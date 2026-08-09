#!/bin/bash
set -euo pipefail
export LC_ALL=C

# osd-straggler-test.sh — straggler 确认实验
# 180s randread + 顺序查询 6 OSD perf dump（每 2s）
# 输出格式：timestamp osd.N metric avgtime avgcount，便于离线计算 delta

MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
RESULTS="/tmp/osd-straggler-test"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
RUNTIME=180
OSD_LIST="0 1 2 3 4 5"

mkdir -p "${RESULTS}"

JFS_PID=$(pgrep -f '/usr/local/bin/juicefs' | head -1)
echo "juicefs PID: ${JFS_PID}"

# === 启动后台采集 ===

# 157: mpstat
mpstat -P ALL 1 $((RUNTIME + 10)) > "${RESULTS}/mpstat.txt" &

# 157: pidstat
[ -n "${JFS_PID}" ] && pidstat -p ${JFS_PID} -ru 1 $((RUNTIME + 10)) > "${RESULTS}/pidstat.txt" &

# 157: NIC 逐秒
( for sec in $(seq 1 $((RUNTIME + 10))); do
    echo "$(date +%s) $(cat /proc/net/dev | grep enp139s0f0np0)"
    sleep 1
  done ) > "${RESULTS}/nic.txt" &

# OSD 节点: iostat
for ip in "${SLAVES[@]}"; do
    ${SSHPASS_CMD}@${ip} "iostat -x 1 $((RUNTIME + 10))" > "${RESULTS}/iostat-${ip}.txt" &
done

# === OSD perf dump（顺序查询，每 2s） ===
(
  for i in $(seq 1 $((RUNTIME / 2 + 5))); do
    ts=$(date '+%H:%M:%S')
    for osd in ${OSD_LIST}; do
      sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
o=d.get('osd',{})
for k in ['op_r','op_r_latency','op_r_process_latency','subop_latency','op_latency']:
    v=o.get(k,{})
    if isinstance(v,dict):
        at=v.get('avgtime',0)
        ac=v.get('avgcount',0)
        print('%s osd.%d %s avgtime=%.9f avgcount=%d' % ('$ts', ${osd}, k, at, ac))
" 2>/dev/null || echo "${ts} osd.${osd} ERROR"
    done
    sleep 2
  done
) > "${RESULTS}/osd-perf-ordered.txt" &

# === fio randread 180s ===
echo "Starting fio randread for ${RUNTIME}s..."
fio --directory="${TEST_DIR}" \
    --name=read_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 --group_reporting \
    --time_based --runtime=${RUNTIME} \
    --write_bw_log="${RESULTS}/randread" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS}/fio.txt"

# === 停止采集 ===
sleep 5  # 让最后一轮采集完成
pkill -P $$ 2>/dev/null || true
wait 2>/dev/null || true

echo "Done. Results in ${RESULTS}/"
ls -la "${RESULTS}/"
