# Docker 部署指南

智谱AI GLM Coding Plan 账单统计系统 Docker 容器化部署文档

## 🚀 快速开始

### 自动化脚本（推荐）

```bash
# 构建默认版本
./docker-build.sh

# 构建指定版本
./docker-build.sh 1.0.0

# 查看状态
./docker-build.sh status

# 查看日志
./docker-build.sh logs

# 停止服务
./docker-build.sh stop
```

### Docker Compose

```bash
# 启动服务
docker-compose up -d

# 查看状态
docker-compose ps

# 查看日志
docker-compose logs -f

# 停止服务
docker-compose down
```

## 🏗️ 构建和运行

### 手动构建

```bash
# 构建镜像
docker build -t areyouok-app:latest .

# 运行容器
docker run -d \
  --name areyouok-app \
  --restart unless-stopped \
  -p 3000:3000 \
  -v $(pwd)/data:/app/data:rw \
  -v $(pwd)/logs:/app/logs:rw \
  areyouok-app:latest
```

### 版本管理

```bash
# 构建指定版本
docker build -t areyouok-app:1.0.0 .

# 运行指定版本
docker run -d --name areyouok-app -p 3000:3000 \
  -v $(pwd)/data:/app/data:rw \
  -v $(pwd)/logs:/app/logs:rw \
  areyouok-app:1.0.0

# 查看镜像版本
docker images | grep areyouok-app
```

## ⚙️ 配置说明

### 环境变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `NODE_ENV` | `production` | 运行环境 |
| `PORT` | `7965` | 后端API端口（容器内部） |
| `TZ` | `Asia/Shanghai` | 时区设置 |
| `PUID` | - | 运行用户的UID（可选，仅在以root启动时有效） |
| `PGID` | - | 运行用户的GID（可选，仅在以root启动时有效） |

### 用户和权限配置

本镜像支持灵活的UID/GID配置，适用于各种部署环境：

#### 默认模式（不指定PUID/PGID）
```bash
docker run -d --name areyouok-app -p 3000:3000 \
  -v $(pwd)/data:/app/data:rw \
  -v $(pwd)/logs:/app/logs:rw \
  areyouok-app:latest
```
容器以root启动，自动创建nodejs用户（无固定UID），并切换到该用户运行应用。

#### 指定UID/GID模式
```bash
docker run -d --name areyouok-app -p 3000:3000 \
  -e PUID=1001 \
  -e PGID=1001 \
  -v $(pwd)/data:/app/data:rw \
  -v $(pwd)/logs:/app/logs:rw \
  areyouok-app:latest
```
容器创建指定UID/GID的nodejs用户，适用于需要匹配宿主机用户权限的场景。

#### OpenShift / Kubernetes 任意UID模式
```bash
docker run -d --name areyouok-app -p 3000:3000 \
  --user 10000:10000 \
  -v $(pwd)/data:/app/data:rw \
  -v $(pwd)/logs:/app/logs:rw \
  areyouok-app:latest
```
容器以指定的任意UID运行，自动跳过权限设置，使用宽松的目录权限确保可写。

#### Kubernetes 部署示例
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: areyouok
spec:
  template:
    spec:
      securityContext:
        fsGroup: 1001  # 设置文件系统组
        runAsUser: 1001  # 或让OpenShift自动分配
      containers:
      - name: areyouok
        image: areyouok-app:latest
        env:
        - name: PUID
          value: "1001"
        - name: PGID
          value: "1001"
        volumeMounts:
        - name: data
          mountPath: /app/data
        - name: logs
          mountPath: /app/logs
```

### 数据卷

```bash
# SQLite 数据库持久化
-v $(pwd)/data:/app/data:rw

# 日志文件持久化
-v $(pwd)/logs:/app/logs:rw
```

### 端口说明

- `3000:3000` - 外部访问端口（Nginx前端服务）
- `7965` - 后端API端口（仅容器内部，通过Nginx代理访问）

## 🔍 健康检查

```bash
# 查看容器状态
docker ps --format "table {{.Names}}\t{{.Status}}"

# 手动健康检查
curl http://localhost:3000/health
curl http://localhost:3000/api/
```

## 📝 日志管理

```bash
# 查看容器日志
docker logs areyouok-app
docker logs -f areyouok-app

# 查看应用日志文件
tail -f logs/backend.log
tail -f logs/nginx.log
```

## 💾 数据备份

```bash
# 手动备份
docker run --rm \
  -v $(pwd)/data:/data:ro \
  -v $(pwd)/backups:/backups:rw \
  alpine:latest \
  tar -czf /backups/backup_$(date +%Y%m%d_%H%M%S).tar.gz -C /data expense_bills.db
```

## 🔧 故障排除

### 常见问题

#### 容器启动失败
```bash
# 查看启动日志
docker logs areyouok-app

# 重新构建镜像
docker build --no-cache -t areyouok-app .
```

#### 端口冲突
```bash
# 检查端口占用
lsof -i :3000

# 使用其他端口
docker run -d --name areyouok-app -p 8080:3000 areyouok-app
```

#### 数据库权限问题
```bash
# 方法1: 使用PUID/PGID匹配宿主机用户
docker run -d --name areyouok-app -p 3000:3000 \
  -e PUID=$(id -u) \
  -e PGID=$(id -g) \
  -v $(pwd)/data:/app/data:rw \
  areyouok-app:latest

# 方法2: 手动修复权限（传统方式）
sudo chown -R 1001:1001 data/

# 方法3: 使用宽松权限（适用于多用户环境）
chmod -R 777 data/ logs/
```

#### 调试模式
```bash
# 进入容器
docker exec -it areyouok-app /bin/sh

# 查看进程状态
docker exec areyouok-app ps aux
```

## 🔄 更新升级

```bash
# 停止旧容器
docker stop areyouok-app
docker rm areyouok-app

# 重新构建镜像
docker build --no-cache -t areyouok-app .

# 启动新容器
docker run -d \
  --name areyouok-app \
  --restart unless-stopped \
  -p 3000:3000 \
  -v $(pwd)/data:/app/data:rw \
  -v $(pwd)/logs:/app/logs:rw \
  areyouok-app
```

## 📞 访问地址

部署成功后的访问地址：

- **前端界面**: http://localhost:3000
- **后端API**: http://localhost:3000/api/
- **健康检查**: http://localhost:3000/health

## 📋 部署检查清单

### 部署前检查
- [ ] Docker和Docker Compose已安装
- [ ] 项目源代码已克隆
- [ ] 端口3000未被占用
- [ ] data和logs目录有写权限

### 部署后验证
- [ ] 容器启动成功
- [ ] 健康检查通过
- [ ] 前端页面可访问
- [ ] 后端API可访问
- [ ] 数据库初始化完成

---

**注意**: 首次运行时，系统会自动初始化SQLite数据库。请确保 `data/` 和 `logs/` 目录具有适当的写入权限。

## 🔐 任意UID/GID支持说明

### 为什么需要支持任意UID/GID

传统Docker镜像通常硬编码固定的用户UID/GID（如1001），这在以下环境中会导致问题：

1. **OpenShift / OKD**: 自动分配任意UID运行容器，硬编码UID会导致权限冲突
2. **Rootless Docker**: 使用UID映射时，容器内UID与宿主机不匹配
3. **Kubernetes SecurityContext**: 使用`runAsUser`指定特定UID时
4. **挂载卷权限**: 宿主机卷的所有者与容器用户不匹配时无法写入

### 本镜像的解决方案

1. **动态用户创建**: 不在Dockerfile中硬编码UID/GID
2. **运行时配置**: 支持通过`PUID`/`PGID`环境变量指定用户ID
3. **智能权限处理**: 
   - 以root启动时：创建用户、设置权限、降权运行
   - 以非root启动时：直接使用指定UID，跳过权限操作
   - 挂载点检测：避免对已挂载的卷执行chown
4. **宽松权限回退**: 为目录设置组/其他用户写权限，确保任意UID可写

### 使用场景

| 场景 | 启动方式 | 说明 |
|------|---------|------|
| 本地开发 | 默认启动 | 自动处理，无需额外配置 |
| 匹配宿主机用户 | `-e PUID=1001 -e PGID=1001` | 避免挂载卷权限问题 |
| OpenShift | `--user 10000` 或 securityContext | 支持任意UID分配 |
| Kubernetes | securityContext.fsGroup | 推荐使用fsGroup统一管理 |
| Rootless Docker | `-e PUID=$(id -u)` | 匹配实际宿主机用户 |

### 兼容性说明

- 向后兼容：现有部署无需修改即可正常运行
- 默认行为：不指定PUID/PGID时，行为与之前一致（但UID不再固定为1001）
- 升级建议：如需固定UID，请在运行时指定`PUID`/`PGID`环境变量