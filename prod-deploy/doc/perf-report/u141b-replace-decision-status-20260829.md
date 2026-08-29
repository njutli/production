# U141b 现状报告：patched v1.4.1 + B-catchup 能否替代 patched v1.3.1

## 日期：2026-08-29

> 任务书：`doc/perf-tasks/u141b-juicefs-141-replace-131-decision.md`（md5 `12bb631caeda364c78182dcce3a8657c`）
> 发现日志：`doc/perf-tasks/u141b-findings-log.md`（md5 `1c04f961e1acf94425a2716d866a28e0`，523 行，
> 含本报告撰写期追加的 F-17；该日志为 append-only 工作日志，**不属** Gate 0 冻结的七项产物）
> 本报告是**现状报告**：按已取得的 P0–P3 证据收口，P4 未执行。
> 所有统计由 opencode 从原始 per-job BW 日志离线复算（任务书 §七），⛔ 未采用 fio summary。

---

## 1. 结论（一句话）

```text
VERDICT = REPLACE_NOT_PROVEN
闭合项  : 2 / 7   (seqread, seqwrite)
未闭合  : 4 / 7   (mseqread, randread, randrw, randwrite) —— 全部因 ε ≥ 3%
未执行  : 1 / 7   (mseqwrite, P4 条件批次)
退步项  : 0 / 7   (两种估计量口径下均为 0)
```

**准确表述**：本批证据**既不能证明**替换安全，**也没有测到任何一项实质退步**。
未闭合的唯一原因是**判据分辨力不足**（`ε ≥ 3%` 使 `M = 2ε` 膨胀），
**不是**因为 v1.4.1 表现差。⛔ 不得把 `REPLACE_NOT_PROVEN` 读作「v1.4.1 不行」。

---

## 2. 测试对象与冻结基线

### 2.1 唯一变量（任务书 §2.2）

| 臂 | 含义 | 二进制 | md5 | PATH shim |
|---|---|---|---|---|
| **V13** | 在位基座 patched v1.3.1 | `/tmp/juicefs-03-8` | `de93563f11a5ff3bd94dd25a4e0283b1` | `/tmp/t53-bin-new` |
| **V14** | 候选 v1.4.1 + B-catchup | `/tmp/juicefs-1.4.1-patched` | `24fae0852051c80ca571cb2f20275d46` | `/tmp/t141p-bin` |

切臂只经 `PATH="<shim>:$PATH"`；两臂挂载参数、fio 规格、V4 脚本、Ceph 私有 conf 全部相同。

### 2.2 Gate 0 冻结产物（2026-08-28 attest，全程未变）

| 产物 | md5 |
|---|---|
| `u141b-driver.sh` | `320bb9b2c5a3994dfd86813c498b80ed` |
| `u141b-collect.sh` | `5a9a4430ad6cecff8f21aab6c02d489e` |
| `u141b-analyze.py` | `2fa28e47f6aac426f46c0f3fb8f03ded` |
| `u141b-gate0-offline.sh` | `bd6672a3d839f2bdba8e0d163d7de5dd` |
| 任务书 | `12bb631caeda364c78182dcce3a8657c` |
| 缺陷清单 | `c93b00a6502e8f8f87aa15738dfc52d8` |
| 处置声明 | `522b7191b3cfcd41b34f8bcc41f23c4b` |

七项在开发机与 157 `/tmp/u141b-repo` 两侧**逐一复核未变**。

### 2.3 设计要点

轮级交错（不是 block 级）：每 phase 8 轮，占位均值 V13 = V14 = **4.5**，
使单调漂移一阶抵消 —— 这是 U141 / V141R 报废后本任务的核心修正。
`MATRIX_AUTHORIZED.tsv` 新旧 RUN_ROOT md5 均 `920ea5c78f7959d3eb282d4e747da0d0`（确定性成立）。

---

## 3. 执行覆盖度

| 项 | phase | 轮数 | 状态 |
|---|---|---|---|
| seqread / mseqread / randread | P1 | 8/8 | ✅ `EVIDENCE_VALID` |
| randrw / seqwrite | P2 | 8/8（重跑） | ✅ `EVIDENCE_VALID` |
| randwrite | P3 | 8/8 | ✅ `EVIDENCE_VALID` |
| mseqwrite | P4（条件） | 0/8 | ⛔ **未执行** |

P2 首次只跑到 4/8（R05 因根分区预存 94.3% 占用而 abort，见 F-11），
该批被判 `EVIDENCE_INSUFFICIENT` 并**从 R01 完整重跑 8 轮**；
旧 RUN_ROOT 的废弃 P2 经 analyzer 独立判 `EVIDENCE_INVALID: incomplete matrix` ⇒ 独立确认（F-10）。

- 新 RUN_ROOT：`/tmp/production/opencode-u141b-20260829-074253`（P2 + P3）
- 旧 RUN_ROOT：`/tmp/production/opencode-u141b-20260828-173830`（P1 + 废弃 P2，只读证据）

---

## 4. 预注册判定（median 口径 = 约束性口径）

判据（任务书 §7.2/§7.3，⛔ 预注册不得事后改）：

```text
D_k   = BW(V14 轮) / BW(V13 轮) − 1     k 取 (R01,R02) (R04,R03) (R06,R05) (R07,R08)
D_med = median(D_1..D_4)
ε     = max(|N1|, |N2|)                 N1 = R03/R02 − 1,  N2 = R07/R06 − 1
M     = max(3.0%, 2 × ε)
ε ≥ 3.0% ⇒ RESOLUTION_INSUFFICIENT（只报上界，⛔ 不得宣告"等价"或"非劣"）
```

| 项 | D_med | ε | M | ≥−M 对数 | 判定 |
|---|---:|---:|---:|---:|---|
| seqread | −0.05% | 0.94% | 3.00% | 4/4 | **NON_INFERIOR** |
| mseqread | +0.57% | 13.20% | 26.40% | 4/4 | RESOLUTION_INSUFFICIENT |
| randread | +0.58% | 13.86% | 27.72% | 4/4 | RESOLUTION_INSUFFICIENT |
| randrw | **−8.30%** | 8.90% | 17.79% | 4/4 | RESOLUTION_INSUFFICIENT |
| seqwrite | −0.28% | 2.81% | 5.61% | 4/4 | **NON_INFERIOR** |
| randwrite | −2.12% | 17.28% | 34.57% | 4/4 | RESOLUTION_INSUFFICIENT |
| mseqwrite | — | — | — | — | ⛔ 未执行 |

**任一项 `MATERIAL_REGRESSION` = 0。** 逐对 `D_k`（median 口径）：

| 项 | (R01,R02) | (R04,R03) | (R06,R05) | (R07,R08) |
|---|---:|---:|---:|---:|
| seqread | +0.16% | −0.08% | −0.01% | −0.17% |
| mseqread | +0.29% | +1.51% | −1.00% | +0.84% |
| randread | +0.19% | +1.53% | +0.26% | +0.90% |
| randrw | **−10.25%** | −7.14% | −9.47% | +2.17% |
| seqwrite | +3.84% | −1.95% | −0.82% | +0.27% |
| randwrite | −9.42% | +2.15% | −1.06% | −3.19% |

---

## 5. ★ 口径歧义：本任务最重要的发现（F-13）

任务书 §7.1 要求同报 mean 与 median，但 §7.2 的 `BW(·)` **没有指定用哪一个**。
冻结 analyzer 在 `u141b-analyze.py:523,549` 选了 **median**（`formal_mean` 只记录、不入判定）。
opencode 独立复算**逐位复现了 analyzer 的 `formal.mean`**（P3 R01：2844.1 vs 2844.0965）
⇒ 差异 100% 来自 mean-vs-median 这一个选择。

| 项 | 秒级 CV | median（约束性） | mean（敏感性） |
|---|---:|---|---|
| seqread | 1.8–4.4% | −0.05% / ε 0.94% / **NON_INFERIOR** | +0.16% / ε 1.80% / **NON_INFERIOR** |
| mseqread | 2.3–6.7% | +0.57% / ε 13.20% / RES_INSUF | +0.00% / ε 11.26% / RES_INSUF |
| randread | 3.8–9.3% | +0.58% / ε 13.86% / RES_INSUF | −0.10% / ε 11.40% / RES_INSUF |
| randrw | 10.4–16.8% | −8.30% / ε 8.90% / RES_INSUF | −4.74% / ε 4.55% / RES_INSUF |
| seqwrite | 2.7–4.6% | −0.28% / ε 2.81% / **NON_INFERIOR** | −0.55% / ε 2.26% / **NON_INFERIOR** |
| **randwrite** | **36.5–45.0%** | −2.12% / ε **17.28%** / **RES_INSUF** | −0.53% / ε **2.09%** / **NON_INFERIOR** |

**分歧完全由秒级 CV 驱动**：CV < 10% 的项两口径同判；CV ≈ 41% 的 randwrite **判定相反**。
randwrite 秒级分布**双峰**（`p10 ≈ 1415`、`p90 ≈ 4185`），median 落在两峰间的稀疏谷底：

- median 轮间跳动：`3130 → 2836 → 2346 → 2296 → 2313 → 2338 → 2204 → 2134`（ε = 17.28%）
- mean 平滑单调：`2844 → 2685 → 2629 → 2575 → 2562 → 2542 → 2576 → 2528`（ε = 2.09%）

⛔ **不得事后择优。** analyzer 是经 Gate 0 attest 冻结的那一份实现 ⇒
**本任务约束性判定取 median**，randwrite 记 `RESOLUTION_INSUFFICIENT`；
mean 口径作为**已登记的敏感性**同时报出，供下一任务设计参考，⛔ 不得用来改写本次结论。

---

## 6. 可正式引用的定性结论（不依赖估计量选择）

1. **v1.4.1 + B-catchup 没有出现 randwrite 崩塌。**
   本批 randwrite 绝对值 median `2134–3130` / mean `2528–2844` MiB/s，
   与 patched v1.3.1 交付基线（03-17f randwrite = 2707）同量级；
   ⛔ 与**原版** v1.4.1 的 `551 / 552 / 551` 崩塌值差约 **5 倍**。
   ⇒ **升级必须携带 B-catchup 补丁**这一既有结论再次得到确认。
2. **P0 回滚可行。** V14 挂过之后 V13 可挂、再挂 V14 亦可。
   ⚑ V14 的 Setting 是 V13 的**超集**（仅多 `Tiers` 一个字段，值为空默认 tier 0；
   15 个共有字段逐字节相同）——⛔ 不得表述为「identical」，元数据确实发生了单向演进（F-02）。
3. `randwrite` 的 `W4/W1 = 0.4340`（mean 口径，8 轮合池 `ΣW4/ΣW1`；
   逐轮比值均值 0.4354，区间 0.3856–0.4894），
   落在 §7.5 记录的**生产集群历史区间 0.36–0.44** 内 ⇒ 衰减形态与在位基座一致。
4. P3 对象数恒 `1,978,582–584`，`post − pre ≤ 1` ⇒ **无对象棘轮，randwrite 为纯覆写**。

---

## 7. 唯一风险项：randrw

| 证据 | 值 |
|---|---|
| `D_med`（median / mean） | **−8.30% / −4.74%**，两口径同为负 |
| 4 对方向 | 3/4 为负 |
| 是否达 `MATERIAL_REGRESSION` | **否**（`D_med ≥ −M`，M = 17.79% / 9.11%） |

⛔ **不得据此宣告「v1.4.1 randrw 退步 8%」**，两条理由：

1. `ε = 8.90%` 本身就大于效应量的一半 ⇒ 判据无分辨力；
2. **F-15**：`randrw` 的 R02 起步异常 —— 读向 W1 = 1702.7，比其余 7 轮低 **12–14%**
   （vs 中位数 1930.7 为 **−11.8%**，vs 均值 1988.8 为 **−14.4%**），
   `W4/W1 = 1.1426 > 1`（读向），是 8 轮中**唯一**违反 analyzer「W1 > W4」DECAY 断言的一轮。
   逐轮读向 W1：`2158.7 / 1702.7 / 2133.3 / 1891.7 / 1886.9 / 2031.0 / 1889.5 / 1930.7`。
   R02 正是跨臂对 `(R01,R02)` 的 V14 侧，其起步瞬态把 `D_1` 拉到 **−6.12%（mean）/ −10.25%（median）**，
   是负号的主要贡献源。⇒ 负号有相当部分来自**一轮的起步瞬态**，而非版本差异。

⛔ 按 S20 不删样本。**randrw 是唯一需要增量取样才能排除的项。**

---

## 8. 非性能硬门与完整性（全部通过）

| 校验项 | 结果 |
|---|---|
| 七个冻结产物 md5（开发机 + 157） | 逐一未变，与 Gate 0 attest 基线一致 |
| `MATRIX_AUTHORIZED.tsv` 新旧 RUN_ROOT | md5 均 `920ea5c78f79…`，逐字节相同 |
| job 数 | seqread 1/1、mseqread 16/16、randread 128/128、randrw 128/128、seqwrite 1/1、randwrite 128/128，**零缺失** |
| 正式窗样本数 | 全部 `n = 160`（W1–W4 各 40），无因 job 覆盖不全被丢弃的秒 |
| 轮间隔 | 除 block2 drain 与 P2→P3 boundary drain 各 55 s 外，相邻轮 `END = BEGIN` **恒为 0** |
| 占位平衡 | 两 phase 均 `arm order ok = True`，V13 = V14 = 4.5 |
| Ceph | 全程 `HEALTH_OK`、6/6 OSD、`nonclean = 0`、primary map 恒 `[0:6 1:6 2:5 3:7 4:5 5:4]` |
| epoch | `e1601 → e1606` 良性递增，全程 `6 up / 6 in`，无 OSD 抖动、无 PG remap |
| 环境残留 | mount 0、真实 fio 0、t6x 0、临时端口 0 |
| 文件资产 | 384 份 `read_test.*`/`rw_test.*`/`storage_test.*` 全程保全 |

⚑ 已记录但不影响判定的执行期发现：F-01（采集器 PG 口径未按池过滤）、
F-03（`closure/*.json` 带日志前缀）、F-04（157 无 shellcheck，Gate 0 记 SKIP 而非 PASS）、
F-05（`pgrep fio` 松匹配反例）、F-07（S01 整除截断掩盖 20.97 min 越界）、
F-08（V4 默认 mount opts 漏 `--max-fuse-io 256K`）、F-16（GLM 批 3 报告两处失实）。

---

## 9. 为什么 4 项没闭合（方法学缺口，F-14）

任务书 §7.2 假设「同臂相邻对 N1、N2 的真值恒为 0」。**本批数据证明该假设在有系统趋势时不成立**：

| 项 | ε 来源 | 实质 |
|---|---|---|
| mseqread / randread | N2 = R07/R06 = −13.20% / −13.86% | F-09 的主机侧双轮下陷（≈ −11%）**正好落在 N2 上** |
| randwrite | N1 = R03/R02 = −17.28% | 前三轮陡峭 warm-up settle（3130→2836→2346）**正好被 N1 骑跨** |
| randrw | N2 = R07/R06 = −8.90% | 叠加 F-15 的 R02 起步异常 |

⇒ 同臂相邻对量到的是**「趋势 + 噪声」**而不是噪声底。
ε 被抬高后 `M = 2ε` 膨胀，判据从"严"变"空"——
**这不是让结论更保守，而是让结论无分辨力**（randwrite 的 M = 34.57%，
意味着连 30% 的退步都判不出来）。

⇒ 因此**不建议照原设计直接补跑 P4（mseqwrite）**：瓶颈在判据而非样本量，
照原方法跑大概率仍落 `RESOLUTION_INSUFFICIENT`。

修法方向（下一任务**取数前**预注册，本任务 ⛔ 不改）：

1. 每轮 fio 前跑足 warmup，让 settle 在正式窗之前收敛；
2. ε 改用**同臂非相邻的多对**，且先去趋势（低阶多项式或分块均值）再取残差；
3. 或增加轮数，用「臂 + 轮序趋势」显式建模后取 arm 系数，ε 用残差标准差；
4. **锁定点估计量**（见 §10 的 D36）。

---

## 10. 收口后待办（本任务期内 ⛔ 不改，D27 协议冻结）

| 编号 | 内容 | 来源 |
|---|---|---|
| D33 | 工具输出含日志前缀却以 `.json` 落盘，下游按扩展名解析即失败 | F-03 |
| D34 | 整数除法截断掩盖门限越界（`check_timing` 改秒级比较） | F-07 |
| D35 | 子脚本失败路径不回写 incident（collect 的 `die()` 接到 `incident()`） | F-11 |
| **D36** | **预注册未锁定点估计量，导致判定可被口径选择翻转** | **F-13** |
| — | `cmd_ceph` 加池过滤，同时打印单池/全池两行 | F-01 |
| — | 删去批 1 的「R01 实测 timing」要求，改 `1.6×` 自动中止规则 | F-06 |
| — | `PHASE_EXPECT_MIN/MAX[P1]` 由 `[13,20]` 改 `[20,24]`，重估 P2/P3/P4 | F-07 |
| — | 任务书 §5.2 补「调 V4 前必须 export 含 `--max-fuse-io 256K` 的 `JUICEFS_MOUNT_OPTS`」 | F-08 |
| — | `EVIDENCE-INTEGRITY-SKILL` 增补「复算必须先复述预注册公式，再逐字对齐实现」 | F-12 |

D36 建议做法：按秒级 CV 分档预注册（如 `CV < 10%` 用 median、`CV ≥ 10%` 用 mean 或 20% trimmed mean），
并在 Gate 0 增加一条「估计量已锁定且与任务书逐字一致」的静态检查。

---

## 11. ⚑ 本报告已订正的历史表述

| 曾经的表述 | 订正 | 依据 |
|---|---|---|
| 「读侧三项非劣」 | **作废**。用臂均值（非预注册估计量）算出 `+0.26/+0.02/+0.33%` 并宣告非劣，且漏掉 §7.3 的 `ε ≥ 3%` 前置门。按预注册口径只有 seqread 闭合 | F-12 |
| P0「settings identical」 | 改为「settings compatible (V14 superset, +Tiers default-empty), rollback verified」 | F-02 |
| P2 四轮的效应量 | ⛔ 不可引用，`EVIDENCE_INSUFFICIENT`，已由完整 8 轮重跑取代 | F-10 |
| F-15「R02 W1 比其余 7 轮**均值**低约 12%」 | 「12%」实为对**中位数**的偏差；订正为「低 12–14%」（vs 中位数 −11.8%，vs 均值 −14.4%）。结论不变 | **F-17** |

---

## 12. 证据位置

| 项 | 位置 |
|---|---|
| 发现日志（全部依据） | `doc/perf-tasks/u141b-findings-log.md`（md5 `1c04f961e1ac…`，523 行，F-01…F-17） |
| 任务书 | `doc/perf-tasks/u141b-juicefs-141-replace-131-decision.md` |
| 冻结脚本 | `scripts/FULLBASELINE/debug/u141b-{driver.sh,collect.sh,analyze.py,gate0-offline.sh}` |
| RUN_ROOT（P2+P3） | 157 `/tmp/production/opencode-u141b-20260829-074253` |
| RUN_ROOT（P1） | 157 `/tmp/production/opencode-u141b-20260828-173830` |
| opencode 独立复算 | `/tmp/opencode/u141b-{recompute,windows3,stats3,verdict}.py` + `agg.json` / `win3.json` |
| 执行报告（GLM 原始交付） | `/tmp/u141b-{phase1,batch2,batch3}-execution-report.md` |

复算与 analyzer **相互独立**；已逐位复现 analyzer 的 `formal.mean`，
median 口径 6 项 `D_med / ε / M / 判定` 亦全部复现（见 §4）。

---

## 13. 下一步（待决策）

| 选项 | 内容 | 代价 |
|---|---|---|
| **A（推荐）** | 立项 **U141c 方法学修订**：按 §9 四条修法重设计，锁定估计量，重过 Gate 0，再取数 | 改任务书 + 重跑；能真正闭合 |
| B | 照原设计补跑 P4（mseqwrite） | 大概率仍 `RESOLUTION_INSUFFICIENT`，不解决瓶颈 |
| C | 仅针对 randrw 做增量取样 | 只排除唯一风险项，其余 3 项仍不闭合 |
| D | 维持在位 patched v1.3.1 不动 | 零风险；v1.4.1 的收益（如有）也拿不到 |

⚑ **选项 A 已起草**：`doc/perf-tasks/u141c-methodology-revision-replace-decision.md`。
其中 §2.6 的判定预算 `M_eng`（方案 A 严格 3% / 方案 B 分档 3%+5%）**待决策者冻结**，
⛔ 冻结前不得进入 Gate 0。功效计算见该文件 §2.7（由本报告的实测残差尺度推出）。

**当前对生产的操作建议**：暂不替换，维持 patched v1.3.1 在位。
理由不是「v1.4.1 更差」，而是「本批证据不足以支撑替换」；
同时已确认**若将来替换，必须携带 B-catchup 补丁**。
