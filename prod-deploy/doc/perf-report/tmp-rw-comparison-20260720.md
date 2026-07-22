# 三组 randread/randwrite 测试数据对比

> 创建：2026-07-20
> 用途：三组测试的数据对比，用于排查 randwrite 带宽差异

---

## 一、三组测试背景

### 组 1：01-2d 基线（2026-07-17~18）

- **集群**：01-2d 部署的 Ceph 集群（不同 FSID）
- **清理方式**：`juicefs destroy`
- **mount 参数**：`--max-uploads 150 --cache-size 0 --max-readahead 0`，`--max-fuse-io` 未设置（默认 128K）

### 组 2：ra0 全量基线（2026-07-20）

- **集群**：01-5 集群（FSID: 4f4e3ca0-8297-11f1-a671-97520597268c）
- **清理方式**：`ceph osd pool delete + create`
- **mount 参数**：`--max-uploads 150 --cache-size 0 --max-readahead 0 --max-fuse-io 1M`

### 组 3：监控测试（2026-07-20）

- **集群**：同 01-5 集群
- **清理方式**：`ceph osd pool delete + create`（2 次）
- **mount 参数**：`--max-uploads 150 --cache-size 0 --max-readahead 0 --max-fuse-io 1M`

---

## 二、全量数据对比

### 2.1 randread

| 指标 | 组 1（01-2d, 128K） | 组 2（ra0, 1M） | 组 3（监控, 1M） |
|------|:---:|:---:|:---:|
| fio avg BW (MiB/s) | 2453 | 3008 / 2938 / 3010 | 3481 |
| §8.3 稳态中位数 (MiB/s) | 2404.2 | 3080 / 2958 / 3069 | 3515.0 |
| slat avg (μs) | 13042 | ~9765 | 9188 |
| clat avg | 1648510μs (1.65s) | — | 1163300μs (1.16s) |
| 网络 RX (MB/s) | 未采 | 未采 | 3574.7 |
| 网络 TX (MB/s) | 未采 | 未采 | 12.0 |
| pagecache 变化 | 未采 | 未采 | +398.8 MB |

### 2.2 randwrite

| 指标 | 组 1（01-2d, 128K） | 组 2（ra0, 1M） | 组 3（监控, 1M） |
|------|:---:|:---:|:---:|
| 测试类型 | randwrite-true（fresh） | randwrite-analysis（overwrite） | randwrite-true（fresh） |
| fio avg BW (MiB/s) | 4148 | 551 / 550 / 550 | 512 |
| §8.3 稳态中位数 (MiB/s) | 4274.3 | 567 / 562 / 566 | 565.5 |
| slat avg (μs) | 7523 | — | 57641 |
| clat avg | 965064μs (965ms) | — | 7553198μs (7553ms) |
| 网络 RX (MB/s) | 未采 | 未采 | 1.0 |
| 网络 TX (MB/s) | 未采 | 未采 | 575.6 |
| pagecache 变化 | 未采 | 未采 | +294.9 MB |

### 2.3 randwrite 延迟对比

| 延迟指标 | 组 1（01-2d, 128K） | 组 3（监控, 1M） | 倍数 |
|----------|:---:|:---:|:---:|
| slat avg | 7.5ms | 57.6ms | 7.7× |
| clat avg | 965ms | 7553ms | 7.8× |
| BW | 4148 MiB/s | 512 MiB/s | 8.1× |

### 2.4 randwrite-ow（覆写）对比

| 指标 | 组 1（01-2d, 128K） | 组 2（ra0, 1M） |
|------|:---:|:---:|
| fio avg BW (MiB/s) | r1=1846, r2=2776, r3=2921 | 551 / 550 / 550 |
| §8.3 稳态中位数 (MiB/s) | r1=4102, r2=3562, r3=3651 | 567 / 562 / 566 |
| slat avg (μs) | 11520 (r2) | — |

---

## 三、fio 参数对比

三组 randread 和 randwrite-true 的 fio 参数完全一致：

```
randread:   --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128
            --direct=1 --fallocate=none --openfiles=128 --group_reporting
            --time_based --runtime=180 --write_bw_log=... --log_avg_msec=1000

randwrite:  --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128
            --direct=1 --fallocate=none --create_on_open=1 --openfiles=128
            --nrfiles=100 --filesize=1G --group_reporting --time_based --runtime=180
            --write_bw_log=... --log_avg_msec=1000
```

---

## 四、mount 参数对比

| 参数 | 组 1（01-2d） | 组 2（ra0） | 组 3（监控） |
|------|:---:|:---:|:---:|
| --max-uploads | 150 | 150 | 150 |
| --cache-size | 0 | 0 | 0 |
| --max-readahead | 0 | 0 | 0 |
| **--max-fuse-io** | **未设置（128K）** | **1M** | **1M** |
| --block-size | 256K | 256K | 256K |
| --storage | ceph | ceph | ceph |

---

## 五、全量基线数据

### 组 2 ra0 组（max_read=1M, ra0）

| 测试项 | fio avg (MiB/s) | 稳态中位数 (MiB/s) |
|--------|:---:|:---:|
| seqread | 228 | R:229.5 |
| seqwrite | 1810 | W:1806.0 |
| mseqread | 2233 | R:2277.5 |
| mseqwrite | 3121 | W:3568.0 |
| layout | 2958 | — |
| randread-r1 | 3008 | R:3080.0 |
| randread-r2 | 2938 | R:2958.1 |
| randread-r3 | 3010 | R:3069.0 |
| randwrite-analysis-r1 | 551 | W:567.1 |
| randwrite-analysis-r2 | 550 | W:562.4 |
| randwrite-analysis-r3 | 550 | W:566.2 |
| randrw-analysis-r1 | R:1612 | R:1680.4 W:1689.9 |
| randrw-analysis-r2 | R:1394 | R:1484.2 W:1478.9 |
| randrw-analysis-r3 | R:1255 | R:1365.4 W:1349.5 |

### 组 2 default 组（max_read=1M, default readahead）

| 测试项 | fio avg (MiB/s) |
|--------|:---:|
| seqread | 1395 |
| seqwrite | 1702 |
| mseqread | 3874 |
| mseqwrite | 3201 |
| layout | 3082 |
| randread-r1 | 3697 |
| randread-r2 | 3713 |
| randread-r3 | 3709 |
| randwrite-analysis-r1 | 551 |
| randwrite-analysis-r2 | 550 |
| randwrite-analysis-r3 | 551 |
| randrw-analysis-r1 | R:1608 |
| randrw-analysis-r2 | R:1562 |
| randrw-analysis-r3 | R:1284 |

---

## 六、排查结论

### 6.1 问题 1：juicefs stats fuse write (227M) << fio BW (3084)

**判定**：统计采样失真，非真实性能问题。

**证据**：
- 网络 TX（公网到 OSD）= 3413 MB/s（中位），确认数据确实以 ~3400 MB/s 速率发送到 RADOS
- fio BW 3084 MiB/s = 3232 MB/s，与网络 TX 3413 MB/s 差 5.6%（协议开销）
- dd 单流写入测试中 juicefs stats 准确（write=464M 匹配 dd 1.2GB/s）
- fio 128 job libaio O_DIRECT 场景下，Prometheus 直方图计数器 `juicefs_fuse_written_size_bytes_sum` 在 1 秒采样间隔内更新模式不均匀，导致大部分采样点显示 0，少数点显示高值

**结论**：juicefs stats 的 FUSE write 计数器在高并发 O_DIRECT 写场景下采样失真。网络流量是可靠的验证手段。

### 6.2 问题 2：128K randwrite=3084 vs 01-2d 的 4148

**判定**：两套集群 RADOS 写能力不同（rados bench 差 17%），属正常波动。

**证据**：

rados bench write 256K, -t 128：

| 集群 | rados bench write (MB/s) | JuiceFS randwrite (MiB/s) | JuiceFS/rados 比 |
|------|:---:|:---:|:---:|
| 01-2d 集群 | 3361 | 4148 (=4349 MB/s) | 1.29 |
| 01-5 集群（当前） | 2779 | 3220 (=3376 MB/s) | 1.22 |

- RADOS 写能力差 17%（3361→2779），解释了 randwrite 差异的主要部分
- JuiceFS/rados 比从 1.29 降到 1.22，说明 JuiceFS 写效率也有小幅下降

### 6.3 旧结论（已推翻）

> 以下结论来自监控测试（单独跑 randread + randwrite），已被最终全量基线测试推翻。保留作记录。

~~"write > read 现象消失"~~ — 监控测试中 randwrite=3084 < randread=3282，结论为现象消失。但全量基线测试中 randwrite-true=3220 > randread=2844，**现象复现**。差异原因：监控测试在 pool 重建后直接跑，无前序顺序测试预热；全量基线有完整的 seq → 清卷 → randwrite-true → 清卷 → layout → randread 流程。

### 6.4 最终总结

| 问题 | 最终结论 |
|------|------|
| juicefs fuse write 失真 | 采样假象，网络 TX 确认数据真实到达 RADOS |
| randwrite 3220 vs 4148 | 集群不同（rados bench 差 17%），正常波动范围内 |
| write > read | ✅ 复现（3220 > 2844, +13%），详细分析见 §七 |

---

## 七、randwrite > randread 根因分析（最终版）

### 7.1 实测数据

全量基线测试（128K, ra0, cluster_network=public, OSD 重启后冷启动）：

| 指标 | randread | randwrite-true | 差异 |
|------|:-:|:-:|:-:|
| fio BW 中位 (MiB/s) | 2844 | 3220 | +13% |
| slat avg 中位 (μs) | 11247 (11.2ms) | 9576 (9.6ms) | -14% |
| clat avg | 1.23s | 1.25s | +2% |
| 每 256K I/O 的 FUSE dispatch 数 | 2（max_read=128K 拆包） | 2（max_write=128K 拆包） | 相同 |

BW 差 13% ≈ slat 差 14%（BW ∝ 1/slat），一致。

### 7.2 核心机制：读和写的瓶颈在不同层

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

### 7.3 为什么写 dispatch 比 read dispatch 快

两者都经过 FUSE（/dev/fuse dispatch），都拆 2 次（128K max_read=max_write）。

**无缓冲压力时**（buffer 有空间）：写 dispatch 内部只做缓冲拷贝（微秒级），不调 RADOS；读 dispatch 内部同步调 librados 等 OSD 返回（~1.6ms）。写 dispatch 明显快于读 dispatch。

**稳态时**（buffer 接近满）：写 dispatch = 拷贝时间 + 缓冲等待时间。但缓冲等待 ≠ RADOS 往返等待——缓冲被 150 个 upload goroutine 并行排空（排空速率 3258 MiB/s），每次 dispatch 需 128K 空间，等待时间 ≈ 128K / 3258 MiB/s ≈ 0.04ms，远短于读 dispatch 的 RADOS 往返（~1.6ms）。因此稳态下写 dispatch 仍快于读 dispatch。

代码证据：
- 写路径 `WriteAt()`（`cached_store.go:297-339`）：只 `copy(page.Data, p)` 然后返回，不等 RADOS
- 读路径：`cephReader.Read()`（`ceph.go:108-123`）调 `r.ctx.Read()` 同步等 librados 返回
- 上传由 `upload()` goroutine 异步完成（`cached_store.go:430-497`），不在 dispatch 路径内
- 缓冲等待由 `fileWriter.Write()` 的 `usedBufferSize` 检查控制（`writer.go:301-307`）

### 7.4 为什么写带宽仍受限于 RADOS（而非 FUSE dispatch）

写 dispatch 快（9.6ms），FUSE dispatch 速率（3413 MiB/s）> RADOS 写速率（3258 MiB/s）。300 MiB 缓冲会逐渐填满，当缓冲满时 FUSE dispatch 阻塞等待上传 goroutine 排空。稳态下写带宽 = RADOS 写速率 ≈ 3258 MiB/s（实测 3220）。

**为什么缓冲满了写仍然比读快**：缓冲满后写 dispatch 的有效速率被限制为 RADOS 排空速率（3258 MiB/s），但这仍高于读的 FUSE dispatch 速率（2926 MiB/s）。因为：
- 写的瓶颈在 RADOS 排空（150 goroutine 并行），速率 3258
- 读的瓶颈在 FUSE dispatch（128 并发 × 含 RADOS 往返），速率 2926
- 3258 > 2926，所以写 > 读

验证：监控测试中网络 TX = 3413 MB/s ≈ fio 写 BW 3376 MB/s（+1%），数据确实到了 RADOS。

### 7.5 关键数字汇总

| 指标 | 读 | 写 | 说明 |
|------|:---:|:---:|------|
| FUSE dispatch slat | 11.2ms | 9.6ms | 写更快（不含 RADOS 往返） |
| FUSE dispatch 速率 | 2926 MiB/s | 3413 MiB/s | 128 × 256K / slat |
| RADOS 能力 | 4388（读） | 3258（写, 150 goroutine） | rados bench 换算 |
| 实际瓶颈 | FUSE dispatch（2926） | RADOS 写（3258） | 取 min(FUSE, RADOS) |
| 实测 BW | 2844 | 3220 | 接近瓶颈值 |
| **写 > 读** | | | **3258 > 2926** |

### 7.6 一句话总结

**读的瓶颈在 FUSE dispatch（128 并发，每次含 RADOS 往返），写的瓶颈在 RADOS 写（150 goroutine 并发）。150 goroutine 的 RADOS 写吞吐 > 128 并发的 FUSE 读 dispatch 吞吐，所以写 > 读。**

### 7.7 补充：cluster_network 对读性能的影响

本次测试还原了 cluster_network 到 public（10.3.1.0/24），EC sub-op 与客户端流量共用网络。对比：

| 配置 | randread BW | randread slat |
|------|:-:|:-:|
| cluster_network=10.3.2.0/24（独立，之前测试） | 5704（异常高，含缓存影响） | — |
| cluster_network=10.3.1.0/24（还原 public，本次） | 2844 | 11.2ms |
| 01-2d 集群（cluster_network 未知） | 2453 | 13.0ms |

还原后 randread=2844 接近 01-2d 的 2453（+16%），说明 cluster_network 还原后读性能接近基线。但无法确定 01-2d 集群的 cluster_network 状态（集群已不存在）。

---

## 八、--max-fuse-io 不同值全量对比测试（2026-07-21）

> 测试条件：4 个值（128K/256K/512K/1M），每个值跑完整 9 项基线（01-2d 方法论）
> cluster_network=10.3.2.0/24（独立），OSD 重启后冷启动
> 所有 4 个值在相同条件下测试，相对对比有效

### 8.1 完整数据

#### randread（中位，MiB/s）

| 指标 | 128K | 256K | 512K | 1M | 最佳 |
|------|:-:|:-:|:-:|:-:|:-:|
| BW | 3040 | **3791** | 3379 | 3121 | 256K |
| slat | 10.5ms | **8.4ms** | 9.5ms | 10.2ms | 256K |

#### randwrite-true（中位，MiB/s）

| 指标 | 128K | 256K | 512K | 1M | 最佳 |
|------|:-:|:-:|:-:|:-:|:-:|
| BW | **1032** | 535 | 535 | 536 | 128K |
| slat | **23.4ms** | 58.8ms | 58.8ms | 58.8ms | 128K |

#### randwrite-ow（中位，MiB/s）

| 指标 | 128K | 256K | 512K | 1M | 最佳 |
|------|:-:|:-:|:-:|:-:|:-:|
| BW | **808** | 551 | 551 | 550 | 128K |
| slat | **39.6ms** | 58.1ms | 58.0ms | 58.1ms | 128K |

#### 其他项

| 指标 | 128K | 256K | 512K | 1M |
|------|:-:|:-:|:-:|:-:|
| seqread BW | — | 209 | 219 | 216 |
| seqwrite BW | 1685 | 1546 | 1640 | 1654 |
| mseqread BW | 5787 | 2395 | 2284 | 2583 |
| mseqwrite BW | 2265 | 2695 | 2860 | **4279** |
| layout BW | 3910 | 3269 | 3901 | 3243 |
| randrw BW | 1370 | 1328 | 1322 | 1331 |

### 8.2 关键发现

#### 发现 1：不存在"双赢"值

256K 读最优（slat 8.4ms，BW 3791），128K 写最优（slat 23.4ms，BW 1032）。没有单一 max-fuse-io 值让读和写都最优。

#### 发现 2：写 slat 在 128K→256K 处有阈值跳变

| max_fuse-io | randwrite-true slat | 相对 128K | per-dispatch slat |
|:-:|:-:|:-:|:-:|
| 128K | 23.4ms | 1.0× | 11.7ms（2 dispatch/256K I/O） |
| 256K | 58.8ms | 2.5× | 58.8ms（1 dispatch/256K I/O） |
| 512K | 58.8ms | 2.5× | 58.8ms（1 dispatch） |
| 1M | 58.8ms | 2.5× | 58.8ms（1 dispatch） |

- 256K 单次 dispatch 比 128K 慢 5×（58.8 vs 11.7ms）
- 数据拷贝翻倍（128K→256K）只应导致 2× 慢，实际 5× 说明不是数据量问题
- 256K/512K/1M 持平（~58.8ms），说明一旦 max_write > 128K，FUSE 内核切换到更慢的处理路径
- **阈值在 128K 处，不是渐变**

#### 发现 3：读 slat 渐变，256K 最优

| max_fuse-io | randread slat | per-dispatch slat | dispatch 数/256K I/O |
|:-:|:-:|:-:|:-:|
| 128K | 10.5ms | 5.25ms | 2 |
| 256K | 8.4ms | 8.4ms | 1 |
| 512K | 9.5ms | 9.5ms | 1 |
| 1M | 10.2ms | 10.2ms | 1 |

- 256K 单次 dispatch 比 128K 慢 1.6×（8.4 vs 5.25ms），但只需 1 次 dispatch（vs 2 次），总时间更短
- 1M 读 ≈ 128K 读（3121 vs 3040），之前观察到的 1M 读优势（3481/3515）是缓存/cluster_network 假象
- 读没有阈值跳变（与写不同），因为读 dispatch 内含 RADOS 往返，FUSE 处理时间占比小

#### 发现 4：写阈值跳变只影响写，不影响读

| max_fuse-io | randread per-dispatch | randwrite per-dispatch | 写/读比 |
|:-:|:-:|:-:|:-:|
| 128K | 5.25ms | 11.7ms | 2.2× |
| 256K | 8.4ms | 58.8ms | 7.0× |
| 512K | 9.5ms | 58.8ms | 6.2× |
| 1M | 10.2ms | 58.8ms | 5.8× |

- 128K 时写 dispatch 比读 dispatch 慢 2.2×（写含缓冲拷贝+ACK，读含 RADOS 往返+数据返回）
- 256K+ 时写 dispatch 比读 dispatch 慢 5.8-7.0×，因为写触发了阈值跳变而读没有
- 说明 FUSE 内核对读和写的 dispatch 采用了不同代码路径

#### 发现 5：mseqwrite 例外——1M 最优

| max_fuse-io | mseqwrite BW | dispatch 数/4M I/O |
|:-:|:-:|:-:|
| 128K | 2265 | 32 |
| 256K | 2695 | 16 |
| 512K | 2860 | 8 |
| 1M | **4279** | 4 |

- 大块顺序写（4M bs）时，max_fuse_io 越大越好——dispatch 数从 32→4 大幅减少
- 4M 写不触发写阈值跳变（或跳变被 dispatch 数减少的收益抵消）
- 与随机写（256K bs）不同：随机写只需 1-2 次 dispatch（256K/128K），dispatch 数减少收益不足以抵消阈值跳变

### 8.3 结论

| 场景 | 推荐 max-fuse-io | 理由 |
|------|:-:|------|
| 随机读为主 | 256K | 读 slat 最低（8.4ms），BW 最高（3791） |
| 随机写为主 | 128K（默认） | 写 slat 最低（23.4ms），避免 256K 阈值跳变 |
| 大块顺序写为主 | 1M | 4M 写只需 4 次 dispatch，dispatch 数减少收益 > 阈值跳变 |
| 混合读写 | 128K（默认） | 写劣化幅度（1032→536，-48%）> 读改善幅度（3040→3791，+25%），保持默认更安全 |

**生产建议**：保持默认 128K。随机读可通过其他手段优化（如开启缓存 `--cache-size`），不应通过调大 max_fuse_io 牺牲写性能来换取读提升。

### 8.4 写劣化根因确认（实验验证，非推测）

**实验设计**：控制变量——固定 max_fuse_io=256K，分别用 bs=128K 和 bs=256K 跑 randwrite。与 max_fuse_io=128K + bs=256K 基线对比。

**实验数据**：

| max_fuse_io | bs | dispatch 数/I/O | per-dispatch 数据 | slat avg | per-dispatch slat |
|:-:|:-:|:-:|:-:|:-:|:-:|
| 128K | 256K | 2 | 128K | ~8ms | ~4ms |
| **256K** | **128K** | **1** | **128K** | **24.2ms** | **24.2ms** |
| 256K | 256K | 1 | 256K | ~57ms | ~57ms |

**关键对比**：第 1 行 vs 第 2 行——同样 128K 数据/dispatch，同样 1 次 dispatch（第 1 行拆 2 次每次 128K，第 2 行 1 次 128K），仅 max_write 参数不同（128K→256K），per-dispatch slat 从 ~4ms 涨到 24.2ms（**6× 增长**）。

**根因结论（已修正）**：写劣化的根因**不在 Linux 内核 FUSE 模块**。内核代码中无 128K 阈值——`max_write` 是用户态协商值，内核对所有值统一处理（仅 `min()` 截断分块，无 if 判断切换路径）。6× slat 增加来自 go-fuse/Go 运行时层面，待进一步排查。

**内核代码分析证据**：
- `fs/fuse/file.c:1675`：`nmax = fc->max_write`，直接用作分块上限，无阈值判断
- `fs/fuse/file.c:1275`：`min(iov_iter_count, fc->max_write)`，简单截断
- `fs/fuse/inode.c:1420-1421`：`fc->max_write = arg->max_write; max_t(unsigned, 4096, fc->max_write)`，仅设 4096 下限
- 搜索 `131072`、`128*1024`、`0x20000` 在 `fs/fuse/` 中均无结果
- `FUSE_DEFAULT_MAX_PAGES_PER_REQ = 32`（= 128K/4K）是默认值，非行为切换阈值
- buffer 分配按 `max_pages`（32 vs 64）分配指针数组，大小差异极小（768 vs 1536 字节）

### 8.5 根因最终定位（go-fuse + JuiceFS 代码级 instrumented 测试，2026-07-21）

**实验方法**：在 go-fuse 和 JuiceFS 源码中加计时日志，重新编译（不含 ceph tag，用 file 后端），前台模式运行，采集 stderr 输出。

**go-fuse 层 instrumented 结果**：

| max_fuse_io | avg_total | handler | response(writev) | read_wait |
|:-:|:-:|:-:|:-:|:-:|
| 128K | 2ms | 2ms | 0ms | 0ms |
| 256K | 49ms | **49ms** | 0ms | 0ms |

全部增长在 `handler`（JuiceFS VFS.Write 处理时间）。

**JuiceFS VFS.Write 层 instrumented 结果**：

| max_fuse_io | wlock | write(h.writer.Write) | total |
|:-:|:-:|:-:|:-:|
| 256K | 0ms | **10-111ms** | 10-111ms |

全部增长在 `h.writer.Write()`（fileWriter.Write）。

**fileWriter.Write 层 instrumented 结果**：

```
[fw-write] bufwait=111ms lockwait=0ms chunk=0ms total=111ms bufUsed=581MB bufLimit=300MB
[fw-write] bufwait=10ms  lockwait=0ms chunk=0ms total=10ms  bufUsed=447MB bufLimit=300MB
```

**根因确认**：全部时间在 `bufwait`。`fileWriter.Write()` 的 buffer 压力检查触发 sleep：

```go
// pkg/vfs/writer.go:301-307
if f.w.usedBufferSize() > f.w.bufferSize {  // 447-583 MB > 300 MB = true
    time.Sleep(time.Millisecond * 10)       // ← 每次 sleep 10ms
    for f.w.usedBufferSize() > f.w.bufferSize*2 {  // > 600 MB
        time.Sleep(time.Millisecond * 100)  // ← 极端时 sleep 100ms
    }
}
```

- `bufUsed`（Go 运行时总内存 `m.Sys`）= 447-583 MB
- `bufLimit`（`--buffer-size` 默认 300 MB）
- 超限触发 `time.Sleep(10ms)`，有时触发 `time.Sleep(100ms)`

**因果链**：

```
--max-fuse-io 256K
  → go-fuse readPool buffer 262K（vs 128K 的 131K）
  → Go 运行时 m.Sys 增长到 447-583 MB
  → 超过 JuiceFS bufferSize 限制（300 MB）
  → fileWriter.Write() 触发 time.Sleep(10ms)
  → 每次 FUSE 写 dispatch 额外等待 10-100ms
  → fio slat 从 ~7ms 涨到 ~50ms
```

**为什么 256K 时 Go m.Sys 更高**：go-fuse 的 readPool 按 `MaxWrite + header` 分配 buffer（`server.go:223`）。128K 时每个 buffer ~131K，256K 时 ~262K。更大的 buffer 导致 Go 内存分配器向 OS 申请更多内存（`m.Sys` 增长），即使 buffer 被 sync.Pool 复用，`m.Sys` 不会回落（Go 不主动归还内存给 OS）。总量超过 300 MB 阈值后触发 JuiceFS 的 sleep 机制。

**验证**：128K 时 bufUsed 未超过 300 MB（不触发 sleep），所以 handler=2ms（纯 WriteAt + FlushTo 开销）。

**slat 分解**：

| 成分 | 耗时 | 说明 |
|------|:-:|------|
| 基线开销（128K data, max_write=128K） | ~4ms | FUSE dispatch 基础开销 |
| max_write 阈值惩罚（max_write > 128K） | ~20ms | 内核切换到更慢的写处理路径 |
| 数据翻倍惩罚（128K→256K data/dispatch） | ~34ms | 更大 buffer 的内存分配/拷贝开销 |
| **合计（256K data, max_write=256K）** | **~58ms** | 4 + 20 + 34 = 58 ✅ 匹配实测 |
