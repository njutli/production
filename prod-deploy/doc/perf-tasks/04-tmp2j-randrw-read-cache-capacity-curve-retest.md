# 04-tmp2j：randrw只读缓存容量收益曲线有效重测

> 日期：2026-09-07  
> 状态：`COMPLETED / VALID / CURVE_COMPLETE / ENVIRONMENT_CLOSED`  
> 级别：`L1_SCREEN`  
> 执行与审核：GPT（157正式执行；持久化raw独立复算）。  
> 承接：04-tmp2h五档只读缓存带宽完整，但正式采样器含递归目录扫描，RUN只能作工程观察；
> 04-tmp2i修复采样器后仅正式确认了128 GiB单点`+12.32%`，尚无有效的多容量曲线。

```text
04-tmp2d：纯randread读缓存容量曲线已闭合
04-tmp2h：randrw五档R/W/P矩阵完成，但runtime采样干扰使证据无效
04-tmp2i：低干扰采样器有效；T128只读缓存提高12.32%
        ↓
04-tmp2j：只重测randrw只读缓存32/64/96/128/256 GiB曲线  ← 你在这里
        ├─ 曲线有效且有材料收益 → 只登记一个生产canary候选，不直接交付
        ├─ 曲线有效但收益不可分辨 → 保持无缓存基线并关闭该方向
        └─ 非性能门失败/锚漂移过大 → 不拼接旧RUN，按状态机收口
```

一句话目标：用04-tmp2i已经验证的低干扰采样方法，准确重测randrw在只开启读缓存时的
`32/64/96/128/256 GiB`容量—命中率—带宽关系。

## 一、最小决策合同

```text
UNIQUE_QUESTION=randrw只开读缓存时，五档cache-size的有效收益曲线及最小平台档是多少
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=04-tmp2i已确认T128正收益并验证低干扰sampler；04-tmp2h五档仅作选点先验
SCREEN_CONTINUE=有效曲线存在超过同RUN噪声底的正收益时，只登记一个生产canary候选
SCREEN_STOP=曲线无可分辨收益、容量继续增加无增益，或证据状态非VALID时停止该参数线
FORMAL_MATRIX=NONE；若以后要直接交付固定容量，另立单点L2而不重跑整条曲线
MINIMUM_DECISION_SET=A0-pre+C32+C128+C64+A0-mid+C256+C96+A0-post，共8格
STOP_AFTER_ANSWER=8格完成并形成有效曲线后停止；不测writeback、P比例、其他容量或重复轮
MAX_PREP_BUDGET=60min
MAX_EXECUTION_BUDGET=3h（含必要恢复与持久化，不含用户等待）
ESTIMATED_WALL_CLOCK=约2--3h
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2j/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2j-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=逐cell优雅卸载并精确清空本RUN缓存子目录；最终删除唯一空RUN目录；scrub按lease恢复
```

本任务只补04-tmp2h无效的五档R曲线。04-tmp2i的T128结果只用于方向一致性检查，不与本RUN
拼接效应量，也不为了提高精度扩成多轮正式矩阵。

## 二、冻结变量与最小矩阵

### 2.1 软件、卷和数据资产

- 使用当前交付的patched JuiceFS v1.4.1、`juicefs-prod`、B256及交付私有Ceph配置
  `ms_async_op_threads=8`；执行前冻结binary SHA256/MD5、配置SHA256、META、UUID和BlockSize。
- 复用`test_dir/rw_test.0.0`至`rw_test.127.0`共128个既有1 GiB文件；冻结文件名、inode和size。
  randrw覆盖写导致mtime变化是预期现象，禁止layout、clone、format、destroy、扩容或创建新文件。
- fio固定为04-tmp2i同一负载：`randrw/rwmixread=50/bs=256K/128 jobs/libaio/iodepth=128/
  direct=1/fallocate=none/time_based/runtime=180/randrepeat=1/固定randseed`。
- 每格先对同一批文件执行固定180秒randread预热，再立即运行180秒randrw；A0也执行相同预热，
  保持后端起点操作对称。禁止根据命中率临时延长预热。
- 157禁止全局`drop_caches`，禁止触碰WekaIO、K8s、业务挂载、内核、网络及非本RUN进程。

### 2.2 缓存介质与参数

- 缓存介质固定为157现有原生ext4 `/mnt/jfs-cache`；每个缓存cell使用本RUN下独立、初始为空的
  cache-dir。复用04-tmp2d已验证的目录方案，**不再创建loop、backing file或新文件系统**。
- 所有挂载公共项固定`--max-fuse-io 256K --max-uploads 150 --free-space-ratio 0.20`，保持默认
  readahead/prefetch；所有cell明确关闭writeback。
- A0使用`--cache-size 0`；C32/C64/C96/C128/C256的`--cache-size`依次为
  `32768/65536/98304/131072/262144 MiB`。
- cell开始前记录缓存文件系统的`df -B1`；可用空间不足以安全容纳C256和20%空闲保护时停止，
  不缩档、不改`free-space-ratio`。
- 每个缓存cell从空目录开始；上一cell优雅卸载、确认挂载进程消失并精确清空自身目录后才能继续。

### 2.3 执行顺序

```text
A0-pre → C32 → C128 → C64 → A0-mid → C256 → C96 → A0-post
```

容量不按单调顺序执行，并在中间插入A0，以降低时间、TiKV/RocksDB运行状态和写后后台活动与容量
大小共线的风险。所有8格是一个RUN；禁止用04-tmp2h或04-tmp2i点值补格。

## 三、采样与统计口径

### 3.1 复用低干扰采样器

- 直接复用04-tmp2i已签收的CORE sampler：正式窗内只采Prometheus累计指标、`statvfs/df`、
  时间戳以及必要的网卡/块设备计数。
- 正式窗内禁止`find`、递归目录遍历、`sort`、inode清单、全量Ceph/TiKV命令或其他随缓存目录
  增长的操作；缓存文件/inode快照只在预热前、预热后和正式fio后各执行一次。
- 正式180秒要求至少150个CORE样本，正式窗`[15,175)`覆盖完整，最大相邻间隔`<=2.5s`，
  sampler rc=0；禁止插值补点或放宽门槛。
- 保存正式窗cache hit/miss字节、命中率、blockcache gauge、drops/evicts、Ceph数据网RX/TX和
  本地缓存盘吞吐/时延。机制指标缺失限制解释；CORE覆盖失败则RUN无效。

### 3.2 带宽真值

- 保存fio JSON、128份per-job逐秒bw log和完整命令；READ、WRITE分别汇总，禁止把二者相加
  冒充单向带宽。
- 实际I/O起点取“fio完成时刻减实际runtime”；按日志区间与自然秒的重叠时长加权，对128 job
  求和，只保留job齐全秒。
- 主口径为`[15,175)`内READ、WRITE各自的mean/median/CV/P10/P90和W1--W4；
  `mean_direction=(READ+WRITE)/2`只用于容量档排序。fio summary只作旁证。
- 每个C点相对其位置两侧A0做分段线性插值；不得统一减去跨日历史基线。

### 3.3 噪声和曲线判读

```text
D_A0=max(A0-pre/mid/post在READ、WRITE、mean_direction上的两两相对漂移)
M=max(5%, D_A0)
```

- `D_A0<=8%`且8格非性能门全部通过：`VALID/CURVE_COMPLETE`；逐点给出带宽、命中率和相对A0效应。
- `D_A0>8%`：`RESOLUTION_INSUFFICIENT`；曲线值可以报告，但小于噪声边界的差异不可排序。
- 任一cell缺失、身份/采样/健康/I/O错误等非性能门失败：`EVIDENCE_INVALID`；不得用旧RUN补点。
- 带宽、CV、W4/W1、命中率、drops/evicts和曲线不单调都是性能结果，不能作为删样门。
- “平台档”定义为容量从小到大搜索时，第一个同时满足以下条件的档位：
  1. `mean_direction`不低于本RUN最佳档超过`M`；
  2. READ和WRITE任一方向均未相对插值A0退步超过`M`；
  3. 更大容量没有超过`M`的新增收益。
  该档只登记为L1生产canary候选，不直接替换无缓存交付基线。

## 四、有效性门与环境控制

### 4.1 非性能硬门

每格前后必须通过：binary/config/META/UUID/PID/starttime/exe与mount参数一致；文件名/inode/size
一致；无foreign fio；fio error=0；Ceph OSD全部up/in、PG active+clean；无recovery/backfill/
peering/inconsistent；CORE sampler覆盖达标；缓存目录和可用空间未越界。

randrw是写负载。每格后必须按现有测试规范等待TiKV/OSD写后状态返回，至少确认
`compact_running=0`、`compact_queue_len=0`及既定`kv_sync_lat`门后才能进入下一格；这些等待只
恢复可比起点，不允许restart OSD、删除pool、destroy卷或重新layout。

### 4.2 scrub口径

为避免2--3小时矩阵被随机scrub污染，预注册在单个Phase II内临时设置
`noscrub+nodeep-scrub`。这只是受控benchmark环境条件，不是性能旋钮或生产配置：

1. 使用现有独立scrub-control脚本，记录FSID、原flags、lease、set/restore时间和完整health；
2. 设置前必须单独列出全局写命令并取得用户授权；等待已运行scrub退出后才能开测；
3. 矩阵中禁止轮间开关；任何退出路径优先恢复本RUN拥有的flags；
4. 恢复后确认原flags、Ceph健康和PG状态返回，再启动其他任务。

## 五、执行阶段与停点

### Phase 0：离线Gate 0

1. 执行前通读`SYSTEM-SAFETY-SKILL.md`、`TESTING-GUIDE.md`、
   `EVIDENCE-INTEGRITY-SKILL.md`、`LONG-RUNNING-TEST-SKILL.md`、
   `test-commands-reference.md`和`TEST-DATA-LIFECYCLE-POLICY.md`。
2. 不新建编排框架：以04-tmp2d的原生ext4五档缓存目录/容量逻辑为骨架，复用04-tmp2i的
   randrw job、低干扰sampler、分析器和scrub-control；只删除W/P分支并改为8格顺序。
3. Gate只覆盖本次改变的矩阵、cache-size、路径守卫、正式窗禁止递归扫描、旧稀疏采样负fixture、
   04-tmp2i有效采样正fixture、实际I/O起点和分段A0插值。
4. 完成bash/Python语法检查、明文秘密扫描、sudo/重启/删除命令清单和脚本SHA256。Gate 0未通过，
   禁止SSH、sudo、mount、fio、Ceph或JuiceFS命令。

### Phase I：只读inventory、计划与唯一开跑授权停点

只读确认157身份、业务指纹、文件资产、`/mnt/jfs-cache`文件系统及空间、foreign进程/挂载、
Ceph/TiKV起点、scrub原状态和脚本哈希；展开唯一RUN目录、8格命令、所有sudo/全局写命令、失败恢复
与精确清理计划。用户一次确认后，Phase II内部自主连续执行，不逐cell停下。

### Phase II：8格执行、持久化与裁决

1. 按授权暂停scrub并等待起点门通过；按注册顺序执行8格。
2. 每格只增量保存自己的raw；异常先记入append-only `incidents.tsv`并停止，不热改脚本、不补样。
3. 优先恢复scrub和本RUN挂载/缓存目录，确认157业务指纹与Ceph/TiKV状态返回。
4. 将证据一次性持久化并校验源/本地SHA256、文件数、字节数和归档可读性；执行方只提交raw、
   逐门清单和incident，不下效应结论。
5. GPT从持久化raw独立复算曲线、证据状态和平台档；回答唯一问题后停止，不追加测试。
6. 测试后对照上述skill复核：未删建pool、未全局drop_caches、未改业务/系统、写后状态返回、
   scrub精确恢复、统计和证据生命周期均符合合同。

## 六、安全与红线

- 任何sudo写和Ceph全局flag变更必须在Phase I列出节点、完整命令、精确路径和恢复命令，经用户
  明确授权后执行；只读inventory无需授权。
- 禁止reboot/shutdown、服务重启、kill非本RUN进程、网络/内核/WekaIO/K8s变更、裸盘操作、
  loop/mkfs、pool删建、卷format/destroy、layout和全局drop_caches。
- 禁止`rm -rf`宽删除、glob、未解析变量、递归chown/chmod、force/lazy umount和模式kill。
  清理只允许命中`/mnt/jfs-cache/jfs-04tmp2j-<RUN_ID>/`下经过realpath与非挂载验证的本RUN子目录。
- 运行脚本前扫描全部调用链中的sudo写、重启和删除命令；路径必须非空、绝对、非`/`、非符号链接，
  且包含精确TASK和RUN_ID。
- 失败时先停止并保留最小现场，优先恢复scrub；不得为了继续矩阵自行改变控制变量或降低硬门。

## 七、交付物与生命周期

必须交付：

1. `doc/perf-report/04-tmp2j-randrw-read-cache-capacity-curve-retest-<DATE>.md`；
2. 五档`cache-size/实际驻留/命中率/READ/WRITE/mean_direction/相对A0`表和收益折线图；
3. A0漂移、sampler覆盖、四窗、Ceph流量、本地缓存盘指标及有效性状态；
4. 实际脚本、`commands.sh`、原始fio/per-job log、sampler、快照、`incidents.tsv`、manifest和独立复算；
5. 更新`results-table.md`、`04-TASK-BOOK-STATUS-20260901.md`及0912周报中的randrw只读缓存曲线。

COMMON每RUN只保存一次，cell只增量保存raw。只有唯一`EVIDENCE_ROOT`完成SHA256、文件数、字节数和
归档可读性核验并记录`PERSISTENCE_PASS`后，才允许清理远端临时证据。审核完成后只长期保留一份
不可变raw归档、manifest、最终分析和报告；同步暂存、复算解压目录及已归因失败副本按
`TEST-DATA-LIFECYCLE-POLICY.md`精确收口。环境资产清理与证据清理分开授权。

## 八、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-07 | 初版：只重测五档randrw纯读缓存曲线；复用04-tmp2i低干扰sampler，改用04-tmp2d已验证的原生ext4 cache-dir，不再测试writeback/P比例或使用loop。 |
| 2026-09-07 | 执行准备完成：新增`t04tmp2j-randrw-run.sh`、`t04tmp2j-randrw-analyze.py`和`t04tmp2j-randrw-gate0-offline.sh`；本地Gate 0通过，待上传157并完成只读inventory。 |
| 2026-09-07 | RUN `20260907-155057`完成8/8格；A0漂移`5.03%`，五档效应`+5.62%/+3.95%/+9.82%/+11.07%/+14.84%`，按合同登记96 GiB最小平台L1 canary候选；环境与证据闭合。 |
