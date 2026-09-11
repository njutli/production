# JuiceFS Cluster Portal

当前已在`10.20.1.152`部署实时只读监控门户，接入JuiceFS、PD/TiKV、Ceph、主机和NVMe指标，并启用本地账户、HTTPS及ADMIN/USER后端RBAC。T09三级目录用量也已按“总量完整、每个目录top 100大项”合同接入业务卷。

## 访问已部署门户

在本机建立SSH隧道：

```bash
ssh -L 8443:10.20.1.152:8443 thailand
```

随后打开`https://localhost:8443/`。当前使用自签名证书，首次访问需核对证书SHA256指纹：

```text
78:2A:A7:57:1D:74:FC:60:29:46:EC:DD:2E:7E:6B:74:C3:28:C9:17:63:20:7E:FF:15:6B:F1:46:CF:34:CD:F0
```

初始随机账户密码仅保存在152的`/etc/juicefs-portal/bootstrap-credentials.txt`，权限为root-only；由管理员登录152后使用sudo读取，禁止复制到Git、报告或聊天记录。确认接收后应按单独批准删除该明文文件。

## 本地离线运行

```bash
make test
make run
```

打开 `http://127.0.0.1:8080`。fixture演示账户为`admin / fixture-admin-password`和`user / fixture-user-password`，只允许本机开发使用。

## 目录

- `api/`：Go 标准库只读 API 和 OpenAPI 合同；
- `web/`：无构建依赖的管理员页面；
- `fixtures/`：脱敏测试数据；
- `configs/`：无凭据配置模板；
- `tests/`：离线 Gate；
- `deploy/`：部署、更新、验证和回滚资产。
- `inventory/`：逐阶段执行证据与签收记录。

## 当前边界

- 除登录/退出会话外，所有接口只接受GET/HEAD；
- 本地账户密码使用Argon2id哈希，会话使用HttpOnly、SameSite签名Cookie；
- ADMIN API会拒绝未认证请求和USER角色；
- 时序查询只接受语义指标白名单，不接受任意 PromQL；
- 完整文件明细浏览和内容访问继续延期；T09只恢复授权根的三级递归总量、每个目录top 100直接子项及其余项聚合。
- JuiceFS `summary`控制请求要求技术可写挂载；152使用不含`allow_other/allow_root`且配置`--atime-mode noatime`的专用控制挂载，Portal本身通过systemd路径隔离不可访问该挂载，只读取SQLite快照。
