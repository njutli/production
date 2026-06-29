#!/bin/bash
# Commands: seq-4m-bs4m cold

# format (cold only)
juicefs format --storage ceph --bucket ceph://juicefs-data   --access-key ceph --secret-key client.juicefs   --block-size 4M --trash-days 0   tikv://192.168.11.12:2379/juicefs-prod juicefs-prod

# mount
juicefs mount -d --cache-size 0  tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# sequential tests (bs=4M)
fio --name=prep --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G
fio --name=seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=4M --size=4G
fio --name=seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1
fio --name=multi-seqread --directory=/mnt/juicefs/seq_dir --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting
fio --name=multi-seqwrite --directory=/mnt/juicefs/seq_dir --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting --end_fsync=1
