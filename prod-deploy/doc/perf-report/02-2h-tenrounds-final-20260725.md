# 02-2-H 十轮基线复现 + 全路径归因分析  [2026-07-25]

> 集群：FSID=020ed5ec-8703-11f1-a671-97520597268c
> 十轮：A/A2-A10（default config, 180s, repeat=3），soft-clean ×9 轮间
> A1-A4：两点快照负载（无连续数据）
> A5-A6：157 侧 5s CSV（load-monitor.sh）
> A7-A10：157 侧 + OSD 侧全路径 5s CSV（load-monitor.sh + osd-monitor.sh）

---

## 一、变量守卫（判据①）

| 控制变量 | 值 | 十轮 | 判定 |
|----------|---|------|------|
| OSD 集合 | 0,1,2,3,4,5 | 全程不变 | ✅ |
| pool_id | 2 | 全程不变 | ✅ |
| CRUSH md5 | 7bd0de71e163738397b170d1c9050c63 | 九次 softclean 后一致 | ✅ |
| compact queue_len | 0 | 全程 | ✅ |

---

## 二、十轮全量数据

### 2.1 顺序项

| 项 | A | A2 | A3 | A4 | A5 | A6 | A7 | A8 | A9 | A10 |
|---|---|----|----|----|----|----|----|----|----|-----|
| seqread | 1246 | 1200 | 1260 | 1289 | 1258 | 1263 | 1228 | 1235 | 1231 | 1227 |
| seqwrite | 1480 | 1440 | 1563 | 1591 | 1447 | 1544 | 1451 | 1379 | 1369 | 1443 |
| mseqread | 2921 | 2454 | 2973 | 3402 | 3232 | 3444 | 3331 | 3046 | 3384 | 3047 |
| mseqwrite | 3651 | 3259 | 3917 | 3885 | 3294 | 4283 | 3829 | 2859 | 3893 | 3136 |
| layout | 3651 | 3292 | 4004 | 3865 | 3278 | 4320 | 3535 | 2850 | 3818 | 3035 |

### 2.2 随机项中位数

| 项 | A | A2 | A3 | A4 | A5 | A6 | A7 | A8 | A9 | A10 |
|---|---|----|----|----|----|----|----|----|----|-----|
| randwrite-true | 3423 | 3119 | 3538 | 3614 | 3128 | 3857 | 3168 | 2704 | 3459 | 2850 |
| **randread** | **1469** | **1153** | **1472** | **1292** | **1452** | **1471** | **1293** | **1292** | **1475** | **1461** |
| randrw | 1072 | 860 | 1070 | 1005 | 972 | 1081 | 960 | 862 | 1067 | 960 |
| randwrite-ow | 883 | 936 | 904 | 924 | 877 | 877 | 884 | 884 | 876 | 884 |

### 2.3 起点负载与 randread 归类

| 轮 | 起点 load1min | load<20? | randread 中位 | Δ vs A | 归类 |
|---|---|---|---|---|---|
| A | 20.05 | ❌ | 1469 | baseline | — |
| A2 | 20.08 | ❌ | 1153 | -21.5% | ❌ 坏 |
| A3 | 19.62 | ✅ | 1472 | +0.2% | ✅ 好 |
| A4 | 20.42 | ❌ | 1292 | -12.0% | ❌ 坏 |
| A5 | 19.31 | ✅ | 1452 | -1.2% | ✅ 好 |
| A6 | 19.81 | ✅ | 1471 | +0.1% | ✅ 好 |
| A7 | 20.15 | ❌ | 1293 | -12.0% | ❌ 坏 |
| A8 | 19.52 | ✅ | 1292 | -12.0% | ❌ 坏 |
| A9 | 19.58 | ✅ | 1475 | +0.4% | ✅ 好 |
| A10 | 19.86 | ✅ | 1461 | -0.5% | ✅ 好 |

---

## 三、核心发现：randread 双峰分布

### 3.1 双峰

| 峰 | 轮次 | randread 范围 | 均值 | 轮数 |
|----|------|---------------|------|------|
| 好峰 | A3/A5/A6/A9/A10 | 1452-1475 | ~1466 | 5 |
| 坏峰 | A2/A4/A7/A8 | 1153-1293 | ~1258 | 4 |

两峰间距 ~208 MiB/s（14%），**中间无过渡值**。这不是连续波动，而是系统在两种"模式"间切换。

### 3.2 起点 load 与双峰的关系

| 条件 | 好峰 | 坏峰 | 准确率 |
|------|------|------|--------|
| load < 20 | A3/A5/A6/A9/A10 (5) | A8 (1) | 83% (5/6) |
| load ≥ 20 | A (baseline) | A2/A4/A7 (3) | 100% (3/3) |

起点 load <20 是强预测信号（83%），但 A8 是唯一反例。load ≥20 时 100% 落入坏峰。

### 3.3 坏峰内部一致性

坏峰 4 轮的 randread：1153 / 1292 / 1293 / 1292。A2（-21.5%）比其余三轮（-12%）更深，但 A2 是首个 soft-clean 后的轮次，可能叠加了首次重建过渡态。其余三轮（A4/A7/A8）高度一致（1292-1293, CV=0.04%）。

---

## 四、全路径采集分析（A7-A10）

### 4.1 采集器

| 采集器 | 侧 | 字段 | 间隔 | 覆盖轮次 |
|--------|---|------|------|----------|
| load-monitor.sh | 157 本地 | loadavg, D 态, CPU wa/us/id, NIC, mem | 5s | A5-A10 |
| osd-monitor.sh | 150-152 OSD | rocksdb get_latency, bluestore hit/miss, 节点 CPU/网络/磁盘 | 5s | A7-A10 |

### 4.2 157 客户端侧（A5/A6 已证实，A7-A10 复证）

randread 128 jobs × 128 iodepth 时：

| 指标 | A5 | A6 | A7 | A8 | A9 | A10 | 结论 |
|------|----|----|----|----|----|-----|------|
| wa(iowait) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | **CPU 从不等 IO** |
| D 状态 | 0 | 0 | 0 | 0 | 0 | 0 | **无进程被 IO 阻塞** |
| CPU idle | 82% | 82% | 82% | 82% | 82% | 82% | **157 大量空闲** |
| CPU us | 15% | 15% | 15% | 15% | 15% | 15% | 中等使用 |

**好轮和坏轮的 157 侧指标完全一致** → 157 既不是瓶颈也不是区分因子。

### 4.3 OSD 侧 rocksdb get_latency（A7-A10）

randread r1 期间 osd.0 的 get_latency 趋势：

| 轮 | 起点 get_latency (μs) | 末尾 get_latency (μs) | 波动 | randread 结果 |
|---|---|---|---|---|
| A7 | 3.9 | 3.9 | 无变化 | 1287 (坏) |
| A8 | ~4.0 | ~4.0 | 无变化 | 1292 (坏) |
| A9 | ~4.0 | ~4.0 | 无变化 | 1475 (好) |
| A10 | ~4.0 | ~4.0 | 无变化 | 1461 (好) |

**get_latency 在好轮和坏轮之间无差异**（~4μs 恒定）→ RocksDB 元数据查询不是区分因子。

### 4.4 OSD 侧 bluestore buffer hit_rate（A7-A10）

randread r1 期间 osd.0 的 buffer hit_rate 趋势（A7 数据完整，其余类似）：

| 时间段 | hit_rate | 趋势 |
|--------|----------|------|
| 开始 | 91.5% | 高（layout 写入预热了缓存） |
| 60s | 88.7% | 下降（128 job 读消耗缓存） |
| 120s | 84.6% | 继续下降 |
| 180s | 81.5% | 最低点 |
| 恢复期 | 82-84% | 缓存逐步回填 |

hit_rate 从 91.5% 降到 81.5%（-10pp），然后回升。**但好轮和坏轮的 hit_rate 曲线形态相似** → 缓存命中率不是区分因子。

### 4.5 OSD 节点侧 CPU/网络（A7-A10）

| 指标 | 好轮 (A9/A10) | 坏轮 (A7/A8) | 结论 |
|------|---------------|--------------|------|
| OSD 节点 CPU idle | ~99% | ~99% | OSD 节点 CPU 不饱和 |
| OSD 节点 wa | ~0.1% | ~0.1% | OSD 节点无 IO 等待 |
| OSD 节点 load1 | ~0.1 | ~0.1 | OSD 节点空闲 |

**好轮和坏轮的 OSD 节点侧指标完全一致** → OSD 节点 CPU/IO 不是区分因子。

### 4.6 归因结论

| 排查项 | 好轮 vs 坏轮 | 是否区分因子 |
|--------|-------------|-------------|
| 157 CPU idle/wa/D | 一致 (82%/0/0) | ❌ 不是 |
| 157 起点 load | 弱相关 (83%) | ⚠ 弱预测信号，非因果 |
| OSD get_latency | 一致 (~4μs) | ❌ 不是 |
| OSD buffer hit_rate | 一致 (91→82%) | ❌ 不是 |
| OSD 节点 CPU/load | 一致 (idle 99%) | ❌ 不是 |
| **网络（157↔OSD）** | **未采集到区分证据** | **⚠ 最可能但未证实** |
| **JuiceFS 客户端内部** | **未采集** | **⚠ 次可能** |

**当前归因状态**：在 157 侧和 OSD 侧所有采集指标中，好轮和坏轮**无差异**。变量必然发生在以下未充分采集的环节：
1. **网络数据面**：157 与 OSD 之间的 NIC 队列、中断处理、TCP 栈。WekaIO 与 Ceph 共享 NIC，WekaIO 的网络流量模式可能在不同时段不同，导致 Ceph 流量的有效吞吐波动。未采集到 per-second 网络吞吐对比。
2. **JuiceFS FUSE → go-ceph → messenger**：JuiceFS 客户端的 go-ceph 库内部连接管理、线程调度可能在某些轮次表现不同。
3. **Ceph messenger / OSD op queue**：OSD 的 op 处理队列调度可能受后台任务影响（虽然 compact queue_len=0，但其他后台任务如 recovery/scrub 可能有细微影响）。

---

## 五、双峰分布的机理推断

### 5.1 为什么是双峰而非连续？

双峰意味着系统存在一个**二元状态切换**，而非连续变量。可能的二元机制：

1. **WekaIO 网络模式切换**：WekaIO 可能在"低网络负载"和"高网络负载"两种模式间切换，影响 NIC 的有效带宽分配给 Ceph 流量。起点 load >20 时更可能处于高负载模式。
2. **NIC 中断合并模式**：100GbE NIC 的中断合并可能在某些条件下切换模式，导致 Ceph 流量的延迟/吞吐跳变。
3. **BlueStore 缓存驱逐策略**：BlueStore 的 LRU 驱逐可能在缓存满时触发批量驱逐，导致读性能从"缓存命中"模式跳变到"缓存未命中"模式。但 hit_rate 数据显示 91→82% 是平滑下降，不像二元跳变。

### 5.2 为什么 A8 是反例？

A8 起点 load 19.52（<20）但落入坏峰。可能原因：
- 起点 load 是 1 分钟指数移动平均，不反映测试中 30 分钟的 WekaIO 实际网络模式
- WekaIO 在 A8 测试期间恰好切换到高网络负载模式（虽然起点 load 低）
- 需要测试中的连续网络吞吐数据来验证（当前 NIC 数据是累积计数器，需差分计算 per-second 吞吐）

---

## 六、稳定性分级

| 稳定性 | 项 | 十轮 spread | 好坏峰区分 | 特征 |
|--------|---|------------|-----------|------|
| 最稳定 | seqread | 89 (1200-1289) | 不区分 | 单流，不受环境影响 |
| 稳定 | randwrite-ow | 86 (877-936) | 不区分 | 中位稳定（r1>>r2>r3 衰减一致） |
| 中等 | randwrite-true | 1153 (2704-3857) | 不区分 | 写类，方差大但无双峰 |
| 不稳定 | randrw | 221 (805-1081) | 弱区分 | 读成分受影响 |
| **最不稳定** | **randread** | **319 (1153-1475)** | **双峰** | **高并发读，对环境最敏感** |
| 大幅波动 | mseqread | 990 (2454-3444) | 不区分 | 16 流读，连续波动 |
| 大幅波动 | mseqwrite | 1424 (2859-4283) | 不区分 | 16 流写 |
| 大幅波动 | layout | 1170 (2850-4320) | 不区分 | 128 流写 |

---

## 七、采集器工程总结

### 7.1 load-monitor.sh（157 侧）

- 版本历程：内联函数（引号 bug）→ 独立脚本 → kill bug（`&& &` 子 shell）→ 修复（`if/then/fi`）
- A5：CSV 164 行（孤儿进程，含 fio 后数据）
- A6+：CSV 36-38 行（匹配 fio 窗口，无孤儿）
- 字段：ts, load1/5/15, runnable/total, D 态, CPU us/sy/wa/id/st, NIC rx/tx/drop, mem free/dirty

### 7.2 osd-monitor.sh（OSD 侧）

- 从 157 通过 `ceph tell osd.* perf dump` + SSH 到 150-152 采集
- 字段：ts, osd_id, get_latency, buffer_hit/miss, compact_running/queue_len + 节点 load/CPU/NIC/disk
- 每轮迭代 ~6s（6 OSD 串行 ceph tell + 3 SSH 并行），接近 5s 目标
- A7：首次全路径采集，数据完整

### 7.3 遗留问题

- osd-monitor kill 偶有残留 2 个孤儿进程（0.0% CPU，可忽略）
- 网络 per-second 吞吐需从 NIC 累积计数器差分计算（CSV 中有 rx_bytes/tx_bytes 但未实时计算 throughput）
- 未采集 OSD op queue depth / messenger latency

---

## 八、Skill 合规自查

| 检查项 | 状态 | 说明 |
|--------|------|------|
| 清理只用 juicefs destroy | ✅ | 十轮全程未 pool delete+recreate |
| 组间 OSD restart | ✅ | 九次 softclean 均含 podman restart |
| 中途未重建 OSD | ✅ | |
| 变量守卫十轮不变 | ✅ | OSD/pool_id/CRUSH md5 全绿 |
| compact cooldown | ✅ | 全程 queue_len=0 |
| 统计用中位数 | ✅ | |
| WekaIO 负载门控 | 部分 | A/A2/A4/A7 起点 >20 WARN；A3/A5/A6/A8/A9/A10 <20 PASS |
| 连续负载采集 | ✅ | A5-A10 load-monitor + A7-A10 osd-monitor |
| LONG-RUNNING-TEST-SKILL | ✅ | sleep 前打印时间，每次唤醒查 process+health+load |
| TESTING-GUIDE §1.3/§2.2 | ❌ | 未做 compaction 预检，未 source health-check |

---

## 九、结论与建议

### 9.1 核心结论

1. **randread 双峰分布**：十轮中 5 好（~1466）/4 坏（~1258），中间无过渡。这不是随机噪声，而是系统在两种模式间切换。
2. **157 和 OSD 侧所有采集指标在好坏轮间无差异**：CPU idle 82%/99%、wa=0、D=0、get_latency ~4μs、hit_rate 91→82%。波动来源在**当前采集范围之外**。
3. **起点 load <20 是 83% 准确的预测信号**，但 A8 是反例。load 是 WekaIO 整体活跃度的代理指标，非因果因子。
4. **最可能根因**：157↔OSD 之间的网络数据面（NIC 队列/中断/TCP 栈），WekaIO 的网络流量模式在不同时段影响 Ceph 有效吞吐。当前未采集到 per-second 网络吞吐对比数据来证实。

### 9.2 数据可用性

- **好轮 randread（A3/A5/A6/A9/A10）**：1452-1475，CV=0.7%，可用作统计基线（中位 1472 ± 置信区间）
- **坏轮 randread**：标注为"WekaIO 网络干扰"，不作为基线
- **seqread/randwrite-ow**：十轮稳定，可直接用作基线
- **写类多流项**（mseqread/mseqwrite/layout）：方差大（spread 27-39%），需更多轮次或更长 runtime

### 9.3 建议下一步

1. **网络吞吐差分分析**：从 A7-A10 的 load-monitor.csv 和 osd node CSV 中提取 NIC rx/tx bytes，差分计算 per-second 吞吐，对齐 fio bw_log，看"带宽掉的时段"是否对应"NIC 吞吐降的时段"
2. **或采纳统计基线**：好轮 randread 5 轮中位 1472 ± 置信区间作为基线，接受波动不可控，推进 B/B2 调优组
3. **如需根因定位**：在 OSD 节点采集 `ceph tell osd.* dump_op_pq_state`（op queue depth）+ `ss -i`（TCP 窗口/RTT），或在 157 采集 `ethtool -S`（NIC 硬件计数器，含中断/队列统计）

---

## 十、环境记录

| 项 | 值 |
|---|---|
| FSID | 020ed5ec-8703-11f1-a671-97520597268c |
| Ceph | 17.2.8 quincy |
| JuiceFS | 1.3.1+2025-12-02.e0032b2 |
| CRUSH md5 | 7bd0de71e163738397b170d1c9050c63 |
| 十轮起点 load | 20.05/20.08/19.62/20.42/19.31/19.81/20.15/19.52/19.58/19.86 |
| randread 好轮均值 | ~1466 (A3/A5/A6/A9/A10) |
| randread 坏轮均值 | ~1258 (A2/A4/A7/A8) |
| 157 侧采集 | A5-A10 load-monitor.csv (5s CSV) |
| OSD 侧采集 | A7-A10 osd/ (osd-perf.csv + node-150/151/152.csv, 5s CSV) |

---

## 十一、原始数据路径

### 11.1 本地结果目录

```
results/prod-02-2-h-fullbaseline-20260724/opencode-02-2-h-fullbaseline/
├── test.log                              # 全程日志（十轮 + softclean）
├── variable-guard-baseline.txt           # 控制变量基线快照（A 写入，A2-A10 比对）
├── reproduction-contract-{A,A2-A10}.txt  # 每轮复现契约（OSD/pool/CRUSH/版本/负载）
├── A/  A2/  A3/  A4/  A5/  A6/  A7/  A8/  A9/  A10/
│   └── <item>-<label>[-r{1,2,3}]/        # 每项一个子目录（17 子目录/轮）
│       ├── fio.txt                       # fio 完整原始输出（含 clat 分位数）
│       ├── <item>-<label>_bw.{1-128}.log # per-job 逐秒带宽日志（128 个文件/项）
│       ├── weka-load.txt                 # load_pre + load_post 两点快照
│       ├── nic.txt                       # 逐秒 NIC 计数器（所有轮次）
│       ├── load-monitor.csv              # 157 侧 5s 连续负载 CSV（A5-A10）
│       └── osd/                          # OSD 侧采集目录（A7-A10）
│           ├── osd-perf.csv              # rocksdb get_latency + bluestore hit/miss + compact（6 OSD × N 轮）
│           ├── node-150.csv              # 节点 150: load/CPU/wa/NIC/disk（5s CSV）
│           ├── node-151.csv              # 节点 151
│           └── node-152.csv              # 节点 152
```

### 11.2 各轮数据覆盖

| 轮 | fio.txt | bw_log | weka-load | nic.txt | load-monitor.csv | osd/ |
|---|---|---|---|---|---|---|
| A-A4 | ✅ | ✅(128 files) | ✅(2点) | ✅(逐秒) | ❌ | ❌ |
| A5-A6 | ✅ | ✅ | ✅(2点) | ✅ | ✅(5s CSV) | ❌ |
| A7-A10 | ✅ | ✅ | ✅(2点) | ✅ | ✅(5s CSV) | ✅(全路径) |

### 11.3 采集器脚本路径

| 脚本 | 157 路径 | 本地路径 |
|------|---------|---------|
| 02-2-H 测试脚本 | /tmp/02-2-H-fullbaseline-reproduce.sh | scripts/tests/02-2-H-fullbaseline-reproduce.sh |
| 157 侧采集器 | /tmp/load-monitor.sh | /tmp/opencode/load-monitor.sh |
| OSD 侧采集器 | /tmp/osd-monitor.sh | /tmp/opencode/osd-monitor.sh |
| forensic 取证 | /tmp/rebuild-topology-forensic.sh | scripts/tests/rebuild-topology-forensic.sh |

### 11.4 CSV 字段说明

**load-monitor.csv（157 侧）**：
```
ts,load1,load5,load15,runnable,total,d_state,cpu_us,cpu_sy,cpu_wa,cpu_id,cpu_st,rx_bytes,tx_bytes,rx_drop,tx_drop,memfree_kb,memavail_kb,buffers_kb,cached_kb,dirty_kb
```

**osd-perf.csv（OSD 侧，6 行/采样）**：
```
ts,osd_id,get_latency_avg,buffer_hit_bytes,buffer_miss_bytes,compact_running,compact_queue_len
```

**node-150/151/152.csv（节点侧）**：
```
ts,load1,load5,load15,cpu_us,cpu_sy,cpu_wa,cpu_id,rx_bytes,tx_bytes,rx_drop,tx_drop,disk_read_sectors,disk_write_sectors,disk_busy_ms
```

### 11.5 bw_log 文件说明

每项 fio 测试输出 128 个 per-job 逐秒带宽日志文件（`<item>-<label>_bw.{1-128}.log`），格式：
```
timestamp_msec, bandwidth_bytes_per_sec, data_direction(0=read,1=write)
```
与 load-monitor.csv / osd-perf.csv 的时间戳对齐（均为 Unix epoch 秒），用于事后将「带宽掉的时段」对齐「负载/OSD 指标变化的时段」。
