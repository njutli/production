# 任务 12.1 报告：随机读补证 —— `--max-readahead 0` 重测 + 网卡/stats 坐实

> 日期：2026-07-09
> 任务来源：`doc/perf-tasks/task-12_1-randread-readahead-recheck.md`
> 二进制：patched `1.3.1+2025-12-02.e0032b2a`（version.txt 已落盘确认）
> 后端：全内存盘（6 OSD DATA+WAL/DB 全 tmpfs），与上轮 `jfs-cold-mu150` 同环境
> 口径：`--cache-size 0 --max-uploads 150`，单变量对照加/不加 `--max-readahead 0`
> layout：128j × 512M = 64G（tmpfs 限制，与上轮同）；A/B 各自 fresh layout
> 采集：每轮同步采 eno1 RX(/proc/net/dev 字节差分) + juicefs stats + pidstat CPU

---

## 0. 三问结论（先给答案）

### Q1：补 `--max-readahead 0` 后 randread 能否过 59？
**能，且远超。** randread r1（冷态，口径只认 r1）= **98.6 MiB/s**，是 A 组基线 50.7 的 **+94%**，超 59 目标 **1.67 倍**。r2/r3（后台 trash 清理完成后）= 112，触及 object get 天花板。与历史最优（真盘 patch+ra0 77.7，专项 ra0 98.3）持平/超越。

### Q2：网卡打没打满？
**没打满。** 客户端 eno1 RX 稳态 ≈ 117 MB/s ≈ 0.94 Gbps，仅占 10GbE 线速 ~9%。瓶颈是 **object get 天花板（~111 MB/s = rados randread 112）**，不是网络。readahead OFF 后 RX 没有下降（get 天花板不变），但有效读翻倍——因为同样 111 MB/s 的后端带宽从"54% 浪费在随机预读"变成"87-100% 转为有效读"。

### Q3：patch 在当前全内存盘重建环境里是否仍生效？
**仍生效。** 版本号确认含 `1.3.1+2025-12-02.e0032b2a`。放大模式佐证：readahead ON 时 get/fuse=2.18×（若 loadRange 全量读 bug 未修会更糟）；readahead OFF 时 get/fuse=1.0-1.15×（无全块过读，patch 工作正常）。

---

## 1. 基线重现确认（A 组 vs 上轮 jfs-cold-mu150）

| 测试 | 上轮 (jfs-cold-mu150) | A 组（本轮重现） | 对账 |
|------|----------------------|----------------|------|
| randread r1 | 50.7 | 50.7 | ✓ 精确重现 |
| randread r2 | 50.8 | 50.8 | ✓ |
| randread r3 | 51.0 | 51.0 | ✓ |
| randrw r1 R/W | 45.6/45.2 | 45.3/44.9 | ✓（冷态方差内） |
| randrw r2 R/W | — | 46.1/45.6 | — |
| randrw r3 R/W | — | 45.8/45.4 | — |
| seqread | 106 | 101 | ✓（差 5%，冷态正常） |

**结论：基线可重现，上轮数据可靠。** 本轮 A 组补齐了上轮缺失的全部采集（NIC RX + juicefs stats + CPU）。

---

## 2. 单变量对照：A（无 ra0）vs B（+max-readahead 0）

### 2.1 fio 带宽（口径只认 r1；r2/r3 看方差）

| 测试 | A 组 (ra ON) | B 组 (ra OFF) | 变化 | 过 59? |
|------|-------------|--------------|------|--------|
| seqread | 101 | 66.3 | -34% | ✓ 仍过 |
| **randread r1** | **50.7** | **98.6** | **+94%** | **✅ 1.67×** |
| randread r2 | 50.8 | 112 | +120% | （无干扰天花板） |
| randread r3 | 51.0 | 112 | +120% | （无干扰天花板） |
| randrw r1 R | 45.3 | 73.8 | +63% | ✅ |
| randrw r1 W | 44.9 | 72.5 | +62% | ✅ |
| randrw r2 R/W | 46.1/45.6 | 75.3/74.0 | +63%/+62% | ✅ |
| randrw r3 R/W | 45.8/45.4 | 74.9/73.5 | +64%/+62% | ✅ |

**randread r2/r3=112 的注记**：r1=98.6 时仍有后台 trash 删除（清理 A 组遗留 64G 数据，put=14M/del_c=138）争抢后端；r2/r3 删除完成后 obj_get 天花板完全释放，fio=112=fuse_read=obj_get，amp≈1.0×。口径只认 r1=98.6（保守值仍远超 59）。

### 2.2 r2/r3 一致性
A 组 randread 三轮 50.7/50.8/51.0（stddev<0.2，极稳）。B 组 98.6/112/112（r1 受后台干扰略低，r2/r3 干净态一致）。两组采集均 3 轮，数据可靠。

---

## 3. 读放大量化（jfs-stats 稳态 + NIC 实测）

### 3.1 关键稳态指标（row 25，稳态中段）

| 测试 | fuse_read | obj_get | get_c | get_lat | NIC RX | fio R | amp(get/fuse) |
|------|-----------|---------|-------|---------|--------|-------|---------------|
| A-randread-r1 | 51M | 111M | 757 | 287ms | 117.3 | 50.7 | **2.18×** |
| B-randread-r1 | 97M | 111M | 834 | 171ms | 116.9 | 98.6 | **1.15×** |
| B-randread-r2 | 109M | 109M | 878 | 149ms | — | 112 | **1.00×** |
| A-randrw-r1 | 45M | 100M | 657 | 279ms | 107.4 | 45.3 | **2.22×** |
| B-randrw-r1 | 71M | 87M | 636 | 173ms | 94.5 | 73.8 | **1.23×** |

### 3.2 放大倍数解读
- **readahead ON（A 组）**：get/fuse ≈ 2.18-2.22× —— JuiceFS 默认预读对**随机读**做投机性预取，随机模式下预取块几乎全被丢弃，浪费 ~54% 后端带宽。
- **readahead OFF（B 组）**：get/fuse ≈ 1.0-1.23× —— 残余放大仅 EC(2+1)+messenger 开销，与历史"残余 1.51×"方向一致（全内存盘后端延迟低，messenger 开销更小，故略低于 1.51×）。
- **写放大**（put/fuse_write）：A-randrw 59/49=1.20×，B-randrw 87/67=1.30× —— readahead 不影响写放大（readahead 是读侧特性），~1.2-1.3× 为 EC 开销。

### 3.3 瓶颈定位
- **object get 天花板恒定 ~111 MB/s**（A/B 相同），= rados randread 裸能力 112 MB/s。这是后端读带宽上限。
- readahead ON：111 MB/s 中仅 51 MB/s（46%）转为有效读 → fio 53。
- readahead OFF：111 MB/s 中 97-109 MB/s（87-100%）转为有效读 → fio 99-112。
- NIC RX ≈ 117 MB/s ≈ 0.94 Gbps，仅 10GbE 线速 9% —— **不是网络瓶颈**。
- juicefs CPU 148-220%（多核），meta lat 0.68-0.83ms —— **不是 CPU/元数据瓶颈**。
- get_lat：A 组 287-320ms（队列深，浪费预取占满并发）→ B 组 149-173ms（并发给有效读，延迟降）。延迟改善是放大降低的副产物。

---

## 4. seqread 退化分析

readahead OFF 使 seqread 101→66.3（-34%），仍过 59（勉强）。
- 原因：seqread 为 1-job psync iodepth=1，**延迟受限**。readahead ON 时 JuiceFS 顺序预取掩盖单线程往返延迟 → 101；OFF 时每个 256K 读需独立 object get 往返 → 66.3。
- 权衡：顺序读为主的工作负载应保留 readahead；随机读为主必须关。全工作负载过 59 的配置取 readahead=0（seqread 66 勉强过但过）。

> 注：seqread 的 jfs-stats 稳态行受预读突发模式影响，fuse read/obj get 列与时序对齐困难，放大倍数对 seqread 标"未取证"（不影响主结论，seqread 非本任务核心）。

---

## 5. randrw 去向

**不需要单独 12.4 诊断。** readahead OFF 后 randrw R=73.8/W=72.5（r1），双双过 59。
- 历史上 randrw 是"硬骨头"（真盘 19/19，patch/调参无效）。本环境（全内存盘 + readahead OFF）下：
  - 读侧：readahead OFF 使读放大 2.22×→1.23×，读带宽 45→74（+63%）。
  - 写侧：read 放大降低后腾出后端 get/网络容量，写带宽 45→72（+62%）（写本身不受 readahead 影响，受益于后端争抢减少）。
- 全内存盘后端天花板足够高（get+put 合计 ~174 MB/s），randrw R+W=148 MB/s 未触顶。

---

## 6. 总判决与配置建议

### 6.1 验收状态（全内存盘 + cache=0 + mu=150 + max-readahead=0）

| 指标 | 值 (MiB/s) | 过 59? | 来源 |
|------|-----------|--------|------|
| seqread | 66.3 | ✓ | 本轮 B |
| seqwrite | 117 | ✓✅ 2× | 上轮（readahead 不影响写，未重测） |
| multi-seqread | 116 | ✓ | 上轮 |
| multi-seqwrite | 69.8 | ✓ | 上轮（mu=150） |
| layout | 104 | ✓ | 上轮 |
| **randread** | **98.6 (r1) / 112 (r2/r3)** | **✅ 1.67×** | 本轮 B |
| randwrite | 126 | ✓✅ 2.1× | 上轮 |
| **randrw R** | **73.8** | **✅** | 本轮 B |
| **randrw W** | **72.5** | **✅** | 本轮 B |

**全工作负载过 59。** 之前 randread/randrw 未达标**唯一原因**是漏挂 `--max-readahead 0`（readahead 对随机读的 2.2× 放大浪费 54% 后端读带宽），非新放大源、非 patch 回退、非网络墙。

### 6.2 生产配置建议
```
juicefs mount --cache-size 0 --max-uploads 150 --max-readahead 0
```
- 读写全部过 59（全内存盘后端）。
- seqread 因 readahead OFF 有退化（101→66），若顺序读为主的工作负载需重新评估，可考虑 readahead 调参（非 0 非 default 的折中值，留作后续 sweep 任务）。
- 真盘后端（非内存盘）下此配置 seqread 可能跌破 59，需单独验证。

### 6.3 randread 收工
✅ **randread 收工。** 假设坐实：randread 未达标 = 漏关预读，补 `--max-readahead 0` 后 98.6（r1）/112（r2/r3），无新放大源。采集（NIC+stats+CPU）完整佐证瓶颈为 object get 天花板（111=rados 112），readahead OFF 将其有效率从 46% 提至 87-100%。

---

## 7. 异常与注记
1. **B 组 r1 后台 trash 干扰**：清理 A 组遗留 64G 数据时 put/del 活动争抢后端，致 r1=98.6 略低于 r2/r3=112。口径只认 r1（保守），仍远超 59。r2/r3 干净态=天花板，佐证结论稳健。
2. **seqread jfs-stats 放大未取证**：预读突发模式致稳态行时序对齐困难，不影响主结论。
3. **layout 缩小**：128G→64G（tmpfs 152GB 限制），与上轮同口径，不影响对比有效性。
4. **未重测写类**：readahead 是读侧特性，写类上轮已全达标（117/126/104），本轮聚焦读侧，写类沿用上轮数据。
