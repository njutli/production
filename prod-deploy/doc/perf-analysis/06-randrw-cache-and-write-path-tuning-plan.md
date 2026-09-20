# 06阶段计划：randrw 缓存与写路径深度调优

> 日期：2026-09-15（2026-09-15 按 GPT 评审意见修订：删除持久化模式"已达架构上限"的循环论证、
> 删除"只利用本地能力 4%"的错误口径、共享 op 预算降为探索性假设、06-1 缩为四格组合包筛选、
> 06-2 增加构建溯源门与动态 profile 门）
>
> 状态：`FOLLOWUP_PLANNED / 06-2b_OFFLINE_PREP_REQUIRED / 06-3_SIX_CELL_COMPLETE_CAUSAL_INCONCLUSIVE`。
> 06-1/06-2原RUN已结束，历史裁决不变；06-3六格安全闭环并完成本地原始归档复算，但后端起点漂移阻止配置收益归因。
> **2026-09-20新增必跟踪项：`CACHE-BURST-21P7 = OPEN_PLANNED / NOT_AUTHORIZED`。**
> 约21.7%历史缓存组合收益的复现与来源确认，由现有06-3任务书§七承接，不再以“06-1先成为有效候选”作为是否跟踪的条件。
> 本次仅补充计划和任务书，未运行新Gate、inventory、性能负载或环境恢复；既有授权不自动延续，详见§十.1。
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
> 不访问有方环境，不产出新的同场竞品对比结论。
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
> [06-3](../perf-tasks/06-3-randrw-cache-admission-and-burst-performance-screen.md)。
> 原文“06-3用于上游合入后交付验证”是旧预留，现由缓存筛选使用；交付验证编号待后续决定。

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
- 数据可读顺序是硬的（`pkg/vfs/writer.go:186` `commitThread`）：`upload → m.Write → reader.Invalidate`，且按创建顺序 FIFO 提交、存在队头阻塞。

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

- ⛔ 竞品对比：有方环境**不再可用**，≥1M 对比行已永久 `NOT_COMPARABLE`（见 05 计划书）。
- ⛔ 删除 M1（§二.1 已论证为正确性缺陷）。
- ⛔ 再扫 `cache-size` 全容量曲线（04-tmp2j 已闭环）。§十.1为历史组合收益归因而按证据另批的两点对照不属全曲线重测，但不能自动执行。
- ⛔ `--max-uploads` 更高档位（U450/U600）。
- ⛔ 卷 BlockSize 再扫描（属 05-1b 已闭环范围）。
- ⛔ 在 06-1 内追加不能形成因果对照的单格（含原 Phase B/C，已按评审删除）。
- ⛔ 几何自证诊断（`iodepth×bs/filesize` 扫描）：目的是解释有方数据，归 05 阶段。

---

## 五、统一测试口径（06 阶段全任务通用）

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
→ GC 与恢复门
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
3. **机制自洽门**：应用侧带宽提升必须与"本地介质吞吐上升 + 后端对象请求率不下降"同向；若应用侧涨而两者都不动，先判口径/采样错误。
4. **非性能硬门与性能端点严格分离**：只有非性能门可删样；带宽/CV/`W4/W1`/延迟**再差都是结果**。
5. **持久性声明强制项**：任何涉及 writeback 的结论必须同时写明"ack 先于持久化 + 排空窗口时长 + 净积压峰值 + `stageFull` 命中时静默回落同步 PUT"，⛔ 不得以"性能提升"单独结论。
6. **因果范围强制声明项**：组合包实验的报告**必须**在结论节显式写明其不可归因范围（§四.1），⛔ 不得只在正文提一句。
7. ⛔ **不得写"可生产""等价""确定无效""已达架构上限"。**

---

## 七、稳定性、安全与证据边界

- 每格私有挂载 + 优雅卸载（顺序见 §5.1）；⛔ 禁 `fusermount -uz` / `umount -l` / 模式 kill。
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
3. **必须交代`CACHE-BURST-21P7`的去向**：在06-3§七先验证历史组合能否复现，再按证据拆必要变量；无需另立任务编号，也不要求先拿到旧06-1的L1候选。组合有效可以先保留，不必拆清全部机制才登记；生产交付验证另行决策，本阶段不自动升级。若仍未解决，必须列明未知与承接安排，不能随旧RUN或源码任务收尾消失。
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
| 2026-09-20 | 补充历史约21.7%收益的承接计划 | 仅改文档。06-3§七新增`CACHE-BURST-21P7`：先按原配置四格复现，再决定WB增量、预算、总空间及存储路径的必要归因。漂移/未复现但来源未明时保留未解决，不自动重跑或关闭；06-2b不能替代该项。新脚本、Gate和环境操作均未启动。 |

## 十、后续工作：06-2b与06-3（当前有效入口）

| 任务 | 要回答的问题 | 最小环境矩阵 | 当前状态 |
|---|---|---|---|
| [06-2b](../perf-tasks/06-2b-randrw-range-flush-repair-and-burst-validation.md) | 正确修复range-flush后，是否真正提高完整测试R/W，而非只赢退化重建基座 | H0/C1/T1/T2/C2/H1；H交付件，C同源无仪表基座，T修正版 | 先离线修复/定向回归，不自动运行 |
| [06-3](../perf-tasks/06-3-randrw-cache-admission-and-burst-performance-screen.md) | 主动缓存新写完整块、以及在此基座启用WB，是否带来可重复的180秒平均收益 | C1/S1/W1/W2/S2/C2；C无缓存，S96GiB+CLW无WB，W同S加WB | 六格安全闭环，本地原始证据持久归档并复算；后端状态起点不对称与高漂移使效应不可判，不选候选、不追加分支；[正式结果](../perf-report/06-3-randrw-cache-admission-and-burst-performance-screen-20260916.md#八正式六格执行与审计结论2026-09-16) |
| [06-3§七：历史收益复现与来源确认](../perf-tasks/06-3-randrw-cache-admission-and-burst-performance-screen.md#七约217历史组合收益复现与来源确认2026-09-20新增暂不执行) | 原96GiB＋WB组合约21.7%的全程观察增幅是否可重复，哪些条件使其成立或失效 | 首批A/B/B/A四格，A无缓存，B原96GiB＋WB且CLW关；收益复现后再逐项决定必要归因 | `CACHE-BURST-21P7 / OPEN_PLANNED / NOT_AUTHORIZED`；不是原六格的自动分支，也不能因其无候选而跳过 |

后续授权时，06-3§七的证据差异核对与06-2b离线修复可以并行；环境测试必须串行，
先审查基线状态是否支持比较，不直接重跑旧六格。两条线不互相替代，也不把新缓存参数偷偷引入源码单变量对照。
暂不新建06-4；原六格的“最多一个Q/P/M分支”仍只适用于其旧合同。§七是新明确承接的待办，
每次最多批准一个四格批次，不一次授权容量/介质/参数全矩阵。

本轮源码复查还发现三项须带入后续：非增长覆盖写的commitcond通知缺口；已提交依赖可能误纳入
无关后缀；旧计时遗漏handle锁且把条件等待误计作持锁。它们需要06-2b确定性回归，不能把静态发现
直接换算成带宽收益。固定覆盖写dep=0不能用于证明增长依赖闭包已经覆盖或不存在。

共同边界：主端点是全程字节/实际时间，不固定除180、不删慢尾；同轮重复用于判断可复现性，
CV/W4/W1不作删样门，排空不强制并入前台均值。高命中由宿主页缓存供给可以是整机配置的真实
收益，但不得称为NVMe介质性能；需报RAM/本地盘/staging预算、排空和断电风险。
不要求收益一定伴随后台PUT上升——有限突发可以增加积压；字节去向与数据安全仍须自洽。
历史的160秒值、有效性裁决及原始证据不改写，只能在06-3增加回顾性解释。

环境授权、业务保护、缓存/内存预算和恢复方案仍是开跑前硬门。06-3的离线签收不替代现场核实或负载授权。

### 10.1 必跟踪项：CACHE-BURST-21P7（2026-09-20）

**当前：`OPEN_PLANNED`；本次只补文档，暂不执行。** 设计/审核由GPT负责，执行方后续指定；
承接位置为06-3任务书§七，原始线索为06-3报告§二对06-1完整fio的复算：读+21.73%、写+21.68%。
这只是历史观察差，不是目标必须达到的数值，不修改原RUN裁决。

1. **必须先确认原组合是否可用。** 同一交付件、既有资产、256K/direct=1、相同60秒预热，
   原生ext4上比较无缓存与96GiB＋WB，CLW均关；完整平均带宽为主值，资源和排空代价单列。
   新测发现漂移或后端明显退化时先停，不能以退化基线或重选高值样本“复现”收益。
2. **复现后再拆必要来源。** 优先核对同96GiB下WB的增量，再按证据选择预算、总空间约束、
   loop/原生路径的最小对照。04阶段已测过相近预算但原矩阵证据无效，不能把本次写成首次大缓存收益；
   纯读缓存容量曲线也不能替代读写同开的验证。新的组合收益不拆清所有机制也可先保留候选。
3. **无结果不丢待办。** 起点不可比、再次漂移、资源不足，或未复现但历史差异仍未知，记
   `PAUSED_INCONCLUSIVE`，停止新增负载但不关闭问题；条件具备后由用户决定继续或挂起，不无限重跑。
4. **区分收益与归因两条完成线。** 复现后记`REPRODUCED_ATTRIBUTION_OPEN`；只有可重复配置及
   足够支持选型的来源/适用条件已明确，或已有证据解释历史增幅为何不构成可用收益，才可签`RESOLVED`。
   仍有剩余差异时必须列出；如决定不再投入，须用户明确同意挂起/限范围收口，不伪装已解决。
5. **防止被其他任务替代。** 源码补丁有效/无效、缓存新参数成功、旧RUN安全收口、阶段报告写完，
   都不自动关闭本项。阶段结题必须逐项说明其状态、证据、剩余未知及去向。

首批复用准备目标≤2小时，四格含预热16分钟纯fio、环境及审核目标2小时；之后每个必要归因批次
另批约1～2小时。不预写所有分支脚本，不修改历史冻结脚本和证据；GC/compact、loop创建销毁及任何
sudo写仍需精确计划和新授权。后续结果持久化到`/mnt/c/SunRise/test/06-3/<新RUN_ID>/`，
在后续报告及本节用同一ID跟踪；此段规划不等于脚本已就绪或已有环境许可。
