#!/usr/bin/env bash
# Offline-only Gate 0 for U141d.  No ssh/sudo/mount/ceph/juicefs/fio is run.
set -euo pipefail
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
DRIVER="$SCRIPT_DIR/u141d-driver.sh"
ANALYZE="$SCRIPT_DIR/u141d-analyze.py"
MOCK="$SCRIPT_DIR/u141d-mock-integration.sh"
SCRUB="$SCRIPT_DIR/u141d-scrub-control.sh"
COLLECT="$SCRIPT_DIR/u141b-collect.sh"
BASE_ANALYZE="$SCRIPT_DIR/u141b-analyze.py"
V4_BASE="$ROOT/scripts/FULLBASELINE/FULLBASELINE_V4.sh"
V4="$ROOT/scripts/FULLBASELINE/FULLBASELINE_V4_U141D.sh"
TASK="$ROOT/doc/perf-tasks/u141d-randwrite-randrw-confirm-10pct.md"
PHASE_A_ARCHIVE=/tmp/u141d-run5-phase-a-evidence-20260830.tar.gz
PHASE_A_ARCHIVE_SHA256=150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b
FIXTURE=${1:-}
OUT=${U141D_GATE0_OUT:-/tmp/u141d-gpt-gate0-20260831-phase-b-only}
mkdir -p "$OUT"

FAILURES=()
pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILURES+=("$*"); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

echo "############################################################"
echo "# U141d offline Gate 0  $(date -Is)"
echo "############################################################"

echo
echo "=== 1. required files and syntax ==="
for file in "$DRIVER" "$ANALYZE" "$MOCK" "$SCRUB" "$COLLECT" "$BASE_ANALYZE" \
            "$V4_BASE" "$V4" "$TASK"; do
  [[ -f $file ]] && pass "present $(basename "$file")" || fail "missing $file"
done
if (( ${#FAILURES[@]} == 0 )); then
  check "bash -n driver" "bash -n '$DRIVER'"
  check "bash -u -n driver" "bash -u -n '$DRIVER'"
  check "bash -n mock integration" "bash -n '$MOCK'"
  check "bash -n scrub controller" "bash -n '$SCRUB'"
  check "bash -n frozen base V4" "bash -n '$V4_BASE'"
  check "bash -n U141d V4 derivative" "bash -n '$V4'"
  check "bash -n gate0" "bash -n '$0'"
  check "python AST analyzer" \
    "python3 -c \"import ast; ast.parse(open('$ANALYZE').read())\""
  check "U141d analyzer has direct-exec permission for driver calls" "[[ -x '$ANALYZE' ]]"
fi

if [[ -f $PHASE_A_ARCHIVE ]]; then
  pass "present reviewed Phase A archive"
  check "reviewed Phase A archive SHA256 is frozen" \
    "[[ \$(sha256sum '$PHASE_A_ARCHIVE' | awk '{print \$1}') == '$PHASE_A_ARCHIVE_SHA256' ]]"
  check "reviewed Phase A archive has no absolute or parent-traversal members" \
    "tar -tzf '$PHASE_A_ARCHIVE' | python3 -c 'import pathlib,sys; names=[x.rstrip(chr(10)) for x in sys.stdin]; assert names; assert all(not pathlib.PurePosixPath(x).is_absolute() and \"..\" not in pathlib.PurePosixPath(x).parts for x in names)'"
else
  fail "missing reviewed Phase A archive $PHASE_A_ARCHIVE"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$SCRUB" > "$OUT/shellcheck-scrub-control.txt" 2>&1; then
    pass "shellcheck -S error scrub controller"
  else
    fail "shellcheck scrub controller; see $OUT/shellcheck-scrub-control.txt"
  fi
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$DRIVER" > "$OUT/shellcheck-driver.txt" 2>&1; then
    pass "shellcheck -S error driver"
  else
    fail "shellcheck driver; see $OUT/shellcheck-driver.txt"
  fi
else
  echo "  [SKIP] shellcheck unavailable"
fi

echo
echo "=== 2. destructive/scope static scan ==="
SCAN_FILE="$OUT/driver.no-comments.sh"
sed -e 's/[[:space:]]*#.*$//' "$DRIVER" > "$SCAN_FILE"
FORBIDDEN=$(cat <<'PATTERNS'
recursive force removal	rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f|rm[[:space:]]+-[A-Za-z]*f[A-Za-z]*r
lazy fuse unmount	fusermount[[:space:]]+-[A-Za-z]*z
lazy or forced umount	umount[[:space:]]+(-l|--lazy|-f|--force)
bulk loop detach	losetup[[:space:]]+-D
pattern kill	pkill|killall|fuser[[:space:]]+-k
volume destroy	juicefs[[:space:]]+destroy
service mutation	systemctl[[:space:]]+(stop|restart|disable)|service[[:space:]][^[:space:]]+[[:space:]]+(stop|restart)
Ceph mutation	ceph[[:space:]]+(config[[:space:]]+set|osd[[:space:]]+pool[[:space:]]+(create|delete)|osd[[:space:]]+crush)
plaintext password	sshpass[[:space:]]+-p|(PASSWORD|PASSWD|SECRET)=[^$"'[:space:]]
settle write probe	settle_probe|settle-rate|settle_rate
PATTERNS
)
while IFS=$'\t' read -r name pattern; do
  [[ -n ${name:-} ]] || continue
  if grep -nEq -- "$pattern" "$SCAN_FILE"; then
    grep -nE -- "$pattern" "$SCAN_FILE" | head -3
    fail "$name present in executable driver"
  else
    pass "$name absent"
  fi
done <<<"$FORBIDDEN"

SCRUB_SCAN_FILE="$OUT/scrub-control.no-comments.sh"
sed -e 's/[[:space:]]*#.*$//' "$SCRUB" > "$SCRUB_SCAN_FILE"
check "scrub controller owns exactly noscrub and nodeep-scrub" \
  "grep -Fxq 'OWNED_FLAGS=(noscrub nodeep-scrub)' '$SCRUB'"
check "scrub mutation requires exact explicit acknowledgement" \
  "grep -q 'I_ACK_GLOBAL_CEPH_SCRUB_PAUSE' '$SCRUB' && grep -q 'pause requires exact acknowledgement token' '$SCRUB'"
check "scrub controller has no pool/config/service/destructive mutation" \
  "! grep -nEq 'ceph_call[[:space:]]+(config|osd[[:space:]]+pool|osd[[:space:]]+crush)|systemctl|service[[:space:]]|rm[[:space:]]+-[A-Za-z]*r|losetup|umount|killall|pkill|fuser' '$SCRUB_SCAN_FILE'"
check "all scrub OSD flag mutations are variable-gated owned-flag calls" \
  "[[ \$(grep -Ec 'ceph_call osd (set|unset)' '$SCRUB_SCAN_FILE') -eq 3 ]] && ! grep -E 'ceph_call osd (set|unset)' '$SCRUB_SCAN_FILE' | grep -Fvq '\"\$flag\"'"
check "restore rejects foreign live flag drift" \
  "grep -q 'unexpected flag appeared; refuse restore' '$SCRUB'"
check "scrub state path is lease-scoped under dedicated state dir" \
  "grep -Fq 'u141d-scrub-control-%s.tsv' '$SCRUB' && grep -q 'expected <RUN_ID>-phase-a|b' '$SCRUB'"

echo
echo "=== 3. positive contract checks ==="
check "RUN_ROOT is restricted to U141d /tmp scope" \
  "grep -Fq '/tmp/production/opencode-u141d-*' '$DRIVER'"
check "mseq deletion is exact and non-recursive" \
  "grep -Fq 'rm -f \"\$TEST_DIR/mseqwrite/mseqwrite.\"*.0' '$DRIVER'"
check "V4 gets fixed runtime/repeat/remount" \
  "grep -Fq 'bash \"\$V4\" \"\$label\" 180 1 --remount' '$DRIVER'"
check "V4 always gets OBJ_GATE=1" "grep -q 'ITEMS=\"\$items\" OBJ_GATE=1' '$DRIVER'"
check "driver always opts U141d V4 into controlled scrub health" \
  "grep -q 'OBJ_GATE=1 CEPH_SCRUB_CONTROLLED=1' '$DRIVER'"
check "rounds.tsv requires one exact row per expected item" \
  "grep -q 'expected exactly one row for item=' '$DRIVER' && grep -q 'copy_round_rows \"\$label\" \"\$items\"' '$DRIVER'"
check "round status requires VALID" "grep -q 'expected VALID' '$DRIVER'"
check "driver refuses lingering mount worker before V4" \
  "grep -q 'begins with a lingering JuiceFS worker' '$DRIVER'"
sed -n '/^jfs_pids_for_mnt() {/,/^}/p' "$DRIVER" > "$OUT/jfs-pids-for-mnt.body.sh"
check "empty PID enumeration is explicitly successful under errexit" \
  "grep -Eq '^[[:space:]]*return 0[[:space:]]*$' '$OUT/jfs-pids-for-mnt.body.sh'"
check "driver rejects V4 non-graceful remount evidence" \
  "grep -q 'UNCLEAN_UMOUNT' '$DRIVER' && grep -q 'umount_mode=(term|kill)' '$DRIVER'"
check "unmount waits for mountpoint and worker quiescence with 180s bound" \
  "grep -q 'UMOUNT_QUIESCE_TIMEOUT=.*180' '$DRIVER' && grep -Fq 'if (( mounted == 0 )) && [[ -z' '$DRIVER'"
check "unmount quiescence telemetry is frozen and archived" \
  "grep -q 'unmount-quiescence.tsv' '$DRIVER' && grep -q 'unmount-quiescence.snapshot.tsv' '$DRIVER'"
check "fatal incident append failure is visible, not suppressed" \
  "grep -q 'U141D_INCIDENT_WRITE_FAIL' '$DRIVER' && ! sed -n '/^die() {/,/^}/p' '$DRIVER' | grep -q '2>/dev/null'"
check "round wall clock is rechecked after quiescent unmount" \
  "grep -q 'total elapsed=.*after quiescent unmount' '$DRIVER'"
check "driver forces collector exact scrub-paused mode" \
  "grep -Fxq 'export U141D_SCRUB_PAUSED=1' '$DRIVER'"
check "driver verifies a phase lease at init, every round, phase edges and closure" \
  "grep -q 'assert_scrub_paused.*scrub_lease a.*init' '$DRIVER' && grep -q 'assert_scrub_paused.*scrub_lease.*stage' '$DRIVER' && grep -q 'phase-a-entry' '$DRIVER' && grep -q 'phase-b-entry' '$DRIVER' && grep -q 'closure-.*scope' '$DRIVER'"
check "phase-b-only init uses a fresh B lease and immutable Phase A archive" \
  "grep -q 'assert_scrub_paused.*scrub_lease b.*init-b-only' '$DRIVER' && grep -q 'reviewed Phase A archive SHA256 mismatch' '$DRIVER' && grep -q 'PHASE_A_SOURCE.tsv' '$DRIVER'"
check "phase-b-only never synthesizes a Phase A completion marker" \
  "grep -q 'phase-b-only run must not synthesize PHASE_A_COMPLETE' '$DRIVER' && grep -q 'phase-b-only closure refuses synthesized Phase A marker' '$DRIVER'"
check "phase-b-only has distinct init, run, completion and closure contracts" \
  "grep -q 'cmd_init_b_only' '$DRIVER' && grep -q 'cmd_phase_b_only' '$DRIVER' && grep -q 'INIT_B_ONLY_COMPLETE' '$DRIVER' && grep -q 'PHASE_B_ONLY_COMPLETE' '$DRIVER' && grep -q 'phase-b-only-final-console' '$DRIVER'"
check "driver fail-closes analyzer executable mode before init, Phase B and closure" \
  "[[ \$(grep -c 'analyzer.*executable' '$DRIVER') -ge 4 ]] && grep -q 'lost executable contract before Phase B' '$DRIVER' && grep -q 'lost executable contract before closure' '$DRIVER'"
check "full-run A-PRE-R05 reset uses seq actual value 5" \
  "grep -Fq '[[ \$i == 5 ]] && drain_to_seed A-PRE-R05' '$DRIVER' && ! grep -Fq '[[ \$i == 05 ]]' '$DRIVER'"
check "closure snapshots scrub state before hashing" \
  "grep -q 'snapshot_scrub_state.*pre-restore' '$DRIVER'"
check "collector saves raw health, OSD dump and pgs_brief sidecars" \
  "grep -q 'health.json' '$COLLECT' && grep -q 'osd-dump.json' '$COLLECT' && grep -q 'pgs-brief.txt' '$COLLECT'"
check "collector allows only OSDMAP_FLAGS as paused WARN" \
  "grep -q 'check_keys == \[\"OSDMAP_FLAGS\"\]' '$COLLECT'"
check "task marks conditional scrub baseline and restore priority" \
  "grep -q 'SCRUB_PAUSED_FOR_CONTROLLED_BENCHMARK' '$TASK' && grep -q '恢复优先' '$TASK'"
check "task documents immutable external Phase A plus fresh Phase-B-only recovery" \
  "grep -q 'Phase-B-only' '$TASK' && grep -q '$PHASE_A_ARCHIVE_SHA256' '$TASK' && grep -q '不得伪造.*PHASE_A_COMPLETE' '$TASK'"

sed -n '/^run_round() {/,/^}/p' "$DRIVER" > "$OUT/run-round.body.sh"
sample_line=$(grep -n '"$ANALYZE" round' "$OUT/run-round.body.sh" | head -1 | cut -d: -f1 || true)
umount_line=$(grep -n 'graceful_umount' "$OUT/run-round.body.sh" | tail -1 | cut -d: -f1 || true)
if [[ -n $sample_line && -n $umount_line && $sample_line -lt $umount_line ]]; then
  pass "sample gate runs before graceful unmount"
else
  fail "sample gate does not precede graceful unmount"
fi

sed -n '/^cmd_close() {/,/^}/p' "$DRIVER" > "$OUT/close.body.sh"
incident_line=$(grep -n 'incident INFO "closure' "$OUT/close.body.sh" | tail -1 | cut -d: -f1 || true)
hash_line=$(grep -n 'SHA256SUMS' "$OUT/close.body.sh" | head -1 | cut -d: -f1 || true)
post_hash_incidents=0
if [[ -n $hash_line ]]; then
  post_hash_incidents=$(tail -n "+$hash_line" "$OUT/close.body.sh" | grep -c 'incident ' || true)
fi
if [[ -n $incident_line && -n $hash_line && $incident_line -lt $hash_line && $post_hash_incidents -eq 0 ]]; then
  pass "closure ledger is frozen before SHA generation"
else
  fail "closure writes incident after SHA or ordering is unknown"
fi

check "randrw READ/WRITE are separate endpoints" \
  "grep -q 'randrw.read.*randrw.write' '$ANALYZE'"
check "effect denominator is V13 mean" \
  "grep -q 'v13_values' '$ANALYZE' && grep -q 'arm_mibs / denom' '$ANALYZE'"
check "analyzer never emits replacement approval" \
  "! grep -q 'REPLACE_APPROVED' '$ANALYZE'"
check "task records 24 valid U141b rounds" "grep -q '24 个有效正式轮' '$TASK'"
check "task keeps mseqwrite after phase A" "grep -q '阶段 B 放在全部测试最后' '$TASK'"
check "task explicitly defers replacement approval" \
  "grep -Fq '本任务不在取数前写死' '$TASK'"
check "historical base V4 remains byte-identical" \
  "[[ \$(md5sum '$V4_BASE' | awk '{print \$1}') == 4198ea2676ba56744a3cd5eba17a5eab ]]"
check "task-specific V4 has the frozen controlled-scrub MD5" \
  "[[ \$(md5sum '$V4' | awk '{print \$1}') == b79402c3ef1691dbf20eafd344f91c27 ]]"
check "task-specific V4 exact gate checks health key, flags and OSD state" \
  "grep -q 'keys == \[\"OSDMAP_FLAGS\"\]' '$V4' && grep -q '\"noscrub\", \"nodeep-scrub\"' '$V4' && grep -q 'not all OSDs are up/in' '$V4'"
check "base V4 does not acquire the task-specific opt-in" \
  "! grep -q 'CEPH_SCRUB_CONTROLLED' '$V4_BASE'"

echo
echo "=== 4. offline self-tests and fault injection ==="
V4_HELPER="$OUT/v4-controlled-health-helper.sh"
sed -n '/^validate_controlled_scrub_health() {/,/^}/p' "$V4" > "$V4_HELPER"
V4_FIXTURE="$OUT/v4-controlled-health-fixture"
mkdir -p "$V4_FIXTURE/results"
v4_health_fixture() {
  local health=$1 osd=$2
  (
    RESULTS="$V4_FIXTURE/results"
    LABEL=GATE0
    sudo() {
      shift
      case "$*" in
        "health detail --format json") cat "$health" ;;
        "osd dump --format json") cat "$osd" ;;
        *) return 2 ;;
      esac
    }
    # shellcheck source=/dev/null
    source "$V4_HELPER"
    validate_controlled_scrub_health
  )
}
printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{}}}\n' > "$V4_FIXTURE/health.json"
printf '{"flags":"sortbitwise,noscrub,nodeep_scrub","osds":[{"osd":0,"up":1,"in":1}]}\n' > "$V4_FIXTURE/osd.json"
if v4_health_fixture "$V4_FIXTURE/health.json" "$V4_FIXTURE/osd.json" \
     > "$OUT/v4-controlled-health-valid.txt" 2>&1; then
  pass "U141d V4 accepts exact controlled scrub fixture"
else
  fail "U141d V4 rejects valid controlled scrub fixture"
fi
printf '{"status":"HEALTH_WARN","checks":{"OSDMAP_FLAGS":{},"OSD_DOWN":{}}}\n' > "$V4_FIXTURE/health-extra.json"
if v4_health_fixture "$V4_FIXTURE/health-extra.json" "$V4_FIXTURE/osd.json" \
     > "$OUT/v4-controlled-health-extra.txt" 2>&1; then
  fail "U141d V4 accepted an extra health check"
else
  pass "U141d V4 rejects an extra health check"
fi
printf '{"flags":"sortbitwise,noscrub","osds":[{"osd":0,"up":1,"in":1}]}\n' > "$V4_FIXTURE/osd-missing.json"
if v4_health_fixture "$V4_FIXTURE/health.json" "$V4_FIXTURE/osd-missing.json" \
     > "$OUT/v4-controlled-health-missing.txt" 2>&1; then
  fail "U141d V4 accepted a missing scrub flag"
else
  pass "U141d V4 rejects a missing scrub flag"
fi
printf '{"flags":"sortbitwise,noscrub,nodeep-scrub","osds":[{"osd":0,"up":0,"in":1}]}\n' > "$V4_FIXTURE/osd-down.json"
if v4_health_fixture "$V4_FIXTURE/health.json" "$V4_FIXTURE/osd-down.json" \
     > "$OUT/v4-controlled-health-down.txt" 2>&1; then
  fail "U141d V4 accepted a down OSD"
else
  pass "U141d V4 rejects a down OSD"
fi
if bash "$DRIVER" --self-test > "$OUT/driver-selftest.txt" 2>&1; then
  pass "driver selftest"; tail -1 "$OUT/driver-selftest.txt"
else
  fail "driver selftest"; tail -30 "$OUT/driver-selftest.txt"
fi
if bash "$SCRUB" --self-test > "$OUT/scrub-control-selftest.txt" 2>&1; then
  pass "scrub controller selftest"; tail -1 "$OUT/scrub-control-selftest.txt"
else
  fail "scrub controller selftest"; tail -40 "$OUT/scrub-control-selftest.txt"
fi
if python3 "$ANALYZE" selftest > "$OUT/analyzer-selftest.txt" 2>&1; then
  pass "analyzer selftest"; tail -1 "$OUT/analyzer-selftest.txt"
else
  fail "analyzer selftest"; tail -30 "$OUT/analyzer-selftest.txt"
fi
if python3 "$ANALYZE" replay-u141b > "$OUT/u141b-report-replay.txt" 2>&1; then
  pass "U141b report-level replay"; tail -3 "$OUT/u141b-report-replay.txt"
else
  fail "U141b report-level replay"; tail -30 "$OUT/u141b-report-replay.txt"
fi
if bash "$COLLECT" --self-test > "$OUT/u141b-collector-selftest.txt" 2>&1; then
  pass "reused U141b collector selftest"; tail -1 "$OUT/u141b-collector-selftest.txt"
else
  fail "reused U141b collector selftest"; tail -30 "$OUT/u141b-collector-selftest.txt"
fi
if python3 "$BASE_ANALYZE" selftest > "$OUT/u141b-analyzer-selftest.txt" 2>&1; then
  pass "reused U141b parser selftest"; tail -1 "$OUT/u141b-analyzer-selftest.txt"
else
  fail "reused U141b parser selftest"; tail -30 "$OUT/u141b-analyzer-selftest.txt"
fi
if bash "$MOCK" "$DRIVER" "$OUT" > "$OUT/mock-integration.console.txt" 2>&1; then
  pass "mocked full lifecycle integration"
  tail -2 "$OUT/mock-integration.console.txt"
else
  fail "mocked full lifecycle integration"
  tail -40 "$OUT/mock-integration.console.txt"
  tail -40 "$OUT/mock-driver-integration.log" 2>/dev/null || true
fi

set +e
bash "$DRIVER" phase-a /tmp/not-u141d-scoped \
  > "$OUT/scope-fault.stdout.txt" 2> "$OUT/scope-fault.stderr.txt"
scope_rc=$?
set -e
if (( scope_rc != 0 )) && grep -q 'outside exact scope' "$OUT/scope-fault.stderr.txt"; then
  pass "fault injection: out-of-scope RUN_ROOT rejected"
else
  fail "fault injection: out-of-scope RUN_ROOT not rejected as expected"
fi

bash "$DRIVER" --print-prereg > "$OUT/prereg.tsv"
check "prereg freezes mean estimator" \
  "grep -Fxq $'estimator\tper_second_all_job_sum_arithmetic_mean' '$OUT/prereg.tsv'"
check "prereg freezes V13 denominator" \
  "grep -Fxq $'effect_denominator\tmean_of_v13_round_means' '$OUT/prereg.tsv'"
check "prereg defers replacement verdict" \
  "grep -Fxq $'replacement_verdict\tdeferred_until_human_review' '$OUT/prereg.tsv'"
check "prereg freezes scrub control condition" \
  "grep -Fxq $'scrub_condition\tSCRUB_PAUSED_FOR_CONTROLLED_BENCHMARK' '$OUT/prereg.tsv'"

echo
echo "=== 5. historical raw-log parser proof ==="
if [[ -z $FIXTURE ]]; then
  fail "historical V141P fixture path not supplied"
elif [[ ! -d $FIXTURE ]]; then
  fail "historical fixture does not exist: $FIXTURE"
elif python3 "$BASE_ANALYZE" fixture "$FIXTURE" --tol 2.0 \
       > "$OUT/historical-parser-replay.txt" 2>&1; then
  pass "frozen parser replays historical raw logs"
  grep -E 'U141B_ANALYZER_FIXTURE|actual I/O start|\+58s max window shift' \
    "$OUT/historical-parser-replay.txt" || true
else
  fail "historical raw-log replay failed"
  tail -30 "$OUT/historical-parser-replay.txt"
fi

echo
echo "=== 5b. U141d end-to-end raw-log matrix replay ==="
if [[ -d $FIXTURE ]]; then
  RAW_ROOT=$(mktemp -d "$OUT/raw-matrix.XXXXXX")
  mkdir -p "$RAW_ROOT/v4" "$RAW_ROOT/analysis"
  printf 'key\tvalue\nrun_id\tGATE0\n' > "$RAW_ROOT/RUN_META.tsv"
  RAW_ARMS=(V13 V14 V14 V13 V14 V13 V13 V14)
  for number in $(seq 1 8); do
    printf -v nn '%02d' "$number"
    arm=${RAW_ARMS[$((number - 1))]}
    source_round=$(( (number - 1) % 3 + 1 ))
    label="U141D-GATE0-A-R${nn}-${arm}"
    mkdir -p "$RAW_ROOT/v4/$label"
    ln -s "$FIXTURE/randrw-V141P-r${source_round}" \
      "$RAW_ROOT/v4/$label/randrw-${label}-r1"
    ln -s "$FIXTURE/randwrite-V141P-r${source_round}" \
      "$RAW_ROOT/v4/$label/randwrite-${label}-r1"
  done
  if python3 "$ANALYZE" matrix "$RAW_ROOT" A --output-dir "$RAW_ROOT/analysis" \
       > "$OUT/u141d-raw-matrix-replay.txt" 2>&1; then
    pass "U141d matrix path consumes 8 rounds of historical raw logs"
    tail -4 "$OUT/u141d-raw-matrix-replay.txt"
  else
    fail "U141d end-to-end raw-log matrix replay"
    tail -30 "$OUT/u141d-raw-matrix-replay.txt"
  fi

  B_ROUND="$RAW_ROOT/b-round"
  mkdir -p "$B_ROUND"
  ln -s "$FIXTURE/mseqwrite-V141P-r1" "$B_ROUND/mseqwrite-GATE0-r1"
  if python3 "$ANALYZE" round "$B_ROUND" --expect mseqwrite \
       > "$OUT/u141d-mseqwrite-round-replay.json" 2> "$OUT/u141d-mseqwrite-round-replay.stderr"; then
    pass "U141d mseqwrite round path consumes historical raw logs"
  else
    fail "U141d mseqwrite round replay"
    cat "$OUT/u141d-mseqwrite-round-replay.stderr"
  fi
else
  fail "cannot build U141d raw matrix without historical fixture"
fi

echo
echo "=== 6. provenance ==="
sha256sum "$TASK" "$DRIVER" "$ANALYZE" "$MOCK" "$SCRUB" "$0" "$COLLECT" \
  "$BASE_ANALYZE" "$V4_BASE" "$V4" \
  | tee "$OUT/provenance.sha256"
sha256sum "$PHASE_A_ARCHIVE" | tee -a "$OUT/provenance.sha256"

echo
echo "############################################################"
if (( ${#FAILURES[@]} )); then
  echo "U141D_GATE0_OFFLINE: FAIL (${#FAILURES[@]})"
  printf '  - %s\n' "${FAILURES[@]}"
  echo "Do not run on 157."
  exit 1
fi
echo "U141D_GATE0_OFFLINE: PASS"
echo "No environment command was executed.  Provenance: $OUT/provenance.sha256"
echo "############################################################"
