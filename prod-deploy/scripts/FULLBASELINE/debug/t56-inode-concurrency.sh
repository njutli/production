#!/usr/bin/env bash
# T56: randwrite inode concurrency boundary (03-19)
# Single mount, ABBA/BAAB, reset_to_gate, persistent samplers
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
PRIVATE_CONF="/tmp/t56-msgr8-${RUN_ID}.conf"
TIKV_IPS=(10.20.1.150 10.20.1.151 10.20.1.152)
TIKV_EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
SSH=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
SCP=(sshpass -p Sunrise@801 scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
OBJ_SOFT=2500000
OBJ_HARD=8000000
OUT="/tmp/opencode-t3.19-${RUN_ID}"
ARCHIVE_DIR=/tmp/production
JOBFILES_DIR="$OUT/jobfiles"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*" | tee -a "$OUT/wrapper.log"; }

# ===== Phase 1: Setup =====
mkdir -p "$OUT" "$JOBFILES_DIR" "$OUT/samplers" "$OUT/reset" "$OUT/arms" "$OUT/files" "$OUT/fingerprint"

# Generate jobfiles
bash "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$JOBFILES_DIR" > "$OUT/jobfiles-gen.log" 2>&1
bash "$SCRIPT_DIR/t56-validate-jobfiles.sh" "$JOBFILES_DIR" > "$OUT/jobfiles-validate.log" 2>&1
validate_rc=$?
if [[ $validate_rc -ne 0 ]]; then
  log "STOP: jobfile validation failed (rc=$validate_rc)"
  exit 1
fi
log "Jobfiles generated and validated"

# Record md5
md5sum "$JOBFILES_DIR"/*.fio > "$OUT/jobfiles.md5"
cp "$0" "$OUT/t56-script.sh"
md5sum "$0" > "$OUT/script.md5"
cp "${SCRIPT_DIR}/t56-gen-jobfiles.sh" "$OUT/"
cp "${SCRIPT_DIR}/t56-validate-jobfiles.sh" "$OUT/"

# Private CEPH_CONF
cp "$SYS_CONF" "$PRIVATE_CONF"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
export CEPH_CONF="$PRIVATE_CONF"

# ===== Phase 2: Preflight =====
log "=== Preflight ==="

# Environment snapshot
hostname > "$OUT/fingerprint/hostname.txt"
date '+%Y-%m-%d %H:%M:%S %z' > "$OUT/fingerprint/datetime.txt"
fio --version > "$OUT/fingerprint/fio-version.txt" 2>&1
df -Pk / | tail -1 > "$OUT/fingerprint/df.txt"

# Binary
[[ "$(md5sum "$BIN" | awk '{print $1}')" == "$BIN_MD5" ]] || { log "STOP: binary md5 mismatch"; exit 5; }

# System ceph.conf
sys_md5=$(md5sum "$SYS_CONF" | awk '{print $1}')
[[ "$sys_md5" == "$SYS_CONF_MD5" ]] || { log "STOP: system ceph.conf md5 mismatch: $sys_md5"; exit 5; }
cp "$SYS_CONF" "$OUT/fingerprint/ceph.conf.system"

# Ceph health
health=$(sudo ceph health 2>/dev/null || echo "ERR")
[[ "$health" == "HEALTH_OK" || "$health" == "HEALTH OK" ]] || { log "STOP: ceph health=$health"; exit 5; }

# OSD count
osd_up=$(sudo ceph osd stat 2>/dev/null | grep -oP '\d+(?= up)' | head -1)
osd_up=${osd_up:-0}
[[ "$osd_up" -ge 6 ]] || { log "STOP: OSD up=$osd_up < 6"; exit 5; }

# PG state
pg_clean=$(sudo ceph pg stat 2>/dev/null | grep -oP 'active\+clean.*?;' | head -1 || echo "")
log "PG: $pg_clean"

# up_from
up_from=$(sudo ceph osd dump 2>/dev/null | grep 'up_from' | head -1 || echo "")
echo "$up_from" > "$OUT/fingerprint/up_from-pre.txt"

# Root space
avail_k=$(df -Pk / | awk 'NR==2{print $4}')
[[ "$avail_k" -ge 5242880 ]] || { log "STOP: root < 5GiB"; exit 5; }

# Graceful unmount if needed
if mountpoint -q "$MNT"; then
  sync
  umount "$MNT" 2>/dev/null || {
    # Try killing mount process gracefully
    local mpid
    mpid=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
    if [[ -n "$mpid" ]]; then
      kill "$mpid" 2>/dev/null; sleep 5
      kill -9 "$mpid" 2>/dev/null; sleep 2
    fi
    umount "$MNT" 2>/dev/null || true
  }
  sleep 2
  mountpoint -q "$MNT" && { log "STOP: cannot clean leftover mount"; exit 6; }
fi

# Mount
"$BIN" mount -d $MOUNT_OPTS "$META" "$MNT" >> "$OUT/mount.log" 2>&1
sleep 10
mountpoint -q "$MNT" || { log "STOP: mount failed"; exit 6; }

PID=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
[[ "$PID" =~ ^[0-9]+$ ]] || { log "STOP: cannot resolve pid"; exit 6; }
PSTART=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null || echo "0")

# Verify binary
exe_md5=$(md5sum "/proc/$PID/exe" | awk '{print $1}')
[[ "$exe_md5" == "$BIN_MD5" ]] || { log "STOP: exe md5 mismatch: $exe_md5"; exit 6; }

# Verify max_read
grep -q 'max_read=262144' /proc/mounts || { log "STOP: max_read != 262144"; exit 6; }

# Verify msgr=8
proc_conf=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | awk -F= '$1=="CEPH_CONF"{print $2}')
msgr_ok=$(grep -c 'ms_async_op_threads = 8' "$proc_conf" 2>/dev/null || echo 0)
[[ "$msgr_ok" -eq 1 ]] || { log "STOP: msgr!=8"; exit 6; }

# Verify file sets
for stem in storage_test read_test rw_test; do
  cnt=$(find "$TEST_DIR" -maxdepth 1 -type f -name "${stem}.*.0" 2>/dev/null | wc -l)
  [[ "$cnt" -eq 128 ]] || { log "STOP: ${stem} count=$cnt != 128"; exit 6; }
done

# Verify file sizes (spot check)
sz=$(stat -c %s "$TEST_DIR/storage_test.0.0" 2>/dev/null || echo 0)
[[ "$sz" -eq 1073741824 ]] || { log "STOP: storage_test.0.0 size=$sz"; exit 6; }

# Save file fingerprints (path inode size mtime_ns)
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
} | sort > "$OUT/files/pre.tsv"
log "File fingerprint: $(wc -l < "$OUT/files/pre.tsv") files"

# Save mount fingerprint
{
  echo "pid=$PID starttime_ticks=$PSTART"
  echo "exe=$(readlink -f /proc/$PID/exe)"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
  echo "proc_ceph_conf=$proc_conf"
  echo "ms_async_op_threads_8=$msgr_ok"
} > "$OUT/fingerprint/pre.txt"

log "Mount OK pid=$PID starttime=$PSTART msgr=8"

# ===== Phase 3: Samplers =====
CLIENT_KEYS='juicefs_meta_ops_duration_seconds_Write|juicefs_meta_ops_total_Write|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_transaction_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_staging_blocks'

start_samplers() {
  # Client metrics (1s)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    while true; do
      ts=$(date +%s)
      curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "'"${CLIENT_KEYS}"'" | while IFS= read -r line; do
        echo -e "'"$ts"'\t'"$line"'" >> "'"$OUT"'/samplers/client.tsv.tmp"
      done
      sleep 1
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/client.pid"

  # Ceph health (30s)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    while true; do
      ts=$(date +%s)
      health=$(sudo ceph health 2>/dev/null || echo "ERR")
      pg=$(sudo ceph pg stat 2>/dev/null | head -1 || echo "NA")
      echo -e "'"$ts"'\t'"$health"'\t'"$pg"'" >> "'"$OUT"'/samplers/ceph.tsv.tmp"
      sleep 30
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/ceph.pid"

  # Pool objects (15s) + hard watchdog
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    META="'"$META"'"
    OBJ_HARD='"$OBJ_HARD"'
    while true; do
      ts=$(date +%s)
      objs=$(sudo rados df --format=json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); pools=[p for p in d[\"pools\"] if \"juicefs-data\" in p[\"name\"]]; print(pools[0][\"stats\"][\"objects\"] if pools else 0)" 2>/dev/null || echo "ERR")
      stored=$(sudo rados df --format=json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); pools=[p for p in d[\"pools\"] if \"juicefs-data\" in p[\"name\"]]; print(pools[0][\"stats\"][\"size\"] if pools else 0)" 2>/dev/null || echo "ERR")
      echo -e "'"$ts"'\t'"$objs"'\t'"$stored"'" >> "'"$OUT"'/samplers/pool.tsv.tmp"
      # Hard watchdog
      if [[ "$objs" =~ ^[0-9]+$ && "$objs" -gt $OBJ_HARD ]]; then
        echo "[WD] objects=$objs > $OBJ_HARD, sending SIGINT to fio"
        pkill -INT -f "fio.*storage_test.*rw_test" 2>/dev/null || true
      fi
      sleep 15
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/pool.pid"

  # TiKV metrics (5s, sequential)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
    TIKV_RE="tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_seconds_(sum|count)|tikv_engine_pending_compaction_bytes|process_cpu_seconds_total"
    while true; do
      ts=$(date +%s)
      for ep in "${EPS[@]}"; do
        host=${ep%%:*}
        curl -s "http://${host}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" | while IFS= read -r line; do
          echo -e "'"$ts"'\t'"$host"'\t'"$line"'" >> "'"$OUT"'/samplers/tikv.tsv.tmp"
        done
      done
      sleep 5
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/tikv.pid"

  sleep 2
  # Rename tmp files
  for s in client ceph pool tikv; do
    mv "$OUT/samplers/${s}.tsv.tmp" "$OUT/samplers/${s}.tsv" 2>/dev/null || true
  done

  log "Samplers started: client=$(cat $OUT/samplers/client.pid) ceph=$(cat $OUT/samplers/ceph.pid) pool=$(cat $OUT/samplers/pool.pid) tikv=$(cat $OUT/samplers/tikv.pid)"
}

# Continuous samplers need to append to .tsv not .tsv.tmp
# Fix: use direct append from the start
start_samplers_fixed() {
  # Client metrics (1s)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    KEYS="'"$CLIENT_KEYS"'"
    while true; do
      ts=$(date +%s)
      curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$KEYS" | while IFS= read -r line; do
        printf "%s\t%s\n" "$ts" "$line" >> "$OUT/samplers/client.tsv"
      done
      sleep 1
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/client.pid"

  # Ceph health (30s)
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

  # Pool objects (15s) + hard watchdog
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    OBJ_HARD='"$OBJ_HARD"'
    while true; do
      ts=$(date +%s)
      objs=$(sudo rados df 2>/dev/null | grep juicefs-data | head -1 | awk "{print \$3}" 2>/dev/null || echo "ERR")
      printf "%s\t%s\n" "$ts" "$objs" >> "$OUT/samplers/pool.tsv"
      if [[ "$objs" =~ ^[0-9]+$ && "$objs" -gt $OBJ_HARD ]]; then
        echo "[WD] objects=$objs > $OBJ_HARD, SIGINT fio" >&2
        pkill -INT -f "fio.*storage_test" 2>/dev/null || true
      fi
      sleep 15
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/pool.pid"

  # TiKV metrics (5s, sequential)
  nice -n 19 bash -c '
    OUT="'"$OUT"'"
    EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
    TIKV_RE="tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_seconds_(sum|count)|tikv_engine_pending_compaction_bytes|process_cpu_seconds_total"
    while true; do
      ts=$(date +%s)
      for ep in "${EPS[@]}"; do
        host=${ep%%:*}
        curl -s "http://${host}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" | while IFS= read -r line; do
          printf "%s\t%s\t%s\n" "$ts" "$host" "$line" >> "$OUT/samplers/tikv.tsv"
        done
      done
      sleep 5
    done
  ' 2>/dev/null &
  echo $! > "$OUT/samplers/tikv.pid"

  sleep 2
  log "Samplers started: client=$(cat $OUT/samplers/client.pid) ceph=$(cat $OUT/samplers/ceph.pid) pool=$(cat $OUT/samplers/pool.pid) tikv=$(cat $OUT/samplers/tikv.pid)"
}

start_samplers_fixed

# ===== Phase 4: reset_to_gate =====
FORMAL_BASE_OBJECTS=""
FORMAL_BASE_STORED=""
FORMAL_BASE_MAX_AVAIL=""

compact_osd() {
  local osd
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    sudo ceph tell "osd.$osd" compact 2>/dev/null || true
  done
  # Wait for compact to settle
  sleep 30
  return 0
}

drop_caches_4node() {
  local ok=0
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 && ok=$((ok+1)) || ok=$ok
  for ip in "${TIKV_IPS[@]}"; do
    if "${SSH[@]}" "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
      ok=$((ok+1))
    else
      # retry once
      sleep 2
      "${SSH[@]}" "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null && ok=$((ok+1)) || ok=$ok
    fi
  done
  [[ $ok -eq 4 ]]
}

pool_sample() {
  local ts objs stored avail
  ts=$(date +%s)
  local df
  df=$(sudo rados df 2>/dev/null | grep juicefs-data | head -1)
  # rados df format: POOL STORED(units) STORED_UNIT OBJECTS ...
  # e.g. "juicefs-data  892 GiB  2434671  0  ..."
  objs=$(echo "$df" | awk '{print $4}')
  stored=$(echo "$df" | awk '{print $2" "$3}')
  avail=$(echo "$df" | awk '{print $NF}')
  echo -e "$ts\t$objs\t$stored\t$avail"
}

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

tikv_pending_ok() {
  for ip in "${TIKV_IPS[@]}"; do
    local val
    val=$(curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep 'tikv_engine_pending_compaction_bytes' | grep -v '^#' | awk '{print $2}' | head -1)
    [[ -n "$val" && "$val" -eq 0 ]] || return 1
  done
  return 0
}

idle_gate() {
  local tries=0
  while [[ $tries -lt 30 ]]; do  # 5 min max
    # No foreign processes (exclude our own samplers)
    local foreign
    foreign=$(pgrep -af 'FULLBASELINE|fio.*storage_test|juicefs gc' 2>/dev/null | grep -v -E 'pgrep|grep|t56|samplers|nice -n 19|rados df|curl -s|process_cpu' | head -1)
    if [[ -n "$foreign" ]]; then
      log "  idle_gate: foreign proc: $foreign"
      sleep 10; tries=$((tries+1)); continue
    fi
    # Health
    local health
    health=$(sudo ceph health 2>/dev/null || echo "ERR")
    [[ "$health" == "HEALTH_OK" || "$health" == "HEALTH OK" ]] || { log "  idle_gate: health=$health"; sleep 10; tries=$((tries+1)); continue; }
    # Pass
    echo "$(date +%s) idle_gate PASS" >> "$OUT/idle-gate.log"
    return 0
  done
  echo "$(date +%s) idle_gate FAIL" >> "$OUT/idle-gate.log"
  return 1
}

reset_to_gate() {
  local arm_label=$1
  local reset_dir="$OUT/reset/before-${arm_label}"
  mkdir -p "$reset_dir"

  log "reset_to_gate: $arm_label"

  # Step 1: sync
  sync -f "$MNT" 2>/dev/null || true

  # Step 2: OSD compact + cooldown
  log "  step2: OSD compact"
  compact_osd || { log "STOP: OSD compact cooldown failed"; return 1; }

  # Step 3: wait 30s + repeat
  sleep 30
  compact_osd || { log "STOP: OSD compact cooldown (2nd) failed"; return 1; }

  # Step 4: juicefs gc --compact
  log "  step4: gc --compact"
  local gc_out="$reset_dir/gc.log"
  echo "$(date +%s) gc_start" > "$gc_out"
  "$BIN" gc --compact "$META" >> "$gc_out" 2>&1
  local gc_rc=$?
  echo "$(date +%s) gc_end rc=$gc_rc" >> "$gc_out"
  [[ $gc_rc -eq 0 ]] || { log "STOP: gc rc=$gc_rc"; return 1; }

  # Step 5: Object convergence
  log "  step5: object convergence"
  local conv=0
  local tries=0
  while [[ $tries -lt 40 ]]; do  # 10 min max (15s interval)
    local s1 s2 s3
    s1=$(pool_sample)
    sleep 15
    s2=$(pool_sample)
    sleep 15
    s3=$(pool_sample)

    local o1 o2 o3
    o1=$(echo "$s1" | awk '{print $2}')
    o2=$(echo "$s2" | awk '{print $2}')
    o3=$(echo "$s3" | awk '{print $2}')

    echo -e "$s1\n$s2\n$s3" > "$reset_dir/objects-try${tries}.tsv"

    # Check convergence
    if [[ "$o1" =~ ^[0-9]+$ && "$o1" -le $OBJ_SOFT ]]; then
      local max_min_diff
      max_min_diff=$(( ${o1/#/0} > ${o2/#/0} ? ${o1/#/0} - ${o2/#/0} : ${o2/#/0} - ${o1/#/0} ))
      max_min_diff=$(( max_min_diff > (${o2/#/0} > ${o3/#/0} ? ${o2/#/0} - ${o3/#/0} : ${o3/#/0} - ${o2/#/0}) ? max_min_diff : (${o2/#/0} > ${o3/#/0} ? ${o2/#/0} - ${o3/#/0} : ${o3/#/0} - ${o2/#/0}) ))
      if [[ $max_min_diff -le 128 ]]; then
        conv=1
        # Establish formal base on first reset after W1
        if [[ -z "$FORMAL_BASE_OBJECTS" && "$arm_label" == "post-w1" ]]; then
          FORMAL_BASE_OBJECTS=$(echo -e "$s1\n$s2\n$s3" | awk '{print $2}' | sort -n | awk 'NR==2')
          FORMAL_BASE_STORED=$(echo -e "$s1\n$s2\n$s3" | awk '{print $3}' | sort -n | awk 'NR==2')
          FORMAL_BASE_MAX_AVAIL=$(echo -e "$s1\n$s2\n$s3" | awk '{print $4}' | sort -n | awk 'NR==2')
          log "  Formal base: objects=$FORMAL_BASE_OBJECTS stored=$FORMAL_BASE_STORED"
        fi
        break
      fi
    fi
    tries=$((tries+1))
  done
  [[ $conv -eq 1 ]] || { log "STOP: object convergence failed"; return 1; }

  # Step 6: post-GC compact
  log "  step6: post-GC compact"
  compact_osd || { log "STOP: post-GC compact failed"; return 1; }

  # Step 7: TiKV pending
  log "  step7: TiKV pending check"
  local tikv_tries=0
  while [[ $tikv_tries -lt 60 ]]; do
    tikv_pending_ok && break
    sleep 10
    tikv_tries=$((tikv_tries+1))
  done
  [[ $tikv_tries -lt 60 ]] || { log "STOP: TiKV pending != 0"; return 1; }

  # Step 8: stat all files
  log "  step8: stat all files"
  stat_all_files > "$reset_dir/file-stats.tsv"

  # Step 9: drop caches (4 nodes)
  log "  step9: drop caches"
  drop_caches_4node || { log "STOP: drop_caches failed"; return 1; }
  echo "$(date +%s) drop_caches 4/4 OK" > "$reset_dir/drop-caches.txt"

  # Step 10: 60s quiet
  log "  step10: 60s quiet"
  sleep 60

  # Step 11: idle gate (30s) + fio start
  log "  step11: idle gate"
  idle_gate || { log "STOP: idle gate failed"; return 1; }

  # Record phase marker
  echo -e "$(date +%s)\t$arm_label\tready" >> "$OUT/phase.tsv"

  log "reset_to_gate: $arm_label OK"
  return 0
}

# ===== Phase 5: run_arm =====
run_arm() {
  local jobfile=$1 label=$2
  local arm_dir="$OUT/arms/$label"
  mkdir -p "$arm_dir/bw"

  log "ARM $label: starting (jobfile=$(basename $jobfile))"

  # Pre snapshot
  curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$CLIENT_KEYS" > "$arm_dir/pre.tsv"
  echo -e "$(date +%s)\t$label\tpre" >> "$OUT/phase.tsv"

  # Record jobfile md5
  md5sum "$jobfile" > "$arm_dir/jobfile.md5"

  # Start fio
  local bw_prefix="$arm_dir/bw/${label}"
  echo "$(date +%s) fio_start" >> "$OUT/phase.tsv"

  setsid fio "$jobfile" --write_bw_log="$bw_prefix" > "$arm_dir/fio.stdout" 2> "$arm_dir/fio.stderr" &
  local fio_pid=$!
  echo $fio_pid > "$arm_dir/fio.pid"
  log "ARM $label: fio pid=$fio_pid"

  # Wait for fio
  wait $fio_pid
  local rc=$?
  echo $rc > "$arm_dir/fio.rc"
  echo "$(date +%s) fio_end rc=$rc" >> "$OUT/phase.tsv"

  # Post snapshot
  curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$CLIENT_KEYS" > "$arm_dir/post.tsv"

  # Mechanical checks
  local bw_logs
  bw_logs=$(find "$arm_dir/bw" -name "*_bw.*.log" -type f | wc -l)
  log "ARM $label: rc=$rc bw_logs=$bw_logs"

  # Extract BW from fio stdout
  local bw
  bw=$(grep -oP 'WRITE: bw=\K[0-9]+MiB' "$arm_dir/fio.stdout" 2>/dev/null | head -1)
  log "ARM $label: BW=$bw"

  # File stats post
  stat_all_files > "$arm_dir/file-stats-post.tsv"

  # Check
  [[ $rc -eq 0 ]] || { log "STOP: $label fio rc=$rc"; return 1; }
  [[ $bw_logs -ge 256 ]] || { log "STOP: $label bw_logs=$bw_logs < 256"; return 1; }

  return 0
}

# ===== Phase 6: Main sequence =====
log "=== T56 03-19 start run_id=$RUN_ID ==="

# Initial reset
reset_to_gate "initial" || { log "STOP: initial reset failed"; exit 7; }

# Warmup W0 (B0 jobfile) and W1 (B1 jobfile)
log "=== Warmup W0 ==="
run_arm "$JOBFILES_DIR/B0.fio" "W0" || { log "STOP: W0 failed"; exit 8; }
reset_to_gate "post-w0" || { log "STOP: post-w0 reset failed"; exit 7; }

log "=== Warmup W1 ==="
run_arm "$JOBFILES_DIR/B1.fio" "W1" || { log "STOP: W1 failed"; exit 8; }
reset_to_gate "post-w1" || { log "STOP: post-w1 reset failed"; exit 7; }

# Block 0: R0-a → B0-a → B0-b → R0-b
log "=== Block 0: R0-a B0-a B0-b R0-b ==="
run_arm "$JOBFILES_DIR/R0.fio" "R0-a" || { log "STOP: R0-a"; exit 8; }
reset_to_gate "post-r0a" || { log "STOP"; exit 7; }
run_arm "$JOBFILES_DIR/B0.fio" "B0-a" || { log "STOP: B0-a"; exit 8; }
reset_to_gate "post-b0a" || { log "STOP"; exit 7; }
run_arm "$JOBFILES_DIR/B0.fio" "B0-b" || { log "STOP: B0-b"; exit 8; }
reset_to_gate "post-b0b" || { log "STOP"; exit 7; }
run_arm "$JOBFILES_DIR/R0.fio" "R0-b" || { log "STOP: R0-b"; exit 8; }
reset_to_gate "post-r0b" || { log "STOP"; exit 7; }

# Block 1: B1-a → R1-a → R1-b → B1-b
log "=== Block 1: B1-a R1-a R1-b B1-b ==="
run_arm "$JOBFILES_DIR/B1.fio" "B1-a" || { log "STOP: B1-a"; exit 8; }
reset_to_gate "post-b1a" || { log "STOP"; exit 7; }
run_arm "$JOBFILES_DIR/R1.fio" "R1-a" || { log "STOP: R1-a"; exit 8; }
reset_to_gate "post-r1a" || { log "STOP"; exit 7; }
run_arm "$JOBFILES_DIR/R1.fio" "R1-b" || { log "STOP: R1-b"; exit 8; }
reset_to_gate "post-r1b" || { log "STOP"; exit 7; }
run_arm "$JOBFILES_DIR/B1.fio" "B1-b" || { log "STOP: B1-b"; exit 8; }

# Final reset
reset_to_gate "final" || { log "WARN: final reset failed (non-fatal)"; }

# ===== Phase 7: Cleanup =====
log "=== Cleanup ==="

# Stop samplers
for s in client ceph pool tikv; do
  pid_file="$OUT/samplers/${s}.pid"
  if [[ -f "$pid_file" ]]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi
done
sleep 2

# Final file fingerprint
stat_all_files > "$OUT/files/post.tsv"

# Post fingerprint
{
  echo "pid=$PID starttime_ticks=$PSTART"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
} > "$OUT/fingerprint/post.txt"

# System ceph.conf post
md5sum "$SYS_CONF" >> "$OUT/fingerprint/post.txt"

# up_from post
up_from_post=$(sudo ceph osd dump 2>/dev/null | grep 'up_from' | head -1 || echo "")
echo "$up_from_post" > "$OUT/fingerprint/up_from-post.txt"

# Unmount
fuser -k "$MNT" 2>/dev/null || true
sleep 1
umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true

# MANIFEST
( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )

# Archive
ARCHIVE="$ARCHIVE_DIR/opencode-t3.19-${RUN_ID}.tar.gz"
tar -C /tmp -czf "$ARCHIVE" "$(basename "$OUT")"
md5sum "$ARCHIVE" > "${ARCHIVE}.md5"

log "=== T56 DONE ==="
log "OUT=$OUT"
log "ARCHIVE=$ARCHIVE"
