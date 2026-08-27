#!/usr/bin/env bash
# Create the two persistent NVMe-backed files for one 03-22c node.
# No loop, mkfs, mount, cluster, fio, or automatic rollback is performed here.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}
NODE_IP=${3:-}
t66_check_run_id "$RUN_ID"
t66_node_suffix "$NODE_IP" >/dev/null

BACKING_ROOT="/mnt/jfs-tikv/jfs-t66-${RUN_ID}-backing"
MOUNT_ROOT="/mnt/jfs-t66-${RUN_ID}"
STATE="/tmp/jfs-t66-${RUN_ID}-storage.tsv"
TARGET_UID=$(id -u)
TARGET_GID=$(id -g)
GIB=$((1024 * 1024 * 1024))
PRE_MIN=$((768 * GIB))
POST_MIN=$((640 * GIB))
ROLES=(kv b1c-logs)
SIZES=($((96 * GIB)) $((32 * GIB)))
FILES=("$BACKING_ROOT/kv.img" "$BACKING_ROOT/b1c-logs.img")

t66_assert_abs_scoped_path "$BACKING_ROOT" "$RUN_ID"
t66_assert_abs_scoped_path "$MOUNT_ROOT" "$RUN_ID"
t66_assert_no_production_overlap "$BACKING_ROOT"

host_guard() {
  local actual
  actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t66_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

mount_identity() {
  local source target fstype
  read -r source target fstype < <(findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE)
  [[ "$source" == /dev/nvme1n1 && "$target" == /mnt/jfs-tikv && "$fstype" == ext4 ]] ||
    t66_die "production TiKV mount mismatch: source=$source target=$target fstype=$fstype"
}

available_bytes() {
  df -B1 --output=avail /mnt/jfs-tikv | awk 'NR==2{gsub(/[[:space:]]/,"");print}'
}

assert_clean_scope() {
  # Historical immutable destroy audits do not represent an active storage
  # lifecycle and must not block the one planned post-canary recreation.
  t66_require_absent "$STATE"; t66_require_absent "$BACKING_ROOT"; t66_require_absent "$MOUNT_ROOT"
  ! findmnt -rn -o TARGET | awk -v p="$MOUNT_ROOT" '$1==p || index($1,p"/")==1{found=1} END{exit !found}' ||
    t66_die 't66 mount already exists'
  ! sudo losetup -l -n -O BACK-FILE | awk -v p="$BACKING_ROOT/" 'index($1,p)==1{found=1} END{exit !found}' ||
    t66_die 't66 loop already exists'
}

preflight() {
  local avail mem_kib
  t66_require_tools awk df du fallocate findmnt hostname losetup realpath stat sudo
  host_guard
  mount_identity
  assert_clean_scope
  avail=$(available_bytes)
  [[ "$avail" =~ ^[0-9]+$ ]] || t66_die 'invalid df available value'
  t66_capacity_pre_ok "$avail" || t66_die "Avail_pre below 768GiB: $avail"
  mem_kib=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  t66_memory_pre_ok "$mem_kib" || t66_die "MemAvailable below 128GiB: ${mem_kib}KiB"
  printf 'STORAGE_PREFLIGHT_PASS\tnode=%s\tavail_pre=%s\tmem_available_kib=%s\n' "$NODE_IP" "$avail" "$mem_kib"
}

plan() {
  local i
  printf 'MODE=PLAN_ONLY\nnode=%s\nrun_id=%s\n' "$NODE_IP" "$RUN_ID"
  printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$TARGET_UID" "$TARGET_GID" "$BACKING_ROOT" "$MOUNT_ROOT"
  for i in "${!FILES[@]}"; do
    printf 'fallocate -l %s -- %q\n' "${SIZES[$i]}" "${FILES[$i]}"
    printf 'stat/du allocation gate role=%s logical=%s allocated>=logical-16MiB\n' "${ROLES[$i]}" "${SIZES[$i]}"
  done
  printf 'No loop, mkfs, mount, service operation, sparse allocation, raw-device write, or cleanup is hidden in this plan.\n'
}

create() {
  local expected="03-22c-storage-create-${RUN_ID}-${NODE_IP}" avail_pre avail_post i path inode dev
  t66_check_auth "${T66_STORAGE_CREATE_AUTH:-}" "$expected"
  t66_record_authorization "$RUN_ID" storage-create "$expected"
  preflight
  avail_pre=$(available_bytes)
  umask 077
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$BACKING_ROOT" "$MOUNT_ROOT"
  printf 'meta\t%s\nnode\t%s\nuid\t%s\ngid\t%s\nbacking_root\t%s\nmount_root\t%s\navail_pre\t%s\n' \
    "$RUN_ID" "$NODE_IP" "$TARGET_UID" "$TARGET_GID" "$BACKING_ROOT" "$MOUNT_ROOT" "$avail_pre" > "$STATE"
  for i in "${!FILES[@]}"; do
    path=${FILES[$i]}
    t66_assert_realpath_exact "$path" "$path"
    t66_assert_no_production_overlap "$path"
    [[ ! -e "$path" ]] || t66_die "backing already exists: $path"
    : > "$path"
    inode=$(stat -Lc '%i' -- "$path"); dev=$(stat -Lc '%d' -- "$path")
    printf 'file\t%s\t%s\t%s\t%s\t%s\tallocating\n' "${ROLES[$i]}" "$path" "${SIZES[$i]}" "$dev" "$inode" >> "$STATE"
    fallocate -l "${SIZES[$i]}" -- "$path"
    t66_assert_allocated_file "$path" "${SIZES[$i]}" >> "$STATE.allocation-checks"
    printf 'allocated\t%s\t%s\t%s\t%s\t%s\n' "${ROLES[$i]}" "$path" "${SIZES[$i]}" "$dev" "$inode" >> "$STATE"
  done
  avail_post=$(available_bytes)
  t66_capacity_post_ok "$avail_post" || t66_die "Avail_post below 640GiB after allocation: $avail_post"
  printf 'avail_post\t%s\ncreate_epoch\t%s\n' "$avail_post" "$(date +%s)" >> "$STATE"
  verify
  printf 'STORAGE_CREATE_PASS node=%s state=%s avail_pre=%s avail_post=%s\n' "$NODE_IP" "$STATE" "$avail_pre" "$avail_post"
}

verify() {
  local i path role expected_bytes dev inode actual_dev actual_inode allocated_count
  [[ -s "$STATE" ]] || t66_die "missing storage state: $STATE"
  t66_validate_storage_contract_rows "$STATE" "$RUN_ID" "$NODE_IP" || t66_die 'storage state text contract mismatch'
  [[ $(t66_state_value "$STATE" meta) == "$RUN_ID" && $(t66_state_value "$STATE" node) == "$NODE_IP" &&
     $(t66_state_value "$STATE" backing_root) == "$BACKING_ROOT" && $(t66_state_value "$STATE" mount_root) == "$MOUNT_ROOT" ]] ||
    t66_die 'storage state identity mismatch'
  mount_identity
  for i in "${!FILES[@]}"; do
    role=${ROLES[$i]}; path=${FILES[$i]}; expected_bytes=${SIZES[$i]}
    read -r dev inode < <(awk -F '\t' -v r="$role" '$1=="allocated"&&$2==r{d=$5;i=$6;n++} END{if(n==1)print d,i;else exit 1}' "$STATE") ||
      t66_die "missing unique allocated row: $role"
    actual_dev=$(stat -Lc '%d' -- "$path"); actual_inode=$(stat -Lc '%i' -- "$path")
    [[ "$actual_dev" == "$dev" && "$actual_inode" == "$inode" ]] || t66_die "backing inode changed: $role"
    t66_assert_allocated_file "$path" "$expected_bytes"
  done
  allocated_count=$(awk -F '\t' '$1=="allocated"{n++} END{print n+0}' "$STATE")
  [[ "$allocated_count" -eq 2 ]] || t66_die "allocated row count mismatch: $allocated_count"
  printf 'STORAGE_VERIFY_PASS node=%s run_id=%s\n' "$NODE_IP" "$RUN_ID"
}

case "$ACTION" in
  plan) host_guard; plan;;
  preflight) preflight;;
  create) create;;
  verify) host_guard; verify;;
  *) t66_die 'usage: t66-storage-create-one.sh plan|preflight|create|verify RUN_ID NODE_IP';;
esac
