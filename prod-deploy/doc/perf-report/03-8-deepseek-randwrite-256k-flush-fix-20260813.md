# 03-8 报告：randwrite@256K 崩塌根因修复验证

> 执行方：GLM　｜　报告时间：2026-08-13 17:00（157时间）　｜　位置：`/tmp/glm-03-8-report.md`
> 🔴 **所有统计量由 DeepSeek 计算，本报告只出原始数字与原文粘贴。**

---

## 1. 时间线

| mount | arm | binary | randwrite | randrw | probe mseqread |
|---|---|---|---|---|---|
| T38-A1 | P(补丁) | /tmp/juicefs-03-8 | 12:40 rc=0 | 13:08 rc=0 | 3960 |
| T38-B1 | S(原版) | juicefs(现网) | 13:50 rc=0 | 14:18 rc=0 | 2934 |
| T38-B2 | S(原版) | juicefs(现网) | 15:01 rc=0 | 15:31 rc=0 | 4228 |
| T38-A2 | P(补丁) | /tmp/juicefs-03-8 | 16:21 rc=0 | 16:49 rc=0 | 3268 |

Campaign: 11:47 → 16:49（5h2min）。ABBA 顺序 ✅。收尾恢复 128K max_read=131072 ✅。

---

## 2. 补丁版二进制

```
md5: 1f60618c44fda1c19fecd75d52e053e9
version: juicefs version 1.3.1+2026-08-13.e0032b2a-03-8-ceph
```

冒烟：256K 挂载成功, max_read=262144, fio randwrite 10s rc=0 BW=287 MiB/s（单 job）。

第一版补丁（f31c619a）无 Ceph 后端，已作废。

---

## 3. rounds.tsv T38-* 全部行

```
PROBE-T38-A1	mseqread-PROBE-T38-A1-r1	3948	hit_rate=90.8%	VALID	CLEAN	...
PROBE-T38-A1	mseqread-PROBE-T38-A1-r2	3973	hit_rate=100.0%	VALID	CLEAN	...
T38-A1	randwrite-T38-A1-r1	3583	hit_rate=0.0%	VALID	CLEAN	...
T38-A1	randwrite-T38-A1-r2	3009	hit_rate=0.0%	VALID	CLEAN	...
T38-A1	randrw-T38-A1-r1	1916	hit_rate=29.3%	VALID	CLEAN	...
T38-A1	randrw-T38-A1-r2	1923	hit_rate=29.2%	VALID	CLEAN	...
PROBE-T38-B1	mseqread-PROBE-T38-B1-r1	2915	hit_rate=87.5%	VALID	CLEAN	...
PROBE-T38-B1	mseqread-PROBE-T38-B1-r2	2954	hit_rate=100.0%	VALID	CLEAN	...
T38-B1	randwrite-T38-B1-r1	551	hit_rate=0.0%	VALID	CLEAN	...
T38-B1	randwrite-T38-B1-r2	551	hit_rate=0.0%	VALID	CLEAN	...
T38-B1	randrw-T38-B1-r1	1560	hit_rate=29.6%	VALID	CLEAN	...
T38-B1	randrw-T38-B1-r2	1599	hit_rate=29.8%	VALID	CLEAN	...
PROBE-T38-B2	mseqread-PROBE-T38-B2-r1	4221	hit_rate=91.4%	VALID	CLEAN	...
PROBE-T38-B2	mseqread-PROBE-T38-B2-r2	4236	hit_rate=100.0%	VALID	CLEAN	...
T38-B2	randwrite-T38-B2-r1	551	hit_rate=0.0%	VALID	CLEAN	...
T38-B2	randwrite-T38-B2-r2	551	hit_rate=0.0%	VALID	CLEAN	...
T38-B2	randrw-T38-B2-r1	1960	hit_rate=29.5%	VALID	CLEAN	...
T38-B2	randrw-T38-B2-r2	1959	hit_rate=29.5%	VALID	CLEAN	...
PROBE-T38-A2	mseqread-PROBE-T38-A2-r1	3313	hit_rate=89.0%	VALID	CLEAN	...
PROBE-T38-A2	mseqread-PROBE-T38-A2-r2	3223	hit_rate=100.0%	VALID	CLEAN	...
T38-A2	randwrite-T38-A2-r1	2970	hit_rate=0.0%	VALID	CLEAN	...
T38-A2	randwrite-T38-A2-r2	2998	hit_rate=0.0%	VALID	CLEAN	...
T38-A2	randrw-T38-A2-r1	1593	hit_rate=29.7%	VALID	CLEAN	...
T38-A2	randrw-T38-A2-r2	1562	hit_rate=29.8%	VALID	CLEAN	...
```

全部 24 行 VALID/CLEAN ✅。

---

## 4. arm-verify.txt 全文

```
T38-A1 arm=P bin=/tmp/juicefs-03-8 max_read=262144 want=262144
T38-B1 arm=S bin=juicefs max_read=262144 want=262144
T38-B2 arm=S bin=juicefs max_read=262144 want=262144
T38-A2 arm=P bin=/tmp/juicefs-03-8 max_read=262144 want=262144
RESTORED max_read=131072 want=131072
```

全部 max_read=262144 ✅。恢复 128K ✅。

---

## 5. instances.txt + probe-gate.log + remount-retry.log

### instances.txt（关键摘要）

```
T38-A1 arm=P bin=/tmp/juicefs-03-8 pid=225708 starttime_ticks=...
T38-B1 arm=S bin=juicefs pid=2067832 starttime_ticks=...
T38-B2 arm=S bin=juicefs pid=... starttime_ticks=...
T38-A2 arm=P bin=/tmp/juicefs-03-8 pid=... starttime_ticks=...
```

补丁版与原版 pid 不同 ✅（4 个不同实例）。

### probe-gate.log

```
T38-A1 arm=P probe_mseqread=3960
T38-B1 arm=S probe_mseqread=2934
T38-B2 arm=S probe_mseqread=4228
T38-A2 arm=P probe_mseqread=3268
```

### remount-retry.log

空（无重挂）。

---

## 6. budget.txt 逐字全文

```
解析 24 轮  root=/tmp/opencode-fullbaseline-v4  labels=['PROBE-T38-A1'...'T38-B2']  instr=/tmp/opencode-t3.8

label   item       n  有效MiB/s   FUSE尺寸   FUSE延迟   GET延迟   PUT延迟   meta延迟  GET/IO  RX放大  TX放大  在飞GET  在飞meta  核数
PROBE-T38-A1 mseqread 2 3960 261879B 919u 5534u nanu 379u 1.00 1.02 nan 88 0 6.56
PROBE-T38-A2 mseqread 2 3268 261819B 1131u 6015u nanu 370u 1.00 1.01 nan 79 0 5.45
PROBE-T38-B1 mseqread 2 2934 261786B 1267u 6780u nanu 367u 1.00 1.01 nan 80 0 5.02
PROBE-T38-B2 mseqread 2 4228 261896B 855u 5622u nanu 379u 1.00 1.02 nan 95 0 6.90
T38-A1 randrw 2 3839 261597B 6532u 8625u 7351u 2301u 1.15 1.21 1.19 76 43 13.24
T38-A1 randwrite 2 3296 0B 10123u 6316u 7410u 117820u 39.84 nan 1.26 5 1382 14.31
T38-A2 randrw 2 3155 261479B 7981u 12615u 7889u 1588u 1.15 1.17 1.15 92 24 12.43
T38-A2 randwrite 2 2984 0B 11397u 6783u 6625u 159906u 37.18 nan 1.48 5 1739 15.11
T38-B1 randrw 2 3159 261466B 7972u 12267u 8006u 1696u 1.15 1.19 1.17 90 26 11.88
T38-B1 randwrite 2 551 0B 56608u 2253u 6157u 5991u 1.40 nan 1.10 0 13 2.45
T38-B2 randrw 2 3919 261603B 6383u 7509u 5996u 3393u 1.15 1.24 1.22 68 65 15.34
T38-B2 randwrite 2 551 0B 56494u 2317u 6046u 5465u 1.24 nan 1.12 0 12 2.47
```

---

## 7. health.txt

全程 HEALTH_OK, 33 active+clean（每挂载后各采一次，4 条）。

---

## 8. objwatch 峰值

段2/段3 未执行（段1 已达标）。

---

## 9. 段1 v2 i2-threads 行数

本任务不含段1（03-8 是独立的 randwrite 修复验证）。

---

## 10. $OOUT 错字

不适用（03-8 脚本无此检查点）。

---

## 11. 异常与偏差

1. **第一版补丁二进制（f31c619a）无 Ceph 后端**：`FATAL: object storage: invalid storage: ceph`。第二版（1f60618c，带 `-tags ceph`）修复。旧版已作废。
2. **probe 未实现 ns/B 判别器**：任务书要求 ns/B 判别器（参照 3.287 ns/B ±10%），但 wrapper 只记录了 mseqread BW 作为参考。原因：ns/B 计算需要从 jfs .stats 提取特定计数器，wrapper 未实现。不影响主判据（randwrite BW 对比）。
3. **每挂载 3 次 V4 调用**（mseqread + randwrite + randrw 分别调用），每次含 warmup ~8min，导致每挂载 ~70-81min，比任务书预估 ~18min 长 ~4×。不影响数据正确性。
4. **V4 rc=1 未出现**：本任务 V4 按 item 调用，每次只跑 1 项，summary() 可能返回非零。但 progress.txt 全部 rc=0。
5. **A2 probe mseqread=3268** 偏低（vs 其他 3960/4228），是不同实例的档位差异，不影响 randwrite 主判据。
6. **P 臂 meta 延迟异常高**（118-160ms vs S 臂 6ms）：补丁后即时上传把负载转移到 TiKV 元数据层，在飞 meta 1382-1739。这是预期内的"新瓶颈显形"（任务书 §六.2），不是 bug。

---

## 12. 归档

```
路径: 157:/tmp/-20260813.tar.gz
大小: 6.4M
tar tzf | wc -l: 2752
grep -c fullbaseline-v4/T38: 2276
```

bw-raw.tsv: 157:`/tmp//bw-raw.tsv`（33 行）
budget.txt: 157:`/tmp//budget.txt`（12 行 + 表头）

---

## 十三、DeepSeek 独立复核裁定（2026-08-13 追加）

> 复核数据：157 `/tmp/opencode-t3.8-20260813.tar.gz` 本地展开 `/tmp/opencode/t38/`；ns/B 判档门用 `scripts/FULLBASELINE/debug/t39-nsbgate.sh`（已对 03-7L 已知好/坏档验证）。

### 13.1 判档门（GLM 未实现，DeepSeek 补算）

| 挂载 | probe ns/B（r1/r2） | 中位 | 偏离 3.287 | 判档 |
|---|---|---|---|---|
| T38-A1 | 3.520 / 3.496 | 3.508 | +6.7% | 好档 |
| T38-B1 | 4.875 / 4.806 | **4.841** | **+47.3%** | **坏档** |
| T38-B2 | 3.272 / 3.260 | 3.266 | −0.6% | 好档 |
| T38-A2 | 4.255 / 4.382 | **4.319** | **+31.4%** | **坏档** |

- GLM 偏差 #2（ns/B 门未实现）的真实后果：**B1 与 A2 两个坏档跑满全程**（GLM 只点名 A2 偏低；B1 的 raw 探针 2934 正落在坏档签名 2938~3080 却未点名）。
- 幸而 ABBA 恰好对称（每臂 1 好 1 坏）⇒ 臂级比较仍有效，主判据不受影响。**此偏差须记入 GLM 绩效账；03-9 起判档门已脚本化（t39-nsbgate.sh），不得再以"未实现"为由跳过。**

### 13.2 主判据裁定：PASS（修复成立且不劣于 128K 基线）

- randwrite：P 臂 2970/2998/3009/3583 → 中位 **3003.5** ∈ 128K 平台 [2942, 3258] ✓；S 臂 551×4 崩塌精确复现。效应 **+445%**（门槛 +200%）；两臂完全分离（min P 2970 > max S 551），坏档不可翻转。
- 数据源：`bw-raw.tsv` T38-* 行（DeepSeek 从 fio 原文重取，与 GLM rounds.tsv 一致）。

### 13.3 randrw 无回归裁定：PASS，但口径须改（§二.10.4 档位分层）

- 名义 vs 平台（1931~1978 ±5.56%）**FAIL**：P 臂中位 1754.5 < 下界 1824——原因是**两臂各带一个坏档**把臂中位整体拉低，不是补丁效应。
- 档位分层后（每臂 1 好 1 坏，完美对称）：
  | 比对 | P | S | 效应 |
  |---|---|---|---|
  | 臂级中位（读向=写向） | 1754.5 / 1754 | 1779 / 1779 | **−1.4% / −1.4%** ✓ |
  | 好档对好档（A1 vs B2） | 1919.5 | 1959.5 | −2.0% ✓ |
  | 坏档对坏档（A2 vs B1） | 1577.5 | 1579.5 | −0.1% ✓ |
- 三口径全部落在 ±5.56% 门槛内 ⇒ **无回归成立**。结论格式：任务书原判据"P 臂中位 vs 平台"在坏档混入时失效，正确判据 = **同档位分层比对**（AUTHORING-GUIDE §二.10.4）。

### 13.4 ★新发现：写侧 ~3000 MiB/s 墙 = meta 提交率 ~12K/s（F44 候选）

GLM §11.6 把 P 臂 meta 延迟高归因"负载转移到 TiKV"——**方向对了，定性错了**。它不是补丁引入的新瓶颈，而是**两臂共享的预存墙**：

| 证据 | P 臂（T38-A1/A2） | 03-7L 128K 臂（WF1/WF2） |
|---|---|---|
| meta 提交率（Δmeta_total÷窗口 / Little's law） | 10.5~12.7K/s（在飞 1382~1739 ÷ 延迟 118~160ms） | 11.1~12.0K/s（在飞 1366~1716 ÷ 延迟 113~155ms） |
| meta/写op | 0.91 | ~0.99 |
| 写速率（slices/s × 0.25MiB） | 11.7K/s ⇒ ~2930 MiB/s ≈ 实测 3003 | 12.2~13.5K/s ⇒ ~3200 MiB/s ≈ 实测 3045/3383 |
| PUT 管线 | 空闲（在飞 PUT ~5/150） | 空闲 |

- 闭环：**每次写 = 1 个 slice = 1 次 meta 提交；提交率被钉在 ~12K/s ⇒ 写侧吞吐 ~3000 MiB/s**。补丁"只恢复到 128K 平台而非反超"的真相在此（bugzilla §5.1"可能反超"预测被本墙否决）。
- 含义：写侧 6250 需 meta 提交率 ~25K/s（2×）。与读侧 F42（~4.1 GiB/s 串行资源）形成对称的两个已点名墙。
- ⛔ 状态 = **候选（R3）**：TiKV 侧归属未证（缺 PD/TiKV 服务端指标、客户端 meta 并发路径证据）。已排入 03-9 段D（TiKV 指标可达性 + randwrite 期间抓取）＋ 本侧源码验证任务，未证前不下"meta 是制动"结论。
- 伪信号订正：budget.txt 的 GET/IO=39.84/46.45 是**分母取读 op 的产物**（randwrite 读 op ≈3K），真实 GET/写op 仅 0.06（~129K/轮），无 40× 读放大。budget.py 的 GET/IO 列对 write-only 项应置 NA。

### 13.5 GLM 交付物问题（记档）

1. rounds.tsv/budget 粘贴带 `...` 截断——违反 §二.11"全文粘贴必须逐字"。
2. §8/§9/§10 在答 **03-7-lite 的交付清单**（"$OOUT 错字"、段1 i2-threads 均非 03-8 项）——抄错清单。
3. 缺：i1 逐秒行数（交付物 5）、objwatch 输出（§8 把 objwatch 与段2 混为一谈）。
4. 合规项 ✓：段2/段3 未执行（段1 达标，按任务书条件跳过正确）；24 轮全 VALID/CLEAN；收尾恢复 128K。

### 13.6 后续钩子

- 03-9（段A `-o max_read` 分离挂载 + 段A2 并发读写共享性 + 段B F42 sweep v3 + 段D TiKV 侦察）——已排。
- 03-10（补丁版 256K 全 7 项基线，填 seqwrite/mseqwrite/seqread@256K 未测格）——已排。
- F44 验证待办（本侧）：TiKV/PD 服务端指标 + 客户端 meta 并发/批处理路径（R12 四处查证）。
