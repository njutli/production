#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}
RUN_ID=${2:-}
CELL=${3:-}
ROOT=/tmp/production/opencode-04tmp2d-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REFERENCE_MNT=/mnt/juicefs
CACHE_PARENT=/mnt/jfs-cache
CACHE_ROOT=$CACHE_PARENT/jfs-04tmp2d-$RUN_ID
CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
METRICS_ADDR=127.0.0.1:9568
EXPECTED_UID=1002
EXPECTED_GID=1002
SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRUB_CONTROL=$SELF_DIR/u141d-scrub-control.sh

die() { printf 'E_04TMP2D\t%s\n' "$*" >&2; exit 42; }

valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID"
  [[ $ROOT == "/tmp/production/opencode-04tmp2d-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die "unsafe result root"
  [[ $CACHE_ROOT == "/mnt/jfs-cache/jfs-04tmp2d-$RUN_ID" && $CACHE_ROOT != / && $CACHE_ROOT != *..* ]] || die "unsafe cache root"
  [[ ! -L $ROOT && ! -L $CACHE_ROOT ]] || die "symlink root refused"
}

cell_fields() {
  [[ $CELL =~ ^(mseqread|randread)-(A0-pre|C25|C50|C75|C100|C200|A0-post)$ ]] || die "invalid cell: $CELL"
  ITEM=${BASH_REMATCH[1]}; POINT=${BASH_REMATCH[2]}
  case $ITEM in
    mseqread) WORKSET_GIB=64; JOBS=16; FILE_BYTES=4294967296 ;;
    randread) WORKSET_GIB=128; JOBS=128; FILE_BYTES=1073741824 ;;
  esac
  case $POINT in
    A0-pre|A0-post) TIER_GIB=0; TIER_MIB=0; CACHE_DIR= ;;
    C25) TIER_GIB=$((WORKSET_GIB / 4)) ;;
    C50) TIER_GIB=$((WORKSET_GIB / 2)) ;;
    C75) TIER_GIB=$((WORKSET_GIB * 3 / 4)) ;;
    C100) TIER_GIB=$WORKSET_GIB ;;
    C200) TIER_GIB=$((WORKSET_GIB * 2)) ;;
  esac
  if [[ $POINT == C* ]]; then
    TIER_MIB=$((TIER_GIB * 1024)); CACHE_DIR=$CACHE_ROOT/cache-$CELL
  fi
  WORKSET_BYTES=$((WORKSET_GIB * 1024 * 1024 * 1024))
  JFS_MNT=/tmp/jfs-04tmp2d-mnt-$RUN_ID-$CELL
  CELL_ROOT=$ROOT/cells/$CELL
}

validate_cell_paths() {
  cell_fields
  [[ $JFS_MNT == "/tmp/jfs-04tmp2d-mnt-$RUN_ID-$CELL" && $JFS_MNT != / && $JFS_MNT != *..* ]] || die "unsafe mount path"
  [[ $CELL_ROOT == "$ROOT/cells/$CELL" && $CELL_ROOT != / && $CELL_ROOT != *..* ]] || die "unsafe cell path"
  if [[ -n $CACHE_DIR ]]; then
    [[ $CACHE_DIR == "$CACHE_ROOT/cache-$CELL" && $CACHE_DIR != / && $CACHE_DIR != *..* ]] || die "unsafe cache path"
    [[ ! -L $CACHE_DIR ]] || die "cache symlink refused"
  fi
  [[ ! -L $JFS_MNT ]] || die "mount symlink refused"
}

metric_value() {
  local text=$1 name=$2
  awk -v n="$name" '$1 ~ ("^" n "($|\\{)") { s += $(NF); found=1 } END { if (found) printf "%.0f", s; else print "NA" }' <<<"$text"
}

require_metrics() {
  local file=$1 text name value
  text=$(<"$file")
  for name in juicefs_blockcache_bytes juicefs_blockcache_blocks juicefs_blockcache_hits juicefs_blockcache_miss \
      juicefs_blockcache_hit_bytes juicefs_blockcache_miss_bytes juicefs_blockcache_write_bytes \
      juicefs_blockcache_evicts juicefs_blockcache_drops; do
    value=$(metric_value "$text" "$name")
    [[ $value != NA ]] || die "metric unavailable: $name"
  done
}

asset_manifest() {
  local out=$1 base=$2
  local dir pattern
  case $ITEM in
    mseqread) dir=$base/test_dir/mseqread; pattern='mseqread.*.0' ;;
    randread) dir=$base/test_dir; pattern='read_test.*.0' ;;
  esac
  [[ -d $dir && ! -L $dir ]] || die "dataset directory missing: $dir"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%i\t%s\t%T@\n' | sort -V >"$out"
  [[ $(wc -l <"$out") -eq $JOBS ]] || die "dataset count mismatch for $ITEM"
  awk -F '\t' -v s="$FILE_BYTES" '$3 != s { bad=1 } END { exit bad }' "$out" || die "dataset size mismatch for $ITEM"
}

ceph_nic() {
  ip route get 10.3.1.6 | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }'
}

verify_runtime_health() {
  local out=$1 nic route_nic ep
  mountpoint -q "$REFERENCE_MNT" || die "reference mount absent"
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  for ep in 10.20.1.150:20180 10.20.1.151:20180 10.20.1.152:20180; do
    curl -fsS --connect-timeout 3 --max-time 5 "http://$ep/metrics" >/dev/null || die "TiKV metrics unavailable: $ep"
  done
  CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json" || die "Ceph status unavailable"
  python3 - "$out/ceph-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
if d.get('health',{}).get('status') != 'HEALTH_OK':
    raise SystemExit('Ceph health is not HEALTH_OK')
pg=d.get('pgmap',{})
states=pg.get('pgs_by_state',[])
if not states or any(x.get('state_name') != 'active+clean' for x in states):
    raise SystemExit(f'PG state is not wholly active+clean: {states}')
PY
  nic=$(ceph_nic)
  [[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes ]] || die "Ceph NIC unavailable"
  for ep in 10.3.1.7 10.3.1.8; do
    route_nic=$(ip route get "$ep" | awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }')
    [[ $route_nic == "$nic" ]] || die "Ceph OSD routes use different NICs: $nic/$route_nic"
  done
  printf '%s\n' "$nic" >"$out/ceph-data-nic.txt"
}

mount_process_gate() {
  local cache_arg=
  [[ -n $CACHE_DIR ]] && cache_arg=$CACHE_DIR
  if ! python3 - "$JFS" "$CELL_ROOT/mount-pids-pre.txt" "$cache_arg" "$TIER_MIB" "$METRICS_ADDR" <<'PY'
import os, sys
exe, pre_file, cache, tier, metrics = sys.argv[1:]
exe = os.path.realpath(exe)
pre = {int(x) for x in open(pre_file) if x.strip().isdigit()}
rows = []
for p in os.listdir('/proc'):
    if not p.isdigit():
        continue
    try:
        if os.path.realpath(f'/proc/{p}/exe') != exe:
            continue
        if int(p) in pre:
            continue
        cmd = open(f'/proc/{p}/cmdline', 'rb').read().replace(b'\0', b' ').decode(errors='replace').strip()
        stat = open(f'/proc/{p}/stat').read().split()
        rows.append((int(p), int(stat[3]), int(stat[21]), cmd))
    except (OSError, ValueError):
        pass
if len(rows) != 2:
    raise SystemExit(f'expected parent/worker pair, got {[x[:2] for x in rows]}')
pids = {x[0] for x in rows}
workers = [x for x in rows if x[1] in pids]
if len(workers) != 1:
    raise SystemExit(f'worker topology mismatch: {[x[:2] for x in rows]}')
cmd = workers[0][3]
required = ['--read-only', '--max-uploads 150', '--max-fuse-io 256K', f'--metrics {metrics}']
for forbidden in ('--writeback', '--prefetch', '--max-readahead'):
    if forbidden in cmd:
        raise SystemExit(f'forbidden mount option: {forbidden}')
if cache:
    required += [f'--cache-dir {cache}', f'--cache-size {tier}', '--free-space-ratio 0.20']
    if '--writeback' in cmd:
        raise SystemExit('writeback is forbidden')
else:
    required += ['--cache-size 0']
    if '--cache-dir' in cmd:
        raise SystemExit('cache-dir present on A0')
missing = [x for x in required if x not in cmd]
if missing:
    raise SystemExit(f'mount argv missing: {missing}')
print('pid\tppid\tstarttime\tselected_worker\tcmdline')
for row in sorted(rows):
    print(row[0], row[1], row[2], int(row[0] == workers[0][0]), row[3], sep='\t')
PY
  then
    return 1
  fi
  grep -Fq 'JuiceFS:juicefs-prod ' "$CELL_ROOT/jfs-findmnt.tsv" || die "mounted volume identity mismatch"
  local metrics
  metrics=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die "mount metrics unavailable"
  grep -Fq 'vol_name="juicefs-prod"' <<<"$metrics" || die "metrics volume label mismatch"
  grep -Fq "mp=\"$JFS_MNT\"" <<<"$metrics" || die "metrics mount label mismatch"
}

jfs_process_gone() {
  python3 - "$JFS" "$CELL_ROOT/mount-process.tsv" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
with open(sys.argv[2], newline='') as f:
    rows=list(csv.DictReader(f, delimiter='\t'))
if len(rows) != 2:
    raise SystemExit('invalid frozen mount-process evidence')
for row in rows:
    pid=row['pid']
    try:
        actual_exe=os.path.realpath(f'/proc/{pid}/exe')
        actual_start=open(f'/proc/{pid}/stat').read().split()[21]
    except OSError:
        continue
    if actual_exe == exe and actual_start == row['starttime']:
        raise SystemExit(1)
PY
}

snapshot_metrics() {
  local label=$1 file=$2 text
  curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$file"
  require_metrics "$file"
  if [[ -n $CACHE_DIR ]]; then
    find "$CACHE_DIR" -xdev -type f -printf '%s\n' 2>/dev/null | awk '{ n++; s += $1 } END { printf "files=%d\tbytes=%d\n", n+0, s+0 }' >"$CELL_ROOT/cache-usage-$label.tsv"
  else
    printf 'files=0\tbytes=0\n' >"$CELL_ROOT/cache-usage-$label.tsv"
  fi
}

sample_runtime() {
  local stop=$1 out=$2 nic=$3 metrics
  printf 'epoch_ns\tdf_used\tdf_avail\trx_bytes\ttx_bytes\tcache_bytes\tcache_blocks\thit_bytes\tmiss_bytes\tevicts\tdrops\n' >"$out"
  while [[ ! -f $stop ]]; do
    metrics=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date +%s%N)" \
      "$(df -B1 --output=used "$CACHE_PARENT" | awk 'NR==2{print $1}')" \
      "$(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')" \
      "$(cat "/sys/class/net/$nic/statistics/rx_bytes")" \
      "$(cat "/sys/class/net/$nic/statistics/tx_bytes")" \
      "$(metric_value "$metrics" juicefs_blockcache_bytes)" \
      "$(metric_value "$metrics" juicefs_blockcache_blocks)" \
      "$(metric_value "$metrics" juicefs_blockcache_hit_bytes)" \
      "$(metric_value "$metrics" juicefs_blockcache_miss_bytes)" \
      "$(metric_value "$metrics" juicefs_blockcache_evicts)" \
      "$(metric_value "$metrics" juicefs_blockcache_drops)" >>"$out"
    sleep 1
  done
}

write_jobfile() {
  local out=$1 i
  if [[ $ITEM == mseqread ]]; then
    cat >"$out" <<EOF
[global]
rw=read
refill_buffers=1
bs=256k
ioengine=psync
iodepth=1
direct=1
size=4G
time_based=1
runtime=180
allow_file_create=0
create_on_open=0
EOF
    for i in $(seq 0 15); do
      printf '\n[mseqread_%03d]\nfilename=%s/test_dir/mseqread/mseqread.%d.0\n' "$i" "$JFS_MNT" "$i" >>"$out"
    done
    return
  fi
  cat >"$out" <<EOF
[global]
rw=randread
bs=256k
ioengine=libaio
iodepth=128
direct=1
filesize=1G
size=1G
openfiles=128
time_based=1
runtime=180
randseed=41001
fallocate=none
allow_file_create=0
create_on_open=0
EOF
  for i in $(seq 0 127); do
    printf '\n[read_test_%03d]\nfilename=%s/test_dir/read_test.%d.0\n' "$i" "$JFS_MNT" "$i" >>"$out"
  done
}

run_fio() {
  local out=$1
  mkdir -m 0700 -p "$out/bw"
  write_jobfile "$out/$ITEM.fio"
  local -a cmd=(fio --readonly "$out/$ITEM.fio" --output-format=json --output="$out/fio.json"
    --write_bw_log="$out/bw/$ITEM" --log_avg_msec=1000 --per_job_logs=1)
  printf '%q ' "${cmd[@]}" >>"$CELL_ROOT/commands.sh"; printf '\n' >>"$CELL_ROOT/commands.sh"
  if timeout 240 "${cmd[@]}"; then
    printf '0\n' >"$out/fio.rc"
  else
    local rc=$?; printf '%s\n' "$rc" >"$out/fio.rc"; return "$rc"
  fi
  python3 - "$out/fio.json" "$JOBS" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
expected=int(sys.argv[2])
jobs=d.get('jobs', [])
if len(jobs) != expected:
    raise SystemExit(f'expected {expected} fio jobs, got {len(jobs)}')
if any(int(j.get('error', -1)) != 0 for j in jobs):
    raise SystemExit('fio job error')
PY
}

mount_jfs() {
  [[ ! -e $JFS_MNT ]] || die "JuiceFS mount path exists"
  mkdir -m 0700 "$JFS_MNT"
  [[ -r $CEPH_CONF && $(md5sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die "private CEPH_CONF identity mismatch"
  local -a cmd=("$JFS" mount -d --read-only --max-uploads 150 --max-fuse-io 256K)
  if [[ -n $CACHE_DIR ]]; then
    [[ -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die "cache directory missing"
    [[ -z $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "cache directory not empty"
    cmd+=(--cache-dir "$CACHE_DIR" --cache-size "$TIER_MIB" --free-space-ratio 0.20)
  else
    cmd+=(--cache-size 0)
  fi
  cmd+=(--metrics "$METRICS_ADDR" "$META" "$JFS_MNT")
  python3 - "$JFS" >"$CELL_ROOT/mount-pids-pre.txt" <<'PY'
import os,sys
exe=os.path.realpath(sys.argv[1])
for p in sorted((x for x in os.listdir('/proc') if x.isdigit()), key=int):
    try:
        if os.path.realpath(f'/proc/{p}/exe') == exe:
            print(p)
    except OSError:
        pass
PY
  printf 'env CEPH_CONF=%q ' "$CEPH_CONF" >>"$CELL_ROOT/commands.sh"; printf '%q ' "${cmd[@]}" >>"$CELL_ROOT/commands.sh"; printf '\n' >>"$CELL_ROOT/commands.sh"
  if ! CEPH_CONF="$CEPH_CONF" "${cmd[@]}"; then die "JuiceFS mount failed"; fi
  local i
  for i in $(seq 1 120); do mountpoint -q "$JFS_MNT" && break; sleep 1; done
  mountpoint -q "$JFS_MNT" || die "JuiceFS mount timeout"
  findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/jfs-findmnt.tsv"
  mount_process_gate >"$CELL_ROOT/mount-process.tsv" || die "JuiceFS mount identity mismatch"
  local worker thread_count
  worker=$(awk -F '\t' '$4==1{print $1}' "$CELL_ROOT/mount-process.tsv")
  thread_count=$(grep -l '^msgr-worker' /proc/"$worker"/task/*/comm 2>/dev/null | wc -l || true)
  [[ $thread_count -eq 8 ]] || die "expected 8 msgr-worker threads, got $thread_count"
  printf 'worker_pid\t%s\nmsgr_worker_threads\t%s\nceph_conf_md5\t%s\n' "$worker" "$thread_count" \
    "$(md5sum "$CEPH_CONF" | awk '{print $1}')" >"$CELL_ROOT/delivery-config.tsv"
}

unmount_jfs() {
  printf '%q umount %q\n' "$JFS" "$JFS_MNT" >>"$CELL_ROOT/commands.sh"
  "$JFS" umount "$JFS_MNT" >"$CELL_ROOT/umount.stdout" 2>"$CELL_ROOT/umount.stderr" || die "JuiceFS umount failed"
  local i
  for i in $(seq 1 180); do ! mountpoint -q "$JFS_MNT" && break; sleep 1; done
  ! mountpoint -q "$JFS_MNT" || die "JuiceFS mount remains"
  for i in $(seq 1 60); do jfs_process_gone && break; sleep 1; done
  jfs_process_gone || die "JuiceFS process remains"
}

cleanup_cache_cell() {
  [[ -n $CACHE_DIR ]] || return 0
  [[ $CACHE_DIR == "$CACHE_ROOT/cache-$CELL" && $CACHE_DIR != / && ! -L $CACHE_DIR ]] || die "cleanup path guard"
  [[ -d $CACHE_DIR ]] || die "cache directory missing during cleanup"
  [[ -z $(findmnt -rn -M "$CACHE_DIR" -o TARGET 2>/dev/null) ]] || die "cache directory is a mountpoint"
  find "$CACHE_DIR" -xdev -depth -mindepth 1 -delete
  [[ -z $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "cache directory not empty"
  rmdir "$CACHE_DIR"
}

cmd_inventory() {
  valid_run
  [[ ! -e $ROOT ]] || die "result root already exists"
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die "cache parent missing"
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans"
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die "binary identity mismatch"
  "$JFS" --version >"$ROOT/inventory/juicefs-version.txt"
  cp /etc/ceph/ceph.conf "$CEPH_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  [[ $(md5sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die "private CEPH_CONF does not match frozen delivery config"
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-mount.tsv"
  for ITEM in mseqread randread; do
    if [[ $ITEM == mseqread ]]; then JOBS=16; FILE_BYTES=4294967296; else JOBS=128; FILE_BYTES=1073741824; fi
    asset_manifest "$ROOT/inventory/assets-$ITEM.tsv" "$REFERENCE_MNT"
  done
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die "cache parent is not ext4"
  df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"
  df -i "$CACHE_PARENT" >"$ROOT/inventory/cache-dfi.tsv"
  stat -Lc 'path=%n dev=%d inode=%i mode=%a uid=%u gid=%g type=%F' "$CACHE_PARENT" >"$ROOT/inventory/cache-stat.tsv"
  find "$CACHE_PARENT" -mindepth 1 -maxdepth 1 -printf '%y\t%p\t%s\t%u\t%g\n' | sort >"$ROOT/inventory/cache-parent-entries.tsv"
  ip route get 10.3.1.6 >"$ROOT/inventory/ceph-route-10.3.1.6.txt"
  ip route get 10.3.1.7 >"$ROOT/inventory/ceph-route-10.3.1.7.txt"
  ip route get 10.3.1.8 >"$ROOT/inventory/ceph-route-10.3.1.8.txt"
  ceph_nic >"$ROOT/inventory/ceph-data-nic.txt"
  [[ -s $ROOT/inventory/ceph-data-nic.txt && -r /sys/class/net/$(<"$ROOT/inventory/ceph-data-nic.txt")/statistics/rx_bytes ]] || die "Ceph NIC unavailable"
  ss -lntp >"$ROOT/inventory/listeners.tsv" 2>&1 || true
  local port
  port=$(printf '%s\n' "$METRICS_ADDR" | awk -F: '{print $NF}')
  ! awk -v p=":$port" '$4 ~ p"$"{found=1} END{exit found?0:1}' "$ROOT/inventory/listeners.tsv" || die "metrics port occupied"
  if pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1; then die "foreign fio exists"; fi
  [[ ! -e $CACHE_ROOT ]] || die "RUN cache root already exists"
  CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$ROOT/inventory/ceph-status.json" || die "Ceph status unavailable"
  for ITEM in mseqread randread; do
    for point in A0-pre C25 C50 C75 C100 C200 A0-post; do
      CELL=$ITEM-$point; cell_fields
      [[ ! -e $JFS_MNT && ! -e $CELL_ROOT ]] || die "cell path already exists: $CELL"
    done
  done
  printf 'INVENTORY_PASS\n' >"$ROOT/inventory/PASS"
  printf '04TMP2D_INVENTORY_PASS root=%s\n' "$ROOT"
}

cmd_plan() {
  valid_run
  [[ -f $ROOT/inventory/PASS ]] || die "inventory PASS missing"
  cat >"$ROOT/plans/cells.tsv" <<EOF
cell	item	cache_mib	cache_fraction	cache_dir
mseqread-A0-pre	mseqread	0	0	NONE
mseqread-C25	mseqread	16384	0.25	RUN/cache-mseqread-C25
mseqread-C50	mseqread	32768	0.50	RUN/cache-mseqread-C50
mseqread-C75	mseqread	49152	0.75	RUN/cache-mseqread-C75
mseqread-C100	mseqread	65536	1.00	RUN/cache-mseqread-C100
mseqread-C200	mseqread	131072	2.00	RUN/cache-mseqread-C200
mseqread-A0-post	mseqread	0	0	NONE
randread-A0-pre	randread	0	0	NONE
randread-C25	randread	32768	0.25	RUN/cache-randread-C25
randread-C50	randread	65536	0.50	RUN/cache-randread-C50
randread-C75	randread	98304	0.75	RUN/cache-randread-C75
randread-C100	randread	131072	1.00	RUN/cache-randread-C100
randread-C200	randread	262144	2.00	RUN/cache-randread-C200
randread-A0-post	randread	0	0	NONE
EOF
  cat >"$ROOT/plans/sudo-contract.txt" <<EOF
# Printed plan only; this driver never executes sudo.
sudo install -d -m 0700 -o 1002 -g 1002 $CACHE_ROOT
sudo rmdir $CACHE_ROOT
EOF
  printf 'mseqread-A0-pre,mseqread-C25,mseqread-C50,mseqread-C75,mseqread-C100,mseqread-C200,mseqread-A0-post,randread-A0-pre,randread-C25,randread-C50,randread-C75,randread-C100,randread-C200,randread-A0-post\n' >"$ROOT/plans/matrix-order.txt"
  sha256sum "$0" "$(dirname "$0")/t04tmp2d-cache-analyze.py" "$(dirname "$0")/t04tmp2d-cache-gate0-offline.sh" >"$ROOT/plans/scripts.sha256"
  printf 'PLAN_PASS\n' >"$ROOT/plans/PASS"
  printf '04TMP2D_PLAN_PASS root=%s\n' "$ROOT"
}

cmd_run_cell() {
  valid_run; validate_cell_paths
  [[ ${TMP2D_ACK:-} == "I_ACK_04TMP2D_$RUN_ID" ]] || die "exact execution ACK missing"
  [[ -f $ROOT/plans/PASS ]] || die "plan PASS missing"
  sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die "script drift"
  [[ ! -e $CELL_ROOT ]] || die "cell evidence exists"
  mkdir -m 0700 -p "$CELL_ROOT/health-pre" "$CELL_ROOT/health-post"
  if pgrep -a -x fio >"$CELL_ROOT/foreign-fio-pre.tsv" 2>&1; then die "foreign fio exists"; fi
  verify_runtime_health "$CELL_ROOT/health-pre"
  if [[ -n $CACHE_DIR ]]; then
    [[ -d $CACHE_ROOT && ! -L $CACHE_ROOT ]] || die "RUN cache root unavailable"
    [[ $(stat -Lc %u "$CACHE_ROOT") -eq $EXPECTED_UID && $(stat -Lc %g "$CACHE_ROOT") -eq $EXPECTED_GID && $(stat -Lc %a "$CACHE_ROOT") == 700 ]] || die "RUN root identity mismatch"
    [[ -z $(find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 ! -name "cache-$CELL" -print -quit) ]] || die "foreign RUN cache entry"
    mkdir -m 0700 "$CACHE_DIR"
  fi
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS) == $(<"$ROOT/inventory/cache-parent.freeze") ]] || die "cache parent identity drift"
  printf 'run_id\t%s\ncell\t%s\ncache_dir\t%s\njfs_mount\t%s\ncache_mib\t%s\n' \
    "$RUN_ID" "$CELL" "${CACHE_DIR:-NONE}" "$JFS_MNT" "$TIER_MIB" >"$CELL_ROOT/state.tsv"
  asset_manifest "$CELL_ROOT/assets-pre.tsv" "$REFERENCE_MNT"
  mount_jfs
  snapshot_metrics mounted "$CELL_ROOT/metrics-mounted.txt"
  if [[ -n $CACHE_DIR ]]; then
    run_fio "$CELL_ROOT/warmup"
    snapshot_metrics warmed "$CELL_ROOT/metrics-warmed.txt"
  fi
  local nic stop sampler_pid fio_rc sampler_rc
  nic=$(<"$CELL_ROOT/health-pre/ceph-data-nic.txt")
  stop=$CELL_ROOT/sampler.stop
  sample_runtime "$stop" "$CELL_ROOT/runtime.tsv" "$nic" >"$CELL_ROOT/sampler.stdout" 2>"$CELL_ROOT/sampler.stderr" &
  sampler_pid=$!
  if run_fio "$CELL_ROOT/formal"; then fio_rc=0; else fio_rc=$?; fi
  : >"$stop"
  if wait "$sampler_pid"; then sampler_rc=0; else sampler_rc=$?; fi
  printf '%s\n' "$sampler_rc" >"$CELL_ROOT/sampler.rc"
  (( fio_rc == 0 && sampler_rc == 0 )) || die "formal or sampler failed"
  if grep -Eq $'\tNA(\t|$)' "$CELL_ROOT/runtime.tsv"; then die "runtime metrics unavailable"; fi
  snapshot_metrics formal "$CELL_ROOT/metrics-formal.txt"
  asset_manifest "$CELL_ROOT/assets-post.tsv" "$JFS_MNT"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post.tsv" || die "asset identity drift"
  verify_runtime_health "$CELL_ROOT/health-post"
  unmount_jfs
  cleanup_cache_cell
  printf 'CELL_PASS\t%s\n' "$CELL" >"$CELL_ROOT/PASS"
  printf '04TMP2D_CELL_PASS cell=%s\n' "$CELL"
}

cmd_inspect_cell() {
  valid_run; validate_cell_paths
  printf 'CELL=%s\nJFS_MNT=%s\nCACHE_DIR=%s\n' "$CELL" "$JFS_MNT" "$CACHE_DIR"
  [[ ! -f $CELL_ROOT/state.tsv ]] || sed -n '1,80p' "$CELL_ROOT/state.tsv"
  findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
  [[ -z $CACHE_DIR || ! -e $CACHE_DIR ]] || find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -printf '%y\t%p\n'
}

cmd_offline_self_test() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "offline RUN_ID invalid"
  local cells='mseqread-A0-pre mseqread-C25 mseqread-C50 mseqread-C75 mseqread-C100 mseqread-C200 mseqread-A0-post randread-A0-pre randread-C25 randread-C50 randread-C75 randread-C100 randread-C200 randread-A0-post' cell count=0
  for cell in $cells; do CELL=$cell; cell_fields; validate_cell_paths; count=$((count+1)); done
  [[ $count -eq 14 ]] || die "matrix contract mismatch"
  printf '04TMP2D_OFFLINE_SELF_TEST_PASS cells=%s mseqread_workset_gib=64 randread_workset_gib=128\n' "$count"
}

case $MODE in
  offline-self-test) cmd_offline_self_test ;;
  inventory) cmd_inventory ;;
  plan) cmd_plan ;;
  run-cell) cmd_run_cell ;;
  inspect-cell) cmd_inspect_cell ;;
  *) printf 'usage: %s offline-self-test|inventory|plan|run-cell|inspect-cell RUN_ID [CELL]\n' "$0"; exit 2 ;;
esac
