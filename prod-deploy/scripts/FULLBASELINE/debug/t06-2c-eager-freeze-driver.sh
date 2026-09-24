#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

MODE=${1:-}
RUN_ID=${2:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PARENT=$SCRIPT_DIR/t06-5-randrw-cache-driver.sh
PARENT_SHA256=a50004ec9429e9aba427c12fd984db6ade0d2b721e0dc9685992ea36b3132c6b

# Import only the already executed 06-5 assignments/functions.  Its dispatch
# is never evaluated; this file overrides the matrix, identities and paths.
PARENT_PREFIX=$(python3 - "$PARENT" "$PARENT_SHA256" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
if hashlib.sha256(b).hexdigest()!=sys.argv[2]: raise SystemExit('parent_dependency_drift')
boundary=b'\ncase $MODE in\n'
if b.count(boundary)!=1: raise SystemExit('parent_dispatch_boundary')
print(b.split(boundary)[0].decode())
PY
) || exit 42
eval "$PARENT_PREFIX"
unset PARENT_PREFIX

MODE=${1:-}
RUN_ID=${2:-}
ROOT=/tmp/production/opencode-06-2c-$RUN_ID
PREP=/tmp/production/opencode-06-2c-prep-$RUN_ID
PLAN_OUT=${T062C_PLAN_OUT:-/tmp/t06-2c-plan-$RUN_ID}
ANALYZER=$SCRIPT_DIR/t06-2c-randrw-analyze.py
GATE0=$SCRIPT_DIR/t06-2c-environment-gate0-offline.sh
H_JFS=/tmp/juicefs-1.4.1-patched
C_JFS=$PREP/bin/juicefs-06-2c-c
T_JFS=$PREP/bin/juicefs-06-2c-t
H_MD5=24fae0852051c80ca571cb2f20275d46
C_MD5=9d8df3a58e63ba96aa55ccf167b6e245
T_MD5=0410a03810865d0994c53d568281687b
C_SHA256=a0c7d0fcabe5eacb2599cc299eaf51d9879611369bf7754b6e245884c78f8cea
T_SHA256=5a502e83e5dd9fb7ac7062c09babb49bedfc5e770f99d967baf9fd688ae73304
readonly CACHE_PARENT=/mnt/jfs-cache/04tmp3
readonly MIN_MEM_AVAILABLE_BYTES=$((384*1024*1024*1024))
readonly MIN_CACHE_AVAILABLE_BYTES=$((384*1024*1024*1024))
METRICS_BASE=19740
JFS=$H_JFS
JFS_MD5=$H_MD5

die() { printf 'T062C_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-06-2c-$RUN_ID && $PREP == /tmp/production/opencode-06-2c-prep-$RUN_ID ]] || die unsafe_RUN_paths
  [[ $ROOT != / && $PREP != / && ! -L $ROOT && ! -L $PREP ]] || die unsafe_RUN_path_type
}

matrix_rows() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    1 C1 C 98304 1 \
    2 T1 T 98304 1 \
    3 T2 T 98304 1 \
    4 C2 C 98304 1
}
matrix_order() { matrix_rows | awk -F '\t' '{print $2}' | paste -sd, -; }
recovery_labels() { printf '%s\n' canary C1-post T1-post T2-post C2-post; }

select_build() {
  case $1 in
    H|V) JFS=$H_JFS; JFS_MD5=$H_MD5; JFS_SHA256=8f8b5a911d4f3a91f3f28448599f7465d0624b1338956a5efecfcaeb27d9f3b2; EXPERIMENTAL=0;;
    C) JFS=$C_JFS; JFS_MD5=$C_MD5; JFS_SHA256=$C_SHA256; EXPERIMENTAL=0;;
    T) JFS=$T_JFS; JFS_MD5=$T_MD5; JFS_SHA256=$T_SHA256; EXPERIMENTAL=1;;
    *) die invalid_build;;
  esac
  [[ -x $JFS && ! -L $JFS ]] || die build_missing
  [[ $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die build_md5_drift
  [[ $(sha256sum "$JFS" | awk '{print $1}') == "$JFS_SHA256" ]] || die build_sha256_drift
}

cache_dirs_for_cell() {
  local cell=$1 parent child
  [[ $cell =~ ^(C1|C2|T1|T2|SMOKE-C|SMOKE-T)$ ]] || die invalid_cache_cell
  parent=$CACHE_PARENT; validate_parent "$parent"
  child=$parent/jfs-06-2c-$RUN_ID-$cell
  [[ $child == "$parent/jfs-06-2c-$RUN_ID-$cell" && ! -L $child ]] || die unsafe_cache_child
  printf '%s\n' "$child"
}
create_cache_dirs() {
  local cell=$1 dir=$2
  [[ $dir == "$CACHE_PARENT/jfs-06-2c-$RUN_ID-$cell" && ! -e $dir && ! -L $dir ]] || die cache_dir_precondition
  event CACHE_CREATE_PRE "$dir"; mkdir -m 0700 -- "$dir"; event CACHE_CREATE_POST "$dir"
}
cleanup_cache_dirs() {
  local cell=$1 dir=$2
  [[ $dir == "$CACHE_PARENT/jfs-06-2c-$RUN_ID-$cell" && -d $dir && ! -L $dir ]] || die cleanup_scope
  [[ -f $ROOT/cells/$cell/UNMOUNTED_formal && -f $ROOT/cells/$cell/UNMOUNTED_verify ]] || die cleanup_before_unmount
  event CACHE_CLEANUP_PRE "$dir"; find "$dir" -xdev -depth -mindepth 1 -delete; rmdir -- "$dir"; event CACHE_CLEANUP_POST "$dir"
}

capture_state_snapshot() {
  local cell=$1 tag=$2 metrics=$3 dirs=$4 out=$ROOT/cells/$1/snapshots
  local start_ns end_ns
  mkdir -m 0700 -p "$out"; start_ns=$(date +%s%N)
  [[ -f $out/timeline.tsv ]] || printf 'tag\tcollect_start_ns\tcollect_end_ns\n' >"$out/timeline.tsv"
  awk '/^(MemAvailable|Cached|Dirty|Writeback):/{print}' /proc/meminfo >"$out/$tag-meminfo.txt"
  curl -fsS --max-time 5 "http://$metrics/metrics" >"$out/$tag-juicefs.prom"
  if [[ -n $dirs ]]; then df -B1 --output=source,size,used,avail,pcent,target "$dirs" >"$out/$tag-df.txt"; fi
  if command -v iostat >/dev/null 2>&1; then iostat -dxk 1 2 >"$out/$tag-iostat.txt"; else printf 'IOSTAT_NOT_INSTALLED\n' >"$out/$tag-iostat.txt"; fi
  end_ns=$(date +%s%N); printf '%s\t%s\t%s\n' "$tag" "$start_ns" "$end_ns" >>"$out/timeline.tsv"
}

# Task-specific C/T binary paths are longer than the delivery binary path.
# JuiceFS rewrites argv in place, so their process titles can end before the
# unique --log value.  Bind the two new exact-executable processes to the
# unique launch log by PID/topology instead of requiring an untruncated argv.
mount_pid_gate() {
  local before=$1 out=$2 launch_log=$3
  python3 - "$JFS" "$before" "$launch_log" >"$out" <<'PY'
import hashlib,os,pathlib,re,sys
exe=os.path.realpath(sys.argv[1])
old={int(x) for x in open(sys.argv[2]) if x.strip().isdigit()}
launch=pathlib.Path(sys.argv[3])
log=launch.read_text(errors='replace')
rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if int(p.name) in old or os.path.realpath(p/'exe') != exe:
            continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
        st=(p/'stat').read_text().split()
        rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5((p/'exe').read_bytes()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError):
        pass
pids={x[0] for x in rows}
workers=[x[0] for x in rows if x[1] in pids]
if len(rows)!=2 or len(workers)!=1:
    raise SystemExit(f'non_unique_parent_worker:{rows}')
worker=workers[0]
parent=next(x[0] for x in rows if x[0] != worker)
if f'[{parent}]' not in log or f'[{worker}]' not in log:
    raise SystemExit(f'launch_log_pid_mismatch:parent={parent}:worker={worker}')
if not re.search(r'watching "[^"]+", pid '+str(worker)+r'\b',log):
    raise SystemExit(f'launch_log_watchdog_mismatch:worker={worker}')
print('pid\tppid\tstarttime_ticks\texe_md5\tis_worker\tcmdline')
for row in sorted(rows):
    print(*row[:4], 'yes' if row[0] == worker else 'no', row[4], sep='\t')
PY
}

resource_gate_062c() {
  local mem_available cache_available
  mem_available=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)
  cache_available=$(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')
  [[ $mem_available =~ ^[0-9]+$ && $cache_available =~ ^[0-9]+$ ]] || die resource_parse
  (( mem_available >= MIN_MEM_AVAILABLE_BYTES )) || die insufficient_memory
  (( cache_available >= MIN_CACHE_AVAILABLE_BYTES )) || die insufficient_cache_space
  if pgrep -af '(^|[ /])fio([[:space:]]|$)' | grep -vF 'vfio-irqfd' >/dev/null; then die foreign_fio_present; fi
}

mount_private() {
  local cell=$1 arm=$2 tag=$3 mnt=$4 metrics=$5 dirs=$6
  local cell_root=$ROOT/cells/$cell before=$ROOT/cells/$cell/pids-$tag.before expected
  local -a cmd
  [[ $cell =~ ^(C1|C2|T1|T2|SMOKE-C|SMOKE-T)$ && ( $tag == formal || $tag == verify || $tag == seed ) ]] || die mount_identity_args
  expected=/tmp/jfs-06-2c-$RUN_ID-$cell; [[ $tag == formal ]] || expected+=-$tag
  [[ $mnt == "$expected" && ! -e $mnt && ! -L $mnt ]] || die unsafe_private_mount
  mkdir -m 0700 -- "$mnt"; select_build "$arm"; capture_preexisting_pids "$before"
  cmd=("$JFS" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 --metrics "$metrics" --log "$cell_root/juicefs-$tag.log")
  case $arm in
    C) [[ -n $dirs ]] || die cache_dir_required; cmd+=(--cache-dir "$dirs" --cache-size 98304 --free-space-ratio 0.20 --writeback --upload-delay 0);;
    T) [[ -n $dirs ]] || die cache_dir_required; cmd+=(--cache-dir "$dirs" --cache-size 98304 --free-space-ratio 0.20 --writeback --upload-delay 0 --experimental-eager-freeze);;
    V) [[ -z $dirs ]] || die verify_cache_forbidden; cmd+=(--cache-size 0);;
    *) die invalid_mount_arm;;
  esac
  cmd+=("$META" "$mnt"); log_cmd env CEPH_CONF="$CEPH_CONF" "${cmd[@]}"
  env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$cell_root/mount-$tag.stdout" 2>"$cell_root/mount-$tag.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$cell_root/findmnt-$tag.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$cell_root/findmnt-$tag.tsv" || die mount_identity
  mount_pid_gate "$before" "$cell_root/mount-process-$tag.tsv" "$cell_root/juicefs-$tag.log"
  printf 'arm\t%s\nexperimental_eager_freeze\t%s\nbinary_sha256\t%s\n' "$arm" "$EXPERIMENTAL" "$JFS_SHA256" >"$cell_root/mount-identity-$tag.tsv"
}

graceful_umount() {
  local cell=$1 tag=$2 mnt=$3 expected=/tmp/jfs-06-2c-$RUN_ID-$1
  [[ $tag == formal ]] || expected+=-$tag
  [[ $mnt == "$expected" && ! -L $mnt ]] || die umount_scope
  local process_file=$ROOT/cells/$cell/mount-process-$tag.tsv
  log_cmd timeout 300 "$JFS" umount "$mnt"
  timeout 300 "$JFS" umount "$mnt" >"$ROOT/cells/$cell/umount-$tag.stdout" 2>"$ROOT/cells/$cell/umount-$tag.stderr" || die umount_failed
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains
  for _ in $(seq 1 60); do processes_gone "$process_file" && break; sleep 1; done
  processes_gone "$process_file" || die mount_process_remains
  rmdir -- "$mnt" || die mount_dir_not_empty
  : >"$ROOT/cells/$cell/UNMOUNTED_$tag"
}

semantic_smoke_arm() {
  local arm=$1 cell=SMOKE-$1 pos metrics dirs mnt seed verify file expect got
  [[ $arm == C || $arm == T ]] || die smoke_arm
  pos=$([[ $arm == C ]] && printf 8 || printf 9); metrics=127.0.0.1:$((METRICS_BASE+pos))
  mnt=/tmp/jfs-06-2c-$RUN_ID-$cell; seed=$mnt-seed; verify=$mnt-verify
  mkdir -m 0700 -p "$ROOT/cells/$cell"; dirs=$(cache_dirs_for_cell "$cell"); create_cache_dirs "$cell" "$dirs"
  mount_private "$cell" V seed "$seed" "$metrics" ""
  file=$seed/test_dir/.t06-2c-$RUN_ID-$arm-semantic.bin
  [[ ! -e $file && ! -L $file ]] || die smoke_file_exists
  python3 - "$file" <<'PY'
import hashlib,os,sys
p=sys.argv[1]; data=bytes((i*17+3)&255 for i in range(4*1024*1024))
fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_RDWR,0o600)
try:
 os.ftruncate(fd,len(data))
 for off in range(0,len(data),256*1024):
  if os.pwrite(fd,data[off:off+256*1024],off)!=256*1024: raise SystemExit('short_write')
 os.fsync(fd)
finally: os.close(fd)
PY
  graceful_umount "$cell" seed "$seed"
  mount_private "$cell" "$arm" formal "$mnt" "$metrics" "$dirs"
  file=$mnt/test_dir/.t06-2c-$RUN_ID-$arm-semantic.bin
  python3 - "$file" "$ROOT/cells/$cell/expected.sha256" <<'PY'
import hashlib,os,sys
p=sys.argv[1]; data=bytes((i*31+7)&255 for i in range(4*1024*1024))
fd=os.open(p,os.O_RDWR)
try:
 if os.fstat(fd).st_size!=len(data): raise SystemExit('unstable_eof')
 for off in range(0,len(data),256*1024):
  if os.pwrite(fd,data[off:off+256*1024],off)!=256*1024: raise SystemExit('short_overwrite')
 got=os.pread(fd,len(data),0)
 if got!=data: raise SystemExit('same_handle_read_mismatch')
finally: os.close(fd)
open(sys.argv[2],'w').write(hashlib.sha256(data).hexdigest()+'\n')
PY
  drain_writeback "$cell" "$metrics" "$dirs" || return $?
  graceful_umount "$cell" formal "$mnt"
  mount_private "$cell" V verify "$verify" "$metrics" ""
  expect=$(cat "$ROOT/cells/$cell/expected.sha256")
  got=$(dd if="$verify/test_dir/.t06-2c-$RUN_ID-$arm-semantic.bin" bs=4M count=1 status=none | sha256sum | awk '{print $1}')
  [[ $got == "$expect" ]] || die independent_readback_mismatch
  rm -- "$verify/test_dir/.t06-2c-$RUN_ID-$arm-semantic.bin"
  graceful_umount "$cell" verify "$verify"
  cleanup_cache_dirs "$cell" "$dirs"; printf 'SEMANTIC_SMOKE_PASS\n' >"$ROOT/cells/$cell/PASS"
}
semantic_smoke() { semantic_smoke_arm C; semantic_smoke_arm T; }

recovery_gate() {
  local tag=$1
  shared_session_gate "$tag-pre"
  [[ $tag != canary || -f $ROOT/correctness/SMOKE_PASS ]] || {
    resource_gate_062c; mkdir -m 0700 -p "$ROOT/correctness"; semantic_smoke; printf 'SMOKE_PASS\n' >"$ROOT/correctness/SMOKE_PASS";
  }
  select_build H; legacy_recovery_gate "$tag"; shared_session_gate "$tag-post"
}

run_cell() {
  local pos=$1 cell=$2 arm=$3 cache_mib=$4 writeback=$5
  local cell_root=$ROOT/cells/$cell mnt=/tmp/jfs-06-2c-$RUN_ID-$cell metrics=127.0.0.1:$((METRICS_BASE+pos)) dirs
  local verify=$mnt-verify
  [[ $cache_mib == 98304 && $writeback == 1 && ! -e $cell_root ]] || die cell_contract
  resource_gate_062c
  mkdir -m 0700 -p "$cell_root"; dirs=$(cache_dirs_for_cell "$cell"); create_cache_dirs "$cell" "$dirs"
  select_build "$arm"
  printf 'cell\t%s\narm\t%s\ncache_mib\t%s\nwriteback\t%s\ncache_dirs\t%s\nbinary_sha256\t%s\n' "$cell" "$arm" "$cache_mib" "$writeback" "$dirs" "$JFS_SHA256" >"$cell_root/state.tsv"
  verify_assets "$REF" "$cell_root/assets-before.tsv"; health_gate "$cell_root/health-before"
  mount_private "$cell" "$arm" formal "$mnt" "$metrics" "$dirs"; verify_assets "$mnt" "$cell_root/assets-mounted.tsv"
  capture_state_snapshot "$cell" quiet-before-warmup "$metrics" "$dirs"
  date +%s%N >"$cell_root/warmup-command-start-ns.txt"
  run_warmup "$cell" "$mnt"
  date +%s%N >"$cell_root/warmup-command-end-ns.txt"
  capture_state_snapshot "$cell" warmup-end "$metrics" "$dirs"
  start_samplers "$cell" "$metrics" "$dirs"
  capture_state_snapshot "$cell" formal-start "$metrics" "$dirs"
  run_formal "$cell" "$mnt"; stop_samplers
  if (( FORMAL_RC != 0 )); then event FIO_FAIL_PRESERVE_MOUNT "$cell:rc=$FORMAL_RC"; return "$FORMAL_RC"; fi
  drain_writeback "$cell" "$metrics" "$dirs" || return $?
  graceful_umount "$cell" formal "$mnt"; mount_private "$cell" V verify "$verify" "$metrics" ""
  readback_verify "$cell" "$verify"; graceful_umount "$cell" verify "$verify"
  recovery_gate "$cell-post"; verify_assets "$REF" "$cell_root/assets-after.tsv"
  cmp -s "$cell_root/assets-before.tsv" "$cell_root/assets-after.tsv" || die assets_changed
  health_gate "$cell_root/health-after"; cleanup_cache_dirs "$cell" "$dirs"; printf 'CELL_RAW_PASS\n' >"$cell_root/PASS"
}

write_plan() {
  local out=$1
  [[ $out == /* && $out != / && ! -e $out && ! -L $out ]] || die unsafe_plan_output
  mkdir -m 0700 -p "$out"
  { printf 'position\tcell\tbuild\tcache_mib\twriteback\n'; matrix_rows; } >"$out/matrix.tsv"
  { printf 'ordinal\tlabel\tmaximum\n'; i=0; while read -r x; do i=$((i+1)); printf '%s\t%s\t1\n' "$i" "$x"; done < <(recovery_labels); } >"$out/recovery.tsv"
  {
    printf 'operation\tscope\tmaximum\n'
    printf 'upload\t%s and frozen scripts/binaries\tone prep\n' "$PREP"
    printf 'portal-maintenance\t152 exact namespace timer/collector/mount\tone pause+restore\n'
    printf 'scrub-flags\tCeph noscrub/nodeep-scrub\tone pause+restore\n'
    printf 'semantic-smoke\ttwo exact RUN files and private mounts\tC+T once\n'
    printf 'gc-compact\tUUID e1b69ea9-0e3d-427d-bea9-8765928afa66\t5\n'
    printf 'private-mount\tRUN-scoped C/T/verify mountpoints\tfour cells plus smoke\n'
    printf 'fio\t128 existing 1GiB files\tfour 180s cells\n'
    printf 'cache-cleanup\texact RUN children below %s\tafter drain+unmount only\n' "$CACHE_PARENT"
    printf 'resource-gate\tMemAvailable and cache filesystem available\tminimum 384 GiB each\n'
  } >"$out/write-operations.tsv"
  printf 'FORBIDDEN: format layout pool PG CRUSH OSD/TiKV service change drop_caches forced/lazy unmount pattern kill\n' >"$out/forbidden.txt"
  sha256sum "$out"/* >"$out/plan.sha256"
}

offline_self_test() {
  valid_run
  [[ $(matrix_order) == C1,T1,T2,C2 && $(matrix_rows | wc -l) -eq 4 ]] || die matrix
  [[ $(matrix_rows | awk -F '\t' '$4==98304&&$5==1{n++}END{print n+0}') -eq 4 ]] || die configuration
  [[ $(recovery_labels | wc -l) -eq 5 ]] || die recovery_count
  [[ $(recovery_labels | paste -sd, -) == canary,C1-post,T1-post,T2-post,C2-post ]] || die recovery_order
  grep -Fq -- '--experimental-eager-freeze' <(declare -f mount_private) || die treatment_flag_missing
  printf 'T062C_DRIVER_SELF_TEST_PASS\tmatrix=%s\trecovery_max=5\n' "$(matrix_order)"
}

require_online_ack() {
  valid_run
  [[ ${T062C_EXECUTE_ACK:-} == I_ACK_06_2C_PHASE_$RUN_ID ]] || die execute_ack_missing
  [[ ${T062C_PATH_ACK:-} == I_ACK_06_2C_PATHS_$RUN_ID ]] || die path_ack_missing
  [[ ${T062C_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
  [[ ${T062C_MAINTENANCE_ACK:-} == I_ACK_06_2C_PORTAL_PAUSED_$RUN_ID ]] || die maintenance_ack_missing
  [[ -r ${T062C_CACHE_CONTRACT:-} && ! -L ${T062C_CACHE_CONTRACT:-/none} ]] || die cache_contract_missing
  local kind file var expected
  for kind in DRIVER ANALYZER GATE0 SCRUB PORTAL CONTRACT; do
    case $kind in
      DRIVER) file=$0;; ANALYZER) file=$ANALYZER;; GATE0) file=$GATE0;; SCRUB) file=$SCRUB;;
      PORTAL) file=$SCRIPT_DIR/t06-5-portal-maintenance.sh;; CONTRACT) file=$T062C_CACHE_CONTRACT;;
    esac
    var=T062C_${kind}_SHA256; expected=${!var:-}
    [[ $expected =~ ^[0-9a-f]{64}$ && -f $file && ! -L $file && $(sha256sum "$file" | awk '{print $1}') == "$expected" ]] || die frozen_dependency_drift_$kind
  done
  select_build C; select_build T; select_build H
  T065_CACHE_CONTRACT=$T062C_CACHE_CONTRACT
  T065_CEPH_FSID=${T062C_CEPH_FSID:?}
  T061_CEPH_FSID=$T065_CEPH_FSID
}

portal_paused_gate() {
  local state
  state=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/sunrise/.ssh/known_hosts 10.20.1.152 \
    "printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"\$(systemctl is-active juicefs-portal.service)\" \"\$(systemctl is-active juicefs-namespace-mount.service || true)\" \"\$(systemctl is-active juicefs-namespace-collector.service || true)\" \"\$(systemctl is-active juicefs-namespace-collector.timer || true)\" \"\$(findmnt -rn -M /var/lib/juicefs-portal/namespace-mount 2>/dev/null || true)\"") || die portal_state_unreadable
  [[ $state == $'active\tinactive\tinactive\tinactive\t' ]] || die portal_not_paused_exactly
}
phase_062c() {
  require_online_ack
  [[ ${T062C_WRAPPER_ACTIVE:-} == I_ACK_06_2C_WRAPPER_$RUN_ID ]] || die wrapper_required
  portal_paused_gate
  phase_065
}

case $MODE in
  --self-test) offline_self_test;;
  preflight-online) require_online_ack; resource_gate_062c; printf 'T062C_ONLINE_PREFLIGHT_PASS\n';;
  plan) valid_run; write_plan "$PLAN_OUT"; printf 'T062C_PLAN_PASS\t%s\n' "$PLAN_OUT";;
  phase) phase_062c;;
  *) printf 'usage: %s --self-test|preflight-online|plan|phase RUN_ID\n' "$0" >&2; exit 2;;
esac
