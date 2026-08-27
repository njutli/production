# 03-22b 任务书：TiKV NVMe-backed A1/B1 逻辑隔离与条件 C 归因

## 日期与状态

- 日期：2026-08-26～27
- 面向：GLM 执行；GPT/用户分阶段签收
- 上游：`03-22-tikv-ram-block-storage-isolation-ab.md` 及其正式报告
- 当前状态：**执行、失败闭包、生产恢复和归档均已完成；正式分类为 `EVIDENCE_INVALID`**
- 最终进度：R01/A1、R02/B1通过；R03/B1因正式窗CV=`10.701303%`触发预注册硬门，R04--R08未运行；不得补跑或拼接本RUN
- 当前允许动作：只读复核归档、离线分析和文档更新
- 当前禁止动作：复用RUN_ID `20260826-164047`继续任何环境操作；03-22c必须另开RUN和维护授权
- 正式报告：`doc/perf-report/03-22b-tikv-nvme-backed-storage-attribution-20260827.md`
- 原始归档：`results/prod-stage03-raw-20260827/opencode-t3.22b-20260826-164047.tar.gz`，SHA-256=`7cd9e57276a19b2ee17966b369bc3a0fac75da3869582ae226689b8e225ac137`

> 03-22 的环境生命周期已经结束，但正式矩阵因 R05 本地容量合同失效而判为 `EVIDENCE_INVALID`。03-22b 使用新 RUN_ID，是独立实验，不是对 R05 的补跑。

```text
03-18  单 inode 排队 + 同步 TiKV transaction 周期
  ↓
03-19  256 inode 只带来方向性增益，随后撞共享 TiKV 写路径
  ↓
03-20  前台同步提交与 compaction 争用每节点唯一 TiKV NVMe
  ↓
03-21  无三节点对称 spare NVMe
  ↓
03-22  RAM A/B：R01--R04 稳定，R05 因本地目录累积而整 RUN 无效
  ↓
03-22b Gate 0 → canary + immutable seed → A1/B1正式矩阵
  ↓
R01/R02 PASS；R03 CV硬门失败 → R04--R08停止
  ↓
invalid closure → 恢复生产 → 原始证据归档       ← 已完成
  ↓
03-22c：同窗B1c/D1物理路径探针；条件C仍独立
```

一句话目标：在不改生产 TiKV 数据、配置和 systemd 的前提下，用同一物理 NVMe 上的 NVMe-backed loop/ext4 对照，判断独立 block/filesystem/上层 worker 路径能否稳定改善 256-inode randwrite。

---

## 〇、背景与 03-22 教训

03-22 的部分工程数据中，RAM-A 为 `3699.30 MiB/s`、RAM-B 为 `3716.64 MiB/s`，B/A 只有 `+0.47%`；相对历史生产 H 的约 `2880 MiB/s`，两臂则高约 28%--29%。这只能说明“fresh 临时 TiKV + RAM 介质 + 临时集群起点”的组合改善明显，不能判断改善来自 fresh RocksDB 状态还是介质，也不能用 RAM 上的小 A/B 差异否定真实 NVMe 延迟下的逻辑隔离。

R05 同时证明：新的 namespace、data-dir 名字或进程并不等于 fresh 本地存储。B 的 32 GiB WAL/Raft 文件系统保留 R02/R03 目录后，R05 起点只剩约 6--9 GiB，最终达到 94%--98%，触发 `AlmostFull/AlreadyFull`、EIO 和采集窗口失配。03-22b 因此把“每 arm 前重建精确 loop 上的 ext4、验证空基线”升级为正式变量合同，而不是依赖目录清理。

当前每个 TiKV 节点只有一块生产 TiKV 盘 `/dev/nvme1n1`，另两块 NVMe 属于 Ceph OSD，不得借用。03-21 只读盘点时 `/mnt/jfs-tikv` 每节点约有 791.94--791.99 GiB 可用；该值只是历史参考，必须在本任务 Phase I 重新采集，不能据此直接创建文件。

---

## 一、目标、问题层级与推断边界

### 1.1 唯一正式因果问题

在相同主机、相同物理 `/dev/nvme1n1`、相同临时 TiKV 配置、相同 Ceph pool、相同 immutable seed/clone、相同 256-inode randwrite 下：

> B1（KV 与 WAL+Raft 位于两个独立 loop/ext4）是否稳定、材料性优于 A1（KV/WAL/Raft 共用一个 loop/ext4）？

A1/B1 都把 backing file 放在同一个生产 TiKV ext4 上，因此 B1 测的是 Linux 通用块层以上的 loop、文件系统和相关 worker/queue 的逻辑隔离；它不是物理介质、控制器或 PCIe 隔离，报告不得写成“分盘”。

### 1.2 同时报告但不作为 A1/B1 通过门的问题

1. B1 四臂中位数是否达到 `6250 MiB/s`；
2. A1/B1 分别相对历史 H、03-22 RAM-A/RAM-B 的方向和量级；
3. `W4/W1`、逐秒 CV、TiKV transaction/storage/Raft 延迟、各 loop 与底层 NVMe 的 await/queue/util；
4. 若 B1 仍未达目标，量化还差多少，并判断剩余约束是否仍为 per-inode 同步周期、物理 NVMe 队列或 Ceph 数据面。

历史 H 和 RAM-A/B 都是跨阶段工程参照，不能与本轮随机化 A1/B1 使用同一因果措辞。03-22 整 RUN 已失效，RAM-A/B 只允许标为“R01--R04 部分观察”。

### 1.3 条件 C 的定位

C 定义为：**fresh 临时 TiKV 直接使用生产 `/mnt/jfs-tikv` 原生 ext4 下的精确作用域目录，KV/WAL/Raft 共享该文件系统，不经过 nested loop/ext4**。生产 TiKV 必须停止，临时目录绝不复用生产数据目录。

C 不进入本轮 A1/B1 八臂，也不在当前授权范围内。A1/B1 完成并恢复生产后，只有 GPT/用户认为仍需区分以下因素时，才另开新 RUN_ID、独立维护窗口和独立脚本审查：

| 比较 | 能回答 | 不能回答 |
|---|---|---|
| A1↔B1 | 同一物理 NVMe 上的逻辑 block/filesystem 隔离 | 物理分盘收益 |
| C↔A1 | 原生 ext4 与 nested loop/ext4 的工程差异 | 历史 RocksDB 状态单因素 |
| H↔C | fresh 临时集群在原生共享 NVMe 上相对历史生产状态的组合差异 | 严格的 fresh-only 因果效应 |
| RAM-A↔A1 | RAM 与 NVMe 的方向性差异 | 同日随机化介质效应 |

C 必须在 A1/B1 正式报告后重新决定，不能为了“矩阵完整”自动执行。

---

## 二、冻结变量与正式矩阵

### 2.1 新 RUN 与保护对象

- 新 RUN_ID 格式固定为 `YYYYMMDD-HHMMSS`，不得复用 `20260825-163811`。
- 节点仍为 `10.20.1.150/151/152`；一次只允许一个临时 PD/TiKV 集群。
- 临时端口、cluster token、data dir 必须与生产和 03-22 历史实例不同，并在 Gate 0 写死作用域。
- 生产 TiKV data/WAL/Raft 路径、配置、systemd unit、二进制和 `/mnt/jfs-tikv` mount 全程只读保护；生产 PID 在批准的 stop/start 后必然变化，不能误用“PID 不变”门，须改验 unit/config/exe/mount/data-path 指纹不变。
- 生产 PD 保持运行；生产 TiKV 与任何临时 TiKV **绝不并行**。

### 2.2 本地存储臂

每节点同时预分配 A1/B1 backing set，总逻辑和实际预分配量为 256 GiB：

| 臂 | backing file | loop/ext4 | TiKV 路径 | 总量 |
|---|---|---|---|---:|
| A1 | `a1-shared.img` 128 GiB | 1 个 | KV、RocksDB WAL、Raft Engine 共用 | 128 GiB |
| B1 | `b1-kv.img` 96 GiB + `b1-logs.img` 32 GiB | 2 个 | KV 独立；WAL+Raft 共用 logs | 128 GiB |

backing 根固定为 `/mnt/jfs-tikv/jfs-t65-<RUN_ID>-backing`，loop mount 根固定为 `/mnt/jfs-t65-<RUN_ID>`。脚本必须验证 RUN_ID 正则、`realpath -m` 精确等于期望值、父文件系统 source 是当前节点 `/dev/nvme1n1`、路径不是 symlink、与生产 data/WAL/Raft 路径无前缀交叠。

临时 PD 不进入 A1/B1 变量：每节点固定使用一个 8 GiB tmpfs。每个 arm/seed/GC 实例 activate 时重新 mount 空 tmpfs，mount 后再把根目录精确改为冻结的临时运行 UID:GID；实例 stop 后 deactivate 并卸载，不跨实例保留 PD 目录。Phase I 必须核对三节点临时运行用户的数字 UID:GID 一致（03-22 为 `1001:1001`，本任务重新实查后冻结），并要求 `MemAvailable ≥64 GiB`；不得把 PD data 放到生产 NVMe、系统 `/tmp` 或未声明路径。

必须使用实际预分配的 `fallocate`；禁止 sparse `truncate`、`dd`、`cp --sparse`。创建后逐文件核对 `stat` logical size、`stat %b×512` 实际块数及 `du -B1`，实际分配不得显著小于逻辑大小。

### 2.3 每 arm 重建本地文件系统

backing file 在整个 A1/B1 矩阵中保留，但每个正式 arm 前必须：

1. 证明上个临时 TiKV/PD 已停止、无 holder/open fd、上个 loop 已精确 detach；
2. 动态关联当前臂的唯一 backing file，核对 `/sys/block/loopN/loop/backing_file`；
3. 用 `mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0` 重建 ext4，防止 mkfs discard 把预分配 backing file 打洞；
4. 以 `noatime,nodiscard` mount，核对 source、FS UUID、owner、容量；
5. 再次核对 backing file 的 allocated blocks 未减少，冻结该次 fresh-FS baseline 后才创建当前实例目录。

这样每个 arm 都从确定性空文件系统开始，不执行 `rm -rf`，也不让旧 TiKV 目录跨 arm 保留。`mkfs` 是破坏性操作，必须由单独脚本、精确 loop/backing 身份和当前 arm token 保护；不得把它藏进 cluster start 或失败 trap。

### 2.4 JuiceFS/Ceph/workload

| 项 | 冻结值 |
|---|---|
| JuiceFS | `/tmp/juicefs-03-8`，MD5 `de93563f11a5ff3bd94dd25a4e0283b1`；执行前复核 version/MD5 |
| mount | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；私有 Ceph conf 固定 `ms_async_op_threads=8` |
| Ceph | 同一 `juicefs-data` pool、同一 6 OSD；禁止 pool delete/create、PG/CRUSH 变更、OSD restart |
| seed | 本 RUN 只 layout 一次：256 文件 × 1 GiB，正式 active extent 合计 128 GiB |
| arm 工作集 | 每 arm 向 fresh metadata namespace load 同一 dump，再从 immutable `/seed_layout` clone 到 `/test_dir` |
| fio | randwrite，256 KiB，256 job/256 inode，iodepth 64，runtime 180s，固定 jobfile/offset/seed |
| 正式窗 | 实际 I/O 起点后 `[15,175)`；W1--W4 各 40 秒 |
| 统计 | 256 个 per-job BW log 按重叠时长对齐求和；正式窗中位数；不使用 fio 进程 fork 时刻冒充 I/O 起点 |

不得每轮 layout、不得覆盖 seed source、不得用 `create_on_open`，不得修改 03-22 的历史测试数据集。新 RUN 使用新卷名和新 metadata namespace；Ceph 对象由本 RUN 的 seed/clone/GC 合同管理。

### 2.5 正式顺序和配对

```text
R01=A1, R02=B1, R03=B1, R04=A1,
R05=B1, R06=A1, R07=A1, R08=B1
```

相邻配对固定为 `(R01,R02)`、`(R03,R04)`、`(R05,R06)`、`(R07,R08)`；每对效应为 `100×(B1-A1)/A1`，不因结果好坏改配对。每个 Rxx 后必须完成 fresh-seed GC return、OSD cooldown、本地文件系统重建回归，前一轮未闭环不得启动下一轮。

### 2.6 预注册判据

A1/B1 正式结论成立的前提：8/8 arm 全部满足证据门，禁止用补跑替换坏臂。

| 判据 | 阈值 | 数据源 |
|---|---:|---|
| arm 内逐秒 CV | `≤10%` | analyzer 的 `[15,175)` 聚合 BW 秒序列 |
| 轮内衰减 | `W4/W1 ≥0.90` | 同一正式窗四个 40 秒中位数 |
| 正式覆盖 | 160/160 秒且 256/256 logs | `fio-io-start.tsv`、coverage report、全部 `*_bw.*.log` |
| 本地容量 | 全程所有 role `<70% used` 且 `avail ≥8 GiB` | 各节点 1 Hz `df -B1`，按 mount UUID 分组 |
| TiKV disk status | 全程 `Normal`，不得出现 `AlmostFull/AlreadyFull` | PD store status + TiKV log |
| local reset | 下一 arm 前无旧实例目录，fresh-FS used/avail 回到本次 mkfs baseline ±256 MiB | `storage-baseline.tsv`、`findmnt`、FS UUID、目录 manifest |
| seed return | leaked/pending/skipped=0，valid/compacted 等于 seed，pool objects 回 seed ±8192 | GC summary、三次 pool sample |
| 服务/环境 | Ceph HEALTH_OK，生产指纹只发生已授权 stop/start | health/fingerprint snapshots |

材料性提升门：四个配对中至少 3 个 `B1>A1`，且四配对效应中位数 `≥15%`。全部证据门通过但未达到该门，结论写为“同一 NVMe 上的逻辑隔离没有可辨识的材料收益”，不是“物理分盘无效”。

目标门独立报告：B1 四臂中位数 `≥6250 MiB/s` 才算达到网卡半速。达到材料性提升但未到 6250，必须继续给架构缺口；达到 6250 但稳定门失败，也不得签收。

---

## 三、容量与稳定性硬合同

### 3.1 backing 创建前容量门

在每个节点上，Phase I 必须重新读取 `df -B1 -T /mnt/jfs-tikv`。同时保留 A1+B1 两套 backing 需要实际预分配 256 GiB；创建前必须满足：

```text
Avail_pre >= 256 GiB planned allocation + 512 GiB production reserve
          >= 768 GiB
```

三节点任一低于 768 GiB，整任务停止，不得缩小 reserve、改用 sparse file、只做部分节点或临时删除生产文件。创建后再次要求 `Avail_post ≥512 GiB`。03-21 的约 792 GiB 只表示方案可能可行，不替代本门。

### 3.2 B1 32 GiB logs 的额外门

03-22 单臂历史增量约可达 11--13 GiB。B1 每次 mkfs 后必须满足：

- logs fresh baseline 可用空间 `≥28 GiB`；
- 无任何上个实例目录；
- canary 实测 peak growth 加 1 GiB 后的两倍不超过 fresh free；
- 运行中 used 达 70% 或 available 低于 8 GiB 时，runner 向 fio 发 TERM、保留现场并标 `CAPACITY_SAFETY_ABORT`，不得等到 TiKV EIO。

容量安全停止不会变成“可剔除坏点”；命中即本 RUN 正式证据无效，清理后回到任务设计层。

### 3.3 采集生命周期

sampler 不能再固定运行 300 秒后自行退出。每个 sampler 必须由独立监督器保持到 fio 退出后至少 30 秒，并有不短于 900 秒的总 watchdog。状态必须区分：

- `SAMPLER_EXIT_AFTER_FIO`：正常；
- `SAMPLER_CRASH`：采集器先于 fio 异常退出；
- `FIO_WATCHDOG_TIMEOUT`：fio 超过总时限；
- `CAPACITY_SAFETY_ABORT`：容量门主动终止。

只有正常类型可以进入 analyzer。实际 I/O 起点从 256 个已落盘 BW logs 的首个有效时间和 flush mtime 反推并校验 spread；不得从 shell fork epoch 或 sampler start 猜测。

### 3.4 避免新增波动源

- 每个正式 arm 前都重新 mkfs 同臂 loop，A1/B1 对称执行；不用目录删除是否完整作为 fresh 判据。
- ext4 关闭 lazy inode/journal 初始化；mkfs/mount 后采样底层 NVMe 60 秒，只用最后 30 秒执行预先冻结的 bounded-idle gate：每个样本 `inflight=0`、累计 completed writes 不超过 256、累计 written sectors 不超过 8192（4 MiB）、任一秒 sectors 增量不超过 2048（1 MiB）。这是允许 ext4/kernel 微量后台回写的有界静置，不要求块设备计数器绝对不动；阈值不得按正式结果临时调整。
- fresh ext4 baseline 是 `used/free` 几何参考，不是 UUID 恒等契约：每次 mkfs 生成新 UUID 是预期行为，当前 `used` 与 `free` 分别相对参考值漂移不超过 256 MiB才通过。第二次无效 canary 留下的 baseline 可继续作为结构证据，因为它在 TiKV 启动和 fio 前生成且不含性能结果；其 UUID 只留作审计，不要求后续复用。
- 两套 backing 在整个矩阵只预分配一次；不得每 arm 重复 fallocate/unlink，避免生产 ext4 的反复分配和碎片变化。
- 不活跃臂必须 unmount 并 detach loop；不得让后台 ext4 初始化或旧 TiKV 进程并行。
- 全矩阵只 layout 一次；ABBA/BAAB 抵时间漂移，immutable seed 抵 layout lottery。
- `msgr=8` 下只采 active-only worker CV 作为协变量，不使用未标定阈值自动重挂或剔除 arm。

### 3.5 SEED-CANARY prepare 一次性证据修复（2026-08-27 预注册）

`RUN_ID=20260826-164047` 的 `SEED-CANARY/A1` 第一次且唯一一次 prepare 已完成 Ceph 健康、六 OSD pre/post cooldown、JuiceFS `gc --compact`、三节点 TiKV pending 连续三次为零和三节点 60 秒 NVMe 采样，但当时远端旧版 `t65-reset-gates.sh` 错误使用“最后 30 秒写计数绝对不变”判据，在写入正式结果前终止。冻结的三份 raw SHA256 分别为 `a37ae75...a542`、`86cb8ea1...e2c3`、`f0ece41c...b8c4`；旧远端包内已经签名的 `t65_nvme_quiet_evidence_ok` 按本任务 3.4 节预注册阈值复算均通过，结果为 `writes=120/96/115`、`sectors=1384/1304/1328`、`max_step=208/144/152`、`inflight=0`。

因此允许仅对此固定 RUN/实例执行一次独立证据修复，但必须满足：旧远端 manifest、common、volume/layout/anchor、21 个原始 reset 文件及其关键 SHA 全匹配；原 prepare 授权记录恰好一次；当前 mount worker/source anchor、三 TiKV endpoint 和 Ceph HEALTH_OK；仍无 `READY_FOR_FIO`/`pool-ready.tsv`。修复脚本只能用旧包 common parser重验原始 raw，写独立 repair manifest、当前 pool 快照、`PREPARE_EVIDENCE_REPAIR_PASS` 和 `READY_FOR_FIO`，不得重跑 compact/GC/prepare，不得执行 fio、mount/umount、loop/backing、服务或生产状态操作，也不得热同步旧 bundle。任一条件不符即保留现场；该例外不适用于后续实例，后续必须使用已离线修复并重新 Gate 0 的完整新包。

### 3.6 RESTORE-PREFLIGHT-A1 clone inode 合同修复（2026-08-27 预注册）

`RUN_ID=20260826-164047` 的 `RESTORE-PREFLIGHT-A1` 首次且唯一一次 `juicefs clone -p` 已成功创建256个target文件，source/target的path、size、256 KiB content anchors全部与formal seed一致，source与target各有256个唯一inode且两集合零重叠，Ceph pool objects/stored前后不变；但旧版`verify_formal_clone_semantics`额外要求冻结seed reference inode集合与本次restore source inode集合零重叠。JuiceFS dump/load实际保留immutable source inode，因此观测为`reference_overlap=256`，脚本在clone命令之后以rc=42退出，未生成`CLONE_PASS/LAYOUT_PASS/formal-clone-contract`。该额外门不属于本任务因果合同：reference/source inode是否复用只作诊断，硬门只要求reference/source/target各自唯一以及当前source/target零重叠。

允许仅对此固定RUN和`RESTORE-PREFLIGHT-A1/A1`执行一次独立clone evidence recovery。由于当前mount、临时TiKV和A1 loop仍在使用旧签名包，`t65-sync-scripts.sh`的quiescent合同必须拒绝热更新；恢复时不得替换活动bundle。必须先离线修改正式脚本、增加“reference/source全重叠应通过、source/target任一重叠应失败”的Gate 0夹具并更新下一版manifest，同时另写固定RUN/实例、固定旧manifest和旧脚本SHA的一次性恢复脚本。恢复脚本只能部署到157独立recovery路径，先`inspect`后用独立token执行一次：核对原clone授权恰好一次、commands.sh中唯一clone命令、clone stdout/stderr均为零字节、无成功marker/正式合同、原始及当前source/target manifests与anchors完全一致、mount PID/starttime/META/MNT、seed bundle SHA和三节点服务身份未变；冻结的post-clone pool快照仍是因果基线，但活跃mount数小时后的共享pool只要求绝对漂移不超过64 objects、16 MiB stored和32 MiB used，并记录全部delta，超过任一界限即硬失败。随后只读重算现场证据并生成首次formal clone contract/jobfiles/markers，不得再次执行clone、load、mount、fio、GC、服务或存储操作。A1按旧活动包优雅闭合并完全quiescent后，才允许用更新后的正式manifest执行三节点resync；任一证据不符即保留现场并判本恢复不可用。

### 3.7 ARM-CANARY-B1稳定性诊断与正式门边界（2026-08-27，R01前冻结）

`ARM-CANARY-B1`按预注册用途完成了容量校准：180秒fio和全部sampler正常，logs最大available drop为`13,523,947,520` bytes，三节点均满足`2×(peak+1 GiB)≤fresh free`。该canary的非正式带宽为`3660.13 MiB/s`、CV=`8.21%`，但`W4/W1=0.861`，低于正式门0.90。同步采集显示三节点底层同一块`nvme1n1`的中位`w_await`从W1约`1.93--2.36 ms`升至W4约`7.94--16.65 ms`，`aqu-sz`从约`23.74--32.38`升至`48.40--107.18`；这与运行中TiKV写放大/compaction逐步加重同一物理NVMe排队一致，但仅是诊断性推断，不足以区分A1/B1，也不得当作正式性能结论。

该观察不触发结果后调参：正式runtime、`[15,175)`窗口、CV和`W4/W1`阈值、ABBA/BAAB顺序均保持不变，也不得新增或补跑canary来筛选有利起点。R01仍按冻结状态机执行；任一正式arm（包括R01）未满足稳定门即整RUN标记`EVIDENCE_INVALID`并停止后续arm，不能因为容量canary被定义为非正式而放宽正式门。若正式矩阵通过，则canary轨迹只作为“共享物理NVMe可能仍形成公共排队瓶颈”的协变量；若正式arm因同类衰减失败，则进入架构稳定性归因，而不是用补跑替换坏臂。

---

## 四、维护窗口与系统安全边界

### 4.1 生产维护前置

本任务会停止三节点生产 TiKV，属于服务中断操作，必须由用户对完整 stop plan 单独明确授权。授权前只允许只读 inventory/plan。

维护开始前必须证明：

1. 业务方已确认 JuiceFS metadata 服务维护窗口，生产客户端已静默或接受中断；
2. 三节点生产 PD/TiKV unit、PID/starttime、exe SHA、config SHA、data/WAL/Raft realpath、mount source/UUID 已归档；
3. `/mnt/jfs-tikv` 为 `/dev/nvme1n1` ext4，空间门通过；
4. 无旧 `t64/t65` mount、loop、临时端口、进程或作用域目录；
5. Ceph HEALTH_OK，生产 TiKV 三 store 全 Up；
6. 所有将执行的 sudo 写命令已由脚本输出为逐节点 plan，用户逐条确认。

生产 stop、临时存储 create、每-arm mkfs、最终 destroy、生产 start 是五类不同授权，不能用一次“继续”覆盖。

### 4.2 绝对红线

1. 禁止改生产 TiKV config/systemd/binary/data-dir，禁止移动、重命名或删除生产数据。
2. 禁止 `rm -rf`、递归 chown/chmod、`wipefs`、`blkdiscard`、`losetup -D`、写裸 NVMe、分区/LVM/RAID、`fstrim`。
3. 禁止 sparse backing；禁止把 backing 写到 Ceph OSD 盘、系统盘或未知设备。
4. 禁止 lazy/force umount、SIGKILL、`pkill/killall/fuser -k`、reboot/shutdown。
5. 禁止 pool delete/create、PG/CRUSH 变更、OSD restart、全局 drop_caches。
6. 禁止三节点并行执行 stop/create/destroy；逐节点执行并逐节点回传。
7. 禁止自动 trap rollback。失败后保留当前 phase，先生成只读 inspect/closure plan，再请求授权。
8. 动态 loop 号不得写死；每次 detach/mkfs 前必须核对 backing realpath、state、holder、mount source 和精确 token。

### 4.3 生产恢复门

正式成功或失败都必须走显式 closure：先停临时 TiKV→PD，确认无进程/端口；卸载并 detach 精确 loop；逐节点核对 destroy plan 后删除三个精确 backing file和空作用域目录；再另行授权逐节点启动生产 TiKV。

生产恢复验收不是“进程起来”即可，必须证明：

- 原 unit/config/exe/data/WAL/Raft/mount 指纹不变；
- 三个 store 全部 Up，心跳连续稳定三次；
- 生产 PD/TiKV log 无新 panic/corruption；
- Ceph HEALTH_OK；
- 无 t65 mount/loop/process/path 残留；
- `/mnt/jfs-tikv` 可用空间回到创建前基线 ±2 GiB；若未回归，停止恢复业务并查明具体文件，不得删除未知对象。

---

## 五、脚本职责与 Gate 0 合同

为便于现场调试和降低 sudo 误操作风险，不写“一键全流程”脚本。至少拆成以下职责：

| 脚本 | 单一职责 | 是否可写环境 |
|---|---|---|
| `t65-gate0-offline.sh` | 语法、负向守卫、路径/容量/parser/analyzer 单测 | 否 |
| `t65-inventory.sh` | 生产指纹、容量、mount/block/loop/端口只读盘点 | 否 |
| `t65-sudo-plan.sh` | 按 phase/node 打印完整 sudo 写命令，不执行 | 否 |
| `t65-sync-scripts.sh` | 按 Gate 0 manifest 同步精确脚本到三节点 `/tmp`；canary 暴露脚本缺陷时，仅在无本 RUN mount/loop/process 后以新旧 manifest 双绑定 token 做保留旧目录的 quiescent resync | 是；普通 sync 无 sudo，resync 仅用只读 `sudo losetup` 门；独立 token |
| `t65-prod-stop-one.sh` | 只停止一个明确节点的生产 TiKV unit | 是，独立 token |
| `t65-prod-start-one.sh` | 只启动一个明确节点的生产 TiKV unit | 是，独立 token |
| `t65-storage-create-one.sh` | 一节点创建精确目录并实际预分配三个 backing file | 是，独立 token |
| `t65-storage-activate-arm.sh` | 一节点重建空 PD tmpfs，并对指定 arm 关联 loop、核验、mkfs、mount | 是，每 arm/node 独立 token |
| `t65-storage-deactivate-arm.sh` | 一节点精确 umount/detach loop 并卸载 PD tmpfs，不删 backing | 是，独立 token |
| `t65-storage-destroy-one.sh` | 一节点按 state 删除三个精确 backing 与空目录 | 是，先 plan 后独立 token |
| `t65-cluster-orchestrator.sh` | 临时 PD/TiKV render/start/verify/TERM stop | 是，不含 sudo/存储操作 |
| `t65-seed-volume.sh` | 一次 seed format/layout/umount/dump | 是，不管 cluster/storage |
| `t65-restore-volume.sh` | load/mount/clone/verify/umount | 是，不 format/layout/GC |
| `t65-gc-return.sh` | fresh-seed inspect、单独授权 delete、seed return/final destroy | 是，破坏步骤独立 token |
| `t65-run-arm.sh` | 单个已准备 arm 的 fio + 有界监督 sampler | 是，不做生命周期操作 |
| `t65-analyze.py` | 原始证据复算、硬门和配对效应 | 否 |
| `t65-finalize.sh` | 只读证据闭包、invalid/valid 标记、manifest/archive | 否 |
| `t65-reset-gates.sh` | 经 token 授权的 Ceph compact、TiKV/OSD/NVMe cooldown 与 seed/pool return 门 | 是，不做服务/存储生命周期 |

内部依赖为 `t65-common.sh`、`t65-node-cluster.sh`、`t65-gen-jobfiles.sh` 和 `t65-sampler.sh`；它们不作为“一键入口”。执行方只能从上表职责脚本进入，禁止直接 source 内部函数后绕过 token。所有脚本位于 `scripts/FULLBASELINE/debug/`。

### 5.1 冻结 CLI 与授权形式

以下只定义调用合同，不代表当前授权。`RUN_ID`、`ARM`、`INSTANCE`、`NODE` 均须使用任务书冻结值；写操作必须设置脚本报错中给出的完整 exact token，不接受缩写或通用 `yes`：

```text
t65-gate0-offline.sh
t65-inventory.sh RUN_ID
t65-sudo-plan.sh RUN_ID PHASE NODE|all ARM INSTANCE
t65-sync-scripts.sh plan|sync RUN_ID
t65-sync-scripts.sh resync-plan|resync RUN_ID [EXPECTED_OLD_REMOTE_MANIFEST_SHA]

t65-prod-stop-one.sh plan|stop RUN_ID NODE
t65-prod-start-one.sh plan|start RUN_ID NODE
t65-storage-create-one.sh plan|preflight|create|verify RUN_ID NODE
t65-storage-activate-arm.sh plan|activate|verify RUN_ID A1|B1 INSTANCE NODE
t65-storage-deactivate-arm.sh plan|deactivate RUN_ID A1|B1 INSTANCE NODE
t65-storage-destroy-one.sh plan|destroy RUN_ID NODE

t65-cluster-orchestrator.sh render|start-pd|start-tikv|verify|stop-tikv|stop-pd RUN_ID A1|B1 INSTANCE
t65-seed-volume.sh format-mount|layout|verify|umount|dump RUN_ID A1 SEED-CANARY|SEED-FORMAL
t65-restore-volume.sh load|mount|verify|clone|adopt-clone-state|cow-canary|umount|abort-umount RUN_ID A1|B1 INSTANCE
t65-gc-return.sh inspect|delete|final-destroy|abort-final-destroy RUN_ID A1 GC-*
t65-reset-gates.sh prepare|post-destroy|seed-return|post-final-destroy|post-abort-final-destroy RUN_ID A1|B1 INSTANCE
t65-run-arm.sh RUN_ID A1|B1 ARM-CANARY-A1|ARM-CANARY-B1|R01..R08
t65-analyze.py INSTANCE_DIR | --matrix RUN_ROOT
t65-finalize.sh RUN_ID normal|invalid
```

脚本同步本身也是远端 `/tmp` 写操作：Phase I inventory/plan 前不执行；Phase I 签收后单独授权 `t65-sync-scripts.sh sync`。后续 cluster/runner 只核对远端 SHA，不再静默覆盖脚本。若正式 arm 前的 storage/cluster/seed canary 暴露实现缺陷，修复后必须重跑 Gate 0；只有三节点均无本 RUN mount、loop、PD/TiKV/JuiceFS 进程，且旧 remote manifest 三节点一致并逐文件校验通过时，才可先执行 `resync-plan`，再用同时绑定旧/新 remote manifest SHA 的独立 token 执行 `resync`。新包先写 fresh staging 并校验，旧包改名为 `scripts-prev-<oldSHA>` 保留，禁止原地手工覆盖；任一节点失败立即保留现场，不得继续 canary。

同一 canary/smoke 实例允许在已经完整 deactivate 后再次激活，但不能覆盖历史证据：当前活动身份只由唯一的 `activation.tsv` 表示；deactivate 必须把它归档为 `activation.tsv.deactivated-<stateSHA前16位>` 后再 unlink 当前 state。每次 activate 的 NVMe quiet 原始文件名必须包含 fresh-FS state SHA 前 16 位，配套 `.summary` 必须绑定同一路径；目标已存在就拒绝，禁止截断旧 quiet 证据。历史 audit/quiet 不阻塞后续 fresh mkfs/activate，当前 state、mount、loop 或进程任一仍存在则必须拒绝重入。

Gate 0 必须覆盖以下负向测试：空/异常 RUN_ID、根路径/相对路径/symlink、production path overlap、state/backing 不一致、loop 号被复用、sparse file、容量低于门槛、错 arm/token/node、old directory、B logs headroom 不足、sampler 先退、I/O 起点 spread 超限、缺任一 BW log、FS baseline 不回归。每项必须期望非零并验证没有环境访问。

脚本完成、仓库 SHA 冻结、同步到 157 后再次核对 SHA，Gate 0 PASS 只允许进入 Phase I，只读 inventory/plan；不自动授予维护或存储写操作。

---

## 六、执行步骤与暂停点

### 步骤 0：测试前通读方法文档

GLM 必须通读并在 `skill-compliance-pre.md` 记录：

- `skills/SYSTEM-SAFETY-SKILL.md` §1.3--1.7、§2.3--2.5；
- `skills/TESTING-GUIDE.md` §1.1--1.4、§2.2、§3；
- `skills/test-commands-reference.md` §8.3、§9、§11；
- `skills/baseline-reproduction-skill.md` §2.2、§2.4、§3.3--3.6、§4.3；
- `skills/LONG-RUNNING-TEST-SKILL.md` 的监控、暂停和异常保留要求；
- 本任务 §三--§五的覆盖规则。

冲突处理必须显式写入：本任务禁止全局 drop_caches 和 OSD restart；冷态由 `direct=1 + cache-size=0 + immutable seed` 保证，后端回归使用 GC + compact/cooldown，不采用通用 skill 的 OSD restart 或每轮 fresh layout。该偏离是生产安全和当前因果合同要求，不得擅自改回。

### 步骤 1：离线实现与 Gate 0

编写 `t65-*`，本地执行 shell/Python 语法检查、静态 sudo/危险命令扫描和所有负向测试。回传脚本 SHA、Gate 0 全文、调用图、sudo 写操作全集。**暂停，等 GPT/用户确认。**

### 步骤 2：Phase I 只读 inventory + sudo plan

在 157/150/151/152 只读采集生产指纹、容量、block topology、mount、loop、端口、进程、Ceph/TiKV health；为 A1/B1 create、生产 stop/start、每-arm activate/deactivate、最终 destroy 分别输出逐节点 plan。不得执行任何写命令。

回传完整 inventory、容量公式、路径解析、所有 plan 和差异清单。**暂停，等维护窗口与具体 phase 授权。**

### 步骤 3：维护窗口与生产 TiKV stop

获得明确授权后，逐节点运行 `t65-prod-stop-one.sh`，每节点核对 exact unit/PID/starttime 后 graceful stop。不得停止生产 PD。三节点全部 stop 且端口/进程确认后暂停一次，复核生产 mount/config/data 未变。

在 stop 前，先单独授权一次脚本 sync，核对三节点 manifest SHA 与 Gate 0 完全一致；sync 只允许写 `/tmp/jfs-t65-<RUN_ID>-scripts`，不得与 production stop 使用同一 token。

### 步骤 4：一节点存储全生命周期 canary

先只在 150：create 三个 backing → 验实际预分配 → A1 activate/deactivate（含 PD tmpfs）→ B1 activate/deactivate（含 PD tmpfs）→ plan-destroy。不得启动 TiKV/fio。每个动作分开回传。

canary 全过后，按独立授权精确 destroy，并证明空间恢复。只有 create→activate→deactivate→destroy 全闭环，才允许正式创建。若任一步失败，禁止手工猜测清理；先用原 state 和原签名脚本闭环活动资源，再修对应职责脚本、重跑 Gate 0，并按上节 quiescent resync 合同更新三节点后重做失败 canary。

canary destroy 与最终正式 destroy 共用同一 RUN，但不得共用可覆盖审计名：每次 storage destroy 必须写 `storage.destroyed-<stateSHA前16位>.tsv`；旧版 canary 已生成的固定名 `storage.destroyed.tsv` 作为 legacy immutable evidence 原样保留。历史 destroy audit 不代表活动资源，不阻塞 canary 后的正式 create；当前 storage state、backing/mount scope 或资源任一存在仍必须拒绝重入。finalize 必须收集并校验该节点全部 legacy/immutable storage destroy audits。

`RUN_ID=20260826-164047` 的 invalid finalize 首次执行在 150 完成 remote closure、到 151 时于首次输出前退出。只读逐断言与 `bash -x` 已唯一确认：旧实现把完整引用的可选 legacy 路径无条件放入 `storage_audits` 数组，151/152 从未生成该早期 canary 审计，因而不存在的字面量在 `[[ -f ]]` 处触发 `set -e`；SHA-bound 最终 destroy audit、production-restored audit和其余环境断言全部有效。修复合同是：仅当 legacy 路径 `-e` 或 `-L` 时才加入（保留 dangling symlink 以便后续拒绝），SHA-bound glob仍使用 `nullglob`，最终至少存在一个有效 audit；Gate 0 必须覆盖“只有SHA-bound”“legacy+SHA-bound”“dangling legacy”三种夹具。禁止创建虚假 legacy 文件绕过检查。保留首次失败的 finalize/provenance 证据后，允许在无任何本RUN活动资源且生产已经恢复的条件下按原子 resync 合同部署修复包，并仅重跑只读 finalize/archive，不得重做任何测试、存储或服务生命周期动作。

### 步骤 5：三节点正式 storage 与临时集群 smoke

逐节点创建 A1+B1 backing；验证 `Avail_post≥512 GiB`。分别做 A1、B1 三节点临时集群 smoke：activate、render/start/全局 readiness 连续三次、graceful stop、deactivate。两侧都必须完成 fresh-FS baseline 和空间回归。

### 步骤 6：seed/clone/GC 小数据 canary

沿用 03-22 已验证的职责拆分，但用新 RUN、t65 state 和新本地存储合同。小数据 canary 必须证明：dump/load、clone COW、source anchor 不变、GC check/delete/return、pool baseline、local reformat baseline 全链路成立。任一失败，不建正式 seed。

### 步骤 7：一次正式 seed

在 fresh A1 上 format/mount，只做一次 128 GiB layout；OSD compact/cooldown 全绿后 graceful umount、等待 session TTL、dump 并冻结 SHA/UUID/Name/source manifest/content anchors/GC baseline/pool baseline。停止 seed 集群并重建 A1 ext4 回空基线。

再分别在 A1/B1 做零正式写 restore/clone preflight，证明同一 dump 与 job contract 对两臂一致；preflight 结束后 fresh-seed GC 检查应 leaked=0，并重建本地 FS 回 baseline。

正式臂前另做一次 `ARM-CANARY-B1`，用相同 180 秒 B256 负载测得 logs 文件系统 peak available drop，冻结 `2×(peak+1 GiB)≤fresh free` 合同；随后通过独立 `GC-ARM-CANARY` 回到 seed/pool baseline。该 canary 只验证 B1 容量安全裕量，不进入 A1/B1 性能矩阵。

### 步骤 8：八个正式 arm

严格按 §2.5 执行。每个 Rxx 的最小状态机：

```text
activate fresh FS → freeze local baseline → start fresh cluster
→ load seed → mount → clone → capacity/health/quiet gate
→ single authorized fio + supervised samplers → analyzer hard gate
→ graceful JuiceFS umount → wait ≥65s → stop TiKV→PD
→ fresh GC cluster on reset A1 → inspect → separately authorized delete
→ seed/pool return → stop GC → deactivate/re-mkfs → local baseline return
```

任何硬门失败：写 `EVIDENCE_INVALID`，停止后续正式 arm；保留现场并只生成 closure plan。不得在同 RUN 修脚本后从失败 arm 继续，不得补跑替换。

### 步骤 9：分析与条件 C 决策

8/8 有效后，独立复算 A1/B1 四臂中位、四配对效应、CV/W4/W1、容量、TiKV/loop/NVMe 指标和目标差距。先写 A1/B1 结论，再判断是否值得另行做 C；不得在报告里先看结果再改变 15% 门。

### 步骤 10：seed、storage 和生产恢复 closure

不论 valid/invalid，都按独立授权完成 seed GC/final destroy、临时集群 stop、两臂 deactivate、逐节点 storage destroy、空间回归和生产 TiKV start/全局 verify。先恢复生产，再做耗时的离线报告；禁止让生产 TiKV因为等待 GPT 分析而持续停机。

### 步骤 11：测试后 skill 合规复核

在报告逐条说明：没有 pool delete/create、OSD restart、全局 drop_caches、重复 layout、sparse backing、生产路径写入、隐式 rollback；所有 sudo phase 有 plan/授权；每个 arm 的 compact/cooldown、capacity、seed/pool/local baseline return、实际 I/O 窗与统计均完整。任一不符必须标注对结论的影响。

---

## 七、交付物

结果目录固定为 `/tmp/opencode-t3.22b-<RUN_ID>/`，至少包含：

```text
manifest.sha256
commands.sh
authorization-ledger.tsv
gate0/
inventory/
sudo-plans/
production-fingerprint/{pre,stopped,restored}/
storage/{node}/{create,activate,deactivate,destroy}/
seed/
preflight/
arms/R01..R08/
gc/G01..G08/
analysis/
closure/
skill-compliance-pre.md
skill-compliance-post.md
```

每 arm 必须保留 fio stdout/stderr、256 个原始 BW logs、I/O 起点证明、sampler supervisor 状态、客户端/三 TiKV 节点/metrics/pidstat/iostat/df/PD store status、seed/clone manifests 和 commands。报告中的每个数字必须指向具体文件和字段。

正式报告落点：

`doc/perf-report/03-22b-tikv-nvme-backed-storage-attribution-<YYYYMMDD>.md`

完成后更新：

- `doc/perf-analysis/03-juicefs-parameter-tuning-execution-plan.md`；
- `doc/deploy-log/results-table.md`；
- 原始包持久化到 `results/prod-stage03-raw-<YYYYMMDD>/`，记录 size 与 SHA-256。

---

## 八、通用注意事项与本任务覆盖规则

1. **统计口径**：所有 fio 必须保留 256 个 per-job、1 秒粒度 BW log；按时间戳/重叠时长求和，在实际 I/O 起点后的 `[15,175)` 取正式中位数。禁止单 log × jobs、挑轮次、用 fio 全程平均替代。
2. **冷态口径**：本任务使用 `direct=1 + cache-size=0 + immutable seed`。为保护 157 和共享业务，明确禁止全局 drop_caches；报告须把该项记为经任务覆盖的 `N/A`，不是漏做。
3. **fresh-volume 失真**：正式 arm 不 format 新 JuiceFS 卷、不 `create_on_open`、不重复 layout；每臂 load 同一 seed 并 clone 工作集，正式写只改 clone。
4. **后端净化**：正式 layout 后、每个写 arm/GC 后执行 Ceph compact/cooldown，确认 `compact_running=0`、`compact_queue_len=0`、`kv_sync_lat` 绿；禁止用 OSD restart 代替。
5. **健康与静置**：每个 fio 前必须 HEALTH_OK、所有 OSD up、TiKV stores/regions readiness 稳定、底层 NVMe 完成 60 秒采样并通过最后 30 秒 bounded-idle gate、本地容量门通过；异常不得跳过。
6. **卷与对象清理**：只使用 frozen-seed GC return 和最终带 UUID/Name/session 守卫的 `juicefs destroy`；禁止 pool delete/create。每轮必须证明 seed/pool baseline return。
7. **本地存储清理**：loop 内状态只通过核验后的 per-arm mkfs 复位；backing 只在最终逐节点 destroy 删除。禁止目录级 `rm -rf`、强制卸载和批量 loop detach。
8. **命令与证据**：每个职责目录都有 `commands.sh`、环境快照、原始输出、state/identity/SHA；每条判据指名文件、字段和计算式，不能只交摘要。
9. **分层授权**：实现性脚本 bug 可在离线修复后重跑 Gate 0；任何变量、容量、矩阵、清理方式或 sudo mutation 变化都必须暂停并重新批准。
10. **挂载档位**：msgr=8 的 active-only worker CV 只作协变量；没有标定坏档阈值，禁止 detect-and-replace、重挂剔除或以历史 `ns/B` 跨并发判档。
11. **静置超时**：若 quiet/compaction/readiness 在预定上限内不收敛，标记环境未就绪并停止；不得无限等待后把不同起点混入矩阵。
12. **长跑监控**：监督器只监控并告警，不自动执行破坏性恢复。GLM 可连续推进已预授权的只读/非破坏步骤；遇到硬门、身份不一致、sudo 新命令或正式 arm 失败必须暂停。

---

## 九、结果分支

| 结果 | 解释 | 下一步 |
|---|---|---|
| B1 材料性优于 A1，仍 <6250 | 真实 NVMe 延迟下逻辑隔离有效但不足 | 给出物理独立介质/节点需求；不再扫局部参数 |
| B1 材料性优于 A1且稳定 ≥6250 | 目标在逻辑隔离下达到 | 另立生产落地/风险验证，不能把 loop PoC 直接当生产方案 |
| B1≈A1，均显著高于 H | fresh 状态或临时集群起点可能主导；逻辑隔离非主因 | 评估条件 C；仍不做 inode/worker 重扫 |
| B1≈A1，且 A1接近 H | RAM 与 NVMe 介质差异可能解释 H→RAM 改善 | C 只用于确认 nested-loop/native 边界，或直接架构收口 |
| 任一硬门失败 | 无正式 A1/B1 结论 | 清理恢复生产；修协议后必须新 RUN，不静默补样 |

无论哪个有效分支，只要 256-inode B1 仍低于 6250，都必须把 F69 的 per-inode 同步 transaction 下界和本轮本地/数据面指标一起纳入最终架构解释。

---

## 十、红线汇总

1. 当前任务书不授权任何环境操作；Gate 0、只读 inventory、维护、sudo 写操作分别授权。
2. 生产 TiKV 与临时 TiKV不得并行；生产 PD 不停，生产 config/systemd/data 绝不修改。
3. NVMe 上只写三个精确、实际预分配的 backing file；PD 只用每实例 fresh 的精确 8 GiB tmpfs；禁止 sparse、裸盘写、OSD/系统盘借用。
4. 每 arm 对精确 loop 重新 mkfs；禁止旧目录跨 arm，禁止 `rm -rf` 冒充 reset。
5. 三节点逐节点 mutation；loop/backing/state/token 不一致立即拒绝。
6. 一次 layout、immutable seed、fresh restore/clone、每轮 GC/pool/local baseline return；缺一即无效。
7. sampler 跟随 fio 生命周期；300 秒固定采样器、fork epoch 计窗、缺 BW log 都无效。
8. B logs 达 70% used 或低于 8 GiB 主动安全停止；不得等 EIO。
9. A1/B1 是逻辑隔离，不是物理分盘；H/RAM/C 都不得冒充同日随机化对照。
10. C 只登记，必须在 A1/B1 报告后另开 RUN、维护窗口、脚本和授权。
11. 失败保留现场、先 plan 再 closure；禁止 trap 自动清理、强制卸载、SIGKILL、reboot。
12. 最终先恢复生产，再离线分析；不得因等待人工结论延长生产 TiKV 停机。
