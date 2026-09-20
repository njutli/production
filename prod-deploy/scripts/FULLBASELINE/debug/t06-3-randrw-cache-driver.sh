#!/bin/bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077
# OFFLINE PREPARATION ONLY. plan never grants online authority.
THIS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LEGACY_SHA256=4a0d104322fbe9d7b790842866d242133082a358f0f3b1acb799bac593be1336
LEGACY=$THIS_DIR/t06-1-randrw-cache-driver.sh
[[ -f $LEGACY && ! -L $LEGACY ]] || { echo 'legacy_missing' >&2; exit 42; }
LEGACY_PREFIX=$(python3 - "$LEGACY" "$LEGACY_SHA256" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
if hashlib.sha256(b).hexdigest()!=sys.argv[2]:raise SystemExit('frozen_dependency_drift')
boundary=b'\ncase $MODE in\n'
if b.count(boundary)!=1:raise SystemExit('legacy_dispatch_boundary_drift')
prefix,dispatch=b.split(boundary)
expected=b"""  --self-test) offline_self_test ;;
  plan) valid_run; write_plans "$PLAN_OUT"; printf 'T061_PLAN_ONLY_PASS\\troot=%s\\n' "$PLAN_OUT" ;;
  phase-a) phase_a ;;
  *) printf 'usage: %s --self-test|plan|phase-a RUN_ID\\n' "$0" >&2; exit 2 ;;
esac
"""
if dispatch!=expected:raise SystemExit('legacy_dispatch_changed')
print(prefix.decode())
PY
) || exit 42
# Exact frozen prefix contains assignments and function definitions only.
eval "$LEGACY_PREFIX"
unset LEGACY_PREFIX
unset -f phase_a recovery_gate offline_self_test write_plans require_online_ack
SCRIPT_DIR=$THIS_DIR
MODE=${1:-}; RUN_ID=${2:-}
ROOT=/tmp/production/opencode-06-3-$RUN_ID
PLAN_OUT=${T063_PLAN_OUT:-/tmp/t06-3-plan-$RUN_ID}
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
ANALYZER=$SCRIPT_DIR/t06-3-randrw-analyze.py
GATE0=$SCRIPT_DIR/t06-3-gate0-offline.sh
readonly CACHE_PARENT=/mnt/jfs-cache/04tmp3
CONTRACT=${T063_CONTRACT:-}
METRICS_BASE=19630
ACTIVE_FIO_PID=; ACTIVE_FIO_TICKS=; ACTIVE_FIO_EXE=
SCRUB_ACTIVE=0; SAMPLERS_RUNNING=0
QUIET_DIRTY_LIMIT=; QUIET_WRITEBACK_LIMIT=
CELL_START_AVAIL=; CELL_MAX_ALLOC=
die() { printf 'T063_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ && $ROOT == /tmp/production/opencode-06-3-$RUN_ID && ! -L $ROOT ]] || die invalid_RUN_ID_or_root
}
matrix_rows() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    1 C1 C 0 0 0 2 S1 S 98304 1 0 3 W1 W 98304 1 1 \
    4 W2 W 98304 1 1 5 S2 S 98304 1 0 6 C2 C 0 0 0
}
contract_value() {
  python3 - "$CONTRACT" "$1" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):v=v[k]
print(json.dumps(v,separators=(',',':')) if isinstance(v,(list,dict)) else v)
PY
}
validate_contract() {
  python3 - "$CONTRACT" "$RUN_ID" "$META" <<'PY'
import json,re,sys
def pairs(xs):
 d={}
 for k,v in xs:
  if k in d:raise ValueError('duplicate contract key:'+k)
  d[k]=v
 return d
d=json.load(open(sys.argv[1]),object_pairs_hook=pairs)
def need(ok,k):
 if not ok:raise SystemExit('contract_'+k)
need(d['schema']=='06-3-v1' and d['status']=='APPROVED','approval')
need(d['run_id']==sys.argv[2] and d['meta']==sys.argv[3],'run_meta')
for k in ('hostname','machine_id','ceph_fsid','volume_uuid','fio_version','cache_source','cache_major_minor','cache_fstype','cache_filesystem_uuid','cache_mount_target','cache_mount_options','cache_physical_leaf_devices'):
 need(isinstance(d[k],str) and bool(d[k]) and '\n' not in d[k] and '\t' not in d[k],k)
need(re.fullmatch('[0-9a-f]{64}',d['assets_sha256']) is not None,'asset_hash')
need(re.fullmatch('[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',d['volume_uuid']) is not None,'volume_uuid')
need(d['cache_parent']=='/mnt/jfs-cache/04tmp3' and d['cache_exclusive_use'] is True,'cache_exclusive_use')
need(d['no_concurrent_benchmark'] is True,'business_approval')
need(isinstance(d['approved_osd_flags'],list) and not any(x in d['approved_osd_flags'] for x in ('noscrub','nodeep-scrub','noout','nobackfill','norecover','pause','pauserd','pausewr')),'osd_flags')
for k in ('cache_owner_uid','cache_owner_gid','cache_mode'):need(type(d[k]) is int and d[k]>=0,k)
s=d['space']
for k in ('read_cache_bytes','worst_backlog_bytes','filesystem_reserve_bytes','business_reserve_bytes','stop_margin_bytes','max_ingress_bytes_per_sec','stop_latency_seconds','monitor_interval_seconds','minimum_start_avail_bytes','minimum_mem_available_bytes','max_fio_wall_seconds'):
 need(type(s[k]) is int and s[k]>0,'space_'+k)
need(s['read_cache_bytes']==96*2**30,'cache_budget')
need(s['monitor_interval_seconds']==1 and 1<=s['stop_latency_seconds']<=30,'monitor_interval')
# Nine seconds includes worst bounded synchronous health probes and polling.
need(s['stop_margin_bytes']>=s['max_ingress_bytes_per_sec']*(9+s['stop_latency_seconds']),'stop_margin')
# worst_backlog_bytes is the approved stage occupancy ceiling, enforced from
# per-cell available-byte deltas. If reached, stop the fio instead of assuming
# the historical PUT rate will keep up for the entire 180-second interval.
need(s['worst_backlog_bytes']>=s['max_ingress_bytes_per_sec']*(9+s['stop_latency_seconds']),'backlog_cap_smaller_than_stop_reaction')
need(s['minimum_start_avail_bytes']>=sum(s[k] for k in ('read_cache_bytes','worst_backlog_bytes','filesystem_reserve_bytes','business_reserve_bytes','stop_margin_bytes')),'start_space')
need(180<=s['max_fio_wall_seconds']<=3600,'wall_guard')
need(len(d['protected_processes'])>=2,'protected_business_inventory')
for p in d['protected_processes']:
 need(type(p['pid']) is int and p['pid']>1 and type(p['starttime_ticks']) is int and p['starttime_ticks']>0 and str(p['exe']).startswith('/'),'protected_process')
need(d['metrics']['pending']=='UNREGISTERED','metric_pending_registration')
for k in ('uploading','staging_errors'):
 need(re.fullmatch('[A-Za-z_:][A-Za-z0-9_:]*',d['metrics'][k]) is not None,'metric_'+k)
need(type(d['metrics']['error_counter_absent_is_zero']) is bool,'error_registration')
PY
}
no_symlink_components() {
  python3 - "$1" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
if not p.is_absolute() or '..' in p.parts or str(p)=='/':raise SystemExit('unsafe_path')
if any(q.is_symlink() for q in (p,*p.parents)):raise SystemExit('symlink_component')
PY
}
require_online_ack() {
  valid_run
  [[ ${T063_EXECUTE_ACK:-} == I_ACK_06_3_PHASE_$RUN_ID ]] || die execute_ack_missing
  [[ ${T063_PATH_ACK:-} == I_ACK_06_3_CACHE_PATHS_$RUN_ID ]] || die path_ack_missing
  [[ ${T063_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
  [[ -f $CONTRACT && ! -L $CONTRACT ]] || die contract_missing
  local kind file expected
  for kind in DRIVER ANALYZER GATE0 SCRUB CONTRACT; do
    case $kind in DRIVER) file=$0;; ANALYZER) file=$ANALYZER;; GATE0) file=$GATE0;; SCRUB) file=$SCRUB;; CONTRACT) file=$CONTRACT;; esac
    expected=T063_${kind}_SHA256; expected=${!expected:-}
    [[ $expected =~ ^[0-9a-f]{64}$ && -f $file && ! -L $file ]] || die frozen_dependency_missing_$kind
    [[ $(sha256sum "$file" | awk '{print $1}') == "$expected" ]] || die frozen_dependency_drift_$kind
  done
  validate_contract || die contract_rejected
  [[ $(hostname) == "$(contract_value hostname)" && $(</etc/machine-id) == "$(contract_value machine_id)" ]] || die host_identity
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die binary_identity
  [[ $(fio --version) == "$(contract_value fio_version)" ]] || die fio_identity
  EXPECTED_FSID=$(contract_value ceph_fsid)
  STOP_LATENCY=$(contract_value space.stop_latency_seconds)
  MAX_FIO_WALL=$(contract_value space.max_fio_wall_seconds)
  MIN_START_AVAIL=$(contract_value space.minimum_start_avail_bytes)
  MIN_MEM_AVAIL=$(contract_value space.minimum_mem_available_bytes)
  CELL_MAX_ALLOC=$(python3 - "$CONTRACT" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))['space'];print(s['read_cache_bytes']+s['worst_backlog_bytes'])
PY
)
  STOP_AVAIL=$(python3 - "$CONTRACT" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))['space'];print(sum(s[k] for k in ('filesystem_reserve_bytes','business_reserve_bytes','stop_margin_bytes')))
PY
)
}
validate_parent() {
  [[ $1 == "$CACHE_PARENT" ]] || die cache_parent_not_exact
  no_symlink_components "$1" || die cache_parent_symlink
  [[ -d $1 && -w $1 ]] || die cache_parent_unavailable
  local source major fstype target options physical uuid device uid gid mode system_source system_device system_leaves
  read -r source major fstype target options < <(findmnt -bnr -T "$1" -o SOURCE,MAJ:MIN,FSTYPE,TARGET,OPTIONS) || die cache_findmnt
  device=${source%%[*}
  physical=$(lsblk -snro KNAME "$device" | tail -1) || die cache_device
  [[ $device != /dev/md* && $physical =~ ^nvme[0-9]+n[0-9]+$ && $target != / && $target != /boot && $target != /boot/efi ]] || die protected_or_nonNVMe_device
  system_source=$(findmnt -bnr -T / -o SOURCE) || die system_device_unknown
  system_device=${system_source%%[*}
  system_leaves=$(lsblk -snro KNAME "$system_device") || die system_leaf_unknown
  if grep -Fxq "$physical" <<<"$system_leaves"; then die cache_is_system_disk; fi
  uuid=$(lsblk -dnro UUID "$device") || die cache_uuid
  read -r uid gid mode < <(stat -Lc '%u %g %a' "$1") || die cache_stat
  python3 - "$CONTRACT" "$source" "$major" "$fstype" "$target" "$options" "$physical" "$uuid" "$uid" "$gid" "$mode" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
keys=('cache_source','cache_major_minor','cache_fstype','cache_mount_target','cache_mount_options','cache_physical_leaf_devices','cache_filesystem_uuid','cache_owner_uid','cache_owner_gid','cache_mode')
for k,v in zip(keys,sys.argv[2:]):
 if str(d[k])!=v:raise SystemExit('cache_identity_drift:'+k)
if d['cache_fstype'] in ('tmpfs','overlay','fuse.juicefs'):raise SystemExit('non_physical_cache')
PY
}
cache_dirs_for_cell() {
  [[ $1 =~ ^[SW][12]$ ]] || die invalid_cache_cell
  validate_parent "$CACHE_PARENT"
  printf '%s/jfs-06-3-%s-%s\n' "$CACHE_PARENT" "$RUN_ID" "$1"
}
cache_tree_guard() {
  [[ $1 =~ ^[SW][12]$ && $2 == "$CACHE_PARENT/jfs-06-3-$RUN_ID-$1" ]] || die unsafe_cache_child
  validate_parent "$CACHE_PARENT"
  no_symlink_components "$2" || die cache_child_symlink
  python3 - "$2" <<'PY'
import os,re,sys
p=sys.argv[1]
for l in open('/proc/self/mountinfo'):
 m=re.sub(r'\\([0-7]{3})',lambda m:chr(int(m[1],8)),l.split()[4])
 if m==p or m.startswith(p+'/'):raise SystemExit('cache_mount_subtree')
if os.path.exists(p):
 dev=os.stat(p).st_dev
 for root,ds,fs in os.walk(p,followlinks=False):
  for n in ds+fs:
   q=os.path.join(root,n)
   if os.path.islink(q) or os.lstat(q).st_dev!=dev:raise SystemExit('cache_tree_escape')
PY
}
create_cache_dirs() {
  cache_tree_guard "$1" "$2"
  [[ ! -e $2 ]] || die cache_child_exists
  event CACHE_CREATE_PRE "$2"; mkdir -m 0700 -- "$2"; event CACHE_CREATE_POST "$2"
}
cleanup_cache_dirs() {
  local cell=$1 dir=$2 c=$ROOT/cells/$1
  [[ -f $c/DRAIN_PASS && -f $c/READBACK_PASS && -f $c/UNMOUNTED_formal && -f $c/UNMOUNTED_verify ]] || die cleanup_lifecycle_incomplete
  cache_tree_guard "$cell" "$dir"
  [[ -d $dir ]] || die cleanup_missing
  event CACHE_CLEAN_PRE "$dir"
  find -P "$dir" -xdev -depth -mindepth 1 -delete
  rmdir -- "$dir"; event CACHE_CLEAN_POST "$dir"
}
verify_assets() {
  local base=$1 out=$2
  [[ -d $base/test_dir && ! -L $base/test_dir ]] || die asset_directory
  find -P "$base/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$out"
  python3 - "$out" <<'PY'
import sys
r=[x.rstrip('\n').split('\t') for x in open(sys.argv[1])]
if len(r)!=128 or {x[0] for x in r}!={f'rw_test.{i}.0' for i in range(128)}:raise SystemExit('asset_names')
if any(int(x[2])!=1073741824 for x in r) or len({x[1] for x in r})!=128:raise SystemExit('asset_size_or_alias')
PY
  [[ $(sha256sum "$out" | awk '{print $1}') == "$(contract_value assets_sha256)" ]] || die frozen_assets_drift
}
volume_identity() {
  python3 - "$1/.config" "$(contract_value volume_uuid)" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));f=d.get('Format',d)
if f.get('UUID')!=sys.argv[2] or f.get('Name')!='juicefs-prod' or f.get('BlockSize')!=256:raise SystemExit('volume_identity_or_B256')
# Never copy .config: it may carry credentials.
PY
}
health_validate() {
  python3 - "$1" "$CONTRACT" "$SCRUB_ACTIVE" <<'PY'
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]);d=json.load(open(sys.argv[2]));paused=sys.argv[3]=='1'
s=json.load(open(p/'ceph-status.json'));o=json.load(open(p/'osd-stat.json'));od=json.load(open(p/'osd-dump.json'))
if s.get('fsid')!=d['ceph_fsid']:raise SystemExit('ceph_fsid_drift')
flags=od.get('flags',[])
if isinstance(flags,str):flags=flags.split(',')
flags={x.strip().replace('nodeep_scrub','nodeep-scrub') for x in flags if x.strip()}
expected=set(d['approved_osd_flags'])|({'noscrub','nodeep-scrub'} if paused else set())
if flags!=expected:raise SystemExit('osd_flags_drift')
h=s.get('health',{});checks=h.get('checks',{});status=h.get('status')
if status=='HEALTH_OK' and not checks:pass
elif paused and status=='HEALTH_WARN' and set(checks)=={'OSDMAP_FLAGS'}:
 msg=checks['OSDMAP_FLAGS'].get('summary',{}).get('message','');m=re.fullmatch(r'(.+?) flag\(s\) set',msg)
 if not m or {x.strip().replace('nodeep_scrub','nodeep-scrub') for x in m[1].split(',')}!={'noscrub','nodeep-scrub'}:raise SystemExit('foreign_warning_flags')
else:raise SystemExit('unexpected_health')
if any(o.get(k)!=6 for k in ('num_osds','num_up_osds','num_in_osds')):raise SystemExit('osd_not_6_up_in')
states=[x.split()[1] for x in (p/'pgs.txt').read_text().splitlines() if re.match(r'^\s*\d+\.[0-9a-fA-F]+\s',x)]
if not states or any(x!='active+clean' for x in states):raise SystemExit('pg_not_clean')
PY
}
health_gate() {
  local out=$1
  mkdir -m 0700 -p "$out"
  timeout 2 ceph --conf "$CEPH_CONF" -s -f json >"$out/ceph-status.json" || die ceph_health
  timeout 2 ceph --conf "$CEPH_CONF" osd stat -f json >"$out/osd-stat.json" || die ceph_osd
  timeout 2 ceph --conf "$CEPH_CONF" osd dump -f json >"$out/osd-dump.json" || die ceph_flags
  timeout 2 ceph --conf "$CEPH_CONF" pg dump pgs_brief >"$out/pgs.txt" || die ceph_pg
  health_validate "$out" || die health_rejected
}
business_guard() {
  python3 - "$CONTRACT" "${ACTIVE_FIO_PID:-0}" <<'PY'
import json,os,pathlib,sys
d=json.load(open(sys.argv[1]));own=int(sys.argv[2] or 0)
def st(pid):
 s=pathlib.Path(f'/proc/{pid}/stat').read_text();return s[s.rfind(')')+2:].split()
for p in d['protected_processes']:
 try:
  if int(st(p['pid'])[19])!=p['starttime_ticks'] or os.path.realpath(f"/proc/{p['pid']}/exe")!=p['exe']:raise ValueError()
 except (OSError,ValueError):raise SystemExit('protected_business_changed')
def ours(pid):
 seen=set()
 while pid>1 and pid not in seen:
  if pid==own:return True
  seen.add(pid)
  try:pid=int(st(pid)[1])
  except OSError:return False
 return False
for p in pathlib.Path('/proc').glob('[0-9]*'):
 try:
  exe=os.path.basename(os.path.realpath(p/'exe'));cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')
  conflict=exe in ('fio','filebench','sysbench') or (exe.startswith('juicefs') and any(x in cmd for x in (' bench ',' benchmark ')))
  if conflict and not ours(int(p.name)):raise SystemExit('concurrent_benchmark:'+p.name)
 except OSError:pass
PY
}
resource_gate() {
  local avail mem threshold=$STOP_AVAIL
  [[ ${1:-no} != yes ]] || threshold=$MIN_START_AVAIL
  read -r avail < <(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}') || return 1
  mem=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024}' /proc/meminfo)
  awk -v a="$avail" -v m="$mem" -v t="$threshold" -v n="$MIN_MEM_AVAIL" \
      -v s="${CELL_START_AVAIL:-0}" -v c="${CELL_MAX_ALLOC:-0}" \
      'BEGIN{exit !(a>=t && m>=n && (s==0 || a+c>=s))}'
}
backend_snapshot() {
  local out=$1 node
  mkdir -m 0700 -p "$out"
  timeout 15 ceph --conf "$CEPH_CONF" df -f json >"$out/ceph-df.json" || die ceph_df
  timeout 20 ceph --conf "$CEPH_CONF" tell 'osd.*' perf dump -f json >"$out/osd-perf.json" 2>"$out/osd-perf.stderr" || event MECHANISM_DEGRADED osd_perf
  for node in 150 151 152; do
    curl -fsS --connect-timeout 3 --max-time 5 "http://10.20.1.$node:20180/metrics" >"$out/tikv-$node.prom" || event MECHANISM_DEGRADED tikv_$node
  done
}

mount_args() {
  local arm=$1 mnt=$2 metrics=$3 log=$4 dirs=$5
  MOUNT_CMD=("$JFS" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 --metrics "$metrics" --log "$log")
  case $arm in
    C) [[ -z $dirs ]] || die control_cache_dir; MOUNT_CMD+=(--cache-size 0);;
    S|W) [[ -n $dirs ]] || die cache_dir_required; MOUNT_CMD+=(--cache-dir "$dirs" --cache-size 98304 --free-space-ratio 0.20 --cache-large-write --upload-delay 0); [[ $arm != W ]] || MOUNT_CMD+=(--writeback);;
    *) die arm_not_mainline;;
  esac
  MOUNT_CMD+=("$META" "$mnt")
}
mount_pid_gate() {
  python3 - "$JFS" "$1" "$3" "$JFS_MD5" >"$2" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]);old={int(x) for x in open(sys.argv[2]) if x.strip().isdigit()};rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
 try:
  if int(p.name) in old or os.path.realpath(p/'exe')!=exe:continue
  cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
  if sys.argv[3] not in cmd:continue
  raw=(p/'stat').read_text();s=raw[raw.rfind(')')+2:].split()
  md5=hashlib.md5((p/'exe').read_bytes()).hexdigest()
  if md5!=sys.argv[4]:raise SystemExit('mount_binary_drift')
  rows.append((int(p.name),int(s[1]),int(s[19]),md5,cmd))
 except (OSError,ValueError,IndexError):pass
workers={r[0] for r in rows if r[1] in {x[0] for x in rows}}
if len(rows)!=2 or len(workers)!=1:raise SystemExit('non_unique_parent_worker')
print('pid\tppid\tstarttime_ticks\texe_md5\tis_worker\tcmdline')
for r in sorted(rows):print(*r[:4],'yes' if r[0] in workers else 'no',r[4],sep='\t')
PY
}
processes_gone() {
  python3 - "$1" <<'PY'
import csv,pathlib,sys
for r in csv.DictReader(open(sys.argv[1]),delimiter='\t'):
 try:
  raw=pathlib.Path('/proc/'+r['pid']+'/stat').read_text();s=raw[raw.rfind(')')+2:].split()
  if s[19]==r['starttime_ticks']:raise SystemExit(1)
 except FileNotFoundError:pass
PY
}
mount_private() {
  local cell=$1 arm=$2 tag=$3 mnt=$4 metrics=$5 dirs=$6 c=$ROOT/cells/$1
  [[ $cell =~ ^[CSW][12]$ && ( $tag == formal || $tag == verify ) ]] || die mount_tags
  local expected=/tmp/jfs-06-3-$RUN_ID-$cell
  [[ $tag == formal ]] || expected+=-verify
  [[ $mnt == "$expected" && ! -e $mnt && ! -L $mnt ]] || die private_mount_scope
  no_symlink_components "$mnt" || die mount_symlink
  [[ $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die binary_drift
  mkdir -m 0700 -- "$mnt"
  capture_preexisting_pids "$c/pids-$tag.before"
  mount_args "$arm" "$mnt" "$metrics" "$c/juicefs-$tag.log" "$dirs"
  printf '%q ' "${MOUNT_CMD[@]}" >"$c/mount-command-$tag.txt"; printf '\n' >>"$c/mount-command-$tag.txt"
  log_cmd env CEPH_CONF="$CEPH_CONF" "${MOUNT_CMD[@]}"
  env CEPH_CONF="$CEPH_CONF" "${MOUNT_CMD[@]}" >"$c/mount-$tag.stdout" 2>"$c/mount-$tag.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$c/findmnt-$tag.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$c/findmnt-$tag.tsv" || die mount_identity
  mount_pid_gate "$c/pids-$tag.before" "$c/mount-process-$tag.tsv" "$c/juicefs-$tag.log" || die mount_process_identity
  volume_identity "$mnt"
}
eval "$(declare -f graceful_umount | sed '1s/graceful_umount/legacy_graceful_umount/')"
graceful_umount() {
  local cell=$1 tag=$2 mnt=$3 expected=/tmp/jfs-06-3-$RUN_ID-$1
  [[ $tag == formal ]] || expected+=-verify
  [[ $mnt == "$expected" && ! -L $mnt ]] || die umount_scope
  [[ -f $ROOT/cells/$cell/DRAIN_PASS ]] || die undrained_umount_forbidden
  [[ $tag != verify || -f $ROOT/cells/$cell/READBACK_PASS ]] || die unread_verify_umount
  legacy_graceful_umount "$@"
  : >"$ROOT/cells/$cell/UNMOUNTED_$tag"
}
proc_ticks() {
  python3 - "$1" <<'PY'
import pathlib,sys
s=pathlib.Path('/proc/'+sys.argv[1]+'/stat').read_text();print(s[s.rfind(')')+2:].split()[19])
PY
}
stop_active_fio() {
  [[ -n $ACTIVE_FIO_PID ]] || return 0
  # Exact recorded fio tree only, revalidate start ticks/executable per signal.
  python3 - "$ACTIVE_FIO_PID" "$ACTIVE_FIO_TICKS" "$ACTIVE_FIO_EXE" "${STOP_LATENCY:-10}" <<'PY'
import os,pathlib,signal,sys,time
pid=int(sys.argv[1]);tick=sys.argv[2];exe=sys.argv[3]
def identity(p):
 try:
  s=pathlib.Path(f'/proc/{p}/stat').read_text();x=s[s.rfind(')')+2:].split()
  return int(x[1]),x[19],os.path.realpath(f'/proc/{p}/exe'),x[0]
 except OSError:return None
i=identity(pid)
if not i or i[1]!=tick or i[2]!=exe:raise SystemExit(0)
owned={pid:i};changed=True
while changed:
 changed=False
 for p in pathlib.Path('/proc').glob('[0-9]*'):
  n=int(p.name);j=identity(n)
  if n not in owned and j and j[0] in owned and j[2]==exe:owned[n]=j;changed=True
def alive(p,j):
 k=identity(p);return k and k[1:3]==j[1:3] and k[3]!='Z'
def send(sig):
 for p,j in sorted(owned.items(),reverse=True):
  if alive(p,j):
   try:os.kill(p,sig)
   except ProcessLookupError:pass
send(signal.SIGTERM)
deadline=time.monotonic()+int(sys.argv[4])
while time.monotonic()<deadline:
 if not any(alive(p,j) for p,j in owned.items()):break
 time.sleep(.2)
send(signal.SIGKILL)
PY
}
fio_checked() {
  local out=$1 cell=$2 seconds=$3 start now rc failed=0 avail mem
  log_cmd "$FIO" "$out/fio.job" --output="$out/fio.json" --output-format=json
  date +%s%N >"$out/fio-start-epoch-ns.txt"
  "$FIO" "$out/fio.job" --output="$out/fio.json" --output-format=json >"$out/fio.stdout" 2>"$out/fio.stderr" &
  ACTIVE_FIO_PID=$!
  ACTIVE_FIO_TICKS=$(proc_ticks "$ACTIVE_FIO_PID") || die fio_pid_unavailable
  ACTIVE_FIO_EXE=$(realpath "$(command -v "$FIO")")
  for _ in $(seq 1 50); do
    [[ $(realpath "/proc/$ACTIVE_FIO_PID/exe" 2>/dev/null || true) == "$ACTIVE_FIO_EXE" ]] && break
    sleep 0.02
  done
  [[ $(realpath "/proc/$ACTIVE_FIO_PID/exe" 2>/dev/null || true) == "$ACTIVE_FIO_EXE" ]] || die fio_exec_identity
  printf '%s\t%s\t%s\n' "$ACTIVE_FIO_PID" "$ACTIVE_FIO_TICKS" "$ACTIVE_FIO_EXE" >"$out/owned-fio.tsv"
  start=$(date +%s)
  while kill -0 "$ACTIVE_FIO_PID" 2>/dev/null; do
    now=$(date +%s)
    read -r avail < <(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')
    mem=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024}' /proc/meminfo)
    printf '%s\t%s\t%s\n' "$(date +%s%N)" "$avail" "$mem" >>"$ROOT/cells/$cell/safety.tsv"
    if (( now-start >= seconds )) || ! resource_gate || ! business_guard; then failed=1; event STOP_LOAD "$cell:space_memory_business_or_timeout"; stop_active_fio; break; fi
    if ! (health_gate "$ROOT/cells/$cell/health-live"); then failed=1; event STOP_LOAD "$cell:health"; stop_active_fio; break; fi
    sleep 1
  done
  if wait "$ACTIVE_FIO_PID"; then rc=0; else rc=$?; fi
  ACTIVE_FIO_PID=; ACTIVE_FIO_TICKS=; ACTIVE_FIO_EXE=
  date +%s%N >"$out/fio-end-epoch-ns.txt"
  read -r avail < <(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')
  mem=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024}' /proc/meminfo)
  printf '%s\t%s\t%s\n' "$(date +%s%N)" "$avail" "$mem" >>"$ROOT/cells/$cell/safety.tsv"
  (( failed == 0 )) || rc=44
  printf '%s\n' "$rc" >"$out/fio.rc"; FORMAL_RC=$rc
}
run_warmup() {
  local cell=$1 mnt=$2 out=$ROOT/cells/$1/warmup
  write_fio_job "$out" "$mnt" randread 60 no
  fio_checked "$out" "$cell" 180
  (( FORMAL_RC == 0 )) || die warmup_failed_preserve_mount
}
run_formal() {
  local cell=$1 mnt=$2 out=$ROOT/cells/$1/formal
  write_fio_job "$out" "$mnt" randrw 180 yes
  fio_checked "$out" "$cell" "$MAX_FIO_WALL"
  (( FORMAL_RC == 0 )) || return 0
  [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) == 128 ]] || die bw_log_count
}
stop_samplers() {
  [[ $SAMPLERS_RUNNING == 1 ]] || return 0
  local rc=0
  [[ -z $ACTIVE_SAMPLER_STOP ]] || : >"$ACTIVE_SAMPLER_STOP.done"
  if [[ -n $ACTIVE_SAMPLER_PID ]]; then wait "$ACTIVE_SAMPLER_PID" || rc=$?; fi
  if [[ -n $ACTIVE_IOSTAT_PID ]]; then
    kill -TERM "$ACTIVE_IOSTAT_PID" 2>/dev/null || true
    wait "$ACTIVE_IOSTAT_PID" 2>/dev/null || true
  fi
  ACTIVE_SAMPLER_PID=; ACTIVE_IOSTAT_PID=; ACTIVE_SAMPLER_STOP=; SAMPLERS_RUNNING=0
  (( rc == 0 )) || event MECHANISM_DEGRADED sampler_failed
}
queue_snapshot() {
  local metrics=$1 dirs=$2 out=$3 arm=$4
  curl -fsS --connect-timeout 2 --max-time 3 "http://$metrics/metrics" >"$out" || return 1
  queue_parse "$out" "$dirs" "$arm"
}
queue_parse() {
  python3 - "$1" "$2" "$CONTRACT" "$3" <<'PY'
import json,math,os,pathlib,re,stat,sys
d=json.load(open(sys.argv[3]));m=d['metrics'];values={}
for l in open(sys.argv[1]):
 if l.startswith('#') or not l.strip():continue
 x=re.match(r'^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{.*\})?\s+(\S+)',l)
 if x:
  v=float(x[2])
  if not math.isfinite(v) or v<0:raise SystemExit('invalid_metric')
  values[x[1]]=values.get(x[1],0)+v
stages=['juicefs_staging_blocks','juicefs_staging_block_bytes','juicefs_staging_writing_blocks']
if m['pending']!='UNREGISTERED':raise SystemExit('pending_registration_contract')
required=[m['uploading']]
if sys.argv[4]=='W':required+=stages
if any(n not in values for n in required):raise SystemExit('core_queue_metric_missing')
error=values.get(m['staging_errors'],0 if m['error_counter_absent_is_zero'] else None)
if error is None or error!=0:raise SystemExit('staging_errors_or_unknown')
stage=[values.get(n,'NA') for n in stages]
if sys.argv[4]!='W' and any(v!='NA' and v!=0 for v in stage):raise SystemExit('unexpected_nonWB_staging')
count=size=0
if sys.argv[2]:
 # Frozen 06-2 source: cached_store.go:589-594 appends volume UUID;
 # disk_cache.go:732-733 appends rawstaging. Never walk the raw read cache.
 uid=d['volume_uuid']
 if not re.fullmatch('[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',uid):raise SystemExit('unsafe_volume_uuid')
 base=pathlib.Path(sys.argv[2])/uid
 if not base.is_dir() or any(p.is_symlink() for p in (base,*base.parents)):raise SystemExit('cache_volume_dir_missing_or_symlink')
 stage_path=base/'rawstaging'
 if stage_path.is_symlink():raise SystemExit('staging_symlink')
 try:
  stage_stat=stage_path.stat()
  if not stat.S_ISDIR(stage_stat.st_mode):raise SystemExit('staging_not_directory')
 except FileNotFoundError:
  # Before the first WB write no rawstaging directory need exist. This is
  # explicit physical absence, not permission errors or absent W metrics.
  stage_stat=None
 def walk_error(e):raise e
 for root,ds,fs in os.walk(stage_path,followlinks=False,onerror=walk_error) if stage_stat else []:
  for n in ds:
   if os.path.islink(os.path.join(root,n)):raise SystemExit('staging_dir_symlink')
  for n in fs:
   p=os.path.join(root,n)
   if os.path.islink(p):raise SystemExit('staging_symlink')
   count+=1
   try:size+=os.stat(p).st_size
   except FileNotFoundError:
    # Concurrent successful upload/unlink: this sample stays nonzero/unknown;
    # next samples must still prove three zeros. All other errors propagate.
    pass
print(*(int(v) if v!='NA' else v for v in stage),'NA',int(values[m['uploading']]),count,size,sep='\t')
PY
}
queues_zero() {
  local q=$1 arm=${2:-W}
  if [[ $arm == W ]]; then [[ $q == $'0\t0\t0\tNA\t0\t0\t0' ]]
  else
    awk -F '\t' 'NF!=7{exit 1} {for(i=1;i<=3;i++)if($i!="NA"&&$i!="0")exit 1;if($4!="NA")exit 1;for(i=5;i<=7;i++)if($i!="0")exit 1}' <<<"$q"
  fi
}
mem_dirty() { awk '/^Dirty:/{d=$2}/^Writeback:/{w=$2}END{print d+0,w+0}' /proc/meminfo; }
freeze_quiet_baseline() {
  local start now dirty wb
  printf 'epoch_ns\tDirty_kB\tWriteback_kB\n' >"$ROOT/quiet-baseline.tsv"
  start=$(date +%s)
  while :; do
    business_guard || die business_not_quiet
    resource_gate yes || die quiet_resource_budget
    read -r dirty wb < <(mem_dirty)
    printf '%s\t%s\t%s\n' "$(date +%s%N)" "$dirty" "$wb" >>"$ROOT/quiet-baseline.tsv"
    now=$(date +%s); (( now-start < 121 )) || break
    sleep 1
  done
  python3 - "$ROOT/quiet-baseline.tsv" >"$ROOT/quiet-baseline.json" <<'PY'
import csv,json,math,sys
r=list(csv.DictReader(open(sys.argv[1]),delimiter='\t'));ts=[int(x['epoch_ns'])/1e9 for x in r]
if ts[-1]-ts[0]<120 or any(b-a>3 for a,b in zip(ts,ts[1:])):raise SystemExit('quiet_sampling_invalid')
def p95(k):
 v=sorted(int(x[k]) for x in r);return v[math.ceil(.95*len(v))-1]
d=p95('Dirty_kB');w=p95('Writeback_kB')
json.dump(dict(p95_method='nearest_rank',samples=len(r),dirty_p95_kB=d,writeback_p95_kB=w,dirty_limit_kB=d+8*1024**2,writeback_limit_kB=w+1024**2),sys.stdout)
PY
  read -r QUIET_DIRTY_LIMIT QUIET_WRITEBACK_LIMIT < <(python3 - "$ROOT/quiet-baseline.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));print(d['dirty_limit_kB'],d['writeback_limit_kB'])
PY
)
}
recovery_window_ok() {
  (( $1 <= QUIET_DIRTY_LIMIT && $2 <= QUIET_WRITEBACK_LIMIT )) && queues_zero "$3" "${4:-W}"
}
post_warmup_gate() {
  local cell=$1 metrics=$2 dirs=$3 arm=$4 c=$ROOT/cells/$1 start now since= last= dirty wb q
  start=$(date +%s)
  printf 'epoch_ns\tDirty_kB\tWriteback_kB\tstaging_blocks\tstaging_bytes\tstaging_writing_blocks\tpending\tuploading\tstaging_files\tstaging_file_bytes\n' >"$c/recovery.tsv"
  while :; do
    resource_gate || die recovery_resource
    business_guard || die recovery_business
    q=$(queue_snapshot "$metrics" "$dirs" "$c/recovery-last.prom" "$arm") || die recovery_queue_unknown
    read -r dirty wb < <(mem_dirty)
    now=$(date +%s)
    printf '%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$dirty" "$wb" "$q" >>"$c/recovery.tsv"
    [[ -z $last ]] || (( now-last <= 3 )) || since=
    if recovery_window_ok "$dirty" "$wb" "$q" "$arm"; then
      [[ -n $since ]] || since=$now
      if (( now-since >= 31 )); then
        printf '%s\n' "$((now-start))" >"$c/post-warmup-recovery-seconds.txt"
        [[ -z $dirs ]] || du -sx -B1 "$dirs" >"$c/cache-after-warmup.tsv"
        : >"$c/RECOVERY_PASS"; return 0
      fi
    else since=; fi
    (( now-start < 900 )) || { event RECOVERY_TIMEOUT "$cell"; die recovery_timeout_preserve_mount; }
    last=$now; sleep 1
  done
}
drain_writeback() {
  local cell=$1 metrics=$2 dirs=$3 arm=${4:-W} c=$ROOT/cells/$1 start now zeros=0 q
  start=$(date +%s)
  printf 'epoch_ns\tstaging_blocks\tstaging_bytes\tstaging_writing_blocks\tpending\tuploading\tstaging_files\tstaging_file_bytes\n' >"$c/drain.tsv"
  while :; do
    resource_gate || { event DRAIN_RESOURCE_LIMIT "$cell"; return 43; }
    now=$(date +%s)
    q=$(queue_snapshot "$metrics" "$dirs" "$c/drain-last.prom" "$arm") || { event DRAIN_UNKNOWN "$cell"; return 43; }
    printf '%s\t%s\n' "$(date +%s%N)" "$q" >>"$c/drain.tsv"
    if queues_zero "$q" "$arm"; then zeros=$((zeros+1)); else zeros=0; fi
    if (( zeros >= 3 )); then
      printf '%s\n' "$((now-start))" >"$c/drain-seconds.txt"
      date +%s%N >"$c/strict-drain-end-ns.txt"
      : >"$c/DRAIN_PASS"; return 0
    fi
    if (( now-start >= DRAIN_TIMEOUT )); then
      event DRAIN_TIMEOUT "$cell"
      printf 'PRESERVE_MOUNT_AND_CACHE\n' >"$c/STOP-PRESERVE-MOUNT"; return 43
    fi
    sleep 1
  done
}

readback_verify() {
  local cell=$1 mnt=$2 out=$ROOT/cells/$1/readback rc
  local -a cmd
  mkdir -m 0700 -p "$out"
  cmd=(timeout 120 "$FIO" --name=readback --filename="$mnt/test_dir/rw_test.0.0:$mnt/test_dir/rw_test.31.0:$mnt/test_dir/rw_test.63.0:$mnt/test_dir/rw_test.127.0" --rw=read --bs=256K --size=4M --direct=1 --ioengine=libaio --iodepth=1 --numjobs=1 --group_reporting --readonly --allow_file_create=0 --fallocate=none --output="$out/fio.json" --output-format=json)
  log_cmd "${cmd[@]}"
  if "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" >"$out/fio.rc"
  printf 'rc\t%s\nremote_readable\t%s\ncontent_correctness\tNOT_PROVEN\n' "$rc" "$([[ $rc == 0 ]] && printf PASS || printf FAIL)" >"$ROOT/cells/$cell/readback-verify.tsv"
  (( rc == 0 )) || die readback_failed
}
run_cell() {
  local pos=$1 cell=$2 arm=$3 cache_mib=$4 clw=$5 wb=$6 c=$ROOT/cells/$2
  local mnt=/tmp/jfs-06-3-$RUN_ID-$cell verify=/tmp/jfs-06-3-$RUN_ID-$cell-verify metrics=127.0.0.1:$((METRICS_BASE+pos)) dirs= avail mem
  CELL_START_AVAIL=
  [[ ! -e $c ]] || die cell_already_exists
  mkdir -m 0700 -- "$c"
  business_guard || die concurrent_business
  validate_parent "$CACHE_PARENT"
  resource_gate yes || die insufficient_approved_space_memory
  read -r avail < <(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')
  CELL_START_AVAIL=$avail
  mem=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024}' /proc/meminfo)
  printf 'epoch_ns\tavail_bytes\tMemAvailable_bytes\n%s\t%s\t%s\n' "$(date +%s%N)" "$avail" "$mem" >"$c/start-resources.tsv"
  printf 'epoch_ns\tavail_bytes\tMemAvailable_bytes\n' >"$c/safety.tsv"
  verify_assets "$REF" "$c/assets-before.tsv"; volume_identity "$REF"
  health_gate "$c/health-before"; backend_snapshot "$c/backend-before"
  if [[ $arm != C ]]; then dirs=$(cache_dirs_for_cell "$cell"); create_cache_dirs "$cell" "$dirs"; fi
  printf 'cell\t%s\narm\t%s\ncache_mib\t%s\ncache_large_write\t%s\nwriteback\t%s\ncache_dirs\t%s\n' "$cell" "$arm" "$cache_mib" "$clw" "$wb" "${dirs:-NONE}" >"$c/state.tsv"
  mount_private "$cell" "$arm" formal "$mnt" "$metrics" "$dirs"
  verify_assets "$mnt" "$c/assets-mounted.tsv"
  start_samplers "$cell" "$metrics" "$dirs"; SAMPLERS_RUNNING=1
  run_warmup "$cell" "$mnt"
  health_gate "$c/health-post-warmup"
  post_warmup_gate "$cell" "$metrics" "$dirs" "$arm"
  health_gate "$c/health-pre-formal"
  run_formal "$cell" "$mnt"; stop_samplers
  (( FORMAL_RC == 0 )) || { event FIO_FAIL_PRESERVE_MOUNT "$cell:rc=$FORMAL_RC"; return "$FORMAL_RC"; }
  drain_writeback "$cell" "$metrics" "$dirs" "$arm" || return $?
  graceful_umount "$cell" formal "$mnt"
  mount_private "$cell" C verify "$verify" "$metrics" ""
  verify_assets "$verify" "$c/assets-verify.tsv"
  readback_verify "$cell" "$verify"; : >"$c/READBACK_PASS"
  graceful_umount "$cell" verify "$verify"
  verify_assets "$REF" "$c/assets-after.tsv"; health_gate "$c/health-after"
  backend_snapshot "$c/backend-after"
  if [[ -n $dirs ]]; then cleanup_cache_dirs "$cell" "$dirs"; fi
  printf 'CELL_RAW_PASS\n' >"$c/PASS"
}
restore_scrub_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  stop_active_fio || rc=45
  stop_samplers || true
  if (( SCRUB_ACTIVE )); then
    if ! env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore-on-exit.txt" 2>&1; then
      event SCRUB_RESTORE_FAIL "$SCRUB_LEASE"
      printf 'SCRUB_RESTORE_FAILED\n' >"$ROOT/STOP-SCRUB-RESTORE-FAILED"; rc=46
    fi
  fi
  # No failure-path unmount or cache deletion: keep upload alive.
  exit "$rc"
}
phase() {
  require_online_ack
  no_symlink_components /tmp/production || die result_parent_symlink
  [[ -d /tmp/production && ! -e $ROOT ]] || die result_root_precondition
  validate_parent "$CACHE_PARENT"; business_guard || die business_guard
  resource_gate yes || die start_budget
  mkdir -m 0700 -- "$ROOT"; mkdir -m 0700 -- "$ROOT/cells" "$ROOT/gate0"
  printf 'epoch_ns\tkind\tdetail\n' >"$ROOT/incidents.tsv"; : >"$ROOT/commands.sh"
  cp -- "$CONTRACT" "$ROOT/gate0/approved-contract.json"; CONTRACT=$ROOT/gate0/approved-contract.json
  [[ $(sha256sum "$CONTRACT" | awk '{print $1}') == "$T063_CONTRACT_SHA256" ]] || die copied_contract_drift
  sha256sum "$0" "$LEGACY" "$ANALYZER" "$GATE0" "$SCRUB" >"$ROOT/gate0/scripts.sha256"
  verify_assets "$REF" "$ROOT/gate0/assets-start.tsv"; volume_identity "$REF"; health_gate "$ROOT/health-initial"
  trap restore_scrub_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Existing scrub component requires its established -phase-a lease suffix.
  SCRUB_LEASE=06-3-$RUN_ID-phase-a; SCRUB_ACTIVE=1
  log_cmd env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" pause "$SCRUB_LEASE" "$EXPECTED_FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
  env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" pause "$SCRUB_LEASE" "$EXPECTED_FSID" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$ROOT/scrub-pause.txt"
  freeze_quiet_baseline
  while IFS=$'\t' read -r pos cell arm cache_mib clw wb; do run_cell "$pos" "$cell" "$arm" "$cache_mib" "$clw" "$wb"; done < <(matrix_rows)
  env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore.txt"
  SCRUB_ACTIVE=0
  health_gate "$ROOT/health-final"; verify_assets "$REF" "$ROOT/gate0/assets-end.tsv"
  printf 'PHASE_RAW_PASS\n' >"$ROOT/PHASE_PASS"
}
write_plans() {
  local out=$1
  [[ $out == /* && $out != / && ! -e $out && ! -L $out ]] || die plan_output_must_be_new
  no_symlink_components "$out" || die plan_path_symlink
  mkdir -m 0700 -p "$out/gate0"
  { printf 'position\tcell\tarm\tcache_mib\tcache_large_write\twriteback\n'; matrix_rows; } >"$out/gate0/mainline-matrix.tsv"
  printf '%s\n' 'quiet120 -> mount -> read-warmup60 -> recovery30/timeout900 -> formal180 -> drain3zero -> graceful-unmount -> cache0-readback -> graceful-unmount -> exact-cache-cleanup' >"$out/gate0/lifecycle.txt"
  printf '%s\n' 'FORBIDDEN: GC, compact, drop_caches, global sync, sysctl, format, layout, forced/lazy unmount, shared cache deletion, legacy phase-a, branch workloads.' >"$out/gate0/forbidden-operations.txt"
  printf '%s\n' 'FUTURE AUTHORIZED WRITES: exact RUN result/cache/mount mkdir; scrub helper sudo ceph osd set/unset noscrub and nodeep-scrub; private JFS mount/umount; fio existing 128 files; exact owned fio PID SIGTERM/SIGKILL safety stop; exact sampler PID SIGTERM; drained/readback exact cache find -xdev -delete and rmdir.' >"$out/gate0/write-operations.txt"
  write_fio_job "$out/gate0/warmup" '<PRIVATE_MOUNT>' randread 60 no
  write_fio_job "$out/gate0/formal" '<PRIVATE_MOUNT>' randrw 180 yes
  python3 - "$RUN_ID" "$META" >"$out/gate0/contract-template.NOT-APPROVED.json" <<'PY'
import json,sys
d=dict(schema='06-3-v1',status='NOT_APPROVED',run_id=sys.argv[1],meta=sys.argv[2],hostname='INVENTORY_REQUIRED',machine_id='INVENTORY_REQUIRED',ceph_fsid='INVENTORY_REQUIRED',volume_uuid='INVENTORY_REQUIRED',fio_version='INVENTORY_REQUIRED',assets_sha256='INVENTORY_REQUIRED',cache_parent='/mnt/jfs-cache/04tmp3',cache_exclusive_use=False,no_concurrent_benchmark=False,approved_osd_flags=[],protected_processes=[],metrics=dict(pending='UNREGISTERED',uploading='juicefs_object_request_uploading',staging_errors='INVENTORY_REQUIRED',error_counter_absent_is_zero=False))
for k in ('source','major_minor','fstype','filesystem_uuid','mount_target','mount_options','physical_leaf_devices'):d['cache_'+k]='INVENTORY_REQUIRED'
for k in ('owner_uid','owner_gid','mode'):d['cache_'+k]=0
d['space']={k:0 for k in ('worst_backlog_bytes','filesystem_reserve_bytes','business_reserve_bytes','stop_margin_bytes','max_ingress_bytes_per_sec','stop_latency_seconds','monitor_interval_seconds','minimum_start_avail_bytes','minimum_mem_available_bytes','max_fio_wall_seconds')};d['space']['read_cache_bytes']=96*2**30
json.dump(d,sys.stdout,indent=2);print()
PY
  sha256sum "$0" "$LEGACY" "$SCRUB" >"$out/gate0/dependency-sha256.txt"
}
offline_self_test() {
  valid_run
  [[ $(matrix_order) == C1,S1,W1,W2,S2,C2 ]] || die test_matrix
  if declare -F phase_a >/dev/null || declare -F recovery_gate >/dev/null; then die test_legacy_entrypoint; fi
  local arm args dirs
  for arm in C S W; do
    dirs=/mock/cache; [[ $arm != C ]] || dirs=
    mount_args "$arm" /mock/mount 127.0.0.1:19631 /mock/log "$dirs"; args=" ${MOUNT_CMD[*]} "
    case $arm in
      C) [[ $args == *' --cache-size 0 '* && $args != *' --writeback '* && $args != *' --cache-large-write '* ]] || die test_C;;
      S) [[ $args == *' --cache-size 98304 '* && $args == *' --cache-large-write '* && $args != *' --writeback '* ]] || die test_S;;
      W) [[ $args == *' --cache-size 98304 '* && $args == *' --cache-large-write '* && $args == *' --writeback '* ]] || die test_W;;
    esac
  done
  local zero=$'0\t0\t0\tNA\t0\t0\t0' td
  QUIET_DIRTY_LIMIT=8388608; QUIET_WRITEBACK_LIMIT=1048576
  recovery_window_ok 8388608 1048576 "$zero" || die test_recovery_boundary
  if recovery_window_ok 8388609 0 "$zero"; then die test_dirty_rejection; fi
  if recovery_window_ok 0 1048577 "$zero"; then die test_writeback_rejection; fi
  if recovery_window_ok 0 0 $'0\t0\t0\t0\t0\t0\t0'; then die test_fake_pending_zero_rejection; fi
  if queues_zero $'0\t0\t0\tNA\t1\t0\t0'; then die test_uploading_rejection; fi
  queues_zero $'NA\tNA\tNA\tNA\t0\t0\t0' C || die test_C_NA_contract
  if queues_zero $'NA\tNA\tNA\tNA\t0\t0\t0' W; then die test_W_NA_rejected; fi
  td=$(mktemp -d "${TMPDIR:-/tmp}/t063-selftest.XXXXXX")
  (
    CONTRACT=$td/queue-contract.json
    printf '%s\n' '{"volume_uuid":"00000000-0000-0000-0000-000000000001","metrics":{"pending":"UNREGISTERED","uploading":"uploading","staging_errors":"errors","error_counter_absent_is_zero":false}}' >"$CONTRACT"
    printf 'juicefs_staging_blocks 0\njuicefs_staging_block_bytes 0\njuicefs_staging_writing_blocks 0\nuploading 0\nerrors 0\n' >"$td/queue.prom"
    base=$td/cache/00000000-0000-0000-0000-000000000001
    mkdir -p "$base/raw" "$base/rawstaging/chunks"
    ln -s /nonexistent-raw-must-not-be-traversed "$base/raw/ignored-link"
    queues_zero "$(queue_parse "$td/queue.prom" "$td/cache" W)" W || die test_raw_not_walked
    printf 'block\n' >"$base/rawstaging/chunks/object"
    if queues_zero "$(queue_parse "$td/queue.prom" "$td/cache" W)" W; then die test_nonzero_rawstaging; fi
    ln -s /tmp "$base/rawstaging/escape"
    if queue_parse "$td/queue.prom" "$td/cache" W >/dev/null 2>&1; then die test_staging_symlink; fi
  ) || die test_queue_subtree
  # Fixtures remain with Gate evidence; never a real online command.
  (
    ROOT=$td; mkdir -p "$ROOT/cells/W1"; n=0
    resource_gate() { return 0; }
    date() { if [[ $1 == +%s ]]; then printf '%s\n' "$(<"$td/clock")"; else printf '1000000000\n'; fi; }
    sleep() { n=$((n+1)); printf '%s\n' "$n" >"$td/clock"; }
    printf '0\n' >"$td/clock"
    queue_snapshot() { printf '%s\n' "$zero"; }
    drain_writeback W1 mock '' W
    [[ $n == 2 && -f $ROOT/cells/W1/DRAIN_PASS ]] || die test_three_zero_drain
  ) || die test_mock_drain
  (
    ROOT=$td; mkdir -p "$ROOT/cells/W2"; DRAIN_TIMEOUT=2; n=0
    resource_gate() { return 0; }
    printf '0\n' >"$td/clock"
    date() { if [[ $1 == +%s ]]; then printf '%s\n' "$(<"$td/clock")"; else printf '1000000000\n'; fi; }
    sleep() { n=$((n+1)); printf '%s\n' "$n" >"$td/clock"; }
    queue_snapshot() { printf '0\t0\t0\tNA\t1\t0\t0\n'; }
    if drain_writeback W2 mock '' W; then die test_timeout_accepted; fi
    [[ ! -f $ROOT/cells/W2/DRAIN_PASS && -f $ROOT/cells/W2/STOP-PRESERVE-MOUNT ]] || die test_timeout_preserve
    if (graceful_umount W2 formal /tmp/jfs-06-3-$RUN_ID-W2) 2>/dev/null; then die test_undrained_umount; fi
    if (cleanup_cache_dirs W2 "$CACHE_PARENT/jfs-06-3-$RUN_ID-W2") 2>/dev/null; then die test_undrained_cleanup; fi
  ) || die test_mock_timeout
  (
    ROOT=$td; mkdir -p "$ROOT/cells/S1"; n=0
    printf '0\n' >"$td/clock"
    date() { if [[ $1 == +%s ]]; then printf '%s\n' "$(<"$td/clock")"; else printf '%s000000000\n' "$(<"$td/clock")"; fi; }
    sleep() { n=$((n+1)); printf '%s\n' "$n" >"$td/clock"; }
    resource_gate() { return 0; }
    business_guard() { return 0; }
    queue_snapshot() { printf '%s\n' "$zero"; }
    mem_dirty() { if [[ $(<"$td/clock") == 10 ]]; then printf '8388609 0\n'; else printf '0 0\n'; fi; }
    post_warmup_gate S1 mock '' S
    [[ $n == 42 && -f $ROOT/cells/S1/RECOVERY_PASS ]] || die test_recovery_reset_and_30sec
  ) || die test_mock_recovery
  (
    CELL_START_AVAIL=1000; CELL_MAX_ALLOC=200
    STOP_AVAIL=100; MIN_START_AVAIL=100; MIN_MEM_AVAIL=1
    df() { printf 'Avail\n%s\n' "$fake_avail"; }
    fake_avail=800; resource_gate || die test_stage_cap_boundary
    fake_avail=799
    if resource_gate; then die test_stage_cap_rejected; fi
    CELL_START_AVAIL=
    resource_gate || die test_quiet_no_cell_budget
  ) || die test_stage_cap
  if (cache_dirs_for_cell C1) >/dev/null 2>&1; then die test_invalid_cache_cell; fi
  if (validate_parent /mnt/jfs-cache) >/dev/null 2>&1; then die test_shared_parent; fi
  ln -s /tmp "$td/link"
  if (no_symlink_components "$td/link/private") >/dev/null 2>&1; then die test_symlink_component; fi
  printf 'T063_DRIVER_SELF_TEST_PASS\tmatrix=C1,S1,W1,W2,S2,C2\tfixture=%s\n' "$td"
}
case $MODE in
  --self-test) offline_self_test;;
  plan) valid_run; write_plans "$PLAN_OUT"; printf 'T063_PLAN_ONLY_PASS\troot=%s\n' "$PLAN_OUT";;
  phase) phase;;
  *) printf 'usage: bash %s --self-test|plan|phase RUN_ID\n' "$0" >&2; exit 2;;
esac
