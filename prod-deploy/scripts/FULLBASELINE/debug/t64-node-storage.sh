#!/usr/bin/env bash
# Node-local RAM block lifecycle for 03-22. Run directly on one TiKV node.
# Mutating actions are create and destroy; neither has an automatic rollback trap.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}
CLUSTER=${3:-}
NODE_IP=${4:-}
t64_check_run_id "$RUN_ID"
t64_check_cluster "$CLUSTER"
t64_node_suffix "$NODE_IP" >/dev/null

LOWER=$(t64_cluster_lower "$CLUSTER")
BASE="/mnt/jfs-t64-${RUN_ID}-${LOWER}"
STATE="/tmp/jfs-t64-${RUN_ID}-${LOWER}-storage.tsv"
AUDIT="/tmp/jfs-t64-${RUN_ID}-${LOWER}-storage.destroyed.tsv"
TARGET_UID=$(id -u)
TARGET_GID=$(id -g)
TARGET_USER=$(id -un)
HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
[[ "$HOST_IP" == "$NODE_IP" ]] || t64_die "host identity mismatch: expected=$NODE_IP actual=${HOST_IP:-unknown}"
t64_assert_abs_scoped_path "$BASE" "$RUN_ID"
t64_assert_abs_scoped_path "$STATE" "$RUN_ID"

if [[ "$CLUSTER" == A ]]; then
  ROLES=(shared)
  SIZES=(128G)
else
  ROLES=(kv logs)
  SIZES=(96G 32G)
fi

mount_source_target() {
  findmnt -rn -M "$1" -o SOURCE,TARGET 2>/dev/null || true
}

assert_no_protected_token() {
  local value=$1
  case "$value" in
    *nvme*|*/mnt/jfs-tikv*|*/opt/*|*/etc/*|*/var/lib/ceph*)
      t64_die "protected path/device token detected: $value";;
  esac
}

plan() {
  local i role size backing fs img
  printf 'MODE=PLAN_ONLY\nnode=%s\nrun_id=%s\ncluster=%s\n' "$NODE_IP" "$RUN_ID" "$CLUSTER"
  printf 'No command below is executed by plan. Create is serial, one node at a time.\n'
  printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$TARGET_UID" "$TARGET_GID" "$BASE" "$BASE/pd"
  printf 'sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec t64-pd-%s-%s %q\n' "$RUN_ID" "$LOWER" "$BASE/pd"
  printf 'sudo install -d -m 0700 -o %s -g %s %q  # reset ownership on mounted tmpfs root\n' "$TARGET_UID" "$TARGET_GID" "$BASE/pd"
  for i in "${!ROLES[@]}"; do
    role=${ROLES[$i]}; size=${SIZES[$i]}
    backing="$BASE/backing-$role"; fs="$BASE/fs-$role"; img="$backing/t64-$role.img"
    printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$TARGET_UID" "$TARGET_GID" "$backing" "$fs"
    printf 'sudo mount -t tmpfs -o size=%s,mode=0700,nodev,nosuid,noexec t64-%s-%s-%s %q\n' "$size" "$RUN_ID" "$LOWER" "$role" "$backing"
    printf 'sudo install -d -m 0700 -o %s -g %s %q  # reset ownership on mounted tmpfs root\n' "$TARGET_UID" "$TARGET_GID" "$backing"
    printf 'truncate -s %s %q\n' "$size" "$img"
    printf 'sudo losetup --find --show --nooverlap %q\n' "$img"
    printf 'sudo mkfs.ext4 -F -m 0 -T largefile -E lazy_itable_init=0,lazy_journal_init=0 <recorded-loop-device>\n'
    printf 'sudo mount -o noatime,nodev,nosuid,nodiscard <recorded-loop-device> %q\n' "$fs"
    printf 'sudo chown %s:%s %q\n' "$TARGET_UID" "$TARGET_GID" "$fs"
  done
  printf 'PROTECTED=/dev/nvme* /mnt/jfs-tikv /opt /etc /var/lib/ceph; no command may target them.\n'
}

plan_destroy() {
  [[ -s "$STATE" ]] || t64_die "missing state: $STATE"
  verify >/dev/null
  printf 'MODE=DESTROY_PLAN_ONLY\nnode=%s\nrun_id=%s\ncluster=%s\n' "$NODE_IP" "$RUN_ID" "$CLUSTER"
  local kind role loop img backing fs
  while IFS=$'\t' read -r kind role loop img backing fs; do
    [[ "$kind" == loop ]] || continue
    printf 'sudo umount %q\n' "$fs"
    printf 'sudo losetup -d %q  # only after backing=%q is reverified\n' "$loop" "$img"
  done < "$STATE"
  while IFS=$'\t' read -r kind role loop img backing fs; do
    [[ "$kind" == tmpfs && "$role" == backing-* ]] || continue
    printf 'sudo umount %q\n' "$img"
  done < "$STATE"
  while IFS=$'\t' read -r kind role loop img backing fs; do
    [[ "$kind" == tmpfs && "$role" == pd ]] || continue
    printf 'sudo umount %q\n' "$img"
  done < "$STATE"
  for role in "${ROLES[@]}"; do
    printf 'rmdir %q %q\n' "$BASE/fs-$role" "$BASE/backing-$role"
  done
  printf 'rmdir %q\n' "$BASE/pd"
  printf 'sudo rmdir %q  # parent is directly below root-managed /mnt\n' "$BASE"
  printf 'No bulk deletion, device wiping, global loop detach, or forced unmount is used. Empty scoped directories use rmdir only.\n'
}

preflight() {
  t64_require_tools awk findmnt lsblk losetup mountpoint truncate mkfs.ext4 stat sudo
  [[ ! -e "$STATE" && ! -e "$AUDIT" ]] || t64_die "state/audit already exists: $STATE"
  [[ ! -e "$BASE" ]] || t64_die "base already exists: $BASE"
  for port in 12379 12380 30160 30180; do
    ! ss -Hlnpt "sport = :$port" 2>/dev/null | grep -q . || t64_die "temporary port already busy: $port"
  done
  local mem_kib
  mem_kib=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  (( mem_kib >= 402653184 )) || t64_die "MemAvailable below frozen 384GiB floor: ${mem_kib}KiB"
  ! pgrep -x fio >/dev/null || t64_die 'foreign fio exists on this node'
  local foreign
  foreign=$(ps -eo pid=,comm=,args= | awk -v me="$$" -v parent="$PPID" -v token="jfs-t64-${RUN_ID}" \
    '$1!=me && $1!=parent && index($0,token)>0 && ($2=="pd-server" || $2=="tikv-server" || $2=="juicefs"){print;exit}')
  [[ -z "$foreign" ]] || t64_die "temporary t64 process already exists: $foreign"
  printf 'PREFLIGHT_PASS node=%s MemAvailable_KiB=%s\n' "$NODE_IP" "$mem_kib"
}

reset_mounted_root_owner() {
  local path=$1 actual
  t64_assert_abs_scoped_path "$path" "$RUN_ID"
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$path"
  actual=$(stat -c '%u:%g:%a' "$path")
  [[ "$actual" == "$TARGET_UID:$TARGET_GID:700" ]] ||
    t64_die "mounted root ownership/mode mismatch: path=$path actual=$actual expected=$TARGET_UID:$TARGET_GID:700"
}

create() {
  [[ ${T64_CREATE_AUTH:-} == "03-22-create-${RUN_ID}-${CLUSTER}-${NODE_IP}" ]] ||
    t64_die "set exact T64_CREATE_AUTH=03-22-create-${RUN_ID}-${CLUSTER}-${NODE_IP} after reviewing plan"
  preflight
  umask 077
  : > "$STATE"
  printf 'meta\t%s\t%s\t%s\t%s\n' "$RUN_ID" "$CLUSTER" "$NODE_IP" "$BASE" >> "$STATE"

  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$BASE"
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$BASE/pd"
  sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec \
    "t64-pd-${RUN_ID}-${LOWER}" "$BASE/pd"
  printf 'tmpfs\tpd\t%s\t%s\n' "t64-pd-${RUN_ID}-${LOWER}" "$BASE/pd" >> "$STATE"
  reset_mounted_root_owner "$BASE/pd"

  local i role size backing fs img loop row
  for i in "${!ROLES[@]}"; do
    role=${ROLES[$i]}; size=${SIZES[$i]}
    backing="$BASE/backing-$role"; fs="$BASE/fs-$role"; img="$backing/t64-$role.img"
    t64_assert_abs_scoped_path "$backing" "$RUN_ID"
    t64_assert_abs_scoped_path "$fs" "$RUN_ID"
    assert_no_protected_token "$backing"
    sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$backing" "$fs"
    sudo mount -t tmpfs -o "size=$size,mode=0700,nodev,nosuid,noexec" \
      "t64-${RUN_ID}-${LOWER}-${role}" "$backing"
    printf 'tmpfs\tbacking-%s\t%s\t%s\n' "$role" "t64-${RUN_ID}-${LOWER}-${role}" "$backing" >> "$STATE"
    reset_mounted_root_owner "$backing"
    truncate -s "$size" "$img"
    loop=$(sudo losetup --find --show --nooverlap "$img")
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t64_die "losetup returned unsafe device: $loop"
    assert_no_protected_token "$loop"
    printf 'loop\t%s\t%s\t%s\t%s\t%s\n' "$role" "$loop" "$img" "$backing" "$fs" >> "$STATE"
    row=$(sudo losetup -l -n -O NAME,BACK-FILE "$loop" | awk 'NF{print $1"\t"$2}')
    [[ "$row" == "$loop"$'\t'"$img" ]] || t64_die "loop/backing verification failed: $row"
    sudo mkfs.ext4 -F -m 0 -T largefile -E lazy_itable_init=0,lazy_journal_init=0 "$loop"
    sudo mount -o noatime,nodev,nosuid,nodiscard "$loop" "$fs"
    sudo chown "$TARGET_UID:$TARGET_GID" "$fs"
  done

  if [[ "$CLUSTER" == A ]]; then
    mkdir -p "$BASE/fs-shared/runs"
  else
    mkdir -p "$BASE/fs-kv/runs" "$BASE/fs-logs/runs"
  fi
  mkdir -p "$BASE/pd/runs"
  printf 'CREATE_PASS node=%s cluster=%s state=%s\n' "$NODE_IP" "$CLUSTER" "$STATE"
}

verify() {
  [[ -s "$STATE" ]] || t64_die "missing state: $STATE"
  local kind role a b c d expected row
  while IFS=$'\t' read -r kind role a b c d; do
    case "$kind" in
      meta)
        [[ "$role" == "$RUN_ID" && "$a" == "$CLUSTER" && "$b" == "$NODE_IP" && "$c" == "$BASE" ]] ||
          t64_die 'state metadata mismatch';;
      tmpfs)
        t64_assert_abs_scoped_path "$b" "$RUN_ID"
        row=$(mount_source_target "$b")
        [[ "$row" == "$a $b" ]] || t64_die "tmpfs mapping mismatch: expected=$a,$b actual=$row";;
      loop)
        [[ "$a" =~ ^/dev/loop[0-9]+$ ]] || t64_die "unsafe recorded loop: $a"
        t64_assert_abs_scoped_path "$b" "$RUN_ID"
        t64_assert_abs_scoped_path "$d" "$RUN_ID"
        row=$(sudo losetup -l -n -O NAME,BACK-FILE "$a" | awk 'NF{print $1"\t"$2}')
        [[ "$row" == "$a"$'\t'"$b" ]] || t64_die "loop mapping changed: $role $row"
        row=$(mount_source_target "$d")
        [[ "$row" == "$a $d" ]] || t64_die "filesystem mapping mismatch: $role $row";;
      *) t64_die "unknown state row: $kind";;
    esac
  done < "$STATE"
  printf 'VERIFY_PASS node=%s cluster=%s\n' "$NODE_IP" "$CLUSTER"
  # BASE itself is only a parent directory, not a mountpoint. `findmnt -R BASE`
  # may print child mounts yet return 1, which is fatal under set -e. Enumerate
  # the mount table and select exact descendants instead.
  findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS | \
    awk -v p="$BASE/" 'index($2,p)==1'
  sudo losetup -l -n -O NAME,BACK-FILE | awk -v p="/mnt/jfs-t64-${RUN_ID}-${LOWER}/" 'index($2,p)==1'
}

destroy() {
  [[ ${T64_DESTROY_AUTH:-} == "03-22-destroy-${RUN_ID}-${CLUSTER}-${NODE_IP}" ]] ||
    t64_die "set exact T64_DESTROY_AUTH=03-22-destroy-${RUN_ID}-${CLUSTER}-${NODE_IP} after separate teardown authorization"
  [[ -s "$STATE" ]] || t64_die "missing state: $STATE"
  [[ ! -e "$AUDIT" ]] || t64_die "destroy audit already exists: $AUDIT"
  ! pgrep -af "/tmp/jfs-t64-${RUN_ID}-.*(pd|tikv).*\.toml" >/dev/null ||
    t64_die 'temporary PD/TiKV process still exists; stop it first'
  local rows=() kind role loop img backing fs source
  IFS=$'\t' read -r kind role loop img backing fs < "$STATE"
  [[ "$kind" == meta && "$role" == "$RUN_ID" && "$loop" == "$CLUSTER" && "$img" == "$NODE_IP" && "$backing" == "$BASE" ]] ||
    t64_die 'state metadata mismatch; refuse destroy'
  mapfile -t rows < <(awk -F '\t' '$1=="loop"{print}' "$STATE")
  local idx
  for ((idx=${#rows[@]}-1; idx>=0; idx--)); do
    IFS=$'\t' read -r kind role loop img backing fs <<< "${rows[$idx]}"
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t64_die "unsafe loop in destroy: $loop"
    t64_assert_abs_scoped_path "$img" "$RUN_ID"
    t64_assert_abs_scoped_path "$backing" "$RUN_ID"
    t64_assert_abs_scoped_path "$fs" "$RUN_ID"
    [[ $(sudo losetup -l -n -O BACK-FILE "$loop" | awk 'NF{print}') == "$img" ]] ||
      t64_die "refuse detach: backing changed for $loop"
    source=$(findmnt -rn -M "$fs" -o SOURCE 2>/dev/null || true)
    if [[ -n "$source" ]]; then
      [[ "$source" == "$loop" ]] || t64_die "refuse unmount: $fs source is $source, expected $loop"
      sudo umount "$fs"
    fi
    [[ -z $(findmnt -rn -S "$loop" -o TARGET 2>/dev/null) ]] || t64_die "$loop remains mounted"
    sudo losetup -d "$loop"
    source=$(findmnt -rn -M "$backing" -o SOURCE 2>/dev/null || true)
    [[ "$source" == "t64-${RUN_ID}-${LOWER}-${role}" ]] || t64_die "refuse backing tmpfs unmount: source=$source"
    sudo umount "$backing"
    [[ ! -e "$fs" ]] || rmdir "$fs"
    [[ ! -e "$backing" ]] || rmdir "$backing"
  done
  for role in "${ROLES[@]}"; do
    backing="$BASE/backing-$role"
    source=$(findmnt -rn -M "$backing" -o SOURCE 2>/dev/null || true)
    if [[ -n "$source" ]]; then
      [[ "$source" == "t64-${RUN_ID}-${LOWER}-${role}" ]] || t64_die "refuse residual backing unmount: source=$source"
      sudo umount "$backing"
    fi
    [[ ! -e "$BASE/fs-$role" ]] || rmdir "$BASE/fs-$role"
    [[ ! -e "$backing" ]] || rmdir "$backing"
  done
  source=$(findmnt -rn -M "$BASE/pd" -o SOURCE 2>/dev/null || true)
  if [[ -n "$source" ]]; then
    [[ "$source" == "t64-pd-${RUN_ID}-${LOWER}" ]] || t64_die "refuse PD tmpfs unmount: source=$source"
    sudo umount "$BASE/pd"
  fi
  [[ ! -e "$BASE/pd" ]] || rmdir "$BASE/pd"
  [[ ! -e "$BASE" ]] || sudo rmdir "$BASE"
  { printf 'destroy_epoch\t%s\n' "$(date +%s)"; cat "$STATE"; } > "$AUDIT"
  rm -f "$STATE"
  printf 'DESTROY_PASS node=%s cluster=%s audit=%s\n' "$NODE_IP" "$CLUSTER" "$AUDIT"
}

case "$ACTION" in
  plan) plan;;
  plan-destroy) plan_destroy;;
  preflight) preflight;;
  create) create;;
  verify) verify;;
  destroy) destroy;;
  *) t64_die 'usage: t64-node-storage.sh plan|plan-destroy|preflight|create|verify|destroy RUN_ID A|B NODE_IP';;
esac
