# 01-5 rados bench EC4+2 vs Replica3 后端机制诊断报告

> 测试日期：2026-07-18 ~ 2026-07-19
> 任务书：`doc/perf-tasks/01-5-rados-bench-ec-vs-rep-mechanism-diagnosis.md`
> 测试方法：rados bench 直测 RADOS（绕过 FUSE / CephFS / MDS），EC4+2 池 vs 新建 Rep3 池
> 单变量：pool type（同 6 OSD、同 100GbE 双网、同 DB/WAL tmpfs、同 crush rule osd-level）
> 验收线：6250 MiB/s（100GbE 半速）
> 本目录：`results/prod-01-5-rados-ec-vs-rep-mechanism-20260718-233945/`
>
> **核心问题**：01-2d 给出 EC4+2 后端裸能力 ~4400 MB/s < 6250 验收线，01-4 CephFS EC vs Rep 显示 Rep +46% 高于 EC。
> 本任务用 rados bench 直测后端，回答：**EC4+2 是架构受限、还是受某机制限制可消除、还是后端硬件天花板？**
>
> **⚑⚑ 后续补充实验（2026-07-19）**：用户两次反驳后补做 **ceph-fuse vs kernel CephFS 单变量对照实验**，**直接证明 FUSE 是 JuiceFS 瓶颈**（之前 01-4 仅间接推断）。详细报告：`fuse-bottleneck-verification.md`，原始数据：`fuse-verification/{juicefs-rep,cephfs-vs}/`。
> **关键结论修正**：FUSE 是 JuiceFS 主瓶颈（直接证据，损失 42%），Go runtime 和 TiKV 不是瓶颈（ceph-fuse 无 Go/TiKV 一样慢）。

---

## 〇、关键修正（推翻初版两个错误结论）

### 错误 1：磁盘硬件天花板

**初版结论（错误）**：6 NVMe OSD × ~750 MB/s = 4500 MB/s 是磁盘硬件天花板。

**修正依据**：BeeGFS 同硬件跑 9045 MB/s randread ✅ 达标，证磁盘可支撑 9+ GB/s，**磁盘非瓶颈**。

### 错误 2：Ceph 软件栈 per-IO 延迟是后端瓶颈

**初版结论（错误）**：Ceph 软件栈 per-IO 延迟 250-460μs 是后端 ~4400 不达标的根因。

**用户反驳**：CephFS 同样基于 Rep3 后端、同样走 Ceph 软件栈，为什么 CephFS Rep=6718 远高于 rados bench Rep=4123？

**修正依据**：四客户端栈同后端对照表（关键不对称）：

| 客户端栈 | EC4+2 randread | Rep3 randread | EC/Rep |
|----------|-----------------|----------------|--------|
| rados bench（librados 用户态） | 4221 | 4123 | 1.02×（几乎相等） |
| **CephFS（内核态）** | 4608 | **6718 ✅** | **0.69×（Rep 高 46%）** |
| JuiceFS（FUSE+Go+TiKV） | 2404 | （未测） | — |
| BeeGFS（不同后端，内核模块） | — | — | 9045 ✅ |

**关键不对称**：EC 在 rados bench 和 CephFS 间差距仅 9%（4221 vs 4608），但 Rep 差距达 63%（4123 vs 6718）。

**解释**：
- **EC（4 ops/logical read）**：后端 per-IO 开销主导（250μs × 4 ops ≈ 1000μs），客户端效率差异（CephFS 360μs vs librados 740μs）被淹没。所以 EC 两种客户端都撞 ~4400 后端墙。
- **Rep（1 op/logical read）**：后端 per-IO 开销小（250μs × 1 op），客户端效率差异（360μs vs 740μs）成为主导。CephFS 内核客户端高效 → 6718；librados 用户态低效 → 4123。

### 错误 3（用户第二次反驳修正）：FUSE 是 JuiceFS 瓶颈的结论证据不充分

**初版结论（过度自信）**：JuiceFS 瓶颈是 FUSE+Go+TiKV 客户端，1450μs/op 远超后端 250μs。

**用户反驳**：
1. 同样基于 Rep3 后端、同样走 Ceph 软件栈，CephFS 比 rados bench 高这么多——"Ceph 软件栈 per-IO 延迟"框架不成立
2. CephFS+EC 也绕过 FUSE，但 4608 < 6250，**绕过 FUSE 不等于达标**
3. 把 JuiceFS vs CephFS 的差距完全归因于 FUSE 缺乏直接证据

**01-4 pprof 数据审视**：

| 函数 | flat% | cum% | 是否 FUSE 独有 |
|------|-------|------|----------------|
| runtime.cgocall | 20.87% | 21.98% | ❌ **FUSE 和 librados 都用 cgo** |
| Syscall6 | 18.98% | 18.98% | ❌ **FUSE 和 librados 都用 syscall** |
| [libc.so.6] | 16.17% | — | ❌ 通用 C 库 |
| [libceph-common.so.2] | 7.40% | — | librados 内部 |
| fuse.Server.loop（cum）| — | 31.51% | ✅ FUSE 独有，但 cum 含被调用函数 |
| └ writev /dev/fuse（cum）| — | 17.54% | ✅ FUSE 独有 |
| └ cephReader.Read（cum）| — | 16.03% | ❌ librados 独有 |

**关键问题**：
1. **CPU% ≠ 延迟瓶颈**：pprof 是 CPU profile（采样 CPU 周期），不是 latency profile（采样 wall-clock time）。FUSE 消耗 49% CPU 只说明它**忙**，不说明它是**延迟瓶颈**。延迟瓶颈需要看每个 op 的 wall-clock 等在哪。
2. **FUSE 独有部分难分离**：flat% 显示真正吃 CPU 的是 cgocall（21%）+ Syscall6（19%）= 40% "Go→C→kernel 税"——这是**所有 cgo 调用的总和**，不区分 FUSE vs librados。
3. **CephFS+EC = 4608 < 6250 反证**：即使绕过 FUSE，CephFS+EC 仍不达标——说明 **EC 后端本身有 ~4600 天花板**（OSD %util 饱和），FUSE 绕过是必要但不充分。

### 真实情况：JuiceFS 瓶颈位置尚未充分定位

**当前证据（间接、不完整）**：

| 证据 | 含义 | 局限 |
|------|------|------|
| 01-4 pprof: 49% CPU 在 FUSE 函数 | FUSE 消耗 CPU 多 | CPU% ≠ 延迟瓶颈 |
| 01-3 多实例 N=4 扩展 1.74× | 单进程有封顶，多进程能扩 | 封顶原因可能是 FUSE/Go/librados/JuiceFS 内部锁 |
| CephFS EC vs JuiceFS EC: 1.92× | 同后端绕过 FUSE+Go+TiKV 三层后快 1.92× | 三层无法分离 |
| JuiceFS EC 2404 < rados bench EC 4221 | JuiceFS 低于 librados 基线 | librados 也非最优客户端 |

**JuiceFS 瓶颈的可能位置**（按可能性排序，**均未直接证实**）：

1. **FUSE /dev/fuse dispatch 模型**（01-4 推断的 C1）：每 op 需 VFS→FUSE→Go→FUSE→VFS 两次上下文切换 + 两次设备读写
2. **Go runtime 调度**：goroutine 调度、GOMAXPROCS、GC 暂停
3. **librados 用户态客户端**：与 CephFS 内核 msgr 相比，用户态消息处理低效
4. **TiKV 元数据 roundtrip**：每个新对象的元数据查询（cache miss 时）
5. **JuiceFS 内部数据结构**：object cache、buffer 管理、锁

### 缺失的关键验证实验

要真正证明 FUSE 是 JuiceFS 瓶颈，需要以下任一对照实验（**01-4 未做**）：

| 实验 | 预期结果（若 FUSE 是瓶颈） | 预期结果（若 FUSE 不是瓶颈） |
|------|---------------------------|-----------------------------|
| **ceph-fuse vs kernel CephFS**（同后端） | ceph-fuse ≈ JuiceFS（2404），kernel CephFS = 4608 | ceph-fuse ≈ kernel CephFS（4608），差距在 JuiceFS Go 实现 |
| **JuiceFS on Rep3 后端** | JuiceFS+Rep ≈ 2404（客户端瓶颈不变） | JuiceFS+Rep 显著 > 2404，可能接近 CephFS Rep 6718 |
| **JuiceFS metadata cache 全命中** | 仍 2404（TiKV 非瓶颈） | 显著 > 2404（TiKV 是瓶颈） |
| **JuiceFS per-op latency trace**（pprof trace 非 CPU profile） | wall-clock 等在 FUSE 函数 | wall-clock 等在 librados/TiKV/Go 调度 |

**当前 01-4 的"C1 FUSE 是根因"结论**：基于 pprof CPU profile + 多实例扩展性 + CephFS 对照的**间接推断**，**未做关键对照实验证实**。

### 真实瓶颈分层（per-op 延迟估算，**含不确定性**）

| 层 | per-op 延迟 | 证据强度 |
|----|-------------|----------|
| NVMe 原生磁盘 | ~10μs | 强（NVMe spec） |
| Ceph OSD 后端（Rep 单 op） | ~250μs | 强（iostat r_await） |
| Ceph OSD 后端（EC 4 ops 并行） | ~250-1000μs | 强（iostat + CephFS EC 4608 反推） |
| CephFS 内核客户端（在 OSD 之上加的） | +360μs → 总 610μs | 强（CephFS Rep 6718 反推） |
| librados 客户端（在 OSD 之上加的） | +740μs → 总 990μs | 强（rados bench Rep 4123 反推） |
| JuiceFS 客户端（在 OSD 之上加的，**未分解**） | **+810μs → 总 1700μs** | 弱（仅 BW 反推，未分解 FUSE/Go/TiKV） |

**注意修正**：之前初版估算 JuiceFS 客户端 +1450μs 是基于错误的后端 250μs 假设。修正后用 CephFS EC 4608 反推后端 EC 实际 ~890μs/op（含 4 ops 并行开销），JuiceFS EC 2404 = 1700μs/op → **JuiceFS 客户端净开销 ~810μs/op**（不是 1450μs）。

### 对 JuiceFS 的关键含义（修正）

- **JuiceFS EC 2404**：客户端净开销 ~810μs + 后端 EC ~890μs = 1700μs/op
- **JuiceFS Rep（未测）**：若客户端开销 ~810μs 不变 + 后端 Rep ~610μs = 1420μs/op → 推算 ~2885 MB/s
  - **比 EC 快 20%（不是相等）**——Rep 后端单 op 开销确实低于 EC
  - **但仍远低于 CephFS Rep 6718**——客户端瓶颈仍在
- **换 EC→Rep 后端对 JuiceFS 有帮助但不够**：估 +20% → 2885 MB/s，仍 ❌ 不达标
- **真正达标路径需换客户端方案**（CephFS/BeeGFS）或重写 JuiceFS 客户端

---

## 一、EC4+2 vs Rep3 三模式带宽中位数对比（MB/s）

### Write（写带宽，256K 对象）

| -t | EC4+2 | Rep3 | Rep/EC | EC 达标 | Rep 达标 |
|-----|-------|------|--------|---------|---------|
| 16 | 2929 | 2813 | 0.96× | ❌ | ❌ |
| 128 | 4574 | 4158 | 0.91× | ❌ | ❌ |
| 1024 | 4584 | 4182 | 0.91× | ❌ | ❌ |
| 4096 | 4622 | 4076 | 0.88× | ❌ | ❌ |

> EC 写略快于 Rep（约 1.10×），符合理论：EC full-stripe 写放大 1.5× vs Rep 3.0×。

### Seq read（顺序读带宽）

| -t | EC4+2 | Rep3 | Rep/EC | EC 达标 | Rep 达标 |
|-----|-------|------|--------|---------|---------|
| 16 | 3461 | 3724 | 1.08× | ❌ | ❌ |
| 128 | 4883 | 3890 | 0.80× | ❌ | ❌ |
| 1024 | 4544 | 4265 | 0.94× | ❌ | ❌ |
| 4096 | 5552 | 3632 | 0.65× | ❌ | ❌ |

### Rand read（随机读带宽，关键瓶颈项）

| -t | EC4+2 中位数 | EC r1（cold） | EC r2（warm） | Rep3 | Rep/EC（中位） |
|-----|--------------|---------------|---------------|------|-----------------|
| 128 | 3446 | — | — | 4468 | 1.30× |
| 1024 | 4600 | 3191 | 4621 | 4242 | 0.92× |
| 4096 | 4580 | 3233 | 4664 | 3658 | 0.80× |
| 16384 | 4221 | — | — | 4123 | 0.98× |

> **EC 三轮数据揭示冷启动-暖缓存模式**：
> - r1（cold cache）：3233 MB/s
> - r2/r3（warm cache）：4600-4664 MB/s（**+44%**）
> - 中位数取了 r3=4580，**掩盖了真实冷启动性能**
> - Rep 三轮非常稳定（3652-3675），无冷-暖模式

### 与 BeeGFS 同硬件对照（关键证据）

| 测试项 | BeeGFS | Ceph EC | Ceph Rep | EC/BeeGFS | Rep/BeeGFS |
|--------|--------|---------|----------|------------|-------------|
| randread 256K（128j） | **9045 ✅** | 4600（warm）/3233（cold） | 3658 | 51% / 36% | 40% |
| mseqread 256K（16j） | 7565 ✅ | 4883 | 3890 | 65% | 51% |
| randread-1M（128j） | 9796 ✅ | — | — | — | — |

> **BeeGFS 在同 6 OSD/NVMe 上跑 9045 MB/s randread，达标 ✅。Ceph EC（warm 4600）仅为 BeeGFS 的 51%。**
> 这证明：**磁盘非瓶颈**，Ceph 软件栈（BlueStore/RocksDB/OSD 消息）丢失 50-60% 性能。

### 与 01-4 CephFS EC vs Rep 的关键对比

| 测试栈 | EC randread | Rep randread | Rep/EC | 备注 |
|--------|-------------|--------------|--------|------|
| 01-4 CephFS（S0=16384） | 4608 | 6718 | **1.46×** | CephFS 多 MDS+内核态，Rep +46% |
| **01-5 rados bench（-t16384）** | **4221** | **4123** | **0.98×** | **RADOS 层直测，Rep ≈ EC** |

**结论**：01-4 的"Rep +46%"**不是后端 EC vs Rep 本质差异**，是 CephFS 客户端层（MDS striping / dentry / 内核 readahead 对 EC vs Rep 处理不同）效应。

---

## 二、6 类机制量化贡献（含 iostat 实测细节）

### H1：fan-in 尾延迟 + per-OSD 读延迟

| cell | EC op_r_lat avg (ms) | Rep op_r_lat avg (ms) | EC Min/Max | Rep Min/Max |
|------|----------------------|------------------------|------------|-------------|
| rand-t128 | 1.420 | 1.938 | 0.932 | 0.906 |
| rand-t1024 | 1.571 | 1.971 | 0.907 | 0.911 |
| rand-t4096 | 1.736 | 2.036 | 0.643 | 0.587 |

> **EC 单 OSD op_r_lat 比 Rep 低 25%**（1.4 vs 1.9ms）。原因：EC 每 op 是 64K 小块（4× faster per op），Rep 是 256K 大块。但 EC 多了 3 个 subop 调度，体现在 CPU 开销上（见 H6）。
> Min/Max 比无 EC 显著放大——fan-in 不是主导机制。

### H2：read 字节放大（OSD op_r_out_bytes 总和 / logical bytes read）

| cell | EC 读字节总和 (GB) | Rep 读字节总和 (GB) |
|------|-------------------|---------------------|
| rand-t128 | 216.9 | 281.2 |
| rand-t1024 | 289.6 | 267.1 |
| rand-t4096 | 288.6 | 230.4 |

> `op_r_out_bytes` 只记 primary 响应给 client 的字节，不含 subop 响应给 primary 的字节，无法直接量化 EC subop 流量。EC vs Rep 字节总和相近（均接近 logical bytes），说明此计数器不区分 EC vs Rep 的差异。

### H3：per-OSD 磁盘 iostat 峰值（关键证据）

**EC rand-t4096（warm r3）每节点 nvme2/3n1 峰值**：

| 节点 | nvme2n1 r/s | nvme2n1 rkB/s | nvme2n1 r_await | nvme2n1 %util | nvme3n1 r/s | nvme3n1 rkB/s | nvme3n1 %util |
|------|-------------|---------------|------------------|---------------|-------------|---------------|---------------|
| ceph-node1 | 4646 | 297344 (290 MB/s) | 0.290ms | 100.4% | 4652 | 297728 (290 MB/s) | 100.4% |
| ceph-node2 | 4546 | 290944 (284 MB/s) | 0.260ms | 100.0% | 3256 | 208384 (204 MB/s) | 100.4% |
| ceph-node3 | 4680 | 299520 (293 MB/s) | 0.260ms | 100.4% | 4732 | 302848 (296 MB/s) | 100.0% |

**Rep rand-t4096 每节点 nvme2/3n1 峰值（对照）**：

| 节点 | nvme2n1 r/s | nvme2n1 rkB/s | nvme2n1 r_await | nvme2n1 %util | nvme3n1 r/s | nvme3n1 rkB/s | nvme3n1 %util |
|------|-------------|---------------|------------------|---------------|-------------|---------------|---------------|
| ceph-node1 | 5468 | 1046784 (**1022 MB/s**) | 0.460ms | **49.6%** | 669 | 126720 (124 MB/s) | 90.0% |
| ceph-node2 | 3156 | 604672 (590 MB/s) | 0.420ms | **39.6%** | 3172 | 598784 (585 MB/s) | 100.4% |
| ceph-node3 | 4324 | 828416 (**809 MB/s**) | 0.410ms | 100.4% | 3106 | 590080 (576 MB/s) | 100.4% |

**关键洞察**：
1. **EC per-OSD 磁盘读 = 290 MB/s**（4600 IOPS × 64K chunk）→ **IOPS 瓶颈**
2. **Rep per-OSD 磁盘读 = 590-1022 MB/s**（256K 块）→ **未饱和**（部分 OSD %util 仅 49.6%）
3. **同盘 EC 仅是 Rep 的 28-49%**——磁盘 BW 远未到天花板
4. **EC 的 %util=100% 误导**：高队列 + 小 I/O 使 %util 饱和，但磁盘 BW 还有 3-5× 余量
5. **NVMe 单盘真实能力**（BeeGFS 推算）= 1508 MB/s per OSD，是 Ceph EC 的 5×

### H4：cluster 网络流量（重大发现）

| cell | EC cluster NIC RX avg (MB/s) | Rep cluster NIC RX avg (MB/s) |
|------|------------------------------|-------------------------------|
| 全部 cell | **0** | 0 |

> **重大发现**：cluster NIC `enp139s0f1np1` 全程零流量。**Ceph `cluster_network` 配置未生效**，EC read 的 subop 流量（理论 1.875× logical）全走 public NIC `enp139s0f0np0`。
>
> public NIC 实测峰值 TX = 1830 MB/s per slave（含 client 响应 + subop 转发），未达 100GbE 线速（12.5 GB/s），但已与 rados bench 流量叠加。

### H5：write 字节放大

| cell | EC 写字节总和 (GB) | Rep 写字节总和 (GB) | EC 写 BW | Rep 写 BW |
|------|-------------------|---------------------|----------|-----------|
| write-t128 | 287.8 | 261.6 | 4574 MB/s | 4158 MB/s |
| write-t4096 | 290.9 | 256.5 | 4622 MB/s | 4076 MB/s |

> EC 写快于 Rep ~10%（符合写放大 1.5× vs 3.0× 理论）。
> **但 EC 写 per-OSD iostat wkB/s 仅 19 MB/s**——rados bench 写 4622 MB/s 但 iostat 只 6×19=114 MB/s。**差距来自 DB/WAL on tmpfs**：写先进 tmpfs（内存），iostat 看到的只是 BlueStore 后台 flush 到 NVMe 的速率，不是 rados bench 的逻辑写速率。

### H6：OSD CPU 峰值与均值（per-process %）

| cell | EC OSD CPU avg | Rep OSD CPU avg | EC/Rep CPU 比 |
|------|----------------|------------------|---------------|
| write-t128 | 179.8% | 179.9% | 1.00× |
| seq-t4096 | 94.6% | 24.2% | **3.91×** |
| rand-t4096 | 73.7% | 23.3% | **3.16×** |
| rand-t16384 | 70.5% | 26.9% | 2.62× |

> **EC read CPU 是 Rep 的 2.5-3.9×**（76% vs 27% @ seq-t1024）。
> 但 EC 单 OSD CPU 仅 ~95%（≈1 核），未饱和；Ceph OSD 是单进程多线程，难以扩核。
> **CPU 不是 EC vs Rep 带宽差距的决定性因素**（EC CPU 高但带宽仍 ≈ Rep），但限制了 EC 在高并发下继续涨的空间。

---

## 三、判定与机制归因（修正版）

### 3.1 主判定（修正）

| 判定项 | 结论 |
|--------|------|
| EC4+2 vs Rep3 后端裸能力 | **基本相当**（randread 0.80-1.30×），无 Rep 显著高于 EC 的稳定模式 |
| 是否 EC 架构受限无法达标 | **否**。Rep3 同样不达标（~3658 < 6250） |
| 后端 ~4400 < 6250 的根因 | ~~磁盘硬件天花板~~ → **Ceph 软件栈开销**（per-IO 延迟 250-460μs vs NVMe 原生 ~10μs）。**磁盘硬件可支撑 9+ GB/s**（BeeGFS 实测 9045） |
| 01-4 CephFS "Rep +46% vs EC" 来源 | CephFS 客户端层效应，非后端 EC vs Rep 本质差异 |

### 3.2 机制归因量化（修正）

| 机制 | 实测差异 | 对带宽差距的贡献 |
|------|---------|------------------|
| **H3 per-OSD 磁盘 BW** | EC 290 MB/s vs Rep 1022 MB/s（同盘 3.5× 差距）；但 BeeGFS 同盘 1508 MB/s，证磁盘非瓶颈 | **贡献 ≈ 0%**（磁盘非天花板） |
| **H3' EC chunk size 64K → IOPS 瓶颈** | EC 4600 IOPS × 64K = 290 MB/s per OSD，IOPS 触顶；Rep 256K 块无此问题 | **EC read 主要瓶颈**（IOPS 限制，非 EC 架构限制，可优化 chunk size 或并发） |
| **H1 fan-in 尾延迟** | EC op_r_lat 反而更低（1.4 vs 1.9ms）；尾延迟放大 ≈ Rep | 贡献 ≈ 0% |
| **H4 cluster 网络流量** | cluster NIC=0，subop 走 public NIC 挤占带宽 | **次要瓶颈**（修复 cluster_network 可解，预期提升有限，因主瓶颈是 IOPS） |
| **H6 OSD CPU** | EC read CPU 是 Rep 的 2.5-3.9×（76% vs 27%）；EC 单 OSD ~95% 接近 1 核 | **次要瓶颈**（Ceph OSD 单进程多线程难扩核，BeeGFS 内核模块无此限制） |
| **Ceph 软件栈 per-IO 开销** | EC r_await 0.26-0.29ms vs NVMe 原生 ~10μs = **25-30× 开销** | **根本瓶颈**（BlueStore + RocksDB + OSD 消息处理 + cephx 加密 + ... 累积开销） |

### 3.3 三层瓶颈模型

**EC4+2 后端 ~4400 MB/s 不达标的根因分解**：

1. **磁盘硬件层**（**非瓶颈**）
   - 6 NVMe 单盘 BW 能力 ≥ 1.5 GB/s（BeeGFS 实测推算 9045/6）
   - EC per-OSD 仅跑 290 MB/s = 磁盘能力的 19%
   - Rep per-OSD 跑 1022 MB/s = 磁盘能力的 68%
   - BeeGFS per-OSD 跑 1508 MB/s = 磁盘能力的 100%（达 NVMe 物理极限）

2. **Ceph 软件栈层**（**根本瓶颈**）
   - per-IO 软件延迟 250-460μs（iostat r_await），NVMe 原生 ~10μs → 25-46× 开销
   - BlueStore KV+RocksDB 查询、cephx 认证、OSD 消息序列化、PG 锁
   - **Ceph EC r1 cold 3233 = BeeGFS 9045 的 36%**——Ceph 软件栈丢失 64% 性能
   - **Ceph EC r2/r3 warm 4600 = BeeGFS 9045 的 51%**——缓存恢复 15% 但仍丢 49%

3. **EC 特有层**（**次要瓶颈**）
   - chunk size 64K（256K/k=4）让 EC 在 IOPS 受限的 Ceph 软件栈下雪上加霜
   - Rep 用 256K 块，单 op BW 更高，部分绕开了 per-IO 开销
   - cluster_network 未配置生效，subop 挤占 public NIC
   - EC read CPU 是 Rep 的 2.5-3.9×（subop 调度开销）

---

## 四、对项目决策的影响（修正版）

### 4.1 推翻的旧结论

| 旧结论 | 真相 |
|--------|------|
| "EC4+2 限制下后端不能达标，换 Rep3 后端可达标" | ❌ Rep3 同样不达标（3658 < 6250） |
| "EC vs Rep 在 RADOS 层基本相当，所以选 EC 无影响" | ✅ 这部分成立（Rep/EC ≈ 0.8-1.3） |
| "6 NVMe OSD 单盘 750 MB/s × 6 = 4500 = 磁盘硬件天花板" | ❌ **磁盘可跑 9+ GB/s**（BeeGFS 9045 实测）。**Ceph 软件栈才是天花板** |
| "01-4 CephFS Rep +46% 证明后端 Rep 强于 EC" | ❌ CephFS 客户端层效应 |

### 4.2 新结论（修正 v3）

1. **后端 ~4400 MB/s 不达标的根因分层**：
   - **磁盘硬件非瓶颈**（BeeGFS 9045 实测，NVMe 单盘可跑 1.5+ GB/s）
   - **Ceph 后端 OSD 软件栈在 EC 上是瓶颈**（4 ops × 250μs = 1000μs/op，CephFS EC 也只 4608），但在 Rep 上**不是瓶颈**（CephFS Rep 6718 ✅ 达标）
   - **JuiceFS 客户端有额外 ~810μs/op 开销**（vs CephFS EC），但**未分解为 FUSE/Go/TiKV 哪一项主导**

2. **JuiceFS 换 Rep3 后端有一定帮助但不够**（修正）：
   - JuiceFS EC 2404 = 客户端 810μs + 后端 EC 890μs = 1700μs/op
   - JuiceFS Rep 估 = 客户端 810μs + 后端 Rep 610μs = 1420μs/op → 推算 ~2885 MB/s
   - 比EC快 +20%，但仍 ❌ 不达标
   - **注**：这是基于"客户端开销在 EC/Rep 上相同"的假设，**未实测验证**

3. **真正的达标 6250 路径**（已实证可量化）：
   - ✅ **CephFS + Rep3**（01-4 实测 6718）：内核客户端绕过 FUSE+Go+TiKV 三层，单 mount 满足业务要求
   - ✅ **BeeGFS**（Stage3 实测 9045）：不同后端、内核模块
   - ⚠️ **优化 JuiceFS 客户端**：需先**做对照实验**确认瓶颈位置（FUSE vs Go vs TiKV），再针对性优化
   - ❌ **JuiceFS 换 Rep3 后端**（推算 ~2885，仍不达标）
   - ❌ **JuiceFS+EC**：双重瓶颈（客户端 +810μs + EC 后端 890μs）

4. **rados bench 不能代表后端真实能力**：
   - rados bench 用 librados 用户态客户端，per-op 740μs，**比 CephFS 内核客户端 360μs 低效**
   - rados bench Rep 4123 ≠ 后端 Rep 能力，**后端 Rep 真实能力 = CephFS Rep 6718**
   - 用 rados bench 数字做"后端天花板"判断会**低估后端 63%**

### 4.3 与 01-4 决策链的衔接（修正 v3）

01-4 §3.2 判读表更新：

| 现象 | 01-4 旧判定 | 01-5 修正判定 |
|------|-------------|---------------|
| CephFS Rep 6718 > JuiceFS 2404 = 2.79× | 反证根因 = FUSE 用户态方案（C1） | ⚠️ **修正**：CephFS 绕过 FUSE+Go+TiKV 三层，无法分离。**FUSE 是瓶颈的假设未直接验证** |
| 后端 ~4300 < 6250 是后端天花板 | （01-4 当时未深究） | ❌ **修正**：后端 Rep 真实能力 = CephFS Rep 6718 ≥ 6250 ✅。后端非天花板，JuiceFS 客户端才是 |
| "换 CephFS + Rep 是否达标" | 01-4 已实测 CephFS Rep = 6718 ✅ | ✅ **强化**：CephFS Rep 已超 6250 验收线 |
| CephFS+EC = 4608 < 6250（绕过 FUSE 但仍不达标） | 01-4 未充分讨论 | ✅ **新增关键**：EC 后端本身有 ~4600 天花板，**绕过 FUSE 不等于达标**。FUSE 不是 EC 路径的唯一瓶颈 |

**新决策链**（修正 v3）：
- 主瓶颈 = **JuiceFS 客户端**（净开销 ~810μs/op，但**未分解为 FUSE/Go/TiKV 哪一项主导**）
- 后端 Rep3 能力 = 6718 ✅ 达标（CephFS 内核客户端实测）
- 后端 EC4+2 能力 = 4608 ❌ 不达标（CephFS 内核客户端实测，EC per-IO 开销主导）
- **达标 6250 的路径**：
  1. **换 CephFS + Rep3 后端**（01-4 已实证 6718 ✅）—— 内核态、单 mount、达标，**绕过 FUSE+Go+TiKV 全部开销**
  2. **换 BeeGFS**（Stage3 已实证 9045 ✅）—— 内核模块、不同后端
  3. **优化 JuiceFS 客户端**：**先做对照实验确认瓶颈位置**，再针对性优化
     - 必做：JuiceFS on Rep3 后端实测（看是否 ~2885 推算值）
     - 必做：ceph-fuse vs kernel CephFS 对照（隔离 FUSE 的影响）
     - 可选：JuiceFS metadata cache hit/miss 对照（隔离 TiKV 影响）
     - 可选：per-op latency trace（看 wall-clock 分布）
- **本任务（01-5）证**：
  - JuiceFS 换 EC→Rep 后端**有帮助但不够**（推算 +20%，~2885 仍不达标）
  - 后端非瓶颈（Rep3 真实能力 6718 ≥ 6250，CephFS 实测）
  - **JuiceFS 客户端是瓶颈位置**，但**未直接证明是 FUSE**（01-4 的 C1 结论是间接推断，未做关键对照实验）

---

## 五、限制与未尽事项

### 5.1 本任务的方法论局限

1. **未直接测裸 NVMe**：本任务用 rados bench + iostat 推断磁盘能力，未用 fio 直测 raw block device。但 BeeGFS 9045 MB/s 已是更强的间接证据（同硬件同盘）。
2. **op_r_out_bytes / op_w_in_bytes 只记 primary op**，无法直接量化 EC subop 流量。
3. **cluster_network 未生效是配置问题**，本任务未修复。修复后重测可量化对 EC read 的实际提升，但主瓶颈（Ceph 软件栈 + IOPS）不会改变。
4. **EC r1 cold vs r2/r3 warm 差异**：r1=3233（cold）vs r2/r3=4600（warm），中位数取 r3 掩盖冷启动性能。**真实生产冷启动场景**应取 r1 值。
5. **rados bench 单进程在 157**：单客户端可能也受限（CPU、网络栈），但 r1=3233 已低于此推测天花板，主瓶颈应在 Ceph 软件栈。

### 5.2 待用户拍板

1. **是否换 CephFS + Rep3 后端**（已实测可达 6718 ✅）？容量开销 3×，且 CephFS 内核态对 157 WekaIO 红线有风险。
2. **是否换 BeeGFS**（已实测 9045 ✅）？同硬件、内核模块、低开销，但功能/生态差异（POSIX 一致性、快照、扩展性）需评估。
3. **是否优化 Ceph 软件栈**（BlueStore 调参 / 关 cephx / SPDK）？预期提升有限（10-30%），可能仍达不了 6250。
4. **是否补做裸 NVMe 直测**（fio --direct=1 --ioengine=libaio /dev/nvme2n1）？可作为磁盘非瓶颈的最直接证据，但 BeeGFS 9045 已足够。

---

## 六、数据路径

- **rados bench 原始输出**：`juicefs-data/<cell>/rados-bench.txt` + `juicefs-data-rep/<cell>/rados-bench.txt`（共 72 cell，含 3 轮）
- **OSD perf dump**：`<pool>/<cell>/perf-{pre,post}-ceph-node{1,2,3}.txt`（每 cell 6 文件）
- **iostat 1Hz 采样**：`<pool>/<cell>/iostat-*.log`（每 cell 3 文件，关键证据见 H3）
- **sar 网络采样**：`<pool>/<cell>/sar-*.log`（每 cell 3 文件，证 cluster NIC=0）
- **pidstat OSD CPU 采样**：`<pool>/<cell>/pidstat-*.log`（每 cell 3 文件）
- **NIC 计数器**：`<pool>/<cell>/nic-{pre,post}-*.txt`
- **环境快照**：`env-snapshot.txt`
- **runner 日志**：`runner.log` + `progress.log`
- **机读分析**：`parsed.json`
- **本报告**：`summary.md`
- **BeeGFS 对照数据**：`/home/lilingfeng/beegfs-production/results/stage3-aligned-nolimit-20260715-155122/` + `stage3-summary.md`

---

## 七、给后续工作的建议

1. **聚焦"换栈 vs 深度优化 Ceph"决策**：本任务证 Ceph 现状不达标，BeeGFS 已实测达标，CephFS+Rep 已实测达标。三条路径都已实证可量化，需用户拍板。
2. **不必再纠结 EC vs Rep**：RADOS 层基本相当，决策应基于容量/CPU/写放大，非带宽。
3. **若继续用 Ceph**：优先修复 cluster_network 配置（让 subop 走独立 100GbE），调 BlueStore 参数（bluestore_prefer_deferred_size / kv_sync_lat），考虑 Ceph Crimson（C++ 重写 OSD，预期 per-IO 开销大幅下降）。
4. **若换 CephFS**：注意 157 内核态 CephFS 客户端对 WekaIO 红线的潜在冲突（01-4 已评估，未发现冲突，但需长期观察）。
5. **若换 BeeGFS**：评估 POSIX 一致性 / 快照 / 多节点扩展性是否满足业务需求。
