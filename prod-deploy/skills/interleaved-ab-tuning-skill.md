# 交错 A/B 调优对比 Skill

> 适用：block-size / EC profile 等需要重新 format + layout 的调优项
> 依据：LC.12 B 组实测 σ≈11.5%（单次 layout 抽签），write-impact 实验"增量覆写不重抽签"
> 创建：2026-07-30

---

## 一、核心原则

**单次 layout = 一次抽签。** 不能比单值，只能比分布。交错采样消除时间漂移。

---

## 二、方法

### 2.1 交错 A/B（非先后块设计）

```
round 1: format(旧配置) → 灌 layout → 测受影响项
round 2: format(新配置) → 灌 layout → 测受影响项
round 3: format(旧配置) → ...
round 4: format(新配置) → ...
...
```

每轮本来就要 format（改 block-size/EC），交错零成本。时间漂移均匀摊入两组。

### 2.2 i.i.d. 前置

每轮统一 allocator 前置状态：
1. `juicefs format --force`（新 volume UUID）
2. `rados purge`（清空 pool）
3. `compact_cooldown`（清 RocksDB tombstone）
4. 灌 layout 128G
5. `compact_cooldown` + `drop_caches`

否则前轮残留污染下次抽签，样本不独立。

---

## 三、样本量与判据

以 B 组实测 σ≈11.5%（≈160 MiB/s @ 中位 1390）估算（2×SEM 经验法则）：

| 每侧 n | SEM (MiB/s) | 可检测 Δ | 判据 |
|--------|------------|----------|------|
| 3 | ~92 | ~13% | ±15% |
| **5** | ~72 | **~10%** | **±10%** ← 推荐 |
| 8 | ~57 | ~8% | ±8% |
| 20 | ~36 | ~5% | ±5% |

推荐 **n=5/侧、判据 ±10%**。成本控制：每轮仅 format + 灌主 layout 128G（跳过 seq/mseq 子目录）+ 只测受影响项，单轮 ~6-7min，10 轮 ≈ 1.2h。Δ 落灰区则加轮次。

---

## 四、双峰统计处理

B 组呈双峰（高簇 ~1467，低簇 ~1042）。n=5 时中位数可能整组落单簇致假结论。

规则：
- **报告全部数据点**（dot plot）+ mean±SD
- 组间比较用 **Mann-Whitney U**（n=5 时 t 检验太弱）
- 判读：
  - 分布不重叠 → 有效
  - 重叠 → 加轮次
  - 均值差 <5% → 判无效

---

## 五、与锁定布局法的对比

| 维度 | 锁定布局法（FULLBASELINE_V2） | 交错 A/B 法（本文） |
|------|------------------------------|-------------------|
| 适用 | mount 参数调优（不改 block-size/EC） | block-size/EC profile 调优 |
| layout | 一次性，不重灌 | 每轮 format + 重灌 |
| CV | 0.6-3.1% | ~11.5%（单次抽签） |
| 判据 | ±5% | ±10% |
| 成本/轮 | ~3.5-4min | ~6-7min |
| 统计方法 | 中位数 + CV | Mann-Whitney U + dot plot |

---

## 六、流程模板

```bash
# 交错 A/B（n=5/侧，共 10 轮）
for round in $(seq 1 10); do
    if [ $((round % 2)) -eq 1 ]; then
        CONFIG="旧配置"    # 如 block-size=256K
    else
        CONFIG="新配置"    # 如 block-size=128K
    fi
    # 1. 统一前置
    juicefs format --block-size=${CONFIG} --force "${META}" juicefs-prod
    sudo rados purge juicefs-data --yes-i-really-really-mean-it
    compact_cooldown
    # 2. 灌 layout
    fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
        --bs=4M --rw=write --numjobs=128 --direct=1 --ioengine=libaio \
        --iodepth=128 --group_reporting --end_fsync=1
    compact_cooldown; drop_caches
    # 3. 测受影响项
    fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --group_reporting \
        --time_based --runtime=180 --write_bw_log=...
    # 4. 记录
    echo "round=${round} config=${CONFIG} bw=..." >> results.txt
done
# 5. 分析：Mann-Whitney U + dot plot
```
