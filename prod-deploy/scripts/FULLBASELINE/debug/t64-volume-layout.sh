#!/usr/bin/env bash
# Client-side temporary JuiceFS volume lifecycle and layout for one 03-22 instance.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
t64_check_run_id "$RUN_ID"
t64_check_cluster "$CLUSTER"
t64_check_instance "$INSTANCE"
t64_is_formal_arm "$INSTANCE" &&
  t64_die 'per-arm format/layout/destroy is retired; formal arms must use the frozen seed restore protocol'

OUT="/tmp/production/opencode-t3.22-${RUN_ID}/instances/${INSTANCE}"
MNT="/tmp/jfs-t64-${RUN_ID}-mnt-${INSTANCE}"
TEST_DIR="$MNT/test_dir"
STATE="$OUT/volume.tsv"
DESTROYED="$OUT/volume.destroyed.tsv"
PRIVATE_CONF="$OUT/ceph-t64.conf"
META=$(t64_meta_url "$RUN_ID" "$INSTANCE")
VOLUME="jfs-t64-${RUN_ID}-${INSTANCE,,}"
t64_assert_abs_scoped_path "$MNT" "$RUN_ID"
t64_require_tools "$T64_JUICEFS_BIN" fio curl python3 sha256sum mountpoint truncate

record_cmd() {
  local arg
  for arg in "$@"; do printf '%q ' "$arg" >> "$OUT/commands.sh"; done
  printf '\n' >> "$OUT/commands.sh"
}

[[ $(t64_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || t64_die "order/cluster mismatch for $INSTANCE"

mount_pid_pairs() {
  # This is the t47 rule already validated on client 157: mount -d leaves a
  # daemon parent plus its I/O worker child with identical cmdlines. Match the
  # exact final mountpoint argument first, then validate the executable and
  # let t64_select_child_pid choose the unique child by PPID topology.
  local pid ppid
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || continue
    [[ $(readlink -f "/proc/$pid/exe" 2>/dev/null || true) == "$T64_JUICEFS_BIN" ]] || continue
    ppid=$(t64_proc_ppid "$pid") || continue
    printf '%s\t%s\n' "$pid" "$ppid"
  done < <(pgrep -af -- "$T64_JUICEFS_BIN" 2>/dev/null | \
    awk -v m="$MNT" '$0 ~ / mount / && $NF==m {print $1}')
}

mount_pid() {
  local pairs
  pairs=$(mount_pid_pairs)
  t64_select_child_pid "$pairs"
}

inspect_mount_pid() {
  mountpoint -q "$MNT" || t64_die "inspect target is not mounted: $MNT"
  local pairs pid ppid selected exe cmdline
  pairs=$(mount_pid_pairs)
  printf 'MOUNT_PID_INSPECT_BEGIN instance=%s mount=%s\n' "$INSTANCE" "$MNT"
  printf 'candidate_pairs_shell=%q\n' "$pairs"
  while IFS=$'\t' read -r pid ppid; do
    printf 'candidate pid=%q ppid=%q' "$pid" "$ppid"
    if [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]]; then
      exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
      printf ' proc_ppid=%q exe=%q cmdline=%q\n' "$(t64_proc_ppid "$pid" || true)" "$exe" "$cmdline"
    else
      printf ' proc=unavailable\n'
    fi
  done <<< "$pairs"
  selected=$(t64_select_child_pid "$pairs")
  printf 'MOUNT_PID_INSPECT_PASS selected_worker=%s\n' "$selected"
}

write_mount_state() {
  local origin=$1 pairs=$2 pid=$3 uuid=$4 candidate parent start
  { printf 'pid\tppid\tselected_worker\n'
    while IFS=$'\t' read -r candidate parent; do
      printf '%s\t%s\t%s\n' "$candidate" "$parent" "$([[ "$candidate" == "$pid" ]] && printf yes || printf no)"
    done <<< "$pairs"
  } > "$OUT/mount-processes.tsv"
  start=$(awk '{print $22}' "/proc/$pid/stat")
  printf 'meta\t%s\ncluster\t%s\ninstance\t%s\nvolume_name\t%s\nmount\t%s\nuuid\t%s\npid\t%s\nstarttime\t%s\nexe_md5\t%s\ncandidate_pairs\t%s\nstate_origin\t%s\n' \
    "$META" "$CLUSTER" "$INSTANCE" "$VOLUME" "$MNT" "$uuid" "$pid" "$start" \
    "$(md5sum /proc/$pid/exe | awk '{print $1}')" "$(tr '\n' ',' <<< "$pairs")" "$origin" > "$STATE"
}

adopt_mount_state() {
  [[ "$INSTANCE" == SMOKE-A2 || "$INSTANCE" == SMOKE-B2 ]] ||
    t64_die 'state adoption is restricted to repair smoke instances'
  [[ ${T64_VOLUME_ADOPT_AUTH:-} == "03-22-volume-adopt-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_VOLUME_ADOPT_AUTH=03-22-volume-adopt-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ ! -e "$STATE" && ! -e "$DESTROYED" ]] || t64_die 'state/destroyed marker already exists'
  [[ ! -e "$OUT/UMOUNT_EPOCH" && ! -e "$OUT/LAYOUT_PASS" && ! -e "$TEST_DIR" ]] ||
    t64_die 'adoption forbidden after umount/layout/data creation'
  mountpoint -q "$MNT" || t64_die 'adoption target is not mounted'
  [[ -s "$PRIVATE_CONF" && -s "$OUT/commands.sh" && -s "$OUT/pool-pre-format.tsv" ]] ||
    t64_die 'original format provenance is incomplete'
  [[ -e "$OUT/format.log" && -e "$OUT/mount.log" ]] || t64_die 'original format/mount logs are missing'
  local quoted_meta quoted_mnt
  printf -v quoted_meta '%q' "$META"
  printf -v quoted_mnt '%q' "$MNT"
  grep -Fq -- "$quoted_meta" "$OUT/commands.sh" || t64_die 'commands.sh lacks exact shell-escaped META'
  grep -Fq -- "$quoted_mnt" "$OUT/commands.sh" || t64_die 'commands.sh lacks exact shell-escaped MNT'
  [[ $(md5sum "$T64_JUICEFS_BIN" | awk '{print $1}') == "$T64_JUICEFS_MD5" ]] ||
    t64_die 'JuiceFS binary MD5 mismatch during adoption'
  verify_cluster

  local pairs pid uuid live_name identity
  pairs=$(mount_pid_pairs)
  pid=$(t64_select_child_pid "$pairs")
  t64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META" || t64_die 'selected worker lacks exact META argument'
  t64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$MNT" || t64_die 'selected worker lacks exact MNT argument'
  CEPH_CONF="$PRIVATE_CONF" "$T64_JUICEFS_BIN" status "$META" > "$OUT/status-adopt.json"
  identity=$(t64_status_identity "$OUT/status-adopt.json") || t64_die 'invalid Setting.UUID/Name during adoption'
  IFS=$'\t' read -r uuid live_name <<< "$identity"
  [[ "$live_name" == "$VOLUME" ]] || t64_die "live volume Name mismatch during adoption: expected=$VOLUME actual=$live_name"
  findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE,OPTIONS > "$OUT/findmnt-adopt.tsv"
  write_mount_state pid-gate-recovery "$pairs" "$pid" "$uuid"
  printf 'ADOPT_MOUNT_STATE_PASS instance=%s uuid=%s pid=%s state=%s\n' "$INSTANCE" "$uuid" "$pid" "$STATE"
}

verify_cluster() {
  local node
  for node in "${T64_NODES[@]}"; do
    curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T64_TIKV_STATUS_PORT}/config" >/dev/null ||
      t64_die "temporary TiKV unavailable: $node"
  done
  [[ $(sudo ceph health) == HEALTH_OK ]] || t64_die 'Ceph is not HEALTH_OK'
}

format_mount() {
  [[ ${T64_VOLUME_AUTH:-} == "03-22-volume-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_VOLUME_AUTH=03-22-volume-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ ! -e "$STATE" && ! -e "$DESTROYED" ]] || t64_die 'volume state already exists'
  [[ ! -e "$MNT" ]] || t64_die "mount path already exists: $MNT"
  [[ $(md5sum "$T64_JUICEFS_BIN" | awk '{print $1}') == "$T64_JUICEFS_MD5" ]] || t64_die 'JuiceFS binary MD5 mismatch'
  verify_cluster
  mkdir -p "$OUT" "$MNT"
  printf '#!/usr/bin/env bash\n# 03-22 actual commands; password intentionally omitted.\n' > "$OUT/commands.sh"
  cp /etc/ceph/ceph.conf "$PRIVATE_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
  export CEPH_CONF="$PRIVATE_CONF"
  sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next((x for x in d["pools"] if x["name"]=="juicefs-data"),None)
assert p is not None
s=p["stats"]; print("%s\t%s\t%s" % (s["objects"],s["stored"],s["bytes_used"]))' \
    > "$OUT/pool-pre-format.tsv"
  if "$T64_JUICEFS_BIN" status "$META" >/dev/null 2>&1; then
    t64_die "metadata namespace already exists: $META"
  fi
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T64_JUICEFS_BIN" format --storage ceph \
    --bucket "ceph://${T64_POOL}" --access-key ceph --secret-key client.juicefs \
    --block-size 256K --trash-days 0 "$META" "$VOLUME"
  "$T64_JUICEFS_BIN" format --storage ceph --bucket "ceph://${T64_POOL}" \
    --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
    "$META" "$VOLUME" > "$OUT/format.log" 2>&1
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T64_JUICEFS_BIN" mount -d --max-uploads 150 \
    --cache-size 0 --max-fuse-io 256K "$META" "$MNT"
  "$T64_JUICEFS_BIN" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K \
    "$META" "$MNT" > "$OUT/mount.log" 2>&1
  sleep 5
  mountpoint -q "$MNT" || t64_die 'mount failed'
  local pid uuid live_name identity pairs
  pairs=$(mount_pid_pairs)
  pid=$(t64_select_child_pid "$pairs")
  "$T64_JUICEFS_BIN" status "$META" > "$OUT/status-format.json"
  identity=$(t64_status_identity "$OUT/status-format.json") || t64_die 'invalid Setting.UUID/Name after format'
  IFS=$'\t' read -r uuid live_name <<< "$identity"
  [[ "$live_name" == "$VOLUME" ]] || t64_die "volume Name mismatch after format: expected=$VOLUME actual=$live_name"
  write_mount_state normal-format "$pairs" "$pid" "$uuid"
  printf 'FORMAT_MOUNT_PASS instance=%s uuid=%s pid=%s\n' "$INSTANCE" "$uuid" "$pid"
}

verify_mount() {
  [[ -s "$STATE" ]] || t64_die 'missing volume state'
  mountpoint -q "$MNT" || t64_die 'mountpoint missing'
  local pid expected_start expected_md5 expected_name
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$STATE")
  expected_start=$(awk -F '\t' '$1=="starttime"{print $2}' "$STATE")
  expected_md5=$(awk -F '\t' '$1=="exe_md5"{print $2}' "$STATE")
  expected_name=$(awk -F '\t' '$1=="volume_name"{print $2}' "$STATE")
  [[ "$expected_name" == "$VOLUME" ]] || t64_die 'state volume Name mismatch'
  [[ -r /proc/$pid/stat && $(awk '{print $22}' /proc/$pid/stat) == "$expected_start" ]] || t64_die 'mount PID/starttime changed'
  [[ $(md5sum /proc/$pid/exe | awk '{print $1}') == "$expected_md5" ]] || t64_die 'mount executable changed'
  [[ $(mount_pid) == "$pid" ]] || t64_die 'mount commandline identity changed'
  t64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META" || t64_die 'mount META argument changed'
  t64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$MNT" || t64_die 'mount MNT argument changed'
  verify_cluster
  printf 'VERIFY_MOUNT_PASS instance=%s pid=%s\n' "$INSTANCE" "$pid"
}

layout() {
  [[ "$INSTANCE" != SMOKE-* ]] || t64_die 'smoke instance must not create layout'
  verify_mount
  [[ ! -e "$OUT/LAYOUT_PASS" ]] || t64_die 'layout already completed'
  mkdir -p "$TEST_DIR" "$OUT/jobfiles" "$OUT/layout-bw"
  bash "$SCRIPT_DIR/t64-gen-jobfiles.sh" "$OUT/jobfiles" "$TEST_DIR" > "$OUT/jobfiles.log"
  record_cmd fio "$OUT/jobfiles/layout-B0.fio" --write_bw_log="$OUT/layout-bw/layout"
  fio "$OUT/jobfiles/layout-B0.fio" --write_bw_log="$OUT/layout-bw/layout" \
    > "$OUT/layout-fio.stdout" 2> "$OUT/layout-fio.stderr"
  grep -q 'err= 0' "$OUT/layout-fio.stdout" || t64_die 'layout fio lacks err=0'
  local count path
  local -a expected_paths=()
  count=$(find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) | wc -l)
  (( count == 256 )) || t64_die "layout file count=$count, expected 256"

  # fio's filesize is an address-space bound, not a preallocation request.
  # Each job intentionally writes only one 512 MiB extent, so jobs at offset 0
  # otherwise leave a 512 MiB logical file. Extend only the 256 paths frozen in
  # the generated jobfile; truncate adds a sparse half and does not add another
  # 128 GiB of object data.
  mapfile -t expected_paths < <(awk -F= '$1=="filename"{print substr($0,index($0,"=")+1)}' \
    "$OUT/jobfiles/layout-B0.fio" | sort -u)
  (( ${#expected_paths[@]} == 256 )) || t64_die 'layout jobfile does not name 256 unique files'
  for path in "${expected_paths[@]}"; do
    [[ "$path" == "$TEST_DIR"/* && -f "$path" && ! -L "$path" ]] ||
      t64_die "unsafe or missing layout path: $path"
    record_cmd truncate -s 1073741824 -- "$path"
    truncate -s 1073741824 -- "$path"
  done

  find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
    -printf '%p\t%s\t%i\n' | sort > "$OUT/layout-files.tsv"
  awk -F '\t' '$2!=1073741824{bad=1} END{exit bad}' "$OUT/layout-files.tsv" || t64_die 'layout contains non-1GiB file'
  sha256sum "$OUT/layout-files.tsv" > "$OUT/layout-files.sha256"
  printf '%s\n' "$(date +%s)" > "$OUT/LAYOUT_PASS"
  printf 'LAYOUT_PASS instance=%s files=%s active_extent_GiB=128\n' "$INSTANCE" "$count"
}

umount_volume() {
  verify_mount
  record_cmd "$T64_JUICEFS_BIN" umount "$MNT"
  "$T64_JUICEFS_BIN" umount "$MNT" > "$OUT/umount.log" 2>&1 || t64_die 'graceful JuiceFS umount failed; no lazy/force fallback used'
  mountpoint -q "$MNT" && t64_die 'mount remains after graceful umount'
  printf '%s\n' "$(date +%s)" > "$OUT/UMOUNT_EPOCH"
  rmdir "$MNT"
  printf 'UMOUNT_PASS instance=%s\n' "$INSTANCE"
}

destroy_volume() {
  [[ ${T64_VOLUME_DESTROY_AUTH:-} == "03-22-volume-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_VOLUME_DESTROY_AUTH=03-22-volume-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ -s "$STATE" && -s "$OUT/UMOUNT_EPOCH" ]] || t64_die 'state or UMOUNT_EPOCH missing'
  ! mountpoint -q "$MNT" || t64_die 'mount still active'
  local then now uuid live_uuid live_name identity
  then=$(<"$OUT/UMOUNT_EPOCH"); now=$(date +%s)
  (( now - then >= 65 )) || t64_die "session TTL not elapsed; retry after $((65-now+then)) seconds"
  uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$STATE")
  CEPH_CONF="$PRIVATE_CONF" "$T64_JUICEFS_BIN" status "$META" > "$OUT/status-pre-destroy.json"
  identity=$(t64_status_identity "$OUT/status-pre-destroy.json") || t64_die 'invalid Setting.UUID/Name before destroy'
  IFS=$'\t' read -r live_uuid live_name <<< "$identity"
  [[ "$live_name" == "$VOLUME" ]] || t64_die "volume Name changed; refuse destroy expected=$VOLUME actual=$live_name"
  [[ "$live_uuid" == "$uuid" ]] || t64_die "UUID changed; refuse destroy expected=$uuid actual=$live_uuid"
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T64_JUICEFS_BIN" destroy "$META" "$uuid" --yes
  CEPH_CONF="$PRIVATE_CONF" "$T64_JUICEFS_BIN" destroy "$META" "$uuid" --yes > "$OUT/destroy.log" 2>&1
  { printf 'destroy_epoch\t%s\n' "$now"; cat "$STATE"; } > "$DESTROYED"
  rm -f "$STATE"
  printf 'DESTROY_VOLUME_PASS instance=%s uuid=%s\n' "$INSTANCE" "$uuid"
}

case "$ACTION" in
  inspect-mount-pid) inspect_mount_pid;;
  adopt-mount-state) adopt_mount_state;;
  format-mount) format_mount;;
  verify) verify_mount;;
  layout) layout;;
  umount) umount_volume;;
  destroy) destroy_volume;;
  *) t64_die 'usage: t64-volume-layout.sh inspect-mount-pid|adopt-mount-state|format-mount|verify|layout|umount|destroy RUN_ID A|B INSTANCE';;
esac
