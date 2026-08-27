#!/usr/bin/env bash
# Local-only autonomous-run control plane for GLM. It records progress/issues;
# it never performs SSH, sudo, service, storage, cluster, JuiceFS, Ceph, or fio actions.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
t66_check_run_id "$RUN_ID"
ROOT="/tmp/production/opencode-t3.22c-${RUN_ID}"
CONTROL="$ROOT/control"
LEDGER=$(t66_incident_ledger "$RUN_ID")

init() {
  [[ ! -e "$CONTROL/AUTONOMY_INITIALIZED" ]] || t66_die 'autonomy control already initialized'
  mkdir -p "$CONTROL/progress"
  t66_record_incident "$RUN_ID" setup GLOBAL INFO initialized "$CONTROL" none continue
  printf 'run_id\t%s\ninit_epoch\t%s\nmode\tautonomous-with-fail-closed-boundaries\n' "$RUN_ID" "$(date +%s)" > "$CONTROL/AUTONOMY_INITIALIZED"
  printf 'AUTONOMY_INIT_PASS run_id=%s ledger=%s\n' "$RUN_ID" "$LEDGER"
}

record() {
  (($# == 7)) || t66_die 'record requires PHASE INSTANCE SEVERITY SYMPTOM EVIDENCE ACTION DECISION'
  t66_record_incident "$RUN_ID" "$@"
  printf 'INCIDENT_RECORDED run_id=%s phase=%s instance=%s\n' "$RUN_ID" "$1" "$2"
}

progress() {
  local instance=${3:-} phase=${4:-} evidence=${5:-} marker
  t66_check_instance "$instance"
  [[ "$phase" =~ ^[A-Za-z0-9._-]+$ && "$evidence" == /* && -s "$evidence" ]] || t66_die 'invalid progress evidence'
  marker="$CONTROL/progress/${instance}-${phase}.tsv"
  [[ ! -e "$marker" ]] || t66_die "progress marker already exists: $marker"
  printf 'epoch\t%s\ninstance\t%s\nphase\t%s\nevidence\t%s\nevidence_sha256\t%s\n' \
    "$(date +%s)" "$instance" "$phase" "$evidence" "$(sha256sum "$evidence" | awk '{print $1}')" > "$marker"
  printf 'PROGRESS_RECORDED %s %s\n' "$instance" "$phase"
}

mark_invalid() {
  local failed=${3:-} reason=${4:-} evidence=${5:-}
  [[ "$failed" =~ ^R0[1-8]$ && -n "$reason" && "$reason" != *$'\t'* && -s "$evidence" ]] || t66_die 'invalid RUN_INVALID arguments'
  [[ ! -e "$ROOT/RUN_INVALID.tsv" ]] || t66_die 'RUN_INVALID already exists'
  printf 'classification\tEVIDENCE_INVALID\nfailed_instance\t%s\nreason\t%s\nevidence\t%s\nevidence_sha256\t%s\nepoch\t%s\n' \
    "$failed" "$reason" "$evidence" "$(sha256sum "$evidence" | awk '{print $1}')" "$(date +%s)" > "$ROOT/RUN_INVALID.tsv"
  t66_record_incident "$RUN_ID" formal "$failed" FATAL "$reason" "$evidence" invalid-closure stop-formal-matrix
  printf 'RUN_INVALID_RECORDED failed_instance=%s\n' "$failed"
}

status() {
  [[ -s "$CONTROL/AUTONOMY_INITIALIZED" && -s "$LEDGER" ]] || t66_die 'autonomy control is not initialized'
  printf 'run_id=%s\ninvalid=%s\nincident_rows=%s\nprogress_markers=%s\n' "$RUN_ID" \
    "$([[ -e "$ROOT/RUN_INVALID.tsv" ]] && printf yes || printf no)" \
    "$(( $(wc -l < "$LEDGER") - 1 ))" \
    "$(find "$CONTROL/progress" -maxdepth 1 -type f -name '*.tsv' | wc -l)"
}

case "$ACTION" in
  init) init;;
  record) shift 2; record "$@";;
  progress) progress "$@";;
  mark-invalid) mark_invalid "$@";;
  status) status;;
  *) t66_die 'usage: t66-autonomy.sh init|record|progress|mark-invalid|status RUN_ID ...';;
esac
