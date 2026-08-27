#!/usr/bin/env bash
# Precisely unmount/detach one activated arm. Backing files are retained.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}; ARM=${3:-}; INSTANCE=${4:-}; NODE_IP=${5:-}
t65_check_run_id "$RUN_ID"; t65_check_cluster "$ARM"; t65_check_instance "$INSTANCE"; t65_node_suffix "$NODE_IP" >/dev/null
[[ $(t65_expected_cluster "$INSTANCE") == "$ARM" ]] || t65_die 'instance/arm mapping mismatch'
MOUNT_ROOT="/mnt/jfs-t65-${RUN_ID}"
BACKING_ROOT="/mnt/jfs-tikv/jfs-t65-${RUN_ID}-backing"
PD_MNT="$MOUNT_ROOT/pd"
STATE="/tmp/jfs-t65-${RUN_ID}-${ARM}-${INSTANCE}-activation.tsv"

audit_path() {
  local sha
  [[ -s "$STATE" ]] || t65_die 'activation state missing'
  sha=$(sha256sum -- "$STATE" | awk '{print $1}')
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || t65_die 'activation state SHA256 is invalid'
  printf '%s.deactivated-%s\n' "$STATE" "${sha:0:16}"
}

host_guard() {
  local actual; actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t65_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

assert_identity() {
  [[ -s "$STATE" ]] || t65_die 'activation state missing'
  t65_validate_activation_partial_rows "$STATE" "$RUN_ID" "$ARM" "$INSTANCE" "$NODE_IP" || t65_die 'activation state text contract mismatch'
  [[ $(t65_state_value "$STATE" meta) == "$RUN_ID" && $(t65_state_value "$STATE" node) == "$NODE_IP" &&
     $(t65_state_value "$STATE" arm) == "$ARM" && $(t65_state_value "$STATE" instance) == "$INSTANCE" ]] || t65_die 'activation identity mismatch'
}

assert_services_stopped() {
  ! ps -eo pid=,comm=,args= | awk -v token="jfs-t65-${RUN_ID}-${INSTANCE}" 'index($0,token)>0 && ($2=="pd-server"||$2=="tikv-server"){print;found=1} END{exit !found}' ||
    t65_die 'temporary PD/TiKV still running'
  ! pgrep -af "/tmp/jfs-t65-${RUN_ID}-mnt-${INSTANCE}" >/dev/null || t65_die 'JuiceFS mount process still running'
}

plan() {
  local audit
  assert_identity
  audit=$(audit_path); [[ ! -e "$audit" ]] || t65_die "deactivation audit already exists: $audit"
  printf 'MODE=DEACTIVATE_PLAN_ONLY\nnode=%s\narm=%s\ninstance=%s\n' "$NODE_IP" "$ARM" "$INSTANCE"
  printf 'immutable_audit=%s\n' "$audit"
  tac "$STATE" | awk -F '\t' '$1=="loop"{print $2"\t"$3"\t"$4"\t"$5}' | while IFS=$'\t' read -r role loop backing mnt; do
    printf 'sudo umount %q  # source must be %q\n' "$mnt" "$loop"
    printf 'sudo losetup -d %q  # backing must be %q\n' "$loop" "$backing"
    printf 'rmdir %q\n' "$mnt"
  done
  printf 'sudo umount %q  # source must be t65-pd-%s-%s\n' "$PD_MNT" "$RUN_ID" "${INSTANCE,,}"
  printf 'rmdir %q\n' "$PD_MNT"
}

deactivate() {
  local expected="03-22b-deactivate-${RUN_ID}-${ARM}-${INSTANCE}-${NODE_IP}" role loop backing mnt source actual audit
  t65_check_auth "${T65_DEACTIVATE_AUTH:-}" "$expected"
  t65_record_authorization "$RUN_ID" "deactivate-$ARM-$INSTANCE" "$expected"
  host_guard; assert_identity; assert_services_stopped
  audit=$(audit_path); [[ ! -e "$audit" ]] || t65_die "deactivation audit already exists: $audit"
  while IFS=$'\t' read -r role loop backing mnt; do
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t65_die "unsafe loop: $loop"
    t65_assert_abs_scoped_path "$backing" "$RUN_ID"; t65_assert_abs_scoped_path "$mnt" "$RUN_ID"
    source=$(findmnt -rn -M "$mnt" -o SOURCE 2>/dev/null || true)
    [[ -z "$source" || "$source" == "$loop" ]] || t65_die "mount source changed: mnt=$mnt source=$source expected=$loop"
    actual=$(sudo losetup -l -n -O BACK-FILE "$loop" | awk 'NF{print}')
    [[ "$actual" == "$backing" ]] || t65_die "loop backing changed: loop=$loop actual=$actual expected=$backing"
    [[ -z "$source" ]] || sudo umount "$mnt"
    [[ -z $(findmnt -rn -S "$loop" -o TARGET 2>/dev/null) ]] || t65_die "loop remains mounted: $loop"
    sudo losetup -d "$loop"
    [[ -z $(sudo losetup -j "$backing") ]] || t65_die "backing remains loop-associated: $backing"
    [[ ! -e "$mnt" ]] || rmdir "$mnt"
  done < <(tac "$STATE" | awk -F '\t' '$1=="loop"{print $2"\t"$3"\t"$4"\t"$5}')
  source=$(findmnt -rn -M "$PD_MNT" -o SOURCE 2>/dev/null || true)
  [[ -z "$source" || "$source" == "t65-pd-${RUN_ID}-${INSTANCE,,}" ]] || t65_die "PD tmpfs source changed: $source"
  [[ -z "$source" ]] || sudo umount "$PD_MNT"
  [[ ! -e "$PD_MNT" ]] || rmdir "$PD_MNT"
  { printf 'deactivate_epoch\t%s\n' "$(date +%s)"; cat "$STATE"; } > "$audit"
  unlink "$STATE"
  printf 'STORAGE_DEACTIVATE_PASS node=%s arm=%s instance=%s audit=%s\n' "$NODE_IP" "$ARM" "$INSTANCE" "$audit"
}

case "$ACTION" in
  plan) host_guard; plan;;
  deactivate) deactivate;;
  *) t65_die 'usage: t65-storage-deactivate-arm.sh plan|deactivate RUN_ID A1|B1 INSTANCE NODE_IP';;
esac
