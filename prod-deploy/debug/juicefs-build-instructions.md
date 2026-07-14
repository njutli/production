# JuiceFS 1.3.1 + eaf3d21f 补丁构建说明

## 补丁信息
- **commit:** eaf3d21fc3dcc0fa79e44b3562a3d3554b08c45d
- **消息:** object: do partial read if cache is disabled (#6364)
- **文件:** pkg/chunk/cached_store.go
- **变更:**
  ```diff
  - if s.store.seekable && boff > 0 && len(p) <= blockSize/4 {
  + if s.store.seekable &&
  +     (!s.store.conf.CacheEnabled() || (boff > 0 && len(p) <= blockSize/4)) {
  ```
- **效果:** 缓存禁用(cache=0)时做部分读，避免读整个 block 的放大

## 构建步骤

```bash
# 1. 克隆 v1.3.1
git clone --branch v1.3.1 --depth 100 https://github.com/juicedata/juicefs.git
cd juicefs

# 2. 手动应用补丁（eaf3d21f 在 main 分支，未 backport 到 v1.3.1）
#    修改 pkg/chunk/cached_store.go 第 153 行

# 3. 下载 librados-dev 头文件（WSL 无 sudo）
apt-get download librados-dev
dpkg-deb -x librados-dev*.deb /path/to/librados-dev
ln -sf /usr/lib/x86_64-linux-gnu/librados.so.2 /path/to/librados-dev/usr/lib/x86_64-linux-gnu/librados.so

# 4. 编译（-tags ceph 关键：启用 ceph 存储后端）
CGO_CFLAGS="-I/path/to/librados-dev/usr/include" \
CGO_LDFLAGS="-L/path/to/librados-dev/usr/lib/x86_64-linux-gnu -lrados" \
GOPROXY=https://goproxy.cn,direct \
go build -tags ceph -ldflags="-s -w" -o juicefs .

# 5. 验证
ldd juicefs | grep rados  # 应显示 librados.so.2
juicefs version           # 1.3.1+2025-12-02.e0032b2
```

## 部署
- 通过 HK ECS 中转 scp 到 157（base64 传输超 112MB 限制）
- 安装到 /usr/local/bin/juicefs
