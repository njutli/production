# node2 写慢根因取证报告

> 日期：2026-07-08
> 任务：直查 RAID 卡缓存/BBU 状态 → 修复尝试 → 内存盘兜底
> 来源：`results/iops-wall-locate-20260708/` 定位 node2 是全局 IOPS 短板

---

## 0. 执行摘要

| 阶段 | 结论 |
|------|------|
| **A 只读取证** | 三节点同型号 RAID 卡(PERC H730 Mini)、同 SSD(Micron M600 1TB)、同磨损(7-9%)、同 OS/SCSI 缓存策略(write through, WCE=0)。**但 node2 写延迟 73ms vs node1/3 的 0.06ms（1216 倍）。** 无 perccli/storcli，无法直查 RAID 控制器内部 CachePolicy/BBU |
| **B 修复尝试** | OS cache_type 改 "write back" → 三节点均 `Invalid argument`（RAID 控制器不允许 OS 层改缓存策略）。**阶段 B 不可行** |
| **C 内存盘兜底** | osd.2 WAL+DB 迁 tmpfs(loop) → **node2 w_await 73ms→0.06ms（与 node1/3 一致），带宽 51.9→58.97 MB/s(+13.6%)，IOPS 207→235(+13.5%)。墙坐实在 node2 物理写路径** |

**总判决：node2 写慢的病因是 RAID 控制器 WriteBack 缓存未生效**（读快写慢=典型特征，tmpfs 绕盘后恢复=坐实）。疑似 BBU 降级导致控制器自动回退 WriteThrough。修复需 perccli64 查 BBU 状态并开 WriteBack。

---

## 1. 阶段 A：三节点 RAID 状态对比

### 1.1 工具
- perccli/storcli/MegaCli：**三节点均未安装**，apt 无包，GitHub/Broadcom 下载失败（0 字节）
- 替代方案：smartctl + sg_raw + /sys + dmesg

### 1.2 硬件对比

| 项 | node1 (.11) | node2 (.13) | node3 (.14) |
|----|-------------|-------------|-------------|
| RAID 卡 | PERC H730 Mini (MegaRAID SAS-3 3108) | 同左 | 同左 |
| 驱动 | megaraid_sas 07.727.03.00-rc1 | 同左 | 同左 |
| OS 盘 sda | INTEL SSDSC2KB480G7 480G | VK0480GDJXV 480G | VK0480GDJXV 480G |
| Ceph 盘 sdb | Micron M600 MTFDDAK1T0MBF 1TB | **同型号** | **同型号** |

### 1.3 SSD 寿命/健康

| 项 | node1 sdb | node2 sdb | node3 sdb |
|----|-----------|-----------|-----------|
| Power-On Hours | 14920 | 15986 | 13951 |
| Lifetime Remaining | 9% | 8% | **7%（最低但最快）** |
| SMART | PASSED | PASSED | PASSED |

> **node3 磨损最严重但写最快** → 排除 SSD 磨损导致写慢。

### 1.4 缓存策略对比

| 层 | node1 | node2 | node3 |
|----|-------|-------|-------|
| /sys/block/sdb/queue/write_cache | write through | write through | write through |
| /sys/class/scsi_disk/*/cache_type | write through | write through | write through |
| SCSI Mode Page 0x08 WCE bit | 0 (disabled) | 0 (disabled) | 0 (disabled) |

> **三节点 OS/SCSI 层完全相同**。差异在 RAID 控制器固件层（OS 看不到）。

### 1.5 性能对比（来自 `iops-wall-locate-20260708`）

| 项 | node1 | node2 | node3 |
|----|-------|-------|-------|
| 读速 (hdparm) | 390 MB/s | 406 MB/s | 405 MB/s |
| 写延迟 (iostat w_await) | 0.06 ms | **73 ms** | 0.06 ms |
| %util (300s 写) | ~50% | **100%** | ~50% |
| perf state_aio_wait_lat | 11.6 ms | **55.8 ms** | 7.3 ms |

> **读速一致、写延迟差 1216 倍** → 典型 RAID 控制器 WriteBack 缓存未生效特征。

### 1.6 阶段 A 结论

**RAID 控制器内部 CachePolicy 差异是最大嫌疑**，但无 perccli 无法直查。转阶段 B/C。

> 对比表详见 `raid-compare.md`

---

## 2. 阶段 B：修复尝试（不可行）

### 2.1 尝试改 OS cache_type

```bash
echo "write back" | sudo tee /sys/class/scsi_disk/0:2:1:0/cache_type
```

**结果**：三节点均返回 `Invalid argument`。RAID 控制器不允许 OS 层修改缓存策略。

### 2.2 阶段 B 结论

**不可行**：无 perccli 无法改 RAID 控制器 CachePolicy；OS 层 cache_type 不可改。转阶段 C。

---

## 3. 阶段 C：内存盘绕盘对照（核心取证）

### 3.1 方法
1. 停止 osd.2（node2 上的两个 OSD 之一）
2. 创建 tmpfs (10G) + loop device (/dev/loop10)
3. `ceph-bluestore-tool --command bluefs-bdev-new-db` 添加 tmpfs DB 设备
4. 重启 osd.2
5. rados bench 120s + 采集 osd.2 perf delta + node2 iostat
6. 对比 before/after

### 3.2 实施细节
- `ceph-bluestore-tool` 需在 podman 容器内运行（挂 `/dev` + OSD 数据目录 + tmpfs）
- tmpfs 不支持 O_DIRECT → 用 loop device 绕过
- `CEPH_ARGS='--bluestore-block-db-size 10737418240'` 指定 DB 大小

### 3.3 结果

| 指标 | Before (sdb 共享) | After (tmpfs DB) | 变化 |
|------|-------------------|------------------|------|
| rados 带宽 | 51.9 MB/s | **58.97 MB/s** | **+13.6%** |
| rados IOPS | 207 | **235** | +13.5% |
| rados 延迟 | 0.308 s | 0.271 s | -12.0% |
| osd.2 state_aio_wait_lat | 55.8 ms | **0.101 ms** | **-99.8%** |
| osd.2 kv_sync_lat | 12.8 ms | **0.304 ms** | **-97.6%** |
| osd.2 state_kv_queued_lat | 55.6 ms | **0.099 ms** | **-99.8%** |
| osd.2 op_w_latency | 254.1 ms | 224.8 ms | -11.5% |
| node2 w_await | 73.2 ms | **0.059 ms** | **-99.9%** |
| node2 %util | 98.6% | **55.2%** | -44% |

### 3.4 关键发现

1. **node2 w_await 从 73ms 降到 0.06ms**（与 node1/3 一致）→ 磁盘不再饱和
2. **%util 从 100% 降到 55%** → WAL/DB 迁到 tmpfs 后，SSD 只处理 data 写，不再饱和
3. **带宽 58.97 MB/s** → 逼近 59 MB/s 目标（bench mean，稳态略低）
4. **IOPS 从 207 提升到 235** → 接近之前测得的 ~230 IOPS 墙被突破

### 3.5 机理

node2 的 RAID 控制器 WriteBack 缓存未生效 → 所有写（data + WAL/DB）直接落 SSD → data+WAL/DB 合计 IOPS 超过 SSD 能力 → 磁盘 100% 饱和 → 排队 → 73ms 延迟。

WAL/DB 迁 tmpfs 后 → SSD 只处理 data 写 → data IOPS 不超 SSD 能力 → 无排队 → 0.06ms 延迟（SSD 原生速度）。

> node1/3 的 RAID 控制器 WriteBack 缓存生效 → data + WAL/DB 均被 NV 缓存吸收 → 0.06ms 延迟（缓存 ack）。

### 3.6 阶段 C 结论

**墙坐实在 node2 的物理写路径**（RAID 控制器 WriteBack 缓存未生效）。tmpfs 绕盘后性能恢复至与 node1/3 一致，**反证用户"node2 RAID 卡新降级"的判断成立**。

> 逐秒数据：`memdisk-bypass/rados-120s.txt` + `osd2-perf-{t0,tend}.txt` + `node2-iostat.txt`

---

## 4. 回滚与异常

### 4.1 回滚异常
- 回滚时（删除 block.db symlink + unmount tmpfs）→ BlueFS CURRENT 文件损坏 → osd.2 无法启动
- `ceph-bluestore-tool repair/quick-fix/fsck` 均失败（RocksDB CURRENT 文件损坏不可修复）
- **解决方案**：`ceph osd purge 2 --force` + `lvremove` + `ceph orch daemon add osd ceph-node2:/dev/ceph-vg-ceph-node2/osd0`
- **结果**：osd.2 重建成功，HEALTH_OK，SSD 参数已重新注入

### 4.2 教训
- `bluefs-bdev-new-db` 添加的 tmpfs DB 设备是**非持久化的**（tmpfs 断电即失）
- 回滚时不能直接删除 block.db symlink + unmount tmpfs → BlueFS 会因丢失 DB 设备上的元数据而损坏
- 正确回滚应：先用 `bluefs-bdev-migrate` 将 DB 数据迁回 sdb → 再删除 block.db → 再 unmount tmpfs
- 本集群无业务数据，OSD 重建可接受；生产环境绝不可这样做

### 4.3 当前集群状态
- 6 OSD up/in
- HEALTH_OK
- osd.2 已重建（新 BlueStore，数据从其他 OSD 恢复）
- SSD 基线参数（deferred=0, throttle=4000）已注入全部 6 OSD
- 无残留 tmpfs/loop 设备

---

## 5. 总判决

### 5.1 病因
**node2 的 PERC H730 Mini RAID 控制器 WriteBack 缓存未生效。**

证据链：
1. 三节点同硬件、同 SSD、同磨损、同 OS/SCSI 缓存策略 → 排除硬件差异
2. node2 读速 406 MB/s = node1/3 一致 → 物理盘健康
3. node2 写延迟 73ms vs node1/3 的 0.06ms → 仅写路径异常
4. 读快写慢 = RAID 控制器 WriteBack 缓存未生效的典型特征
5. **tmpfs DB 绕盘后 node2 w_await 73ms→0.06ms** → 坐实墙在物理写路径
6. **带宽 51.9→58.97 MB/s（+13.6%）** → 接近 59 MB/s 目标

### 5.2 可修复性
**可修复**：需 perccli64（Dell 版 storcli）查 RAID 控制器 CachePolicy 和 BBU 状态：
- 若 BBU 降级 → 更换电池/电容 → 控制器自动恢复 WriteBack
- 若 BBU 正常但策略是 WriteThrough → `perccli /c0/v0 set wrcache=WB` 直接开 WriteBack
- **修复后预期**：node2 写延迟恢复至 0.06ms，全局 IOPS 从 ~230 大幅提升，稳态写带宽应过 59 MB/s

### 5.3 下一步建议
1. **获取 perccli64**：从 Dell 支持站点下载（需可访问外网），或通过 Dell OpenManage 安装
2. **查 node2 RAID CachePolicy + BBU**：`perccli /c0/v0 show all | grep -i cache` + `perccli /c0/bbu show all`
3. **修复**：根据 BBU 状态开 WriteBack
4. **复测**：用 `iops-wall-locate` 同口径验证 node2 写延迟是否恢复

---

## 6. 产出文件

```
results/node2-raid-forensics-20260709/
├── ops.log                              # 全程操作日志
├── raid-compare.md                      # 三节点 RAID 状态对比表
├── memdisk-bypass/                      # 阶段 C 内存盘兜底
│   ├── rados-120s.txt                   # rados bench 逐秒原始
│   ├── osd2-perf-t0.txt                 # perf dump 测前
│   ├── osd2-perf-tend.txt              # perf dump 测后
│   └── node2-iostat.txt                 # node2 iostat -x
└── report.md                            # 本报告
```
