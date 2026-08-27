#!/usr/bin/env bash
# Restore an immutable seed into one fresh metadata cluster, optionally mount and clone its workset.
# No format, layout write, GC deletion, volume destroy, or cluster lifecycle is performed here.
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
case "$INSTANCE" in RESTORE-CANARY|RESTORE-PREFLIGHT|GC-CANARY|GC-PREFLIGHT|G0[1-8]|R0[1-8]) ;; *)
  t64_die 'restore script received a non-restore instance';; esac
[[ $(t64_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || t64_die 'frozen cluster mapping mismatch'

FLAVOR=$(t64_seed_flavor "$INSTANCE")
ROOT="/tmp/production/opencode-t3.22-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
SEED_DIR=$(t64_seed_dir "$RUN_ID" "$FLAVOR")
DUMP="$SEED_DIR/seed-meta.json.gz"
META=$(t64_meta_url "$RUN_ID" "$INSTANCE")
VOLUME=$(t64_seed_name "$RUN_ID" "$FLAVOR")
MNT="/tmp/jfs-t64-${RUN_ID}-mnt-${INSTANCE}"
SOURCE_DIR="$MNT/seed_layout"
TEST_DIR="$MNT/test_dir"
RESTORE_STATE="$OUT/restore.tsv"
STATE="$OUT/volume.tsv"
PRIVATE_CONF="$OUT/ceph-t64.conf"
t64_assert_abs_scoped_path "$MNT" "$RUN_ID"
t64_require_tools "$T64_JUICEFS_BIN" curl python3 sha256sum mountpoint head fio comm cut paste sort

record_cmd() {
  local arg
  for arg in "$@"; do printf '%q ' "$arg" >> "$OUT/commands.sh"; done
  printf '\n' >> "$OUT/commands.sh"
}

verify_seed_bundle() {
  [[ -s "$SEED_DIR/SEED_BUNDLE_PASS" && -s "$SEED_DIR/seed.tsv" && -s "$DUMP" &&
     -s "$SEED_DIR/seed-meta.sha256" && -s "$SEED_DIR/seed-layout-relative.tsv" &&
     -s "$SEED_DIR/seed-content-anchors.tsv" ]] ||
    t64_die "seed bundle incomplete: $SEED_DIR"
  (cd "$SEED_DIR" && sha256sum -c seed-meta.sha256 >/dev/null) || t64_die 'seed dump SHA mismatch'
  [[ $(awk -F '\t' '$1=="volume_name"{print $2}' "$SEED_DIR/seed.tsv") == "$VOLUME" ]] || t64_die 'seed bundle name mismatch'
  [[ $(awk -F '\t' '$1=="juicefs_md5"{print $2}' "$SEED_DIR/seed.tsv") == "$T64_JUICEFS_MD5" ]] || t64_die 'seed bundle binary MD5 mismatch'
  [[ $(sha256sum "$SEED_DIR/seed-layout-relative.tsv" | awk '{print $1}') == \
     "$(awk -F '\t' '$1=="layout_sha256"{print $2}' "$SEED_DIR/seed.tsv")" ]] || t64_die 'seed layout manifest SHA mismatch'
  [[ $(sha256sum "$SEED_DIR/seed-content-anchors.tsv" | awk '{print $1}') == \
     "$(awk -F '\t' '$1=="anchor_sha256"{print $2}' "$SEED_DIR/seed.tsv")" ]] || t64_die 'seed content-anchor SHA mismatch'
}

write_content_anchors() {
  local root=$1 output=$2
  python3 - "$root" "$SEED_DIR/seed-content-anchors.tsv" > "$output" <<'PY'
from pathlib import Path
import hashlib, sys
root=Path(sys.argv[1]); contract=Path(sys.argv[2])
for raw in contract.read_text().splitlines():
    name, off, _ = raw.split("\t")
    with (root/name).open("rb") as f:
        f.seek(int(off)); data=f.read(262144)
    assert len(data)==262144
    print(f"{name}\t{off}\t{hashlib.sha256(data).hexdigest()}")
PY
}

verify_cluster() {
  local node
  for node in "${T64_NODES[@]}"; do
    curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T64_TIKV_STATUS_PORT}/config" >/dev/null ||
      t64_die "temporary TiKV unavailable: $node"
  done
  [[ $(sudo ceph health) == HEALTH_OK ]] || t64_die 'Ceph is not HEALTH_OK'
}

mount_pid_pairs() {
  local pid ppid
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || continue
    [[ $(readlink -f "/proc/$pid/exe" 2>/dev/null || true) == "$T64_JUICEFS_BIN" ]] || continue
    ppid=$(t64_proc_ppid "$pid") || continue
    printf '%s\t%s\n' "$pid" "$ppid"
  done < <(pgrep -af -- "$T64_JUICEFS_BIN" 2>/dev/null | awk -v m="$MNT" '$0 ~ / mount / && $NF==m {print $1}')
}

load_seed() {
  [[ ${T64_RESTORE_AUTH:-} == "03-22-restore-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_RESTORE_AUTH=03-22-restore-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ ! -e "$RESTORE_STATE" && ! -e "$STATE" && ! -e "$MNT" ]] || t64_die 'restore state or mount path already exists'
  [[ $(md5sum "$T64_JUICEFS_BIN" | awk '{print $1}') == "$T64_JUICEFS_MD5" ]] || t64_die 'JuiceFS binary MD5 mismatch'
  verify_seed_bundle
  verify_cluster
  umask 077
  mkdir -p "$OUT"
  printf '#!/usr/bin/env bash\n# Recorded 03-22 seed restore commands; no password.\n' > "$OUT/commands.sh"
  cp /etc/ceph/ceph.conf "$PRIVATE_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
  export CEPH_CONF="$PRIVATE_CONF"
  if "$T64_JUICEFS_BIN" status "$META" >/dev/null 2>&1; then t64_die "restore META is not empty: $META"; fi
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T64_JUICEFS_BIN" load "$META" "$DUMP"
  "$T64_JUICEFS_BIN" load "$META" "$DUMP" > "$OUT/load.stdout" 2> "$OUT/load.stderr"
  "$T64_JUICEFS_BIN" status "$META" > "$OUT/status-post-load.json"
  local identity uuid name
  identity=$(t64_status_identity "$OUT/status-post-load.json") || t64_die 'invalid restored seed identity'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$uuid" == "$(awk -F '\t' '$1=="uuid"{print $2}' "$SEED_DIR/seed.tsv")" && "$name" == "$VOLUME" ]] ||
    t64_die 'restored seed UUID/name differs from frozen bundle'
  t64_status_has_zero_sessions "$OUT/status-post-load.json" || t64_die 'fresh restore unexpectedly has sessions'
  printf 'meta\t%s\ncluster\t%s\ninstance\t%s\nflavor\t%s\nvolume_name\t%s\nuuid\t%s\ndump_sha256\t%s\nrestore_epoch\t%s\n' \
    "$META" "$CLUSTER" "$INSTANCE" "$FLAVOR" "$VOLUME" "$uuid" \
    "$(sha256sum "$DUMP" | awk '{print $1}')" "$(date +%s)" > "$RESTORE_STATE"
  printf 'RESTORE_LOAD_PASS instance=%s cluster=%s uuid=%s\n' "$INSTANCE" "$CLUSTER" "$uuid"
}

mount_restored() {
  case "$INSTANCE" in GC-CANARY|GC-PREFLIGHT|G0[1-8]) t64_die 'GC restore must never be mounted';; esac
  [[ ${T64_RESTORE_MOUNT_AUTH:-} == "03-22-restore-mount-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_RESTORE_MOUNT_AUTH=03-22-restore-mount-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ -s "$RESTORE_STATE" && ! -e "$STATE" && ! -e "$MNT" ]] || t64_die 'restore state missing or mount already exists'
  verify_seed_bundle
  verify_cluster
  mkdir -p "$MNT"
  export CEPH_CONF="$PRIVATE_CONF"
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$T64_JUICEFS_BIN" mount -d --max-uploads 150 \
    --cache-size 0 --max-fuse-io 256K "$META" "$MNT"
  "$T64_JUICEFS_BIN" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K \
    "$META" "$MNT" > "$OUT/mount.log" 2>&1
  sleep 5
  mountpoint -q "$MNT" || t64_die 'restored seed mount failed'
  local pairs pid ppid selected start uuid candidate parent
  pairs=$(mount_pid_pairs); selected=$(t64_select_child_pid "$pairs"); pid=$selected
  t64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META" || t64_die 'restored mount worker lacks exact META'
  t64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$MNT" || t64_die 'restored mount worker lacks exact MNT'
  { printf 'pid\tppid\tselected_worker\n'
    while IFS=$'\t' read -r candidate parent; do
      printf '%s\t%s\t%s\n' "$candidate" "$parent" "$([[ "$candidate" == "$pid" ]] && printf yes || printf no)"
    done <<< "$pairs"
  } > "$OUT/mount-processes.tsv"
  start=$(awk '{print $22}' "/proc/$pid/stat")
  uuid=$(awk -F '\t' '$1=="uuid"{print $2}' "$RESTORE_STATE")
  printf 'meta\t%s\ncluster\t%s\ninstance\t%s\nvolume_name\t%s\nmount\t%s\nuuid\t%s\npid\t%s\nstarttime\t%s\nexe_md5\t%s\nstate_origin\trestored-seed\n' \
    "$META" "$CLUSTER" "$INSTANCE" "$VOLUME" "$MNT" "$uuid" "$pid" "$start" \
    "$(md5sum /proc/$pid/exe | awk '{print $1}')" > "$STATE"
  printf 'RESTORE_MOUNT_PASS instance=%s uuid=%s pid=%s\n' "$INSTANCE" "$uuid" "$pid"
}

verify_mount() {
  [[ -s "$RESTORE_STATE" && -s "$STATE" ]] || t64_die 'restore/mount state missing'
  mountpoint -q "$MNT" || t64_die 'restored mount is absent'
  local pid start md5 pairs selected identity uuid name
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$STATE")
  start=$(awk -F '\t' '$1=="starttime"{print $2}' "$STATE")
  md5=$(awk -F '\t' '$1=="exe_md5"{print $2}' "$STATE")
  [[ -r "/proc/$pid/stat" && $(awk '{print $22}' "/proc/$pid/stat") == "$start" ]] || t64_die 'restored mount PID changed'
  [[ $(md5sum "/proc/$pid/exe" | awk '{print $1}') == "$md5" ]] || t64_die 'restored mount binary changed'
  pairs=$(mount_pid_pairs); selected=$(t64_select_child_pid "$pairs"); [[ "$selected" == "$pid" ]] || t64_die 'restored mount worker changed'
  export CEPH_CONF="$PRIVATE_CONF"
  "$T64_JUICEFS_BIN" status "$META" > "$OUT/status-verify.json"
  identity=$(t64_status_identity "$OUT/status-verify.json") || t64_die 'invalid identity during restore verify'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$uuid" == "$(awk -F '\t' '$1=="uuid"{print $2}' "$RESTORE_STATE")" && "$name" == "$VOLUME" ]] || t64_die 'restore identity changed'
  verify_cluster
  printf 'RESTORE_VERIFY_PASS instance=%s pid=%s\n' "$INSTANCE" "$pid"
}

# A clone's pathname/size/content and inode independence are causal workload
# properties.  The numeric inode assigned to a particular pathname is not:
# `juicefs clone -p` may allocate the same fresh inode set in a different
# pathname order in each restored metadata namespace.
verify_formal_clone_semantics() {
  local reference=$1 rows source_unique target_unique overlap reference_unique reference_overlap per_path_matches
  [[ -s "$reference" && -s "$OUT/seed-source-files.tsv" && -s "$OUT/clone-relative.tsv" ]] ||
    t64_die 'formal clone semantic inputs are incomplete'
  for file in "$reference" "$OUT/seed-source-files.tsv" "$OUT/clone-relative.tsv"; do
    awk -F '\t' 'NF!=3 || $1=="" || $2!~/^[0-9]+$/ || $3!~/^[0-9]+$/{bad=1} END{exit bad}' "$file" ||
      t64_die "invalid clone contract row: $file"
  done
  diff -u <(cut -f1,2 "$reference") <(cut -f1,2 "$OUT/clone-relative.tsv") \
    > "$OUT/clone-contract-name-size.diff" || t64_die 'formal clone name/size differs from preflight contract'
  rows=$(wc -l < "$OUT/clone-relative.tsv")
  reference_unique=$(cut -f3 "$reference" | sort -u | wc -l)
  source_unique=$(cut -f3 "$OUT/seed-source-files.tsv" | sort -u | wc -l)
  target_unique=$(cut -f3 "$OUT/clone-relative.tsv" | sort -u | wc -l)
  reference_overlap=$(comm -12 \
    <(cut -f3 "$OUT/seed-source-files.tsv" | sort -u) \
    <(cut -f3 "$reference" | sort -u) | wc -l)
  overlap=$(comm -12 \
    <(cut -f3 "$OUT/seed-source-files.tsv" | sort -u) \
    <(cut -f3 "$OUT/clone-relative.tsv" | sort -u) | wc -l)
  per_path_matches=$(paste "$reference" "$OUT/clone-relative.tsv" |
    awk -F '\t' '$1==$4 && $2==$5 && $3==$6{n++} END{print n+0}')
  [[ "$rows" -eq 256 && "$reference_unique" -eq 256 && "$source_unique" -eq 256 &&
     "$target_unique" -eq 256 && "$reference_overlap" -eq 0 && "$overlap" -eq 0 ]] ||
    t64_die "clone inode identity requires 256 unique reference/source/target inodes and zero overlap: rows=$rows reference=$reference_unique source=$source_unique target=$target_unique reference_overlap=$reference_overlap target_overlap=$overlap"
  printf 'policy\tpath-size-anchor-exact_inode-unique-disjoint\nfiles\t%s\nreference_unique_inodes\t%s\nsource_unique_inodes\t%s\ntarget_unique_inodes\t%s\nsource_reference_inode_overlap\t%s\nsource_target_inode_overlap\t%s\nper_path_inode_matches_reference\t%s\n' \
    "$rows" "$reference_unique" "$source_unique" "$target_unique" "$reference_overlap" "$overlap" "$per_path_matches" \
    > "$OUT/clone-inode-invariants.tsv"
}

finalize_clone_evidence() {
  [[ ! -e "$OUT/jobfiles" && ! -e "$OUT/layout-files.tsv" && ! -e "$OUT/layout-files.sha256" &&
     ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" ]] ||
    t64_die 'clone runtime evidence or marker already exists'
  bash "$SCRIPT_DIR/t64-gen-jobfiles.sh" "$OUT/jobfiles" "$TEST_DIR" > "$OUT/jobfiles.log"
  find "$TEST_DIR" -maxdepth 1 -type f -printf '%p\t%s\t%i\n' | sort > "$OUT/layout-files.tsv"
  sha256sum "$OUT/layout-files.tsv" > "$OUT/layout-files.sha256"
  if [[ "$INSTANCE" == RESTORE-PREFLIGHT ]]; then
    [[ ! -e "$SEED_DIR/formal-clone-contract.tsv" ]] || t64_die 'formal clone contract already exists'
    cp "$OUT/clone-relative.tsv" "$SEED_DIR/formal-clone-contract.tsv"
    sha256sum "$SEED_DIR/formal-clone-contract.tsv" > "$SEED_DIR/formal-clone-contract.sha256"
  fi
  printf '%s\n' "$(date +%s)" > "$OUT/CLONE_PASS"
  printf '%s\n' "$(date +%s)" > "$OUT/LAYOUT_PASS"
}

clone_workset() {
  case "$INSTANCE" in RESTORE-CANARY|RESTORE-PREFLIGHT|R0[1-8]) ;; *) t64_die 'instance is not allowed to clone a workset';; esac
  verify_mount
  [[ ! -e "$TEST_DIR" && ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" ]] || t64_die 'clone target or marker already exists'
  [[ -d "$SOURCE_DIR" ]] || t64_die 'seed source directory missing after restore'
  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/seed-source-files.tsv"
  cmp -s "$SEED_DIR/seed-layout-relative.tsv" "$OUT/seed-source-files.tsv" || t64_die 'restored seed source manifest differs from frozen seed'
  write_content_anchors "$SOURCE_DIR" "$OUT/seed-source-anchors.tsv"
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/seed-source-anchors.tsv" || t64_die 'restored seed source content anchors differ from frozen seed'
  record_cmd "$T64_JUICEFS_BIN" clone -p "$SOURCE_DIR" "$TEST_DIR"
  "$T64_JUICEFS_BIN" clone -p "$SOURCE_DIR" "$TEST_DIR" > "$OUT/clone.stdout" 2> "$OUT/clone.stderr"
  [[ -d "$TEST_DIR" ]] || t64_die 'clone target directory missing'
  find "$TEST_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/clone-relative.tsv"
  diff -u <(cut -f1,2 "$SEED_DIR/seed-layout-relative.tsv") <(cut -f1,2 "$OUT/clone-relative.tsv") > "$OUT/clone-name-size.diff" ||
    t64_die 'clone name/size contract differs from seed'
  write_content_anchors "$TEST_DIR" "$OUT/clone-content-anchors.tsv"
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/clone-content-anchors.tsv" || t64_die 'clone content anchors differ from immutable seed'
  if t64_is_formal_arm "$INSTANCE"; then
    [[ -s "$SEED_DIR/formal-clone-contract.tsv" && -s "$SEED_DIR/formal-clone-contract.sha256" ]] || t64_die 'formal clone preflight contract missing'
    (cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) || t64_die 'formal clone contract SHA mismatch'
    verify_formal_clone_semantics "$SEED_DIR/formal-clone-contract.tsv"
  elif [[ "$INSTANCE" == RESTORE-PREFLIGHT ]]; then
    verify_formal_clone_semantics "$SEED_DIR/seed-layout-relative.tsv"
  fi
  finalize_clone_evidence
  printf 'CLONE_WORKSET_PASS instance=%s files=%s source=immutable-seed\n' "$INSTANCE" "$(wc -l < "$OUT/clone-relative.tsv")"
}

adopt_clone_state() {
  t64_is_formal_arm "$INSTANCE" || t64_die 'clone state adoption is restricted to formal R01..R08 arms'
  [[ ${T64_CLONE_ADOPT_AUTH:-} == "03-22-clone-adopt-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_CLONE_ADOPT_AUTH=03-22-clone-adopt-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  verify_mount
  verify_seed_bundle
  [[ -d "$SOURCE_DIR" && -d "$TEST_DIR" && ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" ]] ||
    t64_die 'clone adoption requires an existing first-attempt target and no success markers'
  [[ -e "$OUT/clone.stdout" && ! -s "$OUT/clone.stdout" && -e "$OUT/clone.stderr" && ! -s "$OUT/clone.stderr" ]] ||
    t64_die 'clone adoption requires zero-length stdout/stderr from the first clone command'
  grep -Fq -- "$T64_JUICEFS_BIN clone -p $SOURCE_DIR $TEST_DIR" "$OUT/commands.sh" ||
    t64_die 'recorded first clone command is missing or differs'
  ! pgrep -x fio >/dev/null || t64_die 'fio exists; refuse clone state adoption'
  [[ -s "$OUT/seed-source-files.tsv" && -s "$OUT/seed-source-anchors.tsv" &&
     -s "$OUT/clone-relative.tsv" && -s "$OUT/clone-content-anchors.tsv" ]] ||
    t64_die 'first clone evidence is incomplete'

  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/adopt-seed-source-files.tsv"
  find "$TEST_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/adopt-clone-relative.tsv"
  write_content_anchors "$SOURCE_DIR" "$OUT/adopt-seed-source-anchors.tsv"
  write_content_anchors "$TEST_DIR" "$OUT/adopt-clone-content-anchors.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$OUT/adopt-seed-source-files.tsv" || t64_die 'seed source changed after failed clone gate'
  cmp -s "$OUT/clone-relative.tsv" "$OUT/adopt-clone-relative.tsv" || t64_die 'clone target changed after failed clone gate'
  cmp -s "$OUT/seed-source-anchors.tsv" "$OUT/adopt-seed-source-anchors.tsv" || t64_die 'seed source anchors changed after failed clone gate'
  cmp -s "$OUT/clone-content-anchors.tsv" "$OUT/adopt-clone-content-anchors.tsv" || t64_die 'clone anchors changed after failed clone gate'
  cmp -s "$SEED_DIR/seed-layout-relative.tsv" "$OUT/adopt-seed-source-files.tsv" || t64_die 'adopted source manifest differs from frozen seed'
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/adopt-seed-source-anchors.tsv" || t64_die 'adopted source anchors differ from frozen seed'
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/adopt-clone-content-anchors.tsv" || t64_die 'adopted clone anchors differ from frozen seed'
  [[ -s "$SEED_DIR/formal-clone-contract.tsv" && -s "$SEED_DIR/formal-clone-contract.sha256" ]] ||
    t64_die 'formal clone preflight contract missing'
  (cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) || t64_die 'formal clone contract SHA mismatch'
  verify_formal_clone_semantics "$SEED_DIR/formal-clone-contract.tsv"
  printf 'instance\t%s\npolicy\tpath-size-anchor-exact_inode-unique-disjoint\nreference_sha256\t%s\nactual_sha256\t%s\nfirst_clone_stdout_bytes\t0\nfirst_clone_stderr_bytes\t0\n' \
    "$INSTANCE" "$(sha256sum "$SEED_DIR/formal-clone-contract.tsv" | awk '{print $1}')" \
    "$(sha256sum "$OUT/clone-relative.tsv" | awk '{print $1}')" > "$OUT/clone-adopt.tsv"
  finalize_clone_evidence
  printf '%s\n' "$(date +%s)" > "$OUT/CLONE_ADOPT_PASS"
  printf 'CLONE_ADOPT_PASS instance=%s files=%s policy=path-size-anchor-exact_inode-unique-disjoint\n' \
    "$INSTANCE" "$(wc -l < "$OUT/clone-relative.tsv")"
}

cow_canary() {
  [[ "$INSTANCE" == RESTORE-CANARY && "$FLAVOR" == canary ]] || t64_die 'COW canary is restricted to RESTORE-CANARY'
  verify_mount
  [[ -s "$OUT/CLONE_PASS" && ! -e "$OUT/COW_CANARY_PASS" ]] || t64_die 'clone gate missing or COW canary already ran'
  local src="$SOURCE_DIR/canary.bin" dst="$TEST_DIR/canary.bin" src_before src_after dst_before dst_after
  src_before=$(head -c 262144 "$src" | sha256sum | awk '{print $1}')
  dst_before=$(head -c 262144 "$dst" | sha256sum | awk '{print $1}')
  [[ "$src_before" == "$dst_before" ]] || t64_die 'canary clone content differs before COW write'
  record_cmd fio --name=cow-canary "--filename=$dst" --rw=write --bs=256k --offset=0 --size=256k \
    --ioengine=libaio --direct=1 --fallocate=none --allow_file_create=0 --buffer_pattern=0x5a
  fio --name=cow-canary --filename="$dst" --rw=write --bs=256k --offset=0 --size=256k \
    --ioengine=libaio --direct=1 --fallocate=none --allow_file_create=0 --buffer_pattern=0x5a \
    > "$OUT/cow-fio.stdout" 2> "$OUT/cow-fio.stderr"
  grep -q 'err= 0' "$OUT/cow-fio.stdout" || t64_die 'COW canary fio lacks err=0'
  src_after=$(head -c 262144 "$src" | sha256sum | awk '{print $1}')
  dst_after=$(head -c 262144 "$dst" | sha256sum | awk '{print $1}')
  [[ "$src_after" == "$src_before" && "$dst_after" != "$dst_before" ]] || t64_die 'COW canary did not preserve immutable seed source'
  printf 'source_before\t%s\nsource_after\t%s\ntarget_before\t%s\ntarget_after\t%s\n' \
    "$src_before" "$src_after" "$dst_before" "$dst_after" > "$OUT/cow-canary.tsv"
  printf '%s\n' "$(date +%s)" > "$OUT/COW_CANARY_PASS"
  printf 'COW_CANARY_PASS instance=%s source_unchanged=yes target_changed=yes\n' "$INSTANCE"
}

umount_restored() {
  verify_mount
  if t64_is_formal_arm "$INSTANCE"; then [[ -s "$OUT/arm-analysis.json" ]] || t64_die 'formal arm analysis missing before umount'; fi
  if [[ "$INSTANCE" == RESTORE-PREFLIGHT ]]; then [[ -s "$SEED_DIR/formal-clone-contract.tsv" ]] || t64_die 'preflight clone contract missing'; fi
  if [[ "$INSTANCE" == RESTORE-CANARY ]]; then [[ -s "$OUT/COW_CANARY_PASS" ]] || t64_die 'COW canary gate missing'; fi
  record_cmd "$T64_JUICEFS_BIN" umount "$MNT"
  "$T64_JUICEFS_BIN" umount "$MNT" > "$OUT/umount.log" 2>&1 || t64_die 'graceful restored-volume umount failed'
  mountpoint -q "$MNT" && t64_die 'restored mount remains after umount'
  printf '%s\n' "$(date +%s)" > "$OUT/UMOUNT_EPOCH"
  rmdir "$MNT"
  printf 'RESTORE_UMOUNT_PASS instance=%s\n' "$INSTANCE"
}

abort_umount_restored() {
  local deadline
  t64_is_formal_arm "$INSTANCE" || t64_die 'abort-umount is restricted to formal R01..R08 arms'
  [[ ${T64_ABORT_UMOUNT_AUTH:-} == "03-22-abort-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    t64_die "set exact T64_ABORT_UMOUNT_AUTH=03-22-abort-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  [[ -s "$OUT/READY_FOR_FIO" && -s "$OUT/arm/phase.tsv" && ! -e "$OUT/arm-analysis.json" &&
     ! -e "$OUT/ABORT_UMOUNT_PASS" && ! -e "$OUT/UMOUNT_EPOCH" ]] ||
    t64_die 'abort-umount requires one failed formal arm and no prior umount marker'
  grep -Fq $'\tlaunch' "$OUT/arm/phase.tsv" || t64_die 'failed arm lacks fio launch evidence'
  ! pgrep -x fio >/dev/null || t64_die 'fio still exists; preserve the failed arm'
  verify_mount
  verify_seed_bundle

  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/abort-seed-source-post.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$OUT/abort-seed-source-post.tsv" ||
    t64_die 'immutable seed source identity changed in failed arm'
  write_content_anchors "$SOURCE_DIR" "$OUT/abort-seed-anchors-post.tsv"
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/abort-seed-anchors-post.tsv" ||
    t64_die 'immutable seed source content changed in failed arm'
  find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
    -printf '%p\t%s\t%i\n' | sort > "$OUT/abort-layout-post.tsv"
  cmp -s "$OUT/layout-files.tsv" "$OUT/abort-layout-post.tsv" ||
    t64_die 'failed arm changed target path/size/inode identity'

  record_cmd "$T64_JUICEFS_BIN" umount "$MNT"
  "$T64_JUICEFS_BIN" umount "$MNT" > "$OUT/abort-umount.log" 2>&1 ||
    t64_die 'graceful abort umount failed'
  mountpoint -q "$MNT" && t64_die 'restored mount remains after abort umount'
  deadline=$((SECONDS + 30))
  while [[ -n $(mount_pid_pairs) && $SECONDS -lt $deadline ]]; do sleep 1; done
  [[ -z $(mount_pid_pairs) ]] || t64_die 'JuiceFS mount process remains after abort umount'
  printf 'epoch\t%s\ninstance\t%s\ncluster\t%s\nreason\tformal-arm-evidence-failure\n' \
    "$(date +%s)" "$INSTANCE" "$CLUSTER" > "$OUT/abort-umount.tsv"
  cut -f2 "$OUT/abort-umount.tsv" | head -1 > "$OUT/UMOUNT_EPOCH"
  rmdir "$MNT"
  printf '%s\n' "$(date +%s)" > "$OUT/ABORT_UMOUNT_PASS"
  printf 'ABORT_UMOUNT_PASS instance=%s cluster=%s evidence=INVALID\n' "$INSTANCE" "$CLUSTER"
}

case "$ACTION" in
  load) load_seed;;
  mount) mount_restored;;
  verify) verify_mount;;
  clone) clone_workset;;
  adopt-clone-state) adopt_clone_state;;
  cow-canary) cow_canary;;
  umount) umount_restored;;
  abort-umount) abort_umount_restored;;
  *) t64_die 'usage: t64-restore-volume.sh load|mount|verify|clone|adopt-clone-state|cow-canary|umount|abort-umount RUN_ID A|B INSTANCE';;
esac
