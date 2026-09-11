#!/usr/bin/env bash
set -euo pipefail

JFS=/tmp/juicefs-1.4.1-patched
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/jfsportal-dirstats-20260911
VOLUME=jfsportal-dirstats-20260911
ROOT=/dev/shm/jfsportal-dirstats-20260911
BUCKET=/dev/shm/jfsportal-dirstats-20260911-objects
MNT=/dev/shm/jfsportal-dirstats-20260911/mnt
RESULT=/dev/shm/jfsportal-dirstats-20260911/results
DATA=/dev/shm/jfsportal-dirstats-20260911/mnt/DIRTEST
LOG=/dev/shm/jfsportal-dirstats-20260911/juicefs.log
METRICS=127.0.0.1:19567
EXPECTED_FILES=10000
EXPECTED_DIRS=1111
MIN_ROOT_FREE=$((15 * 1024 * 1024 * 1024))
MAX_LOCAL_BYTES=$((64 * 1024 * 1024))

die() { printf 'E_T09_PHASE_B\t%s\n' "$*" >&2; exit 1; }

[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || die wrong_host
[[ -x "$JFS" ]] || die juicefs_binary_missing
[[ ! -e "$ROOT" && ! -e "$BUCKET" ]] || die test_path_already_exists
[[ $(stat -f -c %T /dev/shm) == tmpfs ]] || die dev_shm_not_tmpfs
[[ $(df -B1 --output=avail / | tail -1) -ge $MIN_ROOT_FREE ]] || die root_free_below_15GiB
if ss -ltnH "sport = :19567" | grep -q .; then die metrics_port_occupied; fi
if "$JFS" status "$META" >/dev/null 2>&1; then die temporary_meta_already_formatted; fi

prod_mount_before=$(findmnt -rn /mnt/juicefs)
prod_pids_before=$(pgrep -f '/tmp/juicefs-1.4.1-patched mount .* /mnt/juicefs$' | sort -n | paste -sd, -)
[[ -n "$prod_mount_before" && -n "$prod_pids_before" ]] || die business_mount_fingerprint_missing

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

capture_node_fingerprints() {
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
  } >"$RESULT/metrics-$label.tsv"
}

verify_business() {
  [[ $(findmnt -rn /mnt/juicefs) == "$prod_mount_before" ]] || die business_mount_changed
  [[ $(pgrep -f '/tmp/juicefs-1.4.1-patched mount .* /mnt/juicefs$' | sort -n | paste -sd, -) == "$prod_pids_before" ]] || die business_pids_changed
  [[ $(df -B1 --output=avail / | tail -1) -ge $MIN_ROOT_FREE ]] || die root_free_below_15GiB
}

local_bytes() {
  du -sb "$ROOT" "$BUCKET" 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

run_timed() {
  local label=$1 run=$2
  shift 2
  /usr/bin/time -f "$label\t$run\t%e\t%U\t%S\t%M\t%x" \
    -o "$RESULT/timings.tsv" -a "$@" \
    >"$RESULT/$label.$run.out" 2>"$RESULT/$label.$run.err"
}

mkdir -m 0700 -p "$ROOT" "$BUCKET" "$MNT" "$RESULT"
printf 'method\trun\telapsed_s\tuser_s\tsystem_s\tmax_rss_kib\texit\n' >"$RESULT/timings.tsv"
verify_global
capture_node_fingerprints before
capture_metrics before

"$JFS" format \
  --storage file \
  --bucket "$BUCKET" \
  --block-size 256 \
  --trash-days 0 \
  "$META" "$VOLUME" >"$RESULT/format.out" 2>"$RESULT/format.err"

"$JFS" config "$META" >"$RESULT/config.json" 2>"$RESULT/config.err"
grep -Fq '"Name": "jfsportal-dirstats-20260911"' "$RESULT/config.json" || die volume_name_mismatch
grep -Fq '"Storage": "file"' "$RESULT/config.json" || die storage_not_file
grep -Fq '"TrashDays": 0' "$RESULT/config.json" || die trash_days_not_zero
grep -Fq '"DirStats": true' "$RESULT/config.json" || die dirstats_not_true

"$JFS" mount -d \
  --cache-size 0 \
  --backup-meta 0 \
  --no-bgjob \
  --metrics "$METRICS" \
  --log "$LOG" \
  "$META" "$MNT" >"$RESULT/mount.out" 2>"$RESULT/mount.err"

for _ in $(seq 1 30); do
  findmnt -rn "$MNT" >/dev/null 2>&1 && break
  sleep 1
done
findmnt -rn "$MNT" >"$RESULT/test-findmnt.txt"
grep -Fq "JuiceFS:$VOLUME" "$RESULT/test-findmnt.txt" || die test_mount_source_mismatch
curl -fsS --max-time 5 "http://$METRICS/metrics" >/dev/null || die test_metrics_unavailable

"$JFS" status "$META" >"$RESULT/status.json" 2>"$RESULT/status.err"
python3 - "$RESULT/status.json" "$RESULT/state.tsv" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
setting = data["Setting"]
assert setting["Name"] == "jfsportal-dirstats-20260911"
uuid = setting["UUID"]
assert len(uuid) == 36
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("key\tvalue\n")
    out.write(f"volume\t{setting['Name']}\n")
    out.write(f"uuid\t{uuid}\n")
    out.write("meta_suffix\tjfsportal-dirstats-20260911\n")
    out.write("phase\tB-10k\n")
PY

python3 - "$DATA" "$ROOT" "$BUCKET" "$LOG" "$MIN_ROOT_FREE" "$MAX_LOCAL_BYTES" <<'PY'
import os, sys, time

data, root, bucket, log = sys.argv[1:5]
min_root_free, max_local = map(int, sys.argv[5:7])
rate = 500.0
ops = 0
started = time.monotonic()

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

def pace():
    global ops
    ops += 1
    target = started + ops / rate
    delay = target - time.monotonic()
    if delay > 0:
        time.sleep(delay)
    if ops % 1000 == 0:
        guard()

os.mkdir(data, 0o700)
pace()
for i in range(10):
    l1 = os.path.join(data, f"L1-{i:02d}")
    os.mkdir(l1, 0o700); pace()
    for j in range(10):
        l2 = os.path.join(l1, f"L2-{j:02d}")
        os.mkdir(l2, 0o700); pace()
        for k in range(10):
            leaf = os.path.join(l2, f"L3-{k:02d}")
            os.mkdir(leaf, 0o700); pace()
            for n in range(10):
                path = os.path.join(leaf, f"f-{n:04d}")
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(fd)
                pace()
guard()
elapsed = time.monotonic() - started
print(f"LAYOUT_PASS ops={ops} files=10000 dirs=1111 elapsed_s={elapsed:.3f} rate={ops/elapsed:.3f}")
PY

sleep 30
for attempt in $(seq 1 12); do
  "$JFS" info -r "$DATA" >"$RESULT/convergence-$attempt.out" 2>"$RESULT/convergence-$attempt.err"
  if grep -Eq 'files:[[:space:]]+10000$' "$RESULT/convergence-$attempt.out" && \
     grep -Eq 'dirs:[[:space:]]+1111$' "$RESULT/convergence-$attempt.out"; then
    printf 'CONVERGENCE_PASS\tattempt=%s\n' "$attempt" >"$RESULT/convergence.txt"
    break
  fi
  sleep 10
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
  grep -Eq 'files:[[:space:]]+10000$' "$file" || die "file_count_mismatch:$file"
  grep -Eq 'dirs:[[:space:]]+1111$' "$file" || die "dir_count_mismatch:$file"
done

[[ $(local_bytes) -le $MAX_LOCAL_BYTES ]] || die local_object_or_log_limit_exceeded
verify_business
verify_global
capture_node_fingerprints after
capture_metrics after
cmp -s "$RESULT/nodes-before.tsv" "$RESULT/nodes-after.tsv" || die node_fingerprint_changed

printf '%s\n' "$prod_mount_before" >"$RESULT/business-findmnt.txt"
printf '%s\n' "$prod_pids_before" >"$RESULT/business-pids.txt"
printf 'T09_DIRSTATS_PHASE_B_PASS files=%s dirs=%s result=%s test_mount_retained=true\n' \
  "$EXPECTED_FILES" "$EXPECTED_DIRS" "$RESULT"
