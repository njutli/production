# 基线数据对比文档

> 用途：01-2d 基线数据 vs 256K+buf1024 调优数据对比
> 01-2d 数据来源：`results/prod-01-2d-fullretest-20260717/summary.md`
> 周报（20260718）数据与 01-2d §8.3 稳态中位数一致

---

## 一、01-2d 基线数据（§8.3 稳态中位数，MiB/s）

> 集群：01-2d 集群（不同 FSID）
> mount: `--max-uploads 150 --cache-size 0`，`--max-fuse-io` 未设置（默认 128K）
> 方法论：清卷 destroy + compact cooldown + REPEAT=3 取中位数
> Group A: default readahead，Group B: ra0（`--max-readahead 0`）

### 1.1 Group A（default，不限速 100GbE）

| 测试项 | §8.3 中位数 | fio 聚合中位数 |
|--------|:---:|:---:|
| seqread | 1263.2 | 1263 |
| seqwrite | 1530.0 | 1527 |
| mseqread | 3803.8 | 3792 |
| mseqwrite | 4906.0 | 4886 |
| layout | 4217.6 | 3357 |
| randwrite-true | 3634.7 | 3537 |
| randread | 1480.0 | 1475 |
| randrw R | 1031.8 | 1034 |
| randrw W | 1037.5 | 1033 |
| randwrite-ow | 2143.6 | 2415 |

### 1.2 Group B（ra0，不限速 100GbE）

| 测试项 | §8.3 中位数 | fio 聚合中位数 |
|--------|:---:|:---:|
| seqread | 177.5 | 176 |
| seqwrite | 1550.0 | 1557 |
| mseqread | 1908.5 | 1871 |
| mseqwrite | 4148.0 | 4121 |
| layout | 3170.6 | 3198 |
| randwrite-true | 4274.3 | 4148 |
| randread | 2404.2 | 2453 |
| randrw R | 1316.3 | 1318 |
| randrw W | 1319.0 | 1318 |
| randwrite-ow | 3651.0 | 2776 |

### 1.3 rados bench 后端裸能力

| 模式 | -t | 中位数 (MB/s) |
|------|:---:|:---:|
| Write | 128 | 3361 |
| Write | 4096 | 3516 |
| Seq read | 128 | 4489 |
| Seq read | 4096 | 4388 |
| Rand read | 128 | 4417 |
| Rand read | 4096 | 4383 |

---

## 二、01-5 集群复现基线（2026-07-20，128K default）

> 集群：01-5（FSID: 4f4e3ca0）
> cluster_network=10.3.1.0/24（还原为 public，模拟 01-2d 状态）
> OSD 重启后冷启动
> mount: `--max-uploads 150 --cache-size 0 --max-readahead 0`（ra0），`--max-fuse-io` 未设置（默认 128K）
> 方法论：清卷 destroy + compact cooldown + REPEAT=3

### 2.1 ra0 组复现数据（fio avg BW，MiB/s）

| 测试项 | r1 | r2 | r3 | 中位 | 01-2d ra0 fio 中位 | 偏差 |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|
| seqread | 175 | — | — | 175 | 176 | -0.6% ✅ |
| seqwrite | 1388 | — | — | 1388 | 1557 | -11% |
| mseqread | 1773 | — | — | 1773 | 1871 | -5% |
| mseqwrite | 3349 | — | — | 3349 | 4121 | -19% |
| layout | 3317 | — | — | 3317 | 3198 | +4% ✅ |
| randwrite-true | 3066 | 3253 | 3220 | **3220** | 4148 | -22% |
| randread | 2844 | 2846 | 2812 | **2844** | 2453 | +16% |
| randrw R | 1318 | 1355 | 1065 | **1318** | 1318 | 0% ✅ |
| randrw W | 1318 | 1355 | 1064 | **1318** | 1318 | 0% ✅ |
| randwrite-ow | 808 | 840 | 601 | **808** | 2776 | -71%* |

> *randwrite-ow 轮间退化问题（compact 不足导致），01-2d 用 pool 重建保证同状态

### 2.2 复现结论

- seqread、randrw 完美匹配（<1%）
- layout 接近（+4%）
- randread +16%、randwrite-true -22%：两套集群 RADOS 能力差异（rados bench write 2778 vs 3361, -17%）
- 在可接受范围内，复现成功

---

## 三、256K+buf1024 调优数据（待测）

> 测试条件：
> - 集群：01-5（同复现基线）
> - cluster_network=10.3.1.0/24（同复现基线）
> - OSD 重启清缓存（同复现基线）
> - mount: `--max-uploads 150 --cache-size 0 --max-readahead 0 --max-fuse-io 256K --buffer-size 1024`（ra0）或 `--max-uploads 150 --cache-size 0 --max-fuse-io 256K --buffer-size 1024`（default）
> - 方法论：同复现基线（清卷 destroy + compact cooldown + REPEAT=3）

### 3.1 ra0 组（待测）

| 测试项 | r1 | r2 | r3 | 中位 | 01-2d ra0 | 变化 |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|
| — | — | — | — | — | — | — |

### 3.2 default 组（待测）

| 测试项 | r1 | r2 | r3 | 中位 | 01-2d default | 变化 |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|
| — | — | — | — | — | — | — |
