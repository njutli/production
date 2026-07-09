# 全内存盘（DATA+WAL/DB 全 tmpfs）后端裸能力上限评估报告

> 日期：2026-07-08
> 配置：6 OSD 全部 DATA+WAL/DB 在 tmpfs（38GB LVM on loop device per OSD）
> 口径：**内存盘=上限评估，非交付基线**；稳态段中位数（sec≥30）；客户端网卡 TX 实测（/proc/net/dev 字节差分）

---

## 0. 执行摘要

| 指标 | 真盘 | WAL/DB tmpfs | **全 tmpfs** | 目标 |
|------|------|-------------|-------------|------|
| 256K write 稳态 | 55 MB/s | 55 MB/s | **112 MB/s** | 59 ✅ |
| IOPS | 207 | 247 | **448** | — |
| op_w_latency | 249ms | 225ms | **17ms** | — |
| state_aio_wait | 55-99ms | 7-99ms | **0.09ms** | — |
| 客户端 NIC TX | ~49 MB/s | ~55 MB/s | **117 MB/s (99%)** | — |
| **墙** | DATA 写 | DATA 写 | **1GbE 网卡** | — |

**核心结论：全内存盘 256K 稳态写 112 MB/s = 95% NIC 线速，是 59 目标的 1.9 倍。IOPS 墙完全在 DATA 写路径——DATA 进内存后墙消失，新墙是客户端 1GbE 网卡（实测 117 MB/s TX = 99%）。**

---

## 1. 配置

- 6 OSD 全部 purge 重建，block 设备 = 38GB tmpfs LVM（loop device）
- DATA + WAL/DB 全部在 tmpfs（`bluefs_single_shared_device=1`，无独立 DB/WAL）
- OSD class = ssd（tmpfs 被正确识别）
- 旧的 RGW/mgr pools 已删除（减少 PG 干扰）
- juicefs-data EC 4+2 pool 重建（32 PGs）
- HEALTH_OK，6 OSD up/in

---

## 2. 写测试

### 2.1 write 256K t64 300s ×3

| 轮 | Bench MB/s | IOPS | Lat(s) | SS median | SS mean | SS std | SS min | SS max |
|----|-----------|------|--------|-----------|---------|--------|--------|--------|
| r1 | 112.06 | 448 | 0.143 | **112.00** | 112.07 | 0.57 | 109.50 | 113.50 |
| r2 | 111.93 | 447 | 0.143 | **112.00** | 111.94 | 0.74 | 107.25 | 116.75 |
| r3 | 111.94 | 447 | 0.143 | **112.00** | 111.96 | 0.56 | 109.25 | 113.50 |

**3 轮稳态中位数：112.00 MB/s**（stddev <0.74，极其稳定）

> 与真盘（stddev 9-14）对比：全内存盘稳态几乎是一条直线（±0.7 MB/s），没有波动。

### 2.2 并发扫描 256K 300s

| 并发 | Bench MB/s | IOPS | SS median |
|------|-----------|------|-----------|
| t16 | 111.65 | 446 | 111.75 |
| t64 | 112.06 | 448 | 112.00 |
| t128 | 111.97 | 447 | 112.00 |

**IOPS 墙完全消失**——t16 已打满网卡，t128 无额外收益。与真盘（t16-t128 全卡在 55-57）形成鲜明对比。

### 2.3 块大小矩阵（write t64 120s ×3）

| 块大小 | 全 tmpfs SS med | 真盘 SS med | 变化 |
|--------|----------------|-----------|------|
| 4K | 110.19 | 5.50 | **+1903%** |
| 64K | 112.38 | 25.91 | **+334%** |
| 256K | 112.00 | 51.12 | +119% |
| 1M | 108.00 | 54.00 | +100% |
| 4M | 104.00 | 56.00 | +86% |

**所有块大小均打满网卡**（104-112 MB/s）。4M 略低（104）因为 per-op 开销在低 IOPS 下占比更大。

---

## 3. 读测试

| 操作 | 全 tmpfs SS med | 真盘 SS med | 变化 |
|------|----------------|-----------|------|
| seq read 256K | 112.25 | 111.9 | 0% |
| rand read 256K | 112.00 | 111.8 | 0% |

> 读带宽与真盘一致（~112 MB/s）——读不受 DATA/WAL/DB 设备影响（预期），两者均被 NIC 限制。

---

## 4. 客户端网卡 TX（实测，清单 §1 关键刀）

**采集方法**：/proc/net/dev eno1 TX 字节差分（清单方法 A），每秒采样。

| 指标 | 值 |
|------|-----|
| avg TX | **116.9 MB/s** |
| median TX | 117.3 MB/s |
| max TX | 118.5 MB/s |
| **占 1GbE (118 MB/s)** | **99%** |

> **实测确认**：客户端网卡 TX = 117 MB/s = 99% 1GbE。网卡是新墙（不是"从带宽推算"，是 /proc/net/dev 字节差分实测）。

---

## 5. perf 分段延迟（全 tmpfs vs 真盘 vs WAL/DB tmpfs）

### 5.1 BlueStore 分段（6 OSD 平均，delta 口径）

| 段 | 真盘 | WAL/DB tmpfs | **全 tmpfs** |
|----|------|-------------|-------------|
| txc_throttle_lat | 0.014ms | 1-15ms | **0.013ms** |
| state_aio_wait_lat | 55-99ms | 7-99ms | **0.09ms** |
| state_kv_queued_lat | 24-55ms | 0.1ms | **0.08ms** |
| state_kv_commiting_lat | 24-56ms | 0.35ms | **0.29ms** |
| kv_sync_lat | 1-13ms | 0.3ms | **0.27ms** |

### 5.2 OSD 分段

| 段 | 真盘 | WAL/DB tmpfs | **全 tmpfs** |
|----|------|-------------|-------------|
| op_w_latency | 249ms | 225ms | **17ms** |
| op_w_process_latency | 240ms | 210ms | **6ms** |

### 5.3 关键观察

1. **state_aio_wait_lat: 0.09ms**（真盘 55-99ms）→ DATA 写在 tmpfs 上近乎瞬时，**IOPS 墙彻底消除**
2. **6 OSD 全部一致**（0.089-0.094ms）→ node2 不再是短板，RAID 差异完全消除
3. **op_w_latency: 17ms**（真盘 249ms，14 倍降低）→ 写 op 总延迟仅剩网络 RTT + EC 协调 + 软件开销
4. **throttle: 0.013ms** → 回到近零（WAL/DB tmpfs 时曾升至 15ms 因 txn 涌入）
5. **所有段均 sub-millisecond** → BlueStore 内部无瓶颈，瓶颈已转移到 NIC

---

## 6. 三配置对比总表

| 指标 | 真盘 | WAL/DB tmpfs | 全 tmpfs | 目标 |
|------|------|-------------|---------|------|
| 256K write SS | 55.0 | 55.0 | **112.0** | 59 |
| IOPS | 207 | 247 | **448** | — |
| op_w_latency | 249ms | 225ms | **17ms** | — |
| state_aio_wait | 55-99ms | 7-99ms | **0.09ms** | — |
| kv_sync | 1-13ms | 0.3ms | **0.27ms** | — |
| NIC TX | ~49 MB/s | ~55 MB/s | **117 MB/s** | — |
| NIC % | 42% | 47% | **99%** | — |
| **墙** | DATA 写(RAID) | DATA 写(RAID) | **1GbE NIC** | — |
| **过 59?** | ❌ | ❌ | **✅ (1.9×)** | — |

---

## 7. 总判决

### 7.1 清单回答

1. **全内存盘 256K 稳态写 = 112 MB/s，过 59（1.9 倍）**。IOPS = 448（真盘 207 的 2.2 倍）。
2. **客户端 eno1 TX 实测 = 117 MB/s = 99% 1GbE**（/proc/net/dev 字节差分，非推算）。
3. **后端能打满网卡** → 方向 1 成立：若 JuiceFS 有效写 < 59，瓶颈在 JuiceFS 自身（FUSE/mu/buffer），不在后端。
4. **新墙 = 客户端 1GbE 网卡**（117 MB/s TX = 99%）。不是 CPU、不是 EC 协调、不是 BlueStore（所有 perf 段 sub-ms）。

### 7.2 IOPS 墙归因

| 配置 | 墙在哪 | 证据 |
|------|--------|------|
| 真盘 | DATA 写路径（RAID 控制器） | state_aio_wait 55-99ms，node2 73ms w_await |
| WAL/DB tmpfs | DATA 写路径（RAID 控制器） | state_aio_wait 仍 7-99ms，稳态不变 55→55 |
| **全 tmpfs** | **1GbE 客户端网卡** | state_aio_wait 0.09ms，NIC TX 117 MB/s = 99% |

**IOPS 墙 = DATA 写路径 = node2 RAID WriteThrough + node1/3 RAID WriteBack 缓存溢出。DATA 进内存后墙消失，转移到 NIC。**

### 7.3 对 59 MB/s 目标的含义

- **后端理论上限 = 112 MB/s**（全内存盘，NIC-bound）→ 远超 59
- **当前真盘能力 = 55 MB/s**（DATA 写瓶颈）→ 差 4 MB/s
- **修 node2 RAID 后预期**：node2 DATA 写从 99ms 降到 ~7-20ms（对齐 node1/3），稳态应从 55 提升到... 不确定（node1/3 的 DATA 写仍 7-20ms，可能成为新短板）
- **但后端确实能达到 59+**（全内存盘证明软件/网络/EC 都不是瓶颈，只要 DATA 写够快）

### 7.4 方向 1 指引

后端能打满网卡（117 MB/s），如果 JuiceFS 单客户端有效写仍 < 59：
- 看客户端 NIC TX：若 TX ≈ 59 → JuiceFS 无放大，但被自身 FUSE/mu 限速
- 若 TX > 59 → JuiceFS 有写放大（TX/有效写 = 放大倍数）
- 若 TX ≈ 117 → 网卡满，JuiceFS 放大把有效写压到 < 59

---

## 8. 异常

| 项 | 说明 |
|----|------|
| 旧 juicefs-data PGs stale | purge 重建 OSD 后旧 pool PGs 引用已删 OSD → 删 pool 重建 |
| 4 OSD up_thru=0 | RGW pool slow ops 阻塞 OSD map 确认 → 删 RGW pools 后恢复 |
| OSD class = ssd | tmpfs 被正确识别为 ssd（之前是 hdd），crush rule 不过滤 class |
| RGW/mgr pools 已删 | 为排除干扰，已删除（无业务数据） |
| 未回滚 | 按用户指示保留全内存盘配置 |

---

## 9. 产出文件

```
results/node2-raid-fix-memdisk-ceiling-20260709/
├── full-memdisk/
│   ├── write-256k-t64-r{1,2,3}.txt          # 写 256K 3 轮逐秒
│   ├── conc-256k-t{16,128}.txt              # 并发扫描
│   ├── bs-write-{4K,64K,1M,4M}-r{1,2,3}.txt # 块大小矩阵
│   ├── {seq,rand}-read-256k-r{1,2,3}.txt    # 读测试
│   ├── client-nic-r1.txt                    # 客户端网卡字节差分
│   ├── cpu-node{1,2,3}.txt                  # OSD CPU
│   ├── iostat-node{1,2,3}.txt               # iostat
│   └── osd{0..5}-perf-{t0,tend}-r1.txt      # perf delta
├── memdisk-ceiling/                         # 上轮 WAL/DB-only tmpfs 数据
├── raid-compare.md                          # 三节点 RAID 对比
└── report.md + full-memdisk/report.md       # 报告
```
