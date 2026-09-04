#!/usr/bin/env bash
# 157-side serial orchestrator for temporary PD/TiKV only.
# It never stops production, creates storage, runs fio, or performs rollback.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-runtime-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}; CLUSTER=${3:-}; INSTANCE=${4:-}
s04a1_check_run_id "$RUN_ID"; s04a1_check_cluster "$CLUSTER"; s04a1_check_instance "$INSTANCE"
[[ $(s04a1_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || s04a1_die 'instance/cluster mapping mismatch'
case "$ACTION" in render|start-pd|start-tikv|verify|stop-tikv|stop-pd) ;; *) s04a1_die 'invalid cluster action';; esac
s04a1_make_ssh_array; s04a1_require_tools ssh scp curl python3 sha256sum

OUT="/tmp/production/opencode-04-2-${RUN_ID}/orchestration"
REMOTE_DIR="/tmp/jfs-s04a1-${RUN_ID}-scripts"
LOG="$OUT/${ACTION}-${CLUSTER}-${INSTANCE}.log"
STORAGE_INSTANCE=${S04A1_STORAGE_INSTANCE:-$INSTANCE}
s04a1_check_instance "$STORAGE_INSTANCE"
[[ $STORAGE_INSTANCE =~ ^R0[1-8]$ && $(s04a1_expected_cluster "$STORAGE_INSTANCE") == "$CLUSTER" ]] || s04a1_die 'invalid storage-instance binding'
s04a1_assert_abs_scoped_path "$REMOTE_DIR" "$RUN_ID"
mkdir -p "$OUT"
log() { printf '%s\t%s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

ssh_node() { local node=$1; shift; "${S04A1_SSH[@]}" "$node" "$@"; }
verify_remote_helpers() {
  local node=$1
  local name local_sha remote_sha
  for name in s04a1-runtime-common.sh s04a1-node-cluster.sh; do
    local_sha=$(sha256sum "$SCRIPT_DIR/$name" | awk '{print $1}')
    remote_sha=$(ssh_node "$node" "sha256sum '$REMOTE_DIR/$name'" | awk '{print $1}')
    [[ "$local_sha" == "$remote_sha" ]] || s04a1_die "remote helper SHA mismatch: node=$node file=$name"
  done
}

precheck_node() {
  local node=$1
  ssh_node "$node" bash -s -- "$RUN_ID" "$CLUSTER" "$INSTANCE" "$STORAGE_INSTANCE" "$node" <<'REMOTE'
set -euo pipefail
run=$1; arm=$2; instance=$3; storage_instance=$4; expected=$5
actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
[[ "$actual" == "$expected" ]] || exit 42
[[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || { echo production_tikv_active >&2; exit 42; }
node=${expected##*.}
[[ -s "/tmp/s04a1-${run}-storage-active-${storage_instance}-${node}.tsv" ]] || { echo activation_state_missing >&2; exit 42; }
for p in 12379 12380 30160 30180; do
  if ss -Hlnpt "sport = :$p" 2>/dev/null | grep -q .; then echo "temporary_port_busy=$p" >&2; exit 42; fi
done
REMOTE
}

cluster_action() {
  local sub=$1 node auth="04-2-instance-${RUN_ID}-${INSTANCE}-${CLUSTER}" action_auth
  for node in "${S04A1_NODES[@]}"; do
    if [[ "$sub" == render ]]; then precheck_node "$node"; fi
    verify_remote_helpers "$node"
    log "$sub node=$node arm=$CLUSTER instance=$INSTANCE"
    if [[ "$sub" == render ]]; then
      ssh_node "$node" "export S04A1_INSTANCE_AUTH='$auth' S04A1_STORAGE_INSTANCE='$STORAGE_INSTANCE'; bash '$REMOTE_DIR/s04a1-node-cluster.sh' render '$RUN_ID' '$CLUSTER' '$INSTANCE' '$node'" | tee -a "$LOG"
    elif [[ "$sub" == start-pd || "$sub" == start-tikv || "$sub" == stop-tikv || "$sub" == stop-pd ]]; then
      action_auth="04-2-cluster-${sub%-*}-${sub#*-}-${RUN_ID}-${CLUSTER}-${INSTANCE}"
      s04a1_check_auth "${S04A1_CLUSTER_ACTION_AUTH:-}" "$action_auth"
      ssh_node "$node" "export S04A1_CLUSTER_ACTION_AUTH='$action_auth' S04A1_STORAGE_INSTANCE='$STORAGE_INSTANCE'; bash '$REMOTE_DIR/s04a1-node-cluster.sh' '$sub' '$RUN_ID' '$CLUSTER' '$INSTANCE' '$node'" | tee -a "$LOG"
    else
      ssh_node "$node" "export S04A1_STORAGE_INSTANCE='$STORAGE_INSTANCE'; bash '$REMOTE_DIR/s04a1-node-cluster.sh' '$sub' '$RUN_ID' '$CLUSTER' '$INSTANCE' '$node'" | tee -a "$LOG"
    fi
  done
}

verify_global() {
  cluster_action verify
  local ready="$OUT/readiness-${INSTANCE}" deadline=$((SECONDS+240)) attempt=0 stable=0 epoch health stores health_ok stores_ok
  mkdir -p "$ready"; printf 'attempt\tepoch\thealth_ok\tstores_up\tstable\n' > "$ready/observations.tsv"
  while true; do
    attempt=$((attempt+1)); epoch=$(date +%s); health="$ready/health-${attempt}-${epoch}.json"; stores="$ready/stores-${attempt}-${epoch}.json"
    health_ok=0; stores_ok=0
    if curl -fsS --connect-timeout 3 --max-time 10 "http://10.20.1.150:${S04A1_PD_CLIENT_PORT}/pd/api/v1/health" > "$health" &&
      python3 - "$health" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert isinstance(d,list) and len(d)==3 and all(x.get('health') is True for x in d)
PY
    then health_ok=1; fi
    if curl -fsS --connect-timeout 3 --max-time 10 "http://10.20.1.150:${S04A1_PD_CLIENT_PORT}/pd/api/v1/stores" > "$stores" &&
      python3 - "$stores" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('stores',[]); assert len(s)==3 and all(x.get('store',{}).get('state_name')=='Up' for x in s)
PY
    then stores_ok=1; fi
    if ((health_ok && stores_ok)); then stable=$((stable+1)); else stable=0; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$attempt" "$epoch" "$health_ok" "$stores_ok" "$stable" >> "$ready/observations.tsv"
    log "readiness attempt=$attempt health=$health_ok stores=$stores_ok stable=$stable/3"
    ((stable>=3)) && break
    ((SECONDS<deadline)) || s04a1_die "global readiness timeout; evidence=$ready"
    sleep 10
  done
  log "GLOBAL_VERIFY_PASS arm=$CLUSTER instance=$INSTANCE samples=$attempt stable=3"
}

case "$ACTION" in
  verify) verify_global;;
  *) cluster_action "$ACTION";;
esac
