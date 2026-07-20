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
┌─────────────────────────────────────────────────────────────────┐
│ 层级           │ 瓶颈             │ 证据                    │ 结论   │
├─────────────────────────────────────────────────────────────────┤
│ ① 磁盘硬件     │ ❌ 非瓶颈        │ BeeGFS 同硬件 9045      │ 可排除 │
│ ② Ceph OSD 软件 │ EC 路径是瓶颈   │ CephFS+EC 4608 < 6250   │ 待攻   │
│    栈（EC4+2） │ Rep 路径非瓶颈  │ CephFS+Rep 6718 ✅ 达标 │        │
│ ③ FUSE 用户态  │ JuiceFS 主瓶颈  │ ceph-fuse 单变量 -42%   │ 待攻   │
└─────────────────────────────────────────────────────────────────┘
```

1. **EC4+2 vs Rep3 在 RADOS 层基本相当**（0.80-1.30×）。01-4 CephFS "Rep +46% vs EC" 是客户端层效应（IOPS 放大），非后端本质差异。
2. **磁盘非瓶颈**（BeeGFS 同硬件 9045；EC per-OSD 仅 290 MB/s = 磁盘能力的 19%）。
3. **Ceph OSD 软件栈在 EC 是瓶颈**（IOPS 放大：256K → 4×64K chunks → disk IOPS bound，%util=100%），**在 Rep 非瓶颈**（CephFS+Rep 6718 ✅ 达标）。
4. **FUSE 是 JuiceFS 主瓶颈**（直接证据：ceph-fuse 单变量对照 4972 → 2884，损失 42%；slat 暴涨 15×：729μs → 11092μs）。
5. **Go runtime 和 TiKV 不是瓶颈**（ceph-fuse 无 Go/TiKV 但和 JuiceFS 一样慢，2884 vs 2969 差 3%）。
6. **rados bench 不能代表后端真实能力**（librados 用户态比 CephFS 内核客户端低效 63%）。
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

1. **cluster_network 修复后性能反降**：01-5 后端修复 cluster_network=10.3.2.0/24，但写 -19%、读 -6%；疑似 OSD 冷缓存，需 24h+ 预热后复测。
2. **CephFS+Rep3 本集群 4972 vs 01-4 集群 6718**：同集群不同时期，差距 35% 未解释（疑似 cluster 状态差异）。
3. **01-3 多实例亚线性**：N4 ra0=5013=单进程 1.74×（亚线性），当时可能受后端裸能力上限压制；**后端裸能力提升后需复测**，可能恢复线性。
4. **6 核封顶根因（01-4 §5.4）**：已定位为反馈平衡点（IOPS 被延迟反馈环封顶 → per-I/O CPU 仅 0.4% → 固定开销占 91%），但**未验证是否有可松动的调优点**。

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
> 逻辑：01-5 已确认磁盘非瓶颈（BeeGFS 同硬件 9045）、EC 瓶颈在 Ceph OSD 软件栈（IOPS 放大 + per-op 开销），故 A 线聚焦**削减 Ceph 软件栈 per-op 开销** + **修复 cluster_network** + **OSD 预热**。

### A1：cluster_network 修复 + OSD 预热复测（进行中，门槛低）

**背景**：01-5 发现 cluster_network 配置未生效（EC subop 全走 public NIC），已修复为 10.3.2.0/24，但修复后性能反降（写 -19%、读 -6%），疑似 OSD 冷缓存。

**假设**：cluster_network 修复后，EC subop 走专用 cluster NIC，理论上应减少 public NIC 争用 + 降低 RTT；当前反降是因为 OSD RocksDB cache 冷、PG 状态重算等一次性开销。

**执行**：
1. 等待 OSD 预热 24h+（期间可跑轻负载填充 cache）。
2. 复测 rados bench EC4+2 randread（-t128 / -t4096，REPEAT=3）。
3. 对比修复前后 + 预热前后，判断 cluster_network 修复的净收益。
4. 附带：测 cluster NIC RTT（`ping 10.3.2.7` vs `ping 10.3.1.7`），确认双网延迟差异。

**判定**：
- 修复+预热后 ≥ 修复前（4300）→ cluster_network 修复有效，纳入生产。
- 仍 < 修复前 → cluster_network 修复无益，回滚（EC subop 走 public NIC 并非瓶颈）。

**状态**：⏳ 待执行（需等待 OSD 预热）。

### A2：Ceph OSD 软件开销削减（核心，代码级定向）

**背景**：01-5 §十二 已从 Ceph 源码定位 per-op 开销来源，最大的可消除项 = **cephx AES（40-100μs/op，`CephxSessionHandler.cc:156`）**。

**假设**：cephx_sign_messages=true（默认）对每条 message 做 4 次 AES 运算（sign + verify × 2 方向），在 HPC/AI 内网可信环境下无安全价值却有显著性能代价。关闭后每 op 省 40-100μs，对 256K randread（当前 ~4300 IOPS-equivalent）可提升 5-15%。

**执行**（在诊断池或维护窗口，**需用户拍板安全权衡**）：
1. **A2.1 cephx_sign_messages=false**：
   - `ceph config set osd cephx_sign_messages false`（global 或 per-pool）。
   - 同样对 mon、mds、client 设置。
   - 复测 rados bench EC randread + CephFS randread，对比前后。
   - **安全评估**：内网可信环境下 cephx 主要防中间人篡改，关签名不关认证（cephx 仍认证连接）；记录风险供用户拍板是否生产应用。
2. **A2.2 BlueStore RocksDB cache 加大**：
   - `ceph config set osd bluestore_cache_kv_ratio 0.5`（默认 0.25，加大一倍）。
   - 减少 RocksDB onode/extent 查询的 disk read（20-40μs/op 部分）。
   - 复测同上。
3. **A2.3 OSD op threads 调优**（可选）：
   - `ceph config set osd osd_op_threads 32`（默认 16）。
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

**假设**：调整 EC stripe 配置可能减少 IOPS 放大，但受 EC 数学约束（k=4 不可避免 4× chunk 读）。

**可探索项**：
1. EC k=6 m=2（更多 data chunks，但需更多 OSD）。
2. EC stripe size 调整（当前默认，可试 1M stripe 减少 per-op 放大）。
3. **不推荐**改回 Rep3（违背 EC 空间效率目标，01-5 已确认 RADOS 层 Rep 无显著优势）。

**状态**：⏳ 可选，数学约束大，预期收益低。

---

## 五、主线 B：JuiceFS 层级调优（FUSE 瓶颈缓解）

> 目标：将 JuiceFS+EC 从 2404（后端 56%）提升到 ≥3500（后端 70%+），缩小与后端裸能力的差距。
> 逻辑：01-4 §5.4 + 01-5 §十一 已确认 FUSE 是 JuiceFS 主瓶颈（dispatch 延迟 5+ms/op → IOPS 反馈封顶 ~11.6K → CPU 封顶 ~6 核）。B 线聚焦**削减 FUSE dispatch 延迟** + **JuiceFS 内部参数** + **多实例复测**。

### B1：FUSE dispatch 延迟削减（核心，攻根因）

**背景**：01-4 §5.4.4 排除了 go-fuse `maxMaxReaders=4`（仅 2 reader 活跃，未触顶），故单纯增大 reader 数无益。根因是 **FUSE dispatch 路径本身的长延迟**（writev → /dev/fuse → kernel FUSE module → back ≈ 5+ms/op）。

**假设 B1a**：go-fuse 默认 `WriteBackCache` 未启用或配置不当，启用后可减少 dispatch 往返。

**执行 B1a**：
1. 检查当前 JuiceFS mount 的 FUSE options（`mount | grep fuse`）。
2. 尝试 `-o writeback_cache`（内核 FUSE writeback 模式，减少 readahead 失效场景的 dispatch）。
3. 复测 randread，对比 slat 变化。

**假设 B1b**：go-fuse `async` 模式或 batching 可减少 per-op dispatch 次数。

**执行 B1b**：
1. 检查 go-fuse 是否支持 async dispatch 或 batch read。
2. 若不支持，评估修改 go-fuse 源码（`/home/lilingfeng/go/pkg/mod/github.com/juicedata/go-fuse/v2@.../fuse/server.go`）的可行性。
3. 注意：01-4 §5.4.4 已证明 maxMaxReaders 非瓶颈，故 batching 是更有前景的方向。

**假设 B1c**：FUSE splice（零拷贝）可减少 memcpy 开销。

**执行 B1c**：
1. 检查 go-fuse 是否启用 splice（`-o splice_read -o splice_write`）。
2. 若未启用，尝试启用并复测。

**判定**：
- 任一 B1 子项使 slat 从 ~11000μs 降到 ≤5000μs → FUSE dispatch 有可松动空间，继续深挖。
- 全部无效 → FUSE dispatch 延迟是架构固有，B 线转向 B3 多实例或 B4 换 mount 方式。

**状态**：⏳ 待执行。

### B2：JuiceFS 内部参数调优

**背景**：01-3 已测 max-uploads 对 randread 无益（-2~-5%，控写不控读）。但 JuiceFS 仍有未试参数。

**执行**：
1. **B2.1 max_background**：当前 50（`fuse.go:469`），试 100/200，看是否增加 FUSE 后台请求处理并发。
2. **B2.2 buffer-size / chunk size**：检查当前配置，尝试加大读 buffer。
3. **B2.3 metadata cache**：检查 meta cache 配置，减少 TiKV 往返（01-2 已确认 meta lat 0.25ms 不吃时间，但加大 cache 可进一步降低）。
4. **B2.4 libreSSL / cgo 优化**：检查 JuiceFS 编译选项是否有可优化（cgo overhead 在 01-4 pprof 中占 ~2c 固定开销）。

**判定**：
- 任一参数使 randread ≥ +10% → 参数调优有效，纳入生产配置。
- 全部 < 5% → JuiceFS 内部参数非瓶颈，转向 B1/B3。

**状态**：⏳ 待执行（与 B1 可并行）。

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

### B4：JuiceFS kernel mount 评估（可选，高风险高收益）

**背景**：01-5 已证明 kernel CephFS（无 FUSE）比 ceph-fuse 快 42%。若 JuiceFS 有 kernel mount 模式（jfs.ko），可绕过 FUSE dispatch 延迟，预期接近后端裸能力。

**现状**：JuiceFS 官方主要推 FUSE 模式；kernel mount（jfs.ko）处于实验阶段，需评估可用性。

**执行**（仅当 B1/B2/B3 收益不足时）：
1. 检查 JuiceFS 是否提供 kernel mount 模块（`juicefs mount --kernel` 或独立 jfs.ko）。
2. 若可用：在测试环境试挂载，复测 randread，对比 FUSE 模式。
3. 评估稳定性、兼容性、维护成本。
4. **红线**：不在 157 生产内核加载实验模块（可能影响内核稳定性）。

**判定**：
- kernel mount 可用且 randread ≥ 4000 → JuiceFS 换 mount 方式可行，评估生产应用。
- 不可用或不稳定 → 放弃，接受 JuiceFS FUSE 42% 税。

**状态**：⏳ 可选，高门槛（需评估 JuiceFS kernel mount 成熟度）。

---

## 六、执行顺序与决策树

```
A1 cluster_network 修复 + OSD 预热复测 ──── 门槛低，先行
     │
     ├─ 有效（≥4300）→ 纳入生产，继续 A2
     └─ 无益 → 回滚，跳到 A2
          │
          ▼
A2 Ceph OSD 软件开销削减 ──────────── 核心攻坚
     │
     ├─ A2.1 cephx_sign_messages=false 有效（≥+10%）→ 用户拍板生产应用
     ├─ A2.2 BlueStore cache 加大有效 → 叠加
     └─ 全部无效 → 后端 EC 软件栈无松动空间，A 线天花板确认
          │
          ▼
B1 FUSE dispatch 延迟削减 ──────────── 与 A 线并行
     │
     ├─ B1a writeback_cache 有效 → 纳入
     ├─ B1b async/batch 有效 → 深挖
     └─ 全部无效 → FUSE dispatch 是架构固有
          │
          ▼
B2 JuiceFS 内部参数 ────────────────── 与 B1 并行
     │
     ├─ 任一有效 → 纳入
     └─ 全部无效 → JuiceFS 内部无松动空间
          │
          ▼
[A 线 + B 线叠加后复测]
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
[可选] B4 JuiceFS kernel mount 评估 ── 仅当 B1-B3 收益不足
     │
     └─ 可用且稳定 → 换 mount 方式，绕过 FUSE
```

### 6.1 优先级排序

| 优先级 | 任务 | 预期收益 | 成本 | 风险 |
|:---:|------|---------|------|------|
| P0 | A1 cluster_network + 预热复测 | 中（可能恢复 -19% 损失） | 低（等待时间） | 低 |
| P1 | A2.1 cephx_sign_messages=false | 高（5-15%，最大可消除项） | 低（配置改） | 中（安全权衡） |
| P1 | B1a FUSE writeback_cache | 高（可能削减 dispatch 延迟） | 低（mount 选项） | 低 |
| P2 | A2.2 BlueStore cache 加大 | 中（减少 RocksDB 查询） | 低（配置改） | 低 |
| P2 | B2 JuiceFS 内部参数 | 中 | 低 | 低 |
| P3 | B3 多实例复测 | 诊断价值（不直接达标） | 低 | 低 |
| P4 | A3 OSD 扩容 | 不确定（EC IOPS 放大是架构固有） | 高（加盘） | 中 |
| P4 | B4 JuiceFS kernel mount | 高（绕过 FUSE） | 高（实验模块） | 高（内核稳定） |
| P5 | A4 EC stripe 调优 | 低（数学约束） | 中 | 中 |

---

## 七、口径与红线

### 7.1 测试口径（继承 01 阶段）

- **达标线**：不限速 100GbE 下有效带宽 ≥ 6250 MiB/s（网卡 50%）。
- **统计口径**：fio bw_log 稳态中位数（截开头 1/4），不认 fio 平均。
- **block size**：256K（与 EC stripe_width 对齐）。
- **冷态**：cache=0，无 writeback。
- **openfiles**：128（=numjobs，避免 01 阶段假瓶颈）。
- **双口径**：default + ra0 均测，分析以 ra0 为主。
- **REPEAT**：≥3 轮取中位数，CV < 5%。

### 7.2 红线（不可触碰）

1. 不重启节点、不动 157 内核/100GbE NIC/md0/WekaIO。
2. 不破坏生产 EC4+2 池（调优用独立池或维护窗口）。
3. cephx_sign_messages=false 等**安全相关配置变更需用户拍板**，不在 AI 助手权限内擅自应用生产。
4. B4 JuiceFS kernel mount **不在 157 生产内核加载实验模块**。
5. 所有 OSD 配置变更前做 `ceph osd dump` 快照，可回滚。

### 7.3 文档约定

- 调优任务书：`doc/perf-tasks/02-XX-*.md`（与 01 阶段任务书并列）。
- 调优报告：`doc/perf-report/02-XX-*-report.md`。
- 数据归档：`results/prod-02-XX-*-<timestamp>/`。
- 本计划文档随执行进度更新结论（与 01 计划文档同模式）。

---

## 八、待用户拍板的开放问题

1. **cephx_sign_messages=false 是否可在生产应用**：内网可信环境下安全风险低，但需用户权衡（cephx 防中间人篡改，关签名不关认证）。
2. **调优基线口径**：01-2c 后已倾向 ra0（随机项全面占优），但顺序项 default 仍占优。**是否正式将调优分析基线定为 ra0**？（01 阶段此问题悬而未决）。
3. **A3 OSD 扩容是否纳入预算**：若 A1/A2 收益不足，加盘是最后手段，需提前评估成本。
4. **B4 JuiceFS kernel mount 是否值得评估**：高收益高风险，需用户决定是否投入精力研究实验模块。
5. **验收线是否调整**：当前 6250（网卡 50%）。若 02 阶段后端+JuiceFS 调优仍不达标，是否接受"JuiceFS+EC 后端 70%（~3500）"作为 EC 空间效率下的合理上限？

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
