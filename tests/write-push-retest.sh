#!/bin/bash
# ============================================================
# Write Push Retest 20260705
# 实验 A: contamination 假说验证
# 实验 B: 并发扫描 + 固定总量对照
# 实验 C: BlueFS stall 取证
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
PARENT="/home/turboai/production/results/write-push-retest-20260705"
MOUNT_OPTS="--cache-size 0 --max-uploads 150"
MOUNT_BIN="/usr/local/bin/juicefs"

cd /home/turboai/production
source tests/lib/ceph-health-check.sh

# ============================================================
# 工具函数
# ============================================================

drop_all_caches(){
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || echo "  client drop FAILED"
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"
    [ "$ip" = "192.168.11.13" ] && pw="TurboAi@303"
    [ "$ip" = "192.168.11.14" ] && pw="TurboAi@303"
    if sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "turboai@$ip" "echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null" 2>/dev/null; then
      echo "  $ip cache dropped"
    else
      echo "  $ip drop FAILED"
    fi
  done
}

wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){
  local val unit
  val=$(grep -oP "$2: bw=\K[0-9.]+" "$1" | head -1)
  unit=$(grep -oP "$2: bw=[0-9.]+\K[a-zA-Z]+/s" "$1" | head -1)
  if [ -z "$val" ]; then echo "0"; return; fi
  if [ "$unit" = "KiB/s" ]; then awk "BEGIN{printf \"%.1f\", $val/1024}"; else echo "$val"; fi
}
rxget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }
txget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $10}'; }

# ============================================================
# Backend 状态快照 (§1)
# ============================================================
snapshot_backend(){
  local tag="$1" outdir="$2"
  local f="${outdir}/backend-${tag}"
  {
    echo "### date: $(date)"
    echo "== ceph health detail =="
    sudo ceph health detail 2>&1
    echo "== ceph -s =="
    sudo ceph -s 2>&1
    echo "== ceph osd perf =="
    sudo ceph osd perf 2>&1
    echo "== ceph df detail =="
    sudo ceph df detail 2>&1
    echo "== ceph osd df =="
    sudo ceph osd df 2>&1
  } > "${f}.txt" 2>&1

  # OSD 节点系统状态
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"
    [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 turboai@$ip \
      'echo "== uptime =="; uptime; echo "== iostat 1 3 =="; iostat -x 1 3 2>/dev/null; echo "== loadavg =="; cat /proc/loadavg' \
      > "${outdir}/sys-${tag}-${ip}.txt" 2>&1 || echo "  sys snapshot $ip FAILED"
  done
  echo "  backend snapshot: ${tag} ($(date))"
}

# ============================================================
# Cooldown 等待 + 日志 (§2)
# ============================================================
backend_is_clean(){
  local h; h=$(sudo ceph health detail 2>&1)
  if echo "$h" | grep -q "HEALTH_OK"; then
    if ! echo "$h" | grep -q "slow_op\|stalled.read\|DB_DEVICE"; then
      return 0
    fi
  fi
  return 1
}

restart_stalled_osds(){
  local osds
  osds=$(sudo ceph health detail 2>&1 | grep -oP 'osd\.\d+' | sort -u | tr '\n' ' ')
  for o in $osds; do
    local num=${o#osd.}
    local host pw
    case $num in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; *) continue ;; esac
    echo "  restarting $o on $host"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@${host}" "sudo cephadm shell -- ceph orch daemon restart $o" 2>/dev/null || true
    sleep 15
  done
}

cooldown_and_wait(){
  local outdir="$1" label="$2"
  local logf="${outdir}/cooldown-wait.log"
  echo "### cooldown start: ${label} ($(date))" >> "$logf"

  # 快速检查
  sleep 10
  if backend_is_clean; then
    echo "  backend clean immediately ($(date))" | tee -a "$logf"
    echo "### cooldown end: clean ($(date))" >> "$logf"
    return 0
  fi

  # 轮询等待
  local elapsed=0 max_wait=300
  while [ $elapsed -lt $max_wait ]; do
    sleep 15; elapsed=$((elapsed + 15))
    local h; h=$(sudo ceph health 2>&1 | head -1)
    echo "  [${elapsed}s] ${h} ($(date))" | tee -a "$logf"
    if backend_is_clean; then
      echo "  backend clean after ${elapsed}s ($(date))" | tee -a "$logf"
      echo "### cooldown end: clean after ${elapsed}s ($(date))" >> "$logf"
      return 0
    fi
  done

  # 超时 → restart OSD
  echo "  cooldown timeout ${max_wait}s, restarting stalled OSDs ($(date))" | tee -a "$logf"
  restart_stalled_osds
  elapsed=0 max_wait=300
  while [ $elapsed -lt $max_wait ]; do
    sleep 15; elapsed=$((elapsed + 15))
    local h; h=$(sudo ceph health 2>&1 | head -1)
    echo "  [restart+${elapsed}s] ${h} ($(date))" | tee -a "$logf"
    if backend_is_clean; then
      echo "  backend clean after restart+${elapsed}s ($(date))" | tee -a "$logf"
      echo "### cooldown end: clean after restart ($(date))" >> "$logf"
      return 0
    fi
  done

  echo "  FATAL: backend still not clean after restart+${max_wait}s ($(date))" | tee -a "$logf"
  exit 1
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
# Fio 执行器
# ============================================================
run_seqwrite(){
  local round="$1" out="$2"
  local of="${out}/seqwrite-r${round}.txt"
  echo "# seqwrite r${round}: rw=write bs=256K size=4G numjobs=1 end_fsync=1" > "$of"
  echo "# date: $(date)" >> "$of"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --bs=256K --size=4G --end_fsync=1 >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX_MB=${rxmb} NIC_TX_MB=${txmb}" >> "$of"
  echo "  seqwrite r${round}: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${out}/run.log"
  wait_fio
}

run_randwrite(){
  local round="$1" out="$2"
  local of="${out}/randwrite-r${round}.txt"
  echo "# randwrite r${round}: rw=randwrite bs=256k iod=128 nj=128 direct=1 runtime=60s" > "$of"
  echo "# date: $(date)" >> "$of"
  local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX_MB=${rxmb} NIC_TX_MB=${txmb}" >> "$of"
  echo "  randwrite r${round}: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${out}/run.log"
  wait_fio
}

run_multiseq(){
  local round="$1" out="$2" nj="$3" size="$4"
  local label="nj${nj}s${size}G"
  local of="${out}/multi-r${round}.txt"
  echo "# multi-seqwrite r${round}: nj=${nj} size=${size}G bs=256K end_fsync=1 group_reporting" > "$of"
  echo "# date: $(date)" >> "$of"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local rx0 tx0; rx0=$(rxget); tx0=$(txget)
  fio --name=multi --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --bs=256K --size="${size}G" --numjobs="${nj}" --group_reporting --end_fsync=1 >> "$of" 2>&1
  local rx1 tx1; rx1=$(rxget); tx1=$(txget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local txmb; txmb=$(awk "BEGIN{printf \"%.1f\",($tx1-$tx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "# NIC_RX_MB=${rxmb} NIC_TX_MB=${txmb}" >> "$of"
  echo "  multi r${round}: WRITE=${bw} MiB/s RX=${rxmb}MB TX=${txmb}MB" | tee -a "${out}/run.log"
  wait_fio
}

# ============================================================
# Experiment C: stall 后台收集器
# ============================================================
start_health_poll(){
  local outdir="$1"
  local f="${outdir}/health-timeline.txt"
  echo "### health poll start ($(date))" > "$f"
  while pgrep -x fio >/dev/null 2>&1; do
    echo "--- $(date) ---" >> "$f"
    sudo ceph health detail 2>&1 >> "$f"
    sleep 5
  done
  echo "--- $(date) ---" >> "$f"
  sudo ceph health detail 2>&1 >> "$f"
  echo "### health poll end ($(date))" >> "$f"
}

start_osd_perf_poll(){
  local outdir="$1"
  local f_prefix="${outdir}/osd-perf-timeline"
  for o in 0 1 2 3 4 5; do
    echo "### osd.${o} perf timeline start ($(date))" > "${f_prefix}-osd${o}.txt"
  done
  while pgrep -x fio >/dev/null 2>&1; do
    local ts; ts=$(date +%H:%M:%S)
    for o in 0 1 2 3 4 5; do
      local host pw
      case $o in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; esac
      local dump
      dump=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "turboai@${host}" "sudo cephadm shell -- ceph daemon osd.${o} perf dump 2>/dev/null" 2>/dev/null) || true
      if [ -n "$dump" ]; then
        {
          echo "--- ${ts} ---"
          echo "$dump" | grep -E '"op_w"|"op_w_latency"|"op_w_in_bytes"|"commit_lat"|"apply_lat"|"kv_sync_lat"|"kv_commit_lat"|"subop_w_latency"|"compact"|"compact_queue"|"db_used_bytes"|"log_bytes"|"files_written"|"bytes_written"|"read_random"|"state_kv_queued"|"throttle"|"slow_op"'
        } >> "${f_prefix}-osd${o}.txt"
      fi
    done
    sleep 10
  done
  echo "### osd perf timeline end ($(date))" >> "${f_prefix}-osd0.txt"
}

collect_disk_layout(){
  local outdir="$1"
  local f="${outdir}/osd-layout.txt"
  echo "### Disk layout evidence ($(date))" > "$f"
  for o in 0 1 2 3 4 5; do
    echo "=== osd.${o} metadata ===" >> "$f"
    local host pw
    case $o in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; esac
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@${host}" "sudo cephadm shell -- ceph osd metadata osd.${o} 2>/dev/null | grep -E 'bluefs|bluestore|hostname|devices'" 2>/dev/null >> "$f" || true
    echo "" >> "$f"
  done
  # lsblk from each node
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    echo "=== ${ip} lsblk ===" >> "$f"
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "turboai@${ip}" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,ROTA 2>/dev/null" 2>/dev/null >> "$f" || true
  done
}

# ============================================================
# Grid: A 组 (seqwrite + randwrite, 5轮)
# ============================================================
run_grid_A(){
  local exp="$1" grid="$2" mount_opts="$3" prewrite="$4"
  OUTDIR="${PARENT}/${exp}/${grid}"
  mkdir -p "$OUTDIR"
  echo "============================================================" | tee "${OUTDIR}/run.log"
  echo "Grid ${grid}: ${mount_opts}" | tee -a "${OUTDIR}/run.log"
  echo "Start: $(date)" | tee -a "${OUTDIR}/run.log"

  # mount
  MOUNT_OPTS="$mount_opts"
  do_mount

  # 制造污染 (仅 A-postlayout)
  if [ "$prewrite" = "yes" ]; then
    echo "## Pre-write 64G to create contamination ($(date))" | tee -a "${OUTDIR}/run.log"
    rm -rf "$SEQ_DIR"/* 2>/dev/null
    fio --name=pollute --directory="$SEQ_DIR" --rw=write --refill_buffers \
        --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1 \
        > "${OUTDIR}/prewrite.txt" 2>&1
    wait_fio
    echo "  prewrite DONE ($(date))" | tee -a "${OUTDIR}/run.log"
  fi

  snapshot_backend "before" "$OUTDIR"

  local -a sw_bw rw_bw
  for r in 1 2 3 4 5; do
    echo "" | tee -a "${OUTDIR}/run.log"
    echo "## Round ${r} ($(date))" | tee -a "${OUTDIR}/run.log"
    drop_all_caches 2>&1 | tee -a "${OUTDIR}/run.log"
    check_ceph_health "before ${grid} r${r}"
    sleep 3

    run_seqwrite "$r" "$OUTDIR"
    run_randwrite "$r" "$OUTDIR"
    sw_bw[$r]=$(bwget "${OUTDIR}/seqwrite-r${r}.txt" WRITE)
    rw_bw[$r]=$(bwget "${OUTDIR}/randwrite-r${r}.txt" WRITE)
  done

  snapshot_backend "after" "$OUTDIR"

  # summary
  cat > "${OUTDIR}/summary.md" << SUMEOF
# ${grid} Summary

| 轮次 | seqwrite | randwrite |
|------|----------|----------|
| r1 | ${sw_bw[1]} | ${rw_bw[1]} |
| r2 | ${sw_bw[2]} | ${rw_bw[2]} |
| r3 | ${sw_bw[3]} | ${rw_bw[3]} |
| r4 | ${sw_bw[4]} | ${rw_bw[4]} |
| r5 | ${sw_bw[5]} | ${rw_bw[5]} |

r1: seqwrite=${sw_bw[1]} randwrite=${rw_bw[1]}
挂载: \`${mount_opts}\` | prewrite: ${prewrite}
SUMEOF

  echo "Grid ${grid} DONE: $(date)" | tee -a "${OUTDIR}/run.log"
}

# ============================================================
# Grid: B 组 (multi-seqwrite, 5轮)
# ============================================================
run_grid_B(){
  local exp="$1" grid="$2" nj="$3" size="$4" collect_c="$5"
  OUTDIR="${PARENT}/${exp}/${grid}"
  mkdir -p "$OUTDIR"
  echo "============================================================" | tee "${OUTDIR}/run.log"
  echo "Grid ${grid}: nj=${nj} size=${size}G total=$((nj * size))G ${MOUNT_OPTS}" | tee -a "${OUTDIR}/run.log"
  echo "Start: $(date)" | tee -a "${OUTDIR}/run.log"

  do_mount
  snapshot_backend "before" "$OUTDIR"

  # Experiment C: disk layout (once)
  if [ "$collect_c" = "yes" ] && [ "$grid" = "B1-nj16" ]; then
    collect_disk_layout "${PARENT}/expC-stall-forensics"
  fi

  local -a bw
  for r in 1 2 3 4 5; do
    echo "" | tee -a "${OUTDIR}/run.log"
    echo "## Round ${r} ($(date))" | tee -a "${OUTDIR}/run.log"
    drop_all_caches 2>&1 | tee -a "${OUTDIR}/run.log"
    check_ceph_health "before ${grid} r${r}"
    sleep 3

    # Experiment C: 后台监控 (B1-nj16)
    if [ "$collect_c" = "yes" ] && [ "$grid" = "B1-nj16" ] && [ "$r" -eq 1 ]; then
      start_health_poll "${PARENT}/expC-stall-forensics" &
      HEALTH_POLL_PID=$!
      start_osd_perf_poll "${PARENT}/expC-stall-forensics" &
      OSDPERF_POLL_PID=$!
      echo "  [expC] health poll PID=${HEALTH_POLL_PID} osd perf poll PID=${OSDPERF_POLL_PID}" | tee -a "${OUTDIR}/run.log"
    fi

    run_multiseq "$r" "$OUTDIR" "$nj" "$size"
    bw[$r]=$(bwget "${OUTDIR}/multi-r${r}.txt" WRITE)
  done

  # 停后台监控
  if [ "$collect_c" = "yes" ] && [ "$grid" = "B1-nj16" ]; then
    kill $HEALTH_POLL_PID $OSDPERF_POLL_PID 2>/dev/null || true
    wait $HEALTH_POLL_PID $OSDPERF_POLL_PID 2>/dev/null || true
    echo "  [expC] monitors stopped" | tee -a "${OUTDIR}/run.log"
  fi

  snapshot_backend "after" "$OUTDIR"

  cat > "${OUTDIR}/summary.md" << SUMEOF
# ${grid} Summary

| 轮次 | WRITE MiB/s |
|------|------------|
| r1 | ${bw[1]} |
| r2 | ${bw[2]} |
| r3 | ${bw[3]} |
| r4 | ${bw[4]} |
| r5 | ${bw[5]} |

nj=${nj} per-job=${size}G total=$((nj * size))G
挂载: \`${MOUNT_OPTS}\`
SUMEOF

  echo "Grid ${grid} DONE: $(date)" | tee -a "${OUTDIR}/run.log"
}

# ============================================================
# Main
# ============================================================
main(){
  echo "============================================================"
  echo "Write Push Retest 20260705"
  echo "Start: $(date)"
  echo "============================================================"

  # env snapshot
  {
    echo "### juicefs version: $($MOUNT_BIN version 2>&1)"
    echo "### ceph health: $(sudo ceph health 2>&1 | head -1)"
    echo "### mount opts: ${MOUNT_OPTS}"
  } > "${PARENT}/env-snapshot.txt"

  # ---- 实验 A ----
  # A-idle: 完全空闲
  echo ""; echo "=== Experiment A-idle ==="; date
  run_grid_A "expA-contamination" "A-idle" "${MOUNT_OPTS}" "no"
  cooldown_and_wait "${PARENT}/expA-contamination/A-idle" "A-idle->B1-nj1"

  # ---- 实验 B1 (固定总量) ----
  # B1-nj1: 1job×64G (对照C)
  echo ""; echo "=== Experiment B1-nj1 ==="; date
  run_grid_B "expB-concurrency" "B1-nj1" 1 64 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B1-nj1" "B1-nj1->B1-nj2"

  # B1-nj2
  echo ""; echo "=== Experiment B1-nj2 ==="; date
  run_grid_B "expB-concurrency" "B1-nj2" 2 32 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B1-nj2" "B1-nj2->B1-nj4"

  # B1-nj4
  echo ""; echo "=== Experiment B1-nj4 ==="; date
  run_grid_B "expB-concurrency" "B1-nj4" 4 16 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B1-nj4" "B1-nj4->B1-nj8"

  # B1-nj8
  echo ""; echo "=== Experiment B1-nj8 ==="; date
  run_grid_B "expB-concurrency" "B1-nj8" 8 8 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B1-nj8" "B1-nj8->B1-nj16"

  # B1-nj16 (触发 C)
  echo ""; echo "=== Experiment B1-nj16 + stall forensics ==="; date
  run_grid_B "expB-concurrency" "B1-nj16" 16 4 "yes"
  cooldown_and_wait "${PARENT}/expB-concurrency/B1-nj16" "B1-nj16->B2-nj16"

  # ---- 实验 B2 (对照, 固定 per-job=4G) ----
  echo ""; echo "=== Experiment B2-nj16 ==="; date
  run_grid_B "expB-concurrency" "B2-nj16" 16 4 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B2-nj16" "B2-nj16->B2-nj4"

  echo ""; echo "=== Experiment B2-nj4 ==="; date
  run_grid_B "expB-concurrency" "B2-nj4" 4 4 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B2-nj4" "B2-nj4->B2-nj1"

  echo ""; echo "=== Experiment B2-nj1 ==="; date
  run_grid_B "expB-concurrency" "B2-nj1" 1 4 "no"
  cooldown_and_wait "${PARENT}/expB-concurrency/B2-nj1" "B2-nj1->A-postlayout"

  # ---- 实验 A-postlayout (污染后) ----
  echo ""; echo "=== Experiment A-postlayout ==="; date
  run_grid_A "expA-contamination" "A-postlayout" "${MOUNT_OPTS}" "yes"
  cooldown_and_wait "${PARENT}/expA-contamination/A-postlayout" "A-postlayout->A-repeat"

  # ---- 实验 A-repeat (时间方差) ----
  echo ""; echo "=== Experiment A-repeat ==="; date
  run_grid_A "expA-contamination" "A-repeat" "${MOUNT_OPTS}" "no"

  echo ""; echo "ALL DONE: $(date)"
}

main
