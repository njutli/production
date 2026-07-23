# 02-2-G soft-clean(+OSD restart) 稳定基线验证任务书  [v2 2026-07-23]

> 面向对象：GLM 执行
> 是否重跑性能：**是**，但**不重建 OSD、不删 pool**（核心变量：清理方式）。
> 承接结果目录：`results/prod-02-2-g-softclean-20260723/`
> 方法论 skill：`skills/TESTING-GUIDE.md`（§1.1 health / §3 compact cooldown）、`skills/test-commands-reference.md`（§8.3 稳态中位）、`skills/baseline-reproduction-skill.md`（§2.2/§2.5）
> 因果依据：`doc/perf-report/00-baseline-20260723.md` §九（重建=随机源1）、§9.6（pool delete+recreate=随机源2）、`00-baseline-20260723-2.md`（tmpfs/RocksDB 内存态累积=随机源3）
> 脚本：`scripts/tests/02-2-G-softclean-stability.sh`（配套取证 `rebuild-topology-forensic.sh`）

---

## 〇、背景

已定位**三个波动源**：
1. **重建 OSD**（§九）：OSD 集合变 → CRUSH 32/32 PG 重映射 → 跨重建 ±16~37%。
2. **pool delete+recreate**（§9.6）：pool_id 变 → 同一次重建内也 -22~-26%。已用"保留 pool"消除。
3. **tmpfs/RocksDB 内存态逐轮累积**（00-baseline-20260723-2）：即使 stable-ID 重建 + soft-clean（保 pool），DB/WAL 在 tmpfs 上逐轮 compact/碎片化，**mseqread 单调下降（4062→2894）、randread 单调上升（1325→1595），不收敛**。根因是 `juicefs destroy` 清不掉 OSD 内部 RocksDB 在 tmpfs 上的状态。

**本轮对策（v2）**：soft-clean（保 pool → 映射不变）**＋ OSD restart（不删 pool → 重置 tmpfs/RocksDB 内存态到相同起点）**。
- OSD restart 单独使用**不改 pool_id/映射**（与 §9.6 禁止的 delete+recreate 不同，那是因为 restart 和删 pool 绑定才坏）。
- 目标：消除第三源，使跨 cycle 收敛，且 **mseqread 不再单调下降**。

> ⚑ 可复现性边界（先读）：本任务证明**"同一部署"上可复现**，**非**绝对值跨部署可复现（§九物理不可能）。
> 定位：**调优决策用本测试床（相对 Δ/比值可复现）；生产绝对承诺用区间基线**。复现前 diff `reproduction-contract`。

---

## 一、目标

**验证 soft-clean + OSD restart 能否产出跨轮次稳定可复现的基线，并确认第三源（tmpfs 累积）是否被消除。**

判定（三个条件同时满足才算通过）：
1. **不变量**：全部 cycle 的 OSD 集合 + pool_id + PG→OSD 映射不变（取证自证，`07-pg-brief.txt` 跨 cycle diff 为空）。OSD restart 不应改变这三者。
2. **稳定性**：跨 cycle 的 **randread 中位值 CV < 5%**，**从 cycle2 起算**（cycle1 = 重建后首测/预热轮，含 fresh 态特殊性，排除）。
3. **第三源试金石**：**mseqread 跨 cycle 不再单调下降**（若仍每步跌 >3% → OSD restart 未解决 tmpfs 累积，须上方案 C）。

> 探针 = randread（稳定性，历史漂移最大）+ mseqread（tmpfs 累积试金石，上一轮唯一单调下降项）。

---

## 二、口径与执行矩阵（验证性测试 = 短口径）

- 脚本：`scripts/tests/02-2-G-softclean-stability.sh <GROUP> <CYCLES> <RUNTIME> <REPEAT>`
- **本次口径（≈40min/组）**：`GROUP=A  CYCLES=4  RUNTIME=90  REPEAT=2`
  - **跑 layout + randread + mseqread**（不跑 9 全项）。randread=稳定性探针，mseqread=tmpfs 累积试金石。
  - `RUNTIME=90`、`REPEAT=2`（稳定性证据来自跨 cycle）。
  - `CYCLES=4`，**cycle1=预热/参照轮**，CV 从 cycle2 起算。
  - **先只 A 组**（default）证命题；成立后再决定补 B 组。
- **清理方式（v2 核心）= soft-clean + OSD restart**：
  - ✅ 做：`juicefs destroy`（清对象，**保留 pool**）+ compact cooldown + **OSD restart（不删 pool）** + drop_caches + 重新 format+mount+layout
  - ❌ 禁止：`ceph osd pool delete+recreate`（改 pool_id）、`rebuild-osds`、OSD purge/create、动 CRUSH/pg_num
  - ⚑ 注意：**OSD restart 单独用是允许的且必要的**（重置 tmpfs 内存态）；禁止的是"delete pool + restart"这个组合。
- **compact cooldown 不可省**。
- 验收：判据①②③（脚本末尾自动算 randread CV[从cycle2] + mseqread 单调性判定）。
- **预计时长**：A 组 ≈ 40min。补 B 组再 ~40min。

---

## 三、执行步骤（逐条勾选）

0. [ ] **【测试前必做】通读 skill 并确认关键点**：`skills/baseline-reproduction-skill.md`（§2.2 清理层级 / §2.5 soft-clean 流程 / §3.1 执行顺序 / §4.3 判据）、`skills/TESTING-GUIDE.md`（§1.3 compact 三指标 / §2.2 health / §3 cooldown）、`skills/test-commands-reference.md`（§8.3 稳态中位）。**特别确认：清理保留 pool（禁 delete+recreate）；本任务 OSD restart 是刻意加入的（重置 tmpfs），与 §2.5 禁止的"delete pool+restart 组合"不同。**
1. [ ] `chmod +x scripts/tests/02-2-G-softclean-stability.sh scripts/tests/rebuild-topology-forensic.sh`
2. [ ] 前置：`ceph health` OK、6 OSD up、确认 JuiceFS 版本含 loadRange 修复
2.5 [ ] **【前置：建立 cycle1 干净起点，必做】stable-ID 重建集群**：`scripts/tests/rebuild-stable-ids.sh`（`ceph osd destroy` + `ceph-volume lvm create --osd-id <同ID>`，fresh BlueStore + **保持 OSD ID 0-5 不变** + **不删 pool（pool_id 不变）**）。等 `HEALTH_OK` / PG active+clean。
   - **目的**：让 cycle1 从"CRUSH 映射不变 + tmpfs/BlueStore 全新"的**确定、可复现起点**开始；否则 cycle1 起点若是脏的（tmpfs 已累积），"cycle1 预热 → cycle2+ 稳态"的判定逻辑失效。
   - **禁用**改 OSD ID 的 purge 式重建（会重洗映射，见 §九）；重建方式细节见 `pre-skills/stable-rebuild-skill.md`。
   - ⚑ **若 `rebuild-stable-ids.sh` 因 auth key 不匹配/PGMap 不兼容跑不通（上一轮的障碍）→ 这是"必须改控制变量才能跑通"的情况，属禁止擅动区（见 §四b）：停下来报告障碍，等确认，不要自行改用 purge + pool delete+recreate 绕过。** 正确修法是解决 destroy 后的 auth（`ceph auth rm` + 重新 `ceph auth add`），保持 destroy + 不删 pool。
   - 脚本启动时会做起点自检（tmpfs 占用 / OSD uptime / pool 对象数 / 157 负载）；若检测到起点不干净或负载过高会 **WARN**，此时须先处置再跑。
3. [ ] **A 组**：`./02-2-G-softclean-stability.sh A 4 90 2`（≈40min）
4. [ ] 每 cycle 后确认脚本日志出现 `✅ 变量守卫: OSD/pool_id/crush 全部不变`；若出现 `🔴 变量守卫`（OSD 集合/pool_id/crush 任一变）→ **立即停止**，说明控制变量被破坏（可能有人/脚本误删 pool 或 purge），结果无效，须先查明原因。
5. [ ] 跨 cycle diff 取证：`diff <SOFTCLEAN-c2>/07-pg-brief.txt <SOFTCLEAN-c4>/07-pg-brief.txt` 应为空（映射不变）
6. [ ] 读脚本末尾三条判定：① randread CV(从cycle2)<5% ② mseqread 不再单调降 ③ 总判定。记录结果
7. [ ] 同步结果 + `reproduction-contract-A.txt` 到本地 `results/prod-02-2-g-softclean-20260723/`
8. [ ] **分支决策**：
   - 若判据②失败（mseqread 仍单调降）→ OSD restart 未解决 tmpfs 累积 → 上**方案 C（每轮 stable-ID 重建：destroy OSD + ceph-volume --osd-id 同 ID 重建 fresh BlueStore + 不删 pool）**，另起任务书。
   - 若①②③全过 → 锁基线，进 P2-P4；（可选）补 B 组 `./...sh B 4 90 2`。
9. [ ] **【测试后必做】按 skill 复核执行合规**：对照确认——① 清理只用 `juicefs destroy`、**未 `ceph osd pool delete`**；② OSD restart 已执行**且未伴随删 pool**；③ OSD 集合/pool_id/PG 映射全程不变（查 `SOFTCLEAN-c*/00-FINGERPRINT.txt`）；④ 每项 compact cooldown 已轮询至 `compact_running=0`；⑤ 统计用 §8.3 稳态中位。在报告记录"skill 合规自查结果"，任一不符显式标注并说明影响。

---

## 四、交付物

- 结果目录 `results/prod-02-2-g-softclean-20260723/`：
  - `{A,B}/c{1..4}-randread-*-r{1,2}/`（fio.txt + per-job bw_log + nic.txt）
  - `{A,B}/c{1..4}-mseqread-*/`、`{A,B}/c{1..4}-layout-*/`
  - 取证快照 `SOFTCLEAN-c{1..4}/`（含 `07-pg-brief.txt`、`00-FINGERPRINT.txt`，验证 pool_id/OSD 集合逐 cycle 不变）
  - `reproduction-contract-{A,B}.txt`、`test.log`（含每 cycle 不变量自证 + 末尾三条判定）
- 报告落点：`doc/perf-report/00-baseline-20260723.md` 新增 §十「soft-clean+OSD-restart 稳定基线验证」：
  1. 跨 cycle randread 表（c1..c4 × r1/r2 + 每 cycle 中位）+ mseqread 表（c1..c4）
  2. randread 跨 cycle CV（**从 cycle2 起算**）+ mseqread 单调性判定
  3. 取证不变量证明（pool_id + PG 映射 diff 为空）
  4. **结论**：三个波动源是否全部消除；OSD restart 是否解决第三源（tmpfs 累积）；若达成，宣布 P2-P4 改用本口径；若判据②失败则转方案 C
- 若达成，同步 `skills/baseline-reproduction-skill.md`：
  - §2.5 轮间清理补：调优基线口径 = soft-clean + OSD restart（重置 tmpfs 内存态；不删 pool）
  - §3.1/§4.3 补：调优基线用本口径（可复现点值，cycle1 预热丢弃），生产承诺用区间基线
- 若达成，同步 `skills/baseline-reproduction-skill.md`：
  - §3.1 执行顺序新增 soft-clean 口径为**调优基线首选**（rebuild 仅用于模拟生产冷装机）
  - §4.3 判据补：调优基线用 soft-clean（可复现点值），生产性能承诺用区间基线（跨重建）

---

## 四b、GLM 授权边界（分层授权，2026-07-23 固化）

> 上一轮（02-2g 报告）GLM 因 `rebuild-stable-ids.sh` 的 auth key 问题**擅自改用 purge + pool delete+recreate**，同时踩了两个已证随机源，且未在报告声明偏离 → 数据无效。为此明确边界：

**✅ 允许 GLM 自主修复/调整（工程性，不改变量）——但修完必须在报告显式声明"改了什么、为什么"：**
- 脚本 bug（如对象数解析、compact 轮询逻辑、SSH 转义）
- 环境适配（auth key 不匹配、路径差异、依赖缺失）
- 采集增强（多记指标、加日志、加监控）
- **鼓励**：发现脚本会导致采集错误数据时，**应先修好再采**，不要用错误脚本采错误数据。

**🔴 禁止擅自改动（会破坏实验有效性）——必须停下来报告、等确认，不得绕道：**
- **控制变量**：清理方式（destroy vs purge）、是否删 pool、是否重建 OSD、pool_id、CRUSH rule/pg_num
- 测试项 / 口径 / 判据 / cycle 结构
- 任何标了"红线 / 核心变量"的项

**规则一句话**：**实现怎么修都行；改变量之前必须停下来报告，不能绕道。** 遇到"必须改变量才能跑通"的障碍（如 auth key 逼着用 purge）→ **停下来报告障碍，不要自行选一条改变量的路**。

> 脚本已内置**变量守卫**：每 cycle 自动比对 OSD 集合 / pool_id / CRUSH md5，任一被动即打 `🔴 变量守卫` 并把稳定性判定标记为不可信。GLM 若绕道改了变量，脚本会当场暴露。

---

## 五、通用注意事项（必带，见 TASK-BOOK-AUTHORING-GUIDE §二）

1. **数据统计口径**：所有 fio 加 `--write_bw_log --log_avg_msec=1000`，保留全部 per-job log；取 §8.3 稳态中位；REPEAT 取中位；randread 不合计外推。
2. **冷态净化**：每项跑前 drop_caches（157 + 150-152 全节点，脚本已含）。
3. **fresh-volume 失真**：randread 前必先 layout 铺满数据（脚本已含），不 create_on_open。
4. **后端干净态**：⚑ v3 修复——compact cooldown 轮询至 `compact_running=0` **且 `compact_queue_len=0`**（旧版只查 running 且超时静默继续，曾 57s 未压完就进下轮 → compaction 残留被误判为 tmpfs 累积）。超时须 WARN 不得静默放行。
5. **环境前置**：开测 `ceph health` OK、6 OSD up；版本含 loadRange 修复。
6. **157 红线 + WekaIO 负载门控**：WekaIO 在跑，禁动内核/网卡/RoCE/md0/WekaIO 路径；本任务**不重建 OSD、不删 pool、不动 CRUSH/pg_num**（OSD restart 允许且必要）。⚑ v3 新增：157 `load average(1min)` 超过阈值（默认 20，可 `WEKA_LOAD_MAX` 调）时起点自检 WARN；每次 fio 记录 `weka-load.txt`（前后负载），供判定读带宽虚低是否客户端抢占所致。**建议选 157 空闲时段跑。**
7. **记录规范**：结果目录含 `test.log`、`weka-load.txt`、取证快照与全部原始输出；不裁剪。

---

## 红线汇总（本任务特有）

- **清理绝不能改 pool_id 或 OSD 集合**：不 `pool delete+recreate`、不 rebuild OSD、不 OSD purge/create、不动 CRUSH/pg_num。任一发生则实验作废。**（OSD restart 不删 pool 时允许——它不改 pool_id/映射，只重置 tmpfs 内存态。）**
- **每 cycle 必须取证自证 OSD 集合 + pool_id + PG 映射不变**——这是判定"稳定来自布局不变"而非巧合的关键证据，不可省略。OSD restart 后须复查这三者仍不变。
- **cycle1 为预热/参照轮**，randread CV 从 cycle2 起算；结果须展示逐 cycle 值（含 cycle1）+ CV，不得只报一个平均数。
- **mseqread 试金石不可省**：它是第三源（tmpfs 累积）是否被 OSD restart 消除的唯一判据。仅看 randread 变稳**不足以**判定通过。
- 若判据②失败（mseqread 仍单调降）→ 第三源未解，转**方案 C**（每轮 stable-ID 重建：destroy OSD + ceph-volume --osd-id + 不删 pool），**显式标注、提示人工复审**，不得强解读为"通过"（TASK-BOOK-AUTHORING-GUIDE §四）。
