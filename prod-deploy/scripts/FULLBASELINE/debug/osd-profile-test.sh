#!/bin/bash
set -euo pipefail
export LC_ALL=C

# osd-profile-test.sh — 180s randread + OSD 侧只读采集
# 验证 PG 主分布倾斜 / OSD straggler / 客户端争用
# 全部只读，无 sudo 写操作

MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
RESULTS="/tmp/osd-profile-test"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"
RUNTIME=180

mkdir -p "${RESULTS}"

# JuiceFS PID
JFS_PID=$(pgrep -f '/usr/local/bin/juicefs' | head -1)
echo "juicefs PID: ${JFS_PID}"

# === 静态信息（一次性采集） ===
echo "=== pool settings ==="
sudo ceph osd pool get juicefs-data all 2>/dev/null > "${RESULTS}/pool-settings.txt"
echo "=== pg dump ==="
sudo ceph pg dump pgs_brief 2>/dev/null > "${RESULTS}/pg-map.txt"
echo "=== osd tree ==="
sudo ceph osd tree 2>/dev/null > "${RESULTS}/osd-tree.txt"

# === 启动后台采集 ===

# 1. 157: mpstat（逐秒 CPU）
mpstat -P ALL 1 $((RUNTIME + 10)) > "${RESULTS}/mpstat.txt" &
MPSTAT_PID=$!

# 2. 157: pidstat（逐秒 juicefs 进程 CPU）
if [ -n "${JFS_PID}" ]; then
    pidstat -p ${JFS_PID} -ru 1 $((RUNTIME + 10)) > "${RESULTS}/pidstat.txt" &
    PIDSTAT_PID=$!
fi

# 3. 157: NIC 逐秒
( for sec in $(seq 1 $((RUNTIME + 10))); do
    echo "$(date +%s) $(cat /proc/net/dev | grep enp139s0f0np0)"
    sleep 1
  done ) > "${RESULTS}/nic.txt" &
NIC_PID=$!

# 4. OSD 节点: iostat 逐秒（通过 SSH）
for ip in "${SLAVES[@]}"; do
    ${SSHPASS_CMD}@${ip} "iostat -x 1 $((RUNTIME + 10))" > "${RESULTS}/iostat-${ip}.txt" &
done

# 5. ceph tell osd.N perf dump（每 2s，并行查 6 OSD）
(
  for i in $(seq 1 $((RUNTIME / 2 + 5))); do
    echo "=== t=$((i*2)) $(date '+%H:%M:%S') ==="
    for osd in 0 1 2 3 4 5; do
        (
          echo "--- osd.${osd} ---"
          sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
o=d.get("osd",{})
for k in ["op_r","op_r_latency","op_r_process_latency","subop_latency","op_latency"]:
    v=o.get(k,{})
    if isinstance(v,dict):
        print("  %s: avg=%.6f count=%d avgcount=%d" % (k, v.get("avgtime",0), v.get("count",0), v.get("avgcount",0)))
    else:
        print("  %s: %s" % (k, v))
' 2>/dev/null || echo "  (error)"
        ) &
    done
    wait
    sleep 2
  done
) > "${RESULTS}/osd-perf.txt" &
OSD_PERF_PID=$!

# === fio randread（前台 180s） ===
echo "Starting fio randread for ${RUNTIME}s..."
fio --directory="${TEST_DIR}" \
    --name=read_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 --group_reporting \
    --time_based --runtime=${RUNTIME} \
    --write_bw_log="${RESULTS}/randread" --log_avg_msec=1000 \
    2>&1 | tee "${RESULTS}/fio.txt"

# === 停止采集 ===
kill ${MPSTAT_PID} ${PIDSTAT_PID:-} ${NIC_PID} ${OSD_PERF_PID} 2>/dev/null || true
wait 2>/dev/null || true

echo "Done. Results in ${RESULTS}/"
ls -la "${RESULTS}/"
