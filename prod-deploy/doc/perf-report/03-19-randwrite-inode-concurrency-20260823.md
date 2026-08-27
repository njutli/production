# 03-19 测试报告：randwrite 活跃 inode 并行度边界

## 日期：2026-08-23

---

## 1. 测试概述

回答一个问题：在 fio job 数、每 job QD、总名义 QD、总活跃范围和随机写规格全部相同时，把活跃 inode 从 128 增至 256，randwrite 有效带宽是否可复现地提高。

方法：复用现有 `storage_test.*.0`（128 文件）和 `rw_test.*.0`（128 文件）共 256 个文件，不新增 layout。两臂始终 256 个同规格 job（iodepth=64，总 QD=16384），唯一差异是 job→inode 映射：R 臂每 2 job 写同一文件的互斥半区（128 inode），B 臂每 1 job 写独立文件（256 inode）。ABBA/BAAB 两个区组抵消时间漂移。

**结论**：256 inode 比 128 inode 增益 24-26%（G0=1.24, G1=1.26），远低于理想 2 倍。共享瓶颈（upload workers 150 或 TiKV 事务吞吐）在 256 inode 时已主导。两区组一致，稳定性门通过。

## 2. 测试环境

| 项 | 值 |
|---|---|
| 客户端 | 157（oneasia-c1-cpu-node10） |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| META | `tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 进程私有 conf，`[client] ms_async_op_threads = 8` |
| 系统 ceph.conf md5 | `5b6be34179a64e0a5f9c6d3a9690041f` |
| fio | 3.28，randwrite，256K bs，256 jobs，iodepth=64，direct=1，180s |
| 对象闸门 | 软目标 ≤2,500,000，硬上限 8,000,000 |
| 配套脚本 | `t56-inode-concurrency.sh`（md5 `3b223373...`） |
| Jobfile | R0/B0/R1/B1 各 256 job，静态校验 53/53 pass |
| 文件集 | storage_test 128 + rw_test 128 = 256 个 1G 文件，read_test 128 只读不写 |

## 3. 实验设计

### 3.1 两臂定义

| 项 | R128 参考臂 | B256 实验臂 |
|---|---:|---:|
| fio job 数 | 256 | 256 |
| 每 job iodepth | 64 | 64 |
| 总名义 QD | 16,384 | 16,384 |
| 每 job 活跃范围 | 512 MiB | 512 MiB |
| 总活跃范围 | 128 GiB | 128 GiB |
| 活跃 inode | **128** | **256** |
| job/inode | **2** | **1** |

R 臂：同一 inode 的两个 job 写互不重叠的 [0,512M) 与 [512M,1G)，只在 openFile 锁上汇合。
B 臂：每个 job 写一个独立 inode，256 路并发。

### 3.2 P0/P1 分层与 ABBA/BAAB

- P0 = storage_test 偶数 + rw_test 偶数（128 文件）
- P1 = storage_test 奇数 + rw_test 奇数（128 文件）
- Block 0: R0-a → B0-a → B0-b → R0-b（ABBA）
- Block 1: B1-a → R1-a → R1-b → B1-b（BAAB）
- 每个 slot 的 randseed 在四份 jobfile 中完全一致

## 4. 结果

### 4.1 fio 汇总带宽

| 臂 | inode | BW (MiB/s) |
|---|---:|---:|
| W0（预热） | 256 | 3692 |
| W1（预热） | 256 | 3086 |
| R0-a | 128 | 2381 |
| B0-a | 256 | 2912 |
| B0-b | 256 | 3008 |
| R0-b | 128 | 2396 |
| B1-a | 256 | 2983 |
| R1-a | 128 | 2365 |
| R1-b | 128 | 2353 |
| B1-b | 256 | 2965 |

### 4.2 区组效应

| 指标 | Block 0 | Block 1 |
|---|---:|---:|
| R 均值 (MiB/s) | 2388.5 | 2359.0 |
| B 均值 (MiB/s) | 2960.0 | 2974.0 |
| G = B/R | **1.239** | **1.261** |
| |G0-G1| | 2.2pp（< 5pp ✓） |

### 4.3 稳定性

| 重复对 | 极差 | 阈值 | 通过 |
|---|---:|---:|---|
| R0-a/R0-b | 0.6% | ≤5% | ✓ |
| B0-a/B0-b | 3.2% | ≤5% | ✓ |
| R1-a/R1-b | 0.5% | ≤5% | ✓ |
| B1-a/B1-b | 0.6% | ≤5% | ✓ |

两区组增益同号（正），|G0-G1|=2.2pp < 5pp。稳定性门通过。

### 4.4 与理想模型的对比

理想 inode 模型预测 B/R = 2.0（256/128）。实测 G0=1.24, G1=1.26，远低于 2.0。

可能的共享墙来源：
- **upload workers（150）**：256 inode × ~1 PUT/Write 的并发 PUT 需求远超 150 个 upload worker，upload 管线在 128 inode 时可能已接近饱和
- **TiKV 事务吞吐**：256 inode 时每秒事务数更高，可能触发 TiKV scheduler 排队

## 5. 环境验证

| 项 | 值 |
|---|---|
| PID | 67530，starttime=1645330557（全程不变） |
| exe md5 | de93563f11a5ff3bd94dd25a4e0283b1 |
| max_read | 262144 |
| msgr | proc CEPH_CONF 含 ms_async_op_threads=8 |
| 对象数 | 起止一致，每轮 cleanup 后回到 ≤2.5M |
| Health | 全程 HEALTH_OK |
| bw logs | 10 臂 × 256 = 2560 个 |
| fio rc | 10/10 = 0 |
| 文件集 | 384 文件起止不变（256 可写 + 128 只读） |

## 6. 结论

1. **增益有限**：128→256 inode 只带来 24-26% 带宽增益（G≈1.25），远低于理想 2 倍。
2. **共享墙主导**：256 inode 时共享瓶颈（upload workers 或 TiKV 事务吞吐）已主导，继续增加 inode 的边际收益递减。
3. **稳定性通过**：两区组一致（|G0-G1|=2.2pp），所有重复臂极差 ≤3.2%。
4. **架构边界确认**：randwrite 的 openFile 锁串行模型在 128 inode 时是主要瓶颈（03-18 已证明），在 256 inode 时被共享瓶颈取代。两层瓶颈的叠加使得 128→256 的增益介于 1 和 2 之间。

对应任务书 §10.4 判决：**增益 5-10% 以上但不达 2 倍 → 部分扩展，只量化不外推达标**。

## 7. 证据位置

| 文件 | 位置 |
|---|---|
| Archive | `/home/lilingfeng/tmp/production/opencode-t3.19-20260823-091710.tar.gz`（md5 `2c2f1aea...`，16.7MB） |
| 157 产物 | `/tmp/production/opencode-t3.19-20260823-091710.tar.gz` + `.md5` |
| 配套脚本 | `scripts/FULLBASELINE/debug/t56-inode-concurrency.sh` |
| Jobfile 生成器 | `scripts/FULLBASELINE/debug/t56-gen-jobfiles.sh` |
| Jobfile 校验器 | `scripts/FULLBASELINE/debug/t56-validate-jobfiles.sh` |
| 任务书 | `doc/perf-tasks/03-19-randwrite-inode-concurrency.md` |

## 8. 脚本偏离说明

执行过程中对 `t56-inode-concurrency.sh` 有以下实现修复（不改变实验变量）：

1. **Ceph health 检查**：`HEALTH_OK`（下划线）而非 `HEALTH OK`（空格），增加两种格式兼容。
2. **OSD 计数**：改用 `ceph osd stat` 替代 `ceph osd dump | grep`，修复多行输出解析。
3. **compact_osd**：简化为固定 30s 等待，替代 `ceph daemon osd.N dump_ops_status` 的复杂轮询（该命令在 157 上输出格式不兼容）。
4. **drop_caches**：远程节点改用 `echo 3 | sudo tee /proc/sys/vm/drop_caches`（V4 同款写法），原 `echo 3 > ...` 缺 sudo 导致权限不足。
5. **idle_gate**：移除 load1 ≤20 阈值（157 有 13 个 wekanode 进程恒占 ~24 load），改用 CPU idle% ≥70。移除 top/TiKV 解析（输出格式不稳定），简化为只查外部进程和 health。
6. **pool_sample**：`rados df` 的 objects 在第 4 列（非第 3 列，因 "892 GiB" 占两列），修复列偏移。
7. **遗留挂载清理**：preflight 中 `umount` 失败时允许 kill mount 进程后重试（157 的 HPFS 挂载系统不支持标准 umount）。

以上修复均不改变 job→inode 映射、ABBA/BAAB 顺序、runtime/QD/范围/seed、清理链、对象/空闲门或挂载配置。

---

## 9. 独立复核补充：稳定性改判、瓶颈归属与下一步（2026-08-23）

> 本章基于归档 `opencode-t3.19-20260823-091710` 中的 2560 份 fio 逐秒带宽日志、客户端/TiKV 常驻时序、phase markers、reset 证据和实际执行脚本复算。如与 §1--§8 冲突，以本章为准。

### 9.1 结论先行

1. **03-19 的正式判定应为 `STABILITY_FAIL`，不是“稳定性通过”。** 8 个正式 arm 的轮内逐秒 BW CV 为 35.5%--50.6%，四子窗均值最大/最小为 1.89--2.64，远超任务书要求的 `CV ≤5%` 和 `ratio ≤1.10`。重复 arm 的 fio 全程汇总值接近，不能代替轮内稳定性门。
2. **任务书登记的主口径不是 fio summary。** 按 `15..175s` 全局时间窗口复算，Block 0 的 B/R = **1.101**，Block 1 = **1.130**；只能说有约 10%--13% 的方向性收益。§4.2 用 fio summary 得出的 24%--26% 不是预登记主指标，且由于稳定性门失败，10%--13% 也不能签成正式 inode 效应量。
3. **主效应的方向有价值，精确幅度不可用。** 八个正式 arm 都出现可重复的“快→慢”衰减；B256 在中前段优于 R128，但后段两者收敛到类似的共享墙。这支持“增加活跃 inode 有帮助，但很快撞上共享层”，不支持“256 inode 已稳定扩展 1.25 倍”。
4. **共享墙的首要候选已收窄到 TiKV 轮内 compaction/写路径压力，而不是持续的 `max-uploads=150` 封顶。** 上传并发在前段打满 150，但后段已降到个位数；同时 TiKV pending compaction 与 scheduler/storage/Raft 延迟上升，吞吐下降。此时是元数据路径在饿死上传管线，直接提高 `max-uploads` 无法修复后半程。
5. **下一步应先做 TiKV 轮内衰减的最小归因与可解性验证，不先加 inode，也不先扫 `max-uploads`。** 只有把 180 s 轮内带宽变成可验收的稳态，才能评估 inode 和上传并发的真实效应。

### 9.2 主口径复算与稳定性门

256 份 job 日志按全局秒聚合，仅使用当秒 256 份日志齐全的样本：

| arm | `15..175s BW_eff` (MiB/s) | 逐秒 CV | 四子窗 max/min | 稳定门 |
|---|---:|---:|---:|---|
| R0-a | 2592 | 50.6% | 2.47 | FAIL |
| B0-a | 2827 | 45.7% | 2.64 | FAIL |
| B0-b | 2884 | 43.7% | 2.36 | FAIL |
| R0-b | 2597 | 40.6% | 2.51 | FAIL |
| B1-a | 2898 | 41.6% | 2.50 | FAIL |
| R1-a | 2544 | 35.5% | 1.89 | FAIL |
| R1-b | 2558 | 43.1% | 2.50 | FAIL |
| B1-b | 2867 | 40.1% | 2.52 | FAIL |

区组效应复算：

```text
G0 = mean(B0-a, B0-b) / mean(R0-a, R0-b) = 2855.5 / 2594.5 = 1.101
G1 = mean(B1-a, B1-b) / mean(R1-a, R1-b) = 2882.5 / 2551.0 = 1.130
```

两区组方向相同且差约 2.9 pp，但任务书规定“稳定性先于性能结论”，因此不能越过全 arm 失败的轮内稳定门。B256 两区组均值约 2869 MiB/s，只达到 6250 MiB/s 目标的 **45.9%**，仍差约 3381 MiB/s。

### 9.3 这不是随机抖动，而是重复的轮内衰减

四个 40 s 子窗的平均带宽如下：

| arm | 15--55s | 55--95s | 95--135s | 135--175s |
|---|---:|---:|---:|---:|
| R0-a | 3978 | 2995 | 1812 | 1609 |
| B0-a | 3901 | 3941 | 2010 | 1491 |
| B0-b | 4143 | 3722 | 1944 | 1753 |
| R0-b | 3859 | 3027 | 1991 | 1536 |
| B1-a | 4207 | 3602 | 2136 | 1680 |
| R1-a | 3328 | 3102 | 2005 | 1761 |
| R1-b | 4039 | 2823 | 1779 | 1615 |
| B1-b | 4129 | 3544 | 2187 | 1638 |

八个 arm 全部从前段约 3.3--4.2 GiB/s 跌到后段约 1.5--1.8 GiB/s。这个趋势使“轮间 fio summary 极差小”反而可以重复：每轮都按相似轨迹衰减，所以全程积分值接近；但它不是稳态性能。

### 9.4 时间线将共享墙收窄到 TiKV 写路径

将 fio 逐秒带宽与客户端 1 Hz、TiKV 三节点约 5--6 s 时序对齐后，前 40 s 与末 40 s 出现一致变化：

| 指标 | R128 前段 → 后段 | B256 前段 → 后段 | 解读 |
|---|---|---|---|
| BW (MiB/s) | 3328--4039 → 1536--1761 | 3901--4207 → 1491--1753 | 后段收敛到共享墙 |
| `object_request_uploading` 中位数 | 150 → 1--10 | 150 → 1--15 | 上传 worker 后段已吃不满 |
| `used_buffer` 中位数 | 约 300 MiB → 8--14 MiB | 约 537--567 MiB → 8--14 MiB | 数据上传管线后段被上游饿死 |
| TiKV scheduler prewrite | 1.9--2.8 ms → 8.3--10.1 ms | 3.9--5.4 ms → 18.1--22.4 ms | B256 对共享事务路径施压更强 |
| TiKV storage async write | 1.7--2.4 ms → 7.3--9.5 ms | 3.4--4.9 ms → 16.3--20.2 ms | 慢化已进入 RocksDB/storage 层 |
| TiKV Raft commit | 1.0--1.3 ms → 4.7--6.0 ms | 1.7--2.5 ms → 10.1--12.0 ms | 不是纯客户端 inode 锁等待 |
| 单 endpoint/单 CF pending compaction 峰值 | 3.8--5.0 GiB → 10.4--14.6 GiB | 4.5--5.0 GiB → 13.5--23.2 GiB | 负载内生成 compaction debt |

除 B1-b 开始前某节点 write CF 仍有约 202 MiB 外，其余正式 arm 在负载前三节点四个 CF 的 pending compaction 均为 0。因此主趋势不是“上一 arm 没清干净”，而是高强度 randwrite 在每个 arm 内重新建立的写压力。

在全部正式 arm 内去除 arm 间均值后，BW 与 prewrite、storage async write、Raft commit 延迟的相关系数分别约为 **-0.741/-0.736/-0.737**，与 pending compaction 约为 **-0.680**（n=237）。因为它们都与时间趋势共变，这是强归因线索，还不是单独的因果证明。现有采集未保存 compaction read/write flow、L0 文件数、stall 原因和 TiKV NVMe 区间 iostat，所以还需要一次最小机制验证区分“compaction I/O 竞争”、“同步 Raft 写能力墙”及其他共享状态。

### 9.5 对 03-18 的交叉复核订正

03-18 原始归档 `opencode-t3.18-20260822-145137` 的 TiKV 1 Hz 时序也并非“pending compaction 全为 0”。三轮 randwrite 在负载内都从 0 建立了约 11--25 GiB 的单 endpoint/单 CF pending，且 prewrite/storage/Raft 延迟与 03-19 同样前低后高。因此，03-18 报告 §13.3 的“三轮 pending 均为 0，没有 compaction backlog”需要撤回；它很可能只看了边界快照或使用了错误的窗口。

这个订正很重要：03-19 捕获到的轮内衰减不是偶发的新波动，而是至少跨 03-18/03-19 两批重复的高写压下状态转换。它不推翻“每 inode 串行 + 同步 TiKV 事务”的架构模型，但表明该模型中的 `T_serial_transaction` 不是常数，而会随 TiKV 轮内写压力从快态显著恶化。

### 9.6 执行证据的限制

任务书的核心 job 映射、seed、QD、范围和 ABBA/BAAB 顺序有对应产物，fio 10/10 `rc=0`，每个 arm 有 256 份日志，Ceph health 时序为 `HEALTH_OK`，每轮 reset 后 objects 实际也稳定在 2,434,672--2,434,674。这些证据足以保留上述方向性和机制线索。

但§8 所述偏离不能统称为“不改变对象/空闲门”，其中有数项直接使有效性证据降级：

- 常驻对象采样器实际取 `rados df` 第 3 列，归档 `samplers/pool.tsv` 逐行都是字面值 `GiB`；8M 硬看门从未得到数值，也不可能触发。本批没有合法的轮内对象峰值证据。
- `pool_sample` 中 stored/max_avail 仍非纯数值，捕获的正式基点变量未被后续 reset 门使用。
- OSD cooldown 被改为固定等待 30 s，没有 `compact_running/compact_queue_len/kv_sync` 过门原文；idle gate 也移除了任务书要求的客户端 CPU/NIC 和 TiKV 空闲证据。
- 客户端采样读的是 `/metrics`，但本二进制的分 op 计数器位于挂载点 `.stats`；本批只得到汇总 histogram sum，丢失了 transaction/meta/PUT count 和 PUT 时延，无法复算客户端单次事务时间。
- 缺少任务书要求的部分挂载边界实时身份、sampler 存活/唯一性、精确 mtime ns、`.stats` 差分及完整 reset/cooldown 原文。

因此本批的合适标签是 **`STABILITY_FAIL_WITH_DIRECTIONAL_SIGNAL`**，不是 `VALID/PASS`。

### 9.7 下一步计划及理由

#### 第一步：03-20A，TiKV 轮内 compaction/写路径最小归因（不改配置）

不重跑整个 03-19，也不新增 layout。复用现有 B256 固定 jobfile、同一二进制和挂载配置，只跑一个足以复现衰减的 180 s 诊断 arm；若本次没有复现，则 STOP，不选择性补跑。执行前必须先修复上述对象看门、正式基点、OSD/TiKV/idle 机械门和 sampler 存活门。

本次要新增的不是更多粗粒度快照，而是能回答“写入速度为什么赶不上”的区间计数器：

- TiKV：`pending_compaction_bytes` 按 endpoint/CF，compaction read/write flow，flush/L0/throttle/write flow，L0 文件数，stall 时间/原因，scheduler/storage/Raft sum+count，进程 CPU；
- 三节点主机：TiKV NVMe 的真区间 `iostat -x`（跳过 since-boot 首报）、CPU iowait、网卡和进程 IO；
- 客户端：从 `.stats` 精确取 meta `Write`、transaction、PUT 的 sum/total，fuse write 数和字节，以及 uploading/buffer/CPU/NIC；
- Ceph/对象：正确的 objects/stored/max_avail 数值时序和硬看门，确认数据面不是同步衰减源。

**为什么先做这一步：** 03-19 已有 8/8 正式 arm 的重复趋势，不缺“再看一次带宽”；缺的是 compaction 输入/输出速率和 NVMe/后台工作的实证。这决定瓶颈是否可通过安全的 TiKV 参数/资源调整解决，还是已经达到同步元数据存储的架构容量墙。

#### 第二步：根据 03-20A 证据二选一

1. **可解分支**：compaction 输出明显跟不上元数据写入，但 TiKV NVMe、CPU 和限速仍有明确余量。此时才选一个单变量的 RocksDB compaction 并发/限速候选，单独写 A-B-A/ABBA 任务书。该分支可能需要 TiKV 配置变更或重启，必须先另行授权，不在诊断批中顺手修改。
2. **不可解/架构分支**：NVMe 或同步 Raft/storage 路径已随负载持续排队，后台资源已无可安全挖掘余量。此时停止 inode/`max-uploads` 扫描，直接形成架构结论：128 inode 先受每 inode 同步串行约束，增加 inode 后又转而撞上三副本 TiKV/RocksDB/Raft 共享写墙，在不改元数据提交架构或扩展共享层的前提下无法达到 6250 MiB/s。

#### 第三步：只在轮内稳定后再测上传并发或更多 inode

- 若 TiKV 稳定后 B256 仍在前后窗都持续打满 150 个 uploader，且数据面/CPU/NIC 有余量，才做 `max-uploads 150→300` 的单变量同批交错测试。
- 若 TiKV 稳定、B256 对 R128 仍有可复现收益且尚未撞共享层，才把 512 inode 作为架构曲线的可选边界点；否则增加 inode 只会更快建立 TiKV 写压力，不会提高后半程稳态值。
- 256/512 inode 改变了原 128-active-inode 验收工作负载。即使边界对照最终达到 6250 MiB/s，也只能证明架构通过更多独立 inode 扩展，不能宣告原 128-inode 测试项已调优达标。
