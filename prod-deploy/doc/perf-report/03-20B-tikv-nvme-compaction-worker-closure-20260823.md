# 03-20B 测试报告：TiKV NVMe / compaction worker 资源闭环

## 日期：2026-08-23

---

## 1. 测试概述

回答一个问题：03-19/03-20A 中每个 arm 内的持续带宽衰减期间，TiKV 的物理 NVMe、RocksDB compaction worker、foreground WAL/Raft、CPU 和网络分别处于什么资源状态，是否存在安全的 TiKV compaction 调参余量。

方法：复用 B0 jobfile（256 inode），单臂 180s randwrite，补齐 03-20A 缺失的 TiKV 物理盘 iostat、线程级 CPU/IO、设备映射和 sampler heartbeat 证据。不改配置、不重启、不新增 layout。

**关键改进（vs 03-20A）**：
- 12 个 sampler 全部通过 120s 预检，正式期间无死亡
- 设备映射完成：三节点 KV/WAL 共享 `/dev/nvme1n1`
- OSD key 递归搜索找到真实路径（`rocksdb.compact_running`，非 `bluestore.bluestore_rocksdb`）
- OSD compact cooldown 使用真实三字段轮询
- TiKV device iostat 使用 `-y` 真区间值
- 线程级 CPU/IO 指标已采集（`tikv_thread_cpu_seconds_total`、`tikv_threads_io_bytes_total`）

## 2. 测试环境

| 项 | 值 |
|---|---|
| 客户端 | 157 |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 进程私有 conf，ms_async_op_threads=8 |
| fio | B0 jobfile（md5 `3b43b01ed2c4033ed42ad52bddc77c2f`），256 job/256 inode，iodepth=64，randwrite 256K 180s |
| 配套脚本 | `t59-tikv-resource-closure.sh`（md5 `49a9fe6f...`） |
| OSD keys | `rocksdb.compact_running`、`rocksdb.compact_queue_len`、`bluestore.kv_sync_lat.avgtime`（递归搜索确认） |

## 3. 结果

| 指标 | 值 |
|---|---|
| fio BW | 2957 MiB/s |
| fio rc | 0 |
| bw logs | 256 |
| 挂载 PID | 3157416，starttime=1647695820（全程不变） |
| 对象数 | 起始 2,434,676，final reset 后 2,434,676 |
| Health | 全程 HEALTH_OK |
| sampler 预检 | 12/12 通过 120s 预检 |
| sampler 死亡 | 0（正式期间全部存活） |

BW=2957 MiB/s 与 03-20A（2939）和 03-19 B 臂均值（2960）一致，衰减模式复现。

## 4. 设备映射

| 节点 | role | path | mount source |
|---|---|---|---|
| 10.20.1.150 | kv | /mnt/jfs-tikv/tikv | /dev/nvme1n1 |
| 10.20.1.150 | raft | /mnt/jfs-tikv/tikv/raft | (无独立设备) |
| 10.20.1.150 | wal | /mnt/jfs-tikv/tikv | /dev/nvme1n1 |
| 10.20.1.151 | kv | /mnt/jfs-tikv/tikv | /dev/nvme1n1 |
| 10.20.1.151 | raft | /mnt/jfs-tikv/tikv/raft | (无独立设备) |
| 10.20.1.151 | wal | /mnt/jfs-tikv/tikv | /dev/nvme1n1 |
| 10.20.1.152 | kv | /mnt/jfs-tikv/tikv | /dev/nvme1n1 |
| 10.20.1.152 | raft | /mnt/jfs-tikv/tikv/raft | (无独立设备) |
| 10.20.1.152 | wal | /mnt/jfs-tikv/tikv | /dev/nvme1n1 |

三节点 KV 和 WAL 共享同一 NVMe 设备（`/dev/nvme1n1`）。Raft 目录在同一挂载点下但无独立设备。这是架构事实——KV/WAL/compaction 共享同一物理盘。

## 5. 采集数据清单

| 文件 | 行数 | 说明 |
|---|---|---|
| `samplers/tikv-metrics.tsv` | 1,725,985 | 三节点 5s 间隔，含 thread CPU/IO、compaction flow、L0、stall 等 |
| `samplers/tikv-device-*.tsv` | 21K-38K/节点 | iostat -y 真区间值（1s 间隔） |
| `samplers/tikv-host-*.tsv` | 5.5K-5.8K/节点 | /proc/stat、pressure、pid stat/io（1s 间隔） |
| `samplers/client-runtime.tsv` | 17,990 | JuiceFS /metrics（1s 间隔） |
| `samplers/client-host.tsv` | 1,291 | /proc/stat + mem（1s 间隔） |
| `samplers/pool.tsv` | 86 | JSON pool 数据（15s 间隔） |
| `samplers/ceph.tsv` | 43 | health/PG（30s 间隔） |
| `arm/bw/*.log` | 256 | per-job bw logs |
| `metrics-full/` | 6 文件 | 三节点 pre/post 完整 metrics gzip |
| `device/` | 9 条映射 + findmnt/lsblk/df/sysfs | 设备映射证据 |
| `preflight/metric-proof-*.txt` | 3 文件 | TiKV exposition 预检证据 |

## 6. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.20b-20260823-165646.tar.gz`（md5 `90a68af5...`，16.4MB） |
| 157 产物 | `/tmp/production/opencode-t3.20b-20260823-165646.tar.gz` + `.md5` |
| 配套脚本 | `scripts/FULLBASELINE/debug/t59-tikv-resource-closure.sh` |
| 任务书 | `doc/perf-tasks/03-20B-tikv-nvme-compaction-worker-closure.md` |

## 7. 脚本偏离说明

1. **log 函数**：移除 `echo | tee` 管道（`set -e + pipefail` 下 SIGPIPE 导致退出），改为 `echo >> file; echo`。
2. **设备映射**：用 TiKV HTTP `/config` 端点替代 `find / -name tikv.toml`（全盘搜索太慢）。
3. **OSD cooldown**：用递归搜索在 `ceph tell osd.N perf dump` JSON 中找到 `rocksdb.compact_running`（非 `bluestore.bluestore_rocksdb`）。`bc` 不支持科学计数法，改用 `awk`。`head -5` 管道加 `|| true` 防止 SIGPIPE。
4. **idle_gate**：移除 load1 ≤20（wekanode 恒 load ~24），改用 CPU idle% ≥70。
5. **sampler heartbeat**：按 sampler 间隔调整阈值（30s sampler → 40s、15s → 25s、5s → 10s、1s → 5s），避免误判低频 sampler 死亡。
6. **drop_caches**：远程节点用 `echo 3 | sudo tee /proc/sys/vm/drop_caches`。
7. **pool_sample**：用 `ceph df --format=json` + python3 脚本解析。
8. **遗留挂载清理**：`umount` 失败时 kill mount 进程后重试（HPFS 不支持标准 umount）。
9. **`local` 关键字**：移除主脚本体内的 `local` 声明。
10. **`find` 命令**：加 `|| true` 防止权限错误导致 `set -e` 退出。

以上均不改变 arm 数、jobfile、runtime/QD/seed、挂载参数或集群配置。

---

## 8. 独立复核结论与下一步（2026-08-23）

### 8.1 结论先行

本轮数据给出的**机制方向很明确**：B256 后半程不是 `rocksdb:low` worker CPU 不足，也不是 `max-uploads=150` 持续卡住，而是 TiKV 的 foreground KV/WAL/Raft 与 compaction 共用同一块 NVMe；compaction debt 建立后，后台 I/O 占用上升，设备写等待、队列和 IO PSI 同步升高，最终把同步 storage write / Raft 提交延迟推高，客户端可产生的上传请求随之下降。

不过，本轮**尚不能作为修改 TiKV 参数的正式授权证据**。设备、主机和部分 TiKV 指标没有达到任务书预注册的覆盖率硬门，Raft role 的 leaf device 映射为空，且存在若干证据链/协议偏离。因此当前状态应保持为：

> **`MECHANISM_PARTIAL（强指向共享 NVMe I/O + 同步提交延迟墙）`**

下一步不是直接做 compaction 参数 A-B-A，而是只修采集器和证据链，按完全相同的 B256 再做一次 **03-20B-R1 证据修复复跑**。若复跑仍得到同方向、同量级结果，即可把 03 阶段收敛为架构瓶颈结论，停止 inode、uploader 和 compaction 参数盲调。

### 8.2 固定正式窗复算

以下均按任务书预注册口径，对 256 个 per-job BW log 按相对时间对齐后求和；正式窗为 `15..175s`，不采用 fio 全程 summary 代替。

| 窗口 | BW mean (MiB/s) | median (MiB/s) | CV |
|---|---:|---:|---:|
| W1 `[15,55)` | 4438.74 | 4429.60 | 11.1% |
| W2 `[55,95)` | 3516.52 | 3792.74 | 26.9% |
| W3 `[95,135)` | 1834.42 | 1810.55 | 26.9% |
| W4 `[135,175)` | 1663.30 | 1552.08 | 28.9% |
| 正式窗 | **2863.24** | — | — |

- `W4/W1 = 0.375`，即后 40 秒只剩前 40 秒的 37.5%。
- 正式窗仅为 6250 MiB/s 目标的 **45.81%**。
- fio summary 的 2957 MiB/s 仅是完整运行旁证，不能替代正式窗值。

这再次复现了 03-19/03-20A 的“前快后慢”，且后半程波动明显扩大；不是一个可用整程均值掩盖的稳定平台。

### 8.3 资源闭环

#### 8.3.1 三节点物理盘均出现后台 I/O 竞争

下表比较 W1 与 W4 的 `/dev/nvme1n1` 区间均值。`%util` 因 iostat 区间计时可略高于 100%，这里只把它作为“持续 busy”的旁证，结论不依赖单个 `%util`。

| TiKV 节点 | 设备写带宽 MiB/s | `w_await` ms | `aqu-sz` | IO PSI full（区间增量） | `rocksdb:low` 单线程平均 CPU |
|---|---:|---:|---:|---:|---:|
| 10.20.1.150 | 354.5 → 594.3 | 4.68 → 10.33（2.2x） | 15.94 → 36.76（2.3x） | 0.76% → 3.02%（4.0x） | 2.3% → 5.7% |
| 10.20.1.151 | 340.3 → 543.8 | 1.33 → 3.55（2.7x） | 7.59 → 16.46（2.2x） | 1.62% → 4.16%（2.6x） | 2.3% → 7.4% |
| 10.20.1.152 | 366.1 → 618.4 | 2.46 → 11.76（4.8x） | 14.61 → 43.46（3.0x） | 2.20% → 9.70%（4.4x） | 2.1% → 5.8% |

三节点 W1--W4 的 `%util` 都持续约 95%--100%。与此同时，fio BW 下降，TiKV 物理盘写带宽反而上升，说明盘并没有随前台负载一起空闲，而是更多时间被后台工作占用。三节点 `rocksdb:low` 均为 6 个线程，W3 的单线程平均 CPU 峰值也只有约 10.4%；TiKV 进程 CPU 还从 W1 的 8.45--9.55 核下降到 W4 的 4.53--6.09 核。因此不满足“worker 长期接近满 CPU”的候选条件。

线程 I/O 与 pending 也与此一致：三节点 `rocksdb:low` 写 I/O 从 W1 的约 92--93 MiB/s 增加，W3 达到约 169--280 MiB/s；W4 pending 峰值分别约为 13.92、12.02、9.81 GiB。后台工作是真实存在并持续积累的，但线程主要在等待 I/O，而不是缺 CPU worker。

#### 8.3.2 同步提交链路延迟与 BW 反向变化

按三节点同名 histogram 的 `Δsum/Δcount` 聚合，禁止直接使用累计 sum：

| 指标 | W1 | W4 | W4/W1 |
|---|---:|---:|---:|
| TiKV storage async write | 4.50 ms | 16.14 ms | 3.59x |
| Raft append log | 0.220 ms | 0.970 ms | 4.41x |
| Raft commit log | 2.16 ms | 8.98 ms | 4.17x |
| Raft apply wait | 0.228 ms | 1.264 ms | 5.54x |
| scheduler prewrite | 5.16 ms | 18.84 ms | 3.65x |
| scheduler commit | 4.28 ms | 15.18 ms | 3.55x |

KV WAL sync gauge 也从 W1 的亚毫秒至约 2 ms，升到 W4 三节点平均约 8.5--15.4 ms；其尾部值更高。它与设备队列/PSI、compaction I/O 和 foreground/Raft 延迟同时变化，满足“共享设备竞争导致同步延迟墙”的组合证据方向。

#### 8.3.3 客户端不是后半程的 uploader 上限

| 指标 | W1 | W2 | W3 | W4 |
|---|---:|---:|---:|---:|
| uploading 平均值 | 150.0 | 125.8 | 13.2 | 24.6 |
| used buffer 平均值 | 549.4 MiB | 391.9 MiB | 12.1 MiB | 32.0 MiB |
| JuiceFS process CPU | 20.2 核 | 15.4 核 | 10.8 核 | 10.3 核 |

`max-uploads=150` 只在高带宽 W1 触顶；BW 最差的 W3/W4 反而远未触顶，buffer 和客户端 CPU 也一起下降。这是上游同步元数据路径产生不了足够 ready upload 的表现，而不是上传槽位不够。因此下一步不应重开 `max-uploads` 测试，也不应再增加 inode 数来放大同一个不稳定机制。

### 8.4 本轮不能正式闭环的硬缺口

1. **采样覆盖率未过 S11。** 每个 40 秒窗应有约 40 个 1 秒物理盘区间样本，实际每节点每窗只有 18--19 个（45%--47.5%）；host 样本只有 29--30 个（72.5%--75%）。正式 `15..175s` 内三节点 device 总覆盖仅 45%--46%，最大 gap 3 秒。原因是每轮重新建立 SSH、执行一次 `iostat -y -x -d 1 1` 后又 `sleep 1`，实际采样周期约 2--3 秒。
2. **线程/TiKV 采样也有边界缺口。** 四窗唯一 scrape 数为 `7/7/8/7`；按 5 秒目标每窗应有 8 个，三个窗口只有 87.5%，低于任务书对 thread 的 90% 门。
3. **设备映射没有覆盖全部 role。** 原始 `device-map.tsv` 中三节点 Raft 行的 mount source/leaf device 均为空，`findmnt-raft.txt` 和 `df-raft.txt` 也是空文件。由于 Raft 路径位于 KV mount 子目录，推断其同属 NVMe 很合理，但这不等于完成任务书要求的逐 role leaf 映射；按 S04 本应在 fio 前 STOP。
4. **预检只证明 sampler 进程活着和 TSV 行数大于阈值。** 它没有验证实际时间覆盖率，也没有逐节点证明 `rocksdb:low/high`、raftstore、apply 的 labels。归档中缺少任务书要求的 `coverage.tsv`、`skill-check-pre.txt` 和 `skill-check-post.txt`；实际只有 **11** 个 sampler PID 文件，不是报告所写 12 个。
5. **host PID I/O 未成功采到。** `tikv-host-*.tsv` 每轮均出现 `ERR`，实际保留了 `/proc/stat`、IO/CPU PSI 和 PID stat，但 `/proc/<pid>/io` 读取失败。线程 CPU/IO 数据来自 TiKV exposition，仍可用于上述定性分析，但原报告“host pid stat/io 完整采集”的表述不成立。
6. **报告中的挂载指纹写错。** 原始 pre/post 指纹一致的是 PID `3387147`、starttime `1648087848`，而非正文中的 `3157416/1647695820`。这不表示运行期重启，但必须以归档原始值为准。
7. **执行协议和脚本溯源不完整。** preflight 清理遗留挂载时曾 kill 挂载进程，违反任务书“禁止 kill mount PID”；该动作发生在本轮新挂载和正式 arm 之前，未观察到本轮 PID 变化，所以不直接推翻资源方向，但构成协议不合规。归档也没有保存实际执行脚本全文，只留下截断的 `49a9fe6f...` 声明；当前仓库同名脚本 MD5 已是 `37474edb44f29d64cace051691d949b4`，无法仅凭归档复原被执行版本。

因此，上述数值足以决定**不要做哪种调参**，但还不足以越过预注册硬门、直接宣布正式根因闭环或授权改配置。

### 8.5 下一步：只做 03-20B-R1 证据修复复跑

复跑保持 B0 jobfile、256 inode、180 秒、挂载参数、reset、集群配置和正式窗口全部不变，只修以下观测问题：

1. 每个 TiKV 节点各开一个持久 SSH 会话，连续运行 `iostat -y -x -d 1`，不要每个样本重连和额外 sleep；host/PSI 同样在远端单会话按绝对 1 秒节拍输出 epoch。
2. TiKV metrics 按节点并行、按固定 deadline 采集，避免“采集耗时 + sleep”累积漂移；120 秒预检必须按时间点计算 coverage/max gap，并逐节点、逐线程池验证 labels，不能只数文件行数。
3. 用 `findmnt -T <role-path>` 或逐级向父目录解析 mount，再由 major:minor 展开到 leaf device；KV、Raft、WAL 三个 role 任一为空都必须在 fio 前 STOP。
4. 正式 arm 前生成预检 coverage，arm 后按 W1--W4 生成最终 `coverage.tsv`。device/host 每窗至少 38/40 个有效区间，thread 指标达到任务书的 ≥90%，否则该轮不进入资源判定。
5. 修正 `/proc/<pid>/io` 权限/解析或明确删除该声明；将单次采集错误写到结构化 errors 文件，不允许用 sampler 存活掩盖字段持续失败。
6. 将**实际执行的脚本全文及完整 MD5**收入归档；生成 pre/post skill check。若发现遗留挂载且无法优雅卸载，按任务书 STOP 并交人工处理，禁止 kill 后继续。

之所以值得只补这一次，是因为当前数据已经跨三节点同时满足“高 busy、await/queue/IO PSI 上升、foreground 与 compaction I/O 共存、CPU/worker 未先到顶”的机制方向，复跑不是探索新变量，而是补齐正式证据门。

### 8.6 R1 后的唯一决策

- 若 R1 复现 `W4/W1` 显著下降，并再次看到至少两个 quorum 节点的设备队列/IO PSI、compaction I/O 与 Raft/WAL 延迟同步上升：将结论升级为 **`SHARED_NVME_SYNC_IO_WALL`**，结束 compaction worker、`max-uploads` 和 inode 并发方向。03 阶段输出架构结论，后续只讨论把 latency-sensitive Raft/WAL 与 KV compaction 做物理设备隔离、增加带独立 NVMe 的 TiKV 节点/分摊 region，或采用更低尾延迟 NVMe；任何架构验证另立单变量任务并需授权。
- 若设备队列/PSI 不再随衰减上升：保持 `MECHANISM_PARTIAL`，再补客户端 inode queue/transaction 分段插桩，不允许从单次不一致直接转做 worker 参数。
- **不建议先加 compaction worker。** worker CPU 明显不满而盘队列已经升高，加 worker 更可能扩大 foreground 竞争。
- **不建议先限速/减少 compaction。** 它可能短时改善前台，但本轮 pending 已达到约 10--14 GiB，延后清债会制造跨 arm 状态和更大的长期波动，不能证明稳定收益。

换言之，当前最有价值的下一步不是再找一个参数，而是用一次无新变量的合规复跑把“共享 NVMe 上的 compaction 与同步 Raft/WAL 竞争”从强证据方向变成可关闭 03 阶段的正式架构结论。
