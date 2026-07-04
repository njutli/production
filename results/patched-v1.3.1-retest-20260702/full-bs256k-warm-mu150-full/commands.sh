#!/bin/bash
# Commands: warm-mu150-full (patched v1.3.1)
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)

# mount
juicefs mount -d --cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# preheat
fio --directory=/mnt/juicefs/test_dir --name=preheat --filesize=1G --size=1G --bs=4M --rw=read --numjobs=128 --fallocate=none --group_reporting

# sequential tests (bs=256K)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1

# random tests (bs=256K, 5 rounds)
# ... (repeated 5 times)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
