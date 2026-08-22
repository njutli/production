#!/usr/bin/env bash
# Pure offline regression checks for the 03-15 Gate 0 changes.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"

SHELL_FILES=(
  scripts/FULLBASELINE/debug/t39-segB.sh
  scripts/FULLBASELINE/debug/t42-segD.sh
  scripts/FULLBASELINE/debug/t43-f42.sh
  scripts/FULLBASELINE/debug/t44-night-morning.sh
  scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh
  scripts/FULLBASELINE/probe/instrument.sh
  scripts/FULLBASELINE/probe/env-snapshot.sh
)
bash -n "${SHELL_FILES[@]}"
python3 - <<'PY'
import ast
import pathlib
for name in (
    "scripts/FULLBASELINE/analyze/latency-budget.py",
    "scripts/FULLBASELINE/analyze/goroutine-stack-count.py",
):
    ast.parse(pathlib.Path(name).read_text(), filename=name)
PY

# t46 must refuse before checking files or issuing any state-changing command.
set +e
env -u ACK_SUDO_WRITES bash scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh \
  > /tmp/t46-offline-refusal.out 2>&1
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -q 'REFUSE.*ACK_SUDO_WRITES=YES' /tmp/t46-offline-refusal.out

# Static invariants behind the repaired conclusions.
grep -q 'export SKIP_REMOUNT=1' scripts/FULLBASELINE/debug/t39-segB.sh
grep -q 'want_pid=.*want_starttime' scripts/FULLBASELINE/debug/t39-segB.sh
! grep -q 'B[123]=.*mount_and_run' scripts/FULLBASELINE/debug/t43-f42.sh
grep -q 'read_bw_result.*B1' scripts/FULLBASELINE/debug/t43-f42.sh
grep -q 'capture_full_metrics.*tag-pre' scripts/FULLBASELINE/debug/t42-segD.sh
grep -q 'validate_tikv_snapshot' scripts/FULLBASELINE/debug/t42-segD.sh
! grep -qE 'curl .*\|[[:space:]]*head|head -[0-9]+.*metrics' scripts/FULLBASELINE/debug/t42-segD.sh
! grep -qE -- '--rw=(randwrite|randrw)' scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh
grep -q 'juicefs_meta_ops_durations_histogram_seconds_' scripts/FULLBASELINE/debug/t44-night-morning.sh
grep -q 'juicefs_fuse_read_size_bytes_sum' scripts/FULLBASELINE/debug/t44-night-morning.sh
grep -q 'f\[12\].*f\[13\]' scripts/FULLBASELINE/probe/instrument.sh

python3 - <<'PY'
import importlib.util
import math
import pathlib
import tempfile

repo = pathlib.Path.cwd()

spec = importlib.util.spec_from_file_location(
    "latency_budget", repo / "scripts/FULLBASELINE/analyze/latency-budget.py"
)
lb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lb)

with tempfile.TemporaryDirectory() as td:
    root = pathlib.Path(td)
    for label, item, direction in (("W", "randwrite", "WRITE"), ("R", "randread", "READ")):
        d = root / label / f"{item}-{label}-r1"
        d.mkdir(parents=True)
        (d / "fio.txt").write_text(
            f"  {direction}: bw=100MiB/s (105MB/s), io=1GiB (1GB), run=180000-180000msec\n"
        )
        (d / "jfs-stats-pre.txt").write_text(
            "juicefs_fuse_ops_total_read 0\n"
            "juicefs_object_request_durations_histogram_seconds_GET_total 0\n"
        )
        (d / "jfs-stats-post.txt").write_text(
            "juicefs_fuse_ops_total_read 2\n"
            "juicefs_object_request_durations_histogram_seconds_GET_total 10\n"
        )
    rows = lb.collect(str(root), [], None)
    by_item = {row["item"]: row for row in rows}
    assert math.isnan(by_item["randwrite"]["get_per_io"])
    assert by_item["randread"]["get_per_io"] == 5.0

spec = importlib.util.spec_from_file_location(
    "gstack", repo / "scripts/FULLBASELINE/analyze/goroutine-stack-count.py"
)
gs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gs)
sample = (
    "goroutine 1 [select]:\nfoo.(*fileReader).waitForIO()\nfoo.(*dataReader).Read()\n\n"
    "goroutine 2 [syscall]:\ngithub.com/ceph/go-ceph/rados._Cfunc_rados_read()\n\n"
)
blocks = gs.split_blocks(sample)
assert len(blocks) == 2
assert sum(gs.PATTERNS["file_wait"] in b for b in blocks) == 1
assert sum(gs.PATTERNS["rados_read"] in b for b in blocks) == 1
PY

echo "stage03 Gate 0 offline tests: PASS"
