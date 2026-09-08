# 04-tmp2h：randrw 固定客户端缓存预算下的读写共享策略

> 日期：2026-09-05
> 状态：`COMPLETED / EVIDENCE_INVALID / NO_DECISION / ENVIRONMENT_CLOSED`（RUN：`20260906-090701`）
> 证据等级：`L1_SCREEN`；本文件只定义实验合同，不授权连接环境、sudo 或正式执行。
> 承接：04-tmp2d 已得到纯读缓存曲线；04-tmp2f/2g 已得到纯 randwrite 的排空与前台容量曲线，
> 但这些结果不能回答存储规格中的 50/50 `randrw` 应怎样使用一笔固定的客户端缓存空间。

```text
04-tmp2d：读缓存对纯读有材料收益，但不是 randrw 结论
04-tmp2f/2g：writeback 约 64 GiB 后前台平台，且容量/排空有风险边界
        ↓
04-tmp2h：randrw 读端点 → 写端点 → 各总空间档的最小混合曲线   ← 你在这里
        ├─ 无安全材料收益：保持无缓存交付基线，停止缓存线
        └─ 有安全候选：只登记对应总空间档的 canary 候选
                           ↓
             选定真实客户端预算后，另做一个原生文件系统 L2 canary
```

一句话目标：在 `32/64/96/128/256 GiB` 五档客户端总缓存空间下，从读优先、写优先及
`P25/P50/P75`动态共享候选中，找出当前 `randrw`命令的**最佳已测安全配置**。

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=04-tmp2d + 04-tmp2f + 04-tmp2g
SCREEN_CONTINUE=每档无条件测R/W/P50；只有某点的支配在-30%坏挂载压测后仍成立才省P25/P75，否则补齐
SCREEN_STOP=无安全材料信号，或数据/业务/Ceph/设备所有权/恢复/证据硬门失败
FORMAL_MATRIX=NONE；若要交付，只对实际选定的一个容量档另立原生文件系统L2 canary
ESTIMATED_WALL_CLOCK=正常22--30h；五档全部触发补点时硬上限30h
MINIMUM_DECISION_SET=A0首/中/尾锚+十个近邻交错端点+每档P50；无法裁决的容量档再加P25/P75
STOP_AFTER_ANSWER=五档均已得到最佳已测安全配置或明确无候选，不再扩容量/比例/重复轮次
MAX_PREP_BUDGET=90min
MAX_EXECUTION_BUDGET=30h
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2h/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2h-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=逐cell精确卸载、detach唯一loop、删除唯一backing并恢复本RUN的scrub lease
```

> 执行结论（2026-09-06）：28/28 cell及生命周期均完成，三个A0锚首尾漂移约2.38%；但R/P cell的
> runtime采样被同步rawstaging目录遍历拖慢，违反预注册的每秒覆盖硬门。严格分析签
> `EVIDENCE_INVALID/NO_DECISION`，fio带宽仅保留为描述值；全部混合P点相对同RUN A0下降
> 7.68%--68.85%，当前不改生产配置且不立即重跑。详见
> `doc/perf-report/04-tmp2h-randrw-shared-cache-budget-allocation-20260906.md`。

## 〇、先冻结语义边界

JuiceFS v1.4.1 的 `raw/` 读缓存和 `rawstaging/` 写回暂存位于同一个 `cache-dir` 文件系统；
staging 上传后还会以 hard link 进入 raw。因而不改源码时：

1. 不能把 `raw/` 和 `rawstaging/` 分别挂到两个 loop/dm 设备；跨文件系统 hard link 会失败；
2. 多个 `cache-dir` 按 key 哈希分流，也不能指定一个只读、另一个只写；
3. `--cache-size` 只是 raw 读缓存的目标，不是读空间硬配额；writeback 也没有独立容量参数；
4. 本任务用**一个容量受控的 loop/ext4**定义客户端总物理预算，再改变 `--cache-size`，观察
   JuiceFS 在同一空间内形成的实际 raw、rawstaging、空闲空间和性能。

因此本文中的“读/写分配”是**动态共享策略**，不是两个硬分区。最终横轴以新 ext4 挂载后的
`df -B1 Available` 为准；不得用 backing 名义值、`cache-size` 或 `free-space-ratio` 推定实际占用。
`raw` 与 `rawstaging`可能指向同一 inode，禁止把两目录的 `du`直接相加；总物理占用取 `df`，
角色占用结合 metrics、staging 文件及 inode 去重表报告。

当前环境是“现有挂载目录可提供一部分空间”，故只复用已验证的
`普通文件 → 唯一 loop → 普通 inode 密度 ext4`。本任务不引入 dm-linear，也不接触裸盘。

## 一、问题、输出和结论边界

### 1.1 唯一问题

对 128 GiB 热数据集上的 128-job、50/50 randrw，在客户端总缓存空间分别约为
`32/64/96/128/256 GiB` 时，哪一种**已测且满足排空/安全约束**的配置能使

```text
mean_direction_MiBs = (READ_MiBs + WRITE_MiBs) / 2
```

最大。

### 1.2 必须交付的表

每个总空间档输出一行：

```text
实际总量/初始Available | 最佳已测配置 | cache-size | writeback
READ | WRITE | mean_direction | READ+WRITE(仅描述)
正式窗命中率 | actual raw峰值 | staging峰值 | min free
严格排空秒数 | effective_durable_write | 生命周期判定 | 与次优差距
```

`READ`、`WRITE`必须分开报告并分别与 1870/6250 MiB/s 参照线比较；`READ+WRITE`不得冒充单向
带宽。`mean_direction`只用于配置排序。候选若以均值换来任一方向相对同 RUN A0 退步超过判定
边界，不得称为“无代价最优”，只能列入 Pareto 取舍。

### 1.3 不允许扩大结论

- 本任务只能称“预注册候选中的最佳已测安全配置”，不能声称连续参数空间的数学全局最优；
- loop-on-ext4 是容量控制装置，绝对带宽不能直接外推到原生 NVMe；
- L1 单次筛选不直接改生产配置。有材料信号时，等用户给出真实可用空间，只确认**一个**容量档；
- 04-tmp2g 的“约 64 GiB 平台”只适用于固定 128 GiB 纯 randwrite，是选点先验，不是本任务结论。

## 二、冻结配置与起点

### 2.1 软件与挂载公共项

- JuiceFS：当前交付 exact patched v1.4.1，执行前冻结 MD5/SHA256；
- META/卷：现有 `juicefs-prod`；只使用参考挂载中已有的 `test_dir/rw_test.*.0`；
- Ceph 客户端：沿用交付私有配置 `ms_async_op_threads=8`；
- 所有测试挂载固定 `--max-fuse-io 256K --max-uploads 150 --free-space-ratio 0.20`，保持默认
  readahead/prefetch；除 cell 定义外禁止增加其他 mount 参数；
- writeback cell 使用 `--writeback`；writeback 关闭 cell 不得携带该参数；
- `cache-size=0`会同时关闭 writeback，因此写优先端点必须使用最小正值 `--cache-size 1` MiB；
- 157 禁止全局 `drop_caches`，不触碰 WekaIO、K8s、业务挂载、内核、网卡及非本 RUN 进程。

### 2.2 数据与 fio

- 数据集：`rw_test.0.0`至`rw_test.127.0`，共 128 个既有 1 GiB 文件；冻结名称、inode、size；
- 禁止 layout、clone、fresh volume、文件创建和扩容；覆盖写造成的 mtime 变化是预期现象；
- 正式负载与当前规格完全一致：`randrw`、`rwmixread=50`、128 jobs、每 job 1 GiB 文件、
  `bs=256K`、`libaio`、`iodepth=128`、`direct=1`、`fallocate=none`、`time_based`、`runtime=180`；
- 显式冻结 `randrepeat=1`和同一个 `randseed`，所有 cell 使用同一 jobfile 结构；
- 每个 cell 从空客户端缓存开始，先在**同一批 rw_test 文件**上执行固定 180 秒 randread 预热，
  再立即执行正式 randrw。A0也执行同样预热，使后端起点操作对称；
- 预热不合格不能自动延长：只记录实际驻留量、命中率和 drops/evicts，性能差是结果。

### 2.3 总物理空间档

| 档位 | backing 名义容量 | 相对128 GiB热集 | 正式横轴 |
|---|---:|---:|---|
| T32 | 32 GiB | 25% | 新ext4初始`df Available` |
| T64 | 64 GiB | 50% | 同左 |
| T96 | 96 GiB | 75% | 同左 |
| T128 | 128 GiB | 100% | 同左 |
| T256 | 256 GiB | 200% | 同左 |

每个 cell 单独创建一个 fully allocated backing、一个动态 loop 和一个 ext4；任一时刻最多存在一个
本 RUN loop。宿主 `/mnt/jfs-cache`在创建前必须有“本 cell 名义容量 + 64 GiB”可用空间；不满足即停，
不得改用 sparse overcommit。ext4 禁用历史上造成 inode 不足的 `-T largefile`。

### 2.4 写后等价起点

最多数十次180秒randrw会产生与配置带宽相关的不同写入量，不能只靠“进程已结束”假定下一格起点
相同。RUN开始先在既有数据集上执行一次项目已验证的`juicefs gc --compact`和OSD compact cooldown，
冻结`seed_objects`、`seed_stored_bytes`和128文件资产清单。每个cell后只执行一次同样的gc，
并对冻结的6个OSD各下发且只下发一次`ceph tell osd.<id> compact`。从这两类命令返回时起进入
最长`1800s`的唯一状态返回窗，每`30s`采样；下一cell前必须同时满足：

```text
abs(current_objects - seed_objects) <= 8192
六个OSD连续3次（间隔10s）：compact_running=0 AND compact_queue_len=0
六个OSD同三次采样：kv_sync_lat.avgtime < 2 ms
128个文件：name + inode + size 与RUN起点逐项一致
```

`juicefs gc --compact`返回码非0、OSD perf dump缺失上述已冻结字段，或任一硬门在`1800s`
内不成立，均记`STATE_RETURN_FAIL`并停止整个RUN。`pool stored bytes`、gc输出的
scanned/pending以及TiKV `pending_compaction_bytes`暂无可用的跨cell标定容差，仅作协变量记录，
不设一道无法机械实现的“趋势门”。它们在本L1中只用于描述和解释，不自动删除样本，
也不改变`RUN_VALIDITY_STATE`；若观察到异常趋势，只能登记为后续L2/诊断的待验证问题。

证据分别落到`state/<CELL>-pool.tsv`、`state/<CELL>-gc.txt`、`state/<CELL>-osd.tsv`、
`state/<CELL>-tikv.tsv`和`state/<CELL>-assets.tsv`，其中`pool.tsv`必须同时保存objects与stored bytes的
全部轮询序列。上述门不能证明RocksDB历史状态逐字节相同，但能阻止已知的
对象和compaction债继续跨格累积。不用第二遍gc、重启或重建来“洗”出结果。

## 三、三步自适应矩阵

### 3.1 公共无缓存锚

锚点使用`cache-size=0`、writeback关闭、无loop，并执行与正式cell相同的预热和randrw命令。

- `A0-pre`：第一个容量组前；
- `A0-mid`：T32/T128/T64三个容量组结束后；
- `A0-post`：T256/T96两个容量组结束后；因每档都必测P50，该尾锚不得省略。

在线决定是否省略P25/P75时用保守边界：

```text
A0-mid尚未存在：M_online = 8%
A0-mid已存在：
D_pre_mid = max(|pre_READ/mid_READ-1|, |pre_WRITE/mid_WRITE-1|,
                |pre_mean/mid_mean-1|)
M_online = max(8%, D_pre_mid)
```

若`D_pre_mid>8%`，在A0-mid即按预注册分支停止，未执行后两组不记为“缺格”，
而记`RUN_VALIDITY_STATE=RESOLUTION_INSUFFICIENT`。否则最终报告计算
`M_final=max(5%, D_final)`，其中`D_final`是三锚在READ/WRITE/mean_direction三个指标上的
最大两两相对漂移。`D_final>8%`时签
`RUN_VALIDITY_STATE=RESOLUTION_INSUFFICIENT`；各cell工程值保留，但禁止跨时段形成精确效应量。

### 3.2 步骤一：只开读缓存，得到 randrw 读端点曲线

五档均关闭 writeback，把 `cache-size`设为该 cell 初始 `df Available`向下取整到 MiB；
实际 raw 会受物理空间、free-space-ratio 与清理策略限制，以 metrics/df 实测为准。

本步骤回答“固定总空间全部偏向读缓存时，randrw 的读收益和写侧代价如何变化”。不得引用纯
randread 的04-tmp2d曲线替代本步骤。

### 3.3 步骤二：近似只开 writeback，得到 randrw 写端点曲线

五档均设置 `--writeback --cache-size 1` MiB，容量只由 loop/ext4 控制：

本步骤回答“固定总空间近似全部供writeback动态使用时，前台写收益、读侧影响和排空代价如何变化”。
任何真实 ENOSPC、hardlink/upload 异常或 900 秒不排空都会淘汰该 cell，但容量型失败本身是有效
风险下界。900秒只是候选资格门：到时先只读取证，再走04-tmp2f已经验证的同cache-dir恢复挂载
流程；只有严格归零、抽读和资产恢复均通过后才可清理并继续。恢复挂载再等900秒仍不归零、优雅
卸载失败、数据错误或未知设备时立即停止全RUN并保留现场。fio自身出现I/O错误则是无效cell，不得
作为容量下界。

### 3.3a 三个分析步骤的物理执行顺序

步骤一至三是三类分析曲线，但物理执行不把全部R、全部W和全部混合点分成三个长时段。
同一容量的R/W/P50连续执行，再依§3.4立即决定是否补P25/P75：

```text
A0-pre
→ T32 : R → W → P50 [若需要 → P25 → P75]
→ T128: W → R → P50 [若需要 → P75 → P25]
→ T64 : R → W → P50 [若需要 → P25 → P75]
→ A0-mid（漂移>8%则停）
→ T256: W → R → P50 [若需要 → P75 → P25]
→ T96 : R → W → P50 [若需要 → P25 → P75]
→ A0-post
```

这样同容量的候选最近，R/W先后尽可能交替，容量也不是单调梯子。每格仍必须先通过§2.4
起点门，不能为了保持顺序越过未恢复的状态。分析时再按R/W/混合类别生成三条曲线。

### 3.4 步骤三：读写同时开启，在多档总空间中找共享策略

按§3.3a在每个容量组内先连续完成R/W/P50，禁止用T128外推其他档。为防止漏掉
“单一端点看似支配，但读缓存与writeback同开后存在协同收益”，每档无条件测P50。
所有混合点均开启writeback：

| Cell | `cache-size`候选（`U_T`为该cell初始`df Available`） | 含义 |
|---|---:|---|
| M-T*-P25 | `0.25 × U_T` | 偏写 |
| M-T*-P50 | `0.50 × U_T` | 平衡 |
| M-T*-P75 | `0.75 × U_T` | 偏读 |

配置值向下取整到MiB；仍须以实测raw、staging和df解释，P25/P50/P75不代表硬分区。满足条件的
档位仅在符合下述保守早停时省略P25/P75，否则立即按§3.3a的顺序连续补齐；不再增加
第4个比例。对当前局部三点`C={R,W,P50}`的READ/WRITE，定义：

```text
dR = X_READ / Y_READ - 1
dW = X_WRITE / Y_WRITE - 1
X“材料支配”Y  :=  min(dR,dW) >= -M_online AND max(dR,dW) >= M_online
```

早停还要求R/W/P50三点均已完成可恢复收口，且X是§4.2定义的生命周期安全候选；
对writeback配置，这包括原挂载`900s`内严格排空、无容量或生命周期异常。在此前提下，只有存在一个X，
使得：

```text
X 材料支配 C 中其他两点
AND
将X的READ和WRITE同时乘以0.70后，X仍材料支配其他两点
```

才允许省略P25/P75；这把保守在线边界`M_online>=8%`和历史最坏挂载档`-30%`同时纳入
早停。任一局部三点仅具风险观察资格时，若安全恢复已完成则补P25/P75，恢复失败则仍按
全RUN停止分支处理。其余任意情形——包括全平台（所有两两`abs(relative_delta) < M_online`）、
Pareto取舍、P50只支配一点——都补齐P25/P75。该早停只是节省机器时间的L1规则，
不是“连续参数空间绝无更优点”的数学证明。

同档R/W/P50与需补的两点不得被其他容量档拆散。执行方按冻结规则生成
`mixed-matrix-freeze.tsv`并记录每次决定所用的cell文件SHA256、`M_online`与`0.70`压测计算，
可在一次授权内继续，不需要逐cell人工挑点。

### 3.5 最多会跑多少

| 组成 | cell数 |
|---|---:|
| A0锚 | 3 |
| 读/写端点 | 10 |
| 每档必测P50 | 5 |
| 每个触发档再补P25/P75 | 2（合计0--10） |
| **合计** | **最少18，五档全触发时28** |

所有性能 cell 已直接运行原始 `time_based=180s` randrw，不再追加“短筛后再确认”的第二套矩阵。

## 四、证据、统计和裁决

### 4.1 有效带宽

主效应带宽以fio JSON中128 job每方向`io_bytes`总和除以该方向实际runtime计算，完整保留无完成量
时段的影响。另保存128份per-job逐秒bw日志并按方向拆分，作为median/CV/P10/P90、W1--W4及
W4/W1趋势诊断；正式窗`[15,175)`至少覆盖150/160个128-job齐全秒，必须报告覆盖率和缺失秒，
但辅助bwlog尾部少量空秒不得推翻fio JSON主效应。命令墙钟仅作旁证。

缓存/生命周期至少每秒采集：

```text
blockcache hit/miss/bytes/evicts/drops
staging blocks/bytes/writing_blocks
cache ext4 df used/available/min-free
raw/rawstaging 文件数、字节与inode去重占用
Ceph数据网RX/TX、宿主NVMe统计、JuiceFS daemon错误日志
```

命中率按正式窗`Δhit_bytes / (Δhit_bytes + Δmiss_bytes)`计算，不用预热累计计数代替。
writeback cell另报：

```text
drain_seconds = fio结束到metrics与rawstaging文件连续两次（间隔10秒）均为0
effective_durable_write = fio正式写入总字节 / (实际I/O起点到严格排空的墙钟时间)
```

`effective_durable_write`只描述写回生命周期，不与READ求平均，也不冒充Ceph物理写带宽。

判据到原始文件的固定映射：

| 判据 | 唯一原始来源 |
|---|---|
| READ/WRITE与四窗 | `cells/<CELL>/fio.json`及`bw/randrw_bw.*.log`中的方向字段 |
| 实际I/O起点 | `fio.json`的run/elapsed字段 + `fio-end-epoch-ns.txt` |
| 命中率/raw/staging/min-free | `cells/<CELL>/runtime.tsv`、`cache-inodes-*.tsv` |
| 严格排空/恢复 | `drain.tsv`、`rawstaging-*.tsv`、`recovery/` |
| 容量与设备身份 | `cache-df.tsv`、`cache-findmnt.tsv`、`loop-identity.tsv` |
| 写后等价起点 | §2.4列出的五个`state/<CELL>-*`文件 |
| mount与参数身份 | `commands.sh`、daemon log、PID/starttime/exe hash |

### 4.2 非性能硬门与性能端点分离

可删除/淘汰cell的门仅限：fio错误、job/log缺失、实际参数或身份不符、资产名称/inode/size漂移、
sampler覆盖不足、Ceph出现非预期健康状态、设备/路径所有权不符、非容量型upload错误、数据抽读或
恢复失败。writeback cell在原挂载900秒内严格排空才有候选资格；缓存日志中的容量型ENOSPC或
原挂载排空超时保留为风险观察，但该cell不得进入“安全候选”集合。只有fio JSON自身出现非零error
时才是无效性能样本。超时cell按§3.3的唯一恢复分支处理，恢复成功不能追认原cell通过。

带宽、CV、命中率、drops/evicts、曲线不单调、direct fallback和排空较慢均是性能结果，不能用来
删除样本。

### 4.3 每档选择规则

只在生命周期安全的配置中排序。在线早停用`M_online`，最终用：

```text
M = M_final = max(5%, D_final)
D_final = max(|A0_i,d / A0_j,d - 1|), i!=j, d∈{READ,WRITE,mean_direction}
```

T32/T128/T64以A0-pre/A0-mid按cell位置线性插值，T256/T96以A0-mid/A0-post插值；
READ和WRITE各用本方向的`A0_ref_READ/A0_ref_WRITE`归一，mean_direction另用对应的`A0_ref_mean`。
跨阶段比较使用`cell/A0_ref`的相对效应，不直接比较
相隔十余小时的裸带宽。A0与cell是同一个randrw负载，这不是已证无效的`randrw/mseqread`归一化。

- 第一名相对第二名差 `< M`：报告“最优平台”，按不启用writeback、排空更快、min-free更高的顺序
  选择风险更低者，不强称性能唯一最优；
- 第一名相对第二名差 `>= M`：登记为该容量档的L1最佳已测配置；
- 平均值提高但READ或WRITE任一方向退步`>= M`：只列Pareto取舍，不称无代价收益；
- 相对A0提高`>=5%`才称材料信号；低于5%只作工程波动范围；
- 任一锚漂移超过8%：全RUN只报描述值，记`RUN_VALIDITY_STATE=RESOLUTION_INSUFFICIENT`。

当前已标定的mseqread ns/B判档器建立在无本地缓存的后端读路径上；在本任务的缓存挂载中，探针会
自行升温并改变路径，**不具备原阈值语义**。本任务不运行一个看似合规、实则失真的判档门：只在
A0无缓存挂载上保留原判档器，缓存cell记录PID/starttime、预热首段的FUSE ns/B及实际命中率作为
协变量，不据此剔样。

因此每个缓存结论必须把有利cell整体按历史最大坏挂载档`-30%`做压力测试。压力测试后翻转，或
候选间差异不足以越过该风险时，`RUN_VALIDITY_STATE=RESOLUTION_INSUFFICIENT`，只能报
“候选平台/需L2确认”，不能报唯一最优。选定实际预算后的
原生L2 canary必须用缓存场景可用的判档方法，或每候选至少3个挂载实例的平衡设计，负责最终确认。

最终必须独立输出“证据/分辨力状态”和“缓存业务裁决”，不得将二者合并成一个标签：

```text
RUN_VALIDITY_STATE=VALID | EVIDENCE_INVALID | RESOLUTION_INSUFFICIENT | INCONCLUSIVE
CACHE_VERDICT=SCREEN_CANDIDATES | NO_SAFE_MATERIAL_CANDIDATE |
              PARETO_ONLY | PLATFORM_NEEDS_L2 | NO_DECISION
```

- `VALID`：所有非性能硬门通过，应执行的自适应矩阵完整，且分辨力足以支持对应裁决；
- `EVIDENCE_INVALID`：非性能硬门失败、缺格、参数/身份不符或原始证据不完整；
- `RESOLUTION_INSUFFICIENT`：证据完整，但首尾锚漂移`>8%`、缓存挂载风险大于已测效应、
  或`-30%`压力测试翻转；
- `INCONCLUSIVE`：证据完整且分辨力足够，但预注册规则仍无法将结果唯一映射到业务裁决；
- `CACHE_VERDICT`按上述每档规则填写；非`VALID`时只能是`PLATFORM_NEEDS_L2`或`NO_DECISION`，
  不得登记生产候选。

## 五、最简执行流程与停点

### Phase 0：离线 Gate 0

1. 执行前通读并确认：`SYSTEM-SAFETY-SKILL.md`、`EVIDENCE-INTEGRITY-SKILL.md`、
   `LONG-RUNNING-TEST-SKILL.md`、`TESTING-GUIDE.md`、`test-commands-reference.md`以及
   `TEST-DATA-LIFECYCLE-POLICY.md`；
2. 只复用04-tmp2d的cache指标/正式窗分析，以及04-tmp2g的loop、writeback、排空、恢复和scrub组件；
   不新建通用编排框架；
3. Gate只覆盖本任务新增路径：randrw双方向日志、五档cell解析、读/写mount合同、逐档混合准入、
   容量组过滤与组内顺序、900秒资格门、1800秒状态返回门、同cache-dir恢复和路径/loop所有权；
4. 分析器先用04-tmp2d/2g历史归档及合成randrw fixture自证，包含I/O起点±1秒和+58秒敏感性；
5. Gate未通过，禁止SSH、sudo、mount、fio、ceph或juicefs操作。准备超过90分钟仍未通过则停止，
   报告阻塞，不在环境里调脚本。

### Phase I：只读inventory、完整计划与唯一授权停点

冻结二进制、META/UUID、128文件资产、业务挂载、Ceph/pool起点、宿主空间、现有loop/mount、外来fio、
脚本SHA和全部实际命令。逐条输出预计的sudo写操作及精确RUN路径。

长矩阵预注册暂停普通scrub：复用状态驱动脚本，一次设置`noscrub+nodeep-scrub`，收口时只恢复本RUN
实际拥有的原状态。预计暂停`22--30h`，硬上限`30h`；期间会延后Ceph例行对象一致性巡检，
因此不得与故障修复或维护窗口重叠。它是独立的Ceph全局写操作，必须与loop/mkfs/mount/compact
计划一起由用户一次明确授权；未获授权不得执行。

**停点1：** 用户审核inventory、矩阵、脚本SHA和全部sudo计划；任务书本身不是授权。

### Phase II：一次授权内自主完成矩阵

按§三执行。A0无缓存挂载按`TASK-BOOK-AUTHORING-GUIDE.md`§二.10运行既有判档器，
重试须换唯一label且最多两次；
缓存cell按§4.3明确登记“既有判档器不适用”，不运行会自热污染的伪判档，只记录挂载身份和冷预热
协变量，并对最终结论执行`-30%`压力测试。

正常cell结束顺序固定为：writeback严格排空（如适用）→ 数据抽读和资产核对 → 优雅卸载JuiceFS →
精确卸载ext4/detach唯一loop → 删除唯一backing/空目录 → 对象回归 → OSD/TiKV compact cooldown →
下一cell。原挂载900秒不排空时先取证，再按§3.3执行同cache-dir恢复；恢复严格归零后才能进入上述
清理顺序，恢复失败则停止并保留。禁止通过重建卷、pool或layout恢复起点。

实现性脚本bug可以自主修复，但一旦正式cell开始，修改驱动/分析器即使当前阶段失效；保留事故证据、
换RUN_ID并重过Gate。控制变量、矩阵、判据或安全范围不得自主修改。

### Phase III：复算、报告和生命周期收口

执行方只交raw、逐门PASS/FAIL和append-only `incidents.tsv`，不计算最终效应、不挑轮次。第二方从
持久化raw独立复算§四全部字段，生成五档配置表和正式报告：

```text
doc/perf-report/04-tmp2h-randrw-shared-cache-budget-allocation-<日期>.md
```

报告经第二方签收后，同步更新`doc/deploy-log/results-table.md`和04阶段任务状态文档；
签收前不得先把工程观察写成正式结论。

公共证据每RUN只回传一次，cell只增量回传。源端/本地SHA256、文件数、manifest和归档可读性均通过
后才能清远端副本；证据清理与环境资产恢复分开。末步按上述skill逐条复核执行合规。

**停点2：** 回传完整证据、独立复算、环境恢复和结论，任务结束。

## 六、安全红线

1. 禁止修改或重启WekaIO、K8s、网卡、内核、Ceph/TiKV服务及非本RUN进程；禁止157全局
   `drop_caches`；参考`/mnt/juicefs`只读冻结，不在其上执行卸载。
2. 特权写仅限预先列出的RUN专属目录、唯一backing/loop/ext4、精确OSD compact和本RUN scrub lease；
   禁止裸盘mkfs、`losetup -D`、force/lazy umount、递归`rm/chown/chmod`、pool/volume删除或重建。
3. 所有目标必须非空、绝对、非根、非符号链接并匹配`04tmp2h-<RUN_ID>-<CELL>`；loop必须通过backing
   反查且唯一后才能mkfs/detach。
4. 禁止把raw与rawstaging分挂两个文件系统；禁止直接删除staging文件；排空异常按已验证恢复路径处理。
5. 不创建、不删除、不改变128个测试文件的大小；任一文件缺失或size/inode异常立即停止。
6. 非预期Ceph health、PG非active+clean、未知scrub flag、外来fio或宿主空间不足立即停止；只允许
   `noscrub,nodeep-scrub`造成的精确预期WARN，其他WARN不能吞掉。
7. 失败先只读取证并优先恢复本RUN全局scrub flag；未获明确授权不得自行清理现场。最后一份raw未
   持久化和校验前不得删除。

## 七、修订记录

| 日期 | 内容 |
|---|---|
| 2026-09-05 | 初版：三步测randrw读端点、写端点和五档固定总空间下的动态共享策略。 |
| 2026-09-05 | 审核订正：端点近邻交错；每档必测P50、再自适应补P25/P75；删除T128跨档外推；冻结在线/最终噪声门、写后状态返回、缓存判档能力边界和900秒恢复分支。 |
| 2026-09-05 | RUN `20260905-234947` 离线Gate与只读inventory通过；脚本就绪，等待一次性sudo授权后执行。 |
