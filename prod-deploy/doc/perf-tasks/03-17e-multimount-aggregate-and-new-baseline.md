# 03-17e 多挂载聚合验 F51 + 新配置全量七项基线

> **计划线**：03-16（读侧约束 = per-mount）→ 03-17（原设计作废）→ 03-17b（档位根因 = msgr-worker 连接落位抽签）→ 03-17c（msgr 扫描，F58 有效 worker = OSD 数 6）→ 03-17d（并发扫描，F61 单挂载渐近上限 ≈6280、F62 PG 倾斜）→ **03-17e（本任务：① 判 6280 是单挂载墙还是机器级墙，给 F51 定性收尾；② 用当前推荐配置跑一次全量七项，决定能否固化为新基线）** → 写侧 B1（主线）。
>
> **本任务是读侧最后一次机器时间**。跑完读侧封板，主线转写侧。

---

## 〇、执行方纪律（本次与前几次最大的不同）

1. ⛔ **全程不得向分析方/用户提问**。任务书没写到的情况，按 §八 的兜底规则处理；兜底规则也没覆盖的，**记录 + 续跑**，不要停下来等指示。
2. **只有 §八 列举的 STOP 条件才停机**。其余一切异常（判档值异常、某轮带宽偏低、活跃 worker 数不是 6、时钟告警 ≤0.5 s、后台 GC 使对象数下跌 ≤1000）**一律写进日志继续跑**。
3. **进度播报**：每完成一个 cell 报一行机械状态（`cell 名 / 结束时间 / rounds.tsv 最后一行原文`），⛔ 不报平均值、不报百分比、不做"这轮好/坏""说明什么"之类的解读。分析方会从原始数据重算（历史上执行方统计出过错，这是硬规矩）。
4. **两段之间不要等确认**：Seg A 打包完成后**直接开始 Seg B**。
5. ⛔ **不改 `FULLBASELINE_V4.sh`**（Seg B 全靠环境变量 + PATH 注入驱动，见 §五）；⛔ 不改 `t39-nsbgate.sh`；⛔ 不改 `/etc/ceph/ceph.conf`；⛔ 不执行 `ceph config set`；⛔ 不动 TiKV。

---

## 一、目标与判决规则

### Seg A —— 多挂载聚合（判 F51）

| 观测结果（D128 两挂载 fio bw 之和） | 判决 |
|---|---|
| ≥ **6600** MiB/s | 6280 是**单挂载墙**，机器/集群还有余量 ⇒ 读侧重开，转"多挂载/多实例架构"评估 |
| **6250 ~ 6550** | F51 与 F61 是**同一道机器级墙** ⇒ 读侧收口结论成立，且给出"多挂载也只能贴到目标线"的定量证据 |
| ≈ **5500**（与单挂载 J128 无差） | 墙在集群/OSD 侧且与挂载数无关 ⇒ 收口结论加强，余量只剩 F62 的 PG 均衡 |

### Seg B —— 新配置全量七项

- 目的：拿当前推荐配置（**03-8 补丁二进制 + `ms_async_op_threads=8`**）跑一次与历史 E6 / 03-10 **同口径**的七项，供"是否固化为新基线"决策。
  - 🔴 **2026-08-21 订正**：本段目的表述有误 —— E6（128K 基座）与 03-10（**带 `--max-fuse-io 256K`**）本就不是同一口径，无法用一个臂同时对齐；且"推荐配置"按主计划 §2.4d 是**含 `--max-fuse-io 256K`** 的。详见 §五 订正块，重做见 **03-17f**。
- ⛔ **不做增益归因**：Seg B 是批次级单臂快照，msgr 收益的正式口径以 **03-17d 拉丁方**为准（J64→J128 +10.4%、msgr 相关结论见 F58）。Seg B 的 msgr=3 对照（`NB3`）只作**方向性复核**，⛔ 不得据此报增益百分比。
- 七项验收线：每项有效数据带宽 **6250 MiB/s**（= 网卡带宽一半）；**randrw 读/写分向验收，⛔ 禁两向相加**。

---

## 二、环境与前置事实（已由分析方查证，执行方只需复验）

| 项 | 值 |
|---|---|
| 客户端 | 157（`ssh thailand`），**128 逻辑 CPU**（0-127；SSH 会话亲和掩码为 `0,17-64,81-127`，属正常） |
| 二进制 | `/tmp/juicefs-03-8`，md5 **`de93563f11a5ff3bd94dd25a4e0283b1`**，`version` 输出须含 **`1.3.1+2025-12-02.e0032b2a`**（末尾有 `a`） |
| ⚠ 陷阱 | `/usr/local/bin/juicefs` 是**另一个构建**（md5 `bdd182cf2cd43be657cb4ec0b5a6a048`，version `…e0032b2`，**无末尾 a**）。V4 脚本里调用的是裸 `juicefs` ⇒ **不做 PATH 注入就会测错二进制**，见 §五 |
| 元数据 | `tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod` |
| 卷设置 | `BlockSize=256`（KiB）、`Compression=none`、`TrashDays=0`、`Storage=ceph`、`Bucket=ceph://juicefs-data` |
| 池状态 | 6 OSD、EC 4+2、33 PG；对象数起点 **2,434,618**（Seg A 前复验）；`AvailableSpace` ≈1.13 PB |
| fio | 3.28 |
| ceph.conf | `/etc/ceph/ceph.conf` md5 **`5b6be34179a64e0a5f9c6d3a9690041f`**，全机共用，⛔ 只读 |
| 参数注入 | 进程私有 conf + `CEPH_CONF`（F53）；⛔ 不改系统 conf |
| 常态负载 | load ≈24（`uptime` 显示 23~24 属常态，不是异常） |
| 根分区 | 余量约 20 G（Seg B 的 `--cache-size 0`，不落本地缓存） |

---

## 三、Seg A 脚本要求（`scripts/FULLBASELINE/debug/t50-multimount-aggregate.sh`）

**以 `t49-read-concurrency-sweep.sh`（md5 `2cf5cd4479e96b6667c4a1ec1f1d9e76`）为模板复制修改**，⛔ 不要重写框架，必须继承 t49 已修的全部缺陷修复：`mount_pid()` 取实例进程（B4-8）、背景监控清点剔除自身进程树（B4-9）、取消 ns/B 与 B 停机门槛（B4-11/12）、`MANIFEST.md5` 相对路径（B4-15）、`RUNTIME`/`GAP` 用 `${VAR:-默认}` 不硬赋值（B4-16）。

### 3.1 臂设计（3 臂 × 3 轮 = 9 个 cell，拉丁方轮转）

| 臂 | P（`/mnt/juicefs-p`，读 `read_test.*.0`） | Q（`/mnt/juicefs-q`，读 `rw_test.*.0`） | 作用 |
|---|---|---|---|
| **S128** | randread numjobs=128 | 不挂 | 批次锚点，对齐 03-17d J128 = **5516.7**（±25% 外才 STOP） |
| **D64** | randread numjobs=64 | randread numjobs=64 | 聚合 128 流 |
| **D128** | randread numjobs=128 | randread numjobs=128 | 聚合 256 流，**F51 主判 cell** |

- 每个 cell **独立挂载**（每次重新抽签，F58）；D 臂用 `&` 同时启动 P/Q，`wait` 等两个都结束。
- 轮内三臂顺序按拉丁方轮转（r1: S128→D64→D128；r2: D64→D128→S128；r3: D128→S128→D64）——⚑ **R16⑤ 强制要求**，禁跨轮臂均值直接相减。
- fio 形状与 t49 **逐字符相同**（`randread` / `bs=256k` / `iodepth=128` / `direct=1` / `libaio` / `--readonly` / `runtime=${RUNTIME:-180}` / `filesize=size=1G` / `openfiles=numjobs`），挂载参数也与 t49 相同（`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`），否则与 5516.7 锚点不可比。
- `GAP=${GAP:-20}` 秒。

### 3.2 判档标定 cell（新增，落实 F63/R18）

每轮**额外**跑 1 个 cell：`CAL3` = 单挂载 P、**msgr=3（系统默认，不注入私有 conf）**、numjobs=128、runtime 180 s。
- 作用一：给 F63 的 active-only CV 阈值在本机当前状态下重新标定（msgr=3 是唯一已知能产生坏档的配置）。
- 作用二：同批次给出 msgr=3 → msgr=8 的方向性复核。
- ⚑ **只记录，不据此重挂、不据此剔除任何 cell**（R18）。

### 3.3 每个 cell 必须采集

1. `fio` 完整 stdout 落盘（含 `bw`、`clat` 分位）+ `--write_bw_log` 到 `bwlog/`。
2. **判档协变量（F63）**：fio 开始后每 **5 s** 采一次 `/proc/<io_pid>/task/*/stat` → `threads-series.tsv`（列：`ts tid comm utime stime processor`），并同时落 `threads-pre.tsv` / `threads-post.tsv`。⚑ 必须取**工作子进程**（`mount_pid()`），⛔ 不要取守护父进程（02 阶段 14 个脚本栽在这里：父进程 34 线程里没有 msgr-worker）。
3. **线程数闸门**：挂载后数 `msgr-worker` 线程数，S128/D64/D128 必须 **=8**、`CAL3` 必须 **=3**，不符立即 STOP（说明 `CEPH_CONF` 注入没生效，⛔ 不许自行改注入方式后继续）。同时记 `io_context_pool` 线程数（预期 2）。
4. `i1-<cell>.tsv`：JuiceFS 侧 stats（对象 GET 数/在飞 GET/`fuse_open_handlers`/`fuse_ops_total_read`/读缓冲区），采样间隔与 t49 相同。**D 臂 P 和 Q 各采一份**。
5. `net.tsv`：公网口 `enp139s0f0np0` 收发字节。
6. `osd/`：每个 cell 前后各一次 6 台 OSD 的 `ceph tell osd.N perf dump`（差分口径，供 F62 倾斜度复算）。
7. `objects-pre/post`：对象数（只读，单向闸门见 §八）。
8. `arm-covariates.tsv`：`cell / arm / round / 位次 / msgr_threads / jobs_P / jobs_Q / bw_P / bw_Q / bw_sum / ns_per_B_P / ns_per_B_Q / active_worker_n / active_only_cv_pct / max_worker_pct_core / msgr_sum_core`。
   - ⚑ `active_only_cv_pct` = **只统计 CPU > 2% 单核的 worker** 的 CV（A33：把 0% 空闲 worker 计入分母会恒得 ≈59%，完全不判别）。
   - ⚑ `ns_per_B` 按各自负载记录即可，**⛔ 不要与 `REF_NSB=3.287` 比较**（B4-17：ns/B 是按 numjobs 归一的量 = `numjobs/bw`，跨 numjobs 不可比）。

### 3.4 时长

9 个主 cell + 3 个 CAL3 = 12 × (180 s + 20 s gap + 挂卸载/采样开销 ≈60 s) ≈ **约 55 min**，加冒烟与打包约 **1.2 h**。

---

## 四、Seg A 冒烟（正式跑前必做，⛔ 不可跳）

`RUNTIME=30 GAP=5 ROUNDS=1` 跑一遍全部 4 种 cell（S128/D64/D128/CAL3），确认：
1. `RUNTIME=30` 真的生效（B4-16 回归检查：日志里 fio 的 `runtime` 必须是 30，不是 180）。
2. 线程数闸门在 msgr=8 与 msgr=3 两种情形下都读到正确值。
3. `threads-series.tsv` 里有 `msgr-worker-*` 行且 `utime+stime` 随时间单调增（若全为 0，说明取错进程 ⇒ STOP）。
4. D 臂 P/Q 两个 fio 真的**同时**在跑（日志里两个 start 时间差 <5 s）。
5. 打包 + `MANIFEST.md5` 自校验通过。

冒烟产物单独归档为 `*-smoke`，⛔ 不混入正式矩阵目录。

---

## 五、Seg B 执行方式（⛔ 不改 V4，全靠外部注入）

写一个**只做环境准备**的 wrapper：`scripts/FULLBASELINE/debug/t51-newconfig-baseline-wrapper.sh`。它必须做且只做这些事：

1. **PATH 注入正确的二进制**：
   ```
   mkdir -p /tmp/t51-bin && ln -sf /tmp/juicefs-03-8 /tmp/t51-bin/juicefs
   export PATH=/tmp/t51-bin:$PATH
   ```
   随后**验证**：`command -v juicefs` 指向 `/tmp/t51-bin/juicefs`，且 `juicefs version` 输出含 `e0032b2a`（有末尾 a），`md5sum $(readlink -f $(command -v juicefs))` = `de93563f11a5ff3bd94dd25a4e0283b1`。不符 ⇒ STOP。
2. **私有 conf 注入 msgr=8**（仅 `NB8` 跑）：
   ```
   cp /etc/ceph/ceph.conf /tmp/t51-conf/ceph-msgr8.conf
   printf '\n[client]\n\tms_async_op_threads = 8\n' >> /tmp/t51-conf/ceph-msgr8.conf
   export CEPH_CONF=/tmp/t51-conf/ceph-msgr8.conf
   ```
   `NB3` 对照跑**不设 `CEPH_CONF`**（系统默认 = 3）。
3. **旁路线程哨兵**（V4 自己不验线程数，必须补）：wrapper 起一个后台采样进程，每 30 s 记录 `/mnt/juicefs` 工作子进程的 `msgr-worker` 线程数与逐线程 CPU 到 `/tmp/t51-sentinel/threads-series.tsv`。
   - `NB8` 跑期间若出现 `msgr-worker` 数 ≠ 8 ⇒ **STOP**（注入失效，数据作废）。
   - `NB3` 跑期间须恒为 3。
   - 该文件同时给分析方算 F63 的 active-only CV。
4. **起止两次记录 `/etc/ceph/ceph.conf` 的 md5**，不一致 ⇒ STOP。
5. 调用 V4（⛔ 原样，不加参数以外的任何改动）：

| 跑次 | 命令 | 说明 |
|---|---|---|
| 预检 | `bash FULLBASELINE_V4.sh dry-run` | 只验环境，不产数据 |
| **NB8（主）** | `OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 bash FULLBASELINE_V4.sh NB8 180 3 --remount` | 七项 × 3 轮，msgr=8 |
| **NB3（对照）** | `ITEMS="randread randrw" OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 bash FULLBASELINE_V4.sh NB3 180 3 --remount` | 只 2 项 × 3 轮，msgr=3 |

- ⚠ V4 的 `RUNTIME`/`REPEAT` **只认位置参数**（`$2`/`$3`），环境变量会被忽略（B4-16 同族）⇒ 必须写成 `NB8 180 3`。
- ⚠ ~~`JUICEFS_MOUNT_OPTS` **保持 V4 默认**（`--max-uploads 150 --cache-size 0`），⛔ **不要加 `--max-fuse-io 256K`** —— Seg B 的唯一意义是与历史 E6/03-10 同口径可比，本次相对 03-10 的差异必须只有"二进制 + msgr=8"两项。~~（Seg A 反之必须带 `--max-fuse-io 256K` 以对齐 03-17d ⇒ **Seg A 与 Seg B 的绝对值 ⛔ 不得同表比较**。）
  - 🔴 **2026-08-21 订正（opencode 自查，本条是任务书的错，非执行方的错）**：上面这条指令**基于两个错误**：
    1. **事实错误**：**03-10 是带 `--max-fuse-io 256K` 跑的**（`doc/perf-tasks/03-10-…md:42`：`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`，并要求验 `max_read=262144`；主计划 §2.4d 亦把"生产候选基座"定义为 `--max-fuse-io 256K --max-uploads 150 --cache-size 0`）。只有 **E6** 是 128K 出厂基座（且卷 BlockSize 也是 128K）。把"E6/03-10"并列成同一口径是错的，去掉 `--max-fuse-io 256K` 后既不等于 03-10、也不等于 E6。
    2. **设计错误**：本段目标是固化**交付配置**（= 补丁二进制 + msgr=8 + `--max-fuse-io 256K`），与历史的可比性应当靠**增加一个历史口径臂**解决，⛔ 不应把主臂降级成历史口径。等于把"同口径可比"和"固化交付配置"两个目标压进单臂设计，并选错了臂。
    3. **后果已实测**：Seg B randread 2591 仅为 Seg A 同 fio 规格的 **46.1%**，差值 **+117.0%** 与 03-6 实测的 `--max-fuse-io 256K` 收益 **+115.6%** 只差 1.4 pp ⇒ Seg B 实际测的是"128K FUSE 口径"，不是交付配置 ⇒ 该段不能用于固化新基线（A36）。
    4. **正确做法见 03-17f**：主臂带 `--max-fuse-io 256K`，另设 03-10 口径锚点臂，ABBA 交替、每臂 ≥3 次独立挂载。
- 若 `dry-run` 报 layout 文件缺失：**加 `--layout` 重建一次**后再跑正式，并在日志里明确记录（分析方需要知道数据集被重建过）。

### 5.1 Seg B 时长预估

读项 3 项 × 3 轮 × ~4 min ≈ 36 min；写项 4 项 × 3 轮 × (180 s fio + `aggressive_cleanup` 含两次 `compact_cooldown` + `gc --compact`，约 8~12 min) ≈ **2.5~3 h**；NB3 对照 ≈ 40 min。**Seg B 合计约 3.5~4 h**，Seg A + Seg B **约 5~5.5 h** ⇒ 夜间跑。

---

## 六、执行顺序与时间窗

| 步 | 内容 | 何时 |
|---|---|---|
| 0 | 环境复验（§二 全表 + `ceph -s` HEALTH + load + 对象数 + fio 版本 + 磁盘余量） | 白天 |
| 1 | Seg A 冒烟（§四） | 白天 |
| 2 | **Seg A 正式矩阵**（12 cell，约 55 min） | 白天亦可 |
| 3 | Seg A 打包 + `MANIFEST.md5` 自校验 + 回传 | 紧接步 2 |
| 4 | Seg B `dry-run` + wrapper 自检（PATH/CEPH_CONF/哨兵） | 傍晚 |
| 5 | **Seg B NB8**（七项 × 3 轮） | **夜间**，⛔ 不与任何其他压测并行 |
| 6 | **Seg B NB3**（2 项 × 3 轮） | 紧接步 5 |
| 7 | Seg B 打包 + 自校验 + 回传 | 紧接步 6 |

⚑ 步 3 完成后**不要等确认**，直接进步 4。

---

## 七、对象数闸门（两段不同口径，⛔ 不要混用）

| 段 | 性质 | 闸门 |
|---|---|---|
| **Seg A** | 纯只读 | 起点 ≤ **3,110,000**；**单向闸门**：上涨任意幅度 ⇒ STOP；下跌 ≤ `OBJ_SHRINK_MAX=1000`（后台 GC/trash）⇒ 记录续跑；下跌 >1000 ⇒ STOP；不可解析 ⇒ STOP。⛔ 禁用 `UsedSpace`/`UsedInodes` 替代对象数 |
| **Seg B** | 含 4 个写项，对象数**必然增长** | 用 V4 自带 `obj_gate`：`OBJ_TARGET=2500000`（每个写项后 `gc --compact` 排空回起点）、`OBJ_MAX=8000000`。⚑ Seg A 的 3,110,000 单向闸门**不适用于 Seg B** |

> ⚑ **Seg B 的 `OBJ_MAX=8000000` / `OBJ_TARGET=2500000` 已于 2026-08-21 获用户授权**（= V4 历史默认，03-10 等历史全量跑即用此值）。
> 事实依据：`BlockSize=256 KiB`、`TrashDays=0`；单个 `mseqwrite` 180 s 在 ~4700 MiB/s 下写 ≈826 GiB，落在 16×4 G = 64 GiB 的文件区上反复覆盖 ⇒ **覆盖产生的旧切片在 `gc --compact` 之前会以垃圾对象形式累积，run 内峰值可达数百万**，而 V4 的 `obj_gate` 只在**每个写项结束后**检查（轮内看门狗仍是 B7 缺口）。容量不是约束（8,000,000 × 256 KiB ≈ 2 TiB，池可用 ≈1.13 PB）。
> ⚑ 因 B7（轮内看门狗）仍缺，执行方必须在每个写项**结束后**把 `objects` 值原样写进日志（V4 的 `obj-gate-*.tsv` 已覆盖），供分析方复算峰值轨迹。

---

## 八、STOP 条件（穷举；不在此列的一律记录续跑）

1. `ceph -s` 非 `HEALTH_OK`，且告警不是"唯一一条 clock skew 且 ≤0.5 s"。（clock skew ≤0.5 s ⇒ 记录续跑；⛔ 禁执行 `ceph config set mon mon_clock_drift_allowed`）
2. `/etc/ceph/ceph.conf` md5 与起始值不一致。
3. `msgr-worker` 线程数 ≠ 期望值（Seg A：S128/D64/D128 = 8、CAL3 = 3；Seg B：NB8 = 8、NB3 = 3）。
4. Seg B 的二进制自检不通过（`command -v juicefs` 不在 `/tmp/t51-bin`、version 无末尾 `a`、或 md5 ≠ `de93563f…`）。
5. 对象数闸门触发（Seg A 见 §七 单向规则；Seg B 超 `OBJ_MAX`）。
6. 挂载失败连续 3 次（每次之间做完整清理）。
7. 实例漂移：cell 期间 `mount_pid`/进程 start time 变化。
8. 数据集不完整：P 侧 `read_test.*.0` ≠ 128、Q 侧 `rw_test.*.0` ≠ 128、`mseqread.*.0` ≠ 16。
9. `threads-series.tsv` 里 `msgr-worker` 的 `utime+stime` 全程为 0（取错进程）。
10. fio 非零退出或 `bw` 无法解析。
11. OSD 数 ≠ 6 或有 OSD 非 `up`。
12. 磁盘余量 <5 G。
13. Seg A 锚点臂 S128 三轮均值偏离 **5516.7** 超过 **±25%**（±10% 只打 `NOTE` 续跑）。
14. Seg B 写项后 `objects` > `OBJ_MAX=8000000`，或 `gc --compact` 连续 `OBJ_GC_PASSES` 遍后仍 > `OBJ_TARGET=2500000`（V4 自带逻辑，照其原样停机即可）。

⛔ **不在 STOP 里的**（明确列出以免执行方自行加码）：判档 CV 偏高、活跃 worker 数不是 6、某轮带宽偏低、`ns/B` 偏离 3.287（B4-17：本来就不可比）、`verdict=FAIL`（判档器仅用于取数，`NSB_TOL=100000` 使其恒 PASS）、轮间漂移（F55 已知 −2.7%/轮）。

---

## 九、回传物

| 段 | 打包名 | 内容 |
|---|---|---|
| Seg A | `opencode-t3.17e-segA.tar.gz` + `.md5` | 12 个 cell 目录（fio/i1/threads-{pre,post,series}/net/osd/objects）、`arm-covariates.tsv`、`rounds.tsv`、`bwlog/`、`conf/`（私有 conf + 系统 conf 起止 md5）、`MANIFEST.md5`、主日志 |
| Seg B | `opencode-t3.17e-segB.tar.gz` + `.md5` | `/tmp/opencode-fullbaseline-v4` 全量（NB8 + NB3）、`obj-gate-*.tsv`、`/tmp/t51-sentinel/`、wrapper 日志、`dry-run` 输出、`MANIFEST.md5` |

- `MANIFEST.md5` 用**相对路径**（B4-15），执行方须自校验一次全 OK 再回传。
- 回传报文只写机械信息：包名、md5、文件数、`MANIFEST` 校验结果、起止时间、有无 STOP、`rounds.tsv` 行数。⛔ 不写数值分析。
- `ALL DONE` 只能在**打包完成之后**打印。

---

## 十、分析方（opencode）拿到数据后要判的四件事

1. **F51 定性**：按 §一 判决表给 D128 聚合定档；顺带算 D64 vs S128 的"两挂载各半 vs 单挂载全量"对照。
2. **F63 阈值标定**：用 3 个 `CAL3` cell 的 active-only CV 分布 + 9 个 msgr=8 cell 的分布，给出**msgr=8 下的批内离群判据**（现状只有 msgr=3 的 5.9–10.6% / 33.9–41.9% 标定值，msgr=8 下无坏档样本）。
3. **新基线能否固化**：七项逐项与 E6（randread 1880 / mseqread 4160 / randrw 1215 / seqread 1290 / seqwrite 1400 / mseqwrite 4800 / randwrite ≈2860）及 03-10（mseqwrite 4699 / mseqread 3983 / randread 3831 / randwrite 3018 / randrw 读 1890.5 写 1891.0 / seqwrite 1681 / seqread 1457）逐项对比，**标明跨批次可复现性 ±3%**；任何一项显著低于历史 ⇒ 先查因，不固化。
4. **F62 复核**：用 Seg A 的 OSD perf dump 差分复算 6 台 OSD 的 `op_r/s` 倾斜度，确认 `max/mean ≈1.13` 在多挂载下是否仍然成立。
