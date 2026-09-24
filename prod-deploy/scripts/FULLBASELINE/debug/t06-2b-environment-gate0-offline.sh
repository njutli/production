#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

RUN_ID=${1:-20260921-125717}
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo invalid_run >&2; exit 42; }
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRIVER=$HERE/t06-2b-range-flush-driver.sh
SMOKE=$HERE/t06-2b-environment-smoke.sh
ANALYZER=$HERE/t06-2b-range-flush-analyze.py
SCRUB=$HERE/u141d-scrub-control.sh
LEGACY=$HERE/t06-1-randrw-cache-driver.sh

for file in "$DRIVER" "$SMOKE" "$ANALYZER" "$SCRUB" "$LEGACY"; do
  [[ -f $file && ! -L $file ]] || { echo missing_or_symlink:$file >&2; exit 42; }
done
bash -n "$DRIVER" "$SMOKE" "$SCRUB" "$LEGACY"
python3 -m py_compile "$ANALYZER"
bash "$DRIVER" --self-test "$RUN_ID"
bash "$SMOKE" --self-test
python3 "$ANALYZER" --self-test

plan=$(mktemp -d /tmp/t062b-plan.XXXXXX)
rmdir "$plan"
T062B_PLAN_OUT=$plan bash "$DRIVER" plan "$RUN_ID"
[[ $(awk -F '\t' 'NR>1{print $2}' "$plan/gate0/mainline-matrix.tsv" | paste -sd, -) == H0,C1,T1,T2,C2,H1 ]]
awk -F '\t' 'NR==1{next} NF!=6||$4!=98304||$5!=0||$6!=1{exit 1} END{exit NR==7?0:1}' "$plan/gate0/mainline-matrix.tsv"

grep -Fq 'H_JFS=/tmp/juicefs-1.4.1-patched' "$DRIVER"
grep -Fq '24fae0852051c80ca571cb2f20275d46' "$DRIVER"
grep -Fq 'b713e595a0fd320217913617098e91107de065285860498079e1777a61b2bbbc' "$DRIVER"
grep -Fq '4ffd69637d43a1c33725f540124e7569957cf1c6541cea7fc49b0fa3bf38a4b2' "$DRIVER"
grep -Fq 'io_bytes' "$ANALYZER"
grep -Fq 'runtime' "$ANALYZER"

for file in "$DRIVER" "$SMOKE"; do
  ! grep -nE 'reboot|shutdown|halt|poweroff|systemctl[[:space:]]+(stop|restart|reboot|poweroff)|juicefs[[:space:]]+gc|drop_caches|ceph[[:space:]].*compact|rm[[:space:]]+-rf|umount[[:space:]]+-l|fusermount[[:space:]]+-u[z]|pkill|killall|fuser[[:space:]]+-k|chown[[:space:]]+-R|chmod[[:space:]]+-R' "$file"
done
grep -Fq 'find -P "$dir" -xdev -depth -mindepth 1 -delete' "$DRIVER"
grep -Fq 'DRAIN_PASS' "$DRIVER"
grep -Fq 'READBACK_PASS' "$DRIVER"
grep -Fq 'UNMOUNTED_formal' "$DRIVER"
grep -Fq 'UNMOUNTED_verify' "$DRIVER"

printf 'T062B_ENVIRONMENT_GATE0_PASS\trun_id=%s\n' "$RUN_ID"
sha256sum "$DRIVER" "$SMOKE" "$ANALYZER" "$SCRUB" "$LEGACY"
