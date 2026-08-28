#!/usr/bin/env bash
# Execute the frozen R01..R08 sequence after all preregistered preflight gates.
# No retry, replacement, dynamic arm choice, or ad-hoc cleanup is implemented.
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}
t66_check_run_id "$RUN_ID"
case "$ACTION" in plan|run) ;; *) t66_die 'usage: t66-formal-matrix.sh plan|run RUN_ID';; esac
ROOT="/tmp/production/opencode-t3.22c-${RUN_ID}"
REMOTE_DIR="/tmp/jfs-t66-${RUN_ID}-scripts"
MATRIX=(R01 R02 R03 R04 R05 R06 R07 R08)
CURRENT_INSTANCE=R01
CURRENT_PHASE=precheck
t66_assert_abs_scoped_path "$REMOTE_DIR" "$RUN_ID"

if [[ "$ACTION" == plan ]]; then
  printf 'MODE=FORMAL_MATRIX_PLAN_ONLY\nrun_id=%s\nsequence=%s\n' "$RUN_ID" "${MATRIX[*]}"
  for instance in "${MATRIX[@]}"; do
    bash "$SCRIPT_DIR/t66-formal-arm-lifecycle.sh" plan "$RUN_ID" "$instance"
  done
  printf '%s\n' 'After R08: start exact frozen production TiKV on three nodes; matrix analysis; normal finalize/archive.'
  exit 0
fi

t66_make_ssh_array
t66_require_tools sshpass ssh python3 tee
[[ -s "$ROOT/control/AUTONOMY_INITIALIZED" && -s "$ROOT/control/FORMAL_MATRIX_AUTHORIZED.tsv" ]] ||
  t66_die 'autonomy/formal authorization markers missing'
[[ ! -e "$ROOT/RUN_INVALID.tsv" ]] || t66_die 'RUN is already invalid'
for marker in \
  "$ROOT/seeds/formal/SEED_BUNDLE_PASS" \
  "$ROOT/instances/RESTORE-PREFLIGHT-B1c/CLONE_PASS" \
  "$ROOT/instances/RESTORE-PREFLIGHT-D1/CLONE_PASS" \
  "$ROOT/instances/GC-PREFLIGHT/GC_INSPECT_PASS" \
  "$ROOT/instances/ARM-CANARY-B1c/arm-analysis.json" \
  "$ROOT/instances/ARM-CANARY-D1/arm-analysis.json"; do
  [[ -s "$marker" ]] || t66_die "formal prerequisite missing: $marker"
done

record_matrix_failure() {
  local rc=$? line=${BASH_LINENO[0]:-unknown} evidence
  trap - ERR
  evidence="$ROOT/control/formal-matrix-failure-$(date +%s%N).tsv"
  printf 'epoch\t%s\ninstance\t%s\nphase\t%s\nline\t%s\nrc\t%s\n' \
    "$(date +%s)" "$CURRENT_INSTANCE" "$CURRENT_PHASE" "$line" "$rc" > "$evidence"
  if [[ ! -e "$ROOT/RUN_INVALID.tsv" ]]; then
    bash "$SCRIPT_DIR/t66-autonomy.sh" mark-invalid "$RUN_ID" "$CURRENT_INSTANCE" \
      "formal-matrix-failure-phase-${CURRENT_PHASE}-rc-${rc}" "$evidence" || true
  fi
  printf 'FORMAL_MATRIX_PRESERVE instance=%s phase=%s rc=%s evidence=%s\n' \
    "$CURRENT_INSTANCE" "$CURRENT_PHASE" "$rc" "$evidence" >&2
  exit "$rc"
}
trap record_matrix_failure ERR

for instance in "${MATRIX[@]}"; do
  CURRENT_INSTANCE=$instance
  CURRENT_PHASE=arm-lifecycle
  if ! bash "$SCRIPT_DIR/t66-formal-arm-lifecycle.sh" run "$RUN_ID" "$instance"; then
    printf 'FORMAL_MATRIX_STOP failed_instance=%s; RUN_INVALID must be closed, never resumed\n' "$instance" >&2
    exit 42
  fi
  if [[ "$instance" == R02 ]]; then
    CURRENT_PHASE=first-pair-contract
    python3 - "$ROOT" <<'PY'
import json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
rows = []
for name, arm in (("R01", "B1c"), ("R02", "D1")):
    p = root / "instances" / name / "arm-analysis.json"
    d = json.loads(p.read_text())
    assert d["evidence_class"] == "FORMAL" and d["evidence_valid"] is True
    assert d["arm"] == arm
    rows.append((name, arm, d["formal_median_MiBs"], d["cv_pct"], d["w4_w1"]))
out = root / "control" / "FIRST_PAIR_CONTRACT_PASS.tsv"
assert not out.exists()
out.write_text("epoch\t%d\n" % int(time.time()) +
               "instance\tarm\tmedian_MiBs\tcv_pct\tw4_w1\n" +
               "".join("%s\t%s\t%.9f\t%.9f\t%.9f\n" % r for r in rows))
PY
    bash "$SCRIPT_DIR/t66-autonomy.sh" progress "$RUN_ID" R02 first-pair \
      "$ROOT/control/FIRST_PAIR_CONTRACT_PASS.tsv"
  fi
done

[[ -s "$ROOT/instances/G08/POST_FINAL_DESTROY_PASS" ]] || t66_die 'R08 final seed/pool closure missing'

CURRENT_PHASE=production-restore
for node in "${T66_NODES[@]}"; do
  plan="$ROOT/control/prod-start-plan-${node}.txt"
  "${T66_SSH[@]}" "$node" bash "$REMOTE_DIR/t66-prod-start-one.sh" plan "$RUN_ID" "$node" > "$plan"
  token=$(sed -n 's/^AUTH_REQUIRED=T66_PROD_START_AUTH=//p' "$plan")
  [[ "$token" =~ ^03-22c-prod-start-${RUN_ID}-${node}-[0-9a-f]{64}$ ]] || t66_die "invalid production start token: $node"
  "${T66_SSH[@]}" "$node" env LC_ALL=C "T66_PROD_START_AUTH=$token" \
    bash "$REMOTE_DIR/t66-prod-start-one.sh" start "$RUN_ID" "$node"
done

CURRENT_PHASE=matrix-analysis
mkdir -p "$ROOT/analysis"
python3 "$SCRIPT_DIR/t66-analyze.py" --matrix "$ROOT" > "$ROOT/analysis/matrix-analysis.stdout"
CURRENT_PHASE=finalize
bash "$SCRIPT_DIR/t66-finalize.sh" "$RUN_ID" normal
trap - ERR
printf 'FORMAL_MATRIX_PASS run_id=%s valid_arms=8 production_restored=yes\n' "$RUN_ID"
