# 任务（GLM）12.1-v3 补证：补全 v3 重测的证据链（不重测，只补数据/厘清时序）

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-11
> **背景**：v3 重测（`results/memdisk-fullretest-128g-v3-20260711/`）的**核心达标结论已被采纳并固化**（randread A55.7/B112.2、randrw A48.6/B76.1，ra0 是根因；已写入 `doc/perf-analysis/12-post-diskbottleneck-plan.md §三` 和演进报告）。达标值有 fio 原始 + 128job 聚合稳态曲线双重支撑，**结论不重测**。
> **但校验发现几处证据缺口/时序矛盾，需补齐或厘清**（能从现有原始输出/日志回填就回填；确实没留的，如实说明"未采集，无法补"）：
> **本任务不重跑任何 fio 性能测试、不改结论。只补证据、厘清时序、如实标注哪些能补哪些补不了。**

---

## 要补/厘清的 4 项

### 1. B 组每项净态 %USE 落盘缺失
- `cephdf-per-item.txt` 里 **B 组所有条目只有 `=== B-xxx BEFORE/AFTER ===` 空标题，没有 TOTAL/%USE 数据行**（A 组有）。
- **要做**：从测试时的原始日志/脚本输出/终端记录里，找回 B 组各项（尤其 randwrite/randrw）开测前后的 `ceph df`/`ceph osd df` %USE，回填 `cephdf-per-item.txt`。
- **若原始数据未落盘、找不回**：如实写明"B 组每项 %USE 未采集，无法补"，并**用 B 组各项的 juicefs stats / bw_log 稳态曲线间接佐证是否发生 nearfull 降级**（曲线是否平稳、有无掉速），给出"B 组是否在净态下测"的可核实判断。

### 2. ops.log 阶段 B 时间线缺失
- `ops.log` 只记到 `23:18 A组脚本启动`，**阶段 B 主体全缺**：A 组各项执行、A→B 切换、B 组各项、网络中断（报告称 14:35-15:17 约 1h）、脚本 set -e 崩溃续接 part2。
- **要做**：根据各 fio 输出文件的时间戳（fio 结果里有 `pid=xxx: <日期时间>`）、bw_log 时间、脚本日志，**重建阶段 B 的完整时间线**补进 ops.log：每项开始/结束时间、崩溃点、续接点、网络中断落在哪个项、A/B 各自是否一次连续。
- 明确回答：**网络中断（1h）落在哪个测试项之间？有没有打断某个 fio 的 180s 运行？**（若打断了某项，该项数据要标注）

### 3. 分时清理残留未清干净（A 30G / B 33G）
- `clean-seq-A.txt` 显示 A 组 seq→layout 分时清理后**残留 30 GiB**（pool 59, 18% USE）；`clean-seq-B.txt` 残留 **33 GiB**（pool 60, 20% USE）。**都不是空池**（预期应回到 ~10 MiB）。
- 但 `cephdf-per-item.txt` 里 A-layout BEFORE=8.18%（近空）——**与 clean-seq-A 的 30G 残留矛盾**。
- **要做**：厘清这个时序矛盾——clean-seq-A 记录（23:48）之后到 A-layout BEFORE（8.18%）之间，是否又做了删池重建/额外清理？把这段补进 ops.log。**确认 layout+rand 实际起跑时池到底是 30G 残留还是 8.18% 空池**（这决定 randread/randrw 起跑净态是否真干净）。
- 顺带说明：为什么 seq→layout 分时清理没清到空（gc 语义？后台异步没等够？trash？）——与阶段 A gc 诊断结论对照。

### 4. randrw 起跑 %USE 偏高（A=83.8%）的影响复核
- A randrw 开测前 USE=83.83%（过 85% nearfull 只差 1.2pp），跑 180s 还会再涨。
- v3 已初步佐证 A randrw 稳态曲线前后半平稳（前47.5/后49.6，无掉速）。
- **要做**：对 A/B randrw 各 3 轮，用 128job 聚合逐秒曲线**分前/中/后三段取中位数**，确认全程无 nearfull 渐进掉速（若后段明显低于前段=降级，该轮数据要标注）。给出"randrw 起跑 USE 偏高是否实质影响达标值"的结论。

---

## 判据（回报 opencode）
1. B 组每项 %USE：补回来了 / 补不回（附间接佐证）。
2. 阶段 B 完整时间线：重建后补进 ops.log；网络中断落点 + 是否打断某项 180s。
3. 分时清理 30G/33G 残留 vs layout BEFORE 8.18% 的时序矛盾厘清；randread/randrw 起跑真实净态。
4. randrw 三段曲线：是否有 nearfull 降级；达标值是否受影响。
5. **总结论：v3 核心达标结论（randread/randrw + ra0 根因）的证据链是否补齐、是否仍成立**（预期成立，若补证中发现新问题如实报，可能触发局部重测）。

## 明确不做
- ❌ 不重跑 fio 性能测试（除非补证中发现某项数据确被污染/中断，才局部重测该项，需先报告请示）。
- ❌ 不改已固化的结论数值（除非发现硬伤）。
- ❌ 补不回的数据不许编造，如实写"未采集"。

## 产出
就地更新 `results/memdisk-fullretest-128g-v3-20260711/`：
- 回填 `cephdf-per-item.txt`（B 组）或新增 `cephdf-B-recovered.txt` + 说明。
- 补全 `ops.log` 阶段 B 时间线（标注哪些是事后据时间戳重建）。
- 新增 `evidence-supplement.md`：4 项补证结论 + 时序厘清 + randrw 三段分析 + "证据链是否补齐/结论是否成立"总判。
