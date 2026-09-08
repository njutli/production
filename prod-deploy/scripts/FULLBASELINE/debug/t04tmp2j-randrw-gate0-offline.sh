#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RUN=$DIR/t04tmp2j-randrw-run.sh
ANA=$DIR/t04tmp2j-randrw-analyze.py
BASE=$DIR/t04tmp2i-randrw-analyze.py
SCRUB=$DIR/u141d-scrub-control.sh
OUT=${TMP2J_GATE_OUT:-/tmp/t04tmp2j-gate0-$$}
fail() { printf '04TMP2J_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }

[[ ! -e $OUT ]] || fail output_exists
mkdir -m 0700 "$OUT"
for file in "$RUN" "$ANA" "$BASE" "$SCRUB"; do [[ -r $file ]] || fail "missing:$file"; done
bash -n "$RUN"
bash -n "$SCRUB"
PYTHONPYCACHEPREFIX=$OUT/pycache python3 -m py_compile "$ANA" "$BASE"

bash "$RUN" offline-self-test 20000101-000000 >"$OUT/runner-self-test.txt"
python3 "$ANA" self-test --root "$OUT/fixture" --output "$OUT/analyzer-self-test.json" >"$OUT/analyzer-self-test.txt"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail analyzer_self_test

expected=$'A0-pre\nC32\nC128\nC64\nA0-mid\nC256\nC96\nA0-post'
actual=$(sed -n '/^matrix()/,/^}/p' "$RUN" | sed -n '/^A0-pre$/,/^A0-post$/p')
[[ $actual == "$expected" ]] || fail matrix_order
for token in 'rw=$mode' 'rwmixread=50' 'bs=256K' 'ioengine=libaio' 'iodepth=128' \
  'direct=1' 'runtime=180' 'numjobs=128' 'randseed=20260905' '--max-fuse-io 256K' \
  '--max-uploads 150' '--free-space-ratio 0.20' 'run_fio warmup randread'; do
  grep -Fq -- "$token" "$RUN" || fail "contract_missing:$token"
done
for size in 32768 65536 98304 131072 262144; do
  grep -Fq -- "$size" "$RUN" || grep -Fq 'CACHE_MIB=$((SIZE*1024))' "$RUN" || fail "cache_size_missing:$size"
done

mount_body=$(sed -n '/^mount_jfs()/,/^}/p' "$RUN")
sampler_body=$(sed -n '/^runtime_sampler()/,/^}/p' "$RUN")
for forbidden in --writeback --read-only losetup mkfs.ext4; do
  grep -Fq -- "$forbidden" <<<"$mount_body" && fail "forbidden_mount_or_storage:$forbidden"
done
if grep -Eq '(^|[[:space:]])(find|sort)([[:space:]]|$)' <<<"$sampler_body"; then
  fail runtime_sampler_recursive_scan
fi
grep -Fq 'time.monotonic_ns()' <<<"$sampler_body" || fail monotonic_deadline_missing
grep -Fq 'os.statvfs' <<<"$sampler_body" || fail statvfs_missing

if grep -En '^[[:space:]]*(sudo[[:space:]]+)?(rm[[:space:]]+-r|losetup|mkfs|wipefs|reboot|shutdown|poweroff|halt|systemctl|pkill|killall|fuser[[:space:]]+-k)' "$RUN"; then
  fail forbidden_mutation
fi
if grep -En '^[[:space:]]*(sudo[[:space:]]+)?umount[[:space:]]+(-f|--force|-l|--lazy)' "$RUN"; then
  fail forbidden_unmount
fi
if grep -Ein '(password|passwd|api[_-]?token)[[:space:]]*=' "$RUN" "$ANA"; then
  fail embedded_secret
fi

# The unchanged parser already passed against the authoritative 04-tmp2i RUN.
test -r /mnt/c/SunRise/test/04-tmp2i/20260906-201646/final/gpt-independent-analysis.json \
  || fail historical_positive_fixture_missing
python3 - /mnt/c/SunRise/test/04-tmp2i/20260906-201646/final/gpt-independent-analysis.json <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get('RUN_VALIDITY_STATE') == 'VALID'
assert len(d.get('cells', [])) == 5
PY

sha256sum "$RUN" "$ANA" "$BASE" "$0" "$SCRUB" >"$OUT/scripts.sha256"
printf '04TMP2J_GATE0_OFFLINE_PASS\troot=%s\n' "$OUT"
