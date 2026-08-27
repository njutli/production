#!/usr/bin/env bash
# Node-local temporary PD/TiKV lifecycle for 03-22b. No sudo is used here.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
NODE_IP=${5:-}
t65_check_run_id "$RUN_ID"
t65_check_cluster "$CLUSTER"
t65_check_instance "$INSTANCE"
SUFFIX=$(t65_node_suffix "$NODE_IP")
LOWER=$(t65_cluster_lower "$CLUSTER")
BASE="/mnt/jfs-t65-${RUN_ID}"
WORK="/tmp/jfs-t65-${RUN_ID}-${INSTANCE}-${LOWER}"
PD_CONFIG="$WORK/pd.toml"
TIKV_CONFIG="$WORK/tikv.toml"
PD_PIDFILE="$WORK/pd.pid.tsv"
TIKV_PIDFILE="$WORK/tikv.pid.tsv"
PD_BIN=/opt/pd/bin/pd-server
TIKV_BIN=/opt/tikv/bin/tikv-server
HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
[[ "$HOST_IP" == "$NODE_IP" ]] || t65_die "host identity mismatch: expected=$NODE_IP actual=${HOST_IP:-unknown}"
t65_assert_abs_scoped_path "$BASE" "$RUN_ID"
t65_assert_abs_scoped_path "$WORK" "$RUN_ID"

if [[ "$CLUSTER" == A1 ]]; then
  KV="$BASE/a1-shared/runs/$INSTANCE/kv"
  WAL="$BASE/a1-shared/runs/$INSTANCE/wal"
  RAFT="$BASE/a1-shared/runs/$INSTANCE/raft-engine"
else
  KV="$BASE/b1-kv/runs/$INSTANCE/kv"
  WAL="$BASE/b1-logs/runs/$INSTANCE/wal"
  RAFT="$BASE/b1-logs/runs/$INSTANCE/raft-engine"
fi
PD_DATA="$BASE/pd/runs/$INSTANCE/pd-$SUFFIX"
for path in "$KV" "$WAL" "$RAFT" "$PD_DATA"; do t65_assert_abs_scoped_path "$path" "$RUN_ID"; done

port_free() {
  ! ss -Hlnpt "sport = :$1" 2>/dev/null | grep -q .
}

fingerprint_pid() {
  local pid=$1 expected_bin=$2 expected_cfg=$3
  [[ "$pid" =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
  [[ $(readlink -f "/proc/$pid/exe") == "$expected_bin" ]] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "--config=$expected_cfg" || return 1
  printf '%s\t%s\t%s\t%s\n' "$pid" "$(awk '{print $22}' "/proc/$pid/stat")" \
    "$(md5sum "$expected_bin" | awk '{print $1}')" "$expected_cfg"
}

read_pidfile() {
  local file=$1 expected_bin=$2 expected_cfg=$3 pid start md5 cfg actual
  [[ -s "$file" ]] || return 1
  IFS=$'\t' read -r pid start md5 cfg < "$file"
  [[ "$cfg" == "$expected_cfg" ]] || return 1
  actual=$(fingerprint_pid "$pid" "$expected_bin" "$expected_cfg") || return 1
  [[ "$actual" == "$pid"$'\t'"$start"$'\t'"$md5"$'\t'"$cfg" ]] || return 1
  printf '%s\n' "$pid"
}

render() {
  [[ ${T65_INSTANCE_AUTH:-} == "03-22b-instance-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t65_die "set exact T65_INSTANCE_AUTH=03-22b-instance-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  t65_record_authorization "$RUN_ID" "instance-render-$CLUSTER-$INSTANCE" "$T65_INSTANCE_AUTH"
  [[ -x "$PD_BIN" && -x "$TIKV_BIN" ]] || t65_die 'PD/TiKV binaries missing or not executable'
  [[ -s "/tmp/jfs-t65-${RUN_ID}-storage.tsv" ]] || t65_die 'storage state missing'
  [[ -s "/tmp/jfs-t65-${RUN_ID}-${CLUSTER}-${INSTANCE}-activation.tsv" ]] || t65_die 'matching activation state missing'
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || t65_die 'production tikv unit is active'
  [[ ! -e "$WORK" ]] || t65_die "instance work directory already exists: $WORK"
  for port in "$T65_PD_CLIENT_PORT" "$T65_PD_PEER_PORT" "$T65_TIKV_PORT" "$T65_TIKV_STATUS_PORT"; do
    port_free "$port" || t65_die "port already busy: $port"
  done
  mkdir -p "$WORK" "$KV" "$WAL" "$RAFT" "$PD_DATA"
  umask 077
  local name="t65-${INSTANCE,,}-${SUFFIX}"
  local initial="t65-${INSTANCE,,}-150=http://10.20.1.150:${T65_PD_PEER_PORT},t65-${INSTANCE,,}-151=http://10.20.1.151:${T65_PD_PEER_PORT},t65-${INSTANCE,,}-152=http://10.20.1.152:${T65_PD_PEER_PORT}"
  printf '%s\n' \
    "name = \"$name\"" \
    "data-dir = \"$PD_DATA\"" \
    "client-urls = \"http://0.0.0.0:${T65_PD_CLIENT_PORT}\"" \
    "advertise-client-urls = \"http://${NODE_IP}:${T65_PD_CLIENT_PORT}\"" \
    "peer-urls = \"http://0.0.0.0:${T65_PD_PEER_PORT}\"" \
    "advertise-peer-urls = \"http://${NODE_IP}:${T65_PD_PEER_PORT}\"" \
    "initial-cluster = \"$initial\"" \
    'initial-cluster-state = "new"' \
    "initial-cluster-token = \"jfs-t65-${RUN_ID}-${INSTANCE}\"" \
    '[log]' 'level = "info"' \
    '[replication]' 'max-replicas = 3' > "$PD_CONFIG"

  printf '%s\n' \
    '[server]' \
    "addr = \"0.0.0.0:${T65_TIKV_PORT}\"" \
    "advertise-addr = \"${NODE_IP}:${T65_TIKV_PORT}\"" \
    "status-addr = \"0.0.0.0:${T65_TIKV_STATUS_PORT}\"" \
    "advertise-status-addr = \"${NODE_IP}:${T65_TIKV_STATUS_PORT}\"" \
    "labels = { host = \"$name\" }" \
    '[storage]' "data-dir = \"$KV\"" 'reserve-space = "5GiB"' \
    '[raftstore]' 'sync-log = true' \
    '[raft-engine]' 'enable = true' "dir = \"$RAFT\"" \
    '[rocksdb]' "wal-dir = \"$WAL\"" \
    'max-background-jobs = 9' 'max-background-flushes = 3' 'max-sub-compactions = 3' \
    'rate-bytes-per-sec = "10GiB"' 'rate-limiter-auto-tuned = true' \
    '[rocksdb.titan]' 'enabled = false' \
    '[rocksdb.defaultcf]' 'block-size = "64KiB"' \
    'compression-per-level = ["no", "no", "lz4", "lz4", "lz4", "zstd", "zstd"]' \
    'target-file-size-base = "256MiB"' \
    '[rocksdb.writecf]' 'block-size = "64KiB"' \
    'compression-per-level = ["no", "no", "lz4", "lz4", "lz4", "zstd", "zstd"]' \
    '[rocksdb.lockcf]' 'block-size = "64KiB"' \
    'compression-per-level = ["no", "no", "no", "no", "no", "no", "no"]' \
    '[pd]' \
    "endpoints = [\"10.20.1.150:${T65_PD_CLIENT_PORT}\", \"10.20.1.151:${T65_PD_CLIENT_PORT}\", \"10.20.1.152:${T65_PD_CLIENT_PORT}\"]" \
    '[log]' 'level = "info"' \
    '[log.file]' "filename = \"$WORK/tikv.log\"" \
    '[storage.block-cache]' 'capacity = "4GiB"' > "$TIKV_CONFIG"
  printf 'RENDER_PASS node=%s cluster=%s instance=%s\n' "$NODE_IP" "$CLUSTER" "$INSTANCE"
}

start_one() {
  local service=$1 bin config pidfile logfile pid fp
  local action="start-$service" expected="03-22b-cluster-start-${service}-${RUN_ID}-${CLUSTER}-${INSTANCE}"
  t65_check_auth "${T65_CLUSTER_ACTION_AUTH:-}" "$expected"
  t65_record_authorization "$RUN_ID" "$action-$CLUSTER-$INSTANCE" "$expected"
  case "$service" in
    pd) bin=$PD_BIN; config=$PD_CONFIG; pidfile=$PD_PIDFILE; logfile="$WORK/pd.stdout";;
    tikv) bin=$TIKV_BIN; config=$TIKV_CONFIG; pidfile=$TIKV_PIDFILE; logfile="$WORK/tikv.stdout";;
    *) t65_die 'service must be pd or tikv';;
  esac
  [[ -s "$config" ]] || t65_die "missing config: $config"
  [[ ! -e "$pidfile" ]] || t65_die "pidfile already exists: $pidfile"
  if [[ "$service" == pd ]]; then
    port_free "$T65_PD_CLIENT_PORT" && port_free "$T65_PD_PEER_PORT" || t65_die 'PD port busy'
  else
    port_free "$T65_TIKV_PORT" && port_free "$T65_TIKV_STATUS_PORT" || t65_die 'TiKV port busy'
  fi
  (ulimit -n 1000000; nohup setsid "$bin" --config="$config" > "$logfile" 2>&1 < /dev/null & printf '%s\n' "$!" > "$WORK/$service.launch-pid")
  pid=$(<"$WORK/$service.launch-pid")
  sleep 2
  fp=$(fingerprint_pid "$pid" "$bin" "$config") || {
    printf 'START_FAILED service=%s pid=%s log=%s\n' "$service" "$pid" "$logfile" >&2
    tail -80 "$logfile" >&2 || true
    exit 42
  }
  printf '%s\n' "$fp" > "$pidfile"
  printf 'START_PASS service=%s pid=%s node=%s instance=%s\n' "$service" "$pid" "$NODE_IP" "$INSTANCE"
}

verify() {
  local pd_pid tikv_pid
  pd_pid=$(read_pidfile "$PD_PIDFILE" "$PD_BIN" "$PD_CONFIG") || t65_die 'PD fingerprint invalid'
  tikv_pid=$(read_pidfile "$TIKV_PIDFILE" "$TIKV_BIN" "$TIKV_CONFIG") || t65_die 'TiKV fingerprint invalid'
  curl -fsS --connect-timeout 2 --max-time 5 "http://${NODE_IP}:${T65_PD_CLIENT_PORT}/pd/api/v1/health" >/dev/null || t65_die 'PD health endpoint failed'
  curl -fsS --connect-timeout 2 --max-time 5 "http://${NODE_IP}:${T65_TIKV_STATUS_PORT}/config" > "$WORK/tikv-config-live.json" || t65_die 'TiKV config endpoint failed'
  printf 'VERIFY_PASS node=%s cluster=%s instance=%s pd_pid=%s tikv_pid=%s\n' "$NODE_IP" "$CLUSTER" "$INSTANCE" "$pd_pid" "$tikv_pid"
}

stop_one() {
  local service=$1 bin config pidfile pid deadline
  local action="stop-$service" expected="03-22b-cluster-stop-${service}-${RUN_ID}-${CLUSTER}-${INSTANCE}"
  t65_check_auth "${T65_CLUSTER_ACTION_AUTH:-}" "$expected"
  t65_record_authorization "$RUN_ID" "$action-$CLUSTER-$INSTANCE" "$expected"
  case "$service" in
    pd) bin=$PD_BIN; config=$PD_CONFIG; pidfile=$PD_PIDFILE;;
    tikv) bin=$TIKV_BIN; config=$TIKV_CONFIG; pidfile=$TIKV_PIDFILE;;
    *) t65_die 'service must be pd or tikv';;
  esac
  pid=$(read_pidfile "$pidfile" "$bin" "$config") || t65_die "$service PID fingerprint invalid; refuse signal"
  kill -TERM "$pid"
  deadline=$((SECONDS + 60))
  while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    t65_die "$service pid=$pid did not exit after TERM; preserved for manual analysis (no KILL sent)"
  fi
  mv "$pidfile" "$pidfile.stopped-$(date +%s)"
  printf 'STOP_PASS service=%s pid=%s node=%s instance=%s\n' "$service" "$pid" "$NODE_IP" "$INSTANCE"
}

case "$ACTION" in
  render) render;;
  start-pd) start_one pd;;
  start-tikv) start_one tikv;;
  verify) verify;;
  stop-tikv) stop_one tikv;;
  stop-pd) stop_one pd;;
  *) t65_die 'usage: t65-node-cluster.sh render|start-pd|start-tikv|verify|stop-tikv|stop-pd RUN_ID A1|B1 INSTANCE NODE_IP';;
esac
