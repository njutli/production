# 03-17d：读侧并发标度扫描（T49D，msgr 固定 8）

> 计划线：03-16（读侧约束定为 per-mount）→ 03-17 原设计作废 → 03-17b/T48（H1 成立，msgr-worker 是瓶颈）→
> 03-17c/T47C（worker 标度扫完：**F58 有效 worker 数 = OSD 数 6；F59 ≥6 worker 后瓶颈换成"在飞并发 × 延迟"积**，单挂载 P64 均值 5167、峰值 5412）→
> **本任务 03-17d：worker 固定在 8，只把"并发流数"当自变量，判 6250 MiB/s 是否可达、以及被谁挡住。**
>
> ⚠ 03-17c 任务书与脚本 **保持原样归档，不修改**。

- 脚本：`/tmp/t49-read-concurrency-sweep.sh`（由 t47 派生，见 §一，854 行，md5 `2cf5cd4479e96b6667c4a1ec1f1d9e76`）
- 输出：`/tmp/production/opencode-t3.17d`
- 二进制：`/tmp/juicefs-03-8`，md5 必须为 `de93563f11a5ff3bd94dd25a4e0283b1`
- 预计时长：**≈45 分钟**（9 次挂载 × 约 4.5 分钟）。属短测，**白天可跑**，但启动前 load 必须 < 30。

## 〇、为什么这么设计（读懂再动手）

03-17c 已经把 messenger 线程这条路走到尽头，本任务只做一件事：**把并发流数当自变量，看在飞请求数能不能越过 64。**

03-17c 的四条复算结论决定了本任务的设计：

| 03-17c 结论 | 本任务对应设计 |
|---|---|
| **F58** 数据面连接只有 6 条（= OSD 数），`ms_async_op_threads` > 6 不再增加并行度；取 8 只为防落位碰撞（A8 4/4 轮无碰撞，批内 CV 2.8%；A6 有 1/4 轮碰撞） | **worker 数不再是自变量，全程固定 `ms_async_op_threads=8`**，仍每次挂载强制核对线程数 == 8 |
| **F59** 全 20 轮在飞 GET 恒为 **63.94 ± 0.69**（CV 1.1%），GET 恒 249 KB，`bw ~ 1/GET延迟` **r = 0.9999**；≥6 worker 时 worker 最忙仅 47–73%、客户端总 CPU 8.5/96 核 | 自变量改成 **`--numjobs` = 64 / 96 / 128**，即直接抬在飞并发。iodepth 保持 128 不变（实测它不起作用，在飞数 = numjobs，改它会破坏单变量） |
| 延迟在 ≥6 worker 处触到 **≈2.8 ms 地板**；达 6250 需延迟再降 10.2%，或在飞并发 +11.2%（64 → 71.2） | J96/J128 都在"理论达标点 71.2"之上，**一轮就能判出方向**：并发能上去就必然穿过 6250 线或撞上更高的墙 |
| F42b「读在 64 并发流饱和」是在 worker 饱和态（msgr=3，加流只加延迟）下得出的 | 本任务在 msgr=8、worker 有 27–53% 余量的新条件下**重测 F42b**。这是全任务的核心问题 |

**预期检验点**（你不要验证，也不要计算，只要把数据取全）：

- 若在飞并发随 numjobs 上去、延迟基本不变 → 带宽会显著上升，可能撞上 F51 机器级上限（6246–6554 MiB/s）。
- 若在飞并发**仍卡在 ≈64**（哪怕 numjobs=128）→ 这是本任务最重要的发现，说明窗口在客户端侧被夹死。
- 若在飞并发上去但延迟同比例上升、带宽持平 → 说明 OSD 侧服务已饱和。

**上面三种都算成功。带宽不涨、或某轮偏低，都不是失败，不要重挂、不要重跑、不要补样本。**

## 一、⚑ 与 03-17c 脚本的差异（共 9 处，脚本已按此派生）

1. 臂定义换成并发：`ARMS=(J64 J96 J128)`，`ARM_JOBS=([J64]=64 [J96]=96 [J128]=128)`；`ARM_N` 全部 = 8（`ms_async_op_threads` 恒 8）。
2. `CFG` 不再是常量 P64，改为按臂取 `P${jobs}`；`--numjobs` 取自臂，**其余 fio 参数逐字不变**（`--rw=randread --bs=256k --iodepth=128 --direct=1 --readonly --runtime=180`）。
3. bw log 数量校验按臂取值（64 / 96 / 128），不再硬比 64。
4. 批次锚点换成 **J64 臂 vs 03-17c A8/P64 均值 5167.2**（同二进制、同挂载参数、同 msgr=8、同 P64，属完全一致配置，R16 ③ 满足）：`ANCHOR_MID=5167.2`，`±10%` 打 NOTE，`±25%` STOP。
5. `ROUNDS` 默认 3（3 臂 × 3 轮 = 9 次独立挂载）。
6. 臂序每轮左移一位（继续抵 F55 时序漂移）。
7. pprof 采样条件从「第 2 轮的 A3/A8」改为「**第 2 轮的 J64/J128**」，用于对比低/高并发下的排队结构。
8. `arm-covariates.tsv` 增加 `jobs` 列（第 4 列），并保留 03-17c 全部协变量列（bw、ns/B、worker_cv_pct、max_worker_pct_core、msgr_sum_core、n_worker）。⚑ 其中 `worker_cv_pct` 仍按老口径把空闲 worker 计入（分析方已知，会自行重算 active-only CV），**不要据此判断好坏**。

9. ⚑ 顺带修一个新记的缺陷 **B4-16**：t47 里 `RUNTIME=180` 是硬赋值，环境变量 `RUNTIME` 被静默吞掉 —— 03-17c 步骤 3 那次「`RUNTIME=30` 冒烟」其实是按 180 s 跑的（这也是它比预估 6 分钟慢的原因）。本脚本改成 `${RUNTIME:-180}`、`${GAP:-20}`，所以**本任务的冒烟真的只跑 30 s/臂**。

其余一切照 03-17c：ns/B 不停机（`NSB_TOL=100000`，verdict 恒 PASS）、`ALL DONE` 在打包之后、`MANIFEST.md5` 相对路径、`mount_pid()` 取实例进程、背景监控清点剔除自身进程树、对象闸门单向。

## 二、固定环境（一个都不许动）

| 项 | 值 |
|---|---|
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| Ceph 参数 | `ms_async_op_threads=8`（唯一注入项，进程私有 conf + `CEPH_CONF`），`io_context_pool` 保持库默认 2 |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| fio | 3.28，`--rw=randread --bs=256k --iodepth=128 --direct=1 --readonly`，180 s，**只有 `--numjobs` 变** |
| 元数据 | `tikv://10.20.1.150:2379,151,152/juicefs-prod` |
| 数据集 | 现有 `read_test.*.0` **128 个文件**，⛔ 不许扩、不许重建（对象闸门） |
| 专用挂载 | 只用 `/mnt/juicefs-p` |

- ⛔ 不改 `/etc/ceph/ceph.conf`（脚本起止两次核 md5，变了就 STOP），不执行 `ceph config set`。
- ⛔ 不动业务挂载 `/mnt/juicefs`。
- ⛔ 不跑写负载、不 gc/compact/重启，全程 `--readonly`。
- ⛔ 不改 `objecter_inflight_ops`、`--max-uploads`、`--max-fuse-io`、`--cache-size`、`iodepth`。
- ⛔ 不改 `ms_async_op_threads`（本任务它是常量 8，不是变量）。
- ⛔ 不用 `taskset`/`numactl` 绑核，不 renice。
- ⛔ numjobs 不许超过 128（数据集只有 128 个文件，再高会出现多 job 抢同一文件，破坏口径）。
- ⛔ 注入不生效时不许换第二种注入方式后继续，必须 STOP 回报。
- ⛔ 不改脚本。要改回报，由分析方改。

## 三、矩阵

臂 = `--numjobs`：**J64=64、J96=96、J128=128**；`ms_async_op_threads` 恒 8。

3 轮，每轮每臂各**一次独立挂载 + 一次 fio（180 s）**，共 **9 次挂载 / 9 个 run**。臂序每轮左移：

```
ROUND 1: J64  J96  J128
ROUND 2: J96  J128 J64
ROUND 3: J128 J64  J96
```

重复单位仍是**独立挂载**（F58/F56：连接落位每次挂载重抽签，同一挂载内复跑只是复读同一次抽签）。

每次挂载后脚本**强制核对** `msgr-worker` 线程数 == 8、`io_context_pool` == 2，不等即 STOP。

## 四、执行步骤

### 步骤 0：只读安全扫描

```bash
date; uptime; who | wc -l
md5sum /tmp/juicefs-03-8 /etc/ceph/ceph.conf /tmp/t49-read-concurrency-sweep.sh
pgrep -af 'fio|t4[0-9]-' | grep -v $$ || echo "无残留"
mount | grep juicefs
sudo ceph health detail | head -5
ls /mnt/juicefs/test_dir/read_test.*.0 2>/dev/null | wc -l
```

⚑ load 若 ≥ 30，先报数等我确认再继续（本任务在飞并发要抬到 128，客户端 CPU 余量必须留够）。

### 步骤 1：核对脚本 md5

```bash
md5sum /tmp/t49-read-concurrency-sweep.sh   # 必须 2cf5cd4479e96b6667c4a1ec1f1d9e76
```
不一致就停下来问，**不要自己改**。

### 步骤 2：验证线程注入（约 1 分钟，不跑 fio）

```bash
ACK_SUDO_WRITES=YES bash /tmp/t49-read-concurrency-sweep.sh --preflight-msgr-only
```
把 `msgr-preverify.txt` 全文发我。期望：请求 `ms_async_op_threads=8` → 观测 `msgr-worker=8`，`io_context_pool=2`。

### 步骤 3：管路冒烟（约 4 分钟，独立 OUT，不产出可用数据）

```bash
ACK_SUDO_WRITES=YES ROUNDS=1 RUNTIME=30 \
  OUT=/tmp/production/opencode-t3.17d-smoke \
  nohup bash /tmp/t49-read-concurrency-sweep.sh full > /tmp/t49d-smoke.log 2>&1 &
```

⚑ 必须 `nohup`，并保留 `/tmp/t49d-smoke.log`。

跑完把下面这组命令的**原始输出整段**贴给我，不加工、不总结、不算比例：

```bash
S=/tmp/production/opencode-t3.17d-smoke
cat $S/arm-covariates.tsv
cat $S/msgr-threads.tsv
ls $S/bwlog/ | sed 's/_bw\..*//' | sort | uniq -c
grep -c msgr-worker $S/run-*/threads-pre.tsv
grep -c juicefs_object_request_durations_histogram_seconds_GET_total $S/run-*/i1-P.tsv
tail -5 $S/wrapper.log
ls -la $S.tar.gz $S.tar.gz.md5
```

我要确认四件事：`arm-covariates.tsv` 有 3 行数据且 `jobs` 列为 64/96/128；每臂 bw log 数与 jobs 一致；`n_worker` 列恒为 8；`i1-P.tsv` 里 GET 计数键存在（在飞数要靠它算，缺了整个任务白跑）。

冒烟完：`rm -rf /tmp/production/opencode-t3.17d-smoke*`，但**留下** `/tmp/t49d-smoke.log`。

### 步骤 4：无状态清点

```bash
bash /tmp/t49-read-concurrency-sweep.sh --preflight
```
把 `preflight-summary.txt` 全文发我。

### 步骤 5：拿到我对步骤 0~4 的明确确认后，跑正式矩阵

```bash
{ echo "launcher_pid=$$"; taskset -cp $$; \
  grep -E 'Cpus_allowed_list|Mems_allowed_list' /proc/self/status; \
  echo "nproc=$(nproc)"; echo "online=$(cat /sys/devices/system/cpu/online)"; } \
  > /tmp/t49d-cpus-allowed-launcher.txt 2>&1
ACK_SUDO_WRITES=YES nohup bash /tmp/t49-read-concurrency-sweep.sh full \
  > /tmp/t49d-nohup.log 2>&1 &
```

**每完成一轮报一次**（约 14 分钟一轮），只报机械状态：`arm-covariates.tsv` 的行数 + 最后一行原文。⛔ 不解读、不算平均、不说"哪个臂更快"、不说"是否达标"。

### 步骤 6：命中 STOP 时

保留现场（⛔ 不删 OUT、不卸载残留、不重跑），贴 `wrapper.log` 最后 30 行 + STOP 那一行原文。

## 五、STOP 条件（脚本自动停，你不要自己加判断）

1. `/etc/ceph/ceph.conf` md5 变化。
2. 业务挂载 `/mnt/juicefs` 身份（挂载行 / PID / starttime）变化。
3. 二进制 md5 不符。
4. fio 版本不是 3.28。
5. Ceph 非 `HEALTH_OK`，且不是"唯一告警为 clock skew 且 ≤0.5 s"。
6. 起点对象数 > 3,110,000。
7. 轮内对象数**上涨**（只读任务不该产生对象）。
8. 轮内对象数**下跌 > 1000**；下跌 ≤1000 只记录进 `objects-shrink.tsv` 并继续。
9. 对象数不可解析。
10. `msgr-worker` 线程数 ≠ 8（注入未生效）。
11. `io_context_pool` 线程数 ≠ 2。
12. 挂载 `max_read` ≠ 262144。
13. 实例 PID / starttime 漂移。
14. 数据集不完整（`read_test.*.0` ≠ 128）。
15. fio 非零退出，或缺 `READ: bw=` 汇总行，或 bw log 数 ≠ 本臂 jobs 数。
16. 落盘空间 < 5120 MiB。
17. 专用挂载点已被占用，或专用目录非空。
18. OSD `perf dump` 预探失败。
19. J64 批次锚点均值偏离 03-17c 基准 **5167.2** 超 ±25%（±10% 只打 NOTE，不停机）。

## 六、⚑ 不构成 STOP、不要干预的现象

- `verdict=PASS` 恒出现 —— 判档器已被抬高关闭，那行只用来取 ns/B 数值。
- J96/J128 带宽**不比 J64 高**，甚至更低 —— 这正是要采的信息（F42b 在新条件下是否仍成立），**不要重跑**。
- J128 的 fio 平均延迟大幅上升 —— 队列变长的正常表现，只要 bw 汇总行在就行。
- 客户端 load 因 128 个 fio job 升高 —— 只记录在 `host-state-*.txt`，不干预。
- `worker_cv_pct` 显示 50%+ —— 老口径把空闲 worker 计入，msgr=8 时恒如此（03-17c 已查明），正常。
- `threads-series.tsv` 的 `processor` 列出现 > 95 的值 —— 157 是 128 逻辑 CPU，正常。
- 某轮落位碰撞（活跃 worker < 6）导致带宽偏低 —— F58 抽签固有，采它的分布即可。

## 七、回传

只回传 `/tmp/production/opencode-t3.17d.tar.gz` + `.md5` + `/tmp/t49d-cpus-allowed-launcher.txt` + `/tmp/t49d-nohup.log`。

产物自查（报数字即可）：

- `arm-covariates.tsv` 应有 **9 行数据**（+1 行表头）
- `run-*` 目录 **9 个**，每个含 `fio-P.txt`、`i1-P.tsv`、`threads-pre.tsv`、`threads-post.tsv`、`threads-series.tsv`、`proc-P.tsv`、`net.tsv`、`command-P.txt`
- `osd/` 下 json **108 个**（9 run × 6 OSD × pre/post）
- `bwlog/` 下 **864 个**（3×64 + 3×96 + 3×128）
- `msgr-threads.tsv` **9 行数据**，`got_msgr` 列恒为 8
- `ALL DONE` + `tar.gz` + `tar.gz.md5` 三者同时存在

## 八、回复模板

```
步骤 0：157 时间 __ load __ 登录用户 __ 残留 __ ceph.conf md5 __ 二进制 md5 __ 数据集文件数 __
步骤 1：脚本 md5 __（应 2cf5cd4479e96b6667c4a1ec1f1d9e76）
步骤 2：注入验证 请求 msgr=8 观测 __ / io_context 观测 __
步骤 3：冒烟 arm-covariates 行数 __ jobs 列 __ bwlog 各臂计数 __ GET 计数键 有/无 tar.gz 有/无
步骤 4：preflight 对象数 __ fio __ 落盘 __ MiB 背景监控 __
正式矩阵：启动掩码 __ 起点对象数 __ 收尾对象数 __ 对象下跌条目数 __ 最大跌幅 __
        arm-covariates.tsv 共 __ 行；全文原样粘贴如下（不做任何加工）：
        <粘贴全文>
产物清点：run 目录 __/9  osd json __/108  bwlog __/864  msgr-threads __/9
锚点：anchor-check.tsv 原文 __
时钟漂移 __ 次，峰值 __ s
包：/tmp/production/opencode-t3.17d.tar.gz  md5 __
```

⛔ 回复里不要出现平均值、百分比、"哪个臂更好"、"是否达标"之类的判断。统计一律由分析方从原始数据复算（历史上执行方的统计出过错，这是硬规矩）。

## 九、本任务不做的事

- 不再扫 `ms_async_op_threads`（F58 已封顶在 OSD 数 6，12/16 worker 预测零收益）。
- 不扫 `librados_thread_count`（F57 已否）。
- 不改 `iodepth`、不改 `--max-fuse-io`、不改 `objecter_inflight_ops`（客户端窗口类旋钮留到 03-17e 定性之后再议）。
- 不跑双挂载 / 多挂载聚合（F51 机器级上限验证另立项）。
- 不跑写负载、randrw、seq 项。
- 不扩数据集、不做 CPU 绑核 / NUMA 绑定实验。
- 不试图"修好"低带宽轮次。

## 十、分析方判据（GLM 不执行，仅供留档）

拿到数据后由分析方从原始文件复算（`fio-P.txt` / `i1-P.tsv` / `threads-pre|post.tsv`），三分支收口：

| 观测 | 判定 | 下一步 |
|---|---|---|
| 在飞 GET 随 jobs 上升（≈ jobs）且 GET 延迟基本持平 | 并发是有效旋钮 | 看平台值：≥6250 ⇒ **读侧目标达成**，记录推荐配置；落在 6246–6554 ⇒ 确认 **F51 是最终墙**，立 03-17e 验证机器级上限 |
| 在飞 GET 仍 ≈64（jobs=96/128 无效） | 客户端窗口夹死，F42b 结构性成立 | 读侧在现配置下封顶 ≈5.4 GiB/s；转查窗口位置（FUSE 并发 / 预取 / objecter），或结论层记录上限并转写侧 B1 |
| 在飞 GET 上升但延迟同比例上升、bw 持平 | OSD 侧服务饱和 | 读侧目标在现 6 OSD EC 池规模下不可达，需扩 OSD/PG（超出 03 阶段授权），转写侧 B1 |
