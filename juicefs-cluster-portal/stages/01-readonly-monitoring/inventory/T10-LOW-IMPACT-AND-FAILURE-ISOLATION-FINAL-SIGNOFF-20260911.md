# T10低扰动与故障隔离最终签收

> 时间：2026-09-11  
> RUN：`20260911-172534`  
> 裁决：`T10_LOW_IMPACT_FAILURE_ISOLATION_PASS`

## 1. 执行结果

经用户批准，仅在152顺序短暂停止/恢复Portal和Prometheus：

```text
T10_FAILURE_ISOLATION_PASS portal_stop=true prometheus_stale=true targets=14 services_disabled=true
```

- Portal停止后HTTP健康口不可达，Prometheus和业务组件保持运行；恢复后HTTP/HTTPS健康检查通过；
- Prometheus停止后Portal继续运行，并用最后有效缓存明确返回`freshness=stale`和错误字段；
- Prometheus恢复后14/14 targets重新在线，Portal重新返回fresh；
- 任一步均未操作namespace mount/timer、PD、TiKV、Ceph、Node/NVMe exporter或157 forwarder。

执行时出现的两条`curl connection refused`分别来自预期的Portal/Prometheus停止窗口，不是恢复失败。

## 2. 独立只读复核

| 对象 | 结果 |
|---|---|
| Portal / Prometheus / Grafana | 全部`active/disabled`、`NRestarts=0` |
| Namespace mount / timer | `active/static`，collector为`inactive/static` |
| Portal路径隔离 | `PORTAL_MOUNT_ISOLATION_PASS` |
| T09 SQLite | generation 24、ready、121行；总量与top 100聚合结构未变 |
| Prometheus | `sum(up)=14` |
| Ceph | `HEALTH_OK` |
| PD / TiKV PID | `1589960 / 2088516`，与执行前一致 |
| 业务挂载 | `/mnt/jfs-tikv`、`/mnt/dbwal`完整指纹未变 |
| 157 forwarder | `active/disabled`、`NRestarts=0`、3 tasks、约5.9 MiB |

T09真实快照在故障注入前后均保持`518617337856 bytes / 404 files / 9 dirs`，包含1个有效聚合项；Portal恢复后仍不能进入专用控制挂载。

## 3. 低扰动结论

- 阶段A已证明单个exporter/forwarder CPU远低于单核1%，152常驻管理面内存低于1 GiB；
- forwarder的Go线程数缺陷已通过`GOMAXPROCS=1`消除，当前仅3 tasks且自06:15起`NRestarts=0`；
- 阶段C证明Portal或Prometheus短时故障只影响管理可见性，不改变数据面状态；
- 监控源故障不会显示为0或健康，而是保留最后样本并显式标记stale/error。

T10即时验收完成。forwarder连续24小时和完整管理面24小时观察合并进入T11，避免重复等待；这不改变T10故障隔离结论。

## 4. 下一步

进入T11管理员试运行：保持现有非自启状态，连续观察24小时的服务重启数、targets、T09快照新鲜度、TSDB增长、Ceph健康和业务指纹；随后完成访问、备份、回滚和运维说明并正式交付。
