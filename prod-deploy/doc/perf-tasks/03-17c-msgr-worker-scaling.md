# 03-17c：ms_async_op_threads 标度扫描（T47C）

> 计划线：03-16（读侧约束定为 per-mount，B2 解除）→ **03-17 原设计作废**（自变量未测到，暴露档位波动）→
> 03-17b/T48（定性：H1 成立，msgr-worker 是瓶颈，F56/F57 立账，B8 解除）→ **本任务 03-17c：把 worker 数当自变量做标度扫描，验证 F56 外推、判 6250 MiB/s 可达性**。
>
> ⚠ 原 03-17 任务书 `doc/perf-tasks/03-17-librados-messenger-threads.md` **保持原样归档，不修改**。本任务书取代它。

- 脚本：`/tmp/t47-librados-msgr-threads.sh`（844 行，md5 `8b92e9a8f575bb2fc89c3d94a7d1dfd0`）
- 输出：`/tmp/production/opencode-t3.17c`
- 二进制：`/tmp/juicefs-03-8`，md5 必须为 `de93563f11a5ff3bd94dd25a4e0283b1`
- 预计时长：**≈90 分钟**（20 次挂载 × 约 4.5 分钟）。属长测，**建议晚间跑**。

## 〇、为什么这么设计（读懂再动手）

03-17b 已经把机制查清了，本任务只做一件事：**把 `ms_async_op_threads` 当自变量，验证外推。**

T48 的三条结论决定了本任务的设计：

| T48 结论 | 本任务对应设计 |
|---|---|
| **F56** per-mount 读带宽 = 1438 MiB/s × msgr-worker 满载核数（8 轮 r=0.9962，离散 1.2%）；3 worker 上限 ≈4184 | 扫 `ms_async_op_threads` = **3 / 4 / 6 / 8**，另加 **A1（=1）** 作标度下端锚点 |
| 方差源 = **建连时连接到 worker 的分配抽签**，每次挂载重抽 | **重复单位改成"独立挂载"**：每臂 4 次独立挂载，而不是同一挂载内跑 4 次 fio（后者只是复读同一次抽签） |
| **F57** `io_context_pool` 线程 8 轮 CPU 恒为 0.00s | **删掉 `librados_thread_count` 维度**（原 X8 臂），但仍核对它必须等于库默认 2 |
| worker CPU 离散度 CV 与 bw 的 r = −0.9907，远强于 in-flight 的 0.81 | 每轮采逐线程 CPU，**CV 作协变量落盘**，不作判定 |
| F55 会话内慢漂移仍在 | 臂序**每轮左移一位**轮转，抵消时序混淆 |

**预期检验点**（你不要验证，也不要计算，只要把数据取全）：4 worker ≈5579、6 worker ≈8369 MiB/s。若显著低于外推值，说明撞上了 F51 机器级上限或新的串行点 —— 这正是本任务要发现的东西，**低于预期不是失败，不要重跑**。

## 一、⚑ 与作废的 03-17 最不一样的三条

1. **没有 ns/B 停机门槛了。** ns/B 只作协变量记录，任何值都不停机（修 B4-11、B4-12、B4-14）。判档器 `t39-nsbgate.sh` 仍被调用，但脚本把 `NSB_TOL` 抬到 100000，所以它的 verdict **恒为 PASS**，那行输出只是用来取 ns/B 数值的，**不要按它判断好坏**。
2. **批次锚点窗口放宽到 ±25% 才停机**，±10% 只打 `NOTE`。原因：F56 抽签使单次挂载天然散布 ±15%，原 ±10% 硬窗口会把正常数据判死。
3. **`ALL DONE` 已移到压缩包生成之后**（修 B4-13），`MANIFEST.md5` 改相对路径（修 B4-15）。所以本任务里 `ALL DONE` 出现即代表产物齐全。

## 二、固定环境（一个都不许动）

| 项 | 值 |
|---|---|
| 二进制 | `/tmp/juicefs-03-8`，md5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| fio | 3.28，`--rw=randread --bs=256k --iodepth=128 --numjobs=64 --direct=1 --readonly`，180 s |
| 元数据 | `tikv://10.20.1.150:2379,151,152/juicefs-prod` |
| 专用挂载 | 只用 `/mnt/juicefs-p` |
| 参数注入 | **只经进程私有 conf + `CEPH_CONF`**，脚本自动生成 |

- ⛔ 不改 `/etc/ceph/ceph.conf`（脚本起止两次核 md5，变了就 STOP），不执行 `ceph config set`。
- ⛔ 不动业务挂载 `/mnt/juicefs`。
- ⛔ 不跑写负载、不 gc/compact/重启，全程 `--readonly`。
- ⛔ 不改 `objecter_inflight_ops`、`--max-uploads`、`--max-fuse-io`、`--cache-size`。
- ⛔ 不用 `taskset`/`numactl` 绑核，不 renice。
- ⛔ 注入不生效时**不许换第二种注入方式后继续**，必须 STOP 回报。
- ⛔ 不改脚本。要改回报，由分析方改。

## 三、矩阵

臂 = `ms_async_op_threads`：**A3=3、A4=4、A6=6、A8=8、A1=1**。

4 轮，每轮每臂各**一次独立挂载 + 一次 P64（180 s）**，共 **20 次挂载 / 20 个 run**。臂序每轮左移：

```
ROUND 1: A3 A4 A6 A8 A1
ROUND 2: A4 A6 A8 A1 A3
ROUND 3: A6 A8 A1 A3 A4
ROUND 4: A8 A1 A3 A4 A6
```

每次挂载后脚本**强制核对** `msgr-worker` 线程数 == 请求值、`io_context_pool` == 2，不等即 STOP（注入没生效，继续跑没有意义）。

## 四、执行步骤

### 步骤 0：只读安全扫描

```bash
date; uptime; who | wc -l
md5sum /tmp/juicefs-03-8 /etc/ceph/ceph.conf /tmp/t47-librados-msgr-threads.sh
pgrep -af 'fio|t4[0-9]-' | grep -v $$ || echo "无残留"
mount | grep juicefs
sudo ceph health detail | head -5
```

### 步骤 1：核对脚本 md5

```bash
md5sum /tmp/t47-librados-msgr-threads.sh   # 必须 8b92e9a8f575bb2fc89c3d94a7d1dfd0
```
不一致就停下来问，**不要自己改**。

### 步骤 2：验证线程注入（约 1 分钟，不跑 fio）

```bash
ACK_SUDO_WRITES=YES bash /tmp/t47-librados-msgr-threads.sh --preflight-msgr-only
```
把 `msgr-preverify.txt` 全文发我。期望：请求 `ms_async_op_threads=6` → 观测 `msgr-worker=6`，且 `io_context_pool=2`（库默认，本任务不注入）。

### 步骤 3：管路冒烟（约 6 分钟，独立 OUT，不产出可用数据）

```bash
ACK_SUDO_WRITES=YES ROUNDS=1 RUNTIME=30 \
  OUT=/tmp/production/opencode-t3.17c-smoke \
  nohup bash /tmp/t47-librados-msgr-threads.sh full > /tmp/t47c-smoke.log 2>&1 &
```

⚑ 一定要用 `nohup` 并保留 `/tmp/t47c-smoke.log`（上次 SSH 断线把冒烟证据带走了）。

跑完把下面这组命令的**原始输出整段**贴给我，不加工、不总结、不算比例：

```bash
S=/tmp/production/opencode-t3.17c-smoke
cat $S/arm-covariates.tsv
cat $S/msgr-threads.tsv
wc -l $S/run-*/threads-series.tsv
grep -c msgr-worker $S/run-*/threads-pre.tsv
awk -F'\t' 'NR>1{print $6}' $S/run-*/threads-series.tsv | sort -n | uniq -c | head -3
tail -5 $S/wrapper.log
ls -la $S.tar.gz $S.tar.gz.md5
```

我要确认三件事：`arm-covariates.tsv` 有 5 行数据且 `msgr_threads` 列分别是 3/4/6/8/1、`n_worker` 列与之一致；`worker_cv_pct` 不是 NA；`processor` 列出现 0~127 的值（**>95 正常，157 是 128 逻辑 CPU**）。

冒烟完：`rm -rf /tmp/production/opencode-t3.17c-smoke*`，但**留下** `/tmp/t47c-smoke.log`。

### 步骤 4：无状态清点

```bash
bash /tmp/t47-librados-msgr-threads.sh --preflight
```
把 `preflight-summary.txt` 全文发我。

### 步骤 5：拿到我对步骤 0~4 的明确确认后，跑正式矩阵

```bash
{ echo "launcher_pid=$$"; taskset -cp $$; \
  grep -E 'Cpus_allowed_list|Mems_allowed_list' /proc/self/status; \
  echo "nproc=$(nproc)"; echo "online=$(cat /sys/devices/system/cpu/online)"; } \
  > /tmp/t47c-cpus-allowed-launcher.txt 2>&1
ACK_SUDO_WRITES=YES nohup bash /tmp/t47-librados-msgr-threads.sh full \
  > /tmp/t47c-nohup.log 2>&1 &
```

跑完把 `/tmp/t47c-cpus-allowed-launcher.txt` 一起回传（F55/H4 留档用）。

**每完成一轮报一次**（约 22 分钟一轮），只报机械状态：`arm-covariates.tsv` 的行数 + 最后一行原文。⛔ 不解读、不算平均、不说"哪个臂更快"。

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
10. `msgr-worker` 线程数 ≠ 请求值（注入未生效）。
11. `io_context_pool` 线程数 ≠ 2。
12. 挂载 `max_read` ≠ 262144。
13. 实例 PID / starttime 漂移。
14. 数据集不完整（`read_test.*.0` ≠ 128）。
15. fio 非零退出，或缺 `READ: bw=` 汇总行，或 bw log 数 ≠ 64。
16. 落盘空间 < 5120 MiB。
17. 专用挂载点已被占用，或专用目录非空。
18. OSD `perf dump` 预探失败。
19. A3 批次锚点均值偏离 03-16 基准 4021.3 超 **±25%**（±10% 只打 NOTE，不停机）。

## 六、⚑ 不构成 STOP、不要干预的现象

- `verdict=PASS` 恒出现 —— 判档器已被抬高关闭，那行只用来取 ns/B 数值。
- 某个臂某一轮 bw 明显偏低 —— F56 抽签就是这样，本任务正是要采它的分布。**不要重挂、不要重跑、不要补样本。**
- `threads-series.tsv` 的 `processor` 列出现 > 95 的值 —— 157 是 128 逻辑 CPU，正常。
- 高 worker 数臂的 bw 低于线性外推 —— 可能撞上 F51 机器级上限，这是本任务的发现之一。
- `NOTE 批次锚点偏离 ±10%` —— 记录性提示，继续跑。

## 七、回传

只回传 `/tmp/production/opencode-t3.17c.tar.gz` + `.md5` + `/tmp/t47c-cpus-allowed-launcher.txt` + `/tmp/t47c-nohup.log`。

产物自查（报数字即可）：

- `arm-covariates.tsv` 应有 **20 行数据**（+1 行表头）
- `run-*` 目录 **20 个**，每个含 `fio-P.txt`、`i1-P.tsv`、`threads-pre.tsv`、`threads-post.tsv`、`threads-series.tsv`、`proc-P.tsv`、`net.tsv`
- `osd/` 下 json **240 个**（20 run × 6 OSD × pre/post）
- `bwlog/` 下 **1280 个**（20 × 64）
- `msgr-threads.tsv` **20 行数据**，`got_msgr` 列与请求值逐行一致
- `ALL DONE` + `tar.gz` + `tar.gz.md5` 三者同时存在

## 八、回复模板

```
步骤 0：157 时间 __ load __ 登录用户 __ 残留 __ ceph.conf md5 __ 二进制 md5 __
步骤 1：脚本 md5 __（应 8b92e9a8f575bb2fc89c3d94a7d1dfd0）
步骤 2：注入验证 请求 msgr=6 观测 __ / io_context 观测 __
步骤 3：冒烟 arm-covariates 行数 __ n_worker 列 __ worker_cv 是否 NA __ processor 范围 __ tar.gz 有/无
步骤 4：preflight 对象数 __ fio __ 落盘 __ MiB 背景监控 __
正式矩阵：启动掩码 __ 起点对象数 __ 收尾对象数 __ 对象下跌条目数 __ 最大跌幅 __
        arm-covariates.tsv 共 __ 行；全文原样粘贴如下（不做任何加工）：
        <粘贴全文>
产物清点：run 目录 __/20  osd json __/240  bwlog __/1280  msgr-threads __/20
锚点：anchor-check.tsv 原文 __
时钟漂移 __ 次，峰值 __ s
包：/tmp/production/opencode-t3.17c.tar.gz  md5 __
```

⛔ 回复里不要出现平均值、百分比、"哪个臂更好"、"是否达标"之类的判断。统计一律由分析方从原始数据复算（历史上执行方的统计出过错，这是硬规矩）。

## 九、本任务不做的事

- 不扫 `librados_thread_count`（F57 已否）。
- 不跑双挂载 CTL、不跑 P128、不跑 randrw/写负载。
- 不做 CPU 绑核 / NUMA 绑定实验。
- 不试图"修好"低带宽轮次。
- 不验证 F51 机器级上限（那要多挂载，另立项）。
