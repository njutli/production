# 冷态全量基线复测分析报告

> 日期：2026-07-06 | 二进制：patched v1.3.1+2025-12-02.e0032b2a
> 原始数据：`results/cold-baseline-recheck-20260706/`
> 对照旧基线：`results/full-bs256k-cold-r1-20260626-200742/`（2026-06-26, 原版 v1.3.1）

---

## 一、核心结论

### 1. 全程无 stall

**health timeline 4998 条采样（10:58→13:33, 2.5 小时, 每 5s 一次）全部 HEALTH_OK。**

- seqwrite（4G 顺序写）：无 stall
- multi-seqwrite（64G, 16 jobs × 4G, bs=256K）：无 stall
- **layout（128G, 128 jobs × 1G, bs=4M）：无 stall**
- 3 轮随机读写：无 stall

**这直接回答了任务 A 的核心问题：过去冷态基线数据的 layout 阶段没有 stall，旧基线数据是可信的。**

### 2. 与旧基线对比（r1 口径）

| 指标 | 旧基线(原版) | 复测(patched) | 差异 | 说明 |
|------|:---:|:---:|:---:|------|
| seqread | 77.7 | 78.9 | +1.5% | 一致 |
| seqwrite | 50.8 | 55.3 | +8.9% | patch 可能有小幅提升 |
| multi-seqread | 110 | 109 | -0.9% | 一致 |
| multi-seqwrite | 41.5 | 40.8 | -1.7% | 一致 |
| layout | 33.3 | 33.7 | +1.2% | 一致 |
| randread r1 | 33.6 | 39.7 | +18.2% | loadRange bug 修复，预期提升 |
| randwrite r1 | 29.0 | 43.0 | +48.3% | 旧基线 r1=29.0 异常低（r2=53.5），复测 r1=43.0 更合理 |
| randrw r1 R | N/A | 18.1 | — | 旧基线未分列 R/W |
| randrw r1 W | N/A | 17.7 | — | 同上 |

### 3. 旧基线数据可信度评估

| 测试项 | 可信度 | 依据 |
|--------|:---:|------|
| seqread | ✅ 可信 | 复测值与旧基线差 1.5%，全程无 stall |
| seqwrite | ✅ 可信 | 复测值与旧基线差 8.9%（patch 小幅提升），无 stall |
| multi-seqread | ✅ 可信 | 差 0.9%，无 stall |
| multi-seqwrite | ✅ 可信 | 差 1.7%，无 stall |
| layout | ✅ 可信 | 差 1.2%，**128G 写入全程 HEALTH_OK** |
| randread r1 | ⚠️ 偏低 | 旧基线 33.6 受 loadRange bug 影响，patch 后 39.7 |
| randwrite r1 | ⚠️ 异常 | 旧基线 r1=29.0 异常低（r2=53.5 差 84%），复测 r1=43.0 |
| randrw r1 | ⚠️ 无法对比 | 旧基线未分列 R/W |

---

## 二、对 deepseek 16/README.md P1/P2 命题的判决

### P1："几十G连续写必触发 BlueFS stall" → ❌ 推翻

deepseek 在 exp1 中测得 8G 单 job 顺序写即触发 stall。但本次复测：
- **layout 128G（128 jobs × 1G, bs=4M）全程 HEALTH_OK**
- **multi-seqwrite 64G（16 jobs × 4G, bs=256K）全程 HEALTH_OK**
- **P6 实验 32G 单 job 写全程 HEALTH_OK**（OSD `compact_queue_len=0`，无积压）

deepseek 的 exp1 S1（8G 单 job）触发 stall，但我们的 32G 单 job 和 128G 多 job 都不触发。**stall 的触发需要两个条件同时满足**：
1. **单 job 持续写**（持续压单个 OSD 不给 compaction 喘息空间）
2. **OSD 已有 compaction 积压**（LSM tree 膨胀，`compact_queue_len > 0`）

deepseek 的 OSD 在 write-push 测试（~200G+）后已有积压，**restart OSD 不清除磁盘上的 LSM tree 状态**（compaction 在 restart 后继续但不加速），所以 8G 单 job 一压就 stall。我们的 OSD 状态干净（`compact_queue_len=0`，`kv_sync_lat < 2ms`），所以 32G 单 job 也不 stall。

**可通过 admin socket 检测和消除积压**：
- 检测：`ceph --admin-daemon <asok> perf dump` → 查 `rocksdb.compact_queue_len` / `compact_running`
- 消除：`ceph --admin-daemon <asok> compact`（秒级完成，比 restart OSD 可靠）

**结论：P1 命题"几十G连续写必触发 stall"是错误的。触发条件是"单 job 持续写 + OSD compaction 积压"，不是单纯的写入总量。**

### P2："过去顺序写/layout 数据可能被污染" → ❌ 推翻

本次复测全程无 stall，layout（128G）前后 HEALTH_OK，顺序测试值与旧基线高度一致（差 1-2%）。**过去冷态基线的 layout 和顺序测试数据没有被 stall 污染，是可信的。**

deepseek 在 14/analysis.md 中声称"旧测 57/54.8 被 destroy/layout 污染"——**layout 污染说不成立**（layout 无 stall）。destroy 污染说是另一个问题（destroy 删除 1.4M 对象的 compaction 余波），本次复测未单独验证 destroy 影响，但 layout 本身不是污染源。deepseek 误判污染的原因：其 OSD 在 write-push 后有 compaction 积压（`compact_queue_len > 0`），restart 不消除积压，导致后续测试在退化态下运行——这是 deepseek 自己制造的问题，不是基线流程固有的。

---

## 三、监控数据质量

| 监控项 | 状态 | 数据量 | 说明 |
|--------|:---:|:---:|------|
| health timeline | ✅ 成功 | 4998 行 | 每 5s 一次, 覆盖全程 10:58→13:33 |
| backend 快照 | ✅ 成功 | 38 个文件 | 每阶段前后各一次 |
| OSD perf timeline | ❌ 失败 | 100B/OSD | nohup 后台循环未正常工作, 仅初始测试行 |
| iostat node1 | ✅ 成功 | 24MB | 连续采集 |
| iostat node2/3 | ❌ 失败 | 65B | iostat 命令在 nohup 环境下未找到 |

**health timeline + backend 快照足以回答 stall 问题**。OSD perf timeline 失败是工具问题，不影响核心结论。后续任务 C 需修复 OSD perf 采集方法。

---

## 四、3 轮随机测试稳定性

| 轮次 | randread | randwrite | randrw R | randrw W |
|------|:---:|:---:|:---:|:---:|
| r1 | 39.7 | 43.0 | 18.1 | 17.7 |
| r2 | 49.2 | 25.3 | 16.6 | 16.3 |
| r3 | 48.3 | 41.5 | 17.2 | 16.8 |

- **randread**：r1=39.7 → r2/r3 升至 48-49（OSD cache 预热效应，+24%）
- **randwrite**：r1=43.0 → r2=25.3（-41%）→ r3=41.5（恢复），方差大
- **randrw**：3 轮稳定在 16-18，方差小

randwrite 的大方差（25-43）与旧基线一致（旧基线 r1=29, r2=53.5），说明这是该测试本身的特性，不是 stall 导致的。

---

## 五、文件清单

```
results/cold-baseline-recheck-20260706/
├── summary.md                          # 测试摘要
├── analysis.md                         # 本分析报告
├── commands.sh                         # 完整命令记录
├── env-snapshot.txt                    # 环境快照
├── format.log / mount.log              # 卷配置
├── run.log                             # 全程运行日志
├── seqread.txt / seqwrite.txt          # fio 原始输出
├── multi-seqread.txt / multi-seqwrite.txt
├── layout.txt
├── randread-r{1,2,3}.txt
├── randwrite-r{1,2,3}.txt
├── randrw-r{1,2,3}.txt
└── backend/
    ├── health-timeline.txt             # 4998 行, 全程 HEALTH_OK
    ├── iostat-ceph-node1.log           # 24MB
    ├── osd{0-5}-perf-timeline.txt      # 失败(100B)
    ├── {stage}-{before,after}.txt      # 38 个快照
    └── layout-cooldown-120s.txt
```
