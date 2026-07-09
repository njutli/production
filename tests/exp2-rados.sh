#!/bin/bash
# ============================================================
# Experiment 2: rados bench 测后端裸顺序写能力 → 判 P3
# ============================================================
set -uo pipefail
PARENT="/home/turboai/production/results/write-forensics-20260705"
OUTDIR="${PARENT}/exp2-backend-raw"
POOL="juicefs-data"

mkdir -p "$OUTDIR"
logf="${OUTDIR}/run.log"
echo "=== Experiment 2: rados bench ($(date)) ===" | tee "$logf"

drop_all_caches(){
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@$ip" "echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null" 2>/dev/null || true
  done; echo "  drops done"
}

start_iostat(){
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip \
      "iostat -x 1 > /tmp/iostat-\$(hostname).log 2>&1 &" 2>/dev/null &
  done
}
stop_iostat(){
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip \
      "pkill -f 'iostat -x 1' 2>/dev/null; sleep 1" 2>/dev/null
    local h; h=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip "hostname" 2>/dev/null)
    sshpass -p "$pw" scp -o StrictHostKeyChecking=no "turboai@${ip}:/tmp/iostat-${h}.log" "${OUTDIR}/iostat-${ip}.log" 2>/dev/null || true
  done
}

start_health_poll(){
  {
    while pgrep -x rados >/dev/null 2>&1; do
      echo "--- $(date) ---" >> "${OUTDIR}/health-timeline.txt"
      sudo ceph health detail 2>&1 >> "${OUTDIR}/health-timeline.txt"
      sleep 10
    done
    echo "--- $(date) ---" >> "${OUTDIR}/health-timeline.txt"
    sudo ceph health detail 2>&1 >> "${OUTDIR}/health-timeline.txt"
  } & HPOLL=$!
}
stop_health_poll(){ kill $HPOLL 2>/dev/null; wait $HPOLL 2>/dev/null || true; }

# ---- R1: 4M block, 30s ----
echo "" | tee -a "$logf"
echo "## R1: rados bench -b 4M -t 16 30s ($(date))" | tee -a "$logf"
{
  echo "## ceph health"; sudo ceph health 2>&1 | head -1
  echo "## ceph osd perf"; sudo ceph osd perf 2>&1
} > "${OUTDIR}/backend-before-R1.txt"
drop_all_caches
start_iostat; start_health_poll
sudo rados -p "$POOL" bench 30 write -b 4M -t 16 --no-cleanup 2>&1 | tee "${OUTDIR}/rados-bench-4M.txt"
stop_iostat; stop_health_poll
{
  echo "## ceph health"; sudo ceph health 2>&1 | head -1
} > "${OUTDIR}/backend-after-R1.txt"
echo "  R1 DONE ($(date))" | tee -a "$logf"

# ---- R2: 256K block, 60s ----
echo "" | tee -a "$logf"
echo "## R2: rados bench -b 256K -t 16 60s ($(date))" | tee -a "$logf"
{
  echo "## ceph health"; sudo ceph health 2>&1 | head -1
} > "${OUTDIR}/backend-before-R2.txt"
drop_all_caches
start_iostat; start_health_poll
sudo rados -p "$POOL" bench 60 write -b 256K -t 16 --no-cleanup 2>&1 | tee "${OUTDIR}/rados-bench-256K.txt"
stop_iostat; stop_health_poll
{
  echo "## ceph health"; sudo ceph health 2>&1 | head -1
} > "${OUTDIR}/backend-after-R2.txt"

echo "" | tee -a "$logf"
echo "=== Experiment 2 DONE ($(date)) ===" | tee -a "$logf"
