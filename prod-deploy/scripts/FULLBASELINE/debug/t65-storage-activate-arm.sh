#!/usr/bin/env bash
# Activate one fresh A1/B1 local filesystem set and one fresh PD tmpfs on one node.
# mkfs is deliberately isolated here and requires an exact per-instance token.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

ACTION=${1:-plan}
RUN_ID=${2:-}
ARM=${3:-}
INSTANCE=${4:-}
NODE_IP=${5:-}
t65_check_run_id "$RUN_ID"; t65_check_cluster "$ARM"; t65_check_instance "$INSTANCE"; t65_node_suffix "$NODE_IP" >/dev/null
[[ $(t65_expected_cluster "$INSTANCE") == "$ARM" ]] || t65_die 'instance/arm mapping mismatch'

BACKING_ROOT="/mnt/jfs-tikv/jfs-t65-${RUN_ID}-backing"
MOUNT_ROOT="/mnt/jfs-t65-${RUN_ID}"
PD_MNT="$MOUNT_ROOT/pd"
STORAGE_STATE="/tmp/jfs-t65-${RUN_ID}-storage.tsv"
STATE="/tmp/jfs-t65-${RUN_ID}-${ARM}-${INSTANCE}-activation.tsv"
BASELINE="/tmp/jfs-t65-${RUN_ID}-${NODE_IP}-fresh-baseline.tsv"
QUIET_PREFIX="/tmp/jfs-t65-${RUN_ID}-${ARM}-${INSTANCE}-${NODE_IP}-nvme-quiet"
QUIET=''
TARGET_UID=$(id -u); TARGET_GID=$(id -g)
if [[ "$ARM" == A1 ]]; then
  ROLES=(shared); BACKINGS=("$BACKING_ROOT/a1-shared.img"); MOUNTS=("$MOUNT_ROOT/a1-shared"); BYTES=($((128*1024*1024*1024)))
else
  ROLES=(kv logs); BACKINGS=("$BACKING_ROOT/b1-kv.img" "$BACKING_ROOT/b1-logs.img"); MOUNTS=("$MOUNT_ROOT/b1-kv" "$MOUNT_ROOT/b1-logs"); BYTES=($((96*1024*1024*1024)) $((32*1024*1024*1024)))
fi

host_guard() {
  local actual; actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
  [[ "$actual" == "$NODE_IP" ]] || t65_die "host mismatch: expected=$NODE_IP actual=${actual:-unknown}"
}

assert_prod_tikv_stopped() {
  [[ $(systemctl is-active tikv 2>/dev/null || true) != active ]] || t65_die 'production tikv unit is active'
  ! ps -eo comm=,args= | awk '$1=="tikv-server" && $0 !~ /jfs-t65-/{found=1} END{exit !found}' ||
    t65_die 'a non-t65 tikv-server process is running'
}

assert_no_instance_process() {
  ! ps -eo args= | grep -F -- "jfs-t65-${RUN_ID}-${INSTANCE}" | grep -v -F -- 'grep -F' | grep -q . ||
    t65_die 'instance process already exists'
}

loop_for_backing() {
  sudo losetup -j "$1" | awk -F: 'NF{print $1}'
}

check_or_freeze_baseline() {
  local role=$1 mnt=$2 uuid=$3 used=$4 free=$5 old_used old_free
  if awk -F '\t' -v r="$role" '$1==r{found=1} END{exit !found}' "$BASELINE" 2>/dev/null; then
    read -r old_used old_free < <(awk -F '\t' -v r="$role" '$1==r{print $3,$4}' "$BASELINE")
    t65_baseline_within_256m "$old_used" "$used" || t65_die "fresh FS baseline used drift exceeds 256MiB: role=$role old_used=$old_used used=$used"
    t65_baseline_within_256m "$old_free" "$free" || t65_die "fresh FS baseline drift exceeds 256MiB: role=$role old_free=$old_free free=$free"
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
  t65_nvme_quiet_evidence_ok "$QUIET" > "$QUIET.summary" ||
    t65_die "underlying NVMe did not meet bounded idle profile in final 30s: $QUIET"
}

wait_fs_uuid() {
  local mnt=$1 deadline value=''
  deadline=$((SECONDS+30))
  while (( SECONDS < deadline )); do
    value=$(findmnt -rn -M "$mnt" -o UUID 2>/dev/null || true)
    [[ "$value" =~ ^[0-9A-Fa-f-]{36}$ ]] && { printf '%s\n' "$value"; return 0; }
    sleep 1
  done
  t65_die "FS UUID did not become visible within 30s: $mnt"
}

plan() {
  local i
  printf 'MODE=PLAN_ONLY\nnode=%s\nrun_id=%s\narm=%s\ninstance=%s\n' "$NODE_IP" "$RUN_ID" "$ARM" "$INSTANCE"
  printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$TARGET_UID" "$TARGET_GID" "$PD_MNT"
  printf 'sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec t65-pd-%s-%s %q\n' "$RUN_ID" "${INSTANCE,,}" "$PD_MNT"
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
  local expected="03-22b-activate-${RUN_ID}-${ARM}-${INSTANCE}-${NODE_IP}" i loop backing_real sys_backing fs_uuid free used entries state_sha
  t65_check_auth "${T65_ACTIVATE_AUTH:-}" "$expected"
  t65_record_authorization "$RUN_ID" "activate-$ARM-$INSTANCE" "$expected"
  host_guard; assert_prod_tikv_stopped; assert_no_instance_process
  [[ -s "$STORAGE_STATE" && ! -e "$STATE" ]] || t65_die 'storage state missing or current activation state exists'
  [[ $(t65_state_value "$STORAGE_STATE" meta) == "$RUN_ID" && $(t65_state_value "$STORAGE_STATE" node) == "$NODE_IP" ]] || t65_die 'storage state identity mismatch'
  ! findmnt -rn -o TARGET | awk -v p="$MOUNT_ROOT/" 'index($1,p)==1{found=1} END{exit !found}' || t65_die 'another t65 filesystem is active'
  for i in "${!BACKINGS[@]}"; do
    [[ -z $(loop_for_backing "${BACKINGS[$i]}") ]] || t65_die "backing already has loop: ${BACKINGS[$i]}"
    t65_assert_allocated_file "${BACKINGS[$i]}" "${BYTES[$i]}" >/dev/null
  done
  umask 077
  printf 'meta\t%s\nnode\t%s\narm\t%s\ninstance\t%s\nmount_root\t%s\n' "$RUN_ID" "$NODE_IP" "$ARM" "$INSTANCE" "$MOUNT_ROOT" > "$STATE"
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$PD_MNT"
  sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec "t65-pd-${RUN_ID}-${INSTANCE,,}" "$PD_MNT"
  sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$PD_MNT"
  printf 'pd\t%s\t%s\n' "t65-pd-${RUN_ID}-${INSTANCE,,}" "$PD_MNT" >> "$STATE"
  for i in "${!ROLES[@]}"; do
    loop=$(sudo losetup --find --show --nooverlap "${BACKINGS[$i]}")
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t65_die "unsafe loop result: $loop"
    backing_real=$(realpath -e -- "${BACKINGS[$i]}")
    printf 'loop\t%s\t%s\t%s\t%s\tattached\n' "${ROLES[$i]}" "$loop" "$backing_real" "${MOUNTS[$i]}" >> "$STATE"
    sys_backing=$(sudo cat "/sys/block/${loop#/dev/}/loop/backing_file")
    [[ "/$sys_backing" == "$backing_real" || "$sys_backing" == "$backing_real" ]] || t65_die "loop backing mismatch: $loop $sys_backing"
    sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$loop"
    t65_assert_allocated_file "${BACKINGS[$i]}" "${BYTES[$i]}" >/dev/null
    sudo install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "${MOUNTS[$i]}"
    sudo mount -o noatime,nodiscard "$loop" "${MOUNTS[$i]}"
    sudo chown "$TARGET_UID:$TARGET_GID" "${MOUNTS[$i]}"
    fs_uuid=$(wait_fs_uuid "${MOUNTS[$i]}")
    free=$(df -B1 --output=avail "${MOUNTS[$i]}" | awk 'NR==2{gsub(/[[:space:]]/,"");print}')
    used=$(df -B1 --output=used "${MOUNTS[$i]}" | awk 'NR==2{gsub(/[[:space:]]/,"");print}')
    entries=$(find "${MOUNTS[$i]}" -mindepth 1 -maxdepth 1 ! -name lost+found -printf . | wc -c)
    [[ "$entries" -eq 0 ]] || t65_die "fresh filesystem contains old entries: ${ROLES[$i]} count=$entries"
    check_or_freeze_baseline "${ROLES[$i]}" "${MOUNTS[$i]}" "$fs_uuid" "$used" "$free"
    printf 'fs\t%s\t%s\t%s\t%s\t%s\n' "${ROLES[$i]}" "$loop" "$fs_uuid" "$used" "$free" >> "$STATE"
    if [[ "${ROLES[$i]}" == logs ]]; then (( free >= 28*1024*1024*1024 )) || t65_die "B1 logs fresh free below 28GiB: $free"; fi
  done
  for i in "${!MOUNTS[@]}"; do sync -f "${MOUNTS[$i]}"; done
  state_sha=$(sha256sum "$STATE" | awk '{print $1}')
  [[ "$state_sha" =~ ^[0-9a-f]{64}$ ]] || t65_die 'cannot derive immutable quiet evidence identity'
  QUIET="${QUIET_PREFIX}-${state_sha:0:16}.tsv"
  [[ ! -e "$QUIET" && ! -e "$QUIET.summary" ]] || t65_die "quiet evidence path already exists: $QUIET"
  wait_nvme_quiet
  printf 'quiet_evidence\t%s\n' "$QUIET" >> "$STATE"
  printf 'quiet_summary\t%s\n' "$QUIET.summary" >> "$STATE"
  printf 'activate_epoch\t%s\n' "$(date +%s)" >> "$STATE"
  verify
  printf 'STORAGE_ACTIVATE_PASS node=%s arm=%s instance=%s state=%s\n' "$NODE_IP" "$ARM" "$INSTANCE" "$STATE"
}

verify() {
  local i role loop backing mnt actual_source actual_backing actual_uuid fs_uuid fs_used fs_free baseline_uuid baseline_used baseline_free quiet quiet_id quiet_summary rechecked_summary
  [[ -s "$STATE" ]] || t65_die "missing activation state: $STATE"
  t65_validate_activation_contract_rows "$STATE" "$RUN_ID" "$ARM" "$INSTANCE" "$NODE_IP" || t65_die 'activation state text contract mismatch'
  [[ $(t65_state_value "$STATE" meta) == "$RUN_ID" && $(t65_state_value "$STATE" node) == "$NODE_IP" &&
     $(t65_state_value "$STATE" arm) == "$ARM" && $(t65_state_value "$STATE" instance) == "$INSTANCE" ]] || t65_die 'activation identity mismatch'
  [[ $(findmnt -rn -M "$PD_MNT" -o SOURCE) == "t65-pd-${RUN_ID}-${INSTANCE,,}" ]] || t65_die 'PD tmpfs mismatch'
  quiet=$(t65_state_value "$STATE" quiet_evidence)
  quiet_id=${quiet#"${QUIET_PREFIX}-"}; quiet_id=${quiet_id%.tsv}
  [[ "$quiet" == "${QUIET_PREFIX}-${quiet_id}.tsv" && "$quiet_id" =~ ^[0-9a-f]{16}$ && -s "$quiet" ]] ||
    t65_die 'NVMe quiet evidence missing, unscoped, or mismatched'
  quiet_summary=$(t65_state_value "$STATE" quiet_summary)
  [[ "$quiet_summary" == "$quiet.summary" && -s "$quiet_summary" ]] || t65_die 'NVMe quiet summary missing or mismatched'
  rechecked_summary=$(t65_nvme_quiet_evidence_ok "$quiet") || t65_die 'NVMe quiet evidence does not meet bounded idle profile'
  [[ $(<"$quiet_summary") == "$rechecked_summary" ]] || t65_die 'NVMe quiet summary does not match raw evidence'
  [[ -s "$BASELINE" ]] || t65_die 'fresh filesystem baseline is missing'
  for i in "${!ROLES[@]}"; do
    role=${ROLES[$i]}; backing=$(realpath -e -- "${BACKINGS[$i]}"); mnt=${MOUNTS[$i]}
    loop=$(awk -F '\t' -v r="$role" '$1=="loop"&&$2==r{print $3}' "$STATE")
    [[ "$loop" =~ ^/dev/loop[0-9]+$ ]] || t65_die "bad loop state: $role"
    actual_source=$(findmnt -rn -M "$mnt" -o SOURCE); [[ "$actual_source" == "$loop" ]] || t65_die "mount source mismatch: $role"
    actual_backing=$(sudo losetup -l -n -O BACK-FILE "$loop" | awk 'NF{print}')
    [[ "$actual_backing" == "$backing" ]] || t65_die "loop backing changed: $role actual=$actual_backing expected=$backing"
    read -r fs_uuid fs_used fs_free < <(awk -F '\t' -v r="$role" '$1=="fs"&&$2==r{print $4,$5,$6}' "$STATE") ||
      t65_die "missing complete FS state: $role"
    actual_uuid=$(findmnt -rn -M "$mnt" -o UUID)
    [[ "$actual_uuid" == "$fs_uuid" ]] || t65_die "mounted FS UUID mismatch: $role"
    read -r baseline_uuid baseline_used baseline_free < <(awk -F '\t' -v r="$role" '$1==r{print $2,$3,$4;n++} END{if(n!=1)exit 1}' "$BASELINE") ||
      t65_die "missing unique fresh baseline: $role"
    t65_baseline_within_256m "$baseline_used" "$fs_used" &&
      t65_baseline_within_256m "$baseline_free" "$fs_free" ||
      t65_die "fresh baseline geometry drifts beyond 256MiB: $role reference_uuid=$baseline_uuid current_uuid=$fs_uuid"
  done
  printf 'STORAGE_ACTIVATION_VERIFY_PASS node=%s arm=%s instance=%s\n' "$NODE_IP" "$ARM" "$INSTANCE"
}

case "$ACTION" in
  plan) host_guard; plan;;
  activate) activate;;
  verify) host_guard; verify;;
  *) t65_die 'usage: t65-storage-activate-arm.sh plan|activate|verify RUN_ID A1|B1 INSTANCE NODE_IP';;
esac
