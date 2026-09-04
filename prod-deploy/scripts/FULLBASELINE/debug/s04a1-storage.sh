#!/usr/bin/env bash
# State-driven native/loop storage lifecycle for 04-2.  No automatic rollback.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
NODE_IP=${3:-}
ARM=${4:-}
INSTANCE=${5:-}
BYTES=137438953472
UID_FROZEN=1001
GID_FROZEN=1001
GIB=$((1024 * 1024 * 1024))
PROD_MOUNT=/mnt/jfs-tikv

s04a1_check_run_id "$RUN_ID"
s04a1_check_node "$NODE_IP"
NODE=${NODE_IP##*.}
BASE_ROOT="/mnt/jfs-s04a1-${RUN_ID}"
BACKING_ROOT="${PROD_MOUNT}/jfs-s04a1-${RUN_ID}-l-backing"
BACKING="${BACKING_ROOT}/loop.img"
BASE_STATE="/tmp/s04a1-${RUN_ID}-storage-base-${NODE}.tsv"
BASE_AUDIT="/tmp/s04a1-${RUN_ID}-storage-base-${NODE}.destroyed.tsv"

die() { s04a1_die "$*"; exit 42; }

check_arm_instance() {
  s04a1_check_arm "$ARM"
  [[ $INSTANCE =~ ^R0[1-8]$ ]] || die "storage instance must be an approved R01..R08 path"
  [[ $(s04a1_expected_arm "$INSTANCE") == "$ARM" ]] || die "arm/instance mismatch: $ARM/$INSTANCE"
}

ARM_ROOT="${BASE_ROOT}/${INSTANCE}-${NODE}"
PD_ROOT="${ARM_ROOT}/pd"
LOOP_ROOT="${ARM_ROOT}/fs"
NATIVE_ROOT="${PROD_MOUNT}/jfs-s04a1-${RUN_ID}-c-${INSTANCE}-${NODE}"
ACTIVE_STATE="/tmp/s04a1-${RUN_ID}-storage-active-${INSTANCE}-${NODE}.tsv"
ACTIVE_AUDIT="/tmp/s04a1-${RUN_ID}-storage-active-${INSTANCE}-${NODE}.closed.tsv"

host_guard() {
  local found
  found=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk -v n="$NODE_IP" '$0==n{print;exit}')
  [[ $found == "$NODE_IP" ]] || die "host mismatch: expected=$NODE_IP"
  [[ $(id -u) == "$UID_FROZEN" && $(id -g) == "$GID_FROZEN" ]] || die "executor uid/gid mismatch"
}

prod_mount_guard() {
  local source target fstype
  read -r source target fstype < <(findmnt -rn -M "$PROD_MOUNT" -o SOURCE,TARGET,FSTYPE)
  [[ $source == /dev/nvme1n1 && $target == "$PROD_MOUNT" && $fstype == ext4 ]] ||
    die "production mount mismatch: $source $target $fstype"
}

realpath_guard() {
  local path=$1 expected=$2 actual
  [[ $path == /* && $path != / && $path != *'..'* && $path != *'*'* && $path != *'?'* ]] ||
    die "unsafe path: $path"
  actual=$(realpath -m -- "$path")
  [[ $actual == "$expected" ]] || die "realpath mismatch: $path -> $actual expected=$expected"
  [[ ! -L $path ]] || die "symlink forbidden: $path"
}

scope_guard() {
  local path=$1
  case "$path" in
    "$BASE_ROOT"|"$BASE_ROOT"/*|"$BACKING_ROOT"|"$BACKING_ROOT"/*|\
    "$NATIVE_ROOT") ;;
    *) die "path outside exact 04-2 scope: $path" ;;
  esac
  case "$path" in
    "$PROD_MOUNT"/data|"$PROD_MOUNT"/data/*|"$PROD_MOUNT"/wal|"$PROD_MOUNT"/wal/*|\
    "$PROD_MOUNT"/raft|"$PROD_MOUNT"/raft/*|/opt/*|/var/lib/ceph/*) die "protected path overlap: $path" ;;
  esac
}

state_one() {
  local file=$1 key=$2
  awk -F '\t' -v k="$key" '$1==k{v=$2;n++} END{if(n==1)print v;else exit 1}' "$file"
}

state_last() {
  local file=$1 key=$2
  awk -F '\t' -v k="$key" '$1==k{v=$2;n++} END{if(n>0)print v;else exit 1}' "$file"
}

auth_guard() {
  local verb=$1 expected
  expected="04-2-storage-${verb}-${RUN_ID}-${NODE_IP}"
  [[ ${S04A1_STORAGE_AUTH:-} == "$expected" ]] || die "exact auth required: $expected"
}

tikv_stopped_guard() {
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || die "production tikv remains active on $NODE_IP"
}

available_bytes() { df -B1 --output=avail "$PROD_MOUNT" | awk 'NR==2{gsub(/[[:space:]]/,"");print}'; }

allocated_guard() {
  local path=$1 logical blocks
  [[ -f $path && ! -L $path ]] || die "backing missing/not regular: $path"
  [[ $(stat -Lc %s -- "$path") == "$BYTES" ]] || die "backing logical size mismatch"
  blocks=$(stat -Lc %b -- "$path")
  logical=$((blocks * 512))
  (( logical >= BYTES - 16 * 1024 * 1024 )) || die "backing is sparse/underallocated: allocated=$logical"
}

base_state_guard() {
  [[ -s $BASE_STATE && ! -L $BASE_STATE ]] || die "base state missing"
  [[ $(state_one "$BASE_STATE" run_id) == "$RUN_ID" ]] || die "base RUN mismatch"
  [[ $(state_one "$BASE_STATE" node_ip) == "$NODE_IP" ]] || die "base node mismatch"
  [[ $(state_one "$BASE_STATE" backing) == "$BACKING" ]] || die "base backing mismatch"
  [[ $(state_one "$BASE_STATE" base_root) == "$BASE_ROOT" ]] || die "base root mismatch"
  realpath_guard "$BACKING" "$BACKING"
  allocated_guard "$BACKING"
  [[ $(stat -Lc %u:%g -- "$BACKING") == "$UID_FROZEN:$GID_FROZEN" ]] || die "backing owner mismatch"
  [[ $(stat -Lc %d -- "$BACKING") == $(state_one "$BASE_STATE" backing_dev) ]] || die "backing device changed"
  [[ $(stat -Lc %i -- "$BACKING") == $(state_one "$BASE_STATE" backing_inode) ]] || die "backing inode changed"
}

active_state_guard() {
  [[ -s $ACTIVE_STATE && ! -L $ACTIVE_STATE ]] || die "active state missing"
  [[ $(state_one "$ACTIVE_STATE" run_id) == "$RUN_ID" ]] || die "active RUN mismatch"
  [[ $(state_one "$ACTIVE_STATE" node_ip) == "$NODE_IP" ]] || die "active node mismatch"
  [[ $(state_one "$ACTIVE_STATE" arm) == "$ARM" ]] || die "active arm mismatch"
  [[ $(state_one "$ACTIVE_STATE" instance) == "$INSTANCE" ]] || die "active instance mismatch"
  [[ $(state_one "$ACTIVE_STATE" pd_root) == "$PD_ROOT" ]] || die "active PD path mismatch"
}

no_other_active_state() {
  local file
  while IFS= read -r file; do
    [[ $file != *.closed.tsv ]] || continue
    [[ $file == "$ACTIVE_STATE" ]] || die "another active storage state exists: $file"
  done < <(find /tmp -maxdepth 1 -type f -name "s04a1-${RUN_ID}-storage-active-*.tsv" -print)
}

loop_backing() {
  local loop=$1 sys
  [[ $loop =~ ^/dev/loop[0-9]+$ ]] || die "not a loop device: $loop"
  sys="/sys/block/${loop##*/}/loop/backing_file"
  [[ -r $sys ]] || die "loop backing sysfs absent: $loop"
  realpath -e -- "$(cat "$sys")"
}

loop_guard() {
  local loop=$1 reverse
  [[ $(loop_backing "$loop") == $(realpath -e -- "$BACKING") ]] || die "loop backing mismatch"
  reverse=$(sudo losetup -j "$BACKING")
  [[ $(printf '%s\n' "$reverse" | awk -F: -v l="$loop" '$1==l{n++} END{print n+0}') == 1 ]] ||
    die "losetup reverse mapping mismatch"
}

no_open_files() {
  local path=$1 out rc
  command -v lsof >/dev/null 2>&1 || die "lsof required"
  set +e
  out=$(timeout 60 lsof +D "$path" 2>&1); rc=$?
  set -e
  (( rc == 1 )) || { [[ $rc == 0 ]] && die "open file remains under $path: $out"; die "lsof failed/timeout rc=$rc path=$path"; }
}

no_scoped_process() {
  local token="s04a1-${RUN_ID}" rows='' cursor parent excluded pid args self_pid probe own
  self_pid=${BASHPID:-$$}; cursor=$self_pid; excluded=" $cursor "
  while (( cursor > 1 )); do
    parent=$(awk '{print $4}' "/proc/$cursor/stat" 2>/dev/null || true)
    [[ $parent =~ ^[0-9]+$ && $parent -gt 1 && $excluded != *" $parent "* ]] || break
    excluded+="$parent "; cursor=$parent
  done
  # Keep the scan in this shell.  A command substitution would create a bash
  # child whose inherited argv contains the scoped script path and would make
  # the quiescence gate reject its own scanner.
  while read -r pid args; do
    [[ $args == *"$token"* ]] || continue
    [[ $excluded == *" $pid "* ]] && continue
    # Process substitution can briefly expose a bash child with the caller's
    # argv before execing `ps`; exclude only descendants of this script, not
    # unrelated siblings that happen to share an sshd parent.
    probe=$pid; own=0
    while [[ $probe =~ ^[0-9]+$ && $probe -gt 1 ]]; do
      [[ $probe == "$self_pid" ]] && { own=1; break; }
      parent=$(awk '{print $4}' "/proc/$probe/stat" 2>/dev/null || true)
      [[ $parent =~ ^[0-9]+$ && $parent -ne "$probe" ]] || break
      probe=$parent
    done
    (( own == 1 )) && continue
    # A process-substitution wrapper may exit between the `ps` snapshot and
    # this ancestry check.  A vanished PID is not a remaining process.
    [[ -r /proc/$pid/stat ]] || continue
    rows+="${rows:+$'\n'}$pid $args"
  done < <(ps -eo pid=,args=)
  [[ -z $rows ]] || die "scoped process remains: ${rows//$'\n'/; }"
}

safe_delete_tree_contents() {
  local root=$1
  python3 - "$root" "$UID_FROZEN" <<'PY'
import os, stat, sys
root=os.path.realpath(sys.argv[1]); uid=int(sys.argv[2])
if root == "/" or not root.startswith("/mnt/jfs-tikv/jfs-s04a1-"):
    raise SystemExit("unsafe native root")
st=os.lstat(root)
if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid:
    raise SystemExit("native root type/owner mismatch")
dev=st.st_dev; items=[]
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    bst=os.lstat(base)
    if not stat.S_ISDIR(bst.st_mode) or bst.st_dev != dev or bst.st_uid != uid:
        raise SystemExit(f"unsafe directory: {base}")
    for name in dirs+files:
        p=os.path.join(base,name); x=os.lstat(p)
        if stat.S_ISLNK(x.st_mode) or x.st_dev != dev or x.st_uid != uid:
            raise SystemExit(f"unsafe entry: {p}")
        if not (stat.S_ISDIR(x.st_mode) or stat.S_ISREG(x.st_mode)):
            raise SystemExit(f"special entry: {p}")
        items.append(p)
for p in sorted(items,key=lambda x:(x.count(os.sep),x),reverse=True):
    if stat.S_ISDIR(os.lstat(p).st_mode): os.rmdir(p)
    else: os.unlink(p)
PY
}

reset_active_data() {
  local data_root pd_data path
  check_arm_instance; auth_guard reset-active; host_guard; prod_mount_guard; tikv_stopped_guard; active_state_guard
  no_scoped_process
  data_root=$(state_one "$ACTIVE_STATE" data_root)
  pd_data="$PD_ROOT/pd-$NODE"
  for path in "$data_root/kv" "$data_root/wal" "$data_root/raft-engine" "$pd_data"; do
    [[ ! -e $path ]] && continue
    [[ -d $path && ! -L $path && $(stat -Lc %u -- "$path") == "$UID_FROZEN" ]] || die "reset path unsafe: $path"
    no_open_files "$path"
    python3 - "$path" "$UID_FROZEN" "$data_root" "$PD_ROOT" <<'PY'
import os, stat, sys
root=os.path.realpath(sys.argv[1]); uid=int(sys.argv[2])
allowed=[os.path.realpath(x) for x in sys.argv[3:]]
if root == "/" or not any(root.startswith(x+os.sep) for x in allowed):
    raise SystemExit("reset root outside active data/PD roots")
st=os.lstat(root)
if not stat.S_ISDIR(st.st_mode) or st.st_uid != uid:
    raise SystemExit("reset root type/owner mismatch")
dev=st.st_dev; items=[]
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    bst=os.lstat(base)
    if not stat.S_ISDIR(bst.st_mode) or bst.st_dev != dev or bst.st_uid != uid:
        raise SystemExit(f"unsafe directory: {base}")
    for name in dirs+files:
        p=os.path.join(base,name); x=os.lstat(p)
        if stat.S_ISLNK(x.st_mode) or x.st_dev != dev or x.st_uid != uid:
            raise SystemExit(f"unsafe entry: {p}")
        if not (stat.S_ISDIR(x.st_mode) or stat.S_ISREG(x.st_mode)):
            raise SystemExit(f"special entry: {p}")
        items.append(p)
for p in sorted(items,key=lambda x:(x.count(os.sep),x),reverse=True):
    if stat.S_ISDIR(os.lstat(p).st_mode): os.rmdir(p)
    else: os.unlink(p)
os.rmdir(root)
PY
  done
  printf 'reset_epoch\t%s\nstatus\tactive\n' "$(date +%s)" >> "$ACTIVE_STATE"
  verify_active
  printf 'S04A1_STORAGE_RESET_ACTIVE_PASS node=%s arm=%s storage_instance=%s\n' "$NODE_IP" "$ARM" "$INSTANCE"
}

plan() {
  check_arm_instance
  printf 'MODE=PLAN_ONLY\nRUN_ID=%s\nNODE=%s\nARM=%s\nINSTANCE=%s\n' "$RUN_ID" "$NODE_IP" "$ARM" "$INSTANCE"
  printf 'BASE_CREATE: sudo install -d -m 0700 -o 1001 -g 1001 %q %q\n' "$BACKING_ROOT" "$BASE_ROOT"
  printf 'BASE_ALLOCATE_NON_SUDO: fallocate -l %s -- %q\n' "$BYTES" "$BACKING"
  printf 'PD_CREATE: sudo install -d -m 0700 -o 1001 -g 1001 %q\n' "$PD_ROOT"
  printf 'PD_MOUNT: sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec %q %q\n' \
    "s04a1-pd-${RUN_ID}-${INSTANCE}-${NODE}" "$PD_ROOT"
  printf 'PD_OWNER: sudo install -d -m 0700 -o 1001 -g 1001 %q\n' "$PD_ROOT"
  if [[ $ARM == C ]]; then
    printf 'C_CREATE: sudo install -d -m 0700 -o 1001 -g 1001 %q\n' "$NATIVE_ROOT"
    printf 'C_CLOSE: sudo rmdir -- %q\n' "$NATIVE_ROOT"
  else
    printf 'L_CREATE: sudo install -d -m 0700 -o 1001 -g 1001 %q\n' "$LOOP_ROOT"
    printf 'L_ATTACH: sudo losetup --find --show --nooverlap %q\n' "$BACKING"
    printf 'L_FORMAT: sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <returned-and-verified-loop>\n'
    printf 'L_MOUNT: sudo mount -o noatime,nodiscard <same-verified-loop> %q\n' "$LOOP_ROOT"
    printf 'L_OWNER: sudo chown 1001:1001 %q\n' "$LOOP_ROOT"
    printf 'L_CLOSE: sudo umount %q; sudo losetup -d <state-and-backing-verified-loop>\n' "$LOOP_ROOT"
  fi
  printf 'PD_CLOSE: sudo umount %q\n' "$PD_ROOT"
  printf 'BASE_DESTROY: unlink -- %q; sudo rmdir -- %q %q\n' "$BACKING" "$BACKING_ROOT" "$BASE_ROOT"
}

create_base() {
  local avail_pre avail_post inode dev
  auth_guard create-base; host_guard; prod_mount_guard; tikv_stopped_guard
  [[ ! -e $BASE_STATE && ! -e $BASE_AUDIT && ! -e $BACKING_ROOT && ! -e $BASE_ROOT ]] || die "base scope already exists"
  [[ -z $(sudo losetup -j "$BACKING") ]] || die "loop already maps backing"
  avail_pre=$(available_bytes); [[ $avail_pre =~ ^[0-9]+$ ]] || die "invalid available bytes"
  (( avail_pre >= 768 * GIB )) || die "pre-create free space below 768GiB"
  sudo install -d -m 0700 -o "$UID_FROZEN" -g "$GID_FROZEN" "$BACKING_ROOT" "$BASE_ROOT"
  realpath_guard "$BACKING_ROOT" "$BACKING_ROOT"; realpath_guard "$BASE_ROOT" "$BASE_ROOT"
  : > "$BACKING"
  inode=$(stat -Lc %i -- "$BACKING"); dev=$(stat -Lc %d -- "$BACKING")
  {
    printf 'run_id\t%s\nnode_ip\t%s\nbase_root\t%s\nbacking_root\t%s\nbacking\t%s\n' "$RUN_ID" "$NODE_IP" "$BASE_ROOT" "$BACKING_ROOT" "$BACKING"
    printf 'backing_dev\t%s\nbacking_inode\t%s\navail_pre\t%s\nstatus\tallocating\n' "$dev" "$inode" "$avail_pre"
  } > "$BASE_STATE"
  fallocate -l "$BYTES" -- "$BACKING"
  allocated_guard "$BACKING"
  avail_post=$(available_bytes); (( avail_post >= 640 * GIB )) || die "post-create free space below 640GiB"
  printf 'avail_post\t%s\nstatus\tready\n' "$avail_post" >> "$BASE_STATE"
  verify_base
  printf 'S04A1_STORAGE_BASE_CREATE_PASS node=%s state=%s\n' "$NODE_IP" "$BASE_STATE"
}

verify_base() {
  host_guard; prod_mount_guard; base_state_guard
  [[ $(state_last "$BASE_STATE" status) == ready ]] || die "base state not ready"
  [[ -d $BASE_ROOT && ! -L $BASE_ROOT && $(stat -Lc %u:%g "$BASE_ROOT") == "$UID_FROZEN:$GID_FROZEN" ]] || die "base root mismatch"
  printf 'S04A1_STORAGE_BASE_VERIFY_PASS node=%s\n' "$NODE_IP"
}

activate() {
  local loop uuid i
  check_arm_instance; auth_guard activate; host_guard; prod_mount_guard; tikv_stopped_guard; base_state_guard; no_other_active_state
  [[ ! -e $ACTIVE_STATE && ! -e $ACTIVE_AUDIT && ! -e $ARM_ROOT && ! -e $NATIVE_ROOT ]] || die "arm scope already exists"
  scope_guard "$ARM_ROOT"; scope_guard "$PD_ROOT"; scope_guard "$NATIVE_ROOT"; scope_guard "$LOOP_ROOT"
  sudo install -d -m 0700 -o "$UID_FROZEN" -g "$GID_FROZEN" "$ARM_ROOT" "$PD_ROOT"
  {
    printf 'run_id\t%s\nnode_ip\t%s\narm\t%s\ninstance\t%s\narm_root\t%s\npd_root\t%s\n' "$RUN_ID" "$NODE_IP" "$ARM" "$INSTANCE" "$ARM_ROOT" "$PD_ROOT"
    printf 'status\tcreated-dirs\n'
  } > "$ACTIVE_STATE"
  sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec "s04a1-pd-${RUN_ID}-${INSTANCE}-${NODE}" "$PD_ROOT"
  sudo install -d -m 0700 -o "$UID_FROZEN" -g "$GID_FROZEN" "$PD_ROOT"
  printf 'status\tpd-mounted\n' >> "$ACTIVE_STATE"
  if [[ $ARM == C ]]; then
    sudo install -d -m 0700 -o "$UID_FROZEN" -g "$GID_FROZEN" "$NATIVE_ROOT"
    printf 'data_root\t%s\nstatus\tactive\n' "$NATIVE_ROOT" >> "$ACTIVE_STATE"
  else
    sudo install -d -m 0700 -o "$UID_FROZEN" -g "$GID_FROZEN" "$LOOP_ROOT"
    loop=$(sudo losetup --find --show --nooverlap "$BACKING")
    printf 'loop\t%s\nstatus\tloop-attached\n' "$loop" >> "$ACTIVE_STATE"
    loop_guard "$loop"
    sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop"
    sudo mount -o noatime,nodiscard "$loop" "$LOOP_ROOT"
    sudo chown "$UID_FROZEN:$GID_FROZEN" "$LOOP_ROOT"
    # UUID lookup may lag the successful mount briefly while udev/blkid state
    # settles.  Bound the wait and still fail closed on an empty identity.
    uuid=''
    for ((i=0; i<10; i++)); do
      uuid=$(findmnt -rn -M "$LOOP_ROOT" -o UUID)
      [[ -n $uuid ]] && break
      sleep 1
    done
    [[ -n $uuid ]] || die "L filesystem UUID missing"
    printf 'data_root\t%s\nfs_uuid\t%s\nstatus\tactive\n' "$LOOP_ROOT" "$uuid" >> "$ACTIVE_STATE"
  fi
  verify_active
  printf 'S04A1_STORAGE_ACTIVATE_PASS node=%s arm=%s instance=%s state=%s\n' "$NODE_IP" "$ARM" "$INSTANCE" "$ACTIVE_STATE"
}

verify_active() {
  local source target fstype loop
  check_arm_instance; host_guard; prod_mount_guard; base_state_guard; active_state_guard
  [[ $(state_last "$ACTIVE_STATE" status) == active ]] || die "arm state not active"
  read -r source target fstype < <(findmnt -rn -M "$PD_ROOT" -o SOURCE,TARGET,FSTYPE)
  [[ $source == "s04a1-pd-${RUN_ID}-${INSTANCE}-${NODE}" && $target == "$PD_ROOT" && $fstype == tmpfs ]] || die "PD mount mismatch"
  if [[ $ARM == C ]]; then
    [[ $(state_one "$ACTIVE_STATE" data_root) == "$NATIVE_ROOT" && -d $NATIVE_ROOT && ! -L $NATIVE_ROOT ]] || die "C root mismatch"
  else
    loop=$(state_one "$ACTIVE_STATE" loop); loop_guard "$loop"
    read -r source target fstype < <(findmnt -rn -M "$LOOP_ROOT" -o SOURCE,TARGET,FSTYPE)
    [[ $source == "$loop" && $target == "$LOOP_ROOT" && $fstype == ext4 ]] || die "L mount mismatch"
    [[ $(findmnt -rn -M "$LOOP_ROOT" -o UUID) == $(state_one "$ACTIVE_STATE" fs_uuid) ]] || die "L UUID mismatch"
  fi
  printf 'S04A1_STORAGE_ACTIVE_VERIFY_PASS node=%s arm=%s instance=%s\n' "$NODE_IP" "$ARM" "$INSTANCE"
}

plan_deactivate() {
  check_arm_instance; active_state_guard
  printf 'MODE=PLAN_DEACTIVATE\nNODE=%s\nARM=%s\nINSTANCE=%s\n' "$NODE_IP" "$ARM" "$INSTANCE"
  [[ $ARM == L ]] && printf 'sudo umount %q\nsudo losetup -d %q\n' "$LOOP_ROOT" "$(state_one "$ACTIVE_STATE" loop)"
  printf 'sudo umount %q\n' "$PD_ROOT"
  [[ $ARM == C ]] && printf 'NON_SUDO_SAFE_DELETE_CONTENTS %q\nsudo rmdir -- %q\n' "$NATIVE_ROOT" "$NATIVE_ROOT"
  printf 'NON_SUDO_RMDIR %q\n' "$ARM_ROOT"
}

deactivate() {
  local loop
  check_arm_instance; auth_guard deactivate; host_guard; prod_mount_guard; tikv_stopped_guard; active_state_guard
  no_scoped_process
  no_open_files "$PD_ROOT"
  if [[ $ARM == L ]]; then
    no_open_files "$LOOP_ROOT"
    loop=$(state_one "$ACTIVE_STATE" loop); loop_guard "$loop"
    [[ $(findmnt -rn -M "$LOOP_ROOT" -o SOURCE) == "$loop" ]] || die "L source drift before unmount"
    sudo umount "$LOOP_ROOT"
    loop_guard "$loop"
    sudo losetup -d "$loop"
    [[ -z $(sudo losetup -j "$BACKING") ]] || die "loop remains after detach"
    rmdir "$LOOP_ROOT"
  else
    no_open_files "$NATIVE_ROOT"
    ! findmnt -rn -R "$NATIVE_ROOT" | grep -q . || die "foreign mount under C root"
    safe_delete_tree_contents "$NATIVE_ROOT"
    sudo rmdir "$NATIVE_ROOT"
  fi
  [[ $(findmnt -rn -M "$PD_ROOT" -o FSTYPE) == tmpfs ]] || die "PD tmpfs missing before unmount"
  sudo umount "$PD_ROOT"
  rmdir "$PD_ROOT" "$ARM_ROOT"
  { printf 'closed_epoch\t%s\n' "$(date +%s)"; cat "$ACTIVE_STATE"; } > "$ACTIVE_AUDIT"
  unlink "$ACTIVE_STATE"
  printf 'S04A1_STORAGE_DEACTIVATE_PASS node=%s arm=%s instance=%s audit=%s\n' "$NODE_IP" "$ARM" "$INSTANCE" "$ACTIVE_AUDIT"
}

plan_destroy_base() {
  host_guard; prod_mount_guard; base_state_guard; no_other_active_state; no_scoped_process
  [[ -z $(sudo losetup -j "$BACKING") ]] || die "loop remains"
  [[ -z $(findmnt -rn -R "$BASE_ROOT") ]] || die "mount remains below base root"
  no_open_files "$BACKING_ROOT"
  printf 'MODE=PLAN_DESTROY_BASE\nNODE=%s\nNON_SUDO_UNLINK=%s\n' "$NODE_IP" "$BACKING"
  printf 'sudo rmdir -- %q %q\n' "$BACKING_ROOT" "$BASE_ROOT"
}

destroy_base() {
  local pre now delta
  auth_guard destroy-base; host_guard; prod_mount_guard; tikv_stopped_guard; base_state_guard; no_other_active_state; no_scoped_process
  [[ ! -e $BASE_AUDIT ]] || die "base audit already exists"
  [[ -z $(sudo losetup -j "$BACKING") ]] || die "loop remains"
  [[ -z $(findmnt -rn -R "$BASE_ROOT") ]] || die "mount remains below base root"
  no_open_files "$BACKING_ROOT"
  pre=$(state_one "$BASE_STATE" avail_pre)
  unlink "$BACKING"
  sudo rmdir "$BACKING_ROOT" "$BASE_ROOT"
  now=$(available_bytes); delta=$((now - pre)); (( delta < 0 )) && delta=$((-delta))
  (( delta <= 2 * GIB )) || die "space did not return within 2GiB: pre=$pre now=$now"
  { printf 'destroy_epoch\t%s\navail_after\t%s\n' "$(date +%s)" "$now"; cat "$BASE_STATE"; } > "$BASE_AUDIT"
  unlink "$BASE_STATE"
  printf 'S04A1_STORAGE_BASE_DESTROY_PASS node=%s audit=%s\n' "$NODE_IP" "$BASE_AUDIT"
}

case "$ACTION" in
  plan) plan ;;
  create-base) create_base ;;
  verify-base) verify_base ;;
  activate) activate ;;
  verify-active) verify_active ;;
  reset-active) reset_active_data ;;
  plan-deactivate) plan_deactivate ;;
  deactivate) deactivate ;;
  plan-destroy-base) plan_destroy_base ;;
  destroy-base) destroy_base ;;
  *) die "usage: $0 plan|create-base|verify-base|activate|verify-active|reset-active|plan-deactivate|deactivate|plan-destroy-base|destroy-base RUN_ID NODE_IP ARM INSTANCE" ;;
esac
