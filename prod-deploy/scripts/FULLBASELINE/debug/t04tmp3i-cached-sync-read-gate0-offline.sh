#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN=$DIR/t04tmp3i-cached-sync-read-run.sh
AN=$DIR/t04tmp3i-cached-sync-read-analyze.py
OUT=${T04TMP3I_GATE0_OUT:-/tmp/t04tmp3i-gate0-$(date +%Y%m%d-%H%M%S)}
[[ ! -e $OUT && $OUT == /tmp/t04tmp3i-gate0-* && $OUT != /tmp ]] || { echo T04TMP3I_GATE0_FAIL_output_scope >&2; exit 42; }
mkdir -m 0700 "$OUT"

failures=0
pass(){ printf '[PASS]\t%s\n' "$*"; }
fail(){ printf '[FAIL]\t%s\n' "$*"; failures=$((failures+1)); }
for file in "$RUN" "$AN" "$0"; do [[ -s $file && ! -L $file ]] && pass "present $(basename "$file")" || fail "missing_or_symlink $file"; done
bash -n "$RUN" && pass runner_syntax || fail runner_syntax
bash -n "$0" && pass gate_syntax || fail gate_syntax
PYTHONPYCACHEPREFIX=$OUT/pycache python3 -m py_compile "$AN" && pass analyzer_compile || fail analyzer_compile
bash "$RUN" self-test 20260906-000000 && pass runner_self_test || fail runner_self_test
python3 "$AN" self-test && pass analyzer_self_test || fail analyzer_self_test

bash "$RUN" print-matrix 20260906-000000 >"$OUT/matrix.tsv"
expected=$'cell\tarm\tmax_readahead\twarm_s\tformal_s\tpurpose\nLOCAL1\tLOCAL\t-\t0\t60\tloop-ext4-direct\nA1\tA\t8M\t60\t60\tanchor-pre\nB1\tB\t32M\t60\t60\tra32-confirm-1\nB2\tB\t32M\t60\t60\tra32-confirm-2\nA2\tA\t8M\t60\t60\tanchor-post'
[[ $(<"$OUT/matrix.tsv") == "$expected" ]] && pass matrix_exact || fail matrix_exact

grep -Fq 'local -a cmd=("$JFS" mount -d --max-fuse-io 1M --max-readahead "$RA" --max-downloads 200 --max-uploads 150 --buffer-size 300 --cache-dir "$CACHE_DIR" --cache-size 32768 --free-space-ratio 0.20 --writeback' "$RUN" && pass mount_only_variable_ra || fail mount_only_variable_ra
grep -Fq 'local -a warm=(fio' "$RUN" && grep -Fq -- '--runtime=60 --time_based' "$RUN" && grep -Fq -- '--ioengine=psync --iodepth=1' "$RUN" && pass fio_contract || fail fio_contract
grep -Fq 'for cell in A1 B1 B2 A2' "$RUN" && pass abba_order || fail abba_order
grep -Fq 'ASSET_REL=/test_dir/seqread/seqread.0.0' "$RUN" && grep -Fq 'asset_fingerprint' "$RUN" && ! grep -Eq '\$JFS.*(format|destroy|gc|compact)' "$RUN" && pass existing_asset_read_only || fail existing_asset_read_only
grep -Fq 'hit_ratio>=.995 and miss_ratio<=.005 and rx_ratio<=.01' "$AN" && grep -Fq 'ceph-rx-bytes.txt' "$AN" && pass cache_and_ceph_rx_gate || fail cache_and_ceph_rx_gate
grep -Fq 'B1","B2") for key in ("summary_MiBs","formal_MiBs")' "$AN" && grep -Fq 'drift_a>8 or drift_b>8' "$AN" && pass verdict_contract || fail verdict_contract
grep -Fq 'analyze_local' "$AN" && grep -Fq 'local1_end_fsync' "$AN" && grep -Fq 'local1_write_bytes' "$AN" && pass local1_contract || fail local1_contract

grep -n 'sudo ' "$RUN" >"$OUT/sudo-lines.txt" || true
if grep -En 'sudo +(rm +|chown +-R|chmod +-R|losetup +-D|mount +[^ ]* +/dev/(sd|nvme)|systemctl|reboot|shutdown|halt|poweroff|ceph|wipefs|dd +|lv(remove|create))' "$OUT/sudo-lines.txt" >"$OUT/forbidden-sudo.txt"; then fail forbidden_sudo; else pass sudo_surface_scoped; fi
if grep -En 'rm +-rf|fusermount +-u|umount +-[lf]|pkill|killall|fuser +-k|drop_caches|losetup +-D|reboot|shutdown|halt|poweroff' "$RUN" | grep -Ev '^[^:]+:[[:space:]]*(#|printf )' >"$OUT/forbidden.txt"; then fail forbidden_command; else pass no_forbidden_command; fi
if grep -En '(ceph +osd +pool|ceph +osd +pg-upmap|ceph +osd +primary-affinity|ceph +config +set|noscrub|nodeep-scrub|juicefs[^ ]* +(format|destroy|gc|compact))' "$RUN" >"$OUT/global-mutation.txt"; then fail global_or_volume_mutation; else pass no_global_or_volume_mutation; fi
grep -Fq 'T04TMP3I_ACK' "$RUN" && grep -Fq 'I_ACK_04TMP3I_RUN_$RUN_ID' "$RUN" && pass exact_ack || fail exact_ack
grep -Fq 'verify_loop "$loop"' "$RUN" && grep -Fq 'loop_backing' "$RUN" && grep -Fq 'sudo losetup -j "$BACKING"' "$RUN" && pass loop_identity_guards || fail loop_identity_guards
grep -Fq 'find "$CACHE_DIR" -xdev -depth -delete' "$RUN" && grep -Fq 'CACHE_DIR == "$CACHE_MNT/cache"' "$RUN" && pass exact_cache_cleanup || fail exact_cache_cleanup
grep -Fq 'cmp -s "$0" "$ROOT/scripts/t04tmp3i-cached-sync-read-run.sh"' "$RUN" && grep -Fq 'sha256sum -c "$ROOT/plans/scripts.sha256"' "$RUN" && pass script_freeze || fail script_freeze

printf 'failures\t%s\n' "$failures" >"$OUT/summary.tsv"
sha256sum "$RUN" "$AN" "$0" >"$OUT/input-sha256.tsv"
if (( failures )); then printf 'T04TMP3I_GATE0_FAIL out=%s failures=%s\n' "$OUT" "$failures"; exit 1; fi
printf 'T04TMP3I_GATE0_OFFLINE_PASS out=%s\n' "$OUT"
