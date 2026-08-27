#!/usr/bin/env bash
# Plan or start exactly the previously stopped production TiKV unit on one node.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

ACTION=${1:-plan}; RUN_ID=${2:-}; NODE_IP=${3:-}
t65_check_run_id "$RUN_ID"; t65_node_suffix "$NODE_IP" >/dev/null
STATE="/tmp/jfs-t65-${RUN_ID}-production-stopped.tsv"
AUDIT="/tmp/jfs-t65-${RUN_ID}-production-restored.tsv"
t65_require_tools flock

acquire_state_lock() {
  [[ -f "$STATE" && ! -L "$STATE" ]] || t65_die 'production stop state unavailable for lock'
  exec 9<"$STATE"
  flock -n 9 || t65_die 'another production-start plan/action holds the state lock'
}

host_guard() {
  local actual; actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t65_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

assert_invariants() {
  local fragment exe cfg source target fstype uuid remaining
  [[ -s "$STATE" && ! -e "$AUDIT" && $(t65_state_value "$STATE" meta) == "$RUN_ID" && $(t65_state_value "$STATE" node) == "$NODE_IP" ]] || t65_die 'production stop state mismatch'
  fragment=$(t65_state_value "$STATE" fragment); exe=$(t65_state_value "$STATE" exe); cfg=$(t65_state_value "$STATE" config)
  [[ $(sha256sum "$fragment" | awk '{print $1}') == $(t65_state_value "$STATE" fragment_sha256) ]] || t65_die 'unit fragment changed while stopped'
  [[ $(sha256sum "$exe" | awk '{print $1}') == $(t65_state_value "$STATE" exe_sha256) ]] || t65_die 'production TiKV binary changed while stopped'
  [[ $(sha256sum "$cfg" | awk '{print $1}') == $(t65_state_value "$STATE" config_sha256) ]] || t65_die 'production TiKV config changed while stopped'
  read -r source target fstype < <(findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE); uuid=$(findmnt -rn -M /mnt/jfs-tikv -o UUID)
  [[ "$source" == $(t65_state_value "$STATE" mount_source) && "$target" == $(t65_state_value "$STATE" mount_target) &&
     "$fstype" == $(t65_state_value "$STATE" mount_fstype) && "$uuid" == $(t65_state_value "$STATE" mount_uuid) ]] || t65_die 'production mount changed while stopped'
  ! findmnt -rn -o TARGET | awk -v p="/mnt/jfs-t65-${RUN_ID}" '$1==p || index($1,p"/")==1{found=1} END{exit !found}' || t65_die 't65 mount remains before production restart'
  ! sudo losetup -l -n -O BACK-FILE | awk -v p="/mnt/jfs-tikv/jfs-t65-${RUN_ID}-backing/" 'index($1,p)==1{found=1} END{exit !found}' || t65_die 't65 loop remains before production restart'
  remaining=$(t65_scoped_runtime_process_rows "jfs-t65-${RUN_ID}" "$SCRIPT_DIR/t65-prod-start-one.sh")
  [[ -z "$remaining" ]] || t65_die "t65 process remains before production restart: ${remaining//$'\n'/; }"
}

plan() {
  acquire_state_lock
  host_guard; assert_invariants
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || t65_die 'production tikv already active'
  printf 'MODE=PRODUCTION_START_PLAN_ONLY\nnode=%s\nrun_id=%s\n' "$NODE_IP" "$RUN_ID"
  printf 'sudo systemctl start tikv\n'
  printf 'AUTH_REQUIRED=T65_PROD_START_AUTH=03-22b-prod-start-%s-%s-%s\n' "$RUN_ID" "$NODE_IP" "$(t65_state_value "$STATE" fingerprint_sha256)"
}

start_prod() {
  local expected deadline pid exe cfg cmd
  acquire_state_lock
  host_guard; assert_invariants
  expected="03-22b-prod-start-${RUN_ID}-${NODE_IP}-$(t65_state_value "$STATE" fingerprint_sha256)"
  t65_check_auth "${T65_PROD_START_AUTH:-}" "$expected"
  t65_record_authorization "$RUN_ID" production-start "$expected"
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || t65_die 'production tikv already active'
  sudo systemctl start tikv
  deadline=$((SECONDS+180)); while [[ $(systemctl is-active tikv 2>/dev/null || true) != active && $SECONDS -lt $deadline ]]; do sleep 2; done
  [[ $(systemctl is-active tikv) == active ]] || t65_die 'production tikv did not become active; no restart/escalation attempted'
  pid=$(systemctl show tikv -p MainPID --value); [[ "$pid" =~ ^[1-9][0-9]*$ && -r /proc/$pid/stat ]] || t65_die 'invalid restored MainPID'
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  exe=$(t65_exe_from_cmdline "$cmd")
  cfg=$(printf '%s\n' "$cmd" | sed -nE 's/.*--config(=|[[:space:]])([^[:space:]]+).*/\2/p')
  [[ "$exe" == $(t65_state_value "$STATE" exe) && "$cfg" == $(t65_state_value "$STATE" config) ]] || t65_die 'restored process exe/config mismatch'
  { printf 'restore_epoch\t%s\nnew_pid\t%s\nnew_starttime\t%s\n' "$(date +%s)" "$pid" "$(awk '{print $22}' /proc/$pid/stat)"; cat "$STATE"; } > "$AUDIT"
  printf 'PRODUCTION_START_PASS node=%s pid=%s audit=%s; global three-sample store verification still required\n' "$NODE_IP" "$pid" "$AUDIT"
}

case "$ACTION" in
  plan) plan;;
  start) start_prod;;
  *) t65_die 'usage: t65-prod-start-one.sh plan|start RUN_ID NODE_IP';;
esac
