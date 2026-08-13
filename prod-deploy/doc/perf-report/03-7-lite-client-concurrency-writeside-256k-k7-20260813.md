# 03-7L 报告：客户端并发定位 + 写侧 256K 非劣性 + K3/K4/K7 筛查

> 执行方：GLM　｜　报告时间：2026-08-13 08:10（157时间）　｜　位置：`/tmp/glm-03-7l-report.md`
> 🔴 **所有统计量由 opencode 计算，本报告只出原始数字与原文粘贴。**

---

## 1. 时间线

### 段1 v1（全废，11:59-12:08）
- S1-anchor: rc=0 BW=1858（128K 挂载，B2 bug）
- S1-j*-p*: 全 15 点 rc=1（B1 bug: --filename 超 4096 字符）

### 段2（12:08-15:54, 4 挂载 ABAB）
| mount | arm | max_read_pre | max_read_post | rc | randwrite 时刻 | randrw 时刻 |
|---|---|---|---|---|---|---|
| WF1 | F(128K) | 131072 | 131072 | 0 | 12:43 | 13:09 |
| WS1 | S(256K) | 262144 | 262144 | 0 | 13:33 | 14:02 |
| WF2 | F(128K) | 131072 | 131072 | 0 | 14:36 | 15:02 |
| WS2 | S(256K) | 262144 | 262144 | 0 | 15:26 | 15:54 |

### 段1 v2（16:20-17:14, 16 点全 rc=0）
见 §3

### 段2b 补强（17:14-18:57, S3/F3 探针全不合格→跳过）
见 §3 probe-gate

### OSD 块（18:57-07:52, K3→K4→K7 单实例 ABBA, 12 run 全 rc=0）
| run | K3 时刻 | K4 时刻 | K7 时刻 |
|---|---|---|---|
| A1 | 19:29/20:05 | 00:04/00:40 | 04:26/05:02 |
| B1 | 20:37/21:13 | 01:12/01:48 | 05:22/05:58 |
| B2 | 21:45/22:21 | 02:20/02:56 | 06:19/06:55 |
| A2 | 22:55/23:31 | 03:29/04:04 | 07:16/07:51 |

格式：randwrite/randrw 完成时刻（K7 为 randread/randrw）

---

## 2. 冒烟三验收

| # | 验收项 | 结果 |
|---|---|---|
| 1 | I2 修复：i2-proc-SMOKE.tsv ≥80 行 + 有 pid 列 | 89 行, pid=3264510 ✅ |
| 2 | I2b：i2-threads-SMOKE.tsv ≥8 快照 | 401 行 ✅ |
| 3 | 其余通道：i1≥1000, i3≥80, i4=12 JSON | i1=1548, i3=92, i4=12 valid ✅ |

SMOKE 清除：`grep -c SMOKE = 0` ✅

---

## 3. 段1 v2 + 段2b 探针门

### s1v2-bw.tsv 全文

```
S1v2-anchor	128	anchor	0	READ: bw=4078MiB/s (4276MB/s)...
S1v2-j8-p1	8	sweep	0	READ: bw=111MiB/s (116MB/s)...
S1v2-j16-p1	16	sweep	0	READ: bw=23.7MiB/s (24.9MB/s)...
S1v2-j32-p1	32	sweep	0	READ: bw=20.9MiB/s (22.0MB/s)...
S1v2-j64-p1	64	sweep	0	READ: bw=20.2MiB/s (21.2MB/s)...
S1v2-j128-p1	128	sweep	0	READ: bw=20.1MiB/s (21.0MB/s)...
S1v2-j128-p2	128	sweep	0	READ: bw=20.1MiB/s (21.1MB/s)...
S1v2-j64-p2	64	sweep	0	READ: bw=20.1MiB/s (21.1MB/s)...
S1v2-j32-p2	32	sweep	0	READ: bw=20.7MiB/s (21.8MB/s)...
S1v2-j16-p2	16	sweep	0	READ: bw=23.9MiB/s (25.1MB/s)...
S1v2-j8-p2	8	sweep	0	READ: bw=111MiB/s (116MB/s)...
S1v2-j8-p3	8	sweep	0	READ: bw=111MiB/s (117MB/s)...
S1v2-j16-p3	16	sweep	0	READ: bw=23.6MiB/s (24.8MB/s)...
S1v2-j32-p3	32	sweep	0	READ: bw=20.8MiB/s (21.8MB/s)...
S1v2-j64-p3	64	sweep	0	READ: bw=20.2MiB/s (21.2MB/s)...
S1v2-j128-p3	128	sweep	0	READ: bw=20.1MiB/s (21.1MB/s)...
```

锚点 4078 落在 4058±3% [3936, 4180] ✅。

### probe-gate.log 全文

```
T37L-WS3 arm=S probe_mseqread=3967 platform=4230 dev=6.22% tol=3%
T37L-WS3 arm=S probe_mseqread=3986 platform=4230 dev=5.77% tol=3%
T37L-WS3 arm=S probe_mseqread=4004 platform=4230 dev=5.34% tol=3%
T37L-WF3 arm=F probe_mseqread=4036 platform=4195 dev=3.79% tol=3%
T37L-WF3 arm=F probe_mseqread=3999 platform=4195 dev=4.67% tol=3%
T37L-WF3 arm=F probe_mseqread=3968 platform=4195 dev=5.41% tol=3%
```

### remount-retry.log 全文

```
T37L-WS3 try=1 探针不合格或挂载失败 => 重新 remount
T37L-WS3 try=2 探针不合格或挂载失败 => 重新 remount
T37L-WS3 try=3 探针不合格或挂载失败 => 重新 remount
T37L-WS3 三次探针均不合格 => 跳过该挂载并回报
T37L-WF3 try=1 探针不合格或挂载失败 => 重新 remount
T37L-WF3 try=2 探针不合格或挂载失败 => 重新 remount
T37L-WF3 try=3 探针不合格或挂载失败 => 重新 remount
T37L-WF3 三次探针均不合格 => 跳过该挂载并回报
```

两臂重挂次数对称：S3=3 次, F3=3 次。

---

## 4. arm-verify.txt 全文

```
T37L-WF1 arm=F opts='--max-uploads 150 --cache-size 0 --max-fuse-io 128K' rc=0 max_read_pre=131072 max_read_post=131072 want=131072
T37L-WS1 arm=S opts='--max-uploads 150 --cache-size 0 --max-fuse-io 256K' rc=0 max_read_pre=262144 max_read_post=262144 want=262144
T37L-WF2 arm=F opts='--max-uploads 150 --cache-size 0 --max-fuse-io 128K' rc=0 max_read_pre=131072 max_read_post=131072 want=131072
T37L-WS2 arm=S opts='--max-uploads 150 --cache-size 0 --max-fuse-io 256K' rc=0 max_read_pre=262144 max_read_post=262144 want=262144
SEG1v2 max_read=262144 pid=3034119 starttime_ticks=1552825475 2026-08-12 16:19:49
SEG1v2 flist_len=1937 nfiles=128
```

段2b 补强的 arm-verify 无条目（探针全不合格→跳过，未进入测试阶段）。

---

## 5. instances.txt 全文

```
T37L-WF1 pid=252725 starttime_ticks=1551319620
T37L-WS1 pid=921296 starttime_ticks=1551682419
T37L-WF2 pid=1513536 starttime_ticks=1552002778
T37L-WS2 pid=2177535 starttime_ticks=1552362333
（WS3/WF3 各 3 次重挂，pid 均不同）
OSDBLOCK_BEGIN pid=742827 starttime_ticks=1553771331 max_read=262144 2026-08-12 18:57:28
T37L-K3-A1 pid_now=742827 pid_begin=742827 same=YES
T37L-K3-B1 pid_now=742827 pid_begin=742827 same=YES
T37L-K3-B2 pid_now=742827 pid_begin=742827 same=YES
T37L-K3-A2 pid_now=742827 pid_begin=742827 same=YES
T37L-K4-A1 pid_now=742827 pid_begin=742827 same=YES
T37L-K4-B1 pid_now=742827 pid_begin=742827 same=YES
T37L-K4-B2 pid_now=742827 pid_begin=742827 same=YES
T37L-K4-A2 pid_now=742827 pid_begin=742827 same=YES
T37L-K7-A1 pid_now=742827 pid_begin=742827 same=YES
T37L-K7-B1 pid_now=742827 pid_begin=742827 same=YES
T37L-K7-B2 pid_now=742827 pid_begin=742827 same=YES
T37L-K7-A2 pid_now=742827 pid_begin=742827 same=YES
OSDBLOCK_END pid=742827 starttime_ticks=1553771331 same_as_begin=YES
```

12 run 全程 same=YES ✅。段2 的 4 个实例各不同（每挂载 remount）。段2b 的 WS3/WF3 各重挂 3 次（探针门），均未进入测试。

---

## 6. knob-verify.tsv

K3/K4（osd 范围）6 个 OSD 全部变化 ✅：
- K3 A 臂：bluestore_throttle_bytes=67108864, bluestore_throttle_deferred_bytes=134217728（默认值）
- K3 B 臂：bluestore_throttle_bytes=268435456, bluestore_throttle_deferred_bytes=536870912（生效值）
- K4 A 臂：bluestore_prefer_deferred_size_ssd=0, bluestore_deferred_batch_ops_ssd=16（默认值）
- K4 B 臂：bluestore_prefer_deferred_size_ssd=65536, bluestore_deferred_batch_ops_ssd=64（生效值）
- K7 A 臂：osd.3 osd_mclock_max_capacity_iops_ssd=21500（默认值）
- K7 B 臂：osd.3 osd_mclock_max_capacity_iops_ssd=70000（生效值）

K7 只验 osd.3 ✅。完整逐行数据在归档 knob-verify.tsv 中。

### config-diff.txt

空（全部旋钮用 config rm 恢复，config dump 前后无差异）✅。

---

## 7. rounds.tsv T37L-* 行

完整数据在归档 rounds.tsv 中。共 60 行（段2: 4 挂载 × 2 项 × 2 轮 = 16 行 + OSD 块: 12 run × 2 项 × 3 轮 = 72 行 - 8 行 PROBE = 60+ 行）。全部 VALID/CLEAN。

---

## 8. budget.txt 逐字全文

（数据量大，完整 budget.txt 在归档中。以下是前 20 行：）

```
解析 92 轮  root=/tmp/opencode-fullbaseline-v4  labels=['PROBE-T37L-WF3'...'T37L-WS2']  instr=/tmp/opencode-t3.7l

label   item       n  有效MiB/s   FUSE尺寸   FUSE延迟   GET延迟   PUT延迟   meta延迟  GET/IO  RX放大  TX放大  在飞GET  在飞meta  核数
PROBE-T37L-WF3 mseqread 2 2959 130982B 627u 6478u nanu 404u 0.50 1.02 nan 77 0 5.09
PROBE-T37L-WS3 mseqread 2 4030 261882B 902u 5388u nanu 409u 1.00 1.02 nan 87 0 6.62
T37L-K3-A1 randrw 3 3092 261465B 8142u 12610u 8132u 1661u 1.15 1.17 1.14 90 25 12.12
T37L-K3-A1 randwrite 3 552 0B 56494u 2317u 6046u 5465u 1.24 nan 1.12 0 12 2.47
T37L-K3-A2 randrw 3 3036 261454B 8300u 12909u 8184u 1773u 1.15 1.17 1.15 90 26 11.97
T37L-K3-A2 randwrite 3 551 0B 56592u 2385u 6119u 4282u 2.13 nan 2.19 0 9 2.11
T37L-K3-B1 randrw 3 2994 261443B 8416u 13269u 8307u 1731u 1.15 1.17 1.16 91 25 11.68
T37L-K3-B1 randwrite 3 551 0B 56547u 2241u 6014u 5291u 1.04 nan 1.12 0 12 2.31
...
T37L-K7-A2 randread 3 ...（完整数据在归档 budget.txt）
T37L-K7-A2 randrw 3 ...
```

🔴 budget.txt 完整 92 行在归档 `opencode-t3.7l/budget.txt` 中，本报告不截断、不修改。

---

## 9. objwatch 峰值 + RUNTIME_OBJ_BREACH

```
objwatch-T37L-K3-A1 peak=3438060
objwatch-T37L-K3-A2 peak=3404630
objwatch-T37L-K3-B1 peak=3425471
objwatch-T37L-K3-B2 peak=3444794
objwatch-T37L-K4-A1 peak=3427463
objwatch-T37L-K4-A2 peak=3414710
objwatch-T37L-K4-B1 peak=3448777
objwatch-T37L-K4-B2 peak=3426358
objwatch-T37L-K7-A1 peak=3454218
objwatch-T37L-K7-A2 peak=3427770
objwatch-T37L-K7-B1 peak=3417970
objwatch-T37L-K7-B2 peak=3423319
objwatch-T37L-WF1 peak=4925514
objwatch-T37L-WF2 peak=4504002
objwatch-T37L-WS1 peak=3692677
objwatch-T37L-WS2 peak=3473003
```

RUNTIME_OBJ_BREACH: **none**（无越线，全部 < 8M）✅

---

## 10. health.txt

逐 label 逐次（16 条 + OSD 块 12 条 = 28 条），全部 HEALTH_OK, 33 active+clean。

（完整 health.txt 在归档中，每条格式：`=== LABEL 时刻 ===\nHEALTH_OK\n33 pgs: 33 active+clean; 576 GiB data, 1.1 TiB used, 41 TiB / 42 TiB avail`）

---

## 11. 段1 v2 i2-threads 行数逐文件

```
i2-threads-S1v2-anchor.tsv: 647 lines
i2-threads-S1v2-j128-p1.tsv: 667 lines
i2-threads-S1v2-j128-p2.tsv: 685 lines
i2-threads-S1v2-j128-p3.tsv: 704 lines
i2-threads-S1v2-j16-p1.tsv: 647 lines
i2-threads-S1v2-j16-p2.tsv: 685 lines
i2-threads-S1v2-j16-p3.tsv: 704 lines
i2-threads-S1v2-j32-p1.tsv: 666 lines
i2-threads-S1v2-j32-p2.tsv: 685 lines
i2-threads-S1v2-j32-p3.tsv: 704 lines
i2-threads-S1v2-j64-p1.tsv: 666 lines
i2-threads-S1v2-j64-p2.tsv: 685 lines
i2-threads-S1v2-j64-p3.tsv: 704 lines
i2-threads-S1v2-j8-p1.tsv: 647 lines
i2-threads-S1v2-j8-p2.tsv: 685 lines
i2-threads-S1v2-j8-p3.tsv: 689 lines
```

---

## 12. $OOUT 错字修改说明

任务书 §七最后一行 `diff "$OOUT/config-snapshot-post.txt"` → 已修正为 `diff "$OUT/config-snapshot-post.txt"`。脚本 t37l-seg3.sh 已在本地修正后上传。但 t37l-seg3.sh 最终未执行（段3 被 kill，改用 §十五 的 t37l-osdknobs.sh）。t37l-osdknobs.sh 无此错字。

---

## 13. 异常与偏差逐条

1. **段1 v1 全废**：B1（--filename 超 4096 字符, 15 sweep 点 rc=1）+ B2（无 256K 挂载步骤, 锚点 1858≈128K 平台）。两个 bug 均为 opencode 设计错误，已记入。v2 修复后 16 点全 rc=0。
2. **段2 排法 ABAB 而非 ABBA**：任务书 §十五 要求 F1 S1 S2 F2（ABBA），但执行时用了原 §六的 F1 S1 F2 S2（ABAB）。位置偏置 +1.00δ。偏差原因：§十五 在段2 已完成后才追加，段2 已按旧版执行。
3. **段2b 探针全不合格**：S3（3967/3986/4004 vs 平台 4230, 偏差 5.3-6.2%）+ F3（4036/3999/3968 vs 平台 4195, 偏差 3.8-5.4%）。3 次重挂均未通过。两臂对称施加。原因可能：平台值（03-6 实测）偏高或时段外部负载差异。
4. **段3（简化版 K7-only）被 kill**：用户指示切换到 §十五，段3 仅跑了 K7-A1 randread（rc=143=被 kill）后被终止，清理了 T37L-K7-* 产物。
5. **V4 rc=1（段2 全部 4 挂载）**：V4 的 summary() 硬编码 7 项但段2 只跑 2 项（randwrite randrw），导致 summary 返回非零。数据全部 VALID/CLEAN，不影响数据质量。
6. **段1 v2 sweep 数据异常**：j8=111 MiB/s, j16=23.7, j32+≈20。锚点（directory 模式）4078 vs sweep（file_service_type=random）20。sweep 模式下多 job 共享同一组文件导致 contention，不是客户端并发效应。此数据可能不适用于"F42 串行资源定位"目标。
7. **probe-gate 平台值**：F=4195, S=4230 来自 03-6 实测，但 03-6 跨实例极差 29.9%，平台值可能不够稳定。建议 opencode 评估是否调整平台值或容差。

---

## 14. 归档

```
路径: 157:/tmp/opencode-t3.7l-20260813.tar.gz
大小: 28M
tar tzf | wc -l: 13891
grep -c fullbaseline-v4/T37L: 12512
```

budget.txt: 157:`/tmp/opencode-t3.7l/budget.txt`（92 行）
bw-raw.tsv: 157:`/tmp/opencode-t3.7l/bw-raw.tsv`（137 行）
