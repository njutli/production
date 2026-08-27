# 03-19 任务书：randwrite 活跃 inode 并行度边界（受控 128 vs 256 inode）

> 版本：v3（2026-08-22，波动源复查后重构）
> 计划线：`03-17g（F68）→ 03-18（TiKV 服务端采集完成）→ 03-19（本任务）→ 架构结论或最终长稳`
> 执行方：GLM　｜　分析方：opencode
> 前置报告：`doc/perf-report/03-18-tikv-meta-latency-attribution-20260822.md` §13

```text
03-17g：确认写侧跨日漂移与 meta 双态
   ↓
03-18：客户端 inode 排队 + 同步 TiKV 事务周期闭环
   ↓
03-19：固定 job/QD/范围，只改 job→inode 映射   ← 你在这里
   ├─ 稳定且有收益 → inode 架构边界；再决定是否测生产式 256-job 终值
   ├─ 稳定且无收益 → 共享 TiKV/客户端/数据面平台
   └─ 稳定性失败   → 先定位状态源，不做选择性补跑
   ↓
固定交付配置最终 ≥8 h 长稳
```

执行前必须通读：`skills/TESTING-GUIDE.md`（§1.3/§2.2/§3）、`skills/test-commands-reference.md`（§8）、`skills/baseline-reproduction-skill.md`（§2.2/§2.5/§3.1/§4.3）、`skills/LONG-RUNNING-TEST-SKILL.md` 和 `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。

---

## 〇、任务边界与结论边界

1. 本任务只回答：在 fio job 数、每 job QD、总名义 QD、总活跃地址范围和随机写规格全部相同时，把活跃 inode 从 128 增至 256，randwrite 有效带宽是否可复现地提高。
2. 本任务是**架构边界对照**，不是参数扫描，也不改变原“128 job 对应 128 inode”的测试项验收语义。即使 256 inode 达到 6250 MiB/s，也不能宣告原测试项达标。
3. 全程不得 format、layout、创建/删除/截断文件，不得重启 OSD/TiKV/PD，不得删除/重建 pool，不得修改 CRUSH、PG、卷、Ceph、TiKV 或挂载参数。
4. 只复用现有 `storage_test.*.0` 与 `rw_test.*.0` 各 128 个 1 GiB 文件；`read_test.*.0` 只校验，绝不写。
5. 全批只挂载一次。挂载 PID/starttime 必须从预热前保持到正式区组结束；arm 间不得 remount。
6. 不使用历史绝对带宽作主对照，不按性能高低选择性重跑。主结论只来自本批两个时间平衡区组。
7. 本任务不承诺外部环境永远不波动；它必须消除已知可控波动源，并用机械门与平衡区组把不可控漂移识别出来。稳定性门失败时只能交付 `STABILITY_FAIL`，不得强行给 inode 结论。
8. 不复用 T54/T55 结果目录、锁、脚本名或产物名。本任务统一使用 `T56/t56/t3.19` 命名空间。
9. 执行脚本和全部 fio jobfile 必须在开跑前冻结并记录 md5。运行中任何字节变化均 STOP；不得临时改变量继续跑。
10. 仓库中未跟踪的 `scripts/FULLBASELINE/debug/t57-inode-scaling.sh` **不是本任务脚本，禁止执行或改名复用**：它的 64/32-job 矩阵、卸载方式、失败处理和采集口径均不符合本任务。GLM 必须按本文另写 T56 脚本，先提交静态校验结果再执行。

---

## 一、为什么 v2 设计撤回

v2 的主对照是：

```text
A128：128 inode × qd128 × 1 GiB
B256：256 inode × qd64  × 512 MiB
```

该设计虽然保持总名义 QD 和总范围相同，却同时改变了每 job QD、每 job 范围和 fio job 数；不能把差异唯一归给 inode。v2 还让 B 前后的参考来自不同 A 子集，文件放置差异会混入时间插值。

v3 改用“job 到 inode 的映射”作为唯一处理变量：两臂始终都是 256 个完全同规格的 job。参考臂每两个 job 写同一文件的两个互斥半区，实验臂每个 job 写一个独立 inode。

---

## 二、主实验定义

### 2.1 两臂共同常量

| 项 | R128 参考臂 | B256 实验臂 |
|---|---:|---:|
| fio job 数 | 256 | 256 |
| 每 job iodepth | 64 | 64 |
| 总名义 QD | 16,384 | 16,384 |
| 每 job 活跃范围 | 512 MiB | 512 MiB |
| 总活跃范围 | 128 GiB | 128 GiB |
| bs/rw/ioengine/direct/runtime | 完全相同 | 完全相同 |
| 活跃 inode | **128** | **256** |
| job/inode | **2** | **1** |

两臂唯一的有意差异是：256 个相同 job 映射到 128 还是 256 个 inode。R128 中同一 inode 的两个 job 写互不重叠的 `[0,512MiB)` 与 `[512MiB,1GiB)`，不存在数据区间竞争；它们只在待验证的 inode 串行路径上汇合。

该前提已直接用 `de93563f` 对应源码复核：`pkg/meta/openfile.go` 的 `openfiles.files` 按 `Ino` 唯一映射到一个 `*openFile`，重复打开只增加 `refs`；`pkg/meta/base.go:Write` 按 inode `find()` 后锁同一个 `openFile`。因此 R 臂的两个文件句柄不会绕开 inode 锁。源码副本仅作设计证据，执行身份仍以 `/proc/<mount-pid>/exe` md5 为准。

### 2.2 不再运行生产式 C 臂

v2 的 `256 inode × qd128 × 1 GiB` 同时翻倍总 QD 与总范围，只能回答生产扩展终值，不能完成本任务的纯归因，而且会增加对象峰值、运行时长与批内漂移。它从 03-19 主批删除；如 03-19 已证明 inode 正效应，再另立短任务测生产式终值。

### 2.3 延迟指标的使用边界

- `meta Write latency` 包含 `f.Lock()` 前等待，是 inode 队列的结果；`BW × latency / inode` 近似 Little 定律恒等量，不能作为独立验证。
- `transaction latency` 位于 `kvMeta.txn` 内，更接近每条 inode 通道的同步服务周期，只用于解释 B256 是否因共享 TiKV 排队而偏离理想 2 倍。
- 主判据只来自同批 R128/B256 的有效带宽直接对照，不使用历史回归残差。

---

## 三、固定环境

| 项 | 固定值 |
|---|---|
| 客户端 | 157（oneasia-c1-cpu-node10） |
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| META | `tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod`，无附加 query |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端配置 | 系统 conf 的进程私有副本，恰追加一条 `[client] ms_async_op_threads = 8` |
| 系统 ceph.conf | `/etc/ceph/ceph.conf`，期望 md5 `5b6be34179a64e0a5f9c6d3a9690041f`，起止不得变化 |
| fio | 3.28；`randwrite bs=256K ioengine=libaio direct=1 fallocate=none time_based runtime=180` |
| 挂载 | 全批一个 PID + starttime；禁止 arm 间 remount |
| pool 安全线 | 软目标 `≤2,500,000`；硬上限 `8,000,000` |
| 结果目录 | `/tmp/opencode-t3.19-${RUN_ID}`；存在即 STOP，禁止覆盖 |
| 最终归档 | `/home/lilingfeng/tmp/production/opencode-t3.19-${RUN_ID}.tar.gz` + `.md5` |

挂载后必须从 `/proc/<pid>/exe` 验证实跑二进制 md5，从 `/proc/<pid>/environ` 反查实际 `CEPH_CONF`，并确认私有 conf 中恰有一条 `ms_async_op_threads = 8`。只检查 shim 或启动命令不算生效证据。

---

## 四、固定文件分层与 job 映射

### 4.1 文件资产门

开工前和收尾必须满足：

| 文件集 | 数量 | 每文件大小 | 用途 |
|---|---:|---:|---|
| `storage_test.*.0` | 128 | 1,073,741,824 B | 可写 |
| `rw_test.*.0` | 128 | 1,073,741,824 B | 可写 |
| `read_test.*.0` | 128 | 1,073,741,824 B | 只校验，绝不写 |

本批会改变 `rw_test` 的写历史；后续 randrw 必须重新做同批参考，不能直接引用 03-17f 的绝对值。

### 4.2 P0/P1 两个平衡层

- **P0**：`storage_test` 偶数编号 64 个 + `rw_test` 偶数编号 64 个。
- **P1**：`storage_test` 奇数编号 64 个 + `rw_test` 奇数编号 64 个。

必须按数字编号排序生成绝对路径清单。P0/P1 各 128 行、互斥，并集恰为 256 个普通文件；并集必须有 256 个唯一 inode，且不含 `read_test`。

### 4.3 四个正式 jobfile

所有正式 jobfile 都有 256 个 job；slot 编号 `000..255`、job 名、job 顺序、每 slot 的固定 `randseed` 在四份 jobfile 中完全一致。

| jobfile | slot 0..127 | slot 128..255 | 唯一 inode |
|---|---|---|---:|
| `R0` | P0 每文件低半区，各 1 job | P0 同文件高半区，各 1 job | 128 |
| `B0` | P0 每文件低半区，各 1 job | P1 每文件高半区，各 1 job | 256 |
| `R1` | P1 每文件低半区，各 1 job | P1 同文件高半区，各 1 job | 128 |
| `B1` | P1 每文件低半区，各 1 job | P0 每文件高半区，各 1 job | 256 |

定义：

```text
低半区：offset=0       size=512M
高半区：offset=512M    size=512M
```

这样每个区组内，R/B 有一半 job 逐 slot 使用完全相同的文件和半区，另一半只把相同规格的高半区 job 从同一批 128 inode 分散到另一批 128 inode。第二个区组交换 P0/P1，抵消文件家族、奇偶编号、对象落位和半区位置偏差。

### 4.4 fio jobfile 固定项

```ini
[global]
rw=randwrite
bs=256k
ioengine=libaio
direct=1
fallocate=none
time_based=1
runtime=180
group_reporting=1
allow_file_create=0
create_on_open=0
iodepth=64
log_avg_msec=1000
per_job_logs=1
randrepeat=1
allrandrepeat=1
```

每个 `[slotNNN]` 必须显式写入一个绝对 `filename=`、`offset=`、`size=512M` 和预先冻结的 `randseed=`。禁止 `numjobs` 自动派生文件名，禁止运行时生成随机 seed。`write_bw_log` 使用 arm 唯一前缀并作用于全局。

静态校验必须证明：

1. 四份 jobfile 都恰有 256 个 job，slot/seed/QD/size/bs 完全一致。
2. R0/R1 恰为 128 个 inode、每 inode 2 job，两个 extent 不重叠且并集正好 1 GiB。
3. B0/B1 恰为 256 个 inode、每 inode 1 job；低/高半区各 128 个。
4. 所有 extent 均 256 KiB 对齐且不越过 1 GiB；没有 `read_test`，没有创建或 truncate 选项。

---

## 五、预热与正式顺序

### 5.1 写历史预热

正式区组前执行两个不计结果的预热 arm：

```text
W0 = B0 jobfile
W1 = B1 jobfile
```

W0/W1 共同使 256 个可写 inode 的低、高半区都经历相同规格的 randwrite。每个预热 arm 后也必须执行与正式 arm 完全相同的状态复位；W1 复位达到对象收敛时冻结正式批的 objects/stored/max_avail 状态基点。

预热不是性能探针，不记录为正式样本，也不得因其带宽决定是否继续；只有安全/有效性 STOP 条件可中止。

### 5.2 两个时间平衡区组

```text
W0 → reset → W1 → reset →

Block 0: R0-a → reset → B0-a → reset → B0-b → reset → R0-b → reset →
Block 1: B1-a → reset → R1-a → reset → R1-b → reset → B1-b → final reset
```

- Block 0 是 `A B B A`，Block 1 是 `B A A B`；两种处理在每个区组内的平均时间位置相同，并在全批中平衡先后位置。
- R/B 都有 4 个正式 arm；不把连续 fio 当独立挂载样本，但它们是同一固定实例内用于抵消时间漂移的重复观测。
- 不再追加 C 臂、原 128-job arm 或任何“顺手测试”。它们会延长批次或引入额外变量。

---

## 六、统一状态复位：不得简写为一句 aggressive_cleanup

已知 between-arm 清理本身可能成为波动源，因此每个箭头处必须执行同一 `reset_to_gate` 状态机。不得直接调用旧 V4 后只凭“函数返回 0”放行。

### 6.1 固定复位顺序

1. 确认上一 arm fio 已退出并 `wait`，所有文件描述符已关闭；执行 `sync -f /mnt/juicefs`。
2. 对全部 OSD 发起 compact，轮询至每个 OSD 同时满足：`compact_running=0`、`compact_queue_len=0`、`kv_sync_lat avg<2ms`。任何采集失败按未收敛处理，禁止用默认 0 放行。
3. 固定等待 30 秒，再重复一次上述 compact 与三指标轮询。
4. 执行且只执行一次 `juicefs gc --compact "$META"`，保存完整 stdout/stderr、rc 和起止 epoch。rc 非 0 STOP；禁止用 `tail` 截掉错误。
5. GC 后按 15 秒采样 pool objects/stored，直到连续 3 个样本满足：
   - `objects≤2,500,000`；
   - `|objects-FORMAL_BASE_OBJECTS|≤1,000`（正式区组建立基点后生效）；
   - `|stored-FORMAL_BASE_STORED|≤67,108,864` B，且 `max_avail` 不低于正式基点的 99%（正式区组建立基点后生效）；
   - 三样本 objects 不上升，最大值与最小值之差 ≤128。
   最多等待 10 分钟；不收敛则 STOP。对象下降可以记录，但不能借“下降无害”放宽正式基点，避免后台删除使后半批处于不同底座。
6. GC 可能再次制造 OSD/TiKV 后台工作，因此必须**再次**执行 OSD compact/cooldown 三指标门；不能沿用 GC 前的结果。
7. 三 TiKV endpoint 连续 3 个 5 秒样本均满足 `tikv_engine_pending_compaction_bytes=0`；任一 endpoint 缺值或非零，最多等 10 分钟，仍不满足 STOP。
8. 对全部 256 可写文件和 128 个 read_test 按固定数字顺序执行同一轮只读 stat，保存 `path inode size mtime_ns`。此步骤在每个 arm 前完全相同，用于同时归一客户端 metadata 触达历史。
9. 在客户端 157 与 150--152 三节点各执行一次 `sync` + `drop_caches`，必须 4/4 成功；不允许旧 V4 的“部分失败只 WARN”。一次失败可重试该节点 1 次，仍失败 STOP。
10. 从最后一次成功 drop_caches 起固定静置 60 秒。静置期不得再执行 compact、GC、全量 metrics、文件遍历或性能探针；只允许批次常驻的低频采集器工作。
11. 静置最后 30 秒必须通过 §六.2 空闲门，随后立即写 phase marker 并启动 fio；门到 fio start 间隔须 ≤10 秒。

除首次挂载、W0/W1 和上述统一复位外，不允许增加任何会读写测试文件的 warmup/preprobe。特别禁止用短 randwrite “判断快慢档”。`TASK-BOOK-AUTHORING-GUIDE.md` §二.12 的旧 60 秒 mutating meta 探针在本任务被更新的主计划 B4-16 取代：W0/W1 只消除首轮/写历史差异，绝不按其性能筛选状态。

### 6.2 外部负载空闲门

该门只看与待测性能无关的外部状态，绝不看 randwrite BW：

- 无非本批 fio、FULLBASELINE、gc、compact、layout 或其他 JuiceFS 压测进程。
- Ceph `HEALTH_OK`，6 OSD up/in，全部 PG active+clean，`up_from` 与批首相同；无 scrub/deep-scrub/recovery/backfill 正在运行。
- 客户端 157 最近 30 秒 CPU idle 均值 ≥70%，iowait ≤5%，steal ≤1%，load1 ≤20。
- 客户端数据网/管理网最近 30 秒的非本批背景流量每方向均 <100 MiB/s；接口名从项目 `config.sh` 读取并在 preflight 冻结，禁止猜接口。
- 三 TiKV 的 `process_cpu_seconds_total` 用相邻样本差分，空闲期单节点 <1 CPU core；TiKV 指标抓取无超时。

首次不通过只等待并继续采样，最多 10 分钟；仍不通过 STOP。不得在低负载瞬间挑一个单点放行，也不得因为后续带宽不好回来重选起点。

### 6.3 正式状态基点的建立

W1 后的 `reset_to_gate` 在步骤 5 达到对象收敛时，直接取该步骤最后 3 个样本各自的中位数作为 `FORMAL_BASE_OBJECTS`、`FORMAL_BASE_STORED`、`FORMAL_BASE_MAX_AVAIL`，随即冻结；然后继续完成步骤 6--11。不得在空闲门通过后为了建立基点额外等待或取全量快照。正式 arm 期间不得更新基点。历史约 2,434,614 objects 仅作预期，不硬编码为当日基点。

---

## 七、批次常驻采集与扰动约束

### 7.1 只启动一次

W0 前启动一套批次常驻采集器，直到 final reset 后统一停止并 `wait`。禁止每 arm 反复启停采集器，禁止同一指标启动重复 sampler：

| 采集项 | 周期 | 约束 |
|---|---:|---|
| JuiceFS `.stats` 精确写侧键 | 1 秒 | 只抽取既定 key，不保存整份端点全文 |
| 客户端 `/proc` CPU、内存及两张 NIC | 1 秒 | 轻量文本读取 |
| 三 TiKV 精确指标子集 | 5 秒 | 顺序抓取，保存 local/remote epoch；禁止三端点并发突发抓取 |
| Ceph health/PG/scrub/up_from | 30 秒 | 一个 sampler |
| pool objects/stored/max_avail + 硬看门狗 | 15 秒 | 一个 sampler，不能另起重复对象采样 |

TiKV 只持续保存 03-18 已验证的 histogram sum/count/labels 与 CPU、pending-compaction、cache/raft 必需子集；完整 `/metrics` 仅在批首、W1 的 `reset_to_gate` **开始前**和批尾各 gzip 快照一次，且快照后必须再走完整 reset。禁止在最后一次 drop_caches 后、空闲门与 fio 之间抓全量 metrics；禁止 1 Hz 持续保存完整 TiKV/PD metrics。采集进程使用 `nice -n 19`；不得与 fio 做 CPU 绑定竞争。

持续采集的指标名在 preflight 必须从真实 endpoint 验证存在，不允许凭印象改名。客户端 `http://127.0.0.1:9567/metrics` 固定抽取：

```text
juicefs_meta_ops_duration_seconds_Write
juicefs_meta_ops_total_Write
juicefs_meta_ops_durations_histogram_seconds_{sum,total}
juicefs_transaction_durations_histogram_seconds_{sum,total}
juicefs_fuse_ops_total_write
juicefs_fuse_write_size_bytes_sum
juicefs_object_request_durations_histogram_seconds_PUT_{sum,total}
juicefs_object_request_data_bytes_PUT
juicefs_object_request_uploading
juicefs_process_cpu_seconds_total
juicefs_used_buffer_size_bytes
juicefs_staging_blocks
```

三 TiKV 固定抽取 03-18 已实采的下列 metric family，并完整保留 labels：

```text
tikv_storage_engine_async_request_duration_seconds_{sum,count}
tikv_storage_command_total
tikv_engine_cache_efficiency
tikv_scheduler_{command,latch_wait,processing_read}_duration_seconds_{sum,count}
tikv_raftstore_{append,commit,apply}_log_duration_seconds_{sum,count}
tikv_raftstore_apply_wait_time_duration_seconds_{sum,count}
tikv_engine_pending_compaction_bytes
process_cpu_seconds_total
```

任一核心 family 在任一 endpoint 缺失，预热前 STOP。若确系版本改名，只能回报真实 exposition 与脚本 diff，等待重新冻结，不能现场猜一个近似键。

03-18 已知有问题的 host 采集不得复用：不使用 `ps pcpu` 累计平均作区间 CPU，不使用 `iostat 1 1` 首报，不把三节点输出写进同一文件。主机 CPU 以 Prometheus counter 差分为准；本任务不额外启动高频 iostat。

### 7.2 每 arm 只做边界快照

fio 前后各保存一次 `.stats` 精确键、TiKV 精确指标、pool/health 和进程身份快照；快照命令与顺序固定。全量 metrics 不在 arm 边界抓取，避免其体量成为不等时扰动。

### 7.3 对象硬看门狗

- 每 15 秒样本含 epoch、active arm、objects、stored、max_avail、解析状态。
- 任一 `objects>8,000,000`，或连续 3 次解析失败，或采样间隔 >20 秒：只向当前 arm 已登记的 fio 进程组发 SIGINT，最多等 60 秒；仍不退出才对该精确进程组发 SIGTERM。
- STOP 后保存现场并执行安全复位；无论对象数是否恢复，都禁止继续后续 arm。
- 只记录而不能停止 fio，不算硬看门狗。

---

## 八、每个 arm 的固定执行步骤

1. 上一 arm 后完成且仅完成一次 `reset_to_gate`；首个 W0 前也执行一次。
2. 验证同一挂载 PID/starttime、实跑 binary md5、max_read=262144、proc 私有 conf 的 msgr=8。
3. 验证 jobfile md5、256 job、extent/inode 映射和日志前缀；保存 PRE 边界快照。
4. 登记 phase marker 后以独立进程组启动 fio，保存精确 PID/PGID；不得 `pkill -f` 或 `killall`。
5. fio 跑满 180 秒，完整保存 stdout/stderr、rc 和 256 份 per-job bw log。
6. fio 退出后先 `wait`，保存 POST 快照，再做机械校验：
   - rc=0、runtime 完整、summary 存在；
   - 恰有 256 份非空 bw log；各 job 第一有效样本的最大启动偏差 ≤2 秒，并覆盖统一稳态窗口；
   - W/B 臂恰有 256 个目标 inode mtime 前进；R 臂恰有 128 个目标 inode 前进，另一层 128 个可写 inode 必须为 0；read_test 始终为 0；
   - 三组文件数量、大小、inode 清单不变；
   - `.stats` 的 fuse write、meta Write、transaction 增量均 >0。
7. 通过机械校验后进入下一次统一复位；失败按 §十一 STOP，不得把无效 arm 当数据续跑。

---

## 九、有效性与稳定性门

### 9.1 冻结的证据路径

执行脚本必须使用下列相对路径；每条门都从指定原始文件机械计算，不允许从终端回忆补写：

```text
commands.sh
fingerprint/{pre,post}.txt
phase.tsv
samplers/{client,tikv-150,tikv-151,tikv-152,ceph,pool}.tsv
samplers/{pids,errors}.txt
reset/<before-arm>/{compact-pre1,compact-pre2,gc,objects,compact-post,tikv-pending,drop-caches,idle-gate}.*
arms/<arm>/{jobfile.md5,fio.stdout,fio.stderr,fio.rc,pre.tsv,post.tsv,bw/*.log}
files/{pre,post,before-arm}.tsv
```

### 9.2 有效性门

| # | 判据 | 原始证据/计算 | 失败处置 |
|---|---|---|---|
| V1 | W0/W1 + 8 个正式 arm 全程同一挂载 PID/starttime | `phase.tsv` 每个边界的 pid/starttime 两列唯一值 | 全批无效 |
| V2 | binary/max_read/msgr8/system conf 指纹全程一致 | `fingerprint/*.txt` 与每 arm `pre/post.tsv` 对冻结 md5/值逐项 diff | STOP/全批无效 |
| V3 | R=256 job/128 inode/2互斥 extent；B=256 job/256 inode；其余 fio 参数相同 | 冻结 jobfile + `files/before-arm.tsv`，按 slot/path/inode/offset/size/seed 复算 | 对应区组无效并 STOP |
| V4 | 每 arm 256 份完整 bw log，启动偏差≤2s，可聚合统一窗口 | `arms/<arm>/bw/*.log` 的文件数、首末 timestamp 和非空行数 | 对应 arm 无效并 STOP |
| V5 | fio rc=0、180s 完整，目标 mtime 数正确，R 非目标层和 read_test 零写 | `fio.rc`、`fio.stdout` runtime；`pre.tsv/post.tsv` 对全部384文件按 inode 比 mtime_ns | STOP |
| V6 | 每轮 reset 完整，objects/stored/max_avail 回正式基点带且稳定，OSD/TiKV cooldown 通过 | 对应 `reset/<before-arm>/` 八类原始文件，禁止只读汇总 verdict | STOP |
| V7 | HEALTH_OK、6 OSD、PG clean、无 scrub/recovery、up_from 不变 | `samplers/ceph.tsv` 全行 + `fingerprint/pre.txt` 的 up_from 基点 | STOP |
| V8 | 常驻采集无重启/重复，核心序列可对齐 | `samplers/pids.txt` 唯一 PID；`errors.txt` 为空；`phase.tsv` 覆盖区间 | 缺主数据则对应 arm 无效 |
| V9 | 文件大小/inode 起止不变；jobfile/script md5 不变 | `files/pre.tsv` vs `files/post.tsv`；manifest 起止复算 | STOP |
| V10 | 每个 arm 前空闲门通过；负载期无离散外部事件 | `idle-gate.tsv` 连续30秒；负载期只查 foreign pid、health/scrub/recovery/up_from，不对含 fio 的 CPU/NIC 总量套空闲阈值 | STOP；当前及后续 arm 不判 |

性能值、快慢态和 R/B 增益不作为执行期 STOP 条件。

---

## 十、分析与判决预案（执行方不计算）

### 10.1 有效带宽

每 arm 以全部 256 job 的最早有效时间为全局 `t0`：

1. 对 `15 ≤ sec-t0 ≤ 175` 的每秒数据先跨 job 求和，再对秒求均值，得到 `BW_eff`。
2. 同时报告 `30..165s` 敏感性窗口，以及按 `test-commands-reference.md` §8 要求截去前 1/4 后的 `45..175s` 聚合逐秒中位数、CV、p10/p90；主判据仍只用阶段统一口径 `15..175s BW_eff`。
3. 禁止每文件各取 t0，禁止缺日志时用 fio summary 补算。

### 10.2 区组效应与漂移

```text
Block0_R = mean(R0-a, R0-b)
Block0_B = mean(B0-a, B0-b)
G0       = Block0_B / Block0_R

Block1_R = mean(R1-a, R1-b)
Block1_B = mean(B1-a, B1-b)
G1       = Block1_B / Block1_R
```

ABBA/BAAB 使每个区组 R/B 的平均时间位置相同，可抵消一阶线性漂移。另计算每种 arm 两个端点的相对极差 `D`，并报告 transaction latency、对象轨迹和外部负载协变量。

### 10.3 稳定性先于性能结论

满足以下全部条件才允许签 inode 主效应：

- `R0-a/R0-b`、`B0-a/B0-b`、`R1-a/R1-b`、`B1-a/B1-b` 各自相对极差均 ≤5%；
- 每个正式 arm 在 `15..175s` 的聚合逐秒 BW CV ≤5%，且 `[15,55)`、`[55,95)`、`[95,135)`、`[135,175]` 四个子窗均值的最大/最小比 ≤1.10；数据源为该 arm 的 256 份 `bw/*.log`；
- 两个区组的效应同号，且 `|G0-G1|≤5` 个百分点；
- 主窗口、敏感性窗口和 `45..175s` 稳态中位数的效应方向相同；
- 无 V1--V10 失败。

任一不满足：结论为 `STABILITY_FAIL/INCONCLUSIVE`，先从 transaction 双态、对象复位、外部负载或采集完整性定位波动；禁止把其中“好看的”一轮留下再补跑。

### 10.4 主效应判决

仅在 §10.3 通过后：

| 情形 | 判定 |
|---|---|
| G0、G1 均 ≥1.10，且每个区组增益 ≥该区组最大 D 的 2 倍 | 活跃 inode 数有可复现正效应 |
| G0、G1 均在 0.95--1.05 | 128→256 inode 无可判收益，共享墙主导 |
| 增益 5%--10% | 部分扩展；只量化，不外推达标 |
| 两区组不一致 | 不可判，按稳定性/文件层差异分析 |
| 四个 B arm 均 ≥6250，B 臂极差≤5% | 架构对照达到目标；仍不替代原 128-inode 验收 |

理想 inode 模型的一阶增益是 2 倍；机制预测使用 transaction 周期修正：

```text
P_block = 2 × (txn_per_write_R × txn_latency_R)
              / (txn_per_write_B × txn_latency_B)
```

`G` 显著上升但低于 `P`，说明增加 inode 后开始撞共享 TiKV、CPU、Ceph 或网络平台；`G≈1` 且 transaction 延迟/排队上升，则共享层已主导。`meta Write` 延迟只用于解释每 inode 队列，不作独立交叉验证。

---

## 十一、STOP 条件

| # | 条件 |
|---|---|
| S1 | 任务书、执行脚本、jobfile、binary 或 system ceph.conf md5 与冻结值不符 |
| S2 | 结果目录/archive 已存在，或唯一 T56 flock 获取失败 |
| S3 | 残留压测/GC/compact/采样进程无法确认归属，或挂载无法优雅处理 |
| S4 | 实跑 binary、max_read、proc 私有 conf 或挂载 PID/starttime 不符 |
| S5 | 文件集、P0/P1、R/B job/extent/inode 映射任一校验失败 |
| S6 | jobfile可能创建、截断、越界或触碰 read_test；固定 seed/slot 不一致 |
| S7 | health/OSD/PG/up_from/scrub/recovery 门失败 |
| S8 | reset_to_gate 任一步失败、超时、部分 drop_caches 或对象未回正式基点 |
| S9 | fio rc/runtime/summary/bw log/启动偏差/mtime 校验失败 |
| S10 | 对象数越 8M，或对象看门狗失效/连续3次取数失败/间隔>20s |
| S11 | `.stats` 关键计数器缺失或增量≤0，或采集器重启/重复/时间不可对齐 |
| S12 | 外部负载门 10 分钟不能恢复，或 fio 内出现 foreign pid、scrub/recovery、health/up_from 离散事件 |
| S13 | 根分区可用<5GiB、内存 available<32GiB |
| S14 | 任一文件被创建、删除、截断，或 inode/大小改变 |

明确不 STOP：BW 高低、快慢态、G 是否达标。上述性能现象只能在有效数据上事后分析。

任何 STOP 都必须停止精确子进程、保留现场、在安全时执行 final reset、打包已有证据；不得自行修改任务变量或选择性重跑。

---

## 十二、批首、批尾与回传物

### 12.1 批首

步骤 0：通读抬头列出的 skill/guide，逐项确认本任务采用“固定 layout、单挂载、每轮四节点 drop_caches、OSD 三指标 cooldown、全局 t0、多 job 求和、常驻采集、精确对象看门狗”的口径，并把确认结果写入 `skill-check-pre.txt`。

随后必须落盘：`commands.sh`（全部实际命令）、任务书/脚本/jobfile/binary/conf md5；`env-snapshot.sh` 的 pre 快照；hostname/时区/fio/资源；无残留进程与唯一锁；Ceph/PG/up_from/pool/OSD compact 三指标；三文件集与 P0/P1 指纹；挂载 PID/starttime/exe/max_read/proc-conf；采集器 PID 清单及其唯一性。

只允许开工前优雅处理遗留挂载。不得删除或移动未知旧目录“腾位置”。

### 12.2 批尾

final reset 完成后停止并 wait 常驻采集器，确认无本批进程残留；复采全部环境/文件/配置指纹并执行 `env-snapshot.sh` post；优雅卸载；生成包内 `MANIFEST.md5` 后归档，再生成 archive md5。

末步：按上述 skill 做合规自查并写 `skill-check-post.txt`，至少核对未 format/destroy/pool delete/restart/remount、每轮 cooldown 三指标全绿、每轮四节点 drop_caches 4/4、统计采用全局 t0 跨 job 求和、没有选择性重跑。任一偏离必须说明对结论的影响。

### 12.3 归档内容

1. `commands.sh`、任务书、实际脚本、4 份正式 jobfile、路径/slot/seed 映射及全部 md5。
2. W0/W1 与 8 个正式 arm 的 fio stdout/stderr/rc、各 256 份 bw log、PRE/POST 精确快照。
3. 每个 reset 的完整状态机日志：两次 pre-GC compact、GC 全文与 rc、对象收敛、post-GC compact、TiKV pending、drop_caches 4/4、静置/空闲门。
4. 批次常驻客户端/TiKV/Ceph/NIC/对象序列、phase markers、采集器 errors 与 PID 清单。
5. 批首/批尾文件 stat、配置/进程/集群指纹、`MANIFEST.md5` 和 archive md5。

GLM 回传报文只写：RUN_ID/起止时间/最终 rc 或 STOP 编号；W0/W1 + 8 个正式 arm 的 fio `WRITE: bw=` 原文和 bw-log 数；挂载实况指纹；正式基点与各 arm 峰值/复位后 objects 原文；归档路径/大小/md5；偏离或异常原文。不要计算 G、均值或结论。

### 12.4 授权边界

- 允许自主修复：不改变矩阵/顺序/门限/清理方式的脚本 bug、路径适配和采集正确性修复；修后必须回传 diff、新 md5 和原因，重新静态审查后才能跑。
- 禁止自主改变：job→inode 映射、ABBA/BAAB 顺序、runtime/QD/范围/seed、清理链、对象/空闲/稳定性门、挂载与集群配置。遇到必须改变这些项才能执行的障碍，STOP 并回报。
- 清理操作白名单只有 OSD compact、四节点 drop_caches、`juicefs gc --compact`。本任务固定复用现有卷，所以通用清卷流程中的 destroy/format 在这里明确禁用；禁止 lazy unmount、`fuser -k`、broad kill、OSD restart 和 pool delete/create。

---

## 十三、完成后的路线

- 可复现正效应且 B 达 6250：形成“128-inode 原测试受同步串行通道限制；256-inode 架构对照可达目标”的边界结论。
- 可复现正效应但未达 6250：用 G 与 transaction 周期量化收益递减及共享墙，不按线性单点外推承诺达标。
- B 无效：确认增加 inode 已不能增加吞吐，限制转为共享 TiKV 事务率、客户端全局路径或数据面。
- 稳定性失败：不追加盲目重复；先用本批协变量定位 transaction 双态、对象复位或外部负载，再另立最小验证。
- 结论闭环后，才在固定交付配置上执行不少于 8 小时最终长稳。
