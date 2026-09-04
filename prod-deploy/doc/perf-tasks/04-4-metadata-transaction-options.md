# 04-4 任务书：M1 JuiceFS 同步元数据事务架构方案盘点与原型工作量评估

## 日期：2026-08-30

> 实验编号：**M1**；04 阶段第四份任务书（M 线第一步）。
>
> 执行：GPT 直接进行只读源码取证、机制审计、模型复算和最终方案签收。
>
> 当前状态：`COMPLETED / PAPER_ONLY / M1_SINGLE_OPTION_ONLY`。
> 报告：`doc/perf-report/04-4-metadata-transaction-options-20260830.md`；证据包：
> `results/prod-stage04-analysis-20260830/m1-20260830-gpt-source-audit/`。
> 本任务没有占集群、运行 fio、编译/部署新二进制或修改 JuiceFS 源码。后续 helper、插桩、单测或
> 原型代码仍必须另行冻结 manifest、通过 Gate 0 并按 04-5 分阶段授权，不能沿用本纸面任务的权限。
>
> 承接：`doc/perf-analysis/04-metadata-architecture-and-layout-plan.md` §八、
> `doc/perf-report/03-18-tikv-meta-latency-attribution-20260822.md` §13、
> `doc/perf-report/03-19-randwrite-inode-concurrency-20260823.md` §9、
> `doc/perf-report/03-JUICEFS-PERFORMANCE-TUNING-FINAL-REPORT-20260828.md` §6.3/§8.2、
> `doc/perf-tasks/TODO-cluster-changing-experiments-after-stage03.md` C03/C04。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/fixtures/known-defect-classes.tsv`、`skills/TESTING-GUIDE.md`、
> `skills/test-commands-reference.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。

---

## 计划线（冻结）

```text
03 阶段：128 inode 先受串行事务周期限制，256 inode 后撞共享 TiKV 服务率
04-2/A1 + 04-3a/A2a：拆 fresh/规模残差，给容量与客户端架构方向排序
  ↓
04-4 / M1：源码路径、正确性不变量、四类改造、收益模型、工作量  ← 你在这里
  ├─ ≥2 个可实现候选：提交设计评审，选一个进入 04-5
  ├─ 证据缺口阻断排序：只提最小插桩，不直接写原型
  └─ 无安全候选：签负结论，转 TiKV 扩容/替代引擎评估
  ↓
04-5 / M2（条件）：新 volume 上先正确性、后性能的原型验证
  ↓
生产化（另立项）：兼容、灰度、回滚、长期可靠性
```

一句话任务：把“减少/流水化同步元数据事务”从方向性口号变成可评审的代码改动点、
吞吐上界、正确性义务、测试矩阵、工作量和回滚方案，并给出是否值得进入原型的决策输入。

---

## 〇、背景与已封板事实

### 0.1 性能约束

```text
6250 MiB/s ÷ 0.25 MiB/write ≈ 25,000 logical writes/s
当前稳定 meta 提交能力 ≈ 12,000/s
所需服务率提升 ≈ 2.08×（尚未计入工程余量）
```

03-18 已确认：

- `pkg/vfs/writer.go` 的 completed slice 最终调用 metadata `Write`；
- `pkg/meta/base.go` 中 meta Write 计时在每 inode `f.Lock()` 前开始，包含同 inode 排队；
- `pkg/meta/tkv.go` 的 transaction 更接近取得 inode 通道后的同步事务服务周期；
- 历史 transaction 约 `9.97--13.5 ms`，而 128 inode 达 6250 只允许约 `5.1--5.6 ms`；
- 256 inode 可增加前段并行，但会把 TiKV KV/compaction 和同步提交服务率推到共享墙。

03-22c 已确认：把 WAL/Raft 放到 RAM 可稳定 Raft sync，但带宽中位仅 `+5.05%`，D1 仍只有
`3756.51 MiB/s`；因此继续换介质或扫小参数不能提供所需约 2 倍服务率。

### 0.2 M1 不是性能承诺

M1 只做纸面架构审查。它必须量化候选方案的理论/工程上界，但**不得**把模型值写成实测收益，
也不得在没有 crash consistency 和 rollback 设计时因“可能 2×”直接批准原型。

---

## 一、唯一交付问题与完成定义

### 1.1 唯一问题

> 在不牺牲 JuiceFS 已承诺的写入可见性、顺序、fsync/close、崩溃恢复、重试幂等和版本回滚
> 语义的前提下，是否至少存在两个代码边界清楚、可 feature-gate、可测试、可回滚的方案，
> 能减少每逻辑写同步事务数或提高同 inode 安全在飞事务数，并具有材料性的提交率提升上界？

### 1.2 `可实施候选` 的最低条件

一项方案只有同时满足以下条件，才能进入“可实施候选”：

1. 指出精确 package/file/function/call edge 和锁/事务边界；
2. 明确改变前后的 `transactions/logical-write`、batch size 或 per-inode outstanding 上界；
3. 给出保守/中性/乐观三档 throughput 模型和失效条件；
4. 罗列全部被改变的可见性、顺序、durability、retry/GC/compaction 语义并给出验证办法；
5. 有默认关闭的 feature gate、旧行为 fallback 和无需破坏 metadata 的回滚路径；
6. 给出开发、单测、故障注入、性能验证、灰度各自工作量，而不是一个总人日；
7. 不依赖“以后再解决”的关键 schema/protocol 迁移或未说明的服务端改造。

M1 最终至少产出两个符合条件的候选，或者有证据地签 `M1_NO_SAFE_OPTION_IDENTIFIED`。

### 1.3 只报数据、不作为通过门的内容

- 哪个方案理论上最接近 `2.08×`；
- A2a/A2b 是否让 TiKV 扩容优先于客户端事务架构；
- patched v1.3 与 patched v1.4 的代码差异；
- 上游接受概率、长期维护成本和是否需要 RFC。

---

## 二、源码与证据真值合同

### 2.1 必须建立的 source provenance

在读代码前，对最终 U1 锁定候选建立：

```text
source-provenance/
  git-commit.txt
  git-status.txt
  patch-series/
  build-command.txt
  go-version.txt
  binary-version.txt
  binary-md5.txt
  source-tree-sha256.txt
```

至少包含两套可追踪视图：

- V13：`1.3.1+2025-12-02.e0032b2a` + loadRange + B-catchup/最终补丁，已知二进制 MD5
  `de93563f11a5ff3bd94dd25a4e0283b1`；
- V14：仅在 U1 仍为候选/批准时纳入 patched 1.4.1，已知二进制 MD5
  `24fae0852051c80ca571cb2f20275d46`，同时补全当前报告中的 `version=unknown` 源码来源。

若找不到能解释交付二进制的 exact commit + patch series，不能用任意同版本源码代替；记
`M1_SOURCE_PROVENANCE_BLOCKED`。允许先对上游代码做“参考分析”，但不得输出实现工作量或批准原型。

### 2.2 历史证据矩阵

每条机制事实必须登记在 `evidence-register.tsv`：

```text
claim_id  claim  evidence_type  source_file  section_or_line  raw_artifact  limitation
```

至少覆盖：

- 03-18 的 lock-before-timing、transaction/Write 延迟和 128 inode roofline；
- 03-19 的 B256 前段收益、后段共享墙和旧报告订正；
- 03-20A/B/R1/R2 的 compaction、Raft/storage、NVMe 排队边界；
- 03-22c 的稳定性改善、5.05% 带宽上界和 pending 仍增长；
- U1 最终二进制选择与 dump/load/clone/format compatibility 边界；
- A1/A2a 若已完成，其正式 verdict 与明确不可引用的残差。

报告中每个数字必须指回文档/原始归档；跨 RUN 数字只作边界，不拼成新效应量。

---

## 三、必须复核的当前调用链与事务语义

执行方不得只复述 03-18 行号；必须在 exact source tree 上重新建立可点击/可 grep 的调用图：

```text
FUSE Write/WriteAt
  → fileWriter / slice lifecycle / prepareID / FlushTo
  → object upload completion and ordering
  → meta.Write / doWrite
  → per-inode openFile lock
  → kvMeta.txn / TiKV prewrite + commit + Raft persistence
  → slice/chunk/inode length/mtime update
  → retry / compaction / deletion / GC
```

对每个 edge 记录：

- 调用者/被调者、同步/异步、持有什么锁、可能阻塞在哪里；
- 输入中的 inode/chunk/slice/offset/version 标识；
- transaction 读写 key 集、冲突范围和 retry 条件；
- 用户可见返回点、close/fsync 返回点、数据对象持久化点；
- 崩溃后由谁发现 orphan/partial state，如何 replay/GC；
- v1.3/v1.4 patched 之间是否不同。

输出 `callgraph.tsv`、`lock-transaction-map.tsv` 和不超过一页的 ASCII 时序图。不得用函数名猜语义；
不确定处标 `UNKNOWN_NEEDS_TRACE`。

---

## 四、四类必评方向

### 4.1 O1：多 slice/extent 更新的批量或合并提交

必须回答：

- 当前一个 logical 256 KiB write 平均触发多少 meta transaction；何时可能跨 write 合并；
- batch 是同 inode、同 chunk 还是跨 inode；最大等待时间/条目/字节；
- 相邻、重叠、乱序 write 如何合并，长度/mtime/slice list 如何原子更新；
- batch 失败时全部回滚还是逐项重试；重复提交如何幂等；
- close/fsync 是否强制 drain，进程崩溃时尚未提交 batch 如何处理；
- 是否增加 orphan data object、slice compaction 或 GC 压力。

吞吐模型至少包含：

```text
txn_rate_required = logical_write_rate × txn_per_write_after / average_batch_size
BW_ceiling = min(data_path_ceiling,
                 effective_txn_service_rate / txn_per_write_after × 0.25 MiB)
```

### 4.2 O2：非关键元数据的受控异步化

先分类而不是先假定：inode length、mtime/ctime、slice mapping、quota/accounting、atime、统计字段中，
哪些在 write/close/fsync 返回前属于必须持久的契约。对每个可异步候选说明：

- 最大丢失窗口和用户可见后果；
- flush/close/fsync/barrier 时如何 drain；
- client crash、节点断电、TiKV leader change 后如何恢复；
- 旧客户端或并发 reader 如何观察；
- 是否真的位于 B256 每写同步主路径，能减少多少事务。

若只能异步化不在热路径的字段，必须明确判为“正确但无材料吞吐上界”，不能为了凑候选而推荐。

### 4.3 O3：同 inode 有序 pipeline

必须回答：

- 将 `f.Lock()` 拆成哪些临界区，哪些工作可在锁外准备；
- per-inode sequence number/version 如何分配和提交；最大 outstanding 数；
- 两个事务写同 inode/chunk key 时 TiKV conflict 是否仍把 pipeline 串回去；
- overlap/non-overlap write、truncate、fallocate、rename/unlink、close/fsync 与 pipeline 如何排序；
- 前序失败、后序已准备时如何 cancel/rebase/retry；
- 是否只降低客户端 lock wait，却不能增加 TiKV 共享提交率。

模型必须把 per-inode 并行上界与全局 TiKV service ceiling 分开，禁止写成“outstanding=2 所以 2×”。

### 4.4 O4：热点 inode 元数据分片

至少比较按 chunk/range/extent shard 的两种 key 设计，回答：

- inode length、slice index、truncate 和 hole 的全局一致性如何保持；
- 跨 shard write/read/rename/unlink/fsync 的协调事务数是否反而增加；
- schema/version 标记、rolling upgrade、mixed clients、旧版读写和 rollback；
- shard 数、热点迁移、metadata compaction/GC、small-file 代价；
- 是否需要 server/protocol 变更，能否仅用客户端 + TiKV key schema 实现。

O4 若需要不可逆 metadata migration，默认不得作为第一个原型；必须先给 shadow namespace 或
dual-write/read compatibility 方案。

---

## 五、统一收益模型与决策口径

### 5.1 输入参数

所有方案使用同一组冻结输入，不得各自挑有利历史轮：

| 参数 | 基线/范围 | 来源 |
|---|---:|---|
| logical write size | `256 KiB` | B256 合同 |
| target logical rate | `25K/s` | `6250/0.25` |
| observed stable commit service | 约 `12K/s`，并给历史快慢范围 | 03 final/03-18/03-22c 原始证据 |
| transaction cycle | 约 `9.97--13.5 ms` | 03-17f/03-18 |
| active inode | `128` 原验收；`256` 架构探针 | 03-18/03-19/03-22c |
| data path observed ceiling | 由同批有效报告给区间，不假定无限 | 03 阶段读写/上传证据 |

### 5.2 三情景而非单点承诺

每项方案给出 conservative/base/optimistic：

- transaction 数减少比例或平均 batch size；
- per-inode outstanding；
- conflict/retry 放大；
- 新增 CPU/memory/queue；
- 全局 TiKV service ceiling 是否仍约 12K/s；
- 计算出的 logical write/s 和 MiB/s 上界。

评级：

| 级别 | 模型上界 | 含义 |
|---|---|---|
| **T2** | base 情景 `≥2.08×` 且 conservative `≥1.5×` | 有可能直接面向目标，仍非实测承诺 |
| **T1** | base `1.25×--2.08×` | 材料改善候选，但单独不足以达标 |
| **T0** | base `<1.25×` 或关键路径不减事务 | 不作为主原型，最多附带优化 |

模型敏感性必须显示 batch/outstanding/conflict 每个假设变化后的结果；不得只给一个看似精确百分比。

### 5.3 A2 对优先级的影响

| A2 结果 | M1 排序方式 |
|---|---|
| A2a 有规模信号，A2b 确认 fixed-scale region 因果 | C03 扩容/分片可与 M1 T2 候选并列；先比较成本和风险 |
| A2a 有信号，A2b 不可做/无效 | 不写“region 导致”；优先能减少事务/LSM压力的 O1/O3，并建议最小机制插桩 |
| A2a 无材料规模信号 | H→fresh 残差不能替代架构证据；按 12K→25K roofline 继续评 O1/O3 |
| A2 未完成 | 可完成调用链和方案工程评估，但最终原型排序标 `PRIORITY_PENDING_A2` |

M1 不需要等待 A2 才能开始纸面工作，但不得在 A2 未闭合时用 region 相关性批准 C03。

---

## 六、正确性、兼容性与故障注入义务

每个候选必须填写同一张 `correctness-obligations.tsv`：

1. 单线程/多线程相邻、重叠、乱序写的最终数据与 slice map；
2. read-after-write、跨客户端可见性、stat length/mtime/ctime；
3. close、fsync、fdatasync、flush、unmount 的返回语义；
4. truncate/fallocate/hole、rename/unlink/open-unlinked 文件交互；
5. quota/accounting、snapshot/clone、trash、GC、slice compaction；
6. retry 幂等、TiKV conflict、timeout、unknown commit result、leader change；
7. crash points：数据上传前、上传后/metadata 前、prewrite 后、commit 后/ack 前、batch 部分完成；
8. client kill、节点断电、PD/TiKV 单点/leader failover、网络分区；
9. patched V13/V14 mixed access、rolling upgrade、feature gate on/off；
10. rollback：有未 drain 队列、已有新 schema、旧 binary 回切时的安全行为。

每项写成可执行断言：precondition、fault point、expected visible state、允许 orphan、恢复命令和证据。
“与现有一致”“理论上安全”不算验证计划。

---

## 七、工作量和原型切片

每项候选按以下维度分别估算 `S/M/L/XL` 和人日范围，并注明假设：

| 维度 | 必须包含 |
|---|---|
| 设计/评审 | RFC、invariant、schema/protocol、feature gate |
| 实现 | client/meta/TiKV adapter、metrics、fallback、migration |
| 单元/模型测试 | ordering、conflict、retry、property/model-based tests |
| 故障注入 | §六全部适用 crash/failover points |
| 性能台架 | 新 volume、B128/B256、正确性先行、actual-I/O 统计 |
| 兼容/回滚 | V13/V14 mixed、upgrade/downgrade、数据检查工具 |
| 生产化 | observability、灰度、报警、runbook、长期维护 |

为每项定义最小 prototype slice：只改变一个核心机制、默认 off、全新 namespace、无需生产迁移，
并列出明确 kill criteria。不得把四个方向混成一个无法归因的大补丁。

---

## 八、执行步骤与停点

### Step 0：方法论和范围确认

完整阅读抬头方法论文档，记录 `methodology-ack.tsv`。确认本任务只读、不编译、不跑环境、
不修改源码；若需要任一 helper/trace/代码变更，先停下扩充任务书和 Gate 0。

### Phase I：source provenance 与历史证据表

建立 §2.1/§2.2 产物。exact source 无法闭合时暂停，不进入方案人日估算。回传 source SHA、patch
列表、证据缺口；不得用记忆补齐。

### Phase II：调用链、锁/事务/key-set 审计

只读源码，生成 §三三张图/表；至少两人/两种方法交叉核对关键事务边界：执行方原始取证 + GPT
独立复查。所有 UNKNOWN 单列，禁止在方案中当成已知前提。到 phase closure 暂停审核。

### Phase III：四方向统一模板评估

按 §四--§七逐项完成，不少于四个方向，不允许先挑喜欢的两个；输出三情景模型、正确性矩阵、
工作量和 prototype slice。执行方不做最终推荐，只标事实、假设和风险。

### Phase IV：GPT 独立复算与设计评审材料

GPT 重算吞吐模型、抽查源码引用、检查正确性义务和回滚完整度，给出最终 verdict 和候选排序。
A2 尚未完成时，排序必须带 `PRIORITY_PENDING_A2`；不得为了结束 M1 假设 A2 结果。

### 末步：合规复核

核对全过程无 SSH/cluster/fio/build/source mutation，所有引用可追溯、未知项未被填成结论、
历史 invalid RUN 只作工程观察。记录偏离及其影响。

---

## 九、VERDICT 与后续动作

| 条件 | VERDICT | 动作 |
|---|---|---|
| exact source/patch 与交付二进制无法闭合 | `M1_SOURCE_PROVENANCE_BLOCKED` | 先补构建真值，不估工作量 |
| 关键锁/事务/可见性语义仍未知，足以改变方案安全性 | `M1_NEEDS_MECHANISM_EVIDENCE` | 另立最小只读trace/插桩任务，不直接原型 |
| ≥2 个可实施候选，模型/正确性/回滚/工作量完整 | `M1_OPTIONS_READY_FOR_PROTOTYPE_SELECTION` | 用户评审后只选一个写 04-5 |
| 只有1个候选满足条件 | `M1_SINGLE_OPTION_ONLY` | 评估是否值得承担单一路线风险，不自动进M2 |
| 四方向均无安全、可回滚且有材料上界的候选 | `M1_NO_SAFE_OPTION_IDENTIFIED` | 转 C03/替代引擎/放弃6250目标决策 |

即使 `OPTIONS_READY`，本文也不授权 04-5；原型范围、正确性门和新 volume 必须另写任务书讨论。

---

## 十、交付物

```text
results/prod-stage04-analysis-<date>/m1-<ANALYSIS_ID>/
  methodology-ack.tsv
  commands.sh
  source-provenance/
  evidence-register.tsv
  callgraph.tsv
  lock-transaction-map.tsv
  keyset-conflict-map.tsv
  option-O1/
  option-O2/
  option-O3/
  option-O4/
  correctness-obligations.tsv
  throughput-model.tsv
  workload-estimate.tsv
  unknowns-and-needed-evidence.tsv
  SHA256SUMS
```

报告：`doc/perf-report/04-4-metadata-transaction-options-<date>.md`，首部机器可读 VERDICT，
正文至少含当前调用链、四方案对照、三情景模型、正确性/回滚、工作量、推荐/不推荐理由和
A2 依赖。最终真值同步 `doc/deploy-log/results-table.md` 与 04 计划书。

---

## 十一、通用注意事项与红线

1. 本任务只读源码与历史证据；禁止 SSH、sudo、cluster、fio、mount、服务操作和二进制部署。
2. 不修改 JuiceFS 源码、不生成 patch、不编译；需要时停止并转 04-5/独立机制任务。
3. exact commit + patch series + binary MD5 不闭合时，不能用同 tag/upstream 近似源码冒充真值。
4. 每条源码事实指向 file/function/commit/line 或稳定 symbol；每个数字指向报告和 raw artifact。
5. `EVIDENCE_INVALID` 历史 RUN 不进入效应量；跨 RUN 数字不相减成新因果结论。
6. 模型必须给假设和三情景；不得把理论 ceiling 写成实测、承诺或生产收益。
7. 正确性优先于性能；close/fsync/crash/retry/mixed-version/rollback 任一关键义务为空即不可推荐。
8. feature gate 默认关闭，新 schema 无无损回滚路径时不得作为首个原型。
9. 四方向必须全部评估；不得为凑“两个方案”把不在热路径的优化写成材料候选。
10. A2 只决定优先级，不把规模联合效应偷换成 region/LSM 单因素。
11. 执行方交付原始取证、逐项模板和 UNKNOWN；最终收益复算、风险裁决和推荐由 GPT 完成。
12. 新 helper/脚本必须先新增离线 Gate 0 并覆盖适用 known defect classes；未过不得运行。
13. 末步逐条复核 skill/guide，所有偏离和未闭合假设放在报告首部附近，不藏在附录。

### 执行闭包（2026-08-30）

1. V13 exact source、patch、build log 和 binary 真值已完整闭合；V14 exact tag + patch 语义闭合，
   构建复现字段作为 U1 若选择 V14 时的前置缺口保留；
2. 已先完成 mechanics，并按合同将最终路线优先级标为 `PRIORITY_PENDING_A2`；
3. 纸面人日由 GPT 按统一切片估算；上游维护者语义复核被放入 04-5 设计/正确性门，不阻断 M1 结论。

本任务已完成；`NO_EXECUTION_AUTHORITY` 继续适用于 04-5 的源码修改、构建与环境执行，不再表示 M1 未执行。

### 最终红线一句话

M1 可以交付的是有来源的代码事实、显式假设、方案与风险；**绝不能交付**未经原型验证的性能承诺、
未经故障/回滚设计的“安全”结论，或以任意近似源码替代真实交付二进制后给出的伪精确工作量。
