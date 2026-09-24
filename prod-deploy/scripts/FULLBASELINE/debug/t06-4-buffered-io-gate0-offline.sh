#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

# 06-4 Gate 0 is local-only. It never invokes SSH, sudo, fio, ceph, JuiceFS,
# mount or umount. Environment authorization is a later, separate boundary.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER=$SCRIPT_DIR/t06-4-buffered-io-driver.sh
ANALYZER=$SCRIPT_DIR/t06-4-buffered-io-analyze.py
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
RUN_ID=${1:-}
OUT=${2:-}
die() { printf 'T064_GATE0_FAIL\t%s\n' "$*" >&2; exit 2; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
[[ $OUT == /mnt/c/SunRise/test/06-4/"$RUN_ID"/offline && ! -e $OUT && ! -L $OUT ]] || die output_must_be_new_persistent_RUN_offline
mkdir -m 0700 -p "$OUT"
printf 'offline_only=1\nremote_calls=0\nenvironment_authorized=no\n' >"$OUT/scope.txt"
printf 'bash %q %q %q\n' "$0" "$RUN_ID" "$OUT" >"$OUT/commands.sh"

for f in "$0" "$DRIVER" "$SCRUB"; do
  [[ -s $f && ! -L $f ]] || die "missing:$f"
  bash -n "$f"
  bash -u -n "$f"
done
python3 - "$ANALYZER" <<'PY' || die python_syntax
import ast,sys
ast.parse(open(sys.argv[1]).read(),filename=sys.argv[1])
PY
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$0" "$DRIVER" >"$OUT/shellcheck.txt" || die shellcheck
else
  printf 'NOT_INSTALLED\n' >"$OUT/shellcheck.txt"
fi

inputs=("$0" "$DRIVER" "$ANALYZER" "$SCRUB")
if grep -nE 'sshpass|PASSWORD=|PASSWD=|password[[:space:]]*=' "$DRIVER" "$ANALYZER" "$SCRUB" >"$OUT/secret-scan.txt"; then die plaintext_secret; fi
if grep -nE 'rm[[:space:]]+-rf|umount[[:space:]]+-l|fusermount[[:space:]]+-uz|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|sudo[[:space:]]+(reboot|shutdown|poweroff|wipefs)' "$DRIVER" >"$OUT/unsafe-scan.txt"; then die unsafe_operation; fi
grep -nE 'sudo[[:space:]]' "$DRIVER" "$SCRUB" >"$OUT/sudo-review.txt" || true

mkdir -m 0700 "$OUT/deny-bin"
for name in ssh scp rsync sudo fio ceph rados juicefs mount umount fusermount curl wget; do
  printf '#!/bin/sh\nprintf "forbidden:%s\\n" >> %q\nexit 97\n' "$name" "$OUT/FORBIDDEN_CALLS" >"$OUT/deny-bin/$name"
  chmod 0700 "$OUT/deny-bin/$name"
done
export PATH="$OUT/deny-bin:$PATH" TMPDIR="$OUT"

bash "$DRIVER" --self-test "$RUN_ID" >"$OUT/driver-self-test.txt" 2>&1 || die driver_self_test
grep -q T064_DRIVER_SELF_TEST_PASS "$OUT/driver-self-test.txt" || die driver_self_test_marker
python3 "$ANALYZER" self-test >"$OUT/analyzer-self-test.json" || die analyzer_self_test
grep -q '"status": "PASS"' "$OUT/analyzer-self-test.json" || die analyzer_self_test_marker
[[ ! -e $OUT/FORBIDDEN_CALLS ]] || die offline_called_live_tool

PLAN="$OUT/plan"
T064_PLAN_OUT="$PLAN" bash "$DRIVER" plan "$RUN_ID" >"$OUT/plan.stdout" 2>"$OUT/plan.stderr" || die plan_generation
[[ -f $PLAN/gate0/mainline-matrix.tsv && -f $PLAN/gate0/D1/formal/fio.job && -f $PLAN/gate0/B1/formal/fio.job && -f $PLAN/gate0/warmup/fio.job ]] || die plan_artifacts
[[ $(awk 'NR>1{print $2}' "$PLAN/gate0/mainline-matrix.tsv" | paste -sd, -) == D1,B1,B2,D2 ]] || die matrix_contract
grep -Fxq 'direct=0' "$PLAN/gate0/warmup/fio.job" || die warmup_buffered_contract
grep -Fxq 'invalidate=0' "$PLAN/gate0/warmup/fio.job" || die warmup_invalidate_contract
grep -Fxq 'direct=1' "$PLAN/gate0/D1/formal/fio.job" || die direct_formal_contract
grep -Fxq 'direct=0' "$PLAN/gate0/B1/formal/fio.job" || die buffered_formal_contract
grep -Fq 'targeted_fsync "$cell" "$mnt"' "$DRIVER" || die targeted_fsync_missing

python3 - "$OUT" <<'PY'
from pathlib import Path
import hashlib, sys
out=Path(sys.argv[1])
(out/'coverage.tsv').write_text('class\tscope\tevidence\n'
 'NO_REMOTE\tno SSH/sudo/live tools\tPATH tripwire and scope.txt\n'
 'MATRIX\tD1,B1,B2,D2\tplan/gate0/mainline-matrix.tsv\n'
 'MODEL\tdirect=1 versus direct=0; cache-size=0\tself-test and generated fio jobs\n'
 'ANALYSIS\tbytes/max directional runtime; one group\tanalyzer-self-test.json\n'
 'SAFETY\tno broad deletion/forced unmount/reboot\tunsafe-scan.txt\n')
(out/'lifecycle.tsv').write_text('scope\tremote_status\tlocal_status\n' 'persistent_offline\tNONE\tPRESERVED\n')
(out/'gate-result.json').write_text('{"status":"PASS","schema":"06-4-buffered-io-v1","remote_calls":0,"formal_load":"NOT_AUTHORIZED"}\n')
entries=[]
for p in sorted(out.rglob('*')):
 if p.is_file() and p.name!='manifest.sha256': entries.append(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(out)}\n')
(out/'manifest.sha256').write_text(''.join(entries))
PY
printf 'T064_GATE0_OFFLINE_PASS\troot=%s\tremote_calls=0\tformal_load=NOT_AUTHORIZED\n' "$OUT"
