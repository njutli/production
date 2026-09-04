#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# Minimal single-cell executor for 04-tmp2b.  One invocation owns exactly one
# whitelist backing/loop/ext4/cache mount and cleans it only after a valid run.
MODE=${1:-}
RUN_ID=${2:-}
CELL=${3:-}
ROOT=/tmp/production/opencode-04tmp2b-$RUN_ID
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
REFERENCE_MNT=/mnt/juicefs
CACHE_PARENT=/mnt/jfs-cache
BACKING_ROOT=$CACHE_PARENT/jfs-04tmp2b-$RUN_ID
CEPH_CONF=/etc/ceph/ceph.conf
METRICS_ADDR=127.0.0.1:9568
CEPH_FSID=f8137e5a-8af2-11f1-aa1c-4df480fc234d
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRUB_CONTROL="$SELF_DIR/u141d-scrub-control.sh"
EXPECTED_UID=1002
EXPECTED_GID=1002
FIXED_RUN=20260903-000000

die() { printf 'E_04TMP2B\t%s\n' "$*" >&2; exit 42; }
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

usage() {
  printf 'usage: %s offline-self-test|inventory|plan|run-cell|recover-cell|inspect-cell RUN_ID [CELL]\n' "${0##*/}"
}

validate_run() {
  [[ $RUN_ID == "$FIXED_RUN" ]] || die "RUN_ID must equal conditionally approved $FIXED_RUN"
  [[ $ROOT == "/tmp/production/opencode-04tmp2b-$RUN_ID" && $ROOT != / && $ROOT != *'..'* ]] \
    || die "unsafe result root: $ROOT"
  [[ ! -L $ROOT ]] || die "result root is symlink"
}

cell_fields() {
  local item tier nominal_gib tier_mib
  [[ $CELL =~ ^(mseqread|randread|randwrite|randrw)-c(16|64|32)$ ]] || die "invalid cell: $CELL"
  item=${BASH_REMATCH[1]}; tier=${BASH_REMATCH[2]}
  case $tier in
    16) nominal_gib=20; tier_mib=16384 ;;
    32) nominal_gib=40; tier_mib=32768 ;;
    64) nominal_gib=80; tier_mib=65536 ;;
    *) die "invalid tier" ;;
  esac
  ITEM=$item
  TIER=$tier
  TIER_MIB=$tier_mib
  BYTES=$((nominal_gib * 1024 * 1024 * 1024))
  BACKING="$BACKING_ROOT/$CELL.img"
  CACHE_MNT="/tmp/jfs-04tmp2b-cache-$RUN_ID-$CELL"
  JFS_MNT="/tmp/jfs-04tmp2b-mnt-$RUN_ID-$CELL"
  CELL_ROOT="$ROOT/cells/$CELL"
  STATE="$CELL_ROOT/state.tsv"
}

validate_paths() {
  cell_fields
  [[ $BACKING_ROOT == "/mnt/jfs-cache/jfs-04tmp2b-$FIXED_RUN" ]] || die "backing root scope"
  [[ $BACKING == "/mnt/jfs-cache/jfs-04tmp2b-$FIXED_RUN/$CELL.img" ]] || die "backing scope"
  [[ $CACHE_MNT == "/tmp/jfs-04tmp2b-cache-$FIXED_RUN-$CELL" ]] || die "cache mount scope"
  [[ $JFS_MNT == "/tmp/jfs-04tmp2b-mnt-$FIXED_RUN-$CELL" ]] || die "JuiceFS mount scope"
  for p in "$BACKING" "$CACHE_MNT" "$JFS_MNT" "$CELL_ROOT"; do
    [[ -n $p && $p == /* && $p != / && $p != *'..'* && $p != *'*'* && $p != *'?'* ]] || die "unsafe path: $p"
    [[ ! -L $p ]] || die "symlink target refused: $p"
  done
}

state_get() { awk -F'\t' -v k="$1" '$1==k{v=$2} END{print v}' "$STATE"; }
state_add() { printf '%s\t%s\n' "$1" "$2" >>"$STATE"; }
record_cmd() { printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"; }

lease_for_item() {
  case $ITEM in
    mseqread|randread) printf '%s-phase-a\n' "$RUN_ID" ;;
    randwrite|randrw) printf '%s-phase-b\n' "$RUN_ID" ;;
    *) die "unknown item for lease" ;;
  esac
}

verify_runtime_health() {
  local out=$1 lease
  lease=$(lease_for_item)
  "$SCRUB_CONTROL" verify-paused "$lease" >"$out/scrub.txt" || die "scrub lease is not paused: $lease"
  mountpoint -q "$REFERENCE_MNT" || die "production JuiceFS reference mount absent"
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  for ep in 10.20.1.150:20180 10.20.1.151:20180 10.20.1.152:20180; do
    curl -fsS --connect-timeout 3 --max-time 5 "http://$ep/metrics" >/dev/null || die "TiKV metrics unavailable: $ep"
  done
}

resolve_backing_record() {
  local record=$1 raw
  [[ -r $record ]] || return 1
  raw=$(<"$record")
  [[ $raw == /* && $raw != / && $raw != *'..'* ]] || return 1
  realpath -e "$raw"
}

loop_backing() {
  local loop=$1 name=${loop##*/}
  [[ $loop =~ ^/dev/loop[0-9]+$ && -r /sys/block/$name/loop/backing_file ]] || return 1
  resolve_backing_record "/sys/block/$name/loop/backing_file"
}

verify_loop() {
  local loop=$1 expected actual matches
  expected=$(realpath -e "$BACKING") || die "cannot resolve backing"
  actual=$(loop_backing "$loop") || die "not a loop/backing unavailable: $loop"
  [[ $actual == "$expected" ]] || die "loop backing mismatch: $actual != $expected"
  matches=$(sudo losetup -j "$BACKING" | awk -F: '{print $1}')
  [[ $matches == "$loop" ]] || die "backing does not map uniquely to $loop: $matches"
}

asset_manifest() {
  local out=$1 include_mtime=$2 base=${3:-$JFS_MNT} dir pattern count expected_size
  case $ITEM in
    mseqread) dir="$base/test_dir/mseqread"; pattern='mseqread.*.0'; count=16; expected_size=4294967296 ;;
    randread) dir="$base/test_dir"; pattern='read_test.*.0'; count=128; expected_size=1073741824 ;;
    randwrite) dir="$base/test_dir"; pattern='storage_test.*.0'; count=128; expected_size=1073741824 ;;
    randrw) dir="$base/test_dir"; pattern='rw_test.*.0'; count=128; expected_size=1073741824 ;;
    *) die "unknown item" ;;
  esac
  [[ -d $dir && ! -L $dir ]] || die "asset directory unavailable: $dir"
  if [[ $include_mtime == yes ]]; then
    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%i\t%s\t%T@\n' | sort -V >"$out"
  else
    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%f\t%i\t%s\n' | sort -V >"$out"
  fi
  [[ $(wc -l <"$out") -eq $count ]] || die "asset count mismatch for $ITEM"
  awk -F'\t' -v n="$expected_size" '$3!=n{bad=1} END{exit bad}' "$out" || die "asset size mismatch for $ITEM"
}

mount_process_gate() {
  python3 - "$JFS" "$META" "$JFS_MNT" "$CACHE_MNT/cache" "$TIER_MIB" <<'PY'
import os,sys
exe,meta,mnt,cache,tier=sys.argv[1:]
exe=os.path.realpath(exe); rows=[]
for name in os.listdir('/proc'):
    if not name.isdigit(): continue
    try:
        actual=os.path.realpath(f'/proc/{name}/exe')
        raw=open(f'/proc/{name}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace')
        st=open(f'/proc/{name}/stat').read().split()
    except OSError: continue
    if actual!=exe or f'--cache-dir {cache}' not in raw: continue
    rows.append((int(name),int(st[3]),raw))
if len(rows)!=2: raise SystemExit(f'expected JuiceFS daemon parent/worker, got {[(x[0],x[1]) for x in rows]}')
pids={x[0] for x in rows}; workers=[x for x in rows if x[1] in pids]
if len(workers)!=1: raise SystemExit(f'worker topology mismatch: {[(x[0],x[1]) for x in rows]}')
cmd=workers[0][2]
required=(f'--cache-dir {cache}',f'--cache-size {tier}','--free-space-ratio 0.20','--writeback',
          '--max-uploads 150','--max-fuse-io 256K','--metrics 127.0.0.1:9568')
missing=[x for x in required if x not in cmd]
if missing: raise SystemExit(f'mount argv missing: {missing}')
print(f'worker_pid\t{workers[0][0]}')
print(f'worker_ppid\t{workers[0][1]}')
print(f'cmdline\t{cmd}')
PY
}

jfs_process_gone() {
  python3 - "$JFS" "$CACHE_MNT/cache" <<'PY'
import os,sys
exe=os.path.realpath(sys.argv[1]); cache=sys.argv[2]; found=[]
for p in os.listdir('/proc'):
    if not p.isdigit(): continue
    try:
        if os.path.realpath(f'/proc/{p}/exe')==exe and f'--cache-dir {cache}' in open(f'/proc/{p}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace'):
            found.append(p)
    except OSError: pass
if found: raise SystemExit(1)
PY
}

mount_jfs() {
  [[ ! -e $JFS_MNT ]] || die "JuiceFS mount path already exists"
  mkdir -m 0700 "$JFS_MNT"
  local -a cmd=("$JFS" mount -d --max-uploads 150 --max-fuse-io 256K
    --cache-dir "$CACHE_MNT/cache" --cache-size "$TIER_MIB" --free-space-ratio 0.20
    --writeback --metrics "$METRICS_ADDR" "$META" "$JFS_MNT")
  record_cmd env "CEPH_CONF=$CEPH_CONF" "${cmd[@]}"
  if ! CEPH_CONF="$CEPH_CONF" "${cmd[@]}" >"$CELL_ROOT/mount.stdout" 2>"$CELL_ROOT/mount.stderr"; then
    die "JuiceFS mount command failed"
  fi
  local i
  for i in $(seq 1 120); do mountpoint -q "$JFS_MNT" && break; sleep 1; done
  mountpoint -q "$JFS_MNT" || die "JuiceFS mount timeout"
  findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/jfs-findmnt.tsv"
  mount_process_gate >"$CELL_ROOT/mount-process.tsv" || die "JuiceFS mount identity failed"
  curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/metrics-initial.txt" || die "metrics unavailable"
  grep -Eq '^juicefs_staging_blocks(\{| )' "$CELL_ROOT/metrics-initial.txt" || die "juicefs_staging_blocks metric unavailable"
  grep -Eq '^juicefs_staging_blocks\{[^}]*mp="'"$JFS_MNT"'"' "$CELL_ROOT/metrics-initial.txt" \
    || die "metrics mount identity mismatch"
}

staging_values() {
  local metrics blocks files bytes
  metrics=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || return 1
  blocks=$(awk '$1 ~ /^juicefs_staging_blocks(\{|$)/{sum+=$NF;found=1} END{if(found) print sum}' <<<"$metrics")
  [[ $blocks =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  read -r files bytes < <(find "$CACHE_MNT/cache" -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null | awk '{n++;s+=$1} END{print n+0,s+0}')
  printf '%s\t%s\t%s\n' "$blocks" "$files" "$bytes"
}

sample_runtime() {
  local stop=$1 out=$2 nic base blocks files bytes used avail
  nic=$(ip route get 10.20.1.150 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  base=$(findmnt -rn -T "$CACHE_PARENT" -o SOURCE | sed 's#^/dev/##')
  printf 'epoch_ns\tdf_used\tdf_avail\tstaging_blocks\tstaging_files\tstaging_bytes\trx_bytes\ttx_bytes\tbase_stat\n' >"$out"
  while [[ ! -f $stop ]]; do
    read -r used avail < <(df -B1 --output=used,avail "$CACHE_MNT" | awk 'NR==2{print $1,$2}')
    IFS=$'\t' read -r blocks files bytes < <(staging_values) || { blocks=NA; files=NA; bytes=NA; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$used" "$avail" "$blocks" "$files" "$bytes" \
      "$(cat "/sys/class/net/$nic/statistics/rx_bytes")" "$(cat "/sys/class/net/$nic/statistics/tx_bytes")" \
      "$(tr -s ' ' <"/sys/class/block/$base/stat" 2>/dev/null || printf NA)" >>"$out"
    sleep 1
  done
}

fio_common() {
  local kind=$1 runtime=$2 out=$3
  local -a cmd=(fio --output-format=json --output="$out/fio.json" --time_based --runtime="$runtime"
    --direct=1 --fallocate=none --allow_file_create=0 --create_on_open=0 --group_reporting
    --write_bw_log="$out/bw/$ITEM" --log_avg_msec=1000)
  case $ITEM:$kind in
    mseqread:*) cmd+=(--name=mseqread --directory="$JFS_MNT/test_dir/mseqread" --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --ioengine=psync --iodepth=1) ;;
    randread:*) cmd+=(--name=read_test --directory="$JFS_MNT/test_dir" --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --openfiles=128) ;;
    randwrite:*) cmd+=(--name=storage_test --directory="$JFS_MNT/test_dir" --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --openfiles=128) ;;
    randrw:warmup) cmd+=(--name=rw_test --directory="$JFS_MNT/test_dir" --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --openfiles=128) ;;
    randrw:formal) cmd+=(--name=rw_test --directory="$JFS_MNT/test_dir" --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --openfiles=128) ;;
    *) die "unsupported fio contract $ITEM:$kind" ;;
  esac
  record_cmd timeout "$((runtime + 60))" "${cmd[@]}"
  mkdir -p "$out/bw"
  local rc
  if timeout "$((runtime + 60))" "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/fio-end-ns.txt"
  (( rc == 0 )) || return "$rc"
  python3 - "$out/fio.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); jobs=d.get('jobs',[])
if not jobs: raise SystemExit('fio jobs missing')
bad=[(j.get('jobname'),j.get('error')) for j in jobs if int(j.get('error',-1))!=0]
if bad: raise SystemExit(f'job errors: {bad[:5]}')
PY
}

wait_drain() {
  local out=$1 start now blocks files bytes zeros=0
  start=$(date +%s); printf 'epoch\tstaging_blocks\tstaging_files\tstaging_bytes\n' >"$out"
  while :; do
    now=$(date +%s)
    IFS=$'\t' read -r blocks files bytes < <(staging_values) || die "cannot read staging during drain"
    printf '%s\t%s\t%s\t%s\n' "$now" "$blocks" "$files" "$bytes" >>"$out"
    if [[ $blocks == 0 || $blocks == 0.0 ]] && (( files == 0 && bytes == 0 )); then zeros=$((zeros+1)); else zeros=0; fi
    if (( zeros >= 2 )); then printf '%s\n' "$((now-start))" >"$CELL_ROOT/drain-seconds.txt"; return 0; fi
    (( now - start < 900 )) || die "staging did not drain within 900s"
    sleep 10
  done
}

create_storage() {
  [[ ! -e $BACKING && ! -e $CACHE_MNT && ! -e $JFS_MNT ]] || die "cell asset already exists"
  [[ -d $CACHE_PARENT && ! -L $CACHE_PARENT ]] || die "cache parent unavailable"
  local foreign
  foreign=$(find "$CACHE_PARENT" -mindepth 1 -maxdepth 1 ! -name lost+found ! -path "$BACKING_ROOT" -printf '%p\n')
  [[ -z $foreign ]] || die "cache parent has foreign entries: $foreign"
  [[ -d $BACKING_ROOT && ! -L $BACKING_ROOT && $(stat -Lc %u "$BACKING_ROOT") -eq $EXPECTED_UID \
      && $(stat -Lc %g "$BACKING_ROOT") -eq $EXPECTED_GID && $(stat -Lc %a "$BACKING_ROOT") == 700 ]] \
    || die "RUN backing root missing or identity/mode mismatch"
  [[ -z $(find "$BACKING_ROOT" -mindepth 1 -maxdepth 1 -printf '%p\n') ]] \
    || die "RUN backing root is not empty before cell"
  [[ $(id -u) -eq $EXPECTED_UID && $(id -g) -eq $EXPECTED_GID ]] || die "executor UID/GID mismatch"
  local current_parent frozen_parent
  current_parent=$(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS)
  frozen_parent=$(<"$ROOT/inventory/cache-parent.freeze")
  [[ $current_parent == "$frozen_parent" ]] || die "cache parent identity drift"
  local available
  available=$(df -B1 --output=avail "$CACHE_PARENT" | awk 'NR==2{print $1}')
  [[ $available =~ ^[0-9]+$ && $available -ge $((BYTES + 10737418240)) ]] \
    || die "insufficient cache-parent space: available=$available required=$((BYTES + 10737418240))"
  mkdir -m 0700 "$CACHE_MNT"
  record_cmd mkdir -m 0700 "$CACHE_MNT"
  record_cmd fallocate -l "$BYTES" -- "$BACKING"
  fallocate -l "$BYTES" -- "$BACKING"
  [[ $(stat -Lc %s "$BACKING") -eq $BYTES ]] || die "backing size mismatch"
  local backing_dev backing_inode
  backing_dev=$(stat -Lc %d "$BACKING"); backing_inode=$(stat -Lc %i "$BACKING")
  {
    printf 'run_id\t%s\ncell\t%s\nitem\t%s\ntier_mib\t%s\nbytes\t%s\nbacking\t%s\ncache_mount\t%s\njfs_mount\t%s\n' \
      "$RUN_ID" "$CELL" "$ITEM" "$TIER_MIB" "$BYTES" "$BACKING" "$CACHE_MNT" "$JFS_MNT"
    printf 'backing_dev\t%s\nbacking_inode\t%s\n' "$backing_dev" "$backing_inode"
  } >"$STATE"
  local loop
  record_cmd sudo losetup --find --show --nooverlap "$BACKING"
  loop=$(sudo losetup --find --show --nooverlap "$BACKING")
  [[ $loop =~ ^/dev/loop[0-9]+$ ]] || die "invalid returned loop: $loop"
  state_add loop "$loop"; state_add status LOOP_ATTACHED
  verify_loop "$loop"
  record_cmd sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop"
  sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop" \
    >"$CELL_ROOT/mkfs.stdout" 2>"$CELL_ROOT/mkfs.stderr"
  record_cmd sudo mount -o noatime,nodiscard "$loop" "$CACHE_MNT"
  sudo mount -o noatime,nodiscard "$loop" "$CACHE_MNT"
  record_cmd sudo chown "$EXPECTED_UID:$EXPECTED_GID" "$CACHE_MNT"
  sudo chown "$EXPECTED_UID:$EXPECTED_GID" "$CACHE_MNT"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die "cache ext4 mount source mismatch"
  local fs_uuid='' i
  for i in $(seq 1 30); do
    fs_uuid=$(findmnt -rn -M "$CACHE_MNT" -o UUID)
    [[ $fs_uuid =~ ^[0-9a-fA-F-]{36}$ ]] && break
    sleep 1
  done
  [[ $fs_uuid =~ ^[0-9a-fA-F-]{36}$ ]] || fs_uuid=UNAVAILABLE_NONBLOCKING
  state_add fs_uuid "$fs_uuid"; state_add status CACHE_MOUNTED
  findmnt -rn -M "$CACHE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,UUID >"$CELL_ROOT/cache-findmnt.tsv"
}

cleanup_success() {
  local loop backing_dev backing_inode detach_out detach_rc
  loop=$(state_get loop); backing_dev=$(state_get backing_dev); backing_inode=$(state_get backing_inode)
  mountpoint -q "$JFS_MNT" && die "refuse cleanup while JuiceFS is mounted"
  [[ $(stat -Lc %d "$BACKING") == "$backing_dev" && $(stat -Lc %i "$BACKING") == "$backing_inode" \
      && $(stat -Lc %s "$BACKING") -eq $BYTES ]] || die "backing identity changed before cleanup"
  verify_loop "$loop"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$loop" ]] || die "cleanup mount source mismatch"
  record_cmd sudo umount "$CACHE_MNT"
  sudo umount "$CACHE_MNT"
  ! mountpoint -q "$CACHE_MNT" || die "cache ext4 still mounted"
  verify_loop "$loop"
  record_cmd sudo losetup -d "$loop"
  sudo losetup -d "$loop"
  set +e
  detach_out=$(sudo losetup -j "$BACKING" 2>&1); detach_rc=$?
  set -e
  (( detach_rc == 0 )) || die "losetup verification failed after detach: $detach_out"
  [[ -z $detach_out ]] || die "loop remains after detach: $detach_out"
  record_cmd unlink -- "$BACKING"
  unlink -- "$BACKING"
  record_cmd rmdir "$CACHE_MNT"
  [[ ! -e $CACHE_MNT ]] || rmdir "$CACHE_MNT"
  record_cmd rmdir "$JFS_MNT"
  [[ ! -e $JFS_MNT ]] || rmdir "$JFS_MNT"
  state_add status DESTROYED
}

cmd_inventory() {
  validate_run
  [[ ! -e $ROOT ]] || die "result root already exists"
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans"
  printf '#!/usr/bin/env bash\n' >"$ROOT/commands.sh"
  hostname -f >"$ROOT/inventory/hostname.txt"
  id >"$ROOT/inventory/id.txt"
  date -Ins >"$ROOT/inventory/time.txt"
  command -v fio >"$ROOT/inventory/fio-path.txt"; fio --version >"$ROOT/inventory/fio-version.txt"
  [[ -x $JFS && ! -L $JFS && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die "JuiceFS binary identity mismatch"
  "$JFS" --version >"$ROOT/inventory/juicefs-version.txt" 2>&1
  "$JFS" mount --help >"$ROOT/inventory/mount-help.txt" 2>&1 || true
  grep -q -- '--writeback' "$ROOT/inventory/mount-help.txt" || die "writeback option unavailable"
  grep -q -- '--metrics' "$ROOT/inventory/mount-help.txt" || die "metrics option unavailable"
  [[ -d $REFERENCE_MNT/test_dir ]] || die "reference dataset missing"
  findmnt -rn -M "$REFERENCE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-mount.tsv"
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"
  df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"
  stat -Lc 'path=%n dev=%d inode=%i mode=%a uid=%u gid=%g type=%F' "$CACHE_PARENT" >"$ROOT/inventory/cache-stat.tsv"
  find "$CACHE_PARENT" -mindepth 1 -maxdepth 1 -printf '%y\t%p\t%s\t%u\t%g\n' | sort >"$ROOT/inventory/cache-existing.tsv"
  sudo losetup -l -O NAME,BACK-FILE >"$ROOT/inventory/loops.tsv"
  ss -lntp >"$ROOT/inventory/listeners.tsv" 2>&1 || true
  ! awk -v p=":${METRICS_ADDR##*:}" '$4 ~ p"$"{found=1} END{exit found?0:1}' "$ROOT/inventory/listeners.tsv" \
    || die "metrics port already occupied"
  pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1 && die "foreign fio exists"
  "$SCRUB_CONTROL" inspect "$RUN_ID-phase-a" >"$ROOT/inventory/scrub-a.txt"
  "$SCRUB_CONTROL" plan-pause "$RUN_ID-phase-a" >"$ROOT/plans/scrub-a-plan.txt"
  "$SCRUB_CONTROL" inspect "$RUN_ID-phase-b" >"$ROOT/inventory/scrub-b.txt"
  "$SCRUB_CONTROL" plan-pause "$RUN_ID-phase-b" >"$ROOT/plans/scrub-b-plan.txt"
  for ep in 10.20.1.150:20180 10.20.1.151:20180 10.20.1.152:20180; do
    host=${ep%:*}; curl -fsS --connect-timeout 3 --max-time 5 "http://$ep/metrics" >"$ROOT/inventory/tikv-$host.metrics" || die "TiKV endpoint unavailable: $ep"
  done
  for item in mseqread randread randwrite randrw; do
    for tier in 16 64 32; do CELL="$item-c$tier"; cell_fields; asset_manifest "$ROOT/inventory/assets-$CELL.tsv" no "$REFERENCE_MNT"; done
  done
  printf 'INVENTORY_PASS\n' >"$ROOT/inventory/PASS"
  printf '04TMP2B_INVENTORY_PASS root=%s\n' "$ROOT"
}

cmd_plan() {
  validate_run; [[ -f $ROOT/inventory/PASS ]] || die "inventory PASS missing"
  printf 'cell\titem\ttier_mib\tbytes\tbacking\tcache_mount\tjfs_mount\n' >"$ROOT/plans/cells.tsv"
  for item in mseqread randread randwrite randrw; do
    for tier in 16 64 32; do
      CELL="$item-c$tier"; cell_fields
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CELL" "$ITEM" "$TIER_MIB" "$BYTES" "$BACKING" "$CACHE_MNT" "$JFS_MNT" >>"$ROOT/plans/cells.tsv"
    done
  done
  cat >"$ROOT/plans/sudo-contract.txt" <<'EOF'
Once before phase-a:
sudo install -d -m 0700 -o 1002 -g 1002 /mnt/jfs-cache/jfs-04tmp2b-20260903-000000
Per whitelist cell only:
sudo losetup --find --show --nooverlap <exact backing>
sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <identity-verified loop>
sudo mount -o noatime,nodiscard <same loop> <exact cache mount>
sudo chown 1002:1002 <exact cache mount>
sudo umount <exact cache mount>
sudo losetup -d <same identity-verified loop>
Scrub controller only: sudo ceph osd set/unset noscrub and nodeep-scrub.
Once after all 12 cells and residual checks:
sudo rmdir /mnt/jfs-cache/jfs-04tmp2b-20260903-000000
EOF
  sha256sum "$0" "${0%/*}/t04tmp2b-cache-analyze.py" "${0%/*}/t04tmp2b-cache-gate0-offline.sh" \
    "${0%/*}/u141d-scrub-control.sh" >"$ROOT/plans/scripts.sha256"
  printf 'PLAN_PASS\n' >"$ROOT/plans/PASS"
  printf '04TMP2B_PLAN_PASS root=%s\n' "$ROOT"
}

cmd_run_cell() {
  validate_run; validate_paths
  [[ ${TMP2B_ACK:-} == "I_ACK_04TMP2B_$RUN_ID" ]] || die "exact execution ACK missing"
  [[ -f $ROOT/plans/PASS ]] || die "plan PASS missing"
  sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die "script drift"
  [[ ! -e $CELL_ROOT ]] || die "cell evidence already exists"
  mkdir -m 0700 -p "$CELL_ROOT"
  pgrep -a -x fio >"$CELL_ROOT/foreign-fio-pre.tsv" 2>&1 && die "foreign fio exists"
  mkdir -p "$CELL_ROOT/health-pre" "$CELL_ROOT/health-post"
  verify_runtime_health "$CELL_ROOT/health-pre"
  create_storage
  mount_jfs
  local read_only=no
  [[ $ITEM == mseqread || $ITEM == randread ]] && read_only=yes
  asset_manifest "$CELL_ROOT/assets-pre.tsv" "$read_only"
  if [[ $ITEM == mseqread || $ITEM == randread || $ITEM == randrw ]]; then
    mkdir -p "$CELL_ROOT/warmup"
    fio_common warmup 180 "$CELL_ROOT/warmup" || die "warmup fio failed; preserve cell"
  fi
  local stop="$CELL_ROOT/sampler.stop" sampler_pid fio_rc sampler_rc
  sample_runtime "$stop" "$CELL_ROOT/runtime.tsv" >"$CELL_ROOT/sampler.stdout" 2>"$CELL_ROOT/sampler.stderr" &
  sampler_pid=$!; printf '%s\n' "$sampler_pid" >"$CELL_ROOT/sampler.pid"
  if fio_common formal 180 "$CELL_ROOT"; then fio_rc=0; else fio_rc=$?; fi
  : >"$stop"
  if wait "$sampler_pid"; then sampler_rc=0; else sampler_rc=$?; fi
  printf '%s\n' "$sampler_rc" >"$CELL_ROOT/sampler.rc"
  (( fio_rc == 0 && sampler_rc == 0 )) || die "formal/sampler failed; preserve cell"
  ! grep -Eq $'\tNA(\t|$)' "$CELL_ROOT/runtime.tsv" || die "runtime sampler contains unavailable fields"
  asset_manifest "$CELL_ROOT/assets-post.tsv" "$read_only"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post.tsv" || die "asset identity drift; preserve cell"
  if [[ $ITEM == randwrite || $ITEM == randrw ]]; then wait_drain "$CELL_ROOT/drain.tsv"; else printf '0\n' >"$CELL_ROOT/drain-seconds.txt"; fi
  verify_runtime_health "$CELL_ROOT/health-post"
  record_cmd "$JFS" umount "$JFS_MNT"
  "$JFS" umount "$JFS_MNT" >"$CELL_ROOT/umount.stdout" 2>"$CELL_ROOT/umount.stderr" || die "JuiceFS umount failed"
  local i; for i in $(seq 1 180); do ! mountpoint -q "$JFS_MNT" && break; sleep 1; done
  ! mountpoint -q "$JFS_MNT" || die "JuiceFS umount timeout"
  for i in $(seq 1 60); do jfs_process_gone && break; sleep 1; done
  jfs_process_gone || die "JuiceFS process remains 60s after umount"
  cleanup_success
  printf 'CELL_PASS\t%s\n' "$CELL" >"$CELL_ROOT/PASS"
  printf '04TMP2B_CELL_PASS cell=%s\n' "$CELL"
}

cmd_recover_cell() {
  validate_run; validate_paths
  [[ ${TMP2B_ACK:-} == "I_ACK_04TMP2B_$RUN_ID" ]] || die "exact execution ACK missing"
  [[ -f $STATE && ! -L $STATE ]] || die "recover state missing"
  [[ $(state_get run_id) == "$RUN_ID" && $(state_get cell) == "$CELL" \
      && $(state_get backing) == "$BACKING" && $(state_get cache_mount) == "$CACHE_MNT" \
      && $(state_get jfs_mount) == "$JFS_MNT" ]] || die "recover state identity mismatch"
  [[ $(cat "$CELL_ROOT/fio.rc") == 0 && $(cat "$CELL_ROOT/sampler.rc") == 0 ]] \
    || die "recover refuses failed performance evidence"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post.tsv" || die "recover asset evidence mismatch"
  ! grep -Eq $'\tNA(\t|$)' "$CELL_ROOT/runtime.tsv" || die "recover sampler contains unavailable fields"
  ! mountpoint -q "$JFS_MNT" || die "recover refuses active JuiceFS mount"
  local i
  for i in $(seq 1 60); do jfs_process_gone && break; sleep 1; done
  jfs_process_gone || die "recover sees JuiceFS process after 60s"
  cleanup_success
  printf 'status\tPOST_FIO_CLEANUP_RECOVERED\n' >>"$STATE"
  printf 'CELL_PASS\t%s\n' "$CELL" >"$CELL_ROOT/PASS"
  printf '04TMP2B_RECOVER_CELL_PASS cell=%s\n' "$CELL"
}

cmd_inspect_cell() {
  validate_run; validate_paths
  printf 'CELL=%s\nBACKING=%s\nCACHE_MNT=%s\nJFS_MNT=%s\n' "$CELL" "$BACKING" "$CACHE_MNT" "$JFS_MNT"
  [[ ! -f $STATE ]] || sed -n '1,120p' "$STATE"
  findmnt -rn -M "$JFS_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
  findmnt -rn -M "$CACHE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
  sudo losetup -j "$BACKING" 2>/dev/null || true
  [[ ! -d $CACHE_MNT/cache ]] || staging_values || true
}

cmd_offline_self_test() {
  validate_run
  for cell in mseqread-c16 mseqread-c64 mseqread-c32 randread-c16 randread-c64 randread-c32 randwrite-c16 randwrite-c64 randwrite-c32 randrw-c16 randrw-c64 randrw-c32; do
    CELL=$cell; validate_paths
  done
  CELL=invalid-c16
  if (validate_paths) >/dev/null 2>&1; then die "invalid cell accepted"; fi
  local fixture_backing="/tmp/t04tmp2b-backing-fixture-$$" fixture_record="/tmp/t04tmp2b-backing-record-$$"
  : >"$fixture_backing"; printf '%s\n' "$fixture_backing" >"$fixture_record"
  [[ $(resolve_backing_record "$fixture_record") == "$fixture_backing" ]] || die "sysfs backing record fixture failed"
  unlink "$fixture_record"; unlink "$fixture_backing"
  printf '04TMP2B_OFFLINE_SELF_TEST_PASS\n'
}

case $MODE in
  offline-self-test) cmd_offline_self_test ;;
  inventory) cmd_inventory ;;
  plan) cmd_plan ;;
  run-cell) cmd_run_cell ;;
  recover-cell) cmd_recover_cell ;;
  inspect-cell) cmd_inspect_cell ;;
  *) usage; exit 2 ;;
esac
