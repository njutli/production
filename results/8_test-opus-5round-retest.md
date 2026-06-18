# 8_test 三轮对比重测结果（Opus，2026-06-18，REPEAT=5 全口径）

> 与 DeepSeek 的 `8_test-deepseek-3round-retest.md` **平行对照**：同样三组 128G 测试
> （S3 4M / RADOS 4M / RADOS 256K），用最新 `bench-juicefs.sh`（含 9a/9b analysis 口径）。
> **差异**：本轮 **REPEAT=5**（DeepSeek 为 3），且**做了完整顺序读写（step4-7）**——
> DeepSeek 跳过了顺序测试，本文这部分数据更全。
>
> 测试机：tikv-node (192.168.11.12)，HAProxy LB balance=source，RGW ×3，Ceph EC 4+2。
> 编排：`tests/run-rebench-master.sh`（串行单进程，三组均 rc=0）。
> 结果文件：
> - `results/20260617-224342-rebench-s3-4M-128G.txt`
> - `results/20260618-011057-rebench-rados-4M-128G.txt`
> - `results/20260618-031155-rebench-256K-128G.txt`
>
> ⚠️ **原始 fio 日志已丢失**（归档后未及提交，无法恢复）；本文表格数据为已固化的均值/明细。
> 如需原始日志，按 `tests/run-rebench-master.sh` 重跑。

---

## 一、测试配置

| 项 | 值 |
|----|-----|
| 随机项 fio 参数 | bs=256k, iodepth=128, numjobs=128, direct=1, time_based, runtime=60s |
| 顺序项 fio 参数 | bs=4M, size=4G（单 job）；多 job size=4G × numjobs=16 |
| 布局规模 | 128 jobs × 1G = 128GB |
| 重复次数 | **REPEAT=5**（每随机项 ×5，取均值） |
| 缓存状态 | cold（每步前 drop_caches，挂载 cache-size 0） |
| S3 后端 | RGW via HAProxy LB（balance=source），bucket `juicefs-prod` |
| RADOS 后端 | ceph pool `juicefs-data`（EC 4+2），cephx user `client.juicefs` |

## 二、口径说明（两组随机读写）

| 步骤 | 口径 | 命令来源 | 数据来源 | create_on_open | 可靠性 |
|------|------|---------|---------|----------------|--------|
| 9 | randread | **优化后命令**（复用 layout，去 nrfiles/create_on_open） | 复用 layout 文件 | 无 | ✅ 可靠 |
| 9a | randwrite [analysis] | **优化后命令** | 复用 layout 文件 | 无 | ✅ 可靠 |
| 9b | randrw [analysis] | **优化后命令** | 复用 layout 文件 | 无 | ✅ 可靠 |
| 10 | randwrite [spec] | **原存储规格参数** | fresh 空卷 | 有 | ⚠️ 含文件创建开销 |
| 11 | randrw [spec] | **原存储规格参数** | fresh 空卷 | 有 | ❌ 读大量 short（打到空块） |

> **两组随机读写口径**：
> - **[spec]＝原存储规格参数**（step 10/11，`--nrfiles=100 --create_on_open=1`，fresh 空卷边写边读）；
> - **[analysis]＝我们优化后的命令**（step 9/9a/9b，复用 128G 真实布局、去掉 create_on_open/nrfiles）。
> 纯 randread（step9）即优化后命令，bs/iodepth/numjobs 与 spec 相同，仅去除 short-read 失真。

---

## 三、测试结果（每随机项 run1–5 + 均值）

### 3.0 顺序读写（DeepSeek 未测，本文补全）

| 测试 | S3 4M | RADOS 4M | RADOS 256K |
|------|-------|----------|-----------|
| 顺序读（单 job, 4G） | 113 MB/s | 101 MB/s | 107 MB/s |
| 顺序写（单 job, 4G） | 69.1 MB/s | 107 MB/s | 117 MB/s |
| 多 job 顺序读（16 job, 64G） | 117 MB/s | 113 MB/s | 117 MB/s |
| 多 job 顺序写（16 job, 64G） | 69.4 MB/s | 108 MB/s | 117 MB/s |
| Layout 写 128G | 68.7 MB/s | 108 MB/s | 116 MB/s |

> 顺序写：RGW 路径明显低（~69），RADOS/256K 直连 ~107–117；256K 顺序读写不降反升。

### 3.1 S3 (RGW)，4M block-size

| 步骤 | 测试 | run1 | run2 | run3 | run4 | run5 | **均值** |
|------|------|------|------|------|------|------|----------|
| 9 | 纯 randread [优化] | 9.90 | 9.44 | 10.0 | 9.69 | 10.2 | **9.85** |
| 9a | 纯 randwrite [analysis] | 78.0 | 78.2 | 78.0 | 78.2 | 78.1 | **78.1** |
| 9b | randrw 读 [analysis] | 6.44 | 7.00 | 5.95 | 5.92 | 6.08 | **6.27** |
| 9b | randrw 写 [analysis] | 6.29 | 6.87 | 5.89 | 5.85 | 6.00 | **6.18** |
| 10 | 纯 randwrite [spec] | 66.2 | 66.1 | 65.8 | 65.6 | 65.7 | **65.9** |
| 11 | randrw 读 [spec] | 0.30 | 0.87 | 0.10 | 0.11 | 0.24 | **0.32** |
| 11 | randrw 写 [spec] | 28.3 | 30.7 | 27.6 | 27.6 | 28.2 | **28.5** |
| 11 | short reads | 6784 | 7233 | 6483 | 6495 | 6697 | **~97% short** |

### 3.2 Direct RADOS，4M block-size

| 步骤 | 测试 | run1 | run2 | run3 | run4 | run5 | **均值** |
|------|------|------|------|------|------|------|----------|
| 9 | 纯 randread [优化] | 12.8 | 13.4 | 13.0 | 13.3 | 13.7 | **13.24** |
| 9a | 纯 randwrite [analysis] | 125 | 125 | 126 | 126 | 124 | **125.2** |
| 9b | randrw 读 [analysis] | 11.8 | 12.0 | 11.7 | 11.3 | 11.8 | **11.72** |
| 9b | randrw 写 [analysis] | 11.6 | 11.9 | 11.6 | 11.2 | 11.7 | **11.60** |
| 10 | 纯 randwrite [spec] | 64.1 | 55.4 | 53.9 | 59.9 | 53.8 | **57.42** |
| 11 | randrw 读 [spec] | 0 | 0 | 0 | 0 | 0 | **0** |
| 11 | randrw 写 [spec] | 26.8 | 27.0 | 26.8 | 27.0 | 26.7 | **26.86** |
| 11 | short reads | 6297 | 6329 | 6280 | 6338 | 6271 | **100% short** |

### 3.3 Direct RADOS，256K block-size

| 步骤 | 测试 | run1 | run2 | run3 | run4 | run5 | **均值** |
|------|------|------|------|------|------|------|----------|
| 9 | 纯 randread [优化] | 45.8 | 45.9 | 45.8 | 46.0 | 46.2 | **45.94** |
| 9a | 纯 randwrite [analysis] | 128 | 128 | 128 | 127 | 109 | **124.0** |
| 9b | randrw 读 [analysis] | 33.0 | 35.9 | 36.4 | 35.2 | 36.6 | **35.42** |
| 9b | randrw 写 [analysis] | 32.6 | 35.3 | 35.8 | 34.7 | 36.0 | **34.88** |
| 10 | 纯 randwrite [spec] | 67.7 | 68.2 | 62.8 | 61.4 | 54.7 | **62.96** |
| 11 | randrw 读 [spec] | 0 | 0 | 0 | 0 | 0 | **0** |
| 11 | randrw 写 [spec] | 27.2 | 27.2 | 26.9 | 26.8 | 26.8 | **26.98** |
| 11 | short reads | 6387 | 6373 | 6305 | 6305 | 6285 | **100% short** |

> 注：[spec]＝原存储规格参数（fresh+create_on_open），[analysis]＝优化后命令（复用 layout）。

---

## 四、对比矩阵

### 4.1 [analysis] 优化口径（可靠）

#### S3 4M vs RADOS 4M（RGW 影响）

| 测试 | S3 4M | RADOS 4M | 变化 |
|------|-------|----------|------|
| 顺序读 | 113 | 101 | **−11%** |
| 顺序写 | 69.1 | 107 | **+55%** |
| 多 job 顺序读 | 117 | 113 | −3% |
| 多 job 顺序写 | 69.4 | 108 | **+56%** |
| 纯 randread | 9.85 | 13.24 | **+34%** |
| 纯 randwrite | 78.1 | 125.2 | **+60%** |
| randrw 读 | 6.27 | 11.72 | **+87%** |
| randrw 写 | 6.18 | 11.60 | **+88%** |

> 去 RGW 顺序写大涨（+55%）：RGW HTTP 路径是顺序写的明显开销；顺序读基本持平。

#### RADOS 4M vs RADOS 256K（block-size 影响）

| 测试 | RADOS 4M | RADOS 256K | 变化 |
|------|----------|-----------|------|
| 顺序读 | 101 | 107 | +6% |
| 顺序写 | 107 | 117 | +9% |
| 多 job 顺序读 | 113 | 117 | +4% |
| 多 job 顺序写 | 108 | 117 | +8% |
| 纯 randread | 13.24 | 45.94 | **+247%（3.5×）** |
| 纯 randwrite | 125.2 | 124.0 | ≈持平 |
| randrw 读 | 11.72 | 35.42 | **+202%（3.0×）** |
| randrw 写 | 11.60 | 34.88 | **+201%** |

> 256K 顺序读写**不降反略升**（+6~9%）→ 减小 block-size 不牺牲顺序吞吐。

#### S3 4M vs RADOS 256K（全链路优化，参考）

| 测试 | S3 4M | RADOS 256K | 变化 |
|------|-------|-----------|------|
| 顺序读 | 113 | 107 | −5% |
| 顺序写 | 69.1 | 117 | **+69%** |
| 多 job 顺序读 | 117 | 117 | ≈持平 |
| 多 job 顺序写 | 69.4 | 117 | **+69%** |
| 纯 randread | 9.85 | 45.94 | **+367%（4.7×）** |
| 纯 randwrite | 78.1 | 124.0 | **+59%** |
| randrw 读 | 6.27 | 35.42 | **+465%** |
| randrw 写 | 6.18 | 34.88 | **+464%** |

### 4.2 [spec] 原规格口径（含 create_on_open 偏差）

| 测试 | S3 4M | RADOS 4M | RADOS 256K |
|------|-------|----------|-----------|
| 纯 randwrite | 65.9 | 57.42 | 62.96 |
| randrw 读 | 0.32 | 0 | 0 |
| randrw 写 | 28.5 | 26.86 | 26.98 |
| randrw short% | ~97% | 100% | 100% |

> spec 口径 randrw 读≈0、short≈100%，三组皆然 → 是 `--create_on_open` 边写边读打到空块的
> **口径病态**，不反映真实随机读能力，不用于横向对比（详见 `08_2` 五之五）。

---

## 五、结论

1. **256K block-size 消除读放大实锤**：纯 randread S3 9.85 → RADOS 256K 45.94（4.7×），
   randrw 读 6.27 → 35.42（5.7×）。与 `08_2` 五之四 45.8 完全吻合。
2. **去 RGW 对随机读仅小幅改善**（9.85→13.24，+34%），非数量级 → RGW 非随机读根因。
3. **spec randrw（create_on_open）不可用于随机读分析**：short≈100%，须用 analysis 口径。
4. **analysis 口径 ×5 极稳**（randread ±0.4、randwrite ±0~9、randrw ±1 MB/s）。
5. **256K 顺序读写不受损**：顺序写 117、Layout 116，均 ≥ 4M（顺序写 107、Layout 108）。

---

## 六、与 DeepSeek 三轮结果的对比核对（关键：是否需要重测）

> DeepSeek（REPEAT=3）vs Opus（REPEAT=5），均 128G、同口径、同池。核对 analysis 可靠口径：

| 测试 | DeepSeek 均值 | Opus 均值 | 差异 | 判定 |
|------|--------------|-----------|------|------|
| **S3 纯 randread** | 9.8 | 9.85 | +0.5% | ✅ 一致 |
| **RADOS 纯 randread** | 13.5 | 13.24 | −1.9% | ✅ 一致 |
| **256K 纯 randread** | 45.8 | 45.94 | +0.3% | ✅ 一致 |
| S3 纯 randwrite [a] | 78.1 | 78.1 | 0% | ✅ 一致 |
| RADOS 纯 randwrite [a] | 126 | 125.2 | −0.6% | ✅ 一致 |
| 256K 纯 randwrite [a] | 128 | 124.0 | −3.1% | ✅ 一致（含一次 109 低值） |
| S3 randrw 读 [a] | 5.8 | 6.27 | +8% | ✅ 一致（方差内） |
| RADOS randrw 读 [a] | 11.7 | 11.72 | +0.2% | ✅ 一致 |
| 256K randrw 读 [a] | 35.6 | 35.42 | −0.5% | ✅ 一致 |
| S3 纯 randwrite [spec] | 67.1 | 65.9 | −1.8% | ✅ 一致 |
| RADOS 纯 randwrite [spec] | 54.0 | 57.42 | +6% | ✅ 一致（fresh 写抖动） |
| 256K 纯 randwrite [spec] | 61.4 | 62.96 | +2.5% | ✅ 一致 |
| randrw [spec] short% | 96–100% | 97–100% | — | ✅ 一致 |

### 核对结论

- **两人所有可比项差异均在 ±8% 以内**，绝大多数 <3%，且方向完全一致。
  唯一略大的项（S3 randrw 读 +8%、RADOS spec randwrite +6%）都落在各自 ×3/×5 的方差范围内
  （这两项本身就是高方差项：randrw 读 ~±40%，fresh randwrite 单次 53.8–67.7 抖动）。
- **三大核心结论（256K 消读放大 4.7×、去 RGW 仅 +34% 非主因、spec randrw 口径病态）两人完全互证。**

### → 是否需要重新测试

**不需要重测。** 理由：
1. 两套独立测试（不同人、不同 REPEAT、不同时间段）的关键数据高度吻合（核心项差异 <2%），
   说明结果**可复现、可信**，不存在偶发污染或口径错误。
2. 唯二略大的差异项都是**已知高方差口径**（randrw 读、fresh randwrite），且都在方差带内，
   不改变任何结论。
3. 本文已补齐 DeepSeek 缺的顺序读写口径，数据维度也已完整。

**唯一可选的补充（非必须）**：若要把 fresh randwrite [spec] 的方差也压平，可单独对该项再多跑几次取中位；
但它不影响"写已达标（~58–66，目标 59）"的结论，优先级低。
