#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}; RUN_ID=${2:-}; CELL=${3:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
ROOT=/tmp/production/opencode-04tmp3h-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REFERENCE_MNT=/mnt/juicefs; CACHE_PARENT=/mnt/jfs-cache
BACKING_ROOT=$CACHE_PARENT/jfs-04tmp3h-$RUN_ID
LOCAL_ROOT=$CACHE_PARENT/04tmp3h-local-$RUN_ID
ASSET_ROOT=$REFERENCE_MNT/test_dir/04tmp3h-$RUN_ID
CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
METRICS_ADDR=127.0.0.1:9568
EXPECTED_UID=1002; EXPECTED_GID=1002
# Normal runs use phase-a; an interrupted run may select a fresh, auditable
# helper-compatible lease without deleting earlier lease history.
LEASE=${T04TMP3H_LEASE:-$RUN_ID-phase-a}

die(){ printf 'E_04TMP3H\t%s\n' "$*" >&2; exit 42; }
valid_run(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == "/tmp/production/opencode-04tmp3h-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die unsafe_result_root
  [[ $BACKING_ROOT == "/mnt/jfs-cache/jfs-04tmp3h-$RUN_ID" && $BACKING_ROOT != / && $BACKING_ROOT != *..* ]] || die unsafe_backing_root
  [[ $ASSET_ROOT == "/mnt/juicefs/test_dir/04tmp3h-$RUN_ID" && $LOCAL_ROOT == "/mnt/jfs-cache/04tmp3h-local-$RUN_ID" ]] || die unsafe_asset_scope
  [[ ! -L $ROOT && ! -L $BACKING_ROOT && ! -L $ASSET_ROOT && ! -L $LOCAL_ROOT ]] || die symlink_root
}
cell_fields(){
  case $CELL in
    T32) BACKING_GIB=32; TIER_MIB=16384;;
    T64) BACKING_GIB=64; TIER_MIB=32768;;
    T96) BACKING_GIB=96; TIER_MIB=40960;;
    T128) BACKING_GIB=128; TIER_MIB=40960;;
    *) die invalid_cell;;
  esac
  BACKING_BYTES=$((BACKING_GIB * 1024 * 1024 * 1024))
  JFS_MNT=/tmp/jfs-04tmp3h-mnt-$RUN_ID-$CELL
  CELL_ROOT=$ROOT/cells/$CELL; STATE=$CELL_ROOT/state.tsv
  WB=1; BACKING=$BACKING_ROOT/$CELL.img
  CACHE_MNT=/tmp/jfs-04tmp3h-cache-$RUN_ID-$CELL; CACHE_DIR=$CACHE_MNT/cache
}
valid_paths(){
  cell_fields
  [[ $JFS_MNT == "/tmp/jfs-04tmp3h-mnt-$RUN_ID-$CELL" && $CELL_ROOT == "$ROOT/cells/$CELL" ]] || die unsafe_cell_path
  if (( WB )); then [[ $BACKING == "$BACKING_ROOT/$CELL.img" && $CACHE_DIR == "$CACHE_MNT/cache" ]] || die unsafe_cache_path; fi
  [[ ! -L $JFS_MNT && ! -L $CELL_ROOT && ( ! -n ${CACHE_MNT:-} || ! -L $CACHE_MNT ) ]] || die symlink_path
}
static_identity(){
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die JuiceFS_identity
  [[ -r $CEPH_CONF && ! -L $CEPH_CONF && $(md5sum "$CEPH_CONF"|awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die private_ceph_conf_identity
}
record(){ printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }
metric(){ awk -v n="$2" '$1 ~ ("^" n "($|\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' "$1"; }
metric_text(){ awk -v n="$2" '$1 ~ ("^" n "($|\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' <<<"$1"; }
metrics_required(){
  local f=$1 k; for k in juicefs_staging_blocks juicefs_staging_block_bytes juicefs_staging_writing_blocks juicefs_blockcache_bytes juicefs_blockcache_hit_bytes juicefs_blockcache_miss_bytes juicefs_blockcache_evicts juicefs_blockcache_drops; do [[ $(metric "$f" "$k") != NA ]] || die "metric_missing_$k"; done
}
read_asset_manifest(){
 local out base dir file
 out=$1; base=$2; dir="$base/test_dir/04tmp3h-$RUN_ID"
 printf 'name\tinode\tbytes\tblocks\thead_sha256\ttail_sha256\n' >"$out"
 for file in cp-read-20G.bin fio-read-10G.bin; do
  local p="$dir/$file"; [[ -f $p && ! -L $p ]] || die "read_asset_missing_$file"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$(stat -c %i "$p")" "$(stat -c %s "$p")" "$(stat -c %b "$p")" "$(head -c 1048576 "$p"|sha256sum|awk '{print $1}')" "$(tail -c 1048576 "$p"|sha256sum|awk '{print $1}')" >>"$out"
 done
 awk -F '\t' 'NR==2 && $3!=21474836480{bad=1} NR==3 && $3!=10737418240{bad=1} NR>1 && $4*512<$3*95/100{bad=1} END{exit bad}' "$out" || die read_asset_size_or_sparse
}

health(){
  local out=$1 mode=${2:-unpaused}; mountpoint -q "$REFERENCE_MNT" || die reference_mount_absent
  if [[ $mode == paused ]]; then
    env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" verify-paused "$LEASE" >"$out/scrub-lease.txt" || die scrub_lease_invalid
  elif [[ $mode != unpaused ]]; then die invalid_health_mode; fi
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  CEPH_CONF="$CEPH_CONF" ceph -s --format json >"$out/ceph-status.json" || die ceph_status
  python3 - "$out/ceph-status.json" "$mode" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
h=d.get('health',{}); status=h.get('status'); keys=set(h.get('checks',{}))
mode=sys.argv[2]
ok=(status=='HEALTH_OK' and not keys) if mode=='unpaused' else (
    status=='HEALTH_OK' and not keys or status=='HEALTH_WARN' and keys=={'OSDMAP_FLAGS'})
if not ok:
    raise SystemExit(f'unexpected Ceph health status={status} checks={sorted(keys)}')
s=d.get('pgmap',{}).get('pgs_by_state',[])
if not s or any(x.get('state_name')!='active+clean' for x in s): raise SystemExit('PGs not active+clean')
o=d.get('osdmap',{}).get('osdmap',d.get('osdmap',{}))
if any(o.get(k)!=6 for k in ('num_osds','num_up_osds','num_in_osds')): raise SystemExit('OSDs not exactly 6/6 up-in')
PY
  local ep host
  for ep in 10.20.1.150:20180 10.20.1.151:20180 10.20.1.152:20180; do
    host=${ep%:*}
    curl -fsS --connect-timeout 3 --max-time 5 "http://$ep/metrics" >"$out/tikv-$host.metrics" || die "tikv_metrics_$host"
  done
  local nic; nic=$(ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'); [[ -n $nic && -r /sys/class/net/$nic/statistics/rx_bytes ]] || die ceph_nic
  printf '%s\n' "$nic" >"$out/ceph-data-nic.txt"
}
resolve_backing_record(){
  local record=$1 value
  [[ -r $record ]] || return 1
  value=$(<"$record")
  [[ $value == /* && $value != / && $value != *..* ]] || return 1
  realpath -e "$value"
}
loop_backing(){
  local loop=$1
  local name=${loop##*/}
  [[ $loop =~ ^/dev/loop[0-9]+$ && -r /sys/block/$name/loop/backing_file ]] || return 1
  resolve_backing_record "/sys/block/$name/loop/backing_file"
}
verify_loop(){
  local loop=$1 expected actual matches
  expected=$(realpath -e "$BACKING") || die backing_realpath
  actual=$(loop_backing "$loop") || die loop_backing_unavailable
  [[ $actual == "$expected" ]] || die "loop_backing_mismatch_$actual"
  matches=$(sudo losetup -j "$BACKING" | awk -F: '{print $1}')
  [[ $matches == "$loop" ]] || die "loop_mapping_not_unique_$matches"
}
mount_pid_gate(){
  local tag=$1
  python3 - "$JFS" "$CELL_ROOT/pids-$tag.txt" <<'PY'
import os,sys
exe,pre=sys.argv[1:]; exe=os.path.realpath(exe); old={int(x) for x in open(pre) if x.strip().isdigit()}; rows=[]
for p in os.listdir('/proc'):
  if not p.isdigit() or int(p) in old: continue
  try:
    if os.path.realpath(f'/proc/{p}/exe')!=exe: continue
    cmd=open(f'/proc/{p}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace').strip(); st=open(f'/proc/{p}/stat').read().split(); rows.append((int(p),int(st[3]),int(st[21]),cmd))
  except (OSError,ValueError): pass
if len(rows)!=2: raise SystemExit(f'expected parent/worker pair: {rows}')
pids={x[0] for x in rows}; ws=[x for x in rows if x[1] in pids]
if len(ws)!=1: raise SystemExit('parent/worker mismatch')
print('pid\tppid\tstarttime\tselected_worker\tcmdline')
for x in sorted(rows): print(*x[:3],int(x[0]==ws[0][0]),x[3],sep='\t')
PY
}
jfs_gone(){
  local process_file=$1
  [[ ! -f $process_file ]] && return 0
  python3 - "$JFS" "$process_file" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
for r in csv.DictReader(open(sys.argv[2]),delimiter='\t'):
  try:
    if os.path.realpath('/proc/'+r['pid']+'/exe')==exe and open('/proc/'+r['pid']+'/stat').read().split()[21]==r['starttime']: raise SystemExit(1)
  except OSError: pass
PY
}
make_storage(){
  (( WB )) || return 0
  [[ ! -e $BACKING && ! -e $CACHE_MNT ]] || die storage_exists
  [[ ! -e $BACKING_ROOT ]] || die backing_root_exists
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS) == $(<"$ROOT/inventory/cache-parent.freeze") ]] || die cache_parent_identity_drift
  [[ $(df -B1 --output=avail "$CACHE_PARENT"|awk 'NR==2{print $1}') -ge $((BACKING_BYTES + 68719476736)) ]] || die backing_space
  record sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$BACKING_ROOT"
  sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$BACKING_ROOT"
  [[ -d $BACKING_ROOT && $(stat -Lc %u "$BACKING_ROOT") -eq $EXPECTED_UID && $(stat -Lc %g "$BACKING_ROOT") -eq $EXPECTED_GID && $(stat -Lc %a "$BACKING_ROOT") == 700 ]] || die backing_identity
  [[ -z $(find "$BACKING_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die backing_not_empty
  printf 'run_id\t%s\ncell\t%s\nbacking\t%s\ncache_mount\t%s\nstatus\tCREATING_BACKING\n' \
    "$RUN_ID" "$CELL" "$BACKING" "$CACHE_MNT" >"$STATE"
  local loop backing_dev backing_inode
  record fallocate -l "${BACKING_GIB}G" -- "$BACKING"
  fallocate -l "${BACKING_GIB}G" -- "$BACKING"
  [[ $(stat -Lc %s "$BACKING") -eq $BACKING_BYTES ]] || die backing_size
  backing_dev=$(stat -Lc %d "$BACKING"); backing_inode=$(stat -Lc %i "$BACKING")
  printf 'backing_dev\t%s\nbacking_inode\t%s\nstatus\tBACKING_CREATED\n' "$backing_dev" "$backing_inode" >>"$STATE"
  record sudo losetup --find --show --nooverlap "$BACKING"
  loop=$(sudo losetup --find --show --nooverlap "$BACKING")
  [[ $loop =~ ^/dev/loop[0-9]+$ ]] || die bad_loop
  printf 'loop\t%s\nstatus\tLOOP_ATTACHED\n' "$loop" >>"$STATE"
  verify_loop "$loop"
  record sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop"
  sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop" \
    >"$CELL_ROOT/mkfs.stdout" 2>"$CELL_ROOT/mkfs.stderr"
  mkdir -m 0700 "$CACHE_MNT"
  record sudo mount -o noatime,nodiscard "$loop" "$CACHE_MNT"
  sudo mount -o noatime,nodiscard "$loop" "$CACHE_MNT"
  record sudo chown "$EXPECTED_UID:$EXPECTED_GID" "$CACHE_MNT"
  sudo chown "$EXPECTED_UID:$EXPECTED_GID" "$CACHE_MNT"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die cache_mount_source
  findmnt -rn -M "$CACHE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,UUID >"$CELL_ROOT/cache-findmnt.tsv"
  df -B1 --output=size,avail "$CACHE_MNT" >"$CELL_ROOT/cache-df.tsv"
  df -i "$CACHE_MNT" >"$CELL_ROOT/cache-dfi.tsv"
  mkdir -m 0700 "$CACHE_DIR"
  printf 'status\tCACHE_MOUNTED\n' >>"$STATE"
}
mount_jfs(){
  local tag=$1
  if [[ $tag == formal ]]; then
    [[ ! -e $JFS_MNT ]] || die formal_mount_path_exists
    mkdir -m 0700 "$JFS_MNT"
  else
    [[ -d $JFS_MNT && ! -L $JFS_MNT ]] || die recovery_mount_path_missing
    ! mountpoint -q "$JFS_MNT" || die recovery_mount_path_already_mounted
    [[ $(stat -Lc %u "$JFS_MNT") -eq $EXPECTED_UID && $(stat -Lc %g "$JFS_MNT") -eq $EXPECTED_GID && $(stat -Lc %a "$JFS_MNT") == 700 ]] || die recovery_mount_path_identity
    [[ -z $(find "$JFS_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die recovery_mount_path_not_empty
  fi
  : >"$CELL_ROOT/pids-$tag.txt"; for p in /proc/[0-9]*; do [[ -e $p/exe && $(realpath "$p/exe" 2>/dev/null) == "$JFS" ]] && basename "$p" >>"$CELL_ROOT/pids-$tag.txt" || true; done
  local -a cmd=($JFS mount -d --max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300 --log "$CELL_ROOT/juicefs-$tag.log" --cache-dir "$CACHE_DIR" --cache-size "$TIER_MIB" --free-space-ratio 0.20 --writeback --metrics "$METRICS_ADDR" "$META" "$JFS_MNT")
  record env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"; CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$CELL_ROOT/mount-$tag.stdout" 2>"$CELL_ROOT/mount-$tag.stderr"; local i; for i in $(seq 1 120); do mountpoint -q "$JFS_MNT" && break; sleep 1; done; mountpoint -q "$JFS_MNT" || die mount_timeout
  findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/jfs-findmnt-$tag.tsv"; mount_pid_gate "$tag" >"$CELL_ROOT/mount-process-$tag.tsv" || die mount_identity
  local mount_log=$CELL_ROOT/juicefs-$tag.log command_line
  for i in $(seq 1 10); do
    grep -Fq "Disk cache ($CACHE_DIR/" "$mount_log" 2>/dev/null &&
      grep -Fq "Mounting volume juicefs-prod at \"$JFS_MNT\"" "$mount_log" 2>/dev/null && break
    sleep 1
  done
  grep -Fq "Disk cache ($CACHE_DIR/" "$mount_log" || die cache_log_identity
  grep -Fq "Mounting volume juicefs-prod at \"$JFS_MNT\"" "$mount_log" || die mount_log_identity
  ! grep -Fq 'writeback and prefetch will be disabled' "$mount_log" || die writeback_disabled
  command_line=$(tail -n 1 "$ROOT/commands.sh")
  [[ $command_line == *"--cache-size $TIER_MIB"* && $command_line == *'--writeback'* && $command_line == *"$CACHE_DIR"* ]] || die recorded_mount_contract
  local worker thread_count
  worker=$(awk -F '\t' '$4==1{print $1}' "$CELL_ROOT/mount-process-$tag.tsv")
  thread_count=$(grep -l '^msgr-worker' /proc/"$worker"/task/*/comm 2>/dev/null | wc -l || true)
  [[ $thread_count -eq 8 ]] || die "expected_8_msgr_workers_got_$thread_count"
  printf 'worker_pid\t%s\nmsgr_worker_threads\t%s\nceph_conf_md5\t%s\n' "$worker" "$thread_count" \
    "$(md5sum "$CEPH_CONF" | awk '{print $1}')" >"$CELL_ROOT/delivery-config-$tag.tsv"
  curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/metrics-mounted-$tag.txt"; (( WB == 0 )) || metrics_required "$CELL_ROOT/metrics-mounted-$tag.txt"
  grep -Fq "mp=\"$JFS_MNT\"" "$CELL_ROOT/metrics-mounted-$tag.txt" || die metrics_mount_identity
  grep -Fq 'vol_name="juicefs-prod"' "$CELL_ROOT/metrics-mounted-$tag.txt" || die metrics_volume_identity
}
unmount_jfs(){
  local tag=$1
  local process_file=$CELL_ROOT/mount-process-$tag.tsv i
  record "$JFS" umount "$JFS_MNT"
  "$JFS" umount "$JFS_MNT" >"$CELL_ROOT/umount-$tag.stdout" 2>"$CELL_ROOT/umount-$tag.stderr" || die umount_failed
  for i in $(seq 1 180); do ! mountpoint -q "$JFS_MNT" && break; sleep 1; done
  ! mountpoint -q "$JFS_MNT" || die mount_remains
  for i in $(seq 1 60); do jfs_gone "$process_file" && break; sleep 1; done
  jfs_gone "$process_file" || die process_remains
}
analyze_mount_log(){
  local tag=$1
  local output=$CELL_ROOT/juicefs-$tag.log
  [[ -f $output && ! -L $output ]] || die "juicefs_log_missing_$tag"
  grep -Eai 'link .* failed|stage@disk_cache\.go|uploadStagingFile.*(no such file|error|fail)|staging.*(no such file|error|fail)' "$output" |
    grep -Eavi 'no space left on device|stage@disk_cache.go:804' >"$CELL_ROOT/noncapacity-upload-errors-$tag.txt" || true
  printf 'metric\tcount\n' >"$CELL_ROOT/log-counts-$tag.tsv"
  printf 'direct_fallback\t%s\n' "$(grep -Fc 'upload it directly' "$output" || true)" >>"$CELL_ROOT/log-counts-$tag.tsv"
  printf 'real_enospc\t%s\n' "$(grep -Fic 'no space left on device' "$output" || true)" >>"$CELL_ROOT/log-counts-$tag.tsv"
  printf 'hardlink_error\t%s\n' "$(grep -Fc 'stage@disk_cache.go:804' "$output" || true)" >>"$CELL_ROOT/log-counts-$tag.tsv"
  printf 'noncapacity_upload_error\t%s\n' "$(wc -l <"$CELL_ROOT/noncapacity-upload-errors-$tag.txt")" >>"$CELL_ROOT/log-counts-$tag.tsv"
}
statvfs_available(){ python3 -c 'import os,sys; s=os.statvfs(sys.argv[1]); print(s.f_bavail*s.f_frsize)' "$1"; }
rawstaging_snapshot(){
  local output=$1
  printf 'size_bytes\tinode\tmtime_epoch\tpath\n' >"$output"
  find "$CACHE_DIR" -ignore_readdir_race -xdev -type f -path '*/rawstaging/*' \
    -printf '%s\t%i\t%T@\t%p\n' 2>/dev/null | sort >>"$output"
}
wait_recovery_drain(){
  local start now zeros=0 text blocks bytes writing files bytes_fs available
  start=$(date +%s)
  printf 'epoch_ns\tstaging_blocks\tstaging_block_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\tavailable_bytes\n' >"$CELL_ROOT/recovery-drain.tsv"
  while :; do
    now=$(date +%s); text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die recovery_metrics
    blocks=$(metric_text "$text" juicefs_staging_blocks); bytes=$(metric_text "$text" juicefs_staging_block_bytes); writing=$(metric_text "$text" juicefs_staging_writing_blocks)
    read -r files bytes_fs < <(find "$CACHE_DIR" -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null | awk '{n++;s+=$1}END{print n+0,s+0}')
    available=$(statvfs_available "$CACHE_MNT")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$blocks" "$bytes" "$writing" "$files" "$bytes_fs" "$available" >>"$CELL_ROOT/recovery-drain.tsv"
    [[ $blocks == 0 && $bytes == 0 && $writing == 0 && $files == 0 && $bytes_fs == 0 ]] && zeros=$((zeros+1)) || zeros=0
    (( zeros >= 2 )) && printf '%s\n' "$((now-start))" >"$CELL_ROOT/recovery-drain-seconds.txt" && return 0
    (( now-start < 900 )) || die recovery_drain_timeout
    sleep 10
  done
}
verify_recovery_mount(){
 wait_recovery_drain; local order kind path
 printf 'order\tkind\tbytes\treadback\n' >"$CELL_ROOT/recovery-write-assets.tsv"
 for order in FWD REV; do for kind in cp-write fio-write; do
  path="$JFS_MNT/test_dir/04tmp3h-$RUN_ID/$CELL-$order-$kind.bin"; [[ -e $path ]] || continue
  local expected=10737418240; [[ $kind == cp-write ]] && expected=21474836480
  [[ -f $path && ! -L $path && $(stat -c %s "$path") == "$expected" ]] || die "recovery_size_${order}_${kind}"
  dd if="$path" of=/dev/null bs=1M count=1 iflag=direct status=none || die "recovery_read_${order}_${kind}"
  printf '%s\t%s\t%s\tPASS\n' "$order" "$kind" "$expected" >>"$CELL_ROOT/recovery-write-assets.tsv"
  record unlink -- "$path"; unlink -- "$path"
 done; done
 analyze_mount_log recovery
}

fio_command(){
 local label rw runtime file out stop nic sampler rc sample_rc
 label=$1; rw=$2; runtime=$3; file=$4; out="$CELL_ROOT/$label"
 mkdir -m 0700 -p "$out/bw"
 local -a cmd=(fio --name="$label" --filename="$file" --size=10G --bs="$([[ $rw == read ]] && echo 20M || echo 16M)" --rw="$rw" --direct=1 --numjobs=1 --runtime="$runtime" --time_based --group_reporting --write_bw_log="$out/bw/$label" --log_avg_msec=1000 --output="$out/fio.json" --output-format=json+)
 stop="$out/sample.stop"; nic=$(<"$ROOT/inventory/ceph-data-nic.txt"); sample "$stop" "$out/runtime.tsv" "$nic" & sampler=$!
 printf '%s\n' "$(date +%s%N)" >"$out/start-ns.txt"; record "${cmd[@]}"; set +e; timeout "$((runtime+120))" "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; rc=$?; : >"$stop"; wait "$sampler"; sample_rc=$?; set -e
 unlink "$stop"; (( sample_rc==0 )) || die "runtime_sampler_failed_$label"
 printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/end-ns.txt"; (( rc==0 )) || die "fio_failed_$label"
 [[ $(find "$out/bw" -maxdepth 1 -type f -name '*_bw.*.log'|wc -l) -eq 1 ]] || die "fio_bwlog_$label"
}
cp_timed(){
 local label source target bytes out stop nic sampler rc sample_rc
 label=$1; source=$2; target=$3; bytes=$4; out="$CELL_ROOT/$label"
 mkdir -m 0700 -p "$out"
 [[ ! -e $target && ! -L $target ]] || die "cp_target_exists_$label"
 record /usr/bin/time -f %e -o "$out/time-real.txt" cp -- "$source" "$target"
 stop="$out/sample.stop"; nic=$(<"$ROOT/inventory/ceph-data-nic.txt"); sample "$stop" "$out/runtime.tsv" "$nic" & sampler=$!
 set +e; /usr/bin/time -f %e -o "$out/time-real.txt" cp -- "$source" "$target" >"$out/cp.stdout" 2>"$out/cp.stderr"; rc=$?; : >"$stop"; wait "$sampler"; sample_rc=$?; set -e
 unlink "$stop"; (( sample_rc==0 )) || die "runtime_sampler_failed_$label"
 printf '%s\n' "$rc" >"$out/cp.rc"; (( rc==0 )) || die "cp_failed_$label"; [[ $(stat -c %s "$target") == "$bytes" ]] || die "cp_size_$label"
}
metrics_snapshot(){ curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/$1.metrics" || die "metrics_$1"; }
warm_cp_read(){ record cp -- "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/cp-read-20G.bin" /dev/null; cp -- "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/cp-read-20G.bin" /dev/null; }
warm_fio_read(){ fio_command "$1-warm-fio-read" read 60 "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/fio-read-10G.bin"; }
run_order(){
 local order local_out cp_write fio_write
 order=$1; local_out="$LOCAL_ROOT/cp-read-$CELL-$order.bin"
 cp_write="$JFS_MNT/test_dir/04tmp3h-$RUN_ID/$CELL-$order-cp-write.bin"
 fio_write="$JFS_MNT/test_dir/04tmp3h-$RUN_ID/$CELL-$order-fio-write.bin"
 if [[ $order == FWD ]]; then
  warm_cp_read; metrics_snapshot "$order-cp-read-pre"; cp_timed "$order-cp-read" "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/cp-read-20G.bin" "$local_out" 21474836480; metrics_snapshot "$order-cp-read-post"; unlink "$local_out"
  warm_fio_read "$order"; metrics_snapshot "$order-fio-read-pre"; fio_command "$order-fio-read" read 60 "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/fio-read-10G.bin"; metrics_snapshot "$order-fio-read-post"
  cp_timed "$order-cp-write" "$LOCAL_ROOT/source-20G.bin" "$cp_write" 21474836480; drain "$CELL_ROOT/$order-cp-write-drain.tsv" || return $?
  fio_command "$order-fio-write" write 120 "$fio_write"; [[ $(stat -c %s "$fio_write") == 10737418240 ]] || die "$order-fio-write-size"; drain "$CELL_ROOT/$order-fio-write-drain.tsv" || return $?
 else
  fio_command "$order-fio-write" write 120 "$fio_write"; [[ $(stat -c %s "$fio_write") == 10737418240 ]] || die "$order-fio-write-size"; drain "$CELL_ROOT/$order-fio-write-drain.tsv" || return $?
  cp_timed "$order-cp-write" "$LOCAL_ROOT/source-20G.bin" "$cp_write" 21474836480; drain "$CELL_ROOT/$order-cp-write-drain.tsv" || return $?
  warm_fio_read "$order"; metrics_snapshot "$order-fio-read-pre"; fio_command "$order-fio-read" read 60 "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/fio-read-10G.bin"; metrics_snapshot "$order-fio-read-post"
  warm_cp_read; metrics_snapshot "$order-cp-read-pre"; cp_timed "$order-cp-read" "$JFS_MNT/test_dir/04tmp3h-$RUN_ID/cp-read-20G.bin" "$local_out" 21474836480; metrics_snapshot "$order-cp-read-post"; unlink "$local_out"
 fi
}

sample(){
  local stop=$1 out=$2 nic=$3 text key value base available
  base=$(findmnt -rn -T "$CACHE_PARENT" -o SOURCE | sed 's#^/dev/##')
  [[ $base != */* && -r /sys/class/block/$base/stat ]] || die cache_parent_block_stat
  printf 'epoch_ns\tstaging_blocks\tstaging_block_bytes\tstaging_writing_blocks\tcache_bytes\thit_bytes\tmiss_bytes\tevicts\tdrops\tavailable_bytes\trx_bytes\ttx_bytes\tbase_stat\n' >"$out"
  while [[ ! -e $stop ]]; do
    text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || return 42
    local -a values=()
    for key in juicefs_staging_blocks juicefs_staging_block_bytes juicefs_staging_writing_blocks juicefs_blockcache_bytes juicefs_blockcache_hit_bytes juicefs_blockcache_miss_bytes juicefs_blockcache_evicts juicefs_blockcache_drops; do
      value=$(metric_text "$text" "$key")
      if [[ $value == NA && $WB -eq 1 ]]; then return 42; fi
      values+=("$value")
    done
    available=$(statvfs_available "$CACHE_MNT")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" \
      "${values[@]}" "$available" "$(cat /sys/class/net/$nic/statistics/rx_bytes)" "$(cat /sys/class/net/$nic/statistics/tx_bytes)" \
      "$(tr -s ' ' <"/sys/class/block/$base/stat")" >>"$out"
    sleep 1
  done
}
drain(){
  local out=$1 start now=0 zeros=0 text blocks bytes writing files bytes_fs available
  start=$(date +%s)
  printf 'epoch_ns\tstaging_blocks\tstaging_block_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\tavailable_bytes\n' >"$out"
  while :; do
    now=$(date +%s); text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die staging_metrics
    blocks=$(metric_text "$text" juicefs_staging_blocks); bytes=$(metric_text "$text" juicefs_staging_block_bytes); writing=$(metric_text "$text" juicefs_staging_writing_blocks)
    [[ $blocks != NA && $bytes != NA && $writing != NA ]] || die staging_metric_missing
    read -r files bytes_fs < <(find "$CACHE_DIR" -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null|awk '{n++;s+=$1}END{print n+0,s+0}')
    available=$(statvfs_available "$CACHE_MNT")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$blocks" "$bytes" "$writing" "$files" "$bytes_fs" "$available" >>"$out"
    [[ $blocks == 0 && $writing == 0 && $files == 0 && $bytes_fs == 0 && $bytes == 0 ]] && zeros=$((zeros+1)) || zeros=0
    if (( zeros >= 2 )); then
      printf '%s\n' "$((now-start))" >"$out.seconds"
      printf 'STRICT_ZERO\n' >"$out.status"
      return 0
    fi
    if (( now-start >= 900 )); then printf 'TIMEOUT\n' >"$out.status"; return 3; fi
    sleep 10
  done
}
cleanup(){
  (( WB )) || return 0
  local loop backing_dev backing_inode
  loop=$(awk -F '\t' '$1=="loop"{v=$2}END{print v}' "$STATE")
  backing_dev=$(awk -F '\t' '$1=="backing_dev"{v=$2}END{print v}' "$STATE")
  backing_inode=$(awk -F '\t' '$1=="backing_inode"{v=$2}END{print v}' "$STATE")
  mountpoint -q "$JFS_MNT" && die mounted
  [[ $(stat -Lc %d "$BACKING") == "$backing_dev" && $(stat -Lc %i "$BACKING") == "$backing_inode" && $(stat -Lc %s "$BACKING") -eq $BACKING_BYTES ]] || die backing_identity_changed
  verify_loop "$loop"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die cleanup_mount_source
  record sudo umount "$CACHE_MNT"; sudo umount "$CACHE_MNT"
  ! mountpoint -q "$CACHE_MNT" || die cache_mount_remains
  verify_loop "$loop"
  record sudo losetup -d "$loop"; sudo losetup -d "$loop"
  [[ -z $(sudo losetup -j "$BACKING") ]] || die loop_remains
  [[ -z $(find "$CACHE_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die underlying_cache_mount_not_empty
  rmdir "$CACHE_MNT"
  record unlink -- "$BACKING"; unlink -- "$BACKING"
  [[ -z $(find "$BACKING_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die backing_root_not_empty
  record sudo rmdir "$BACKING_ROOT"; sudo rmdir "$BACKING_ROOT"
  printf 'status\tDESTROYED\n' >>"$STATE"
}
pool_objects(){ CEPH_CONF="$CEPH_CONF" ceph df detail --format json | python3 -c 'import json,sys; p=[x for x in json.load(sys.stdin).get("pools",[]) if x.get("name")=="juicefs-data"]; assert len(p)==1; print(p[0]["stats"]["objects"])'; }
tikv_pending(){ curl -fsS --connect-timeout 3 --max-time 5 "http://$1:20180/metrics" | awk '$1~/^tikv_engine_pending_compaction_bytes(\{|$)/{s+=$2;n=1}END{if(!n)exit 1;printf "%.0f",s}'; }
wait_pool(){
 local label=$1 target=$2 out round objects pending ok ep
 out="$ROOT/recovery/$label"; mkdir -m 0700 -p "$out"
 printf 'round\tobjects\tpending150\tpending151\tpending152\n' >"$out/poll.tsv"
 for round in $(seq 1 180); do objects=$(pool_objects); ok=1; local vals=(); for ep in 10.20.1.150 10.20.1.151 10.20.1.152; do pending=$(tikv_pending "$ep") || die "pending_$ep"; vals+=("$pending"); [[ $pending == 0 ]] || ok=0; done; (( objects <= target + 8192 )) || ok=0; printf '%s\t%s\t%s\t%s\t%s\n' "$round" "$objects" "${vals[@]}" >>"$out/poll.tsv"; (( ok )) && { printf 'RECOVERY_PASS\n' >"$out/PASS"; return; }; sleep 10; done
 die "recovery_timeout_$label"
}
recover_pool(){
 local label target out
 label=$1; target=$2; out="$ROOT/recovery/$label"; mkdir -m 0700 -p "$out"
 [[ ${T04TMP3H_GC_ACK:-} == "I_ACK_04TMP3H_SHARED_GC_$RUN_ID" ]] || die "required exact GC ACK: I_ACK_04TMP3H_SHARED_GC_$RUN_ID"
 record env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout 1800 "$JFS" gc --compact --delete --threads 32 "$META"
 JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$CEPH_CONF" timeout 1800 "$JFS" gc --compact --delete --threads 32 "$META" >"$out/gc.log" 2>&1 || die "gc_$label"
 wait_pool "$label" "$target"
}
prepare_one(){
 local path=$1 size=$2 label=$3 expected rc; case $size in 10G) expected=10737418240;; 20G) expected=21474836480;; *) die bad_prepare_size;; esac
 [[ ! -e $path && ! -L $path ]] || die "prepare_exists_$label"
 record timeout 600 fio --name="prepare-$label" --filename="$path" --rw=write --bs=16M --size="$size" --direct=1 --end_fsync=1 --output="$ROOT/prepare-$label.json" --output-format=json
 set +e; timeout 600 fio --name="prepare-$label" --filename="$path" --rw=write --bs=16M --size="$size" --direct=1 --end_fsync=1 --output="$ROOT/prepare-$label.json" --output-format=json; rc=$?; set -e
 (( rc==0 )) || die "prepare_failed_$label"; [[ -f $path && ! -L $path && $(stat -c %s "$path") == "$expected" ]] || die "prepare_size_$label"
}
cmd_inventory(){
 valid_run; [[ ! -e $ROOT && ! -e $BACKING_ROOT && ! -e $ASSET_ROOT && ! -e $LOCAL_ROOT ]] || die preexisting_task_scope
 mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans" "$ROOT/cells" "$ROOT/recovery"; printf '#!/usr/bin/env bash\n# 04-tmp3h actual commands\n' >"$ROOT/commands.sh"
 command -v fio >"$ROOT/inventory/fio-path.txt"; fio --version >"$ROOT/inventory/fio-version.txt"
 [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die JuiceFS_identity
 cp /etc/ceph/ceph.conf "$CEPH_CONF"; printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"; static_identity
 CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$ROOT/inventory/volume-status.json"
 python3 - "$ROOT/inventory/volume-status.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])).get('Setting') or {}
if s.get('Name')!='juicefs-prod' or str(s.get('BlockSize')) not in {'256','256K','262144'} or not s.get('UUID'): raise SystemExit('B256 volume identity')
PY
 CEPH_CONF="$CEPH_CONF" ceph fsid >"$ROOT/inventory/ceph-fsid.txt"; CEPH_CONF="$CEPH_CONF" ceph osd ls >"$ROOT/inventory/osd-ids.txt"
 mountpoint -q "$REFERENCE_MNT" || die reference_mount_absent; findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-mount.tsv"
 [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT && $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die cache_parent
 findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"; df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"
 [[ $(df -B1 --output=avail "$CACHE_PARENT"|awk 'NR==2{print $1}') -ge 206158430208 ]] || die cache_parent_below_192GiB
 health "$ROOT/inventory" unpaused; CEPH_CONF="$CEPH_CONF" ceph df detail --format json >"$ROOT/inventory/ceph-df-detail.json"
 if pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1; then die foreign_fio; fi; ss -lntp >"$ROOT/inventory/listeners.tsv" 2>&1 || :
 ! awk -v p=":${METRICS_ADDR##*:}" '$4 ~ p"$"{found=1} END{exit found?0:1}' "$ROOT/inventory/listeners.tsv" || die metrics_port_occupied
 printf 'INVENTORY_PASS\n' >"$ROOT/inventory/PASS"; printf '04TMP3H_INVENTORY_PASS root=%s\n' "$ROOT"
}
cmd_plan(){
 valid_run; [[ -f $ROOT/inventory/PASS ]] || die inventory_missing
 printf 'T32\nT64\nT96\nT128\n' >"$ROOT/plans/matrix-order.txt"; printf 'tier\tverdict\tepoch\n' >"$ROOT/run-state.tsv"
 cat >"$ROOT/plans/sudo-contract.txt" <<EOF
# Exact privileged surface; execute only after explicit approval.
sudo ceph osd set noscrub
sudo ceph osd set nodeep-scrub
# One RUN-scoped local source/output directory under the root-owned cache parent.
sudo install -d -m 0700 -o 1002 -g 1002 $LOCAL_ROOT
# Per tested tier: scoped directory, unique loop, ext4, mount, ownership, then exact reverse cleanup.
sudo install -d -m 0700 -o 1002 -g 1002 $BACKING_ROOT
sudo losetup --find --show --nooverlap $BACKING_ROOT/<TIER>.img
sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <verified-loop>
sudo mount -o noatime,nodiscard <verified-loop> /tmp/jfs-04tmp3h-cache-$RUN_ID-<TIER>
sudo chown 1002:1002 /tmp/jfs-04tmp3h-cache-$RUN_ID-<TIER>
sudo umount /tmp/jfs-04tmp3h-cache-$RUN_ID-<TIER>
sudo losetup -d <verified-loop>
sudo rmdir $BACKING_ROOT
sudo rmdir $LOCAL_ROOT
sudo ceph osd unset nodeep-scrub
sudo ceph osd unset noscrub
EOF
 printf 'T32 cache=16384MiB\nT64 cache=32768MiB\nT96 cache=40960MiB\nT128 cache=40960MiB\nFWD cp-read fio-read cp-write drain fio-write drain\nREV fio-write drain cp-write drain fio-read cp-read\n' >"$ROOT/plans/matrix.txt"
 cat >"$ROOT/plans/mutation-contract.txt" <<EOF
# Complete non-sudo/shared-volume mutation contract.
# Prepare only $ASSET_ROOT/{cp-read-20G.bin,fio-read-10G.bin} and $LOCAL_ROOT/source-20G.bin.
# Per tier create only $BACKING_ROOT/<TIER>.img, one verified loop/ext4 and RUN-scoped cache/mount paths.
# FWD/REV commands are frozen in matrix.txt and use only RUN-scoped files below $ASSET_ROOT.
# After each tested tier and once after final read-asset deletion, run this shared-volume GC (maximum five invocations):
JFS_GC_SKIPPEDTIME=0 CEPH_CONF=$CEPH_CONF timeout 1800 $JFS gc --compact --delete --threads 32 $META
# GC requires exact token: I_ACK_04TMP3H_SHARED_GC_$RUN_ID
# Cleanup unlinks only manifest-listed RUN assets and reverses the verified loop/backing state.
EOF
 sha256sum "$ROOT/plans/mutation-contract.txt" >"$ROOT/plans/mutation-contract.txt.sha256"
 sha256sum "$SCRIPT_DIR/t04tmp3h-cache-run.sh" "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" "$SCRIPT_DIR/t04tmp3h-cache-gate0-offline.sh" "$SCRIPT_DIR/u141d-scrub-control.sh" >"$ROOT/plans/scripts.sha256"
 printf 'PLAN_PASS\n' >"$ROOT/plans/PASS"; printf '04TMP3H_PLAN_PASS root=%s\n' "$ROOT"
}
cmd_prepare(){
 valid_run; [[ ${T04TMP3H_ACK:-} == I_ACK_04TMP3H_PREPARE_$RUN_ID ]] || die prepare_ack; [[ -f $ROOT/plans/PASS ]] || die plan_missing; static_identity
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 record sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$LOCAL_ROOT"
 sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$LOCAL_ROOT"
 [[ -d $LOCAL_ROOT && ! -L $LOCAL_ROOT && $(stat -Lc %u "$LOCAL_ROOT") -eq $EXPECTED_UID && $(stat -Lc %g "$LOCAL_ROOT") -eq $EXPECTED_GID && $(stat -Lc %a "$LOCAL_ROOT") == 700 ]] || die local_root_identity
 mkdir -m 0700 "$ASSET_ROOT"; printf '%s\n' "$(pool_objects)" >"$ROOT/inventory/O0.tsv"
 prepare_one "$LOCAL_ROOT/source-20G.bin" 20G local-source; prepare_one "$ASSET_ROOT/cp-read-20G.bin" 20G cp-read; prepare_one "$ASSET_ROOT/fio-read-10G.bin" 10G fio-read
 [[ $(($(stat -c %b "$LOCAL_ROOT/source-20G.bin")*512)) -ge 20401094656 ]] || die local_source_sparse
 read_asset_manifest "$ROOT/inventory/read-assets.tsv" "$REFERENCE_MNT"; sleep 60; printf '%s\n' "$(pool_objects)" >"$ROOT/inventory/O1.tsv"; printf 'PREPARE_PASS\n' >"$ROOT/PREPARE_PASS"
}
cmd_pause_scrub(){ valid_run; [[ ${T04TMP3H_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack; env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" pause "$LEASE" "$(<"$ROOT/inventory/ceph-fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE; }
cmd_verify_scrub(){ valid_run; env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" verify-paused "$LEASE"; }
cmd_restore_scrub(){ valid_run; env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$LEASE"; env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" verify-restored "$LEASE"; printf 'SCRUB_RESTORED\n' >"$ROOT/SCRUB_RESTORED"; }
restore_scrub_on_exit(){ local rc=$? restore_rc=0; trap - EXIT; set +e; cmd_restore_scrub || restore_rc=$?; (( restore_rc == 0 )) || rc=97; exit "$rc"; }
run_tier(){
 CELL=$1; valid_paths; [[ ! -e $CELL_ROOT && ! -e $BACKING_ROOT ]] || die tier_scope_exists; mkdir -m 0700 -p "$CELL_ROOT/health-pre" "$CELL_ROOT/health-post"
 health "$CELL_ROOT/health-pre" paused; make_storage; mount_jfs formal; read_asset_manifest "$CELL_ROOT/read-assets-pre.tsv" "$JFS_MNT"
 local order_rc=0 fwd=no enospc hardlink upload_error
 run_order FWD || order_rc=$?
 if (( order_rc == 3 )); then
  printf 'FWD\tDRAIN_TIMEOUT\n' >"$CELL_ROOT/CAPACITY_TIMEOUT.tsv"
 elif (( order_rc != 0 )); then
  die "unexpected_FWD_rc_$order_rc"
 else
  python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" order "$CELL_ROOT" FWD >"$CELL_ROOT/FWD-analysis.json"
  fwd=$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1]))["all_targets_pass"] else "no")' "$CELL_ROOT/FWD-analysis.json")
 fi
 if [[ $fwd == yes ]]; then
  order_rc=0; run_order REV || order_rc=$?
  if (( order_rc == 3 )); then printf 'REV\tDRAIN_TIMEOUT\n' >"$CELL_ROOT/CAPACITY_TIMEOUT.tsv"
  elif (( order_rc != 0 )); then die "unexpected_REV_rc_$order_rc"
  else python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" order "$CELL_ROOT" REV >"$CELL_ROOT/REV-analysis.json"
  fi
 fi
 analyze_mount_log formal
 enospc=$(awk -F '\t' '$1=="real_enospc"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
 hardlink=$(awk -F '\t' '$1=="hardlink_error"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
 upload_error=$(awk -F '\t' '$1=="noncapacity_upload_error"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
 (( hardlink == 0 && upload_error == 0 )) || die formal_cache_or_upload_error
 if (( enospc > 0 )); then printf 'FORMAL\tENOSPC\n' >"$CELL_ROOT/CAPACITY_TIMEOUT.tsv"; fi
 unmount_jfs formal; mount_jfs recovery; verify_recovery_mount; read_asset_manifest "$CELL_ROOT/read-assets-recovery.tsv" "$JFS_MNT"; cmp -s "$CELL_ROOT/read-assets-pre.tsv" "$CELL_ROOT/read-assets-recovery.tsv" || die read_asset_drift
 unmount_jfs recovery; [[ -z $(find "$JFS_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die jfs_mount_dir_not_empty; rmdir "$JFS_MNT"; cleanup
 recover_pool "after-$CELL" "$(<"$ROOT/inventory/O1.tsv")"; health "$CELL_ROOT/health-post" paused
 python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" tier "$CELL_ROOT" >"$CELL_ROOT/tier-analysis.json"
 local verdict; verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$CELL_ROOT/tier-analysis.json"); printf '%s\t%s\t%s\n' "$CELL" "$verdict" "$(date +%s)" >>"$ROOT/run-state.tsv"; printf 'TIER_PASS\t%s\n' "$verdict" >"$CELL_ROOT/PASS"
}
cmd_run_auto(){
 valid_run; [[ ${T04TMP3H_ACK:-} == I_ACK_04TMP3H_RUN_$RUN_ID ]] || die run_ack; [[ -f $ROOT/PREPARE_PASS ]] || die prepare_missing; sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift; sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift; static_identity; cmd_verify_scrub
 trap restore_scrub_on_exit EXIT
 local tier verdict; for tier in T32 T64 T96 T128; do
  if [[ -f $ROOT/cells/$tier/PASS ]]; then
   verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$ROOT/cells/$tier/tier-analysis.json")
  else
   run_tier "$tier"
   verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$ROOT/cells/$tier/tier-analysis.json")
  fi
  [[ $verdict != FOUR_COMMAND_CACHE_TARGET_CONFIRMED ]] || break
 done
 python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" run "$ROOT" >"$ROOT/final-analysis.json"; printf 'RUN_AUTO_PASS\n' >"$ROOT/RUN_AUTO_PASS"; cmd_restore_scrub; trap - EXIT
}
cmd_resume_completed_fwd(){
 valid_run; [[ ${T04TMP3H_ACK:-} == I_ACK_04TMP3H_RUN_$RUN_ID ]] || die run_ack
 [[ ${T04TMP3H_GC_ACK:-} == "I_ACK_04TMP3H_SHARED_GC_$RUN_ID" ]] || die gc_ack
 [[ -f $ROOT/PREPARE_PASS ]] || die prepare_missing
 sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 static_identity; cmd_verify_scrub; trap restore_scrub_on_exit EXIT
 CELL=${CELL:-}; valid_paths
 [[ -d $CELL_ROOT && ! -f $CELL_ROOT/PASS && ! -f $CELL_ROOT/REV-analysis.json ]] || die resume_state
 [[ $(findmnt -rn -M "$JFS_MNT" -o FSTYPE) == fuse.juicefs ]] || die resume_jfs_mount
 for item in FWD-cp-read/cp.rc FWD-fio-read/fio.rc FWD-cp-write/cp.rc FWD-fio-write/fio.rc FWD-cp-write-drain.tsv.status FWD-fio-write-drain.tsv.status; do
  [[ -s $CELL_ROOT/$item ]] || die "resume_evidence_missing_$item"
 done
 [[ $(<"$CELL_ROOT/FWD-cp-read/cp.rc") == 0 && $(<"$CELL_ROOT/FWD-fio-read/fio.rc") == 0 && $(<"$CELL_ROOT/FWD-cp-write/cp.rc") == 0 && $(<"$CELL_ROOT/FWD-fio-write/fio.rc") == 0 ]] || die resume_command_rc
 [[ $(<"$CELL_ROOT/FWD-cp-write-drain.tsv.status") == STRICT_ZERO && $(<"$CELL_ROOT/FWD-fio-write-drain.tsv.status") == STRICT_ZERO ]] || die resume_drain
 if [[ -e $CELL_ROOT/FWD-analysis.json ]]; then
  [[ ! -s $CELL_ROOT/FWD-analysis.json ]] || die resume_existing_analysis_nonempty
  mv "$CELL_ROOT/FWD-analysis.json" "$CELL_ROOT/FWD-analysis.pre-repair-empty.json"
 fi
 python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" order "$CELL_ROOT" FWD >"$CELL_ROOT/FWD-analysis.json"
 [[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["all_targets_pass"])' "$CELL_ROOT/FWD-analysis.json") == False ]] || die resume_fwd_requires_rev
 analyze_mount_log formal
 [[ $(awk -F '\t' '$1=="hardlink_error" || $1=="noncapacity_upload_error"{s+=$2} END{print s+0}' "$CELL_ROOT/log-counts-formal.tsv") == 0 ]] || die resume_cache_or_upload_error
 unmount_jfs formal; mount_jfs recovery; verify_recovery_mount
 read_asset_manifest "$CELL_ROOT/read-assets-recovery.tsv" "$JFS_MNT"
 cmp -s "$CELL_ROOT/read-assets-pre.tsv" "$CELL_ROOT/read-assets-recovery.tsv" || die read_asset_drift
 unmount_jfs recovery
 [[ -z $(find "$JFS_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die jfs_mount_dir_not_empty
 rmdir "$JFS_MNT"; cleanup
 recover_pool "after-$CELL" "$(<"$ROOT/inventory/O1.tsv")"
 health "$CELL_ROOT/health-post" paused
 python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" tier "$CELL_ROOT" >"$CELL_ROOT/tier-analysis.json"
 local verdict; verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$CELL_ROOT/tier-analysis.json")
 printf '%s\t%s\t%s\n' "$CELL" "$verdict" "$(date +%s)" >>"$ROOT/run-state.tsv"
 printf 'TIER_PASS\t%s\n' "$verdict" >"$CELL_ROOT/PASS"
 printf 'RESUME_COMPLETED_FWD_PASS\n' >"$CELL_ROOT/RESUME_PASS"
 trap - EXIT
 cmd_run_auto
}
cmd_resume_destroyed_tier(){
 valid_run; [[ ${T04TMP3H_ACK:-} == I_ACK_04TMP3H_RUN_$RUN_ID ]] || die run_ack
 [[ -f $ROOT/PREPARE_PASS ]] || die prepare_missing
 sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 static_identity; cmd_verify_scrub; trap restore_scrub_on_exit EXIT
 CELL=${CELL:-}; valid_paths
 [[ -d $CELL_ROOT && ! -f $CELL_ROOT/PASS && -s $CELL_ROOT/FWD-analysis.json ]] || die destroyed_resume_state
 [[ $(awk -F '\t' '$1=="status"{v=$2} END{print v}' "$STATE") == DESTROYED ]] || die destroyed_resume_storage_state
 ! mountpoint -q "$JFS_MNT" || die destroyed_resume_jfs_mounted
 [[ ! -e $BACKING && ! -e $CACHE_MNT ]] || die destroyed_resume_storage_present
 [[ -s $ROOT/recovery/after-$CELL/gc.log && ! -e $ROOT/recovery/after-$CELL/PASS ]] || die destroyed_resume_gc_state
 wait_pool "after-$CELL" "$(<"$ROOT/inventory/O1.tsv")"
 mkdir -m 0700 -p "$CELL_ROOT/health-post"; health "$CELL_ROOT/health-post" paused
 python3 "$SCRIPT_DIR/t04tmp3h-cache-analyze.py" tier "$CELL_ROOT" >"$CELL_ROOT/tier-analysis.json"
 local verdict; verdict=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$CELL_ROOT/tier-analysis.json")
 printf '%s\t%s\t%s\n' "$CELL" "$verdict" "$(date +%s)" >>"$ROOT/run-state.tsv"
 printf 'TIER_PASS\t%s\n' "$verdict" >"$CELL_ROOT/PASS"
 printf 'RESUME_DESTROYED_TIER_PASS\n' >"$CELL_ROOT/RESUME_DESTROYED_PASS"
 trap - EXIT
 cmd_run_auto
}
cmd_cleanup_plan(){
 valid_run; printf 'path\tclass\n%s\tJFS_READ_ASSETS\n%s\tLOCAL_SOURCE\n' "$ASSET_ROOT" "$LOCAL_ROOT" >"$ROOT/plans/cleanup-assets.tsv"; sha256sum "$ROOT/plans/cleanup-assets.tsv" >"$ROOT/plans/cleanup-assets.tsv.sha256"
}
cmd_cleanup_assets(){
 valid_run; [[ ${T04TMP3H_ACK:-} == I_ACK_04TMP3H_CLEANUP_$RUN_ID ]] || die cleanup_ack; [[ -f $ROOT/RUN_AUTO_PASS && -f $ROOT/SCRUB_RESTORED ]] || die run_or_scrub_not_closed; sha256sum -c "$ROOT/plans/cleanup-assets.tsv.sha256" >/dev/null || die cleanup_plan_drift
 sha256sum -c "$ROOT/plans/mutation-contract.txt.sha256" >/dev/null || die mutation_plan_drift
 [[ -d $ASSET_ROOT && ! -L $ASSET_ROOT ]] || die asset_root; for file in cp-read-20G.bin fio-read-10G.bin; do [[ -f $ASSET_ROOT/$file && ! -L $ASSET_ROOT/$file ]] || die cleanup_asset; record unlink -- "$ASSET_ROOT/$file"; unlink "$ASSET_ROOT/$file"; done; rmdir "$ASSET_ROOT"
 [[ -d $LOCAL_ROOT && ! -L $LOCAL_ROOT && -f $LOCAL_ROOT/source-20G.bin ]] || die local_root; record unlink -- "$LOCAL_ROOT/source-20G.bin"; unlink "$LOCAL_ROOT/source-20G.bin"
 [[ -z $(find "$LOCAL_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die local_root_not_empty
 record sudo rmdir "$LOCAL_ROOT"; sudo rmdir "$LOCAL_ROOT"
 recover_pool FINAL "$(<"$ROOT/inventory/O0.tsv")"; mkdir -m 0700 "$ROOT/closure-health"; health "$ROOT/closure-health" unpaused; printf 'CLEANUP_PASS\n' >"$ROOT/CLEANUP_PASS"
}
cmd_bundle(){
 valid_run; [[ -f $ROOT/CLEANUP_PASS ]] || die cleanup_required; local manifest="$ROOT/manifest.sha256" archive="/tmp/production/04tmp3h-$RUN_ID-evidence.tar"
 (cd "$ROOT" && find . -type f ! -name manifest.sha256 -print0|sort -z|xargs -0 sha256sum) >"$manifest"; tar -C /tmp/production -cf "$archive" "opencode-04tmp3h-$RUN_ID"; sha256sum "$archive" >"$archive.sha256"; printf 'BUNDLE_PASS\t%s\n' "$archive"
}
cmd_offline(){ valid_run; local candidate; for candidate in T32 T64 T96 T128; do CELL=$candidate; valid_paths; done; [[ $(grep -c '^    T' "$0") -ge 4 ]] || die tier_contract; ! grep -Eq 'mkfs\\.ext4[^\n]*-T[[:space:]]+largefile' "$0" || die largefile_forbidden; printf '04TMP3H_OFFLINE_SELF_TEST_PASS tiers=32,64,96,128\n'; }
cmd_inspect(){ valid_run; [[ -z $CELL ]] || { valid_paths; printf 'CELL=%s\nJFS_MNT=%s\nBACKING=%s\n' "$CELL" "$JFS_MNT" "$BACKING"; }; findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS | grep -F 04tmp3h || :; }
case $MODE in
 offline-self-test) cmd_offline;; inventory) cmd_inventory;; plan) cmd_plan;; prepare-assets) cmd_prepare;; pause-scrub) cmd_pause_scrub;; verify-scrub) cmd_verify_scrub;; run-auto) cmd_run_auto;; resume-completed-fwd) cmd_resume_completed_fwd;; resume-destroyed-tier) cmd_resume_destroyed_tier;; restore-scrub) cmd_restore_scrub;; cleanup-plan) cmd_cleanup_plan;; cleanup-assets) cmd_cleanup_assets;; bundle) cmd_bundle;; inspect) cmd_inspect;; *) printf 'usage: %s offline-self-test|inventory|plan|prepare-assets|pause-scrub|verify-scrub|run-auto|resume-completed-fwd|resume-destroyed-tier|restore-scrub|cleanup-plan|cleanup-assets|bundle|inspect RUN_ID [TIER]\n' "$0"; exit 2;; esac
