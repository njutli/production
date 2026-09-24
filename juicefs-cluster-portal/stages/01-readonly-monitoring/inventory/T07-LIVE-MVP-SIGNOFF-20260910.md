# T07 管理员实时监控MVP签收

> 完成时间：2026-09-10  
> 裁决：`T07_PASS`

## 交付结果

- Portal已从fixture数据切换为152本机Prometheus实时只读适配器。
- 八个管理员页面均可点击：总览、拓扑、节点与磁盘、JuiceFS客户端、TiKV/PD、Ceph、用量、告警。
- 后端实时API覆盖上述页面及150～152磁盘明细，接口返回数据源为`prometheus`，不会把缺失指标伪装成0。
- 后端具有8秒查询缓存；Prometheus短时不可用时只返回带`stale`标记的旧缓存，没有缓存则明确返回不可用。
- 拓扑按实时指标识别一个PD Leader；磁盘页覆盖150～152共12块NVMe及静态用途/OSD映射。

## 安装过程

第一次更新使用staging `/tmp/jfsportal-t07-20260910-200500`。Portal和Prometheus均成功启动，但脚本在Prometheus自身30秒scrape周期完成前立即执行全量target硬门，观察到自身target为`unknown`，因此按设计自动恢复T06配置、Portal二进制和Web文件并重启两个管理服务。回滚后T06全局只读验收通过，业务状态未变。

最小修复只为既有T06只读验收增加最多18次、每次间隔5秒的有限等待；没有改变采集配置、业务配置或回滚边界。修复版staging为`/tmp/jfsportal-t07-20260910-220949`，三端SHA与离线Gate通过后完成更新：

```text
TARGET_CONTRACT_PASS required=12 ceph_up=2
T06_GLOBAL_VERIFY_PASS enabled=false
T07_READONLY_VERIFY_PASS services_disabled=true
T07_UPDATE_PASS backup=/var/lib/juicefs-portal/t07-backup-20260910-220949 services_disabled=true
```

修复版关键SHA256：

| 文件 | SHA256 |
|---|---|
| Portal二进制 | `252cceb69cd283024f83680a5de64698c64a425131a7056f16ac8c7da91b1883` |
| `index.html` | `68b7b0a0a7fdd77d3028b5e300ed2571a5e7c0f5bfb58c179afc7235217cf3d3` |
| `styles.css` | `c70f44f92855f7792cec14dc614946b90f5b5744c4ae47af52a6dbfd15c8aca6` |
| `app.js` | `fe5a62fc7b2e51fb05443af0376f684e5e54ff907b2ef159d34ffa0981dc9f1d` |
| Prometheus配置 | `56c3019785651928e20444c70fc4fca24a43bf0849137630abffa59ced52d993` |
| `SHA256SUMS` | `a1495d8d7b6288f964fb39e7c35d335653d080dfd38ca6a9674d8563405301d7` |

## 独立验收

- Portal健康：`{"mode":"live","status":"ok"}`。
- Prometheus在线target：14；`count(up == 0)`为空，即没有down target。
- `sum(etcd_server_is_leader{job="pd"}) = 1`。
- `count(jfsportal_nvme_info) = 12`。
- `max(ceph_health_status) = 0`，表示Ceph健康。
- Portal、Prometheus、Grafana均为`active/disabled`且`NRestarts=0`。
- 验收时内存约为Portal 15 MiB、Prometheus 122 MiB、Grafana 209 MiB，既有CPU上限保持生效。
- 已安装Portal二进制及三个Web文件的SHA与修复版staging逐项一致。

## 业务与安全边界

- PD PID保持`1589960`，TiKV PID保持`2088516`。
- `/mnt/jfs-tikv`仍为`/dev/nvme1n1`上的ext4，`/mnt/dbwal`仍为tmpfs。
- 未enable任何服务；所有管理组件仍只监听152 loopback。
- 未操作PD、TiKV、Ceph OSD、JuiceFS业务挂载、NVMe设备或业务数据。
- 普通用户直接运行Ceph CLI因无keyring被拒绝，说明Ceph管理凭据未暴露；门户通过Prometheus白名单指标获取只读健康状态。
- 可回滚备份：`/var/lib/juicefs-portal/t07-backup-20260910-220949`。

## 下一步

T08完成认证与USER/ADMIN后端RBAC，并继续保持Prometheus、Grafana只监听loopback；文件/目录浏览仍按用户决定延期至T09。
