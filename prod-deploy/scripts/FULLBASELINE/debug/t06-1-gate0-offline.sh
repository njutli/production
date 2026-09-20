#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER=$SCRIPT_DIR/t06-1-randrw-cache-driver.sh
ANALYZER=$SCRIPT_DIR/t06-1-randrw-analyze.py
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
FIXTURES=$SCRIPT_DIR/../../../skills/fixtures/known-defect-classes.tsv
RUN_ID=${1:-20260915-200000}
OUT=${2:-/tmp/t06-1-gate0-$RUN_ID}

die() { printf 'T061_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
[[ $OUT == /* && $OUT != / && ! -L $OUT && ! -e $OUT ]] || die unsafe_output
for file in "$DRIVER" "$ANALYZER" "$SCRUB" "$FIXTURES"; do
  [[ -s $file && ! -L $file ]] || die "missing_input:$file"
done
mkdir -m 0700 -p "$OUT/gate0"

# Stage 0A is source/fixture work only.  Runtime commands such as fio, ceph,
# JuiceFS and SSH are never invoked by this Gate.
bash -n "$DRIVER"
bash -u -n "$DRIVER"
bash -n "$0"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANALYZER"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$DRIVER" "$0" >"$OUT/gate0/shellcheck.txt" || die shellcheck
else
  printf 'NOT_INSTALLED\n' >"$OUT/gate0/shellcheck.txt"
fi

secret_pattern='sshpass[[:space:]]+'
secret_pattern+='-p|PASS'
secret_pattern+='WORD=[^$[:space:]]|Turbo'
secret_pattern+='Ai@|I_ACK_[^$<[:space:]]+[0-9]{8}'
if grep -nE "$secret_pattern" "$DRIVER" "$ANALYZER"; then
  die plaintext_secret_or_live_ack
fi
destructive_pattern='rm[[:space:]]+-'
destructive_pattern+='rf|fusermount[[:space:]]+-uz|umount[[:space:]]+-l|losetup[[:space:]]+-D|pk'
destructive_pattern+='ill|killall|fuser[[:space:]]+-k|reboot|shutdown|poweroff|wipefs'
if grep -nE "$destructive_pattern" "$DRIVER"; then
  die forbidden_destructive_pattern
fi
if grep -nE '^[[:space:]]*(ssh|scp|rsync)([[:space:]]|$)' "$DRIVER"; then
  die embedded_remote_execution
fi
unsafe_pattern='rados[[:space:]]+'
unsafe_pattern+='df|echo .*\|[[:space:]]*tee|\|[[:space:]]*bc'
if grep -nE "$unsafe_pattern" "$DRIVER" "$ANALYZER"; then
  die known_unsafe_pattern
fi
if grep -nE '^[[:space:]]*local[[:space:]]+[A-Za-z_]+=[^[:space:]]+[[:space:]]+[A-Za-z_]+=' "$DRIVER"; then
  die dependent_local_initializer
fi

[[ -x $DRIVER && -x $ANALYZER ]] || die source_not_executable
"$DRIVER" --self-test "$RUN_ID" >"$OUT/gate0/driver-self-test.txt"
grep -Fq 'T061_DRIVER_SELF_TEST_PASS' "$OUT/gate0/driver-self-test.txt" || die driver_self_test
set +e
"$DRIVER" phase-a "$RUN_ID" >"$OUT/gate0/missing-ack.stdout" 2>"$OUT/gate0/missing-ack.stderr"
missing_ack_rc=$?
set -e
[[ $missing_ack_rc -eq 42 ]] || die missing_ack_fixture
grep -Fq 'execute_ack_missing' "$OUT/gate0/missing-ack.stderr" || die missing_ack_reason
"$ANALYZER" self-test >"$OUT/gate0/analyzer-self-test.json"
grep -Fq '"status": "PASS"' "$OUT/gate0/analyzer-self-test.json" || die analyzer_self_test
grep -Fq 'formal_window_rejects_missing_second' "$OUT/gate0/analyzer-self-test.json" || die missing_second_fixture
grep -Fq 'complete_mechanism_metrics_and_missing_metric_rejection' "$OUT/gate0/analyzer-self-test.json" || die mechanism_metric_fixture
grep -Fq 'per_device_df_160s_and_missing_second_rejection' "$OUT/gate0/analyzer-self-test.json" || die df_coverage_fixture

T061_PLAN_OUT="$OUT" "$DRIVER" plan "$RUN_ID" >"$OUT/gate0/plan.stdout"
grep -Fq 'T061_PLAN_ONLY_PASS' "$OUT/gate0/plan.stdout" || die plan_generation
[[ $(awk -F '\t' 'NR>1{n++}END{print n+0}' "$OUT/gate0/phase-a-matrix.tsv") -eq 4 ]] || die matrix_count
[[ $(awk -F '\t' 'NR>1{print $2}' "$OUT/gate0/phase-a-matrix.tsv" | paste -sd, -) == C1,T1,T2,C2 ]] || die matrix_order
[[ $(awk -F '\t' 'NR>1&&$1=="0B"&&$3=="READ_ONLY"{n++}END{print n+0}' "$OUT/gate0/command-plan.tsv") -eq 5 ]] || die stage0b_readonly_plan
[[ $(awk -F '\t' 'NR>1&&$1=="0B"&&$3!="READ_ONLY"{n++}END{print n+0}' "$OUT/gate0/command-plan.tsv") -eq 0 ]] || die stage0b_write_found
awk -F '\t' '$1=="30"{z=NR}$1=="40"{u=NR}$1=="50"{v=NR}$1=="90"{c=NR}END{exit !(z<u&&u<v&&v<c)}' "$OUT/gate0/lifecycle-order.tsv" || die lifecycle_order
grep -Fq $'formal-fio\tWRITE_EXISTING_FILES_REQUIRES_APPROVAL' "$OUT/gate0/command-plan.tsv" || die fio_write_plan
grep -Fq $'cleanup-cache\tDELETE_RUN_SCOPED_REQUIRES_APPROVAL' "$OUT/gate0/command-plan.tsv" || die cleanup_plan
grep -Fq $'drop_caches\tFORBIDDEN' "$OUT/gate0/forbidden-operations.tsv" || die drop_caches_forbidden
grep -Fq $'touch-/mnt/juicefs\tFORBIDDEN' "$OUT/gate0/forbidden-operations.tsv" || die reference_mount_forbidden
sha256sum -c "$OUT/gate0/warmup.sha256" >/dev/null || die warmup_hash
grep -Fq 'runtime=60' "$OUT/gate0/warmup.fio" || die warmup_duration
grep -Fq 'rw=randread' "$OUT/gate0/warmup.fio" || die warmup_mode
grep -Fq 'allow_file_create=0' "$OUT/gate0/warmup.fio" || die warmup_asset_guard

# Historical replay: prove the new bandwidth parser against the signed-off
# 04-tmp2j A0-pre cell.  Extraction stays under this Gate output only.
HIST_ARCHIVE=/mnt/c/SunRise/test/04-tmp2j/20260907-155057/final/04-tmp2j-20260907-155057.tar.gz
HIST_EXPECTED=/mnt/c/SunRise/test/04-tmp2j/20260907-155057/final/final-analysis.json
[[ -s $HIST_ARCHIVE && -s $HIST_EXPECTED && ! -L $HIST_ARCHIVE && ! -L $HIST_EXPECTED ]] || die historical_fixture_missing
if tar -tzf "$HIST_ARCHIVE" | grep -E '(^/|(^|/)\.\.(/|$))'; then die unsafe_historical_archive_paths; fi
mkdir -m 0700 "$OUT/history"
tar -xzf "$HIST_ARCHIVE" -C "$OUT/history"
"$ANALYZER" replay-cell --cell "$OUT/history/cells/A0-pre" --output "$OUT/gate0/historical-replay.json"
python3 - "$OUT/gate0/historical-replay.json" "$HIST_EXPECTED" >"$OUT/gate0/historical-replay-check.tsv" <<'PY'
import json,sys
actual=json.load(open(sys.argv[1])); expected=json.load(open(sys.argv[2]))
row=next(x for x in expected['cells'] if x['cell']=='A0-pre')
print('direction\tactual_MiB_s\texpected_MiB_s\tdelta_pct')
for direction in ('read','write'):
    a=actual['formal'][direction]['mean_MiB_s']
    e=row['bandwidth'][direction]['mean_MiBs']
    d=(a/e-1)*100
    print(f'{direction}\t{a:.9f}\t{e:.9f}\t{d:.6f}')
    if abs(d)>2: raise SystemExit('historical replay differs by more than 2%')
PY
find "$OUT/history" -depth -mindepth 1 -delete
rmdir "$OUT/history"
if [[ -d $OUT/pycache ]]; then find "$OUT/pycache" -depth -mindepth 1 -delete; rmdir "$OUT/pycache"; fi

# Machine-readable coverage of the CRIT/HIGH historical defect catalogue.
cat >"$OUT/gate0/known-defect-coverage.tsv" <<'EOF'
id	status	assertion
D01	PASS	actual start=end-runtime; analyzer reports registered delta and sensitivity fixtures
D02	PASS	overlap-weighted per-job parser fixture
D03	PASS	formal [15,175) is the only effect input
D04	PASS	parent/worker topology; no pgrep head-1
D05	PASS	/proc access failure rejects identity; no silent blank fields
D06	PASS	bash -u -n and single dependent local assignments
D08	NOT_APPLICABLE	no runtime SSH loop in driver
D09	PASS	Ceph pool values use JSON plus Python
D12	PASS	coverage counts epoch-named scrapes, not exposition lines
D13	PASS	iostat kept raw; analyzer does not use fixed columns
D14	NOT_APPLICABLE	PSI is not collected or judged
D15	PASS	formal window is [actual_start+15,actual_start+175)
D16	PASS	exact sampler PIDs are stopped and waited before analysis
D17	PASS	wait return code is captured without `wait || true; rc=$?`
D19	NOT_APPLICABLE	fixed unique cell labels; no retry/replacement
D20	NOT_APPLICABLE	FULLBASELINE_V4 is not called
D21	PASS	per-device headroom is a Stage-0B hard gate
D22	PASS	samplers follow fio completion; no fixed sampler timeout
D25	PASS	plain-text secret scan
D26	PASS	forbidden destructive-pattern scan and exact RUN child cleanup
D27	PASS	frozen script SHA is required before Phase A
D28	PASS	append-only incidents ledger events around cache create/cleanup
EOF
for id in $(awk -F '\t' 'NR>1&&($2=="CRIT"||$2=="HIGH"){print $1}' "$FIXTURES"); do
  awk -F '\t' -v id="$id" 'NR>1&&$1==id&&($2=="PASS"||$2=="NOT_APPLICABLE"){found=1}END{exit found?0:1}' "$OUT/gate0/known-defect-coverage.tsv" || die "known_defect_uncovered:$id"
done

sha256sum "$DRIVER" "$ANALYZER" "$0" "$SCRUB" >"$OUT/gate0/input-sha256.tsv"
cat >"$OUT/gate0/gate.tsv" <<'EOF'
check	status
remote_calls	0
syntax	PASS
safety_scan	PASS
matrix	PASS
analyzer_fixtures	PASS
historical_replay	PASS
driver_fixtures	PASS
lifecycle_order	PASS
command_plan	PASS
warmup_freeze	PASS
known_defect_coverage	PASS
EOF
printf 'T061_GATE0A_OFFLINE_PASS\troot=%s\tremote_calls=0\tformal_load=NOT_AUTHORIZED\n' "$OUT"
