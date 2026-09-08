#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
RUN=$DIR/t04tmp2i-randrw-run.sh
ANA=$DIR/t04tmp2i-randrw-analyze.py
OLD=$DIR/t04tmp2h-randrw-run.sh
SCRUB=$DIR/u141d-scrub-control.sh
OUT=${TMP2I_GATE_OUT:-/tmp/t04tmp2i-gate0-$$}
fail() { printf '04TMP2I_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }

[[ ! -e $OUT ]] || fail output_exists
mkdir -m 0700 "$OUT"
for file in "$RUN" "$ANA" "$OLD" "$SCRUB"; do [[ -r $file ]] || fail "missing:$file"; done
bash -n "$RUN"
bash -n "$SCRUB"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANA"

for symbol in cell_spec mount_pid_gate run_fio runtime_sampler drain_writeback \
  prepare_cache cleanup_cache initialize_seed state_return validate_p25_sampling \
  p25_supplement_decision resume_postfio bundle_run; do
  grep -Eq "^${symbol}[[:space:]]*\(\)" "$RUN" || fail "runner_function_missing:$symbol"
done
for token in 'A0-pre' 'T128-P25' 'T128-R' 'T128-W' 'A0-post' \
  'T128-P50' 'T128-P75' 'rw=$mode' 'rwmixread=50' 'bs=256K' \
  'ioengine=libaio' 'iodepth=128' 'direct=1' 'runtime=180' 'numjobs=128' \
  '--max-fuse-io 256K' '--max-uploads 150' '--free-space-ratio 0.20' '--writeback'; do
  grep -Fq -- "$token" "$RUN" || fail "contract_missing:$token"
done

# The old runner is a negative fixture; only the formal sampler body is checked.
old_sampler=$(sed -n '/^runtime_sampler()/,/^}/p' "$OLD")
new_sampler=$(sed -n '/^runtime_sampler()/,/^}/p' "$RUN")
grep -Fq 'find "$CACHE_DIR"' <<<"$old_sampler" || fail old_negative_fixture_missing
if grep -Eq '(^|[[:space:]])(find|sort)([[:space:]]|$)' <<<"$new_sampler"; then
  fail repaired_sampler_still_recursive
fi
grep -Fq 'time.monotonic_ns()' <<<"$new_sampler" || fail monotonic_deadline_missing
grep -Fq 'os.statvfs' <<<"$new_sampler" || fail statvfs_missing
grep -Fq 'sampler-resource.tsv' "$RUN" || fail sampler_resource_evidence_missing
grep -Fq 'len(selected) < 150' "$ANA" || fail sampler_150_of_160_gate_missing
grep -Fq '2.5e9' "$ANA" || fail sampler_gap_gate_missing
if grep -Fq 'a0_mount_gate' "$RUN"; then
  fail obsolete_absolute_nsb_gate_present
fi

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
python3 "$ANA" self-test --root "$OUT/fixture" --output "$OUT/analyzer-self-test.json" >"$OUT/analyzer-self-test.txt"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail analyzer_self_test

cat >"$OUT/summary-add.tsv" <<'EOF'
cell	read_mib_s	write_mib_s	mean_direction_mib_s
A0-pre	100	100	100
T128-P25	101	101	101
EOF
cat >"$OUT/summary-skip.tsv" <<'EOF'
cell	read_mib_s	write_mib_s	mean_direction_mib_s
A0-pre	100	100	100
T128-P25	94	110	102
EOF
python3 - "$OUT/summary-add.tsv" "$OUT/summary-skip.tsv" <<'PY'
import csv,sys
def decide(path):
    r={x['cell']:tuple(float(x[k]) for k in ('read_mib_s','write_mib_s','mean_direction_mib_s'))
       for x in csv.DictReader(open(path),delimiter='\t')}
    a,p=r['A0-pre'],r['T128-P25']; e=[p[i]/a[i]-1 for i in range(3)]
    return 'ADD' if e[2] >= 0 and e[0] > -.05 and e[1] > -.05 else 'SKIP'
assert decide(sys.argv[1]) == 'ADD'
assert decide(sys.argv[2]) == 'SKIP'
PY

sha256sum "$RUN" "$ANA" "$0" "$OLD" "$SCRUB" >"$OUT/scripts.sha256"
printf '04TMP2I_GATE0_OFFLINE_PASS\troot=%s\n' "$OUT"
