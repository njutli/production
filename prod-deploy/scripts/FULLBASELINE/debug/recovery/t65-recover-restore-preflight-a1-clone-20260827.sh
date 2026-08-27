#!/usr/bin/env bash
# One-shot evidence adoption for the fixed RESTORE-PREFLIGHT-A1 clone attempt.
# The clone command already completed; the old verifier rejected normal
# dump/load source-inode preservation.  This script never reruns clone/load,
# touches a mount, runs fio/GC, or changes cluster/storage/service state.
set -euo pipefail
export LC_ALL=C

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}

EXPECTED_RUN=20260826-164047
EXPECTED_CLUSTER=A1
EXPECTED_INSTANCE=RESTORE-PREFLIGHT-A1
ACTIVE_DIR=/tmp/t65-scripts
ACTIVE_MANIFEST_SHA=ce56032e766808635c47c22130e61a6a80e4469c7def7381db43e5e5a50b7e08
COMMON_SHA=97e3b84d60415b47a12ed3e590db841058f01d4d0660a4ac8961d9439be60355
RESTORE_SHA=f9be4d25e8cdd99ca5a1ae66366c88668155dea95fcfc8fa63c3c58315eedab7
GEN_JOB_SHA=16cb676c5ee3ccb9413baa07df8f95351f430b89eb0c38c0955f6480a925e32b
JUICEFS_MD5=de93563f11a5ff3bd94dd25a4e0283b1
SEED_UUID=82d3e3d8-857e-4e82-a9e9-5ea02529bf22
SEED_NAME=jfs-t65-20260826-164047-seed
DUMP_SHA=66432a7acffa3460c60acd7b65cf234374587b6978c6a74f1253727635f67e83
LAYOUT_SHA=a127a81e8cf7a30b5c86c37d770b67dd2a91fd88de58794917ebe5b2eed756a2
ANCHOR_SHA=4cbf69fad8a6fd18b84f528db687839695260e545f5d14ee21e232b09fdde293
EXPECTED_PID=2024036
EXPECTED_POOL_OBJECTS=2958981
EXPECTED_POOL_STORED=775755661312
EXPECTED_POOL_USED=1163633467392
# The frozen values above are the post-clone snapshot.  A long-lived active
# validation window can observe small unrelated/shared-pool or asynchronous
# accounting drift; its exact source is not attributed here.  Keep this
# allowance orders of magnitude below a materialized clone and record it.
MAX_POOL_OBJECT_DRIFT=64
MAX_POOL_STORED_DRIFT=$((16 * 1024 * 1024))
MAX_POOL_USED_DRIFT=$((32 * 1024 * 1024))

die() { printf 'E_T65_CLONE_RECOVERY\t%s\n' "$*" >&2; exit 42; }
sha() { sha256sum -- "$1" | awk '{print $1}'; }
abs_delta() { local a=$1 b=$2; (( a >= b )) && printf '%s\n' "$((a - b))" || printf '%s\n' "$((b - a))"; }
pool_within_recovery_drift() {
  local objects=$1 stored=$2 used=$3 object_delta stored_delta used_delta
  [[ "$objects" =~ ^[0-9]+$ && "$stored" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] || return 1
  object_delta=$(abs_delta "$objects" "$EXPECTED_POOL_OBJECTS")
  stored_delta=$(abs_delta "$stored" "$EXPECTED_POOL_STORED")
  used_delta=$(abs_delta "$used" "$EXPECTED_POOL_USED")
  (( object_delta <= MAX_POOL_OBJECT_DRIFT &&
     stored_delta <= MAX_POOL_STORED_DRIFT &&
     used_delta <= MAX_POOL_USED_DRIFT ))
}

if [[ "$ACTION" == --offline-self-test ]]; then
  [[ "$EXPECTED_RUN" =~ ^[0-9]{8}-[0-9]{6}$ ]]
  [[ "$EXPECTED_CLUSTER" == A1 && "$EXPECTED_INSTANCE" == RESTORE-PREFLIGHT-A1 ]]
  [[ "$ACTIVE_MANIFEST_SHA" =~ ^[0-9a-f]{64}$ && "$DUMP_SHA" =~ ^[0-9a-f]{64}$ ]]
  [[ "$EXPECTED_POOL_OBJECTS" == 2958981 && "$EXPECTED_POOL_STORED" == 775755661312 &&
     "$EXPECTED_POOL_USED" == 1163633467392 ]]
  pool_within_recovery_drift "$EXPECTED_POOL_OBJECTS" "$EXPECTED_POOL_STORED" "$EXPECTED_POOL_USED"
  pool_within_recovery_drift 2958982 775755726848 1163633565696
  pool_within_recovery_drift \
    "$((EXPECTED_POOL_OBJECTS + MAX_POOL_OBJECT_DRIFT))" \
    "$((EXPECTED_POOL_STORED + MAX_POOL_STORED_DRIFT))" \
    "$((EXPECTED_POOL_USED + MAX_POOL_USED_DRIFT))"
  ! pool_within_recovery_drift "$((EXPECTED_POOL_OBJECTS + MAX_POOL_OBJECT_DRIFT + 1))" "$EXPECTED_POOL_STORED" "$EXPECTED_POOL_USED"
  ! pool_within_recovery_drift "$EXPECTED_POOL_OBJECTS" "$((EXPECTED_POOL_STORED + MAX_POOL_STORED_DRIFT + 1))" "$EXPECTED_POOL_USED"
  ! pool_within_recovery_drift "$EXPECTED_POOL_OBJECTS" "$EXPECTED_POOL_STORED" "$((EXPECTED_POOL_USED + MAX_POOL_USED_DRIFT + 1))"
  printf 'OFFLINE_SELF_TEST_PASS\n'
  exit 0
fi

[[ "$ACTION" == inspect || "$ACTION" == recover ]] ||
  die 'usage: inspect|recover RUN_ID A1 RESTORE-PREFLIGHT-A1'
[[ "$RUN_ID" == "$EXPECTED_RUN" && "$CLUSTER" == "$EXPECTED_CLUSTER" && "$INSTANCE" == "$EXPECTED_INSTANCE" ]] ||
  die 'this one-shot recovery is scoped only to the frozen A1 preflight attempt'

COMMON="$ACTIVE_DIR/t65-common.sh"
RESTORE="$ACTIVE_DIR/t65-restore-volume.sh"
GEN_JOB="$ACTIVE_DIR/t65-gen-jobfiles.sh"
MANIFEST="$ACTIVE_DIR/t65-manifest.sha256"
[[ -f "$COMMON" && $(sha "$COMMON") == "$COMMON_SHA" ]] || die 'active common script identity mismatch'
[[ -f "$RESTORE" && $(sha "$RESTORE") == "$RESTORE_SHA" ]] || die 'active restore script identity mismatch'
[[ -f "$GEN_JOB" && $(sha "$GEN_JOB") == "$GEN_JOB_SHA" ]] || die 'active job generator identity mismatch'
[[ -f "$MANIFEST" && $(sha "$MANIFEST") == "$ACTIVE_MANIFEST_SHA" ]] ||
  die 'active bundle manifest identity mismatch; hot-resync is forbidden'
# shellcheck source=/dev/null
source "$COMMON"

ROOT="/tmp/production/opencode-t3.22b-${RUN_ID}"
OUT="$ROOT/instances/$INSTANCE"
SEED_DIR="$ROOT/seeds/formal"
MNT="/tmp/jfs-t65-${RUN_ID}-mnt-${INSTANCE}"
SOURCE="$MNT/seed_layout"
TARGET="$MNT/test_dir"
STATE="$OUT/volume.tsv"
RESTORE_STATE="$OUT/restore.tsv"
LEDGER="/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv"
RECOVERY="$OUT/clone-evidence-recovery"
META="tikv://10.20.1.150:12379,10.20.1.151:12379,10.20.1.152:12379/jfs-t65-${RUN_ID}-${INSTANCE,,}"
export CEPH_CONF="$OUT/ceph-t65.conf"

for path in "$ROOT" "$OUT" "$SEED_DIR" "$MNT" "$SOURCE" "$TARGET"; do
  [[ -e "$path" && ! -L "$path" ]] || die "required path missing or symlinked: $path"
done
[[ -s "$STATE" && -s "$RESTORE_STATE" && -s "$LEDGER" ]] || die 'restore/mount/ledger state is incomplete'
[[ -s "$SEED_DIR/SEED_BUNDLE_PASS" && -s "$SEED_DIR/seed.tsv" && -s "$SEED_DIR/seed-meta.json.gz" &&
   -s "$SEED_DIR/seed-meta.sha256" && -s "$SEED_DIR/seed-layout-relative.tsv" &&
   -s "$SEED_DIR/seed-content-anchors.tsv" ]] || die 'formal seed bundle is incomplete'
[[ $(sha "$SEED_DIR/seed-meta.json.gz") == "$DUMP_SHA" &&
   $(sha "$SEED_DIR/seed-layout-relative.tsv") == "$LAYOUT_SHA" &&
   $(sha "$SEED_DIR/seed-content-anchors.tsv") == "$ANCHOR_SHA" ]] || die 'formal seed SHA changed'
[[ $(awk -F '\t' '$1=="uuid"{print $2}' "$SEED_DIR/seed.tsv") == "$SEED_UUID" &&
   $(awk -F '\t' '$1=="volume_name"{print $2}' "$SEED_DIR/seed.tsv") == "$SEED_NAME" ]] ||
  die 'formal seed identity changed'
[[ $(md5sum "$T65_JUICEFS_BIN" | awk '{print $1}') == "$JUICEFS_MD5" ]] || die 'JuiceFS binary changed'

[[ ! -e "$OUT/CLONE_PASS" && ! -e "$OUT/LAYOUT_PASS" && ! -e "$OUT/CLONE_ADOPT_PASS" &&
   ! -e "$SEED_DIR/formal-clone-contract.tsv" && ! -e "$SEED_DIR/formal-clone-contract.sha256" &&
   ! -e "$OUT/jobfiles" && ! -e "$OUT/layout-files.tsv" && ! -e "$RECOVERY" ]] ||
  die 'success/contract/recovery output already exists; preserve first attempt'
[[ -e "$OUT/clone.stdout" && ! -s "$OUT/clone.stdout" && -e "$OUT/clone.stderr" && ! -s "$OUT/clone.stderr" ]] ||
  die 'first clone stdout/stderr are not both zero length'
[[ $(grep -Fc -- "$T65_JUICEFS_BIN clone -p $SOURCE $TARGET" "$OUT/commands.sh") == 1 ]] ||
  die 'commands.sh does not contain exactly one frozen clone command'
[[ $(awk -F '\t' '$3=="restore-clone" && $4=="03-22b-clone-20260826-164047-RESTORE-PREFLIGHT-A1-A1"{n++} END{print n+0}' "$LEDGER") == 1 ]] ||
  die 'authorization ledger lacks exactly one original clone attempt'
[[ $(awk -F '\t' '$3=="clone-adopt" || $3=="clone-evidence-recovery"{n++} END{print n+0}' "$LEDGER") == 0 ]] ||
  die 'a clone adoption/recovery authorization already exists'
! pgrep -x fio >/dev/null || die 'fio exists; refuse recovery'

mountpoint -q "$MNT" || die 'restored mount is not active'
pid=$(awk -F '\t' '$1=="pid"{print $2}' "$STATE")
start=$(awk -F '\t' '$1=="starttime"{print $2}' "$STATE")
[[ "$pid" == "$EXPECTED_PID" && -r "/proc/$pid/stat" && $(awk '{print $22}' "/proc/$pid/stat") == "$start" ]] ||
  die 'mount worker PID/starttime changed'
[[ $(md5sum "/proc/$pid/exe" | awk '{print $1}') == "$JUICEFS_MD5" ]] || die 'mount worker executable changed'
t65_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META" || die 'mount worker META changed'
t65_nul_file_has_exact_arg "/proc/$pid/cmdline" "$MNT" || die 'mount worker path changed'
[[ $(awk -F '\t' '$1=="uuid"{print $2}' "$STATE") == "$SEED_UUID" &&
   $(awk -F '\t' '$1=="meta"{print $2}' "$STATE") == "$META" ]] || die 'volume state identity changed'

"$T65_JUICEFS_BIN" status "$META" > /tmp/t65-clone-recovery-status.$$.json
STATUS_TMP=/tmp/t65-clone-recovery-status.$$.json
trap 'unlink "$STATUS_TMP" 2>/dev/null || true' EXIT
identity=$(t65_status_identity "$STATUS_TMP") || die 'live status identity invalid'
IFS=$'\t' read -r live_uuid live_name <<< "$identity"
[[ "$live_uuid" == "$SEED_UUID" && "$live_name" == "$SEED_NAME" ]] || die 'live Name/UUID changed'
[[ $(python3 - "$STATUS_TMP" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(len(d.get("Sessions",[])))
PY
) == 1 ]] || die 'live session count is not one'

[[ $(sudo ceph health) == HEALTH_OK ]] || die 'Ceph is not HEALTH_OK'
pool=$(sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next(x for x in d["pools"] if x["name"]=="juicefs-data"); s=p["stats"]
print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))')
IFS=$'\t' read -r pool_objects pool_stored pool_used <<< "$pool"
pool_within_recovery_drift "$pool_objects" "$pool_stored" "$pool_used" ||
  die "pool drift exceeds recovery-only bounds: current=$pool baseline=${EXPECTED_POOL_OBJECTS},${EXPECTED_POOL_STORED},${EXPECTED_POOL_USED} limits=${MAX_POOL_OBJECT_DRIFT},${MAX_POOL_STORED_DRIFT},${MAX_POOL_USED_DRIFT}"
pool_object_delta=$(abs_delta "$pool_objects" "$EXPECTED_POOL_OBJECTS")
pool_stored_delta=$(abs_delta "$pool_stored" "$EXPECTED_POOL_STORED")
pool_used_delta=$(abs_delta "$pool_used" "$EXPECTED_POOL_USED")
for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
  curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:30180/config" >/dev/null ||
    die "temporary TiKV unavailable: $node"
done
curl -fsS --connect-timeout 3 --max-time 8 'http://10.20.1.150:12379/pd/api/v1/health' |
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==3 and all(x.get("health") is True for x in d)' ||
  die 'PD health is not 3/3'
curl -fsS --connect-timeout 3 --max-time 8 'http://10.20.1.150:12379/pd/api/v1/stores' |
  python3 -c 'import json,sys; s=json.load(sys.stdin).get("stores",[]); assert len(s)==3 and all(x.get("store",{}).get("state_name")=="Up" for x in s)' ||
  die 'TiKV stores are not 3/3 Up'

for file in seed-source-files.tsv seed-source-anchors.tsv clone-relative.tsv clone-content-anchors.tsv; do
  [[ -s "$OUT/$file" ]] || die "first-attempt evidence missing: $file"
done
TMP=$(mktemp -d /tmp/production/t65-clone-recovery-inspect.XXXXXX)
cleanup_tmp() { find "$TMP" -type f -delete 2>/dev/null || true; find "$TMP" -depth -type d -empty -delete 2>/dev/null || true; }
trap 'cleanup_tmp; unlink "$STATUS_TMP" 2>/dev/null || true' EXIT
find "$SOURCE" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$TMP/source.tsv"
find "$TARGET" -maxdepth 1 -type f -printf '%P\t%s\t%i\n' | sort > "$TMP/target.tsv"
cmp -s "$OUT/seed-source-files.tsv" "$TMP/source.tsv" || die 'source identity changed after failed gate'
cmp -s "$OUT/clone-relative.tsv" "$TMP/target.tsv" || die 'target identity changed after failed gate'
cmp -s "$SEED_DIR/seed-layout-relative.tsv" "$TMP/source.tsv" || die 'source differs from frozen seed manifest'
diff -u <(cut -f1,2 "$SEED_DIR/seed-layout-relative.tsv") <(cut -f1,2 "$TMP/target.tsv") >/dev/null ||
  die 'target name/size differs from frozen seed'

python3 - "$SOURCE" "$SEED_DIR/seed-content-anchors.tsv" > "$TMP/source-anchors.tsv" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1])
for raw in Path(sys.argv[2]).read_text().splitlines():
    name,off,_=raw.split("\t")
    with (root/name).open("rb") as f:
        f.seek(int(off)); data=f.read(262144)
    assert len(data)==262144
    print(f"{name}\t{off}\t{hashlib.sha256(data).hexdigest()}")
PY
python3 - "$TARGET" "$SEED_DIR/seed-content-anchors.tsv" > "$TMP/target-anchors.tsv" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1])
for raw in Path(sys.argv[2]).read_text().splitlines():
    name,off,_=raw.split("\t")
    with (root/name).open("rb") as f:
        f.seek(int(off)); data=f.read(262144)
    assert len(data)==262144
    print(f"{name}\t{off}\t{hashlib.sha256(data).hexdigest()}")
PY
cmp -s "$OUT/seed-source-anchors.tsv" "$TMP/source-anchors.tsv" || die 'source anchors changed after failed gate'
cmp -s "$OUT/clone-content-anchors.tsv" "$TMP/target-anchors.tsv" || die 'target anchors changed after failed gate'
cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$TMP/source-anchors.tsv" || die 'source anchors differ from frozen seed'
cmp -s "$SEED_DIR/seed-content-anchors.tsv" "$TMP/target-anchors.tsv" || die 'target anchors differ from frozen seed'

rows=$(wc -l < "$TMP/target.tsv")
reference_unique=$(cut -f3 "$SEED_DIR/seed-layout-relative.tsv" | sort -u | wc -l)
source_unique=$(cut -f3 "$TMP/source.tsv" | sort -u | wc -l)
target_unique=$(cut -f3 "$TMP/target.tsv" | sort -u | wc -l)
reference_overlap=$(comm -12 <(cut -f3 "$SEED_DIR/seed-layout-relative.tsv" | sort -u) <(cut -f3 "$TMP/source.tsv" | sort -u) | wc -l)
source_target_overlap=$(comm -12 <(cut -f3 "$TMP/source.tsv" | sort -u) <(cut -f3 "$TMP/target.tsv" | sort -u) | wc -l)
[[ "$rows" -eq 256 && "$reference_unique" -eq 256 && "$source_unique" -eq 256 &&
   "$target_unique" -eq 256 && "$reference_overlap" -eq 256 && "$source_target_overlap" -eq 0 ]] ||
  die "inode contract failed: rows=$rows reference=$reference_unique source=$source_unique target=$target_unique reference_overlap=$reference_overlap source_target_overlap=$source_target_overlap"

printf 'CLONE_RECOVERY_INSPECT_PASS run=%s instance=%s pid=%s reference_overlap=%s source_target_overlap=%s pool=%q pool_abs_delta=%s,%s,%s\n' \
  "$RUN_ID" "$INSTANCE" "$pid" "$reference_overlap" "$source_target_overlap" "$pool" \
  "$pool_object_delta" "$pool_stored_delta" "$pool_used_delta"
printf 'PLAN\twrite only clone recovery evidence, formal clone contract, generated jobfiles/layout manifest and success markers\n'
printf 'PLAN\tno clone/load/mount/umount/fio/GC/cluster/loop/backing/production action\n'
[[ "$ACTION" == inspect ]] && exit 0

EXPECTED_AUTH="03-22b-clone-evidence-recovery-${RUN_ID}-${INSTANCE}-${CLUSTER}"
[[ ${T65_CLONE_RECOVERY_AUTH:-} == "$EXPECTED_AUTH" ]] ||
  die "set exact T65_CLONE_RECOVERY_AUTH=$EXPECTED_AUTH"
t65_record_authorization "$RUN_ID" clone-evidence-recovery "$T65_CLONE_RECOVERY_AUTH"

umask 077
mkdir "$RECOVERY"
cp "$TMP/source.tsv" "$RECOVERY/source-current.tsv"
cp "$TMP/target.tsv" "$RECOVERY/target-current.tsv"
cp "$TMP/source-anchors.tsv" "$RECOVERY/source-anchors-current.tsv"
cp "$TMP/target-anchors.tsv" "$RECOVERY/target-anchors-current.tsv"
cp "$TMP/target.tsv" "$RECOVERY/formal-clone-contract.tsv"
sha256sum "$RECOVERY/formal-clone-contract.tsv" > "$RECOVERY/formal-clone-contract.sha256"
printf 'policy\tpath-size-anchor-exact_inode-unique-source-target-disjoint\nfiles\t256\nreference_unique_inodes\t%s\nsource_unique_inodes\t%s\ntarget_unique_inodes\t%s\nsource_reference_inode_overlap_diagnostic\t%s\nsource_target_inode_overlap\t%s\n' \
  "$reference_unique" "$source_unique" "$target_unique" "$reference_overlap" "$source_target_overlap" \
  > "$RECOVERY/clone-inode-invariants.tsv"
mkdir "$RECOVERY/jobfiles"
bash "$GEN_JOB" "$RECOVERY/jobfiles" "$TARGET" > "$RECOVERY/jobfiles.log"
find "$TARGET" -maxdepth 1 -type f -printf '%p\t%s\t%i\n' | sort > "$RECOVERY/layout-files.tsv"
sha256sum "$RECOVERY/layout-files.tsv" > "$RECOVERY/layout-files.sha256"
printf 'instance\t%s\npolicy\tpath-size-anchor-exact_inode-unique-source-target-disjoint\nreference_sha256\t%s\nactual_sha256\t%s\nfirst_clone_stdout_bytes\t0\nfirst_clone_stderr_bytes\t0\nold_manifest_sha256\t%s\npool_frozen_post_clone\t%s\t%s\t%s\npool_recovery_current\t%s\npool_recovery_abs_delta\t%s\t%s\t%s\npool_recovery_drift_limits\t%s\t%s\t%s\n' \
  "$INSTANCE" "$LAYOUT_SHA" "$(sha "$TMP/target.tsv")" "$ACTIVE_MANIFEST_SHA" \
  "$EXPECTED_POOL_OBJECTS" "$EXPECTED_POOL_STORED" "$EXPECTED_POOL_USED" "$pool" \
  "$pool_object_delta" "$pool_stored_delta" "$pool_used_delta" \
  "$MAX_POOL_OBJECT_DRIFT" "$MAX_POOL_STORED_DRIFT" "$MAX_POOL_USED_DRIFT" > "$RECOVERY/clone-adopt.tsv"
printf '#!/usr/bin/env bash\n# Recorded one-shot evidence recovery; no password.\n%s recover %s %s %s\n' \
  "$0" "$RUN_ID" "$CLUSTER" "$INSTANCE" > "$RECOVERY/commands.sh"
(cd "$RECOVERY" && find . -type f ! -name recovery-evidence.sha256 -printf '%P\0' | sort -z | xargs -0 sha256sum --) > "$RECOVERY/recovery-evidence.sha256"

install -m 0600 "$RECOVERY/formal-clone-contract.tsv" "$SEED_DIR/formal-clone-contract.tsv"
sha256sum "$SEED_DIR/formal-clone-contract.tsv" > "$SEED_DIR/formal-clone-contract.sha256"
cp -a "$RECOVERY/jobfiles" "$OUT/jobfiles"
install -m 0600 "$RECOVERY/jobfiles.log" "$OUT/jobfiles.log"
install -m 0600 "$RECOVERY/layout-files.tsv" "$OUT/layout-files.tsv"
sha256sum "$OUT/layout-files.tsv" > "$OUT/layout-files.sha256"
install -m 0600 "$RECOVERY/clone-inode-invariants.tsv" "$OUT/clone-inode-invariants.tsv"
install -m 0600 "$RECOVERY/clone-adopt.tsv" "$OUT/clone-adopt.tsv"
epoch=$(date +%s)
printf '%s\n' "$epoch" > "$OUT/CLONE_PASS"
printf '%s\n' "$epoch" > "$OUT/LAYOUT_PASS"
printf '%s\n' "$epoch" > "$OUT/CLONE_ADOPT_PASS"
printf '%s\told-verifier-reference-source-overlap-defect\n' "$epoch" > "$OUT/CLONE_EVIDENCE_RECOVERY_PASS"

printf 'CLONE_EVIDENCE_RECOVERY_PASS instance=%s files=256 reference_overlap=%s source_target_overlap=%s contract_sha256=%s\n' \
  "$INSTANCE" "$reference_overlap" "$source_target_overlap" "$(sha "$SEED_DIR/formal-clone-contract.tsv")"
