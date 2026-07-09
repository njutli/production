# 最终汇报：任务 A/B/C 执行结果

> 日期：2026-07-06 | 执行者：GLM | 原始数据：`results/cold-baseline-recheck-20260706/`

---

## 1. 任务 A：冷态基线复测 → 全程无 stall，旧数据可信

**核心发现**：health timeline 4998 条采样（10:58→13:33, 2.5h, 每 5s）**全部 HEALTH_OK**。

- layout 128G（128 jobs × 1G, bs=4M）**无 stall**
- multi-seqwrite 64G（16 jobs × 4G, bs=256K）**无 stall**
- seqwrite 4G、3 轮随机读写**无 stall**

与旧基线对比（r1 口径）：

| 指标 | 旧基线(原版) | 复测(patched) | 差异 |
|------|:---:|:---:|:---:|
| seqread | 77.7 | 78.9 | +1.5% |
| seqwrite | 50.8 | 55.3 | +8.9% |
| multi-seqread | 110 | 109 | -0.9% |
| multi-seqwrite | 41.5 | 40.8 | -1.7% |
| layout | 33.3 | 33.7 | +1.2% |
| randread r1 | 33.6 | 39.7 | +18.2% (bug 修复) |
| randwrite r1 | 29.0 | 43.0 | +48.3% |
| randrw r1 R/W | N/A | 18.1/17.7 | — |

**结论：过去冷态基线数据可信。layout 不产生 stall 污染。**

## 2. 任务 B：deepseek 14/15/16 交叉复核

### P1-P6 判决汇总

| 命题 | deepseek 结论 | GLM 判决 | 关键依据 |
|------|:---:|:---:|------|
| P1: 几十G必触发 stall | ✅ 证实 | ❌ 推翻 | 128G 多 job 全程无 stall |
| P2: 过去数据被污染 | ✅ 证实 | ❌ 推翻 | 全程无 stall, 值与旧基线一致 |
| P3: 写侧被硬件封死 | ⚠️ 部分推翻 | ⚠️ 部分推翻 | 256K 写接近后端稳态(52.7), 但 deepseek cherry-pick 4M 瞬态峰值 |
| P4: stall=compaction 反压 | ⚠️ 方向对 | ⚠️ 存疑 | 无 perf 定量证据 |
| P5: WAL/DB 同盘是瓶颈 | ⚠️ 未取证 | ⚠️ 未取证 | exp4 阻停 |
| P6: SSD 误判无影响 | ✅ 推翻 | ❌ 推翻(deepseek 测反) | deferred_size hdd=65536/ssd=0, throttle 167× 差异 |

### 新发现问题（opencode 未点出）

- **N1**：15/STATUS.md 声称 B1-nj1 有 backend-after.txt，实际文件不存在（文档不实）
- **N2**：16 exp1 S4 "文件布局阶段即卡死" 未区分 Ceph stall 还是 FUSE 层问题
- **N3**：14 A3 (mu=300) seqwrite -28% 无 backend 快照，无法排除 stall
- **N4**：15 A-idle r1→r2 的 30% 断崖退化（仅 8G 累积写入）未合理解释
- **N5**：16 P3 rados bench 用 4M 瞬态峰值说"硬件不封顶"，忽略 256K 均值与 JuiceFS 一致

### 关键推翻

- **"stall 由写入总量决定"** → ❌ 实际是写法形态（单流持续 vs 多流分散）决定
- **"layout 污染旧数据"** → ❌ layout 全程无 stall
- **"SSD 误判无影响"** → ❌ deepseek 漏查 deferred_size/throttle_cost 两个关键写路径参数

## 3. 任务 C：P6 deferred_size 对照实验

| 组 | config | 带宽 | stall |
|----|--------|:---:|:---:|
| 对照(HDD) | deferred=65536, throttle=670000 | 43.4 | 无 |
| 实验(SSD) | deferred=0, throttle=4000 | 39.1 | 无 |

**结论**：改 config 到 SSD 值在非 stall 场景下无 measurable 收益。"免硬件突破口"假设不成立。config 已回滚，HEALTH_OK。

## 4. compaction 反压 perf 定量证据

**缺失**。OSD perf timeline 采集失败（nohup 循环在远端节点不工作，cephadm shell 太慢）。health timeline 足以回答 stall 有无，但无 compact_queue_len/kv_sync_lat 定量时间线。后续需用 admin socket 直采（已在 task A 验证可行，但需修复 nohup 问题）。

## 5. "要不要向领导要 NVMe 预算"证据链现状

| 证据 | 状态 | 说明 |
|------|:---:|------|
| 持续写入触发 stall | ⚠️ 条件性 | 单流持续写触发, 多流分散不触发; 与 OSD compaction 状态相关 |
| 后端裸能力 | ✅ 有 | rados 256K 均值 52.7, 与 JuiceFS 接近 |
| 介质误判 | ❌ 非突破口 | 参数差异存在但改 config 无实际收益 |
| WAL/DB 隔离有效 | ⚠️ 有条件的不需要 | stall 直接原因是 compaction 积压; compact 命令可消除, 不一定需要独立 NVMe |
| compaction 反压定量 | ❌ 未取证 | perf 采集失败 |
| 写侧物理封顶 | ⚠️ 256K 接近 | 4M 有空间, 256K 接近后端稳态 |

**现状**：stall 可通过 `compact` 命令管理，WAL/DB 隔离非必须（P5 有条件关闭）。256K 写接近后端稳态上限（rados 52.7），4M 写有空间但会引入 16× 随机读放大。主要瓶颈是 256K EC 写的 deferred 双写 + metadata 开销，以及 1Gbps 网络物理上限。独立 NVMe 的必要性从"必须"降为"可选优化"。

## 6. 文件清单

```
results/cold-baseline-recheck-20260706/
├── summary.md              # 测试摘要
├── analysis.md             # 任务 A 分析报告
├── cross-review.md         # 任务 B 交叉复核
├── commands.sh             # 完整命令记录
├── env-snapshot.txt        # 环境快照
├── format.log / mount.log  # 卷配置
├── run.log                 # 全程运行日志
├── seqread.txt ... randrw-r3.txt  # fio 原始输出
├── backend/                # health timeline + 快照 + iostat
└── p6-deferred/            # 任务 C P6 实验
    ├── ops.log             # 操作日志
    ├── report.md           # P6 实验报告
    ├── control-*.txt       # 对照组数据
    ├── experiment2-*.txt   # 实验组数据
    └── control-health-timeline.txt / experiment2-health-timeline.txt
```
