#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# 06-1 minimal driver.  `--self-test` and `plan` are the only Stage-0A modes.
# Online modes are inert unless the exact post-Gate authorization tokens and
# the approved path contract are supplied.
MODE=${1:-}
RUN_ID=${2:-}
REMOTE_PARENT=/tmp/production
ROOT=$REMOTE_PARENT/opencode-06-1-$RUN_ID
PLAN_OUT=${T061_PLAN_OUT:-/tmp/t06-1-plan-$RUN_ID}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
ANALYZER=$SCRIPT_DIR/t06-1-randrw-analyze.py
GATE0=$SCRIPT_DIR/t06-1-gate0-offline.sh
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REF=/mnt/juicefs
CEPH_CONF=/etc/ceph/ceph.conf
FIO=fio
RUNTIME=180
WARMUP_RUNTIME=60
CACHE_MIB=98304
METRICS_BASE=19610
DRAIN_TIMEOUT=900
GC_TIMEOUT=1800
ACTIVE_SAMPLER_PID=
ACTIVE_SAMPLER_STOP=
ACTIVE_IOSTAT_PID=
SCRUB_ACTIVE=0
SCRUB_LEASE=
FORMAL_RC=0

die() { printf 'T061_DRIVER_FAIL\t%s\n' "$*" >&2; exit 42; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == "$REMOTE_PARENT/opencode-06-1-$RUN_ID" && $ROOT != / && ! -L $ROOT ]] || die unsafe_result_root
}
matrix_rows() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    1 C1 C 0 0 \
    2 T1 T "$CACHE_MIB" 1 \
    3 T2 T "$CACHE_MIB" 1 \
    4 C2 C 0 0
}
matrix_order() { matrix_rows | awk -F '\t' '{print $2}' | paste -sd, -; }
event() {
  local kind=$1
  local detail=$2
  printf '%s\t%s\t%s\n' "$(date +%s%N)" "$kind" "$detail" >>"$ROOT/incidents.tsv"
}
log_cmd() { printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }

write_plans() {
  local out=$1
  [[ $out == /* && $out != / && ! -L $out ]] || die unsafe_plan_output
  mkdir -m 0700 -p "$out/gate0"
  {
    printf 'position\tcell\tarm\tcache_mib\twriteback\n'
    matrix_rows
  } >"$out/gate0/phase-a-matrix.tsv"
  cat >"$out/gate0/command-plan.tsv" <<'EOF'
stage	operation	classification	target	command_template
0B	remote-inventory	READ_ONLY	157	ssh thailand '<read-only host/device/filesystem/owner/capacity/process inventory>'
0B	ceph-health	READ_ONLY	Ceph	ssh thailand 'ceph -s --format json; ceph osd stat --format json; ceph pg dump pgs_brief'
0B	tikv-metrics	READ_ONLY	10.20.1.150-152	ssh thailand 'curl -fsS http://10.20.1.<node>:20180/metrics'
0B	juicefs-metrics	READ_ONLY	/mnt/juicefs	ssh thailand 'curl -fsS http://<existing-mount-metrics>/metrics'
0B	asset-manifest	READ_ONLY	/mnt/juicefs/test_dir	ssh thailand 'find -P /mnt/juicefs/test_dir -maxdepth 1 -type f -name rw_test.*.0 -printf ...'
1	create-result-root	WRITE_RUN_SCOPED	/tmp/production/opencode-06-1-<RUN_ID>	mkdir -m 0700 -p <RUN_ROOT>
1	pause-scrub	WRITE_GLOBAL_REQUIRES_APPROVAL	Ceph flags	u141d-scrub-control.sh pause <LEASE> <FSID> I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
1	juicefs-gc	WRITE_EXISTING_VOLUME_REQUIRES_APPROVAL	juicefs-prod	juicefs gc --compact --delete --threads 32 <META>
1	create-cache-dir	WRITE_APPROVED_PATH_ONLY	<APPROVED_PARENT>/jfs-06-1-<RUN_ID>-<CELL>	mkdir -m 0700 <EXACT_RUN_CELL_DIR>
1	mount-private	WRITE_PRIVATE_MOUNT	/tmp/jfs-06-1-<RUN_ID>-<CELL>	juicefs mount -d <FROZEN_ARGS> <META> <PRIVATE_MOUNT>
1	warmup	WRITE_WORKLOAD_READ_ONLY	/test_dir/rw_test.*.0	fio randread direct=1 runtime=60 (same command both arms)
1	formal-fio	WRITE_EXISTING_FILES_REQUIRES_APPROVAL	/test_dir/rw_test.0.0..127.0	fio randrw direct=1 runtime=180 allow_file_create=0
1	drain	READ_ONLY	<APPROVED_CACHE_DIRS>/rawstaging	poll metrics and exact RUN cache directories until strict zero
1	umount-original	WRITE_PRIVATE_MOUNT	/tmp/jfs-06-1-<RUN_ID>-<CELL>	juicefs umount <PRIVATE_MOUNT>
1	mount-cache0-verify	WRITE_PRIVATE_MOUNT	/tmp/jfs-06-1-<RUN_ID>-<CELL>-verify	juicefs mount -d --cache-size 0 <META> <VERIFY_MOUNT>
1	readback	READ_ONLY	four fixed rw_test files	fio direct=1 rw=read size=4M
1	umount-cache0-verify	WRITE_PRIVATE_MOUNT	/tmp/jfs-06-1-<RUN_ID>-<CELL>-verify	juicefs umount <VERIFY_MOUNT>
1	cleanup-cache	DELETE_RUN_SCOPED_REQUIRES_APPROVAL	<APPROVED_PARENT>/jfs-06-1-<RUN_ID>-<CELL>	find <EXACT_VERIFIED_RUN_CELL_DIR> -xdev -depth -mindepth 1 -delete; rmdir <EXACT_DIR>
2	restore-scrub	WRITE_GLOBAL_MANDATORY	Ceph flags	u141d-scrub-control.sh restore <LEASE>
EOF
  cat >"$out/gate0/write-operations.tsv" <<'EOF'
operation	scope	authorization
mkdir-result	RUN-scoped /tmp result root	future Phase-A approval
pause/restore-scrub	exact state-owned Ceph flags	future explicit sudo-write approval
juicefs-gc	existing juicefs-prod namespace	future Phase-A approval
mkdir/cleanup-cache	each explicitly approved parent + exact RUN/CELL child	future per-path approval
mount/umount	RUN-private mountpoints only	future Phase-A approval
fio-randrw	existing rw_test.0.0..127.0 overwrite only	future Phase-A approval
EOF
  cat >"$out/gate0/forbidden-operations.tsv" <<'EOF'
operation	status
format/layout/destroy-volume	FORBIDDEN
pool/PG/CRUSH/TiKV/OSD-config-change	FORBIDDEN
drop_caches	FORBIDDEN
binary-replacement-or-build	FORBIDDEN
touch-/mnt/juicefs	FORBIDDEN
forced/lazy-unmount-or-pattern-kill	FORBIDDEN
cache-expire	FORBIDDEN
cleanup-outside-exact-RUN-cache-dir	FORBIDDEN
EOF
  cat >"$out/gate0/warmup.fio" <<'EOF'
[global]
ioengine=libaio
iodepth=128
numjobs=128
rw=randread
bs=256K
filesize=1G
size=1G
direct=1
fallocate=none
allow_file_create=0
openfiles=128
time_based=1
runtime=60
group_reporting=1
randrepeat=1
randseed=20260915
filename_format=<PRIVATE_MOUNT>/test_dir/rw_test.$jobnum.0
[job]
EOF
  sha256sum "$out/gate0/warmup.fio" >"$out/gate0/warmup.sha256"
  cat >"$out/gate0/lifecycle-order.tsv" <<'EOF'
order	action
10	fio_end
20	original_mount_kept_alive
30	rawstaging_strict_zero
40	original_mount_graceful_umount
50	cache_size_0_verify_mount
60	remote_readback_no_EIO
70	verify_mount_graceful_umount
80	gc_and_recovery_gate
90	exact_RUN_cache_cleanup
EOF
}

require_online_ack() {
  valid_run
  [[ ${T061_EXECUTE_ACK:-} == I_ACK_06_1_PHASE_A_$RUN_ID ]] || die execute_ack_missing
  [[ ${T061_PATH_ACK:-} == I_ACK_06_1_CACHE_PATHS_$RUN_ID ]] || die path_ack_missing
  [[ ${T061_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
  [[ -r ${T061_CACHE_CONTRACT:-} && ! -L ${T061_CACHE_CONTRACT:-/nonexistent} ]] || die approved_path_contract_missing
  [[ ${T061_DRIVER_SHA256:-} =~ ^[0-9a-f]{64}$ && ${T061_ANALYZER_SHA256:-} =~ ^[0-9a-f]{64}$ && ${T061_GATE0_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || die frozen_sha256_missing
  [[ $(sha256sum "$0" | awk '{print $1}') == "$T061_DRIVER_SHA256" ]] || die driver_drift
  [[ $(sha256sum "$ANALYZER" | awk '{print $1}') == "$T061_ANALYZER_SHA256" ]] || die analyzer_drift
  [[ $(sha256sum "$GATE0" | awk '{print $1}') == "$T061_GATE0_SHA256" ]] || die gate0_drift
}

approved_parents() {
  awk -F '\t' 'NR>1 && $1=="APPROVED" {print $2}' "$T061_CACHE_CONTRACT"
}
contract_value() {
  local parent=$1
  local field=$2
  awk -F '\t' -v p="$parent" -v wanted="$field" '
    NR==1 {for (i=1;i<=NF;i++) if ($i==wanted) column=i; next}
    $1=="APPROVED" && $2==p {count++; value=$column}
    END {if (!column || count!=1) exit 1; print value}
  ' "$T061_CACHE_CONTRACT"
}
validate_parent() {
  local parent=$1
  local expected_real expected_source expected_major expected_physical expected_fstype
  local expected_uuid expected_target expected_options expected_uid expected_gid expected_mode
  local actual_real actual_source actual_major actual_physical actual_fstype actual_uuid
  local actual_target actual_options actual_uid actual_gid actual_mode device
  [[ $parent == /* && $parent != / && $parent != /tmp && $parent != /mnt && $parent != *..* && ! -L $parent ]] || die unsafe_cache_parent
  [[ -d $parent ]] || die approved_parent_missing
  awk -F '\t' -v p="$parent" 'NR>1 && $1=="APPROVED" && $2==p {n++} END{exit n==1?0:1}' "$T061_CACHE_CONTRACT" || die parent_not_uniquely_approved
  expected_real=$(contract_value "$parent" realpath) || die contract_realpath_missing
  expected_source=$(contract_value "$parent" source) || die contract_source_missing
  expected_major=$(contract_value "$parent" major_minor) || die contract_major_missing
  expected_physical=$(contract_value "$parent" physical_leaf_devices) || die contract_physical_missing
  expected_fstype=$(contract_value "$parent" fstype) || die contract_fstype_missing
  expected_uuid=$(contract_value "$parent" filesystem_uuid) || die contract_uuid_missing
  expected_target=$(contract_value "$parent" mount_target) || die contract_target_missing
  expected_options=$(contract_value "$parent" mount_options) || die contract_options_missing
  expected_uid=$(contract_value "$parent" owner_uid) || die contract_uid_missing
  expected_gid=$(contract_value "$parent" owner_gid) || die contract_gid_missing
  expected_mode=$(contract_value "$parent" mode) || die contract_mode_missing
  actual_real=$(realpath -e "$parent") || die cache_parent_realpath
  read -r actual_source actual_major actual_fstype actual_target actual_options < <(findmnt -bnr -T "$parent" -o SOURCE,MAJ:MIN,FSTYPE,TARGET,OPTIONS) || die cache_parent_findmnt
  device=${actual_source%%[*}
  actual_physical=$(lsblk -snro KNAME "$device" 2>/dev/null | tail -1 || true)
  actual_uuid=$(lsblk -dnro UUID "$device" 2>/dev/null || true)
  read -r actual_uid actual_gid actual_mode < <(stat -Lc '%u %g %a' "$parent") || die cache_parent_stat
  [[ -w $parent ]] || die cache_parent_not_writable
  [[ $actual_real == "$expected_real" && $actual_source == "$expected_source" &&
     $actual_major == "$expected_major" && $actual_physical == "$expected_physical" &&
     $actual_fstype == "$expected_fstype" && $actual_uuid == "$expected_uuid" &&
     $actual_target == "$expected_target" && $actual_options == "$expected_options" &&
     $actual_uid == "$expected_uid" && $actual_gid == "$expected_gid" &&
     $actual_mode == "$expected_mode" ]] || die cache_parent_identity_drift
}
cache_dirs_for_cell() {
  local cell=$1
  local parent
  local child
  local joined=
  while IFS= read -r parent; do
    [[ -n $parent ]] || continue
    validate_parent "$parent"
    child=$parent/jfs-06-1-$RUN_ID-$cell
    [[ $child == "$parent/jfs-06-1-$RUN_ID-$cell" && ! -L $child ]] || die unsafe_cache_child
    if [[ -z $joined ]]; then joined=$child; else joined=$joined:$child; fi
  done < <(approved_parents)
  [[ -n $joined ]] || die no_approved_cache_parent
  printf '%s\n' "$joined"
}

verify_assets() {
  local base=$1
  local out=$2
  [[ -d $base/test_dir && ! -L $base/test_dir ]] || die asset_dir_missing
  find -P "$base/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$out"
  [[ $(wc -l <"$out") -eq 128 ]] || die asset_count
  awk -F '\t' '$3 != 1073741824 {bad=1} END{exit bad}' "$out" || die asset_size
}
health_gate() {
  local out=$1
  mkdir -m 0700 -p "$out"
  ceph --conf "$CEPH_CONF" -s -f json >"$out/ceph-status.json" || die ceph_health
  ceph --conf "$CEPH_CONF" osd stat -f json >"$out/osd-stat.json" || die ceph_osd
  ceph --conf "$CEPH_CONF" pg dump pgs_brief >"$out/pgs.txt" || die ceph_pg
  python3 - "$out/ceph-status.json" "$out/osd-stat.json" "$out/pgs.txt" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); o=json.load(open(sys.argv[2]))
h=s.get('health') or {}; checks=h.get('checks') or {}
paused=h.get('status')=='HEALTH_WARN' and set(checks)=={'OSDMAP_FLAGS'}
if not (h.get('status')=='HEALTH_OK' or paused): raise SystemExit('health_not_accepted')
if o.get('num_osds')!=6 or o.get('num_up_osds')!=6 or o.get('num_in_osds')!=6: raise SystemExit('osd_not_6_up_in')
states=[]
for line in open(sys.argv[3]):
    fields=line.split()
    if fields and fields[0][:1].isdigit() and len(fields)>1: states.append(fields[1])
if not states or any(x!='active+clean' for x in states): raise SystemExit('pg_not_clean')
PY
}
recovery_gate() {
  local tag=$1
  local out=$ROOT/recovery/$tag
  local stable=0
  local previous_objects=
  local previous_stored=
  local objects
  local stored
  local p1
  local p2
  local p3
  mkdir -m 0700 -p "$out"
  log_cmd env CEPH_CONF="$CEPH_CONF" timeout "$GC_TIMEOUT" "$JFS" gc --compact --delete --threads 32 "$META"
  timeout "$GC_TIMEOUT" env CEPH_CONF="$CEPH_CONF" "$JFS" gc --compact --delete --threads 32 "$META" >"$out/gc.stdout" 2>"$out/gc.stderr" || die gc_failed
  printf 'sample\tobjects\tstored\tpending_150\tpending_151\tpending_152\n' >"$out/gate.tsv"
  for sample in $(seq 1 180); do
    ceph --conf "$CEPH_CONF" df -f json >"$out/ceph-df-$sample.json" || die ceph_df
    read -r objects stored < <(python3 - "$out/ceph-df-$sample.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); p=[x for x in d.get('pools',[]) if x.get('name')=='juicefs-data']
if len(p)!=1: raise SystemExit('pool_not_unique')
s=p[0]['stats']; print(int(s['objects']),int(s['stored']))
PY
    ) || die pool_stats
    for node in 150 151 152; do curl -fsS --connect-timeout 3 --max-time 5 "http://10.20.1.$node:20180/metrics" >"$out/tikv-$sample-$node.prom" || die tikv_metrics; done
    p1=$(awk '/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n++}END{if(!n)exit 1;printf "%.0f",s}' "$out/tikv-$sample-150.prom") || die pending_150
    p2=$(awk '/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n++}END{if(!n)exit 1;printf "%.0f",s}' "$out/tikv-$sample-151.prom") || die pending_151
    p3=$(awk '/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n++}END{if(!n)exit 1;printf "%.0f",s}' "$out/tikv-$sample-152.prom") || die pending_152
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sample" "$objects" "$stored" "$p1" "$p2" "$p3" >>"$out/gate.tsv"
    if [[ $p1 == 0 && $p2 == 0 && $p3 == 0 && -n $previous_objects && $objects == $previous_objects ]] && awk -v a="$stored" -v b="$previous_stored" 'BEGIN{d=a-b;if(d<0)d=-d;exit d<=16777216?0:1}'; then stable=$((stable+1)); else stable=0; fi
    previous_objects=$objects
    previous_stored=$stored
    (( stable >= 3 )) && { printf 'RECOVERY_GATE_PASS\n' >"$out/PASS"; return 0; }
    sleep 10
  done
  die recovery_timeout
}

capture_preexisting_pids() {
  local out=$1
  : >"$out"
  for proc in /proc/[0-9]*; do
    [[ -e $proc/exe && $(realpath "$proc/exe" 2>/dev/null) == "$JFS" ]] && basename "$proc" >>"$out" || true
  done
}
mount_pid_gate() {
  local before=$1
  local out=$2
  local launch_log=$3
  python3 - "$JFS" "$before" "$launch_log" >"$out" <<'PY'
import hashlib,os,pathlib,sys
exe=os.path.realpath(sys.argv[1]); old={int(x) for x in open(sys.argv[2]) if x.strip().isdigit()}; launch_log=sys.argv[3]; rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        if int(p.name) in old or os.path.realpath(p/'exe')!=exe: continue
        cmd=(p/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace').strip()
        # JuiceFS is a Go program and rewrites its process title into the
        # original argv buffer.  Long treatment commands can therefore be
        # truncated after --cache-dir.  The unique per-cell --log argument is
        # deliberately placed earlier and remains a reliable launch marker.
        if launch_log not in cmd: continue
        st=(p/'stat').read_text().split(); rows.append((int(p.name),int(st[3]),int(st[21]),hashlib.md5((p/'exe').read_bytes()).hexdigest(),cmd))
    except (OSError,ValueError,IndexError): pass
pids={x[0] for x in rows}; workers=[x[0] for x in rows if x[1] in pids]
if len(rows)!=2 or len(workers)!=1: raise SystemExit(f'non_unique_parent_worker:{rows}')
print('pid\tppid\tstarttime_ticks\texe_md5\tis_worker\tcmdline')
for row in sorted(rows): print(*row[:4], 'yes' if row[0] in workers else 'no', row[4], sep='\t')
PY
}
processes_gone() {
  local file=$1
  python3 - "$JFS" "$file" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
for row in csv.DictReader(open(sys.argv[2]),delimiter='\t'):
    try:
        if os.path.realpath('/proc/'+row['pid']+'/exe')==exe and open('/proc/'+row['pid']+'/stat').read().split()[21]==row['starttime_ticks']: raise SystemExit(1)
    except OSError: pass
PY
}
mount_private() {
  local cell=$1
  local arm=$2
  local tag=$3
  local mnt=$4
  local metrics=$5
  local dirs=$6
  local cell_root=$ROOT/cells/$cell
  local before=$cell_root/pids-$tag.before
  local -a cmd
  [[ $mnt == /tmp/jfs-06-1-$RUN_ID-$cell* && $mnt != / && ! -L $mnt && ! -e $mnt ]] || die unsafe_private_mount
  mkdir -m 0700 "$mnt"
  capture_preexisting_pids "$before"
  cmd=("$JFS" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 --metrics "$metrics" --log "$cell_root/juicefs-$tag.log")
  if [[ $arm == T ]]; then
    cmd+=(--cache-dir "$dirs" --cache-size "$CACHE_MIB" --free-space-ratio 0.20 --writeback)
  else
    cmd+=(--cache-size 0)
  fi
  cmd+=("$META" "$mnt")
  log_cmd env CEPH_CONF="$CEPH_CONF" "${cmd[@]}"
  env CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$cell_root/mount-$tag.stdout" 2>"$cell_root/mount-$tag.stderr"
  for _ in $(seq 1 120); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$cell_root/findmnt-$tag.tsv"
  grep -Fq "JuiceFS:juicefs-prod $mnt fuse.juicefs" "$cell_root/findmnt-$tag.tsv" || die mount_identity
  mount_pid_gate "$before" "$cell_root/mount-process-$tag.tsv" "$cell_root/juicefs-$tag.log"
}
graceful_umount() {
  local cell=$1
  local tag=$2
  local mnt=$3
  local process_file=$ROOT/cells/$cell/mount-process-$tag.tsv
  log_cmd timeout 300 "$JFS" umount "$mnt"
  timeout 300 "$JFS" umount "$mnt" >"$ROOT/cells/$cell/umount-$tag.stdout" 2>"$ROOT/cells/$cell/umount-$tag.stderr" || die umount_failed
  for _ in $(seq 1 180); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains
  for _ in $(seq 1 60); do processes_gone "$process_file" && break; sleep 1; done
  processes_gone "$process_file" || die mount_process_remains
  rmdir "$mnt" || die mount_dir_not_empty
}

create_cache_dirs() {
  local cell=$1
  local joined=$2
  local dir
  local parent
  IFS=: read -r -a paths <<<"$joined"
  for dir in "${paths[@]}"; do
    parent=${dir%/*}
    validate_parent "$parent"
    [[ $dir == "$parent/jfs-06-1-$RUN_ID-$cell" && ! -e $dir && ! -L $dir ]] || die cache_dir_precondition
    event CACHE_CREATE_PRE "$dir"
    mkdir -m 0700 "$dir"
    [[ -d $dir && ! -L $dir && -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_dir_not_empty
    event CACHE_CREATE_POST "$dir"
  done
}
cleanup_cache_dirs() {
  local cell=$1
  local joined=$2
  local dir
  local parent
  IFS=: read -r -a paths <<<"$joined"
  for dir in "${paths[@]}"; do
    parent=${dir%/*}
    validate_parent "$parent"
    [[ $dir == "$parent/jfs-06-1-$RUN_ID-$cell" && -d $dir && ! -L $dir ]] || die cleanup_scope
    [[ -z $(findmnt -rn -R "$dir" -o TARGET 2>/dev/null) ]] || die cache_dir_is_mount
    event CACHE_CLEAN_PRE "$dir"
    find "$dir" -xdev -depth -mindepth 1 -delete
    [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_cleanup_incomplete
    rmdir "$dir"
    event CACHE_CLEAN_POST "$dir"
  done
}

write_fio_job() {
  local out=$1
  local mnt=$2
  local mode=$3
  local duration=$4
  local logs=$5
  mkdir -m 0700 -p "$out"
  [[ $logs == yes ]] && mkdir -m 0700 -p "$out/bw" "$out/clat"
  {
    printf '%s\n' '[global]' 'ioengine=libaio' 'iodepth=128' 'numjobs=128' "rw=$mode" 'rwmixread=50' 'bs=256K' 'filesize=1G' 'size=1G' 'direct=1' 'fallocate=none' 'allow_file_create=0' 'openfiles=128' 'time_based=1' "runtime=$duration" 'group_reporting=1' 'randrepeat=1' 'randseed=20260915'
    if [[ $logs == yes ]]; then printf 'write_bw_log=%s/bw/randrw\nwrite_lat_log=%s/clat/randrw\nper_job_logs=1\nlog_avg_msec=1000\n' "$out" "$out"; fi
    printf 'filename_format=%s/test_dir/rw_test.$jobnum.0\n%s\n' "$mnt" '[job]'
  } >"$out/fio.job"
}
run_warmup() {
  local cell=$1
  local mnt=$2
  local out=$ROOT/cells/$cell/warmup
  local rc
  write_fio_job "$out" "$mnt" randread "$WARMUP_RUNTIME" no
  log_cmd timeout 120 "$FIO" "$out/fio.job" --output="$out/fio.json" --output-format=json
  set +e
  timeout 120 "$FIO" "$out/fio.job" --output="$out/fio.json" --output-format=json
  rc=$?
  set -e
  printf '%s\n' "$rc" >"$out/fio.rc"
  (( rc == 0 )) || die warmup_failed
}
start_samplers() {
  local cell=$1
  local metrics=$2
  local dirs=$3
  local cell_root=$ROOT/cells/$cell
  local stop=$cell_root/sampler.stop
  : >"$stop"
  ACTIVE_SAMPLER_STOP=$stop
  (
    mkdir -m 0700 -p "$cell_root/mechanism"
    printf 'epoch_ns\tdir\tavail_bytes\ttotal_bytes\n' >"$cell_root/df-1hz.tsv"
    printf 'epoch_ns\tCached_kB\tDirty_kB\tWriteback_kB\trx_bytes\ttx_bytes\n' >"$cell_root/meminfo-1hz.tsv"
    while [[ ! -e $stop.done ]]; do
      epoch=$(date +%s%N)
      curl -fsS --max-time 5 "http://$metrics/metrics" >"$cell_root/mechanism/$epoch.prom" || exit 42
      if [[ -n $dirs ]]; then
        IFS=: read -r -a sample_paths <<<"$dirs"
        for sample_dir in "${sample_paths[@]}"; do
          read -r total avail < <(df -B1 --output=size,avail "$sample_dir" | awk 'NR==2{print $1,$2}')
          printf '%s\t%s\t%s\t%s\n' "$epoch" "$sample_dir" "$avail" "$total" >>"$cell_root/df-1hz.tsv"
        done
      fi
      read -r cached dirty writeback < <(awk '/^Cached:/{c=$2}/^Dirty:/{d=$2}/^Writeback:/{w=$2}END{print c+0,d+0,w+0}' /proc/meminfo)
      nic=$(ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
      [[ -n $nic ]] || exit 42
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$cached" "$dirty" "$writeback" "$(cat /sys/class/net/$nic/statistics/rx_bytes)" "$(cat /sys/class/net/$nic/statistics/tx_bytes)" >>"$cell_root/meminfo-1hz.tsv"
      sleep 0.8
    done
  ) >"$cell_root/sampler.stdout" 2>"$cell_root/sampler.stderr" &
  ACTIVE_SAMPLER_PID=$!
  if command -v iostat >/dev/null 2>&1; then
    iostat -dxk 1 >"$cell_root/iostat-1hz.tsv" 2>"$cell_root/iostat.stderr" &
    ACTIVE_IOSTAT_PID=$!
  fi
}
stop_samplers() {
  local rc=0
  [[ -n $ACTIVE_SAMPLER_STOP ]] && : >"$ACTIVE_SAMPLER_STOP.done"
  if [[ -n $ACTIVE_SAMPLER_PID ]]; then wait "$ACTIVE_SAMPLER_PID" || rc=$?; fi
  if [[ -n $ACTIVE_IOSTAT_PID ]]; then kill -TERM "$ACTIVE_IOSTAT_PID" 2>/dev/null || true; wait "$ACTIVE_IOSTAT_PID" 2>/dev/null || true; fi
  ACTIVE_SAMPLER_PID=
  ACTIVE_SAMPLER_STOP=
  ACTIVE_IOSTAT_PID=
  (( rc == 0 )) || die sampler_failed
}
run_formal() {
  local cell=$1
  local mnt=$2
  local out=$ROOT/cells/$cell/formal
  local rc
  write_fio_job "$out" "$mnt" randrw "$RUNTIME" yes
  log_cmd timeout 300 "$FIO" "$out/fio.job" --output="$out/fio.json" --output-format=json
  date +%s%N >"$out/fio-start-epoch-ns.txt"
  set +e
  timeout 300 "$FIO" "$out/fio.job" --output="$out/fio.json" --output-format=json
  rc=$?
  set -e
  date +%s%N >"$out/fio-end-epoch-ns.txt"
  printf '%s\n' "$rc" >"$out/fio.rc"
  FORMAL_RC=$rc
  (( rc == 0 )) || return 0
  [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) -eq 128 ]] || die bw_log_count
}
metric_sum() {
  local text=$1
  local name=$2
  awk -v n="$name" '$1 ~ ("^" n "($|\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' <<<"$text"
}
drain_writeback() {
  local cell=$1
  local metrics=$2
  local dirs=$3
  local out=$ROOT/cells/$cell/drain.tsv
  local start
  local now
  local zeros=0
  local text
  local blocks
  local bytes
  local writing
  local files
  local file_bytes
  start=$(date +%s)
  printf 'epoch_ns\tdir\tstaging_blocks\tstaging_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\n' >"$out"
  while :; do
    now=$(date +%s)
    text=$(curl -fsS --max-time 5 "http://$metrics/metrics") || die drain_metrics
    blocks=$(metric_sum "$text" juicefs_staging_blocks)
    bytes=$(metric_sum "$text" juicefs_staging_block_bytes)
    writing=$(metric_sum "$text" juicefs_staging_writing_blocks)
    [[ $blocks != NA && $bytes != NA && $writing != NA ]] || die staging_metrics_missing
    all_zero=1
    IFS=: read -r -a drain_paths <<<"$dirs"
    for dir in "${drain_paths[@]}"; do
      read -r files file_bytes < <(find "$dir" -ignore_readdir_race -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null | awk '{n++;s+=$1}END{print n+0,s+0}')
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$dir" "$blocks" "$bytes" "$writing" "$files" "$file_bytes" >>"$out"
      [[ $files == 0 && $file_bytes == 0 ]] || all_zero=0
    done
    [[ $blocks == 0 && $bytes == 0 && $writing == 0 && $all_zero == 1 ]] && zeros=$((zeros+1)) || zeros=0
    if (( zeros >= 2 )); then
      printf '%s\n' "$((now-start))" >"$ROOT/cells/$cell/drain-seconds.txt"
      printf '%s\n' "$(date +%s%N)" >"$ROOT/cells/$cell/strict-drain-end-ns.txt"
      return 0
    fi
    if (( now-start >= DRAIN_TIMEOUT )); then
      event DRAIN_TIMEOUT "$cell"
      printf 'DRAIN_TIMEOUT_PRESERVE_MOUNT\n' >"$ROOT/cells/$cell/STOP-PRESERVE-MOUNT"
      return 43
    fi
    sleep 1
  done
}
readback_verify() {
  local cell=$1
  local mnt=$2
  local out=$ROOT/cells/$cell/readback
  local rc
  mkdir -m 0700 -p "$out"
  log_cmd timeout 120 fio --name=readback --filename="$mnt/test_dir/rw_test.0.0:$mnt/test_dir/rw_test.31.0:$mnt/test_dir/rw_test.63.0:$mnt/test_dir/rw_test.127.0" --rw=read --bs=256K --size=4M --direct=1 --ioengine=libaio --iodepth=1 --numjobs=1 --group_reporting --output="$out/fio.json" --output-format=json
  set +e
  timeout 120 fio --name=readback --filename="$mnt/test_dir/rw_test.0.0:$mnt/test_dir/rw_test.31.0:$mnt/test_dir/rw_test.63.0:$mnt/test_dir/rw_test.127.0" --rw=read --bs=256K --size=4M --direct=1 --ioengine=libaio --iodepth=1 --numjobs=1 --group_reporting --output="$out/fio.json" --output-format=json
  rc=$?
  set -e
  printf 'rc\t%s\nremote_readable\t%s\ncontent_correctness\tNOT_PROVEN\n' "$rc" "$([[ $rc == 0 ]] && printf PASS || printf FAIL)" >"$ROOT/cells/$cell/readback-verify.tsv"
  (( rc == 0 )) || die readback_failed
}
run_cell() {
  local pos=$1
  local cell=$2
  local arm=$3
  local cache_mib=$4
  local writeback=$5
  local cell_root=$ROOT/cells/$cell
  local mnt=/tmp/jfs-06-1-$RUN_ID-$cell
  local verify_mnt=/tmp/jfs-06-1-$RUN_ID-$cell-verify
  local metrics=127.0.0.1:$((METRICS_BASE+pos))
  local dirs=
  [[ ! -e $cell_root ]] || die cell_already_exists
  mkdir -m 0700 -p "$cell_root"
  if [[ $arm == T ]]; then dirs=$(cache_dirs_for_cell "$cell"); create_cache_dirs "$cell" "$dirs"; fi
  printf 'cell\t%s\narm\t%s\ncache_mib\t%s\nwriteback\t%s\ncache_dirs\t%s\n' "$cell" "$arm" "$cache_mib" "$writeback" "${dirs:-NONE}" >"$cell_root/state.tsv"
  verify_assets "$REF" "$cell_root/assets-before.tsv"
  health_gate "$cell_root/health-before"
  mount_private "$cell" "$arm" formal "$mnt" "$metrics" "$dirs"
  verify_assets "$mnt" "$cell_root/assets-mounted.tsv"
  run_warmup "$cell" "$mnt"
  start_samplers "$cell" "$metrics" "$dirs"
  run_formal "$cell" "$mnt"
  stop_samplers
  if (( FORMAL_RC != 0 )); then event FIO_FAIL_PRESERVE_MOUNT "$cell:rc=$FORMAL_RC"; return "$FORMAL_RC"; fi
  if [[ $arm == T ]]; then drain_writeback "$cell" "$metrics" "$dirs" || return $?; else printf '0\n' >"$cell_root/drain-seconds.txt"; printf 'NOT_APPLICABLE_NO_WRITEBACK\n' >"$cell_root/drain.tsv"; fi
  graceful_umount "$cell" formal "$mnt"
  mount_private "$cell" C verify "$verify_mnt" "$metrics" ""
  readback_verify "$cell" "$verify_mnt"
  graceful_umount "$cell" verify "$verify_mnt"
  recovery_gate "$cell-post"
  verify_assets "$REF" "$cell_root/assets-after.tsv"
  cmp -s "$cell_root/assets-before.tsv" "$cell_root/assets-after.tsv" || die assets_changed
  health_gate "$cell_root/health-after"
  if [[ $arm == T ]]; then cleanup_cache_dirs "$cell" "$dirs"; fi
  printf 'CELL_RAW_PASS\n' >"$cell_root/PASS"
}
phase_a() {
  require_online_ack
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die juicefs_identity
  [[ -x $SCRUB && -x $ANALYZER && -x $GATE0 ]] || die script_dependency
  [[ ! -e $ROOT ]] || die result_root_exists
  mkdir -m 0700 -p "$ROOT/cells" "$ROOT/recovery" "$ROOT/gate0"
  printf 'epoch_ns\tkind\tdetail\n' >"$ROOT/incidents.tsv"
  : >"$ROOT/commands.sh"
  cp -- "$T061_CACHE_CONTRACT" "$ROOT/gate0/cache-path-contract.tsv"
  T061_CACHE_CONTRACT=$ROOT/gate0/cache-path-contract.tsv
  sha256sum "$0" "$ANALYZER" "$GATE0" "$SCRUB" >"$ROOT/gate0/scripts.sha256"
  verify_assets "$REF" "$ROOT/gate0/assets-start.tsv"
  recovery_gate phase-a-initial
  restore_scrub_on_exit() {
    local rc=$?
    if [[ -n $ACTIVE_SAMPLER_STOP ]]; then : >"$ACTIVE_SAMPLER_STOP.done"; fi
    if [[ -n $ACTIVE_SAMPLER_PID ]]; then wait "$ACTIVE_SAMPLER_PID" 2>/dev/null || true; fi
    if [[ -n $ACTIVE_IOSTAT_PID ]]; then kill -TERM "$ACTIVE_IOSTAT_PID" 2>/dev/null || true; wait "$ACTIVE_IOSTAT_PID" 2>/dev/null || true; fi
    if (( SCRUB_ACTIVE )); then
      if ! env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore-on-exit.txt" 2>&1; then
        printf '%s\t%s\t%s\n' "$(date +%s%N)" SCRUB_RESTORE_FAIL "$SCRUB_LEASE" >>"$ROOT/incidents.tsv"
        printf 'SCRUB_RESTORE_FAILED\n' >"$ROOT/STOP-SCRUB-RESTORE-FAILED"
      fi
    fi
    exit "$rc"
  }
  trap restore_scrub_on_exit EXIT
  SCRUB_LEASE=$RUN_ID-phase-a
  SCRUB_ACTIVE=1
  env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" pause "$SCRUB_LEASE" "${T061_CEPH_FSID:?}" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
  while IFS=$'\t' read -r pos cell arm cache_mib writeback; do run_cell "$pos" "$cell" "$arm" "$cache_mib" "$writeback"; done < <(matrix_rows)
  env U141D_SCRUB_STATE_DIR="$ROOT/scrub" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$SCRUB_LEASE" >"$ROOT/scrub-restore.txt"
  SCRUB_ACTIVE=0
  trap - EXIT
  verify_assets "$REF" "$ROOT/gate0/assets-end.tsv"
  cmp -s "$ROOT/gate0/assets-start.tsv" "$ROOT/gate0/assets-end.tsv" || die final_assets_changed
  printf 'PHASE_A_RAW_PASS\n' >"$ROOT/PHASE_A_PASS"
}

offline_self_test() {
  valid_run
  [[ $(matrix_rows | wc -l) -eq 4 ]] || die matrix_count
  [[ $(matrix_order) == C1,T1,T2,C2 ]] || die matrix_order
  [[ $(matrix_rows | awk -F '\t' '$3=="C"&&$4==0&&$5==0{n++}END{print n+0}') -eq 2 ]] || die control_contract
  [[ $(matrix_rows | awk -F '\t' '$3=="T"&&$4==98304&&$5==1{n++}END{print n+0}') -eq 2 ]] || die treatment_contract
  tmp=/tmp/t061-driver-selftest-$$
  [[ ! -e $tmp && $tmp != / ]] || die selftest_path
  mkdir -m 0700 "$tmp"
  trap 'find "$tmp" -depth -mindepth 1 -delete; rmdir "$tmp"' RETURN
  mkdir "$tmp/approved"
  read -r source major fstype target options < <(findmnt -bnr -T "$tmp/approved" -o SOURCE,MAJ:MIN,FSTYPE,TARGET,OPTIONS)
  device=${source%%[*}
  physical=$(lsblk -snro KNAME "$device" 2>/dev/null | tail -1 || true)
  uuid=$(lsblk -dnro UUID "$device" 2>/dev/null || true)
  read -r uid gid mode < <(stat -Lc '%u %g %a' "$tmp/approved")
  printf 'status\tpath\trealpath\tis_symlink\tis_writable\tsource\tmajor_minor\tphysical_leaf_devices\tfstype\tfilesystem_uuid\tmount_target\tmount_options\towner_uid\towner_gid\tmode\n' >"$tmp/contract.tsv"
  printf 'APPROVED\t%s\t%s\tno\tyes\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tmp/approved" "$(realpath -e "$tmp/approved")" "$source" "$major" "$physical" "$fstype" "$uuid" "$target" "$options" "$uid" "$gid" "$mode" >>"$tmp/contract.tsv"
  T061_CACHE_CONTRACT=$tmp/contract.tsv
  parent=$(approved_parents)
  [[ $parent == "$tmp/approved" ]] || die whitelist_fixture
  validate_parent "$parent"
  ln -s "$tmp/approved" "$tmp/link"
  if (validate_parent "$tmp/link" 2>/dev/null); then die symlink_fixture_accepted; fi
  write_plans "$tmp/plan"
  awk -F '\t' '$1=="30"{z=NR}$1=="40"{u=NR}$1=="50"{v=NR}END{exit !(z<u&&u<v)}' "$tmp/plan/gate0/lifecycle-order.tsv" || die lifecycle_order
  [[ $(sha256sum "$tmp/plan/gate0/warmup.fio" | awk '{print $1}') == $(awk '{print $1}' "$tmp/plan/gate0/warmup.sha256") ]] || die warmup_hash
  printf 'T061_DRIVER_SELF_TEST_PASS\tmatrix=C1,T1,T2,C2\twhitelist=PASS\tsymlink_reject=PASS\tlifecycle=drain-before-umount-before-cache0-verify\n'
}

case $MODE in
  --self-test) offline_self_test ;;
  plan) valid_run; write_plans "$PLAN_OUT"; printf 'T061_PLAN_ONLY_PASS\troot=%s\n' "$PLAN_OUT" ;;
  phase-a) phase_a ;;
  *) printf 'usage: %s --self-test|plan|phase-a RUN_ID\n' "$0" >&2; exit 2 ;;
esac
