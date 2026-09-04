#!/usr/bin/env bash
# 04-tmp3 Gate 0: local-only; no SSH, sudo, fio, mount or cluster access.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
DRIVER="$SCRIPT_DIR/t04tmp3-screen-driver.sh"
ANALYZER="$SCRIPT_DIR/t04tmp3-screen-analyze.py"
SCRUB="$SCRIPT_DIR/u141d-scrub-control.sh"
EXECUTOR="$SCRIPT_DIR/t04tmp3-executor.sh"
TASK="$ROOT/doc/perf-tasks/04-tmp3-competitor-large-block-sequential-benchmark.md"
OUT=${T04TMP3_GATE0_OUT:-/mnt/c/SunRise/test/04-tmp3/gate0-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
FAIL=0
pass() { printf '[PASS]\t%s\n' "$*"; }
fail() { printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

FILES=("$DRIVER" "$ANALYZER" "$SCRUB" "$EXECUTOR" "$TASK" "$0")
for file in "${FILES[@]}"; do check "present $(basename "$file")" test -s "$file"; done
check 'driver bash -n' bash -n "$DRIVER"
check 'driver bash -u -n' bash -u -n "$DRIVER"
check 'scrub bash -n' bash -n "$SCRUB"
check 'executor bash -n' bash -n "$EXECUTOR"
check 'executor bash -u -n' bash -u -n "$EXECUTOR"
check 'gate bash -n' bash -n "$0"
check 'analyzer compile' python3 -m py_compile "$ANALYZER"
check 'analyzer self-test' python3 "$ANALYZER" self-test
check 'scrub controller self-test' "$SCRUB" --self-test

# The runtime set is deliberately small.  These are the only high/critical
# defect classes applicable to a planner, capture contract and analyzer.
for id in D01 D02 D03 D04 D05 D06 D08 D12 D16 D17 D19 D21 D22 D23 D25 D26 D27 D28 D29 D30 D31 D32; do
  check "defect marker $id" grep -R -Fq "DEFECT-$id" "$DRIVER" "$ANALYZER" "$SCRUB" "$EXECUTOR" "$TASK"
done

check 'executor self-test' "$EXECUTOR" --self-test
if grep -nE 'rm[[:space:]]+-rf|fusermount[[:space:]]+-u[zf]|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|sshpass|PASSWORD=' "$EXECUTOR" >"$OUT/executor-forbidden.txt"; then
  fail 'executor contains forbidden destructive/secret text'
else
  pass 'executor forbidden destructive/secret scan'
fi
if grep -nEi 'ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)|juicefs[[:space:]]+(format|destroy)' "$EXECUTOR" >"$OUT/executor-unsupported.txt"; then
  fail 'executor contains format/destroy/pool mutation'
else
  pass 'executor no format/destroy/pool mutation'
fi
if grep -nE '(^|[[:space:];])sudo[[:space:]]' "$EXECUTOR" >"$OUT/executor-sudo.txt"; then
  fail 'executor contains unapproved sudo surface'
else
  pass 'executor has no sudo surface'
fi

RUNTIME="$OUT/runtime.txt"
cat "$DRIVER" "$ANALYZER" >"$RUNTIME"
# Dynamic command execution is forbidden in the runtime set.  The words
# below are assembled to keep this audit itself from becoming a false hit.
for bad in '(^|[[:space:];])sudo[[:space:]]' '(^|[[:space:];])ssh[[:space:]]' '(^|[[:space:];])mount[[:space:]]' '(^|[[:space:];])umount[[:space:]]' '(^|[[:space:];])(pkill|killall)[[:space:]]' 'fuser[[:space:]]+-k' '(^|[[:space:];])systemctl[[:space:]]' '(^|[[:space:];])(reboot|shutdown)[[:space:]]' 'juicefs[[:space:]]+format' 'juicefs[[:space:]]+destroy' 'ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)'; do
  if grep -nEi -- "$bad" "$RUNTIME" >/dev/null; then fail "forbidden runtime text: $bad"; else pass "absent $bad"; fi
done
check 'no secret assignment' bash -c "! grep -nE '(sshpass[[:space:]]+-p|PASSWORD=)[^$]' '$RUNTIME'"
check 'executor no secret assignment' bash -c "! grep -nE '(sshpass[[:space:]]+-p|PASSWORD=)[^$]' '$EXECUTOR'"
check 'matrix read palindrome' bash -c "grep -Fq 'R01) arm=A' '$DRIVER' && grep -Fq 'R06) arm=A' '$DRIVER'"
check 'matrix write palindrome' bash -c "grep -Fq 'W01) arm=A' '$DRIVER' && grep -Fq 'W06) arm=A' '$DRIVER'"
check 'full read palindrome' grep -Fq 'read\tA F R R F A' "$EXECUTOR"
check 'full write palindrome' grep -Fq 'write\tA F W W F A' "$EXECUTOR"
check 'four command contract' bash -c "grep -Fq 'echo 20M' '$EXECUTOR' && grep -Fq 'echo 16M' '$EXECUTOR' && grep -Fq -- '--allow_file_create=0' '$EXECUTOR'"
check 'private msgr8 baseline contract' bash -c "grep -Fq 'CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730' '$EXECUTOR' && grep -Fq 'ms_async_op_threads = 8' '$EXECUTOR' && grep -Fq 'make_private_ceph_conf' '$EXECUTOR'"
check 'combined gc O0/O1 contract' bash -c "grep -Fq 'gc --compact --delete --threads 32' '$EXECUTOR' && grep -Fq 'combined_gc PRE' '$EXECUTOR' && grep -Fq 'combined_gc POSTPREP' '$EXECUTOR' && grep -Fq 'O0.tsv' '$EXECUTOR' && grep -Fq 'O1.tsv' '$EXECUTOR'"
check 'arm mount paths expanded' bash -c "grep -Fq 'base=\"/tmp/jfs-04tmp3-' '$EXECUTOR' && grep -Fq 'cp \"\$base/read/20Gfile\"' '$EXECUTOR' && ! grep -Fq 'fio_cell \"\$cell\" \"\$work\" \"\$ASSET_ROOT' '$EXECUTOR'"
check 'prepare-assets fixed manifest' bash -c "grep -Fq 'prepare-assets' '$EXECUTOR' && grep -Fq 'assets-manifest.tsv' '$EXECUTOR' && grep -Fq 'PREPARE_ASSETS_PASS' '$EXECUTOR' && ! grep -nE 'prepare_assets.*sudo|sudo.*prepare_assets' '$EXECUTOR'"
check 'asset manifest samples only' bash -c "grep -Fq 'head -c 1048576' '$EXECUTOR' && grep -Fq 'tail -c 1048576' '$EXECUTOR' && ! grep -Fq 'sha256sum \"\$p\"' '$EXECUTOR'"
check 'A baseline cp coverage' bash -c "grep -Fq '\$cell == R01 || \$cell == R04' '$EXECUTOR' && grep -Fq '\$cell == W01 || \$cell == W04' '$EXECUTOR'"
check 'inventory residual mount scan' bash -c "grep -Fq 'residual-mounts.tsv' '$EXECUTOR' && grep -Fq 'residual_tmp3_mount' '$EXECUTOR'"
check 'write object anchor hard gate' bash -c "grep -Fq '8192' '$EXECUTOR' && grep -Fq 'objects anchor drift' '$EXECUTOR'"
check 'analyzer P10/P90 output' bash -c "grep -Fq 'formal_p10_MiBs' '$ANALYZER' && grep -Fq 'formal_p90_MiBs' '$ANALYZER'"
check 'fixed safe paths' bash -c "grep -Fq 'TASK_ROOT=/mnt/c/SunRise/test/04-tmp3' '$DRIVER' && grep -Fq 'REF=/mnt/juicefs' '$EXECUTOR' && grep -Fq 'SCRATCH_PARENT=/mnt/jfs-cache/04tmp3' '$EXECUTOR' && ! grep -Eq 'T04TMP3_(TASK_ROOT|REFERENCE_MNT|SCRATCH_PARENT):-' '$DRIVER' '$EXECUTOR'"
check 'scratch parent ownership gate' grep -Fq '1002:1002:700' "$EXECUTOR"
check 'executor root overrides rejected' bash -c "! env T04TMP3_REFERENCE_MNT=/tmp/evil T04TMP3_SCRATCH_PARENT=/tmp/evil '$EXECUTOR' --self-test"
check 'driver root override rejected' bash -c "! env T04TMP3_TASK_ROOT=/tmp/evil '$DRIVER'"
check 'no automatic L2' grep -Fq 'NO-AUTOMATIC-EXPANSION' "$DRIVER"
check 'scrub owned flags only' grep -Fq 'OWNED_FLAGS=(noscrub nodeep-scrub)' "$SCRUB"
check 'read-only perf dump is non-sudo and timed' bash -c "grep -Fq 'ceph_read tell' '$EXECUTOR' && grep -Fq 'ceph_read(){ timeout 20' '$EXECUTOR' && ! grep -Fq 'sudo ceph tell' '$EXECUTOR'"
check 'prepared assets have exact size gate' bash -c "grep -Fq 'prepared file size mismatch' '$EXECUTOR' && grep -Fq 'expected=10737418240' '$EXECUTOR' && grep -Fq 'expected=21474836480' '$EXECUTOR'"
check 'prepare-only routine scrub policy is explicit' bash -c "grep -Fq 'health PREPARE-pre preparing' '$EXECUTOR' && grep -Fq 'health PREPARE-post preparing' '$EXECUTOR' && grep -Fq 'allowed={' '$EXECUTOR'"
check 'no wildcard asset deletion inventory' bash -c "! grep -Fq '\$ASSET_ROOT/write/\"*/testfile1' '$EXECUTOR' && grep -Fq 'asset_paths \"\$ASSET_ROOT\"' '$EXECUTOR'"
check 'fio JSON contract validation' bash -c "grep -Fq 'validate_fio_json' '$ANALYZER' && grep -Fq 'JSON fio rw/bs contract mismatch' '$ANALYZER' && grep -Fq 'JSON fio reports I/O errors' '$ANALYZER'"
check 'fio 3.28 omitted-time_based semantic proof' bash -c "grep -Fq 'omits time_based and lacks looping-I/O proof' '$ANALYZER' && grep -Fq 'active_bytes <= 10 * 1024**3' '$ANALYZER'"
check 'worker identity and msgr8 thread gate' bash -c "grep -Fq 'worker_pid' '$EXECUTOR' && grep -Fq 'worker_starttime' '$EXECUTOR' && grep -Fq 'worker_exe' '$EXECUTOR' && grep -Fq 'msgr_worker_threads' '$EXECUTOR' && grep -Fq '== 8' '$EXECUTOR'"
check 'Go argv truncation uses unique launch log identity' bash -c "grep -Fq 'if log not in cmd: continue' '$EXECUTOR' && ! grep -Fq 'if meta not in cmd' '$EXECUTOR'"
check 'cleanup works without write PASS' bash -c "! grep -Fq 'write_phase_required' '$EXECUTOR' && grep -Fq 'combined_gc CLEANUP' '$EXECUTOR' && grep -Fq 'CLEANUP_PASS' '$EXECUTOR'"
check 'formal phase requires completed prepare' grep -Fq 'prepare/PASS' "$EXECUTOR"
check 'driver and executor share timestamp RUN_ID grammar' bash -c "grep -Fq '^[0-9]{8}-[0-9]{6}\$' '$DRIVER' && grep -Fq '^[0-9]{8}-[0-9]{6}\$' '$EXECUTOR'"
check 'local declarations do not hide RHS failures' bash -c "! grep -nE 'local [^;]*=\"\\$' '$EXECUTOR'"
check 'phase plan carries exact fsid lease state' bash -c "grep -Fq 'phase\\tlease\\tfsid\\tstate_file' '$EXECUTOR' && grep -Fq 'state-path \"\$RUN_ID-phase-a\"' '$EXECUTOR' && grep -Fq 'state-path \"\$RUN_ID-phase-b\"' '$EXECUTOR'"
check 'scrub sudo confined to write helper' bash -c "test \$(grep -Ec '^[[:space:]]+timeout 20 sudo ceph ' '$SCRUB') -eq 1 && grep -Fq 'ceph_write osd set' '$SCRUB' && grep -Fq 'ceph_write osd unset' '$SCRUB'"
if grep -nEi 'rm[[:space:]]+-rf|fusermount[[:space:]]+-u[zf]|umount[[:space:]]+-(l|f)|pkill|killall|fuser[[:space:]]+-k|juicefs[[:space:]]+(format|destroy)|ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)' "$SCRUB" >"$OUT/scrub-forbidden.txt"; then
  fail 'scrub controller contains forbidden destructive text'
else
  pass 'scrub controller forbidden destructive scan'
fi

printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL )); then printf 'T04TMP3_GATE0_FAIL\t%s\n' "$OUT"; exit 1; fi
sha256sum "${FILES[@]}" >"$OUT/input-sha256.tsv"
printf 'T04TMP3_GATE0_PASS\tout=%s\n' "$OUT"
