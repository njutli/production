#!/usr/bin/env bash
set -euo pipefail

# No SSH, Ceph calls, mount, or fio. Exercise only the new six-cell plan and
# the frozen 05-3b analyzer/worker identity fixtures.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner="$here/t05-3c-randwrite-screen.sh"
analyzer="$here/t05-3b-randrw-analyze.py"
old_analyzer="$here/t05-3-randrw-analyze.py"
worker_guard="$here/t05-baseline-guard.py"
scrub_helper="$here/u141d-scrub-control.sh"

bash -n "$runner" "$scrub_helper"
[[ $(sha256sum "$analyzer" | awk '{print $1}') == ccd0f0081657da74ad91b67b2094294783929d9a36317effd10018020acec953 ]] || exit 42
[[ $(sha256sum "$old_analyzer" | awk '{print $1}') == 77f98a6e102260f196ddf9c67ccc4fa09bf0bbf6d1f78d6c2202cf7110925e0a ]] || exit 42
[[ $(sha256sum "$worker_guard" | awk '{print $1}') == b5c1fcae6fb08f517b9cde30aa8373bfd1142ae3494e436482c36d8e16c71816 ]] || exit 42
python3 "$analyzer" self-test
python3 "$worker_guard" self-test >/dev/null

if grep -Eq 'maintenance_assets|drift_gate|READ_CELLS|WRITE_X|drop_caches|reboot|shutdown|wipefs|mkfs|rm -rf' "$runner"; then
    echo 'GATE0_FAIL: forbidden old path or destructive command in runner' >&2
    exit 42
fi
grep -Fq 'avail >= 20*1024*1024' "$runner" || { echo 'GATE0_FAIL: 20 GiB shared-system-disk floor missing' >&2; exit 42; }
grep -Fq 'printf '\''%s\t%s\n'\'' "$(date -Is)" "$avail" >>"$EVIDENCE/disk-free-kib.tsv"' "$runner" || { echo 'GATE0_FAIL: disk-free audit missing' >&2; exit 42; }
grep -Fq 'if ! ( log_space_gate ) || ! ( health_gate' "$runner" || { echo 'GATE0_FAIL: disk-free guard not first in active sampler' >&2; exit 42; }
grep -Fq '"/tmp/production/05-3c-${RUN_ID}"' "$runner" || { echo 'GATE0_FAIL: evidence path scope missing' >&2; exit 42; }
grep -Fq 'floor=max(stop_free, observed-growth)' "$runner" || { echo 'GATE0_FAIL: DB growth budget stop missing' >&2; exit 42; }

tmp=$(mktemp -d /tmp/t05-3c-gate-XXXXXXXX)
cleanup() {
    [[ "$tmp" == /tmp/t05-3c-gate-* && -d "$tmp" && ! -L "$tmp" ]] || return 1
    rm -r --one-file-system -- "$tmp"
}
trap cleanup EXIT
run_id=20260924-000000
T053C_OFFLINE_GATE=1 T053C_EVIDENCE_ROOT="$tmp/evidence" bash "$runner" plan "$run_id" >"$tmp/plan.out"
space_fn=$(sed -n '/^log_space_gate() {/,/^}/p' "$runner")
[[ "$space_fn" == *'avail >= 20*1024*1024'* ]] || { echo 'GATE0_FAIL: cannot extract space gate' >&2; exit 42; }
for free_kib in 20971520 20971519; do
    if SPACE_FIXTURE_KIB="$free_kib" EVIDENCE="$tmp/evidence" bash -c '
        set -euo pipefail
        df() { printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/mock 1 1 %s 1%% /tmp\n" "$SPACE_FIXTURE_KIB"; }
        die() { exit 42; }
        source /dev/fd/3
        log_space_gate
    ' 3<<<"$space_fn"; then
        [[ "$free_kib" == 20971520 ]] || { echo 'GATE0_FAIL: below-floor space accepted' >&2; exit 42; }
    else
        [[ "$free_kib" == 20971519 ]] || { echo 'GATE0_FAIL: at-floor space rejected' >&2; exit 42; }
    fi
done
if T053C_OFFLINE_GATE=1 T053C_EVIDENCE_ROOT="$tmp/out-of-scope" bash "$runner" plan "$run_id" >"$tmp/scope.out" 2>&1; then
    echo 'GATE0_FAIL: out-of-scope evidence path accepted' >&2
    exit 42
fi
grep -Fq unsafe_root "$tmp/scope.out" || { echo 'GATE0_FAIL: path-negative failed for another reason' >&2; exit 42; }
matrix="$tmp/evidence/matrix.tsv"
commands="$tmp/evidence/commands-plan.sh"
[[ $(wc -l < "$matrix") -eq 7 ]] || { echo 'GATE0_FAIL: not six cells' >&2; exit 42; }
actual=$(awk -F '\t' 'NR>1 {print $2 ":" $3}' "$matrix" | paste -sd , -)
[[ "$actual" == '256K-before:256K,16K-screen:16K,64K-screen:64K,1M-screen:1M,4M-screen:4M,256K-after:256K' ]] || { echo 'GATE0_FAIL: order/BS mismatch' >&2; exit 42; }
[[ $(grep -c -- '--rw=randwrite' "$commands") -eq 6 ]] || { echo 'GATE0_FAIL: fio count' >&2; exit 42; }
[[ $(grep -c -- '--output-format=json+' "$commands") -eq 6 ]] || { echo 'GATE0_FAIL: JSON capture' >&2; exit 42; }
[[ $(grep -c -- '--per_job_logs=1' "$commands") -eq 6 ]] || { echo 'GATE0_FAIL: per-job logs' >&2; exit 42; }
[[ $(grep -c -- '--direct=1' "$commands") -eq 6 ]] || { echo 'GATE0_FAIL: direct IO contract' >&2; exit 42; }
! grep -Eq -- '--rw=randread|--bs=4K|compact|drop_caches|rm -r' "$commands" || { echo 'GATE0_FAIL: forbidden command' >&2; exit 42; }
if T053C_OFFLINE_GATE=1 T053C_EVIDENCE_ROOT="$tmp/evidence" bash "$runner" write-phase "$run_id" INVALID I_ACK_GLOBAL_CEPH_SCRUB_PAUSE >"$tmp/negative.out" 2>&1; then
    echo 'GATE0_FAIL: incorrect execution acknowledgement accepted' >&2
    exit 42
fi
grep -Fq ack_missing "$tmp/negative.out" || { echo 'GATE0_FAIL: negative test failed for another reason' >&2; exit 42; }

printf 'T053C_GATE0_PASS cells=6 order=%s\n' "$actual"
printf 'SCRUB_HELPER_SUDO_WRITES_REQUIRE_SEPARATE_APPROVAL\n'
