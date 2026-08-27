# 03-22 测试报告：TiKV RAM block 存储隔离 A/B

## 日期与结论

- 日期：2026-08-26
- RUN_ID：`20260825-163811`
- 工作负载：randwrite，256 KiB，256 job / 256 inode，iodepth 64，runtime 180 s
- A：每节点 128 GiB tmpfs-backed loop/ext4，KV、WAL、Raft 共盘
- B：每节点 96 GiB KV loop/ext4 + 32 GiB WAL/Raft loop/ext4
- 正式判定：**`EVIDENCE_INVALID`**

正式矩阵没有完成。R01--R04 及 G01--G04 有完整闭环，R05 因 B 臂 WAL/Raft 文件系统跨实例累积旧目录而耗尽容量，触发 TiKV `AlmostFull/AlreadyFull`、fio 超时和 EIO；R06--R08 未启动。按任务书硬门，缺臂时不能把前四臂升级为 A/B 因果结论，也不能以补样方式修复本 RUN。

前四臂仍提供两条有边界的工程观察：

1. RAM 条件下 B/A 的部分点估计仅 **+0.47%**，两个时间邻近配对一正一负；B 虽降低后半程 TiKV async-write/raft-commit 平均延迟，但没有转化为足够带宽。该结果远离预注册的 15% 隔离效应门，只能作为后续设计依据，不能写成正式否证。
2. A/B 都约为 **3.7 GiB/s**，比原生产 TiKV 共享 NVMe 历史中心约 2880 MiB/s 高约 **28%--29%**，但这同时改变了 TiKV fresh 状态、介质和临时集群起点，不能区分各因素贡献；两臂仍只达到目标的约 **59%**。

---

## 1. 设计与推断边界

正式顺序预注册为：

```text
R01=A, R02=B, R03=B, R04=A,
R05=B, R06=A, R07=A, R08=B
```

所有 arm 共用同一个 immutable seed：256 个 1 GiB 文件，只预写每文件一个 512 MiB active extent，共 128 GiB。每轮把 seed metadata dump 加载到新的 PD/TiKV namespace，再用 `juicefs clone -p` 生成 `/test_dir`；fio 只写 clone，不写 seed。轮后用独立 fresh-seed GC namespace 删除 leaked objects，并要求 pool 回到 seed 基线。

正式窗为实际 I/O 起点后的 `[15,175)`，W1--W4 各 40 s。带宽从 256 份 fio interval-average 日志按区间与自然秒的重叠时长做 1 s 加权重采样，再逐秒求和。

三个比较的含义不同：

| 比较 | 可回答的问题 | 本报告边界 |
|---|---|---|
| H→A | fresh TiKV + RAM 介质 + 临时集群起点的组合效果 | 跨阶段工程对照，不能拆单因素 |
| A→B | RAM 条件下 KV 与 WAL/Raft 分盘的效果 | 原本是唯一随机化因果问题；本 RUN 缺臂，只保留部分观察 |
| H→B | 整体 RAM PoC 相对原集群的改善与目标缺口 | 跨阶段工程对照 |

---

## 2. 证据完整性与独立复算

正式 archive 已持久化到：

```text
results/prod-stage03-raw-20260826/opencode-t3.22-20260825-163811.tar.gz
```

| 项 | 结果 |
|---|---|
| archive bytes | `124546067` |
| 外层 SHA-256 | `1352878807325128fa3a07ac9325b74c89119ea24cbfab9f6e420fbc50096929` |
| tar 结构检查 | 5699 个成员；无绝对路径、`..` 越界或 link member |
| 内层 `SHA256SUMS` | 全部通过 |
| finalize | `FINALIZE_PASS mode=invalid`；仅表示证据、清理和归档闭环 |
| `RUN_INVALID.tsv` | `failed_instance=R05`，reason=`formal-arm-sampler-timeout-after-local-storage-capacity-exhaustion` |

GPT 未调用归档分析器，而是从 R01--R04 的 1024 份原始 BW log 独立实现同一 interval-overlap 重采样。四个 arm 的正式窗中位数、均值、CV、四子窗和 `W4/W1` 均与归档 `arm-analysis.json` 在浮点误差内一致。

---

## 3. R01--R04 原始结果

### 3.1 带宽和稳定性

| arm | 臂 | 正式窗 median MiB/s | mean MiB/s | CV | W1 | W2 | W3 | W4 | W4/W1 | 6250 达成率 |
|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| R01 | A | 3665.43 | 3644.44 | 6.49% | 3716.18 | 3686.39 | 3641.03 | 3563.60 | 0.959 | 58.65% |
| R02 | B | 3743.41 | 3716.76 | 5.54% | 3831.14 | 3803.91 | 3605.50 | 3696.69 | 0.965 | 59.89% |
| R03 | B | 3689.86 | 3675.28 | 6.12% | 3820.90 | 3739.21 | 3654.40 | 3536.72 | 0.926 | 59.04% |
| R04 | A | 3733.17 | 3691.65 | 7.92% | 3800.13 | 3649.74 | 3830.58 | 3592.50 | 0.945 | 59.73% |

四臂各自都满足 `CV≤10%`、`W4/W1≥0.90`，说明单臂正式窗可重复分析；这不能补足 R05--R08 缺失造成的矩阵无效。

### 3.2 部分 A/B 算术

| 项 | 结果 |
|---|---:|
| A 点中位数（R01、R04） | 3699.30 MiB/s |
| B 点中位数（R02、R03） | 3716.64 MiB/s |
| 部分 B/A | **+0.47%** |
| Block 1（R01--R04） | +0.47% |
| Block 2（R05--R08） | 不可用 |
| R02/R01 | **+2.13%** |
| R03/R04 | **−1.16%** |
| R05/R06 | 不可用 |
| R08/R07 | 不可用 |

已观测的两个相邻配对仅 1/2 同向；另外两个配对及第二 block 缺失。预注册条件要求 B/A≥15%、至少 3/4 配对和两个 block 同向，因此本 RUN 只能落入 `EVIDENCE_INVALID`，不能越权改判 `BLOCK_ISOLATION_NOT_SUFFICIENT`。

### 3.3 与历史 H 及目标的工程比较

历史 H 为原生产 TiKV 共享 NVMe 的同口径 B256 正式窗 `2828--2959 MiB/s`，中心约 2880 MiB/s，典型 `W4/W1≈0.36--0.44`。

| 工程对照 | 部分点值 | 相对 H 中心 | 相对 H 范围 | 6250 达成率 | 距目标 |
|---|---:|---:|---:|---:|---:|
| H→A | 3699.30 | +28.45% | +25.02%--+30.81% | 59.19% | 2550.70 MiB/s |
| H→B | 3716.64 | +29.05% | +25.60%--+31.42% | 59.47% | 2533.36 MiB/s |

这证明“fresh TiKV + RAM 介质 + 临时集群起点”这一组合显著改善了原集群工程状态，并把轮内衰减从历史 `0.36--0.44` 提高到 `0.926--0.965`。它不能单独证明原集群瓶颈来自跨日 RocksDB 状态，也不能单独证明来自 NVMe 介质；两者需要 fresh/NVMe 对照拆分。

---

## 4. TiKV 与 loop 时间线

以下为 GPT 从三节点 5 s Prometheus 快照和约 1 s `iostat` 原始样本独立复算的补充指标。histogram 使用相邻快照 `_sum/_count` 增量聚合；loop 数值汇总三节点样本。它们用于解释方向，不改变正式分类。

### 4.1 TiKV 前台延迟

| arm | 臂 | async write W1→W4 mean | raft commit W1→W4 mean | engine pending 单节点峰值 W1→W4 |
|---|:---:|---:|---:|---:|
| R01 | A | 0.888→2.174 ms | 0.457→1.282 ms | 0.476→4.051 GiB |
| R02 | B | 0.886→1.770 ms | 0.481→1.037 ms | 0→4.387 GiB |
| R03 | B | 0.907→1.776 ms | 0.489→0.965 ms | 0→5.498 GiB |
| R04 | A | 0.974→2.360 ms | 0.510→1.397 ms | 0.475→5.866 GiB |

四臂都会在运行中建立 compaction debt，前台写与 Raft commit 延迟随时间上升。B 的 W4 async-write 为约 1.77 ms，A 为 2.17--2.36 ms；B 的 W4 raft-commit 为 0.96--1.04 ms，A 为 1.28--1.40 ms。分盘对局部延迟有方向性改善，但总体带宽仅 +0.47%，说明这段局部介质竞争不是 6250 缺口的充分解释。

### 4.2 loop 设备

| 臂/role | W1→W4 mean `w_await` | W1→W4 mean `aqu-sz` | W1→W4 mean `%util` | 解释 |
|---|---:|---:|---:|---|
| A shared（R01） | 0.016→0.038 ms | 0.572→1.134 | 99.25→99.98 | loop 持续 busy，但等待仍为几十微秒 |
| A shared（R04） | 0.017→0.045 ms | 0.609→1.274 | 99.32→99.98 | 同方向复现 |
| B KV（R02） | 0.300→0.348 ms | 0.038→0.329 | 7.90→54.82 | KV 路径逐步承接 compaction 写入 |
| B KV（R03） | 0.225→0.371 ms | 0.030→0.333 | 7.94→52.75 | 同方向复现 |
| B WAL/Raft（R02） | 0.014→0.019 ms | 0.552→0.650 | 99.13→99.92 | 日志 loop busy，但低等待、低队列 |
| B WAL/Raft（R03） | 0.014→0.019 ms | 0.532→0.641 | 99.23→99.95 | 同方向复现 |

tmpfs-backed loop 的 `%util≈100%` 不能按真实 NVMe 饱和解释：`w_await` 仅约 0.014--0.045 ms，队列深度也低。A/B 都位于极快 RAM 介质，容易压缩“共享盘与分盘”的差异；这正是后续需要 NVMe-backed A1/B1 的原因。

---

## 5. R05 事故归因

### 5.1 直接原因

B 每节点的 32 GiB logs 文件系统在 R02、R03 stop 后没有删除旧实例目录。R05 启动前各节点 R02+R03 已占约 25.8/24.3/23.4 GiB，仅余约 6.2/7.7/8.6 GiB；R05 又写入约 5.1/6.1/6.1 GiB，最终 logs 使用率达到约 98%/96%/94%。同期 KV 文件系统只使用约 7%--8%。

R05 的 TiKV 配置也明确把 `data-dir` 放在 96 GiB KV 文件系统，而 `raft-engine.dir` 和 `rocksdb.wal-dir` 放在 32 GiB logs 文件系统。原始 TiKV 日志显示：

- 150：`Normal→AlmostFull`，并在约 15 s 后 `AlmostFull→AlreadyFull`；日志明确为 `raft engine usage: AlreadyFull, kv engine usage: Normal`；
- 151：反复在 `Normal/AlmostFull` 间切换，仍明确为 raft AlmostFull、KV Normal；
- 其他 peer 大量报告 `AlmostFull`，伴随 leader transfer reject 和事务 fallback。

因此这是**本地 storage 生命周期/容量合同失败**，不是 A/B 的性能观测，也不是内存不足、Ceph 故障或生产集群故障。

### 5.2 sampler 与 fio 时间线

| epoch | 事件 |
|---:|---|
| 1787708212 左右 | 五路 sampler 启动 |
| 1787708227.510 | fio launch |
| 1787708511 左右 | sampler 达到固定 300 s 生命周期 |
| 1787708513.675 | runner 记录 `samper_failed` 并对 fio PGID 发 SIGINT |

fio 的名义 runtime 为 180 s，但在容量门和事务阻塞下，launch 后约 286 s 仍未完成。sampler 正常到时退出，却被 runner 当作运行中故障；fio 随后产生大量 `err=5 Input/output error`。R05 没有 `fio.rc`、BW logs 或 `arm-analysis.json`，不得生成性能数字。

### 5.3 后续测试合同必须修复

未来同类 RUN 必须在每个 arm 前后冻结并核对：

1. 每个 role 的总容量、已用、可用、旧实例目录和 `reserve-space` headroom；
2. 当前 arm 预计 WAL/Raft 增量必须小于可用空间并保留明确安全余量；
3. 每轮精确删除已停止实例的本地目录，或重建等价空文件系统；
4. sampler 生命周期以 fio 进程结束为准，并设置有余量的总 watchdog；超时与 sampler 自身失败必须分型；
5. 任何容量门、EIO、缺 BW log 或缺 arm analysis 都直接使 RUN 无效。

---

## 6. seed、clone、GC 与清理闭环

### 6.1 seed 与 clone

| 项 | 冻结值/结果 |
|---|---|
| seed volume UUID | `a6cdd740-6050-4fdc-b9f9-9d82bc0a7c33` |
| dump SHA-256 | `118cae561b063947badac583049ee5e2686a69bc0614364a4f013f0ab736760b` |
| layout SHA-256 | `2d2c69949f0b85beefc4174f6ffbb2b6a29782ddc77470ae0f148d35f99c11ae` |
| content-anchor SHA-256 | `752357a9dd5152e258e7eb0e23c9cf6d8dbd941b90f73e1e2785e82c9b720b66` |
| formal clone contract | 256 行，SHA-256 `9c3a274c...` |

R01 首次暴露“跨 namespace 的逐路径数字 inode 必须相同”这一错误合同。clone 命令实际 rc=0、source/target path/size/anchor 全同，source 和 target 各 256 个 inode 均唯一且集合零重叠；差异只来自新 namespace 的数字 inode 分配。脚本经离线 Gate 0 修正为 `path-size-anchor exact + inode unique/disjoint`，随后用只读 `adopt-clone-state` 采纳首次现场，没有再次 clone 或写数据。R02--R05 都按修正合同通过。

### 6.2 GC 与 pool return

正式 seed GC 基线为 `valid=524288`、`leaked/pending/skipped=0`，seed pool objects=`2958972`。G01--G04 分别识别约 2.57M、2.61M、2.58M、2.59M leaked objects，删除后均精确回到 `valid=524288` 且 `leaked/pending/skipped=0`；三次 pool return 各自 spread=0，objects 相对 seed 只差 6--13，处于 ±8192 门内。

R05 失败后 G05 仍按独立 inspect→授权 delete→postcheck→seed-return 闭环，识别并清除 1,010,938 leaked objects。formal seed 随后以 `mode=abort-invalid-run` 精确销毁，并有 `ABORT_SEED_DESTROY_PASS`、`POST_ABORT_FINAL_DESTROY_PASS`。这些 marker 只证明无效 RUN 的清理完成，不把结果变为有效。

### 6.3 最终 teardown

- 六组 A/B RAM storage 均逐节点生成 destroyed audit；无 t64 mount、loop、目录或临时集群进程残留；
- 三节点生产 PD/TiKV 仍 active，PID/starttime、配置 SHA 和 `/mnt/jfs-tikv` 挂载保持不变；
- 157 的生产 JuiceFS 挂载正常；Ceph `HEALTH_OK`，6/6 OSD up/in，PG 全部 active+clean；
- 约 402 GiB RAM storage 实占内存已释放。

---

## 7. 协议偏离与脚本缺陷

| 阶段 | 偏离/缺陷 | 影响与处置 |
|---|---|---|
| storage smoke | tmpfs mount 覆盖预设属主；partial create 无完整 destroy plan；父目录普通 `rmdir` 权限不足 | 均先在单节点保留现场、精确清理，再经 Gate 0 修复；正式 RUN 前 A/B 三节点生命周期通过 |
| volume smoke/canary | mount scope、Gate 0 期待模式、JuiceFS daemon 父子 PID、Go argv 空格化、status JSON `Setting.UUID`、state adoption 多处缺陷 | 通过 A2/B2 全脚本 smoke 闭环后才进入正式准备 |
| 初始 layout canary | fio `filesize=1GiB` 不等于预分配，P0 文件只长到 512 MiB | 旧 RUN 作废清理；改为一次 formal layout + immutable seed，canary/restore/GC 全链路重验 |
| R01 | 错误要求跨 namespace 数字 inode 逐路径相同 | 现场停住；只读修正合同并 adopt 首次 clone，未重跑数据写；报告保留该修订 |
| R05 | 旧实例目录跨 arm 累积，缺 per-role 容量门；sampler 固定 300 s 把超时归类为 sampler failure | 直接导致正式矩阵无效；禁止补跑 |
| R05 取证 | 操作者尝试 `kill -9` 清理 fio，但目标已退出，命令 rc=1 | 实际未向存活进程送达，仍作为违反“失败即保留现场”的协议偏离记录 |

大量前置 Gate 0/canary 修复说明脚本最终实现明显收敛，但也说明正式测试前对存储**状态量**的检查仍不完整。下一任务不得只做脚本语法和单次生命周期 smoke，必须把跨 arm 容量累计纳入模型化 fixture 和运行时硬门。

---

## 8. 架构解释与下一步

### 8.1 当前能确定什么

1. **本 RUN 的唯一正式分类是 `EVIDENCE_INVALID`。** R01--R04 不能替代完整 ABBA/BAAB，更不能宣告分盘有效或无效。
2. **RAM 条件下，局部介质隔离不是 6250 缺口的充分解释。** B 的 TiKV 后半程提交延迟优于 A，但部分带宽只高 0.47%，仍差约 2.53 GiB/s。
3. **原生产 H 的元数据子系统/本地状态确实构成重大工程约束。** fresh+RAM 组合带来约 28%--29% 改善和显著更好的 W4/W1；但 fresh RocksDB 状态和介质贡献尚未拆开。
4. **剩余上限仍在端到端同步链。** 256 inode 只是 256 条独立前进通道；每 inode 内仍受客户端顺序提交和同步 TiKV/Raft 事务周期约束。即使 RAM 消除了大部分真实盘等待，A/B 仍停在约 3.7 GiB/s，说明还存在 TiKV/Raft 服务率、每 inode 串行提交以及共享 Ceph/client 路径的联合上限。

### 8.2 后续另立 03-22b

不在本 RUN 上补 R05--R08。另立新 RUN_ID，只回答介质与隔离归因：

| 臂 | 建议定义 | 回答的问题 |
|---|---|---|
| A1 | NVMe-backed loop/ext4，共享 KV/WAL/Raft | 对照同介质共盘基线 |
| B1 | 同一 NVMe 文件系统上两个预分配 backing file，各自 loop/ext4，KV 与 WAL/Raft 分盘 | Linux block/filesystem/worker 隔离在真实 NVMe 延迟下是否有收益；不冒充物理盘隔离 |
| C | fresh TiKV + production-equivalent 共享 NVMe | H→C 拆 fresh/历史状态，C→RAM A 拆 NVMe/RAM 介质 |

03-22b 必须先完成只读容量 inventory 和逐条 sudo plan，并满足生产 TiKV 与临时 C 不并行、backing file 预分配且有明确生产安全余量、每 arm 本地目录回到冻结基线、失败可精确卸载/detach/删除唯一 backing file。A1/B1/C 都属于新实验，需用户另行授权；本报告不授权任何环境操作。

若 03-22b 仍显示 B1≈A1，而 C/RAM A 的差异很大，则介质/新鲜状态是主项，逻辑分盘不是；若 B1 稳定显著优于 A1，则共享真实 NVMe 的低延迟 I/O 竞争成立。无论哪一支，256-inode 工作负载若仍远低于 6250，都应按同步事务与 per-inode 串行架构限制收口，不再扫 `max-uploads`、inode 数或 compaction worker。

## 9. 最终结论

03-22 的**环境测试已经结束且清理归档完整，但性能实验没有完成**。本 RUN 因 R05 容量合同失效而作废；前四臂只保留为部分工程证据。最重要的后续不是补样，而是用独立 03-22b 在 NVMe-backed A1/B1/C 上拆开 fresh 状态、介质和逻辑隔离三个因素，并从一开始把每臂本地容量回归设为硬门。

---

## 附录 A：Seed-Clone-COW-GC 测试机制设计原理

### A.1 核心问题

A/B 性能对比测试面临一个根本挑战：如何确保每个测试臂（arm）从**完全相同的系统状态和数据状态**开始，使得臂间差异只来自被测变量（存储配置），而不是起始条件或累积污染。

传统方法（直接 format → mount → fio）有两个不可控的混淆因素：

1. **数据创建污染**：每臂需要先写 128GiB 数据，写入过程本身会改变 TiKV 的 RocksDB 状态（SST 文件数量、compaction 触发历史、memtable 刷盘节奏）。不同臂的创建过程在时间上不可重复，导致每臂的 TiKV 起始状态不同。

2. **COW 数据累积**：JuiceFS 使用内容寻址的对象存储，fio 的 randwrite 会在同一文件内反复写同一 offset，第二次写触发 COW（写新块、留旧块）。历史测试不清理这些旧块，Ceph 池中的对象数量随每轮测试持续增长，对象年龄分布不同，影响 OSD 读路径和 GC 行为。

### A.2 JuiceFS 架构基础

JuiceFS 的核心设计是**元数据与数据分离**：

| 层 | 存储位置 | 内容 | 特性 |
|---|---|---|---|
| 元数据 | TiKV | 文件名 → 对象 key 列表的映射 | 可 dump/load（跨 namespace 便携） |
| 数据 | Ceph 对象存储 | 256KiB 数据块，key = 内容哈希 | 内容寻址（相同内容 = 相同 key，天然去重） |

这个分离是 03-22 测试机制的基础 — 元数据可以导出为 ~25KB 的快照文件，而 128GiB 的实际数据块留在 Ceph 池中不动。

### A.3 四步循环

每个 arm 执行以下循环：

**Step 1 — Seed 创建（一次性）**

```
format → layout(fio 写 128GiB) → prepare(gc --compact + OSD compact + TiKV idle) → dump
```

- fio 一次性写入 128GiB（256 文件 × 512MiB），然后 truncate 每文件到 1GiB（总逻辑 256GiB）
- prepare 阶段运行 gc --compact 让系统状态稳定（消除 compaction 尾部效应），等待 TiKV pending compaction 归零，OSD compact 完成，60 秒静默
- dump 只导出元数据快照（seed-meta.json.gz），128GiB 数据块留在 Ceph 池中
- dump 后运行 gc baseline 验证：524,288 个对象全部 valid，0 leaked（确认 seed 干净）

**Step 2 — Load + Clone（每个 arm 开始时）**

```
新 TiKV namespace → juicefs load seed-meta.json.gz → mount → juicefs clone -p seed_layout test_dir
```

- load 将元数据载入**全新 TiKV namespace**（无 compaction 历史、无旧 SST 文件、无事务延迟积累）
- 载入后元数据指向 Ceph 池中原始的 524,288 个数据块（这些块从 seed 创建到现在一个字节都没变过）
- clone 创建元数据级副本：test_dir 的文件指向同一批数据块（零数据拷贝）
- 验证 source manifest/anchor 与冻结 seed 完全一致，256 inode 全唯一且与 source/reference 不相交

**Step 3 — Fio 正式写入**

```
fio --rw=randwrite --bs=256k --numjobs=256 --runtime=180s --filename=test_dir/...
```

- fio 向 clone 文件写入，触发 **COW（Copy-On-Write）**：
  - JuiceFS 发现文件要被修改 → 不覆盖原块
  - 写一个**全新的对象**到 Ceph（key = 新内容的哈希）
  - 更新 arm 的 TiKV 元数据指向新对象
  - **原始 seed 数据块完全不动**
- 180 秒内产生 ~644GiB 的新 COW 对象（~2.5M 个 256KiB 块）
- fio 前后验证 source layout 不变（layout-pre.tsv = layout-post.tsv）

**Step 4 — GC 回收（每个 arm 结束后）**

```
新 TiKV namespace → load seed → gc inspect → gc delete → postcheck → seed-return → stop
```

- arm umount 后，其 TiKV namespace 关闭，COW 写的 ~2.5M 个对象变成"孤儿"（无元数据引用）
- GC 实例 load seed 元数据（指向原始 524,288 个块）→ 扫描 Ceph 池 → 识别 valid（seed 块）vs leaked（arm 的 COW 块）
- gc delete 精确删除 leaked 对象，postcheck 确认 524,288 valid / 0 leaked
- seed-return 验证 Ceph pool 三次采样稳定，回到 seed baseline ±8192 对象

### A.4 循环的完整闭环

```
                    ┌─────────────────────────────────────┐
                    │          Seed 创建（一次性）           │
                    │  format → layout(128GiB) → prepare   │
                    │  → dump(seed-meta.json.gz)           │
                    └──────────────┬──────────────────────┘
                                   │
                                   ▼
          ┌────────────────────────────────────────────┐
          │           Arm (R01-R08)                     │
          │                                           │
          │  1. load seed → fresh TiKV namespace      │
          │  2. clone → test_dir (元数据级副本)        │
          │  3. prepare (OSD compact + TiKV idle)     │
          │  4. fio 180s → COW ~644GiB 新对象          │
          │  5. umount → TiKV namespace 关闭           │
          └──────────────┬───────────────────────────┘
                         │
                         ▼
          ┌────────────────────────────────────────────┐
          │           GC (G01-G08)                     │
          │                                           │
          │  1. load seed → fresh TiKV namespace      │
          │  2. gc inspect → 发现 ~2.5M leaked        │
          │  3. gc delete → 精确删除 COW 块            │
          │  4. postcheck → 524,288 valid / 0 leaked  │
          │  5. seed-return → pool 回归 baseline       │
          │  6. stop                                  │
          └──────────────┬───────────────────────────┘
                         │
                         ▼
              Ceph 池回到只有原始
              524,288 个 seed 对象
              → 下一个 arm 可以
                从相同状态开始
```

### A.5 公平性保证

| 威胁 | 传统方法 | 03-22 Seed-Clone-COW-GC |
|---|---|---|
| 每臂数据起点不同 | 每次自己创建，数据分布不同 | load 同一个 seed dump，数据完全相同 |
| TiKV compaction 污染 | 同一 namespace 越跑越脏 | 每臂全新 namespace，无历史 |
| COW 旧块累积 | 不清理，对象数持续增长 | GC 精确删除，pool 回归 baseline |
| source 不可验证 | 无法证明原始数据没被动 | anchor SHA 前后验证一致 |
| 创建过程的时间不可重复 | 每次创建的 wall-clock 不同 | 跳过创建，直接 load |
| OSD 对象年龄分布漂移 | 旧块和新块混合，年龄分布不一致 | 每轮 GC 后只剩原始 seed 块（年龄统一） |

### A.6 COW 在这套机制中的角色

COW 是 JuiceFS 的固有写入机制（所有测试都有），但 03-22 将其**有意利用为测试工具**：

- **COW 保证原始数据不变**：fio 写 clone 文件时，原始 seed 块永远不被覆盖，只产生新块
- **COW 产生可识别的"垃圾"**：arm 结束后 COW 块变成 leaked（无元数据引用），GC 可以精确识别和删除
- **COW 使 clone 零成本**：clone 不拷贝数据（只复制元数据映射），256 文件 × 1GiB 的 clone 几乎瞬间完成

### A.7 测试机制的局限性

1. **混淆变量**：03-22 同时改变了 TiKV 存储介质（NVMe → RAM）和 namespace 状态（有历史 → fresh），无法分离两者各自的贡献。需要加一个"fresh TiKV on NVMe"的控制臂才能归因。

2. **天花板效应**：RAM 存储延迟极低，瓶颈可能已转移到 TiKV Raft 共识 / JuiceFS COW 元数据 / Ceph PUT 等非存储层。如果 A/B 都撞到同一非存储天花板，分盘差异被掩盖。

3. **B 臂容量约束**：32G logs tmpfs 在不清理旧实例数据时会耗尽（R05 失败的根因）。这不是架构缺陷，是运维缺陷，但限制了 B 臂的连续测试能力。

4. **COW 额外开销未量化**：COW 写入需要创建新对象 + 更新元数据引用，与传统覆盖写相比可能有额外开销。但 03-22 的 fio bs=256K = JuiceFS BlockSize=256K，每个写操作恰好替换一个块，不需要 read-merge-write，理论上 COW 开销最小化。未做对比验证。

### A.8 历史测试（03-17~03-20）与此机制的对比

| 方面 | 历史测试 | 03-22 |
|---|---|---|
| 数据起点 | 每次自己创建 128GiB | load 同一 seed，相同 524,288 块 |
| TiKV 状态 | 同一 namespace，有历史 | 每臂全新 namespace |
| COW 处理 | 不清理，累积 | GC 精确删除，回归 baseline |
| 可复现性 | 低（创建过程不可重复） | 高（相同 seed + 相同流程） |
| source 验证 | 无 | anchor SHA 前后验证 |
| 稳定性 (W4/W1) | ~0.36-0.44（严重衰减） | 0.93-0.97（几乎不衰减） |
| 带宽 (mean) | ~2,828-2,959 MiB/s | ~3,680 MiB/s (+25-30%) |

### A.9 结论

03-22 的 Seed-Clone-COW-GC 循环是一套围绕 JuiceFS 元数据/数据分离架构设计的可复现测试协议。它解决了传统测试的"起点不可控"和"COW 累积污染"两个核心问题，使 A/B 对比具备了公平性基础。但 03-22 同时改变了存储介质和 namespace 状态，无法分离收益来源，且 RAM 存储可能导致天花板效应掩盖 A/B 差异。后续如需归因，需要设计正交控制实验（如 fresh TiKV on NVMe vs fresh TiKV on RAM）。
