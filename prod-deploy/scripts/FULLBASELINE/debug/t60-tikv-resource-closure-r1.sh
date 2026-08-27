#!/usr/bin/env bash
# T60: TiKV resource closure evidence repair (03-20B-R1)
# --self-test | --dry-run RUN_ID | RUN_ID
set -euo pipefail

RUN_ID=""
MODE="run"
if [[ "${1:-}" == "--self-test" ]]; then MODE="selftest"
elif [[ "${1:-}" == "--dry-run" ]]; then MODE="dryrun"; RUN_ID="${2:-TEST}"
else RUN_ID="${1:-$(date +%Y%m%d-%H%M%S)}"; fi

# Config
BIN=/tmp/juicefs-03-8
BIN_MD5=de93563f11a5ff3bd94dd25a4e0283b1
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'
MNT=/mnt/juicefs
TEST_DIR=/mnt/juicefs/test_dir
MOUNT_OPTS='--max-uploads 150 --cache-size 0 --max-fuse-io 256K'
SYS_CONF=/etc/ceph/ceph.conf
SYS_CONF_MD5=5b6be34179a64e0a5f9c6d3a9690041f
TIKV_IPS=(10.20.1.150 10.20.1.151 10.20.1.152)
SSH_BASE=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
SCP_BASE=(sshpass -p Sunrise@801 scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
OBJ_SOFT=2500000; OBJ_HARD=8000000
OUT="/tmp/opencode-t3.20b-r1-${RUN_ID}"
ARCHIVE_DIR=/tmp/production
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TIKV_RE='tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_storage_command_total|tikv_engine_cache_efficiency|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_scheduler_(flush|l0|throttle|write)_flow|tikv_scheduler_pending_compaction_bytes|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_secs_(sum|count)|tikv_engine_pending_compaction_bytes|tikv_engine_compaction_duration_seconds_(sum|count)|tikv_engine_compaction_flow_bytes|tikv_engine_num_files_at_level|tikv_engine_num_subcompaction_scheduled|tikv_engine_stall_micro_seconds|tikv_engine_write_stall|tikv_engine_write_stall_reason|tikv_engine_wal_file_sync_micro_seconds|tikv_engine_wal_file_synced|tikv_rate_limiter_max_bytes_per_sec|tikv_thread_cpu_seconds_total|tikv_threads_io_bytes_total|tikv_threads_state|process_cpu_seconds_total'

CLIENT_KEYS='juicefs_meta_ops_duration_seconds_Write|juicefs_meta_ops_total_Write|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_transaction_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_staging_blocks'

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; echo "$msg" >> "$OUT/wrapper.log" 2>/dev/null; echo "$msg"; }

# Self-test
if [[ "$MODE" == "selftest" ]]; then
  echo "=== T60 Self-test ==="
  for cmd in bash fio curl python3 awk md5sum stat findmnt lsblk ceph fusermount; do
    command -v "$cmd" >/dev/null 2>&1 && echo "  $cmd: OK" || echo "  $cmd: MISSING"
  done
  for ip in "${TIKV_IPS[@]}"; do
    timeout 5 "${SSH_BASE[@]}" "$ip" 'echo ok' 2>/dev/null && echo "  SSH $ip: OK" || echo "  SSH $ip: FAIL"
    curl -s --connect-timeout 3 "http://${ip}:20180/metrics" 2>/dev/null | grep -c 'tikv_engine' | head -1 | xargs -I{} echo "  metrics $ip: {} lines"
  done
  echo "=== Self-test done ==="; exit 0
fi

if [[ "$MODE" == "dryrun" ]]; then
  echo "=== T60 Dry-run RUN_ID=$RUN_ID ==="
  echo "OUT=$OUT"; echo "BIN=$BIN ($BIN_MD5)"; echo "B0.fio md5=3b43b01ed2c4033ed42ad52bddc77c2f"
  echo "=== Dry-run done ==="; exit 0
fi

# === Normal execution ===
mkdir -p "$OUT" "$OUT/samplers" "$OUT/reset" "$OUT/arm/bw" "$OUT/files" "$OUT/fingerprint" "$OUT/jobfiles" "$OUT/metrics-full" "$OUT/preflight" "$OUT/device" "$OUT/provenance"

# Provenance
cp "$0" "$OUT/provenance/t60-tikv-resource-closure-r1.sh" 2>/dev/null || true
for f in t60-remote-host-sampler.sh t60-validate-coverage.py t56-gen-jobfiles.sh t56-validate-jobfiles.sh; do
  [[ -f "$SCRIPT_DIR/$f" ]] && cp "$SCRIPT_DIR/$f" "$OUT/provenance/" || [[ -f "/tmp/$f" ]] && cp "/tmp/$f" "$OUT/provenance/" || true
done
md5sum "$OUT/provenance/"* > "$OUT/provenance/MD5SUMS" 2>/dev/null || true

# Pool parser
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
            if k in ("compact_running","compact_queue_len"): results[k] = p
            if k == "kv_sync_lat" and isinstance(v, dict) and "avgtime" in v: results["kv_sync_lat"] = p + ".avgtime"
            find_keys(v, p)
find_keys(d)
for k in ("compact_running","compact_queue_len","kv_sync_lat"):
    print(f"{k}={results.get(k,'NOT_FOUND')}")
PYEOF
cat > "$OUT/get_osd_value.py" << 'PYEOF'
import sys,json
d=json.load(sys.stdin)
v=d
for k in sys.argv[1].split('.'): v=v[k]
print(v)
PYEOF

# EXIT trap
cleanup_on_exit() {
  local rc=$?
  log "EXIT trap: rc=$rc, stopping samplers"
  for pf in "$OUT"/samplers/*.pid; do
    [[ -f "$pf" ]] || continue
    kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null || true
  done
  # Kill remote SSH processes
  for pf in "$OUT"/samplers/*.sshpid; do
    [[ -f "$pf" ]] || continue
    kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null || true
  done
  # Archive if not already done
  if [[ -d "$OUT" && ! -f "$ARCHIVE_DIR/opencode-t3.20b-r1-${RUN_ID}.tar.gz" ]]; then
    ( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 2>/dev/null | sort -z | xargs -0 md5sum > MANIFEST.md5 2>/dev/null ) || true
    tar -C /tmp -czf "$ARCHIVE_DIR/opencode-t3.20b-r1-${RUN_ID}-ABORT.tar.gz" "$(basename "$OUT")" 2>/dev/null || true
    md5sum "$ARCHIVE_DIR/opencode-t3.20b-r1-${RUN_ID}-ABORT.tar.gz" > "${ARCHIVE_DIR}/opencode-t3.20b-r1-${RUN_ID}-ABORT.tar.gz.md5" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

# Private CEPH_CONF
cp "$SYS_CONF" "/tmp/t60-msgr8-${RUN_ID}.conf"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "/tmp/t60-msgr8-${RUN_ID}.conf"
export CEPH_CONF="/tmp/t60-msgr8-${RUN_ID}.conf"

# Helpers
ssh_tikv() { local ip=$1; shift; "${SSH_BASE[@]}" "$ip" "$@" 2>/dev/null; }
pool_json() { sudo ceph df --format=json 2>/dev/null | python3 "$OUT/pool_parse.py" 2>/dev/null || echo "ERR ERR ERR"; }
stat_all_files() { { for s in storage_test read_test rw_test; do for f in "$TEST_DIR/${s}."*.0; do [[ -f "$f" ]] || continue; echo -e "$f\t$(stat -c %i "$f")\t$(stat -c %s "$f")\t$(stat -c %Y "$f")"; done; done; } | sort; }
drop_caches_4node() { local ok=0; echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null 2>&1 && ok=$((ok+1)); for ip in "${TIKV_IPS[@]}"; do "${SSH_BASE[@]}" "$ip" 'sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null' 2>/dev/null && ok=$((ok+1)) || { sleep 2; "${SSH_BASE[@]}" "$ip" 'sync;echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null' 2>/dev/null && ok=$((ok+1)); }; done; [[ $ok -eq 4 ]]; }

OSD_KEYS=""
find_osd_keys() {
  local d; d=$(sudo ceph tell "osd.0" perf dump 2>/dev/null || echo "")
  [[ -n "$d" ]] || return 1
  OSD_KEYS=$(echo "$d" | python3 "$OUT/find_osd_keys.py" 2>/dev/null || echo "")
  log "OSD keys: $OSD_KEYS"
  echo "$OSD_KEYS" | grep -q "NOT_FOUND" && return 1; return 0
}
osd_cooldown_ok() {
  local cr_p=$(echo "$OSD_KEYS"|grep '^compact_running='|cut -d= -f2)
  local cq_p=$(echo "$OSD_KEYS"|grep '^compact_queue_len='|cut -d= -f2)
  local ksl_p=$(echo "$OSD_KEYS"|grep '^kv_sync_lat='|cut -d= -f2)
  [[ -n "$cr_p"&&-n "$cq_p"&&-n "$ksl_p" ]] || return 1
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    local d; d=$(sudo ceph tell "osd.$osd" perf dump 2>/dev/null || echo "")
    [[ -n "$d" ]] || return 1
    local cr=$(echo "$d"|python3 "$OUT/get_osd_value.py" "$cr_p" 2>/dev/null||echo 1)
    local cq=$(echo "$d"|python3 "$OUT/get_osd_value.py" "$cq_p" 2>/dev/null||echo 1)
    local ksl=$(echo "$d"|python3 "$OUT/get_osd_value.py" "$ksl_p" 2>/dev/null||echo 999)
    [[ "$cr"=="0"&&"$cq"=="0" ]] || return 1
    echo "$ksl"|awk '{exit ($1<0.002)?0:1}' || return 1
  done; return 0
}
compact_osd() {
  for osd in $(sudo ceph osd ls 2>/dev/null); do sudo ceph tell "osd.$osd" compact 2>/dev/null||true; done
  sleep 30
  [[ -n "$OSD_KEYS" ]] || return 0
  local t=0; while [[ $t -lt 60 ]]; do osd_cooldown_ok && return 0; sleep 5; t=$((t+1)); done; return 1
}
tikv_pending_ok() { for ip in "${TIKV_IPS[@]}"; do local v; v=$(curl -s --connect-timeout 5 "http://${ip}:20180/metrics" 2>/dev/null|grep '^tikv_engine_pending_compaction_bytes'|grep -v '^#'|awk '{print $2}'|head -1); [[ -n "$v"&&"$v"=="0" ]] || return 1; done; return 0; }
idle_gate() { local t=0; while [[ $t -lt 30 ]]; do local f; f=$(pgrep -af 'FULLBASELINE|fio.*storage_test|juicefs gc' 2>/dev/null|grep -v -E 'pgrep|grep|t60|samplers|nice|rados|curl|pool_parse|process_cpu'|head -1); [[ -z "$f" ]] || { log " idle: foreign=$f"; sleep 10; t=$((t+1)); continue; }; local h; h=$(sudo ceph health 2>/dev/null||echo "ERR"); [[ "$h"=="HEALTH_OK" ]] || { sleep 10; t=$((t+1)); continue; }; local i; i=$(top -b -n1 2>/dev/null|grep -oP '\d+\.\d id'|grep -oP '^\d+\.\d'||echo 0); echo "$i"|awk '{exit ($1>=70)?0:1}' || { sleep 10; t=$((t+1)); continue; }; echo "$(date +%s) PASS">>"$OUT/idle-gate.log"; return 0; done; echo "$(date +%s) FAIL">>"$OUT/idle-gate.log"; return 1; }

reset_to_gate() {
  local label=$1
  local rdir="$OUT/reset/$label"; mkdir -p "$rdir"; log "reset_to_gate: $label"
  sync -f "$MNT" 2>/dev/null||true
  log "  step2: OSD compact"; compact_osd||{ log "STOP: OSD cooldown"; return 1; }
  sleep 30; compact_osd||{ log "STOP: OSD cooldown 2nd"; return 1; }
  log "  step4: gc"; echo "$(date +%s) gc_start">"$rdir/gc.log"; "$BIN" gc --compact "$META">>"$rdir/gc.log" 2>&1; local rc=$?; echo "$(date +%s) gc_end rc=$rc">>"$rdir/gc.log"; [[ $rc -eq 0 ]]||{ log "STOP: gc rc=$rc"; return 1; }
  log "  step5: objects"; local t=0; while [[ $t -lt 40 ]]; do local s1 s2 s3 o1 o2 o3; s1=$(pool_json); sleep 15; s2=$(pool_json); sleep 15; s3=$(pool_json); echo -e "$s1\n$s2\n$s3">"$rdir/obj-try${t}.tsv"; o1=$(echo "$s1"|awk '{print $1}'); o2=$(echo "$s2"|awk '{print $1}'); o3=$(echo "$s3"|awk '{print $1}'); if [[ "$o1" =~ ^[0-9]+$&&"$o1" -le $OBJ_SOFT ]]; then local d1=$(( ${o1/#/0}>${o2/#/0}?${o1/#/0}-${o2/#/0}:${o2/#/0}-${o1/#/0} )); local d2=$(( ${o2/#/0}>${o3/#/0}?${o2/#/0}-${o3/#/0}:${o3/#/0}-${o2/#/0} )); local md=$(( d1>d2?d1:d2 )); [[ $md -le 128 ]]&&{ log "  converged: $o1"; break; }; fi; t=$((t+1)); done; [[ $t -lt 40 ]]||{ log "STOP: obj convergence"; return 1; }
  log "  step6: post-GC compact"; compact_osd||{ log "STOP: post-GC"; return 1; }
  log "  step7: TiKV pending"; local tk=0; while [[ $tk -lt 60 ]]; do tikv_pending_ok&&break; sleep 10; tk=$((tk+1)); done; [[ $tk -lt 60 ]]||{ log "STOP: TiKV pending"; return 1; }
  log "  step8: stat files"; stat_all_files>"$rdir/file-stats.tsv"
  log "  step9: drop caches"; drop_caches_4node||{ log "STOP: drop_caches"; return 1; }
  log "  step10: 60s quiet"; sleep 60
  log "  step11: idle gate"; idle_gate||{ log "STOP: idle"; return 1; }
  echo -e "$(date +%s)\t$label\tready">>"$OUT/phase.tsv"; log "reset_to_gate: $label OK"; return 0
}

# Device mapping
map_devices() {
  log "=== Device mapping ==="
  for ip in "${TIKV_IPS[@]}"; do
    local dd="$OUT/device/$ip"; mkdir -p "$dd"
    curl -s --connect-timeout 5 "http://${ip}:20180/config" 2>/dev/null>"$dd/tikv-config.json"||true
    local kv raft wal
    kv=$(python3 -c "import json;d=json.load(open('$dd/tikv-config.json'));print(d.get('storage',{}).get('data-dir',''))" 2>/dev/null||echo "")
    raft=$(python3 -c "import json;d=json.load(open('$dd/tikv-config.json'));print(d.get('raftdb',{}).get('path',''))" 2>/dev/null||echo "")
    wal="$kv"
    local pid; pid=$(ssh_tikv "$ip" 'pgrep tikv-server|head -1' 2>/dev/null||echo "")
    [[ -n "$pid" ]]||{ log "STOP: no tikv on $ip"; return 1; }
    local cmd; cmd=$(ssh_tikv "$ip" "cat /proc/$pid/cmdline 2>/dev/null|tr '\0' ' '"||echo ""); echo "$cmd">"$dd/cmdline.txt"
    [[ -z "$kv" ]]&&kv=$(echo "$cmd"|grep -oP '\--data-dir\s+\K\S+'|head -1)
    [[ -z "$kv" ]]&&kv="/mnt/jfs-tikv"
    [[ -z "$raft" ]]&&raft="$kv/raft"
    log "  $ip: kv=$kv raft=$raft wal=$wal"
    for role in kv raft wal; do
      local path=""; case $role in kv) path="$kv";; raft) path="$raft";; wal) path="$wal";; esac
      [[ -z "$path" ]]&&continue
      ssh_tikv "$ip" "findmnt -T '$path' -o TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN 2>/dev/null">"$dd/findmnt-$role.txt"||true
      ssh_tikv "$ip" "lsblk -s -o NAME,TYPE,MAJ:MIN,SIZE,MOUNTPOINTS 2>/dev/null">>"$dd/lsblk.txt" 2>/dev/null||true
      ssh_tikv "$ip" "df -T '$path' 2>/dev/null">"$dd/df-$role.txt"||true
      local src; src=$(awk 'NR==2{print $2}' "$dd/findmnt-$role.txt" 2>/dev/null||echo "")
      echo -e "$ip\t$role\t$path\t$src">>"$OUT/device/device-map.tsv"
    done
  done
  log "Device mapping: $(wc -l<"$OUT/device/device-map.tsv" 2>/dev/null||echo 0) entries"
}

# Samplers
start_sampler() {
  local name=$1; shift; local cmd=$1; shift
  local pf="$OUT/samplers/${name}.pid"; local hb="$OUT/samplers/${name}.heartbeat"
  nice -n 19 bash -c "$cmd" 2>"$OUT/samplers/${name}.errors.tsv" &
  echo $!>"$pf"; echo "$(date +%s)">"$hb"
  log "  $name started (pid=$!)"
}

start_all_samplers() {
  log "=== Starting samplers ==="
  # Upload remote helper to each TiKV node
  for ip in "${TIKV_IPS[@]}"; do
    "${SCP_BASE[@]}" "$OUT/provenance/t60-remote-host-sampler.sh" "${ip}:/tmp/t60-remote-host-sampler.sh" 2>/dev/null||true
    "${SSH_BASE[@]}" "$ip" 'chmod +x /tmp/t60-remote-host-sampler.sh' 2>/dev/null||true
  done

  # Client runtime (1s)
  start_sampler client-runtime 'OUT="'"$OUT"'"; K="'"$CLIENT_KEYS"'"; while true; do ts=$(date +%s); curl -s http://127.0.0.1:9567/metrics 2>/dev/null|grep -E "$K"|while IFS= read -r l; do printf "%s\t%s\n" "$ts" "$l">>"$OUT/samplers/client-runtime.tsv"; done; echo "$ts">>"$OUT/samplers/client-runtime.heartbeat"; sleep 1; done'

  # Client host (1s)
  start_sampler client-host 'OUT="'"$OUT"'"; while true; do ts=$(date +%s); cpu=$(head -1 /proc/stat 2>/dev/null|tr -s " "|cut -d" " -f2-11); mem=$(awk "/MemAvailable/{print \$2}" /proc/meminfo 2>/dev/null); printf "%s\t%s\t%s\n" "$ts" "$cpu" "$mem">>"$OUT/samplers/client-host.tsv"; echo "$ts">>"$OUT/samplers/client-host.heartbeat"; sleep 1; done'

  # TiKV metrics - 3 parallel (5s each)
  for ip in "${TIKV_IPS[@]}"; do
    start_sampler "tikv-metrics-$ip" 'OUT="'"$OUT"'"; IP="'"$ip"'"; RE="'"$TIKV_RE"'"; while true; do ts=$(date +%s); curl -s --connect-timeout 5 "http://${IP}:20180/metrics" 2>/dev/null|grep -E "$RE"|while IFS= read -r l; do printf "%s\t%s\t%s\n" "$ts" "$IP" "$l">>"$OUT/samplers/tikv-metrics-'"$ip"'.tsv"; done; echo "$ts">>"$OUT/samplers/tikv-metrics-'"$ip"'.heartbeat"; sleep 5; done'
  done

  # TiKV device - persistent SSH iostat (1s)
  for ip in "${TIKV_IPS[@]}"; do
    local dev=$(awk -v ip="$ip" '$1==ip && $2=="kv"{print $4}' "$OUT/device/device-map.tsv" 2>/dev/null|sed 's|/dev/||'|head -1)
    [[ -z "$dev" ]]&&dev="nvme1n1"
    start_sampler "tikv-device-$ip" 'OUT="'"$OUT"'"; IP="'"$ip"'"; DEV="'"$dev"'"; SSH=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5); while true; do "${SSH[@]}" "$IP" "bash /tmp/t60-remote-host-sampler.sh device /dev/$DEV" 2>/dev/null|while IFS= read -r l; do echo "$l">>"$OUT/samplers/tikv-device-'"$ip"'.tsv"; echo "$(date +%s)">>"$OUT/samplers/tikv-device-'"$ip"'.heartbeat"; done; sleep 2; done'
  done

  # TiKV host - persistent SSH (1s)
  for ip in "${TIKV_IPS[@]}"; do
    local tpid=$(ssh_tikv "$ip" 'pgrep tikv-server|head -1' 2>/dev/null||echo "")
    start_sampler "tikv-host-$ip" 'OUT="'"$OUT"'"; IP="'"$ip"'"; TPID="'"$tpid"'"; SSH=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5); while true; do "${SSH[@]}" "$IP" "bash /tmp/t60-remote-host-sampler.sh host $TPID" 2>/dev/null|while IFS= read -r l; do echo "$l">>"$OUT/samplers/tikv-host-'"$ip"'.tsv"; echo "$(date +%s)">>"$OUT/samplers/tikv-host-'"$ip"'.heartbeat"; done; sleep 2; done'
  done

  # Ceph (30s)
  start_sampler ceph 'OUT="'"$OUT"'"; while true; do ts=$(date +%s); h=$(sudo ceph health 2>/dev/null||echo ERR); p=$(sudo ceph pg stat 2>/dev/null|head -1||echo NA); printf "%s\t%s\t%s\n" "$ts" "$h" "$p">>"$OUT/samplers/ceph.tsv"; echo "$ts">>"$OUT/samplers/ceph.heartbeat"; sleep 30; done'

  # Pool (15s)
  start_sampler pool 'OUT="'"$OUT"'"; H='"$OBJ_HARD"'; while true; do ts=$(date +%s); l=$(sudo ceph df --format=json 2>/dev/null|python3 '"$OUT"'/pool_parse.py 2>/dev/null||echo "ERR ERR ERR"); o=$(echo "$l"|awk "{print \$1}"); printf "%s\t%s\n" "$ts" "$l">>"$OUT/samplers/pool.tsv"; echo "$ts">>"$OUT/samplers/pool.heartbeat"; if [[ "$o" =~ ^[0-9]+$ && "$o" -gt $H ]]; then echo "[WD] objs=$o>$H">>"$OUT/STOP.txt"; pkill -INT -f "fio.*B0" 2>/dev/null||true; fi; sleep 15; done'

  sleep 2; log "All samplers started"
}

check_samplers_alive() {
  for pf in "$OUT"/samplers/*.pid; do
    [[ -f "$pf" ]]||continue
    local name=$(basename "$pf" .pid); local pid=$(cat "$pf" 2>/dev/null)
    kill -0 "$pid" 2>/dev/null||{ log "DEAD: $name"; return 1; }
    local hb="$OUT/samplers/${name}.heartbeat"
    if [[ -f "$hb" ]]; then
      local last=$(tail -1 "$hb" 2>/dev/null); local now=$(date +%s)
      if [[ "$last" =~ ^[0-9]+$ ]]; then
        local gap=$((now-last)); local th=5
        case "$name" in ceph) th=40;; pool) th=25;; tikv-metrics-*) th=10;; tikv-device-*|tikv-host-*) th=10;; esac
        [[ $gap -le $th ]]||{ log "STALE: $name gap=${gap}s"; return 1; }
      fi
    fi
  done; return 0
}

validate_samplers_120s() {
  log "=== 120s pre-validation ==="
  local s=$(date +%s)
  while [[ $(($(date +%s)-s)) -lt 120 ]]; do check_samplers_alive||{ log "STOP: sampler died"; return 1; }; sleep 5; done
  # Python validator
  python3 "$OUT/provenance/t60-validate-coverage.py" --preflight "$OUT" "$s" 2>&1 | tee "$OUT/preflight/validator-output.txt"
  local vrc=${PIPESTATUS[0]}
  [[ $vrc -eq 0 ]]||{ log "STOP: coverage validation failed"; return 1; }
  log "  120s validation passed"; return 0
}

stop_samplers() { for pf in "$OUT"/samplers/*.pid; do [[ -f "$pf" ]]||continue; kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null||true; done; sleep 2; }

# ===== Phase 0: Preflight =====
log "=== T60 03-20B-R1 start run_id=$RUN_ID ==="

# S00: mount check
if mountpoint -q "$MNT"; then log "S00 STOP: mount already exists"; echo "S00">>"$OUT/STOP.txt"; exit 0; fi

hostname>"$OUT/fingerprint/hostname.txt"; date '+%Y-%m-%d %H:%M:%S %z'>"$OUT/fingerprint/datetime.txt"; fio --version>"$OUT/fingerprint/fio-version.txt" 2>&1
[[ "$(md5sum "$BIN"|awk '{print $1}')"=="$BIN_MD5" ]]||{ log "S01 STOP: binary"; exit 5; }
[[ "$(md5sum "$SYS_CONF"|awk '{print $1}')"=="$SYS_CONF_MD5" ]]||{ log "S01 STOP: conf"; exit 5; }
cp "$SYS_CONF" "$OUT/fingerprint/ceph.conf.system"
health=$(sudo ceph health 2>/dev/null||echo "ERR"); [[ "$health"=="HEALTH_OK" ]]||{ log "S02 STOP: health=$health"; exit 5; }
osd_up=$(sudo ceph osd stat 2>/dev/null|grep -oP '\d+(?= up)'|head -1); osd_up=${osd_up:-0}; [[ "$osd_up" -ge 6 ]]||{ log "S02 STOP: OSD=$osd_up"; exit 5; }
sudo ceph osd dump 2>/dev/null|grep 'up_from'|head -1>"$OUT/fingerprint/up_from-pre.txt"||true
avail_k=$(df -Pk /|awk 'NR==2{print $4}'); [[ "$avail_k" -ge 8388608 ]]||{ log "STOP: root<8GiB"; exit 5; }

# Mount
"$BIN" mount -d $MOUNT_OPTS "$META" "$MNT">>"$OUT/mount.log" 2>&1; sleep 10
mountpoint -q "$MNT"||{ log "STOP: mount failed"; exit 6; }
PID=$(pgrep -f "juicefs-03-8.*juicefs-prod"|head -1); [[ "$PID" =~ ^[0-9]+$ ]]||{ log "STOP: no pid"; exit 6; }
PSTART=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null||echo 0)
exe_md5=$(md5sum "/proc/$PID/exe"|awk '{print $1}'); [[ "$exe_md5"=="$BIN_MD5" ]]||{ log "STOP: exe md5"; exit 6; }
grep -q 'max_read=262144' /proc/mounts||{ log "STOP: max_read"; exit 6; }
proc_conf=$(tr '\0' '\n'</proc/$PID/environ 2>/dev/null|awk -F= '$1=="CEPH_CONF"{print $2}')
msgr_ok=$(grep -c 'ms_async_op_threads = 8' "$proc_conf" 2>/dev/null||echo 0); [[ "$msgr_ok" -eq 1 ]]||{ log "STOP: msgr"; exit 6; }
for s in storage_test read_test rw_test; do c=$(find "$TEST_DIR" -maxdepth 1 -type f -name "${s}.*.0" 2>/dev/null|wc -l); [[ "$c" -eq 128 ]]||{ log "STOP: ${s}=$c"; exit 6; }; done
stat_all_files>"$OUT/files/pre.tsv"
{ echo "pid=$PID starttime=$PSTART"; md5sum "/proc/$PID/exe"; grep " $MNT " /proc/mounts; echo "conf=$proc_conf msgr=$msgr_ok"; }>"$OUT/fingerprint/pre.txt"
log "Mount OK pid=$PID"

# Jobfile
if [[ -f "$SCRIPT_DIR/t56-gen-jobfiles.sh" ]]; then bash "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$OUT/jobfiles">"$OUT/jobfiles-gen.log" 2>&1; bash "$SCRIPT_DIR/t56-validate-jobfiles.sh" "$OUT/jobfiles">>"$OUT/jobfiles-validate.log" 2>&1
elif [[ -f /tmp/t56-gen-jobfiles.sh ]]; then bash /tmp/t56-gen-jobfiles.sh "$OUT/jobfiles">"$OUT/jobfiles-gen.log" 2>&1; bash /tmp/t56-validate-jobfiles.sh "$OUT/jobfiles">>"$OUT/jobfiles-validate.log" 2>&1; fi
cp "$OUT/jobfiles/B0.fio" "$OUT/arm/B0.fio"; b0_md5=$(md5sum "$OUT/arm/B0.fio"|awk '{print $1}'); [[ "$b0_md5"=="3b43b01ed2c4033ed42ad52bddc77c2f" ]]||{ log "S01 STOP: B0 md5=$b0_md5"; exit 5; }
log "Jobfile B0 OK (md5=$b0_md5)"

# Device mapping
map_devices||{ log "S04 STOP: device mapping"; exit 6; }

# OSD keys
log "=== OSD key precheck ==="; find_osd_keys||log "WARN: OSD keys not found"

# Metric exposition
log "=== Metric exposition ==="
for ip in "${TIKV_IPS[@]}"; do curl -s "http://${ip}:20180/metrics" 2>/dev/null|grep -E "$TIKV_RE"|head -5>"$OUT/preflight/metric-proof-${ip}.txt"||true; done
for ip in "${TIKV_IPS[@]}"; do curl -s "http://${ip}:20180/metrics" 2>/dev/null|gzip>"$OUT/metrics-full/tikv-${ip}-pre.prom.gz"; done
log "Metrics preflight done"

# Samplers
start_all_samplers
validate_samplers_120s||{ log "S08 STOP: sampler validation"; stop_samplers; exit 7; }

# Reset
reset_to_gate "preload"||{ log "STOP: preload reset"; stop_samplers; exit 7; }

# ===== Phase 5: fio =====
log "=== ARM D-B256 ==="
curl -s http://127.0.0.1:9567/metrics 2>/dev/null|grep -E "$CLIENT_KEYS">"$OUT/arm/pre.tsv"
for ip in "${TIKV_IPS[@]}"; do curl -s "http://${ip}:20180/metrics" 2>/dev/null|grep -E "$TIKV_RE">"$OUT/arm/tikv-pre-${ip}.tsv"; done
stat_all_files>"$OUT/files/pre-arm.tsv"
echo -e "$(date +%s)\tD-B256\tpre">>"$OUT/phase.tsv"

setsid fio "$OUT/arm/B0.fio" --write_bw_log="$OUT/arm/bw/D-B256">"$OUT/arm/fio.stdout" 2>"$OUT/arm/fio.stderr" &
FIO_PID=$!; echo $FIO_PID>"$OUT/arm/fio.pid"
FIO_START_EPOCH=$(date +%s)
echo -e "$(date +%s)\tD-B256\tfio_start pid=$FIO_PID epoch=$FIO_START_EPOCH">>"$OUT/phase.tsv"
log "Starting fio D-B256 (pid=$FIO_PID)"

while kill -0 $FIO_PID 2>/dev/null; do
  sleep 2
  [[ -f "$OUT/STOP.txt" ]]&&{ log "STOP: watchdog"; kill -INT -$FIO_PID 2>/dev/null||true; break; }
  mountpoint -q "$MNT"||{ log "STOP: mount lost"; break; }
  check_samplers_alive||{ log "S09 STOP: sampler died"; kill -INT -$FIO_PID 2>/dev/null||true; break; }
done
wait $FIO_PID 2>/dev/null||true; FIO_RC=$?; echo $FIO_RC>"$OUT/arm/fio.rc"
echo -e "$(date +%s)\tD-B256\tfio_end rc=$FIO_RC">>"$OUT/phase.tsv"

# POST
curl -s http://127.0.0.1:9567/metrics 2>/dev/null|grep -E "$CLIENT_KEYS">"$OUT/arm/post.tsv"
for ip in "${TIKV_IPS[@]}"; do curl -s "http://${ip}:20180/metrics" 2>/dev/null|grep -E "$TIKV_RE">"$OUT/arm/tikv-post-${ip}.tsv"; curl -s "http://${ip}:20180/metrics" 2>/dev/null|gzip>"$OUT/metrics-full/tikv-${ip}-post.prom.gz"; done
stat_all_files>"$OUT/files/post.tsv"
bw_logs=$(find "$OUT/arm/bw" -name "*_bw.*.log" -type f|wc -l)
bw=$(grep -oP 'WRITE: bw=\K[0-9]+MiB' "$OUT/arm/fio.stdout" 2>/dev/null|head -1)
log "ARM D-B256: rc=$FIO_RC bw_logs=$bw_logs BW=$bw"

# Phase 6: Coverage validation
log "=== Coverage validation ==="
python3 "$OUT/provenance/t60-validate-coverage.py" --formal "$OUT" "$FIO_START_EPOCH" 2>&1|tee "$OUT/coverage-output.txt"
COVERAGE_RC=${PIPESTATUS[0]}
[[ $COVERAGE_RC -eq 0 ]]||log "WARN: coverage validation failed (rc=$COVERAGE_RC)"

# Final reset
reset_to_gate "final"||{ log "WARN: final reset failed"; }

# Cleanup
log "=== Cleanup ==="
stop_samplers
{ echo "pid=$PID starttime=$PSTART"; md5sum "/proc/$PID/exe"; }>"$OUT/fingerprint/post.txt"
md5sum "$SYS_CONF">>"$OUT/fingerprint/post.txt"
sudo ceph osd dump 2>/dev/null|grep 'up_from'|head -1>"$OUT/fingerprint/up_from-post.txt"||true

# Graceful unmount only
sync; umount "$MNT" 2>/dev/null||fusermount -u "$MNT" 2>/dev/null||umount "$MNT" 2>/dev/null||{ log "WARN: umount failed, keeping mount"; }

# Archive
( cd "$OUT"&&find . -type f ! -name MANIFEST.md5 -print0|sort -z|xargs -0 md5sum>MANIFEST.md5 2>/dev/null )||true
ARCHIVE="$ARCHIVE_DIR/opencode-t3.20b-r1-${RUN_ID}.tar.gz"
tar -C /tmp -czf "$ARCHIVE" "$(basename "$OUT")" 2>/dev/null||true
md5sum "$ARCHIVE">"${ARCHIVE}.md5" 2>/dev/null||true
trap - EXIT  # Remove trap before final log
log "=== T60 DONE ==="
log "OUT=$OUT ARCHIVE=$ARCHIVE BW=$bw bw_logs=$bw_logs rc=$FIO_RC coverage_rc=$COVERAGE_RC"
