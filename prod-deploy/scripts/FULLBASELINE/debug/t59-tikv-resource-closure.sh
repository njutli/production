#!/usr/bin/env bash
# T59: TiKV NVMe/compaction worker resource closure (03-20B)
# --self-test: verify deps/parsers
# --dry-run RUN_ID: check without mount/SSH/fio
# RUN_ID: full execution
set -euo pipefail

RUN_ID=""
MODE="run"
if [[ "${1:-}" == "--self-test" ]]; then
  MODE="selftest"
elif [[ "${1:-}" == "--dry-run" ]]; then
  MODE="dryrun"
  RUN_ID="${2:-$(date +%Y%m%d-%H%M%S)}"
else
  RUN_ID="${1:-$(date +%Y%m%d-%H%M%S)}"
fi

# ===== Config =====
BIN=/tmp/juicefs-03-8
BIN_MD5=de93563f11a5ff3bd94dd25a4e0283b1
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'
MNT=/mnt/juicefs
TEST_DIR=/mnt/juicefs/test_dir
MOUNT_OPTS='--max-uploads 150 --cache-size 0 --max-fuse-io 256K'
SYS_CONF=/etc/ceph/ceph.conf
SYS_CONF_MD5=5b6be34179a64e0a5f9c6d3a9690041f
PRIVATE_CONF="/tmp/t59-msgr8-${RUN_ID}.conf"
TIKV_IPS=(10.20.1.150 10.20.1.151 10.20.1.152)
SSH_BASE=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
OBJ_SOFT=2500000
OBJ_HARD=8000000
OUT="/tmp/opencode-t3.20b-${RUN_ID}"
ARCHIVE_DIR=/tmp/production
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# TiKV metrics regex (expanded for 03-20B)
TIKV_RE='tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_scheduler_(flush|l0|throttle|write)_flow|tikv_scheduler_pending_compaction_bytes|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_secs_(sum|count)|tikv_engine_pending_compaction_bytes|tikv_engine_compaction_duration_seconds_(sum|count)|tikv_engine_compaction_flow_bytes|tikv_engine_num_files_at_level|tikv_engine_num_subcompaction_scheduled|tikv_engine_stall_micro_seconds|tikv_engine_write_stall|tikv_engine_write_stall_reason|tikv_engine_wal_file_sync_micro_seconds|tikv_engine_wal_file_synced|tikv_rate_limiter_max_bytes_per_sec|tikv_thread_cpu_seconds_total|tikv_threads_io_bytes_total|tikv_threads_state|process_cpu_seconds_total'

CLIENT_KEYS='juicefs_meta_ops_duration_seconds_Write|juicefs_meta_ops_total_Write|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_transaction_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_staging_blocks'

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; echo "$msg" >> "$OUT/wrapper.log" 2>/dev/null; echo "$msg"; }

# ===== Self-test =====
if [[ "$MODE" == "selftest" ]]; then
  echo "=== T59 Self-test ==="
  echo "1. Checking dependencies..."
  for cmd in bash fio curl python3 bc awk md5sum stat findmnt lsblk ceph; do
    command -v "$cmd" >/dev/null 2>&1 && echo "  $cmd: OK" || echo "  $cmd: MISSING"
  done
  echo "2. Checking SSH to TiKV nodes..."
  for ip in "${TIKV_IPS[@]}"; do
    timeout 5 "${SSH_BASE[@]}" "$ip" 'echo ok' 2>/dev/null && echo "  $ip: OK" || echo "  $ip: FAIL"
  done
  echo "3. Checking TiKV metrics endpoint..."
  for ip in "${TIKV_IPS[@]}"; do
    curl -s --connect-timeout 3 "http://${ip}:20180/metrics" 2>/dev/null | head -1 | grep -q '^#' && echo "  $ip: OK" || echo "  $ip: FAIL"
  done
  echo "4. Checking binary..."
  [[ -f "$BIN" ]] && md5sum "$BIN" || echo "  binary missing"
  echo "5. Checking t56 helpers..."
  for f in t56-gen-jobfiles.sh t56-validate-jobfiles.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] && echo "  $SCRIPT_DIR/$f: OK" || [[ -f "/tmp/$f" ]] && echo "  /tmp/$f: OK" || echo "  $f: MISSING"
  done
  echo "=== Self-test done ==="
  exit 0
fi

# ===== Dry-run =====
if [[ "$MODE" == "dryrun" ]]; then
  echo "=== T59 Dry-run RUN_ID=$RUN_ID ==="
  echo "OUT=$OUT"
  echo "BIN=$BIN (expect md5=$BIN_MD5)"
  echo "META=$META"
  echo "MOUNT_OPTS=$MOUNT_OPTS"
  echo "TIKV_IPS=${TIKV_IPS[*]}"
  echo "Jobfile: B0.fio (expect md5=3b43b01ed2c4033ed42ad52bddc77c2f)"
  echo "Pool parser: python3 inline"
  echo "SSH_BASE: ${SSH_BASE[*]}"
  echo "=== Dry-run done ==="
  exit 0
fi

# ===== Normal execution =====
mkdir -p "$OUT" "$OUT/samplers" "$OUT/reset" "$OUT/arm/bw" "$OUT/files" "$OUT/fingerprint" "$OUT/jobfiles" "$OUT/metrics-full" "$OUT/preflight" "$OUT/device"

# Private CEPH_CONF
cp "$SYS_CONF" "$PRIVATE_CONF"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
export CEPH_CONF="$PRIVATE_CONF"

# Pool JSON parser script
cat > "$OUT/pool_parse.py" << 'PYEOF'
import sys,json
d=json.load(sys.stdin)
for p in d.get("pools",[]):
    if "juicefs-data" in p.get("name",""):
        s=p.get("stats",{})
        print(s.get("objects",0), s.get("bytes_used",0), s.get("max_avail",0))
        break
PYEOF

# OSD key finder + value extractor
cat > "$OUT/find_osd_keys.py" << 'PYEOF'
import sys,json
d=json.load(sys.stdin)
results={}
def find_keys(obj, path=""):
    if isinstance(obj, dict):
        for k,v in obj.items():
            p = f"{path}.{k}" if path else k
            if k in ("compact_running","compact_queue_len"):
                results[k] = p
            if k == "kv_sync_lat" and isinstance(v, dict) and "avgtime" in v:
                results["kv_sync_lat"] = p + ".avgtime"
            find_keys(v, p)
find_keys(d)
for k in ("compact_running","compact_queue_len","kv_sync_lat"):
    print(f"{k}={results.get(k,'NOT_FOUND')}")
PYEOF

cat > "$OUT/get_osd_value.py" << 'PYEOF'
import sys,json
d=json.load(sys.stdin)
path=sys.argv[1]
v=d
for k in path.split('.'):
    v=v[k]
print(v)
PYEOF

# ===== Helper functions =====
ssh_tikv() { local ip=$1; shift; "${SSH_BASE[@]}" "$ip" "$@" 2>/dev/null; }

pool_json() {
  sudo ceph df --format=json 2>/dev/null | python3 "$OUT/pool_parse.py" 2>/dev/null || echo "ERR ERR ERR"
}

stat_all_files() {
  { for stem in storage_test read_test rw_test; do
      for f in "$TEST_DIR/${stem}."*.0; do
        [[ -f "$f" ]] || continue
        echo -e "$f\t$(stat -c %i "$f")\t$(stat -c %s "$f")\t$(stat -c %Y "$f")"
      done
    done
  } | sort
}

drop_caches_4node() {
  local ok=0
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 && ok=$((ok+1))
  for ip in "${TIKV_IPS[@]}"; do
    "${SSH_BASE[@]}" "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null && ok=$((ok+1)) || { sleep 2; "${SSH_BASE[@]}" "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null && ok=$((ok+1)) || true; }
  done
  [[ $ok -eq 4 ]]
}

# OSD cooldown using recursively-found keys
OSD_KEYS_FOUND=""
find_osd_keys() {
  local dump
  dump=$(sudo ceph tell "osd.0" perf dump 2>/dev/null || echo "")
  [[ -n "$dump" ]] || return 1
  OSD_KEYS_FOUND=$(echo "$dump" | python3 "$OUT/find_osd_keys.py" 2>/dev/null || echo "")
  log "OSD keys: $OSD_KEYS_FOUND"
  echo "$OSD_KEYS_FOUND" | grep -q "NOT_FOUND" && return 1
  return 0
}

osd_cooldown_ok() {
  local cr_path cq_path ksl_path
  cr_path=$(echo "$OSD_KEYS_FOUND" | grep '^compact_running=' | cut -d= -f2)
  cq_path=$(echo "$OSD_KEYS_FOUND" | grep '^compact_queue_len=' | cut -d= -f2)
  ksl_path=$(echo "$OSD_KEYS_FOUND" | grep '^kv_sync_lat=' | cut -d= -f2)
  [[ -n "$cr_path" && -n "$cq_path" && -n "$ksl_path" ]] || return 1

  for osd in $(sudo ceph osd ls 2>/dev/null); do
    local dump
    dump=$(sudo ceph tell "osd.$osd" perf dump 2>/dev/null || echo "")
    [[ -n "$dump" ]] || return 1
    local cr cq ksl
    cr=$(echo "$dump" | python3 "$OUT/get_osd_value.py" "$cr_path" 2>/dev/null || echo 1)
    cq=$(echo "$dump" | python3 "$OUT/get_osd_value.py" "$cq_path" 2>/dev/null || echo 1)
    ksl=$(echo "$dump" | python3 "$OUT/get_osd_value.py" "$ksl_path" 2>/dev/null || echo 999)
    [[ "$cr" == "0" && "$cq" == "0" ]] || return 1
    echo "$ksl" | awk '{exit ($1 < 0.002) ? 0 : 1}' || return 1
  done
  return 0
}

compact_osd() {
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    sudo ceph tell "osd.$osd" compact 2>/dev/null || true
  done
  sleep 30
  # If keys not found, just return OK after fixed wait
  [[ -n "$OSD_KEYS_FOUND" ]] || { log "  OSD keys not found, fixed 30s wait"; return 0; }
  # Poll with real keys
  local tries=0
  while [[ $tries -lt 60 ]]; do
    osd_cooldown_ok && return 0
    sleep 5; tries=$((tries+1))
  done
  return 1
}

tikv_pending_ok() {
  for ip in "${TIKV_IPS[@]}"; do
    local val
    val=$(curl -s --connect-timeout 5 "http://${ip}:20180/metrics" 2>/dev/null | grep '^tikv_engine_pending_compaction_bytes' | grep -v '^#' | awk '{print $2}' | head -1)
    [[ -n "$val" && "$val" == "0" ]] || return 1
  done
  return 0
}

idle_gate() {
  local tries=0
  while [[ $tries -lt 30 ]]; do
    local foreign
    foreign=$(pgrep -af 'FULLBASELINE|fio.*storage_test|juicefs gc' 2>/dev/null | grep -v -E 'pgrep|grep|t59|samplers|nice -n 19|rados|curl|process_cpu|pool_parse' | head -1)
    [[ -z "$foreign" ]] || { log "  idle: foreign=$foreign"; sleep 10; tries=$((tries+1)); continue; }
    local health
    health=$(sudo ceph health 2>/dev/null || echo "ERR")
    [[ "$health" == "HEALTH_OK" ]] || { sleep 10; tries=$((tries+1)); continue; }
    local idle
    idle=$(top -b -n1 2>/dev/null | grep -oP '\d+\.\d id' | grep -oP '^\d+\.\d' || echo 0)
    echo "$idle" | awk '{exit ($1 >= 70) ? 0 : 1}' || { sleep 10; tries=$((tries+1)); continue; }
    echo "$(date +%s) idle_gate PASS" >> "$OUT/idle-gate.log"
    return 0
  done
  echo "$(date +%s) idle_gate FAIL" >> "$OUT/idle-gate.log"
  return 1
}

reset_to_gate() {
  local label=$1; local rdir="$OUT/reset/$label"; mkdir -p "$rdir"
  log "reset_to_gate: $label"
  sync -f "$MNT" 2>/dev/null || true
  log "  step2: OSD compact + cooldown"
  compact_osd || { log "STOP: OSD cooldown failed"; return 1; }
  sleep 30
  compact_osd || { log "STOP: OSD cooldown (2nd) failed"; return 1; }
  log "  step4: gc --compact"
  echo "$(date +%s) gc_start" > "$rdir/gc.log"
  "$BIN" gc --compact "$META" >> "$rdir/gc.log" 2>&1
  local gc_rc=$?
  echo "$(date +%s) gc_end rc=$gc_rc" >> "$rdir/gc.log"
  [[ $gc_rc -eq 0 ]] || { log "STOP: gc rc=$gc_rc"; return 1; }
  log "  step5: object convergence"
  local tries=0
  while [[ $tries -lt 40 ]]; do
    local s1 s2 s3 o1 o2 o3
    s1=$(pool_json); sleep 15; s2=$(pool_json); sleep 15; s3=$(pool_json)
    echo -e "$s1\n$s2\n$s3" > "$rdir/objects-try${tries}.tsv"
    o1=$(echo "$s1" | awk '{print $1}'); o2=$(echo "$s2" | awk '{print $1}'); o3=$(echo "$s3" | awk '{print $1}')
    if [[ "$o1" =~ ^[0-9]+$ && "$o1" -le $OBJ_SOFT ]]; then
      local d1=$(( ${o1/#/0} > ${o2/#/0} ? ${o1/#/0} - ${o2/#/0} : ${o2/#/0} - ${o1/#/0} ))
      local d2=$(( ${o2/#/0} > ${o3/#/0} ? ${o2/#/0} - ${o3/#/0} : ${o3/#/0} - ${o2/#/0} ))
      local md=$(( d1 > d2 ? d1 : d2 ))
      [[ $md -le 128 ]] && { log "  objects converged: $o1"; break; }
    fi
    tries=$((tries+1))
  done
  [[ $tries -lt 40 ]] || { log "STOP: object convergence failed"; return 1; }
  log "  step6: post-GC compact"
  compact_osd || { log "STOP: post-GC compact failed"; return 1; }
  log "  step7: TiKV pending check"
  local tk=0
  while [[ $tk -lt 60 ]]; do tikv_pending_ok && break; sleep 10; tk=$((tk+1)); done
  [[ $tk -lt 60 ]] || { log "STOP: TiKV pending != 0"; return 1; }
  log "  step8: stat all files"
  stat_all_files > "$rdir/file-stats.tsv"
  log "  step9: drop caches"
  drop_caches_4node || { log "STOP: drop_caches failed"; return 1; }
  echo "$(date +%s) drop_caches 4/4" > "$rdir/drop-caches.txt"
  log "  step10: 60s quiet"
  sleep 60
  log "  step11: idle gate"
  idle_gate || { log "STOP: idle gate failed"; return 1; }
  echo -e "$(date +%s)\t$label\tready" >> "$OUT/phase.tsv"
  log "reset_to_gate: $label OK"
  return 0
}

# ===== Device mapping =====
map_devices() {
  log "=== Device mapping ==="
  for ip in "${TIKV_IPS[@]}"; do
    local ddir="$OUT/device/$ip"
    mkdir -p "$ddir"
    # Get TiKV config via HTTP endpoint (fast, no SSH find)
    curl -s --connect-timeout 5 "http://${ip}:20180/config" 2>/dev/null > "$ddir/tikv-config.json" || true
    local kv_dir raft_dir wal_dir
    kv_dir=$(python3 -c "import json; d=json.load(open('$ddir/tikv-config.json')); print(d.get('storage',{}).get('data-dir',''))" 2>/dev/null || echo "")
    raft_dir=$(python3 -c "import json; d=json.load(open('$ddir/tikv-config.json')); print(d.get('raftdb',{}).get('path',''))" 2>/dev/null || echo "")
    wal_dir="$kv_dir"  # default: WAL in same dir
    # Also try cmdline
    local tikv_pid
    tikv_pid=$(ssh_tikv "$ip" 'pgrep tikv-server | head -1' 2>/dev/null || echo "")
    [[ -n "$tikv_pid" ]] || { log "STOP: no tikv-server on $ip"; return 1; }
    local cmdline
    cmdline=$(ssh_tikv "$ip" "cat /proc/$tikv_pid/cmdline 2>/dev/null | tr '\0' ' '" || echo "")
    echo "$cmdline" > "$ddir/cmdline.txt"
    [[ -z "$kv_dir" ]] && kv_dir=$(echo "$cmdline" | grep -oP '\--data-dir\s+\K\S+' | head -1)
    [[ -z "$kv_dir" ]] && kv_dir="/mnt/jfs-tikv"  # fallback
    log "  $ip: kv_dir=$kv_dir raft_dir=$raft_dir wal_dir=$wal_dir pid=$tikv_pid"
    for role in kv raft wal; do
      local path=""
      case $role in
        kv) path="$kv_dir" ;;
        raft) path="${raft_dir:-$kv_dir/raft}" ;;
        wal) path="$wal_dir" ;;
      esac
      [[ -z "$path" ]] && continue
      ssh_tikv "$ip" "findmnt -T '$path' -o TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN 2>/dev/null" > "$ddir/findmnt-${role}.txt" || true
      ssh_tikv "$ip" "df -T '$path' 2>/dev/null" > "$ddir/df-${role}.txt" || true
      ssh_tikv "$ip" 'lsblk -e7 -o NAME,KNAME,PKNAME,TYPE,MAJ:MIN,SIZE,ROTA,MOUNTPOINTS,FSTYPE 2>/dev/null' > "$ddir/lsblk.txt" || true
      ssh_tikv "$ip" "readlink -f '$path' 2>/dev/null" > "$ddir/readlink-${role}.txt" || true
      local mount_src
      mount_src=$(awk 'NR==2{print $2}' "$ddir/findmnt-${role}.txt" 2>/dev/null || echo "")
      echo -e "$ip\t$role\t$path\t$mount_src" >> "$OUT/device/device-map.tsv"
      if [[ -n "$mount_src" ]]; then
        local dev_name
        dev_name=$(echo "$mount_src" | sed 's/[0-9]*$//' | sed 's|/dev/||')
        [[ -n "$dev_name" ]] && ssh_tikv "$ip" "cat /sys/block/$dev_name/queue/scheduler /sys/block/$dev_name/queue/nr_requests /sys/block/$dev_name/queue/rotational 2>/dev/null" > "$ddir/sysfs-$dev_name.txt" || true
      fi
    done
  done
  log "Device mapping done: $(wc -l < "$OUT/device/device-map.tsv" 2>/dev/null || echo 0) entries"
}

# ===== Sampler system =====
SAMPLER_PIDS=""
start_sampler() {
  local name=$1; shift
  local cmd=$1; shift
  local pid_file="$OUT/samplers/${name}.pid"
  local hb_file="$OUT/samplers/${name}.heartbeat"
  nice -n 19 bash -c "$cmd" 2>"$OUT/samplers/${name}.errors" &
  local pid=$!
  echo $pid > "$pid_file"
  echo "$(date +%s) started" > "$hb_file"
  SAMPLER_PIDS="$SAMPLER_PIDS $pid"
  log "  Sampler $name started (pid=$pid)"
}

start_all_samplers() {
  log "=== Starting samplers ==="

  # Client runtime (1s from /metrics)
  start_sampler client-runtime '
    OUT="'"$OUT"'"; KEYS="'"$CLIENT_KEYS"'"
    while true; do
      ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/client-runtime.heartbeat"
      curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$KEYS" | while IFS= read -r line; do
        printf "%s\t%s\n" "$ts" "$line" >> "'"$OUT"'/samplers/client-runtime.tsv"
      done
      sleep 1
    done
  '

  # Client host (1s)
  start_sampler client-host '
    OUT="'"$OUT"'"
    while true; do
      ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/client-host.heartbeat"
      cpu=$(head -1 /proc/stat 2>/dev/null)
      mem=$(awk "/MemAvailable/{print \$2}" /proc/meminfo 2>/dev/null)
      printf "%s\t%s\tmem=%s\n" "$ts" "$cpu" "$mem" >> "'"$OUT"'/samplers/client-host.tsv"
      sleep 1
    done
  '

  # TiKV metrics (5s, sequential)
  start_sampler tikv-metrics '
    OUT="'"$OUT"'"; RE="'"$TIKV_RE"'"
    EPS=(10.20.1.150:20180/metrics 10.20.1.151:20180/metrics 10.20.1.152:20180/metrics)
    while true; do
      ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/tikv-metrics.heartbeat"
      for ep in "${EPS[@]}"; do
        host=${ep%%:*}
        curl -s --connect-timeout 5 "http://${host}:20180/metrics" 2>/dev/null | grep -E "$RE" | while IFS= read -r line; do
          printf "%s\t%s\t%s\n" "$ts" "$host" "$line" >> "'"$OUT"'/samplers/tikv-metrics.tsv"
        done
      done
      sleep 5
    done
  '

  # TiKV device iostat (1s per node)
  for ip in "${TIKV_IPS[@]}"; do
    start_sampler "tikv-device-$ip" '
      OUT="'"$OUT"'"; IP="'"$ip"'"
      SSH_ARR=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
      while true; do
        ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/tikv-device-'"$ip"'.heartbeat"
        iostat=$("${SSH_ARR[@]}" "$IP" "iostat -y -x -d 1 1 2>/dev/null | tail -n +3" 2>/dev/null || echo "ERR")
        printf "%s\t%s\n" "$ts" "$iostat" >> "'"$OUT"'/samplers/tikv-device-'"$ip"'.raw"
        # Parse to TSV
        echo "$iostat" | grep -v "^$" | while IFS= read -r line; do
          printf "%s\t%s\t%s\n" "$ts" "'"$ip"'" "$line" >> "'"$OUT"'/samplers/tikv-device-'"$ip"'.tsv"
        done
        sleep 1
      done
    '
  done

  # TiKV host (1s per node: /proc/stat, pressure, pid stat/io)
  for ip in "${TIKV_IPS[@]}"; do
    start_sampler "tikv-host-$ip" '
      OUT="'"$OUT"'"; IP="'"$ip"'"
      SSH_ARR=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
      while true; do
        ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/tikv-host-'"$ip"'.heartbeat"
        stat=$("${SSH_ARR[@]}" "$IP" "head -1 /proc/stat; cat /proc/pressure/io 2>/dev/null || echo NA; cat /proc/pressure/cpu 2>/dev/null || echo NA" 2>/dev/null || echo "ERR")
        pid_stat=$("${SSH_ARR[@]}" "$IP" "PID=\$(pgrep tikv-server | head -1); cat /proc/\$PID/stat 2>/dev/null; cat /proc/\$PID/io 2>/dev/null" 2>/dev/null || echo "ERR")
        printf "%s\t%s\t%s\t%s\n" "$ts" "'"$ip"'" "$stat" "$pid_stat" >> "'"$OUT"'/samplers/tikv-host-'"$ip"'.tsv"
        sleep 1
      done
    '
  done

  # Ceph (30s)
  start_sampler ceph '
    OUT="'"$OUT"'"
    while true; do
      ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/ceph.heartbeat"
      health=$(sudo ceph health 2>/dev/null || echo "ERR")
      pg=$(sudo ceph pg stat 2>/dev/null | head -1 || echo "NA")
      printf "%s\t%s\t%s\n" "$ts" "$health" "$pg" >> "'"$OUT"'/samplers/ceph.tsv"
      sleep 30
    done
  '

  # Pool watchdog (15s, JSON)
  start_sampler pool '
    OUT="'"$OUT"'"; OBJ_HARD='"$OBJ_HARD"'
    while true; do
      ts=$(date +%s); echo "$ts" >> "'"$OUT"'/samplers/pool.heartbeat"
      line=$(sudo ceph df --format=json 2>/dev/null | python3 '"$OUT"'/pool_parse.py 2>/dev/null || echo "ERR ERR ERR")
      objs=$(echo "$line" | awk "{print \$1}")
      printf "%s\t%s\n" "$ts" "$line" >> "'"$OUT"'/samplers/pool.tsv"
      if [[ "$objs" =~ ^[0-9]+$ && "$objs" -gt $OBJ_HARD ]]; then
        echo "[WD] objects=$objs > $OBJ_HARD" >> "'"$OUT"'/STOP.txt"
        pkill -INT -f "fio.*B0" 2>/dev/null || true
      fi
      sleep 15
    done
  '

  sleep 2
  log "All samplers started"
}

check_samplers_alive() {
  for pid_file in "$OUT"/samplers/*.pid; do
    [[ -f "$pid_file" ]] || continue
    local name=$(basename "$pid_file" .pid)
    local pid=$(cat "$pid_file" 2>/dev/null)
    if ! kill -0 "$pid" 2>/dev/null; then
      log "SAMPLER DEAD: $name (pid=$pid)"
      return 1
    fi
    # Check heartbeat with per-sampler threshold
    local hb_file="$OUT/samplers/${name}.heartbeat"
    if [[ -f "$hb_file" ]]; then
      local last_ts now gap
      last_ts=$(tail -1 "$hb_file" 2>/dev/null)
      now=$(date +%s)
      if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
        gap=$((now - last_ts))
        # Threshold: 30s samplers→40s, 15s→25s, 5s→10s, 1s→5s
        local thresh=5
        case "$name" in
          ceph) thresh=40 ;;
          pool) thresh=25 ;;
          tikv-metrics|tikv-device-*|tikv-host-*) thresh=10 ;;
        esac
        if [[ $gap -gt $thresh ]]; then
          log "SAMPLER HEARTBEAT STALE: $name gap=${gap}s thresh=${thresh}s"
          return 1
        fi
      fi
    fi
  done
  return 0
}

validate_samplers_120s() {
  log "=== 120s sampler pre-validation ==="
  local start=$(date +%s)
  while [[ $(($(date +%s) - start)) -lt 120 ]]; do
    check_samplers_alive || { log "STOP: sampler died during validation"; return 1; }
    sleep 5
  done
  # Check sample counts
  local ok=1
  for f in client-runtime client-host tikv-metrics; do
    local n=$(wc -l < "$OUT/samplers/${f}.tsv" 2>/dev/null || echo 0)
    [[ $n -ge 50 ]] || { log "  $f: only $n samples (need >=50)"; ok=0; }
  done
  for ip in "${TIKV_IPS[@]}"; do
    for f in "tikv-device-$ip" "tikv-host-$ip"; do
      local n=$(wc -l < "$OUT/samplers/${f}.tsv" 2>/dev/null || echo 0)
      [[ $n -ge 50 ]] || { log "  $f: only $n samples (need >=50)"; ok=0; }
    done
  done
  local pool_n=$(wc -l < "$OUT/samplers/pool.tsv" 2>/dev/null || echo 0)
  [[ $pool_n -ge 5 ]] || { log "  pool: only $pool_n samples (need >=5)"; ok=0; }
  local ceph_n=$(wc -l < "$OUT/samplers/ceph.tsv" 2>/dev/null || echo 0)
  [[ $ceph_n -ge 3 ]] || { log "  ceph: only $ceph_n samples (need >=3)"; ok=0; }

  [[ $ok -eq 1 ]] || { log "STOP: sampler validation failed"; return 1; }
  log "  120s validation passed"
  return 0
}

stop_samplers() {
  for pid_file in "$OUT"/samplers/*.pid; do
    [[ -f "$pid_file" ]] || continue
    local pid=$(cat "$pid_file" 2>/dev/null)
    kill "$pid" 2>/dev/null || true
  done
  sleep 2
}

# ===== Phase 1: Preflight =====
log "=== T59 03-20B start run_id=$RUN_ID ==="

hostname > "$OUT/fingerprint/hostname.txt"
date '+%Y-%m-%d %H:%M:%S %z' > "$OUT/fingerprint/datetime.txt"
fio --version > "$OUT/fingerprint/fio-version.txt" 2>&1

[[ "$(md5sum "$BIN" | awk '{print $1}')" == "$BIN_MD5" ]] || { log "STOP: binary md5 mismatch"; exit 5; }
sys_md5=$(md5sum "$SYS_CONF" | awk '{print $1}')
[[ "$sys_md5" == "$SYS_CONF_MD5" ]] || { log "STOP: system conf md5 mismatch"; exit 5; }
cp "$SYS_CONF" "$OUT/fingerprint/ceph.conf.system"

health=$(sudo ceph health 2>/dev/null || echo "ERR")
[[ "$health" == "HEALTH_OK" ]] || { log "STOP: ceph health=$health"; exit 5; }

osd_up=$(sudo ceph osd stat 2>/dev/null | grep -oP '\d+(?= up)' | head -1)
osd_up=${osd_up:-0}
[[ "$osd_up" -ge 6 ]] || { log "STOP: OSD up=$osd_up"; exit 5; }

sudo ceph osd dump 2>/dev/null | grep 'up_from' | head -1 > "$OUT/fingerprint/up_from-pre.txt" || true

avail_k=$(df -Pk / | awk 'NR==2{print $4}')
[[ "$avail_k" -ge 8388608 ]] || { log "STOP: root < 8GiB"; exit 5; }

# Graceful unmount if needed
if mountpoint -q "$MNT"; then
  sync; umount "$MNT" 2>/dev/null || {
    mpid=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
    if [[ -n "$mpid" ]]; then kill "$mpid" 2>/dev/null; sleep 5; kill -9 "$mpid" 2>/dev/null; sleep 2; fi
    umount "$MNT" 2>/dev/null || true
  }
  sleep 2; mountpoint -q "$MNT" && { log "STOP: cannot clean mount"; exit 6; }
fi

# Mount
"$BIN" mount -d $MOUNT_OPTS "$META" "$MNT" >> "$OUT/mount.log" 2>&1
sleep 10
mountpoint -q "$MNT" || { log "STOP: mount failed"; exit 6; }

PID=$(pgrep -f "juicefs-03-8.*juicefs-prod" | head -1)
[[ "$PID" =~ ^[0-9]+$ ]] || { log "STOP: no pid"; exit 6; }
PSTART=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null || echo 0)

exe_md5=$(md5sum "/proc/$PID/exe" | awk '{print $1}')
[[ "$exe_md5" == "$BIN_MD5" ]] || { log "STOP: exe md5 mismatch"; exit 6; }
grep -q 'max_read=262144' /proc/mounts || { log "STOP: max_read"; exit 6; }
proc_conf=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | awk -F= '$1=="CEPH_CONF"{print $2}')
msgr_ok=$(grep -c 'ms_async_op_threads = 8' "$proc_conf" 2>/dev/null || echo 0)
[[ "$msgr_ok" -eq 1 ]] || { log "STOP: msgr!=8"; exit 6; }

for stem in storage_test read_test rw_test; do
  cnt=$(find "$TEST_DIR" -maxdepth 1 -type f -name "${stem}.*.0" 2>/dev/null | wc -l)
  [[ "$cnt" -eq 128 ]] || { log "STOP: ${stem}=$cnt"; exit 6; }
done
stat_all_files > "$OUT/files/pre.tsv"

{
  echo "pid=$PID starttime_ticks=$PSTART"
  echo "exe=$(readlink -f /proc/$PID/exe)"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
  echo "proc_ceph_conf=$proc_conf"
  echo "ms_async_op_threads_8=$msgr_ok"
} > "$OUT/fingerprint/pre.txt"
log "Mount OK pid=$PID"

# Jobfile
if [[ -f "$SCRIPT_DIR/t56-gen-jobfiles.sh" ]]; then
  bash "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$OUT/jobfiles" > "$OUT/jobfiles-gen.log" 2>&1
  bash "$SCRIPT_DIR/t56-validate-jobfiles.sh" "$OUT/jobfiles" > "$OUT/jobfiles-validate.log" 2>&1
elif [[ -f /tmp/t56-gen-jobfiles.sh ]]; then
  bash /tmp/t56-gen-jobfiles.sh "$OUT/jobfiles" > "$OUT/jobfiles-gen.log" 2>&1
  bash /tmp/t56-validate-jobfiles.sh "$OUT/jobfiles" > "$OUT/jobfiles-validate.log" 2>&1
fi
[[ $? -eq 0 ]] || { log "STOP: jobfile validation failed"; exit 5; }
cp "$OUT/jobfiles/B0.fio" "$OUT/arm/B0.fio"
md5sum "$OUT/jobfiles/B0.fio" > "$OUT/arm/jobfile.md5"
b0_md5=$(awk '{print $1}' "$OUT/arm/jobfile.md5")
[[ "$b0_md5" == "3b43b01ed2c4033ed42ad52bddc77c2f" ]] || { log "STOP: B0 md5 mismatch: $b0_md5"; exit 5; }
log "Jobfile B0 validated (md5=$b0_md5)"

# Device mapping
map_devices || { log "STOP: device mapping failed"; exit 6; }

# OSD key precheck
log "=== OSD key precheck ==="
find_osd_keys || log "WARN: OSD keys not found, will use fixed wait"

# Metric exposition precheck
log "=== Metric exposition precheck ==="
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" | head -5 > "$OUT/preflight/metric-proof-${ip}.txt" || true
  local_n=$(wc -l < "$OUT/preflight/metric-proof-${ip}.txt")
  [[ $local_n -gt 0 ]] || { log "STOP: no TiKV metrics on $ip"; exit 6; }
done
log "  TiKV metrics exposition OK"

# Full metrics snapshot (pre)
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | gzip > "$OUT/metrics-full/tikv-${ip}-pre.prom.gz"
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -v '^#' | awk '{print $1}' | sort -u > "$OUT/metrics-full/tikv-${ip}-pre.names.txt"
done
log "Full metrics snapshot (pre) done"

# ===== Phase 2: Samplers =====
start_all_samplers

# 120s validation
validate_samplers_120s || { log "STOP: sampler validation failed"; stop_samplers; exit 7; }

# ===== Phase 3: Pre-load reset =====
reset_to_gate "preload" || { log "STOP: preload reset failed"; stop_samplers; exit 7; }

# ===== Phase 4: Run arm D-B256 =====
log "=== ARM D-B256 ==="

# PRE snapshot
curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$CLIENT_KEYS" > "$OUT/arm/pre.tsv"
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" > "$OUT/arm/tikv-pre-${ip}.tsv"
done
stat_all_files > "$OUT/files/pre-arm.tsv"
echo -e "$(date +%s)\tD-B256\tpre" >> "$OUT/phase.tsv"

setsid fio "$OUT/arm/B0.fio" --write_bw_log="$OUT/arm/bw/D-B256" > "$OUT/arm/fio.stdout" 2> "$OUT/arm/fio.stderr" &
FIO_PID=$!
echo $FIO_PID > "$OUT/arm/fio.pid"
echo -e "$(date +%s)\tD-B256\tfio_start pid=$FIO_PID" >> "$OUT/phase.tsv"
log "Starting fio D-B256 (pid=$FIO_PID)"

# Main watchdog (2s interval)
while kill -0 $FIO_PID 2>/dev/null; do
  sleep 2
  [[ -f "$OUT/STOP.txt" ]] && { log "STOP: watchdog triggered"; kill -INT -$FIO_PID 2>/dev/null || true; break; }
  mountpoint -q "$MNT" || { log "STOP: mount lost"; break; }
  check_samplers_alive || { log "STOP: sampler died during fio"; kill -INT -$FIO_PID 2>/dev/null || true; break; }
done

wait $FIO_PID 2>/dev/null || true
FIO_RC=$?
echo $FIO_RC > "$OUT/arm/fio.rc"
echo -e "$(date +%s)\tD-B256\tfio_end rc=$FIO_RC" >> "$OUT/phase.tsv"

# POST snapshot
curl -s http://127.0.0.1:9567/metrics 2>/dev/null | grep -E "$CLIENT_KEYS" > "$OUT/arm/post.tsv"
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | grep -E "$TIKV_RE" > "$OUT/arm/tikv-post-${ip}.tsv"
done
stat_all_files > "$OUT/files/post.tsv"
for ip in "${TIKV_IPS[@]}"; do
  curl -s "http://${ip}:20180/metrics" 2>/dev/null | gzip > "$OUT/metrics-full/tikv-${ip}-post.prom.gz"
done

bw_logs=$(find "$OUT/arm/bw" -name "*_bw.*.log" -type f | wc -l)
bw=$(grep -oP 'WRITE: bw=\K[0-9]+MiB' "$OUT/arm/fio.stdout" 2>/dev/null | head -1)
log "ARM D-B256: rc=$FIO_RC bw_logs=$bw_logs BW=$bw"

# ===== Phase 5: Final reset =====
reset_to_gate "final" || { log "WARN: final reset failed"; }

# ===== Phase 6: Cleanup =====
log "=== Cleanup ==="
stop_samplers

# Post fingerprint
{
  echo "pid=$PID starttime_ticks=$PSTART"
  md5sum "/proc/$PID/exe"
  grep " $MNT " /proc/mounts
} > "$OUT/fingerprint/post.txt"
md5sum "$SYS_CONF" >> "$OUT/fingerprint/post.txt"
sudo ceph osd dump 2>/dev/null | grep 'up_from' | head -1 > "$OUT/fingerprint/up_from-post.txt" || true

# Graceful unmount
sync; umount "$MNT" 2>/dev/null || fusermount -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || {
  log "WARN: graceful umount failed, keeping mount"
}

# Archive
( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )
ARCHIVE="$ARCHIVE_DIR/opencode-t3.20b-${RUN_ID}.tar.gz"
tar -C /tmp -czf "$ARCHIVE" "$(basename "$OUT")"
md5sum "$ARCHIVE" > "${ARCHIVE}.md5"

log "=== T59 DONE ==="
log "OUT=$OUT"
log "ARCHIVE=$ARCHIVE"
log "BW=$bw bw_logs=$bw_logs rc=$FIO_RC"
