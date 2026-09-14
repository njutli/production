# JuiceFS Cluster Portal

这是部署在 `10.20.1.152` 的 JuiceFS 集群只读管理门户。当前已接入 JuiceFS、PD/TiKV、Ceph、主机、NVMe、客户端和三级目录用量，并提供 HTTPS、ADMIN/USER 权限隔离、实时状态、数据过期提示及带宽趋势曲线。

系统功能、架构、安全边界、刷新周期、访问方式和已知限制统一见：

- [当前阶段系统功能说明](CURRENT-STAGE-SYSTEM-OVERVIEW-20260914.md)
- [当前部署验收摘要](inventory/CURRENT-DEPLOYMENT-ACCEPTANCE-SUMMARY-20260914.md)
- [开发部署步骤](DEVELOPMENT-DEPLOYMENT-STEPS.md)
- [当前任务状态](TODO.md)

## 快速访问

```bash
ssh -F /home/lilingfeng/.ssh/config -N -T \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8443:10.20.1.152:8443 thailand
```

打开 `https://localhost:8443/`。当前使用自签名证书；账户凭据只保存在 152 的 root-only 文件中，不进入代码仓库。

## 本地验证

```bash
make test
make run
```

本地 fixture 仅用于开发演示，打开 `http://127.0.0.1:8080`。目录结构：`api/` 为 Go API，`web/` 为静态前端，`deploy/` 为部署资产，`docs/` 为现行合同，`inventory/` 仅保留阶段签收。
