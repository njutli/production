# 方向 E：CephFS vs JuiceFS 对比测试

> 目标：在内核态 CephFS 上跑同参数 fio randrw，对比 JuiceFS 的 FUSE 层开销，
> 分别在 SSD 后端和内存盘后端上测试。

---

## 执行步骤

### 一、部署 MDS

```bash
ceph orch apply mds cephfs --placement="3 ceph-node1,ceph-node2,ceph-node3"
```

### 二、创建 CephFS 池

元数据池必须 replicated（放 SSD），数据池用 EC：

```bash
# 元数据池（replicated, SSD）
ceph osd pool create cephfs-meta replicated
ceph osd pool set cephfs-meta size 3

# 数据池：SSD 后端（EC 4+2, ec-prod profile）
ceph osd pool create cephfs-data-ssd erasure ec-prod
ceph osd pool application enable cephfs-data-ssd cephfs

# 数据池：内存盘后端（需先重建 ec-ram profile/rule）
ceph osd erasure-code-profile set ec-ram k=4 m=2 crush-device-class=ram crush-failure-domain=osd
ceph osd crush rule create-erasure ec-ram-rule ec-ram
ceph osd pool create cephfs-data-ram erasure ec-ram ec-ram-rule
ceph osd pool application enable cephfs-data-ram cephfs
```

### 三、创建 CephFS 并挂载

```bash
# 创建 CephFS（初始指向 SSD 数据池）
ceph fs new cephfs cephfs-meta cephfs-data-ssd

# tikv-node 上需有 ceph.conf + admin keyring
# 从 ceph-node1 拷贝 keyring
scp turboai@192.168.11.11:/etc/ceph/ceph.conf /etc/ceph/ceph.conf
scp turboai@192.168.11.11:/etc/ceph/ceph.client.admin.keyring /etc/ceph/ceph.client.admin.keyring

# 挂载
mount -t ceph 192.168.11.11:6789,192.168.11.13:6789,192.168.11.14:6789:/ /mnt/cephfs \
  -o name=admin,secret=<admin_key>
```

### 四、SSD 后端 fio 测试

```bash
mkdir -p /mnt/cephfs/test_dir/{1..100}
chown -R turboai:turboai /mnt/cephfs/test_dir

fio --directory=/mnt/cephfs/test_dir \
    --name=test --nrfiles=100 --filesize=1G --size=1G \
    --bs=256k --rw=randrw --ioengine=libaio \
    --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --create_on_open=1 --openfiles=100 \
    --group_reporting --time_based --runtime=60s
```

### 五、切换内存盘后端再测

```bash
# 卸载
umount /mnt/cephfs

# 删除 CephFS（测试数据不要了）
ceph fs rm cephfs --yes-i-really-mean-it

# 重新创建（注意：需先 `ceph fs fail cephfs` 再 `ceph fs rm`）
echo fs fail
ceph fs fail cephfs
ceph fs rm cephfs --yes-i-really-mean-it
ceph fs new cephfs cephfs-meta cephfs-data-ram --force

echo "Mounted with data pool: cephfs-data-ram (RAM)"

# 清理旧数据，重新创建目录，跑同参数 fio

# 重新挂载
mount -t ceph ... /mnt/cephfs ...

# 跑同参数 fio
```

### 六、清理

```bash
umount /mnt/cephfs
ceph fs rm cephfs --yes-i-really-mean-it
ceph orch rm mds.cephfs
ceph osd pool delete cephfs-meta cephfs-meta --yes-i-really-really-mean-it
ceph osd pool delete cephfs-data-ssd cephfs-data-ssd --yes-i-really-really-mean-it
ceph osd pool delete cephfs-data-ram cephfs-data-ram --yes-i-really-really-mean-it
```

## 实测结果（2026-06-12）

### SSD 后端

```
   READ: bw=13.3MiB/s (13.9MB/s), io=2874MiB
  WRITE: bw=13.2MiB/s (13.8MB/s), io=2854MiB
   IOPS: total=506
  Latency: all >=2s
```

### RAM 后端

```
   READ: bw=26.4MiB/s (27.6MB/s), io=3699MiB
  WRITE: bw=26.0MiB/s (27.3MB/s), io=3654MiB
   IOPS: total=490
  Latency: all >=2s
```

### 对比总结

| 方式 | 后端 | 读 | 写 | 关键差异 |
|------|------|-----|-----|---------|
| JuiceFS | SSD | 3.8 MB/s | 38.1 MB/s | FUSE+TiKV+RGW 多层开销，写绕过 RMW |
| JuiceFS | RAM | 3.5 MB/s | 36.8 MB/s | 介质无关 |
| **CephFS** | **SSD** | **13.9 MB/s** | **13.8 MB/s** | 无 FUSE 税，读 3.6× 提升；写反降：EC overwrite 触发真 RMW |
| **CephFS** | **RAM** | **27.6 MB/s** | **27.3 MB/s** | EC RMW 受益于更快介质（2× 提升），读写均衡 |

### 关键发现

1. **CephFS 消除 FUSE 开销**：内核态直连 RADOS，读性能 4-7× 于 JuiceFS
2. **EC overwrite RMW 是双刃剑**：CephFS 写需就地修改触发 RMW（读回旧条带+重写），
   JuiceFS 创建新 chunk 绕过了这个代价——所以 write 反而 JuiceFS 更快
3. **RAM 盘对 CephFS 有效，对 JuiceFS 无效**：
   - CephFS 的 EC RMW 需要读回旧数据（I/O 操作），介质快 = RMW 快
   - JuiceFS 的瓶颈在 FUSE+TiKV+RGW 往返（网络/协议操作），介质快没用

