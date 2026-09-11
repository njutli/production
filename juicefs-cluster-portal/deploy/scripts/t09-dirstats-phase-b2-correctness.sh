#!/usr/bin/env bash
set -euo pipefail

JFS=/tmp/juicefs-1.4.1-patched
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/jfsportal-dirstats-20260911
VOLUME=jfsportal-dirstats-20260911
UUID=80a2a0da-d98a-4b47-a97a-2da488c4d1ba
ROOT=/dev/shm/jfsportal-dirstats-20260911
MNT=/dev/shm/jfsportal-dirstats-20260911/mnt
DATA=/dev/shm/jfsportal-dirstats-20260911/mnt/DIRTEST
CASE=/dev/shm/jfsportal-dirstats-20260911/mnt/CORRECTNESS
BUCKET=/dev/shm/jfsportal-dirstats-20260911-objects
LOG=/dev/shm/jfsportal-dirstats-20260911/juicefs.log
RESULT=/dev/shm/jfsportal-dirstats-20260911/correctness-results
MIN_ROOT_FREE=$((15 * 1024 * 1024 * 1024))
MAX_LOCAL_BYTES=$((64 * 1024 * 1024))

die() { printf 'E_T09_PHASE_B2\t%s\n' "$*" >&2; exit 1; }

[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || die wrong_host
[[ -x "$JFS" ]] || die juicefs_binary_missing
[[ ! -e "$CASE" && ! -e "$RESULT" ]] || die correctness_path_already_exists
findmnt -rn "$MNT" | grep -Fq "JuiceFS:$VOLUME" || die test_mount_missing
[[ $(df -B1 --output=avail / | tail -1) -ge $MIN_ROOT_FREE ]] || die root_free_below_15GiB

status_uuid=$("$JFS" status "$META" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Setting"]["UUID"])')
[[ "$status_uuid" == "$UUID" ]] || die temporary_uuid_mismatch

prod_mount_before=$(cat "$ROOT/results/business-findmnt.txt")
prod_pids_before=$(cat "$ROOT/results/business-pids.txt")
[[ $(findmnt -rn /mnt/juicefs) == "$prod_mount_before" ]] || die business_mount_changed_before
[[ $(pgrep -f '/tmp/juicefs-1.4.1-patched mount .* /mnt/juicefs$' | sort -n | paste -sd, -) == "$prod_pids_before" ]] || die business_pids_changed_before

prom_value() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 10.20.1.152 \
    "curl -fsSG --data-urlencode 'query=$1' http://127.0.0.1:9090/api/v1/query" |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "EMPTY")'
}

verify_global() {
  [[ $(prom_value 'sum(up)') == 14 ]] || die prometheus_targets_not_14
  [[ $(prom_value 'ceph_health_status') == 0 ]] || die ceph_not_healthy
  [[ $(prom_value 'sum(ceph_osd_up)') == 6 ]] || die ceph_osd_up_not_6
  [[ $(prom_value 'sum(ceph_osd_in)') == 6 ]] || die ceph_osd_in_not_6
  [[ $(prom_value 'max(ceph_pg_clean)-max(ceph_pg_total)') == 0 ]] || die ceph_pg_not_all_clean
}

local_bytes() {
  local path bytes total=0
  # Do not du $ROOT: it contains the live FUSE mount and would recursively
  # traverse the 10k-file test tree.  Count only local backing/log/evidence.
  for path in "$BUCKET" "$ROOT/results" "$RESULT" "$LOG"; do
    [[ -e "$path" ]] || continue
    bytes=$(du -sb -- "$path" 2>/dev/null | awk 'NR == 1 {print $1}')
    [[ $bytes =~ ^[0-9]+$ ]] || die "cannot_measure_local_bytes:$path"
    total=$((total + bytes))
  done
  printf '%s\n' "$total"
}

verify_capacity() {
  [[ $(df -B1 --output=avail / | tail -1) -ge $MIN_ROOT_FREE ]] || die root_free_below_15GiB
  [[ $(local_bytes) -le $MAX_LOCAL_BYTES ]] || die temporary_local_bytes_above_64MiB
}

capture_metrics() {
  local label=$1
  {
    printf 'label\t%s\n' "$label"
    printf 'epoch\t%s\n' "$(date +%s)"
    printf 'targets_up\t%s\n' "$(prom_value 'sum(up)')"
    printf 'ceph_health\t%s\n' "$(prom_value 'ceph_health_status')"
    printf 'pool_objects\t%s\n' "$(prom_value 'max(ceph_pool_objects{pool_id="3"})')"
    printf 'pool_stored_bytes\t%s\n' "$(prom_value 'max(ceph_pool_stored{pool_id="3"})')"
    printf 'tikv_pending_compaction_bytes\t%s\n' "$(prom_value 'sum(tikv_engine_pending_compaction_bytes)')"
    printf 'tikv_cpu_cores_1m\t%s\n' "$(prom_value 'sum(rate(process_cpu_seconds_total{job="tikv"}[1m]))')"
    printf 'root_free_bytes\t%s\n' "$(df -B1 --output=avail / | tail -1)"
    printf 'temporary_local_bytes\t%s\n' "$(local_bytes)"
  } >"$RESULT/metrics-$label.tsv"
}

apply_step() {
  local step=$1
  python3 - "$CASE" "$step" <<'PY'
import os, sys

root, step = sys.argv[1:3]
expected = "/dev/shm/jfsportal-dirstats-20260911/mnt/CORRECTNESS"
if root != expected:
    raise SystemExit("fixed correctness path mismatch")
left, right = os.path.join(root, "left"), os.path.join(root, "right")

if step == "S0-create":
    os.mkdir(root, 0o700)
    os.mkdir(left, 0o700)
    os.mkdir(right, 0o700)
    for name, size in (("f0", 0), ("f1", 1), ("f4095", 4095),
                       ("f4096", 4096), ("f4097", 4097), ("f1m", 1048576)):
        path = os.path.join(left, name)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        os.truncate(path, size)
elif step == "S1-grow":
    os.truncate(os.path.join(left, "f1"), 16385)
elif step == "S2-shrink":
    os.truncate(os.path.join(left, "f1m"), 8193)
elif step == "S3-rename":
    os.rename(os.path.join(left, "f4097"), os.path.join(right, "f4097"))
elif step == "S4-link":
    os.link(os.path.join(left, "f4096"), os.path.join(right, "f4096-link"))
elif step == "S5-unlink-original":
    os.unlink(os.path.join(left, "f4096"))
elif step == "S6-unlink-zero":
    os.unlink(os.path.join(left, "f0"))
else:
    raise SystemExit(f"unknown step {step}")
PY
}

write_expected() {
  local step=$1
  python3 - "$CASE" "$RESULT/$step.expected.tsv" <<'PY'
import os, stat, sys

root, output = sys.argv[1:3]
paths = [root, os.path.join(root, "left"), os.path.join(root, "right")]

def aligned(n):
    return 4096 if n == 0 else ((n + 4095) // 4096) * 4096

with open(output, "w", encoding="utf-8") as out:
    out.write("path\tfiles\tdirs\tlength\tsize\n")
    for path in paths:
        files = dirs = length = size = 0
        for base, names, filenames in os.walk(path, followlinks=False):
            dirs += 1
            size += 4096
            for name in filenames:
                st = os.lstat(os.path.join(base, name))
                files += 1
                size += aligned(st.st_size)
                if stat.S_ISREG(st.st_mode):
                    length += st.st_size
        out.write(f"{path}\t{files}\t{dirs}\t{length}\t{size}\n")
PY
}

collect_info() {
  local step=$1 mode=$2 path label opts=()
  [[ $mode == strict ]] && opts=(--strict)
  for label in root left right; do
    case $label in
      root) path=$CASE ;;
      left) path=$CASE/left ;;
      right) path=$CASE/right ;;
    esac
    "$JFS" info -r "${opts[@]}" "$path" \
      >"$RESULT/$step.$mode.$label.out" \
      2>"$RESULT/$step.$mode.$label.err"
  done
}

validate_info() {
  local step=$1 mode=$2
  python3 - "$RESULT/$step.expected.tsv" "$RESULT/$step.$mode" <<'PY'
import pathlib, re, sys

expected_file, prefix = sys.argv[1:3]
rows = {}
for line in pathlib.Path(expected_file).read_text().splitlines()[1:]:
    path, files, dirs, length, size = line.split("\t")
    rows[path] = tuple(map(int, (files, dirs, length, size)))

for label, path in (("root", next(iter(rows))), ("left", next(p for p in rows if p.endswith("/left"))),
                    ("right", next(p for p in rows if p.endswith("/right")))):
    text = pathlib.Path(f"{prefix}.{label}.out").read_text()
    def number(field):
        match = re.search(rf"^\s*{field}:\s+.*?\((\d+) Bytes\)\s*$", text, re.M)
        if match:
            return int(match.group(1))
        match = re.search(rf"^\s*{field}:\s+(\d+) Bytes\s*$", text, re.M)
        if not match:
            raise SystemExit(f"cannot parse {field} from {label}")
        return int(match.group(1))
    actual = (
        int(re.search(r"^\s*files:\s+(\d+)\s*$", text, re.M).group(1)),
        int(re.search(r"^\s*dirs:\s+(\d+)\s*$", text, re.M).group(1)),
        number("length"), number("size"),
    )
    if actual != rows[path]:
        raise SystemExit(f"{label}: actual={actual} expected={rows[path]}")
PY
}

mkdir -m 0700 "$RESULT"
printf 'step\tconvergence_attempt\tconvergence_ms\n' >"$RESULT/convergence.tsv"
verify_global
verify_capacity
capture_metrics before
"$JFS" info -r "$DATA" >"$RESULT/dirtest-before.out" 2>"$RESULT/dirtest-before.err"
grep -Eq 'files:[[:space:]]+10000$' "$RESULT/dirtest-before.out" || die original_dirtest_files_changed
grep -Eq 'dirs:[[:space:]]+1111$' "$RESULT/dirtest-before.out" || die original_dirtest_dirs_changed

for step in S0-create S1-grow S2-shrink S3-rename S4-link S5-unlink-original S6-unlink-zero; do
  started_ns=$(date +%s%N)
  apply_step "$step"
  write_expected "$step"
  collect_info "$step" strict
  validate_info "$step" strict || die "strict_or_manifest_mismatch:$step"
  converged=0
  for attempt in $(seq 1 30); do
    collect_info "$step" fast
    if validate_info "$step" fast; then
      ended_ns=$(date +%s%N)
      printf '%s\t%s\t%s\n' "$step" "$attempt" "$(((ended_ns-started_ns)/1000000))" >>"$RESULT/convergence.tsv"
      converged=1
      break
    fi
    sleep 1
  done
  [[ $converged -eq 1 ]] || die "fast_did_not_converge:$step"
  verify_capacity
done

"$JFS" summary --depth 2 --entries 100 --csv "$CASE" >"$RESULT/final-summary-fast.csv" 2>"$RESULT/final-summary-fast.err"
"$JFS" summary --depth 2 --entries 100 --strict --csv "$CASE" >"$RESULT/final-summary-strict.csv" 2>"$RESULT/final-summary-strict.err"
python3 - "$RESULT/final-summary-fast.csv" "$RESULT/final-summary-strict.csv" <<'PY'
import sys
a = open(sys.argv[1], encoding="utf-8").read().splitlines()
b = open(sys.argv[2], encoding="utf-8").read().splitlines()
assert a[0] == b[0]
assert sorted(a[1:]) == sorted(b[1:])
PY

"$JFS" info -r "$DATA" >"$RESULT/dirtest-after.out" 2>"$RESULT/dirtest-after.err"
cmp -s "$RESULT/dirtest-before.out" "$RESULT/dirtest-after.out" || die original_dirtest_result_changed
verify_global
verify_capacity
capture_metrics after
[[ $(findmnt -rn /mnt/juicefs) == "$prod_mount_before" ]] || die business_mount_changed_after
[[ $(pgrep -f '/tmp/juicefs-1.4.1-patched mount .* /mnt/juicefs$' | sort -n | paste -sd, -) == "$prod_pids_before" ]] || die business_pids_changed_after

printf 'T09_DIRSTATS_PHASE_B2_PASS steps=7 result=%s test_mount_retained=true\n' "$RESULT"
