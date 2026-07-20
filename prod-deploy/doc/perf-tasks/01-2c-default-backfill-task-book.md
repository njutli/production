# 任务书 01-2c：default readahead 口径补测（读放大 + randrw，与 ra0 对照）

> 面向 GLM。**这是 default readahead 侧的精简补测任务书**：全量基线 / randread 的 default
> 数据已有 bw_log（报告草稿 §1.2 A 组已用稳态中位数复算），**只需补两项 default 侧真正缺失的**
> ——① randread 读放大诊断（juicefs stats），② randrw 方案 A 四档扫描。均在 **default readahead**
> （去掉 `--max-readahead 0`，其余口径完全不变）下跑，用于两口径对照与「调优基线 = default」落地。
>
> 承接（ra0 侧已验收）：
> - `results/prod-nolimit-cold-ra0-20260715-235631/`（01-1 全量基线）
> - `results/prod-nolimit-concurrency-sweep-20260716-081059/`（01-2 randread 扫描 / jfs-stats / rados）
> - `results/prod-nolimit-randrw-rerun-20260716-114143/`（01-2b randrw 方案 A）
>
> 方法论/命令见 skill：`prod-deploy/skills/test-commands-reference.md`（§5 layout / §6 随机项 / §8.3 稳态中位数 / §9 采集）、`TESTING-GUIDE.md`、`LONG-RUNNING-TEST-SKILL.md`。
> 上位规划：`prod-deploy/doc/perf-analysis/01-baseline-review-and-nolimit-plan.md` 头部「⚑ 口径策略修订」。

---

## 〇、先读：default 侧已有什么、还缺什么（背景 + 数据源澄清）

项目已定：**后续两口径都测**（default + ra0），**调优分析与调优计划以 default 为基线口径**，
ra0 作随机读专项对照（依据：AI 训练「多客户端共享读基础文件」偏顺序/多流读，default 占优）。

**default 侧已有数据（不重测）**：`results/prod-nolimit-cold-default-20260714-164343/` 已存
全量基线 bw_log（seqread/seqwrite/mseqread/mseqwrite/layout/randread/randwrite 的
`*_bw.log`）。报告草稿 §1.2 A 组的稳态中位数值（seqread 1268 / randread 1504 …）就是用
`process-baseline-final.py` 对这批 bw_log 重算得到的，**已是 §8.3 稳态口径、可信、已入报告**。
→ 因此**全量基线、randread 单点/扫描 default 侧不必重测**，直接复算/引用现有 bw_log。

**default 侧真正缺失、本任务书要补的只有两项**：
1. **juicefs stats 读放大诊断（default D0）** —— results 里只有 ra0 的 GET/fio=0.985，
   **没有 default 的读放大数据**。这是量化「default 预读用带宽换吞吐」代价的关键机理证据。
2. **randrw 降并发扫描（default，方案 A）** —— default 只有 00 那次 fresh-volume 冷启动
   失真值（已作废），**没有方案 A 的干净四档数据**。

> **⚠️ 附带修一个数据源冲突（务必处理）**：`process-baseline-final.py` 的 B 组（ra0）硬编码用
> `prod-nolimit-cold-ra0-20260715-235631/`（01-1，randread 稳态 2595），但
> `results/STAGE-SUMMARY-nolimit.md` 引用的 B 组是更早的 `...ra0-20260714-180604/`（fio 平均
> randread 2361）。两处 ra0 来源不一致。**本任务书完成时须统一为 01-1 的 235631 那次**
> （更新版本、§8.3 口径），并订正 STAGE-SUMMARY 的引用，避免报告与汇总打架。

**红线**：157 上 WekaIO 业务在跑，**禁动内核/网卡/RoCE/md0/WekaIO 路径**；只重挂 JuiceFS（改 readahead），不改集群、不重部署、不动 BeeGFS。

---

## 一、口径（与 ra0 侧唯一差异 = readahead）

**default readahead**：mount **去掉** `--max-readahead 0`，其余全部保持与 ra0 侧一致：

- 不限速 100GbE、`--storage ceph`、`--block-size 256K`、`--max-uploads 150`、`--cache-size 0`（冷态）。
- fio bs=256k(读)/4M(写)、direct=1、time_based 180s、REPEAT=3、每轮跑前 drop_caches（157 + 3 slave）。
- JuiceFS 版本 = `1.3.1+2025-12-02.e0032b2`（含 eaf3d21f），fsid `7bb47ec2-8061-11f1-a671-97520597268c`。
- 最终值一律 **§8.3 每-job 聚合稳态中位数**（截前 1/4），REPEAT=3 取中位数（第 2 大），**不取平均、不挑轮次**。
- 每 job 必留 `_bw.<id>.log` 全部文件（不许单 job）。

> 开跑前确认 mount 生效的 readahead：`cat /sys/class/bdi/.../read_ahead_kb` 或 `juicefs status` / mount 参数回显，写进 env-snapshot，证明**确实是 default 不是 ra0**。

---

## 二、补测项（两项，均 default 口径）

> 全量基线 / randread 扫描 default 侧**不测**（bw_log 已有，复算引用即可，见 §〇）。本任务书只补下面两项真正缺的 default 数据。

### 2.1 juicefs stats 读放大诊断（default randread D0，**重点**）

在 default 口径下跑 **randread D0（128×128）**，稳态期间采 `juicefs stats`（skill §9.4，
每秒一行）+ `pidstat -p <juicefs_pid> 1`：

| 指标 | 采集 | ra0 已知(对照) |
|------|------|----------------|
| fio read | | 2875 |
| object GET | | 2832 |
| **读放大 (GET/fio)** | | **0.985（无放大）** |
| meta lat | | 0.25 ms |
| fuse lat | | 5.5 ms |
| CPU | | 580% |

**目的**：default 预读预期使 GET/fio **>1**（预读拉了未用数据）。量化这个放大倍数，就量化了
「default 用带宽换顺序读吞吐」的代价——这是两口径权衡的机理证据，也为「调优基线选 default」补一条量化理由。

> randread D0 的带宽值同时可作 default randread 的复核（对报告草稿 A 组 randread 1504 的一致性检查）。

### 2.2 randrw 降并发扫描（default，方案 A，对照 01-2b）

**必须用方案 A**（复用 §5 layout 卷 + §6.4 randrw analysis 版，不 create_on_open、不 fresh volume），消除冷启动失真。矩阵/统计规则**完全同 01-2b**：

| 档 | numjobs×iodepth | 总并发 | ra0 已知(对照) |
|----|----|----|----|
| D0 | 128×128 | 16384 | 合计 2673.8 (R/W=1.0) |
| D1 | 32×16 | 512 | 1726.5 |
| D2 | 16×8 | 128 | 919.0 |
| D3 | 8×4 | 32 | 508.3 |

报 R/W/合计三列 + R/W 比 + `>=2000ms` 占比。预期与 ra0 打平（randrw 两口径历史打平）。

### 不做

- **全量基线、randread 扫描不测**（default bw_log 已有，见 §〇；仅在 §2.1 顺带复核 randread D0）。
- **rados 裸测不重跑**（后端裸测与 readahead 无关，直接引用 01-2 §4：write 2160 / rand-t128 3198 / rand-t16 2832）。
- 不改集群、不重部署、不动 BeeGFS 任务书。

---

## 三、判读（写进 summary + 分析报告）

1. **读放大**：default randread D0 的 GET/fio 放大倍数（§2.1），对照 ra0 的 0.985，
   给出「default 预读代价」量化结论；default randread 带宽复核报告草稿 A 组 1504。
2. **randrw**：default 四档是否与 ra0 打平（预期打平，坐实写口径两配置无差异）。
3. **CPU**：default randread D0 CPU vs ra0 580%（读放大高 → 传输/解码更多 → CPU 更高？
   为 01-3 CPU 天花板提供 default 侧数据点）。
4. **数据源统一**：确认报告草稿/汇总的 ra0 来源统一到 01-1（235631），订正 STAGE-SUMMARY。

---

## 四、落盘

一次任务的所有数据放在**同一个** results 目录，多项测试建**子目录**：
```
results/prod-nolimit-default-backfill-<YYYYMMDD-HHMMSS>/
├── env-snapshot.txt          # HEALTH_OK + 6/6 OSD 双网 + 无 tc + juicefs version+fsid + readahead=default 佐证
├── commands.sh
├── jfs-stats-diag/           # 2.1 randread D0 juicefs stats + pidstat + fio-output + _bw.<id>.log + nic
├── randrw-D0../D3/           # 2.2 各档 fio + 全部 _bw.<id>.log + nic + jfs-stats
├── layout-write-output.txt   # 方案 A 复用的 layout 卷写入记录
├── aggregation-results.txt   # §8.3 聚合脚本完整输出
└── summary.md                # 读放大对照 + randrw 四档对照表 + 判读 + 数据源统一说明
```

**输出分析报告（强制）**：完成后在 `doc/perf-report/` 建 `01-2c-default-backfill-report.md`
（编号对应本任务书），头部标明对应任务书 / 结果路径 / 执行审阅方 / 判定，正文含目的/结果/分析/可信度校验/后续动作。
**并把 default 的读放大 + randrw 真值回填** `perf-report/01-2`、`01-2b` 报告的对照/口径说明节；
01-1 报告 §三对照表的 default 列，用报告草稿 §1.2 A 组现有 bw_log 稳态中位数值填入（本任务书新采的读放大/randrw 项补上）。

不写 perf-analysis/（只放计划文档）；实测追加 `doc/deploy-log/results-table.md`。

---

## 五、开跑前 checklist

- [ ] env-snapshot **完整**：HEALTH_OK + 6/6 OSD up/in + 双网 10.3.1/10.3.2 + 无 tc qdisc + juicefs version(含 eaf3d21f) + fsid
- [ ] **mount = default readahead**（去掉 `--max-readahead 0`）+ cache=0 + mu150 + bs256K，**readahead 生效值写进 env-snapshot**
- [ ] randrw 用 **§6.4 analysis 版复用 layout**（方案 A），**不得裸用 §6.3 create_on_open**
- [ ] 每档每轮跑前 drop_caches（157 + 3 slave）
- [ ] fio 带 `--write_bw_log --log_avg_msec=1000`，跑完**确认每 job `_bw.<id>.log` 全部存在**（D0=128 个）
- [ ] 最终中位数走 **§8.3 每-job 聚合**，不是 fio 汇总行手挑；REPEAT=3 取中位数**不取平均**
- [ ] randread D0 采到 juicefs stats（含 object GET / fio read，供算读放大）+ pidstat CPU
- [ ] 统一 ra0 数据源到 01-1（235631），订正 STAGE-SUMMARY 引用（§〇 附带项）
- [ ] 157 WekaIO 业务状态确认，全程红线优先

---

## 六、完成后交接

- 分析报告 `doc/perf-report/01-2c-default-backfill-report.md`（编号对应本任务书）。
- default 读放大 + randrw 真值回填 `perf-report/01-2`/`01-2b` 对照节 + `deploy-log/results-table.md`；
  01-1 报告 §三 default 列用报告草稿 §1.2 A 组现有稳态值补齐。
- 回填 `perf-analysis/01` §5.1 增 default 列 / §六真值汇总；两口径对照结论供后续 default 基线调优参考。
- 统一 ra0 数据源、订正 `results/STAGE-SUMMARY-nolimit.md` 引用（改指 01-1 的 235631）。
