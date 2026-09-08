#!/usr/bin/env bash
set -euo pipefail
MODE=${1:-}
RUN_ID=${2:-}
CELL=${3:-}
REQUEST_KIND=R
ROOT=/tmp/production/opencode-04tmp2h-$RUN_ID
die() { printf 'E_04TMP2H\t%s\n' "$*" >&2; exit 42; }
incident() { mkdir -m 0700 -p "$ROOT"; printf '%s\t%s\t%s\n' "$(date +%s%N)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-04tmp2h-$RUN_ID && $ROOT != / && ! -L $ROOT ]] || die unsafe_result_root
  if [[ -e $ROOT ]]; then
    [[ -d $ROOT && $(stat -Lc %u "$ROOT") -eq 1002 && $(stat -Lc %g "$ROOT") -eq 1002 && $(stat -Lc %a "$ROOT") == 700 ]] || die result_root_identity
  fi
}
usage() { printf '%s\n' "usage"; }
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
JFS=/tmp/juicefs-1.4.1-patched
REF=/mnt/juicefs
CACHE_PARENT=/mnt/jfs-cache
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
ANALYZER=$SCRIPT_DIR/t04tmp2h-randrw-analyze.py
NSB_GATE=$SCRIPT_DIR/t39-nsbgate.sh
FORMAL_RW=randrw; FORMAL_MIX=50; FORMAL_JOBS=128; FORMAL_RUNTIME=180
FORMAL_SIZE=1G; FORMAL_BS=256K; WARMUP_RUNTIME=180; M_ONLINE=0.08; MARGIN=0.08
METRICS_ADDR=127.0.0.1:9568
readonly META JFS REF CACHE_PARENT FORMAL_RW FORMAL_MIX FORMAL_JOBS FORMAL_RUNTIME FORMAL_SIZE FORMAL_BS WARMUP_RUNTIME
cell_spec() {
  KIND=; SIZE=0; CACHE_MIB=0; WB=0
  case $CELL in
    A0-pre|A0-mid|A0-post) KIND=A0 ;;
    T32|T64|T96|T128|T256)
      KIND=$REQUEST_KIND; SIZE=$(printf '%s' "$CELL" | sed 's/^T//')
      case $KIND in R) WB=0;; W|P25|P50|P75) WB=1;; *) die invalid_kind ;; esac
      ;;
    *) die invalid_cell ;;
  esac
  MNT=/tmp/jfs-04tmp2h-$RUN_ID-$CELL-$KIND
  CELL_ROOT=$ROOT/cells/$CELL-$KIND
  CACHE_DIR=$ROOT/cache/$CELL
}
matrix() {
  cat <<'EOF'
A0-pre
T32-R
T32-W
T32-P50
T128-W
T128-R
T128-P50
T64-R
T64-W
T64-P50
A0-mid
T256-W
T256-R
T256-P50
T96-R
T96-W
T96-P50
A0-post
EOF
}
record() { mkdir -p "$CELL_ROOT"; printf '%s\t%s\n' "$1" "$2" >>"$CELL_ROOT/status.tsv"; }
log_command() {
  printf '%q ' "$@" >>"$ROOT/commands.sh"; printf '\n' >>"$ROOT/commands.sh"
  [[ -z ${CELL_ROOT:-} ]] || { printf '%q ' "$@" >>"$CELL_ROOT/commands.sh"; printf '\n' >>"$CELL_ROOT/commands.sh"; }
}
metric_text() {
  awk -v n="$2" '$1 ~ ("^" n "($|\\{)") {s+=$(NF);f=1} END{if(f)printf "%.0f",s;else print "NA"}' <<<"$1"
}
assert_no_forbidden() {
  ! grep -Eq '(^|[[:space:]])(rm[[:space:]]+-rf|umount[[:space:]]+(-f|--force|-l|--lazy)|pkill|killall|fuser[[:space:]]+-k|drop_caches|pool[[:space:]]+(create|delete))([[:space:]]|$)' "$0" || die forbidden_command_in_source
}
offline_self_test() {
  RUN_ID=20000101-000000; ROOT=/tmp/production/opencode-04tmp2h-$RUN_ID
  assert_no_forbidden
  [[ $(matrix | wc -l) -eq 18 ]] || die matrix_count
  [[ $(matrix | sed -n '/^T[0-9].*-R$/p' | wc -l) -eq 5 ]] || die read_matrix
  [[ $(matrix | sed -n '/^T[0-9].*-W$/p' | wc -l) -eq 5 ]] || die write_matrix
  [[ $(matrix | sed -n '/^T[0-9].*-P50$/p' | wc -l) -eq 5 ]] || die p50_matrix
  grep -q '^A0-pre$' <(matrix) && grep -q '^A0-mid$' <(matrix) && grep -q '^A0-post$' <(matrix) || die anchors
  grep -q -- '--max-fuse-io 256K' "$0" || die mount_contract
  grep -q -- '--max-uploads 150' "$0" || die upload_contract
  grep -q -- '--free-space-ratio 0.20' "$0" || die free_space_contract
  grep -q 'time_based' "$0" || die fio_time_based
  printf '04TMP2H_OFFLINE_SELF_TEST_PASS matrix=18 capacities=32,64,96,128,256\n'
}
make_ceph_conf() {
  mkdir -m 0700 -p "$ROOT/inventory"
  CEPH_CONF=$ROOT/inventory/ceph.conf
  [[ -r /etc/ceph/ceph.conf ]] || die ceph_conf_missing
  cp -- /etc/ceph/ceph.conf "$CEPH_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >>"$CEPH_CONF"
  chmod 0600 "$CEPH_CONF"
  [[ $(md5sum "$CEPH_CONF" | awk '{print $1}') == 86351c58848c7e4caaa1bbeccb211730 ]] || die ceph_conf_md5
}
inventory_plan() {
  valid_run
  [[ ! -e $ROOT ]] || die result_exists
  # mkdir -p applies -m only to newly-created leaf directories.  /tmp/production
  # is setgid on this host, so create and normalize the RUN root explicitly.
  mkdir -p "$ROOT"
  chmod 0700 "$ROOT"
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans" "$ROOT/cells" "$ROOT/cache"
  [[ -x $JFS && -d $REF && -d $CACHE_PARENT ]] || die prerequisite_missing
  make_ceph_conf
  [[ $(id -u) -eq 1002 && $(id -g) -eq 1002 ]] || die executor_identity
  id >"$ROOT/inventory/executor-id.txt"
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"
  sha256sum "$JFS" >"$ROOT/inventory/juicefs.sha256"
  "$JFS" version >"$ROOT/inventory/juicefs-version.txt"
  CEPH_CONF="$ROOT/inventory/ceph.conf" "$JFS" status "$META" >"$ROOT/inventory/volume-status.json" || die volume_status
  python3 - "$ROOT/inventory/volume-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d.get('Setting',{})
if s.get('Name') != 'juicefs-prod' or not s.get('UUID'):
    raise SystemExit('volume identity mismatch')
PY
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph fsid >"$ROOT/inventory/fsid.txt" || die ceph_fsid
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph osd ls --format json | \
    python3 -c 'import json,sys; print("\n".join(map(str,json.load(sys.stdin))))' >"$ROOT/inventory/osd-ids.txt"
  [[ $(wc -l <"$ROOT/inventory/osd-ids.txt") -eq 6 ]] || die osd_count_not_6
  if grep -Eqv '^[0-9]+$' "$ROOT/inventory/osd-ids.txt"; then die invalid_osd_id; fi
  findmnt -rn -M "$REF" >"$ROOT/inventory/reference-mount.tsv"
  grep -q 'JuiceFS:juicefs-prod' "$ROOT/inventory/reference-mount.tsv" || die current_mount_identity
  grep -q '/mnt/juicefs' "$ROOT/inventory/reference-mount.tsv" || die current_mount_identity
  df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"
  df -B1 "$CACHE_PARENT" | awk 'NR==2{printf "%d\n", $4/1048576}' >"$ROOT/inventory/cache-available-mib"
  [[ $(df -B1 "$CACHE_PARENT" | awk 'NR==2{print $4}') -ge $((320*1024*1024*1024)) ]] || die cache_free_320g_gate
  find "$REF/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\t%T@\n' | sort -V >"$ROOT/inventory/assets.tsv"
  [[ $(wc -l <"$ROOT/inventory/assets.tsv") -eq 128 ]] || die asset_count
  awk -F '\t' '$3 != 1073741824 {bad=1} END {exit bad}' "$ROOT/inventory/assets.tsv" || die asset_size
  for i in $(seq 0 127); do awk -F '\t' -v n="rw_test.$i.0" '$1==n{found=1} END{exit !found}' "$ROOT/inventory/assets.tsv" || die "asset_name_$i"; done
  cut -f1-3 "$ROOT/inventory/assets.tsv" >"$ROOT/inventory/assets-core.tsv"
  find "$REF/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$ROOT/inventory/a0-probe-assets.tsv"
  [[ $(wc -l <"$ROOT/inventory/a0-probe-assets.tsv") -eq 16 ]] || die a0_probe_asset_count
  awk -F '\t' '$3 != 4294967296 {bad=1} END {exit bad}' "$ROOT/inventory/a0-probe-assets.tsv" || die a0_probe_asset_size
  for i in $(seq 0 15); do awk -F '\t' -v n="mseqread.$i.0" '$1==n{found=1} END{exit !found}' "$ROOT/inventory/a0-probe-assets.tsv" || die "a0_probe_asset_name_$i"; done
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph df -f json >"$ROOT/inventory/pool-pre-normalization.json" || die pool_pre_normalization
  python3 - "$ROOT/inventory/pool-pre-normalization.json" >"$ROOT/inventory/pool-pre-normalization.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); objs=stored=0; found=0
for p in d.get("pools",[]):
  if p.get("name") != "juicefs-data": continue
  found += 1
  s=p.get("stats",{})
  objs += s.get("objects",0) or 0
  stored += s.get("stored",0) or 0
if found != 1: raise SystemExit("juicefs-data pool missing or duplicated")
print("objects\t%s\nstored\t%s"%(objs,stored))
PY
  if pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1; then die foreign_fio; fi
  ss -ltnp >"$ROOT/inventory/listeners.tsv" 2>&1 || die listener_inventory
  ! awk '$4 ~ /:9568$/ {found=1} END {exit found?0:1}' "$ROOT/inventory/listeners.tsv" || die metrics_port_busy
  findmnt -rn >"$ROOT/inventory/findmnt-all.tsv" || die findmnt_inventory
  losetup -l -n -O NAME,BACK-FILE >"$ROOT/inventory/loops.tsv" || die loop_inventory
  if pgrep -a -f '/tmp/jfs-04tmp2h-[0-9]{8}-[0-9]{6}-' >"$ROOT/inventory/tmp2h-processes.tsv" 2>&1; then
    die stale_tmp2h_process
  fi
  ip -j link >"$ROOT/inventory/nic.json" || die nic_inventory
  find "$REF/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\n' | sort -V >"$ROOT/inventory/asset-manifest.txt"
  matrix >"$ROOT/plans/matrix-order.txt"
  write_sudo_plan
  printf 'RUN_ID\t%s\n' "$RUN_ID" >"$ROOT/run-state.tsv"
  printf 'epoch_ns\tcell\tevent\n' >"$ROOT/incidents.tsv"
  printf 'INVENTORY_PLAN_PASS\n' >"$ROOT/plans/PASS"
}
write_sudo_plan() {
  cat >"$ROOT/plans/sudo-contract.txt" <<EOF
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set noscrub
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set nodeep-scrub
sudo install -d -m 0700 -o 1002 -g 1002 /mnt/jfs-cache/jfs-04tmp2h-$RUN_ID
sudo losetup --find --show --nooverlap /mnt/jfs-cache/jfs-04tmp2h-$RUN_ID/CELL.img
sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 LOOP_DEVICE
sudo mount -o noatime,nodiscard LOOP_DEVICE /tmp/jfs-04tmp2h-cache-$RUN_ID-CELL
sudo chown 1002:1002 /tmp/jfs-04tmp2h-cache-$RUN_ID-CELL
sudo umount /tmp/jfs-04tmp2h-cache-$RUN_ID-CELL
sudo losetup -d LOOP_DEVICE
sudo rmdir /mnt/jfs-cache/jfs-04tmp2h-$RUN_ID
EOF
  local osd
  while read -r osd; do
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s compact\n' "$ROOT/inventory/ceph.conf" "$osd"
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s perf dump # read-only\n' "$ROOT/inventory/ceph.conf" "$osd"
  done <"$ROOT/inventory/osd-ids.txt" >>"$ROOT/plans/sudo-contract.txt"
  cat >>"$ROOT/plans/sudo-contract.txt" <<EOF
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset nodeep-scrub
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset noscrub
EOF
}
resolve_backing_record() {
  local record=$1 value
  [[ -r $record ]] || return 1
  value=$(<"$record")
  [[ $value == /* && $value != / && $value != *..* ]] || return 1
  realpath -e "$value"
}
loop_backing() {
  local loop=$1 name
  name=${loop##*/}
  [[ $loop =~ ^/dev/loop[0-9]+$ && -r /sys/block/$name/loop/backing_file ]] || return 1
  resolve_backing_record "/sys/block/$name/loop/backing_file"
}
mount_pid_gate() {
  local tag=$1
  python3 - "$JFS" "$CELL_ROOT/pids-$tag.txt" <<'PY'
import os,sys
exe,pre=sys.argv[1:]; exe=os.path.realpath(exe)
old={int(x) for x in open(pre) if x.strip().isdigit()}; rows=[]
for p in os.listdir('/proc'):
    if not p.isdigit() or int(p) in old: continue
    try:
        if os.path.realpath(f'/proc/{p}/exe') != exe: continue
        cmd=open(f'/proc/{p}/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace').strip()
        st=open(f'/proc/{p}/stat').read().split()
        # JuiceFS (Go) rewrites and may truncate argv after daemonizing.  Do not
        # use the process title as identity.  The pre-mount PID snapshot plus
        # exact executable and a unique new parent/worker pair are stable; the
        # caller separately verifies the exact FUSE source and mountpoint.
        rows.append((int(p),int(st[3]),int(st[21]),cmd))
    except (OSError,ValueError): pass
if len(rows) != 2: raise SystemExit(f'expected parent/worker pair: {rows}')
pids={x[0] for x in rows}; workers=[x for x in rows if x[1] in pids]
if len(workers) != 1: raise SystemExit(f'parent/worker mismatch: {rows}')
print('pid\tppid\tstarttime\tselected_worker\tcmdline')
for row in sorted(rows): print(*row[:3],int(row[0]==workers[0][0]),row[3],sep='\t')
PY
}
jfs_gone() {
  local process_file=$1
  [[ ! -f $process_file ]] && return 0
  python3 - "$JFS" "$process_file" <<'PY'
import csv,os,sys
exe=os.path.realpath(sys.argv[1])
for r in csv.DictReader(open(sys.argv[2]),delimiter='\t'):
    try:
        if os.path.realpath('/proc/'+r['pid']+'/exe')==exe and open('/proc/'+r['pid']+'/stat').read().split()[21]==r['starttime']:
            raise SystemExit(1)
    except OSError: pass
PY
}
mount_jfs() {
  local tag=$1
  local -a cmd
  [[ $MNT == /tmp/jfs-04tmp2h-$RUN_ID-$CELL-$KIND && $MNT != / && ! -L $MNT ]] || die unsafe_mount_path
  ! ss -ltnH 2>/dev/null | awk '$4 ~ /:9568$/ {found=1} END {exit found?0:1}' || die metrics_port_busy
  if [[ $tag == recovery ]]; then
    [[ -d $MNT ]] || die recovery_mount_path_missing
  else
    [[ ! -e $MNT ]] || die mount_path_exists
  fi
  mkdir -m 0700 -p "$CELL_ROOT" "$MNT"
  : >"$CELL_ROOT/pids-$tag.txt"
  for p in /proc/[0-9]*; do
    [[ -e $p/exe && $(realpath "$p/exe" 2>/dev/null) == "$JFS" ]] && basename "$p" >>"$CELL_ROOT/pids-$tag.txt" || true
  done
  cmd=("$JFS" mount -d --max-uploads 150 --max-fuse-io 256K --log "$CELL_ROOT/juicefs-$tag.log")
  if [[ $KIND == A0 ]]; then
    cmd+=(--cache-size 0)
  else
    mkdir -m 0700 -p "$CACHE_DIR"
    cmd+=(--cache-dir "$CACHE_DIR" --cache-size "$CACHE_MIB" --free-space-ratio 0.20)
    (( WB )) && cmd+=(--writeback)
  fi
  cmd+=(--metrics "$METRICS_ADDR" "$META" "$MNT")
  log_command env "CEPH_CONF=$ROOT/inventory/ceph.conf" "${cmd[@]}"
  CEPH_CONF="$ROOT/inventory/ceph.conf" "${cmd[@]}" >"$CELL_ROOT/mount-$tag.stdout" 2>"$CELL_ROOT/mount-$tag.stderr"
  local i
  for i in $(seq 1 120); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || die mount_failed
  findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$CELL_ROOT/mount-$tag.findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $MNT fuse.juicefs " "$CELL_ROOT/mount-$tag.findmnt.tsv" || die mount_source_identity
  if ! mount_pid_gate "$tag" >"$CELL_ROOT/mount-$tag.process.tsv"; then
    # A failed identity gate occurs before fio.  Close only this exact mount so
    # a validation bug cannot leave a live client behind.
    "$JFS" umount "$MNT" >"$CELL_ROOT/identity-failure-umount.stdout" 2>"$CELL_ROOT/identity-failure-umount.stderr" || true
    for i in $(seq 1 20); do mountpoint -q "$MNT" || break; sleep 1; done
    if ! mountpoint -q "$MNT"; then rmdir "$MNT" 2>/dev/null || true; fi
    die mount_process_identity
  fi
  ACTIVE_PROCESS_FILE=$CELL_ROOT/mount-$tag.process.tsv
  printf 'metrics_addr\t%s\n' "$METRICS_ADDR" >>"$CELL_ROOT/state.tsv"
  printf 'active_process_file\t%s\n' "$ACTIVE_PROCESS_FILE" >>"$CELL_ROOT/state.tsv"
  curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/metrics-$tag.prom" || die metrics_unavailable
}
run_fio() {
  local label=$1 mode=$2 out
  out=$CELL_ROOT/$label
  mkdir -m 0700 -p "$out" "$out/bw"
  local fiofile=$out/fio.job
  cat >"$fiofile" <<EOF
[global]
ioengine=libaio
iodepth=128
direct=1
bs=256K
rw=$mode
rwmixread=50
size=1G
numjobs=128
openfiles=128
allow_file_create=0
create_on_open=0
fallocate=none
time_based
runtime=180
randrepeat=1
randseed=20260905
group_reporting=0
write_bw_log=$out/bw/randrw
per_job_logs=1
log_avg_msec=1000
filename_format=$MNT/test_dir/rw_test.\$jobnum.0
[job]
EOF
  printf '%s\n' "$mode" >"$out/direction.txt"
  printf 'fio %q --output=%q --output-format=json\n' "$fiofile" "$out/fio.json" >>"$ROOT/commands.sh"
  printf 'fio %q --output=%q --output-format=json\n' "$fiofile" "$out/fio.json" >>"$CELL_ROOT/commands.sh"
  date +%s%N >"$out/fio-start-ns.txt"
  set +e
  fio "$fiofile" --output="$out/fio.json" --output-format=json
  local rc=$?
  date +%s%N >"$out/fio-end-epoch-ns.txt"
  set -e
  printf '%s\n' "$rc" >"$out/fio.rc"
  [[ $rc -eq 0 ]] || return "$rc"
  for i in $(seq 1 128); do [[ -f "$out/bw/randrw_bw.$i.log" ]] || die "bw_log_missing_$i"; done
  [[ $(find "$out/bw" -maxdepth 1 -type f -name 'randrw_bw.*.log' | wc -l) -eq 128 ]] || die bw_log_count_not_exact
  cp -- "$out/fio.json" "$CELL_ROOT/fio.json"
  cp -- "$out/fio-start-ns.txt" "$CELL_ROOT/fio-start-ns.txt"
  cp -- "$out/fio-end-epoch-ns.txt" "$CELL_ROOT/fio-end-epoch-ns.txt"
}
sample_sidecar() {
  local label=$1
  curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/$label.metrics.prom" || die metrics_sample
  ps -eLo pid,tid,comm,utime,stime,args | awk '$0 ~ /juicefs/ {print}' >"$CELL_ROOT/$label.process.tsv"
  ip -s link >"$CELL_ROOT/$label.nic.txt"
  cat /proc/diskstats >"$CELL_ROOT/$label.diskstats.txt"
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph -s -f json >"$CELL_ROOT/$label.ceph.json" || die ceph_health
  for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
    curl -fsS --connect-timeout 3 --max-time 5 "http://$host:20180/metrics" >"$CELL_ROOT/$label.tikv-$host.metrics" || die tikv_metrics
  done
}
cache_inode_snapshot() {
  local label=$1
  [[ $KIND != A0 ]] || return 0
  printf 'path\tdevice\tinode\tsize_bytes\n' >"$CELL_ROOT/cache-inodes-$label.tsv"
  # raw/rawstaging entries may disappear while the writeback worker promotes
  # or uploads them.  ENOENT during traversal is expected churn, not a cell
  # failure; other find errors must still propagate through pipefail.
  find "$CACHE_DIR" -ignore_readdir_race -xdev -type f -printf '%p\t%D\t%i\t%s\n' 2>/dev/null | sort >>"$CELL_ROOT/cache-inodes-$label.tsv"
}
runtime_sampler() {
  local stop=$1 out=$2 text hit miss rawb rawbytes cachebytes writing evict drop free files filebytes value
  printf 'epoch_ns\thit_bytes\tmiss_bytes\tblockcache_bytes\tstaging_blocks\tstaging_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\tavailable_bytes\tevicts\tdrops\n' >"$out"
  while [[ ! -e $stop ]]; do
    text=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || return 42
    hit=$(metric_text "$text" juicefs_blockcache_hit_bytes)
    miss=$(metric_text "$text" juicefs_blockcache_miss_bytes)
    rawb=$(metric_text "$text" juicefs_staging_blocks)
    rawbytes=$(metric_text "$text" juicefs_staging_block_bytes)
    writing=$(metric_text "$text" juicefs_staging_writing_blocks)
    evict=$(metric_text "$text" juicefs_blockcache_evicts)
    drop=$(metric_text "$text" juicefs_blockcache_drops)
    cachebytes=$(metric_text "$text" juicefs_blockcache_bytes)
    for value in "$hit" "$miss" "$rawb" "$rawbytes" "$writing" "$evict" "$drop" "$cachebytes"; do
      [[ $value != NA ]] || return 42
    done
    files=0; filebytes=0; free=$(df -B1 /tmp | awk 'NR==2{print $4}')
    if [[ $KIND != A0 ]]; then
      read -r files filebytes < <(find "$CACHE_DIR" -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null | awk '{n++;s+=$1} END {print n+0,s+0}')
      free=$(df -B1 "$CACHE_MNT" | awk 'NR==2{print $4}')
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$hit" "$miss" "$cachebytes" "$rawb" "$rawbytes" "$writing" "$files" "$filebytes" "$free" "$evict" "$drop" >>"$out"
    sleep 1
  done
}
graceful_umount() {
  local process_file
  process_file=${ACTIVE_PROCESS_FILE:-}
  [[ -n $process_file && -r $process_file ]] || die active_mount_process_evidence_missing
  log_command "$JFS" umount "$MNT"
  "$JFS" umount "$MNT" >"$CELL_ROOT/umount.stdout" 2>"$CELL_ROOT/umount.stderr" || die graceful_umount_failed
  for _ in 1 2 3 4 5 6 7 8 9 10; do mountpoint -q "$MNT" || break; sleep 1; done
  mountpoint -q "$MNT" && die mount_still_present
  for _ in 1 2 3 4 5 6 7 8 9 10; do jfs_gone "$process_file" && break; sleep 1; done
  jfs_gone "$process_file" || die mount_process_still_alive
  grep -Eiq 'assert|panic|fatal' "$CELL_ROOT"/juicefs-*.log 2>/dev/null && die worker_log_failure || true
  rmdir "$MNT" || die mount_directory_not_empty
}
a0_mount_gate() {
  [[ $KIND == A0 ]] || return 0
  [[ -x $NSB_GATE ]] || die nsb_gate_missing
  local attempt round label round_root rc=1
  for attempt in 1 2 3; do
    label="${CELL_ROOT##*/}-mount-$attempt"
    for round in 1 2; do
      round_root=$CELL_ROOT/probe-rounds/$label/mseqread-$label-r$round
      mkdir -m 0700 -p "$round_root"
      timeout 5 cat "$MNT/.stats" >"$round_root/jfs-stats-pre.txt" || die a0_stats_pre
      fio --name=mseqread --directory="$MNT/test_dir/mseqread" --filename_format='mseqread.$jobnum.0' \
        --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting \
        --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=180 \
        --allow_file_create=0 --output-format=json --output="$round_root/fio.json" || die a0_probe_fio
      timeout 5 cat "$MNT/.stats" >"$round_root/jfs-stats-post.txt" || die a0_stats_post
    done
    set +e
    bash "$NSB_GATE" "$CELL_ROOT/probe-rounds" "$label" mseqread >"$CELL_ROOT/probe-gate-$attempt.txt" 2>&1
    rc=$?
    set -e
    (( rc == 0 )) && return 0
    (( attempt < 3 )) || break
    graceful_umount
    mount_jfs "retry-$((attempt+1))"
  done
  die a0_mount_gate_failed_after_3_attempts
}
asset_identity() {
  local base=$1 out=$2
  find "$base/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$out"
  [[ $(wc -l <"$out") -eq 128 ]] || die asset_identity_count
  awk -F '\t' '$3 != 1073741824 {bad=1} END {exit bad}' "$out" || die asset_identity_size
}
run_cell() {
  local label=$1
  local drain_rc=0
  cell_spec
  mkdir -m 0700 -p "$CELL_ROOT"
  record "$label" START
  incident "$label" START
  health_gate paused "$CELL_ROOT/health-pre"
  prepare_cache
  asset_identity "$REF" "$CELL_ROOT/assets-pre.tsv"
  mount_jfs warmup
  a0_mount_gate
  sample_sidecar pre
  cache_inode_snapshot pre
  run_fio warmup randread || die fio_warmup
  local stop sampler_pid fio_rc sampler_rc
  stop=$CELL_ROOT/sampler.stop
  runtime_sampler "$stop" "$CELL_ROOT/runtime.tsv" >"$CELL_ROOT/sampler.stdout" 2>"$CELL_ROOT/sampler.stderr" &
  sampler_pid=$!
  if run_fio formal randrw; then fio_rc=0; else fio_rc=$?; fi
  : >"$stop"
  if wait "$sampler_pid"; then sampler_rc=0; else sampler_rc=$?; fi
  printf '%s\n' "$fio_rc" >"$CELL_ROOT/fio.rc"
  printf '%s\n' "$sampler_rc" >"$CELL_ROOT/sampler.rc"
  (( fio_rc == 0 && sampler_rc == 0 )) || die formal_or_sampler_failed
  sample_sidecar formal-end
  cache_inode_snapshot formal-end
  printf 'READ_WRITE_DIRECTIONAL_LOGS\n' >"$CELL_ROOT/formal-directions.txt"
  asset_identity "$MNT" "$CELL_ROOT/assets-post.tsv"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post.tsv" || die asset_identity_drift
  sample_sidecar post
  if (( WB )); then
    if drain_writeback "$CELL_ROOT/drain.tsv"; then
      drain_rc=0
    else
      drain_rc=$?
    fi
    printf '%s\n' "$drain_rc" >"$CELL_ROOT/drain.rc"
    (( drain_rc == 0 )) || { incident "$label" drain_timeout; die drain_timeout_preserve; }
  fi
  cache_inode_snapshot post-drain
  graceful_umount
  if [[ $KIND != A0 ]]; then
    cleanup_cache
  fi
  state_return
  record "$label" PASS
  incident "$label" PASS
  : >"$CELL_ROOT/PASS"
}
drain_writeback() {
  local out=$1 prefix=${2:-} start now blocks bytes writing files zero_streak=0
  start=$(date +%s)
  printf 'epoch_s\tstaging_blocks\tstaging_block_bytes\tstaging_writing_blocks\tstaging_files\tstaging_file_bytes\n' >"$out"
  while :; do
    now=$(date +%s)
    metrics=$(curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics") || die staging_metrics
    blocks=$(metric_text "$metrics" juicefs_staging_blocks)
    bytes=$(metric_text "$metrics" juicefs_staging_block_bytes)
    writing=$(metric_text "$metrics" juicefs_staging_writing_blocks)
    [[ $blocks =~ ^[0-9]+$ && $bytes =~ ^[0-9]+$ && $writing =~ ^[0-9]+$ ]] || die staging_metric_missing
    read -r files bytes_fs < <(find "$CACHE_DIR" -xdev -type f -path '*/rawstaging/*' -printf '%s\n' 2>/dev/null | awk '{n++; s+=$1} END {print n+0, s+0}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$blocks" "$bytes" "$writing" "$files" "$bytes_fs" >>"$out"
    if [[ $blocks == 0 && $bytes == 0 && $writing == 0 && $files == 0 && $bytes_fs == 0 ]]; then
      zero_streak=$((zero_streak+1))
    else
      zero_streak=0
    fi
    if (( zero_streak >= 2 )); then
      printf '%s\n' "$((now-start))" >"$CELL_ROOT/${prefix}drain-seconds.txt"
      date +%s%N >"$CELL_ROOT/${prefix}strict-drain-end-ns.txt"
      printf 'STRICT_ZERO\n' >"$CELL_ROOT/${prefix}drain-status.txt"
      return 0
    fi
    (( now-start < 900 )) || { printf 'TIMEOUT\n' >"$CELL_ROOT/${prefix}drain-status.txt"; return 3; }
    if (( zero_streak == 1 )); then sleep 10; else sleep 1; fi
  done
}
need_supplement() {
  local base=$1 decision=ADD margin=$M_ONLINE
  [[ ! -s $ROOT/m-online.txt ]] || margin=$(<"$ROOT/m-online.txt")
  [[ -s $ROOT/summary.tsv ]] || { printf '%s\n' "$decision"; return; }
  decision=$(python3 - "$ROOT/summary.tsv" "$base" "$margin" <<'PY'
import csv,sys
rows={}
for r in csv.DictReader(open(sys.argv[1]), delimiter='\t'):
    if r["cell"].startswith(sys.argv[2]+"-"):
        rows[r["cell"].split("-",1)[1]] = (float(r["read_mib_s"]), float(r["write_mib_s"]))
m=float(sys.argv[3]); names=["R","W","P50"]
if any(n not in rows for n in names):
    print("ADD"); raise SystemExit
for n in names:
    ok=True
    for q in names:
        if n==q: continue
        dr=rows[n][0]/rows[q][0]-1.0; dw=rows[n][1]/rows[q][1]-1.0
        if min(dr,dw) < -m or max(dr,dw) < m: ok=False
        sr=0.70*rows[n][0]/rows[q][0]-1.0; sw=0.70*rows[n][1]/rows[q][1]-1.0
        if min(sr,sw) < -m or max(sr,sw) < m: ok=False
    if ok:
        print("SKIP"); break
else: print("ADD")
PY
)
  printf '%s\n' "$decision"
}
a0_mid_guard() {
  [[ -s $ROOT/summary.tsv ]] || return 0
  python3 - "$ROOT/summary.tsv" "$ROOT/m-online.txt" <<'PY'
import csv,sys
r={x["cell"]:(float(x["read_mib_s"]),float(x["write_mib_s"]),float(x["mean_direction_mib_s"])) for x in csv.DictReader(open(sys.argv[1]),delimiter="\t")}
if "A0-pre" in r and "A0-mid" in r:
    drift=max(abs(r["A0-mid"][i]/r["A0-pre"][i]-1.0) for i in (0,1,2))
    open(sys.argv[2],"w").write("%.9f\n"%max(0.08,drift))
    if drift > 0.08: raise SystemExit("A0-mid drift >8%")
PY
}
static_identity() {
  [[ -x $JFS && ! -L $JFS ]] || die jfs_missing
  [[ $(md5sum "$JFS" | awk '{print $1}') == 24fae0852051c80ca571cb2f20275d46 ]] || die jfs_identity
  [[ -r $ROOT/inventory/ceph.conf && ! -L $ROOT/inventory/ceph.conf ]] || die private_ceph_conf_missing
  [[ $(md5sum "$ROOT/inventory/ceph.conf" | awk '{print $1}') == 86351c58848c7e4caaa1bbeccb211730 ]] || die private_ceph_conf_identity
}
health_gate() {
  local mode=$1 out=$2 status checks
  mkdir -m 0700 -p "$out"
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph -s -f json >"$out/ceph-status.json" || die ceph_status
  status=$(python3 - "$out/ceph-status.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("health",{}).get("status","MISSING"))
PY
)
  checks=$(python3 - "$out/ceph-status.json" <<'PY'
import json,sys
print(",".join(sorted(json.load(open(sys.argv[1])).get("health",{}).get("checks",{}))))
PY
)
  if [[ $mode == paused ]]; then
    [[ $status == HEALTH_OK || ( $status == HEALTH_WARN && $checks == OSDMAP_FLAGS ) ]] || die paused_health
  else
    [[ $status == HEALTH_OK && -z $checks ]] || die unpaused_health
  fi
  python3 - "$out/ceph-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pg=d.get("pgmap",{}).get("pgs_by_state",[])
if not pg or any(x.get("state_name")!="active+clean" for x in pg):
    raise SystemExit("PG state is not active+clean")
o=d.get("osdmap",{}); total=o.get("num_osds",0)
if total and (o.get("num_up_osds")!=total or o.get("num_in_osds")!=total):
    raise SystemExit("OSD is not fully up/in")
PY
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  grep -q 'JuiceFS:juicefs-prod' "$out/reference-mount.tsv" || die reference_drift
}
pause_scrub() {
  [[ -x $SCRUB ]] || die scrub_controller_missing
  SCRUB_SESSION_DIR=$ROOT/scrub-sessions/$(date +%s%N)
  mkdir -m 0700 -p "$SCRUB_SESSION_DIR"
  printf '%s\t%s\n' "$(date +%s%N)" "$SCRUB_SESSION_DIR" >>"$ROOT/scrub-sessions.tsv"
  [[ -r $ROOT/inventory/fsid.txt ]] || env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph fsid >"$ROOT/inventory/fsid.txt"
  env U141D_SCRUB_STATE_DIR="$SCRUB_SESSION_DIR" U141D_CEPH_CONF="$ROOT/inventory/ceph.conf" bash "$SCRUB" pause "$RUN_ID-phase-b" "$(<"$ROOT/inventory/fsid.txt")" I_ACK_GLOBAL_CEPH_SCRUB_PAUSE
  SCRUB_ACTIVE=1
  env U141D_SCRUB_STATE_DIR="$SCRUB_SESSION_DIR" U141D_CEPH_CONF="$ROOT/inventory/ceph.conf" bash "$SCRUB" verify-paused "$RUN_ID-phase-b" >"$SCRUB_SESSION_DIR/verify-paused.txt"
}
restore_scrub() {
  [[ ${SCRUB_ACTIVE:-0} == 1 ]] || return 0
  [[ -n ${SCRUB_SESSION_DIR:-} && -d $SCRUB_SESSION_DIR ]] || return 1
  env U141D_SCRUB_STATE_DIR="$SCRUB_SESSION_DIR" U141D_CEPH_CONF="$ROOT/inventory/ceph.conf" bash "$SCRUB" restore "$RUN_ID-phase-b" >"$SCRUB_SESSION_DIR/restore.txt" || return 1
  env U141D_SCRUB_STATE_DIR="$SCRUB_SESSION_DIR" U141D_CEPH_CONF="$ROOT/inventory/ceph.conf" bash "$SCRUB" verify-restored "$RUN_ID-phase-b" >"$SCRUB_SESSION_DIR/verify-restored.txt" || return 1
  SCRUB_ACTIVE=0
}
on_exit() {
  local rc=$?
  if [[ ${SCRUB_ACTIVE:-0} == 1 ]]; then restore_scrub || printf 'SCRUB_RESTORE_FAIL\n' >"$ROOT/INCIDENT-SCRUB-RESTORE"
  fi
  return "$rc"
}
prepare_cache() {
  [[ $KIND != A0 ]] || return 0
  BACKING_ROOT=/mnt/jfs-cache/jfs-04tmp2h-$RUN_ID
  CACHE_MNT=/tmp/jfs-04tmp2h-cache-$RUN_ID-$CELL
  BACKING=$BACKING_ROOT/$CELL.img
  CACHE_DIR=$CACHE_MNT/cache
  local parent_avail
  [[ $BACKING_ROOT == /mnt/jfs-cache/jfs-04tmp2h-$RUN_ID &&
     $CACHE_MNT == /tmp/jfs-04tmp2h-cache-$RUN_ID-$CELL &&
     $BACKING == /mnt/jfs-cache/jfs-04tmp2h-$RUN_ID/$CELL.img &&
     $BACKING_ROOT != / && $CACHE_MNT != / && ! -L $BACKING_ROOT && ! -L $CACHE_MNT ]] || die unsafe_cache_path
  [[ ! -e $BACKING_ROOT && ! -e $CACHE_MNT ]] || die cache_path_exists
  parent_avail=$(df -B1 "$CACHE_PARENT" | awk 'NR==2{print $4}')
  [[ $parent_avail -ge $(( (SIZE+64) * 1024 * 1024 * 1024 )) ]] || die capacity_free_gate
  mkdir -m 0700 -p "$ROOT/backing" "$ROOT/cache-mount"
  log_command sudo install -d -m 0700 -o 1002 -g 1002 "$BACKING_ROOT"
  sudo install -d -m 0700 -o 1002 -g 1002 "$BACKING_ROOT"
  [[ $(stat -Lc %u "$BACKING_ROOT") -eq 1002 && $(stat -Lc %g "$BACKING_ROOT") -eq 1002 && $(stat -Lc %a "$BACKING_ROOT") == 700 ]] || die backing_root_identity
  [[ ! -e $BACKING && ! -L $BACKING ]] || die backing_exists
  log_command fallocate -l "$SIZE"G -- "$BACKING"
  fallocate -l "$SIZE"G "$BACKING"
  log_command sudo losetup --find --show --nooverlap "$BACKING"
  sudo losetup --find --show --nooverlap "$BACKING" >"$CELL_ROOT/loop.txt"
  LOOP=$(<"$CELL_ROOT/loop.txt")
  [[ $LOOP =~ ^/dev/loop[0-9]+$ ]] || die invalid_loop_device
  verify_loop_identity
  log_command sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$LOOP"
  sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$LOOP" >"$CELL_ROOT/mkfs.txt"
  mkdir -m 0700 -p "$CACHE_MNT"
  log_command sudo mount -o noatime,nodiscard "$LOOP" "$CACHE_MNT"
  sudo mount -o noatime,nodiscard "$LOOP" "$CACHE_MNT"
  log_command sudo chown 1002:1002 "$CACHE_MNT"
  sudo chown 1002:1002 "$CACHE_MNT"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$LOOP" ]] || die cache_mount_identity
  findmnt -rn -M "$CACHE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,UUID >"$CELL_ROOT/cache-findmnt.tsv"
  df -B1 "$CACHE_MNT" >"$CELL_ROOT/cache-df.tsv"
  mkdir -m 0700 "$CACHE_DIR"
  [[ ! -L $CACHE_DIR && $(stat -Lc %u "$CACHE_DIR") -eq 1002 && $(stat -Lc %g "$CACHE_DIR") -eq 1002 && $(stat -Lc %a "$CACHE_DIR") == 700 ]] || die cache_dir_identity
  AVAIL_MIB=$(df -B1 "$CACHE_MNT" | awk 'NR==2{printf "%d", $4/1048576}')
  case $KIND in R) CACHE_MIB=$AVAIL_MIB;; W) CACHE_MIB=1;; P25) CACHE_MIB=$((AVAIL_MIB*25/100));; P50) CACHE_MIB=$((AVAIL_MIB*50/100));; P75) CACHE_MIB=$((AVAIL_MIB*75/100));; esac
  printf 'loop\t%s\nbacking\t%s\ncache_mount\t%s\ncache_dir\t%s\n' "$LOOP" "$BACKING" "$CACHE_MNT" "$CACHE_DIR" >"$CELL_ROOT/storage.tsv"
  printf 'available_mib\t%s\ncache_mib\t%s\nmetrics_addr\t%s\n' "$AVAIL_MIB" "$CACHE_MIB" "$METRICS_ADDR" >>"$CELL_ROOT/storage.tsv"
}
cleanup_cache() {
  [[ $KIND != A0 ]] || return 0
  mountpoint -q "$MNT" && die cleanup_jfs_still_mounted
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$LOOP" ]] || die cleanup_loop_source
  verify_loop_identity
  log_command sudo umount "$CACHE_MNT"
  sudo umount "$CACHE_MNT"
  log_command sudo losetup -d "$LOOP"
  sudo losetup -d "$LOOP"
  [[ -z $(losetup -j "$BACKING") ]] || die loop_remains
  printf 'LOOP_DETACHED_AND_RECHECKED\n' >"$CELL_ROOT/loop-recheck"
  rmdir "$CACHE_MNT" || die cache_mount_dir_not_empty
  unlink -- "$BACKING"
  log_command sudo rmdir "$BACKING_ROOT"
  sudo rmdir "$BACKING_ROOT" || die backing_root_not_empty
  printf 'CACHE_CLEANED\n' >"$CELL_ROOT/cache-cleanup"
}
verify_loop_identity() {
  local expected actual found
  expected=$(realpath -e "$BACKING") || die backing_realpath
  found=$(losetup -j "$BACKING" | awk -F: 'NF{print $1}')
  [[ $found == "$LOOP" ]] || die loop_identity_mismatch
  actual=$(loop_backing "$LOOP") || die loop_backing_unavailable
  [[ $actual == "$expected" ]] || die loop_backing_mismatch
}
compact_snapshot() {
  local now=$1 osd
  printf 'osd\trunning\tqueue\tkv_sync_lat_seconds\n' >"$CELL_ROOT/compact-status-$now.tsv"
  while read -r osd; do
    sudo ceph -c "$ROOT/inventory/ceph.conf" --keyring /etc/ceph/ceph.client.admin.keyring \
      -n client.admin tell osd.$osd perf dump >"$CELL_ROOT/perf-$now-$osd.json" || die compact_perf
    python3 - "$osd" "$CELL_ROOT/perf-$now-$osd.json" >>"$CELL_ROOT/compact-status-$now.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[2])); found={}
def walk(x):
    if isinstance(x,dict):
        for k,v in x.items():
            if k in ('compact_running','compact_queue_len') and isinstance(v,(int,float)): found[k]=v
            if k == 'kv_sync_lat' and isinstance(v,dict) and isinstance(v.get('avgtime'),(int,float)):
                found[k]=v['avgtime']
            walk(v)
    elif isinstance(x,list):
        for v in x: walk(v)
walk(d)
print("%s\t%s\t%s\t%s"%(sys.argv[1],found.get('compact_running','NA'),
      found.get('compact_queue_len','NA'),found.get('kv_sync_lat','NA')))
PY
  done <"$ROOT/inventory/osd-ids.txt"
}
pool_counts() {
  local json=$1
  python3 - "$json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); o=s=0; found=0
for p in d.get("pools",[]):
  if p.get("name") != "juicefs-data": continue
  found += 1
  st=p.get("stats",{})
  o += st.get("objects",0) or 0
  s += st.get("stored",0) or 0
if found != 1: raise SystemExit("juicefs-data pool missing or duplicated")
print("%s\t%s"%(o,s))
PY
}
initialize_seed() {
  local saved_cell_root=${CELL_ROOT:-} osd start now quiet=0 previous_objects=NA objects stored
  CELL_ROOT=$ROOT/initialization
  mkdir -m 0700 -p "$CELL_ROOT"
  printf 'env JFS_GC_SKIPPEDTIME=0 CEPH_CONF=%q %q gc --compact --delete --threads 32 %q\n' \
    "$ROOT/inventory/ceph.conf" "$JFS" "$META" >>"$ROOT/commands.sh"
  env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$ROOT/inventory/ceph.conf" \
    "$JFS" gc --compact --delete --threads 32 "$META" >"$CELL_ROOT/gc.txt" || die initial_gc
  while read -r osd; do
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s compact\n' "$ROOT/inventory/ceph.conf" "$osd" >>"$ROOT/commands.sh"
    sudo ceph -c "$ROOT/inventory/ceph.conf" --keyring /etc/ceph/ceph.client.admin.keyring \
      -n client.admin tell osd.$osd compact >>"$CELL_ROOT/compact.txt" || die initial_compact
  done <"$ROOT/inventory/osd-ids.txt"
  printf 'epoch_s\tobjects\tstored\n' >"$CELL_ROOT/pool-series.tsv"
  start=$(date +%s)
  while :; do
    now=$(date +%s)
    compact_snapshot "$now"
    ceph -c "$ROOT/inventory/ceph.conf" df -f json >"$CELL_ROOT/pool-$now.json" || die initial_pool_poll
    read -r objects stored < <(pool_counts "$CELL_ROOT/pool-$now.json")
    printf '%s\t%s\t%s\n' "$now" "$objects" "$stored" >>"$CELL_ROOT/pool-series.tsv"
    if [[ $objects == "$previous_objects" && $(awk 'NR>1 && $2==0 && $3==0 && $4!="NA" && $4+0<0.002 {n++} END {print n+0}' "$CELL_ROOT/compact-status-$now.tsv") -eq 6 ]]; then
      quiet=$((quiet+1))
    else
      quiet=0
    fi
    previous_objects=$objects
    (( quiet >= 3 )) && break
    (( now-start < 1800 )) || die initial_state_timeout
    sleep 10
  done
  cp -- "$CELL_ROOT/pool-$now.json" "$ROOT/inventory/seed-pool.json"
  printf 'objects\t%s\nstored\t%s\n' "$objects" "$stored" >"$ROOT/inventory/seed-pool.tsv"
  asset_identity "$REF" "$ROOT/inventory/assets-core.tsv"
  printf 'INITIAL_SEED_PASS\n' >"$CELL_ROOT/PASS"
  CELL_ROOT=$saved_cell_root
}
state_return() {
  local osd start now quiet seed_objects seed_stored poll_objects poll_stored object_ok now_objects now_stored
  printf 'env JFS_GC_SKIPPEDTIME=0 CEPH_CONF=%q %q gc --compact --delete --threads 32 %q\n' "$ROOT/inventory/ceph.conf" "$JFS" "$META" >>"$CELL_ROOT/commands.sh"
  ceph -c "$ROOT/inventory/ceph.conf" df -f json >"$CELL_ROOT/objects-before.json" || die objects_before
  env JFS_GC_SKIPPEDTIME=0 CEPH_CONF="$ROOT/inventory/ceph.conf" "$JFS" gc --compact --delete --threads 32 "$META" >"$CELL_ROOT/gc.txt"
  while read -r osd; do
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s compact\n' "$ROOT/inventory/ceph.conf" "$osd" >>"$CELL_ROOT/commands.sh"
    sudo ceph -c "$ROOT/inventory/ceph.conf" --keyring /etc/ceph/ceph.client.admin.keyring \
      -n client.admin tell osd.$osd compact >>"$CELL_ROOT/compact.txt"
  done <"$ROOT/inventory/osd-ids.txt"
  printf 'epoch_s\tobjects\tstored\n' >"$CELL_ROOT/pool-return-series.tsv"
  : >"$CELL_ROOT/tikv-return-series.txt"
  seed_objects=$(awk -F '\t' '$1=="objects"{print $2}' "$ROOT/inventory/seed-pool.tsv")
  seed_stored=$(awk -F '\t' '$1=="stored"{print $2}' "$ROOT/inventory/seed-pool.tsv")
  [[ $seed_objects =~ ^[0-9]+([.][0-9]+)?$ ]] || die seed_object_count_missing
  start=$(date +%s); quiet=0
  while :; do
    now=$(date +%s)
    compact_snapshot "$now"
    ceph -c "$ROOT/inventory/ceph.conf" df -f json >"$CELL_ROOT/pool-$now.json" || die pool_poll
    read -r poll_objects poll_stored < <(pool_counts "$CELL_ROOT/pool-$now.json")
    printf '%s\t%s\t%s\n' "$now" "$poll_objects" "$poll_stored" >>"$CELL_ROOT/pool-return-series.tsv"
    if awk -v a="$seed_objects" -v b="$poll_objects" 'BEGIN{d=a-b;if(d<0)d=-d;exit(d>8192)}'; then object_ok=1; else object_ok=0; fi
    for host in 10.20.1.150 10.20.1.151 10.20.1.152; do
      printf '===== %s %s =====\n' "$now" "$host" >>"$CELL_ROOT/tikv-return-series.txt"
      curl -fsS --connect-timeout 3 --max-time 5 "http://$host:20180/metrics" | grep -E 'pending_compaction|compaction_pending' >>"$CELL_ROOT/tikv-return-series.txt" || true
    done
    if [[ $object_ok == 1 && $(awk 'NR>1 && $2==0 && $3==0 && $4!="NA" && $4+0<0.002 {n++} END {print n+0}' "$CELL_ROOT/compact-status-$now.tsv") -eq 6 ]]; then quiet=$((quiet+1)); else quiet=0; fi
    if (( quiet >= 3 )); then
      ceph -c "$ROOT/inventory/ceph.conf" df -f json >"$CELL_ROOT/objects-after.json" || die objects_after
      read -r now_objects now_stored < <(pool_counts "$CELL_ROOT/objects-after.json")
      [[ $seed_objects =~ ^[0-9]+([.][0-9]+)?$ && $now_objects =~ ^[0-9]+([.][0-9]+)?$ ]] || die pool_object_count_missing
      awk -v a="$seed_objects" -v b="$now_objects" 'BEGIN{d=a-b;if(d<0)d=-d;exit(d>8192)}' || die pool_objects_seed_drift
      asset_identity "$REF" "$CELL_ROOT/assets-return.tsv"
      cmp -s "$ROOT/inventory/assets-core.tsv" "$CELL_ROOT/assets-return.tsv" || die assets_state_return_drift
      printf 'seed_objects\t%s\nfinal_objects\t%s\nseed_stored\t%s\nfinal_stored\t%s\n' "$seed_objects" "$now_objects" "$seed_stored" "$now_stored" >"$CELL_ROOT/pool-return.tsv"
      printf '%s\n' "$((now-start))" >"$CELL_ROOT/state-return-seconds"
      return 0
    fi
    (( now-start < 1800 )) || die state_return_timeout
    sleep 10
  done
}
append_summary() {
  local token=$1 json=$CELL_ROOT/online-summary.json
  [[ -x $ANALYZER ]] || die analyzer_missing
  python3 "$ANALYZER" cell-summary --cell "$CELL_ROOT" --output "$json" >/dev/null || die online_summary_failed
  [[ -e $ROOT/summary.tsv ]] || printf 'cell\tread_mib_s\twrite_mib_s\tmean_direction_mib_s\n' >"$ROOT/summary.tsv"
  python3 - "$token" "$json" >>"$ROOT/summary.tsv" <<'PY'
import json,sys
d=json.load(open(sys.argv[2]))
print("%s\t%.6f\t%.6f\t%.6f"%(sys.argv[1],d["read_mib_s"],d["write_mib_s"],d["mean_direction_mib_s"]))
PY
}
run_token() {
  local token=$1 base kind
  if [[ $token == A0-* ]]; then
    CELL=$token; REQUEST_KIND=R
  else
    base=${token%-*}; kind=${token#*-}
    CELL=$base; REQUEST_KIND=$kind
  fi
  cell_spec
  if [[ -f $CELL_ROOT/PASS ]]; then
    if ! awk -F '\t' -v c="$token" 'NR>1 && $1==c{found=1} END{exit !found}' "$ROOT/summary.tsv" 2>/dev/null; then
      append_summary "$token"
    fi
    printf '%s\tSKIP_ALREADY_PASS\n' "$token" >>"$ROOT/run-state.tsv"
    return 0
  fi
  if [[ -f $CELL_ROOT/RECOVERY-CLOSED ]]; then
    if ! awk -F '\t' -v c="$token" 'NR>1 && $1==c{found=1} END{exit !found}' "$ROOT/summary.tsv" 2>/dev/null; then
      append_summary "$token"
    fi
    printf '%s\tSKIP_RECOVERY_CLOSED_UNSAFE\n' "$token" >>"$ROOT/run-state.tsv"
    return 0
  fi
  [[ ! -e $CELL_ROOT ]] || die "incomplete_cell_requires_explicit_recovery:$token"
  run_cell "$token"
  append_summary "$token"
  printf '%s\tPASS\n' "$token" >>"$ROOT/run-state.tsv"
}
execute_all() {
  valid_run
  [[ ${TMP2H_ACK:-} == I_ACK_04TMP2H_$RUN_ID ]] || die ack_missing
  [[ -f $ROOT/plans/PASS ]] || die plan_missing
  [[ ! -f $ROOT/PASS ]] || die run_already_complete
  static_identity
  if pgrep -a -x fio >"$ROOT/foreign-fio-execute.tsv" 2>&1; then die foreign_fio; fi
  mkdir -m 0700 -p "$ROOT"
  touch "$ROOT/commands.sh"
  sha256sum "$0" "$ANALYZER" "$SCRIPT_DIR/t04tmp2h-randrw-gate0-offline.sh" "$SCRUB" "$NSB_GATE" >"$ROOT/runtime-scripts.sha256"
  trap on_exit EXIT
  pause_scrub
  health_gate paused "$ROOT/health-pre"
  [[ -f $ROOT/initialization/PASS ]] || initialize_seed
  local token base kind supp resolution_stop=0
  while IFS= read -r token; do
    [[ -n $token ]] || continue
    run_token "$token"
    if [[ $token == T32-P50 || $token == T64-P50 || $token == T96-P50 || $token == T128-P50 || $token == T256-P50 ]]; then
      base=${token%-*}
      supp=$(need_supplement "$base")
      printf '%s\t%s\n' "$base" "$supp" >>"$ROOT/supplement-decisions.tsv"
      if [[ $supp == ADD ]]; then
        if [[ $base == T128 || $base == T256 ]]; then
          for kind in P75 P25; do CELL=$base; REQUEST_KIND=$kind; cell_spec; run_token "$base-$kind"; done
        else
          for kind in P25 P75; do CELL=$base; REQUEST_KIND=$kind; cell_spec; run_token "$base-$kind"; done
        fi
      fi
    fi
    if [[ $token == A0-mid ]] && ! a0_mid_guard; then
      incident "$token" A0_MID_DRIFT
      printf 'A0_MID_DRIFT_STOP\n' >"$ROOT/RESOLUTION-STOP-A0-MID"
      resolution_stop=1
      break
    fi
  done < <(matrix)
  restore_scrub || die scrub_restore_failed
  trap - EXIT
  health_gate unpaused "$ROOT/health-final"
  if (( resolution_stop )); then
    printf 'EXECUTE_RESOLUTION_INSUFFICIENT\n' >"$ROOT/PASS"
  else
    printf 'EXECUTE_PASS\n' >"$ROOT/PASS"
  fi
}
resume_postfio() {
  valid_run
  [[ ${TMP2H_ACK:-} == I_ACK_04TMP2H_$RUN_ID ]] || die ack_missing
  local token=$CELL
  if [[ $token == T32-* || $token == T64-* || $token == T96-* || $token == T128-* || $token == T256-* ]]; then
    REQUEST_KIND=${token#*-}; CELL=${token%-*}
  else
    REQUEST_KIND=W
  fi
  [[ $CELL == T32 || $CELL == T64 || $CELL == T96 || $CELL == T128 || $CELL == T256 ]] || die invalid_resume_cell
  cell_spec
  [[ -d $CELL_ROOT && -r $CELL_ROOT/drain-status.txt ]] || die resume_evidence_missing
  [[ $(<"$CELL_ROOT/drain-status.txt") == TIMEOUT ]] || die resume_not_timeout
  [[ -r $CELL_ROOT/storage.tsv ]] || die resume_storage_missing
  BACKING=$(awk -F '\t' '$1=="backing"{print $2}' "$CELL_ROOT/storage.tsv")
  CACHE_MNT=$(awk -F '\t' '$1=="cache_mount"{print $2}' "$CELL_ROOT/storage.tsv")
  CACHE_DIR=$(awk -F '\t' '$1=="cache_dir"{print $2}' "$CELL_ROOT/storage.tsv")
  LOOP=$(awk -F '\t' '$1=="loop"{print $2}' "$CELL_ROOT/storage.tsv")
  CACHE_MIB=$(awk -F '\t' '$1=="cache_mib"{print $2}' "$CELL_ROOT/storage.tsv")
  METRICS_ADDR=$(awk -F '\t' '$1=="metrics_addr"{print $2}' "$CELL_ROOT/storage.tsv")
  ACTIVE_PROCESS_FILE=$(awk -F '\t' '$1=="active_process_file"{v=$2} END{print v}' "$CELL_ROOT/state.tsv")
  [[ $BACKING == /mnt/jfs-cache/jfs-04tmp2h-$RUN_ID/$CELL.img && $CACHE_MNT == /tmp/jfs-04tmp2h-cache-$RUN_ID-$CELL ]] || die resume_storage_path
  static_identity
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$LOOP" ]] || die resume_cache_mount_identity
  verify_loop_identity
  trap on_exit EXIT
  pause_scrub
  health_gate paused "$CELL_ROOT/health-resume"
  if mountpoint -q "$MNT"; then
    [[ -r $ACTIVE_PROCESS_FILE ]] || die resume_active_process_evidence
    curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/resume-metrics.prom" || die resume_metrics
  else
    mount_jfs recovery
  fi
  drain_writeback "$CELL_ROOT/recovery-drain.tsv" recovery- || die recovery_drain_failed
  asset_identity "$MNT" "$CELL_ROOT/remount-assets.tsv"
  graceful_umount
  cleanup_cache
  state_return
  append_summary "$token"
  : >"$CELL_ROOT/RECOVERY-CLOSED"
  printf '%s\tRECOVERY_CLOSED_ORIGINAL_CELL_UNSAFE\n' "$token" >>"$ROOT/run-state.tsv"
  incident "$token" RECOVERY_PASS
  restore_scrub || die scrub_restore_failed
  trap - EXIT
  health_gate unpaused "$CELL_ROOT/health-final"
  printf 'RESUME_POSTFIO_PASS\n' >"$CELL_ROOT/resume-PASS"
}
bundle_run() {
  valid_run
  [[ -d $ROOT ]] || die evidence_root_missing
  mkdir -m 0700 -p "$ROOT/bundle"
  local tarball=$ROOT/bundle/04-tmp2h-$RUN_ID.tar
  local -a files=(inventory plans cells run-state.tsv)
  for f in initialization scrub-sessions health-pre health-final summary.tsv commands.sh incidents.tsv \
    runtime-scripts.sha256 supplement-decisions.tsv m-online.txt scrub-sessions.tsv \
    RESOLUTION-STOP-A0-MID PASS; do
    [[ -e $ROOT/$f ]] && files+=("$f")
  done
  tar --sort=name --mtime='UTC 1970-01-01' -cf "$tarball" -C "$ROOT" "${files[@]}" \
    -C "$SCRIPT_DIR" t04tmp2h-randrw-run.sh t04tmp2h-randrw-analyze.py \
    t04tmp2h-randrw-gate0-offline.sh u141d-scrub-control.sh t39-nsbgate.sh 2>/dev/null || die bundle_failed
  sha256sum "$tarball" >"$tarball.sha256"
  printf 'BUNDLE_PASS\n%s\n%s\n' "$tarball" "$tarball.sha256"
}
set -u
case $MODE in
  offline-self-test) offline_self_test ;;
  inventory-plan) inventory_plan ;;
  execute) execute_all ;;
  resume-postfio) resume_postfio ;;
  bundle) bundle_run ;;
  *) usage; exit 2 ;;
esac
