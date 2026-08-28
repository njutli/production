#!/usr/bin/env bash
# Execute one frozen formal 03-22c arm and its matching GC return.
#
# This coordinator contains no ad-hoc recovery.  It invokes only the reviewed,
# state-guarded t66 entry points.  Any error is recorded, marks the formal RUN
# invalid, and preserves the exact state for the separately reviewed closure.
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}
INSTANCE=${3:-}
t66_check_run_id "$RUN_ID"
t66_check_instance "$INSTANCE"
t66_is_formal_arm "$INSTANCE" || t66_die 'formal arm lifecycle requires R01..R08'
ARM=$(t66_expected_cluster "$INSTANCE")
GC_INSTANCE="G${INSTANCE#R}"
ROOT="/tmp/production/opencode-t3.22c-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
GC_OUT="$ROOT/instances/$GC_INSTANCE"
REMOTE_DIR="/tmp/jfs-t66-${RUN_ID}-scripts"
LOG="$ROOT/control/formal-${INSTANCE}-driver.log"
CURRENT_PHASE=precheck
t66_assert_abs_scoped_path "$REMOTE_DIR" "$RUN_ID"

case "$ACTION" in plan|run) ;; *) t66_die 'usage: t66-formal-arm-lifecycle.sh plan|run RUN_ID R01..R08';; esac

record_failure() {
  local rc=$? line=${BASH_LINENO[0]:-unknown} evidence
  trap - ERR
  mkdir -p "$ROOT/control"
  evidence="$ROOT/control/formal-${INSTANCE}-failure-$(date +%s%N).tsv"
  printf 'epoch\t%s\ninstance\t%s\narm\t%s\ngc_instance\t%s\nphase\t%s\nline\t%s\nrc\t%s\n' \
    "$(date +%s)" "$INSTANCE" "$ARM" "$GC_INSTANCE" "$CURRENT_PHASE" "$line" "$rc" > "$evidence"
  if [[ ! -e "$ROOT/RUN_INVALID.tsv" ]]; then
    bash "$SCRIPT_DIR/t66-autonomy.sh" mark-invalid "$RUN_ID" "$INSTANCE" \
      "formal-driver-failure-phase-${CURRENT_PHASE}-rc-${rc}" "$evidence" || true
  else
    bash "$SCRIPT_DIR/t66-autonomy.sh" record "$RUN_ID" formal "$INSTANCE" ERROR \
      "additional-driver-failure-phase-${CURRENT_PHASE}-rc-${rc}" "$evidence" preserve-state stop || true
  fi
  printf 'FORMAL_DRIVER_STOP instance=%s phase=%s rc=%s evidence=%s\n' \
    "$INSTANCE" "$CURRENT_PHASE" "$rc" "$evidence" >&2
  exit "$rc"
}

run_logged() {
  local label=$1
  shift
  printf '%s\tBEGIN\t%s\n' "$(date -Is)" "$label" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  printf '%s\tPASS\t%s\n' "$(date -Is)" "$label" | tee -a "$LOG"
}

remote_logged() {
  local node=$1 label=$2
  shift 2
  run_logged "$label@$node" "${T66_SSH[@]}" "$node" "$@"
}

storage_create_all() {
  local node token
  for node in "${T66_NODES[@]}"; do
    token="03-22c-storage-create-${RUN_ID}-${node}"
    remote_logged "$node" "storage-create-$INSTANCE" env LC_ALL=C \
      "T66_STORAGE_CREATE_AUTH=$token" bash "$REMOTE_DIR/t66-storage-create-one.sh" create "$RUN_ID" "$node"
  done
}

storage_activate_all() {
  local cluster=$1 instance=$2 node token
  for node in "${T66_NODES[@]}"; do
    token="03-22c-activate-${RUN_ID}-${cluster}-${instance}-${node}"
    remote_logged "$node" "activate-$cluster-$instance" env LC_ALL=C \
      "T66_ACTIVATE_AUTH=$token" bash "$REMOTE_DIR/t66-storage-activate-arm.sh" \
      activate "$RUN_ID" "$cluster" "$instance" "$node"
  done
}

storage_deactivate_all() {
  local cluster=$1 instance=$2 node token
  for node in "${T66_NODES[@]}"; do
    token="03-22c-deactivate-${RUN_ID}-${cluster}-${instance}-${node}"
    remote_logged "$node" "deactivate-$cluster-$instance" env LC_ALL=C \
      "T66_DEACTIVATE_AUTH=$token" bash "$REMOTE_DIR/t66-storage-deactivate-arm.sh" \
      deactivate "$RUN_ID" "$cluster" "$instance" "$node"
  done
}

storage_destroy_all() {
  local node token
  for node in "${T66_NODES[@]}"; do
    token="03-22c-storage-destroy-${RUN_ID}-${node}"
    remote_logged "$node" "storage-destroy-$INSTANCE" env LC_ALL=C \
      "T66_STORAGE_DESTROY_AUTH=$token" bash "$REMOTE_DIR/t66-storage-destroy-one.sh" destroy "$RUN_ID" "$node"
  done
}

cluster_action() {
  local action=$1 cluster=$2 instance=$3 token
  case "$action" in
    render)
      token="03-22c-instance-${RUN_ID}-${instance}-${cluster}"
      run_logged "cluster-$action-$instance" env "T66_INSTANCE_AUTH=$token" \
        bash "$SCRIPT_DIR/t66-cluster-orchestrator.sh" "$action" "$RUN_ID" "$cluster" "$instance"
      ;;
    start-pd|start-tikv|stop-tikv|stop-pd)
      token="03-22c-cluster-${action%-*}-${action#*-}-${RUN_ID}-${cluster}-${instance}"
      run_logged "cluster-$action-$instance" env "T66_CLUSTER_ACTION_AUTH=$token" \
        bash "$SCRIPT_DIR/t66-cluster-orchestrator.sh" "$action" "$RUN_ID" "$cluster" "$instance"
      ;;
    verify)
      run_logged "cluster-$action-$instance" bash "$SCRIPT_DIR/t66-cluster-orchestrator.sh" \
        "$action" "$RUN_ID" "$cluster" "$instance"
      ;;
    *) t66_die "unsupported cluster action: $action";;
  esac
}

print_plan() {
  printf 'MODE=FORMAL_ARM_LIFECYCLE_PLAN_ONLY\nrun_id=%s\ninstance=%s\narm=%s\ngc_instance=%s\n' \
    "$RUN_ID" "$INSTANCE" "$ARM" "$GC_INSTANCE"
  printf '%s\n' \
    '1 exact storage create on 150/151/152' \
    "2 exact $ARM activation for $INSTANCE" \
    "3 temporary cluster render/start/verify for $INSTANCE" \
    '4 seed load/mount/clone and reset prepare' \
    '5 one formal fio plus frozen samplers/analyzer' \
    '6 graceful JuiceFS umount; temporary cluster stop; exact deactivate/destroy' \
    "7 fresh B1c GC cluster $GC_INSTANCE; inspect/delete/seed-return" \
    '8 exact GC cluster stop/deactivate/destroy' \
    'Any failure: append evidence, mark RUN_INVALID, preserve exact state; no automatic broad cleanup.'
}

if [[ "$ACTION" == plan ]]; then
  print_plan
  exit 0
fi

t66_make_ssh_array
t66_require_tools sshpass ssh python3 sha256sum tee
trap record_failure ERR
[[ -s "$ROOT/control/AUTONOMY_INITIALIZED" ]] || t66_die 'autonomy control is not initialized'
[[ -s "$ROOT/control/FORMAL_MATRIX_AUTHORIZED.tsv" ]] || t66_die 'formal matrix authorization marker missing'
[[ ! -e "$ROOT/RUN_INVALID.tsv" ]] || t66_die 'RUN is already invalid'
[[ ! -e "$OUT" && ! -e "$GC_OUT" ]] || t66_die 'formal arm or GC evidence path already exists; replacement is forbidden'

CURRENT_PHASE=arm-storage-create
storage_create_all
CURRENT_PHASE=arm-storage-activate
storage_activate_all "$ARM" "$INSTANCE"
CURRENT_PHASE=arm-cluster
cluster_action render "$ARM" "$INSTANCE"
cluster_action start-pd "$ARM" "$INSTANCE"
cluster_action start-tikv "$ARM" "$INSTANCE"
cluster_action verify "$ARM" "$INSTANCE"

CURRENT_PHASE=arm-restore
run_logged "restore-load-$INSTANCE" env "T66_RESTORE_AUTH=03-22c-restore-${RUN_ID}-${INSTANCE}-${ARM}" \
  bash "$SCRIPT_DIR/t66-restore-volume.sh" load "$RUN_ID" "$ARM" "$INSTANCE"
run_logged "restore-mount-$INSTANCE" env "T66_RESTORE_MOUNT_AUTH=03-22c-restore-mount-${RUN_ID}-${INSTANCE}-${ARM}" \
  bash "$SCRIPT_DIR/t66-restore-volume.sh" mount "$RUN_ID" "$ARM" "$INSTANCE"
run_logged "restore-clone-$INSTANCE" env "T66_CLONE_AUTH=03-22c-clone-${RUN_ID}-${INSTANCE}-${ARM}" \
  bash "$SCRIPT_DIR/t66-restore-volume.sh" clone "$RUN_ID" "$ARM" "$INSTANCE"

CURRENT_PHASE=arm-prepare
run_logged "reset-prepare-$INSTANCE" env "T66_RESET_AUTH=03-22c-reset-${RUN_ID}-${INSTANCE}-${ARM}" \
  bash "$SCRIPT_DIR/t66-reset-gates.sh" prepare "$RUN_ID" "$ARM" "$INSTANCE"
CURRENT_PHASE=arm-fio
run_logged "formal-fio-$INSTANCE" env "T66_FIO_AUTH=03-22c-fio-${RUN_ID}-${INSTANCE}-${ARM}" \
  bash "$SCRIPT_DIR/t66-run-arm.sh" "$RUN_ID" "$ARM" "$INSTANCE"
CURRENT_PHASE=arm-umount
run_logged "restore-umount-$INSTANCE" env "T66_RESTORE_UMOUNT_AUTH=03-22c-restore-umount-${RUN_ID}-${INSTANCE}-${ARM}" \
  bash "$SCRIPT_DIR/t66-restore-volume.sh" umount "$RUN_ID" "$ARM" "$INSTANCE"
sleep 70

CURRENT_PHASE=arm-cluster-stop
cluster_action stop-tikv "$ARM" "$INSTANCE"
cluster_action stop-pd "$ARM" "$INSTANCE"
CURRENT_PHASE=arm-storage-deactivate
storage_deactivate_all "$ARM" "$INSTANCE"
CURRENT_PHASE=arm-storage-destroy
storage_destroy_all

CURRENT_PHASE=gc-storage-create
storage_create_all
CURRENT_PHASE=gc-storage-activate
storage_activate_all B1c "$GC_INSTANCE"
CURRENT_PHASE=gc-cluster
cluster_action render B1c "$GC_INSTANCE"
cluster_action start-pd B1c "$GC_INSTANCE"
cluster_action start-tikv B1c "$GC_INSTANCE"
cluster_action verify B1c "$GC_INSTANCE"
CURRENT_PHASE=gc-restore
run_logged "gc-load-$GC_INSTANCE" env "T66_RESTORE_AUTH=03-22c-restore-${RUN_ID}-${GC_INSTANCE}-B1c" \
  bash "$SCRIPT_DIR/t66-restore-volume.sh" load "$RUN_ID" B1c "$GC_INSTANCE"
sleep 70
CURRENT_PHASE=gc-delete
run_logged "gc-inspect-$GC_INSTANCE" bash "$SCRIPT_DIR/t66-gc-return.sh" inspect "$RUN_ID" B1c "$GC_INSTANCE"
run_logged "gc-delete-$GC_INSTANCE" env "T66_GC_DELETE_AUTH=03-22c-gc-delete-${RUN_ID}-${GC_INSTANCE}-B1c" \
  bash "$SCRIPT_DIR/t66-gc-return.sh" delete "$RUN_ID" B1c "$GC_INSTANCE"
run_logged "gc-seed-return-$GC_INSTANCE" env "T66_RESET_AUTH=03-22c-reset-${RUN_ID}-${GC_INSTANCE}-B1c" \
  bash "$SCRIPT_DIR/t66-reset-gates.sh" seed-return "$RUN_ID" B1c "$GC_INSTANCE"

if [[ "$INSTANCE" == R08 ]]; then
  CURRENT_PHASE=final-seed-destroy
  run_logged "final-seed-destroy-$GC_INSTANCE" env "T66_SEED_DESTROY_AUTH=03-22c-seed-destroy-${RUN_ID}-${GC_INSTANCE}-B1c" \
    bash "$SCRIPT_DIR/t66-gc-return.sh" final-destroy "$RUN_ID" B1c "$GC_INSTANCE"
  run_logged "post-final-destroy-$GC_INSTANCE" env "T66_RESET_AUTH=03-22c-reset-${RUN_ID}-${GC_INSTANCE}-B1c" \
    bash "$SCRIPT_DIR/t66-reset-gates.sh" post-final-destroy "$RUN_ID" B1c "$GC_INSTANCE"
fi

CURRENT_PHASE=gc-cluster-stop
cluster_action stop-tikv B1c "$GC_INSTANCE"
cluster_action stop-pd B1c "$GC_INSTANCE"
CURRENT_PHASE=gc-storage-deactivate
storage_deactivate_all B1c "$GC_INSTANCE"
CURRENT_PHASE=gc-storage-destroy
storage_destroy_all

CURRENT_PHASE=progress
bash "$SCRIPT_DIR/t66-autonomy.sh" progress "$RUN_ID" "$INSTANCE" closure "$OUT/arm-analysis.json"
trap - ERR
printf 'FORMAL_ARM_LIFECYCLE_PASS run_id=%s instance=%s arm=%s gc=%s\n' \
  "$RUN_ID" "$INSTANCE" "$ARM" "$GC_INSTANCE"
