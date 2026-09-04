# 04-5 任务书（已废弃）：同 inode 跨 chunk 元数据事务批处理原型

## 日期：2026-08-30

> 实验编号：**M2**；承接 `04-4-metadata-transaction-options-20260830.md` 的唯一候选 O1。
>
> 当前状态：`ABANDONED / WILL_NOT_EXECUTE / RETAIN_FOR_REFERENCE`。
>
> 废弃决定（2026-09-02）：本任务需要修改 JuiceFS 源码并经历长期正确性、故障注入、兼容性和生产化
> 验证；即使原型获得性能收益，也不能在当前交付周期内直接用于生产。综合研发成本、维护风险和近期
> 可交付价值，停止插桩、原型开发及环境测试，不再等待 A2 触发。下文仅保留为历史技术设计参考，
> 不构成任何源码修改、构建或环境执行权限。
>
> 本文只冻结研发与验证合同，**不授权**修改源码、编译、部署、创建 volume、运行 fio、故障注入或操作集群。
> U1 已选择 exact patched V14；执行前仍必须补齐其可重现基座 provenance、提交代码设计评审，并另行冻结全部脚本/代码
> manifest 与离线 Gate 0。任何执行方不得根据本文自行连接环境。

承接证据：

- `doc/perf-report/04-4-metadata-transaction-options-20260830.md`；
- `results/prod-stage04-analysis-20260830/m1-20260830-gpt-source-audit/`；
- `doc/perf-report/03-18-tikv-meta-latency-attribution-20260822.md` §13；
- `doc/perf-report/03-22c-tikv-hybrid-ram-logs-attribution-20260828.md`；
- `doc/perf-report/u141d-juicefs-v141-replace-v131-final-20260831.md`（`REPLACE_APPROVED`）。

```text
EVIDENCE_LEVEL=L1_SCREEN(M2-I opportunity) → L2_FORMAL(M2-II correctness + performance)
SCREEN_SOURCE=instrument-only shadow batch/opportunity/1PC/cost 模型，不改提交行为
SCREEN_CONTINUE=eligible、shadow batch depth、b/k、modeled gain 与 1PC 全部过 §4.4 硬门
SCREEN_STOP=任一 opportunity 主门失败则不开发行为 patch，签 M2_EARLY_STOP_NO_BATCH_OPPORTUNITY
FORMAL_MATRIX=正确性全过后 OFF,ON,ON,OFF,ON,OFF,OFF,ON
ESTIMATED_WALL_CLOCK=M2-I 指标实查后估算；M2-II 属源码研发项目，不用 fio 纯负载时长代替研发预算
```

方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、
`skills/fixtures/known-defect-classes.tsv`、`skills/TESTING-GUIDE.md`、
`skills/test-commands-reference.md`、`skills/LONG-RUNNING-TEST-SKILL.md`、
`skills/baseline-reproduction-skill.md`、
`doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。

---

## 计划线（冻结）

```text
U1：exact patched V14 已批准；补齐可重现源码/二进制 provenance
  ↓
04-3a/A2：先判定元数据规模路线是否更优先
  ↓
M2-I instrument-only L1：opportunity / 1PC / b/k 门      ← 你在这里
  ├─ 不过：不写行为 patch，方向停止
  └─ 通过：进入 behavior design/code review
        ↓
M2-II 单元/模型/fault correctness
  ├─ 任一失败：终止，禁止看性能
  └─ 全过：新 volume OFF/ON 八臂 L2
        ↓
若正确且材料收益≥25%：另立生产化 RFC/L3，不直接交付
```

一句话任务：先用不改行为的插桩证明现场真有可批处理机会，再以正确性先于性能的顺序验证原型。

---

## 一、唯一问题与阶段边界

### 1.1 唯一问题

> 在不改变 JuiceFS metadata key schema、不降低 Flush/Fsync/Close、可见性、顺序、重试幂等和 crash recovery
> 正确性的前提下，把同一 inode 多个已完成上传的 chunk-head slice 合成一个 TiKV metadata transaction，
> 能否稳定减少 `transactions/logical-write`，并使 B128/B256 randwrite 获得至少 25% 的材料收益，或达到
> 6250 MiB/s 目标？

### 1.2 M2 分为两个可独立终止的项目

```text
M2-I  被动机制插桩（不改变提交行为）
  ├─ opportunity / 1PC / transaction-cost 模型通过 -> 设计评审
  └─ 不通过 -> M2_EARLY_STOP_NO_BATCH_OPPORTUNITY

M2-II 默认关闭的行为原型
  ├─ 单元/模型/故障注入全部通过 -> 新 volume 性能 A/B
  ├─ 任一正确性失败 -> M2_KILLED_CORRECTNESS
  └─ 正确但收益不足 -> M2_SAFE_BUT_NOT_MATERIAL
```

不得因为 M2-I 指标看起来乐观而跳过 M2-II 正确性；也不得在正确性失败时“先看一下性能”。

---

## 二、前置硬门

全部满足前禁止开始任何源码工作：

1. **U1 已封板**：明确 V13 或 V14 是 04 阶段基座，记录 exact binary MD5/SHA256、version、BuildID、
   commit、patch series、build command、Go version 和 source-tree manifest；
2. **源码可重现**：clean base + ordered patches 能得到审核中的 source diff；若选择 V14，必须补齐 04-4 中
   `build-command/go-version/binary-SHA/BuildID` 缺口；
3. **04-4 评审通过**：接受“只有 O1 一个候选”的路线风险，并明确 A2 未完成时优先级仍 pending；
4. **独立研发分支/目录**：禁止在现交付源码树直接开发；禁止覆盖 `/tmp/juicefs-03-8`、
   `/tmp/juicefs-1.4.1-patched` 等已签名二进制；
5. **新 volume 合同**：任何行为原型只允许全新、可销毁 namespace；生产/现有测试 volume 只读且不得挂载原型；
6. **代码与脚本 Gate 0**：source diff、测试代码、driver、collector、analyzer、fault helper 全部进入 manifest；
   `bash -n`、Python compile、静态危险命令检查、mock integration、known defect class 覆盖全部 PASS；
7. **授权拆分**：本地单测、隔离集群 canary、故障注入、性能矩阵各自单独授权，不得一次授权到底。

任一项缺失，输出 `M2_PREREQUISITE_BLOCKED` 并停止。

---

## 三、原型设计合同

### 3.1 精确代码边界

首版只允许以下结构，若设计评审发现必须扩大边界，先回改任务书：

```text
pkg/vfs/writer.go
  chunkWriter.commitThread
    -> per-fileWriter shadow/real commit coordinator
       -> optional metadata batch capability

pkg/meta/base.go + pkg/meta/tkv.go
  WriteBatch(same inode, ordered []SliceUpdate)
    -> one openFile inode critical section
    -> one kvMeta transaction
       read inode attr once
       read each distinct chunk key once
       append original slice records in deterministic per-chunk order
       write inode attr once
       write each changed chunk key once

pkg/meta/tkv_tikv.go
  metrics only unless an exact client-go API change is independently justified
```

不得在第一原型修改 object layout、chunk/slice encoding、metadata version、TiKV/PD server、Raft 参数或 Ceph。

### 3.2 Eligibility（首版冻结）

一项 update 只有同时满足以下条件才可 batch：

- metadata engine 是 TiKV；
- 同一 client、同一 inode、已存在 regular file；
- object `Finish` 已成功；
- `new_length <= current_length` 的 non-growing overwrite；
- volume `ChangeLog=false`；
- 当前没有 truncate/fallocate/hole/unlink/open-unlinked/close barrier 等控制操作等待；
- 每个 chunk 仅取当前队首，且依赖项已 committed；
- quota delta 为 0，inode/parent/flags 等校验无歧义。

任一条件无法证明时必须计数具体 `fallback_reason` 并调用原 singleton 路径。禁止“理论上应该是 overwrite”式默认。

### 3.3 Batch 和延迟上限

- 初始候选：`max_items=8`、`max_wait_us<=200`、预计编码后 transaction payload `<=512 KiB`；
- payload 估算必须包含被整值重写的全部 chunk slice-list 和 inode value，超出 byte cap 的 group 拆小或 fallback，
  不得只按新增 slice record 大小计算；
- coordinator 只能在短持有 `fileWriter` mutex 时 claim ready heads，不能持 mutex 等 TiKV；
- Flush/Fsync/Close、控制操作或队列错误触发立即 drain，不得等待 batch timer；
- 一个 batch 只含同 inode；按 `(logical_sequence, chunk_index, per_chunk_sequence)` 的已评审规则排序；
- 事务失败时全部 abort；语义错误按 coordinator 原序 singleton replay；不得在同一 batch 内手工部分 commit；
- 每个 item 只有 transaction success 后才标 committed、invalidate range、唤醒等待者。

具体 `max_items/max_wait` 只有在 M2-I 通过后才能冻结到行为 manifest，不做大范围性能扫参。

### 3.4 Feature gate 与回滚

- `off` 为默认值；instrument-only 和 behavior-on 必须是不同显式模式；
- unsupported engine/state 自动 old path；
- 不写新 schema，不设置不可逆 format flag；
- 关闭开关并换回 U1 基座后，旧客户端必须直接读取已由 batch 写入的 volume；
- 若实现需要 dump/load、metadata migration、dual-read 或 server-side change，立即判超出 O1，返回 M1 重评。

---

## 四、M2-I：被动机制插桩

### 4.1 插桩不得改变的行为

仍由每个原 `commitThread` 调一次 singleton `Meta.Write`，不等待 batch timer、不改变提交顺序、不合并 transaction。
shadow coordinator 只在实际 commit 边界扫描并标记“shadow claimed”的 completed eligible heads，模拟如果启用 O1
会形成的确定性 group；同一 slice 只能进入一个 shadow group，防止重复观察把 batch size 夸大。

### 4.2 必采 metrics

| metric | 含义 |
|---|---|
| `shadow_batch_size` histogram | 去重模拟 group 的 item 数 |
| `ready_heads` histogram | 每次 commit 边界同 inode 已完成上传的 chunk-head 数 |
| `eligible_total / fallback_reason_total` | 可进入首版 O1 的比例及被排除原因 |
| `meta_write_total / fuse_write_total` | 与历史 0.914--0.915 口径闭合 |
| `meta_transaction_total / logical_write_total` | singleton 真值 |
| `transaction_duration` | singleton service cycle |
| `distinct_chunks_per_shadow_batch` | key 数和 region 风险输入 |
| `estimated_encoded_tx_bytes` | 读取/重写完整 chunk values 后的事务 payload 分布 |
| `onepc_attempt/success/fallback` | 只能用明确 API/metric；取不到就记 UNKNOWN，不得猜 |
| `inode_lock_wait / transaction_service / postprocess` | 复核 03-18 queue/service 分解 |

### 4.3 插桩自扰检查

同一 U1 binary source 做 instrument off/on 的 A-A-B-B/B-B-A-A 短矩阵；行为仍 singleton。必须同时满足：

- 数据/metadata dump 完全一致；
- instrument-on 相对 off 带宽中位差绝对值 `<=2%`；
- transaction duration 中位差绝对值 `<=2%`；
- CV/W4/W1 无单向材料恶化；
- 每个 logical/meta/transaction counter 闭合，无重复 shadow claim。

失败则先修插桩，所有 opportunity 数字无效。

### 4.4 Opportunity 硬门

在 B128 与 B256 各至少一个稳定、完整的新-volume overwrite arm 中：

```text
eligible/meta_write >= 0.80
mean(shadow_batch_size) >= 2.0
median(shadow_batch_size) >= 2
estimated b/k >= 1.25
base modeled gain >= 25%
projected onepc success loss <= 10 percentage points
```

`k` 不能填假设常数：Phase I 可先以 TiKV key/payload 数和 singleton duration 给上下界；若仍无法约束，允许
进入一个不改变 schema的本地 fake-client/synthetic transaction cost microbench，但必须另行 Gate 0，不得先跑行为原型。

任一主门失败，签 `M2_EARLY_STOP_NO_BATCH_OPPORTUNITY`，不编写行为 patch。若 1PC outcome 取不到，签
`M2_NEEDS_ONEPC_EVIDENCE` 并只补最小 evidence，不默认通过。

---

## 五、M2-II-A：实现前正确性测试

### 5.1 单元与模型测试

至少覆盖：

1. 同/跨 chunk，相邻、重叠、乱序 overwrite 的 byte 与 canonical slice-map 对照；
2. randomized scheduler/property test：singleton model 与 batch model 最终状态一致；
3. growth、ChangeLog、quota、unsupported engine、control-op race 必须 fallback；
4. Flush/Fsync/Close drain：返回成功前所有 batch item committed；
5. batch transaction semantic error 后 singleton replay 的 errno、顺序和 partial progress；
6. exact duplicate slice、commit succeeded/ACK lost、retry 1--50 次的幂等；
7. batch 前后跨过 `numSlices%100==99`、`>350`、`maxSlices` 时 compaction trigger 不漏；
8. reader invalidation 每 range 正确；未 commit item 不提前可见；
9. feature gate off 的调用路径和现基座一致；
10. race detector、deadlock/timeout、队列关闭和 process shutdown。

### 5.2 本地 fault model

在 fake TiKV/client hook 中至少注入：

- object finish 前/后；
- transaction begin 后、reads 后、sets 后、prewrite 后、commit 后 ACK 前；
- first attempt conflict、leader-change-like retryable error、nonretryable error；
- coordinator claim 后 client kill；commit 后 signal 前 client kill；
- barrier 与 batch timer/commit/replay 并发。

任何断言失败均 `M2_KILLED_CORRECTNESS`。禁止将失败 case 排除为“不常见”。

---

## 六、M2-II-B：隔离新 volume 正确性 canary

### 6.1 环境和数据隔离

- 只用全新临时 TiKV namespace + 全新 JuiceFS volume name；
- 不访问、clone、dump/load 生产或既有性能 volume；
- Ceph 只使用已授权测试 pool/namespace，生产 pool 操作和生产 TiKV 端口均禁止；
- layout 只做一次，生成固定 128×1 GiB seed；验收实际 allocated ranges 和 256 KiB overwrite 合同后冻结；
- 后续 arm 从同一 immutable seed/metadata snapshot 或经验证 clone 恢复，不重复 layout；
- 所有 destroy/GC/seed-return 必须使用 UUID、pool、path、PID/starttime/exe 多重精确 gate。

### 6.2 集群故障矩阵

在单元测试全过后，按独立授权逐项执行：

- cross-client read/stat polling during batches；
- Flush/Fsync/Close/unmount；
- one TiKV leader transfer；
- one TiKV process kill/restart；
- client worker kill at registered hooks；
- short network interruption only if exact scoped rule and rollback are separately reviewed；
- old U1 binary gate-off remount and direct read/fsck/dump comparison。

每一项 precondition、fault epoch、expected state、actual state、recovery、orphan/GC 和 cleanup 都写入
`correctness-verdict.tsv`。没有注入点证据的“测试通过”无效。

---

## 七、性能验证矩阵

### 7.1 唯一变量

同一原型 binary、同一 source/tree/build、同一挂载配置；唯一变量为：

| arm | feature mode |
|---|---|
| OFF | instrument available, batch behavior disabled, exact singleton path |
| ON | same binary, O1 behavior enabled |

禁止拿旧 U1 binary 对新 prototype binary 直接相减，因为编译/插桩/其他 diff 会混入效应。旧 U1 binary 仅用于
兼容回滚签收。

### 7.2 固定负载与顺序

- 主负载：B128 randwrite，`256 KiB`、每 inode `iodepth=128`、与 03 正式口径同长；
- 架构探针：B256 仅在 B128 完整签收后执行；
- 固定八臂 `OFF,ON,ON,OFF,ON,OFF,OFF,ON`，配对关系事前冻结；
- 每臂从同一 seed state 恢复；不 relayout、不扫参数、不选择性补跑；
- Ceph scrub 在性能窗口按基线合同暂停并在每个阶段 finally restore；任何 abnormal PG 与例行 scrub 分开记录；
- actual-I/O epoch、per-job BW、client meta metrics、TiKV transaction/1PC、NVMe/OSD/CPU/PSI 同窗采集。

### 7.3 硬门与主端点

证据硬门先于性能：全部 arm 命令、sampler、coverage、health、seed、GC、PID/binary、feature mode、fallback 计数
完整；任一正式 arm 失败则整个矩阵 invalid，不选择性保留。

主端点：

```text
transaction_reduction = 1 - tx_per_logical_ON / tx_per_logical_OFF
bandwidth_effect       = paired_median(BW_ON/BW_OFF - 1)
effective_batch        = committed_items / batch_transactions
cost_factor_k          = batch_tx_duration / singleton_tx_duration at comparable state
```

成功判据同时要求：

- 正确性矩阵全部 PASS；
- `transaction_reduction >=35%`；
- `effective_batch >=2` 且 measured `b/k >=1.25`；
- 至少 3/4 配对带宽正向，paired median `>=25%`；
- ON 的 CV、W4/W1 不比 OFF 材料恶化；
- TiKV retry/conflict、1PC fallback、pending compaction、GC/orphan 无不可接受放大；
- `6250 MiB/s` 单列为目标达成，不是批准“材料收益”的必要条件。

若收益 `15%--25%` 且正确性全过，签 `M2_SAFE_BUT_BELOW_MATERIAL_GATE`，不得事后放宽 25%；若 `<15%`，
签 `M2_SAFE_BUT_NOT_MATERIAL`。只有达到上述全部门才是 `M2_PROTOTYPE_EFFECTIVE`，仍不等于生产可交付。

---

## 八、产物合同

建议根目录：

```text
results/prod-stage04-m2-<date>/<RUN_ID>/
  methodology-ack.tsv
  source-provenance/
  source-diff.patch
  SOURCE-MANIFEST.sha256
  SCRIPT-MANIFEST.sha256
  commands.sh
  phase-ledger.tsv
  authorization-ledger.tsv
  incidents.tsv
  instrumentation/
    shadow-batch.tsv
    lock-service.tsv
    onepc.tsv
    self-interference.tsv
  correctness/
    model-tests.tsv
    fault-injection.tsv
    cross-client.tsv
    compatibility.tsv
    correctness-verdict.tsv
  performance/
    MATRIX_AUTHORIZED.tsv
    per-job-bw/
    metrics/
    paired-effect.tsv
    mechanism-closure.tsv
  cleanup/
    gc.tsv
    seed-return.tsv
    residuals.tsv
  SHA256SUMS
```

正式报告必须同时给出 source verdict、correctness verdict、mechanism verdict、performance verdict 和 cleanup verdict；
不得只报带宽。

---

## 九、阶段停点与授权粒度

| 阶段 | 内容 | 自动执行边界 | 必停点 |
|---|---|---|---|
| P0 | U1/provenance/design/Gate0 | 只读与离线 | 设计 diff 审核 |
| P1 | instrument-only + local tests | 本地、无集群 | 自扰与 opportunity 报告 |
| P2 | isolated short instrument canary | 仅新 volume，经单独授权 | opportunity verdict |
| P3 | behavior patch + unit/model/fault tests | 本地、无集群 | correctness code review |
| P4 | isolated correctness canary/failover | 新 volume，逐类授权 | correctness verdict |
| P5 | fixed performance matrix | 仅全部前门 PASS 后 | performance + cleanup verdict |

执行方可在一个阶段内自主修复**不改变合同**的纯脚本格式/解析 bug并完整记录；涉及 sudo target、volume/UUID、
source semantics、判据、矩阵、fault scope 或 cleanup 的变化必须停止，不能自行扩大授权。

---

## 十、最终 VERDICT

| 条件 | VERDICT | 后续 |
|---|---|---|
| U1/source/Gate0 不闭合 | `M2_PREREQUISITE_BLOCKED` | 补真值，不开发 |
| ready-depth 或 b/k 不过门 | `M2_EARLY_STOP_NO_BATCH_OPPORTUNITY` | 终止 O1，转 A2/C03/架构结论 |
| 1PC 关键证据取不到 | `M2_NEEDS_ONEPC_EVIDENCE` | 只补最小 evidence |
| 任一正确性/回滚失败 | `M2_KILLED_CORRECTNESS` | 终止当前设计，不跑性能 |
| 正确但 bandwidth `<15%` | `M2_SAFE_BUT_NOT_MATERIAL` | 不生产化 |
| 正确且 `15%--25%` | `M2_SAFE_BUT_BELOW_MATERIAL_GATE` | 仅保留研发证据，不改门 |
| 全部门通过、带宽 `>=25%` | `M2_PROTOTYPE_EFFECTIVE` | 另立生产化 RFC/长期测试，仍不直接交付 |

### 最终红线

04-5 不是“写一个 batch patch 看带宽”的任务；它首先要证明现场存在可批机会，其次证明改变提交粒度不改变
文件系统语义，最后才允许在新 volume 上测性能。任何一步不能闭合，都必须在该步停止。
