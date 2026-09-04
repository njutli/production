#!/usr/bin/env bash
# Fingerprint-bound graceful stop/start of the production TiKV unit. PD is never touched.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
NODE_IP=${3:-}
s04a1_check_run_id "$RUN_ID"
s04a1_check_node "$NODE_IP"
NODE=${NODE_IP##*.}
STATE="/tmp/s04a1-${RUN_ID}-production-stopped-${NODE}.tsv"
AUDIT="/tmp/s04a1-${RUN_ID}-production-restored-${NODE}.tsv"
LEDGER="/tmp/s04a1-${RUN_ID}-authorization-${NODE}.tsv"

die() { s04a1_die "$*"; exit 42; }
state_one() { awk -F '\t' -v k="$2" '$1==k{v=$2;n++} END{if(n==1)print v;else exit 1}' "$1"; }

host_guard() {
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -Fqx "$NODE_IP" || die "host mismatch: expected=$NODE_IP"
  [[ $(id -u) == 1001 && $(id -g) == 1001 ]] || die "executor uid/gid mismatch"
}

prod_mount_row() { findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE,UUID; }

exe_from_cmdline() {
  local cmd=$1 exe=${cmd%%[[:space:]]*}
  [[ $exe == /* && -x $exe && -f $exe ]] || die "cannot resolve executable from cmdline"
  readlink -f -- "$exe"
}

fingerprint() {
  local pid cmd exe cfg fragment start source target fstype uuid
  [[ $(systemctl is-active tikv) == active ]] || die "production tikv is not active"
  [[ $(systemctl is-active pd) == active ]] || die "production pd is not active"
  pid=$(systemctl show tikv -p MainPID --value)
  [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/stat ]] || die "invalid tikv MainPID"
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
  exe=$(exe_from_cmdline "$cmd")
  cfg=$(printf '%s\n' "$cmd" | sed -nE 's/.*--config(=|[[:space:]])([^[:space:]]+).*/\2/p')
  [[ -f $cfg && ! -L $cfg ]] || die "cannot resolve tikv config"
  fragment=$(systemctl show tikv -p FragmentPath --value)
  [[ $fragment == /etc/systemd/system/tikv.service && -f $fragment && ! -L $fragment ]] || die "tikv unit fragment mismatch"
  start=$(awk '{print $22}' "/proc/$pid/stat")
  read -r source target fstype uuid < <(prod_mount_row)
  [[ $source == /dev/nvme1n1 && $target == /mnt/jfs-tikv && $fstype == ext4 && -n $uuid ]] || die "production mount identity mismatch"
  printf 'node_ip\t%s\nunit\ttikv\nmain_pid\t%s\nstarttime\t%s\nexe\t%s\nexe_sha256\t%s\n' \
    "$NODE_IP" "$pid" "$start" "$exe" "$(sha256sum "$exe" | awk '{print $1}')"
  printf 'config\t%s\nconfig_sha256\t%s\nfragment\t%s\nfragment_sha256\t%s\n' \
    "$cfg" "$(sha256sum "$cfg" | awk '{print $1}')" "$fragment" "$(sha256sum "$fragment" | awk '{print $1}')"
  printf 'mount_source\t%s\nmount_target\t%s\nmount_fstype\t%s\nmount_uuid\t%s\ncmdline\t%s\n' \
    "$source" "$target" "$fstype" "$uuid" "$cmd"
}

auth_guard() {
  local verb=$1 fp_sha=$2 expected
  expected="04-2-prod-${verb}-${RUN_ID}-${NODE_IP}-${fp_sha}"
  [[ ${S04A1_PROD_AUTH:-} == "$expected" ]] || die "exact auth required: $expected"
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$NODE_IP" "$verb" "$expected" >> "$LEDGER"
}

assert_stopped_state() {
  local f
  [[ -s $STATE && ! -L $STATE && ! -e $AUDIT ]] || die "stopped state unavailable/audit exists"
  [[ $(state_one "$STATE" run_id) == "$RUN_ID" && $(state_one "$STATE" node_ip) == "$NODE_IP" ]] || die "stopped state identity mismatch"
  for f in exe config fragment; do
    [[ -f $(state_one "$STATE" "$f") ]] || die "$f missing while stopped"
    [[ $(sha256sum "$(state_one "$STATE" "$f")" | awk '{print $1}') == $(state_one "$STATE" "${f}_sha256") ]] || die "$f changed while stopped"
  done
  local source target fstype uuid
  read -r source target fstype uuid < <(prod_mount_row)
  [[ $source == $(state_one "$STATE" mount_source) && $target == $(state_one "$STATE" mount_target) &&
     $fstype == $(state_one "$STATE" mount_fstype) && $uuid == $(state_one "$STATE" mount_uuid) ]] || die "production mount changed while stopped"
}

no_temporary_resources() {
  local rows='' cursor parent excluded pid args token="s04a1-$RUN_ID" self_pid probe own
  [[ -z $(findmnt -rn -o TARGET | awk -v a="/mnt/jfs-s04a1-$RUN_ID" -v b="/mnt/jfs-tikv/jfs-s04a1-$RUN_ID" '$1==a||index($1,a"/")==1||index($1,b)==1{print}') ]] || die "04-2 mount remains"
  [[ -z $(sudo losetup -l -n -O BACK-FILE | awk -v p="/mnt/jfs-tikv/jfs-s04a1-$RUN_ID-l-backing/" 'index($1,p)==1{print}') ]] || die "04-2 loop remains"
  self_pid=${BASHPID:-$$}; cursor=$self_pid; excluded=" $cursor "
  while (( cursor > 1 )); do
    parent=$(awk '{print $4}' "/proc/$cursor/stat" 2>/dev/null || true)
    [[ $parent =~ ^[0-9]+$ && $parent -gt 1 && $excluded != *" $parent "* ]] || break
    excluded+="$parent "; cursor=$parent
  done
  while read -r pid args; do
    [[ $args == *"$token"* ]] || continue
    [[ $excluded == *" $pid "* ]] && continue
    probe=$pid; own=0
    while [[ $probe =~ ^[0-9]+$ && $probe -gt 1 ]]; do
      [[ $probe == "$self_pid" ]] && { own=1; break; }
      parent=$(awk '{print $4}' "/proc/$probe/stat" 2>/dev/null || true)
      [[ $parent =~ ^[0-9]+$ && $parent -ne "$probe" ]] || break
      probe=$parent
    done
    (( own == 1 )) && continue
    [[ -r /proc/$pid/stat ]] || continue
    rows+="${rows:+$'\n'}$pid $args"
  done < <(ps -eo pid=,args=)
  [[ -z $rows ]] || die "04-2 process remains: ${rows//$'\n'/; }"
}

plan_stop() {
  local fp sha
  host_guard; [[ ! -e $STATE && ! -e $AUDIT ]] || die "production lifecycle state already exists"
  fp=$(fingerprint); sha=$(printf '%s\n' "$fp" | sha256sum | awk '{print $1}')
  printf 'MODE=PROD_STOP_PLAN_ONLY\nRUN_ID=%s\n%s\nfingerprint_sha256\t%s\n' "$RUN_ID" "$fp" "$sha"
  printf 'sudo systemctl stop tikv\nAUTH_REQUIRED=S04A1_PROD_AUTH=04-2-prod-stop-%s-%s-%s\n' "$RUN_ID" "$NODE_IP" "$sha"
}

stop_prod() {
  local fp sha deadline
  host_guard; [[ ! -e $STATE && ! -e $AUDIT ]] || die "production lifecycle state already exists"
  fp=$(fingerprint); sha=$(printf '%s\n' "$fp" | sha256sum | awk '{print $1}')
  auth_guard stop "$sha"
  { printf 'run_id\t%s\nfingerprint_sha256\t%s\n' "$RUN_ID" "$sha"; printf '%s\n' "$fp"; printf 'stop_begin_epoch\t%s\n' "$(date +%s)"; } > "$STATE"
  sudo systemctl stop tikv
  deadline=$((SECONDS + 120))
  while [[ $(systemctl is-active tikv 2>/dev/null || true) == active && $SECONDS -lt $deadline ]]; do sleep 1; done
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || die "tikv did not stop within 120s; no escalation sent"
  [[ $(systemctl is-active pd) == active ]] || die "production pd changed during tikv stop"
  printf 'stop_pass_epoch\t%s\n' "$(date +%s)" >> "$STATE"
  printf 'S04A1_PROD_STOP_PASS node=%s state=%s\n' "$NODE_IP" "$STATE"
}

plan_start() {
  host_guard; assert_stopped_state; no_temporary_resources
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || die "production tikv already active"
  printf 'MODE=PROD_START_PLAN_ONLY\nRUN_ID=%s\nNODE=%s\n' "$RUN_ID" "$NODE_IP"
  printf 'sudo systemctl start tikv\nAUTH_REQUIRED=S04A1_PROD_AUTH=04-2-prod-start-%s-%s-%s\n' \
    "$RUN_ID" "$NODE_IP" "$(state_one "$STATE" fingerprint_sha256)"
}

start_prod() {
  local deadline pid cmd exe cfg
  host_guard; assert_stopped_state; no_temporary_resources
  auth_guard start "$(state_one "$STATE" fingerprint_sha256)"
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || die "production tikv already active"
  sudo systemctl start tikv
  deadline=$((SECONDS + 180))
  while [[ $(systemctl is-active tikv 2>/dev/null || true) != active && $SECONDS -lt $deadline ]]; do sleep 2; done
  [[ $(systemctl is-active tikv) == active ]] || die "tikv did not start within 180s; no restart attempted"
  [[ $(systemctl is-active pd) == active ]] || die "production pd is not active after tikv start"
  pid=$(systemctl show tikv -p MainPID --value); [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/stat ]] || die "invalid restored MainPID"
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline"); exe=$(exe_from_cmdline "$cmd")
  cfg=$(printf '%s\n' "$cmd" | sed -nE 's/.*--config(=|[[:space:]])([^[:space:]]+).*/\2/p')
  [[ $exe == $(state_one "$STATE" exe) && $cfg == $(state_one "$STATE" config) ]] || die "restored exe/config mismatch"
  { printf 'restore_epoch\t%s\nnew_pid\t%s\nnew_starttime\t%s\n' "$(date +%s)" "$pid" "$(awk '{print $22}' /proc/$pid/stat)"; cat "$STATE"; } > "$AUDIT"
  printf 'S04A1_PROD_START_PASS node=%s pid=%s audit=%s; global store verification remains required\n' "$NODE_IP" "$pid" "$AUDIT"
}

case "$ACTION" in
  plan-stop) plan_stop ;;
  stop) stop_prod ;;
  plan-start) plan_start ;;
  start) start_prod ;;
  *) die "usage: $0 plan-stop|stop|plan-start|start RUN_ID NODE_IP" ;;
esac
