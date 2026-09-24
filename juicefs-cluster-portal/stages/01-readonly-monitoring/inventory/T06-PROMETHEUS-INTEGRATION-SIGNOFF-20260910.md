# T06 Prometheus 指标接入签收

> 时间：2026-09-10  
> 裁决：`T06_PASS`  
> 运行方式：调试态，所有新增服务均为`active/disabled`，未设置开机自启。

## 接入结果

- 152中央Prometheus已切换到T06白名单配置，仅重启`juicefs-prometheus.service`；切换前备份位于`/var/lib/juicefs-portal/t06-backup`。
- 两次全局验收跨越多个采集周期，均返回`TARGET_CONTRACT_PASS required=12 ceph_up=2`和`T06_GLOBAL_VERIFY_PASS enabled=false`。
- 12个必需目标全部在线：Prometheus 1、JuiceFS客户端1、PD 3、TiKV 3、Node Exporter 4；Ceph至少一个Gate满足，实际两个HTTP目标均为up。
- NVMe控制器计数为12，正好对应150～152每节点4个控制器。

## 时序规模

| job/指标 | 当前活跃时序数 |
|---|---:|
| JuiceFS客户端 | 160 |
| PD | 779 |
| TiKV | 13,299 |
| Node Exporter | 4,722 |
| Ceph | 574 |
| `jfsportal_nvme_info`控制器 | 12 |
| Prometheus TSDB总活跃时序 | 20,438 |

白名单已将总量控制在约2.1万条时序，低于资源规划量级。Prometheus服务保持`active/disabled`且重启次数为0。

## 安全与业务复核

- 150～152的Node Exporter和NVMe timer均为active/disabled；157只读转发器为active/disabled且重启次数为0。
- 152上的Prometheus、Grafana和Portal均为active/disabled。
- Ceph指标`ceph_health_status=0`，对应`HEALTH_OK`；启用Prometheus mgr模块后未修改其他Ceph配置。
- 152的PD PID仍为`1589960`、TiKV PID仍为`2088516`；`/mnt/jfs-tikv`和`/mnt/dbwal`挂载未变。
- 157原JuiceFS业务进程PID `977835/977874`未变；转发器只读访问本机`9567`，没有重挂或重启JuiceFS。

## 边界

- T06只完成指标采集链路，不在本步实现Portal实时适配器和页面；该工作属于T07。
- Prometheus原生`up`和样本时间戳已经保留，Portal按冻结的数据新鲜度合同判断`STALE/UNAVAILABLE`，不得把缺失数据写成0。
- 不主动停止真实采集器做故障注入；低扰动故障隔离验收统一放在T10，避免为了验证监控而中断当前正常采集链路。

## 结论

T06完成：JuiceFS、PD/TiKV、Ceph、四节点主机和三节点NVMe指标已经汇聚到152，采集链路跨周期稳定，资源规模受控，业务进程和挂载未受影响。下一步为T07管理员总览、磁盘和动态拓扑MVP接入真实数据。
