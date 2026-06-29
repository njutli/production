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
| `07-random-rw-optimization.md` | 随机读写专项：诊断（瓶颈在 RGW GET 延迟，非网络/介质）+ 框架内优化结果 |
| `08-next-steps-comparison.md` | 多方向规划（含 06-17 结论纠错区块：RGW 非瓶颈、根因=FUSE 读放大、`--max-downloads` 不存在；原规划保留作思路记录） |
| `08_1-direction3-result-direct-rados.md` | 方向三实测结论：去 RGW 直连 RADOS → RGW 非随机读根因，附下一步定位方法；**四之二：S3/RADOS/256K 三组 128G 全口径 REPEAT=5 多次重测复核（纯随机读 9.85 / 13.24 / 45.94 MB/s，256K 优势坐实）** |
| `08_2-abc-bottleneck-localization.md` | **（最新）** A/B/C 白盒定位 + 读放大验证 + 256K 全验收：根因=FUSE 4MB block 对 256k 随机读 ~16× 读放大；**block-size 4M→256K 使纯随机读 12.3→45.8 MB/s（3.7×，达目标 78%），顺序读写不降**，为生产可落地解（副作用：对象数理论×16，待精测）；附 fio bs-sweep / block-size-sweep / 256K 全验收三组实验+原始日志链接 |
| `09-blocksize-followups-todo.md` | **下一阶段调优工作总纲**：固化 08 系列三大结论（block-size 对齐 bs 随机读 4.7×、去 RGW 部分提升、顺序到顶+随机写达标）+ 已排除非瓶颈 + 随机读瓶颈层次；盘点 08 待办完成度；据"顺序已对齐后端裸能力"判定**下一阶段只聚焦随机读**，按优先级排：①rados bench 标随机读后端裸上限（必做、分叉点）②降残余放大/多客户端聚合（按验收口径）③256K 副作用精测定生产值 ④CephFS/BlueStore 备选 |
| `10-random-read-bottleneck-localization-plan.md` | 随机读瓶颈定位与提升计划（124 来历 / 2.5× 归因 / L1L2L3 分层 / 单客户端主线 / v1.3.1 保留 / 无效数据弃用） |
| `10_3-l1-rados-and-cache-compare-results.md` | L1 裸 RADOS 256K（放大 1.04× → 后端/EC 非放大源）+ §五 cache/预读 G1-G4 对比（16G 工作集，结论待 128G 复测修正）|
| `10_A-model-tuning-supplements-summary.md` | tun/ 三份模型（GLM5.1/5.2/qwen）调优补充的汇总+纠偏+候选清单（对照 10_3 标证实/证伪）|
| `10_A_1 / 10_A_2_3 / 10_A_4 / 10_A_7` | 候选清单各顺位验证结果：①FUSE 节流证伪 ②tcpdump/strace 分解（放大在 JuiceFS 内部、strace 2.60×、slice 碎片排除、元数据缓存证伪）④readahead/prefetch 关停 **128G 冷态证伪**（无改善+顺序写退化）⑦FUSE splice/max_read 系统不支持 |
| `10_issue-1-highconcurrency-randread-hang.md` | 高并发 fio 偶发起不来：非系统卡死/非 fio bug/非压力大，根因=前一个 fio 被 SIGKILL 后的残留污染 |
| `results-table.md` | **各条件实测带宽总表（持续更新）**，新优化手段的测试结果追加于此 |
| `diag.sh` | 可复跑的逐层排查脚本（裸盘→网络→后端→端到端） |

## 测试脚本（`tests/`）

| 脚本 | 用途 / 口径 |
|------|------------|
| `bench-juicefs.sh` | 全周期基准（顺序/随机/混合）；`WARMUP=1` 热态、`SKIP_LAYOUT/DO_LAYOUT_ONLY/SKIP_RANDWRITE` 复用开关 |
| `bench-rados-256k-rand.sh` | L1 裸 RADOS 256K 随机读（定位放大是否在 librados/EC 层）|
| `bench-cache-randread.sh` | 纯 randread 的 cache × 预读 G1-G4 对比（10_3 §五）|
| `bench-hot-multiround.sh` | **热态多轮带宽（验收口径，全程不 drop cache，自然预热）**：在大缓存 + 已有 128G 布局上连跑多轮 纯randread + randrw(9b 口径)，看 Run1→RunN 是否递增并稳定达标。**口径=热态/缓存命中，代表重复访问场景上限，非冷态真值**。⚠️ 当前**默认不带** `--max-readahead 0 / --prefetch 0`（依据 10_A_4 的 128G **冷态**证伪）；**待定点**：GLM 正在跑的 128G G4（开 cache + 关预读）若证明**热态**下关预读有效，则需补一个带预读关停的对照组 |

## 一句话结论

瓶颈的本质（blktrace 实测坐实）：**Ceph 的 EC 拆片 + BlueStore 把用户的顺序大 IO
转成了碎片化、71% 需寻道的小 IO，而 HDD 最怕寻道**。软件侧已接近榨干，顺序吞吐天花板 ~102 MB/s。
要数量级突破，唯有让落盘 IO 不再受寻道惩罚——即 WAL/DB 上 SSD（对症、性价比高）或整盘换 SSD/NVMe（根治）。
