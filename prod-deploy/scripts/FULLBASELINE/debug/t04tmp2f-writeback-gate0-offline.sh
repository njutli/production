#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN=$DIR/t04tmp2f-writeback-run.sh
ANALYZER=$DIR/t04tmp2f-writeback-analyze.py
RECOVERY=$DIR/t04tmp2f-writeback-recovery.sh
GATE=$DIR/t04tmp2f-writeback-gate0-offline.sh
SCRUB=$DIR/u141d-scrub-control.sh
RUN_ID=${TMP2F_GATE_RUN_ID:-20260903-235959}
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { printf '04TMP2F_GATE0_FAIL\tinvalid RUN_ID: %s\n' "$RUN_ID" >&2; exit 42; }
OUT=${TMP2F_GATE_OUT:-/tmp/t04tmp2f-gate0-$RUN_ID}

fail() { printf '04TMP2F_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $OUT == /tmp/t04tmp2f-gate0-* && ! -e $OUT ]] || fail "unsafe or existing output: $OUT"
mkdir -m 0700 "$OUT"
for file in "$RUN" "$ANALYZER" "$RECOVERY" "$GATE" "$SCRUB"; do
  [[ -f $file && ! -L $file ]] || fail "missing or symlink script: $file"
done

bash -n "$RUN"
bash -u -n "$RUN"
bash -n "$GATE"
bash -n "$RECOVERY"
bash -u -n "$RECOVERY"
PYTHONPYCACHEPREFIX=$OUT/pycache python3 -m py_compile "$ANALYZER"

if grep -EnH 'rm[[:space:]]+-r|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|drop_caches|reboot|shutdown|poweroff|halt|systemctl|/dev/(nvme|sd|md)[[:alnum:]]*' \
    "$RUN" "$ANALYZER" "$RECOVERY" "$SCRUB" >"$OUT/forbidden.txt"; then
  fail "forbidden command or raw device target present"
fi
! grep -EnH '(sshpass|SSHPASS=|password=|Sunrise@)' "$RUN" "$ANALYZER" "$RECOVERY" "$SCRUB" >"$OUT/secrets.txt" || fail "possible secret"

for cell in W20-randwrite W32-randwrite W64-randwrite W96-randwrite W128-randwrite; do
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
grep -Fq 'BACKING_GIB=20' "$RUN" || fail "20 GiB backing missing"
grep -Fq 'BACKING_GIB=128' "$RUN" || fail "128 GiB backing missing"
grep -Fq 'sudo install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" "$BACKING_ROOT"' "$RUN" || fail "scoped backing-root creation missing"
grep -Fq 'mkfs.ext4 -F -m 0 -E nodiscard' "$RUN" || fail "normal ext4 contract missing"
! grep -Eq 'mkfs\.ext4[^\n]*-T[[:space:]]+largefile' "$RUN" || fail "largefile inode profile forbidden"
grep -Fq "printf 'TIMEOUT" "$RUN" || fail "drain timeout classification missing"
grep -Fq 'return 3' "$RUN" || fail "drain timeout must be a classifiable cell result"
grep -Fq 'rawstaging_snapshot' "$RUN" || fail "pre-recovery rawstaging snapshot missing"
grep -Fq 'find "$CACHE_DIR" -ignore_readdir_race' "$RUN" || fail "concurrent rawstaging scan tolerance missing"
grep -Fq 'statvfs_available' "$RUN" || fail "statvfs available sampler missing"
grep -Fq 'available_bytes' "$RUN" || fail "available-bytes evidence missing"
grep -Fq 'OBSERVED_SAFE_POINT' "$RUN" || fail "safe-point verdict missing"
grep -Fq 'LIFECYCLE_PASS_TIGHT' "$RUN" || fail "tight-pass verdict missing"
grep -Fq 'LIFECYCLE_FAIL' "$RUN" || fail "lifecycle-fail verdict missing"
grep -Fq 'conditional W96 required but missing' "$ANALYZER" || fail "conditional W96 analyzer contract missing"
grep -Fq 'matrix_guard' "$RUN" || fail "matrix-order state guard missing"
grep -Fq 'matrix_expected_W20' "$RUN" || fail "matrix must begin at W20"
grep -Fq 'matrix_expected_W128' "$RUN" || fail "core matrix must end at W128"
grep -Fq 'matrix_complete_or_W96_not_required' "$RUN" || fail "conditional W96 execution guard missing"
grep -Fq 'previous_cell_recovery_missing' "$RUN" || fail "inter-cell recovery guard missing"
grep -Fq 'NEXT_REQUIRED_RECOVERY:' "$RUN" || fail "post-cell recovery instruction missing"
grep -Fq 'recovery/after-<CELL>/PASS' "$RUN" || fail "generated plan lacks inter-cell recovery PASS contract"
grep -Fq 'drain-status.txt' "$ANALYZER" || fail "analyzer drain-status binding missing"
grep -Fq 'last two drain samples are not strict zero' "$ANALYZER" || fail "strict-zero analyzer gate missing"
grep -Fq 'rawstaging snapshot disagrees' "$ANALYZER" || fail "rawstaging/drain cross-check missing"
grep -Fq 'rawstaging-after-formal-umount.tsv' "$RUN" || fail "stable timeout snapshot missing"
grep -Fq 'stable post-unmount residual is not a snapshot subset' "$ANALYZER" || fail "stable timeout subset analyzer contract missing"
grep -Fq 'invalid_resume_drain_status' "$RUN" || fail "resume path lacks strict-zero/timeout split"
grep -Fq 'allow_file_create=0' "$RUN" || fail "existing-file contract missing"
grep -Fq 'create_on_open=0' "$RUN" || fail "fresh-file distortion guard missing"
grep -Fq 'for i in $(seq 0 127)' "$RUN" || fail "explicit 128-file job generation missing"
grep -Fq '10.3.1.6' "$RUN" || fail "Ceph data NIC route missing"
grep -Fq 'I_ACK_04TMP2F_' "$RUN" || fail "execution ACK missing"
grep -Fq 'JFS_GC_SKIPPEDTIME=0' "$RECOVERY" || fail "write-object GC recovery missing"
grep -Fq 'OBJECT_TOLERANCE=8192' "$RECOVERY" || fail "object-return tolerance missing"
grep -Fq 'I_ACK_04TMP2F_RECOVERY_' "$RECOVERY" || fail "recovery ACK missing"
grep -Fq 'osd-$osd-latest.json' "$RECOVERY" || fail "bounded compact evidence contract missing"
grep -Fq 'tikv_idle_gate' "$RECOVERY" || fail "TiKV cooldown gate missing"
grep -Fq 'compact_schema_unavailable_osd_' "$RECOVERY" || fail "OSD schema fail-closed probe missing"
grep -Fq 'CEPH_KEYRING=/etc/ceph/ceph.client.admin.keyring' "$RECOVERY" || fail "explicit Ceph keyring missing"
! grep -q 'drop_caches' "$RECOVERY" || fail "drop_caches forbidden"
grep -Fq 'OWNED_FLAGS=(noscrub nodeep-scrub)' "$SCRUB" || fail "scrub ownership contract missing"
grep -Fq 'U141D_SCRUB_STATE_DIR="$ROOT"' "$RUN" || fail "runner scrub state not scoped to RUN"
grep -Fq 'U141D_CEPH_CONF="$CEPH_CONF"' "$RUN" || fail "runner scrub helper not bound to private Ceph config"
grep -Fq 'U141D_CEPH_CONF="$CEPH_CONF"' "$RECOVERY" || fail "recovery scrub helper not bound to private Ceph config"
grep -Fq 'CEPH_CONF_ARGS=(-c "$U141D_CEPH_CONF")' "$SCRUB" || fail "scrub helper lacks explicit config binding"
grep -Fq 'CEPH_AUTH_ARGS=(--keyring /etc/ceph/ceph.client.admin.keyring -n client.admin)' "$SCRUB" || fail "scrub helper lacks explicit keyring binding"
grep -Fq 'verify-paused "$LEASE"' "$RUN" || fail "runner health not bound to scrub lease"
grep -Fq 'verify-paused "$LEASE"' "$RECOVERY" || fail "recovery health not bound to scrub lease"
grep -Fq 'bash $SCRUB pause $LEASE' "$RUN" || fail "pause helper absent from plan"
grep -Fq 'bash $SCRUB restore $LEASE' "$RUN" || fail "restore helper absent from plan"
grep -Fq 'cmd_pause_scrub' "$RUN" || fail "pause executor action missing"
grep -Fq 'cmd_restore_scrub' "$RUN" || fail "restore executor action missing"
grep -Fq 'verify-restored "$LEASE"' "$RUN" || fail "restore verification missing"

# The executable sudo surface must remain the exact loop/ext4 lifecycle subset.
grep -En 'sudo[[:space:]]+' "$RUN" >"$OUT/sudo-surface.txt" || fail "expected sudo lifecycle surface missing"
grep -En 'sudo[[:space:]]+' "$RECOVERY" >>"$OUT/sudo-surface.txt" || fail "expected recovery sudo surface missing"
grep -En 'sudo[[:space:]]+' "$SCRUB" >>"$OUT/sudo-surface.txt" || fail "expected scrub sudo surface missing"
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|chmod|dd|wipefs|systemctl|reboot|shutdown|mount[[:space:]]+/dev/(nvme|sd|md)|mkfs[^[:space:]]*[[:space:]]+/dev/(nvme|sd|md))' "$RUN" >"$OUT/unsafe-sudo.txt"; then
  fail "unsafe sudo surface"
fi
if grep -En 'sudo[[:space:]]+(rm[[:space:]]|rmdir|chmod|chown|mount|umount|losetup|mkfs|dd|wipefs|systemctl|reboot|shutdown)' "$RECOVERY" >"$OUT/unsafe-recovery-sudo.txt"; then
  fail "recovery contains storage/destructive sudo"
fi

bash "$RUN" offline-self-test "$RUN_ID" >"$OUT/runner-self-test.txt"
bash "$RECOVERY" offline-self-test >"$OUT/recovery-self-test.txt"
env U141D_SCRUB_STATE_DIR="$OUT/scrub-state" bash "$SCRUB" --self-test >"$OUT/scrub-self-test.txt"
python3 "$ANALYZER" self-test --root "$OUT/analyzer-fixture" --output "$OUT/analyzer-self-test.json" \
  >"$OUT/analyzer-self-test.stdout"
grep -Fq '"status": "PASS"' "$OUT/analyzer-self-test.json" || fail "analyzer self-test failed"

sha256sum "$RUN" "$ANALYZER" "$RECOVERY" "$GATE" "$SCRUB" >"$OUT/scripts.sha256"
printf 'RUN_ID\t%s\nGATE_STATUS\tPASS\n' "$RUN_ID" >"$OUT/summary.tsv"
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) >"$OUT/SHA256SUMS"
printf '04TMP2F_GATE0_OFFLINE_PASS root=%s\n' "$OUT"
