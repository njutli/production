#!/bin/bash
# ============================================================
# Experiment 1: 阶梯写入找 stall 门槛 + 复现 layout 悖论
# 判 P1/P2
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
PARENT="/home/turboai/production/results/write-forensics-20260705"
OUTBASE="${PARENT}/exp1-threshold"
MOUNT_OPTS="--cache-size 0 --max-uploads 150"
MOUNT_BIN="/usr/local/bin/juicefs"

cd /home/turboai/production
source tests/lib/ceph-health-check.sh

# ============================================================
# Backend 工具
# ============================================================
snapshot_backend(){
  local tag="$1" outdir="$2"
  local f="${outdir}/backend-${tag}"
  { echo "### date: $(date)"; echo "== ceph health detail =="; sudo ceph health detail 2>&1
    echo "== ceph -s =="; sudo ceph -s 2>&1; echo "== ceph osd perf =="; sudo ceph osd perf 2>&1
    echo "== ceph df detail =="; sudo ceph df detail 2>&1; echo "== ceph osd df =="; sudo ceph osd df 2>&1
  } > "${f}.txt" 2>&1
  echo "  backend snapshot: ${tag}"
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
  local osds; osds=$(sudo ceph health detail 2>&1 | grep -oP 'osd\.\d+' | sort -u | tr '\n' ' ')
  for o in $osds; do
    local num=${o#osd.} host pw
    case $num in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; *) continue ;; esac
    echo "  restarting $o"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@${host}" "sudo cephadm shell -- ceph orch daemon restart $o" 2>/dev/null || true
    sleep 15
  done
}

wait_for_clean(){
  local logf="$1" elapsed=0 maxw=600
  echo "## wait_for_clean start: $(date)" >> "$logf"
  while [ $elapsed -lt $maxw ]; do
    sleep 10; elapsed=$((elapsed+10))
    local h; h=$(sudo ceph health 2>&1 | head -1)
    echo "  [${elapsed}s] ${h}" >> "$logf"
    if [ "$h" = "HEALTH_OK" ]; then
      echo "## OK after ${elapsed}s ($(date))" >> "$logf"
      return 0
    fi
  done
  # timeout → restart
  echo "## timeout ${maxw}s, restarting ($(date))" >> "$logf"
  restart_stalled_osds
  sleep 30
  elapsed=0
  while [ $elapsed -lt 300 ]; do
    sleep 10; elapsed=$((elapsed+10))
    local h; h=$(sudo ceph health 2>&1 | head -1)
    echo "  [restart+${elapsed}s] ${h}" >> "$logf"
    if [ "$h" = "HEALTH_OK" ]; then
      echo "## OK after restart+${elapsed}s ($(date))" >> "$logf"
      return 0
    fi
  done
  echo "## FATAL: still not OK ($(date))" >> "$logf"
  exit 1
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

# ============================================================
# perf_timeline + iostat 后台收集
# ============================================================
start_perf_timeline(){
  local outdir="$1" interval="${2:-15}"
  local fh="${outdir}/health-timeline.txt"
  echo "### health timeline start ($(date))" > "$fh"
  for o in 0 1 2 3 4 5; do echo "### osd.${o} perf start ($(date))" > "${outdir}/osd${o}-perf-timeline.txt"; done
  {
    while pgrep -x fio >/dev/null 2>&1; do
      local ts; ts=$(date +%H:%M:%S)
      echo "--- ${ts} ---" >> "$fh"
      sudo ceph health detail 2>&1 >> "$fh"
      for o in 0 1 2 3 4 5; do
        local host pw
        case $o in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; esac
        local dump; dump=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          "turboai@${host}" "sudo cephadm shell -- ceph daemon osd.${o} perf dump 2>/dev/null" 2>/dev/null) || true
        if [ -n "$dump" ]; then
          { echo "--- ${ts} ---"
            echo "$dump" | grep -E '"op_w"|"op_w_latency"|"commit_lat"|"apply_lat"|"kv_sync_lat"|"kv_commit_lat"|"subop_w_latency"|"compact"|"compact_queue"|"db_used_bytes"|"log_bytes"|"files_written"|"bytes_written"|"read_random"|"state_kv_queued"|"throttle"|"slow_op"'
          } >> "${outdir}/osd${o}-perf-timeline.txt"
        fi
      done
      sleep "$interval"
    done
    echo "--- $(date) ---" >> "$fh"; sudo ceph health detail 2>&1 >> "$fh"
    echo "### health timeline end ($(date))" >> "$fh"
  } &
  PERF_TIMELINE_PID=$!
}

stop_perf_timeline(){
  kill $PERF_TIMELINE_PID 2>/dev/null || true
  wait $PERF_TIMELINE_PID 2>/dev/null || true
  echo "  perf_timeline stopped"
}

start_iostat(){
  local outdir="$1"
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip \
      "iostat -x 1 > /tmp/iostat-\$(hostname).log 2>&1 &" 2>/dev/null &
  done
  echo "  iostat started on 3 nodes"
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
  echo "  iostat stopped and collected"
}

# ============================================================
# 挂载
# ============================================================
do_mount(){
  juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
  sleep 3
  juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
  sleep 3
  mountpoint -q "$MNT" || { echo "FATAL: mount failed"; exit 1; }
  echo "  mount OK"
}

# ============================================================
# S1-S4: 单job 阶梯顺序写
# ============================================================
run_single_seq(){
  local label="$1" size_g="$2" outdir="$3"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local of="${outdir}/fio-${label}.txt"
  echo "# ${label}: single-job seqwrite bs=256K size=${size_g}G end_fsync=1" > "$of"
  echo "# date: $(date)" >> "$of"
  local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  fio --name="${label}" --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --bs=256K --size="${size_g}G" --end_fsync=1 >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX_MB=${rxmb} NIC_TX_MB=${txmb}" >> "$of"
  echo "  ${label}: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${outdir}/run.log"
  wait_fio
}

# ============================================================
# S5: 复现 layout 写法 (128job×1G)
# ============================================================
run_layout_style(){
  local outdir="$1"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local of="${outdir}/fio-S5-layout.txt"
  echo "# S5: layout-style 128jobs×1G bs=4M end_fsync=1" > "$of"
  echo "# date: $(date)" >> "$of"
  local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  fio --name=layout --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --filesize=1G --size=1G --bs=4M --numjobs=128 --group_reporting --end_fsync=1 >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX_MB=${rxmb} NIC_TX_MB=${txmb}" >> "$of"
  echo "  S5-layout: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${outdir}/run.log"
  wait_fio
}

# ============================================================
# Main
# ============================================================
main(){
  echo "============================================================"
  echo "Experiment 1: staircase write + layout paradox"
  echo "Start: $(date)" | tee "${OUTBASE}/run.log"
  echo "============================================================"

  DO_MOUNT=1
  for step in S1-8G S2-32G S3-64G S4-128G S5-128G-layout; do
    OUTDIR="${OUTBASE}/${step}"
    mkdir -p "$OUTDIR"
    local logf="${OUTDIR}/run.log"

    echo "" | tee -a "${OUTBASE}/run.log"
    echo "========================================" | tee -a "${OUTBASE}/run.log"
    echo "Step ${step} ($(date))" | tee -a "${OUTBASE}/run.log"

    # wait clean + restart
    wait_for_clean "${OUTDIR}/cooldown-into.log"

    # mount (first time only)
    if [ "$DO_MOUNT" -eq 1 ]; then
      MOUNT_OPTS="--cache-size 0 --max-uploads 150"
      do_mount
      DO_MOUNT=0
    fi

    snapshot_backend "before" "$OUTDIR"
    drop_all_caches 2>&1 | tee -a "$logf"
    check_ceph_health "before ${step}"
    sleep 3

    # 启动后台监控
    start_perf_timeline "$OUTDIR" 15
    start_iostat "$OUTDIR"

    # 跑测试
    case "$step" in
      S1-8G)           run_single_seq "S1-8G" 8 "$OUTDIR" ;;
      S2-32G)          run_single_seq "S2-32G" 32 "$OUTDIR" ;;
      S3-64G)          run_single_seq "S3-64G" 64 "$OUTDIR" ;;
      S4-128G)         run_single_seq "S4-128G" 128 "$OUTDIR" ;;
      S5-128G-layout)  run_layout_style "$OUTDIR" ;;
    esac

    # 停后台监控
    stop_perf_timeline
    stop_iostat "$OUTDIR"

    snapshot_backend "after" "$OUTDIR"
    echo "  ${step} DONE ($(date))" | tee -a "${OUTBASE}/run.log"
  done

  echo ""; echo "ALL DONE: $(date)" | tee -a "${OUTBASE}/run.log"
}

main
