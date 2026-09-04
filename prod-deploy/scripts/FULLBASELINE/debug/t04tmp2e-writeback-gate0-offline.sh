#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN=$DIR/t04tmp2e-writeback-run.sh
ANALYZER=$DIR/t04tmp2e-writeback-analyze.py
RECOVERY=$DIR/t04tmp2e-writeback-recovery.sh
GATE=$DIR/t04tmp2e-writeback-gate0-offline.sh
RUN_ID=20260903-235959
OUT=${TMP2E_GATE_OUT:-/tmp/t04tmp2e-gate0-$RUN_ID}

fail() { printf '04TMP2E_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $OUT == /tmp/t04tmp2e-gate0-* && ! -e $OUT ]] || fail "unsafe or existing output: $OUT"
mkdir -m 0700 "$OUT"
for file in "$RUN" "$ANALYZER" "$RECOVERY" "$GATE"; do
  [[ -f $file && ! -L $file ]] || fail "missing or symlink script: $file"
done

bash -n "$RUN"
bash -u -n "$RUN"
bash -n "$GATE"
bash -n "$RECOVERY"
bash -u -n "$RECOVERY"
PYTHONPYCACHEPREFIX=$OUT/pycache python3 -m py_compile "$ANALYZER"

if grep -EnH 'rm[[:space:]]+-r|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|drop_caches|reboot|shutdown|poweroff|halt|systemctl|/dev/(nvme|sd|md)[[:alnum:]]*' \
    "$RUN" "$ANALYZER" "$RECOVERY" >"$OUT/forbidden.txt"; then
  fail "forbidden command or raw device target present"
fi
! grep -EnH '(sshpass|SSHPASS=|password=|Sunrise@)' "$RUN" "$ANALYZER" "$RECOVERY" >"$OUT/secrets.txt" || fail "possible secret"

for cell in W16-randwrite W32-randwrite W64-randwrite W96-randwrite W128-randwrite; do
  grep -Fq "$cell" "$RUN" || fail "capacity cell missing: $cell"
done
grep -Fq -- '--cache-size "$TIER_MIB" --free-space-ratio 0.20 --writeback' "$RUN" || fail "writeback mount contract missing"
grep -Fq 'WB=1; TIER_MIB=1;' "$RUN" || fail "writeback enable/minimal-read-cache contract missing"
grep -Fq 'timeout 300 fio' "$RUN" || fail "runtime+120s watchdog contract missing"
grep -Fq -- '--log "$CELL_ROOT/juicefs-$tag.log"' "$RUN" || fail "per-mount log path missing"
! grep -Fq '"$JFS" log' "$RUN" || fail "unsupported JuiceFS log subcommand present"
! grep -Fq 'mount argv mismatch' "$RUN" || fail "rewritten proc argv must not be an identity hard gate"
grep -Fq 'writeback and prefetch will be disabled' "$RUN" || fail "runtime writeback-disable guard missing"
grep -Fq 'metrics_mount_identity' "$RUN" || fail "metrics mount identity gate missing"
grep -Fq 'cmd_resume_postfio' "$RUN" || fail "post-fio evidence repair path missing"
grep -Fq 'resume_staging_not_zero_' "$RUN" || fail "post-fio staging gate missing"
! grep -Eq 'local loop=\$1 name=|local tag=\$1 process_file=' "$RUN" || fail "same-declaration local expansion hazard"
grep -Fq 'fallocate -l "${BACKING_GIB}G"' "$RUN" || fail "dynamic direct backing contract missing"
grep -Fq 'BACKING_GIB=16' "$RUN" || fail "16 GiB backing missing"
grep -Fq 'BACKING_GIB=128' "$RUN" || fail "128 GiB backing missing"
grep -Fq 'sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$BACKING_ROOT"' "$RUN" || fail "scoped backing-root creation missing"
grep -Fq 'mkfs.ext4 -F -m 0 -E nodiscard' "$RUN" || fail "normal ext4 contract missing"
! grep -Eq 'mkfs\.ext4[^\n]*-T[[:space:]]+largefile' "$RUN" || fail "largefile inode profile forbidden"
grep -Fq 'staging did not drain within 900s' "$RUN" || grep -Fq 'drain_timeout' "$RUN" || fail "15 minute drain stop missing"
grep -Fq 'allow_file_create=0' "$RUN" || fail "existing-file contract missing"
grep -Fq 'create_on_open=0' "$RUN" || fail "fresh-file distortion guard missing"
grep -Fq 'for i in $(seq 0 127)' "$RUN" || fail "explicit 128-file job generation missing"
grep -Fq '10.3.1.6' "$RUN" || fail "Ceph data NIC route missing"
grep -Fq 'I_ACK_04TMP2E_' "$RUN" || fail "execution ACK missing"
grep -Fq 'JFS_GC_SKIPPEDTIME=0' "$RECOVERY" || fail "write-object GC recovery missing"
grep -Fq 'OBJECT_TOLERANCE=8192' "$RECOVERY" || fail "object-return tolerance missing"
grep -Fq 'I_ACK_04TMP2E_RECOVERY_' "$RECOVERY" || fail "recovery ACK missing"
grep -Fq 'osd-$osd-latest.json' "$RECOVERY" || fail "bounded compact evidence contract missing"
grep -Fq 'tikv_idle_gate' "$RECOVERY" || fail "TiKV cooldown gate missing"
grep -Fq 'compact_schema_unavailable_osd_' "$RECOVERY" || fail "OSD schema fail-closed probe missing"
grep -Fq 'CEPH_KEYRING=/etc/ceph/ceph.client.admin.keyring' "$RECOVERY" || fail "explicit Ceph keyring missing"
! grep -q 'drop_caches' "$RECOVERY" || fail "drop_caches forbidden"

# The executable sudo surface must remain the exact loop/ext4 lifecycle subset.
grep -En 'sudo[[:space:]]+' "$RUN" >"$OUT/sudo-surface.txt" || fail "expected sudo lifecycle surface missing"
grep -En 'sudo[[:space:]]+' "$RECOVERY" >>"$OUT/sudo-surface.txt" || fail "expected recovery sudo surface missing"
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|chmod|dd|wipefs|systemctl|reboot|shutdown|mount[[:space:]]+/dev/(nvme|sd|md)|mkfs[^[:space:]]*[[:space:]]+/dev/(nvme|sd|md))' "$RUN" >"$OUT/unsafe-sudo.txt"; then
  fail "unsafe sudo surface"
fi
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|rmdir|chmod|chown|mount|umount|losetup|mkfs|dd|wipefs|systemctl|reboot|shutdown)' "$RECOVERY" >"$OUT/unsafe-recovery-sudo.txt"; then
  fail "recovery contains storage/destructive sudo"
fi

bash "$RUN" offline-self-test "$RUN_ID" >"$OUT/runner-self-test.txt"
bash "$RECOVERY" offline-self-test >"$OUT/recovery-self-test.txt"
python3 "$ANALYZER" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" \
  >"$OUT/analyzer-self-test.stdout"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail "analyzer self-test failed"

sha256sum "$RUN" "$ANALYZER" "$RECOVERY" "$GATE" >"$OUT/scripts.sha256"
printf 'RUN_ID\t%s\nGATE_STATUS\tPASS\n' "$RUN_ID" >"$OUT/summary.tsv"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$OUT/SHA256SUMS"
printf '04TMP2E_GATE0_OFFLINE_PASS root=%s\n' "$OUT"
