#!/usr/bin/env bash
# Minimal serial coordinator for reviewed 04-2 building blocks. No hidden rollback.
set -euo pipefail
export LC_ALL=C
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/s04a1-runtime-common.sh"

ACTION=${1:-plan}; RUN_ID=${2:-}; INSTANCE=${3:-}
s04a1_check_run_id "$RUN_ID"
ROOT="/tmp/production/opencode-04-2-$RUN_ID"
REMOTE="/tmp/jfs-s04a1-$RUN_ID-scripts"
LOG="$ROOT/control/lifecycle.log"
mkdir -p "$ROOT/control"

log() { printf '%s\t%s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
node_cmd() { local node=$1; shift; ssh -o BatchMode=yes -o ConnectTimeout=8 "sunrise@$node" "$@"; }

storage() {
  local verb=$1 arm=$2 inst=$3 node token
  for node in "${S04A1_NODES[@]}"; do
    token="04-2-storage-${verb}-${RUN_ID}-${node}"
    log "storage $verb node=$node arm=$arm instance=$inst"
    node_cmd "$node" env "S04A1_STORAGE_AUTH=$token" bash "$REMOTE/s04a1-storage.sh" "$verb" "$RUN_ID" "$node" "$arm" "$inst"
  done
}

cluster() {
  local verb=$1 arm=$2 inst=$3 storage_inst=$4 token
  case "$verb" in
    render)
      token="04-2-instance-${RUN_ID}-${inst}-${arm}"
      env "S04A1_INSTANCE_AUTH=$token" "S04A1_STORAGE_INSTANCE=$storage_inst" bash "$DIR/s04a1-cluster-orchestrator.sh" render "$RUN_ID" "$arm" "$inst"
      ;;
    start-pd|start-tikv|stop-tikv|stop-pd)
      token="04-2-cluster-${verb%-*}-${verb#*-}-${RUN_ID}-${arm}-${inst}"
      env "S04A1_CLUSTER_ACTION_AUTH=$token" "S04A1_STORAGE_INSTANCE=$storage_inst" bash "$DIR/s04a1-cluster-orchestrator.sh" "$verb" "$RUN_ID" "$arm" "$inst"
      ;;
    verify) env "S04A1_STORAGE_INSTANCE=$storage_inst" bash "$DIR/s04a1-cluster-orchestrator.sh" verify "$RUN_ID" "$arm" "$inst" ;;
    *) s04a1_die "invalid cluster verb: $verb" ;;
  esac
}

start_cluster() {
  local storage_inst=$1 inst=$2 arm node; arm=$(s04a1_expected_cluster "$storage_inst")
  [[ $storage_inst =~ ^R0[1-8]$ && $(s04a1_expected_cluster "$inst") == "$arm" ]] || s04a1_die 'cluster/storage arm mismatch'
  for node in "${S04A1_NODES[@]}"; do
    [[ $(node_cmd "$node" 'systemctl is-active tikv 2>/dev/null || true') != active ]] || s04a1_die "production TiKV active: $node"
  done
  cluster render "$arm" "$inst" "$storage_inst"
  cluster start-pd "$arm" "$inst" "$storage_inst"
  cluster start-tikv "$arm" "$inst" "$storage_inst"
  cluster verify "$arm" "$inst" "$storage_inst"
  log "CLUSTER_START_PASS arm=$arm instance=$inst storage=$storage_inst"
}

stop_cluster() {
  local storage_inst=$1 inst=$2 arm; arm=$(s04a1_expected_cluster "$storage_inst")
  cluster stop-tikv "$arm" "$inst" "$storage_inst"
  cluster stop-pd "$arm" "$inst" "$storage_inst"
  log "CLUSTER_STOP_PASS arm=$arm instance=$inst storage=$storage_inst"
}

reset_storage() {
  local storage_inst=$1 arm; arm=$(s04a1_expected_cluster "$storage_inst")
  storage reset-active "$arm" "$storage_inst"
}

seed_formal() {
  local storage_inst=${1:-R01} arm=C inst=SEED-FORMAL
  [[ $storage_inst == R01 ]] || s04a1_die 'formal seed is bound to R01 storage'
  start_cluster "$storage_inst" "$inst"
  env S04A1_SEED_FORMAT_AUTH="04-2-seed-format-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-seed.sh" format-mount "$RUN_ID" "$arm" "$inst"
  env S04A1_SEED_LAYOUT_AUTH="04-2-seed-layout-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-seed.sh" layout "$RUN_ID" "$arm" "$inst"
  env S04A1_RESET_AUTH="04-2-reset-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-reset-gates.sh" prepare "$RUN_ID" "$arm" "$inst"
  env S04A1_SEED_UMOUNT_AUTH="04-2-seed-umount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-seed.sh" umount "$RUN_ID" "$arm" "$inst"
  env S04A1_SEED_DUMP_AUTH="04-2-seed-dump-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-seed.sh" dump "$RUN_ID" "$arm" "$inst"
  sleep 70
  stop_cluster "$storage_inst" "$inst"
  reset_storage "$storage_inst"
  log SEED_FORMAL_PASS
}

restore_preflight() {
  local storage_inst=$1 inst=$2 arm; arm=$(s04a1_expected_cluster "$inst")
  [[ $inst == RESTORE-PREFLIGHT-C || $inst == RESTORE-PREFLIGHT-L ]] || s04a1_die 'preflight instance required'
  [[ $(s04a1_expected_cluster "$storage_inst") == "$arm" ]] || s04a1_die 'preflight storage arm mismatch'
  start_cluster "$storage_inst" "$inst"
  env S04A1_RESTORE_AUTH="04-2-restore-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" load "$RUN_ID" "$arm" "$inst"
  env S04A1_RESTORE_MOUNT_AUTH="04-2-restore-mount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" mount "$RUN_ID" "$arm" "$inst"
  env S04A1_CLONE_AUTH="04-2-clone-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" clone "$RUN_ID" "$arm" "$inst"
  env S04A1_RESTORE_UMOUNT_AUTH="04-2-restore-umount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" umount "$RUN_ID" "$arm" "$inst"
  sleep 70
  stop_cluster "$storage_inst" "$inst"
  reset_storage "$storage_inst"
  log "RESTORE_PREFLIGHT_PASS arm=$arm instance=$inst"
}

gc_cleanup() {
  local storage_inst=$1 prior=$2 gc=$3 arm; arm=$(s04a1_expected_cluster "$storage_inst")
  [[ $(s04a1_expected_cluster "$gc") == "$arm" ]] || s04a1_die 'GC/storage arm mismatch'
  # GC metadata is loaded on the same approved Rxx storage.  It sees the
  # immutable seed after the prior cluster's local metadata was removed.
  start_cluster "$storage_inst" "$gc"
  env S04A1_RESTORE_AUTH="04-2-restore-${RUN_ID}-${gc}-${arm}" bash "$DIR/s04a1-volume-restore.sh" load "$RUN_ID" "$arm" "$gc"
  sleep 70
  bash "$DIR/s04a1-gc-return.sh" inspect "$RUN_ID" "$arm" "$gc"
  env S04A1_GC_DELETE_AUTH="04-2-gc-delete-${RUN_ID}-${gc}-${arm}" bash "$DIR/s04a1-gc-return.sh" delete "$RUN_ID" "$arm" "$gc"
  env S04A1_RESET_AUTH="04-2-reset-${RUN_ID}-${gc}-${arm}" bash "$DIR/s04a1-reset-gates.sh" seed-return "$RUN_ID" "$arm" "$gc"
  if [[ $prior == R08 ]]; then
    env S04A1_SEED_DESTROY_AUTH="04-2-seed-destroy-${RUN_ID}-${gc}-${arm}" bash "$DIR/s04a1-gc-return.sh" final-destroy "$RUN_ID" "$arm" "$gc"
    env S04A1_RESET_AUTH="04-2-reset-${RUN_ID}-${gc}-${arm}" bash "$DIR/s04a1-reset-gates.sh" post-final-destroy "$RUN_ID" "$arm" "$gc"
  fi
  stop_cluster "$storage_inst" "$gc"
  reset_storage "$storage_inst"
  log "GC_ARM_PASS prior=$prior gc=$gc"
}

arm_canary() {
  local storage_inst=$1 inst=$2 gc arm; arm=$(s04a1_expected_cluster "$inst")
  [[ $(s04a1_expected_cluster "$storage_inst") == "$arm" ]] || s04a1_die 'canary storage arm mismatch'
  if [[ $arm == C ]]; then gc=GC-ARM-CANARY-C; else gc=GC-ARM-CANARY-L; fi
  start_cluster "$storage_inst" "$inst"
  env S04A1_RESTORE_AUTH="04-2-restore-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" load "$RUN_ID" "$arm" "$inst"
  env S04A1_RESTORE_MOUNT_AUTH="04-2-restore-mount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" mount "$RUN_ID" "$arm" "$inst"
  env S04A1_CLONE_AUTH="04-2-clone-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" clone "$RUN_ID" "$arm" "$inst"
  env S04A1_RESET_AUTH="04-2-reset-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-reset-gates.sh" prepare "$RUN_ID" "$arm" "$inst"
  env S04A1_STORAGE_INSTANCE="$storage_inst" S04A1_ARM_CANARY_AUTH="04-2-arm-canary-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-run-arm.sh" "$RUN_ID" "$arm" "$inst"
  env S04A1_RESTORE_UMOUNT_AUTH="04-2-restore-umount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" umount "$RUN_ID" "$arm" "$inst"
  sleep 70
  stop_cluster "$storage_inst" "$inst"
  reset_storage "$storage_inst"
  gc_cleanup "$storage_inst" "$inst" "$gc"
  log "ARM_CANARY_CLOSURE_PASS arm=$arm storage=$storage_inst"
}

formal_arm() {
  local inst=$1 arm; arm=$(s04a1_expected_cluster "$inst")
  [[ $inst =~ ^R0[1-8]$ ]] || s04a1_die 'formal R01..R08 required'
  if ! node_cmd 10.20.1.150 "test -s /tmp/s04a1-${RUN_ID}-storage-active-${inst}-150.tsv"; then
    storage activate "$arm" "$inst"
  fi
  start_cluster "$inst" "$inst"
  env S04A1_RESTORE_AUTH="04-2-restore-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" load "$RUN_ID" "$arm" "$inst"
  env S04A1_RESTORE_MOUNT_AUTH="04-2-restore-mount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" mount "$RUN_ID" "$arm" "$inst"
  env S04A1_CLONE_AUTH="04-2-clone-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" clone "$RUN_ID" "$arm" "$inst"
  env S04A1_RESET_AUTH="04-2-reset-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-reset-gates.sh" prepare "$RUN_ID" "$arm" "$inst"
  env S04A1_STORAGE_INSTANCE="$inst" S04A1_FIO_AUTH="04-2-fio-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-run-arm.sh" "$RUN_ID" "$arm" "$inst"
  env S04A1_RESTORE_UMOUNT_AUTH="04-2-restore-umount-${RUN_ID}-${inst}-${arm}" bash "$DIR/s04a1-volume-restore.sh" umount "$RUN_ID" "$arm" "$inst"
  sleep 70
  stop_cluster "$inst" "$inst"
  reset_storage "$inst"
  gc_cleanup "$inst" "$inst" "G${inst#R}"
  storage deactivate "$arm" "$inst"
  log "FORMAL_ARM_PASS arm=$arm instance=$inst"
}

case "$ACTION" in
  plan)
    printf 'PLAN_ONLY\nBASE=create once on 150,151,152\nSEED=SEED-FORMAL on approved R01(C) storage\nPREFLIGHT=C on R01; L on R02\nCAPACITY_CANARY=C on R01; L on R02\nMATRIX=R01,R02,R03,R04,R05,R06,R07,R08\nGC=matching storage, including canaries and G01..G08\nBASE_DESTROY=after G08\n'
    ;;
  base-create) storage create-base C R01 ;;
  base-destroy) storage destroy-base C R01 ;;
  arm-activate) storage activate "$(s04a1_expected_cluster "$INSTANCE")" "$INSTANCE" ;;
  arm-deactivate) storage deactivate "$(s04a1_expected_cluster "$INSTANCE")" "$INSTANCE" ;;
  seed-formal) seed_formal R01 ;;
  restore-preflight)
    if [[ $INSTANCE == RESTORE-PREFLIGHT-C ]]; then restore_preflight R01 "$INSTANCE"; else restore_preflight R02 "$INSTANCE"; fi
    ;;
  arm-canary)
    if [[ $INSTANCE == ARM-CANARY-C ]]; then arm_canary R01 "$INSTANCE"; else arm_canary R02 "$INSTANCE"; fi
    ;;
  formal-arm) formal_arm "$INSTANCE" ;;
  *) s04a1_die 'usage: lifecycle plan|base-create|base-destroy|arm-activate|arm-deactivate|seed-formal|restore-preflight|arm-canary|formal-arm RUN_ID [INSTANCE]' ;;
esac
