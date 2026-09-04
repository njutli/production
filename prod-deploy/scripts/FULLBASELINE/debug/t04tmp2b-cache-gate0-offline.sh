#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN="$DIR/t04tmp2b-cache-run.sh"
ANALYZE="$DIR/t04tmp2b-cache-analyze.py"
SCRUB="$DIR/u141d-scrub-control.sh"
GATE="$DIR/t04tmp2b-cache-gate0-offline.sh"
RUN_ID=20260903-000000
OUT=${TMP2B_GATE_OUT:-/tmp/t04tmp2b-gate0-$RUN_ID}

fail() { printf '04TMP2B_GATE_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ ! -e $OUT && $OUT == /tmp/t04tmp2b-gate0-* ]] || fail "unsafe/existing output"
mkdir -m 0700 "$OUT"
for f in "$RUN" "$ANALYZE" "$SCRUB" "$GATE"; do [[ -f $f && ! -L $f ]] || fail "missing/symlink $f"; done

bash -n "$RUN"; bash -u -n "$RUN"; bash -n "$GATE"; bash -n "$SCRUB"
PYTHONPYCACHEPREFIX="$OUT/pycache" python3 -m py_compile "$ANALYZE"
if command -v shellcheck >/dev/null; then shellcheck "$RUN" "$GATE" >"$OUT/shellcheck.txt"; else printf 'SKIPPED\n' >"$OUT/shellcheck.txt"; fi

if grep -EnH 'rm[[:space:]]+-r|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+-(l|f)|fusermount[[:space:]]+-u[zf]|losetup[[:space:]]+-D|drop_caches|reboot|shutdown|poweroff|halt|systemctl' \
  "$RUN" "$ANALYZE" >"$OUT/forbidden.txt"; then fail "forbidden command present"; fi
if awk '/^cmd_plan\(\)/{exit} {print}' "$RUN" | grep -En 'sudo[[:space:]]+(rm|chmod|install|rmdir|dd|wipefs|mount[[:space:]]+/dev/(nvme|sd|md)|mkfs[^[:space:]]*[[:space:]]+/dev/(nvme|sd|md))' \
  >"$OUT/unapproved-sudo.txt"; then fail "unapproved executable sudo present"; fi
awk '/^cmd_plan\(\)/{exit} {print}' "$RUN" | grep -En 'sudo (losetup --find --show --nooverlap|mkfs.ext4|mount -o noatime,nodiscard|chown|umount|losetup -d)' >"$OUT/sudo-approved-subset.txt"
[[ $(wc -l <"$OUT/sudo-approved-subset.txt") -eq 12 ]] || fail "sudo subset/log count differs"
! grep -EnH '(Sunrise@|sshpass|SSHPASS=|password=)' "$RUN" "$ANALYZE" >"$OUT/secrets.txt" || fail "possible secret"

grep -Fq 'FIXED_RUN=20260903-000000' "$RUN" || fail "fixed RUN missing"
grep -Fq 'ROOT=/tmp/production/opencode-04tmp2b-$RUN_ID' "$RUN" || fail "fixed root missing"
grep -Fq 'BACKING_ROOT=$CACHE_PARENT/jfs-04tmp2b-$RUN_ID' "$RUN" || fail "fixed backing root missing"
grep -Fq 'META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod' "$RUN" || fail "fixed META missing"
grep -Fq 'METRICS_ADDR=127.0.0.1:9568' "$RUN" || fail "fixed metrics endpoint missing"
grep -Fq 'EXPECTED_UID=1002' "$RUN" || fail "UID gate missing"
grep -Fq -- '--writeback --metrics' "$RUN" || fail "writeback/metrics contract missing"
grep -Fq -- '--cache-size "$TIER_MIB" --free-space-ratio 0.20' "$RUN" || fail "capacity contract missing"
grep -Fq 'mseqread randread randwrite randrw' "$RUN" || fail "four item matrix missing"
grep -Fq 'for tier in 16 64 32' "$RUN" || fail "tier order missing"
grep -Fq 'staging did not drain within 900s' "$RUN" || fail "drain hard stop missing"
grep -Fq 'refuse cleanup while JuiceFS is mounted' "$RUN" || fail "cleanup mount guard missing"
grep -Fq 'loop backing mismatch' "$RUN" || fail "loop identity guard missing"
grep -Fq 'sysfs backing record fixture failed' "$RUN" || fail "sysfs backing fixture missing"
grep -Fq 'metrics mount identity mismatch' "$RUN" || fail "metrics mount identity gate missing"
grep -Fq 'UNAVAILABLE_NONBLOCKING' "$RUN" || fail "mounted UUID retry/record path missing"
grep -Fq 'JuiceFS process remains 60s after umount' "$RUN" || fail "daemon-exit wait missing"
grep -Fq 'recover refuses failed performance evidence' "$RUN" || fail "post-fio recovery evidence gate missing"
grep -Fq 'asset identity drift; preserve cell' "$RUN" || fail "asset gate missing"
grep -Fq 'script drift' "$RUN" || fail "script freeze gate missing"
grep -Fq 'verify-paused "$lease"' "$RUN" || fail "scrub runtime gate missing"
grep -Fq 'timeout "$((runtime + 60))"' "$RUN" || fail "fio timeout missing"
grep -Fq 'runtime sampler contains unavailable fields' "$RUN" || fail "sampler availability gate missing"
grep -Fq 'cache parent has foreign entries' "$RUN" || fail "foreign cache-parent gate missing"
grep -Fq 'RUN backing root missing or identity/mode mismatch' "$RUN" || fail "backing-root identity gate missing"
grep -Fq 'sudo install -d -m 0700 -o 1002 -g 1002 /mnt/jfs-cache/jfs-04tmp2b-20260903-000000' "$RUN" || fail "backing-root sudo plan missing"
grep -Fq 'sudo rmdir /mnt/jfs-cache/jfs-04tmp2b-20260903-000000' "$RUN" || fail "backing-root cleanup plan missing"
! grep -q -- '--upload-delay' "$RUN" || fail "upload-delay forbidden"
[[ $(grep -Ec '^[[:space:]]*sudo ceph ' "$SCRUB") -eq 1 ]] || fail "scrub controller sudo surface changed"

TMP2B_RESULT_ROOT="/tmp/production/opencode-04tmp2b-$RUN_ID" bash "$RUN" offline-self-test "$RUN_ID" >"$OUT/runner-self-test.txt"
python3 "$ANALYZE" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" >"$OUT/analyzer-self-test.stdout"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail "analyzer self-test"
bash "$SCRUB" --self-test >"$OUT/scrub-self-test.txt"
grep -Fq 'U141D_SCRUB_CONTROL_SELFTEST: PASS' "$OUT/scrub-self-test.txt" || fail "scrub self-test"

sha256sum "$RUN" "$ANALYZE" "$GATE" "$SCRUB" >"$OUT/scripts.sha256"
printf 'RUN_ID\t%s\nGATE_STATUS\tPASS\n' "$RUN_ID" >"$OUT/summary.tsv"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$OUT/SHA256SUMS"
printf '04TMP2B_GATE0_OFFLINE_PASS root=%s\n' "$OUT"
