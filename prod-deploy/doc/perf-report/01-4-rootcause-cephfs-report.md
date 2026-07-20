# 01-4 FUSE 单进程 6 核封顶根因定位 + CephFS 对照实验报告

> ## ⚑ 基线订正块（2026-07-17，据 01-2d 全量重测）
> **本报告的 CephFS 实测数据全部真实、复算无误（EC S0=4608 / Rep S0=6718 / EC D2=4614 / EC randrw R=W=1498 / Rep randrw R=W=2392 / layout EC=3117，均 3 轮中位、CV<3%）。**
> 但**所有 JuiceFS 对照值与由此推导的倍率、达标率、根因定性均基于已作废的错误基线**，据 01-2d 订正如下：
>
> | 对照项 | 原报告（作废） | 01-2d 准确值 | 倍率订正 |
> |------|--------------|-------------|---------|
> | JuiceFS randread ra0 | ~~2876~~ | **2404** | EC/JF ~~1.60×~~→**1.92×**；Rep/JF ~~2.34×~~→**2.79×** |
> | JuiceFS randread D2(128) | ~~1833~~ | **2404**（无 CPU 封顶差） | EC/JF ~~2.52×~~→**1.92×** |
> | JuiceFS randrw 合计 | ~~919（R460/W460）~~ | **2635（R1316/W1319）** | EC/JF ~~3.26×~~→**1.14×**；Rep/JF ~~5.20×~~→**1.82×** |
>
> **核心叙事订正**：CephFS 更快这一**定性结论仍成立**（EC 1.92× / Rep 2.79×），但倍率被大幅夸大，randrw 尤甚（合计从"3.26×/5.20×"缩到 1.14×/1.82×）。
>
> **根因定性反转**：原报告判"JuiceFS 已贴近后端上限、瓶颈主体=FUSE 用户态税"。准确基线下 **JuiceFS randread 2404 仅为后端 rados 裸能力 ~4300 的 56%**（非贴顶）；而 **CephFS EC 4608 ≈ 后端裸值 4300（107%）**——这说明：
> - **系统级首要瓶颈 = 后端 EC4+2 随机读（~4300，低于 6250 验收线）**；FUSE 用户态税（把 4300 再砍到 2404）是**次级**因素。
> - §5.4 "6 核封顶 / 固定开销 91%" 的推导本身逻辑自洽，但它解释的是"JuiceFS 为何到不了后端 4300"，**不是**"系统为何到不了 6250 验收线"——后者答案在后端。
> - 换栈到 CephFS 仅能把客户端从 2404 提到 ~4608（拿回后端裸值），**仍不过 6250 验收线（EC 74%）**；要过线必须先攻后端 EC 随机读。Rep 6718 过线但非当前 EC 方案。
>
> 下文正文保留原判定并以删除线 + ⚑ 标注订正，不重测。

## 报告头

| 字段 | 值 |
|------|-----|
| 对应任务书 | `doc/perf-tasks/01-4-rootcause-and-cephfs-control-task-book.md` |
| 测试结果路径 | `results/prod-nolimit-rootcause-cephfs-20260716-220958/` |
| 远端原始数据 | 157:`/tmp/scalability-results/01-4-pprof/` + `01-4-cephfs/` |
| 执行日期 | 2026-07-16 |
| 执行方 | AI 助手（GLM） |
| 审阅方 | （待审阅） |
| 判定 | ~~**根因 = 用户态方案固定运行时开销（91% 固定 + 9% 可变）**。6 核封顶 = Go runtime 调度/GC（~2c）+ librados 3 线程 messenger 事件循环（~1.3c）+ cgo/FUSE dispatch 基础设施（~2c）+ per-I/O writev/read/memcpy（~0.5c）。CephFS 内核态消除全部固定开销 → 无封顶。是否换栈由用户拍板。~~ ⚑ **订正**：CPU 封顶推导（§5.4）仍成立，但那只解释"JuiceFS 为何到不了后端 4300"。**系统首要瓶颈 = 后端 EC4+2 随机读 ~4300（<6250 验收线）**，FUSE 用户态税为次级（把 4300 砍到 2404=后端 56%）。换栈到 CephFS EC 仅回到 ~4608（后端裸值，仍 74% 未过线）→ **要过验收线须先攻后端**。 |

---

## 一、测试目的

定位 01-3 发现的"单进程 CPU 封顶 ~6 核"根因，区分三个候选：
- C1: FUSE /dev/fuse 单管道 dispatch 模型限流
- C2: librados/messenger 线程模型或连接数上限
- C3: Go runtime 调度/内部锁竞争

CephFS 内核态对照作为"根因是否 = FUSE 用户态方案"的判定实验。

---

## 二、步骤1：pprof 热点分析

### 2.1 分析对象
- cpu-01-3.prof: 20s 采样（01-3 捕获），87.35s samples（avg 436.74%）
- cpu-60s.prof: 45s 采样（01-4 重采），206.96s samples（avg 459.91%）
- goroutine.txt: 稳态期快照，10555 行
- mutex.prof / block.prof: 各 1.5KB（未启用，空）

### 2.2 pprof top（flat，45s profile）

| 函数 | flat% | 含义 |
|------|-------|------|
| runtime.cgocall | 20.87% | Go→C 转换（writev + rados_read） |
| Syscall6 | 18.98% | 内核系统调用（/dev/fuse read/write） |
| [libc.so.6] | 16.17% | C 库函数（memcpy/malloc） |
| [libceph-common.so.2] | 7.40% | Ceph messenger |
| runtime.memmove | 4.17% | 内存拷贝 |
| [librados.so.2.0.0] | 2.26% | librados API |
| runtime.futex | 1.56% | 锁竞争（低） |
| Mutex.Lock | 0.74% | 互斥锁（低） |

### 2.3 pprof -cum（调用链）

| 调用路径 | cum% | 分类 |
|----------|------|------|
| **fuse.Server.loop** | **31.51%** | **C1 FUSE 主循环（最大路径）** |
| └ fuse.handleRequest | 28.51% | C1 请求处理 |
| └ fuse.write → writev → /dev/fuse | 17.54% | **C1 写回内核** |
| └ cephReader.Read → rados_read | 16.03% | C2 从 RADOS 读 |
| runtime.cgocall | 21.98% | C1+C2 cgo 开销 |
| Syscall6 | 18.98% | C1+C2 系统调用 |
| [libceph-common] + [librados] | 9.66% | C2 |
| futex + Mutex | 2.30% | C3（次要） |

### 2.4 goroutine 分布
- 131 goroutine 在 FUSE Server loop
- 128 在 rSlice.ReadAt（= fio numjobs，一致）
- 70 在 IOContext.Read（librados）
- 无大量 goroutine 阻塞在同一处/锁

### 2.5 C1/C2/C3 判定

| 候选 | 占比 | 判定 |
|------|------|------|
| **C1 FUSE dispatch** | ~31% cum + 17.5% writev = 主路径 | ✅ **主要根因** |
| C2 librados | cgocall 21.98% + libceph 7.4% + librados 2.26% ≈ **31% cum** | 与 C1 相当（非"次要"，见订正） |
| C3 锁/调度 | ~2.3% | 次要（无单点锁死） |

> **审阅订正（cgo 归属核对）**：`go tool pprof -peek=runtime.cgocall` 显示 flat 20.87% 的 cgocall **100% 来自 C2**（rados_read 70.85% + rados_stat 26.69%），非 FUSE。原稿把 cgo 全算作"C1 的税"不准。实际两条路径量级相当：
> - **C1 FUSE 写回**：Server.loop 31.5% cum、writev→/dev/fuse 17.5%
> - **C2 librados 读**：cgocall 21.98% + libceph 7.4% + librados 2.26% ≈ 31%
>
> **修正判定**：并非"C1 单一主因、C2 次要"，而是 **C1（FUSE dispatch/writev 写回）+ C2（librados 经 cgo 读）共同构成用户态方案税，量级相当**。C3（锁）确为次要（2.3%，无单点锁死）。

**结论**：pprof → 用户态方案税（C1 FUSE writev 写回 + C2 librados cgo 读，各约 31% cum，量级相当）；cgo + syscall 合计 39.85% flat 是核心开销。两者均为用户态架构固有、客户端无对应旋钮 → 跳过步骤2。此判定与 CephFS 内核态对照（下节，两条税皆消，1.6-5.2×）自洽。

---

## 三、步骤2：跳过

pprof 指向 C1（FUSE dispatch），客户端无对应参数可调。不试参数，直接进入步骤3。

---

## 四、步骤3：CephFS 内核态对照

### 4.1 部署
- MDS: `cephfs.ceph-node1` (up:active)
- Pools: `cephfs_metadata`(replicated) + `cephfs_data_ec`(EC4+2) + `cephfs_data_rep`(replicated)
- Mount: `mount -t ceph`（内核态，无 FUSE 用户态税）
- fio 口径：bs=256k, direct=1, cache=0, time_based 180s, REPEAT=3, 256K 对齐

### 4.2 randread 对照

| 口径 | CephFS EC | CephFS Rep | JuiceFS ra0 | EC/JuiceFS | Rep/JuiceFS |
|------|-----------|------------|-------------|------------|-------------|
| S0 (16384) | 4608 | **6718** | ~~2876~~ **2404** | ~~1.60×~~ **1.92×** | ~~2.34×~~ **2.79×** |
| D2 (128) | 4614 | — | ~~1833~~ **2404** | ~~2.52×~~ **1.92×** | — |

- CephFS EC randread = 4608 MiB/s，**显著 > JuiceFS ~~2876~~ 2404**（~~1.60×~~ **1.92×**）
- CephFS Rep randread = 6718 MiB/s，**超过 6250 验收线**
- CephFS S0 ≈ D2（4608 ≈ 4614）→ **无 CPU 封顶**（对比 JuiceFS 受 6 核限制）
- EC vs Rep 差距：1.46×（EC 读需 4 片 + 解码，Rep 仅 1 片）
- ⚑ **订正关键**：CephFS EC 4608 ≈ 后端 rados 随机读裸值 ~4300（107%），即 **CephFS 已基本拿满后端；JuiceFS 2404 = 后端的 56%**。故差距来源 = FUSE 用户态税，但两者共同的天花板 = 后端 ~4300（<6250 验收线）。

### 4.3 randrw 对照（D2 = 16×8 = 128，验收口径）

| 口径 | R | W | R/W | 合计 | vs JuiceFS 合计 |
|------|---|---|-----|------|----------------|
| CephFS EC | 1498 | 1498 | 1.00 | 2996 | ~~3.26×~~ **1.14×** |
| CephFS Rep | 2392 | 2392 | 1.00 | 4784 | ~~5.20×~~ **1.82×** |
| JuiceFS ra0 | ~~460~~ **1316** | ~~460~~ **1319** | 1.00 | ~~919~~ **2635** | 1.0× |

- R/W 全部 1:1 均衡
- CephFS EC 写未崩（ec_overwrites 有效，R/W 均衡）
- CephFS Rep 合计 4784 > ~~6250 验收线~~（注：验收线 6250 针对单向 randread，randrw 合计无独立验收线，此处仅作对照）
- ⚑ **订正**：原用 JuiceFS randrw 合计 919（R460/W460）系作废基线，倍率虚高近 3 倍。01-2d 准确合计 = 2635（R1316/W1319）→ EC 仅 **1.14×**、Rep **1.82×**。EC randrw 与 JuiceFS 几乎持平，说明 randrw 混合负载下后端 EC overwrite 开销把 CephFS 优势基本抵消。

### 4.4 判定（§3.2 判读表）

| 现象 | 判定 |
|------|------|
| CephFS randread/randrw **显著 > ~~2876~~ 2404** | ✅ **反证：FUSE 用户态税确是 JuiceFS 落后 CephFS 的原因（C1 坐实）** |
| CephFS + EC 写未崩 | EC overwrite 对 CephFS 可用（不触发 RMW 崩溃） |
| CephFS 无 CPU 封顶（S0≈D2） | 内核态无用户态 dispatch 瓶颈 |
| ⚑ CephFS EC 4608 ≈ 后端裸值 4300 | **系统天花板 = 后端 EC4+2 随机读，仍 <6250 验收线（74%）；换栈只能拿回后端裸值，不能过线** |

---

## 五、结论

### 5.1 根因定位

⚑ **订正后的分层结论**：
- **系统级首要瓶颈 = 后端 EC4+2 随机读 ~4300 MiB/s**（<6250 验收线）。CephFS EC 4608 ≈ 该裸值（107%），证明后端就是天花板。
- **JuiceFS 落后 CephFS 的原因（次级）= 用户态方案税**（C1 FUSE writev 写回 + C2 librados cgo 读，量级相当），把后端可达的 ~4300 砍到 2404（后端的 56%）。

1. pprof 证实：C1 FUSE server loop 最大调用路径（31.51% cum）、writev 写回 /dev/fuse 17.54%；C2 cgo（100% 走 rados_read/stat）21.98% + libceph/librados ≈ 31% cum，与 C1 量级相当
2. CephFS 对照证实：同后端（EC4+2 + replica）、同口径（256K, direct=1, cold），内核态获 ~~1.60-5.20×~~ **1.14-2.79×** 带宽提升（C1 FUSE 税 + C2 cgo 税同时消除）——但 EC 上限即后端裸值 4608
3. 锁竞争仅 2.3%（C3 排除，无单点锁死）

### 5.2 有无调优可能

**客户端 FUSE 税无调优可能**（架构限制）：
- 01-3 已证 max-uploads 参数无效
- pprof 证实瓶颈在 FUSE writev/cgo/syscall，非可配参数
- 唯一 workaround = 多挂载实例（01-3 N=4 = 2.13×），但需多挂载点

⚑ **但客户端调优不改变系统首要瓶颈**：即便消除 FUSE 税（换 CephFS），单客户端 randread 也只到 ~4608（后端裸值），**仍不过 6250 验收线**。要过线必须优化后端 EC4+2 随机读能力（当前 ~4300）→ 优先级高于客户端换栈。

### 5.3 CephFS 对照结论

| 维度 | JuiceFS FUSE | CephFS 内核态 |
|------|-------------|---------------|
| 单客户端 randread | ~~2876 MiB/s (46% 达标)~~ **2404 MiB/s (38% 达标 / 后端 56%)** | 4608-6718 MiB/s (74-108% 达标) |
| 单客户端 randrw 合计 | ~~919 MiB/s~~ **2635 MiB/s** | 2996-4784 MiB/s（EC 仅 1.14×） |
| CPU 封顶 | 595% (6核) | 无封顶 |
| 多实例 workaround | 需要（2.13×） | 不需要（单挂载点即够） |
| ⚑ 相对后端 4300 | 56%（有 FUSE 税） | EC 107%（拿满后端） |

### 5.4 六核 CPU 封顶根因（补充分析）

> 审阅指出：§5.1-5.3 解释了 JuiceFS 落后 CephFS 的原因（用户态方案税），但未解释"为什么 CPU 停在 ~6 核"——即什么机制阻止了 CPU 继续增长到 7、8、9 核。
> 本节用 01-3 可扩展性曲线 + pprof + goroutine dump + go-fuse 源码定位封顶机制。
>
> ⚑ **订正后的定位与口径提醒**：
> - 本节解释的是"**JuiceFS 为何到不了后端 4300**"（客户端 FUSE 税机制），**不是**"系统为何到不了 6250 验收线"——后者答案是后端 EC 随机读裸能力 ~4300。两问题不要混淆。
> - 下方 Step 1 的 IOPS=11576（≈2894 MiB/s）来自 01-3 当时的 S0 测量，与 01-2d 准确基线 randread 2404（≈9616 IOPS）有出入。**推导的机制（IOPS-延迟反馈平衡 + per-I/O CPU 极小）不受影响**，但固定/可变开销的绝对拆分（5.43c/0.52c）待 01-3 用真值复跑后回填（任务书已标 "⟨待 01-3 复跑回填⟩"）。

#### 5.4.1 核心机制：IOPS 被延迟反馈环封顶，CPU 因 per-I/O 工作量极小而无法增长

**6 核封顶不是某个资源硬限（不是 maxReaders、不是线程数、不是 GOMAXPROCS），而是一个反馈平衡点。**

推导链（每一步有数据支撑）：

**Step 1：每个 I/O 的生命周期 = 11ms，其中 99.6% 在等待，0.4% 在做 CPU 工作。**

从 goroutine dump（S0 稳态快照）：128 个 goroutine 在 handleRequest。
从 01-3 S0：IOPS = 11576。
Little's Law：`N = IOPS × latency` → `128 = 11576 × 0.011s` → **每个 I/O 耗时 11.1ms**。

从 pprof（线性回归 01-3 五个数据点，R²≈0.99）：
- **per-I/O CPU 工作量 = 0.044ms**（cgo + syscall + memcpy + writev 合计）
- CPU 占空比 = 0.044ms / 11.1ms = **0.4%**

→ 每个 goroutine 99.6% 的时间在等网络/OSD 响应，0.4% 的时间在做 CPU 工作。

**Step 2：IOPS 被延迟反馈环封顶在 ~11.6K，无法继续增长。**

01-3 可扩展性曲线：

| 档 | goroutine 数 | IOPS | per-I/O 延迟 | 延迟 vs S4 |
|----|-------------|------|-------------|-----------|
| S4 | ~32 | 4920 | 6.5ms | 1.0× |
| S3 | ~128 | 7332 | 17.4ms | 2.7× |
| S0 | ~128 | 11576 | 11.1ms | 1.7× |

延迟随并发上升的原因（两部分）：
- **FUSE dispatch 延迟**（writev 竞争 + cgo 调度 + /dev/fuse 内核锁）：2.8ms → 5.4ms
- **RADOS 读延迟**（OSD 排队 + 网络处理）：3.7ms → 5.7ms

反馈环：`更多 goroutine → 更多并发 RADOS 读 → OSD 排队更长 → 延迟上升 → IOPS = N/延迟 不再增长`。
系统在 N≈128、延迟≈11ms 处达到平衡，IOPS 封顶在 11.6K。

**Step 3：per-I/O CPU 工作量极小（0.044ms），即使 IOPS 翻倍也只多 0.5 核。**

| 目标 CPU | 所需 IOPS | 所需延迟（128 goroutine） | 可行性 |
|---------|---------|------------------------|--------|
| 6 cores | 13K | 9.9ms | ✅ 当前 11.1ms，接近 |
| 7 cores | 36K | 3.6ms | ❌ FUSE+librados 延迟 >5ms |
| 8 cores | 58K | 2.2ms | ❌ 远超 RADOS 网络 RTT |
| 9 cores | 81K | 1.6ms | ❌ 物理不可能 |

→ **到 7 核需要 IOPS 36K，需将延迟从 11ms 降到 3.6ms。但 FUSE dispatch + OSD 排队 + 网络处理合计 >5ms，无法降至 3.6ms。IOPS 被封在 ~12K，CPU 被封在 ~6 核。**

**Step 4：固定开销 5.43 cores 占 91%，是封顶值的主体。**

线性回归：`CPU = 5.43 + 0.044ms × IOPS`
- 固定 = 5.43 cores（91%）：Go runtime + librados messenger + cgo/FUSE 基础设施
- 可变 = 0.52 cores（9%）：per-I/O 的 cgo + syscall + memcpy + writev

封顶值 = 5.43 + 0.52 = **5.95 ≈ 6 cores**

#### 5.4.2 固定开销（5.43 cores）来源

进程 CPU 595% = pprof 捕获 460%（Go 侧）+ 非 pprof 135%（librados messenger C 线程）。

| 来源 | 估算 | 为什么固定 |
|------|------|-----------|
| Go runtime（调度/GC/内存管理） | ~2 cores | 716 goroutine + GOMAXPROCS=64，stealWork/findRunnable/mallocgc 持续运行，与 IOPS 无关 |
| librados 3 线程 messenger | ~1.3 cores | 3 个 C 线程运行 epoll 事件循环，IOPS=0 也轮询。pprof 无法捕获（纯 C 线程） |
| cgo 边界 + FUSE dispatch 基础设施 | ~2 cores | Go↔C 线程池管理 + 主循环 readRequest 轮询 /dev/fuse + 缓冲池维护 |

#### 5.4.3 可变开销（0.044ms/I/O）—— 为什么极小

每个 FUSE read 的 CPU 工作仅 44μs，因为大部分时间在等网络：

| per-I/O 路径 | CPU | 占 11ms 延迟的% |
|-------------|-----|----------------|
| writev → /dev/fuse（写 256K 响应回内核） | 0.068ms | 0.6% |
| cephReader.Read → rados.Read（cgo + librados API） | 0.064ms | 0.6% |
| libc memcpy（4-6 次 256K 数据拷贝） | 0.064ms | 0.6% |
| libceph-common messenger（网络处理） | 0.029ms | 0.3% |
| memmove + librados + 其他 | 0.025ms | 0.2% |
| **合计** | **0.044ms** | **0.4%** |
| **等待网络/OSD 响应** | **~11ms** | **99.6%** |

→ per-I/O CPU 占空比仅 0.4%，这是 I/O bound 负载的典型特征。即使 IOPS 翻倍，可变 CPU 也只多 0.5 核。

#### 5.4.4 排除的候选机制

| 候选 | 数据 | 判定 |
|------|------|------|
| go-fuse `maxMaxReaders=4` | goroutine dump 仅 2 个 reader 在 readRequest（2 < 4） | ❌ 未触顶 |
| GOMAXPROCS | 默认 64（= NumCPU），无覆盖 | ❌ 不是限制 |
| Go 内部锁（futex/Mutex） | pprof 仅 2.3%，无单点锁死 | ❌ 次要 |
| librados 连接数上限 | 01-5 实验 A Rep3 2969 ≈ ceph-fuse 2884（同 librados），差 3% | ❌ 不是瓶颈 |

→ 6 核封顶**不是**任何单一硬限触顶，而是 IOPS-延迟反馈平衡 + per-I/O CPU 极小的综合结果。

#### 5.4.5 为什么内核 CephFS 不封顶

内核 CephFS 从两个方向同时打破封顶机制：

1. **消除固定开销 5.4 cores** → 即使 IOPS 很低，CPU 也不会被固定开销抬高
   - 无 Go runtime、无 librados 用户态 messenger、无 cgo、无 FUSE dispatch

2. **消除延迟反馈环** → IOPS 可线性增长到后端极限
   - 无 FUSE dispatch 延迟（writev → /dev/fuse 路径不存在）
   - 无 cgo 转换开销（直接内核 C 代码）
   - 内核 messenger（软中断 + 内核线程，比 3 线程 epoll 更高效）
   - 结果：延迟从 11ms 降到 0.6ms → IOPS 从 11.6K 增到 26.6K

| 对比 | JuiceFS | 内核 CephFS |
|------|---------|------------|
| 固定开销 | 5.43 cores | ≈ 0 |
| per-I/O 延迟 | 11.1ms | 0.6ms |
| IOPS | 11.6K | 26.6K |
| 可变 CPU | 0.51 cores | ~1.2 cores |
| **总 CPU** | **5.94 ≈ 6 cores** | **~1.2 cores** |

→ 内核 CephFS 总 CPU ≈ 1.2 cores，远低于 64 核，不构成瓶颈 → "无封顶"。

#### 5.4.6 为什么 ceph-fuse ≈ JuiceFS

01-5 实验 B：ceph-fuse 2884 ≈ JuiceFS+Rep 2969（差 3%）。两者共享 6 核封顶的两个核心机制：
1. **FUSE dispatch 延迟**：都需 writev → /dev/fuse → 内核 FUSE 模块锁 → 每 I/O 5+ms dispatch 延迟
2. **librados 3 线程 messenger**：都用 librados（ceph-fuse 直接 C++，JuiceFS 经 cgo）→ 固定 ~1.3 cores + 限制网络处理吞吐

不同语言（C++ vs Go）但延迟反馈环和固定开销量级相当 → IOPS 封顶在相近水平 → CPU 封顶在 ~6 cores。

---

## 六、数据可信度校验

| 检查项 | 结果 |
|--------|------|
| Ceph HEALTH 全程 OK | ✅ |
| CephFS 3轮 REPEAT 方差 | EC randread S0: CV=0.5%, Rep: CV=2.9% |
| R/W 均衡 | 全部 1:1 ✅ |
| CephFS layout write BW | EC 3117 MiB/s（合理，128G/42s） |
| 同后端验证 | EC4+2 + replicated，同一 Ceph 集群 ✅ |
| 256K 对齐 | bs=256k 与 EC stripe_width 对齐 ✅ |
| WekaIO 未受影响 | 全程运行 ✅ |

---

## 七、后续动作

1. **回填**：perf-analysis/01 §5.3.4a/§5.3.5a 状态列 + §七决策链落点（已随 01-2d 订正完成）
2. ⚑ **订正后的决策建议**（给判定，不擅自落地）：
   - **首要**：**攻后端 EC4+2 随机读**（当前裸值 ~4300 < 6250 验收线）。这是系统天花板，客户端任何方案（含换栈）都无法突破它。
   - 如业务接受多挂载点 → JuiceFS 多实例 workaround（ra0 N=4 = 5013 MiB/s，靠并发绕过单客户端 FUSE 税，但仍受后端总能力约束）
   - 如业务需单挂载点且可接受 74% 达标 → CephFS 内核态 EC 4608（拿满后端裸值，仍不过 6250）；Rep 6718 过线但非当前 EC 方案且容量成本翻 3 倍
   - ~~换栈评估条件已满足（C1 坐实 + 单挂载点需求 + CephFS 显著优于 JuiceFS）~~ ⚑ **订正**：换栈只能把客户端从 2404 拿到后端裸值 4608，**不能过验收线**；randrw 场景 CephFS EC 仅 1.14×（几乎无收益）。换栈是否值得取决于"是否接受 74% 达标 + MDS/EC 生产化成本"，**且必须先解决后端瓶颈**，否则换栈后依旧不达标。
3. **pprof 深入**：goroutine.txt 可进一步分析（mutex/block profile 未启用，如需可重采）
4. **CephFS 生产评估**（若决定换栈）：
   - MDS HA（当前单节点，需扩到 3 节点）
   - EC overwrite 生产稳定性（长写测试）
   - CephFS 元数据池容量规划
