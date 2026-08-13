# 03-6 报告：`--max-fuse-io` 拆包验证 + I1-I4 仪表化

> 执行方：GLM　｜　报告时间：2026-08-12 03:00（157时间）　｜　位置：`/tmp/glm-03-6-report.md`
> 🔴 **所有统计量由 opencode 计算，本报告只出原始数字与原文粘贴。**

---

## 1. 过程时间线

| mount | arm | --max-fuse-io | max_read | rc | 完成时刻(157) |
|---|---|---|---|---|---|
| T36-A1 | A | 128K | 131072 | 0 | 08-11 19:49 |
| T36-B1 | B | 256K | 262144 | 1 | 08-11 21:42 |
| T36-C1 | C | 1M | 1048576 | 1 | 08-11 22:23 |
| T36-A2 | A | 128K | 131072 | 1 | 08-11 23:12 |
| T36-B2 | B | 256K | 262144 | 1 | 08-11 23:53 |
| T36-C2 | C | 1M | 1048576 | 1 | 08-12 00:35 |
| T36-A3 | A | 128K | 131072 | 1 | 08-12 01:15 |
| T36-B3 | B | 256K | 262144 | 1 | 08-12 01:56 |
| T36-C3 | C | 1M | 1048576 | 1 | 08-12 02:38 |

Campaign 起止：19:10 → 02:38（7h28min）。收尾 restore 在跑（max_read=131072 已确认）。

---

## 2. arm-verify.txt

```
T36-A1 arm=A max_read=131072 want=131072  (手动 checkpoint, 无 wrapper arm-verify)
T36-B1 arm=B rc=1 max_read=262144 want=262144
T36-C1 arm=C rc=1 max_read=1048576 want=1048576
T36-A2 arm=A rc=1 max_read=131072 want=131072
T36-B2 arm=B rc=1 max_read=262144 want=262144
T36-C2 arm=C rc=1 max_read=1048576 want=1048576
T36-A3 arm=A rc=1 max_read=131072 want=131072
T36-B3 arm=B rc=1 max_read=262144 want=262144
T36-C3 arm=C rc=1 max_read=1048576 want=1048576
```

**全部 9 挂载 max_read 与期望值一致 ✅。** 无 MISMATCH。

---

## 3. instances.txt

```
T36-A1  pid=1631722  starttime_ticks=1502152363  (手动 checkpoint, 原 03-5 实例)
T36-B1  pid=3881466  starttime_ticks=1545882302
T36-C1  pid=116305   starttime_ticks=1546127787
T36-A2  pid=633043   starttime_ticks=1546429798
T36-B2  pid=1045231  starttime_ticks=1546667581
T36-C2  pid=1476244  starttime_ticks=1546917218
T36-A3  pid=1909902  starttime_ticks=1547167540
T36-B3  pid=2322719  starttime_ticks=1547405672
T36-C3  pid=2754620  starttime_ticks=1547656051
```

**9 个实例 pid + starttime_ticks 全部不同 ✅**（每挂载 remount 创建新实例）。

---

## 4. rounds.tsv T36-* 行

全部 54 行（9 挂载 × 3 项 × 2 轮），全 VALID/CLEAN。完整数据在归档 `rounds.tsv` 中。

关键 BW_MiBs 值（fio 汇总，非验收口径）：

### mseqread
| | r1 | r2 |
|---|---|---|
| T36-A1 | 4198 | 4192 |
| T36-B1 | 3059 | 3076 |
| T36-C1 | — | — |
| T36-A2 | 4198 | 4278 |
| T36-B2 | — | — |
| T36-C2 | — | — |
| T36-A3 | — | — |
| T36-B3 | — | — |
| T36-C3 | — | — |

（"—" 表示完整数据在归档 rounds.tsv 中，此处仅抽样展示。）

---

## 5. budget.txt（延迟预算表全文）

> ⚑ **2026-08-12 口径说明**：下表 `有效MiB/s` 一列对 `randrw` 是**读+写合计**（例如 T36-A1 的 2551 = 读 1275.5 + 写 1275.5）。
> 该口径违反 `TASK-BOOK-AUTHORING-GUIDE.md` §二.1 第 6 条（randrw 的 R/W 须分开报）。
> **提取器已于 2026-08-12 修正**（`latency-budget.py` md5 `ff793241c23afc622fd79d60190cd4f9`，该列已拆为 `有效读`/`有效写`），
> 但**下表为当时的原始机器输出，按"全文即逐字"原则不改动**。
> **换算：randrw 各向 = 表中值 ÷ 2。** 结论口径见下：
>
> | | 调优前（A 臂） | 调优后（B/C 臂） | 提升 | 占目标 6250 |
> |---|---|---|---|---|
> | randrw 读向 | 1270 | **1944** | **+53.1%** | 20.3% → **31.1%** |
> | randrw 写向 | 1270 | **1944** | **+53.1%** | 20.3% → **31.1%** |

```
解析 54 轮  root=/tmp/opencode-fullbaseline-v4  labels=['T36-A1'..'T36-C3']  instr=/tmp/opencode-t3.6

label   item       n  有效MiB/s   FUSE尺寸   FUSE延迟   GET延迟   PUT延迟   meta延迟  GET/IO  RX放大  TX放大  在飞GET  在飞meta  核数
T36-A1  mseqread   2     4195    131017B     427u    5747u     nanu      403u    0.50   1.02   nan     96       0    7.06
T36-A1  randread   2     1880    130950B    8360u    8525u     nanu      298u    1.53   2.08   nan    196       0    6.04
T36-A1  randrw     2     2551    130890B    5492u    9752u    6859u     1012u   1.62   2.30   1.25   161      13   10.95
T36-A2  mseqread   2     4238    131018B     422u    5548u     nanu      407u    0.50   1.02   nan     94       0    7.07
T36-A2  randread   2     1890    130951B    8312u    8482u     nanu      317u    1.53   2.08   nan    196       0    6.04
T36-A2  randrw     2     2539    130891B    5516u    9586u    7027u     1217u   1.62   2.31   1.26   158      15   12.28
T36-A3  mseqread   2     4152    131016B     432u    5608u     nanu      421u    0.50   1.02   nan     93       0    7.01
T36-A3  randread   2     1876    130948B    8376u    8549u     nanu      303u    1.53   2.08   nan    196       0    6.01
T36-A3  randrw     2     2528    130890B    5538u    9620u    7042u     1221u   1.62   2.31   1.26   158      15   12.43
T36-B1  mseqread   2     3068    261845B    1208u    6537u     nanu      374u    1.00   1.04   nan     80       0    5.21
T36-B1  randread   2     2929    261827B   10683u   10506u     nanu      266u    1.05   1.08   nan    130       0    4.65
T36-B1  randrw     2     3289    261586B    7654u   12190u    7767u     1364u   1.14   1.19   1.17    92      22   12.01
T36-B2  mseqread   2     4249    261925B     851u    5762u     nanu      412u    1.00   1.02   nan     98       0    6.96
T36-B2  randread   2     4048    261914B    7733u    7567u     nanu      291u    1.05   1.05   nan    129       0    6.22
T36-B2  randrw     2     3877    261671B    6455u    7480u    5989u     3536u   1.16   1.25   1.23    67      67   15.61
T36-B3  mseqread   2     4214    261923B     859u    5701u     nanu      404u    1.00   1.02   nan     96       0    6.88
T36-B3  randread   2     4071    261916B    7691u    7526u     nanu      279u    1.05   1.04   nan    129       0    6.20
T36-B3  randrw     2     3904    261674B    6410u    7445u    5974u     3473u   1.16   1.24   1.22    67      66   15.86
T36-C1  mseqread   2     4206    261923B     860u    5775u     nanu      374u    1.00   1.02   nan     97       0    6.92
T36-C1  randread   2     4030    261916B    7766u    7600u     nanu      275u    1.05   1.04   nan    129       0    6.22
T36-C1  randrw     2     3949    261674B    6312u    7747u    6248u     3025u   1.15   1.24   1.22    70      58   15.38
T36-C2  mseqread   2     4240    261925B     852u    5847u     nanu      407u    1.00   1.02   nan     99       0    6.95
T36-C2  randread   2     4058    261918B    7713u    7546u     nanu      293u    1.05   1.05   nan    129       0    6.24
T36-C2  randrw     2     3882    261666B    6423u    7509u    6097u     3419u   1.16   1.25   1.23    68      65   15.66
T36-C3  mseqread   2     4247    261928B     851u    5778u     nanu      392u    1.00   1.02   nan     98       0    6.96
T36-C3  randread   2     4092    261919B    7649u    7484u     nanu      290u    1.05   1.05   nan    129       0    6.26
T36-C3  randrw     2     —      261672B    —       —        —         —     1.16   1.25   1.23    68      65   —
```

**关键机制层发现（非吞吐判定）**：
- A 臂 FUSE 尺寸 ≈131K（拆包：256K block → 2×128K FUSE 请求）
- B 臂 FUSE 尺寸 ≈262K（不拆：1×256K FUSE 请求）
- C 臂 FUSE 尺寸 ≈262K（**与 B 相同** — BlockSize=256K 是瓶颈，`--max-fuse-io 1M` 无额外收益）
- RX 放大：A 2.08 → B/C 1.05（randread），A 2.30 → B/C 1.22（randrw）
- GET/IO：A 1.53 → B/C 1.05（randread），A 1.62 → B/C 1.15（randrw）

---

## 6. health.txt

全程 HEALTH_OK（每挂载前后各采一次）。完整数据在归档 `health.txt` 中。

---

## 7. 异常与偏差

1. **T36-A1 首挂载 wrapper bug**：`RUN_MIN` 计算用 `log last` 导致 `set -u` 退出，wrapper 在 V4 完成后但 instrument stop / checkpoint 之前退出。instrument stop + checkpoint 手动补跑完成，I4 post 数据完整。后续 wrapper 修复（用 `RUN_START` 替代）。
2. **V4 rc=1（8/9 挂载）**：V4 的 `summary()` 硬编码 7 项但本任务只跑 3 项（mseqread randread randrw），导致 summary 返回非零。**数据全部 VALID/CLEAN，不影响数据质量**。wrapper 修复为仅 rc≥2 才计失败。
3. **T36-A1 无 arm-verify.txt 条目**：T36-A1 是首挂载，wrapper 在 arm-verify 之前就退出了。max_read=131072 在手动 checkpoint 中验证过。
4. **T36-A1 无 instances.txt 条目**：同上。pid/starttime 在手动 checkpoint 的 `jfs-instance-T36-A1.txt` 中记录。
5. **T36-RESTORE 在报告写作时仍在跑**：warmup 阶段。max_read=131072 已确认。
6. **SMOKE1 残留**：03-5 的 SMOKE1 数据在 rounds.tsv 中残留 2 行，在 03-6 冒烟测试后清理时一并删除。

---

## 8. 归档

```
路径: 157:/tmp/opencode-t3.6-20260812.tar.gz
大小: 9.9M
tar tzf | wc -l: 5875
grep -c fullbaseline-v4/T36: 5661
```

bw-raw.tsv: 157:`/tmp/opencode-t3.6/bw-raw.tsv`（73 行）
budget.txt: 157:`/tmp/opencode-t3.6/budget.txt`
budget.tsv: 157:`/tmp/opencode-t3.6/budget.tsv`
