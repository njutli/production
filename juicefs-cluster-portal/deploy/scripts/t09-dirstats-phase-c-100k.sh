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
RESULT=/dev/shm/jfsportal-dirstats-20260911/phase-c-results
MIN_ROOT_FREE=$((15 * 1024 * 1024 * 1024))
MAX_LOCAL_BYTES=$((64 * 1024 * 1024))
EXPECTED_FILES=100000
EXPECTED_DIRS=1111
EXPECTED_SIZE=414150656

die() { printf 'E_T09_PHASE_C\t%s\n' "$*" >&2; exit 1; }

[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || die wrong_host
[[ -x "$JFS" ]] || die juicefs_binary_missing
[[ -d "$DATA" && -d "$CASE" ]] || die retained_test_tree_missing
[[ ! -e "$RESULT" ]] || die phase_c_result_already_exists
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
  for path in "$BUCKET" "$ROOT/results" "$ROOT/correctness-results" "$RESULT" "$LOG"; do
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

capture_nodes() {
  local label=$1 node
  : >"$RESULT/nodes-$label.tsv"
  for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$node" '
      printf "%s\t" "$(hostname -s)"
      printf "%s\t%s\t" "$(pgrep -xo pd-server)" "$(pgrep -xo tikv-server)"
      printf "%s\t%s\n" "$(findmnt -rn /mnt/jfs-tikv)" "$(findmnt -rn /mnt/dbwal | head -1)"
    ' >>"$RESULT/nodes-$label.tsv"
  done
}

capture_metrics() {
  local label=$1
  {
    printf 'label\t%s\n' "$label"
    printf 'epoch\t%s\n' "$(date +%s)"
    printf 'targets_up\t%s\n' "$(prom_value 'sum(up)')"
    printf 'ceph_health\t%s\n' "$(prom_value 'ceph_health_status')"
    printf 'pg_clean\t%s\n' "$(prom_value 'max(ceph_pg_clean)')"
    printf 'pg_total\t%s\n' "$(prom_value 'max(ceph_pg_total)')"
    printf 'pool_objects\t%s\n' "$(prom_value 'max(ceph_pool_objects{pool_id="3"})')"
    printf 'pool_stored_bytes\t%s\n' "$(prom_value 'max(ceph_pool_stored{pool_id="3"})')"
    printf 'tikv_pending_compaction_bytes\t%s\n' "$(prom_value 'sum(tikv_engine_pending_compaction_bytes)')"
    printf 'tikv_cpu_cores_1m\t%s\n' "$(prom_value 'sum(rate(process_cpu_seconds_total{job="tikv"}[1m]))')"
    printf 'business_fuse_ops_1m\t%s\n' "$(prom_value 'sum(rate(juicefs_fuse_ops_total[1m]))')"
    printf 'business_read_Bps_1m\t%s\n' "$(prom_value 'sum(rate(juicefs_fuse_read_size_bytes_sum[1m]))')"
    printf 'business_write_Bps_1m\t%s\n' "$(prom_value 'sum(rate(juicefs_fuse_written_size_bytes_sum[1m]))')"
    printf 'root_free_bytes\t%s\n' "$(df -B1 --output=avail / | tail -1)"
    printf 'shm_used_bytes\t%s\n' "$(df -B1 --output=used /dev/shm | tail -1)"
    printf 'temporary_local_bytes\t%s\n' "$(local_bytes)"
  } >"$RESULT/metrics-$label.tsv"
}

run_timed() {
  local label=$1 run=$2
  shift 2
  /usr/bin/time -f "$label\t$run\t%e\t%U\t%S\t%M\t%x" \
    -o "$RESULT/timings.tsv" -a "$@" \
    >"$RESULT/$label.$run.out" 2>"$RESULT/$label.$run.err"
}

mkdir -m 0700 "$RESULT"
printf 'method\trun\telapsed_s\tuser_s\tsystem_s\tmax_rss_kib\texit\n' >"$RESULT/timings.tsv"
verify_global
verify_capacity
capture_nodes before
cmp -s "$RESULT/nodes-before.tsv" "$ROOT/results/nodes-after.tsv" || die node_fingerprint_changed_since_phase_b
capture_metrics before

"$JFS" info -r "$DATA" >"$RESULT/info-before.out" 2>"$RESULT/info-before.err"
grep -Eq 'files:[[:space:]]+10000$' "$RESULT/info-before.out" || die phase_b_file_count_not_10000
grep -Eq 'dirs:[[:space:]]+1111$' "$RESULT/info-before.out" || die phase_b_dir_count_not_1111
cmp -s "$RESULT/info-before.out" "$ROOT/correctness-results/dirtest-after.out" || die phase_b_tree_changed_since_b2

python3 - "$DATA" "$BUCKET" "$LOG" "$MIN_ROOT_FREE" "$MAX_LOCAL_BYTES" <<'PY'
import os, re, sys, time

data, bucket, log = sys.argv[1:4]
min_root_free, max_local = map(int, sys.argv[4:6])
expected = "/dev/shm/jfsportal-dirstats-20260911/mnt/DIRTEST"
if data != expected:
    raise SystemExit("fixed data path mismatch")

leaves = []
for i in range(10):
    for j in range(10):
        for k in range(10):
            leaf = os.path.join(data, f"L1-{i:02d}", f"L2-{j:02d}", f"L3-{k:02d}")
            names = sorted(os.listdir(leaf))
            if names != [f"f-{n:04d}" for n in range(10)]:
                raise SystemExit(f"unexpected phase-B leaf contents: {leaf}")
            leaves.append(leaf)

def path_bytes(path):
    total = 0
    if not os.path.exists(path):
        return 0
    for base, dirs, files in os.walk(path):
        total += os.lstat(base).st_size
        for name in files:
            total += os.lstat(os.path.join(base, name)).st_size
    return total

def guard():
    st = os.statvfs("/")
    if st.f_bavail * st.f_frsize < min_root_free:
        raise RuntimeError("root free space below 15 GiB")
    used = path_bytes(bucket)
    if os.path.exists(log):
        used += os.lstat(log).st_size
    if used > max_local:
        raise RuntimeError(f"unexpected object/log bytes: {used}")

rate = 500.0
ops = 0
started = time.monotonic()
for leaf in leaves:
    for n in range(10, 100):
        path = os.path.join(leaf, f"f-{n:04d}")
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        ops += 1
        target = started + ops / rate
        delay = target - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        if ops % 1000 == 0:
            guard()

guard()
elapsed = time.monotonic() - started
print(f"LAYOUT_C_PASS new_files={ops} total_files=100000 elapsed_s={elapsed:.3f} rate={ops/elapsed:.3f}")
PY

for attempt in $(seq 1 12); do
  "$JFS" info -r "$DATA" >"$RESULT/convergence-$attempt.out" 2>"$RESULT/convergence-$attempt.err"
  if grep -Eq 'files:[[:space:]]+100000$' "$RESULT/convergence-$attempt.out" && \
     grep -Eq 'dirs:[[:space:]]+1111$' "$RESULT/convergence-$attempt.out"; then
    printf 'CONVERGENCE_PASS\tattempt=%s\n' "$attempt" >"$RESULT/convergence.txt"
    break
  fi
  sleep 5
done
[[ -s "$RESULT/convergence.txt" ]] || die dirstats_did_not_converge

for run in first r1 r2 r3; do
  run_timed info-fast "$run" "$JFS" info -r "$DATA"
  run_timed info-strict "$run" "$JFS" info -r --strict "$DATA"
  run_timed summary-fast "$run" "$JFS" summary --depth 3 --entries 10 --csv "$DATA"
  run_timed summary-strict "$run" "$JFS" summary --depth 3 --entries 10 --strict --csv "$DATA"
  run_timed du-total "$run" du -s --block-size=1 "$DATA"
  run_timed du-depth3 "$run" du --max-depth=3 --block-size=1 "$DATA"
done

for file in "$RESULT"/info-fast.*.out "$RESULT"/info-strict.*.out; do
  grep -Eq 'files:[[:space:]]+100000$' "$file" || die "file_count_mismatch:$file"
  grep -Eq 'dirs:[[:space:]]+1111$' "$file" || die "dir_count_mismatch:$file"
  grep -Eq 'length:[[:space:]]+0 Bytes$' "$file" || die "length_mismatch:$file"
  grep -Fq "($EXPECTED_SIZE Bytes)" "$file" || die "size_mismatch:$file"
done

for run in first r1 r2 r3; do
  { head -1 "$RESULT/summary-fast.$run.out"; tail -n +2 "$RESULT/summary-fast.$run.out" | sort; } >"$RESULT/summary-fast.$run.sorted"
  { head -1 "$RESULT/summary-strict.$run.out"; tail -n +2 "$RESULT/summary-strict.$run.out" | sort; } >"$RESULT/summary-strict.$run.sorted"
  cmp -s "$RESULT/summary-fast.$run.sorted" "$RESULT/summary-strict.$run.sorted" || die "summary_fast_strict_mismatch:$run"
done

verify_capacity
verify_global
capture_nodes after
cmp -s "$RESULT/nodes-before.tsv" "$RESULT/nodes-after.tsv" || die node_fingerprint_changed
capture_metrics after
[[ $(findmnt -rn /mnt/juicefs) == "$prod_mount_before" ]] || die business_mount_changed_after
[[ $(pgrep -f '/tmp/juicefs-1.4.1-patched mount .* /mnt/juicefs$' | sort -n | paste -sd, -) == "$prod_pids_before" ]] || die business_pids_changed_after

printf 'T09_DIRSTATS_PHASE_C_PASS files=%s dirs=%s result=%s test_mount_retained=true\n' \
  "$EXPECTED_FILES" "$EXPECTED_DIRS" "$RESULT"
