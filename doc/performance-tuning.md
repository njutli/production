# JuiceFS Performance Tuning Guide

## Current Bottleneck Analysis

Your sequential read/write results (~8 MiB/s) vs official (~300+ MiB/s):

| Factor | Your Setup | Impact |
|--------|-----------|--------|
| **fio engine** | psync (sync, iodepth=1) | One I/O at a time, no pipeline |
| **I/O depth** | 1 | Each 4M I/O waits for full round-trip |
| **Write path latency** | ~350ms median per 4M I/O | TiKV PD "get timestamp too slow" + S3 put |
| **Metadata engine** | Single-node TiKV | PD warnings show 30-200ms timestamp latency |
| **RGW gateways** | 1 instance on ceph-node1 | All S3 traffic through single node |
| **System tuning** | None | Swap, THP, limits at defaults |

Root cause: `psync, iodepth=1` = one I/O at a time. Each 4M write takes ~500ms round-trip (TiKV metadata + RGW S3 put). 4 MiB / 0.5s = 8 MiB/s. With iodepth=32, pipeline 32 I/Os simultaneously → 32x throughput.

## Tier 1: fio Parameters (immediate, no redeploy)

```bash
# Sequential write (libaio + pipeline)
fio --name=seq-write --directory=/mnt/juicefs/test_dir/ \
    --rw=write --bs=4M --size=4G \
    --ioengine=libaio --iodepth=32 \
    --numjobs=1 --end_fsync=1 --group_reporting

# Sequential read (pre-create file first)
truncate -s 4G /mnt/juicefs/test_dir/seq-read-file
fio --name=seq-read --filename=/mnt/juicefs/test_dir/seq-read-file \
    --rw=read --bs=4M --size=4G \
    --ioengine=libaio --iodepth=32 \
    --numjobs=1 --group_reporting

# Random RW (small block, multi-job)
fio --name=rnd-rw --directory=/mnt/juicefs/test_dir/ \
    --rw=randrw --bs=256k --size=1G \
    --ioengine=libaio --iodepth=32 \
    --numjobs=4 --group_reporting --runtime=60 --time_based
```

## Tier 2: System Tuning

```bash
bash production/tune-servers.sh
```

Applies: disable swap, disable THP, increase fd limits, network sysctl tuning.

## Tier 3: TiKV Tuning (requires TiKV restart)

Edit `config/tikv/tikv1.toml`:

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

Then restart:
```bash
bash production/deploy-tikv.sh restart
```

## Tier 4: Multi-RGW (future)

Deploy RGW on all 3 nodes, add HAProxy LB in front, point JuiceFS at LB.

## Expected Performance Improvement

| Tier Applied | Seq Write (1 job) | Seq Read (1 job) |
|-------------|-------------------|------------------|
| None (current) | ~8 MiB/s | ~8 MiB/s |
| Tier 1 (libaio+iodepth) | **50-150 MiB/s** | **100-250 MiB/s** |
| Tier 1+2 (system tuning) | 80-200 MiB/s | 150-300 MiB/s |
| Tier 1+2+3 (TiKV tuning) | 100-250 MiB/s | 200-400 MiB/s |

## Bottleneck Isolation Commands

```bash
# TiKV metrics during test
curl -s http://127.0.0.1:2379/metrics | grep -E "grpc_server_handling|tikv_raftstore"

# Ceph OSD latency
ssh 192.168.11.11 "sudo ceph osd perf"

# Network throughput
sar -n DEV 1 10
```
