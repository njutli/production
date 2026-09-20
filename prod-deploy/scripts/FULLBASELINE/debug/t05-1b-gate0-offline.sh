#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# Pure offline Gate 0.  It may inspect local source and an already persisted
# archive, but it must never execute SSH, mount, fio, Ceph, JuiceFS, GC or a
# destructive cleanup operation.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER="$SCRIPT_DIR/t05-1b-randrw-driver.sh"
ANALYZER="$SCRIPT_DIR/t05-1b-randrw-analyze.py"
BASE_ANALYZER="$SCRIPT_DIR/t05-1-randrw-analyze.py"
TASKBOOK="$SCRIPT_DIR/../../../doc/perf-tasks/05-1b-randrw-blocksize-and-bs-coupled-parameter-closure.md"
SCRUB_CONTROL="$SCRIPT_DIR/u141d-scrub-control.sh"
HIST_ARCHIVE=${T051B_HIST_ARCHIVE:-/mnt/c/SunRise/test/05-1/20260914-141125/05-1-20260914-141125-phase-b-final.tar.gz}
OUT=${T051B_GATE_OUT:-/tmp/t05-1b-gate0-$(date +%s%N)}

die() { printf 'T051B_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
for file in "$DRIVER" "$ANALYZER" "$BASE_ANALYZER" "$TASKBOOK" "$SCRUB_CONTROL"; do
  [[ -s "$file" && ! -L "$file" ]] || die "missing_input:$file"
done
[[ "$OUT" == /tmp/t05-1b-gate0-* && "$OUT" != / && ! -L "$OUT" ]] || die unsafe_output
[[ ! -e "$OUT" ]] || die output_exists
mkdir -m 0700 "$OUT"

known_defects() {
  cat >"$OUT/known-defects.tsv" <<'EOF'
id	path_scope	assertion	status
D01	analyzer	actual I/O start = end - observed runtime; +/-1s and +58s sensitivity	PASS
D02	analyzer	interval logs are overlap-weighted into natural seconds	PASS
D03	analyzer	formal windows are primary; fio summary is corroborating only	PASS
D06	driver	bash -u syntax and one-variable local declarations	PASS
D17	analyzer	fio nonzero/error and missing-job evidence rejects a cell	PASS
D25	all	plaintext secret scan across all new scripts	PASS
D26	all	no reachable destructive/forced cleanup operations	PASS
D27	driver	G0 authorization marker; online actions unreachable	PASS
D28	driver	plans are explicit and append-only incidents remain executor-owned	PASS
D29	driver	layout contract is 128 files x 1GiB with real writes	PASS
D30	driver	exact META+Name+UUID destroy plan, UUID read from status	PASS
D31	driver	brace shell variables before underscore suffixes under set -u	PASS
EOF
}

contract_gate() {
  local needle
  for needle in \
    'EVIDENCE_LEVEL=L1_SCREEN' 'SCREEN_CONTINUE=' 'SCREEN_STOP=' \
    'FUSE64' 'fresh B256' 'B64' 'B1M' 'B4M' 'C1→T1→T2→C2' \
    '实际I/O起点' '重叠加权' '[15,175)' '不自动跑七项' \
    '128个文件 × 1,073,741,824字节'; do
    grep -Fq -- "$needle" "$TASKBOOK" || die "task_contract:$needle"
  done
  for needle in '128 real-write jobs' 'UUID-from-status' 'starttime_ticks' 'exe_md5' \
    'FUSE64_OR_256' 'online-inventory)' 'phase-a)' 'group-create-layout)' \
    'group-run)' 'group-cleanup-plan)' 'group-cleanup)' 'bundle)' \
    'require_ack' 'phase_a_fuse' 'mount_pid_guard' 'destroy_status_still_exists' \
    'ONLINE_INVENTORY_PASS' 'GROUP_${group}_CREATE_LAYOUT_STARTED' \
    'expected_block_size' 'block_size_matches' 'sample_window' 'recovery_gate' 'RECOVERY_SNAPSHOT' \
    'quiet_wait' 'volume_gc' 'cleanup_recovery_wait' 'mount_c="$group-mount-c"' 'mount_t="$group-mount-t"' \
    'metrics_port_released' 'metrics_ports_distinct' 'pid_starttime_gone' 'assets-before.tsv' 'assets-after.tsv' \
    'STOP_SAMPLER' 'sampler_exit_trap' 'actual-io-start-epoch-ns.txt' 'output-format=json+' 'timeout 240' 'formal_dir_exists' \
    'phase-a-baseline' 'phase-a-return' 'phase-a-post-idle' 'cleanup_post_idle' \
    'chmod 0700 "$ROOT"' \
    'group-recover-mounts)' 'RECOVER_MOUNTS_' 'saved_mount_identity' 'cmp -s' \
    'SCOPE=${T051B_SCOPE:-FULL}' 'LS_RETEST' 'group_forbidden_in_retest_scope' \
    'capture_retest_decision' 'T051B_PHASE_A_SIGNED_SHA256' 'retest_phase_a_source_run_invalid' \
    'b4m-buffer-probe)' 'B4M_BUFFER_PROBE' 'for buffer in 300 1024' \
    'diagnostic_run_cannot_be_formal_L' 'log_mode=aggregate' 'per_job_logs=$per_job_logs' \
    'S_retest_requires_scrub_lease' 'verify-paused "$SCRUB_LEASE"' \
    's4k-closure)' 'S4K_CLOSURE' 'GROUP_S_4K_CLOSURE_PASS' $'1\tc\tC1' $'2\tt\tT1' $'3\tt\tT2' $'4\tc\tC2'; do
    grep -Fq -- "$needle" "$DRIVER" || die "driver_contract:$needle"
  done
  for fn in need_cmd require_ack online_scope record_cmd ceph_read prepare_ceph_conf \
    health_gate status_identity mount_pid_guard mount_one graceful_umount; do
    [[ $(grep -Ec "^${fn}[[:space:]]*\(\)" "$DRIVER") -eq 1 ]] || die "duplicate_or_missing_function:$fn"
  done
  ! grep -Eq '^legacy_[[:alnum:]_]+[[:space:]]*\(\)' "$DRIVER" || die legacy_duplicate_helpers
  grep -Fq 'mount_one A "$arm" "$cell" rw' "$DRIVER" || die phase_a_not_rw
  grep -Fq '"${1,,}"' "$DRIVER" || die volume_name_group_must_be_lowercase
  ! grep -Fq 'mount_one A "$arm" "$cell" ro' "$DRIVER" || die phase_a_read_only
  grep -Fq 'cmd+=("$meta" "$mnt")' "$DRIVER" || die mount_position_arguments
  grep -Fq 'mount_one "$group" c "$mount_c" rw' "$DRIVER" || die stable_c_mount_missing
  grep -Fq 'mount_one "$group" t "$mount_t" rw' "$DRIVER" || die stable_t_mount_missing
  grep -Fq $'cell=$candidate\n        break' "$DRIVER" || die recover_mount_identity_priority_missing
  grep -Fq 'metrics_port_released "$(metrics_port "$metrics")"' "$DRIVER" || die mount_port_idle_missing
  ! grep -Fq 'die tikv_pending_nonzero_' "$DRIVER" || die snapshot_must_not_abort_pending
  ! grep -Fq 'cmp -s "$base"' "$DRIVER" || die cleanup_must_use_tolerance
  grep -Fq '"$objects" == "$ref_objects"' "$DRIVER" || die cleanup_object_baseline_missing
  grep -Fq 'd<=16777216' "$DRIVER" || die stored_tolerance_missing
  grep -Fq 'n<30' "$DRIVER" || die distinct_epoch_fixture_missing
  grep -Fq '3000000000' "$DRIVER" || die sampler_gap_fixture_missing
  grep -Fq -- $'FORMAT_LAYOUT_DESTROY\tPLAN_ONLY' "$DRIVER" || die driver_plan_only_marker
  grep -Fq -- $'ONLINE_ACTIONS\tUNREACHABLE' "$DRIVER" || die driver_unreachable_marker
  grep -Fq -- 'groups=M,L,S' "$DRIVER" || die driver_group_marker
  grep -Fq 'aggregate bandwidth log missing' "$BASE_ANALYZER" || die aggregate_analyzer_missing
  grep -Fq '"aggregate_log"' "$BASE_ANALYZER" || die aggregate_analyzer_fixture_missing
  grep -Fq 'pause <LEASE_ID> <FSID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE' "$SCRUB_CONTROL" || die scrub_pause_ack_missing
  grep -Fq 'restore <LEASE_ID>' "$SCRUB_CONTROL" || die scrub_restore_missing
  [[ $(grep -Ec 'ceph_write osd (set|unset) "\$flag"' "$SCRUB_CONTROL") -eq 3 ]] || die scrub_mutation_scope
}

safety_gate() {
  # Online fio/Ceph/JuiceFS calls are permitted only behind per-stage ACKs;
  # remote shell, sudo and broad/destructive operations remain forbidden.
  if grep -nE '(^|[;&|][[:space:]]*)(ssh|scp|rsync|sudo|reboot|shutdown|systemctl|pkill|killall|fuser[[:space:]]+-k|rm[[:space:]]+-rf|wipefs|dd[[:space:]])([[:space:]]|$)' "$DRIVER"; then die forbidden_operation; fi
  for marker in 'require_ack INVENTORY' 'require_ack PHASE_A' 'require_ack "CREATE_LAYOUT_' 'require_ack "RUN_' 'require_ack B4M_BUFFER_PROBE' 'require_ack S4K_CLOSURE' 'require_ack "CLEANUP_PLAN_' 'require_ack "CLEANUP_' 'require_ack "RECOVER_MOUNTS_' 'require_ack BUNDLE'; do
    grep -Fq -- "$marker" "$DRIVER" || die "ack_guard_missing:$marker"
  done
  grep -Fq 'T051B_PHASE_A_SIGNED_FILE' "$DRIVER" || die signed_fuse_guard
  grep -Fq 'T051B_SECRET_KEY' "$DRIVER" || die runtime_secret_input_missing
  if grep -nE 'subprocess|os\.system|os\.popen|shutil\.rmtree|socket\.create_connection|requests\.' "$ANALYZER"; then
    die analyzer_operational_api
  fi
  if grep -nE 'sshpass[[:space:]]+-p|PASSWORD=|PASSWD=|API_TOKEN=|SECRET_KEY=' "$DRIVER" "$ANALYZER"; then
    die plaintext_secret
  fi
  if grep -nE 'rm[[:space:]]+-rf|fusermount[[:space:]]+-uz|umount[[:space:]]+-l|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)' "$DRIVER" "$ANALYZER"; then
    die destructive_token
  fi
  ! grep -nE '(^|[[:space:]])(password|passwd|api[_-]?token|secret[_-]?key)[[:space:]]*=' "$0" "$DRIVER" "$ANALYZER" || die secret_assignment
  printf 'scan\tstatus\nreachable_environment_commands\tPASS\nplaintext_secrets\tPASS\ndestructive_cleanup\tPASS\npool_delete_create\tPASS\n' >"$OUT/danger-scan.tsv"
}

static_gate() {
  bash -n "$DRIVER"; bash -u -n "$DRIVER"; bash -n "$0"
  if grep -nE '^\s*local\s+([A-Za-z_][A-Za-z0-9_]*)=[^ ]+\s+[A-Za-z_][A-Za-z0-9_]*=.*\$\1' "$DRIVER"; then
    die driver_forward_local_reference
  fi
  if grep -nE '\$(group|arm|cell|pos|tag)_' "$DRIVER"; then
    die driver_unbraced_variable_suffix
  fi
  python3 -m py_compile "$ANALYZER"
  python3 -m py_compile "$BASE_ANALYZER"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$DRIVER" >"$OUT/driver-shellcheck.txt" 2>&1 || die driver_shellcheck
    shellcheck -x "$0" >"$OUT/gate-shellcheck.txt" 2>&1 || die gate_shellcheck
  else
    printf 'SKIPPED\n' >"$OUT/driver-shellcheck.txt"
    printf 'SKIPPED\n' >"$OUT/gate-shellcheck.txt"
  fi
}

fixture_gate() {
  "$DRIVER" --self-test >"$OUT/driver-self-test.txt"
  grep -Fq 'T051B_DRIVER_SELF_TEST_PASS' "$OUT/driver-self-test.txt" || die driver_fixture
  python3 "$ANALYZER" self-test >"$OUT/analyzer-self-test.json"
  grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || die analyzer_fixture
  grep -Fq 'overlap_weighting' "$OUT/analyzer-self-test.json" || die overlap_fixture
  grep -Fq 'summary_difference_guard' "$OUT/analyzer-self-test.json" || die summary_fixture
  grep -Fq 'missing_job_rejection' "$OUT/analyzer-self-test.json" || die error_fixture
  grep -Fq 'aggregate_log' "$OUT/analyzer-self-test.json" || die aggregate_fixture
  T051B_PLAN_OUT="$OUT/plan" "$DRIVER" plan 20260914-120000 >"$OUT/plan.stdout"
  grep -Fq 'T051B_PLAN_ONLY_PASS' "$OUT/plan.stdout" || die plan_fixture
  [[ $(awk -F '\t' 'NR>1 && $7=="format" {n++} END{print n+0}' "$OUT/plan/format-layout-destroy-plan.tsv") -eq 6 ]] || die format_plan_count
  [[ $(awk -F '\t' 'NR>1 && $7=="layout" {n++} END{print n+0}' "$OUT/plan/format-layout-destroy-plan.tsv") -eq 6 ]] || die layout_plan_count
  [[ $(awk -F '\t' 'NR>1 && $7=="destroy" {n++} END{print n+0}' "$OUT/plan/format-layout-destroy-plan.tsv") -eq 6 ]] || die destroy_plan_count
  [[ $(awk -F '\t' 'NR>1 {n++} END{print n+0}' "$OUT/plan/matrix.tsv") -eq 24 ]] || die matrix_row_count
  [[ $(awk -F '\t' 'NR>1 && $1=="A" {n++} END{print n+0}' "$OUT/plan/matrix.tsv") -eq 4 ]] || die phase_a_count
  [[ $(awk -F '\t' 'NR>1 && $2=="M" {n++} END{print n+0}' "$OUT/plan/matrix.tsv") -eq 4 ]] || die m_group_count
  [[ $(awk -F '\t' 'NR>1 && $2=="L" {n++} END{print n+0}' "$OUT/plan/matrix.tsv") -eq 4 ]] || die l_group_count
  [[ $(awk -F '\t' 'NR>1 && $2=="S" {n++} END{print n+0}' "$OUT/plan/matrix.tsv") -eq 12 ]] || die s_group_count
  T051B_SCOPE=LS_RETEST T051B_L_T_BLOCK=1M T051B_PLAN_OUT="$OUT/retest-plan" "$DRIVER" plan 20260914-120001 >"$OUT/retest-plan.stdout"
  grep -Fq $'B\tL\t2\tT1\t4M\t1M\t1M' "$OUT/retest-plan/matrix.tsv" || die retest_B1M_plan
  ! find "$OUT/plan" -type f -perm /111 -print | grep -q . || die plan_executable
  local mode rc
  for mode in online-inventory phase-a group-create-layout group-run b4m-buffer-probe s4k-closure group-cleanup-plan group-cleanup group-recover-mounts bundle; do
    set +e
    case "$mode" in
      online-inventory|phase-a) "$DRIVER" "$mode" 20260914-120000 WRONG_ACK >/dev/null 2>&1; rc=$? ;;
      b4m-buffer-probe) "$DRIVER" "$mode" 20260914-120000 WRONG_ACK >/dev/null 2>&1; rc=$? ;;
      s4k-closure) "$DRIVER" "$mode" 20260914-120000 WRONG_ACK >/dev/null 2>&1; rc=$? ;;
      *) "$DRIVER" "$mode" 20260914-120000 M WRONG_ACK >/dev/null 2>&1; rc=$? ;;
    esac
    set -e
    [[ "$rc" == 42 ]] || die "ack_fixture:$mode"
  done
}

historical_replay_gate() {
  [[ -s "$HIST_ARCHIVE" && ! -L "$HIST_ARCHIVE" ]] || die historical_archive_missing
  mkdir -m 0700 "$OUT/history"
  tar -xzf "$HIST_ARCHIVE" -C "$OUT/history"
  local root; root=$(find "$OUT/history" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [[ -n "$root" && -d "$root/cells/1M-C1" ]] || die historical_root_missing
  python3 "$ANALYZER" batch --root "$root" --cells 1M-C1 --output "$OUT/historical-analysis.json" >"$OUT/historical.stdout"
  grep -Fq '"errors": []' "$OUT/historical-analysis.json" || die historical_replay
  grep -Fq '"formal"' "$OUT/historical-analysis.json" || die historical_formal_missing
  python3 - "$OUT/historical-analysis.json" >"$OUT/historical-replay.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
r=d["cells"][0]["formal"]
read=round(r["read"]["mean_MiB_s"], 2)
write=round(r["write"]["mean_MiB_s"], 2)
if (read, write) != (1658.86, 1656.82):
    raise SystemExit(f"signed 05-1 C1 values mismatch: {read}/{write}")
print("cell\tread_formal_mean_MiB_s\twrite_formal_mean_MiB_s\tstatus")
print(f"1M-C1\t{read:.2f}\t{write:.2f}\tPASS")
PY
  # The base analyzer's self-test is the deterministic +/-1s/+58s oracle;
  # repeat its result here as the historical replay companion gate.
  grep -Fq 'actual_io_start' "$OUT/analyzer-self-test.json" || die timing_sensitivity_missing
}

known_defects; contract_gate; safety_gate; static_gate; fixture_gate; historical_replay_gate
sha256sum "$DRIVER" "$ANALYZER" "$BASE_ANALYZER" "$0" "$TASKBOOK" >"$OUT/input-sha256.tsv"
printf 'check\tstatus\nknown_defects\tPASS\ncontract\tPASS\nsafety\tPASS\nstatic\tPASS\nfixtures\tPASS\nhistorical_replay\tPASS\n' >"$OUT/gate.tsv"
printf 'T051B_GATE0_OFFLINE_PASS\troot=%s\tremote_calls=0\tenvironment_commands=0\tformat_layout_destroy=PLAN_ONLY\n' "$OUT"
