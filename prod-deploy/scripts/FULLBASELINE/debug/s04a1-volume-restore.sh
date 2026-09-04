#!/usr/bin/env bash
# Restore an immutable seed into one fresh metadata cluster, optionally mount and clone its workset.
# No format, layout write, GC deletion, volume destroy, or cluster lifecycle is performed here.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/s04a1-runtime-common.sh"

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
s04a1_check_run_id "$RUN_ID"
s04a1_check_cluster "$CLUSTER"
s04a1_check_instance "$INSTANCE"
case "$INSTANCE" in RESTORE-CANARY-C|RESTORE-CANARY-L|RESTORE-PREFLIGHT-C|RESTORE-PREFLIGHT-L|ARM-CANARY-C|ARM-CANARY-L|GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|GC-ARM-CANARY-C|GC-ARM-CANARY-L|G0[1-8]|R0[1-8]) ;; *)
  s04a1_die 'restore script received a non-restore instance';; esac
[[ $(s04a1_expected_cluster "$INSTANCE") == "$CLUSTER" ]] || s04a1_die 'frozen cluster mapping mismatch'

FLAVOR=$(s04a1_seed_flavor "$INSTANCE")
ROOT="/tmp/production/opencode-04-2-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
SEED_DIR=$(s04a1_seed_dir "$RUN_ID" "$FLAVOR")
DUMP="$SEED_DIR/seed-meta.json.gz"
META=$(s04a1_meta_url "$RUN_ID" "$INSTANCE")
VOLUME=$(s04a1_seed_name "$RUN_ID" "$FLAVOR")
MNT="/tmp/jfs-s04a1-${RUN_ID}-mnt-${INSTANCE}"
SOURCE_DIR="$MNT/seed_layout"
TEST_DIR="$MNT/test_dir"
RESTORE_STATE="$OUT/restore.tsv"
STATE="$OUT/volume.tsv"
PRIVATE_CONF="$OUT/ceph-s04a1.conf"
s04a1_assert_abs_scoped_path "$MNT" "$RUN_ID"
s04a1_require_tools "$S04A1_JUICEFS_BIN" curl python3 sha256sum mountpoint head fio comm cut paste sort

record_cmd() {
  local arg
  for arg in "$@"; do printf '%q ' "$arg" >> "$OUT/commands.sh"; done
  printf '\n' >> "$OUT/commands.sh"
}

verify_seed_bundle() {
  [[ -s "$SEED_DIR/SEED_BUNDLE_PASS" && -s "$SEED_DIR/seed.tsv" && -s "$DUMP" &&
     -s "$SEED_DIR/seed-meta.sha256" && -s "$SEED_DIR/seed-layout-relative.tsv" &&
     -s "$SEED_DIR/seed-content-anchors.tsv" ]] ||
    s04a1_die "seed bundle incomplete: $SEED_DIR"
  (cd "$SEED_DIR" && sha256sum -c seed-meta.sha256 >/dev/null) || s04a1_die 'seed dump SHA mismatch'
  [[ $(awk -F '\t' '$1=="volume_name"{print $2}' "$SEED_DIR/seed.tsv") == "$VOLUME" ]] || s04a1_die 'seed bundle name mismatch'
  [[ $(awk -F '\t' '$1=="juicefs_md5"{print $2}' "$SEED_DIR/seed.tsv") == "$S04A1_JUICEFS_MD5" ]] || s04a1_die 'seed bundle binary MD5 mismatch'
  [[ $(sha256sum "$SEED_DIR/seed-layout-relative.tsv" | awk '{print $1}') == \
     "$(awk -F '\t' '$1=="layout_sha256"{print $2}' "$SEED_DIR/seed.tsv")" ]] || s04a1_die 'seed layout manifest SHA mismatch'
  [[ $(sha256sum "$SEED_DIR/seed-content-anchors.tsv" | awk '{print $1}') == \
     "$(awk -F '\t' '$1=="anchor_sha256"{print $2}' "$SEED_DIR/seed.tsv")" ]] || s04a1_die 'seed content-anchor SHA mismatch'
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
  for node in "${S04A1_NODES[@]}"; do
    curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${S04A1_TIKV_STATUS_PORT}/config" >/dev/null ||
      s04a1_die "temporary TiKV unavailable: $node"
  done
  s04a1_ceph_health_test_ok || s04a1_die 'Ceph health is outside the approved test/scrub state'
}

mount_pid_pairs() {
  local pid ppid
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || continue
    [[ $(readlink -f "/proc/$pid/exe" 2>/dev/null || true) == "$S04A1_JUICEFS_BIN" ]] || continue
    ppid=$(s04a1_proc_ppid "$pid") || continue
    printf '%s\t%s\n' "$pid" "$ppid"
  done < <(pgrep -af -- "$S04A1_JUICEFS_BIN" 2>/dev/null | awk -v m="$MNT" '$0 ~ / mount / && $NF==m {print $1}')
}

load_seed() {
  [[ ${S04A1_RESTORE_AUTH:-} == "04-2-restore-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_RESTORE_AUTH=04-2-restore-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" restore-load "$S04A1_RESTORE_AUTH"
  [[ ! -e "$RESTORE_STATE" && ! -e "$STATE" && ! -e "$MNT" ]] || s04a1_die 'restore state or mount path already exists'
  [[ $(md5sum "$S04A1_JUICEFS_BIN" | awk '{print $1}') == "$S04A1_JUICEFS_MD5" ]] || s04a1_die 'JuiceFS binary MD5 mismatch'
  verify_seed_bundle
  verify_cluster
  umask 077
  mkdir -p "$OUT"
  printf '#!/usr/bin/env bash\n# Recorded 04-2 seed restore commands; no password.\n' > "$OUT/commands.sh"
  cp /etc/ceph/ceph.conf "$PRIVATE_CONF"
  printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$PRIVATE_CONF"
  export CEPH_CONF="$PRIVATE_CONF"
  if "$S04A1_JUICEFS_BIN" status "$META" >/dev/null 2>&1; then s04a1_die "restore META is not empty: $META"; fi
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" load "$META" "$DUMP"
  "$S04A1_JUICEFS_BIN" load "$META" "$DUMP" > "$OUT/load.stdout" 2> "$OUT/load.stderr"
  "$S04A1_JUICEFS_BIN" status "$META" > "$OUT/status-post-load.json"
  local identity uuid name
  identity=$(s04a1_status_identity "$OUT/status-post-load.json") || s04a1_die 'invalid restored seed identity'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$uuid" == "$(awk -F '\t' '$1=="uuid"{print $2}' "$SEED_DIR/seed.tsv")" && "$name" == "$VOLUME" ]] ||
    s04a1_die 'restored seed UUID/name differs from frozen bundle'
  s04a1_status_has_zero_sessions "$OUT/status-post-load.json" || s04a1_die 'fresh restore unexpectedly has sessions'
  printf 'meta\t%s\ncluster\t%s\ninstance\t%s\nflavor\t%s\nvolume_name\t%s\nuuid\t%s\ndump_sha256\t%s\nrestore_epoch\t%s\n' \
    "$META" "$CLUSTER" "$INSTANCE" "$FLAVOR" "$VOLUME" "$uuid" \
    "$(sha256sum "$DUMP" | awk '{print $1}')" "$(date +%s)" > "$RESTORE_STATE"
  printf 'RESTORE_LOAD_PASS instance=%s cluster=%s uuid=%s\n' "$INSTANCE" "$CLUSTER" "$uuid"
}

mount_restored() {
  case "$INSTANCE" in GC-CANARY|GC-PREFLIGHT|GC-ARM-CANARY|GC-ARM-CANARY-C|GC-ARM-CANARY-L|G0[1-8]) s04a1_die 'GC restore must never be mounted';; esac
  [[ ${S04A1_RESTORE_MOUNT_AUTH:-} == "04-2-restore-mount-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_RESTORE_MOUNT_AUTH=04-2-restore-mount-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" restore-mount "$S04A1_RESTORE_MOUNT_AUTH"
  [[ -s "$RESTORE_STATE" && ! -e "$STATE" && ! -e "$MNT" ]] || s04a1_die 'restore state missing or mount already exists'
  verify_seed_bundle
  verify_cluster
  mkdir -p "$MNT"
  export CEPH_CONF="$PRIVATE_CONF"
  record_cmd env "CEPH_CONF=$PRIVATE_CONF" "$S04A1_JUICEFS_BIN" mount -d --max-uploads 150 \
    --cache-size 0 --max-fuse-io 256K "$META" "$MNT"
  "$S04A1_JUICEFS_BIN" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K \
    "$META" "$MNT" > "$OUT/mount.log" 2>&1
  sleep 5
  mountpoint -q "$MNT" || s04a1_die 'restored seed mount failed'
  local pairs pid ppid selected start uuid candidate parent
  pairs=$(mount_pid_pairs); selected=$(s04a1_select_child_pid "$pairs"); pid=$selected
  s04a1_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META" || s04a1_die 'restored mount worker lacks exact META'
  s04a1_nul_file_has_exact_arg "/proc/$pid/cmdline" "$MNT" || s04a1_die 'restored mount worker lacks exact MNT'
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
  [[ -s "$RESTORE_STATE" && -s "$STATE" ]] || s04a1_die 'restore/mount state missing'
  mountpoint -q "$MNT" || s04a1_die 'restored mount is absent'
  local pid start md5 pairs selected identity uuid name
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$STATE")
  start=$(awk -F '\t' '$1=="starttime"{print $2}' "$STATE")
  md5=$(awk -F '\t' '$1=="exe_md5"{print $2}' "$STATE")
  [[ -r "/proc/$pid/stat" && $(awk '{print $22}' "/proc/$pid/stat") == "$start" ]] || s04a1_die 'restored mount PID changed'
  [[ $(md5sum "/proc/$pid/exe" | awk '{print $1}') == "$md5" ]] || s04a1_die 'restored mount binary changed'
  pairs=$(mount_pid_pairs); selected=$(s04a1_select_child_pid "$pairs"); [[ "$selected" == "$pid" ]] || s04a1_die 'restored mount worker changed'
  export CEPH_CONF="$PRIVATE_CONF"
  "$S04A1_JUICEFS_BIN" status "$META" > "$OUT/status-verify.json"
  identity=$(s04a1_status_identity "$OUT/status-verify.json") || s04a1_die 'invalid identity during restore verify'
  IFS=$'\t' read -r uuid name <<< "$identity"
  [[ "$uuid" == "$(awk -F '\t' '$1=="uuid"{print $2}' "$RESTORE_STATE")" && "$name" == "$VOLUME" ]] || s04a1_die 'restore identity changed'
  verify_cluster
  printf 'RESTORE_VERIFY_PASS instance=%s pid=%s\n' "$INSTANCE" "$pid"
}

# A clone's pathname/size/content and source-target inode independence are
# causal workload properties.  The numeric inode assigned to a particular
# pathname is not.  Dump/load is allowed to preserve the immutable source
# inode set, while `juicefs clone -p` may allocate the target inode set in a
# different pathname order in each restored metadata namespace.
verify_formal_clone_semantics() {
  local reference=$1 rows source_unique target_unique overlap reference_unique reference_overlap per_path_matches
  [[ -s "$reference" && -s "$OUT/seed-source-files.tsv" && -s "$OUT/clone-relative.tsv" ]] ||
    s04a1_die 'formal clone semantic inputs are incomplete'
  for file in "$reference" "$OUT/seed-source-files.tsv" "$OUT/clone-relative.tsv"; do
    awk -F '\t' 'NF!=3 || $1=="" || $2!~/^[0-9]+$/ || $3!~/^[0-9]+$/{bad=1} END{exit bad}' "$file" ||
      s04a1_die "invalid clone contract row: $file"
  done
  diff -u <(cut -f1,2 "$reference") <(cut -f1,2 "$OUT/clone-relative.tsv") \
    > "$OUT/clone-contract-name-size.diff" || s04a1_die 'formal clone name/size differs from preflight contract'
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
     "$target_unique" -eq 256 && "$overlap" -eq 0 ]] ||
    s04a1_die "clone inode identity requires 256 unique reference/source/target inodes and zero source-target overlap: rows=$rows reference=$reference_unique source=$source_unique target=$target_unique reference_overlap_diagnostic=$reference_overlap source_target_overlap=$overlap"
  printf 'policy\tpath-size-anchor-exact_inode-unique-disjoint\nfiles\t%s\nreference_unique_inodes\t%s\nsource_unique_inodes\t%s\ntarget_unique_inodes\t%s\nsource_reference_inode_overlap\t%s\nsource_target_inode_overlap\t%s\nper_path_inode_matches_reference\t%s\n' \
    "$rows" "$reference_unique" "$source_unique" "$target_unique" "$reference_overlap" "$overlap" "$per_path_matches" \
    > "$OUT/clone-inode-invariants.tsv"
}

finalize_clone_evidence() {
  [[ ! -e "$OUT/jobfiles" && ! -e "$OUT/layout-files.tsv" && ! -e "$OUT/layout-files.sha256" &&
     ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" ]] ||
    s04a1_die 'clone runtime evidence or marker already exists'
  bash "$SCRIPT_DIR/s04a1-gen-jobfiles.sh" "$OUT/jobfiles" "$TEST_DIR" > "$OUT/jobfiles.log"
  find "$TEST_DIR" -maxdepth 1 -type f -printf '%p\t%s\t%i\n' | sort > "$OUT/layout-files.tsv"
  sha256sum "$OUT/layout-files.tsv" > "$OUT/layout-files.sha256"
  if [[ "$INSTANCE" == RESTORE-PREFLIGHT-C ]]; then
    [[ ! -e "$SEED_DIR/formal-clone-contract.tsv" ]] || s04a1_die 'formal clone contract already exists'
    cp "$OUT/clone-relative.tsv" "$SEED_DIR/formal-clone-contract.tsv"
    sha256sum "$SEED_DIR/formal-clone-contract.tsv" > "$SEED_DIR/formal-clone-contract.sha256"
  fi
  printf '%s\n' "$(date +%s)" > "$OUT/CLONE_PASS"
  printf '%s\n' "$(date +%s)" > "$OUT/LAYOUT_PASS"
}

clone_workset() {
  [[ ${S04A1_CLONE_AUTH:-} == "04-2-clone-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] || s04a1_die "set exact S04A1_CLONE_AUTH=04-2-clone-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" restore-clone "$S04A1_CLONE_AUTH"
  case "$INSTANCE" in RESTORE-CANARY-C|RESTORE-CANARY-L|RESTORE-PREFLIGHT-C|RESTORE-PREFLIGHT-L|ARM-CANARY-C|ARM-CANARY-L|R0[1-8]) ;; *) s04a1_die 'instance is not allowed to clone a workset';; esac
  verify_mount
  [[ ! -e "$TEST_DIR" && ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" ]] || s04a1_die 'clone target or marker already exists'
  [[ -d "$SOURCE_DIR" ]] || s04a1_die 'seed source directory missing after restore'
  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/seed-source-files.tsv"
  cmp -s "$SEED_DIR/seed-layout-relative.tsv" "$OUT/seed-source-files.tsv" || s04a1_die 'restored seed source manifest differs from frozen seed'
  write_content_anchors "$SOURCE_DIR" "$OUT/seed-source-anchors.tsv"
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/seed-source-anchors.tsv" || s04a1_die 'restored seed source content anchors differ from frozen seed'
  record_cmd "$S04A1_JUICEFS_BIN" clone -p "$SOURCE_DIR" "$TEST_DIR"
  "$S04A1_JUICEFS_BIN" clone -p "$SOURCE_DIR" "$TEST_DIR" > "$OUT/clone.stdout" 2> "$OUT/clone.stderr"
  [[ -d "$TEST_DIR" ]] || s04a1_die 'clone target directory missing'
  find "$TEST_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/clone-relative.tsv"
  diff -u <(cut -f1,2 "$SEED_DIR/seed-layout-relative.tsv") <(cut -f1,2 "$OUT/clone-relative.tsv") > "$OUT/clone-name-size.diff" ||
    s04a1_die 'clone name/size contract differs from seed'
  write_content_anchors "$TEST_DIR" "$OUT/clone-content-anchors.tsv"
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/clone-content-anchors.tsv" || s04a1_die 'clone content anchors differ from immutable seed'
  if s04a1_is_formal_arm "$INSTANCE" || [[ "$INSTANCE" == ARM-CANARY-C || "$INSTANCE" == ARM-CANARY-L ]]; then
    [[ -s "$SEED_DIR/formal-clone-contract.tsv" && -s "$SEED_DIR/formal-clone-contract.sha256" ]] || s04a1_die 'formal clone preflight contract missing'
    (cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) || s04a1_die 'formal clone contract SHA mismatch'
    verify_formal_clone_semantics "$SEED_DIR/formal-clone-contract.tsv"
  elif [[ "$INSTANCE" == RESTORE-PREFLIGHT-C ]]; then
    verify_formal_clone_semantics "$SEED_DIR/seed-layout-relative.tsv"
  elif [[ "$INSTANCE" == RESTORE-PREFLIGHT-L ]]; then
    [[ -s "$SEED_DIR/formal-clone-contract.tsv" && -s "$SEED_DIR/formal-clone-contract.sha256" ]] || s04a1_die 'C preflight clone contract missing'
    (cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) || s04a1_die 'C preflight clone contract SHA mismatch'
    verify_formal_clone_semantics "$SEED_DIR/formal-clone-contract.tsv"
  fi
  finalize_clone_evidence
  printf 'CLONE_WORKSET_PASS instance=%s files=%s source=immutable-seed\n' "$INSTANCE" "$(wc -l < "$OUT/clone-relative.tsv")"
}

adopt_clone_state() {
  if ! s04a1_is_formal_arm "$INSTANCE" && [[ "$INSTANCE" != RESTORE-PREFLIGHT-C ]]; then
    s04a1_die 'clone state adoption is restricted to RESTORE-PREFLIGHT-C or formal R01..R08 arms'
  fi
  [[ ${S04A1_CLONE_ADOPT_AUTH:-} == "04-2-clone-adopt-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_CLONE_ADOPT_AUTH=04-2-clone-adopt-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" clone-adopt "$S04A1_CLONE_ADOPT_AUTH"
  verify_mount
  verify_seed_bundle
  [[ -d "$SOURCE_DIR" && -d "$TEST_DIR" && ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" ]] ||
    s04a1_die 'clone adoption requires an existing first-attempt target and no success markers'
  [[ -e "$OUT/clone.stdout" && ! -s "$OUT/clone.stdout" && -e "$OUT/clone.stderr" && ! -s "$OUT/clone.stderr" ]] ||
    s04a1_die 'clone adoption requires zero-length stdout/stderr from the first clone command'
  grep -Fq -- "$S04A1_JUICEFS_BIN clone -p $SOURCE_DIR $TEST_DIR" "$OUT/commands.sh" ||
    s04a1_die 'recorded first clone command is missing or differs'
  ! pgrep -x fio >/dev/null || s04a1_die 'fio exists; refuse clone state adoption'
  [[ -s "$OUT/seed-source-files.tsv" && -s "$OUT/seed-source-anchors.tsv" &&
     -s "$OUT/clone-relative.tsv" && -s "$OUT/clone-content-anchors.tsv" ]] ||
    s04a1_die 'first clone evidence is incomplete'

  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/adopt-seed-source-files.tsv"
  find "$TEST_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/adopt-clone-relative.tsv"
  write_content_anchors "$SOURCE_DIR" "$OUT/adopt-seed-source-anchors.tsv"
  write_content_anchors "$TEST_DIR" "$OUT/adopt-clone-content-anchors.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$OUT/adopt-seed-source-files.tsv" || s04a1_die 'seed source changed after failed clone gate'
  cmp -s "$OUT/clone-relative.tsv" "$OUT/adopt-clone-relative.tsv" || s04a1_die 'clone target changed after failed clone gate'
  cmp -s "$OUT/seed-source-anchors.tsv" "$OUT/adopt-seed-source-anchors.tsv" || s04a1_die 'seed source anchors changed after failed clone gate'
  cmp -s "$OUT/clone-content-anchors.tsv" "$OUT/adopt-clone-content-anchors.tsv" || s04a1_die 'clone anchors changed after failed clone gate'
  cmp -s "$SEED_DIR/seed-layout-relative.tsv" "$OUT/adopt-seed-source-files.tsv" || s04a1_die 'adopted source manifest differs from frozen seed'
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/adopt-seed-source-anchors.tsv" || s04a1_die 'adopted source anchors differ from frozen seed'
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/adopt-clone-content-anchors.tsv" || s04a1_die 'adopted clone anchors differ from frozen seed'
  local reference
  if [[ "$INSTANCE" == RESTORE-PREFLIGHT-C ]]; then
    [[ ! -e "$SEED_DIR/formal-clone-contract.tsv" && ! -e "$SEED_DIR/formal-clone-contract.sha256" ]] ||
      s04a1_die 'C preflight adoption requires an absent formal clone contract'
    reference="$SEED_DIR/seed-layout-relative.tsv"
  else
    [[ -s "$SEED_DIR/formal-clone-contract.tsv" && -s "$SEED_DIR/formal-clone-contract.sha256" ]] ||
      s04a1_die 'formal clone preflight contract missing'
    (cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) || s04a1_die 'formal clone contract SHA mismatch'
    reference="$SEED_DIR/formal-clone-contract.tsv"
  fi
  verify_formal_clone_semantics "$reference"
  printf 'instance\t%s\npolicy\tpath-size-anchor-exact_inode-unique-disjoint\nreference_sha256\t%s\nactual_sha256\t%s\nfirst_clone_stdout_bytes\t0\nfirst_clone_stderr_bytes\t0\n' \
    "$INSTANCE" "$(sha256sum "$reference" | awk '{print $1}')" \
    "$(sha256sum "$OUT/clone-relative.tsv" | awk '{print $1}')" > "$OUT/clone-adopt.tsv"
  finalize_clone_evidence
  printf '%s\n' "$(date +%s)" > "$OUT/CLONE_ADOPT_PASS"
  printf 'CLONE_ADOPT_PASS instance=%s files=%s policy=path-size-anchor-exact_inode-unique-disjoint\n' \
    "$INSTANCE" "$(wc -l < "$OUT/clone-relative.tsv")"
}

cow_canary() {
  [[ ${S04A1_COW_CANARY_AUTH:-} == "04-2-cow-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] || s04a1_die "set exact S04A1_COW_CANARY_AUTH=04-2-cow-canary-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" cow-canary "$S04A1_COW_CANARY_AUTH"
  [[ "$INSTANCE" == RESTORE-CANARY-C && "$FLAVOR" == canary ]] || s04a1_die 'COW canary is restricted to RESTORE-CANARY-C'
  verify_mount
  [[ -s "$OUT/CLONE_PASS" && ! -e "$OUT/COW_CANARY_PASS" ]] || s04a1_die 'clone gate missing or COW canary already ran'
  local src="$SOURCE_DIR/canary.bin" dst="$TEST_DIR/canary.bin" src_before src_after dst_before dst_after
  src_before=$(head -c 262144 "$src" | sha256sum | awk '{print $1}')
  dst_before=$(head -c 262144 "$dst" | sha256sum | awk '{print $1}')
  [[ "$src_before" == "$dst_before" ]] || s04a1_die 'canary clone content differs before COW write'
  record_cmd fio --name=cow-canary "--filename=$dst" --rw=write --bs=256k --offset=0 --size=256k \
    --ioengine=libaio --direct=1 --fallocate=none --allow_file_create=0 --buffer_pattern=0x5a
  fio --name=cow-canary --filename="$dst" --rw=write --bs=256k --offset=0 --size=256k \
    --ioengine=libaio --direct=1 --fallocate=none --allow_file_create=0 --buffer_pattern=0x5a \
    > "$OUT/cow-fio.stdout" 2> "$OUT/cow-fio.stderr"
  grep -q 'err= 0' "$OUT/cow-fio.stdout" || s04a1_die 'COW canary fio lacks err=0'
  src_after=$(head -c 262144 "$src" | sha256sum | awk '{print $1}')
  dst_after=$(head -c 262144 "$dst" | sha256sum | awk '{print $1}')
  [[ "$src_after" == "$src_before" && "$dst_after" != "$dst_before" ]] || s04a1_die 'COW canary did not preserve immutable seed source'
  printf 'source_before\t%s\nsource_after\t%s\ntarget_before\t%s\ntarget_after\t%s\n' \
    "$src_before" "$src_after" "$dst_before" "$dst_after" > "$OUT/cow-canary.tsv"
  printf '%s\n' "$(date +%s)" > "$OUT/COW_CANARY_PASS"
  printf 'COW_CANARY_PASS instance=%s source_unchanged=yes target_changed=yes\n' "$INSTANCE"
}

umount_restored() {
  [[ ${S04A1_RESTORE_UMOUNT_AUTH:-} == "04-2-restore-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] || s04a1_die "set exact S04A1_RESTORE_UMOUNT_AUTH=04-2-restore-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" restore-umount "$S04A1_RESTORE_UMOUNT_AUTH"
  verify_mount
  if s04a1_is_formal_arm "$INSTANCE"; then [[ -s "$OUT/arm-analysis.json" ]] || s04a1_die 'formal arm analysis missing before umount'; fi
  if [[ "$INSTANCE" == ARM-CANARY-C || "$INSTANCE" == ARM-CANARY-L ]]; then [[ -s "$OUT/arm-analysis.json" ]] || s04a1_die 'arm canary analysis missing before umount'; fi
  case "$INSTANCE" in RESTORE-PREFLIGHT-C|RESTORE-PREFLIGHT-L) [[ -s "$SEED_DIR/formal-clone-contract.tsv" ]] || s04a1_die 'preflight clone contract missing';; esac
  if [[ "$INSTANCE" == RESTORE-CANARY-C ]]; then [[ -s "$OUT/COW_CANARY_PASS" ]] || s04a1_die 'COW canary gate missing'; fi
  record_cmd "$S04A1_JUICEFS_BIN" umount "$MNT"
  "$S04A1_JUICEFS_BIN" umount "$MNT" > "$OUT/umount.log" 2>&1 || s04a1_die 'graceful restored-volume umount failed'
  mountpoint -q "$MNT" && s04a1_die 'restored mount remains after umount'
  printf '%s\n' "$(date +%s)" > "$OUT/UMOUNT_EPOCH"
  rmdir "$MNT"
  printf 'RESTORE_UMOUNT_PASS instance=%s\n' "$INSTANCE"
}

abort_umount_restored() {
  local deadline reason
  if s04a1_is_formal_arm "$INSTANCE"; then
    [[ -s "$OUT/READY_FOR_FIO" && -s "$OUT/arm/phase.tsv" && ! -e "$OUT/arm-analysis.json" &&
       ! -e "$OUT/ABORT_UMOUNT_PASS" && ! -e "$OUT/UMOUNT_EPOCH" ]] ||
      s04a1_die 'abort-umount requires one failed formal arm and no prior umount marker'
    grep -Fq $'\tlaunch' "$OUT/arm/phase.tsv" || s04a1_die 'failed formal arm lacks fio launch evidence'
    reason=formal-arm-evidence-failure
  elif [[ "$INSTANCE" == ARM-CANARY-C || "$INSTANCE" == ARM-CANARY-L ]]; then
    [[ -s "$OUT/NONFORMAL_CANARY" && -s "$OUT/PREWINDOW_ABORT.tsv" &&
       $(awk -F '\t' '$1=="fio_started"{print $2}' "$OUT/PREWINDOW_ABORT.tsv") == no &&
       ! -e "$OUT/arm/phase.tsv" && ! -e "$OUT/arm/fio.pid" && ! -e "$OUT/arm-analysis.json" &&
       ! -e "$OUT/ABORT_UMOUNT_PASS" && ! -e "$OUT/UMOUNT_EPOCH" ]] ||
      s04a1_die 'canary abort-umount requires a pre-window sampler failure with no fio launch'
    reason=canary-sampler-prewindow-failure
  else
    s04a1_die 'abort-umount is restricted to formal arms or pre-window arm canaries'
  fi
  [[ ${S04A1_ABORT_UMOUNT_AUTH:-} == "04-2-abort-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}" ]] ||
    s04a1_die "set exact S04A1_ABORT_UMOUNT_AUTH=04-2-abort-umount-${RUN_ID}-${INSTANCE}-${CLUSTER}"
  s04a1_record_authorization "$RUN_ID" abort-umount "$S04A1_ABORT_UMOUNT_AUTH"
  ! pgrep -x fio >/dev/null || s04a1_die 'fio still exists; preserve the failed arm'
  verify_mount
  verify_seed_bundle

  find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$OUT/abort-seed-source-post.tsv"
  cmp -s "$OUT/seed-source-files.tsv" "$OUT/abort-seed-source-post.tsv" ||
    s04a1_die 'immutable seed source identity changed in failed arm'
  write_content_anchors "$SOURCE_DIR" "$OUT/abort-seed-anchors-post.tsv"
  cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$OUT/abort-seed-anchors-post.tsv" ||
    s04a1_die 'immutable seed source content changed in failed arm'
  find "$TEST_DIR" -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) \
    -printf '%p\t%s\t%i\n' | sort > "$OUT/abort-layout-post.tsv"
  cmp -s "$OUT/layout-files.tsv" "$OUT/abort-layout-post.tsv" ||
    s04a1_die 'failed arm changed target path/size/inode identity'

  record_cmd "$S04A1_JUICEFS_BIN" umount "$MNT"
  "$S04A1_JUICEFS_BIN" umount "$MNT" > "$OUT/abort-umount.log" 2>&1 ||
    s04a1_die 'graceful abort umount failed'
  mountpoint -q "$MNT" && s04a1_die 'restored mount remains after abort umount'
  deadline=$((SECONDS + 30))
  while [[ -n $(mount_pid_pairs) && $SECONDS -lt $deadline ]]; do sleep 1; done
  [[ -z $(mount_pid_pairs) ]] || s04a1_die 'JuiceFS mount process remains after abort umount'
  printf 'epoch\t%s\ninstance\t%s\ncluster\t%s\nreason\t%s\n' \
    "$(date +%s)" "$INSTANCE" "$CLUSTER" "$reason" > "$OUT/abort-umount.tsv"
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
  *) s04a1_die 'usage: s04a1-restore-volume.sh load|mount|verify|clone|adopt-clone-state|cow-canary|umount|abort-umount RUN_ID C|L INSTANCE';;
esac
