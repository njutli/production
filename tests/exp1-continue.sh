#!/bin/bash
# ============================================================
# Experiment 1 continuation: S4(128G) + S5(layout 128G)
# ============================================================
set -uo pipefail
META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
SEQ_DIR="${MNT}/seq_dir"
PARENT="/home/turboai/production/results/write-forensics-20260705"
OUTBASE="${PARENT}/exp1-threshold"
MOUNT_BIN="/usr/local/bin/juicefs"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh

snapshot_backend(){
  local tag="$1" outdir="$2"
  { echo "### date: $(date)"; echo "== ceph health detail =="; sudo ceph health detail 2>&1
    echo "== ceph -s =="; sudo ceph -s 2>&1; echo "== ceph osd perf =="; sudo ceph osd perf 2>&1
  } > "${outdir}/backend-${tag}.txt" 2>&1
}

drop_all_caches(){
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@$ip" "echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null" 2>/dev/null && echo "  $ip dropped" || echo "  $ip FAILED"
  done
}

restart_stalled_osds(){
  for o in $(sudo ceph health detail 2>&1 | grep -oP 'osd\.\d+' | sort -u); do
    local num=${o#osd.} host pw
    case $num in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; *) continue ;; esac
    echo "  restarting $o"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@${host}" "sudo cephadm shell -- ceph orch daemon restart $o" 2>/dev/null || true
    sleep 15
  done
  sleep 30
}

wait_for_clean(){
  local logf="$1" elapsed=0
  echo "## wait_for_clean start: $(date)" >> "$logf"
  while [ $elapsed -lt 600 ]; do
    sleep 15; elapsed=$((elapsed+15))
    local h; h=$(sudo ceph health 2>&1 | head -1)
    echo "  [${elapsed}s] ${h}" >> "$logf"
    if [ "$h" = "HEALTH_OK" ]; then echo "## OK after ${elapsed}s" >> "$logf"; return 0; fi
  done
  echo "## timeout, restarting" >> "$logf"
  restart_stalled_osds
  elapsed=0
  while [ $elapsed -lt 600 ]; do
    sleep 15; elapsed=$((elapsed+15))
    local h; h=$(sudo ceph health 2>&1 | head -1)
    echo "  [restart+${elapsed}s] ${h}" >> "$logf"
    if [ "$h" = "HEALTH_OK" ]; then echo "## OK after restart+${elapsed}s" >> "$logf"; return 0; fi
  done
  echo "## FATAL: still not OK" >> "$logf"; exit 1
}

wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){
  local val unit; val=$(grep -oP "$2: bw=\K[0-9.]+" "$1" | head -1)
  unit=$(grep -oP "$2: bw=[0-9.]+\K[a-zA-Z]+/s" "$1" | head -1)
  [ -z "$val" ] && { echo "0"; return; }
  if [ "$unit" = "KiB/s" ]; then awk "BEGIN{printf \"%.1f\", $val/1024}"; else echo "$val"; fi
}
rxget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }
txget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $10}'; }

start_perf_timeline(){
  local outdir="$1" interval="${2:-15}"
  for o in 0 1 2 3 4 5; do echo "### osd.${o} perf start ($(date))" > "${outdir}/osd${o}-perf-timeline.txt"; done
  echo "### health timeline start ($(date))" > "${outdir}/health-timeline.txt"
  {
    while pgrep -x fio >/dev/null 2>&1; do
      local ts; ts=$(date +%H:%M:%S)
      echo "--- ${ts} ---" >> "${outdir}/health-timeline.txt"
      sudo ceph health detail 2>&1 >> "${outdir}/health-timeline.txt"
      for o in 0 1 2 3 4 5; do
        local host pw
        case $o in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; esac
        local dump; dump=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          "turboai@${host}" "sudo cephadm shell -- ceph daemon osd.${o} perf dump 2>/dev/null" 2>/dev/null) || true
        [ -n "$dump" ] && { echo "--- ${ts} ---"; echo "$dump" | grep -E '"op_w"|"op_w_latency"|"commit_lat"|"apply_lat"|"kv_sync_lat"|"kv_commit_lat"|"compact"|"compact_queue"|"db_used_bytes"|"files_written"|"bytes_written"|"read_random"|"throttle"|"slow_op"'; } >> "${outdir}/osd${o}-perf-timeline.txt"
      done
      sleep "$interval"
    done
    echo "--- $(date) ---" >> "${outdir}/health-timeline.txt"; sudo ceph health detail 2>&1 >> "${outdir}/health-timeline.txt"
  } & PERF_TIMELINE_PID=$!
}
stop_perf(){ kill $PERF_TIMELINE_PID 2>/dev/null; wait $PERF_TIMELINE_PID 2>/dev/null || true; }

start_iostat(){
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip \
      "iostat -x 1 > /tmp/iostat-\$(hostname).log 2>&1 &" 2>/dev/null &
  done
}
stop_iostat(){
  local outdir="$1"
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip \
      "pkill -f 'iostat -x 1' 2>/dev/null; sleep 1" 2>/dev/null
    local h; h=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip "hostname" 2>/dev/null)
    sshpass -p "$pw" scp -o StrictHostKeyChecking=no "turboai@${ip}:/tmp/iostat-${h}.log" "${outdir}/iostat-${ip}.log" 2>/dev/null || true
  done
}

run_single_seq(){
  local label="$1" size_g="$2" outdir="$3"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local of="${outdir}/fio-${label}.txt"; local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  echo "# ${label}: seqwrite bs=256K size=${size_g}G end_fsync=1 ($(date))" > "$of"
  fio --name="${label}" --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --bs=256K --size="${size_g}G" --end_fsync=1 >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX=${rxmb}MB NIC_TX=${txmb}MB" >> "$of"
  echo "  ${label}: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${outdir}/run.log"
  wait_fio
}

run_layout_style(){
  local outdir="$1"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local of="${outdir}/fio-S5-layout.txt"; local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  echo "# S5: layout-style 128jobs×1G bs=4M end_fsync=1 ($(date))" > "$of"
  fio --name=layout --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --filesize=1G --size=1G --bs=4M --numjobs=128 --group_reporting --end_fsync=1 >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX=${rxmb}MB NIC_TX=${txmb}MB" >> "$of"
  echo "  S5-layout: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${outdir}/run.log"
  wait_fio
}

do_mount(){
  juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
  sleep 3
  juicefs mount -d --cache-size 0 --max-uploads 150 "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
  sleep 3; mountpoint -q "$MNT" || { echo "FATAL"; exit 1; }
}

# ============================================================
OUTDIR="${OUTBASE}/S4-128G"; mkdir -p "$OUTDIR"
echo "=== S4-128G ($(date)) ===" | tee -a "${OUTBASE}/run2.log"
wait_for_clean "${OUTDIR}/cooldown-into2.log"
do_mount
snapshot_backend "before" "$OUTDIR"
drop_all_caches; check_ceph_health "before S4-128G"; sleep 3
start_perf_timeline "$OUTDIR" 15; start_iostat
run_single_seq "S4-128G" 128 "$OUTDIR"
stop_perf; stop_iostat "$OUTDIR"
snapshot_backend "after" "$OUTDIR"
echo "  S4 DONE ($(date))" | tee -a "${OUTBASE}/run2.log"

# ============================================================
OUTDIR="${OUTBASE}/S5-128G-layout"; mkdir -p "$OUTDIR"
echo "=== S5-128G-layout ($(date)) ===" | tee -a "${OUTBASE}/run2.log"
wait_for_clean "${OUTDIR}/cooldown-into2.log"
snapshot_backend "before" "$OUTDIR"
drop_all_caches; check_ceph_health "before S5-layout"; sleep 3
start_perf_timeline "$OUTDIR" 15; start_iostat
run_layout_style "$OUTDIR"
stop_perf; stop_iostat "$OUTDIR"
snapshot_backend "after" "$OUTDIR"
echo "ALL DONE ($(date))" | tee -a "${OUTBASE}/run2.log"
