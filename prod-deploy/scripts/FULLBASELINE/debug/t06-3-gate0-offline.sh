#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# Local fixture/replay only. No remote inventory, workload or state changes.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN_ID=${1:-}
OUT=${2:-}
PROFILE=${3:-legacy-six-cell}
[[ $PROFILE == legacy-six-cell || $PROFILE == burst-abba ]] || { printf 'T063_GATE0_FAIL\tinvalid_profile\n' >&2; exit 2; }
DRIVER=$SCRIPT_DIR/t06-3-randrw-cache-driver.sh
ANALYZER=$SCRIPT_DIR/t06-3-randrw-analyze.py
LEGACY_DRIVER=$SCRIPT_DIR/t06-1-randrw-cache-driver.sh
LEGACY_ANALYZER=$SCRIPT_DIR/t06-1-randrw-analyze.py
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
HISTORY=/mnt/c/SunRise/test/06-1/20260915-204941/phase-a-raw/06-1-raw.tar.gz

die() { printf 'T063_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
[[ $OUT == /mnt/c/SunRise/test/06-3/"$RUN_ID"/offline && ! -e $OUT && ! -L $OUT ]] || die output_must_be_new_persistent_RUN_offline
[[ $(realpath -m "$OUT") == "$OUT" ]] || die output_symlink_or_traversal
inputs=("$0" "$DRIVER" "$ANALYZER" "$LEGACY_DRIVER" "$LEGACY_ANALYZER" "$SCRUB")
for file in "${inputs[@]}"; do [[ -s $file && ! -L $file ]] || die "missing_input:$file"; done
[[ -s $HISTORY && ! -L $HISTORY ]] || die historical_archive_missing
mkdir -m 0700 -p "$OUT"
printf 'Offline Gate only; remote_calls=0; environment_authorized=no\n' >"$OUT/scope.txt"
printf 'bash %q %q %q %q\n' "$0" "$RUN_ID" "$OUT" "$PROFILE" >"$OUT/commands.sh"

for file in "$0" "$DRIVER" "$LEGACY_DRIVER" "$SCRUB"; do bash -n "$file"; bash -u -n "$file"; done
python3 - "$ANALYZER" "$LEGACY_ANALYZER" <<'PY'
import ast, pathlib, sys
for name in sys.argv[1:]:
    ast.parse(pathlib.Path(name).read_text(), filename=name)
print('PYTHON_SYNTAX_PASS')
PY
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$0" "$DRIVER" >"$OUT/shellcheck.txt" || die shellcheck
else
  printf 'NOT_INSTALLED; bash syntax and executable fixtures used\n' >"$OUT/shellcheck.txt"
fi

secret_pattern='sshpass[[:space:]]+'
secret_pattern+='-p[[:space:]]|PASS'
secret_pattern+='WORD=[^$[:space:]]|Turbo'
secret_pattern+='Ai@'
if grep -nE "$secret_pattern" "${inputs[@]}" >"$OUT/secret-scan.txt"; then die plaintext_secret; fi
destructive_pattern='rm[[:space:]]+-'
destructive_pattern+='rf|fusermount[[:space:]]+-uz|umount[[:space:]]+-l|losetup[[:space:]]+-D|pk'
destructive_pattern+='ill|killall|fuser[[:space:]]+-k|sudo[[:space:]]+(reboot|shutdown|poweroff|wipefs)'
if grep -nE "$destructive_pattern" "$DRIVER" "$LEGACY_DRIVER" "$SCRUB" >"$OUT/unsafe-scan.txt"; then die unsafe_operation; fi
# List sudo call sites, never execute them. The existing scrub component is
# separately authorized at the later online approval boundary.
grep -nE 'sudo[[:space:]]' "$DRIVER" "$LEGACY_DRIVER" "$SCRUB" >"$OUT/sudo-review.txt" || true

# PATH tripwires prove fixtures do not use the live executables. A tripwire
# writes a marker and fails even if a caller mistakenly swallows its rc.
mkdir -m 0700 "$OUT/deny-bin"
python3 - "$OUT" <<'PY'
from pathlib import Path
import shlex, sys
root = Path(sys.argv[1])
names = ('ssh', 'scp', 'rsync', 'sudo', 'fio', 'ceph', 'rados', 'juicefs',
         'mount', 'umount', 'fusermount', 'curl', 'wget')
for name in names:
    p = root / 'deny-bin' / name
    p.write_text('#!/bin/bash\nprintf "%s\\n" ' + shlex.quote(name) +
                 ' >> ' + shlex.quote(str(root / 'FORBIDDEN_CALLS')) + '\nexit 97\n')
    p.chmod(0o700)
PY
export PATH="$OUT/deny-bin:$PATH"
export TMPDIR="$OUT"
driver_test=--self-test; driver_plan=plan; driver_phase=phase
if [[ $PROFILE == burst-abba ]]; then driver_test=burst-self-test; driver_plan=burst-plan; driver_phase=burst-phase; fi
bash "$DRIVER" "$driver_test" "$RUN_ID" >"$OUT/driver-self-test.txt" 2>&1 || die driver_self_test
grep -q 'T063_DRIVER_SELF_TEST_PASS' "$OUT/driver-self-test.txt" || die driver_self_test_marker
T063_PLAN_OUT="$OUT/plan" bash "$DRIVER" "$driver_plan" "$RUN_ID" >"$OUT/plan.stdout" 2>"$OUT/plan.stderr" || die driver_plan
python3 - "$ANALYZER" "$OUT/plan/gate0" "$PROFILE" >"$OUT/plan-analyzer-contract.txt" <<'PY'
import csv, pathlib, runpy, sys
analysis = runpy.run_path(sys.argv[1])
analysis['configure_profile'](sys.argv[3])
root = pathlib.Path(sys.argv[2])
def job(path):
    return dict(line.strip().split('=', 1) for line in path.read_text().splitlines()
                if '=' in line and not line.lstrip().startswith('#'))
formal = job(root/'formal/fio.job')
for key, value in analysis['WORKLOAD'].items():
    assert formal.get(key, '').lower() == value, (key, formal.get(key), value)
assert formal['filename_format'] == '<PRIVATE_MOUNT>/test_dir/rw_test.$jobnum.0'
warm = job(root/'warmup/fio.job')
assert warm['rw'] == 'randread' and warm['runtime'] == '60'
rows = list(csv.DictReader((root/'mainline-matrix.tsv').open(), delimiter='\t'))
expected_cells = ("A1", "B1", "B2", "A2") if sys.argv[3] == "burst-abba" else ("C1", "S1", "W1", "W2", "S2", "C2")
assert tuple(row['cell'] for row in rows) == expected_cells
print('GENERATED_PLAN_ANALYZER_CONTRACT_PASS')
PY
set +e
env -u T063_EXECUTE_ACK bash "$DRIVER" "$driver_phase" "$RUN_ID" >"$OUT/no-ack.stdout" 2>"$OUT/no-ack.stderr"
no_ack_rc=$?
set -e
[[ $no_ack_rc -eq 42 ]] || die missing_ack_not_rejected
grep -q 'execute_ack_missing' "$OUT/no-ack.stderr" || die missing_ack_wrong_reason
set +e
bash "$DRIVER" phase-a "$RUN_ID" >"$OUT/legacy-entry.stdout" 2>"$OUT/legacy-entry.stderr"
legacy_rc=$?
set -e
[[ $legacy_rc -ne 0 ]] || die legacy_GC_entry_exposed
python3 "$ANALYZER" self-test --profile "$PROFILE" >"$OUT/analyzer-self-test.json" || die analyzer_self_test
python3 - "$OUT/analyzer-self-test.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['status'] == 'PASS'
PY
python3 "$ANALYZER" replay-archive --archive "$HISTORY" --output "$OUT/history-replay.json" --table "$OUT/history-replay.tsv" >"$OUT/history-replay.stdout" 2>"$OUT/history-replay.stderr" || die historical_replay
[[ ! -e $OUT/FORBIDDEN_CALLS ]] || die fixture_called_live_command

# Independent primary-endpoint recomputation reads four members directly,
# without extracting the old RUN or trusting its historical analyzer result.
python3 - "$HISTORY" "$OUT" <<'PY'
import hashlib, json, math, pathlib, statistics, sys, tarfile
archive, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
digest = hashlib.sha256()
with archive.open('rb') as source:
    for block in iter(lambda: source.read(1024 * 1024), b''):
        digest.update(block)
sha = digest.hexdigest()
assert sha == 'ce8ec6c203d4bae4d8bf39cea38d1af64d7e67fe2a9001d6fa8b2af47383357c'
expected = {'C1': (1804.716316, 1808.101975), 'T1': (2157.687192, 2161.697057),
            'T2': (2080.462626, 2083.520242), 'C2': (1676.884347, 1680.624484)}
rows = []
with tarfile.open(archive, 'r:gz') as tf:
    for cell, values in expected.items():
        name = f'opencode-06-1-20260915-204941/cells/{cell}/formal/fio.json'
        data = json.load(tf.extractfile(name))
        assert len(data['jobs']) == 1
        j = data['jobs'][0]
        assert j['error'] == 0
        t = max(j[d]['runtime'] for d in ('read', 'write')) / 1000
        b = [j[d]['io_bytes'] / t / 2**20 for d in ('read', 'write')]
        assert all(math.isclose(x, y, abs_tol=0.00001) for x, y in zip(b, values))
        rows.append({'cell': cell, 'seconds': t, 'read_MiB_s': b[0], 'write_MiB_s': b[1],
                     'read_bytes': j['read']['io_bytes'], 'write_bytes': j['write']['io_bytes']})
effects = {d: (statistics.mean(r[d] for r in rows if r['cell'].startswith('T')) /
               statistics.mean(r[d] for r in rows if r['cell'].startswith('C')) - 1) * 100
           for d in ('read_MiB_s', 'write_MiB_s')}
replay = json.loads((out/'history-replay.json').read_text())
assert replay['replay_check'] == 'PASS' and replay['original_06_1_verdict_modified'] is False
computed = {row['cell']: row['primary'] for row in replay['cells']}
assert set(computed) == set(expected)
for row in rows:
    primary = computed[row['cell']]
    assert math.isclose(primary['runtime_s'], row['seconds'], abs_tol=1e-9)
    for direction in ('read', 'write'):
        assert primary['directional'][direction]['io_bytes'] == row[direction + '_bytes']
        assert math.isclose(primary['directional'][direction]['MiB_s'], row[direction + '_MiB_s'], abs_tol=1e-8)
(out/'independent-history.json').write_text(json.dumps({'sha256': sha, 'cells': rows,
    'ratio_of_arm_means_pct': effects, 'status': 'RETROSPECTIVE_NOT_NEW_RUN_RESULT'}, indent=2)+'\n')
print('INDEPENDENT_HISTORY_PASS', effects)
PY

# Coverage is scoped to the changed contract, not a claim to have rerun every
# unrelated legacy fixture. Specific executable assertions remain in self-tests.
python3 - "$OUT" "$PROFILE" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
profile = sys.argv[2]
rows = [
 ('D01/D02', 'timing/log integration', 'analyzer-self-test.json; history-replay.json'),
 ('D03', 'EXPLICIT_OVERRIDE: full runtime primary; old window diagnostic only', '06-3 taskbook section 2.1'),
 ('D06/D17', 'shell syntax; explicit mock timeout/entry rejection', 'driver-self-test.txt; bash -n/-u -n'),
 ('D21/D22', 'mock recovery reset, three-zero drain, reject undrained cleanup and occupancy ceiling; live guards NOT EXECUTED', 'driver-self-test.txt'),
 ('CAPACITY_RAW', 'synthetic low-space/low-memory/over-ceiling evidence rejected; actual host budget NOT INVENTORIED', 'analyzer-self-test.json'),
 ('D25/D26', 'secret/unsafe-operation scanning', 'secret-scan.txt; unsafe-scan.txt; sudo-review.txt'),
 ('D27/D28', 'frozen dependencies and fail-closed entry', 'no-ack.stderr; scripts.sha256'),
 ('FIO_GROUP_RUNTIME', 'single group; no cumulative job_runtime divisor', 'analyzer-self-test.json; independent-history.json'),
 ('BURST_UNKNOWN_ZERO', 'do not erase stalls or zero-fill unknown logs', 'analyzer-self-test.json'),
 ('MATRIX', 'A/B original-package ABBA' if profile == 'burst-abba' else 'CLW and WB independent six-cell order', 'driver-self-test.txt; plan/'),
 ('NO_ENVIRONMENT', 'PATH tripwire + no live calls in offline modes', 'absence of FORBIDDEN_CALLS'),
]
(out/'coverage.tsv').write_text('class\tscope\tevidence\n' + ''.join('\t'.join(r)+'\n' for r in rows))
(out/'lifecycle.tsv').write_text('scope\tremote_status\tlocal_status\tpurge\tnext_checkpoint\n'
    'OFFLINE_ONLY\tNONE\tPRESERVED\tNO_PURGE_REQUIRED\tonline-plan-review\n')
(out/'gate-result.json').write_text('{"status":"PASS","scope":"OFFLINE_ONLY",'
    f'"profile":"{profile}","remote_calls":0,"formal_load":"NOT_AUTHORIZED"}}\n')
PY

python3 - "$OUT" "${inputs[@]}" <<'PY'
import hashlib, pathlib, sys
out = pathlib.Path(sys.argv[1]); copies = out/'scripts'; copies.mkdir()
entries = []
for name in sys.argv[2:]:
    p = pathlib.Path(name); data = p.read_bytes()
    (copies/p.name).write_bytes(data)
    entries.append(f'{hashlib.sha256(data).hexdigest()}  scripts/{p.name}\n')
(out/'scripts.sha256').write_text(''.join(entries))
PY
(
  cd -- "$OUT"
  sha256sum -c scripts.sha256 >scripts-verify.txt
  find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >manifest.sha256
  sha256sum -c manifest.sha256 >/dev/null
)
printf 'T063_GATE0_OFFLINE_PASS\troot=%s\tprofile=%s\tremote_calls=0\tformal_load=NOT_AUTHORIZED\n' "$OUT" "$PROFILE"
