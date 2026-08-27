# 03-20A 测试报告：TiKV 轮内 compaction/写路径最小归因

## 日期：2026-08-23

---

## 1. 测试概述

回答一个问题：03-19 中每个 arm 内的持续带宽衰减（前段 ~3.3-4.2 GiB/s → 后段 ~1.5-1.8 GiB/s），是否与 TiKV compaction debt、RocksDB/storage 或同步 Raft 写路径同步。

方法：复用 03-19 的 B0 jobfile（256 inode），单臂 180s randwrite，全程采集扩展 TiKV 指标（compaction flow、L0 文件数、stall 原因、rate limiter）+ 客户端 /metrics + JSON pool + TiKV host iostat。不改配置、不重启、不新增 layout。

## 2. 测试环境

| 项 | 值 |
|---|---|
| 客户端 | 157 |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 进程私有 conf，ms_async_op_threads=8 |
| fio | B0 jobfile，256 job/256 inode，iodepth=64，randwrite 256K 180s |
| 配套脚本 | `t58-tikv-inrun-compaction-attribution.sh`（md5 `2e0624cf...`） |

## 3. 结果

| 指标 | 值 |
|---|---|
| fio BW | 2939 MiB/s |
| fio rc | 0 |
| bw logs | 256 |
| 挂载 PID | 1854854，starttime=1647112688（全程不变） |
| 对象数 | 起始 2,434,677，final reset 后 2,434,677 |
| Health | 全程 HEALTH_OK |

BW=2939 MiB/s 与 03-19 的 B 臂均值（2960 MiB/s）一致，衰减模式复现。

## 4. 采集数据清单

| 文件 | 行数 | 说明 |
|---|---|---|
| `samplers/tikv.tsv` | 532,761 | 三节点 5s 间隔，含 compaction flow/L0/stall 等扩展指标 |
| `samplers/jfs-runtime.tsv` | 20,258 | 客户端 /metrics 1s 间隔 |
| `samplers/client-host.tsv` | 1,453 | /proc/stat + mem 1s 间隔 |
| `samplers/pool.tsv` | 96 | JSON pool 15s 间隔 + 硬看门 |
| `samplers/ceph.tsv` | 48 | health/PG 30s 间隔 |
| `arm/bw/*.log` | 256 | per-job bw logs |
| `metrics-full/` | 6 文件 | 三节点 pre/post 完整 metrics gzip |

## 5. 证据限制

1. **`.stats` 文件未找到**：`find` 未定位到 JuiceFS `.stats` 文件，`jfs-stats.tsv` 缺失。客户端 per-op 计数从 `/metrics` HTTP 端点获取（`jfs-runtime.tsv`），包含 `meta_ops_duration_seconds_Write`、`transaction_durations_histogram_seconds` 等关键指标，与 03-18 口径一致。
2. **部分 sampler 在 fio 运行期间退出**：日志显示多次 "WARN: sampler died"。TiKV host iostat sampler 可能未覆盖全程。但主 TiKV metrics（532K 行）和客户端 /metrics（20K 行）覆盖完整。
3. **OSD cooldown 简化**：Ceph 版本不导出 `compact_running`/`compact_queue_len`，cooldown 仅检查 `kv_sync_lat.avgtime < 2ms`（始终通过，值 ~0.00007s）。
4. **idle_gate 简化**：因 157 有 13 个 wekanode 进程恒占 load ~24，移除了 load1 ≤20 检查，改用 CPU idle% ≥70。移除了 TiKV CPU 差分检查。

## 6. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.20a-20260823-141414.tar.gz`（md5 `1a708980...`，5MB） |
| 157 产物 | `/tmp/production/opencode-t3.20a-20260823-141414.tar.gz` + `.md5` |
| 配套脚本 | `scripts/FULLBASELINE/debug/t58-tikv-inrun-compaction-attribution.sh` |
| Jobfile | 同 03-19（`t56-gen-jobfiles.sh` 生成的 B0.fio） |
| 任务书 | `doc/perf-tasks/03-20A-tikv-inrun-compaction-attribution.md` |

## 7. 脚本偏离说明

1. **Ceph health 兼容**：`HEALTH_OK`（下划线）而非 `HEALTH OK`（空格）。
2. **OSD count**：改用 `ceph osd stat` 替代 `ceph osd dump | grep`。
3. **OSD cooldown**：`compact_running`/`compact_queue_len` 在此 Ceph 版本不存在，简化为固定 30s 等待 + `kv_sync_lat` 检查。`bc` 不支持科学计数法，改用 `awk` 比较。
4. **drop_caches**：远程节点用 `echo 3 | sudo tee /proc/sys/vm/drop_caches`。
5. **idle_gate**：移除 load1 ≤20（wekanode 恒 load ~24），改用 CPU idle% ≥70。移除 top/TiKV CPU 差分检查。
6. **pool_sample**：改用 `ceph df --format=json` + python3 解析，修复 `rados df` 列偏移。
7. **find 命令**：`find /home` 权限错误导致 `set -e + pipefail` 退出，加 `|| true` 保护。
8. **local 关键字**：移除主脚本体（非函数内）的 `local` 声明。
9. **遗留挂载清理**：`umount` 失败时 kill mount 进程后重试（HPFS 不支持标准 umount）。

以上均不改变 arm 数、jobfile、runtime/QD/seed、挂载参数或集群配置。

---

## 8. 独立复算与下一步建议（2026-08-23）

### 8.1 校正性能口径

前文的 `2939 MiB/s` 是 fio 整轮汇总值，不能代替阶段计划规定的稳态窗口指标。按 256 份 per-job 带宽日志重新汇总，并以共同有效区间起点为 `t=0`，得到：

| 指标 | 复算结果 |
|---|---:|
| job 日志数 | 256 |
| job 起始偏差 | 不超过 1s |
| 正式窗口 `[15,175]` 均值 | **2827.87 MiB/s** |
| 正式窗口中位数 | 3101.48 MiB/s |
| 正式窗口 CV | 43.64% |
| P10 / P90 | 1288.50 / 4490.75 MiB/s |
| 目标 6250 MiB/s 达成率 | **45.25%** |

40s 分窗结果如下：

| 窗口 | 平均带宽 (MiB/s) | 窗口内 CV |
|---|---:|---:|
| W1 `[15,55)` | 4201.24 | 13.58% |
| W2 `[55,95)` | 3658.06 | 11.64% |
| W3 `[95,135)` | 1951.99 | 34.12% |
| W4 `[135,175]` | 1532.58 | 22.12% |

`W4/W1=0.365`，明确命中预注册的衰减判据 `W4/W1 <= 0.70`。这是继 03-19 的 8 个 arm 后，第 9 个呈现“前快后慢”方向的 arm。因此衰减是可重复现象，不是一次性的布局、预热或随机噪声。正式窗口均值约 2828 MiB/s，也与 03-19 的 B256 档位一致；本轮没有证明有效带宽得到提升。

### 8.2 TiKV 指标与衰减的时间关系

将 fio 时间轴与三台 TiKV 的约 5s 采样对齐后，正式窗口内有 29 个可用区间。下表带宽按 TiKV 采样区间重新聚合，因而与上一节的严格 1s 分窗略有差异。

| 指标（三节点合计或均值） | W1 | W2 | W3 | W4 | 变化 |
|---|---:|---:|---:|---:|---|
| 对齐带宽 (MiB/s) | 4255 | 3662 | 2031 | 1603 | 持续下降 |
| storage async write 平均延迟 (ms) | 4.03 | 11.69 | 13.72 | 16.70 | 持续升高 |
| scheduler prewrite 平均延迟 (ms) | 4.64 | 13.65 | 16.36 | 19.77 | 持续升高 |
| scheduler commit command 平均延迟 (ms) | 3.82 | 11.02 | 12.79 | 15.62 | 持续升高 |
| Raft commit 平均延迟 (ms) | 1.91 | 6.01 | 7.59 | 9.24 | 持续升高 |
| Raft apply wait 平均延迟 (ms) | 0.22 | 0.76 | 1.34 | 1.39 | 持续升高 |
| compaction read (MiB/s) | 164 | 1089 | 1294 | 1000 | 负载后快速放大 |
| compaction write (MiB/s) | 28 | 426 | 948 | 875 | 负载后快速放大 |
| pending compaction bytes 合计 (GiB) | 5.18 | 14.32 | 21.53 | 20.63 | 累积至约 20GiB |
| TiKV 进程 CPU（核） | 26.2 | 21.2 | 19.1 | 15.9 | 随吞吐下降 |

正式窗口内，带宽与 storage async write、prewrite、commit、Raft commit、Raft apply wait 延迟的相关系数分别约为 `-0.79/-0.80/-0.78/-0.82/-0.87`；与 compaction write flow、pending compaction bytes 的相关系数约为 `-0.72/-0.71`。相关性只表示这些现象在同一时间轴上共同恶化，不能单独证明因果方向。

现有证据支持如下近端链条：

1. 写入开始后 compaction 流量和 compaction debt 快速增大；
2. 同期 TiKV/Raft 同步事务链路延迟从约 4ms 档上升到 15--20ms 档；
3. randwrite 的 inode 请求完成速率受同步元数据事务完成速率约束，事务延迟升高后，客户端不能持续产生足够的数据写入；
4. fio 带宽随之下降。

客户端指标与此一致：W1 的 uploader 基本维持 150、buffer 约 549MiB；到 W3/W4，uploader 均值分别降至约 29/14，buffer 降至约 41/12MiB，而客户端 CPU 空闲率反而升高。后半程不是 `max-uploads=150` 把数据面压住，而是上游同步元数据完成变慢后，没有足够请求供 uploader 发送。因此当前证据不支持继续增大 `max-uploads`，也不支持直接把 inode 并发从 256 扩到 512。

### 8.3 能排除什么，尚不能证明什么

本轮三个 TiKV 节点上：

- `engine_write_stall_microseconds` 没有增长；
- write-stall reason 没有出现；
- scheduler throttle flow 为 0；
- rate limiter 没有观测到非零限速；
- default CF 的 L0 文件最高分别约为 12/14/16，低于 slowdown trigger 20；
- 单节点 pending compaction bytes 最高约 15.25GiB，仅约为 192GiB soft limit 的 7.9%。

所以，这不是 RocksDB 达到配置阈值后触发的正式 write stall、rate limit 或 slowdown。`pending compaction bytes` 增长说明后台产生了债务，但不能据此直接推出“应当提高 compaction 并发”。

同样，也还不能声称“TiKV NVMe 已经物理饱和”。本轮关键主机采集器在 fio 期间退出，归档中缺少 TiKV 主机 `iostat`、`/proc/diskstats`、TiKV 进程 I/O 和 RocksDB worker 运行状态；`jfs-stats.tsv` 也缺失。现有数据只能确定 TiKV 同步链路延迟和 compaction 活动与衰减共同发生，无法区分以下两条分支：

1. foreground WAL/Raft 与 compaction 竞争同一组物理 NVMe，盘时延或队列已经到达极限；
2. 盘仍有余量，但 RocksDB compaction worker 数量或后台调度能力不足，债务累积并间接拖慢前台事务。

因此本轮应定性为：

- **性能现象有效**：fio、布局、挂载 PID、对象数回收和集群健康证据完整，且衰减再次复现。
- **近端归因有效**：可定位到 TiKV/Raft 同步事务延迟上升，并确认它与 compaction 活动增强共同发生。
- **资源根因归因不完整（`MECHANISM_PARTIAL`）**：缺 TiKV 主机盘和 compaction worker 的运行期证据，本轮不能授权参数修改。

另外，前文称相关 OSD 字段“此 Ceph 版本不存在”与 03-18 同集群证据不一致；03-18 曾采到 `rocksdb.compact_running`、`rocksdb.compact_queue_len` 和 `bluestore.kv_sync_lat.avgtime`。更可能是本轮解析路径或 key 兼容问题，03-20B 应修正解析，不能继续用固定等待 30s 代替 cooldown 判定。

执行中正常卸载失败后 kill 挂载进程，虽然发生在测量和最终 reset 之后、不影响本 arm 的性能结论，但违反任务书的稳定性约束。后续不得把强杀作为自动清理路径；正常卸载失败时应保留现场并停止。

### 8.4 下一步：03-20B 只补齐资源归因，暂不调参

建议下一项任务为 **03-20B TiKV NVMe / compaction worker 资源闭环**。只重放一次固定 B256 arm，保持 03-20A 的 jobfile、384 文件布局、256 活跃 inode、挂载参数、reset 和时间窗全部不变；不改 JuiceFS/TiKV 参数、不重启服务、不重新 layout，也不增加并发。

原因是性能形态已经重复 9 次，再增加重复次数或 inode 并发不会回答“盘饱和还是 worker 不足”；立即改 compaction 参数则会同时改变资源竞争和系统状态，在缺少基线资源证据时无法解释结果，也可能引入新波动源。

03-20B 必须先修好并验证采集链，再允许 fio 启动：

1. **采集器空载预检**：load 前连续运行 60--120s，确认所有采集 PID 存活，且时间戳和输出文件持续增长；任一核心采集器退出即 `STOP`，不得仅打印 warning 后继续。
2. **每台 TiKV 的真实 NVMe**：采集准确设备名上的 `iostat -y -x -d 1 1`、`/proc/diskstats`、`/proc/stat`，并采集 TiKV PID 的 `/proc/<pid>/io`。必须得到 `r/s`、`w/s`、读写 MiB/s、`await`、`aqu-sz/avgqu-sz` 和 `%util` 时间序列。
3. **RocksDB/TiKV worker**：采集 `tikv_thread_cpu_seconds_total`、`tikv_threads_io_bytes_total` 和 `tikv_threads_state`，至少区分 `rocksdb:low`、`rocksdb:high`、raftstore、apply 等线程池，判断 compaction worker 是否长期全忙且固定在并发上限。
4. **保留已验证的 TiKV 指标**：继续采集 storage async write、prewrite/commit、Raft append/commit/apply、compaction flow、pending bytes、L0、stall、throttle 和 rate-limit 指标，保持相同标签聚合方法。
5. **客户端指标完整性**：HTTP `/metrics` 可以替代缺失的 `.stats`，但须在预检确认所需 family 存在，并同时保存 duration 的 `sum` 与 `count`，避免只能看累计时间而不能计算单次延迟。
6. **恢复正确的静稳门**：TiKV CPU idle 使用 30s delta 判定；OSD cooldown 使用实际存在的上述三个字段。Weka 环境可以不使用 `load1`，但不能用固定等待代替可观测 cooldown。
7. **硬看门**：fio 期间任一核心 sampler 退出，立即终止 fio 并判该 arm 无效。
8. **可复现归档**：归档实际执行脚本、完整命令、配置快照及 md5，不能只保留 `.pid` 文件。
9. **安全清理**：只允许正常卸载；失败时停止、采证并上报，不允许 kill 挂载进程。

### 8.5 03-20B 后的预注册决策树

| 03-20B 证据 | 结论与动作 |
|---|---|
| 各 TiKV NVMe 长时间高 `%util`、高 `await`/队列；compaction I/O 与前台 WAL/Raft I/O 并存；CPU/worker 未先达到上限 | 判为共享 NVMe I/O 墙。停止参数盲调，形成架构结论：同步复制的元数据事务与 compaction 共享物理盘。接近 6250MiB/s 需要扩展/分片元数据面、使用更快或隔离的 NVMe，或从架构上减少同步事务频率。 |
| NVMe 有明确余量；`rocksdb:low` 等 compaction worker 长期全忙并固定在并发上限；pending debt 持续增长；仍无 stall/throttle | 才授权独立、单变量的 TiKV compaction 并发 A/B/A 或 ABBA 实验。具体参数和值由 03-20B 观察到的线程池和当前配置决定，本报告不预选。 |
| NVMe 有余量，compaction worker 也未饱和，但 Raft fsync/commit 延迟和队列持续升高 | 判为同步 Raft/WAL 提交路径限制，不做 compaction 参数实验；转向 Raft/WAL 设备隔离、节点/region 架构或减少同步事务频率的分析。 |
| 上述资源均稳定且无对应事件 | 再补 JuiceFS 客户端内部 inode 队列、锁等待、重试和事务分阶段指标；在此之前不增加 inode 数。 |

只有当 03-20B 证明后半程 uploader 仍持续顶在 150，且客户端、TiKV、数据网卡均有可验证余量时，才值得重新讨论 `max-uploads` 或 512 inode。当前 W3/W4 的 uploader 已明显低于上限，这个前提并不成立。

综上，下一步不是增加并发，而是用一次不改配置的 B256 重放补齐 TiKV 物理盘与后台 worker 证据。它能把当前的 `MECHANISM_PARTIAL` 收敛为可操作的两类结论：若存在可调的 compaction 并发瓶颈，再做严格单变量调优；若是共享 NVMe 或同步 Raft/WAL 的物理边界，则停止局部参数试验，形成目标无法在当前架构和并发模型下达到的架构说明。
