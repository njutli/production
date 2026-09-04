# 04 · JuiceFS 元数据架构与集群布局执行计划

> 建立：2026-08-28
>
> 承接：`doc/perf-report/03-JUICEFS-PERFORMANCE-TUNING-FINAL-REPORT-20260828.md`
> （`STAGE03_COMPLETE_TARGET_NOT_MET_ARCHITECTURE_LIMIT`）
>
> 上阶段计划：`doc/perf-analysis/03-juicefs-parameter-tuning-execution-plan.md`
> 集群变更型待办：`doc/perf-tasks/TODO-cluster-changing-experiments-after-stage03.md`（C01--C11）
> 方法论（**本阶段全部实验强制遵守**）：`skills/EVIDENCE-INTEGRITY-SKILL.md`
> + `skills/fixtures/known-defect-classes.tsv`
> + `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.13--22
> + `doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`

---

## 〇、04 阶段与 03 阶段的分界

03 阶段的命题是"**在不改变集群的前提下，把参数调到 6250**"。该命题已被证伪并收口：
在线/低风险参数空间穷尽，剩余差距进入架构层。

04 阶段的命题**不是无期限继续调参**，而是以下工作及一次最终收尾裁决：

| 线 | 命题 | 是否承诺达标 |
|---|---|---|
| **U 线** | 交付基座版本锁定：patched v1.4.1 能否替代 patched v1.3.1 | 比较性能与兼容性，但不以 `6250` 为验收线 |
| **A 线** | 归因闭合：历史环境→全新环境的 `+25%--30%` 由什么构成 | 不涉及性能目标 |
| **R 线** | 读侧最后余量：pool-scoped primary均衡能否提高 randread 并达到`≥6250` | **已完成：相对收益信号`+13.67%`，但`3924.5<6250`，目标未达** |
| **M 线** | 写侧架构：产出可选方案 + 工作量评估 + 原型验证 | **否**，明确不承诺 |
| **Z 线** | 收尾：补齐三项最小并发曲线，决定是否存在值得进入05的可生产旋钮 | 有候选开05；无候选结束调优 |

⚑ **04 阶段必须避免重犯 03 阶段的一个表述错误**：把"目标未达成"写成"工作未完成"。
04 的交付物是**决策输入**（能不能达标、代价多少、走哪条路），不是"再试一次 6250"。

### 0.1 编号约定

- **`U1 / A1 / A2a / A2b / M1 / M2 / R1`** = 04 阶段实验编号，定义在本计划书（§五--§九）。这是"要做什么"。
- **`04-N`** = 任务书序号，一本任务书承载一个实验编号。这是"哪一次去做"。
- 例外：U1 由已完成取数的 `u141b-juicefs-141-replace-131-decision.md` 与最终补证任务书
  `u141d-randwrite-randrw-confirm-10pct.md` 共同承载，二者均**不重命名**（历史引用已存在）。

### 0.2 文档职责

| 文档 | 职责 |
|---|---|
| **本计划书** | 04 阶段全部计划的唯一归属地：分线、判据、排期、红线、待拍板。结论变化时原地更新 |
| 任务书 `doc/perf-tasks/04-N-*.md` | 一个实验的执行描述。开工前写，**R01 开始后不改** |
| 报告 `doc/perf-report/04-N-*-<date>.md` | 该实验的结果。**首部必须有机器可读 VERDICT 行** |
| 周报 `report/周报-*.md` | 仅周末编写/修改 |

---

## 一、继承的公理层事实（04 阶段不再重验）

以下全部来自 03 阶段的可正式引用结论。**04 阶段任何任务书不得重新测量这些项**，
除非其前提（硬件、拓扑、版本）发生变化。

### 1.1 交付基座

```text
JuiceFS  /tmp/juicefs-1.4.1-patched   v1.4.1 + B-catchup   md5 24fae0852051c80ca571cb2f20275d46
mount    --max-fuse-io 256K --max-uploads 150 --cache-size 0
ceph     客户端私有 CEPH_CONF: [client] ms_async_op_threads = 8
规则     ms_async_op_threads >= OSD数据连接数 × 1.33（当前 6 OSD → 8）
```

U1 已批准上述 exact V14；stock v1.4.1 仍因 randwrite `551/552/551 MiB/s` 被排除。若不是部署
归档中的同 MD5 binary，而是重新构建，必须先补齐 source/patch/toolchain/BuildID/SHA256 可重现性
和 P0 smoke，不能把性能批准解释为任意 v1.4.1 构建均获批准。

### 1.2 七项基线与达成率（03-17f 交付口径，128 inode）

| 项 | 方向 | MiB/s | 达成率 |
|---|---|---:|---:|
| seqread | 读 | `1449` | `23.2%` |
| mseqread | 读 | `5366` | `85.9%` |
| randread | 读 | `5544` | `88.7%` |
| randrw | 读 | `1870` | `29.9%` |
| randrw | 写 | `1870` | `29.9%` |
| seqwrite | 写 | `1570` | `25.1%` |
| mseqwrite | 写 | `4676` | `74.8%` |
| randwrite | 写 | `2707` | `43.3%` |

### 1.3 已封板的机制结论

| # | 结论 | 关键数字 |
|---|---|---|
| 1 | primary分布是读侧可操纵变量，但不是6250目标的充分条件 | R1b把测试Pool `I_primary=1.40625→1.03125`，randread描述性提升`3452.5→3924.5 MiB/s（+13.67%）`；仍仅达目标`62.79%`。实际`op_r`未采到，不能把收益等同于`I_op`点估计，也不能外推到历史`5544`基线 |
| 2 | 写侧墙在按 inode 串行的同步元数据事务 + TiKV KV/compaction 共享服务率 | `6250 MiB/s @256KiB` 需 ≈`25000` 逻辑写/s；当前 meta 提交能力 ≈`12K/s`，缺口近 2 倍 |
| 3 | 轮内衰减是软排队，不是 RocksDB hard stall | stall 计数全程 0，L0 低于 trigger，限速器未生效 |
| 4 | **TiKV 存储介质不是随机写主因** | 全部本地存储 RAM vs NVMe 仅差 `+0.26%`；介质效应量级 `0%--3%` |
| 5 | **WAL/Raft 隔离的带宽收益上界 `≤5.05%`** | D1（logs on RAM）严格优于任何真实 NVMe；稳定性收益真实（CV `+2.36 pp`、`W4/W1` `+0.0694`） |
| 6 | **v1.4.1 原版仍有随机写崩塌，必须携带 B-catchup 补丁** | 原版 `551/552/551`（跨 `2.6` 倍池对象数恒值）；补丁版 `2679--2754` |
| 7 | 三节点无合格 spare NVMe | 12 块 NVMe：3 系统 + 3 TiKV + 6 Ceph OSD，SMART 全绿但**健康≠空闲** |
| 8 | 单流项受单请求完成周期限制，物理不可达 | `6250 @256KiB` 需 ≈`41 µs` 等效周期，一次跨网 librados 往返已 >`200 µs` |

### 1.4 已排除、⛔ 不得重开的方向

提高 `max-uploads` · 继续增加活跃 inode 数 · 增加 compaction worker ·
对 compaction 限速或暂停 · 同一物理盘上的逻辑分离（目录/分区/双 loop）·
通过主动清理消除轮内波动 · 调高某个 RocksDB 阈值

04-tmp又关闭了一个剩余在线参数：在当前exact V14、256K FUSE和msgr=8栈上，显式
`--max-readahead 0`对randrw读/写仅`+1.62%/+1.64%`，双侧95% CI上界分别为`+3.21%/+3.28%`，
均低于`+5%`材料阈值。保持默认readahead；该结论不得外推到randread。

---

## 二、判据体系（不再重新定义，全部引用 skill）

04 阶段**不重复发明采样、证据和安全口径**。全部实验统一使用
`skills/EVIDENCE-INTEGRITY-SKILL.md`；但每个任务书在开跑前冻结的、针对该命题的统计模型与工程边界
优先于 skill 中的通用示例，二者冲突时必须在任务书中显式说明，⛔ 不得执行中择优切换：

| 项 | 出处 |
|---|---|
| 有效带宽主口径（实际 I/O 起点 + 重叠加权重采样 + 正式窗 + W1--W4 + CV） | skill §1 |
| 多臂平衡顺序（ABBA-BAAB）与轮序漂移控制；效应模型和工程边界由任务书预注册 | skill §2 |
| 非性能证据门 vs 性能端点分离 | skill §3 |
| RUN 有效性状态机（`VALID` / `EVIDENCE_INVALID` / `RESOLUTION_INSUFFICIENT` / `INCONCLUSIVE`） | skill §4 |
| 离线 Gate 0（未过 ⛔ 禁止连接环境）+ 32 条缺陷类断言 | skill §5 + `fixtures/known-defect-classes.tsv` |
| 隔离台架合同（immutable seed / 四层 fresh / 每 arm GC return） | skill §6 |
| 第二方独立复算（执行方只交原始数据） | skill §7 |
| 分阶段停点粒度（phase 边界停，phase 内不停） | skill §8 |

⚑ 每份 04 任务书必须在抬头显式引用上表，并在 §通用注意事项中就地复述关键红线。

---

## 三、目标与验收

### 3.1 04 阶段的验收线（与 03 不同，必须区分）

| 线 | 验收线 | 说明 |
|---|---|---|
| U1 | 给出 `REPLACE_APPROVED` / `REPLACE_REJECTED` / `REPLACE_NOT_PROVEN` 之一 | 不是性能指标，是决策 |
| A1/A2a/A2b | `+25%--30%` 被拆成可识别效应与有证据的范围：nested-loop 单因素、元数据状态规模联合效应、可选 region 单因素，以及剩余 fresh/历史状态残差 | 不强求把不可正交控制的因素伪装成精确点估计 |
| R1 | randread 在pool-scoped primary更均衡的隔离Pool上 **≥6250 MiB/s** | **已签`R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET`**：存在材料工程信号但绝对值未达标；测试映射已随Pool删除，生产仅保留候选策略 |
| M1 | 四方向完成同口径审计；只识别出 1 个满足材料上界、正确性与回滚门的候选时，诚实签 `SINGLE_OPTION` | 决策输入 |
| M2 | 原型在正确性（崩溃一致性/重放/故障注入/回滚）全过后，给出提交率与带宽实测 | 性能通过不能替代正确性签收 |

### 3.2 ⛔ 04 阶段不承诺的事

- ⛔ 不承诺写侧达到 `6250 MiB/s`（03 已证明需要架构改造，且缺口近 2 倍）
- ⛔ 不承诺单流项（seqread `23.2%` / seqwrite `25.1%`）改善——物理不可达
- ⛔ 不承诺 randrw 双向各自达标——同挂载读写强反相关，合计落在 `4.0--4.2 GiB/s`

---

## 四、工作线总览与依赖

```text
U1  版本锁定（U141b 已有证据 + U141d 最终补证） ← 已完成：REPLACE_APPROVED
        │
        └─→ 锁定 04 全部后续实验使用的二进制

A1   H/C/L 同窗锚定：历史原生 / fresh原生 / fresh nested-loop（已完成）
        │
        └─→ A2a 元数据状态规模联合效应 sweep（已挂起）
                  │
                  ├─ 复活后有规模信号 ─→ A2b 固定规模、只改 region 的最小因果确认（当前挂起）
                  └─ 无规模信号 ─→ 保留 fresh/历史状态残差，先补事务与 RocksDB 插桩
                              │
                              └─→ 决定 C03 / C04 的优先级，或保持 MECHANISM_PARTIAL

R1  已完成：自然增加PG数无效；显式primary均衡有+13.67%工程信号但未达6250
                                      ← 新Pool生产候选，不是可直接复制的配置

M1  架构方案盘点与工作量评估        ← 依赖 A2a/A2b 结论定优先级
        │
        └─→ M2  选中方案的原型实现与正确性+性能验证
```

**并行性**：U1 与 R1 互不冲突但**不得同时占用集群**（共用 6 OSD 与同一 100GbE，且互相触发 foreign-fio 门）。
A1 必须独占生产 TiKV 维护窗口；A2a/A2b 不得默认塞进同一窗口，先用非性能 feasibility canary
确认数据生成时间与容量，再按其冻结的存储路径判断是否需要另一个生产 TiKV 维护窗口。

---

## 五、U1：交付基座版本锁定（P0，已完成）

### 5.1 命题

> 在同一生产卷、同一挂载参数、同一 Ceph 数据面和同一文件资产上，把二进制从
> `de93563f`（patched v1.3.1）换成 `24fae085`（v1.4.1 + B-catchup）后，综合已有
> 24 个有效正式轮与 U141d 最终写路径补证，能否在生产最相关 IO 模型上把版本差异控制在可接受范围？

原生未打 B-catchup 的 v1.4.1 已因 randwrite 约 `551 MiB/s` 被排除，⛔ 不属于 U1 候选。
U1 的任务是取得准确幅度后做版本决策，不是在取数前写死“每项必须零下降”或
`REPLACE_APPROVED`。

### 5.2 已有证据与原补证缺口

U141b 已取得 **24 个有效正式轮**：P1/P2/P3 各 8 轮，保留且不重跑：

| 项 | U141b 已有结论 | U141d 处置 |
|---|---|---|
| seqread / mseqread / randread | 版本效应接近 0，无材料性退化迹象 | 不重测 |
| seqwrite | 版本效应接近 0 | 不重测 |
| randrw | 均值趋势约 `−3.52%`，4 个跨臂对中 3 个为负；最贴近生产规格 | **Phase A 第一优先级复测** |
| randwrite | 均值趋势约 `−1.27%`，配对并非每轮都低 | Phase A 同时复测 |
| mseqwrite | U141b 未执行；更早 U141 被对象数棘轮污染 | **Phase B 独立补测** |

### 5.3 U141d 冻结设计

- Phase A：`randrw + randwrite`，固定 4 个预热轮，再跑 8 轮
  `V13 V14 V14 V13 | V14 V13 V13 V14`；阶段内连续、不动态加轮；
- Phase B：仅在 Phase A 未确认超过 `10%` 的材料性退化且用户授权后执行；
  2 个 canary + 8 个正式 `mseqwrite` 轮，每轮前删除精确 payload 并要求 pool 回到
  `seed_objects ±8192`；
- 主口径固定为实际 timed-I/O 起点后的 `[15,175)` 算术平均；`randrw` READ/WRITE 分开；
- 主模型固定为轮序中心化的二次 OLS，效应分母固定为 V13 正式轮均值；报告双侧/单侧 95% CI；
- `5%` 是关注线、`10%` 是材料性退化红线，二者都不是自动批准条件；CI 半宽超过
  `5 pp` 记 `RESOLUTION_INSUFFICIENT`；
- 本任务的冻结模型覆盖 skill §2.3 的通用 `ε/M` 示例，⛔ 不得在取数后切回更有利口径。

### 5.4 任务书、状态与排期

| 项 | 值 |
|---|---|
| 已有报告 | `doc/perf-report/u141b-replace-decision-status-20260829.md`（当前为 `REPLACE_NOT_PROVEN`，不是最终裁决） |
| 当前任务书 | `doc/perf-tasks/u141d-randwrite-randrw-confirm-10pct.md` |
| Gate 0 | **2026-08-29 离线 PASS**：语法、自测、历史原始日志回放、8 轮矩阵、完整生命周期与失败保留均通过；未接触环境 |
| 最终报告 | `doc/perf-report/u141d-juicefs-v141-replace-v131-final-20260831.md` |
| 当前状态 | **已完成：`REPLACE_APPROVED`；stock v1.4.1 仍排除** |
| 实际墙钟 | Phase A 约 `5.7 h`；有效 Phase-B-only 约 `3.7 h`，另有方法/脚本修复与无效 RUN |
| 有效停点 | Gate 0 / Phase A closure /（授权后）Phase B final closure |

### 5.5 结论如何落地

| U1 结论 | 动作 |
|---|---|
| `REPLACE_APPROVED` | 修订 03 最终报告 §3.1 与 §4；04 后续全部实验改用 `24fae085`；更新 `results-table.md` |
| `REPLACE_REJECTED` | 交付基座保持 `de93563f`；记录退步项与幅度，作为向上游反馈的依据 |
| `REPLACE_NOT_PROVEN` | 交付基座保持 `de93563f`；列明未闭合项与所需增量样本，**⛔ 不得默认升级** |

U1 已签 `REPLACE_APPROVED`：04 后续实验默认使用 exact V14 `24fae085...`。如果届时 V14
可重现构建闭环仍有缺口，可以临时继续 exact V13，但必须在任务 manifest 写明这是制品闭环的保守回退，
不得把不同构建的“v1.4.1”名字当成已批准身份。

---

## 六、A 线：归因闭合（A1 需生产 TiKV 维护窗口；A2 按 feasibility 另行定窗）

### 6.1 为什么这是最高信息价值的一线

| 因子 | 已测？ | 量级 |
|---|---|---|
| TiKV 存储介质（RAM vs NVMe） | ✅ 工程范围 | `+0.26%`（同拓扑跨 RUN）；`0%--3%`（含分盘对照），⛔ 不是随机化点估计 |
| logs 隔离（共享盘 → 独立） | ✅ 已测 | `+5.05%`（上界） |
| **历史环境 → 全新环境** | ❌ **仅有组合差** | **`+25%--30%`**，混有 fresh、规模、起点和 nested-loop |

⇒ **尚未拆开的组合差比已知介质效应大一个数量级。** A 线的目标是把可正交控制的因素
正式签出，把不能独立控制的部分留作有边界的残差；⛔ 不为满足表格完整性伪造四个单因素点估计。

### 6.2 A1：H/C/L 同窗锚定 —— 历史原生 / fresh 原生 / fresh nested-loop

- 对应 `TODO C01`；本节的 H/C/L 对照与可签边界覆盖 TODO 中较早的条件C描述，后续任务书以本节为准；
- 任务书：`doc/perf-tasks/04-2-hcl-native-vs-nested-attribution.md`；RUN `20260902-160000`已完成，
  `SCRIPTS_NOT_READY / NO_ENVIRONMENT_AUTHORITY`，执行前仍须审核动态容量、维护窗口与生产恢复计划；
- 不需要额外 NVMe，但需要一次生产 TiKV 维护窗口；临时目录必须位于
  `/mnt/jfs-tikv/<精确RUN_ID前缀>`，与生产 data/WAL/Raft 无前缀交叠；
- 使用U1已锁定的exact patched V14 `24fae085...`；不同校验和的重构建不得冒充同一身份；
- 三种逻辑条件都跑相同 B256 负载、挂载参数、Ceph 数据面和语义等价的 immutable seed/clone 资产：

| 条件 | TiKV 状态 | 本地存储路径 | 作用 |
|---|---|---|---|
| **H0/H1** | 当前历史生产 TiKV，维护窗口前/恢复后各一个锚点 | 生产原生 NVMe/ext4 | 测量窗口漂移与恢复；不是可随机化 arm |
| **C** | fresh PD/TiKV + fresh namespace/目录 | 同一生产 NVMe 的原生 ext4 临时目录 | 与 H 的差仍是 fresh+规模+起点组合效应 |
| **L** | 与 C 同 seed、同 fresh 层级 | 同一生产 NVMe/ext4 上的预分配 backing + loop/ext4 | 与 C 的唯一区别是 nested-loop 层 |

维护窗口内 C/L 的正式顺序固定为完整的 `C L L C | L C C L`，不能只跑一个四轮 block；
每 arm 必须重新建立同级别 fresh 状态；
H0 在停生产 TiKV 前执行，H1 仅在生产 TiKV 恢复、quorum/身份/目录指纹全部通过并完成冻结观察期后执行。
H0/H1 漂移边界在任务书中预注册，禁止看完性能后修改。

### 6.3 A1 能签什么、不能签什么

| 对照 | 可签结论 | 明确不能声称 |
|---|---|---|
| `C ↔ L` | nested-loop 单因素效应与区间 | 介质效应、fresh效应 |
| `mean(H0,H1) ↔ C` | 在同一维护窗口内，历史环境→fresh seed原生ext4的**组合差** | fresh RocksDB、元数据规模任一单因素 |
| H0 ↔ H1 | 时间漂移/恢复是否足以破坏 H↔C 分辨力 | 版本或存储收益 |

- 若 H0/H1 超过预注册漂移边界，只把 H↔C 降级为 `RESOLUTION_INSUFFICIENT`；
  C↔L 在自身证据门完整时仍可独立有效；
- 03 阶段 RAM↔NVMe 的 `0%--3%` 继续作为介质工程范围，不与 A1 跨 RUN 拼成正式效应量；
- A1 完成后必须先恢复并签收生产 TiKV，再决定是否启动 A2；⛔ 不因“同一维护窗口方便”自动续跑。

执行结果：C/L冻结OLS效应为`-4.54%`，双侧95% CI `[-12.45%,+3.37%]`；同臂噪声底
`epsilon=8.45%`且CI半宽`7.91 pp`，签`A1_CL_RESOLUTION_INSUFFICIENT`。H0/H1为
`4072.58/1417.99 MiB/s`，`D_H=96.70%`，签`HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`。
因此A1没有形成nested-loop生产调优手段，也不能固化fresh收益；生产已恢复签收，不自动启动A2。

### 6.4 A2a：元数据状态规模联合效应 sweep

> **2026-09-03状态：`PARKED_ARCHITECTURE_RESEARCH`。** 04-2未得到可固化的fresh收益，H锚点漂移
> `96.70%`；A2a即使确认规模效应，也只支持扩容、namespace拆分和容量规划，不能形成当前可直接交付
> 的配置。其生成器、快照和长矩阵成本较高，因此不准备脚本、不占维护窗口、不阻塞04-6。仅在生产出现
> 规模相关退化或已决定架构投资时复活。以下内容仅作为未来复活设计保留。

- 对应 `TODO C01b`（2026-08-28 新增）；本节的 A2a/A2b 分层定义覆盖 TODO 中把规模与region合写为单变量的旧描述；
- 任务书评审稿：`doc/perf-tasks/04-3a-metadata-state-scale-sweep.md`；当前只冻结
  `feasibility → 强制停点 → 条件正式矩阵`，生成器/脚本未实现且未授权任何环境动作；
- 要回答的问题是：在二进制、存储介质、路径拓扑、B256 负载和 seed/clone/GC 协议固定时，
  **随 JuiceFS 元数据状态规模增长而共同变化的 TiKV 服务状态**是否使同步事务服务率下降；
- A2a 的操纵量是冻结的“元数据规模档位”。key 数/字节数、region 数、RocksDB/LSM 形态、
  compaction 工作量会随档位共同变化，因此它是**联合效应实验**，⛔ 不得命名为 region 单因素实验；
- Ceph `juicefs-data` pool 的活对象数是数据对象，不是 TiKV 元数据条目数，不能作为
  A2a 的元数据规模自变量，只能继续用作数据面 GC return 安全门；
- 每档必须记录实际 TiKV key/value 量级、store used size、region/leader 数、RocksDB 各层文件/字节、
  pending compaction、Raft sync、scheduler prewrite/commit 和正式窗性能。

先验库存只用于设计量级，开跑时必须动态重采，禁止把下表数字当永久常量：

| 项 | 生产 TiKV | 临时集群（seed 级） |
|---|---:|---:|
| region 数/store | `2485` | 极少 |
| store used size | `15.42 / 17.53 / 17.54 GiB` | 远小于此 |
| 元数据 dump | 全量 | ≈`25 KB` |

#### A2a feasibility 与正式矩阵

1. 先做**非性能 feasibility canary**：验证元数据生成器产生的是 JuiceFS 真实 key 前缀、值大小和
   region 边界形态，测量生成/导入时间、本地容量与Ceph增量；禁止用任意大 key 填充冒充生产元数据；
2. 只根据 canary 的时间/容量可行性，在看任何正式带宽前冻结 3--5 个 immutable metadata snapshot；
   至少含 seed、中间、接近生产三个档位；
3. 正式样本数只能依据历史同拓扑噪声和预注册最小效应确定，不能依据 canary 性能确定；
   最低要求为两个端点各 4 个独立 fresh replicate、中间档各 2 个，顺序采用平衡设计并冻结；
   每次从对应 snapshot 恢复，不在同一个 RocksDB 上原地逐档累加；
4. 若接近生产档无法在批准的维护窗口和容量内生成，记 `SCALE_ENDPOINT_NOT_FEASIBLE`，
   给出已覆盖范围，⛔ 不用低档外推生产点；
5. feasibility canary 未完成前，不得把 A2a 与 A1 绑定为一个连续停机窗口。

### 6.5 A2b：固定规模的 region 最小因果确认（条件执行）

> **2026-09-03状态：`PARKED_CONDITIONAL_ARCHITECTURE_RESEARCH`。** 已建立挂起任务书
> `doc/perf-tasks/04-3b-fixed-scale-region-causality.md`；由于A2a未执行且没有材料规模信号，当前前置条件
> 不成立。即使确认region因果，也只能支撑TiKV扩容/分片等架构决策，不产生当前低风险调优配置。

A2b 仅在以下条件同时满足时执行：A2a 检出可复现的规模信号；在可销毁临时集群内能够
保持同一个 metadata snapshot 的逻辑 key/value 内容和规模不变，只改变 region 切分布局。

- 对照两侧固定 metadata snapshot、二进制、TiKV配置（除预注册的region切分操纵量）、store数、
  leader约束、存储路径、B256和fresh流程；
- 开跑前证明逻辑 key 数、逻辑字节、主要 key 前缀分布一致；region 数达到预注册差异；
- 正式两臂至少使用完整 `ABBA-BAAB` 八轮矩阵，禁止单个四轮 block；
- 报告 region/leader 分布、每事务实际触达 region 数、各 store 提交率、Raft sync、scheduler与
  RocksDB状态，不能仅凭总region数与带宽相关就宣告因果；
- 若无法在不同时改变 split 阈值、压缩状态或其他服务参数的条件下独立操纵 region 数，
  A2b 记 `REGION_CAUSAL_TEST_NOT_FEASIBLE`，保留 A2a 的联合效应结论，⛔ 强行归因。

### 6.6 A 线预注册决策表（决定 M 线优先级）

| 结果 | 结论 | M 线动作 |
|---|---|---|
| A2a 有规模信号，A2b 在固定规模下确认 region 单因素且服务率同步变化 | region布局/分摊是规模效应的重要组成 | **C03（TiKV扩容/分片）优先**，但仍需容量模型 |
| A2a 有规模信号，A2b 无效应或不可独立操纵 | 规模相关，但不能归因到region数 | 优先定位 LSM/compaction/scheduler 与事务路径；由 M1 决定是否进入 C04 |
| A2a 在实际覆盖范围内无规模信号 | H↔C 的剩余差来自未拆的历史/fresh/时间状态，尚未定位 | 补事务分段与 RocksDB 状态插桩；⛔ 自动写成“fresh RocksDB单因素”或直接启动 C04 |
| 非单调、方差过大或未覆盖生产端点 | `MECHANISM_PARTIAL` | 保留范围和残差，⛔ 据此启动 C03/C04 |

A 线最终报告必须给出一张可加和性声明：哪些数字来自同 RUN 随机化效应，哪些只是跨 RUN
工程范围，哪些仍是残差；除非设计真正正交，⛔ 要求各项点估计机械相加等于 `25%--30%`。

---

## 七、R 线：读侧最后余量（已完成，目标未达）

### 7.1 R1a：自然增加PG数量

任务书：`doc/perf-tasks/04-1-randread-pg-layout-feasibility-and-isolated-pool-ab.md`。
RUN `20260901-125124`实测32→64→128 PG的`I_primary=1.3125→1.21875→1.21875`；64→128只同比
放大直方图，不能自然改善当前CRUSH产生的primary比例。签`R1_FEASIBILITY_BLOCKED`，测试资源已清理。

### 7.2 R1b：同Pool显式primary均衡

任务书：`doc/perf-tasks/04-1b-randread-explicit-primary-steering-ab.md`；正式报告：
`doc/perf-report/04-1b-randread-explicit-primary-steering-ab-20260902.md`。

RUN `20260901-194644`在64-PG空Pool上应用5条pool-scoped `pg-upmap`，保持每个PG的六个acting成员
集合不变并调整顺序，再layout一次。通过`primary-temp`在同一Pool/UUID/文件集上恢复自然N或清除回
均衡S：

| 条件 | primary直方图 | I_primary | randread MiB/s |
|---|---|---:|---:|
| N | `{0:10,1:15,2:11,3:11,4:8,5:9}` | `1.40625` | `3467 / 3438` |
| S | `{0:10,1:11,2:11,3:10,4:11,5:11}` | `1.03125` | `3920 / 3929` |

描述性S-N为`+472 MiB/s（+13.67%）`，明显超过两组pair spread（`0.84%/0.23%`）和5%材料线；
但S均值`3924.5 MiB/s`只达6250的`62.79%`，R线目标未达。

### 7.3 结论边界与生产处置

- W01与W02--W04之间挂载实例变化；Attempt 4同挂载的`S/S/N`仍显示`3920/3929→3438`，早先W01 N
  又与W04只差0.84%，因此保留强工程信号，但不冒充八轮正式效应或95% CI；
- OSD admin-socket采样链路不可用，未取得正式窗实际`op_r`，不能签`I_op`机制点估计；
- 03历史randread `5544`属于另一Pool/layout/窗口，不与本RUN绝对值直接相减，也不更新七项基线；
- **可生产化方向**：新Pool为空时，按该Pool实际map计算primary均衡，先canary再layout；
- **不可直接上线**：pool_id=6的5条映射已随测试Pool删除且不可移植；Quincy没有`pg-upmap-primary`，
  对已有EC数据Pool直接重排`pg-upmap`可能触发shard恢复，`primary-temp`也不是持久生产配置；
- 若决定生产采用，应另立目标Pool变更单和回滚计划；04-1b不再补测L2/H或采样器。

证据manifest `558/558 OK`；测试volume/Pool/upmap/CephX与远端RUN根已清理，balancer和删除保护恢复，
Ceph `HEALTH_OK`，参考Pool与157业务正常。最终签
`R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET / R1B_TEST_COMPLETE`。

---

## 八、M 线：写侧架构（不承诺达标）

### 8.1 M1：方案盘点与工作量评估（纸面工作，不占集群）

任务书：`doc/perf-tasks/04-4-metadata-transaction-options.md`；报告：
`doc/perf-report/04-4-metadata-transaction-options-20260830.md`。M1 已由 GPT 以
`PAPER_ONLY` 完成，VERDICT=`M1_SINGLE_OPTION_ONLY`，exact V13 交付真值完整闭合；V14 exact tag + patch
语义闭合，但构建命令/Go version/binary SHA/BuildID仍须在 U1 选择 V14 时补齐。

针对"减少 / 批量化同步元数据事务"，至少评估四个方向：

| 方向 | 机制 | 需要评估的风险 |
|---|---|---|
| 多 slice/extent 更新的批量或合并提交 | 减少每次数据写触发的事务数 | 崩溃一致性窗口变大 |
| 数据写与非关键元数据更新的受控异步化 | 把非关键路径移出同步周期 | 故障恢复语义变化 |
| 同 inode 多请求的有序 pipeline | 替代全程持锁串行等待 | 顺序保证与重试语义 |
| 热点 inode 的元数据分片 | 提高单 inode 并行度 | 一致性与可验证性 |

每个方向必须给出：**预期提交率提升倍数**（当前 ≈`12K/s`，达标需 ≈`25000` 逻辑写/s，即需 ≈2 倍）、
代码改动面、协议兼容性、正确性验证清单、工作量与风险等级。

审计结果：只有 **O1 同 inode、跨 chunk 的 completed-slice metadata batch** 满足第一原型门。首版只允许
TiKV、`ChangeLog=false`、non-growing overwrite；不改 key schema，feature gate 默认 off，所有不确定状态
singleton fallback。模型为 `T2_CONDITIONAL`：只有实测 ready batch、transaction cost 与 1PC 后才能判断，
不是性能承诺。O2 不减少 mapping transaction，O3 会把本地锁等待移成共同 inode key 冲突，O4 需要不可简单
回滚的 schema migration，均不作为第二候选。

### 8.2 M2：选中方案的原型验证

- 对应 `TODO C04`
- 任务书：`doc/perf-tasks/04-5-metadata-transaction-batching-prototype.md`，当前
  `ABANDONED / WILL_NOT_EXECUTE / RETAIN_FOR_REFERENCE`；
- 2026-09-02决定废弃：即使源码原型有效，也需要长期正确性、兼容性和生产化验证，无法在当前交付
  周期直接用于生产；以下阶段门仅作历史设计参考，不再实施；
- 第一阶段只做不改变 singleton 提交行为的 shadow ready-depth/1PC/transaction-cost 插桩；平均有效 batch
  `<2`、实测 `b/k<1.25` 或 base 模型收益 `<25%` 时提前停止，不写行为原型；
- 必须使用**新测试 volume/namespace**；
- **正确性签收先于性能签收**：崩溃一致性、重放、故障注入、旧版本回滚，全过之后才报性能；
- 性能报告沿用 §二 的全部口径。

### 8.3 与 C03 的关系

C03（TiKV 扩容/分片）需要新增节点与专用 NVMe，属容量项目。
M1 的纸面方案盘点可以提前开展，但 C03 的采购/拓扑立项优先级必须依据 A2a/A2b（§6.4--§6.6）：
只有固定规模的 A2b 支持 region 因果且服务率证据同向，才能把 C03 写成优先候选；
仅有 A2a 规模相关性时，⛔ 直接以“region数过多”为由立项。

---

## 九、暂不做清单与复活条件

| 项 | 状态 | 复活条件 |
|---|---|---|
| C02 真实第二 NVMe | `BLOCKED_BY_HARDWARE_AND_DECISION` | 三节点硬件同时具备 **且** 按"稳定性收益"立项（⛔ 不得以带宽为由，上界 `≤5.05%`） |
| C05 TiKV RocksDB/compaction 重启参数 | `PARKED_LOW_PRIOR` | 有独立可重建 TiKV 环境；单变量 + A-B-A |
| C07 OSD 扩容 / EC 布局重建 | `PARKED_ARCHITECTURE` | R1已有primary均衡正向信号但未达标；仅在决定建设新Pool/迁移或扩容时联合评估，不以`+13.67%`承诺生产幅度 |
| C08 BlueStore 缓存/调度器 | `PARKED_RESTART_NOISE` | 可重建环境或可接受大量 sham restart 对照 |
| C09 Messenger/cephx 服务端变更 | `PARKED_NO_MECHANISM` | 有明确服务端队列证据 |
| C10 主机/NVMe/网络栈 | `PARKED_CROSS_TEAM` | 系统组 + 网络组联合立项 |
| C11 关闭 BlueStore 校验 | `DO_NOT_RUN_ON_PRODUCTION` | 仅完全隔离可销毁集群 |

---

## 九·一、Z线：04阶段最终收尾

任务书：`doc/perf-tasks/04-6-stage04-final-capacity-and-tuning-exit-decision.md`。

04-6不重跑七项全量基线，也不在04内试新参数；只用固定数据集补：

```text
mseqread   8→16→8
mseqwrite  8→16→8
randrw    64→128→64
```

结合03-17d/03-17e的randread扩展曲线、03-19的randwrite inode曲线和现有单流周期证据，判断剩余弱项
是仍可扩展、进入共享服务平台，还是证据不足。只有当同窗机制指标定位到一个现有配置可控制、无需代码/
硬件/拓扑/测试语义变化、保守预期收益`≥5%`且未被既有实验排除的候选时，关闭04并新建05阶段；否则
04-6 RUN `20260903-214003`已完成9/9 cell及恢复。环境结束后从frozen raw确定性生成机制证据：
mseqwrite 8→16时完成服务率为两侧低档均值的`0.94565×`、fio P50为`4.216×`，六块OSD数据盘
正式窗P50均为`100%`，更正为`SERVICE_PLATEAU_IDENTIFIED`；mseqread仍为`PARTIAL_SCALING`，
randrw低并发回环漂移约`8.2%`且存在TiKV/RocksDB状态债务。因此阶段仍签
`STAGE04_CONTINUE_DIAGNOSIS`：未发现新可交付旋钮，且不能把单个写平台闭合扩大为全部项目数学架构上限。

04-2/04-3a/04-3b只补fresh/规模/region归因；04-tmp2d已完成交付配置读缓存曲线；04-tmp2e用
修正容量的W16确认持续满压下排空硬失败并关闭环境，该事实否决W16容量档，但项目已将writeback
纳入“客户端空间充足、独占文件、低占空比且受监控”的条件性生产增强。04-tmp3竞品口径已完成：
20 MiB direct读的R臂相对A提升`65.27%`，16 MiB写的F臂有`10.60%` L1信号，但四项披露目标均未达。
04-tmp3b进一步完成路径对齐：RA32未过双配对选择门、`async_dio`无收益；fresh 4 MiB BlockSize
虽然把GET次数降为1/16，却因单GET时延升高使20 MiB单流读下降约34%，因此保持RA8、async off和
256 KiB。写侧首个B256 cell在重挂可见性硬门失败，工程带宽不进入结论；两个临时卷已销毁，当前卷
指纹不变。这些专项均不阻塞Z线收尾。

---

## 十、执行台账与排期

| 实验 | 任务书 | 需硬件 | 需维护窗口 | 依赖 | 状态 |
|---|---|---|---|---|---|
| **U1** | `u141b-juicefs-141-replace-131-decision.md`（已有证据）+ `u141d-randwrite-randrw-confirm-10pct.md`（最终补证） | 否 | 否 | 无 | **已完成：`REPLACE_APPROVED`；exact patched V14 锁定** |
| TMP-RW1 | `04-tmp-randrw-readahead-residual-tuning.md` | 否 | 性能独占但不需停服务 | U1 | **已全部完成并关闭生命周期：保持默认readahead** |
| **R1** | `04-1-*` + `04-1b-*` | 否 | 已使用Ceph变更+性能独占窗口 | U1、04-tmp | **已完成并关闭：自然PG梯子无效；显式primary均衡`+13.67%`工程信号，`3924.5<6250`；仅作新Pool生产候选** |
| TMP-CACHE1 | `04-tmp2-juicefs-local-read-cache-stability-canary.md` | 否 | 已使用性能独占窗口 | U1、R1 | **已完成并关闭：热集机制信号强，但缓存合同失败，不形成生产交付值、不升级L2** |
| TMP-CACHE2 | `04-tmp2b-juicefs-read-write-cache-capacity-curve.md` | 否 | 已使用性能独占窗口 | TMP-CACHE1 | **已完成并关闭：6个读点仅作描述；首个写点staging排空失败，整体INVALID，不交付组合缓存配置** |
| TMP-CACHE2C | `04-tmp2c-randread-cache-residency-curve.md` | 否 | 已使用只读性能独占窗口 | TMP-CACHE2 | **已完成并关闭：修正inode容量合同后，近全驻留读缓存约35.3k MiB/s（34.5 GiB/s）；正式曲线受drops硬门限制，不交付固定档位** |
| TMP-CACHE2D | `04-tmp2d-production-aligned-read-cache-curve.md` | 否 | 已使用只读性能独占窗口 | TMP-CACHE2C | **已完成并关闭：14/14有效；75%缓存收益`+173%/+233%`，全驻留mseqread/randread约35--37 GiB/s；进入独立生产canary候选** |
| TMP-CACHE2E | `04-tmp2e-writeback-capacity-curve.md` | 否 | 已使用写性能独占窗口 | TMP-CACHE2D | **已完成并关闭：W16在900秒后仍残留2 blocks/524288 B，故不采用W16；前段突发吸收支持有充足本地空间时条件性启用writeback** |
| TMP-H3C | `04-tmp3-competitor-large-block-sequential-benchmark.md` | 否 | 已使用读写性能独占窗口 | U1、Z0 | **已完成并关闭：R读臂`+65.27%`为强L1信号，F写臂`+10.60%`具确认资格，`buffer-size=1024`无增量；4/4披露目标未达，不自动L2** |
| TMP-H3C-BIGSEQ2 | `04-tmp3b-competitor-large-block-io-path-alignment.md` | 否 | 已使用读写性能独占窗口 | TMP-H3C | **已完成并关闭：RA32未过门、async无收益；B4单流读相对B256下降约34%；写侧持久性硬门失败而停止，无生产配置变化** |
| A1 | `04-2-hcl-native-vs-nested-attribution.md` | 否 | **已完成**（H0→停生产TiKV→C/L→恢复→H1） | U1 | **已完成并关闭：C/L分辨力不足；H锚点严重漂移；无生产配置变更** |
| A2a | `04-3a-metadata-state-scale-sweep.md` | 否 | 当前不安排 | 生产规模退化或架构投资需求 | **已挂起；不准备脚本；不阻塞04收尾** |
| A2b | `04-3b-fixed-scale-region-causality.md` | 否 | 当前不安排 | A2a材料信号+region独立操纵+架构投资需求 | **已建挂起任务书；前置条件不成立** |
| M1 | `04-4-metadata-transaction-options.md` | 否（纸面） | 否 | A2a/A2b决定最终优先级 | **已完成：`M1_SINGLE_OPTION_ONLY`；O1 batch为唯一候选，T2 conditional** |
| M2 | `04-5-metadata-transaction-batching-prototype.md` | 否 | 否 | — | **已废弃；不执行；仅保留历史设计** |
| **Z0** | `04-6-stage04-final-capacity-and-tuning-exit-decision.md` | 否 | 已完成 | U1、R1及既有03曲线 | **RUN `20260903-214003`完成：mseqwrite服务平台已闭合；无新可交付旋钮，mseqread/randrw仍使阶段签`STAGE04_CONTINUE_DIAGNOSIS`** |

### 10.1 建议顺序

```text
第 1 步  U1              已完成：exact patched V14锁定；stock V14继续排除
第 2 步  R1              已完成并关闭：正向工程信号、目标未达，不再补测
第 3 步  TMP-CACHE1      已完成并关闭：强热集信号仅作工程观察，不升级L2
第 4 步  Z0 / 04-6       已完成：9-cell与恢复PASS；mseqwrite平台闭合，mseqread部分扩展/randrw漂移仍需定点诊断
阶段外    A2a/A2b         仅在生产规模退化或扩容/拆分立项时复活；不再为历史组合差单独排窗
阶段外    TMP-CACHE2/2C/2D/2E  读缓存曲线已完成；writeback的W16失败并关闭实验，条件性生产配置保留
阶段外    TMP-H3C/3B      已完成并关闭；路径对齐未产生新候选，不阻塞Z0
```

⚑ **U1 与 R1 不得并行占用集群**；A1已使用独占维护窗口并关闭；A2a/A2b当前挂起。未来若复活，是否
需要停生产由届时冻结的存储路径决定，任何情况下都不得与其他性能RUN并行。

### 10.2 每个实验开工前的强制检查

1. Gate 0 通过（若含新脚本），⛔ 未过禁止连接环境；
2. 串行门：无其他 RUN 残留（mount/loop/临时端口/foreign fio）；
3. 对每个相关 pool 动态采集并冻结本 RUN 起点；`2.43M` 只作历史参照，⛔ 当永久常量；
4. 冻结 manifest 生成，含二进制 md5、脚本 md5、系统 `ceph.conf` md5、文件资产清单；
5. 任务书 R01 开始后 ⛔ 脚本一字节不改。

---

## 十一、红线（逐项复核后在报告中打勾）

1. ⛔ 禁改系统 `ceph.conf`（md5 必须恒为 `5b6be34179a64e0a5f9c6d3a9690041f`）、禁 `ceph config set`；
2. ⛔ 禁 `ceph osd pool delete/create` 作为轮间清理；R1 新建 pool 是**实验对象**，需单独授权，且不得删除生产 pool；
3. ⛔ 禁写 `/dev/nvme*`、`/mnt/jfs-tikv`（A1 例外：仅在授权窗口内的精确临时目录）、`/opt`、`/etc`、`/var/lib/ceph`；
4. ⛔ 禁 `pkill`/`killall`/`fuser -k`/模式 kill；⛔ 禁 `fusermount -uz`、`umount -l`、`losetup -D`、`rm -rf`；⛔ 禁 kill mount PID；
5. ⛔ 禁 reboot/shutdown/systemctl 改生产服务（A1 的生产 TiKV 停启需单独授权与回滚计划）；
6. ⛔ 禁动 157 的 WekaIO、K8s、内核、网卡、RoCE、md0；
7. ⛔ 脚本内不得内嵌口令（既有例外 `FULLBASELINE_V4.sh:37` 已登记，建议轮换凭据）；
8. 失败即保留现场：不卸载、不删目录、不清 sampler；`incidents.tsv` 动作前后各一条；
9. ⛔ 禁同 RUN 热修后按正常签收、禁换 RUN_ID 重来、禁补样替换、禁把无效 RUN 点值与有效 RUN 拼接；
10. 执行方只交原始数据 + 逐门 PASS/FAIL + `incidents.tsv`；⛔ 不算效应量、不下结论、不挑轮次；
11. 报告首部必须有机器可读 VERDICT 行；⛔ 订正不得只写在附录。

### 最终红线一句话

04 阶段可以丢掉的是临时 namespace、临时目录、隔离测试 pool 和本 RUN 的 COW 垃圾对象；
**绝不能碰**的是生产 `juicefs-prod` 卷与 `juicefs-data` pool 的既有数据、
生产 PD/TiKV/Ceph 的配置与服务、系统 `ceph.conf`、384 个文件资产，
以及任何无法由指纹文件精确证明归属的 PID、挂载或设备。

---

## 十二、变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-28 | 建立。承接 03 阶段收口；U1 从 03 阶段末移入作为前置项；A2（元数据规模 sweep）为新增线 |
| 2026-08-29 | 同步U141d现状与冻结判据；A1改为H0/H1+C/L同窗可识别对照；A2拆为规模联合效应A2a与固定规模region因果确认A2b，禁止把Ceph对象数当元数据规模或用相关性直接启动C03 |
| 2026-08-30 | R1 定为04阶段首份任务书 `04-1`；订正32/33 PG混算与fast_read下primary因果过度表述；增加只读/离线可行性门、实际op_r操纵门、一次layout和保留确定性pool/layout合同；A1/A2顺延为04-2/04-3a/04-3b |
| 2026-08-30 | 新增04-2、04-3a、04-4任务书评审稿：分别冻结H/C/L同窗归因、真实元数据规模feasibility+12臂正式矩阵、同步元数据事务四方向纸面评估；三者均未授权执行，04-3b/04-5继续保持条件待写 |
| 2026-08-30 | GPT完成04-4 exact-source审计：签`M1_SINGLE_OPTION_ONLY`，唯一候选为同inode跨chunk metadata batch，模型仅`T2_CONDITIONAL`；新增04-5分阶段任务书，先过被动ready-depth/1PC/cost硬门，再谈行为原型，仍无执行权限且优先级等待A2 |
| 2026-08-31 | U141d Phase A+B 完整闭合并由GPT从原始per-job日志独立复算：randrw读/写`−0.52%/−0.51%`、randwrite`−2.08%`、mseqwrite`+2.96%`，四端点均排除超过5%退化；U1签`REPLACE_APPROVED`，锁定exact patched V14 `24fae085...`，stock v1.4.1继续排除 |
| 2026-09-01 | 04-tmp完成12/12 cell并由GPT独立复算：ra0对randrw读/写`+1.62%/+1.64%`，95% CI上界均低于`+5%`；保持默认readahead并关闭该方向。同步R1 V2 Gate已过、下一步只读inventory+计划，以及测试数据生命周期规范 |
| 2026-09-02 | 新增Z线/04-6最终收尾：只补mseqread、mseqwrite、randrw三组半并发↔原并发最小回环；若定位到可生产且预期≥5%的具体旋钮则开05，否则结束本轮调优。A1/A2与缓存/竞品专项不再阻塞04收尾 |
| 2026-09-02 | R1a自然PG梯子签`R1_FEASIBILITY_BLOCKED`；R1b同Pool primary均衡工程筛选N=`3467/3438`、S=`3920/3929 MiB/s`，描述性`+13.67%`但`3924.5<6250`。签`R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET`，只作为新Pool生产候选策略；证据与环境生命周期已关闭 |
| 2026-09-02 | 04-tmp2 RUN `20260902-133433`完成ABBA与POST-A：A=`3713.56`、B=`36490.02 MiB/s`，但R02仍填充`19.51 GiB`且热点主要命中Linux页缓存，缓存三源合同未闭合。签`CACHE_SCREEN_EVIDENCE_INVALID`，不补跑、不升级L2；缓存目录、scrub和性能基线已恢复 |
| 2026-09-02 | 废弃04-5源码原型：即使批处理原型有效，也无法在当前交付周期直接生产化；停止插桩、开发、构建和环境测试，仅保留历史设计参考 |
| 2026-09-02 | 04-2 RUN `20260902-160000`完成H0/H1与C/L八臂：C/L效应`-4.54%`、95% CI `[-12.45%,+3.37%]`，噪声底`8.45%`，签`A1_CL_RESOLUTION_INSUFFICIENT`；H漂移`96.70%`，H↔C不可归因；生产与证据生命周期完整关闭 |
| 2026-09-03 | 04-3a/04-3b改为架构研究挂起：历史`+25%--30%`组合现象未稳定复现，继续拆规模/region成本高且不能形成当前生产配置；仅在生产规模退化或扩容/namespace拆分立项时复活，不阻塞04-6收尾 |
| 2026-09-03 | 04-tmp2b RUN `20260903-000000`完成6个读点；mseqread=`3104/3293/3437`、randread=`3892/2645/3815 MiB/s`，不形成单调容量曲线。首个randwrite写后staging固定残留112 blocks/29.36 MB并持续ENOENT，按硬门终止；恢复挂载清零后环境精确关闭，签`CACHE_CAPACITY_CURVE_INVALID / NO_DELIVERABLE_COMBINED_CACHE_TIER` |
| 2026-09-03 | 04-tmp2c RUN `20260903-141500`订正04-tmp2b的inode容量错误：16 GiB热集下C16/C32命中`95.83%/~100%`、带宽约`35.3k MiB/s（34.5 GiB/s）`、Ceph RX降至`4.25%/~0`，确认近全驻留读缓存机制收益；因预注册drops硬门、A0漂移9.36%及C08不稳，正式容量曲线仍INVALID，本RUN不交付固定档位且不提供writeback判断（后续决策见04-tmp2e） |
| 2026-09-03 | 04-tmp2d RUN `20260903-131428`完成交付配置对齐的14个读缓存cell：75%容量时mseqread/randread收益`+173%/+233%`，全驻留约35--37 GiB/s，A0漂移均小于1%；确认读缓存存在稳定材料收益，但固定生产容量仍需独立canary |
| 2026-09-03 | 04-tmp2e RUN `20260903-181523`以修正后的16 GiB backing复验writeback：前90秒约`2770.80 MiB/s`、全窗`2436.50 MiB/s`，900秒后仍残留`2 blocks/524288 B`；恢复挂载清零、抽读通过且环境精确关闭。签`W16_WRITEBACK_DRAIN_FAILURE`并取消更大容量和randrw；该失败否决W16，不否定低占空比突发吸收，项目决定在客户端空间充足等条件下交付writeback增强配置 |
| 2026-09-04 | 04-6 RUN `20260903-214003`完成并从frozen raw离线补齐机制证据：mseqwrite 8→16约`-5.5%`、P50约`4.2×`，六块OSD盘P50均100%，更正为`SERVICE_PLATEAU_IDENTIFIED`；mseqread仍`PARTIAL_SCALING`，randrw回环漂移约`8.2%`并伴随TiKV/RocksDB compaction debt；未发现新可交付旋钮，阶段仍裁决`STAGE04_CONTINUE_DIAGNOSIS` |
| 2026-09-04 | 04-tmp3 RUN `20260904-095827`完成12/12 L1 cell：20 MiB direct读R臂`2614.08 MiB/s`、相对A `+65.27%`，16 MiB写F臂相对A `+10.60%`且两个配对方向一致，`buffer-size=1024`无增量；四个竞品披露目标均未达，持久化与环境生命周期已关闭，不自动升级L2 |
| 2026-09-04 | 04-tmp3b RUN `20260904-132417`完成并关闭：RA32配对`+9.74%/+13.80%`未过双门，async约0%；fresh B4读相对B256为`-34.13%/-33.47%`，故保持RA8/async off/256K。首个B256写在clean unmount后重挂不可见，按持久性硬门停止并排除写效应；两个临时卷精确销毁，当前卷与Ceph环境回归通过 |
