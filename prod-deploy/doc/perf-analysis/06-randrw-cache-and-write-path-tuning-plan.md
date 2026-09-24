# 06阶段计划：randrw 缓存与写路径深度调优

> 日期：2026-09-15（2026-09-15 按 GPT 评审意见修订：删除持久化模式"已达架构上限"的循环论证、
> 删除"只利用本地能力 4%"的错误口径、共享 op 预算降为探索性假设、06-1 缩为四格组合包筛选、
> 06-2 增加构建溯源门与动态 profile 门）
>
> 状态：`STAGE06_CLOSED_WITH_LIMITS / 06_2C_SCREEN_STOP_NO_CANDIDATE / NO_NEW_DELIVERABLE`；06-2b、06-2c、06-4、06-5均已结束，`CACHE-BURST-21P7 = COMBINED_SIGNAL_REPRODUCED / SOURCE_RESOLUTION_INSUFFICIENT`。
> **2026-09-22最终补充**：[06-2c源码探索](../perf-tasks/06-2c-randrw-write-path-source-optimization-screen.md)已完成。完整非增长对象块提前冻结候选通过正确性门，但两组C/T效应分别约`-5.6%`与`+2.5%`，同臂漂移达`16%～23%`，且前段增益转为后段下降和更长排空；裁决`SCREEN_STOP / RESOLUTION_INSUFFICIENT / NO_CANDIDATE`。旧任务裁决不变，07仍冻结。
> 06-1/06-2原RUN已结束，历史裁决不变；06-3六格安全闭环并完成本地原始归档复算，但后端起点漂移阻止配置收益归因。
> **2026-09-21最终订正（优先于下文历史设计）**：06-5已在维护窗口内完成统一恢复后的三臂六格复验。约21%的完整组合收益得到复现，普通缓存单独不足以解释；独立writeback增量受约7.55%同臂漂移限制，严格来源裁决仍为`PAUSED_INCONCLUSIVE`。06按限范围闭环，不再追加同模型样本。
> 扩大buffer、缓存策略及其他后续探索保留在[07阶段计划](07-randrw-cache-admission-and-write-path-optimization-plan.md)，状态`PLANNED_NOT_STARTED`；其中读前等待/eager-freeze源码候选现由06-2c统一承接，避免重复立项。文档规划不授权新的06负载、恢复操作或任何07工作。
>
> **2026-09-16后续合同（优先于下文06-1/06-2历史设计）**：用户确认写缓存可用于吸收有限突发，
> 完整180秒负载的平均R/W可重复提升即有价值，后段衰减/排空非零不自动否决；新任务以实际完成
> 字节/实际timed-I/O时长为主端点，保留过程曲线，排空和数据安全代价单列。不得修改历史合同后
> 追认原RUN。06-2b修复通知/范围并补正确性证据，06-3筛选新写块读缓存与writeback配置，详见§十。
>
> 2026-09-16审计订正：06-1的`+16.3%～+19.6%`撤销为窗长依赖瞬时量，轮内衰减由宿主脏页
> 吸收/回压获得强定量支持；06-2 Gate2B的Amdahl口径无关键路径语义并回溯为`GATE_INVALID`。
> 原始证据、正式有效性状态与“无生产候选”结论不变。
>
> 与 05 阶段的关系：**并行**，不互相阻塞。05 阶段保持"不同 I/O Block Size 下的性能曲线与竞品对比"定位；
> **06 阶段目标 = 对 randrw 做进一步调优**。新任务可记录与有方历史数值目标的差距，
> 06-3/06-2b及06-4均未访问有方环境；06-4在JuiceFS侧已无正向信号，因此不再触发竞品同模型补测。
>
> 立项依据：`report/周报-JuiceFS调优工作汇总-20260919.md`（§3 源码机制 M1--M4）、
> `doc/perf-report/04-tmp3j-direct-rados-write-service-curve-20260907.md`（对象后端 256K 写服务曲线，**非循环的独立证据**）、
> `doc/perf-report/05-2-randrw-upload-concurrency-and-buffer-gate-20260915.md`（U300 无一致收益）、
> `doc/perf-report/04-tmp2j-randrw-read-cache-capacity-curve-retest-20260907.md`（纯读缓存五档曲线）、
> `report/周报-JuiceFS调优工作汇总-20260912.md` §1.2（读缓存 `+12.32%`、读缓存+writeback `-16.88%`）
>
> 评审意见：`/tmp/review-06-stage-plan-and-taskbooks-20260915.md`（GPT，14 条全部受纳）
>
> 源码基线（**仅用于机制阅读，不作构建基座**）：`/mnt/c/SunRise/github/juicefs`，
> `v1.4.0-dev-467-g44dd412a-dirty`。⚠️ 交付基座是官方 v1.4.1 `0b90c7db` + B-catchup（MD5 `24fae085…`），
> 二者不同源；构建相关要求见 §四.2 与 04 计划书 §1.1。
>
> 任务：`doc/perf-tasks/06-1-randrw-cache-writeback-configuration-screen.md`、
> `doc/perf-tasks/06-2-randrw-range-scoped-flush-investigation.md`、
> [06-2b](../perf-tasks/06-2b-randrw-range-flush-repair-and-burst-validation.md)、
> [06-2c](../perf-tasks/06-2c-randrw-write-path-source-optimization-screen.md)、
> [06-3](../perf-tasks/06-3-randrw-cache-admission-and-burst-performance-screen.md)、
> [06-4](../perf-tasks/06-4-randrw-buffered-io-model-validation.md)、
> [06-5](../perf-tasks/06-5-randrw-cache-writeback-benefit-source-attribution.md)。
> 原文“06-3用于上游合入后交付验证”是旧预留，现由缓存筛选使用；06没有交付候选，不预留交付验证编号。未来候选的验证由07计划条件性承接。

---

## 一、为什么开展 06 阶段

05 阶段全部 randrw 数据都在 `cache-size=0` 下取得，而源码 `Config.SelfCheck` 明确该值为 0 时**连带强制关闭 writeback 与 prefetch**：

```go
if !c.CacheEnabled() {
    logger.Warnf("cache-size is 0, writeback and prefetch will be disabled")
    c.Writeback = false; c.Prefetch = 0
}
```

即 05-1/05-1b/05-2 的全部 randrw 数据都是"无读缓存 + 无写吸收 + 无预取"下取得的，是最保守模式。

三条立项依据：

1. **上传并发这条路已走到尽头。** 05-2 正式裁决 `RESOLUTION_INSUFFICIENT / SCREEN_CONTINUE=FAIL`：U300 未形成一致收益，没有继续扫描上传并发的依据。
2. **后端在纯写口径上没有形成 `2.2 GiB/s` 的独立硬上限。** 见 §三.1 —— 这是**独立测得**的，不来自被评价样本自身。⚠️ 但纯写与混合读写不是同一后端负载，直接 RADOS 只证明 PUT 没有在 `2.2 GiB/s` 处形成独立的**纯写**硬上限；randrw 的剩余约束**可能位于客户端路径，也可能来自 GET/PUT 混合服务关系**，需 06 阶段继续区分。
3. **源码已定位到四条具体机制（M1--M4）**，其中 M1 是不可配置的结构性耦合，且有语义**可能**等价的安全改法（待验证，见 §四.2）。

⇒ 06 阶段先用正确配置把缓存模式探一遍（06-1，零源码改动），再用动态证据决定是否值得改源码（06-2）。

---

## 二、四条机制（06 阶段的机制立论基础）

均为 1.4 源码确认，非推断。引用时必须带代码位置。⚠️ 源码树与交付基座不同源（见抬头），机制阅读有效，构建不得据此进行。

| 编号 | 机制 | 代码位置 | 可否配置消除 |
|---|---|---|---|
| **M1** | **每次 read 前无条件 flush 整个 inode 的写缓冲**，持 `fileWriter` 锁并等该文件**全部** chunk/slice 完成；非 writeback 下"完成"= 对象 PUT 返回 | `pkg/vfs/vfs.go:787`；`pkg/vfs/writer.go:386`；`pkg/chunk/cached_store.go:400` | **不可**（range-scoped 化为候选改法，见 §四.2） |
| **M2** | 新写的**满块**默认不进读缓存，需 `--cache-large-write`（默认 false） | `pkg/chunk/cached_store.go:368`；`cmd/flags.go:259` | 可；但 **writeback 下自动失效**（见 M2') |
| **M2'** | writeback 下 `stage()` 会把暂存块 `os.Link` **硬链接进读缓存**并注册 ⇒ 刚写的块天然本地可读 | `pkg/chunk/disk_cache.go:773` | — |
| **M3** | slice 级 COW，覆盖写产生新 slice ID/新 object key，旧缓存块不失效只变垃圾 ⇒ randrw 下读缓存对"当前数据"的命中率单调衰减 | `pkg/vfs/writer.go:110` `prepareID` | 部分（靠 M2' 补新块） |
| **M4** | `cache-size=0` 连带强制关闭 writeback 与 prefetch | `Config.SelfCheck` | 可（给足容量即可） |

### 2.1 M1 的性质：不可删除（防止误改）

- `grep -cE 'writer|Writer' pkg/vfs/reader.go` = **0**，`dataReader` 只持 `meta.Meta` 与 `chunk.ChunkStore` ⇒ **读路径在结构上看不见写缓冲**。
- 数据可读顺序受提交依赖约束（`pkg/vfs/writer.go:186` `commitThread`）：WB可让**没有冲突读时**的写先在本地stage并后台上传，但同inode读会先触发Flush，仍须等待相应脏slice`数据上传完成 → 依赖提交 → m.Write → reader.Invalidate`。FIFO按chunk内队列及实际依赖执行，不表示所有inode/chunk全局串行。

⇒ **M1 是单客户端 read-your-own-writes（POSIX 强制）所必需，不是跨客户端一致性机制。**
⛔ **禁止以"我方场景不需要多客户端一致"为理由删除 M1** —— 删除会给我方自身负载引入读到旧数据/空洞的正确性缺陷（fio randrw 本身就在同 offset 先写后读）。

### 2.2 M1 的地位：合理嫌疑，尚未证明是当前主因

静态源码路径只能证明**机制存在**，不能证明它占当前 randrw 停顿的主要部分。04-7 只能确认同步 DIO 提交/缓存协调参与停顿，尚未收窄到某个 JuiceFS 锁、writer flush、FUSE 队列或单一后台线程。

⇒ ⛔ **本阶段不得把 M1 写成主因**；06-2 必须先过动态 profile 门（§四.2）。

---

## 三、天花板认知（06 阶段的边界，已按评审修订）

### 3.1 持久化模式（`cache-size=0`）：没有继续扫上传并发的依据，但⛔ 不得称已达架构上限

**成立的部分**：fio randrw 50/50 **按发起数强制读写比例**（05-2 实测 READ `2015.89` vs WRITE `2012.15`，差 0.19%），故恒等式成立：

```
randrw 聚合 ≈ 2 × 应用写速率
```

**⛔ 已删除的错误论证**：此前用"05-2 最好格 C2 的应用写 `2120.09 MiB/s` × 2 = `4240.18 MiB/s`"当作架构上限，再拿同轮实测与它比得出"达成 95%--100%"。该"上限"直接来自被评价样本自身，命题退化为"最差格与最好格相差 5%"，只是**离散度**，**不能证明该模式已达不可突破的上限**。

**准确结论**：U300 没有形成一致收益（`RESOLUTION_INSUFFICIENT / SCREEN_CONTINUE=FAIL`），当前没有继续扫描上传并发的依据；⛔ 但不得把现有带宽定义为架构上限。

**独立证据（非循环，来自 04-tmp3j 直接 RADOS，绕过 TiKV/FUSE）**：

| 口径 | 值 |
|---|---:|
| 直接 RADOS 256 KiB 写 QD32 / QD64 / QD128 | `3271` / `3660` / **`3949 MiB/s`**（**未饱和**） |
| JuiceFS 在 05-2 randrw 中达成的对象 PUT 字节吞吐 | `2177 -- 2275 MiB/s` |

⇒ **直接 RADOS 只证明 PUT 没有在 `2.2 GiB/s` 处形成独立的**纯写**硬上限；randrw 的剩余约束**可能位于客户端路径，也可能来自 GET/PUT 混合服务关系**，需 06 阶段继续区分。** 这是 06 阶段的核心立项依据 —— 它把「该模式无空间」这一错误结论替换为一个**待区分的开放问题**，⛔ 而不是替换成「瓶颈已定位在客户端」。

⚠️ **必带限定（⛔ 不得省略）**：
1. 04-tmp3j 是**纯写、无并发 GET**；而 05-2 中后端同时承担约 `2.0 GB/s` GET，对象层总量约 `4.2 GB/s`，已接近 RADOS 纯写的 `3.95 GB/s`。
2. 04-tmp3j 自述 `3948.86 MiB/s` "只是本次最高观测点，不得写成 Ceph 写服务的最终上限"。
3. ⇒ 只能得出"后端未在 2.2 GB/s 硬封顶"，⛔ **不得推出"PUT 可达 3.9 GB/s"**，也⛔ 不得据此预告任何具体收益幅度。

### 3.2 缓存模式：本地读路径本身有充足读能力（定性），但⛔ 上限未知

**⛔ 已删除的错误口径**：此前用"`1393.98 MiB/s` ÷ `34.83 GiB/s` ≈ 4%"表述"只利用了本地能力的 4%"。该比较有双重错配：分子是 randrw **单方向**均值（聚合约 `2788 MiB/s`），分母是热缓存下的**纯 mseqread/randread** 结果。

**可成立的定性表述**：热数据完整容纳时多流顺序读/随机读实测 `34.83 / 36.53 GiB/s`（0912 周报 §3.4.2），**只能证明客户端本地读缓存路径本身具备充足读能力**。

**⛔ 不可成立的表述**：
- ⛔ "randrw 只利用了 4% 的缓存能力"
- ⛔ "cache+writeback 的上限就是本地介质带宽"

理由：randrw 混合路径还包含本地缓存读、staging 写、元数据提交、后台对象上传、FUSE、CPU、锁等待与远端未命中读取，**纯读结果不构成 randrw 的上限**。

**现状唯一数据点**（0912 周报 §1.2，⚠️ 该格 `cache-size` 仅为热集 25%）：

| 配置 | 双方向均值 | 相对无缓存 | 排空 |
|---|---:|---:|---:|
| 只开读缓存 128 GiB | 1850.82 MiB/s | `+12.32%` | 0 s |
| 读缓存 + writeback（25% 容量） | 1393.98 MiB/s | **`-16.88%`** | **57 s** |

⇒ 06-1 的任务是在**容量与本地并行度都改善后**重新测一次，⛔ 不预设结论、⛔ 不预告幅度。

### 3.3 长期稳态：writeback 只是突发吸收

- writeback 是**突发吸收**不是稳态吞吐 —— 排空 `57 s` 即证据；0912 周报 line 132 已述"缓存容量增加只能吸收更多暂存数据，不能提高长期持久化服务率"。
- ⚠️ 稳态排空率的**保证值未知**：05-2 观测到的 `≈2.2 GB/s` 来自 `cache-size=0` 配置，**不是 writeback 配置下的保证值**，⛔ 不得直接用于 writeback 场景的容量估算（见 §五.2 空间门）。
- **吸收介质只能是盘、不能是内存**：`SelfCheck` 明确 `writeback is not supported in memory cache mode`。
- ⇒ 任何 06 阶段的短窗收益**必须同时报排空时长与净积压峰值**，⛔ 不得把前台加速等同于长期持久化带宽提升。

### 3.4 一条探索性假设（⛔ 不作预设结论）

`SHARED_OP_BUDGET` 假设：05-2 中 GET `≈8064 ops/s` + PUT `≈8711 ops/s` ≈ `16.8k object ops/s`；若读改由本地供给使 GET 预算释放，PUT 可能上升。

⚠️ **该数只是某一轮混合负载的观测和，不是独立测得的对象层容量。** 因此：

1. ⛔ `16.8k ops/s` 与 `×1.9` **只能作探索性预测，不得写成高可信上限**。
2. B1M 字节吞吐更高（`6.07--6.15 GiB/s`）也**不能单独证明** B256 必然受固定 op 预算限制 —— BS、对象大小、放大、客户端发起能力与队列形态均已改变。
3. ⚠️ **writeback 模式下前台应用写与后台 PUT 已解耦**：前台带宽上升而 PUT 不变，既可能是短窗积压增加，也可能是读路径改善，**无法直接区分**共享预算与 PUT 专属上限。
4. ⇒ 验证须用**同一 RUN、同一基座的 paired U150/U300**，⛔ 单格不足以判定（见 §四.2）。

---

## 四、任务分解

本节保留06-1/06-2原始任务分解供追溯；后续执行入口改为§十，禁止复用已作废的Amdahl准入门。

```text
06-1  cache+writeback 组合包筛选（零源码改动，L1_SCREEN，四格）
      └─ 有材料收益 → 登记**组合包** L1 候选；另立小任务拆变量归因；⛔ 不在 06-1 内扩矩阵
      └─ 无材料收益 → 关闭该配置包，⛔ 不追加单格找漂亮样本，直接进 06-2 profile 门
  ↓
06-2  两道前置门 → 才谈改码
      门1 构建溯源：还原 v1.4.1 0b90c7db + B-catchup、冻结工具链、baseline 登记 BuildID/SHA256、
           与现有 24fae085 做 P0 smoke（04 计划书 §1.1 既有红线）
      门2A 零行为修改粗筛：.accesslog + goroutine dump + runtime trace，只判有无材料阻塞信号
           （pprof block/mutex 默认关闭、源码从未设采样率 ⇒ 空 profile，不可作精测）
      门2B instrumentation-only 观测构建（只加计时与 chunk/slice/依赖计数，不改行为）：
           由直接计数算 G_max = 1/(1-F)-1；< M = max(5%,2ε) ⇒ 停止 range-flush 改造
      └─ 两门皆过 → 实现含**依赖闭包**的 range-scoped flush → 语义回归 → 四格 ABBA
预留  06-3（如需）：上游 PR 落地后的正式效应量与七项非劣回归
```

### 4.1 06-1：cache+writeback 组合包筛选（四格）

回答：**`96 GiB 读缓存预算 + writeback + 本地多路径`这一整套配置包，相对同轮无缓存锚，randrw 能否取得材料收益？**

⚑ **因果范围（强制声明项）**：Phase A 同时改变 `cache-size`（0→96 GiB）、writeback（关→开）、`cache-dir` 数量与物理设备。**它只能回答"这套组合包是否有收益"，⛔ 不能归因到容量、writeback 或多路径各自的贡献，⛔ 不得表述为"逐个消除混杂"。** 若有正收益，另立小任务拆变量。

三项配置的性质（已按评审降级表述）：

| 项 | 核实结论 | 表述要求 |
|---|---|---|
| `cache-size=98304 MiB`（96 GiB） | 04-tmp2j 五档效应 `+5.62/+3.95/+9.82/+11.07/+14.84%`（32/64/96/128/256 GiB），命中率 `11.08%→47.41%`，`M=5.03%`；96 GiB 为**最小平台档**（`+9.82%`、命中 `31.55%`） | ⛔ 不得称"容量给足"。称**"固定 96 GiB 读缓存预算"**；底层文件系统可用物理容量作**独立安全条件** |
| 多 `--cache-dir` 跨设备 | 源码只证 `raw/` 与 `rawstaging/` 同属一个 cache store（`disk_cache.go:718/722`）且 M2' 的 `os.Link` 要求同一文件系统 ⇒ **"分盘"不可实现**；但**未实测**原测试的本地盘是否在带宽/IOPS/时延上饱和 | ⛔ 不得称"已核实混杂"。称**"提高本地并行能力的候选配置"**；须用既有或本轮 iostat 说明单盘是否饱和 |
| `--upload-delay=0s`（默认） | 暂存完成后内联发起上传并占用 `currentUpload` 槽（`cached_store.go:443`） | 主格保持默认以使积压有界；"拉开"属另立任务 |

附带确认（不作受测变量，仅写入禁止项）：
- 暂存块以 `size<0` 记录、**不占 `cache-size` 预算**；`cleanupExpire` 遇 `size<0` 直接 `continue` ⇒ 过期淘汰不淘汰未上传暂存块。
- `stagedBlockCooldown = CacheExpire/2`，`--cache-expire` 默认 `0s` ⇒ 回拨量为 0。
  ⛔ **06 阶段禁止设置 `--cache-expire`**，否则刚写的块被优先逐出读缓存。
- `--cache-large-write` **降级**：writeback 下已被 M2' 覆盖，仅非 writeback 场景需要。

### 4.2 06-2：两道前置门 + 含依赖闭包的 range-scoped flush（历史方案，Gate 2B已审计作废）

**门 1｜构建溯源（04 计划书 §1.1 既有红线）**

04-4 报告已明载：V14 = 官方 v1.4.1 `0b90c7db` + B-catchup patch，**"exact build command、Go version、binary SHA256/BuildID 因本地构建现场丢失而未闭合"**；04 计划书 line 68 要求"若不是部署归档中的同 MD5 binary，而是重新构建，必须先补齐 source/patch/toolchain/BuildID/SHA256 可重现性和 P0 smoke"。

而本地源码树为 `v1.4.0-dev-467-g44dd412a-dirty`，与交付基座**不同源**。⇒ ⛔ **不得从当前树构建 baseline 并声称它与交付二进制只差 range-flush 一项。** 必须先：

1. 还原官方 v1.4.1 `0b90c7db` + 精确 B-catchup patch；
2. 冻结 Go 版本、依赖与完整构建命令；
3. 构建**未修改行为**的 baseline 并登记 SHA256 / MD5 / BuildID；
4. 新 baseline 与现有 `24fae085…` 做 P0 兼容性 smoke；
5. 以上通过后才能构建 range-flush 版本。

**门 2｜动态 profile（拆 2A 粗筛 + 2B 精测，Amdahl 裁决）**

⚑ 静态源码不能证明 M1 是主因（§二.2）。但**"零补丁测得 flush 等待占比"不可执行**，已核实：

- `SetBlockProfileRate` / `SetMutexProfileFraction` 在 JuiceFS 源码中**从未被调用**（全树 `grep` 无命中），Go 默认 `0` ⇒ `/debug/pprof/block` 与 `mutex` 返回**空 profile**；
- `.accesslog` 只有完整 VFS 操作耗时，无法拆出 `writer.Flush` 内部时间；
- 源码没有 flush chunk/slice 数、依赖闭包规模、逐段等待时长的任何现成指标。

故拆为：

| 门 | 手段 | 判定 |
|---|---|---|
| **2A 粗筛**（零行为修改） | `.accesslog` + 定点重复 `goroutine?debug=2` dump + runtime trace（原生记录阻塞事件，不依赖采样率） | 只回答 `fileWriter.flush` **有无材料阻塞信号**。明确无 ⇒ `STOP_RANGE_FLUSH`；有信号或分辨率不足 ⇒ 进 2B |
| **2B 精测**（instrumentation-only 构建） | 仅加 ① `writer.Flush` 前后计时 ② 每次 flush 的 chunk/slice 数 ③ 依赖等待数量与时间 ④ 逐段等待归属。⛔ 不改 flush 范围/提交顺序/依赖行为/任何控制流 | **历史判据已作废**：墙钟并集与并发等待和都不能表示串行关键路径；本RUN回溯`GATE_INVALID` |

⚑ **历史 Amdahl 口径（保留追溯，2026-09-16审计判定无效）**：

```
F     = 正式窗内可归因于 writer.Flush 的 read 等待时间 / read 端总等待时间
G_max = 1 / (1 - F) - 1
裁决：G_max < M = max(5%, 2ε) ⇒ 停止行为修改
```

本RUN的墙钟并集`F≈0.99999`在高并发下构造性趋1，并发等待和`F≈0.8964`也不能直接换算墙钟吞吐，
故上述公式不得未来复用。未来若再调查，必须使用逐请求关键路径口径并给出排队换算；换算不可得则
标记`AMDAHL_NOT_APPLICABLE`。同时观测开销须设硬门`abs(delta)<M`，`ε/M`须来自同RUN同基座有效对照。

⚠️ **2A 与 2B 都必须在 06-1 的目标模式（writeback 开启）下测。** 非 writeback 下 flush 等的是对象 PUT（`17--21 ms`），writeback 下等的是本地盘写 —— M1 成本相差一个量级，**拿错模式会给出相反裁决**。

⚑ 观测代码虽不改行为，**仍属源码修改** ⇒ 必须基于门 1 已闭合的源码与工具链构建，并**登记观测开销**。且 **Phase A 的 baseline 就是这个 instrumentation-only 构建**，patched 为"instrumentation + range-scoped"，二者观测点与采样配置**构造性相同**。

**改法要求｜依赖闭包（评审发现的硬伤）**

`pkg/vfs/writer.go:291` 注释即为 "first slice of a new chunk, try to find **the last slice of the last chunk** as dependency"，`s.dep = lastSlice` 是**跨 chunk**的；`commitThread` 中 `for s.dep != nil && !s.dep.committed` 会等它。

⇒ 只冻结与读区间重叠的 chunk 会让目标 slice 等待一个**区间外、从未被 freeze** 的依赖，只能靠 3 s 超时循环或 `flushDuration*2` 自动 freeze 兜底，**反而引入停顿**。

因此：
- 实现**必须处理依赖闭包**，不能只做"遍历重叠 chunk"；
- **"语义等价"是待回归验证的目标，⛔ 不是已成立的结论**；
- **补丁行数不作正确性硬门**，只作复杂度预警（40 行的错误补丁会过门，80 行的正确补丁会被误挡）；
- 回归须覆盖"目标 chunk 依赖区间外 growing slice"、跨 chunk 扩展、并发读写、部分重叠 slice；
- 保留 `Flush/FlushAll/Close/fsync/Truncate/CopyFileRange` 等全量语义路径。

**`SHARED_OP_BUDGET` 只作附属假设**，验证须用同 RUN 同基座的 paired U150/U300（§三.4）。

### 4.3 明确不在 06 范围

- 不自动访问竞品环境；历史环境信息不足的比较保留限制，不将环境可用性写成永久事实。06-4竞品补测另批；本阶段不以256K结果声称全部BS胜出。
- ⛔ 删除 M1（§二.1 已论证为正确性缺陷）。
- 不再默认重扫纯读缓存容量全曲线；06-3§七必要的两点归因不在此禁令内，须按证据另批。
- ⛔ `--max-uploads` 更高档位（U450/U600）。
- ⛔ 卷 BlockSize 再扫描（属 05-1b 已闭环范围）。
- ⛔ 在 06-1 内追加不能形成因果对照的单格（含原 Phase B/C，已按评审删除）。
- ⛔ 几何自证诊断（`iodepth×bs/filesize` 扫描）：目的是解释有方数据，归 05 阶段。

---

## 五、统一测试口径（06 阶段全任务通用）

> 本节保留06-1/06-2历史口径。后续06-3§七、06-2b和06-4以各任务新合同为准：完整字节/实际时长为主值，不裁慢尾，不机械套用每轮GC；06-4的direct=0结果独立归类。

- **fio 合同逐字沿用 05 系列**：`randrw 50/50`、128 jobs × iodepth 128、`direct=1`、每文件 1 GiB、`runtime=180 s`、复用既有 `rw_test` 128×1 GiB 固定资产，⛔ 不 layout、⛔ 不新建/销毁卷。
- **主口径**：实际 timed-I/O 起点后 `[15,175)` 的 160 s 逐秒聚合；同时报 mean / median / 秒级 CV / P10 / P90 与 W1--W4 及 `W4/W1`。fio summary 只作旁证。
- **卷与基线**：157、既有 B256 卷、FUSE256K、`buffer-size=300`、`max-uploads=150`、`max-downloads=200`。**只有缓存相关参数是受测变量。**
- **无缓存锚必须同轮采集**：⛔ 不得引用历史 `cache-size=0` 数字作对照。
- **平衡设计**：`L1_SCREEN` 允许单个 ABBA；同臂相邻对给噪声底 `ε`，`M = max(5%, 2ε)`；`ε >= 5%` 记 `RESOLUTION_INSUFFICIENT`。⛔ 禁先设边界后测噪声。
- **四态裁决**：`VALID` / `EVIDENCE_INVALID` / `RESOLUTION_INSUFFICIENT` / `INCONCLUSIVE`。
- **第二方复算**：执行方只交原始数据，统计与裁决由第二方独立复算。
- **单位统一**：容量与积压一律用 **GiB**，带宽一律用 **MiB/s** 或 **GiB/s** 并显式标注；⛔ 禁 GB/GiB 混用。

### 5.1 writeback 生命周期顺序（强制，⛔ 不得改序）

```
fio 结束
→ **保持 JuiceFS 挂载存活**（由它继续上传 rawstaging）
→ 等待并验证 staging/rawstaging 归零
→ 必要的读回检查
→ 优雅卸载
→ 后端状态检查；GC/compact仅在精确方案另行获批时执行
→ 仅在已验证归零后，才清理本 RUN 缓存目录
```

⚠️ **排空超时 ⇒ 保留挂载与现场取证**，⛔ 不得先卸载再尝试正常排空。
理由：卸载后 `uploader()` goroutine 已终止，`rawstaging` 内未上传块只能靠下次挂载同一 cache-dir 续传；若此时删除缓存目录，**未上传数据直接丢失**。

### 5.2 staging 空间门（按设备逐一过门）

- 排空下界取**既有 writeback 实测的保守值**（如 04-tmp2f 的实测排空能力与脏峰值 `≈53 GiB`），⛔ 不得用 05-2 在 `cache-size=0` 下观测的 `2.2 GB/s` 当保证值。
- 前台写入取**上界**，并加安全余量。
- **一致性哈希不保证暂存块均匀分布** ⇒ 必须按**每个 cache-dir 所在设备最坏偏斜**分别过门。
- 短窗净积压可能达数百 GiB，**远大于 96 GiB 读缓存预算**；两者记账不同（暂存块 `size<0` 不占 `cache-size`），但**争用同一文件系统可用空间**，须一并计入。
- ⛔ 不得在 `stageFull`（设备可用空间比 `< free-space-ratio/2`）会命中的配置下跑正式格。

### 5.3 06 阶段专属必采指标（指标名已按评审订正）

| 指标 | 来源（prometheus 名，`juicefs_` 前缀） | 用途 |
|---|---|---|
| **对象请求次数** | **`object_request_durations_histogram_seconds_count{method=...}` 增量** | **PUT/GET ops/s 的唯一主口径** |
| 对象数据字节吞吐 | `object_request_data_bytes{method=...}` 增量 ÷ 正式窗长 | 字节吞吐；⛔ **该指标是字节计数器，不得当作请求数来源** |
| 对象请求错误 | `object_request_errors` | 硬门 |
| 读缓存命中 | `blockcache_hits` / `blockcache_miss` / `blockcache_hit_bytes` / `blockcache_miss_bytes` | 缓存是否真在工作 |
| 本地缓存写入与淘汰 | `blockcache_writes` / `blockcache_write_bytes` / `blockcache_drops` / `blockcache_evicts` / `blockcache_blocks` / `blockcache_bytes` | 本地介质写入量与淘汰压力 |
| 本地缓存读时延 | `blockcache_read_hist_seconds` | 本地读路径成本 |
| **暂存错误与延迟** | **`staging_block_errors`** / `staging_block_delay_seconds` | **stage 是否静默回落同步 PUT** |
| `stageFull` 命中 | 挂载日志 + 各缓存设备可用空间比逐秒 | 硬门（§五.2） |
| 上传在途 | `object_request_uploading` **mean / p95 / max** | **三项都要**（05-2 D1 教训：p95 不是运行水位） |
| **排空时长 + 净积压峰值** | fio 结束到 `rawstaging` 归零的时长；`rawstaging` 占用逐秒峰值 | **§六 强制项** |
| 各缓存设备 iostat + `/proc/meminfo` | 逐秒 | §5.4 解释规则 |
| 客户端 CPU / NIC | 逐秒 | 排除客户端成为新瓶颈 |

⚑ 指标名在 Gate 0 必须**从实际 `.prom` dump 核对**，⛔ 不得凭文档假设（本条即由指标来源错误的评审意见固化而来）。

### 5.4 缓存命中的解释规则（继承 04-tmp2j）

04-tmp2j 报告 §line 74--78 已记录：预热数据驻留 Linux 页缓存 ⇒ 正式窗内块设备读计数接近零。

⇒ **预注册解释规则**：若正式窗块设备读计数接近零而应用带宽高，**判为"命中经由页缓存供给"**，⛔ 不得表述为 NVMe 介质速度，⛔ 不得据此推算可持续本地带宽。

---

## 六、判定规则

1. **唯一通过/不通过项**由各任务书指定，其余只报数据。
2. **材料收益**：READ 与 WRITE 两方向、两组位置配对效应**同向**，且较小效应 `>= M = max(5%, 2ε)`。
3. **机制自洽检查（后续任务订正）**：核对应用完成字节、缓存/页缓存服务、上传和积压变化。缓存命中可降低后端请求，有限突发可增加积压，不能强求本地介质或PUT吞吐上升；机制证据不足则限制归因，不据此删除真实前台结果。
4. **非性能硬门与性能端点严格分离**：只有非性能门可删样；带宽/CV/`W4/W1`/延迟**再差都是结果**。
5. **持久性声明强制项**：任何涉及 writeback 的结论必须同时写明"ack 先于持久化 + 排空窗口时长 + 净积压峰值 + `stageFull` 命中时静默回落同步 PUT"，⛔ 不得以"性能提升"单独结论。
6. **因果范围强制声明项**：组合包实验的报告**必须**在结论节显式写明其不可归因范围（§四.1），⛔ 不得只在正文提一句。
7. ⛔ **不得写"可生产""等价""确定无效""已达架构上限"。**

---

## 七、稳定性、安全与证据边界

- 06-3/06-2b按各轮私有挂载控制缓存起点；06-4也采用每格新私有挂载，避免FUSE页缓存跨格继承而不执行全局`drop_caches`。结束时优雅卸载（WB顺序见 §5.1）；⛔ 禁 `fusermount -uz` / `umount -l` / 模式 kill。
- ⛔ 不 format / layout / destroy 卷，不改 pool/PG/CRUSH/TiKV/OSD 配置，不 `drop_caches`（会破坏 §5.4 观测口径）。
- **本地缓存路径须逐路径显式批准**：每个 `cache-dir` 必须来自白名单，记录源设备/文件系统/挂载点/属主/可用空间/业务用途；⛔ 排除系统盘、`md0`、Weka 盘、业务盘及未知挂载；每个目录必须本 RUN 创建、非符号链接、起点为空；清理只覆盖本 RUN 目录，动作前后各记一条 `incidents.tsv`。
- scrub 策略在 Gate 0 前二选一并精确恢复（沿用 05 系列，指导书 §二.19.1）。
- 主动 OSD compact 默认禁用，仅在恢复门连续超时后按预列命令与授权行执行。
- 唯一持久化证据根 `/mnt/c/SunRise/test/06-*/<RUN_ID>/`，遵循 `TEST-DATA-LIFECYCLE-POLICY.md`。
- 06-2 的调查构建二进制须登记 SHA256 / MD5 / BuildID 与源码 diff，标注 `INVESTIGATION_BUILD / NOT_FOR_PRODUCTION`，收口时从环境移除并登记。

---

## 八、阶段交付物

1. 06-1 / 06-2 正式报告各一份（`doc/perf-report/`），均须含因果范围声明与持久性声明。
2. `doc/deploy-log/results-table.md` 追加对应小节。
3. **必须交代历史21.7%观察收益的去向**：06-3§七先复现，再优先拆WB增量；不要求旧06-1先通过L1门，也不默认新建任务。若要精确归因或生产交付，另批相应L2/回归；不自动升级。
4. 若 06-2 两门皆过且有材料收益：上游 PR 材料一份（补丁 + 依赖闭包说明 + A/B + 语义回归 + profile 证据）。
5. **randrw 调优结论汇总**：各模式下的最优配置与其语义代价，供 05-6 与对外材料引用。

---

## 九、执行进展

| 日期 | 事项 | 结论 |
|---|---|---|
| 2026-09-15 | 06 阶段立项，与 05 并行 | 目标 = randrw 进一步调优；不产出竞品对比结论 |
| 2026-09-15 | 06-1 / 06-2 任务书起草 | 初稿完成 |
| 2026-09-15 | GPT 评审（`/tmp/review-06-stage-plan-and-taskbooks-20260915.md`） | **14 条意见全部受纳**。主要修订：①删除"持久化模式已达架构上限 95%--100%"的循环论证，改用 04-tmp3j 直接 RADOS（`3271/3660/3949 MiB/s` 未饱和）作非循环证据，结论改为"后端未硬封顶、约束在客户端"；②删除"只利用本地能力 4%"的错误口径（单方向 vs 聚合、混合 vs 纯读双重错配）；③writeback 生命周期改为"先排空后卸载"（原顺序在超时时会随缓存目录清理丢失未上传数据）；④06-2 增加构建溯源门（本地树 `44dd412a-dirty` 与交付基座 v1.4.1 `0b90c7db` 不同源，且工具链/BuildID 早已记录为未闭合）与动态 profile/Amdahl 门；⑤M1 降为合理嫌疑，⛔ 不得写成主因；⑥`s.dep` 经核实为**跨 chunk**依赖，range-scoped 必须实现依赖闭包，"语义等价"降为待验证目标，行数门降为复杂度预警；⑦ops/s 改用 `object_request_durations_histogram_seconds_count`（原用字节计数器，属指标来源错误）；⑧共享 op 预算降为探索性假设，验证须同 RUN paired U150/U300；⑨06-1 缩为四格组合包并加因果范围强制声明；⑩96 GiB 改称"固定读缓存预算"（实测 `+9.82%`/命中 `31.55%`，非容量给足）；⑪单盘饱和降为候选（未实测）；⑫多设备改逐路径白名单 + 逐设备空间门；⑬删除 Phase B/C；⑭空间公式按设备、统一单位、保守下界 |
| 2026-09-15 | GPT 执行就绪度最终校验（`/tmp/final-review-06-stage-execution-readiness-20260915.md`） | 裁决 `NEEDS_MINIMAL_REPAIR_BEFORE_EXECUTION`，**4 条全部受纳**：①06-1 阶段 0 的授权边界自相矛盾（标题禁 SSH 但 0-4/0-7/0-8 需远端只读）⇒ 拆为**阶段 0A 纯离线（禁 SSH）+ 阶段 0B 远端只读（写操作数=0）**，停点相应增为 3 个；②原挂载读回**不能证明远端持久化**（带读缓存 + 页缓存）⇒ 改为**卸载原挂载后用 `cache-size=0` 私有验证挂载抽样读回**，并声明只做可读性 + 无 EIO、⛔ 不构成内容正确性验证（随机覆盖无期望内容清单，内容校验须改冻结负载，属另立任务）；③**原"零补丁测全四项 profile"合同不可执行** —— 核实 `SetBlockProfileRate`/`SetMutexProfileFraction` 全树从未调用，pprof block/mutex 为空 ⇒ 门 2 拆为**2A 零行为修改粗筛**（accesslog + goroutine dump + runtime trace，只判有无材料信号）与 **2B instrumentation-only 观测构建**（只加计时与 chunk/slice/依赖计数，由直接计数算 G_max），并写死 `F` 与 `G_max = 1/(1-F)-1` 口径、重叠不得重复累计、Phase A baseline 即为该观测构建（观测点构造性对称）；④04-tmp3j 归因措辞仍偏强 ⇒ 全库统一改为"纯写口径无 `2.2 GiB/s` 硬上限；剩余约束**可能在客户端路径，也可能来自 GET/PUT 混合服务关系**，待 06 阶段区分"。当前状态：`06-1=可进阶段 0A`、`06-2=BLOCKED`、`FORMAL_LOAD=NOT_AUTHORIZED_YET` |
| 2026-09-15 | 06-1 阶段 0A 离线 Gate（`RUN_ID=20260915-200000`） | GPT + Luna 二方 `SIGNED_OFF`；driver/analyzer/Gate 自测、严格 160 秒采样、§2.8 指标、生命周期与历史回放全部通过；远端调用数 `0`，证据已持久化至 `/mnt/c/SunRise/test/06-1/20260915-200000/gate0/`。状态升为 `READY_FOR_GATE0B`；0B 与正式负载均未授权。 |
| 2026-09-15 | 06-1 阶段 0B 只读清点（`RUN_ID=20260915-200000`） | GPT + Luna 条件签收：Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean、三节点 pending-compaction=0、128×1GiB资产及全部机制指标通过；远端写操作数=0。唯一候选 `/mnt/jfs-cache/04tmp3` 空间门在零排空保守上界下仍余 `200.499 GiB`；仅一个物理设备，记 `MULTI_DIR_UNAVAILABLE`。driver 已加入逐格路径身份漂移硬门并重新通过 0A r2。等待用户确认同盘 `/mnt/beegfs-meta` 不承载业务并批准候选路径；正式负载未授权。 |
| 2026-09-15 | 06-1 Phase A 与收口（有效 `RUN_ID=20260915-204941`） | 四格生命周期与原始流有效；`+16.32%～+19.56%`经审计改判为窗长依赖瞬时量，不登记效应。T格CV=`38%～42%`、W4/W1=`0.387～0.414`；脏页字节预算闭合支持“RAM吸收→内核回压”，设备读近零说明命中主要来自宿主页缓存。裁决仍为`RESOLUTION_INSUFFICIENT / NO_CANDIDATE`，不重跑。报告：`doc/perf-report/06-1-randrw-cache-writeback-configuration-screen-20260915.md`。 |
| 2026-09-15 | 06-2 启动判断 | 06-1 未产出可交付配置，但证明缓存/writeback真实改变GET/PUT路径并暴露强烈轮内衰减；whole-inode flush仍是合理嫌疑。允许只进入06-2的构建溯源门与动态profile门，⛔ 尚不实现range-scoped行为补丁。 |
| 2026-09-16 | 06-2 门1--门3、Phase A 与收口（`RUN_ID=20260916-091446`） | Gate1/Gate2A通过；Gate2B经审计回溯`GATE_INVALID`：两种`F`均无关键路径语义，观测开销约23%>`M=14.64%`。补丁观测scope约`1.87→1.00`，但依赖闭包计数全零且flush wait升至`52/51 ms`；Phase A另因覆盖/runtime失败为`EVIDENCE_INVALID / NO_DECISION`。Phase B不触发、不登记候选、不重跑。报告：`doc/perf-report/06-2-randrw-m1-flush-investigation-20260916.md`。 |
| 2026-09-16 | 新建06-2b/06-3，采纳有限突发目标 | 只制定。06-2b补通知/范围正确性，用无重仪表构建比较；06-3先重算旧证据，再六格筛选缓存配置包。后段下降不否定完整180秒收益；原RUN裁决不变。 |
| 2026-09-16 | 06-3初版离线准备 | 新driver/analyzer/Gate、34项统计自测、mock恢复/排空和独立历史重算通过；初版证据`/mnt/c/SunRise/test/06-3/20260916-155931/offline/`，后来被下行容量合同修订版取代。06-1全程读/写组均值观测差约+21.73%/+21.68%，仅回顾性线索，原裁决不变；06-2b未启动。 |
| 2026-09-16 | 06-3现场清点前容量合同修复 | 发现旧“峰值写满210秒且零上传”预留式对当前约879GiB盘不可行，改为读缓存＋暂存占用硬上限、轮内监测越线停负载；35项分析器自测及新Gate`/mnt/c/SunRise/test/06-3/20260916-161032/offline/`通过。只读连接与目录存在已核，但完整现场身份采集被自动安全审查拦下，需明确这些字段的保存授权。 |
| 2026-09-16 | 06-3获准只读清点与指标契约修复 | 157现有128×1GiB资产、JuiceFS二进制、NVMe空闲约834.4GiB、内存约916GiB、Ceph HEALTH_OK/6/6/97 clean核实；缓存盘与`/mnt/beegfs-meta`共盘。现场JuiceFS不注册pending指标，驱动/分析器改为明确`UNREGISTERED`/原始`NA`，不得假记0。新离线Gate`/mnt/c/SunRise/test/06-3/20260916-161945/offline/`通过并取代旧Gate；正式负载及全局scrub操作未授权。 |
| 2026-09-16 | 06-3获准正式六格执行 | `C1/S1/W1/W2/S2/C2`全部生命周期PASS、Ceph scrub flags精确恢复；fio全程读/写约`488–639 MiB/s`，明显低于06-1，但本RUN对象起点约526万（06-1约200万），且C1后TiKV pending-compaction不再为零，C1→C2约−23.6%。六格数字有效、缓存效应不可判，不登记候选。157原始归档已生成但本地复制被安全审查拒绝，需明确授权指定载荷与目标。详见06-3报告§八。 |
| 2026-09-16 | 06-3授权后证据持久化 | 用户明确批准指定原始包从157复制到`/mnt/c/SunRise/test/06-3/20260916-161945/raw.tar.gz`；本地/远端SHA256一致，6044个归档成员路径与类型合规。本地冻结分析器复算主值、比较和裁决与157一致，表格逐字节一致；不改变“效应不可判、不追加分支”的结论。 |
| 2026-09-21 | 本周双主线与缓冲I/O立项 | 修订06-3§七承接`CACHE-BURST-21P7`，06-2b同步执行关系，新建06-4。只完成文档，不授权环境，不重跑历史矩阵。 |
| 2026-09-21 | 06-4完成及阶段收口 | `direct=0`四格有效完成；两组配对均为负向，且FUSE读请求由256KiB拆为128KiB、GET读放大约2.25倍，判定`SCREEN_STOP / NO_CANDIDATE`。06阶段三条主线均无新增可交付优化。 |
| 2026-09-21 | 06-3§七最小脚本适配与离线Gate | 独立`burst-*`入口固定A1/B1/B2/A2，复用旧采集/恢复框架；`RUN_ID=20260921-111637`离线Gate通过，`remote_calls=0`，环境负载未授权。 |
| 2026-09-21 | 06-3§七只读inventory与执行计划 | 157资产/容量/进程/Ceph/TiKV准入通过，精确写操作及恢复边界已保存；合同保持`NOT_APPROVED`，等待正式负载授权。 |
| 2026-09-21 | 06-3§七正式A/B/B/A执行 | `RUN_ID=20260921-111637`四格生命周期及环境收口全部PASS。B1/B2读写约`504--508 MiB/s`且同臂变化小于0.5%，但A1→A2约`629/631→412/413 MiB/s`，同臂下降约34.5%；两组配对效应异号，B/A均值约`-3%`，历史21.7%未复现，WB单变量第二批不触发。原始包已持久化并独立复算；跟踪项记`PAUSED_INCONCLUSIVE / NO_PRODUCTION_CANDIDATE`。 |
| 2026-09-21 | 06-2b离线源码修复与Gate | 从06-2权威`v1.4.1+B-catchup`源码包构建同源C/T；修复固定覆盖提交不广播及已提交依赖误扩范围两项缺陷。两条旧逻辑确定性负例FAIL，修正版定向/相关VFS/race回归PASS，同工具链Ceph构建PASS。证据`/mnt/c/SunRise/test/06-2b/20260921-124344/offline/`；未访问环境，尚不能判断带宽收益。 |
| 2026-09-21 | 06-2b环境六格完成 | 有效RUN `20260921-140634`完成H/C/T六格。T1/C1读写`+0.51%/+0.47%`，T2/C2`+11.41%/+11.55%`；`ε=5.617%`、`M=11.235%`，四项未全部过门，`SCREEN_STOP / NO_CANDIDATE`。正确性修复成立，但未形成可固化平均带宽收益；环境安全收口。 |
| 2026-09-21 | 06收口补证与恢复可行性只读评估 | 06-1已补C臂四分窗、uploading mean/P95/max、PUT `_count`请求率与分位数；06-3已补drops/evicts、命中及设备对账；指导书已固化缓存准入和NVMe压力证据门。只读现场显示`juicefs-data=6,116,986`对象，约为06-1归一起点3.06倍；`juicefs-prod`同时存在157测试挂载和ceph-node3 portal挂载。虽Ceph clean且三节点pending=0，仍不具备直接复验或无维护窗口全卷GC的条件。详见`06-CLOSEOUT-RECOVERY-FEASIBILITY-20260921.md`。 |
| 2026-09-21 | 06-5统一恢复与来源确认 | 维护窗口内完成7次全卷恢复和`C1/R1/W1/W2/R2/C2`六格。W/C读写两组均约`+20.7%～+21.2%`，复现历史组合信号；R/C为`-1.1%/+8.6%`，普通缓存单独无材料收益；W/R为`+22.5%/+11.2%`，但R同臂漂移约`7.55%`使严格来源分辨率不足。状态`COMBINED_SIGNAL_REPRODUCED / RESOLUTION_INSUFFICIENT / NO_PRODUCTION_CANDIDATE`，06限范围闭环。 |
| 2026-09-22 | 06-2c eager-freeze源码候选完成 | 有效RUN `20260922-180504`完成`C1/T1/T2/C2`。T1/C1读写约`-5.6%`，T2/C2约`+2.5%`；C/T同臂均明显衰减，`epsilon=23.149%`、`M=46.298%`。候选前45秒较快，但后段更慢、staging和排空增加，未提高完整180秒平均带宽；正确性和环境收口PASS，`SCREEN_STOP / NO_CANDIDATE`。 |

## 十、已执行主线及未决问题（2026-09-21）

| 任务 | 要回答的问题 | 最小环境矩阵 | 当前状态 |
|---|---|---|---|
| [06-2b](../perf-tasks/06-2b-randrw-range-flush-repair-and-burst-validation.md) | 正确修复range-flush后，是否真正提高完整测试R/W，而非只赢退化重建基座 | H0/C1/T1/T2/C2/H1；H交付件，C同源无仪表基座，T修正版 | **完成**：正确性PASS；两组配对分别约`+0.5%`与`+11.5%`，未形成重复材料收益，`SCREEN_STOP / NO_CANDIDATE` |
| [06-2c](../perf-tasks/06-2c-randrw-write-path-source-optimization-screen.md) | 减少剩余读前等待或提前完成写提交的一个最小源码改动，能否提高完整randrw平均带宽 | 正确性前置；无重仪表C1/T1/T2/C2 | **已完成**：eager-freeze正确性PASS；两组配对约`-5.6%`与`+2.5%`，同臂漂移`16%～23%`。前段更快但后段更慢、排空更久，完整平均无重复收益；`SCREEN_STOP / NO_CANDIDATE`；[报告](../perf-report/06-2c-randrw-write-path-source-optimization-screen-20260922.md) |
| [06-3](../perf-tasks/06-3-randrw-cache-admission-and-burst-performance-screen.md) | 主动缓存新写完整块、以及在此基座启用WB，是否带来可重复的180秒平均收益 | C1/S1/W1/W2/S2/C2；C无缓存，S96GiB+CLW无WB，W同S加WB | 六格安全闭环，本地原始证据持久归档并复算；后端状态起点不对称与高漂移使效应不可判，不选候选、不追加分支；[正式结果](../perf-report/06-3-randrw-cache-admission-and-burst-performance-screen-20260916.md#八正式六格执行与审计结论2026-09-16) |
| [06-3§七](../perf-tasks/06-3-randrw-cache-admission-and-burst-performance-screen.md#七本周主线一217观察收益复现与来源确认2026-09-21) | 主线一：历史原组合收益是否可重复、来源是什么 | 首批A/B/B/A：无缓存/原96GiB＋WB；有信号后另批WB增量四轮 | 首批完成；配对异号、A同臂下降约34.5%，历史21.7%未复现；`PAUSED_INCONCLUSIVE`，第二批不触发；[报告§九](../perf-report/06-3-randrw-cache-admission-and-burst-performance-screen-20260916.md#九217观察收益最小复现2026-09-21) |
| [06-4](../perf-tasks/06-4-randrw-buffered-io-model-validation.md) | 独立模型：允许内核页缓存后，当前randrw能达到什么性能 | 每格新私有挂载，direct=1/0四轮ABBA；两侧相同60秒预热、JuiceFS磁盘缓存与WB均关 | **已完成**：两组读写配对约`-24%`和`-1.7%`，`SCREEN_STOP / NO_CANDIDATE`；不再安排竞品侧补测 |
| [06-5](../perf-tasks/06-5-randrw-cache-writeback-benefit-source-attribution.md) | 统一恢复起点后，历史约21.7%组合收益能否复现、主要来自普通缓存还是writeback路径 | C1/R1/W1/W2/R2/C2；C无缓存，R为96GiB普通缓存，W在R上开启WB | **已完成**：W/C两组约`+20.7%～+21.2%`，组合信号复现；R/C无材料收益，来源收窄至WB启用后的缓存/暂存交互；R臂漂移约7.55%，严格单项来源仍`PAUSED_INCONCLUSIVE`；[报告](../perf-report/06-5-randrw-cache-writeback-benefit-source-attribution-20260921.md) |

§十一的闭环工作已经06-5完成；06-2c随后完成一个限范围源码候选筛选。06-2b、06-2c、06-4、06-5均不再安排原样重测。buffer等其他候选保留在07，暂不开展。
06-4本批direct=1/0对照只解释应用模型变化，不并入旧direct=1效应，也不冒充同模型竞品对比。

06-2旧实验补丁的非增长覆盖写通知缺口、已提交依赖误纳无关后缀，已由06-2b定向修复验证；
这不是发现并修复了交付版本的两项同等缺陷。旧计时遗漏handle锁、把条件等待误计作持锁，不能继续
作为关键路径判据。新调查若确需观测须重审，不能把静态发现直接换算成带宽收益。

共同边界：主端点是全程字节/实际时间，不固定除180、不删慢尾；同轮重复用于判断可复现性，
CV/W4/W1不作删样门，排空不强制并入前台均值。高命中由宿主页缓存供给可以是整机配置的真实
收益，但不得称为NVMe介质性能；需报RAM/本地盘/staging预算、排空和断电风险。
不要求收益一定伴随后台PUT上升——有限突发可以增加积压；字节去向与数据安全仍须自洽。
历史的160秒值、有效性裁决及原始证据不改写，只能在06-3增加回顾性解释。

环境授权、业务保护、缓存/内存预算和恢复方案仍是开跑前硬门。06-3的离线签收不替代现场核实或负载授权。

### 10.1 必跟踪项与收口（2026-09-21）

- `CACHE-BURST-21P7`的首批06-3结果仍按原裁决保留；后续06-5在统一恢复起点下复现W/C两组
  `+20.7%～+21.2%`组合信号，限范围取代“当前未复现”的阶段状态。
- 06-5的R/C没有材料收益，W/R同向但第二组低于M；R同臂漂移约7.55%，因此来源收窄至
  WB启用后的缓存/staging/宿主脏页协同路径，精确独立贡献仍记`PAUSED_INCONCLUSIVE`。
- 不登记生产候选、不补漂亮样本；06在L1分辨率边界闭环，后续新buffer、缓存准入或源码机制进入07。
- 06-2b只回答修正版的正确性及带宽价值，不关闭历史缓存收益项；06-4同样不能替代它。
- 06-3首批准备≤2h、环境及审核目标2h；必要归因每次另批1～2h。06-2b离线3～5h、环境2～3h；
  06-4准备目标≤1h、环境1～2h，主动恢复或业务窗口冲突另报。预算不是跳过安全排空的理由。
- 状态总结、架构问答和周报是线索，不能直接作执行许可或既定因果：不得将用量差等同可删垃圾，
  不设“上传槽满才准判断WB”的门，不用缓存洪流/设备等待跨层算式直接宣布参数无效，不拼不同RUN机制证明21.7%来源。
- 固定资产、轻量采集、完整时段R/W、原始证据独立复核和一次性持久化保留；不默认重跑六轮、
  6～8轮漂移矩阵、容量曲线或重型profile。操作范围扩大时再审批，所有新结果使用独立RUN。

## 十一、06阶段闭环待补清单（2026-09-21当前执行规划）

**06补旧问题，07探索新手段。** 本节记录已完成的收口执行状态；不把历史“未复现”改写成“已证无效”，
也不把“筛选停止”改写成“randrw已无优化空间”。

| 顺序 | 待补任务 | 最小工作与产出 | 执行边界 / 完成条件 |
|---|---|---|---|
| 1 | **已有证据与报告补齐** | 从持久归档补06-3的cache drops/evicts、命中字节与设备流量对账；补06-1的PUT请求数、uploading及可复核的C臂分窗。统一报告最新状态、旧结论取代关系、调查补丁性质和未决项 | **已完成（2026-09-21）**。纯离线摘录权威归档，不重测、不改原RUN裁决 |
| 2 | **可比起点恢复评估** | 基于已有06-1/06-3命令与状态差异提出一个最小恢复方案，分别说明JuiceFS slice/object、TiKV压缩状态和客户端Dirty如何观测、恢复及验证 | **只读评估完成**。当前对象数为历史归一起点3.06倍，直接复验不准入；全卷GC/compact是唯一可继续评估的主线，但须维护窗口和单独授权，见`06-CLOSEOUT-RECOVERY-FEASIBILITY-20260921.md` |
| 3 | **有条件复验21.7%原组合** | 统一恢复后复验无缓存与96GiB普通缓存＋WB组合 | **已由06-5完成**：W/C两组读写均约`+20.7%～+21.2%`，组合信号复现 |
| 4 | **有信号才拆收益来源** | 同一六格加入96GiB普通缓存、WB关的R臂，计算R/C、W/R、W/C | **已由06-5完成至L1分辨率边界**：普通缓存单独无材料收益，来源收窄至WB启用后的缓存/暂存交互；同臂漂移使独立WB贡献不可严格裁决，不追加样本 |
| 5 | **统一阶段结论与最小生命周期收口** | 更新报告、计划、现状和results-table；持久化一份权威证据并恢复环境 | **已完成**：正式证据归档并独立复算，portal/scrub/Ceph及任务挂载均已安全收口 |

### 11.1 补测合同与停止规则

- 继续使用既有B256卷、128×1GiB文件、256K/50:50/128 jobs×QD128/direct=1、180秒；不新layout、不混入新buffer或源码补丁。
- 主值为`fio完整完成字节 / 实际timed-I/O时长`，读写分报，包含慢尾；分窗仅在日志可复核时使用。轮内下降、暂存积压和非零排空本身不否定有限突发收益；持久性代价必须单列。
- 恢复策略在看新性能数据前冻结并对各臂对称。对象数稳定、pending-compaction为零只是旁证，不能单独证明可比；更不能为了回到历史高值而挑起点。
- ABBA只抵消线性轮序偏差，实际对照仍大幅漂移时保持`INCONCLUSIVE`。不把低吞吐、低暂存工作区的负向结果外推成对历史高突发场景的否证。
- 恢复成功后的四轮纯负载约16分钟；沿用06-3每批准备≤2小时、执行/审核目标1～2小时的预算。主动恢复成本单独评估，超预算停下决策；安全排空不因预算强行终止。
- 若恢复不可行、无法保护业务或再次不可判，保留`CACHE-BURST-21P7 = PAUSED_INCONCLUSIVE`，由用户决定是否限范围结束，不自动继续扫描。

### 11.2 06与07的责任边界及最终关闭条件

- `CACHE-BURST-21P7`已由06-5复现完整组合收益并把来源收窄至WB启用后的缓存/暂存交互；精确单项比例因分辨率不足保留限定，不再作为06继续扩矩阵的理由。07的新收益不能反向改写本RUN。
- 06-2b range-flush修复和06-2c eager-freeze候选均已完成，均没有可交付性能收益；06-4当前`direct=0`筛选已结束。三者只补必要报告一致性，不作为06补测项目。
- buffer300/2048、CLW新对照、缓存淘汰/容量新方案、新的源码改动及其交付验证，均交由[07计划](07-randrw-cache-admission-and-write-path-optimization-plan.md)条件性承接，暂不开展。
- 06最终记`STAGE06_CLOSED_WITH_LIMITS`：组合信号已复现，精确来源仍受分辨率限制，无新增生产候选。不得写“21.7%已证不存在”“独立writeback贡献已精确确认”或“已达架构上限”。
