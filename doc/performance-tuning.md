# JuiceFS 性能调优指南

> ⚠️ **已被实测推翻，仅作历史记录保留。**
> 本文档（deepseek 初版）的瓶颈分析方向是错的：把 PD 时间戳 / TiKV
> block-cache 当主因。2026-06-08 实测证明瓶颈在 Ceph 后端，根因是
> **ceph-node1/node2 网卡只协商到 100Mb/s**，与 TiKV/PD/RocksDB 无关。
> 这解释了为什么第一~三级调优全都没效果。
> **请以 `doc/perf-analysis/` 为准。**

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

在任意 ceph-node 上执行：

```bash
# OSD 线程优化
sudo ceph config set osd osd_op_num_threads_per_shard 2
sudo ceph config set osd osd_op_num_shards 8
sudo ceph config set osd osd_memory_target 4294967296    # 4GB per OSD
sudo ceph config set osd bluestore_cache_size_hdd 1073741824  # 1GB BlueStore cache
sudo ceph config set osd bluestore_cache_size_ssd 1073741824  # 1GB (如果有 SSD)

# PG 日志
sudo ceph config set osd osd_pg_log_trim_min 10
sudo ceph config set osd osd_max_pg_log_entries 1000

# RGW (在 ceph-node1 执行)
sudo ceph config set client.rgw rgw_frontends "beast port=8000"
sudo ceph config set client.rgw rgw_max_concurrent_requests 1024
sudo ceph config set client.rgw rgw_thread_pool_size 512
```

> 注意：Ceph config set 是集群级别设置，在任意一台 ceph-node 用 sudo 执行即可。

### 第四级：JuiceFS 客户端调优

重新挂载 JuiceFS 时添加参数：

```bash
juicefs mount -d tikv://127.0.0.1:2379/juicefs-prod /mnt/juicefs \
    --cache-dir /var/jfsCache \
    --cache-size 102400 \          # 100GB 本地缓存
    --prefetch 1 \                 # 启用顺序预读
    --max-uploads 20 \             # 最大并发上传数
    --writeback \                  # 启用写回缓存
    --open-cache 10 \              # 元数据打开文件缓存时间（s）
    --attr-cache 10                # 属性缓存时间（s）
```

| 参数 | 作用 | 建议值 |
|------|------|--------|
| `--cache-size` | 本地数据缓存（MiB），减少 S3 读取 | 100GB 以上 |
| `--prefetch` | 顺序预读，提升大文件读性能 | 1 |
| `--max-uploads` | 并发上传 S3 的线程数 | 20 |
| `--writeback` | 写回缓存，先写到本地再异步上传 S3 | 适合有磁盘空间时启用 |
| `--open-cache` | 缓存已打开文件元数据（秒） | 10 |
| `--attr-cache` | 缓存文件属性（秒） | 10 |

### 第五级：网络调优

在 tikv-node 和 3 台 ceph-node 上分别执行：

```bash
# 确认网卡名
ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}'

# 增大网卡接收/发送缓冲区（假设网卡 eth0）
sudo ethtool -G eth0 rx 4096 tx 4096

# 禁用不必要的网卡卸载功能（减少延迟）
sudo ethtool -K eth0 tso off gso off gro off lro off

# 如果交换机支持，开启巨帧（MTU 9000）
sudo ip link set dev eth0 mtu 9000
```

> 注意：MTU 9000 需要所有节点 + 交换机都支持，否则会导致分片和丢包。不确定是否支持时可以跳过此项。

### 第六级：多 RGW 部署（后续优化方向）

当前仅 ceph-node1 运行 RGW。在 3 台 Ceph 节点上各部署一个 RGW 实例，前置 HAProxy 负载均衡，JuiceFS 连接 LB 地址。

## 瓶颈分析方法

如果所有调优手段都试过仍未达预期，按以下步骤逐层排查瓶颈。

### 1. 延迟分解

单次 4M 写入的 ~500ms 延迟，分解到各层：

```
fio write (500ms)
 ├── JuiceFS FUSE 层           — fuse_dispatch 耗时
 ├── TiKV 元数据写入            — grpc 往返 + RocksDB write
 │   ├── PD get_timestamp       — 当前 30-200ms (PD 日志 "get timestamp too slow")
 │   ├── TiKV prewrite+commit   — 2PC 事务
 │   └── RocksDB fsync          — 磁盘同步
 ├── S3 对象上传                — HTTP PUT to RGW
 │   ├── 网络传输（tikv-node → ceph-node1）
 │   ├── RGW 处理（HTTP → RADOS）
 │   ├── EC 编码（4+2）
 │   └── OSD 写入 + fsync      — 6 个 OSD 并行
 └── fio fsync (end_fsync=1)    — 等待 S3 确认
```

### 2. 各层监控命令

```bash
# === TiKV 层 ===
# PD 时间戳延迟
curl -s http://127.0.0.1:2379/metrics | grep "pd_request.*duration"

# TiKV gRPC 延迟
curl -s http://127.0.0.1:20160/metrics | grep "tikv_storage_engine_async_request_duration_seconds"

# RocksDB 写延迟
curl -s http://127.0.0.1:20160/metrics | grep "rocksdb_write_duration_seconds"

# TiKV CPU 和内存
top -b -n 1 -p $(pgrep tikv-server) | tail -1


# === 网络层 ===
# 测试到 RGW 的延迟和带宽
ping -c 100 192.168.11.11 | tail -1
iperf3 -c 192.168.11.11 -t 30

# 实时查看网络流量
sar -n DEV 1 10 | grep -E "eth|ens"


# === Ceph 层 ===
# OSD 延迟分布
ssh 192.168.11.11 "sudo ceph osd perf"

# RGW 请求统计
ssh 192.168.11.11 "sudo ceph daemon /var/run/ceph/*/ceph-client.rgw.*.asok perf dump 2>/dev/null | grep -A5 '\"get_obj\"\|\"put_obj\"'"

# 各 pool 的读写速率
ssh 192.168.11.11 "sudo ceph pg stat"


# === 系统层 ===
# 磁盘 I/O 延迟
iostat -x 1 10 | grep -E "sd[ab]"

# CPU 和上下文切换
vmstat 1 10

# 内存使用
free -h
```

### 3. 常见瓶颈定位

| 症状 | 可能原因 | 定位命令 |
|------|---------|---------|
| PD 时间戳延迟 >50ms | 单核 CPU 瓶颈，PD 与 TiKV 抢 CPU | `top -H -p $(pgrep pd-server)` |
| TiKV gRPC 延迟 >100ms | RocksDB write stall | `grep "write stall" /data/tikv/data/rocksdb.info` |
| S3 put 延迟 >200ms | RGW 单线程瓶颈 | `curl http://192.168.11.11:8000` 测 HTTP 延迟 |
| OSD apply latency >50ms | HDD 寻道延迟（EC 小块随机写） | `ceph osd perf` 的 apply_latency_ms |
| 网络带宽打满 (>80% 线速) | 单 1G 网口瓶颈 | `sar -n DEV 1` 查看 rx/tx Mbps |
| CPU iowait >10% | 磁盘 I/O 瓶颈 | `iostat -x 1` 查看 %iowait 和 await |
| JuiceFS FUSE 慢 | FUSE 内核模块单线程 | `/sys/fs/fuse/connections/*/waiting` 中的等待数 |

### 4. 快速诊断脚本

```bash
#!/bin/bash
# 保存为 diag-perf.sh，fio 测试期间在 tikv-node 运行
echo "=== PD Timestamp Latency ==="
curl -s http://127.0.0.1:2379/metrics | grep "pd_request_duration_seconds" | grep -v "#"

echo "=== TiKV Write Duration ==="
curl -s http://127.0.0.1:20160/metrics | grep "tikv_storage_engine_async_request_duration_seconds_bucket" | grep -v "#" | tail -5

echo "=== Network to RGW ==="
ping -c 5 192.168.11.11 | tail -1

echo "=== CPU ==="
top -b -n 1 | head -5

echo "=== Disk IO ==="
iostat -x 1 2 | tail -n+7
```
