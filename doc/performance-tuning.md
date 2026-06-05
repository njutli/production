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

```bash
bash production/tune-servers.sh tikv    # tikv-node 机器
bash production/tune-servers.sh ceph    # 3 台 ceph-node
```

应用内容：
- 禁用 swap（防止内存页换出导致延迟抖动）
- 禁用透明大页 THP（减少内存碎片）
- 提高文件描述符上限（TiKV/Ceph 高并发场景需要）
- 网络 sysctl 调优（tcp 缓冲区、backlog 等）
- I/O 调度器优化

> TiKV: fd limits 需要 `systemctl restart pd tikv` 生效  
> Ceph: swap/THP/sysctl/I/O 调度器即时生效，fd limits 需重启 OSD

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
