#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER="$SCRIPT_DIR/t04-8-analyze.py"
EXECUTOR="$SCRIPT_DIR/t04-8-phase-a.sh"
TASKBOOK="$SCRIPT_DIR/../../../doc/perf-tasks/04-8-max-fuse-io-1m-formal-validation.md"
RUN_ID=${1:-}
GATE_ROOT=${T048_GATE_ROOT:-}

die() { printf 'T048_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ ${RUN_ID:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'usage: t04-8-gate0-offline.sh RUN_ID'
GATE_ROOT=${GATE_ROOT:-/mnt/c/SunRise/test/04-8/gate0-$RUN_ID}
[[ "$GATE_ROOT" == "/mnt/c/SunRise/test/04-8/gate0-$RUN_ID" ]] || die unsafe_gate_root
[[ -f "$TASKBOOK" && ! -L "$TASKBOOK" ]] || die taskbook_missing
[[ -f "$ANALYZER" && ! -L "$ANALYZER" ]] || die analyzer_missing
[[ -f "$EXECUTOR" && ! -L "$EXECUTOR" ]] || die executor_missing
if ! mkdir -m 0700 -p "$GATE_ROOT" 2>"${TMPDIR:-/tmp}/t048-gate0-mkdir.err"; then
  printf 'T048_GATE0_BLOCKED_PERSISTENCE\t%s\t%s\n' "$GATE_ROOT" "$(tr '\n' ' ' <"${TMPDIR:-/tmp}/t048-gate0-mkdir.err")" >&2
  exit 3
fi

bash -n "$0"
bash -u -n "$0"
bash -n "$EXECUTOR"
python3 -m py_compile "$ANALYZER"
python3 "$ANALYZER" self-test | tee "$GATE_ROOT/analyzer-self-test.txt"
grep -Fq T048_ANALYZER_SELF_TEST_PASS "$GATE_ROOT/analyzer-self-test.txt" || die analyzer_self_test

# Only scan the execution helper, not this gate's own grep expressions.
if grep -nE '(^|[;&|[:space:]])(sudo|ssh|scp|reboot|shutdown|systemctl|pkill|killall|fuser[[:space:]]+-k|drop_caches|umount|rm[[:space:]]+-r|wipefs|dd[[:space:]])' "$ANALYZER"; then
  die analyzer_contains_operational_or_destructive_command
fi
if awk '!/^[[:space:]]*#/' "$EXECUTOR" | grep -nE '(^|[;&|])[[:space:]]*(sudo|ssh|scp|reboot|shutdown|systemctl|pkill|killall|fuser[[:space:]]+-k|drop_caches|umount[[:space:]]+-[lf]|rm[[:space:]]+-r|wipefs|dd[[:space:]]+|ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+delete|juicefs[[:space:]]+(format|destroy))'; then
  die executor_contains_forbidden_operation
fi
if grep -nE 'sudo[[:space:]]+ceph[[:space:]]+tell.*compact|sudo[[:space:]]+ceph[[:space:]]+config[[:space:]]+set|juicefs[[:space:]]+(format|destroy)' "$EXECUTOR"; then
  die executor_contains_phase_b_forbidden_write
fi

for needle in \
  'EVIDENCE_LEVEL=L2_FORMAL' \
  'FORMAL_MATRIX=Phase A: ABBA-BAAB' \
  'Phase B: ABBA四个独立mount' \
  'STOP_AFTER_ANSWER=YES' \
  'EVIDENCE_ROOT=/mnt/c/SunRise/test/04-8/<RUN_ID>' \
  'REMOTE_RESULT_ROOT=/tmp/production/opencode-04-8-<RUN_ID>' \
  '--max-fuse-io 256K' \
  '--max-fuse-io 1M' \
  'S01' 'S08' 'C01' 'C04' \
  'Phase A不通过即停止' \
  'PERSISTENCE_PASS'; do
  grep -Fq -- "$needle" "$TASKBOOK" || die "taskbook_contract_missing:$needle"
done

grep -Fq '10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod' "$EXECUTOR" || die meta_contract_missing
if grep -Fq '12379' "$EXECUTOR"; then die forbidden_meta_port; fi
test "$(grep -Fc '$REMOTE_ROOT/cells/$cell/metrics-port.txt' "$EXECUTOR")" -eq 3 || die metrics_port_consumer_path_contract
if grep -Fq '$REMOTE_ROOT/mounts/$cell/metrics-port.txt' "$EXECUTOR"; then die stale_metrics_port_consumer_path; fi
grep -Fq 'CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730' "$EXECUTOR" || die ceph_conf_pin_missing
grep -Fq '10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod' "$TASKBOOK" || die taskbook_meta_contract_missing

for needle in \
  'phase-a-matrix.tsv' 'sudo-write-plan.tsv' 'I_ACK_04_8_PHASE_A_' \
  'mount-process.tsv' 'mount-state.tsv' '--allow_file_create=0' \
  'graceful_umount' 'PHASE_A_CLOSURE_PASS' 'ENVIRONMENT_ASSET_STATUS=OPEN' \
  'metrics_snapshot' 'metrics-delta.json' 'recovery_gate' 'tikv_pending_snapshot' \
  'gc_after_write' 'JFS_GC_SKIPPEDTIME=0' 'cleanup-plan' 'scrub-pause' 'scrub-restore'; do
  grep -Fq -- "$needle" "$EXECUTOR" || die "executor_contract_missing:$needle"
done

for needle in \
  'phase-b RUN_ID I_ACK_04_8_PHASE_B_' 'phase-b)' 'phase_b_workload' \
  'scrub-pause-b RUN_ID FSID' 'scrub-restore-b RUN_ID' 'state-b/SCRUB_PAUSED_B' \
  'I_ACK_04_8_PHASE_${phase^^}_$run' 'I_ACK_04_8_PHASE_${phase^^}_RESTORE_$run' \
  'lease="${run}-phase-${phase,,}"' \
  'PHASE_B_STARTED' 'PHASE_B_PASS' 'phase-b-matrix.tsv' \
  'scrub_pause_lease' 'scrub_restore_lease' 'SCRUB_PAUSED_B' \
  'C01' 'C02' 'C03' 'C04' 'rwmixread=50' \
  '--readonly' '--randseed=20260907' 'PHASE_B_ASSET_PASS' 'ENDPOINT_PASS' \
  'workloads=(mseqread seqread randread mseqwrite randwrite randrw)' \
  'mseqwrite|randwrite|randrw' 'derived/phase-b.json'; do
  grep -Fq -- "$needle" "$EXECUTOR" || die "phase_b_executor_contract_missing:$needle"
done

python3 - "$EXECUTOR" <<'PY'
import sys
text = open(sys.argv[1]).read()
needle = 'fio_seqwrite "$cell" "$mnt"\n    gc_after_write "$cell"\n    recovery_gate "$cell" "$O1"'
if needle not in text:
    raise SystemExit('write/GC/recovery order contract missing')
PY

grep -Fq 'workload in {"mseqread", "mseqwrite"}' "$ANALYZER" || die mseqread_jobs_contract_missing
grep -Fq 'analyze_cell(cell, expected, "read", 0)' "$ANALYZER" || die randrw_read_contract_missing
grep -Fq 'analyze_cell(cell, expected, "write", 1)' "$ANALYZER" || die randrw_write_contract_missing
grep -Fq 'column 3 (ddir)' "$ANALYZER" || die randrw_ddir_contract_missing
grep -Fq '3.287' "$ANALYZER" || die detector_calibration_missing
grep -Fq 'detector_max_ns_per_byte' "$ANALYZER" || die detector_one_sided_ceiling_missing
grep -Fq 'pre.get(name, 0.0)' "$ANALYZER" || die zero_suppressed_pre_counter_contract_missing
grep -Fq 'detector_gate' "$ANALYZER" || die detector_gate_missing

# The taskbook intentionally names forbidden operations in its safety section;
# scan executable helpers above, and do not mistake that prose for a command.

sha256sum "$ANALYZER" "$EXECUTOR" "$0" "$TASKBOOK" >"$GATE_ROOT/input-sha256.tsv"
printf 'taskbook=%s\n' "$TASKBOOK" >"$GATE_ROOT/contract.tsv"
printf 'T048_GATE0_PASS\t%s\n' "$GATE_ROOT"
