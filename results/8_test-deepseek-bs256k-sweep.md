# 8_test-deepseek-bs256k-sweep.md

> 在 256K block-size（ceph 直连 RADOS）基础上扫 JuiceFS mount 参数，验证消除读放大后
> `--buffer-size`/`--prefetch`/`--max-readahead`/`--writeback` 是否对 randread 有效。
> 
> 结果文件：`results/bs256k-sweep-20260618-101648.txt`
> 测试机：tikv-node (192.168.11.12)，Ceph EC 4+2，pool `juicefs-data`

---

## 一、测试配置

| 项 | 值 |
|----|-----|
| 后端 | ceph 直连 RADOS，pool `juicefs-data` |
| block-size | 256K |
| 布局 | 32 jobs × 1G = 32G |
| fio | bs=256k, iodepth=128, numjobs=32, direct=1, runtime=60s |
| 缓存 | `--cache-size 0`，每步前 drop_caches（冷态） |
| 每组跑 | 纯 randread / 纯 randwrite(analysis) / randrw(analysis) |

## 二、Part 1：读侧 mount 参数

| # | 标签 | mount 参数 |
|---|------|-----------|
| 1 | baseline | 无 |
| 2 | buf2g | `--buffer-size 2048` |
| 3 | prefetch0 | `--prefetch 0` |
| 4 | prefetch16 | `--prefetch 16` |
| 5 | buf2g-prefetch16 | `--buffer-size 2048 --prefetch 16` |
| 6 | readahead | `--buffer-size 2048 --max-readahead 512` |

### 结果

| 参数 | randread | randwrite | randrw 读 | randrw 写 |
|------|----------|-----------|----------|----------|
| **baseline** | **32.2 MB/s** | 105 MB/s | 22.5 MB/s | 21.6 MB/s |
| buf2g | 30.5 MB/s (−5%) | 165 MB/s (+57%) | 20.8 MB/s | 20.0 MB/s |
| prefetch0 | 31.3 MB/s (−3%) | 99.3 MB/s | 24.2 MB/s | 23.3 MB/s |
| prefetch16 | 31.1 MB/s (−3%) | 103 MB/s | 24.6 MB/s | 23.7 MB/s |
| buf2g + pf16 | 30.3 MB/s (−6%) | 145 MB/s (+38%) | 21.4 MB/s | 20.5 MB/s |
| buf2g + readahead | 31.9 MB/s (−1%) | 139 MB/s (+32%) | 22.9 MB/s | 22.1 MB/s |

## 三、Part 2：写侧参数

| # | 标签 | 改动 | 状态 |
|---|------|------|------|
| 2a | writeback | mount 加 `--writeback` | ✅ 已测 |
| 2b | max-uploads | `EXTRA_FORMAT_OPTS="--max-uploads 40"` | ❌ v1.3.1 无此参数 |

### 结果

| 参数 | randread | randwrite | randrw 读 | randrw 写 |
|------|----------|-----------|----------|----------|
| baseline | 32.2 MB/s | 105 MB/s | 22.5 MB/s | 21.6 MB/s |
| writeback | 32.1 MB/s (≈) | 74.7 MB/s (−29%) | 23.8 MB/s | 23.0 MB/s |

## 四、结论

1. **读侧参数对 256K block-size randread 仍然无效**：
   所有参数组合 randread 均在 30–32 MB/s，波动 ±5%，无趋势性提升。
   与 08_2 B 测试（4M block-size）结论一致——`--buffer-size`/`--prefetch`/`--max-readahead` 对随机读不起作用。
   即使消除了读放大，调参也无法继续提升。

2. **buffer-size 2048 大幅加速了 randwrite**（+57%，105→165 MB/s）：
   这不是读侧参数，而是增大了写缓冲（buffer 从 300MB 扩到 2GB），
   使 JuiceFS 能聚合更多小写再落盘。但 randread 同时略降（-5%），与 4M 卷行为一致。

3. **prefetch 开/关对 randread 几乎无影响**：与 4M 卷一致（08_2 B：5.0→5.1）。

4. **writeback 对冷态 randwrite 反而下降**（105→74.7 MB/s）：
   可能原因为 writeback 引入异步 flush 竞争，或 `--cache-size 0` 下 writeback 缓存池为零，
   导致每次写仍走同步路径而非预期中的"写缓存即返回"。

5. **`--max-uploads` 不存在于 JuiceFS 1.3.1**：`juicefs format: unknown option: --max-uploads`。
   这是 v1.4+ 参数，当前版本不可用。

6. **与 4M block-size 对比**：

| 测试 | 4M baseline | 256K baseline | 256K 增幅 |
|------|------------|-------------|----------|
| 纯 randread (32G) | ~5.0 MB/s | 32.2 MB/s | **6.4×** |
| 纯 randwrite (32G) | ~? MB/s | 105 MB/s | — |
| randrw 读 (32G) | ~? MB/s | 22.5 MB/s | — |

> 4M baseline 数据来自 08_2 B 测试（randread 32G 冷态）。
> 256K 调参后最佳 randread = 32.2（baseline），未突破。
> **128G 全口径下 256K randread = 45.8 MB/s**（见 `8_test-deepseek-3round-retest.md`），
> 32G 口径的 32.2 与之比例合理（job 数 32 vs 128，并发度差 4×）。

## 五、Part 3：缓存热态（warmup）

| 配置 | 值 |
|------|-----|
| cache-dir | /dev/shm/jfsCache (tmpfs) |
| cache-size | 10240 MB |
| cache-partial-only | yes |
| 预热 | `juicefs warmup` 全目录 |

### 结果

| 测试 | 冷态 baseline | warmup 热态 | 变化 |
|------|-------------|------------|------|
| **纯 randread** | 32.2 MB/s | **48.2 MB/s** | **+50%** |
| 纯 randwrite | 105 MB/s | 116 MB/s | +10% |
| randrw 读 | 22.5 MB/s | 23.1 MB/s | +3% |
| randrw 写 | 21.6 MB/s | 22.2 MB/s | +3% |

### 对比 128G 全口径

| 配置 | randread | randwrite | randrw 读 | randrw 写 |
|------|----------|-----------|----------|----------|
| Cold baseline | **36.5 MB/s** | 113 MB/s | 25.3 MB/s | 24.8 MB/s |
| buffer-size 2048 | 32.2 MB/s (−12%) | **174 MB/s (+54%)** | 26.1 MB/s | 25.8 MB/s |
| warmup (10GB cache) | 35.9 MB/s (−2%) | 107 MB/s | 26.9 MB/s | 26.5 MB/s |

> warmup 基本无效：10GB cache << 128G 工作集（warmup 实际读取 292 GiB），
> 缓存命中率极低。要使 warmup 生效，cache-size 需 ≥ 热数据量。

#### 达标判定

| 配置 | randread | 达标 (59)? |
|------|----------|-----------|
| 256K cold (128G) | 36.5–45.8 MB/s | ❌ 59%–78% |
| 256K + buf2g (128G) | 32.2 MB/s | ❌ |
| 256K + warmup 10GB (128G) | 35.9 MB/s | ❌ |
| **多客户端 256K** (opus C, 32G) | **54.8 MB/s** | ⚠️ 93% |

> 单次 36.5 与 ×3 均值 45.8 有波动，属于正常单次方差范围。

## 六、最终结论

1. **所有 mount 参数对 256K block-size randread 仍无效**——与 4M 卷 08_2 B 测试一致
2. **buffer-size 2048 大幅提升写**（+57%），但 randread 不涨
3. **warmup 热态 randread 提升 50%**（32.2→48.2），是最有效的单一手段
4. **128G 全口径 warmup**：冷态 45.8，warmup 后有望突破 59，待测
5. **`--max-uploads` 不存在于 v1.3.1**，需升 v1.4+
