#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DRIVER=$DIR/t05-2-randrw-driver.sh
ANALYZER=$DIR/t05-2-randrw-analyze.py
BASE_DRIVER=$DIR/t05-1-randrw-driver.sh
BASE_ANALYZER=$DIR/t05-1-randrw-analyze.py
HIST_ARCHIVE=/mnt/c/SunRise/test/05-1/20260914-141125/05-1-20260914-141125-phase-b-final.tar.gz
OUT=/tmp/t05-2-gate0-$(date +%s%N)
die() { printf 'T052_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
for f in $DRIVER $ANALYZER $BASE_DRIVER $BASE_ANALYZER; do [[ -s $f && ! -L $f ]] || die missing_input_$f; done
[[ ! -e $OUT && $OUT != / && ! -L $OUT ]] || die unsafe_output
mkdir -m 0700 $OUT
# Gate 0 must remain offline: source scans only, no SSH, mount, fio, JuiceFS or Ceph calls.
if grep -nE '(^|[;&|][[:space:]]*)(ssh|scp|rsync|sudo|reboot|shutdown|systemctl|pkill|killall|drop_caches)([[:space:]]|$)' $DRIVER; then die forbidden_operation; fi
if grep -nE 'rm[[:space:]]+-rf|wipefs|ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)' $DRIVER; then die destructive_operation; fi
bash -n $DRIVER; bash -u -n $DRIVER; bash -n $0
grep -Fq 'find -P "$path/test_dir"' $DRIVER || die find_syntax_guard
grep -Fq 'find "$ROOT" -type f ! -path "$ROOT/bundle/*"' $DRIVER || die bundle_glob_guard
! grep -nE 'local [^;]*=[^;]*\$[A-Za-z_][A-Za-z0-9_]*' $DRIVER || die dependent_local_initializer
find -P $OUT -maxdepth 0 -type d >/dev/null || die find_fixture
grep -Fq 'require_online_ack' $DRIVER || die online_ack_guard
grep -Fq 'T052_EXECUTE_ACK' $DRIVER || die execute_ack_guard
grep -Fq 'T052_CLEAN_STATE_ACK' $DRIVER || die cleanup_ack_guard
grep -Fq 'verify_assets' $DRIVER || die asset_guard
grep -Fq 'mount_identity' $DRIVER || die mount_identity_guard
grep -Fq 'mount_cell $cell $uploads $fuse $buffer' $DRIVER || die phase_mount_call_guard
grep -Fq 'need=("--max-uploads "' $DRIVER || die cmdline_guard
grep -Fq 'sampler_start' $DRIVER || die mechanism_sampler_guard
grep -Fq 'recovery_gate' $DRIVER || die recovery_guard
grep -Fq 'recovery_gate A-initial' $DRIVER || die initial_recovery_guard
grep -Fq 'recovery_gate B1-initial' $DRIVER || die b1_initial_recovery_guard
grep -Fq 'recovery_gate $cell-post' $DRIVER || die post_recovery_guard
grep -Fq 'objects $stored' $DRIVER || die recovery_objects_guard
grep -Fq 'stable >= 3' $DRIVER || die recovery_consecutive_guard
grep -Fq 'timeout 240 $FIO' $DRIVER || die fio_timeout_guard
grep -Fq 'sampler_rc==0' $DRIVER || die sampler_exit_guard
grep -Fq 'verify_assets $path' $DRIVER || die private_asset_guard
grep -Fq 'put_ops_s' $ANALYZER || die put_count_guard
grep -Fq 'put_avg_latency_ms' $ANALYZER || die put_sum_guard
grep -Fq 'formal_1hz' $ANALYZER || die formal_window_guard
grep -Fq 'date +%s%N' $DRIVER || die sampler_epoch_guard
grep -Fq 'fio-start-epoch-ns' $DRIVER || die raw_evidence_guard
grep -Fq 'per_job_logs=0' $DRIVER || die fio_contract_guard
grep -Fq 'allow_file_create=0' $DRIVER || die fio_asset_guard
grep -Fq 'PHASE_A_PASS' $DRIVER || die phase_a_marker
grep -Fq 'PHASE_B1_PASS' $DRIVER || die b1_marker
grep -Fq 'T052_B2_GATE_ACK' $DRIVER || die b2_ack_guard
grep -Fq 'uploading_p95' $DRIVER || die b2_metric_gate_guard
! grep -Eq '^phase_c\(\)|phase-c\)' $DRIVER || die phase_c_implemented
# The base driver/analyzer are inputs for reuse; this task adds no analyzer.
grep -Fq 't05-1-randrw-analyze.py' $0 || die analyzer_reuse_not_declared
python3 -m py_compile $ANALYZER; python3 $ANALYZER self-test >$OUT/analyzer-self-test.json
grep -Fq '"status": "PASS"' $OUT/analyzer-self-test.json || die analyzer_fixture
T052_EXECUTE_ACK=wrong T052_CLEAN_STATE_ACK=wrong $DRIVER phase-a 20260915-120000 >/dev/null 2>&1 && die ack_fixture
set +e; T052_EXECUTE_ACK=wrong T052_CLEAN_STATE_ACK=wrong $DRIVER phase-b1 20260915-120000 >/dev/null 2>&1; rc=$?; set -e; [[ $rc == 42 ]] || die b1_ack_fixture
set +e; T052_EXECUTE_ACK=wrong T052_CLEAN_STATE_ACK=wrong T052_B2_GATE_ACK=wrong $DRIVER phase-b2 20260915-120000 >/dev/null 2>&1; rc=$?; set -e; [[ $rc == 42 ]] || die b2_ack_fixture
$DRIVER --self-test 20260915-120000 >$OUT/driver-self-test.txt
grep -Fq T052_DRIVER_SELF_TEST_PASS $OUT/driver-self-test.txt || die driver_fixture
grep -Fq $'MOUNT_FIXTURE\tC1\t150\t1M\t300' $OUT/driver-self-test.txt || die mount_fixture_c1
grep -Fq $'MOUNT_FIXTURE\tT1\t300\t1M\t300' $OUT/driver-self-test.txt || die mount_fixture_t1
grep -Fq $'MOUNT_FIXTURE\tT2\t300\t1M\t300' $OUT/driver-self-test.txt || die mount_fixture_t2
grep -Fq $'MOUNT_FIXTURE\tC2\t150\t1M\t300' $OUT/driver-self-test.txt || die mount_fixture_c2
T052_PLAN_OUT=$OUT/plan $DRIVER plan 20260915-120000 >$OUT/plan.stdout
grep -Fq T052_PLAN_ONLY_PASS $OUT/plan.stdout || die plan_fixture
[[ $(awk -F '\t' 'NR>1{n++}END{print n+0}' $OUT/plan/phase-a-matrix.tsv) -eq 4 ]] || die phase_a_rows
[[ $(awk -F '\t' 'NR>1{n++}END{print n+0}' $OUT/plan/phase-b1-matrix.tsv) -eq 1 ]] || die b1_rows
[[ $(awk -F '\t' 'NR>1{n++}END{print n+0}' $OUT/plan/phase-b2-matrix.tsv) -eq 4 ]] || die b2_rows
[[ $(awk -F '\t' 'NR>1&&$3=="REQUIRES_G0_APPROVAL"{n++}END{print n+0}' $OUT/plan/scrub-plan.tsv) -eq 2 ]] || die scrub_plan
[[ $(awk -F '\t' 'NR>1&&$2=="DISABLED_PENDING_SEPARATE_APPROVAL"&&$3=="one per OSD (6 total)"{n++}END{print n+0}' $OUT/plan/compact-plan.tsv) -eq 2 ]] || die compact_plan
grep -Fq $'juicefs-gc\texisting juicefs-prod volume' $OUT/plan/write-operations.tsv || die write_plan
[[ $(awk -F '\t' 'NR>1&&$5==150&&$6=="1M"&&$7==300{n++}END{print n+0}' $OUT/plan/phase-a-matrix.tsv) -eq 2 ]] || die phase_a_controls
[[ $(awk -F '\t' 'NR>1&&$5==300&&$6=="1M"&&$7==300{n++}END{print n+0}' $OUT/plan/phase-a-matrix.tsv) -eq 2 ]] || die phase_a_treatments
grep -Fq $'1\tC1\t1M\tC\t150\t1M\t300\tEFFECT' $OUT/plan/phase-a-matrix.tsv || die c1
grep -Fq $'2\tT1\t1M\tT\t300\t1M\t300\tEFFECT' $OUT/plan/phase-a-matrix.tsv || die t1
grep -Fq $'3\tT2\t1M\tT\t300\t1M\t300\tEFFECT' $OUT/plan/phase-a-matrix.tsv || die t2
grep -Fq $'4\tC2\t1M\tC\t150\t1M\t300\tEFFECT' $OUT/plan/phase-a-matrix.tsv || die c2
grep -Fq $'1\tB1\t256K\tC\t150\t256K\t300\tEXCLUDED' $OUT/plan/phase-b1-matrix.tsv || die b1_contract
awk -F '\t' 'NR>1&&$5==150{c++} NR>1&&$5==300{t++} END{exit !(c==2&&t==2)}' $OUT/plan/phase-b2-matrix.tsv || die b2_contract
[[ -s $HIST_ARCHIVE && ! -L $HIST_ARCHIVE ]] || die historical_fixture_missing
mkdir -m 0700 $OUT/history; tar -xzf $HIST_ARCHIVE -C $OUT/history
HIST_ROOT=$(find $OUT/history -mindepth 1 -maxdepth 1 -type d -print -quit)
python3 $ANALYZER analyze --root $HIST_ROOT --output $OUT/historical-analysis.json
grep -Fq '"evidence_mode": "historical_endpoint_replay"' $OUT/historical-analysis.json || die historical_replay_mode_missing
grep -Fq '"put_bytes_rate_MiB_s"' $OUT/historical-analysis.json || die historical_put_bytes_missing
printf 'check\tstatus\nsyntax\tPASS\nsafety_scan\tPASS\nmatrix\tPASS\nfixtures\tPASS\nreuse\tPASS\n' >$OUT/gate.tsv
sha256sum $DRIVER $ANALYZER $0 $BASE_DRIVER $BASE_ANALYZER >$OUT/input-sha256.tsv
printf 'T052_GATE0_OFFLINE_PASS\troot=%s\tremote_calls=0\tphase_b2=gated\tphase_c=absent\n' $OUT
