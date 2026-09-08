#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

MODE=${1:-}; RUN_ID=${2:-}; CELL=${3:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
ROOT=/tmp/production/opencode-04tmp2f-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REFERENCE_MNT=/mnt/juicefs; CACHE_PARENT=/mnt/jfs-cache
BACKING_ROOT=$CACHE_PARENT/jfs-04tmp2f-$RUN_ID
CEPH_CONF=$ROOT/inventory/ceph-msgr8.conf
CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730
METRICS_ADDR=127.0.0.1:9568
EXPECTED_UID=1002; EXPECTED_GID=1002
LEASE=$RUN_ID-phase-a

die(){ printf 'E_04TMP2F\t%s\n' "$*" >&2; exit 42; }
valid_run(){
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == "/tmp/production/opencode-04tmp2f-$RUN_ID" && $ROOT != / && $ROOT != *..* ]] || die unsafe_result_root
  [[ $BACKING_ROOT == "/mnt/jfs-cache/jfs-04tmp2f-$RUN_ID" && $BACKING_ROOT != / && $BACKING_ROOT != *..* ]] || die unsafe_backing_root
  [[ ! -L $ROOT && ! -L $BACKING_ROOT ]] || die symlink_root
}
cell_fields(){
  case $CELL in
    W20-randwrite) BACKING_GIB=20;;
    W32-randwrite) BACKING_GIB=32;;
    W64-randwrite) BACKING_GIB=64;;
    W96-randwrite) BACKING_GIB=96;;
    W128-randwrite) BACKING_GIB=128;;
    *) die invalid_cell;;
  esac
  BACKING_BYTES=$((BACKING_GIB * 1024 * 1024 * 1024))
  JOBS=128; FILE_BYTES=1073741824; JFS_MNT=/tmp/jfs-04tmp2f-mnt-$RUN_ID-$CELL
  CELL_ROOT=$ROOT/cells/$CELL; STATE=$CELL_ROOT/state.tsv
  WB=1; TIER_MIB=1; BACKING=$BACKING_ROOT/$CELL.img
  CACHE_MNT=/tmp/jfs-04tmp2f-cache-$RUN_ID-$CELL; CACHE_DIR=$CACHE_MNT/cache
}
valid_paths(){
  cell_fields
  [[ $JFS_MNT == "/tmp/jfs-04tmp2f-mnt-$RUN_ID-$CELL" && $CELL_ROOT == "$ROOT/cells/$CELL" ]] || die unsafe_cell_path
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
asset_manifest(){
  local out=$1 base=$2; find "$base/test_dir" -maxdepth 1 -type f -name 'storage_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$out"
  [[ $(wc -l <"$out") -eq 128 ]] || die asset_count; awk -F '\t' '$3!=1073741824{bad=1}END{exit bad}' "$out" || die asset_size
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
  [[ $(df -B1 --output=avail "$CACHE_PARENT"|awk 'NR==2{print $1}') -ge $((BACKING_BYTES + 8589934592)) ]] || die backing_space
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
  local -a cmd=($JFS mount -d --max-uploads 150 --max-fuse-io 256K --log "$CELL_ROOT/juicefs-$tag.log"); if (( WB )); then cmd+=(--cache-dir "$CACHE_DIR" --cache-size "$TIER_MIB" --free-space-ratio 0.20 --writeback); else cmd+=(--cache-size 0); fi; cmd+=(--metrics "$METRICS_ADDR" "$META" "$JFS_MNT")
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
  [[ $command_line == *'--cache-size 1'* && $command_line == *'--writeback'* && $command_line == *"$CACHE_DIR"* ]] || die recorded_mount_contract
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
    sleep 1
  done
}
verify_recovery_mount(){
  local text blocks bytes writing index
  wait_recovery_drain
  text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die recovery_metrics
  blocks=$(metric_text "$text" juicefs_staging_blocks)
  bytes=$(metric_text "$text" juicefs_staging_block_bytes)
  writing=$(metric_text "$text" juicefs_staging_writing_blocks)
  [[ $blocks == 0 && $bytes == 0 && $writing == 0 ]] || die "recovery_staging_not_zero_${blocks}_${bytes}_${writing}"
  printf 'file\tread_status\n' >"$CELL_ROOT/recovery-read-sample.tsv"
  for index in 0 63 127; do
    dd if="$JFS_MNT/test_dir/storage_test.$index.0" of=/dev/null bs=256K count=1 iflag=direct status=none || die "recovery_read_failed_$index"
    printf 'storage_test.%s.0\tPASS\n' "$index" >>"$CELL_ROOT/recovery-read-sample.tsv"
  done
  analyze_mount_log recovery
}
write_fio(){
  local out=$1 i; mkdir -m 0700 -p "$out/bw"; printf '[global]\nrw=randwrite\nbs=256k\nioengine=libaio\niodepth=128\ndirect=1\nfilesize=1G\nsize=1G\nopenfiles=128\ntime_based=1\nruntime=180\nrandseed=41001\nfallocate=none\nallow_file_create=0\ncreate_on_open=0\n' >"$out/randwrite.fio"; for i in $(seq 0 127); do printf '\n[storage_test_%03d]\nfilename=%s/test_dir/storage_test.%d.0\n' "$i" "$JFS_MNT" "$i" >>"$out/randwrite.fio"; done
  record timeout 300 fio "$out/randwrite.fio" --output-format=json --output="$out/fio.json" --write_bw_log="$out/bw/randwrite" --log_avg_msec=1000 --per_job_logs=1
  local rc
  if timeout 300 fio "$out/randwrite.fio" --output-format=json --output="$out/fio.json" --write_bw_log="$out/bw/randwrite" --log_avg_msec=1000 --per_job_logs=1; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" >"$out/fio.rc"
  (( rc == 0 )) || return "$rc"
  python3 - "$out/fio.json" "$out/bw" <<'PY'
import json, pathlib, re, sys
data=json.load(open(sys.argv[1])); jobs=data.get('jobs', [])
if len(jobs) != 128: raise SystemExit(f'expected 128 jobs, got {len(jobs)}')
if any(int(job.get('error', -1)) != 0 for job in jobs): raise SystemExit('fio job error')
logs=list(pathlib.Path(sys.argv[2]).glob('randwrite_bw.*.log'))
ids=[]
for path in logs:
    match=re.fullmatch(r'randwrite_bw\.(\d+)\.log', path.name)
    if match: ids.append(int(match.group(1)))
if sorted(ids) != list(range(1,129)): raise SystemExit('per-job bw logs incomplete')
PY
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
      printf '%s\n' "$((now-start))" >"$CELL_ROOT/drain-seconds.txt"
      printf 'STRICT_ZERO\n' >"$CELL_ROOT/drain-status.txt"
      return 0
    fi
    if (( now-start >= 900 )); then printf 'TIMEOUT\n' >"$CELL_ROOT/drain-status.txt"; return 3; fi
    sleep 1
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
matrix_guard(){
  local -a names verdicts
  [[ -f $ROOT/run-state.tsv ]] || die matrix_state_missing
  mapfile -t names < <(awk -F '\t' 'NR>1{print $1}' "$ROOT/run-state.tsv")
  mapfile -t verdicts < <(awk -F '\t' 'NR>1{print $2}' "$ROOT/run-state.tsv")
  [[ ${#names[@]} -eq ${#verdicts[@]} ]] || die matrix_state_malformed
  if (( ${#names[@]} > 0 )); then
    [[ -f $ROOT/recovery/after-${names[${#names[@]}-1]}/PASS ]] || die previous_cell_recovery_missing
  fi
  case ${#names[@]} in
    0) [[ $CELL == W20-randwrite ]] || die matrix_expected_W20;;
    1) [[ ${names[0]} == W20-randwrite && $CELL == W32-randwrite ]] || die matrix_expected_W32;;
    2) [[ ${names[0]} == W20-randwrite && ${names[1]} == W32-randwrite && $CELL == W64-randwrite ]] || die matrix_expected_W64;;
    3) [[ ${names[2]} == W64-randwrite && $CELL == W128-randwrite ]] || die matrix_expected_W128;;
    4) [[ ${names[3]} == W128-randwrite && ${verdicts[2]} == LIFECYCLE_FAIL && ${verdicts[3]} != LIFECYCLE_FAIL && $CELL == W96-randwrite ]] || die matrix_complete_or_W96_not_required;;
    *) die matrix_already_complete;;
  esac
  if (( ${#verdicts[@]} > 0 )); then
    [[ ${verdicts[${#verdicts[@]}-1]} != INVALID_AND_STOP ]] || die matrix_stopped_by_invalid_cell
  fi
}
cmd_inventory(){
  valid_run; [[ ! -e $ROOT ]] || die result_root_exists
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans"
  printf '#!/usr/bin/env bash\n' >"$ROOT/commands.sh"
  command -v fio >"$ROOT/inventory/fio-path.txt"; fio --version >"$ROOT/inventory/fio-version.txt"
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS"|awk '{print $1}') == "$JFS_MD5" ]] || die JuiceFS_identity
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"
  sha256sum "$JFS" >"$ROOT/inventory/juicefs.sha256"
  "$JFS" version >"$ROOT/inventory/juicefs-version.txt"
  "$JFS" mount --help >"$ROOT/inventory/mount-help.txt" 2>&1
  grep -q -- '--writeback' "$ROOT/inventory/mount-help.txt" || die writeback_unavailable
  cp /etc/ceph/ceph.conf "$CEPH_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  [[ $(md5sum "$CEPH_CONF" | awk '{print $1}') == "$CEPH_CONF_MD5" ]] || die private_ceph_conf_identity
  CEPH_CONF="$CEPH_CONF" "$JFS" status "$META" >"$ROOT/inventory/volume-status.json"
  python3 - "$ROOT/inventory/volume-status.json" >"$ROOT/inventory/volume-identity.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Setting',d)
name=s.get('Name'); uuid=s.get('UUID')
if name!='juicefs-prod' or not isinstance(uuid,str) or not uuid: raise SystemExit('volume identity mismatch')
print('name\tuuid'); print(f'{name}\t{uuid}')
PY
  CEPH_CONF="$CEPH_CONF" ceph fsid >"$ROOT/inventory/ceph-fsid.txt"
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die cache_parent_missing
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die cache_parent_not_ext4
  df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"; df -i "$CACHE_PARENT" >"$ROOT/inventory/cache-dfi.tsv"
  [[ ! -e $BACKING_ROOT ]] || die backing_root_exists
  asset_manifest "$ROOT/inventory/assets.tsv" "$REFERENCE_MNT"
  health "$ROOT/inventory"
  CEPH_CONF="$CEPH_CONF" ceph df detail --format json >"$ROOT/inventory/ceph-df-detail.json"
  CEPH_CONF="$CEPH_CONF" ceph osd ls --format json | python3 -c 'import json,sys; print("\n".join(map(str,json.load(sys.stdin))))' >"$ROOT/inventory/osd-ids.txt"
  python3 - "$ROOT/inventory/ceph-df-detail.json" >"$ROOT/inventory/pool-seed.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); rows=[p for p in d.get('pools',[]) if p.get('name')=='juicefs-data']
if len(rows)!=1: raise SystemExit('juicefs-data pool not unique')
s=rows[0].get('stats',{}); print('pool\tobjects\tstored'); print(f"juicefs-data\t{s['objects']}\t{s['stored']}")
PY
  if pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1; then die foreign_fio; fi
  ss -lntp >"$ROOT/inventory/listeners.tsv" 2>&1 || true
  ! awk -v p=":${METRICS_ADDR##*:}" '$4 ~ p"$"{found=1} END{exit found?0:1}' "$ROOT/inventory/listeners.tsv" || die metrics_port_occupied
  printf 'INVENTORY_PASS\n' >"$ROOT/inventory/PASS"
  printf '04TMP2F_INVENTORY_PASS root=%s\n' "$ROOT"
}
cmd_plan(){
  valid_run; [[ -f $ROOT/inventory/PASS ]] || die inventory_missing
  cat >"$ROOT/plans/sudo-contract.txt" <<EOF
# plan only; execute only after explicit approval
Once for this RUN, state-owned scrub lease (helper records original flags under the RUN root):
env U141D_SCRUB_STATE_DIR=$ROOT U141D_CEPH_CONF=$CEPH_CONF bash $SCRUB pause $LEASE $(cat "$ROOT/inventory/ceph-fsid.txt") I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
  underlying privileged writes: sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set noscrub
                                sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set nodeep-scrub

For each CELL in W20/W32/W64/W128-randwrite, plus conditional W96-randwrite, one at a time:
sudo install -d -m 0700 -o 1002 -g 1002 $BACKING_ROOT
fallocate -l <20G|32G|64G|96G|128G> -- $BACKING_ROOT/<CELL>.img
sudo losetup --find --show --nooverlap $BACKING_ROOT/<CELL>.img
sudo losetup -j $BACKING_ROOT/<CELL>.img  # read-only identity checks
sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <identity-verified-loop>
sudo mount -o noatime,nodiscard <same-loop> /tmp/jfs-04tmp2f-cache-$RUN_ID-<CELL>
sudo chown 1002:1002 /tmp/jfs-04tmp2f-cache-$RUN_ID-<CELL>
sudo umount /tmp/jfs-04tmp2f-cache-$RUN_ID-<CELL>
sudo losetup -d <same-loop>
sudo rmdir $BACKING_ROOT

After every CELL, for each inventory-frozen OSD ID:
EOF
  local osd
  while read -r osd; do
    [[ $osd =~ ^[0-9]+$ ]] || die bad_osd_id
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s perf dump  # read-only cooldown polling\n' "$CEPH_CONF" "$osd" >>"$ROOT/plans/sudo-contract.txt"
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s compact\n' "$CEPH_CONF" "$osd" >>"$ROOT/plans/sudo-contract.txt"
  done <"$ROOT/inventory/osd-ids.txt"
  cat >>"$ROOT/plans/sudo-contract.txt" <<EOF

After each CELL completes, run its recovery/cooldown helper before starting the next CELL:
TMP2F_RECOVERY_ACK=I_ACK_04TMP2F_RECOVERY_$RUN_ID bash $SCRIPT_DIR/t04tmp2f-writeback-recovery.sh run $RUN_ID after-<CELL>
  The helper writes $ROOT/recovery/after-<CELL>/PASS; matrix_guard rejects the next CELL without it.

At closure, restore only the two state-owned flags:
env U141D_SCRUB_STATE_DIR=$ROOT U141D_CEPH_CONF=$CEPH_CONF bash $SCRUB restore $LEASE
  underlying privileged writes: sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset nodeep-scrub
                                sudo ceph -c $CEPH_CONF --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset noscrub
EOF
  printf 'W20-randwrite\nW32-randwrite\nW64-randwrite\nW96-randwrite\nW128-randwrite\n' >"$ROOT/plans/matrix-order.txt"
  printf 'cell\tverdict\tepoch\n' >"$ROOT/run-state.tsv"
  sha256sum "$SCRIPT_DIR/t04tmp2f-writeback-run.sh" "$SCRIPT_DIR/t04tmp2f-writeback-analyze.py" \
    "$SCRIPT_DIR/t04tmp2f-writeback-recovery.sh" \
    "$SCRIPT_DIR/t04tmp2f-writeback-gate0-offline.sh" \
    "$SCRIPT_DIR/u141d-scrub-control.sh" >"$ROOT/plans/scripts.sha256"
  printf 'PLAN_PASS\n' >"$ROOT/plans/PASS"; printf '04TMP2F_PLAN_PASS root=%s\n' "$ROOT"; }
cmd_pause_scrub(){
  valid_run; [[ -f $ROOT/plans/PASS && -r $ROOT/inventory/ceph-fsid.txt ]] || die plan_missing
  [[ ${TMP2F_SCRUB_ACK:-} == I_ACK_GLOBAL_CEPH_SCRUB_PAUSE ]] || die scrub_ack_missing
  env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" pause "$LEASE" "$(<"$ROOT/inventory/ceph-fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
}
cmd_verify_scrub(){
  valid_run
  env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" verify-paused "$LEASE"
}
cmd_restore_scrub(){
  valid_run; mkdir -m 0700 -p "$ROOT/scrub-restored"
  env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" restore "$LEASE" >"$ROOT/scrub-restored/restore.txt"
  env U141D_SCRUB_STATE_DIR="$ROOT" U141D_CEPH_CONF="$CEPH_CONF" bash "$SCRUB" verify-restored "$LEASE" >"$ROOT/scrub-restored/verify.txt"
  printf 'SCRUB_RESTORED\n' >"$ROOT/scrub-restored/PASS"
  printf '04TMP2F_SCRUB_RESTORE_PASS run=%s\n' "$RUN_ID"
}
cmd_run(){
  valid_run; valid_paths
  [[ ${TMP2F_ACK:-} == I_ACK_04TMP2F_$RUN_ID ]] || die ack_missing
  [[ -f $ROOT/plans/PASS ]] || die plan_missing
  sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift
  static_identity
  matrix_guard
  [[ ! -e $CELL_ROOT ]] || die evidence_exists
  mkdir -m 0700 -p "$CELL_ROOT/health-pre" "$CELL_ROOT/health-post" "$CELL_ROOT/health-final"
  if pgrep -a -x fio >"$CELL_ROOT/foreign-fio.tsv" 2>&1; then die foreign_fio; fi
  health "$CELL_ROOT/health-pre" paused; make_storage
  asset_manifest "$CELL_ROOT/assets-pre.tsv" "$REFERENCE_MNT"
  mount_jfs formal
  local nic stop sampler_pid fio_rc sampler_rc drain_rc verdict enospc hardlink upload_error
  printf '%s\n' "$(statvfs_available "$CACHE_MNT")" >"$CELL_ROOT/actual-available-bytes.txt"
  nic=$(<"$CELL_ROOT/health-pre/ceph-data-nic.txt"); stop=$CELL_ROOT/sampler.stop
  sample "$stop" "$CELL_ROOT/runtime.tsv" "$nic" >"$CELL_ROOT/sampler.stdout" 2>"$CELL_ROOT/sampler.stderr" & sampler_pid=$!
  sleep 10
  if write_fio "$CELL_ROOT"; then fio_rc=0; else fio_rc=$?; fi
  printf '%s\n' "$(date +%s%N)" >"$CELL_ROOT/fio-end-epoch-ns.txt"
  : >"$stop"
  if wait "$sampler_pid"; then sampler_rc=0; else sampler_rc=$?; fi
  printf '%s\n' "$sampler_rc" >"$CELL_ROOT/sampler.rc"
  (( fio_rc == 0 )) || die fio_failed
  (( sampler_rc == 0 )) || die sampler_failed
  if (( WB )) && grep -Eq $'\tNA(\t|$)' "$CELL_ROOT/runtime.tsv"; then die sampler_NA; fi
  if drain "$CELL_ROOT/drain.tsv"; then drain_rc=0; else drain_rc=$?; fi
  (( drain_rc == 0 || drain_rc == 3 )) || die drain_failed
  rawstaging_snapshot "$CELL_ROOT/rawstaging-at-drain-end.tsv"
  analyze_mount_log formal
  asset_manifest "$CELL_ROOT/assets-post-formal.tsv" "$JFS_MNT"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post-formal.tsv" || die asset_identity_drift
  health "$CELL_ROOT/health-post" paused
  unmount_jfs formal
  if (( drain_rc == 3 )); then
    rawstaging_snapshot "$CELL_ROOT/rawstaging-after-formal-umount.tsv"
  fi
  mount_jfs recovery
  verify_recovery_mount
  asset_manifest "$CELL_ROOT/assets-post-recovery.tsv" "$JFS_MNT"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post-recovery.tsv" || die recovery_asset_identity_drift
  unmount_jfs recovery
  [[ -z $(find "$JFS_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die underlying_jfs_mount_not_empty
  rmdir "$JFS_MNT"
  cleanup
  health "$CELL_ROOT/health-final" paused
  enospc=$(awk -F '\t' '$1=="real_enospc"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
  hardlink=$(awk -F '\t' '$1=="hardlink_error"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
  upload_error=$(awk -F '\t' '$1=="noncapacity_upload_error"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
  if (( upload_error > 0 )); then verdict=INVALID_AND_STOP
  elif (( drain_rc == 3 )); then verdict=LIFECYCLE_FAIL
  elif (( enospc > 0 || hardlink > 0 )); then verdict=LIFECYCLE_PASS_TIGHT
  else verdict=OBSERVED_SAFE_POINT; fi
  printf 'verdict\t%s\ndrain_rc\t%s\nreal_enospc\t%s\nhardlink_error\t%s\nnoncapacity_upload_error\t%s\n' \
    "$verdict" "$drain_rc" "$enospc" "$hardlink" "$upload_error" >"$CELL_ROOT/verdict.tsv"
  printf 'CELL_COMPLETE\t%s\t%s\n' "$CELL" "$verdict" >"$CELL_ROOT/PASS"
  printf '%s\t%s\t%s\n' "$CELL" "$verdict" "$(date +%s)" >>"$ROOT/run-state.tsv"
  printf '04TMP2F_CELL_COMPLETE cell=%s verdict=%s\n' "$CELL" "$verdict"
  printf 'NEXT_REQUIRED_RECOVERY: TMP2F_RECOVERY_ACK=I_ACK_04TMP2F_RECOVERY_%s bash %q run %q %q\n' \
    "$RUN_ID" "$SCRIPT_DIR/t04tmp2f-writeback-recovery.sh" "$RUN_ID" "after-$CELL"
  [[ $verdict != INVALID_AND_STOP ]] || die noncapacity_upload_error
}
cmd_resume_postfio(){
  valid_run; valid_paths
  [[ ${TMP2F_ACK:-} == I_ACK_04TMP2F_$RUN_ID ]] || die ack_missing
  [[ -f $ROOT/plans/PASS ]] || die plan_missing
  sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift
  static_identity
  matrix_guard
  [[ -d $CELL_ROOT && ! -e $CELL_ROOT/PASS ]] || die resume_evidence_state
  [[ $(<"$CELL_ROOT/fio.rc") == 0 && $(<"$CELL_ROOT/sampler.rc") == 0 ]] || die resume_runtime_rc
  if pgrep -a -x fio >"$CELL_ROOT/foreign-fio-resume.tsv" 2>&1; then die foreign_fio; fi
  python3 - "$CELL_ROOT/fio.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); jobs=d.get('jobs',[])
assert len(jobs)==128 and all(int(j.get('error',-1))==0 for j in jobs)
r=max(int(j.get('write',{}).get('runtime',0)) for j in jobs)
assert 175000 <= r <= 190000
PY
  [[ $(awk -F '\t' '$1=="status"{v=$2}END{print v}' "$STATE") == CACHE_MOUNTED ]] || die resume_storage_state
  local loop text blocks bytes writing drain_status drain_rc
  loop=$(awk -F '\t' '$1=="loop"{v=$2}END{print v}' "$STATE")
  verify_loop "$loop"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die resume_cache_mount_source
  mountpoint -q "$JFS_MNT" || die resume_jfs_mount_absent
  [[ -s $CELL_ROOT/mount-process-formal.tsv ]] || die resume_process_evidence
  jfs_gone "$CELL_ROOT/mount-process-formal.tsv" && die resume_process_absent
  drain_status=$(<"$CELL_ROOT/drain-status.txt")
  case $drain_status in
  STRICT_ZERO)
    text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die resume_metrics
    blocks=$(metric_text "$text" juicefs_staging_blocks); bytes=$(metric_text "$text" juicefs_staging_block_bytes); writing=$(metric_text "$text" juicefs_staging_writing_blocks)
    [[ $blocks == 0 && $bytes == 0 && $writing == 0 ]] || die "resume_staging_not_zero_${blocks}_${bytes}_${writing}"
    python3 - "$CELL_ROOT/drain.tsv" "$CELL_ROOT/drain-seconds.txt" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t')); assert len(rows)>=2
for row in rows[-2:]:
    assert all(float(row[k])==0 for k in ('staging_blocks','staging_block_bytes','staging_writing_blocks','staging_files','staging_file_bytes'))
seconds=int(open(sys.argv[2]).read()); assert 0 <= seconds <= 900
PY
    drain_rc=0
    rawstaging_snapshot "$CELL_ROOT/rawstaging-at-drain-end.tsv"
    ;;
  TIMEOUT)
    [[ ! -e $CELL_ROOT/drain-seconds.txt && -s $CELL_ROOT/rawstaging-at-drain-end.tsv ]] || die timeout_evidence_missing
    python3 - "$CELL_ROOT/drain.tsv" "$CELL_ROOT/rawstaging-at-drain-end.tsv" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t'))
snapshot=list(csv.DictReader(open(sys.argv[2]),delimiter='\t'))
assert len(rows)>=2 and snapshot
span=(int(rows[-1]['epoch_ns'])-int(rows[0]['epoch_ns']))/1e9
assert span>=895
PY
    drain_rc=3
    ;;
  *) die invalid_resume_drain_status;;
  esac
  analyze_mount_log formal
  asset_manifest "$CELL_ROOT/assets-post-formal.tsv" "$JFS_MNT"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post-formal.tsv" || die asset_identity_drift
  health "$CELL_ROOT/health-post" paused
  unmount_jfs formal
  if (( drain_rc == 3 )); then
    rawstaging_snapshot "$CELL_ROOT/rawstaging-after-formal-umount.tsv"
  fi
  mount_jfs recovery
  verify_recovery_mount
  asset_manifest "$CELL_ROOT/assets-post-recovery.tsv" "$JFS_MNT"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post-recovery.tsv" || die recovery_asset_identity_drift
  unmount_jfs recovery
  [[ -z $(find "$JFS_MNT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die underlying_jfs_mount_not_empty
  rmdir "$JFS_MNT"
  cleanup
  health "$CELL_ROOT/health-final" paused
  local verdict enospc hardlink upload_error
  enospc=$(awk -F '\t' '$1=="real_enospc"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
  hardlink=$(awk -F '\t' '$1=="hardlink_error"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
  upload_error=$(awk -F '\t' '$1=="noncapacity_upload_error"{print $2}' "$CELL_ROOT/log-counts-formal.tsv")
  if (( upload_error > 0 )); then verdict=INVALID_AND_STOP
  elif (( drain_rc == 3 )); then verdict=LIFECYCLE_FAIL
  elif (( enospc > 0 || hardlink > 0 )); then verdict=LIFECYCLE_PASS_TIGHT
  else verdict=OBSERVED_SAFE_POINT; fi
  printf 'verdict\t%s\ndrain_rc\t%s\nreal_enospc\t%s\nhardlink_error\t%s\nnoncapacity_upload_error\t%s\n' \
    "$verdict" "$drain_rc" "$enospc" "$hardlink" "$upload_error" >"$CELL_ROOT/verdict.tsv"
  printf 'CELL_COMPLETE\t%s\t%s\n' "$CELL" "$verdict" >"$CELL_ROOT/PASS"
  printf '%s\t%s\t%s\n' "$CELL" "$verdict" "$(date +%s)" >>"$ROOT/run-state.tsv"
  printf '04TMP2F_RESUME_POSTFIO_COMPLETE cell=%s verdict=%s\n' "$CELL" "$verdict"
  printf 'NEXT_REQUIRED_RECOVERY: TMP2F_RECOVERY_ACK=I_ACK_04TMP2F_RECOVERY_%s bash %q run %q %q\n' \
    "$RUN_ID" "$SCRIPT_DIR/t04tmp2f-writeback-recovery.sh" "$RUN_ID" "after-$CELL"
  [[ $verdict != INVALID_AND_STOP ]] || die noncapacity_upload_error
}
cmd_offline(){
  valid_run
  local candidate
  for candidate in W20-randwrite W32-randwrite W64-randwrite W96-randwrite W128-randwrite; do
    CELL=$candidate; valid_paths
  done
  ! grep -Eq 'mkfs\.ext4[^\n]*-T[[:space:]]+largefile' "$0" || die largefile_forbidden
  grep -q -- '--writeback' "$0"
  printf '04TMP2F_OFFLINE_SELF_TEST_PASS cells=5 workset_gib=128 direct_backing_gib=20,32,64,96,128\n'
}
cmd_inspect(){ valid_run; valid_paths; printf 'CELL=%s\nJFS_MNT=%s\nBACKING=%s\n' "$CELL" "$JFS_MNT" "${BACKING:-NONE}"; [[ ! -f $STATE ]] || sed -n '1,80p' "$STATE"; findmnt -rn -M "$JFS_MNT" 2>/dev/null || true; }
case $MODE in offline-self-test) cmd_offline;; inventory) cmd_inventory;; plan) cmd_plan;; pause-scrub) cmd_pause_scrub;; verify-scrub) cmd_verify_scrub;; restore-scrub) cmd_restore_scrub;; run-cell) cmd_run;; resume-postfio) cmd_resume_postfio;; inspect-cell) cmd_inspect;; *) usage 2>/dev/null || true; exit 2;; esac
