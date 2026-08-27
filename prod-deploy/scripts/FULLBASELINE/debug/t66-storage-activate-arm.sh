#!/usr/bin/env bash
# Activate one fresh B1c/D1 local filesystem set and one fresh PD tmpfs on one node.
# mkfs is deliberately isolated here and requires an exact per-instance token.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}
ARM=${3:-}
INSTANCE=${4:-}
NODE_IP=${5:-}
t66_check_run_id "$RUN_ID"; t66_check_cluster "$ARM"; t66_check_instance "$INSTANCE"; t66_node_suffix "$NODE_IP" >/dev/null
[[ $(t66_expected_cluster "$INSTANCE") == "$ARM" ]] || t66_die 'instance/arm mapping mismatch'

BACKING_ROOT="/mnt/jfs-tikv/jfs-t66-${RUN_ID}-backing"
MOUNT_ROOT="/mnt/jfs-t66-${RUN_ID}"
PD_MNT="$MOUNT_ROOT/pd"
STORAGE_STATE="/tmp/jfs-t66-${RUN_ID}-storage.tsv"
STATE="/tmp/jfs-t66-${RUN_ID}-${ARM}-${INSTANCE}-activation.tsv"
BASELINE="/tmp/jfs-t66-${RUN_ID}-${NODE_IP}-fresh-baseline.tsv"
QUIET_PREFIX="/tmp/jfs-t66-${RUN_ID}-${ARM}-${INSTANCE}-${NODE_IP}-nvme-quiet"
QUIET=''
TARGET_UID=$(id -u); TARGET_GID=$(id -g)
LOGS_TMPFS="$MOUNT_ROOT/d1-${INSTANCE,,}-logs-backing"
LOGS_BACKING="$LOGS_TMPFS/t66-d1-logs.img"
LOGS_TMPFS_SOURCE="t66-logs-${RUN_ID}-${INSTANCE,,}"
if [[ "$ARM" == B1c ]]; then
  ROLES=(kv logs); BACKINGS=("$BACKING_ROOT/kv.img" "$BACKING_ROOT/b1c-logs.img")
  MOUNTS=("$MOUNT_ROOT/b1c-kv" "$MOUNT_ROOT/b1c-logs")
else
  ROLES=(kv logs); BACKINGS=("$BACKING_ROOT/kv.img" "$LOGS_BACKING")
  MOUNTS=("$MOUNT_ROOT/d1-kv" "$MOUNT_ROOT/d1-logs")
fi
BYTES=($((96*1024*1024*1024)) $((32*1024*1024*1024)))

host_guard() {
  local actual; actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t66_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

assert_prod_tikv_stopped() {
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || t66_die 'production tikv unit is active'
  ! ps -eo comm=,args= | awk '$1=="tikv-server" && $0 !~ /jfs-t66-/{found=1} END{exit !found}' ||
    t66_die 'a non-t66 tikv-server process is running'
}

assert_no_instance_process() {
  ! ps -eo args= | grep -F -- "jfs-t66-${RUN_ID}-${INSTANCE}" | grep -v -F -- 'grep -F' | grep -q . ||
    t66_die 'instance process already exists'
}

loop_for_backing() {
  sudo losetup -j "$1" | awk -F: 'NF{print $1}'
}

check_or_freeze_baseline() {
  local role=$1 mnt=$2 uuid=$3 used=$4 free=$5 old_used old_free
  if awk -F '\t' -v r="$role" '$1==r{found=1} END{exit !found}' "$BASELINE" 2>/dev/null; then
    read -r old_used old_free < <(awk -F '\t' -v r="$role" '$1==r{print $3,$4}' "$BASELINE")
    t66_baseline_within_256m "$old_used" "$used" || t66_die "fresh FS baseline used drift exceeds 256MiB: role=$role old_used=$old_used used=$used"
    t66_baseline_within_256m "$old_free" "$free" || t66_die "fresh FS baseline drift exceeds 256MiB: role=$role old_free=$old_free free=$free"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$role" "$uuid" "$used" "$free" "$(date +%s)" >> "$BASELINE"
  fi
}

wait_nvme_quiet() {
  local i epoch writes sectors inflight
  : > "$QUIET"
  printf 'epoch\twrites_completed\tsectors_written\tinflight\n' >> "$QUIET"
  for ((i=0;i<=60;i++)); do
    read -r writes sectors inflight < <(awk '{print $5,$7,$9}' /sys/block/nvme1n1/stat)
    epoch=$(date +%s); printf '%s\t%s\t%s\t%s\n' "$epoch" "$writes" "$sectors" "$inflight" >> "$QUIET"
    ((i==60)) || sleep 1
  done
  t66_nvme_quiet_evidence_ok "$QUIET" > "$QUIET.summary" ||
    t66_die "underlying NVMe did not meet bounded idle profile in final 30s: $QUIET"
}

wait_fs_uuid() {
  local mnt=$1 deadline value=''
  deadline=$((SECONDS+30))
  while (( SECONDS < deadline )); do
    value=$(findmnt -rn -M "$mnt" -o UUID 2>/dev/null || true)
    [[ "$value" =~ ^[0-9A-Fa-f-]{36}$ ]] && { printf '%s\n' "$value"; return 0; }
    sleep 1
  done
  t66_die "FS UUID did not become visible within 30s: $mnt"
}

plan() {
  local i
  printf 'MODE=PLAN_ONLY\nnode=%s\nrun_id=%s\narm=%s\ninstance=%s\n' "$NODE_IP" "$RUN_ID" "$ARM" "$INSTANCE"
  printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$TARGET_UID" "$TARGET_GID" "$PD_MNT"
  if [[ "$ARM" == D1 ]]; then
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$TARGET_UID" "$TARGET_GID" "$LOGS_TMPFS"
    printf 'sudo mount -t tmpfs -o size=34G,mode=0700,nodev,nosuid,noexec %q %q\n' "$LOGS_TMPFS_SOURCE" "$LOGS_TMPFS"
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$TARGET_UID" "$TARGET_GID" "$LOGS_TMPFS"
    printf 'fallocate -l 34359738368 -- %q\n' "$LOGS_BACKING"
    printf 'stat/du allocation gate role=logs logical=34359738368 allocated>=logical-16MiB\n'
  fi
  printf 'sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec t66-pd-%s-%s %q\n' "$RUN_ID" "${INSTANCE,,}" "$PD_MNT"
  printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$TARGET_UID" "$TARGET_GID" "$PD_MNT"
  for i in "${!ROLES[@]}"; do
    printf 'sudo losetup --find --show --nooverlap %q\n' "${BACKINGS[$i]}"
    printf 'sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <verified-loop-for-%s>\n' "${ROLES[$i]}"
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$TARGET_UID" "$TARGET_GID" "${MOUNTS[$i]}"
    printf 'sudo mount -o noatime,nodiscard <verified-loop-for-%s> %q\n' "${ROLES[$i]}" "${MOUNTS[$i]}"
    printf 'sudo chown %s:%s %q\n' "$TARGET_UID" "$TARGET_GID" "${MOUNTS[$i]}"
  done
}

activate() {
  local expected="03-22c-activate-${RUN_ID}-${ARM}-${INSTANCE}-${NODE_IP}" i loop backing_real sys_backing fs_uuid free used entries state_sha mem_pre swap_free_pre pswpin_pre pswpout_pre
  t66_check_auth "${T66_ACTIVATE_AUTH:-}" "$expected"
  t66_record_authorization "$RUN_ID" "activate-$ARM-$INSTANCE" "$expected"
  host_guard; assert_prod_tikv_stopped; assert_no_instance_process
  [[ -s "$STORAGE_STATE" && ! -e "$STATE" ]] || t66_die 'storage state missing or current activation state exists'
  [[ $(t66_state_value "$STORAGE_STATE" meta) == "$RUN_ID" && $(t66_state_value "$STORAGE_STATE" node) == "$NODE_IP" ]] || t66_die 'storage state identity mismatch'
  ! findmnt -rn -o TARGET | awk -v p="$MOUNT_ROOT/" 'index($1,p)==1{found=1} END{exit !found}' || t66_die 'another t66 filesystem is active'
  t66_assert_allocated_file "$BACKING_ROOT/kv.img" "${BYTES[0]}" >/dev/null
  if [[ "$ARM" == B1c ]]; then
    t66_assert_allocated_file "$BACKING_ROOT/b1c-logs.img" "${BYTES[1]}" >/dev/null
  else
    [[ ! -e "$LOGS_TMPFS" ]] || t66_die "D1 logs tmpfs path already exists: $LOGS_TMPFS"
    ! findmnt -rn -M "$LOGS_TMPFS" >/dev/null 2>&1 || t66_die 'D1 logs tmpfs is already mounted'
  fi
  mem_pre=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); t66_memory_pre_ok "$mem_pre" || t66_die "MemAvailable below 128GiB before activation: $mem_pre"
  swap_free_pre=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  read -r pswpin_pre pswpout_pre < <(awk '$1=="pswpin"{a=$2}$1=="pswpout"{b=$2}END{print a+0,b+0}' /proc/vmstat)
  umask 077
  printf 'meta\t%s\nnode\t%s\narm\t%s\ninstance\t%s\nmount_root\t%s\nmemory_baseline\t%s\t%s\t%s\t%s\n' \
    "$RUN_ID" "$NODE_IP" "$ARM" "$INSTANCE" "$MOUNT_ROOT" "$mem_pre" "$swap_free_pre" "$pswpin_pre" "$pswpout_pre" > "$STATE"
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$PD_MNT"
  sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec "t66-pd-${RUN_ID}-${INSTANCE,,}" "$PD_MNT"
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$PD_MNT"
  printf 'pd\t%s\t%s\n' "t66-pd-${RUN_ID}-${INSTANCE,,}" "$PD_MNT" >> "$STATE"
  if [[ "$ARM" == D1 ]]; then
    sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$LOGS_TMPFS"
    sudo mount -t tmpfs -o size=34G,mode=0700,nodev,nosuid,noexec "$LOGS_TMPFS_SOURCE" "$LOGS_TMPFS"
    sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$LOGS_TMPFS"
    printf 'ram_logs\t%s\t%s\t%s\n' "$LOGS_TMPFS_SOURCE" "$LOGS_TMPFS" "${BYTES[1]}" >> "$STATE"
    fallocate -l "${BYTES[1]}" -- "$LOGS_BACKING"
    t66_assert_allocated_file "$LOGS_BACKING" "${BYTES[1]}" >/dev/null
  fi
  for i in "${!ROLES[@]}"; do
    [[ -z $(loop_for_backing "${BACKINGS[$i]}") ]] || t66_die "backing already has loop: ${BACKINGS[$i]}"
    t66_assert_allocated_file "${BACKINGS[$i]}" "${BYTES[$i]}" >/dev/null
    loop=$(sudo losetup --find --show --nooverlap "${BACKINGS[$i]}")
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t66_die "unsafe loop result: $loop"
    backing_real=$(realpath -e -- "${BACKINGS[$i]}")
    printf 'loop\t%s\t%s\t%s\t%s\tattached\n' "${ROLES[$i]}" "$loop" "$backing_real" "${MOUNTS[$i]}" >> "$STATE"
    sys_backing=$(sudo cat "/sys/block/${loop#/dev/}/loop/backing_file")
    [[ "/$sys_backing" == "$backing_real" || "$sys_backing" == "$backing_real" ]] || t66_die "loop backing mismatch: $loop $sys_backing"
    sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop"
    t66_assert_allocated_file "${BACKINGS[$i]}" "${BYTES[$i]}" >/dev/null
    sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "${MOUNTS[$i]}"
    sudo mount -o noatime,nodiscard "$loop" "${MOUNTS[$i]}"
    sudo chown "$TARGET_UID:$TARGET_GID" "${MOUNTS[$i]}"
    fs_uuid=$(wait_fs_uuid "${MOUNTS[$i]}")
    free=$(df -B1 --output=avail "${MOUNTS[$i]}" | awk 'NR==2{gsub(/[[:space:]]/,"");print}')
    used=$(df -B1 --output=used "${MOUNTS[$i]}" | awk 'NR==2{gsub(/[[:space:]]/,"");print}')
    entries=$(find "${MOUNTS[$i]}" -mindepth 1 -maxdepth 1 ! -name lost+found -printf . | wc -c)
    [[ "$entries" -eq 0 ]] || t66_die "fresh filesystem contains old entries: ${ROLES[$i]} count=$entries"
    check_or_freeze_baseline "${ROLES[$i]}" "${MOUNTS[$i]}" "$fs_uuid" "$used" "$free"
    printf 'fs\t%s\t%s\t%s\t%s\t%s\n' "${ROLES[$i]}" "$loop" "$fs_uuid" "$used" "$free" >> "$STATE"
    if [[ "${ROLES[$i]}" == logs ]]; then (( free >= 28*1024*1024*1024 )) || t66_die "$ARM logs fresh free below 28GiB: $free"; fi
  done
  for i in "${!MOUNTS[@]}"; do sync -f "${MOUNTS[$i]}"; done
  state_sha=$(sha256sum "$STATE" | awk '{print $1}')
  [[ "$state_sha" =~ ^[0-9a-f]{64}$ ]] || t66_die 'cannot derive immutable quiet evidence identity'
  QUIET="${QUIET_PREFIX}-${state_sha:0:16}.tsv"
  [[ ! -e "$QUIET" && ! -e "$QUIET.summary" ]] || t66_die "quiet evidence path already exists: $QUIET"
  wait_nvme_quiet
  printf 'quiet_evidence\t%s\n' "$QUIET" >> "$STATE"
  printf 'quiet_summary\t%s\n' "$QUIET.summary" >> "$STATE"
  printf 'activate_epoch\t%s\n' "$(date +%s)" >> "$STATE"
  verify
  printf 'STORAGE_ACTIVATE_PASS node=%s arm=%s instance=%s state=%s\n' "$NODE_IP" "$ARM" "$INSTANCE" "$STATE"
}

verify() {
  local i role loop backing mnt actual_source actual_backing actual_uuid fs_uuid fs_used fs_free baseline_uuid baseline_used baseline_free quiet quiet_id quiet_summary rechecked_summary mem_now swap_free_pre pswpin_pre pswpout_pre pswpin_now pswpout_now
  [[ -s "$STATE" ]] || t66_die "missing activation state: $STATE"
  t66_validate_activation_contract_rows "$STATE" "$RUN_ID" "$ARM" "$INSTANCE" "$NODE_IP" || t66_die 'activation state text contract mismatch'
  [[ $(t66_state_value "$STATE" meta) == "$RUN_ID" && $(t66_state_value "$STATE" node) == "$NODE_IP" &&
     $(t66_state_value "$STATE" arm) == "$ARM" && $(t66_state_value "$STATE" instance) == "$INSTANCE" ]] || t66_die 'activation identity mismatch'
  [[ $(findmnt -rn -M "$PD_MNT" -o SOURCE) == "t66-pd-${RUN_ID}-${INSTANCE,,}" ]] || t66_die 'PD tmpfs mismatch'
  if [[ "$ARM" == D1 ]]; then
    [[ $(findmnt -rn -M "$LOGS_TMPFS" -o SOURCE) == "$LOGS_TMPFS_SOURCE" ]] || t66_die 'D1 logs tmpfs mismatch'
    t66_assert_allocated_file "$LOGS_BACKING" "${BYTES[1]}" >/dev/null
  else
    [[ ! -e "$LOGS_TMPFS" ]] || t66_die 'B1c must not have a D1 logs tmpfs path'
  fi
  mem_now=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); t66_memory_runtime_ok "$mem_now" || t66_die "MemAvailable below 64GiB: $mem_now"
  read -r _ swap_free_pre pswpin_pre pswpout_pre < <(awk -F '\t' '$1=="memory_baseline"{print $2,$3,$4,$5;n++}END{if(n!=1)exit 1}' "$STATE")
  read -r pswpin_now pswpout_now < <(awk '$1=="pswpin"{a=$2}$1=="pswpout"{b=$2}END{print a+0,b+0}' /proc/vmstat)
  [[ "$pswpin_now" == "$pswpin_pre" && "$pswpout_now" == "$pswpout_pre" ]] || t66_die 'swap activity changed after activation'
  quiet=$(t66_state_value "$STATE" quiet_evidence)
  quiet_id=${quiet#"${QUIET_PREFIX}-"}; quiet_id=${quiet_id%.tsv}
  [[ "$quiet" == "${QUIET_PREFIX}-${quiet_id}.tsv" && "$quiet_id" =~ ^[0-9a-f]{16}$ && -s "$quiet" ]] ||
    t66_die 'NVMe quiet evidence missing, unscoped, or mismatched'
  quiet_summary=$(t66_state_value "$STATE" quiet_summary)
  [[ "$quiet_summary" == "$quiet.summary" && -s "$quiet_summary" ]] || t66_die 'NVMe quiet summary missing or mismatched'
  rechecked_summary=$(t66_nvme_quiet_evidence_ok "$quiet") || t66_die 'NVMe quiet evidence does not meet bounded idle profile'
  [[ $(<"$quiet_summary") == "$rechecked_summary" ]] || t66_die 'NVMe quiet summary does not match raw evidence'
  [[ -s "$BASELINE" ]] || t66_die 'fresh filesystem baseline is missing'
  for i in "${!ROLES[@]}"; do
    role=${ROLES[$i]}; backing=$(realpath -e -- "${BACKINGS[$i]}"); mnt=${MOUNTS[$i]}
    loop=$(awk -F '\t' -v r="$role" '$1=="loop"&&$2==r{print $3}' "$STATE")
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t66_die "bad loop state: $role"
    actual_source=$(findmnt -rn -M "$mnt" -o SOURCE); [[ "$actual_source" == "$loop" ]] || t66_die "mount source mismatch: $role"
    actual_backing=$(sudo losetup -l -n -O BACK-FILE "$loop" | awk 'NF{print}')
    [[ "$actual_backing" == "$backing" ]] || t66_die "loop backing changed: $role actual=$actual_backing expected=$backing"
    read -r fs_uuid fs_used fs_free < <(awk -F '\t' -v r="$role" '$1=="fs"&&$2==r{print $4,$5,$6}' "$STATE") ||
      t66_die "missing complete FS state: $role"
    actual_uuid=$(findmnt -rn -M "$mnt" -o UUID)
    [[ "$actual_uuid" == "$fs_uuid" ]] || t66_die "mounted FS UUID mismatch: $role"
    read -r baseline_uuid baseline_used baseline_free < <(awk -F '\t' -v r="$role" '$1==r{print $2,$3,$4;n++} END{if(n!=1)exit 1}' "$BASELINE") ||
      t66_die "missing unique fresh baseline: $role"
    t66_baseline_within_256m "$baseline_used" "$fs_used" &&
      t66_baseline_within_256m "$baseline_free" "$fs_free" ||
      t66_die "fresh baseline geometry drifts beyond 256MiB: $role reference_uuid=$baseline_uuid current_uuid=$fs_uuid"
  done
  printf 'STORAGE_ACTIVATION_VERIFY_PASS node=%s arm=%s instance=%s\n' "$NODE_IP" "$ARM" "$INSTANCE"
}

case "$ACTION" in
  plan) host_guard; plan;;
  activate) activate;;
  verify) host_guard; verify;;
  *) t66_die 'usage: t66-storage-activate-arm.sh plan|activate|verify RUN_ID B1c|D1 INSTANCE NODE_IP';;
esac
