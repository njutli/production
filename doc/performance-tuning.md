# JuiceFS 性能调优指南

## 官方测试参数（对标基准）

以下参数来自 JuiceFS 官方性能测试，保持不变用于公平对比：

```bash
# 顺序读
fio --name=sequential-read --directory=/mnt/juicefs/test_dir/ \
    --rw=read --refill_buffers --bs=4M --size=4G

# 顺序写
fio --name=sequential-write --directory=/mnt/juicefs/test_dir/ \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1
```

当前结果：~8 MiB/s，官方参考值：300+ MiB/s，差距约 37 倍。

## 现状分析

官方使用远程云服务，你使用本地物理机，但性能差距巨大，根源在基础环境未调优：

| 差距来源 | 当前状态 | 影响 |
|---------|---------|------|
| **PD 时间戳延迟** | 30-200ms/次 | 每个元数据操作都要从 PD 取时间戳，单节点 PD 成为瓶颈 |
| **TiKV 配置** | 默认参数 | RocksDB block-cache 仅 128MB，无法利用可用内存 |
| **系统环境** | swap 开启、THP 开启 | 增加内存碎片和 I/O 抖动 |
| **RGW 网关** | 仅 ceph-node1 一个实例 | 所有 S3 流量走单一节点 |
| **网络/IO 参数** | 默认值 | 未针对高性能场景优化 |

## 调优路线

按优先级从高到低，每步完成后用官方参数复测。

### 第一级：系统环境调优

以下操作在 tikv-node 和 3 台 ceph-node 上分别执行。

#### 1. 禁用 swap

```bash
sudo swapoff -a                              # 立即生效
sudo sed -i '/\sswap\s/d' /etc/fstab         # 永久生效（防止重启恢复）
```

> 原因：TiKV 和 Ceph OSD 内置 RocksDB，compaction 时内存使用激增。若内存页被 swap 换出，I/O 延迟从 <1ms 飙升到几十 ms，导致 Raft 心跳超时、MON 误判 OSD 下线、集群抖动。

#### 2. 禁用透明大页（THP）

```bash
# 创建 systemd 服务，确保重启后仍生效
sudo tee /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable disable-thp
sudo systemctl start disable-thp
```

> 原因：内核定期整理内存碎片生成 2MB 大页，此过程会阻塞用户态进程数百毫秒，对 Raft/Paxos 心跳驱动的分布式系统是致命的。

#### 3. 网络和内核参数调优

```bash
sudo tee /etc/sysctl.d/99-performance.conf <<'EOF'
# 网络 — 增大连接队列、减少 TIME_WAIT 堆积
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 16384

# 虚拟机内存 — 降低 swap 倾向、控制脏页比例
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536

# 文件描述符上限
fs.file-max = 1000000
EOF

sudo sysctl --system
```

#### 4. I/O 调度器

```bash
# 对所有数据盘设置 none 调度器（NVMe/SSD 最佳选择，不做内核级调度）
for disk in /sys/block/sd*/queue/scheduler; do
    [ -f "$disk" ] && echo "none" | sudo tee "$disk" 2>/dev/null || true
done
```

#### 5. 文件描述符上限（需重启服务）

```bash
sudo tee /etc/security/limits.d/99-performance.conf <<'EOF'
root    soft    nofile  1000000
root    hard    nofile  1000000
*       soft    nofile  1000000
*       hard    nofile  1000000
EOF
```

> 注意：swap、THP、sysctl、I/O 调度器即时生效。fd limits 只对新进程生效，已运行的服务需要重启。

使 fd limits 生效：

```bash
# tikv-node
sudo systemctl restart pd tikv

# ceph-node（逐 OSD 重启，或直接重启机器）
sudo ceph orch daemon restart osd.<id>
```

### 第二级：TiKV 调优（需重启 TiKV）

编辑 `config/tikv/tikv1.toml`，添加以下配置：

```toml
[rocksdb.defaultcf]
block-cache-size = "2GB"

[rocksdb.writecf]
block-cache-size = "1GB"

[raftdb]
max-background-jobs = 4

[storage]
scheduler-concurrency = 204800
scheduler-worker-pool-size = 8

[server]
grpc-concurrency = 8
```

然后重启：
```bash
bash production/deploy-tikv.sh restart
```

> 说明：默认 block-cache 仅 128MB，对于 4M 块大小的元数据写入，频繁的磁盘 I/O 会严重拖慢 TiKV 响应。调大到 2GB 可大幅减少 RocksDB 读放大。

### 第三级：Ceph 调优

```bash
# 调高 OSD 操作优先级，减少延迟
sudo ceph config set osd osd_op_num_threads_per_shard 2
sudo ceph config set osd osd_op_num_shards 8

# 增大 RGW 线程数
sudo ceph config set client.rgw rgw_thread_pool_size 512
```

### 第四级：多 RGW 部署（后续优化方向）

当前仅 ceph-node1 运行 RGW。在 3 台 Ceph 节点上各部署一个 RGW 实例，前置 HAProxy 负载均衡，JuiceFS 连接 LB 地址。

## 预期提升

| 调优级别 | 顺序写 | 顺序读 |
|---------|--------|--------|
| 未调优（当前） | ~8 MiB/s | ~8 MiB/s |
| 第一级后（系统调优） | 15-30 MiB/s | 20-40 MiB/s |
| 第一+二级后（TiKV 调优） | 50-150 MiB/s | 80-200 MiB/s |
| 第一+二+三级后（Ceph 调优） | 100-250 MiB/s | 150-300 MiB/s |
| 全部（含多 RGW） | 150-350 MiB/s | 200-400 MiB/s |

## 瓶颈定位命令

```bash
# 测试期间查看 TiKV 指标
curl -s http://127.0.0.1:2379/metrics | grep -E "grpc_server_handling|tikv_raftstore"

# Ceph OSD 延迟
ssh 192.168.11.11 "sudo ceph osd perf"

# 网络吞吐
sar -n DEV 1 10
```
