#!/usr/bin/env bash
# T61: 03-20B-R2 final TiKV shared-NVMe evidence closure.
# Normal mode is deliberately single-use.  --self-test is pure offline.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_FILE="$SCRIPT_DIR/../../../doc/perf-tasks/03-20B-R2-tikv-shared-nvme-final-closure.md"

case "${1:-}" in
  --self-test)
    exec bash "$SCRIPT_DIR/t61-gate0-offline.sh"
    ;;
  --describe)
    printf '%s\n' '03-20B-R2: one frozen B256 arm; no configuration changes; no automatic retry.'
    exit 0
    ;;
esac

RUN_ID=${1:-}
[[ $# -eq 1 && "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || {
  echo "usage: T61_SKILL_ACK=read-and-accepted T61_USER_AUTH=03-20B-R2-single-run $0 YYYYMMDD-HHMMSS" >&2
  exit 2
}
[[ "${T61_SKILL_ACK:-}" == read-and-accepted ]] || { echo 'REFUSE: T61_SKILL_ACK=read-and-accepted is required' >&2; exit 2; }
[[ "${T61_USER_AUTH:-}" == 03-20B-R2-single-run ]] || { echo 'REFUSE: T61_USER_AUTH=03-20B-R2-single-run is required' >&2; exit 2; }

BIN=/tmp/juicefs-03-8
BIN_MD5=de93563f11a5ff3bd94dd25a4e0283b1
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'
MNT=/mnt/juicefs
TEST_DIR=/mnt/juicefs/test_dir
MOUNT_OPTS=(--max-uploads 150 --cache-size 0 --max-fuse-io 256K)
SYS_CONF=/etc/ceph/ceph.conf
SYS_CONF_MD5=5b6be34179a64e0a5f9c6d3a9690041f
B0_MD5=3b43b01ed2c4033ed42ad52bddc77c2f
TIKV_IPS=(10.20.1.150 10.20.1.151 10.20.1.152)
SSH_BASE=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1)
SCP_BASE=(sshpass -p Sunrise@801 scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
OBJ_BASE=2434672
OBJ_TOL=128
OBJ_HARD=8000000
OUT="/tmp/opencode-t3.20b-r2-${RUN_ID}"
ARCHIVE_DIR=/tmp/production
ARCHIVE="$ARCHIVE_DIR/opencode-t3.20b-r2-${RUN_ID}.tar.gz"
ATTEMPT="$ARCHIVE_DIR/03-20B-R2-ATTEMPT-${RUN_ID}.started"
LOCK_DIR=/tmp/t61-r2-global.lock
PRIVATE_CONF="/tmp/t61-msgr8-${RUN_ID}.conf"

TIKV_RE='^(tikv_storage_engine_async_request_duration_seconds_(sum|count)|tikv_scheduler_(command|latch_wait|processing_read)_duration_seconds_(sum|count)|tikv_raftstore_(append|commit|apply)_log_duration_seconds_(sum|count)|tikv_raftstore_apply_wait_time_duration_secs_(sum|count)|tikv_engine_pending_compaction_bytes|tikv_scheduler_pending_compaction_bytes|tikv_engine_compaction_duration_seconds_(sum|count)|tikv_engine_compaction_flow_bytes|tikv_engine_num_files_at_level|tikv_engine_num_subcompaction_scheduled|tikv_engine_stall_micro_seconds|tikv_engine_write_stall|tikv_engine_write_stall_reason|tikv_engine_wal_file_sync_micro_seconds|tikv_engine_wal_file_synced|tikv_rate_limiter_max_bytes_per_sec|tikv_thread_cpu_seconds_total|tikv_threads_io_bytes_total|tikv_threads_state|process_cpu_seconds_total)'
CLIENT_RE='^(juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_transaction_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_fuse_write_size_bytes_sum|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_staging_blocks)'

STOP_CODE=""
MOUNT_OWNED=0
MOUNT_PID=""
MOUNT_START=""
FIO_PID=""
FIO_PGID=""
FIO_RC=255
FIO_FORCED=0
ARM_COUNT=0
SAMPLER_FORCE_KILL=0
FINALIZED=0
SAMPLER_NAMES=()
SAMPLER_PIDS=()
SAMPLER_PGIDS=()
OSD_IDS=()

mkdir -p "$ARCHIVE_DIR"
shopt -s nullglob
prior_attempts=("$ARCHIVE_DIR"/03-20B-R2-ATTEMPT-*.started)
shopt -u nullglob
(( ${#prior_attempts[@]} == 0 )) || {
  printf 'REFUSE: an R2 attempt marker already exists: %s\n' "${prior_attempts[*]}" >&2
  exit 3
}
mkdir "$LOCK_DIR" 2>/dev/null || { echo "REFUSE: concurrent/stale lock $LOCK_DIR" >&2; exit 3; }
( set -o noclobber; printf 'run_id=%s epoch=%s pid=%s\n' "$RUN_ID" "$(date +%s)" "$$" > "$ATTEMPT" ) || {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  echo 'REFUSE: could not create unique attempt marker' >&2
  exit 3
}
mkdir "$OUT" || { rmdir "$LOCK_DIR" 2>/dev/null || true; exit 3; }
mkdir -p "$OUT"/{arm/bw,device,files,fingerprint,jobfiles,metrics-full,preflight,provenance,reset,samplers}
cp "$ATTEMPT" "$OUT/attempt.started"

log() {
  local message="[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"
  printf '%s\n' "$message" >> "$OUT/wrapper.log"
  printf '%s\n' "$message"
}

record_stop() {
  local code=$1
  shift
  [[ -z "$STOP_CODE" ]] && STOP_CODE=$code
  printf '%s\t%s\t%s\n' "$(date +%s)" "$code" "$*" >> "$OUT/STOP.txt"
  log "$code STOP: $*"
}

pid_alive() {
  local pid=$1
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
  [[ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" != Z ]]
}

group_alive() {
  local pgid=$1
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  ps -eo pgid=,stat= | awk -v want="$pgid" '$1==want && $2 !~ /^Z/{found=1} END{exit !found}'
}

stop_exact_group() {
  local pgid=$1 signal=$2
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  kill "-$signal" -- "-$pgid" 2>/dev/null || true
}

wait_group_dead() {
  local pgid=$1
  local seconds=$2
  local deadline=$((SECONDS + seconds))
  while group_alive "$pgid" && (( SECONDS < deadline )); do sleep 1; done
  ! group_alive "$pgid"
}

stop_fio_for_watchdog() {
  [[ -n "$FIO_PGID" ]] || return 0
  stop_exact_group "$FIO_PGID" INT
  if ! wait_group_dead "$FIO_PGID" 60; then
    stop_exact_group "$FIO_PGID" TERM
    if ! wait_group_dead "$FIO_PGID" 60; then
      stop_exact_group "$FIO_PGID" KILL
      FIO_FORCED=1
      wait_group_dead "$FIO_PGID" 10 || true
    fi
  fi
}

stop_unregistered_fio_pid() {
  local pid=$1 deadline
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -INT "$pid" 2>/dev/null || true
  deadline=$((SECONDS + 60)); while pid_alive "$pid" && (( SECONDS < deadline )); do sleep 1; done
  if pid_alive "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + 60)); while pid_alive "$pid" && (( SECONDS < deadline )); do sleep 1; done
  fi
  if pid_alive "$pid"; then kill -KILL "$pid" 2>/dev/null || true; FIO_FORCED=1; fi
}

stop_samplers() {
  local index pgid pid
  for index in "${!SAMPLER_NAMES[@]}"; do
    pgid=${SAMPLER_PGIDS[$index]}
    stop_exact_group "$pgid" TERM
  done
  for index in "${!SAMPLER_NAMES[@]}"; do
    pgid=${SAMPLER_PGIDS[$index]}
    pid=${SAMPLER_PIDS[$index]}
    if ! wait_group_dead "$pgid" 15; then
      stop_exact_group "$pgid" KILL
      SAMPLER_FORCE_KILL=1
      wait_group_dead "$pgid" 5 || true
    fi
    set +e
    wait "$pid" 2>/dev/null
    set -e
  done
}

verify_remote_sampler_cleanup() {
  local ip deadline output
  : > "$OUT/fingerprint/remote-sampler-post.tsv"
  for ip in "${TIKV_IPS[@]}"; do
    deadline=$((SECONDS + 15))
    while :; do
      output=$(ssh_tikv "$ip" "pgrep -af '[t]61-remote-resource-sampler.sh' || true") || return 1
      [[ -z "$output" ]] && break
      (( SECONDS < deadline )) || {
        printf '%s\t%s\n' "$ip" "$output" >> "$OUT/fingerprint/remote-sampler-post.tsv"
        return 1
      }
      sleep 1
    done
    printf '%s\tCLEAN\n' "$ip" >> "$OUT/fingerprint/remote-sampler-post.tsv"
  done
}

graceful_unmount() {
  (( MOUNT_OWNED == 1 )) || return 0
  mountpoint -q "$MNT" || return 0
  "$BIN" umount "$MNT" >/dev/null 2>&1 || true
  mountpoint -q "$MNT" || return 0
  command -v fusermount3 >/dev/null 2>&1 && fusermount3 -u "$MNT" >/dev/null 2>&1 || true
  mountpoint -q "$MNT" || return 0
  command -v fusermount >/dev/null 2>&1 && fusermount -u "$MNT" >/dev/null 2>&1 || true
  mountpoint -q "$MNT" || return 0
  umount "$MNT" >/dev/null 2>&1 || true
  ! mountpoint -q "$MNT"
}

write_skill_post() {
  {
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'arm_count=%s\n' "$ARM_COUNT"
    printf 'fio_forced_kill=%s\n' "$FIO_FORCED"
    printf 'sampler_forced_kill=%s\n' "$SAMPLER_FORCE_KILL"
    printf 'mount_kill=0\nconfig_change=0\nrestart=0\nlayout_change=0\nremount_repair=0\n'
    printf 'stop_code=%s\n' "${STOP_CODE:-NONE}"
    printf 'mount_remaining=%s\n' "$(mountpoint -q "$MNT" && echo 1 || echo 0)"
  } > "$OUT/skill-check-post.txt"
}

files_stable() {
  local first="/tmp/t61-stable-${RUN_ID}.1" second="/tmp/t61-stable-${RUN_ID}.2"
  find "$OUT" -type f ! -name MANIFEST.md5 -printf '%P\t%s\t%T@\n' | sort > "$first"
  sleep 2
  find "$OUT" -type f ! -name MANIFEST.md5 -printf '%P\t%s\t%T@\n' | sort > "$second"
  cmp -s "$first" "$second"
  local rc=$?
  rm -f "$first" "$second"
  return "$rc"
}

finalize_archive() {
  local suffix=${1:-}
  (( FINALIZED == 0 )) || return 0
  FINALIZED=1
  write_skill_post
  log "Finalizing archive suffix=${suffix:-SUCCESS}"
  files_stable || {
    record_stop S14 "files changed after sampler shutdown"
    write_skill_post
    suffix=-ABORT
    sleep 3
  }
  (cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5)
  local verify="/tmp/t61-manifest-${RUN_ID}.verify"
  if ! (cd "$OUT" && md5sum -c MANIFEST.md5) > "$verify" 2>&1; then
    rm -f "$OUT/MANIFEST.md5"
    record_stop S14 "MANIFEST self-check failed"
    write_skill_post
    suffix=-ABORT
    files_stable || true
    (cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5)
    (cd "$OUT" && md5sum -c MANIFEST.md5) > "$verify" 2>&1 || true
  fi
  local target="$ARCHIVE_DIR/opencode-t3.20b-r2-${RUN_ID}${suffix}.tar.gz"
  tar -C /tmp -czf "$target" "$(basename "$OUT")"
  md5sum "$target" > "${target}.md5"
  cp "$verify" "${target}.manifest-verify.txt"
  rm -f "$verify"
  printf 'ARCHIVE=%s\n' "$target"
  printf 'ARCHIVE_MD5=%s\n' "$(awk '{print $1}' "${target}.md5")"
}

on_exit() {
  local rc=$?
  local had_samplers=${#SAMPLER_NAMES[@]}
  trap - EXIT INT TERM
  set +e
  if [[ -n "$FIO_PGID" ]] && group_alive "$FIO_PGID"; then
    record_stop S10 "exit trap found live fio PGID=$FIO_PGID"
    stop_fio_for_watchdog
  elif [[ -n "$FIO_PID" ]] && pid_alive "$FIO_PID"; then
    record_stop S10 "exit trap found live unregistered fio PID=$FIO_PID"
    stop_unregistered_fio_pid "$FIO_PID"
  fi
  stop_samplers
  if (( had_samplers > 0 )); then verify_remote_sampler_cleanup || record_stop S12 remote-sampler-remains; fi
  if ! graceful_unmount; then record_stop S12 "graceful unmount failed; mount preserved"; fi
  if (( FINALIZED == 0 )); then finalize_archive -ABORT; fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
  exit "$rc"
}
trap on_exit EXIT INT TERM

start_sampler() {
  local name=$1
  shift
  setsid nice -n 19 "$@" 2> "$OUT/samplers/${name}.errors.tsv" &
  local pid=$! pgid
  sleep 0.1
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ "$pgid" == "$pid" ]] || { record_stop S08 "sampler $name did not get private PGID pid=$pid pgid=$pgid"; return 1; }
  printf '%s\n' "$pid" > "$OUT/samplers/${name}.pid"
  printf '%s\n' "$pgid" > "$OUT/samplers/${name}.pgid"
  SAMPLER_NAMES+=("$name")
  SAMPLER_PIDS+=("$pid")
  SAMPLER_PGIDS+=("$pgid")
  log "sampler $name pid=$pid pgid=$pgid"
}

check_samplers() {
  local index name pid hb last now threshold
  now=$(date +%s)
  (( ${#SAMPLER_NAMES[@]} == 13 )) || return 1
  for index in "${!SAMPLER_NAMES[@]}"; do
    name=${SAMPLER_NAMES[$index]}
    pid=${SAMPLER_PIDS[$index]}
    pid_alive "$pid" || { log "sampler dead: $name"; return 1; }
    hb="$OUT/samplers/${name}.heartbeat"
    [[ -s "$hb" ]] || { log "sampler heartbeat missing: $name"; return 1; }
    last=$(tail -1 "$hb")
    threshold=4
    case "$name" in tikv-metrics-*) threshold=8;; pool) threshold=22;; ceph) threshold=38;; esac
    [[ "$last" =~ ^[0-9]+$ ]] && (( now - last <= threshold )) || { log "sampler stale: $name last=$last"; return 1; }
  done
}

ssh_tikv() {
  local ip=$1
  shift
  "${SSH_BASE[@]}" "$ip" "$@"
}

mount_identity_ok() {
  [[ -n "$MOUNT_PID" && -r "/proc/$MOUNT_PID/stat" ]] || return 1
  [[ "$(awk '{print $22}' "/proc/$MOUNT_PID/stat")" == "$MOUNT_START" ]] || return 1
  [[ "$(md5sum "/proc/$MOUNT_PID/exe" | awk '{print $1}')" == "$BIN_MD5" ]] || return 1
  mountpoint -q "$MNT"
}

find_mount_pid() {
  local pid found=()
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/exe" ]] || continue
    [[ "$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')" == "$BIN_MD5" ]] && found+=("$pid")
  done < <(pgrep -o -f '/tmp/juicefs-03-8.*juicefs-prod' || true)
  (( ${#found[@]} >= 1 )) || return 1
  printf '%s\n' "${found[0]}"
}

stat_all_files() {
  local prefix file
  for prefix in storage_test read_test rw_test; do
    for file in "$TEST_DIR/${prefix}."*.0; do
      [[ -f "$file" ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$(stat -c %n "$file")" "$(stat -c %i "$file")" "$(stat -c %s "$file")" "$(stat -c %Y "$file")"
    done
  done | sort
}

validate_layout_file() {
  local file=$1
  [[ $(wc -l < "$file") -eq 384 ]] || return 1
  awk -F '\t' '
    $3 != 1073741824 { bad=1 }
    $1 ~ /\/storage_test\.[0-9]+\.0$/ { storage++ }
    $1 ~ /\/read_test\.[0-9]+\.0$/ { readc++ }
    $1 ~ /\/rw_test\.[0-9]+\.0$/ { rw++ }
    END { exit (bad || storage!=128 || readc!=128 || rw!=128) }
  ' "$file"
}

layout_signature() {
  awk -F '\t' '{print $1"\t"$2"\t"$3}' "$1"
}

pool_sample() {
  sudo ceph df --format=json | bash "$OUT/provenance/t61-local-sampler.sh" --parse-pool
}

tikv_pending_sample() {
  local ip=$1
  curl -fsS --connect-timeout 3 --max-time 5 "http://${ip}:20180/metrics" \
    | awk '/^tikv_engine_pending_compaction_bytes\{/{sum+=$2; found=1} END{if(!found)exit 1; printf "%.0f\n",sum}'
}

find_osd_keys() {
  local json="$OUT/preflight/osd-perf-schema.json"
  sudo ceph tell "osd.${OSD_IDS[0]}" perf dump > "$json"
  python3 "$OUT/provenance/t61-validate-evidence.py" --osd-keys "$json" > "$OUT/preflight/osd-keys.tsv"
}

osd_value() {
  local json=$1 path=$2
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1]));
for key in sys.argv[2].split("."): v=v[key]
print(v)' "$json" "$path"
}

osd_cooldown_once() {
  local label=$1 epoch ipath cpath qpath osd json running queue latency ok=1
  epoch=$(date +%s)
  cpath=$(awk -F '\t' '$1=="compact_running"{print $2}' "$OUT/preflight/osd-keys.tsv")
  qpath=$(awk -F '\t' '$1=="compact_queue_len"{print $2}' "$OUT/preflight/osd-keys.tsv")
  ipath=$(awk -F '\t' '$1=="kv_sync_lat"{print $2}' "$OUT/preflight/osd-keys.tsv")
  for osd in "${OSD_IDS[@]}"; do
    json="/tmp/t61-osd-${RUN_ID}-${osd}.json"
    sudo ceph tell "osd.$osd" perf dump > "$json" || return 1
    running=$(osd_value "$json" "$cpath") || return 1
    queue=$(osd_value "$json" "$qpath") || return 1
    latency=$(osd_value "$json" "$ipath") || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$label" "$osd" "$running" "$queue" "$latency" >> "$OUT/reset/osd-cooldown.tsv"
    [[ "$running" == 0 && "$queue" == 0 ]] || ok=0
    awk -v value="$latency" 'BEGIN{exit !(value>=0 && value<0.002)}' || ok=0
  done
  (( ok == 1 ))
}

compact_and_wait() {
  local label=$1 osd deadline
  for osd in "${OSD_IDS[@]}"; do sudo ceph tell "osd.$osd" compact >/dev/null; done
  sleep 5
  deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    osd_cooldown_once "$label" && return 0
    sleep 5
  done
  return 1
}

drop_caches_four_nodes() {
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  local ip
  for ip in "${TIKV_IPS[@]}"; do
    ssh_tikv "$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null'
  done
}

cpu_idle_percent() {
  local a b
  a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
  sleep 5
  b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
  awk -v a="$a" -v b="$b" 'BEGIN{split(a,x);split(b,y); total=y[1]-x[1]; idle=y[2]-x[2]; if(total<=0)exit 1; printf "%.2f\n",100*idle/total}'
}

idle_gate() {
  local deadline=$((SECONDS + 180)) consecutive=0 idle health ip pending all_pending
  while (( SECONDS < deadline )); do
    pgrep -x fio >/dev/null && { consecutive=0; sleep 5; continue; }
    health=$(sudo ceph health 2>/dev/null || true)
    [[ "$health" == HEALTH_OK ]] || { consecutive=0; sleep 5; continue; }
    mount_identity_ok || return 1
    osd_cooldown_once idle || { consecutive=0; sleep 5; continue; }
    all_pending=1
    for ip in "${TIKV_IPS[@]}"; do pending=$(tikv_pending_sample "$ip") || return 1; (( pending == 0 )) || all_pending=0; done
    (( all_pending == 1 )) || { consecutive=0; sleep 5; continue; }
    idle=$(cpu_idle_percent) || return 1
    if awk -v value="$idle" 'BEGIN{exit !(value>=70)}'; then consecutive=$((consecutive + 1)); else consecutive=0; fi
    printf '%s\t%s\t%s\n' "$(date +%s)" "$idle" "$consecutive" >> "$OUT/idle-gate.tsv"
    (( consecutive >= 3 )) && return 0
  done
  return 1
}

reset_to_gate() {
  local label=$1 dir="$OUT/reset/$1" attempt a b c spread ip pending deadline ta tb tc converged=0
  mkdir -p "$dir"
  log "reset $label: begin"
  sync -f "$MNT" 2>/dev/null || true
  compact_and_wait "${label}-pre1" || return 1
  sleep 30
  compact_and_wait "${label}-pre2" || return 1
  set +e
  "$BIN" gc --compact "$META" > "$dir/gc.log" 2>&1
  local gc_rc=$?
  set -e
  printf 'rc=%s\n' "$gc_rc" >> "$dir/gc.log"
  (( gc_rc == 0 )) || return 1

  for attempt in $(seq 1 40); do
    ta=$(date +%s); a=$(pool_sample) || return 1; sleep 15
    tb=$(date +%s); b=$(pool_sample) || return 1; sleep 15
    tc=$(date +%s); c=$(pool_sample) || return 1
    printf '%s\t%s\n%s\t%s\n%s\t%s\n' "$ta" "$a" "$tb" "$b" "$tc" "$c" > "$dir/objects-${attempt}.tsv"
    read -r a _ <<<"$a"; read -r b _ <<<"$b"; read -r c _ <<<"$c"
    spread=$(printf '%s\n' "$a" "$b" "$c" | sort -n | awk 'NR==1{lo=$1} END{print $1-lo}')
    if (( spread <= OBJ_TOL && a >= OBJ_BASE-OBJ_TOL && a <= OBJ_BASE+OBJ_TOL && b >= OBJ_BASE-OBJ_TOL && b <= OBJ_BASE+OBJ_TOL && c >= OBJ_BASE-OBJ_TOL && c <= OBJ_BASE+OBJ_TOL )); then converged=1; break; fi
  done
  (( converged == 1 )) || return 1
  compact_and_wait "${label}-post" || return 1

  deadline=$((SECONDS + 600))
  while :; do
    local all_zero=1
    for ip in "${TIKV_IPS[@]}"; do
      pending=$(tikv_pending_sample "$ip") || return 1
      printf '%s\t%s\t%s\n' "$(date +%s)" "$ip" "$pending" >> "$dir/tikv-pending.tsv"
      (( pending == 0 )) || all_zero=0
    done
    (( all_zero == 1 )) && break
    (( SECONDS < deadline )) || return 1
    sleep 10
  done

  stat_all_files > "$dir/file-stats.tsv"
  validate_layout_file "$dir/file-stats.tsv" || return 1
  drop_caches_four_nodes || return 1
  sleep 60
  idle_gate || return 1
  printf '%s\t%s\tready\n' "$(date +%s)" "$label" >> "$OUT/phase.tsv"
  log "reset $label: PASS"
}

map_devices() {
  local ip cfg parsed role path resolved target source fstype majmin leaves leaf base
  : > "$OUT/device/device-map.tsv"
  for ip in "${TIKV_IPS[@]}"; do
    mkdir -p "$OUT/device/$ip"
    cfg="$OUT/device/$ip/tikv-config-pre.json"
    curl -fsS --connect-timeout 3 --max-time 5 "http://${ip}:20180/config" > "$cfg"
    parsed=$(python3 "$OUT/provenance/t61-validate-evidence.py" --role-paths "$cfg") || return 1
    while IFS=$'\t' read -r role path <&3; do
      resolved=$(ssh_tikv "$ip" bash -s -- "$path" <<'REMOTE'
set -euo pipefail
export LC_ALL=C
path=$1
candidate=$path
row=""
while [[ "$candidate" != / ]]; do
  row=$(findmnt -rn -T "$candidate" -o TARGET,SOURCE,FSTYPE,MAJ:MIN 2>/dev/null || true)
  [[ -n "$row" ]] && break
  candidate=$(dirname "$candidate")
done
[[ -n "$row" ]] || exit 1
read -r target source fstype majmin <<<"$row"
source=${source%%\[*}
mapfile -t leaf_array < <(lsblk -s -nrpo NAME,TYPE "$source" | awk '$2=="disk"{print $1}' | sort -u)
(( ${#leaf_array[@]} > 0 )) || exit 1
leaves=$(IFS=,; echo "${leaf_array[*]}")
printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$source" "$fstype" "$majmin" "$leaves"
REMOTE
) || return 1
      IFS=$'\t' read -r target source fstype majmin leaves <<<"$resolved"
      [[ -n "$target" && -n "$source" && -n "$fstype" && -n "$majmin" && -n "$leaves" ]] || return 1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ip" "$role" "$path" "$target" "$source" "$fstype" "$majmin" "$leaves" >> "$OUT/device/device-map.tsv"
      ssh_tikv "$ip" "findmnt -rn -T '$target' -o TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN; lsblk -s -o NAME,TYPE,MAJ:MIN,SIZE,MOUNTPOINTS '$source'" > "$OUT/device/$ip/${role}-mount-and-lsblk.txt"
      IFS=',' read -ra leaf_array <<<"$leaves"
      for leaf in "${leaf_array[@]}"; do
        base=$(basename "$leaf")
        ssh_tikv "$ip" "for q in scheduler nr_requests read_ahead_kb rotational; do printf '%s=' \"\$q\"; cat /sys/block/'$base'/queue/\"\$q\"; done" > "$OUT/device/$ip/${role}-${base}-queue.txt"
      done
    done 3<<<"$parsed"
  done
  [[ $(wc -l < "$OUT/device/device-map.tsv") -eq 9 ]] || return 1
  awk -F '\t' 'NF!=8 || $1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="" || $7=="" || $8==""{bad=1} END{exit bad}' "$OUT/device/device-map.tsv"
}

start_all_samplers() {
  local ip leaves tpid helper="$OUT/provenance/t61-remote-resource-sampler.sh"
  local local_sampler="$OUT/provenance/t61-local-sampler.sh"
  for ip in "${TIKV_IPS[@]}"; do
    "${SCP_BASE[@]}" "$helper" "$ip:/tmp/t61-remote-resource-sampler.sh" >/dev/null
    ssh_tikv "$ip" 'command -v iostat; command -v stdbuf; chmod 700 /tmp/t61-remote-resource-sampler.sh; LC_ALL=C bash /tmp/t61-remote-resource-sampler.sh --self-test' > "$OUT/preflight/remote-helper-${ip}.txt"
  done

  start_sampler client-runtime bash "$local_sampler" client-runtime "$OUT" "$RUN_ID" "$CLIENT_RE"
  start_sampler client-host bash "$local_sampler" client-host "$OUT"

  for ip in "${TIKV_IPS[@]}"; do
    start_sampler "tikv-metrics-$ip" bash "$local_sampler" tikv-metrics "$OUT" "$RUN_ID" "$ip" "$TIKV_RE"
  done

  for ip in "${TIKV_IPS[@]}"; do
    leaves=$(awk -F '\t' -v node="$ip" '$1==node{print $8}' "$OUT/device/device-map.tsv" | tr ',' '\n' | sort -u | xargs -n1 basename | tr '\n' ' ')
    [[ -n "$leaves" ]] || return 1
    start_sampler "tikv-device-$ip" bash "$local_sampler" bridge-device "$OUT" "$ip" $leaves

    tpid=$(ssh_tikv "$ip" 'pgrep -x tikv-server')
    [[ "$tpid" =~ ^[0-9]+$ ]] || return 1
    start_sampler "tikv-host-$ip" bash "$local_sampler" bridge-host "$OUT" "$ip" "$tpid"
  done

  start_sampler ceph bash "$local_sampler" ceph "$OUT"
  start_sampler pool bash "$local_sampler" pool "$OUT" "$OBJ_HARD"
  (( ${#SAMPLER_NAMES[@]} == 13 ))
}

validate_preflight() {
  local start=$(date +%s) deadline=$((SECONDS + 121)) rc
  printf '%s\n' "$start" > "$OUT/preflight/start-epoch.txt"
  sleep 5  # grace period for SSH-based samplers to establish connections
  while (( SECONDS < deadline )); do check_samplers || return 1; sleep 5; done
  set +e
  python3 "$OUT/provenance/t61-validate-evidence.py" --preflight "$OUT" "$start" > "$OUT/preflight/validator-output.txt" 2>&1
  rc=$?
  set -e
  return "$rc"
}

capture_tikv_processes() {
  local label=$1 ip
  : > "$OUT/fingerprint/tikv-process-${label}.tsv"
  for ip in "${TIKV_IPS[@]}"; do
    ssh_tikv "$ip" 'pid=$(pgrep -x tikv-server); [[ "$pid" =~ ^[0-9]+$ ]] || exit 1; printf "%s\t%s\t%s\n" "$pid" "$(awk "{print \$22}" /proc/$pid/stat)" "$(md5sum /proc/$pid/exe | awk "{print \$1}")"' \
      | awk -v node="$ip" -F '\t' '{print node"\t"$0}' >> "$OUT/fingerprint/tikv-process-${label}.tsv"
  done
}

log "=== T61 03-20B-R2 start run_id=$RUN_ID ==="
{
  printf 'skill_ack=%s\nuser_auth=%s\n' "$T61_SKILL_ACK" "$T61_USER_AUTH"
  printf 'planned_arm_count=1\nconfig_change=0\nrestart=0\nlayout_change=0\nmount_kill=0\nauto_retry=0\n'
} > "$OUT/skill-check-pre.txt"

for required in "$BIN" "$SYS_CONF" "$TASK_FILE" "$SCRIPT_DIR/t61-remote-resource-sampler.sh" "$SCRIPT_DIR/t61-local-sampler.sh" "$SCRIPT_DIR/t61-validate-evidence.py" "$SCRIPT_DIR/t61-gate0-offline.sh" "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$SCRIPT_DIR/t56-validate-jobfiles.sh"; do
  [[ -f "$required" ]] || { record_stop S01 "missing $required"; exit 5; }
done
[[ "$(md5sum "$BIN" | awk '{print $1}')" == "$BIN_MD5" ]] || { record_stop S01 binary-md5; exit 5; }
[[ "$(md5sum "$SYS_CONF" | awk '{print $1}')" == "$SYS_CONF_MD5" ]] || { record_stop S01 ceph-conf-md5; exit 5; }

cp "$0" "$OUT/provenance/"
cp "$TASK_FILE" "$OUT/provenance/"
cp "$SCRIPT_DIR/t61-remote-resource-sampler.sh" "$SCRIPT_DIR/t61-local-sampler.sh" "$SCRIPT_DIR/t61-validate-evidence.py" "$SCRIPT_DIR/t61-gate0-offline.sh" "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$SCRIPT_DIR/t56-validate-jobfiles.sh" "$OUT/provenance/"
(cd "$OUT/provenance" && md5sum ./* > MD5SUMS)

mountpoint -q "$MNT" && { record_stop S00 "mount already exists; untouched"; exit 4; }
pgrep -x fio >/dev/null && { record_stop S00 "foreign fio exists; untouched"; exit 4; }
[[ "$(sudo ceph health)" == HEALTH_OK ]] || { record_stop S02 ceph-health; exit 5; }
mapfile -t OSD_IDS < <(sudo ceph osd ls)
(( ${#OSD_IDS[@]} == 6 )) || { record_stop S02 "expected exactly 6 OSD, got ${#OSD_IDS[@]}"; exit 5; }
printf '%s\n' "${OSD_IDS[@]}" > "$OUT/fingerprint/osd-ids.txt"
sudo ceph osd dump > "$OUT/fingerprint/osd-dump-pre.txt"
cp "$SYS_CONF" "$OUT/fingerprint/ceph.conf.system"
df -Pk /tmp "$ARCHIVE_DIR" > "$OUT/fingerprint/space-pre.txt"
(( $(df -Pk /tmp | awk 'NR==2{print $4}') >= 4194304 )) || { record_stop S01 'tmp free <4GiB'; exit 5; }

cp "$SYS_CONF" "$PRIVATE_CONF"
printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
export CEPH_CONF="$PRIVATE_CONF"

MOUNT_OWNED=1
"$BIN" mount -d "${MOUNT_OPTS[@]}" "$META" "$MNT" > "$OUT/mount.log" 2>&1
sleep 10
mountpoint -q "$MNT" || { record_stop S03 mount-failed; exit 6; }
MOUNT_PID=$(find_mount_pid) || { record_stop S03 mount-pid-ambiguous; exit 6; }
MOUNT_START=$(awk '{print $22}' "/proc/$MOUNT_PID/stat")
grep -q " $MNT .*max_read=262144" /proc/mounts || { record_stop S03 max-read; exit 6; }
PROC_CONF=$(tr '\0' '\n' < "/proc/$MOUNT_PID/environ" | awk -F= '$1=="CEPH_CONF"{print $2}')
[[ "$PROC_CONF" == "$PRIVATE_CONF" ]] || { record_stop S03 private-conf-not-in-mount; exit 6; }
[[ $(grep -c 'ms_async_op_threads = 8' "$PROC_CONF") -eq 1 ]] || { record_stop S03 msgr-thread-conf; exit 6; }
{
  printf 'pid=%s starttime=%s\n' "$MOUNT_PID" "$MOUNT_START"
  md5sum "/proc/$MOUNT_PID/exe"
  grep " $MNT " /proc/mounts
  printf 'private_conf_md5=%s\n' "$(md5sum "$PRIVATE_CONF" | awk '{print $1}')"
} > "$OUT/fingerprint/mount-pre.txt"

stat_all_files > "$OUT/files/pre.tsv"
validate_layout_file "$OUT/files/pre.tsv" || { record_stop S03 layout; exit 6; }
bash "$SCRIPT_DIR/t56-gen-jobfiles.sh" "$OUT/jobfiles" > "$OUT/jobfiles-generate.log"
bash "$SCRIPT_DIR/t56-validate-jobfiles.sh" "$OUT/jobfiles" > "$OUT/jobfiles-validate.log"
cp "$OUT/jobfiles/B0.fio" "$OUT/arm/B0.fio"
[[ "$(md5sum "$OUT/arm/B0.fio" | awk '{print $1}')" == "$B0_MD5" ]] || { record_stop S01 b0-md5; exit 5; }

map_devices || { record_stop S04 device-map; exit 6; }
capture_tikv_processes pre || { record_stop S04 tikv-process; exit 6; }
find_osd_keys || { record_stop S05 osd-keys; exit 6; }

for ip in "${TIKV_IPS[@]}"; do
  curl -fsS --connect-timeout 3 --max-time 5 "http://${ip}:20180/metrics" | gzip > "$OUT/metrics-full/tikv-${ip}-pre.prom.gz"
done
curl -fsS --connect-timeout 3 --max-time 5 http://127.0.0.1:9567/metrics | gzip > "$OUT/metrics-full/client-pre.prom.gz"

start_all_samplers || { record_stop S08 sampler-start; exit 7; }
validate_preflight || { record_stop S08 strict-preflight; exit 7; }
reset_to_gate preload || { record_stop S06 preload-reset; exit 7; }
check_samplers || { record_stop S08 sampler-before-arm; exit 7; }
mount_identity_ok || { record_stop S09 mount-before-arm; exit 7; }

stat_all_files > "$OUT/files/pre-arm.tsv"
validate_layout_file "$OUT/files/pre-arm.tsv" || { record_stop S03 pre-arm-layout; exit 7; }
layout_signature "$OUT/files/pre.tsv" > "$OUT/files/pre.signature.tsv"
layout_signature "$OUT/files/pre-arm.tsv" > "$OUT/files/pre-arm.signature.tsv"
cmp -s "$OUT/files/pre.signature.tsv" "$OUT/files/pre-arm.signature.tsv" || { record_stop S13 pre-arm-layout-changed; exit 7; }
ARM_COUNT=1
printf '%s\tD-B256\tpre\n' "$(date +%s)" >> "$OUT/phase.tsv"
setsid fio "$OUT/arm/B0.fio" --write_bw_log="$OUT/arm/bw/D-B256" > "$OUT/arm/fio.stdout" 2> "$OUT/arm/fio.stderr" &
FIO_PID=$!
FIO_PGID=$(ps -o pgid= -p "$FIO_PID" | tr -d ' ')
[[ "$FIO_PGID" == "$FIO_PID" ]] || { record_stop S10 "fio private PGID failed"; stop_unregistered_fio_pid "$FIO_PID"; exit 8; }
FIO_START=$(date +%s)
printf '%s\n' "$FIO_PID" > "$OUT/arm/fio.pid"
printf '%s\n' "$FIO_PGID" > "$OUT/arm/fio.pgid"
printf '%s\tD-B256\tfio_start pid=%s pgid=%s epoch=%s\n' "$FIO_START" "$FIO_PID" "$FIO_PGID" "$FIO_START" >> "$OUT/phase.tsv"
log "D-B256 started pid=$FIO_PID pgid=$FIO_PGID"

while pid_alive "$FIO_PID"; do
  sleep 2
  if [[ -f "$OUT/STOP.txt" ]]; then record_stop S07 watchdog; stop_fio_for_watchdog; break; fi
  if ! mount_identity_ok; then record_stop S09 mount-changed; stop_fio_for_watchdog; break; fi
  if ! check_samplers; then record_stop S09 sampler-failed; stop_fio_for_watchdog; break; fi
done
set +e
wait "$FIO_PID"
FIO_RC=$?
set -e
printf '%s\n' "$FIO_RC" > "$OUT/arm/fio.rc"
printf '%s\tD-B256\tfio_end rc=%s\n' "$(date +%s)" "$FIO_RC" >> "$OUT/phase.tsv"
FIO_PID=""
FIO_PGID=""

bw_logs=$(find "$OUT/arm/bw" -type f -name 'D-B256_bw.*.log' | wc -l)
(( FIO_RC == 0 && bw_logs == 256 && FIO_FORCED == 0 )) || record_stop S10 "fio_rc=$FIO_RC bw_logs=$bw_logs forced=$FIO_FORCED"
grep -q 'err= 0' "$OUT/arm/fio.stdout" || record_stop S10 'fio stdout lacks err=0'

set +e
python3 "$OUT/provenance/t61-validate-evidence.py" --formal "$OUT" "$FIO_START" > "$OUT/coverage-output.txt" 2>&1
COVERAGE_RC=$?
set -e
(( COVERAGE_RC == 0 )) || record_stop S11 "formal coverage rc=$COVERAGE_RC"

stat_all_files > "$OUT/files/post.tsv"
validate_layout_file "$OUT/files/post.tsv" || record_stop S03 post-layout
layout_signature "$OUT/files/post.tsv" > "$OUT/files/post.signature.tsv"
cmp -s "$OUT/files/pre.signature.tsv" "$OUT/files/post.signature.tsv" || record_stop S13 post-layout-changed
curl -fsS --connect-timeout 3 --max-time 5 http://127.0.0.1:9567/metrics | gzip > "$OUT/metrics-full/client-post.prom.gz" || record_stop S09 client-post-metrics
for ip in "${TIKV_IPS[@]}"; do
  curl -fsS --connect-timeout 3 --max-time 5 "http://${ip}:20180/config" > "$OUT/device/$ip/tikv-config-post.json" || record_stop S09 "post config $ip"
  cmp -s "$OUT/device/$ip/tikv-config-pre.json" "$OUT/device/$ip/tikv-config-post.json" || record_stop S13 "TiKV config changed $ip"
  curl -fsS --connect-timeout 3 --max-time 5 "http://${ip}:20180/metrics" | gzip > "$OUT/metrics-full/tikv-${ip}-post.prom.gz" || record_stop S09 "post metrics $ip"
done
capture_tikv_processes post || record_stop S09 tikv-process-post
cmp -s "$OUT/fingerprint/tikv-process-pre.tsv" "$OUT/fingerprint/tikv-process-post.tsv" || record_stop S13 tikv-restart
[[ "$(md5sum "$SYS_CONF" | awk '{print $1}')" == "$SYS_CONF_MD5" ]] || record_stop S13 ceph-conf-change
sudo ceph osd dump > "$OUT/fingerprint/osd-dump-post.txt"

reset_to_gate final || record_stop S12 final-reset
stop_samplers
verify_remote_sampler_cleanup || record_stop S12 remote-sampler-remains
SAMPLER_NAMES=()
SAMPLER_PIDS=()
SAMPLER_PGIDS=()

mount_identity_ok || record_stop S09 mount-post
{
  printf 'pid=%s starttime=%s\n' "$MOUNT_PID" "$MOUNT_START"
  md5sum "/proc/$MOUNT_PID/exe" 2>/dev/null || true
  grep " $MNT " /proc/mounts || true
} > "$OUT/fingerprint/mount-post.txt"

if ! graceful_unmount; then record_stop S12 "graceful unmount failed; mount preserved"; fi
if (( SAMPLER_FORCE_KILL != 0 )); then record_stop S12 sampler-force-kill; fi
if [[ -z "$STOP_CODE" ]]; then
  log "=== T61 SUCCESS ==="
  write_skill_post
  trap - EXIT INT TERM
  finalize_archive ""
  rmdir "$LOCK_DIR" 2>/dev/null || true
  exit 0
fi

log "=== T61 INVALID stop_code=$STOP_CODE ==="
write_skill_post
trap - EXIT INT TERM
finalize_archive -ABORT
rmdir "$LOCK_DIR" 2>/dev/null || true
exit 9
