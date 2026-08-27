#!/usr/bin/env bash
# Pure offline Gate 0 for 03-20B-R2.  No SSH, curl, mount, Ceph or fio is run.
set -euo pipefail
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MAIN="$SCRIPT_DIR/t61-tikv-resource-closure-r2.sh"
HELPER="$SCRIPT_DIR/t61-remote-resource-sampler.sh"
LOCAL_SAMPLER="$SCRIPT_DIR/t61-local-sampler.sh"
VALIDATOR="$SCRIPT_DIR/t61-validate-evidence.py"
TASK="$SCRIPT_DIR/../../../doc/perf-tasks/03-20B-R2-tikv-shared-nvme-final-closure.md"

for file in "$MAIN" "$HELPER" "$LOCAL_SAMPLER" "$VALIDATOR" "$TASK"; do
  [[ -f "$file" ]] || { echo "Gate0 FAIL: missing $file" >&2; exit 1; }
done

bash -n "$MAIN" "$HELPER" "$LOCAL_SAMPLER" "$0"
python3 - "$VALIDATOR" <<'PY'
import ast
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(), filename=str(path))
PY

bash "$HELPER" --self-test
bash "$LOCAL_SAMPLER" --self-test
set +e
timeout 2 bash "$HELPER" host "$$" > /tmp/t61-gate0-host.tsv 2> /tmp/t61-gate0-host.stderr
host_rc=$?
set -e
[[ "$host_rc" -eq 124 ]]
[[ ! -s /tmp/t61-gate0-host.stderr ]]
awk -F '\t' 'NF!=20{exit 1} {for(i=2;i<=NF;i++) if($i !~ /^-?[0-9]+([.][0-9]+)?$/) exit 1} END{if(NR<1)exit 1}' /tmp/t61-gate0-host.tsv
python3 "$VALIDATOR" --self-test
[[ "$(bash "$MAIN" --describe)" == *'one frozen B256 arm'* ]]

set +e
env -u T61_SKILL_ACK -u T61_USER_AUTH bash "$MAIN" 20991231-235959 \
  > /tmp/t61-gate0-refusal.stdout 2> /tmp/t61-gate0-refusal.stderr
refusal_rc=$?
set -e
[[ "$refusal_rc" -eq 2 ]]
grep -q 'REFUSE: T61_SKILL_ACK' /tmp/t61-gate0-refusal.stderr

# Static safety and regression invariants.
! grep -Eq '(^|[^[:alnum:]_])(pkill|killall|fuser)([^[:alnum:]_]|$)' "$MAIN" "$HELPER" "$LOCAL_SAMPLER"
! grep -Eq 'umount[[:space:]]+-(l|f|lf|fl)' "$MAIN" "$HELPER" "$LOCAL_SAMPLER"
! grep -Eq 'kill[^\n]*(MOUNT_PID|juicefs-03-8)' "$MAIN"
! grep -Eq 'wait[[:space:]]+"?\$FIO_PID"?[^\n]*\|\|[[:space:]]*true' "$MAIN"
grep -q 'wait "$FIO_PID"' "$MAIN"
grep -q 'FIO_RC=$?' "$MAIN"
grep -q '03-20B-R2-ATTEMPT-' "$MAIN"
grep -q 'prior_attempts=' "$MAIN"
grep -q 'start <= ts < end' "$VALIDATOR"
grep -q 'setdefault(ts' "$VALIDATOR"
grep -q 'minimum_metrics = math.ceil' "$VALIDATOR"
grep -q 'fields\[11\] = "-1"' "$VALIDATOR"
grep -q 'md5sum -c MANIFEST.md5' "$MAIN"
grep -q 'files_stable' "$MAIN"
grep -q 'kill "-\$signal" -- "-\$pgid"' "$MAIN"
grep -q 'mount_kill=0' "$MAIN"
grep -q 'auto_retry=0' "$MAIN"

# Ensure the active Raft Engine and RocksDB WAL paths are selected from /config.
grep -q 'data.get("raft-engine"' "$VALIDATOR"
grep -q 'data.get("rocksdb"' "$VALIDATOR"
grep -q 'findmnt -rn -T' "$MAIN"
grep -q 'lsblk -s -nrpo NAME,TYPE' "$MAIN"

rm -f /tmp/t61-gate0-refusal.stdout /tmp/t61-gate0-refusal.stderr /tmp/t61-gate0-host.tsv /tmp/t61-gate0-host.stderr
echo '03-20B-R2 Gate 0 offline tests: PASS'
