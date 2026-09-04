#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RUN=$DIR/t04tmp2d-cache-run.sh
ANALYZE=$DIR/t04tmp2d-cache-analyze.py
GATE=$DIR/t04tmp2d-cache-gate0-offline.sh
RUN_ID=${T04TMP2D_GATE_RUN_ID:-$(date +%Y%m%d-%H%M%S)}
OUT=
fail() { printf '04TMP2D_GATE_FAIL\t%s\n' "$*" >&2; exit 42; }

[[ -f $RUN && ! -L $RUN ]] || fail "run script missing/symlink"
[[ -f $ANALYZE && ! -L $ANALYZE ]] || fail "analyzer missing/symlink"
[[ -f $GATE && ! -L $GATE ]] || fail "gate script missing/symlink"
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || fail "invalid fixture RUN_ID"
OUT=$(mktemp -d "/tmp/t04tmp2d-gate0-$RUN_ID-XXXXXX")
[[ $OUT == /tmp/t04tmp2d-gate0-* && -d $OUT && ! -L $OUT ]] || fail "unsafe fixture output"

bash -n "$RUN"
bash -u -n "$RUN"
bash -n "$GATE"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANALYZE"
if command -v shellcheck >/dev/null; then shellcheck "$RUN" "$GATE" >"$OUT/shellcheck.txt"; else printf 'SKIPPED\n' >"$OUT/shellcheck.txt"; fi

# The only sudo text is the two printed, non-executable plan lines.
[[ $(grep -Ec '^[[:space:]]*sudo ' "$RUN") -eq 2 ]] || fail "unexpected sudo surface"
grep -Fq 'sudo install -d -m 0700 -o 1002 -g 1002 $CACHE_ROOT' "$RUN" || fail "install plan missing"
grep -Fq 'sudo rmdir $CACHE_ROOT' "$RUN" || fail "rmdir plan missing"
if grep -En '(^|[[:space:]])(ssh|scp|mkfs|losetup|fallocate[[:space:]]+-|drop_caches|reboot|shutdown|poweroff|killall|pkill|rm[[:space:]]+-r)' "$RUN" >"$OUT/forbidden.txt"; then
  fail "forbidden operation text present"
fi
if grep -En 'cmd.*(writeback|randwrite|randrw)|cmd\+=.*(writeback|randwrite|randrw)' "$RUN" >"$OUT/write-forbidden.txt"; then
  fail "write operation added to runtime command"
fi
grep -Fq -- 'local -a cmd=("$JFS" mount -d --read-only --max-uploads 150 --max-fuse-io 256K)' "$RUN" || fail "mount baseline contract missing"
grep -Fq -- 'cmd+=(--cache-dir "$CACHE_DIR" --cache-size "$TIER_MIB" --free-space-ratio 0.20)' "$RUN" || fail "cache mount contract missing"
grep -Fq -- 'cmd+=(--cache-size 0)' "$RUN" || fail "cache=0 mount contract missing"
grep -Fq -- 'cmd+=(--metrics "$METRICS_ADDR" "$META" "$JFS_MNT")' "$RUN" || fail "metrics mount contract missing"
grep -Fq 'rw=randread' "$RUN" || fail "randread contract missing"
grep -Fq 'rw=read' "$RUN" || fail "mseqread contract missing"
grep -Fq 'size=4G' "$RUN" || fail "mseqread 4GiB job size missing"
grep -Fq 'size=1G' "$RUN" || fail "randread 1GiB job size missing"
grep -Fq 'for i in $(seq 0 15)' "$RUN" || fail "16 explicit mseqread jobs missing"
grep -Fq 'for i in $(seq 0 127)' "$RUN" || fail "128 explicit jobs missing"
grep -Fq 'mseqread-C75' "$RUN" || fail "mseqread C75 missing"
grep -Fq 'randread-C75' "$RUN" || fail "randread C75 missing"
grep -Fq 'mseqread-A0-pre mseqread-C25 mseqread-C50 mseqread-C75 mseqread-C100 mseqread-C200 mseqread-A0-post randread-A0-pre randread-C25 randread-C50 randread-C75 randread-C100 randread-C200 randread-A0-post' "$RUN" || fail "14-cell matrix missing"
grep -Fq 'CEPH_CONF_MD5=86351c58848c7e4caaa1bbeccb211730' "$RUN" || fail "frozen msgr8 conf identity missing"
grep -Fq 'ms_async_op_threads = 8' "$RUN" || fail "msgr8 injection missing"
grep -Fq 'expected 8 msgr-worker threads' "$RUN" || fail "runtime msgr thread gate missing"
grep -Fq 'if ! python3 - "$JFS" "$CELL_ROOT/mount-pids-pre.txt"' "$RUN" || fail "mount process gate must propagate Python failure"
[[ $(grep -Fc 'CEPH_CONF="$CEPH_CONF" ceph -s --format json' "$RUN") -eq 2 ]] || fail "private conf is not used by both Ceph health checks"
grep -Fq 'openfiles=128' "$RUN" || fail "randread openfiles contract missing"
grep -Fq '10.3.1.6' "$RUN" || fail "Ceph route target missing"
grep -Fq 'juicefs_blockcache_hit_bytes' "$RUN" || fail "hit metric missing"
grep -Fq 'juicefs_blockcache_miss_bytes' "$RUN" || fail "miss metric missing"
grep -Fq 'juicefs_blockcache_evicts' "$RUN" || fail "eviction metric missing"
grep -Fq 'juicefs_blockcache_drops' "$RUN" || fail "drop metric missing"
grep -Fq 'cache directory not empty' "$RUN" || fail "empty-cache gate missing"
grep -Fq 'asset identity drift' "$RUN" || fail "asset gate missing"
grep -Fq 'script drift' "$RUN" || fail "script freeze gate missing"
! grep -Fq 'verify-paused' "$RUN" || fail "read-only L1 must not require a scrub pause"
grep -Fq "d.get('health',{}).get('status') != 'HEALTH_OK'" "$RUN" || fail "Ceph HEALTH_OK gate missing"
grep -Fq 'result[second] = sum(' "$ANALYZE" || fail "per-job bandwidth must be summed"
grep -Fq 'mount-pids-pre.txt' "$RUN" || fail "launch-scoped PID snapshot missing"
grep -Fq 'metrics mount label mismatch' "$RUN" || fail "metrics mount identity gate missing"
grep -Fq "actual_start == row['starttime']" "$RUN" || fail "PID/starttime exit gate missing"
grep -Fq 'JuiceFS process remains' "$RUN" || fail "process exit gate missing"
grep -Fq "for forbidden in ('--writeback', '--prefetch', '--max-readahead')" "$RUN" || fail "default prefetch/readahead guard missing"
! grep -Fq 'formal_drops_delta"] == 0' "$ANALYZE" || fail "drops must be an endpoint, not evidence hard gate"

"$RUN" offline-self-test "$RUN_ID" NONE >"$OUT/runner-self-test.txt"
grep -Fq '04TMP2D_OFFLINE_SELF_TEST_PASS cells=14 mseqread_workset_gib=64 randread_workset_gib=128' "$OUT/runner-self-test.txt" || fail "runner fixture mismatch"
python3 "$ANALYZE" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" >"$OUT/analyzer-self-test.stdout"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail "analyzer self-test failed"

sha256sum "$RUN" "$ANALYZE" "$GATE" >"$OUT/scripts.sha256"
printf 'RUN_ID\t%s\nGATE_STATUS\tPASS\n' "$RUN_ID" >"$OUT/summary.tsv"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$OUT/SHA256SUMS"
printf '04TMP2D_GATE0_OFFLINE_PASS root=%s\n' "$OUT"
