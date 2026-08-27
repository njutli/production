# 03-20A 任务书：TiKV 轮内 compaction/写路径最小归因

> 版本：v2（2026-08-23，按 03-18 实际 exposition 校正指标名）
> 执行方：GLM　｜　分析方：GPT/opencode
> 性质：只读诊断 + 1 个固定 B256 randwrite arm；**不改配置、不重启、不新增 layout**
> 前置报告：`doc/perf-report/03-19-randwrite-inode-concurrency-20260823.md` §9
> 配套脚本：`scripts/FULLBASELINE/debug/t58-tikv-inrun-compaction-attribution.sh`

```text
03-18：确认每 inode 串行队列 + 同步 TiKV 事务周期
   ↓
03-19：128→256 inode 有方向性收益，但 8/8 arm 均快→慢
   ↓
03-20A：补齐 compaction flow / L0 / stall / NVMe 区间证据  ← 你在这里
   ├─ compaction 跟不上且资源有余量 → 另立单变量 TiKV A-B-A（须授权）
   ├─ NVMe/Raft/storage 已无余量     → 输出共享写墙架构结论
   ├─ 衰减未复现                     → STOP，不选择性补跑
   └─ 证据门失败                     → STOP，修采集而非猜结论
   ↓
只有轮内稳定后，才考虑 max-uploads 或更多 inode
```

本任务只回答：03-19 中每个 arm 内的持续衰减，是否与 TiKV compaction debt、RocksDB/storage 或同步 Raft 写路径同步，以及该瓶颈是否还有安全的资源余量。

---

## 〇、背景与已知事实

03-19 按正式 `15..175s` 窗口复算后，B256 约为 2827--2898 MiB/s，只达到 6250 MiB/s 目标的约 46%。更重要的是，8 个正式 arm 的轮内 CV 为 35.5%--50.6%，四个 40 s 子窗 max/min 为 1.89--2.64，正式判定为 `STABILITY_FAIL_WITH_DIRECTIONAL_SIGNAL`。

现有时间线同时显示：

- BW 从前段约 3.3--4.2 GiB/s 降到后段约 1.5--1.8 GiB/s；
- uploader 从 150 降到个位数，buffer 从数百 MiB 排空到约 10 MiB；
- B256 的 TiKV prewrite 从约 4--5 ms 增至 18--22 ms，storage async write 和 Raft commit 同向恶化；
- 负载前 pending compaction 基本为 0，负载内单 endpoint/单 CF 上升到约 13--23 GiB；
- 03-18 原始归档也存在同类 pending/延迟增长，说明不是 03-19 单批偶发事件。

但 03-19 没有采 compaction read/write flow、L0 文件数、stall 原因和 TiKV NVMe 真区间 iostat，客户端又误从 `/metrics` 取数而丢失 `.stats` 的分 op total。因此目前只有强相关线索，还不能区分：

1. compaction 输入长期大于输出、与前台写争用 NVMe；
2. 同步 RocksDB/Raft 写本身已到共享能力墙；
3. 其他客户端、Ceph 或外部负载事件恰好同步。

---

## 一、目标与明确不做的事

### 1.1 唯一主问题

用一次固定 B256、180 s randwrite，把 fio BW、客户端 `.stats`、三 TiKV 精确指标和三节点 NVMe 区间状态对齐，判定轮内衰减首先落在哪一层，并给出“可继续调优”或“共享架构墙”的下一步分支。

### 1.2 副问题

- 负载开始前 TiKV 四个 CF 的 pending 是否全部为 0，负载后是否从 0 内生增长；
- compaction read/write 输出、L0/stall/flow 与前台 scheduler/storage/Raft 延迟是否同步；
- TiKV NVMe、CPU、网络是否仍有余量；
- Ceph、对象数、客户端 CPU/NIC、挂载身份是否出现离散事件。

### 1.3 本任务禁止

- 不改 TiKV/PD/Ceph/JuiceFS 配置，不执行动态注入；
- 不重启 TiKV、PD、OSD，不 remount 第二次；
- 不 format/destroy，不删建 pool，不改 CRUSH/PG，不创建、删除、截断或 layout 文件；
- 不跑 R128、512 inode、`max-uploads=300`、短探针或第二个性能 arm；
- 不因第一轮结果“不好看”补跑或挑窗。

---

## 二、冻结矩阵与不变量

| 项 | 冻结值 |
|---|---|
| arm | `D-B256`，仅 1 次 |
| jobfile | 由 `t56-gen-jobfiles.sh` 生成的 `B0.fio`，并经 `t56-validate-jobfiles.sh` 全通过 |
| 文件 | 现有 `storage_test.*.0` 128 个 + `rw_test.*.0` 128 个 |
| job/inode | 256 job / 256 inode / 每 inode 1 job |
| extent | P0 文件低半区 + P1 文件高半区；每 job 512 MiB，总活跃范围 128 GiB |
| fio | randwrite、256K、libaio、direct=1、iodepth=64/job、总名义 QD=16384 |
| runtime | 180 s，`time_based=1` |
| seed | slot+1，与 03-19 B0 完全相同 |
| 挂载 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| mount opts | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph client | 进程私有 conf，`ms_async_op_threads = 8` |
| system ceph.conf | md5 `5b6be34179a64e0a5f9c6d3a9690041f` |
| 对象软/硬门 | reset 后 ≤2,500,000；负载期硬上限 8,000,000 |
| 验收目标 | 6250 MiB/s 只作差距记录，不作执行期 STOP 条件 |

采用 B0 而不是新建 jobfile，是为了复用 03-19 已验证的映射和 seed。只跑 B256，是因为该 arm 对共享 TiKV 路径施压最强且已 4/4 复现衰减；本任务缺的是机制指标，不缺 R/B 方向的第五次重复。

---

## 三、执行前必须通读与确认

### 步骤 0：skill 合规确认

执行前通读并把确认写入 `skill-check-pre.txt`：

- `skills/baseline-reproduction-skill.md` §2.2/§2.4/§3.3/§3.4/§3.6；
- `skills/TESTING-GUIDE.md` §1.1/§1.3/§2.2/§3.2/§5.6；
- `skills/test-commands-reference.md` §8.2--§8.4、§9、§11；
- `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.1--§二.12。

本任务对通用指引作两项有意收窄：

1. 通用写类“60 s meta 探针”在本任务禁止，因为它本身会制造待归因的 TiKV 写状态；以正式 `D-B256` 作为唯一写负载。
2. 通用清卷流程在本任务禁止；复用既有 384 文件，只允许 `juicefs gc --compact`、OSD compact 和四节点 drop_caches。

### 步骤 0.1：部署、静态复审与唯一启动命令

在 157 上把下列文件按**固定 basename**放入 `/tmp`（脚本也可与两个 t56 helper 放在同一目录）：

```text
/tmp/03-20A-tikv-inrun-compaction-attribution.md
/tmp/t58-tikv-inrun-compaction-attribution.sh
/tmp/t56-gen-jobfiles.sh
/tmp/t56-validate-jobfiles.sh
/tmp/env-snapshot.sh
/tmp/ceph-health-check.sh
/tmp/juicefs-03-8
```

先只执行 `bash -n` 和 `md5sum`，把六个脚本/文档的 md5 与静态 diff 回传分析方；**收到静态复审通过前不得进入环境执行**。复审通过后只允许下面一个入口，不得拆开复制命令逐段手跑：

```bash
RUN_ID=$(date +%Y%m%d-%H%M%S)
bash /tmp/t58-tikv-inrun-compaction-attribution.sh "$RUN_ID"
```

脚本要求 `RUN_ID` 精确匹配 `YYYYMMDD-HHMMSS`；同名结果目录、同名归档或锁冲突都会 STOP，禁止改名覆盖或删除旧结果后重跑。

---

## 四、批首与环境前置门

配套脚本必须机械执行，任何一项失败立即 STOP：

1. 唯一 RUN_ID/结果目录和 `/tmp/t58-stage03.lock`；目录存在或锁冲突不得覆盖。
2. `/tmp` 可用 ≥5 GiB、客户端 `MemAvailable≥32 GiB`。
3. 任务书、脚本、t56 生成器/校验器、env-snapshot、health 库、binary、system conf 全部存在；保存 md5 和 `commands.sh`。
4. 不得存在 fio、本任务、GC/compact 或其他压测进程；若 `/mnt/juicefs` 已挂载或存在未知 JuiceFS mount 进程，STOP。禁止脚本替用户杀进程或 lazy unmount。
5. `ceph health=HEALTH_OK`，6 OSD 全部 up/in，PG 全 active+clean，无 scrub/deep-scrub/recovery/backfill；冻结全部 OSD `up_from`。
6. 只挂载一次，验证 PID/starttime、实跑 exe md5、`max_read=262144`、进程私有 `CEPH_CONF` 含 msgr=8。
7. 三组文件各恰有 128 个、每个恰为 1 GiB；保存全部 384 文件 `path/inode/size/mtime_ns`。禁止 spot check 代替全量检查。
8. 生成并校验 B0 jobfile；保存 jobfile、映射 TSV 和 md5。
9. 三 TiKV 服务 active、PID/starttime/config md5 固定；发现 `/mnt/jfs-tikv` 的真实块设备，并验证 `iostat -y -x -d 1 1 <dev>` 有区间输出。
10. 从真实 `.stats` 和三 TiKV `/metrics` 验证核心 family 存在。禁止现场凭印象改名；确有版本差异则 STOP 并回传 exposition/差异。
11. 执行 `env-snapshot.sh ... pre`，保存 TiKV `/config`、完整 metrics gzip 和 metric 名清单。全量 metrics 完成后必须再走完整 reset；禁止在最终 quiet/idle gate 与 fio 之间抓全量 metrics。

---

## 五、统一 pre-load reset 与空闲门

### 5.1 reset 顺序

1. `sync -f /mnt/juicefs`。
2. 全 OSD 发 `compact`，每 5 s 保存每个 OSD `perf dump` 原文，连续 3 个样本同时满足：
   - `compact_running=0`；
   - `compact_queue_len=0`；
   - `bluestore.kv_sync_lat.avgtime<0.002s`。
   任一 tell/parse 失败按未通过，最多 10 min。
3. 固定等待 30 s，再重复一次步骤 2。
4. 只执行一次 `juicefs gc --compact "$META"`，保存完整 stdout/stderr、rc、起止 epoch；rc 非 0 STOP。
5. 只读取常驻对象 sampler，等待连续 3 个 15 s 样本：全部 `objects≤2,500,000`、不递增、极差≤128，stored/max_avail 极差各≤64 MiB。取三样本中位数冻结为正式基点。
6. GC 后再次执行步骤 2，不能沿用 GC 前结果。
7. 三 TiKV endpoint 的 default/write/lock/raft CF 连续 3 个 5 s 样本全部 pending=0；缺 endpoint/CF 或解析失败均不通过，最多 10 min。
8. 全量 stat 384 文件，随后客户端与 150--152 各 `sync + drop_caches`，必须 4/4 成功。
9. 固定 quiet 60 s；期间只保留已启动的低频常驻 sampler，禁止 full metrics、文件遍历、GC、compact 或性能探针。
10. quiet 最后 30 s 通过空闲门，门通过至 fio start ≤10 s。

### 5.2 空闲门

- 无外部 fio/layout/GC/compact/其他 JuiceFS 压测进程；
- HEALTH_OK、6 OSD、PG clean、无 scrub/recovery、up_from 不变；
- 客户端 30 s CPU idle≥70%、iowait≤5%、steal≤1%；
- 客户端数据网和 TiKV 管理网的背景流量每方向均 <100 MiB/s；接口从 `ip route get` 实查并冻结；
- 三 TiKV `process_cpu_seconds_total` 30 s 差分均 <1 core；四 CF pending 全为 0；
- 核心 sampler 全部存活且 PID/starttime 未变。

最多等待 10 min，不得选择某个瞬间样本放行。

---

## 六、批次常驻采集

sampler 在 reset 前只启动一次，final reset 后统一停止并 `wait`。同一指标不得重复启动。

| 文件 | 周期 | 内容 |
|---|---:|---|
| `samplers/jfs-stats.tsv` | 1 s | 挂载点 `.stats` 的 meta Write、transaction、PUT、fuse write sum/total |
| `samplers/jfs-runtime.tsv` | 1 s | uploader、buffer、staging、JuiceFS process CPU |
| `samplers/client-host.tsv` | 1 s | `/proc/stat`、MemAvailable、数据网/TiKV 网 RX/TX |
| `samplers/tikv.tsv` | 5 s | 三 endpoint 顺序抓取，完整 labels + local start/end epoch |
| `samplers/tikv-host-<ip>.tsv` | 约 5--8 s | remote epoch、TiKV proc stat/io、`iostat -y` 真 1 s 区间报告 |
| `samplers/ceph.tsv` | 30 s | health、PG、scrub/recovery、up_from |
| `samplers/pool.tsv` | 15 s | active phase、objects/stored/max_avail、parse 状态 + 硬看门 |

TiKV 精确子集至少包含：

```text
process_cpu_seconds_total
tikv_storage_engine_async_request_duration_seconds_{sum,count}
tikv_scheduler_{command,latch_wait,processing_read}_duration_seconds_{sum,count}
tikv_raftstore_{append,commit,apply}_log_duration_seconds_{sum,count}
tikv_raftstore_apply_wait_time_duration_secs_{sum,count}
tikv_engine_pending_compaction_bytes
tikv_engine_compaction_duration_seconds_{sum,count}
tikv_engine_compaction_flow_bytes
tikv_engine_num_files_at_level
tikv_engine_stall_micro_seconds
tikv_engine_write_stall
tikv_engine_write_stall_reason
tikv_scheduler_{flush,l0,throttle,write}_flow
tikv_scheduler_pending_compaction_bytes
tikv_rate_limiter_max_bytes_per_sec
```

上面两个易混淆名称已用 03-18 留存的三节点完整 exposition 离线核对：当前版本实际导出的是 `apply_wait_time_duration_secs_*` 和 `scheduler_pending_compaction_bytes`，禁止执行时改回相似但不存在的 `...seconds_*` / `...pending_compaction_flow`。

### 对象硬看门

- sampler 必须用一次 JSON 请求取得同一时点的纯数值 objects/stored/max_avail；禁止解析人类可读列。
- `objects>8,000,000`、连续 3 次解析失败或相邻样本间隔>20 s：写 `STOP.txt`，只向当前登记的 fio PGID 发 SIGINT；60 s 后仍存在才对同一 PGID 发 SIGTERM。
- 禁止 `pkill -f`、`killall`、`fuser -k` 或任何 broad kill。
- 无论 fio 是否正常退出，一旦看门触发，禁止继续或补跑。

---

## 七、唯一诊断 arm：D-B256

1. reset/idle gate 通过后，保存 PRE `.stats`、TiKV 精确快照、pool/health、384 文件 stat、挂载和三 TiKV 身份。
2. 写 phase marker，以 `setsid` 启动 fio，保存精确 PID/PGID；对象看门只能引用该 PGID。
3. fio 跑满 180 s，保存 stdout/stderr/rc 和恰好 256 份 per-job bw log。
4. 主进程每 5 s 检查：对象 STOP、sampler 存活、挂载 PID/starttime；发现异常终止精确 fio PGID 并 STOP。
5. fio 完成后 `wait`，保存 POST 边界快照和完整 metrics；不得根据 BW 决定是否补跑。
6. 机械校验：
   - rc=0，summary 存在；
   - 恰好 256 份非空日志，首样本启动偏差≤2 s，覆盖统一 `15..175s`；
   - 256 个目标文件 mtime_ns 前进，128 个 read_test 不变；384 文件数量/inode/size 不变；
   - `.stats` 的 fuse write、meta Write、transaction、PUT total 和字节增量均>0；
   - sampler 无重启/重复，核心序列覆盖 pre-load 至 post-load。
7. 执行 final reset，使 objects/stored/max_avail 回正式基点带，OSD 三指标及 TiKV 四 CF pending 重新归零。
8. 停止并 wait sampler，采 post 环境/身份/配置指纹，优雅卸载本脚本创建的挂载；优雅卸载失败只记录并 STOP，不得强杀或 lazy unmount。

---

## 八、分析口径与决策树（GLM 不计算结论）

### 8.1 带宽与衰减

- 全部 256 job 以最早有效样本为全局 `t0`，按整秒对齐后求和；缺任一 job 的秒不得作为完整秒。
- 主窗口：`15≤sec-t0≤175` 的逐秒均值；同时报告 `30..165s` 均值和 `45..175s` 中位数/p10/p90/CV。
- 固定四子窗 `[15,55)`、`[55,95)`、`[95,135)`、`[135,175]`；报告均值和 max/min。
- “衰减复现”预登记为：末窗/首窗≤0.70，且 BW 与 prewrite 或 storage async write 延迟的轮内相关≤-0.60。只报是否满足，不据此选择补跑。

### 8.2 机制判定

| 观测 | 归属 | 后续 |
|---|---|---|
| pending/L0 上升，compaction 输入>输出，NVMe/CPU 有余量，无前台硬墙 | compaction 资源配置可能可解 | 只提出一个单变量候选，另立 A-B-A；变更/重启须授权 |
| pending/compaction flow 与 NVMe await/util 同升，盘已持续饱和 | TiKV RocksDB 物理写/放大墙 | 输出存储架构/设备能力结论，不扫 uploader/inode |
| pending 不显著但 storage/Raft 延迟、队列和 NVMe fsync 同升 | 同步 RocksDB/Raft 写墙 | 输出三副本同步元数据路径容量结论 |
| TiKV 路径稳定，uploader 前后都持续=150，其他层有余量 | 数据上传并发候选 | 才允许另立 `max-uploads 150→300` 单变量交错测试 |
| TiKV 与数据面都稳定但 BW 仍衰减 | 现有假设未闭合 | 转客户端队列/锁/重试插桩，不猜配置 |
| 衰减未复现 | 本批不回答 | STOP；保留为跨状态证据，不补跑 |

相关性只用于时间线归属，不单独宣称因果。任何“可解”结论必须同时有资源余量和输入/输出失衡证据。

---

## 九、有效性门与 STOP 条件

| # | 条件 | 处置 |
|---|---|---|
| V1 | 全程单挂载 PID/starttime/exe/conf/max_read 不变 | 否则全批无效 |
| V2 | jobfile/mapping/seed/QD/runtime 与冻结值一致 | 否则 STOP |
| V3 | pre-load reset、四 CF pending、idle gate 原始证据完整 | 否则 STOP |
| V4 | fio rc/runtime/256 logs/启动偏差/mtime/文件不变量全过 | 否则 STOP |
| V5 | sampler PID/starttime唯一且覆盖完整，无核心时间洞 | 否则主归因无效 |
| V6 | health/OSD/PG/up_from/scrub/recovery 全程无离散事件 | 否则 STOP |
| V7 | 对象硬看门有效且未越 8M；final 回正式基点 | 否则 STOP |
| V8 | 三 TiKV PID/starttime/config md5 和服务状态不变 | 否则 STOP |
| V9 | TiKV host 的 iostat 为 `-y` 真区间值，三主机分文件 | 否则资源余量不可判 |
| V10 | pre/post env、完整 metrics、commands、manifest/archive md5 齐全 | 否则降级并声明 |

性能高低不是执行期 STOP 条件。任何 STOP 都停止精确子进程、保留现场、禁止改变量绕过或选择性重跑。

---

## 十、交付物与回传格式

结果目录固定：`/tmp/opencode-t3.20a-<RUN_ID>`；归档：`/tmp/production/opencode-t3.20a-<RUN_ID>.tar.gz`。

至少包含：

```text
commands.sh
skill-check-{pre,post}.txt
taskbook.md / t58-script.sh / t56-*.sh / *.md5
env-snapshot-{pre,post}.txt
fingerprint/{mount,tikv,ceph,files}-{pre,post}.*
jobfiles/B0.fio{,.tsv}
reset/{preload,final}/...
arm/D-B256/{fio.stdout,fio.stderr,fio.rc,pre.stats,post.stats,bw/*.log}
samplers/{pids.tsv,errors.tsv,jfs-stats.tsv,jfs-runtime.tsv,client-host.tsv,tikv.tsv,tikv-host-*.tsv,ceph.tsv,pool.tsv}
metrics-full/*.{prom.gz,names.txt}
phase.tsv / STOP.txt（如触发）
MANIFEST.md5
```

GLM 回传只需：RUN_ID、起止时间、最终 rc/STOP 编号；fio `WRITE: bw=` 原文、日志数；挂载和三 TiKV 身份；pre-load/final 对象基点与 arm 峰值；归档路径/大小/md5；所有偏离原文。不要现场写机制结论。

末步必须对照 skill 做合规复查并写 `skill-check-post.txt`：确认无 format/destroy/pool delete/restart/配置变更/第二次挂载/额外 arm；OSD 三指标、四节点 drop_caches、对象硬看门、全局 t0 多 job 求和和所有采集路径均符合任务书。任一偏离必须显式写影响。

---

## 十一、授权边界与红线汇总

- 可自主修复：不改变矩阵、门限、清理链、指标语义的脚本语法、路径和采集实现错误；修复后必须先回传 diff/md5，等待静态复审再执行。
- 禁止自主改变：arm 数、jobfile、runtime/QD/seed、挂载参数、reset、对象/空闲/证据门和任何集群配置。
- 只允许本任务创建的结果目录和归档；不得删除、覆盖或移动未知历史产物。
- 清理白名单仅为 OSD compact、一次 `juicefs gc --compact`/reset、四节点 drop_caches；禁止 format/destroy/pool 操作和服务重启。
- 157 上禁动 WekaIO、内核、网卡、MTU、RoCE、IRQ 和业务进程。
- 禁止 broad kill、lazy unmount、自动重跑、按 BW 挑窗或用 fio summary 替代逐秒主口径。
