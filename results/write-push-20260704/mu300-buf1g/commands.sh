#!/bin/bash
# Grid: mu300-buf1g
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)
juicefs umount /mnt/juicefs 2>/dev/null || true
sleep 3
juicefs mount -d --cache-size 0 --max-uploads 300 --buffer-size 1024 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# seqwrite
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
# randwrite
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
