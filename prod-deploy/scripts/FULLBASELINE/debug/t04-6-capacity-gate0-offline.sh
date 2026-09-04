#!/usr/bin/env bash
# 04-6 Gate 0: offline-only.  No ssh/sudo/ceph/juicefs/fio/mount operation.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
DRIVER="$SCRIPT_DIR/t04-6-capacity-driver.sh"
ANALYZER="$SCRIPT_DIR/t04-6-capacity-analyze.py"
SAMPLER="$SCRIPT_DIR/t04-6-capacity-sampler.sh"
EXECUTOR="$SCRIPT_DIR/t04-6-capacity-execute.sh"
SCRUB_CONTROL="$SCRIPT_DIR/u141d-scrub-control.sh"
TASK="$ROOT/doc/perf-tasks/04-6-stage04-final-capacity-and-tuning-exit-decision.md"
OUT=${T046_GATE0_OUT:-$(mktemp -d /tmp/t046-gate0.XXXXXX)}
mkdir -p "$OUT"
FAIL=0
pass() { printf '[PASS]\t%s\n' "$*"; }
fail() { printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

printf 'T046_GATE0_BEGIN\t%s\tout=%s\n' "$(date -Is)" "$OUT"
for f in "$DRIVER" "$ANALYZER" "$SAMPLER" "$EXECUTOR" "$SCRUB_CONTROL" "$TASK" "$0"; do
  check "present $(basename "$f")" test -s "$f"
done
check 'driver bash -n' bash -n "$DRIVER"
check 'driver bash -u -n' bash -u -n "$DRIVER"
check 'gate bash -n' bash -n "$0"
check 'sampler bash -n' bash -n "$SAMPLER"
check 'executor bash -n' bash -n "$EXECUTOR"
check 'executor bash -u -n' bash -u -n "$EXECUTOR"
check 'scrub controller bash -n' bash -n "$SCRUB_CONTROL"
check 'scrub controller bash -u -n' bash -u -n "$SCRUB_CONTROL"
check 'analyzer Python compile' python3 -m py_compile "$ANALYZER"
check 'analyzer deterministic self-test' python3 "$ANALYZER" self-test
check 'sampler deterministic self-test' "$SAMPLER" --self-test
check 'executor deterministic self-test' "$EXECUTOR" --self-test
check 'scrub controller deterministic self-test' "$SCRUB_CONTROL" --self-test

# Execute both a sequential-read and mixed-R/W cell against a fake fio.  This
# catches variable-order, directory-mapping and latency-parser bugs that a
# syntax/static scan cannot see, without touching a mounted filesystem.
FIXTURE="$OUT/integration"
mkdir -p "$FIXTURE/test_dir/mseqread" "$FIXTURE/test_dir/mseqwrite"
for i in $(seq 0 15); do truncate -s 4G "$FIXTURE/test_dir/mseqread/mseqread.$i.0"; done
for i in $(seq 0 127); do truncate -s 1G "$FIXTURE/test_dir/rw_test.$i.0"; done
FAKE_FIO="$OUT/fake-fio.sh"
cat >"$FAKE_FIO" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jobs=0; rw=; log=; latlog=; directory=; name=
for arg in "$@"; do
  case $arg in
    --numjobs=*) jobs=${arg#*=} ;;
    --rw=*) rw=${arg#*=} ;;
    --write_bw_log=*) log=${arg#*=} ;;
    --write_lat_log=*) latlog=${arg#*=} ;;
    --directory=*) directory=${arg#*=} ;;
    --name=*) name=${arg#*=} ;;
  esac
done
[[ $jobs =~ ^[0-9]+$ && $jobs -gt 0 && -n $rw ]]
if [[ $name == mseqwrite-seed ]]; then
  [[ -d $directory && $jobs -eq 16 ]]
  for ((job=0; job<jobs; job++)); do truncate -s 4G "$directory/mseqwrite.$job.0"; done
  printf '  write: IOPS=1, BW=1MiB/s\nRun status group 0 (all jobs):\n   WRITE: bw=1MiB/s, io=64GiB, run=1000-1000msec\n'
  exit 0
fi
[[ -n $log && -n $latlog ]]
mkdir -p "$(dirname -- "$log")" "$(dirname -- "$latlog")"
for ((job=1; job<=jobs; job++)); do
  : >"${log}_bw.${job}.log"
  : >"${latlog}_clat.${job}.log"
  for ((sec=1; sec<=180; sec++)); do
    if [[ $rw == randrw ]]; then
      printf '%s,102400,0,262144\n%s,102400,1,262144\n' "$((sec*1000))" "$((sec*1000))" >>"${log}_bw.${job}.log"
    else
      direction=1; [[ $rw == read ]] && direction=0
      printf '%s,102400,%s,262144\n' "$((sec*1000))" "$direction" >>"${log}_bw.${job}.log"
    fi
    printf '%s,1000,0,262144\n' "$((sec*1000))" >>"${latlog}_clat.${job}.log"
  done
done
if [[ $rw == read || $rw == randrw ]]; then
  printf '  read: IOPS=1, BW=1MiB/s\n    clat percentiles (msec):\n     | 50.00th=[ 10], 95.00th=[ 20], 99.00th=[ 30]\n'
fi
if [[ $rw == write || $rw == randrw ]]; then
  printf '  write: IOPS=1, BW=1MiB/s\n    clat percentiles (usec):\n     | 50.00th=[ 40], 95.00th=[ 50], 99.00th=[ 60]\n'
fi
printf 'Run status group 0 (all jobs):\n   READ: bw=1MiB/s, io=1GiB, run=180000-180000msec\n'
EOF
chmod 700 "$FAKE_FIO"
check 'driver plan fixture' env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
  T046_FIO="$FAKE_FIO" T046_EVIDENCE_ROOT="$FIXTURE/run" "$DRIVER" plan GATE0 "$FIXTURE/run"
check 'driver R cell fixture' env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
  T046_FIO="$FAKE_FIO" T046_EXECUTE_ACK=I_ACK_04_6_CELL_EXECUTION \
  "$DRIVER" run-cell GATE0 R01 "$FIXTURE/run"
check 'R latency fixture generated' grep -Fq $'read\t10000.0\t20000.0\t30000.0' "$FIXTURE/run/cells/R01/latency.tsv"
for cell in R02 R03; do
  check "driver $cell fixture" env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
    T046_FIO="$FAKE_FIO" T046_EXECUTE_ACK=I_ACK_04_6_CELL_EXECUTION \
    "$DRIVER" run-cell GATE0 "$cell" "$FIXTURE/run"
done
check 'driver seed fixture' env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
  T046_FIO="$FAKE_FIO" T046_EXECUTE_ACK=I_ACK_04_6_MSEQWRITE_SEED \
  "$DRIVER" seed-mseqwrite GATE0 "$FIXTURE/run"
for cell in W01 W02 W03; do
  check "driver $cell fixture" env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
    T046_FIO="$FAKE_FIO" T046_EXECUTE_ACK=I_ACK_04_6_CELL_EXECUTION \
    "$DRIVER" run-cell GATE0 "$cell" "$FIXTURE/run"
done
check 'driver cleanup ownership fixture' env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
  T046_EXECUTE_ACK=I_ACK_04_6_MSEQWRITE_CLEANUP \
  "$DRIVER" cleanup-mseqwrite GATE0 "$FIXTURE/run"
check 'fixture cleanup is exact' bash -c "[[ \$(find '$FIXTURE/test_dir/mseqwrite' -mindepth 1 -maxdepth 1 | wc -l) -eq 0 ]]"
check 'driver M cell fixture' env T046_OFFLINE_FIXTURE=1 T046_TEST_DIR="$FIXTURE/test_dir" \
  T046_FIO="$FAKE_FIO" T046_EXECUTE_ACK=I_ACK_04_6_CELL_EXECUTION \
  "$DRIVER" run-cell GATE0 M01 "$FIXTURE/run"
check 'M latency directions generated' bash -c "[[ \$(wc -l <'$FIXTURE/run/cells/M01/latency.tsv') -eq 3 ]]"

# Static scan is intentionally strict: 04-6 must never inherit the old
# FULLBASELINE paths that perform cache flushing or Ceph mutations.
SOURCE="$OUT/runtime-source.txt"
sed -e 's/[[:space:]]*#.*$//' "$DRIVER" >"$SOURCE"
for pattern in 'drop_caches' 'sudo[[:space:]]' '^[[:space:]]*(ceph|juicefs|mount|umount|fusermount|systemctl|ssh)[[:space:]]' \
               'rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f' 'rsync[[:space:]].*--delete'; do
  if grep -nE -- "$pattern" "$SOURCE" >/dev/null; then fail "forbidden runtime pattern: $pattern"; else pass "absent $pattern"; fi
done
check 'fixed nine-cell matrix is present' grep -Fq 'for cell in R01 R02 R03 W01 W02 W03 M01 M02 M03' "$DRIVER"
check 'local/remote result scopes are exact' grep -Fq '/tmp/production/opencode-04-6-*' "$DRIVER"
check 'read mapping is 8->16->8' bash -c "grep -Eq 'R01\).*8|R02\).*16|R03\).*8' '$DRIVER'"
check 'write mapping is 8->16->8' bash -c "grep -Eq 'W01\).*8|W02\).*16|W03\).*8' '$DRIVER'"
check 'randrw mapping is 64->128->64' bash -c "grep -Eq 'M01\).*64|M02\).*128|M03\).*64' '$DRIVER'"
check 'fixed formal window' grep -Fq $'formal_window_s\t[15,175)' "$DRIVER"
check 'mseqwrite one-time seed contract' grep -Fq $'mseqwrite_seed\tone-time-only,16x4GiB' "$DRIVER"
check 'mseqwrite exact cleanup contract' grep -Fq $'mseqwrite_cleanup\texact-files-only' "$DRIVER"
check 'post-write gc return is explicit external gate' grep -Fq $'post_cleanup_gc\tREQUIRED_EXTERNAL_JUICEFS_GC_DELETE' "$DRIVER"
check 'normalization gc is explicit external gate' grep -Fq $'pre_and_between_cell_gc\tEXTERNAL_JUICEFS_GC_COMPACT_DELETE' "$DRIVER"
check 'executor uses compact+delete normalization' grep -Fq 'gc --compact --delete --threads 32' "$EXECUTOR"
check 'randrw directions remain separate' grep -Fq 'randrw.write' "$ANALYZER"
check 'analyzer refuses missing per-job log coverage' grep -Fq 'expected per-job logs 1..' "$ANALYZER"
check 'analyzer requires hard saturation evidence' grep -Fq 'hard_evidence' "$ANALYZER"
check 'sampler contains no sudo' bash -c "! grep -nE '^[[:space:]]*sudo[[:space:]]' '$SAMPLER'"
check 'sampler contains no global cache flush' bash -c "! grep -nF drop_caches '$SAMPLER'"
check 'sampler records health check keys' grep -Fq 'check_keys' "$SAMPLER"

# The online executor is admitted only when its frozen identity and the exact
# previously approved Ceph mutation surface remain visible.  Gate 0 never
# invokes any of these online commands.
check 'executor pins approved Ceph FSID' grep -Fq 'EXPECTED_FSID=f8137e5a-8af2-11f1-aa1c-4df480fc234d' "$EXECUTOR"
check 'executor pins exact OSD set 0..5' grep -Fq 'EXPECTED_OSDS=(0 1 2 3 4 5)' "$EXECUTOR"
check 'executor pins private msgr8 config identity' grep -Fq 'CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730' "$EXECUTOR"
check 'executor pins eight messenger workers' grep -Fq '[[ $threads -eq 8 ]]' "$EXECUTOR"
check 'executor pins Ceph NIC' grep -Fq 'CEPH_NIC=${T046_NIC:-enp139s0f0np0}' "$EXECUTOR"
check 'executor repair compact budget is 30' grep -Fq 'repair_compact_attempts=30' "$EXECUTOR"
check 'executor has state-driven scrub restoration trap' grep -Fq 'scrub_restore || restore_rc=$?' "$EXECUTOR"
check 'scrub controller owns only noscrub flags' grep -Fq 'OWNED_FLAGS=(noscrub nodeep-scrub)' "$SCRUB_CONTROL"
check 'executor direct compact command is exact' grep -Fq 'timeout 60 sudo ceph tell "osd.$osd" compact' "$EXECUTOR"
for pattern in 'drop_caches' 'rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f' \
               'rsync[[:space:]].*--delete' '^[[:space:]]*systemctl[[:space:]]' '^[[:space:]]*service[[:space:]]' \
               'ceph[[:space:]]+osd[[:space:]]+pool' 'pg_upmap' 'primary-affinity' \
               'mkfs' 'losetup' 'umount[[:space:]]+-[fl]'; do
  if grep -nE -- "$pattern" "$EXECUTOR" "$SCRUB_CONTROL" >/dev/null; then
    fail "forbidden orchestrator pattern: $pattern"
  else
    pass "orchestrator absent $pattern"
  fi
done
check 'scrub controller centralizes sudo Ceph calls' bash -c \
  "[[ \$(grep -cE '^[[:space:]]*sudo ceph \"\\\$@\"' '$SCRUB_CONTROL') -eq 1 ]]"

# Fail closed for accidental online invocation in Gate 0.
check 'unknown driver command fails closed' bash -c "! '$DRIVER' unknown 20990101-000000"
check 'invalid RUN_ID fails closed' bash -c "! '$DRIVER' plan ''"

printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL )); then printf 'T046_GATE0_FAIL\t%s\tout=%s\n' "$FAIL" "$OUT"; exit 1; fi
sha256sum "$DRIVER" "$ANALYZER" "$SAMPLER" "$EXECUTOR" "$SCRUB_CONTROL" "$TASK" "$0" >"$OUT/input-sha256.tsv"
printf 'T046_GATE0_PASS\tout=%s\n' "$OUT"
