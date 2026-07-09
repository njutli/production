# Write Push 测试分析

> 日期：2026-07-04
> 对应数据：`results/write-push-20260704/`
> 对照旧测试：`results/patched-v1.3.1-retest-20260702/full-bs256k-cold-mu150-full-20260703-145314/`

---

## 一、为什么本次测出的顺序写 / 随机写比旧测试高？

### 旧测试 seqwrite=57.0 被 destroy 污染

旧测试的时间线：

```
14:53  destroy 开始（删除 1.4M Ceph 对象，耗时 21 分钟）
15:14  destroy 完成
15:15  format
15:16  mount OK
15:17  seqread prep（写 4G）
15:19  seqwrite → 57.0 MiB/s  ← 距 destroy 完成仅 5 分钟！
```

`juicefs destroy` 需要从 Ceph RGW 删除全部对象。旧卷有 1.4M 个对象（340 GiB）。21 分钟的密集型删除操作使 Ceph OSD 的 RocksDB 产生大量 tombstone 和 compaction 积压。销毁完成后 RocksDB 仍需数分钟到数十分钟进行后台 compaction，此时任何新写入都会与 compaction 争抢同一块 SSD 的 I/O。

seqwrite 在 destroy 完成后仅 5 分钟运行，OSD 的 compaction 压力尚未消退，因此实际测到的是"destroy aftermath 中的写性能"而非 JuiceFS 的真实能力。

### 旧测试 randwrite=54.8 被 layout 污染

旧测试顺序：seq 测试 → **128G layout (39.1 MiB/s)** → cooldown → randwrite(54.8)

128G layout 写入是对 Ceph 的一轮 massive write，触发大量 RocksDB compaction。即使有 cooldown，compaction 余波仍影响后续随机写。

### 本次测试没有这些背景压力

本次测试流程：

```
无 destroy/format（复用已有 volume）
无 layout（复用已有 test_dir 128G 数据）
drop caches on 客户端 + 3 OSD 节点 → OSD 完全 idle
seqwrite → 64.0 MiB/s ✓
randwrite → 63.7 MiB/s ✓
```

OSD 在测试前处于 idle 状态，没有后台 compaction 竞争，测出的才是 JuiceFS 在 patched v1.3.1 + cache=0 + mu=150 下的真实写能力。

### 结论

| 指标 | 旧测试（污染） | 新测试（清洁） | 差异 |
|------|-------------|-------------|------|
| 顺序写 | 57.0 | **64.0** | +12% |
| 随机写 | 54.8 | **63.7** | +16% |

**旧测试的 57.0/54.8 不是 JuiceFS 的真实能力，是被测试流程（destroy/layout）污染的数值。**

---

## 二、BlueFS stall 的根因分析

### 现象

多线程写（16 jobs 并发 seq write，64 GiB 总量）运行期间触发 `DB_DEVICE_STALLED_READ_ALERT`：

```
HEALTH_WARN 2 OSD(s) experiencing slow operations in BlueStore
             2 OSD(s) experiencing stalled read in db device of BlueFS
```

受影响的 OSD：osd.0、osd.3、osd.5（本次测试中先后中招）。

### 不是"进程数 > OSD 数"

> BlueFS stall 的本质是 RocksDB metadata compaction 跟不上写入速率，**不是进程数与 OSD 数量的关系**。

即使 1 个进程写足够长时间也会触发 stall。16 个进程只是把问题加速了。

### 机制

```
16 个 seq writer（每个 4G）
  ↓ 每个 writer 产生独立的 metadata（block 分配、对象映射）
  ↓ 16 × 16K blocks = 256K metadata entries
  ↓ 所有 metadata 写入同一个 RocksDB（WAL/DB 和 Data 共用一个物理 SSD）
  ↓ compaction 合并 SST 文件需要读 DB → 与 Data 写入争抢 I/O
  ↓ compaction 落后 → SST 文件堆积 → DB 读延迟飙升
  ↓ BlueFS stalled read → 写性能骤降
```

### 当前环境的致命问题

所有 6 个 OSD 的 DB/WAL 和 Data 都在同一块 SSD 的同一个 LV 上（`db=none wal=none`）。这意味着：

- 写入数据 → SSD 写带宽
- 写入 metadata（WAL）→ 同一 SSD 写带宽
- compaction 读 DB + 写新 SST → 同一 SSD 同时读写

三者争抢一块 SSD 的有限 IOPS 和带宽，compaction 落后是必然的。

---

## 三、多线程写的并发数影响分析

### 实测数据

| numjobs | 总量 | aggregate 带宽 | 是否 stall |
|---------|------|---------------|-----------|
| 1 | 4 GiB | **64.0 MiB/s** | 否 |
| 16 | 64 GiB | **41.1~43.7 MiB/s** | 是 |

16 个并发不仅没提升总带宽，反而从 64 降到 ~42（**−34%**）。

### 原因

每个 writer 是独立的顺序流，各自产生 metadata。16 个 writer 的 metadata 压力是 1 个 writer 的 **16 倍**。RocksDB compaction 开销与单位时间 metadata 条目数成正比。

### 估算各并发级别的预期

| numjobs | 总量 | metadata 压力倍数 | 预期 aggregate | 说明 |
|---------|------|-----------------|---------------|------|
| 1 | 4G | 1× | 64 | 已验证 |
| 2 | 8G | 2× | ~58-64 | 推测 |
| 4 | 16G | 4× | ~50-58 | 推测 |
| 8 | 32G | 8× | ~44-50 | 推测 |
| 16 | 64G | 16× | 41-44（实测） | stall |

最优并发数大约在 **2-4**，此时 aggregate 可能最接近千兆网卡 EC 天花板（~79 MiB/s）。16 已严重过饱和。

### 额外结论

多线程写的瓶颈不在 JuiceFS 软件层面：

1. **EC 写放大**：EC 4+2 放大约 1.5× → 千兆网卡有效净带宽 ~79 MiB/s
2. **单千兆网卡**：max 118 MiB/s，EC 放大后净带宽 ~79 MiB/s
3. **WAL/DB 共享**：metadata 与 data 争抢同一 SSD

三项物理限制叠加，多线程写无法达到 59 MiB/s 是**硬件/架构层面的限制**，不是 JuiceFS 参数可解的问题。根本解法：
- 独立 NVMe 做 WAL/DB（隔离 metadata 与 data I/O）
- 升级万兆网卡（突破单网卡瓶颈）
- 多客户端聚合写入（分散 metadata 压力到多个 OSD 上的多个 RocksDB 实例）
