#!/usr/bin/env bash
# Offline Gate 0 for 04-tmp2. It must not contact or mutate the test environment.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN="$SELF_DIR/t04tmp2-cache-run.sh"
CLEANUP="$SELF_DIR/t04tmp2-cache-cleanup.sh"
ANALYZE="$SELF_DIR/t04tmp2-cache-analyze.py"
SCRUB="$SELF_DIR/u141d-scrub-control.sh"
GATE="$SELF_DIR/t04tmp2-cache-gate0-offline.sh"
RUN_ID=${TMP2_GATE_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}
OUT=${TMP2_GATE0_OUT:-/tmp/t04tmp2-gate0-$RUN_ID}
FIXTURE_ROOT="/tmp/production/opencode-04tmp2-$RUN_ID"
FILES=("$RUN" "$CLEANUP" "$ANALYZE" "$GATE")
RUNTIME_FILES=("$RUN" "$CLEANUP" "$ANALYZE")

fail() { printf 'GATE_FAIL\t%s\n' "$*" >&2; exit 42; }
pass() { printf 'GATE_PASS\t%s\n' "$*"; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || fail "invalid Gate RUN_ID"
[[ $OUT == /tmp/t04tmp2-gate0-* && ! -e $OUT && ! -L $OUT ]] || fail "Gate output exists/outside scope: $OUT"
[[ ! -e $FIXTURE_ROOT ]] || fail "fixture result root already exists: $FIXTURE_ROOT"
mkdir -m 0700 "$OUT"

for file in "${FILES[@]}"; do
  [[ -f $file && ! -L $file ]] || fail "missing/symlink file: $file"
done

bash -n "$RUN"; bash -u -n "$RUN"; bash -n "$CLEANUP"; bash -u -n "$CLEANUP"
python3 -m py_compile "$ANALYZE"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$RUN" "$CLEANUP" "$GATE" >"$OUT/shellcheck.txt"
else
  printf 'SKIPPED shellcheck unavailable\n' >"$OUT/shellcheck.txt"
fi
for file in "${FILES[@]}"; do
  if awk '/[ \t]+$/{print FNR ":" $0; bad=1} END{exit bad}' "$file" >"$OUT/$(basename "$file").whitespace"; then :; else
    fail "trailing whitespace: $file"
  fi
done
pass static-syntax-whitespace

if rg -n 'rm[[:space:]]+-r(f|[[:space:]])|pkill|killall|fusermount[[:space:]]+-uz|umount[[:space:]]+-l|losetup[[:space:]]+-D|reboot|shutdown|poweroff|halt' \
  "${RUNTIME_FILES[@]}" >"$OUT/forbidden-static.txt"; then
  fail "forbidden destructive/process/reboot command found"
fi
if rg -n 'sudo[[:space:]]+(rm|chown|chmod|systemctl|mount|umount|dd|wipefs|lvremove|lvcreate)' \
  "${RUNTIME_FILES[@]}" >"$OUT/sudo-write-static.txt"; then
  fail "unplanned sudo write command found"
fi
if rg -n '(Sunrise@|sshpass[[:space:]]+-p|SSHPASS=)' "${RUNTIME_FILES[@]}" >"$OUT/secret-static.txt"; then
  fail "possible plaintext credential found"
fi
pass static-safety-secret

KNOWN_DEFECTS="$SELF_DIR/../../../skills/fixtures/known-defect-classes.tsv"
[[ -f $KNOWN_DEFECTS ]] || fail "known defect catalog missing"
python3 - "$KNOWN_DEFECTS" "$OUT/known-defects-coverage.tsv" <<'PY'
import csv,sys
source,out=sys.argv[1:]
covered={
 'D01':'actual_t0=end-runtime and timing sensitivity fixture',
 'D02':'interval-overlap weighted bw-log fixture',
 'D03':'formal [15,175) is the only screen measurement',
 'D04':'all proc candidates plus parent-child worker selection',
 'D05':'unreadable proc cannot produce the required unique worker',
 'D06':'bash -u -n and local declarations reviewed',
 'D16':'exact sampler PID is waited before evidence closes',
 'D17':'fio/sampler nonzero rc preserved by explicit if/wait',
 'D19':'cell directory must not pre-exist and labels are frozen',
 'D21':'cache capacity and unique RUN directory pre-gates',
 'D22':'sampler lifetime ends from explicit fio-completion stop file',
 'D25':'plaintext credential static scan',
 'D26':'destructive/process/reboot static scan',
 'D27':'script SHA manifest freezes before environment mutation',
 'D28':'append-only incidents ledger',
 'D30':'mount parent-child PID and Setting.UUID schema validation',
}
rows=list(csv.DictReader(open(source),delimiter='\t'))
if len(rows)!=32: raise SystemExit(f'expected 32 catalog rows, got {len(rows)}')
with open(out,'w',newline='') as f:
 w=csv.writer(f,delimiter='\t'); w.writerow(('id','disposition','reason'))
 for row in rows:
  did=row['id']; reason=covered.get(did,'not reachable in read-only cache L1 path')
  w.writerow((did,'COVERED' if did in covered else 'NOT_APPLICABLE',reason))
PY
[[ $(awk -F'\t' 'NR>1{n++} END{print n+0}' "$OUT/known-defects-coverage.tsv") -eq 32 ]] \
  || fail "known defect classification incomplete"
pass known-defect-scope-classification

grep -Fq -- '--read-only --prefetch 0 --max-fuse-io 256K --max-uploads 150' "$RUN" || fail "common mount contract missing"
grep -Fq -- '--cache-size 0' "$RUN" || fail "A cache contract missing"
grep -Fq -- '--cache-size 65536 --cache-dir' "$RUN" || fail "B cache contract missing"
grep -Fq -- 'fio --readonly' "$RUN" || fail "fio global readonly missing"
! grep -Eq 'cmd\+?=\([^\n]*--max-readahead|mount[[:space:]].*--max-readahead' "$RUN" \
  || fail "runner changes max-readahead"
! grep -Eq 'readonly=1|^readonly=' "$RUN" || fail "invalid fio readonly job option present"
grep -Fq 'run_cell R01-A A 41001' "$RUN" || fail "R01 contract missing"
grep -Fq 'run_cell R02-B B 41001' "$RUN" || fail "R02 pair seed mismatch"
grep -Fq 'run_cell R03-B B 41002' "$RUN" || fail "R03 contract missing"
grep -Fq 'run_cell R04-A A 41002' "$RUN" || fail "R04 pair seed mismatch"
grep -Fq 'sha256sum -c "$STATE/scripts.sha256"' "$RUN" || fail "frozen script verification missing"
grep -Fq '>>"$ROOT/incidents.tsv"' "$RUN" || fail "append-only incident ledger missing"
grep -Fq "required=('UUID','Name','Storage','Bucket','BlockSize')" "$RUN" || fail "volume Setting schema gate missing"
grep -Fq 'find "$CACHE_PARENT" -mindepth 1 -maxdepth 1' "$RUN" \
  || fail "cache inventory must not descend into ext4 lost+found"
! grep -Fq 'find "$CACHE_PARENT" -mindepth 1 -maxdepth 2' "$RUN" \
  || fail "cache inventory still descends into ext4 lost+found"
grep -Fq 'cache_origin=PRECREATED_EMPTY' "$RUN" \
  || fail "runner cannot adopt an exact empty precreated cache directory"
grep -Fq 'precreated cache root owner mismatch' "$RUN" \
  || fail "precreated cache root owner gate missing"
grep -Fq 'precreated cache root mode mismatch' "$RUN" \
  || fail "precreated cache root mode gate missing"
grep -Fq 'precreated cache root is not empty' "$RUN" \
  || fail "precreated cache root emptiness gate missing"
grep -Fq 'mount-pids-pre.txt' "$RUN" \
  || fail "launch-scoped mount PID baseline missing"
grep -Fq 'pid in pre or exe!=expected' "$RUN" \
  || fail "launch-scoped mount PID filter missing"
grep -Fq 'selected worker CEPH_CONF mismatch' "$RUN" \
  || fail "mount worker CEPH_CONF gate missing"
grep -Fq 'mount source/volume mismatch' "$RUN" \
  || fail "mount source/Setting.Name gate missing"
pass frozen-mount-fio-abba

TMP2_RESULT_ROOT="$FIXTURE_ROOT" bash "$RUN" offline-self-test "$RUN_ID" >"$OUT/run-self-test.txt"
FORMAL="$FIXTURE_ROOT/offline-self-test/formal.fio"
WARMUP="$FIXTURE_ROOT/offline-self-test/warmup.fio"
[[ $(grep -c '^\[read_test_[0-9][0-9][0-9]\]$' "$FORMAL") -eq 128 ]] || fail "formal job count"
[[ $(grep -c '^filename=' "$FORMAL") -eq 128 ]] || fail "formal filename count"
[[ $(grep -c '^filename=' "$WARMUP") -eq 128 ]] || fail "warmup filename count"
grep -Fqx 'rw=randread' "$FORMAL"; grep -Fqx 'runtime=180' "$FORMAL"
grep -Fqx 'rw=read' "$WARMUP"; grep -Fqx 'size=256M' "$WARMUP"
! grep -Eq '^(filesize|readonly)=' "$FORMAL" || fail "formal contains forbidden option"
! grep -Eq '^(filesize|readonly)=' "$WARMUP" || fail "warmup contains forbidden option"
pass jobfile-fixture

python3 "$ANALYZE" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" \
  >"$OUT/analyzer-self-test.stdout"
grep -Fq '"verdict": "CACHE_SCREEN_MATERIAL_SIGNAL"' "$OUT/analyzer-self-test.json" \
  || fail "analyzer positive fixture verdict"

NEG="$OUT/analyzer-negative/bw"; mkdir -p "$NEG"
python3 - "$NEG" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for job in range(1,128):
    (root/f'read_test_bw.{job}.log').write_text('1000,1024,0,0\n')
PY
set +e
python3 - "$ANALYZE" "$OUT/analyzer-negative" >"$OUT/analyzer-negative.stdout" 2>"$OUT/analyzer-negative.stderr" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('a',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try: m.aggregate_logs(m.Path(sys.argv[2])/'bw')
except m.EvidenceError: raise SystemExit(42)
raise SystemExit(0)
PY
negative_rc=$?
set -e
(( negative_rc == 42 )) || fail "analyzer accepted 127 logs"
pass analyzer-positive-negative-fixtures

CACHE_FIXTURE="$OUT/cache-parent"
mkdir -p "$CACHE_FIXTURE"
TMP2_FIXTURE=1 TMP2_CACHE_PARENT="$CACHE_FIXTURE" TMP2_RESULT_ROOT="$FIXTURE_ROOT" \
  bash "$CLEANUP" offline-self-test "$RUN_ID" >"$OUT/cleanup-self-test.txt"
: >"$FIXTURE_ROOT/MATRIX_PERSISTENCE_PASS"
TMP2_DRY_RUN_ONLY=0 TMP2_ACK="I_ACK_TMP2_CACHE_DESTROY_$RUN_ID" TMP2_CACHE_PARENT="$CACHE_FIXTURE" \
  TMP2_RESULT_ROOT="$FIXTURE_ROOT" bash "$CLEANUP" destroy "$RUN_ID" >"$OUT/cleanup-destroy-fixture.txt"
[[ -f $FIXTURE_ROOT/CACHE_DESTROYED_PASS && ! -e $CACHE_FIXTURE/jfs-04tmp2-$RUN_ID ]] \
  || fail "cleanup fixture did not close"
pass cleanup-inspect-plan-destroy-fixture

bash "$SCRUB" --self-test >"$OUT/scrub-control-self-test.txt"
grep -Fq 'U141D_SCRUB_CONTROL_SELFTEST: PASS' "$OUT/scrub-control-self-test.txt" \
  || fail "reused scrub controller self-test"
pass reused-scrub-controller

sha256sum "${FILES[@]}" "$SCRUB" >"$OUT/scripts.sha256"
printf 'RUN_ID\t%s\nGATE_STATUS\tPASS\nFIXTURE_ROOT\t%s\nOUTPUT_ROOT\t%s\n' \
  "$RUN_ID" "$FIXTURE_ROOT" "$OUT" >"$OUT/gate-summary.tsv"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) >"$OUT/SHA256SUMS"
printf 'TMP2_GATE0_OFFLINE_PASS run_id=%s output=%s\n' "$RUN_ID" "$OUT"
