#!/usr/bin/env bash
# Short, bounded QD calibration for the slow 192.168.11 validation cluster.
# It reuses only an explicitly named invalidated LT dataset and never deletes it.
set -euo pipefail
export LC_ALL=C
umask 077
base_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$base_dir/env/cluster-192.168.11.env"

check_cluster() {
    mountpoint -q "$LT_MOUNT_POINT" || { echo 'JuiceFS mount missing' >&2; return 42; }
    "$LT_CEPH_READONLY_WRAPPER" -s -f json | python3 -c '
import json,sys
d=json.load(sys.stdin); o=d.get("osdmap") or {}
raise SystemExit(0 if (d.get("health") or {}).get("status")=="HEALTH_OK" and o.get("num_up_osds")==6 and o.get("num_in_osds")==6 else 1)
    ' || { echo 'Ceph health/OSD gate failed' >&2; return 42; }
}

action=${1:-}
run_id=${2:-}
data_root=${3:-}
[[ "$action" == plan || "$action" == run ]] || { echo 'usage: calibrate-randrw-qd.sh {plan|run} YYYYMMDD-HHMMSS ABS_DATA_ROOT' >&2; exit 42; }
[[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo 'invalid RUN_ID' >&2; exit 42; }
[[ "$data_root" == /mnt/juicefs/reliability-lt-data/*/LT-002/randrw256k && "$data_root" != / && -d "$data_root" && ! -L "$data_root" ]] || {
    echo 'invalid calibration data root' >&2; exit 42;
}

result_root="/data/reliability-lt-results/${run_id}/LT-QD-CALIBRATION"
qd_set=${LT_QD_CALIBRATION_SET:-"1 2 4"}
[[ "$qd_set" =~ ^(1|2|4)([[:space:]]+(1|2|4))*$ ]] || { echo 'invalid QD calibration set' >&2; exit 42; }
[[ "$(realpath -m -- "$result_root")" == "$result_root" && "$result_root" != / ]] || { echo 'invalid result root' >&2; exit 42; }
[[ $(find "$data_root" -maxdepth 1 -type f -name 'lt.*.0' | wc -l) -eq 128 ]] || { echo 'dataset file count mismatch' >&2; exit 42; }
find "$data_root" -maxdepth 1 -type f -name 'lt.*.0' -printf '%s\n' | awk '$1!=1073741824{bad=1} END{exit bad}' || {
    echo 'dataset file size mismatch' >&2; exit 42;
}
command -v fio >/dev/null || { echo 'fio missing' >&2; exit 42; }
command -v python3 >/dev/null || { echo 'python3 missing' >&2; exit 42; }
pgrep -x fio >/dev/null 2>&1 && { echo 'foreign fio present' >&2; exit 42; }
check_cluster

cat <<EOF
QD_CALIBRATION_PLAN
run_id=$run_id
data_root=$data_root
result_root=$result_root
fio=randrw bs:256K jobs:128 qd:${qd_set// /,} runtime:300s_each latency:total(slat+clat)
cleanup=none
EOF
[[ "$action" == plan ]] && exit 0
[[ ${LT_QD_CALIBRATION_ACK:-} == "I_ACK_LT_QD_${run_id}" ]] || { echo 'calibration ACK missing' >&2; exit 42; }
[[ ! -e "$result_root" && ! -L "$result_root" ]] || { echo 'result target exists' >&2; exit 42; }

mkdir -m 0700 -p "$result_root"
printf 'qd\tread_mib_s\twrite_mib_s\tread_p95_us\tread_p99_us\tread_mean_us\tread_max_us\twrite_p95_us\twrite_p99_us\twrite_mean_us\twrite_max_us\terrors\trc\n' >"$result_root/summary.tsv"
"$LT_CEPH_READONLY_WRAPPER" -s -f json >"$result_root/ceph-pre.json"
findmnt -rn -M "$LT_MOUNT_POINT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$result_root/mount-pre.tsv"
for qd in $qd_set; do
    out="$result_root/qd-${qd}"
    mkdir -m 0700 -p "$out"
    check_cluster
    cmd=(timeout --signal=TERM --kill-after=30s 420s fio --directory="$data_root" --name=lt --filename_format='lt.$jobnum.0'
         --filesize=1G --size=1G --numjobs=128 --ioengine=libaio --iodepth="$qd"
         --direct=1 --fallocate=none --group_reporting --allow_file_create=0 --openfiles=128
         --rw=randrw --bs=256K --time_based --runtime=300 --randrepeat=1 --refill_buffers
         --lat_percentiles=1 --percentile_list=95:99
         --verify=crc32c --verify_interval=256K --do_verify=0 --verify_fatal=1
         --output-format=json --output="$out/fio.json")
    printf '%q ' "${cmd[@]}" >>"$result_root/commands.sh"; printf '\n' >>"$result_root/commands.sh"
    date +%s%N >"$out/start-epoch-ns.txt"
    set +e; "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; set -e
    date +%s%N >"$out/end-epoch-ns.txt"; printf '%s\n' "$rc" >"$out/fio.rc"
    python3 - "$qd" "$rc" "$out/fio.json" >>"$result_root/summary.tsv" <<'PY'
import json, sys
qd, rc, path = sys.argv[1:]
d = json.load(open(path))
jobs = d.get("jobs") or []
def total(direction, key):
    return sum(float((j.get(direction) or {}).get(key) or 0) for j in jobs)
def stat(direction, key):
    values=[]
    for j in jobs:
        section=j.get(direction) or {}
        item=section.get("lat_ns") or section.get("lat_us") or {}
        value=item.get(key)
        scale=1/1000 if "lat_ns" in section else 1
        if isinstance(value,(int,float)): values.append(float(value)*scale)
    return max(values, default=0)
def pct(direction, key):
    values=[]
    for j in jobs:
        section=j.get(direction) or {}
        item=section.get("lat_ns") or section.get("lat_us") or {}
        value=(item.get("percentile") or {}).get(key)
        scale=1/1000 if "lat_ns" in section else 1
        if isinstance(value,(int,float)): values.append(float(value)*scale)
    return max(values, default=0)
errors=sum(int(j.get("error") or j.get("total_err") or j.get("total_io_errors") or 0) for j in jobs)
print("\t".join(map(str,[qd,total("read","bw_bytes")/2**20,total("write","bw_bytes")/2**20,
                        pct("read","95.000000"),pct("read","99.000000"),stat("read","mean"),stat("read","max"),
                        pct("write","95.000000"),pct("write","99.000000"),stat("write","mean"),stat("write","max"),errors,rc])))
PY
    (( rc == 0 )) || { echo "QD_CALIBRATION_FAIL qd=$qd rc=$rc" >&2; exit "$rc"; }
    check_cluster
done
"$LT_CEPH_READONLY_WRAPPER" -s -f json >"$result_root/ceph-post.json"
findmnt -rn -M "$LT_MOUNT_POINT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$result_root/mount-post.tsv"
(cd "$result_root" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
printf 'QD_CALIBRATION_PASS\trun=%s\tresult=%s\n' "$run_id" "$result_root"
