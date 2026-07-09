# 11_1 步骤 2 写侧冲线分支：stall/compaction 根因 + JuiceFS 吞噬 deferred 收益追查

> 日期：2026-07-06　维护：opencode（规划/校验）/ deepseek·GLM（执行）
> 定位：本文是 `11-next-stage-plan.md` **步骤 2（写侧冲线）** 的延伸分支。步骤 2 的三天测试（14/15/16 任务）意外把一个隐藏的后端行为——**BlueFS stall / RocksDB compaction**——逼了出来，并牵出"SSD 被误判为 HDD、deferred 双写"这条线。本文：
> ① 记录步骤 2 三天测试的过程与数据索引；
> ② 沉淀已定论的 stall/compaction 根因（经 GLM 干净基线复核 + 原始数据对账）；
> ③ 立项两个待办：**查 JuiceFS 为何吃掉 deferred 后端收益** + **补 compaction 反压定量证据**。
>
> ⚠️ 本文结论**优先级高于** 11 正文里基于 deepseek 早期（被 GLM 推翻的）stall 归因的表述。

---

## 〇、一句话结论（2026-07-06，经 GLM 干净基线复核；2026-07-07 stall 归因对照坐实）

**BlueFS stall 不是负载本身触发的硬瓶颈，而是"多轮实验累积的 BlueFS 残余状态 + 高并发写入"共同作用的可管理现象；`compact` 能清除残余状态、有效防护。经净态对照（G1/G2/G3，见 §2.4）坐实：从干净态起跑，无论前置负载如何（无 / rados / rados+seqwrite 完整复刻上轮 A3 序列），multi-seqwrite 64G 均零 stall。因此过去冷态基线数据可信、不必作废；独立 NVMe 维持"可选优化"（干净态根本不 stall，只要有 compact 纪律即不必上独立 WAL/DB）。介质误判（SSD 当 HDD、deferred 双写）此前以为后端有 +23% 空间，但经干净态 2×2 重测（§2.5）证明 **+23% 是测量假象（crush class 重映射 + 60s 短测缓冲暂态），不可复现**；deferred=0 干净态无带宽收益、不纳入基线，JuiceFS 层亦无异常损耗——写侧"JuiceFS 吞掉后端收益"的命题前提不成立，待办 A 关闭。**

---

## 一、步骤 2 三天测试过程与数据索引（14/15/16/17）

| 任务书 | 日期 | 主题 | 结果目录 | 关键产出/状态 |
|----|----|----|----|----|
| `doc/perf-tasks/14-deepseek-task-step2-write-push.md` | 07-04 | 写侧冲线：扫 mu/buffer 推三项写过 59 | `results/write-push-20260704/` | mu=150 seqwrite 64/randwrite 63.7（后经 GLM 判为**运行间方差**，非真达标）；多线程写 41 触发 stall |
| `doc/perf-tasks/15-deepseek-task-write-retest-forensics.md` | 07-05 | 后端状态控制 + 并发扫描 + stall 取证 | `results/write-push-retest-20260705/` | A-idle r1=68→r2=47 断崖；B1-nj1 单进程 64G 也 stall；10 格设计仅完成 1.5 格（stall→abort） |
| `doc/perf-tasks/16-deepseek-task-write-forensics.md` | 07-05~06 | 后端裸能力/layout悖论/compaction/介质误判/内存盘对照 | `results/write-forensics-20260705/` | 提出 P1-P6；rados 256K 裸能力 52.7；exp3(compaction定量)/exp4(内存盘)均失败；P6 只查 cache_size 草率下"无影响" |
| `doc/perf-tasks/17-glm-task-baseline-recheck-crossreview.md` | 07-06 | **GLM 冷态基线复测(全程盯stall) + 交叉复核 14/15/16 + P6补验** | `results/cold-baseline-recheck-20260706/` | **推翻 P1/P2/P6，修正 P3/P5**；发现关键变量 compact_queue_len；rados 证 deferred +23% |

**关键原始数据出处**：
- 干净基线全程 health：`results/cold-baseline-recheck-20260706/backend/health-timeline.txt`（15129 行；基线阶段零 `stalled read`/`slow op`；105 行 HEALTH_WARN 全是 GLM 后续有创实验的 osd down/degraded，非 stall）。
- GLM 交叉复核：`results/cold-baseline-recheck-20260706/cross-review.md`（P1-P6 逐条 + N1-N5 新发现）。
- P6 deferred 对照：`results/cold-baseline-recheck-20260706/p6-deferred/report.md`（32G 单job非stall场景，SSD 模式无收益）。
- rados deferred 对照：`results/cold-baseline-recheck-20260706/rados-deferred-comparison/report.md`（**直打池 SSD 72.3 vs HDD 58.6，+23%**）。
- deepseek stall 门槛（污染起跑线）：`results/write-forensics-20260705/exp1-threshold/S1-8G/backend-after.txt`（8G→osd.3 stall）。

---

## 二、已定论的 stall / compaction 根因（经原始数据对账）

### 2.1 stall 的真实触发条件（GLM 发现，opencode + deepseek 早前均漏）
- **两条件同时满足才触发**：① 单 job 持续写（持续压单个 OSD，不给 compaction 喘息）；② **OSD 已有 compaction 积压（`compact_queue_len > 0`）**。
- **restart OSD 不清除积压**——LSM tree 状态在磁盘上，restart 只清内存缓存，compaction 在 restart 后继续但不加速。**这是关键盲点**：deepseek "每档间 restart 回干净态"的假设错误，其 8G stall 门槛是在**污染起跑线**（此前 write-push 累计 200G+ 写入的积压）上测出的。
- **干净态反证**：GLM 从干净卷起（destroy→format），layout 128G（128job）+ multi-seqwrite 64G（16job）**全程零 stall**；P6 实验 32G 单job（`compact_queue_len=0`）也不 stall。
- **规避手段**：定期 `ceph --admin-daemon <asok> compact`（秒级）清积压；避免单流长时间大写；多 job 分散写给 compaction 喘息。已写入 `skills/TESTING-GUIDE.md` §1.3/§3。

### 2.2 对 11 正文旧结论的订正
| 旧表述（deepseek 早期 / opencode 曾背书） | 订正（GLM 复核，本文为准） |
|----|----|
| "几十G连续写必触发 stall（P1）" | ❌ 推翻：干净态 128G 多job 零 stall；触发需"单流+已有积压" |
| "过去顺序写/layout 数据被 compaction 污染（P2）" | ❌ 推翻：基线全程 HEALTH_OK，值与旧基线差 1-2%，**旧数据可信、不必重测** |
| "写侧被硬件封死（P3）" | ⚠️ 修正：256K 写确接近后端稳态（rados 52.7 vs JuiceFS seqwrite 55.3），但 4M 写有空间（77.9）；"封死"不准 |
| "stall = WAL/DB 同盘，需独立 NVMe（P5）" | ⚠️ 修正并**经 §2.4 净态对照坐实**：stall 是残余状态累积（compact 可清除），非负载/同盘必然触发；干净态复现不出 stall、内存盘对照无前提，**独立 NVMe 维持"可选优化/有条件不需要"** |
| "SSD 误判 HDD 不影响写（P6，deepseek 只查 cache_size）" | ❌ 推翻：漏查 `bluestore_prefer_deferred_size`(hdd=65536/ssd=0)、`throttle_cost_per_io`(167×)；rados 证后端 +23% |

### 2.3 14 那次"mu=150 达标"的定性
- 14/analysis.md 称"旧测 57/54.8 被污染、新测 64/63.7 是真实态"→ **GLM 判为运行间方差 + mu 效应**，非污染（layout 不 stall）。这三项写在 mu=150 是**贴 59 上下浮动、单次 r1 不足判达标**，需多轮中位数。步骤 2"把写类推过 59"的原目标因此**未坐实达标**。

### 2.4 stall 归因对照坐实（2026-07-07，`results/stall-repro-memdisk-20260706/`，经 opencode 逐文件对账）
上一轮 `write-jfs-path-20260706` 的 A3（JuiceFS HDD mu=150 multi-seqwrite 64G）出现真实 stall（fio 24.6min/44.3 MiB/s，810 行 stalled read），但其起跑线未证明干净（紧接 A1 rados、中间未 compact）。本轮做**净态对照**分离"负载本身 vs 残余状态"变量：

| 组 | 前置负载（复刻上轮真实节奏） | 起跑线 | multi-seqwrite 64G | 自身 fio 窗口内 stall |
|----|----|----|:---:|:---:|
| G1 | 无 | 净态三确认 | 55.3 MiB/s | **无** |
| G2 | rados 3×60s（无清无 compact）| 净态三确认 | 64.1 MiB/s | **无** |
| G3 | rados 3×60s → seqwrite 3×4G（无清无 compact，完整复刻上轮 A3 序列）| 净态三确认 | 56.7 MiB/s | **无** |
| A3(上轮) | rados+seqwrite | **残余态（多轮实验累积、未 compact）** | 44.3 MiB/s | **有(5/6 OSD)** |

- **结论（坐实）**：从干净态起跑，即使完整复刻上轮 A3 的负载序列（G3），也**不 stall**。→ **A3 上轮 stall 的根因是之前多轮实验累积的 BlueFS 残余状态，不是当前测试负载本身；`compact` 清除残余状态即可防护。**
- **触发条件最终修正**：`stall = BlueFS 残余状态累积 + 高并发写入触发`（此前"compaction 积压"是残余状态的一种表现，但 G1/G2/G3 全程 `compact_running=0`，未再纠结单点 perf 归因）。
- **阶段二内存盘隔离：合理跳过**——前提是"能稳定复现 stall"，既然干净态复现不出，无从对照；**P5 维持"有条件不需要"**（生产只要有 compact 纪律即不必上独立 WAL/DB）。
- **对账校准记录**（不劳烦重跑）：报告"G2/G3 无 stall"就其真实 fio 窗口而言正确；但 G2/G3 的 health-timeline 各含 978/984 行 stalled read，经 opencode 按时间戳核对**全部发生在次日 Jul 7 09:45 之后**——是 G2/G3 监控循环未关、捕获到了同期 A1-A4-retest（09:43 起 A3 seqwrite）的 stall，**与 G2/G3 自身写入无关**。GLM 报告未自查这 978/984 行（数据卫生疏漏），结论不受影响。
- **仍未解决（转待办 A 最高优先级）**：SSD/deferred 端到端收益始终没拿到干净数据——A1-A4-retest 每次切 SSD 后 OSD 退化态（HEALTH_WARN + degraded 29 pgs）就开测，A2 rados 仅 27.6（正常 ~72），SSD 侧全部作废。**待办 A 重测必须：切 SSD 后等 HEALTH_OK + degraded 清零 + iostat idle 再测。**

### 2.5 待办 A 关闭：后端 deferred +23% 是测量假象（2026-07-07，`results/clean-deferred-retest-20260707/`，经 opencode 逐层对账）
干净态 2×2 对比（rados/JuiceFS × HDD/SSD，切 SSD 用 `injectargs` 且等满 HEALTH_OK+degraded=0+iostat idle+10min 再测，A3/A4 零 stall）：

| 对比 | HDD | SSD | Delta |
|----|:---:|:---:|:---:|
| 后端 rados 256K（3 轮均值）| 57.4 | 57.9 | **+0.9%** |
| 端到端 seqwrite（3 轮均值）| 62.4 | 63.2 | +1.3% |
| 端到端 multi-seqwrite（1 轮）| 57.5 | 65.9 | +14.6%（单轮，未排除方差）|

- **结论（坐实）**：**上轮"后端 deferred=0 有 +23%"不可复现，是测量假象**。deferred config 确实生效（`issued_deferred_writes` delta：HDD +2026/OSD、SSD +0~1/OSD，硬证据），但**干净态无带宽收益**。→ **待办 A 的核心谜题"JuiceFS 为何吃掉后端 +23%"前提不成立：没有收益被吃掉**。JuiceFS 层亦无异常损耗（HDD seqwrite JuiceFS 65.4 MB/s 甚至快于 rados 57.4，multi 仅差 5% 且口径不同）。
- **+23% 假象的两层归因**：
  1. **crush class 假象**：上轮 SSD 模式用 `ceph osd crush set-device-class` 改 device class 实现，会触发 **PG 重映射**，测到的是重映射瞬态而非 deferred 本身；本轮用 `injectargs`（不动 class）就没了。
  2. **60s 短测缓冲暂态**：rados bench 60s 逐秒曲线是"前 ~17s 缓冲加速 ~112 MB/s → 断崖 → 后段稳态 ~48-53"的两段式（见 `A1/rados-bench-r1.txt`，Stddev 27.9）。上轮孤立单次 72.3 很可能是缓冲暂态占比更大的一次采样。**教训已写入 `skills/TESTING-GUIDE.md` §5.5：rados bench 短测均值含缓冲暂态，不可当后端稳态写能力，只可做同口径相对对比。**
- **决策**：**deferred=0 不纳入基线**（后端 +0.9% 在方差内，不值得引入 config 变更风险）。上轮 72.3/+23% 数据点**标记为不可复现，后续分析不再引用**。
- **遗留（低优先级）**：multi-seqwrite SSD +14.6% 单轮信号，如有余力补 ≥2 轮验证；否则按方差处理。
- **对账校准记录**（不劳烦重跑）：GLM 报告 §3.1 deferred delta 表头误标——表中 175→2201/+2026 实为 **A3(JuiceFS HDD)** 数据，被填入了 "A1" 列；A1(rados 3×60s) 真实 delta 仅 +3/OSD（写入量小）。经 opencode 核 6×2 原始 perf 确认，**结论方向不受影响**（HDD 走 deferred、SSD 不走由 A2 的 +0 独立佐证）。

---

## 三、待办立项（本分支下一步）

> 📌 **执行进度**：
> - stall 归因 + compaction 分支 → **已坐实**（§2.4，`results/stall-repro-memdisk-20260706/`）：残余状态累积触发、compact 防护、内存盘无需（P5 维持"不需要"）。
> - **待办 A（JuiceFS 吞噬 deferred 收益）→ 已关闭**（§2.5，`results/clean-deferred-retest-20260707/`）：干净态下后端 deferred +23% **不可复现**（是测量假象），JuiceFS 层无异常损耗，**谜题的前提不成立**。deferred=0 **不纳入基线**。
> - 待办 B（compaction 定量）**降级/存档**：§2.4 已证干净态不 stall，compaction 反压不再是主线瓶颈，暂不追。
> - 待办 C（内存盘）**不做**：§2.4 已判定无前提。
> - 相关任务书：`task-clean-deferred-retest.md`（关闭待办 A 的干净态重测，已完成）；早前 `task-write-jfs-path-deferred.md`（实验 A/B）、`task-stall-repro-memdisk.md`（stall 复现+内存盘）均已闭环。

### 待办 A → 已关闭：后端 deferred +23% 是测量假象，JuiceFS 未吃掉任何收益（§2.5）

### 待办 B（存档）：补 compaction 反压定量证据
- ~~原计划补 stall 时刻 perf 时间线坐实 P4~~。§2.4 已证**干净态根本不 stall**、stall 是残余状态累积的可管理现象，compaction 反压不再是写侧主线瓶颈。**降级存档，暂不单独追**；如未来需要，方法见 `task-stall-repro-memdisk.md` §4（OSD 本地前台采集）。

### 待办 C（已判定，不做）：内存盘独立 WAL/DB 对照
- §2.4 已判定：干净态复现不出 stall，内存盘对照无前提，**P5 维持"有条件不需要"，不做内存盘实验**。保留 deepseek exp4 卡点记录（`ceph-bluestore-tool` 容器路径）备查。

---

## 四、对 11 正文的影响（需同步处理，已在 11 正文加分支指针）
- 步骤 2 状态：从"扫参数推写过 59"**转向根因**——写类未达标的核心不是 mu/buffer 参数，而是 JuiceFS 写路径吞吐（待办 A）；stall 是可管理现象非硬瓶颈。
- 步骤 3（randrw）不受影响，仍为独立硬骨头。
- 演进报告 §3.3/§5.3 关于"WAL/DB 换介质无效 / 独立 NVMe" 的表述已按本文校准（NVMe 降为可选优化）。

---

## 五、方法论教训（记录以改进后续校验，opencode 自省）
- **必须验证执行者的"复位/干净"前提本身**，不能默认接受（deepseek "restart 回干净态"被 GLM 用 `compact_queue_len` 证伪；opencode 当时未质疑并背书了错误 stall 归因）。
- **校验结论不仅看"有无原始数据"，还要看"数据的起跑线/口径是否干净"**（污染起跑线上的数据再真也得错误结论）。
- **交叉验证有效**：用一个已知干净的独立基线去反证执行者的框架，比顺着其框架校验更能发现系统性错误（GLM 复核价值的来源）。
- GLM 本轮小瑕疵：final-report 称"4998 条全 HEALTH_OK"不精确（实含 105 行有创实验的 down/degraded）；P6 因 32G 场景无收益就整体否定 deferred，忽略 rados +23% 的张力——本文已按更准确口径记录。
