#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RUN=$DIR/t04tmp2j-randrw-cache-run.sh
ANA=$DIR/t04tmp2j-randrw-cache-analyze.py
SCRUB=$DIR/u141d-scrub-control.sh
OUT=${T04TMP2J_GATE_OUT:-/tmp/t04tmp2j-gate0-$$}
fail(){ printf '04TMP2J_GATE0_FAIL\\t%s\\n' "$*" >&2; exit 42; }
[[ -f $RUN && ! -L $RUN ]] || fail runner_missing
[[ -f $ANA && ! -L $ANA ]] || fail analyzer_missing
[[ -f $SCRUB && ! -L $SCRUB ]] || fail scrub_missing
[[ ! -e $OUT ]] || fail output_exists
mkdir -m 0700 "$OUT"
bash -n "$RUN"; bash -u -n "$RUN"; bash -n "$SCRUB"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANA"
if command -v shellcheck >/dev/null; then shellcheck "$RUN" "$SCRUB" >"$OUT/shellcheck.txt"; else printf 'SKIPPED\\n' >"$OUT/shellcheck.txt"; fi
for token in 'A0-pre C32 C128 C64 A0-mid C256 C96 A0-post' 'rw=randrw' 'rwmixread=50' 'bs=256K' 'ioengine=libaio' 'iodepth=128' 'numjobs=128' 'runtime=180' 'log_avg_msec=1000' '--max-fuse-io 256K' '--max-uploads 150' '--free-space-ratio 0.20' 'cache-size 0' ; do grep -Fq -- "$token" "$RUN" || fail "contract_missing:$token"; done
if grep -Ein '(^|[[:space:]])(ssh|scp|rm[[:space:]]+-r|losetup|mkfs|wipefs|drop_caches|reboot|shutdown|poweroff|halt|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+(-f|--force|-l|--lazy))' "$RUN"; then fail forbidden_operation_text; fi
if grep -Ein '(password|passwd|api[_-]?token|secret[_-]?key)[[:space:]]*=' "$RUN" "$ANA"; then fail embedded_secret; fi
"$RUN" offline-self-test 20000101-000000 NONE >"$OUT/runner-self-test.txt"
grep -Fq '04TMP2J_OFFLINE_SELF_TEST_PASS cells=8' "$OUT/runner-self-test.txt" || fail runner_fixture
python3 "$ANA" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" >"$OUT/analyzer-self-test.txt"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail analyzer_fixture
sha256sum "$RUN" "$ANA" "$0" "$SCRUB" >"$OUT/scripts.sha256"
printf 'RUN_ID\\tgate0-fixture\\nGATE_STATUS\\tPASS\\n' >"$OUT/summary.tsv"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$OUT/SHA256SUMS"
printf '04TMP2J_GATE0_OFFLINE_PASS\\troot=%s\\n' "$OUT"

