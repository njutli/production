# 06-2 任务书：M1 flush 路径调查（构建溯源门 → profile 门 → range-scoped flush）

> 日期：2026-09-15（按 GPT 评审 `/tmp/review-06-stage-plan-and-taskbooks-20260915.md` 修订：
> 新增构建溯源门与动态 profile/Amdahl 门、"语义等价"降为待验证目标、补丁行数由硬门降为复杂度预警、
> 补依赖闭包实现要求与跨 chunk 依赖回归、`SHARED_OP_BUDGET` 降为附属假设并改用同 RUN paired U150/U300）
>
> 面向：执行方产出溯源构建与原始证据，第二方（GPT/Luna）独立复算与裁决
>
> 状态：`COMPLETED / GATE2B_INVALID / EVIDENCE_INVALID / NO_CANDIDATE / PHASE_B_NOT_TRIGGERED`。
> Gate 1、Gate 2A 已闭合；Gate 3原登记为`QUALIFIED_GATE3_PASS`，但审计确认它不能正面证明依赖
> 闭包正确；Gate 2B 经2026-09-16审计判为结构性无效；Phase A 因 T1/T2/C2 正式窗覆盖和
> runtime 合同失败而不能计算正式效应量。range scope 已缩小但 flush wait 未下降，调查构建不进入生产。
>
> 是否重跑：否。首要原因是 Gate 2B 无判定力、观测开销约23%大于材料阈值、依赖闭包缺少正面证据；
> 状态重置或私有卷不能单独修复这些问题。
>
> 正式报告：`doc/perf-report/06-2-randrw-m1-flush-investigation-20260916.md`
>
> 后续（2026-09-16）：通知/范围修复与新合同验证另见
> [06-2b](06-2b-randrw-range-flush-repair-and-burst-validation.md)，不在本RUN补格。
> 下文“06-3用于交付验证”是历史预留；现06-3已用于缓存配置筛选，且本任务没有候选，
> 因此交付验证**未触发且不再预留编号**。
>
> 上位计划：`doc/perf-analysis/06-randrw-cache-and-write-path-tuning-plan.md`
>
> 立项依据：`report/周报-JuiceFS调优工作汇总-20260919.md` §3.1（M1 机制与代码位置）、§4（M1 性质辨析）
>
> 既有红线（本任务必须服从）：`doc/perf-analysis/04-metadata-architecture-and-layout-plan.md` §1.1 line 68
> ——"若不是部署归档中的同 MD5 binary，而是重新构建，必须先补齐 source/patch/toolchain/BuildID/SHA256
> 可重现性和 P0 smoke，不能把性能批准解释为任意 v1.4.1 构建均获批准"；
> `doc/perf-report/04-4-metadata-transaction-options-20260830.md` line 44 —— V14 的
> "exact build command、Go version、binary SHA256/BuildID 因本地构建现场丢失而未闭合"
>
> ⚑ **定位：`INVESTIGATION_BUILD / NOT_FOR_PRODUCTION`。** 本任务产出的二进制**不得**进入任何生产或交付路径，
> 也不得作为交付候选。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、`skills/TESTING-GUIDE.md` §1.3/§2.2/§3、
> `skills/test-commands-reference.md` §8.3、`skills/SYSTEM-SAFETY-SKILL.md`、`doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`

> **审计勘误（优先于下文历史合同）**：下文 `F=flush等待/read总等待` 与墙钟并集去重是本次实际
> 预注册合同，保留用于解释历史执行，但两者都不能表示高并发吞吐的串行关键路径，Gate 2B 回溯为
> `GATE_INVALID`。任何未来任务不得复用该判据；须使用逐请求关键路径口径并建立排队模型，不能换算时
> 就声明 Amdahl 不适用。观测开销必须作为硬门 `abs(delta)<M`，否则 `STOP_INSTRUMENTATION`。

```text
源码   M1：vfs.go:787 每次 read 前无条件 `writer.Flush(ctx, ino)`（**全 inode**）
       writer.go:386 持 fileWriter 锁、等该文件全部 chunk/slice 完成
       commitThread：upload → m.Write → Invalidate，按创建顺序 FIFO，且 s.dep **跨 chunk**
       reader.go 对 writer 引用数 = 0 ⇒ 读路径结构上看不见写缓冲
  ↓
辨析   M1 是**单客户端 read-your-own-writes（POSIX 强制）**，⛔ 不能删除
       但静态源码只证机制存在，⛔ **不能证明它是当前主因**
  ↓
06-1   cache+writeback 组合包筛选，产出最佳配置基座
  ↓
06-2   你在这里，三道门串行：
       门1 构建溯源：还原官方 v1.4.1 0b90c7db + B-catchup、冻结工具链、baseline 登记 BuildID/SHA256、
            与部署归档 24fae085 做 P0 smoke（04 计划书 §1.1 既有红线）
       门2A 零行为修改粗筛：.accesslog + goroutine dump + runtime trace，只判有无材料阻塞信号
            （pprof block/mutex 默认关闭、源码从未设采样率 ⇒ 空 profile，故不可作精测）
       门2B instrumentation-only baseline：历史 Amdahl 判据事后无效；观测开销约23%也超过M，
            本任务回溯为 GATE_INVALID，⛔ 不得由该门授权改造或未来复用
       门3 语义回归：含**跨 chunk 依赖闭包**用例，全通才能进效应量
  ↓
       三门皆过 → 四格 ABBA（baseline vs patched）
       ├─ 有材料收益 → 整理上游 PR；另立任务才谈交付（本次未触发）
       └─ 无材料收益 → M1 不是主要瓶颈，randrw 调优在本后端收敛
```

一句话：**先证明 whole-inode flush 值得改（构建可溯源 + profile 显示等待占比足够），再实现含依赖闭包的 range-scoped flush 并量化其净贡献；⛔ 全程不得预设 M1 是主因，也不得预设语义等价已成立。**

## 〇、最小决策与生命周期合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=源码 M1（vfs.go:787 全 inode flush；writer.go:386 持锁等全部 slice；
              cached_store.go:400 非 writeback 下完成信号在 PUT 之后；
              commitThread FIFO 且 writer.go:291 的 s.dep 为**跨 chunk**依赖；
              meta.ChunkSize=64 MiB ⇒ 1 GiB 文件 16 chunk）；
              0912 周报（读缓存命中率 47.41% 时仍只 +12.32%，**疑因**读被 flush 堵住，未证）；
              04-tmp3j（直接 RADOS 256K 写 3949 MiB/s 未饱和 > JuiceFS PUT 2177--2275 ⇒ 纯写口径无硬上限；
              ⚠️ 纯写!=混合，剩余约束可能在客户端路径也可能来自 GET/PUT 混合服务关系，待区分）
SCREEN_CONTINUE=见 §三.3 四条材料信号
SCREEN_STOP=历史合同见正文；审计后 Gate2B=GATE_INVALID，未来复用须先建立逐请求关键路径与排队换算，且观测开销<M
FORMAL_MATRIX=有收益则另立任务：上游PR + ABBA-BAAB 8轮 + 七项非劣回归；本次无候选，未触发且不预留编号
M1_STATUS=**合理嫌疑，未证主因**。⛔ 全文不得写"M1 是主因"
SEMANTIC_EQUIVALENCE=**待回归验证的目标**。⛔ 不得预先宣称"语义完全等价"
NOT_IN_SCOPE=⛔ 不删除 M1（正确性缺陷，见 §一.2）
            ⛔ 不改读路径去查询写缓冲（改动量级远超本任务，另议）
            ⛔ 不改 cache/writeback 参数（沿用 06-1 冻结基座，单变量）
            ⛔ 不改 max-uploads/buffer-size/max-fuse-io/卷 BlockSize（除 §2.6 的 paired 检验格）
            ⛔ 该构建不进生产、不作交付候选
ESTIMATED_WALL_CLOCK=门1 构建溯源 <=4 h；门2A 粗筛 <=1 h；门2B 观测构建+精测 <=3 h；
              门3 语义回归 <=3 h；效应量环境执行 1.5--3 h（4 格，条件式 +2 格）

MINIMUM_DECISION_SET=门1 构建溯源（离线，硬门）
              + 门2A 零行为修改动态粗筛（环境，硬门）
              + 门2B instrumentation-only 观测构建精测 + Amdahl 裁决（离线构建 + 环境，硬门）
              + 门3 语义回归（离线，硬门）
              + Phase A（4 格 ABBA：baseline / patched / patched / baseline，唯一通过项）
              + Phase B（<=2 格：同 RUN paired U150/U300，仅 Phase A 有材料收益时）
STOP_AFTER_ANSWER=Phase A 出数即回答主问题；Phase B 未触发即取消，⛔ 不补"漂亮样本"
MAX_PREP_BUDGET=溯源构建 + profile + 补丁 + 回归 <=10 h
MAX_EXECUTION_BUDGET=未经新授权只执行门2 与两个 Phase 且 <=6 h

EVIDENCE_ROOT=/mnt/c/SunRise/test/06-2/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-06-2-<RUN_ID>
BUILD_ROOT=/mnt/c/SunRise/test/06-2/<RUN_ID>/build
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=不新建/不销毁卷、不 layout、不改卷格式；缓存路径逐路径合同沿用 06-1 §2.4
BUILD_DISPOSITION=INVESTIGATION_BUILD / NOT_FOR_PRODUCTION；收口时从环境移除并登记
```

## 一、背景、目标与边界

### 1.1 M1 的确切行为（全部代码确认）

`pkg/vfs/vfs.go:787`，每次 read 之前**无条件**执行，且传的是 `ino` 而非区间：

```go
_ = v.writer.Flush(ctx, ino)      // 全 inode
n, err = h.reader.Read(ctx, off, buf)
```

`pkg/vfs/writer.go:386` `fileWriter.flush()`：**持有整个 `fileWriter` 锁**，遍历该文件**所有** chunk 的**所有** slice 并等其全部完成。

"完成"的含义（`pkg/vfs/writer.go:186` `commitThread`）：`flushData() → writer.Finish()`（非 writeback 下 = 等对象 PUT 返回）`→ s.done → m.Write(...) → reader.Invalidate(...)`，且**按创建顺序 FIFO 提交**。

`meta.ChunkSize = 64 MiB`（`pkg/meta/interface.go:41`）⇒ 1 GiB 文件 = 16 chunk；随机写散布全部 16 个，而一次 `bs=256K` 的读只碰 1 个 ⇒ **flush 范围被放大约 16×**。

### 1.2 M1 不可删除（防止误改的核心约束）

- `grep -cE 'writer|Writer' pkg/vfs/reader.go` = **0**；`dataReader` 只持 `meta.Meta` 与 `chunk.ChunkStore` ⇒ **读路径在结构上看不见写缓冲**。
- ⇒ **M1 是单客户端、甚至单进程的 read-your-own-writes（POSIX 强制），只有一个客户端时也必须有。** 它对其他客户端的读毫无帮助，因此**不是**跨客户端一致性机制。
- ⛔ **禁止以"我方场景每个客户端只读自己写的文件"为理由删除 M1。** 删除会让本任务自身的 fio randrw（同 offset 先写后读）读到旧数据或空洞，是**正确性缺陷**而非性能取舍。

### 1.3 ⚑ M1 只是合理嫌疑，尚未证明是当前主因

静态源码路径只能证明**机制存在**，不能证明它占当前 randrw 停顿的主要部分。04-7 只能确认同步 DIO 提交/缓存协调参与停顿，**尚未收窄**到某个 JuiceFS 锁、writer flush、FUSE 队列或单一后台线程。0912 周报"命中率 47.41% 时仍只 `+12.32%`"只是**疑似**被 flush 堵住，未证。

⇒ ⛔ **本任务全文不得写"M1 是主因"**；必须先过 §二.2 的动态 profile 门。

### 1.4 唯一主问题（通过/不通过项）

**在 06-1 冻结的最佳配置上，把 M1 改为含依赖闭包的 range-scoped flush 后，randrw 相对同轮 baseline 二进制，READ 与 WRITE 双方向能否取得至少 `M = max(5%, 2ε)` 的材料收益？**

### 1.5 附属假设（⛔ 不作预设结论）

`SHARED_OP_BUDGET`：05-2 中 GET `≈8064 ops/s` + PUT `≈8711 ops/s` ≈ `16.8k object ops/s`；若读改由本地供给使 GET 预算释放，PUT 可能上升。

⚠️ **限定（⛔ 不得省略）**：
1. 该数只是某一轮混合负载的**观测和**，不是独立测得的对象层容量。
2. B1M 字节吞吐更高（`6.07--6.15 GiB/s`）**不能单独证明** B256 必然受固定 op 预算限制 —— BS、对象大小、放大、客户端发起能力与队列形态均已改变。
3. ⚠️ **writeback 下前台应用写与后台 PUT 已解耦**：前台带宽上升而 PUT 不变，既可能是短窗积压增加，也可能是读路径改善，**无法直接区分**。
4. ⇒ `16.8k ops/s` 与 `×1.9` **只作探索性预测**，⛔ 不得写成高可信上限；验证须用 §2.6 的同 RUN paired U150/U300。

### 1.6 明确不回答

1. ⛔ 不回答"是否可生产"。本构建定位 `NOT_FOR_PRODUCTION`。
2. ⛔ 不回答"改读路径直接从写缓冲供读能到多少"。
3. ⛔ 不回答竞品对比。
4. ⛔ 不回答缓存参数最优值（沿用 06-1 结论，本任务单变量）。

## 二、三道前置门

### 2.1 ⚑ 门 1：构建溯源（离线硬门，⛔ 不闭合不得进入门 2 之后的任何改码）

**问题**：本地源码树为 `v1.4.0-dev-467-g44dd412a-**dirty**`，而部署批准的交付基线是**官方 v1.4.1 commit `0b90c7db` + 精确 B-catchup patch**（binary MD5 `24fae0852051c80ca571cb2f20275d46`）。二者**不同源**（相差数百 commit 且工作区有未提交改动）。

同时 04-4 报告 line 44 已明载：V14 的 **"exact build command、Go version、binary SHA256/BuildID 因本地构建现场丢失而未闭合"**。

⇒ ⛔ **不得从当前树构建 baseline 并声称它与交付二进制只差 range-flush 一项。**

必须依次完成（04 计划书 §1.1 line 68 的既有要求）：

| 步骤 | 内容 | 产物 |
|---|---|---|
| 1 | 还原官方 v1.4.1 `0b90c7db` 源码树（干净、无 dirty） | `build/source-provenance.tsv`（commit、tag、tree 干净性证明） |
| 2 | 应用精确 B-catchup patch，`git apply --check` 须 PASS | `build/b-catchup.patch`、`apply-check.log` |
| 3 | **冻结 Go 版本、依赖与完整构建命令** | `build/toolchain.tsv`、`build/build-command.txt`、`go.sum` 快照 |
| 4 | 构建**未修改行为**的 baseline，登记 SHA256 / MD5 / **BuildID** / `juicefs version` | `build/baseline-identity.tsv` |
| 5 | 新 baseline 与部署归档 `24fae085…` 做 **P0 兼容性 smoke** | `build/p0-smoke/` |

⚠️ 若步骤 4 的 baseline MD5 与 `24fae085…` 不一致（预期如此，因 BuildID/时间戳差异），**必须由 P0 smoke 证明行为一致**，并在报告中显式声明"baseline 为重建产物，与部署归档非同一 binary"。
⛔ 不得把"性能批准"解释为任意 v1.4.1 构建均获批准。

### 2.2 ⚑ 门 2：动态 profile 与 Amdahl 裁决（拆为 2A 粗筛 + 2B 精测）

#### 2.2.0 为什么必须拆两步（⛔ 原"零补丁测全四项"合同不可执行）

已核实的可观测性限制：

| 限制 | 核实 |
|---|---|
| **Go block/mutex profile 默认关闭** | `SetBlockProfileRate` 与 `SetMutexProfileFraction` 在 JuiceFS 源码中**从未被调用**（`grep` 全树无命中），Go 默认值为 `0` ⇒ `/debug/pprof/block` 与 `/debug/pprof/mutex` 返回**空 profile** |
| `.accesslog` 粒度不足 | 记录的是**完整 VFS 操作耗时**，无法拆出 `writer.Flush` 内部时间 |
| 无现成计数 | 源码没有 flush 涉及 chunk/slice 数、依赖闭包规模、逐段等待时长的任何指标 |
| 采样对应困难 | 即使拿到 `fileWriter.flush` 堆栈，也难与每个 read 的端到端等待做精确一一对应 |

⇒ ⛔ **"零补丁测得全部四项并计算精确 `G_max`"不成立**，必须拆为粗筛 + 观测构建精测。

#### 2.2.1 门 2A：零行为修改的动态粗筛（环境，⛔ 不改任何源码）

手段（全部零行为修改）：`.accesslog`、**定点重复 goroutine dump**（`/debug/pprof/goroutine?debug=2`，统计任一时刻停在 `fileWriter.flush` / `flushcond.WaitWithTimeout` / `f.Lock()` 的 goroutine 数）、**runtime trace**（原生记录 goroutine 阻塞事件，不依赖 `SetBlockProfileRate`）、以及其他可用 pprof。

**唯一回答的问题**：`fileWriter.flush` 是否出现**材料性阻塞信号**？

```
明确无材料信号            ⇒ STOP_RANGE_FLUSH，本任务终止于门 2A
有信号 或 采样分辨率不足  ⇒ 进入门 2B
```

⚠️ **必须在 06-1 的目标模式（writeback 开启、06-1 最佳配置）下测。** 非 writeback 下 flush 等的是**对象 PUT**（`17--21 ms`），writeback 下等的是**本地盘写** —— M1 的成本相差一个量级，**拿错模式会给出相反裁决**。

#### 2.2.2 门 2B：instrumentation-only baseline（观测构建，⛔ 不改行为）

⚑ 观测代码**不是** range-scoped 优化补丁，但**它仍属源码修改** ⇒ 必须基于**门 1 已闭合的源码与工具链**构建。

| 项 | 规格 |
|---|---|
| 允许的改动 | 仅 ① `writer.Flush` 前后计时；② 每次 flush 涉及的 **chunk 数 / slice 数**；③ 等待依赖的**数量与时间**；④ 逐段等待归属（持锁 / 上传 / 元数据提交 / 依赖链） |
| ⛔ 禁止的改动 | ⛔ 不改原 flush **范围**；⛔ 不改**提交顺序**；⛔ 不改**依赖行为**；⛔ 不改任何控制流 |
| 登记 | 完整 diff + 二进制身份（SHA256/MD5/BuildID）+ **观测开销实测**（同配置下 instrumented vs 门1 baseline 的带宽差） |
| 用途 | 由**直接计数**（非采样推断）计算 `G_max` |

⚑ **最终 Phase A 的 baseline 必须是这个 instrumentation-only 构建**，patched 则是"instrumentation + range-scoped"，二者**保持相同观测点与相同采样配置** —— 这样"观测点对称"（§3.2）是构造性满足的，而非事后核对。

#### 2.2.3 历史 Amdahl 口径（2026-09-16审计判定无效，⛔ 不得未来复用）

```
F     = 正式窗内可归因于 writer.Flush 的 read 等待时间 / read 端总等待时间
G_max = 1 / (1 - F) - 1
```

以下规则是本 RUN 实际采用的预注册合同，保留用于审计追溯，不代表仍有效：

1. **分子与分母必须来自同一正式窗口与同一观测构建**。
2. **若等待存在重叠，⛔ 不得重复累计**（须给出去重方法与去重前后两个值）。
3. `G_max` 是"该等待被**完全**消除"的**乐观上限**；range-scoped 只能**减少**而非消除 flush ⇒ **实际收益必然低于 `G_max`**。
4. **裁决**：

```
G_max <  M = max(5%, 2ε)  ⇒  STOP_RANGE_FLUSH，终止于门 2B，⛔ 不实现行为修改
G_max >= M                ⇒  进入门 3
```

⚑ 当时阈值使用06-1跨任务导入的`ε`。事后确认：墙钟并集在高并发下构造性趋1；请求等待之和也不是
串行关键路径；且跨任务`ε`不能替代本RUN同基座噪声。因此本段计算不得再作为行为修改准入门。

#### 2.2.4 未来任务的最小替代合同

1. `F` 只能定义为**单个read请求关键路径内**可归因flush的等待占该请求端到端时延比例，再按请求
   加权；禁止使用所有并发请求的等待总和或墙钟区间并集。
2. 只有证明该等待在排队模型中可从请求关键路径移除，才允许换算墙钟吞吐上限；无法换算时明确写
   `AMDAHL_NOT_APPLICABLE`，改用同RUN低扰动A/B，而不是制造`G_max`。
3. 观测器必须先通过硬门：`abs(instrumented/baseline-1) < M`；否则
   `STOP_INSTRUMENTATION`，不得进入行为补丁。
4. `ε`与`M`必须来自本RUN、同构建基座的有效对照；不得跨任务导入。

⚑ 门 2 的产出本身即有价值：无论裁决如何，它给出 randrw 读端停顿的**首个直接计数分解**（非采样推断），须单独成文。

### 2.3 ⚑ 门 3：语义回归（离线硬门，⛔ 不全通不得进入效应量）

⚑ **"语义等价"是待回归验证的目标，⛔ 不是已成立的结论。**

| # | 用例 | 判据 |
|---|---|---|
| R1 | 单进程写 offset X 后**立即**读同 offset（chunk 内 / 跨 chunk 边界 / 跨多 chunk），`bs` = 4K/256K/1M/4M | 逐字节一致 |
| R2 | 写 chunk A 后读 chunk B（未写区域） | 返回原有内容，⛔ 无脏数据/空洞 |
| R3 | 多线程同文件交错读写（同 fd / 不同 fd） | 无数据错乱；读到的必为某次已完成写的值 |
| R4 | **跨 64 MiB chunk 边界的单次读**，区间覆盖两个 chunk 且两 chunk 均有 pending 写 | 两侧数据都正确 ⇒ 区间重叠判定无 off-by-one |
| **R5** | ⚑ **目标 chunk 的 slice 依赖区间外的 growing slice**（`writer.go:291` 的跨 chunk `s.dep`） | 正确返回**且不出现异常等待**；须记录该读的时延分布，⛔ 不得靠 3 s 超时循环或 `flushDuration*2` 自动 freeze 兜底 |
| **R6** | ⚑ **跨 chunk 文件增长序列**：顺序追加使新 chunk 的首 slice 依赖前 chunk 的 growing slice，其间穿插随机读 | 无停顿、无 EIO、数据正确 |
| R7 | **部分重叠 slice**：读区间只覆盖某 slice 的一部分 | 正确返回 |
| R8 | 写后 `fsync` / `close` / `truncate` / `CopyFileRange` 后读 | 与 baseline 二进制行为一致 |
| R9 | JuiceFS 自带单测：`pkg/vfs`、`pkg/chunk`、`pkg/meta` | 全通过且与 baseline 结果一致 |
| R10 | `juicefs fsck`（只读）在回归卷上 | 无新增异常 |

- 全部在**离线临时卷**执行，⛔ 不在生产卷上跑语义回归。
- **任一条失败即停止本任务**，回退补丁并回传原因；⛔ 不得"先上环境看性能再修语义"。
- R5/R6 是本轮评审新增的关键用例（依赖闭包），⛔ 不得省略。

> **2026-09-16 执行偏离登记（不改写原预注册门）**：冻结 Go 1.26 工具链下，baseline 与 patched
> 的 `pkg/chunk` 均因 mockey 对 `runtime.duffcopy/duffzero` 的链接兼容问题失败；`pkg/meta` 全量套件
> 依赖本机不存在的外部后端，无法作为补丁差异判据。两臂已在 157 的隔离 SQLite 临时卷上完成真实
> FUSE R1--R8、R5/R6 延时、填充卷只读 `fsck`、零残留及业务指纹核对，结果完全同向通过，且独立
> 复核未发现范围计算、依赖闭包、FIFO 等待或观测对称性阻塞项。因此本次仅登记
> `QUALIFIED_GATE3_PASS` 并允许进入 Phase A，**不得表述为原合同 R1--R10 全通过**；上述基础设施
> 限制必须进入最终报告。

## 三、补丁规格、口径与矩阵

### 3.1 ⚑ 补丁规格（含依赖闭包，门 2 通过后才实现）

| 项 | 规格 |
|---|---|
| 改动点 | `pkg/vfs/vfs.go:787` 读路径 flush 传入 `[off, off+size)`；`dataWriter`/`fileWriter` 增加区间版 flush |
| ⚑ **依赖闭包（必须实现）** | `writer.go:291` 的注释即 "first slice of a new chunk, try to find **the last slice of the last chunk** as dependency"，`s.dep = lastSlice` 是**跨 chunk**的，`commitThread` 中 `for s.dep != nil && !s.dep.committed` 会等它。⇒ **只遍历重叠 chunk 会让目标 slice 等待一个区间外、从未被 freeze 的依赖**，只能靠 3 s 超时循环或 `flushDuration*2` 自动 freeze 兜底，**反而引入停顿**。实现必须沿 `s.dep` 链**递归纳入依赖闭包**并一并 freeze |
| 语义要求 | ⛔ 不改 `commitThread` 的提交顺序与依赖等待逻辑；⛔ 不改 `Flush`/`FlushAll`/`Close`/`fsync`/`Truncate`/`CopyFileRange` 等全量语义路径 |
| **规模** | ⚑ **复杂度预警线 `~60` 行**（含新增函数）。⛔ **不作正确性硬门** —— 40 行的错误补丁会过门、80 行的正确补丁会被误挡。超线只触发"须在报告中说明为何需要更大改动"，正确性一律由门 3 判定 |
| 基座 | **门 2B 的 instrumentation-only 构建**（其本身基于门 1 溯源源码与冻结工具链），⛔ 不同时引入任何其他改动 |
| 产物登记 | `BUILD_ROOT/`：`range-flush.patch`、`git diff` 全文、构建日志、baseline 与 patched 的 SHA256/MD5/**BuildID**、`juicefs version` |

⚑ **baseline 与 patched 必须由同一（门 1 冻结的）工具链在同一次操作中构建。**

### 3.2 观测点对称（构造性满足）

Phase A 的两臂定义为：

```
baseline = 门 2B 的 instrumentation-only 构建
patched  = instrumentation-only + range-scoped 行为修改
```

⇒ 观测点与采样配置**天然相同**，对称性是构造性满足而非事后核对。
⛔ 仍禁止只给 patched 加观测点后与无观测的 baseline 比较；⛔ 禁止两臂采样配置不同。
⚑ 观测开销须在门 2B 登记（instrumented vs 门 1 baseline 的带宽差），并在报告中声明。

### 3.3 fio 合同与公共条件

- fio 合同逐字沿用 05/06 系列（见 06-1 §2.1），BS 固定 `256K`。
- 挂载参数：**沿用 06-1 冻结的最佳配置**（cache-size / cache-dir 白名单 / writeback / upload-delay / free-space-ratio 逐项照抄并在 Gate 0 登记），⛔ 本任务不改任何缓存参数。
- 缓存路径逐路径合同、staging 逐设备空间门、**writeback"先排空后卸载"顺序**、预热合同、页缓存解释规则：**全部沿用 06-1 §2.4 / §2.5 / §2.6 / §2.7**。
- 若 06-1 裁决为"无材料收益"，基座取 06-1 的 T 臂配置，并在报告中显式声明"基座本身未通过 06-1 材料门"。

### 3.4 Phase A：baseline vs patched（4 格，唯一通过/不通过项）

顺序 **ABBA**：`C1(baseline) → T1(patched) → T2(patched) → C2(baseline)`

- **唯一变量 = 二进制**。挂载参数、fio 合同、预热合同、缓存目录处置全部相同。
- 每格必须记录实际使用二进制的 SHA256 与 BuildID，由分析器逐格校验与登记值一致（防臂串味）。
- 效应量：`T1/C1`、`T2/C2` 两组位置配对；同臂给 `ε`；`M = max(5%, 2ε)`；`ε >= 5%` 记 `RESOLUTION_INSUFFICIENT`。
- 零假设对照 = 两个 baseline 格之间。

### 3.5 Phase B：`SHARED_OP_BUDGET` 附属检验（<= 2 格，条件式）

仅当 Phase A 取得材料收益时执行。

⚑ **必须是同一 RUN、同一基座（patched）的 paired U150/U300 两格**：

| cell | 配置 | 目的 |
|---|---|---|
| P1 | patched + 06-1 基座 + `--max-uploads=150` | paired 对照 |
| P2 | patched + 06-1 基座 + `--max-uploads=300` | 若 op 预算已释放，U300 应从"无效"转为"有效" |

⚠️ 这是对 §1.5 假设的**正向预测检验**：05-2 已证 U300 在旧基座下无净收益。预测失败须在报告中显式记录为**削弱证据**，⛔ 不得省略。
⛔ **P1/P2 不得与 05-2 历史样本作直接因果比较**，历史值只作背景。
⛔ 单格不足以判定（原设计的单个 P2 格已按评审删除）。

### 3.6 机制指标（每格必采）

除 06-1 §2.8 全部指标外，新增：

| 指标 | 来源 | 用途 |
|---|---|---|
| **对象 PUT / GET 请求次数** | **`object_request_durations_histogram_seconds_count{method=...}` 增量** | §1.5 假设判定的**唯一主口径**；⛔ 不得用 `object_request_data_bytes`（字节计数器） |
| 对象 PUT / GET 字节吞吐 | `object_request_data_bytes{method=...}` 增量 ÷ 正式窗长 | 字节口径，与请求数**分开记录** |
| **读路径 flush 等待时长** | 门 2 的观测点（两臂对称，§3.2） | **机制主证据** |
| **每次 flush 涉及的 chunk 数与 slice 数** | 同上 | 直接验证 `16/16 → ~1/16` 与依赖闭包的实际规模 |
| **依赖闭包纳入的额外 chunk 数** | 同上 | ⚑ 验证闭包未退化成全量 flush |
| 上传在途 | `object_request_uploading` mean/p95/max | 三项都要 |
| 二进制 SHA256 + BuildID | 每格 `mount-process.tsv` | 防臂串味 |

## 四、有效性、裁决与数据来源

### 4.1 非性能硬门（失败即 `EVIDENCE_INVALID` 并停，⛔ 不得用性能好坏删样）

| 门 | 判据 | 数据来源 |
|---|---|---|
| **门 1 构建溯源** | §2.1 五步全部闭合；baseline 登记 SHA256/MD5/BuildID；P0 smoke 通过 | `build/source-provenance.tsv`、`toolchain.tsv`、`baseline-identity.tsv`、`p0-smoke/` |
| **门 2A 粗筛** | 在 writeback 目标模式下取得 `.accesslog` + goroutine dump + runtime trace，并给出"有/无材料阻塞信号"判定 | `profile/gate2a/` |
| **门 2B 精测（历史，已回溯无效）** | 本RUN曾登记观测开销并计算两种`F`；审计后两种`F`均无关键路径语义，且观测开销约23%>`M=14.64%`，故结果为`GATE_INVALID` | `build/instrumented-identity.tsv`、`profile/gate2b/amdahl.tsv`、`observability-overhead.tsv` |
| **门 3 语义回归** | R1--R10 **全通过**（含 R5/R6 依赖闭包用例），且与 baseline 逐项一致 | `build/semantic-regression/` |
| **二进制身份** | 每格实际二进制 SHA256 + BuildID 与该臂登记值一致 | `cells/<cell>/mount-process.tsv` |
| **工具链同源** | baseline 与 patched 由门 1 冻结的同一工具链同一次操作构建 | `build/build.log` |
| **观测点对称** | §3.5 新增计数在两臂以同一方式存在 | `build/`、`cells/*/` |
| **依赖闭包未退化** | patched 臂每次 flush 涉及的 chunk 数显著小于全量（否则改造无意义） | `cells/<cell>/flush-stats.tsv` |
| 其余 | 沿用 06-1 §三.1 全部门（路径授权、逐设备空间门、`stageFull`、`staging_block_errors=0`、**先排空后卸载**、缓存目录闭环、采样覆盖、身份指纹、集群健康、资产完整、预热一致、指标名核对） | 同 06-1 |

⚠️ **补丁行数不在本表中** —— 已降为复杂度预警（§3.1）。

### 4.2 性能口径（⛔ 性能端点不触发删样）

沿用 06-1 §3.2：实际 I/O 起点 + 重叠加权重采样 + 正式窗 `[15,175)` + W1--W4 + `W4/W1`；fio summary 只作旁证；带宽/CV/延迟再差都是结果。

### 4.3 材料信号（`SCREEN_CONTINUE`，四条全部满足才登记候选并进 Phase B）

1. **效应门**：READ 与 WRITE 两组位置对照的四个效应同向，且较小效应 `>= M = max(5%, 2ε)`。
2. **语义回归全通**（§2.3），且 patched 臂无新增 I/O 错误、无 `EIO`、无 fsck 异常。
3. **flush 机制证据同向**：patched 臂的读路径 flush 等待时长与每次 flush 涉及 chunk/slice 数**材料下降**，且依赖闭包未退化为全量。
   ⚑ 若带宽涨而这两项不动，**先判补丁未生效或口径错误**，⛔ 不得直接采信。
4. **口径自洽**：应用带宽提升与"对象层请求数变化 + 本地介质承担"方向一致，且对象层无新增错误。
   ⚠️ writeback 下前台与后台已解耦，本条只作自洽检查，⛔ 不得据其推断共享 op 预算。

### 4.4 附属假设裁决（独立于通过/不通过项）

| 观测（须来自 §3.5 的 paired U150/U300） | 裁决 |
|---|---|
| U300 相对 U150 出现材料收益，且 PUT 请求数材料上升 | `SHARED_OP_BUDGET_SUPPORTED`（**探索性**） |
| U300 仍无材料收益，PUT 请求数不动 | `PUT_SPECIFIC_CEILING_SUPPORTED`（**探索性**） |
| 两者皆不明确，或前台涨而积压同步增加无法区分 | `INCONCLUSIVE`，只报逐格值 |

⛔ 三种裁决均须标注为**探索性**，⛔ 不得写成高可信结论；⛔ 不得据此预告任何幅度。

### 4.5 四态裁决与强制声明项

沿用指导书 §二.15 四态。⛔ 不得写"可生产""等价""确定无效""已达架构上限"。

报告**必须**含：
1. `INVESTIGATION_BUILD / NOT_FOR_PRODUCTION` 声明；
2. "baseline 为重建产物，与部署归档 `24fae085…` 非同一 binary"声明（§2.1）；
3. **"M1 为合理嫌疑，本任务不主张其为主因"**声明；
4. **"语义等价由门 3 回归验证得出，非先验成立"**声明；
5. 门 2A 的信号判定、门 2B 的 Amdahl 分解（`F`、`G_max`、重叠去重前后两值）与观测开销；
6. 持久性声明与因果范围声明（沿用 06-1 §3.5）。

## 五、执行步骤与授权停点

### 阶段 0-A：门 1 构建溯源（离线）

- [ ] 0A-1 通读 skill 与本任务书，回传关键点确认；**显式确认 §一.2「M1 不可删除」与 §一.3「未证主因」**。
- [ ] 0A-2 确认 06-1 已回传裁决，抄录并冻结其最佳配置为本任务基座（逐项登记）。
- [ ] 0A-3 执行 §2.1 五步，产出全部溯源证据。
- ⛔ **停点 1**：回传门 1 全部证据，等第二方审核 + 用户授权。⛔ 未过不得进入门 2。

### 阶段 0-B1：门 2A 零行为修改粗筛（环境，用门 1 baseline 二进制）

- [ ] 0B1-1 只读 inventory；scrub 策略二选一；缓存路径白名单沿用 06-1 已批准项。
- [ ] 0B1-2 在 06-1 最佳配置（**writeback 开启**）下，用门 1 溯源 baseline 跑粗筛采集：`.accesslog`、定点重复 `goroutine?debug=2` dump、runtime trace。
  ⚠️ ⛔ 不得依赖 `/debug/pprof/block` 与 `/debug/pprof/mutex` —— 源码从未设采样率，二者为空。
- [ ] 0B1-3 **严格按 06-1 §2.6 生命周期顺序**（先排空归零 → 卸载原挂载 → `cache-size=0` 验证挂载读回 → 卸载 → GC/恢复门 → 清理目录）。
- [ ] 0B1-4 给出"`fileWriter.flush` 有/无材料阻塞信号"判定。
- ⛔ **停点 2**：回传粗筛证据与判定。**明确无材料信号 ⇒ 本任务终止于门 2A**，出报告后收口，⛔ 不建观测构建、⛔ 不改行为。

### 阶段 0-B2：门 2B instrumentation-only 精测（离线构建 + 环境）

- [ ] 0B2-1 基于**门 1 溯源源码与冻结工具链**实现 instrumentation-only 改动（仅 §2.2.2 允许的四项计时/计数）；登记完整 diff 与二进制身份（SHA256/MD5/BuildID）。
- [ ] 0B2-2 **实测观测开销**：同配置下 instrumented vs 门 1 baseline 的带宽差，登记为 `observability-overhead.tsv`；审计后硬门为`abs(delta)<M`，否则`STOP_INSTRUMENTATION`。
- [ ] 0B2-3 在 06-1 最佳配置下跑精测采集，取得逐段等待归属、每次 flush 的 chunk/slice 数、依赖等待数量与时间。
- [ ] 0B2-4 按 §2.2.3 写死口径计算 `F` 与 `G_max`（含重叠去重前后两值），给出 Amdahl 裁决。
- ⛔ **停点 3（审计替代规则）**：回传观测构建身份与观测开销；`abs(delta)>=M`立即
  `STOP_INSTRUMENTATION`。只有逐请求关键路径与排队换算均成立时才可使用Amdahl，否则
  `AMDAHL_NOT_APPLICABLE`并终止，不实现行为修改。

### 阶段 0-C：门 3 补丁与语义回归（离线）

- [ ] 0C-1 实现含**依赖闭包**的 range-scoped flush + 两臂对称观测计数。
- [ ] 0C-2 用门 1 冻结工具链同次构建 **baseline（= instrumentation-only）与 patched（= instrumentation + range-scoped）**；登记 SHA256/MD5/BuildID。
- [ ] 0C-3 执行 R1--R10 语义回归（离线临时卷），逐条留证；⛔ 任一失败即停止并回退。
- [ ] 0C-4 驱动脚本：复用 `t06-1-randrw-cache-driver.sh`，仅增加"按臂切换二进制 + 逐格校验 SHA256/BuildID"；分析器扩展 §3.5 指标。登记脚本 SHA256。
- [ ] 0C-5 `bash -n` + `--self-test`：矩阵顺序、二进制身份门、正式窗边界、时间锚、重叠加权、`ε`/`M`、四态裁决、附属假设裁决分支、排空顺序门、依赖闭包未退化门、缓存目录白名单检查。
- [ ] 0C-6 逐设备空间门复算（沿用 06-1 §2.5 口径，按本任务 runtime 重算）。
- ⛔ **停点 4**：回传补丁 diff（含依赖闭包实现说明）、R1--R10 全证据、两个二进制身份、self-test 结果，等第二方审核 + 用户授权。

### 阶段 1：Phase A（4 格 ABBA）

- [ ] 1-1 Phase 起始恢复门采用健康检查 + 被动稳定等待；本轮明确不对共享卷执行
  `juicefs gc --compact --delete`，避免以元数据改写改变待测状态。
- [ ] 1-2 按 `C1 → T1 → T2 → C2` 逐格执行：切换二进制并校验 SHA256/BuildID → 创建空缓存目录 → 私有挂载 → 预热 → fio 180 s → **保持挂载等排空归零 + 读回检查** → 优雅卸载 → 健康检查 + 被动稳定等待 → 清理本 RUN 缓存目录（前后各记 `incidents.tsv`）。
- [ ] 1-3 每格产出 06-1 §2.8 + 本任务 §3.5 全部指标。
- ⛔ **停点 5**：回传 Phase A 原始数据，由第二方独立复算。

### 阶段 2：条件 Phase B

- [ ] 2-1 仅 Phase A 有材料收益时执行 paired P1/P2；否则记 `PHASE_B_NOT_TRIGGERED` 并停止。
- [ ] 2-2 给出 §4.4 附属假设裁决（含预测检验结果，成败都要记）。
- ⛔ **停点 6**：回传结果并裁决。

### 阶段 3：收口（无论性能如何都必须完成）

- [ ] 3-1 **从环境移除调查构建二进制**并登记（`BUILD_DISPOSITION`）；确认后续挂载不会误用；确认生产二进制 `24fae085…` 未被替换。
- [ ] 3-2 scrub flag 精确恢复并验证。
- [ ] 3-3 无 fio / sampler / 挂载残留；各设备 `rawstaging` 归零。
- [ ] 3-4 删除本 RUN 自建缓存目录并验证；⛔ 不得递归删除非本 RUN 目录。
- [ ] 3-5 Ceph `HEALTH_OK`、6/6 OSD、97/97 PG active+clean；资产 128 × 1 GiB 完整。
- [ ] 3-6 证据打包 + SHA256SUMS + 持久化校验，再清远端临时根。
- [ ] 3-7 若有材料收益：整理上游 PR 材料（补丁 + **依赖闭包说明** + A/B + 语义回归 + profile 证据）。
- [ ] 3-8 按 skill 复核执行合规，回传自查结论。

## 六、交付物

```
/mnt/c/SunRise/test/06-2/<RUN_ID>/
├── build/            source-provenance.tsv b-catchup.patch apply-check.log
│                     toolchain.tsv build-command.txt go.sum.snapshot build.log
│                     baseline-identity.tsv instrumented-identity.tsv patched-identity.tsv
│                     range-flush.patch full.diff dependency-closure.md
│                     p0-smoke/  semantic-regression/{R1..R10}/…
├── profile/  gate2a/  accesslog.tsv goroutine-dumps/ runtime-trace.* signal-verdict.tsv
│           gate2b/  flush-wait-breakdown.tsv flush-chunk-slice-counts.tsv
│                    dep-wait.tsv observability-overhead.tsv amdahl.tsv
├── gate0/            gate.tsv self-test.* input-sha256.tsv base-config.tsv
│                     staging-headroom-per-device.tsv metric-names.tsv plan/
├── inventory/        只读环境快照
├── cells/<cell>/     mount-process.tsv（含二进制 SHA256+BuildID）findmnt.tsv foreign-fio.tsv
│                     warmup.log fio.json formal/bw/*.log formal/clat/*.log
│                     metrics-pre.prom metrics-post.prom juicefs-metrics-1hz.tsv
│                     flush-stats.tsv df-1hz.tsv iostat-1hz.tsv meminfo-1hz.tsv
│                     client-sidecar.tsv cache-dir-state.tsv drain.tsv readback.tsv
├── closeout/         构建移除、生产二进制未替换、恢复门、scrub 恢复、资产、健康
├── incidents.tsv     append-only
└── SHA256SUMS
```

- 正式报告：`doc/perf-report/06-2-randrw-m1-flush-investigation-<日期>.md`
- `doc/deploy-log/results-table.md` 追加小节
- 上位计划 §九 追加执行进展行
- 报告必带 §4.5 的**六条强制声明项**、R1--R10 逐条结果、§4.3 四条材料信号逐条 PASS/FAIL、§4.4 附属假设裁决
- 若门 2A/2B 任一即终止：仍须出报告，记录信号判定或 Amdahl 分解与 `STOP_RANGE_FLUSH` 裁决（门 2B 的分解是首个 randrw 读端停顿的**直接计数**分解，有独立价值）

## 七、通用注意事项（必带）

1. **数据统计口径**：主口径为实际 I/O 起点 + 重叠加权重采样 + 正式窗 + 四子窗；⛔ fio summary 不得作主口径。
2. **冷态净化**：⛔ 不执行 `drop_caches`（沿用 06-1 §2.7 页缓存观测口径）。
3. **fresh-volume / 冷启动失真**：预热合同为必须项，两臂完全一致。
4. **后端干净态**：每格后 GC + 被动恢复门；主动 OSD compact 默认禁用。
5. **环境前置检查**：只读 inventory 必须先过。
6. **记录规范**：判据指名数据来源文件；`incidents.tsv` **append-only**，动作前后各记一条。
7. **skill 合规自查**：测试前通读确认（0A-1），测试后复核（3-8）。
8. **分层授权**：可自主修复区 = 本 RUN 补丁与采集脚本、自建缓存目录、私有挂载；禁止擅动区 = 卷格式、pool/PG/CRUSH、TiKV/OSD 配置、`/mnt/juicefs`、固定资产、scrub 以外的集群开关、**生产二进制替换**、白名单外的本地路径。
9. **非性能门与性能端点分离**（§四.1 / §四.2 已分表）；**构建溯源、profile、语义回归均属非性能硬门**。
10. **RUN 有效性状态机与禁止补样**：四态预注册；⛔ 禁同 RUN 热改补丁/脚本后正常签收、换 RUN_ID 重来、补样替换、拼接无效 RUN 点值、门失败后改挑有利判据。失败即**保留现场**，⛔ 禁 `fusermount -uz` / `umount -l` / `rm -rf` / 模式 kill / kill mount PID。
11. **多臂设计**：ABBA 最小平衡筛选；同臂相邻对给 `ε`；`M = max(5%, 2ε)`；⛔ 禁先设边界后测噪声。零假设对照 = 两个 baseline 格之间。
12. **Gate 0**：三道门未过 ⛔ 禁止进入下一阶段。
13. **第二方复算**：执行方只交原始数据与补丁，统计、语义回归复核与裁决由第二方独立完成。
14. **scrub 条件性控制**：Gate 0 前二选一，Phase 内暂停、结束立即只恢复本任务拥有的 flag。
15. **证据分级**：`L1_SCREEN`，⛔ 不自动升级 `L2_FORMAL`。
16. **数据生命周期**：遵循 `TEST-DATA-LIFECYCLE-POLICY.md`，先持久化校验再清远端。
17. **精简与尽快闭环**：门 2 不过即终止；Phase A 出数即回答主问题；Phase B 未触发即取消。

## 八、红线汇总

**本任务特有：**

1. ⛔ **禁止删除 M1**（§一.2：POSIX 强制的单客户端 read-your-own-writes，删除是正确性缺陷）。
2. ⛔ **不得写"M1 是主因"**（§一.3：静态源码只证机制存在）。
3. ⛔ **不得预先宣称"语义完全等价"** —— 它是门 3 待验证的目标。
4. ⛔ **构建溯源门未闭合不得改码** —— 本地树 `44dd412a-dirty` 与交付基座 v1.4.1 `0b90c7db` 不同源；04 计划书 §1.1 line 68 为既有红线。
5. ⛔ **门 2A 明确无信号即停止改造**；历史门2B已回溯无效，未来须先满足§2.2.4，不能以原`G_max`准入；⛔ 动态调查必须在writeback目标模式下测。
5b. ⛔ **不得声称"零补丁可测得 flush 等待占比并算出精确 `G_max`"** —— `SetBlockProfileRate`/`SetMutexProfileFraction` 源码从未调用，pprof block/mutex 为空；精测必须走门 2B 观测构建。
5c. ⛔ **观测构建只准加计时与计数** —— 不改 flush 范围、提交顺序、依赖行为与任何控制流；且必须基于门 1 已闭合的源码与工具链，并登记观测开销。
6. ⛔ **必须实现依赖闭包** —— `s.dep` 跨 chunk（`writer.go:291`），只遍历重叠 chunk 会引入停顿；R5/R6 用例不得省略。
7. ⛔ **补丁行数不得作正确性门**，只作复杂度预警。
8. ⛔ **不得用 `object_request_data_bytes` 当请求数来源** —— 请求数取 histogram `_count`，字节与请求数分开记录。
9. ⛔ **`SHARED_OP_BUDGET` 只作探索性附属假设**；验证须同 RUN paired U150/U300；⛔ 不得与 05-2 历史样本作直接因果比较；预测失败必须记为削弱证据。
10. ⛔ **baseline 与 patched 必须同工具链同次构建**；⛔ 新增观测计数必须两臂对称。
11. ⛔ **若带宽涨而 flush 等待/chunk 数不动，先判补丁未生效**，不得直接采信。
12. ⛔ **该构建不得进入生产或交付路径**；收口须从环境移除并确认生产二进制未被替换。
13. ⛔ **writeback 格必须"先排空后卸载"**（沿用 06-1 §2.6）；⛔ 不改任何缓存参数；⛔ 不使用白名单外本地路径。
14. ⛔ 不触碰 `/mnt/juicefs`；⛔ 不 format / layout / destroy 卷。

**复述关键通用红线：** 性能端点不得删样；四态必须预注册且不得写"可生产/等价/确定无效/已达架构上限"；禁止补样与热改后正常签收；失败保留现场；`incidents.tsv` append-only；统计由第二方复算。

## 九、完成线

- [x] 06-1 裁决已回传，基座配置已冻结登记
- [x] **门 1** 构建溯源五步闭合，baseline 登记 SHA256/MD5/BuildID，P0 smoke 通过
- [x] **门 2A** 在 writeback 目标模式下取得粗筛证据并判定有材料阻塞信号
- [x] **门 2B** 已执行但经审计回溯为`GATE_INVALID`：两种`F`均无关键路径语义，观测开销约23%>`M`；不得未来复用
- [x] **门 3按限定口径完成**：真实FUSE R1--R8等通过，裁决仅为`QUALIFIED_GATE3_PASS`；⛔ 不得写成原合同R1--R10全通，依赖闭包缺少正面证据
- [x] Phase A 四格原始生命周期完成；T1/T2/C2正式窗/runtime合同失败，故登记`EVIDENCE_INVALID`而非性能PASS
- [x] Phase B未触发，已记`PHASE_B_NOT_TRIGGERED`
- [x] 第二方已给出证据有效性、机制与四态裁决；正式效应量因证据失效不计算
- [x] 调查构建已从环境移除并登记；生产二进制未被替换
- [x] 收口全项通过，证据持久化并校验
- [x] 正式报告、results-table与上位计划进展行已落地
