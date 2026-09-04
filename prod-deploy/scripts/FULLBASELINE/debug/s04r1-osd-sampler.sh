#!/usr/bin/env bash
# Local-node OSD counter sampler for 04-1/R1. Finite lifetime, strict fields.
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
OUT=${2:-}
DURATION=${3:-200}
INTERVAL=${R1_SAMPLE_INTERVAL:-1}
DRY_RUN_ONLY=${DRY_RUN_ONLY:-1}
FIXTURE_DIR=${R1_OSD_FIXTURE_DIR:-}

die() { printf 'E_R1_SAMPLER\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 'invalid RUN_ID'
# Accept both 04-1 and 04-1b result scopes
[[ $OUT == /tmp/production/opencode-04-1-"$RUN_ID"/* || $OUT == /tmp/production/opencode-04-1b-"$RUN_ID"/* ]] || die 'OUT outside RUN scope'
[[ ! -L $OUT ]] || die 'OUT must not be symlink'
[[ $DURATION =~ ^[0-9]+$ && $DURATION -ge 5 && $DURATION -le 900 ]] || die 'duration outside 5..900s'
[[ $INTERVAL =~ ^[0-9]+$ && $INTERVAL -ge 1 && $INTERVAL -le 10 ]] || die 'interval outside 1..10s'
mkdir -p "$OUT/raw"
[[ ! -e $OUT/SAMPLER_STARTED ]] || die 'sampler output already exists'

printf 'pid\t%s\npgid\t%s\nstart_epoch_ns\t%s\nduration\t%s\n' \
  "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" "$(date +%s%N)" "$DURATION" >"$OUT/SAMPLER_STARTED"
printf 'epoch_ns\tnode\tosd\top_r\top_r_out_bytes\top_r_latency_sum\top_r_latency_count\tcompact_running\tcompact_queue_len\n' >"$OUT/osd-perf.tsv"
printf 'epoch_ns\trows\n' >"$OUT/heartbeat.tsv"

if [[ -n $FIXTURE_DIR ]]; then
  [[ $DRY_RUN_ONLY == 1 ]] || die 'fixture sampler requires DRY_RUN_ONLY=1'
  mapfile -t fixtures < <(find "$FIXTURE_DIR" -maxdepth 1 -type f -name 'osd-*.json' -print | sort)
  (( ${#fixtures[@]} > 0 )) || die 'no fixture JSON'
  FSID=fixture
else
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real sampler disabled'
  command -v sudo >/dev/null; command -v ceph >/dev/null; command -v python3 >/dev/null
  FSID=$(sudo ceph fsid)
  mapfile -t osd_ids < <(sudo ceph osd ls | tr ' ' '\n' | awk '/^[0-9]+$/')
  fixtures=()
  for osd in "${osd_ids[@]}"; do
    asok="/var/run/ceph/$FSID/ceph-osd.$osd.asok"
    [[ -S $asok ]] && fixtures+=("$asok")
  done
  (( ${#fixtures[@]} > 0 )) || die 'no local OSD admin sockets'
fi

deadline=$(( $(date +%s) + DURATION ))
sample=0
while (( $(date +%s) <= deadline )); do
  epoch_ns=$(date +%s%N)
  rows=0
  for source in "${fixtures[@]}"; do
    if [[ -n $FIXTURE_DIR ]]; then
      raw=$source
      osd=${source##*/osd-}; osd=${osd%.json}
    else
      osd=${source##*.}; osd=${osd%.asok}
      raw="$OUT/raw/osd-${osd}.json"
      sudo ceph --admin-daemon "$source" perf dump >"$raw"
    fi
    python3 - "$raw" "$epoch_ns" "$(hostname -s)" "$osd" >>"$OUT/osd-perf.tsv" <<'PY'
import json,sys
p,epoch,node,osd=sys.argv[1:]
d=json.load(open(p)); section=d.get('osd')
if not isinstance(section,dict): raise SystemExit('missing exact osd section')
lat=section.get('op_r_latency')
rocks=d.get('rocksdb')
if not isinstance(lat,dict) or not isinstance(rocks,dict):
    raise SystemExit('missing op_r_latency or rocksdb section')
need={'op_r':section.get('op_r'),'op_r_out_bytes':section.get('op_r_out_bytes'),
      'lat_sum':lat.get('sum'),'lat_count':lat.get('avgcount'),
      'compact_running':rocks.get('compact_running'),
      'compact_queue_len':rocks.get('compact_queue_len')}
if any(v is None for v in need.values()):
    raise SystemExit('missing required OSD counter: '+repr(need))
print(epoch,node,osd,need['op_r'],need['op_r_out_bytes'],need['lat_sum'],
      need['lat_count'],need['compact_running'],need['compact_queue_len'],sep='\t')
PY
    rows=$((rows+1))
  done
  printf '%s\t%s\n' "$epoch_ns" "$rows" >>"$OUT/heartbeat.tsv"
  sample=$((sample+1))
  if [[ -n $FIXTURE_DIR ]]; then
    (( sample >= 6 )) && break
  else
    if [[ -f $OUT/STOP_REQUEST && $sample -ge 10 ]]; then
      break
    fi
    sleep "$INTERVAL"
  fi
done
(( sample >= 2 )) || die 'insufficient samples'
printf 'SAMPLER_PASS\t%s\t%s\t%s\n' "$RUN_ID" "$sample" "$(date +%s%N)" >"$OUT/SAMPLER_PASS"
# Save first schema sample per OSD for audit
for f in "$OUT"/raw/osd-*.json; do
  [[ -f $f ]] && cp "$f" "$OUT/schema-$(basename "$f")" 2>/dev/null || true
done
# Clean up raw perf dumps (schema already saved)
find "$OUT/raw" -name 'osd-*.json' -delete 2>/dev/null || true
printf 'SAMPLER_PASS samples=%s out=%s\n' "$sample" "$OUT"
