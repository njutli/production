# T06 Ceph metrics启用签收

> 时间：2026-09-10  
> 裁决：`T06_CEPH_METRICS_PASS`  
> 状态变更：启用Ceph mgr内置`prometheus`模块；未修改模块配置。

## 执行与结果

- 在active MGR所在的150执行用户批准的`ceph mgr module enable prometheus`。
- 命令成功，`prometheus`进入enabled modules；没有执行`ceph config set`。
- Ceph启用后仍为`HEALTH_OK`，没有重启MGR、MON或OSD。
- 默认监听保持`[::]:9283`。

## 端点

- 从152访问`10.20.1.150:9283/metrics`：HTTP 200，约149 KiB，约1.6 ms。
- 从152访问`10.20.1.151:9283/metrics`：HTTP 200，响应体为空；151当前为standby MGR。
- Prometheus同时抓取150和151：当前由150提供数据，MGR切换后151可成为数据源。

## 实测指标

- 健康与角色：`ceph_health_status`、`ceph_mon_quorum_status`、`ceph_mgr_status`、`ceph_mgr_metadata`。
- OSD：up/in、metadata、容量、读写op/bytes、apply/commit latency和recovery系列。
- PG：total、active、clean及recovery/backfill/scrub等状态系列。
- Pool：stored/raw used/max available、objects和读写op/bytes系列。
- 集群：total/used/raw used bytes和磁盘占用映射。

## 持久化与回退

- 模块启用状态会持久化；调试结束或验收失败时可执行已批准的`ceph mgr module disable prometheus`。
- 本次验收通过，未触发回退。

