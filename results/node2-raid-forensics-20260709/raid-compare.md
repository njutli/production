# 三节点 RAID 状态对比表

## 硬件
| 项 | node1 (.11) | node2 (.13) | node3 (.14) |
|----|-------------|-------------|-------------|
| RAID 控制器 | PERC H730 Mini (MegaRAID SAS-3 3108) | 同左 | 同左 |
| 驱动版本 | megaraid_sas 07.727.03.00-rc1 | 同左 | 同左 |
| OS 盘 (sda) | INTEL SSDSC2KB480G7 480GB | VK0480GDJXV 480GB | VK0480GDJXV 480GB |
| Ceph 盘 (sdb) | Micron M600 MTFDDAK1T0MBF 1TB | **同型号** | **同型号** |
| sdb 序列号 | 15120F0C60D3 | 15130F1CA71F | 160611C31D52 |

## SSD 寿命/健康
| 项 | node1 sdb | node2 sdb | node3 sdb |
|----|-----------|-----------|-----------|
| Power-On Hours | 14920 | 15986 | 13951 |
| Lifetime Remaining | 9% | 8% | **7%（最低但最快）** |
| SMART Status | PASSED | PASSED | PASSED |
| Program Fail Count | N/A | 0 | 0 |
| Erase Fail Count | N/A | 0 | 0 |

## 缓存策略
| 项 | node1 | node2 | node3 |
|----|-------|-------|-------|
| /sys/block/sdb/queue/write_cache | write through | write through | write through |
| /sys/class/scsi_disk/*/cache_type | write through | write through | write through |
| SCSI Mode Page 0x08 WCE bit | 0 (disabled) | 0 (disabled) | 0 (disabled) |

## 性能
| 项 | node1 | node2 | node3 |
|----|-------|-------|-------|
| 读速 (hdparm) | 390 MB/s | 406 MB/s | 405 MB/s |
| 写延迟 (iostat w_await) | 0.06 ms | **73 ms** | 0.06 ms |
| %util (300s 写) | ~50% | **100%** | ~50% |
| perf state_aio_wait_lat | 11.6 ms | **55.8 ms** | 7.3 ms |

## 结论
- **三节点硬件相同**（同 RAID 卡、同 SSD 型号、寿命相近）
- **三节点缓存策略相同**（OS 层 + SCSI 层全部 write through / WCE=0）
- **但 node2 写延迟 73ms vs node1/3 的 0.06ms（1216 倍差异）**
- node3 寿命最低(7%) 但写最快 → **不是 SSD 磨损问题**
- 读速三节点一致 → **不是物理盘问题**
- 差异在 **RAID 控制器内部缓存策略**（WriteBack vs WriteThrough），此设置在控制器固件层，SCSI/sysfs 看不到，需 perccli/storcli 查询（当前不可用）
