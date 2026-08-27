# 03-20B 任务书：TiKV NVMe / compaction worker 资源闭环

> 版本：v2（2026-08-23，配套 t59 实现就绪并冻结正式入口）
> 执行方：GLM　｜　分析方：GPT/opencode
> 性质：只读诊断 + 1 个固定 B256 randwrite arm；**只补证据，不调参数**
> 前置报告：`doc/perf-report/03-20A-tikv-inrun-compaction-attribution-20260823.md` §8
> 配套脚本：`scripts/FULLBASELINE/debug/t59-tikv-resource-closure.sh`（**不得复用 t58 直接执行**）

```text
03-18：确认客户端 inode 串行队列 + 同步 TiKV 事务周期
   ↓
03-19：256 inode 有方向性收益，但全部 arm 均前快后慢
   ↓
03-20A：衰减与 TiKV/Raft 延迟、compaction 活动同步
        但 TiKV host sampler 失败，资源根因仅 MECHANISM_PARTIAL
   ↓
03-20B：同一 B256 只补 NVMe / WAL-Raft / worker 证据  ← 你在这里
   ├─ 共享 NVMe 饱和        → 架构结论，停止局部参数扫描
   ├─ NVMe 有余量、worker 满 → 另立单变量 TiKV A-B-A（须授权）
   ├─ Raft/WAL 同步延迟墙    → 架构结论，不调 compaction
   └─ 证据门失败             → STOP，修采集，不产机制结论
```

本任务只做一件事：在不引入任何新实验变量的前提下，补齐 03-20A 缺失的 TiKV 物理盘和后台 worker 运行期证据，将 `MECHANISM_PARTIAL` 收敛为可执行分支。

---

## 〇、背景与已知事实

03-20A 的正式 `15..175s` 窗口复算值为 2827.87 MiB/s，只达到 6250 MiB/s 目标的 45.25%；四个固定子窗为 4201/3658/1952/1533 MiB/s，`W4/W1=0.365`。继 03-19 的 8 个 arm 后，该轮再次复现“前快后慢”。

时间对齐结果显示，带宽下降时：

- storage async write、prewrite、commit、Raft commit/apply wait 延迟持续升高；
- compaction read/write flow 和 pending compaction bytes 快速增大；
- TiKV 总 CPU、客户端 CPU、uploader 和客户端 buffer 反而下降；
- uploader 后半程远低于 150，故当前不支持提高 `max-uploads` 或增加 inode；
- L0、pending bytes 均未到配置 slowdown/soft limit，且未出现 write stall、throttle 或 rate limit。

03-20A 未能完成最终资源归因，因为 TiKV host sampler 在 fio 中途退出，归档只有 PID 文件，没有三主机的有效 iostat；同时缺少 RocksDB thread 运行期序列。当前不能区分：

1. compaction 与 foreground WAL/Raft 竞争同一物理 NVMe；
2. NVMe 尚有余量，但 compaction worker 数量或后台调度能力不足；
3. 盘吞吐未饱和，但同步 fsync/Raft commit 的单次延迟已经构成能力墙。

03-20B 不再证明衰减“是否存在”，也不做任何参数尝试，只补齐这三个分支所需的证据。

---

## 一、目标、结论边界与明确不做的事

### 1.1 唯一主问题

在同一个固定 B256 arm 内，判明 W1→W4 衰减期间 TiKV 的真实块设备、RocksDB compaction worker、foreground WAL/Raft、CPU 和网络分别处于什么资源状态，回答是否存在安全、可验证的 TiKV compaction 调参余量。

### 1.2 本任务只采集，不由 GLM 下机制结论

GLM 只负责执行机械门、保存原始数据并报告偏离。是否“NVMe 饱和”“worker 不足”或“架构墙”，由分析方按 §八预注册口径计算；不得在现场根据单个 `%util`、单个 pending 值或 fio summary 自行选择分支。

### 1.3 本任务禁止

- 不改 JuiceFS、TiKV、PD、Ceph、OSD、内核、网卡、IRQ、NVMe 或文件系统配置；
- 不执行 TiKV/PD/OSD restart、reload、dynamic config、failpoint 或压力注入；
- 不新增、删除、截断、改 layout 文件，不 format/destroy，不删建 pool，不改 CRUSH/PG；
- 不跑 R128、512 inode、`max-uploads=300`、额外预探针、第二个性能 arm 或选择性补跑；
- 不 remount 第二次，不以重新挂载挑选好档；
- 不运行 `t58-tikv-inrun-compaction-attribution.sh`。t58 已知存在 sampler 只 WARN 不 STOP、host 文件未产出、OSD key 解析错误和强杀挂载等问题；
- 不允许 `pkill -f`、`killall`、`fuser -k`、lazy unmount 或 kill JuiceFS 挂载进程。

---

## 二、冻结矩阵与不变量

| 项 | 冻结值 |
|---|---|
| arm | `D-B256`，仅 1 次 |
| jobfile | 03-20A 的 `B0.fio`，md5 **`3b43b01ed2c4033ed42ad52bddc77c2f`** |
| mapping | 03-20A 的 `B0.fio.tsv`，md5 **`f92c7aed945229a11d3898ce3f9c177d`** |
| 文件 | 现有 `storage_test.*.0` 128 个 + `rw_test.*.0` 128 个作为写目标；`read_test.*.0` 128 个只校验 |
| job/inode | 256 job / 256 inode / 每 inode 1 job |
| extent | P0 文件低半区 + P1 文件高半区；每 job 512MiB，总活跃范围 128GiB |
| fio | randwrite、256K、libaio、direct=1、iodepth=64/job、总名义 QD=16384 |
| runtime/seed | 180s；slot+1，与 03-19/03-20A B0 完全相同 |
| binary | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| mount opts | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph client | 进程私有 conf，`ms_async_op_threads=8`；system conf md5 `5b6be34179a64e0a5f9c6d3a9690041f` |
| 对象门 | reset 后 `objects≤2,500,000`；负载期硬上限 8,000,000 |
| 正式性能窗 | 全局对齐后的 `15..175s`；四窗 `[15,55)`、`[55,95)`、`[95,135)`、`[135,175]` |
| 验收目标 | 6250 MiB/s 只记录差距，不是执行期 STOP 条件 |

优先从 03-20A 归档 `/home/lilingfeng/tmp/production/opencode-t3.20a-20260823-141414.tar.gz`（157 留存副本为 `/tmp/production/opencode-t3.20a-20260823-141414.tar.gz`）复制 `B0.fio` 和 `B0.fio.tsv`。若归档侧文件不可直接复制，允许用冻结的 t56 generator 重新生成，但生成后的两个 md5 必须与上表逐字一致；“内容看起来相同”不能放行。md5 不符即 STOP。

---

## 三、执行步骤

### 步骤 0：测试前通读 skill 并写合规确认

执行前通读并将确认写入 `skill-check-pre.txt`：

- `skills/baseline-reproduction-skill.md` §2.2/§2.4/§3.3/§3.4/§3.6；
- `skills/TESTING-GUIDE.md` §1.1/§1.3/§2.2/§3.2/§5.6；
- `skills/test-commands-reference.md` §8.2--§8.4、§9、§11；
- `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.1--§二.12；
- 本任务书全文，特别是 sampler 硬门、设备映射、停止与卸载红线。

本任务有两项有意收窄：

1. 禁止通用指南中的 60s randwrite meta 探针，因为它会预先制造本任务要观察的 compaction/TiKV 状态；正式 B256 是唯一写负载。
2. 禁止通用清卷流程；复用已验证的 384 个文件，只允许既定 reset 中的一次 `juicefs gc --compact`、OSD compact/cooldown 和四节点 drop_caches。

### 步骤 0.1：先写 t59，静态复审后才上环境

使用独立的 `t59-tikv-resource-closure.sh`，不得复制 t58 后不审即跑。部署到 157 的 `/tmp` 后，先只执行：

```text
/tmp/03-20B-tikv-nvme-compaction-worker-closure.md
/tmp/t59-tikv-resource-closure.sh
/tmp/t56-gen-jobfiles.sh
/tmp/t56-validate-jobfiles.sh
/tmp/env-snapshot.sh
/tmp/juicefs-03-8
```

- `bash -n`；
- ShellCheck（若环境已有；没有则记录，不安装新包）；
- 所有脚本、任务书、B0 jobfile/mapping、binary 和 conf 的 md5；
- `bash /tmp/t59-tikv-resource-closure.sh --self-test`；
- `bash /tmp/t59-tikv-resource-closure.sh --dry-run <RUN_ID>`，只检查依赖、命令拼装和解析器，不挂载、不 SSH、不执行 Ceph/reset/fio。

把静态 diff、md5、`bash -n`、dry-run 输出回传分析方；收到书面放行前不得开始环境执行。正式入口只能有一个：

```bash
RUN_ID=$(date +%Y%m%d-%H%M%S)
T59_SKILL_CONFIRMED=YES bash /tmp/t59-tikv-resource-closure.sh "$RUN_ID"
```

若 157 到 150--152 不能使用现有 SSH key/agent，执行方可在当前 shell 预先 `export T59_SSH_PASS`；脚本仅通过 `sshpass -e` 向 SSH 子进程传递，不写入命令行、commands.sh、挂载进程环境或归档。不得把密码直接拼进启动命令。

结果目录、归档或锁已存在均 STOP；不得删除旧目录、覆盖或改名继续。

### 步骤 1：批首只读门与单次挂载

以下任何一项失败均在启动 sampler/fio 前 STOP：

1. `/tmp` 可用空间 ≥8GiB，客户端 `MemAvailable≥32GiB`；157、150--152 SSH 可达。
2. 不存在外部 fio、layout、GC、compact、本任务或其他 JuiceFS 压测；`/mnt/juicefs` 若已挂载或有未知 mount 进程，STOP，脚本不得代用户清理。
3. `ceph health=HEALTH_OK`，6 OSD 全 up/in，PG 全 active+clean，无 scrub/deep-scrub/recovery/backfill；冻结 OSD `up_from`。
4. 三个 TiKV 服务 active，冻结 PID/starttime/exe/config md5；保存 `/proc/<pid>/cmdline`、`systemctl show`、TiKV `/config` 和完整 metrics exposition。
5. 只挂载一次；验证 mount PID/starttime、实跑 exe md5、`max_read=262144`、私有 `CEPH_CONF` 及 `ms_async_op_threads=8`。
6. 全量 stat 384 个文件，三组各 128 个、每个恰为 1GiB；保存 path/inode/size/mtime_ns。禁止 spot check。
7. 复制并校验冻结的 B0 jobfile/mapping md5；再运行 t56 validator，必须全通过。
8. 执行 `env-snapshot.sh ... pre`；保存客户端、Ceph、TiKV 身份和配置指纹。

### 步骤 2：冻结 TiKV 路径到物理设备映射

对 150--152 分别执行，只读保存原文，不允许凭 `/mnt/jfs-tikv` 名称猜盘：

1. 从 TiKV `/config`、进程 cmdline 和 config 文件确定 KV data-dir、Raft engine/RaftDB、RocksDB WAL dir；缺省路径也必须展开成绝对路径。
2. 对每个路径保存 `findmnt -T <path> -o TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN`、`df -T`、`lsblk -e7 -o NAME,KNAME,PKNAME,TYPE,MAJ:MIN,SIZE,ROTA,MOUNTPOINTS,FSTYPE`、`readlink -f`。
3. 若 source 是 LVM/dm/md/分区，递归展开到所有 leaf block device；保存 logical device 和每个 leaf device，不能只采 `nvme0n1` 或 `dm-*` 的其中一个。
4. 保存 `/sys/block/<dev>/queue/{scheduler,nr_requests,read_ahead_kb,rotational}` 和 `/proc/diskstats` 初值；只读，禁止修改 sysfs。
5. 输出 `device-map.tsv`，每行至少含 host、TiKV path role（KV/Raft/WAL）、path、mount source、major:minor、logical device、leaf device。三节点任一 role 无法映射，STOP。

若 KV、Raft/WAL 最终映射到同一 leaf device，必须原样记录；这本身是架构事实，但不是现场结论。

### 步骤 3：指标 exposition 与 OSD key 预检

1. 在三 TiKV 完整 exposition 中逐节点验证下列实际 family 存在，并把匹配原文保存到 `preflight/metric-proof-<ip>.txt`：

```text
tikv_thread_cpu_seconds_total
tikv_threads_io_bytes_total
tikv_threads_state
tikv_engine_compaction_flow_bytes
tikv_engine_compaction_duration_seconds_{sum,count}
tikv_engine_num_subcompaction_scheduled
tikv_engine_pending_compaction_bytes
tikv_engine_num_files_at_level
tikv_engine_wal_file_sync_micro_seconds
tikv_engine_wal_file_synced
tikv_storage_engine_async_request_duration_seconds_{sum,count}
tikv_scheduler_{command,latch_wait,processing_read}_duration_seconds_{sum,count}
tikv_raftstore_{append,commit,apply}_log_duration_seconds_{sum,count}
tikv_raftstore_apply_wait_time_duration_secs_{sum,count}
tikv_engine_stall_micro_seconds
tikv_engine_write_stall
tikv_engine_write_stall_reason
tikv_scheduler_pending_compaction_bytes
tikv_rate_limiter_max_bytes_per_sec
process_cpu_seconds_total
```

2. `tikv_thread_cpu_seconds_total` 和 `tikv_threads_io_bytes_total` 必须保留完整 `name/tid/io` labels；预检需证明三个节点均可看到 `rocksdb:low`、`rocksdb:high`、raftstore、apply 线程。03-20A exposition 已显示单节点有 6 个 `rocksdb:low` 和 3 个 `rocksdb:high`，但本任务仍须逐节点实查，禁止硬编码线程数。
3. `tikv_threads_state` 当前仅为全进程状态汇总，作为旁证保存，**不得把它冒充 RocksDB pool 活跃度**。
4. 客户端 HTTP `/metrics` 逐项验证 uploader、buffer、JuiceFS process CPU、meta Write、transaction、PUT、fuse write。duration 必须有 `sum`，并实查与它同语义、同 labels 的 `count`、`total` 或独立 op counter，保存映射表后冻结采集正则；禁止凭后缀猜配对。不存在 `.stats` 不阻断资源主问题；若确实没有等价计数器，标为 `CLIENT_AVG_PARTIAL`，但仍须保存 duration sum 和完整 exposition。uploader/buffer 或 TiKV 资源主指标缺失才 STOP。
5. 对 6 个 OSD 各保存一次完整 `perf dump` JSON，用递归 key 检查实查并冻结 `rocksdb.compact_running`、`rocksdb.compact_queue_len`、`bluestore.kv_sync_lat.avgtime` 的准确 JSON 路径。03-18 同集群已有这些字段；若本轮取不到，视为 parser/命令问题，STOP 回传 raw JSON，禁止退化为固定等待。

### 步骤 4：启动一次正式 sampler，并完成 120s 空载存活预检

所有正式 sampler 在 reset 前启动一次，持续覆盖 reset、quiet、B256、final reset，最后统一停止；不得在 fio 前重启 sampler。每类必须有独立 PID、heartbeat、raw 和 parsed 文件，单个 sampler 失败不得连带吞掉其他文件。

| sampler | 周期 | 必须保存的数据 |
|---|---:|---|
| client runtime | 1s | JuiceFS HTTP metrics 原始行：uploader/buffer/CPU/meta/transaction/PUT/fuse write 的 sum+count |
| client host | 1s | `/proc/stat`、meminfo、数据网/TiKV 网 `/proc/net/dev` |
| TiKV metrics | 5s | §3 全部 TiKV family，三 endpoint 各自 local request start/end + remote metric labels |
| TiKV device | 1s | 每台每个 logical+leaf device 的原始 iostat 和解析 TSV；`r/s,w/s,rMiB/s,wMiB/s,await,r_await,w_await,aqu-sz,%util` |
| TiKV proc/host | 1s | `/proc/stat`、`/proc/pressure/{io,cpu}`、`/proc/<pid>/{stat,io,status}`、相关网卡 RX/TX、远端 epoch |
| TiKV thread | 5s | thread CPU/IO 完整 labels；可与 TiKV metrics 同请求，但文件必须可独立验证 |
| Ceph | 30s | health、PG、scrub/recovery、up_from |
| pool watchdog | 15s | 单次 JSON 请求得到 objects/stored/max_avail + parse 状态 |
| OSD cooldown | 5s（仅 reset 阶段） | 六 OSD 三个实查字段的原始 JSON 与解析值 |

设备 sampler 可使用连续 `iostat -y -x -d -t 1 <devices>`，也可逐秒读取 `/proc/diskstats` 后计算；无论实现方式，必须同时保留原始值和解析 TSV，且首个累计样本不得冒充区间值。若使用 SSH 流式进程，需记录本地 SSH PID 与远端 PID，并以 trap 精确回收。

禁止在 sampler loop 中因某一次 `curl/ssh/grep` 非零而静默退出。每次失败写 `errors.tsv` 并继续 heartbeat；连续失败达到硬门后由主看门统一 STOP。

启动后先空载连续运行 120s，机械验收：

- 1s sampler 每个目标至少 100 个可解析区间样本，最大 heartbeat gap ≤3s；
- 5s sampler 每 endpoint 至少 20 个可解析样本，最大 gap ≤8s；
- pool 至少 7 个样本，最大 gap ≤20s；Ceph 至少 3 个样本，最大 gap ≤40s；
- 三 TiKV 的每个冻结 device 都有非空 iostat/diskstats 数值；不得只有 `.pid` 文件；
- thread CPU/IO 至少包含所有实查到的 `rocksdb:low/high` TID，counter 单调不减；
- 全部 sampler PID/starttime 与启动记录一致，120s 内无重启；
- 校验三个主机的时钟：保存 5 次 local-send/remote-epoch/local-receive，按 RTT 中点算 offset；RTT 抖动或校正残差 >500ms 则 STOP，不得执行 fio。

任一项失败：写 `STOP.txt`、保存现场、停止精确 sampler PID、归档本次 preflight，**不运行 fio**。修复需新脚本 md5 和新 RUN_ID，再走静态复审；不得在同目录原地修补继续。

### 步骤 5：统一 reset 与静稳门

sampler 通过预检后保持原进程继续运行，按 03-20A 同一顺序 reset：

1. `sync -f /mnt/juicefs`。
2. 全 OSD 发 compact；每 5s 保存 6 个 OSD 的 raw perf dump，连续 3 个样本同时满足 `compact_running=0`、`compact_queue_len=0`、`kv_sync_lat.avgtime<0.002s`。任一 tell/parse 失败均未通过，最多 10min。
3. 为保持 03-20A reset 顺序一致，在第一个可观测 cooldown 通过后固定 quiet 30s，再执行第二次全 OSD compact，并重新以三个真实字段完成 cooldown。这里的 30s 只是冻结的 quiet interval，**不能代替前后任一次可观测 cooldown**。
4. 只执行一次 `juicefs gc --compact "$META"`，保存命令、stdout/stderr、rc 和起止 epoch；rc 非 0 STOP。
5. 从常驻 pool sampler 等待连续 3 个 15s 样本：objects≤2,500,000、不递增、极差≤128，stored/max_avail 极差各≤64MiB；取中位数为正式基点。
6. GC 后第三次执行完整 OSD compact/cooldown，不沿用 GC 前结果。
7. 三 TiKV endpoint 的 default/write/lock/raft CF 连续 3 个 5s 样本 pending 全为 0；缺 endpoint/CF 或解析失败不放行，最多 10min。
8. 全量 stat 384 文件；客户端与 150--152 各 `sync + drop_caches`，必须 4/4 成功。
9. quiet 60s。期间只保留已启动的 sampler，不抓 full metrics、不遍历文件、不运行探针、不新增 SSH/监控进程。
10. quiet 最后 30s 通过空闲门，门通过至 fio start ≤10s：
   - HEALTH_OK、6 OSD、PG clean、无 scrub/recovery，up_from 不变；
   - 客户端 CPU idle≥70%、iowait≤5%、steal≤1%；
   - 三 TiKV `process_cpu_seconds_total` 30s 差分各 <1 core，四 CF pending=0；
   - 客户端和三 TiKV 的相关网卡背景流量每方向 <100MiB/s；
   - 所有 sampler PID/starttime 不变，heartbeat gap 仍满足 §4；
   - 三 TiKV device 的 30s 基线数值完整，作为 W1 相对比较基准，不以低 `%util` 单点挑时刻。

空闲门最多等待 10min，不得选择某个瞬时样本放行。因 Weka 常驻进程，本任务不使用 load1 门，但必须保留 CPU/IO PSI 和进程 CPU 门。

### 步骤 6：唯一正式 arm `D-B256`

1. 保存 PRE：客户端/TiKV 精确快照、pool/health、384 文件 stat、mount/TiKV 身份、device-map 和当前 sampler 完整性摘要。
2. 记录 `fio_start_epoch_ns` 和 phase marker，以 `setsid` 启动冻结 B0 jobfile，保存精确 PID/PGID；bw log prefix 必须唯一。
3. fio 跑 180s；主看门每 2s 检查：
   - mount PID/starttime；三 TiKV PID/starttime；
   - 每个核心 sampler PID/starttime；
   - 1s sampler heartbeat age≤3s、5s sampler≤8s、pool≤20s、Ceph≤40s；
   - pool JSON parse 连续失败次数、objects 硬上限；
   - Ceph/OSD/PG/up_from 离散事件。
4. 任一核心 sampler 死亡、重启或 heartbeat 超时：立即写 `STOP.txt`，只向已登记 fio PGID 发 SIGINT；60s 后仍存活才向同一 PGID 发 SIGTERM。禁止继续采一个“部分有效”arm，禁止 broad kill。
5. `objects>8,000,000` 或 pool 连续 3 次解析失败同样触发上述精确 STOP；性能高低不触发 STOP。
6. fio 完成后 `wait`，记录 `fio_end_epoch_ns`、stdout/stderr/rc 和 POST 精确快照；不得根据 BW 决定补跑。
7. 机械校验：
   - fio rc=0、runtime 达标、恰好 256 份非空 per-job bw log，首样本偏差≤2s且覆盖共同 `15..175s`；
   - 256 个目标文件 mtime_ns 前进，128 个 `read_test` 不变，384 文件数量/inode/size 不变；
   - 客户端 meta/transaction/PUT/fuse write counter 增量>0；
   - 所有核心 sampler 从 quiet 前连续覆盖到 POST，无重启、无超限时间洞；
   - 三主机所有冻结设备在正式窗口每秒都有可解析区间值；允许极少单点缺失，但每台/每窗覆盖率必须≥95%，否则资源根因无效；
   - thread CPU/IO counter 每台/每窗覆盖率≥90%，TID 集合变化必须记录，不能静默丢弃。

### 步骤 7：final reset、停止 sampler 与安全卸载

1. 无论 arm 成败均先保存故障现场和 POST 快照，再执行与步骤 5 相同的 final reset，目标是对象回正式基点带、OSD cooldown 通过、TiKV 四 CF pending 归零。最多等待 30min；未回归则记录 cleanup failure，不自动重跑。
2. 停止并 `wait` 本任务登记的 sampler 精确 PID；若有远端流式 sampler，只终止登记的远端 PID并验证退出。禁止模式匹配杀进程。
3. 执行 post env snapshot，复核 mount/TiKV/OSD PID/starttime、配置 md5、up_from、device map 未变。
4. 只允许优雅卸载本任务创建的挂载，可依次尝试 JuiceFS 自带 umount、`fusermount3 -u`/`fusermount -u`、普通 `umount`；**禁止 `-l`、`-f` 和 kill mount PID**。仍失败则保留挂载、记录阻塞进程/内核状态并 STOP，由用户人工处置。
5. 生成 MANIFEST 和归档 md5；归档前验证核心 raw/parsed 文件非空及覆盖率，不能只检查文件存在。

### 步骤 8：测试后 skill 合规复查

写入 `skill-check-post.txt`，逐项确认：

- 无 format/destroy/pool delete/restart/config change/layout/第二挂载/额外 arm；
- 仅使用规定 reset 白名单，无 mutating preprobe；
- 每次 OSD cooldown 均由三个实查字段连续 3 点放行，没有固定等待降级；
- fio 前四节点 drop_caches 完成；
- sampler 先通过 120s 预检，正式窗口无死亡/重启/超限 gap；
- 设备映射覆盖所有 KV/Raft/WAL leaf device；
- 统计使用多 job 时间对齐求和，未用单 log×256 或 fio summary 代替；
- 未强杀挂载、未 broad kill、未自动补跑。

任一不符必须在回传首屏和报告中显式列出，并说明影响到“性能现象”“TiKV 近端归因”还是“资源根因归因”。

---

## 四、原始数据与交付物

结果目录：`/tmp/opencode-t3.20b-<RUN_ID>`；归档：`/tmp/production/opencode-t3.20b-<RUN_ID>.tar.gz`。

至少包含：

```text
commands.sh
skill-check-{pre,post}.txt
taskbook.md / t59-script.sh / script-and-input.md5
env-snapshot-{pre,post}.txt
preflight/{sampler-validation.txt,clock-offset.tsv,metric-proof-*.txt,osd-key-proof/*}
fingerprint/{mount,tikv,ceph,files,config}-{pre,post}.*
device/device-map.tsv
device/<ip>/{findmnt,lsblk,df,sysfs,diskstats}-*.txt
jobfiles/B0.fio{,.tsv}
reset/{preload,final}/...
arm/D-B256/{fio.stdout,fio.stderr,fio.rc,timing.tsv,pre*,post*,bw/*.log}
samplers/pids.tsv
samplers/heartbeats.tsv
samplers/errors.tsv
samplers/client-{runtime,host}.{raw,tsv}
samplers/tikv-metrics-<ip>.{raw,tsv}
samplers/tikv-threads-<ip>.{raw,tsv}
samplers/tikv-device-<ip>.{raw,tsv}
samplers/tikv-host-<ip>.{raw,tsv}
samplers/{ceph,pool}.{raw,tsv}
metrics-full/tikv-<ip>-{pre,post}.prom.gz
phase.tsv / STOP.txt（若触发）
coverage.tsv
MANIFEST.md5
```

GLM 回传只需：

1. RUN_ID、起止时间、最终 rc/STOP 编号；
2. fio `WRITE: bw=` 原文、256 日志数和 runtime；
3. mount 与三 TiKV PID/starttime/config md5 是否全程不变；
4. 三节点 KV/Raft/WAL→logical/leaf device 映射摘要；
5. sampler 120s 预检结果、正式窗口逐类覆盖率、最大 gap 和 errors 数；
6. preload/峰值/final 的 objects/stored/max_avail；
7. final reset、OSD cooldown、TiKV pending 和优雅卸载结果；
8. 归档路径、大小、完整 md5；
9. 所有脚本偏离和环境异常。

不要现场计算机制结论，不要只摘录平均 `%util`，不要删除 raw exposition/iostat/perf dump。

报告落点：`doc/perf-report/03-20B-tikv-nvme-compaction-worker-closure-<YYYYMMDD>.md`。在分析方完成后再更新 `doc/deploy-log/results-table.md` 和 03 阶段计划；GLM 不预写结论。

---

## 五、分析口径与预注册决策树（供分析方，GLM 只交原始数据）

### 5.1 时间轴与带宽

- 以 fio 正式记录的 start epoch 和 256 份 bw log 建立全局 `t0`；所有远端数据先用 `clock-offset.tsv` 校正。
- 256 job 按时间戳对齐后逐秒求和；正式均值 `15..175s`，并报告 `30..165s`、`45..175s` 中位数/P10/P90/CV。
- 固定比较 W1--W4，不事后移动窗。fio summary 仅作完整性旁证。
- 03-20A 的 2827.87 MiB/s 只作同配置外部锚，不作为本轮有效性门；本轮不因不相等而补跑。

### 5.2 主机与线程计算来源

| 结论量 | 数据来源与算法 |
|---|---|
| device busy/util | `samplers/tikv-device-<ip>.tsv`；优先由相邻 `/proc/diskstats` busy_ms 差分÷区间，同时与 iostat `%util` 互证 |
| device 吞吐/IOPS | 同文件，相邻 sectors/IO count 差分÷区间；与 iostat r/w MiB/s、r/s、w/s 互证 |
| await/queue | iostat 真区间 `r_await/w_await/await/aqu-sz`；首个累计样本禁用 |
| 主机 CPU/IO 压力 | `tikv-host-<ip>.tsv` 的 `/proc/stat` 与 `/proc/pressure/io` 相邻差分 |
| TiKV 进程 I/O | 同文件 `/proc/<pid>/io` 的 read_bytes/write_bytes/syscr/syscw 差分 |
| thread CPU 利用率 | `tikv-threads-<ip>.tsv` 中同 `name+tid` 的 `Δcpu_seconds/Δwall_seconds`；按 rocksdb:low/high、raftstore、apply 分组求和，并除以实际线程数 |
| thread I/O | 同文件中 `tikv_threads_io_bytes_total` 按 `name+tid+io` 差分，按线程池分组 |
| TiKV/Raft 延迟 | `tikv-metrics-<ip>.tsv` 中同 label 的 `Δsum/Δcount`；禁止用累计 sum 直接当平均延迟 |
| compaction debt/flow | pending 为 gauge；flow 为相邻 counter 差分÷区间；按 endpoint+CF 分开后再汇总 |
| client uploader/buffer | `client-runtime.tsv`，按固定窗口统计均值、中位数、末值及触顶占比 |

所有资源量先按 host/device/CF/thread pool 分开画时间线，再给集群聚合；禁止三节点求和后掩盖单节点热点。相关性只作时间归属，不能单独宣称因果。

### 5.3 判定原则

| 组合证据 | 结论 | 下一步 |
|---|---|---|
| 至少构成 Raft quorum 的两个节点，其相关 leaf device 在 W3/W4 相对 W1 同时出现持续高 busy/util、await/queue 显著上升或 IO PSI，且 foreground WAL/Raft 与 compaction I/O 同期存在；CPU/thread 未先成为上限 | **共享 NVMe I/O 墙** | 停止 inode/uploader/compaction 参数盲调；输出同步复制元数据与 compaction 共享设备的架构结论，讨论元数据分片/扩容、更快或隔离 NVMe、降低同步事务频率 |
| leaf NVMe 在 W3/W4 有明确余量，await/queue/IO PSI 不升；`rocksdb:low` 实际线程长期接近满 CPU或每线程持续工作，线程数固定，pending 持续增长；前台 CPU/网络也有余量 | **compaction worker/config 候选** | 只提出一个与实测线程池相符的 TiKV 参数，另立 A-B-A/ABBA；参数、值、重启均须用户授权 |
| NVMe 吞吐/busy 有余量，compaction worker 不满，但 WAL sync、Raft append/commit/apply 延迟持续上升并与 BW 反向；低队列同步 IO 的单次 await/fsync 上升 | **同步 Raft/WAL 延迟墙** | 不做 compaction 实验；转设备隔离、Raft/WAL 布局、节点/region 或同步事务频率的架构分析 |
| TiKV 设备、worker、Raft/WAL 全稳定，但 uploader 仍不触顶、客户端队列/transaction 恶化 | **客户端内部机制未闭合** | 下一任务补 inode queue/lock/retry/transaction 分段插桩，不增加 inode |
| uploader 在 W3/W4 持续触顶 150，TiKV/客户端/网卡均有清楚余量 | **上传并发才重新成为候选** | 另立 `max-uploads` 单变量测试；03-20B 本身仍不改 |

“显著上升”必须同时报告绝对值和 W3/W4 相对 W1 的倍数，并有至少两个连续 5s 区间，不以单点峰值判定。NVMe 饱和不能只看 `%util`；worker 不足不能只看 pending bytes；同步墙不能只看 Raft latency。若证据组合不满足任何一行，结论保持 `MECHANISM_PARTIAL`，不得硬选分支。

---

## 六、有效性门与 STOP 编号

| 编号 | 条件 | 处置 |
|---|---|---|
| S01 | 输入文件、binary、脚本、conf md5 不符 | fio 前 STOP |
| S02 | mount/TiKV/OSD 身份或配置发生变化 | STOP；性能和机制均无效 |
| S03 | 384 文件、B0 mapping、runtime/QD/seed 不符 | fio 前 STOP |
| S04 | KV/Raft/WAL 任一路径无法映射到全部 leaf device | fio 前 STOP |
| S05 | TiKV/client 核心 family 或 OSD 三 key 预检失败 | fio 前 STOP，不得降级 |
| S06 | sampler 120s 预检数量、内容、heartbeat、时钟任一不合格 | fio 前 STOP |
| S07 | preload reset、pending=0、idle gate 原始证据不完整 | fio 前 STOP |
| S08 | fio 期间核心 sampler 死亡/重启/heartbeat 超时 | 精确终止 fio；资源根因无效 |
| S09 | objects>8M、pool 连续解析失败或 health/PG/up_from 离散事件 | 精确终止 fio；不得补跑 |
| S10 | fio rc/runtime/256 logs/mtime/文件不变量失败 | 性能 arm 无效 |
| S11 | device 每窗覆盖率<95%或 thread 每窗<90% | 资源根因无效，保持 `MECHANISM_PARTIAL` |
| S12 | final reset 未回基点或优雅卸载失败 | 测量可单独评估，但 cleanup FAIL；禁止强杀 |
| S13 | 发生配置修改、restart、第二 arm、remount、layout 或 broad kill | 全任务无效 |

任何 STOP 都须：先写编号、epoch、phase、触发值和命令 rc，再终止精确子进程、保存现场并归档。禁止修变量后在同 RUN_ID 继续，禁止自动重跑。

---

## 七、通用注意事项与本任务适用方式

1. **统计口径**：保存全部 per-job 1s bw log；多 job 按时间戳对齐求和。禁止单 log×job 数，禁止用 fio summary 冒充正式窗口。
2. **冷态**：direct=1 不能替代 drop_caches；fio 前客户端及 150--152 必须 4/4 drop_caches，挂载 `cache-size=0`。
3. **fresh-volume**：复用已有 layout，不使用 `create_on_open`，不建 fresh volume，避免首轮空洞失真。
4. **后端干净态**：OSD compact 后必须用六 OSD 三指标连续 3 点确认；restart 不能替代 cooldown。
5. **环境**：HEALTH_OK、OSD up/in、PG clean；157 有 WekaIO，禁止触碰内核/网卡/RoCE/md0/WekaIO，测试须与 BeeGFS/外部压测错峰。
6. **记录**：保存 `commands.sh`、原始输出、完整 metrics、所有 bw log、pre/post env snapshot、身份和配置指纹；每个数字必须能回溯到文件/字段/算法。
7. **清理**：通用指南的 destroy 流程本任务不适用且明确禁止；本任务不清卷，只执行冻结 reset 白名单，绝不删建 pool。
8. **skill 自查**：步骤 0 和步骤 8 不可省略，偏离必须显式披露。
9. **分层授权**：可修语法、路径、只读采集和解析实现，但修后必须换 md5、静态复审；arm、门限、reset、配置、路径映射、停止规则不得擅改。
10. **挂载档位**：本任务无臂间效应比较且只挂载一次，不运行 mseqread 判档探针、不 detect-and-replace；以同挂载重放 03-20A 固定负载，避免主动引入 remount 波动。
11. **判据数据源**：按 §5.2 固定；指标名必须由 §3 exposition 证明，禁止凭相似名字替换。
12. **静稳快照**：pre/post env snapshot、可观测 cooldown、pending=0、CPU/NIC/IO quiet gate 必须齐全；禁止 60s 写探针和固定 sleep 代替门。

---

## 八、红线汇总

- **一个固定 B256 arm；不调参、不重启、不 remount、不新增 layout、不增加 inode。**
- **sampler 必须先连续存活 120s；正式期间任一核心采集死亡即终止 fio，不能只 WARN。**
- **TiKV KV/Raft/WAL 必须映射到全部真实 leaf device；禁止猜设备或只采一个方便的设备。**
- **OSD cooldown 必须解析三个真实字段；禁止固定等待降级。**
- **只终止登记 PID/PGID；禁止 broad kill，禁止 kill 挂载，禁止 lazy/force unmount。**
- **不得按带宽高低补跑、挑窗或改门；证据不足就保留 `MECHANISM_PARTIAL`。**
- **03-20B 只授权收集证据，不授权任何 TiKV/JuiceFS/Ceph 参数修改。**
