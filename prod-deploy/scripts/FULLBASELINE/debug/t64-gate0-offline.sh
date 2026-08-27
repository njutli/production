#!/usr/bin/env bash
# Pure offline Gate 0 for 03-22. No SSH, sudo, mount, loop, Ceph, JuiceFS, or fio is executed.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FILES=(
  t64-common.sh
  t64-node-storage.sh
  t64-recover-partial-storage.sh
  t64-node-cluster.sh
  t64-cluster-orchestrator.sh
  t64-gen-jobfiles.sh
  t64-volume-layout.sh
  t64-seed-interface-gate.sh
  t64-seed-volume.sh
  t64-restore-volume.sh
  t64-gc-return.sh
  t64-reset-gates.sh
  t64-sampler.sh
  t64-run-arm.sh
  t64-finalize.sh
)
for file in "${FILES[@]}"; do bash -n "$SCRIPT_DIR/$file"; done
python3 -c 'compile(open("'$SCRIPT_DIR'/t64-analyze-arm.py").read(), "t64-analyze-arm.py", "exec")'
python3 "$SCRIPT_DIR/t64-analyze-arm.py" --self-test
grep -Fq 'time-weighted into 1s bins' "$SCRIPT_DIR/t64-analyze-arm.py"
grep -Fq 'bw-resample.tsv' "$SCRIPT_DIR/t64-analyze-arm.py"
! grep -Fq 'duplicate second' "$SCRIPT_DIR/t64-analyze-arm.py"
python3 -c 'import json,sys; d=json.load(sys.stdin); p=next(x for x in d["pools"] if x["name"]=="juicefs-data"); s=p["stats"]; print("%s\t%s\t%s"%(s["objects"],s["stored"],s["bytes_used"]))' \
  <<< '{"pools":[{"name":"juicefs-data","stats":{"objects":1,"stored":2,"bytes_used":3}}]}' \
  | grep -q $'^1\t2\t3$'

TMP="/tmp/production/t64-gate0-$$"
mkdir -p "$TMP"
cleanup() {
  find "$TMP/io-start" -type f -delete 2>/dev/null || true
  rm -f "$TMP/cmdline.fixture" "$TMP/cmdline-flat.fixture" "$TMP/status.fixture.json" "$TMP/gc.fixture.log"
  rm -f "$TMP/jobfiles/layout-B0.fio" "$TMP/jobfiles/B0.fio" "$TMP/jobfiles.log"
  rmdir "$TMP/io-start/arm/bw" "$TMP/io-start/arm" "$TMP/io-start" 2>/dev/null || true
  rmdir "$TMP/jobfiles" "$TMP" 2>/dev/null || true
}
trap cleanup EXIT
bash "$SCRIPT_DIR/t64-gen-jobfiles.sh" "$TMP/jobfiles" \
  "/tmp/jfs-t64-20260824-120000-mnt-R01/test_dir" > "$TMP/jobfiles.log"
[[ $(grep -c '^\[slot' "$TMP/jobfiles/B0.fio") -eq 256 ]]
[[ $(grep -c '^filename=' "$TMP/jobfiles/B0.fio") -eq 256 ]]
[[ $(grep '^filename=' "$TMP/jobfiles/B0.fio" | sort -u | wc -l) -eq 256 ]]
grep -q '^runtime=180$' "$TMP/jobfiles/B0.fio"
grep -q '^allow_file_create=0$' "$TMP/jobfiles/B0.fio"
! grep -qE 'create_on_open=1|read_test' "$TMP/jobfiles/B0.fio"
bash -c 'source "$1"; t64_check_instance LAYOUT-CANARY-A' _ "$SCRIPT_DIR/t64-common.sh"
bash -c 'source "$1"; t64_check_instance ARM-CANARY-A' _ "$SCRIPT_DIR/t64-common.sh"
bash -c 'source "$1"; t64_check_instance ARM-CANARY-A2' _ "$SCRIPT_DIR/t64-common.sh"
bash -c 'source "$1"; t64_check_instance SEED-FORMAL; t64_check_instance RESTORE-PREFLIGHT; t64_check_instance G08' _ "$SCRIPT_DIR/t64-common.sh"
grep -Fq 'LAYOUT-CANARY-A' "$SCRIPT_DIR/t64-gen-jobfiles.sh"
grep -Fq 'ARM-CANARY-A' "$SCRIPT_DIR/t64-gen-jobfiles.sh"
grep -Fq 't64_expected_cluster "$INSTANCE"' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq '[[ "$INSTANCE" =~ ^R0[1-8]$ ]]' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq 'T64_ARM_CANARY_AUTH' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq 'formal T64_FIO_AUTH is forbidden for arm canary' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq 'canary authorization is forbidden for formal arm' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq 'NONFORMAL_ARM_CANARY' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq 'formal arm requires a restored-seed clone state' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq 'immutable seed source changed during fio' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq -- '--derive-io-start "$OUT"' "$SCRIPT_DIR/t64-run-arm.sh"
! rg -n 'WATCHER_PID|watcher=' "$SCRIPT_DIR/t64-run-arm.sh"
grep -Fq '"NONFORMAL_CANARY"' "$SCRIPT_DIR/t64-analyze-arm.py"
grep -Fq 'fio-io-start-estimates.tsv' "$SCRIPT_DIR/t64-analyze-arm.py"
grep -Fq 'spread > 2.0' "$SCRIPT_DIR/t64-analyze-arm.py"
! grep -Fq 'for instance in SMOKE-A' "$SCRIPT_DIR/t64-finalize.sh"
grep -Fq 'normal|invalid' "$SCRIPT_DIR/t64-finalize.sh"
grep -Fq 'invalid finalize requires RUN_INVALID.tsv' "$SCRIPT_DIR/t64-finalize.sh"
grep -Fq 'abort seed destroy audit does not match RUN_INVALID.tsv' "$SCRIPT_DIR/t64-finalize.sh"
grep -Fq 'post-failure formal arm was started' "$SCRIPT_DIR/t64-finalize.sh"
grep -Fq 'FINALIZE_PASS mode=%s archive=%s' "$SCRIPT_DIR/t64-finalize.sh"
grep -Fq 'place $TASK_BASENAME beside the scripts or set T64_TASK_DOC' "$SCRIPT_DIR/t64-finalize.sh"
python3 - "$TMP/jobfiles/layout-B0.fio" <<'PY'
import sys

jobs = []
current = None
for raw in open(sys.argv[1]):
    line = raw.strip()
    if line.startswith("[slot"):
        current = {}
        jobs.append(current)
    elif current is not None and "=" in line:
        key, value = line.split("=", 1)
        current[key] = value
assert len(jobs) == 256
assert len({j["filename"] for j in jobs}) == 256
assert all(int(j["filesize"]) == 1073741824 for j in jobs)
assert all(int(j["size"]) == 536870912 for j in jobs)
assert sum(int(j["offset"]) == 0 for j in jobs) == 128
assert sum(int(j["offset"]) == 536870912 for j in jobs) == 128
assert all(int(j["offset"]) + int(j["size"]) <= int(j["filesize"]) for j in jobs)
PY

# fio 3.28 flushes BW logs only at exit. Exercise the post-run estimator with
# 256 synthetic logs whose flush mtime and final relative timestamp imply an
# exact epoch 1000.0, without invoking fio or touching the environment.
mkdir -p "$TMP/io-start/arm/bw"
printf '998.000000000\tlaunch\n1180.500000000\tend\trc=0\n' > "$TMP/io-start/arm/phase.tsv"
for i in $(seq 1 256); do
  file=$(printf '%s/io-start/arm/bw/FIXTURE_bw.%s.log' "$TMP" "$i")
  printf '1000,1024,1,262144\n180000,1024,1,262144\n' > "$file"
  touch -d '@1180.000000000' "$file"
done
python3 "$SCRIPT_DIR/t64-analyze-arm.py" --derive-io-start "$TMP/io-start" \
  | grep -q 'IO_START_DERIVE_PASS epoch=1000.000000000 estimates=256 spread_s=0.000000000'
grep -q '^1000.000000000$' "$TMP/io-start/arm/fio-io-start.epoch"

# Negative guards must fail before reaching any environmental command.
set +e
bash "$SCRIPT_DIR/t64-node-storage.sh" plan INVALID A 10.20.1.150 >/dev/null 2>&1; a=$?
bash "$SCRIPT_DIR/t64-node-cluster.sh" render 20260824-120000 X R01 10.20.1.150 >/dev/null 2>&1; b=$?
bash "$SCRIPT_DIR/t64-volume-layout.sh" verify 20260824-120000 A R02 >/dev/null 2>&1; c=$?
bash "$SCRIPT_DIR/t64-recover-partial-storage.sh" inspect INVALID A 10.20.1.150 >/dev/null 2>&1; d=$?
bash "$SCRIPT_DIR/t64-seed-volume.sh" verify 20260824-120000 B SEED-FORMAL >/dev/null 2>&1; e=$?
bash "$SCRIPT_DIR/t64-restore-volume.sh" load 20260824-120000 A SEED-FORMAL >/dev/null 2>&1; f=$?
bash "$SCRIPT_DIR/t64-gc-return.sh" inspect 20260824-120000 B G01 >/dev/null 2>&1; g=$?
bash "$SCRIPT_DIR/t64-restore-volume.sh" adopt-clone-state 20260824-120000 A R01 >/dev/null 2>&1; h=$?
bash "$SCRIPT_DIR/t64-restore-volume.sh" abort-umount 20260824-120000 A R01 >/dev/null 2>&1; i=$?
bash "$SCRIPT_DIR/t64-gc-return.sh" abort-final-destroy 20260824-120000 A G05 >/dev/null 2>&1; j=$?
bash "$SCRIPT_DIR/t64-reset-gates.sh" post-abort-final-destroy 20260824-120000 A G05 >/dev/null 2>&1; k=$?
set -e
(( a == 42 && b == 42 && c == 42 && d == 42 && e == 42 && f == 42 && g == 42 && h == 42 && i == 42 && j == 42 && k == 42 )) || { printf 'negative guard failed: %s %s %s %s %s %s %s %s %s %s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i" "$j" "$k" >&2; exit 1; }

# JuiceFS daemon PID selection: accept one process or select the unique child
# from the known parent+worker topology; reject ambiguous sibling children.
source "$SCRIPT_DIR/t64-common.sh"
[[ $(t64_select_child_pid $'100\t1') == 100 ]]
[[ $(t64_select_child_pid $'100\t1\n101\t100') == 101 ]]
[[ $(t64_proc_ppid "$$") == "$PPID" ]]
printf '%s\0%s\0%s\0' '/tmp/juicefs-03-8' 'tikv://10.20.1.150:12379,10.20.1.151:12379/test value' '/tmp/jfs-t64-20260824-120000-mnt-R01' > "$TMP/cmdline.fixture"
t64_nul_file_has_exact_arg "$TMP/cmdline.fixture" 'tikv://10.20.1.150:12379,10.20.1.151:12379/test value'
t64_nul_file_has_exact_arg "$TMP/cmdline.fixture" '/tmp/jfs-t64-20260824-120000-mnt-R01'
! t64_nul_file_has_exact_arg "$TMP/cmdline.fixture" 'tikv://10.20.1.150:12379,10.20.1.151:12379/test'
printf '%s' '/tmp/juicefs-03-8 mount -d --max-uploads 150 tikv://10.20.1.150:12379,10.20.1.151:12379/test /tmp/jfs-t64-20260824-120000-mnt-R01' > "$TMP/cmdline-flat.fixture"
t64_nul_file_has_exact_arg "$TMP/cmdline-flat.fixture" 'tikv://10.20.1.150:12379,10.20.1.151:12379/test'
t64_nul_file_has_exact_arg "$TMP/cmdline-flat.fixture" '/tmp/jfs-t64-20260824-120000-mnt-R01'
! t64_nul_file_has_exact_arg "$TMP/cmdline-flat.fixture" '10.20.1.150:12379,10.20.1.151:12379/test'
! t64_nul_file_has_exact_arg "$TMP/cmdline-flat.fixture" 'tikv://10.20.1.150:12379,10.20.1.151:12379/test /tmp/jfs-t64-20260824-120000-mnt-R01'
printf '%s\n' '{"Setting":{"UUID":"01234567-89ab-cdef-0123-456789abcdef","Name":"jfs-t64-fixture"},"Sessions":[],"Stat":{}}' > "$TMP/status.fixture.json"
[[ $(t64_status_identity "$TMP/status.fixture.json") == $'01234567-89ab-cdef-0123-456789abcdef\tjfs-t64-fixture' ]]
t64_status_has_zero_sessions "$TMP/status.fixture.json"
printf '%s\n' 'scanned 13 objects, 10 valid, 0 pending delete (0 bytes), 2 compacted (8 bytes), 1 leaked (4 bytes), 0 delslices (0 bytes), 0 delfiles (0 bytes), 0 skipped (0 bytes)' > "$TMP/gc.fixture.log"
[[ $(t64_gc_summary "$TMP/gc.fixture.log" | awk -F '\t' '$1=="leaked"{print $2}') == 1 ]]
set +e
( t64_select_child_pid $'100\t1\n101\t100\n102\t100' ) >/dev/null 2>&1; daemon_rc=$?
set -e
(( daemon_rc == 42 )) || { printf 'ambiguous daemon topology guard failed: %s\n' "$daemon_rc" >&2; exit 1; }
grep -Fq 'SMOKE-[AB]2?' "$SCRIPT_DIR/t64-common.sh"
grep -Fq 'pairs=$(mount_pid_pairs)' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'pgrep -af -- "$T64_JUICEFS_BIN"' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq "\$0 ~ / mount / && \$NF==m" "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'candidate_pairs_shell=%q' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'inspect-mount-pid) inspect_mount_pid' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'adopt-mount-state) adopt_mount_state' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'state adoption is restricted to repair smoke instances' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'T64_VOLUME_ADOPT_AUTH' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'write_mount_state normal-format' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'write_mount_state pid-gate-recovery' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 't64_status_identity "$OUT/status-adopt.json"' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 't64_status_identity "$OUT/status-format.json"' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 't64_status_identity "$OUT/status-pre-destroy.json"' "$SCRIPT_DIR/t64-volume-layout.sh"
! rg -n 'json\.load\([^)]*\)\["UUID"\]' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 't64_nul_file_has_exact_arg "/proc/$pid/cmdline" "$META"' "$SCRIPT_DIR/t64-volume-layout.sh"
! rg -n "tr '\\\\0' '\\\\n'.*grep -Fxq" "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq "printf -v quoted_meta '%q' \"\$META\"" "$SCRIPT_DIR/t64-volume-layout.sh"
quoted_fixture=''
printf -v quoted_fixture '%q' 'tikv://10.20.1.150:12379,10.20.1.151:12379/test'
[[ "$quoted_fixture" == 'tikv://10.20.1.150:12379\,10.20.1.151:12379/test' ]]
! rg -n 'matches\+=|\$\{#matches\[@\]\} == 1' "$SCRIPT_DIR/t64-volume-layout.sh"

# Formal arms may no longer format/layout/destroy one new volume per arm. They
# must load one frozen seed, metadata-clone its immutable source directory,
# then use a separate fresh seed restore for an inspected, authorized GC.
grep -Fq 'per-arm format/layout/destroy is retired' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'dump --keep-secret-key "$META" "$DUMP"' "$SCRIPT_DIR/t64-seed-volume.sh"
grep -Fq '"$T64_JUICEFS_BIN" clone -p "$SOURCE_DIR" "$TEST_DIR"' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'formal-clone-contract.tsv' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'source_target_inode_overlap' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'adopt-clone-state) adopt_clone_state' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'T64_CLONE_ADOPT_AUTH' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'abort-umount) abort_umount_restored' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'T64_ABORT_UMOUNT_AUTH' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'formal-arm-evidence-failure' "$SCRIPT_DIR/t64-restore-volume.sh"
! grep -Fq 'cmp -s "$SEED_DIR/formal-clone-contract.tsv" "$OUT/clone-relative.tsv"' "$SCRIPT_DIR/t64-restore-volume.sh"
grep -Fq 'destructive GC requires a positive inspected leaked-object count' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'T64_GC_DELETE_AUTH' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'JFS_GC_SKIPPEDTIME=0' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'post-GC $key differs from seed' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'abort-final-destroy) abort_final_destroy' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'T64_ABORT_SEED_DESTROY_AUTH' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'mode\tabort-invalid-run' "$SCRIPT_DIR/t64-gc-return.sh"
grep -Fq 'seed-return)' "$SCRIPT_DIR/t64-reset-gates.sh"
grep -Fq 'post-final-destroy)' "$SCRIPT_DIR/t64-reset-gates.sh"
grep -Fq 'post-abort-final-destroy)' "$SCRIPT_DIR/t64-reset-gates.sh"
grep -Fq 'T64_ABORT_RESET_AUTH' "$SCRIPT_DIR/t64-reset-gates.sh"
! rg -n -- '--max-deletes[=[:space:]]+0|--no-bgjob' "$SCRIPT_DIR/t64-seed-volume.sh" "$SCRIPT_DIR/t64-restore-volume.sh" "$SCRIPT_DIR/t64-run-arm.sh"

# Static destructive-pattern guard. Exact scoped rm/rmdir and exact PID kill remain allowed.
if rg -n 'rm[[:space:]]+-rf|chown[[:space:]]+-R|chmod[[:space:]]+-R|losetup[[:space:]]+-D|wipefs|blkdiscard|modprobe|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+-(l|f)|ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+delete|systemctl[[:space:]]+(stop|restart|reboot|poweroff)|(^|[[:space:]])(reboot|shutdown|halt|poweroff)([[:space:]]|$)' \
    "${FILES[@]/#/$SCRIPT_DIR/}"; then
  printf 'forbidden command pattern found\n' >&2
  exit 1
fi
! rg -n 'Sunrise@|sshpass[[:space:]]+-p' "${FILES[@]/#/$SCRIPT_DIR/}"

# Stage I must remain remote-read-only: plan/preflight use dedicated read-only functions.
grep -Fq 'plan_storage_readonly "$node"' "$SCRIPT_DIR/t64-cluster-orchestrator.sh"
grep -Fq 'preflight_storage_readonly "$node"' "$SCRIPT_DIR/t64-cluster-orchestrator.sh"
if sed -n '/^plan_storage_readonly()/,/^}/p;/^preflight_storage_readonly()/,/^}/p' \
    "$SCRIPT_DIR/t64-cluster-orchestrator.sh" | \
    rg -n 'scp|mkdir|install -d|mount -t|losetup --find|mkfs|truncate -s' | \
    rg -v 'printf|for tool in'; then
  printf 'Stage I function contains a remote write operation\n' >&2
  exit 1
fi

# Every mkfs target is a previously recorded /dev/loopN and no storage command names NVMe.
grep -q 'loop=\$(sudo losetup --find --show --nooverlap' "$SCRIPT_DIR/t64-node-storage.sh"
grep -Fq '[[ "$loop" =~ ^/dev/loop[0-9]+$ ]]' "$SCRIPT_DIR/t64-node-storage.sh"
! rg -n 'sudo (dd|wipefs|blkdiscard)|mkfs[^\n]*/dev/nvme|losetup -D' "$SCRIPT_DIR/t64-node-storage.sh"

# A tmpfs mount replaces the mountpoint inode. Ownership must be reset and
# verified after each tmpfs mount and before the first unprivileged write.
python3 - "$SCRIPT_DIR/t64-node-storage.sh" "$SCRIPT_DIR/t64-cluster-orchestrator.sh" <<'PY'
from pathlib import Path
import sys

node = Path(sys.argv[1]).read_text()
create = node[node.index("create() {"):node.index("\nverify() {")]
pd_mount = create.index('"t64-pd-${RUN_ID}-${LOWER}" "$BASE/pd"')
pd_owner = create.index('reset_mounted_root_owner "$BASE/pd"')
backing_mount = create.index('"t64-${RUN_ID}-${LOWER}-${role}" "$backing"')
backing_owner = create.index('reset_mounted_root_owner "$backing"')
truncate = create.index('truncate -s "$size" "$img"')
assert pd_mount < pd_owner < backing_mount < backing_owner < truncate
assert "stat -c '%u:%g:%a'" in node
verify = node[node.index("verify() {"):node.index("\ndestroy() {")]
assert 'findmnt -rn -R "$BASE"' not in verify
assert "awk -v p=\"$BASE/\" 'index($2,p)==1'" in verify
plan_destroy = node[node.index("plan_destroy() {"):node.index("\npreflight() {")]
assert "printf 'rmdir %q %q" in plan_destroy
assert "printf 'sudo rmdir %q" in plan_destroy
destroy = node[node.index("destroy() {"):node.index("\ncase \"$ACTION\"")]
assert 'sudo rmdir "$BASE"' in destroy
assert 'sudo rmdir "$BASE/pd"' not in destroy

orchestrator = Path(sys.argv[2]).read_text()
plan = orchestrator[orchestrator.index("plan_storage_readonly() {"):orchestrator.index("\npreflight_storage_readonly() {")]
assert plan.count("reset ownership on mounted tmpfs root") == 2
pd_mount = plan.index("t64-pd-%s-%s %q")
pd_owner = plan.index("reset ownership on mounted tmpfs root")
backing_mount = plan.index("t64-%s-%s-%s %q")
backing_owner = plan.index("reset ownership on mounted tmpfs root", pd_owner + 1)
truncate = plan.index("truncate -s %s %q")
assert pd_mount < pd_owner < backing_mount < backing_owner < truncate
PY

# All client mount consumers must use the same RUN_ID-scoped path accepted by
# t64_assert_abs_scoped_path; the rejected legacy jfs-t64-mnt-RUN_ID form must
# never return.
grep -Fq 'MNT="/tmp/jfs-t64-${RUN_ID}-mnt-${INSTANCE}"' "$SCRIPT_DIR/t64-volume-layout.sh"
grep -Fq 'MNT="/tmp/jfs-t64-${RUN_ID}-mnt-${INSTANCE}"' "$SCRIPT_DIR/t64-run-arm.sh"
! rg -n '/tmp/jfs-t64-mnt-' "$SCRIPT_DIR/t64-volume-layout.sh" \
  "$SCRIPT_DIR/t64-run-arm.sh" "$SCRIPT_DIR/t64-gen-jobfiles.sh"
bash -c 'source "$1"; t64_assert_abs_scoped_path "/tmp/jfs-t64-20260824-120000-mnt-R01" "20260824-120000"' \
  _ "$SCRIPT_DIR/t64-common.sh"

# A 1 GiB filesize in fio does not preallocate an offset-0 512 MiB extent.
# The layout must explicitly sparse-extend exactly the generated 256 paths,
# after fio succeeds and before recording/validating the final manifest.
python3 - "$SCRIPT_DIR/t64-volume-layout.sh" <<'PY'
from pathlib import Path
import sys

s = Path(sys.argv[1]).read_text()
layout = s[s.index("layout() {"):s.index("\numount_volume() {")]
fio = layout.index('fio "$OUT/jobfiles/layout-B0.fio"')
paths = layout.index("mapfile -t expected_paths")
unique = layout.index("${#expected_paths[@]} == 256")
extend = layout.index('truncate -s 1073741824 -- "$path"')
manifest = layout.index('> "$OUT/layout-files.tsv"')
size_gate = layout.index("'$2!=1073741824{bad=1}")
assert fio < paths < unique < extend < manifest < size_gate
assert '[[ "$path" == "$TEST_DIR"/* && -f "$path" && ! -L "$path" ]]' in layout
PY

# State-less recovery is a separate, pre-loop-only path. It must refuse normal
# state, require exact mount sources and an exact token, and never detach loops.
grep -Fq '[[ ! -e "$STATE" ]]' "$SCRIPT_DIR/t64-recover-partial-storage.sh"
grep -Fq 'RECOVERY_INSPECT_PASS' "$SCRIPT_DIR/t64-recover-partial-storage.sh"
grep -Fq 'T64_PARTIAL_RECOVERY_AUTH' "$SCRIPT_DIR/t64-recover-partial-storage.sh"
! rg -n 'losetup[[:space:]]+-d|mkfs|truncate|rm[[:space:]]' "$SCRIPT_DIR/t64-recover-partial-storage.sh"

# Process/status readiness is not store readiness. Global verification must use
# bounded polling and require three consecutive all-Up samples.
grep -Fq 'local deadline=$((SECONDS + 180))' "$SCRIPT_DIR/t64-cluster-orchestrator.sh"
grep -Fq 'if (( stable >= 3 ))' "$SCRIPT_DIR/t64-cluster-orchestrator.sh"
grep -Fq 'sleep 10' "$SCRIPT_DIR/t64-cluster-orchestrator.sh"
grep -Fq 'readiness-${INSTANCE}' "$SCRIPT_DIR/t64-cluster-orchestrator.sh"

printf '%s\n' '03-22 t64 Gate 0 offline tests: PASS'
