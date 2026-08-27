#!/usr/bin/env bash
# 157-side serial orchestrator for 03-22. It never performs a hidden rollback.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

ACTION=${1:-inventory}
RUN_ID=${2:-}
CLUSTER=${3:-A}
INSTANCE=${4:-SMOKE-A}
NODE_SCOPE=${5:-all}
t64_check_run_id "$RUN_ID"
t64_check_cluster "$CLUSTER"
t64_check_instance "$INSTANCE"
t64_make_ssh_array
t64_require_tools sshpass ssh scp curl sha256sum python3

OUT="/tmp/production/opencode-t3.22-${RUN_ID}"
mkdir -p "$OUT/orchestration"
LOG="$OUT/orchestration/${ACTION}-${CLUSTER}-${INSTANCE}-${NODE_SCOPE}.log"
REMOTE_DIR="/tmp/jfs-t64-${RUN_ID}-scripts"
t64_assert_abs_scoped_path "$REMOTE_DIR" "$RUN_ID"

log() { printf '%s\t%s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

ssh_node() {
  local node=$1
  shift
  "${T64_SSH[@]}" "$node" "$@"
}

upload_helpers() {
  local node=$1
  ssh_node "$node" "mkdir -p '$REMOTE_DIR'"
  "${T64_SCP[@]}" "$SCRIPT_DIR/t64-common.sh" "$SCRIPT_DIR/t64-node-storage.sh" \
    "$SCRIPT_DIR/t64-node-cluster.sh" "$SCRIPT_DIR/t64-recover-partial-storage.sh" \
    "$node:$REMOTE_DIR/"
}

production_fingerprint() {
  local node=$1 label=$2
  ssh_node "$node" 'set -euo pipefail
for svc in pd-server tikv-server; do
  ps -eo pid=,comm= | awk -v s="$svc" '\''$2==s{print $1}'\'' | while read -r pid; do
    printf "%s\t%s\t%s\t%s\n" "$svc" "$pid" "$(awk '\''{print $22}'\'' /proc/$pid/stat)" "$(readlink -f /proc/$pid/exe)"
  done
done
systemctl is-active pd tikv
findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE,OPTIONS
sha256sum /opt/pd/conf/pd.toml /opt/tikv/conf/tikv.toml' \
    > "$OUT/orchestration/production-${node}-${label}.txt"
}

check_production_unchanged() {
  local node=$1 label=$2
  production_fingerprint "$node" "$label"
  cmp -s "$OUT/orchestration/production-${node}-pre.txt" \
    "$OUT/orchestration/production-${node}-${label}.txt" ||
    t64_die "production fingerprint changed on $node at $label"
}

inventory() {
  ! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on 157; Stage I must not overlap a performance run'
  : > "$OUT/orchestration/inventory.tsv"
  local node
  for node in "${T64_NODES[@]}"; do
    log "inventory node=$node"
    production_fingerprint "$node" pre
    ssh_node "$node" 'set -euo pipefail
printf "host\t%s\n" "$(hostname -f 2>/dev/null || hostname)"
awk '\''/^(MemTotal|MemAvailable):/{print "mem\t"$1"\t"$2}'\'' /proc/meminfo
for p in 12379 12380 30160 30180; do ss -Hlnpt "sport = :$p" || true; done
findmnt -rn -t tmpfs,ext4 -o SOURCE,TARGET,FSTYPE | awk '\''$2 ~ /^\/mnt\/jfs-t64-/{print}'\''
sudo losetup -l -n -O NAME,BACK-FILE | awk '\''$2 ~ /^\/mnt\/jfs-t64-/{print}'\''
ps -eo pid=,comm=,args= | awk '\''$2=="fio" || (($2=="pd-server" || $2=="tikv-server" || $2=="juicefs") && $0 ~ /jfs-t64-/){print}'\''
df -B1 -T /mnt/jfs-tikv' >> "$OUT/orchestration/inventory.tsv"
  done
  log 'INVENTORY_PASS; stop for human review before any create action'
}

storage_nodes() {
  if [[ "$NODE_SCOPE" == all ]]; then
    printf '%s\n' "${T64_NODES[@]}"
  else
    t64_node_suffix "$NODE_SCOPE" >/dev/null
    printf '%s\n' "$NODE_SCOPE"
  fi
}

plan_storage_readonly() {
  local node=$1 ids uid gid lower base i role size backing fs img
  local -a roles sizes
  ids=$(ssh_node "$node" 'printf "%s\t%s\n" "$(id -u)" "$(id -g)"')
  IFS=$'\t' read -r uid gid <<< "$ids"
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || t64_die "invalid uid/gid from $node: $ids"
  lower=$(t64_cluster_lower "$CLUSTER")
  base="/mnt/jfs-t64-${RUN_ID}-${lower}"
  if [[ "$CLUSTER" == A ]]; then roles=(shared); sizes=(128G); else roles=(kv logs); sizes=(96G 32G); fi
  printf 'MODE=PLAN_ONLY\nnode=%s\nrun_id=%s\ncluster=%s\n' "$node" "$RUN_ID" "$CLUSTER" | tee -a "$LOG"
  printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$uid" "$gid" "$base" "$base/pd" | tee -a "$LOG"
  printf 'sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec t64-pd-%s-%s %q\n' "$RUN_ID" "$lower" "$base/pd" | tee -a "$LOG"
  printf 'sudo install -d -m 0700 -o %s -g %s %q  # reset ownership on mounted tmpfs root\n' "$uid" "$gid" "$base/pd" | tee -a "$LOG"
  for i in "${!roles[@]}"; do
    role=${roles[$i]}; size=${sizes[$i]}; backing="$base/backing-$role"; fs="$base/fs-$role"; img="$backing/t64-$role.img"
    printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$uid" "$gid" "$backing" "$fs" | tee -a "$LOG"
    printf 'sudo mount -t tmpfs -o size=%s,mode=0700,nodev,nosuid,noexec t64-%s-%s-%s %q\n' "$size" "$RUN_ID" "$lower" "$role" "$backing" | tee -a "$LOG"
    printf 'sudo install -d -m 0700 -o %s -g %s %q  # reset ownership on mounted tmpfs root\n' "$uid" "$gid" "$backing" | tee -a "$LOG"
    printf 'truncate -s %s %q\n' "$size" "$img" | tee -a "$LOG"
    printf 'sudo losetup --find --show --nooverlap %q\n' "$img" | tee -a "$LOG"
    printf 'sudo mkfs.ext4 -F -m 0 -T largefile -E lazy_itable_init=0,lazy_journal_init=0 <recorded-loop-device>\n' | tee -a "$LOG"
    printf 'sudo mount -o noatime,nodev,nosuid,nodiscard <recorded-loop-device> %q\n' "$fs" | tee -a "$LOG"
    printf 'sudo chown %s:%s %q\n' "$uid" "$gid" "$fs" | tee -a "$LOG"
  done
}

preflight_storage_readonly() {
  local node=$1
  ssh_node "$node" bash -s -- "$RUN_ID" "$CLUSTER" "$node" <<'REMOTE'
set -euo pipefail
export LC_ALL=C
run_id=$1; cluster=$2; expected_ip=$3
[[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}$ && ( "$cluster" == A || "$cluster" == B ) ]] || exit 42
lower=${cluster,,}
base="/mnt/jfs-t64-${run_id}-${lower}"
state="/tmp/jfs-t64-${run_id}-${lower}-storage.tsv"
audit="/tmp/jfs-t64-${run_id}-${lower}-storage.destroyed.tsv"
host_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
[[ "$host_ip" == "$expected_ip" ]] || { printf 'host mismatch expected=%s actual=%s\n' "$expected_ip" "${host_ip:-unknown}" >&2; exit 42; }
for tool in awk findmnt lsblk losetup mountpoint truncate mkfs.ext4 stat sudo ss; do command -v "$tool" >/dev/null || { echo "missing=$tool" >&2; exit 42; }; done
[[ ! -e "$state" && ! -e "$audit" && ! -e "$base" ]] || { echo "existing t64 state/path" >&2; exit 42; }
for port in 12379 12380 30160 30180; do
  ! ss -Hlnpt "sport = :$port" 2>/dev/null | grep -q . || { echo "busy_port=$port" >&2; exit 42; }
done
mem_kib=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
(( mem_kib >= 402653184 )) || { echo "MemAvailable_KiB=$mem_kib" >&2; exit 42; }
! pgrep -x fio >/dev/null || { echo foreign_fio >&2; exit 42; }
foreign=$(ps -eo comm=,args= | awk -v token="jfs-t64-${run_id}" 'index($0,token)>0 && ($1=="pd-server" || $1=="tikv-server" || $1=="juicefs"){print;exit}')
[[ -z "$foreign" ]] || { echo "foreign_t64=$foreign" >&2; exit 42; }
printf 'PREFLIGHT_PASS node=%s cluster=%s MemAvailable_KiB=%s mode=READ_ONLY\n' "$expected_ip" "$cluster" "$mem_kib"
REMOTE
}

node_storage_action() {
  local subaction=$1 node auth_name auth_value
  if [[ "$subaction" == plan || "$subaction" == preflight ]]; then
    ! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on 157; Stage I must not overlap a performance run'
  fi
  while read -r node; do
    log "$subaction cluster=$CLUSTER node=$node"
    case "$subaction" in
      plan)
        plan_storage_readonly "$node"
        ;;
      preflight)
        preflight_storage_readonly "$node" | tee -a "$LOG"
        ;;
      create)
        ! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on 157; create-storage must not overlap a performance run'
        [[ "$NODE_SCOPE" != all ]] || t64_die 'create-storage requires one explicit NODE_SCOPE; multi-node mutation is forbidden'
        auth_name=T64_CREATE_AUTH
        auth_value="03-22-create-${RUN_ID}-${CLUSTER}-${node}"
        [[ ${T64_CREATE_AUTH:-} == "$auth_value" ]] || t64_die "set exact T64_CREATE_AUTH=$auth_value"
        upload_helpers "$node"
        ssh_node "$node" "export T64_CREATE_AUTH='$auth_value'; bash '$REMOTE_DIR/t64-node-storage.sh' create '$RUN_ID' '$CLUSTER' '$node'" | tee -a "$LOG"
        ;;
      destroy)
        [[ "$NODE_SCOPE" != all ]] || t64_die 'destroy-storage requires one explicit NODE_SCOPE; multi-node mutation is forbidden'
        auth_name=T64_DESTROY_AUTH
        auth_value="03-22-destroy-${RUN_ID}-${CLUSTER}-${node}"
        [[ ${T64_DESTROY_AUTH:-} == "$auth_value" ]] || t64_die "set exact T64_DESTROY_AUTH=$auth_value"
        upload_helpers "$node"
        ssh_node "$node" "export T64_DESTROY_AUTH='$auth_value'; bash '$REMOTE_DIR/t64-node-storage.sh' destroy '$RUN_ID' '$CLUSTER' '$node'" | tee -a "$LOG"
        ;;
      *)
        upload_helpers "$node"
        ssh_node "$node" "bash '$REMOTE_DIR/t64-node-storage.sh' '$subaction' '$RUN_ID' '$CLUSTER' '$node'" | tee -a "$LOG"
        ;;
    esac
    check_production_unchanged "$node" "post-${subaction}-${CLUSTER}"
  done < <(storage_nodes)
}

partial_recovery_action() {
  local subaction=$1 node auth_value
  ! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on 157; partial recovery must not overlap a performance run'
  [[ "$NODE_SCOPE" != all ]] || t64_die 'partial recovery requires one explicit NODE_SCOPE'
  node=$NODE_SCOPE
  t64_node_suffix "$node" >/dev/null
  if [[ "$subaction" == recover ]]; then
    auth_value="03-22-recover-partial-${RUN_ID}-${CLUSTER}-${node}"
    [[ ${T64_PARTIAL_RECOVERY_AUTH:-} == "$auth_value" ]] ||
      t64_die "set exact T64_PARTIAL_RECOVERY_AUTH=$auth_value"
  fi
  upload_helpers "$node"
  if [[ "$subaction" == recover ]]; then
    ssh_node "$node" "export T64_PARTIAL_RECOVERY_AUTH='$auth_value'; bash '$REMOTE_DIR/t64-recover-partial-storage.sh' recover '$RUN_ID' '$CLUSTER' '$node'" | tee -a "$LOG"
  else
    ssh_node "$node" "bash '$REMOTE_DIR/t64-recover-partial-storage.sh' inspect '$RUN_ID' '$CLUSTER' '$node'" | tee -a "$LOG"
  fi
  check_production_unchanged "$node" "post-partial-${subaction}-${CLUSTER}"
}

cluster_action() {
  local subaction=$1 node auth="03-22-instance-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  for node in "${T64_NODES[@]}"; do
    upload_helpers "$node"
    log "$subaction cluster=$CLUSTER instance=$INSTANCE node=$node"
    if [[ "$subaction" == render ]]; then
      ssh_node "$node" "export T64_INSTANCE_AUTH='$auth'; bash '$REMOTE_DIR/t64-node-cluster.sh' render '$RUN_ID' '$CLUSTER' '$INSTANCE' '$node'" | tee -a "$LOG"
    else
      ssh_node "$node" "bash '$REMOTE_DIR/t64-node-cluster.sh' '$subaction' '$RUN_ID' '$CLUSTER' '$INSTANCE' '$node'" | tee -a "$LOG"
    fi
  done
}

verify_global() {
  cluster_action verify
  local ready_dir="$OUT/orchestration/readiness-${INSTANCE}"
  local deadline=$((SECONDS + 180)) attempt=0 stable=0 stamp health_file stores_file
  local health_ok stores_ok
  mkdir -p "$ready_dir"
  : > "$ready_dir/observations.tsv"
  printf 'attempt\tepoch\thealth_ok\tstores_up\tstable_count\n' >> "$ready_dir/observations.tsv"
  while true; do
    attempt=$((attempt + 1))
    stamp=$(date +%s)
    health_file=$(printf '%s/health-%03d-%s.json' "$ready_dir" "$attempt" "$stamp")
    stores_file=$(printf '%s/stores-%03d-%s.json' "$ready_dir" "$attempt" "$stamp")
    health_ok=0
    stores_ok=0
    if curl -fsS --connect-timeout 3 --max-time 10 \
      "http://10.20.1.150:${T64_PD_CLIENT_PORT}/pd/api/v1/health" > "$health_file" && \
      python3 - "$health_file" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert isinstance(d,list) and len(d)==3, d
assert all(x.get("health") is True for x in d), d
PY
    then
      health_ok=1
    fi
    if curl -fsS --connect-timeout 3 --max-time 10 \
      "http://10.20.1.150:${T64_PD_CLIENT_PORT}/pd/api/v1/stores" > "$stores_file" && \
      python3 - "$stores_file" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
stores=d.get("stores",[])
assert len(stores)==3, d
assert all(x.get("store",{}).get("state_name") == "Up" for x in stores), d
PY
    then
      stores_ok=1
    fi
    if (( health_ok == 1 && stores_ok == 1 )); then
      stable=$((stable + 1))
    else
      stable=0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$attempt" "$stamp" "$health_ok" "$stores_ok" "$stable" \
      >> "$ready_dir/observations.tsv"
    log "readiness cluster=$CLUSTER instance=$INSTANCE attempt=$attempt health=$health_ok stores=$stores_ok stable=$stable/3"
    if (( stable >= 3 )); then
      cp "$health_file" "$OUT/orchestration/pd-health-${INSTANCE}.json"
      cp "$stores_file" "$OUT/orchestration/pd-stores-${INSTANCE}.json"
      break
    fi
    (( SECONDS < deadline )) || t64_die "global readiness timeout after ${attempt} samples; evidence=$ready_dir"
    sleep 10
  done
  log "GLOBAL_VERIFY_PASS cluster=$CLUSTER instance=$INSTANCE samples=$attempt stable=3"
}

case "$ACTION" in
  inventory) inventory;;
  plan-storage) node_storage_action plan;;
  plan-destroy) node_storage_action plan-destroy;;
  preflight-storage) node_storage_action preflight;;
  create-storage) node_storage_action create;;
  verify-storage) node_storage_action verify;;
  inspect-partial-storage) partial_recovery_action inspect;;
  recover-partial-storage) partial_recovery_action recover;;
  render) cluster_action render;;
  start-pd) cluster_action start-pd;;
  start-tikv) cluster_action start-tikv;;
  verify) verify_global;;
  stop-tikv) cluster_action stop-tikv;;
  stop-pd) cluster_action stop-pd;;
  destroy-storage) node_storage_action destroy;;
  *) t64_die 'usage: ... ACTION RUN_ID A|B INSTANCE [all|NODE_IP]';;
esac
