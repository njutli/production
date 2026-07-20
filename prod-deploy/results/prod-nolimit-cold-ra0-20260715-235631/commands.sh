#!/bin/bash
# 完整命令记录：不限速 ra0 冷态基线

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
JUICEFS_BW_LOG_DIR="/tmp/jfs-bw"

# format
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
  "${META}" juicefs-prod

# mount (ra0)
juicefs mount -d --storage ceph --bucket ceph://juicefs-data --max-uploads 150 \
  --cache-size 0 --max-readahead 0 "${META}" "${MNT}"

# seqread (256k, 1job, 180s)
fio --name=seqread --directory="${TEST_DIR}/" --rw=read --refill_buffers --bs=256k --size=4G \
    --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/seqread" --log_avg_msec=1000

# seqwrite (4M, 1job, fsync)
fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/seqwrite" --log_avg_msec=1000

# mseqread (256k, 16job, 180s)
fio --name=mseqread --directory="${TEST_DIR}/mseq/" --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting \
    --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/mseqread" --log_avg_msec=1000

# mseqwrite (4M, 16job, fsync)
fio --name=mseqwrite --directory="${TEST_DIR}/mseqw/" --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting \
    --direct=1 --ioengine=psync --iodepth=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/mseqwrite" --log_avg_msec=1000

# layout (128job×1G)
fio --directory="${TEST_DIR}/layout" --name=storage_test --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1 \
    --write_bw_log="${JUICEFS_BW_LOG_DIR}/layout" --log_avg_msec=1000

# randread R1-R3 (256k, 128job, 180s)
for i in 1 2 3; do
  fio --directory="${TEST_DIR}/layout" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --group_reporting --time_based --runtime=180 \
      --write_bw_log="${JUICEFS_BW_LOG_DIR}/randread-r${i}" --log_avg_msec=1000
done

# randwrite R1-R3 (fresh, create_on_open)
for i in 1 2 3; do
  fio --directory="${TEST_DIR}/randwrite" --name=storage_test --nrfiles=100 --filesize=1G --size=1G \
      --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
      --group_reporting --time_based --runtime=180 \
      --write_bw_log="${JUICEFS_BW_LOG_DIR}/randwrite-r${i}" --log_avg_msec=1000
done

# randrw R1-R3 (fresh, create_on_open)
for i in 1 2 3; do
  fio --directory="${TEST_DIR}/randrw" --name=storage_test --nrfiles=100 --filesize=1G --size=1G \
      --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --create_on_open=1 --openfiles=100 \
      --group_reporting --time_based --runtime=180 \
      --write_bw_log="${JUICEFS_BW_LOG_DIR}/randrw-r${i}" --log_avg_msec=1000
done

rm -rf "${TEST_DIR}"
