#!/bin/bash
set -euo pipefail

# Read-only, bounded post-LT-002 observation. This script never invokes GC,
# compaction, deletion, or a new workload. It writes only its own evidence files.
umask 077
RUN_ID=20260924-102324
RUN_ROOT=/data/reliability-lt-results/20260924-102324/LT-002
DATA_ROOT=/mnt/juicefs/reliability-lt-data/20260924-102324/LT-002/randrw256k
OUT_DIR=/data/reliability-lt-results/20260924-102324/LT-002/idle-observation
POOL=juicefs-data
CEPH_CONF=/etc/ceph/ceph.conf
CEPH_KEYRING=/etc/ceph/ceph.client.admin.keyring
INTERVAL_S=300
SAMPLES=289
PREWRITE_STORED=251712839084

[[ -d "$RUN_ROOT" && -d "$DATA_ROOT" ]] || { echo 'REFUSE: scoped LT-002 result or data directory missing' >&2; exit 2; }
[[ -f "$RUN_ROOT/run-state.tsv" ]] || { echo 'REFUSE: run state missing' >&2; exit 2; }
grep -Fq $'\tCOMPLETE\tprofile=randrw256k' "$RUN_ROOT/run-state.tsv" || { echo 'REFUSE: LT-002 not complete' >&2; exit 2; }
python3 - "$RUN_ROOT/inventory/volume-config.json" <<'PY'
import json, sys
setting = json.load(open(sys.argv[1]))['Setting']
if setting['UUID'] != '3e54dcc4-991e-425a-8e76-16c9c1fb6836' or setting['TrashDays'] != 0:
    raise SystemExit('REFUSE: volume fingerprint differs')
PY
if pgrep -x fio >/dev/null; then echo 'REFUSE: fio is running' >&2; exit 2; fi
[[ ! -e "$OUT_DIR/observations.tsv" ]] || { echo 'REFUSE: observation file already exists' >&2; exit 2; }
mkdir -p -- "$OUT_DIR"
exec 9>"$OUT_DIR/observer.lock"
flock -n 9 || { echo 'REFUSE: another observer is running' >&2; exit 2; }
printf 'epoch\tiso8601\thealth\tobjects\tstored_bytes\tdelta_vs_prewrite_bytes\traw_used_bytes\tmax_avail_bytes\tstate\n' >"$OUT_DIR/observations.tsv"
printf 'run_id=%s\tpool=%s\tinterval_s=%s\tsamples=%s\tprewrite_stored=%s\tstart_epoch=%s\n' \
    "$RUN_ID" "$POOL" "$INTERVAL_S" "$SAMPLES" "$PREWRITE_STORED" "$(date +%s)" >"$OUT_DIR/observer-meta.tsv"

for ((n=0; n<SAMPLES; n++)); do
    epoch=$(date +%s)
    iso=$(date --iso-8601=seconds)
    if [[ ! -d "$DATA_ROOT" ]] || pgrep -x fio >/dev/null; then
        printf '%s\t%s\tNA\tNA\tNA\tNA\tNA\tNA\tCONTAMINATED_DATA_OR_FIO\n' "$epoch" "$iso" >>"$OUT_DIR/observations.tsv"
        exit 3
    fi
    if pool_row=$(timeout 30s sudo -n ceph --conf "$CEPH_CONF" --keyring "$CEPH_KEYRING" -n client.admin df detail --format json | \
        python3 -c 'import json,sys; p=next(x for x in json.load(sys.stdin)["pools"] if x["name"]=="juicefs-data"); s=p["stats"]; print("\t".join(str(int(s[k])) for k in ("objects","stored","bytes_used","max_avail")))') && \
       health=$(timeout 30s sudo -n ceph --conf "$CEPH_CONF" --keyring "$CEPH_KEYRING" -n client.admin health); then
        health=${health//$'\t'/ }
        health=${health//$'\n'/ }
        IFS=$'\t' read -r objects stored raw_used max_avail <<<"$pool_row"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tOK\n' \
            "$epoch" "$iso" "$health" "$objects" "$stored" "$((stored-PREWRITE_STORED))" "$raw_used" "$max_avail" >>"$OUT_DIR/observations.tsv"
    else
        printf '%s\t%s\tNA\tNA\tNA\tNA\tNA\tNA\tSAMPLE_ERROR\n' "$epoch" "$iso" >>"$OUT_DIR/observations.tsv"
    fi
    if (( n + 1 < SAMPLES )); then sleep "$INTERVAL_S"; fi
done
printf 'complete_epoch=%s\n' "$(date +%s)" >>"$OUT_DIR/observer-meta.tsv"
