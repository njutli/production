# 03-18 测试报告：TiKV meta Write 延迟服务端归因采集

## 日期：2026-08-22

---

## 1. 测试概述

回答两个问题：
- **Q1（主问题）**：客户端 meta Write 延迟 138→187ms 增量落在 TiKV 哪一段（scheduler / storage / Raft / RocksDB）？
- **Q2（副问题）**：同挂载快态→慢态切换是否与 region/leader、compaction/cache、Raft 或主机资源事件同步？

方法：单挂载（三轮同 PID/starttime）randwrite 180s × 3 轮，全程采集客户端逐秒 meta 计数器 + 3 个 TiKV `:20180/metrics` 精确子集 + PD hotspot/stores + 3 节点主机资源 + 完整 metrics gzip 快照。不改任何生产配置、不调参、不重启服务。

## 2. 测试环境

| 项 | 值 |
|---|---|
| 客户端 | 157（oneasia-c1-cpu-node10） |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 进程私有 conf，`[client] ms_async_op_threads = 8` |
| 系统 ceph.conf md5 | `5b6be34179a64e0a5f9c6d3a9690041f`（起止一致） |
| fio | 3.28，randwrite，256K bs，128 jobs，iodepth=128，direct=1，180s |
| V4 脚本 | `/tmp/FULLBASELINE_V4.sh`，md5 `4198ea2676ba56744a3cd5eba17a5eab` |
| 对象闸门 | OBJ_START_MAX=2500000，OBJ_HARD_MAX=8000000 |
| 配套脚本 | `/tmp/t54-tikv-meta-latency-attribution.sh`，md5 `b8e9fc009ac29aae19e94044a4467826`（含 msgr 检查修复，见 §8） |

## 3. 执行序列

```
挂载并校验交付配置
  → 120s idle 采集（无 fio、无 preprobe）
  → V4 reset_state / deterministic_warmup
  → randwrite r1（180s）→ aggressive_cleanup
  → randwrite r2（180s）→ aggressive_cleanup
  → randwrite r3（180s）→ aggressive_cleanup
  → 收尾采集、卸载、打包
```

- V4 调用：`ITEMS=randwrite SKIP_REMOUNT=1 OBJ_GATE=1 OBJ_GC_PASSES=0 ... T54 180 3`
- 三轮为同一挂载 PID=1415911，starttime_ticks=1638697008，skip_remount=1

## 4. 结果

### 4.1 带宽

| 轮次 | fio 汇总 BW (MiB/s) | 逐秒均值 (MiB/s) | 状态 |
|---|---|---|---|
| r1 | 2577 | 2493 | VALID |
| r2 | 2558 | 2426 | VALID |
| r3 | 2513 | 2425 | VALID |

- 验收口径（逐秒均值 15-175s）：median=2426，极差幅度=2.8%，CV=1.6%，L2=PASS
- 参考口径：fio 汇总 median=2558，极差=2.5%；逐秒中位数 median=1923，极差=33.0%

### 4.2 延迟分布（fio summary）

| 轮次 | 250ms | 500ms | 750ms | 1000ms | 2000ms | ≥2000ms |
|---|---|---|---|---|---|---|
| r1 | 0.27% | 1.38% | 6.32% | 25.53% | 41.88% | 24.57% |
| r2 | 0.30% | 1.15% | 6.36% | 25.33% | 43.03% | 23.70% |
| r3 | 0.11% | 0.71% | 2.86% | 11.75% | 62.05% | 22.47% |

r3 延迟分布明显右移：2000ms 桶占比从 r1/r2 的 ~42% 升至 62%。

### 4.3 对象数

| 边界 | objects | stored |
|---|---|---|
| 起点 | 2,434,614 | 638,339,186,688 |
| r1 post-cleanup | 2,434,614 | 638,349,934,592 |
| r2 post-cleanup | 2,434,614 | 638,349,934,592 |
| r3 post-cleanup | 2,434,614 | 638,349,934,592 |

每轮 cleanup 后对象数回到起点，无泄漏累积。

## 5. 有效性验证

| # | 判据 | 结果 |
|---|---|---|
| V1 | 同一挂载 | PID=1415911 + starttime=1638697008 三轮不变；无 forced-mount |
| V2 | 配置生效 | exe md5=de93563f...；max_read=262144；proc CEPH_CONF 含 ms_async_op_threads=8 |
| V3 | 三轮负载完整 | 3/3 rc=0，384 个 per-job bw log（3×128） |
| V4 | 客户端计数完整 | write-meta-series.tsv 32394 行；jfsstats/threads/net/osdperf 齐全 |
| V5 | TiKV 核心指标 | 3 endpoints；scheduler/storage/Raft/RocksDB histogram sum/count + labels 全配对 |
| V6 | 状态边界 | 起点/cleanup 后 objects=2,434,614 ≤ 2.5M；轮内峰值完整 |
| V7 | 集群稳定 | 全程 HEALTH_OK；6 OSD up；PG 32 active+clean；up_from 未变 |
| V8 | 时间对齐 | phase-markers + series epoch + 三节点 remote_ts 可秒级对齐 |

## 6. 集群状态

- Ceph：HEALTH_OK（全程，health-series.tsv 1732 行，30s 间隔）
- Pool objects：2,434,614（起止一致）
- PG：33 active+clean，6 OSD up/in
- PG primary 分布：[0:6 1:6 2:5 3:6 4:5 5:4]（三轮一致）
- ceph.conf md5 起止一致：`5b6be341...`
- 无 JuiceFS 挂载残留

## 7. 采集数据清单

| 类别 | 文件 | 规模 |
|---|---|---|
| 客户端 meta 计数器 | `client/write-meta-series.tsv` | 32394 行 |
| 客户端 jfs stats | `client/i1-jfsstats-T54.tsv` | 51759 行 |
| 客户端 线程 CPU | `client/i2-threads-T54.tsv` | 3154 行 |
| 客户端 网络 | `client/i3-net-T54.tsv` + `i3-tikv-rtt-T54.txt` | 2646 + 2592 行 |
| OSD perf | `client/i4-osdperf-T54-{pre,post}-osd{0-5}.json` | 12 文件 |
| TiKV 精确子集 | `metrics-series/tikv-10.20.1.{150,151,152}_20180_metrics.prom.txt` | ~111 万行/节点 |
| TiKV 完整快照 | `metrics-full/tikv-*-{preflight,idle-post,post-load}.prom.gz` | 3 边界 × 3 节点 |
| PD metrics | `metrics-full/pd-*-{preflight,idle-post,post-load}.prom.gz` | 3 边界 × 3 节点 |
| PD 精确子集 | `metrics-series/pd-10.20.1.{150,151,152}_2379_metrics.prom.txt` | ~83-286 万行 |
| PD API | `pd-api/{hotspot_regions_write,hotspot_regions_read,hotspot_stores,stores}.jsonl` | 4 文件 |
| TiKV 主机 | `tikv-host/{identity-{pre,post},tikv-journal,10.20.1.*}.txt` | 12 文件 |
| fio bw logs | `v4/T54/randwrite-T54-r{1,2,3}/` | 384 个 |
| metrics-errors.log | 空（0 errors） | — |
| pd-api/errors.log | 空（0 errors） | — |

## 8. 脚本修复记录

### 问题

t54 脚本原 msgr 验证方式为检查 `/proc/$PID/task/*/comm` 中线程名 `msgr-worker` 的数量是否等于 8。但 Go 运行时会将所有线程名覆盖为二进制名（`juicefs-03-8`），导致计数恒为 0。此问题在历次测试（03-17b~g）中均存在，但此前脚本不做此检查，故未暴露。

### 修复

将 msgr 验证从线程名计数改为 CEPH_CONF 文件内容校验：
- 读取 `/proc/$PID/environ` 获取 `CEPH_CONF` 路径
- 检查该 conf 文件中 `ms_async_op_threads = 8` 是否存在

此修复不改变实验变量（msgr=8 配置未变），仅修正验证方法。修复后脚本 md5：`b8e9fc009ac29aae19e94044a4467826`。

## 9. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.18-20260822-145137.tar.gz`（md5 `684f3616...`，33.8MB） |
| 157 产物 | `/tmp/production/opencode-t3.18-20260822-145137.tar.gz` + `.md5` |
| V4 全目录 | `/tmp/opencode-fullbaseline-v4/`（157，已恢复） |
| 旧 V4 备份 | `/tmp/opencode-fullbaseline-v4.pre-t54-20260822-145137`（157，禁止删除） |
| 任务书 | `doc/perf-tasks/03-18-tikv-meta-latency-attribution.md` |

## 10. skill 合规声明

1. 未执行 pool delete/create、destroy、format、layout、OSD/TiKV/PD restart。
2. 未修改 `/etc/ceph/ceph.conf`，起止 md5 一致；只使用进程私有 msgr=8 conf。
3. 每个 fio 前 V4 已执行 health/PG gate 与四节点 drop cache；写后已走一次 aggressive cleanup/compact。
4. 三轮为同一 PID/starttime，无 forced-mount。
5. 384 个 bw logs、fio 原文、客户端/TiKV/PD/对象/主机指标均已打包。
6. 偏离：t54 脚本 msgr 检查方法修复（§8），已回传 diff 和新 md5；其余无偏离、无缺件。

---

## 12. 附录：并发调参对照实验（03-18b）

### 12.1 实验设计

基于 03-18 的采集与分析，追加一组对照实验，验证两个外部可调参数对写侧性能的影响：

| 参数 | 03-18（基线） | 03-18b（对照） |
|---|---|---|
| `--max-uploads` | 150 | **300** |
| TiKV URL `max-tso-batch-wait-interval` | 默认（0） | **1ms** |
| TiKV URL `open-tso-follower-proxy` | 默认（false） | **true** |
| 其余参数 | 不变 | 不变 |

二进制、ceph.conf、msgr=8、fio 参数、矩阵（3 轮 randwrite 180s）、V4 脚本均不变。配套脚本 `t55-tikv-concurrency-tuning.sh`（md5 `fd1c1b2384c0a8ca7b75a8ef89d3bb37`），仅改 META URL 和 MOUNT_OPTS 两行。

mount.log 确认参数生效：
```
Enabling TSO Follower Proxy
Set MaxTSOBatchWaitInterval to 1ms
```

### 12.2 结果

#### fio 汇总带宽

| 轮次 | 03-18 (MiB/s) | 03-18b (MiB/s) | 变化 |
|---|---|---|---|
| r1 | 2577 | 2622 | +1.7% |
| r2 | 2558 | 2595 | +1.4% |
| r3 | 2513 | 2605 | +3.7% |
| median | 2558 | 2605 | +1.8% |

#### 验收口径（逐秒均值 15-175s）

| 轮次 | 03-18 (MiB/s) | 03-18b (MiB/s) | 变化 |
|---|---|---|---|
| r1 | 2493 | 2495 | +0.1% |
| r2 | 2426 | 2457 | +1.3% |
| r3 | 2425 | 2509 | +3.5% |
| median | 2426 | 2495 | +2.8% |
| 极差 | 2.8% | 2.1% | 改善 |
| CV | 1.6% | 1.1% | 改善 |
| L2 | PASS | PASS | — |

#### 逐秒中位数稳定性

| 指标 | 03-18 | 03-18b |
|---|---|---|
| 逐秒中位数 median | 1923 | 1880 |
| 逐秒中位数 极差 | 33.0% | **4.9%** |

逐秒中位数极差从 33.0% 降至 4.9%，说明调参后每秒带宽波动大幅收敛。

#### 延迟分布（fio summary，r3）

| 桶 | 03-18 r3 | 03-18b r3 |
|---|---|---|
| ≤250ms | 0.11% | 0.24% |
| 500ms | 0.71% | 1.37% |
| 750ms | 2.86% | 5.87% |
| 1000ms | 11.75% | 27.21% |
| 2000ms | 62.05% | 36.80% |
| ≥2000ms | 22.47% | 28.41% |

2000ms 桶从 62% 降至 37%，延迟分布左移。

### 12.3 环境验证

| 项 | 值 |
|---|---|
| PID | 1750997，starttime=1639503648（三轮不变） |
| exe md5 | de93563f11a5ff3bd94dd25a4e0283b1 |
| max_read | 262144 |
| msgr | proc CEPH_CONF 含 ms_async_op_threads=8 |
| 对象数 | 2,434,614（起止一致，每轮 cleanup 后回到起点） |
| Health | 全程 HEALTH_OK |
| PG | 32 active+clean，primary [0:6 1:6 2:5 3:6 4:5 5:4]（三轮一致） |
| bw logs | 384 个（3×128） |

### 12.4 结论

`--max-uploads 300 + max-tso-batch-wait-interval=1ms + open-tso-follower-proxy=true` 带来：
- fio 汇总 median +1.8%（2558→2605）
- 逐秒均值 median +2.8%（2426→2495）
- 逐秒中位数极差 33.0%→4.9%（稳定性大幅改善）
- R3（最差轮）改善最大：+3.7%（2513→2605）

收益来源主要是 TSO 批量等待和 follower proxy 降低了 TSO 获取开销，以及 `--max-uploads 300` 增加了并发上传管线深度。但改善幅度有限（~2-3%），未改变快态→慢态切换的基本模式。

### 12.5 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.18-20260822-170603.tar.gz`（md5 `135bb3f7...`） |
| 157 产物 | `/tmp/production/opencode-t3.18-20260822-170603.tar.gz` + `.md5` |
| 配套脚本 | `scripts/FULLBASELINE/debug/t55-tikv-concurrency-tuning.sh`（md5 `fd1c1b23...`） |
| 任务书 | 同 03-18（`doc/perf-tasks/03-18-tikv-meta-latency-attribution.md`） |

---

## 13. 独立复核补充：客户端排队、TiKV 事务周期与 inode 并行度（2026-08-22）

> 本章基于 §9/§12.5 所列两份 03-18/03-18b 原始归档、03-17f 的 NB8 原始归档、客户端/TiKV 指标和 JuiceFS 源码进行独立复算。它补答 §1 的 Q1/Q2，并对 §12.4 的因果表述作证据等级修正；若二者冲突，以本章为准。

### 13.1 结论先行

1. 客户端观测到的 meta `Write` 约 186--201 ms，**不是 TiKV 单次服务时间**。该计时从等待每 inode 的 `f.Lock()` 之前开始，因此包含同 inode 上大量已完成数据写的排队等待。
2. 更接近底层同步事务周期的是客户端 `transaction` 约 12.8--13.5 ms；TiKV 端 prewrite 约 5.9--6.3 ms、commit 约 4.7--5.1 ms，与客户端事务周期数量级闭合。
3. 当前 randwrite 为 128 个 job 对应约 128 个持续活跃文件/inode。每 inode 同时只能推进一个 meta `Write`，所以一阶吞吐模型为“活跃 inode 数 ÷ 单通道事务周期”。当前 128-inode 慢态的 2.4--2.5 GiB/s 与该模型吻合。
4. 即使采用 03-17f 捕获到的快态事务周期 9.97 ms，128 inode 也只能达到约 3.2 GiB/s。6250 MiB/s 要求每通道周期约 5.1--5.6 ms，已低于当前快态；因此**当前 128-inode 验收布局不能靠小参数调优达标**。
5. 这不是“JuiceFS 任意工作负载都只能到 2.5--3.3 GiB/s”。在共享资源尚未饱和、事务延迟不随负载上升的区间，带宽应随**同时活跃 inode 数**近似线性增长；这是架构边界，不是原 128-inode 测试项的调优结果。
6. 03-18 三轮全部处于慢态，没有捕获 03-17f 的快→慢切换瞬间。因此 Q2 的具体触发事件仍未直接观测到；但该残余问题不影响“128-inode 同步事务架构无法达到 6250 MiB/s”的判定。

### 13.2 客户端延迟预算复算

以下数值由各轮 `jfs-stats-pre.txt` / `jfs-stats-post.txt` 的 histogram `sum/count` 增量计算：

| 批次 | 轮次 | 有效 BW (MiB/s) | meta `Write` 平均延迟 (ms) | transaction 平均延迟 (ms) | PUT 平均延迟 (ms) |
|---|---|---:|---:|---:|---:|
| 03-18 | r1 | 2493 | 201.394 | 13.274 | 6.296 |
| 03-18 | r2 | 2426 | 197.312 | 13.469 | 6.489 |
| 03-18 | r3 | 2425 | 186.156 | 12.801 | 7.897 |
| 03-18b | r1 | 2495 | 198.823 | 13.050 | 11.371 |
| 03-18b | r2 | 2457 | 197.737 | 13.152 | 10.995 |
| 03-18b | r3 | 2509 | 200.636 | 13.309 | 10.296 |

03-18 三轮的 `meta_ops_total_Write / fuse_ops_total_write` 为 0.9144--0.9154，轮间基本不变。也就是说，带宽差异不是由“每个应用写触发了更多 meta Write”造成。

`Write` 平均延迟约为 transaction 的 14--16 倍，不能把前者直接拆分或归因到某一个 TiKV scheduler/storage/Raft 子阶段。它表示的是一个逻辑 `Write` 从进入客户端 meta 层、等待本 inode 前序提交，到完成自身事务及后处理的总时间。

按 Little 定律，约 9--9.5K/s 的 meta `Write` 速率乘以 186--201 ms，得到约 1700--1900 个在飞/排队的逻辑 `Write`；除以 128 个活跃 inode，相当于每条 inode 通道平均约 13--15 个请求等待。该结果解释了为什么 13 ms 的事务周期会被放大成约 190 ms 的逻辑 `Write` 延迟。

### 13.3 TiKV 服务端分段复算

以下平均延迟由三台 TiKV 在各轮稳态窗口（fio 第 15--175 秒）的 histogram `sum/count` 增量聚合计算：

| 轮次 | scheduler prewrite (ms) | scheduler commit (ms) | storage async write (ms) | Raft commit (ms) |
|---|---:|---:|---:|---:|
| r1 | 5.947 | 4.804 | 5.046 | 3.110 |
| r2 | 6.285 | 5.119 | 5.358 | 3.219 |
| r3 | 5.894 | 4.661 | 4.957 | 2.989 |

辅助证据同向：

- 三轮 `tikv_engine_pending_compaction_bytes` 采样均为 0，没有 compaction backlog。
- 聚合 block-cache miss ratio 约为 r1 6.8%、r2 8.4%、r3 5.5%；r2 略差而 r3 恢复，不存在随轮次持续恶化的 cache 双态。
- PD 写热点分散在大量 region，三轮 store load 的 `max/min` 中位数约 1.17--1.25；三 store 均为 Up、`slow_score=1`，没有单 store/单 region 热点墙。
- TiKV 自身 `process_cpu_seconds_total` 显示三节点合计平均仅使用约 7 个 CPU 核，远低于三节点总 CPU 配额；没有 CPU 容量饱和证据。

因此 Q1 的准确回答是：**约 190 ms 的 client meta `Write` 不能落到单个 TiKV 子阶段，主要增量在客户端每 inode 队列；队列的服务周期则由约 10--13 ms 的同步 TiKV 事务决定。** TiKV prewrite/commit/Raft 是这个服务周期的组成部分，但 03-18 没有发现服务端容量饱和、compaction 或单点热点。

### 13.4 源码路径与 128 条串行通道

审阅的源码路径为 `/tmp/opencode/juicefs-03-8`。关键调用链如下：

1. `pkg/vfs/writer.go:181-201`：每个完成的数据 slice 最终调用 `m.Write(...)` 提交元数据。
2. `pkg/meta/base.go:1685-1696`：`defer m.timeit("Write", time.Now())` 在 `f.Lock()` 之前执行；同 inode 的 `Write` 在 open-file lock 上串行，计时包含锁等待。
3. `pkg/meta/tkv.go:808-820`：`transaction` histogram 在 `kvMeta.txn` 内计时，更接近取得 inode 通道后实际执行的同步事务周期。
4. `scripts/FULLBASELINE/FULLBASELINE_V4.sh:944-951`：randwrite 使用 `--numjobs=128`，fio 生成 `storage_test.0.0` 至 `storage_test.127.0`，即 128 个独立文件/inode；每 job 的 `iodepth=128` 只会在对应 inode 后形成更深队列，不会解除 `f.Lock()` 的串行化。

这给出一个经数据验证的一阶模型：

```text
BW(N) ≈ min(
  N_active_inode × 256 KiB / T_serial_transaction,
  TiKV / Ceph / 客户端 CPU / 网络等共享上限
)
```

模型成立的前提是每个 inode 都持续有待处理请求，且增加 inode 后事务延迟尚未因共享资源排队而上升。

### 13.5 03-17f 快慢态的交叉验证

03-17f NB8 是同一挂载、同一二进制、同一配置内连续三轮，能够排除重挂落位和配置差异：

| 轮次 | BW (MiB/s) | meta `Write` (ms) | transaction (ms) | 以 r1 事务反比预测的 BW (MiB/s) |
|---|---:|---:|---:|---:|
| r1 快态 | 3274 | 136.62 | 9.97 | 3274（锚点） |
| r2 慢态 | 2639 | 172.27 | 12.36 | 2641 |
| r3 慢态 | 2659 | 179.30 | 12.69 | 2573 |

r2 的预测值与实测仅差 2 MiB/s；r3 相差约 3.3%。这说明快→慢态带宽变化主要可由单通道 transaction 周期 9.97→12.36/12.69 ms 解释。与此同时，逻辑 `Write` 因队列积累从 136.62 ms 放大到 172--179 ms。

03-18 三轮 transaction 均为 12.8--13.5 ms，因此本批只复现了慢态，没有捕获切换瞬间。具体是什么因素让底层事务周期从约 10 ms 变为约 13 ms，仍缺少同一批快态 TiKV 服务端分段数据，不能强行归因到 cache、region 或 Raft；但即使恢复 9.97 ms 快态，目标仍不可达。

### 13.6 6250 MiB/s roofline 与 inode 数的关系

6250 MiB/s、256 KiB 写入对应：

```text
6250 MiB/s ÷ 0.25 MiB/write = 25,000 logical writes/s
```

在 128 条串行 inode 通道下，若近似每个 logical write 需要一次事务，则单通道允许的周期为：

```text
128 ÷ 25,000 = 5.12 ms
```

若按实测 meta `Write / fuse write = 0.914--0.915` 修正，外层 meta `Write` 通道允许的周期约为 5.6 ms。无论采用哪个口径，都显著低于当前慢态 12.8--13.5 ms，也低于历史快态 9.97 ms。

在事务延迟保持不变、共享层尚未饱和的理想条件下，可作如下边界估算：

| 状态 | 事务周期 | 128 inode | 256 inode 理论值 | 达到 6250 所需活跃 inode |
|---|---:|---:|---:|---:|
| 当前慢态 | 约 13 ms | 实测约 2426 MiB/s | 约 4850 MiB/s | 约 325--335 |
| 历史快态 | 约 9.97 ms | 实测 3274 MiB/s | 约 6550 MiB/s | 约 245--250 |

因此，“randwrite 是否随 inode 数成正比”的答案是：**在低于共享瓶颈的平台前，近似成正比；越过平台后不再成正比。** 增加静态文件总数无效，必须增加测试窗口内同时活跃、且各自有足够待处理写请求的 inode 数。

该推论也限定了架构结论的适用范围：当前结论是“128-active-inode 的既定测试布局受 per-inode 同步串行事务限制”，不是“任意多 inode 的 JuiceFS randwrite 都只能达到当前带宽”。将活跃 inode 数改为 256/512 可以作为架构边界对照，但改变了验收工作负载，不能据此宣告原 128-inode 测试项达标。

### 13.7 对 03-18b 因果结论的证据等级修正

03-18b 同时改变了三个变量：`max-uploads 150→300`、`max-tso-batch-wait-interval=1ms`、`open-tso-follower-proxy=true`；实验顺序为先 03-18、后 03-18b，没有随机区组或 A-B-A，因而无法区分参数效应与时间漂移，也无法把收益分配给某个参数。

更关键的是，客户端机理指标没有出现与“TSO/上传并发优化”一致的改善：

| 指标（三轮中位数） | 03-18 | 03-18b | 变化 |
|---|---:|---:|---:|
| 有效 BW (MiB/s) | 2426 | 2495 | +2.8% |
| meta `Write` (ms) | 197.312 | 198.823 | +0.8%（略差） |
| transaction (ms) | 13.274 | 13.152 | -0.9%（近似不变） |
| PUT (ms) | 6.489 | 10.995 | +69.4%（变差） |

TiKV 服务端 prewrite/commit/storage/Raft 延迟在 03-18b 也与 03-18 基本相同。因此 §12.4 的“收益主要来自 TSO 批量等待、follower proxy 和 max-uploads”**证据不足，应降级为未经因果确认的探索性现象**。+2.8% 不能作为固化三项参数的依据，尤其不能用于解释仍有约 2.5 倍的目标缺口。

在没有单变量、同批交错/ABBA 和对应机理指标改善前，交付候选仍应保持 `max-uploads=150` 与默认 TiKV URL 参数；本阶段不建议为该 2--3% 现象继续消耗机器时间。

### 13.8 主机采样证据的限制

T54 的 TiKV host 辅助采样存在三处实现问题：

1. `t54-tikv-meta-latency-attribution.sh:197` 在同一条 `local` 命令中声明 `ip` 和使用 `${ip}` 生成 `out`，展开时取到的是函数外残留值，三台 host loop 实际写入同一个 `10.20.1.152.txt`，内容交错；§7 所称三节点独立 host 时序不成立。
2. `ps ... pcpu` 是进程自启动以来的平均 CPU，不是当前采样间隔 CPU。
3. `iostat -x -d 1 1` 的唯一一份输出是 since-boot 首报，不是 1 秒区间值；若后续复用，应改为跳过首报的区间采样方式。

因此 host 文件不能用于逐节点 CPU/磁盘时间归因，§5 的相关完整性应降级，§7 文件清单也应更正。该问题不推翻本章结论，因为 CPU 判定采用 TiKV Prometheus 的 `process_cpu_seconds_total`，核心延迟采用 TiKV histogram，二者均为三 endpoint 独立采集。

### 13.9 阶段判定与下一步

1. **关闭 B1/F49 的“缺 TiKV 服务端指标”阻塞项**：03-18 已拿到有效指标。决策树选择分支 3+4——客户端每 inode 队列放大逻辑延迟，同时同步 TiKV 事务周期无法满足 128-inode 目标预算。
2. **停止普通 TiKV/cache/region/max-uploads 参数扫描**：没有服务端容量饱和证据；即使回到历史快态也只有约 3.27 GiB/s，不能填平到 6.25 GiB/s 的缺口。
3. **输出架构分析交付物**：若必须保持 128-active-inode 验收语义，候选方向只能是减少每次写的同步事务数（批量/合并 meta 提交），或在保持顺序与一致性的前提下允许同 inode 有序流水/并行。增加独立 inode/分片属于工作负载或架构变化，只能作为边界对照。
4. **可选的最小因果确认**：若评审要求直接测量锁等待，只需在 `baseMeta.Write` 中把 `f.Lock()` 等待、`doWrite/transaction` 服务和后处理分别计时，执行一次短 randwrite；无需再跑完整七项基线或继续盲扫参数。
5. **最终长稳**：文档和交付参数收口后，在 `de93563f + max-fuse-io=256K + 私有 msgr=8 + max-uploads=150 + 默认 TiKV URL` 上执行不少于 8 小时的稳定性签收。03-18b 的三项组合在因果确认前不进入长稳候选。
