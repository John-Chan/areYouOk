#!/bin/sh
#
# docker-start.sh - Entrypoint for AreYouOk Docker container
#
# This script handles running the container with arbitrary UID/GID assignments,
# making it compatible with:
# - OpenShift arbitrary UIDs
# - Rootless Docker with UID remapping
# - Kubernetes securityContext with different fsGroup
# - Host volume mounts with different ownership
#
# Environment variables:
#   PUID - User ID for the nodejs user (optional, only when running as root)
#   PGID - Group ID for the nodejs group (optional, only when running as root)
#
# Usage:
#   Run as root (default): Container handles user creation and permission setup
#   Run with --user flag: Container runs as that user without privilege operations
#   Run with PUID/PGID: Creates nodejs user with specified IDs when running as root
#

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Detect current user
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

log "Starting AreYouOk container (UID=$CURRENT_UID, GID=$CURRENT_GID)"

# Function to check if a path is a mount point
is_mountpoint() {
    mountpoint -q "$1" 2>/dev/null || [ "$(stat -c '%d' "$1" 2>/dev/null)" != "$(stat -c '%d' "$1/.." 2>/dev/null)" ]
}

# Function to safely chown, ignoring errors on mount points
safe_chown() {
    local target="$1"
    local owner="$2"
    
    if [ ! -e "$target" ]; then
        return 0
    fi
    
    # Skip if it's a mount point
    if is_mountpoint "$target"; then
        log "Skipping chown on mountpoint: $target"
        # Try to set permissive permissions instead
        chmod -R g+rwX,o+rwX "$target" 2>/dev/null || log "Warning: Could not set permissive permissions on $target"
        return 0
    fi
    
    # Try to chown, log but don't fail if it doesn't work
    if ! chown -R "$owner" "$target" 2>/dev/null; then
        log "Warning: Could not chown $target, attempting permissive permissions"
        chmod -R g+rwX,o+rwX "$target" 2>/dev/null || true
    fi
}

# Handle running as root - setup user and permissions
if [ "$CURRENT_UID" = "0" ]; then
    log "Running as root, setting up user and permissions"
    
    # Determine target UID and GID
    TARGET_UID=${PUID:-}
    TARGET_GID=${PGID:-}
    
    if [ -n "$TARGET_UID" ] && [ -n "$TARGET_GID" ]; then
        log "Creating nodejs user with UID=$TARGET_UID, GID=$TARGET_GID"
        
        # Remove existing nodejs user/group if they exist
        deluser nodejs 2>/dev/null || true
        delgroup nodejs 2>/dev/null || true
        
        # Create group and user with specified IDs
        addgroup -g "$TARGET_GID" -S nodejs
        adduser -S -u "$TARGET_UID" -G nodejs -s /bin/sh nodejs
    else
        log "Using default nodejs user (no PUID/PGID specified)"
        # User should already exist from Dockerfile, but ensure it does
        if ! id nodejs >/dev/null 2>&1; then
            addgroup -S nodejs
            adduser -S -G nodejs -s /bin/sh nodejs
        fi
    fi
    
    # Get the actual nodejs user UID/GID
    NODEJS_UID=$(id -u nodejs)
    NODEJS_GID=$(id -g nodejs)
    log "nodejs user configured: UID=$NODEJS_UID, GID=$NODEJS_GID"
    
    # Fix permissions on internal directories (not mount points)
    log "Setting up directory permissions..."
    
    # Application directories - try to chown but handle mount points gracefully
    safe_chown /app "nodejs:nodejs"
    safe_chown /app/data "nodejs:nodejs"
    safe_chown /app/logs "nodejs:nodejs"
    
    # Nginx directories
    safe_chown /var/log/nginx "nodejs:nodejs"
    safe_chown /var/lib/nginx "nodejs:nodejs"
    safe_chown /run/nginx "nodejs:nodejs"
    safe_chown /etc/nginx "nodejs:nodejs"
    
    # Ensure directories are writable by group/others as fallback for OpenShift
    for dir in /app/data /app/logs /var/log/nginx /var/lib/nginx/logs /run/nginx; do
        if [ -d "$dir" ]; then
            chmod -R g+rwX,o+rwX "$dir" 2>/dev/null || true
        fi
    done
    
    log "Permissions setup complete, switching to nodejs user"
    
    # Use su-exec to drop privileges and run the rest of the script as nodejs user
    # Export functions and variables for the subshell
    export NODEJS_UID NODEJS_GID
    
    if command -v su-exec >/dev/null 2>&1; then
        exec su-exec nodejs "$0" --as-user
    elif command -v gosu >/dev/null 2>&1; then
        exec gosu nodejs "$0" --as-user
    else
        exec su -s /bin/sh nodejs "$0" --as-user
    fi
fi

# This part runs as the nodejs user (or non-root user)
if [ "$1" = "--as-user" ]; then
    log "Running application as nodejs user"
else
    log "Running as non-root user (UID=$CURRENT_UID, GID=$CURRENT_GID)"
    log "Skipping user creation and chown operations"
    
    # Ensure critical directories exist and are writable
    for dir in /app/data /app/logs /var/log/nginx /var/lib/nginx/logs /run/nginx; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" 2>/dev/null || log "Warning: Could not create $dir"
        fi
    done
    
    # Check if we can write to critical directories
    for dir in /app/data /app/logs; do
        if [ -d "$dir" ] && [ ! -w "$dir" ]; then
            log "Warning: Directory $dir is not writable by current user"
        fi
    done
fi

# Application startup functions
wait_for_backend() {
    log "Waiting for backend..."
    for i in $(seq 1 30); do
        if curl -f -s http://localhost:7965/ > /dev/null 2>&1; then
            log "Backend ready"
            return 0
        fi
        sleep 1
    done
    log "Backend failed to start"
    return 1
}

init_database() {
    if [ ! -f "/app/data/expense_bills.db" ]; then
        log "Initializing database..."
        cd /app/backend && npm run init-db 2>&1 | tee /app/logs/db_init.log
        [ $? -eq 0 ] || { log "Database init failed"; exit 1; }
    fi
}

log "Initializing application..."

init_database

log "Starting backend..."
cd /app/backend && NODE_ENV=production PORT=7965 npm start > /app/logs/backend.log 2>&1 &
BACKEND_PID=$!

wait_for_backend

log "Starting nginx..."
nginx -g 'daemon off; pid /run/nginx/nginx.pid;' \
  -c /etc/nginx/nginx.conf \
  -e error >/app/logs/nginx.log 2>&1 &
NGINX_PID=$!

shutdown() {
    log "Stopping services..."
    kill -TERM $NGINX_PID $BACKEND_PID 2>/dev/null
    wait $NGINX_PID $BACKEND_PID
    log "Stopped"
    exit 0
}

trap shutdown SIGTERM SIGINT

tail -f /app/logs/backend.log &

log "Services started successfully"
log "Frontend: http://localhost:3000"
log "API: http://localhost:3000/api/"

wait $BACKEND_PID $NGINX_PID