# JuiceFS 部署调试记录（prod-deploy）

本目录记录 JuiceFS（TiKV + Ceph）在 4 机集群上的部署与调试过程。

## 与上层的关系

- `doc/perf-analysis/` = 之前 1Gbps 环境的调优链路，是 JuiceFS 最优配置的**来源依据**
- 本目录 = 当前 4 机/100GbE 环境的部署与测试**落地过程**

配置的每一项都引用上层调优结论作为依据，详见 `prod-deploy/README.md` 的配置对照表。

## 文件命名约定

- `NN-<topic>.md` — 单个部署/调试步骤的记录（NN 为两位序号）
- `results-table.md` — 持续更新的实测结果总表

## 建议的初始条目

- `01-deploy-and-cold-baseline.md` — 部署过程 + 不限速口径冷态基线
- `02-cold-baseline-1gbit.md` — 千兆限速口径冷态基线（eno12409 TBF 1Gbps）
- `results-table.md` — 实测带宽总表

> 上层调优阶段已坐实的结论（`--max-readahead 0`、直连 RADOS、block-size 256K）不在此重复验证，只在 README 的对照表中引用。
