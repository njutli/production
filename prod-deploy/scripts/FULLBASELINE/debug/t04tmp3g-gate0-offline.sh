#!/usr/bin/env bash
# 04-tmp3g Gate 0: local-only; no SSH, sudo, fio, mount, ceph or JuiceFS execution.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
EXECUTOR="$SCRIPT_DIR/t04tmp3g-executor.sh"
ANALYZER="$SCRIPT_DIR/t04tmp3g-analyze.py"
SCRUB="$SCRIPT_DIR/u141d-scrub-control.sh"
TASK="$ROOT/doc/perf-tasks/04-tmp3g-competitor-large-block-async-write-closure.md"
OUT=${T04TMP3G_GATE0_OUT:-/tmp/t04tmp3g-gate0-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
FAIL=0
pass(){ printf '[PASS]\t%s\n' "$*"; }
fail(){ printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

FILES=("$EXECUTOR" "$ANALYZER" "$SCRUB" "$TASK" "$0")
for file in "${FILES[@]}"; do check "present $(basename "$file")" test -s "$file"; done
check 'executor bash syntax' bash -n "$EXECUTOR"
if grep -nE 'local cell=\$1.*(out|file|prefix)=.*\$cell' "$EXECUTOR" >"$OUT/local-expansion.txt"; then
  fail 'set-u unsafe same-declaration expansion absent'
else
  pass 'set-u unsafe same-declaration expansion absent'
fi
check 'gate bash syntax' bash -n "$0"
check 'analyzer compile' python3 -m py_compile "$ANALYZER"
check 'executor self-test' bash "$EXECUTOR" --self-test
check 'analyzer fixtures' python3 "$ANALYZER" self-test
check 'scrub controller self-test' bash "$SCRUB" --self-test

for id in D01 D02 D03 D04 D05 D06 D08 D12 D16 D17 D19 D21 D22 D23 D25 D26 D27 D28 D29 D30 D31 D32; do
  check "defect marker $id" grep -R -Fq "DEFECT-$id" "$EXECUTOR" "$ANALYZER" "$SCRUB" "$TASK"
done

if grep -nE 'rm[[:space:]]+-rf|fusermount[[:space:]]+-u[zf]|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|sshpass|PASSWORD=|(^|[[:space:];])(reboot|shutdown|halt|poweroff)([[:space:];]|$)' "$EXECUTOR" >"$OUT/forbidden.txt"; then
  fail 'forbidden destructive/secret command text'
else
  pass 'forbidden destructive/secret command text absent'
fi
if grep -nEi 'ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)|juicefs[^[:space:]]*[[:space:]]+(format|destroy)' "$EXECUTOR" >"$OUT/unsupported.txt"; then
  fail 'format/destroy/pool mutation absent'
else
  pass 'format/destroy/pool mutation absent'
fi
if grep -nE '(^|[[:space:];])sudo[[:space:]]' "$EXECUTOR" >"$OUT/sudo-surface.txt"; then
  fail 'executor contains sudo outside scrub controller'
else
  pass 'executor contains no sudo'
fi
if grep -nE '(sshpass[[:space:]]+-p|PASSWORD=)[^$]' "$EXECUTOR" "$ANALYZER" "$SCRUB" "$TASK" >"$OUT/secrets.txt"; then fail 'plaintext secret absent'; else pass 'plaintext secret absent'; fi

check 'exact seven-cell order' bash -c "grep -Fq 'S01\\tpsync\\t1\\t120\\toff\\nC08A\\tlibaio\\t8\\t120\\ton\\nC01\\tlibaio\\t1\\t60\\ton\\nC02\\tlibaio\\t2\\t60\\ton\\nC04\\tlibaio\\t4\\t60\\ton\\nC08B\\tlibaio\\t8\\t120\\ton\\nS02\\tpsync\\t1\\t120\\toff' '$EXECUTOR'"
check 'one async mount for all C cells' bash -c "grep -Fq 'mount_arm C C' '$EXECUTOR' && grep -Fq 'run_cell C08A libaio 8 120 C; run_cell C01 libaio 1 60 C; run_cell C02 libaio 2 60 C; run_cell C04 libaio 4 60 C; run_cell C08B libaio 8 120 C' '$EXECUTOR' && grep -Fq 'cmd+=(-o async_dio)' '$EXECUTOR'"
check 'sync anchors use psync QD1' bash -c "grep -Fq 'run_cell S01 psync 1 120 SYNC1' '$EXECUTOR' && grep -Fq 'run_cell S02 psync 1 120 SYNC2' '$EXECUTOR'"
check 'fio write contract' bash -c "grep -Fq 'local -a cmd=(fio --name=write16m' '$EXECUTOR' && grep -Fq -- '--bs=16M' '$EXECUTOR' && grep -Fq -- '--rw=write' '$EXECUTOR' && grep -Fq -- '--size=10G' '$EXECUTOR' && grep -Fq -- '--allow_file_create=0' '$EXECUTOR'"
check 'no cache/writeback workload mutation' bash -c "grep -Fq -- '--cache-size 0' '$EXECUTOR' && ! grep -Fq -- '--writeback' '$EXECUTOR'"
check 'independent seven assets' bash -c "grep -Fq 'for cell in S01 C08A C01 C02 C04 C08B S02' '$EXECUTOR' && grep -Fq '\$base/\$cell.bin' '$EXECUTOR'"
check 're-mount persistence all assets' bash -c "grep -Fq 'mount_arm VERIFY V' '$EXECUTOR' && grep -Fq 'verify_all_assets' '$EXECUTOR' && grep -Fq 'remount_persistence_' '$EXECUTOR'"
check '300 second upload drain' bash -c "grep -Fq 'juicefs_object_request_uploading' '$EXECUTOR' && grep -Fq 'now-start < 300' '$EXECUTOR'"
check 'complete mutation plan includes one shared GC and exact assets' bash -c "grep -Fq 'mutation-contract.txt.sha256' '$EXECUTOR' && grep -Fq 'Shared-volume GC, exactly one invocation' '$EXECUTOR' && grep -Fq 'I_ACK_04TMP3G_SHARED_GC_' '$EXECUTOR' && grep -Fq '<S01|C08A|C01|C02|C04|C08B|S02>.bin' '$EXECUTOR'"
check 'per-cell metrics host and post-health gates' bash -c "grep -Fq 'cell_snapshot \"\$cell\" pre' '$EXECUTOR' && grep -Fq 'cell_snapshot \"\$cell\" post' '$EXECUTOR' && grep -Fq 'health \"\$cell-post\" paused' '$EXECUTOR' && grep -Fq 'validate_supporting_evidence(root, cell)' '$ANALYZER'"
check 'exact 6/6 OSD and runtime async identity' bash -c "grep -Fq 'OSDs not exactly 6/6 up-in' '$EXECUTOR' && grep -Fq 'async_dio_runtime_missing' '$EXECUTOR' && grep -Fq 'mount-mode-ref.tsv' '$ANALYZER'"
check 'analyzer validates fio drain and persistence evidence' bash -c "grep -Fq 'fio rc nonzero' '$ANALYZER' && grep -Fq 'post/remount asset mismatch' '$ANALYZER' && grep -Fq 'upload drain not strictly closed' '$ANALYZER'"
check '8 percent anchor gates' bash -c "grep -Fq 's_drift > 8 or c_drift > 8' '$ANALYZER'"
check 'dual QD8 dual-metric target' bash -c "grep -Fq 'for cell in (\"C08A\", \"C08B\")' '$ANALYZER' && grep -Fq 'for key in (\"summary_MiBs\", \"formal_mean_MiBs\")' '$ANALYZER' && grep -Fq '3051.76' '$ANALYZER'"
check 'no drop caches or OSD compact' bash -c "! grep -Eq 'drop_caches|ceph_read tell .* compact|ceph tell .* compact' '$EXECUTOR'"
check 'B256/current-volume only' bash -c "grep -Fq \"s.get('BlockSize')\" '$EXECUTOR' && grep -Fq 'META=tikv://' '$EXECUTOR' && ! grep -Eq 'juicefs[^ ]* (format|destroy)' '$EXECUTOR'"
check 'exact cleanup scope' bash -c "grep -Fq \"root.startswith('/mnt/juicefs/test_dir/04tmp3g-')\" '$EXECUTOR' && grep -Fq 'os.unlink(path)' '$EXECUTOR'"
check 'runtime set frozen' bash -c "grep -Fq 'sha256sum \"\$EXECUTOR\" \"\$ANALYZER\" \"\$SCRUB\"' '$EXECUTOR'"

printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL )); then printf 'T04TMP3G_GATE0_FAIL\tout=%s failures=%s\n' "$OUT" "$FAIL"; exit 1; fi
sha256sum "${FILES[@]}" >"$OUT/input-sha256.tsv"
printf 'T04TMP3G_GATE0_PASS\tout=%s\n' "$OUT"
