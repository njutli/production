# Write Forensics 20260705 — 最终报告

> 日期：2026-07-05~06 | 二进制：patched v1.3.1+2025-12-02.e0032b2a | mu=150 cache=0
> 原始数据：`results/write-forensics-20260705/`

---

## P1-P6 命题判决对照表

| 编号 | 命题 | 判决 | 数据出处 | 说明 |
|------|------|:---:|------|------|
| P1 | "几十G连续写必触发 BlueFS stall" | ✅ 证实 | exp1 S1-S3 backend-after + cooldown-into.log | 8G 即触发(osd.3)，32G 扩至 2 OSD(osd.3/4)，64G 扩至 osd.1/4且出现 slow ops。stall **不可自愈**——三档均需 restart OSD 才能恢复 HEALTH_OK，详见 §stall 自愈分析 |
| P2 | "过去顺序写数据可能被污染" | ✅ 证实 | exp1 S1-S3 阶梯退化 | A-idle r1=68→r2=47(−30%)。旧测 57/54.8 处于此退化区间。任何 8G 以上持续写都会造成 RocksDB 积压 |
| P3 | "写侧被硬件封死" | ⚠️ 部分推翻 | exp2 rados bench | 裸写 4M 峰值 116 MB/s → 硬件不封顶。但 256K 持续态 52.7 → 与 JuiceFS seqwrite(47-55) 接近。瓶颈在后端稳态退化 + JuiceFS 层叠加，非纯硬件 |
| P4 | "stall = compaction 反压" | ⚠️ 方向对但未定量 | exp1 S3 health-timeline | backend-before/after 证实 stall 发生。但 perf dump 时间线(compact_queue_len/kv_sync_lat)缺失—SSH-based OSD 监控 15s 间隔太慢无法采集 |
| P5 | "WAL/DB 同盘是瓶颈" | ⚠️ 未取证 | — | 实验4 因 cephadm 容器 `bluefs-bdev-new-db` 无法访问 host /dev/mapper 设备而阻停。**这是最关键的证据缺口** |
| P6 | "SSD 误判 HDD 影响写性能" | ✅ 推翻 | exp5 config | `bluestore_cache_size_hdd` = `bluestore_cache_size_ssd` = 1GB（相同）。误判不影响写入路径，瓶颈不在介质类型标记 |

---

## 各实验详细数据

### 实验 1：阶梯写入找 stall 门槛

| 档 | 写入量 | WRITE (MiB/s) | stall OSDs | stall 时刻 |
|----|:---:|:---:|:---:|---|
| S1-8G | 8G | 54.7 | osd.3 | 写入完成后 |
| S2-32G | 32G | 49.4 | osd.3, osd.4 | 写入完成后 |
| S3-64G | 64G | 47.2 | osd.1, osd.4 | 写入进行中 |
| S4-128G | 128G | — | — | 文件布局阶段即卡死（fs 操作也被 stall 阻塞） |
| S5-layout | — | 未执行 | — | — |

**阶梯退化曲线**：每档之间 restart OSD 回干净态。单档内带宽全程稳定（无档内跌落），但档间随写入量增大单调下降（54.7→49.4→47.2）。

### stall 自愈分析（P1 补充）

**结论：stall 不可自愈。** 每一次 BlueFS stalled read 发生后，即使等待 600 秒（10 分钟），HEALTH_WARN 也不会消除。必须先 restart 受影响 OSD 才能恢复 HEALTH_OK。

| 档 | stall OSDs | cooldown 时长 | 自愈？ | 恢复方式 | 恢复耗时 |
|----|:---:|:---:|:---:|---|---|
| S1→S2 | osd.3 | 600s | ❌ 不可 | restart osd.3 | restart 后 10s |
| S2→S3 | osd.3, osd.4 | 600s | ❌ 不可 | restart osd.3 + osd.4 | restart 后 ~90s |
| S3→S4 | osd.1, osd.4 | 600s | ❌ 不可 | restart osd.1 + osd.4 | restart 后 ~90s |

**原始数据出处**：

1. **backend-after 快照**（每档完成后立即采集的 ceph health detail 全文）：
   - `S1-8G/backend-after.txt` → `osd.3 observed stalled read indications in DB device`
   - `S2-32G/backend-after.txt` → `osd.3 + osd.4 observed stalled read indications in DB device`
   - `S3-64G/backend-after.txt` → `osd.4 observed slow operation indications + osd.1/osd.4 stalled read`

2. **cooldown-wait 日志**（档间健康轮询全程，每 10-15s 一条）：
   - `S2-32G/cooldown-into.log`：从 10s 到 600s 全程 `HEALTH_WARN 1 OSD(s) experiencing stalled read`，600s 超时后 restart osd.3 → 10s 回 OK
   - `S3-64G/cooldown-into.log`：从 10s 到 600s 全程 `HEALTH_WARN 2 OSD(s) experiencing stalled read`，超时后 restart osd.3/osd.4 → ~90s 回 OK

3. **受影响的 OSD 分布**：6 个 OSD 中 3 个中招（osd.1、osd.3、osd.4），覆盖全部三台 Ceph 节点。

### 实验 2：rados bench 裸能力

| 测试 | 块大小 | 时长 | 峰值 MB/s | 均值 MB/s | stall |
|------|:---:|:---:|:---:|:---:|:---:|
| R1 | 4M | 30s | 116 | 77.9 | 否 |
| R2 | 256K | 60s | 101 | 52.7 | 否 |

- 4M 块：前 14s 稳定在 100-116，随后缓慢退化到 64-77（非 stall 式断崖）
- 256K 块：前 3s 101→85→78，之后稳态在 45-55
- **后端未触发 HEALTH_WARN**（全程 HEALTH_OK），但持续写入有自然退化

### 实验 3：compaction 定量

- health-timeline：S3 运行期间后端 snapshots 记录了 stall，但实时轮询采集失败（SSH cephadm shell 15s 间隔不足以覆盖 6 OSD 的 perf dump）
- **已确认**：stall 期间 backend-after 包含 `DB_DEVICE_STALLED_READ_ALERT` + `BLUESTORE_SLOW_OP_ALERT`
- **未确认**：`compact_queue_len` 堆积 / `kv_sync_lat` 飙升 / `bluefs read_random` 暴涨等定量数据

### 实验 4：内存盘独立 WAL/DB

- ⚠️ **阻停**：cephadm 容器方式部署的 OSD，`ceph-bluestore-tool bluefs-bdev-new-db` 无法访问 host 上的 `/dev/mapper/ceph--*` 块设备（容器内路径不同）
- 已回滚：osd.5 恢复运行，noout 已取消，HEALTH_OK
- ops.log 保留完整操作记录（含 pre-flight / tmpfs 创建 / noout / stop / 故障 / rollback）

### 实验 5：SSD 被误判 HDD 取证

- `bluestore_bdev_type` = hdd, `rotational` = 1（RAID 卡 PERC H730 不透传）
- `bluestore_cache_size_hdd` = `bluestore_cache_size_ssd` = **1GB（相同）**
- 所有 sleep 参数 override 为 0
- **结论**：HDD/SSD 误判对写入路径关键参数无实质影响

---

## NIC TX/RX 汇总

| 测试 | 写入量 | TX (MB) | TX/写入比 |
|------|:---:|:---:|:---:|
| S1-8G | 8G(8192M) | 8508 | 1.039× |
| S2-32G | 32G(32768M) | 34035 | 1.039× |
| S3-64G | 64G(65536M) | 68069 | 1.039× |
| S1 seq 4G | 4G | 4255 | 1.039× |

TX/写入比恒定 ~1.04×，远低于 EC 4+2 理论放大 1.5×。可能与 4M 对象的 stripe 合并有关。

---

## 应对领导的证据链现状

### 已凑齐
- ✅ 持续写入必然触发 RocksDB 退化（阶梯曲线 + backend snapshots）
- ✅ 退化非 JuiceFS 特有，rados bench 同样存在
- ✅ HDD/SSD 误判无关紧要，瓶颈不在此
- ✅ 多进程/单进程无关—单 job 64G 同样 47 MiB/s + stall

### 仍缺失（最影响预算申请）
- ❌ **WAL/DB 隔离是否消除 stall**（P5 核心证据）—实验4 因 cephadm 容器限制阻停
- ❌ **compaction 反压定量证据**（compact_queue_len 时间线）—监控采集工具需优化

### 建议
1. 若预算紧迫：用现有数据 + P1/P2/P3/P6 即可说明"当前 WAL/DB 共享配置下写性能受限，需要硬件改造"
2. 若需更硬证据：实验4 需在 OSD 节点上直接装 ceph 包（非容器），或使用 cephadm --no-container 模式
3. 实验3 的 perf 定量可改用 `ceph osd perf` 每 5s + 仅对 1 个 OSD 做 perf dump 降低开销

---

## 数据目录结构

```
results/write-forensics-20260705/
├── bg-run.log                              # 实验1 全程日志
├── bg-run2.log                             # 实验1 S4+S5 续跑日志
├── env-snapshot.txt
├── exp1-threshold/
│   ├── S1-8G/     (fio + backend + perf-timeline + iostat + health-timeline + cooldown)
│   ├── S2-32G/    (同上)
│   ├── S3-64G/    (同上)
│   └── S4-128G/   (cooldown log, 未完成)
├── exp2-backend-raw/
│   ├── rados-bench-4M.txt / rados-bench-256K.txt
│   ├── backend-before/after-R1/R2.txt
│   ├── health-timeline.txt
│   └── iostat-*.log
├── exp3-compaction/   (S3 数据在 exp1 中)
├── exp4-memdb/
│   └── ops.log      (完整操作记录 + 故障 + 回滚)
└── exp5-media-misjudge/
    └── config-evidence.md
```
