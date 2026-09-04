# 04-1 任务书：R1 randread PG/数据布局可行性与隔离 Pool A/B

## 日期：2026-08-30

> 实验编号：**R1**；04 阶段第一份任务书。
>
> 面向：GLM 分阶段执行；GPT 负责 Gate 0、阶段间审核、独立复算与最终签收。
>
> 当前状态：`V2_FEASIBILITY_CONTRACT_REVISED / OFFLINE_GATE0_PASS / NO_ENVIRONMENT_AUTHORITY`。
> 旧 RUN `20260831-172212` 保留为 v1 合同终点和失败证据，不得改写、覆盖或重跑。
> v2 将注册一个且仅一个空 B pool；先冻结其实际 32-PG OSDMap，再按同一 pool_id 的
> 32→64→128 单调 PG 梯子逐档实际调整和核验。禁止伪造离线 64/128 逐 PG candidate；
> 每一档均以实际 active+clean 映射决定继续、选定或停止。当前只签收空 pool 可行性链；
> auth、volume、layout、fio 和正式分析要等结构档位 `SELECTED` 后再补独立 Gate，避免提前开发。
>
> 承接：`doc/perf-analysis/04-metadata-architecture-and-layout-plan.md` §七、
> `doc/perf-tasks/TODO-cluster-changing-experiments-after-stage03.md` C06、
> `doc/perf-report/03-17d-read-concurrency-sweep-20260820.md` F61/F62、
> `doc/perf-report/03-17e-multimount-and-new-baseline-20260821.md` F66。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/fixtures/known-defect-classes.tsv`、`skills/TESTING-GUIDE.md`、
> `skills/test-commands-reference.md`、`skills/LONG-RUNNING-TEST-SKILL.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。

```text
EVIDENCE_LEVEL=L0_INVENTORY → L1_FEASIBILITY(空pool实际PG梯子) → L1_SCREEN → L2_FORMAL
SCREEN_SOURCE=历史固定 layout CV 0.6%--1.5% + 本 RUN W01--W04 实际 OSD op_r 操纵量
SCREEN_CONTINUE=B 对 A 的实际 OSD 读负载不均衡按 §3.3 过门，才跑八轮带宽矩阵
SCREEN_STOP=候选映射不可控/不匹配或操纵量未改善，直接签可行性/机制负结论
FORMAL_MATRIX=A,B,B,A,B,A,A,B
ESTIMATED_WALL_CLOCK=当前仅标定空pool梯子；数据面和性能时长在SELECTED后另行冻结
```

---

## 〇、执行路线（冻结）

```text
Gate 0 离线自测
  → I 只读 inventory
  → II 生成注册空 pool 计划后暂停
  → 用户批准后 III 只注册一次 32-PG 空 pool，等 active+clean 并冻结该 pool 的 OSDMap 后暂停
  → IV evaluate-layout(32)；若 NEXT_REQUIRED，生成 64 调整计划并暂停
  → 用户批准后只调整同一空 pool 到 64，等 clean、逐 PG 核对，再 evaluate-layout(64)
       ├─ SELECTED：禁止继续调整
       └─ NEXT_REQUIRED：同理只允许 128；三档均失败则 BLOCKED
  → SELECTED 后暂停；补写并签收数据面/性能 Gate，用户批准后才创建 auth/volume/layout
  → V 只 layout 一次，固定双挂载，四轮预热/操纵检查
       ├─ 实际 op_r 未改善：有效负结论，停止正式轮
       └─ 实际 op_r 已改善：VI 固定 ABBA-BAAB 八轮
  → VII 优雅卸载、归档、保留 pool/数据等待独立复算
```

当前签收范围内，**Gate 0、注册计划、注册完成、每次PG调整计划/完成、SELECTED/BLOCKED都是强制停点**。
任何失败均停止并保留现场，不在同一 RUN 中热修、补轮或换 pool 重来。

---

## 一、背景、口径订正与唯一问题

### 1.1 已有证据

- 交付口径 randread 为 `5544 MiB/s`；同形状 J128 三轮均值为 `5516.7 MiB/s`；
- 单挂载并发拟合渐近上限约 `6280 MiB/s`，目标 `6250 MiB/s` 已占其 `99.5%`；
- 六个 OSD 的 client-facing `op_r/s` 在 J128 的一轮实测为
  `8956/8883/7422/8916/7412/5873`，`max/mean=1.132--1.136`，跨轮稳定；
- 以最热 OSD 服务率作理想上界，`5516.7 × 1.136 ≈ 6267 MiB/s`；该值只比目标高
  `17 MiB/s`，几乎没有工程余量；
- 固定 layout 的连续读 CV 约 `0.6%--1.5%`；每轮 destroy/re-layout 会把 CV 放大到
  `10%--13%`。因此本任务只允许每个数据集 layout 一次并永久冻结到任务结束。

### 1.2 必须先订正的两点

1. `juicefs-data` 当前历史证据是 **32 个 PG**。旧报告中的“33 PG”混入了另一 pool 的
   1 个 PG；`6+6+5+6+5+4=32`。本任务必须同时输出“目标单池”和“全 Ceph 集群”两行，
   禁止再次混算。
2. 当前 EC 4+2 pool 已启用 `fast_read=1`。历史 `6:6:5:6:5:4` 既像单池 primary 计数，
   也与实际 `op_r/s` 倾斜同向，但 **primary 计数本身不是因果证据**；既有报告还曾证明
   `fast_read=1` 时 primary 恒定并不能解释布局波动。R1 真正要操纵和验证的是
   **固定对象/PG/CRUSH 布局下的实际 OSD 读负载分布**，primary 直方图只作结构代理量。

### 1.3 本任务唯一判定问题

> 在不修改参考 `juicefs-data` pool、既有卷和 Ceph 全局配置的前提下，是否存在一个
> **可保留、可回滚、pool 级隔离**的新布局，使 128-job/256 KiB randread 的实际 OSD
> `op_r/s max/mean` 从历史约 `1.136` 显著收敛，并把有效带宽提高到 `≥6250 MiB/s`？

本任务不是“多试几个 pool 直到碰到高分”，也不是“证明 PG 数越多越快”。如果 Quincy、
EC 4+2/6 OSD 和现有 CRUSH 约束下无法形成可识别操纵量，在空 pool 梯子结束时给出
`R1_FEASIBILITY_BLOCKED` 就是完整、有效的结果。

---

## 二、实验对象、固定量与允许变化量

### 2.1 两臂定义

| 臂 | 数据面 | 文件资产 | 用途 |
|---|---|---|---|
| **A / CURRENT** | 现有 `juicefs-data`，其 pool_id、32 PG、EC/CRUSH 全部只读冻结 | 现有 `juicefs-prod/test_dir/read_test.{0..127}.0`，128×1 GiB，永不改写 | 同窗锚点和旧布局对照 |
| **B / CANDIDATE** | 只创建一次的 `jfs-r1-<RUN_ID>`；同一 pool 以实际32→64→128梯子选择第一档过门布局 | 仅SELECTED并通过后续数据面Gate后才生成128×1 GiB | 被验证并在成功后保留的候选布局 |

A 使用专用**只读**挂载，不接管、不卸载 `/mnt/juicefs`；B 只在一次性 layout 阶段可写，
完成后优雅卸载并以只读方式重挂。正式阶段两个固定挂载同时存在，但任一时刻只运行一个 fio。

若 JuiceFS/Ceph 后端无法证明 B 的 metadata namespace、Ceph pool、CephX 身份和对象归属均与
既有参考卷隔离，记 `R1_FEASIBILITY_BLOCKED`，不得用“名称看起来不同”替代证据。

### 2.2 全程固定

- JuiceFS 二进制：U1 已锁定 `/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`；Gate/manifest/每个性能 cell 必须核对 exact identity；
- mount：`--max-fuse-io 256K --max-uploads 150 --cache-size 0`；
- 私有客户端 Ceph 配置：`ms_async_op_threads=8`，不得改系统 `ceph.conf`；
- fio：`fio-3.28`，`randread`、`bs=256k`、`numjobs=128`、`iodepth=128`、
  `direct=1`、`openfiles=128`、`filesize=size=1G`、`runtime=180`、`--readonly`；
- 128 个文件的数量、逻辑大小、路径模式；每个臂的 inode/size/mtime 清单在首次冻结后不变；
- 6 OSD 的 ID、up/in、weight、class、`up_from`，CRUSH map、EC profile、`fast_read=1`；
- 正式顺序、采样口径、等待时间、脚本哈希和统计模型。

### 2.3 唯一允许的工程变化与结论边界

B 相对 A 的工程变化是“**新 pool_id + 实际单调梯子选定的 PG 数 + 由此确定的 PG/CRUSH/对象布局**”。
这不是 PG 数的纯单因素实验；若 Quincy 不能提供 pool-scoped 的精确读负载控制，报告只能签：

> 该**保留的具体 B pool/layout**相对当前 A 的工程收益及其机制一致性。

不得外推为“任意新 pool”“任意 64/128 PG”或“primary 数均衡必然获得同等收益”。

---

## 三、预注册指标、计算与结论状态

### 3.1 有效带宽主口径

每轮 128 个 fio bw log，字段为 `timestamp_ms,bw_KiB/s,direction`：

1. 以所有 128 job 首次共同产生正 READ 样本的时刻定义实际 timed-I/O `t0`；
2. 按时间区间与自然秒的重叠比例加权，128 job 同秒求和；
3. 主窗口固定为 `t=[15,175)`，必须恰有 160 个 job 齐全的完整秒；
4. 逐轮主值 `BW_r` 为 160 秒聚合 READ MiB/s 的**算术平均**；median、W1--W4、CV、
   fio summary 仅作敏感性，不得替换主值；
5. 原始源：`round-*/bw/*_bw.{1..128}.log`、`fio-start-ns.txt`、`fio.txt`；
   分析器必须输出逐秒明细和缺 job 清单。

### 3.2 实际 OSD 负载操纵量

每个 OSD 在与 fio 正式窗重叠的 perf counter 差分中计算：

```text
r_i       = delta(osd.op_r) / elapsed_seconds
I_op      = max(r_i) / mean(r_0 ... r_5)
CV_op     = population_stdev(r_i) / mean(r_i)
share_i   = r_i / sum(r_i)
```

源文件为每节点本地 admin-socket 采样器的
`osd-perf-<node>.tsv`，至少包含 `epoch_ns/osd/op_r/op_r_out_bytes/op_r_latency_sum/
op_r_latency_count`；字段路径须在 Gate 0 的真实历史 JSON fixture 上验证，缺字段不得静默填 0。

同时输出以下结构量，但它们**不替代 `I_op`**：

- 单池 PG 数与 primary 直方图：从 `ceph pg dump pgs_brief -f json` 按精确 pool_id 过滤；
- acting/up 集、`pg_upmap*` 例外、CRUSH 映射；
- 每臂 pool 对象数、文件清单、B pool 的 PG 对象分布；
- `op_r/s ÷ fio read IOPS`、OSD out bytes ÷ fio bytes，检查计数链闭合。

### 3.3 预热后的机制操纵硬门

固定四个非正式轮：

```text
W01=A  W02=B  W03=B  W04=A
```

在**不读取、不汇报、不据此选择 warmup 带宽**的条件下，只复算实际 OSD 负载：

```text
mean(I_op of A warmups) >= 1.10
mean(I_op of B warmups) <= 1.05
mean(I_op_A) - mean(I_op_B) >= 0.05
```

- 三项全过：`R1_MANIPULATION_PASS`，可以进入正式矩阵；
- A 不再倾斜：`R1_MECHANISM_ABSENT_NOW`，有效负结论，停止；
- B 未改善：`R1_MECHANISM_NOT_MANIPULATED`，有效负结论，停止；
- OSD 证据缺失：`EVIDENCE_INVALID`，不是机制负结论。

这一硬门防止“primary 计数好看但实际 fast_read 负载没变”仍继续消耗八轮测试。

### 3.4 正式矩阵与统计模型

仅在 §3.3 通过后运行，顺序冻结为：

```text
R01=A  R02=B  R03=B  R04=A  R05=B  R06=A  R07=A  R08=B
```

两臂的轮序均值和二阶矩相同。逐轮模型固定为：

```text
BW_r = beta0 + beta1*(r-4.5) + beta2*(r-4.5)^2 + beta_arm*1[B]
effect_pct = beta_arm / mean(BW of A formal rounds) * 100%
```

报告 `effect_pct`、双侧 95% CI、单侧 95% 下界、原始臂均值、四个邻近跨臂对、
以及同一模型下 B 的调整均值与 95% 区间。线性模型、无趋势臂均值差和 median 只作敏感性；
禁止看完数据换模型。效应 CI 半宽超过 **5 个百分点**时记 `RESOLUTION_INSUFFICIENT`，
同一 RUN 不动态补轮。

### 3.5 最终 verdict（优先级从上到下）

| 条件 | VERDICT | 含义 |
|---|---|---|
| 任一非性能硬门失败 | `R1_EVIDENCE_INVALID` | 证据不能签，保留现场 |
| 注册后实际 map/PGP 无法闭合 | `R1_REGISTERED_MAP_SIMULATION_INSUFFICIENT` | 转实际空 pool 梯子或停止，不伪造 candidate |
| B 空 pool 实际映射不符合离线计划 | `R1_MAPPING_MISMATCH` | 不 layout，不通过重建搜索 |
| warmup 操纵检查未过 | `R1_MECHANISM_NOT_MANIPULATED` 或 `R1_MECHANISM_ABSENT_NOW` | 有效负结论，不跑正式轮 |
| 正式效应 CI 半宽 >5 pp | `R1_RESOLUTION_INSUFFICIENT` | 不把高噪声当无差异或收益 |
| B 调整均值的单侧 95% 下界 `>=6250` | `R1_TARGET_CONFIRMED` | 该保留 pool/layout 达标且统计确认 |
| B 点估计 `>=6250`，但单侧下界 `<6250` | `R1_TARGET_OBSERVED_NOT_CONFIRMED` | 观察达标，证据余量不足 |
| B `<6250` 且效应双侧 95% CI 下界 `>0` | `R1_BENEFIT_CONFIRMED_TARGET_NOT_MET` | 布局有益但目标仍不可达 |
| 效应 CI 跨 0 | `R1_NO_DETECTABLE_BENEFIT` | 未检出稳定布局收益 |
| 效应 CI 上界 `<0` | `R1_LAYOUT_REGRESSION` | 候选布局稳定退化 |

历史 `5516.7/5544` 只作外部锚点：A 正式均值偏离历史超过 `±10%` 打 NOTE，超过
`±25%` 记 `HISTORICAL_ANCHOR_NOT_COMPARABLE`，但**不得因此删除当前 A/B 样本**。

---

## 四、Phase 0：离线 Gate 0（GPT；禁止连接环境）

### 4.1 执行方 Step 0：先读方法论

GLM 在复制或调用任何脚本前，必须完整阅读本文抬头列出的六份方法论文档，并在
`methodology-ack.tsv` 记录文件路径、SHA256、读完时间与执行身份。未完成 Step 0 时，
包括只读 inventory 在内的任何环境动作都不得开始。

### 4.2 当前 feasibility Gate 的脚本范围

```text
scripts/FULLBASELINE/debug/s04r1-inventory.sh
scripts/FULLBASELINE/debug/s04r1-map-analyze.py
scripts/FULLBASELINE/debug/s04r1-driver.sh
scripts/FULLBASELINE/debug/s04r1-gate0-offline.sh
scripts/FULLBASELINE/debug/s04r1-mock-integration.sh
```

旧版 sampler、性能 analyzer 和 driver 中未开放的数据面函数不进入本次签名范围；driver 的命令分派
必须拒绝 layout/warmup/formal/close。结构档位 SELECTED 后再审核和启用这些路径。

### 4.3 Gate 0 最低断言

1. 当前范围内所有 shell `bash -n`；map analyzer 编译和单测通过；
2. `DRY_RUN_ONLY=1` 默认，未知子命令和缺 ACK 均 fail closed；
3. inventory 只读，脚本中不存在 pool create/delete、upmap、affinity、config set、OSD restart；
4. 注册和每次PG调整均先生成精确plan；缺阶段专用ACK时不得执行；
5. pool名和结果目录包含精确RUN_ID，拒绝空值、根路径、父路径和符号链接逃逸；
6. pool只创建一次；mock证明第二次注册、降PG、跳档、SELECTED后继续扩PG均被拒绝；
7. 禁止 pool delete/recreate 搜索布局，禁止更改 `juicefs-data` 的任何属性；
8. fixture验证A为32 PG且全池为33 PG，B每档仅含同一pool_id、精确32/64/128条PG；
9. analyzer拒绝合成候选、foreign pool、重复PG、primary不在acting、非六OSD和非冻结档位；
10. mock至少走通`32不过→64 SELECTED`与`32不过→64不过→128 BLOCKED`；
11. 每个真实写步骤都有有限等待，超时必须失败；B对象数始终为0，A属性指纹不变；
12. 数据面和性能命令不可分派；`git diff --check`、SHA256、mock原始证据和Gate总结落盘。

Gate 0 只证明脚本控制流，不证明线上 Ceph 能形成 R1 操纵量。

### 4.4 v1证据与v2签收状态

旧RUN `20260831-172212`在v1合同下签出的`R1_FEASIBILITY_INSUFFICIENT`继续有效，原因是工具不能
模拟尚不存在的pool；它不是R1机制负结论。v2已改用单一空pool的实际单调PG梯子，必须重新执行
当前精简Gate。Gate PASS只允许依次申请inventory、空pool注册和PG梯子授权，不允许数据面或fio。

v2 不伪造 64/128 candidate：`register-empty` 完成后保存实际 pool_id、OSDMap epoch、
OSDMap/CRUSHMap SHA256 和逐 PG 映射。若离线工具不能同时闭合 `pg_num/pgp_num` 与逐 PG map，
记录 `R1_REGISTERED_MAP_SIMULATION_INSUFFICIENT`，随后只按实际空 pool 梯子推进。

### 4.5 v2 离线签收（2026-08-31）

- 独立 mock 覆盖 32→64 `SELECTED` 与 32→64→128 `BLOCKED` 两条完整状态机；
- 覆盖重复注册/重复评估、跳档、降档、选定后继续调整以及畸形实际 PG map 的拒绝路径；
- Gate 同时核对参考 pool ID/属性不变量、B 空 pool 的完整属性合同、实际 OSDMap epoch/SHA
  归档逻辑，以及数据面/性能命令保持不可分派；
- 持久化签收目录：`/mnt/c/SunRise/test/04-1/gate0-v2-feasibility-20260831-220600/`；
- 签收结论：`R1_V2_GATE0_PASS`。该结论只批准离线合同本身，不授予任何环境执行权限。

---

## 五、Phase I/II：只读 inventory 与离线可行性（第一批可执行工作）

### 5.1 Phase I：只读 inventory

本阶段只允许读取并落盘，不允许 sudo 写、mount、fio 或 Ceph 状态变更。至少采集：

| 证据 | 必需字段/用途 |
|---|---|
| `ceph-version.txt` | 完整版本；不得沿用“Quincy 17.2.8”历史常量 |
| `ceph-status*.json` | fsid、health、OSD/PG 状态、recovery/backfill/scrub |
| `pool-detail.json` | 所有 pool 的 id/name；A 的 pg_num/pgp_num/autoscale/size/min_size/flags/fast_read/crush_rule |
| `ec-profile.txt` / `crush-map.bin` / `crush-dump.json` | k/m、failure-domain、rule、weight、class、CRUSH SHA256 |
| `osd-dump.json` / `osd-tree.json` | OSD ID、up/in、weight、primary-affinity、up_from、现有 `pg_upmap*` |
| `pg-single-pool.json` | 只按 A pool_id 过滤的 32 PG、primary/up/acting |
| `pg-all-pools.json` | 防止再次把全池 33 PG 当目标池 |
| `ceph-features.txt` / `ceph-help.txt` / `osdmaptool-help.txt` | 当前工具能力；以现场 help/schema 为准 |
| `auth-readonly.json` | 只列实体与 caps，不输出 key；证明后续可新增隔离 B 身份；本阶段不创建身份 |
| `ceph-df.json` | pool `MAX AVAIL`、cluster raw avail、PG/OSD 容量背景；空 pool 梯子不写数据 |
| `runtime-inventory.txt` | foreign fio、t64/t65/t66/u141、临时挂载、维护/恢复任务；只清点不 kill |
| `runtime-inventory.txt` 中的参考指纹 | `/mnt/juicefs`、系统 ceph.conf SHA256、foreign进程；卷 UUID/TiKV endpoints 延后到数据面独立Gate |

Phase I 完成后暂停。任何“现场顺手试一个 ceph 命令”的写操作都超出授权。

### 5.2 Phase II：生成注册空 Pool 计划（只生成，不执行）

`plan-register-empty` 只由 Phase I 的 `osd-dump.json` 计算下一可分配 pool_id，并写出精确计划：
创建唯一 B pool、`pg_num=pgp_num=32`、`pg_autoscale_mode=off`、复用既有 EC profile/CRUSH rule。
计划明确不包含 auth、format、volume、mount、layout、data 或 pool delete。生成后立即暂停。

### 5.3 Phase III：注册空 Pool、稳定化并冻结 map

`register-empty` 是唯一建池动作，默认 `DRY_RUN_ONLY=1`，真实执行需要精确
`I_ACK_R1_REGISTER_EMPTY_<RUN_ID>`。只创建一次 B pool，不创建 CephX auth，不创建 JuiceFS volume，
不挂载、不写数据。等待 B pool 全部 PG `active+clean`，随后保存包含 B 的 OSDMap 和逐 PG 实际映射；
完成后立即暂停。pool_id 或实际状态异常时保留现场并停止，禁止 delete/recreate。

RUN `20260901-125124`在五条建池命令成功后，因Quincy的pool detail字段为`pool_id`而旧driver只读取
`pool`，在写本地状态标记前中断。该RUN只允许在修复脚本和新Gate独立通过后，以精确ACK调用
`adopt-registered-empty`：只读核验已存在B Pool的ID、属性、对象数、32 PG、参考Pool、CRUSH和OSD
不变量，并补齐冻结映射与状态标记；该入口不得创建、删除或修改Pool。禁止重跑`register-empty`。

恢复入口离线Gate已于2026-09-01通过，证据位于
`/mnt/c/SunRise/test/04-1/gate0-v2-recovery-20260901-142408/final/`。Gate覆盖缺ACK拒绝、一次接管成功、
重复接管拒绝和Quincy `pool_id`字段兼容；结论仍为`R1_V2_GATE0_PASS`。该Gate只授权恢复控制流，
不自动授权任何PG调整。

第一次接管发现Ceph为新EC Pool自动创建了rule ID=2；它与A的rule ID=1名称/ID不同，但实际steps
完全相同。恢复验证因此改为：参考Pool及其旧rule逐项不变；CRUSH非rule内容不变；只允许新增B所用
的一个rule，且去除`rule_id/rule_name/ruleset`后的语义必须与A rule完全相同。禁止再要求B复用同一
rule ID或要求建Pool前后整张CRUSH map字节相同。

### 5.4 Phase IV：同一 pool_id 的实际 PG 梯子与结构门

现有 `osdmaptool --test-map-pgs` 只能输出比例化汇总，不能证明实际 `pgp_num=64/128` 的逐 PG
映射；`--test-map-pgs-dump` 也不能覆盖 `pg_num`。离线能力探针若不能同时闭合 `pg_num/pgp_num`
和逐 PG 映射，记录 `R1_REGISTERED_MAP_SIMULATION_INSUFFICIENT`，随后转入实际空 pool 梯子。
注册 pool 为空，不发生用户数据迁移。

实际档位严格为 32→64→128，禁止降 PG、删除重建、换 pool_id、同时创建多个 pool 或按性能选择。
每档只保存实际 OSDMap/逐 PG 映射，并由 analyzer 输出结构指标。六 OSD/32 PG 下整数分布的理论
最优为 `I_primary=6/(32/6)=1.125>1.05`，所以 32 只能是注册起点，不能 `SELECTED`；Gate/mock
必须覆盖 32 `NEXT_REQUIRED`、64 `SELECTED` 后拒绝 128，以及 64 失败后 128 继续和 128 `BLOCKED`。

候选 PG 数预先冻结为：

```text
CANDIDATE_PG_NUM = {32, 64, 128}
```

对**已注册且当前实际冻结的同一个 pool_id**逐 PG 映射计算：

```text
n_i            = 该候选中 primary 为 OSD i 的 PG 数
I_primary      = max(n_i) / (pg_num / 6)
CV_primary     = population_stdev(n_i) / mean(n_i)
acting_count_i = acting 集中包含 OSD i 的 PG 数
```

按 `(I_primary, CV_primary, pg_num)` 结构门选择；不得用带宽、历史高分 pool_id 或性能参与选择。
每档实际布局必须同时满足：

```text
I_primary <= 1.05
current_I_primary - candidate_I_primary >= 0.075
pg_num <= 128
```

其中 `current_I_primary` 从 Phase I 参考 A 动态计算，不写死。若 map、pool_id、health、对象数为 0
或参考 pool 指纹不能闭合，记录 `R1_MAPPING_MISMATCH` 并停止；不得创建 dummy pool、第二个 pool
或 delete/recreate 搜索 ID。`evaluate-layout` 只输出 `SELECTED/NEXT_REQUIRED/BLOCKED`，不得读取性能数据。

### 5.5 可行性分级

| 状态 | 条件 | 后续 |
|---|---|---|
| `R1_ACTUAL_LAYOUT_SELECTED` | 实际 PG 梯子中某一档满足结构门且可精确复核 | 可生成数据面计划 |
| `R1_REGISTERED_MAP_SIMULATION_INSUFFICIENT` | 离线工具不能闭合 64/128 逐 PG map；转实际空 pool 梯子 | 不得伪造 candidate |
| `R1_FEASIBILITY_BLOCKED` | 无候选达门、只能用全局 primary-affinity/生产 upmap、或隔离身份/容量不成立 | 签负结论，任务结束 |
| `R1_FEASIBILITY_INSUFFICIENT` | map/feature/capacity 证据缺失或模拟与现场工具无法闭合 | 补只读证据，不得建 pool |

在 EC 4+2 恰好六个 OSD 时，acting-count 很可能天然相等；若所有 acting set 都包含同六个 OSD，
普通 acting-set 均衡不能冒充 primary/read-load 控制。全局 `primary-affinity` 会影响其他 pool，
**不属于可行方案**。是否存在 `pg-upmap-primary` 等能力以 Phase I 的现场版本为准，禁止按新版文档想当然。

若当前档位未过门且仍小于 128，`plan-adjust` 只生成把同一空 B pool 调整到下一个档位的精确计划并暂停；
`adjust-verify` 经独立 ACK 后执行调整、等待 clean、冻结新 map 并逐 PG 核对。若某档 `SELECTED`，
立即禁止任何后续 adjust；若 128 仍未过门，签 `BLOCKED`。任何 mismatch 均停止，不得创建 auth/volume/data。

### 5.6 后续数据面（当前未签收、未授权）

仅在 `evaluate-layout` 输出 `SELECTED` 后，才修订并重新审核数据面脚本与独立 Gate 0；随后另行
申请创建 auth、format/volume 和一次性 layout 的授权。当前 v2 feasibility Gate 即使 PASS，
也不构成这些操作的执行权限。A `juicefs-data` 是参考 pool/固定基线资产，始终严禁修改。

---

## 六、后续数据面设计草案（当前不进入可执行状态机）

只有 Phase IV `evaluate-layout` 输出 `SELECTED` 时生成，至少冻结：

```text
RUN_ID
RESULT_ROOT=/tmp/production/opencode-04-1-<RUN_ID>
POOL_B=jfs-r1-<RUN_ID>
META_B=tikv://<动态采集的三端点>/jfs-r1-<RUN_ID>-b
MNT_A=/tmp/jfs-r1-<RUN_ID>-a
MNT_B=/tmp/jfs-r1-<RUN_ID>-b
PG_NUM_B=<实际 SELECTED PG 档位>
BINARY_PATH/BINARY_MD5
SYSTEM_CEPH_CONF_MD5/PRIVATE_CEPH_CONF_SHA256
```

计划必须逐行展示且验证：

1. 只在 Phase III 创建 `POOL_B` 一次，Phase IV/后续禁止第二个 pool；复用现有 `ec-prod`/CRUSH rule；
2. 注册阶段固定 `pg_num=pgp_num=32`、autoscale off；扩 PG 另由 `plan-adjust` 精确列出；
3. auth 只能在 `adjust-verify` 通过后的独立阶段创建；不得扩大或改写参考 pool 的身份 caps；
4. B metadata namespace 唯一，format 前后 A 的 URI、UUID、Setting 与对象数指纹不变；
5. 128 GiB 逻辑数据按 EC 1.5× 与余量计，B pool `MAX AVAIL >=512 GiB`；
6. exact create、verify、graceful-unmount、volume destroy、auth remove、pool delete 的**计划**分别输出；
7. rollback 只能指向 state 文件中精确记录的 B UUID/auth/pool；未完成归属核验时拒绝；
8. 默认收口是**保留** B pool、namespace 和数据，不执行 destroy/delete；真正删除需测试报告审核后的新授权。

后续 Gate 应输出 `plan-data-plane.txt`、`plan-preserve.txt`、`plan-destroy.txt`、`sudo-writes.txt`
和 SHA256 后暂停。用户批准的是精确计划，不是“可自行处理 Ceph”。

---

## 七、后续数据面执行草案（当前不授权）

获得单独授权后，执行已审核 plan；完成以下内容立即暂停：

1. 仅在 `adjust-verify` 通过后创建 B auth/volume；记录精确 UUID/caps/state；
2. 核对 A 参考 pool 所有属性、CRUSH SHA256、OSD `up_from`、系统 ceph.conf MD5、生产卷 UUID 未变；
3. 输出实际 `I_primary/CV_primary/acting_count`，随后才可进入一次性 layout。

若 pool_id 或任一逐 PG 映射不符，记 `R1_MAPPING_MISMATCH`：**保留空 pool、停止，不 layout，
不得删除重建寻找下一个 pool_id，也不得现场改 PG 数**。若一致，也必须等 GPT/用户批准后才进入 layout。

---

## 八、后续一次性 Layout、稳定化与机制操纵检查草案

### 8.1 B 卷和一次性 layout

1. 在唯一 `META_B` format B 卷，bucket 只指向 `POOL_B`；核对 A UUID/Setting 不变；
2. B 以可写挂载完成且仅完成一次：

```text
read_test.{0..127}.0，共128个；每个1073741824字节；总逻辑大小128GiB
fio: write, bs=4MiB, numjobs=128, filesize=size=1GiB,
     fallocate=none, direct=1, libaio, iodepth=128, end_fsync=1
```

3. 逐文件核对 128/128 均为 1 GiB；禁止重现“P0 只写 512 MiB”的 D29 契约缺陷；
4. 保存 inode/size/mtime、B UUID、对象数/bytes、PG object histogram、layout 命令和 bw log；
5. 优雅卸载 B，之后 A/B 都按 §2.2 固定参数只读挂载；冻结 worker PID、PPID、starttime、exe MD5、
   mount line 和 UUID。后续任何 PID/starttime 变化都停止，禁止自动重挂；
6. 从此不再 format、destroy、GC、layout、改 PG、改 pool 属性。

### 8.2 固定稳定化门

layout 完成后使用**固定条件**等待，不依据带宽决定等待时长：

- 至少等待 300 秒；
- Ceph 连续 3 次（间隔 30 秒）`HEALTH_OK`，B 全部 PG active+clean；
- 无 recovery/backfill/degraded/misplaced/scrub；
- 6 OSD `compact_running=0` 且 `compact_queue_len=0` 连续 3 次；
- B pool objects/stored 连续 3 次完全相同；A pool 不允许对象上涨，下跌累计不超过 1000；
- 无 foreign fio、rados bench、其他测试 mount/loop/临时集群；
- A/B 两个闲置挂载均无错误，非活动臂的后台 op 只记录，不得有持续业务 I/O。

本任务不因“看起来已经稳了”缩短，也不因某轮带宽低动态增加 cooldown。

### 8.3 固定预热与操纵检查

先执行 W01--W04。每轮前对客户端和三个 OSD 节点执行相同的 `sync + drop_caches`，固定等待
20 秒；只在该轮目标臂运行 fio，另一臂保持空闲。每轮均采齐正式轮同级证据。

W04 后仅按 §3.3 的 OSD `I_op` 判是否操纵成功；GLM 不得打开 analyzer 的带宽结果。
阶段输出 `MANIPULATION_PASS/FAIL` 后暂停。失败是 R1 的有效负结论，不通过 relayout、换 PG、
重建 pool 或延长 warmup 修复。

### 8.4 scrub 分段控制（上环境前必须补到脚本/Gate）

R1 是长多臂读矩阵，OSD 例行 scrub 会直接竞争读路径，不能仅靠 fio 前后两次
`HEALTH_OK` 排除正式窗内短 scrub。又因 Phase V 结束后要停下来审核操纵量，禁止用一个
全局 lease 跨越人工审核时间。冻结为：

1. Phase V W01--W04 使用 `<RUN_ID>-phase-a` 独立 lease；设置前冻结 FSID/原 flags/
   health/OSD/PG，同时 pause `noscrub + nodeep-scrub`，等已运行 scrub 退出后才跑 W01。
2. W04 成功、失败或操纵量不过时，都先 state-driven restore/verify 该 lease，然后才回传审核；
   禁止在等待 GPT/用户时保持 scrub 暂停。
3. 只有操纵门通过且正式阶段另行授权时，才使用 `<RUN_ID>-phase-b` 独立 lease 跑 R01--R08；
   R08 或任何失败后立即 restore/verify。两个 lease 的 state/审计不得复用或覆盖。
4. 两个 phase 内每轮仍验证 lease ownership、唯一 `OSDMAP_FLAGS` WARN、OSD up/in、
   逐 PG `active+clean` 且无 `scrubbing/deep`；任何其他 health check 立即停止。
5. 控制脚本可复用已通过 self-test 的 `u141d-scrub-control.sh`，但须使用 R1 独立 state dir；
   driver 必须在每轮前后调用 `verify-paused`，并在所有失败分支将 restore 置于证据收口之前。
6. Gate 0 须新增：原有/foreign flag、部分 pause、唯一 WARN、逐轮 lease 漂移、两 phase 独立、
   失败优先 restore 与“未 pause 禁止跑 fio”mock。在这些断言全部 PASS 前，Phase V 没有环境权限。

---

## 九、后续八轮正式 A/B 草案

获得授权后连续执行 R01--R08；阶段内部不得逐轮请示，只有硬门失败才停。

### 9.1 每轮非性能硬门

1. 当前轮 arm/tag 与冻结矩阵一致，目标 OUT 不存在，禁止覆盖；
2. A/B 两个挂载 PID/starttime/exe MD5/UUID/mount options 与冻结值一致；
3. A/B pool_id、pg_num/pgp_num、fast_read、autoscale、CRUSH、PG 映射和 `up_from` 均未变化；
4. 本 phase scrub lease ownership/`verify-paused` 通过；health 只允许该两 flags 导致的唯一
   `OSDMAP_FLAGS` WARN，两 pool 全部 PG active+clean，无 recovery/backfill/degraded/misplaced/scrub；
5. 无 foreign fio/rados bench；本轮只存在一个属于 state 文件的 fio PGID；
6. 固定 `sync + drop_caches` 与 20 秒等待成功；不得 compact、restart OSD、重挂或清卷；
7. fio rc=0，READ summary 存在，128 个 bw log 恰好各一份，正式窗 160 秒完整；
8. sampler heartbeat 覆盖 `[t0-5,t0+180+5]`，OSD 六台齐全，无 counter 回绕；
9. 只读轮中 B objects/stored 不变；A objects 不涨、累计下跌不超过 1000；
10. 系统 ceph.conf、既有参考卷 UUID/Setting、主挂载 `/mnt/juicefs` 指纹不变。

任一失败：先写 `incidents.tsv` 动作前记录，停止 fio/采样器时只按精确 PID/PGID，保存现场，
写动作后记录并退出；不得继续后面的轮，也不得把失败轮换成“R08b”。

### 9.2 只记录、不废样

带宽高低、CV、W4/W1、OSD util、延迟、CPU、NIC、cache hit、`I_op`、C_amp 和历史锚点偏离
均不构成删样理由。性能不达标是结果，不是环境故障。

---

## 十、Phase VII：安全收口、回传与独立复算

### 10.1 执行方收口

R08 后：

1. 结束本任务 sampler，并证明全部 wait rc 已记录；
2. 优雅卸载 B、A 专用挂载，先核 UUID/PID/starttime；禁止 kill mount PID、lazy/force unmount；
3. 不触碰 `/mnt/juicefs`；不 destroy B 卷、不删 B pool、不删 B CephX 身份；
4. 采集参考环境指纹、A/B pool/PG/CRUSH、Ceph health、残留进程/挂载；
5. 生成相对路径 manifest、SHA256、tar 及 tar 校验；归档后才写 `ALL_DONE`；
6. 将 157/集群节点的原始归档、实际脚本、manifest 和本地生成的 Gate/分析/报告全部持久化到
   `/mnt/c/SunRise/test/04-1/<RUN_ID>/`；源端与持久化副本的 SHA256、文件数及归档可读性全部
   核对通过后，才允许写 `PERSISTENCE_PASS` 或清理服务器临时结果；
7. GLM 只回传硬门、原始证据位置、incident 和脚本输出，不计算效应、不挑轮、不宣布达标。

本任务中的 `RESULT_ROOT=/tmp/production/opencode-04-1-<RUN_ID>` 是 157/远端运行时工作目录，
不是最终交付落点；`/tmp`、远端 `/tmp` 和 `/tmp/production` 均不得成为证据的唯一副本。
电脑或 WSL 重启后，只以 `/mnt/c/SunRise/test/04-1/<RUN_ID>/` 中通过 manifest 校验的副本恢复。

### 10.2 GPT 独立复算

GPT 从 raw bw logs 和 OSD counters 独立生成：

- 8 轮逐秒 BW、逐轮主值、A/B 原始均值、固定 OLS、CI 和四个跨臂对；
- 每轮六 OSD `op_r/s`、`I_op/CV_op/share_i`、延迟与 out bytes；
- `I_op` 改善是否与 BW 改善同向；primary/PG 代理量与实际负载是否闭合；
- B 的 6250 点估计、单侧下界及 §3.5 唯一 verdict；
- 历史 5516.7/5544 只作锚点的明确标注；
- 结论只适用于保留的确切 pool_id/PG/layout，或签出 feasibility 边界。

完成报告并由用户决定保留、迁移评估或销毁后，才能另行生成精确 cleanup 任务。若 B 有收益，
优先保留其 pool_id 和 layout；删除重建会丢失本次被验证的确定性映射，不能视为等价恢复。

---

## 十一、交付物清单

每个阶段至少交付：

```text
phase-status.tsv                 # phase/state/start/end/rc/verdict
commands.sh                      # 实际命令，printf %q；秘密值脱敏
input-sha256.txt                 # 二进制、脚本、配置、任务书
incidents.tsv                    # 即使无 incident 也有表头
inventory/                       # Phase I 全部只读证据
mapping/                         # 注册后各 PG 档实际 map、结构指标和逐PG差异
plans/                           # create/preserve/destroy/sudo 计划
state/                           # pool/auth/namespace/mount/PID/UUID 精确归属
layout/                          # 一次性 layout、128文件合同、对象/PG分布
warmup/W01..W04/                 # 完整 raw，不参与性能估计
formal/R01..R08/                 # fio、bw、OSD、NIC、health、fingerprint
manifest.sha256
archive.tar.zst + archive.sha256
persistence.tsv                 # 持久化路径、源/目标文件数、SHA256与归档可读性
```

上述目录树的最终持久化根为：

```text
/mnt/c/SunRise/test/04-1/<RUN_ID>/
```

报告文件预留：

```text
doc/perf-report/04-1-randread-pg-layout-feasibility-and-isolated-pool-ab-<YYYYMMDD>.md
```

首行必须包含一个 §3.5 中的机器可读 `VERDICT=<value>`。

---

## 十二、通用注意事项与安全红线

1. ⛔ 不修改 `juicefs-data` 的 pg_num/pgp_num/autoscale/fast_read/CRUSH/upmap/affinity；
2. ⛔ 不修改任何既有参考 pool、既有卷、既有 TiKV namespace、既有 CephX caps；
3. ⛔ 不使用 `ceph config set`，不改系统 `/etc/ceph/ceph.conf`，不重启 OSD/PD/TiKV；
4. ⛔ 不使用全局 `primary-affinity` 作为 B 的替代方案；
5. ⛔ 不删除/重建 pool 搜索高分映射；只允许按预注册状态机在空 pool 上执行32→64→128
   单调梯子，某档一旦SELECTED立即禁止继续改PG；
6. ⛔ 不重复 layout，不在轮间 format/destroy/GC/compact/remount；
7. ⛔ 不运行 randwrite/randrw/mseqwrite，不允许 fio 创建缺失文件；正式 fio 强制 `--readonly`；
8. ⛔ 不使用 `pkill`、`killall`、`fuser -k`、模式 kill、kill mount PID、lazy/force unmount；
9. ⛔ 不使用宽路径递归删除、`losetup -D`、设备 wipe，不写 `/dev/nvme*`、`/opt`、`/etc`、
   `/var/lib/ceph`、`/mnt/jfs-tikv`；
10. 当前 feasibility 合同的 sudo 写权限只可能覆盖：精确创建一个 B 空 pool，以及同一空 pool
    按状态机增加到64/128 PG；auth、volume、mount、layout、fio、drop_caches均不在当前授权内；
11. 脚本一字节修改后原 Gate 0 和授权失效；同 RUN 不热修，必须保留并另行审计；
12. 失败先保留现场，清理本任务自有进程也必须按 state 中 PID+starttime+exe/PGID 核验；
13. 密码、Ceph key 不写报告/commands/trace；只记录实体名、caps 和 keyring SHA256；
14. 长测遵守 heartbeat、有限等待和阶段停点；网络中断恢复时先 inspect，不重复已完成命令；
15. 执行方不做统计选择；GPT 不接受只含 summary、缺 raw logs 或缺 manifest 的结果。

### 最终红线一句话

当前 feasibility 合同只允许新增**一个经批准且精确命名的空测试 pool，并在对象数为0时按
32→64→128单调增加PG**；身份/namespace、128 GiB读数据和专用挂载均等待后续独立Gate。
绝不能碰的是现有 `juicefs-data`、`juicefs-prod`、`/mnt/juicefs`、
既有 PD/TiKV/Ceph 配置与服务，以及任何不能由本 RUN state 精确证明归属的对象、PID、路径或身份。
