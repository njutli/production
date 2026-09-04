# U141d 任务书：JuiceFS 1.4.1 最终写路径补证

## 日期：2026-08-30

> 面向：GLM 执行；GPT 离线独立复算与签收。
>
> 候选范围固定为：
>
> - **V13**：patched JuiceFS 1.3.1，`/tmp/juicefs-03-8`，MD5 `de93563f11a5ff3bd94dd25a4e0283b1`；
> - **V14**：JuiceFS 1.4.1 + B-catchup，`/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`。
>
> 原生未打 B-catchup 的 1.4.1 已因 randwrite 约 551 MiB/s 被排除，不属于本任务候选。
>
> 承接：`u141b-juicefs-141-replace-131-decision.md`、
> `u141b-replace-decision-status-20260829.md`、`u141b-findings-log.md` 与 Opus 原 U141d。
> 本文件保留原文件名以避免引用失效，但已将范围扩展为全部剩余写路径证据。

---

## 一、任务目的与已有证据

U141b 最终取得 **24 个有效正式轮**：P1/P2/P3 各 8 轮；P4 `mseqwrite` 未执行。
已有证据足以保留以下结论，不再重复全量七项基线：

| 项 | U141b 结论 | 本任务处置 |
|---|---|---|
| seqread / mseqread / randread | 版本效应接近 0，无材料性退化迹象 | 不重测 |
| seqwrite | 版本效应接近 0 | 不重测 |
| randwrite | 均值趋势模型约 −1.27%，配对结果并非每轮都低 | 阶段 A 复测确认 |
| randrw | 均值趋势模型约 −3.52%，4 个跨臂对中 3 个为负；最贴近生产规格 IO 模型 | **阶段 A 第一优先级** |
| mseqwrite | U141b 未执行；U141 又被对象数棘轮污染 | 阶段 B 独立补测 |

本任务只回答三件事：

1. V14 的 `randrw` 是否存在可复现的负向版本效应，准确幅度和区间是多少；
2. V14 的 `randwrite` 是否与 V13 同量级，且不再出现原生 1.4.1 的性能塌陷；
3. 在每轮恢复相同对象起点后，V14 的 `mseqwrite` 相对 V13 表现如何。

**本任务不在取数前写死 `REPLACE_APPROVED`。** 测试输出实际效应与置信区间；是否接受小幅下降，
待数据出来后结合 `randrw` 的生产重要性决定。

---

## 二、预注册统计口径（取数前冻结）

### 2.1 主估计量

- 每个 item、每轮只使用 fio 实际 timed-I/O 起点对齐后的正式窗 `[15,175)`；
- 对 per-job BW 日志做区间重叠加权到自然秒；只保留 job 齐全的秒；
- 主估计量固定为正式窗逐秒聚合带宽的**算术平均值**；median、CV 只作敏感性；
- `randrw` 的 READ 与 WRITE **分开分析，禁止相加**，两向都是正式端点；
- `randwrite`、`mseqwrite` 分析 WRITE 方向。

逐轮版本模型固定为：

```text
BW_r = β0 + β1·(r−4.5) + β2·(r−4.5)² + βarm·1[V14]
effect_pct = βarm / mean(BW of V13 rounds) × 100%
```

报告 `effect_pct`、双侧 95% CI、单侧 95% 下界、逐轮值与四个跨臂对。
二次模型是主口径；线性模型和不去趋势的臂均值差只作敏感性，禁止择优切换。

### 2.2 数值解释，不预判替代

| 数值 | 含义 |
|---|---|
| **5%** | 关注线：若区间整体落在 −5% 以内，可描述为“小幅、受控”；这不是自动批准 |
| **10%** | 明显退化红线；若单侧 95% 上界仍低于 −10%，记 `MATERIAL_REGRESSION` |
| CI 跨 0 | 未检测到稳定版本方向，描述为 `NO_DETECTABLE_DIFFERENCE` |
| CI 全部低于 0、但未越 −10% | 记录 `SMALL_REGRESSION_MEASURED` 及准确幅度，交由最终评审 |

精度门只防止“高噪声等于通过”：阶段 A/B 任一端点双侧 95% CI 半宽 > **5 个百分点**，
记 `RESOLUTION_INSUFFICIENT`。不在同一 RUN 内临时补轮；先分析状态原因，再决定是否另行取数。

---

## 三、阶段设计

### 3.1 固定正式矩阵（两阶段相同）

```text
R01=V13  R02=V14  R03=V14  R04=V13  R05=V14  R06=V13  R07=V13  R08=V14
```

V13/V14 占位均值均为 4.5，二阶矩均为 5.25，可同时抵消一阶和二阶轮序漂移。
正式矩阵固定 8 轮，每臂 4 轮；禁止补点、换顺序或删除性能差的轮。

### 3.2 阶段 A：`randrw + randwrite`

- `ITEMS="randrw randwrite"`，顺序两臂完全相同，`randrw` 始终先执行；
- 正式矩阵前固定运行 4 个预热轮：`V13 V14 V14 V13`；
- 预热数据完整保留但不进入效应量；
- 预热只用于消化 U141b 已观察到的跨轮 settle，**不设置 CV/2% 收敛门，也不动态追加预热**；
- 预热与正式 R01 必须连续执行，中间不得暂停等待审核；
- 排空点固定为 W01 前、R01 前、R05 前；`randwrite` 是覆盖写，`randrw` 产生的垃圾对象由固定排空控制。

阶段 A 共 12 个 V4 label，预计约 5.7 小时。完成后停止并回传，GPT 独立复算。

### 3.3 阶段 B：`mseqwrite`

仅当阶段 A 没有确认超过 10% 的材料性退化，且用户授权后执行：

- 两个非正式 canary：`V13 V14`，用于确认两臂均能完成 mseqwrite 全路径；
- 随后执行固定 8 轮正式矩阵；
- canary 和每个正式轮**之前**均执行精确排空：只删除
  `/mnt/juicefs/test_dir/mseqwrite/mseqwrite.*.0`，然后 `juicefs gc --delete`；
- preflight 排空完成后的对象数记为 `seed_objects`；每轮开跑前必须回到
  `seed_objects ± 8192`，否则 `EVIDENCE_INVALID` 并停止；
- 阶段 B 放在全部测试最后，避免其新写入对象污染阶段 A；
- 最后一轮后再次排空并核对回到 seed 范围。

对象起点门是本阶段不可简化的核心门：U141 正是因为 mseqwrite 每轮新增 0.9–1.3M 对象、
版本臂与存储状态共线而失效。

---

## 四、精简后的有效性门

### 4.1 开跑前硬门

1. U141d 专用 `/tmp/FULLBASELINE_V4_U141D.sh` MD5 必须为
   `b79402c3ef1691dbf20eafd344f91c27`，U141b 复用件、V13/V14 与 msgr 配置 MD5 全匹配；
   原冻结 `/tmp/FULLBASELINE_V4.sh` 仍须保持 MD5 `4198ea2676ba56744a3cd5eba17a5eab`，不得覆盖；
2. 无 foreign fio、无 t64/t65/t66 测试挂载或 loop、无临时 PD/TiKV 端口；
3. 157 根分区可用空间不少于 20 GiB；
4. 本任务按 §4.4 使用 phase 级 `noscrub + nodeep-scrub` 控制基线；仅允许由这两个 flag
   产生且 health-check key 唯一为 `OSDMAP_FLAGS` 的 `HEALTH_WARN`，OSD 必须全部 up/in、
   PG 必须逐个精确为 `active+clean` 且无正在运行的 scrub/deep-scrub；任何其他 WARN 立即停止；
5. `read_test.*.0`、`rw_test.*.0`、`storage_test.*.0` 各 128 个且均为 1 GiB；
6. P0：V14 挂载→V13挂载→V14挂载全部成功；V14 Setting 允许只多默认空 `Tiers`；
7. 建立 `seed_objects` 并冻结矩阵、统计口径和全部脚本哈希。
8. `u141d-analyze.py` 不仅要 SHA256 一致，还必须是可由 driver 直接执行的 regular file；
   init、Phase B 入口和 closure 前均检查 executable bit，禁止以“可被 `python3 file` 读取”替代
   真实 direct-exec 合同。

不再执行 60 秒写入 settle probe，不以系统负载、CV、W4/W1 或缓存命中率作为开跑门。

### 4.2 每轮硬门

- 切臂前 `command -v juicefs` 与目标 MD5 一致；
- 调用 V4 前挂载点和对应 JuiceFS worker 必须都为 0；优雅卸载会等待二者同时消失，
  从入口上避免触发冻结 V4 内部的 TERM/KILL 兜底。卸载后最多等待 **180 秒**，逐秒写入
  `unmount-quiescence.tsv`（context/arm/method/elapsed/mountpoint/PID/state）；只有
  `mountpoint=0 && matching worker PID=0` 才能进入下一轮。超过 180 秒立即停止并保留现场，
  禁止忽略 worker、kill worker 或进入 V4 TERM/KILL 兜底；退出耗时作为版本运维兼容性指标报告；
- 所有 mount 进程 `exe_md5`、`CEPH_CONF`、`max_read=262144` 一致；
- V4 rc=0，`rounds.tsv` 必须对本轮冻结 item **逐项恰好一行且 status=VALID**：
  Phase A 每个 label 恰好两行（randrw、randwrite），Phase B 每个 label 恰好一行（mseqwrite）；
  缺项、重复项或未知项均失败；
- `UNCLEAN_UMOUNT.txt` 不得新增，`jfs-instance-<LABEL>.txt` 不得出现 `umount_mode=term/kill`；
- 目标 item 目录必须全部存在，日志数严格为 randrw/randwrite 128、mseqwrite 16；
- 每个正式端点 `[15,175)` 必须有 160 个完整秒；
- Ceph 保持健康；单轮总墙钟（包含 post-round 优雅卸载至 worker 完全退出）不得超过 41 分钟；
- 每轮入口、pre、post 和 closure 均须再次核验本 phase 独立 scrub lease 仍为 `paused`；
  collector 必须保存完整 health JSON、OSD dump JSON 和逐 PG `pgs_brief` 原文，禁止仅凭
  `nonclean=0` 丢弃 PG 身份或吞掉其他 health check；
- 阶段 B 额外执行对象起点门。

性能值、CV、W4/W1、带宽高低永远不是删样理由。非性能硬门失败时停止，保留挂载和现场；
禁止卸载后再宣告该轮无效。

### 4.3 仅记录、不设门

PG primary map、cache hit、`c_amp`、`jfs-stats`、W1–W4、对象增量、主机负载照常落盘，
用于解释结果；不因它们偏离历史值而自动废弃数据。

### 4.4 Ceph scrub 条件性控制合同

本任务预注册环境标记：`SCRUB_PAUSED_FOR_CONTROLLED_BENCHMARK`。它只用于排除 Ceph 后台
一致性巡检对版本比较的随机干扰，不是性能旋钮，也不是生产交付配置。

1. **作用域固定为 phase**：Phase A 使用 `<RUN_ID>-phase-a` lease，覆盖
   `init → phase-a → close phase-a`；随后立即恢复。Phase B 经授权后使用独立的
   `<RUN_ID>-phase-b` lease，正常全流程覆盖 `phase-b → close final`；若使用 §5.1 的恢复入口，
   则覆盖 `init-b-only → phase-b-only → close phase-b-only`，随后立即恢复。禁止轮间开关。
2. **只准独立状态驱动脚本操作**：设置前冻结 FSID、原始 OSD flags、health、OSD up/in 和逐PG状态；
   只允许新增 `noscrub,nodeep-scrub`，只恢复该 lease 自己拥有的两项变化。禁止裸
   `ceph osd set/unset`、无状态恢复、无条件 unset 或只依赖性能驱动的 `EXIT trap`。
3. **设置并不等于已有 scrub 已退出**：两个 flag 生效后仍须等待所有 PG 精确回到
   `active+clean` 才能开始；Ceph 手工触发的 scrub 不受这两个调度 flag 保证约束，因此测试期
   禁止人工 scrub，采集器仍须每轮检查无 `scrubbing/deep`。
4. **恢复优先**：phase 成功、失败、SSH 中断或测试脚本故障后，第一安全动作都是按 state
   执行 `plan-restore → restore → verify-restored`；性能现场可保留，但不得为了采证延迟恢复。
   恢复失败视为集群级安全事件。恢复后若补做 scrub，须等 health、OSD、PG 重新稳定才可开下一 phase。
5. **审计不可缺**：RUN 内冻结 pause 状态副本，独立 state 文件保留 set/unset epoch、rc、FSID、
   原 flags 与最终状态；报告必须明确说明该数据是在暂停 scrub 的受控基线下取得，不能外推为
   scrub 开启时的生产长期性能。

---

## 五、执行脚本与命令

仓库脚本：

```text
scripts/FULLBASELINE/debug/u141d-driver.sh
scripts/FULLBASELINE/debug/u141d-analyze.py
scripts/FULLBASELINE/debug/u141d-gate0-offline.sh
scripts/FULLBASELINE/debug/u141d-scrub-control.sh
scripts/FULLBASELINE/debug/u141b-collect.sh
scripts/FULLBASELINE/FULLBASELINE_V4_U141D.sh
```

`FULLBASELINE_V4_U141D.sh` 是原冻结 V4 的任务专用派生版：fio 参数、item 顺序、对象门和证据逻辑
不变，只增加显式 `CEPH_SCRUB_CONTROLLED=1` 时对 `OSDMAP_FLAGS` 唯一告警、两个 scrub flags 与
OSD up/in 的严格 JSON 校验；默认原 V4 文件及其历史 MD5 不作任何修改。

Gate 0 另调用 `u141d-mock-integration.sh` 在纯本地假环境走完
`init → phase A → closure → phase B → final closure`，并独立走完
`init-b-only → phase-b-only → phase-b-only closure`；该脚本只用于离线自测，不同步到执行环境。

复用且行为不变：

```text
scripts/FULLBASELINE/debug/u141b-analyze.py
```

离线 Gate 0（GPT 本地完成，不接触环境）：

```bash
bash scripts/FULLBASELINE/debug/u141d-gate0-offline.sh \
  /tmp/u141b-gate0/fixture-v141p
```

GLM 在 157 上先只读检查并生成 pause 计划；未确认计划前禁止执行 `pause`：

```bash
RUN_ROOT=/tmp/production/opencode-u141d-<RUN_ID>
RUN_ID=${RUN_ROOT##*/opencode-u141d-}
SCRUB=/tmp/u141d-scrub-control.sh

bash "$SCRUB" inspect "${RUN_ID}-phase-a"
bash "$SCRUB" plan-pause "${RUN_ID}-phase-a"
```

计划与 FSID 经 GPT 核对、用户授权后，按计划输出的**精确参数**执行 `pause`，然后连续执行：

```bash
bash "$SCRUB" pause "${RUN_ID}-phase-a" <APPROVED_FSID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
bash "$SCRUB" verify-paused "${RUN_ID}-phase-a"

bash /tmp/u141d-driver.sh init "$RUN_ROOT"
bash /tmp/u141d-driver.sh phase-a "$RUN_ROOT"     # init 后直接连续执行，阶段内不暂停
bash /tmp/u141d-driver.sh close "$RUN_ROOT" phase-a
bash "$SCRUB" plan-restore "${RUN_ID}-phase-a"
bash "$SCRUB" restore "${RUN_ID}-phase-a"
bash "$SCRUB" verify-restored "${RUN_ID}-phase-a"
```

无论上述哪一步失败，都停止性能流程并优先执行 phase-a 的 state-driven restore；不得清理失败现场。
回传阶段 A 与 restore 审计后等待 GPT 审核。获授权才为 phase-b 重复
`inspect → plan-pause → pause → verify-paused`，然后执行：

```bash
bash /tmp/u141d-driver.sh phase-b "$RUN_ROOT"
bash /tmp/u141d-driver.sh close "$RUN_ROOT" final
bash "$SCRUB" plan-restore "${RUN_ID}-phase-b"
bash "$SCRUB" restore "${RUN_ID}-phase-b"
bash "$SCRUB" verify-restored "${RUN_ID}-phase-b"
```

GLM只报告硬门、偏离和原始结果位置，不自行选择样本或宣布版本替代结论。

### 5.1 RUN `20260830-122350` 的 Phase-B-only 恢复入口

Phase A 已完成并由 GPT 独立复算，可信证据冻结在：

```text
/tmp/u141d-run5-phase-a-evidence-20260830.tar.gz
SHA256=150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b
source RUN=20260830-122350
status=VALID_WITH_PROTOCOL_DEVIATION_NO_OBSERVED_STATE_EFFECT
```

原 RUN 的 Phase B 在 R05 post gate 因 node2 缺失本地 NTP 配置而命中 `MON_CLOCK_SKEW`，矩阵不完整，
正式分类为 `EVIDENCE_INVALID_INCOMPLETE_MATRIX`。现已补齐 node2 的 timesyncd 上游、连续验证 Ceph
monitor skew 恢复，并将 R05 数据精确排空到 seed。旧 RUN 的 B-C01--R05 仍全部禁止纳入效应量，
不得 resume、补 R06--R08 或复用旧 label。

为避免无意义地重跑 5.7 小时的有效 Phase A，新 driver 提供显式恢复状态机：

```bash
NEW_RUN_ROOT=/tmp/production/opencode-u141d-<NEW_RUN_ID>
NEW_RUN_ID=${NEW_RUN_ROOT##*/opencode-u141d-}

bash "$SCRUB" inspect "${NEW_RUN_ID}-phase-b"
bash "$SCRUB" plan-pause "${NEW_RUN_ID}-phase-b"
# GPT 核对计划后，使用精确 FSID 和 ACK 执行 pause + verify-paused。

bash /tmp/u141d-driver.sh init-b-only "$NEW_RUN_ROOT"
bash /tmp/u141d-driver.sh phase-b-only "$NEW_RUN_ROOT"
bash /tmp/u141d-driver.sh close "$NEW_RUN_ROOT" phase-b-only

bash "$SCRUB" plan-restore "${NEW_RUN_ID}-phase-b"
bash "$SCRUB" restore "${NEW_RUN_ID}-phase-b"
bash "$SCRUB" verify-restored "${NEW_RUN_ID}-phase-b"
```

合同如下：

1. `init-b-only` 必须核对上述归档的固定路径、固定 SHA256、安全成员和 Phase A 完成/closure/analysis
   成员，并把绑定写入新 RUN 的 `PHASE_A_SOURCE.tsv` 与 provenance；调用方不能替换可信根。
2. 新 RUN 只创建 `INIT_B_ONLY_COMPLETE`、`PHASE_B_COMPLETE` 和 `PHASE_B_ONLY_COMPLETE`；
   **不得伪造或复制 `PHASE_A_COMPLETE`**，避免把外部证据冒充本 RUN 内执行结果。
3. 新 RUN 重新执行资产门、bootstrap drain、seed 三采样和 P0，然后从 B-C01 开始完整执行
   `V13,V14` canary 及 8 轮正式矩阵；禁止复用旧 RUN 的任何 Phase B 样本。
4. `close phase-b-only` 只分析并冻结新 RUN 的 Phase B，同时保留外部 Phase A 归档绑定；最终替代判断
   由 GPT 将可信 Phase A 归档与新 Phase B closure 离线合并，不由 driver 自动宣布。
5. 新 RUN 的整个 init/Phase B/closure 共用一个新的 phase-b scrub lease；任何失败均先 state-driven restore，
   不得为节省时间复用旧 lease 或旧 RUN_ROOT。

---

## 六、安全红线

1. 禁止 `pkill`、`killall`、`fuser -k`、模式 kill、kill mount PID；
2. 禁止 lazy/force unmount、`losetup -D`、递归强删和变量展开后的宽路径删除；
3. 禁止改生产服务、Ceph 配置、CRUSH/PG/pool、系统 ceph.conf、生产 TiKV 数据；唯一例外是
   经单独授权后由 `u141d-scrub-control.sh` 在 phase 作用域内设置并恢复精确的
   `noscrub,nodeep-scrub`，不得设置其他 OSD flag；
4. 禁止覆盖 `/usr/local/bin/juicefs`；切臂只允许切换 PATH shim；
5. 禁止 `juicefs destroy`；本任务复用既有卷和既有 384 文件资产；
6. 唯一允许删除的数据是精确的 `test_dir/mseqwrite/mseqwrite.*.0`；
7. 代码问题必须停止当前 phase，记录 incident，修复后重新 Gate 0，并从该 phase 第一个非正式轮开始；
8. 同一 RUN、同一 label 禁止重试覆盖；失败现场没有完成归属核验前不得清理。

---

## 七、回传和最终收口

只保留两个环境检查点：

| 回传 | 内容 | 后续 |
|---|---|---|
| 阶段 A | init、P0、4预热+8正式轮、closure、完整原始归档 | GPT复算 randrw READ/WRITE 与 randwrite |
| 阶段 B | 2 canary+8正式轮、逐轮 seed 回归、最终排空、closure | GPT复算 mseqwrite并形成总报告 |

最终报告必须同时引用：

- U141b 的四个无需重测项；
- U141d 阶段 A 的 `randrw` 双向与 `randwrite`；
- U141d 阶段 B 的 `mseqwrite`；
- P0 回滚证据；
- 原生 1.4.1 randwrite 崩塌与 B-catchup 必要性。

输出可以是“无可测差异”“确认小幅下降”“材料性退化”或“分辨率不足”；
是否最终批准 patched 1.4.1 替代 patched 1.3.1，由完整数据出来后再决定。

---

## 八、变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-30 | 离线串联检查发现原冻结 V4 在 fio 前硬编码只接受 `HEALTH_OK`，会把 scrub flags 引起的预期 `HEALTH_WARN` 直接拒绝。为避免篡改历史基准，保留原 V4 MD5 `4198...` 不动，新增 U141d 专用派生版 MD5 `b794...`；它只在驱动显式传入 `CEPH_SCRUB_CONTROLLED=1` 时接受 `OSDMAP_FLAGS` 唯一告警，并再次严格核对两个 flags 与 OSD up/in。 |
| 2026-08-30 | RUN `20260830-092829` 在 W02-V14 的 fio 正式窗全部结束约 6.5 分钟后，post gate 命中 PG 3.d 的 11 秒普通 scrub；正式性能窗经 epoch 复核未重叠，但矩阵仅完成 W01/W02，仍记 `EVIDENCE_INVALID_ENV_SCRUB`，禁止复用。过去24小时只读日志确认 pool 3 至少12次普通 scrub与1次 deep-scrub，阶段级命中不是可忽略的小概率。用户授权将 `noscrub+nodeep-scrub` 固化为调优/版本比较的条件性测试基线；新增独立 state-driven 控制器、严格 `OSDMAP_FLAGS` 唯一豁免、完整 Ceph 原始 sidecar、逐轮 lease 守卫及恢复优先合同。该设置不作为生产交付配置。 |
| 2026-08-30 | RUN `20260829-203206` 在 W01 暴露多 item `rounds.tsv` 合同缺陷：旧驱动错误要求每个 label 恰好一行，而 Phase A 按设计应有 randrw/randwrite 各一行。修订为“冻结 item 逐项恰好一行”，并增加缺项、重复项离线故障注入。旧 RUN 永久记 `EVIDENCE_INVALID_SCRIPT_DEFECT`，不得续跑或复用其性能点；修复后须重新 Gate 0 并使用新 RUN_ID 从 init 开始。 |
| 2026-08-30 | RUN `20260830-001537` 在 W02-V14 完成 V4 与全部样本门后，`fusermount -u` 已成功但 V14 worker 未在旧版固定 30 秒内退出，驱动在 post-round 收口失败；worker 后来自行退出。旧门既不能证明永久残留，也不能允许下一轮与残留 worker 并发。修订为最多 180 秒有界等待、逐秒保存 mount/PID/state、仅在 mountpoint 与 worker 同时归零后继续，并把等待计入 41 分钟总墙钟；超过上限仍 fail closed 且禁止 kill。同步修复 `die()`，FATAL ledger 写入失败必须显式报错；Gate 0 新增“延迟退出成功”和“超过上限失败且 FATAL 落账”故障注入。该 RUN 永久记 `EVIDENCE_INVALID_SCRIPT_DEFECT`，W01/W02只可作工程观察，禁止 resume/拼接；修复后新 RUN_ID 从 init 开始。 |
| 2026-08-30 | RUN `20260830-064128` 在 W01-V13 的 V4、样本门、对象门、Ceph 门和 `fusermount -u` 全部成功后，以 rc=1 静默退出且未产生首条卸载 telemetry/FATAL。根因由离线最小复现确认：`jfs_pids_for_mnt` 以条件表达式作为循环体末命令，在最后扫描项不匹配时函数返回 1；`pids=$(jfs_pids_for_mnt)` 继承该状态并被 `set -e` 直接终止。修订为“零匹配 PID 是显式成功”的枚举合同，并新增真实非匹配扫描项下的 errexit 故障注入与 Gate 0 静态门。该 RUN 永久记 `EVIDENCE_INVALID_SCRIPT_DEFECT`，其 W01 只作工程观察，禁止续跑或纳入版本比较；修复后仍须以新 RUN_ID 从 init 开始。 |
| 2026-08-31 | RUN `20260830-122350` 的 Phase A 已完整闭合并由 GPT 独立复算；Phase B 在 R05 post gate 因 node2 缺少本地 NTP 上游触发 `MON_CLOCK_SKEW`，旧 B 矩阵永久记 `EVIDENCE_INVALID_INCOMPLETE_MATRIX`。修复 timesyncd 后三节点持续 HEALTH_OK，R05 精确排空回 seed。新增绑定固定 Phase A 归档 SHA256 的 `init-b-only/phase-b-only/close phase-b-only` 状态机：使用新 RUN_ID 从 C01 完整重跑 Phase B，不伪造 Phase A marker、不拼接旧 B 样本，同时修正未来全流程 `A-PRE-R05` 的一位 `seq` 索引比较。 |
| 2026-08-31 | Phase-B-only 首次部署 preflight 发现 `/tmp/u141d-analyze.py` 被以 0644 安装，而 driver 对 round/matrix analyzer 使用 direct exec；原 Gate 0 仅用 `python3` 读取文件，未覆盖实际调用合同。尚未 pause、创建 RUN 或运行 fio，因此没有性能证据受影响。补充 analyzer executable bit 的 Gate 0 与 driver 多阶段硬门，修复后重新离线 Gate 0；旧候选 driver 不进入正式 RUN provenance。 |
