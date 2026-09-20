#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 05-1 Gate 0 is deliberately offline.  It validates only the new analyzer
# and the frozen task contract; no environment command is reachable here.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ANALYZER="$SCRIPT_DIR/t05-1-randrw-analyze.py"
DRIVER="$SCRIPT_DIR/t05-1-randrw-driver.sh"
TASKBOOK="$SCRIPT_DIR/../../../doc/perf-tasks/05-1-randrw-block-size-sweep-and-adaptive-tuning.md"
REUSE_RANDRW="$SCRIPT_DIR/t04tmp2i-randrw-analyze.py"
REUSE_WEIGHTED="$SCRIPT_DIR/t04-8-analyze.py"
OUT=${T051_GATE_OUT:-/tmp/t05-1-gate0-$(date +%s%N)}

die() { printf 'T051_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }

[[ -f "$ANALYZER" && ! -L "$ANALYZER" ]] || die analyzer_missing
[[ -f "$DRIVER" && ! -L "$DRIVER" ]] || die driver_missing
[[ -f "$TASKBOOK" && ! -L "$TASKBOOK" ]] || die taskbook_missing
[[ -f "$REUSE_RANDRW" && ! -L "$REUSE_RANDRW" ]] || die reuse_randrw_missing
[[ -f "$REUSE_WEIGHTED" && ! -L "$REUSE_WEIGHTED" ]] || die reuse_weighted_missing
[[ "$OUT" == /tmp/t05-1-gate0-* && "$OUT" != / && ! -L "$OUT" ]] || die unsafe_output
[[ ! -e "$OUT" ]] || die output_exists
mkdir -m 0700 "$OUT"

check_contract() {
  local needle
  for needle in \
    '4K/16K/64K/256K/1M/4M' \
    '256K-A → 4K → 16K → 64K → 1M → 4M → 4M → 1M → 64K → 16K → 4K → 256K-B' \
    '--max-fuse-io 256K' '--max-fuse-io 1M' \
    'FUSE请求尺寸' 'READ/WRITE分别统计' '实际timed-I/O起点' \
    '重叠加权' '[15,175)' '不自动执行'; do
    grep -Fq -- "$needle" "$TASKBOOK" || die "taskbook_contract_missing:$needle"
  done
}

check_source_safety() {
  # The analyzer is an offline Python consumer.  Scan executable-looking
  # operations, not prose, and keep the reused operational runner out of the
  # call chain.  The latter is intentional: it owns 04-tmp2i cache lifecycle.
  if grep -nE '(^|[[:space:];])((sudo|ssh|scp|rsync|mount|umount|ceph|juicefs)[[:space:]]|subprocess\.|os\.system)' \
      "$ANALYZER"; then
    die analyzer_operational_command
  fi
  if grep -nE '(sshpass[[:space:]]+-p|PASSWORD=|API_TOKEN=|SECRET_KEY=)' "$ANALYZER"; then
    die analyzer_embedded_secret
  fi
  for source in "$REUSE_RANDRW" "$REUSE_WEIGHTED"; do
    grep -Fq 'overlap' "$source" || die "reuse_overlap_algorithm_missing:$source"
  done
  ! grep -Fq 't04tmp2i-randrw-run.sh' "$ANALYZER" || die accidental_runner_dependency
  ! grep -Fq 'ssh' "$DRIVER" || die driver_remote_command
  # PLAN_ONLY rows are inert records, not shell commands.  All other driver
  # lines must be free of privileged or irreversible operations.
  if awk '!/^[[:space:]]*#/ && !/PLAN_ONLY/' "$DRIVER" | \
      grep -nE '(^|[;&|[:space:]])(sudo|scp|rsync|reboot|shutdown|poweroff|systemctl[[:space:]]+(stop|restart)|rm[[:space:]]+-r|wipefs|dd[[:space:]]|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|ceph[[:space:]]+.*compact|noscrub|nodeep-scrub|juicefs[[:space:]]+(format|destroy|layout))'; then
    die driver_forbidden_active_operation
  fi
  grep -Fq $'ceph_compact\tPLAN_ONLY' "$DRIVER" || die compact_plan_missing
  grep -Fq $'scrub_pause\tPLAN_ONLY' "$DRIVER" || die scrub_plan_missing
  grep -Fq $'format_layout_destroy\tNOT_USED' "$DRIVER" || die volume_lifecycle_plan_missing
  for token in 'phase-b-1m)' 'phase-b-4m)' 'T051_BETWEEN_BS_ACK' \
    'reference-mount-process.tsv' '--max-fuse-io 256K' '--max-uploads 150' '--cache-size 0' \
    'mount_pid_identity "$MNT" "$CELL_ROOT/mount-process.tsv" "$CELL_ROOT/juicefs.log"' \
    'T051_PHASE_A_EVIDENCE_ROOT' 'PHASE_A_EXTERNAL_ACCEPTED.tsv' \
    'sample_metrics pre' 'sample_metrics post' 'http://$METRICS/metrics' 'pre_cell_recovery' \
    'gc --compact --delete --threads 32' 'timeout "$GC_TIMEOUT_SECONDS"' \
    'readonly-gates.tsv' 'pending_150' '16777216' 'volume identity changed' \
    'objects/stored missing or invalid' 'v+0<0' 'for i in $(seq 1 180)' \
    'tail -n 3' 'recovery_pass=1' \
    'find "$ROOT" -type f'; do
    grep -Fq -- "$token" "$DRIVER" || die "driver_contract_missing:$token"
  done
  if grep -nE '^\s*local\s+([A-Za-z_][A-Za-z0-9_]*)=[^ ]+\s+[A-Za-z_][A-Za-z0-9_]*=.*\$\1' "$DRIVER"; then
    die driver_forward_local_reference
  fi
}

check_known_defects() {
  # Scope is limited to this new offline analyzer.  D01/D02/D03 are the
  # measured time-series hazards; D17 is the raw fio-error hazard; D25/D26/D27
  # assert that the offline component cannot carry secrets, destructive
  # operations, or a production verdict.  Mount/process/ledger classes remain
  # online-driver obligations and are not silently claimed here.
  grep -Fq 'effective_runtime_s = max(float(RUNTIME_S), runtime_ms / 1000.0)' "$ANALYZER" || die D01_runtime_rule
  grep -Fq 'start_ns = end_ns - int(effective_runtime_s * 1_000_000_000)' "$ANALYZER" || die D01_start_rule
  grep -Fq 'overlap = min(end, runtime_s, second + 1.0) - max(begin, float(second))' "$ANALYZER" || die D02_overlap_rule
  grep -Fq 'fio_summary' "$ANALYZER" && grep -Fq 'formal' "$ANALYZER" || die D03_summary_separation
  grep -Fq 'job.get("error", -1)' "$ANALYZER" || die D17_fio_error_gate
  ! grep -Eq 'sshpass[[:space:]]+-p|PASSWORD=|SECRET_KEY=' "$ANALYZER" || die D25_secret
  local dash=- token
  for token in "rm ${dash}rf" "fusermount ${dash}uz" "umount ${dash}l" \
               "losetup ${dash}D" "pk""ill" "kill""all" "fuser ${dash}k"; do
    ! grep -Fq -- "$token" "$ANALYZER" || die D26_destructive
  done
  grep -Fq 'RAW_MEASUREMENTS_ONLY' "$ANALYZER" && \
    grep -Fq 'REQUIRES_SECOND_PARTY_REVIEW' "$ANALYZER" || die D27_verdict_freeze
  printf 'D01\tPASS\nD02\tPASS\nD03\tPASS\nD17\tPASS\nD25\tPASS\nD26\tPASS\nD27\tPASS\n' \
    >"$OUT/known-defects.tsv"
}

check_static() {
  bash -n "$0"
  bash -u -n "$0"
  bash -n "$DRIVER"
  bash -u -n "$DRIVER"
  python3 -m py_compile "$ANALYZER"
  if command -v shellcheck >/dev/null; then
    shellcheck -x "$0" >"$OUT/shellcheck.txt" 2>&1 || die shellcheck_failed
    shellcheck -x "$DRIVER" >"$OUT/driver-shellcheck.txt" 2>&1 || true
  else
    printf 'SKIPPED\n' >"$OUT/shellcheck.txt"
    printf 'SKIPPED\n' >"$OUT/driver-shellcheck.txt"
  fi
  grep -nE '(password|passwd|api[_-]?token|secret[_-]?key)[[:space:]]*=' \
    "$0" "$ANALYZER" >"$OUT/secret-scan.txt" && die plaintext_secret || true
}

check_fixture() {
  "$DRIVER" offline-self-test 20000101-000000 >"$OUT/driver-self-test.txt"
  grep -Fq 'T051_DRIVER_OFFLINE_SELF_TEST_PASS' "$OUT/driver-self-test.txt" || die driver_self_test
  grep -Fq 'phase_a=12_unique' "$OUT/driver-self-test.txt" || die driver_phase_a_unique_fixture
  grep -Fq 'phase_b=8_unique' "$OUT/driver-self-test.txt" || die driver_phase_b_unique_fixture
  python3 "$ANALYZER" self-test >"$OUT/analyzer-self-test.json"
  grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || die analyzer_self_test
  grep -Fq 'overlap_weighting' "$OUT/analyzer-self-test.json" || die fixture_overlap_missing
  grep -Fq 'gap_and_tail_zero_fill' "$OUT/analyzer-self-test.json" || die fixture_zero_fill_missing
  grep -Fq 'full_log_vs_fio_io_bytes_delta_pct' "$ANALYZER" || die log_byte_reconciliation_missing
  grep -Fq 'summary_difference_guard' "$OUT/analyzer-self-test.json" || die fixture_summary_guard_missing
  grep -Fq 'missing_job_rejection' "$OUT/analyzer-self-test.json" || die fixture_failure_missing
}

check_contract
check_source_safety
check_known_defects
check_static
check_fixture

sha256sum "$ANALYZER" "$DRIVER" "$0" "$TASKBOOK" "$REUSE_RANDRW" "$REUSE_WEIGHTED" >"$OUT/input-sha256.tsv"
printf 'check\tstatus\ncontract\tPASS\nsource_safety\tPASS\nknown_defects\tPASS\nstatic\tPASS\nfixture\tPASS\ndriver\tPASS\n' >"$OUT/gate.tsv"
printf 'T051_GATE0_OFFLINE_PASS\troot=%s\tonline_driver=ACK_GATED_NOT_EXECUTED\n' "$OUT"
