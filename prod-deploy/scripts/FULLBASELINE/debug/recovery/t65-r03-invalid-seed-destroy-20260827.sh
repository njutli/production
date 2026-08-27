#!/usr/bin/env bash
# One-shot invalid-run seed-destroy recovery for the fixed 03-22b R03 CV gate
# failure.  This client-side script never mounts a volume, runs GC, stops a
# service, touches loop/backing storage, or starts production TiKV.
set -euo pipefail
export LC_ALL=C

ACTION=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}

EXPECTED_RUN=20260826-164047
EXPECTED_CLUSTER=A1
EXPECTED_INSTANCE=G03
FAILED_INSTANCE=R03
FAILED_ARM=B1
FAILURE_REASON=formal-stability-cv-gate-failed
ACTIVE_DIR=/tmp/t65-scripts
ACTIVE_MANIFEST_SHA=a61c4ce2de7612f573ca53610c644bb2ddf1f2669e2fc70bbd229435aebbd20c
COMMON_SHA=97e3b84d60415b47a12ed3e590db841058f01d4d0660a4ac8961d9439be60355
ANALYZE_SHA=db2d87ad46ce02ed34ec7aa6ed41339ebcfbc6385798062547668a85242591ef
GC_RETURN_SHA=2ad036ed8dd9ad60d661b5d15dc311d9f2d5245cd539f92f1da8c42315b88551
RESET_SHA=7f4cf52969d2dfea8e3f33a07f7a2f4a555474ab8672595e8e9ca9eade35fd82
JUICEFS_MD5=de93563f11a5ff3bd94dd25a4e0283b1
SEED_UUID=82d3e3d8-857e-4e82-a9e9-5ea02529bf22
SEED_NAME=jfs-t65-20260826-164047-seed
DUMP_SHA=66432a7acffa3460c60acd7b65cf234374587b6978c6a74f1253727635f67e83
CLONE_CONTRACT_SHA=a409f7c43f288376ab453cec82b0bb02ff7094ea2fe3babed1f87c1e38ea2774
EXPECTED_VALID=524288
MAX_POOL_OBJECT_DRIFT=8192

die() { printf 'E_T65_R03_INVALID_RECOVERY\t%s\n' "$*" >&2; exit 42; }
sha() { sha256sum -- "$1" | awk '{print $1}'; }
state_value() { awk -F '\t' -v key="$2" '$1==key{print $2}' "$1"; }
abs_delta() { local a=$1 b=$2; (( a >= b )) && printf '%s\n' "$((a-b))" || printf '%s\n' "$((b-a))"; }
pool_within_seed_drift() {
  local current=$1 seed=$2 delta
  [[ "$current" =~ ^[0-9]+$ && "$seed" =~ ^[0-9]+$ ]] || return 1
  delta=$(abs_delta "$current" "$seed")
  (( delta <= MAX_POOL_OBJECT_DRIFT ))
}
parse_failure_line() {
  python3 - "$1" <<'PY'
import re,sys
s=sys.argv[1]
m=re.search(r"formal stability hard gate failed: cv=([0-9]+(?:\.[0-9]+)?) w4_w1=([0-9]+(?:\.[0-9]+)?)",s)
assert m and m.group(0)==s, s
cv=float(m.group(1)); ratio=float(m.group(2))
assert cv>10.0, cv
assert ratio>=0.90, ratio
print(f"{cv:.6f}\t{ratio:.6f}")
PY
}

if [[ "$ACTION" == --offline-self-test ]]; then
  [[ "$EXPECTED_RUN" =~ ^[0-9]{8}-[0-9]{6}$ ]]
  [[ "$EXPECTED_CLUSTER" == A1 && "$EXPECTED_INSTANCE" == G03 ]]
  [[ "$FAILED_INSTANCE" == R03 && "$FAILED_ARM" == B1 ]]
  [[ "$ACTIVE_MANIFEST_SHA" =~ ^[0-9a-f]{64}$ && "$DUMP_SHA" =~ ^[0-9a-f]{64}$ ]]
  [[ $(parse_failure_line 'formal stability hard gate failed: cv=10.700885 w4_w1=0.917123') == $'10.700885\t0.917123' ]]
  ! parse_failure_line 'formal stability hard gate failed: cv=9.999999 w4_w1=0.917123' >/dev/null 2>&1
  ! parse_failure_line 'formal stability hard gate failed: cv=10.700885 w4_w1=0.899999' >/dev/null 2>&1
  ! parse_failure_line 'cv=10.700885 w4_w1=0.917123' >/dev/null 2>&1
  pool_within_seed_drift 2958986 2958981
  pool_within_seed_drift "$((2958981 + MAX_POOL_OBJECT_DRIFT))" 2958981
  ! pool_within_seed_drift "$((2958981 + MAX_POOL_OBJECT_DRIFT + 1))" 2958981
  ! pool_within_seed_drift 2958986 2434691
  printf 'OFFLINE_SELF_TEST_PASS\n'
  exit 0
fi

[[ "$ACTION" == inspect || "$ACTION" == destroy ]] ||
  die 'usage: inspect|destroy 20260826-164047 A1 G03'
[[ "$RUN_ID" == "$EXPECTED_RUN" && "$CLUSTER" == "$EXPECTED_CLUSTER" && "$INSTANCE" == "$EXPECTED_INSTANCE" ]] ||
  die 'this one-shot recovery is scoped only to RUN 20260826-164047 / G03 / A1'

COMMON="$ACTIVE_DIR/t65-common.sh"
ANALYZE="$ACTIVE_DIR/t65-analyze.py"
GC_RETURN="$ACTIVE_DIR/t65-gc-return.sh"
RESET="$ACTIVE_DIR/t65-reset-gates.sh"
MANIFEST="$ACTIVE_DIR/t65-manifest.sha256"
[[ -f "$COMMON" && ! -L "$COMMON" && $(sha "$COMMON") == "$COMMON_SHA" ]] || die 'frozen common identity mismatch'
[[ -f "$ANALYZE" && ! -L "$ANALYZE" && $(sha "$ANALYZE") == "$ANALYZE_SHA" ]] || die 'frozen analyzer identity mismatch'
[[ -f "$GC_RETURN" && ! -L "$GC_RETURN" && $(sha "$GC_RETURN") == "$GC_RETURN_SHA" ]] || die 'frozen GC script identity mismatch'
[[ -f "$RESET" && ! -L "$RESET" && $(sha "$RESET") == "$RESET_SHA" ]] || die 'frozen reset script identity mismatch'
[[ -f "$MANIFEST" && ! -L "$MANIFEST" && $(sha "$MANIFEST") == "$ACTIVE_MANIFEST_SHA" ]] ||
  die 'active manifest identity mismatch; hot-resync is forbidden'
# shellcheck source=/dev/null
source "$COMMON"

ROOT="/tmp/production/opencode-t3.22b-${RUN_ID}"
R03="$ROOT/instances/$FAILED_INSTANCE"
G03="$ROOT/instances/$INSTANCE"
SEED_DIR="$ROOT/seeds/formal"
RESTORE_STATE="$G03/restore.tsv"
PRIVATE_CONF="$G03/ceph-t65.conf"
RECOVERY="$G03/r03-invalid-seed-destroy-recovery"
LEDGER="/tmp/jfs-t65-${RUN_ID}-authorization-ledger.tsv"
MNT="/tmp/jfs-t65-${RUN_ID}-mnt-${INSTANCE}"
META=$(t65_meta_url "$RUN_ID" "$INSTANCE")
VOLUME=$(t65_seed_name "$RUN_ID" formal)
export CEPH_CONF="$PRIVATE_CONF"

for path in "$ROOT" "$R03" "$G03" "$SEED_DIR"; do
  [[ -d "$path" && ! -L "$path" ]] || die "required directory missing or symlinked: $path"
done
[[ ! -e "$ROOT/instances/R04" && ! -e "$ROOT/instances/G04" ]] || die 'a post-failure formal instance exists'
[[ ! -e "$ROOT/RUN_INVALID.tsv" && ! -e "$SEED_DIR/seed.destroyed.tsv" &&
   ! -e "$G03/ABORT_SEED_DESTROY_PASS" && ! -e "$RECOVERY" ]] ||
  die 'invalid/destroy/recovery output already exists; preserve first attempt'

[[ -s "$R03/READY_FOR_FIO" && -s "$R03/arm/phase.tsv" && -s "$R03/arm/fio.rc" &&
   -s "$R03/ABORT_UMOUNT_PASS" && -s "$R03/abort-umount.tsv" && -s "$R03/UMOUNT_EPOCH" &&
   ! -e "$R03/arm-analysis.json" ]] || die 'R03 failed-arm/abort evidence contract is incomplete'
grep -Fq $'\tlaunch' "$R03/arm/phase.tsv" || die 'R03 lacks fio launch evidence'
grep -Fq $'\tend\trc=0' "$R03/arm/phase.tsv" || die 'R03 lacks successful fio end evidence'
[[ $(<"$R03/arm/fio.rc") == 0 ]] || die 'R03 fio rc is not zero'
[[ $(state_value "$R03/abort-umount.tsv" instance) == "$FAILED_INSTANCE" &&
   $(state_value "$R03/abort-umount.tsv" cluster) == "$FAILED_ARM" &&
   $(state_value "$R03/abort-umount.tsv" reason) == formal-arm-evidence-failure ]] ||
  die 'R03 abort-umount identity mismatch'
[[ ! -e "/tmp/jfs-t65-${RUN_ID}-mnt-${FAILED_INSTANCE}" ]] || die 'R03 mount path remains'
! pgrep -x fio >/dev/null || die 'fio exists'

SCRATCH=$(mktemp -d /tmp/production/t65-r03-invalid-inspect.XXXXXX)
cleanup_scratch() {
  [[ -n ${SCRATCH:-} && "$SCRATCH" == /tmp/production/t65-r03-invalid-inspect.* ]] || return 0
  find "$SCRATCH" -type f -delete 2>/dev/null || true
  find "$SCRATCH" -type l -delete 2>/dev/null || true
  find "$SCRATCH" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup_scratch EXIT
cp -a -- "$R03" "$SCRATCH/R03"
set +e
python3 "$ANALYZE" "$SCRATCH/R03" >"$SCRATCH/analyzer.stdout" 2>"$SCRATCH/analyzer.stderr"
analyzer_rc=$?
set -e
(( analyzer_rc != 0 )) || die 'frozen analyzer unexpectedly passed R03'
[[ ! -s "$SCRATCH/analyzer.stdout" ]] || die 'failed analyzer unexpectedly produced stdout'
mapfile -t failure_lines < <(sed -n 's/^E_T65_ANALYZE[[:space:]]*//p' "$SCRATCH/analyzer.stderr" | grep -F 'formal stability hard gate failed:')
(( ${#failure_lines[@]} == 1 )) || die 'expected exactly one frozen analyzer hard-gate failure line'
read -r official_cv official_ratio < <(parse_failure_line "${failure_lines[0]}")

[[ -s "$G03/GC_INSPECT_PASS" && -s "$G03/GC_DELETE_PASS" && -s "$G03/SEED_RETURN_PASS" &&
   -s "$G03/gc-inspect.tsv" && -s "$G03/gc-postcheck.tsv" && -s "$RESTORE_STATE" &&
   -s "$PRIVATE_CONF" && ! -e "$G03/volume.tsv" ]] || die 'G03 GC/seed-return identity is incomplete'
for key in pending leaked compacted delslices delfiles skipped; do
  [[ $(state_value "$G03/gc-postcheck.tsv" "$key") == 0 ]] || die "G03 postcheck $key is not zero"
done
[[ $(state_value "$G03/gc-postcheck.tsv" valid) == "$EXPECTED_VALID" ]] || die 'G03 postcheck valid count mismatch'
[[ $(state_value "$SEED_DIR/gc-baseline.tsv" valid) == "$EXPECTED_VALID" ]] || die 'formal seed GC baseline valid count mismatch'
[[ $(state_value "$G03/gc-postcheck.tsv" compacted) == "$(state_value "$SEED_DIR/gc-baseline.tsv" compacted)" ]] ||
  die 'G03 compacted count differs from formal baseline'
[[ $(state_value "$G03/gc-inspect.tsv" leaked) =~ ^[1-9][0-9]*$ ]] || die 'G03 inspect did not identify positive leaked objects'

[[ -s "$SEED_DIR/SEED_BUNDLE_PASS" && -s "$SEED_DIR/seed.tsv" && -s "$SEED_DIR/seed-meta.sha256" &&
   -s "$SEED_DIR/formal-clone-contract.sha256" && $(sha "$SEED_DIR/seed-meta.json.gz") == "$DUMP_SHA" ]] ||
  die 'formal seed bundle or dump identity mismatch'
(cd "$SEED_DIR" && sha256sum -c seed-meta.sha256 >/dev/null) || die 'formal seed metadata checksum failed'
(cd "$SEED_DIR" && sha256sum -c formal-clone-contract.sha256 >/dev/null) || die 'formal clone contract checksum failed'
[[ $(sha "$SEED_DIR/formal-clone-contract.tsv") == "$CLONE_CONTRACT_SHA" ]] || die 'formal clone contract SHA mismatch'
[[ $(state_value "$SEED_DIR/seed.tsv" uuid) == "$SEED_UUID" &&
   $(state_value "$SEED_DIR/seed.tsv" volume_name) == "$SEED_NAME" && "$VOLUME" == "$SEED_NAME" ]] ||
  die 'formal seed UUID/name mismatch'
[[ $(state_value "$RESTORE_STATE" uuid) == "$SEED_UUID" ]] || die 'G03 restore UUID mismatch'
[[ $(md5sum "$T65_JUICEFS_BIN" | awk '{print $1}') == "$JUICEFS_MD5" ]] || die 'JuiceFS binary identity mismatch'

! mountpoint -q "$MNT" || die 'G03 must never be mounted'
if pgrep -af -- "$T65_JUICEFS_BIN" 2>/dev/null | awk -v token="jfs-t65-${RUN_ID}" '$0 ~ / mount / && index($0,token)>0{found=1} END{exit !found}'; then
  die 'RUN-scoped JuiceFS mount process exists'
fi
"$T65_JUICEFS_BIN" status "$META" >"$SCRATCH/status.json"
identity=$(t65_status_identity "$SCRATCH/status.json") || die 'G03 live status identity invalid'
IFS=$'\t' read -r live_uuid live_name <<< "$identity"
[[ "$live_uuid" == "$SEED_UUID" && "$live_name" == "$SEED_NAME" ]] || die 'G03 live UUID/name mismatch'
t65_status_has_zero_sessions "$SCRATCH/status.json" || die 'G03 has a live session'

[[ $(sudo ceph health) == HEALTH_OK ]] || die 'Ceph is not HEALTH_OK'
pool=$(sudo ceph df --format=json | python3 -c '
import json,sys
d=json.load(sys.stdin); p=next(x for x in d["pools"] if x["name"]=="juicefs-data"); s=p["stats"]
print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))')
pool_objects=${pool%%$'\t'*}
[[ -s "$SEED_DIR/pool-seed.tsv" && -s "$SEED_DIR/pool-pre-format.tsv" ]] || die 'seed/pre-format pool baseline is missing'
seed_pool_objects=$(awk 'NR==1{print $1}' "$SEED_DIR/pool-seed.tsv")
pre_format_pool_objects=$(awk 'NR==1{print $1}' "$SEED_DIR/pool-pre-format.tsv")
[[ "$pool_objects" =~ ^[0-9]+$ && "$seed_pool_objects" =~ ^[0-9]+$ && "$pre_format_pool_objects" =~ ^[0-9]+$ ]] ||
  die 'pool object sample is invalid'
(( seed_pool_objects >= pre_format_pool_objects )) || die 'seed pool baseline precedes pre-format baseline numerically'
seed_creation_delta=$((seed_pool_objects - pre_format_pool_objects))
seed_creation_delta_error=$(abs_delta "$seed_creation_delta" "$EXPECTED_VALID")
(( seed_creation_delta_error <= MAX_POOL_OBJECT_DRIFT )) ||
  die "seed/pre-format delta does not match valid seed scale: delta=$seed_creation_delta valid=$EXPECTED_VALID"
pool_delta=$(abs_delta "$pool_objects" "$seed_pool_objects")
pool_within_seed_drift "$pool_objects" "$seed_pool_objects" || die "pool object drift exceeds seed contract: delta=$pool_delta"

t65_make_ssh_array
for node in "${T65_NODES[@]}"; do
  curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T65_TIKV_STATUS_PORT}/config" >/dev/null ||
    die "G03 TiKV unavailable: $node"
  "${T65_SSH[@]}" "$node" bash -s -- "$RUN_ID" "$node" <<'REMOTE' || die "remote G03/production identity failed: $node"
set -euo pipefail
run=$1; node=$2
[[ $(systemctl is-active pd) == active ]]
[[ $(systemctl is-active tikv 2>/dev/null || true) != active ]]
[[ -s "/tmp/jfs-t65-${run}-A1-G03-activation.tsv" ]]
[[ ! -e "/tmp/jfs-t65-${run}-B1-R03-activation.tsv" ]]
REMOTE
done
curl -fsS --connect-timeout 3 --max-time 8 "http://10.20.1.150:${T65_PD_CLIENT_PORT}/pd/api/v1/health" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==3 and all(x.get("health") is True for x in d)' ||
  die 'G03 PD health is not 3/3'
curl -fsS --connect-timeout 3 --max-time 8 "http://10.20.1.150:${T65_PD_CLIENT_PORT}/pd/api/v1/stores" |
  python3 -c 'import json,sys; s=json.load(sys.stdin).get("stores",[]); assert len(s)==3 and all(x.get("store",{}).get("state_name")=="Up" for x in s)' ||
  die 'G03 stores are not 3/3 Up'

[[ -s "$LEDGER" ]] || die 'client authorization ledger missing'
[[ $(awk -F '\t' '$3=="abort-umount" && $4=="03-22b-abort-umount-20260826-164047-R03-B1"{n++} END{print n+0}' "$LEDGER") == 1 ]] ||
  die 'abort-umount authorization count is not one'
[[ $(awk -F '\t' '$3=="gc-delete" && $4=="03-22b-gc-delete-20260826-164047-G03-A1"{n++} END{print n+0}' "$LEDGER") == 1 ]] ||
  die 'G03 delete authorization count is not one'
[[ $(awk -F '\t' '$3=="reset-seed-return-G03" && $4=="03-22b-reset-20260826-164047-G03-A1"{n++} END{print n+0}' "$LEDGER") == 1 ]] ||
  die 'G03 seed-return authorization count is not one'
[[ $(awk -F '\t' '$3=="r03-invalid-seed-destroy"{n++} END{print n+0}' "$LEDGER") == 0 ]] ||
  die 'one-shot seed-destroy authorization was already recorded'

printf 'R03_INVALID_SEED_DESTROY_INSPECT_PASS run=%s failed=%s gc=%s cv=%s w4_w1=%s pool=%q seed_pool=%s pre_format_pool=%s pool_seed_abs_delta=%s seed_creation_delta=%s\n' \
  "$RUN_ID" "$FAILED_INSTANCE" "$INSTANCE" "$official_cv" "$official_ratio" "$pool" \
  "$seed_pool_objects" "$pre_format_pool_objects" "$pool_delta" "$seed_creation_delta"
printf 'PLAN\tdestroy only seed UUID=%s Name=%s META=%s with frozen JuiceFS binary\n' "$SEED_UUID" "$SEED_NAME" "$META"
printf 'PLAN\twrite seed.destroyed.tsv mode=abort-invalid-run, RUN_INVALID.tsv classification=EVIDENCE_INVALID and G03/ABORT_SEED_DESTROY_PASS\n'
printf 'PLAN\tno GC, mount, cluster stop/start, reset, loop/backing/storage or production action\n'
[[ "$ACTION" == inspect ]] && exit 0

EXPECTED_AUTH="03-22b-r03-invalid-seed-destroy-${RUN_ID}-${INSTANCE}-${CLUSTER}"
[[ ${T65_R03_INVALID_DESTROY_AUTH:-} == "$EXPECTED_AUTH" ]] ||
  die "set exact T65_R03_INVALID_DESTROY_AUTH=$EXPECTED_AUTH"
t65_record_authorization "$RUN_ID" r03-invalid-seed-destroy "$T65_R03_INVALID_DESTROY_AUTH"

umask 077
mkdir "$RECOVERY"
cp "$SCRATCH/analyzer.stderr" "$RECOVERY/frozen-analyzer.stderr"
cp "$SCRATCH/status.json" "$RECOVERY/status-pre-destroy.json"
printf '%s\n' "$pool" > "$RECOVERY/pool-pre-destroy.tsv"
printf 'run_id\t%s\nfailed_instance\t%s\ngc_instance\t%s\nreason\t%s\nofficial_cv_pct\t%s\nofficial_w4_w1\t%s\nmanifest_sha256\t%s\nseed_uuid\t%s\nseed_name\t%s\nmeta\t%s\npool_abs_delta\t%s\n' \
  "$RUN_ID" "$FAILED_INSTANCE" "$INSTANCE" "$FAILURE_REASON" "$official_cv" "$official_ratio" \
  "$ACTIVE_MANIFEST_SHA" "$SEED_UUID" "$SEED_NAME" "$META" "$pool_delta" > "$RECOVERY/contract.tsv"
printf 'CEPH_CONF=%q %q destroy %q %q --yes\n' "$PRIVATE_CONF" "$T65_JUICEFS_BIN" "$META" "$SEED_UUID" > "$RECOVERY/command.plan"
printf 'destroy_epoch\tPENDING\nmode\tabort-invalid-run\nfailed_instance\t%s\ngc_instance\t%s\nmeta\t%s\nvolume_name\t%s\nuuid\t%s\n' \
  "$FAILED_INSTANCE" "$INSTANCE" "$META" "$SEED_NAME" "$SEED_UUID" > "$RECOVERY/seed.destroyed.tsv.pending"
printf 'classification\tEVIDENCE_INVALID\nfailed_instance\t%s\ngc_instance\t%s\nreason\t%s\nofficial_cv_pct\t%s\nofficial_w4_w1\t%s\n' \
  "$FAILED_INSTANCE" "$INSTANCE" "$FAILURE_REASON" "$official_cv" "$official_ratio" > "$RECOVERY/RUN_INVALID.tsv.pending"
(cd "$RECOVERY" && sha256sum contract.tsv command.plan frozen-analyzer.stderr pool-pre-destroy.tsv status-pre-destroy.json) > "$RECOVERY/pre-destroy.sha256"

"$T65_JUICEFS_BIN" destroy "$META" "$SEED_UUID" --yes > "$RECOVERY/seed-destroy.log" 2>&1 ||
  die "JuiceFS seed destroy failed; preserve recovery directory: $RECOVERY"
destroy_epoch=$(date +%s)
sed "s/^destroy_epoch[[:space:]]PENDING$/destroy_epoch\t${destroy_epoch}/" \
  "$RECOVERY/seed.destroyed.tsv.pending" > "$RECOVERY/seed.destroyed.tsv.final"
mv "$RECOVERY/seed.destroyed.tsv.final" "$SEED_DIR/seed.destroyed.tsv"
mv "$RECOVERY/RUN_INVALID.tsv.pending" "$ROOT/RUN_INVALID.tsv"
printf '%s\tfailed_instance=%s\treason=%s\n' "$destroy_epoch" "$FAILED_INSTANCE" "$FAILURE_REASON" > "$G03/ABORT_SEED_DESTROY_PASS"
printf '%s\n' "$destroy_epoch" > "$RECOVERY/DESTROY_COMPLETE"
(cd "$RECOVERY" && sha256sum contract.tsv command.plan frozen-analyzer.stderr pool-pre-destroy.tsv status-pre-destroy.json seed-destroy.log DESTROY_COMPLETE) > "$RECOVERY/post-destroy.sha256"
printf 'R03_INVALID_SEED_DESTROY_PASS failed_instance=%s gc_instance=%s uuid=%s evidence=INVALID\n' \
  "$FAILED_INSTANCE" "$INSTANCE" "$SEED_UUID"
