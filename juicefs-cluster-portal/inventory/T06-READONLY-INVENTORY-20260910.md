# T06 指标源只读盘点

> 时间：2026-09-10  
> 裁决：`T06_INVENTORY_PASS`  
> 状态变更：无；通过157向150～152执行只读查询。

## 1. JuiceFS 客户端157

- 主机名：`oneasia-c1-cpu-node10`。
- JuiceFS metrics：`127.0.0.1:9567/metrics`，HTTP 200，单次约100 KiB；不改变现有挂载，后续在`10.20.1.157:9633`部署只读转发器。
- 现有Node Exporter：`*:9100`，HTTP 200，单次约335 KiB；直接复用，不安装第二份。
- 计划端口`9633`空闲。
- JuiceFS挂载进程仍为`/tmp/juicefs-1.4.1-patched`，挂载参数包含`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`。
- 实测标签为`instance`、`juicefs_version`、`mp`、`vol_name`、`method`和`storage_class`。
- FUSE、对象请求、blockcache、buffer/staging、卷用量、uptime和进程资源指标均存在。

## 2. PD/TiKV与节点指标

| 节点 | 主机名 | PD `:2379/metrics` | TiKV `:20180/metrics` | `:9100` | NVMe工具/控制器 |
|---|---|---:|---:|---|---|
| `10.20.1.150` | `ceph-node1` | HTTP 200，约500 KiB | HTTP 200，约1.45 MiB | 空闲 | `nvme`、`smartctl`存在，4个控制器 |
| `10.20.1.151` | `ceph-node2` | HTTP 200，约264 KiB | HTTP 200，约1.49 MiB | 空闲 | 同上 |
| `10.20.1.152` | `ceph-node3` | HTTP 200，约264 KiB | HTTP 200，约1.49 MiB | 空闲 | 同上 |

- PD需要的region、hot region和heartbeat系列均存在。
- TiKV需要的进程、PD/gRPC/scheduler/storage、Raft、RocksDB cache/compaction/stall/WAL系列均存在。
- 三节点非root执行`nvme smart-log`会被设备权限拒绝，因此采用受限root oneshot每5分钟采一次，而不是在页面请求时执行sudo。
- Node Exporter采用官方`1.12.1` Linux amd64包，官方SHA256为`b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63`。

## 3. Ceph

- `10.20.1.150:9283`、`.151:9283`、`.152:9283`均拒绝连接，说明Ceph mgr Prometheus模块当前未提供端点。
- 下一步先用只读`ceph mgr dump/module ls/config get/orch ps`确定active/standby和现有配置，再单独审批最小的`mgr module enable prometheus`；不启用Ceph Dashboard。

## 4. 接入边界

- 不重挂、不重启、不修改157上的JuiceFS进程。
- 不修改PD/TiKV/Ceph OSD配置，不访问数据目录，不写任何NVMe设备。
- 150～152只新增低资源Node Exporter和5分钟一次的只读NVMe SMART采集。
- 所有监控数据仍只写152系统盘；服务在调试阶段只`start`，不`enable`。

