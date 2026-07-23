# 02-2-H 全量基线复现验证任务书  [v1 2026-07-24]

> 面向对象：GLM 执行
> 是否重跑性能：**是**。开头 stable-ID 重建**一次**，此后全程 **不重建 OSD、不删 pool**（核心变量：清理方式恒为 soft-clean+OSD-restart）。
> 承接结果目录：`results/prod-02-2-h-fullbaseline-20260724/`
> 方法论 skill：`skills/TESTING-GUIDE.md`（§1.1 health / §3 compact cooldown）、`skills/test-commands-reference.md`（§8.3 稳态中位）、`skills/baseline-reproduction-skill.md`（§2.2 清理层级 / §2.5 soft-clean / §3.1 执行顺序 / §4 复现判据）
> 因果依据：`doc/perf-report/00-baseline-20260723.md` §九（重建=随机源1）、§9.6（pool delete+recreate=随机源2）、`00-baseline-20260723-2.md`（tmpfs 累积=随机源3）；02-2-G v3 已证 soft-clean+OSD-restart 稳态可复现（randread CV=2.88%）
> 脚本：`scripts/tests/02-2-H-fullbaseline-reproduce.sh`（配套取证 `rebuild-topology-forensic.sh`、前置重建 `rebuild-stable-ids.sh`）

---

## 〇、背景与本任务定位

02-2-G v3 已用**短口径**（layout+randread+mseqread）证明：soft-clean（保 pool → 映射不变）+ OSD restart（重置 tmpfs 内存态）能得到跨 cycle 稳态可复现基线。

**本任务把它扩到全量 9 项基线，目的 = 确认"全量基线在此口径下同组可复现"，为上调优手段建立可信基线。** 跑完确认无误后，才在此基线上叠加调优配置看效果（另起任务书）。

> ⚑ **可复现性边界（先读）**：本任务证明**"同一部署"上可复现**，**非**绝对值跨部署可复现（§九物理不可能）。调优决策用本测试床（相对 Δ/比值可复现）；生产绝对承诺用区间基线。

---

## 一、目标与判据

**验证全量 9 项基线在 soft-clean+OSD-restart 口径下同组两遍可复现。**

顺序（见 §二）：**重建(一次) → A → soft-clean → A2 → soft-clean → B → soft-clean → B2**
- A/A2 = default 组两遍；B/B2 = ra0 组两遍。

判定（三条同时看）：
1. **不变量（可比性前提）**：A→A2→B→B2 全程 OSD 集合 + pool_id + CRUSH md5 不变（脚本把 A 的快照持久化到 `variable-guard-baseline.txt`，A2/B/B2 每次运行都比对；任一变 → `🔴 变量守卫` → 数据不可比）。
2. **同组复现（核心判据）**：`|A2-A|/A < 5%` 且 `|B2-B|/B < 5%`（随机项取中位数偏差；顺序项看单值偏差）。脚本末尾 `compare_reproduce` 在四组齐全后自动逐项算 Δ 并判 ✅/❌。
3. **A vs B 冷态可比（顺带产出，非本轮判据）**：因全程 CRUSH 不变、每组前都 soft-clean 冷态对齐，`B/A` 比值即 readahead(ra0) 相对 default 的效果。本轮只记录，readahead 结论留调优阶段定。

> **通过标准**：判据①全程绿 + 判据②两组都 <5% → 全量基线可复现，可进入调优。
> 判据②失败（某组 Δ≥5%）→ 排查（compact queue_len 未清 / 157 负载抢占 / 变量被破坏），必要时定位到具体项后重跑该组；持续不收敛再考虑方案 C（每轮 stable-ID 重建）。

---

## 二、口径与执行矩阵

- 脚本：`scripts/tests/02-2-H-fullbaseline-reproduce.sh <LABEL> [RUNTIME] [REPEAT]`
- **本次口径（全量基线 = 长口径）**：`RUNTIME=180  REPEAT=3`
  - **跑全量 9 项**：seqread / seqwrite / mseqread / mseqwrite / layout / randwrite-true / randread / randrw / randwrite-ow。
  - 顺序项（seqread/seqwrite/mseqread/mseqwrite/layout）REPEAT=1；随机项（randwrite-true/randread/randrw/randwrite-ow）REPEAT=3 取中位。
  - **每组 ≈ 60-90min**（9 项 × 长 runtime + 组内两次清卷 + compact cooldown）。四组合计 ~4-6h + 三次 soft-clean。
- **清理方式（核心变量，恒定）**：
  - 组间（A→A2→B→B2）= **soft-clean + OSD restart**：`juicefs destroy`（保 pool）+ compact cooldown + OSD restart（不删 pool）+ drop_caches。脚本 `soft_clean_restart` 已实现。
  - 组内（seq→randwrite、randwrite→layout）= **juicefs destroy**（不 restart OSD）。脚本 `clean_volume` 已实现。
  - ❌ 禁止：`ceph osd pool delete+recreate`（改 pool_id）、中途 rebuild OSD、OSD purge/create、动 CRUSH/pg_num。
  - ⚑ **中途绝不重建**：stable-ID 重建也会改 CRUSH 映射（波动源①）。只在【开头一次】重建建立干净起点，此后全靠 soft-clean 保持映射不变——这是 A/B 能冷态可比的前提。
- **compact cooldown 不可省**（轮询至 `compact_running=0` 且 `compact_queue_len=0`）。

---

## 三、执行步骤（逐条勾选）

0. [ ] **【测试前必做】通读 skill 并确认关键点**：`skills/baseline-reproduction-skill.md`（§2.2 清理层级 / §2.5 soft-clean+OSD-restart 流程 / §3.1 组内 9 项顺序 / §4 复现判据）、`skills/TESTING-GUIDE.md`（§1.3 compact 三指标 / §2.2 health / §3 cooldown）、`skills/test-commands-reference.md`（§8.3 稳态中位）。**特别确认：清理保留 pool（禁 delete+recreate）；中途不重建；OSD restart 仅重置 tmpfs、不删 pool。**
1. [ ] `chmod +x scripts/tests/02-2-H-fullbaseline-reproduce.sh scripts/tests/rebuild-topology-forensic.sh scripts/tests/rebuild-stable-ids.sh`
2. [ ] 前置：`ceph health` OK、6 OSD up、确认 JuiceFS 版本含 loadRange 修复
3. [ ] **【前置：建立干净起点，做一次】stable-ID 重建集群**：`scripts/tests/rebuild-stable-ids.sh`（`ceph osd destroy` + `ceph auth rm` + `ceph-volume lvm` 复用现有 LV，**禁 zap** + **保持 OSD ID 0-5** + **不删 pool（pool_id 不变）**）。等 `HEALTH_OK` / PG active+clean。
   - **目的**：让 A 从"tmpfs/BlueStore 全新"的确定起点开始。**只此一次**，A2/B/B2 之前不再重建。
   - ⚑ 若 `rebuild-stable-ids.sh` 因 auth key 不匹配/PGMap 不兼容跑不通 → 属禁止擅动区（§四b）：**停下来报告障碍，等确认，不要自行改用 purge + pool delete+recreate 绕道**。正解见 `pre-skills/stable-rebuild-skill.md` 问题 5（`ceph auth rm` 再 activate）、问题 7（`lvm prepare` 复用 LV 禁 zap）。
4. [ ] **R-A（default，紧接重建）**：`./02-2-H-fullbaseline-reproduce.sh A 180 3`
   - 脚本首次运行会把控制变量（OSD 集合/pool_id/crush md5）写入 `variable-guard-baseline.txt` 作为后续比对基线。**A 必须是重建后第一个跑的**，否则守卫基线起点错。
5. [ ] **soft-clean + OSD restart**（组间清理）：`./02-2-H-fullbaseline-reproduce.sh softclean`
   - 复用与组内完全相同的已测 `soft_clean_restart`（juicefs destroy 保 pool + compact + OSD restart + drop_caches），跑完自动比对 CRUSH md5 与基线一致。**不要手抄命令，直接用 softclean 模式。**
6. [ ] **R-A2（default 复现）**：`./02-2-H-fullbaseline-reproduce.sh A2 180 3`
   - 脚本会比对 `variable-guard-baseline.txt`，出现 `✅ 变量守卫: ... 与基线快照一致` 才继续；若 `🔴` → 立即停，查明谁改了变量。
7. [ ] **soft-clean + OSD restart**：`./02-2-H-fullbaseline-reproduce.sh softclean`
8. [ ] **R-B（ra0）**：`./02-2-H-fullbaseline-reproduce.sh B 180 3`（变量守卫仍须绿）
9. [ ] **soft-clean + OSD restart**：`./02-2-H-fullbaseline-reproduce.sh softclean`
10. [ ] **R-B2（ra0 复现）**：`./02-2-H-fullbaseline-reproduce.sh B2 180 3`
    - B2 跑完后脚本 `compare_reproduce` 自动算 `A2 vs A`、`B2 vs B` 的逐项 Δ 与 `B/A` 比值，输出到 `test.log`。
11. [ ] 每次运行后确认日志：`✅ 变量守卫`（不可比性）+ `✅ 起点自检通过`（或 WARN 已处置）+ 跑完 `✅ CRUSH md5 未变`。任一 `🔴` → 停，数据存疑。
12. [ ] 读 `test.log` 末尾 `compare_reproduce` 输出：判据②（A2 vs A、B2 vs B 最大偏差 <5%）是否 ✅。记录结果。
13. [ ] 同步结果 + `reproduction-contract-{A,A2,B,B2}.txt` + `variable-guard-baseline.txt` 到本地 `results/prod-02-2-h-fullbaseline-20260724/`
14. [ ] **分支决策**：
    - 判据①②全过 → **全量基线可复现，锁基线**，进调优阶段（在此口径上叠加配置背靠背比 Δ，另起任务书）。
    - 判据②失败（某组 Δ≥5%）→ 定位到具体项（看该项 r1/r2/r3 是否某轮异常、weka-load.txt 是否负载抢占、compact 是否超时），排除污染后**只重跑该组**；反复不收敛再评估方案 C。
15. [ ] **【测试后必做】按 skill 复核执行合规**：① 清理只用 `juicefs destroy`、**全程未 `ceph osd pool delete`**；② 组间 OSD restart 已执行**且未伴随删 pool**；③ **中途未重建**；④ OSD 集合/pool_id/CRUSH md5 四组全程不变（查 `variable-guard-baseline.txt` + 各运行日志 + `FULLBASE-*/00-FINGERPRINT.txt`）；⑤ 每项 compact cooldown 已轮询至 `compact_running=0 且 compact_queue_len=0`；⑥ 统计用 §8.3 稳态中位。在报告记录"skill 合规自查结果"，任一不符显式标注并说明影响。

### 三-补、完整编排一览（复制即用）

```bash
cd scripts/tests
chmod +x 02-2-H-fullbaseline-reproduce.sh rebuild-topology-forensic.sh rebuild-stable-ids.sh

bash rebuild-stable-ids.sh                    # 步骤3：开头重建一次（禁 zap，复用 LV，不删 pool）
./02-2-H-fullbaseline-reproduce.sh A  180 3   # 步骤4：R-A（写守卫基线）
./02-2-H-fullbaseline-reproduce.sh softclean  # 步骤5：组间清理
./02-2-H-fullbaseline-reproduce.sh A2 180 3   # 步骤6：R-A2
./02-2-H-fullbaseline-reproduce.sh softclean  # 步骤7
./02-2-H-fullbaseline-reproduce.sh B  180 3   # 步骤8：R-B
./02-2-H-fullbaseline-reproduce.sh softclean  # 步骤9
./02-2-H-fullbaseline-reproduce.sh B2 180 3   # 步骤10：R-B2（末尾自动算复现偏差）
```

> ⚑ `softclean` 模式复用与组内完全相同的 `soft_clean_restart`（不删 pool、不重建 OSD），并自动比对 CRUSH md5。**禁止**在组间 `ceph osd pool delete/create` 或 rebuild OSD。

---

## 四、交付物

- 结果目录 `results/prod-02-2-h-fullbaseline-20260724/`：
  - `{A,A2,B,B2}/<item>-<label>[-r{1,2,3}]/`（fio.txt + per-job bw_log + nic.txt + weka-load.txt），9 项齐全
  - `variable-guard-baseline.txt`（A 写入，四组比对的控制变量基线）
  - 取证快照 `FULLBASE-{A,A2,B,B2}/`（含 `00-FINGERPRINT.txt`、`07-pg-brief.txt`，验证四组布局一致）
  - `reproduction-contract-{A,A2,B,B2}.txt`、`test.log`（含每组变量守卫 + 末尾 compare_reproduce 逐项 Δ）
- 报告落点：`doc/perf-report/` 新建 `02-2h-fullbaseline-reproduce-20260724.md`：
  1. 四组 × 9 项数据表（顺序项单值；随机项 r1/r2/r3 + 中位）
  2. 同组复现偏差表（A2 vs A、B2 vs B 逐项 Δ，标 ✅/❌）+ 最大偏差
  3. 变量守卫证明（四组 OSD 集合/pool_id/CRUSH md5 一致；跑前跑后 md5 不变）
  4. （顺带）A vs B 冷态 B/A 比值表（readahead 效果初步观察，结论留调优阶段）
  5. **结论**：全量基线是否同组可复现；若达成，宣布进入调优阶段；若某项超阈，定位并给出重跑/排查方案
- 若达成，同步 `skills/baseline-reproduction-skill.md` §4：把"全量 9 项基线复现口径"补为 §4.5（重建一次 + 全 soft-clean + 同组两遍 <5% 判据），标注 02-2-H 已验证。

---

## 四b、GLM 授权边界（分层授权，2026-07-23 固化，本任务沿用）

**✅ 允许 GLM 自主修复/调整（工程性，不改变量）——但修完必须在报告显式声明"改了什么、为什么"：**
- 脚本 bug（对象数解析、compact 轮询、SSH 转义、compare 汇总逻辑）
- 环境适配（auth key 不匹配、路径差异、依赖缺失）
- 采集增强（多记指标、加日志、加监控）
- **鼓励**：发现脚本会采错数据时，**先修好再采**，不要用错误脚本采错误数据。

**🔴 禁止擅自改动（会破坏实验有效性）——必须停下来报告、等确认，不得绕道：**
- **控制变量**：清理方式（destroy vs purge）、是否删 pool、是否重建 OSD、pool_id、CRUSH rule/pg_num
- **中途重建**（本任务特有红线：只开头重建一次；A2/B/B2 前绝不重建）
- 测试项 / 口径 / 判据 / 组顺序

**规则一句话**：**实现怎么修都行；改变量之前必须停下来报告，不能绕道。** 遇到"必须改变量才能跑通"的障碍（如 auth key 逼着用 purge）→ **停下来报告障碍，不要自行选一条改变量的路**。

> 脚本已内置**跨运行变量守卫**：A 写基线快照文件，A2/B/B2 每次运行比对；任一被动即打 `🔴 变量守卫`。GLM 若中途重建或误删 pool，脚本下次运行会当场暴露。

---

## 五、通用注意事项（必带，见 TASK-BOOK-AUTHORING-GUIDE §二）

1. **数据统计口径**：所有 fio 加 `--write_bw_log --log_avg_msec=1000`，保留全部 per-job log；取 §8.3 稳态中位；随机项 REPEAT=3 取中位；randread 不合计外推。
2. **冷态净化**：每项跑前 drop_caches（157 + 150-152 全节点，脚本已含）。
3. **fresh-volume 失真**：randread 前必先 layout 铺满数据（脚本已含），不 create_on_open；randwrite-true 才 create_on_open。
4. **后端干净态**：compact cooldown 轮询至 `compact_running=0` **且 `compact_queue_len=0`**（旧版只查 running，曾 57s 未压完就进下轮 → 被误判为累积）。超时须 WARN 不得静默放行。
5. **环境前置**：开测 `ceph health` OK、6 OSD up；版本含 loadRange 修复。
6. **157 红线 + WekaIO 负载门控**：WekaIO 在跑，禁动内核/网卡/RoCE/md0/WekaIO 路径；本任务**不重建 OSD（除开头一次）、不删 pool、不动 CRUSH/pg_num**（组间 OSD restart 允许且必要）。157 `load average(1min)` 超阈值（默认 20，`WEKA_LOAD_MAX` 可调）起点自检 WARN；每项 fio 记 `weka-load.txt`（前后负载），供判定读带宽虚低是否客户端抢占。**建议选 157 空闲时段跑。**
7. **记录规范**：结果目录含 `test.log`、`weka-load.txt`、取证快照与全部原始输出；不裁剪。

---

## 红线汇总（本任务特有）

- **只开头重建一次**：A2/B/B2 之前**绝不重建**（stable-ID 重建也改 CRUSH 映射=波动源①）。中途重建即毁掉 A/B 可比性，实验作废。
- **清理绝不能改 pool_id 或 OSD 集合**：不 `pool delete+recreate`、不 rebuild OSD、不 OSD purge/create、不动 CRUSH/pg_num。任一发生实验作废。（OSD restart 不删 pool 时允许——只重置 tmpfs 内存态。）
- **四组必须同布局**：变量守卫 A 写基线、A2/B/B2 比对，全程 OSD 集合+pool_id+CRUSH md5 不变——这是判据②（同组复现）与判据③（A/B 可比）成立的前提。
- **判据②以同组两遍偏差为准**：`|A2-A|/A`、`|B2-B|/B` <5%（随机项中位）。不得只报一组或只报平均；须展示逐项 Δ。
- 若某组超阈 → **先定位污染源（负载/compact/变量）再重跑该组**，不得强解读为"通过"（TASK-BOOK-AUTHORING-GUIDE §四）；持续不收敛显式标注、提示人工复审并评估方案 C。
