# loadRange patch 验证结果

> 日期：2026-07-01
> 测试者：GLM
> 依据：`doc/perf-analysis/13-randread-amplification-source-analysis.md` v3
> 根因：v1.3.1 `cached_store.go:153` 条件 `len(p) <= blockSize/4 = 64K` 阻止 128K FUSE 半块进 `loadRange`，全部走全量读 → 2× 放大
> 修复：commit `eaf3d21f`，加 `!CacheEnabled()` 备选条件

---

## 一、测试配置

| 参数 | 值 |
|------|---|
| 二进制 | `/tmp/juicefs-patched-clean`（v1.3.1 + patch 第 153 行，无调试日志） |
| 挂载 | `--cache-size 0 --max-readahead 0` |
| fio | nj=128 / bs=256k / direct=1 / iodepth=128 / runtime=60s |
| 工作集 | 128×1G（复用现有 `juicefs-prod` 卷） |
| EC | k=4 m=2（`ec-prod` profile） |
| 采集 | BW + NIC RX + 6 OSD before/after json |

---

## 二、主表：patch 前后对比

| 指标 | randread 基线 | randread patched | seqread 基线 | seqread patched |
|------|-------------|-----------------|-------------|----------------|
| BW (MiB/s) | 51.8 | **98.3** | 106 | 112 |
| fio io (MiB) | 3139 | **5934** | 6412 | 6763 |
| OSD 总吐出 (MiB) | 6807 | 6562 | 6681 | 6666 |
| **后端放大** | **2.17×** | **1.11×** | 1.04× | 0.99× |
| NIC 放大 | 2.33× | 1.17× | 1.04× | 1.04× |
| 每 op (KiB) | 127 | **67** | 127 | **64** |
| OSD ops | ~55,000 | ~100,400 | ~54,000 | ~107,200 |

> 基线数据来自 `results/readahead-sweep-glm-20260630/`（randread ra=0 3 轮均值）和 `results/seqrand-osd-compare-final-20260629/`（seqread）。
> Patched 数据为本目录 3 轮均值。

---

## 三、三轮原始数据

### randread

| 轮次 | BW | io (MiB) | OSD_out (MiB) | 后端放大 | ops | 每 op (KiB) | NIC RX (MiB) |
|------|-----|---------|--------------|---------|------|------------|-------------|
| 1 | 98.8 | 5958 | 6633 | 1.11× | 100,858 | 67.3 | 7015 |
| 2 | 100.0 | 6040 | 6652 | 1.10× | 101,908 | 66.8 | 7034 |
| 3 | 96.0 | 5803 | 6400 | 1.10× | 98,430 | 66.6 | 6787 |
| 均值 | 98.3 | 5934 | 6562 | **1.11×** | 100,398 | 66.9 | 6945 |

### seqread

| 轮次 | BW | io (MiB) | OSD_out (MiB) | 后端放大 | ops | 每 op (KiB) | NIC RX (MiB) |
|------|-----|---------|--------------|---------|------|------------|-------------|
| 1 | 112 | 6729 | 6637 | 0.99× | 106,674 | 63.7 | 7011 |
| 2 | 112 | 6778 | 6679 | 0.99× | 107,391 | 63.7 | 7062 |
| 3 | 112 | 6782 | 6682 | 0.99× | 107,388 | 63.7 | — |
| 均值 | 112 | 6763 | 6666 | **0.99×** | 107,151 | 63.7 | 7037 |

---

## 四、判读

### V1-a（patched randread）：✅ 坐实

后端放大从 **2.17× 降到 1.11×**，BW 从 51.8 翻倍到 98.3。`loadRange` 条件 bug 是随机读 2.17× 放大的根因，patch 修复有效。

残余 0.11× 放大来源：
- `Head`（`ceph.go:136`）每次 `Get` 前做 `rados.Stat`，产生 STAT op（~0 字节输出但计入 op 计数）
- EC 4+2 下 128K range GET 需读取 2 个 64K data chunk，边界处可能有少量额外读取
- NIC 背景流量

### V1-b（patched seqread）：✅ 不影响顺序读

后端放大 0.99×（patch 前 1.04×），BW 112（patch 前 106）。patch 不影响顺序读——顺序读的低放大来自 kernel FUSE readahead + `group.Execute` singleflight 合并，与 `loadRange` 是否被调用无关。

### per-op 变化

- 基线 127K = STAT(0) + 256K 全量读 的平均值
- Patched 67K ≈ 64K = EC 4+2 的 data chunk 大小（256K / k=4）
- 确认 `loadRange` 的 128K range GET 在 EC 4+2 下被拆成 2 个 64K data chunk op

---

## 五、结论

1. **v1.3.1 `cached_store.go:153` 的 `loadRange` 条件 bug 是随机读 2.17× 后端放大的根因**，由 patch（加 `!CacheEnabled()`）修复后放大降到 1.11×
2. **BW 翻倍**（51.8 → 98.3 MiB/s），因为后端不再 2× 浪费
3. **顺序读不受影响**（~1× 不变），patch 安全
4. **修复 commit `eaf3d21f` 已在 main 分支，建议 backport 到 release-1.3 或升级到 v1.4.0+**

---

## 六、文件清单

```
loadrange-patch-verify-20260701/
├── README.md                              本文件
├── analyze.py                             OSD 分析脚本
├── test-script.log                        完整运行日志
├── env.txt                                环境快照
├── mount.log                              挂载日志（确认 cache=0）
├── patched-{randread,seqread}-r{1,2,3}-fio.txt        6 个 fio 完整输出
├── patched-{randread,seqread}-r{1,2,3}-osd{0-5}-{before,after}.json   72 个 OSD perf dump
└── patched-{randread,seqread}-r{1,2,3}-nic.txt        6 个 NIC + BW 汇总
```
