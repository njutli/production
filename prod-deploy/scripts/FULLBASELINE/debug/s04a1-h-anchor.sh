#!/usr/bin/env bash
# Run exactly one H0/H1 B256 anchor on the existing production JuiceFS test assets.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
INSTANCE=${3:-}
s04a1_check_run_id "$RUN_ID"
[[ $INSTANCE == H0 || $INSTANCE == H1 ]] || s04a1_die "anchor must be H0 or H1"

ROOT=${S04A1_REMOTE_ROOT:-/tmp/production/opencode-04-2-$RUN_ID}
OUT="$ROOT/anchors/$INSTANCE"
ARM="$OUT/arm"
MNT=/mnt/juicefs
TEST_DIR="$MNT/test_dir"
META=${S04A1_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
SCRUB_CONTROL=${S04A1_SCRUB_CONTROL:-$ROOT/scripts/u141d-scrub-control.sh}
SCRUB_STATE_DIR=${S04A1_SCRUB_STATE_DIR:-$ROOT/state}
LEASE=${S04A1_SCRUB_LEASE:-$RUN_ID-${INSTANCE,,}-phase-a}
NODES=(10.20.1.150 10.20.1.151 10.20.1.152)
SAMPLER_PIDS=()
SAMPLER_NAMES=()
SAMPLERS_ACTIVE=0
FIO_PGID=''

die() { s04a1_die "$*"; exit 42; }

scope_guard() {
  [[ $ROOT == "/tmp/production/opencode-04-2-$RUN_ID" && $OUT == "$ROOT/anchors/$INSTANCE" &&
     $OUT == /* && $OUT != / && $OUT != *'..'* && ! -L $ROOT ]] || die "result scope mismatch"
}

asset_manifest() {
  local output=$1
  find "$TEST_DIR" -xdev -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
    -printf '%f\t%i\t%s\t%u\t%g\t%T@\n' | sort -V > "$output"
  python3 - "$output" <<'PY'
import sys
rows=[x.rstrip("\n").split("\t") for x in open(sys.argv[1])]
want={f"{stem}.{i}.0" for stem in ("storage_test","rw_test") for i in range(128)}
got={x[0] for x in rows}
assert len(rows)==256 and got==want, (len(rows), sorted(want-got)[:3], sorted(got-want)[:3])
assert all(len(x)==6 and int(x[2])==1073741824 for x in rows)
PY
}

asset_identity_without_mtime() { awk -F '\t' 'BEGIN{OFS="\t"}{print $1,$2,$3,$4,$5}' "$1"; }

mount_guard() {
  local source target fstype
  read -r source target fstype < <(findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE)
  [[ $source == JuiceFS:juicefs-prod && $target == "$MNT" && $fstype == fuse.juicefs ]] || die "production JuiceFS mount mismatch"
  [[ $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die "JuiceFS binary MD5 mismatch"
  "$JFS" status "$META" > "$OUT/status-pre.json"
  python3 - "$OUT/status-pre.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get("Setting",{})
assert s.get("Name")=="juicefs-prod" and s.get("UUID")
PY
  python3 - "$JFS" "$MNT" "$META" > "$OUT/mount-processes.tsv" <<'PY'
import hashlib,os,sys
exe=os.path.realpath(sys.argv[1]); mnt=sys.argv[2]; meta=sys.argv[3]; rows=[]
for name in os.listdir('/proc'):
    if not name.isdigit(): continue
    try:
        actual=os.path.realpath(f'/proc/{name}/exe')
        raw=open(f'/proc/{name}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace')
        st=open(f'/proc/{name}/stat').read().split(); ppid=int(st[3]); start=int(st[21])
    except (OSError,ValueError): continue
    if actual==exe and ' mount ' in raw and mnt in raw and meta in raw:
        rows.append((int(name),ppid,start,actual,raw))
assert rows and any(x[1] in {y[0] for y in rows} for x in rows), rows
assert all('--cache-size 0' in x[4] and '--max-uploads 150' in x[4] and '--max-fuse-io 256K' in x[4] for x in rows)
print('pid\tppid\tstarttime\texe_md5\tcmdline')
for pid,ppid,start,actual,raw in sorted(rows):
    print(pid,ppid,start,hashlib.md5(open(f'/proc/{pid}/exe','rb').read()).hexdigest(),raw,sep='\t')
PY
}

render_jobfile() {
  local file=$1 stem i slot path offset
  {
    printf '%s\n' '[global]' 'rw=randwrite' 'bs=256k' 'ioengine=libaio' 'direct=1' \
      'fallocate=none' 'group_reporting=1' 'iodepth=64' 'log_avg_msec=1000' \
      'per_job_logs=1' 'time_based=1' 'runtime=180' 'allow_file_create=0' \
      'create_on_open=0' 'randrepeat=1' 'allrandrepeat=1'
    slot=0
    for stem in storage_test rw_test; do
      for ((i=0;i<128;i++)); do
        if (( i % 2 == 0 )); then offset=0; else offset=536870912; fi
        path="$TEST_DIR/$stem.$i.0"
        printf '\n[slot%03d]\nfilename=%s\nfilesize=1073741824\noffset=%s\nsize=536870912\nrandseed=%s\n' \
          "$slot" "$path" "$offset" "$((slot+1))"
        slot=$((slot+1))
      done
    done
  } > "$file"
  [[ $(grep -c '^\[slot[0-9][0-9][0-9]\]$' "$file") == 256 && $(grep -c '^filename=' "$file") == 256 ]] || die "jobfile slot count mismatch"
  ! grep -Eq '^allow_file_create=1|^create_on_open=1|^filesize=0' "$file" || die "jobfile can create files"
}

readonly_snapshots() {
  local phase=$1 node
  mkdir -p "$OUT/snapshots/$phase"
  date -Ins > "$OUT/snapshots/$phase/time.txt"
  sudo -n ceph health detail --format json > "$OUT/snapshots/$phase/ceph-health.json"
  sudo -n ceph osd stat --format json > "$OUT/snapshots/$phase/ceph-osd-stat.json"
  sudo -n ceph pg dump pgs_brief > "$OUT/snapshots/$phase/ceph-pgs.txt"
  sudo -n ceph df --format json > "$OUT/snapshots/$phase/ceph-df.json"
  for node in "${NODES[@]}"; do
    curl -fsS --connect-timeout 3 --max-time 20 "http://$node:20180/metrics" > "$OUT/snapshots/$phase/tikv-$node.metrics"
  done
}

start_samplers() {
  local node pid pgid
  mkdir -p "$OUT/samplers"
  setsid iostat -dxm 1 230 > "$OUT/samplers/client-iostat.txt" 2> "$OUT/samplers/client-iostat.stderr" &
  SAMPLER_PIDS=($!)
  SAMPLER_NAMES=(client)
  for node in "${NODES[@]}"; do
    setsid ssh -o BatchMode=yes -o ConnectTimeout=8 "sunrise@$node" 'iostat -dxm 1 230' \
      > "$OUT/samplers/node-$node-iostat.txt" 2> "$OUT/samplers/node-$node-iostat.stderr" &
    pid=$!; SAMPLER_PIDS+=("$pid"); SAMPLER_NAMES+=("$node")
  done
  sleep 5
  for pid in "${SAMPLER_PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || die "sampler died before fio: $pid"
    pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
    [[ $pgid == "$pid" ]] || die "sampler lacks private PGID: pid=$pid pgid=$pgid"
  done
  SAMPLERS_ACTIVE=1
}

stop_samplers() {
  local i pid deadline rc bad=0
  for pid in "${SAMPLER_PIDS[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
  deadline=$((SECONDS+30))
  for i in "${!SAMPLER_PIDS[@]}"; do
    pid=${SAMPLER_PIDS[$i]}
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then printf '%s\tSTUCK\n' "${SAMPLER_NAMES[$i]}" >> "$OUT/samplers/status.tsv"; bad=1; continue; fi
    set +e; wait "$pid"; rc=$?; set -e
    # TERM of the private sampler process group is expected after fio.
    printf '%s\tEXITED\trc=%s\n' "${SAMPLER_NAMES[$i]}" "$rc" >> "$OUT/samplers/status.tsv"
    if [[ ${SAMPLER_NAMES[$i]} == client ]]; then
      [[ -s "$OUT/samplers/client-iostat.txt" ]] || bad=1
    else
      [[ -s "$OUT/samplers/node-${SAMPLER_NAMES[$i]}-iostat.txt" ]] || bad=1
    fi
  done
  SAMPLERS_ACTIVE=0
  (( bad == 0 )) || die "sampler closure failed"
}

emergency_process_cleanup() {
  local rc=$? pid
  trap - EXIT INT TERM
  if [[ -n $FIO_PGID && $FIO_PGID =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM -- "-$FIO_PGID" 2>/dev/null || true
  fi
  if (( SAMPLERS_ACTIVE == 1 )); then
    for pid in "${SAMPLER_PIDS[@]}"; do
      [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -TERM -- "-$pid" 2>/dev/null || true
    done
  fi
  exit "$rc"
}

plan() {
  printf 'H_ANCHOR_PLAN_ONLY\trun=%s\tanchor=%s\tlease=%s\n' "$RUN_ID" "$INSTANCE" "$LEASE"
  printf 'DATASET\t%s/storage_test.0..127.0 + rw_test.0..127.0\n' "$TEST_DIR"
  printf 'FIO\trandwrite bs=256k jobs=256 iodepth=64 runtime=180 direct=1 no-create\n'
  printf 'SCRUB\texternal verify-paused; runner contains no set/unset\n'
  printf 'EVIDENCE\t%s\n' "$OUT"
}

run_anchor() {
  local fio_pid fio_pgid deadline fio_rc=0
  [[ ${S04A1_H_EXECUTE:-} == YES ]] || die "set S04A1_H_EXECUTE=YES"
  [[ ${S04A1_H_AUTH:-} == "04-2-h-anchor-$RUN_ID-$INSTANCE" ]] || die "exact H auth mismatch"
  trap emergency_process_cleanup EXIT INT TERM
  scope_guard
  [[ ! -e $OUT ]] || die "anchor evidence already exists"
  mkdir -p "$ARM/bw" "$OUT/samplers" "$OUT/snapshots"
  mount_guard
  [[ $(pgrep -x fio 2>/dev/null | wc -l) == 0 ]] || die "foreign fio exists"
  for node in "${NODES[@]}"; do
    [[ $(ssh -o BatchMode=yes -o ConnectTimeout=8 "sunrise@$node" 'systemctl is-active tikv 2>/dev/null || true') == active ]] || die "production tikv not active: $node"
    [[ $(ssh -o BatchMode=yes -o ConnectTimeout=8 "sunrise@$node" 'systemctl is-active pd 2>/dev/null || true') == active ]] || die "production pd not active: $node"
  done
  U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" bash "$SCRUB_CONTROL" verify-paused "$LEASE" > "$OUT/scrub-paused.txt"
  asset_manifest "$OUT/layout-pre.tsv"
  render_jobfile "$ARM/B256.fio"
  sha256sum "$ARM/B256.fio" > "$ARM/B256.fio.sha256"
  readonly_snapshots pre
  start_samplers
  printf '%s\tlaunch\n' "$(date +%s.%N)" > "$ARM/phase.tsv"
  printf 'fio %q --write_bw_log=%q\n' "$ARM/B256.fio" "$ARM/bw/$INSTANCE" > "$OUT/commands.sh"
  setsid fio "$ARM/B256.fio" --write_bw_log="$ARM/bw/$INSTANCE" > "$ARM/fio.stdout" 2> "$ARM/fio.stderr" &
  fio_pid=$!; fio_pgid=$(ps -o pgid= -p "$fio_pid" | tr -d ' ')
  [[ $fio_pgid == "$fio_pid" ]] || die "fio does not own a private PGID"
  FIO_PGID=$fio_pgid
  printf '%s\n' "$fio_pid" > "$ARM/fio.pid"; printf '%s\n' "$fio_pgid" > "$ARM/fio.pgid"
  deadline=$((SECONDS+600))
  while kill -0 "$fio_pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 2; done
  if kill -0 "$fio_pid" 2>/dev/null; then
    printf '%s\twatchdog-term\n' "$(date +%s.%N)" >> "$ARM/phase.tsv"
    kill -TERM -- "-$fio_pgid" 2>/dev/null || true
    local term_deadline=$((SECONDS+60)); while kill -0 "$fio_pid" 2>/dev/null && (( SECONDS < term_deadline )); do sleep 1; done
    kill -0 "$fio_pid" 2>/dev/null && die "fio stuck after TERM; no SIGKILL sent"
    fio_rc=124
  else
    set +e; wait "$fio_pid"; fio_rc=$?; set -e
  fi
  FIO_PGID=''
  printf '%s\n' "$fio_rc" > "$ARM/fio.rc"
  printf '%s\tend\trc=%s\n' "$(date +%s.%N)" "$fio_rc" >> "$ARM/phase.tsv"
  sleep 15
  readonly_snapshots post
  stop_samplers
  asset_manifest "$OUT/layout-post.tsv"
  asset_identity_without_mtime "$OUT/layout-pre.tsv" > "$OUT/layout-pre.identity.tsv"
  asset_identity_without_mtime "$OUT/layout-post.tsv" > "$OUT/layout-post.identity.tsv"
  cmp -s "$OUT/layout-pre.identity.tsv" "$OUT/layout-post.identity.tsv" || die "H asset identity changed"
  (( fio_rc == 0 )) || die "fio failed rc=$fio_rc"
  [[ ! -s $ARM/fio.stderr && $(grep -c 'err= 0' "$ARM/fio.stdout") -ge 1 ]] || die "fio output reports error"
  [[ $(find "$ARM/bw" -maxdepth 1 -type f -name '*_bw.*.log' | wc -l) == 256 ]] || die "expected 256 BW logs"
  python3 "$SCRIPT_DIR/t65-analyze.py" --derive-io-start "$OUT" > "$OUT/io-start.stdout"
  python3 "$SCRIPT_DIR/s04a1-analyze.py" --arm "$OUT" "$INSTANCE" > "$OUT/analysis.stdout"
  printf 'H_ANCHOR_PASS\t%s\n' "$INSTANCE" > "$OUT/PASS"
  find "$OUT" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$OUT/SHA256SUMS"
  trap - EXIT INT TERM
  printf 'S04A1_H_ANCHOR_PASS instance=%s evidence=%s\n' "$INSTANCE" "$OUT"
}

case "$ACTION" in
  plan) plan ;;
  run) run_anchor ;;
  *) die "usage: $0 plan|run RUN_ID H0|H1" ;;
esac
