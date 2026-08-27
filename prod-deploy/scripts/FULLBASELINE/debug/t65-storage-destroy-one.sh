#!/usr/bin/env bash
# Delete only the three state-recorded t65 backing files after a reviewed plan.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}; NODE_IP=${3:-}
t65_check_run_id "$RUN_ID"; t65_node_suffix "$NODE_IP" >/dev/null
BACKING_ROOT="/mnt/jfs-tikv/jfs-t65-${RUN_ID}-backing"
MOUNT_ROOT="/mnt/jfs-t65-${RUN_ID}"
STATE="/tmp/jfs-t65-${RUN_ID}-storage.tsv"
AUDIT=''
GIB=$((1024*1024*1024))
t65_require_tools flock

acquire_state_lock() {
  [[ -f "$STATE" && ! -L "$STATE" ]] || t65_die 'storage state unavailable for lock'
  exec 9<"$STATE"
  flock -n 9 || t65_die 'another storage destroy plan/action holds the state lock'
}

host_guard() {
  local actual; actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t65_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

assert_state() {
  local state_sha
  [[ -s "$STATE" ]] || t65_die 'storage state missing'
  t65_validate_storage_partial_rows "$STATE" "$RUN_ID" "$NODE_IP" || t65_die 'storage state text contract mismatch'
  [[ $(t65_state_value "$STATE" meta) == "$RUN_ID" && $(t65_state_value "$STATE" node) == "$NODE_IP" &&
     $(t65_state_value "$STATE" backing_root) == "$BACKING_ROOT" && $(t65_state_value "$STATE" mount_root) == "$MOUNT_ROOT" ]] || t65_die 'storage state identity mismatch'
  state_sha=$(sha256sum "$STATE" | awk '{print $1}')
  [[ "$state_sha" =~ ^[0-9a-f]{64}$ ]] || t65_die 'invalid storage state SHA'
  AUDIT="/tmp/jfs-t65-${RUN_ID}-storage.destroyed-${state_sha:0:16}.tsv"
  [[ ! -e "$AUDIT" ]] || t65_die "immutable storage destroy audit already exists: $AUDIT"
}

assert_quiescent() {
  local remaining
  ! findmnt -rn -o TARGET | awk -v p="$MOUNT_ROOT" '$1==p || index($1,p"/")==1{found=1} END{exit !found}' || t65_die 't65 mount remains'
  ! sudo losetup -l -n -O BACK-FILE | awk -v p="$BACKING_ROOT/" 'index($1,p)==1{found=1} END{exit !found}' || t65_die 't65 loop remains'
  remaining=$(t65_scoped_runtime_process_rows "jfs-t65-${RUN_ID}" "$SCRIPT_DIR/t65-storage-destroy-one.sh")
  [[ -z "$remaining" ]] || t65_die "t65 process remains: ${remaining//$'\n'/; }"
  ! compgen -G "/tmp/jfs-t65-${RUN_ID}-*-activation.tsv" >/dev/null || t65_die 'active activation state remains'
}

state_files() {
  awk -F '\t' '$1=="file"{key=$3; role[key]=$2; bytes[key]=$4; dev[key]=$5; inode[key]=$6} END{for(k in role)print role[k]"\t"k"\t"bytes[k]"\t"dev[k]"\t"inode[k]}' "$STATE" | sort
}

verify_file_identity() {
  local role=$1 path=$2 bytes=$3 dev=$4 inode=$5
  t65_assert_abs_scoped_path "$path" "$RUN_ID"; t65_assert_no_production_overlap "$path"
  [[ -f "$path" && ! -L "$path" ]] || t65_die "recorded backing missing/not regular: $role $path"
  [[ $(stat -Lc '%d' -- "$path") == "$dev" && $(stat -Lc '%i' -- "$path") == "$inode" ]] || t65_die "recorded backing identity changed: $role"
  [[ $(stat -Lc '%s' -- "$path") -le "$bytes" ]] || t65_die "recorded backing grew unexpectedly: $role"
}

plan() {
  local role path bytes dev inode count=0
  acquire_state_lock
  assert_state; assert_quiescent
  printf 'MODE=DESTROY_PLAN_ONLY\nnode=%s\nrun_id=%s\n' "$NODE_IP" "$RUN_ID"
  printf 'immutable_audit=%s\n' "$AUDIT"
  while IFS=$'\t' read -r role path bytes dev inode; do
    verify_file_identity "$role" "$path" "$bytes" "$dev" "$inode"
    printf 'unlink %q  # role=%s dev=%s inode=%s\n' "$path" "$role" "$dev" "$inode"
    count=$((count+1))
  done < <(state_files)
  if grep -q $'^avail_post\t' "$STATE"; then [[ "$count" -eq 3 ]] || t65_die "completed storage requires 3 recorded files, got $count"; fi
  printf 'sudo rmdir %q %q\n' "$BACKING_ROOT" "$MOUNT_ROOT"
}

destroy() {
  local expected="03-22b-storage-destroy-${RUN_ID}-${NODE_IP}" role path bytes dev inode count=0 avail_pre avail_now delta
  acquire_state_lock
  t65_check_auth "${T65_STORAGE_DESTROY_AUTH:-}" "$expected"
  t65_record_authorization "$RUN_ID" storage-destroy "$expected"
  host_guard; assert_state; assert_quiescent
  avail_pre=$(t65_state_value "$STATE" avail_pre)
  while IFS=$'\t' read -r role path bytes dev inode; do
    verify_file_identity "$role" "$path" "$bytes" "$dev" "$inode"
    unlink "$path"
    count=$((count+1))
  done < <(state_files)
  if grep -q $'^avail_post\t' "$STATE"; then [[ "$count" -eq 3 ]] || t65_die "completed storage requires 3 files, got $count"; fi
  sudo rmdir "$BACKING_ROOT"
  sudo rmdir "$MOUNT_ROOT"
  avail_now=$(df -B1 --output=avail /mnt/jfs-tikv | awk 'NR==2{gsub(/[[:space:]]/,"");print}')
  delta=$((avail_now-avail_pre)); (( delta < 0 )) && delta=$((-delta))
  (( delta <= 2*GIB )) || t65_die "space did not return to pre-create ±2GiB: pre=$avail_pre now=$avail_now delta=$delta"
  { printf 'destroy_epoch\t%s\navail_after\t%s\n' "$(date +%s)" "$avail_now"; cat "$STATE"; } > "$AUDIT"
  unlink "$STATE"; [[ ! -e "$STATE.allocation-checks" ]] || unlink "$STATE.allocation-checks"
  printf 'STORAGE_DESTROY_PASS node=%s audit=%s avail_after=%s\n' "$NODE_IP" "$AUDIT" "$avail_now"
}

case "$ACTION" in
  plan) host_guard; plan;;
  destroy) destroy;;
  *) t65_die 'usage: t65-storage-destroy-one.sh plan|destroy RUN_ID NODE_IP';;
esac
