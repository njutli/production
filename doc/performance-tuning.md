# JuiceFS 性能调优指南

## 当前瓶颈分析

当前顺序读写约 8 MiB/s，距离官方参考值（300+ MiB/s）差距较大：

| 因素 | 当前状态 | 影响 |
|------|---------|------|
| **fio 引擎** | psync（同步，iodepth=1） | 一次只发一个 I/O，无流水线 |
| **I/O 深度** | 1 | 每个 4M I/O 必须等完整往返 |
| **写路径延迟** | 中位 ~350ms/4M I/O | TiKV PD 时间戳获取慢 + S3 写入 |
| **元数据引擎** | 单节点 TiKV | PD 日志持续报 "get timestamp too slow"（30-200ms） |
| **RGW 网关** | 仅 ceph-node1 一个实例 | 所有 S3 流量走单一节点 |
| **系统调优** | 未做 | swap、THP、fd limits 均为默认值 |

根本原因：`psync, iodepth=1` 串行执行 I/O。每个 4M 写入需约 500ms 往返（TiKV 元数据 + RGW S3 写入），4 MiB / 0.5s ≈ 8 MiB/s。改用 `iodepth=32` 可同时流水线 32 个 I/O，理论提升 32 倍。

## 第一级：fio 参数优化（立即生效，无需重新部署）

```bash
# 顺序写（libaio + 流水线）
fio --name=seq-write --directory=/mnt/juicefs/test_dir/ \
    --rw=write --bs=4M --size=4G \
    --ioengine=libaio --iodepth=32 \
    --numjobs=1 --end_fsync=1 --group_reporting

# 顺序读（先预创建文件，避免 fio 布局阶段卡住）
truncate -s 4G /mnt/juicefs/test_dir/seq-read-file
fio --name=seq-read --filename=/mnt/juicefs/test_dir/seq-read-file \
    --rw=read --bs=4M --size=4G \
    --ioengine=libaio --iodepth=32 \
    --numjobs=1 --group_reporting

# 随机读写（小块、多任务）
fio --name=rnd-rw --directory=/mnt/juicefs/test_dir/ \
    --rw=randrw --bs=256k --size=1G \
    --ioengine=libaio --iodepth=32 \
    --numjobs=4 --group_reporting --runtime=60 --time_based
```

## 第二级：系统调优

```bash
bash production/tune-servers.sh tikv    # tikv-node 机器
bash production/tune-servers.sh ceph    # 3 台 ceph-node
```

应用内容：禁用 swap、禁用透明大页（THP）、提高文件描述符上限、网络 sysctl 调优、I/O 调度器优化。

> TiKV: fd limits 需要 `systemctl restart pd tikv` 生效  
> Ceph: swap/THP/sysctl/I/O 调度器即时生效，fd limits 需重启 OSD

## 第三级：TiKV 调优（需重启 TiKV）

编辑 `config/tikv/tikv1.toml`：

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

## 第四级：多 RGW 部署（后续优化方向）

在 3 台 Ceph 节点上各部署一个 RGW 实例，前置 HAProxy 负载均衡，JuiceFS 连接 LB 地址。当前仅 ceph-node1 运行 RGW。

## 预期性能提升

| 调优级别 | 顺序写（1 任务） | 顺序读（1 任务） |
|---------|----------------|----------------|
| 未调优（当前） | ~8 MiB/s | ~8 MiB/s |
| 一级（libaio+iodepth） | 50-150 MiB/s | 100-250 MiB/s |
| 一级+二级（系统调优） | 80-200 MiB/s | 150-300 MiB/s |
| 一级+二级+三级（TiKV 调优） | 100-250 MiB/s | 200-400 MiB/s |

## 瓶颈定位命令

```bash
# 测试期间查看 TiKV 指标
curl -s http://127.0.0.1:2379/metrics | grep -E "grpc_server_handling|tikv_raftstore"

# Ceph OSD 延迟
ssh 192.168.11.11 "sudo ceph osd perf"

# 网络吞吐
sar -n DEV 1 10
```
