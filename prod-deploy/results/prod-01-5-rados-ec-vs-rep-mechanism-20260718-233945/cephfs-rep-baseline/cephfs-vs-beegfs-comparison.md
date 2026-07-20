# CephFS+Rep3 vs BeeGFS Stage3 全量基线对比报告

> 测试日期：2026-07-19
> 测试方法：CephFS+Rep3（kernel 内核态）+ 同 BeeGFS Stage3 口径 12 项 fio 测试
> 数据源：
> - CephFS+Rep3: `results/prod-01-5-.../cephfs-rep-baseline/`
> - BeeGFS Stage3: `/home/lilingfeng/beegfs-production/results/stage3-aligned-nolimit-20260715-155122/` + `stage3-summary.md`
> 验收线：6250 MiB/s（100GbE 半速）

---

## 一、对比总表

| 测试项 | CephFS+Rep3 | BeeGFS | 比值 | 达标6250 | 差距分析 |
|--------|-------------|--------|------|----------|----------|
| seqread (1j, 256K) | 1133 | 1644 | 0.69× | ❌❌ | -31% |
| seqwrite (1j, 4M, fsync) | 639 | 1906 | **0.34×** | ❌❌ | **-66%（写最大差距）** |
| mseqread (16j, 256K) | 4115 | 7565 | 0.54× | ❌✅ | -46% |
| mseqwrite (16j, 4M, fsync) | 4793 | 11314 | 0.42× | ❌✅ | -58% |
| layout (128j, 4M) | 5039 | 10199 | 0.49× | ❌✅ | -51% |
| randread-256K (128j) | 5576 | 9045 | 0.62× | ❌✅ | -38% |
| randread-64K (128j) | 4031 | 4759 | 0.85× | ❌❌ | -15%（最小差距）|
| randread-1M (128j) | 5551 | 9796 | 0.57× | ❌✅ | -43% |
| randwrite-analysis | 4511 | 6505 | 0.69× | ❌✅ | -31% |
| randrw-analysis R/W | 2917/2918 | 4853/4836 | 0.60× | ❌❌ | -40% |
| randwrite-fresh | 4422 | 6795 | 0.65× | ❌✅ | -35% |
| randrw-fresh R/W | 3986/3985 | 2573/4279 | R:1.55× / W:0.93× | ❌❌ | R +55%（BeeGFS fresh 起步失真）/ W -7% |

**汇总**：12 项中 11 项 CephFS < BeeGFS（仅 randrw-fresh R 异常高，因 BeeGFS fresh 起步 R 失真）。
**写类差距更大**（写 -31%~-66%）**vs 读类差距**（读 -15%~-46%）。

---

## 二、差距根源分析

### 2.1 写路径差距（写类 -31%~-66%）

**CephFS+Rep3 写路径**：
- 客户端 → MDS（元数据 cap）→ OSD primary → 写本地 BlueStore → primary 发 subop_w 给 2 副本 → 副本 ack → primary 等 3/3 ack（size=3, min_size=2）→ primary ack 客户端
- fsync 强制等待：BlueStore WAL flush + RocksDB commit + 副本 ack
- 3× 写放大（256K logical → 3 × 256K actual = 768K）

**BeeGFS 写路径**：
- 客户端 → meta → storage → 写本地 + Buddy Mirror + numtargets=3 → ack
- 同 3× 写放大（Buddy Mirror + numtargets=3）
- 走 100GbE RDMA（更低延迟）

**写瓶颈定位（基于 clat 数据）**：

| 测试项 | CephFS clat avg | 含义 |
|--------|-----------------|------|
| seqwrite (1j, 4M, fsync) | 5.66ms，99.22% @10ms | fsync 等待 BlueStore WAL flush + RocksDB commit + 副本 ack |
| mseqwrite (16j, 4M, fsync) | 12.4ms，90% @10-20ms | 多流并发 + fsync 等待 |
| layout (128j, 4M, fsync) | 12.2s，87.87% @2000ms+ | 128 并发 fsync 严重队列 |
| randwrite-analysis | ~37ms | 256K randwrite + fsync |
| randwrite-fresh | ~37ms | 同上 + create_on_open |

**写瓶颈根源**：
1. **Ceph BlueStore + RocksDB per-IO 开销**：fsync 触发 WAL flush（tmpfs）+ RocksDB commit，每 op ~5-12ms
2. **3× 写放大 + 副本 ack 等待**：primary 必须等 min_size=2 ack 才返回
3. **cluster_network=0 配置问题**（01-5 实测发现）：subop_w 走 public NIC，挤占 client 带宽
4. **CephFS MDS 元数据开销**：每个写需要 MDS 更新 dentry size/mtime

**BeeGFS 优势**：
- 用 100GbE RDMA（延迟 <5μs vs Ceph cluster NIC=0 走 public NIC）
- 无 BlueStore/RocksDB 软件栈
- 内部协议精简，per-IO 开销小

### 2.2 读路径差距（读类 -15%~-46%）

**CephFS+Rep3 读路径**：
- 客户端 → MDS（cap 检查 + inode lookup）→ OSD primary（直接读本地）→ 返回
- 1× 读放大（只 primary 服务，2 副本 idle）
- kernel CephFS 客户端高效（无 FUSE）

**BeeGFS 读路径**：
- 客户端 → meta → storage → 返回
- 内核模块 + RDMA

**读瓶颈定位（基于 clat 数据）**：

| 测试项 | CephFS clat avg | 含义 |
|--------|-----------------|------|
| seqread (1j, 256K) | 5ms range | 单流串行读，per-IO 延迟主导 |
| mseqread (16j, 256K) | 多并发但稳态 | 16 路并发，OSD 队列适中 |
| randread-256K (128j) | 708ms，16.44%@1ms | 16384 并发，OSD 队列积压 |
| randread-1M (128j) | 2.69s | 1M 块 × 16K 并发 = 大块延迟长 |
| randread-64K (128j) | 1ms range | 64K 小块，IOPS-bound |

**读瓶颈根源**：
1. **Ceph OSD per-IO 软件开销 ~250μs**（BlueStore KV 查询 + RocksDB + cephx + OSD message）
2. **CephFS MDS 元数据查询开销**（每个新文件需 MDS lookup，cache miss 时延）
3. **CephFS kernel 客户端 → MDS → OSD 两跳**（BeeGFS 也是两跳但 RDMA 更快）
4. **cluster_network=0**：对 Rep3 读无影响（不走 subop），但 public NIC 同时承载 client 和 EC 残余 subop

**BeeGFS 优势**：
- 无 BlueStore/RocksDB 软件栈
- RDMA 通信延迟 <5μs vs Ceph 内核 msgr ~50μs
- 内部协议精简

### 2.3 关键不对称：写差距 > 读差距

| 维度 | CephFS 写 / BeeGFS 写 | CephFS 读 / BeeGFS 读 |
|------|------------------------|------------------------|
| 平均比值 | 0.34-0.65× | 0.54-0.85× |
| 主要差距 | -35%~-66% | -15%~-46% |

**写差距更大的原因**：
1. fsync 强制刷盘触发 BlueStore WAL flush + RocksDB commit（BeeGFS fsync 路径更轻）
2. 3× 写放大的副本 ack 等待（BeeGFS Buddy Mirror + numtargets=3 也是 3×，但 RDMA ack 更快）
3. **cluster_network=0 让 subop_w 走 public NIC**，多流写时挤占 client 带宽（BeeGFS RDMA 无此问题）

---

## 三、调优空间分析

### 3.1 调优项总表

| 调优项 | 影响项 | 预期增益 | 实测/理论 | 实施成本 |
|--------|--------|----------|-----------|----------|
| **修复 cluster_network 配置** | 写类（多流） | +20-40% | 01-5 已发现 cluster NIC=0 | 低（改 ceph.conf + 重启 OSD）|
| OSD cache 增加（osd_memory_target 1G→50G）| 读类冷启动 | +20-30%（冷）| 理论 | 低（动态调参）|
| CephFS mount 选项（readahead, nocrc）| 顺序读 | +5-15% | 理论 | 极低 |
| CephFS MDS cache 增加（mds_cache_size）| 元数据密集负载 | +5-10% | 理论 | 低 |
| PG num 增加（32→128） | 全部 | +5-10% | 理论 | 中（需重平衡）|
| 关 cephx 认证 | 全部 | +1-3% | 理论 | 低 |
| Rep pool size=3→2 | 写类 | +30-50% | 理论 | 低（容错降级）|
| BlueStore 调参（deferred_size, throttle）| 全部 | +5-10% | 老集群已测无效 | 低 |
| **OSD 扩容（6→8+ OSD）** | 全部 | +33%+ | 硬件扩容 | 高（硬件采购）|
| **Ceph Crimson 重写** | 全部 | +50-100% 潜在 | 实验阶段 | 极高（未生产就绪）|

### 3.2 关键调优项详解

#### 调优 1：修复 cluster_network（**写类最大调优空间**）

**问题**：01-5 实测发现 `cluster_network` 配置未生效，cluster NIC `enp139s0f1np1` 全程零流量。Rep3 写路径的 subop_w（primary → 2 副本）走 public NIC，与 client 流量争抢带宽。

**修复方法**：
```bash
# 在 ceph.conf [global] 添加
cluster_network = 10.3.2.0/24
# 重启所有 OSD
sudo ceph tell osd.* shutdown  # 谨慎，逐个重启避免降级
# 或用 ceph orch
sudo ceph orch restart osd
```

**预期收益**：
- 写类（多流）：seqwrite 单流无变化（1 个 client 不挤带宽），mseqwrite/layout 多流 +20-40%
- 读类：Rep3 读不走 subop，无直接影响；但 public NIC 释放后整体负载下降
- 预期 mseqwrite 4793 → 6000-7000，layout 5039 → 7000-9000
- **可能让 layout/mseqwrite 接近 6250 ✅**

#### 调优 2：增加 OSD BlueStore cache（**冷启动读最大调优空间**）

**问题**：01-5 实测 EC r1 cold vs r2/r3 warm 差距 44%（3233 vs 4600）。当前 `osd_memory_target` 默认 1G，1TB RAM 节点有大量余量。

**修复方法**：
```bash
# 在 ceph.conf [osd] 添加
osd_memory_target = 53687091200  # 50GB
# 重启 OSD 生效
```

**预期收益**：
- 冷启动读（r1）：+20-30%
- 元数据密集负载：MDS cache 也可同步增加
- 对 randread r1 影响最大，r2/r3 已 warm 无变化

#### 调优 3：CephFS mount 选项 + readahead

**修复方法**：
```bash
# mount 时加选项
sudo mount -t ceph :/ /mnt/cephfs-kernel -o name=admin,rasize=4194304,readahead_max=4194304
# rasize: 单次 readahead 大小（默认 256K，可增至 4M）
# readahead_max: 最大 readahead 字节
```

**预期收益**：
- 顺序读（seqread/mseqread）：+5-15%
- 随机读：无影响（direct=1 绕预读）

#### 调优 4：Rep pool size=2（容错降级换性能）

**问题**：当前 Rep3 = 3 副本，写放大 3.0×。改 Rep2 = 2 副本，写放大降至 2.0×。

**预期收益**：
- 写类：+30-50%（少 1 副本 ack 等待）
- 读类：无变化（primary 不变）
- **代价**：容错从 2 盘降到 1 盘（同 host 1 OSD down 数据仍在，但 2 OSD down 数据丢）

#### 调优 5：OSD 扩容（硬件）

**问题**：当前 6 OSD × ~750-1500 MB/s per-OSD（Ceph 软件天花板），总能力 ~4500-9000 MB/s。

**扩容方案**：
- 6 → 8 OSD：+33% 容量与 IOPS
- 6 → 12 OSD：+100% 容量与 IOPS
- 但单盘 Ceph 软件开销不变，靠数量堆叠

**预期收益**：
- 所有项线性扩展
- 8 OSD 时 randread-256K 可能从 5576 → 7400（达标 ✅）

### 3.3 综合预期

| 调优组合 | 预期 CephFS+Rep3 带宽 |
|----------|------------------------|
| 现状（baseline） | 写 639-5039, 读 1133-5576 |
| + cluster_network 修复 | 写 +20-40%，读不变 | 写 800-7000, 读 同 |
| + OSD cache 50G | 冷启动读 +20-30% | 写 同，读冷启动 +25% |
| + mount readahead | 顺序读 +5-15% | seqread 1300, mseqread 4700 |
| + Rep size=2 | 写 +30-50% | 写 1000-10500 |
| + OSD 扩容 8 个 | 全部 +33% | 写 1500-9300, 读 1700-7400 |
| **全调优综合** | | **大部分项接近或超过 6250 ✅** |

---

## 四、关键观察：CephFS+Rep3 vs BeeGFS 的本质差距

**即使应用所有调优，CephFS+Rep3 大概率仍 < BeeGFS**，因为：

1. **BeeGFS 用 100GbE RDMA**：延迟 <5μs，Ceph 用 TCP ~50μs（cluster_network 修复后用独立 100GbE TCP 仍 ~50μs）
2. **BeeGFS 无 BlueStore/RocksDB 软件栈**：per-IO 开销远低于 Ceph
3. **BeeGFS 是专用存储协议**：内部精简，Ceph 是通用分布式存储（更多功能 = 更多开销）

**Ceph 的优势**（与性能无关）：
- 成熟的 POSIX 一致性
- 快照、克隆、EC 等丰富功能
- 多 PD 多 MDS 多 monitor 的成熟 HA
- 生态完整（librados/librbd/rgw/cephfs 多接口）

**BeeGFS 的限制**：
- POSIX 一致性较 Ceph 弱（性能优先设计）
- 无快照（依赖外部备份）
- 生态相对窄（专注 HPC/AI 场景）

---

## 五、决策建议

### 5.1 若业务"以最大带宽为首要目标"

→ **选 BeeGFS**：12 项中 11 项 CephFS < BeeGFS，且差距 15-66%。即使 CephFS 全调优，仍难追平 BeeGFS（RDMA 优势 + 无 BlueStore/RocksDB 开销）。

### 5.2 若业务"需 Ceph 生态（快照/EC/多接口）+ 接近 BeeGFS 性能"

→ **选 CephFS + Rep3 + 全调优**：
- 必做：修复 cluster_network（写类 +20-40%）
- 必做：OSD cache 50G（冷启动读 +25%）
- 推荐：mount readahead（顺序读 +10%）
- 可选：Rep size=2（写 +30-50%，容错降级）
- 可选：OSD 扩容（全部 +33%）

**全调优后预期**：
- 写类 800-10500（layout/mseqwrite 可能达标 6250 ✅）
- 读类 1300-7400（randread-256K 可能达标 ✅）
- 仍可能不达标：seqwrite 单流 fsync（~1000-1500）、seqread 单流（~1500-1900）

### 5.3 若业务"既要性能又要 Ceph 功能"

→ **混合方案**：
- 热数据用 BeeGFS（高性能）
- 冷数据/归档用 CephFS+EC4+2（高容量效率）
- 通过 mount point 分流

---

## 六、与之前 01-4/01-5 数据的关系

| 数据源 | CephFS+Rep3 randread-256K | 备注 |
|--------|----------------------------|------|
| 01-4 集群（2026-07-16）| 6718 ✅ | 旧集群状态 |
| 01-5 实验B（2026-07-19）| 4972 | 同集群，pool 共享污染 |
| **本任务全量基线**（2026-07-19）| **5576** | 三轮中位数，集群状态最佳时 |

**01-4 6718 vs 本任务 5576 差距**：可能源于 cluster 状态差异（01-5 重部署后 CephFS + 共享池残留）。但**不影响与 BeeGFS 的横向对比**（同集群同时间测）。

---

## 七、限制与未尽事项

1. **未实测各调优项的真实效果**：本报告所有"预期收益"基于理论 + 01-5 已发现的 cluster_network=0 问题。需补测验证。
2. **未修复 cluster_network 后重测**：最有可能的调优项，但本任务未执行。
3. **CephFS+Rep3 在本集群 4972-5576 低于 01-4 的 6718**：原因未深究（pool 共享 / cluster 状态）。
4. **BeeGFS Stage3 数据是 2026-07-15 测的，与本任务（07-19）有时间差**：硬件状态可能略有不同，但同集群同硬件。
5. **未测 CephFS+EC4+2 全量基线**：仅 01-4 测了 randread（4608）。若要全面对比，需补测 EC 全量基线。

---

## 八、推荐补测项

| 补测项 | 目的 | 预期 |
|--------|------|------|
| 修复 cluster_network 后重测 layout/mseqwrite | 验证写类 +20-40% 预期 | 可能从 5039 → 7000-9000 |
| 修复 cluster_network 后重测 randread-256K | 看 public NIC 释放后读是否提升 | 可能 +5-10% |
| OSD cache 50G 后重测 randread r1 cold | 验证冷启动 +20-30% | r1 可能从 4972 → 6000+ |
| mount readahead=4M 后重测 seqread/mseqread | 验证顺序读 +5-15% | seqread 1133 → 1300 |
| Rep size=2 后重测写类 | 验证写 +30-50% | layout 5039 → 7000-9000 |

---

## 九、数据路径

- **CephFS+Rep3 全量基线**：`results/prod-01-5-.../cephfs-rep-baseline/{seqread,seqwrite,mseqread,mseqwrite,layout,randread-r{1,2,3},randread-64K-r{1,2,3},randread-1M-r{1,2,3},randwrite-analysis-r{1,2,3},randrw-analysis-r{1,2,3},randwrite-fresh-r{1,2,3},randrw-fresh-r{1,2,3}}/fio.txt + per-job bw_log`
- **BeeGFS Stage3 对照**：`/home/lilingfeng/beegfs-production/results/stage3-aligned-nolimit-20260715-155122/` + `stage3-summary.md`
- **进度日志**：`cephfs-rep-baseline/progress.log`
- **runner 日志**：`cephfs-rep-baseline/runner.log`
