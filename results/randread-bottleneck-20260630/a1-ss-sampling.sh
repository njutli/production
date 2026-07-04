#!/bin/bash
OUTDIR=/home/turboai/production/results/randread-bottleneck-20260630
MODE=$1  # randread or seqread
RW=$([ "$MODE" = "randread" ] && echo "randread" || echo "read")

# Drop
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  ssh -o ConnectTimeout=10 $ip 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null' 2>/dev/null
done
sleep 2

# Start fio
fio --directory=/mnt/juicefs/test_dir --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=$RW \
    --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 \
    --fallocate=none --openfiles=100 --create_serialize=0 \
    --group_reporting --time_based --runtime=60s \
    > $OUTDIR/a1-${MODE}-fio.txt 2>&1 &
FIO_PID=$!
sleep 20
echo "fio PID=$FIO_PID, starting ss samples"

# 10 samples, 2s apart
for n in $(seq 1 10); do
  echo "=== sample $n $(date +%H:%M:%S) ===" >> $OUTDIR/a1-ss-${MODE}.txt
  ss -tin dst 192.168.11.11 or dst 192.168.11.13 or dst 192.168.11.14 >> $OUTDIR/a1-ss-${MODE}.txt 2>/dev/null
  sleep 2
done

wait $FIO_PID 2>/dev/null
grep 'READ: bw=' $OUTDIR/a1-${MODE}-fio.txt | head -1
echo "A1 $MODE done"
