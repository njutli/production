# 03-16 GLM：N1/N2 单/双挂载读边界取证（Phase R，只读）

> 任务书类型：**P0 边界实验；GLM 只执行和交付原始证据，不做统计、不选下一分支**  
> 日期：2026-08-17（脚本与纪律于 2026-08-19 复核订正）　｜　执行方：GLM　｜　分析方：GPT  
> 母文档：`doc/perf-analysis/03-juicefs-parameter-tuning-execution-plan.md` §11.3  
> 唯一执行脚本：`scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh`  
> 本轮**单轨执行**：夜间编排总任务书 `03-16N` 已作废，无人值守纪律见本文 §八；同一窗口不得叠加 V02 或任何写测试

---

## 计划线

```text
03-14：同一挂载内 R/W 分项强反相关、合计较稳
03-15 Gate 0：只能确认“单挂载存在读写共享约束”，尚不能把约束层级写死为 librados/整机
★ 03-16（本任务）：用两个独立、同为好档的只读挂载，测单挂载与双挂载扩展边界
  ├─ 双挂载显著扩展：约束偏单 mount/单进程；多挂载仅作为架构诊断，不等于业务验收
  └─ 双挂载不扩展：约束偏整机共享 JuiceFS/librados/host 路径；再由分析方签发 direct-rados 对照
拿到原始包后立即停；写路径、TiKV、librados T2、max-downloads 均不得顺手补跑。
```

## 〇、为什么现在只跑 Phase R

1. 当前最有价值的未知量不是另一个参数点，而是约束作用域：**单挂载**还是**整机共享**。
2. 03-14 已发生写窗口延长、对象数增长和缓存异步排空，不能把写侧绝对值混进本轮读边界。
3. 读实验必须位于所有新写实验之前。本任务完全只读；分析方收到 Phase R 后，才决定是否另发 Phase X。
4. 目标仍是每个测试方向有效带宽 `>=6250 MiB/s`。双挂载合计只是架构诊断量，**永远不能代替单业务挂载/单方向验收**。
5. 对象池当前处于低位且已被验证可维持：2026-08-20 08:41 实测 `juicefs-data` objects = **2,434,630**（stored 595.2 GiB、`HEALTH_OK`、33 pgs active+clean、无任何 JuiceFS 挂载与 session），低于 3.11M 闸门。
   ⚑ 订正（2026-08-20）：初版本节曾写"任何写 block 会毁掉这个窗口并推后数天"，该说法据 V02 证据只在**不做每轮回收**时成立，须收窄。实际情况是：V01 未按轮回收，把池顶到 18,337,356，靠自然回收花了 08-17→08-19；而 V02（08-19 11:01~23:35，54+27 轮 fio 写）每轮 fio 峰值 ~3.3–3.6M，**每轮 cleanup 后都回到 2,434,623，终值 2,434,630**。因此窗口是可再生的，但再生依赖对方严格执行每轮回收。本窗口仍然只跑 03-16，理由改为：① 读实验必须在新写实验之前；② 同窗口叠加写负载会让读边界的背景不干净（对象数在 2.4M↔3.6M 之间摆动，正好跨过 3.11M 闸门）；③ 一旦对方漏做回收，代价是数天。


## 一、目标

- 在两个独立 pair 上复现 P、Q 两个好档 mount，并冻结各自 `PID + starttime_ticks`。
- 同一 pair 内交错采集：P 单跑、Q 单跑、P+Q 并发，分别测 64/128 jobs，共 3 轮。
- 交付足够的原始证据，使分析方能回答：
  - 单挂载平台是否仍在约 4.1 GiB/s；
  - 双挂载是否增加整机总吞吐；
  - 扩展发生在 64 还是 128 jobs；
  - 并发时是否出现 CPU、NIC、OSD 延迟或同一类 goroutine 排队。

GLM 不回答以上问题，只报告“脚本是否完成、是否命中 STOP、结果路径与校验和”。

## 二、固定环境与矩阵

### 2.1 固定环境

- 客户端：157；元数据/OSD 节点：`10.20.1.150-152`。
- 二进制：`/tmp/juicefs-03-8`。
- 参数：`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`。
- 业务挂载 `/mnt/juicefs`：**只读身份核对，禁止卸载、重挂、改参数或在其中起 fio**。若本轮开始时它本来就没有挂载（近期 V01/V02 系列任务后可能如此），脚本会把身份记为 `NA` 并在全程比对"仍为 NA"；这不是 STOP，但必须在报告中写明"起始无业务挂载"。
- 专用挂载：`/mnt/juicefs-p`、`/mnt/juicefs-q`。
- P 数据集：`read_test.*.0` 128 文件；Q 数据集：`rw_test.*.0` 128 文件。两组互斥，均以 `randread --readonly` 访问。
- 判档数据集：`test_dir/mseqread/mseqread.*.0` **精确 16 个**（V4 布局 16×4G）。判档 fio 同样带 `--readonly`，缺文件时脚本先 STOP、fio 也不会补写。
- fio 版本必须是 **3.28**（157 现装版本；脚本已加硬校验，非 3.28 直接 `exit 3`）。03-13/03-14 全部判档轮的归档输出均为 fio-3.28 且无 `Laying out IO file` 行，即确实读的是既有 16 个文件；2026-08-20 在 157 本地 ext4 用两个 8 MiB 既有文件实测：`--readonly` 下 rc=0、READ 汇总行正常、bw log 计数正确、目录无新文件。⚠ 更高版本（已在 3.41 上复现）对"`--name` + `--directory` + `numjobs>1` 且未给 `--filename`"的默认文件名解析不同，会指向不带后缀的 `mseqread`，无 `--readonly` 时静默补写、有 `--readonly` 时判档直接失败。
- 集群：Ceph **17.2.8 quincy**，EC pool（`size=6`，`ec-prod`），33 pgs，`max_avail` 26.0 TiB。
- 157 落盘：根分区长期 **98% 占用、约 20 GiB 可用**。本任务预计产出 ≈200 MiB（OSD perf dump 单个 34 KB × 6 × 2 × 36 ≈ 15 MiB，其余为 pprof/i1/bwlog）。脚本要求可用空间 ≥5 GiB，否则 `exit 3`。

- 起点对象数：**Ceph pool `juicefs-data` 的 objects** `<= 3,110,000`。超过即 STOP；本脚本不会自动 gc。
  ⛔ 该闸门口径不得用 `UsedSpace`、`UsedInodes`、TiKV disk size 或任何其他量替代（与 `V02-PRE` §十一、`V02` §5 同一条规矩）。`UsedInodes` 实测量级为 10²，与 3.11M 阈值差 4 个数量级，一旦替换闸门将永远通过。每次取值的 `ceph df` 原文追加落盘到 `objects-raw.jsonl`。

### 2.1b 背景噪音：历史遗留监控已清理（基线应为空）

2026-08-20 09:01 已在用户明确授权下清理完毕：**11 个历史实验遗留的监控循环**（最久已跑 23 天）全部按显式 PID `TERM`（未使用 pkill 模式匹配），核对后全部退出；`pool-tracer` 的包装 `bash`（PID 3280649）随子进程自然退出；两个孤儿 `sleep` 在 35 s 内自行结束。取证：157 `/tmp/opencode-orphan-cleanup-20260820/{before,kill,after}.txt`。被清理的清单（留档）：

| PID | 进程 | 起始 | 行为 |
|---|---|---|---|
| 270098 / 3377130 / 3425561 / 3473041 / 3513634 | `load-monitor.sh …opencode-lcnvme…/opencode-lc-verify…` | 07-27 起 | 每 5 s 采 NIC 计数 |
| 3377132 / 3425562 | `osd-monitor.sh …opencode-lcnvme/B/B-{3,1}/osd` | 07-29 12:10 | **每 5 s 对 6 个 OSD 跑 `ceph tell osd.N perf dump` + `dump_mempools`**（与本脚本 OSD 快照抢 admin socket） |
| 3280651 | `pool-tracer.sh` | 08-07 20:23 | 每 15 s `ceph df`，每次都因目标目录不存在而报错 |
| 2956829/30/32/33 | `instrument.sh start …opencode-t3.7l randrw-T37L-K7-A1` | 08-12 16:12 | 03-7L 探针残留 |

日志文件按授权范围**未删除**（`/tmp/lc-nvme-attribution-B.log` 107.9 MB、`/tmp/pool-tracer.log` 1.09 MB），现已停止增长。

现在的规则：

1. `background-monitors-initial.txt` **应为空**。若非空，说明又有人起了新的监控循环或有任务未清场，**必须在报告中列出并回报**，不得自行 kill。
2. 出现任何**非本任务 fio** 一律 STOP。
3. 脚本仍保留开跑前的 6 个 OSD `perf dump` 可用性预探（15 s 内需返回 ≥1000 字节，失败 `exit 3`）——清理后本应稳定通过，若仍失败说明另有 admin socket 竞争源。
4. 主机常态 `load average ≈ 24`（96 核、127 个登录用户），主要来自本机其他业务（Weka/K8s/用户会话），这是背景值，不是本任务造成的。


### 2.1c 时钟漂移：唯一被放宽的门（须知悉）

**现状（2026-08-20 实测）**：`mon.ceph-node2` 已越线且在持续增大 —— 08:41 测 0.0478 s、09:01 测 0.0637 s、09:10 测 0.0673 s，而 `mon_clock_drift_allowed` 默认 **0.05 s**。集群日志显示 `Health check failed: … (MON_CLOCK_SKEW)` 发生于 01:46:31 UTC 且**至今未 cleared**，即当前是持续偏离而非瞬时抖动。V02 于 08-19 夜间也因此失败过一轮（其报告偏差第 3 条）。

**根因（只读诊断，已量化）**：三节点均用 `systemd-timesyncd`（`chronyd` inactive），node2 的时间源是公网 `ntp.ubuntu.com`（185.125.190.56）：

```text
Poll interval: 34min 8s    Delay: 319.408ms    Offset: +27.782ms
Jitter: 12.872ms           Frequency: -11.157ppm
```

`11.157 ppm = 0.669 ms/min = 40.2 ms/h`，而校准周期 34.1 min ⇒ 两次校准间累积 **≈22.8 ms**，叠在 +27.8 ms 基础偏移上，**峰值必然顶到 50 ms 阈值**。也就是说跨线是该 NTP 拓扑的**固有周期现象（约 34 min 一次）**，不是集群健康信号。一次 4 小时的跑会经历约 7 个周期。

**因此本任务的判据（选项 A）**：`health_gate` 在"`[WRN]/[ERR]` 只有一条且内容匹配 `clock skew`"时，**记录后立即继续，不重试、不等待**；其余任何告警（含"时钟漂移 + 另一条告警"同时出现）一律立即 STOP。护栏：从告警原文解析漂移值（`mon.X clock skew <N>s > max 0.05s`），**> 0.5 s（10× 阈值）即 STOP**，解析不出也 STOP。每次事件把漂移值、累计次数、告警原文写入 `skew-events.tsv`，并存一份 `ceph time-sync-status` 到 `time-sync-<tag>.json`。

判据已双向验证：4 组合成样本（OK / 仅漂移 / 漂移+`OSD_DOWN` / `PG_DEGRADED`）分别得到 PASS / 继续 / STOP / STOP；并用**集群实况原文**（skew=0.0672819 s）跑通"记录后继续"。

为什么这样做是安全的：

1. 对本任务的测量数学**零影响** —— P/Q 对齐用 157 本机 `date +%s%N`（`fio-*-start-ns.txt`），OSD 指标取 pre/post 计数器差值，带宽取 fio per-job 逐秒日志，均不依赖 mon 之间的时间一致性。
2. 比"重试 3×60s"更好 —— 重试会往某些配置的时间轴里插进最多 3 分钟空档，破坏交错设计的均匀间隔；直接继续没有这个副作用。
3. 唯一被放弃的是"漂移作为主机过载代理指标"这点旁证，已由每配置的 `host-state-{pre,post}.txt`（load/内存/进程）替代。

> 治本方案（**本任务不做**，需另行授权）：把 node2 的 `PollIntervalMaxSec` 从 2048 s 降到 128 s，锯齿幅度将从 22.8 ms 降到 ~1.4 ms；或改用内网 NTP 源。禁止用 `ceph config set mon mon_clock_drift_allowed` 遮盖。

### 2.2 每个 pair 的固定矩阵

| 配置 | P | Q | 性质 |
|---|---:|---:|---|
| P64 | randread, 64 jobs | idle | N1 单挂载 |
| Q64 | idle | randread, 64 jobs | N1 独立实例复核 |
| C64 | randread, 64 jobs | randread, 64 jobs | N2-control |
| P128 | randread, 128 jobs | idle | N1 单挂载饱和点 |
| Q128 | idle | randread, 128 jobs | N1 独立实例复核 |
| C128 | randread, 128 jobs | randread, 128 jobs | N2-scale |

每个 pair 跑 3 个交错轮，脚本顺序固定为：

```text
r1: P64 Q64 C64 P128 Q128 C128
r2: Q128 C128 P128 Q64 C64 P64
r3: C64 P64 Q64 C128 P128 Q128
```

随后整对 P/Q 卸载，重新抽取第二个 pair；禁止只换一侧。每个 mount 在效应轮前连续跑 2 次 mseqread，按两次 ns/B 中位数与 `3.287 +/-10%` 判档。每个 pair 最多 3 次尝试，label 必须唯一。

## 三、分析判据（GLM 只采证，不计算）

| 编号 | 分析方将使用的判据 | 原始来源 |
|---|---|---|
| R0 | 每个 fio `rc=0`，完整输出和全部 per-job bw log 齐全 | `run-*/fio-*.txt`、`bwlog/*_bw.*.log`、`progress.tsv` |
| R1 | 有效带宽统一用 per-job 逐秒日志；按各进程 start-ns 对齐，窗口 `15 <= sec-t0 <= 175` 取均值 | `bwlog/`、`run-*/fio-*-start-ns.txt` |
| R2 | 单 mount：P/Q solo 的 64->128 曲线和跨 pair 稳定性 | P64/Q64/P128/Q128，3 轮 x2 pair |
| R3 | 双 mount：C64/C128 的 P、Q 分向值及整机合计；分向必须单列 | C64/C128 的 P/Q bw logs |
| R4 | 约束层级 | R2/R3 + P/Q I1、进程 CPU、NIC、OSD pre/post、round-2 goroutine |
| R5 | 可比性 | gate、PID/starttime、HEALTH_OK、对象数、主挂载身份、主机负载/内存 |

禁止用 fio 汇总值签收，禁止用并发 P+Q 合计冒充测试项达标，禁止让 GLM 按 `>6250` 自行选择后续分支。

## 四、执行步骤

### 步骤 0：必须先读和预扫描

在仓库中完整阅读：

```text
skills/TESTING-GUIDE.md
skills/test-commands-reference.md
skills/FULLBASELINE-SKILL.md
skills/SYSTEM-SAFETY-SKILL.md
skills/interleaved-ab-tuning-skill.md
doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md
本任务书
```

然后在本地仓库执行并保存输出：

```bash
bash -n scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh
grep -nE 'sudo|reboot|shutdown|halt|poweroff|systemctl|rm -rf|pkill|killall|juicefs (destroy|format)|ceph osd pool (delete|rm)' \
  scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh
```

本脚本允许的状态写入只有下列精确范围，**运行前必须把扫描结果和这份清单交给用户，取得明确确认**：

1. 157：创建/chown `/mnt/juicefs-p`、`/mnt/juicefs-q`；对这两个专用挂载执行 JuiceFS umount，失败时才 `sudo umount`。
2. 157、150、151、152：每个 fio 前 `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches`。
3. 两个专用 JuiceFS mount/umount（不使用 sudo mount；绝不触碰 `/mnt/juicefs`）。

脚本还会使用下列**只读** sudo，请一并列入确认清单：`sudo ceph health detail`、`sudo ceph pg stat`、`sudo ceph df --format=json`、`sudo ceph osd dump`、`sudo ceph tell osd.N perf dump`、`sudo ss -tlnp`（仅用于取 pprof 端口）。

脚本无 reboot、restart、gc、compact、pool、layout、网络或内核调参。未取得确认不得设置 `ACK_SUDO_WRITES=YES`。

### 步骤 1：确认机器、文件与红线

登录 157 后确认主机名，选择 WekaIO/BeeGFS 业务相对空闲窗口。不得改 NIC/RoCE/MTU/RPS/IRQ/md0/WekaIO/K8s。记录：

```bash
hostname -f
date '+%F %T %z'
uptime
free -m
df -h /tmp
fio --version
mount | grep juicefs
pgrep -af juicefs
pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh'   # §2.1b 遗留监控清点，只看不动
sudo ceph health detail
sudo ceph pg stat
sudo ceph time-sync-status                                        # 对照 §2.1c；node2 越线属已知，不是 STOP
sudo ceph df --format=json | python3 -c \
  "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data'][0]; print(p['stats']['objects'])"
```

对象数若已大于 `3,110,000`，到此 STOP，把数字和上述原文回传；不要启动 wrapper，也不要自行 gc。
`fio --version` 不是 3.28、`/tmp` 可用空间不足 5 GiB，同样到此 STOP。

把下列文件复制到 157 `/tmp/`，并保存源端/目标端 md5：

```text
t46-n1n2-read-boundary.sh
t39-nsbgate.sh
env-snapshot.sh
```

⚠ 157 上现存的 `/tmp/env-snapshot.sh` 是 08-15 旧版（md5 `e20c46f9…`），必须用仓库版（`b6d1c556…`）覆盖；`/tmp/t39-nsbgate.sh` 尚不存在，须新拷。

必须确认 `/tmp/juicefs-03-8` 存在（`juicefs version 1.3.1+2026-08-13.e0032b2a-03-8-ceph`，md5 `1f60618c44fda1c19fecd75d52e053e9`）。不得覆盖 `/usr/local/bin/juicefs`。


### 步骤 2：先跑无状态 preflight

```bash
bash -n /tmp/t46-n1n2-read-boundary.sh
grep -nE 'sudo|reboot|shutdown|halt|poweroff|systemctl|rm -rf|pkill|killall|juicefs (destroy|format)|ceph osd pool (delete|rm)' \
  /tmp/t46-n1n2-read-boundary.sh
md5sum /tmp/t46-n1n2-read-boundary.sh /tmp/t39-nsbgate.sh /tmp/env-snapshot.sh /tmp/juicefs-03-8
```

若当前对象数大于 `3,110,000`，脚本将停止。GLM 只回传 `objects-initial.txt`、health 和日志；**不要自行 gc 或继续跑**。

### 步骤 3：得到用户对步骤 0 清单的明确确认后，一次执行

```bash
ACK_SUDO_WRITES=YES bash /tmp/t46-n1n2-read-boundary.sh
```

脚本会自动完成：

1. 前置校验：fio 版本、落盘空间、6 个 OSD 的 `perf dump` 可用性、遗留监控清点、health、起点对象数。
2. 冻结业务挂载身份；创建 P/Q 专用目录。
2. 为 pair A 同时挂 P/Q；每侧 2 次 mseqread 判档；两侧都 PASS 后冻结 PID/starttime。
3. 运行 18 个交错只读配置；每个配置前 health、对象数、四节点 drop_caches 和实例核对。
4. pair A 卸载后，以新实例重复 pair B。
5. 每轮采 P/Q 的统一 I1、P/Q 进程 CPU/RSS、双 NIC、6 OSD perf pre/post、主机 load/memory；r2 对活跃实例抓 goroutine。
6. 校验主挂载未变，生成 `MANIFEST.md5`、tar.gz 和 tar.gz.md5。

正常耗时约 3.5–4.5 小时（时钟漂移按 §2.1c 记录后继续、不增加耗时；两个 pair 若都需要判档重试，最坏约 5–5.5 小时）。不要同时跑其他 fio、V4、rados bench、写测试或参数扫描。


### 步骤 4：命中 STOP 时

立即停止，不做“修好后接着跑”的临场处理。只执行以下只读核对并回传：

```bash
tail -100 /tmp/opencode-t3.16/wrapper.log
mount | grep juicefs
pgrep -af juicefs
sudo ceph health detail
sudo ceph pg stat
```

不得手工杀 JuiceFS/fio，不得 `pkill -f`、`killall`，不得重启节点/服务。专用挂载由 trap 清理；若残留，先回报，不自行扩大处理范围。

## 五、STOP 条件

- 不是在 157 执行，或脚本/md5/二进制缺失，或 `fio --version` 不是 3.28。
- 落盘可用空间 < 5 GiB，或 6 个 OSD 的 `perf dump` 预探有任一失败。
- Ceph 不是 `HEALTH_OK`，或 PG 非预期稳定状态。**唯一例外**见 §2.1c：只有一条告警且是时钟漂移（且 ≤0.5 s、可解析）时记录后继续；漂移 >0.5 s、解析失败、或同时存在其他告警，一律 STOP。

- 起点或任一轮对象数不可解析/超过 `3,110,000`（口径必须是 Ceph pool `juicefs-data` objects）。
- P/Q 数据集不是各 128 文件，或 `mseqread` 不是精确 16 文件。
- 任一 pair 三次仍不能让 P/Q 都通过 ns/B 门。
- gate 后 P/Q 任一 PID/starttime 变化，或 `/mnt/juicefs` 身份变化。
- 任一 fio rc 非 0、输出缺 READ 行、采集器关键文件为空。
- 主机内存逼近风险线、WekaIO/K8s/BeeGFS 业务异常、出现 `background-monitors-initial.txt` 基线之外的新负载（尤其任何非本任务 fio），或任何无法解释的共享机负载突变。

## 六、必须回传的原始证据

优先传文件，不要在聊天中只贴人工摘要：

1. `/tmp/opencode-t3.16.tar.gz` 和 `/tmp/opencode-t3.16.tar.gz.md5`。
2. 若中途 STOP 无 tar：完整 `/tmp/opencode-t3.16/`，至少包括 `wrapper.log`、`health-*`、`skew-events.tsv`、`time-sync-*.json`、`objects-*`、`objects-raw.jsonl`、`dataset-check.tsv`、`instances.tsv`、`gate-summary.tsv`、`instance-checks.tsv`、`main-mount-*`、`fio-version.txt`、`disk-preflight.txt`、`osd-probe.txt`、`background-monitors-initial.txt`。

3. 每个 `run-*`：fio 全文、command、start-ns、P/Q I1、P/Q proc、net、host-state、objects。
4. `bwlog/` 下**全部** `_bw.*.log`；不得只挑一个 job。
5. `osd/` 全部 pre/post JSON；所有 pprof；所有 active/complete env snapshot。
6. 步骤 0/2 的安全扫描与 md5 原文、任何偏差或人工操作的逐字记录。

GLM 最终回复模板：

```text
03-16 执行状态：DONE / STOP（原因原文）
结果目录：
压缩包及 md5：
主挂载 before/after 是否逐字一致（起始无挂载则写 NA→NA）：
数据集核对（read_test / rw_test / mseqread）：
对象数起点/峰值/终点（Ceph pool juicefs-data objects）：
时钟漂移事件数与峰值（`skew-events.tsv` 行数、最大漂移值）：
遗留监控进程清点（数量，是否与基线一致）：
pair A/B 最终 label：
fio 非零 rc 或缺文件：只列文件名，不计算带宽
脚本改动及旧/新 md5：无 / 逐条列出
任何偏差/人工操作：
```

## 七、合规自查（最后一步）

- [ ] 全程只读数据负载；无 randwrite/randrw/gc/compact/restart/config set。
- [ ] 判档 fio 与效应轮 fio 均带 `--readonly`；`dataset-check.tsv` 显示 read_test/rw_test 各 128、mseqread 16。
- [ ] 对象闸门全程用 Ceph pool `juicefs-data` objects，`objects-raw.jsonl` 每次取值都有 `ceph df` 原文；未使用任何替代量。
- [ ] 主挂载 `/mnt/juicefs` 未改变；仅 P/Q 专用挂载被创建/卸载（起始即无挂载时，全程仍为 NA 并已写明）。
- [ ] 两个 pair 均为 P/Q 双侧 2 次判档，gate 后 PID/starttime 全程冻结。
- [ ] 每个 fio 前 health、对象数、四节点 drop_caches 均有证据。
- [ ] 每个活动 fio 有全文和全部 per-job bw logs；并发 P/Q 有各自 start-ns。
- [ ] 未计算百分比、均值、中位数、CV 或归因结论。
- [ ] 未 kill、未 pkill 任何进程；`background-monitors-initial.txt`（应为空，见 §2.1b）与各配置 host-state 已留痕，非空情况已在报告列出。
- [ ] `skew-events.tsv` 每条都满足「仅一条告警且为时钟漂移、值 ≤0.5 s」，没有其他类型告警被放过。
- [ ] 没有顺手执行 Phase X、T2、TiKV 或 max-downloads。
- [ ] 全部脚本改动（若有）只改实现、未改变量，且已按 §八.3 记录旧/新 md5 与理由。

任一项不满足，最终回复中显式标注；不要补造数据。

## 八、无人值守监控与改动纪律

本任务是 3.5–4.5 小时的单轨无人值守跑，不再另发夜间编排总任务书（`03-16N` 已作废）。下列三条从 `03-16N` §5、§6 移入本任务书，与上文同等生效。

### 8.1 监控频率

- 默认每 30 分钟唤醒一次；单次 `sleep` 不超过 30 分钟。
- 预计 10 分钟内结束的 gate/cooldown 可 2–10 分钟查一次。
- 每次 sleep 前打印北京时间；每小时更新一次预计完成时间。

### 8.2 每次必查项

1. wrapper 精确 PID、子 fio PID 与当前 `run-*` 目录；
2. `wrapper.log` 最后 50 行、最新 `DONE`/`STOP` 行；
3. `sudo ceph health` 与 pool objects；
4. P/Q 挂载 PID/starttime 是否仍等于 `frozen-*.tsv`；
5. `/mnt/juicefs` 身份是否逐字不变（含"仍为 NA"）；
6. 主机内存、磁盘、是否出现非本任务 fio；
7. `progress.tsv` 行数与 `bwlog/` 文件数是否继续增长。

**只看到进程消失不能判 DONE**：必须同时有 `wrapper.log` 的 `ALL DONE`、`MANIFEST.md5`、tar.gz 及其 md5。

### 8.3 SSH 断线与单实例纪律

测试须由可恢复会话或后台 wrapper 承载，SSH 断线不重启任务。重连后先判原 PID、日志与 marker，再决定动作。**禁止因"不确定"而启动第二份 fio**。脚本本身已有双启动保护：`OUT` 非空 `exit 2`、专用挂载点已占用 `exit 6`；若命中这两个退出码，说明已有实例或有旧证据，一律先回报，不得改 `OUT` 绕过。

### 8.4 可自主修与必须 STOP

可自主修（属"实现"）：本地 bash 语法、路径、依赖、权限位、采集缺文件、归档与报告生成。修改前保存旧文件，修改后在 `adaptations.tsv` 记录旧/新 md5、diff、原因，以及"为何这不改变量"。

必须 STOP，不得自行解决（属"变量、权限、安全门"）：

- 改 fio 参数、矩阵、臂顺序、运行时长、挂载选项；
- 改 ns/B 参照值 `3.287`、容差 `10%`、对象闸门 `3,110,000` **或其取值口径**；
- 需要 gc、compact、删数据、改 Ceph/TiKV 配置或 restart；
- 需要 kill/umount 非本任务的进程或挂载；
- 需要扩大步骤 0 的 sudo 清单。

> 前车之鉴：本脚本曾被以"Fix"为名把对象闸门从 Ceph pool objects 换成 `juicefs status` 的 `UsedInodes`（实测 429 vs 阈值 3,110,000），使闸门永久失效且逐轮对象轨迹全为常数。这类改动就是"改变量"，一律 STOP 上报。

