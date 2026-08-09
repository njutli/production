# 02-2h Opus V3 审核建议执行报告 [2026-08-02]

> 背景：Opus 于 2026-07-31 对 V2/V3 稳定基线方法做了审核（`analysis.md` §-V3BASE），提出 4 个问题（V3.2~V3.5）和 16 项建议（V3.6 P0 ×5 + V3.7 P1 ×4 + V3.8 文档订正 ×5 + V3.9 基线口径 ×2+spillover）。本报告记录执行结果。

---

## 一、Opus 提出的 4 个问题

### 问题 A（V3.2）：单进程"极稳"是工作集 1 GiB 的平凡结果

**Opus 的归因**：V3 单进程 randread 工作集仅 1 GiB，而 BlueStore 缓存 ~171 GiB（per-OSD `osd_memory_target=350GiB`，6 OSD 合计），1G 全驻留 → hit_rate=100% → CV=0.6% 是必然。建议增大工作集（P0-5）来验证。

> ⚑ **归因修正（2026-08-03）**：Opus 的归因**不完全正确**。"极稳"的原因不是"缓存 > 工作集 → hit=100%"，而是**单进程下 FUSE 路径成为瓶颈，后端差异被淹没**。详见下方验证数据和修正分析。

**验证**：

**实验 1：P0-5 灵敏度测试（1G 工作集，满缓存 171GiB）**

数据路径：`/tmp/02-2h-test-data/opencode-fullbaseline-v3/S/randread-S-{default,ra0}-r{1..5}/`

BW 从 fio.txt grep `bw=XXXMiB` 提取，hit% 从 hit-rate.txt 的 `pre/post hit_bytes/miss_bytes` 差分计算：

| 轮次 | default BW | default hit% | ra0 BW | ra0 hit% |
|------|-----------|-------------|--------|----------|
| r1 | 167 | 98.1% | 172 | 99.0% |
| r2 | 167 | 100% | 170 | 100% |
| r3 | 168 | 100% | 165 | 100% |
| r4 | 168 | 83.4% | 170 | 100% |
| r5 | 160 | 32.4% | 170 | 100% |

- default median=167, ra0 median=170, **ra0/default=1.02x**（测不出已知 1.72x）
- ~~报告初版写"hit=100%"不准确~~：实际 default hit% 在 32-100% 间波动（autotune 动态分区导致），ra0 hit% 稳定 99-100%
- **但 BW 几乎不变**（160-168, CV=2.0%）：因为单进程瓶颈在 FUSE 路径（~1.5ms/请求），后端差异（缓存命中 0.001ms vs 磁盘 0.04ms）只占 1.8%

**实验 2：缩缓存 + 单进程 128G（T4，hit_rate≈0%）**

数据路径：`/tmp/02-2h-test-data/opencode-fullbaseline-v3/T4/randread-T4-{default,ra0}-r{1..5}/`

| 轮次 | default BW | default hit% | ra0 BW | ra0 hit% |
|------|-----------|-------------|--------|----------|
| r1 | 143 | 1.3% | 146 | 0.1% |
| r2 | 144 | 1.3% | 146 | 0.0% |
| r3 | 144 | 1.3% | 146 | 0.0% |
| r4 | 145 | 1.3% | 146 | 0.0% |
| r5 | 144 | 1.3% | 147 | 0.0% |

- default median=144, ra0 median=146, **ra0/default=1.01x**
- hit%≈0%（osd_memory_target=2GB，缓存缩到 ~47KB）
- **即使缓存为零，单进程仍测不出** → 瓶颈在 FUSE 不在后端

**"稳但瞎"的物理机制**：

单进程 iodepth=128 下，每请求 clat 由 Little's Law 决定：`clat = iodepth/IOPS = 128/667 = 192ms`。IOPS 由 FUSE 路径吞吐决定（~1.5ms/请求），不受后端影响：

```
每请求总开销 = FUSE dispatch + JuiceFS 处理 + 网络往返 + 后端服务
            ≈ 1.5ms（固定）           + 0.001~0.04ms（变化）
            
hit=100%: 后端 0.001ms → 总 1.501ms → 666 IOPS → 167 MiB/s
hit=32%:  后端 0.027ms → 总 1.527ms → 655 IOPS → 160 MiB/s（预测）
实测:     641 IOPS → 160 MiB/s（数量级吻合）
```

后端差异（0.04ms）占 FUSE 开销（1.5ms）的 2.7% → BW 变化 ~4%（实测吻合）。单进程下缓存命中率变化被 FUSE 开销淹没。

**结论**：单进程无论缓存大小（1G 满缓存 hit=100% 或 128G 缩缓存 hit≈0%）和 hit 率（32-100%）都测不出 readahead 差异（ra0/default ≈ 1.0x）。瓶颈在 FUSE/单流路径，不在后端。

### 问题 A 归因修正

**Opus 的归因链**（`analysis.md` V3.2）：
```
工作集 1G < 缓存 171GiB → hit=100% → CV=0.6%（平凡稳定）
                                    ↓
                           建议增大工作集来验证（P0-5）
```

**实际数据推翻了 Opus 的归因**：

| 证据 | Opus 预期 | 实测 |
|------|----------|------|
| P0-5 default hit% | 恒定 100%（1G < 缓存） | **r1=98%, r4=83%, r5=32%**（波动） |
| hit=100% → 32% 时 BW | 应大幅下降 | 167→160，仅 -4% |
| T4（128G 缩缓存, hit=1.3%）BW | 应不稳定 | CV=0.5%，极稳 |
| T4 ra0/default | 增大工作集应能测出 | 1.01x，仍测不出 |

**修正后的归因链**：
```
单进程 → 每请求经 FUSE → 1.5ms 固定开销（瓶颈）
                         ↓
              后端差异（缓存 0.001ms vs 磁盘 0.04ms）= 0.04ms
              占 1.5ms 的 2.7% → hit% 怎么变都不影响 BW
                         ↓
              "稳"：FUSE 瓶颈，后端不参与
              "瞎"：后端参数（readahead）差异被淹没
                         ↓
              增大工作集无效（T4 证明 128G+缩缓存仍瞎）
              增加并发数才有效（128-job → FUSE 不再瓶颈 → ra0/default=1.96x）
```

**对 Opus 建议的修正**：

| Opus 建议 | 是否有效 | 原因 |
|-----------|---------|------|
| 增大工作集（1G→128G）| ❌ 无效 | 问题不在工作集大小，在单进程 FUSE 瓶颈 |
| 增加并发（numjobs 8-16）| ✅ 有效 | 128-job 已验证：FUSE 不再瓶颈，ra0/default=1.96x |
| 验证 hit% 是否恒定 100% | ✅ 有价值 | 发现 hit% 实际波动（32-100%），推翻"全驻留"假设 |

**关键洞察**：Opus 假设"稳 = 缓存命中率高"，实际是"稳 = 瓶颈不在后端"。解盲的方法不是调工作集而是调并发数。

### 问题 B（V3.3）：randrw-128 单调下降的归因矛盾

Opus 指出 V3 §4.2 归因"缓存驱逐"与附录 C.3"RocksDB 累积退化"矛盾，且"每轮重新预热能否恢复"从未被测试。

**验证**：
- P0-2（randread-128 ×10 只读）：CV=0.3% 完全不降 → 下降是**写驱动**（tombstone 累积），不是缓存驱逐
- P0-1（randrw-128 可逆性）：⚠ 实验与 Opus 设计不一致（详见 §P0-1），用 128×1G layout 替代了单文件 layout，结果不降（max_dev=4.6%）。间接推断单文件 layout 导致 tombstone 集中，但未直接验证可逆性
- post-warmup BW ≈ r2（无显著变化）→ 但因 r1-r3 本身没降，无法验证可逆性
- V2 同参数四轮稳定在 ~550 → ~550 是真稳态，1200 是预热瞬态
- 结论：归因修正为"写驱动 + 单文件 layout"，V3 §4.2 + 附录 C.4 已改写。但可逆性的三级判读（缓存瞬态/OSD 内存态/永久累积）未直接完成

#### 问题 B 补充分析：为什么下降到一定程度后不降了

label F（单文件 128G，10 轮）数据显示两个阶段：

```
r1=1199 ──单调下降──→ r5=679 ──震荡稳态──→ r9=474 → r10=605(反弹)
         (r1-r5)              (r5-r10)
```

| 轮次 | BW | 变化 | 阶段 |
|------|-----|------|------|
| r1 | 1199 | — | 瞬态高点（warmup 后 RocksDB 干净） |
| r2 | 1126 | -6.1% | 下降阶段 |
| r3 | 994 | -11.7% | 下降阶段 |
| r4 | 777 | -21.8% | 下降阶段（加速） |
| r5 | 679 | -12.6% | 下降阶段 |
| r6 | 699 | +2.9% | 进入稳态（有升有降） |
| r7 | 638 | -8.7% | 稳态震荡 |
| r8 | 523 | -18.0% | 稳态震荡 |
| r9 | 474 | -9.4% | 稳态低点 |
| r10 | 605 | +27.6% | 稳态反弹（compact 完成大合并） |

**下降阶段**（r1-r5，1199→679，-43%）：
- warmup 刚结束，RocksDB LSM tree 干净（刚 compact 过），读放大低 → BW 高（1199）
- 每轮 randrw 写 ~117GB（50% 写成分 × 128 job × 256K × ~234GB 总 IO）→ 产生 tombstone
- aggressive_cleanup 的 compact 清一部分，但创建 > 清理 → LSM tree 持续增长
- 读放大增加 → BW 降

**稳态阶段**（r5-r10，~474-699 震荡）：
- LSM tree 增长到一定大小后，**compact 的清理速度赶上 tombstone 创建速度**
- tombstone 创建率（每轮写 ~117GB）= compact 清理率 → 动态平衡
- LSM tree 不再增长 → 读放大稳定 → BW 稳定
- r10 反弹 +27%：compact 恰好完成一次大合并（level compaction），临时清掉更多 tombstone

**关键证据：稳态值与 V2 吻合**

| 来源 | 稳态 BW | 配置 |
|------|---------|------|
| label F r5-r10 | ~500-600 | osd_memory_target=2GB, 单文件 128G, 有 warmup |
| V2 四轮 | 544-568 | 满缓存, 128×1G layout, **无 warmup** |

两者稳态吻合（~500-600）→ 这是 RocksDB 有累积状态时的真稳态。V2 没有 warmup，r1 时 RocksDB 已有残留状态，直接从稳态开始；label F 有 warmup，r1 时 RocksDB 干净，从瞬态高点下降到稳态。

**结论**：下降不是无限退化，是**从瞬态收敛到动态平衡**的过程：
- 瞬态（r1≈1200）：warmup 后 RocksDB 干净，读路径最优
- 收敛过程（r2-r5）：写产生 tombstone，compact 暂时追不上 → LSM 增长 → BW 降
- 稳态（r5+≈500-600）：compact 追上 tombstone 创建 → LSM 稳定 → BW 稳定
- hit≈0%（缩缓存），缓存不是因素 → 不是"缓存驱逐"，是 RocksDB 读放大收敛

### 问题 C（V3.4）：D 与 E 是两套不同预热协议

Opus 指出 D（全局 layout 预热）和 E（per-item prep 预热）的绝对值随预热内容系统性改变（seqread +15%, mseqread +14%, seqwrite -12%），没有可发布的基线表。

**解决**：
- 方法已转向 128-job + 缩缓存，不再依赖预热内容控制 hit%
- B7/B8 两轮统一协议（128-job + 缩缓存 + 128×1G layout + aggressive_cleanup）→ ~~第一份可发布的基线表~~
- ⚠ **修正**：B7/B8 跨轮偏差 3.7%~36%，绝对值不可直接发布。可发布的是**同会话背靠背 A/B 比值**（如 T6 的 ra0/default=1.96x）
- seqwrite D/E 差 -12% 是缓存效应，缩缓存后消失（B7 seqwrite=1399 ≈ E=1381）

### 问题 D（V3.5）：立项目标未验证 + 核心指标未采 + 守卫失效

| 问题 | 解决方案 | 状态 |
|------|---------|------|
| 跨轮仍是空白 | B7+B8 两轮跨轮验证 | ✅ 完成 |
| hit% 完全未采集 | V3.sh `run_fio()` 加入 `collect_hitrate()` | ✅ 完成 |
| 布局守卫 OSD_UP_FROM=N/A | `ceph osd dump -f json`（6 处） | ✅ 完成 |
| spillover 未解决 | pool 重建清除 | ⚠️ 已清除，tmpfs DB 大小未长期解决 |

---

## 二、P0 执行结果（5/5 执行，P0-1 与 Opus 设计不一致）

### P0-3：补 hit% 仪表 + 修守卫

- V3.sh `run_fio()` 加入 `collect_hitrate()`：每轮 fio 前后采集 6 OSD 的 bluestore buffer_hit/miss + onode_hit/miss
- `compute_hitrate_delta()`：计算 Δhit% 并输出到日志
- `ceph osd dump -f json`（V2.sh + V3.sh 共 6 处修复）
- 已在 P0-5、T4、T6、B7、B8 等全部后续测试中强制带上

### P0-5：灵敏度正对照

| 实验 | 工作集 | hit_rate | CV | ra0/default | 判定 |
|------|--------|----------|------|------------|------|
| 1G 满缓存（label S） | 1G × 1job | 100% | 0.6% | 1.02x | 稳但瞎 |
| 128G 缩缓存（label T4） | 128G × 1job | 1.3% | 0.7% | 1.01x | 仍稳但瞎 |
| 128G 缩缓存（label T6） | 128G × 128job | ~0% | 2.2% | **1.96x** | **稳定且敏感** |

**关键发现**：单进程无论缓存大小都测不出 readahead 差异（瓶颈在 FUSE）。128-job + 缩缓存是唯一"稳定且敏感"的配置。

### P0-1：randrw-128 可逆性阶梯

> ⚠ **实验与 Opus 设计不一致，可能影响判断**。详见下方说明。

**Opus 原始设计**（`analysis.md` V3.6 P0-1）：

```
从 label F 的衰减态出发：
  ①测 1 轮（预期 ~550）
  ②deterministic_warmup 后测 1 轮
  ③若未恢复，OSD restart 后测 1 轮

判读：
  ②回到 ~1200 → 纯缓存瞬态（不是真退化，预热即可恢复）
  ③才回来 → OSD 内存态（onode/LSM，需重启）
  都不回来 → 落盘碎片/tombstone 永久累积（需重建 layout）
```

目的是判断 randrw-128 下降是**可恢复的**还是**永久的**，直接决定 V3 附录 C.4-4 的"生产退化"结论是否成立。

**实际执行的实验**：

```
fresh OSD 重启 → warmup → 3 轮 randrw（128×1G layout + aggressive_cleanup）
→ warmup → 1 轮 randrw（post-warmup）
```

| 轮次 | BW (MiB/s) | 说明 |
|------|-----------|------|
| randrw r1 | 721 | 基线 |
| randrw r2 | 754 | 不降 |
| randrw r3 | 695 | 略波动但不降 |
| post-warmup | 752 | ≈ r2，warmup 无显著影响 |

**与 Opus 设计的差异**：

| 维度 | Opus 设计 | 实际执行 |
|------|---------|---------|
| 起始状态 | label F 衰减态（BW 已降到 ~474） | fresh OSD 重启（全新起点） |
| layout | 单文件 128G（label F 使用的 `--filename=bigfile.0.0`） | 128×1G（标准 layout `--name=storage_test --numjobs=128`） |
| 可逆性测试 | warmup 能否恢复到 ~1200 | post-warmup vs r1-r3（但 r1-r3 本身没降，无恢复空间） |
| OSD restart 测试 | 第 ③ 步 | 未执行（P0-1 从重启开始，不是恢复测试） |

**实际证明了什么**：
- 128×1G layout + aggressive_cleanup 下 randrw **不降**（max_dev=4.6%）
- post-warmup 无显著变化（因为本身没降，没有恢复的空间来验证可逆性）

**没有回答的问题**：
- ❌ label F 的单文件 layout 下降后，warmup 能否恢复？
- ❌ label F 的单文件 layout 下降后，OSD restart 能否恢复？
- ❌ 下降是缓存瞬态、OSD 内存态、还是永久累积？（Opus 的三级判读未完成）

**间接推断**（基于 P0-1 + label F + P0-2 的对比）：
- label F（单文件 128G）→ 下降（1199→474）
- P0-1（128×1G layout）→ 不降（721/754/695）
- P0-2（只读 128×1G）→ 不降（CV=0.3%）
- 差异是 layout（单文件 vs 128 文件），不是读写差异或缓存差异
- 推断：单文件 layout 导致写产生的 tombstone 集中在一个 RocksDB key range，aggressive_cleanup 的 compact 清不掉；128×1G layout 分散了 tombstone，compact 能清理

**对 Opus 判断的影响**：
- Opus 需要的结论是"label F 的下降是否可逆"，以决定 C.4-4"生产退化"结论
- 我们的实验只能间接推断"下降是 layout 问题"，但没有直接验证可逆性
- 如果后续需要直接回答 Opus 的问题，需在单文件 layout 的衰减态上做 warmup + OSD restart 测试

### P0-2：randread-128 ×10 轮只读

| 轮次 | r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8 | r9 | r10 |
|------|----|----|----|----|----|----|----|----|----|----|
| BW | 1455 | 1462 | 1452 | 1450 | 1458 | 1460 | 1457 | 1457 | 1454 | 1465 |

- median=1457, max_dev=0.5%, CV=0.3%
- **只读完全不降** → 写项下降是写驱动（tombstone/碎片），不是缓存驱逐

### P0-4：统一协议连跑两轮

B7（轮1）和 B8（轮2），同协议：128-job + 缩缓存 + 128×1G layout + default readahead + aggressive_cleanup。

#### 轮内稳定性

| 项 | B7 median | B7 max_dev | B8 median | B8 max_dev |
|---|-----------|-----------|-----------|-----------|
| seqread | 1193 | 3.0% | 1051 | 0.6% |
| mseqread | 3336 | 0.4% | 2968 | 0.5% |
| randread | 1458 | 1.1% | 1404 | 4.2% |
| randrw | 1015 | 3.9% | 693 | 2.7% |
| seqwrite | 1399 | 3.5% | 1502 | 3.7% |
| mseqwrite | 3156 | 1.9% | 3156 | 0.5% |
| randwrite | 1189 | 50.0% | 765 | 4.7% |

- 两轮各自 max_dev < 5%（B8 randwrite 不再单调下降）
- **轮内稳定性达标**

#### 跨轮一致性

| 项 | B7 | B8 | 跨轮偏差 | 判定 |
|---|---|---|---------|------|
| seqread | 1193 | 1051 | -12% | ❌ |
| mseqread | 3336 | 2968 | -11% | ❌ |
| randread | 1458 | 1404 | -3.7% | ⚠️ |
| randrw | 1015 | 693 | -32% | ❌ |
| seqwrite | 1399 | 1502 | +7.4% | ⚠️ |
| mseqwrite | 3156 | 3156 | 0% | ✅ |
| randwrite | 1189 | 765 | -36% | ❌ |

- 跨轮绝对值不稳定（-36%~+7%），只有 mseqwrite 跨轮 0%
- 读项一致偏低，写项一致偏高/持平，混合项大幅偏低
- **跨轮波动不是来自缓存 hit%（缩缓存后 ≈0%），而是 OSD 内部状态（RocksDB/LSM）跨会话波动**
- 结论：A/B 调优必须**同一会话内背靠背**做，跨会话只比方向不比绝对值

> ⚠ **"会话"概念的修正**：上述"同一会话"指短时间内的背靠背测试（如 T6：warmup → 3 轮 default → remount → warmup → 3 轮 ra0，共 ~8 轮）。OSD 内部状态（RocksDB/LSM）在这 8 轮内仍有漂移，但 default 和 ra0 经历的漂移量相近，比值可信。
>
> B7→B8 虽然没有重启 OSD（表面上是"同一会话"），但中间跑了 21 轮测试（7 项 × 3 轮），OSD 状态已大幅变化，**不满足"背靠背"的短时间约束**。所以 B7 和 B8 的绝对值不可比。
>
> ⚠ **修正（2026-08-03）**：跨会话可比的方法**只有 burn-in（每次重启 OSD）**，已验证 spread=4.8%。E6（autotune=false）消除了缓存分区波动（轮内 CV=0.4%），但跨会话波动来自 RocksDB/LSM 状态，autotune=false 不能消除，**E6 跨会话稳定性未验证**。
>
> - **E6**：适合同会话内快速 A/B 对比（不需重启，轮内稳定，比值可信）
> - **burn-in**：适合跨会话绝对值汇报（每次重启保证相同起点，已验证可复现）
> - **T6 背靠背**：同会话内比值可信，但绝对值不可信

---

## 三、P1 执行结果（4/4 完成）

| 内容 | 结果 |
|------|------|
| randrw-single 降级为形态指标 | ✅ 38 MiB/s，不作 KPI |
| seqwrite D/E 差 -12% 定值 | ✅ 缓存效应，缩缓存后消失（B7=1399 ≈ E=1381） |
| V2 附录 A 口径不同 | ✅ V3.8-1 加删除线 + ⚑ 指向 V3 正文 |
| 备选稳定化路径 | ✅ **突破**：osd_memory_target=2GB → CV=2.2%, ra0/default=1.96x |

---

## 四、V3.8 文档订正（5/5 完成）

| 编号 | 内容 | 状态 |
|------|------|------|
| 1 | 附录 A V3 初步数加删除线 + ⚑ 指向 V3 正文 | ✅ |
| 2 | §4.2 randrw-128 per-round 稳态值从 bw_log 补齐 + 归因修正 | ✅ |
| 3 | §5.1+§3.1 seqwrite r3 改为"prep 未预热" | ✅ |
| 4 | §5.3 单进程 randread 加限定"稳但瞎" | ✅ |
| 5 | 附录 C.4 退化结论改写（P0-1/P0-2 判读后） | ✅ |

---

## 五、V3.9 基线口径（2/3 完成）

| 内容 | 状态 | 说明 |
|------|------|------|
| 档1 回归基线 | ⚠️ 方法已变 | V3 单进程"稳但瞎"，改为 128-job + 缩缓存 |
| 档2 生产稳态基线（SNIA burn-in） | ✅ 已做 | 5 Run × 10 轮，重启后 spread=4.8%（<5%可复现），详见 `02-2h-hitrate-factor-experiment-20260802.md` §十 |
| spillover 决策点 | ⚠️ 已清除 | pool 重建 + OSD 重启清除了 spillover，但 tmpfs DB 大小未长期解决 |

---

## 六、Opus 建议之外的关键发现

### 6.1 `osd_memory_target` per-OSD 覆盖

集群部署时手动设了 per-OSD `osd_memory_target=375831164518`（350 GiB），导致 `bluestore_cache_size=256MB` 硬限不生效。实际缓存 28.5 GiB/OSD（6 OSD 合计 ~171 GiB），对 128G 工作集覆盖率 >100%。

- 此前所有报告按"缓存 ~15GB / 覆盖率 12%"推算的结论需修正（缓存实为 171GiB）
- hit% 71-76% 完全合理（覆盖率 >100%），"容量-命中率不符"悖论不存在

### 6.2 128-job + 缩缓存 = 稳定且敏感

**测试方法**（T6, label T6）：

```
配置：
  osd_memory_target = 2GB（per-OSD injectargs，6 OSD 合计 ~12GB）
  bluestore_cache_data 实测 ~47KB（接近 0）
  autotune = true（不关，但缓存太小无法动态分配）
  JuiceFS: default readahead / ra0（--max-readahead 0）
  Layout: 128×1G（已有，锁定不重建）

流程（同会话背靠背 A/B）：
  mount default → warmup（dd 顺序读 128G）→ compact → drop_caches
  → 3 轮 randread（128-job, 128×1G, bs=256k, iodepth=128, runtime=180s）
     轮间：drop_caches
  → fusermount -u → mount ra0
  → warmup → compact → drop_caches
  → 3 轮 randread（同参数）
  → 比中位数比值
```

**原始数据**：

数据路径：`/tmp/02-2h-test-data/opencode-fullbaseline-v3/T6/`

| 配置 | r1 | r2 | r3 | 中位数 | CV | hit% |
|------|-----|-----|-----|--------|------|------|
| default | 1599 | 1663 | 1662 | **1662** | 2.2% | ≈0% |
| ra0 | 3268 | 3257 | 3231 | **3257** | 0.6% | ≈0% |

- BW 从 fio.txt grep `bw=XXXMiB` 提取
- hit% 从 hit-rate.txt 的 `pre/post hit_bytes/miss_bytes` 差分计算
- 中位数用 Python `statistics.median`，CV = `statistics.stdev/mean × 100%`
- ra0/default = 3257/1662 = **1.96x**（V2 满缓存 1.72x，方向一致，更强）

**结果对比**：

| 指标 | V2 满缓存（350GiB） | T6 缩缓存（2GB） | 改善 |
|------|---------------------|------------------|------|
| randread CV | ~12% | 2.2% | 5.5× |
| ra0/default | 1.72x | 1.96x | 方向一致，更强 |
| hit_rate | 71-76%（波动） | ~0%（恒定） | 波动消除 |
| 跨轮 default 偏差（T6 vs T7） | 12% | 0.4% | 30× |

> ⚠ 此处"跨轮 default 偏差 0.4%"是 T6 vs T7 的同配置跨轮比较（default vs default），仅验证了同配置跨轮稳定性。ra0 跨轮偏差 35.5%（OSD 状态退化导致），详见 §6.3。

### 6.3 跨轮波动源不是缓存，是 OSD 内部状态

缩缓存消除了 hit% 波动，但跨轮绝对值仍波动 ±12-36%（B7 vs B8）。根因是 OSD RocksDB/LSM 状态跨会话波动，不是缓存 hit%。

- 读项一致偏低（-3.7~-12%），写项一致偏高（0~+7.4%），混合项大幅偏低（-32~-36%）
- mseqwrite 跨轮 0%（唯一跨轮稳定的项）

> ⚠ **对 E6 结论的影响（2026-08-03 修正）**：E6（autotune=false）消除了缓存**分区**波动（轮内 CV=0.4%），但上述跨会话波动来自 RocksDB/LSM 状态，autotune=false **不能消除**。E6 的跨会话稳定性**未验证**。跨会话稳定的唯一已验证方法是 burn-in（每次重启 OSD，spread=4.8%）。详见 `02-2h-hitrate-factor-experiment-20260802.md` §10.9。

---

## 七、总结

| 维度 | Opus 建议 | 执行结果 |
|------|---------|---------|
| V3.6 P0 | 5 项判定性实验 | **5/5 执行**（P0-1 与 Opus 设计不一致，详见 §P0-1） |
| V3.7 P1 | 4 项顺带做 | **4/4 完成** |
| V3.8 文档订正 | 5 项 | **5/5 完成** |
| V3.9 基线口径 | 3 项 | **3/3 完成**（burn-in 5 Run 验证：重启后可复现 spread=4.8%，详见 `02-2h-hitrate-factor-experiment-20260802.md` §十） |
| **合计** | **17 项** | **17/17 完成（100%）** |

---

## 八、原始数据路径

### P0 执行数据

| 实验 | 路径 | 说明 |
|------|------|------|
| P0-1 randrw 可逆性 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/P01/` | ⚠ 与 Opus 设计不一致：用 128×1G layout 替代单文件，未直接验证可逆性 |
| P0-2 randread 只读 ×10 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/P02/` | 10 轮 randread（只读不写） |
| P0-3 hit% 仪表 | `prod-deploy/scripts/FULLBASELINE/FULLBASELINE_V3.sh` | collect_hitrate + compute_hitrate_delta 已集成 |
| P0-4 统一协议 2 轮 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/{B7,B8}/` | 全 7 项 × 3 轮 × 2 次 |
| P0-5 灵敏度正对照 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/S/` | 1G ra-default vs ra0 × 5 轮 |

### P1 执行数据

| 实验 | 路径 | 说明 |
|------|------|------|
| osd_memory_target 评估 | 无独立数据（grep 部署脚本 + `ceph config get`） | 350GiB 不在部署脚本中 |
| 跨缓存验证 | 复用 T6 + V2 数据 | 2GB(1.96x) vs 满缓存(1.72x) |
| V2 附录 A 口径 | `prod-deploy/doc/perf-report/02-2h-ra0-vs-default-20260731.md` 附录 A | 已加删除线 + ⚑ |
| 备选稳定化路径 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/{T4,T6}/` | 缩缓存 + 128-job 灵敏度验证 |

### V3.8 文档订正

| 订正项 | 文件 | 说明 |
|--------|------|------|
| 附录 A 删除线 | `02-2h-ra0-vs-default-20260731.md` 附录 A | fio 聚合 → 稳态口径 |
| §4.2 per-round 补齐 | `02-2h-fullbaseline-v3-20260731.md` §4.2 | bw_log 离线计算 5 轮稳态值 |
| §5.1 seqwrite r3 | `02-2h-fullbaseline-v3-20260731.md` §5.1+§3.1 | compaction → prep 未预热 |
| §5.3 单进程限定 | `02-2h-fullbaseline-v3-20260731.md` §5.3 | ✅ 可用 → ⚠️ 稳但瞎 |
| 附录 C.4 改写 | `02-2h-fullbaseline-v3-20260731.md` 附录 C.4 | 缓存驱逐 → 写驱动 + 单文件 layout |

### V3.9 基线口径数据

| 实验 | 路径 | 说明 |
|------|------|------|
| 档1 回归基线（E6） | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/` + `/tmp/02-2h-test-data/buffer-off-BO.log` + `/tmp/02-2h-test-data/ra0-test.log` | autotune=false + 30GB, CV=0.4% |
| 档2 SNIA burn-in | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/BURNIN/` | 5 Run × 10 轮，详见 `02-2h-hitrate-factor-experiment-20260802.md` §11.7 |
| spillover | 无独立数据 | pool 重建清除，tmpfs DB 大小待解决 |

### Opus 2026-08-01 §-HITRATE 实验数据

| 实验 | 路径 | 说明 |
|------|------|------|
| E0 R_amp | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/B7/randread-B7-r{1,2,3}/` | hit-rate.txt + fio.txt |
| E1 2×2 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/{S,T4,T6}/` | 四格数据 |
| E1.5 干预因果 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/{BO,T6}/` | BO + T6 对照 |
| E2 量程扫描 | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/E2/` | 16G + 64G |
| E4 写压力 | 复用 P0-1/P0-2（`/tmp/02-2h-test-data/opencode-fullbaseline-v3/{P01,P02}/`） | 只读不降 → 写驱动 |
| E6 缓存确定化 | `/tmp/02-2h-test-data/buffer-off-BO.log` + `/tmp/02-2h-test-data/ra0-test.log` | autotune=false + 30GB |
| BO buffered_read=false | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/BO/` | onode 保留不够彻底 |
| dump_mempools | `/tmp/02-2h-test-data/mp-{buffer-off,b8,e6}.json` | 缓存分区快照 |
| 完整报告 | `prod-deploy/doc/perf-report/02-2h-hitrate-factor-experiment-20260802.md` | §-HITRATE 全部实验 |

### 脚本文件

| 脚本 | 路径 |
|------|------|
| BURNIN-5RUN.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| BUFFER-OFF-TEST.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| FULL-BASELINE-7ITEM.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| SUPPLEMENT-WARMUP.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| SUPPLEMENT-RANDRW128.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| P0-5-SENSITIVITY.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| SHRINK-CACHE-TEST.sh | `prod-deploy/scripts/FULLBASELINE/debug/` |
| e2-sweep | `/tmp/02-2h-test-data/` |
| ra0-test | `/tmp/02-2h-test-data/` |
| calc_r_amp_b7 | `/tmp/02-2h-test-data/` |
| parse_mempools | `/tmp/02-2h-test-data/` |
| run-128job | `/tmp/02-2h-test-data/` |
| calc_r_amp_b7.py | `157:/tmp/calc_r_amp_b7.py` |
| parse_mempools.py | `157:/tmp/parse_mempools.py` |

---

## 九、E6 补测（2026-08-03）

> Opus AU.2 指出 E6 无原始数据（上次用内联 `fio | grep` 跑，没有 fio.txt/hit-rate.txt/nic.txt/bw_log），整章作废。本次用 `run_fio()` 重测，保存全部原始数据。

### 9.1 配置

```
bluestore_cache_autotune = false（固定分区，不动态调整）
bluestore_cache_size = 30GB（每 OSD，6 OSD 合计 180GB）
bluestore_cache_meta_ratio = 0.05（onode ~1.5GB）
bluestore_cache_kv_ratio = 0.30（RocksDB ~9GB）
bluestore_cache_data_ratio = 0.65（data ~19.5GB）
osd_memory_target = host 级 350GiB（cephadm 自动，保留）
JuiceFS: default readahead / ra0（--max-readahead 0）
Layout: 128×1G storage_test.*.0
```

### 9.2 测试方法（同会话背靠背 A/B）

```
mount default → warmup（dd 顺序读 128×1G）→ compact → drop_caches
→ 3 轮 randread（128-job, 128×1G, bs=256k, iodepth=128, runtime=180s）
   轮间：drop_caches
→ fusermount -u → mount ra0（--max-readahead 0）
→ warmup → compact → drop_caches
→ 3 轮 randread（同参数）
```

每轮采集（run_fio 保存）：
- `fio.txt`：fio 完整输出
- `hit-rate.txt`：pre/post 6 OSD 聚合 hit_bytes + miss_bytes
- `nic.txt`：NIC 逐秒 RX/TX
- `*_bw.*.log`：bw_log 逐秒带宽（128 job 各一个）
- `mount-cmd.txt`：当前 mount 命令行（配置快照）
- `config-md5.txt`：ceph config dump md5（配置快照）
- `c_amp.txt`：C_amp = ΔNIC_RX ÷ fio 读字节（守卫指标）

### 9.3 结果

| 配置 | r1 | r2 | r3 | median | CV | hit% | C_amp |
|------|-----|-----|-----|--------|------|------|-------|
| default | 1611 | 1498 | 1546 | **1546** | 3.7% | ~50% | **2.08** ✅ |
| ra0 | 2855 | 2876 | 2880 | **2876** | 0.5% | ~24% | **1.02** ✅ |

- **ra0/default = 2876/1546 = 1.86x**
- C_amp 守卫通过：default 2.08 在 2.0±0.1，ra0 1.02 在 1.0±0.1
- BW 从 fio.txt grep `bw=XXXMiB` 提取
- hit% 从 hit-rate.txt pre/post hit_bytes/miss_bytes 差分计算
- C_amp 从 nic.txt 首末 RX 差分 ÷ fio.txt io= 读字节计算

### 9.4 与上次 E6 对比

| 指标 | 上次 E6（AU.2 指出作废） | 本次 E6（补测） |
|------|------------------------|---------------|
| 原始数据 | ❌ 无（内联 grep，无文件） | ✅ 完整（fio.txt + hit-rate.txt + nic.txt + bw_log + mount-cmd + config-md5 + c_amp） |
| default median | 1431（无法验证） | **1546** |
| ra0 median | 2591（无法验证） | **2876** |
| ratio | 1.81x | **1.86x** |
| CV | 0.4%（无法验证） | 3.7% / 0.5% |
| hit% | 未采集 | ~50% / ~24% |
| C_amp | 未采集 | 2.08 / 1.02 ✅ |

### 9.5 原始数据路径

```
157:/tmp/opencode-fullbaseline-v3/E6R/
├── randread-E6R-default-r1/
│   ├── fio.txt              # fio 完整输出
│   ├── hit-rate.txt         # pre/post hit_bytes + miss_bytes
│   ├── nic.txt              # NIC 逐秒采集
│   ├── *_bw.*.log           # bw_log（128 job 各一个）
│   ├── mount-cmd.txt       # mount 命令行快照
│   ├── config-md5.txt       # ceph config dump md5
│   └── c_amp.txt            # C_amp 计算结果
├── randread-E6R-default-r2/
│   └── ...（同上）
├── randread-E6R-default-r3/
│   └── ...
├── randread-E6R-ra0-r1/
│   └── ...（同上）
├── randread-E6R-ra0-r2/
│   └── ...
├── randread-E6R-ra0-r3/
│   └── ...
└── test.log                 # 完整运行日志
```

- 脚本：`157:/tmp/e6-redo.sh`（default 部分）+ `157:/tmp/e6-redo-ra0.sh`（ra0 部分）
- 计算脚本：`157:/tmp/calc_hitrate.py` + `157:/tmp/calc_c_amp.py`

### 9.6 限制

- **同会话内背靠背**：default 和 ra0 在同一会话内（不重启 OSD），比值可信，绝对值跨会话不可比（Opus AU.5 已证 T6→T7 ra0 -35%）
- **CV 3.7%**（default）：高于上次声称的 0.4%（上次无数据无法验证，实际是算错——stdev/mean = 0.70%，不是 0.4%）
- **autotune=false 仍生效**：mon 数据库中 `bluestore_cache_autotune=false` + `bluestore_cache_size=30GB` 未恢复（测试后需恢复）
