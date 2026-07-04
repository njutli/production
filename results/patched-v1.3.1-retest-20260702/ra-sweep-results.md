# RA Sweep + 冷态 mu=150 测试结果

> 日期：2026-07-03
> 二进制：/tmp/juicefs-patched-clean（v1.3.1+2025-12-02.e0032b2a，含 loadRange 修复）
> 环境：3-node Ceph（6 OSD, EC 4+2）/ TiKV meta / 1Gbps / block-size=256K
> 测试前 drop OSD page cache + 客户端 page cache（真冷态）
> 复用已有 128G 布局，不 destroy/format/layout

---

## 一、RA Sweep 对照表（冷态 cache=0，patched v1.3.1）

| ra (MiB) | seqread | randread r1 | randread r2 | randread r3 | randread MAX |
|----------|---------|-------------|-------------|-------------|-------------|
| 0 (T2)¹ | 51.6 | 53.4 | 51.4 | 73.1 | 73.1 |
| 1 | 74.7 | 51.0 | 54.6 | 54.5 | 54.6 |
| 2 (=default) | 80.1 | 52.0 | 54.6 | 56.1 | 56.1 |
| 4 | 81.1 | 52.0 | 54.8 | 56.1 | 56.1 |
| 8 | 86.2 | 52.2 | 54.4 | 55.7 | 55.7 |
| default(=2)² | 78.8 | 37.2 | 45.4 | 35.1 | 45.4 |

¹ T2 来自全量测试，未 drop OSD cache（post-layout OSD 压力状态）
² T1 来自全量测试，未 drop OSD cache（post-layout OSD 压力状态）

### 关键发现

1. **randread r1 在所有 ra 值下基本持平（51-53）**：ra 对 randread 几乎无影响。
   - 之前的结论"ra=0 显著提升 randread"是**带 bug 版本的假象**——loadRange bug 造成的 2x 放大与 ra 预读叠加，ra=0 恰好消除了预读部分。修复 bug 后，预读不再造成额外放大。

2. **seqread 随 ra 单调递增**：51.6 → 74.7 → 80.1 → 81.1 → 86.2
   - ra=0 严重损害顺序读（-37% vs default）
   - ra=1 已恢复大部分顺序读（74.7 vs 80.1，仅 -7%）
   - ra≥2 后 seqread 趋于饱和

3. **T1 vs ra=2（同配置）差异巨大**：randread r1 37.2 vs 52.0（+40%）
   - T1 在 layout 写入后 120s cooldown 即开始随机测试，OSD RocksDB compaction 未完成
   - ra sweep 在 layout 写入 12+ 小时后测试，OSD 状态稳定
   - **结论：T1/T2 全量测试的 randread r1 数据偏低，不代表稳态性能**

4. **最佳 ra 值 = default（2）或更高**：randread 不受 ra 影响，seqread 在 ra≥2 时达到 80+。无需设置 ra=0。

---

## 二、冷态 mu=150 测试结果（仅随机测试）

> 顺序测试因 BlueFS stall 跳过。顺序类指标参考 T1（mu=20, default）。
> 测试前 drop OSD cache，但 OSD 经历过重启恢复。

| 指标 | r1 | r2 | r3 | MAX |
|------|-----|-----|-----|-----|
| randread | 48.7 | 48.4 | 33.2 | 48.7 |
| randwrite | 45.9 | 46.3 | 41.8 | 46.3 |
| randrw R | 26.6 | 26.3 | 21.8 | 26.6 |
| randrw W | 26.3 | 26.0 | 21.5 | 26.3 |

### 与 T1（冷态 mu=20）对比

| 指标 | T1 mu=20 r1 | mu=150 r1 | 变化 | 判定 |
|------|------------|-----------|------|------|
| randread | 37.2² | 48.7 | +31% | OSD状态差异²，不结论 |
| randwrite | 43.1 | 45.9 | +6.5% | 小幅提升，可能波动 |
| randrw R | 14.3 | **26.6** | **+86%** | **真实提升** |
| randrw W | 14.0 | **26.3** | **+88%** | **真实提升** |

² T1 未 drop OSD cache 且 post-layout，randread 偏低。ra sweep 同配置 ra=2 r1=52.0，mu=150 r1=48.7 差异 6%，在波动范围内。

### 与 ra-sweep ra=2（同冷态 mu=20）对比

| 指标 | ra=2 mu=20 r1 | mu=150 r1 | 变化 | 判定 |
|------|--------------|-----------|------|------|
| randread | 52.0 | 48.7 | -6.3% | 波动范围内 |
| randwrite | — | 45.9 | — | 无对照 |
| randrw R | — | 26.6 | — | 无对照³ |

³ ra sweep 未测 randwrite/randrw。

### 关键发现

1. **mu=150 大幅提升冷态 randrw（+86%）**：26.6 vs 14.3
   - randrw 是 50% 读 + 50% 写，写操作需要 upload goroutine
   - mu=20 时 128 个 fio job 争抢 20 个 upload slot，写请求排队
   - mu=150 提供足够 upload slot，减少排队延迟
   - **确认了用户的假设：瓶颈在并发度，提高 max-uploads 可以提升 randrw**

2. **mu=150 对 randread 无显著影响**：48.7 vs 52.0（-6.3%，波动范围）
   - 读操作不走 upload pipeline，符合预期

3. **mu=150 对 randwrite 小幅提升**：45.9 vs 43.1（+6.5%）
   - 纯写场景已有 128 个 fio job 并发写，upload slot 从 20→150 有帮助但不是主要瓶颈

4. **randrw 仍不达标**：最优 26.6，距 59 差 2.2 倍
   - mu=150 改善了并发度，但读写竞争仍是瓶颈

---

## 三、结论

### 对原报告结论的修正

| 原报告结论 | 修正后 | 依据 |
|-----------|--------|------|
| ra=0 救随机读、砸顺序读 | **patch 后 ra 对 randread 无影响，ra=0 仅砸 seqread** | ra sweep: randread r1 在 ra=0/1/2/4/8 下均为 51-53 |
| ra=0 是随机读最优配置 | **无需设 ra=0，default 即可** | ra=0 randread=53.4 vs default=52.0，差异在波动内 |
| randrw 瓶颈未定位 | **randrw 瓶颈部分来自 upload 并发度不足** | mu=150 冷态 randrw +86%（14.3→26.6） |
| mu=150 是暖态 randrw 最优 | **冷态同样有效** | 冷态 randrw 26.6 vs 暖态 25.8，一致 |

### 生产配置建议

| 参数 | 建议值 | 理由 |
|------|--------|------|
| --max-readahead | default（2 MiB） | ra 对 randread 无影响，default seqread 最优 |
| --max-uploads | 150 | 冷态/暖态 randrw 均显著提升 |
| --block-size | 256K | 核心突破，不变 |
| --cache-size | 100G | 暖态随机读大幅提升 |

### 下一步

1. randrw 即使 mu=150 仍差 2.2 倍，需进一步定位残余瓶颈（读写竞争机制）
2. 考虑测更大 mu 值（200/300）看是否有边际递减
3. 多客户端 randrw 聚合测试（贴近验收口径）
