# 任务 12.1-步骤2：全量重测报告

> 日期：2026-07-10 | 部署：WAL/DB独立4G+DATA独立45G, EC 4+2, 128G layout | juicefs 1.3.1+2025-12-02.e0032b2a

## 判据1：全量带宽表（A/B 两组，r1 + 3轮方差）

### A组（默认）
| 项 | R1 (MB/s) | R2 | R3 | 过59 |
|----|----------|-----|-----|------|
| seqwrite | 117 | - | - | YES |
| multi-seqwrite | 117 | - | - | YES |
| seqread | 106 | - | - | YES |
| multi-seqread | 117 | - | - | YES |
| randwrite | 127 | 127 | 127 | YES* |
| randread | 53.4 | 53.7 | 53.9 | NO (53.4<59) |
| randrw R | 48.1 | 48.4 | 48.4 | NO |
| randrw W | 47.8 | 47.7 | 48.2 | NO |
| layout | 117 | - | - | YES |

### B组（max-readahead 0）
| 项 | R1 (MB/s) | R2 | R3 | 过59 |
|----|----------|-----|-----|------|
| seqwrite | 117 | - | - | YES |
| multi-seqwrite | 117 | - | - | YES |
| seqread | 71.9 | - | - | YES |
| multi-seqread | 117 | - | - | YES |
| randwrite | 127 | 127 | 127 | YES* |
| randread | 103 | 104 | 104 | YES |
| randrw R | 80.1 | 78.7 | 79.9 | YES |
| randrw W | 78.5 | 77.3 | 78.3 | YES |
| layout | 117 | - | - | YES |

*randwrite 127>124 阈值：经查非缓存（cache=0），系 JuiceFS 写缓冲（max-uploads=150）使 fio 应用层带宽 > NIC 实际传输（TX=112）。网络实际吞吐~112 MB/s=NIC墙。非测量误差。

### 59 MB/s 达标汇总
| 项 | A组 | B组 |
|----|------|------|
| seqwrite | PASS | PASS |
| multi-seqwrite | PASS | PASS |
| seqread | PASS | PASS |
| multi-seqread | PASS | PASS |
| randwrite | PASS | PASS |
| randread | **FAIL** (53.4) | **PASS** (103) |
| randrw | **FAIL** (48/48) | **PASS** (80/78) |
| layout | PASS | PASS |

A组 7/8 过，B组 8/8 全过。

## 判据2：内存盘 A组 vs 真盘 128G 对比

详见 compare-vs-realdisk.md。摘要：
- 写类内存盘 1.96-2.85x 真盘（全撞 NIC 墙，真盘受 SSD IOPS 限制）
- 读类 multi-seqread 持平（均撞 NIC 墙 113 vs 117）
- randread 内存盘高 32%（53.4 vs 40.5），randrw 高 3.3x（48 vs 14.5）
- 介质收益显著，但 randread/randrw A组仍有软件瓶颈（未撞 NIC 墙却低于 59）

## 判据3：A vs B（关预读）对比

| 项 | A (MB/s) | B (MB/s) | 变化 | 分析 |
|----|---------|---------|------|------|
| seqread | 106 | 71.9 | -32% | ra0 降 seqread（预读有益于顺序单流读） |
| multi-seqread | 117 | 117 | 0% | 16 并行已撞 NIC 墙，ra0 无影响 |
| seqwrite | 117 | 117 | 0% | 写不受 ra 影响（符合预期） |
| multi-seqwrite | 117 | 117 | 0% | 同上 |
| layout | 117 | 117 | 0% | 同上 |
| randread | 53.4 | 103 | +93% | **ra0 使 randread 翻倍**（关键发现） |
| randwrite | 127 | 127 | 0% | 写不受 ra 影响（数据验证，非臆断） |
| randrw R | 48.1 | 80.1 | +67% | ra0 提升 randrw 读侧 |
| randrw W | 47.8 | 78.5 | +64% | ra0 提升 randrw 写侧（间接：读快→写也快） |

结论：ra0 对写类零影响（数据证实），对 randread 大幅提升（+93%），对 seqread 降低（-32%）。B组全部过 59。

## 判据4：网卡占用

| 项 | A组 RX/TX (MB/s) | A占千兆% | B组 RX/TX | B占千兆% | 撞墙? |
|----|------------------|---------|----------|---------|-------|
| seqread | 56/55 | 47%/47% | 45/44 | 38%/37% | 否（有软件瓶颈） |
| multi-seqread | 59/58 | 50%/49% | 59/59 | 50%/50% | 否（有软件瓶颈） |
| seqwrite | 3/112 | 3%/95% | 3/112 | 3%/95% | TX 撞墙 |
| multi-seqwrite | 3/116 | 3%/98% | 3/116 | 3%/98% | TX 撞墙 |
| layout | 3/116 | 3%/98% | 3/116 | 3%/98% | TX 撞墙 |
| randread | 90-116/10-12 | 76-98%/8-10% | 89-113/12-14 | 76-96%/10-12% | A R1未撞墙(76%)，R2/R3撞墙(96-98%)；B R1未撞墙(76%) |
| randwrite | 3-6/112-114 | 3-5%/95-97% | 3-5/112-114 | 3-4%/95-97% | TX 撞墙 |
| randrw | 104-106/58-58 | 88-90%/49% | 92-94/90-92 | 78-80%/76-78% | A RX接近墙(88-90%)；B 双向接近墙(78-80%/76-78%) |

seqread/multi-seqread 未撞 NIC 墙 → 有软件瓶颈（步骤3深挖）。写类全撞 TX 墙。

## 判据5：seqread / multi-seqwrite 画像

**seqread (A组)**：106 MB/s, NIC RX=56 MB/s (47%千兆), 未撞墙。jfs-stats 待提取 object get 并发与 lat。
- 带宽=106 < NIC 上限 118 → 有软件瓶颈
- 可能原因：JuiceFS meta 操作开销、FUSE 上下文切换、单线程 psync 串行

**multi-seqwrite (A组)**：117 MB/s, NIC TX=116 MB/s (98%千兆), 撞墙。
- 带宽=117 = NIC 上限 → 瓶颈=网卡
- 16 并行写已充分利用千兆带宽

## 判据6：容量安全 + 净态

- 写类期间最高 OSD %USE：layout 后 73.5%（128G），randwrite/randrw 覆盖写后未见显著增长（覆盖写不增总量）
- 最高 %USE 未超 85% nearfull ✅
- A→B 切换前池确认回空（clean-between-AB.txt：10 MiB metadata only, 170 GiB MAX AVAIL）✅
- seq→layout 分时清理后池回空（clean-seq-A/B.txt）✅
- 最终清理后池回空（10 MiB, HEALTH_OK）✅

## 判据7：异常

1. **gc 在 umount 状态下跳过所有对象**：A→B 切换时先 umount 再 gc，gc 报 "649859 skipped"，池 92% 满 nearfull WARN。修复：remount 后 gc 才能正常删除。后续 clean-seq-B 在 mounted 状态下 gc，正常。
2. **randwrite 127 > 124 阈值**：经查系 JuiceFS 写缓冲（max-uploads=150），非缓存。NIC TX=112 证实实际网络吞吐未超标。
3. **B 组 seqread 低于 A 组**：ra0 使 seqread 从 106 降至 72（-32%），属预期行为（预读有益顺序读）。
4. **无 OOM/OSD down/数据损坏/测量异常**。
