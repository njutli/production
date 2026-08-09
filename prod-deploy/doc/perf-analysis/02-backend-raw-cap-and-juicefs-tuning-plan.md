# 02 · 后端裸能力提升 + JuiceFS 层级调优计划

> 日期：2026-07-20　维护：opencode（规划/校验）/ GLM（执行）
> 承接：`01-baseline-review-and-nolimit-plan.md`（01 阶段基线 + 调优计划）
> 本阶段一句话：**01 阶段已确认"后端裸能力不足"和"FUSE 是 JuiceFS 主瓶颈"两个核心问题；02 阶段分两条主线并行攻坚——A 线提升 Ceph 后端裸能力（逼近/突破 6250 验收线），B 线缩小 JuiceFS 与后端裸能力的差距（从 56% 提升）**。

---

## 一、01 阶段工作总结

### 1.1 任务清单与性质

| 任务 | 性质 | 核心成果 |
|------|------|----------|
| **01-1** | 重定基线 | 从零部署 Ceph+TiKV+JuiceFS，不限速 ra0 基线入表 |
| **01-2 / 2b / 2c** | 诊断扫描 + 补丁 | randread 降并发扫描、读放大诊断（0.985≈1.0）、randrw 四档 R/W=1.0 均衡、default 读放大 2.01× 量化 |
| **01-2d** | 全量基线重测 | **准确基线就位**（见 §1.2），推翻旧全部真值 |
| **01-3** | 可扩展性验证 | 单进程 CPU 封顶 ~6 核坐实；多实例可倍增（N4=5013=1.74×）但业务要求单挂载点→否决多挂载出路 |
| **01-4** | JuiceFS 瓶颈分析 | pprof 定位根因 = 用户态方案固定开销（91% 固定 + 9% 可变）；CephFS 内核态对照（EC 4608 / Rep 6718）；§5.4 解释 6 核封顶 = 反馈平衡点 |
| **01-5** | 进一步瓶颈分析 | 三层瓶颈分解 + 代码级对比；FUSE 直接证据（ceph-fuse 单变量对照损失 42%）；BeeGFS 优势归因 = 设计目标不同（HPC 专用 vs 统一三接口） |

### 1.2 准确基线（01-2d，已采信）

> 口径：不限速 100GbE，256K block，单客户端，冷态 cache=0，`--openfiles=128`，§8.3 稳态中位数。

| 测试项 | default (A) | ra0 (B) | 50% 线 | 达标 |
|--------|---------|-----|------|:---:|
| seqread (1job) | 1263 | 178 | 6250 | ❌ |
| mseqread (16job) | 3804 | 1909 | 6250 | ❌ |
| seqwrite (定量4G) | 1527 | 1557 | 6250 | ❌ |
| mseqwrite (定量64G) | 4886 | 4121 | 6250 | ❌ |
| layout (定量128G) | 3357 | 3198 | 6250 | ❌ |
| **randread (128job)** | 1480 | **2404** | 6250 | ❌ |
| randwrite-true (128job) | 3635 | 4274 | 6250 | ❌ |
| randrw 合计 (128job) | 2069 | 2635 | 6250 | ❌ |

**后端裸能力**（rados bench，01-2d §3.3 REPEAT=3 低方差稳态）：顺序读 ~4400 / 随机读 **~4300–4400 MB/s**。

### 1.3 01 阶段核心结论（三层瓶颈分解，01-5 最终版）

```
┌────────────────────────────────────────────────────────────────────┐
│ 层级           │ 瓶颈             │ 证据                    │ 结论   │
├────────────────────────────────────────────────────────────────────┤
│ ① 磁盘硬件     │ ❌ 非瓶颈        │ BeeGFS 同硬件 9045      │ 可排除 │
│ ② Ceph OSD 软件 │ EC 路径是瓶颈   │ CephFS+EC 4608 < 6250   │ 待攻   │
│    栈（EC4+2） │ Rep 路径非瓶颈   │ CephFS+Rep 6718 ✅ 达标 │        │
│ ③ FUSE 用户态  │ JuiceFS 主瓶颈   │ ceph-fuse 单变量 -42%   │ 待攻   │
└────────────────────────────────────────────────────────────────────┘
```

1. **EC4+2 vs Rep3 在 RADOS 层基本相当**（0.80-1.30×）。01-4 CephFS "Rep +46% vs EC" 是客户端层效应（IOPS 放大），非后端本质差异。
2. **磁盘非瓶颈**（BeeGFS 同硬件 9045；EC per-OSD 仅 290 MB/s = 磁盘能力的 19%）。
3. **Ceph OSD 软件栈在 EC 是瓶颈**（IOPS 放大：256K → 4×64K chunks → disk IOPS bound，%util=100%），**在 Rep 非瓶颈**（CephFS+Rep 6718 ✅ 达标）。
4. **FUSE 是 JuiceFS 主瓶颈**（直接证据：ceph-fuse 单变量对照 4972 → 2884，损失 42%；slat 暴涨 15×：729μs → 11092μs）。
5. **Go runtime 和 TiKV 不是瓶颈**（ceph-fuse 无 Go/TiKV 但和 JuiceFS 一样慢，2884 vs 2969 差 3%）。
6. **rados bench 不能代表后端真实能力**（librados 用户态比 CephFS 内核客户端低效 63%）。因为 librados 使用用户态 messenger，每次网络收发都需 user↔kernel context switch，而 kernel CephFS 内核模块使用内核态 socket 直连 OSD，无此开销。
7. **达标 6250 路径**：✅ kernel CephFS+Rep（6718）/ ✅ BeeGFS（9045），其余均不达标。

### 1.4 Ceph per-op 软件开销代码级定位（01-5 §十二）

| 开销来源 | 代码位置 | 估算 per-op 开销 | 可消除性 |
|----------|----------|------------------|----------|
| cephx AES（4×签名/验证）| `CephxSessionHandler.cc:156` | 40-100μs | **可关**（`cephx_sign_messages=false`） |
| BlueStore RocksDB（onode + extent）| `BlueStore.cc:12744` `:13141` | 20-40μs | 部分可调（cache 加大） |
| 线程池切换（messenger → ShardedOpWQ → PG lock → collection lock）| `OSD.cc:9889` | 20-40μs | 架构固有 |
| do_op 验证（caps + op limiter）| `PrimaryLogPG.cc` | 10-20μs | 架构固有 |
| checksum（per-blob CRC）| BlueStore | 5-10μs | 可关（不推荐） |
| **Ceph per-op 总开销** | — | **~155-330μs** | 部分可削减 |

对照：**BeeGFS per-op 总开销 ~67-127μs**（无 cephx/RocksDB/线程池切换），差距 88-203μs/op。

### 1.5 为什么 BeeGFS 全面领先（01-5 §十二最终版）

- **Ceph**：官方定位 "scalable **unified** distributed storage"（[ceph.io](https://ceph.io)，`doc/technical-charter.rst`），提供 object + block + file 三合一接口，per-op 需经过安全/功能验证链。
- **BeeGFS**：官方定位 "parallel file system, **architected for large-scale HPC and AI clusters**"（[beegfs.io](https://www.beegfs.io)），仅 POSIX 文件接口，per-op 路径最短化。
- 差异源于**设计目标不同**：Ceph 追求"一套系统覆盖所有存储需求"，BeeGFS 追求"并行 I/O 极致性能"。

### 1.6 JuiceFS 仍有调优意义的理由

虽然 BeeGFS 全面领先，但**BeeGFS 仅有 Replication 一种冗余方式，空间利用率低（3× 副本）**；而 **Ceph EC4+2 空间利用率 = 1.5×**，对大规模存储有显著成本优势。因此 **JuiceFS+EC 调优仍有价值**——目标是将 JuiceFS+EC 从当前 2404（后端 56%）提升，缩小与后端裸能力（~4300）的差距。

---

## 二、当前瓶颈全景图

### 2.1 四客户端栈同后端对照矩阵（01-5 §5.4）

| 客户端栈 | randread (MiB/s) | FUSE | Go | TiKV | 达标 6250 |
|----------|:-:|:-:|:-:|:-:|:-:|
| kernel CephFS+Rep（01-4 集群）| 6718 | ❌ | ❌ | ❌ | **✅** |
| kernel CephFS+EC（01-4）| 4608 | ❌ | ❌ | ❌ | ❌ |
| kernel CephFS（本集群 01-5）| 4972 | ❌ | ❌ | ❌ | ❌ |
| ceph-fuse（C++）| 2884 | ✅ | ❌ | ❌ | ❌ |
| JuiceFS+Rep | 2969 | ✅ | ✅ | ✅ | ❌ |
| JuiceFS+EC（01-2d）| 2404 | ✅ | ✅ | ✅ | ❌ |
| rados bench+EC（librados）| 4221 | ❌ | ❌ | ❌ | ❌ |
| BeeGFS（不同后端）| 9045 | ❌ | ❌ | n/a | **✅** |

### 2.2 瓶颈链路图

```
磁盘硬件 ──────── 9+ GB/s（BeeGFS 9045 实测）──────── 非瓶颈 ✅
     │
     ▼
Ceph OSD 软件栈 ── EC 路径 ~4300（IOPS 放大，%util=100%）── ② 瓶颈（A 线目标）
     │              Rep 路径 ~4300（非瓶颈，CephFS+Rep 6718 ✅）
     ▼
FUSE 用户态 ────── -42%（ceph-fuse 直接证据）────────── ③ JuiceFS 主瓶颈（B 线目标）
     │              slat 729μs → 11092μs（15×）
     ▼
JuiceFS 客户端 ─── 2404（EC）/ 2969（Rep）= 后端 56% ── 当前生产值
     │
     ▼
验收线 6250 ────── ❌ 当前所有 JuiceFS 配置均不达标
```

### 2.3 01 阶段遗留的开放问题

1. **cluster_network 修复后性能反降**：02-1 Z1 已确认 cluster_network 修复生效（cluster NIC 7.8GB 流量）。01-5 的"反降"需在 cluster_network=10.3.2.0/24 下重新跑 rados bench 确认（A1 待执行）。
2. **CephFS+Rep 本集群 5359 vs 01-4 集群 6718**：02-1 Z3 复测中位 5359，未复现 6718。差距 20% 缩窄至原 35%，剩余归因集群状态差异。待作为独立全量基线任务（02-2）深入排查。
3. **01-3 多实例亚线性**：N4 ra0=5013=单进程 1.74×（亚线性），当时可能受后端裸能力上限压制；**后端裸能力提升后需复测**，可能恢复线性。
4. **6 核封顶根因（01-4 §5.4）**：已定位为反馈平衡点（IOPS 被延迟反馈环封顶 → per-I/O CPU 仅 0.4% → 固定开销占 91%），但**未验证是否有可松动的调优点**。
5. **randwrite-ow 不限速轮间波动 50-100%**（01-2d 唯一未结项）：A=2004~3015、B=1410~2847；v2 诊断数据（OSD delta/PG/iostat/jfs-stats）已采集待分析；限速口径 0% 波动形成反常对照。

---

## 三、02 阶段目标与验收

### 3.1 总目标

| 维度 | 01 阶段终态 | 02 阶段目标 |
|------|------------|------------|
| 后端裸能力（rados bench EC randread） | ~4300 | **≥5000**（逼近 6250） |
| CephFS+EC（内核态）| 4608-4972 | **≥5500** |
| CephFS+Rep（内核态）| 4972-6718 | **≥6250 ✅ 达标** |
| JuiceFS+EC randread | 2404（后端 56%）| **≥3500**（后端 70%+） |
| JuiceFS+Rep randread | 2969 | **≥4000** |
| 多实例可扩展性 | N4=5013（1.74×，亚线性）| 后端提升后复测，验证是否恢复线性 |

### 3.2 验收标准

- **达标线**：不限速 100GbE 下有效带宽 ≥ 网卡 50%（6250 MiB/s）。
- **口径**：256K block，单客户端，冷态 cache=0，`--openfiles=128`，§8.3 稳态中位数（截开头 1/4）。
- **双口径约定**：default + ra0 均测，分析以 ra0 为主（随机项 ra0 全面占优，01-2c 后已确认）。

### 3.3 红线（不可触碰）

- 不重启节点、不动 157 内核/100GbE NIC/md0/WekaIO。
- 不破坏生产 EC4+2 池（调优用独立池或临时切换）。
- cephx_sign_messages=false 仅在诊断池测试，不擅自应用到生产（安全权衡由用户拍板）。

---

## 四、主线 A：后端裸能力提升

> 目标：将 Ceph EC4+2 后端裸能力从 ~4300 提升到 ≥5000，逼近 6250 验收线。
> 逻辑：01-5 已确认磁盘非瓶颈（BeeGFS 同硬件 9045）、EC 瓶颈在 Ceph OSD 软件栈（IOPS 放大 + per-op 开销），故 A 线聚焦**削减 Ceph 软件栈 per-op 开销** + **修复 cluster_network**。

### A1：cluster_network 修复 + rados bench 复测（门槛低）

**前置检查（已完成）**：cluster_network 配置/监听/流量三层验证
- `ceph config get osd cluster_network` = `10.3.2.0/24` ✅
- OSD `back_addr` 在 cluster 网段 ✅
- EC randread 期间 cluster NIC 有 7.8GB RX + 5.8GB TX ✅
- 结论：cluster_network 修复已生效。

**背景**：01-5 发现 cluster_network 配置未生效（EC subop 全走 public NIC），已修复为 10.3.2.0/24。

**执行**：
1. 跑 rados bench EC4+2 randread（-t128 / -t4096，REPEAT=3）。
2. 对比 01-5 修复前数据，判断 cluster_network 修复的净收益。

**判定**：
- 修复后 ≥ 修复前（4300）→ cluster_network 修复有效，纳入生产。
- 仍 < 修复前 → cluster_network 修复无益，回滚。

**状态**：⏳ 待执行。

### A2：Ceph OSD 软件开销削减（核心，代码级定向）

**背景**：01-5 §十二 已从 Ceph 源码定位 per-op 开销来源，最大的可消除项 = **cephx AES（40-100μs/op，`CephxSessionHandler.cc:156`）**。

**假设**：cephx_sign_messages=true（默认）对每条 message 做 4 次 AES 运算（sign + verify × 2 方向），在 HPC/AI 内网可信环境下无安全价值却有显著性能代价。关闭后每 op 省 40-100μs，对 256K randread（当前 ~4300 IOPS-equivalent）可提升 5-15%。

**执行**（在诊断池或维护窗口，**需用户拍板安全权衡**）：
1. **A2.1 cephx 分级测试**（来源：外部建议深化）：
   - cephx 有三个层次：① `cephx_require_signatures`（认证级）② `cephx_sign_messages`（每条消息签名）③ `cephx_cluster_sign_messages`（OSD 间消息签名）。
   - **第一步**：只关 `cephx_cluster_sign_messages=false`（仅影响 OSD 间 EC subop，对 client 透明），测 EC subop 路径的签名开销。
   - **第二步**：再关全局 `cephx_sign_messages=false`，测总收益。
   - 量化两者占比，给用户**分级别**的拍板依据（"只关 cluster 不影响 client 是否可接受"）。
   - **安全评估**：内网可信环境下 cephx 主要防中间人篡改，关签名不关认证（cephx 仍认证连接身份）。
2. **A2.2 osd_memory_target + BlueStore cache 深度调优**（来源：外部建议深化）：
   - 当前每节点 **1TB RAM**，但 OSD 默认 `osd_memory_target` 仅 ~4GB → **96% 内存未用**。EC 路径每 op 查 4 次 RocksDB（每 shard 一次 onode + extent），cache 命中率直接影响 per-op 延迟。
   - `ceph config set osd osd_memory_target 17179869184`（**16GB**，1TB RAM 充足）。
   - `ceph config set osd bluestore_cache_kv_ratio 0.6`（默认 0.25 → 0.6，比原计划 0.5 更激进）。
   - `ceph config set osd bluestore_cache_meta_ratio 0.8`（默认 0.5 → 0.8，元数据缓存）。
   - 复测 rados bench EC randread，对比 RocksDB cache hit rate 变化。
3. **A2.3 OSD 线程模型 + Messenger 层调优**（来源：外部建议深化）：
   - `ceph config set osd osd_op_num_shards 10`（默认 5，增加 shard 数减少锁争用）。
   - `ceph config set osd osd_op_threads 32`（默认 16）。
   - `ceph config set osd ms_async_op_threads 8`（默认 3，100GbE epoll 线程数）。
   - `ceph config set osd osd_client_message_cap 300`（默认 100，128×128=16384 并发可能触发限流）。
   - 验证是否减少 ShardedOpWQ 队列等待（20-40μs/op 部分）。
   - 注意：可能加重 CPU 争用，需监控。

**判定**：
- A2.1 关 cephx 后 rados bench ≥ +10% → 确认 cephx 是主要可消除开销，建议生产应用（用户拍板）。
- A2.1 无增益 → cephx AES 非 per-op 主导开销（可能 JIT/缓存命中），回滚、聚焦其他方向。
- A2.2/A2.3 有增益 → 叠加应用。

**状态**：⏳ 待 A1 完成后执行（避免变量混淆）。

### A3：磁盘/OSD 扩容评估（可选，成本高）

**背景**：当前 3 节点 × 2 OSD = 6 OSD，EC4+2。01-5 确认 EC per-OSD 仅 290 MB/s = 磁盘能力 19%（磁盘未饱和），故**扩容 OSD 不直接解决 EC IOPS 放大问题**，但可增加并行度。

**假设**：增加 OSD 数量 → 增加 PG 并行度 → EC 读可并行更多 shard → 缓解 IOPS 放大。

**执行**（仅当 A1/A2 收益不足时）：
1. 评估当前 NVMe 盘是否有空闲槽位（150-152 各 2 NVMe 已用，可能需加盘）。
2. 若可加盘：每节点加 1-2 NVMe → 9-12 OSD → 重新 crush + rebalance。
3. 复测 rados bench + CephFS randread。

**判定**：
- 扩容后线性提升 → 并行度不足是次级瓶颈。
- 扩容后非线性（per-OSD 反降）→ EC IOPS 放大是架构固有，扩容无益。

**状态**：⏳ 可选，低优先级（成本高、收益不确定）。

### A4：EC stripe 配置调优（可选）

**背景**：当前 EC4+2 failure-domain=osd，256K block。EC 读路径 256K → 4×64K chunks（IOPS 放大 4×）。01-5 §十二 确认这是 EC 瓶颈本质。

> **前置检查（已完成）**：EC pool fast_read 开关
> - fast_read=true 消除轮间波动（19%→2%），但中位数无显著提升（+0.5%）
> - 结论：稳定性强但无吞吐收益，保持 false（默认）

**可探索项**：
1. **A4.1 JuiceFS chunk/block vs EC stripe 三层对齐检查**（来源：外部建议新增）：
   - 检查 JuiceFS block size（默认 4M?）→ Ceph object → EC stripe_unit 的对齐关系。
   - `ceph osd pool get juicefs-data stripe_unit` + `juicefs status <vol>`。
   - 注意：block 越大 → EC object 越大 → IOPS 放大可能越严重（4M block → 4×1M shard read）。
2. EC k=6 m=2（更多 data chunks，但需更多 OSD）。
3. EC stripe size 调整（当前默认，可试 1M stripe 减少 per-op 放大）。
4. **不推荐**改回 Rep3（违背 EC 空间效率目标，01-5 已确认 RADOS 层 Rep 无显著优势）。

**状态**：⏳ 可选，数学约束大，预期收益低。

---

## 五、主线 B：JuiceFS 层级调优（FUSE 瓶颈缓解）

> 目标：将 JuiceFS+EC 从 2404（后端 56%）提升到 ≥3500（后端 70%+），缩小与后端裸能力的差距。
> 逻辑：01-4 §5.4 + 01-5 §十一 已确认 FUSE 是 JuiceFS 主瓶颈（dispatch 延迟 5+ms/op → IOPS 反馈封顶 ~11.6K → CPU 封顶 ~6 核）。B 线聚焦**削减 FUSE dispatch 延迟** + **JuiceFS 内部参数** + **多实例复测**。

### B1：FUSE dispatch 延迟削减（已完成，结论更新）

> **前置检查（已完成）**：max_read = 128K（JuiceFS 默认 `--max-fuse-io 128K`）
> - 256K I/O 被拆成 2 × 128K dispatch，slat 翻倍
> - 修正为 1M 后 randread +25%，FUSE 税从 39% 降到 24%
> - 但 max-fuse-io > 128K 导致写劣化（根因：buffer 压力检查 sleep，详见 02-1 报告 §九-十）
> - **当前最优配置**：`--max-fuse-io 256K --buffer-size 1024`（读 +16%，写 +70%，详见 02-1b 报告）

**背景**：01-4 §5.4.4 排除了 go-fuse `maxMaxReaders=4`，根因是 FUSE dispatch 路径本身的长延迟。但通过 Z4 发现 max_read=128K 拆包是主要因素，修正后 FUSE 税大幅降低。

**后续方向**：
- B1a writeback_cache：**降级**（FUSE 税已从 39% 降到 24-27%，边际收益变小）
- B1b io_uring FUSE：**排除**（内核 5.15 < 6.1，不可用）
- B1c splice：低优先级

### B2：JuiceFS 内部参数调优

**背景**：01-3 已测 max-uploads 对 randread 无益（-2~-5%，控写不控读）。但 JuiceFS 仍有未试参数。

> **前置检查（已完成）**：objecter_inflight_op_bytes 限流核查
> - objecter_inflight_op_bytes=100MB（默认），调大到 1GB 后 BW 仅 +3%、slat -3%（噪声范围）
> - 结论：非瓶颈，不再追踪

**执行**：
1. **B2.1 max_background**：当前 50（`fuse.go:469`），试 100/200，看是否增加 FUSE 后台请求处理并发。**注意**：这是 go-fuse 用户态参数，与内核 `/sys/fs/fuse/connections/*/max_background`（Z4 检查项）是不同变量，需同时调。
2. **B2.2 buffer-size / chunk size**：检查当前配置，尝试加大读 buffer。
3. **B2.3 metadata cache**：检查 meta cache 配置，减少 TiKV 往返（01-2 已确认 meta lat 0.25ms 不吃时间，但加大 cache 可进一步降低）。
4. **B2.4 JuiceFS 连接/IOContext 架构核查**（来源：外部建议新增）：检查 JuiceFS cgo 调用 librados 时是否复用单一 rados 连接/IOContext 处理全部 128 并发请求——若单连接，所有请求排队在同一 librados session 内部队列。
5. **B2.5 cgo 优化**：检查 JuiceFS 编译选项（cgo overhead 在 01-4 pprof 中占 ~2c 固定开销，但 01-5 已确认 Go/cgo 非主瓶颈，低优先级）。

**判定**（⚑ 2026-08-06 更新，原"≥+10% 有效 / <5% 无效"作废）：
- 按 §11.1 **逐项分辨力**判定，不再用统一阈值。效应量须同时满足：≥该项可检出效应量、且 ≥2× 本次实验的 A↔A' 漂移底噪。
- 落在噪声内即结论"无收益"，**不得写成"略有提升"**。
- 执行方式受 §11.4 约束（挂载参数需 remount ⇒ 会重抽档位，同实例配对做不到）。⚑ **2026-08-07：路线已收敛** —— 首选路线①（在线可切旋钮，03-3 已验证走通）；路线②保留但**必须 A/B 交错**；路线③探针归一化**已否证作废**。
- ⚑ **判据集**：`seqread` 已移出（底噪门槛 7.78% > 可检出 4.0%，无判别力）；`mseqread` 1.5% / `randread` 3.0%。写侧四项门槛待 03-4 产出。详见 §11.4.4。

**状态**：⏸ 待授权具体旋钮清单（路线已定，见 §11.4.5），方法见 `skills/TUNING-SKILL.md`。

### B3：多实例可扩展性复测（后端提升后回看）

**背景**：01-3 测得 N4 ra0=5013=单进程 1.74×（亚线性），当时后端裸 ~4300 可能是上限。**A 线提升后端后，多实例可能恢复线性**。

**假设**：后端提升到 ≥5000 后，多实例 N4 可达 6000+（线性倍增），逼近 6250 验收线。

**执行**（A 线完成后）：
1. 后端提升后（A1/A2 见效），复测 JuiceFS 多实例 N1/N2/N4。
2. 验证是否从亚线性（1.74×）恢复到线性（~3.5×）。
3. 若线性恢复 → 多实例是受后端压制的假亚线性，**但业务要求单挂载点**（01-3 用户否决多挂载）→ 仅作诊断，不作生产方案。
4. 若仍亚线性 → 单进程 FUSE 封顶是架构固有，确认 01-4 §5.4 结论。

**判定**：
- 线性恢复 → 后端是亚线性根因，记录但不用多挂载（业务约束）。
- 仍亚线性 → FUSE 单进程封顶坐实，B 线天花板确认。

**状态**：⏳ 待 A 线完成后执行。

### B4：io_uring FUSE / kernel mount 评估（可选，高风险高收益）

> **更新**：外部建议指出 io_uring FUSE 比 jfs.ko kernel mount 更安全（仍走 FUSE ABI，不需要新内核模块）。应**优先于 jfs.ko 评估**。

**背景**：01-5 已证明 kernel CephFS（无 FUSE）比 ceph-fuse 快 42%。若能绕过 FUSE dispatch 延迟，预期接近后端裸能力。

**执行**（仅当 B1/B2/B3 收益不足时）：
1. **B4a io_uring FUSE**（优先）：若 157 内核 ≥ 6.1 + JuiceFS 社区有 io_uring 分支 → 评估编译/启用可行性。io_uring 绕过传统 /dev/fuse read/write 模型，风险远低于内核模块加载。
2. **B4b JuiceFS kernel mount（jfs.ko）**（备选）：若 io_uring 不可行，检查 JuiceFS 是否提供 kernel mount 模块。在测试环境试挂载，复测 randread。
3. **红线**：不在 157 生产内核加载实验模块（可能影响内核稳定性）。

**判定**：
- io_uring FUSE 可用且 randread ≥ 4000 → 换底层通道，评估生产应用。
- kernel mount 可用且稳定 → 换 mount 方式。
- 均不可用 → 放弃，接受 JuiceFS FUSE 42% 税。

**状态**：⏳ 可选，先评估 io_uring（B1b 已检查内核版本），再考虑 jfs.ko。

---

## 六、C 线：操作系统/网络层调优（来源：外部建议新增）

> 目标：消除 OS/网络层的隐藏瓶颈，为 A/B 线提供干净的基础设施底座。
> 来源：`/tmp/minimax-m3-02-stage-tuning-recommendations.md` §五 + `/tmp/opencode-02-stage-tuning-suggestions.md` 方向3/4/5/9 + `/tmp/02-stage-optimization-suggestions.md` §2.4。

### C1：NVMe 队列参数【P2】

01-5 §四.2 实测 EC per-OSD %util=100%，已到 IOPS 上限。NVMe 队列参数可能影响实际 IOPS 能力。

| 参数 | 当前推测 | 建议 | 文件 |
|------|---------|------|------|
| scheduler | `none` 或 `mq-deadline` | `none` | `/sys/block/nvme*/queue/scheduler` |
| nr_requests | 默认 1024 | 4096 | `/sys/block/nvme*/queue/nr_requests` |
| read_ahead_kb | 默认 256-512 | **0**（随机读场景） | `/sys/block/nvme*/queue/read_ahead_kb` |
| nomerges | 0 | 2 | `/sys/block/nvme*/queue/nomerges` |
| rq_affinity | 1 | 2 | `/sys/block/nvme*/queue/rq_affinity` |

```bash
for dev in nvme2n1 nvme3n1; do
  echo none > /sys/block/$dev/queue/scheduler
  echo 4096 > /sys/block/$dev/queue/nr_requests
  echo 0 > /sys/block/$dev/queue/read_ahead_kb
done
```

### C2：NIC IRQ 亲和性 + NUMA【P2】

100GbE NIC 中断可能与 OSD 线程争抢同一 CPU 核心。

| 调优项 | 检查 | 调优 |
|--------|------|------|
| NIC IRQ 分布 | `cat /proc/interrupts \| grep enp139` | 分散到与 OSD 不同的核 |
| OSD CPU pinning | `taskset -p <osd_pid>` | 绑 NUMA node |
| NUMA 拓扑 | `numactl --hardware` | NIC 必须在 OSD 同 node |
| CPU governor | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | `performance` |
| IRQ coalescing | `ethtool -c enp139s0f0np0` | `rx-usecs` 减小 |

**红线**：slave（150-152）可动，**157 不可动**（WekaIO 红线）。

### C3：MTU 4200 → 9000【P2】

当前 MTU=4200（非标准值）。256K 响应在 MTU 4200 下需 60 个 packet，MTU 9000 下仅 28 个。

- **前置**：确认交换机全线支持 jumbo frame（9000 MTU）。**若有任一环节不支持 → 立刻分片，性能反而下降**。
- 需 IT/网络组确认后执行。

### C4：TCP 拥塞控制 / busy_poll【P3】

`tune-servers.sh` 已调大 TCP buffer，但未指定拥塞控制算法：

```bash
sysctl net.ipv4.tcp_congestion_control  # 默认 cubic
# 建议（数据中心内部）
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.busy_read=50
sysctl -w net.core.busy_poll=50
```

注意：busy_poll 会持续占用 CPU，需评估 idle CPU 占用。

---

## 七、D 线：测试方法论补充（来源：外部建议新增）

> 来源：`/tmp/02-stage-optimization-suggestions.md` §四 + `/tmp/minimax-m3-02-stage-tuning-recommendations.md` §六 + `/tmp/opencode-02阶段调优补充建议.md` N2。

### D1：randwrite-ow 波动数据分析【P2 — 零成本纯分析】

01-2d 唯一未结项：不限速 randwrite-ow 轮间波动 50-100%（A=2004~3015、B=1410~2847）。**v2 诊断数据已采集**（`results/prod-01-2d-fullretest-20260717/diagnosis/randwrite-ow-jitter{,-v2}/`），只差分析。

**分析方向**：
1. 逐秒 OSD delta / PG / iostat / jfs-stats 时序对齐。
2. 检查是否同样是"脏 pool RocksDB compaction"模式（EC overwrite 是 RMW 路径，比 randwrite-true 更可能触发 compaction）。
3. **限速口径 0% 波动**的反常对照：若波动只在不限速高吞吐下出现，说明和"高并发瞬时打满某资源"相关，而非纯 compaction 周期性。
4. 结合 `dmesg` 检查 NIC/PCIe reset、NVMe 热保护。

### D2：大 block-size（1M/4M）基线【P2】

01 阶段全程 256K block。对 AI/HPC 主流场景（checkpoint、模型权重、训练数据 shard），1M 甚至 4M 可能更贴合实际。

| 块大小 | EC chunk size | IOPS 放大 | 业务场景 |
|--------|---------------|-----------|---------|
| 256K | 64K | 4× (64K→4 ops) | 01 阶段已测 |
| 1M | 256K | 4× (单 IOPS 数据量 16×) | 大文件 AI 数据 |
| 4M | 1M | 4× (单 IOPS 数据量 64×) | checkpoint |

**预期**：1M block 下 rados bench randread 可能突破 4400（每 IOPS 数据量增加，per-IOPS 开销摊薄）。**可能给出"不改代码就达标"的路径**。

### D3：细粒度并发扫描（64-192）【P3 — 可并入 B3】

01-3 只在几个跳档（32/128/16384）之间对比。建议在 N=64~192 之间做更细的扫描，可能存在比 128 更优的并发甜点。可合并进 B3 多实例复测的同一批测试。

---

## 八、执行顺序与决策树

```
A1 cluster_network 修复 + rados bench 复测 ─── 前置已确认（Z1 已生效）
     │
     ├─ 有效（≥4300）→ 纳入生产，继续 A2
     └─ 无益 → 回滚，跳到 A2
          │
          ▼
A2 Ceph OSD 软件开销削减 ──────────── 核心攻坚
     │
     ├─ A2.1 cephx 分级测试（cluster-only → global）有效 → 用户拍板
     ├─ A2.2 osd_memory_target 16GB + BlueStore cache 有效 → 叠加
     ├─ A2.3 Messenger/线程模型 有效 → 叠加
     └─ 全部无效 → 后端 EC 软件栈无松动空间
          │
          ▼
B1 FUSE dispatch 延迟削减 ──────────── 与 A 线并行（Z4 结果决定方向）
     │
     ├─ B1a writeback_cache 有效 → 纳入
     ├─ B1b go-fuse 版本/io_uring 调研 → 评估替代路径
     └─ 全部无效 → FUSE dispatch 是架构固有
          │
          ▼
B2 JuiceFS 内部参数 ────────────────── 与 B1 并行
     │
     ├─ 任一有效 → 纳入
     └─ 全部无效 → JuiceFS 内部无松动空间
          │
          ▼
[C 线 OS/网络层调优（可并行）] ──── NVMe 队列 / IRQ 亲和 / MTU / TCP
     │
     ▼
[A 线 + B 线 + C 线叠加后复测]
     │
     ├─ JuiceFS+EC ≥ 3500（后端 70%）→ 调优成功，记录最优配置
     ├─ 3500 > JuiceFS+EC ≥ 2800 → 部分成功，评估是否够用
     └─ JuiceFS+EC < 2800 → FUSE 税不可削减，接受现状或换方案
          │
          ▼
B3 多实例复测（后端提升后）────────── 验证 01-3 亚线性是否为后端压制
     │
     ├─ 线性恢复 → 后端是根因（但业务要单挂载，仅诊断）
     └─ 仍亚线性 → FUSE 单进程封顶坐实
          │
          ▼
[D 线 测试方法论补充] ──── randwrite-ow 分析 / 大 block 基线 / 细粒度扫描
     │
     ▼
[可选] B4 io_uring FUSE / kernel mount ── 仅当 B1-B3 收益不足
     │
     └─ 可用且稳定 → 换底层通道，绕过 FUSE
```

### 8.1 优先级排序

| 优先级 | 任务 | 预期收益 | 成本 | 风险 |
|:---:|------|---------|------|------|
| **P0** | A1 cluster_network 修复 + rados bench 复测 | 高（确认修复净收益） | 极低 | 0 |
| **P1** | A2.1 cephx 分级测试 | 高（5-15%，最大可消除项） | 低（配置改） | 中（安全权衡） |
| **P1** | A2.2 osd_memory_target 16GB + cache | 高（EC 4× RocksDB 查） | 低（配置改） | 低 |
| **P1** | B1 FUSE 调优（⚑ 结论存疑，02-2 重验中） | ~~已确认：max-fuse-io 256K + buf1024 读写都受益~~ 收益基于漂移基线（02-1b 写 683↔1760 差 2.6×），**待 02-2 P1 锁定收敛基线后 P3 重扫复核** | 低 | — |
| **P2** | A2.3 Messenger/线程模型 | 中 | 低（配置改） | 中 |
| **P2** | B2 JuiceFS 内部参数 | 中（objecter 已排除） | 低 | 低 |
| **P2** | C1 NVMe 队列参数 | 中（EC %util=100%） | 极低 | 低 |
| **P2** | C2 NIC IRQ 亲和性 | 中 | 低 | 低（slave only） |
| **P2** | C3 MTU 4200→9000 | 中 | 中（需确认交换机） | 中 |
| **P2** | D1 randwrite-ow 波动数据分析 | 中（补齐唯一未结项） | 极低（纯分析） | 0 |
| **P2** | D2 大 block-size（1M/4M）基线 | 高（可能不改代码就近达标） | 中 | 低 |
| **P3** | B3 多实例复测 | 诊断价值 | 低 | 低 |
| **P3** | C4 TCP BBR / busy_poll | 低-中 | 低 | 低 |
| **P4** | A3 OSD 扩容 | 不确定 | 高（加盘） | 中 |
| **P4** | B4 io_uring FUSE / kernel mount | 高 | 高 | 高 |
| **P5** | A4 EC stripe 调优 | 低（数学约束） | 中 | 中 |

---

## 九、口径与红线

### 9.1 测试口径（继承 01 阶段）

- **达标线**：不限速 100GbE 下有效带宽 ≥ 6250 MiB/s（网卡 50%）。
- **统计口径**：fio bw_log 稳态中位数（截开头 1/4），不认 fio 平均。
- **block size**：256K（与 EC stripe_width 对齐）。
- **冷态**：cache=0，无 writeback。
- **OSD 缓存**：对比性测试（不同配置 A/B 对照）前重启所有 OSD 清缓存；生产模拟测试可不清。
- **openfiles**：128（=numjobs，避免 01 阶段假瓶颈）。
- **readahead 口径（已定，用户拍板）**：**统一单组 ra0（`--max-readahead 0`）**，不再 default + ra0 双测。依据：生产只能用一种挂载配置，AI 训推稳态热点（shuffle 随机读 + checkpoint 并发写）ra0 全面占优；default 唯一强项（顺序大文件读）属冷启动一次性开销，已在 `doc/perf-report/00-baseline-20260722.md` 的 A/B 全量对照中作"已知代价"固化，后续不再每轮双测（省约 1/3 全量测试时间）。仅当新增负载确含高频顺序大文件读时才回补 default 单项。
- **REPEAT**：≥3 轮取中位数，CV < 5%。
- ⚑ **A/B 交错（2026-08-07 新增，P0）**：任何 A/B 对照**一律按 `A B A B A B` 交错采集，禁止分臂串行**（A 臂跑完再跑 B 臂）。依据：同实例日间 4.5h 时序漂移 1.72%，分臂串行会把漂移整体记成臂间差异；交错抵消率 ≈87%。详见 §11.4.2。
- ⚑ **randrw 双口径必标（2026-08-07 新增）**：`FULLBASELINE_V4.sh` 输出**读侧**（签收值 1215），部分调试脚本输出**读写合计**（2430）。**报数必须显式标注口径**，否则对外会被看成掉 50%。详见 §11.2 第 1 条。
- ⚑ **实例同一性硬判据**：`pid` + `starttime_ticks` 不变，**不是带宽值落在某个区间**。带宽区间在长跑中必然误报（日间 4.5h 就能跌 1.72%）。

### 9.2 红线（不可触碰）

1. 不重启节点、不动 157 内核/100GbE NIC/md0/WekaIO。
2. 不破坏生产 EC4+2 池（调优用独立池或维护窗口）。
3. cephx_sign_messages=false 等**安全相关配置变更需用户拍板**，不在 AI 助手权限内擅自应用生产。
4. B4 JuiceFS kernel mount **不在 157 生产内核加载实验模块**。
5. 所有 OSD 配置变更前做 `ceph osd dump` 快照，可回滚。

### 9.3 文档约定

- 调优任务书：`doc/perf-tasks/02-XX-*.md`（与 01 阶段任务书并列）。
- 调优报告：`doc/perf-report/02-XX-*-report.md`。
- 数据归档：`results/prod-02-XX-*-<timestamp>/`。
- 本计划文档随执行进度更新结论（与 01 计划文档同模式）。

---

## 十、待用户拍板的开放问题

1. **cephx_sign_messages=false 是否可在生产应用**：内网可信环境下安全风险低，但需用户权衡（cephx 防中间人篡改，关签名不关认证）。A2.1 分级测试可提供更细的决策依据。
2. ~~**调优基线口径**：01-2c 后已倾向 ra0（随机项全面占优），但顺序项 default 仍占优。**是否正式将调优分析基线定为 ra0**？~~ ⚑ **已拍板（2026-07-22）：正式定为单组 ra0**。理由：生产只能用一种挂载配置，AI 训推稳态热点（shuffle 随机读 + checkpoint 写）ra0 全面占优；default 顺序读强项属冷启动一次性开销，仅在 `00-baseline-20260722.md` 作已知代价一次性记录。后续全量测试不再双测 default（见 §9.1）。
3. **A3 OSD 扩容是否纳入预算**：若 A1/A2 收益不足，加盘是最后手段。
4. **io_uring FUSE / kernel mount 是否值得评估**：B4 先评估 io_uring（更安全），再考虑 jfs.ko。
5. **验收线是否调整**：若 02 阶段后端+JuiceFS 调优仍不达标，是否接受"JuiceFS+EC 后端 70%（~3500）"作为 EC 空间效率下的合理上限？
6. **MTU 9000 是否能确认交换机支持**（C3 前置）：需 IT/网络组答复。
7. **157 client 是否允许在 sysctl 层做 TCP/IRQ 调优**（C2/C4）：sysctl 改动不涉及内核模块加载——是否可放宽 157 红线？

---

## 十一、基线签收状态与遗留动作（2026-08-06 更新）

> 来源：`report/基线测试报告-JuiceFS-E6-20260806.md`（W2 全量基线，3 次 × 7 项 × 5 轮）
> 方法与陷阱：`skills/FULLBASELINE-SKILL.md`；调优方法：`skills/TUNING-SKILL.md`

### 11.1 基线已签收，B 线调优可开工

| 测试项 | 基线值 (MiB/s) | 状态 | **可检出效应量** |
|---|---|---|---|
| randread | 1880 | ✅ 正式签收 | **≥3%** |
| mseqread | 4160 | ✅ 正式签收 | **≥1.5%** |
| randrw | 1215 读侧 / 2430 合计 | ✅ 正式签收 | **≥3%** |
| seqread | 1290 | ⚠ 条件签收 | ~~≥4%~~ → 🔴 **实际 7.78%，已移出判据集**（见 §11.4.4） |
| seqwrite | 1400 | ⚠ 条件签收 | ≥5% |
| mseqwrite | 4800 | ⚠ 条件签收 | ≥7% |
| randwrite | ≈2860 | ⚑ 暂签（剔首轮达标） | ≥4% |

⚑ **2026-08-07 补**：上表只是"重复性分辨力"，**不等于 A/B 判定门槛**。真实门槛还要取 `max(可检出效应量, 2× 同实例漂移底噪)`，代入 03-2 实测底噪后 **seqread 被移出判据集**、mseqread/randread 门槛维持 1.5%/3.0% —— 详见 **§11.4.4**。写侧四项底噪尚未采集（03-4 进行中）。

**"可检出效应量"是调优排期的硬约束**：§五 B2 各子项的判定线（原写"≥+10% 有效 / <5% 无效"）须按此表逐项收紧或放宽 —— 例如 mseqwrite 分辨力只有 ≥7%，对该项声称的 5% 收益不可采信；而 mseqread 可检出 1.5%，判定线定在 10% 会漏掉真实收益。

### 11.2 口径更新（影响所有历史对比）

1. **randrw 双口径**：`FULLBASELINE_V4.sh` 输出**读侧**（1215），`debug/mount-gear-attrib-test.sh` 与 `r5chk.py` 输出**读写合计**（2430），相差 2 倍但是同一性能（原始日志实测 read 1205 + write 1204 = 2408）。**所有报数必须标口径。** §9.1 测试口径已隐含此坑，需显式补一条。
2. **首轮规则**：`randrw` / `randwrite` 每轮后都做 `juicefs gc --compact`，首轮跑在"刚回收完的干净池"上，`randwrite` 首轮系统性偏高。**规则：首轮单独记录、不进 L2 统计，两项口径必须一致。**
3. **门控前置**：性能档位属于 JuiceFS 挂载实例（同实例 ≤1.1%，跨实例极差 29.9%）。**任何 A/B 对比前必须先做探针门控并固定实例**，否则测的是抽签分布。
   ⚑ **2026-08-07 限定（03-1 否证）**：探针门控**只能**用于确认实例同一性（硬判据 **pid + starttime_ticks**，不是带宽值）、实例健康、randread 自身在高档；**不能**用探针值筛选"其它项也是高档"的实例（传导增益仅 0.221）。详见 **§11.4.3**。
4. ⚑ **A/B 一律交错（2026-08-07 新增，P0）**：禁止分臂串行。日间 4.5h 内时序漂移达 **1.72%**（已超 mseqread 可检出效应量 1.5%），`A B A B A B` 交错可抵消 **≈87%**。两臂须落在同一时段窗口内，跨时段历史值不可直接相减。详见 **§11.4.2**。

### 11.3 遗留动作

| # | 动作 | 优先级 | 依赖/说明 |
|---|---|---|---|
| 1 | ~~W2 数据从 157 归档~~ | ~~高~~ | ✅ **已完成并复核（2026-08-07）**。⚑ 实际路径不是原计划的 `results/E6/...`，而是 **`results/stability-raw/week3-20260803-0806/opencode-fullbaseline-v4/`**（含 `W2P1/W2P2/W2P3`）。完整性已逐目录核对：归档 2545 文件 = 157 侧 2545 文件，三份全对 |
| 2 | 修正历史文档中 randrw 口径标注（`02-2h-e6-v4-fullbaseline-20260803.md` §12.10 / §18.6.4、`周报-...-20260802.md` §三 现写 2400） | **高** | 对外会被看成掉 50% |
| 3 | 把"首轮规则"写进 `02-2h-e6-v4-fullbaseline-20260803.md` §十二 判据章 | 高 | — |
| 4 | 用 `*_bw.*.log` 重算 W2P2 / W2P3 逐轮逐秒均值（执行方只回报了 median 与 range，剔首轮复算目前基于 fio 汇总口径） | 高 | ⚑ **依赖已解除**：原写"需登 157"，但数据已归档到 WSL（见第 1 项）⇒ **可在本地零成本复算**，且不占用正被 03-4 独占的客户端。⚠ 复算须用**全局 t0** 口径（按每文件 t0 会引入 1.3% 系统性偏差，03-3 已踩过） |
| 5 | randwrite 转正签收（补第 3 个数据点） | 中 | ~~由 B2 基线臂自然产出~~ 🔴 **2026-08-07 更正：不能用 03-4 的数据**。03-4 虽产出 8 run × 5 轮 randwrite，但其对象数运行在 3.78M 拐点**之上**，**绝对值不可用**（只有相对变异性可用）⇒ 转正仍需一个**干净池**上的数据点。仍可由 B2 基线臂产出，但该臂必须保证起点对象数在安全线以下 |
| 6 | mseqwrite 离群机制未定位（分辨力仅 ≥7%） | 中 | 影响写侧调优判定力 |
| 7 | PG 主分布 9:1 倾斜 + straggler（osd.4 延迟 4-5×）已确认存在但未量化贡献 | 低 | pg_num 已冻结 32，属 A 线范畴 |
| 8 | `FULLBASELINE_V4.sh` 中 `drop_caches()` / `compact_cooldown()` / `aggressive_cleanup()` / `mkdir -p ${RESULTS}` 各有两份重复定义（后者生效、函数体一致，当前无害） | 低 | 清理时须重跑 `bash -n` + `fnorder_check.py`。⚑ **03-4 长跑期间不得改动脚本**（会破坏跨 run 一致性）；当前 md5 **`4551ef3c0d405734ea0a4a281427a989`**（含 `obj_gate()`，1373 行） |
| 9 | ⚑ **写侧四项同实例底噪采集**（`randrw`/`seqwrite`/`mseqwrite`/`randwrite`）—— 无此数据则写侧 A/B 没有判定门槛 | **高** | 进行中：`doc/perf-tasks/03-4-write-side-drift-floor.md`，8 run ≈54h，报告节点周一 08:00 |
| 10 | ⚑ `seqread` 转正需 ≥3 个实例且**含日间窗口** | 中 | 03-2 夜间与 03-3 日间结论相反（lag 依赖 +0.091 vs −0.771）⇒ 夜间数据不足以定论 |
| 11 | ⚑ `osd.3` 缺 `osd_mclock_max_capacity_iops_ssd` → 取默认 21500，同伴 OSD 为 63911-79983（差 3 倍） | 中 | 归 03-7（T1.3 / K7）处理 |

### 11.4 B2 执行方式（⚑ 2026-08-07 更新：路线已收敛，不再待拍板）

§五 B2 的 `--max-uploads` / `--buffer-size` 等属**挂载参数**，改动需 remount，而 remount **会重新抽档位**（极差 29.9%）⇒ **同实例 A-B-A 配对做不到**，单次 A/B 比较无效。

#### 11.4.1 三条候选路线的最新裁定

> 依据：`doc/perf-report/03-1-probe-cross-validation-20260806.md`、`03-2-same-instance-drift-floor-20260806.md`、`03-3-t1.0-protocol-selfcheck-20260807.md`

| 路线 | 做法 | 裁定 |
|---|---|---|
| **①** | 找 `ceph config set` 类**在线可切**的等价旋钮 | ✅ **首选，已验证可行**。03-3 用 `osd_mclock_profile` 走通全流程：同实例连续 ~20.8h、零 remount、mseqread 臂间差 0.138%（门槛 1.5%）⇒ 分辨力确实压到了 2-3% 以内 |
| **②** | 每臂 remount 多次，比**分布位移**而非单值 | ⚠ **保留但必须改为 A/B 交错**（原写"每臂 remount 多次"= 分臂串行，已被 03-3 否证，见 11.4.2）；且"探针判档筛高档实例"这一步**基本无效**，见 11.4.3 |
| ~~③~~ | ~~探针归一化~~ | 🔴 **已否证，作废**。03-1 留一法：探针与其余项 **r = −0.1291**、传导增益 **0.221**、SNR 相差 **22 倍** ⇒ 探针值不预测任何其它项，归一化没有可用的传导系数。原表注"仅适用读项"也不成立 |

#### 11.4.2 🔴 分臂串行 → A/B 交错（P0 口径修正）

**原路线②的致命缺陷**：把 A 臂全部跑完再跑 B 臂，则**时序漂移会被整体记成臂间差异**。

03-3 实测（日间 4.5h 窗口，同一实例、同一配置）：

| 量 | 值 |
|---|---|
| 时序漂移（randread 首→末） | 1862.8 → 1830.7，**1.72%** |
| Spearman(run 序, 值) | **−0.771**（单调下行，非随机） |
| 漂移最低点 | 落在午后 14:07-14:52 外部负载峰 |

**1.72% 已经超过 mseqread 的可检出效应量 1.5%** —— 也就是说分臂串行下，什么旋钮都不动也能"测出"一个显著收益。

**A/B 交错的实测效力**（同一份数据）：

| 量 | 值 |
|---|---|
| 交错后臂间残差 | **0.233%** |
| **漂移抵消率** | **≈87%** |
| 6 个 median 排序 | **`B A B A B A` 完全交织**（无分层） |
| mseqread Mann-Whitney | **U = 7 / 9**，不显著（n₁=n₂=3 需 U=0 或 9 才显著） |
| 两项符号 | mseqread **+0.138%** / randread **−0.233%**，**符号相反** ⇒ 纯噪声特征 |

⇒ **所有 A/B 对比一律采用 `A B A B A B` 交错，禁止分臂串行**（含路线②的多次 remount：remount 也要按 `A B A B A B` 交错，不是 `AAA BBB`）。

**⚑ 时段是隐含前提**：03-2 在夜间测得 randread 无 lag 依赖（+0.091），03-3 在日间测得 **−0.771** —— 同一系统、相反结论。因此**底噪与判定门槛都只在采集时段内有效**，A/B 两臂必须落在同一时段窗口内（交错天然满足），跨时段的历史值不可直接相减。

#### 11.4.3 探针门控的能力边界（修正 §11.2 第 3 条）

§11.2 第 3 条"任何 A/B 对比前必须先做探针门控并固定实例"仍然成立，但**必须限定其作用**：

- ✅ **有效**：确认实例同一性（硬判据是 **pid + starttime_ticks**，不是带宽值）、确认实例健康度、确认 randread 自身落在高档带
- 🔴 **无效**：**用探针值筛选"其它项也是高档"的实例**。03-1 已否证（传导增益 0.221），探针高档不蕴含写侧/mseqread 高档
- 成本参考：randread 高档命中率约 **61%**（平均需挂 **1.6** 次才中一个），路线②每臂 ≥3 个高档实例 ⇒ 约需 5 次 remount/臂

**⚑ 探针不是看门狗**：03-3 表明日间 4.5h 内 randread 就能跌 1.72%，最低点 1830.7 距高档带下界 1830 仅剩 0.04% 余量。长跑中把探针当"越界即中止"的看门狗**必然误报**；正确用法是把它当**外部负载协变量**记录下来，中止线放宽到远离常态波动的位置（03-4 取 single-run median < 1700）。

#### 11.4.4 判据集收紧（⚑ 与 §11.1 联动）

B2 判定要求"效应量 ≥ 该项可检出效应量 **且** ≥ 2× 同实例漂移底噪"。代入 03-2 实测底噪（F13）：

| 项 | 同实例底噪 | 2× 底噪 = 漂移门槛 | 可检出效应量 | **实际生效门槛** | 状态 |
|---|---|---|---|---|---|
| mseqread | 0.50%（lag1） | 1.00% | 1.5% | **1.5%** | ✅ 判据集主力 |
| randread | 1.30% | 2.59% | 3.0% | **3.0%** | ✅ 判据集 |
| **seqread** | **3.89%** | **7.78%** | 4.0% | **7.78%** | 🔴 **移出判据集** —— 底噪门槛已超过可检出效应量，该项无判别力 |

**⚑ mseqread 的 lag 依赖**：底噪从 lag1 的 0.50% 涨到 lag8 的 **1.69%**（Spearman **+0.939**）⇒ **A/B 两臂的轮次间隔越大、门槛越高**。交错设计要把同一臂的相邻轮次间隔压到最小，否则 1.5% 的门槛保不住。

#### 11.4.5 仍待拍板

1. `ceph config set` 属改集群配置，**每个旋钮需单独授权**（须含配对的恢复命令）—— 授权哪些？
2. 一次只测一个旋钮（同时改两个，出了差异也归因不了）；测组合前须各自单独测过。是否接受 4 臂（基线 / A / B / A+B）的时间成本？
3. 路线①的在线等价旋钮清单尚未系统排查（03 阶段 T1.1/T1.2/T1.3 = `doc/perf-tasks/03-5/03-6/03-7` 正在推进 K2/K1/K7 三个）。

**读侧旋钮（`--max-readahead` 类）方法学有坑**：需 remount 且**会同时污染门控探针**（探针本身就是 randread），路线③已作废故无法归一化，只能走路线②的交错 remount。若要做，优先找在线读侧旋钮替代。

**⚑ 写侧尚缺底噪**：F13 只测了读侧三项。写侧四项（randrw/seqwrite/mseqwrite/randwrite）的同实例底噪正由 `doc/perf-tasks/03-4-write-side-drift-floor.md` 采集中，**未出结果前写侧 A/B 没有可用门槛**。

---

> **附：01 阶段文档索引**（供 02 阶段引用）
> - 任务书：`doc/perf-tasks/01-{1,2,2b,2c,2d,3,4,5}-*.md` + `task-progression.md`
> - 报告：`doc/perf-report/01-{1,2,2b,2c,3,4,5}-*-report.md`
> - 分析：`doc/perf-analysis/01-baseline-review-and-nolimit-plan.md`
> - 数据：`results/prod-{01-2d,01-5,...}-*/`
> - Ceph 源码：`/home/lilingfeng/project/ceph/`（v17 quincy）
> - go-fuse 源码：`/home/lilingfeng/go/pkg/mod/github.com/juicedata/go-fuse/v2@.../`
> - JuiceFS 源码：`/home/lilingfeng/project/juicefs/`
> - BeeGFS 部署：`/home/lilingfeng/beegfs-production/`
