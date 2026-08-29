# U141c 任务书：替换判定的方法学修订版（v1.4.1 + B-catchup vs patched v1.3.1）

## 日期：2026-08-29

> 面向：GLM 执行；opencode 离线独立复算与签收。
>
> **执行模式：分阶段执行。** 每个 phase 内部**完全自主、不许中途停下提问**；
> phase 边界处停下回传，由 opencode 审核本 phase 全部硬门与原始数据后才放行下一 phase。
>
> 状态：任务书草案，**尚未上环境**，且 **§2.6 的判定预算（M_eng 方案 A / B）尚待决策者冻结**。
> ⛔ 预算未冻结前不得进入 Gate 0。不占 03-xx 编号（交付基座版本决策，非调优任务）。
>
> 承接：`doc/perf-report/u141b-replace-decision-status-20260829.md`
> （`VERDICT = REPLACE_NOT_PROVEN`，闭合 2/7、未闭合 4/7、未执行 1/7、退步 **0/7**）、
> `doc/perf-tasks/u141b-findings-log.md`（F-01…F-17，本任务的全部修法依据）。
>
> 方法论：执行前必须完整阅读 `skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/fixtures/known-defect-classes.tsv`（Gate 0 须逐条覆盖，**含本任务新增的 D33–D36**）、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` §二.13–18、
> `skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`、
> `skills/test-commands-reference.md` §8.3/§9、`skills/LONG-RUNNING-TEST-SKILL.md`、
> `skills/interleaved-ab-tuning-skill.md`、`skills/baseline-reproduction-skill.md` §2.2/§2.5/§3.1/§4.3。

```text
03-8    B-catchup 补丁定型，patched v1.3.1 成为交付基座
  ↓
03-17f  交付七项基线（1449 / 5366 / 5544 / 1870 / 1570 / 4676 / 2707）
  ↓
08-24   原版 v1.4.1 randwrite 崩塌 551；+B-catchup 恢复 → 补丁必要性封板
  ↓
U141    ABBA 32 cell：mseqwrite 对象棘轮，臂与对象数共线 → 主判据失效
  ↓
V141R/P 序贯非交叉：纯读零假设给出 ±5.25% 块级偏置 → 无分辨力
  ↓
U141b   轮级交错 ABBA-BAAB + 同臂相邻对自校准 → 执行成功、硬门全过、退步 0/7，
        但 ε 量到「趋势+噪声」使 M=2ε 膨胀（randwrite M 达 34.57%）⇒ REPLACE_NOT_PROVEN
  ↓
U141c   锁定点估计量 + 回归式判据 + 12 轮二阶平衡 + 预热收敛  ← 你在这里
  ├─ 七项 CI 下界 ≥ −M_eng → REPLACE_APPROVED
  ├─ 任一项 effect < −M_eng 且 CI 上界 < −M_eng → REPLACE_REJECTED
  ├─ 任一项 CI 半宽 ≥ M_eng → RESOLUTION_INSUFFICIENT（只给上界，且说明还差多少轮）
  └─ 任一非性能硬门失败 → EVIDENCE_INVALID，保留现场，⛔ 禁止补样
```

一句话：**U141b 的执行是成功的，失败的是判据**。本任务不改被测对象、不改负载、不改台架，
只把「点估计量、噪声底估计法、判定统计量、轮数」四件事按 U141b 实测数据重新预注册，
使七项真正具备分辨力，给出可执行的替换结论。

---

## 〇、为什么必须再做一轮，以及这次只改什么

U141b **不是执行失败**：32 轮全部跑完、非性能硬门全过、退步项 0/7、
矩阵确定性与完整性逐项自证通过。失败的是**判据的分辨力**。四条根因（全部出自 U141b 发现日志）：

| 根因 | U141b 的表现 | U141c 的修法 |
|---|---|---|
| **点估计量未锁定**（F-13, D36） | U141b §7.2 的 `BW(·)` 未指定 mean/median；冻结 analyzer 选了 median；randwrite 秒级 CV 41.6% 双峰，median 落稀疏谷 ⇒ 两口径**判定相反** | §2.4 预注册**唯一**估计量 = 正式窗 mean（物理上 = 字节数/窗长）；median 与 20% trimmed mean 只记录不判定；Gate 0 加静态检查 |
| **ε 量到「趋势+噪声」**（F-14） | ε = 相邻同臂对 max。F-09 主机下陷正落 N2、randwrite 跨轮 settle 正被 N1 骑跨 ⇒ ε 达 13–17%，`M=2ε` 膨胀到 26–35% | §2.5 判据换成**回归式**：`arm` 系数 + 单侧 95% CI；不确定度来自全部残差自由度，不再由 2 个相邻对决定 |
| **跨轮 settle 未收敛就取数**（F-14） | randwrite 前三轮 `2844→2685→2629`（mean）陡降，属跨轮 settle | §3.3 矩阵前加**预热轮**（丢弃但留证），收敛判据预注册；预热轮两臂对称 |
| **轮数不足 / 曲率失衡**（F-10） | 8 轮时 df=4、t=2.132，CI 半宽 3.7–5.1%；半块 4 轮时曲率失衡 9 倍 | §3.1 轮数提到 **12**（每臂 6），精确一阶+二阶平衡；df=8、t=1.860 |

**本任务不改的东西**（与 U141b 逐字相同，保证可比）：

- 两臂二进制与 md5、切臂方式（PATH shim）；
- 挂载参数 `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` + 私有 `CEPH_CONF`（`ms_async_op_threads=8`）；
- 七项 fio 规格与载体、`RUNTIME=180`、`REPEAT=1`、`direct=1`；
- V4 脚本 `/tmp/FULLBASELINE_V4.sh`（md5 `4198ea2676ba56744a3cd5eba17a5eab`）；
- 生产 PD/TiKV/Ceph/文件资产的全部冻结要求。

⚑ **明确不做的三件事**：
① ⛔ 不使用 03-22c 的 t66 seed/clone/GC 台架（只覆盖单负载；且 `dump/load/clone` 行为随版本变化，会把待测变量塞进台架）；
② ⛔ 不使用 meta 延迟流形残差判据（U141 已 8/8 失守，`T_serial_transaction` 非常数，只作旁证打印）；
③ ⛔ 不复用 U141b 的任何一轮数据拼进本任务效应量（§15.2 红线：禁止跨 RUN 拼效应量）。

---

## 一、唯一目标与问题层级

唯一通过/不通过问题（与 U141b 逐字相同，只换判据）：

> 在同一生产 JuiceFS 卷、同一挂载参数、同一 Ceph 数据面和同一文件资产上，
> 把二进制从 `de93563f11a5ff3bd94dd25a4e0283b1`（patched v1.3.1）换成
> `24fae0852051c80ca571cb2f20275d46`（patched v1.4.1 + B-catchup）后，
> **七项有效带宽是否每一项都非劣**？

其余只报数据，不作结论：

1. 各项 `arm` 系数的点值与双侧 CI、逐跨臂对比值；
2. randwrite / randrw 的 W1–W4 / 秒级 CV / `W4/W1` 是否被版本改变；
3. 元数据格式的双向兼容性与回滚可行性（U141b F-02 已确认 V14 Setting 为 V13 超集，本次复核）；
4. 距 6250 MiB/s 的缺口（本任务不追求达标，只判版本等价）。

本任务**不测试任何新参数**，不改 TiKV/Ceph/内核/网卡配置，不新增 layout，不动生产 PD/TiKV 服务。

---

## 二、口径（全部预注册，⛔ 取数后不得改）

### 2.1 带宽主口径（沿用 U141b §7.1，逐字不变）

⛔ **不采用 fio summary 作为主口径。** 主口径固定为：

1. 对每个 item 的全部 per-job BW 日志，按**实际 timed-I/O 起点**对齐
   （起点 = fio 报告的完成时刻 − `run=` 实际毫秒数；⛔ 禁用 fork 时刻 / 脚本登记起点 / sampler 启动时刻）；
2. 日志是 interval-average（`--log_avg_msec=1000`），按区间与自然秒的**重叠时长加权**重采样到 1 s；
3. 逐秒把该 item 的全部 job 求和，**只保留当秒 job 数齐全的样本**；
4. 正式窗 = `[15,175)`，`n = 160`；
5. randwrite 与 randrw 额外报 W1`[15,55)` / W2`[55,95)` / W3`[95,135)` / W4`[135,175)` 与 `W4/W1`。

### 2.2 必报的描述统计（只报不判）

正式窗的 mean / median / 20% trimmed mean / 秒级 CV / P10 / P90，以及 W1–W4 与 `W4/W1`。
⛔ 只报一个整程数字的产物不予签收。

### 2.3 ⚑ 起点自证（Gate 0 必做，零环境成本）

打印「实际起点 − 脚本登记起点」的差值；**差值 > 2 s 即说明存在启动期污染**，必须解释。
并做**起点敏感性三算**：±1 s 应使正式窗变化 <1%；+58 s 应显著改变四窗
（若 +58 s 几乎不变，说明窗口逻辑没生效 —— 这是 03-20B-R2 的原始故障模式）。

### 2.4 ★ 点估计量锁定（D36 的正面落地，本任务最关键的一条）

```text
BW(轮) ≡ 正式窗 [15,175) 内「逐秒全 job 求和」序列的算术平均（mean）
```

**唯一预注册估计量 = mean。** 三条理由，必须写进报告：

1. **物理意义唯一正确**：窗内 mean × 窗长 = 该窗实际传输字节数。
   有效带宽的定义就是「字节数 / 时间」，mean 是它的无偏估计；
   而逐秒值的 median **没有对应的物理量**。
2. **对双峰分布稳定**：U141b 实测 randwrite 秒级双峰（`p10≈1415`、`p90≈4185`、CV 36–45%），
   median 落在两峰间稀疏谷，轮间 ε = 17.28%；mean 平滑，ε = 2.09%（F-13）。
   **对双峰分布，median 是可选估计量里最不稳定的一个。**
3. **⛔ 不做数据依赖的分档切换**。曾考虑「CV<10% 用 median、≥10% 用 mean」，
   但 CV 本身是被估量、带噪声 ⇒ 分档边界附近判定可被噪声翻转，
   等于把 D36 换个形式再犯一次。**单一估计量，无分支。**

配套约束：

- median 与 20% trimmed mean **必须同时算出并落盘**，作为**已登记的敏感性**；
  ⛔ 但不得用于改写判定。若三者判定不一致，报告必须显式列出并归因到秒级分布形态。
- ⚑ **Gate 0 静态检查（新增，D36）**：analyzer 中进入判定路径的字段名必须逐字为
  预注册的那一个；`grep` 到判定路径引用 `median`/`p50`/`trimmed` 即 **FAIL**。
- ⚑ **报告纪律**：任何偏差数字必须同时写明**基准估计量**（F-17 的教训：
  「比其余 7 轮均值低约 12%」实为对中位数的偏差，对均值是 −14.4%）。

### 2.5 ★ 判定统计量（回归式，取代 `M = 2ε`）

对每个 item，用全部 `n` 轮拟合**一个**预注册模型（OLS）：

```text
BW_r = β0 + β1·r + β2·r² + βarm·1[arm(r)=V14] + e_r        r = 1..n（轮序）
effect = βarm / mean(BW)                                   相对效应量
SE     = SE(βarm) / mean(BW)                               相对标准误（经典 OLS）
df     = n − 4
halfw  = t(0.95, df) × SE                                  单侧 95% CI 半宽
CI_low = effect − halfw
```

**为什么这样合法**：§3.1 的轮序设计使 `arm` 与 `{1, r, r²}` **精确正交**
（一阶、二阶占位矩逐位相等，见 §3.2 自证表）⇒ 拟合掉时间/对象数/compaction 债这类
对轮序单调或二次的漂移，**不会吸收 arm 效应**，同时把它们从残差中移除。
这正是 U141b `ε` 失效的反面：ε 用 2 个相邻对，任何一次环境波动都直接顶满；
回归用全部 `df` 个残差自由度，单次波动只贡献 `1/df`。

⚑ **趋势阶数预注册为二次，⛔ 禁止数据驱动选阶**（选阶即引入 D36 同类漏洞）。
另须报**三次项敏感性**（加 `β3·r³` 重拟合），因 §3.2 的设计三阶不平衡（±16.5）；
若 arm 系数变化 > 1 pp，必须在报告显式讨论。

### 2.6 ⚠ 逐项判定与判定预算 M_eng（**待决策者冻结，⛔ 冻结前不得取数**）

判定表（预注册）：

| 条件 | 该项判定 |
|---|---|
| `halfw < M_eng` 且 `CI_low ≥ −M_eng` | **NON_INFERIOR** |
| `halfw < M_eng` 且 `effect < −M_eng` 且 `effect + halfw < −M_eng` | **MATERIAL_REGRESSION** |
| `halfw ≥ M_eng` | **RESOLUTION_INSUFFICIENT**（只报上界，并按 §2.7 给出还差多少轮） |
| 其余 | **INCONCLUSIVE**（报点值与 CI） |

`M_eng` 是**工程边界**，必须由运维/交付角度决定，⛔ 不得由实测噪声反推（否则重犯 U141 的
「先设边界后测噪声」与 U141b 的「边界随噪声膨胀」）。两个候选方案：

| 方案 | `M_eng` 设定 | 所需轮数 | 预计闭合 | 墙钟 |
|---|---|---|---|---|
| **A（严格）** | 七项一律 **3%** | P1 需 16、seqwrite 需 20 | 7/7 | ~4–5 夜 |
| **B（推荐）** | seqread / randwrite / randrw = **3%**；mseqread / randread / seqwrite / mseqwrite = **5%** | 一律 **12** | 7/7 | ~3 夜 |

方案 B 的运维依据（必须由决策者确认，⛔ 不得由 opencode 单方面认定）：
mseqread / randread 绝对值 ≈ 5300 MiB/s，5% = 265 MiB/s；seqwrite ≈ 1550 MiB/s，5% = 78 MiB/s。
当前交付基线距 6250 MiB/s 目标本就有较大缺口，读侧 5% 的版本间差异不改变容量规划结论；
而 randwrite / randrw 是历史崩塌与退步风险项，必须守 3%。

⚑ **决策必须在 Gate 0 之前落到本文件里**（写死每项的 `M_eng` 数值 + 一句依据），
并进入 provenance md5。⛔ 取数后修改 `M_eng` 视为 `EVIDENCE_INVALID`。

### 2.7 功效计算（由 U141b 实测数据推出，本任务轮数的唯一依据）

每轮相对残差尺度 `s`（U141b 8 轮，mean 口径，去 `arm + r + r²` 后的 RMS 残差 / 轮均值）：

| item | `s` |
|---|---:|
| seqwrite | **3.37%** |
| mseqread | **3.13%** |
| randread | **2.97%** |
| randrw | **2.43%** |
| randwrite | 1.02% |
| seqread | 0.52% |
| mseqwrite | ⛔ **未知**（U141b 未执行）；⚑ 预算按 seqwrite 的 3.37% 假设，P5 首 4 轮后必须重估 |

单侧 95% CI 半宽随轮数（`i33` 由各 `n` 的精确二阶平衡设计算出，`t` 取 `df=n−4`）：

| item | n=8 | n=12 | n=16 | n=20 | n=24 |
|---|---:|---:|---:|---:|---:|
| seqwrite | 5.09% | 3.62% | 3.01% | **2.63%** | 2.38% |
| mseqread | 4.72% | 3.36% | **2.79%** | 2.45% | 2.21% |
| randread | 4.48% | 3.19% | **2.65%** | 2.32% | 2.09% |
| randrw | 3.67% | **2.61%** | 2.17% | 1.90% | 1.71% |
| randwrite | **1.54%** | 1.10% | 0.91% | 0.80% | 0.72% |
| seqread | **0.78%** | 0.55% | 0.46% | 0.40% | 0.36% |

（加粗 = 该项首次满足 `halfw < 3%`。）读法：
**方案 A 下 seqread/randwrite 8 轮即可、randrw 需 12、mseqread/randread 需 16、seqwrite 需 20；
方案 B 下全部 12 轮即可。** 这张表也是 `RESOLUTION_INSUFFICIENT` 时「还差多少轮」的回答依据。

### 2.8 ε 的新定位：只作诊断，不作边界

仍须计算并报出，但**不进入判定**：

```text
ε_detrend = 1.4826 × MAD(e_r) / mean(BW)          去趋势稳健噪声底
excursion = max|e_r| / (1.4826 × MAD(e_r))        单次异常放大比
```

- `ε_detrend` 与 U141b 的相邻对 ε 并列报出，用于证明修法有效。
- ⚑ **异常轮审计**：`excursion > 3.5` ⇒ 该 item 标 `EXCURSION_PRESENT`，
  必须逐轮排查可归因项（Ceph epoch / nonclean / cache hit / 主机侧负载）并写进报告。
  ⛔ **但不得据此删样本**（§13 的 S20：性能端点再差都是结果）。
  n=12 时清洁高斯噪声的 `max/SD` 期望约 2.2–2.5，故 3.5 是"真异常"而非"正常极值"。

### 2.9 ⚑ 修法有效性的回顾性自证（Gate 0 必做；⛔ **不得当作结论**）

把本任务的口径**回代 U141b 已有 8 轮数据**（零环境成本），必须逐位复现下表：

| item | 旧 ε（相邻对 max） | 旧 `M=2ε` | 新 `ε_detrend` | 新 `M`(=max(3%,2ε)) | `arm` 系数 |
|---|---:|---:|---:|---:|---:|
| mseqread | 11.26% | 22.53% | **1.49%** | 3.00% | +0.02% |
| randread | 11.40% | 22.79% | **1.46%** | 3.00% | +0.33% |
| seqread | 1.80% | 3.60% | **0.31%** | 3.00% | +0.25% |
| randrw | 4.55% | 9.11% | **2.51%** | 5.03% | −3.52% |
| seqwrite | 2.26% | 4.51% | **2.62%** | 5.24% | +0.07% |
| randwrite | 2.09% | 4.17% | **0.86%** | 3.00% | −1.27% |

⇒ 噪声底估计从 11–17% 降到 0.3–2.6%，判据恢复分辨力。**这是修法有效性的证明。**

⛔⛔ **但这不是、也不得被引用为替换结论。** 三条理由：
① 这是在**已看过的数据**上换口径，正是 F-12/F-13 判定为违规的「事后择优」；
② U141b 的 `n=8`（df=4）本就不足以闭合多数项（§2.7）；
③ U141b 的 randwrite 跨轮 settle 未收敛（F-14），起点条件与本任务不同。
**正式结论只能来自 U141c 的新数据，且口径必须在取数前冻结。**
Gate 0 的作用是证明 analyzer 实现正确，不是提前拿结论。

---

## 三、矩阵与交错顺序

### 3.1 固定顺序（12 轮，⛔ 禁改、禁补点、禁挑轮）

```text
R01=V13  R02=V14  R03=V13  R04=V14  R05=V14  R06=V14
R07=V13  R08=V13  R09=V13  R10=V14  R11=V13  R12=V14
```

V13 占位 `{1,3,7,8,9,11}`，V14 占位 `{2,4,5,6,10,12}`。
⚑ 这是 12 轮下**唯一**（连同其镜像共 2 个）同时满足一阶与二阶精确平衡的划分 ——
由穷举 `C(12,6)=924` 种划分得出，Gate 0 必须复现该穷举结论。

### 3.2 平衡性自证（必须在报告中复算并列出）

| 矩 | V13 | V14 | 是否平衡 |
|---|---:|---:|---|
| 占位均值 `mean(r)` | **6.5** | **6.5** | ✅ 一阶精确 |
| `mean((r−6.5)²)` | **11.9167** | **11.9167** | ✅ 二阶精确 |
| `mean((r−6.5)³)` | −16.5 | +16.5 | ⚠ 三阶不平衡，按 §2.5 报三次项敏感性 |
| 最长同臂连跑 | 3（R04–R06） | — | 记录 |

⇒ 任何对轮序**单调或二次**的漂移（时间、对象数、compaction 债、温度）一阶与二阶完全抵消。

### 3.3 ⚑ 预热轮（丢弃但留证；针对 F-14 的跨轮 settle）

矩阵 R01 之前跑 **4 个预热轮**，臂序 `V13 V14 V14 V13`（两臂各 2 轮，对称，不引入起点偏置）：

- LABEL 用 `U141C-<PH>-W<nn>-<ARM>`（⛔ 与矩阵轮不同前缀，防被 analyzer 计入）；
- 全部产物照常落盘，**但 ⛔ 不进入任何效应量**；
- **收敛判据（预注册）**：最后 3 个预热轮的相邻相对变化 `|BW_i/BW_{i-1} − 1|` 必须**连续 2 次 < 2.0%**；
- 不满足 ⇒ 最多再加 **2** 个预热轮（仍按臂对称成对追加，即 `V14 V13`）；
  仍不满足 ⇒ **STOP 并回传**，该 phase 记 `EVIDENCE_INVALID`，⛔ 不得"先跑起来再说"。
- 依据：U141b randwrite 跨轮 settle `2844→2685→2629→2575→2562→…`，
  前三轮降幅 −5.6% / −2.1% / −2.1%，第 4 轮起进入 ±2% 带内。

⚑ 只读 phase（P1）也跑 2 个预热轮（`V13 V14`），用于挂载/缓存暖机，同样丢弃。

### 3.4 跨臂配对（只作**次要**分析，⛔ 不是主判据）

6 个不相交跨臂对，用于与 U141b 口径对照（`D_k = BW(V14)/BW(V13) − 1`，报 `median` 与逐对值）：

| 对 | 组成 | 轮距 |
|---|---|---:|
| C1 | R01(V13) ↔ R02(V14) | 1 |
| C2 | R03(V13) ↔ R04(V14) | 1 |
| C3 | R07(V13) ↔ R05(V14) | 2 |
| C4 | R08(V13) ↔ R06(V14) | 2 |
| C5 | R09(V13) ↔ R10(V14) | 1 |
| C6 | R11(V13) ↔ R12(V14) | 1 |

### 3.5 同臂对（只作诊断）

每臂 `C(6,2)=15` 对，合计 **30** 对，轮距覆盖 `{1,2,3,4,5,6,7,8,10}`
（U141b 只有 **2** 对、且都是轮距 1）。报「`|ratio−1|` 随轮距的中位数曲线」——
若随轮距单调上升，即证明「相邻对量到的是趋势而非噪声底」（F-14 的直接证据）。

### 3.6 Phase 划分与轮数

| Phase | `ITEMS` | 轮数（方案 B） | 轮数（方案 A） | 每轮墙钟（估） | 排空要求 |
|---|---|---:|---:|---:|---|
| **P0** | 兼容性门（无 fio） | — | — | ~10 min | — |
| **P1** | `seqread mseqread randread` | 12 | **16** | ~24 min | 无（读项不产生对象） |
| **P2** | `randrw` | 12 | 12 | ~20 min | 每 4 轮起点排空 |
| **P3** | `randwrite` | 12 | 12 | ~26 min | 无（覆写，gc 可回收） |
| **P4** | `seqwrite` | 12 | **20** | ~26 min | 每 4 轮起点排空 |
| **P5** | `mseqwrite`（**条件执行**） | 12 | 20 | ~28 min | **每轮**排空 |

⚑ U141b 把 `randrw + seqwrite` 合在一个 phase；本任务**拆开**，因两者所需轮数不同（§2.7），
合并会被 seqwrite 拖到 20 轮。拆开后 P2 只需 12 轮。

⚑ **S01｜时长门（按 F-06/F-07 修订）**：`check_timing` 必须**秒级比较**
（⛔ 禁整除取整 —— U141b 因 `1258/60=20` 掩盖了 20.97 min 的真实越界，见 F-07/D34）。
每轮跑完当场比对；若 **任一轮墙钟 > 1.6 × 预估**，**立即中止整个 phase**，记 `EVIDENCE_INVALID`，回传等重新排期。
⛔ 不得"继续但压缩后续轮"、⛔ 不得"停下等指示再续跑"—— 两者都产生非均匀轮间隔。
`PHASE_EXPECT_MIN/MAX` 按上表 ±20% 预置，并在 R01 后据实重估写入 `timing.tsv`。

---

## 四、目录、命名与产物布局

```text
RUN_ROOT=/tmp/production/opencode-u141c-<RUN_ID>      # RUN_ID=$(date +%Y%m%d-%H%M%S)
  ├─ MATRIX_AUTHORIZED.tsv        # 冻结矩阵：phase/round/arm/binary_md5/items（含预热轮，标 warmup=1）
  ├─ PREREG.tsv                   # ⚑ 新增：预注册口径快照（估计量、M_eng 逐项值、趋势阶数、轮数、正式窗）
  ├─ timing.tsv                   # 每轮 begin/end epoch 与墙钟（秒级）
  ├─ incidents.tsv                # append-only，动作前后各一条
  ├─ objects.tsv                  # 每轮 pre/post 的 objects/stored/max_avail
  ├─ fingerprint/
  │    ├─ frozen-manifest.tsv     # §五 全部冻结项的 md5/mtime/size，R01 前生成
  │    ├─ mount-<PH>-R<nn>-pre.txt / -post.txt
  │    ├─ arm-resolve-<PH>-R<nn>.txt
  │    └─ frozen-verify-final.tsv
  ├─ assets/asset-<PH>-R<nn>.tsv  # 384 文件 path/size/mtime（每轮 pre）
  ├─ v4/<LABEL>/                  # 每轮从 /tmp/opencode-fullbaseline-v4/<LABEL>/ 完整拷回
  ├─ rounds-u141c.tsv
  └─ closure/                     # 最终指纹核对、SHA256SUMS、归档、二进制副本
```

LABEL 命名（⛔ 严格照此，报告与复算脚本依赖它）：

```text
矩阵轮：U141C-<PHASE>-R<nn>-<ARM>      例：U141C-P1-R01-V13 / U141C-P3-R12-V14
预热轮：U141C-<PHASE>-W<nn>-<ARM>      例：U141C-P3-W01-V13
```

⚑ `RESULTS=/tmp/opencode-fullbaseline-v4` 在 V4 `:33` 是硬编码、**不可环境覆盖**；
`LAYOUT_JOBS=128` 在 `:47` 同理。不要改，按上表把产物**拷回** `RUN_ROOT/v4/` 即可。
⚑ **每次重试必须换 LABEL**（⛔ 禁复用同一 label）—— `rounds.tsv` 按 label 累计追加，
同 label 重试会把坏读数稀释进中位数（03-7L 段2b：真值 2959 被稀释成 3968 而被门放行）。

---

## 五、冻结对象与唯一变量

### 5.1 保护对象（全程不得变化）

| 对象 | 冻结要求 |
|---|---|
| 生产 PD/TiKV | systemd 服务、PID/starttime/exe、`/opt/*/conf`、`/mnt/jfs-tikv` 全程不变；只允许 HTTP 只读查询 |
| 生产块设备 | `/dev/nvme0n1`–`/dev/nvme3n1` 只读保护；任何命令不得含 `nvme` 写操作 |
| Ceph | 同一 6 OSD、同一 `juicefs-data` pool、同一 CRUSH/PG；只允许 `health/df/osd dump/pg dump/tell ... perf dump` 与已授权的 `ceph tell osd.N compact` |
| 系统 ceph.conf | md5 恒为 `5b6be34179a64e0a5f9c6d3a9690041f`；⛔ 禁改、禁 `ceph config set` |
| 私有 msgr conf | `/tmp/t141-msgr8.conf` md5 恒为 `86351c58848c7e4caaa1bbeccb211730` |
| 测试脚本 | `/tmp/FULLBASELINE_V4.sh` md5 恒为 `4198ea2676ba56744a3cd5eba17a5eab`；⛔ 一个字节都不许改 |
| 文件资产 | `read_test.*.0` 128 个（mtime 仍是 `08-04 17:06`）、`rw_test.*.0` 128 个、`storage_test.*.0` 128 个，每个恰 1073741824 字节 |
| 157 | 禁动 WekaIO、K8s、内核、网卡、RoCE、md0 |

### 5.2 唯一变量

| 臂 | 二进制 | md5 | PATH shim |
|---|---|---|---|
| **V13**（在位基座） | `/tmp/juicefs-03-8` | `de93563f11a5ff3bd94dd25a4e0283b1` | `/tmp/t53-bin-new` |
| **V14**（候选） | `/tmp/juicefs-1.4.1-patched` | `24fae0852051c80ca571cb2f20275d46` | `/tmp/t141p-bin` |

切臂**只允许**通过 `PATH="<shim>:$PATH"`；⛔ 禁 `cp`/`ln -sf` 覆盖 `/usr/local/bin/juicefs`
（该文件是错版本 `bdd182cf2cd43be657cb4ec0b5a6a048`，全程不得使用）。

### 5.3 工作负载（沿用 V4 冻结值，⛔ 不得改）

| 项 | fio 规格 | 载体 |
|---|---|---|
| seqread | `psync iodepth=1`，bs=256K，1 job | `test_dir/seqread/` |
| mseqread | `psync iodepth=1`，bs=256K，16 job | `test_dir/mseqread/` |
| randread | `libaio iodepth=128`，bs=256K，128 job，openfiles=128 | `read_test.*.0` |
| randrw | `libaio iodepth=128`，bs=256K，128 job，50/50 | `rw_test.*.0` |
| seqwrite | `psync iodepth=1`，**bs=4M**，size=32G | `test_dir/seqwrite/` |
| mseqwrite | `psync iodepth=1`，**bs=4M**，size=4G，16 job | `test_dir/mseqwrite/` |
| randwrite | `libaio iodepth=128`，bs=256K，128 job，openfiles=128 | `storage_test.*.0` |

`RUNTIME=180`，`REPEAT=1`（轮级交错靠外层循环实现），`direct=1`。

### 5.4 ⚑ 前置条件（F-08 的落地，U141b 因缺此条废掉一次 R01）

调 V4 **之前必须** export 含 256K FUSE 的挂载参数：

```bash
export JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
```

V4 默认值**不含** `--max-fuse-io 256K`，缺它 `max_read=131072` 直接撞 S12 硬门，
且 256K FUSE 是 03-17f 交付基线的组成部分 —— 漏掉整条基线不可比。
preflight 必须有一条「mount opts 含 256K」的静态检查。

---

## 六、阶段 0：离线 Gate 0（零环境接触；未过 ⛔ 禁止 SSH 到 157）

⛔ Gate 0 未过，禁止 SSH / sudo / mount / fio / ceph / juicefs 任何一条。

### 6.1 必须逐条断言的项

1. **静态检查**：`bash -n`、`bash -u -n`、`python3 ast` 全过；
   `grep` 自身脚本**发现明文口令即 FAIL**（已知例外：V4 `:37` 的 SSH 口令，
   须在报告"既有风险"节登记并建议轮换凭据 —— 本任务不改 V4）。
   ⚑ shellcheck 在 157 缺失，本项在**开发机**上补跑，结论单独记录、不进 157 provenance；
   ⛔ 不得为一个 lint 在测试机 `apt install`；⛔ 不得把 SKIP 记为 PASS（F-04）。
2. **覆盖 `known-defect-classes.tsv` 全部已知缺陷类**，含本任务新增的四类：

   | 类 | 断言 |
   |---|---|
   | **D33** | 凡 `> *.json` 的重定向须经 `sed -n '/^{/,$p'` 或 `2>/dev/null` 分流；Gate 0 对产出的每个 `*.json` 跑一次 `json.load` |
   | **D34** | `check_timing` 不得出现整数除法；必须秒级比较或向上取整 |
   | **D35** | collect 的 `die()` 必须回写 `incident()`；构造一次失败 fixture 验证 `incidents.tsv` 有记录 |
   | **D36** | 判定路径引用的估计量字段名必须逐字等于 §2.4 预注册值；`grep` 到 `median`/`p50`/`trimmed` 进入判定路径即 **FAIL** |

3. **矩阵穷举自证**：脚本必须复现「`C(12,6)=924` 种划分中仅 2 种（互为镜像）同时满足
   一阶+二阶精确平衡」，并断言 §3.1 的 V13 占位集合是其中之一。
4. **`PREREG.tsv` 一致性**：`M_eng` 逐项值、估计量名、趋势阶数、轮数、正式窗
   必须与本任务书**逐字一致**；不一致即 FAIL。
5. **采集器口径修正（F-01）**：`cmd_ceph` 解析 `pg dump pgs_brief` 必须**按池过滤**，
   并同时打印单池/全池两行。验收期望值：
   单池 `juicefs-data` = 32 PG `[0:6 1:6 2:5 3:6 4:5 5:4]`；
   全池 = 33 PG `[0:6 1:6 2:5 3:7 4:5 5:4]`（多出的 1 个是 `.mgr`）。
6. **串行门模式**：判"有外来 fio"必须用 `pgrep -c -f '(^|/)fio( |$)'`（全命令行锚定）。
   ⛔ 禁 `pgrep -c fio` —— 会被内核线程 `vfio-irqfd-clea` 命中，每轮误判失败（F-05）。

### 6.2 分析器必须先在已有真实数据上自证（零环境成本）

1. **起点敏感性三算**（§2.3）；
2. **回代 U141b 归档**，逐位复现 §2.9 的表（旧 ε / 新 `ε_detrend` / arm 系数）
   与 §2.7 的 `s` 表；⛔ 差异 > 0.01 pp 即 FAIL；
3. **合成 fixture**：注入已知 arm 效应（如 −4.0%）+ 已知线性/二次漂移 + 已知噪声，
   断言 analyzer 回收出的 arm 系数在 ±0.3 pp 内、且漂移不泄漏进 arm；
4. **不完整矩阵必须被拒**：缺任一轮时 analyzer 必须输出
   `EVIDENCE_INVALID: incomplete matrix, missing [...]`（U141b 已验证该能力，F-10）；
5. **双峰鲁棒性**：用 U141b randwrite 的秒级序列断言 mean 与 median 的差异可复现
   （证明 §2.4 的锁定确有必要）。

### 6.3 三条纪律

- Gate 0 产物（脚本全文 + md5 + fixture 输出 + 自证表）**回传后由 opencode 审完才许 SSH**；
- Gate 0 通过后，四个脚本 + 任务书 + 缺陷清单 + `PREREG.tsv` 的 md5 进入 provenance，
  **本任务期内 ⛔ 一个字节不得改**；
- 期间任何发现统一记入 `u141c-findings-log.md`（append-only，⛔ 只追加不重写，
  订正用新条目引用旧条目号），收口后一次性落地。

---

## 七、阶段 I：前置归一化与冻结

1. **环境快照** `pre`：`bash scripts/FULLBASELINE/probe/env-snapshot.sh <OUTDIR> pre [META]`；
2. **S02 环境残留**：mount 0、真实 fio 0（用 §6.1.6 的模式）、t6x 0、临时端口 0；
3. **S03 Ceph**：`HEALTH_OK`、6/6 OSD `up`+`in`、`nonclean=0`、PG primary map 按 §6.1.5 双行；
4. **S04 冻结指纹**：生成 `fingerprint/frozen-manifest.tsv`（§5.1 全部项的 md5/mtime/size）；
5. **S05 文件资产**：384 个文件数量/大小/mtime 落 `assets/asset-PREFLIGHT.tsv`（385 行）；
6. **S06 对象数**：三次采样，spread 必须为 0，且 ≤ 2.5M；记 `stored`；
7. **S07 容量**：根分区可用 ≥ **20 G**（⚑ U141b 因根分区预存 94.3% 占用、可用 4.7 G < 5 G
   导致 P2 R05 直接 abort，见 F-11。开跑前必须清理 `/tmp` 旧测试数据并复核）；
8. **S08 写类静置检查**：60 s randwrite 探针 → meta 提交率 ≥ **8000/s**（白天态）方可开跑；
   不达标等 30 min 重查（最多 4 次），仍不达标 ⇒ 记录后继续但全任务标"退化态"；
9. **P0 兼容性门**：V14 挂载 → 卸载 → V13 挂载 → 卸载 → V14 挂载，三次全成功；
   落 `p0-status-{1-V14,2-V13,3-V14}.json`（⚑ 按 D33 先剥日志前缀再落盘）。
   Setting 段做**键集合 diff**，期望结论：
   **V14 是 V13 的超集，仅多 `Tiers`（值为空默认 tier 0），15 个共有字段逐字节相同**。
   ⛔ 不得表述为「identical」（F-02）。
   ⚑ 补一个只读操作：不挂载直接 `juicefs config <META_URL>`（无参数即只读回显），
   判别 `Tiers` 是 (a) 仅客户端渲染默认值 还是 (b) 已写入 TiKV 的 setting blob；
   若 (b)，报告须写明「回滚可行但元数据已带 v1.4.1 字段」。
   任一次挂载失败 ⇒ `ROLLBACK_BLOCKED` ⇒ 强制 `REPLACE_REJECTED`，无论性能如何。
10. **`PREREG.tsv` 落盘**并按 §6.1.4 复核。

---

## 八、阶段 II：单轮执行模板（全部轮照此，不得简化）

`PH`∈{P1..P5}，`nn` 按 §3.6，`ARM`∈{V13,V14}，`SHIM` 为 `/tmp/t53-bin-new`（V13）或 `/tmp/t141p-bin`（V14）。

### 8.1 轮前

```bash
LABEL=U141C-${PH}-R${nn}-${ARM}          # 预热轮用 W${nn}
echo -e "$(date +%s)\t${LABEL}\tBEGIN" >> ${RUN_ROOT}/timing.tsv
# 对象数 pre（三次采样）→ objects.tsv
# 文件资产 pre → assets/asset-${PH}-R${nn}.tsv（384 行 path/size/mtime）
# Ceph health + PG primary map（单池/全池两行）
```

⚑ **S09｜轮前对象门**：pre `objects` 必须 ≤ **3,110,000**。超过 → 立即 `drain`；
排空后仍超 → **STOP**。⛔ 本任务**没有 SOFT-PASS**。

### 8.2 执行

```bash
export PATH="${SHIM}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CEPH_CONF=/tmp/t141-msgr8.conf
export JUICEFS_MOUNT_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"   # §5.4

# ⚑ S09b 切臂自证：必须在启动 V4 之前确认解析到本臂二进制
resolved=$(command -v juicefs)
[ "${resolved}" = "${SHIM}/juicefs" ] || { echo "ARM_RESOLVE_FAIL ${resolved}"; exit 1; }
md5sum "$(readlink -f "${resolved}")" | tee -a ${RUN_ROOT}/fingerprint/arm-resolve-${PH}-R${nn}.txt
# 该 md5 必须等于本臂 §5.2 的 md5，否则 STOP

ITEMS="${ITEMS}" OBJ_GATE=1 \
  bash /tmp/FULLBASELINE_V4.sh "${LABEL}" 180 1 --remount \
  > ${RUN_ROOT}/v4-${LABEL}.stdout.log 2>&1
echo "rc=$?" >> ${RUN_ROOT}/v4-${LABEL}.stdout.log
```

三个必须理解的点（与 U141b 相同，逐字保留）：

1. **`OBJ_GATE=1` 是强制的。** V4 `:918/:929/:940/:953` 每个写项循环体最后一句是
   `[ "${OBJ_GATE}" = "1" ] && obj_gate ...`；`OBJ_GATE=0` 时该 `&&` 列表返回 1 ⇒ 函数返回 1 ⇒
   在 `:1352` 触发 `set -e`，脚本会在最后一轮 cleanup 之后、`summary()` 之前退出（rc=1）。
2. **`--remount` 是必须的**，它让 V4 用当前 PATH 的 `juicefs` 重新挂载 —— 这正是切臂的实现方式。
3. **`REPEAT=1`（第三个位置参数）**。`RUNTIME`/`REPEAT` 在 V4 里**只认位置参数** `$2`/`$3`。

⛔ 不要用 `env -i`：只 `export` 上面三个变量即可，并保证 `PATH` 里 shim 在最前。

### 8.3 轮后（顺序不可颠倒）

```bash
# ① 挂载指纹 —— 必须在卸载之前
for p in $(pgrep -f 'juicefs.*mount'); do
  echo "pid=$p exe_md5=$(sudo md5sum /proc/$p/exe | awk '{print $1}')"
  echo "  starttime=$(awk '{print $22}' /proc/$p/stat)"
  echo "  cmdline=$(sudo tr '\0' ' ' < /proc/$p/cmdline)"
  echo "  ceph_conf=$(sudo tr '\0' '\n' < /proc/$p/environ | grep ^CEPH_CONF=)"
done > ${RUN_ROOT}/fingerprint/mount-${PH}-R${nn}-post.txt
mount | grep juice >> ${RUN_ROOT}/fingerprint/mount-${PH}-R${nn}-post.txt

# ② 对象数 post（三次采样）→ objects.tsv
# ③ 拷回全部产物
cp -a /tmp/opencode-fullbaseline-v4/${LABEL} ${RUN_ROOT}/v4/
grep -P "^${LABEL}\t" /tmp/opencode-fullbaseline-v4/rounds.tsv >> ${RUN_ROOT}/rounds-u141c.tsv
# ④ 优雅卸载
fusermount -u /mnt/juicefs || sudo umount /mnt/juicefs
echo -e "$(date +%s)\t${LABEL}\tEND" >> ${RUN_ROOT}/timing.tsv
```

⚑ **轮间隔必须均匀**：除按 §3.6 计划的 `drain` 外，相邻轮 `END → BEGIN` 间隔应为 0。
U141b 实测除两次 55 s drain 外恒为 0，本任务同标准。
⛔ 中途停下等指令会引入时间偏置，破坏轮级交错的全部意义。

### 8.4 排空过程（`drain`，仅按 §3.6 指定的点使用）

```bash
juicefs gc --compact --delete <META_URL>       # 原文输出必须落盘
# 轮询：每 30 s 采一次 objects，最多 20 次，直到连续两次不再下降
```

前后对象数与 `gc --delete` 原文输出必须落盘（交付物第 6 项）。

---

## 九、硬门（分两类，⛔ 不得共用阈值）

### 9.1 非性能证据门（失败 → 该 phase 记 `EVIDENCE_INVALID`，STOP，⛔ 禁止补样）

| Gate | 检查 | 条件 |
|---|---|---|
| **S10** | `exe_md5` | 该轮**所有** `juicefs.*mount` 进程 `/proc/<pid>/exe` md5 = 本臂 §5.2 md5 |
| **S11** | `CEPH_CONF` | 每个 mount 进程 environ 含 `CEPH_CONF=/tmp/t141-msgr8.conf` |
| **S12** | `max_read` | `mount` 输出含 `max_read=262144` |
| **S13** | fio 有效性 | `rounds.tsv` 该轮 status = `VALID`；本轮所有 item 无 `INVALID.txt` |
| **S14** | per-job BW 日志 | randread/randrw/randwrite 各 **128** 个 `*_bw.*.log`；seqread/seqwrite 各 1；mseqread/mseqwrite 各 16 |
| **S14b** | 正式窗样本数 | 每 item 每轮 `n = 160`（W1–W4 各 40）；缺秒即 FAIL |
| **S15** | 对象数 | pre ≤ 3,110,000；`post − pre` 必须是数值（⛔ 不得是字面 `GiB`） |
| **S16** | 文件资产 | 384 个文件数量与大小与 S05 一致；`read_test.*` mtime 不变 |
| **S17** | Ceph | 全程 `HEALTH_OK`；`nonclean=0`；PG primary map 按 §6.1.5 双行恒定 |
| **S18** | 冻结项 | 系统 ceph.conf、msgr conf、V4 脚本三个 md5 不变 |
| **S19** | 卸载 | 优雅卸载成功且 `mount \| grep -c juice` 为 0 |
| **S21** | 轮间隔 | 除计划 `drain` 外相邻轮间隔为 0；异常须在 `incidents.tsv` 有前后两条 |
| **S22** | 预热收敛 | 按 §3.3 达标；否则 `EVIDENCE_INVALID` |

### 9.2 性能端点（⛔ **永不触发样本删除**）

⚑ **S20**：带宽绝对值、秒级 CV、`W4/W1`、CI 半宽、`ε_detrend`、`excursion`
**再差都是结果，不是删样本的理由**。
这是 03-22b 用 CV 当证据门导致整 RUN 无法回答稳定性问题的直接教训。
`EXCURSION_PRESENT`（§2.8）只要求**排查并写进报告**，⛔ 不得删轮。

### 9.3 RUN 有效性状态机（预注册四态）

| 状态 | 含义 | 允许的引用方式 |
|---|---|---|
| `VALID` | 全部非性能门通过且矩阵完整 | 可作正式效应量 |
| `EVIDENCE_INVALID` | 任一非性能门失败或缺轮 | **只能作工程观察**，⛔ 不得进入效应量 |
| `RESOLUTION_INSUFFICIENT` | `halfw ≥ M_eng` | 只给上界 + §2.7 的"还差多少轮" |
| `INCONCLUSIVE` | 方向一致性不足 | 只报点值与 CI |

---

## 十、总判定（U141b §7.4 的修订版）

| 条件 | 结论 |
|---|---|
| 七项全部 `NON_INFERIOR`，且 P0 兼容性门通过 | **`REPLACE_APPROVED`** |
| 任一项 `MATERIAL_REGRESSION` | **`REPLACE_REJECTED`**（列明项、幅度、CI、逐对值） |
| 无退步但存在 `RESOLUTION_INSUFFICIENT`/`INCONCLUSIVE` | **`REPLACE_NOT_PROVEN`**（列明未闭合项 + 还差多少轮） |
| P0 出现 `ROLLBACK_BLOCKED` | 强制 **`REPLACE_REJECTED`**，无论性能如何 |
| 任一非性能硬门失败 | **`EVIDENCE_INVALID`** |

⚑ **verdict 必须机器可读地写在报告标题区**（⛔ 禁止把裁决藏在附录而正文留错误数字 ——
03-19 §1/§4.3/§6 至今仍写着"增益 24%–26%"而 §9 才给 `STABILITY_FAIL`，引用摘要者必然拿到错数字）。

### 10.1 只报不判的旁证

- 各项对 03-17f 七项（1449/5366/5544/1870/1570/4676/2707）的偏差 —— 跨批，仅供追溯，不入判定；
- `meta/写op`、meta `Write` 延迟、transaction 计数（从 V4 `jfs-stats-pre/post.txt` 差分）；
- 恒等式自检 `在飞 meta ≡ 4 × BW(MiB/s) × 延迟(s) × (meta/写op)`；
- randwrite 的 `W4/W1` 与历史区间对比（**0.36–0.44 生产** / 0.88–0.99 fresh 临时集群）。
  ⚑ 报此值必须注明是**合池 `ΣW4/ΣW1`** 还是**逐轮比值均值**（F-17）；
- 距 6250 MiB/s 的缺口。

---

## 十一、交付物与回传节奏

结果根目录：`${RUN_ROOT}`。归档：`/tmp/production/opencode-u141c-<RUN_ID>.tar.gz` + `.sha256`，
并 `scp` 回 `/home/lilingfeng/tmp/production/`。

必须交付（缺任一项按 `EVIDENCE_INVALID` 处理）：

1. `MATRIX_AUTHORIZED.tsv`、**`PREREG.tsv`**、`timing.tsv`、`incidents.tsv`、`objects.tsv`、`rounds-u141c.tsv`；
2. `fingerprint/frozen-manifest.tsv` + 每轮 `mount-*-post.txt` + `arm-resolve-*.txt` + `frozen-verify-final.tsv`；
3. `assets/` 每轮 384 行资产清单；
4. `v4/` 全部 LABEL 目录**完整**内容（fio.txt、全部 `*_bw.*.log`、jfs-stats-pre/post、
   mount-cmd.txt、pg-summary、hit-rate、nic.txt、gear.txt、c_amp.txt）；
   ⚑ `c_amp.txt` 是 V4 自带产物，⛔ 不需要也不应在测试机上跑 `ceph tell osd.N perf dump`（F-16）；
5. P0 的三份 `p0-status-*.json`（已剥日志前缀）+ 三次挂载日志 + `juicefs config` 只读回显；
6. 每次 `drain` 的前后对象数与 `gc --delete` 原文输出；
7. `closure/`：最终冻结项核对、生产 PD/TiKV 指纹、Ceph health/PG、二进制副本、`SHA256SUMS` 自校验全 PASS；
8. 内层 `SHA256SUMS` 与外层 `.sha256` 都必须自校验通过；
9. 环境快照 `pre` 与 `post`。

⚑ **GLM 的交付边界**：只交原始数据 + 硬门 PASS/FAIL 清单 + `incidents.tsv`。
⛔ **不要**写效应量、不要写"非劣/等价/退步"、不要算 CV/中位数/CI、不要挑轮次。
全部统计由 opencode 从原始 per-job 日志独立复算
（历史上执行方算术多次出错：03-19 的 24–26%、03-20A 的"字段不存在"、03-22c 的 GC 数字）。

| 批次 | 内容 | 停下等审核？ |
|---|---|---|
| 批 0 | **Gate 0**：脚本全文+md5、fixture 输出、§2.9 回代自证、矩阵穷举自证、起点敏感性三算 | **是**，审完才许 SSH |
| 批 1 | 阶段 I 全部（S02–S08）+ P0 兼容性结果 + `PREREG.tsv` | **是** |
| 批 2 | P1 全部轮（含预热）+ 逐轮硬门表 | **是** |
| 批 3 | P2 + P3 全部轮 | **是** |
| 批 4 | P4 全部轮 + 归档 + `closure/` | **是**，出前四 phase 判定 |
| 批 5 | （条件）P5 `mseqwrite` + 最终归档 | 是 |

**phase 内部不要停**（含预热轮）：中途停下重挂/等指令会引入时间偏置。
**phase 之间必须停**：一个 phase 废掉不该拖累下一个。

排期纪律：TiKV gc 周期 3 h —— 重型写 phase（P3/P4/P5）之间尽量留 ≥3 h；
⛔ 跨时段对比结论一律无效（同会话对比纪律）。

---

## 十二、执行步骤（可逐条勾选）

- [ ] **步骤 0（测试前）**：通读 skill 并确认关键点 —— `EVIDENCE-INTEGRITY-SKILL.md`（全篇）、
      `known-defect-classes.tsv`（含 D33–D36）、`TESTING-GUIDE.md` §1.3 compact 三指标 / §2.2 health / §3 cooldown、
      `test-commands-reference.md` §8.3 / §9、`baseline-reproduction-skill.md` §2.2/§2.5/§3.1/§4.3、
      `LONG-RUNNING-TEST-SKILL.md`、`SYSTEM-SAFETY-SKILL.md`。**须显式列出已读章节号。**
- [ ] **步骤 0b**：确认 §2.6 的 `M_eng` 已由决策者冻结并写入本文件与 `PREREG.tsv`。⛔ 未冻结不得继续。
- [ ] **阶段 0**：离线 Gate 0（§六）→ 回传批 0 → 等 opencode 放行。
- [ ] **阶段 I**：环境快照 pre、S02–S08、P0（§七）→ 回传批 1 → 等放行。
- [ ] **P1**：预热 2 轮 + 矩阵 12/16 轮（§3.6）→ 回传批 2 → 等放行。
- [ ] **P2**：预热 4 轮 + 矩阵 12 轮 → **P3**：预热 4 轮 + 矩阵 12 轮 → 回传批 3 → 等放行。
- [ ] **P4**：预热 4 轮 + 矩阵 12/20 轮 → 归档 + closure → 回传批 4 → 等放行。
- [ ] **P5（条件）**：仅在 P1–P4 全部 `NON_INFERIOR` 或 `RESOLUTION_INSUFFICIENT` 时执行；
      若已出现 `MATERIAL_REGRESSION`，结论已成立，**不执行 P5**，直接出报告。
- [ ] 环境快照 post。
- [ ] **末步（测试后）**：对照全部 skill 逐条复核执行合规，在报告记录"skill 合规自查结果"。
      必查：① 清理只用 `juicefs gc --compact --delete`，**未出现 `ceph osd pool delete`**；
      ② 清理未夹带禁止操作；③ 每写项后 compact cooldown 已轮询至
      `compact_running=0` **且 `compact_queue_len=0`**；④ 每 fio 前 drop_caches；
      ⑤ 统计口径走 §2.1/§2.4；⑥ sudo 只用授权白名单；⑦ 无生产状态变化。
      **任一不符须显式标注并说明对结论的影响，⛔ 不得默默跳过。**

---

## 十三、通用注意事项（每份任务书必带，逐条复核后在报告打勾）

1. **统计口径**：所有 fio 保留全部 per-job `*_bw.*.log`；按 §2.1 对齐求和。
   ⛔ 禁单文件乘 job 数（历史 65× 失真）、⛔ 禁用 fio 汇总均值代替正式窗。
   多实例各取聚合值后**求和**，不是乘。**randrw 的 R/W 分开报，不合计。**
   超网卡线速（100GbE ≈ 12500 MiB/s）的平均值一律不认。
2. **冷态净化**：每轮跑前 drop_caches（客户端 157 + 3 slave 全部执行）。
   `direct=1` 只绕内核页缓存，绕不开 JuiceFS 客户端缓冲 ⇒ 冷态还需 `cache-size 0`（§5.4 已含）。
3. **fresh-volume 失真**：本任务全部复用已 layout 铺好的卷，
   ⛔ 不 `create_on_open`、⛔ 不 fresh volume。
4. **后端干净态**：写项之间必须 compact cooldown 并轮询至 `compact_running=0` + `compact_queue_len=0`；
   三指标全绿**不保证** LSM tree 最优，数据异常必须排查并重测，⛔ 不得跳过。
5. **环境前置**：`ceph health` 必须 `HEALTH_OK`、所有 OSD `up`。
   **157 红线**：157 上有 WekaIO 业务，⛔ 禁动内核/网卡/RoCE/md0/WekaIO 路径；BeeGFS 须错峰。
6. **记录规范**：结果目录必须含 `commands.sh`（含 PATH、env、位置参数，口令除外）。
   `REPEAT` 在本任务是**独立轮**，不是同 mount 重跑；报全部点、⛔ 不挑轮。
7. **每个判据指名数据来源**：报告每个数字必须能回溯到原始文件路径 + 字段名；
   计数器/指标名**必须实查后写入**，⛔ 禁凭印象猜；声称"全文粘贴"必须逐字粘贴；
   声称"全程 HEALTH_OK"必须有逐次落盘证据。
8. **挂载档位**：每轮 `--remount` 相当于重新抽签（坏档深度 −15~−31%，p≈0.31）。
   本任务靠**12 轮二阶平衡 + 回归式判据**吸收，⛔ 不额外加判档门（会引入选择性剔除，与 S20 冲突）。
   ⚑ 但必须逐轮报 `ns/B` 判别器读数**作为诊断**（`fuse_ops_durations_histogram_seconds_{sum,total}`
   与 `fuse_read_size_bytes_sum / fuse_ops_total_read`），偏离参照 3.287 ns/B >10% 的轮须在报告点名。
9. **分层授权**：✅ 可自主修复脚本 bug / 环境适配 / 采集增强（修完必须在报告声明改了什么、为什么）；
   🔴 ⛔ 禁擅动控制变量（清理方式、是否删 pool、pool_id、CRUSH、pg_num、测试项、口径、判据、轮序）。
   **规则一句话：实现怎么修都行；改变量之前必须停下来报告，不能绕道。**
10. **`pool_sample` 必须用 `ceph df --format=json` + python3 解析。**
    ⛔ 禁 `rados df` 列切分（`892 GiB` 占两列，03-19 因此让 8M 硬门从未生效、U141 把 5.31M 解析成 `1.3`）。
11. **`incidents.tsv` append-only**，任何异常/修复在动作**前后各记一条**，⛔ 不得改写历史行。
    事后汇总里出现账本没有的修复项，视为账本无效。
12. **门必须标定在可达水平**。若一类门连续两次全 RUN 失败，说明门标定错误，
    应先修门再上环境 —— ⛔ 不得靠"这次也失败但结论仍成立"继续。
13. **术语**：统一用**"失真"**，⛔ 禁用"伪影"。结论若与既有论断冲突或被数据推翻，
    **显式标注、提示人工复审**，⛔ 不得默默改写论断。

---

## 十四、失败处理与红线

1. 任何硬门失败：**停止当前 phase、保留现场**（不卸载、不删目录、不清 sampler），
   在 `incidents.tsv` 记动作前后各一条，回传后由 opencode 判定。
   ⛔ 禁止换 RUN_ID 重来、禁止同 RUN 热改脚本、禁止补样替换、
   ⛔ 禁止把无效 RUN 的点值与有效 RUN 拼成新效应量、⛔ 禁止门失败后改挑有利判据。
2. ⛔ 禁 `pkill`/`killall`/`fuser -k`/模式 kill；⛔ 禁 `fusermount -uz`、`umount -l`、
   `losetup -D`、`rm -rf`；⛔ 禁 kill mount PID。
   这四条在 03-19/03-20A/03-20B/首次 03-22c 都被违反过，本任务视为红线。
3. ⛔ 禁 reboot/shutdown/systemctl 改生产服务；⛔ 禁写 `/dev/nvme*`、`/mnt/jfs-tikv`、
   `/opt`、`/etc`、`/var/lib/ceph`。
4. ⛔ 禁 `ceph osd pool delete/create`、禁改 CRUSH/PG/pool 参数、禁 `ceph config set`、
   ⛔ 禁 OSD restart 作轮间清理、⛔ 禁 `juicefs destroy`（本任务复用生产卷）。
5. 允许的 sudo 写操作**全集**：三节点 `echo 3 | sudo tee /proc/sys/vm/drop_caches`（V4 内部）、
   `sudo ceph tell osd.N compact`（V4 `compact_cooldown` 内部）。
   此外只有只读 sudo（`ceph health/df/osd ls/osd dump/pg dump/tell ... perf dump`、
   `md5sum /proc/<pid>/exe`、`cat /proc/<pid>/cmdline|environ`）。不在此列的 sudo 写操作一律禁止。
6. 脚本实现层 bug 可修，但必须：停止当前 phase、在 `incidents.tsv` 说明 diff 与原因、
   重新生成指纹、**从该 phase 的第一个预热轮重跑**。⛔ 不得在已开始的 phase 中静默换脚本。
7. 长跑期间按 `LONG-RUNNING-TEST-SKILL.md` 每 10–30 min 检查：当前 mount PID、
   `v4-*.stdout.log` 尾部、Ceph health、objects、`MemAvailable`、无 foreign fio。
8. `/tmp` 持久化：第一轮前把 `/tmp/juicefs-03-8`、`/tmp/juicefs-1.4.1-ceph`、
   `/tmp/juicefs-1.4.1-patched`、`/tmp/t141-msgr8.conf` 连同 md5 复制到
   `${RUN_ROOT}/closure/binaries/`，防 `/tmp` 清理导致 1.4.1 二进制需重新编译。

### 最终红线一句话

本任务可以丢掉的是 `test_dir` 下 `seqwrite/`、`mseqwrite/` 的载荷文件和本 RUN 的 COW 垃圾对象；
**绝不能碰**的是 `read_test.*`/`rw_test.*`/`storage_test.*` 这 384 个文件资产、
生产 PD/TiKV/Ceph 的任何配置或服务、系统 `ceph.conf`、`/tmp/FULLBASELINE_V4.sh`，
以及任何无法由指纹文件精确证明归属的 PID 或挂载。

---

## 十五、与 U141b 的差异清单（供审阅者快速核对）

| # | 项 | U141b | U141c |
|---|---|---|---|
| 1 | 点估计量 | ⚠ 未指定，实现选 median | **锁定 mean**，Gate 0 静态检查（D36） |
| 2 | 噪声底 | `ε = max(\|N1\|,\|N2\|)`，2 个相邻同臂对 | 回归残差（df=8），相邻对降级为诊断 |
| 3 | 判定边界 | `M = max(3%, 2ε)`，随噪声膨胀 | `M_eng` 工程边界（§2.6 待冻结）+ 单侧 95% CI |
| 4 | 判定统计量 | 4 对比值的 median | OLS `arm` 系数（含 `r`、`r²` 趋势项） |
| 5 | 轮数/phase | 8（df=4，t=2.132） | **12**（df=8，t=1.860）；方案 A 下 P1=16、P4=20 |
| 6 | 平衡阶数 | 一阶+二阶（ABBA-BAAB） | 一阶+二阶（12 轮唯一解），三阶偏差已登记并做敏感性 |
| 7 | 同臂对数量 | 2（都是轮距 1） | **30**（轮距 1–8,10），可画噪声-轮距曲线 |
| 8 | 跨轮 settle | ⚠ 未处理，污染 N1 | **预热轮 + 收敛判据**（§3.3，S22） |
| 9 | phase 分组 | `randrw + seqwrite` 合并 | **拆开**（所需轮数不同） |
| 10 | 时长门 | ⚠ 整除截断掩盖越界（F-07） | 秒级比较 + 1.6× 自动中止（D34） |
| 11 | PG 口径 | ⚠ 未按池过滤（F-01） | 单池/全池双行，期望值写死 |
| 12 | `*.json` | ⚠ 带日志前缀（F-03） | 落盘前剥前缀 + Gate 0 `json.load`（D33） |
| 13 | incident 回写 | ⚠ collect 的 `die()` 不回写（F-11） | `die()` 接 `incident()` + fixture 验证（D35） |
| 14 | mount opts | ⚠ 任务书漏 256K（F-08） | §5.4 前置条件 + preflight 静态检查 |
| 15 | 根分区余量 | ⚠ 阈值 5 G，实际预存 94.3% 致 abort（F-11） | S07 提到 **20 G** 并要求开跑前清 `/tmp` |
| 16 | 预注册快照 | 无 | **`PREREG.tsv`** 落盘并进 provenance |
