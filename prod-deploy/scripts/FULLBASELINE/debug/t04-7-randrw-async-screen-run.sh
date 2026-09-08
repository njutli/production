#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

# Reuse the already exercised 04-tmp2i lifecycle primitives.  Only the
# experiment identity, four-cell matrix, shared cache device and mount option
# are overridden below.
SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BASE=$SELF_DIR/t04tmp2i-randrw-run.sh
[[ -f $BASE && ! -L $BASE ]] || { printf 'E_04_7\tbase_runner_missing\n' >&2; exit 42; }
# The base script has one terminal dispatcher beginning at `set -u`.
# shellcheck disable=SC1090
source <(awk '/^set -u$/{exit} {print}' "$BASE")

MODE=${1:-}
RUN_ID=${2:-}
CELL=${3:-}
ROOT=/tmp/production/opencode-04-7-$RUN_ID
ANALYZER=$SELF_DIR/t04-7-randrw-async-screen-analyze.py
GATE=$SELF_DIR/t04-7-randrw-async-screen-gate0-offline.sh
BACKING_ROOT=/mnt/jfs-cache/jfs-04-7-$RUN_ID
BACKING=$BACKING_ROOT/cache-128g.img
SHARED_LOOP_FILE=$ROOT/storage/shared-loop.txt
CACHE_MIB=31978
SIZE=128
WB=1
KIND=P25

die() { printf 'E_04_7\t%s\n' "$*" >&2; exit 42; }
usage() { printf 'usage: %s offline-self-test|inventory-plan|execute|bundle RUN_ID\n' "$0"; }

valid_run() {
  [[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_RUN_ID
  [[ $ROOT == /tmp/production/opencode-04-7-$RUN_ID && $ROOT != / && ! -L $ROOT ]] || die unsafe_result_root
  [[ $BACKING_ROOT == /mnt/jfs-cache/jfs-04-7-$RUN_ID && $BACKING_ROOT != / && ! -L $BACKING_ROOT ]] || die unsafe_backing_root
  [[ $BACKING == /mnt/jfs-cache/jfs-04-7-$RUN_ID/cache-128g.img && $BACKING != / && ! -L $BACKING ]] || die unsafe_backing
  if [[ -e $ROOT ]]; then
    [[ -d $ROOT && $(stat -Lc %u "$ROOT") == 1002 && $(stat -Lc %g "$ROOT") == 1002 && $(stat -Lc %a "$ROOT") == 700 ]] || die result_root_identity
  fi
}

matrix() { printf '%s\n' A1 B1 B2 A2; }

cell_spec() {
  case $CELL in A1|A2) ASYNC=0 ;; B1|B2) ASYNC=1 ;; *) die "invalid_cell:$CELL" ;; esac
  KIND=P25; SIZE=128; CACHE_MIB=31978; WB=1
  MNT=/tmp/jfs-04-7-$RUN_ID-$CELL
  CELL_ROOT=$ROOT/cells/$CELL
  CACHE_MNT=/tmp/jfs-04-7-cache-$RUN_ID-$CELL
  CACHE_DIR=$CACHE_MNT/cache
  [[ $MNT == /tmp/jfs-04-7-$RUN_ID-$CELL && $MNT != / && ! -L $MNT ]] || die unsafe_mount_path
  [[ $CACHE_MNT == /tmp/jfs-04-7-cache-$RUN_ID-$CELL && $CACHE_MNT != / && ! -L $CACHE_MNT ]] || die unsafe_cache_mount
  [[ $CACHE_DIR == /tmp/jfs-04-7-cache-$RUN_ID-$CELL/cache && $CACHE_DIR != / && ! -L $CACHE_DIR ]] || die unsafe_cache_dir
}

record_fuse_contract() {
  local dev minor conn=$CELL_ROOT/fuse-connection.tsv file value
  dev=$(findmnt -rn -M "$MNT" -o MAJ:MIN) || die fuse_device_missing
  minor=${dev#*:}
  [[ $minor =~ ^[0-9]+$ ]] || die fuse_minor_invalid
  printf 'field\tvalue\nmaj_min\t%s\nconnection_id\t%s\n' "$dev" "$minor" >"$conn"
  for file in max_background congestion_threshold waiting; do
    value=UNREADABLE
    [[ -r /sys/fs/fuse/connections/$minor/$file ]] && value=$(<"/sys/fs/fuse/connections/$minor/$file")
    printf '%s\t%s\n' "$file" "$value" >>"$conn"
  done
}

mount_jfs() {
  local tag=$1 i
  local -a cmd
  ! ss -ltnH 2>/dev/null | awk '$4 ~ /:9568$/ {found=1} END {exit found?0:1}' || die metrics_port_busy
  [[ ! -e $MNT ]] || die mount_path_exists
  [[ -d $CACHE_DIR && ! -L $CACHE_DIR ]] || die cache_dir_missing
  mkdir -m 0700 -p "$CELL_ROOT" "$MNT"
  : >"$CELL_ROOT/pids-$tag.txt"
  for i in /proc/[0-9]*; do
    [[ -e $i/exe && $(realpath "$i/exe" 2>/dev/null) == "$JFS" ]] && basename "$i" >>"$CELL_ROOT/pids-$tag.txt" || true
  done
  cmd=("$JFS" mount -d --max-uploads 150 --max-fuse-io 256K --log "$CELL_ROOT/juicefs-$tag.log"
       --cache-dir "$CACHE_DIR" --cache-size "$CACHE_MIB" --free-space-ratio 0.20 --writeback)
  (( ASYNC )) && cmd+=(-o async_dio)
  cmd+=(--metrics "$METRICS_ADDR" "$META" "$MNT")
  printf '%q ' "${cmd[@]}" >"$CELL_ROOT/mount-$tag.argv"; printf '\n' >>"$CELL_ROOT/mount-$tag.argv"
  log_command env "CEPH_CONF=$ROOT/inventory/ceph.conf" "${cmd[@]}"
  CEPH_CONF="$ROOT/inventory/ceph.conf" "${cmd[@]}" >"$CELL_ROOT/mount-$tag.stdout" 2>"$CELL_ROOT/mount-$tag.stderr"
  for i in $(seq 1 120); do mountpoint -q "$MNT" && break; sleep 1; done
  mountpoint -q "$MNT" || die mount_failed
  findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,MAJ:MIN >"$CELL_ROOT/mount-$tag.findmnt.tsv"
  grep -Fq "JuiceFS:juicefs-prod $MNT fuse.juicefs " "$CELL_ROOT/mount-$tag.findmnt.tsv" || die mount_source_identity
  mount_pid_gate "$tag" >"$CELL_ROOT/mount-$tag.process.tsv" || die mount_process_identity
  ACTIVE_PROCESS_FILE=$CELL_ROOT/mount-$tag.process.tsv
  record_fuse_contract
  curl -fsS --max-time 5 "http://$METRICS_ADDR/metrics" >"$CELL_ROOT/metrics-$tag.prom" || die metrics_unavailable
}

shared_loop() {
  [[ -r $SHARED_LOOP_FILE ]] || die shared_loop_state_missing
  LOOP=$(<"$SHARED_LOOP_FILE")
  [[ $LOOP =~ ^/dev/loop[0-9]+$ ]] || die shared_loop_invalid
  verify_shared_loop
}

verify_shared_loop() {
  local expected actual found
  expected=$(realpath -e "$BACKING") || die backing_realpath
  found=$(losetup -j "$BACKING" | awk -F: 'NF{print $1}')
  [[ $found == "$LOOP" ]] || die shared_loop_mapping
  actual=$(loop_backing "$LOOP") || die shared_loop_backing_unavailable
  [[ $actual == "$expected" ]] || die shared_loop_backing_mismatch
}

create_storage() {
  [[ ! -e $BACKING_ROOT && ! -e $BACKING ]] || die backing_path_exists
  mkdir -m 0700 -p "$ROOT/storage"
  log_command sudo install -d -m 0700 -o 1002 -g 1002 "$BACKING_ROOT"
  sudo install -d -m 0700 -o 1002 -g 1002 "$BACKING_ROOT"
  [[ $(stat -Lc %u "$BACKING_ROOT") == 1002 && $(stat -Lc %g "$BACKING_ROOT") == 1002 && $(stat -Lc %a "$BACKING_ROOT") == 700 ]] || die backing_root_identity
  log_command fallocate -l 128G -- "$BACKING"
  fallocate -l 128G -- "$BACKING"
  log_command sudo losetup --find --show --nooverlap "$BACKING"
  sudo losetup --find --show --nooverlap "$BACKING" >"$SHARED_LOOP_FILE"
  shared_loop
  printf 'backing\t%s\nloop\t%s\n' "$BACKING" "$LOOP" >"$ROOT/storage/state.tsv"
}

prepare_cache() {
  shared_loop
  [[ -z $(findmnt -rn -S "$LOOP" -o TARGET) ]] || die shared_loop_already_mounted
  [[ ! -e $CACHE_MNT ]] || die cache_mount_exists
  log_command sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$LOOP"
  sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$LOOP" >"$CELL_ROOT/mkfs.txt"
  mkdir -m 0700 "$CACHE_MNT"
  log_command sudo mount -o noatime,nodiscard "$LOOP" "$CACHE_MNT"
  sudo mount -o noatime,nodiscard "$LOOP" "$CACHE_MNT"
  log_command sudo chown 1002:1002 "$CACHE_MNT"
  sudo chown 1002:1002 "$CACHE_MNT"
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$LOOP" ]] || die cache_mount_identity
  mkdir -m 0700 "$CACHE_DIR"
  AVAIL_MIB=$(df -B1 "$CACHE_MNT" | awk 'NR==2{printf "%d",$4/1048576}')
  (( AVAIL_MIB > CACHE_MIB + 8192 )) || die cache_capacity_margin
  findmnt -rn -M "$CACHE_MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS,UUID >"$CELL_ROOT/cache-findmnt.tsv"
  printf 'backing\t%s\nloop\t%s\ncache_mount\t%s\ncache_dir\t%s\navailable_mib\t%s\ncache_mib\t%s\n' \
    "$BACKING" "$LOOP" "$CACHE_MNT" "$CACHE_DIR" "$AVAIL_MIB" "$CACHE_MIB" >"$CELL_ROOT/storage.tsv"
}

cleanup_cache() {
  mountpoint -q "$MNT" && die cleanup_jfs_still_mounted
  shared_loop
  [[ $(findmnt -rn -M "$CACHE_MNT" -o SOURCE) == "$LOOP" ]] || die cleanup_cache_mount_identity
  log_command sudo umount "$CACHE_MNT"
  sudo umount "$CACHE_MNT"
  [[ -z $(findmnt -rn -S "$LOOP" -o TARGET) ]] || die cache_mount_remains
  rmdir "$CACHE_MNT" || die cache_mount_dir_not_empty
  printf 'CACHE_CELL_CLOSED\n' >"$CELL_ROOT/cache-cleanup"
}

destroy_storage() {
  shared_loop
  [[ -z $(findmnt -rn -S "$LOOP" -o TARGET) ]] || die destroy_loop_still_mounted
  log_command sudo losetup -d "$LOOP"
  sudo losetup -d "$LOOP"
  [[ -z $(losetup -j "$BACKING") ]] || die loop_remains
  unlink -- "$BACKING"
  log_command sudo rmdir "$BACKING_ROOT"
  sudo rmdir "$BACKING_ROOT"
  [[ ! -e $BACKING_ROOT ]] || die backing_root_remains
  printf 'STORAGE_DESTROY_PASS\n' >"$ROOT/storage/DESTROYED"
}

readback_probe() {
  local out=$CELL_ROOT/readback-cache0
  mkdir -m 0700 "$out"
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$out/reference-mount.tsv"
  grep -Fq "JuiceFS:juicefs-prod $REF fuse.juicefs " "$out/reference-mount.tsv" || die readback_reference_identity
  local -a cmd=(fio --readonly --name=readback --ioengine=libaio --iodepth=1 --direct=1 --bs=256K
    --rw=randread --size=1G --numjobs=8 --time_based=1 --runtime=10 --randrepeat=1 --randseed=20260907
    "--filename_format=$REF/test_dir/rw_test.\$jobnum.0" --output="$out/fio.json" --output-format=json)
  log_command "${cmd[@]}"
  "${cmd[@]}"
  python3 - "$out/fio.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); j=d.get('jobs',[])
if len(j)!=8 or any(int(x.get('error',-1)) for x in j): raise SystemExit('readback fio contract')
PY
  printf 'READBACK_PASS\n' >"$out/PASS"
}

run_cell() {
  local label=$1 stop sampler_pid fio_rc sampler_rc drain_rc=0
  CELL=$label; cell_spec
  [[ ! -e $CELL_ROOT ]] || die "cell_exists:$CELL"
  mkdir -m 0700 -p "$CELL_ROOT"
  record "$label" START; incident "$label" START
  health_gate paused "$CELL_ROOT/health-pre"
  prepare_cache
  asset_identity "$REF" "$CELL_ROOT/assets-pre.tsv"
  mount_jfs warmup
  sample_sidecar pre
  run_fio warmup randread || die fio_warmup
  stop=$CELL_ROOT/sampler.stop
  runtime_sampler "$stop" "$CELL_ROOT/runtime.tsv" >"$CELL_ROOT/sampler.stdout" 2>"$CELL_ROOT/sampler.stderr" & sampler_pid=$!
  if run_fio formal randrw; then fio_rc=0; else fio_rc=$?; fi
  : >"$stop"
  if wait "$sampler_pid"; then sampler_rc=0; else sampler_rc=$?; fi
  printf '%s\n' "$fio_rc" >"$CELL_ROOT/fio.rc"; printf '%s\n' "$sampler_rc" >"$CELL_ROOT/sampler.rc"
  (( fio_rc == 0 && sampler_rc == 0 )) || die formal_or_sampler_failed
  sample_sidecar formal-end
  asset_identity "$MNT" "$CELL_ROOT/assets-post.tsv"
  cmp -s "$CELL_ROOT/assets-pre.tsv" "$CELL_ROOT/assets-post.tsv" || die asset_identity_drift
  if drain_writeback "$CELL_ROOT/drain.tsv"; then drain_rc=0; else drain_rc=$?; fi
  printf '%s\n' "$drain_rc" >"$CELL_ROOT/drain.rc"
  (( drain_rc == 0 )) || { incident "$label" drain_timeout; die drain_timeout_preserve; }
  graceful_umount
  cleanup_cache
  readback_probe
  state_return
  health_gate paused "$CELL_ROOT/health-post"
  record "$label" PASS; incident "$label" PASS
  : >"$CELL_ROOT/PASS"
}

write_sudo_plan() {
  local cell osd round
  cat >"$ROOT/plans/sudo-contract.txt" <<EOF
# Scrub lease (state-driven controller executes these only if absent)
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set noscrub
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd set nodeep-scrub
# One RUN-owned backing and verified dynamic loop
sudo install -d -m 0700 -o 1002 -g 1002 $BACKING_ROOT
sudo losetup --find --show --nooverlap $BACKING
EOF
  for cell in $(matrix); do
    cat >>"$ROOT/plans/sudo-contract.txt" <<EOF
# $cell; LOOP is the exact verified output of the preceding losetup
sudo mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 VERIFIED_LOOP
sudo mount -o noatime,nodiscard VERIFIED_LOOP /tmp/jfs-04-7-cache-$RUN_ID-$cell
sudo chown 1002:1002 /tmp/jfs-04-7-cache-$RUN_ID-$cell
sudo umount /tmp/jfs-04-7-cache-$RUN_ID-$cell
EOF
  done
  for round in initialization A1 B1 B2 A2; do
    printf '# OSD compact round: %s\n' "$round" >>"$ROOT/plans/sudo-contract.txt"
    while read -r osd; do
      printf 'sudo ceph -c %s --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin tell osd.%s compact\n' "$ROOT/inventory/ceph.conf" "$osd" >>"$ROOT/plans/sudo-contract.txt"
    done <"$ROOT/inventory/osd-ids.txt"
  done
  cat >>"$ROOT/plans/sudo-contract.txt" <<EOF
sudo losetup -d VERIFIED_LOOP
sudo rmdir $BACKING_ROOT
# Scrub restore executes unset only for flags owned by this lease
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset nodeep-scrub
sudo ceph -c $ROOT/inventory/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin osd unset noscrub
EOF
}

reference_cache0_gate() {
  python3 - "$JFS" "$REF" >"$ROOT/inventory/reference-processes.tsv" <<'PY'
import os,sys
exe=os.path.realpath(sys.argv[1]); mount=sys.argv[2]; rows=[]
for p in os.listdir('/proc'):
 if not p.isdigit(): continue
 try:
  if os.path.realpath('/proc/'+p+'/exe') != exe: continue
  cmd=open('/proc/'+p+'/cmdline','rb').read().replace(b'\0',b' ').decode(errors='replace').strip()
  if mount in cmd: rows.append((p,cmd))
 except OSError: pass
if len(rows)!=2 or any('--cache-size 0' not in cmd for _,cmd in rows):
 raise SystemExit('reference cache=0 process contract')
print('pid\tcmdline')
for row in rows: print(*row,sep='\t')
PY
}

inventory_plan() {
  local runner_path
  valid_run
  [[ ! -e $ROOT ]] || die result_exists
  mkdir -p "$ROOT"; chmod 0700 "$ROOT"
  mkdir -m 0700 -p "$ROOT/inventory" "$ROOT/plans" "$ROOT/cells" "$ROOT/storage"
  [[ $(id -u) == 1002 && $(id -g) == 1002 ]] || die executor_identity
  [[ -x $JFS && ! -L $JFS && -d $REF && -d $CACHE_PARENT ]] || die prerequisite_missing
  [[ $(md5sum "$JFS" | awk '{print $1}') == 24fae0852051c80ca571cb2f20275d46 ]] || die jfs_identity
  make_ceph_conf
  md5sum "$JFS" >"$ROOT/inventory/juicefs.md5"; sha256sum "$JFS" >"$ROOT/inventory/juicefs.sha256"; "$JFS" version >"$ROOT/inventory/juicefs-version.txt"
  CEPH_CONF="$ROOT/inventory/ceph.conf" "$JFS" status "$META" >"$ROOT/inventory/volume-status.json" || die volume_status
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph fsid >"$ROOT/inventory/fsid.txt" || die ceph_fsid
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph osd ls --format json | python3 -c 'import json,sys;print("\n".join(map(str,json.load(sys.stdin))))' >"$ROOT/inventory/osd-ids.txt"
  [[ $(wc -l <"$ROOT/inventory/osd-ids.txt") == 6 ]] || die osd_count
  health_gate unpaused "$ROOT/inventory/health"
  asset_identity "$REF" "$ROOT/inventory/assets-core.tsv"
  findmnt -rn -M "$REF" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/reference-mount.tsv"
  reference_cache0_gate
  findmnt -rn -T "$CACHE_PARENT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$ROOT/inventory/cache-parent.tsv"
  [[ $(findmnt -rn -T "$CACHE_PARENT" -o FSTYPE) == ext4 ]] || die cache_parent_not_ext4
  df -B1 "$CACHE_PARENT" >"$ROOT/inventory/cache-df.tsv"
  [[ $(df -B1 "$CACHE_PARENT" | awk 'NR==2{print $4}') -ge $((160*1024*1024*1024)) ]] || die cache_free_below_160g
  if pgrep -a -x fio >"$ROOT/inventory/foreign-fio.tsv" 2>&1; then die foreign_fio; fi
  ! findmnt -rn | grep -F 'jfs-04-7-' >"$ROOT/inventory/stale-mounts.tsv" || die stale_04_7_mount
  ! losetup -l -n -O NAME,BACK-FILE | grep -F '/jfs-04-7-' >"$ROOT/inventory/stale-loops.tsv" || die stale_04_7_loop
  ! pgrep -af '/tmp/jfs-04-7-[0-9]{8}-[0-9]{6}-' >"$ROOT/inventory/stale-processes.tsv" 2>&1 || die stale_04_7_process
  ss -ltnH >"$ROOT/inventory/listeners.tsv"
  ! awk '$4 ~ /:9568$/ {found=1} END {exit found?0:1}' "$ROOT/inventory/listeners.tsv" || die metrics_port_busy
  env CEPH_CONF="$ROOT/inventory/ceph.conf" ceph df -f json >"$ROOT/inventory/pool-pre.json"
  matrix >"$ROOT/plans/matrix-order.txt"
  write_sudo_plan
  runner_path=$(realpath -e "$0") || die runner_realpath
  sha256sum "$runner_path" "$ANALYZER" "$GATE" "$BASE" "$SCRUB" >"$ROOT/plans/scripts.sha256"
  printf 'RUN_ID\t%s\nSTATUS\tINVENTORY_PLAN_PASS\n' "$RUN_ID" >"$ROOT/run-state.tsv"
  printf 'epoch_ns\tcell\tevent\n' >"$ROOT/incidents.tsv"
  printf 'INVENTORY_PLAN_PASS\n' >"$ROOT/plans/PASS"
  printf '04_7_INVENTORY_PLAN_PASS\troot=%s\n' "$ROOT"
}

execute_all() {
  valid_run
  [[ ${T047_ACK:-} == I_ACK_04_7_$RUN_ID ]] || die ack_missing
  [[ -f $ROOT/plans/PASS && ! -f $ROOT/PASS ]] || die plan_or_run_state
  sha256sum -c "$ROOT/plans/scripts.sha256" >/dev/null || die script_drift
  static_identity
  if pgrep -a -x fio >"$ROOT/foreign-fio-execute.tsv" 2>&1; then die foreign_fio; fi
  : >"$ROOT/commands.sh"
  trap on_exit EXIT
  pause_scrub
  health_gate paused "$ROOT/health-pre"
  initialize_seed
  create_storage
  local item
  for item in $(matrix); do run_cell "$item"; done
  destroy_storage
  restore_scrub || die scrub_restore_failed
  trap - EXIT
  health_gate unpaused "$ROOT/health-final"
  python3 "$ANALYZER" analyze --root "$ROOT" --output "$ROOT/analysis.json" >"$ROOT/verdict.txt"
  printf 'RUN_ID\t%s\nSTATUS\tEXECUTE_PASS\nVERDICT\t%s\n' "$RUN_ID" "$(<"$ROOT/verdict.txt")" >"$ROOT/run-state.tsv"
  printf 'EXECUTE_PASS\n' >"$ROOT/PASS"
  printf '04_7_EXECUTE_PASS\tverdict=%s\n' "$(<"$ROOT/verdict.txt")"
}

bundle_run() {
  valid_run; [[ -d $ROOT ]] || die evidence_root_missing
  mkdir -m 0700 -p "$ROOT/bundle"
  local tarball=$ROOT/bundle/04-7-$RUN_ID.tar
  tar --sort=name --mtime='UTC 1970-01-01' -cf "$tarball" -C "$ROOT" --exclude=./bundle . \
    -C "$SELF_DIR" t04-7-randrw-async-screen-run.sh t04-7-randrw-async-screen-analyze.py \
    t04-7-randrw-async-screen-gate0-offline.sh t04tmp2i-randrw-run.sh u141d-scrub-control.sh
  sha256sum "$tarball" >"$tarball.sha256"
  printf 'BUNDLE_PASS\t%s\n' "$tarball"
}

offline_self_test() {
  RUN_ID=20000101-000000; ROOT=/tmp/production/opencode-04-7-$RUN_ID
  BACKING_ROOT=/mnt/jfs-cache/jfs-04-7-$RUN_ID; BACKING=$BACKING_ROOT/cache-128g.img
  [[ $(matrix | paste -sd, -) == A1,B1,B2,A2 ]] || die matrix_contract
  local item seen=''
  for item in $(matrix); do CELL=$item; cell_spec; seen+="$CELL:$ASYNC,"; done
  [[ $seen == A1:0,B1:1,B2:1,A2:0, ]] || die variable_contract
  printf '04_7_OFFLINE_SELF_TEST_PASS\tmatrix=A1,B1,B2,A2\n'
}

set -u
case $MODE in
  offline-self-test) offline_self_test ;;
  inventory-plan) inventory_plan ;;
  execute) execute_all ;;
  bundle) bundle_run ;;
  *) usage; exit 2 ;;
esac
