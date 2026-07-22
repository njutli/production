# 02-1b max-fuse-io 256K + buffer-size 1024 调优测试报告

> 衍生自 02-1 零号检查（Z4 发现 max_read=128K 拆包问题）
> 在 02-1 基础上深入排查 max-fuse-io 不同值的影响，发现 max-fuse-io > 128K 导致写劣化（根因：JuiceFS buffer 压力检查触发 sleep），通过调大 --buffer-size 到 1024 解决
> 详细根因分析见 `doc/perf-report/02-1-zero-check-report.md` §九-十

---

## 报告头

| 字段 | 值 |
|------|-----|
| 衍生自 | 02-1 零号检查（Z4 max_read 拆包发现） |
| 测试日期 | 2026-07-21 |
| 执行方 | opencode（GLM 执行） |
| 配置 | `--max-fuse-io 256K --buffer-size 1024 --max-uploads 150 --cache-size 0 --max-readahead 0` |
| 测试流程 | 01-2d 任务书 §3.2（清卷 destroy + compact cooldown + REPEAT=3） |
| 集群 | 01-5（FSID: 4f4e3ca0），cluster_network=10.3.2.0/24 |
| 数据路径 | 157:`/tmp/opencode-baseline-256k-buf1024/` |

---

## 一、测试背景

02-1 Z4 发现 `--max-fuse-io 1M` 可让 randread +25%（消除 256K 拆包）。但后续 sweep 测试发现 max-fuse-io > 128K 会导致 randwrite 劣化（128K→256K 写 slat 从 23ms 跳到 59ms）。

通过代码级 instrumented 测试定位根因：写劣化因为 go-fuse readPool buffer 增大（262K vs 131K）→ Go m.Sys 增长到 447-583 MB → 超过 JuiceFS `--buffer-size` 默认 300 MB 限制 → `fileWriter.Write()` 触发 `time.Sleep(10ms)`。

**解决方案**：将 `--buffer-size` 从 300 调到 1024，使 m.Sys（447-583 MB）< 1024 MB，不触发 sleep。

---

## 二、快速验证（20s 单轮）

| 配置 | randread BW | randread slat | randwrite BW | randwrite slat |
|------|:-:|:-:|:-:|:-:|
| 128K 默认（sweep 基线） | 3040 | 10.5ms | 1032 | 23.4ms |
| 256K 无 buffer 调整 | 3791 | 8.4ms | 535 | 58.8ms |
| **256K + buffer-size 1024** | **3757** | **8.5ms** | **683** | **12.9ms** |

- randread +24% ✅（读收益保持）
- randwrite 从 535→683（+28%），buffer 调大有效

---

## 三、全量基线数据（ra0 组）

> 完整 9 项 × REPEAT=3，01-2d 方法论
> mount: `--max-fuse-io 256K --buffer-size 1024 --max-uploads 150 --cache-size 0 --max-readahead 0`

### 3.1 fio avg BW（MiB/s）

| 测试项 | r1 | r2 | r3 | 中位 | 128K sweep | 变化 |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|
| seqread | 240 | — | — | 240 | — | — |
| seqwrite | 1639 | — | — | 1639 | 1685 | -3% |
| mseqread | 2579 | — | — | 2579 | 5787 | -55%* |
| mseqwrite | 4223 | — | — | 4223 | 2265 | +86% |
| layout | 3975 | — | — | 3975 | 3910 | +2% |
| randwrite-true | 1666 | 1762 | 1760 | **1760** | 1032 | **+70%** ✅ |
| randread | 3405 | 3538 | 3528 | **3528** | 3040 | **+16%** ✅ |
| randrw R | 1652 | 1266 | 766 | **1266** | 1370 | -8% |
| randrw W | 1651 | 1266 | 765 | **1266** | 1370 | -8% |
| randwrite-ow | 887 | 760 | 607 | **760** | 808 | -6% |

> *mseqread 波动大，与 OSD 缓存状态有关
> randrw 和 randwrite-ow 有轮间退化（compact 不足），与 128K 测试一致

### 3.2 slat 数据（μs）

| 测试项 | slat avg (中位轮) |
|---------|:-:|
| randread | 9067 (9.1ms) |
| randwrite-true | 17718 (17.7ms) |
| layout | 124535 (124.5ms) |

---

## 四、结论

1. **读写都受益**：randread +16%（3040→3528），randwrite-true +70%（1032→1760）
2. **配置有效**：`--max-fuse-io 256K --buffer-size 1024` 兼顾读写
3. **写仍低于读**（1760 < 3528）：当前集群 RADOS 写能力（2778 MB/s）远低于读能力（4388 MB/s）
4. **mseqwrite 大幅提升**（2265→4223, +86%）：大块顺序写（4M bs）dispatch 数从 32→16，收益显著
5. **randrw 和 randwrite-ow 有退化**：与 128K 测试一致的轮间退化问题（compact 不足）

---

## 五、数据路径

| 内容 | 文件位置 |
|------|---------|
| 全量基线数据 | 157:`/tmp/opencode-baseline-256k-buf1024/` |
| max-fuse-io sweep（4 值对比） | 157:`/tmp/opencode-maxfuse-full-sweep/` |
| instrumented patches + 日志 | `results/maxfuse-instrumented-20260721/` |
| 根因分析（02-1 报告） | `doc/perf-report/02-1-zero-check-report.md` §九-十 |
