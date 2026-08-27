#!/usr/bin/env bash
# Recover only a state-less, pre-loop create failure. This is intentionally
# separate from normal state-driven destroy and has its own authorization.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

ACTION=${1:-inspect}
RUN_ID=${2:-}
CLUSTER=${3:-}
NODE_IP=${4:-}
t64_check_run_id "$RUN_ID"
t64_check_cluster "$CLUSTER"
t64_node_suffix "$NODE_IP" >/dev/null
t64_require_tools awk find findmnt losetup mountpoint pgrep sort stat sudo

LOWER=$(t64_cluster_lower "$CLUSTER")
BASE="/mnt/jfs-t64-${RUN_ID}-${LOWER}"
STATE="/tmp/jfs-t64-${RUN_ID}-${LOWER}-storage.tsv"
AUDIT="/tmp/jfs-t64-${RUN_ID}-${LOWER}-storage.destroyed.tsv"
HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
[[ "$HOST_IP" == "$NODE_IP" ]] ||
  t64_die "host identity mismatch: expected=$NODE_IP actual=${HOST_IP:-unknown}"
t64_assert_abs_scoped_path "$BASE" "$RUN_ID"
t64_assert_abs_scoped_path "$STATE" "$RUN_ID"
t64_assert_abs_scoped_path "$AUDIT" "$RUN_ID"

if [[ "$CLUSTER" == A ]]; then
  ROLES=(shared)
else
  ROLES=(kv logs)
fi

assert_exact_tmpfs() {
  local target=$1 expected_source=$2 actual
  t64_assert_abs_scoped_path "$target" "$RUN_ID"
  [[ -d "$target" && ! -L "$target" ]] || t64_die "unsafe or missing directory: $target"
  actual=$(findmnt -rn -M "$target" -o SOURCE,FSTYPE,TARGET 2>/dev/null || true)
  [[ "$actual" == "$expected_source tmpfs $target" ]] ||
    t64_die "mount mismatch: target=$target expected='$expected_source tmpfs' actual='${actual:-none}'"
  [[ -z $(sudo find "$target" -mindepth 1 -print -quit) ]] ||
    t64_die "mounted tmpfs is not empty: $target"
}

inspect() {
  [[ ! -e "$STATE" ]] || t64_die "normal state exists; use state-driven plan-destroy: $STATE"
  [[ ! -e "$AUDIT" ]] || t64_die "recovery/destroy audit already exists: $AUDIT"
  [[ -d "$BASE" && ! -L "$BASE" ]] || t64_die "unsafe or missing base: $BASE"
  ! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on this node'

  local foreign role backing fs img loops actual_top expected_top target unexpected i
  foreign=$(ps -eo pid=,comm=,args= | awk -v me="$$" -v parent="$PPID" -v token="jfs-t64-${RUN_ID}" \
    '$1!=me && $1!=parent && index($0,token)>0 && ($2=="pd-server" || $2=="tikv-server" || $2=="juicefs"){print;exit}')
  [[ -z "$foreign" ]] || t64_die "temporary t64 process exists: $foreign"

  assert_exact_tmpfs "$BASE/pd" "t64-pd-${RUN_ID}-${LOWER}"
  for role in "${ROLES[@]}"; do
    backing="$BASE/backing-$role"
    fs="$BASE/fs-$role"
    img="$backing/t64-$role.img"
    assert_exact_tmpfs "$backing" "t64-${RUN_ID}-${LOWER}-${role}"
    [[ ! -e "$img" ]] || t64_die "unexpected backing image without state: $img"
    [[ -d "$fs" && ! -L "$fs" ]] || t64_die "unsafe or missing filesystem mountpoint: $fs"
    ! mountpoint -q "$fs" || t64_die "unexpected mounted filesystem without state: $fs"
    [[ -z $(sudo find "$fs" -mindepth 1 -print -quit) ]] ||
      t64_die "filesystem mountpoint is not empty: $fs"
  done

  loops=$(sudo losetup -l -n -O NAME,BACK-FILE | awk -v p="$BASE/" 'index($2,p)==1{print}')
  [[ -z "$loops" ]] || t64_die "unexpected loop backed by state-less base: $loops"

  actual_top=$(sudo find "$BASE" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  expected_top=$(printf '%s\n' pd "${ROLES[@]/#/backing-}" "${ROLES[@]/#/fs-}" | sort)
  [[ "$actual_top" == "$expected_top" ]] ||
    t64_die "unexpected top-level entry under $BASE: actual=[$actual_top] expected=[$expected_top]"

  declare -A allowed=(["$BASE/pd"]=1)
  for role in "${ROLES[@]}"; do allowed["$BASE/backing-$role"]=1; done
  unexpected=''
  while read -r target; do
    [[ -z "$target" || ${allowed[$target]+present} ]] || { unexpected=$target; break; }
  done < <(findmnt -rn -o TARGET 2>/dev/null | awk -v p="$BASE/" 'index($0,p)==1' || true)
  [[ -z "$unexpected" ]] || t64_die "unexpected nested mount under state-less base: $unexpected"

  printf 'RECOVERY_INSPECT_PASS node=%s cluster=%s state=absent loop=absent contents=empty\n' "$NODE_IP" "$CLUSTER"
  printf 'MODE=PARTIAL_RECOVERY_PLAN_ONLY\n'
  for ((i=${#ROLES[@]}-1; i>=0; i--)); do
    role=${ROLES[$i]}
    printf 'sudo umount %q  # only while source remains t64-%s-%s-%s\n' "$BASE/backing-$role" "$RUN_ID" "$LOWER" "$role"
  done
  printf 'sudo umount %q  # only while source remains t64-pd-%s-%s\n' "$BASE/pd" "$RUN_ID" "$LOWER"
  for role in "${ROLES[@]}"; do printf 'rmdir %q %q\n' "$BASE/fs-$role" "$BASE/backing-$role"; done
  printf 'rmdir %q\n' "$BASE/pd"
  printf 'sudo rmdir %q  # parent is directly below root-managed /mnt\n' "$BASE"
  printf 'No loop detach, file removal, forced/lazy unmount, or production-path operation is planned.\n'
}

recover() {
  [[ ${T64_PARTIAL_RECOVERY_AUTH:-} == "03-22-recover-partial-${RUN_ID}-${CLUSTER}-${NODE_IP}" ]] ||
    t64_die "set exact T64_PARTIAL_RECOVERY_AUTH=03-22-recover-partial-${RUN_ID}-${CLUSTER}-${NODE_IP} after reviewing inspect output"
  inspect

  umask 077
  printf 'status\tSTARTED\nrun_id\t%s\ncluster\t%s\nnode\t%s\nreason\tstate-absent-pre-loop-create-failure\n' \
    "$RUN_ID" "$CLUSTER" "$NODE_IP" > "$AUDIT"

  local i role target source
  for ((i=${#ROLES[@]}-1; i>=0; i--)); do
    role=${ROLES[$i]}
    target="$BASE/backing-$role"
    source=$(findmnt -rn -M "$target" -o SOURCE 2>/dev/null || true)
    [[ "$source" == "t64-${RUN_ID}-${LOWER}-${role}" ]] || t64_die "backing source changed before recovery: $target source=$source"
    sudo umount "$target"
    printf 'unmounted\t%s\t%s\n' "$source" "$target" >> "$AUDIT"
  done
  source=$(findmnt -rn -M "$BASE/pd" -o SOURCE 2>/dev/null || true)
  [[ "$source" == "t64-pd-${RUN_ID}-${LOWER}" ]] || t64_die "PD source changed before recovery: source=$source"
  sudo umount "$BASE/pd"
  printf 'unmounted\t%s\t%s\n' "$source" "$BASE/pd" >> "$AUDIT"

  for role in "${ROLES[@]}"; do rmdir "$BASE/fs-$role" "$BASE/backing-$role"; done
  rmdir "$BASE/pd"
  sudo rmdir "$BASE"
  [[ -z $(findmnt -rn -o TARGET 2>/dev/null | awk -v p="$BASE/" 'index($0,p)==1' || true) ]] ||
    t64_die 'scoped mount remains after recovery'
  [[ ! -e "$BASE" ]] || t64_die "scoped base remains after recovery: $BASE"
  [[ -z $(sudo losetup -l -n -O NAME,BACK-FILE | awk -v p="$BASE/" 'index($2,p)==1{print}') ]] ||
    t64_die 'scoped loop unexpectedly exists after recovery'
  printf 'status\tCOMPLETE\nepoch\t%s\n' "$(date +%s)" >> "$AUDIT"
  printf 'PARTIAL_RECOVERY_PASS node=%s cluster=%s audit=%s\n' "$NODE_IP" "$CLUSTER" "$AUDIT"
}

case "$ACTION" in
  inspect) inspect;;
  recover) recover;;
  *) t64_die 'usage: t64-recover-partial-storage.sh inspect|recover RUN_ID A|B NODE_IP';;
esac
