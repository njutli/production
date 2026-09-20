#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

RUN_ID=${1:-}
if [[ $RUN_ID == --self-test ]]; then
  grep -Fq 'META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod' "$0"
  grep -Fq 'OLD_MD5=24fae0852051c80ca571cb2f20275d46' "$0"
  grep -Fq 'NEW_MD5=1eb79575f654c77c14aa212c2b6c478d' "$0"
  grep -Fq 'for arm in NEW OLD NEW' "$0"
  ! grep -Eq 'fusermount[[:space:]]+-u[z]|umount[[:space:]]+-l|rm[[:space:]]+-rf|pkill|killall|fuser[[:space:]]+-k' "$0"
  printf 'T062_P0_SELF_TEST_PASS\n'
  exit 0
fi
ROOT=/tmp/production/opencode-06-2-${RUN_ID}
OUT=${ROOT}/p0-smoke
NEW=${ROOT}/bin/juicefs-v1.4.1-b-catchup-baseline
OLD=/tmp/juicefs-1.4.1-patched
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
NEW_MD5=1eb79575f654c77c14aa212c2b6c478d
OLD_MD5=24fae0852051c80ca571cb2f20275d46

die() { printf 'T062_P0_FAIL\t%s\n' "$*" >&2; exit 42; }
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || die invalid_run_id
[[ $ROOT == /tmp/production/opencode-06-2-${RUN_ID} && -d $ROOT && ! -L $ROOT ]] || die invalid_root
[[ -x $NEW && ! -L $NEW && $(md5sum "$NEW" | awk '{print $1}') == "$NEW_MD5" ]] || die new_binary_identity
[[ -x $OLD && ! -L $OLD && $(md5sum "$OLD" | awk '{print $1}') == "$OLD_MD5" ]] || die old_binary_identity
[[ ! -e $OUT ]] || die output_already_exists
mkdir -m 0700 "$OUT"

exact_pids() {
  local bin=$1 proc
  for proc in /proc/[0-9]*; do
    [[ -e $proc/exe ]] || continue
    [[ $(readlink -f "$proc/exe" 2>/dev/null || true) == "$bin" ]] && basename "$proc"
  done | sort -n
}

normalize_status() {
  local raw=$1 out=$2
  python3 - "$raw" "$out" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
start = text.find("{")
if start < 0:
    raise SystemExit("status JSON missing")
data, _ = json.JSONDecoder().raw_decode(text[start:])
setting = data.get("Setting", {})
keys = ("UUID", "BlockSize", "Compression", "TrashDays", "Storage", "Bucket")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for key in keys:
        f.write(f"{key}\t{json.dumps(setting.get(key), sort_keys=True)}\n")
PY
}

findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.before.tsv"
ceph -s -f json >"$OUT/ceph.before.json"

step=0
for arm in NEW OLD NEW; do
  step=$((step + 1))
  if [[ $arm == NEW ]]; then bin=$NEW; else bin=$OLD; fi
  label=${step}-${arm}
  mnt=/tmp/jfs-06-2-${RUN_ID}-p0-${label}
  metrics=$((19630 + step))
  [[ ! -e $mnt && ! -L $mnt ]] || die mount_path_exists_${label}
  exact_pids "$bin" >"$OUT/${label}.pids.before"
  "$bin" version >"$OUT/${label}.version.txt" 2>&1
  "$bin" status "$META" >"$OUT/${label}.status.raw" 2>&1
  normalize_status "$OUT/${label}.status.raw" "$OUT/${label}.status.tsv"
  mkdir -m 0700 "$mnt"
  "$bin" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 \
    --max-downloads 200 --cache-size 0 --metrics "127.0.0.1:${metrics}" \
    --log "$OUT/${label}.mount.log" "$META" "$mnt" \
    >"$OUT/${label}.mount.stdout" 2>"$OUT/${label}.mount.stderr"
  for _ in $(seq 1 60); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || die mount_timeout_${label}
  findmnt -rn -T "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/${label}.findmnt.tsv"
  stat -Lc '%d\t%i\t%f\t%u\t%g\t%n' "$mnt" "$mnt/test_dir" >"$OUT/${label}.readonly-stat.tsv"
  find -P "$mnt/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%s\n' \
    | sort -V >"$OUT/${label}.assets.tsv"
  [[ $(wc -l <"$OUT/${label}.assets.tsv") -eq 128 ]] || die asset_count_${label}
  awk -F '\t' '$2 != 1073741824 {bad++} END {exit bad ? 1 : 0}' "$OUT/${label}.assets.tsv" \
    || die asset_size_${label}
  "$bin" umount "$mnt" >"$OUT/${label}.umount.stdout" 2>"$OUT/${label}.umount.stderr"
  for _ in $(seq 1 60); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && die mount_remains_${label}
  rmdir "$mnt"
  exact_pids "$bin" >"$OUT/${label}.pids.after"
  cmp -s "$OUT/${label}.pids.before" "$OUT/${label}.pids.after" || die process_leak_${label}
done

cmp -s "$OUT/1-NEW.status.tsv" "$OUT/2-OLD.status.tsv" || die settings_mismatch_new_old
cmp -s "$OUT/1-NEW.status.tsv" "$OUT/3-NEW.status.tsv" || die settings_mismatch_new_new
findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference-mount.after.tsv"
cmp -s "$OUT/reference-mount.before.tsv" "$OUT/reference-mount.after.tsv" || die reference_mount_changed
ceph -s -f json >"$OUT/ceph.after.json"
python3 - "$OUT/ceph.before.json" "$OUT/ceph.after.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    d = json.load(open(path))
    if d.get("health", {}).get("status") != "HEALTH_OK":
        raise SystemExit(f"health gate failed: {path}")
PY
(cd "$OUT" && sha256sum ./* >SHA256SUMS)
printf 'P0_COMPATIBILITY_PASS\tsequence=NEW-OLD-NEW\tassets=128x1GiB\n'
