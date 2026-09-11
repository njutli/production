# 监控 MVP v1 范围冻结

> 状态：`FROZEN`
> 冻结日期：2026-09-10
> 部署节点：`10.20.1.152`

## 1. 本版目标

第一版只交付管理员只读监控面：统一查看 JuiceFS + TiKV/PD + Ceph 的健康、容量、吞吐、客户端、主机磁盘和组件拓扑。页面不提供任何集群控制或文件写入能力。

“实时”是指后台定时采集、页面自动刷新并展示数据年龄；页面请求只读本地缓存或 Prometheus，不直接 SSH 集群或现场执行命令。

## 2. 页面与冻结字段

| 页面 | 必须展示的字段 |
|---|---|
| 总览 | 集群总状态；在线/过期客户端数；JuiceFS 逻辑读写带宽；Ceph 物理读写带宽；节点网络带宽；全卷逻辑空间/inode；Ceph pool/raw 用量；PD/TiKV/MON/MGR/OSD/PG 摘要；当前告警；各数据源年龄 |
| 拓扑 | client→JuiceFS volume；client→PD/TiKV；client→Ceph pool→OSD→物理盘；PD Leader；MGR Active；TiKV Store、OSD up/in 和客户端在线状态；静态映射与实时状态的来源时间 |
| 节点与磁盘 | 主机 CPU/内存/网络；设备名、型号、序列号、容量、挂载点、用途；读写带宽、IOPS、平均时延、队列、util；NVMe 温度、寿命、media error、unsafe shutdown；OSD block/DB/WAL 和 TiKV 路径映射 |
| JuiceFS 客户端 | 主机、挂载点、版本、启动时间/uptime；FUSE 读写吞吐、IOPS和平均延迟；对象 GET/PUT 吞吐、请求率、平均延迟和错误；缓存命中/未命中字节、淘汰/drop；buffer/staging；进程 CPU/内存 |
| TiKV/PD | PD Leader、成员和 Store Up/Down；Region/Leader 分布；TiKV scheduler/latch/storage 延迟；Raft append/commit/apply；pending compaction、L0 文件、compaction 流量、write stall；进程资源 |
| Ceph | HEALTH；MON quorum；MGR Active；OSD up/in；PG clean/非 clean；pool/raw 容量；读写吞吐、IOPS、延迟；recovery/backfill/scrub；OSD 到磁盘映射 |
| 容量 | JuiceFS 全卷逻辑空间和 inode；Ceph pool stored/used/max available；集群 raw used/available；逻辑量与物理量必须分开展示 |
| 告警 | 严重度、对象、摘要、开始时间、最近更新时间、数据源、当前/已恢复状态；只通知，不自动修复 |

每个状态卡片必须显示 `collectedAt`、`ageSeconds` 和 `freshness`。数据缺失或过期不得显示为 0 或健康。

## 3. T09范围恢复

T02～T08期间以下内容曾延期；2026-09-11起仅恢复“授权根目录三级递归用量SQLite快照”：

- USER可查看绑定根目录的完整总用量，以及三级内每个目录容量最大的100个直接子项和其余项聚合；ADMIN可查看全部根；
- 页面只读SQLite，不同步运行`du`、JuiceFS命令或目录扫描；
- 超过top 100的逐项名称、完整文件明细、面包屑、文件属性、内容预览和下载仍延期；
- 152专用控制挂载因JuiceFS `.control`合同采用内核rw，但无`allow_other/allow_root`且使用JuiceFS参数`--atime-mode noatime`；仅固定后台采集器可访问，Portal由systemd明确屏蔽该路径。

## 4. 安全与资源边界

- 只有 `ADMIN` 可访问监控 API；Prometheus、Grafana 和 exporter 不直接暴露给用户。
- 不提供 format、mount、umount、服务启停、配置修改、告警自愈或文件操作接口。
- 不重挂 157 的生产 JuiceFS；其 localhost metrics 后续只用轻量只读转发采集。
- 门户数据只写 152 系统盘，禁止写入 `/mnt/jfs-tikv`、`/mnt/dbwal` 和任何 Ceph OSD 设备。
- 页面刷新不触发 SSH、sudo、Ceph CLI、smartctl 或 PD/TiKV 管理命令。
- 管理面故障只允许造成监控不可见，不能影响 JuiceFS、TiKV/PD 或 Ceph 服务。

## 5. T02 冻结规则

- 页面字段、语义指标 ID、API 路径和刷新 SLA 进入 v1 合同。
- 已可访问的数据源冻结到实际指标名；尚未启用的 Ceph/Node/SMART exporter 冻结语义字段和标准候选指标名，T06 只允许校正绑定关系，不得静默删减页面字段。
- 新字段进入 backlog，不在实现中临时扩展 v1。
- 任何写能力、目录查询或普通用户功能都必须单独恢复范围并重新审查安全边界。
