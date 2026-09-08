#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
RUN=$DIR/t04tmp2h-randrw-run.sh
ANA=$DIR/t04tmp2h-randrw-analyze.py
SCRUB=$DIR/u141d-scrub-control.sh
NSB=$DIR/t39-nsbgate.sh
OUT=${TMP2H_GATE_OUT:-/tmp/t04tmp2h-gate0-$$}
fail() { printf '04TMP2H_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }

[[ ! -e $OUT ]] || fail output_exists
mkdir -m 0700 "$OUT"
for file in "$RUN" "$ANA" "$SCRUB" "$NSB"; do [[ -r $file ]] || fail "missing:$file"; done

bash -n "$RUN"
bash -n "$SCRUB"
bash -n "$NSB"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANA"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning "$RUN" "$0" >"$OUT/shellcheck.txt" || fail shellcheck
else
  printf 'shellcheck unavailable; bash -n used\n' >"$OUT/shellcheck.txt"
fi

for symbol in cell_spec mount_pid_gate run_fio a0_mount_gate runtime_sampler \
  drain_writeback prepare_cache cleanup_cache initialize_seed state_return \
  need_supplement a0_mid_guard resume_postfio bundle_run; do
  grep -Eq "^${symbol}[[:space:]]*\(\)" "$RUN" || fail "runner_function_missing:$symbol"
done
for symbol in aggregate_logs bandwidth_window online_cell_summary anchor_drift \
  pareto_decision pressure_test analyze self_test; do
  grep -Eq "^def ${symbol}\(" "$ANA" || fail "analyzer_function_missing:$symbol"
done

for token in 'rw=$mode' 'rwmixread=50' 'bs=256K' 'ioengine=libaio' \
  'iodepth=128' 'direct=1' 'time_based' 'runtime=180' 'numjobs=128' \
  'allow_file_create=0' 'write_bw_log=' 'per_job_logs=1' \
  '--max-fuse-io 256K' '--max-uploads 150' '--free-space-ratio 0.20' \
  '--writeback' 'METRICS_ADDR=127.0.0.1:9568'; do
  grep -Fq -- "$token" "$RUN" || fail "fio_or_mount_contract_missing:$token"
done
for token in 'T32-R' 'T32-W' 'T32-P50' 'T128-W' 'T128-R' 'T128-P50' \
  'T64-R' 'T64-W' 'T64-P50' 'T256-W' 'T256-R' 'T256-P50' \
  'T96-R' 'T96-W' 'T96-P50' 'A0-pre' 'A0-mid' 'A0-post' 'P25' 'P75'; do
  grep -Fq -- "$token" "$RUN" || fail "matrix_contract_missing:$token"
done
for token in 'losetup --find --show --nooverlap' \
  'mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0' \
  'mount -o noatime,nodiscard' 'compact_running' 'compact_queue_len' \
  'kv_sync_lat' '1800' '8192' 'RESOLUTION-STOP-A0-MID'; do
  grep -Fq -- "$token" "$RUN" || fail "lifecycle_contract_missing:$token"
done
for token in 'result_root_identity' 'a0-probe-assets.tsv' 'RECOVERY-CLOSED' \
  'strict-drain-end-ns.txt' 'trap on_exit EXIT' 'initialize_seed' 'seed-pool.tsv' \
  'scrub-sessions' 'health-final' 'runtime formal coverage too sparse' 'if not rc_path.is_file()'; do
  grep -Fq -- "$token" "$RUN" "$ANA" || fail "evidence_or_recovery_contract_missing:$token"
done
grep -Fq 'rmdir "$CACHE_MNT" || die' "$RUN" || fail cache_mount_cleanup_not_strict
grep -Fq 'sudo rmdir "$BACKING_ROOT" || die' "$RUN" || fail backing_cleanup_not_strict

if grep -En '^[[:space:]]*(sudo[[:space:]]+)?(rm[[:space:]]+-r|losetup[[:space:]]+-D|wipefs|reboot|shutdown|poweroff|halt|systemctl|pkill|killall|fuser[[:space:]]+-k)' "$RUN"; then
  fail forbidden_mutation
fi
if grep -En '^[[:space:]]*(sudo[[:space:]]+)?umount[[:space:]]+(-f|--force|-l|--lazy)' "$RUN"; then
  fail forbidden_unmount
fi
if grep -Ein '(password|passwd|api[_-]?token|secret[_-]?key)[[:space:]]*=' "$RUN" "$ANA"; then
  fail embedded_secret
fi

bash "$RUN" offline-self-test 20000101-000000 >"$OUT/runner-self-test.txt"
python3 "$ANA" self-test --root "$OUT/fixture" --output "$OUT/analyzer-self-test.json" \
  >"$OUT/analyzer-self-test.txt"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail analyzer_self_test
python3 "$ANA" cell-summary --cell "$OUT/fixture/cells/T32-R" \
  --output "$OUT/cell-summary.json" >"$OUT/cell-summary.txt"
python3 - "$OUT/cell-summary.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['read_mib_s'] > 0 and d['write_mib_s'] > 0 and d['mean_direction_mib_s'] > 0
PY

sha256sum "$RUN" "$ANA" "$0" "$SCRUB" "$NSB" >"$OUT/scripts.sha256"
printf '04TMP2H_GATE0_OFFLINE_PASS\troot=%s\n' "$OUT"
