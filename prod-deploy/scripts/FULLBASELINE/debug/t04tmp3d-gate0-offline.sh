#!/usr/bin/env bash
# Offline-only Gate 0 for 04-tmp3d.  It never invokes a cluster client.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXEC="$DIR/t04tmp3d-executor.sh"
ANALYZER="$DIR/t04tmp3d-analyze.py"
OUT=${T04TMP3D_GATE0_OUT:-/mnt/c/SunRise/test/04-tmp3d/gate0-$(date +%Y%m%d-%H%M%S)}
mkdir -m 0700 -p "$OUT"
FAIL=0
pass(){ printf '[PASS]\t%s\n' "$*"; }
fail(){ printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

for f in "$EXEC" "$ANALYZER" "$0"; do check "present $(basename "$f")" test -s "$f"; done
check executor-bash-n bash -n "$EXEC"
check executor-bash-u-n bash -u -n "$EXEC"
check gate-bash-n bash -n "$0"
check analyzer-compile python3 -m py_compile "$ANALYZER"
check executor-self-test "$EXEC" --self-test
check analyzer-self-test python3 "$ANALYZER" self-test

for id in D01 D02 D03 D06 D09 D12 D16 D17 D18 D21 D22 D25 D26 D27 D28 D31; do
  check "defect-marker-$id" grep -R -Fq "DEFECT-$id" "$EXEC" "$ANALYZER"
done
if grep -nEi 'sshpass|PASSWORD=|(^|[[:space:];])sudo[[:space:]]|rm[[:space:]]+-rf|fusermount[[:space:]]+-u[[:space:]]*[zf]|umount[[:space:]]+-(l|f)|losetup[[:space:]]+-D|pkill|killall|fuser[[:space:]]+-k|reboot|shutdown|systemctl|ceph[[:space:]]+osd[[:space:]]+(set|unset|pool[[:space:]]+(delete|create))|rados[[:space:]]+(cppool|rmpool|purge)' "$EXEC" >"$OUT/forbidden.txt"; then
  fail forbidden-command-or-secret-surface
else
  pass forbidden-command-or-secret-surface
fi
check fixed-pool grep -Fq 'POOL=juicefs-data' "$EXEC"
check fixed-client grep -Fq 'RADOS_USER=client.juicefs' "$EXEC"
check fixed-namespace grep -Fq 'NAMESPACE="04tmp3d-$RUN_ID"' "$EXEC"
check matrix-size-256 grep -Fq 'SIZE_BYTES_b256=262144' "$EXEC"
check matrix-size-4m grep -Fq 'SIZE_BYTES_b4=4194304' "$EXEC"
check matrix-qds grep -Fq 'QDS=(1 2 4 8 16 32 1)' "$EXEC"
check namespace-option grep -Fq -- '-N "$NAMESPACE"' "$EXEC"
check exact-cleanup grep -Fq -- 'cleanup --run-name "$run"' "$EXEC"
check namespace-list-helper grep -Fq 'ns_ls() { rados_cmd 30 -p "$POOL" -N "$NAMESPACE" ls; }' "$EXEC"
check analyzer-stable-window grep -Fq 'stable_seconds' "$ANALYZER"
check analyzer-summary-旁证 grep -Fq 'summary_minus_stable_pct' "$ANALYZER"
check actual-raw-output grep -Fq 'stable_values_MiBs' "$ANALYZER"
check rados-unit-contract grep -Fq 'bytes / 2^20 / s' "$ANALYZER"
check exact-seed-contract grep -Fq 'seed_contract_failed_' "$EXEC"
sha256sum "$EXEC" "$ANALYZER" "$0" >"$OUT/input-sha256.tsv"
printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL )); then printf 'T04TMP3D_GATE0_FAIL\tout=%s\n' "$OUT"; exit 42; fi
printf 'T04TMP3D_GATE0_PASS\tout=%s\tremote_calls=0\tprivileged_calls=0\n' "$OUT"
