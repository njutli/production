# T10低扰动、安全与故障隔离验收计划

> 状态：`DONE`；阶段A/B/C已于2026-09-11签收，24小时连续观察合并到T11。

## 1. 目标与精简原则

T10只验证监控面不会影响业务、发生故障时不会伪造健康状态，以及认证和网络边界有效。禁止为验收填满30 GB磁盘、迁移PD Leader、停止PD/TiKV/Ceph/JuiceFS、运行生产路径fio或断开业务网络。

## 2. 阶段划分

### A. 只读基线与安全审计

- 采集各管理服务的CPU、内存、I/O、线程、重启次数和cgroup上限。
- 核对Prometheus 14天/30 GB保留参数、当前TSDB大小、监听和目标健康。
- 复核HTTPS、ADMIN/USER后端RBAC、只读API、限流和来源IP限制。
- 复核管理服务与PD/TiKV/Ceph/JuiceFS不存在启动依赖或写接口。

### B. 最小缺陷修复

只读基线发现157 metrics forwarder因Go默认按128核调度、`TasksMax=32`而出现第33线程创建失败。先设置`GOMAXPROCS=1`并只重启forwarder；保持10%单核、64 MiB、IOWeight 10和TasksMax 32不变。修复前后必须确认JuiceFS PID及`/mnt/juicefs`挂载未变，并从152验证采集恢复。

### C. 最小故障隔离

在B稳定后，单独审批并顺序执行：

1. 短暂停止Portal，确认PD/TiKV、JuiceFS挂载和Ceph不变，再启动Portal；
2. 短暂停止Prometheus但保持Portal运行，确认Portal返回缓存且明确标记stale/unavailable，再启动Prometheus；
3. 确认全部targets恢复、三个管理服务仍为disabled且无自动重启。

T09已在阶段C执行前上线，因此本轮同时固定验证：namespace mount和timer保持`active/static`、mount PID及挂载指纹不变、SQLite快照持续ready且不超过180秒、Portal恢复后仍无法进入专用控制挂载。阶段C不得停止或重启T09挂载与采集器。

不停止150～152 Node Exporter、NVMe collector、157 forwarder或任何业务组件。单一管理源失联语义继续由已有单元/集成测试覆盖，避免扩大远端故障注入。

## 3. 不做的昂贵验收

- 30 GB回收：运行时指标已确认限制为`32212254720`字节；不人为写满系统盘。14天或30 GB先到者触发回收，留给T11观察。
- PD Leader场景：不主动迁移Leader；Portal 0.5核/1 GiB/IOWeight 10的cgroup硬上限与PD角色无关。
- 监控开关下的业务fio A/B：既有性能测试已在监控开启条件下完成，且短窗资源采样远低于单核1%；不再向业务数据集注入负载。
- T09的USER/ADMIN越权、opaque root ID和Portal路径隔离已在T09正式部署中签收；完整文件浏览仍未实现，因此不再构造不存在的路径浏览测试。

## 4. 完成标准

- forwarder修复后24小时内`NRestarts=0`且线程数保有余量；T10即时验收先确认重启后稳定。
- 150～152 Node Exporter单服务CPU低于单核1%、内存低于32 MiB；157 forwarder低于单核1%、内存低于32 MiB。
- 152全部管理服务合计内存低于1 GiB，Prometheus持续写入受14天/30 GB约束。
- Portal/Prometheus停止与恢复不改变PD/TiKV PID、JuiceFS及TiKV挂载或Ceph健康。
- 未认证、越权和写请求保持401/403/405；157可访问Portal TLS，非许可来源不可访问。
