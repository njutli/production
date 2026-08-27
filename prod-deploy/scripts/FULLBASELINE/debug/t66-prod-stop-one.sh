#!/usr/bin/env bash
# Plan or gracefully stop exactly the production TiKV unit on one node.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-plan}; RUN_ID=${2:-}; NODE_IP=${3:-}
t66_check_run_id "$RUN_ID"; t66_node_suffix "$NODE_IP" >/dev/null
STATE="/tmp/jfs-t66-${RUN_ID}-production-stopped.tsv"

host_guard() {
  local actual; actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t66_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

fingerprint() {
  local main_pid exe exe_sha cfg cfg_sha fragment fragment_sha cmd start source target fstype uuid
  [[ $(systemctl is-active tikv) == active ]] || t66_die 'production tikv unit is not active'
  main_pid=$(systemctl show tikv -p MainPID --value); [[ "$main_pid" =~ ^[1-9][0-9]*$ && -r /proc/$main_pid/stat ]] || t66_die 'invalid production MainPID'
  cmd=$(tr '\0' ' ' < "/proc/$main_pid/cmdline")
  exe=$(t66_exe_from_cmdline "$cmd"); exe_sha=$(sha256sum -- "$exe" | awk '{print $1}')
  [[ "$exe_sha" =~ ^[0-9a-f]{64}$ ]] || t66_die 'production executable SHA256 is empty or invalid'
  start=$(awk '{print $22}' "/proc/$main_pid/stat")
  cfg=$(printf '%s\n' "$cmd" | sed -nE 's/.*--config(=|[[:space:]])([^[:space:]]+).*/\2/p')
  [[ -n "$cfg" && -f "$cfg" && ! -L "$cfg" ]] || t66_die "cannot resolve production TiKV config from cmdline: $cmd"
  cfg_sha=$(sha256sum -- "$cfg" | awk '{print $1}'); [[ "$cfg_sha" =~ ^[0-9a-f]{64}$ ]] || t66_die 'production config SHA256 is invalid'
  fragment=$(systemctl show tikv -p FragmentPath --value); [[ -f "$fragment" ]] || t66_die 'tikv unit fragment missing'
  fragment_sha=$(sha256sum -- "$fragment" | awk '{print $1}'); [[ "$fragment_sha" =~ ^[0-9a-f]{64}$ ]] || t66_die 'unit fragment SHA256 is invalid'
  read -r source target fstype < <(findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE)
  uuid=$(findmnt -rn -M /mnt/jfs-tikv -o UUID)
  [[ "$source" == /dev/nvme1n1 && "$target" == /mnt/jfs-tikv && "$fstype" == ext4 && -n "$uuid" ]] || t66_die 'production mount identity mismatch'
  printf 'node\t%s\nunit\ttikv\nfragment\t%s\nfragment_sha256\t%s\nmain_pid\t%s\nstarttime\t%s\nexe\t%s\nexe_sha256\t%s\nconfig\t%s\nconfig_sha256\t%s\nmount_source\t%s\nmount_target\t%s\nmount_fstype\t%s\nmount_uuid\t%s\ncmdline\t%s\n' \
    "$NODE_IP" "$fragment" "$fragment_sha" "$main_pid" "$start" "$exe" \
    "$exe_sha" "$cfg" "$cfg_sha" "$source" "$target" "$fstype" "$uuid" "$cmd"
}

plan() {
  local fp sha
  host_guard; [[ ! -e "$STATE" ]] || t66_die 'production stop state already exists'
  fp=$(fingerprint); sha=$(printf '%s\n' "$fp" | sha256sum | awk '{print $1}')
  printf 'MODE=PRODUCTION_STOP_PLAN_ONLY\nrun_id=%s\n%s\nfingerprint_sha256\t%s\n' "$RUN_ID" "$fp" "$sha"
  printf 'sudo systemctl stop tikv\n'
  printf 'AUTH_REQUIRED=T66_PROD_STOP_AUTH=03-22c-prod-stop-%s-%s-%s\n' "$RUN_ID" "$NODE_IP" "$sha"
}

stop_prod() {
  local fp sha expected deadline
  host_guard; [[ ! -e "$STATE" ]] || t66_die 'production stop state already exists'
  fp=$(fingerprint); sha=$(printf '%s\n' "$fp" | sha256sum | awk '{print $1}')
  expected="03-22c-prod-stop-${RUN_ID}-${NODE_IP}-${sha}"
  t66_check_auth "${T66_PROD_STOP_AUTH:-}" "$expected"
  t66_record_authorization "$RUN_ID" production-stop "$expected"
  printf 'meta\t%s\nfingerprint_sha256\t%s\n%s\nstop_begin_epoch\t%s\n' "$RUN_ID" "$sha" "$fp" "$(date +%s)" > "$STATE"
  sudo systemctl stop tikv
  deadline=$((SECONDS+120)); while [[ $(systemctl is-active tikv 2>/dev/null || true) == active && $SECONDS -lt $deadline ]]; do sleep 1; done
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || t66_die 'production tikv did not stop in 120s; no signal escalation sent'
  ! ps -eo comm=,args= | awk '$1=="tikv-server" && $0 !~ /jfs-t66-/{found=1} END{exit !found}' || t66_die 'production tikv-server process remains'
  printf 'stop_pass_epoch\t%s\n' "$(date +%s)" >> "$STATE"
  printf 'PRODUCTION_STOP_PASS node=%s state=%s\n' "$NODE_IP" "$STATE"
}

case "$ACTION" in
  plan) plan;;
  stop) stop_prod;;
  *) t66_die 'usage: t66-prod-stop-one.sh plan|stop RUN_ID NODE_IP';;
esac
