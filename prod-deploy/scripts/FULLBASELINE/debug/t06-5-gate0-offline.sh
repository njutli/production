#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GATE=$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")
DRIVER=$SCRIPT_DIR/t06-5-randrw-cache-driver.sh
ANALYZER=$SCRIPT_DIR/t06-5-randrw-cache-analyze.py
PORTAL=$SCRIPT_DIR/t06-5-portal-maintenance.sh
LEGACY=$SCRIPT_DIR/t06-1-randrw-cache-driver.sh
LEGACY_ANALYZER=$SCRIPT_DIR/t06-1-randrw-analyze.py
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
TASK=$SCRIPT_DIR/../../../doc/perf-tasks/06-5-randrw-cache-writeback-benefit-source-attribution.md
RUN_ID=${1:-20260921-174705}
OUT=${2:-/tmp/t06-5-gate0-$RUN_ID}

die() { printf 'T065_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
[[ $OUT == /* && $OUT != / && ! -e $OUT && ! -L $OUT ]] || die unsafe_or_existing_output
for file in "$DRIVER" "$ANALYZER" "$PORTAL" "$LEGACY" "$LEGACY_ANALYZER" "$SCRUB" "$TASK"; do [[ -s $file && ! -L $file ]] || die "missing_input:$file"; done
mkdir -m 0700 -p "$OUT"

# Only self-test and plan are invoked here.  The guarded online branch is
# inspected but never called.
bash -n "$DRIVER"; bash -u -n "$DRIVER"; bash -n "$PORTAL"; bash -n "$0"
python3 - "$DRIVER" <<'PY'
import pathlib,re,sys
for number,line in enumerate(pathlib.Path(sys.argv[1]).read_text().splitlines(),1):
    stripped=line.strip()
    if not stripped.startswith('local '): continue
    names=re.findall(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=', stripped[6:])
    for name in names:
        if re.search(r'\$\{?'+re.escape(name)+r'(?:\}|[^A-Za-z0-9_])', stripped):
            raise SystemExit(f'unsafe same-local dependency line {number}: {name}')
PY
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANALYZER"
if grep -nE '^[[:space:]]*(ssh|scp|rsync|sudo|mount|umount|fio|ceph|rados|juicefs|curl)([[:space:]]|$)' "$GATE" "$ANALYZER"; then
  die offline_path_contains_environment_command
fi
if grep -nE 'rm[[:space:]]+-rf|fusermount[[:space:]]+-uz|umount[[:space:]]+-l|losetup[[:space:]]+-D|(^|[[:space:];])killall([[:space:];]|$)|(^|[[:space:];])(reboot|shutdown|poweroff)([[:space:];]|$)' "$DRIVER" "$PORTAL" "$LEGACY" "$SCRUB" "$ANALYZER"; then
  die destructive_pattern
fi
if grep -nE 'sshpass|PASS(word)?=|TurboAi@|I_ACK_[^$<[:space:]]+[0-9]{8}' "$DRIVER" "$PORTAL" "$ANALYZER"; then
  die plaintext_secret_or_live_ack
fi
grep -nE 'sudo |systemctl (stop|start)|gc --compact --delete|ceph osd (set|unset)|find .* -delete|fio ' "$DRIVER" "$PORTAL" "$LEGACY" "$SCRUB" >"$OUT/write-operation-scan.txt" || true
grep -Fq 'I_ACK_06_5_PHASE_$RUN_ID' "$DRIVER" || die phase_ack_guard
grep -Fq 'I_ACK_06_5_PORTAL_PAUSED_$RUN_ID' "$DRIVER" || die maintenance_ack_guard
grep -Fq 'unexpected_shared_sessions' "$DRIVER" || die shared_session_guard
grep -Fq 'main_mount_in_use' "$DRIVER" || die main_mount_guard
grep -Fq 'systemctl stop "$TIMER_UNIT"' "$PORTAL" || die portal_timer_stop
grep -Fq 'systemctl stop "$MOUNT_UNIT"' "$PORTAL" || die portal_mount_stop
grep -Fq 'systemctl start "$MOUNT_UNIT"' "$PORTAL" || die portal_mount_restore
python3 - "$DRIVER" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
phase=s[s.index('phase_065() {'):s.index('\ncase $MODE in\n')]
pause=phase.index('bash "$SCRUB" pause')
canary=phase.index('recovery_gate canary')
if not pause < canary: raise SystemExit('scrub_pause_must_precede_recovery_canary')
PY

"$DRIVER" --self-test "$RUN_ID" >"$OUT/driver-self-test.txt"
grep -Fq 'T065_DRIVER_SELF_TEST_PASS' "$OUT/driver-self-test.txt" || die driver_self_test
set +e
"$DRIVER" phase "$RUN_ID" >"$OUT/missing-ack.stdout" 2>"$OUT/missing-ack.stderr"
missing_ack_rc=$?
set -e
[[ $missing_ack_rc -eq 42 ]] || die online_branch_not_inert_without_ack
grep -Fq 'execute_ack_missing' "$OUT/missing-ack.stderr" || die missing_ack_reason
T065_PLAN_OUT="$OUT/plan" "$DRIVER" plan "$RUN_ID" >"$OUT/plan.stdout"
grep -Fq 'T065_PLAN_ONLY_PASS' "$OUT/plan.stdout" || die plan_generation
[[ $(awk -F '\t' 'NR>1{n++}END{print n+0}' "$OUT/plan/matrix.tsv") -eq 6 ]] || die matrix_count
[[ $(awk -F '\t' 'NR>1{print $2}' "$OUT/plan/matrix.tsv" | paste -sd, -) == C1,R1,W1,W2,R2,C2 ]] || die matrix_order
[[ $(awk -F '\t' 'NR>1{n++}END{print n+0}' "$OUT/plan/recovery-contract.tsv") -eq 7 ]] || die recovery_count
[[ $(awk -F '\t' 'NR>1{print $2}' "$OUT/plan/recovery-contract.tsv" | paste -sd, -) == canary,C1-post,R1-post,W1-post,W2-post,R2-post,C2-post ]] || die recovery_order
grep -Fq $'C1-post\tbetween-C1-R1\t1\tSTOP_NO_NEXT_CELL' "$OUT/plan/recovery-contract.tsv" || die interval_contract
grep -Fq $'C2-post\tafter-C2\t1\tSTOP_CLOSEOUT' "$OUT/plan/recovery-contract.tsv" || die closeout_contract
grep -Fq $'writeback-drain\tREAD_AND_STATE_GATE' "$OUT/plan/maintenance-contract.tsv" || die drain_contract
grep -Fq $'automatic-GC-retry\tFORBIDDEN' "$OUT/plan/safety-contract.tsv" || die gc_retry_guard
grep -Fq $'runtime\t180' "$OUT/plan/workload-contract.tsv" || die fio_runtime_contract

python3 "$ANALYZER" self-test >"$OUT/analyzer-self-test.json"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || die analyzer_self_test
grep -Fq 'actual_runtime_endpoint' "$OUT/analyzer-self-test.json" || die endpoint_fixture
grep -Fq 'R/C_W/R_W/C_effects' "$OUT/analyzer-self-test.json" || die effect_fixture
grep -Fq 'noise_gate' "$OUT/analyzer-self-test.json" || die noise_fixture
bash "$SCRUB" --self-test >"$OUT/scrub-self-test.txt"
grep -Fq 'U141D_SCRUB_CONTROL_SELFTEST: PASS' "$OUT/scrub-self-test.txt" || die scrub_self_test

# Task-book contract checks: textual assertions only; no task or environment
# file is modified by this Gate.
grep -Fq 'C1 → R1 → W1 → W2 → R2 → C2' "$TASK" || die task_matrix_contract
grep -Fq '初始canary一次、六格间/后恢复最多六次' "$TASK" || die task_gc_contract
grep -Fq 'R1/C1 - 1' "$TASK" || die task_rc_formula
grep -Fq 'W1/R1 - 1' "$TASK" || die task_wr_formula
grep -Fq 'W1/C1 - 1' "$TASK" || die task_wc_formula

find "$OUT/pycache" -depth -mindepth 1 -delete 2>/dev/null || true
rmdir "$OUT/pycache" 2>/dev/null || true
sha256sum "$DRIVER" "$ANALYZER" "$PORTAL" "$LEGACY" "$LEGACY_ANALYZER" "$SCRUB" "$GATE" "$TASK" >"$OUT/scripts.sha256"
cat >"$OUT/gate-result.json" <<EOF
{"status":"PASS","scope":"L0_OFFLINE","run_id":"$RUN_ID","remote_calls":0,"formal_load":"NOT_AUTHORIZED","recovery_max":7}
EOF
(
  cd "$OUT"
  sha256sum -c scripts.sha256 >/dev/null
  find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
  sha256sum -c manifest.sha256 >/dev/null
)
printf 'T065_GATE0_OFFLINE_PASS\troot=%s\tremote_calls=0\tformal_load=NOT_AUTHORIZED\trecovery_max=7\n' "$OUT"
