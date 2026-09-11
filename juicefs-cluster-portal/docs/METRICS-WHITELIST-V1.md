# 指标白名单 v1

> 状态：`FROZEN_SEMANTIC`
> 原则：Prometheus 只保留本表所需系列；未在表内的高基数指标默认不采集。

## 1. JuiceFS 客户端（157）

实际 metrics 当前仅监听 `127.0.0.1:9567`。以下系列来自现有 JuiceFS 1.4.1 指标合同；T06 接入时须保存一次完整 label 样本并核对 method 标签。

| 语义 ID | 指标系列/算法 | 单位 |
|---|---|---|
| `jfs.fuse.read_bps` / `write_bps` | `rate(juicefs_fuse_{read,written}_size_bytes_sum[1m])` | B/s |
| `jfs.fuse.read_iops` / `write_iops` | 按 method 取 `rate(juicefs_fuse_ops_total[1m])` | ops/s |
| `jfs.fuse.latency` | 按 method 取 `rate(juicefs_fuse_ops_durations_histogram_seconds_sum[1m]) / rate(..._count[1m])` | s/op |
| `jfs.object.get_bps` / `put_bps` | 按 method 取 `rate(juicefs_object_request_data_bytes[1m])` | B/s |
| `jfs.object.request_rate` | 按 method 取对象请求 histogram 的 count 增量 | req/s |
| `jfs.object.latency` | 按 method 取对象请求 histogram 的 sum/count 增量 | s/req |
| `jfs.object.errors` | `rate(juicefs_object_request_errors[5m])` | errors/s |
| `jfs.cache.hit_ratio_bytes` | hit bytes 增量 / (hit + miss bytes 增量) | ratio |
| `jfs.cache.bytes` | `juicefs_blockcache_bytes` | B |
| `jfs.cache.evicts` / `drops` | `rate(juicefs_blockcache_{evicts,drops}[5m])` | events/s |
| `jfs.buffer.write_bytes` / `read_bytes` | `juicefs_used_buffer_size_bytes` / `juicefs_used_read_buffer_size_bytes` | B |
| `jfs.staging.blocks` / `bytes` | `juicefs_staging_blocks` / `juicefs_staging_block_bytes`（存在时） | count/B |
| `jfs.volume.used_space` / `used_inodes` | `juicefs_used_space` / `juicefs_used_inodes` | B/count |
| `jfs.client.uptime` | `juicefs_uptime` | s |
| `jfs.client.cpu` / `rss` | JuiceFS process CPU counter / resident memory gauge | core-s/B |

禁止把 FUSE 逻辑吞吐、对象层吞吐和节点网卡吞吐合并为同一指标。

## 2. PD/TiKV

以下指标名已从当前 `:2379/metrics` 和 `:20180/metrics` 只读探测确认；仅保留需要的 label 组合。

| 语义 ID | 指标系列/来源 |
|---|---|
| `pd.leader` / `pd.members` | Prometheus `etcd_server_is_leader`、`etcd_server_has_leader`与`up{job="pd"}`；Portal不在页面刷新时直连PD API |
| `pd.stores` | PD 只读 stores API；metrics 辅助使用 `pd_cluster_store_sync` |
| `pd.region_state` | `pd_regions_status`、`pd_regions_offline_status` |
| `pd.hotspot` | `pd_scheduler_hot_*` 和 PD 只读 hotspot API |
| `pd.heartbeat_latency` | PD heartbeat histogram 系列 |
| `tikv.server.info` | `tikv_server_info`、`tikv_server_cpu_cores_quota` |
| `tikv.process.cpu` / `rss` | `process_cpu_seconds_total`、`process_resident_memory_bytes` |
| `tikv.pd.health` | `tikv_pd_heartbeat_message_total`、`tikv_pd_pending_heartbeat_total`、`tikv_pd_reconnect_total`、`tikv_pd_request_duration_seconds_*` |
| `tikv.grpc.latency` | `tikv_grpc_msg_duration_seconds_*` |
| `tikv.scheduler.latency` | `tikv_scheduler_command_duration_seconds_*`、`tikv_scheduler_latch_wait_duration_seconds_*` |
| `tikv.storage.latency` | `tikv_storage_engine_async_request_duration_seconds_*`、`tikv_storage_command_total` |
| `tikv.raft.latency` | `tikv_raftstore_append_log_duration_seconds_*`、`tikv_raftstore_commit_log_duration_seconds_*`、`tikv_raftstore_apply_duration_secs_*`、`tikv_raftstore_raft_log_kv_sync_duration_secs_*` |
| `tikv.raft.state` | `tikv_raftstore_region_count`、`tikv_raftstore_leader_missing` |
| `tikv.engine.size` / `cache` | `tikv_engine_size_bytes`、`tikv_engine_block_cache_size_bytes`、`tikv_engine_cache_efficiency` |
| `tikv.compaction` | `tikv_engine_pending_compaction_bytes`、`tikv_engine_compaction_flow_bytes`、`tikv_engine_num_files_at_level`、`tikv_engine_num_immutable_mem_table` |
| `tikv.write_stall` | `tikv_engine_write_stall`、`tikv_engine_write_stall_reason`、`tikv_engine_stall_micro_seconds` |
| `tikv.wal` | `tikv_engine_wal_file_sync_micro_seconds`、`tikv_engine_write_wal_time_micro_seconds` |

## 3. Ceph

Ceph mgr Prometheus模块已在T06启用并完成首次只读抓取。150为active MGR并导出指标；151为standby，端点可达但当前响应体为空。实测绑定如下：

| 语义 ID | T06实测指标 |
|---|---|
| `ceph.health` | `ceph_health_status` |
| `ceph.mon.quorum` / `mgr.active` | `ceph_mon_quorum_status`、`ceph_mgr_status`、`ceph_mgr_metadata` |
| `ceph.osd.up_in` | `ceph_osd_up`、`ceph_osd_in`、`ceph_osd_metadata` |
| `ceph.pg.state` | `ceph_pg_total`、`ceph_pg_active`、`ceph_pg_clean`及其他实测PG state系列 |
| `ceph.cluster.capacity` | `ceph_cluster_total_bytes`、`ceph_cluster_total_used_bytes` |
| `ceph.pool.capacity` | `ceph_pool_stored`、`ceph_pool_bytes_used`、`ceph_pool_max_avail` |
| `ceph.pool.io` | `ceph_pool_rd_bytes`、`ceph_pool_wr_bytes`、`ceph_pool_rd`、`ceph_pool_wr` 的 rate |
| `ceph.osd.io` / `latency` | `ceph_osd_op*`、`ceph_osd_apply_latency_ms`、`ceph_osd_commit_latency_ms` |
| `ceph.recovery` / `scrub` | `ceph_osd_recovery_*`、`ceph_pg_recovering`、`ceph_pg_backfilling`、`ceph_pg_scrubbing`、`ceph_pg_deep` |

当前实测版本为Ceph `17.2.8`。未来版本若导出名变化，只修改adapter映射并更新指标目录；不得伪造0值。

## 4. 主机、网络和磁盘

150～152已部署Node Exporter `1.12.1`，157复用原有Node Exporter。采用标准指标：

| 语义 ID | 指标系列/算法 |
|---|---|
| `node.cpu.util` | `node_cpu_seconds_total` 非 idle rate |
| `node.memory.available` | `node_memory_MemAvailable_bytes` |
| `node.network.rx_bps` / `tx_bps` | `rate(node_network_{receive,transmit}_bytes_total[1m])` |
| `node.fs.capacity` | `node_filesystem_size_bytes`、`node_filesystem_avail_bytes` |
| `node.disk.bps` / `iops` | `node_disk_{read,written}_bytes_total`、`node_disk_{reads,writes}_completed_total` rate |
| `node.disk.latency` | I/O time counter增量 / completed counter增量 |
| `node.disk.queue` / `util` | `node_disk_io_time_weighted_seconds_total`、`node_disk_io_time_seconds_total` rate |
| `node.exporter.up` | Prometheus `up` |

SMART/NVMe只保留`jfsportal_nvme_temperature_celsius`、`available_spare_ratio`、`percentage_used_ratio`、`media_errors_total`、`unsafe_shutdowns_total`和`critical_warning`；每5分钟由受限oneshot更新textfile，禁止页面访问时执行smartctl/nvme。

## 5. 标签与基数限制

允许的公共标签：`cluster`、`instance`、`node`、`component`、`volume`、`mountpoint`、`device`、`osd`、`pool`、`store`、`method`、`type`、`cf`、`level`。

禁止采集文件名、目录路径、用户输入、请求 ID、region ID 全量明细等无界标签。默认 14 天且 30 GiB 封顶；任何新增指标先估算 series 数。
