# Summary: 任务 12.1 随机读补证（--max-readahead 0 重测 + 采集）

> 2026-07-09 | patched 1.3.1+2025-12-02.e0032b2a | 全内存盘后端
> A 组: cache=0 mu=150（基线，重现上轮+补采集）
> B 组: cache=0 mu=150 + --max-readahead 0（单变量）

## 结果

| 测试 | A (ra ON) | B (ra OFF) | 过59? |
|------|-----------|------------|-------|
| seqread | 101 | 66.3 | ✓ |
| randread r1 | 50.7 | **98.6** | ✅ 1.67× |
| randread r2/r3 | 50.8/51.0 | 112/112 | (天花板) |
| randrw R r1-r3 | 45.3/46.1/45.8 | 73.8/75.3/74.9 | ✅ |
| randrw W r1-r3 | 44.9/45.6/45.4 | 72.5/74.0/73.5 | ✅ |

## 三问
1. 补 ra0 后 randread 过 59? → ✅ 98.6(r1)/112(r2-r3)，远超
2. 网卡满? → 未满，RX 117MB/s=0.94Gbps(9%线速)；瓶颈=object get 天花板111=rados112
3. patch 生效? → ✅ 版本确认；raON amp2.2×，raOFF amp1.0-1.15×

## 放大（稳态 get/fuse_read）
- A 组: randread 2.18×, randrw 2.22×（readahead 浪费 54%）
- B 组: randread r1 1.15×, r2 1.00×, randrw 1.23×（残余=EC+msg）

## 判决
- randread 收工：未达标=漏关预读，补 ra0→全过
- randrw 不需 12.4：ra0 后 R/W 双过 59
- 全工作负载过 59 配置：cache=0 mu=150 max-readahead=0
- seqread 退化(101→66)但仍过；顺序读为主的工作负载需权衡
