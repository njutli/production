#!/bin/bash
set -euo pipefail
OUT=/tmp/juicefs-v02-20260819-110158/quiescence
MNT=/mnt/juicefs-v02

# Save .stats pre
curl -s http://127.0.0.1:9567/metrics > $OUT/stats-pre-probe1-full.txt 2>/dev/null

# drop_caches
sudo -n bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null

# 60s write probe
fio --directory=$MNT/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60 --write_bw_log=$OUT/probe1 --log_avg_msec=1000 --kb_base=1024 > $OUT/probe1-fio.txt 2>&1
RC=$?
echo $RC > $OUT/probe1.rc
echo "FIO_DONE rc=$RC $(date)" >> $OUT/probe1-fio.txt

# Save .stats post
curl -s http://127.0.0.1:9567/metrics > $OUT/stats-post-probe1-full.txt 2>/dev/null

# Save objects
sudo -n ceph df --format=json 2>/dev/null | python3 -c "import json,sys;[print('objects=%d'%p['stats']['objects']) for p in json.load(sys.stdin)['pools'] if p['name']=='juicefs-data']" > $OUT/objects-post-probe1.txt 2>/dev/null

echo "ALL_DONE $(date)" >> $OUT/probe1-fio.txt
