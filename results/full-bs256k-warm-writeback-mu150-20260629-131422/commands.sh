#!/bin/bash
# Commands: full-bs256k warm-writeback-mu150

# format (cold only)
juicefs format --storage ceph --bucket ceph://juicefs-data   --access-key ceph --secret-key client.juicefs   --block-size 256K --trash-days 0   tikv://192.168.11.12:2379/juicefs-prod juicefs-prod

# mount
juicefs mount -d --cache-size 102400 --cache-dir /data/jfsCache --max-uploads 150 --writeback tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# sequential tests (bs=256K)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1

# layout (bs=4M, 128 jobs x 1G)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=4M --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1

# random tests (bs=256K, 3 rounds)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
