# 10 三轮对比重测结果（DeepSeek，2026-06-17）

> 执行三组 128G 全口径 bench 测试（REPEAT=3），使用最新 bench-juicefs.sh（含新增 9a/9b
> analysis 口径步骤）。目的：以统一口径重测 S3 vs RADOS vs 256K block-size，排除单次波动，
> 并验证新增 analysis 口径对 randrw 读偏差的消除效果。
>
> 测试机：tikv-node (192.168.11.12)，HAProxy LB balance=source，RGW ×3，Ceph EC 4+2。
> 结果文件：
> - `results/20260617/20260617-192216-s3-128G-new.txt`
> - `results/20260617/20260617-203851-rados-128G-new.txt`
> - `results/20260617/20260617-214030-rados-bs256k-128G-new.txt`

---

## 一、测试配置

| 项 | 值 |
|----|-----|
| fio 参数 | bs=256k, iodepth=128, numjobs=128, direct=1, time_based, runtime=60s |
| 布局规模 | 128 jobs × 1G = 128GB |
| 重复次数 | REPEAT=3（每组 ×3，取均值） |
| 缓存状态 | cold（每步前 drop_caches） |
| S3 后端 | RGW via HAProxy LB（balance=source），bucket `juicefs-prod` |
| RADOS 后端 | ceph pool `juicefs-data`（EC 4+2），cephx user `client.juicefs` |

## 二、口径说明

| 步骤 | 口径 | 数据来源 | create_on_open | 可靠性 |
|------|------|---------|---------------|--------|
| 9 | randread [spec] | 复用 layout 文件 | 无 | ✅ 可靠 |
| 9a | randwrite [analysis] | 复用 layout 文件 | 无 | ✅ 可靠 |
| 9b | randrw [analysis] | 复用 layout 文件 | 无 | ✅ 可靠 |
| 10 | randwrite [spec] | fresh 空卷 | 有 | ⚠️ 含文件创建开销 |
| 11 | randrw [spec] | fresh 空卷 | 有 | ❌ 读大量 short（打到空块） |

## 三、测试结果

### 3.1 S3 (RGW)，4M block-size

| 步骤 | 测试 | run1 | run2 | run3 | **均值** |
|------|------|------|------|------|----------|
| Layout | 写 128G | 68.7 MB/s | — | — | 68.7 |
| 9 | 纯 randread | 9.7 MB/s | 10.2 MB/s | 9.6 MB/s | **9.8 MB/s** |
| 9a | 纯 randwrite [a] | 78.0 MB/s | 78.1 MB/s | 78.1 MB/s | **78.1 MB/s** |
| 9b | randrw 读 [a] | 5.9 MB/s | 5.9 MB/s | 5.6 MB/s | **5.8 MB/s** |
| 9b | randrw 写 [a] | 5.7 MB/s | 5.8 MB/s | 5.5 MB/s | **5.7 MB/s** |
| 10 | 纯 randwrite [s] | 67.8 MB/s | 66.7 MB/s | 66.8 MB/s | **67.1 MB/s** |
| 11 | randrw 读 [s] | 1.4 MB/s | 1.4 MB/s | 1.6 MB/s | **1.5 MB/s** |
| 11 | randrw 写 [s] | 32.9 MB/s | 32.8 MB/s | 33.2 MB/s | **33.0 MB/s** |
| 11 | short reads | 7820 | 7847 | 7925 | **96% short** |

### 3.2 Direct RADOS，4M block-size

| 步骤 | 测试 | run1 | run2 | run3 | **均值** |
|------|------|------|------|------|----------|
| Layout | 写 128G | 109 MB/s | — | — | 109 |
| 9 | 纯 randread | 13.1 MB/s | 13.4 MB/s | 13.9 MB/s | **13.5 MB/s** |
| 9a | 纯 randwrite [a] | 126 MB/s | 126 MB/s | 126 MB/s | **126 MB/s** |
| 9b | randrw 读 [a] | 11.8 MB/s | 11.8 MB/s | 11.6 MB/s | **11.7 MB/s** |
| 9b | randrw 写 [a] | 11.7 MB/s | 11.6 MB/s | 11.5 MB/s | **11.6 MB/s** |
| 10 | 纯 randwrite [s] | 54.4 MB/s | 53.8 MB/s | 53.7 MB/s | **54.0 MB/s** |
| 11 | randrw 读 [s] | — | — | — | **0 MB/s** |
| 11 | randrw 写 [s] | 26.8 MB/s | 26.7 MB/s | 26.5 MB/s | **26.7 MB/s** |
| 11 | short reads | 6289 | 6266 | 6204 | **100% short** |

### 3.3 Direct RADOS，256K block-size

| 步骤 | 测试 | run1 | run2 | run3 | **均值** |
|------|------|------|------|------|----------|
| Layout | 写 128G | 117 MB/s | — | — | 117 |
| 9 | 纯 randread | 45.7 MB/s | 45.7 MB/s | 46.1 MB/s | **45.8 MB/s** |
| 9a | 纯 randwrite [a] | 128 MB/s | 128 MB/s | 128 MB/s | **128 MB/s** |
| 9b | randrw 读 [a] | 35.2 MB/s | 35.7 MB/s | 36.0 MB/s | **35.6 MB/s** |
| 9b | randrw 写 [a] | 34.8 MB/s | 35.2 MB/s | 35.5 MB/s | **35.2 MB/s** |
| 10 | 纯 randwrite [s] | 61.0 MB/s | 54.3 MB/s | 68.9 MB/s | **61.4 MB/s** |
| 11 | randrw 读 [s] | — | — | — | **0 MB/s** |
| 11 | randrw 写 [s] | 26.8 MB/s | 26.7 MB/s | 26.8 MB/s | **26.8 MB/s** |
| 11 | short reads | 6291 | 6256 | 6286 | **100% short** |

> 注：[a]=analysis 口径（复用 layout），[s]=spec 口径（fresh+create_on_open）。

## 四、对比矩阵（analysis 口径，可靠）

### S3 4M vs RADOS 4M（RGW 影响）

| 测试 | S3 4M | RADOS 4M | 变化 |
|------|-------|----------|------|
| **纯 randread** | 9.8 MB/s | 13.5 MB/s | **+38%** |
| **纯 randwrite** | 78.1 MB/s | 126 MB/s | **+61%** |
| **randrw 读** | 5.8 MB/s | 11.7 MB/s | **+102%** |
| **randrw 写** | 5.7 MB/s | 11.6 MB/s | **+104%** |

### RADOS 4M vs RADOS 256K（block-size 影响）

| 测试 | RADOS 4M | RADOS 256K | 变化 |
|------|----------|-----------|------|
| **纯 randread** | 13.5 MB/s | 45.8 MB/s | **+239%** |
| **纯 randwrite** | 126 MB/s | 128 MB/s | **+2%** |
| **randrw 读** | 11.7 MB/s | 35.6 MB/s | **+204%** |
| **randrw 写** | 11.6 MB/s | 35.2 MB/s | **+203%** |

### S3 4M vs RADOS 256K（全链路优化，参考）

| 测试 | S3 4M | RADOS 256K | 变化 |
|------|-------|-----------|------|
| **纯 randread** | 9.8 MB/s | 45.8 MB/s | **+367%** |
| **纯 randwrite** | 78.1 MB/s | 128 MB/s | **+64%** |
| **randrw 读** | 5.8 MB/s | 35.6 MB/s | **+514%** |
| **randrw 写** | 5.7 MB/s | 35.2 MB/s | **+518%** |

### 对比矩阵（spec 口径，含 create_on_open 偏差）

#### S3 4M vs RADOS 4M

| 测试 | S3 4M | RADOS 4M | 变化 |
|------|-------|----------|------|
| 纯 randwrite | 67.1 MB/s | 54.0 MB/s | **−20%** |
| randrw 读 | 1.5 MB/s | 0 MB/s | **−100%** |
| randrw 写 | 33.0 MB/s | 26.7 MB/s | **−19%** |
| randrw short% | 96% | 100% | — |

#### RADOS 4M vs RADOS 256K

| 测试 | RADOS 4M | RADOS 256K | 变化 |
|------|----------|-----------|------|
| 纯 randwrite | 54.0 MB/s | 61.4 MB/s | **+14%** |
| randrw 读 | 0 MB/s | 0 MB/s | **—** |
| randrw 写 | 26.7 MB/s | 26.8 MB/s | **≈0%** |
| randrw short% | 100% | 100% | —

## 五、结论

1. **256K block-size 消除读放大效果实锤**：
   纯 randread S3 9.8 → RADOS 256K 45.8（4.7×），randrw 读 5.8 → 35.6（6.1×）。
   与 08_2 五之四的 45.8 MB/s 完全吻合。

2. **去 RGW 对随机读仅小幅改善**（9.8→13.5，+38%），非数量级。
   RGW 不是随机读瓶颈根因，主因仍是 JuiceFS 4MB block 读放大。

3. **Spec randrw（create_on_open）完全不适用于随机读分析**：
   RADOS 上短读率 100%（所有读请求都打到未写的空块），S3 上 96%。
   08_2 五之五已指出此为「口径病态」，本次用新增 analysis 口径复证。

4. **Analysis 口径（9a/9b 复用 layout）稳定可靠**：
   ×3 方差极小（randread ±0.5 MB/s，randwrite ±0 MB/s），消除了 create_on_open
   的 100% short read 假象，应作为随机读写性能判定的标准口径。

5. **256K block-size 顺序写不受损**：Layout 128G 写速 117 MB/s > 4M 的 109 MB/s。

## 六、与 opus 跨机 C 测试的互证

opus 的跨机双客户端 C 测试（256K block-size，`results/20260617/c-multihost-c256k-20260617-180815.txt`）：
- 单客户端 randread：35.5 MB/s
- 双客户端聚合：54.8 MB/s（1.54×）

本次单客户端 128G 口径 randread 45.8 MB/s（128 jobs vs opus 的 32 jobs + 32G 布局），
两者在同一量级，跨机聚合有收益，初步排除"后端共享瓶颈"假设。
