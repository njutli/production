# 方向 B：内存盘模拟 SSD 做 WAL/DB 测试

> 目标：在 3 节点各创建内存盘，将 OSD 的 WAL/DB 迁移到内存盘上，
> 跑 rados bench 验证"WAL/DB 上更快介质"是否提升吞吐。
>
> **状态：✅ 已完成（2026-06-11），结论：仅 +4.8%，基本无效。**

---

## 重要前置发现：磁盘是 SSD，不是 HDD

**2026-06-11 实测确认**：三节点的 sdb 均为 SSD，通过 PERC H730 RAID 卡提供。

| 查询项 | 结果 | 说明 |
|--------|------|------|
| `lsblk -o ROTA` | **1**（rotational） | RAID 虚拟盘统一报告为 rotational，**障眼法** |
| `smartctl -i /dev/sdb` | 无输出 | SMART passthrough 未启用，无法穿透 RAID 卡 |
| `/sys/block/sdb/queue/rotational` | **1** | 同上，RAID 虚拟盘不区分实际介质 |
| `/sys/block/sdb/queue/discard_*` | 全 0 | RAID 虚拟盘不支持 TRIM |

**决定性证据：裸盘 fio 实测（node1, sdb, direct=1）**

| 测试 | 结果 | 如果是 HDD |
|------|------|-----------|
| 4K 随机读 IOPS（iodepth=32） | **92,500** | 最多 ~200 |
| 4K 随机写 IOPS（iodepth=32） | **17,800** | 最多 ~200 |
| 4M 顺序写带宽（iodepth=1） | **178 MB/s** | 可能但 IOPS 对不上 |

> 4K 随机读 92.5k IOPS 是铁证：HDD 不可能做到。node2/node3 硬件相同（同型号 PERC H730，
> 同容量 sdb），可推断均为 SSD。

**这意味着之前的瓶颈分析前提需要修正**：
- SSD 不区分顺序 vs 随机访问，"71% 落盘不连续（seek）" 在 SSD 上不是性能问题
- blktrace 的 107KB 平均 IO 大小偏小，但 SSD 的小 IO 性能远好于 HDD
- 裸盘 178 MB/s → Ceph EC 只跑 102 MB/s（效率仅 **57%**），差距在 RAID 卡/EC 协议/Ceph 软件栈

---

## 前置信息

| 节点 | OSD | 当前 WAL/DB | 实际介质 | 内存 free |
|------|-----|-----------|---------|----------|
| ceph-node1 (192.168.11.11) | osd.0, osd.1 | 均在 SSD (sdb，经 PERC H730) | SSD | 224 GiB |
| ceph-node2 (192.168.11.13) | osd.2, osd.3 | 均在 SSD (sdb，经 PERC H730) | SSD | 202 GiB |
| ceph-node3 (192.168.11.14) | osd.4, osd.5 | 均在 SSD (sdb，经 PERC H730) | SSD | 217 GiB |

FSID: `073f28e0-5fe0-11f1-8ce6-7369ee2be5a1`
ceph 用户 UID: `64045`

最终每 OSD 分配 **4GB** 内存盘（2GB 时 BlueFS spillover）。

---

## 关键约束

OSD 由 cephadm 以容器方式运行，OSD 数据目录在宿主机和容器内路径不同：

| 位置 | 宿主机路径 | 容器内路径 |
|------|----------|----------|
| OSD 数据目录 | `/var/lib/ceph/<fsid>/osd.<id>/` | `/var/lib/ceph/osd/ceph-<id>/` |

因此 `ceph-bluestore-tool` 迁移时必须用**容器内路径**。

**额外约束**：BlueStore 以 O_DIRECT 打开 DB 设备，tmpfs 不支持 O_DIRECT，
必须通过 **loop device** 中转。

---

## 实际执行步骤（已验证）

### 一、创建内存盘并绑定 loop device

```bash
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1

# 在每台 ceph-node 上，对每个 OSD 执行（以 osd.0 为例）：
sudo mkdir -p /var/lib/ceph/${FSID}/osd.0/wal-db
sudo mount -t tmpfs -o size=4G tmpfs /var/lib/ceph/${FSID}/osd.0/wal-db
sudo truncate -s 4G /var/lib/ceph/${FSID}/osd.0/wal-db/block.db
sudo chown -R 64045:64045 /var/lib/ceph/${FSID}/osd.0/wal-db
sudo losetup -f /var/lib/ceph/${FSID}/osd.0/wal-db/block.db
# 记录 loop 设备名（如 /dev/loop7）
```

### 二、迁移 WAL/DB（逐个 OSD）

关键要点：
1. `ceph orch daemon stop` 只是调度关闭，不会等待进程退出
2. 容器可能仍在运行，必须等 OSD 报告 down **且** `podman rm -f` 强杀容器
3. 用 loop 设备路径而非文件路径作为 `--dev-target`

```bash
# 1) 停止 OSD
sudo cephadm shell -- ceph orch daemon stop osd.0

# 2) 等待 OSD 实际 down（5 up 而非 6 up）
while true; do
  sudo cephadm shell -- ceph osd stat 2>/dev/null | grep -q '5 up' && break
  sleep 2
done

# 3) 强杀残留容器（关键！否则 fsid 文件锁不释放）
sudo podman rm -f ceph-${FSID}-osd.0 2>/dev/null
sudo podman rm -f ceph-${FSID}-osd-0 2>/dev/null

# 4) 迁移（LOOP=实际 loop 设备，如 /dev/loop7）
sudo cephadm shell \
  --mount /var/lib/ceph/${FSID}/osd.0:/var/lib/ceph/osd/ceph-0 \
  -- ceph-bluestore-tool \
    --path /var/lib/ceph/osd/ceph-0 \
    --devs-source /var/lib/ceph/osd/ceph-0/block \
    --dev-target ${LOOP} \
    --command bluefs-bdev-new-db

# 5) 启动 OSD
sudo cephadm shell -- ceph orch daemon start osd.0
```

### 三、实际迁移的 loop 设备映射

| OSD | 节点 | loop 设备 |
|-----|------|----------|
| osd.0 | ceph-node1 | /dev/loop7 |
| osd.1 | ceph-node1 | /dev/loop8 |
| osd.2 | ceph-node2 | /dev/loop5 |
| osd.3 | ceph-node2 | /dev/loop6 |
| osd.4 | ceph-node3 | /dev/loop1 |
| osd.5 | ceph-node3 | /dev/loop3 |

---

## 实测结果

### rados bench（60s write, -t 64, 从 ceph-node1 发起）

| 指标 | WAL/DB on SSD（基线） | WAL/DB on 内存盘 | 变化 |
|------|----------------------|------------------|------|
| 写带宽 | 101.6 MB/s | **106.4 MB/s** | +4.8% |
| 平均延迟 | 2.47s | **2.35s** | -4.7% |
| IOPS | 25 | 26 | +4% |
| 最大延迟 | — | 6.10s | — |

> **集群状态：HEALTH_WARN，6 个 OSD 均 BlueFS spillover。**
> 4GB tmpfs 仍不够（每 OSD 管理 ~476GB 数据盘），部分元数据溢出到 SSD 主数据区。

### 裸盘能力对比

| 测试（node1, /dev/sdb, direct=1） | 结果 |
|-----------------------------------|------|
| 4K 随机读 IOPS | 92,500 |
| 4K 随机写 IOPS | 17,800 |
| 4M 顺序写带宽 | 178 MB/s |

---

## 结论

1. **WAL/DB 上内存盘无明显收益**（+4.8%，误差范围内）
   - 即使 spillover 有干扰，核心问题是：数据块本身仍在相同介质（SSD）上，
     WAL/DB 迁移不改变数据写入路径
2. **磁盘是 SSD 而非 HDD**，之前 blktrace 的"71% 寻道"分析对 SSD 不适用
3. **裸盘 178 MB/s → Ceph EC 仅 102 MB/s**（效率 57%），瓶颈在 RAID 控制器 +
   EC 协议开销 + Ceph 软件栈，不在介质
4. **方向 B（WAL/DB 上更快介质）对本场景无效**，从优化清单排除

---

## 宕机风险

- 重启后所有 tmpfs 清空 → loop 设备失效 → block.db 丢失 → 所有 OSD 无法启动
- 恢复需重建全部 OSD，再重建 EC 池和 RGW（步骤见下方"恢复流程"）

### 恢复流程

```bash
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1

# 1) 销毁所有 OSD
for id in 0 1 2 3 4 5; do
  sudo cephadm shell -- ceph orch daemon rm osd.${id} --force
done

# 2) 每节点清理内存盘
# ceph-node1:
ssh turboai@192.168.11.11 "
  sudo umount /var/lib/ceph/${FSID}/osd.0/wal-db /var/lib/ceph/${FSID}/osd.1/wal-db 2>/dev/null
  sudo rm -rf /var/lib/ceph/${FSID}/osd.0/wal-db /var/lib/ceph/${FSID}/osd.1/wal-db
"
# ... 其余节点类似

# 3) 重新创建 OSD（复用已有 LV）
sudo cephadm shell -- ceph orch daemon add osd ceph-node1:/dev/ceph-vg-ceph-node1/osd0
sudo cephadm shell -- ceph orch daemon add osd ceph-node1:/dev/ceph-vg-ceph-node1/osd1
# node2:
sudo cephadm shell -- ceph orch daemon add osd ceph-node2:/dev/ceph-vg-ceph-node2/osd0
sudo cephadm shell -- ceph orch daemon add osd ceph-node2:/dev/ceph-vg-ceph-node2/osd1
# node3:
sudo cephadm shell -- ceph orch daemon add osd ceph-node3:/dev/ceph-vg-ceph-node3/osd0
sudo cephadm shell -- ceph orch daemon add osd ceph-node3:/dev/ceph-vg-ceph-node3/osd1
  
# 4) 重建 EC 池和 RGW
sudo cephadm shell -- ceph osd pool create default.rgw.buckets.data erasure ec-prod
sudo cephadm shell -- ceph osd pool application enable default.rgw.buckets.data rgw
```