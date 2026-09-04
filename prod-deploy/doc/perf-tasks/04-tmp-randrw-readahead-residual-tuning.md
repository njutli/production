# 04-tmp 任务书：randrw 当前栈剩余调优——`max-readahead` 严格 A/B

## 日期：2026-08-30

> 实验编号：**TMP-RW1**；04 阶段暂存任务，**不占正式 `04-N` 编号**。
>
> 面向：GLM 分阶段执行；GPT 负责离线 Gate 0、阶段间审核、原始数据独立复算和最终签收。
>
> 当前状态：`COMPLETE / VALID / KEEP_DEFAULT_READAHEAD / LIFECYCLE_CLOSED`。
> 正式RUN `20260831-231629`已完成12/12 cell、持久化和GPT独立复算；冻结verdict为
> `RW_RA_INCONCLUSIVE`，但两向95% CI上界均低于`+5%`材料阈值，工程决策为保持默认readahead、
> 不补测并关闭当前栈该调优方向。正式结果见
> `doc/perf-report/04-tmp-randrw-readahead-residual-tuning-20260901.md`。
>
> 承接：`doc/perf-analysis/04-metadata-architecture-and-layout-plan.md`、
> `doc/perf-analysis/CURRENT-JUICEFS-PERFORMANCE-STATUS-20260830.md`、
> `doc/perf-report/03-JUICEFS-PERFORMANCE-TUNING-FINAL-REPORT-20260828.md` §6.4、
> `doc/perf-report/03-6-max-fuse-io-and-instrumentation-20260812.md`、
> `doc/perf-report/03-17f-deliver-config-baseline-20260821.md`。
>
> 方法论：`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/fixtures/known-defect-classes.tsv`、`skills/TUNING-SKILL.md`、
> `skills/TESTING-GUIDE.md`、`skills/test-commands-reference.md`、
> `skills/LONG-RUNNING-TEST-SKILL.md`、`skills/SYSTEM-SAFETY-SKILL.md`、
> `skills/baseline-reproduction-skill.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`。
>
> 口径优先级：本任务冻结口径与 `EVIDENCE-INTEGRITY-SKILL.md`、作者指南 §二.13--20
> 优先于旧文档中“截前段取中位数”“fresh volume”“把 randrw 两向相加”及旧静态基线的表述。

```text
EVIDENCE_LEVEL=L2_FORMAL
SCREEN_SOURCE=旧 ra0 有正/零两类观测 + 03-6 当前 256K 栈 randrw 收益；足以说明值得一次正式闭合
SCREEN_CONTINUE=已满足；randrw 是生产规格唯一明确混合 IO 模型，不用新的低精度 screen 再消耗一轮写历史
SCREEN_STOP=Phase I 资产/清理起点不可复现则不进入正式阶段
FORMAL_MATRIX=4 固定预热 + A,B,B,A,B,A,A,B
ESTIMATED_WALL_CLOCK=7--10 h（fio 纯负载 36 min，其余为写后 GC/cooldown/对象回归与证据；最坏约 14h）
MAX_SCRUB_LEASE=16h
```

---

## 计划线（冻结）

```text
03：max-fuse-io=256K 已使 randrw 每向约 +53%，当前每向约 1870
U1/U141d：已锁定 exact patched V14；randrw版本效应读/写为−0.52%/−0.51%
04 当前在途任务：全部结束、环境与 scrub lease 完整收口
  ↓
04-tmp Phase 0：新脚本离线 Gate 0                         ← 已完成
  ↓
Phase I：只读 inventory、冻结版本/资产/计划，回传审核     ← 已完成
  ↓（用户单独授权）
Phase II：default 与 ra0，4 预热 + ABBA-BAAB 八轮正式矩阵 ← 已完成
  ├─ 双向均有材料收益：形成 randrw 候选配置，不自动交付
  ├─ 无双向材料收益：关闭 readahead 当前栈调优方向
  ├─ 一向增一向降：记 trade-off，不改变交付配置
  └─ 实际：两向约+1.6%，CI上界<+5% ⇒ 保持default，不补测
  ↓
条件后续：04-1 布局的 randrw 端点 / 本地读缓存，均另立任务
```

一句话任务：在 U1 锁定的最终二进制和 03 交付配置上，只改变是否显式设置
`--max-readahead 0`，用既有固定数据集严格判断 randrw 读、写两向是否同时获得可交付收益。

---

## 〇、背景、价值与边界

### 0.1 为什么仍需补这一刀

当前正式 randrw 基线为读 `1870 MiB/s`、写 `1870 MiB/s`，各为目标 `6250 MiB/s` 的
`29.9%`。同挂载真实重叠窗的读写呈强反相关，合计服务量主要约 `4.0--4.2 GiB/s`；严格目标
要求读写各 `6250 MiB/s`，即总有效服务能力约 `12.5 GiB/s`。因此本任务**不预期一个挂载参数
补齐约 3 倍缺口**，但 randrw 是存储规格指定的核心模型，最后一个有明确机制依据的挂载变量仍应
在当前栈上正式闭合。

历史 readahead 证据互相不能直接替代：

- 较早的 100GbE/128K/旧基座实验曾观察到 ra0 明显降低随机读放大并改善 randrw；
- 另一次旧 1Gbps 专项 sweep 中，ra0 改善 randread，但 randrw 总服务量基本不变；
- 03-6 在**默认 readahead**下确认 `max-fuse-io 128K→256K` 使 randrw 每向约 `+53.1%`；
- 03-17f 交付配置是 `--max-fuse-io 256K --max-uploads 150 --cache-size 0`，没有显式 ra0；
- 尚无“当前最终二进制 + 256K FUSE + msgr=8 + 当前数据资产”下的严格同窗 A/B。

所以旧文档中“ra0 必然提升”或“ra0 对 randrw 必然无效”都只能作为先验，不能作为本任务结论。

### 0.2 本任务唯一改变的变量

| 臂 | 挂载参数 | 含义 |
|---|---|---|
| **A / DEFAULT** | 不传 `--max-readahead` | 当前 03 交付配置，对照臂 |
| **B / RA0** | 追加 `--max-readahead 0` | 候选臂 |

两臂其余内容必须逐字符相同。任何额外 mount、Ceph、fio、文件布局或系统参数差异都会使本任务失效。

### 0.3 本任务明确不做

1. 不调 `rwmixread`、`numjobs`、`iodepth`、`bs` 或文件数；改变规格负载不算调优。
2. 不测试多个 `max-readahead` 非零档；先闭合“当前默认 vs 完全关闭”这一有机制依据的二元问题。
3. 不做 format、destroy、fresh volume、create-on-open 或新 layout。
4. 不改变 `max-fuse-io`、`max-uploads`、cache-size、msgr 线程数、PG、CRUSH、pool 或 TiKV。
5. 不测试多挂载并行拆读写；它改变原单挂载 randrw 验收语义，只能另作架构探针。
6. 不在本任务启用本地读缓存或 `--writeback`；缓存改变路径和冷热语义，须另立任务。
7. 不把本任务的正收益自动外推给 seqread/mseqread/randread，也不自动改交付配置。

---

## 一、目标、估计量与唯一通过条件

### 1.1 唯一正式问题

> 在 U1 锁定的最终二进制、03 交付配置、同一既有 128×1GiB `rw_test` 数据资产、同一 Ceph/TiKV
> 数据面和相同状态净化合同下，显式 `--max-readahead 0` 相对当前默认值，能否使 randrw 的
> **READ 与 WRITE 两向都获得至少 5% 的可复现收益**，且不只是把固定共享容量从一向挪给另一向？

这是本任务唯一的通过/不通过问题。READ 与 WRITE 是两个共同主端点，必须分别报告和判定。

### 1.2 主估计量

每轮、每方向使用实际 timed-I/O 起点后的 `[15,175)` 共 160 个完整秒的算术平均带宽。
分别拟合冻结模型：

```text
Y(d,r) = beta0(d) + beta1(d)*(r-4.5) + beta2(d)*(r-4.5)^2
                    + beta_arm(d)*1[RA0]
effect_pct(d) = beta_arm(d) / mean(DEFAULT formal rounds, d) * 100%
d ∈ {READ, WRITE}
```

报告每向 `effect_pct`、双侧 95% CI、单侧 95% 下界、A/B 原始均值、逐轮点值和四个相邻跨臂对。
线性模型、不去趋势臂均值、median 只作敏感性；禁止看数据后更换主模型。

### 1.3 只作机制解释的端点

- READ/WRITE 每向的秒级 CV、P10/P90、W1--W4 和 `W4/W1`；
- READ+WRITE 合计服务量与秒级相关系数；**合计只解释共享容量，绝不与 6250 单向目标比较**；
- client NIC RX/TX、JuiceFS FUSE/read/object 指标、OSD client op/bytes/latency；
- 读放大代理量，例如 `client_rx_bytes / fio_read_bytes`，前提是 inventory 已实查字段和背景流量；
- 每轮前后 pool objects/stored、compact 状态、挂载进程 CPU/RSS、主机负载。

这些指标不能删除性能较差的样本，也不能替代双向带宽判定。机制 sidecar 缺失时标记
`MECHANISM_EVIDENCE_INCOMPLETE`；核心 fio/身份/健康证据仍完整时，不自动抹掉带宽效应量。

### 1.4 工程边界与 verdict

`5%` 是本任务预注册的最小材料收益：当前每向约 1870 MiB/s 时约为 94 MiB/s，低于此值不足以
改变约 3 倍架构缺口，也不值得为全局挂载语义增加交付复杂度。

优先级从上到下：

| 条件 | VERDICT | 动作 |
|---|---|---|
| 任一非性能硬门失败或矩阵缺臂 | `RW_RA_EVIDENCE_INVALID` | 只作工程观察，禁止拼样 |
| 任一方向效应 CI 半宽 `>5 pp` | `RW_RA_RESOLUTION_INSUFFICIENT` | 只报边界；另 RUN 是否增样另行讨论 |
| 两向点估计均 `>=+5%`，且两向单侧 95% 下界均 `>0` | `RW_RA0_DUAL_DIRECTION_BENEFIT_CONFIRMED` | 形成候选；不得自动交付 |
| 任一向效应 CI 上界 `<-5%` | `RW_RA0_REGRESSION` | 保持默认配置 |
| 一向 `>=+5%`、另一向 `<+5%`，或任一向 `<=-5%` | `RW_RA0_DIRECTION_TRADEOFF` | 不替换当前配置 |
| 两向均未满足材料收益且 CI 与 0 相容 | `RW_RA0_NO_MATERIAL_BENEFIT` | 关闭当前栈 readahead 方向 |
| 其余 | `RW_RA_INCONCLUSIVE` | 逐对报告，不择优补点 |

另行标注但不改变上述 verdict：两向各自点估计/单侧 95% 下界是否达到 `6250 MiB/s`。
历史 `1870/1870` 仅作外部锚点；同 RUN 的 A 臂才是正式对照。

---

## 二、冻结实验合同

### 2.1 开跑依赖

必须同时满足：

1. U1/U141d 已产生最终版本 verdict；本任务按下表锁定唯一二进制；
2. 当前全部在途性能任务已收口，无 foreign fio、临时集群、测试 mount/loop 和未恢复 scrub lease；
3. 若 04-1 已改变正式交付 pool/layout，必须先回到本文重新冻结基线，禁止临场选择更快的 pool；
4. 现有 `rw_test.*.0` 被确认是测试资产，允许覆盖写；没有该授权不得运行；
5. 专用脚本、任务书与 analyzer 的 manifest 已冻结且 Gate 0 PASS；
6. Phase I 动态 inventory 和所有 sudo/全局 scrub 计划已回传并单独获批。

二进制固定为 `/tmp/juicefs-1.4.1-patched`，MD5
`24fae0852051c80ca571cb2f20275d46`。当前 HOLD 只来自排期与环境授权。

### 2.2 固定配置

| 项 | 冻结值 |
|---|---|
| mount 共性 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端 | 私有 `CEPH_CONF`；`[client] ms_async_op_threads = 8`；系统配置不变 |
| fio | `rw=randrw`，默认 50/50，`bs=256KiB`，128 jobs，128 files，`openfiles=128` |
| fio engine | `libaio`，`iodepth=128`，`direct=1`，`fallocate=none` |
| duration | `time_based`，`runtime=180s`，每 job 逐秒 bw log |
| 数据 | 既有 `rw_test.0.0`～`rw_test.127.0`，128/128 均为 1GiB |
| 路径 | 同一 metadata volume 的精确测试目录；不 create、不扩文件、不改文件数 |
| 挂载 | RUN_ID 专用 `/tmp/jfs-s04tmp-<RUN_ID>-<LABEL>`；不卸载/替换 `/mnt/juicefs` |
| 缓存 | 冷态；每 cell 前执行同样的 drop_caches 合同；不 warmup JuiceFS 本地缓存 |
| 随机序列 | 四个跨臂 pair 使用冻结的四组 randseed；配对两侧相同 |

`iodepth` 不作为调优变量；FUSE 上的有效并发主要来自 128 jobs。`rwmixread` 默认值必须在
Gate 0 和实际 `commands.sh` 中显式展开为 50，避免依赖不同 fio 版本默认值。

### 2.3 数据资产和“禁止新 layout”合同

首次只读挂载后必须保存：

- metadata URL 的脱敏标识、volume UUID、Setting、测试根目录真实路径；
- `rw_test` 128 个文件的 path、inode、size、mtime；size 必须 128/128 等于 1073741824；
- 文件名集合 SHA256、总逻辑大小、所在 pool 与对象数；
- 不存在符号链接逃逸、缺文件、额外同前缀文件或正在访问这些文件的 foreign fio。

randrw 会改变文件内容与 mtime，这是预期性能负载；inode、文件名和 size 不得变化。
本任务不校验数据内容相等，也不以 mtime 不变作为硬门。任何脚本包含 layout、format、destroy、
`create_on_open`、删除 `rw_test` 或重建 pool 的路径，Gate 0 必须直接失败。

### 2.4 挂载型变量的实例噪声处理

`max-readahead` 需要 remount，不能做同一进程在线切换；单次 A/B 会把参数效应与挂载实例档位混合。
因此正式矩阵每个 cell 使用一个独立专用挂载，按完整平衡顺序比较分布，不挑“好档”实例：

```text
预热（不入效应量）：W01=A  W02=B  W03=B  W04=A
正式：              R01=A  R02=B  R03=B  R04=A |
                    R05=B  R06=A  R07=A  R08=B
```

A/B 正式占位均值均为 4.5，二阶矩相同。每臂 4 个独立挂载；不得用单个 ABBA block、AAAABBBB、
补样或同 label 重试。`mseqread/randread` 探针会被 readahead 本身改变，且历史证明探针对 randrw
不能可靠归一化，故：

- randseed 配对固定为 `P1=R01/R02`、`P2=R03/R04`、`P3=R05/R06`、`P4=R07/R08`；
  四组精确 seed 在 Gate 0 前写入冻结 manifest，执行时不得临场生成；
- 不按探针带宽删除、重挂或归一化任何 cell；
- 挂载档位只作为未观测随机效应与解释限制；
- 通过平衡顺序、独立挂载、固定模型、CI 与状态机控制；分辨力不够就如实签不足。

### 2.5 写历史与固定净化

每个 cell 只跑一个 180s randrw 正式负载，随后执行任务专用、固定顺序的：

```text
graceful unmount 专用挂载
→ juicefs gc --compact（同一 META；这是 volume 级操作，须先确认该 volume 为测试卷并获授权）
→ OSD compact cooldown
→ compact_running=0 / compact_queue_len=0 / kv_sync_lat 回到动态绿色范围
→ pool objects/stored 稳定
→ 157 + 3 节点 drop_caches
→ 固定等待
→ 下一独立挂载
```

开跑前净化后动态记录 `seed_objects`。每个正式 cell 开始前必须回到
`seed_objects ±8192`；该门须先在 W01--W04 验证可达。若任一预热无法回归，正式矩阵不得开始，
记 `PRECONDITION_OBJECT_RETURN_NOT_REPRODUCIBLE`，禁止临场放宽阈值。每轮前后同时保存 JSON
objects/stored 和 `pending delete`，不得用人读表格列切分。对象自然排水窗口为 `150×30s=75min`；
该窗口等待的是 JuiceFS 年轻/skipped 对象的后台待删生命周期（约一小时档位，具体调度机制未拆分），
不是把 Ceph 健康/active+clean 当作对象已删除。75 分钟仍未回归则硬失败，恢复 scrub 并终止 RUN。

本任务不使用 OSD restart、pool delete/create、format/destroy 或重复 layout 净化状态。

### 2.6 Ceph scrub 控制

本任务预注册 `SCRUB_PAUSED_FOR_CONTROLLED_BENCHMARK`：正式因果 phase 内以独立 state-driven
lease 同时暂停 `noscrub + nodeep-scrub`，排除长矩阵中的随机巡检竞争。预计 pause 作用域为
Phase II 全部预热与正式矩阵，典型约 `7--10 h`，最坏约 `14 h`；scrub lease 安全上限冻结为 `16 h`，
接近上限必须停止后续 cell 并恢复 lease。

- 这是全局环境控制条件，不是性能旋钮或生产交付配置；执行前必须单独列出计划并获用户授权；
- 设置前冻结 FSID、原 flags、health、OSD up/in、逐 PG 状态；只恢复本 lease 自己增加的 flags；
- 设置后须等正在运行的 scrub/deep-scrub 完全退出；每轮仍采集逐 PG 状态；
- 仅允许唯一 `OSDMAP_FLAGS` WARN；任何其他 health check、非 active+clean PG、recovery/backfill
  或人工 scrub 都立即停止；
- phase 成功、失败、SSH 中断时，第一安全动作均是 state-driven restore；恢复失败是安全事件；
- 若执行前决定保持 scrub 开启，必须在任何性能数据产生前修改本任务冻结条件并重新 Gate 0；
  正式窗重叠 scrub 的 cell 不能事后靠“例行巡检”豁免。

---

## 三、执行步骤与阶段停点

### Phase 0：离线 Gate 0（GPT；禁止连接环境）

#### 步骤 0：先通读并确认方法论

执行方和审核方至少确认：

- `EVIDENCE-INTEGRITY-SKILL.md` §1--§5、§7--§9；
- `TASK-BOOK-AUTHORING-GUIDE.md` §二.8--20；
- `TUNING-SKILL.md` §一 B 类、§三、§四.2--4.4、§五；
- `TESTING-GUIDE.md` §1.3、§2.2、§3、§5.1、§5.6、§10；
- `test-commands-reference.md` §6.4、§8--§9；
- `SYSTEM-SAFETY-SKILL.md` §一、§二.3--2.5；
- `LONG-RUNNING-TEST-SKILL.md` §三、§五。

在 `methodology-ack.tsv` 记录路径、SHA256、读完时刻和身份。旧 reference 中 fresh-volume、
ra0 既有结论与旧统计口径若与本文冲突，以本文为准。

#### 已实现脚本

```text
scripts/FULLBASELINE/debug/s04tmp-randrw-ra-driver.sh
scripts/FULLBASELINE/debug/s04tmp-randrw-ra-sampler.sh
scripts/FULLBASELINE/debug/s04tmp-randrw-ra-analyze.py
scripts/FULLBASELINE/debug/s04tmp-randrw-ra-gate0-offline.sh
scripts/FULLBASELINE/debug/s04tmp-randrw-ra-mock-integration.sh
```

另增加真实历史 fixture `skills/fixtures/s04tmp-osd-perf-quincy.json`。scrub 控制复用仓库中已经审核的
`scripts/FULLBASELINE/debug/u141d-scrub-control.sh`，但实际使用 `S04TMP-<RUN_ID>-phase-a` 独立 lease
和本 RUN 下独立 state 目录；其实际文件全文与 SHA256 一并冻结，不依赖执行机上的临时副本。

#### Gate 0 最低断言

1. shell `bash -n`、`bash -u -n`，Python 编译/单测，shellcheck（若有）和 `git diff --check`；
2. 逐条覆盖 `known-defect-classes.tsv` 的 CRIT/HIGH 类；报告未覆盖项必须为 0；
3. 默认 `DRY_RUN_ONLY=1`；未知子命令、空 RUN_ID、未授权 ACK、非精确路径全部 fail closed；
4. 自 grep 无明文口令、`rm -rf`、force/lazy umount、宽 kill、重启、pool delete/create、
   format/destroy/layout/create_on_open、系统 ceph.conf 修改；
5. A/B mount 命令逐 token 对比，只允许 B 多 `--max-readahead 0`；显式验证 A 没有该参数；
6. fio fixture 验证 `rwmixread=50`、128 jobs/files、256KiB、180s、openfiles=128、固定 randseed；
7. 128/127/重复/512MiB 文件资产 fixture；非 128×1GiB 必须拒绝；
8. JuiceFS daemon 父子 PID、Go argv 空格化、`Setting.UUID` 嵌套、PID/starttime/exe MD5 fixture；
9. 实际 I/O 起点、重叠加权、direction 0/1 分离、160 秒正式窗和 W1--W4 fixture；
10. 起点 `±1s` 变化 `<1%`、`+58s` 显著改变 W1--W4；fio summary 不得进入 verdict；
11. 128/127/重复/截断 bw log、sampler 提前退出、watchdog 超时、fio rc 非零和 wait rc 传播；
12. objects 只解析 Ceph JSON；科学计数、GiB 空格、缺字段、回绕不得填 0；
13. `seed_objects ±8192`、固定 W01--W04、完整 R01--R08、缺臂、重复 label、禁止补样 fixture；
14. scrub lease 所有权、部分 pause、restore、既有 flag、不应 unset 他人 flag和唯一 WARN fixture；
15. 失败先 append incident、恢复 scrub、保留性能现场；脚本修改使当前 RUN/manifest 失效；
16. 在已有 randrw 历史归档上自证 READ/WRITE 拆分、正式窗、四窗与 summary 差异；
17. mock 走通 `inventory→plan→hold`、完整 A/B closure、非性能门失败三条路径；
18. 实际脚本全文、SHA256、内层 manifest 自校验、commands.sh 和 incidents 归档完整。

Gate 0 PASS 只证明控制流，不产生任何环境权限。完成后暂停并回传。

#### 2026-08-31 离线 Gate 0 结果

执行命令：

```bash
S04TMP_GATE0_OUT=/tmp/s04tmp-gate0-20260831-final \
  bash scripts/FULLBASELINE/debug/s04tmp-randrw-ra-gate0-offline.sh
```

结果为 `S04TMP_GATE0_PASS`、`failures=0`。除合成fixture外，Gate还按冻结SHA重新解析
`u141d-run5-phase-a-evidence-20260830.tar.gz`中的真实randrw归档，确认READ/WRITE方向拆分、
160秒正式窗、四子窗和fio summary差异；真实Quincy OSD fixture验证了读写counter、compaction和
`kv_sync_lat`字段。scrub控制器的pause/partial-failure rollback/foreign-flag/restore self-test通过，
完整mock走通只读inventory、精确计划、12-cell状态机与第二方matrix分析。

本机没有安装 `shellcheck`，该项明确记录为 `SKIP`；所有shell的`bash -n`、`bash -u -n`、
Python编译、危险命令扫描、CRIT/HIGH已知缺陷disposition和`git diff --check`均通过。
按作者指南 §20 补充“历史先验已满足 L1、本任务直接 L2”的理由后，2026-08-31
重跑完整离线 Gate 0，结果仍为 `S04TMP_GATE0_PASS`，输出位于
`/tmp/s04tmp-gate0-20260831-tier-audit`；已冻结脚本和 4+8 矩阵未改变。
本结果仍保持 `ON_HOLD / NO_ENVIRONMENT_AUTHORITY`：U1虽已锁版，但其他在途测试/优先任务未收口时，
Phase I inventory也不应与当前环境任务并行启动。

#### 旧 RUN 20260831-203458 失败记录

RUN `20260831-203458` 执行了修订前的原始合同（`OBJ_POLL_MAX=20`, 10 分钟排水窗口）。
W01（Arm A）成功 PASS；W02（Arm B）在 fio/sampler 成功后，object-return 20 轮轮询（10 分钟）
内 objects 未回归 seed（稳定在 2099708，seed=1978585，差值 +121123）。

只读排水观察证实：W02 GC 结束后约 49.5 分钟 objects 一次性回到 seed，说明原 10 分钟窗口过短。
该延迟应表述为"约一小时档位的 JuiceFS 年轻/skipped 对象后台待删生命周期，具体调度机制未拆分"，
不得归因为"Ceph RADOS 删除确认延迟 49.5 分钟"或从单样本外推通用固定时延。

同时发现挂载身份检查缺陷：JuiceFS v1.4.1 daemon 模式 (`-d`) fork 子进程时不保留 `CEPH_CONF`
环境变量，导致 `mount-processes.tsv` 从未创建；该错误被 command substitution 吞掉（未启用
`inherit_errexit`），driver 继续执行。修订后改为直接调用 `mount_cell`、写 `selected-worker.pid`、
验证 PID 存活，`/proc/PID/environ` 缺少 `CEPH_CONF` 只记录不硬门。

W01/W02 只能作工程观察，不进入正式效果量。修订后必须使用全新 RUN_ID，从 init/Phase I/plan 开始。

### Phase I：只读 inventory 与执行计划（GLM；完成后暂停）

只允许只读命令，禁止 sudo 写、mount、fio、GC、compact 或 scrub flag 变更：

1. 冻结 U1 verdict、二进制 path/version/MD5、私有 CEPH_CONF SHA256 和系统配置 MD5；
2. 冻结 FSID、health checks、OSD up/in、PG、scrub flags/活动、pool 属性与对象状态；
3. 只读核验 volume UUID/Setting、主挂载指纹、`rw_test` 128×1GiB 合同；
4. 清点 foreign fio、测试挂载/loop/PD/TiKV、当前任务和 WekaIO/K8s 状态；
5. 验证 157 归档空间、内存/swap、三节点空间和时间同步；
6. 生成 A/B 精确 mount diff、fio 命令、专用目录、GC/cooldown/drop_caches、graceful unmount、
   scrub pause/restore、失败恢复和收口计划；
7. 列出全部 sudo 写命令、目标节点、目标路径和预计 scrub pause 时长；
8. 输出 `INVENTORY_PASS/FAIL` 与 Phase II 一次性授权请求。

Phase I 不得输出性能预测，也不得因为历史 ra0 结果跳过正式矩阵。

### Phase II：受控预热 + 八轮正式矩阵（单独授权后连续执行）

1. 按批准 plan 建立并验证 scrub lease；等待集群达到本文唯一允许健康状态；
2. 拍 pre env snapshot，完成固定净化，动态冻结 `seed_objects`；
3. 运行 W01--W04。每 cell 都完整走“挂载→身份/参数核验→drop caches→randrw→采集→
   优雅卸载→GC/cooldown→对象回归”；预热性能不进入效应量；
4. 四次预热全部非性能门、对象回归和 cleanup 可达后，**不暂停、不改脚本、不换 RUN_ID**，
   连续运行 R01--R08；
5. 任一非性能门失败：先写 incident，停止后续性能负载，优先按 lease state 精确恢复 scrub；
   除全局恢复外保留性能现场，禁止擅自卸载/清理/补轮；
6. R08 后优雅卸载本 RUN 专用挂载，恢复 scrub，验证原 flags、health、生产指纹和无本 RUN 残留；
7. 拍 post snapshot，冻结实际脚本/命令/manifest，等待文件 size/mtime 静止后打包；
8. GLM 只回传逐门 PASS/FAIL、原始数据、incidents、scrub audit 和归档 SHA；不算效应、不下结论。

预计墙钟：Gate 0/计划约 `0.5--1.5 h`；Phase II 典型约 `7--10 h`，最坏约 `14 h`（受 16h scrub lease
上限截断），其中 fio 纯负载 36 分钟，主要时间用于 12 次独立挂载、GC、OSD cooldown、最长 75 分钟
对象自然排水和证据采集。阶段内部不得逐轮请示。

### 末步：第二方复算与 skill 合规复核

GPT 必须从原始 per-job log 独立重算两向正式窗、四窗、固定 OLS/CI、逐对效应与机制 sidecar；
核对执行脚本哈希、实际 mount token diff、对象起点平衡、scrub lease、授权和 manifest。随后逐条复核
抬头所列 skill/guide，并在报告列出符合项、偏离项及其对结论的影响。任一关键偏离不得静默忽略。

---

## 四、非性能硬门与性能端点分离

### 4.1 可使 RUN/后续 cell 停止的非性能硬门

- 二进制、脚本、CEPH_CONF、任务书 SHA 与冻结 manifest 不符；
- A/B 除 readahead 外存在任何 token 差异，或 `/proc/mounts` 未见 `max_read=262144`；
- mount PID/PPID/starttime/exe MD5/UUID/专用路径身份不完整或指向非本 RUN；
- 文件资产不是 128×1GiB、fio job/log 数不为 128、方向缺失、I/O error 或 fio rc 非零；
- 实际正式窗不是 160 个 job 齐全秒，sampler 未覆盖或时间基准无法闭合；
- Ceph/PG/OSD/scrub 状态不符合 §2.6，compact 三指标不绿；
- 正式 cell 前 objects 未回到 `seed_objects ±8192`，或容量/swap/归档空间越界；
- foreign fio/业务 I/O 与正式窗重叠，主挂载/系统配置/pool/PG/CRUSH/TiKV 指纹变化；
- 矩阵顺序、randseed pairing、label、清理步骤或授权范围与冻结合同不同；
- scrub lease ownership/restore 异常、脚本热改、缺 incident 或 manifest 自校验失败。

### 4.2 只记录、绝不删样的性能端点

READ/WRITE 带宽高低、CV、P10/P90、W4/W1、读写相关系数、client/OSD 延迟、CPU、NIC、
读放大以及偏离历史 1870 的幅度，全部是结果，不是证据门。数据差不能被命名为“环境异常”后删除。

### 4.3 RUN 状态机

| 状态 | 条件 | 允许引用 |
|---|---|---|
| `VALID` | 矩阵完整且全部非性能门通过 | 可计算正式效应和 verdict |
| `EVIDENCE_INVALID` | 任一非性能门失败或缺臂 | 只能作工程观察 |
| `RESOLUTION_INSUFFICIENT` | 任一共同主端点 CI 半宽 >5pp | 只给效应边界 |
| `INCONCLUSIVE` | 其余方向/配对不一致 | 逐轮逐对报告 |

同 RUN 禁止热修后继续、换 RUN_ID 重来、补样替换、拼接无效点或看到数据后改变阈值/模型。

---

## 五、交付物

结果根目录预留：

```text
/tmp/production/opencode-04-tmp-randrw-ra-<RUN_ID>/
  methodology-ack.tsv
  phase-status.tsv
  commands.sh
  incidents.tsv
  input-sha256.txt
  inventory/
  plans/{mount,cleanup,scrub-pause,scrub-restore,closure}/
  state/{volume,mounts,scrub-lease,seed-objects}/
  snapshots/{pre,post}/
  warmup/{W01,W02,W03,W04}/
  formal/{R01,R02,R03,R04,R05,R06,R07,R08}/
  sampler/
  closure/
  scripts-executed/
  manifest.sha256
  # archive 文件本体位于同级安全路径，避免归档递归包含自身：
  # /tmp/production/opencode-04-tmp-randrw-ra-<RUN_ID>.archive.tar.zst
  # /tmp/production/opencode-04-tmp-randrw-ra-<RUN_ID>.archive.tar.zst.sha256
```

每个 cell 至少含：fio stdout、128 个原始 bw log、实际起止时刻、fio `run=`、mount/PID/UUID
指纹、完整命令、pre/post health/PG/objects、OSD compact、NIC/JFS/OSD sampler 和 cleanup audit。

报告预留：

```text
doc/perf-report/04-tmp-randrw-readahead-residual-tuning-<YYYYMMDD>.md
```

报告首部必须有机器可读 `VERDICT=<§1.4之一>`、`RUN_STATE`、`BINARY_MD5`、`ARCHIVE_SHA256`。
若产生正式结论，再更新：

- `doc/deploy-log/results-table.md`；
- `doc/perf-analysis/CURRENT-JUICEFS-PERFORMANCE-STATUS-*.md`；
- `doc/perf-analysis/04-metadata-architecture-and-layout-plan.md`。

若 RA0 获得双向收益，只登记为“randrw 候选配置”；是否成为统一交付配置，须另做其他规格项
回归或由用户明确接受 seqread 等项目的潜在代价。

---

## 六、通用注意事项与安全红线

1. **统计**：有 per-job log 时只用实际 I/O 起点、重叠加权重采样、正式窗和 W1--W4；
   fio summary 只作旁证；禁止一份 log 乘 job 数；randrw 两向分开报告。
2. **冷态**：每 cell 前按同一批准计划在 157 与三节点执行 drop_caches；任一节点失败即硬门，
   不得因 `direct=1` 省略。所有 sudo 写在 Phase I 逐行列出并单独授权。
3. **数据**：复用既有 layout 卷和 `rw_test`；不 fresh volume、不 create-on-open、不新 layout。
4. **后端净化**：高写后强制 `gc --compact`、OSD compact/cooldown 和三指标全绿；
   restart 不能替代 compact，性能差不能触发额外净化。
5. **健康**：每个 fio 前检查完整 health JSON、OSD up/in、逐 PG；仅 §2.6 的唯一 scrub flags WARN
   可接受，任何其他异常停止。
6. **记录**：每 cell 保存 commands、全部原始 log、环境/配置/身份/健康/对象/采样证据；
   每个报告数字可回溯到文件、字段与算法。
7. **清理**：本任务禁止 destroy 和 pool delete/create；任何未来清卷只能另立精确计划，
   禁止通过重建池“恢复状态”。
8. **skill 首尾自查**：执行前记录 methodology ACK，结束后逐条复核；关键偏离必须改变 RUN 状态。
9. **授权边界**：脚本解析/日志/路径适配可在正式 RUN 前修复并重做 Gate 0；改变变量、矩阵、
   阈值、清理、数据、pool、scrub 范围或 sudo 目标必须停下讨论。R01 后脚本一字节不得改。
10. **挂载实例**：每 cell 独立专用挂载，不筛档、不复用 label、不自动重挂；主挂载不得卸载或替换。
11. **判据来源**：每个 verdict 只读 formal 原始 log、固定 analyzer 输出与非性能门清单；
    机制指标字段必须 Phase I 实查，缺失不能填 0。
12. **快照**：pre/post 都使用任务 OUT 内 env snapshot；记录 Ceph pool、scrub flags、活动 PG、
    mount options、二进制和配置哈希。
13. **有效带宽**：打印实际 I/O 起点与登记起点差；正式窗 mean/median/CV/P10/P90 和四窗全保存；
    无 per-job log 不允许退化为正式结论。
14. **证据/性能分离**：带宽、CV、W4/W1、延迟再差都不删样；验收线不是证据有效门。
15. **状态机**：失败保留现场；不卸载、不删目录、不清 sampler、不 kill。全局 scrub 精确恢复优先，
    且只能恢复本 lease 拥有的变化。
16. **平衡矩阵**：固定 ABBA-BAAB，记录 objects/pending/mtime 等状态协变量并复算臂位平衡；
    禁止 AAAABBBB、动态加轮或补样。
17. **离线 Gate 0**：未过禁止任何环境调用；全部已知 CRIT/HIGH 缺陷类须有静态/fixture 断言，
    analyzer 必须先在历史归档自证。
18. **第二方复算**：GLM 只交 raw + 门清单 + incidents，不算效应/CV/中位数、不挑轮、不下结论；
    归档必须含实际脚本全文、哈希、manifest 自校验。
19. **scrub 控制**：只在单独授权的 phase lease 内同时 pause 两项，禁止裸 set/unset、轮间开关、
    无状态恢复或把 pause 配置写入生产交付基线。

### 系统级绝对红线

- 禁止 `rm -rf`、`chown -R`、`chmod -R`、设备写、`losetup -D`、force/lazy umount；
- 禁止 `pkill`、`killall`、`fuser -k`、模式 kill、kill mount PID；
- 禁止 reboot/shutdown、服务重启、OSD/PD/TiKV 停启、内核/IRQ/RPS/NUMA/NIC/RoCE/MTU 修改；
- 禁止修改系统 `/etc/ceph/ceph.conf`、生产 pool/PG/CRUSH/CephX/TiKV/volume Setting；
- 禁止触碰 157 的 WekaIO、K8s、md0、非本 RUN 路径、挂载、进程或数据；
- 脚本运行前必须扫描自身及全部子脚本的 sudo 写、重启、删除、kill 和卸载命令；
- 任何 sudo 写必须使用 Phase I 审核过的精确命令、节点与目标；不得用宽泛“继续”代替授权。

### 最终红线一句话

本任务唯一允许改变的是**本 RUN 专用挂载是否追加 `--max-readahead 0`**，以及经单独授权、
可精确恢复的测试净化/scrub 控制；绝不能改变规格负载、既有 layout、生产主挂载、Ceph/TiKV
架构和任何不能由 RUN state 精确证明归属的系统对象。
