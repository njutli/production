#!/bin/bash
# ============================================================
# Write push test: mu/buffer 扫描 (multi-seqwrite skipped due to BlueFS stall)
# patched v1.3.1 + 冷态(cache=0) + 默认 ra
# 只测 seqwrite + randwrite
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
PARENT="/home/turboai/production/results/write-push-20260704"
MOUNT_BIN="/usr/local/bin/juicefs"

cd /home/turboai/production
source tests/lib/ceph-health-check.sh

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

restart_osds_if_needed(){
  local health
  health=$(sudo ceph health 2>&1 | head -1)
  if [ "$health" = "HEALTH_OK" ]; then
    echo "  [health] OK"
    return 0
  fi
  echo "  [recovery] Health non-OK: $health"
  for osd in 0 1 2 3 4 5; do
    if sudo ceph health detail 2>&1 | grep -q "osd.${osd}"; then
      local host pw
      case $osd in 0|1) host="192.168.11.11"; pw="TurboAi@303" ;; 2|3) host="192.168.11.13"; pw="TurboAi@303" ;; 4|5) host="192.168.11.14"; pw="TurboAi@303" ;; esac
      sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "turboai@${host}" "sudo cephadm shell -- ceph orch daemon restart osd.${osd}" 2>/dev/null || true
    fi
  done
  echo "  [recovery] waiting for HEALTH_OK..."
  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    sleep 15; elapsed=$((elapsed + 15))
    health=$(sudo ceph health 2>&1 | head -1)
    [ "$health" = "HEALTH_OK" ] && { echo "  [recovery] OK after ${elapsed}s"; return 0; }
  done
  echo "  [recovery] FATAL: still non-OK after 300s"; exit 1
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

do_mount(){
  local grid="$1" mount_opts="$2"
  echo "## Mount: ${mount_opts}" | tee -a "${OUTDIR}/run.log"
  juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
  sleep 3
  juicefs mount -d ${mount_opts} "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
  sleep 3
  mountpoint -q "$MNT" || { echo "FATAL: mount failed for ${grid}"; exit 1; }
  echo "  mount OK: ${grid}" | tee -a "${OUTDIR}/run.log"
}

run_seqwrite(){
  local round="$1" out="$2" logf="$3"
  local of="${out}/seqwrite-r${round}.txt"
  echo "# seqwrite round ${round}: rw=write bs=256K size=4G numjobs=1 end_fsync=1" > "$of"
  echo "# date: $(date)" >> "$of"
  rm -rf "$SEQ_DIR"/* 2>/dev/null
  local rx0; rx0=$(rxget)
  fio --name=seqwrite --directory="$SEQ_DIR" --rw=write --refill_buffers \
      --bs=256K --size=4G --end_fsync=1 >> "$of" 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "  seqwrite r${round}: WRITE=${bw} MiB/s NIC_RX=${rxmb} MB" | tee -a "$logf"
  wait_fio
}

run_randwrite(){
  local round="$1" out="$2" logf="$3"
  local of="${out}/randwrite-r${round}.txt"
  echo "# randwrite round ${round}: rw=randwrite bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# date: $(date)" >> "$of"
  local rx0; rx0=$(rxget)
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local bw; bw=$(bwget "$of" WRITE)
  echo "  randwrite r${round}: WRITE=${bw} MiB/s NIC_RX=${rxmb} MB" | tee -a "$logf"
  wait_fio
}

run_grid(){
  local grid="$1" mount_opts="$2"
  OUTDIR="${PARENT}/${grid}"
  mkdir -p "$OUTDIR"
  local logf="${OUTDIR}/run.log"

  echo "============================================================" | tee "$logf"
  echo "Grid ${grid}: ${mount_opts}" | tee -a "$logf"
  echo "Start: $(date)" | tee -a "$logf"
  echo "============================================================" | tee -a "$logf"

  {
    echo "### date: $(date)"
    echo "### juicefs version: $($MOUNT_BIN version 2>&1)"
    echo "### ceph health: $(sudo ceph health 2>&1 | head -1)"
    echo "### mount opts: ${mount_opts}"
  } > "${OUTDIR}/env-snapshot.txt"

  do_mount "$grid" "$mount_opts"

  local -a sw_bw rw_bw sw_stall rw_stall
  for r in 1 2 3; do
    echo "" | tee -a "$logf"
    echo "## Round ${r} ($(date))" | tee -a "$logf"
    drop_all_caches 2>&1 | tee -a "$logf"
    sleep 3

    restart_osds_if_needed
    run_seqwrite "$r" "$OUTDIR" "$logf"
    sw_bw[$r]=$(bwget "${OUTDIR}/seqwrite-r${r}.txt" WRITE)
    sw_stall[$r]=$(sudo ceph health 2>&1 | head -1 | grep -qv HEALTH_OK && echo "stall" || echo "ok")
    echo "  [health] seqwrite r${r}: ${sw_stall[$r]}" | tee -a "$logf"

    restart_osds_if_needed
    run_randwrite "$r" "$OUTDIR" "$logf"
    rw_bw[$r]=$(bwget "${OUTDIR}/randwrite-r${r}.txt" WRITE)
    rw_stall[$r]=$(sudo ceph health 2>&1 | head -1 | grep -qv HEALTH_OK && echo "stall" || echo "ok")
    echo "  [health] randwrite r${r}: ${rw_stall[$r]}" | tee -a "$logf"
  done

  restart_osds_if_needed

  cat > "${OUTDIR}/summary.md" << SUMEOF
# ${grid} Summary

| 测试 | r1 MiB/s | r2 MiB/s | r3 MiB/s | stall | 判定(取r1) |
|------|----------|----------|----------|-------|-----------|
| seqwrite | ${sw_bw[1]} | ${sw_bw[2]} | ${sw_bw[3]} | ${sw_stall[1]}/${sw_stall[2]}/${sw_stall[3]} | $( [ "$(echo "${sw_bw[1]} >= 59" | bc -l 2>/dev/null)" = "1" ] && echo "达标" || echo "未达标") |
| randwrite | ${rw_bw[1]} | ${rw_bw[2]} | ${rw_bw[3]} | ${rw_stall[1]}/${rw_stall[2]}/${rw_stall[3]} | $( [ "$(echo "${rw_bw[1]} >= 59" | bc -l 2>/dev/null)" = "1" ] && echo "达标" || echo "未达标") |

挂载参数: \`${mount_opts}\`
SUMEOF

  cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# Grid: ${grid}
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)
juicefs umount ${MNT} 2>/dev/null || true
sleep 3
juicefs mount -d ${mount_opts} ${META} ${MNT}

# seqwrite
fio --name=seqwrite --directory=${SEQ_DIR} --rw=write --refill_buffers --bs=256K --size=4G --end_fsync=1
# randwrite
fio --directory=${DIR} --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
CMDEOF
  chmod +x "${OUTDIR}/commands.sh"

  echo "" | tee -a "$logf"
  echo "Grid ${grid} DONE: $(date)" | tee -a "$logf"
}

# ============================================================
# A3: mu=300
# ============================================================
run_grid "mu300" "--cache-size 0 --max-uploads 300"

# ============================================================
# B1: mu* + buffer=300M (reuses A best)
# B2: mu* + buffer=1024M
# ============================================================
run_grid "mu300-buf1g" "--cache-size 0 --max-uploads 300 --buffer-size 1024"

echo "ALL_DONE $(date)"
