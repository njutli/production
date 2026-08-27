# 03-20B-R2 测试报告：TiKV 共享 NVMe 架构瓶颈最终证据闭环

## 日期：2026-08-23

---

## 1. 测试概述

回答一个问题：在相同的 B256 衰减过程中，至少构成 Raft quorum 的两个 TiKV 节点是否同时满足：KV/Raft/WAL 映射到同一 leaf NVMe、W3/W4 设备 busy/await 上升、foreground 与 compaction I/O 同期、worker/CPU 未先到顶。

方法：复用 B0 jobfile（256 inode），单臂 180s randwrite，使用 GPT 预编写的 t61 脚本套件（主脚本 + remote sampler + local sampler + Python validator + offline gate0），13 路严格 sampler，120s 预检 + W1-W4 覆盖率硬门。

**结果：执行成功。BW=2978 MiB/s，fio rc=0，256 bw logs，覆盖率全 PASS（55/55 行 PASS，0 FAIL），13 sampler 全程无死亡。设备映射 9/9 role 全部解析到 leaf device（三节点 KV/Raft/WAL 均映射到 /dev/nvme1n1）。MANIFEST.md5 419/419 验证通过。**

## 2. 执行历史

本任务经历 5 次执行，前 4 次因脚本 bug 失败，第 5 次成功：

| 次序 | RUN_ID | 结果 | 失败原因 |
|---|---|---|---|
| 第 1 次 | 20260823-220127 | S03 STOP | `find_mount_pid` 的 `pgrep -f` 匹配多个 PID（juicefs mount -d fork 父子进程） |
| 第 2 次 | 20260823-220548 | S03 STOP | `stat -c '%n\t%i'` 在 157 上不解释 `\t` 转义，输出字面 `\t` 而非制表符 |
| 第 3 次 | 20260823-221556 | S04 STOP | `ssh` 在 while-read 循环内消费 fd 0 的 here-string 输入，导致只处理第一个 role |
| 第 4 次 | 20260823-223235 | S08 STOP | TiKV 进程以 root 运行，sunrise 用户无权读 `/proc/<pid>/stat`；`validate_preflight` 无 grace period 导致最后一个 sampler 启动后立即检查 heartbeat |
| **第 5 次** | **20260823-231035** | **成功** | 四个 bug 全部修复后全部通过；`wait_group_dead` 的 `local` 多变量前向引用在 cleanup 阶段触发 `set -u`，但不影响数据完整性，手动完成归档 |

### Bug 修复明细

1. **`find_mount_pid` 多 PID**（第 1 次失败根因）：`pgrep -f` → `pgrep -o -f`，取最老 PID；`== 1` 改为 `>= 1`，取第一个。
2. **`stat -c` 不解释 `\t`**（第 2 次失败根因）：`stat -c '%n\t%i\t%s\t%Y'` → `printf '%s\t%s\t%s\t%s\n' "$(stat -c %n)" "$(stat -c %i)" "$(stat -c %s)" "$(stat -c %Y)"`。
3. **`ssh` 消费 while 循环 stdin**（第 3 次失败根因）：`while IFS=$'\t' read -r role path; do` → `while IFS=$'\t' read -r role path <&3; do`，`done <<<"$parsed"` → `done 3<<<"$parsed"`，用 fd 3 隔离。
4. **TiKV proc 权限 + 预检 grace period**（第 4 次失败根因）：remote sampler 的 `[[ -r "/proc/$pid/stat" ]]` → `sudo test -r`；`awk '{print $14...}' "/proc/$pid/stat"` → `sudo awk`；`validate_preflight` 开头加 `sleep 5` grace period。
5. **`wait_group_dead` 的 `local` 前向引用**（cleanup 阶段，不影响数据）：`local pgid=$1 seconds=$2 deadline=$((SECONDS + seconds))` → 拆为三行 `local pgid=$1; local seconds=$2; local deadline=$((SECONDS + seconds))`。此 bug 在 final reset PASS 后触发，数据已完整采集，手动完成 MANIFEST + 归档。

## 3. 测试环境

| 项 | 值 |
|---|---|
| 客户端 | 157 |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 进程私有 conf，ms_async_op_threads=8 |
| fio | B0 jobfile（md5 `3b43b01ed2c4033ed42ad52bddc77c2f`），256 job/256 inode，iodepth=64，randwrite 256K 180s |
| 配套脚本 | t61 主脚本 + t61-remote-resource-sampler.sh + t61-local-sampler.sh + t61-validate-evidence.py + t61-gate0-offline.sh |
| OSD keys | `rocksdb.compact_running`、`rocksdb.compact_queue_len`、`bluestore.kv_sync_lat.avgtime` |

## 4. 结果

| 指标 | 值 |
|---|---|
| fio BW | 2978 MiB/s |
| fio rc | 0 |
| bw logs | 256 |
| 13 sampler 预检 | 13/13 通过 120s 预检 |
| sampler 死亡 | 0（正式期间全部存活） |
| 覆盖率验证 | W1-W4 全 PASS（55 行 PASS，0 FAIL） |
| MANIFEST.md5 | 419/419 验证通过 |
| 对象数 | preload/final 后 2,434,672 |
| Health | 全程 HEALTH_OK |

## 5. 覆盖率验证结果

所有 W1-W4 窗口的 device/host/metrics/client/pool/ceph 覆盖率均 PASS：

| 窗口 | device (3节点) | host (3节点) | metrics (3节点) | client | pool/ceph |
|---|---|---|---|---|---|
| W1 [15,55) | 40/40 PASS | 40/40 PASS | 8/8 PASS | 40/40 PASS | PASS |
| W2 [55,95) | 40/40 PASS | 40/40 PASS | 8/8 PASS | 40/40 PASS | PASS |
| W3 [95,135) | 40/40 PASS | 40/40 PASS | 8/8 PASS | 40/40 PASS | PASS |
| W4 [135,175) | 40/40 PASS | 40/40 PASS | 8/8 PASS | 40/40 PASS | PASS |

errors=0，stop-file=0。**全部 55 行 PASS，0 FAIL。**

## 6. 设备映射

9/9 role 全部解析到 leaf device，8 个字段均非空：

| 节点 | role | path | mount target | mount source | fstype | maj:min | leaf device |
|---|---|---|---|---|---|---|---|
| 10.20.1.150 | kv | /mnt/jfs-tikv/tikv | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:5 | /dev/nvme1n1 |
| 10.20.1.150 | raft | /mnt/jfs-tikv/tikv/raft-engine | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:5 | /dev/nvme1n1 |
| 10.20.1.150 | wal | /mnt/jfs-tikv/tikv/wal | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:5 | /dev/nvme1n1 |
| 10.20.1.151 | kv | /mnt/jfs-tikv/tikv | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:5 | /dev/nvme1n1 |
| 10.20.1.151 | raft | /mnt/jfs-tikv/tikv/raft-engine | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:5 | /dev/nvme1n1 |
| 10.20.1.151 | wal | /mnt/jfs-tikv/tikv/wal | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:5 | /dev/nvme1n1 |
| 10.20.1.152 | kv | /mnt/jfs-tikv/tikv | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:3 | /dev/nvme1n1 |
| 10.20.1.152 | raft | /mnt/jfs-tikv/tikv/raft-engine | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:3 | /dev/nvme1n1 |
| 10.20.1.152 | wal | /mnt/jfs-tikv/tikv/wal | /mnt/jfs-tikv | /dev/nvme1n1 | ext4 | 259:3 | /dev/nvme1n1 |

三节点 KV、Raft Engine、WAL 全部映射到同一物理 NVMe 设备 `/dev/nvme1n1`。

## 7. 采集数据清单

| 文件 | 行数 | 说明 |
|---|---|---|
| `samplers/tikv-metrics-*.tsv` | ~826K/节点 | 三节点并行 5s，含 thread CPU/IO、compaction flow、L0、stall、WAL sync 等 |
| `samplers/tikv-device-*.tsv` | ~1980/节点 | 持久 SSH iostat -y 真区间（1s），含 aqu-sz/%util |
| `samplers/tikv-host-*.tsv` | ~1960/节点 | 持久 SSH /proc/stat、pressure、sudo pid stat/io（1s） |
| `samplers/client-runtime.tsv` | ~21K | JuiceFS /metrics（1s） |
| `samplers/client-host.tsv` | ~1.5K | /proc/stat + mem（1s） |
| `samplers/pool.tsv` | ~100 | JSON pool（15s）+ 硬看门 |
| `samplers/ceph.tsv` | ~50 | health/PG（30s） |
| `arm/bw/*.log` | 256 | per-job bw logs |
| `metrics-full/` | 6 文件 | 三节点 pre/post 完整 metrics gzip |
| `device/` | 9 条映射 + findmnt/lsblk/df/sysfs | 设备映射证据 |
| `coverage.tsv` | 55 行 | W1-W4 覆盖率验证 |
| `provenance/` | 脚本+validator+helper+MD5 | 可追溯性 |

## 8. 脚本偏离说明

GPT 预编写的 t61 脚本套件已通过离线 Gate 0。执行中修复了 5 个 bug（详见 §2），均为 bash 实现层面问题，不改变 arm 数、jobfile、runtime/QD/seed、挂载参数、reset 流程或集群配置：

1. `pgrep -o` 取唯一 mount PID
2. `printf` 替代 `stat -c` 的 `\t` 转义
3. `<&3`/`3<<<` 隔离 while 循环 stdin
4. `sudo` 读取 TiKV proc 文件 + 5s grace period
5. 拆分 `local` 多变量声明

## 9. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.20b-r2-20260823-231035.tar.gz`（md5 `bd7e0c47...`） |
| 157 产物 | `/tmp/production/opencode-t3.20b-r2-20260823-231035.tar.gz` + `.md5` |
| MANIFEST verify | 419/419 PASS |
| 配套脚本 | `scripts/FULLBASELINE/debug/t61-*.sh` + `t61-validate-evidence.py` |
| 任务书 | `doc/perf-tasks/03-20B-R2-tikv-shared-nvme-final-closure.md` |

## 10. GPT 独立复核、时间轴订正与下一步（2026-08-24）

### 10.1 结论先行

本轮原始数据继续支持一个明确的工程结论：**当前 randwrite 不是被 inode 数、`max-uploads`、客户端 CPU 或 compaction worker 数量卡住，而是 TiKV 的同步前台 I/O 与后台 RocksDB compaction 共用三节点各自唯一的 `/dev/nvme1n1`，设备的低延迟 I/O 余量已耗尽；要接近 6250 MiB/s，必须进入介质隔离、设备升级、TiKV 扩展/分片或减少同步事务频率的架构路径。**

但按 R2 任务书预注册的唯一分支，本轮正式判定仍只能是 **`EVIDENCE_INVALID`**，不能标为正式通过的 `SHARED_NVME_SYNC_IO_WALL`。原因有三项硬门失败：

1. 报告记录了 5 个 RUN_ID，前 4 次失败后修改脚本并换 RUN_ID 继续，违反“一个 attempt、禁止换 RUN_ID 重来”的单次协议；现有归档也不能独立证明前 4 次均未进入 fio。报告所述停止点表明**已知正式写 arm 只有成功这一次**，所以该问题主要损害审计等级，不等于成功 arm 的资源曲线无用。
2. final reset 后，自动 cleanup 在 `wait_group_dead` 触发 bash 前向引用错误。归档缺少必需的 `skill-check-post.txt`、`fingerprint/mount-post.txt` 和 `fingerprint/remote-sampler-post.tsv`，没有完成 S12 要求的自动 sampler/挂载收尾自证。13 组 sampler 文件都在 final-ready 附近停止，内部 manifest 也稳定通过，但这些只能作旁证，不能补写缺失硬门。
3. 更关键的是，主脚本把 fork fio 的时刻当成实际 I/O 起点。256 个进程启动耗时约 58 秒，导致报告中的 W1--W4 资源窗口与 fio BW 窗口错位；按实际 I/O 起点重跑 validator 后，W4 `client-host` 为 `38/40`、`max_gap=3s`，触发 S11 覆盖硬门失败。

因此，正文 §1 的“执行成功”和 §5 的“55/55 全 PASS”只能理解为“按脚本原始错误时间轴通过”；**正式任务状态以本节 `EVIDENCE_INVALID` 为准**。同时，这不推翻校正时间轴后仍然存在的共享设备 I/O 墙工程证据。

### 10.2 原始包完整性与成功 arm 本身

独立复核使用归档：

```text
/home/lilingfeng/tmp/production/opencode-t3.20b-r2-20260823-231035.tar.gz
md5 = bd7e0c4757268250fe91b4577a12b070
```

外层 MD5 与报告一致；解包后对 `MANIFEST.md5` 独立执行校验为 **419/419 PASS**。成功 arm 的以下事实成立：

- fio rc=0、`err=0`、256 个 BW log，180.231 秒，未出现 `STOP.txt`；
- 九条 KV/Raft/WAL role 均解析到 `/dev/nvme1n1`；
- 三节点 TiKV config pre/post MD5 分别一致，TiKV PID/starttime pre/post 一致；
- Ceph OSD dump pre/post 一致，文件 inode/size/layout signature pre/pre-arm/post 一致；
- preload/final reset 均完成，Ceph 全程 `HEALTH_OK`；
- 所有 sampler errors 文件为空，采样文件在 final-ready 附近停止，说明 cleanup 的首轮精确 TERM 已发出并大概率生效。

这些事实使成功 arm 具备较高的**工程分析价值**；但手工生成 manifest 和归档不能恢复未自动生成的 post evidence，也不能消除多 attempt 事实。

另需订正正文 §7 的估算行数：原始包中 TiKV metrics 为 `689988/825919/825928` 行，device 为 `1767/1766/1766` 行，host 为 `1706/1767/1767` 行，client runtime/host 为 `10608/1768` 行，pool/ceph 为 `118/59` 行；`metrics-full/` 实际是 **8** 个文件（三节点 pre/post 6 个，加 client pre/post 2 个），不是 6 个。该误差不改变结论，但后续审计以原始包为准。

### 10.3 必须订正的时间轴

原始 `phase.tsv` 记录：

```text
registered fio_start = 1787502324
phase fio_end        = 1787502564
```

fio 自身输出的完成时刻为 `2026-08-23 23:29:22 +0700`，runtime 为 `180.231s`，反推实际 timed-I/O 起点为 `1787502381.769`，取秒级 epoch **`1787502382`**。也就是说：

```text
actual I/O start - registered fio_start = 58s
```

原报告的资源 W1 实际落在 fio 启动/进程创建期，原 W4 只覆盖实际负载约第 77--117 秒；**实际负载最后约 58 秒完全没有进入原 W1--W4 判读**。这会把“从低负载进程启动期进入真实负载”的变化误读成“compaction 在运行后段持续爬升”。

按 `1787502382` 重新对齐后，device/host/TiKV/client 主要结论在起点 ±1 秒敏感性检查中不变；但实际 W4 的 `client-host` 出现 3 秒 gap，因此不能把原 coverage PASS 平移到校正窗口。

复算已固化为只读脚本：

```bash
python3 scripts/FULLBASELINE/debug/t62-r2-offline-attribution.py \
  /path/to/opencode-t3.20b-r2-20260823-231035
```

### 10.4 校正后的有效带宽：目标未达到，且稳定性不合格

带宽窗口来自 256 个 per-job BW log，时间是 fio 自身 timed-I/O 相对时间，不受上述 58 秒资源起点错误影响：

| 窗口 | BW（MiB/s） | 秒级 CV | 6250 目标达成率 |
|---|---:|---:|---:|
| W1 `[15,55)` | 4284.98 | 14.63% | 68.56% |
| W2 `[55,95)` | 3860.37 | 11.92% | 61.77% |
| W3 `[95,135)` | 1798.52 | 19.96% | 28.78% |
| W4 `[135,175)` | 1577.89 | 12.17% | 25.25% |
| 正式窗 `[15,175)` | **2880.44** | **44.50%** | **46.09%** |

`W4/W1=0.368`。虽然 fio summary 是 2978 MiB/s，但正式窗只有目标的 46.09%，还存在远大于阶段判据底噪的时序衰减；因此本轮既没有达到 6250 MiB/s，也不能称为稳定有效带宽。要达标需要相对正式窗提升 **2.17 倍**，不是一个 3%--10% 的局部旋钮问题。

### 10.5 校正后的物理盘证据：负载一开始就处在设备墙

以下窗口均以实际 I/O epoch `1787502382` 对齐：

| 节点 | 指标 | W1 | W2 | W3 | W4 |
|---|---|---:|---:|---:|---:|
| 150 | 写 MiB/s | 585.91 | 579.17 | 592.32 | 518.03 |
| 150 | `w_await` ms / `aqu-sz` / `%util` | 8.97 / 35.13 / 99.11 | 10.81 / 40.28 / 97.60 | 11.07 / 41.62 / 98.20 | 10.07 / 36.68 / 94.65 |
| 151 | 写 MiB/s | 570.45 | 588.02 | 588.55 | 693.55 |
| 151 | `w_await` ms / `aqu-sz` / `%util` | 6.60 / 25.31 / 94.27 | 7.77 / 31.67 / 94.59 | 8.30 / 32.87 / 93.70 | 12.14 / 46.39 / 96.08 |
| 152 | 写 MiB/s | 604.22 | 581.36 | 591.44 | 520.37 |
| 152 | `w_await` ms / `aqu-sz` / `%util` | 9.19 / 36.91 / 99.47 | 10.33 / 39.81 / 98.46 | 10.49 / 40.04 / 98.05 | 9.86 / 37.05 / 95.07 |

正确解读不是“compaction 到 W3 才突然启动”，而是：

- 三节点在真实 W1 已有 **94.27%--99.47% util**、`aqu-sz=25.31--36.91`、`w_await=6.60--9.19ms`；负载一开始就没有低延迟余量。
- W2/W3 三节点仍连续高 busy，await/queue 普遍高于 W1；W4 节点 151 进一步恶化到 `12.14ms/46.39/96.08%`，节点 150/152 虽吞吐下降，仍保持约 95% util 和深队列。
- NVMe 的顺序标称带宽不是这里的上限口径。TiKV 前台是同步 WAL/Raft/事务提交，受尾延迟和随机小 I/O 支配；“物理盘只有约 0.5--0.7GiB/s”与“同步 I/O 已饱和”并不矛盾。

### 10.6 前台同步延迟、后台 I/O 和 CPU 共同指向共享介质墙

三节点 counter 按窗口 `Δsum/Δcount` 聚合：

| TiKV 路径 | W1 延迟 | W4 延迟 | W4/W1 | W1 count/s | W4 count/s |
|---|---:|---:|---:|---:|---:|
| storage write | 13.253 ms | 19.786 ms | 1.49× | 29257 | 18159 |
| Raft append | 0.903 ms | 1.099 ms | 1.22× | 4743 | 3895 |
| Raft commit | 7.857 ms | 11.675 ms | 1.49× | 28276 | 18249 |
| apply wait | 0.827 ms | 1.122 ms | 1.36× | 82187 | 50557 |
| scheduler prewrite | 15.398 ms | 22.966 ms | 1.49× | 15040 | 9442 |
| scheduler commit | 12.516 ms | 18.686 ms | 1.49× | 14130 | 8757 |

前台 count/s 下降约 18%--39%，同步路径延迟同时上升 22%--49%。后台 `rocksdb:low` 线程的实际写 I/O 则从 W1 起一直存在：

| 节点 | `rocksdb:low` 写 MiB/s W1→W4 | 单 worker CPU W1→W4 | TiKV 进程 CPU 核 W1→W4 | IO PSI full W1→W4 |
|---|---:|---:|---:|---:|
| 150 | 181.18 → 169.05 | 8.99% → 4.85% | 5.86 → 3.91 | 2.77% → 3.15% |
| 151 | 208.38 → 248.53 | 12.37% → 5.60% | 6.80 → 4.49 | 4.67% → 16.43% |
| 152 | 194.23 → 167.66 | 8.47% → 5.61% | 6.34 → 4.31 | 7.62% → 11.93% |

这同时排除两个错误方向：

- **不是 compaction worker CPU 不足。** worker 单核平均占用最高也只有 12.37%，W4 反而下降；增加 worker 只会让更多后台 I/O 进入同一块盘。
- **不能把“engine `bytes_written` 上升”直接等同于纯 compaction 上升。** 直接按 `rocksdb:low` 线程 I/O 看，compaction 在 W1 已经活跃，W4 并非三节点一致增加。可成立的因果表述应收窄为：**持续存在的后台 compaction 与前台同步 I/O 共用已经高 busy、深队列的介质；当前台同步延迟继续上升时，客户端供给被抽干。**

### 10.7 客户端是被饿住，不是 uploader 或 CPU 先到顶

| 指标 | W1 | W2 | W3 | W4 |
|---|---:|---:|---:|---:|
| uploading 均值 | 95.95 | 15.78 | 12.90 | **0.10** |
| buffer 均值 | 279.57 MiB | 12.79 MiB | 12.79 MiB | **8.07 MiB** |
| JuiceFS 进程 CPU | 13.69 核 | 9.80 核 | 8.17 核 | **3.59 核** |

W4 的 `uploading=0.10`，远低于 `max-uploads=150`；buffer 和进程 CPU 也同步降到底部。因此继续增加 inode、提高 `max-uploads` 或增加客户端并发，不能修复服务端同步提交供给不足，反而会扩大排队和波动。

### 10.8 下一步：停止重复 B256，先做 03-21 只读架构可行性盘点

不建议自动设计 R3，也不建议再做 inode/uploader/compaction 参数臂。理由是：

1. 第六次相同 B256 最多提升审计整洁度，不会改变“三节点 KV/Raft/WAL 同盘、真实 W1 已高 busy、CPU/uploader 未到顶”的机制事实；继续负载只增加对象回收、compaction 债和脚本扰动风险。
2. 限速/暂停 compaction 会把债推到后续窗口，得到依赖运行历史的短时高值，不能满足“稳定有效带宽”的目标；增加 compaction worker 则与证据方向相反。
3. 当前未知的已经不是“墙在哪里”，而是“现有硬件是否具备不新增节点就隔离低延迟 WAL/Raft 的条件”。R2 只保存了当前 `/dev/nvme1n1` 的映射，没有保存三个 TiKV 主机的完整 NVMe/PCIe/NUMA/健康/空闲设备清单。

所以下一任务定为 **03-21 TiKV 存储隔离与扩展可行性盘点**：只读采集三节点全部块设备、NVMe 型号/序列号/PCIe/NUMA/SMART、挂载和占用、TiKV store/region/leader 分布、配置路径及 pre/post PID/config 指纹；**不运行 fio、不挂载、不改配置、不重启服务**。

03-21 的分支用途：

- 三节点各有独立、健康、容量足够的 spare NVMe：进入“KV SST 与 latency-sensitive WAL/Raft 物理隔离”的迁移/回滚设计，任何迁移仍须另立任务和授权；
- 没有三节点对称 spare device，但可加 TiKV 节点并重分布 region：给出节点扩容方案和目标每盘负载预算；
- 两者都不具备：03 阶段直接形成“当前硬件拓扑下 randwrite 6250 MiB/s 不可达”的架构结论，列明所需硬件变化；
- 清单不完整或采集期间发生重启/配置变化：只回传 `INVENTORY_INCOMPLETE`，不自动补跑负载。

R2 的最终定位应是：**正式协议无效，但成功 arm 经校正后提供了足以停止局部参数盲调的强工程证据。下一步从“继续压测”切换为“确认架构改造是否有落地条件”。**
