# 性能分析（实测纠偏版）

> ⚠️ **2026-06 更新**：网络已升级，**100Mb/s 瓶颈已不存在**，
> 三台 Ceph 节点现在都是千兆；node1 已重装系统、OSD 盘改为 sdb。
> 本目录下"node1/node2 = 100Mb/s"的结论已过时，
> 以 **`03-env-change-2026-06.md`** 为准。

本目录是基于 **2026-06-08 实测数据**对原调优指南的纠偏与重构。

> 原 `doc/performance-tuning.md`（deepseek 初版）的瓶颈分析方向是错的：
> 它把 PD 时间戳 / TiKV block-cache 当主因，但实测证明瓶颈在 Ceph 后端，
> 根因是 **ceph-node1/node2 网卡只协商到 100Mb/s**。
> 原文档保留作为历史记录，请以本目录为准。

## 文档

| 文件 | 内容 |
|------|------|
| `01-measured-data.md` | 4 组排查命令的原始输出与数据汇总 |
| `02-bottleneck-analysis.md` | 决定性发现、理论上限计算、按收益排序的优化方向、正确的分析方法论 |
| `03-env-change-2026-06.md` | 千兆升级 + node1 重装后的环境变更与 node1 重新纳管步骤 |
| `04-multitask-finding.md` | 多任务并发测试：瓶颈在单 RGW/单链路而非并发度，指向加 RGW+LB |
| `05-progress-and-next-steps.md` | 调优进展总览 + 双 RGW 结果分析 + 后续瓶颈/调优方向 |
| `05_1-verify-ec-rmw-bottleneck.md` | 方向 D 验证步骤：用复制池对照确认随机 36MB/s 是 HDD+EC RMW 硬限制（步骤，未跑） |
| `06-conclusions-and-roadmap.md` | 阶段性结论汇总 + 瓶颈定性（已修正：磁盘是 SSD，瓶颈在 Ceph/EC 软件栈） + 路线图 |
| `06_1-ramdisk-wal-db-test.md` | WAL/DB 放内存盘验证（+4.8% 无效）；并确认磁盘实为 SSD |
| `06_2-ramdisk-cluster-test.md` | 全内存盘集群验证（106.6 MB/s 无提升）→ RAID 卡/SSD 均非瓶颈 |
| `06_3-cephfs-test.md` | CephFS vs JuiceFS 随机读写对比（CephFS 读 3.6×，无 FUSE 税） |
| `07-random-rw-optimization.md` | **（最新）** 随机读写专项：目标 59MB/s、随机读 3.8 瓶颈定位、框架内+换方案调优方向 |
| `results-table.md` | **各条件实测带宽总表（持续更新）**，新优化手段的测试结果追加于此 |
| `diag.sh` | 可复跑的逐层排查脚本（裸盘→网络→后端→端到端） |

## 一句话结论

瓶颈的本质（blktrace 实测坐实）：**Ceph 的 EC 拆片 + BlueStore 把用户的顺序大 IO
转成了碎片化、71% 需寻道的小 IO，而 HDD 最怕寻道**。软件侧已接近榨干，顺序吞吐天花板 ~102 MB/s。
要数量级突破，唯有让落盘 IO 不再受寻道惩罚——即 WAL/DB 上 SSD（对症、性价比高）或整盘换 SSD/NVMe（根治）。
