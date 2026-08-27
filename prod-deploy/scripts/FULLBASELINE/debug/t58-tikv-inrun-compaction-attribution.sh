#!/usr/bin/env bash
# T58: TiKV in-run compaction/write path attribution (03-20A)
# Single B256 arm, 180s, diagnostic metrics, no config change
set -euo pipefail

# ===== Config =====
RUN_ID="${1:-$(date +%Y%m%d-%H%M%S)}"
BIN=/tmp/juicefs-03-8
BIN_MD5=de93563f11a5ff3bd94dd25a4e0283b1
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'
MNT=/mnt/juicefs
TEST_DIR=/mnt/juicefs/test_dir
MOUNT_OPTS='--max-uploads 150 --cache-size 0 --max-fuse-io 256K'
SYS_CONF=/etc/ceph/ceph.conf
SYS_CONF_MD5=5b6be34179a64e0a5f9c6d3a9690041f
PRIVATE_CONF="/tmp/t58-msgr8-${RUN_ID}.conf"
TIKV_IPS=(10.20.1.150 10.20.1.151 10.20.1.152)
TIKV_EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
SSH=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
OBJ_SOFT=2500000
OBJ_HARD=8000000
OUT="/tmp/opencode-t3.20a-${RUN_ID}"
ARCHIVE_DIR=/tmp/production
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATS_FILE=""  # will be set after mount

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*" | tee -a "$OUT/wrapper.log"; }

mkdir -p "$OUT" "$OUT/samplers" "$OUT/reset" "$OUT/arm/bw" "$OUT/files" "$OUT/fingerprint" "$OUT/jobfiles" "$OUT/metrics-full"

# ===== Helper: JSON pool query =====
pool_json() {
  sudo ceph df --format=json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
for p in d.get("pools",[]):
    if "juicefs-data" in p.get("name",""):
        s=p.get("stats",{})
        print(s.get("objects",0), s.get("bytes_used",0), s.get("max_avail",0))
        break
' 2>/dev/null || echo "ERR ERR ERR"
}

# ===== Helper: OSD perf dump cooldown =====
osd_cooldown_ok() {
  # compact_running/compact_queue_len not available in this Ceph version
  # Only check kv_sync_lat (always fast after compact completes)
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    local dump
    dump=$(sudo ceph tell "osd.$osd" perf dump 2>/dev/null || echo "")
    [[ -n "$dump" ]] || return 1
    local ksl
    ksl=$(echo "$dump" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("bluestore",{}).get("kv_sync_lat",{}).get("avgtime",999))' 2>/dev/null || echo 999)
    echo "$ksl" | awk '{exit ($1 < 0.002) ? 0 : 1}' || return 1
  done
  return 0
}

compact_osd() {
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    sudo ceph tell "osd.$osd" compact 2>/dev/null || true
  done
  sleep 30
  osd_cooldown_ok || return 1
  return 0
}

# ===== Helper: TiKV pending compaction =====
tikv_pending_ok() {
  for ip in "${TIKV_IPS[@]}"; do
    local val
    val=$(curl -s --connect-timeout 5 "http://${ip}:20180/metrics" 2>/dev/null | grep '^tikv_engine_pending_compaction_bytes' | grep -v '^#' | awk '{print $2}' | head -1)
    [[ -n "$val" && "$val" == "0" ]] || return 1
  done
  return 0
}

# ===== Helper: stat all files =====
stat_all_files() {
  {
    for stem in storage_test read_test rw_test; do
      for f in "$TEST_DIR/${stem}."*.0; do
        [[ -f "$f" ]] || continue
        inode=$(stat -c %i "$f")
        sz=$(stat -c %s "$f")
        mtime=$(stat -c %Y "$f")
        echo -e "$f\t$inode\t$sz\t$mtime"
      done
    done
  } | sort
}

# ===== Helper: drop caches =====
drop_caches_4node() {
  local ok=0
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 && ok=$((ok+1))
  for ip in "${TIKV_IPS[@]}"; do
    if "${SSH[@]}" "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
      ok=$((ok+1))
    else
      sleep 2
      "${SSH[@]}" "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null && ok=$((ok+1)) || ok=$ok
    fi
  done
  [[ $ok -eq 4 ]]
}

# ===== Helper: idle gate =====
idle_gate() {
  local tries=0
  while [[ $tries -lt 30 ]]; do
    # No foreign processes
    local foreign
    foreign=$(pgrep -af 'FULLBASELINE|fio.*storage_test|juicefs gc' 2>/dev/null | grep -v -E 'pgrep|grep|t58|samplers|nice -n 19|rados|curl -s|process_cpu' | head -1)
    [[ -z "$foreign" ]] || { log "  idle: foreign=$foreign"; sleep 10; tries=$((tries+1)); continue; }
    # Health
    local health
    health=$(sudo ceph health 2>/dev/null || echo "ERR")
    [[ "$health" == "HEALTH_OK" ]] || { sleep 10; tries=$((tries+1)); continue; }
    # CPU idle (top -b -n1, handle wekanode baseline)
    local idle
    idle=$(top -b -n1 2>/dev/null | grep -oP '\d+\.\d id' | grep -oP '^\d+\.\d' || echo 0)
    [[ $(echo "$idle >= 70" | bc 2>/dev/null || echo 0) -eq 1 ]] || { sleep 10; tries=$((tries+1)); continue; }
    echo "$(date +%s) idle_gate PASS" >> "$OUT/idle-gate.log"
    return 0
  done
  echo "$(date +%s) idle_gate FAIL" >> "$OUT/idle-gate.log"
  return 1
}

# ===== Helper: reset_to_gate =====
reset_to_gate() {
  local label=$1
  local rdir="$OUT/reset/$label"
  mkdir -p "$rdir"
  log "reset_to_gate: $label"

  # 1. sync
  sync -f "$MNT" 2>/dev/null || true

  # 2. OSD compact + cooldown
  log "  step2: OSD compact + cooldown"
  compact_osd || { log "STOP: OSD cooldown failed"; return 1; }

  # 3. wait 30s + repeat
  sleep 30
  compact_osd || { log "STOP: OSD cooldown (2nd) failed"; return 1; }

  # 4. gc --compact
  log "  step4: gc --compact"
  echo "$(date +%s) gc_start" > "$rdir/gc.log"
  "$BIN" gc --compact "$META" >> "$rdir/gc.log" 2>&1
  local gc_rc=$?
  echo "$(date +%s) gc_end rc=$gc_rc" >> "$rdir/gc.log"
  [[ $gc_rc -eq 0 ]] || { log "STOP: gc rc=$gc_rc"; return 1; }

  # 5. Object convergence (JSON)
  log "  step5: object convergence"
  local tries=0
  while [[ $tries -lt 40 ]]; do
    local s1 s2 s3 o1 o2 o3
    s1=$(pool_json); sleep 15
    s2=$(pool_json); sleep 15
    s3=$(pool_json)
    echo -e "$s1\n$s2\n$s3" > "$rdir/objects-try${tries}.tsv"
    o1=$(echo "$s1" | awk '{print $1}')
    o2=$(echo "$s2" | awk '{print $1}')
    o3=$(echo "$s3" | awk '{print $1}')
    if [[ "$o1" =~ ^[0-9]+$ && "$o1" -le $OBJ_SOFT ]]; then
      local diff=$(( ${o1/#/0} > ${o2/#/0} ? ${o1/#/0} - ${o2/#/0} : ${o2/#/0} - ${o1/#/0} ))
      local diff2=$(( ${o2/#/0} > ${o3/#/0} ? ${o2/#/0} - ${o3/#/0} : ${o3/#/0} - ${o2/#/0} ))
      local maxdiff=$(( diff > diff2 ? diff : diff2 ))
      if [[ $maxdiff -le 128 ]]; then
        log "  objects converged: $o1"
        break
      fi
    fi
    tries=$((tries+1))
  done
  [[ $tries -lt 40 ]] || { log "STOP: object convergence failed"; return 1; }

  # 6. Post-GC compact
  log "  step6: post-GC compact"
  compact_osd || { log "STOP: post-GC compact failed"; return 1; }

  # 7. TiKV pending
  log "  step7: TiKV pending check"
  local tk_tries=0
  while [[ $tk_tries -lt 60 ]]; do
    tikv_pending_ok && break
    sleep 10
    tk_tries=$((tk_tries+1))
  done
  [[ $tk_tries -lt 60 ]] || { log "STOP: TiKV pending != 0"; return 1; }

  # 8. stat all files
  log "  step8: stat all files"
  stat_all_files > "$rdir/file-stats.tsv"

  # 9. drop caches
  log "  step9: drop caches"
  drop_caches_4node || { log "STOP: drop_caches failed"; return 1; }
  echo "$(date +%s) drop_caches 4/4" > "$rdir/drop-caches.txt"

  # 10. 60s quiet
  log "  step10: 60s quiet"
  sleep 60

  # 11. idle gate
  log "  step11: idle gate"
  idle_gate || { log "STOP: idle gate failed"; return 1; }

  echo -e "$(date +%s)\t$label\tready" >> "$OUT/phase.tsv"
  log "reset_to_gate: $label OK"
  return 0
}

# ===== Phase 1: Preflight =====
log "=== T58 03-20A start run_id=$RUN_ID ==="

# Private CEPH_CONF
cp "$SYS_CONF" "$PRIVATE_CONF"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
export CEPH_CONF="$PRIVATE_CONF"

# Environment
hostname > "$OUT/fingerprint/hostname.txt"
date '+%Y-%m-%d %H:%M:%S %z' > "$OUT/fingerprint/datetime.txt"
fio --version > "$OUT/fingerprint/fio-version.txt" 2>&1
df -Pk / | awk 'NR==2{print $4}' > "$OUT/fingerprint/df.txt"

# Binary
[[ "$(md5sum "$BIN" | awk '{print $1}')" == "$BIN_MD5" ]] || { log "STOP: binary md5 mismatch"; exit 5; }

# System ceph.conf
sys_md5=$(md5sum "$SYS_CONF" | awk '{print $1}')
[[ "$sys_md5" == "$SYS_CONF_MD5" ]] || { log "STOP: system conf md5 mismatch"; exit 5; }
cp "$SYS_CONF" "$OUT/fingerprint/ceph.conf.system"

# Ceph health
health=$(sudo ceph health 2>/dev/null || echo "ERR")
[[ "$health" == "HEALTH_OK" ]] || { log "STOP: ceph health=$health"; exit 5; }

# OSD count
osd_up=$(sudo ceph osd stat 2>/dev/null | grep -oP '\d+(?= up)' | head -1)
osd_up=${osd_up:-0}
[[ "$osd_up" -ge 6 ]] || { log "STOP: OSD up=$osd_up < 6"; exit 5; }

# PG
pg_stat=$(sudo ceph pg stat 2>/dev/null | head -1 || echo "NA")
log "PG: $pg_stat"

# up_from
sudo ceph osd dump 2>/dev/null | grep 'up_from' | head -1 > "$OUT/fingerprint/up_from-pre.txt" || true

# Root space
avail_k=$(df -Pk / | awk 'NR==2{print $4}')
[[ "$avail_k" -ge 5242880 ]] || { log "STOP: root < 5GiB"; exit 5; }

# Graceful unmount if needed
if mountpoint -q "$MNT"; then
  sync; umount "$MNT" 2>/dev/null || {
    local mpid=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
    if [[ -n "$mpid" ]]; then
      kill "$mpid" 2>/dev/null; sleep 5
      kill -9 "$mpid" 2>/dev/null; sleep 2
    fi
    umount "$MNT" 2>/dev/null || true
  }
  sleep 2
  mountpoint -q "$MNT" && { log "STOP: cannot clean mount"; exit 6; }
fi

# Mount
"$BIN" mount -d $MOUNT_OPTS "$META" "$MNT" >> "$OUT/mount.log" 2>&1
sleep 10
mountpoint -q "$MNT" || { log "STOP: mount failed"; exit 6; }

PID=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
[[ "$PID" =~ ^[0-9]+$ ]] || { log "STOP: no pid"; exit 6; }
PSTART=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null || echo 0)

# Verify binary/max_read/msgr
exe_md5=$(md5sum "/proc/$PID/exe" | awk '{print $1}')
[[ "$exe_md5" == "$BIN_MD5" ]] || { log "STOP: exe md5 mismatch"; exit 6; }
grep -q 'max_read=262144' /proc/mounts || { log "STOP: max_read"; exit 6; }
proc_conf=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | awk -F= '$1=="CEPH_CONF"{print $2}')
msgr_ok=$(grep -c 'ms_async_op_threads = 8' "$proc_conf" 2>/dev/null || echo 0)
[[ "$msgr_ok" -eq 1 ]] || { log "STOP: msgr!=8"; exit 6; }

# Find .stats file
STATS_FILE=$( (find /home -name ".stats" -path "*juicefs*" 2>/dev/null || true) | head -1)
[[ -n "$STATS_FILE" ]] || STATS_FILE=$( (find /root -name ".stats" -path "*juicefs*" 2>/dev/null || true) | head -1)
[[ -n "$STATS_FILE" ]] || STATS_FILE=$( (find /tmp -name ".stats" -path "*juicefs*" 2>/dev/null || true) | head -1)
log "Stats file: $STATS_FILE"

# Verify file sets
for stem in storage_test read_test rw_test; do
  cnt=$(find "$TEST_DIR" -maxdepth 1 -type f -name "${stem}.*.0" 2>/dev/null | wc -l)
  [[ "$cnt" -eq 128 ]] || { log "STOP: ${stem}=$cnt != 128"; exit 6; }
done
sz=$(stat -c %s "$TEST_DIR/storage_test.0.0" 2>/dev/null || echo 0)
[[ "$sz" -eq 1073741824 ]] || { log "STOP: file size"; exit 6; }

# File fingerprint
stat_all_files > "$OUT/files/pre.tsv"
log "Files: $(wc -l < "$OUT/files/pre.tsv") files"

# Mount fingerprint
{
  echo "pid=$PID starttime_ticks=$PSTART"
  echo "exe=$(readlink -f /proc/$PID/exe)"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
  echo "proc_ceph_conf=$proc_conf"
  echo "ms_async_op_threads_8=$msgr_ok"
} > "$OUT/fingerprint/pre.txt"
log "Mount OK pid=$PID"

# Generate and validate B0 jobfile
if [[ -f "$SCRIPT_DIR/t56-gen-jobfiles.sh" ]]; then
  bash "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$OUT/jobfiles" > "$OUT/jobfiles-gen.log" 2>&1
  bash "$SCRIPT_DIR/t56-validate-jobfiles.sh" "$OUT/jobfiles" > "$OUT/jobfiles-validate.log" 2>&1
elif [[ -f /tmp/t56-gen-jobfiles.sh ]]; then
  bash /tmp/t56-gen-jobfiles.sh "$OUT/jobfiles" > "$OUT/jobfiles-gen.log" 2>&1
  bash /tmp/t56-validate-jobfiles.sh "$OUT/jobfiles" > "$OUT/jobfiles-validate.log" 2>&1
else
  log "STOP: t56 helper scripts not found"; exit 5
fi
[[ $? -eq 0 ]] || { log "STOP: jobfile validation failed"; exit 5; }
cp "$OUT/jobfiles/B0.fio" "$OUT/arm/B0.fio"
md5sum "$OUT/jobfiles/B0.fio" > "$OUT/arm/jobfile.md5"
log "Jobfile B0 validated"

# ===== Phase 2: Samplers =====
# TiKV metrics regex (expanded for 03-20A)
TIKV_RE='tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_secs_(sum|count)|tikv_engine_pending_compaction_bytes|tikv_engine_compaction_duration_seconds_(sum|count)|tikv_engine_compaction_flow_bytes|tikv_engine_num_files_at_level|tikv_engine_stall_micro_seconds|tikv_engine_write_stall|tikv_engine_write_stall_reason|tikv_scheduler_(flush|l0|throttle|write)_flow|tikv_scheduler_pending_compaction_bytes|tikv_rate_limiter_max_bytes_per_sec|process_cpu_seconds_total'

# Client metrics from /metrics
CLIENT_KEYS='juicefs_meta_ops_duration_seconds_Write|juicefs_meta_ops_total_Write|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_transaction_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_staging_blocks'

start_samplers() {
  # jfs-stats from .stats (1s)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"; SF="'"$STATS_FILE"'"
    while true; do
      ts=$(date +%s)
      if [[ -f "$SF" ]]; then
        cat "$SF" 2>/dev/null | while IFS= read -r line; do
          printf "%s\t%s\n" "$ts" "$line" >> "$OUT/samplers/jfs-stats.tsv"
        done
      fi
      sleep 1
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/jfs-stats.pid"

  # Client /metrics (1s)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"; KEYS="'"$CLIENT_KEYS"'"
    while true; do
      ts=$(date +%s)
      curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$KEYS" | while IFS= read -r line; do
        printf "%s\t%s\n" "$ts" "$line" >> "$OUT/samplers/jfs-runtime.tsv"
      done
      sleep 1
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/jfs-runtime.pid"

  # Client host (1s): /proc/stat, mem, NIC
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    while true; do
      ts=$(date +%s)
      cpu=$(head -1 /proc/stat 2>/dev/null)
      mem=$(awk "/MemAvailable/{print \$2}" /proc/meminfo 2>/dev/null)
      printf "%s\t%s\tmem=%s\n" "$ts" "$cpu" "$mem" >> "$OUT/samplers/client-host.tsv"
      sleep 1
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/client-host.pid"

  # TiKV metrics (5s, sequential)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
    RE="'"$TIKV_RE"'"
    while true; do
      ts=$(date +%s)
      for ep in "${EPS[@]}"; do
        host=${ep%%:*}
        curl -s --connect-timeout 5 "http://${host}:20180/metrics" 2>/dev/null | grep -E "$RE" | while IFS= read -r line; do
          printf "%s\t%s\t%s\n" "$ts" "$host" "$line" >> "$OUT/samplers/tikv.tsv"
        done
      done
      sleep 5
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/tikv.pid"

  # TiKV host: iostat + process (per node, ~5-8s)
  for ip in "${TIKV_IPS[@]}"; do
    nice -n 19 bash -c '
      OUT="'"$OUT"'"; IP="'"$ip"'"
      SSH_ARR=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
      while true; do
        ts=$(date +%s)
        # iostat -y (true interval, skip first)
        iostat=$("${SSH_ARR[@]}" "$IP" "iostat -y -x -d 1 1 2>/dev/null | tail -5" 2>/dev/null || echo "ERR")
        # process stat
        pstat=$("${SSH_ARR[@]}" "$IP" "cat /proc/loadavg; awk '{print \$1+\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9+\$10}' /proc/$(pgrep tikv-server|head -1)/stat 2>/dev/null" 2>/dev/null || echo "ERR")
        printf "%s\t%s\tiostat=%s\tpstat=%s\n" "$ts" "$IP" "$iostat" "$pstat" >> "$OUT/samplers/tikv-host-${IP}.tsv"
        sleep 5
      done
    ' 2>/dev/null &
    echo $! > "$OUT/samplers/tikv-host-${ip}.pid"
  done

  # Ceph (30s)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    while true; do
      ts=$(date +%s)
      health=$(sudo ceph health 2>/dev/null || echo "ERR")
      pg=$(sudo ceph pg stat 2>/dev/null | head -1 || echo "NA")
      printf "%s\t%s\t%s\n" "$ts" "$health" "$pg" >> "$OUT/samplers/ceph.tsv"
      sleep 30
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/ceph.pid"

  # Pool (15s) + hard watchdog (JSON via python script)
  cat > "$OUT/pool_parse.py" << 'PYEOF'
import sys,json
d=json.load(sys.stdin)
for p in d.get("pools",[]):
    if "juicefs-data" in p.get("name",""):
        s=p.get("stats",{})
        print(s.get("objects",0), s.get("bytes_used",0), s.get("max_avail",0))
        break
PYEOF
  nice -n 19 bash -c "
    OUT='$OUT'; OBJ_HARD=$OBJ_HARD
    while true; do
      ts=\$(date +%s)
      line=\$(sudo ceph df --format=json 2>/dev/null | python3 $OUT/pool_parse.py 2>/dev/null || echo 'ERR ERR ERR')
      objs=\$(echo \"\$line\" | awk '{print \$1}')
      printf '%s\t%s\n' \"\$ts\" \"\$line\" >> \"\$OUT/samplers/pool.tsv\"
      if [[ \"\$objs\" =~ ^[0-9]+\$ && \"\$objs\" -gt \$OBJ_HARD ]]; then
        echo '[WD] objects='\$objs' > '\$OBJ_HARD >> \"\$OUT/STOP.txt\"
        pkill -INT -f 'fio.*B0' 2>/dev/null || true
      fi
      sleep 15
    done
  " 2>/dev/null &
  echo $! > "$OUT/samplers/pool.pid"

  sleep 2
  log "Samplers started"
}

start_samplers

# Save sampler PIDs
{
  echo "=== Sampler PIDs ==="
  for f in "$OUT"/samplers/*.pid; do
    echo "$(basename $f .pid)=$(cat $f)"
  done
} > "$OUT/samplers/pids.tsv"

# Full metrics snapshot (pre-load)
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | gzip > "$OUT/metrics-full/tikv-${ip}-pre.prom.gz"
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -v '^#' | awk '{print $1}' | sort -u > "$OUT/metrics-full/tikv-${ip}-pre.names.txt"
done
log "Full metrics snapshot (pre) done"

# ===== Phase 3: Pre-load reset =====
reset_to_gate "preload" || { log "STOP: preload reset failed"; exit 7; }

# ===== Phase 4: Run arm D-B256 =====
log "=== ARM D-B256 ==="

# PRE snapshot
if [[ -n "$STATS_FILE" && -f "$STATS_FILE" ]]; then
  cp "$STATS_FILE" "$OUT/arm/pre.stats"
fi
curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$CLIENT_KEYS" > "$OUT/arm/pre.tsv"
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" > "$OUT/arm/tikv-pre-${ip}.tsv"
done
echo -e "$(date +%s)\tD-B256\tpre" >> "$OUT/phase.tsv"

# Start fio
log "Starting fio D-B256 (B0 jobfile, 180s)"
setsid fio "$OUT/arm/B0.fio" --write_bw_log="$OUT/arm/bw/D-B256" > "$OUT/arm/fio.stdout" 2> "$OUT/arm/fio.stderr" &
FIO_PID=$!
echo $FIO_PID > "$OUT/arm/fio.pid"
echo -e "$(date +%s)\tD-B256\tfio_start pid=$FIO_PID" >> "$OUT/phase.tsv"

# Monitor
while kill -0 $FIO_PID 2>/dev/null; do
  sleep 5
  # Check STOP
  [[ -f "$OUT/STOP.txt" ]] && { log "STOP: watchdog triggered"; kill -INT -$FIO_PID 2>/dev/null || true; break; }
  # Check mount
  mountpoint -q "$MNT" || { log "STOP: mount lost"; break; }
  # Check samplers
  sp_dead=0
  for sf in "$OUT"/samplers/*.pid; do
    sp_pid=$(cat "$sf" 2>/dev/null)
    kill -0 "$sp_pid" 2>/dev/null || { sp_dead=1; break; }
  done
  [[ $sp_dead -eq 0 ]] || { log "WARN: sampler died"; }
done

wait $FIO_PID 2>/dev/null || true
FIO_RC=$?
echo $FIO_RC > "$OUT/arm/fio.rc"
echo -e "$(date +%s)\tD-B256\tfio_end rc=$FIO_RC" >> "$OUT/phase.tsv"

# POST snapshot
if [[ -n "$STATS_FILE" && -f "$STATS_FILE" ]]; then
  cp "$STATS_FILE" "$OUT/arm/post.stats"
fi
curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$CLIENT_KEYS" > "$OUT/arm/post.tsv"
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" > "$OUT/arm/tikv-post-${ip}.tsv"
done
stat_all_files > "$OUT/files/post.tsv"

# Full metrics snapshot (post-load)
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | gzip > "$OUT/metrics-full/tikv-${ip}-post.prom.gz"
done

# Mechanical checks
bw_logs=$(find "$OUT/arm/bw" -name "*_bw.*.log" -type f | wc -l)
bw=$(grep -oP 'WRITE: bw=\K[0-9]+MiB' "$OUT/arm/fio.stdout" 2>/dev/null | head -1)
log "ARM D-B256: rc=$FIO_RC bw_logs=$bw_logs BW=$bw"

[[ $FIO_RC -eq 0 ]] || { log "STOP: fio rc=$FIO_RC"; }
[[ $bw_logs -ge 256 ]] || { log "STOP: bw_logs=$bw_logs < 256"; }

# ===== Phase 5: Final reset =====
reset_to_gate "final" || { log "WARN: final reset failed"; }

# ===== Phase 6: Cleanup =====
log "=== Cleanup ==="

# Stop samplers
for sf in "$OUT"/samplers/*.pid; do
  kill "$(cat "$sf")" 2>/dev/null || true
done
sleep 2

# Post fingerprint
{
  echo "pid=$PID starttime_ticks=$PSTART"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
} > "$OUT/fingerprint/post.txt"
md5sum "$SYS_CONF" >> "$OUT/fingerprint/post.txt"
sudo ceph osd dump 2>/dev/null | grep 'up_from' | head -1 > "$OUT/fingerprint/up_from-post.txt" || true

# Unmount
sync; umount "$MNT" 2>/dev/null || {
  mpid=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
  [[ -n "$mpid" ]] && kill "$mpid" 2>/dev/null; sleep 5; umount "$MNT" 2>/dev/null || true
}

# MANIFEST + archive
( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )
ARCHIVE="$ARCHIVE_DIR/opencode-t3.20a-${RUN_ID}.tar.gz"
tar -C /tmp -czf "$ARCHIVE" "$(basename "$OUT")"
md5sum "$ARCHIVE" > "${ARCHIVE}.md5"

log "=== T58 DONE ==="
log "OUT=$OUT"
log "ARCHIVE=$ARCHIVE"
log "BW=$bw bw_logs=$bw_logs rc=$FIO_RC"
