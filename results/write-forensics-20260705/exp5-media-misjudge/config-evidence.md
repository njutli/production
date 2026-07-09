# Experiment 5: SSD 被误判为 HDD 取证

> 日期：2026-07-06 02:00

## 关键发现

### Ceph 介质类型
| 参数 | 值 | 含义 |
|------|-----|------|
| `bluestore_bdev_type` | hdd | Ceph 认为盘是 HDD |
| `bluestore_bdev_rotational` | 1 | Ceph 认为盘是旋转盘 |
| `rotational` | 1 | 整体标记为旋转盘 |
| RAID 卡 | PERC H730 Mini | 不透传介质类型 |

物理实测是 SSD（randread 4K IOPS=6542、avg lat=151us），但因 RAID 卡标记 ROTA=1，Ceph 误判。

### 关键参数（均为默认值，末手动调整）

| 参数 | hdd 值 | ssd 值 | 差异 |
|------|--------|--------|------|
| `bluestore_cache_size` | 1GB | 1GB | **相同** |
| `bluestore_max_blob_size` | 65536 | 65536 | **相同** |
| `osd_recovery_max_active` | 3 | 10 | SSD 恢复快 |
| `osd_delete_sleep` | 0 | 0 | 相同(override) |
| `osd_snap_trim_sleep` | 0 | 0 | 相同(override) |
| `osd_recovery_sleep` | 0 | 0 | 相同(override) |

### 磁盘拓扑
| 参数 | 值 |
|------|-----|
| `bluefs_single_shared_device` | 1 |
| `bluefs_dedicated_db` | 0 |
| `bluefs_dedicated_wal` | 0 |

### 结论

- **HDD/SSD 误判对 bluestore_cache_size 无影响**（两值均为 1GB）
- 误判主要影响 `osd_recovery_max_active`（3 vs 10），不影响写入路径
- **性能瓶颈主因不是介质误判**，而是 WAL/DB 与 Data 共享同一物理 SSD
- 因此实验 4（隔离 WAL/DB）是比实验 5 更应优先的验证方向
