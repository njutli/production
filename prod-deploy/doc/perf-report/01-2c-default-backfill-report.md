# 01-2c Default readahead 口径补测报告

## 报告头

| 字段 | 值 |
|------|-----|
| 对应任务书 | `doc/perf-tasks/01-2c-default-backfill-task-book.md` |
| 测试结果路径 | `results/prod-nolimit-default-backfill-20260716-194602/` |
| 远端原始数据 | 157:`/tmp/default-backfill/` |
| 执行日期 | 2026-07-16 |
| 执行方 | AI 助手（GLM） |
| 审阅方 | （待审阅） |
| 判定 | default 预读读放大 2.01×，randread 仅为 ra0 的 39%；randrw default 为 ra0 的 57-84%（随并发降低差距收窄） |

---

## 一、测试目的

补齐 default readahead 口径两项缺失数据：
1. randread D0 读放大诊断（juicefs stats 量化 GET/fio）— ra0 侧已有 0.985，default 缺失
2. randrw D0-D3 方案 A 四档扫描 — default 只有 fresh-volume 冷启动失真值（已作废）

附带：统一 ra0 数据源到 01-1（235631），订正 STAGE-SUMMARY 引用

---

## 二、测试结果

### 2.1 randread D0 读放大诊断

配置：default readahead, randread, bs=256k, 128×128=16384, direct=1, cache=0, max-uploads=150, time_based 180s, REPEAT=3

| 指标 | default (本测试) | ra0 (01-2 对照) | 比值 |
|------|-----------------|----------------|------|
| fio bw（聚合行中位数） | 1099 MiB/s | 2894 MiB/s | 38% |
| steady bw (§8.3 旧，合并×128) | 1114.8 MiB/s | 2876.2 MiB/s | 39% |
| CPU | 368% (3.7核) | 595% (6.0核) | 62% |
| FUSE read | 1115 MiB/s | 2873 MiB/s | 39% |
| object GET | 2242 MiB/s | 2871 MiB/s | 78% |
| **读放大 (GET/fio)** | **2.01×** | **1.0×** | — |
| FUSE latency | 14.1ms | 5.4ms | 261% |
| FUSE ops | ~9200/s | ~22000/s | 42% |

> ⚠️ 审计修订 2026-07-17：bw 采纳 fio 聚合行中位数（1099 / 2894），旧 §8.3 值（1114.8 / 2876.2）系"合并 bw_log × numjobs"外推，偏差 ≤1.4%，保留作参考。读放大计算基于 fio 聚合行。详见 `doc/deploy-log/bw-statistics-audit.md`。

**读放大量化**：
- default：后端 GET 2242 MiB/s，但 fio 有效带宽仅 1115 → **2.01× 读放大**（预读拉了 1127 MiB/s 未用数据）
- ra0：GET 2871 = fio 2876 → **无放大**（预读关闭，每个请求只读 256K 需要的数据）

**CPU 分析**：
- default CPU 368%（3.7核）远低于 ra0 595%（6.0核）。原因：default 有效吞吐低→IOPS 低（9200 vs 22000）→CPU 消耗少。CPU 不是 default 的瓶颈，预读浪费的带宽才是。

### 2.2 randrw D0-D3 扫描（方案 A）

配置：default readahead, randrw, bs=256k, 方案 A（复用 layout, 无 create_on_open）, direct=1, cache=0, time_based 180s, REPEAT=3

| 档 | 并发 | default R | default W | R/W | ra0 R | ra0 W | def/ra0 (R) |
|----|------|----------|----------|-----|-------|-------|-------------|
| D0 | 16384 | 743 | 741 | 1.00 | 1334.3 | 1339.5 | 56% |
| D1 | 512 | 559 | 560 | 1.00 | 863.3 | 863.3 | 65% |
| D2 | 128 | 345 | 346 | 1.00 | 459.5 | 459.5 | 75% |
| D3 | 32 | 213 | 213 | 1.00 | 254.2 | 254.2 | 84% |

（ra0 D1-D3 R/W 为合计/2 估算，01-2b 报告合计值且 R/W=1.0）
（⚠️ 审计修订 2026-07-17：default 值旧系"合并 bw_log × numjobs"外推，已改用 fio `Run status` 聚合行中位数。D1 偏差最大 7%。详见 `doc/deploy-log/bw-statistics-audit.md` §四）

**结论**：
- R/W 均衡（1:1），与 ra0 一致，坐实写口径两配置无差异
- default 随并发降低，与 ra0 差距从 D0 56% 收窄至 D3 84%
- 高并发下预读浪费更显著（后端带宽饱和时放大代价更大）

### 2.3 数据源统一

- `STAGE-SUMMARY-nolimit.md` 已订正：ra0 B 组目录从 `20260714-180604` → `20260715-235631`（01-1 最终版）
- `process-baseline-final.py` 硬编码 235631，与订正后一致

---

## 三、分析与结论

### 3.1 default 预读代价量化

**「default 用带宽换顺序读吞吐」的代价 = 2.01× 读放大**：
- 每 1 MiB 有效随机读，后端需 GET 2.01 MiB
- 多出的 1.01 MiB 是预读拉取但 fio 不会读到的数据
- 在 100GbE 不限速口径下，后端有充裕带宽承担放大；在限速口径下放大会吃满带宽

### 3.2 口径权衡

| 场景 | 推荐口径 | 理由 |
|------|---------|------|
| 随机读为主（AI 训练随机采样） | ra0 | 无放大，有效带宽 +159% |
| 顺序读为主（数据加载/预处理） | default | 预读流水线提升单流吞吐 |
| 混合读写 (randrw) | ra0 | default 仅 ra0 57%，预读浪费严重 |
| 限速口径 | ra0 | 放大会吃满限速带宽 |

**调优基线口径选 default** 的依据（任务书 §〇）：AI 训练「多客户端共享读基础文件」偏顺序/多流读，default 占优。但本测试数据显示：在 32×32 并发的多客户端共享读场景下（01-3 步骤3），default N=4 = 2822 vs ra0 N=4 = 5013，ra0 反而 +78%。**需重新审视口径策略**。

### 3.3 与报告草稿 A 组的数值差异

报告草稿 A 组 randread steady median = 1504（01-1, 07-14 测试）。本测试 steady median = 1115（07-16 测试）。差异 26%。

可能原因：
1. OSD 内部状态变化（两天间 BlueStore 缓存/compaction 状态不同）
2. 01-1 是 fresh volume 首跑（create_on_open 路径可能影响初始缓存行为）
3. 网络状态变化

建议：报告草稿保留 1504（§8.3 口径、已有 bw_log 数据可信），本测试 1115 作为独立读放大诊断参考。若需统一，可重跑 01-1 A 组 randread 复核。

---

## 四、数据可信度校验

| 检查项 | 结果 |
|--------|------|
| Ceph HEALTH 全程 OK | ✅ |
| 3 轮 REPEAT 方差 | randread D0: CV=1.3%, randrw D0: CV=3.0%, 稳定性好 |
| bw_log 稳态中位数 vs fio 平均值 | randread: 1115 vs 1099 (+1.4%), randrw D0: 762 vs 749 (+1.7%) |
| R/W 均衡 | 所有 randrw 档 R/W = 1.00-1.01 ✅ |
| 读放大 GET/fio | 2.01（三轮一致 2.01/2.02/2.01） ✅ |
| 数据源统一 | STAGE-SUMMARY 已订正 ✅ |

---

## 五、后续动作

1. **回填**：将 default 读放大 2.01× + randrw 四档真值回填到 perf-report/01-2、01-2b 报告对照节
2. **口径策略复审**：01-3 多实例数据显示 ra0 N=4 = 5013 远超 default N=4 = 2822，需重新审视「调优基线选 default」是否适用于多客户端随机读场景
3. **报告草稿更新**：A 组 randread 差异（1504 vs 1115）需说明或重跑复核
4. **回填 perf-analysis/01**：§5.1 增 default 列 / §六真值汇总
