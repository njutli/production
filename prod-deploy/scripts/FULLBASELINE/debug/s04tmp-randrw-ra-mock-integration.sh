#!/usr/bin/env bash
# Fully offline integration for 04-tmp. Never invokes ssh/sudo/ceph/juicefs/fio.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
DRIVER="$SCRIPT_DIR/s04tmp-randrw-ra-driver.sh"
ANALYZER="$SCRIPT_DIR/s04tmp-randrw-ra-analyze.py"
OUT=${S04TMP_MOCK_OUT:-$(mktemp -d /tmp/s04tmp-mock.XXXXXX)}
FIXTURE="$OUT/inventory-fixture"
mkdir -p "$FIXTURE" "$OUT/analysis-fixture"

python3 - "$FIXTURE" <<'PY'
import json,sys
from pathlib import Path
r=Path(sys.argv[1])
with (r/'assets.tsv').open('w') as f:
 f.write('name\tsize\tinode\tmtime\n')
 for i in range(128): f.write(f'rw_test.{i}.0\t1073741824\t{10000+i}\t1.0\n')
(r/'volume-status.json').write_text(json.dumps({'Setting':{'UUID':'fixture-uuid','Name':'juicefs-prod'}}))
(r/'ceph-fsid.txt').write_text('fixture-fsid\n')
PY

make_ack() {
  local run=$1
  local root="/tmp/production/opencode-04-tmp-randrw-ra-$run"
  printf 'path\tsha256\tread_epoch\tidentity\n' >"$root/methodology-ack.tsv"
  for rel in skills/EVIDENCE-INTEGRITY-SKILL.md skills/fixtures/known-defect-classes.tsv \
    skills/TUNING-SKILL.md skills/TESTING-GUIDE.md skills/test-commands-reference.md \
    skills/LONG-RUNNING-TEST-SKILL.md skills/SYSTEM-SAFETY-SKILL.md \
    skills/baseline-reproduction-skill.md doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md; do
    printf '%s\t%s\t%s\tmock-gate0\n' "$rel" "$(sha256sum "$ROOT/$rel" | awk '{print $1}')" "$(date +%s)" >>"$root/methodology-ack.tsv"
  done
}

suffix=$(date +%N); RUN="20990201-${suffix:0:6}"
DRY_RUN_ONLY=1 S04TMP_MOCK=1 bash "$DRIVER" init "$RUN"
make_ack "$RUN"
DRY_RUN_ONLY=1 S04TMP_MOCK=1 S04TMP_FIXTURE_DIR="$FIXTURE" bash "$DRIVER" phase-i "$RUN"
DRY_RUN_ONLY=1 S04TMP_MOCK=1 bash "$DRIVER" phase-ii-plan "$RUN"
DRY_RUN_ONLY=1 S04TMP_MOCK=1 bash "$DRIVER" phase-ii-execute "$RUN"
ROOT_RUN="/tmp/production/opencode-04-tmp-randrw-ra-$RUN"
[[ $(find "$ROOT_RUN/warmup" -name CELL_PASS -type f | wc -l) -eq 4 ]]
[[ $(find "$ROOT_RUN/formal" -name CELL_PASS -type f | wc -l) -eq 8 ]]
[[ ! -e $ROOT_RUN/analysis/matrix.json ]]
if DRY_RUN_ONLY=1 S04TMP_MOCK=1 bash "$DRIVER" phase-ii-execute "$RUN" >/dev/null 2>&1; then
  echo 'duplicate execute unexpectedly passed' >&2; exit 42
fi

# Generate eight complete mixed-direction per-job archives for independent analysis.
python3 - "$OUT/analysis-fixture" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); arms=['A','B','B','A','B','A','A','B']; seeds=[41001,41001,41002,41002,41003,41003,41004,41004]
read=[1800,1900,1892,1808,1905,1795,1802,1898]; write=[1810,1902,1890,1800,1900,1805,1798,1904]
for idx,(arm,seed,rr,ww) in enumerate(zip(arms,seeds,read,write),1):
 label=f'R{idx:02d}'; d=root/label; (d/'bw').mkdir(parents=True)
 (d/'fio-start-ns.txt').write_text('1000000000000\n'); (d/'fio-end-ns.txt').write_text('1181000000000\n')
 (d/'fio.txt').write_text('READ: bw=1800MiB/s\nWRITE: bw=1800MiB/s\n run=180000-180000msec\n')
 for job in range(1,129):
  with (d/'bw'/f'rw_test_bw.{job}.log').open('w') as f:
   for sec in range(1,261):
    rv=rr*1024/128; wv=ww*1024/128
    if sec>=190: rv*=.7; wv*=1.2
    f.write(f'{sec*1000+137}, {rv}, 0, 0\n')
    f.write(f'{sec*1000+251}, {wv}, 1, 0\n')
 (d/'contract.tsv').write_text(f'label\t{label}\narm\t{arm}\nseed\t{seed}\n')
PY
for i in $(seq 1 8); do
  printf -v label 'R%02d' "$i"; arm=(A B B A B A A B); seeds=(41001 41001 41002 41002 41003 41003 41004 41004)
  python3 "$ANALYZER" round --round-dir "$OUT/analysis-fixture/$label" --label "$label" \
    --arm "${arm[i-1]}" --randseed "${seeds[i-1]}" --output "$OUT/analysis-fixture/$label.json" >/dev/null
done
python3 "$ANALYZER" matrix --inputs "$OUT"/analysis-fixture/R0{1,2,3,4,5,6,7,8}.json \
  --output "$OUT/analysis-fixture/matrix.json" >"$OUT/analysis-fixture/matrix.console"
grep -Fxq 'VERDICT=RW_RA0_DUAL_DIRECTION_BENEFIT_CONFIRMED' "$OUT/analysis-fixture/matrix.console"

printf 'S04TMP_MOCK_INTEGRATION_PASS\trun=%s\tout=%s\n' "$RUN" "$OUT"
