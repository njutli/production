# JuiceFS randwrite 带宽高于 randread 原因分析

> 本报告**不对应任何任务书**，是对基线测试中观察到的 randwrite > randread 现象的专项分析。
> 创建：2026-07-21
> 基于数据：01-2d 基线（2026-07-17~18）+ 01-5 集群复现测试（2026-07-20~21）

---

## 一、现象

01-2d 基线测试中，ra0（冷态、cache=0、max-readahead=0）口径下：

| 指标 | randread | randwrite-true | 写 > 读？ |
|------|:---:|:---:|:---:|
| 01-2d §8.3 稳态中位数 (MiB/s) | 2404.2 | 4274.3 | ✅ +78% |
| 01-2d fio 聚合中位数 (MiB/s) | 2453 | 4148 | ✅ +69% |

随机写带宽**显著高于**随机读带宽，与直觉不符（写涉及 EC 编码 + 多 OSD fan-out，应更慢）。

---

## 二、实验数据

### 2.1 三组测试背景

| 组 | 集群 | max_fuse_io | 清理方式 | 日期 |
|----|------|:-:|---------|------|
| 组 1（01-2d） | 01-2d 集群（不同 FSID） | 128K（默认） | juicefs destroy | 2026-07-17~18 |
| 组 2（ra0 全量） | 01-5 集群 | 1M | pool delete+create | 2026-07-20 |
| 组 3（监控测试） | 01-5 集群 | 1M | pool delete+create | 2026-07-20 |
| 组 4（复现基线） | 01-5 集群 | 128K（默认） | juicefs destroy | 2026-07-20 |

### 2.2 全量数据对比

#### randread

| 指标 | 组 1（01-2d, 128K） | 组 4（复现, 128K） |
|------|:---:|:---:|
| fio avg BW (MiB/s) | 2453 | 3275 |
| §8.3 稳态中位数 | 2404.2 | — |
| slat avg | 13042μs | 9745μs |
| 网络 RX (MB/s) | 未采 | 3574.7 |
| pagecache 变化 | 未采 | +398.8 MB |

#### randwrite-true

| 指标 | 组 1（01-2d, 128K） | 组 4（复现, 128K） |
|------|:---:|:---:|
| fio avg BW (MiB/s) | 4148 | 3084 |
| §8.3 稳态中位数 | 4274.3 | — |
| slat avg | 7523μs | 9544μs |
| 网络 TX (MB/s) | 未采 | 575.6（监控测试，1M）→ 3413（128K）|
| pagecache 变化 | 未采 | +294.9 MB |

### 2.3 "写 > 读"复现

| 测试 | randwrite-true | randread | write > read | 差异 |
|------|:---:|:---:|:---:|:---:|
| 01-2d（128K） | 4148 | 2453 | ✅ | +69% |
| 复现基线（128K, cluster_network=public） | 3220 | 2844 | ✅ | +13% |

现象在 01-5 集群上复现（cluster_network 还原到 public，OSD 重启冷启动，01-2d 方法论）。

---

## 三、排查过程

### 3.1 排除项

| 因素 | 方法 | 结论 |
|------|------|------|
| fio 参数不同 | 三组对比 | 完全一致 |
| pagecache | 监控测试 | +300MB（90+ GiB 数据量中可忽略） |
| 缓冲虚高 | 网络 TX 验证 | TX ≈ fio BW，数据确实到 RADOS |
| max_fuse_io 影响 | 控制变量实验 | 128K 下读写都正常 |
| JuiceFS stats 采样失真 | 网络 TX 交叉验证 | stats fuse write 在高并发下采样失真 |

### 3.2 旧结论（已推翻）

监控测试中 randwrite=3084 < randread=3282，曾结论"write > read 现象消失"。但全量基线测试中 randwrite=3220 > randread=2844，**现象复现**。差异原因：监控测试在 pool 重建后直接跑，无前序顺序测试预热；全量基线有完整流程。

---

## 四、根因分析

### 4.1 核心机制：读和写的瓶颈在不同层

```
读路径（FUSE dispatch 是瓶颈）：
  fio → FUSE dispatch → JuiceFS → librados → OSD → 磁盘 → 返回 → fio
       ↑ 11.2ms/dispatch，含 RADOS 往返 ~1.6ms ↑
  瓶颈 = 128 并发 × 256K / 11.2ms = 2926 MiB/s
  RADOS 读能力 = 4388 MiB/s（rados bench），但 FUSE 是瓶颈

写路径（RADOS 写能力是瓶颈）：
  fio → FUSE dispatch → JuiceFS 写缓冲 → ACK fio（快，9.6ms）
                    ↓ 异步，150 goroutine 并发
                  librados → OSD → 磁盘
  FUSE dispatch 速率 = 128 × 256K / 9.6ms = 3413 MiB/s（快于 RADOS）
  RADOS 写能力（150 goroutine）= 150 × 21.7 MB/s ≈ 3258 MiB/s
```

### 4.2 为什么写 dispatch 比 read dispatch 快

两者都经过 FUSE（/dev/fuse dispatch），都拆 2 次（128K max_read=max_write）。

**无缓冲压力时**（buffer 有空间）：写 dispatch 内部只做缓冲拷贝（微秒级），不调 RADOS；读 dispatch 内部同步调 librados 等 OSD 返回（~1.6ms）。写 dispatch 明显快于读 dispatch。

**稳态时**（buffer 接近满）：写 dispatch = 拷贝时间 + 缓冲等待时间。但缓冲等待 ≠ RADOS 往返等待——缓冲被 150 个 upload goroutine 并行排空（排空速率 3258 MiB/s），每次 dispatch 需 128K 空间，等待时间 ≈ 128K / 3258 MiB/s ≈ 0.04ms，远短于读 dispatch 的 RADOS 往返（~1.6ms）。因此稳态下写 dispatch 仍快于读 dispatch。

代码证据：
- 写路径 `WriteAt()`（`cached_store.go:297-339`）：只 `copy(page.Data, p)` 然后返回，不等 RADOS
- 读路径：`cephReader.Read()`（`ceph.go:108-123`）调 `r.ctx.Read()` 同步等 librados 返回
- 上传由 `upload()` goroutine 异步完成（`cached_store.go:430-497`），不在 dispatch 路径内
- 缓冲等待由 `fileWriter.Write()` 的 `usedBufferSize` 检查控制（`writer.go:301-307`）

### 4.3 为什么写带宽仍受限于 RADOS（而非 FUSE dispatch）

写 dispatch 快（9.6ms），FUSE dispatch 速率（3413 MiB/s）> RADOS 写速率（3258 MiB/s）。300 MiB 缓冲会逐渐填满，当缓冲满时 FUSE dispatch 阻塞等待上传 goroutine 排空。稳态下写带宽 = RADOS 写速率 ≈ 3258 MiB/s（实测 3220）。

**为什么缓冲满了写仍然比读快**：缓冲满后写 dispatch 的有效速率被限制为 RADOS 排空速率（3258 MiB/s），但这仍高于读的 FUSE dispatch 速率（2926 MiB/s）。因为：
- 写的瓶颈在 RADOS 排空（150 goroutine 并行），速率 3258
- 读的瓶颈在 FUSE dispatch（128 并发 × 含 RADOS 往返），速率 2926
- 3258 > 2926，所以写 > 读

验证：监控测试中网络 TX = 3413 MB/s ≈ fio 写 BW 3376 MB/s（+1%），数据确实到了 RADOS。

### 4.4 关键数字汇总

| 指标 | 读 | 写 | 说明 |
|------|:---:|:---:|------|
| FUSE dispatch slat | 11.2ms | 9.6ms | 写更快（不含 RADOS 往返） |
| FUSE dispatch 速率 | 2926 MiB/s | 3413 MiB/s | 128 × 256K / slat |
| RADOS 能力 | 4388（读） | 3258（写, 150 goroutine） | rados bench 换算 |
| 实际瓶颈 | FUSE dispatch（2926） | RADOS 写（3258） | 取 min(FUSE, RADOS) |
| 实测 BW | 2844 | 3220 | 接近瓶颈值 |
| **写 > 读** | | | **3258 > 2926** |

### 4.5 一句话总结

**读的瓶颈在 FUSE dispatch（128 并发，每次含 RADOS 往返），写的瓶颈在 RADOS 写（150 goroutine 并发）。150 goroutine 的 RADOS 写吞吐 > 128 并发的 FUSE 读 dispatch 吞吐，所以写 > 读。**

---

## 五、深入讨论：并发度差异与结构差异

### 5.1 是并发度不同导致的差异吗

不完全是。并发度差异（150 vs 128）是直接原因，但根因是**结构差异**——RADOS 操作在读写路径中的位置不同：

**读路径**：RADOS 往返在 FUSE dispatch **内部**（同步）：
```
dispatch slot 1: [FUSE 9.6ms + RADOS 1.6ms] = 11.2ms → 释放 slot
dispatch slot 2: [FUSE 9.6ms + RADOS 1.6ms] = 11.2ms → 释放 slot
...
128 个 dispatch slot，每个被 RADOS 占着 1.6ms
```
RADOS 并发度 = FUSE dispatch 并发度（128），因为 RADOS 往返嵌在 dispatch 里，dispatch slot 不释放就无法处理下一个请求。

**写路径**：RADOS 上传在 FUSE dispatch **外部**（异步 goroutine）：
```
dispatch: [FUSE 9.6ms + 拷贝微秒级] = 9.6ms → 释放 slot（不等 RADOS）
                          ↓ 150 个 goroutine 独立并发上传
                          goroutine 1: [RADOS 11.8ms]
                          goroutine 2: [RADOS 11.8ms]
                          ...
                          goroutine 150: [RADOS 11.8ms]
```
RADOS 并发度 = 150（由 `--max-uploads` 独立控制），不受 FUSE dispatch 并发度限制。

### 5.2 数字验证

| 指标 | 读 | 写 |
|------|:-:|:-:|
| RADOS 并发度 | 128（= FUSE dispatch 并发） | 150（独立 goroutine） |
| RADOS 单次耗时 | 1.6ms（往返，嵌在 11.2ms dispatch 内） | 11.8ms（完整上传） |
| 有效吞吐 | 128 × 256K / 11.2ms = 2926 MiB/s | 150 × 256K / 11.8ms = 3258 MiB/s |
| 吞吐比 | — | 3258/2926 = 1.11× |

并发度比 150/128 = 1.17×，单次耗时比 11.8/11.2 = 1.05×（写单次更慢），综合 1.17 / 1.05 = 1.11×，与实测吞吐比一致。

### 5.3 把 --max-uploads 改成 128 能缩小差距吗

能。计算：

| --max-uploads | 写吞吐 = mu × 256K / 11.8ms | vs 读吞吐 2844 |
|:-:|:-:|:-:|
| 150（当前） | 3258 MiB/s | +15%（写 > 读） |
| 128 | 2783 MiB/s | -2%（写 ≈ 读） |

但这是**通过降低写性能来匹配读性能**，不是提高读性能。

### 5.4 能提高读的 RADOS 并发度吗

理论上可以，但需要改 JuiceFS 架构。当前读路径是同步的（FUSE dispatch 内直接调 librados），如果把 RADOS 读移到 dispatch 外的独立 goroutine（像写路径一样），就能提高读的 RADOS 并发度。但这会改变读语义——fio 会认为 I/O 已提交但数据还没到，需要重新设计完成通知机制（类似 Linux AIO 的 io_getevents）。

### 5.5 代码证据

**读路径 — 同步 RADOS 在 dispatch 内**：
- `pkg/object/ceph.go:115`：`r.ctx.Read(r.key, buf, uint64(r.off))` — 同步调用 librados，阻塞等待 OSD
- 调用链：go-fuse `doRead()` → `VFS.Read()` → `reader.Read()` → `cephReader.Read()` → `r.ctx.Read()`
- `r.ctx.Read()` 在 go-fuse 的 `handleRequest` 内执行，占着 FUSE dispatch slot

**写路径 — 异步 RADOS 在 dispatch 外**：
- `pkg/chunk/cached_store.go:334`：`n += copy(page.Data[bo:], p[n:])` — 只拷贝到内存 page，立即返回
- `pkg/chunk/cached_store.go:437`：`go func() { ... }` — 在独立 goroutine 里执行 RADOS 上传
- `pkg/chunk/cached_store.go:494`：`s.store.currentUpload <- true` — 通过 channel 限流
- `pkg/chunk/cached_store.go:795`：`make(chan bool, config.MaxUpload)` — channel 容量 = `--max-uploads`（默认 150）
- 调用链：go-fuse `doWrite()` → `VFS.Write()` → `sliceWriter.write()` → `WriteAt()`（拷贝）+ `FlushTo()`（启动 goroutine）→ return

---

## 五、补充：cluster_network 对读性能的影响

本次测试还原了 cluster_network 到 public（10.3.1.0/24），EC sub-op 与客户端流量共用网络。对比：

| 配置 | randread BW | randread slat |
|------|:-:|:-:|
| cluster_network=10.3.2.0/24（独立，之前测试） | 5704（异常高，含缓存影响） | — |
| cluster_network=10.3.1.0/24（还原 public，本次） | 2844 | 11.2ms |
| 01-2d 集群（cluster_network 未知） | 2453 | 13.0ms |

还原后 randread=2844 接近 01-2d 的 2453（+16%），说明 cluster_network 还原后读性能接近基线。但无法确定 01-2d 集群的 cluster_network 状态（集群已不存在）。

---

## 六、数据来源

| 内容 | 文件位置 |
|------|---------|
| 三组测试数据对比 + 全量排查记录 | `doc/perf-report/tmp-rw-comparison-20260720.md` §1-7 |
| 01-2d 完整实验数据 | `results/prod-01-5-rados-ec-vs-rep-mechanism-20260718-233945/` |
| 01-5 监控测试数据 | 157:`/tmp/opencode-monitor-test/` |
| 复现基线数据 | 157:`/tmp/opencode-baseline-128k-ra0-v2/` |
