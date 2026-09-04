# 04-2 任务书：A1 H/C/L 同窗锚定——历史原生、fresh 原生与 fresh nested-loop

## 日期：2026-08-30

> 实验编号：**A1**；04 阶段第二份任务书。
>
> 面向：GLM 分阶段执行；GPT 负责离线 Gate 0、阶段间审核、独立复算和最终签收。
>
> 当前状态：`COMPLETED / EVIDENCE_VALID / PRODUCTION_RESTORE_SIGNED`。
> RUN `20260902-160000` 已按冻结合同完成；正式判定为
> `A1_CL_RESOLUTION_INSUFFICIENT`，历史锚点判定为
> `HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`。执行前的权限边界仅对该次执行授权有效，
> 不构成后续环境操作授权；结果见
> `doc/perf-report/04-2-hcl-native-vs-nested-attribution-20260902.md`。
>
> 承接：`doc/perf-analysis/04-metadata-architecture-and-layout-plan.md` §六、
> `doc/perf-tasks/TODO-cluster-changing-experiments-after-stage03.md` C01、
> `doc/perf-report/03-22b-tikv-nvme-backed-storage-attribution-20260827.md`、
> `doc/perf-report/03-22c-tikv-hybrid-ram-logs-attribution-20260828.md`。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/fixtures/known-defect-classes.tsv`、`skills/TESTING-GUIDE.md`、
> `skills/test-commands-reference.md`、`skills/LONG-RUNNING-TEST-SKILL.md`、
> `skills/baseline-reproduction-skill.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。

```text
EVIDENCE_LEVEL=L2_FORMAL（Phase I/III 只是 L0/安全 canary）
SCREEN_SOURCE=03-22b/03-22c 已给出 nested-loop 0%--3% 与 H→fresh +25%--30% 先验，足以支撑直接正式归因
SCREEN_CONTINUE=已满足；本任务的 C/L 是正式单因素闭合，不再用低精度 screen 代替
SCREEN_STOP=Phase I 容量/维护窗口不可行，或 Phase III 生产恢复安全 canary 不过
FORMAL_MATRIX=H0 → C,L,L,C,L,C,C,L → H1
ESTIMATED_WALL_CLOCK=Phase I 后依动态容量、每 arm GC/恢复与生产维护预算冻结
```

---

## 计划线（冻结）

```text
03-22～03-22c：介质效应仅 0%～3%，H→fresh 仍有 +25%～30% 组合差
U1：已锁定 exact patched v1.4.1 `24fae085...`
  ↓
04-2 / A1：H0 → 停生产 TiKV → C L L C | L C C L → 恢复 → H1  ← 你在这里
  ├─ C/L 可辨：签 nested-loop 单因素
  ├─ H0/H1 可比：签 H→fresh-native 组合差范围
  ├─ H 漂移过大：H↔C 降级，C↔L 可独立保留
  └─ 任一非性能门失败：整 RUN 无效，先恢复生产
  ↓
04-3a / A2a：元数据状态规模联合效应 feasibility 与 sweep
  ↓
04-3b（条件）：固定规模后才讨论 region 单因素
```

一句话任务：在同一维护窗口内用 H0/H1 夹住完整 C/L 八臂，分别量化 nested-loop
单因素和“历史生产状态→fresh 原生状态”的组合差，并安全恢复生产 TiKV。

---

## 〇、背景与已知边界

### 0.1 为什么要做

历史生产 TiKV 条件 H 的 randwrite 中心约为 `2880 MiB/s`，fresh 临时 TiKV 条件约为
`3608--3757 MiB/s`，观察差约 `+25%--30%`。但旧对照同时改变了：

- TiKV namespace、RocksDB/LSM/region 状态与集群起点；
- 本地路径是否经过 backing file + loop/ext4；
- RAM/NVMe 介质或 WAL/Raft 路径；
- 测试日期、生产恢复状态及临时 volume/file identity。

03-22～03-22c 已把“介质本身”压到 `0%--3%` 工程量级，并确认 WAL/Raft RAM 隔离的
带宽收益中位仅 `+5.05%`。尚未拆开的 `+25%--30%` 比这些因素大一个数量级，A1 的价值
是先把**可以正交控制的 nested-loop 层**独立签出，再给剩余组合差划清边界。

### 0.2 本任务故意不回答的事

1. 不把 `H↔C` 命名为“fresh RocksDB 单因素”；H 与 C 的元数据规模、region、进程起点、
   volume/file identity 仍不同。
2. 不重新测试 RAM/NVMe 介质，也不重新测试 WAL/Raft 隔离。
3. 不做 TiKV 参数扫描、compaction worker 扫描、更多 inode 或 `max-uploads` 扫描。
4. 不要求 A1 各项点估计机械相加等于历史 `+25%--30%`。
5. 不承诺达到 `6250 MiB/s`；本任务是归因，不是调优验收。

---

## 一、唯一判定问题与两个独立估计量

### 1.1 唯一通过/不通过问题

> 在二进制、B256 负载、Ceph 数据面、TiKV 配置和 fresh 生命周期固定时，
> `backing file + loop/ext4` 相对同一生产 NVMe 上的原生 ext4，是否产生可辨识的
> randwrite 带宽或稳定性差异？

这是 `C↔L` 的 randomized estimand，也是本任务唯一的正式因果问题。

### 1.2 必须同时报告但不冒充单因素的问题

> 由 H0/H1 夹住的历史生产 TiKV，相对同窗 fresh 原生 C，组合差的方向和保守范围是多少？

这是 `H↔C` 的 anchored engineering estimand。它只能写成：

```text
历史生产元数据/集群状态 → fresh seed级临时元数据/集群状态（原生NVMe/ext4）的组合差
```

不得写成“fresh RocksDB 提升 X%”“region 数导致 X%”或“历史积累导致 X%”。

### 1.3 H0/H1 的角色

H0/H1 不是随机化 arm，也不是两个可替代样本。它们只用来：

- 测量维护窗口、生产停启和时间漂移是否破坏 H↔C 的分辨力；
- 给 H↔C 提供区间而不是单个跨日历史点；
- 验证生产恢复后的测试路径是否回到可比较档位。

H 漂移不会自动删除证据完整的 C/L arm。

---

## 二、实验对象与冻结变量

### 2.1 三种条件

| 条件 | 元数据状态 | TiKV 本地路径 | 在设计中的角色 |
|---|---|---|---|
| **H0/H1** | 当前生产 TiKV；窗口前/恢复后各一次 | 当前 `/dev/nvme1n1` 上原生 `/mnt/jfs-tikv` | 历史同窗锚点，非随机化 |
| **C / NATIVE** | 每 arm 新 PD/TiKV、空目录、同一 immutable seed restore | `/mnt/jfs-tikv/jfs-s04a1-<RUN_ID>-c-<INSTANCE>-<NODE>` 原生 ext4 | fresh 原生臂 |
| **L / LOOP** | 与 C 同 seed、同 fresh 层级、同 TiKV 配置 | 同一 NVMe/ext4 上精确 backing file → loop → ext4 | fresh nested-loop 臂 |

生产 PD 不停止；临时集群使用独立端口、cluster token、PD data 和 metadata URL。
生产 TiKV 与任何 C/L 临时 TiKV **绝不并行运行**。

### 2.2 C/L 唯一允许的差异

C 与 L 只允许不同于 TiKV KV/WAL/Raft 数据目录是否经过 nested-loop：

- C：直接位于生产 TiKV ext4 的精确临时子目录；
- L：同一 ext4 上一次预分配的 backing file，经动态核验的唯一 loop 和 ext4 挂载；
- PD data、二进制、TiKV 配置、端口、store 数、seed dump、Ceph pool、JuiceFS 挂载参数、
  B256 jobfile、采集器、GC/reset 和等待时间全部相同。

L backing 的逻辑大小暂按 03-22b 已验证的每节点 `128 GiB` 设计，但**不是执行常量**：
执行前必须按动态 inventory、实际峰值和生产 reserve 重新审核；禁止为通过容量门改成 sparse file。

### 2.3 二进制选择规则

U1 已签 `REPLACE_APPROVED`。A1 全程固定 `/tmp/juicefs-1.4.1-patched`，MD5
`24fae0852051c80ca571cb2f20275d46`；H0/H1、seed 生成、C/L mount、GC 和分析必须使用
同一 exact binary。stock v1.4.1 或任何仅版本字符串相同、校验和不同的重构建均不属于批准身份。

dump/load/clone 兼容性以 U1 最终报告为准；不得在 arm 间换版本。

### 2.4 工作负载合同

| 项 | 冻结值 |
|---|---|
| fio | randwrite；`bs=256KiB`；256 jobs / 256 active inodes；`iodepth=64`；`direct=1` |
| runtime | `180s`；time_based；每 slot 固定 randseed |
| 正式窗 | 实际 timed-I/O 起点后 `[15,175)`；W1--W4 各 40s |
| mount | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端 | 私有 `CEPH_CONF`，`ms_async_op_threads=8`；系统 `ceph.conf` 不变 |
| C/L seed | 256×1 GiB；每文件仅正式 B256 会访问的 512 MiB extent 已预写；总 active data 128 GiB |
| C/L 每 arm | 从同一 immutable seed restore 后 `clone -p` 到精确 `/test_dir`；fio 只写 clone |
| H | 复用生产卷现有 `storage_test.*.0 + rw_test.*.0` 的 256 个 1 GiB 文件；禁止 layout |

H 与 C/L 只能做到**工作负载合同等价**，做不到 inode、对象 ID 和完整 metadata state 相同；
这正是 H↔C 只能作为组合差的原因。执行前若 H 的 256 文件合同不满足，记
`H_WORKLOAD_CONTRACT_NOT_AVAILABLE`，不得临场新 layout 后仍声称历史 H。

### 2.5 C/L 完整矩阵

```text
R01=C, R02=L, R03=L, R04=C,
R05=L, R06=C, R07=C, R08=L
```

- C/L 各 4 arm，占位均值均为 `4.5`；对中心化线性、二次轮序均平衡；
- 同臂相邻对固定为 L `(R02,R03)` 和 C `(R06,R07)`，用于测量批内噪声底；
- 每 arm 使用新的 TiKV data dir / fresh FS / cluster token / metadata URL；
- 不允许只跑 `C L L C` 一个 block，不允许缺臂后补样，不允许改顺序。

### 2.6 H0/H1 顺序和恢复观察

```text
H0 → 优雅卸载测试挂载 → 逐节点停生产 TiKV → C/L 八臂
   → 停临时集群并精确销毁临时资源 → 逐节点恢复生产 TiKV
   → stores 3/3 Up 连续通过 + 固定观察/净化合同 → H1
```

恢复观察合同在脚本冻结前确定为：生产身份/配置/路径/mount source 全部通过，stores 3/3 Up
连续 3 次、Ceph `HEALTH_OK`、无临时进程/端口/loop/mount、相同 pre-arm cooldown 与 quiet gate，
再等待至少 30 分钟。若执行前评审决定延长，只能在看任何 H0/C/L 性能前修改任务书版本；
R01 后不得改变。

### 2.7 scrub 受控基线与最长 lease

H0/H1 与 C/L 都是同一归因链的性能端点，必须处于相同的“排除例行 scrub”条件；
但生产维护窗口和 8 个 fresh arm 可能很长，禁止使用一个 lease 跨越全任务或人工停点。

1. H0、C/L block-1 `C,L,L,C`、C/L block-2 `L,C,C,L`、H1 各使用一个独立
   state-driven lease；每个 lease 单独 plan/授权，目标上限 `4 h`。
2. 每个 lease 前冻结 FSID、原 flags、health、OSD up/in 和逐 PG state；同时设置
   `noscrub + nodeep-scrub`，等已运行 scrub 退出。每个 cell 前后均验证 ownership、
   唯一 `OSDMAP_FLAGS` WARN、逐 PG `active+clean` 且无 `scrubbing/deep`。
3. H0 、block-1、block-2、H1 结束/失败后都先精确 restore/verify，再做报告、临时资源处理或人工停点。
   restore 后若积压 scrub 启动，等它完成并恢复静稳门才能开下一 lease。
4. 两个 C/L block 的分割点不改变冻结臂顺序，且每个 block 内 C/L 均各两臂、位置对称；
   L2 分析仍使用全部 8 臂，逐 block/lease 作为预注册协变量，禁止因 block 效应删臂。
5. 这些 flags 是 benchmark 控制条件，不是生产配置。控制脚本须独立于 performance driver，
   只恢复自己拥有的变化；恢复失败是优先于生产恢复/效应分析的集群安全事件。

---

## 三、预注册数据源、计算和判定

### 3.1 每 arm 原始数据

| 指标 | 原始文件/字段 | 计算 |
|---|---|---|
| 有效 BW | 256 个 `fio/*_bw.<job>.log` + `fio.stdout` 完成时刻/runtime | 由完成时刻反推实际 I/O 起点；区间重叠加权到自然秒；256 job 齐全后求和；取 `[15,175)` mean/median |
| W1--W4/CV/P10/P90 | 同上 | 正式窗 160 个完整秒；W1--W4 各 40s；CV=`sd/mean` |
| I/O 起点偏差 | `fio-io-start.tsv` | `actual_start - registered_fork`; 绝对值 `>2s` 只标启动污染，主窗仍用 actual start |
| client meta | 挂载 `.stats` 或已实查 endpoint 的原始累计 histogram | 正式窗 sum/count 增量：meta Write、transaction、PUT、fuse write 数/字节 |
| TiKV 服务 | 每节点 Prometheus 原文 | scheduler prewrite/commit、storage async write、Raft commit/sync 的 sum/count 增量 |
| RocksDB | 每节点 Prometheus/engine property 原文 | pending compaction、compaction read/write、L0/files/bytes、stall reason/time |
| 本地设备 | 每节点区间 `iostat -x`，跳过 since-boot 首报 | util、await、aqu-sz、读写吞吐；按 W1--W4 聚合 |
| Ceph | 6 OSD perf/admin-socket 原文 + health/pool TSV | client-facing op、kv_sync、对象/stored/max_avail；只作状态与机制 |
| 身份/容量 | PID/starttime/exe/config/path/findmnt/df/state TSV | 精确比较；不从日志文字猜测 |

指标名必须在 Phase I 对实际 endpoint 实查并冻结到 `metric-contract.tsv`；缺失字段不得填 0，
不得用名字相似字段替代。

### 3.2 C↔L 主效应

使用 8 个 arm 的正式窗 **mean MiB/s**，模型固定为：

```text
BW_i = β0 + βL·I(L_i) + β1·x_i + β2·x_i² + ε_i
x_i = round_i - 4.5
effect_CL_pct = 100 × βL / adjusted_mean_C
```

报告 `βL`、`effect_CL_pct`、双侧 95% CI、C/L 调整均值和逐 arm 原值。不得在看数据后
切换到 fio summary、只取中位数、删除尾段或选择有利配对。

同臂噪声底：

```text
ε = max(
  abs(BW_R03-BW_R02)/mean(BW_R03,BW_R02),
  abs(BW_R07-BW_R06)/mean(BW_R07,BW_R06)
)
M = max(5%, 2ε)
```

- `5%` 是 nested-loop 的工程关注线，不是“相等”证明；
- 若 `ε >= 5%` 或效应 CI 半宽 `>5 pp`，C↔L 记 `RESOLUTION_INSUFFICIENT`；
- CV、W4/W1、bottom-decile 和延迟为正式性能端点，**数值差不能删除 arm**。

### 3.3 H 漂移与 H↔C 组合差

```text
H_center = mean(BW_H0, BW_H1)
D_H = 100 × abs(BW_H1-BW_H0) / H_center
C_center = C 的 OLS 调整均值
effect_HC_pct = 100 × (C_center-H_center) / H_center
```

同时给保守观测范围：

```text
lower = 100 × (min(C_arm)/max(H0,H1) - 1)
upper = 100 × (max(C_arm)/min(H0,H1) - 1)
```

| `D_H` | H↔C 处置 |
|---:|---|
| `≤5%` | 记 `H_ANCHOR_STABLE`，报告中心和保守范围 |
| `(5%,10%]` | 记 `H_ANCHOR_DRIFT_MATERIAL`，仍报范围，但不得给“精确 fresh 收益” |
| `>10%` | 记 `HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`；只报 H0/H1/C 原值，不签 H↔C 点估计 |

H0/H1 只有两个锚点，禁止伪造 CI 或把它们当独立随机重复。无论 `D_H` 如何，证据完整的
C↔L 仍按 §3.2 独立判定。

### 3.4 非性能证据门与性能端点分离

能使 arm/RUN 无效的只有：身份错、生产/临时并发、路径/设备归属错、seed/clone/GC 合同错、
容量/内存门失败、Ceph/TiKV health 失败、fio I/O error、sampler 覆盖不足、缺日志、矩阵缺臂、
未授权写操作或正式阶段脚本哈希变化。

以下再差也是结果，不能删样本：BW、CV、W4/W1、P10、transaction latency、pending compaction、
NVMe await/util。03-22b 的“CV>10%使整 RUN 无效”规则**不在本任务复用**。

### 3.5 VERDICT 状态

| 优先级 | 条件 | VERDICT |
|---:|---|---|
| 1 | 生产未安全恢复或保护对象身份不闭合 | `A1_PRODUCTION_RESTORE_NOT_SIGNED`，立即升级处置 |
| 2 | 任一非性能门失败或 C/L 缺臂 | `A1_EVIDENCE_INVALID` |
| 3 | C/L 噪声/CI 超分辨力 | `A1_CL_RESOLUTION_INSUFFICIENT` |
| 4 | C/L CI 全在 `[-M,+M]` 内 | `A1_NESTED_LOOP_WITHIN_RESOLUTION` |
| 5 | C/L CI 不跨 0 且超出 `M` | `A1_NESTED_LOOP_EFFECT_DETECTED` |
| 6 | C/L CI 跨 0 | `A1_NESTED_LOOP_INCONCLUSIVE` |

H↔C 另附 `H_ANCHOR_STABLE` / `H_ANCHOR_DRIFT_MATERIAL` /
`HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`，不得覆盖 C/L 主 verdict。

---

## 四、阶段 0：离线 Gate 0（GPT；禁止连接环境）

### 4.1 执行方 Step 0

GLM 在接收脚本后必须完整阅读抬头列出的七份方法论文档，并在
`methodology-ack.tsv` 记录路径、SHA256、读完时间和执行身份。未完成 Step 0 时，
包括只读 inventory 在内的环境动作均不得开始。

### 4.2 Phase 0 最小实现与边界

Phase 0 已实现本地-only最小包：`s04a1-common.sh`、`s04a1-inventory.sh`、
`s04a1-driver.sh`、`s04a1-analyze.py`、`s04a1-gate0-offline.sh` 和
`s04a1-mock-integration.sh`。它们只验证参数、矩阵、路径/状态合同、离线分析输入和
mock状态机；不得连接远端或执行 SSH、sudo、fio、mount、loop、mkfs、systemd、Ceph 或
任何生产/临时资源操作。`s04a1-driver.sh run` 明确返回 `NOT_READY`。

Phase 0 通过后的唯一就绪边界是：允许 GPT/Luna 审核后讨论并授权 Phase I 只读 inventory
及 plan；不授权 H0、生产 TiKV 停启、临时存储/loop/mount、seed/clone/GC、fio、scrub
flags 或任何环境写操作。在线职责脚本仍须在后续离线 Gate 通过后另行实现，不得以本包
的 plan 输出代替执行授权。

### 4.3 待实现在线脚本

```text
scripts/FULLBASELINE/debug/s04a1-inventory.sh
scripts/FULLBASELINE/debug/s04a1-prod-lifecycle.sh
scripts/FULLBASELINE/debug/s04a1-storage.sh
scripts/FULLBASELINE/debug/s04a1-cluster.sh
scripts/FULLBASELINE/debug/s04a1-seed-clone-gc.sh
scripts/FULLBASELINE/debug/s04a1-run-arm.sh
scripts/FULLBASELINE/debug/s04a1-driver.sh
scripts/FULLBASELINE/debug/s04a1-analyze.py
scripts/FULLBASELINE/debug/s04a1-gate0-offline.sh
scripts/FULLBASELINE/debug/s04a1-mock-integration.sh
```

可以复用 t65/t66 已验证的函数和 fixture 思路，但不得直接把旧 arm 名称、路径、授权 token、
容量常量或生产停启假设复制过来。每种操作拆成独立脚本；禁止把 stop、mkfs、mount、fio、
destroy、start 藏在一个失败 trap 中。

### 4.3 Gate 0 最低覆盖

1. `known-defect-classes.tsv` 全部适用项，shell 语法、Python 编译和 analyzer 单测；
2. 空/异常 RUN_ID、相对/根路径、symlink、production path 前缀交叠、错 node/arm/token；
3. C 原生目录与 L backing/loop/state 的精确归属；loop 号复用、mount source 错、sparse backing；
4. 生产 TiKV 与临时 TiKV 并发必须 fail closed；生产 PD 不得被 stop；
5. stop/start 按单节点 exact unit/PID/starttime/exe/config/path，禁止模式 kill/systemctl 通配；
6. C/L 矩阵、占位均值/二次矩、同臂相邻对和缺臂/重复臂 fixture；
7. 256/255/重复/截断 BW logs、actual I/O start、±1s 和 +58s 窗口敏感性；
8. seed source 不变、clone target 唯一且与 source inode 零重叠、dump/UUID/anchor 合同；
9. GC check-only→独立授权 delete→pool/seed return；禁止 load 已无存活对象的旧 dump；
10. `/proc/PID/cmdline` NUL 与空格覆写两种形态、JuiceFS daemon 父子 PID、嵌套 `Setting.UUID`；
11. sampler 先退、wait 非零、pipeline `PIPESTATUS`、缺指标/计数器回绕不得静默通过；
12. 失败现场保留、append-only incident、同 RUN 热修/补样/覆盖归档必须拒绝；
13. destroy plan 在无 state/部分 state/完整 state 三种 fixture 下只触及精确 RUN 资源；
14. 全脚本 grep 明文口令、`rm -rf`、`losetup -D`、lazy/force umount、模式 kill、OSD restart、
    pool delete/create 和系统 `ceph.conf` 写入，任一出现即 FAIL；
15. scrub controller mock 覆盖 H0/block-1/block-2/H1 四个独立 lease、foreign flag、部分 pause、
    唯一 WARN、失败优先 restore、不得跨停点保持 paused；
16. mock 走通 H0→stop→C/L 8 arm→restore→H1 正常闭环，以及 C/L 失败后优先恢复生产的闭环。

Gate 0 通过只允许进入只读 inventory；不等于授权 H0、停生产或创建临时资源。

---

## 五、分阶段执行与强制停点

### Phase I：只读 inventory、容量与计划（可最先讨论）

只读采集并回传：

- 四节点 hostname/time/fio/binary、foreign fio/mount/session/process；
- 三节点生产 PD/TiKV unit、PID/starttime/exe SHA、config SHA、data/WAL/Raft realpath；
- `/mnt/jfs-tikv` source/fstype/UUID/容量、生产路径和拟建 C/L 路径的前缀关系；
- PD/TiKV health、store/leader/region、Ceph health/pool/OSD、系统 `ceph.conf` SHA；
- H 256 文件 path/size/inode/mtime，确认无 layout/create/truncate；
- 每种 sudo/服务/存储动作的**计划文本**和预计维护窗口预算，不执行。

输出 `INVENTORY_PASS`、`capacity-plan.tsv`、`maintenance-budget.tsv`、
`prod-stop-plan/`、`storage-create-plan/`、`restore-plan/`、`destroy-plan/` 后暂停。

### Phase II：H0 锚点（需单独授权）

在生产 TiKV 未停止、C/L 未创建时：

1. 按 §2.7 经单独授权 pause/verify H0 lease；固定生产测试挂载身份和 H jobfile；
   执行与正式 arm 相同的 pre-gates；
2. 运行且仅运行一个 H0 B256；保存全量原始数据；
3. 完成生产卷允许的精确 reset/cooldown，核对 256 文件未创建/删除/截断；
4. 无论成败先 restore/verify H0 lease，生成 `H0_CLOSED.tsv` 后暂停，
   不自动停止生产 TiKV。

H0 失败不得选择性重跑；根据失败类型记 invalid 或重新立新 RUN。

### Phase III：生产停启与 C/L 台架 canary（需维护窗口授权）

用户审核完整 stop/rollback 计划后，逐节点 graceful stop 生产 TiKV；不得停止生产 PD。
确认生产 TiKV 进程/端口全部停止后，先在单节点验证 C 与 L create/activate/deactivate/destroy
全生命周期，再扩到三节点。随后完成：

- C/L cluster smoke，各自 stores 3/3 Up 连续 3 次；
- 小数据 dump/load/clone/COW/GC canary；
- 正式 immutable seed 只 layout 一次并双份持久化 SHA；
- C、L 各一次零正式写 restore/clone preflight；
- 一次不进入正式矩阵的 B256 容量 canary，仅校准 headroom，不输出性能结论。

输出 `A1_CANARY_CLOSURE_PASS` 后暂停。任何问题先保留现场；若会延长已批准维护窗口，优先按
已审计划恢复生产，不得为了“修脚本继续跑”擅自占用生产窗口。

### Phase IV：C/L 八臂（需独立正式矩阵授权）

只有 Phase III 全闭合、脚本 SHA 未变、维护余量满足时，才允许一次授权阶段内自主执行：

```text
fresh FS/dir → start fresh cluster → load seed → mount → clone
→ health/capacity/quiet gates → B256 180s + full samplers
→ graceful umount → wait ≥65s → stop TiKV→PD
→ fresh-seed GC inspect → 独立预授权范围内的精确 delete
→ seed/pool/local return → 下一 arm
```

顺序固定 `C L L C | L C C L`。按 §2.7 在 block-1 前 pause/verify 第一个 lease，R04 后立即
restore/verify，等积压 scrub 和环境回稳后再 pause/verify block-2 独立 lease；R08 后再立即
restore/verify。这些动作在预审 plan 内可阶段自主执行，不需逐 arm 请示，但不得跨人工停点保持 pause。

任一非性能门失败立即停止矩阵并进入已批准的安全恢复分支；
不得在同 RUN 热修、补 arm 或换 RUN_ID 重来。

### Phase V：临时资源清理与生产恢复（恢复优先）

无论 Phase IV 是 valid 还是 invalid，都先执行：

1. 核对 C/L scrub lease 已 restore/verified，无 active owned lease；若尚未恢复，它是第一安全动作；
2. 精确关闭 C/L mount、临时 TiKV/PD；
3. seed final GC/destroy，pool 回到动态 pre-seed 基线容差；
4. 按 state 逐节点卸载 loop、删除唯一 backing/临时目录，空间回归；
5. 逐节点启动生产 TiKV，验证 exact unit/config/exe/data path/mount；
6. stores 3/3 Up 连续 3 次、生产 volume status、Ceph `HEALTH_OK`、无临时残留；
7. 生成不可变 `PRODUCTION_RESTORE_SIGNED.tsv` 并暂停。

生产未签收前禁止做耗时的离线分析，也禁止因等待 GPT 让生产继续停机。

### Phase VI：H1 与最终归档（需单独授权）

满足 §2.6 固定观察合同后，按 H0 完全相同的 jobfile、挂载参数、pre-gates 和采集运行一次 H1；
开跑前按 §2.7 单独 pause/verify H1 lease；完成 H1 后无论成败先 restore/verify，再完成
reset/cooldown、post snapshot、方法论末步自查、内层/外层 SHA 和只读归档。

执行方只回传原始数据、逐门 PASS/FAIL、`incidents.tsv` 和 closure；**不计算效应、不删除 arm、
不下 nested-loop/fresh 结论**。GPT 从持久归档独立复算 §三全部指标。

---

## 六、交付物

```text
results/prod-stage04-raw-<date>/s04a1-<RUN_ID>/
  methodology-ack.tsv
  commands.sh
  frozen-manifest.tsv
  incidents.tsv
  inventory/
  plans/{prod-stop,prod-start,storage-create,storage-destroy}/
  production-fingerprint/{pre,h0,stopped,restored,h1,post}/
  seed/{dump,manifest,anchors,sha256}/
  preflight/
  arms/{H0,R01,R02,R03,R04,R05,R06,R07,R08,H1}/
  gc/
  closure/
  SHA256SUMS
```

最终文档：

- `doc/perf-report/04-2-hcl-native-vs-nested-attribution-<date>.md`；
- 首部机器可读 `VERDICT`、H anchor 状态、archive SHA；
- 更新 `doc/deploy-log/results-table.md`；
- 更新 `doc/perf-analysis/04-metadata-architecture-and-layout-plan.md`，但不得把 H↔C 改写为单因素。

---

## 七、通用注意事项与安全红线

1. 有 per-job log 时只用实际 I/O 起点 + 重叠加权重采样 + `[15,175)` + W1--W4；
   fio summary 只作旁证，禁止一份 log 乘 job 数。
2. 非性能证据门与性能端点分离；CV/W4/W1 再差也不删 arm。
3. 多臂固定完整平衡顺序；同臂相邻对测噪声；禁止单 block、补样和执行后换模型。
4. C/L 正式 seed 只 layout 一次；每 arm 写 clone、不写 seed；旧 dump 若对应 Ceph 对象已销毁，
   只能作结构参考，禁止直接 load。
5. 高强度写后完成 Ceph compact/cooldown 三指标和 TiKV/pool/local return；禁止 OSD restart、
   pool delete/create 或重新 layout 充当净化。
6. 本任务为生产安全偏离通用“全局 drop_caches”：禁止在三台生产节点全局 drop cache；
   冷态由 `direct=1 + cache-size=0 + immutable seed` 和同臂对称 pre-gate 控制。
7. 系统 `ceph.conf`、Ceph config、PG/CRUSH、生产 PD、生产 TiKV 配置/data/WAL/Raft 路径、
   生产卷和既有数据不得修改。
8. sudo 仅允许执行已回传、逐行审核、带 RUN_ID 和精确目标的 plan；生产 stop/start、存储
   create/destroy、loop mkfs/mount 是不同授权，不得用一句“继续”概括。
9. 禁止 `rm -rf`、`losetup -D`、force/lazy umount、模式 kill、`pkill`、`killall`、
   `fuser -k`、reboot/shutdown；不得 kill JuiceFS mount PID。
10. 失败即保留现场并 append-only 记录 incident；安全恢复动作只按预审 plan 执行。
11. 实现性脚本 bug 可在**未开始正式 RUN 且已离线复验**时修；任何改变变量、容量、顺序、
    判据、维护范围或授权目标的修复必须停下讨论。R01 后脚本一字节不得改。
12. 157 的 WekaIO、K8s、内核、网卡、RoCE、md0 和非本 RUN 挂载不得触碰；foreign fio 存在即停。
13. `incidents.tsv` 前后动作成对追加；归档包含实际脚本全文/MD5、冻结 manifest、内层
    `SHA256SUMS` 和外层 SHA，支持第二方完全复算。
14. 最后一步必须对抬头全部 skill/guide 逐条复核并在报告列出偏离及影响；不得只写“已遵守”。

### 执行前仍需讨论并明确的四项

1. exact V14 的 dump/load/clone 兼容边界与可重现制品身份；
2. 动态容量门、L backing 大小和生产 reserve；
3. 维护窗口是否足以容纳 canary + 8 arm + 失败恢复余量；
4. 生产测试挂载和 H 256 文件是否确认仅为测试资产，可在 H0/H1 覆写。

上述任一项未签字，本文保持 `NO_ENVIRONMENT_AUTHORITY`。

### 最终红线一句话

本任务可以销毁的只有带精确 RUN_ID 的 C/L 临时 namespace、临时目录、backing/loop、clone 和
本 RUN 垃圾对象；**绝不能碰**生产 PD、生产 TiKV 的既有 data/WAL/Raft 内容、生产卷非测试数据、
系统 Ceph 配置及任何无法由 state/指纹精确证明属于本 RUN 的进程、挂载、目录或设备。
