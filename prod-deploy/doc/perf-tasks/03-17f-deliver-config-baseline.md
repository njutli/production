# 03-17f 任务书：交付配置七项新基线（重做 03-17e Seg B）

> 计划线：`03-16 → 03-17（作废）→ 03-17b → 03-17c → 03-17d → 03-17e（Seg A 成立/Seg B 撤回）→ **03-17f（本任务书）** → B1 写侧 TiKV`
> 执行方：GLM　｜　分析方：opencode　｜　立项日：2026-08-21
> 前置报告：`doc/perf-report/03-17e-multimount-and-new-baseline-20260821.md`（§3.5 硬伤、§3.7 四格表、§7 判决）
> 立项原因：03-17e Seg B 因**口径设错**（任务书错误 A37/B9）+ 三条执行侧硬伤被整段撤回（A36），4 h 机器时间作废。本任务书重做，并同时补齐四格交互。

---

## 〇、GLM 全自动执行纪律（与 03-17e §〇 相同，逐条仍生效）

1. ⛔ **全程不得向人提问**。只有 §七 穷举的 STOP 条件才停机；其余异常一律记录并续跑。
2. 段与段之间**直接连跑**，不等确认。
3. 进度播报**只报机械状态**（cell 名 / 结束时间 / `rounds.tsv` 最后一行原文 / 哨兵最后一行原文）；⛔ 不报均值、不报百分比、不做好坏判断、不写结论。
4. 一切统计量由 opencode 从原始数据计算 ⇒ 报告只贴原始数字与原文，⛔ 不做归因。
5. 开工前先 `md5sum` 本文件，与派发报文中的 md5 核对，不一致立即回报并停手。

---

## 一、本次要回答的问题（分析方判决表，执行方不必判）

| # | 问题 | 判决依据 |
|---|---|---|
| 1 | **交付配置的七项基线数值**（补丁二进制 + `ms_async_op_threads=8` + `--max-fuse-io 256K`） | A 臂 7 项 × 3 次独立挂载，L2 极差 ≤5% 才算可固化；逐项对 03-10（28 点）与 E6 做非劣/增益判定 |
| 2 | **msgr 效应的第三次独立估计** | B 臂（msgr=3，其余相同）对 A 臂同项之比；已有 +44.3%（03-17e 同批）与 +46.8%（S128 对 03-10 跨批），本次给同批同口径的写/读双侧值 |
| 3 | **四格交互是否存在**（`max-fuse-io` × `msgr`） | 与 03-17e 的 (128K,8)=2591 / (128K,3)=1179 合表；若 A/B 之比 ≈ +44~47% 则 03-17e 的 +119.8% 判为坏档伪值（硬伤①②），若 ≈ +120% 则判为真交互 |
| 4 | **`de93563f` 二进制在 256K FUSE 下写侧是否安全** | Gate 0：randwrite 必须 ≥ 2942 MiB/s（见 §二.3） |

---

## 二、环境、二进制与四个已知陷阱（开跑前逐条自检并把结果写进日志）

| 项 | 值 |
|---|---|
| 目标机 | `ssh thailand`（157）；157 时间 = WSL − 1 h |
| 元数据 | `META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod` |
| 卷设置 | `BlockSize=256`KiB / `Compression=none` / `TrashDays=0` / `Bucket=ceph://juicefs-data`（⛔ 不改） |
| 系统 ceph.conf | `/etc/ceph/ceph.conf`，md5 **`5b6be34179a64e0a5f9c6d3a9690041f`** —— ⛔ **全机共用，禁改、禁 `ceph config set`**；起止各记一次 md5 |
| 主脚本 | `/tmp/FULLBASELINE_V4.sh`（⛔ **不得修改一个字符**，全部靠 PATH / `CEPH_CONF` / 环境变量 / 位置参数驱动） |
| 结果目录 | `RESULTS=/tmp/opencode-fullbaseline-v4`（V4 硬编码） |

### 二.1 ⚠ 陷阱一：二进制有两个构建，裸 `juicefs` 会取错

| 路径 | md5 | version | 用途 |
|---|---|---|---|
| `/tmp/juicefs-03-8` | **`de93563f11a5ff3bd94dd25a4e0283b1`** | `1.3.1+2025-12-02.e0032b2a`（**末尾有 a**） | ✅ 本次唯一允许 |
| `/usr/local/bin/juicefs` | `bdd182cf2cd43be657cb4ec0b5a6a048` | `…e0032b2`（**无 a**） | ⛔ 错版本 |
| `/tmp/juicefs-03-8-async-backup` | `1f60618c44fda1c19fecd75d52e053e9` | 03-8/03-10 用的旧补丁 | 仅备查 |

⇒ 必须建 shim：`mkdir -p /tmp/t52-bin && ln -sf /tmp/juicefs-03-8 /tmp/t52-bin/juicefs && export PATH=/tmp/t52-bin:$PATH`，并把 `command -v juicefs`、`readlink -f`、`juicefs version`、`md5sum` 四行写进日志。

### 二.2 ⚠ 陷阱二：`--max-fuse-io 256K` 必加，且必须验生效

- 本次**两臂都带** `--max-fuse-io 256K`（这是交付配置，也是 03-10 的口径 —— 03-17e 把它去掉是任务书的错，见 A37）。
- 挂载参数（两臂逐字符相同）：`JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"`
- **每次挂载后**立即执行 `grep -H max_read /proc/mounts` 并落盘 `mount-verify-<label>.txt`，必须含 **`max_read=262144`**；缺失 ⇒ STOP（§七 S3）。

### 二.3 ⚠ 陷阱三：`de93563f` 从未在 256K FUSE 下测过写（本次最大风险）

- 03-7L 实测：`--max-fuse-io 256K` 下 randwrite 崩塌至 **551 MiB/s**（5.8×，14 轮稳定、极差 0.2%）；03-8 的 FlushTo 竞态补丁修复后落回 **[2942, 3258]** 平台。
- 但 03-8 的 ABBA 验证是在**旧二进制 `1f60618c`** 上做的；`de93563f` 只在**读侧**（03-17b/c/d）和**128K FUSE 写侧**（03-17e Seg B）跑过 ⇒ **该补丁在本二进制中是否仍在，无证据**。
- ⇒ **Gate 0 必须先跑**（§五 步 1）：randwrite 1 轮，`< 2942` ⇒ **立即 STOP**，不要继续任何写项。

### 二.4 ⚠ 陷阱四：V4 的参数与重挂行为

- `RUNTIME`/`REPEAT` **只认位置参数**（`$2`/`$3`），环境变量被静默忽略 ⇒ 必须写成 `<LABEL> 180 1`。
- **V4 只在每次调用开始时 remount 一次**（03-17e 实测：`SKIP_REMOUNT=0` 下 21 个 run 共用 pid=2319972，B4-20）⇒ **要拿到 3 次独立挂载抽签，必须调用 V4 三次，每次 `REPEAT=1`**（本任务书的核心修正之一）。
- 可环境覆盖：`ITEMS` / `OBJ_GATE` / `OBJ_TARGET` / `OBJ_MAX` / `JUICEFS_MOUNT_OPTS`。
- ⛔ 不加 `--layout`（layout 文件已存在；V4 在 `:1318-1320` 有硬门禁，缺文件会自己退出）。

---

## 三、两臂定义与执行矩阵

| 臂 | 私有 conf | 挂载参数 | 项 | 轮 |
|---|---|---|---|---|
| **A｜DELIVER（主）** | `ms_async_op_threads=8` | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` | 七项全 | 3（= 3 次独立挂载） |
| **B｜REF10（锚点）** | `ms_async_op_threads=3`（系统默认值，仍走私有 conf 显式写死） | 同上，**逐字符相同** | `randread` `randwrite` | 3（= 3 次独立挂载） |

- 两臂**唯一差异 = `ms_async_op_threads`**。B 臂同时是 03-10 口径的锚点（除二进制外与 03-10 一致）。
- 私有 conf 生成方式（两份，⛔ 不动系统 conf）：
  ```
  mkdir -p /tmp/t52-conf
  for n in 8 3; do cp /etc/ceph/ceph.conf /tmp/t52-conf/ceph-msgr$n.conf
    printf '\tms_async_op_threads = %s\n' $n >> /tmp/t52-conf/ceph-msgr$n.conf; done
  ```
  运行时 `export CEPH_CONF=/tmp/t52-conf/ceph-msgr8.conf`（或 `-msgr3`）。
- **ABBA 交替顺序**（消时序混淆，R16⑤）：见 §五 步 2 的调用序列。

---

## 四、哨兵（B4-18/B4-19 修正版，必须重写）

`scripts/FULLBASELINE/debug/t52-sentinel.sh`，与每次 V4 调用同起同落：

1. **按挂载 pid 定位**，⛔ 不用 `pgrep | head -1`：从 `mount | grep ' /mnt/juicefs '` 取挂载点，再用 `pgrep -f "juicefs-03-8 mount"` 交叉核对，取**启动时间最新**的那个 pid，并把 pid 与 `starttime` 写进日志首行；与 V4 日志里 `挂载实例: pid=` 一行**必须一致**，不一致 ⇒ STOP。
2. 每 5 s 采一次：`msgr_workers` = `/proc/<pid>/task/*/comm` 中前缀 `msgr-worker` 的**计数**；同时落 `utime+stime`（供 opencode 算 F63 active-only CV）。
3. 输出文件**每次调用独立命名**：`/tmp/t52-sentinel/<LABEL>-r<N>-threads.tsv`（03-17e 的哨兵因同路径覆盖丢了整段 NB8 数据，B4-18）。
4. 🔴 **零值/错值即 STOP**：连续 2 次采样 `msgr_workers` 为 **0** 或 **≠ 该臂期望值**（A 臂 8 / B 臂 3）⇒ 杀掉本轮、写 `STOP.txt`、终止全流程（03-17e 是 86 条 `!= 3` 只写日志照跑完 4 h，B4-19）。
   - 例外：挂载后 30 s 内允许为 0（线程惰性创建），该窗口内不计。

---

## 五、执行顺序（步 0 起连跑到底）

**步 0｜环境自检**（全部落 `env-check.txt`）：`ceph health`（须 HEALTH_OK）、`ceph osd stat`（须 6 up/in）、根分区余量（须 ≥15G）、系统 ceph.conf md5、shim 四行、两份私有 conf 的 md5、`fio --version`（3.28）、当前对象数 `rados df` 或 `ceph df` 原文。

**步 1｜Gate 0：补丁风险门**（~25 min）
```
export CEPH_CONF=/tmp/t52-conf/ceph-msgr8.conf
JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K" \
ITEMS="randwrite" OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 \
bash /tmp/FULLBASELINE_V4.sh GATE0 180 1 --remount
```
判据：`randwrite` BW **≥ 2942** ⇒ 继续；**< 2942** ⇒ 🔴 **STOP（S1）**，回传后等分析方。⚑ Gate0 的这一轮**同时计入 A 臂 randwrite 的第 1 次抽签**（label 保留 `GATE0`，分析方按同配置合并）。

**步 2｜主体：ABBA 交替，每次调用 = 1 次独立挂载**（共 3+3+3+3=… 见序列）

调用序列（严格按此顺序，`export CEPH_CONF` 随臂切换）：
```
A-r1 :  ITEMS=全七项            LABEL=A1  180 1
B-r1 :  ITEMS="randread randwrite"  LABEL=B1  180 1
B-r2 :  ITEMS="randread randwrite"  LABEL=B2  180 1
A-r2 :  ITEMS=全七项            LABEL=A2  180 1
A-r3 :  ITEMS=全七项            LABEL=A3  180 1
B-r3 :  ITEMS="randread randwrite"  LABEL=B3  180 1
```
- 全七项写法：`ITEMS="seqread mseqread randread randrw seqwrite mseqwrite randwrite"`
- 每次调用统一带：`OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000`、`JUICEFS_MOUNT_OPTS` 同 §二.2、位置参数 `180 1`、`--remount`。
- 每次调用**前**启哨兵、**后**停哨兵；每次挂载后立即做 §二.2 的 `max_read` 验证。
- 时长预估：A 臂每轮 ≈ 55~65 min（4 个写项各含 `aggressive_cleanup` 8~12 min），B 臂每轮 ≈ 25 min ⇒ **合计约 4.5~5.5 h**，夜间跑。

**步 3｜收尾**：卸载所有 juicefs 挂载（`juicefs umount --flush`，优雅）、再记一次系统 ceph.conf md5 与对象数、打包回传（§六）。

---

## 六、回传物（B4-21 修正：03-17e Seg B 只回传了日志，17 KB）

`opencode-t3.17f.tar.gz`，**必须包含**：
1. `/tmp/opencode-fullbaseline-v4/` **整目录**（含每个 run 的子目录、`fio.txt` 原文、`rounds.tsv`、`hit-rate.txt`、`nic.txt`、`obj-gate-*.tsv`、`guard-*`）；
2. `/tmp/t52-sentinel/` 全部 `*-threads.tsv` 与 `STOP.txt`（若有）；
3. 每次调用的 stdout 全量日志 `a1.log`/`b1.log`/…；
4. `env-check.txt`、`mount-verify-*.txt`、两份私有 conf、`ceph.conf.system-{before,after}`；
5. `MANIFEST.md5`（对包内每个文件逐一 md5）+ 包自身 md5。

放 `/tmp/production/`，并 `scp` 回 WSL `/home/lilingfeng/tmp/production/`。⛔ 不要删 157 上的原始目录。

---

## 七、STOP 条件（穷举；只有这些才停机）

| # | 条件 | 动作 |
|---|---|---|
| S1 | Gate 0 的 randwrite < 2942 MiB/s | 停全流程，回传，等分析方 |
| S2 | 哨兵 `msgr_workers` 连续 2 次为 0 或 ≠ 期望值（挂载后 30 s 窗口除外） | 停全流程 |
| S3 | `/proc/mounts` 缺 `max_read=262144` | 停全流程 |
| S4 | 哨兵 pid 与 V4 日志 `挂载实例: pid=` 不一致 | 停全流程 |
| S5 | `ceph health` 非 HEALTH_OK，且**不是**唯一的 clock skew 且 ≤0.5 s | 停；⛔ 禁 `ceph config set mon mon_clock_drift_allowed` |
| S6 | OSD up/in ≠ 6，或 PG 出现非 `active+clean` 且 60 s 内未恢复 | 停 |
| S7 | 对象数 > `OBJ_MAX=8000000` | 停 |
| S8 | 系统 `/etc/ceph/ceph.conf` md5 与 `5b6be341…` 不符 | 停 |
| S9 | 根分区余量 < 8G | 停 |
| S10 | V4 返回 rc≠0，或 `rounds.tsv` 出现 `INVALID`/`PG_UNSTABLE` | 停 |
| S11 | 二进制自检不符（`de93563f…` / version 末尾 `a`） | 停 |
| S12 | 出现非优雅卸载（V4 `GUARD` 报错） | 停 |

**明确"不 STOP"的情况**（记录并续跑）：L2 极差超 5%；某项 BW 低于历史；`hit_rate` 偏高；唯一告警且为 clock skew ≤0.5 s；对象数下跌 ≤1000；单个 cell 的 active-only CV 偏离批内其他 cell（判档只做协变量记录，R18）。

---

## 八、分析方（opencode）拿到数据后要做的判决

1. 七项 × 3 次独立挂载 ⇒ 逐项 median、L2 极差、跨挂载散布；**能否固化交付配置基线**（并回填主计划 §2.4d 与 `REFERENCE-VALUES.md`）。
2. A/B 同项之比 ⇒ msgr 效应第三次独立估计（与 +44.3% / +46.8% 合表；写侧首次有值）。
3. 与 03-17e 的 (128K,8)=2591 / (128K,3)=1179 合成四格表 ⇒ 判 **A36 硬伤①② vs 真交互**（§一 #3）。
4. Gate 0 结果 ⇒ 立结论：`de93563f` 在 256K FUSE 下写侧安全性（若 PASS，补上 03-8 补丁在新二进制上的验证缺口 B5 的一半）。
5. 逐项 `hit_rate` 记录（03-17e 实测 seqread/mseqread 达 85~100% buffer 命中）⇒ 判断哪些项其实没在测存储路径，供下阶段口径修订。
