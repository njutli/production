# 04-3a 任务书：A2a 元数据状态规模联合效应 feasibility 与正式 sweep

## 日期：2026-08-30

> 实验编号：**A2a**；04 阶段第三份任务书（A 线第二步）。
>
> 面向：GLM 分阶段执行；GPT 负责 Gate 0、feasibility 审核、正式矩阵授权、独立复算与签收。
>
> 当前状态：`PARKED_ARCHITECTURE_RESEARCH / DO_NOT_PREPARE_SCRIPTS / NO_ENVIRONMENT_AUTHORITY`。
> 本文仅保留实验逻辑和安全边界供未来复活；当前不准备生成器、脚本或Gate，也**不授权**生产画像
> 导出、临时集群、layout、metadata生成、生产TiKV停启、sudo或fio。
>
> 承接：`doc/perf-analysis/04-metadata-architecture-and-layout-plan.md` §6.4--6.6、
> `doc/perf-tasks/04-2-hcl-native-vs-nested-attribution.md`、
> `doc/perf-tasks/TODO-cluster-changing-experiments-after-stage03.md` C01b。
>
> 口径订正：本任务书覆盖 TODO C01b 中“元数据规模/region 数是一个单变量”以及
> “Ceph pool 活对象数可代表元数据条目”的旧表述。Ceph 对象是数据面对象，只能作
> seed/GC return 安全门；A2a 是**元数据规模档位引起的 TiKV 服务状态联合效应**，
> 不是 region 单因素实验。本文中的“规模”专指正式 arm 开始前已经存在的**存活逻辑元数据**，
> 不等于固定文件集反复覆盖写所积累的 MVCC/SST/compaction 运行历史。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/fixtures/known-defect-classes.tsv`、`skills/TESTING-GUIDE.md`、
> `skills/test-commands-reference.md`、`skills/LONG-RUNNING-TEST-SKILL.md`、
> `skills/baseline-reproduction-skill.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。

```text
EXECUTION_STATE=PARKED_ARCHITECTURE_RESEARCH
EVIDENCE_LEVEL=L0_OFFLINE(feasibility) → L1_SCREEN(S0/S100) → L2_FORMAL(conditional)
SCREEN_SOURCE=本任务独立的 S0/S100/S100/S0 四臂；历史 H→fresh 只作先验
SCREEN_CONTINUE=两个跨臂对均指向 S100 下降且两对算术平均损失≥10%，或有同向材料机制信号
SCREEN_STOP=两个跨臂对均在±10%内且无同向机制信号；只表示不升级，不表示无效应
FORMAL_MATRIX=S0,S100,S100,S25,S0,S50,S50,S0,S25,S100,S100,S0（独立新 RUN）
ESTIMATED_WALL_CLOCK=Phase F 动态标定；L1=4 arms；L2=12 arms+恢复，禁止在标定前猜总小时数
```

---

## 挂起决定（2026-09-03，覆盖后文原排期）

04-2已经完成存储形态拆分：fresh原生ext4与同盘nested-loop/ext4调整均值为
`4121.22/3933.97 MiB/s`，名义差`-4.54%`但低于`8.45%`同臂噪声；历史TiKV锚点又出现
`4072.58→1417.99 MiB/s`、`D_H=96.70%`的严重漂移。因此此前`+25%--30%`只能保留为不稳定的
历史组合现象，不再要求本任务把它逐项“对账”拆完。

本任务即使确认逻辑元数据规模影响randwrite，也只能为TiKV扩容、namespace拆分或架构容量规划提供
依据；业务元数据规模和集群起点不能作为当前生产调优参数直接干预。考虑生成生产画像、构造四档
snapshot、维护窗口、4臂筛选及条件12臂矩阵的成本，当前投入不能形成同量级的可交付配置收益，故挂起，
并且**不阻塞04-6及04阶段结束**。

仅在以下任一业务触发条件成立后，才允许先修订本文再复活：

1. 生产出现可重复的“随逻辑元数据规模增长而持续退化”，需要给出容量边界；
2. 已决定评估TiKV扩容、namespace拆分或元数据迁移，需要规模—服务率模型作为投资依据；
3. 已有独立可重建环境和明确维护窗口，且业务明确要求完成历史组合差的架构归因。

复活仍从Phase F开始并重新审核生产画像、容量、墙钟和安全计划；不得把本文当前内容当作执行授权。

---

## 计划线（冻结）

```text
04-2 / A1：先拆 H/C/L，签 nested-loop 效应与 H→fresh-native 组合差
  ↓
04-3a Phase F：只做真实元数据生成器、容量、时长、snapshot 合同  ← 当前挂起，复活后从此开始
  ├─ 生产端点不可达：签 feasibility 负结论，不跑性能
  └─ 端点可达：冻结 S0/S25/S50/S100 四个 immutable snapshot
        ↓（必须重新讨论并授权）
04-3a L1：S0/S100/S100/S0 四臂低成本端点筛选
  ├─ 无升级信号：保留工程观察，不占用 12 臂维护窗口
  └─ 有信号/模糊：回传审核，只有重新授权才升级
        ↓
04-3a L2 Formal：独立新 RUN 跑 12 个 fresh restore arm
  ├─ 有可复现规模信号：评估 04-3b region 单因素是否可做
  ├─ 无材料信号：转向历史/fresh 残差与事务/LSM 插桩
  └─ 分辨力不足/端点不代表生产：保留覆盖范围，不外推
        ↓
04-4 / M1：按证据给事务架构与 TiKV 扩容方向排序
```

一句话任务：先证明能以真实 JuiceFS 语义构造并恢复接近生产规模的不可变逻辑元数据状态；
再回答：**在相同 B256 高写入负载下，预先存在的逻辑元数据规模越大，是否会减少 TiKV
服务余量、加快本轮 compaction debt 积累并降低 randwrite 性能。**

边界一句话：**04-3a 测试“逻辑元数据规模是否会放大产生速度高于清理速度时的性能问题”；
它不直接测试运行历史债务本身。**

---

## 〇、背景与推断边界

### 0.1 已知事实

- H→fresh 的观察组合差约 `+25%--30%`，远大于介质 `0%--3%` 和 logs 隔离 `+5.05%`；
- 生产 TiKV 历史盘点约为每 store `2485` regions、used size `15.42/17.53/17.54 GiB`；
- 03-22 seed dump 约为 seed 级小 namespace，不能代表生产元数据规模；
- B256 一轮可重新建立约 `11--16 GiB` pending compaction，轮内软排队不依赖跨日旧状态；
- 当前随机写约 `12K` logical meta commits/s，`6250 MiB/s @256KiB` 约需 `25K/s`。

固定文件集上的覆盖写不会持续增加 inode/dentry 数量，但会不断提交新的 slice 版本并更新
TiKV；旧版本、SST 与 compaction debt 由后台异步回收。因此必须把“存活逻辑元数据有多大”
和“同一逻辑元数据经历了多久的覆盖写历史”分开。

上述数字是设计先验，执行时必须动态重采；尤其不能把 `2485`、`17 GiB` 或 `2.43M`
写成永久常量。

### 0.2 A2a 操纵什么、不操纵什么

用三层状态理解本任务：

| 层 | 本任务如何处理 | 含义 |
|---|---|---|
| **X：预存逻辑元数据规模** | **主动改变**：`S0/S25/S50/S100` | arm 开始前已经存在的 inode/dentry/chunk/slice/xattr 与应用 key/value 规模 |
| **Y：跨轮运行历史债务** | **主动重置**：每 arm 使用 fresh FS、fresh TiKV 和 immutable snapshot | 不让旧 MVCC 版本、旧 SST/compaction debt 与规模档位共线 |
| **Z：本轮新生债务** | **同负载产生并观测**：每 arm 运行完全相同 B256 | 比较不同预存规模下，本轮 pending/compaction、事务延迟与带宽如何演化 |

换言之，S100 不是把同一批文件多覆盖写几轮得到的“老状态”，而是正式 I/O 开始前就已构造好的
大逻辑命名空间；S0 与 S100 在正式 arm 中都从 fresh 引擎起跑，并承受相同的 180 秒 B256。

A2a 的操纵量是四个冻结的**逻辑元数据规模档位**。随着规模变化，以下状态会共同变化：

- JuiceFS inode/dentry/chunk/slice/xattr 等真实记录的数量和序列化字节；
- TiKV key/value 数、逻辑/物理字节、region/leader 数；
- RocksDB SST/level/file/compaction 形态和 scheduler/Raft 工作量。

因此 A2a 能签的是“在本生成画像和固定台架下，规模增长引起的联合效应”。除非后续 A2b
保持逻辑内容/规模不变而只改变 region，A2a **不得**声称 region 数、LSM 层数、compaction
或 fresh RocksDB 中任一项是单独原因。

A2a 也不得声称已经回答“固定逻辑规模下，覆盖写运行越久是否越慢”或“原地 GC/compact 能恢复
多少”。这两个问题需要另立固定 K/B、只改变 `fresh → aged → cleaned/reloaded` 状态的实验。

### 0.3 本任务不做的事

1. 不用随机大 key、padding value 或直接 TiKV raw put 冒充 JuiceFS 元数据；
2. 不把 Ceph `juicefs-data` pool objects 当元数据规模自变量；
3. 不把生成阶段的任意性能数字当正式结果；
4. 不在一个 RocksDB 上依次跑 S0→S25→S50→S100 性能，从而把轮序和积累状态共线；
5. 不通过增加覆盖写轮数构造 S25/S50/S100，禁止把“逻辑规模”和“运行历史债务”混成同一变量；
6. 不因某个 region 数与 BW 相关就直接启动 TiKV 扩容采购；
7. 不承诺覆盖真实生产的全部 key mix、访问历史和 LSM aging；未覆盖部分必须留作残差。

---

## 一、唯一判定问题与估计对象

### 1.1 唯一正式问题

> 在二进制、NVMe nested-loop 存储拓扑、TiKV 配置、B256 工作路径、immutable data seed、
> fresh restore/clone/GC 流程和正式窗口全部固定时，从 seed 级增加到接近生产的逻辑
> JuiceFS 元数据规模，是否会减少 TiKV 可用于本轮前台同步事务与后台清理的服务余量，
> 使 compaction debt 增长更快或更大，并使 randwrite 有效带宽和同步事务服务率出现
> 可复现、材料性的下降？

主估计量是 `S100` 相对 `S0` 的调整后带宽损失。S25/S50 用于判断方向、非线性和机制轨迹，
不替代端点对照。

### 1.2 结论适用范围

正式 replicate 是“从同一 immutable snapshot 恢复出的 fresh 运行实例”，不是四次独立生成的
生产元数据。结论只适用于本次冻结的 key mix/目录树/clone 结构和台架；报告必须列明生产画像
覆盖率，禁止外推为所有 JuiceFS namespace 的普遍规律。

正结论只能表述为“较大的**预存逻辑规模**在相同 B256 下放大了服务率/债务问题”；负结论也只能
排除本次覆盖范围内的逻辑规模材料效应。二者都不能证明或否定固定规模下的运行历史债务效应。

---

## 二、规模坐标、生成器和快照合同

### 2.1 生产参考画像 P

Phase F 前先构造只读、聚合、脱敏的生产画像 `production-metadata-profile.json`：

| 维度 | 必须记录 | 来源与边界 |
|---|---|---|
| JuiceFS 逻辑记录 | inode、directory entry、chunk、slice、symlink、xattr 等计数和序列化字节 | 优先使用已存在且日期/UUID可验证的只读 dump；若需新导出，必须单独评估只读负载并授权 |
| key/value 画像 | 主要应用 key 前缀的 count、key bytes、value bytes、value-size histogram | 只允许对经批准的只读 snapshot/checkpoint 或官方只读导出解析；不在生产 TiKV 上做无界 raw scan |
| TiKV 逻辑/物理状态 | 每 engine/CF live bytes、total SST bytes、files/level、pending、region/leader/store size | PD/TiKV API/Prometheus/engine property 原文；指标名先实查 |
| 数据面 | pool objects/stored/max_avail | 只作 seed/GC/容量边界，不进入元数据规模坐标 |

生产路径名、用户信息和业务名称不得进入报告；只保留聚合计数、分布、UUID 哈希和原始证据 SHA。
若无法在安全负载下获得逻辑画像，记 `PRODUCTION_SCALE_REFERENCE_UNAVAILABLE`，不得用
`store used size` 或 Ceph 对象数单独替代后继续正式矩阵。

画像还应回答“生产的**存活逻辑 K/B**相对 seed 有多大差异”，以便说明本实验实际覆盖的逻辑规模
范围；即使生产 store used、SST 或 region 很大，也只能说明运行历史/物理状态不同，不能把它们
当成存活逻辑规模，或据此声称 S25/S50/S100 已代表对应的生产规模。

### 2.2 规模坐标

定义：

```text
K = JuiceFS application metadata record count（排除 PD/TiKV 系统键）
B = 对应 key bytes + value bytes 的逻辑总量
K0/B0 = formal seed snapshot 的值
KP/BP = 生产参考画像的值
target(Sq) = S0 + q × (P-S0), q ∈ {0, 0.25, 0.50, 1.00}
```

四档固定为 `S0/S25/S50/S100`。快照接受门：

- `K` 距目标 `≤5%`；`B` 距目标 `≤10%`；
- 生产占比 `≥1%` 的主要应用前缀，在 S100 中 count share 绝对差 `≤10 pp`；
- B256 source/target contract 在四档完全相同；
- 无 raw put、任意 padding key/value、运行时随机目录深度或未冻结 generator seed；
- 实际 region/store、store used、SST/level 只记录，不为了“凑 2485”临场改 split 参数。

若 `K/B` 达到 S100 但 region/store 与生产差超过 `±20%`，快照仍可用于逻辑规模实验，
但必须附 `S100_REGION_ENDPOINT_NOT_MATCHED`，禁止把结果外推成“生产 region 规模效应已闭合”。

### 2.3 真实语义生成器

生成器只能通过锁定 JuiceFS 二进制和公开文件系统/CLI 语义构造状态，例如：

- 固定模板目录和空文件层级；
- 对 immutable B256 seed 的 metadata clone，用共享数据引用增加真实 inode/dentry/chunk/slice 记录；
- 仅在生产画像确有对应占比时生成固定 xattr/symlink/rename 结构；
- 所有操作数、目录深度、batch size、并发数和随机 seed 在生成前写入 manifest。

生成器不得直接写 TiKV key，也不得通过大量真实数据写入来“顺便增加元数据”。正式数据面只允许
一次 128 GiB seed layout；规模 ballast 应优先复用 seed object 引用。Phase F 必须实测每个生成动作
对 K/B、region、Ceph objects/stored 和墙钟的增量，证明对象增量与设计一致。

### 2.4 immutable snapshots

按 `S0→S25→S50→S100` 单调生成只用于降低准备成本；每到目标立即 graceful quiesce、dump 并冻结：

- metadata dump path/mode/bytes/SHA256、UUID、Name；
- K/B、key prefix/value-size profile、region/leader、store/CF/LSM 状态；
- 256 source path/size/inode/anchor manifest；
- generator manifest 和累计操作计数；
- Ceph seed objects/stored、无 leaked/pending/skipped 的 GC check-only；
- 在独立 fresh canary cluster 中 load→mount→clone→read anchor→umount 的可恢复性证明。

正式阶段只 load 这些已冻结 dump；禁止再次生成、修补、增删 ballast 或改变档位。

---

## 三、筛选/正式台架与固定量

### 3.1 存储拓扑

正式台架固定采用 A1 的 **L / NVMe-backed loop/ext4 shared** 形态：每节点一个实际预分配
backing/loop/ext4，KV、WAL、Raft 共用。理由是可以对每 arm 精确 mkfs 并恢复空本地 FS；
A1 的 C↔L 结果用于标注外部可比性，不改变 A2a 内部的 scale 因果识别。

backing 大小不在本文猜死。Phase F 后按以下公式生成 proposal，再由用户审核：

```text
ROLE_BYTES >= 2 × (S100 fresh used bytes + B256 observed peak pending/temporary bytes + 16 GiB)
ROLE_BYTES 向上取整到 32 GiB
创建后每节点生产 ext4 仍保留 ≥512 GiB reserve
```

不得降低 reserve、改 sparse、借系统盘/Ceph OSD 盘或只做部分节点。无法满足即
`SCALE_ENDPOINT_NOT_FEASIBLE`。正式 L 会占用生产 TiKV NVMe，因此生产 TiKV 必须按 A1 同级计划
停止；不得让二者并发争用。

### 3.2 二进制和 B256

- 二进制固定为 U1 已批准的 `/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`；所有生成/load/mount/GC/fio 使用同一 exact binary；
- mount：`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；私有 msgr=8；
- fio：randwrite、256 KiB、256 jobs/inodes、iodepth 64、runtime 180s、固定 256 slot/randseed；
- 每 arm 从对应 scale snapshot load，`clone -p` 固定 B256 source 到 `/test_dir`，只写 target；
- 正式窗为 actual timed-I/O `[15,175)`，重叠加权汇总 256 logs，W1--W4 各 40s；
- 每 arm fresh PD/TiKV data dir、FS、token、metadata URL；不在同一 RocksDB 上原地复用。

### 3.3 L1 端点筛选（只决定是否值得跑长矩阵）

在 Phase F 完成且 S0/S100 端点合同通过后，先用独立 `SCREEN_RUN_ID` 跑：

```text
S01=S0, S02=S100, S03=S100, S04=S0
```

- 四臂与正式 arm 使用同一 B256、fresh restore、GC/恢复和最小真值集；
- 只采 `CORE`（身份/health/log/容量/起点）与与问题直接相关的 `MECHANISM`
  （logical commits/s、transaction latency、pending/compaction、NVMe await）；
  其他 `DIAGNOSTIC` 指标按异常触发，不为筛选每轮全量采集；
- 定义两个方向对 `loss_1=1-BW_S02/BW_S01`、`loss_2=1-BW_S03/BW_S04`；
  `screen_loss=(loss_1+loss_2)/2`，同时报 S02/S03 同臂差与 S01/S04 首尾漂移；
- `SCREEN_CONTINUE`：`loss_1>0 && loss_2>0 && screen_loss>=10%`，或两个 S100 都出现与
  服务余量降低一致的材料机制信号；
- `SCREEN_STOP`：`abs(loss_1)<10% && abs(loss_2)<10%` 且无一致机制信号；
- 其余为 `SCREEN_AMBIGUOUS`，由 GPT 根据 raw 决定是否值得升级，不得由执行方挑点。

“材料机制信号”也在 L1 前冻结：两个 S100↔S0 方向对中，以下三项至少两项均同向超过 `10%`：
`logical commits/s` 下降、transaction service duration 上升、正式窗 pending-compaction 净增量上升。
单个指标单点、看数据后新增指标或只在一个方向对中出现的变化均不算过门。

L1 的四臂不进入正式效应量，也不能签“规模无效”。无论是否升级，都先完成
生产 TiKV、pool/seed 与临时存储恢复后停止；不能让生产在人工审核期间保持停机。

### 3.4 L2 正式 12 臂顺序

```text
R01=S0
R02=S100
R03=S100
R04=S25
R05=S0
R06=S50
R07=S50
R08=S0
R09=S25
R10=S100
R11=S100
R12=S0
```

性质：

- S0 与 S100 各 4 个 fresh replicate，S25/S50 各 2 个；
- 四档的占位均值均为 `6.5`；S0 和 S100 的中心化二次矩也相同；
- S100 有 `(R02,R03)`、`(R10,R11)`，S50 有 `(R06,R07)` 三个同档相邻零效应对；
- 端点对时间一阶和二阶漂移平衡，主估计不依赖中间档位置；
- 禁止缺臂补跑、按性能调换顺序或只跑端点后“视情况”追加中间档。

### 3.5 每 arm fresh 与回归合同

每个 arm 必须：fresh local FS→fresh cluster→load immutable scale dump→mount/clone→pre-gates→
B256→graceful umount→wait≥65s→stop→独立 fresh GC namespace load**同档 snapshot**→check-only→
授权 delete 本轮 leaked objects→seed/pool/local return。上一 arm 未闭合不得启动下一 arm。

不同档位可引用同一 underlying immutable data seed，但 GC 必须用当前档 snapshot 判断 valid objects；
禁止用 S0 metadata 清理 S100，从而误删 S100 仍引用的对象。

### 3.6 scrub 分级口径

- **L1 筛选保持 scrub 开启**：不为工程筛选修改全局 flags，但每个正式窗必须保存
  PG state/epoch 并判定 scrub/deep-scrub 是否重叠。任一重叠记 `SCREEN_ENV_SCRUB_OVERLAP`，
  不允许换 label 补点；四臂仍安全收口后交 GPT 判为 screen ambiguous/invalid。
- **L2 正式矩阵预注册暂停 scrub**：使用独立 state-driven lease 同时设置
  `noscrub + nodeep-scrub`，只恢复本 lease 自己增加的 flags。设置前冻结 FSID/原 flags/
  health/逐 PG，等待已运行 scrub 退出，每 arm 仍证明无 scrub；成功、失败或 SSH 中断均优先
  精确 restore。该全局操作必须在维护计划中单列时长/风险并取得用户单独授权；
  它不是生产交付配置。

---

## 四、预注册数据源、指标和统计

### 4.1 每 arm 数据源

| 组 | 原始文件 | 字段/计算 |
|---|---|---|
| BW | 256 per-job BW logs、fio stdout/JSON | actual start；重叠加权 1s；正式窗 mean/median/CV/P10/P90、W1--W4 |
| 规模身份 | `scale-contract.json`、dump SHA、runtime profile | K/B、prefix/value-size、UUID、region/leader、store/CF bytes；必须等于冻结档位 |
| 客户端事务 | `.stats` 或实查 endpoint 原始累计值 | meta Write、transaction、PUT、fuse write 的 sum/count/total 增量及 logical commits/s |
| TiKV scheduler/Raft | 三 endpoint Prometheus 原文 | prewrite/commit/storage async/Raft commit/sync sum/count、write flow |
| LSM/compaction | Prometheus + engine properties | pending、compaction read/write、L0/files/bytes、stall reason/time；按 W1--W4 |
| 本地 NVMe | 三节点区间 iostat/PSI/SMART只读 | await/util/aqu-sz/throughput/PSI；SMART只用于温度/状态，不写设备 |
| Ceph | health、pool TSV、6 OSD perf/admin socket | data objects/bytes 和 GC return；OSD op/kv_sync 作机制，不作规模变量 |
| 身份/覆盖 | PID/starttime/exe/config/path/findmnt、sampler heartbeat | 非性能有效性门 |

Phase F 必须实查所有指标名和单位，冻结 `metric-contract.tsv`。不存在的字段明确写 NA 并在正式授权前
决定是否影响问题；禁止运行中换名字相似指标或填零。

### 4.2 主模型

使用正式窗 mean MiB/s，模型固定为：

```text
BW_i = β0 + β25·I(S25) + β50·I(S50) + β100·I(S100)
       + β1·x_i + β2·x_i² + ε_i
x_i = round_i - 6.5
loss_100_pct = -100 × β100 / adjusted_mean_S0
```

正值 `loss_100_pct` 表示元数据规模增长后带宽下降。报告 β、双侧 95% CI、调整均值、逐 arm
原值和实际 K/B/region/store used。中间档只作轨迹，不把四档强行拟合为线性。

同档噪声底：

```text
ε = max(relative_delta(R02,R03), relative_delta(R06,R07), relative_delta(R10,R11))
M = max(10%, 2ε)
```

- `10%` 是 A2a 对 H→fresh `25%--30%` 组合差具有决策价值的材料线；
- 若 `ε≥10%` 或 `loss_100_pct` CI 半宽 `>5 pp`，记 `RESOLUTION_INSUFFICIENT`；
- 不得因 BW/CV/延迟差而删 arm；只有 §4.4 非性能门可判 invalid。

### 4.3 机制一致性只用于解释

报告必须并列展示随档位变化的：logical commits/s、transaction latency、prewrite/commit、Raft sync、
pending/compaction flow、SST/level、region/leader、NVMe await。它们用于区分候选路径并决定 A2b/M1
优先级，但都不是 A2a 的独立处理变量。

pending 与 compaction 必须按 W1--W4 展示起点、终点、`W4-W1` 和正式窗趋势，用来回答：在完全
相同的 B256 产生速率下，S100 是否比 S0 更快或更多地积累**本轮新生债务**。这些指标只解释
“预存逻辑规模是否放大问题”，不得命名为跨轮历史债务效应。

即使 BW 与 region 高相关，也只能写“与规模档位同向”；即使 region 不变而 LSM 变化，也不能在
未正交操纵前签 LSM 单因素。

### 4.4 非性能有效性门

任一项失败使 arm/RUN `EVIDENCE_INVALID`：

- snapshot SHA/UUID/K/B/prefix 合同错，或档位标签与实际 dump 不符；
- seed/source/clone identity/anchor 错，目标文件数/size/inode/extent/seed 错；
- production 与 temporary TiKV 并发；路径、loop、mount source、FS UUID、配置、二进制错；
- store/health/capacity/memory/swap 失败，fio rc/err/I/O error，256 logs/覆盖不足；
- sampler 缺失/提前退出、actual start 无法反推、counter 单位/回绕无法处理；
- 前一 arm GC/seed/pool/local baseline 未回归；正式脚本/manifest 变更；矩阵缺臂/重臂；
- 未授权环境写、raw TiKV put、额外 layout、pool delete/create、OSD restart 或生产路径写入。

CV、W4/W1、pending、latency、await 是性能/机制结果，不是删样本门。

### 4.5 VERDICT

| 条件 | VERDICT | 后续 |
|---|---|---|
| Phase F 无安全生产参考 | `A2A_PRODUCTION_SCALE_REFERENCE_UNAVAILABLE` | 不跑正式；先解决画像来源 |
| 生成时间/容量无法达到 S100 | `A2A_SCALE_ENDPOINT_NOT_FEASIBLE` | 报已覆盖范围，禁止低档外推 |
| K/B 达标但生产 key mix/region 代表性不足 | `A2A_ENDPOINT_NOT_REPRESENTATIVE` | 可作局部实验，不能闭合生产残差 |
| 非性能门失败/缺臂 | `A2A_EVIDENCE_INVALID` | 只保留工程观察 |
| 噪声或 CI 超分辨力 | `A2A_RESOLUTION_INSUFFICIENT` | 只给上界，不宣告无效应 |
| `loss` CI 下界 `>0` 且点估计 `≥M` | `A2A_MATERIAL_SCALE_SIGNAL` | 评估 A2b 可行性；不直接归因 region |
| `loss` CI 上界 `<10%` | `A2A_NO_MATERIAL_SCALE_SIGNAL_IN_RANGE` | 保留覆盖范围；转历史/fresh残差与事务/LSM插桩 |
| 其余 | `A2A_INCONCLUSIVE_OR_NONMONOTONIC` | 报逐档原值，不启动 A2b |

是否启动 A2b 还要求“同一 snapshot 逻辑内容不变、region 可独立操纵”的可行性证明；
`A2A_MATERIAL_SCALE_SIGNAL` 本身不是 A2b 执行授权。

`A2A_NO_MATERIAL_SCALE_SIGNAL_IN_RANGE` 只表示本画像范围内未发现“预存逻辑规模的放大效应”，
不表示覆盖写历史、MVCC/SST aging 或清理债务对性能无影响；后者不在本任务估计对象内。

---

## 五、阶段 0：离线 Gate 0（GPT；禁止连接环境）

### 5.1 Step 0 方法论确认

GLM 必须通读抬头七份文档，在 `methodology-ack.tsv` 记录 SHA/时间/身份，重点确认：
真实 I/O 起点、非性能门/性能端点分离、四态状态机、fresh 四层、禁止补样、第二方复算、
生产安全与阶段停点。未确认不得 inventory。

### 5.2 待实现脚本

```text
scripts/FULLBASELINE/debug/s04a2a-profile.py
scripts/FULLBASELINE/debug/s04a2a-generator.sh
scripts/FULLBASELINE/debug/s04a2a-snapshot.sh
scripts/FULLBASELINE/debug/s04a2a-inventory.sh
scripts/FULLBASELINE/debug/s04a2a-storage.sh
scripts/FULLBASELINE/debug/s04a2a-cluster.sh
scripts/FULLBASELINE/debug/s04a2a-seed-clone-gc.sh
scripts/FULLBASELINE/debug/s04a2a-run-arm.sh
scripts/FULLBASELINE/debug/s04a2a-driver.sh
scripts/FULLBASELINE/debug/s04a2a-analyze.py
scripts/FULLBASELINE/debug/s04a2a-gate0-offline.sh
scripts/FULLBASELINE/debug/s04a2a-mock-integration.sh
```

生成、snapshot、存储、生产停启、集群、fio、GC 必须分脚本；任何 destructive action 先有纯 plan。

### 5.3 Gate 0 最低断言

1. `known-defect-classes.tsv` 适用项全部覆盖；语法、编译、单测、明文口令扫描；
2. profile parser 对空/截断/重复/未知版本/敏感路径泄漏 fail closed；系统键与应用键分类 fixture；
3. 生成器只能输出冻结的 JuiceFS 操作，不含 raw TiKV put；操作数溢出/负值/动态随机拒绝；
4. S0/S25/S50/S100 K/B 容差、prefix share 和端点算法 fixture；不得用 store used、region 或
   Ceph objects 替代逻辑 K/B；
5. snapshot dump/UUID/Name/SHA/mode、四档唯一性、错标签/错 SHA/不可恢复拒绝；
6. L1 `S0,S100,S100,S0` 与 L2 12 臂各自的 count/顺序/占位/同档对；
   筛选与正式 RUN_ID/目录/分析输出必须隔离，缺臂、重臂和顺序变化失败；
7. 256/255/重复/截断 BW logs、actual start、重叠重采样、±1s/+58s 敏感性；
8. analyzer 在 03-22b/c 历史原始 fixture 上复现已知窗口、CV、W4/W1，证明不读 fio summary；
9. fresh FS/token/data dir/metadata URL、seed/clone/GC/current-scale 绑定，S0 清 S100 必须拒绝；
10. production/temp 并发、生产路径 overlap、wrong loop/backing/mount、sparse、容量/reserve 失败；
11. 部分 state/失败 destroy 只能输出精确 plan；禁止 `rm -rf`、bulk loop detach、lazy/force umount；
12. sampler、counter 回绕/缺失、wait/PIPESTATUS、JSON stdout/stderr 分离和超时；
13. 没有 `SCREEN_MATRIX_AUTHORIZED.tsv` 时必须拒绝 L1 fio；没有独立
    `FORMAL_MATRIX_AUTHORIZED.tsv` 时必须拒绝 L2 fio；两个 ACK 不得通用；
14. scrub fixture 覆盖 L1 observe-only 与窗内 overlap，以及 L2 lease ownership、部分 pause、
    foreign flag、唯一 WARN 和失败优先 restore；L1 driver 出现 set/unset 命令必须 Gate 0 FAIL；
15. mock 走通 `profile→generate→4 snapshots→restore canary→STOP`、L1 四臂三种 screen verdict
    与恢复闭环，以及独立 L2 正式 12 臂/失败恢复闭环；
16. 同 RUN 热修、补样、覆盖 incident/归档、改变 scale snapshot 或生成器 manifest 全部拒绝。

Gate 0 通过后仍只允许进入经批准的只读 Phase I。

---

## 六、阶段执行与停点

### Phase I：只读生产画像和正式资源 plan

先只读确认：U1 二进制、A1 结论/路径、生产 TiKV/PD/Ceph 指纹、可用容量、region/leader/store/CF、
已有 metadata dump 是否存在且可验证、画像导出的命令和负载上界。只输出 profile plan 和所有 sudo/
stop/start/create/destroy plan，不执行。

若需要新生产 dump 或 checkpoint，必须把预计读取量、时长、CPU/IO限额、输出路径、权限、停止条件
单独回传并授权；禁止默认把“只读”理解为“无性能影响”。

输出 `PROFILE_PLAN_PASS`、`FORMAL_STORAGE_PLAN.tsv`、`maintenance-budget.tsv` 后暂停。

### Phase F：非性能 feasibility（独立授权；禁止正式 fio）

建议先在独立 RAM-backed 临时 PD/TiKV 台架生成快照，从而不占用生产 TiKV NVMe，也不停止生产
TiKV；但仍须性能独占、端口隔离和 Ceph seed/GC 计划。若执行前决定其他介质，必须先修改/复审
任务书状态，不能临场切换。

Phase F 阶段内完成：

1. 取得经批准的生产聚合逻辑画像，与 S0 比较 K/B/key mix，明确本实验实际覆盖的逻辑规模范围；
2. 小数据 generator semantic canary；核对真实 key 前缀/value-size 和 Ceph 增量；
3. 一次 formal data seed layout，冻结 256 source/anchors；
4. 按 S0→S25→S50→S100 生成并 dump，记录每档墙钟、K/B、region/store/LSM、容量；
5. 每个 snapshot 在独立 fresh canary 中 load/mount/clone/read/umount；不跑 randwrite；
6. 估算正式 ROLE_BYTES、每 arm 生命周期、12 arm 总维护时长和失败恢复余量；
7. 保存所有 snapshot 双份 SHA，并使 data seed 对象保持可恢复；不执行 final destroy。

到此**强制暂停**。执行方回传原始画像、snapshot 合同、容量/时长 proposal 和 incidents；不得算
scale→BW 效应（本阶段没有正式 BW）。GPT/用户决定：端点是否代表生产、是否值得长维护窗口、
是否调整任务书后另起正式 RUN。

### Phase II：L1 端点筛选与完整恢复（条件授权）

仅在 Phase F 签 `FEASIBILITY_PASS` 且用户批准筛选维护窗口后：

- 冻结 4 snapshot、生成器已停且正式阶段不可再改；
- 逐节点 stop 生产 TiKV，不停生产 PD；
- 创建一个筛选专用 L working backing/loop，做全生命周期 smoke；
- 四档各做零正式写 restore/clone preflight；
- 运行一次不入矩阵的容量 canary，校准 S100+B256 headroom；
- 生成并核验 `SCREEN_MATRIX_AUTHORIZED.tsv`，按 §3.3 跑完四臂，执行方只交 raw 与门清单；
- 无论 `SCREEN_CONTINUE/STOP/AMBIGUOUS`，均立即完成临时资源清理、pool/seed 回归和生产
  TiKV 恢复签收；禁止为等待审核保持生产停机。

到此强制暂停。GPT 独立复算 screen verdict；L1 不产生 scale 正式效应量。

### Phase III：L2 独立正式矩阵（需重新授权）

只有 GPT 复算为 `SCREEN_CONTINUE`，或 `SCREEN_AMBIGUOUS` 经用户明确认为仍具决策价值时，
才使用新 RUN_ID 重做 production stop、storage/restore preflight，并生成独立
`FORMAL_MATRIX_AUTHORIZED.tsv`。L1 的四个性能点禁止并入 L2。
开始 R01 前须按 §3.6 经单独授权 pause/verify L2 scrub lease；未取得 lease ownership
或已运行 scrub 未退出时不得跑 fio。

严格按 §3.4 顺序和 §3.5 生命周期执行。阶段内部只在全部门 PASS 时自动继续；任何非性能门失败
立即停止、保留现场并走已预审的安全恢复。性能端点差不触发停机或删样。

### Phase IV：生产恢复、seed 清理和归档

无论正式 valid/invalid：先按 lease state 精确 restore scrub 并证明原 flags 回归，再停临时集群，
按当前 snapshot/UUID 精确 GC/final destroy，卸载/detach/
删除唯一 RUN backing，空间和 pool 回归；逐节点恢复生产 TiKV并签 stores 3/3、路径/config/exe、
Ceph health 和无残留。生产签收后再做 archive 和离线分析。

末步按全部 skill/guide 复核。执行方只交原始数据、PASS/FAIL 和 incidents，不算效应、不挑 arm、
不下“region/规模导致”结论。

---

## 七、交付物

```text
results/prod-stage04-raw-<date>/s04a2a-<FEAS_OR_SCREEN_OR_FORMAL_RUN_ID>/
  methodology-ack.tsv
  commands.sh
  incidents.tsv
  frozen-manifest.tsv
  production-profile/{raw,aggregate,sha256}/
  generator/{contract,operations,increment-profile}/
  snapshots/{S0,S25,S50,S100}/
  feasibility/{capacity,time,restore-canary}/
  plans/{production,storage,rollback}/
  screen/{S01,S02,S03,S04}/            # 仅 SCREEN_RUN_ID 存在
  formal/{R01..R12}/                   # 仅独立 FORMAL_RUN_ID 存在
  gc/
  production-restore/
  closure/
  SHA256SUMS
```

最终报告：`doc/perf-report/04-3a-metadata-state-scale-sweep-<date>.md`，首部必须包含：

```text
VERDICT=...
SCALE_ENDPOINT=...
PRODUCTION_PROFILE_SHA256=...
SCREEN_ARCHIVE_SHA256=...
FORMAL_ARCHIVE_SHA256=...
```

feasibility、screen 与 formal 各自有独立 RUN_ID/归档/SHA256；不得为了目录简单将 L1/L2 raw
拼成同一个可计算矩阵。若没有升级 L2，`FORMAL_ARCHIVE_SHA256=NOT_RUN`。

随后更新 `doc/deploy-log/results-table.md` 和 04 计划书。报告必须区分：随机化/平衡的正式 scale
效应、跨任务 H/C 工程参照、生产画像覆盖率、region/LSM 等共同变化量和仍未拆开的残差；还必须
明确分列“arm 前预存逻辑规模”“被 fresh 重置的跨轮历史债务”“同一 B256 正式窗内新生债务”，
禁止把三者统称为“元数据膨胀”。

---

## 八、通用注意事项与红线

1. 正式性能只认 actual I/O 起点、256 logs 重叠加权、`[15,175)`、W1--W4；summary 仅旁证。
2. feasibility 禁止性能择档；规模档只按 K/B/profile/容量冻结，不能看 BW 决定 snapshot。
3. 非性能门与性能端点分离；CV/W4/W1/latency/pending 再差也不删样。
4. 正式矩阵前四个 snapshot、生成器/脚本/二进制/配置全部哈希冻结；R01 后一字节不改。
5. 只通过真实 JuiceFS 语义生成元数据；禁止 raw TiKV 写、随机 padding、大 value 冒充规模。
6. Ceph objects/stored 只作 data seed 和 GC return；禁止将其写成元数据 entry 数或回归自变量。
7. 正式 data seed 只 layout 一次；每 arm 写 clone；不同 scale 的 GC 必须加载同档 snapshot。
8. 禁止 pool delete/create、PG/CRUSH/Ceph config/OSD restart、全局 drop_caches、额外 layout。
9. 系统 `ceph.conf`、生产 PD、生产 TiKV config/data/WAL/Raft、生产 volume/data 不得修改。
10. sudo/生产 stop/start/storage create/destroy 分层授权，只运行逐行审过的 exact plan。
11. 禁止 `rm -rf`、`losetup -D`、force/lazy umount、模式 kill、kill mount PID、reboot/shutdown。
12. 失败保留现场并 append-only 记录 incident；恢复生产优先于分析和继续试验。
13. 157 WekaIO/K8s/内核/网卡/RoCE/md0 不得触碰；foreign fio 或同池性能 RUN 存在即停。
14. 归档含实际脚本、manifest、原始 profile、全量日志、内外 SHA，支持 GPT 独立复算。
15. 执行方可修实现但不得改变量/scale/顺序/判据/路径/容量/授权；需改时停止讨论。

### 执行前仍需讨论并明确的五项

1. 生产逻辑元数据画像的安全来源、读取负载上界，以及生产↔S0 是否存在可识别的存活 K/B 差异；
2. Phase F 是否采用 RAM-backed 台架，以及 data seed 在两阶段间的保管/GC方案；
3. S100 的 K/B/key-mix/region 代表性是否足以进入正式矩阵；
4. 计算出的 ROLE_BYTES、生产 reserve、12 arm 墙钟与维护窗口；
5. A1 结论以及 U1 exact V14/可重现构建边界对外部可比性的注记。

任何一项未签字，本文保持 `NO_ENVIRONMENT_AUTHORITY`；Phase F 通过也不自动授权 Formal。

### 最终红线一句话

本任务可销毁的仅是带精确 RUN_ID、UUID、snapshot/seed state 证明的临时元数据、clone、backing/loop
和本 RUN 数据对象；**绝不能碰**生产 metadata/data、生产 PD/TiKV/Ceph 配置、任何未归属对象，
也绝不能用“需要达到生产规模”为理由绕过容量、身份、GC、维护窗口或用户授权。
