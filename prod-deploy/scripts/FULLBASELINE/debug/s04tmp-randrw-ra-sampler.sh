#!/usr/bin/env bash
# Finite, read-only client/Ceph sidecar for 04-tmp randrw readahead A/B.
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
OUT=${2:-}
DURATION=${3:-240}
MOUNT_PID=${4:-0}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-1}
FIXTURE=${S04TMP_OSD_FIXTURE:-}
INTERVAL=${S04TMP_SAMPLE_INTERVAL:-5}

die() { printf 'E_S04TMP_SAMPLER\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'invalid RUN_ID'
[[ $OUT == /tmp/production/opencode-04-tmp-randrw-ra-"$RUN_ID"/* ]] || die 'OUT outside exact RUN scope'
[[ ! -L $OUT ]] || die 'OUT must not be symlink'
[[ $DURATION =~ ^[0-9]+$ && $DURATION -ge 10 && $DURATION -le 600 ]] || die 'duration outside 10..600'
[[ $INTERVAL =~ ^[0-9]+$ && $INTERVAL -ge 1 && $INTERVAL -le 10 ]] || die 'interval outside 1..10'
[[ $MOUNT_PID =~ ^[0-9]+$ ]] || die 'mount PID must be numeric'
[[ ! -e $OUT/SAMPLER_STARTED ]] || die 'sampler output already exists'
mkdir -p "$OUT/raw"
printf 'pid\t%s\npgid\t%s\nstart_ns\t%s\nduration\t%s\n' \
  "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" "$(date +%s%N)" "$DURATION" >"$OUT/SAMPLER_STARTED"
printf 'epoch_ns\tosd\top_r\top_r_out_bytes\top_r_lat_sum\top_r_lat_count\top_w\top_w_in_bytes\top_w_lat_sum\top_w_lat_count\tcompact_running\tcompact_queue_len\tkv_sync_sum\tkv_sync_count\n' >"$OUT/osd-perf.tsv"
printf 'epoch_ns\trx_bytes\ttx_bytes\tproc_utime\tproc_stime\tproc_rss_pages\tosd_rows\n' >"$OUT/heartbeat.tsv"

if [[ -n $FIXTURE ]]; then
  [[ $DRY_RUN_ONLY == 1 && -f $FIXTURE && ! -L $FIXTURE ]] || die 'invalid fixture mode'
else
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real sampler disabled by DRY_RUN_ONLY=1'
  command -v sudo >/dev/null || die 'sudo missing'
  command -v ceph >/dev/null || die 'ceph missing'
  mapfile -t OSDS < <(sudo ceph osd ls | awk '/^[0-9]+$/{print}')
  (( ${#OSDS[@]} == 6 )) || die "expected exactly six OSDs, got ${#OSDS[@]}"
fi

read_nic() {
  awk -F'[: ]+' '$1!="lo" && $1!="Inter-" && NF>=11{rx+=$3;tx+=$11} END{printf "%d\t%d\n",rx+0,tx+0}' /proc/net/dev
}

parse_perf() {
  python3 - "$1" "$2" "$3" <<'PY'
import json,sys
path,epoch,osd=sys.argv[1:]; d=json.load(open(path)); o=d.get('osd'); r=d.get('rocksdb'); b=d.get('bluestore')
if not all(isinstance(x,dict) for x in (o,r,b)): raise SystemExit('required osd/rocksdb/bluestore section missing')
rl=o.get('op_r_latency'); wl=o.get('op_w_latency'); kv=b.get('kv_sync_lat')
if not all(isinstance(x,dict) for x in (rl,wl,kv)): raise SystemExit('required latency object missing')
vals=(o.get('op_r'),o.get('op_r_out_bytes'),rl.get('sum'),rl.get('avgcount'),o.get('op_w'),
      o.get('op_w_in_bytes'),wl.get('sum'),wl.get('avgcount'),r.get('compact_running'),
      r.get('compact_queue_len'),kv.get('sum'),kv.get('avgcount'))
if any(x is None for x in vals): raise SystemExit('required OSD counter missing')
print(epoch,osd,*vals,sep='\t')
PY
}

deadline=$(( $(date +%s) + DURATION )); samples=0
while (( $(date +%s) <= deadline )); do
  epoch=$(date +%s%N); rows=0
  if [[ -n $FIXTURE ]]; then
    for osd in 0 1 2 3 4 5; do parse_perf "$FIXTURE" "$epoch" "$osd" >>"$OUT/osd-perf.tsv"; rows=$((rows+1)); done
  else
    sudo ceph health detail --format json >"$OUT/raw/health-$epoch.json"
    sudo ceph pg dump pgs_brief --format json >"$OUT/raw/pg-$epoch.json"
    sudo ceph df detail --format json >"$OUT/raw/df-$epoch.json"
    for osd in "${OSDS[@]}"; do
      raw="$OUT/raw/osd-$osd-$epoch.json"
      timeout 15 sudo ceph tell "osd.$osd" perf dump >"$raw" || die "cannot sample osd.$osd"
      parse_perf "$raw" "$epoch" "$osd" >>"$OUT/osd-perf.tsv"; rows=$((rows+1))
    done
  fi
  read -r rx tx < <(read_nic)
  utime=0; stime=0; rss=0
  if (( MOUNT_PID > 0 )); then
    [[ -r /proc/$MOUNT_PID/stat ]] || die 'mount process disappeared during sample'
    read -r utime stime rss < <(python3 - "$MOUNT_PID" <<'PY'
import sys
x=open('/proc/'+sys.argv[1]+'/stat').read().split(); print(x[13],x[14],x[23])
PY
)
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$rx" "$tx" "$utime" "$stime" "$rss" "$rows" >>"$OUT/heartbeat.tsv"
  samples=$((samples+1))
  if [[ -n $FIXTURE ]]; then
    (( samples >= 4 )) && break
  elif [[ -f $OUT/STOP_REQUEST && $samples -ge 3 ]]; then
    break
  fi
  sleep "$INTERVAL"
done
(( samples >= 3 )) || die 'insufficient sampler coverage'
printf 'SAMPLER_PASS\t%s\t%s\t%s\n' "$RUN_ID" "$samples" "$(date +%s%N)" >"$OUT/SAMPLER_PASS"
printf 'SAMPLER_PASS samples=%s out=%s\n' "$samples" "$OUT"
