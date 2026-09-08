#!/usr/bin/env bash
set -euo pipefail
MODE=${1:-}
RUN_ID=${2:-}
CELL=${3:-}
ROOT=/tmp/production/opencode-04tmp2j-$RUN_ID
die() { printf 'E_04TMP2J\t%s\n' "$*" >&2; exit 42; }
incident() { mkdir -m 0700 -p "$ROOT"; printf '%s\t%s\t%s\n' "$(date +%s%N)" "$1" "$2" >>"$ROOT/incidents.tsv"; }
valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-04tmp2j-$RUN_ID && $ROOT != / && ! -L $ROOT ]] || die unsafe_result_root
  if [[ -e $ROOT ]]; then
    [[ -d $ROOT && $(stat -Lc %u "$ROOT") -eq 1002 && $(stat -Lc %g "$ROOT") -eq 1002 && $(stat -Lc %a "$ROOT") == 700 ]] || die result_root_identity
  fi
}
usage() { printf '%s\n' "usage"; }
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
JFS=/tmp/juicefs-1.4.1-patched
REF=/mnt/juicefs
CACHE_PARENT=/mnt/jfs-cache
CACHE_ROOT=$CACHE_PARENT/jfs-04tmp2j-$RUN_ID
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRUB=$SCRIPT_DIR/u141d-scrub-control.sh
ANALYZER=$SCRIPT_DIR/t04tmp2j-randrw-analyze.py
FORMAL_RW=randrw; FORMAL_MIX=50; FORMAL_JOBS=128; FORMAL_RUNTIME=180
FORMAL_SIZE=1G; FORMAL_BS=256K; WARMUP_RUNTIME=180; M_ONLINE=0.08; MARGIN=0.08
METRICS_ADDR=127.0.0.1:9568
readonly META JFS REF CACHE_PARENT FORMAL_RW FORMAL_MIX FORMAL_JOBS FORMAL_RUNTIME FORMAL_SIZE FORMAL_BS WARMUP_RUNTIME
cell_spec() {
  KIND=R; SIZE=0; CACHE_MIB=0; WB=0
  case $CELL in
    A0-pre|A0-mid|A0-post) KIND=A0 ;;
    C32|C64|C96|C128|C256)
      SIZE=${CELL#C}; CACHE_MIB=$((SIZE*1024))
      ;;
    *) die invalid_cell ;;
  esac
  MNT=/tmp/jfs-04tmp2j-$RUN_ID-$CELL
  CELL_ROOT=$ROOT/cells/$CELL
  CACHE_DIR=$CACHE_ROOT/cache-$CELL
}
matrix() {
  cat <<'EOF'
A0-pre
C32
C128
C64
A0-mid
C256
C96
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
  RUN_ID=20000101-000000; ROOT=/tmp/production/opencode-04tmp2j-$RUN_ID
  assert_no_forbidden
  [[ $(matrix | wc -l) -eq 8 ]] || die matrix_count
  [[ $(matrix | grep -Ec '^C(32|64|96|128|256)$') -eq 5 ]] || die capacity_matrix
  grep -q '^A0-pre$' <(matrix) && grep -q '^A0-mid$' <(matrix) && grep -q '^A0-post$' <(matrix) || die anchors
  grep -q -- '--max-fuse-io 256K' "$0" || die mount_contract
  grep -q -- '--max-uploads 150' "$0" || die upload_contract
  grep -q -- '--free-space-ratio 0.20' "$0" || die free_space_contract
  grep -q 'time_based' "$0" || die fio_time_based
  printf '04TMP2J_OFFLINE_SELF_TEST_PASS cells=8 capacities=32,64,96,128,256\n'
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
  # The signed scripts are staged below this RUN root before inventory.  Reuse
  # only that exact scripts-only directory; reject every other pre-existing
  # result so an old or partial run cannot be overwritten.
  if [[ -e $ROOT ]]; then
    [[ -d $ROOT/scripts && ! -L $ROOT/scripts ]] || die result_root_not_scripts_only
    [[ -z $(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name scripts -print -quit) ]] || die result_root_not_scripts_only
  else
    mkdir -p "$ROOT"
  fi
  # /tmp/production is setgid on this host, so normalize the RUN root before
  # creating evidence beneath it.
  chmod 0700 "$ROOT"
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans" "$ROOT/cells"
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
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die cache_parent_not_ext4
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.freeze"
  stat -Lc 'path=%n dev=%d inode=%i mode=%a uid=%u gid=%g type=%F' "$CACHE_PARENT" >"$ROOT/inventory/cache-parent.stat"
  [[ $(df -B1 "$CACHE_PARENT" | awk 'NR==2{print $4}') -ge $((320*1024*1024*1024)) ]] || die cache_free_320g_gate
  find "$REF/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\t%T@\n' | sort -V >"$ROOT/inventory/assets.tsv"
  [[ $(wc -l <"$ROOT/inventory/assets.tsv") -eq 128 ]] || die asset_count
  awk -F '\t' '$3 != 1073741824 {bad=1} END {exit bad}' "$ROOT/inventory/assets.tsv" || die asset_size
  for i in $(seq 0 127); do awk -F '\t' -v n="rw_test.$i.0" '$1==n{found=1} END{exit !found}' "$ROOT/inventory/assets.tsv" || die "asset_name_$i"; done
  cut -f1-3 "$ROOT/inventory/assets.tsv" >"$ROOT/inventory/assets-core.tsv"
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
  if pgrep -a -f '/tmp/jfs-04tmp2j-[0-9]{8}-[0-9]{6}-' >"$ROOT/inventory/tmp2j-processes.tsv" 2>&1; then
    die stale_tmp2j_process
  fi
  [[ ! -e $CACHE_ROOT ]] || die cache_root_exists
  ip -j link >"$ROOT/inventory/nic.json" || die nic_inventory
  find "$REF/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\n' | sort -V >"$ROOT/inventory/asset-manifest.txt"
  matrix >"$ROOT/plans/matrix-order.txt"
  write_sudo_plan
  sha256sum "$0" "$ANALYZER" "$SCRIPT_DIR/t04tmp2i-randrw-analyze.py" \
    "$SCRIPT_DIR/t04tmp2j-randrw-gate0-offline.sh" "$SCRUB" >"$ROOT/plans/scripts.sha256"
  printf 'RUN_ID\t%s\n' "$RUN_ID" >"$ROOT/run-state.tsv"
  printf 'epoch_ns\tcell\tevent\n' >"$ROOT/incidents.tsv"
  printf 'INVENTORY_PLAN_PASS\n' >"$ROOT/plans/PASS"
}
write_sudo_plan() {
  cat >"$ROOT/plans/sudo-contract.txt" <<EOF
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set noscrub
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set nodeep-scrub
sudo install -d -m 0700 -o 1002 -g 1002 /mnt/jfs-cache/jfs-04tmp2j-$RUN_ID
EOF
  local osd
  while read -r osd; do
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s compact\n' "$ROOT/inventory/ceph.conf" "$osd"
    printf 'sudo ceph -c %q --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s perf dump # read-only\n' "$ROOT/inventory/ceph.conf" "$osd"
  done <"$ROOT/inventory/osd-ids.txt" >>"$ROOT/plans/sudo-contract.txt"
  cat >>"$ROOT/plans/sudo-contract.txt" <<EOF
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset nodeep-scrub
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset noscrub
sudo rmdir /mnt/jfs-cache/jfs-04tmp2j-$RUN_ID
EOF
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
  [[ $MNT == /tmp/jfs-04tmp2j-$RUN_ID-$CELL && $MNT != / && ! -L $MNT ]] || die unsafe_mount_path
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
  local stop=$1 out=$2 text hit miss rawb rawbytes cachebytes writing evict drop free value
  local nic devno major minor rx tx diskline rios wios rsec wsec rms wms ioms wioms
  local sampler_pid=$BASHPID next_deadline now_ns sleep_ns epoch_ns free_path start_stat end_stat
  start_stat=$(<"/proc/$sampler_pid/stat")
  printf 'pid\t%s\nstarttime\t%s\nstart_epoch_ns\t%s\n' "$sampler_pid" "$(awk '{print $22}' <<<"$start_stat")" "$(date +%s%N)" >"$CELL_ROOT/sampler-resource.tsv"
  nic=$(ip route get 10.3.1.6 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  devno=$(findmnt -rn -T "$CACHE_PARENT" -o MAJ:MIN)
  IFS=: read -r major minor <<<"$devno"
  [[ -n $nic && $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 42
  printf 'epoch_ns\thit_bytes\tmiss_bytes\tblockcache_bytes\tstaging_blocks\tstaging_bytes\tstaging_writing_blocks\tavailable_bytes\tevicts\tdrops\tnic_rx_bytes\tnic_tx_bytes\tcache_read_ios\tcache_write_ios\tcache_read_sectors\tcache_write_sectors\tcache_read_ms\tcache_write_ms\tcache_io_ms\tcache_weighted_io_ms\n' >"$out"
  next_deadline=$(python3 -c 'import time; print(time.monotonic_ns())')
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
    free_path=/tmp
    [[ $KIND == A0 ]] || free_path=$CACHE_PARENT
    read -r epoch_ns now_ns free < <(python3 - "$free_path" <<'PY'
import os,sys,time
s=os.statvfs(sys.argv[1])
print(time.time_ns(), time.monotonic_ns(), s.f_bavail*s.f_frsize)
PY
    )
    rx=$(<"/sys/class/net/$nic/statistics/rx_bytes")
    tx=$(<"/sys/class/net/$nic/statistics/tx_bytes")
    diskline=$(awk -v a="$major" -v b="$minor" '$1==a&&$2==b{print;exit}' /proc/diskstats)
    read -r _ _ _ rios _ rsec rms wios _ wsec wms _ ioms wioms _ <<<"$diskline"
    [[ -n $rios && -n $wios && -n $rsec && -n $wsec && -n $rms && -n $wms && -n $ioms && -n $wioms ]] || return 42
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$epoch_ns" "$hit" "$miss" "$cachebytes" "$rawb" "$rawbytes" "$writing" "$free" "$evict" "$drop" \
      "$rx" "$tx" "$rios" "$wios" "$rsec" "$wsec" "$rms" "$wms" "$ioms" "$wioms" >>"$out"
    next_deadline=$((next_deadline+1000000000))
    sleep_ns=$((next_deadline-now_ns))
    if (( sleep_ns > 0 )); then
      python3 - "$sleep_ns" <<'PY'
import sys,time
time.sleep(int(sys.argv[1])/1_000_000_000)
PY
    else
      next_deadline=$now_ns
    fi
  done
  end_stat=$(<"/proc/$sampler_pid/stat")
  printf 'end_epoch_ns\t%s\nutime_ticks\t%s\nstime_ticks\t%s\n' "$(date +%s%N)" "$(awk -v a="$(awk '{print $14}' <<<"$start_stat")" '{print $14-a}' <<<"$end_stat")" "$(awk -v a="$(awk '{print $15}' <<<"$start_stat")" '{print $15-a}' <<<"$end_stat")" >>"$CELL_ROOT/sampler-resource.tsv"
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
  sample_sidecar pre
  cache_inode_snapshot pre
  run_fio warmup randread || die fio_warmup
  sample_sidecar warmed
  cache_inode_snapshot warmed
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
  cache_inode_snapshot post-drain
  graceful_umount
  if [[ $KIND != A0 ]]; then
    cleanup_cache
  fi
  state_return
  health_gate paused "$CELL_ROOT/health-post"
  record "$label" PASS
  incident "$label" PASS
  : >"$CELL_ROOT/PASS"
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
  [[ $CACHE_ROOT == /mnt/jfs-cache/jfs-04tmp2j-$RUN_ID &&
     $CACHE_DIR == "$CACHE_ROOT/cache-$CELL" &&
     $CACHE_ROOT != / && $CACHE_DIR != / &&
     ! -L $CACHE_ROOT && ! -L $CACHE_DIR ]] || die unsafe_cache_path
  [[ -d $CACHE_ROOT ]] || die cache_root_missing
  [[ $(stat -Lc %u "$CACHE_ROOT") -eq 1002 &&
     $(stat -Lc %g "$CACHE_ROOT") -eq 1002 &&
     $(stat -Lc %a "$CACHE_ROOT") == 700 ]] || die cache_root_identity
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o SOURCE,MAJ:MIN,FSTYPE,OPTIONS) == $(<"$ROOT/inventory/cache-parent.freeze") ]] ||
    die cache_parent_identity_drift
  [[ -z $(find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_root_not_empty
  local parent_avail
  parent_avail=$(df -B1 "$CACHE_PARENT" | awk 'NR==2{print $4}')
  [[ $parent_avail -ge $((320*1024*1024*1024)) ]] || die cache_capacity_gate
  mkdir -m 0700 "$CACHE_DIR"
  printf 'cache_root\t%s\ncache_dir\t%s\ncache_mib\t%s\nmetrics_addr\t%s\n'     "$CACHE_ROOT" "$CACHE_DIR" "$CACHE_MIB" "$METRICS_ADDR" >"$CELL_ROOT/storage.tsv"
  df -B1 "$CACHE_PARENT" >"$CELL_ROOT/cache-df.tsv"
}
cleanup_cache() {
  [[ $KIND != A0 ]] || return 0
  mountpoint -q "$MNT" && die cleanup_jfs_still_mounted
  [[ $CACHE_DIR == /mnt/jfs-cache/jfs-04tmp2j-$RUN_ID/cache-$CELL &&
     $CACHE_DIR != / && -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die cleanup_path_guard
  [[ -z $(findmnt -rn -M "$CACHE_DIR" -o TARGET 2>/dev/null) ]] || die cache_dir_is_mount
  find "$CACHE_DIR" -xdev -depth -mindepth 1 -delete
  [[ -z $(find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_dir_not_empty
  rmdir "$CACHE_DIR" || die cache_dir_rmdir
  printf 'CACHE_CLEANED\n' >"$CELL_ROOT/cache-cleanup"
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
  local token=$1
  CELL=$token
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
  [[ ${TMP2J_ACK:-} == I_ACK_04TMP2J_$RUN_ID ]] || die ack_missing
  [[ -f $ROOT/plans/PASS ]] || die plan_missing
  [[ ! -f $ROOT/PASS ]] || die run_already_complete
  sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift_after_plan
  static_identity
  if pgrep -a -x fio >"$ROOT/foreign-fio-execute.tsv" 2>&1; then die foreign_fio; fi
  mkdir -m 0700 -p "$ROOT"
  touch "$ROOT/commands.sh"
  sha256sum "$0" "$ANALYZER" "$SCRIPT_DIR/t04tmp2i-randrw-analyze.py" \
    "$SCRIPT_DIR/t04tmp2j-randrw-gate0-offline.sh" "$SCRUB" >"$ROOT/runtime-scripts.sha256"
  trap on_exit EXIT
  pause_scrub
  health_gate paused "$ROOT/health-pre"
  [[ -f $ROOT/initialization/PASS ]] || initialize_seed
  log_command sudo install -d -m 0700 -o 1002 -g 1002 "$CACHE_ROOT"
  sudo install -d -m 0700 -o 1002 -g 1002 "$CACHE_ROOT"
  while read -r token; do run_token "$token"; done < <(matrix)
  restore_scrub || die scrub_restore_failed
  trap - EXIT
  [[ -d $CACHE_ROOT && ! -L $CACHE_ROOT &&
     -z $(find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -print -quit) ]] || die cache_root_not_empty_final
  log_command sudo rmdir "$CACHE_ROOT"
  sudo rmdir "$CACHE_ROOT" || die cache_root_rmdir
  health_gate unpaused "$ROOT/health-final"
  printf 'EXECUTE_PASS\n' >"$ROOT/PASS"
}
bundle_run() {
  valid_run
  [[ -d $ROOT ]] || die evidence_root_missing
  mkdir -m 0700 -p "$ROOT/bundle"
  local tarball=$ROOT/bundle/04-tmp2j-$RUN_ID.tar
  local -a files=(inventory plans cells run-state.tsv)
  for f in initialization scrub-sessions health-pre health-final summary.tsv commands.sh incidents.tsv \
    runtime-scripts.sha256 scrub-sessions.tsv PASS; do
    [[ -e $ROOT/$f ]] && files+=("$f")
  done
  tar --sort=name --mtime='UTC 1970-01-01' -cf "$tarball" -C "$ROOT" "${files[@]}" \
    -C "$SCRIPT_DIR" t04tmp2j-randrw-run.sh t04tmp2j-randrw-analyze.py t04tmp2i-randrw-analyze.py \
    t04tmp2j-randrw-gate0-offline.sh u141d-scrub-control.sh 2>/dev/null || die bundle_failed
  sha256sum "$tarball" >"$tarball.sha256"
  printf 'BUNDLE_PASS\n%s\n%s\n' "$tarball" "$tarball.sha256"
}
set -u
case $MODE in
  offline-self-test) offline_self_test ;;
  inventory-plan) inventory_plan ;;
  execute) execute_all ;;
  bundle) bundle_run ;;
  *) usage; exit 2 ;;
esac
