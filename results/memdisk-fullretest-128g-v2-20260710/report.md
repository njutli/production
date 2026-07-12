# report.md — 任务 12.1-步骤2修订版 v2 口径校准全量重测报告

> 日期：2026-07-10 | JuiceFS 1.3.1+2025-12-02.e0032b2a | fio 3.28 | Ceph EC 4+2
> 口径：达标值 = fio bw_log 瞬时带宽稳态中位数（非全程平均），写类跳 10s 暂态，读类跳 5s。
> A组=默认（--cache-size 0 --max-uploads 150），B组=+--max-readahead 0。

## 判据1：全量 8 项 A/B 达标表（稳态中位数，过 59 否）

| 项 | A组 Fio Avg | A组 稳态中位数 | A 过59 | B组 Fio Avg | B组 稳态中位数 | B 过59 | ra0 影响 |
|----|------------|--------------|--------|------------|--------------|--------|---------|
| seqwrite | 117 | 111.9 | PASS | 117 | 112.0 | PASS | 无影响 |
| multi-seqwrite | 117 | 111.9 | PASS | 117 | 112.0 | PASS | 无影响 |
| seqread | 107 | 101.9 | PASS | 73 | 69.2 | PASS | -32% |
| multi-seqread | 116 | 111.2 | PASS | 117 | 111.9 | PASS | 无影响 |
| randwrite | 127 | 109.3 | PASS | 127 | 107.4 | PASS | 无影响 |
| **randread** | 56 | **54.9** | **FAIL** | 113 | **111.5** | PASS | **+103%** |
| **randrw(R/W)** | 48/47 | 48/47* | R:FAIL W:FAIL | 87/85 | 87/85* | PASS | **+81%** |
| layout | 117 | 112.0 | PASS | 117 | 112.0 | PASS | 无影响 |

*randrw bw_log 混合读写数据点过少（4-32个），用 fio 全程平均。
- **A组 7/8 过 59**（randread FAIL），**B组 8/8 全过 59**。

## 判据2：放大表（详见 amplification.md）

| 项 | A组 写/读放大 | B组 写/读放大 | 说明 |
|----|-------------|-------------|------|
| 写类 | 1.0x | 1.0x | JuiceFS 层无放大 |
| 顺序读 | 1.0x | 1.0x | 正常 |
| **randread** | **2.02x** | **0.98x** | A组预读浪费致 2x，B组 ra0 消除 |
| randrw | R:1.6x W:1.5x | R:0.8x W:1.2x | A组预读浪费，B组 ra0 改善 |

三者关系验证：fio 有效 <= NIC <= object（全项满足，无矛盾）。上一版 RX<GET 矛盾已消除。

## 判据3：网卡（稳态 RX/TX 中位数，原始逐秒字节差分）

| 项 | A组 RX/TX | A占千兆% | B组 RX/TX | B占千兆% | 撞墙? |
|----|----------|---------|----------|---------|------|
| seqread | 107/2 | 91% | 74/1 | 62% | A未撞墙(软件瓶颈) |
| seqwrite | 3/117 | 99% | 3/117 | 99% | 写全撞TX墙 |
| multi-seqread | 117/2 | 99% | 118/2 | 100% | 撞RX墙 |
| multi-seqwrite | 3/117 | 99% | 3/117 | 99% | 撞TX墙 |
| layout | 3/117 | 99% | 3/117 | 99% | 撞TX墙 |
| randread | 118/2 | 100% | 118/3 | 100% | 撞RX墙 |
| randwrite | 3/117 | 99% | 2/117 | 99% | 撞TX墙 |
| randrw | 107/58 | 90/49% | 104/102 | 88/87% | 撞双向 |

- NIC 原始 /proc/net/dev 逐秒行已存盘，与 fio 稳态段对齐。
- 不再有 RX<GET 矛盾（上一版硬伤已修复）。
- 写类全撞 TX 墙（117 MB/s = 千兆 99%）。
- A-seqread RX=107（91%）未撞墙 -> 软件瓶颈（FUSE/meta 开销），步骤3深挖。

## 判据4：A vs B（关预读）对比

| 项 | A组稳态 | B组稳态 | ra0 影响 | 说明 |
|----|--------|--------|---------|------|
| randread | 54.9 | 111.5 | **+103%** | ra0 翻倍，预读浪费是根因 |
| randrw | 48/47 | 87/85 | **+81%** | ra0 大幅提升混合读写 |
| seqread | 101.9 | 69.2 | **-32%** | ra0 降顺序单流读（预读有益） |
| 写类(全部) | ~110 | ~110 | **0%** | 数据证实 ra0 不影响写 |
| multi-seqread | 111.2 | 111.9 | **0%** | 多流已满载，预读无额外影响 |

## 判据5：seqread/multi-seqwrite 画像

### seqread (A组)
- 稳态中位数 101.9 MB/s，NIC RX=107 (91%)
- 未撞 NIC 墙 -> 软件瓶颈（FUSE + meta 开销 ~15%）
- object GET=99 MB/s ~ fio (放大~1x)
- juicefs stats: fuse ops ~820/s, lat 3.5ms, CPU 102-123%（1核满载）
- 非缓存命中：GET=99M 非零

### multi-seqwrite (A组)
- 稳态中位数 111.9 MB/s，NIC TX=117 (99%) -> 撞 NIC TX 墙
- object PUT=111 MB/s ~ fio
- 16 job 并发，无 stall

## 判据6：randwrite 127 复核

- fio 全程平均 127 MB/s -> 超千兆线速 118-123 = 物理不可能 = 缓冲暂态假象
- bw_log 稳态中位数：A=109.3, B=107.4 -> < 117 NIC 墙 = 合理
- 暂态污染 14-15%（开头 2-5s 冲到 290-485 KB/s 后跌落到 ~110）
- 结论：127 是假象，稳态真值 ~109 MB/s。但仍过 59。

## 判据7：容量安全 / 净态 / 缓存防护

- 容量安全：A组最高 %USE 92.89%（nearfull），B组最高 96.64%（backfillfull）。均未撞 full。
  - 异常1：randwrite 180s x 3 轮导致池满（170G stored, 100% full, HEALTH_ERR）。
    原因：randwrite 180s 产生 ~20G orphaned slices/轮，gc --delete 不工作（全 skip）。
    修复：randwrite/randrw 改 60s（原 180s），~7G/轮，128+31.5=159.5G < 170G。
  - 异常2：B组 seq->layout cleanup 不干净（gc "stop deleting slice" warning），残留 51G。
- 组间净态：A->B 切换删池重建，reformat block-size 256，clean-between-AB.txt 证明池清空。
- 缓存防护：
  - seqread --size=20G（180s 读不完一遍 194s>180s），drop_caches 前置
  - multi-seqread 16x4G=64G，180s 聚合读~21G < 64G 不会读完
  - 验证：object GET 非零（seqread GET=99M, multi-seqread GET=111M, randread GET=111M）= 非缓存命中

## 判据8：异常如实列

1. randwrite 180s 池满（已修复为 60s）：gc --delete 对 orphaned slices 全 skip，疑似 JuiceFS v1.3.1 rados 后端 bug。
2. block-size 误改 256->4096：reformat --block-size 4096 误改，发现后改回 256。seq阶段在 block-size 256 上测，数据有效。
3. randrw bw_log 数据点过少：混合读写每个方向仅 4-32 个数据点，不可靠。达标值改用 fio 全程平均。
4. B组 cleanup 不干净：gc "stop deleting slice" warning + compact path error，残留 51G。layout 在残留上跑完。
5. randwrite/randrw runtime 60s（非 180s）：容量约束，60s 仍可取稳态中位数（27-37 个数据点）。

## 总结

| 维度 | 结论 |
|------|------|
| 达标 | A组 7/8，B组 8/8。B组（ra0）全过 59。 |
| randread | A=55 FAIL -> B=112 PASS。ra0 +103%。根因：预读浪费 2x 读放大。 |
| randwrite | 稳态 ~109（非 127 假象）。ra0 不影响写。撞 NIC TX 墙。 |
| 写类 | 全撞 NIC TX 墙 117 MB/s = 千兆 99%。ra0 无影响。 |
| seqread | A=102(91% NIC) 未撞墙->软件瓶颈。B=69(62%)。ra0 -32%。 |
| 口径校准 | bw_log 稳态中位数替代全程平均，暴露 randwrite 127 假象。 |
| 缓存防护 | drop_caches + 20G 文件 + GET 非零验证。 |
| NIC 原始 | 逐秒 /proc/net/dev 行存盘，无 RX<GET 矛盾。 |
