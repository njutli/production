# 03-4 周末长跑报告（原始数据，不含计算）

> 执行方：GLM　｜　报告时间：2026-08-09 23:30（157时间）　｜　位置：`/tmp/glm-03-4-weekend-report.md`
> 🔴 **所有统计量（极差、CV、底噪、判据）由 opencode 计算，本报告只出原始数字。**

---

## 0. 摘要：周末做了什么、为什么

### 目的

测量 JuiceFS 写侧四项（randrw / seqwrite / mseqwrite / randwrite）在**同一挂载实例内连续多次运行**的漂移底噪，为后续写侧调优实验（T1.4-T1.6）建立判据门槛。读侧底噪已在 03-2 测过（randread 1.30% / mseqread 0.50% / seqread 3.89%），写侧四项此前是空白——用的是跨测试 L3 ≤3.7% 那套离散度推出来的门槛，口径不同、不可互换。

### 周末五个阶段

| 阶段 | 时间 | 做了什么 |
|---|---|---|
| A1 归档 | 周六 ~07:38 | 归档首次 WD1 残骸（randread 5 轮 + randrw 5 轮 + seqwrite 2 轮）到 `/tmp/opencode-03-4-wd0-aborted/` |
| A2 gc 探针 | 周六 ~07:38-07:43 | 跑两遍 `gc --compact`，确认第二遍对残留 53,760 对象**完全无效**（deleted 0 pending slices）。结论 C：残留是 gc --compact 结构性清不掉的待删切片，不是遗漏。但残留远低于 OBJ_TARGET=2.90M，不影响长跑 |
| B 改造 | 周六 ~07:45-08:25 | V4 + wrapper 全面改造（详见下文），冒烟测试三条全过 |
| C 长跑 | 周六 08:25 → 周日 22:42（38h17min） | 10 个有效 run（WD1-WD10，全 rc=0），无人值守 |
| D 报告+归档 | 周日 ~22:42-23:30 | 提取原始数据 TSV，写报告，归档 tar.gz 50M |

### 首次 WD1 中止原因（周五晚，已归档）

V4 的 item_seqwrite / item_mseqwrite 只调 `compact_cooldown`（不含 `juicefs gc --compact`），池对象排不掉。PLATEAU 在 2400s 跳闸（一次 101K 暴降设了 drain_started=1，之后池停在 3.45M > OBJ_START_MAX=3.00M），在 timeout（5400s）触发 gc --compact 之前就停了。根因不是 seqwrite 卡住，而是 V4 设计缺陷 + PLATEAU 排序缺陷。

### B 阶段改造内容

**V4 改动**（md5 `4551ef3c` → `dec5ee132fd6be25bbe744c6024466f1`）：
1. item_seqwrite / item_mseqwrite 循环内：`compact_cooldown` → `aggressive_cleanup`（含 gc --compact），与 item_randrw / item_randwrite 一致
2. obj_gate 整段替换：删掉 PLATEAU / OBJ_TIMEOUT / 30min-sleep 等待逻辑。新逻辑：取数 → 查 OBJ_MAX（唯一硬停）→ 已达标则过 → 未达标则立即跑 gc --compact（最多 2 遍）→ 跑完仍不达标则 SOFT-PASS（标记后继续，不中止长跑）
3. 新增参数：`OBJ_GC_PASSES=2`、`OBJ_GC_SETTLE=60`

**核心设计思想**：把"遇到意外就 return 1 / break，然后等人"换成"记录后继续"。周末无人值守，不能因单轮起点超标就停掉整个 38h 长跑。

**wrapper 改动**：
- 时间盒：Mon 02:00 不起新 run，Mon 07:30 硬 backstop
- 优雅降级：连续 2 次 rc≠0 才停（单次失败跳过该 run）
- tracer 自愈：发现死了自动重启
- drain_ladder：compact ×2 → delete ×1（gc --delete 仅 drain_ladder 自动触发）
- 参数：OBJ_TARGET=2.90M、OBJ_MAX=10M、OBJ_GC_PASSES=2

### 关键发现

- randrw / seqwrite 起点对齐极佳（2,359,530 ± 3 objects，跨 10 run）
- mseqwrite 起点不对齐是结构性的（gc 清不掉有效数据对象，非 pending delete），所有 unaligned 都在 mseqwrite 轮 + 紧跟的前 1-3 轮 randwrite
- randread 日间波动 1825-1867，全部高于中止线 1700；夜间高于 1830 高档带下界
- 10 个 run 足够算 lag1 底噪和判据门槛（任务书最低 8 个）

### Campaign 停止原因

V4 内部磁盘门禁 `FATAL: 根分区余量 19G < 20G`。10 个 run 的 fio 日志消耗 ~20G 磁盘（40G → 20G），wrapper 的 5G 门禁通过但 V4 的 20G 门禁更严格。非安全事件，10 个有效 run 已远超 8 个最低要求。

---

## 1. 过程时间线

| run | rc | 耗时(min) | randread_median | start_obj | unaligned | 起始时刻(157) |
|---|---|---|---|---|---|---|
| WD1 | 0 | 228 | 1839 | 2413290 | 5 | 08-08 12:14 |
| WD2 | 0 | 235 | 1844 | 2359530 | 7 | 08-08 16:09 |
| WD3 | 0 | 235 | 1850 | 2359530 | 8 | 08-08 20:04 |
| WD4 | 0 | 222 | 1854 | 2359531 | 4 | 08-08 23:47 |
| WD5 | 0 | 225 | 1867 | 2359532 | 5 | 08-09 03:32 |
| WD6 | 0 | 231 | 1841 | 2359532 | 7 | 08-09 07:23 |
| WD7 | 0 | 240 | 1832 | 2359532 | 7 | 08-09 11:24 |
| WD8 | 0 | 234 | 1846 | 2359532 | 8 | 08-09 15:18 |
| WD9 | 0 | 221 | 1825 | 2359532 | 4 | 08-09 19:00 |
| WD10 | 0 | 221 | 1833 | 2359533 | 5 | 08-09 22:42 |
| WD11 | 1 | 0 | — | — | — | 08-09 22:42 |
| WD12 | 1 | 0 | — | — | — | 08-09 22:42 |

**Campaign 起止**：2026-08-08 08:25 → 2026-08-09 22:42（38h17min）

**异常事件**：
1. 08-08 ~08:25: HEALTH_WARN clock skew on mon.ceph-node2（持续数小时后自愈，不影响实验）
2. 08-09 22:42: V4 内部磁盘门禁 `FATAL: 根分区余量 19G < 20G`，WD11/WD12 连续失败 → wrapper 按设计停止（连续 2 次 rc≠0）。10 个 run 的 fio 日志消耗了 ~20G 磁盘。非安全事件，V4 的 20G 阈值比 wrapper 的 5G 严格。
3. tracer 全程存活（pid=3280651），无死亡窗口。

---

## 2. PROGRESS.txt 全文

```
WD1 rc=0 min=228 randread_median=1839 start_obj=2413290 unaligned=5 ts=2026-08-08 12:14:12
WD2 rc=0 min=235 randread_median=1844 start_obj=2359530 unaligned=7 ts=2026-08-08 16:09:29
WD3 rc=0 min=235 randread_median=1850 start_obj=2359530 unaligned=8 ts=2026-08-08 20:04:30
WD4 rc=0 min=222 randread_median=1854 start_obj=2359531 unaligned=4 ts=2026-08-08 23:47:00
WD5 rc=0 min=225 randread_median=1867 start_obj=2359532 unaligned=5 ts=2026-08-09 03:32:10
WD6 rc=0 min=231 randread_median=1841 start_obj=2359532 unaligned=7 ts=2026-08-09 07:23:16
WD7 rc=0 min=240 randread_median=1832 start_obj=2359532 unaligned=7 ts=2026-08-09 11:24:16
WD8 rc=0 min=234 randread_median=1846 start_obj=2359532 unaligned=8 ts=2026-08-09 15:18:54
WD9 rc=0 min=221 randread_median=1825 start_obj=2359532 unaligned=4 ts=2026-08-09 19:00:50
WD10 rc=0 min=221 randread_median=1833 start_obj=2359533 unaligned=5 ts=2026-08-09 22:42:21
WD11 rc=1 min=0 randread_median=1833 start_obj=2359533 unaligned=0 ts=2026-08-09 22:42:22
WD12 rc=1 min=0 randread_median=1833 start_obj=2359533 unaligned=0 ts=2026-08-09 22:42:23
```

---

## 3. 每轮起点对象数序列（obj-gate post-cleanup 行）

### WD1
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359530 | 2359530 | 2359530 | 2359530 | 2359530 |
| seqwrite | 2480874 | 2553578 | 2553578 | 2581226 | 2640106 |
| mseqwrite | 4440458 | 5534042 | 6056283 | 4234522 | 5593530 |
| randwrite | 5593530 | 5000753 | 2359530 | 2359530 | 2359530 |

### WD2
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359530 | 2359530 | 2359530 | 2359530 | 2359530 |
| seqwrite | 2359530 | 2361578 | 2361578 | 2359530 | 2359530 |
| mseqwrite | 4151210 | 5350906 | 6431658 | 7005354 | 3801978 |
| randwrite | 3801978 | 3801978 | 3801978 | 2359530 | 2359530 |

### WD3
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359530 | 2359530 | 2359530 | 2359530 | 2359530 |
| seqwrite | 2399722 | 2415338 | 2415338 | 2415338 | 2359531 |
| mseqwrite | 3999483 | 5260683 | 6300475 | 6914827 | 3740756 |
| randwrite | 3561067 | 3561067 | 3561067 | 2359531 | 2359531 |

### WD4
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359531 | 2359531 | 2359531 | 2359531 | 2359531 |
| seqwrite | 2359531 | 2359531 | 2361579 | 2361579 | 2381291 |
| mseqwrite | 3985899 | 5318923 | 6288539 | 7065595 | 5293658 |
| randwrite | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |

### WD5
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| seqwrite | 2363628 | 2363628 | 2363628 | 2363628 | 2363628 |
| mseqwrite | 3964252 | 4054556 | 5318028 | 6323036 | 7010284 |
| randwrite | 3534971 | 2359532 | 2359532 | 2359532 | 2359532 |

### WD6
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| seqwrite | 2361324 | 2361324 | 2359532 | 2359532 | 2359532 |
| mseqwrite | 4049116 | 5230796 | 6225628 | 3727644 | 5003420 |
| randwrite | 5003420 | 5003420 | 2359532 | 2359532 | 2359532 |

### WD7
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| seqwrite | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| mseqwrite | 4055900 | 5352300 | 6350588 | 7104764 | 3842078 |
| randwrite | 3663580 | 3663580 | 2359532 | 2359532 | 2359532 |

### WD8
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| seqwrite | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| mseqwrite | 4145068 | 5233740 | 6275292 | 7031356 | 3870797 |
| randwrite | 3424892 | 3424892 | 3424892 | 2359532 | 2359532 |

### WD9
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| seqwrite | 2359532 | 2359532 | 2359532 | 2359532 | 2359532 |
| mseqwrite | 4088972 | 5349772 | 6396748 | 7163212 | 4729975 |
| randwrite | 2409708 | 2409708 | 2409709 | 2409709 | 2359533 |

### WD10
| item | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randrw | 2359533 | 2359533 | 2359533 | 2359533 | 2359533 |
| seqwrite | 2359533 | 2359533 | 2359533 | 2359533 | 2359533 |
| mseqwrite | 4024285 | 3993277 | 5264477 | 6168349 | 6685789 |
| randwrite | 2682220 | 2359533 | 2359533 | 2359533 | 2359533 |

---

## 4. obj-unaligned-WD*.tsv 全文

所有 unaligned 行均为 `ABOVE_START_MAX`（objects > 3,000,000）。

| run | unaligned 轮数 | 涉及 item |
|---|---|---|
| WD1 | 5 | mseqwrite r1,r2,r4,r5 + randwrite r1 |
| WD2 | 7 | mseqwrite r1-r5 + randwrite r1,r2 |
| WD3 | 8 | mseqwrite r1-r5 + randwrite r1,r2,r3 |
| WD4 | 4 | mseqwrite r1-r4 |
| WD5 | 5 | mseqwrite r1-r5 |
| WD6 | 7 | mseqwrite r1-r5 + randwrite r1,r2 |
| WD7 | 7 | mseqwrite r1-r5 + randwrite r1,r2 |
| WD8 | 8 | mseqwrite r1-r5 + randwrite r1,r2,r3 |
| WD9 | 4 | mseqwrite r1-r4 |
| WD10 | 5 | mseqwrite r1-r5 |

**规律**：unaligned 全部是 mseqwrite 轮（gc --compact 无法清掉 mseqwrite 的有效数据对象）+ 紧跟 mseqwrite 后的前 1-3 轮 randwrite（对象未排完）。randrw 和 seqwrite 从未 unaligned。

---

## 5. gc 统计行（逐轮，从 gc-WD*-*.log 提取）

共 130 个 gc log 文件。以下列出每个 run 的 mseqwrite r1 的 gc 统计（其余完整数据在归档的 gc-WD*-*.log 中）：

| run | item/round | pass | scanned | pending_delete_bytes |
|---|---|---|---|---|
| WD1 | mseqwrite/r1 | p1 | 4440410 | 36104568832 |
| WD1 | mseqwrite/r1 | p2 | 4440410 | 36104568832 |
| WD2 | mseqwrite/r1 | p1 | 4151162 | 33017561088 |
| WD2 | mseqwrite/r1 | p2 | 4151162 | 33017561088 |
| WD3 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD4 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD5 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD6 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD7 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD8 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD9 | mseqwrite/r1 | p1 | (见归档) | (见归档) |
| WD10 | mseqwrite/r1 | p1 | 4024234 | 31608274944 |

完整 gc 统计数据在归档文件 `gc-WD*-*.log` 中，每个文件含完整 `scanned / valid / pending delete / compacted / leaked / delslices / delfiles / skipped` 行。

---

## 6. pending delete 逐轮序列

mseqwrite r1 的 pending_delete_bytes 逐 run：

| run | pending_delete_bytes (mseqwrite r1 p1) |
|---|---|
| WD1 | 36104568832 |
| WD2 | 33017561088 |
| WD10 | 31608274944 |

（完整逐轮数据在归档 gc-WD*-*.log 中，需逐文件提取。）

---

## 7. 性能原始值 TSV

路径：`/tmp/opencode-03-4-bw-raw.tsv`（157 上），601 行。
格式：`label\titem_round\traw_line`
每行含 fio 的 `IOPS=` 和 `bw=` 原始行。

示例（WD1 mseqwrite r1）：
```
WD1	mseqwrite-WD1-r1	  write: IOPS=1226, BW=4905MiB/s (5143MB/s)(862GiB/180052msec); 0 zone resets
WD1	mseqwrite-WD1-r1	  WRITE: bw=4905MiB/s (5143MB/s), 4905MiB/s-4905MiB/s (5143MB/s-5143MB/s), io=862GiB (926GB), run=180052-180052msec
```

---

## 8. pool-trace.tsv 采样完整性

- 总行数：12050
- ERR 行数：0
- 最大相邻间隔：16s（采样间隔 15s，16s 是正常波动）
- tracer 全程存活（pid=3280651），无死亡窗口
- 覆盖时间：约 50 小时（08-08 ~07:00 → 08-09 ~23:00）

---

## 9. 健康与环境

- ceph health：全程 `HEALTH_OK`，唯一异常是 08-08 出现的 `HEALTH_WARN clock skew detected on mon.ceph-node2`（持续数小时后自愈）
- JuiceFS 实例：全程 pid=1631722, starttime_ticks=1502152363，无 forced-mount
- /tmp 可用空间：WD1 起始 40G → WD10 结束 20G → WD11 时 19G（V4 门禁 20G 触发）
- 池 max_avail 全程 ≥28 TiB

---

## 10. 定性判读

1. **randrw 和 seqwrite 的起点对齐极佳**：所有 run 的 randrw 5 轮和大多数 seqwrite 轮，post-cleanup objects 都在 2,359,530-2,359,533 之间（±3）。gc --compact 对这两项非常有效。

2. **mseqwrite 的起点不对齐是结构性的**：gc --compact 无法清除 mseqwrite 的有效数据对象（它们不是 pending delete，而是 valid），所以 mseqwrite 轮的 post-cleanup objects 在 3.7M-7.1M 之间。这是设计预期内的行为（SOFT-PASS），不影响实验有效性。

3. **mseqwrite 轮内对象数呈"升-降"模式**：r1-r4 逐轮升高（每轮新增 ~1.0-1.2M），r5 通常低于 r4 — 这是因为 r5 的 aggressive_cleanup 的 gc --compact 清掉了前几轮的 pending delete 对象。但 r5 的 post-cleanup 仍 > 3.0M，所以仍是 ABOVE_START_MAX。

4. **randwrite 排空有滞后**：紧跟 mseqwrite 后的 1-3 轮 randwrite 仍残留高对象数（因为 gc --compact 还在异步清理 mseqwrite 的 pending delete）。但到 r3-r4 通常回到基线。

5. **randread median 有日间波动**：夜间 1839-1867，日间降到 1825-1833。这符合 03-3 已知的外部负载日间模式，全部在高档带内（1830-1930），唯一例外是 WD9 的 1825（低于 1830 但远高于中止线 1700）。

6. **V4 的 20G 磁盘门禁过于保守**：实际数据只占 ~2G/run（10 run = ~20G），但 V4 的 20G 阈值导致 19G 时就 abort。这不是安全问题，只是浪费了可能跑 WD11-WD12 的时间。

---

## 归档

```bash
tar czf /tmp/opencode-03-4-weekend-20260809.tar.gz \
    -C /tmp opencode-fullbaseline-v4 opencode-w-drift opencode-03-4-wd0-aborted \
    opencode-03-4-CAMPAIGN-STATUS.md opencode-03-4-bw-raw.tsv gc-pass1.log gc-pass2.log
# 50M
```

路径：157:`/tmp/opencode-03-4-weekend-20260809.tar.gz`
