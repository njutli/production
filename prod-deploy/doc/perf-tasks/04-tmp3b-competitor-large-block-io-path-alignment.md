# 04-tmp3b 任务书：竞品大块顺序 I/O 路径对齐验证

## 状态与最小执行合同

| 字段 | 冻结值 |
|---|---|
| 日期/实验号 | 2026-09-04 / `TMP-H3C-BIGSEQ2`（不占正式 04-N） |
| 当前状态 | `COMPLETED_L1 / RA8_ASYNC_OFF_RETAINED / BLOCK4_READ_NO_SIGNAL / BLOCKSIZE_WRITE_INVALID_PERSISTENCE_GATE / ENVIRONMENT_CLOSED` |
| 证据等级 | `L1_SCREEN`；本任务只筛选机制和候选，不直接改生产交付配置 |
| 前置证据 | 04-tmp3 RUN `20260904-095827`；读侧可作 L1 起点，写侧因卸载时 `ceph_assert + SIGABRT` 不作为持久写结论 |
| 唯一权威证据根 | `/mnt/c/SunRise/test/04-tmp3b/<RUN_ID>/` |
| 157 临时结果根 | `/tmp/production/opencode-04tmp3b-<RUN_ID>/`，不得作为唯一副本 |
| 预计时长 | 步骤一约 1.5–2.5 小时；条件步骤二约 2–4 小时；总上限 6 小时 |
| 准备预算 | 新脚本和离线 Gate 0 合计最多 60 分钟；超时停止并简化，不继续扩框架 |
| 自动扩展 | 禁止；两步各自回答问题后立即停止 |
| 环境清理 | 证据持久化并复核后，按独立计划精确清理；不得自动 destroy |

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=04-tmp3 RUN 20260904-095827（读侧L1；写侧异常退出，不签收）
SCREEN_CONTINUE=读侧未达目标且对象机制完整，或04-tmp3写侧仍未闭环，则进步骤二；步骤二方向一致且>=10%才进后续L2候选；>43%且坏档压力测试不翻转为强L1信号
SCREEN_STOP=<5%、方向反转、对应方向达到目标、非性能硬门失败，或两步问题已经回答
FORMAL_MATRIX=NONE_IN_THIS_TASK；正向候选另立L2并至少3个合格挂载/臂
ESTIMATED_WALL_CLOCK=步骤一1.5–2.5h；条件步骤二2–4h；合计不超过6h
MINIMUM_DECISION_SET=RA镜像6 cell + async ABBA 4 cell；条件B256/B4读ABBA 4 cell、写ABBA 4 cell
STOP_AFTER_ANSWER=不加第三档block、不扩并发/缓存/七项基线、不在本RUN补样
MAX_PREP_BUDGET=60min
MAX_EXECUTION_BUDGET=6h
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp3b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=Phase V独立计划和独立授权；不得沿用证据清理授权
```

执行前必须依次阅读：`TASK-BOOK-AUTHORING-GUIDE.md`、`TEST-DATA-LIFECYCLE-POLICY.md`、
`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`、
`skills/baseline-reproduction-skill.md`（§2.2/§2.5/§3.1/§4.3）、
`skills/TESTING-GUIDE.md`（§1.3/§2.2/§3）和
`skills/test-commands-reference.md`（§8.3）。

```text
离线 Gate 0
  → 只读 inventory、当前卷指纹和所有状态变更计划
  → 步骤一：现有 256 KiB 卷只读筛选 readahead 与 async_dio
       ├─ 已达读目标，或没有剩余对象粒度信号 → 读分支停止
       └─ 仍受对象粒度约束 → 允许申请进入步骤二
  → 步骤二：两个同起点临时卷 B256/B4 做 block-size 因果对照
       ├─ 读、写分别得出答案后停止，不扩第三档
       └─ 任一硬门失败 → EVIDENCE_INVALID / HOLD，保留现场
  → 原始证据持久化 → 独立清理计划与授权 → 环境回归
```

一句话：先在当前 256 KiB 卷上确认 20 MiB 单流读是否还能从更大 readahead 或
`async_dio` 获益；若大应用 I/O 仍被 256 KiB 对象切分限制，再用两个同起点临时卷直接比较
`BlockSize=256 KiB` 与 `4 MiB`，不把“新卷/fresh”误当成 block-size 收益。

## 一、背景与要回答的问题

04-tmp3 观察到把 fio `bs` 增大后，带宽没有按 `bs` 倍数增长；应用层 I/O 仍会经过 FUSE 和
JuiceFS 对象层拆分：当前卷 `BlockSize=256 KiB`，20 MiB 读和 16 MiB 写分别可能涉及约 80 和
64 个对象。04-tmp3 的 20 MiB 读在 `--max-readahead 8M` 下出现明确 L1 信号，但没有继续验证
窗口大小，也没有验证 `async_dio`；其写侧没有闭合 client-close、drain 与重挂读回口径，且
W01/W03 卸载日志出现 `ceph_assert(initialized)` 和 `SIGABRT`，不能据此签收写路径。

本任务只回答三个问题：

1. 在现有 256 KiB 卷上，`max-readahead=8/16/32M` 是否出现方向一致的 L1 信号，`async_dio` 是否能让
   1 MiB FUSE 子请求更充分并行；
2. 在 fresh 状态、数据量、二进制、META/TiKV、Ceph pool、挂载参数和测试顺序都对齐时，
   `BlockSize=4 MiB` 相对 `256 KiB` 是否因减少对象请求而提高 20 MiB 读或 16 MiB 写；
3. 候选是否达到竞品公开口径：读 5.4 GB/s（5149.84 MiB/s）、写 3.2 GB/s
   （3051.76 MiB/s）。达到目标只表示本环境在该公开命令口径达标，不表示硬件同条件领先。

明确不做：不重跑 cp 口径、不跑七项全基线、不测 1 MiB 等第三种 format block、不调
`max-downloads/max-uploads/buffer-size`、不改 PG/CRUSH/OSD/TiKV/网络/内核、不清全局页缓存、
不建删 Ceph pool、不停止或重启业务服务。若筛出候选，随机 I/O 回归和正式 L2 另立任务。
本任务也不重新隔离“应用 fio bs 本身”的效应；它承接 04-tmp3，只检验仍未对齐的 readahead、
同步大 syscall 内部拆分路径和 format BlockSize。报告不得把结果外推成所有 bs 的普遍规律。

## 二、共同测试合同与硬门

### 2.1 固定参数与数据口径

- 二进制固定为 `/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`；执行前重新核对。
- 当前基线卷固定为 `juicefs-prod`，META 为
  `tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod`；
  开跑前冻结 UUID、完整 Setting、挂载和进程身份，任务结束再次比对。
- 共同挂载参数固定：`--max-fuse-io 1M --max-downloads 200 --max-uploads 150
  --buffer-size 300 --cache-size 0`，关闭 writeback；沿用 04-tmp3 的 RUN 私有 Ceph 配置
  `ms_async_op_threads=8`，不修改 `/etc/ceph/ceph.conf`；只有被测的 readahead/`async_dio` 可变化。
- fio 固定为单 job、同步引擎：`--ioengine=psync --iodepth=1 --direct=1 --numjobs=1`；记录
  fio 版本、完整命令、文本/JSON 输出和 1 秒 bw log。
- 读命令核心参数：`--rw=read --bs=20M --size=10G --runtime=60 --time_based`。
- 写命令核心参数：`--rw=write --bs=16M --size=10G --runtime=120 --time_based`。
- 不使用 drop_caches。`direct=1` 只绕过客户端页缓存，Ceph/BlueStore warm effect 由平衡顺序吸收并
  如实报告；不得把它描述成绝对冷态。

### 2.2 每个 cell 的最小证据

每个 cell 只收集与判断直接相关的证据，并分成两级：

- **有效性必需**：fio 完整 stdout/JSON、逐秒 bw log、实际开始/结束时间和 rc/error；挂载命令、
  PID/starttime/exe、完整 mount 日志；157 的 CPU/RSS/thread 和 NIC 使用 1 秒时间序列覆盖至少 95%
  正式窗、最大缺口不超过 3 秒；Ceph health/PG/OSD 在每个 cell 前后作为状态硬门；参数臂、文件、
  UUID、BlockSize 和脚本 SHA256。所有采集时钟与 fio 时间线对齐；缺失即 cell 无效。
- **机制归因必需**：FUSE read/write 字节与次数、对象 GET/PUT 字节与次数/时延的正式窗增量；
  read/write buffer 使用量和上传并发用 1 秒时间序列。若现有 trace/指标能直接给出 outstanding
  FUSE/对象请求，同步保存其峰值和时间线。该组缺失时可保留 L1 fio 观察，但标记
  `MECHANISM_INCOMPLETE`；不得进入步骤二或形成 block-size 归因，也不得新增源码补丁或编造。

统计以 fio JSON 和完整 bw log 为真值，输出 mean/median/CV/P10/P50/P90、四窗趋势和 clat。
同臂两次方向不一致或锚点 spread 大于 5% 时，不得挑样，结论为 `INCONCLUSIVE`。

RA、`async_dio` 和 format BlockSize 都需要新挂载，现有 mseqread ns/B 挂载档位判别器又未证明
对这三个变量免疫，因此本任务不使用 detect-and-replace 删除观测。每臂只有两个挂载时，10%
只能记方向性 `SCREEN_SIGNAL`；报告必须把有利臂整体折减 30%做坏档压力测试，只有臂间提升超过
43%且压力测试后仍为正，才可记 `STRONG_SCREEN_SIGNAL`。其余正向结果必须另做至少 3 个合格
挂载/臂的 L2 才能签收幅度，不能在本任务宣称“调优有效”或用于生产交付。

### 2.3 非性能硬门

任一项失败立即停止当前分支，不继续下一个正式 cell：

1. 二进制、META、UUID、BlockSize、挂载 PID 或 fio 合同不匹配；
2. Ceph 非预期 WARN/ERR、PG 非 `active+clean`、发生 recovery/backfill，或 scrub 与正式窗重叠；
3. fio rc/error、有效性必需 sidecar 覆盖、文件大小或读回校验失败；
4. mount/stdout/stderr 命中 `ceph_assert|SIGABRT|SIGSEGV|panic|fatal|core dumped|Aborted`；
5. 当前卷指纹漂移，或任何命令越过本 RUN 的精确路径/META/UUID。

特别规定：挂载点消失或 umount rc=0 不等于客户端正常退出。每次卸载都必须等父子进程退出并扫描
完整日志。若复现 04-tmp3 的 assertion，标记该 cell `EVIDENCE_INVALID`、保存现场并停止，禁止在
同一正式 RUN 热修脚本后接着跑。

## 三、步骤一：现有 256 KiB 卷的读路径筛选

### 3.1 资产与边界

本步骤只读，不在当前卷新增、覆盖或删除数据。inventory 必须找到现有 FULLBASELINE 的 32 GiB
`/mnt/juicefs/test_dir/seqread/seqread.0.0`，冻结 realpath/inode/size/mtime 和固定抽样 hash；fio
只读取其前 10 GiB。找不到或指纹不符即停止，不为本步骤临时 layout。

每种挂载参数使用独立、精确 RUN_ID 挂载点，并强制使用现场已验证的 `--read-only`；从 argv/固定二进制语义确认参数，
再对起跑前不存在的 `${MNT}/.04tmp3b-ro-probe-<RUN_ID>-<CELL>` 发起一次创建并要求返回
`EROFS`、前后均不存在。JuiceFS 会在内部消费只读选项，`findmnt` 未必显示该 flag，因此只记录而
不作为硬门。禁止挂载到现有业务挂载之上，
禁止 lazy/force umount 和模式 kill。只读挂载仍会登记 mount session，因此这里的“只读”只承诺
不改文件数据，不宣称 META 完全无状态变化。

### 3.2 最小矩阵

先跑 readahead 镜像顺序：

```text
RA8 → RA16 → RA32 → RA32 → RA16 → RA8
```

其中只改变 `--max-readahead 8M/16M/32M`，其余参数完全固定。只有最佳档相对 RA8 的两次配对
增益均至少 10%时，才选“与最高有效带宽相差不超过 5% 的最小 readahead”进入下一小步；不足
10%一律回到 RA8，避免把小波动固化成工作点。

随后在所选 readahead 下跑：

```text
ASYNC_OFF → ASYNC_ON → ASYNC_ON → ASYNC_OFF
```

早期 256 KiB 小 I/O 口径下 `async_dio` 没有形成可交付收益，因此这里只针对 20 MiB 同步大
syscall 做一次有界复核；若本矩阵无至少 10%的双向一致信号，本阶段不再重试。

`ASYNC_ON` 只增加 `-o async_dio`。这里不把 `psync/iodepth=1` 变成应用 AIO，只检验一个 20 MiB
同步 syscall 被内核/FUSE 拆分后，子请求是否能出现更多重叠；因此不能把结果解释成“应用 QD
提高”。argv、固定二进制源码语义和可获得的 FUSE INIT/outstanding 证据共同用于确认，不能要求
`findmnt` 必然显示该 capability。若只能证明参数被请求、不能证明协商或请求重叠，性能结果最多是
L1 经验观察。真正的 libaio/io_uring + QD>1 已偏离竞品单流模型，不在本任务内。

### 3.3 步骤一裁决与停止

- 两次镜像观察方向一致且相对锚点增益至少 10%，对象 GET 次数/每 GiB、对象时延或 FUSE 请求
  并行证据与性能方向一致，才记方向性 `SCREEN_SIGNAL`；超过 43%并通过坏档压力测试才记
  `STRONG_SCREEN_SIGNAL`；
- 增益小于 5%：记本 RUN `SCREEN_STOP_NO_SIGNAL`并停止该参数分支，不外推成普遍无效；
  5%–10%：只记录小信号、回到 RA8，不补第三轮；
- 达到 5149.84 MiB/s 且非性能门全过：读目标已经回答，读方向不必进入步骤二；
- 未达目标，但每 GiB 仍产生与 256 KiB block 对应的大量 GET、客户端/网卡/OSD又未形成更早的
  饱和证据：记 `BLOCKSIZE_TEST_JUSTIFIED`，允许申请步骤二；
- 缺失对象层指标时，性能数字可保留为 L1 观察，但不得声称已证明对象粒度瓶颈。

## 四、步骤二：同起点 B256/B4 临时卷因果对照

### 4.1 进入条件与隔离方式

步骤二不是步骤一的自动后续。只有至少一个方向仍有未回答问题、步骤一和环境恢复门通过、两条
format 命令及后续 destroy 计划经 GPT 复核并得到用户精确授权后才可进入。

在同一 RUN 创建两个全新的 JuiceFS namespace/卷，均使用当前 TiKV endpoints、同一 Ceph
bucket/pool、同一凭据和同一二进制。除 Name、UUID 和 BlockSize 外，Compression、TrashDays、
加密及其他 format Setting 必须逐项复制当前卷；两个唯一 Name 同时提供独立 Ceph 对象前缀：

| 臂 | META namespace / 卷名后缀 | 唯一 format 差异 |
|---|---|---|
| B256 | `<RUN_ID>-b256` | `--block-size 256K` |
| B4 | `<RUN_ID>-b4` | `--block-size 4M` |

禁止 `--force`。format 后必须从 `juicefs status` 断言 B256=`256 KiB`、B4=`4096 KiB`，两者
UUID 互不相同且都不等于当前卷 UUID；Name、META、Storage、Bucket 和其余 Setting 全部与计划
一致。mount 日志还必须证明 data prefix 分别指向两个临时 Name，且均不是 `juicefs-prod`。两卷
分别使用 `/tmp/jfs-04tmp3b-mnt-<RUN_ID>-b256` 和 `...-b4`，不得复用当前挂载点。

两卷使用相同的非稀疏逻辑数据和相同准备流程；准备完成后统一 fsync、卸载/重挂、等待 Ceph
回到 quiet 锚，再冻结各自资产指纹。B256 与 B4 都是 fresh 起点，因此**只做两者同 RUN 内比较**，
不得把步骤一当前卷的绝对值直接减去步骤二结果来归因 block-size。

### 4.2 生命周期 canary

正式矩阵前，两卷各做一次小文件 `mount → write → fsync → graceful umount → remount → size/hash
verify → graceful umount`。完整 mount 日志必须不含 assertion/SIGABRT；任一卷失败即停止步骤二。
该 canary 只验证身份和基本生命周期，不声称排除“满压后卸载”缺陷；第一次正式写 cell 必须完整
通过 §4.4 的满压退出门，才允许第二个写 cell。

### 4.3 读对照

仅当读分支未在步骤一停止时执行。两卷各预置同内容 10 GiB 读文件，固定步骤一选出的
readahead/async 模式，按下列顺序跑同一条 20 MiB 读命令：

```text
B256 → B4 → B4 → B256
```

readahead 按**相同字节数**固定，而不是按 block 个数放大 B4 的窗口；因此本对照估计的是相同
客户端内存窗口下两种可部署配置的总效应。若 B4 无收益，只能否定该固定窗口配置，不能外推为
“任何 readahead 下 4 MiB block 都无收益”。

### 4.4 写对照与持久性口径

写侧固定 `async_dio=off`，只改变 format BlockSize。这样不会先用额外的 B256 async 写把某一臂
“跑旧”，也避免把 04-tmp3 尚未签收的写侧变量带入主对照；若 block-size 对照后仍有必要验证
写侧 async，另立小任务。每个 cell 使用独立、起跑前不存在的 10 GiB 文件，按下列顺序运行
16 MiB 写：

```text
B256 → B4 → B4 → B256
```

竞品原命令没有 `end_fsync`。每个 cell 同时报告两种、但都不冒充底层介质持久带宽的口径：

```text
竞品口径 = fio JSON/bw log 报告的前台带宽
close-complete 口径 = fio JSON io_bytes / 执行器从启动 fio 到进程完整退出的外部 wall time
```

第二个口径包含 fio teardown、文件 close 和 JuiceFS writer flush，但由于 `time_based` 会反复覆盖
同一 10 GiB 文件，它只能表示“该重复覆盖工作负载越过客户端 close 屏障的速率”，不能表示每个
提交字节都形成独立持久数据。fio 退出后不再另开文件做无效的 post-fio fsync。

每个正式写 cell 都必须独立完成以下闭环，不能等矩阵末尾再检查：

```text
fio完整退出
  → write buffer回到cell前基线±1 MiB、uploading=0，且PUT/DELETE计数连续3个5秒采样不再增长
  → graceful umount、父子worker全部退出且退出码/信号正常、扫描完整日志
  → 新挂载核对文件大小和固定抽样hash
  → 精确删除本cell文件、graceful umount并再次扫描日志
  → 仅对该临时META执行gc --delete，pool对象/空间回到本phase冻结锚
  → Ceph/TiKV无活跃恢复或compaction后才进入下一cell
```

drain 最长等待 300 秒；超时、worker 非零/信号退出、assert、读回失败、GC 失败或对象/空间不能
回到预注册容差时，当前写 cell 无效并停止整个写分支。容差必须在 Phase I 依据采集精度冻结，
开跑后不得放宽。逐 cell 复位是 B256/B4 因果有效性的一部分，不得为省时删除。

### 4.5 步骤二裁决

读、写分别裁决，禁止合并：

- B4 两个配对方向均为正且相对 B256 增益至少 10%，对象 GET/PUT 次数每 GiB 明显下降，且
  clat/p99、CPU、RSS、错误率、写 drain 无大于 10% 的反向退化：记
  `BLOCK4_SCREEN_SIGNAL`；只有增益超过 43%且坏档压力测试后仍为正，才升级为
  `BLOCK4_STRONG_SCREEN_SIGNAL`；
- 增益小于 5%或方向反转：记本 RUN `BLOCK4_SCREEN_NO_SIGNAL` 并停止，不外推成普遍无效；
- 增益 5%–10%或两次方向不一致：记 `INCONCLUSIVE_SMALL_SIGNAL`，本任务不补样；
- 达到竞品目标可另记 `TARGET_REACHED`，但不改变证据等级；
- B4 即使有效，也只能作为“大块顺序专用卷”候选。未完成 256 KiB 七项回归前，不得替换当前
  随机 I/O 主配置。

## 五、执行阶段、授权与收口

### Phase 0：步骤一脚本与离线 Gate 0

只准备 `t04tmp3b-executor.sh`、`t04tmp3b-analyze.py` 和 `t04tmp3b-gate0-offline.sh` 三个新增文件；
优先复用 04-tmp3 的身份、fio、指标与证据代码，以及现有 `u141d-scrub-control.sh`，不再拆更多
脚本。为避免步骤一已经回答问题后浪费步骤二开发成本，Phase 0 只实现步骤一和步骤二的安全拒绝桩；
只有步骤一签出 `BLOCKSIZE_TEST_JUSTIFIED` 后，才在相同三文件内补实现步骤二并重新 Gate 0。
Gate 0 只跑合成 fixture，禁止 SSH、mount、fio、juicefs、ceph 和 sudo。首轮至少验证：步骤一矩阵/
顺序、参数单变量、当前卷只读、分析器时间窗、步骤二未实现时硬拒绝、assert 门、证据路径和危险命令
扫描。通过后冻结首轮脚本 SHA256；步骤二若获准，新的 Gate 0 再验证 B256/B4 身份、禁止 `--force`、
UUID 防误毁、写后 close/drain/重挂和精确清理。

### Phase I：只读 inventory 与计划

连接 157 后仅采集身份、容量、health、现有读资产、指标可用性和当前卷指纹；生成步骤一命令、
scrub 计划，以及步骤二的 format/destroy 命令全文，但不执行任何状态变更。

### Phase II：步骤一

得到执行授权后，在一个 scrub lease 内连续完成步骤一和恢复；不中途改脚本、不补样。完成后先
恢复 scrub，再持久化证据并在“是否进入步骤二”停点由 GPT 复核。

### Phase III：步骤二创建与 canary

先单独审批两个 format 动作；创建后完成 status 身份门和生命周期 canary。失败保留现场，不自动
destroy，不进入正式矩阵。

### Phase IV：步骤二正式矩阵

在新的 scrub lease 内连续完成已开放的读/写分支。每个方向回答后停止，不新增 block-size 档位、
并发度或缓存变量。写分支开跑前必须另行审批逐 cell 精确文件删除和两条临时 META 上的
`gc --delete` 计划；结束后恢复 scrub、卸载、完成读回和证据持久化。

### Phase V：独立清理与报告

先生成只读 cleanup/destroy plan，逐卷列出 META、Name、UUID、专属文件和对象前缀，证明 UUID
不等于当前卷。经用户独立精确授权后，才按“删除临时卷内 manifest 文件 → graceful umount并
等待 session 消失 → `gc --delete` 仅处理对应临时 META → destroy 对应 UUID”的顺序清理；每一步
均核对 pool 对象/空间回归，并在本地流式计数两个临时 Name/prefix 已归零（不保存全池对象清单）。
destroy 或 GC 失败立即停止，不得改用 pool 删除、扩大路径或强制卸载。最后证明 `juicefs-prod`
的 META/UUID/data prefix 仍存在且指纹不变，业务进程、Ceph health/PG 和空间锚均正常。

正式报告写入 `doc/perf-report/04-tmp3b-competitor-large-block-io-path-alignment-<DATE>.md`；只有原始
证据、分析结果和环境收口全部通过，才可在 results-table 增加独立“大块顺序口径”小节，不覆盖
现有 256 KiB 七项基线。

## 六、sudo 与安全边界

本任务执行器、fio、mount、format、fsync、status、临时卷 GC/destroy 本身不应调用 sudo；但
format、GC 和 destroy 仍属于状态变更，必须使用相互独立的精确计划与授权。唯一计划中的
sudo 写操作是每个性能 phase 可选的 scrub 暂停/恢复，并且只能通过
`u141d-scrub-control.sh`、精确 FSID 和 state-driven lease 执行：

```text
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub
sudo ceph osd unset noscrub
sudo ceph osd unset nodeep-scrub
```

每个 phase 最多各一次 set/unset，步骤一 lease 上限 3 小时、步骤二上限 4 小时；必须另行列出
原状态和完整命令供用户批准。若未批准则不暂停 scrub，正式窗一旦与 scrub 重叠即判该 cell
无效，不得把巡检忽略掉。

绝对禁止：`rm -rf` 宽路径、glob 删除、force/lazy umount、模式 kill、全局 drop_caches、pool
delete/create、PG/CRUSH/OSD/TiKV/服务修改或重启、设备格式化/擦除、对当前卷执行
format/destroy/gc-delete。任何新增 sudo 或扩大状态变更范围都必须停止并重新向用户审核。

## 七、证据和数据生命周期

- 每个 phase 结束即把新增证据增量复制到唯一权威根，生成 manifest/SHA256 并验证可读；不得反复
  全量复制旧目录。
- `run-state.tsv` 至少记录 `VALIDITY_STATE`、`LIFECYCLE_STATE`、`INCIDENT_STATUS`、
  `EVIDENCE_ROOT`、`REMOTE_RESULT_ROOT`、`RETENTION_DECISION` 和两个临时 UUID。
- 性能端点不得用于删样本；失败样本、命令、日志和 incident 必须保留到归因完成。
- 环境资产清理与证据清理分开。持久副本未校验前不得删除远端唯一原件；清理只允许冻结 manifest
  中本 RUN 的精确绝对路径和已核验的临时 UUID，不使用通配或递归宽删。
- 最后一步按上述 skill/guide 做合规复核；未收口则状态为 `DOWNSTREAM_HOLD`，不得启动下一项
  性能任务。

## 八、预注册的最终输出

最终报告首屏必须分别给出：

1. `RA_RESULT`：8/16/32 MiB 的最佳观察档、方向性信号和坏档压力测试；
2. `ASYNC_READ_RESULT`：强信号、方向信号、无信号或无效；写侧 async 明记
   `NOT_TESTED_BY_DESIGN`；
3. `BLOCKSIZE_READ_RESULT`、`BLOCKSIZE_WRITE_RESULT`：B4 相对 B256 的 L1 配对观察和对象请求变化；
4. `TARGET_STATUS`：5.4/3.2 GB/s 是否达到；
5. `WRITE_COMPLETION_STATUS`：前台带宽、close-complete 口径、drain 和重挂校验；明确不外推为
   底层介质持久带宽；
6. `VALIDITY_STATE` 与 `LIFECYCLE_STATE`；
7. 若未达标，明确落到哪一层：应用/FUSE 串行、对象请求粒度、客户端资源、网络或 Ceph 后端，
   不得仅写“架构限制”。

本任务的最大成功不是多跑数据，而是以最少矩阵回答：挂载参数能否解决大块单流问题；不能时，
4 MiB format 是否提供了可重复、可解释的对象层收益。

## 九、修订记录

| 日期 | 修订 |
|---|---|
| 2026-09-04 | 初版：按“两步法”冻结现有 256 KiB 卷 readahead/async 筛选，以及 fresh B256/B4 隔离卷因果对照；补入 04-tmp3 写侧 assertion、close/drain/重挂和精确清理硬门。 |
| 2026-09-04 | 执行前收缩：先实现步骤一，步骤二待步骤一裁决后再补；统一使用已验证的 `--read-only`，沿用私有 `ms_async_op_threads=8`，GPT 修复 fio 绕过新挂载和进程范围过宽问题后，离线 Gate 0 通过。 |
| 2026-09-04 | Step 1 首次完整执行得到 RA32 方向性观察，但复核发现 sidecar 错把 TiKV 网卡当成 Ceph 数据网卡，且沿用旧式指标名而漏采 1.4 对象 GET 指标；该 RUN 降级为工程观察，禁止进入 Step 2。仅修正这两处仪表并通过离线 Gate 0，等待使用新 RUN_ID 完整重跑 Step 1。 |
| 2026-09-04 | Step 1 新 RUN `20260904-132417` 有效：RA32 两配对为 +9.74%/+13.80%，未过“双配对均≥10%”门，故回退 RA8；async 两配对均约 0%，保持关闭。1 MiB FUSE read 稳定拆成 4×256 KiB GET，客户端 CPU 和 100GbE 均未先饱和，允许进入 fresh B256/B4 Step 2，但须先补实现、离线 Gate 0 和独立授权。 |
| 2026-09-04 | Step 2 首次 create 在任何 namespace/对象产生前被固定二进制拒绝不支持的 `--dir-stats`，B4/canary/layout 均未启动且 pool 精确不变。历史同版本族证据证明该字段与 `MinClientVersion` 均为新卷默认值；重试脚本删除两个不支持参数、保留 format 后 Setting 硬校验，并改用全新 `s2r2` 名称，离线与远端 Gate 0 均通过，等待更正后的 format 授权。 |
| 2026-09-04 | Step 2 read RUN `20260904-132417` 有效：B256 两格均值约 `2500.81 MiB/s`，B4 两格约 `1654.46 MiB/s`，B4 两个配对分别 `-34.13%/-33.47%`。B4 虽将 GET/GiB 从约 `4096` 降至 `256`，但单 GET 平均时延由约 `1.15 ms` 增至 `5.59 ms`，单流总带宽反而降低，读分支裁决 `BLOCK4_READ_SCREEN_NO_SIGNAL`。写分支因 04-tmp3 尚无有效持久性结果，继续最小 ABBA 闭环。 |
| 2026-09-04 | Step 2 写分支在首个 B256 cell 触发持久性硬门：fio 前台/close-complete 为 `3163.45/3150.57 MiB/s`，但 clean unmount 后重挂时 10 GiB 文件在原路径不可见，volume status 仍计入约 10 GiB。该值仅作工程观察，停止后续 B4/B256 写 cell；两个临时卷已按精确 UUID 销毁，pool 回到创建前 1 object/64 KiB 范围内，当前 `juicefs-prod` 指纹不变，任务签 `EVIDENCE_INVALID_PERSISTENCE_GATE / ENVIRONMENT_CLOSED`。 |
