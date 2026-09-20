#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
if [[ $RUN_ID == --self-test ]]; then
  grep -Fq 'ROOT=/tmp/production/opencode-06-2-${RUN_ID}' "$0"
  grep -Fq 'juicefs-gate3-baseline' "$0"
  grep -Fq 'juicefs-gate3-patched' "$0"
  grep -Fq 'gate3-fuse-regression' "$0"
  ! grep -Eq 'sudo|reboot|shutdown|halt|poweroff|rm[[:space:]]+-|fusermount[[:space:]]+-u[z]|umount[[:space:]]+-l|pkill|killall|fuser[[:space:]]+-k' "$0"
  printf 'T062_GATE3_SEMANTIC_SELF_TEST_PASS\n'
  exit 0
fi

ROOT=/tmp/production/opencode-06-2-${RUN_ID}
OUT=${ROOT}/gate3-semantic
HELPER=${ROOT}/bin/gate3-fuse-regression
BASELINE=${ROOT}/bin/juicefs-gate3-baseline
PATCHED=${ROOT}/bin/juicefs-gate3-patched
BASELINE_SHA=50533485977e187146c53b2cf2497b929df70b590a8a6b655a32c9e8c8d94dc9
PATCHED_SHA=a83343bc62e023f090a99d37872665516429765055968349de6eaefb2a81fc76

die() { printf 'T062_GATE3_SEMANTIC_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
[[ $ROOT == /tmp/production/opencode-06-2-${RUN_ID} && -d $ROOT && ! -L $ROOT ]] || die invalid_root
[[ ! -e $OUT && ! -L $OUT ]] || die output_already_exists
[[ -x $HELPER && ! -L $HELPER ]] || die helper_identity
[[ -x $BASELINE && ! -L $BASELINE && $(sha256sum "$BASELINE" | awk '{print $1}') == "$BASELINE_SHA" ]] || die baseline_identity
[[ -x $PATCHED && ! -L $PATCHED && $(sha256sum "$PATCHED" | awk '{print $1}') == "$PATCHED_SHA" ]] || die patched_identity
mkdir -m 0700 "$OUT"

exact_pids() {
  local bin=$1 proc
  for proc in /proc/[0-9]*; do
    [[ -e $proc/exe ]] || continue
    [[ $(readlink -f "$proc/exe" 2>/dev/null || true) == "$bin" ]] && basename "$proc"
  done | sort -n
}

findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.before.tsv"
ceph -s -f json >"$OUT/ceph.before.json"

step=0
for arm in B T; do
  step=$((step + 1))
  if [[ $arm == B ]]; then bin=$BASELINE; else bin=$PATCHED; fi
  cell=${OUT}/cell-${arm}
  mnt=/tmp/jfs-06-2-${RUN_ID}-gate3-${arm}
  meta=sqlite3://${cell}/meta.db
  bucket=${cell}/objects
  metrics=$((19650 + step))
  [[ ! -e $cell && ! -L $cell ]] || die cell_exists_${arm}
  [[ ! -e $mnt && ! -L $mnt ]] || die mount_exists_${arm}
  mkdir -m 0700 "$cell" "$bucket" "$mnt"
  exact_pids "$bin" >"$cell/pids.before"
  sha256sum "$bin" >"$cell/binary.sha256"
  "$bin" version >"$cell/version.txt" 2>&1
  "$bin" format --storage file --bucket "$bucket" --trash-days 0 "$meta" "gate3-${arm,,}-${RUN_ID}" \
    >"$cell/format.stdout" 2>"$cell/format.stderr"
  "$bin" mount -d --cache-size 0 --metrics "127.0.0.1:${metrics}" --log "$cell/mount.log" \
    "$meta" "$mnt" >"$cell/mount.stdout" 2>"$cell/mount.stderr"
  for _ in $(seq 1 60); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout_${arm}
  findmnt -rn -T "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$cell/findmnt.tsv"
  "$HELPER" "$mnt" >"$cell/regression.tsv" 2>"$cell/regression.stderr" || die regression_${arm}
  for r in R1 R2 R3 R4 R5 R6 R7 R8; do
    grep -Fq "$r"$'\tPASS' "$cell/regression.tsv" || die missing_${r}_${arm}
  done
  "$bin" umount "$mnt" >"$cell/umount.stdout" 2>"$cell/umount.stderr"
  for _ in $(seq 1 60); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains_${arm}
  rmdir "$mnt"
  "$bin" fsck "$meta" >"$cell/fsck.stdout" 2>"$cell/fsck.stderr" || die fsck_${arm}
  exact_pids "$bin" >"$cell/pids.after"
  cmp -s "$cell/pids.before" "$cell/pids.after" || die process_leak_${arm}
done

findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.after.tsv"
cmp -s "$OUT/reference-mount.before.tsv" "$OUT/reference-mount.after.tsv" || die reference_mount_changed
ceph -s -f json >"$OUT/ceph.after.json"
python3 - "$OUT/ceph.before.json" "$OUT/ceph.after.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    status = json.load(open(path)).get("health", {}).get("status")
    if status != "HEALTH_OK":
        raise SystemExit(f"health gate failed: {path}: {status}")
PY
(cd "$OUT" && find . -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
printf 'T062_GATE3_SEMANTIC_PASS\tarms=B,T\tR=1-8,R10\n'
