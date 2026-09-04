# 04-6 多流容量曲线与 04 阶段收尾裁决正式报告

```text
RUN_ID=20260903-214003
EVIDENCE_LEVEL=L1_SCREEN
MATRIX=PASS
RECOVERY_CONTRACT=PASS
OFFLINE_MECHANISM_REPAIR=PASS
NEW_PRODUCTION_TUNING_KNOB=NONE_FOUND
STAGE_DECISION=STAGE04_CONTINUE_DIAGNOSIS
```

## 一、执行结论

本 RUN 完成了任务书规定的三组最小容量曲线：`mseqread 8→16→8`、`mseqwrite 8→16→8`、
`randrw 64→128→64`。9 个 cell 的 fio、身份、健康、对象恢复和最终收口均通过；写组逐 OSD
compact 预算也符合任务书约束。

结果显示：

1. `mseqread` 在 8→16 流只增长约 6.8%；fio P50 未增加，但 P95 与 OSD 平均读操作延迟均有
   上升，表现为部分扩展，不能据此证明后端已达到架构上限。
2. `mseqwrite` 在 16 流吞吐反而下降约 5.5%，同时 P50 延迟约升至 4.2 倍。环境结束后仅从
   frozen raw 确定性补算机制证据：W02 六块 OSD 数据盘正式窗 `%util` P50 均为 100%，OSD
   完成服务率反降至两侧低档均值的 94.56%，曲线闭合为 `SERVICE_PLATEAU_IDENTIFIED`；没有
   重跑性能、改阈值或补造缺失值。
3. `randrw` 的 64 流回环漂移约 8.2%，超过预注册 5% 漂移门。读、写方向均独立出现相同趋势，
   因而只能记为证据不足；不得把两方向相加后作结论。
4. 未发现新的、明确位置、单变量、可回滚且保守预期收益不少于 5% 的现有生产配置旋钮。

严格按任务书裁决，mseqwrite 已在当前范围内闭合到共享 OSD 写服务平台，但 mseqread 仍为部分扩展、
randrw 又超过漂移门，因此阶段整体仍不能签署全部项目均 `ARCHITECTURE_LIMITED_IN_TESTED_RANGE`，
也不能打开 05 阶段；当前阶段裁决保持 `STAGE04_CONTINUE_DIAGNOSIS`。这表示剩余项目证据尚不足，
不表示已经发现了必然有效的下一项调优。

## 二、固定条件与证据范围

测试使用 exact patched v1.4.1、无本地缓存和固定挂载参数：

```text
JuiceFS binary: /tmp/juicefs-1.4.1-patched
mount: --max-uploads 150 --cache-size 0 --max-fuse-io 256K
client Ceph config: 私有 msgr_async_op_threads=8 配置，系统 ceph.conf 未修改
formal window: [15,175) seconds of each 180-second fio cell
PG health: 97/97 active+clean；HEALTH_WARN 仅来自主动设置的 noscrub,nodeep-scrub 标志
```

本地持久化证据根目录：

```text
/mnt/c/SunRise/test/04-6/20260903-214003/opencode-04-6-20260903-214003/
```

重要索引：

| 证据 | 路径 |
|---|---|
| 运行阶段与最终 PASS | `execute/phases.tsv`、`execute/console.log` |
| 每 cell 原始 fio 与参数 | `cells/{R01,R02,R03,W01,W02,W03,M01,M02,M03}/fio.txt`、`command.txt`、`fio.rc` |
| 每秒带宽原始日志 | 各 cell 的 `bw/` |
| fio 结束时间与延迟摘要 | 各 cell 的 `fio-end-ns.txt`、`latency.tsv` |
| OSD 计数器与队列 | 各 cell 的 `sampler/osd-perf.tsv` |
| JuiceFS、TiKV 原始采样 | 各 cell 的 `sampler/raw/*.txt.keys`、`sampler/tikv/*.prom.key` |
| Ceph/客户端/NIC/磁盘采样 | 各 cell 的 `sampler/ceph-health.tsv`、`client-host.tsv`、`nic.tsv`、`iostat/` |
| 写组 compact 审计 | `execute/compact-audit.tsv` |
| 对象恢复 | `execute/quiet-PRE/`、`quiet-R-GROUP/`、`quiet-SEED/`、`quiet-W01/`、`quiet-W02/`、`quiet-W03/`、`quiet-M01/`、`quiet-M02/`、`quiet-M03/` |
| GC/恢复日志 | `execute/gc-*.log`、`execute/pool-final.tsv` |
| frozen raw机制修复 | `cells/W02/mechanism.json`、`cells/R02/mechanism.json`、`analysis-postmechanism.json` |

证据包与本地校验值：

```text
04-6-20260903-214003-evidence.tar.gz
SHA256=742ae150c6206345e48fc14a796de94b96f5fcfc148d8bbd0c14f60393e0e9be
```

归档完成后新增的文件均为 frozen raw 的确定性离线派生物，不属于上述原始归档本体：

```text
t04-6-mechanism-repair.py  dda73ee191b3252fc4ded2fd00500f57379aa9c1a62524ae16ca5c059fca4259
W02/mechanism.json         562bca4271a29141fe3d86453f47d4ecf12a3fdfa495db3dbac2117e1510d231
R02/mechanism.json         2043703496d4aca1580fde5f9dcdbc91b613ffc1428aca6f1b9751f9c25ffe46
analysis-postmechanism.json 411f870555952cf5b9054b0167960dc7f25a6376e5e89676f7053143427905e7
```

## 三、矩阵和恢复合同

阶段文件记录如下：

```text
PHASE_I PASS
NORMALIZE PASS, O0=1,978,606 objects
R_GROUP PASS, returned O0
SEED PASS, O1=2,240,750 objects
W_GROUP PASS, returned O0
M_GROUP PASS, returned O0
PHASE_II PASS
```

一次性 mseqwrite seed 为 16 个固定 4 GiB 文件；W03 后按 manifest 精确删除。每个 OSD 的 compact
预算满足设计：本次修复 RUN 执行 5 次/OSD，叠加先前失败 RUN 的 W01 compact 1 次/OSD，累计为
6 次/OSD，没有追加超预算操作。对象数量在 M01、M02、M03 收口均为 `1,978,606`。

因此，以下性能数据是本 RUN 可追溯的容量观察；各组曲线能否解释，仍须分别通过下文的
漂移和机制门。对象数量回归不等于 TiKV/RocksDB 运行时状态完全回归，`randrw` 的回环问题
正体现了这一点。

## 四、性能结果（正式窗 `[15,175)`）

### 4.1 mseqread

| Cell | 并发 | 正式窗均值 MiB/s | CV | W4/W1 | fio P50 |
|---|---:|---:|---:|---:|---:|
| R01 | 8 | 4384.27 | 1.33% | 1.0067 | 151 µs |
| R02 | 16 | 4686.99 | 1.85% | 1.0300 | 143 µs |
| R03 | 8 | 4392.77 | 1.55% | 1.0268 | 151 µs |

```text
anchor_drift = 0.194%
scale_ratio = 1.0680
scale_efficiency = 53.4%
P50 latency ratio = 0.947
status = PARTIAL_SCALING
```

16 流仅比两侧 8 流均值高约 6.8%；同时 fio P95 由约 `2.15 ms` 升至 `4.95 ms`，OSD 平均读操作
延迟由约 `0.37 ms` 升至 `0.58 ms`，但预注册的 fio P50 并未上升。因此它仍不满足“服务率平台 +
预注册延迟/队列增长”的架构闭环条件。该组没有 `mechanism.json`，也不能把结果写成 Ceph/OSD
后端墙；尤其不能忽略当前读路径可能受客户端/FUSE/对象请求路径共同影响。

### 4.2 mseqwrite

| Cell | 并发 | 正式窗均值 MiB/s | CV | W4/W1 | fio P50 |
|---|---:|---:|---:|---:|---:|
| W01 | 8 | 4064.31 | 3.11% | 0.9706 | 3621 µs |
| W02 | 16 | 3853.67 | 1.92% | 0.9718 | 14091 µs |
| W03 | 8 | 4090.14 | 4.15% | 0.9554 | 3064 µs |

```text
anchor_drift = 0.636%
scale_ratio = 0.9452
scale_efficiency = 47.3%
P50 latency ratio = 4.216
status = SERVICE_PLATEAU_IDENTIFIED
```

OSD 计数器在正式窗的聚合平均写延迟约为：W01 `7.04 ms`、W02 `7.57 ms`、W03 `6.93 ms`。
离线生成器按 `fio-end-ns - run_ms`重建每个 cell 的 I/O 起点，只选`[15,175)`内采样：W02 共
`16 epoch × 3节点 × 2块OSD盘 = 96`个 `%util` 观测，范围`99.6%--100.4%`，六块盘各自及总体
P50均为`100.0%`。六OSD完成率由正式窗内累计计数首末差分得到：W01/W02/W03分别约为
`16242/15403/16334 op/s`和`4060.6/3850.7/4083.5 MiB/s`，W02相对两侧低档均值均为
`0.94565×`。结合低档漂移`0.636%`及fio P50延迟比`4.216×`，满足任务书的服务率、排队和
组件硬饱和三门，故更正为`SERVICE_PLATEAU_IDENTIFIED`。

该修复只证明当前硬件、EC4+2拓扑、无缓存语义和8→16流范围内的六OSD数据盘写服务平台；它没有
产生新的在线生产旋钮，也不得外推成跨硬件、跨拓扑的数学上限。

### 4.3 randrw（读写分开）

| Cell | 并发 | READ MiB/s | WRITE MiB/s | READ P50 | WRITE P50 |
|---|---:|---:|---:|---:|---:|
| M01 | 64 | 1554.71 | 1556.35 | 651 ms | 659 ms |
| M02 | 128 | 1756.77 | 1757.03 | 1133 ms | 1133 ms |
| M03 | 64 | 1426.69 | 1428.34 | 676 ms | 676 ms |

```text
READ  anchor_drift = 8.234%, scale_ratio = 1.1785, latency_ratio = 1.708
WRITE anchor_drift = 8.225%, scale_ratio = 1.1774, latency_ratio = 1.697
status = INCONCLUSIVE_DRIFT (READ)
status = INCONCLUSIVE_DRIFT (WRITE)
```

高并发相对低并发的延迟和服务率信号是明确的，但因低并发回环超过 5% 门，不能将该曲线作为
稳定的扩展效率或架构平台证据。

## 五、机制观察与 randrw 回环漂移

### 5.1 共享组件观察

客户端 NIC 在正式窗约为：

```text
mseqread RX: 4.33--4.73 GiB/s
mseqwrite TX: 3.79--4.16 GiB/s
randrw M01/M02/M03 RX: 1.77/2.06/1.78 GiB/s
randrw M01/M02/M03 TX: 1.74/2.03/1.76 GiB/s
```

randrw 三组 TiKV 节点的 `/mnt/jfs-tikv` 对应 `nvme1n1` 在正式窗中基本处于 98--100% util；
OSD 聚合计数器也显示 M02 相对 M01/M03 具有更高的读写操作服务量和明显更高的平均操作延迟：

```text
M01: op_r≈14.2k/s, op_w≈7.0k/s, OSD avg r/w≈0.73/3.56 ms
M02: op_r≈16.5k/s, op_w≈9.3k/s, OSD avg r/w≈1.27/6.82 ms
M03: op_r≈14.3k/s, op_w≈9.2k/s, OSD avg r/w≈0.67/3.03 ms
```

这些数据与高并发时共享后端排队/服务率受压相符；但相关性不等于已找到可生产旋钮，且randrw
自身仍被8.2%回环漂移硬门否决，不能用W02的机制文件替它完成§4.3/§6闭环。

### 5.2 8.2% 回环漂移的最合理解释

M01 与 M03 的对象数都回到 `O0=1,978,606`，因此漂移不是简单的对象数量未清理。可是 M02
高并发后 TiKV/RocksDB 的运行时状态没有被对象回归完全重置：

- M02 期间 `tikv_scheduler_pending_compaction_bytes` 达到约 `300--325 MB`；
- M03 开始时该指标仍约 `305--307 MB`；
- M03 期间 `tikv_engine_pending_compaction_bytes` 增长到约 `2.5/8.7/7.4 GB`（150/151/152）；
- TiKV NVMe await 中位数由 M01 的约 `0.5--0.9 ms` 上升到 M03 的约 `1.9--3.2 ms`。

因此，当前最合理的归因是：M02 造成 TiKV/RocksDB compaction debt、NVMe 队列和后台运行
状态积累；即使 GC/对象数量回到了 O0，服务运行状态仍未回到 M01 的起点，导致 M03 低并发
带宽下降约 8.2%。该归因仍应标为“强相关证据”，而不是已完成的独立因果实验。

## 六、现有生产旋钮与阶段裁决

本 RUN 未发现满足以下全部条件的新候选：位置明确、存在单变量可回滚配置、可生产、保守材料
收益不少于 5%，且没有被此前实验排除。

已知方向中，readahead、max-uploads、compaction worker/限速、同盘逻辑分离、继续增加 inode、
主动清理等均已有前序结论或不符合本任务的生产交付边界；Primary 均衡和缓存/writeback 也已
作为独立专项或条件性配置处理，不能由本 RUN 重新宣称为新候选。

严格裁决：

```text
mseqread  = INCONCLUSIVE_CONTINUE_DIAGNOSIS
mseqwrite = ARCHITECTURE_LIMITED_IN_TESTED_RANGE (curve=SERVICE_PLATEAU_IDENTIFIED)
randrw    = INCONCLUSIVE_CONTINUE_DIAGNOSIS
STAGE04   = STAGE04_CONTINUE_DIAGNOSIS
```

不能把mseqwrite在当前范围内识别出的六OSD写平台或“randrw NVMe/TiKV相关性”夸大为跨架构数学
上限；同样也没有理由因为这次容量曲线而追加参数臂或重跑全量基线。阶段若继续，只剩两个相互
独立的最小缺口：

1. mseqread目前只能保留`PARTIAL_SCALING`；现有raw没有P50/队列`≥1.60×`或资源`≥90%`硬证据；
2. 如果仍需闭合`randrw`，另立最小的固定并发状态漂移归因，不重跑04-6九格矩阵，不增加参数臂。

若不继续上述定点诊断，则应将本 RUN 的曲线、漂移和未闭合项归档，并把“需要改变代码、硬件、拓扑、
缓存或持久性语义”的方向登记到阶段外 TODO。

## 七、生命周期与安全收口

本 RUN 使用专属第二挂载，未改动 `/mnt/juicefs`，未改变系统 `ceph.conf`，未触碰生产进程、
pool/PG 拓扑或块设备；主动暂停的 scrub 标志在流程结束后恢复。写 seed 文件按 manifest 精确
删除，对象回归和 TiKV/Ceph 健康门通过。远端结果在本地持久化后，才允许按生命周期策略清理
远端临时目录；本报告只引用 `/mnt/c/SunRise/test/04-6/20260903-214003/` 持久副本。
