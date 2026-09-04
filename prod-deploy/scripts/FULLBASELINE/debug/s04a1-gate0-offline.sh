#!/usr/bin/env bash
# Pure offline Gate 0. It invokes only local shell/Python and fixture files.
set -euo pipefail
export LC_ALL=C
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/s04a1-common.sh"
TMP=/tmp/s04a1-gate0-$$; mkdir "$TMP"
trap 'find "$TMP" -depth -delete 2>/dev/null || true' EXIT
RUN=20260902-120000
expect_fail() { if "$@" >/dev/null 2>&1; then printf 'FAIL\t%s\n' "$*" >&2; exit 1; fi; }
expect_ok() { "$@" >/dev/null; }
scan_tree() {
  local pattern=$1
  if command -v rg >/dev/null 2>&1; then
    rg -n --glob 's04a1-*.sh' "$pattern" "$DIR"
  else
    grep -En --include='s04a1-*.sh' -R "$pattern" "$DIR"
  fi
}
scan_file() {
  local pattern=$1 file=$2
  if command -v rg >/dev/null 2>&1; then rg -n "$pattern" "$file"; else grep -En "$pattern" "$file"; fi
}
count_file() {
  local pattern=$1 file=$2
  if command -v rg >/dev/null 2>&1; then rg -c "$pattern" "$file" || true; else grep -Ec "$pattern" "$file" || true; fi
}

bash -n "$DIR"/s04a1-*.sh
python3 -m py_compile "$DIR/s04a1-analyze.py"
expect_ok python3 "$DIR/s04a1-analyze.py" --self-test
expect_ok s04a1_check_run_id "$RUN"; expect_fail s04a1_check_run_id bad
expect_fail s04a1_check_node 10.20.1.153; expect_fail s04a1_check_arm H
expect_ok s04a1_check_matrix C,L,L,C,L,C,C,L; expect_fail s04a1_check_matrix C,L,L,C
expect_fail s04a1_abs_path relative; expect_fail s04a1_abs_path /tmp/../x
expect_ok bash "$DIR/s04a1-driver.sh" plan "$RUN"
expect_fail bash "$DIR/s04a1-driver.sh" run "$RUN"
expect_ok bash "$DIR/s04a1-h-anchor.sh" plan "$RUN" H0
expect_fail env S04A1_H_EXECUTE=YES bash "$DIR/s04a1-h-anchor.sh" run "$RUN" H0
printf 'C,L,L,C,L,C,C,L\n' > "$TMP/matrix"; expect_ok python3 "$DIR/s04a1-analyze.py" "$TMP/matrix"
printf 'C,L,C,L,C,L,C,L\n' > "$TMP/bad-matrix"; expect_fail python3 "$DIR/s04a1-analyze.py" "$TMP/bad-matrix"

# The online storage runner is exercised only in non-mutating plan mode.
for spec in 'C R01' 'L R02' 'L R03' 'C R04' 'L R05' 'C R06' 'C R07' 'L R08'; do
  read -r arm instance <<< "$spec"
  for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
    bash "$DIR/s04a1-storage.sh" plan "$RUN" "$node" "$arm" "$instance" > "$TMP/storage-${instance}-${node##*.}.plan"
    grep -Fq "RUN_ID=$RUN" "$TMP/storage-${instance}-${node##*.}.plan"
    grep -Fq "NODE=$node" "$TMP/storage-${instance}-${node##*.}.plan"
    grep -Fq "PD_MOUNT: sudo mount -t tmpfs" "$TMP/storage-${instance}-${node##*.}.plan"
  done
done
expect_fail bash "$DIR/s04a1-storage.sh" plan "$RUN" 10.20.1.150 C R02
expect_fail bash "$DIR/s04a1-storage.sh" plan "$RUN" 10.20.1.153 C R01
grep -Fq 'L_FORMAT: sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0' "$TMP/storage-R02-150.plan"
grep -Fq "/mnt/jfs-s04a1-$RUN/R02-150/fs" "$TMP/storage-R02-150.plan"
grep -Fq "/mnt/jfs-s04a1-$RUN/R02-150/pd" "$TMP/storage-R02-150.plan"
grep -Fq "/mnt/jfs-tikv/jfs-s04a1-$RUN-c-R01-150" "$TMP/storage-R01-150.plan"

# Static contract checks: only the dedicated Phase 0 files are inspected.
if scan_tree 'systemctl[[:space:]]+(stop|start|restart)|sudo[[:space:]]+[^|]*[>][[:space:]]|(^|[[:space:]])(fio|mount|losetup|mkfs|ceph[[:space:]]+(osd|config)[[:space:]]+(pool|set))([[:space:]]|$)' | grep -Ev 's04a1-(gate0-offline|inventory|run-arm|storage|prod-lifecycle|prod-mount|h-anchor|lifecycle|cluster|cluster-orchestrator|node-cluster|volume-seed|volume-restore|gc-return|reset-gates|sampler|gen-jobfiles|runtime-common).sh'; then
  printf 'FAIL\tPhase 0 script contains mutation command\n' >&2; exit 1
fi
[[ $(count_file '^  sudo systemctl stop tikv$' "$DIR/s04a1-prod-lifecycle.sh") == 1 ]] || { echo 'FAIL exact TiKV stop count' >&2; exit 1; }
[[ $(count_file '^  sudo systemctl start tikv$' "$DIR/s04a1-prod-lifecycle.sh") == 1 ]] || { echo 'FAIL exact TiKV start count' >&2; exit 1; }
if scan_tree 'rm[[:space:]]+-rf|rm[[:space:]]+-f|losetup[[:space:]]+-D|umount[[:space:]]+-(l|f)|pkill|killall|fuser[[:space:]]+-k|(^|[[:space:]])(reboot|shutdown|poweroff)([[:space:]]|$)|drop_caches|wipefs|blkdiscard|fstrim|chown[[:space:]]+-R|chmod[[:space:]]+-R' | grep -Ev 's04a1-(gate0-offline|reset-gates)\.sh:'; then
  printf 'FAIL\tforbidden destructive command found\n' >&2; exit 1
fi
if scan_tree 'systemctl[[:space:]]+(stop|start|restart)[[:space:]]+(pd|pd-server)|mkfs[^\n]*/dev/(nvme|sd|md)' | grep -Ev 's04a1-gate0-offline\.sh:'; then
  printf 'FAIL\tproduction PD or raw-device operation found\n' >&2; exit 1
fi
scan_file 'sudo -n ceph health' "$DIR/s04a1-inventory.sh" >/dev/null || { echo 'FAIL read-only ceph allowlist missing' >&2; exit 1; }
scan_file 'systemctl is-active' "$DIR/s04a1-inventory.sh" >/dev/null || { echo 'FAIL read-only unit check missing' >&2; exit 1; }
if scan_file 'systemctl[[:space:]]+(stop|start|restart)|sudo[[:space:]]+.*(tee|install|rm|touch|truncate)' "$DIR/s04a1-inventory.sh"; then echo 'FAIL inventory mutation found' >&2; exit 1; fi
if scan_tree 'production.*PD.*stop|PRODUCTION_PD.*MUST_NOT_STOP' >/dev/null; then :; else
  printf 'FAIL\tproduction PD prohibition missing\n' >&2; exit 1
fi
printf 'GATE0_PASS\tno-network-no-environment-actions\tproduction-PD-stop-forbidden\tC-L-contract\tmatrix\trecovery-first\n'
