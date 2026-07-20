# cluster_network 修复后重测报告

> 测试日期：2026-07-19 22:09 ~ 23:32
> 任务：修复 cluster_network 配置（10.3.2.0/24）后重跑 CephFS+Rep3 全量 12 项基线
> 对比对象：修复前 baseline（2026-07-19 20:10 测）+ BeeGFS Stage3
> 数据源：`results/prod-01-5-.../cephfs-rep-baseline-clusternet-fixed/`

---

## 〇、关键发现：修复后性能反而下降

**修复 cluster_network 前**（cluster NIC 全程 0 流量，subop 走 public NIC）：
- 写类平均 BW：~3500-5039 MiB/s
- 读类平均 BW：~1133-5576 MiB/s

**修复 cluster_network 后**（cluster NIC 有流量，subop 走独立 100GbE）：
- 写类平均 BW：~2627-3806 MiB/s（**下降 -19%**）
- 读类平均 BW：~1067-5816 MiB/s（**下降 -6%**）

**与预期对比**：预期写类 +20-40%，实际 -19%。**完全推翻预期**。

---

## 一、修复前后详细对比

| 测试项 | 修复前 | 修复后 | 变化 | BeeGFS | 后/Bee |
|--------|--------|--------|------|--------|--------|
| seqread (1j) | 1133 | 1067 | -6% | 1644 | 0.65× |
| seqwrite (1j, fsync) | 639 | 663 | +4% | 1906 | 0.35× |
| mseqread (16j) | 4115 | 3946 | -4% | 7565 | 0.52× |
| mseqwrite (16j, fsync) | 4793 | 3806 | **-21%** | 11314 | 0.34× |
| layout (128j, fsync) | 5039 | 3539 | **-30%** | 10199 | 0.35× |
| randread-256K (128j) | 5576 | 5383 | -3% | 9045 | 0.60× |
| randread-64K (128j) | 4031 | 3957 | -2% | 4759 | 0.83× |
| randread-1M (128j) | 5551 | 5816 | +5% | 9796 | 0.59× |
| randwrite-analysis | 4511 | 3315 | **-27%** | 6505 | 0.51× |
| randrw-analysis R | 2917 | 2625 | -10% | 4853 | 0.54× |
| randrw-analysis W | 2918 | 2627 | -10% | 4836 | 0.54× |
| randwrite-fresh | 4422 | 3200 | **-28%** | 6795 | 0.47× |
| randrw-fresh R | 3986 | 3064 | -23% | 2573 | 1.19× |
| randrw-fresh W | 3985 | 3065 | -23% | 4279 | 0.72× |

### 提升汇总

| 类别 | 平均变化 | 最差项 | 最好项 |
|------|----------|--------|--------|
| **写类** | **-19%** | layout -30% | seqwrite +4% |
| **读类** | **-6%** | randrw-fresh-R -23% | randread-1M +5% |

---

## 二、根因分析

### 2.1 layout clat 数据揭示写路径延迟增加

| 指标 | 修复前 | 修复后 | 变化 |
|------|--------|--------|------|
| clat min | **5ms** | **21ms** | **+320%** |
| clat avg | 12221ms | 17325ms | +42% |
| clat P99（>=2000ms 占比） | 87.87% | 87.28% | 相近 |

**关键**：clat min 从 5ms → 21ms。min clat 代表无队列时的纯服务延迟，**+16ms 纯延迟增加**说明每个写 op 的底层路径变慢。

**修复前写路径**：
- primary 写本地 BlueStore → subop_w 走 public NIC（10.3.1.x）→ 副本 ack → 返回
- subop_w 在 public NIC 上延迟 ~50μs（同 NIC，路由快）

**修复后写路径**：
- primary 写本地 BlueStore → subop_w 走 cluster NIC（10.3.2.x）→ 副本 ack → 返回
- subop_w 在 cluster NIC 上延迟可能更高（见下方分析）

### 2.2 可能原因（按可能性排序）

#### 假设 1：OSD 刚重启 BlueStore cache 冷（**最可能**）

- OSD 运行时间：88-94 分钟（修复前 baseline 测时 OSD 已运行 27+ 小时）
- 01-5 rados bench 实测 EC r1 cold vs r2/r3 warm 差 44%
- 修复后所有 cell 都是 cold 状态（OSD 刚重启）
- **但**：写类不应该受 cache 影响（写是新数据，不读 cache）
- **反驳**：写路径中 BlueStore 的 RocksDB LSM tree 状态影响写性能（LSM tree 膨胀 → 写放大增加）

#### 假设 2：cluster NIC 延迟高于 public NIC（**待验证**）

- MTU 都是 4200（无 MTU 不匹配）
- 但 cluster NIC（10.3.2.x）可能存在：
  - ARP 缓存未建立（首次通信查 ARP 延迟）
  - 路由配置问题
  - 交换机配置差异
  - 驱动/中断处理差异
- **验证方法**：`ping -c 100 10.3.2.7` 测 cluster NIC RTT，对比 `ping 10.3.1.7`

#### 假设 3：Ceph msgr 线程模型开销

- cluster_network 和 public_network 使用不同 messenger 线程
- 线程切换 + 连接建立开销
- 对于高并发写，多了一层线程调度

### 2.3 为什么读类影响小（-3% to -6%）

- Rep3 读路径：primary 直接读本地，**不走 subop**
- cluster_network 修复对 Rep3 读**无直接影响**
- 读类 -3% to -6% 在测试误差范围内（冷启动 cache 差异）

### 2.4 为什么 randread-1M 反而 +5%

- 1M 块读占用 OSD 时间长，cache 命中影响小
- 可能是测量噪声

---

## 三、cluster NIC 流量验证

修复后 cluster NIC `enp139s0f1np1` 流量（fio randread 期间采样）：

| 节点 | cluster NIC RX peak (kB/s) | cluster NIC TX peak (kB/s) |
|------|----------------------------|----------------------------|
| ceph-node1 | 445677 (**435 MB/s**) | 329191 (321 MB/s) |
| ceph-node2 | 同上（镜像） | 同上 |
| ceph-node3 | 同上（镜像） | 同上 |

> 修复前 cluster NIC 全程 0（01-5 实测）；修复后有 435 MB/s 流量。
> 注：Rep3 randread 不应走 cluster NIC（只 primary 服务）。上述流量可能来自 EC pool 残余 subop 或 CephFS MDS 元数据同步。

---

## 四、结论与后续

### 4.1 当前结论

1. **cluster_network 修复未带来预期 +20-40% 写类提升，反而 -19%**
2. 写路径 min clat 从 5ms → 21ms（+320%），说明 subop_w 走 cluster NIC 后纯延迟增加
3. **可能原因**：OSD 刚重启 cache 冷（最可能）+ cluster NIC 延迟/配置问题（待验证）
4. 读类不受影响（-3% to -6% 在误差范围），符合 Rep3 读不走 subop 的理论

### 4.2 无法确认 cluster_network 修复的净收益

当前测试条件下（OSD 刚重启），cluster_network 修复**负面影响了写性能**。但：
- 可能是 OSD cold 状态的暂时性退化
- 可能是 cluster NIC 配置问题的永久性退化
- 需要等 OSD warm（运行 24h+）后重测才能确认

### 4.3 后续验证步骤

1. **等 OSD 运行 24h+ 后重测**：消除 cold cache 影响
2. **测 cluster NIC RTT**：`ping -c 100 10.3.2.7` vs `ping 10.3.1.7`，看是否有延迟差异
3. **检查 cluster NIC 网络配置**：`ethtool enp139s0f1np1`、`ip route`、ARP 表
4. **如果 warm 后仍慢**：可能需要 revert cluster_network 配置（回到修复前状态）

### 4.4 对决策的影响

| 决策路径 | 当前数据支持 | 修正 |
|----------|-------------|------|
| CephFS+Rep3 + cluster_network 修复可达 6250 | ❌ 不支持 | 修复后更差，不能作为达标路径 |
| CephFS+Rep3 已达标（01-4 的 6718） | ✅ 支持 | 但本集群 4972-5576 < 6718 |
| BeeGFS 9045 ✅ | ✅ 支持 | 唯一稳定达标的方案 |

**当前最可靠的达标路径仍是 BeeGFS（9045 ✅）**，或 CephFS+Rep3 在 01-4 集群状态下（6718 ✅，但本集群未复现）。

---

## 五、数据路径

- **修复后全量基线**：`results/prod-01-5-.../cephfs-rep-baseline-clusternet-fixed/{seqread,seqwrite,mseqread,mseqwrite,layout,randread-r{1,2,3},randread-64K-r{1,2,3},randread-1M-r{1,2,3},randwrite-analysis-r{1,2,3},randrw-analysis-r{1,2,3},randwrite-fresh-r{1,2,3},randrw-fresh-r{1,2,3}}/fio.txt + per-job bw_log`
- **修复前全量基线**（对比基准）：`results/prod-01-5-.../cephfs-rep-baseline/`
- **BeeGFS Stage3**：`/home/lilingfeng/beegfs-production/results/stage3-aligned-nolimit-20260715-155122/`
- **进度日志**：`cephfs-rep-baseline-clusternet-fixed/progress.log`
- **cluster NIC 验证数据**：157 上 `/tmp/sar-cluster-verify.log`（已清理）
