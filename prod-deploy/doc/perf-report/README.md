# perf-report —— 测试分析报告目录

每次测试任务（每份 `doc/perf-tasks/01-N-*.md` 任务书）完成后，在此目录输出一份分析报告。

## 约定

1. **一份任务书 → 一份分析报告**，报告编号与任务书编号对应：
   - `01-1-*.md` 任务书 → `perf-report/01-1-*-report.md`
   - `01-2b-*.md` 任务书 → `perf-report/01-2b-*-report.md`
2. **报告头部**必须以表格标明：
   - 对应任务书路径
   - 测试结果路径（该任务全部数据所在的 results 目录）
   - 执行方 / 审阅方 / 报告日期 / 判定（可信 / 部分可信 / 作废）
3. **报告正文**：测试目的、结果数据、分析与结论、数据可信度校验、后续动作。
4. **数据组织**（在 `results/` 下）：
   - 一次任务的所有数据放在 **同一个** results 目录下。
   - 该任务的多项测试在此目录下 **建子目录** 保存，不散落到别的 results 目录。
5. **两口径都测（通用约定）**：常规性能项后续 `default` + `ra0 --max-readahead 0` 两口径都跑，
   报告并列对照（专项测试可在任务书中声明例外）。
6. **调优基线口径 = ra 默认（default）**：所有调优分析与调优计划以 default 配置为基线陈述；
   `ra0` 作随机读专项对照。依据见 `perf-analysis/01` 头部「口径策略修订」。

## 现有报告

| 报告 | 任务书 | 结果路径 | 判定 |
|------|--------|---------|------|
| `01-1-nolimit-baseline-report.md` | 01-1 | `results/prod-nolimit-cold-ra0-20260715-235631/` | 可信 |
| `01-2-concurrency-sweep-report.md` | 01-2 | `results/prod-nolimit-concurrency-sweep-20260716-081059/` | 部分可信（randrw 作废） |
| `01-2b-randrw-rerun-report.md` | 01-2b | `results/prod-nolimit-randrw-rerun-20260716-114143/` | 可信 |
| `01-2c-default-backfill-report.md` | 01-2c | `results/prod-nolimit-default-backfill-20260716-194602/` | 可信（default 读放大 2.01×；randrw default 为 ra0 的 57-84%）|
| `01-3-client-scalability-report.md` | 01-3 | `results/prod-nolimit-scalability-20260716-162750/` | 可信（现象层 6 核封顶属实，根因待 01-4 定位）|
| `03-12-deepseek-tikv-server-side-metrics-20260815.md` | 03-12 | `results/prod-stage03-raw-20260815/opencode-t3.12-20260815.tar.gz` | 部分可信（客户端证据可用；TiKV 归属未闭环） |
| `03-13-deepseek-f42-download-concurrency-20260815.md` | 03-13 | `results/prod-stage03-raw-20260815/opencode-t3.13-20260815.tar.gz` | 部分可信（fio 原始值可用；脚本分支作废） |
| `03-14-deepseek-segA-shared-wall-segB-seqread-20260815.md` | 03-14 | `results/prod-stage03-raw-20260815/opencode-t3.14-20260815.tar.gz` | 部分可信（共享性/seqread 可用；绝对层级与 buffer 已在 §8 订正） |
| `03-15-gate0-offline-reconciliation-20260817.md` | 03-15 Gate 0（离线） | 上述三包 + 03-11 goroutine dump | 可信（零机器对账；线上脚本待 03-16 preflight） |
| `03-16-n1n2-read-boundary-20260820.md` | 03-16 | `results/prod-stage03-raw-20260820/opencode-t3.16-20260820.tar.gz` | 可信（Pair A 18 run；读侧约束定为 per-mount，B2 解除；Pair B 无数据不影响结论） |
| `03-17-interim-abort-20260820.md` | 03-17（阶段性，未完成） | 157 `/tmp/production/opencode-t3.17-abort1/`、`/tmp/production/opencode-t3.17/`（未归档） | 阶段性可信（自变量未测到；新增 F54/F55 与阻塞 B8；订正 03-16 §六 的归因）｜⚑ F54 已被 03-17b 订正为"多值抽签" |
| `03-17b-msgr-worker-bottleneck-20260820.md` | 03-17b（T48） | `results/prod-stage03-raw-20260820/opencode-t3.17b-20260820.tar.gz`（md5 `4caca50eaf79a9c2546c4f4ce4bbe1c8`，MANIFEST 380 文件全通过） | 可信（8/8 轮完成；H1 成立、H2/H3/H4 排除；B8 解除；新增 F56/F57；bw=1438 MiB/s×满载 worker，r=0.9962） |

> 待补：`01-4-rootcause-cephfs-report.md`（任务书 `perf-tasks/01-4-rootcause-and-cephfs-control-task-book.md`）——
> pprof 根因定位（C1/C2/C3）+ 条件触发的 CephFS 对照。
