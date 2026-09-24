#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER=$SCRIPT_DIR/t06-2c-eager-freeze-driver.sh
WRAPPER=$SCRIPT_DIR/t06-2c-run-wrapper.sh
ANALYZER=$SCRIPT_DIR/t06-2c-randrw-analyze.py
SOURCE_GATE=$SCRIPT_DIR/t06-2c-gate0-offline.sh
PARENT=$SCRIPT_DIR/t06-5-randrw-cache-driver.sh
LEGACY=$SCRIPT_DIR/t06-1-randrw-cache-driver.sh
LEGACY_ANALYZER=$SCRIPT_DIR/t06-1-randrw-analyze.py
PORTAL=$SCRIPT_DIR/t06-5-portal-maintenance.sh
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
TASK=$SCRIPT_DIR/../../../doc/perf-tasks/06-2c-randrw-write-path-source-optimization-screen.md
RUN_ID=${1:-}
OUT=${2:-/tmp/t06-2c-environment-gate0-$RUN_ID}

die() { printf 'T062C_ENV_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
[[ $OUT == /* && $OUT != / && ! -e $OUT && ! -L $OUT ]] || die unsafe_or_existing_output
for f in "$DRIVER" "$WRAPPER" "$ANALYZER" "$SOURCE_GATE" "$PARENT" "$LEGACY" "$LEGACY_ANALYZER" "$PORTAL" "$SCRUB" "$TASK"; do
  [[ -s $f && ! -L $f ]] || die missing_input_$f
done
mkdir -m 0700 -p "$OUT"

bash -n "$DRIVER"; bash -u -n "$DRIVER"; bash -n "$WRAPPER"; bash -n "$PORTAL"; bash -n "$0"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANALYZER"
python3 - "$DRIVER" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
for n,line in enumerate(s.splitlines(),1):
    stripped=line.strip()
    if not stripped.startswith('local '): continue
    for name in re.findall(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=',stripped[6:]):
        if re.search(r'\$\{?'+re.escape(name)+r'(?:\}|[^A-Za-z0-9_])',stripped):
            raise SystemExit(f'unsafe same-local dependency line {n}: {name}')
PY

if grep -nE 'rm[[:space:]]+-rf|fusermount[[:space:]]+-uz|umount[[:space:]]+-l|losetup[[:space:]]+-D|(^|[[:space:];])killall([[:space:];]|$)|(^|[[:space:];])(reboot|shutdown|poweroff)([[:space:];]|$)' \
  "$DRIVER" "$WRAPPER" "$PARENT" "$LEGACY" "$PORTAL" "$SCRUB" "$ANALYZER"; then die destructive_pattern; fi
if grep -nE 'sshpass|PASS(word)?=|TurboAi@|I_ACK_[^$<[:space:]]+[0-9]{8}' "$DRIVER" "$ANALYZER"; then die secret_or_live_ack; fi
grep -nE 'sudo |systemctl (stop|start)|gc --compact --delete|ceph osd (set|unset)|find .* -delete|fio |rm --' \
  "$DRIVER" "$WRAPPER" "$PARENT" "$LEGACY" "$PORTAL" "$SCRUB" >"$OUT/write-operation-scan.txt" || true

"$DRIVER" --self-test "$RUN_ID" >"$OUT/driver-self-test.txt"
grep -Fq 'T062C_DRIVER_SELF_TEST_PASS' "$OUT/driver-self-test.txt" || die driver_self_test
python3 "$ANALYZER" --self-test >"$OUT/analyzer-self-test.txt"
grep -Fq 'T062C_ANALYZE_SELF_TEST_PASS' "$OUT/analyzer-self-test.txt" || die analyzer_self_test
bash "$SCRUB" --self-test >"$OUT/scrub-self-test.txt"
grep -Fq 'U141D_SCRUB_CONTROL_SELFTEST: PASS' "$OUT/scrub-self-test.txt" || die scrub_self_test

set +e
"$DRIVER" preflight-online "$RUN_ID" >"$OUT/missing-ack.stdout" 2>"$OUT/missing-ack.stderr"
rc=$?
set -e
[[ $rc -eq 42 ]] || die online_branch_not_inert
grep -Fq 'execute_ack_missing' "$OUT/missing-ack.stderr" || die wrong_missing_ack_reason

T062C_PLAN_OUT="$OUT/plan" "$DRIVER" plan "$RUN_ID" >"$OUT/plan.stdout"
grep -Fq 'T062C_PLAN_PASS' "$OUT/plan.stdout" || die plan_generation
[[ $(awk -F '\t' 'NR>1{print $2}' "$OUT/plan/matrix.tsv" | paste -sd, -) == C1,T1,T2,C2 ]] || die matrix_order
[[ $(awk -F '\t' 'NR>1&&$4==98304&&$5==1{n++}END{print n+0}' "$OUT/plan/matrix.tsv") -eq 4 ]] || die matrix_configuration
[[ $(awk -F '\t' 'NR>1{print $2}' "$OUT/plan/recovery.tsv" | paste -sd, -) == canary,C1-post,T1-post,T2-post,C2-post ]] || die recovery_contract
grep -Fq $'gc-compact\tUUID e1b69ea9-0e3d-427d-bea9-8765928afa66\t5' "$OUT/plan/write-operations.tsv" || die gc_limit
grep -Fq $'semantic-smoke\ttwo exact RUN files and private mounts\tC+T once' "$OUT/plan/write-operations.tsv" || die smoke_plan
grep -Fq $'resource-gate\tMemAvailable and cache filesystem available\tminimum 384 GiB each' "$OUT/plan/write-operations.tsv" || die resource_plan

python3 - "$DRIVER" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
mount=s[s.index('mount_private() {'):s.index('\ngraceful_umount() {')]
if mount.count('--experimental-eager-freeze')!=1: raise SystemExit('candidate flag count')
if 'T) ' not in mount or 'C) ' not in mount: raise SystemExit('C/T mount arms')
smoke=s[s.index('semantic_smoke_arm() {'):s.index('\nsemantic_smoke() {')]
for x in ('.t06-2c-$RUN_ID-$arm-semantic.bin','os.ftruncate(fd,len(data))','unstable_eof','short_overwrite','same_handle_read_mismatch','independent_readback_mismatch'):
    if x not in smoke: raise SystemExit('smoke contract:'+x)
if 'rw_test.' in smoke: raise SystemExit('smoke touches benchmark file names')
run=s[s.index('run_cell() {'):s.index('\nwrite_plan() {')]
if not run.index('drain_writeback') < run.index('graceful_umount'): raise SystemExit('unmount before drain')
if 'return $?' not in run[:run.index('graceful_umount')]: raise SystemExit('drain failure does not preserve mount')
if 'resource_gate_062c' not in run: raise SystemExit('per-cell resource gate missing')
for x in ('quiet-before-warmup','warmup-end','formal-start'):
    if x not in run: raise SystemExit('missing state snapshot:'+x)
if 'T061_CEPH_FSID=$T065_CEPH_FSID' not in s: raise SystemExit('missing inherited FSID bridge')
if 'warmup-command-start-ns.txt' not in run or 'warmup-command-end-ns.txt' not in run: raise SystemExit('warmup timing missing')
snapshot=s[s.index('capture_state_snapshot() {'):s.index('\nresource_gate_062c() {')]
for x in ('collect_start_ns','collect_end_ns'):
    if x not in snapshot: raise SystemExit('snapshot interval missing:'+x)
pidgate=s[s.index('mount_pid_gate() {'):s.index('\nresource_gate_062c() {')]
for x in ('launch_log_pid_mismatch','launch_log_watchdog_mismatch','len(rows)!=2','len(workers)!=1'):
    if x not in pidgate: raise SystemExit('pid gate contract missing:'+x)
if 'launch_log not in cmd' in pidgate: raise SystemExit('pid gate still depends on untruncated argv')
PY

grep -Fq '10.20.1.152 sudo "$PORTAL" pause "$RUN_ID"' "$WRAPPER" || die portal_pause_missing
grep -Fq '10.20.1.152 sudo "$PORTAL" restore "$RUN_ID"' "$WRAPPER" || die portal_restore_missing
grep -Fq 'trap finish EXIT INT TERM' "$WRAPPER" || die portal_restore_trap_missing
grep -Fq '"$DRIVER" preflight-online "$RUN_ID"' "$WRAPPER" || die preflight_before_pause_missing
grep -Fq 'StrictHostKeyChecking=yes' "$WRAPPER" || die strict_host_key_missing
! grep -Eq 'StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null' "$WRAPPER" || die insecure_host_key_policy
grep -Fq 'UserKnownHostsFile=/home/sunrise/.ssh/known_hosts' "$WRAPPER" || die pinned_known_hosts_missing
grep -Fq 'UserKnownHostsFile=/home/sunrise/.ssh/known_hosts' "$DRIVER" || die driver_pinned_known_hosts_missing
grep -Fq 'T062C_WRAPPER_SHA256' "$WRAPPER" || die wrapper_identity_missing
grep -Fq 'remote_portal_identity' "$WRAPPER" || die remote_portal_identity_missing
grep -Fq 'portal_paused_gate' "$DRIVER" || die runtime_portal_gate_missing
grep -Fq 'juicefs-namespace-collector.service' "$DRIVER" || die runtime_portal_collector_gate_missing
grep -Fq 'T062C_WRAPPER_ACTIVE' "$DRIVER" || die direct_phase_not_rejected
grep -Fq 'T062C_WRAPPER_ACTIVE=I_ACK_06_2C_WRAPPER_$RUN_ID "$DRIVER" phase "$RUN_ID"' "$WRAPPER" || die wrapper_phase_token_missing
grep -Fq 'PORTAL_RESTORE_PASS' "$WRAPPER" || die portal_restore_marker_missing
grep -Fq 'WRAPPER_PASS' "$WRAPPER" || die wrapper_pass_marker_missing
grep -Fq 'wrapper.rc' "$WRAPPER" || die wrapper_rc_missing
grep -Fq 'portal_state_not_restored' "$PORTAL" || die portal_restore_verification_missing
grep -Fq 'collector_state_not_restored' "$PORTAL" || die collector_restore_verification_missing
python3 - "$PORTAL" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
restore=s[s.index('restore() {'):s.index('\ncase $MODE in')]
needle='[[ $(unit_state "$COLLECTOR_UNIT") == "$(awk -F \'\\t\' \'$1=="collector"{print $2}\' "$STATE")" ]] || die collector_state_not_restored'
if needle not in restore: raise SystemExit('collector active/inactive exact restore assertion missing')
if not restore.index('systemctl start "$COLLECTOR_UNIT"') < restore.index('collector_state_not_restored'):
    raise SystemExit('collector verified before restore attempt')
PY

grep -Fq 'C1 → T1 → T2 → C2' "$TASK" || die task_matrix
grep -Fq '性能批最多5次' "$TASK" || die task_recovery_limit
grep -Fq 'M = max(5%, 2*epsilon)' "$TASK" || die task_materiality

find "$OUT/pycache" -depth -mindepth 1 -delete 2>/dev/null || true
rmdir "$OUT/pycache" 2>/dev/null || true
sha256sum "$DRIVER" "$WRAPPER" "$ANALYZER" "$SOURCE_GATE" "$PARENT" "$LEGACY" "$LEGACY_ANALYZER" "$PORTAL" "$SCRUB" "$TASK" >"$OUT/scripts.sha256"
cat >"$OUT/gate-result.json" <<EOF
{"status":"PASS","scope":"L0_ENVIRONMENT_ORCHESTRATION_OFFLINE","run_id":"$RUN_ID","remote_calls":0,"formal_load":"NOT_AUTHORIZED","matrix":"C1,T1,T2,C2","recovery_max":5}
EOF
(
  cd "$OUT"
  find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
  sha256sum -c manifest.sha256 >/dev/null
)
printf 'T062C_ENV_GATE0_PASS\troot=%s\tremote_calls=0\tformal_load=NOT_AUTHORIZED\trecovery_max=5\n' "$OUT"
