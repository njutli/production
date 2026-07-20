# 测试分析报告 01-1：新集群部署 + 不限速冷态基线

| 项 | 内容 |
|----|------|
| **对应任务书** | `doc/perf-tasks/01-1-cluster-deploy-and-nolimit-baseline.md` |
| **测试结果路径** | `results/prod-nolimit-cold-ra0-20260715-235631/` |
| **执行方** | GLM |
| **审阅方** | 本会话 |
| **报告日期** | 2026-07-16 |
| **判定** | ✅ 可信，可入表 |

> **口径说明**：01-1 任务书按当时决策**只测了 ra0**，但 default 全量项 bw_log 早在 00 阶段目录已采集，
> 已用稳态中位数复算入 §三对照；default 读放大 + randrw 四档由 `01-2c` 补齐。§二为 01-1 ra0 原始数值，
> §三为两口径 bw_log 稳态对照（数值以 §三为准）。⚠️ 01-2c 数据推翻了"randrw 打平"，**调优基线口径待复审**（见 §三末）。

---

## 一、本次测试目的

新集群（157 client + 150/151/152 PD+TiKV+Ceph）从零部署 Ceph EC4+2 + TiKV + JuiceFS，
验收通过后做一次**不限速 100GbE 冷态基线**，确立后续调优的起点数据。

- 口径：不限速 100GbE，256K block，单客户端，冷态 cache=0，**ra0（`--max-readahead 0`）**。
- runtime=180s，REPEAT=3 取稳态中位数（第 2 大）。
- 达标参考线：不限速 50% = 6250 MiB/s（ACCEPT=网卡半速，趋势为主不作硬判据）。
- JuiceFS `1.3.1+2025-12-02.e0032b2`（含 eaf3d21f）；fsid `7bb47ec2-8061-11f1-a671-97520597268c`。

## 二、结果数据（ra0，稳态中位数）

| 测试项 | 结果 (MiB/s) | 备注 |
|--------|-------------|------|
| seqread | 178 | 单流顺序读，暴低（见分析） |
| seqwrite | 1350 | 单流顺序写 |
| mseqread | 1755 | 多流顺序读 |
| mseqwrite | 2799 | 多流顺序写 |
| layout (128G 铺盘) | 2954 | 128 jobs × 1G，4M 铺满 |
| randread | 2572 | 128 jobs, iodepth=128, R1/R2/R3=2576/2570/2572 |
| randwrite | 2652 | R1/R2/R3=2652/2673/2560 |
| **randrw** | **72.7（已作废）** | R=20.6/W=52.1；冷启动失真，见 §三.3 |

## 三、两口径对照（default / ra0）

> **数据来源说明**：default 与 ra0 的全量项来自 bw_log 稳态中位数复算
> （`process-baseline-final.py`）——default 复算自 `prod-nolimit-cold-default-20260714-164343/`，
> ra0 复算自本报告 01-1 的 `...ra0-20260715-235631/`。**读放大 / randrw 干净四档**由 `01-2c`
> （`prod-nolimit-default-backfill-20260716-194602/`）补齐，已填入下表。
> ⚠️ default randread 存在两个值：报告草稿/00 目录 bw_log 复算 = **1504**（07-14）；01-2c 独立重测 = **1115**（07-16），
> 差 26%（见 01-2c §3.3，疑 OSD BlueStore 缓存/compaction 状态或首跑路径差异），下表 randread 保留 1504 并注 01-2c=1115。

| 测试项 (不限速, MiB/s) | default | ra0 | 谁优 |
|------------------------|---------|-----|------|
| seqread（单流顺序读） | **1268** | 180 | **default 压倒**（关预读后单流读无流水线掩盖） |
| mseqread（多流顺序读） | **3330** | 1755 | **default** |
| seqwrite | 1346 | 1350 | 相当 |
| mseqwrite | **3891** | 2799 | default 优 |
| layout（128G 铺盘写） | **3841** | 2954 | default 优 |
| randread | 1474（01-2c 重测 1099） | **2572** | **ra0 +74%~+133%**（关预读消读放大，贴后端裸上限） |
| randwrite | 3412 | 2652 | default 优 |
| randrw D0（合计，方案 A） | **1484** | **2673.8** | **ra0 +80%**（default 吃预读放大） |
| randrw D2=128（验收档） | **691** | **919.0** | **ra0 +33%** |
| **读放大 GET/fio** | **2.01×** | 0.985 | ra0 无放大；default 预读多拉 1.01×（代价已量化） |

> ⚠️ 审计修订 2026-07-17：多 job 项旧值系"合并 bw_log × numjobs"外推，已改用 fio `Run status` 聚合行。旧值：mseqread A=3311→3330, B=1784→1755; randread A=1504→1474, B=2595→2572; randwrite A=3620→3412, B=2755→2652; randrw D0 default 合计 1519.3→1484 (743+741), D2 692.0→691 (345+346)。详见 `doc/deploy-log/bw-statistics-audit.md`。

> **权衡本质（据 01-2c 补测更新）**：`default` 靠预读流水线赢 **顺序读 / 多流读 / 写类**；
> `ra0` 靠关预读消除读放大赢 **所有随机项**（randread +74%↑、randrw +33~80%、GET/fio≈1.0 贴后端天花板）。
> ⚠️ **原"randrw 两口径打平"的判断已被 01-2c 推翻**——default randrw 因 2.01× 读放大仅为 ra0 的 57-84%。
> **口径策略出现张力**：当初「调优基线取 default」的主要论据之一（randrw 打平）不再成立，且业务的
> AI 训练"多客户端共享读"在 01-3 多实例测试中也是 ra0 更优（N4 ra0=5013 vs default=2822）。
> **是否将调优基线由 default 改回 ra0，需用户复审**（见 01-2c §3.2 / `perf-analysis/01` §七口径复审）。

## 四、分析与结论

1. **随机读写主项健康**：randread=2572、randwrite=2652 三轮离散度极小（<1%），数据稳定可信。
2. **顺序读 seqread=178 异常低**：单流顺序读远低于多流（mseqread=1755），初判为 FUSE 单流
   顺序读延迟受 EC 跨节点取片影响；延迟分拆（fuse/meta/object lat）为遗留待办，见缺口①。
   （ra0 关闭预读后单流读无流水线掩盖，这一项 default 预期明显更高。）
3. **randrw=72.7 被后续作废**：本次 randrw 采用 fresh-volume（`create_on_open`）冷启动，
   读命中未写数据的空洞导致 W 虚高、R 虚低，合计被拖到 72.7。**此值不可信**，
   已由 01-2b 用方案 A（复用 layout 卷）重跑修正（真值合计 D0=2673.8，R/W≈1.0）。
4. **达标情况**：主项 randread/randwrite ≈2600，距 6250 达标线约 41%；顺序单流是短板。

## 五、后续动作

- **default 口径补测 → 01-2c**（`01-2c-default-backfill-task-book.md`），补齐 §三对照表。
- randrw 断崖已由 **01-2** 诊断、**01-2b** 定案（真值 D0=2673.8）。
- seqread 延迟分拆 → 缺口①，列入 `perf-analysis/01` §6.4，优先级中。
- 本次 ra0 真值已回填 `doc/deploy-log/results-table.md` 与 `perf-analysis/01` §5.1 稳态真值表。

## 六、数据可信度校验

- ✅ 三轮离散度小（randread/randwrite <1%）。
- ✅ env-snapshot：Ceph HEALTH_OK、6/6 OSD up/in、双网分离、无 tc。
- ✅ 每 job bw_log 保留（单 job 项）。
- ⚠️ randrw 一项因冷启动失真作废（非采集问题，是测法问题）。
