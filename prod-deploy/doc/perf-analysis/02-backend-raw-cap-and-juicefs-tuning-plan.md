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

## 零、零号检查（A1/B1 前置，门槛极低）

> **核心逻辑**：在投入大量测试时间前，先确认测试环境的基础设施没有隐藏问题。01-5 已暴露 cluster_network 零流量是重大隐患；4 份外部调优建议均指出"不先修底层问题就做 A/B 线调优，所有后续数据都可能受干扰"。
> 来源：`/tmp/02-stage-optimization-suggestions.md` §一 + `/tmp/minimax-m3-02-stage-tuning-recommendations.md` §二 + `/tmp/opencode-02-stage-tuning-suggestions.md` 方向1 + `/tmp/opencode-02阶段调优补充建议.md` N1。

### Z1：cluster_network 零流量根因诊断【P0】

**问题**：01-5 §四.4 报告 cluster NIC `enp139s0f1np1` **全程零流量**——EC subop 全部走 public NIC。02 计划 A1 直接写"等预热 24h 后复测"，但**没有验证修复是否生效**。若 cluster_network 依然零流量，则"预热后复测"得到的是无效对照。

**执行**（4 项，<30 分钟）：
```bash
# 1. 配置层确认
ceph config show osd.0 | grep -E "cluster_network|public_network|cluster_addr"
ceph config get osd cluster_network
ceph config get osd public_network

# 2. OSD 进程实际监听端口
ss -tlnp | grep ceph   # 应有 6789(public) + 6800-7300(cluster) 两组

# 3. CRUSH map 检查
ceph osd metadata osd.0 | grep -E "addr|front_addr|back_addr"

# 4. 抓包直接确认（跑 randread 时）
tcpdump -i enp139s0f1np1 'port 6800' -c 100   # 期望：有 EC subop 流量
```

**判定**：
- 配置层正确 + 进程监听 6800 + tcpdump 有流量 → cluster_network 已生效，进 A1 预热复测。
- 配置层正确但 tcpdump 0 流量 → 可能是 Quincy 17.2.x 在 `failure-domain=osd` 下的路由 bug，搜 [tracker.ceph.com](https://tracker.ceph.com)。
- 配置层缺失 → 修配置后重测。

### Z2：PG 分布与 CRUSH 均衡性检查【P0】

**问题**：01 阶段从未检查 32 PG 在 6 OSD 上的分布均衡性。EC k=4+m=2+6 OSD 理论每 OSD 5.3 PG，但 CRUSH 可能不均匀。

**执行**（~5 分钟）：
```bash
ceph osd df tree                          # 各 OSD 使用率
ceph pg dump_stuck                         # 是否有 stuck PG
ceph pg ls-by-pool juicefs-data | awk '{print $NF}' | sort | uniq -c  # PG per OSD
```

**判定**：若某 OSD 承载 PG 数偏离均值 ±20% → 调 pg_num 或重 crush。

### Z3：kernel CephFS+Rep 同集群差距复现【P0】

**问题**：01-4 集群 kernel CephFS+Rep = **6718**（达标），01-5 同集群同配置仅 **4972**（差 35%），从未被解释。

**价值**：若能复现 6718 → "换 CephFS+Rep"是确定性达标路径，直接给用户拍板；若复现 4972 → 找出 01-4 集群为何更高（cluster_network 状态？Ceph 版本？PG 分布？），挖掘更深调优空间。

**执行**（与 Z1 合并）：
1. 在本集群（01-5 FSID）kernel mount 跑一次 randread。
2. 若 Z1 确认 cluster_network 修复生效 → 修复后再跑一次，对比是否从 4972 → 6718。

### Z4：FUSE 内核侧参数核查【P0 — 整个 B 线最高优先级】

**问题**：02 计划 B1 全集中在 go-fuse 用户态（writeback_cache / splice / batch），但 **FUSE dispatch 延迟是用户态 + 内核态双重路径**。01-4 §5.4.4 排除了 go-fuse `maxMaxReaders=4`（用户态），但**从未检查内核侧 FUSE 队列参数**。

**关键怀疑**：`/sys/fs/fuse/connections/<dev>/max_read` 默认 **131072（128K）**，而业务用 **256K block** ——每个 256K 读请求被内核 FUSE 拆成 2 次 `/dev/fuse` 往返，**dispatch 延迟直接翻倍**。这可能是 slat 11092μs（kernel CephFS 729μs 的 15×）的**物理根因**，而非 01-4/01-5 推断的"FUSE 架构固有"。

**执行**：
```bash
# 1. 检查当前值
for d in /sys/fs/fuse/connections/*/; do
  echo "=== $d ==="
  echo "max_background: $(cat $d/max_background)"
  echo "congestion_threshold: $(cat $d/congestion_threshold)"
  echo "max_read: $(cat $d/max_read)"
  echo "max_write: $(cat $d/max_write)"
done

# 2. 若 max_read=131072(128K)，调大到 256K 并 remount
echo 262144 > /sys/fs/fuse/connections/*/max_read    # 注意：需 umount + remount 生效
echo 1024 > /sys/fs/fuse/connections/*/max_background
```

| 参数 | 默认 | 建议 | 机理 |
|------|------|------|------|
| `max_read` | 131072 (128K) | **262144 (256K)** | 与 JuiceFS 256K block 对齐，避免拆包 |
| `max_write` | 131072 | 262144 | 同上 |
| `max_background` | 128 | 512-1024 | 内核 pending 请求数；128j×128 远超 128 |
| `congestion_threshold` | max_bg × 0.75 | 接近 max_bg | 入队限流阈值 |

**预期收益**：若 `max_read=128K` 确认是限制，修正后 slat 砍半，randread 可能提升 20-40%。**这会改变整个 B 线策略**——从"攻 FUSE 架构固有延迟"转向"修正一个配置不匹配"。

### Z5：librados 客户端限流参数核查【P0】

**问题**（来源：`/tmp/opencode-02阶段调优补充建议.md` N1）：01-4 §5.4 的"IOPS 被延迟反馈环封顶在 11.6K → CPU 封顶 6 核"推导，隐含前提是"128 goroutine 发出的请求都能畅通进入 librados objecter 队列"。但 Ceph 客户端侧有**两个默认限流阀**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `objecter_inflight_ops` | 1024 | objecter 最大在途操作数 |
| `objecter_inflight_op_bytes` | **100MB** | objecter 最大在途字节数 |

当前 fio 口径 `iodepth=128 × numjobs=128`，每 op 256K，理论峰值在途字节 = 16384 × 256KB ≈ **4GB**，远超 100MB 默认阈值 **40 倍**。若未显式覆盖，objecter 会在客户端本地排队等待配额释放，这部分排队被 fio 计入 `slat`/`clat`，**混进"FUSE dispatch 5+ms/op"的观测值中**，导致 FUSE 税被高估。

**执行**（成本极低）：
```bash
ceph config get client objecter_inflight_ops
ceph config get client objecter_inflight_op_bytes
# 同时检查 157 ceph.conf 和 JuiceFS 进程实际生效值
```

**判定**：
- 确认是默认值 100MB → 临时调大到 `objecter_inflight_op_bytes=1073741824`（1GB），复测 randread D0，对比 slat 是否显著下降。
- 若 slat 下降 30%+ → 说明 01-4 §5.4 的"FUSE dispatch 5+ms 是架构固有"结论需部分修正，**objecter 限流是比 FUSE dispatch 更早触发的隐藏瓶颈**。
- 若无变化 → 排除该假设，明确记录"objecter 限流非瓶颈"。

### Z6：EC pool fast_read 开关【P1】

**问题**（来源：`/tmp/opencode-02阶段调优补充建议.md` N3）：01-5 §4.1 显示 EC randread 存在"冷启动-暖缓存"模式（r1=3191 vs r2/r3=4600+，+44%）。EC 读延迟 = `max(4 个 shard 延迟)`，某个 shard 偶发慢会拖低整体。Ceph 原生 `fast_read` 属性向 **K+M 个 shard 全发请求**，取最先回来的 K 个组数据，用冗余 shard 顶替偶发慢 shard。

**执行**（一条命令）：
```bash
ceph osd pool set juicefs-data fast_read true   # 或诊断池先试
rados bench -p juicefs-data 60 rand --pool-ops   # REPEAT=3
```

**判定**：
- 消除"冷启动-暖缓存"模式（r1 ≈ r2 ≈ r3）→ 确认尾延迟拖尾是冷启动根因。
- 中位数提升 → fast_read 有效（需权衡多读 M=2 份冗余 shard 的 IOPS/网络代价）。
- 中位数反降（IOPS-bound 场景多读反而更糟）→ 回滚，不适用。

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

> **前置**：Z6 `fast_read` 开关已作为零号检查项先行验证。若 fast_read 有效，A4 的 stripe/k/m 调优可降低优先级。

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

### B1：FUSE dispatch 延迟削减（核心，攻根因）

> **前置**：Z4（FUSE 内核侧 `max_read` 检查）已作为零号检查项先行。若 Z4 确认 `max_read=128K` 且修正后 slat 砍半，则 B1 的优先级和方向需重新评估——可能是配置不匹配而非架构固有。

**背景**：01-4 §5.4.4 排除了 go-fuse `maxMaxReaders=4`（仅 2 reader 活跃，未触顶），故单纯增大 reader 数无益。根因是 **FUSE dispatch 路径本身的长延迟**（writev → /dev/fuse → kernel FUSE module → back ≈ 5+ms/op）。

**假设 B1a**：go-fuse 默认 `WriteBackCache` 未启用或配置不当，启用后可减少 dispatch 往返。

**执行 B1a**：
1. 检查当前 JuiceFS mount 的 FUSE options（`mount | grep fuse`）。
2. 尝试 `-o writeback_cache`（内核 FUSE writeback 模式，减少 readahead 失效场景的 dispatch）。
3. 复测 randread，对比 slat 变化。

**假设 B1b**：go-fude 版本/补丁调研 + io_uring FUSE 替代路径（来源：外部建议新增）。

**执行 B1b**：
1. 检查 JuiceFS 依赖的 go-fuse 版本（`grep go-fuse /home/lilingfeng/project/juicefs/go.mod`），对比上游是否有未启用的 batch/splice 优化。
2. **检查 157 内核版本**：`uname -r`。若 ≥ 6.1 → Linux 支持 `IORING_OP_URING_CMD` 让 FUSE 通过 io_uring 与内核通信，**绕过传统 /dev/fuse read/write 模型**——理论上是 B4（kernel mount）的更安全替代方案（仍走 FUSE ABI，不需要新内核模块）。
3. 调研 JuiceFS 社区是否有 io_uring FUSE 的实验分支。

**假设 B1c**：FUSE splice（零拷贝）可减少 memcpy 开销。

**执行 B1c**：
1. 检查 go-fuse 是否启用 splice（`-o splice_read -o splice_write`）。
2. 检查内核 `/sys/module/fuse/parameters/` 是否允许 splice。
3. 若未启用，尝试启用并复测。

**判定**：
- 任一 B1 子项使 slat 从 ~11000μs 降到 ≤5000μs → FUSE dispatch 有可松动空间，继续深挖。
- 全部无效 → FUSE dispatch 延迟是架构固有，B 线转向 B3 多实例或 io_uring/kernel mount。

**状态**：⏳ 待 Z4 完成后执行（Z4 结果决定 B1 方向）。

### B2：JuiceFS 内部参数调优

**背景**：01-3 已测 max-uploads 对 randread 无益（-2~-5%，控写不控读）。但 JuiceFS 仍有未试参数。

> **前置**：Z5（objecter_inflight_op_bytes 限流核查）已作为零号检查项先行。若 Z5 确认限流命中，B2 优先级降低（限流是更早的瓶颈）。

**执行**：
1. **B2.1 max_background**：当前 50（`fuse.go:469`），试 100/200，看是否增加 FUSE 后台请求处理并发。**注意**：这是 go-fuse 用户态参数，与内核 `/sys/fs/fuse/connections/*/max_background`（Z4 检查项）是不同变量，需同时调。
2. **B2.2 buffer-size / chunk size**：检查当前配置，尝试加大读 buffer。
3. **B2.3 metadata cache**：检查 meta cache 配置，减少 TiKV 往返（01-2 已确认 meta lat 0.25ms 不吃时间，但加大 cache 可进一步降低）。
4. **B2.4 JuiceFS 连接/IOContext 架构核查**（来源：外部建议新增）：检查 JuiceFS cgo 调用 librados 时是否复用单一 rados 连接/IOContext 处理全部 128 并发请求——若单连接，所有请求排队在同一 librados session 内部队列。
5. **B2.5 cgo 优化**：检查 JuiceFS 编译选项（cgo overhead 在 01-4 pprof 中占 ~2c 固定开销，但 01-5 已确认 Go/cgo 非主瓶颈，低优先级）。

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
零号检查（§零）────────── 门槛极低，先行（<1h）
  ├─ Z1 cluster_network 根因诊断 ─── 确认修复生效后再预热
  ├─ Z2 PG 分布均衡性检查
  ├─ Z3 kernel CephFS+Rep 同集群复现 6718
  ├─ Z4 FUSE 内核 max_read 检查 ─── 可能是 slat 15× 的物理根因
  ├─ Z5 objecter_inflight_op_bytes 限流核查 ─── 可能是隐藏客户端限流
  └─ Z6 EC pool fast_read 开关
     │
     ├─ Z4 命中（max_read=128K）→ 修正后 slat 砍半，B 线方向根本改变
     ├─ Z5 命中（限流生效）→ 修正后排除客户端限流干扰，01-4 §5.4 结论需修正
     ├─ Z3 复现 6718 → 记录"CephFS+Rep 达标"路径
     └─ 任一项异常 → 先修异常再进 A/B 线
          │
          ▼
A1 cluster_network 修复 + OSD 预热复测 ──── 门槛低，先行
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
| **P0** | Z1 cluster_network 根因诊断 | 高（影响 A1 有效性） | 极低（<30min） | 0 |
| **P0** | Z2 PG 分布均衡性检查 | 中 | 极低（~5min） | 0 |
| **P0** | Z3 kernel CephFS+Rep 同集群复现 | 高（影响决策） | 低 | 低 |
| **P0** | Z4 FUSE 内核 max_read 检查 | **可能极高（slat 砍半）** | 极低 | 低 |
| **P0** | Z5 objecter 限流核查 | **可能极高（隐藏限流）** | 极低 | 低 |
| **P1** | Z6 EC pool fast_read | 中（消除尾延迟拖尾） | 极低（一条命令） | 低 |
| **P1** | A2.1 cephx 分级测试 | 高（5-15%，最大可消除项） | 低（配置改） | 中（安全权衡） |
| **P1** | A2.2 osd_memory_target 16GB + cache | 高（EC 4× RocksDB 查） | 低（配置改） | 低 |
| **P1** | B1a FUSE writeback_cache | 高（可能削减 dispatch 延迟） | 低（mount 选项） | 低 |
| **P2** | A2.3 Messenger/线程模型 | 中 | 低（配置改） | 中 |
| **P2** | B2 JuiceFS 内部参数 | 中 | 低 | 低 |
| **P2** | C1 NVMe 队列参数 | 中（EC %util=100%） | 极低 | 低 |
| **P2** | C2 NIC IRQ 亲和性 | 中 | 低 | 低（slave only） |
| **P2** | C3 MTU 4200→9000 | 中 | 中（需确认交换机） | 中 |
| **P2** | D1 randwrite-ow 波动数据分析 | 中（补齐唯一未结项） | 极低（纯分析） | 0 |
| **P2** | D2 大 block-size（1M/4M）基线 | 高（可能不改代码就近达标） | 中 | 低 |
| **P3** | B3 多实例复测 | 诊断价值 | 低 | 低 |
| **P3** | B1b go-fuse 版本/io_uring 调研 | 中-高 | 低 | 低 |
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
- **openfiles**：128（=numjobs，避免 01 阶段假瓶颈）。
- **双口径**：default + ra0 均测，分析以 ra0 为主。
- **REPEAT**：≥3 轮取中位数，CV < 5%。

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
2. **调优基线口径**：01-2c 后已倾向 ra0（随机项全面占优），但顺序项 default 仍占优。**是否正式将调优分析基线定为 ra0**？
3. **A3 OSD 扩容是否纳入预算**：若 A1/A2 收益不足，加盘是最后手段。
4. **io_uring FUSE / kernel mount 是否值得评估**：B4 先评估 io_uring（更安全），再考虑 jfs.ko。
5. **验收线是否调整**：若 02 阶段后端+JuiceFS 调优仍不达标，是否接受"JuiceFS+EC 后端 70%（~3500）"作为 EC 空间效率下的合理上限？
6. **MTU 9000 是否能确认交换机支持**（C3 前置）：需 IT/网络组答复。
7. **157 client 是否允许在 sysctl 层做 TCP/IRQ 调优**（C2/C4）：sysctl 改动不涉及内核模块加载——是否可放宽 157 红线？

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
