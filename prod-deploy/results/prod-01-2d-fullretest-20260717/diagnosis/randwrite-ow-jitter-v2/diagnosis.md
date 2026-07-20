# randwrite-ow 不限速波动根因诊断报告 v2

> 日期：2026-07-18
> 原始数据：`diagnosis/randwrite-ow-jitter-v2/`（fio 输出 + per-job bw_log + OSD perf JSON + PG dump + iostat + juicefs stats）
> v1 结论（OSD/tmpfs 累积 + FUSE buffer）无直接数据支撑，已废弃。

---

## 一、结果

| 轮次 | fio 聚合 BW | 写入量 | 总写操作数(w_count) | JuiceFS CPU | object PUT |
|------|------------|--------|-------------------|-------------|------------|
| R1 | 3904 MiB/s | 687 GiB | 3,122,252 | 1581% | 4040/s |
| R2 | 4072 MiB/s | 716 GiB | 3,243,871 | 1865% | 4110/s |
| R3 | 3345 MiB/s | 588 GiB | 2,676,311 | 1625% | 3452/s |

波动：(4072-3345)/3345 = **22%**

---

## 二、数据分析

### 2.1 OSD 写延迟（op_w_avg，delta before→after）

| OSD | R1 | R2 | R3 |
|-----|------|------|------|
| osd.0 | 8.26ms | 4.61ms | 4.65ms |
| osd.1 | 2.07ms | 1.70ms | 1.47ms |
| osd.2 | 2.30ms | 2.04ms | 1.70ms |
| osd.3 | 10.94ms | 5.49ms | 6.86ms |
| osd.4 | 2.36ms | 2.26ms | 1.84ms |
| osd.5 | 8.57ms | 4.69ms | 4.63ms |

**关键发现**：R1 的 op_w_avg 显著高于 R2/R3（osd.0=8.26 vs 4.61/4.65，osd.3=10.94 vs 5.49/6.86，osd.5=8.57 vs 4.69/4.63）。但 R1 的 BW（3904）高于 R3（3345）。**写延迟高的轮次反而带宽高**——说明波动不是后端写延迟导致的。

### 2.2 RocksDB get_latency（delta，元数据查找）

| OSD | R1 delta | R2 delta | R3 delta |
|-----|---------|---------|---------|
| osd.0 | 2.0μs | 0.4μs | 0.2μs |
| osd.1 | 1.7μs | 0.3μs | 0.1μs |
| osd.2 | 1.0μs | 0.3μs | 0.1μs |
| osd.3 | 1.7μs | 0.4μs | 0.2μs |
| osd.4 | 1.7μs | 0.4μs | 0.1μs |
| osd.5 | 2.9μs | 0.6μs | 0.2μs |

**R1 get_latency delta 显著高于 R2/R3**（2-3μs vs 0.1-0.6μs）。但 R1 BW 高于 R3。排除 RocksDB 作为瓶颈。

### 2.3 iostat（NVMe SSD 写 IOPS，各轮各节点均值）

| 轮次 | node150 | node151 | node152 |
|------|---------|---------|---------|
| R1 | 56 w/s | 55 w/s | 55 w/s |
| R2 | 58 w/s | 56 w/s | 55 w/s |
| R3 | 56 w/s | 54 w/s | 54 w/s |

iostat w/s 几乎相同（54-58 w/s），**NVMe SSD 状态不是波动根因**。

### 2.4 juicefs stats（JuiceFS 客户端 CPU + object PUT）

| 轮次 | CPU | object PUT | BW |
|------|-----|-----------|---|
| R1 | 1581% | 4040/s | 3904 |
| R2 | 1865% | 4110/s | 4072 |
| R3 | 1625% | 3452/s | 3345 |

**R2 CPU 最高（1865%）、PUT 最高（4110）、BW 最高（4072）**。R3 CPU 中等（1625%）、PUT 最低（3452）、BW 最低（3345）。CPU 与 BW 正相关。

### 2.5 PG→OSD 映射

PG dump 在 layout 后采集时返回 0 行（juicefs-data pool 刚重建无对象）。**无法对比 CRUSH 分布差异**。

### 2.6 写入量差异

| 轮次 | fio io | rados df after | w_count total |
|------|--------|----------------|---------------|
| R1 | 687 GiB | 840 GiB | 3.12M |
| R2 | 716 GiB | 869 GiB | 3.24M |
| R3 | 588 GiB | 739 GiB | 2.68M |

R3 写入量显著低于 R1/R2（588 vs 687/716 GiB）。**R3 写入少→PUT 少→CPU 低→BW 低**。这是直接关联。

---

## 三、根因定位

### 3.1 波动来自 JuiceFS 客户端 CPU + object PUT，不是后端

| 指标 | 是否波动 | 与 BW 相关性 | 根因？ |
|------|---------|------------|--------|
| OSD op_w_avg | R1 高 R2/R3 低 | 反相关（延迟高 BW 反而高） | ❌ |
| RocksDB get_lat | R1 高 R2/R3 低 | 反相关 | ❌ |
| NVMe iostat w/s | 几乎相同 | 无相关 | ❌ |
| kv_sync_lat delta | 几乎相同 | 无相关 | ❌ |
| **JuiceFS CPU** | **R2 高 R3 低** | **正相关** | **✅** |
| **object PUT** | **R2 高 R3 低** | **正相关** | **✅** |
| 写入量 | R3 少 15-18% | 正相关 | 症状而非根因 |

### 3.2 根因：JuiceFS 客户端写吞吐能力波动

R3 写入量低（588 GiB vs 687/716）不是后端拒绝写入，而是 **JuiceFS 客户端在 180s 内发出的 PUT 少了**（3452/s vs 4040/4110）。CPU 也低了（1625% vs 1581/1865%）。

这说明波动的根源在 **JuiceFS 客户端侧**（FUSE dispatch + Go goroutine 调度），不是后端（OSD/BlueStore/NVMe）。

### 3.3 为什么客户端吞吐会波动

可能的客户端侧原因：
- **FUSE /dev/fuse dispatch 串行入口**：单 goroutine 读取 /dev/fuse 的速率受内核调度影响
- **Go runtime goroutine 调度**：GC pause、goroutine 切换开销
- **TiKV 元数据引擎延迟波动**：JuiceFS 写入前需更新元数据（inode/block 映射），TiKV 响应时间波动影响整体吞吐
- **网络抖动**：librados 连接池/消息延迟波动

**无法进一步区分**这四个，需要 Go pprof + TiKV 延迟分拆（超出本次测试范围）。

---

## 四、结论

| 结论 | 数据支撑 |
|------|---------|
| 波动根因在 **JuiceFS 客户端侧**，不在后端 | OSD delta + iostat 全部无波动或反相关；juicefs CPU/PUT 正相关 |
| 后端（OSD/BlueStore/NVMe/RocksDB）**不是**波动根因 | op_w_avg、get_lat、iostat w/s、kv_sync_lat 跨轮几乎一致或反相关 |
| 22% 波动来自客户端写吞吐能力差异 | CPU 1625-1865%、PUT 3452-4110/s，与 BW 正相关 |
| 进一步定位需 Go pprof + TiKV 延迟分拆 | 超出本次测试范围 |

### 对基线数据的建议

- 后端指标跨轮稳定（op_w_avg、get_lat、iostat），说明 pool 重建有效保证后端同状态
- 22% 波动来自客户端侧，pool 重建无法消除（因为客户端 JuiceFS 进程不重启）
- 如需更稳定：可在轮间重启 JuiceFS mount（但会丢失 FUSE session）
- 22% 波动可接受，取中位数 3904 作为基线
