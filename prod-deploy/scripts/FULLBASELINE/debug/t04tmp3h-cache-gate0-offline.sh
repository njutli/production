#!/usr/bin/env bash
# 04-tmp3h Gate 0: local-only; never invokes SSH, sudo, fio, mount, Ceph or JuiceFS.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$DIR/../../.." && pwd)
RUN=$DIR/t04tmp3h-cache-run.sh
ANALYZER=$DIR/t04tmp3h-cache-analyze.py
SCRUB=$DIR/u141d-scrub-control.sh
TASK=$ROOT/doc/perf-tasks/04-tmp3h-competitor-four-command-client-cache-capacity.md
OUT=${T04TMP3H_GATE0_OUT:-/tmp/t04tmp3h-gate0-$(date +%Y%m%d-%H%M%S)}
[[ $OUT == /tmp/t04tmp3h-gate0-* && ! -e $OUT ]] || { printf '04TMP3H_GATE0_FAIL\tunsafe_or_existing_output\n' >&2; exit 42; }
mkdir -m 0700 "$OUT"
FAIL=0
pass(){ printf '[PASS]\t%s\n' "$*"; }
fail(){ printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

FILES=("$RUN" "$ANALYZER" "$SCRUB" "$TASK" "$0")
for file in "${FILES[@]}"; do check "present $(basename "$file")" test -s "$file"; done
check 'runner bash syntax' bash -n "$RUN"
if grep -nE 'local (out|label|order)=\$[12].*(dir|out|local_out|cp_write|fio_write)=.*\$(base|label|order)' "$RUN" >"$OUT/local-expansion.txt"; then
  fail 'set-u unsafe same-declaration expansion absent'
else
  pass 'set-u unsafe same-declaration expansion absent'
fi
check 'gate bash syntax' bash -n "$0"
check 'analyzer compile' python3 -m py_compile "$ANALYZER"
check 'runner self-test' bash "$RUN" offline-self-test 20260906-120000
check 'analyzer fixtures' python3 "$ANALYZER" self-test
check 'scrub controller self-test' bash "$SCRUB" --self-test

if grep -nE 'rm[[:space:]]+-rf|fusermount[[:space:]]+-u[zf]|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|sshpass|PASSWORD=|drop_caches|(^|[[:space:];])(reboot|shutdown|halt|poweroff)([[:space:];]|$)' "$RUN" >"$OUT/forbidden.txt"; then
  fail 'forbidden destructive/secret command text'
else
  pass 'forbidden destructive/secret command text absent'
fi
if grep -nEi 'ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)|juicefs[^[:space:]]*[[:space:]]+(format|destroy)' "$RUN" >"$OUT/unsupported.txt"; then
  fail 'format/destroy/pool mutation absent'
else
  pass 'format/destroy/pool mutation absent'
fi

check 'four capacity tiers fixed' bash -c "grep -Fq 'T32) BACKING_GIB=32; TIER_MIB=16384' '$RUN' && grep -Fq 'T64) BACKING_GIB=64; TIER_MIB=32768' '$RUN' && grep -Fq 'T96) BACKING_GIB=96; TIER_MIB=40960' '$RUN' && grep -Fq 'T128) BACKING_GIB=128; TIER_MIB=40960' '$RUN'"
check 'full allocation and 64GiB reserve' bash -c "grep -Fq 'fallocate -l' '$RUN' && grep -Fq 'BACKING_BYTES + 68719476736' '$RUN' && ! grep -Eq 'truncate .*T(32|64|96|128)' '$RUN'"
check 'root-owned cache parent uses scoped local-root sudo lifecycle' bash -c "grep -Fq 'sudo install -d -m 0700 -o 1002 -g 1002 \$LOCAL_ROOT' '$RUN' && grep -Fq 'record sudo rmdir \"\$LOCAL_ROOT\"' '$RUN'"
check 'ordinary ext4 inode contract' bash -c "grep -Fq 'mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0' '$RUN' && ! grep -Eq 'mkfs\.ext4.*-T[[:space:]]+largefile' '$RUN'"
check 'single cache filesystem with writeback' bash -c "grep -Fq -- '--cache-dir \"\$CACHE_DIR\" --cache-size \"\$TIER_MIB\" --free-space-ratio 0.20 --writeback' '$RUN'"
check 'delivery mount parameters fixed' bash -c "grep -Fq -- '--max-fuse-io 1M --max-downloads 200 --max-uploads 150 --buffer-size 300' '$RUN'"
check 'FWD command order fixed' bash -c "grep -Fq 'FWD cp-read fio-read cp-write drain fio-write drain' '$RUN'"
check 'REV command order fixed' bash -c "grep -Fq 'REV fio-write drain cp-write drain fio-read cp-read' '$RUN'"
check 'original fio commands fixed' bash -c "grep -Fq -- '--size=10G' '$RUN' && grep -Fq -- '--runtime=\"\$runtime\" --time_based --group_reporting' '$RUN' && ! grep -Eq 'ioengine=libaio|iodepth=[2-9]|async_dio' '$RUN'"
check 'cp exact wall-clock contract' bash -c "grep -Fq '/usr/bin/time -f %e' '$RUN' && grep -Fq '21474836480' '$RUN'"
check 'fixed read warm-up' bash -c "grep -Fq 'warm_cp_read' '$RUN' && grep -Fq 'warm_fio_read' '$RUN'"
check 'strict 900 second drain with 10s double-zero' bash -c "grep -Fq 'now-start >= 900' '$RUN' && grep -Fq 'STRICT_ZERO' '$RUN' && grep -Fq 'CAPACITY_TIMEOUT.tsv' '$RUN' && [[ \$(grep -Fc 'sleep 10' '$RUN') -ge 3 ]]"
check 'analyzer independently verifies strict drain evidence' bash -c "grep -Fq 'rows[-2:]' '$ANALYZER' && grep -Fq 'final_gap < 9.5' '$ANALYZER' && grep -Fq 'not 0 <= seconds <= 900' '$ANALYZER'"
check 'foreground sampler is executed and merged' bash -c "[[ \$(grep -Fc 'sample \"\$stop\" \"\$out/runtime.tsv\"' '$RUN') -eq 2 ]] && grep -Fq 'foreground_staging_peak_bytes' '$ANALYZER' && grep -Fq 'runtime_rows + rows' '$ANALYZER'"
check 'shared GC has frozen plan and exact ACK' bash -c "grep -Fq 'maximum five invocations' '$RUN' && grep -Fq 'I_ACK_04TMP3H_SHARED_GC_' '$RUN' && grep -Fq 'mutation-contract.txt.sha256' '$RUN'"
check 'FWD/REV early stop' bash -c "grep -Fq 'FOUR_COMMAND_CACHE_TARGET_CONFIRMED' '$RUN' && grep -Fq '[[ \$verdict != FOUR_COMMAND_CACHE_TARGET_CONFIRMED ]] || break' '$RUN'"
check 'interrupted completed-FWD can close without rerunning data commands' bash -c "grep -Fq 'cmd_resume_completed_fwd' '$RUN' && grep -Fq 'FWD-analysis.pre-repair-empty.json' '$RUN' && grep -Fq 'if [[ -f \$ROOT/cells/\$tier/PASS ]]' '$RUN'"
check 'post-GC metric-parser failure can resume without duplicate GC' bash -c "grep -Fq 'cmd_resume_destroyed_tier' '$RUN' && grep -Fq 'wait_pool \"after-\$CELL\"' '$RUN' && grep -Fq 'tikv_engine_pending_compaction_bytes(\\{|\$)' '$RUN'"
check 'scrub restore on success/failure' bash -c "grep -Fq 'trap restore_scrub_on_exit EXIT' '$RUN' && grep -Fq 'cmd_restore_scrub; trap - EXIT' '$RUN'"
check 'read/write recovery and exact unlink' bash -c "grep -Fq 'verify_recovery_mount' '$RUN' && grep -Fq 'record unlink -- \"\$path\"' '$RUN'"
check 'loop identity before mkfs/detach' bash -c "[[ \$(grep -Fc 'verify_loop \"\$loop\"' '$RUN') -ge 3 ]]"
check 'no large-device target' bash -c "! grep -Eq '/dev/(nvme|sd|md)[[:alnum:]]*' '$RUN'"
check 'targets and dual metric decision' bash -c "grep -Fq 'CP_TARGET_GBS = 2.0' '$ANALYZER' && grep -Fq '5149.84' '$ANALYZER' && grep -Fq '3051.76' '$ANALYZER' && grep -Fq 'summary > FIO_TARGET_MIB' '$ANALYZER' && grep -Fq 'formal > FIO_TARGET_MIB' '$ANALYZER'"
check 'cache hit and durable bandwidth outputs' bash -c "grep -Fq 'cache_hit_ratio' '$ANALYZER' && grep -Fq 'effective_durable_MiBs' '$ANALYZER'"
check 'buffered cp permits page-cache-only zero block-cache delta' grep -Fq 'allow_zero=True' "$ANALYZER"
check 'scrub ownership contract' grep -Fq 'OWNED_FLAGS=(noscrub nodeep-scrub)' "$SCRUB"
check 'frozen runtime hashes' bash -c "grep -Fq 'sha256sum \"\$SCRIPT_DIR/t04tmp3h-cache-run.sh\"' '$RUN' && grep -Fq 'sha256sum -c \"\$ROOT/plans/scripts.sha256\"' '$RUN'"

grep -En 'sudo[[:space:]]+' "$RUN" >"$OUT/sudo-surface.txt" || fail 'expected scoped sudo surface missing'
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|chmod|dd|wipefs|systemctl|reboot|shutdown|mount[[:space:]]+/dev/(nvme|sd|md)|mkfs[^[:space:]]*[[:space:]]+/dev/(nvme|sd|md))' "$RUN" >"$OUT/unsafe-sudo.txt"; then
  fail 'unsafe sudo surface absent'
else
  pass 'unsafe sudo surface absent'
fi

printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL )); then printf '04TMP3H_GATE0_FAIL\tout=%s failures=%s\n' "$OUT" "$FAIL"; exit 1; fi
sha256sum "${FILES[@]}" >"$OUT/input-sha256.tsv"
printf '04TMP3H_GATE0_OFFLINE_PASS\tout=%s\n' "$OUT"
