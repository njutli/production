# randwrite-ow 退化根因诊断报告

> 日期：2026-07-17
> 原始数据：`diagnosis/randwrite-ow-degradation/`（fio 输出 + per-job bw_log）

---

## 一、问题现象

randwrite-ow 三轮 REPEAT 测试中，带宽逐轮递减，即使轮间有 compact cooldown：

| 来源 | R1 | R2 | R3 | 退化幅度 |
|------|-----|-----|-----|---------|
| 首次补测（compact 轮间） | 4031 | 1704 | 1406 | R1→R3 -65% |
| 早期测试（无 compact） | 2259 | 1292 | 1096 | R1→R3 -51% |

---

## 二、诊断方法

两种策略对比，控制变量：

| 策略 | 操作 | 预期 |
|------|------|------|
| A（compact+wait） | compact_cooldown + 等 5 分钟，同 pool | 若 R2-A ≈ R1 → compact 足够 |
| B（pool 重建） | umount→destroy→compact→pool delete/recreate→format→mount→layout | 若 R2-B ≈ R1 → pool 重建恢复 |

测试前置：pool delete/recreate + OSD 重启 + HEALTH_OK 验证。

---

## 三、结果

| 测试 | BW (MiB/s) | Runtime (s) | Data (GiB) | 策略 | RocksDB 状态 |
|------|-----------|-------------|-----------|------|-------------|
| layout | 2950 | 44 | 128 | Phase 0 初始 | 膨胀（今日 6.5T+ 累积写入） |
| R1 | 1406 | 180 | 247 | 初始 layout | 膨胀 |
| R2-A | 1190 | 180 | 209 | A: compact+5min | 仍膨胀（compact 部分恢复） |
| layoutB | 4113 | 32 | 128 | B: pool 重建 | 干净（destroy+compact 清理） |
| **R2-B** | **3681** | **180** | **647** | **B: 干净 pool** | **干净** |

---

## 四、关键对比

| 对比 | 倍数 | 结论 |
|------|------|------|
| R1=1406 vs R2-B=3681 | 2.6× | **同一 layout 测试，不同 RocksDB 状态 → RocksDB 是决定因素** |
| R2-A=1190 vs R2-B=3681 | 3.1× | **compact+wait 无法恢复，pool 重建才行** |
| R2-B=3681 vs 之前 R1=4031 | 91% | **pool 重建后基本恢复到干净态水平** |
| R2-A=1190 vs R1=1406 | 85% | compact+5min 防止了大幅退化（85% vs 无 compact 的 42%） |

---

## 五、根因

**RocksDB on tmpfs（DB/WAL）状态累积导致 randwrite-ow 性能退化。**

### 机制

1. 每轮 randwrite-ow 写入 250-650 GiB（~1-2.5M 对象），对象元数据写入 RocksDB（tmpfs DB/WAL）
2. RocksDB LSM tree 随对象数增长，即使 `compact_running=0`，LSM tree 多层未合并的 SST 文件导致元数据查找变慢
3. `compact_cooldown` 合并 SST 文件，但无法完全恢复（R2-A 仅为 R1 的 85%）
4. `pool delete/recreate + destroy + compact` 彻底清理 RocksDB（删除所有对象 + 合并 tombstone），恢复到干净态（R2-B = 91% of 之前 R1）

### 为什么 compact 不够

- compact 合并 SST 文件，但 tombstone（已删除对象的标记）仍留在 LSM tree 中
- 只有删除所有对象 + compact 才能彻底清除 tombstone
- `pool delete/recreate` 删除 pool 中所有对象，但 RocksDB 上的 tombstone 需要后续 compact 才能合并
- 策略 B 的 `destroy → compact → pool delete/recreate` 顺序确保：先 destroy 删对象 → compact 合并 tombstone → pool delete/recreate 清零

### 为什么 layout 也受影响

- layout (2950) vs layoutB (4113)：同一操作，不同 RocksDB 状态
- layout 在膨胀的 RocksDB 上跑 → 2950
- layoutB 在干净的 RocksDB 上跑 → 4113 (+39%)
- 写操作也依赖 RocksDB（每个对象的元数据写入），不仅限于读

---

## 六、对基线测试的结论

**要保证三轮 randwrite-ow 在同样状态下进行，必须在每轮之间做 pool 重建：**

```
R1 → umount → destroy → compact → pool delete/recreate → format → mount → layout → compact → R2 → 同上 → R3
```

每轮间开销 ~8 分钟，但保证每轮在干净 RocksDB 上跑。

**无法通过 compact_cooldown 实现同状态**（R2-A 仅 85% of R1），必须用 pool 重建。
