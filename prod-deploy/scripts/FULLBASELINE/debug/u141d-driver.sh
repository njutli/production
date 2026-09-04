#!/usr/bin/env bash
# U141d two-phase driver: A=randrw+randwrite, B=mseqwrite.
#
# This script deliberately reuses the frozen U141b collector.  It adds only the
# new matrix/state machine, exact mseqwrite reset, and stricter round completeness
# checks.  A phase is continuous; performance values never invalidate a sample.
set -euo pipefail
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COLLECT=${U141D_COLLECT:-$SCRIPT_DIR/u141b-collect.sh}
BASE_ANALYZE=${U141D_BASE_ANALYZE:-$SCRIPT_DIR/u141b-analyze.py}
ANALYZE=${U141D_ANALYZE:-$SCRIPT_DIR/u141d-analyze.py}
SCRUB_CONTROL=${U141D_SCRUB_CONTROL:-$SCRIPT_DIR/u141d-scrub-control.sh}
SCRUB_STATE_DIR=${U141D_SCRUB_STATE_DIR:-/tmp/production}
# U141d is a controlled benchmark: every Ceph gate must validate the exact
# scrub-paused contract instead of silently accepting arbitrary HEALTH_WARN.
export U141D_SCRUB_PAUSED=1

V4=${V4:-/tmp/FULLBASELINE_V4_U141D.sh}
V4_BASE=${V4_BASE:-/tmp/FULLBASELINE_V4.sh}
V4_RESULTS=${V4_RESULTS:-/tmp/opencode-fullbaseline-v4}
export V4 V4_BASE
MNT=${MNT:-/mnt/juicefs}
TEST_DIR=${TEST_DIR:-${MNT}/test_dir}
META=${META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
MSGR_CONF=${MSGR_CONF:-/tmp/t141-msgr8.conf}
MOUNT_OPTS=${MOUNT_OPTS:---max-uploads 150 --cache-size 0 --max-fuse-io 256K}

SHIM_V13=${SHIM_V13:-/tmp/t53-bin-new}
SHIM_V14=${SHIM_V14:-/tmp/t141p-bin}
BIN_V13=${BIN_V13:-/tmp/juicefs-03-8}
BIN_V14=${BIN_V14:-/tmp/juicefs-1.4.1-patched}
MD5_V13=de93563f11a5ff3bd94dd25a4e0283b1
MD5_V14=24fae0852051c80ca571cb2f20275d46

# Immutable, independently reviewed Phase A evidence used only by the explicit
# phase-b-only recovery path.  Do not accept caller-supplied replacements: the
# archive digest is the trust root that prevents a new Phase B run from being
# paired with arbitrary or mutable Phase A data.
PHASE_A_SOURCE_RUN_ID=20260830-122350
PHASE_A_SOURCE_ARCHIVE=/tmp/u141d-run5-phase-a-evidence-20260830.tar.gz
PHASE_A_SOURCE_SHA256=150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b
PHASE_A_SOURCE_ROOT=production/opencode-u141d-20260830-122350
PHASE_A_SOURCE_STATUS=VALID_WITH_PROTOCOL_DEVIATION_NO_OBSERVED_STATE_EFFECT

ARM_ORDER=(V13 V14 V14 V13 V14 V13 V13 V14)
WARM_A_ORDER=(V13 V14 V14 V13)
CANARY_B_ORDER=(V13 V14)

ROOT_MIN_FREE_KIB=20971520       # 20 GiB
OBJ_BOOTSTRAP_MAX=2500000
OBJ_SEED_TOL=8192
OBJ_SAMPLE_SPREAD_MAX=32
OBJ_POLL_MAX=20
OBJ_POLL_SLEEP=${OBJ_POLL_SLEEP:-30}
OBJ_SAMPLE_SLEEP=${OBJ_SAMPLE_SLEEP:-10}
ROUND_ABORT_SECONDS=2460         # 41 minutes
UMOUNT_QUIESCE_TIMEOUT=180

RUN_ROOT=""
RUN_ID=""

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

incident() {
  local severity=$1
  shift
  [[ -n ${RUN_ROOT:-} && -d ${RUN_ROOT:-/nonexistent} ]] || return 0
  local ledger="$RUN_ROOT/incidents.tsv"
  if [[ ! -f $ledger ]]; then
    printf 'ts\tepoch\tseverity\tmessage\n' > "$ledger" || return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$(date +%s)" "$severity" "$*" >> "$ledger" \
    || return 1
}

die() {
  local message=$*
  if ! incident FATAL "$message"; then
    printf 'U141D_INCIDENT_WRITE_FAIL: could not append FATAL to %s\n' \
      "${RUN_ROOT:-unset}/incidents.tsv" >&2
  fi
  printf 'U141D_DRIVER_FAIL: %s\n' "$message" >&2
  exit 1
}

set_root() {
  [[ $# -eq 1 && -n $1 ]] || die "RUN_ROOT argument required"
  local resolved base
  resolved=$(readlink -m -- "$1")
  case "$resolved" in
    /tmp/production/opencode-u141d-*) ;;
    *) die "RUN_ROOT outside exact scope /tmp/production/opencode-u141d-*: $resolved" ;;
  esac
  base=$(basename -- "$resolved")
  RUN_ID=${base#opencode-u141d-}
  [[ $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "RUN_ID contains unsupported characters: $RUN_ID"
  RUN_ROOT=$resolved
}

require_existing_root() {
  set_root "$1"
  [[ -d $RUN_ROOT && -f $RUN_ROOT/RUN_META.tsv ]] \
    || die "not an initialized U141d run root: $RUN_ROOT"
  grep -Fxq $'run_id\t'"$RUN_ID" "$RUN_ROOT/RUN_META.tsv" \
    || die "RUN_META run_id does not match path"
}

scrub_lease() {
  local phase=${1,,}
  [[ $phase == a || $phase == b ]] || die "invalid scrub lease phase: $1"
  printf '%s-phase-%s\n' "$RUN_ID" "$phase"
}

scrub_state_path() {
  local lease=$1 path
  path=$(U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" \
    bash "$SCRUB_CONTROL" state-path "$lease") \
    || die "cannot resolve scrub-control state path for lease=$lease"
  case "$path" in
    "$SCRUB_STATE_DIR"/u141d-scrub-control-*.tsv) ;;
    *) die "scrub-control returned out-of-scope state path: $path" ;;
  esac
  printf '%s\n' "$path"
}

assert_scrub_paused() {
  local lease=$1 tag=$2 out
  [[ -f $SCRUB_CONTROL ]] || die "scrub-control script missing: $SCRUB_CONTROL"
  out="$RUN_ROOT/fingerprint/scrub-control-${tag}.txt"
  if ! U141D_SCRUB_STATE_DIR="$SCRUB_STATE_DIR" \
       bash "$SCRUB_CONTROL" verify-paused "$lease" > "$out" 2>&1; then
    die "scrub pause lease verification failed lease=$lease tag=$tag; see $out"
  fi
}

snapshot_scrub_state() {
  local lease=$1 tag=$2 state out
  state=$(scrub_state_path "$lease")
  [[ -f $state ]] || die "scrub-control state missing for snapshot: $state"
  out="$RUN_ROOT/fingerprint/scrub-control-${tag}.state.tsv"
  cp -- "$state" "$out" || die "cannot snapshot scrub-control state: $state"
}

arm_shim() {
  case "$1" in V13) printf '%s\n' "$SHIM_V13" ;; V14) printf '%s\n' "$SHIM_V14" ;;
    *) die "unknown arm $1" ;; esac
}

arm_md5() {
  case "$1" in V13) printf '%s\n' "$MD5_V13" ;; V14) printf '%s\n' "$MD5_V14" ;;
    *) die "unknown arm $1" ;; esac
}

export_arm() {
  local arm=$1 shim
  shim=$(arm_shim "$arm")
  export PATH="${shim}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export CEPH_CONF="$MSGR_CONF"
  export JUICEFS_MOUNT_OPTS="$MOUNT_OPTS"
  export U141D_ACTIVE_ARM="$arm"
}

timing() {
  local label=$1 mark=$2
  [[ -f $RUN_ROOT/timing.tsv ]] || printf 'epoch\tlabel\tmark\n' > "$RUN_ROOT/timing.tsv"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$label" "$mark" >> "$RUN_ROOT/timing.tsv"
}

pool_objects() {
  sudo ceph df --format=json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
p = [x for x in d["pools"] if x["name"] == "juicefs-data"]
if len(p) != 1:
    raise SystemExit("juicefs-data pool count=%d" % len(p))
v = p[0]["stats"]["objects"]
if not isinstance(v, int) or v < 0:
    raise SystemExit("invalid objects=%r" % (v,))
print(v)
'
}

record_objects() {
  local tag=$1 value
  value=$(pool_objects) || die "cannot sample juicefs-data objects for $tag"
  [[ $value =~ ^[0-9]+$ ]] || die "non-numeric object sample for $tag: $value"
  [[ -f $RUN_ROOT/objects.tsv ]] || printf 'epoch\ttag\tobjects\n' > "$RUN_ROOT/objects.tsv"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$tag" "$value" >> "$RUN_ROOT/objects.tsv"
  printf '%s\n' "$value"
}

seed_objects() {
  [[ -s $RUN_ROOT/seed-objects.txt ]] || die "seed objects not established"
  local seed
  seed=$(<"$RUN_ROOT/seed-objects.txt")
  [[ $seed =~ ^[0-9]+$ ]] || die "invalid seed objects: $seed"
  printf '%s\n' "$seed"
}

capture_seed() {
  local values=() i value sorted min max median
  for i in 1 2 3; do
    value=$(record_objects "seed-sample-$i")
    values+=("$value")
    [[ $i -eq 3 ]] || sleep "$OBJ_SAMPLE_SLEEP"
  done
  mapfile -t sorted < <(printf '%s\n' "${values[@]}" | sort -n)
  min=${sorted[0]}; median=${sorted[1]}; max=${sorted[2]}
  (( max - min <= OBJ_SAMPLE_SPREAD_MAX )) \
    || die "seed object samples unstable: ${values[*]} spread=$((max-min))"
  printf '%s\n' "$median" > "$RUN_ROOT/seed-objects.txt"
  log "SEED_OBJECTS=$median samples=${values[*]} spread=$((max-min))"
}

wait_object_range() {
  local tag=$1 low=$2 high=$3 i value
  for i in $(seq 1 "$OBJ_POLL_MAX"); do
    value=$(record_objects "${tag}-poll-$i")
    log "object poll $i/$OBJ_POLL_MAX tag=$tag objects=$value range=[$low,$high]"
    if (( value >= low && value <= high )); then
      printf 'OBJECT_RANGE_PASS tag=%s objects=%s range=[%s,%s]\n' "$tag" "$value" "$low" "$high"
      return 0
    fi
    [[ $i -eq $OBJ_POLL_MAX ]] || sleep "$OBJ_POLL_SLEEP"
  done
  die "object range not reached for $tag: last=$value range=[$low,$high]"
}

jfs_pids_for_mnt() {
  local pid cmdline
  while IFS= read -r pid; do
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || continue
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    if [[ $cmdline == *"$MNT"* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -f 'juicefs.*mount' 2>/dev/null || true)
  # No matching PID is the expected quiescent result, not an enumeration error.
  # Keep command substitutions safe under `set -e` even when the last scanned
  # process does not match this mountpoint.
  return 0
}

worker_state_summary() {
  local pids=$1 pid ppid state wchan item out=""
  while IFS= read -r pid; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    if [[ -r /proc/$pid/status ]]; then
      ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
      state=$(awk '/^State:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
      wchan=$(cat "/proc/$pid/wchan" 2>/dev/null || true)
      item=$(printf '%s:%s:%s:%s' "$pid" "${ppid:-?}" "${state:-?}" "${wchan:-?}")
    else
      item=$(printf '%s:gone' "$pid")
    fi
    out=${out:+$out,}$item
  done <<<"$pids"
  printf '%s\n' "${out:-none}"
}

record_umount_poll() {
  local context=$1 method=$2 elapsed=$3 mounted=$4 pids=$5 states=$6
  local ledger="$RUN_ROOT/unmount-quiescence.tsv"
  [[ -f $ledger ]] \
    || printf 'epoch\tcontext\tarm\tmethod\telapsed_s\tmounted\tpids\tstates\n' > "$ledger"
  pids=${pids//$'\n'/,}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$context" "${U141D_ACTIVE_ARM:-UNKNOWN}" "$method" \
    "$elapsed" "$mounted" "${pids:-none}" "$states" >> "$ledger"
}

graceful_umount() {
  local context=${1:-unspecified} pids states i mounted method=none
  [[ $UMOUNT_QUIESCE_TIMEOUT =~ ^[0-9]+$ ]] \
    || die "invalid UMOUNT_QUIESCE_TIMEOUT=$UMOUNT_QUIESCE_TIMEOUT"
  (( UMOUNT_QUIESCE_TIMEOUT >= 60 && UMOUNT_QUIESCE_TIMEOUT <= 600 )) \
    || die "UMOUNT_QUIESCE_TIMEOUT=$UMOUNT_QUIESCE_TIMEOUT outside [60,600]"
  pids=$(jfs_pids_for_mnt)
  if ! mountpoint -q "$MNT" && [[ -z $pids ]]; then
    return 0
  fi
  if mountpoint -q "$MNT"; then
    if fusermount -u "$MNT" 2>/dev/null; then
      method=fusermount
      log "fusermount -u $MNT PASS"
    elif sudo umount "$MNT" 2>/dev/null; then
      method=sudo-umount
      log "sudo umount $MNT PASS"
    else
      die "graceful unmount failed; site preserved (no lazy/force fallback)"
    fi
  fi
  for ((i=0; i<=UMOUNT_QUIESCE_TIMEOUT; i++)); do
    pids=$(jfs_pids_for_mnt)
    mounted=0
    mountpoint -q "$MNT" && mounted=1
    states=$(worker_state_summary "$pids")
    record_umount_poll "$context" "$method" "$i" "$mounted" "$pids" "$states" \
      || die "cannot append unmount quiescence telemetry context=$context"
    if (( mounted == 0 )) && [[ -z $pids ]]; then
      incident INFO "unmount quiescent context=$context arm=${U141D_ACTIVE_ARM:-UNKNOWN} method=$method wait_s=$i"
      log "unmount quiescent context=$context arm=${U141D_ACTIVE_ARM:-UNKNOWN} wait_s=$i"
      return 0
    fi
    (( i < UMOUNT_QUIESCE_TIMEOUT )) || break
    sleep 1
  done
  die "$MNT or its JuiceFS worker remains after ${UMOUNT_QUIESCE_TIMEOUT}s; refuse kill fallback context=$context arm=${U141D_ACTIVE_ARM:-UNKNOWN} mounted=$mounted pids=${pids:-none} states=$states"
}

resolve_arm() {
  local arm=$1 out=$2 shim md5
  shim=$(arm_shim "$arm"); md5=$(arm_md5 "$arm")
  export_arm "$arm"
  bash "$COLLECT" resolve "$shim" "$md5" "$out" \
    || die "arm resolution failed for $arm"
}

mount_arm() {
  local arm=$1 tag=$2 shim md5
  local -a args
  read -r -a args <<<"$MOUNT_OPTS"
  shim=$(arm_shim "$arm"); md5=$(arm_md5 "$arm")
  resolve_arm "$arm" "$RUN_ROOT/fingerprint/resolve-${tag}-${arm}.txt"
  log "mount $arm tag=$tag"
  juicefs mount -d "${args[@]}" "$META" "$MNT" > "$RUN_ROOT/fingerprint/mount-command-${tag}-${arm}.log" 2>&1 \
    || die "mount command failed arm=$arm tag=$tag"
  sleep 3
  mountpoint -q "$MNT" || die "mount not present arm=$arm tag=$tag"
  bash "$COLLECT" mount "$RUN_ROOT/fingerprint/mount-${tag}-${arm}.txt" \
    || die "mount fingerprint failed arm=$arm tag=$tag"
  bash "$COLLECT" gate-mount "$RUN_ROOT/fingerprint/mount-${tag}-${arm}.txt" "$md5" \
    || die "mount identity gate failed arm=$arm tag=$tag"
}

extract_status_json() {
  local raw=$1 out=$2
  python3 - "$raw" "$out" <<'PY'
import json, sys
raw, out = sys.argv[1:]
text = open(raw, errors="replace").read()
start, end = text.find("{"), text.rfind("}")
if start < 0 or end < start:
    raise SystemExit("no JSON object in juicefs status output")
data = json.loads(text[start:end + 1])
with open(out, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

cmd_p0() {
  local sequence=(V14 V13 V14) i=0 arm raw json
  for arm in "${sequence[@]}"; do
    i=$((i + 1))
    mount_arm "$arm" "P0-$i"
    raw="$RUN_ROOT/p0/status-$i-$arm.raw.txt"
    json="$RUN_ROOT/p0/status-$i-$arm.json"
    juicefs status "$META" > "$raw" 2>&1 \
      || die "P0 status command failed arm=$arm step=$i"
    extract_status_json "$raw" "$json" \
      || die "P0 status JSON invalid arm=$arm step=$i"
    graceful_umount "P0-$i-$arm"
  done
  python3 - "$RUN_ROOT/p0/status-2-V13.json" \
    "$RUN_ROOT/p0/status-1-V14.json" "$RUN_ROOT/p0/status-3-V14.json" \
    > "$RUN_ROOT/p0/settings-compatibility.txt" <<'PY'
import json, sys
def setting(path):
    data = json.load(open(path))
    value = data.get("Setting")
    if not isinstance(value, dict):
        raise SystemExit("%s lacks Setting object" % path)
    return value
v13, v14a, v14b = map(setting, sys.argv[1:])
if v14a != v14b:
    raise SystemExit("two V14 Setting objects differ")
k13, k14 = set(v13), set(v14a)
extra13, extra14 = k13 - k14, k14 - k13
bad_common = [k for k in sorted(k13 & k14) if v13[k] != v14a[k]]
print("extra_in_v13=%s" % sorted(extra13))
print("extra_in_v14=%s" % sorted(extra14))
print("different_common=%s" % bad_common)
if extra13 or not extra14.issubset({"Tiers"}) or bad_common:
    raise SystemExit("settings compatibility gate failed")
print("P0_SETTINGS_COMPATIBLE: PASS")
PY
  incident INFO "P0 rollback sequence V14->V13->V14 PASS"
}

delete_mseq_payload() {
  mount_arm V13 "drain-$1"
  local before after
  before=$(find "$TEST_DIR/mseqwrite" -maxdepth 1 -type f -name 'mseqwrite.*.0' 2>/dev/null | wc -l)
  rm -f "$TEST_DIR/mseqwrite/mseqwrite."*.0
  after=$(find "$TEST_DIR/mseqwrite" -maxdepth 1 -type f -name 'mseqwrite.*.0' 2>/dev/null | wc -l)
  log "mseq payload files $before -> $after"
  (( after == 0 )) || die "mseq payload deletion incomplete: $after files remain"
  graceful_umount "mseq-drain-$1"
}

run_gc_delete() {
  local tag=$1 out="$RUN_ROOT/gc/gc-delete-${tag}.log"
  export_arm V13
  log "juicefs gc --delete tag=$tag"
  juicefs gc --delete --threads 32 "$META" > "$out" 2>&1 \
    || die "juicefs gc --delete failed tag=$tag"
}

bootstrap_drain() {
  local tag=$1
  incident INFO "bootstrap drain begin tag=$tag"
  graceful_umount "bootstrap-$tag-pre"
  delete_mseq_payload "$tag"
  run_gc_delete "$tag"
  wait_object_range "$tag" 0 "$OBJ_BOOTSTRAP_MAX"
  incident INFO "bootstrap drain end tag=$tag"
}

drain_to_seed() {
  local tag=$1 seed low high
  incident INFO "seed drain begin tag=$tag"
  graceful_umount "seed-drain-$tag-pre"
  delete_mseq_payload "$tag"
  run_gc_delete "$tag"
  seed=$(seed_objects)
  low=$(( seed > OBJ_SEED_TOL ? seed - OBJ_SEED_TOL : 0 ))
  high=$(( seed + OBJ_SEED_TOL ))
  wait_object_range "$tag" "$low" "$high"
  incident INFO "seed drain end tag=$tag"
}

write_matrix() {
  local out=$1 i arm label
  printf 'stage\tkind\tindex\tarm\tlabel\titems\tformal\n' > "$out"
  for i in $(seq 1 4); do
    arm=${WARM_A_ORDER[$((i - 1))]}
    label=$(printf 'U141D-%s-A-W%02d-%s' "$RUN_ID" "$i" "$arm")
    printf 'A\twarmup\t%02d\t%s\t%s\trandrw randwrite\t0\n' "$i" "$arm" "$label" >> "$out"
  done
  for i in $(seq 1 8); do
    arm=${ARM_ORDER[$((i - 1))]}
    label=$(printf 'U141D-%s-A-R%02d-%s' "$RUN_ID" "$i" "$arm")
    printf 'A\tformal\t%02d\t%s\t%s\trandrw randwrite\t1\n' "$i" "$arm" "$label" >> "$out"
  done
  for i in $(seq 1 2); do
    arm=${CANARY_B_ORDER[$((i - 1))]}
    label=$(printf 'U141D-%s-B-C%02d-%s' "$RUN_ID" "$i" "$arm")
    printf 'B\tcanary\t%02d\t%s\t%s\tmseqwrite\t0\n' "$i" "$arm" "$label" >> "$out"
  done
  for i in $(seq 1 8); do
    arm=${ARM_ORDER[$((i - 1))]}
    label=$(printf 'U141D-%s-B-R%02d-%s' "$RUN_ID" "$i" "$arm")
    printf 'B\tformal\t%02d\t%s\t%s\tmseqwrite\t1\n' "$i" "$arm" "$label" >> "$out"
  done
  [[ $(( $(wc -l < "$out") - 1 )) -eq 22 ]] || die "matrix row count is not 22"
}

print_prereg() {
  cat <<'EOF'
key	value
candidate_v13_md5	de93563f11a5ff3bd94dd25a4e0283b1
candidate_v14_md5	24fae0852051c80ca571cb2f20275d46
formal_window_s	15,175
estimator	per_second_all_job_sum_arithmetic_mean
randrw_endpoints	read,write_separate_never_sum
model	bw~centered_round+centered_round_squared+arm_v14
effect_denominator	mean_of_v13_round_means
formal_rounds_per_phase	8
arm_order	V13,V14,V14,V13,V14,V13,V13,V14
phase_a_items	randrw,randwrite
phase_a_warmups	V13,V14,V14,V13_fixed_no_dynamic_extension
phase_b_items	mseqwrite
phase_b_canaries	V13,V14
phase_b_reset	before_every_canary_and_formal_round
seed_object_tolerance	8192
precision_halfwidth_pct	5
control_review_line_pct	-5
material_redline_pct	-10
replacement_verdict	deferred_until_human_review
scrub_condition	SCRUB_PAUSED_FOR_CONTROLLED_BENCHMARK
scrub_scope	separate_phase_a_and_phase_b_leases
scrub_health_exception	OSDMAP_FLAGS_only
unmount_quiescence_timeout_s	180
unmount_completion	mountpoint_absent_and_matching_worker_pids_zero
EOF
}

write_runtime_provenance() {
  local out="$RUN_ROOT/RUNTIME_PROVENANCE.sha256" file
  : > "$out"
  for file in "$0" "$COLLECT" "$BASE_ANALYZE" "$ANALYZE" "$SCRUB_CONTROL" \
              "$V4_BASE" "$V4" "$MSGR_CONF" \
              "$BIN_V13" "$BIN_V14"; do
    [[ -f $file ]] || die "provenance input missing: $file"
    sha256sum "$file" >> "$out"
  done
}

verify_phase_a_source_archive() {
  local out="$RUN_ROOT/fingerprint/phase-a-source-archive-members.txt" got
  [[ -f $PHASE_A_SOURCE_ARCHIVE && -r $PHASE_A_SOURCE_ARCHIVE ]] \
    || die "reviewed Phase A archive missing or unreadable: $PHASE_A_SOURCE_ARCHIVE"
  got=$(sha256sum "$PHASE_A_SOURCE_ARCHIVE" | awk '{print $1}')
  [[ $got == "$PHASE_A_SOURCE_SHA256" ]] \
    || die "reviewed Phase A archive SHA256 mismatch: got=$got expected=$PHASE_A_SOURCE_SHA256"
  tar -tzf "$PHASE_A_SOURCE_ARCHIVE" > "$out" \
    || die "cannot list reviewed Phase A archive"
  python3 - "$out" "$PHASE_A_SOURCE_ROOT" <<'PY' \
    || die "reviewed Phase A archive member contract failed"
import pathlib, sys

listing, root = sys.argv[1:]
members = [line.rstrip("\n") for line in open(listing, encoding="utf-8")]
if not members:
    raise SystemExit("archive member list is empty")
for name in members:
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit("unsafe archive member: %s" % name)
required = {
    root + "/PHASE_A_COMPLETE",
    root + "/RUN_META.tsv",
    root + "/MATRIX_AUTHORIZED.tsv",
    root + "/RUNTIME_PROVENANCE.sha256",
    root + "/analysis/u141d-a-analysis.json",
    root + "/closure/phase-a/SHA256SUMS",
    root + "/closure/phase-a/verify.txt",
}
missing = sorted(required - set(members))
if missing:
    raise SystemExit("required member(s) missing: %s" % missing)
for forbidden in (root + "/PHASE_B_COMPLETE", root + "/closure/final/SHA256SUMS"):
    if forbidden in members:
        raise SystemExit("archive unexpectedly contains Phase B/final evidence: %s" % forbidden)
print("PHASE_A_SOURCE_ARCHIVE_CONTRACT_PASS members=%d" % len(members))
PY
  {
    printf 'key\tvalue\n'
    printf 'source_run_id\t%s\n' "$PHASE_A_SOURCE_RUN_ID"
    printf 'source_archive\t%s\n' "$PHASE_A_SOURCE_ARCHIVE"
    printf 'source_archive_sha256\t%s\n' "$PHASE_A_SOURCE_SHA256"
    printf 'source_status\t%s\n' "$PHASE_A_SOURCE_STATUS"
    printf 'pairing_scope\tphase_b_only\n'
  } > "$RUN_ROOT/PHASE_A_SOURCE.tsv"
}

assert_phase_a_source_binding() {
  local got
  [[ -f $RUN_ROOT/PHASE_A_SOURCE.tsv ]] || die "PHASE_A_SOURCE.tsv missing"
  grep -Fxq $'source_run_id\t'"$PHASE_A_SOURCE_RUN_ID" "$RUN_ROOT/PHASE_A_SOURCE.tsv" \
    || die "Phase A source run binding mismatch"
  grep -Fxq $'source_archive\t'"$PHASE_A_SOURCE_ARCHIVE" "$RUN_ROOT/PHASE_A_SOURCE.tsv" \
    || die "Phase A source archive path binding mismatch"
  grep -Fxq $'source_archive_sha256\t'"$PHASE_A_SOURCE_SHA256" "$RUN_ROOT/PHASE_A_SOURCE.tsv" \
    || die "Phase A source archive SHA binding mismatch"
  grep -Fxq $'source_status\t'"$PHASE_A_SOURCE_STATUS" "$RUN_ROOT/PHASE_A_SOURCE.tsv" \
    || die "Phase A source evidence status mismatch"
  got=$(sha256sum "$PHASE_A_SOURCE_ARCHIVE" 2>/dev/null | awk '{print $1}') \
    || die "reviewed Phase A archive missing or unreadable during binding check"
  [[ $got == "$PHASE_A_SOURCE_SHA256" ]] \
    || die "reviewed Phase A archive no longer matches trusted SHA256"
}

cmd_init() {
  set_root "$1"
  [[ ! -e $RUN_ROOT ]] || die "RUN_ROOT already exists; RUN_ID reuse forbidden: $RUN_ROOT"
  mkdir -p "$RUN_ROOT"/{analysis,assets,closure,fingerprint,gc,p0,round-analysis,v4}
  printf 'key\tvalue\nrun_id\t%s\ncreated_epoch\t%s\n' "$RUN_ID" "$(date +%s)" > "$RUN_ROOT/RUN_META.tsv"
  printf 'epoch\tlabel\tmark\n' > "$RUN_ROOT/timing.tsv"
  printf 'ts\tepoch\tseverity\tmessage\n' > "$RUN_ROOT/incidents.tsv"
  printf 'epoch\tcontext\tarm\tmethod\telapsed_s\tmounted\tpids\tstates\n' \
    > "$RUN_ROOT/unmount-quiescence.tsv"
  printf 'epoch\ttag\tobjects\n' > "$RUN_ROOT/objects.tsv"
  printf 'LABEL\tround\tBW_MiBs\thit\tstatus\tpg_gate\tpg\tgear\n' > "$RUN_ROOT/rounds-u141d.tsv"
  incident INFO "init begin run_id=$RUN_ID"

  [[ -f $COLLECT && -f $BASE_ANALYZE && -f $ANALYZE && -f $SCRUB_CONTROL \
     && -f $V4_BASE && -f $V4 ]] \
    || die "required script missing"
  [[ -x $ANALYZE ]] || die "U141d analyzer is not directly executable: $ANALYZE"
  assert_scrub_paused "$(scrub_lease a)" init
  local free n
  free=$(df -Pk / | awk 'NR==2{print $4}')
  [[ $free =~ ^[0-9]+$ ]] || die "cannot parse root free KiB"
  (( free >= ROOT_MIN_FREE_KIB )) || die "root free ${free}KiB < ${ROOT_MIN_FREE_KIB}KiB"

  mountpoint -q "$MNT" && die "$MNT is already mounted; inspect ownership before U141d"
  [[ -z $(jfs_pids_for_mnt) ]] || die "JuiceFS worker for $MNT exists without a mount; inspect before U141d"
  n=$(pgrep -c -f '(^|/)fio( |$)' || true); (( n == 0 )) || die "foreign fio count=$n"
  n=$(mount | grep -cE 't6[456]' || true); (( n == 0 )) || die "t64/t65/t66 mount count=$n"
  n=$(losetup -l 2>/dev/null | grep -cE 't6[456]' || true); (( n == 0 )) || die "t64/t65/t66 loop count=$n"
  n=$(ss -ltn 2>/dev/null | grep -cE ':(12379|12380|30160|30180)' || true)
  (( n == 0 )) || die "temporary PD/TiKV listener count=$n"

  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-init.tsv" \
    || die "frozen manifest gate failed"
  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-init.txt" \
    || die "Ceph init gate failed"

  mount_arm V13 PREFLIGHT-ASSET
  bash "$COLLECT" assets "$RUN_ROOT/assets/assets-pre.tsv" \
    || die "asset preflight failed"
  graceful_umount "PREFLIGHT-ASSET"

  bootstrap_drain INIT
  capture_seed
  cmd_p0
  write_matrix "$RUN_ROOT/MATRIX_AUTHORIZED.tsv"
  print_prereg > "$RUN_ROOT/PREREG.tsv"
  write_runtime_provenance
  touch "$RUN_ROOT/INIT_COMPLETE"
  incident INFO "init end PASS seed=$(seed_objects)"
  printf 'U141D_INIT_PASS run_id=%s seed_objects=%s\n' "$RUN_ID" "$(seed_objects)"
}

cmd_init_b_only() {
  set_root "$1"
  [[ ! -e $RUN_ROOT ]] || die "RUN_ROOT already exists; RUN_ID reuse forbidden: $RUN_ROOT"
  mkdir -p "$RUN_ROOT"/{analysis,assets,closure,fingerprint,gc,p0,round-analysis,v4}
  {
    printf 'key\tvalue\n'
    printf 'run_id\t%s\n' "$RUN_ID"
    printf 'created_epoch\t%s\n' "$(date +%s)"
    printf 'run_mode\tphase-b-only\n'
    printf 'phase_a_source_run_id\t%s\n' "$PHASE_A_SOURCE_RUN_ID"
  } > "$RUN_ROOT/RUN_META.tsv"
  printf 'epoch\tlabel\tmark\n' > "$RUN_ROOT/timing.tsv"
  printf 'ts\tepoch\tseverity\tmessage\n' > "$RUN_ROOT/incidents.tsv"
  printf 'epoch\tcontext\tarm\tmethod\telapsed_s\tmounted\tpids\tstates\n' \
    > "$RUN_ROOT/unmount-quiescence.tsv"
  printf 'epoch\ttag\tobjects\n' > "$RUN_ROOT/objects.tsv"
  printf 'LABEL\tround\tBW_MiBs\thit\tstatus\tpg_gate\tpg\tgear\n' > "$RUN_ROOT/rounds-u141d.tsv"
  incident INFO "phase-b-only init begin run_id=$RUN_ID source_phase_a=$PHASE_A_SOURCE_RUN_ID"

  [[ -f $COLLECT && -f $BASE_ANALYZE && -f $ANALYZE && -f $SCRUB_CONTROL \
     && -f $V4_BASE && -f $V4 ]] \
    || die "required script missing"
  [[ -x $ANALYZE ]] || die "U141d analyzer is not directly executable: $ANALYZE"
  assert_scrub_paused "$(scrub_lease b)" init-b-only
  verify_phase_a_source_archive

  local free n
  free=$(df -Pk / | awk 'NR==2{print $4}')
  [[ $free =~ ^[0-9]+$ ]] || die "cannot parse root free KiB"
  (( free >= ROOT_MIN_FREE_KIB )) || die "root free ${free}KiB < ${ROOT_MIN_FREE_KIB}KiB"

  mountpoint -q "$MNT" && die "$MNT is already mounted; inspect ownership before U141d"
  [[ -z $(jfs_pids_for_mnt) ]] || die "JuiceFS worker for $MNT exists without a mount; inspect before U141d"
  n=$(pgrep -c -f '(^|/)fio( |$)' || true); (( n == 0 )) || die "foreign fio count=$n"
  n=$(mount | grep -cE 't6[456]' || true); (( n == 0 )) || die "t64/t65/t66 mount count=$n"
  n=$(losetup -l 2>/dev/null | grep -cE 't6[456]' || true); (( n == 0 )) || die "t64/t65/t66 loop count=$n"
  n=$(ss -ltn 2>/dev/null | grep -cE ':(12379|12380|30160|30180)' || true)
  (( n == 0 )) || die "temporary PD/TiKV listener count=$n"

  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-init-b-only.tsv" \
    || die "frozen manifest gate failed"
  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-init-b-only.txt" \
    || die "Ceph init-b-only gate failed"

  mount_arm V13 PREFLIGHT-B-ONLY-ASSET
  bash "$COLLECT" assets "$RUN_ROOT/assets/assets-pre.tsv" \
    || die "asset preflight failed"
  graceful_umount "PREFLIGHT-B-ONLY-ASSET"

  bootstrap_drain INIT-B-ONLY
  capture_seed
  cmd_p0
  write_matrix "$RUN_ROOT/MATRIX_AUTHORIZED.tsv"
  print_prereg > "$RUN_ROOT/PREREG.tsv"
  write_runtime_provenance
  sha256sum "$PHASE_A_SOURCE_ARCHIVE" >> "$RUN_ROOT/RUNTIME_PROVENANCE.sha256"
  touch "$RUN_ROOT/INIT_B_ONLY_COMPLETE"
  incident INFO "phase-b-only init end PASS seed=$(seed_objects) source_phase_a=$PHASE_A_SOURCE_RUN_ID"
  printf 'U141D_INIT_B_ONLY_PASS run_id=%s seed_objects=%s source_phase_a=%s\n' \
    "$RUN_ID" "$(seed_objects)" "$PHASE_A_SOURCE_RUN_ID"
}

matrix_lookup() {
  local stage=$1 kind=$2 index=$3
  awk -F'\t' -v s="$stage" -v k="$kind" -v i="$index" \
    'NR>1 && $1==s && $2==k && ($3+0)==(i+0) {print $4"\t"$5"\t"$6}' \
    "$RUN_ROOT/MATRIX_AUTHORIZED.tsv"
}

copy_round_rows() {
  local label=$1 expected_items=$2 rows_file="$V4_RESULTS/rounds.tsv" item row status
  local -a matches expected item_rows
  [[ -f $rows_file ]] || die "V4 rounds.tsv missing"
  read -r -a expected <<<"$expected_items"
  (( ${#expected[@]} > 0 )) || die "expected item list is empty for $label"
  mapfile -t matches < <(awk -F'\t' -v l="$label" '$1==l{print}' "$rows_file")
  (( ${#matches[@]} == ${#expected[@]} )) \
    || die "rounds.tsv expected ${#expected[@]} item row(s) for $label, got ${#matches[@]}"
  for item in "${expected[@]}"; do
    mapfile -t item_rows < <(
      awk -F'\t' -v l="$label" -v r="${item}-${label}-r1" '$1==l && $2==r{print}' "$rows_file"
    )
    (( ${#item_rows[@]} == 1 )) \
      || die "rounds.tsv expected exactly one row for item=$item label=$label, got ${#item_rows[@]}"
    row=${item_rows[0]}
    status=$(awk -F'\t' '{print $5}' <<<"$row")
    [[ $status == VALID ]] \
      || die "round status for item=$item label=$label is $status, expected VALID"
    printf '%s\n' "$row" >> "$RUN_ROOT/rounds-u141d.tsv"
  done
}

run_round() {
  local stage=$1 kind=$2 index=$3 arm=$4 label=$5 items=$6
  local expected_arm expected_label expected_items row start now elapsed rc src dst analysis_tmp
  local unclean_file unclean_before unclean_after instance_file v4_health_json v4_osd_json
  row=$(matrix_lookup "$stage" "$kind" "$index")
  [[ -n $row ]] || die "matrix row missing stage=$stage kind=$kind index=$index"
  IFS=$'\t' read -r expected_arm expected_label expected_items <<<"$row"
  [[ $arm == "$expected_arm" && $label == "$expected_label" && $items == "$expected_items" ]] \
    || die "runtime row differs from frozen matrix: got '$arm|$label|$items' expected '$row'"
  [[ ! -e $RUN_ROOT/v4/$label ]] || die "label destination already exists: $label"
  if [[ -f $V4_RESULTS/rounds.tsv ]] && awk -F'\t' -v l="$label" '$1==l{found=1} END{exit !found}' "$V4_RESULTS/rounds.tsv"; then
    die "label already exists in cumulative V4 rounds.tsv: $label"
  fi

  assert_scrub_paused "$(scrub_lease "$stage")" "${label}-entry"
  log "BEGIN $label items='$items'"
  incident INFO "round begin $label"
  timing "$label" BEGIN
  start=$(date +%s)
  record_objects "${label}-pre" >/dev/null
  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-${label}-pre.txt" \
    || die "Ceph pre gate failed for $label"
  resolve_arm "$arm" "$RUN_ROOT/fingerprint/resolve-${label}.txt"
  mountpoint -q "$MNT" && die "$label begins with an active mount; refuse V4 remount"
  [[ -z $(jfs_pids_for_mnt) ]] || die "$label begins with a lingering JuiceFS worker; refuse V4 remount"

  unclean_file="$V4_RESULTS/UNCLEAN_UMOUNT.txt"
  v4_health_json="$V4_RESULTS/ceph-health-pre-${label}.json"
  v4_osd_json="$V4_RESULTS/ceph-osd-dump-pre-${label}.json"
  [[ ! -e $v4_health_json && ! -e $v4_osd_json ]] \
    || die "task-specific V4 health sidecar already exists for unique label=$label"
  unclean_before=0
  [[ -f $unclean_file ]] && unclean_before=$(wc -l < "$unclean_file")

  set +e
  ITEMS="$items" OBJ_GATE=1 CEPH_SCRUB_CONTROLLED=1 \
    bash "$V4" "$label" 180 1 --remount > "$RUN_ROOT/v4-${label}.stdout.log" 2>&1
  rc=$?
  set -e
  printf 'rc=%s\n' "$rc" >> "$RUN_ROOT/v4-${label}.stdout.log"

  src="$V4_RESULTS/$label"
  dst="$RUN_ROOT/v4/$label"
  if [[ -d $src ]]; then
    cp -a "$src" "$dst" || die "cannot copy V4 artefacts for $label"
  fi
  if (( rc != 0 )); then
    [[ ! -f $v4_health_json ]] \
      || cp -- "$v4_health_json" "$RUN_ROOT/fingerprint/v4-ceph-health-${label}-failure.json"
    [[ ! -f $v4_osd_json ]] \
      || cp -- "$v4_osd_json" "$RUN_ROOT/fingerprint/v4-ceph-osd-dump-${label}-failure.json"
    bash "$COLLECT" mount "$RUN_ROOT/fingerprint/mount-${label}-failure.txt" 2>/dev/null || true
    die "V4 rc=$rc for $label; site preserved"
  fi
  [[ -s $v4_health_json && -s $v4_osd_json ]] \
    || die "task-specific V4 controlled-health sidecars missing for $label; site preserved"
  cp -- "$v4_health_json" "$RUN_ROOT/fingerprint/v4-ceph-health-${label}.json"
  cp -- "$v4_osd_json" "$RUN_ROOT/fingerprint/v4-ceph-osd-dump-${label}.json"
  [[ -d $dst ]] || die "V4 artefact directory missing for $label"
  unclean_after=0
  [[ -f $unclean_file ]] && unclean_after=$(wc -l < "$unclean_file")
  (( unclean_after == unclean_before )) \
    || die "V4 recorded a new UNCLEAN_UMOUNT for $label; evidence invalid"
  instance_file="$V4_RESULTS/jfs-instance-${label}.txt"
  if [[ -f $instance_file ]] && grep -Eq 'umount_mode=(term|kill)' "$instance_file"; then
    cp "$instance_file" "$RUN_ROOT/fingerprint/jfs-instance-${label}.txt"
    die "V4 used non-graceful remount mode for $label; evidence invalid"
  fi

  bash "$COLLECT" mount "$RUN_ROOT/fingerprint/mount-${label}-post.txt" \
    || die "mount fingerprint failed for $label"
  bash "$COLLECT" gate-mount "$RUN_ROOT/fingerprint/mount-${label}-post.txt" "$(arm_md5 "$arm")" \
    || die "mount identity failed for $label"
  copy_round_rows "$label" "$items"

  analysis_tmp="$RUN_ROOT/round-analysis/${label}.json.tmp"
  if ! "$ANALYZE" round "$dst" --expect "$items" > "$analysis_tmp" \
       2> "$RUN_ROOT/round-analysis/${label}.stderr.txt"; then
    die "round artefact/sample gate failed for $label; site preserved"
  fi
  mv "$analysis_tmp" "$RUN_ROOT/round-analysis/${label}.json"

  record_objects "${label}-post" >/dev/null
  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-${label}-post.txt" \
    || die "Ceph post gate failed for $label; site preserved"
  now=$(date +%s); elapsed=$((now - start))
  (( elapsed <= ROUND_ABORT_SECONDS )) \
    || die "round $label elapsed=${elapsed}s > ${ROUND_ABORT_SECONDS}s; site preserved"

  graceful_umount "$label"
  now=$(date +%s); elapsed=$((now - start))
  (( elapsed <= ROUND_ABORT_SECONDS )) \
    || die "round $label total elapsed=${elapsed}s > ${ROUND_ABORT_SECONDS}s after quiescent unmount"
  timing "$label" END
  incident INFO "round end $label rc=0 total_elapsed=${elapsed}s"
  log "END $label total_elapsed=${elapsed}s"
}

phase_asset_snapshot() {
  local tag=$1
  mount_arm V13 "ASSET-$tag"
  bash "$COLLECT" assets "$RUN_ROOT/assets/assets-${tag}.tsv" \
    || die "asset snapshot failed tag=$tag"
  graceful_umount "ASSET-$tag"
}

cmd_phase_a() {
  require_existing_root "$1"
  [[ -f $RUN_ROOT/INIT_COMPLETE ]] || die "init not complete"
  [[ ! -e $RUN_ROOT/PHASE_A_COMPLETE ]] || die "phase A already complete"
  assert_scrub_paused "$(scrub_lease a)" phase-a-entry
  incident INFO "phase A begin"

  local i row arm label items
  drain_to_seed A-PRE-W01
  for i in $(seq -w 1 4); do
    row=$(matrix_lookup A warmup "$i")
    IFS=$'\t' read -r arm label items <<<"$row"
    run_round A warmup "$i" "$arm" "$label" "$items"
  done
  drain_to_seed A-PRE-R01
  for i in $(seq -w 1 8); do
    [[ $i == 5 ]] && drain_to_seed A-PRE-R05
    row=$(matrix_lookup A formal "$i")
    IFS=$'\t' read -r arm label items <<<"$row"
    run_round A formal "$i" "$arm" "$label" "$items"
  done

  phase_asset_snapshot phase-a-post
  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-phase-a-post.tsv" \
    || die "phase A frozen gate failed"
  "$ANALYZE" matrix "$RUN_ROOT" A --output-dir "$RUN_ROOT/analysis" \
    > "$RUN_ROOT/analysis/phase-a-console.txt" \
    || die "phase A offline analysis could not consume complete matrix"
  assert_scrub_paused "$(scrub_lease a)" phase-a-exit
  touch "$RUN_ROOT/PHASE_A_COMPLETE"
  incident INFO "phase A end PASS (no replacement verdict)"
  echo "U141D_PHASE_A_PASS_NO_REPLACE_VERDICT"
}

run_phase_b_matrix() {
  local mode=$1
  [[ -x $ANALYZE ]] || die "U141d analyzer lost executable contract before Phase B: $ANALYZE"
  assert_scrub_paused "$(scrub_lease b)" phase-b-entry
  incident INFO "phase B begin mode=$mode (caller confirms human authorization)"

  local i row arm label items
  for i in $(seq -w 1 2); do
    drain_to_seed "B-PRE-C${i}"
    row=$(matrix_lookup B canary "$i")
    IFS=$'\t' read -r arm label items <<<"$row"
    run_round B canary "$i" "$arm" "$label" "$items"
  done
  for i in $(seq -w 1 8); do
    drain_to_seed "B-PRE-R${i}"
    row=$(matrix_lookup B formal "$i")
    IFS=$'\t' read -r arm label items <<<"$row"
    run_round B formal "$i" "$arm" "$label" "$items"
  done
  drain_to_seed B-FINAL

  phase_asset_snapshot phase-b-post
  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-phase-b-post.tsv" \
    || die "phase B frozen gate failed"
  "$ANALYZE" matrix "$RUN_ROOT" B --output-dir "$RUN_ROOT/analysis" \
    > "$RUN_ROOT/analysis/phase-b-console.txt" \
    || die "phase B offline analysis could not consume complete matrix"
  assert_scrub_paused "$(scrub_lease b)" phase-b-exit
  touch "$RUN_ROOT/PHASE_B_COMPLETE"
  [[ $mode != phase-b-only ]] || touch "$RUN_ROOT/PHASE_B_ONLY_COMPLETE"
  incident INFO "phase B end PASS mode=$mode (no replacement verdict)"
  printf 'U141D_PHASE_B_PASS_NO_REPLACE_VERDICT mode=%s\n' "$mode"
}

cmd_phase_b() {
  require_existing_root "$1"
  [[ -f $RUN_ROOT/PHASE_A_COMPLETE ]] || die "phase A not complete"
  [[ ! -e $RUN_ROOT/INIT_B_ONLY_COMPLETE ]] || die "full phase-b refuses phase-b-only run root"
  [[ ! -e $RUN_ROOT/PHASE_B_COMPLETE ]] || die "phase B already complete"
  run_phase_b_matrix full
}

cmd_phase_b_only() {
  require_existing_root "$1"
  grep -Fxq $'run_mode\tphase-b-only' "$RUN_ROOT/RUN_META.tsv" \
    || die "phase-b-only command requires run_mode=phase-b-only"
  [[ -f $RUN_ROOT/INIT_B_ONLY_COMPLETE ]] || die "phase-b-only init not complete"
  [[ ! -e $RUN_ROOT/PHASE_A_COMPLETE ]] \
    || die "phase-b-only run must not synthesize PHASE_A_COMPLETE"
  [[ ! -e $RUN_ROOT/PHASE_B_COMPLETE ]] || die "phase B already complete"
  assert_phase_a_source_binding
  run_phase_b_matrix phase-b-only
}

cmd_close() {
  require_existing_root "$1"
  local scope=${2:-} out
  [[ -x $ANALYZE ]] || die "U141d analyzer lost executable contract before closure: $ANALYZE"
  [[ $scope == phase-a || $scope == final || $scope == phase-b-only ]] \
    || die "close scope must be phase-a, final or phase-b-only"
  [[ ! -e $RUN_ROOT/closure/$scope ]] || die "closure scope already exists: $scope"
  local lease
  if [[ $scope == phase-a ]]; then
    lease=$(scrub_lease a)
  else
    lease=$(scrub_lease b)
  fi
  assert_scrub_paused "$lease" "closure-${scope}"
  if [[ $scope == phase-a ]]; then
    [[ -f $RUN_ROOT/PHASE_A_COMPLETE ]] || die "phase A marker missing"
    "$ANALYZE" matrix "$RUN_ROOT" A --output-dir "$RUN_ROOT/analysis" \
      > "$RUN_ROOT/analysis/phase-a-close-console.txt" \
      || die "phase A closure analysis failed"
  elif [[ $scope == final ]]; then
    [[ -f $RUN_ROOT/PHASE_A_COMPLETE && -f $RUN_ROOT/PHASE_B_COMPLETE ]] \
      || die "final closure requires both phase markers"
    "$ANALYZE" matrix "$RUN_ROOT" A --output-dir "$RUN_ROOT/analysis" \
      > "$RUN_ROOT/analysis/phase-a-final-console.txt" \
      || die "final phase A analysis failed"
    "$ANALYZE" matrix "$RUN_ROOT" B --output-dir "$RUN_ROOT/analysis" \
      > "$RUN_ROOT/analysis/phase-b-final-console.txt" \
      || die "final phase B analysis failed"
  else
    grep -Fxq $'run_mode\tphase-b-only' "$RUN_ROOT/RUN_META.tsv" \
      || die "phase-b-only closure requires run_mode=phase-b-only"
    [[ -f $RUN_ROOT/INIT_B_ONLY_COMPLETE && -f $RUN_ROOT/PHASE_B_COMPLETE \
       && -f $RUN_ROOT/PHASE_B_ONLY_COMPLETE ]] \
      || die "phase-b-only closure requires init and Phase B markers"
    [[ ! -e $RUN_ROOT/PHASE_A_COMPLETE ]] \
      || die "phase-b-only closure refuses synthesized Phase A marker"
    assert_phase_a_source_binding
    "$ANALYZE" matrix "$RUN_ROOT" B --output-dir "$RUN_ROOT/analysis" \
      > "$RUN_ROOT/analysis/phase-b-only-final-console.txt" \
      || die "phase-b-only closure analysis failed"
  fi
  mountpoint -q "$MNT" && die "closure refuses active mount $MNT"
  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-closure-${scope}.txt" \
    || die "closure Ceph gate failed"
  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-closure-${scope}.tsv" \
    || die "closure frozen gate failed"
  snapshot_scrub_state "$lease" "closure-${scope}-pre-restore"

  incident INFO "closure $scope evidence complete; no ledger writes after this row"
  out="$RUN_ROOT/closure/$scope"
  mkdir -p "$out"
  cp "$RUN_ROOT/incidents.tsv" "$out/incidents.snapshot.tsv"
  cp "$RUN_ROOT/timing.tsv" "$out/timing.snapshot.tsv"
  cp "$RUN_ROOT/unmount-quiescence.tsv" "$out/unmount-quiescence.snapshot.tsv"
  cp "$RUN_ROOT/objects.tsv" "$out/objects.snapshot.tsv"
  cp "$RUN_ROOT/rounds-u141d.tsv" "$out/rounds.snapshot.tsv"
  (
    cd "$RUN_ROOT"
    find . -type f ! -path "./closure/$scope/SHA256SUMS" -print0 \
      | sort -z | xargs -0 sha256sum > "closure/$scope/SHA256SUMS"
  )
  [[ -s $out/SHA256SUMS ]] || die "empty closure checksum file"
  (cd "$RUN_ROOT" && sha256sum -c "closure/$scope/SHA256SUMS") > "$out/verify.txt"
  # verify.txt is intentionally outside SHA256SUMS; no hashed file is changed now.
  printf 'U141D_CLOSURE_PASS scope=%s files=%s\n' "$scope" "$(wc -l < "$out/SHA256SUMS")"
}

verify_balance() {
  local sum13=0 sum14=0 q13=0 q14=0 n13=0 n14=0 i x2 q
  for i in $(seq 1 8); do
    x2=$((2 * i - 9)); q=$((x2 * x2))
    if [[ ${ARM_ORDER[$((i - 1))]} == V13 ]]; then
      sum13=$((sum13 + i)); q13=$((q13 + q)); n13=$((n13 + 1))
    else
      sum14=$((sum14 + i)); q14=$((q14 + q)); n14=$((n14 + 1))
    fi
  done
  (( n13 == 4 && n14 == 4 && sum13 == 18 && sum14 == 18 && q13 == q14 ))
}

self_test() {
  local failures=() td count empty_pid_rc empty_pid_output
  local delayed_rc timeout_rc delayed_root timeout_root
  check() { if eval "$2"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; failures+=("$1"); fi; }
  echo "=== matrix ==="
  check "formal order ABBA-BAAB" "[[ '${ARM_ORDER[*]}' == 'V13 V14 V14 V13 V14 V13 V13 V14' ]]"
  check "A warmup fixed symmetric" "[[ '${WARM_A_ORDER[*]}' == 'V13 V14 V14 V13' ]]"
  check "quadratic balance" "verify_balance"
  td=$(mktemp -d /tmp/u141d-driver-selftest.XXXXXX)
  RUN_ROOT=$td; RUN_ID=SELFTEST
  write_matrix "$td/matrix.tsv"
  count=$(( $(wc -l < "$td/matrix.tsv") - 1 ))
  check "matrix has 22 rows" "(( count == 22 ))"
  check "A has 4 warmups + 8 formal" "[[ \$(awk -F'\t' 'NR>1 && \$1==\"A\"{n++} END{print n+0}' '$td/matrix.tsv') -eq 12 ]]"
  check "B has 2 canaries + 8 formal" "[[ \$(awk -F'\t' 'NR>1 && \$1==\"B\"{n++} END{print n+0}' '$td/matrix.tsv') -eq 10 ]]"
  check "labels include RUN_ID" "grep -q 'U141D-SELFTEST-A-R01-V13' '$td/matrix.tsv'"

  echo "=== registered constants and safety ==="
  check "root free gate is 20 GiB" "(( ROOT_MIN_FREE_KIB == 20971520 ))"
  check "seed tolerance is 8192" "(( OBJ_SEED_TOL == 8192 ))"
  check "round abort uses seconds" "(( ROUND_ABORT_SECONDS == 2460 ))"
  check "unmount quiescence timeout is 180s" "(( UMOUNT_QUIESCE_TIMEOUT == 180 ))"
  check "V4 receives OBJ_GATE=1" "grep -q 'ITEMS=\"\$items\" OBJ_GATE=1' '$0'"
  check "V4 receives exact controlled-scrub health mode" \
    "grep -q 'OBJ_GATE=1 CEPH_SCRUB_CONTROLLED=1' '$0'"
  check "mseq deletion exact and non-recursive" "grep -Fq 'rm -f \"\$TEST_DIR/mseqwrite/mseqwrite.\"*.0' '$0'"
  check "candidate md5 V13" "[[ \$(arm_md5 V13) == '$MD5_V13' ]]"
  check "candidate md5 V14" "[[ \$(arm_md5 V14) == '$MD5_V14' ]]"
  check "Phase A source run is frozen" "[[ '$PHASE_A_SOURCE_RUN_ID' == 20260830-122350 ]]"
  check "Phase A source archive SHA is frozen" \
    "[[ '$PHASE_A_SOURCE_SHA256' == 150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b ]]"
  check "full-run R05 reset uses the actual one-digit seq value" \
    "grep -Fq '[[ \$i == 5 ]] && drain_to_seed A-PRE-R05' '$0'"
  check "phase-b-only uses distinct markers and never synthesizes Phase A" \
    "grep -q 'INIT_B_ONLY_COMPLETE' '$0' && grep -q 'PHASE_B_ONLY_COMPLETE' '$0' && grep -q 'must not synthesize PHASE_A_COMPLETE' '$0'"

  echo "=== PID enumerator errexit contract ==="
  set +e
  empty_pid_output=$(
    set -e
    MNT=/tmp/u141d-selftest-must-not-match-any-process
    pgrep() { printf '%s\n' "$$"; }
    pids=$(jfs_pids_for_mnt)
    [[ -z $pids ]]
  )
  empty_pid_rc=$?
  set -e
  check "no matching mount worker is success under errexit" \
    "(( empty_pid_rc == 0 )) && [[ -z \$empty_pid_output ]]"

  echo "=== graceful unmount quiescence ==="
  delayed_root="$td/delayed"
  timeout_root="$td/timeout"
  mkdir -p "$delayed_root" "$timeout_root"
  set +e
  (
    RUN_ROOT=$delayed_root
    RUN_ID=SELFTEST-DELAYED
    MNT="$delayed_root/mnt"
    U141D_ACTIVE_ARM=V14
    UMOUNT_QUIESCE_TIMEOUT=60
    touch "$delayed_root/mounted"
    printf '3\n' > "$delayed_root/linger-polls"
    mountpoint() { [[ -f $delayed_root/mounted ]]; }
    fusermount() { rm -f "$delayed_root/mounted"; return 0; }
    jfs_pids_for_mnt() {
      mock_remaining=$(<"$delayed_root/linger-polls")
      if (( mock_remaining > 0 )); then
        printf '999999\n'
        printf '%s\n' "$((mock_remaining - 1))" > "$delayed_root/linger-polls"
      fi
    }
    sleep() { :; }
    graceful_umount SELFTEST-DELAYED
  ) > "$delayed_root/console.txt" 2>&1
  delayed_rc=$?
  (
    RUN_ROOT=$timeout_root
    RUN_ID=SELFTEST-TIMEOUT
    MNT="$timeout_root/mnt"
    U141D_ACTIVE_ARM=V14
    UMOUNT_QUIESCE_TIMEOUT=60
    touch "$timeout_root/mounted"
    mountpoint() { [[ -f $timeout_root/mounted ]]; }
    fusermount() { rm -f "$timeout_root/mounted"; return 0; }
    jfs_pids_for_mnt() { printf '888888\n'; }
    sleep() { :; }
    graceful_umount SELFTEST-TIMEOUT
  ) > "$timeout_root/console.txt" 2>&1
  timeout_rc=$?
  set -e
  check "delayed worker exit succeeds only after quiescence" \
    "(( delayed_rc == 0 )) && awk -F'\\t' 'NR>1 && \$2==\"SELFTEST-DELAYED\" && \$6==0 && \$7==\"none\" && \$5>=1{ok=1} END{exit !ok}' '$delayed_root/unmount-quiescence.tsv'"
  check "worker beyond timeout fails without kill fallback" \
    "(( timeout_rc != 0 )) && grep -q 'remains after 60s; refuse kill fallback' '$timeout_root/console.txt'"
  check "timeout FATAL is appended to incidents" \
    "grep -q $'\\tFATAL\\t.*remains after 60s' '$timeout_root/incidents.tsv'"

  find "$td" -depth -delete
  if (( ${#failures[@]} )); then
    echo "U141D_DRIVER_SELFTEST: FAIL -> ${failures[*]}"
    return 1
  fi
  echo "U141D_DRIVER_SELFTEST: PASS"
}

usage() {
  sed -n '2,12p' "$0"
  cat <<'EOF'
Usage:
  u141d-driver.sh --self-test
  u141d-driver.sh --print-prereg
  u141d-driver.sh init <RUN_ROOT>
  u141d-driver.sh init-b-only <NEW_RUN_ROOT>
  u141d-driver.sh phase-a <RUN_ROOT>
  u141d-driver.sh phase-b <RUN_ROOT>
  u141d-driver.sh phase-b-only <NEW_RUN_ROOT>
  u141d-driver.sh close <RUN_ROOT> <phase-a|final|phase-b-only>
EOF
}

case "${1:-}" in
  --self-test) self_test ;;
  --print-prereg) print_prereg ;;
  init) shift; [[ $# -eq 1 ]] || { usage; exit 1; }; cmd_init "$1" ;;
  init-b-only) shift; [[ $# -eq 1 ]] || { usage; exit 1; }; cmd_init_b_only "$1" ;;
  phase-a) shift; [[ $# -eq 1 ]] || { usage; exit 1; }; cmd_phase_a "$1" ;;
  phase-b) shift; [[ $# -eq 1 ]] || { usage; exit 1; }; cmd_phase_b "$1" ;;
  phase-b-only) shift; [[ $# -eq 1 ]] || { usage; exit 1; }; cmd_phase_b_only "$1" ;;
  close) shift; [[ $# -eq 2 ]] || { usage; exit 1; }; cmd_close "$1" "$2" ;;
  *) usage; exit 1 ;;
esac
