#!/usr/bin/env bash
# Pure offline Gate 0 for 03-22c. No SSH, sudo, systemctl, mount, loop,
# Ceph, JuiceFS, or fio command is executed by this script.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

SHELL_FILES=(
  t66-gate0-offline.sh t66-common.sh t66-autonomy.sh t66-inventory.sh t66-sudo-plan.sh t66-sync-scripts.sh
  t66-prod-stop-one.sh t66-prod-start-one.sh
  t66-storage-create-one.sh t66-storage-activate-arm.sh
  t66-storage-deactivate-arm.sh t66-storage-destroy-one.sh
  t66-node-cluster.sh t66-cluster-orchestrator.sh
  t66-gen-jobfiles.sh t66-seed-volume.sh t66-restore-volume.sh
  t66-gc-return.sh t66-reset-gates.sh t66-sampler.sh t66-run-arm.sh
  t66-finalize.sh
)
ALL_FILES=("${SHELL_FILES[@]}" t66-analyze.py)
for file in "${SHELL_FILES[@]}"; do bash -n "$SCRIPT_DIR/$file"; done
python3 -c 'compile(open("'$SCRIPT_DIR'/t66-analyze.py").read(), "t66-analyze.py", "exec")'
python3 "$SCRIPT_DIR/t66-analyze.py" --self-test
# The sync path discovers files in bytewise filename order.  Freeze the local
# manifest in that exact order so the reviewed manifest SHA and the remote
# manifest SHA are one identity rather than two order-dependent identities.
mapfile -t SYNC_FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -type f \( -name 't66-*.sh' -o -name 't66-analyze.py' \) -printf '%f\n' | sort)
[[ ${#SYNC_FILES[@]} -eq ${#ALL_FILES[@]} ]]
diff -u <(printf '%s\n' "${ALL_FILES[@]}" | sort) <(printf '%s\n' "${SYNC_FILES[@]}") >/dev/null
diff -u <(for file in "${SYNC_FILES[@]}"; do sha256sum "$SCRIPT_DIR/$file" | sed 's#  .*/#  #'; done) \
  "$SCRIPT_DIR/t66-manifest.sha256" >/dev/null

mkdir -p /tmp/production
TMP=$(mktemp -d /tmp/production/t66-gate0.XXXXXX)
cleanup() {
  find "$TMP" -depth -type f -delete 2>/dev/null || true
  find "$TMP" -depth -type l -delete 2>/dev/null || true
  find "$TMP" -depth -type d -empty -delete 2>/dev/null || true
  if [[ -n ${AUTOROOT:-} && "$AUTOROOT" == /tmp/production/opencode-t3.22c-19990101-* ]]; then
    find "$AUTOROOT" -depth -type f -delete 2>/dev/null || true
    find "$AUTOROOT" -depth -type d -empty -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT
source "$SCRIPT_DIR/t66-common.sh"

# Finalize audit discovery must accept nodes that only have the mandatory
# state-SHA-bound destroy audit.  A missing optional legacy fixed-name audit
# must not survive as a literal array entry; an existing or dangling-symlink
# legacy path must remain visible so the remote identity gate can reject it.
audit_fixture="$TMP/finalize-audits"
mkdir -p "$audit_fixture"
sha_audit="$audit_fixture/jfs-t66-20260826-120000-storage.destroyed-0123456789abcdef.tsv"
legacy_audit="$audit_fixture/jfs-t66-20260826-120000-storage.destroyed.tsv"
printf 'fixture\n' > "$sha_audit"
shopt -s nullglob
storage_audits=()
if [[ -e "$legacy_audit" || -L "$legacy_audit" ]]; then storage_audits+=("$legacy_audit"); fi
storage_audits+=("$audit_fixture/jfs-t66-20260826-120000-storage.destroyed-"*.tsv)
[[ ${#storage_audits[@]} -eq 1 && ${storage_audits[0]} == "$sha_audit" ]]
printf 'legacy\n' > "$legacy_audit"
storage_audits=()
if [[ -e "$legacy_audit" || -L "$legacy_audit" ]]; then storage_audits+=("$legacy_audit"); fi
storage_audits+=("$audit_fixture/jfs-t66-20260826-120000-storage.destroyed-"*.tsv)
[[ ${#storage_audits[@]} -eq 2 && ${storage_audits[0]} == "$legacy_audit" && ${storage_audits[1]} == "$sha_audit" ]]
unlink "$legacy_audit"; ln -s "$audit_fixture/missing-target" "$legacy_audit"
storage_audits=()
if [[ -e "$legacy_audit" || -L "$legacy_audit" ]]; then storage_audits+=("$legacy_audit"); fi
storage_audits+=("$audit_fixture/jfs-t66-20260826-120000-storage.destroyed-"*.tsv)
[[ ${#storage_audits[@]} -eq 2 && -L ${storage_audits[0]} ]]
grep -Fq 'storage_audits=()' "$SCRIPT_DIR/t66-finalize.sh"
grep -Fq 'if [[ -e "$legacy_audit" || -L "$legacy_audit" ]]' "$SCRIPT_DIR/t66-finalize.sh"
! grep -Fq 'storage_audits=("/tmp/jfs-t66-${run}-storage.destroyed.tsv"' "$SCRIPT_DIR/t66-finalize.sh"

# Exercise the exact embedded inventory validator against the real two-line
# findmnt+df shape seen on production.  This prevents an ambiguous device
# prefix match from surviving Gate 0 and failing only after remote inventory.
mkdir -p "$TMP/inventory-fixture/nodes"
for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
  printf 'section\thost\nnode\t%s\nuid\t1001\ngid\t1001\n' "$node" \
    > "$TMP/inventory-fixture/nodes/${node}.txt"
  printf 'mem\tMemAvailable:\t786432000\nmem\tSwapTotal:\t0\nmem\tSwapFree:\t0\nvmstat\tpswpin\t0\nvmstat\tpswpout\t0\n' \
    >> "$TMP/inventory-fixture/nodes/${node}.txt"
  printf 'unit\tpd\tactive\t101\t/etc/systemd/system/pd.service\t/opt/pd/bin/pd-server\n' \
    >> "$TMP/inventory-fixture/nodes/${node}.txt"
  printf 'unit\ttikv\tactive\t102\t/etc/systemd/system/tikv.service\t/opt/tikv/bin/tikv-server\n' \
    >> "$TMP/inventory-fixture/nodes/${node}.txt"
  printf '/dev/nvme1n1 /mnt/jfs-tikv ext4 rw,noatime,stripe=32 fixture-uuid\n' \
    >> "$TMP/inventory-fixture/nodes/${node}.txt"
  printf '/dev/nvme1n1 ext4 943971160064 34359738368 861255421952 4%% /mnt/jfs-tikv\n' \
    >> "$TMP/inventory-fixture/nodes/${node}.txt"
done
awk '/^python3 - "\$OUT" <</ {copy=1; next} copy && /^PY$/ {exit} copy {print}' \
  "$SCRIPT_DIR/t66-inventory.sh" > "$TMP/inventory-validator.py"
[[ -s "$TMP/inventory-validator.py" ]]
python3 "$TMP/inventory-validator.py" "$TMP/inventory-fixture"
grep -Fq $'uid\t1001' "$TMP/inventory-fixture/contract.tsv"
grep -Fq $'min_avail_pre\t861255421952' "$TMP/inventory-fixture/contract.tsv"

expect_42() {
  local rc
  set +e; ( "$@" ) >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -eq 42 ]] || { printf 'expected rc=42, got rc=%s: %q\n' "$rc" "$1" >&2; exit 1; }
}
expect_nonzero() {
  local rc
  set +e; ( "$@" ) >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -ne 0 ]] || { printf 'expected nonzero rc: %q\n' "$1" >&2; exit 1; }
}

# Scoped process filtering must exclude only the invoking shell ancestry, not
# every process launched from the signed script directory.
PROC_TOKEN='jfs-t66-20260826-120000'
PROC_ROWS=$'100 bash /tmp/jfs-t66-20260826-120000-scripts/t66-storage-destroy-one.sh plan 20260826-120000 10.20.1.150\n101 sshd: fixture\n200 bash /tmp/jfs-t66-20260826-120000-scripts/t66-sampler.sh 20260826-120000 R01\n201 /tmp/juicefs mount tikv://fixture/jfs-t66-20260826-120000-r01 /tmp/jfs-t66-20260826-120000-mnt-R01\n202 unrelated-process'
filtered=$(printf '%s\n' "$PROC_ROWS" | t66_filter_scoped_process_rows "$PROC_TOKEN" ' 101 ' '/tmp/jfs-t66-20260826-120000-scripts/t66-storage-destroy-one.sh')
[[ "$filtered" == $'200\tbash /tmp/jfs-t66-20260826-120000-scripts/t66-sampler.sh 20260826-120000 R01\n201\t/tmp/juicefs mount tikv://fixture/jfs-t66-20260826-120000-r01 /tmp/jfs-t66-20260826-120000-mnt-R01' ]]
[[ -z $(printf '%s\n' "$PROC_ROWS" | t66_filter_scoped_process_rows "$PROC_TOKEN" ' 100 101 200 201 ') ]]
# Under `set -euo pipefail`, an empty live-process result must still return 0.
t66_scoped_runtime_process_rows 'jfs-t66-19990101-000000-no-live-fixture' >/dev/null

# Pure identity/path/token guards.
printf '#!/usr/bin/env sh\nexit 0\n' > "$TMP/fixture-production-exe"
chmod 0700 "$TMP/fixture-production-exe"
[[ $(t66_exe_from_cmdline "$TMP/fixture-production-exe --config=/tmp/fixture.toml") == "$TMP/fixture-production-exe" ]]
expect_42 t66_exe_from_cmdline ''
expect_42 t66_exe_from_cmdline relative-command
expect_42 t66_exe_from_cmdline /definitely/missing/t66-production-exe
expect_42 t66_check_run_id INVALID
expect_42 t66_check_cluster A
expect_42 t66_check_cluster B
expect_42 t66_check_instance R09
expect_42 t66_node_suffix 10.20.1.157
expect_42 t66_assert_abs_scoped_path / 20260826-120000
expect_42 t66_assert_abs_scoped_path relative 20260826-120000
expect_42 t66_assert_abs_scoped_path /mnt/jfs-tikv/data 20260826-120000
expect_42 t66_assert_no_production_overlap /mnt/jfs-tikv/data
expect_42 t66_check_auth wrong expected
mkdir -p "$TMP/old-scope"; expect_42 t66_require_absent "$TMP/old-scope"
t66_check_cluster B1c; t66_check_cluster D1
for instance in SMOKE-B1c SMOKE-D1 ARM-CANARY-B1c ARM-CANARY-D1 SEED-FORMAL RESTORE-PREFLIGHT-B1c RESTORE-PREFLIGHT-D1 GC-PREFLIGHT G08 R01 R08; do
  t66_check_instance "$instance"
done
[[ $(t66_expected_cluster R01) == B1c && $(t66_expected_cluster R02) == D1 &&
   $(t66_expected_cluster R03) == D1 && $(t66_expected_cluster R04) == B1c &&
   $(t66_expected_cluster R05) == D1 && $(t66_expected_cluster R06) == B1c &&
   $(t66_expected_cluster R07) == B1c && $(t66_expected_cluster R08) == D1 ]]

# Entry-point argument/arm/token guards fail before host or environment access.
expect_42 bash "$SCRIPT_DIR/t66-storage-create-one.sh" plan INVALID 10.20.1.150
expect_42 bash "$SCRIPT_DIR/t66-storage-activate-arm.sh" plan 20260826-120000 B1c R02 10.20.1.150
expect_42 bash "$SCRIPT_DIR/t66-prod-stop-one.sh" plan 20260826-120000 10.20.1.157
expect_42 bash "$SCRIPT_DIR/t66-seed-volume.sh" verify 20260826-120000 D1 SEED-FORMAL
expect_42 bash "$SCRIPT_DIR/t66-restore-volume.sh" load 20260826-120000 B1c SEED-FORMAL
expect_42 bash "$SCRIPT_DIR/t66-gc-return.sh" inspect 20260826-120000 D1 G01
expect_42 bash "$SCRIPT_DIR/t66-sync-scripts.sh" plan INVALID
expect_42 bash "$SCRIPT_DIR/t66-sync-scripts.sh" invalid-action 20260826-120000
bash "$SCRIPT_DIR/t66-sync-scripts.sh" plan 20260826-120000 > "$TMP/sync-plan.txt"
grep -q '^MODE=SYNC_PLAN_ONLY$' "$TMP/sync-plan.txt"
grep -Fq '03-22c-resync-${RUN_ID}-${old_sha}-${REMOTE_MANIFEST_SHA}' "$SCRIPT_DIR/t66-sync-scripts.sh"
grep -Fq 'assert_remote_quiescent' "$SCRIPT_DIR/t66-sync-scripts.sh"
grep -Fq 'scripts-prev-${old_sha:0:16}' "$SCRIPT_DIR/t66-sync-scripts.sh"

mkdir -p "$TMP/real"; ln -s "$TMP/real" "$TMP/link"
expect_42 t66_assert_realpath_exact "$TMP/link" "$TMP/link"

# Pure capacity, D1 headroom, and baseline thresholds.
t66_capacity_pre_ok $((768*1024**3)); expect_nonzero t66_capacity_pre_ok $((768*1024**3-1))
t66_capacity_post_ok $((640*1024**3)); expect_nonzero t66_capacity_post_ok $((640*1024**3-1))
t66_memory_pre_ok $((128*1024**2)); expect_nonzero t66_memory_pre_ok $((128*1024**2-1))
t66_memory_runtime_ok $((64*1024**2)); expect_nonzero t66_memory_runtime_ok $((64*1024**2-1))
t66_b_logs_margin_ok $((28*1024**3)) $((13*1024**3)); expect_nonzero t66_b_logs_margin_ok $((28*1024**3)) $((14*1024**3))
t66_baseline_within_256m 1000000000 $((1000000000+256*1024**2)); expect_nonzero t66_baseline_within_256m 1000000000 $((1000000000+256*1024**2+1))

# Sparse backing must fail; genuinely allocated fixture must pass.
truncate -s $((64*1024**2)) "$TMP/sparse.img"
expect_42 t66_assert_allocated_file "$TMP/sparse.img" $((64*1024**2))
fallocate -l $((16*1024**2)) "$TMP/allocated.img"
t66_assert_allocated_file "$TMP/allocated.img" $((16*1024**2)) >/dev/null

# State/backing mismatch and loop reuse are rejected by text-only validators.
STATE="$TMP/storage.tsv"
cat > "$STATE" <<'EOF'
meta	20260826-120000
node	10.20.1.150
backing_root	/mnt/jfs-tikv/jfs-t66-20260826-120000-backing
mount_root	/mnt/jfs-t66-20260826-120000
allocated	kv	/mnt/jfs-tikv/jfs-t66-20260826-120000-backing/kv.img	103079215104	1	11
allocated	b1c-logs	/mnt/jfs-tikv/jfs-t66-20260826-120000-backing/b1c-logs.img	34359738368	1	12
EOF
t66_validate_storage_contract_rows "$STATE" 20260826-120000 10.20.1.150
sed 's/b1c-logs.img/wrong.img/' "$STATE" > "$TMP/storage-bad.tsv"
expect_nonzero t66_validate_storage_contract_rows "$TMP/storage-bad.tsv" 20260826-120000 10.20.1.150
ACT="$TMP/activation.tsv"
cat > "$ACT" <<'EOF'
meta	20260826-120000
node	10.20.1.150
arm	D1
instance	R02
mount_root	/mnt/jfs-t66-20260826-120000
pd	t66-pd-20260826-120000-r02	/mnt/jfs-t66-20260826-120000/pd
memory_baseline	786432000	0	0	0
ram_logs	t66-logs-20260826-120000-r02	/mnt/jfs-t66-20260826-120000/d1-r02-logs-backing	34359738368
loop	kv	/dev/loop5	/mnt/jfs-tikv/jfs-t66-20260826-120000-backing/kv.img	/mnt/jfs-t66-20260826-120000/d1-kv	attached
loop	logs	/dev/loop25	/mnt/jfs-t66-20260826-120000/d1-r02-logs-backing/t66-d1-logs.img	/mnt/jfs-t66-20260826-120000/d1-logs	attached
fs	kv	/dev/loop5	11111111-1111-1111-1111-111111111111	1048576	102005473280
fs	logs	/dev/loop25	22222222-2222-2222-2222-222222222222	1048576	32984080384
quiet_evidence	/tmp/jfs-t66-20260826-120000-D1-R02-10.20.1.150-nvme-quiet-0123456789abcdef.tsv
quiet_summary	/tmp/jfs-t66-20260826-120000-D1-R02-10.20.1.150-nvme-quiet-0123456789abcdef.tsv.summary
activate_epoch	1787747000
EOF
t66_validate_activation_contract_rows "$ACT" 20260826-120000 D1 R02 10.20.1.150
sed 's#/dev/loop25#/dev/loop5#' "$ACT" > "$TMP/activation-loop-reused.tsv"
expect_nonzero t66_validate_activation_contract_rows "$TMP/activation-loop-reused.tsv" 20260826-120000 D1 R02 10.20.1.150
grep -v $'^fs\tlogs\t' "$ACT" > "$TMP/activation-missing-fs.tsv"
expect_nonzero t66_validate_activation_contract_rows "$TMP/activation-missing-fs.tsv" 20260826-120000 D1 R02 10.20.1.150
grep -v '^quiet_evidence' "$ACT" > "$TMP/activation-missing-quiet.tsv"
expect_nonzero t66_validate_activation_contract_rows "$TMP/activation-missing-quiet.tsv" 20260826-120000 D1 R02 10.20.1.150
grep -v '^quiet_summary' "$ACT" > "$TMP/activation-missing-quiet-summary.tsv"
expect_nonzero t66_validate_activation_contract_rows "$TMP/activation-missing-quiet-summary.tsv" 20260826-120000 D1 R02 10.20.1.150
sed 's/0123456789abcdef/0123456789abcdeg/g' "$ACT" > "$TMP/activation-bad-quiet-id.tsv"
expect_nonzero t66_validate_activation_contract_rows "$TMP/activation-bad-quiet-id.tsv" 20260826-120000 D1 R02 10.20.1.150
sed $'/^quiet_summary\t/s/\.tsv\.summary$/.other.tsv.summary/' "$ACT" > "$TMP/activation-summary-mismatch.tsv"
expect_nonzero t66_validate_activation_contract_rows "$TMP/activation-summary-mismatch.tsv" 20260826-120000 D1 R02 10.20.1.150

# A bounded idle profile accepts tiny ext4/kernel background writeback, while
# rejecting a burst, nonzero inflight, malformed sample count, or counter reset.
QUIET_FIX="$TMP/quiet-pass.tsv"
printf 'epoch\twrites_completed\tsectors_written\tinflight\n' > "$QUIET_FIX"
for i in $(seq 0 60); do
  printf '%s\t%s\t%s\t0\n' "$((1700000000+i))" "$((1000+2*i))" "$((2000+16*i))" >> "$QUIET_FIX"
done
t66_nvme_quiet_evidence_ok "$QUIET_FIX" | grep -Fq $'QUIET_PROFILE_PASS\tduration_s=30\tdelta_writes=60\tdelta_sectors=480'
awk -F '\t' 'BEGIN{OFS="\t"} NR==62{$3+=9000} {print}' "$QUIET_FIX" > "$TMP/quiet-burst.tsv"
expect_nonzero t66_nvme_quiet_evidence_ok "$TMP/quiet-burst.tsv"
awk -F '\t' 'BEGIN{OFS="\t"} NR==45{$4=1} {print}' "$QUIET_FIX" > "$TMP/quiet-inflight.tsv"
expect_nonzero t66_nvme_quiet_evidence_ok "$TMP/quiet-inflight.tsv"
head -n 61 "$QUIET_FIX" > "$TMP/quiet-short.tsv"
expect_nonzero t66_nvme_quiet_evidence_ok "$TMP/quiet-short.tsv"
awk -F '\t' 'BEGIN{OFS="\t"} NR==45{$3=1} {print}' "$QUIET_FIX" > "$TMP/quiet-reset.tsv"
expect_nonzero t66_nvme_quiet_evidence_ok "$TMP/quiet-reset.tsv"

# Every runtime NVMe quiet gate must reuse the same preregistered bounded-idle
# parser.  A second, stricter "absolute zero writes" implementation would make
# the live protocol disagree with the task contract and the activation gate.
grep -Fq 't66_nvme_quiet_evidence_ok "$evidence" > "$summary"' "$SCRIPT_DIR/t66-reset-gates.sh"
grep -Fq "underlying NVMe did not meet the frozen bounded-idle profile" "$SCRIPT_DIR/t66-reset-gates.sh"
if grep -Fq 'NR==32{w=$2;s=$3}' "$SCRIPT_DIR/t66-reset-gates.sh"; then
  echo 'reset gate still contains an absolute-zero NVMe implementation' >&2
  exit 1
fi

# Jobfile contract: one immutable 256-file/128GiB active layout and one
# randwrite jobfile that cannot create files.
JOBROOT="/tmp/jfs-t66-20260826-120000-mnt-R01/test_dir"
bash "$SCRIPT_DIR/t66-gen-jobfiles.sh" "$TMP/jobfiles" "$JOBROOT" > "$TMP/jobfiles.sha"
[[ $(grep -c '^\[slot' "$TMP/jobfiles/B0.fio") -eq 256 && $(grep '^filename=' "$TMP/jobfiles/B0.fio" | sort -u | wc -l) -eq 256 ]]
grep -q '^runtime=180$' "$TMP/jobfiles/B0.fio"
grep -q '^iodepth=64$' "$TMP/jobfiles/B0.fio"
grep -q '^allow_file_create=0$' "$TMP/jobfiles/B0.fio"
if grep -q '^create_on_open=1$' "$TMP/jobfiles/B0.fio"; then echo 'formal jobfile can create files' >&2; exit 1; fi

# Clone inode contract: dump/load may preserve all immutable source inode
# numbers.  Only source-target independence is causal; reference-source
# overlap remains a diagnostic and must not reject the B1c preflight.
awk '/^verify_formal_clone_semantics\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' \
  "$SCRIPT_DIR/t66-restore-volume.sh" > "$TMP/clone-validator.sh"
source "$TMP/clone-validator.sh"
mkdir -p "$TMP/clone-contract/out"
CLONE_REF="$TMP/clone-contract/reference.tsv"
CLONE_SOURCE="$TMP/clone-contract/source.tsv"
CLONE_TARGET="$TMP/clone-contract/target.tsv"
CLONE_TARGET_BAD="$TMP/clone-contract/target-overlap.tsv"
: > "$CLONE_REF"; : > "$CLONE_SOURCE"; : > "$CLONE_TARGET"; : > "$CLONE_TARGET_BAD"
for i in $(seq 0 255); do
  printf 'file.%03d\t1073741824\t%s\n' "$i" "$((1000+i))" >> "$CLONE_REF"
  printf 'file.%03d\t1073741824\t%s\n' "$i" "$((1000+i))" >> "$CLONE_SOURCE"
  printf 'file.%03d\t1073741824\t%s\n' "$i" "$((2000+i))" >> "$CLONE_TARGET"
  if (( i == 0 )); then inode=1000; else inode=$((2000+i)); fi
  printf 'file.%03d\t1073741824\t%s\n' "$i" "$inode" >> "$CLONE_TARGET_BAD"
done
OUT="$TMP/clone-contract/out"
cp "$CLONE_SOURCE" "$OUT/seed-source-files.tsv"
cp "$CLONE_TARGET" "$OUT/clone-relative.tsv"
verify_formal_clone_semantics "$CLONE_REF"
grep -Fxq $'source_reference_inode_overlap\t256' "$OUT/clone-inode-invariants.tsv"
grep -Fxq $'source_target_inode_overlap\t0' "$OUT/clone-inode-invariants.tsv"
cp "$CLONE_TARGET_BAD" "$OUT/clone-relative.tsv"
expect_42 verify_formal_clone_semantics "$CLONE_REF"
grep -Fq "RESTORE-PREFLIGHT-B1c or formal R01..R08" "$SCRIPT_DIR/t66-restore-volume.sh"
grep -Fq 'B1c preflight adoption requires an absent formal clone contract' "$SCRIPT_DIR/t66-restore-volume.sh"

# I/O-start estimator accepts 256 aligned logs, rejects spread >2s and a
# missing 256th log without contacting fio or any environment endpoint.
mkdir -p "$TMP/io/arm/bw"
printf '998.000000000\tlaunch\n1180.500000000\tend\trc=0\n' > "$TMP/io/arm/phase.tsv"
for i in $(seq 1 256); do
  f=$(printf '%s/io/arm/bw/FIXTURE_bw.%s.log' "$TMP" "$i")
  printf '1000,1024,1,262144\n180000,1024,1,262144\n' > "$f"
  touch -d '@1180.000000000' "$f"
done
python3 "$SCRIPT_DIR/t66-analyze.py" --derive-io-start "$TMP/io" | grep -q 'IO_START_DERIVE_PASS'
touch -d '@1183.000000000' "$TMP/io/arm/bw/FIXTURE_bw.256.log"
set +e; python3 "$SCRIPT_DIR/t66-analyze.py" --derive-io-start "$TMP/io" >/dev/null 2>&1; spread_rc=$?; set -e
[[ "$spread_rc" -ne 0 ]]
unlink "$TMP/io/arm/bw/FIXTURE_bw.256.log"
set +e; python3 "$SCRIPT_DIR/t66-analyze.py" --derive-io-start "$TMP/io" >/dev/null 2>&1; missing_rc=$?; set -e
[[ "$missing_rc" -ne 0 ]]

# Frozen matrix mapping/pair direction and 15%/3-of-4 decision.
mkdir -p "$TMP/matrix/instances"
for spec in 'R01 B1c 100' 'R02 D1 120' 'R03 D1 121' 'R04 B1c 100' 'R05 D1 119' 'R06 B1c 100' 'R07 B1c 100' 'R08 D1 118'; do
  read -r inst arm bw <<< "$spec"; mkdir -p "$TMP/matrix/instances/$inst"
  if [[ "$arm" == D1 ]]; then cv=6; ratio=0.98; else cv=12; ratio=0.85; fi
  printf '{"evidence_class":"FORMAL","arm":"%s","evidence_valid":true,"formal_median_MiBs":%s,"cv_pct":%s,"w4_w1":%s}\n' "$arm" "$bw" "$cv" "$ratio" > "$TMP/matrix/instances/$inst/arm-analysis.json"
done
python3 "$SCRIPT_DIR/t66-analyze.py" --matrix "$TMP/matrix" > "$TMP/matrix.stdout"
python3 - "$TMP/matrix/analysis/matrix-analysis.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['valid_arms']==8 and d['positive_pairs']==4 and d['material_gain_pass'] is True
assert d['half_nic_target_pass'] is False and len(d['pair_effect_pct'])==4
assert d['stability_improvement_pass'] is True and d['d1_deployment_stable_pass'] is True
PY
unlink "$TMP/matrix/instances/R08/arm-analysis.json"
set +e; python3 "$SCRIPT_DIR/t66-analyze.py" --matrix "$TMP/matrix" >/dev/null 2>&1; matrix_missing_rc=$?; set -e
[[ "$matrix_missing_rc" -ne 0 ]]

# Required guards/statuses and exact destructive vocabulary are present.
grep -Fq 'SAMPLER_CRASH' "$SCRIPT_DIR/t66-run-arm.sh"
grep -Fq 'FIO_WATCHDOG_TIMEOUT' "$SCRIPT_DIR/t66-run-arm.sh"
grep -Fq 'CAPACITY_SAFETY_ABORT' "$SCRIPT_DIR/t66-run-arm.sh"
grep -Fq 'MEMORY_SAFETY_ABORT' "$SCRIPT_DIR/t66-run-arm.sh"
grep -Fq 'sample_osd' "$SCRIPT_DIR/t66-sampler.sh"
grep -Fq 'nvme-smart-pre.json' "$SCRIPT_DIR/t66-sampler.sh"
grep -Fq 'SAMPLER_EXIT_AFTER_FIO' "$SCRIPT_DIR/t66-sampler.sh"
grep -Fq 'sleep 30' "$SCRIPT_DIR/t66-run-arm.sh"
grep -Fq 'WATCHDOG_DEADLINE=$((SECONDS+900))' "$SCRIPT_DIR/t66-run-arm.sh"
grep -Fq 'T66_CLUSTER_ACTION_AUTH' "$SCRIPT_DIR/t66-node-cluster.sh"
grep -Fq 'fallocate -l' "$SCRIPT_DIR/t66-storage-create-one.sh"
grep -Fq -- '-E nodiscard,lazy_itable_init=0,lazy_journal_init=0' "$SCRIPT_DIR/t66-storage-activate-arm.sh"
grep -Fq 't66_assert_allocated_file' "$SCRIPT_DIR/t66-storage-activate-arm.sh"
grep -Fq "printf '%s.deactivated-%s" "$SCRIPT_DIR/t66-storage-deactivate-arm.sh"
grep -Fq 'immutable_audit=' "$SCRIPT_DIR/t66-storage-deactivate-arm.sh"
grep -Fq 'immutable_audit=' "$SCRIPT_DIR/t66-storage-destroy-one.sh"
grep -Fq 'LOGS_TMPFS_SOURCE="t66-logs-' "$SCRIPT_DIR/t66-storage-deactivate-arm.sh"
grep -Fq 'READ_ONLY_SUDO_VOCABULARY=' "$SCRIPT_DIR/t66-sudo-plan.sh"
grep -Fq 'PREAUTHORIZED_BOUNDED_CEPH_MUTATION=' "$SCRIPT_DIR/t66-sudo-plan.sh"
grep -Fq 'storage.destroyed-${state_sha:0:16}.tsv' "$SCRIPT_DIR/t66-storage-destroy-one.sh"
if grep -Fq 't66_require_absent "$AUDIT"' "$SCRIPT_DIR/t66-storage-create-one.sh"; then echo 'historical storage audit incorrectly blocks post-canary recreation' >&2; exit 1; fi
if grep -Fq '! -e "$AUDIT"' "$SCRIPT_DIR/t66-storage-activate-arm.sh"; then echo 'historical audit incorrectly blocks reactivation' >&2; exit 1; fi
if grep -EnH -- 'truncate|dd[[:space:]]+if=|cp[[:space:]].*--sparse' "$SCRIPT_DIR"/t66-storage-*.sh; then echo 'sparse storage operation found' >&2; exit 1; fi

# Static safety scan. Exact file unlink/rmdir, exact PID TERM, and exact
# `systemctl stop/start tikv` are intentionally allowed by the contract.
if grep -EnH -- 'rm[[:space:]]+-rf|chown[[:space:]]+-R|chmod[[:space:]]+-R|losetup[[:space:]]+-D|wipefs|blkdiscard|fstrim|pkill|killall|fuser[[:space:]]+-k|umount[[:space:]]+-(l|f)|kill[[:space:]]+-(9|KILL)|(^|[[:space:]])(reboot|shutdown|poweroff)([[:space:]]|$)|drop_caches|ceph[[:space:]]+osd[[:space:]]+pool[[:space:]]+(delete|create)' "${ALL_FILES[@]/#/$SCRIPT_DIR/}" | grep -Ev 'printf|t66-gate0-offline\.sh:'; then
  printf 'forbidden command pattern found\n' >&2; exit 1
fi
if grep -EnH -- 'systemctl[[:space:]]+(stop|start)[[:space:]]+(pd|pd-server)|systemctl[[:space:]]+(restart|reboot|poweroff)' "${ALL_FILES[@]/#/$SCRIPT_DIR/}" | grep -Ev 'printf|t66-gate0-offline\.sh:'; then echo 'forbidden systemctl operation found' >&2; exit 1; fi
if grep -EnH -- 'Sunrise@|sshpass[[:space:]]+-p' "${ALL_FILES[@]/#/$SCRIPT_DIR/}" | grep -Ev 't66-gate0-offline\.sh:'; then echo 'embedded password found' >&2; exit 1; fi

# The append-only issue ledger and local autonomy control plane are mandatory.
AUTORUN=$(printf '19990101-%06d' "$((BASHPID % 1000000))")
bash "$SCRIPT_DIR/t66-autonomy.sh" init "$AUTORUN" >/dev/null
AUTOROOT="/tmp/production/opencode-t3.22c-${AUTORUN}"
printf 'fixture\n' > "$AUTOROOT/evidence.txt"
bash "$SCRIPT_DIR/t66-autonomy.sh" record "$AUTORUN" gate0 GLOBAL WARN fixture "$AUTOROOT/evidence.txt" none continue >/dev/null
[[ $(wc -l < "$AUTOROOT/control/incidents.tsv") -eq 3 ]]
bash "$SCRIPT_DIR/t66-autonomy.sh" status "$AUTORUN" | grep -Fq 'incident_rows=2'
if grep -EnH -- '(^|[[:space:]])(ssh|scp|sudo|systemctl|mount|losetup|mkfs|ceph|fio)([[:space:]]|$)' "$SCRIPT_DIR/t66-autonomy.sh" | grep -Ev '^[^:]+:[0-9]+:#'; then
  echo 'autonomy control plane contains environment action' >&2; exit 1
fi

# Phase-I scripts contain no remote mutation/upload. sudo is limited to
# read-only ceph/losetup inventory calls.
if grep -EnH -- 'scp|ssh[^#]*(mkdir|install|mount|fallocate|losetup --find|mkfs|unlink|systemctl)' "$SCRIPT_DIR/t66-inventory.sh"; then echo 'inventory remote mutation found' >&2; exit 1; fi
if grep -EnH -- '(^|[[:space:]])(eval|source)[[:space:]].*plan|bash[[:space:]].*storage|systemctl[[:space:]]' "$SCRIPT_DIR/t66-sudo-plan.sh" | grep -Ev 'printf'; then echo 'sudo-plan execution found' >&2; exit 1; fi

sha256sum "${ALL_FILES[@]/#/$SCRIPT_DIR/}"
printf '%s\n' '03-22c t66 Gate 0 offline tests: PASS'
