# 01-2c Default readahead 补测 Summary

## 任务信息
- 任务书：`doc/perf-tasks/01-2c-default-backfill-task-book.md`
- 执行日期：2026-07-16
- 结果目录：`results/prod-nolimit-default-backfill-20260716-194602/`
- 远端数据（157）：`/tmp/default-backfill/`
- JuiceFS 版本：1.3.1+2025-12-02.e0032b2
- 口径：default readahead（无 `--max-readahead 0`），其余与 ra0 一致

## §2.1 randread D0 读放大诊断

| 指标 | default | ra0（01-2 对照） | 说明 |
|------|---------|-----------------|------|
| fio bw | 1099 MiB/s | 2894 MiB/s | default 仅 ra0 的 38% |
| steady bw | 1114.8 MiB/s | 2876.2 MiB/s | §8.3 稳态中位数 |
| CPU | 368%（3.7核） | 595%（6.0核） | default CPU 更低（吞吐低→IOPS低→CPU低） |
| FUSE read | ~1115 MiB/s | ~2873 MiB/s | FUSE 层读带宽 |
| object GET | 2242 MiB/s | 2871 MiB/s | 后端 GET 带宽 |
| **读放大 GET/fio** | **2.01×** | **1.0×** | default 预读拉 2× 未用数据 |
| FUSE lat | 14.1ms | 5.4ms | default 每次读 2MiB 预读，延迟更高 |
| FUSE ops | ~9200 ops/s | ~22000 ops/s | default 预读合并 IO，ops 更少 |

**结论**：default 预读导致 2.01× 读放大（后端 GET 2242 但 fio 有效仅 1115），用 2× 后端带宽换取顺序读流水线。对随机读，预读全是浪费。

**与报告草稿 A 组 randread 1504 的差异**：本次 steady median = 1114.8，低于报告草稿的 1504。差异原因可能是：① 测试时间不同（01-1 在 07-14，本测试在 07-16），OSD 内部状态变化；② 01-1 是 fresh volume 首跑，本次在多次测试后的卷上。建议以报告草稿 §1.2 A 组 1504 为准（§8.3 口径），本测试的 1115 作为读放大诊断独立参考。

## §2.2 randrw D0-D3 对照

| 档 | 并发 | default R | default W | ra0 R | ra0 W | def/ra0 (R) |
|----|------|----------|----------|-------|-------|-------------|
| D0 | 16384 | 761.9 | 757.4 | 1334.3 | 1339.5 | 57% |
| D1 | 512 | 598.2 | 594.6 | 863.3* | 863.3* | 69% |
| D2 | 128 | 346.2 | 345.8 | 459.5* | 459.5* | 75% |
| D3 | 32 | 212.8 | 212.8 | 254.2* | 254.2* | 84% |

*ra0 D1-D3 为合计/2 估算（01-2b 报告了合计值，R/W=1.0 均衡）

**结论**：
- R/W 均 1:1 均衡（与 ra0 一致）
- default 随并发降低，与 ra0 差距收窄（D0 57% → D3 84%），高并发下预读浪费更显著

## 附带项：数据源统一

- `STAGE-SUMMARY-nolimit.md` 第 199 行已订正：ra0 B 组目录从 `20260714-180604` 改为 `20260715-235631`（01-1 最终版，§8.3 稳态中位数口径）
- `process-baseline-final.py` 的 B 组硬编码 `20260715-235631` 与订正后一致

## 目录结构
```
results/prod-nolimit-default-backfill-20260716-194602/
├── env-snapshot.txt
├── processed-summary.txt
├── test-summary.txt
├── randread-D0-r{1,2,3}-fio.txt
├── randrw-D{0,1,2,3}-r{1,2,3}-fio.txt
└── summary.md (本文件)
```
