#!/usr/bin/env bash
# Fully offline state-machine integration test for u141d-driver.sh.
# This file doubles as every mocked command via symlink basename dispatch.
set -euo pipefail
export LC_ALL=C

mode=$(basename "$0")

case "$mode" in
  mountpoint)
    [[ -f ${MOCK_STATE:?}/mounted ]]
    exit
    ;;
  fusermount)
    rm -f "${MOCK_STATE:?}/mounted"
    exit 0
    ;;
  sudo)
    shift_count=0
    while [[ ${1:-} == -* ]]; do shift; shift_count=$((shift_count + 1)); done
    if [[ ${1:-} == ceph && ${2:-} == df ]]; then
      printf '{"pools":[{"name":"juicefs-data","stats":{"objects":2000000,"stored":1,"max_avail":999999999}}]}\n'
      exit 0
    fi
    if [[ ${1:-} == umount ]]; then
      rm -f "${MOCK_STATE:?}/mounted"
      exit 0
    fi
    printf 'mock sudo rejects command after %s option(s): %s\n' "$shift_count" "$*" >&2
    exit 1
    ;;
  mount)
    exit 0
    ;;
  pgrep)
    [[ ${1:-} == -c ]] && printf '0\n'
    exit 1
    ;;
  losetup|ss)
    exit 0
    ;;
  sleep)
    exit 0
    ;;
  df)
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf 'mockfs 100000000 1 99999999 1%% /\n'
    exit 0
    ;;
  juicefs)
    case "${1:-}" in
      mount)
        touch "${MOCK_STATE:?}/mounted"
        printf 'mock mount arm=%s\n' "${U141D_ACTIVE_ARM:-UNKNOWN}"
        ;;
      status)
        if [[ ${U141D_ACTIVE_ARM:-} == V14 ]]; then
          printf 'mock log prefix\n{"Setting":{"UUID":"mock-uuid","Name":"mock","BlockSize":4096,"Tiers":[]}}\n'
        else
          printf 'mock log prefix\n{"Setting":{"UUID":"mock-uuid","Name":"mock","BlockSize":4096}}\n'
        fi
        ;;
      gc)
        printf 'mock gc delete complete\n'
        ;;
      *) printf 'mock juicefs unsupported: %s\n' "$*" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  mock-collect)
    command_name=${1:-}; shift || true
    case "$command_name" in
      resolve)
        out=${3:?}; mkdir -p "$(dirname "$out")"
        printf 'ARM_RESOLVE_PASS\n' > "$out"
        ;;
      mount)
        out=${1:?}; mkdir -p "$(dirname "$out")"
        printf 'mock mount fingerprint max_read=262144\n' > "$out"
        ;;
      gate-mount) ;;
      frozen)
        out=${1:?}; mkdir -p "$(dirname "$out")"
        printf 'object\tsha\tstatus\nmock\tmock\tOK\n' > "$out"
        ;;
      ceph)
        out=${1:?}; mkdir -p "$(dirname "$out")"
        printf 'health: HEALTH_OK\npg_count=1 nonclean=0\n' > "$out"
        ;;
      assets)
        out=${1:?}; mkdir -p "$(dirname "$out")"
        printf 'path\tsize\nmock\t1073741824\n' > "$out"
        ;;
      *) printf 'mock collector unsupported: %s\n' "$command_name" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  mock-scrub-control)
    command_name=${1:-}; shift || true
    lease=${1:-}
    state="${MOCK_STATE:?}/u141d-scrub-control-${lease}.tsv"
    case "$command_name" in
      state-path) printf '%s\n' "$state" ;;
      verify-paused)
        [[ -f $state ]] || { printf 'mock scrub state missing: %s\n' "$state" >&2; exit 1; }
        grep -Fxq $'status\t1\tpaused' "$state"
        printf 'SCRUB_PAUSE_VERIFY_PASS lease=%s state=%s flags=noscrub,nodeep-scrub pgs=1\n' \
          "$lease" "$state"
        ;;
      *) printf 'mock scrub control unsupported: %s\n' "$command_name" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  mock-analyze)
    command_name=${1:-}; shift || true
    case "$command_name" in
      round)
        [[ ${MOCK_ANALYZE_FAIL_ROUND:-0} == 1 ]] && { echo 'injected round analysis failure' >&2; exit 2; }
        printf '{"mock":"round-pass"}\n'
        ;;
      matrix)
        output_dir=""
        while (( $# )); do
          if [[ $1 == --output-dir ]]; then output_dir=$2; shift 2; else shift; fi
        done
        [[ -n $output_dir ]] || { echo 'mock analyzer missing output dir' >&2; exit 1; }
        mkdir -p "$output_dir"
        printf '{"mock":"matrix-pass"}\n' > "$output_dir/mock-matrix.json"
        printf 'mock matrix pass\n'
        ;;
      *) printf 'mock analyzer unsupported: %s\n' "$command_name" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  mock-v4)
    label=${1:?}
    results=${MOCK_RESULTS:?}
    read -r -a mock_items <<<"${ITEMS:-}"
    (( ${#mock_items[@]} > 0 )) || { echo 'mock V4 received empty ITEMS' >&2; exit 1; }
    mkdir -p "$results/$label"
    printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{}}}\n' \
      > "$results/ceph-health-pre-${label}.json"
    printf '{"flags":"noscrub,nodeep-scrub","osds":[{"osd":0,"up":1,"in":1}]}\n' \
      > "$results/ceph-osd-dump-pre-${label}.json"
    touch "${MOCK_STATE:?}/mounted"
    [[ -f $results/rounds.tsv ]] \
      || printf 'LABEL\tround\tBW_MiBs\thit\tstatus\tpg_gate\tpg\tgear\n' > "$results/rounds.tsv"
    mock_limit=${#mock_items[@]}
    [[ ${MOCK_V4_ROW_MODE:-normal} == missing-last ]] && mock_limit=$((mock_limit - 1))
    for ((mock_i=0; mock_i<mock_limit; mock_i++)); do
      printf '%s\t%s-%s-r1\t1000\t0\tVALID\tPASS\t0\tmock\n' \
        "$label" "${mock_items[$mock_i]}" "$label" >> "$results/rounds.tsv"
    done
    if [[ ${MOCK_V4_ROW_MODE:-normal} == duplicate-first ]]; then
      printf '%s\t%s-%s-r1\t1000\t0\tVALID\tPASS\t0\tmock\n' \
        "$label" "${mock_items[0]}" "$label" >> "$results/rounds.tsv"
    fi
    printf 'mock V4 label=%s items=%s\n' "$label" "${ITEMS:-}"
    exit 0
    ;;
esac

if [[ $mode != u141d-mock-integration.sh ]]; then
  printf 'unknown mock dispatch basename: %s\n' "$mode" >&2
  exit 1
fi

DRIVER=${1:?driver path required}
OUT=${2:?output directory required}
mkdir -p "$OUT" /tmp/production
WORK=$(mktemp -d /tmp/u141d-mock.XXXXXX)
RUN_ROOT="/tmp/production/opencode-u141d-MOCK-$$-$RANDOM"
RUN_ROOT_B_ONLY="/tmp/production/opencode-u141d-MOCKBONLY-$$-$RANDOM"
RUN_ROOT_FAIL="/tmp/production/opencode-u141d-MOCKFAIL-$$-$RANDOM"
RUN_ROOT_MISSING="/tmp/production/opencode-u141d-MOCKMISSING-$$-$RANDOM"
RUN_ROOT_DUPLICATE="/tmp/production/opencode-u141d-MOCKDUPLICATE-$$-$RANDOM"
MOCK_STATE="$WORK/state"
MOCK_RESULTS="$WORK/results"
MOCK_MNT="$WORK/mnt"
MOCK_TEST_DIR="$MOCK_MNT/test_dir"
COMMON="$WORK/common"
SHIM13="$WORK/shim13"
SHIM14="$WORK/shim14"
mkdir -p "$MOCK_STATE" "$MOCK_RESULTS" "$MOCK_TEST_DIR/mseqwrite" \
         "$COMMON" "$SHIM13" "$SHIM14"

cleanup() {
  case "$RUN_ROOT" in /tmp/production/opencode-u141d-MOCK-*) find "$RUN_ROOT" -depth -delete 2>/dev/null || true ;; esac
  case "$RUN_ROOT_B_ONLY" in /tmp/production/opencode-u141d-MOCKBONLY-*) find "$RUN_ROOT_B_ONLY" -depth -delete 2>/dev/null || true ;; esac
  case "$RUN_ROOT_FAIL" in /tmp/production/opencode-u141d-MOCKFAIL-*) find "$RUN_ROOT_FAIL" -depth -delete 2>/dev/null || true ;; esac
  case "$RUN_ROOT_MISSING" in /tmp/production/opencode-u141d-MOCKMISSING-*) find "$RUN_ROOT_MISSING" -depth -delete 2>/dev/null || true ;; esac
  case "$RUN_ROOT_DUPLICATE" in /tmp/production/opencode-u141d-MOCKDUPLICATE-*) find "$RUN_ROOT_DUPLICATE" -depth -delete 2>/dev/null || true ;; esac
  case "$WORK" in /tmp/u141d-mock.*) find "$WORK" -depth -delete 2>/dev/null || true ;; esac
}
trap cleanup EXIT

SELF=$(readlink -f "$0")
for command_name in mountpoint fusermount sudo mount pgrep losetup ss sleep df; do
  ln -s "$SELF" "$COMMON/$command_name"
  ln -s "$SELF" "$SHIM13/$command_name"
  ln -s "$SELF" "$SHIM14/$command_name"
done
ln -s "$SELF" "$SHIM13/juicefs"
ln -s "$SELF" "$SHIM14/juicefs"
ln -s "$SELF" "$WORK/mock-collect"
ln -s "$SELF" "$WORK/mock-scrub-control"
ln -s "$SELF" "$WORK/mock-analyze"
ln -s "$SELF" "$WORK/mock-v4"
ln -s "$SELF" "$WORK/mock-base-analyze"
ln -s "$SELF" "$WORK/mock-v13-bin"
ln -s "$SELF" "$WORK/mock-v14-bin"
printf 'mock msgr config\n' > "$WORK/msgr.conf"
printf 'mock frozen base V4\n' > "$WORK/mock-v4-base"

export MOCK_STATE MOCK_RESULTS
export PATH="$COMMON:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export U141D_COLLECT="$WORK/mock-collect"
export U141D_BASE_ANALYZE="$WORK/mock-base-analyze"
export U141D_ANALYZE="$WORK/mock-analyze"
export U141D_SCRUB_CONTROL="$WORK/mock-scrub-control"
export U141D_SCRUB_STATE_DIR="$MOCK_STATE"
export V4="$WORK/mock-v4"
export V4_BASE="$WORK/mock-v4-base"
export V4_RESULTS="$MOCK_RESULTS"
export MNT="$MOCK_MNT"
export TEST_DIR="$MOCK_TEST_DIR"
export MSGR_CONF="$WORK/msgr.conf"
export SHIM_V13="$SHIM13"
export SHIM_V14="$SHIM14"
export BIN_V13="$WORK/mock-v13-bin"
export BIN_V14="$WORK/mock-v14-bin"
export OBJ_POLL_SLEEP=0
export OBJ_SAMPLE_SLEEP=0

LOG="$OUT/mock-driver-integration.log"
: > "$LOG"
for mock_root in "$RUN_ROOT" "$RUN_ROOT_B_ONLY" "$RUN_ROOT_FAIL" "$RUN_ROOT_MISSING" "$RUN_ROOT_DUPLICATE"; do
  mock_id=${mock_root##*/opencode-u141d-}
  for mock_phase in a b; do
    {
      printf 'meta\tlease\t%s-phase-%s\n' "$mock_id" "$mock_phase"
      printf 'meta\tfsid\tmock-fsid\n'
      printf 'pre\tflags\tsortbitwise\n'
      printf 'status\t1\tpaused\n'
    } > "$MOCK_STATE/u141d-scrub-control-${mock_id}-phase-${mock_phase}.tsv"
  done
done
bash "$DRIVER" init "$RUN_ROOT" >> "$LOG" 2>&1
bash "$DRIVER" phase-a "$RUN_ROOT" >> "$LOG" 2>&1
bash "$DRIVER" close "$RUN_ROOT" phase-a >> "$LOG" 2>&1
bash "$DRIVER" phase-b "$RUN_ROOT" >> "$LOG" 2>&1
bash "$DRIVER" close "$RUN_ROOT" final >> "$LOG" 2>&1

[[ -f $RUN_ROOT/INIT_COMPLETE ]]
[[ -f $RUN_ROOT/PHASE_A_COMPLETE ]]
[[ -f $RUN_ROOT/PHASE_B_COMPLETE ]]
[[ -s $RUN_ROOT/closure/phase-a/SHA256SUMS ]]
[[ -s $RUN_ROOT/closure/final/SHA256SUMS ]]
[[ -s $RUN_ROOT/fingerprint/scrub-control-closure-phase-a-pre-restore.state.tsv ]]
[[ -s $RUN_ROOT/fingerprint/scrub-control-closure-final-pre-restore.state.tsv ]]
[[ $(awk -F'\t' 'NR>1{n++} END{print n+0}' "$RUN_ROOT/rounds-u141d.tsv") -eq 34 ]]
[[ $(find "$RUN_ROOT/v4" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 22 ]]
mountpoint -q "$MOCK_MNT" && { echo 'mock mount leaked' >&2; exit 1; }

find "$RUN_ROOT" -type f -printf '%P\n' | sort > "$OUT/mock-run-files.txt"

# Independent Phase-B-only lifecycle: bind the immutable reviewed Phase A
# archive, create no synthetic Phase A marker, run a fresh 2+8 B matrix and
# close it under its own scope.
bash "$DRIVER" init-b-only "$RUN_ROOT_B_ONLY" >> "$LOG" 2>&1
bash "$DRIVER" phase-b-only "$RUN_ROOT_B_ONLY" >> "$LOG" 2>&1
bash "$DRIVER" close "$RUN_ROOT_B_ONLY" phase-b-only >> "$LOG" 2>&1

[[ -f $RUN_ROOT_B_ONLY/INIT_B_ONLY_COMPLETE ]]
[[ ! -e $RUN_ROOT_B_ONLY/PHASE_A_COMPLETE ]]
[[ -f $RUN_ROOT_B_ONLY/PHASE_B_COMPLETE ]]
[[ -f $RUN_ROOT_B_ONLY/PHASE_B_ONLY_COMPLETE ]]
[[ -s $RUN_ROOT_B_ONLY/PHASE_A_SOURCE.tsv ]]
[[ -s $RUN_ROOT_B_ONLY/fingerprint/phase-a-source-archive-members.txt ]]
[[ -s $RUN_ROOT_B_ONLY/closure/phase-b-only/SHA256SUMS ]]
[[ -s $RUN_ROOT_B_ONLY/fingerprint/scrub-control-closure-phase-b-only-pre-restore.state.tsv ]]
[[ $(awk -F'\t' 'NR>1{n++} END{print n+0}' "$RUN_ROOT_B_ONLY/rounds-u141d.tsv") -eq 10 ]]
[[ $(find "$RUN_ROOT_B_ONLY/v4" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 10 ]]
grep -Fxq $'run_mode\tphase-b-only' "$RUN_ROOT_B_ONLY/RUN_META.tsv"
grep -Fxq $'source_archive_sha256\t150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b' \
  "$RUN_ROOT_B_ONLY/PHASE_A_SOURCE.tsv"
mountpoint -q "$MOCK_MNT" && { echo 'phase-b-only mock mount leaked' >&2; exit 1; }
find "$RUN_ROOT_B_ONLY" -type f -printf '%P\n' | sort > "$OUT/mock-b-only-run-files.txt"

# Fault injection: a hard round-evidence failure must stop the phase while the
# V4-created mount is still present.  This proves the preserve-site ordering.
bash "$DRIVER" init "$RUN_ROOT_FAIL" >> "$LOG" 2>&1
export MOCK_ANALYZE_FAIL_ROUND=1
set +e
bash "$DRIVER" phase-a "$RUN_ROOT_FAIL" >> "$LOG" 2>&1
failure_rc=$?
set -e
unset MOCK_ANALYZE_FAIL_ROUND
(( failure_rc != 0 ))
[[ ! -e $RUN_ROOT_FAIL/PHASE_A_COMPLETE ]]
[[ -f $MOCK_STATE/mounted ]]
grep -q 'round artefact/sample gate failed' "$RUN_ROOT_FAIL/incidents.tsv"
rm -f "$MOCK_STATE/mounted"

# Fault injection: Phase A expects two V4 rounds.tsv rows, one for each exact
# item.  Missing or duplicate rows must fail while preserving the mount.
bash "$DRIVER" init "$RUN_ROOT_MISSING" >> "$LOG" 2>&1
export MOCK_V4_ROW_MODE=missing-last
set +e
bash "$DRIVER" phase-a "$RUN_ROOT_MISSING" >> "$LOG" 2>&1
missing_rc=$?
set -e
unset MOCK_V4_ROW_MODE
(( missing_rc != 0 ))
[[ -f $MOCK_STATE/mounted ]]
grep -q 'expected 2 item row(s).*got 1' "$RUN_ROOT_MISSING/incidents.tsv"
rm -f "$MOCK_STATE/mounted"

bash "$DRIVER" init "$RUN_ROOT_DUPLICATE" >> "$LOG" 2>&1
export MOCK_V4_ROW_MODE=duplicate-first
set +e
bash "$DRIVER" phase-a "$RUN_ROOT_DUPLICATE" >> "$LOG" 2>&1
duplicate_rc=$?
set -e
unset MOCK_V4_ROW_MODE
(( duplicate_rc != 0 ))
[[ -f $MOCK_STATE/mounted ]]
grep -q 'expected 2 item row(s).*got 3' "$RUN_ROOT_DUPLICATE/incidents.tsv"
rm -f "$MOCK_STATE/mounted"

tail -8 "$LOG"
echo "U141D_MOCK_INTEGRATION: PASS (full + phase-b-only lifecycles + multi-item rows + hard-failure preservation)"
