#!/usr/bin/env bash
# u141b-driver.sh -- U141b 32-round matrix driver.
#
# Task book: doc/perf-tasks/u141b-juicefs-141-replace-131-decision.md
# Method:    skills/EVIDENCE-INTEGRITY-SKILL.md (§1 口径 / §2 平衡 / §4 状态机 / §5 Gate0)
#
# One V4 invocation == one round == ITEMS x REPEAT=1, so that arms interleave at
# ROUND granularity (not block granularity).  Arm switching happens ONLY through
# PATH shim selection; the V4 script itself is frozen and never modified.
#
# Usage:
#   u141b-driver.sh --self-test
#   u141b-driver.sh matrix <RUN_ROOT>                 emit the frozen 32-row matrix
#   u141b-driver.sh preflight <RUN_ROOT>              stage I (S02..S08)
#   u141b-driver.sh phase <RUN_ROOT> <P1|P2|P3|P4>    run 8 rounds of one phase
#   u141b-driver.sh drain <RUN_ROOT> <tag>            payload delete + gc --delete
#
# ⛔ Never: rm with recursive force, lazy/force umount, bulk loop detach,
#          pattern kill, kill of a mount pid, same-RUN hot fix, RUN_ID reuse.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COLLECT="$SCRIPT_DIR/u141b-collect.sh"
ANALYZE="$SCRIPT_DIR/u141b-analyze.py"

V4=${V4:-/tmp/FULLBASELINE_V4.sh}
V4_RESULTS=${V4_RESULTS:-/tmp/opencode-fullbaseline-v4}
MNT=${MNT:-/mnt/juicefs}
TEST_DIR=${TEST_DIR:-${MNT}/test_dir}
META=${META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
MSGR_CONF=${MSGR_CONF:-/tmp/t141-msgr8.conf}
MOUNT_OPTS=${MOUNT_OPTS:---max-uploads 150 --cache-size 0 --max-fuse-io 256K}

SHIM_V13=/tmp/t53-bin-new
SHIM_V14=/tmp/t141p-bin
MD5_V13=de93563f11a5ff3bd94dd25a4e0283b1
MD5_V14=24fae0852051c80ca571cb2f20275d46

# frozen order (task book §3.1).  Positions: V13={1,4,6,7} V14={2,3,5,8}, both mean 4.5
ARM_ORDER=(V13 V14 V14 V13 V14 V13 V13 V14)

OBJ_START_MAX=3110000       # S09 hard gate -- no SOFT-PASS in this task
OBJ_DRAIN_TARGET=2500000    # drain success threshold
DRAIN_POLL_MAX=20
DRAIN_POLL_SLEEP=30

declare -A PHASE_ITEMS=(
  [P1]="seqread mseqread randread"
  [P2]="randrw seqwrite"
  [P3]="randwrite"
  [P4]="mseqwrite"
)
declare -A PHASE_EXPECT_MIN=([P1]=13 [P2]=24 [P3]=18 [P4]=22)   # minutes, for S01
declare -A PHASE_EXPECT_MAX=([P1]=20 [P2]=35 [P3]=26 [P4]=32)

RUN_ROOT=""

# ------------------------------------------------------------------ logging

log()  { echo "[$(date -Is)] $*"; }
die()  { echo "DRIVER_FAIL: $*" >&2; incident FATAL "$*" 2>/dev/null || true; exit 1; }

incident() {
  local sev=$1
  shift
  [[ -n $RUN_ROOT ]] || return 0
  local f="$RUN_ROOT/incidents.tsv"
  [[ -f $f ]] || printf 'ts\tepoch\tseverity\tmessage\n' > "$f"
  # append-only; never rewrite an existing row (D28)
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$(date +%s)" "$sev" "$*" >> "$f"
}

timing() {
  local label=$1
  local mark=$2
  local f="$RUN_ROOT/timing.tsv"
  [[ -f $f ]] || printf 'epoch\tlabel\tmark\n' > "$f"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$label" "$mark" >> "$f"
}

arm_shim() { [[ $1 == V13 ]] && echo "$SHIM_V13" || echo "$SHIM_V14"; }
arm_md5()  { [[ $1 == V13 ]] && echo "$MD5_V13"  || echo "$MD5_V14"; }

# ------------------------------------------------------------------ matrix

cmd_matrix() {
  RUN_ROOT=$1
  mkdir -p "$RUN_ROOT"
  local f="$RUN_ROOT/MATRIX_AUTHORIZED.tsv"
  printf 'phase\tround\tarm\tbinary_md5\tshim\titems\n' > "$f"
  local ph i arm
  for ph in P1 P2 P3 P4; do
    for i in $(seq 1 8); do
      arm=${ARM_ORDER[$((i - 1))]}
      printf '%s\tR%02d\t%s\t%s\t%s\t%s\n' \
        "$ph" "$i" "$arm" "$(arm_md5 "$arm")" "$(arm_shim "$arm")" "${PHASE_ITEMS[$ph]}" >> "$f"
    done
  done
  local n
  n=$(( $(wc -l < "$f") - 1 ))
  [[ $n -eq 32 ]] || die "matrix should have 32 rows, got $n"
  log "matrix frozen: $f ($n rows)"
  cat "$f"
}

verify_balance() {
  local a13=0 a14=0 n13=0 n14=0 i
  for i in $(seq 1 8); do
    if [[ ${ARM_ORDER[$((i - 1))]} == V13 ]]; then
      a13=$((a13 + i)); n13=$((n13 + 1))
    else
      a14=$((a14 + i)); n14=$((n14 + 1))
    fi
  done
  [[ $n13 -eq 4 && $n14 -eq 4 ]] || die "each arm must hold 4 slots, got $n13/$n14"
  # mean must be exactly 4.5 for both -> x2 == 9
  [[ $((a13 * 2 / n13)) -eq 9 && $((a14 * 2 / n14)) -eq 9 ]] \
    || die "position means unbalanced: V13 sum=$a13 V14 sum=$a14"
  echo "BALANCE_PASS V13 sum=$a13 mean=4.5 | V14 sum=$a14 mean=4.5"
}

# ------------------------------------------------------------------ unmount

graceful_umount() {
  mountpoint -q "$MNT" || { log "not mounted, nothing to unmount"; return 0; }
  if fusermount -u "$MNT" 2>/dev/null; then
    log "fusermount -u ok"
  elif sudo umount "$MNT" 2>/dev/null; then
    log "sudo umount ok"
  else
    incident FATAL "graceful umount of $MNT failed -- site preserved, STOP"
    die "S03/S19 graceful umount failed. Site preserved on purpose: do NOT use -z/-l, do NOT kill the mount pid."
  fi
  sleep 3
  mountpoint -q "$MNT" && die "still mounted after umount"
  return 0
}

# ------------------------------------------------------------------ drain

cmd_drain() {
  RUN_ROOT=$1
  local tag=${2:-drain}
  incident INFO "drain begin tag=$tag"
  graceful_umount

  # drain always runs on V13 so that it is a constant across arms
  export PATH="${SHIM_V13}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export CEPH_CONF="$MSGR_CONF"
  bash "$COLLECT" resolve "$SHIM_V13" "$MD5_V13" "$RUN_ROOT/fingerprint/drain-resolve-$tag.txt" >/dev/null

  log "drain: mounting V13 to delete payload"
  juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" >/dev/null 2>&1
  sleep 3
  mountpoint -q "$MNT" || die "drain: mount failed"

  # only the two regenerable payload dirs; the 384 frozen assets are NOT touched
  local before after
  before=$(ls -1 "${TEST_DIR}/seqwrite/" "${TEST_DIR}/mseqwrite/" 2>/dev/null | wc -l)
  rm -f "${TEST_DIR}/seqwrite/seqwrite."*.0 2>/dev/null || true
  rm -f "${TEST_DIR}/mseqwrite/mseqwrite."*.0 2>/dev/null || true
  after=$(ls -1 "${TEST_DIR}/seqwrite/" "${TEST_DIR}/mseqwrite/" 2>/dev/null | wc -l)
  log "drain: payload files $before -> $after"
  graceful_umount

  log "drain: juicefs gc --delete"
  juicefs gc --delete --threads 32 "$META" 2>&1 | tail -5 \
    | tee "$RUN_ROOT/drain-gc-$tag.txt"

  local i objs
  for i in $(seq 1 $DRAIN_POLL_MAX); do
    objs=$(sudo ceph df --format=json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
print([x for x in d["pools"] if x["name"] == "juicefs-data"][0]["stats"]["objects"])
')
    log "drain poll $i/$DRAIN_POLL_MAX objects=$objs target<=$OBJ_DRAIN_TARGET"
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$tag" "$i" "$objs" \
      >> "$RUN_ROOT/drain-poll.tsv"
    if [[ -n $objs && $objs -le $OBJ_DRAIN_TARGET ]]; then
      incident INFO "drain end tag=$tag objects=$objs DRAIN_PASS"
      echo "DRAIN_PASS objects=$objs"
      return 0
    fi
    sleep $DRAIN_POLL_SLEEP
  done
  incident FATAL "DRAIN_FAIL tag=$tag last_objects=$objs"
  die "DRAIN_FAIL: objects still > $OBJ_DRAIN_TARGET after $DRAIN_POLL_MAX polls. STOP (no 'continue anyway')."
}

# ------------------------------------------------------------------ preflight

cmd_preflight() {
  RUN_ROOT=$1
  mkdir -p "$RUN_ROOT"/{fingerprint,assets,v4,closure,gate0}
  incident INFO "preflight begin"

  log "S02 serial gate"
  local n
  n=$(mount | grep -cE 't6[456]' || true);        [[ $n -eq 0 ]] || die "S02: $n t64/65/66 mounts remain"
  n=$(pgrep -c -f '(^|/)fio( |$)' || true);        [[ $n -eq 0 ]] || die "S02: foreign fio running"
  n=$(losetup -l 2>/dev/null | grep -c 't6[456]' || true); [[ $n -eq 0 ]] || die "S02: t6x loop remains"
  n=$(ss -ltn 2>/dev/null | grep -cE ':(12379|12380|30160|30180)' || true)
  [[ $n -eq 0 ]] || die "S02: temp PD/TiKV ports still listening"
  echo "S02_PASS"

  log "S03 graceful unmount of any existing mount"
  bash "$COLLECT" mount "$RUN_ROOT/fingerprint/mount-PRE-preflight.txt" || true
  graceful_umount
  echo "S03_PASS"

  log "S04 frozen manifest"
  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-manifest.tsv"
  verify_balance

  log "S05 asset gate (temporary V13 mount)"
  export PATH="${SHIM_V13}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export CEPH_CONF="$MSGR_CONF"
  juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" >/dev/null 2>&1
  sleep 3
  bash "$COLLECT" assets "$RUN_ROOT/assets/asset-PREFLIGHT.tsv"
  graceful_umount

  log "S06 object baseline"
  bash "$COLLECT" objects "$RUN_ROOT/objects.tsv" preflight
  local objs
  objs=$(awk -F'\t' '$2=="preflight"{print $4}' "$RUN_ROOT/objects.tsv" | tail -1)
  if [[ $objs -gt $OBJ_DRAIN_TARGET ]]; then
    incident INFO "S06 objects=$objs > $OBJ_DRAIN_TARGET -> drain"
    cmd_drain "$RUN_ROOT" preflight
  fi
  echo "S06_PASS objects=$objs"

  log "S07 P0 compatibility gate"
  cmd_p0 "$RUN_ROOT"

  log "S08 freeze matrix"
  cmd_matrix "$RUN_ROOT" > "$RUN_ROOT/closure/matrix-echo.txt"

  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-preflight.txt"
  incident INFO "preflight end PASS"
  echo "U141B_PREFLIGHT: PASS"
}

cmd_p0() {
  RUN_ROOT=$1
  local seq=(V14 V13 V14) arm shim md5 out
  local i=0
  for arm in "${seq[@]}"; do
    i=$((i + 1))
    shim=$(arm_shim "$arm"); md5=$(arm_md5 "$arm")
    export PATH="${shim}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export CEPH_CONF="$MSGR_CONF"
    bash "$COLLECT" resolve "$shim" "$md5" "$RUN_ROOT/fingerprint/p0-resolve-$i-$arm.txt" >/dev/null
    log "P0 step $i: mount with $arm"
    juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" >/dev/null 2>&1 \
      || { incident FATAL "P0 mount failed with $arm (step $i)"; die "ROLLBACK_BLOCKED: $arm cannot mount at step $i"; }
    sleep 3
    mountpoint -q "$MNT" || die "ROLLBACK_BLOCKED: $arm mount not present (step $i)"
    out="$RUN_ROOT/closure/p0-status-$i-$arm.json"
    juicefs status "$META" > "$out" 2>&1 || true
    bash "$COLLECT" mount "$RUN_ROOT/fingerprint/mount-P0-$i-$arm.txt"
    bash "$COLLECT" gate-mount "$RUN_ROOT/fingerprint/mount-P0-$i-$arm.txt" "$md5"
    graceful_umount
  done
  python3 - "$RUN_ROOT/closure/p0-status-2-V13.json" "$RUN_ROOT/closure/p0-status-1-V14.json" <<'PY'
import json, sys
keys = ["UUID", "BlockSize", "Compression", "TrashDays", "Storage", "Bucket"]
def load(p):
    txt = open(p, errors="replace").read()
    i, j = txt.find("{"), txt.rfind("}")
    return json.loads(txt[i:j+1]) if i >= 0 else {}
a, b = load(sys.argv[1]), load(sys.argv[2])
sa, sb = a.get("Setting", a), b.get("Setting", b)
bad = [k for k in keys if sa.get(k) != sb.get(k)]
for k in keys:
    print("  %-12s V13=%-40r V14=%r" % (k, sa.get(k), sb.get(k)))
if bad:
    print("P0_GATE: ROLLBACK_BLOCKED differing=%s" % bad)
    sys.exit(1)
print("P0_GATE: PASS (settings identical across versions, rollback viable)")
PY
}

# ------------------------------------------------------------------ one round

run_round() {
  local phase=$1
  local idx=$2
  local arm=${ARM_ORDER[$((idx - 1))]}
  local shim md5 items label
  shim=$(arm_shim "$arm"); md5=$(arm_md5 "$arm")
  items=${PHASE_ITEMS[$phase]}
  # D19: the label is uniquely derived from the frozen matrix.  rounds.tsv is
  #      cumulative per label, so a reused label would dilute the gate value --
  #      a failed round STOPs the phase; labels are NEVER reused for a retry.
  label=$(printf 'U141B-%s-R%02d-%s' "$phase" "$idx" "$arm")

  log "=== $label  arm=$arm items='$items' ==="
  timing "$label" BEGIN
  incident INFO "round begin $label"

  # ---- S09 pre-round object gate (no SOFT-PASS)
  bash "$COLLECT" objects "$RUN_ROOT/objects.tsv" "${label}-pre"
  local objs
  objs=$(awk -F'\t' -v t="${label}-pre" '$2==t{print $4}' "$RUN_ROOT/objects.tsv" | tail -1)
  [[ -n $objs ]] || die "S09: no object sample for $label"
  if [[ $objs -gt $OBJ_START_MAX ]]; then
    incident INFO "S09 $label objects=$objs > $OBJ_START_MAX -> drain"
    cmd_drain "$RUN_ROOT" "${label}-pre"
    bash "$COLLECT" objects "$RUN_ROOT/objects.tsv" "${label}-pre2"
    objs=$(awk -F'\t' -v t="${label}-pre2" '$2==t{print $4}' "$RUN_ROOT/objects.tsv" | tail -1)
    [[ $objs -le $OBJ_START_MAX ]] || die "S09: objects=$objs still above $OBJ_START_MAX after drain"
  fi
  log "S09_PASS objects=$objs"

  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-${phase}-R$(printf '%02d' "$idx")-pre.txt"

  # ---- S09b arm resolution self-proof, BEFORE launching V4
  export PATH="${shim}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export CEPH_CONF="$MSGR_CONF"
  bash "$COLLECT" resolve "$shim" "$md5" \
    "$RUN_ROOT/fingerprint/arm-resolve-${phase}-R$(printf '%02d' "$idx").txt"

  # ---- V4: one item-group, ONE round.  OBJ_GATE=1 is mandatory (D20).
  local rc=0
  set +e
  ITEMS="$items" OBJ_GATE=1 \
    bash "$V4" "$label" 180 1 --remount \
    > "$RUN_ROOT/v4-${label}.stdout.log" 2>&1
  rc=$?
  set -e
  echo "rc=$rc" >> "$RUN_ROOT/v4-${label}.stdout.log"
  log "V4 rc=$rc"

  # ---- fingerprints BEFORE unmount (this is what U141 was missing)
  local mfp="$RUN_ROOT/fingerprint/mount-${phase}-R$(printf '%02d' "$idx")-post.txt"
  bash "$COLLECT" mount "$mfp"
  bash "$COLLECT" gate-mount "$mfp" "$md5"

  bash "$COLLECT" assets "$RUN_ROOT/assets/asset-${phase}-R$(printf '%02d' "$idx").tsv"
  bash "$COLLECT" objects "$RUN_ROOT/objects.tsv" "${label}-post"
  bash "$COLLECT" ceph "$RUN_ROOT/fingerprint/ceph-${phase}-R$(printf '%02d' "$idx")-post.txt"
  bash "$COLLECT" frozen "$RUN_ROOT/fingerprint/frozen-${phase}-R$(printf '%02d' "$idx").tsv"

  # ---- copy artefacts back
  if [[ -d "$V4_RESULTS/$label" ]]; then
    cp -a "$V4_RESULTS/$label" "$RUN_ROOT/v4/"
  else
    die "S13: $V4_RESULTS/$label not produced"
  fi
  [[ -f "$RUN_ROOT/rounds-u141b.tsv" ]] || \
    printf 'LABEL\tround\tBW_MiBs\thit\tstatus\tpg_gate\tpg\tgear\n' > "$RUN_ROOT/rounds-u141b.tsv"
  grep -P "^${label}\t" "$V4_RESULTS/rounds.tsv" >> "$RUN_ROOT/rounds-u141b.tsv" || true

  graceful_umount
  timing "$label" END

  # ---- S13/S14 gates
  [[ $rc -eq 0 ]] || die "S13: V4 rc=$rc for $label (EVIDENCE_INVALID, STOP, no re-sample)"
  local bad
  bad=$(grep -c INVALID "$RUN_ROOT/rounds-u141b.tsv" || true)
  awk -F'\t' -v l="$label" '$1==l && $5!="VALID"{print;e=1} END{exit e?1:0}' \
    "$RUN_ROOT/rounds-u141b.tsv" || die "S13: non-VALID round recorded for $label"
  gate_bwlogs "$RUN_ROOT/v4/$label"

  incident INFO "round end $label rc=$rc"
  log "=== $label DONE ==="
}

gate_bwlogs() {
  # D11: find is scoped to a local artefact dir -> no permission surface
  local rd=$1 d n kind exp bad=0
  for d in "$rd"/*/; do
    [[ -d $d ]] || continue
    [[ -f "$d/fio.txt" ]] || continue
    n=$(find "$d" -maxdepth 1 -name '*_bw.*.log' | wc -l)
    kind=$(basename "$d")
    case "$kind" in
      randread-*|randrw-*|randwrite-*) exp=128 ;;
      mseqread-*|mseqwrite-*)          exp=16  ;;
      seqread-*|seqwrite-*)            exp=1   ;;
      *)                               exp=0   ;;
    esac
    echo "  S14 $kind logs=$n expect=$exp"
    [[ $exp -eq 0 || $n -eq $exp ]] || bad=1
  done
  [[ $bad -eq 0 ]] || die "S14: per-job bw log count mismatch in $rd"
  echo "S14_PASS"
}

# ------------------------------------------------------------------ phase

cmd_phase() {
  RUN_ROOT=$1
  local phase=$2
  [[ -n ${PHASE_ITEMS[$phase]:-} ]] || die "unknown phase $phase"
  [[ -f "$RUN_ROOT/MATRIX_AUTHORIZED.tsv" ]] || die "matrix not frozen; run preflight first"
  incident INFO "phase $phase begin"

  # P2 drains at each 4-round block start; P4 drains every round (task book §3.2)
  local i
  for i in $(seq 1 8); do
    case "$phase" in
      P2) [[ $i -eq 1 || $i -eq 5 ]] && cmd_drain "$RUN_ROOT" "${phase}-blockstart-R$i" ;;
      P4) cmd_drain "$RUN_ROOT" "${phase}-R$i" ;;
    esac
    run_round "$phase" "$i"
    [[ $i -eq 1 ]] && check_timing "$phase"
  done

  incident INFO "phase $phase end"
  log "phase $phase complete; run the analyzer offline:"
  log "  python3 $ANALYZE matrix $RUN_ROOT"
  echo "U141B_PHASE_${phase}: DONE"
}

check_timing() {
  local phase=$1 b e min
  b=$(awk -F'\t' -v p="$phase" '$2 ~ ("U141B-"p"-R01-") && $3=="BEGIN"{print $1}' "$RUN_ROOT/timing.tsv" | tail -1)
  e=$(awk -F'\t' -v p="$phase" '$2 ~ ("U141B-"p"-R01-") && $3=="END"{print $1}'   "$RUN_ROOT/timing.tsv" | tail -1)
  [[ -n $b && -n $e ]] || { log "S01: timing incomplete, skip"; return 0; }
  min=$(( (e - b) / 60 ))
  log "S01 $phase R01 wall clock = ${min} min (expect ${PHASE_EXPECT_MIN[$phase]}..${PHASE_EXPECT_MAX[$phase]})"
  if [[ $min -gt ${PHASE_EXPECT_MAX[$phase]} ]]; then
    incident FATAL "S01 $phase R01 took ${min} min > ${PHASE_EXPECT_MAX[$phase]}"
    die "S01: round duration far above estimate; STOP and report timing.tsv (an incomplete phase is an invalid phase)"
  fi
  echo "S01_PASS ${min}min"
}

# ------------------------------------------------------------------ selftest

self_test() {
  local fails=()
  ck() { if eval "$2"; then echo "  [PASS] $1"; else echo "  [FAIL] $1"; fails+=("$1"); fi; }

  # static red-line scanning lives in u141b-gate0.sh (see collect.sh note)
  echo "=== frozen order and balance (§2.2/§3.1) ==="
  ck "8 slots"      "[[ ${#ARM_ORDER[@]} -eq 8 ]]"
  ck "order is ABBA-BAAB" "[[ '${ARM_ORDER[*]}' == 'V13 V14 V14 V13 V14 V13 V13 V14' ]]"
  local out
  out=$(verify_balance) && ck "position means both 4.5" true || ck "position means both 4.5" false
  echo "    $out"

  echo "=== phase definitions ==="
  ck "P1 has 3 read items" "[[ '${PHASE_ITEMS[P1]}' == 'seqread mseqread randread' ]]"
  ck "P3 is randwrite only" "[[ '${PHASE_ITEMS[P3]}' == 'randwrite' ]]"
  ck "mseqwrite isolated in P4" "[[ '${PHASE_ITEMS[P4]}' == 'mseqwrite' ]]"
  ck "mseqwrite absent from P1..P3" \
    "! grep -qw mseqwrite <<<'${PHASE_ITEMS[P1]} ${PHASE_ITEMS[P2]} ${PHASE_ITEMS[P3]}'"

  echo "=== hard-gate constants ==="
  ck "S09 uses 3.11M, no SOFT-PASS" "[[ $OBJ_START_MAX -eq 3110000 ]]"
  ck "drain target 2.5M"            "[[ $OBJ_DRAIN_TARGET -eq 2500000 ]]"
  ck "arm md5 V13" "[[ $(arm_md5 V13) == $MD5_V13 ]]"
  ck "arm md5 V14" "[[ $(arm_md5 V14) == $MD5_V14 ]]"
  ck "shim V13"    "[[ $(arm_shim V13) == $SHIM_V13 ]]"
  ck "shim V14"    "[[ $(arm_shim V14) == $SHIM_V14 ]]"

  echo "=== D20: OBJ_GATE=1 must be passed to V4 ==="
  ck "OBJ_GATE=1 present" "grep -q 'OBJ_GATE=1 *\\\\' \"\$0\" || grep -q 'OBJ_GATE=1' \"\$0\""
  ck "REPEAT is positional 1" "grep -qE '\"\\\$V4\" \"\\\$label\" 180 1 --remount' \"\$0\""

  echo "=== matrix emission ==="
  local td
  td=$(mktemp -d)
  ( cmd_matrix "$td" >/dev/null )
  ck "32 rows emitted" "[[ \$(( \$(wc -l < $td/MATRIX_AUTHORIZED.tsv) - 1 )) -eq 32 ]]"
  ck "16 V13 rows"     "[[ \$(awk -F'\t' '\$3==\"V13\"' $td/MATRIX_AUTHORIZED.tsv | wc -l) -eq 16 ]]"
  ck "16 V14 rows"     "[[ \$(awk -F'\t' '\$3==\"V14\"' $td/MATRIX_AUTHORIZED.tsv | wc -l) -eq 16 ]]"

  echo "=== S14 bw-log count gate ==="
  local rd="$td/round"
  mkdir -p "$rd/randwrite-X-r1"
  : > "$rd/randwrite-X-r1/fio.txt"
  local j
  for j in $(seq 1 128); do : > "$rd/randwrite-X-r1/st_bw.$j.log"; done
  set +e
  ( gate_bwlogs "$rd" ) >/dev/null 2>&1; local rc=$?
  set -e
  ck "128 logs passes" "[[ $rc -eq 0 ]]"
  rm -f "$rd/randwrite-X-r1/st_bw.128.log"
  set +e
  ( gate_bwlogs "$rd" ) >/dev/null 2>&1; rc=$?
  set -e
  ck "127 logs fails (S14)" "[[ $rc -ne 0 ]]"

  echo "=== incidents ledger is append-only (D28) ==="
  RUN_ROOT="$td"
  incident INFO "first"
  incident INFO "second"
  ck "two rows appended" "[[ \$(( \$(wc -l < $td/incidents.tsv) - 1 )) -eq 2 ]]"
  ck "first row retained" "grep -q first $td/incidents.tsv"
  rm -r "$td"

  echo
  if [[ ${#fails[@]} -gt 0 ]]; then
    echo "U141B_DRIVER_SELFTEST: FAIL -> ${fails[*]}"
    return 1
  fi
  echo "U141B_DRIVER_SELFTEST: PASS"
}

# ------------------------------------------------------------------ dispatch

case "${1:-}" in
  --self-test) self_test ;;
  matrix)      shift; cmd_matrix "$@" ;;
  preflight)   shift; cmd_preflight "$@" ;;
  p0)          shift; cmd_p0 "$@" ;;
  phase)       shift; cmd_phase "$@" ;;
  drain)       shift; cmd_drain "$@" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
