#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RUN=$DIR/t04-7-randrw-async-screen-run.sh
ANA=$DIR/t04-7-randrw-async-screen-analyze.py
BASE=$DIR/t04tmp2i-randrw-run.sh
SCRUB=$DIR/u141d-scrub-control.sh
OUT=${T047_GATE_OUT:-/tmp/t04-7-gate0-$$}
fail() { printf '04_7_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }

[[ ! -e $OUT ]] || fail output_exists
mkdir -m 0700 "$OUT"
for file in "$RUN" "$ANA" "$BASE" "$SCRUB"; do [[ -f $file && ! -L $file ]] || fail "missing_or_symlink:$file"; done

bash -n "$RUN"; bash -u -n "$RUN"; bash -n "$BASE"; bash -n "$SCRUB"
PYTHONPYCACHEPREFIX=$OUT/pycache python3 -m py_compile "$ANA"
if command -v shellcheck >/dev/null; then
  shellcheck -x "$RUN" "$0" >"$OUT/shellcheck.txt" 2>&1 || true
else
  printf 'SKIPPED\n' >"$OUT/shellcheck.txt"
fi

for token in 'A1 B1 B2 A2' 'CACHE_MIB=31978' 'KIND=P25' '-o async_dio' \
  '--max-uploads 150' '--max-fuse-io 256K' '--free-space-ratio 0.20' '--writeback' \
  'runtime_sampler' 'drain_writeback' 'state_return' 'readback_probe' 'destroy_storage'; do
  grep -Fq -- "$token" "$RUN" || fail "runner_contract_missing:$token"
done
for token in 'ioengine=libaio' 'iodepth=128' 'direct=1' 'bs=256K' 'rw=$mode' \
  'rwmixread=50' 'size=1G' 'numjobs=128' 'runtime=180' 'log_avg_msec=1000'; do
  grep -Fq -- "$token" "$BASE" || fail "base_fio_contract_missing:$token"
done
for token in 'FIO_JSON_FULL_TIMED_RUN' 'NO_BACKFILL' 'A1' 'B1' 'B2' 'A2' \
  'RESOLUTION_INSUFFICIENT' 'CONTINUE_CANDIDATE' 'STOP_NEGATIVE' 'STOP_NO_SIGNAL'; do
  grep -Fq -- "$token" "$ANA" || fail "analyzer_contract_missing:$token"
done

[[ $(grep -Fc 'for item in $(matrix); do run_cell "$item"; done' "$RUN") == 1 ]] || fail matrix_loop_missing
[[ $(grep -Ec '^matrix\(\)' "$RUN") == 1 ]] || fail matrix_definition_count
[[ $(grep -Ec '^set -u$' "$BASE") == 1 ]] || fail base_dispatch_boundary
if grep -En '^[[:space:]]*(sudo[[:space:]]+)?(rm[[:space:]]+-r|losetup[[:space:]]+-D|wipefs|dd[[:space:]]|reboot|shutdown|poweroff|halt|systemctl|pkill|killall|fuser[[:space:]]+-k)' "$RUN"; then
  fail forbidden_operation
fi
if grep -En '^[[:space:]]*(sudo[[:space:]]+)?umount[[:space:]]+(-f|--force|-l|--lazy)' "$RUN"; then
  fail forbidden_unmount
fi
if grep -Ein '(password|passwd|api[_-]?token|secret[_-]?key)[[:space:]]*=' "$RUN" "$ANA"; then
  fail embedded_secret
fi

sampler=$(sed -n '/^runtime_sampler()/,/^}/p' "$BASE")
if grep -Eq '(^|[[:space:]])(find|du|sort)([[:space:]]|$)' <<<"$sampler"; then
  fail formal_sampler_recursive_or_sorting
fi
grep -Fq 'time.monotonic_ns()' <<<"$sampler" || fail sampler_monotonic_deadline_missing
grep -Fq 'os.statvfs' <<<"$sampler" || fail sampler_statvfs_missing

"$RUN" offline-self-test 20000101-000000 >"$OUT/runner-self-test.txt"
grep -Fq '04_7_OFFLINE_SELF_TEST_PASS' "$OUT/runner-self-test.txt" || fail runner_self_test
python3 "$ANA" self-test --root "$OUT/fixture" --output "$OUT/analyzer-self-test.json" >"$OUT/analyzer-self-test.txt"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail analyzer_self_test

grep -nE '^[[:space:]]*sudo[[:space:]]+' "$RUN" "$SCRUB" >"$OUT/sudo-lines.txt" || true
sha256sum "$RUN" "$ANA" "$0" "$BASE" "$SCRUB" >"$OUT/scripts.sha256"
printf 'check\tstatus\nsyntax\tPASS\ncontract\tPASS\nself_test\tPASS\nsafety_scan\tPASS\n' >"$OUT/gate.tsv"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$OUT/SHA256SUMS"
printf '04_7_GATE0_OFFLINE_PASS\troot=%s\n' "$OUT"
