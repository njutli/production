#!/bin/bash
# Commands: cold-cache0-mu150 randonly (patched v1.3.1)
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)
# 注：跳过顺序测试，仅随机测试（避免 BlueFS stall）

# drop OSD cache
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  sshpass -p "TurboAi@303" ssh turboai@$ip "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null"
done

# mount
juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# random tests (bs=256K, 3 rounds)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
