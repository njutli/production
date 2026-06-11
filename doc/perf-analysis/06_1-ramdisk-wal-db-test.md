# 方向 B：内存盘模拟 SSD 做 WAL/DB 测试步骤

> 目标：在 3 节点各创建内存盘，将 OSD 的 WAL/DB 迁移到内存盘上，
> 跑 rados bench 验证"WAL/DB 上更快介质"是否提升吞吐。

---

## 前置信息

| 节点 | OSD | 当前 WAL/DB | 内存 free |
|------|-----|-----------|----------|
| ceph-node1 (192.168.11.11) | osd.0, osd.1 | 均在 HDD (sdb) | 224 GiB |
| ceph-node2 (192.168.11.13) | osd.2, osd.3 | 均在 HDD (sdb) | 202 GiB |
| ceph-node3 (192.168.11.14) | osd.4, osd.5 | 均在 HDD (sdb) | 217 GiB |

每 OSD 分配 2GB 内存盘（WAL+DB 共用），每节点共 4GB。

FSID: `073f28e0-5fe0-11f1-8ce6-7369ee2be5a1`
ceph 用户 UID: `64045`

---

## 关键约束

OSD 由 cephadm 以容器方式运行，OSD 数据目录在宿主机和容器内路径不同：

| 位置 | 宿主机路径 | 容器内路径 |
|------|----------|----------|
| OSD 数据目录 | `/var/lib/ceph/<fsid>/osd.<id>/` | `/var/lib/ceph/osd/ceph-<id>/` |

因此 `ceph-bluestore-tool` 迁移时必须用**容器内路径**，确保 OSD 启动后能找到 DB 设备。

---

## 步骤

### 一、在 OSD 数据目录内创建内存盘

在 **每个 ceph 节点** 上执行（每节点 2 个 OSD，各 2GB）：

```bash
# ---- 以 ceph-node1 为例，osd.0 和 osd.1 ----
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1
CEPH_UID=64045

# osd.0 的内存盘
sudo mkdir -p /var/lib/ceph/${FSID}/osd.0/wal-db
sudo mount -t tmpfs -o size=2G tmpfs /var/lib/ceph/${FSID}/osd.0/wal-db
sudo truncate -s 2G /var/lib/ceph/${FSID}/osd.0/wal-db/block.db
sudo chown -R ${CEPH_UID}:${CEPH_UID} /var/lib/ceph/${FSID}/osd.0/wal-db

# osd.1 的内存盘
sudo mkdir -p /var/lib/ceph/${FSID}/osd.1/wal-db
sudo mount -t tmpfs -o size=2G tmpfs /var/lib/ceph/${FSID}/osd.1/wal-db
sudo truncate -s 2G /var/lib/ceph/${FSID}/osd.1/wal-db/block.db
sudo chown -R ${CEPH_UID}:${CEPH_UID} /var/lib/ceph/${FSID}/osd.1/wal-db
```

同样在 node2 (osd.2, osd.3) 和 node3 (osd.4, osd.5) 执行。

### 二、迁移 WAL/DB 到内存盘

对每个 OSD，执行：停 OSD → 迁移 → 启 OSD。必须逐个做，一个 up 且 PG clean 后再做下一个。

```bash
# ---- 以 ceph-node1 的 osd.0 为例 ----
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1

# 1) 停止 OSD（在任一 ceph 节点执行）
sudo cephadm shell -- ceph orch daemon stop osd.0

# 2) 迁移：关键！用 --mount 把宿主机 OSD 目录映射到容器内路径，
#    这样 ceph-bluestore-tool 写入的 DB 路径在 OSD 容器内也有效
sudo cephadm shell \
  --mount /var/lib/ceph/${FSID}/osd.0:/var/lib/ceph/osd/ceph-0 \
  -- ceph-bluestore-tool \
    --path /var/lib/ceph/osd/ceph-0 \
    --devs-source /var/lib/ceph/osd/ceph-0/block \
    --dev-target /var/lib/ceph/osd/ceph-0/wal-db/block.db \
    --command bluefs-bdev-new-db

# 3) 启动 OSD
sudo cephadm shell -- ceph orch daemon start osd.0

# 4) 等待 OSD up + PG active+clean
sudo cephadm shell -- ceph -s
```

### 三、对所有 OSD 重复

```bash
# 按顺序逐个：osd.0 → osd.1 → osd.2 → osd.3 → osd.4 → osd.5
# 需要注意：osd.2/osd.3 在 node2 上执行，osd.4/osd.5 在 node3 上执行
# 但 ceph orch daemon stop/start 可以从任一节点执行
```

### 四、验证 WAL/DB 已生效

```bash
sudo cephadm shell -- ceph osd metadata 0 | python3 -c "
import sys, json
m = json.load(sys.stdin)
for k in ['bluefs_db_path','bluefs_wal_path','bluefs_db_size','bluefs_wal_size']:
    print(f'{k}: {m.get(k, \"N/A\")}')
"
# 预期 bluefs_db_path 指向 wal-db/block.db
```

### 五、跑 rados bench 对比

```bash
# 从中立的 tikv-node 发起，与之前基线相同的参数
rados bench -p default.rgw.buckets.data 60 write -t 64 --no-cleanup
```

### 六、验证落盘 IO 模型变化

跑 rados bench 时，同时在节点上抓 blktrace：

```bash
# 在 ceph-node1 上
sudo blktrace -d /dev/sdb -o - | blkparse -i - -q -f "%5T.%9t %a %S %N\n" > /tmp/blktrace-wal-ssd.log
```

### 七、测试后恢复（重启后 OSD 无法启动）

重启后内存盘清空，WAL/DB 丢失 → OSD 病理状态，只能销毁重建：

```bash
# 在 ceph-node1 上执行
sudo cephadm shell -- ceph orch daemon rm osd.0 --force
sudo cephadm shell -- ceph orch daemon rm osd.1 --force
# ... 依此类推 osd.2~5

# 清理内存盘挂载（每个节点）
sudo umount /var/lib/ceph/${FSID}/osd.0/wal-db
sudo umount /var/lib/ceph/${FSID}/osd.1/wal-db
sudo rm -rf /var/lib/ceph/${FSID}/osd.0/wal-db
sudo rm -rf /var/lib/ceph/${FSID}/osd.1/wal-db

# 重新创建 OSD（复用已有的 LV）
sudo cephadm shell -- ceph orch daemon add osd ceph-node1:/dev/ceph-vg-ceph-node1/osd0
sudo cephadm shell -- ceph orch daemon add osd ceph-node1:/dev/ceph-vg-ceph-node1/osd1
# node2: ceph-node2:/dev/ceph-vg-ceph-node2/osd0, osd1
# node3: ceph-node3:/dev/ceph-vg-ceph-node3/osd0, osd1

# 重建 EC 池和 RGW（如果被删）
sudo cephadm shell -- ceph osd pool create default.rgw.buckets.data erasure ec-prod
sudo cephadm shell -- ceph osd pool application enable default.rgw.buckets.data rgw
```

### 八、重启不丢失的持久化方案（若测试有效，后续用真 SSD）

```bash
# 真 SSD 部署时，替换 tmpfs 为真实块设备：
# 1. 在 fstab 中持久化挂载 SSD 分区
# 2. 用 ceph-volume 或 ceph orch daemon add osd 指定 --db-dev
# 这样重启后 OSD 自动找到 SSD 上的 DB 设备，不会丢失
```

### 九、预期效果

| 指标 | 当前基线 (WAL/DB on HDD) | 预期 (WAL/DB on 内存盘) |
|------|------------------------|------------------------|
| rados bench 写带宽 | 101.6 MB/s | **提升 20~50%** |
| 落盘顺序性 (seek=0 占比) | 29% | **明显提升** |
| 平均 IO 大小 | 107 KB | **变大** |
| OSD 写延迟 | 2.47s | **降低** |

> 原理：WAL/DB 的小 IO（元数据读写、RocksDB compaction）不再与数据 IO 争抢
> HDD 磁头 → 数据 IO 更连续、寻道大幅减少 → 吞吐和延迟同时改善。