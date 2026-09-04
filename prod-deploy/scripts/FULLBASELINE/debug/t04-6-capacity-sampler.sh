#!/usr/bin/env bash
# 04-6 finite read-only mechanism sampler.
# It owns only files below one RUN/CELL sampler directory.  It never invokes
# elevated privilege and has no cache, mount, Ceph-state, service, or data mutation path.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN_ID=${1:-}
CELL=${2:-}
OUT=${3:-}
DURATION=${4:-240}
MOUNT_PID=${5:-0}
STOP_REQUEST=${6:-}
INTERVAL=${T046_SAMPLE_INTERVAL:-5}
FIXTURE_DIR=${T046_FIXTURE_DIR:-}
MOUNT_POINT=${T046_MOUNT_POINT:-/mnt/juicefs}
NIC=${T046_NIC:-}
OSD_IDS=(0 1 2 3 4 5)
TIKV_HOSTS_CSV=${T046_TIKV_HOSTS:-10.20.1.150,10.20.1.151,10.20.1.152}
TIKV_PORT=${T046_TIKV_PORT:-20180}
TIKV_SSH_USER=${T046_TIKV_SSH_USER:-}
DRY_RUN_ONLY=${T046_DRY_RUN_ONLY:-0}
MOUNT_START_TICKS=

die() { printf 'T046_SAMPLER_FAIL\t%s\n' "$*" >&2; exit 42; }
log() { printf 'T046_SAMPLER\t%s\n' "$*" >&2; }

if [[ ${1:-} == --self-test ]]; then
  set --
  SELF_ROOT=$(mktemp -d /tmp/t046-sampler-selftest.XXXXXX)
  SELF_RUN=20990101-000002-$(date +%s%N)
  SELF_FIXTURE="$SELF_ROOT/fixture"; SELF_OUT="/tmp/production/opencode-04-6-$SELF_RUN/cells/R01/sampler"
  mkdir -p "$SELF_FIXTURE" "$SELF_OUT"
  # A compact fixture exercises all six OSD rows without contacting Ceph.
  python3 - "$SELF_FIXTURE" <<'PY'
import json, pathlib, sys
r = pathlib.Path(sys.argv[1])
for osd in range(6):
    (r/f"osd-{osd}.json").write_text(json.dumps({
        "osd": {"op_r": 10, "op_r_out_bytes": 1000,
                "op_r_latency": {"sum": 20, "avgcount": 10},
                "op_w": 11, "op_w_in_bytes": 1100,
                "op_w_latency": {"sum": 22, "avgcount": 11}},
        "rocksdb": {"compact_running": 0, "compact_queue_len": 0},
        "bluestore": {"kv_sync_lat": {"sum": 3, "avgcount": 2}}
    }))
(r/"juicefs.stats").write_text("buffer_hit_bytes 100\nget_requests 2\nput_requests 3\n")
(r/"tikv.metrics").write_text("tikv_scheduler_command_duration_seconds_sum 1\n"
                              "tikv_storage_engine_async_request_duration_seconds_sum 2\n"
                              "tikv_raftstore_apply_wait_time_duration_seconds_sum 3\n"
                              "tikv_engine_pending_compaction_bytes 0\n")
(r/"iostat.txt").write_text("fixture iostat\n")
(r/"ceph-status.json").write_text(json.dumps({"health":{"status":"HEALTH_OK"},
    "pgmap":{"pgs_by_state":[{"state_name":"active+clean","count":97}]}}))
PY
  # The output directory is intentionally left as a reviewable transient fixture.
  : >"$SELF_OUT/STOP_REQUEST"
  T046_DRY_RUN_ONLY=1 T046_FIXTURE_DIR="$SELF_FIXTURE" T046_SAMPLE_INTERVAL=1 \
    "$0" "$SELF_RUN" R01 "$SELF_OUT" 10 0 "$SELF_OUT/STOP_REQUEST"
  test -s "$SELF_OUT/SAMPLER_PASS"
  test "$(awk 'END{print NR-1}' "$SELF_OUT/osd-perf.tsv")" -ge 18
  test -s "$SELF_OUT/juicefs-stats.tsv"
  test -s "$SELF_OUT/tikv-metrics.tsv"
  printf 'T046_SAMPLER_SELFTEST_PASS\tout=%s\n' "$SELF_OUT"
  exit 0
fi

[[ $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid RUN_ID'
[[ $CELL =~ ^[RWM]0[1-3]$ ]] || die 'invalid CELL'
[[ $OUT == /tmp/production/opencode-04-6-"$RUN_ID"/cells/"$CELL"/sampler ]] \
  || die 'OUT must be exact /tmp/production/opencode-04-6-RUN/cells/CELL/sampler'
[[ ! -L $OUT ]] || die 'OUT must not be symlink'
[[ $DURATION =~ ^[0-9]+$ && $DURATION -ge 10 && $DURATION -le 600 ]] || die 'duration outside 10..600'
[[ $INTERVAL =~ ^[0-9]+$ && $INTERVAL -ge 1 && $INTERVAL -le 10 ]] || die 'interval outside 1..10'
[[ $MOUNT_PID =~ ^[0-9]+$ ]] || die 'MOUNT_PID must be numeric'
[[ -z $STOP_REQUEST || $STOP_REQUEST == "$OUT/STOP_REQUEST" ]] || die 'STOP_REQUEST outside sampler scope'
STOP_REQUEST=${STOP_REQUEST:-$OUT/STOP_REQUEST}
[[ ! -e $OUT/SAMPLER_STARTED ]] || die 'sampler output already exists'

if (( MOUNT_PID > 0 )); then
  [[ -r /proc/$MOUNT_PID/stat ]] || die 'mount worker missing before sampler start'
  MOUNT_START_TICKS=$(awk '{print $22}' "/proc/$MOUNT_PID/stat")
  [[ $MOUNT_START_TICKS =~ ^[0-9]+$ ]] || die 'invalid mount worker starttime'
fi

mkdir -p "$OUT/raw" "$OUT/iostat" "$OUT/tikv"
printf 'pid\t%s\nstart_ns\t%s\nduration_s\t%s\ninterval_s\t%s\n' \
  "$$" "$(date +%s%N)" "$DURATION" "$INTERVAL" >"$OUT/SAMPLER_STARTED"
printf 'epoch_ns\tosd\top_r\top_r_out_bytes\top_r_lat_sum\top_r_lat_count\top_w\top_w_in_bytes\top_w_lat_sum\top_w_lat_count\tcompact_running\tcompact_queue_len\tkv_sync_sum\tkv_sync_count\n' >"$OUT/osd-perf.tsv"
printf 'epoch_ns\tpid\tstarttime_ticks\tutime_ticks\tstime_ticks\trss_pages\tthreads\tcmdline\n' >"$OUT/mount-proc.tsv"
printf 'epoch_ns\tpid\ttid\tcomm\tutime_ticks\tstime_ticks\n' >"$OUT/mount-threads.tsv"
printf 'epoch_ns\tinterface\trx_bytes\ttx_bytes\n' >"$OUT/nic.tsv"
printf 'epoch_ns\tcpu_fields\tload1\trunnable\tblocked\n' >"$OUT/client-host.tsv"
printf 'epoch_ns\thealth\tcheck_keys\ttotal_pgs\tactive_clean_pgs\tother_states\n' >"$OUT/ceph-health.tsv"
printf 'epoch_ns\tpid\targs\n' >"$OUT/fio-processes.tsv"
printf 'epoch_ns\tfile\tstatus\n' >"$OUT/juicefs-stats.tsv"
printf 'epoch_ns\thost\tstatus\tfile\n' >"$OUT/tikv-metrics.tsv"
printf 'epoch_ns\tscope\tstatus\tfile\n' >"$OUT/iostat.tsv"

if [[ -n $FIXTURE_DIR ]]; then
  [[ $DRY_RUN_ONLY == 1 && -d $FIXTURE_DIR && ! -L $FIXTURE_DIR ]] || die 'invalid fixture mode'
  for osd in "${OSD_IDS[@]}"; do [[ -s $FIXTURE_DIR/osd-$osd.json ]] || die "missing fixture osd-$osd.json"; done
else
  [[ $DRY_RUN_ONLY == 0 ]] || die 'real sampler disabled by T046_DRY_RUN_ONLY=1'
  command -v ceph >/dev/null || die 'ceph missing'
  command -v curl >/dev/null || die 'curl missing'
  [[ -r $MOUNT_POINT/.stats ]] || die "JuiceFS stats missing: $MOUNT_POINT/.stats"
  [[ -n $NIC && -r /sys/class/net/$NIC/statistics/rx_bytes ]] || die 'exact T046_NIC is required in real mode'
  (( MOUNT_PID > 0 )) || die 'real sampler requires the mount worker PID'
fi

parse_perf() {
  local json=$1 epoch=$2 osd=$3
  python3 - "$json" "$epoch" "$osd" <<'PY'
import json, sys
path, epoch, osd = sys.argv[1:]
d = json.load(open(path)); o = d.get("osd", {}); r = d.get("rocksdb", {}); b = d.get("bluestore", {})
rl = o.get("op_r_latency", {}); wl = o.get("op_w_latency", {}); kv = b.get("kv_sync_lat", {})
keys = (o.get("op_r"), o.get("op_r_out_bytes"), rl.get("sum"), rl.get("avgcount"),
        o.get("op_w"), o.get("op_w_in_bytes"), wl.get("sum"), wl.get("avgcount"),
        r.get("compact_running"), r.get("compact_queue_len"), kv.get("sum"), kv.get("avgcount"))
if any(x is None for x in keys):
    raise SystemExit("required OSD/rocksdb/bluestore counter missing")
print(epoch, osd, *keys, sep="\t")
PY
}

sample_nic() {
  if [[ -n $NIC && -r /sys/class/net/$NIC/statistics/rx_bytes ]]; then
    printf '%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$NIC" \
      "$(cat "/sys/class/net/$NIC/statistics/rx_bytes")" "$(cat "/sys/class/net/$NIC/statistics/tx_bytes")" >>"$OUT/nic.tsv"
  else
    awk -F'[: ]+' -v e="$(date +%s%N)" '$1!="lo" && $1!="Inter-" && NF>=11{printf "%s\t%s\t%d\t%d\n",e,$1,$3,$11}' /proc/net/dev >>"$OUT/nic.tsv"
  fi
}

sample_mount_proc() {
  (( MOUNT_PID > 0 )) || { printf '%s\t0\tNA\tNA\tNA\tNA\tNA\tfixture-or-unset\n' "$(date +%s%N)" >>"$OUT/mount-proc.tsv"; return; }
  [[ -r /proc/$MOUNT_PID/stat ]] || die 'mount worker disappeared'
  [[ -z $MOUNT_START_TICKS || $(awk '{print $22}' "/proc/$MOUNT_PID/stat") == "$MOUNT_START_TICKS" ]] || die 'mount worker starttime changed'
  local epoch; epoch=$(date +%s%N)
  python3 - "$MOUNT_PID" "$epoch" "$OUT/mount-proc.tsv" <<'PY'
import pathlib, sys
pid, epoch, out = sys.argv[1:]
ids = [pid]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        stat = (p/'stat').read_text().split()
        if stat[3] == pid: ids.append(p.name)
    except (OSError, ValueError, IndexError): pass
with open(out, 'a') as f:
    for x in ids:
        try:
            st = pathlib.Path('/proc', x, 'stat').read_text().split()
            threads = 'NA'
            for line in pathlib.Path('/proc', x, 'status').read_text().splitlines():
                if line.startswith('Threads:'): threads = line.split()[1]
            cmd = pathlib.Path('/proc', x, 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
            f.write(f"{epoch}\t{x}\t{st[21]}\t{st[13]}\t{st[14]}\t{st[23]}\t{threads}\t{cmd}\n")
        except OSError: pass
PY
}

sample_mount_threads() {
  local epoch=$1
  (( MOUNT_PID > 0 )) || return 0
  python3 - "$MOUNT_PID" "$epoch" "$OUT/mount-threads.tsv" <<'PY'
import pathlib, re, sys
pid, epoch, out = sys.argv[1:]
with open(out, 'a') as f:
    for p in sorted(pathlib.Path('/proc', pid, 'task').glob('[0-9]*'), key=lambda x:int(x.name)):
        try:
            s=(p/'stat').read_text(); m=re.match(r'^(\d+) \((.*)\) ([A-Z]) (.*)$',s)
            if not m: continue
            rest=m.group(4).split()
            # rest starts at proc field 4; utime/stime are fields 14/15.
            f.write(f"{epoch}\t{pid}\t{m.group(1)}\t{m.group(2)}\t{rest[10]}\t{rest[11]}\n")
        except OSError: pass
PY
}

sample_host_health() {
  local epoch=$1 status load cpu run blocked
  status="$OUT/raw/ceph-status-$epoch.json"
  cpu=$(awk '/^cpu /{for(i=2;i<=11;i++) printf "%s%s",$i,(i==11?"":" "); exit}' /proc/stat)
  read -r load _ _ run _ </proc/loadavg
  blocked=$(awk '/^procs_blocked /{print $2}' /proc/stat)
  printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$cpu" "$load" "${run%%/*}" "${blocked:-NA}" >>"$OUT/client-host.tsv"
  if [[ -n $FIXTURE_DIR ]]; then cp -- "$FIXTURE_DIR/ceph-status.json" "$status"
  else timeout 15 ceph status --format json >"$status" 2>&1 || die 'cannot sample Ceph status'; fi
  python3 - "$status" "$epoch" >>"$OUT/ceph-health.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); rows=d.get('pgmap',{}).get('pgs_by_state',[])
health_obj=d.get('health',{}); health=health_obj.get('status','MISSING')
checks=','.join(sorted((health_obj.get('checks') or {}).keys())) or 'none'
total=sum(int(x.get('count',0)) for x in rows)
clean=sum(int(x.get('count',0)) for x in rows if x.get('state_name')=='active+clean')
other=','.join(f"{x.get('state_name')}:{x.get('count')}" for x in rows if x.get('state_name')!='active+clean') or 'none'
print(sys.argv[2],health,checks,total,clean,other,sep='\t')
PY
  if [[ -z $FIXTURE_DIR ]]; then
    ps -C fio -o pid=,args= 2>/dev/null | awk -v e="$epoch" '{$1=$1; p=$1; sub(/^[^ ]+[ ]*/,""); print e"\t"p"\t"$0}' >>"$OUT/fio-processes.tsv" || true
  fi
}

sample_jfs_stats() {
  local epoch=$1 file
  file="$OUT/raw/juicefs-stats-$epoch.txt"
  if [[ -n $FIXTURE_DIR ]]; then cp -- "$FIXTURE_DIR/juicefs.stats" "$file" 2>/dev/null || : >"$file"
  else timeout 5 cat "$MOUNT_POINT/.stats" >"$file" 2>&1 || printf 'STATS_READ_MISSING\n' >"$file"; fi
  grep -Ei 'buffer|hit|miss|get|put|request|upload|download|read|write|cache|inflight|pending' "$file" >"$file.keys" 2>/dev/null || :
  printf '%s\t%s\t%s\n' "$epoch" "$file.keys" "$(test -s "$file.keys" && echo PRESENT || echo MISSING)" >>"$OUT/juicefs-stats.tsv"
  [[ $samples -eq 0 ]] || rm -f -- "$file"
}

sample_tikv() {
  local epoch=$1 host file
  IFS=',' read -r -a hosts <<<"$TIKV_HOSTS_CSV"
  for host in "${hosts[@]}"; do
    [[ $host =~ ^[A-Za-z0-9_.:-]+$ ]] || { printf '%s\t%s\tINVALID_HOST\t-\n' "$epoch" "$host" >>"$OUT/tikv-metrics.tsv"; continue; }
    file="$OUT/tikv/$epoch-$host.prom"
    if [[ -n $FIXTURE_DIR ]]; then
      cp -- "$FIXTURE_DIR/tikv.metrics" "$file" 2>/dev/null || : >"$file"
    else
      curl -fsS --connect-timeout 3 --max-time 8 "http://$host:$TIKV_PORT/metrics" >"$file.tmp" 2>/dev/null || : >"$file.tmp"
      mv -- "$file.tmp" "$file"
    fi
    grep -E '^(tikv_scheduler_|tikv_storage_.*(prewrite|async|request)|tikv_raftstore_.*(append|commit|apply|sync|wait)|tikv_engine_pending_compaction|tikv_engine_compaction|process_cpu_seconds_total)' "$file" >"$file.key" 2>/dev/null || :
    if [[ -s $file.key ]]; then printf '%s\t%s\tPRESENT\t%s\n' "$epoch" "$host" "$file.key" >>"$OUT/tikv-metrics.tsv"
    else printf '%s\t%s\tMISSING\t%s\n' "$epoch" "$host" "$file" >>"$OUT/tikv-metrics.tsv"; fi
    [[ $samples -eq 0 ]] || rm -f -- "$file"
  done
}

sample_iostat() {
  local epoch=$1 file
  file="$OUT/iostat/157-$epoch.txt"
  if [[ -n $FIXTURE_DIR ]]; then cp -- "$FIXTURE_DIR/iostat.txt" "$file" 2>/dev/null || : >"$file"
  elif command -v iostat >/dev/null; then timeout 8 iostat -dxk -y 1 1 >"$file" 2>&1 || :
  else printf 'IOSTAT_UNAVAILABLE\n' >"$file"; fi
  printf '%s\t157\t%s\t%s\n' "$epoch" "$(test -s "$file" && echo PRESENT || echo MISSING)" "$file" >>"$OUT/iostat.tsv"
  [[ -n $TIKV_SSH_USER ]] || return 0
  local host rfile
  IFS=',' read -r -a hosts <<<"$TIKV_HOSTS_CSV"
  for host in "${hosts[@]}"; do
    rfile="$OUT/iostat/tikv-$host-$epoch.txt"
    if [[ -n $FIXTURE_DIR ]]; then printf 'REMOTE_IOSTAT_FIXTURE\n' >"$rfile"
    elif ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no "$TIKV_SSH_USER@$host" 'iostat -dxk -y 1 1' >"$rfile" 2>&1; then :
    else printf 'REMOTE_IOSTAT_MISSING\n' >"$rfile"; fi
    printf '%s\t%s\t%s\t%s\n' "$epoch" "$host" "$(grep -qv MISSING "$rfile" && echo PRESENT || echo MISSING)" "$rfile" >>"$OUT/iostat.tsv"
  done
}

if [[ -n $FIXTURE_DIR ]]; then
  # Fixture mode deliberately runs four samples so STOP_REQUEST and coverage
  # are tested without sleeping through a real benchmark window.
  SAMPLE_LIMIT=4
else
  SAMPLE_LIMIT=0
fi
start=$(date +%s); deadline=$((start + DURATION)); samples=0
while (( $(date +%s) <= deadline )); do
  epoch=$(date +%s%N)
  for osd in "${OSD_IDS[@]}"; do
    raw="$OUT/raw/osd-$osd-$epoch.json"
    if [[ -n $FIXTURE_DIR ]]; then cp -- "$FIXTURE_DIR/osd-$osd.json" "$raw"
    else timeout 15 ceph tell "osd.$osd" perf dump >"$raw" 2>&1 || die "cannot sample osd.$osd"; fi
    parse_perf "$raw" "$epoch" "$osd" >>"$OUT/osd-perf.tsv" || die "invalid perf dump osd.$osd"
  done
  sample_nic; sample_mount_proc; sample_mount_threads "$epoch"; sample_host_health "$epoch"
  sample_jfs_stats "$epoch"; sample_tikv "$epoch"; sample_iostat "$epoch"
  samples=$((samples + 1))
  if [[ -e $STOP_REQUEST && $samples -ge 3 ]]; then break; fi
  if (( SAMPLE_LIMIT > 0 && samples >= SAMPLE_LIMIT )); then break; fi
  sleep "$INTERVAL"
done
(( samples >= 3 )) || die 'insufficient sampler coverage'
printf 'SAMPLER_PASS\t%s\t%s\t%s\n' "$RUN_ID" "$CELL" "$samples" >"$OUT/SAMPLER_PASS"
printf 'T046_SAMPLER_PASS\tsamples=%s\tout=%s\n' "$samples" "$OUT"
