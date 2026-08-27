#!/usr/bin/env bash
# Create exactly one immutable JuiceFS seed dataset, then freeze its metadata dump.
# This script never restores an arm, runs formal fio, performs GC deletion, or destroys data.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
t66_check_run_id "$RUN_ID"
t66_check_cluster "$CLUSTER"
t66_check_instance "$INSTANCE"
[[ "$INSTANCE" == SEED-CANARY || "$INSTANCE" == SEED-FORMAL ]] ||
  t66_die 'seed script accepts only SEED-CANARY or SEED-FORMAL'
[[ "$CLUSTER" == B1c ]] || t66_die 'seed creation is frozen to cluster B1c'

FLAVOR=$(t66_seed_flavor "$INSTANCE")
ROOT="/tmp/production/opencode-t3.22c-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
SEED_DIR=$(t66_seed_dir "$RUN_ID" "$FLAVOR")
MNT="/tmp/jfs-t66-${RUN_ID}-mnt-${INSTANCE}"
SOURCE_DIR="$MNT/seed_layout"
STATE="$OUT/volume.tsv"
PRIVATE_CONF="$OUT/ceph-t66.conf"
META=$(t66_meta_url "$RUN_ID" "$INSTANCE")
VOLUME=$(t66_seed_name "$RUN_ID" "$FLAVOR")
DUMP="$SEED_DIR/seed-meta.json.gz"
t66_assert_abs_scoped_path "$MNT" "$RUN_ID"
t66_require_tools "$T66_JUICEFS_BIN" fio curl python3 sha256sum mountpoint truncate sync

record_cmd() {
  local arg
  for arg in "$@"; do printf '%q ' "$arg" >> "$OUT/commands.sh"; done
  printf '\n' >> "$OUT/commands.sh"
}

verify_cluster() {
  local node
  for node in "${T66_NODES[@]}"; do
    curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T66_TIKV_STATUS_PORT}/config" >/dev/null ||
      t66_die "temporary TiKV unavailable: $node"
  done
  [[ $(sudo ceph health) == HEALTH_OK ]] || t66_die 'Ceph is not HEALTH_OK'
}

mount_pid_pairs() {
  local pid ppid
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || continue
    [[ $(readlink -f "/proc/$pid/exe" 2>/dev/null || true) == "$T66_JUICEFS_BIN" ]] || continue
    ppid=$(t66_proc_ppid "$pid") || continue
    printf '%s\t%s\n' "$pid" "$ppid"
  done < <(pgrep -af -- "$T66_JUICEFS_BIN" 2>/dev/null | awk -v m="$MNT" '$0 ~ / mount / && $NF==m {print $1}')
}

write_mount_state() {
  local pairs=$1 pid=$2 uuid=$3 candidate parent start
  { printf 'pid\tppid\tselected_worker\n'
    while IFS=$'\t' read -r candidate parent; do
      printf '%s\t%s\t%s\n' "$candidate" "$parent" "$([[ "$candidate" == "$pid" ]] && printf yes || printf no)"
    done <<< "$pairs"
  } > "$OUT/mount-processes.tsv"
  start=$(awk '{print $22}' "/proc/$pid/stat")
  printf 'meta\t%s\ncluster\t%s\ninstance\t%s\nvolume_name\t%s\nmount\t%s\nuuid\t%s\npid\t%s\nstarttime\t%s\nexe_md5\t%s\nstate_origin\tseed-format\n' \
    "$META" "$CLUSTER" "$INSTANCE" "$VOLUME" "$MNT" "$uuid" "$pid" "$start" \
    "$(md5sum /proc/$pid/exe | awk '{print $1}')" > "$STATE"
}

verify_mount() {
  [[ -s "$STATE" ]] || t66_die 'seed volume state missing'
  mountpoint -q "$MNT" || t66_die 'seed mount is not active'
  local pid start md5 pairs selected
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$STATE")
  start=$(awk -F '\t' '$1=="starttime"{print $2}' "$STATE")
  md5=$(awk -F '\t' '$1=="exe_md5"{print $2}' "$STATE")
  [[ -r "/proc/$pid/stat" && $(awk '{print $22}' "/proc/$pid/stat") == "$start" ]] || t66_die 'seed mount PID changed'
  [[ $(md5sum "/proc/$pid/exe" | awk '{print $1}') == "$md5" ]] || t66_die 'seed mount binary changed'
  pairs=$(mount_pid_pairs); selected=$(t66_select_child_pid "$pairs")
  [[ "$selected" == "$pid" ]] || t66_die 'seed mount worker changed'
  t66_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META" || t66_die 'seed mount META changed'
  t66_nul_file_has_exact_arg "/proc/$pid/cmdline" "$MNT" || t66_die 'seed mount path changed'
  verify_cluster
}

format_mount() {
  [[ ${T66_SEED_FORMAT_AUTH:-} == "03-22c-seed-format-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t66_die "set exact T66_SEED_FORMAT_AUTH=03-22c-seed-format-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  t66_record_authorization "$RUN_ID" seed-format "$T66_SEED_FORMAT_AUTH"
  [[ ! -e "$STATE" && ! -e "$SEED_DIR/SEED_BUNDLE_PASS" && ! -e "$MNT" ]] ||
    t66_die 'seed state, bundle, or mount path already exists'
  [[ $(md5sum "$T66_JUICEFS_BIN" | awk '{print $1}') == "$T66_JUICEFS_MD5" ]] || t66_die 'JuiceFS binary MD5 mismatch'
  verify_cluster
  umask 077
  mkdir -p "$OUT" "$SEED_DIR" "$MNT"
  printf '#!/usr/bin/env bash\n# Recorded 03-22c seed commands; no password.\n' > "$OUT/commands.sh"
  cp /etc/ceph/ceph.conf "$PRIVATE_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
  export CEPH_CONF="$PRIVATE_CONF"
  sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next(x for x in d["pools"] if x["name"]=="juicefs-data"); s=p["stats"]
print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))' > "$SEED_DIR/pool-pre-format.tsv"
  if "$T66_JUICEFS_BIN" status "$META" >/dev/null 2>&1; then t66_die "seed META already exists: $META"; fi
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T66_JUICEFS_BIN" format --storage ceph \
    --bucket "ceph://${T66_POOL}" --access-key ceph --secret-key client.juicefs \
    --block-size 256K --trash-days 0 "$META" "$VOLUME"
  "$T66_JUICEFS_BIN" format --storage ceph --bucket "ceph://${T66_POOL}" \
    --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
    "$META" "$VOLUME" > "$OUT/format.log" 2>&1
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T66_JUICEFS_BIN" mount -d --max-uploads 150 \
    --cache-size 0 --max-fuse-io 256K "$META" "$MNT"
  "$T66_JUICEFS_BIN" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K \
    "$META" "$MNT" > "$OUT/mount.log" 2>&1
  sleep 5
  mountpoint -q "$MNT" || t66_die 'seed mount failed'
  local pairs pid identity uuid name
  pairs=$(mount_pid_pairs); pid=$(t66_select_child_pid "$pairs")
  "$T66_JUICEFS_BIN" status "$META" > "$OUT/status-format.json"
  identity=$(t66_status_identity "$OUT/status-format.json") || t66_die 'invalid seed identity after format'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$name" == "$VOLUME" ]] || t66_die 'seed volume name mismatch'
  write_mount_state "$pairs" "$pid" "$uuid"
  printf 'SEED_FORMAT_MOUNT_PASS instance=%s uuid=%s pid=%s\n' "$INSTANCE" "$uuid" "$pid"
}

layout_seed() {
  [[ ${T66_SEED_LAYOUT_AUTH:-} == "03-22c-seed-layout-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] || t66_die "set exact T66_SEED_LAYOUT_AUTH=03-22c-seed-layout-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  t66_record_authorization "$RUN_ID" seed-layout "$T66_SEED_LAYOUT_AUTH"
  verify_mount
  [[ ! -e "$OUT/LAYOUT_PASS" && ! -e "$SOURCE_DIR" ]] || t66_die 'seed layout already exists'
  mkdir -p "$SOURCE_DIR" "$OUT/jobfiles" "$OUT/layout-bw"
  if [[ "$FLAVOR" == formal ]]; then
    bash "$SCRIPT_DIR/t66-gen-jobfiles.sh" "$OUT/jobfiles" "$SOURCE_DIR" > "$OUT/jobfiles.log"
    record_cmd fio "$OUT/jobfiles/layout-B0.fio" "--write_bw_log=$OUT/layout-bw/layout"
    fio "$OUT/jobfiles/layout-B0.fio" "--write_bw_log=$OUT/layout-bw/layout" \
      > "$OUT/layout-fio.stdout" 2> "$OUT/layout-fio.stderr"
    grep -q 'err= 0' "$OUT/layout-fio.stdout" || t66_die 'formal seed layout fio lacks err=0'
    mapfile -t paths < <(awk -F= '$1=="filename"{print substr($0,index($0,"=")+1)}' "$OUT/jobfiles/layout-B0.fio" | sort -u)
    (( ${#paths[@]} == 256 )) || t66_die 'formal seed jobfile does not contain 256 unique files'
    for path in "${paths[@]}"; do
      [[ "$path" == "$SOURCE_DIR"/* && -f "$path" && ! -L "$path" ]] || t66_die "unsafe seed layout path: $path"
      record_cmd truncate -s 1073741824 -- "$path"
      truncate -s 1073741824 -- "$path"
    done
  else
    local path="$SOURCE_DIR/canary.bin"
    record_cmd fio --name=seed-canary "--filename=$path" --rw=write --bs=256k --ioengine=libaio \
      --direct=1 --fallocate=none --size=16m --end_fsync=1
    fio --name=seed-canary --filename="$path" --rw=write --bs=256k --ioengine=libaio \
      --direct=1 --fallocate=none --size=16m --end_fsync=1 > "$OUT/layout-fio.stdout" 2> "$OUT/layout-fio.stderr"
    grep -q 'err= 0' "$OUT/layout-fio.stdout" || t66_die 'canary seed layout fio lacks err=0'
    record_cmd truncate -s 33554432 -- "$path"
    truncate -s 33554432 -- "$path"
  fi
  sync -f "$SOURCE_DIR"
  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/seed-layout-relative.tsv"
  local expected=1 size=33554432
  if [[ "$FLAVOR" == formal ]]; then expected=256; size=1073741824; fi
  [[ $(wc -l < "$OUT/seed-layout-relative.tsv") -eq "$expected" ]] || t66_die 'seed layout file count mismatch'
  awk -F '\t' -v s="$size" '$2!=s{bad=1} END{exit bad}' "$OUT/seed-layout-relative.tsv" || t66_die 'seed layout size mismatch'
  sha256sum "$OUT/seed-layout-relative.tsv" > "$OUT/seed-layout-relative.sha256"
  python3 - "$SOURCE_DIR" "$FLAVOR" "$OUT/jobfiles/layout-B0.fio" > "$OUT/seed-content-anchors.tsv" <<'PY'
from pathlib import Path
import hashlib, sys
root, flavor, jobfile = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
items=[]
if flavor == "formal":
    cur={}
    for raw in jobfile.read_text().splitlines():
        if raw.startswith("["):
            if "filename" in cur: items.append((Path(cur["filename"]).name, int(cur["offset"])))
            cur={}
        elif "=" in raw:
            k,v=raw.split("=",1); cur[k]=v
    if "filename" in cur: items.append((Path(cur["filename"]).name, int(cur["offset"])))
else:
    items=[("canary.bin", 0)]
assert len(items) == (256 if flavor == "formal" else 1)
for name, off in sorted(items):
    with (root/name).open("rb") as f:
        f.seek(off); data=f.read(262144)
    assert len(data)==262144
    print(f"{name}\t{off}\t{hashlib.sha256(data).hexdigest()}")
PY
  sha256sum "$OUT/seed-content-anchors.tsv" > "$OUT/seed-content-anchors.sha256"
  printf '%s\n' "$(date +%s)" > "$OUT/LAYOUT_PASS"
  printf 'SEED_LAYOUT_PASS instance=%s files=%s\n' "$INSTANCE" "$expected"
}

umount_seed() {
  [[ ${T66_SEED_UMOUNT_AUTH:-} == "03-22c-seed-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] || t66_die "set exact T66_SEED_UMOUNT_AUTH=03-22c-seed-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  t66_record_authorization "$RUN_ID" seed-umount "$T66_SEED_UMOUNT_AUTH"
  verify_mount
  [[ -s "$OUT/LAYOUT_PASS" ]] || t66_die 'seed layout gate missing'
  record_cmd "$T66_JUICEFS_BIN" umount "$MNT"
  "$T66_JUICEFS_BIN" umount "$MNT" > "$OUT/umount.log" 2>&1 || t66_die 'graceful seed umount failed'
  mountpoint -q "$MNT" && t66_die 'seed mount remains after umount'
  printf '%s\n' "$(date +%s)" > "$OUT/UMOUNT_EPOCH"
  rmdir "$MNT"
  printf 'SEED_UMOUNT_PASS instance=%s\n' "$INSTANCE"
}

dump_seed() {
  [[ ${T66_SEED_DUMP_AUTH:-} == "03-22c-seed-dump-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t66_die "set exact T66_SEED_DUMP_AUTH=03-22c-seed-dump-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  t66_record_authorization "$RUN_ID" seed-dump "$T66_SEED_DUMP_AUTH"
  [[ -s "$STATE" && -s "$OUT/LAYOUT_PASS" && -s "$OUT/READY_FOR_FIO" && -s "$OUT/UMOUNT_EPOCH" ]] ||
    t66_die 'seed layout/reset/umount evidence incomplete'
  [[ ! -e "$DUMP" && ! -e "$SEED_DIR/SEED_BUNDLE_PASS" ]] || t66_die 'seed bundle already exists'
  ! mountpoint -q "$MNT" || t66_die 'seed is still mounted'
  local then now identity uuid name
  then=$(<"$OUT/UMOUNT_EPOCH"); now=$(date +%s)
  (( now - then >= 65 )) || t66_die "seed session TTL not elapsed; retry after $((65-now+then)) seconds"
  export CEPH_CONF="$PRIVATE_CONF"
  "$T66_JUICEFS_BIN" status "$META" > "$OUT/status-pre-dump.json"
  identity=$(t66_status_identity "$OUT/status-pre-dump.json") || t66_die 'invalid seed identity before dump'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$uuid" == "$(awk -F '\t' '$1=="uuid"{print $2}' "$STATE")" && "$name" == "$VOLUME" ]] || t66_die 'seed UUID/name changed before dump'
  t66_status_has_zero_sessions "$OUT/status-pre-dump.json" || t66_die 'seed has a live session; refuse dump'
  umask 077
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T66_JUICEFS_BIN" dump --keep-secret-key "$META" "$DUMP"
  "$T66_JUICEFS_BIN" dump --keep-secret-key "$META" "$DUMP" > "$OUT/dump.stdout" 2> "$OUT/dump.stderr"
  [[ -s "$DUMP" && $(stat -c '%a' "$DUMP") == 600 ]] || t66_die 'seed dump missing or not mode 600'
  cp "$OUT/seed-layout-relative.tsv" "$SEED_DIR/seed-layout-relative.tsv"
  cp "$OUT/seed-layout-relative.sha256" "$SEED_DIR/seed-layout-relative.sha256"
  cp "$OUT/seed-content-anchors.tsv" "$SEED_DIR/seed-content-anchors.tsv"
  cp "$OUT/seed-content-anchors.sha256" "$SEED_DIR/seed-content-anchors.sha256"
  sha256sum "$DUMP" > "$SEED_DIR/seed-meta.sha256"
  JFS_GC_SKIPPEDTIME=0 "$T66_JUICEFS_BIN" gc "$META" > "$SEED_DIR/gc-baseline.log" 2>&1
  t66_gc_summary "$SEED_DIR/gc-baseline.log" > "$SEED_DIR/gc-baseline.tsv"
  [[ $(awk -F '\t' '$1=="leaked"{print $2}' "$SEED_DIR/gc-baseline.tsv") == 0 ]] || t66_die 'seed has leaked objects'
  [[ $(awk -F '\t' '$1=="pending"{print $2}' "$SEED_DIR/gc-baseline.tsv") == 0 ]] || t66_die 'seed has pending-delete objects'
  [[ $(awk -F '\t' '$1=="skipped"{print $2}' "$SEED_DIR/gc-baseline.tsv") == 0 ]] || t66_die 'seed GC baseline skipped objects'
  sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next(x for x in d["pools"] if x["name"]=="juicefs-data"); s=p["stats"]
print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))' > "$SEED_DIR/pool-seed.tsv"
  printf 'flavor\t%s\nvolume_name\t%s\nuuid\t%s\nsource_dir\t/seed_layout\ndump\t%s\ndump_sha256\t%s\nlayout_sha256\t%s\nanchor_sha256\t%s\njuicefs_md5\t%s\n' \
    "$FLAVOR" "$VOLUME" "$uuid" "$DUMP" "$(sha256sum "$DUMP" | awk '{print $1}')" \
    "$(sha256sum "$SEED_DIR/seed-layout-relative.tsv" | awk '{print $1}')" \
    "$(sha256sum "$SEED_DIR/seed-content-anchors.tsv" | awk '{print $1}')" "$T66_JUICEFS_MD5" > "$SEED_DIR/seed.tsv"
  printf '%s\n' "$(date +%s)" > "$SEED_DIR/SEED_BUNDLE_PASS"
  printf 'SEED_DUMP_PASS instance=%s flavor=%s uuid=%s dump_sha256=%s\n' \
    "$INSTANCE" "$FLAVOR" "$uuid" "$(sha256sum "$DUMP" | awk '{print $1}')"
}

case "$ACTION" in
  format-mount) format_mount;;
  layout) layout_seed;;
  verify) verify_mount; printf 'SEED_VERIFY_PASS instance=%s\n' "$INSTANCE";;
  umount) umount_seed;;
  dump) dump_seed;;
  *) t66_die 'usage: t66-seed-volume.sh format-mount|layout|verify|umount|dump RUN_ID B1c SEED-CANARY|SEED-FORMAL';;
esac
