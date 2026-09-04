#!/usr/bin/env bash
# Minimal stateful runner for 04-tmp2. Gate 0 is offline; real modes fail closed.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRUB_CONTROL="$SELF_DIR/u141d-scrub-control.sh"
RUN_SCRIPT="$SELF_DIR/t04tmp2-cache-run.sh"
CLEANUP_SCRIPT="$SELF_DIR/t04tmp2-cache-cleanup.sh"
ANALYZER="$SELF_DIR/t04tmp2-cache-analyze.py"
GATE_SCRIPT="$SELF_DIR/t04tmp2-cache-gate0-offline.sh"
MODE=${1:-}
RUN_ID=${2:-}
DRY_RUN_ONLY=${TMP2_DRY_RUN_ONLY:-1}
JFS=${TMP2_JFS:-/tmp/juicefs-1.4.1-patched}
EXPECTED_JFS_MD5=${TMP2_JFS_MD5:-24fae0852051c80ca571cb2f20275d46}
META=${TMP2_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
REFERENCE_MNT=${TMP2_REFERENCE_MNT:-/mnt/juicefs}
CACHE_PARENT=${TMP2_CACHE_PARENT:-/mnt/jfs-cache}
CEPH_CONF_PATH=${TMP2_CEPH_CONF:-}
NIC=${TMP2_NIC:-}
CACHE_DEV=${TMP2_CACHE_DEV:-}
CEPH_FSID=${TMP2_CEPH_FSID:-}
ROOT=${TMP2_RESULT_ROOT:-/tmp/production/opencode-04tmp2-$RUN_ID}
STATE="$ROOT/state"
PLAN="$ROOT/plans"
SCRUB_LEASE=${TMP2_SCRUB_LEASE:-$RUN_ID-phase-a}

incident() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ && $ROOT == "/tmp/production/opencode-04tmp2-$RUN_ID" && -d $ROOT && ! -L $ROOT ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "${MODE:-unknown}" "${1:-EVENT}" "${2:-}" >>"$ROOT/incidents.tsv" 2>/dev/null || true
}
die() { incident STOP "$*"; printf 'E_TMP2\t%s\n' "$*" >&2; exit 42; }
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

usage() {
  printf '%s\n' \
    'usage: t04tmp2-cache-run.sh offline-self-test RUN_ID' \
    '       t04tmp2-cache-run.sh inventory RUN_ID' \
    '       t04tmp2-cache-run.sh plan RUN_ID' \
    '       t04tmp2-cache-run.sh prepare RUN_ID' \
    '       t04tmp2-cache-run.sh screen RUN_ID' \
    '       t04tmp2-cache-run.sh post-anchor RUN_ID'
}

validate_run_id() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "invalid RUN_ID: ${RUN_ID:-missing}"
}

validate_scope() {
  validate_run_id
  [[ $ROOT == "/tmp/production/opencode-04tmp2-$RUN_ID" ]] || die "result root outside exact RUN scope: $ROOT"
  [[ ! -L $ROOT ]] || die "result root is symlink"
}

init_root() {
  validate_scope
  mkdir -p "$ROOT" "$STATE" "$PLAN"
  [[ ! -L $STATE && ! -L $PLAN ]] || die "state/plan path is symlink"
  if [[ ! -f $STATE/run.tsv ]]; then
    printf 'run_id\t%s\nresult_root\t%s\ncreated_epoch\t%s\n' "$RUN_ID" "$ROOT" "$(date +%s)" >"$STATE/run.tsv"
  fi
  grep -Fqx $'run_id\t'"$RUN_ID" "$STATE/run.tsv" || die "run state identity mismatch"
  if [[ ! -f $ROOT/incidents.tsv ]]; then printf 'epoch\tmode\taction\tdetail\n' >"$ROOT/incidents.tsv"; fi
  if [[ ! -f $ROOT/commands.sh ]]; then printf '#!/usr/bin/env bash\n# Actual commands for 04-tmp2 %s\n' "$RUN_ID" >"$ROOT/commands.sh"; fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

freeze_scripts() {
  sha256sum "$RUN_SCRIPT" "$CLEANUP_SCRIPT" "$ANALYZER" "$GATE_SCRIPT" "$SCRUB_CONTROL" >"$STATE/scripts.sha256"
}

verify_scripts() {
  [[ -f $STATE/scripts.sha256 ]] || die "frozen script manifest missing"
  sha256sum -c "$STATE/scripts.sha256" >"$STATE/scripts-verify-last.txt" || die "script drift after freeze"
}

require_real_ack() {
  local action=$1 expected="I_ACK_TMP2_${1}_${RUN_ID}"
  [[ $DRY_RUN_ONLY == 0 ]] || die "$action is disabled by TMP2_DRY_RUN_ONLY=$DRY_RUN_ONLY"
  [[ ${TMP2_ACK:-} == "$expected" ]] || die "$action requires TMP2_ACK=$expected"
}

cache_root() { printf '%s/jfs-04tmp2-%s\n' "$CACHE_PARENT" "$RUN_ID"; }
mount_path() {
  local label=$1
  [[ $label =~ ^(PREP|R0[1-4]-(A|B)|POST-A)$ ]] || die "invalid mount label: $label"
  printf '/tmp/jfs-04tmp2-%s-%s\n' "$RUN_ID" "$label"
}

assert_exact_mount_path() {
  local label=$1 path=$2
  [[ $path == "$(mount_path "$label")" && $path != / && $path != *'..'* && $path != *'*'* && $path != *'?'* ]] \
    || die "unsafe mount path: $path"
  [[ ! -L $path ]] || die "mount path is symlink: $path"
}

write_command() {
  local out=$1; shift
  printf '%q ' "$@" >>"$out"
  printf '\n' >>"$out"
}

render_jobfile() {
  local out=$1 mnt=$2 kind=$3 label=$4 seed=${5:-0}
  [[ $out == "$ROOT"/* && ! -L $out ]] || die "jobfile outside result root"
  [[ $mnt == /tmp/jfs-04tmp2-"$RUN_ID"-* ]] || die "jobfile mount outside RUN scope"
  mkdir -p "$(dirname -- "$out")"
  {
    printf '[global]\n'
    if [[ $kind == warmup ]]; then
      printf 'rw=read\nbs=4M\noffset=0\nsize=256M\nioengine=libaio\niodepth=16\n'
      printf 'time_based=0\n'
    elif [[ $kind == formal ]]; then
      printf 'rw=randread\nbs=256k\noffset=0\nsize=256M\nioengine=libaio\niodepth=128\n'
      printf 'time_based=1\nruntime=180\nrandrepeat=1\nrandseed=%s\n' "$seed"
      printf 'write_bw_log=%s/cells/%s/bw/read_test\nlog_avg_msec=1000\n' "$ROOT" "$label"
    else
      die "unknown jobfile kind: $kind"
    fi
    printf 'direct=1\nfallocate=none\nallow_file_create=0\ncreate_on_open=0\n'
    local i
    for i in $(seq 0 127); do
      printf '\n[read_test_%03d]\nfilename=%s/test_dir/read_test.%d.0\n' "$i" "$mnt" "$i"
    done
  } >"$out"
}

assert_jobfile() {
  local file=$1 kind=$2
  [[ -f $file && ! -L $file ]] || die "missing jobfile: $file"
  [[ $(grep -c '^\[read_test_[0-9][0-9][0-9]\]$' "$file") -eq 128 ]] || die "jobfile does not contain 128 jobs"
  grep -Fqx 'allow_file_create=0' "$file" || die "jobfile allows file creation"
  grep -Fqx 'create_on_open=0' "$file" || die "jobfile allows create_on_open"
  ! grep -Eq '^(readonly|filesize)=' "$file" || die "jobfile contains forbidden/invalid readonly or filesize option"
  ! grep -Eq '^rw=(write|randwrite|randrw)' "$file" || die "jobfile contains write workload"
  if [[ $kind == formal ]]; then
    grep -Fqx 'rw=randread' "$file" || die "formal jobfile is not randread"
    grep -Fqx 'runtime=180' "$file" || die "formal runtime differs"
  else
    grep -Fqx 'rw=read' "$file" || die "warmup jobfile is not read"
    grep -Fqx 'size=256M' "$file" || die "warmup size differs"
  fi
}

asset_manifest() {
  local dir=$1 out=$2
  [[ -d $dir && ! -L $dir ]] || die "test_dir unavailable or symlink: $dir"
  find "$dir" -maxdepth 1 -type f -name 'read_test.*.0' \
    -printf '%f\t%i\t%s\t%T@\n' | sort -V >"$out"
  python3 - "$out" <<'PY'
import re,sys
p=sys.argv[1]; rows=[x.rstrip('\n').split('\t') for x in open(p)]
if len(rows)!=128: raise SystemExit(f'expected 128 assets, got {len(rows)}')
for i,row in enumerate(rows):
    if len(row)!=4 or row[0]!=f'read_test.{i}.0': raise SystemExit(f'asset name/order mismatch at {i}: {row}')
    if int(row[2])!=1073741824: raise SystemExit(f'asset size mismatch: {row[0]}={row[2]}')
    if not re.fullmatch(r'[0-9]+',row[1]): raise SystemExit(f'invalid inode: {row}')
PY
  sha256sum "$out" >"$out.sha256"
}

validate_volume_status() {
  local input=$1 output=$2
  python3 - "$input" "$output" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Setting')
if not isinstance(s,dict): raise SystemExit('Setting object missing')
required=('UUID','Name','Storage','Bucket','BlockSize')
missing=[k for k in required if s.get(k) in (None,'')]
if missing: raise SystemExit(f'Setting fields missing: {missing}')
with open(sys.argv[2],'w') as f:
    f.write('field\tvalue\n')
    for key in required: f.write(f'{key}\t{s[key]}\n')
PY
}

wait_mounted() {
  local mnt=$1
  local i
  for i in $(seq 1 120); do mountpoint -q "$mnt" && return 0; sleep 1; done
  die "mount did not become active: $mnt"
}

mount_identity() {
  local arm=$1 label=$2 mnt=$3 out=$4
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/findmnt.tsv"
  "$JFS" status "$META" >"$out/status.json"
  validate_volume_status "$out/status.json" "$out/setting.tsv"
  local volume_name mount_source
  volume_name=$(awk -F'\t' '$1=="Name"{print $2}' "$out/setting.tsv")
  mount_source=$(findmnt -rn -M "$mnt" -o SOURCE)
  [[ $mount_source == "JuiceFS:$volume_name" ]] \
    || die "mount source/volume mismatch: source=$mount_source name=$volume_name"
  python3 - "$mnt" "$JFS" "$META" "$arm" "$(cache_root)" "$CEPH_CONF_PATH" \
    "$out/mount-pids-pre.txt" >"$out/mount-processes.tsv" <<'PY'
import hashlib,os,sys
mnt,expected,meta,arm,cache_root,expected_conf,pre_file=sys.argv[1:]
expected=os.path.realpath(expected); rows=[]
pre={int(x) for x in open(pre_file) if x.strip().isdigit()}
for name in os.listdir('/proc'):
    if not name.isdigit(): continue
    try:
        raw=open(f'/proc/{name}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace')
        env=open(f'/proc/{name}/environ','rb').read().split(b'\0')
        exe=os.path.realpath(f'/proc/{name}/exe')
        st=open(f'/proc/{name}/stat').read().split(); ppid=int(st[3]); start=int(st[21])
    except (OSError,ValueError): continue
    pid=int(name)
    if pid in pre or exe!=expected: continue
    required=[' mount -d ','--read-only','--prefetch 0','--max-fuse-io 256K','--max-uploads 150']
    if any(x not in raw for x in required): continue
    if arm=='A':
        if '--cache-size 0' not in raw or '--cache-dir' in raw: continue
    elif arm=='B':
        if '--cache-size 65536' not in raw or f'--cache-dir {cache_root}' not in raw: continue
    else: raise SystemExit('invalid arm')
    conf=[x.decode(errors='replace').split('=',1)[1] for x in env if x.startswith(b'CEPH_CONF=')]
    rows.append((pid,ppid,start,exe,conf[0] if conf else '',raw))
if not rows: raise SystemExit('no launch-scoped mount process candidates')
workers=[r for r in rows if any(r[1]==x[0] for x in rows)]
if len(workers)!=1: raise SystemExit(f'exactly one child worker required, got {[(r[0],r[1]) for r in rows]}')
if workers[0][4] != expected_conf: raise SystemExit('selected worker CEPH_CONF mismatch')
cmd=workers[0][5]
if '--max-readahead' in cmd: raise SystemExit('mount argv unexpectedly changes max-readahead')
print('pid\tppid\tstarttime\texe_md5\tceph_conf\tselected_worker\tcmdline')
for r in sorted(rows):
    h=hashlib.md5(open(f'/proc/{r[0]}/exe','rb').read()).hexdigest()
    print(r[0],r[1],r[2],h,r[4],int(r[0]==workers[0][0]),r[5],sep='\t')
PY
}

mount_arm() {
  local arm=$1 label=$2 mnt=$3 out=$4
  assert_exact_mount_path "$label" "$mnt"
  [[ ! -e $mnt ]] || die "mount path already exists: $mnt"
  mkdir -m 0700 "$mnt"
  local -a cmd=("$JFS" mount -d --read-only --prefetch 0 --max-fuse-io 256K --max-uploads 150)
  if [[ $arm == A ]]; then
    cmd+=(--cache-size 0)
  elif [[ $arm == B ]]; then
    local cr; cr=$(cache_root)
    [[ -d $cr && ! -L $cr ]] || die "cache root unavailable: $cr"
    cmd+=(--cache-size 65536 --cache-dir "$cr" --free-space-ratio 0.2)
  else
    die "invalid arm: $arm"
  fi
  cmd+=("$META" "$mnt")
  python3 - "$JFS" >"$out/mount-pids-pre.txt" <<'PY'
import os,sys
expected=os.path.realpath(sys.argv[1])
for name in sorted((x for x in os.listdir('/proc') if x.isdigit()),key=int):
    try: actual=os.path.realpath(f'/proc/{name}/exe')
    except OSError: continue
    if actual==expected: print(name)
PY
  write_command "$ROOT/commands.sh" env "CEPH_CONF=$CEPH_CONF_PATH" "${cmd[@]}"
  env CEPH_CONF="$CEPH_CONF_PATH" "${cmd[@]}" >"$out/mount.stdout" 2>"$out/mount.stderr"
  wait_mounted "$mnt"
  mount_identity "$arm" "$label" "$mnt" "$out"
}

graceful_umount() {
  local label=$1 mnt=$2 out=$3
  assert_exact_mount_path "$label" "$mnt"
  write_command "$ROOT/commands.sh" "$JFS" umount "$mnt"
  "$JFS" umount "$mnt" >"$out/umount.stdout" 2>"$out/umount.stderr"
  local i
  for i in $(seq 1 180); do
    if ! mountpoint -q "$mnt"; then rmdir "$mnt"; return 0; fi
    sleep 1
  done
  die "graceful umount timeout: $mnt"
}

snapshot_counters() {
  local out=$1
  mkdir -p "$out"
  date +%s%N >"$out/epoch-ns.txt"
  if [[ -n $NIC && -r /sys/class/net/$NIC/statistics/rx_bytes ]]; then
    printf 'rx_bytes\t%s\ntx_bytes\t%s\n' \
      "$(</sys/class/net/$NIC/statistics/rx_bytes)" "$(</sys/class/net/$NIC/statistics/tx_bytes)" >"$out/nic.tsv"
  else
    printf 'UNAVAILABLE\tNIC=%s\n' "${NIC:-unset}" >"$out/nic.tsv"
  fi
  if [[ -n $CACHE_DEV && -r /sys/class/block/$CACHE_DEV/stat ]]; then
    printf 'device\t%s\nstat\t%s\n' "$CACHE_DEV" "$(</sys/class/block/$CACHE_DEV/stat)" >"$out/block.tsv"
  else
    printf 'UNAVAILABLE\tCACHE_DEV=%s\n' "${CACHE_DEV:-unset}" >"$out/block.tsv"
  fi
  local cr; cr=$(cache_root)
  if [[ -d $cr ]]; then
    du -s -B1 -- "$cr" >"$out/cache-du.tsv"
    find "$cr" -xdev -type f -printf '%P\t%s\n' | sort >"$out/cache-files.tsv"
    if find "$cr" -xdev -type f -path '*/rawstaging/*' -print -quit | grep -q .; then
      die "rawstaging file detected"
    fi
  else
    printf 'ABSENT\n' >"$out/cache-du.tsv"
    : >"$out/cache-files.tsv"
  fi
}

sample_runtime() {
  local out=$1 stop=$2
  printf 'epoch_ns\trx_bytes\ttx_bytes\tblock_stat\n' >"$out"
  local n=0 rx=NA tx=NA block=NA
  while [[ ! -f $stop && $n -lt 240 ]]; do
    if [[ -n $NIC && -r /sys/class/net/$NIC/statistics/rx_bytes ]]; then
      rx=$(</sys/class/net/$NIC/statistics/rx_bytes); tx=$(</sys/class/net/$NIC/statistics/tx_bytes)
    fi
    if [[ -n $CACHE_DEV && -r /sys/class/block/$CACHE_DEV/stat ]]; then block=$(tr -s ' ' <"/sys/class/block/$CACHE_DEV/stat"); fi
    printf '%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$rx" "$tx" "$block" >>"$out"
    n=$((n+1)); sleep 1
  done
  (( n >= 170 )) || die "runtime sampler has only $n samples"
}

verify_binary() {
  [[ -x $JFS && ! -L $JFS ]] || die "JuiceFS binary unavailable or symlink: $JFS"
  [[ $(md5sum "$JFS" | awk '{print $1}') == "$EXPECTED_JFS_MD5" ]] || die "JuiceFS MD5 mismatch"
  [[ -n $CEPH_CONF_PATH && -f $CEPH_CONF_PATH && ! -L $CEPH_CONF_PATH ]] || die "TMP2_CEPH_CONF must identify a regular private config"
}

run_fio_job() {
  local jobfile=$1 out=$2
  need_cmd fio
  assert_jobfile "$jobfile" "$(grep -q '^rw=randread$' "$jobfile" && printf formal || printf warmup)"
  write_command "$ROOT/commands.sh" fio --readonly --output-format=json --output="$out/fio.json" "$jobfile"
  local rc
  if fio --readonly --output-format=json --output="$out/fio.json" "$jobfile" >"$out/fio.stdout" 2>"$out/fio.stderr"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$rc" >"$out/fio.rc"
  date +%s%N >"$out/fio-end-ns.txt"
  (( rc == 0 )) || return "$rc"
  python3 - "$out/fio.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); jobs=d.get('jobs',[])
if len(jobs)!=128: raise SystemExit(f'expected 128 fio jobs, got {len(jobs)}')
for j in jobs:
    if int(j.get('error',-1))!=0: raise SystemExit(f"fio job error: {j.get('jobname')}={j.get('error')}")
PY
  return $?
}

run_cell() {
  local label=$1 arm=$2 seed=$3 context=${4:-screen}
  local out="$ROOT/cells/$label" mnt; mnt=$(mount_path "$label")
  [[ ! -e $out ]] || die "cell already exists: $label"
  mkdir -p "$out/bw" "$out/pre" "$out/post"
  if pgrep -a -x fio >"$out/foreign-fio-pre.txt" 2>&1; then die "foreign fio exists before $label"; fi
  if [[ $context == screen ]]; then "$SCRUB_CONTROL" verify-paused "$SCRUB_LEASE" >"$out/scrub-pre.txt"; fi
  snapshot_counters "$out/pre"
  mount_arm "$arm" "$label" "$mnt" "$out"
  asset_manifest "$mnt/test_dir" "$out/assets-pre.tsv"
  local jobfile="$out/formal.fio"
  render_jobfile "$jobfile" "$mnt" formal "$label" "$seed"
  assert_jobfile "$jobfile" formal
  local stop="$out/sampler.stop"
  sample_runtime "$out/runtime.tsv" "$stop" >"$out/sampler.stdout" 2>"$out/sampler.stderr" &
  local sampler_pid=$!
  printf '%s\n' "$sampler_pid" >"$out/sampler.pid"
  local fio_rc sampler_rc
  if run_fio_job "$jobfile" "$out"; then fio_rc=0; else fio_rc=$?; fi
  : >"$stop"
  if wait "$sampler_pid"; then sampler_rc=0; else sampler_rc=$?; fi
  printf '%s\n' "$sampler_rc" >"$out/sampler.rc"
  (( fio_rc == 0 && sampler_rc == 0 )) || die "cell failed; preserving mount label=$label fio_rc=$fio_rc sampler_rc=$sampler_rc"
  snapshot_counters "$out/post"
  asset_manifest "$mnt/test_dir" "$out/assets-post.tsv"
  cmp -s "$out/assets-pre.tsv" "$out/assets-post.tsv" || die "asset drift in $label; preserving mount"
  if [[ $context == screen ]]; then "$SCRUB_CONTROL" verify-paused "$SCRUB_LEASE" >"$out/scrub-post.txt"; fi
  graceful_umount "$label" "$mnt" "$out"
  printf 'label\t%s\narm\t%s\nseed\t%s\nstatus\tPASS\n' "$label" "$arm" "$seed" >"$out/CELL-PASS.tsv"
}

cmd_offline_self_test() {
  init_root
  local d="$ROOT/offline-self-test" mnt="/tmp/jfs-04tmp2-$RUN_ID-PREP"
  mkdir -p "$d"
  render_jobfile "$d/warmup.fio" "$mnt" warmup PREP 0
  render_jobfile "$d/formal.fio" "$mnt" formal R01-A 41001
  assert_jobfile "$d/warmup.fio" warmup
  assert_jobfile "$d/formal.fio" formal
  [[ $(grep -c '^filename=' "$d/formal.fio") -eq 128 ]] || die "self-test filename count"
  grep -Fqx "filename=$mnt/test_dir/read_test.0.0" "$d/formal.fio" || die "self-test first filename"
  grep -Fqx "filename=$mnt/test_dir/read_test.127.0" "$d/formal.fio" || die "self-test last filename"
  ! grep -q 'max-readahead' "$d/formal.fio" || die "self-test readahead drift"
  printf 'OFFLINE_SELF_TEST_PASS\n' >"$d/PASS"
  printf 'TMP2_OFFLINE_SELF_TEST_PASS root=%s\n' "$ROOT"
}

cmd_inventory() {
  init_root
  local out="$ROOT/inventory"
  [[ ! -e $out ]] || die "inventory already exists"
  mkdir -p "$out"
  need_cmd findmnt; need_cmd lsblk; need_cmd fio
  hostname -f >"$out/hostname.txt" 2>&1 || hostname >"$out/hostname.txt"
  date -Ins >"$out/time.txt"; uname -a >"$out/uname.txt"
  command -v timedatectl >/dev/null && timedatectl >"$out/timedatectl.txt" 2>&1 || true
  command -v fio >"$out/fio-path.txt"; fio --version >"$out/fio-version.txt"
  [[ -x $JFS ]] || die "JuiceFS binary missing"
  "$JFS" --version >"$out/juicefs-version.txt" 2>&1
  md5sum "$JFS" >"$out/juicefs.md5"; sha256sum "$JFS" >"$out/juicefs.sha256"
  "$JFS" mount --help >"$out/juicefs-mount-help.txt" 2>&1 || true
  "$JFS" warmup --help >"$out/juicefs-warmup-help.txt" 2>&1 || true
  "$JFS" status "$META" >"$out/volume-status.json"
  validate_volume_status "$out/volume-status.json" "$out/volume-setting.tsv"
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-findmnt.tsv"
  asset_manifest "$REFERENCE_MNT/test_dir" "$out/read-assets.tsv"
  findmnt -R "$CACHE_PARENT" -o SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN >"$out/cache-findmnt.txt" 2>&1 || true
  findmnt -T "$CACHE_PARENT" -o SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN >"$out/cache-findmnt-parent.txt" 2>&1 || true
  lsblk -O -J >"$out/lsblk.json"; lsblk -o NAME,KNAME,PKNAME,TYPE,MAJ:MIN,FSTYPE,SIZE,MOUNTPOINTS,MODEL,SERIAL,WWN >"$out/lsblk.txt"
  df -B1 "$CACHE_PARENT" >"$out/cache-df-bytes.txt"; df -i "$CACHE_PARENT" >"$out/cache-df-inodes.txt"
  stat -Lc 'path=%n dev=%d inode=%i mode=%a uid=%u gid=%g type=%F' "$CACHE_PARENT" >"$out/cache-parent-stat.txt"
  # Only the mount-point's direct children decide whether this otherwise empty
  # cache device has foreign occupants.  Do not descend into ext4 lost+found:
  # an unprivileged inventory cannot read it, and doing so used to abort Phase I.
  find "$CACHE_PARENT" -mindepth 1 -maxdepth 1 -printf '%y\t%p\t%s\t%u\t%g\n' | sort >"$out/cache-existing.tsv"
  command -v fuser >/dev/null && fuser -vm "$CACHE_PARENT" >"$out/cache-fuser.txt" 2>&1 || true
  command -v lsof >/dev/null && timeout 30 lsof +D "$CACHE_PARENT" >"$out/cache-lsof.txt" 2>&1 || true
  ps -eo pid,ppid,lstart,comm,args >"$out/processes.txt"
  pgrep -a -x fio >"$out/foreign-fio.txt" 2>&1 || true
  pgrep -af 'juicefs|warmup|t04tmp2' >"$out/juicefs-processes.txt" 2>&1 || true
  if command -v iostat >/dev/null; then timeout 70 iostat -dxm 1 60 >"$out/cache-idle-iostat.txt" 2>"$out/cache-idle-iostat.stderr" || true; fi
  if command -v nvme >/dev/null; then nvme list -o json >"$out/nvme-list.json" 2>"$out/nvme-list.stderr" || true; fi
  if command -v ceph >/dev/null; then
    ceph fsid >"$out/ceph-fsid.txt" 2>"$out/ceph-fsid.stderr" || true
    ceph health detail --format json >"$out/ceph-health.json" 2>"$out/ceph-health.stderr" || true
    ceph osd stat --format json >"$out/ceph-osd-stat.json" 2>"$out/ceph-osd-stat.stderr" || true
    ceph pg dump pgs_brief --format json >"$out/ceph-pgs.json" 2>"$out/ceph-pgs.stderr" || true
    ceph osd dump --format json >"$out/ceph-osd-dump.json" 2>"$out/ceph-osd-dump.stderr" || true
    ceph balancer status >"$out/ceph-balancer.json" 2>"$out/ceph-balancer.stderr" || true
    ceph osd pool ls detail --format json >"$out/ceph-pools.json" 2>"$out/ceph-pools.stderr" || true
  fi
  printf 'KNOWN_EXCLUDED_ASSET\tjfs-r1b-20260901-152736\tDO_NOT_TOUCH\n' >"$out/excluded-assets.tsv"
  find "$out" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >"$out/SHA256SUMS"
  printf 'INVENTORY_COMPLETE\n' >"$out/PASS"
  printf 'TMP2_INVENTORY_COMPLETE root=%s\n' "$ROOT"
}

cmd_plan() {
  init_root
  [[ -f $ROOT/inventory/PASS ]] || die "inventory PASS missing"
  verify_binary
  [[ $CEPH_FSID =~ ^[0-9a-fA-F-]{36}$ ]] || die "TMP2_CEPH_FSID must be frozen from fresh inventory"
  local cr; cr=$(cache_root)
  [[ $cr == "$CACHE_PARENT/jfs-04tmp2-$RUN_ID" ]] || die "cache root scope"
  mkdir -p "$PLAN/jobfiles"
  render_jobfile "$PLAN/jobfiles/PREP-warmup.fio" "$(mount_path PREP)" warmup PREP 0
  render_jobfile "$PLAN/jobfiles/R01-A.fio" "$(mount_path R01-A)" formal R01-A 41001
  render_jobfile "$PLAN/jobfiles/R02-B.fio" "$(mount_path R02-B)" formal R02-B 41001
  render_jobfile "$PLAN/jobfiles/R03-B.fio" "$(mount_path R03-B)" formal R03-B 41002
  render_jobfile "$PLAN/jobfiles/R04-A.fio" "$(mount_path R04-A)" formal R04-A 41002
  cat >"$PLAN/phase-ii.txt" <<EOF
CREATE_CACHE_DIR (non-sudo if parent permits): install -d -m 0700 -- $cr
MOUNT_A: env CEPH_CONF=$CEPH_CONF_PATH $JFS mount -d --read-only --prefetch 0 --max-fuse-io 256K --max-uploads 150 --cache-size 0 $META /tmp/jfs-04tmp2-$RUN_ID-<A_LABEL>
MOUNT_B: env CEPH_CONF=$CEPH_CONF_PATH $JFS mount -d --read-only --prefetch 0 --max-fuse-io 256K --max-uploads 150 --cache-size 65536 --cache-dir $cr --free-space-ratio 0.2 $META /tmp/jfs-04tmp2-$RUN_ID-<B_LABEL>
WARMUP: fio --readonly <128-explicit-file read jobfile, 256MiB per file>
SCREEN: R01-A(seed=41001),R02-B(seed=41001),R03-B(seed=41002),R04-A(seed=41002)
SCRUB_PAUSE: $SCRUB_CONTROL pause $SCRUB_LEASE $CEPH_FSID I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
SCRUB_RESTORE: $SCRUB_CONTROL restore $SCRUB_LEASE
EOF
  "$SCRUB_CONTROL" plan-pause "$SCRUB_LEASE" >"$PLAN/scrub-pause.txt" 2>&1 || true
  printf 'CACHE_ROOT\t%s\nPREPARE_ACK\tI_ACK_TMP2_PREPARE_%s\nSCREEN_ACK\tI_ACK_TMP2_SCREEN_%s\nPOST_ACK\tI_ACK_TMP2_POST_%s\n' \
    "$cr" "$RUN_ID" "$RUN_ID" "$RUN_ID" >"$PLAN/ack.tsv"
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$PLAN/cache-parent.freeze"
  [[ -s $PLAN/cache-parent.freeze ]] || die "cannot freeze cache parent mount identity"
  freeze_scripts
  printf 'PLAN_COMPLETE\n' >"$PLAN/PASS"
  printf 'TMP2_PLAN_COMPLETE root=%s\n' "$ROOT"
}

cmd_prepare() {
  init_root; require_real_ack PREPARE; verify_binary; verify_scripts
  [[ -f $PLAN/PASS ]] || die "plan PASS missing"
  local cr; cr=$(cache_root)
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die "cache parent unavailable/symlink"
  local current_parent avail
  current_parent=$(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS)
  [[ $current_parent == "$(<"$PLAN/cache-parent.freeze")" ]] || die "cache parent mount identity drift"
  avail=$(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')
  [[ $avail =~ ^[0-9]+$ && $avail -ge 274877906944 ]] || die "cache parent has less than 256GiB available"
  local cache_origin expected_uid expected_gid cache_mode
  expected_uid=$(id -u); expected_gid=$(id -g)
  if [[ -e $cr ]]; then
    [[ -d $cr && ! -L $cr ]] || die "precreated cache root is not a regular directory"
    [[ $(stat -Lc %u "$cr") == "$expected_uid" && $(stat -Lc %g "$cr") == "$expected_gid" ]] \
      || die "precreated cache root owner mismatch"
    cache_mode=$(stat -Lc %a "$cr")
    [[ $cache_mode == 700 ]] || die "precreated cache root mode mismatch: $cache_mode"
    [[ -z $(find "$cr" -mindepth 1 -maxdepth 1 -print -quit) ]] \
      || die "precreated cache root is not empty"
    cache_origin=PRECREATED_EMPTY
  else
    install -d -m 0700 -- "$cr"
    cache_origin=RUNNER_CREATED
  fi
  local parent_dev root_dev parent_source
  parent_dev=$(stat -Lc %d "$CACHE_PARENT"); root_dev=$(stat -Lc %d "$cr")
  [[ $parent_dev == "$root_dev" ]] || die "cache root crossed device"
  parent_source=$(findmnt -rn -T "$CACHE_PARENT" -o SOURCE)
  printf 'run_id\t%s\ncache_root\t%s\ncache_parent\t%s\nparent_dev\t%s\nroot_dev\t%s\nparent_source\t%s\ncache_origin\t%s\nstatus\tCREATED\n' \
    "$RUN_ID" "$cr" "$CACHE_PARENT" "$parent_dev" "$root_dev" "$parent_source" "$cache_origin" >"$STATE/cache.tsv"
  local label=PREP mnt out jobfile
  mnt=$(mount_path "$label"); out="$ROOT/prepare"; mkdir -p "$out"
  mount_arm B "$label" "$mnt" "$out"
  asset_manifest "$mnt/test_dir" "$out/assets-pre.tsv"
  jobfile="$out/warmup.fio"; render_jobfile "$jobfile" "$mnt" warmup PREP 0; assert_jobfile "$jobfile" warmup
  snapshot_counters "$out/pre"; run_fio_job "$jobfile" "$out"; snapshot_counters "$out/post"
  asset_manifest "$mnt/test_dir" "$out/assets-post.tsv"
  cmp -s "$out/assets-pre.tsv" "$out/assets-post.tsv" || die "asset drift during warmup; preserving mount"
  graceful_umount "$label" "$mnt" "$out"
  if find "$cr" -xdev -type f -path '*/rawstaging/*' -print -quit | grep -q .; then die "rawstaging detected"; fi
  printf 'status\tPREPARED\n' >>"$STATE/cache.tsv"
  printf 'PREPARE_PASS\n' >"$out/PASS"
  printf 'TMP2_PREPARE_PASS root=%s\n' "$ROOT"
}

RESTORE_REQUIRED=0
restore_scrub_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if (( RESTORE_REQUIRED == 1 )); then
    set +e
    "$SCRUB_CONTROL" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore.stdout" 2>"$ROOT/scrub-restore.stderr"
    local rrc=$?
    if (( rrc == 0 )); then
      "$SCRUB_CONTROL" verify-restored "$SCRUB_LEASE" >"$ROOT/scrub-restored.txt" 2>&1
      rrc=$?
    fi
    set -e
    (( rrc == 0 )) || { printf 'E_TMP2\tscrub restore failed rc=%s\n' "$rrc" >&2; exit 43; }
  fi
  exit "$rc"
}

cmd_screen() {
  init_root; require_real_ack SCREEN; verify_binary; verify_scripts
  [[ $(awk -F'\t' '$1=="status"{v=$2} END{print v}' "$STATE/cache.tsv") == PREPARED ]] \
    || die "cache state is not PREPARED"
  [[ ! -e $ROOT/cells ]] || die "screen cells already exist"
  "$SCRUB_CONTROL" verify-paused "$SCRUB_LEASE" >"$ROOT/scrub-paused.txt"
  RESTORE_REQUIRED=1; trap restore_scrub_on_exit EXIT INT TERM
  mkdir -p "$ROOT/cells"
  run_cell R01-A A 41001 screen
  run_cell R02-B B 41001 screen
  run_cell R03-B B 41002 screen
  run_cell R04-A A 41002 screen
  "$SCRUB_CONTROL" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore.stdout" 2>"$ROOT/scrub-restore.stderr"
  "$SCRUB_CONTROL" verify-restored "$SCRUB_LEASE" >"$ROOT/scrub-restored.txt"
  RESTORE_REQUIRED=0; trap - EXIT INT TERM
  printf 'SCREEN_PASS\n' >"$ROOT/cells/PASS"
  printf 'TMP2_SCREEN_PASS root=%s\n' "$ROOT"
}

cmd_post_anchor() {
  init_root; require_real_ack POST; verify_binary; verify_scripts
  [[ -f $ROOT/MATRIX_PERSISTENCE_PASS ]] || die "matrix persistence gate missing"
  [[ -f $ROOT/CACHE_DESTROYED_PASS ]] || die "cache destroyed gate missing"
  [[ ! -e $(cache_root) ]] || die "cache root still exists"
  "$SCRUB_CONTROL" verify-restored "$SCRUB_LEASE" >"$ROOT/post-scrub-restored.txt"
  run_cell POST-A A 42001 post
  printf 'POST_ANCHOR_PASS\n' >"$ROOT/POST-ANCHOR-PASS"
  printf 'TMP2_POST_ANCHOR_PASS root=%s\n' "$ROOT"
}

validate_run_id
case "$MODE" in
  offline-self-test) cmd_offline_self_test ;;
  inventory) cmd_inventory ;;
  plan) cmd_plan ;;
  prepare) cmd_prepare ;;
  screen) cmd_screen ;;
  post-anchor) cmd_post_anchor ;;
  -h|--help|'') usage; [[ -n $MODE ]] || exit 2 ;;
  *) usage; die "unknown mode: $MODE" ;;
esac
