#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN=$DIR/t04tmp2g-writeback-run.sh
ANALYZER=$DIR/t04tmp2g-writeback-analyze.py
RECOVERY=$DIR/t04tmp2g-writeback-recovery.sh
SCRUB=$DIR/u141d-scrub-control.sh
RUN_ID=${TMP2G_GATE_RUN_ID:-20260905-141236}
OUT=${TMP2G_GATE_OUT:-/tmp/t04tmp2g-gate0-$RUN_ID}

fail(){ printf '04TMP2G_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || fail invalid_RUN_ID
[[ $OUT == /tmp/t04tmp2g-gate0-* && ! -e $OUT ]] || fail unsafe_or_existing_output
mkdir -m 0700 "$OUT"

for file in "$RUN" "$ANALYZER" "$RECOVERY" "$SCRUB"; do
  [[ -f $file && ! -L $file ]] || fail "missing_or_symlink:$file"
done
bash -n "$RUN"; bash -u -n "$RUN"; bash -n "$RECOVERY"; bash -u -n "$RECOVERY"
PYTHONPYCACHEPREFIX=$OUT/pycache python3 -m py_compile "$ANALYZER"

if grep -EnH 'rm[[:space:]]+-r|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|drop_caches|reboot|shutdown|poweroff|halt|systemctl|/dev/(nvme|sd|md)[[:alnum:]]*' \
    "$RUN" "$ANALYZER" "$RECOVERY" "$SCRUB" >"$OUT/forbidden.txt"; then
  fail forbidden_command
fi
! grep -EnH '(sshpass|SSHPASS=|password=|Sunrise@)' "$RUN" "$ANALYZER" "$RECOVERY" "$SCRUB" \
  >"$OUT/secrets.txt" || fail possible_secret

for cell in W20A-randwrite W32-randwrite W64-randwrite W128-randwrite W20B-randwrite; do
  grep -Fq "$cell" "$RUN" || fail "matrix_cell_missing:$cell"
  grep -Fq "$cell" "$ANALYZER" || fail "analyzer_cell_missing:$cell"
done
! grep -Fq 'W96-randwrite' "$RUN" || fail unplanned_W96
grep -Fq "printf 'W20A-randwrite\\nW32-randwrite\\nW64-randwrite\\nW128-randwrite\\nW20B-randwrite\\n'" "$RUN" || fail matrix_order
grep -Fq 'size=1G' "$RUN" || fail per_job_size_missing
grep -Fq '137438953472' "$RUN" || fail fixed_128GiB_total_missing
grep -Fq 'fixed-total-write-bytes.txt' "$RUN" || fail fixed_total_sidecar_missing
grep -Fq 'fio-start-epoch-ns.txt' "$RUN" || fail fio_start_sidecar_missing
grep -Fq 'fio-end-epoch-ns.txt' "$RUN" || fail fio_end_sidecar_missing
grep -Fq 'fio.rc' "$RUN" || fail fio_rc_sidecar_missing
grep -Fq 'timeout 900 fio' "$RUN" || fail fio_watchdog_missing
[[ $(grep -Fc 'timeout 900 fio "$out/randwrite.fio"' "$RUN") == 1 ]] || fail fio_must_execute_exactly_once
! grep -Eq "printf '[^']*(time_based=1|runtime=180)" "$RUN" || fail time_based_contract_present
grep -Fq 'foreground_verdict' "$ANALYZER" || fail foreground_verdict_missing
grep -Fq 'anchor_drift_pct' "$ANALYZER" || fail anchor_drift_missing
grep -Fq 'first_30s_MiBs' "$ANALYZER" || fail burst_windows_missing
grep -Fq 'strict_zero_seconds' "$ANALYZER" || fail drain_metric_missing
grep -Fq 'fixed write contract failed' "$ANALYZER" || fail fixed_total_analyzer_gate_missing
grep -Fq 'expected 128 bw logs' "$ANALYZER" || fail exact_log_count_gate_missing
grep -Fq 'fio wall timing self-test' "$ANALYZER" || fail wall_timing_fixture_missing
grep -Fq 'decision self-test' "$ANALYZER" || fail decision_fixture_missing

grep -Fq -- '--cache-size "$TIER_MIB" --free-space-ratio 0.20 --writeback' "$RUN" || fail writeback_mount_contract
grep -Fq 'allow_file_create=0' "$RUN" || fail existing_file_guard
grep -Fq 'create_on_open=0' "$RUN" || fail create_guard
grep -Fq 'for i in $(seq 0 127)' "$RUN" || fail explicit_128_jobs
grep -Fq 'verify_loop' "$RUN" || fail loop_identity_guard
grep -Fq 'rawstaging_snapshot' "$RUN" || fail rawstaging_evidence
grep -Fq 'statvfs_available' "$RUN" || fail statvfs_sampler
grep -Fq 'previous_cell_recovery_missing' "$RUN" || fail intercell_recovery_guard
grep -Fq '^after-W(20A|20B|32|64|128)-randwrite$' "$RECOVERY" || fail recovery_label_contract_missing
! grep -Fq 'after-W(20|32|64|96|128)-randwrite' "$RECOVERY" || fail stale_recovery_label_contract
grep -Fq 'JFS_GC_SKIPPEDTIME=0' "$RECOVERY" || fail gc_recovery_missing
grep -Fq 'OBJECT_TOLERANCE=8192' "$RECOVERY" || fail object_return_guard
grep -Fq 'tikv_idle_gate' "$RECOVERY" || fail tikv_cooldown_guard
grep -Fq 'OWNED_FLAGS=(noscrub nodeep-scrub)' "$SCRUB" || fail scrub_ownership_guard

grep -En 'sudo[[:space:]]+' "$RUN" >"$OUT/sudo-surface.txt" || fail expected_sudo_surface_missing
grep -En 'sudo[[:space:]]+' "$RECOVERY" >>"$OUT/sudo-surface.txt" || fail recovery_sudo_surface_missing
grep -En 'sudo[[:space:]]+' "$SCRUB" >>"$OUT/sudo-surface.txt" || fail scrub_sudo_surface_missing
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|chmod|dd|wipefs|systemctl|reboot|shutdown|mount[[:space:]]+/dev/(nvme|sd|md)|mkfs[^[:space:]]*[[:space:]]+/dev/(nvme|sd|md))' \
    "$RUN" >"$OUT/unsafe-sudo.txt"; then
  fail unsafe_sudo_surface
fi
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|rmdir|chmod|chown|mount|umount|losetup|mkfs|dd|wipefs|systemctl|reboot|shutdown)' \
    "$RECOVERY" >"$OUT/unsafe-recovery-sudo.txt"; then
  fail recovery_contains_storage_sudo
fi

bash "$RUN" offline-self-test "$RUN_ID" >"$OUT/runner-self-test.txt"
bash "$RECOVERY" offline-self-test >"$OUT/recovery-self-test.txt"
env U141D_SCRUB_STATE_DIR="$OUT/scrub-state" bash "$SCRUB" --self-test >"$OUT/scrub-self-test.txt"
python3 "$ANALYZER" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" \
  >"$OUT/analyzer-self-test.stdout"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail analyzer_selftest

sha256sum "$RUN" "$ANALYZER" "$RECOVERY" "$0" "$SCRUB" >"$OUT/scripts.sha256"
printf 'RUN_ID\t%s\nGATE_STATUS\tPASS\nFIXED_WRITE_BYTES\t137438953472\n' "$RUN_ID" >"$OUT/summary.tsv"
printf '04TMP2G_GATE0_OFFLINE_PASS root=%s\n' "$OUT"
