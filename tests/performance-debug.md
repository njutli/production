# 第一次测试

## 本地测试结果(使用存储规格参数测试)
```
/home/turboai/lilingfeng/test_dir
mkdir -p /home/turboai/lilingfeng/test_dir/{1..100}
fio --directory=/home/turboai/lilingfeng/test_dir \
        --name=storage_test \
        --nrfiles=100 \
        --filesize=1G \
        --size=1G \
        --bs=256k \
        --rw=randrw \
        --ioengine=libaio \
        --iodepth=128 \
        --numjobs=128 \
        --direct=1 \
        --fallocate=none \
        --create_on_open=1 \
        --openfiles=100 \
        --group_reporting \
        --time_based \
        --runtime=60s

Run status group 0 (all jobs):
   READ: bw=209MiB/s (219MB/s), 209MiB/s-209MiB/s (219MB/s-219MB/s), io=12.2GiB (13.2GB), run=60140-60140msec
  WRITE: bw=411MiB/s (431MB/s), 411MiB/s-411MiB/s (431MB/s-431MB/s), io=24.1GiB (25.9GB), run=60140-60140msec

Disk stats (read/write):
  sdb: ios=588/106798, merge=0/118229, ticks=54579/7414714, in_queue=7469293, util=99.43%
turboai@ceph-node1:~$
Run status group 0 (all jobs):
   READ: bw=206MiB/s (216MB/s), 206MiB/s-206MiB/s (216MB/s-216MB/s), io=12.1GiB (13.0GB), run=60147-60147msec
  WRITE: bw=408MiB/s (427MB/s), 408MiB/s-408MiB/s (427MB/s-427MB/s), io=23.9GiB (25.7GB), run=60147-60147msec

Disk stats (read/write):
  sdb: ios=16/103618, merge=0/119552, ticks=2148/12988286, in_queue=12990435, util=99.32%
```

## 集群测试结果

### 使用JuiceFS官方参数测试
**测试命令**
```
mkdir -p /mnt/juicefs/test_dir/
fio --name=sequential-read --directory=/mnt/juicefs/test_dir/ --rw=read --refill_buffers --bs=4M --size=4G

mkdir -p /mnt/juicefs/test_dir/
fio --name=sequential-write --directory=/mnt/juicefs/test_dir/ --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1
```
#### 默认挂载
**读测试**
```
Run status group 0 (all jobs):
   READ: bw=7888KiB/s (8077kB/s), 7888KiB/s-7888KiB/s (8077kB/s-8077kB/s), io=4096MiB (4295MB), run=531733-531733msec
```

**写测试**
```
Run status group 0 (all jobs):
  WRITE: bw=7915KiB/s (8105kB/s), 7915KiB/s-7915KiB/s (8105kB/s-8105kB/s), io=4096MiB (4295MB), run=529920-529920msec

```

#### 调整juicefs缓存参数
**读测试**
```
Run status group 0 (all jobs):
   READ: bw=1367MiB/s (1433MB/s), 1367MiB/s-1367MiB/s (1433MB/s-1433MB/s), io=4096MiB (4295MB), run=2997-2997msec
```
**写测试**
```
Run status group 0 (all jobs):
  WRITE: bw=372MiB/s (390MB/s), 372MiB/s-372MiB/s (390MB/s-390MB/s), io=4096MiB (4295MB), run=11002-11002msec
```

### 使用存储规格参数测试
**测试命令**
```
mkdir -p /mnt/juicefs/test_dir/{1..100}
fio --directory=/mnt/juicefs/test_dir \
        --name=storage_test \
        --nrfiles=100 \
        --filesize=1G \
        --size=1G \
        --bs=256k \
        --rw=randrw \
        --ioengine=libaio \
        --iodepth=128 \
        --numjobs=128 \
        --direct=1 \
        --fallocate=none \
        --create_on_open=1 \
        --openfiles=100 \
        --group_reporting \
        --time_based \
        --runtime=60s
```

#### 默认挂载
```
Run status group 0 (all jobs):
  WRITE: bw=16.9MiB/s (17.7MB/s), 16.9MiB/s-16.9MiB/s (17.7MB/s-17.7MB/s), io=1061MiB (1113MB), run=62805-62805msec
```

#### 调整juicefs缓存参数
```
juicefs mount -d tikv://127.0.0.1:2379/juicefs-prod /mnt/juicefs --cache-dir /var/jfsCache --cache-size 102400 --prefetch 1 --max-uploads 20 --writeback --open-cache 10 --attr-cache 10

Run status group 0 (all jobs):
   READ: bw=5271KiB/s (5398kB/s), 5271KiB/s-5271KiB/s (5398kB/s-5398kB/s), io=312MiB (327MB), run=60609-60609msec
  WRITE: bw=38.8MiB/s (40.7MB/s), 38.8MiB/s-38.8MiB/s (40.7MB/s-40.7MB/s), io=2350MiB (2464MB), run=60609-60609msec
```

# 第二次测试
集群节点网络带宽均提升至千兆

### 使用JuiceFS官方参数测试
**测试命令**
```
mkdir -p /mnt/juicefs/test_dir/
fio --name=sequential-read --directory=/mnt/juicefs/test_dir/ --rw=read --refill_buffers --bs=4M --size=4G

mkdir -p /mnt/juicefs/test_dir/
fio --name=sequential-write --directory=/mnt/juicefs/test_dir/ --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1
```
#### 默认挂载
**读测试**
```
Run status group 0 (all jobs):
   READ: bw=83.7MiB/s (87.8MB/s), 83.7MiB/s-83.7MiB/s (87.8MB/s-87.8MB/s), io=4096MiB (4295MB), run=48937-48937msec
```
**写测试**
```
Run status group 0 (all jobs):
  WRITE: bw=80.1MiB/s (84.0MB/s), 80.1MiB/s-80.1MiB/s (84.0MB/s-84.0MB/s), io=4096MiB (4295MB), run=51106-51106msec
```

### 使用存储规格参数测试
**测试命令**
```
mkdir -p /mnt/juicefs/test_dir/{1..100}
fio --directory=/mnt/juicefs/test_dir \
        --name=storage_test \
        --nrfiles=100 \
        --filesize=1G \
        --size=1G \
        --bs=256k \
        --rw=randrw \
        --ioengine=libaio \
        --iodepth=128 \
        --numjobs=128 \
        --direct=1 \
        --fallocate=none \
        --create_on_open=1 \
        --openfiles=100 \
        --group_reporting \
        --time_based \
        --runtime=60s
```

#### 默认挂载
```
Run status group 0 (all jobs):
   READ: bw=3788KiB/s (3879kB/s), 3788KiB/s-3788KiB/s (3879kB/s-3879kB/s), io=226MiB (237MB), run=61029-61029msec
  WRITE: bw=36.0MiB/s (37.7MB/s), 36.0MiB/s-36.0MiB/s (37.7MB/s-37.7MB/s), io=2195MiB (2301MB), run=61029-61029msec
```

#### 调整juicefs缓存参数
```
juicefs mount -d tikv://127.0.0.1:2379/juicefs-prod /mnt/juicefs --cache-dir /var/jfsCache --cache-size 102400 --prefetch 1 --max-uploads 20 --writeback --open-cache 10 --attr-cache 10

Run status group 0 (all jobs):
   READ: bw=5464KiB/s (5595kB/s), 5464KiB/s-5464KiB/s (5595kB/s-5595kB/s), io=323MiB (339MB), run=60585-60585msec
  WRITE: bw=39.4MiB/s (41.3MB/s), 39.4MiB/s-39.4MiB/s (41.3MB/s-41.3MB/s), io=2385MiB (2501MB), run=60585-60585msec
```

# 第三次测试
部署RGW数量 1 -> 2 ，通过LB实现负载均衡


