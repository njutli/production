#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

RUN_ID=${1:-}
if [[ $RUN_ID == --self-test ]]; then
  grep -Fq 'for build in C T' "$0"
  grep -Fq -- '--readonly' "$0"
  grep -Fq 'allow_file_create=0' "$0"
  ! grep -Eq 'sudo|juicefs[[:space:]]+gc|drop_caches|compact|rm[[:space:]]+-rf|umount[[:space:]]+-l|fusermount[[:space:]]+-u[z]|pkill|killall|fuser[[:space:]]+-k' "$0"
  printf 'T062B_SMOKE_SELF_TEST_PASS\n'
  exit 0
fi
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo invalid_run >&2; exit 42; }
ROOT=/tmp/production/opencode-06-2b-$RUN_ID
OUT=$ROOT/smoke
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
CEPH_CONF=/etc/ceph/ceph.conf
[[ -d $ROOT && ! -L $ROOT && ! -e $OUT ]] || { echo invalid_root_or_output >&2; exit 42; }
mkdir -m 0700 -- "$OUT"
findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference.before"

for build in C T; do
  case $build in
    C) jfs=$ROOT/bin/juicefs-06-2b-c; md5=4ea96bfb923733555221279d0a71083e; sha=b713e595a0fd320217913617098e91107de065285860498079e1777a61b2bbbc; port=19670 ;;
    T) jfs=$ROOT/bin/juicefs-06-2b-t; md5=2f28b8a4fefa78dc95dfaa8b91f72844; sha=4ffd69637d43a1c33725f540124e7569957cf1c6541cea7fc49b0fa3bf38a4b2; port=19671 ;;
  esac
  cell=$OUT/$build
  mnt=/tmp/jfs-06-2b-$RUN_ID-smoke-$build
  [[ -x $jfs && ! -L $jfs && $(md5sum "$jfs" | awk '{print $1}') == "$md5" && $(sha256sum "$jfs" | awk '{print $1}') == "$sha" ]] || { echo binary_$build >&2; exit 42; }
  [[ ! -e $mnt && ! -L $mnt ]] || { echo mount_path_$build >&2; exit 42; }
  mkdir -m 0700 -- "$cell" "$mnt"
  "$jfs" mount -d --max-fuse-io 256K --buffer-size 300 --max-uploads 150 --max-downloads 200 \
    --metrics "127.0.0.1:$port" --log "$cell/juicefs.log" --cache-size 0 "$META" "$mnt" \
    >"$cell/mount.stdout" 2>"$cell/mount.stderr"
  for _ in $(seq 1 90); do mountpoint -q "$mnt" && break; sleep 1; done
  mountpoint -q "$mnt" || { echo mount_timeout_$build >&2; exit 42; }
  findmnt -rn -M "$mnt" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$cell/findmnt.tsv"
  find -P "$mnt/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$cell/assets.tsv"
  [[ $(wc -l <"$cell/assets.tsv") -eq 128 ]] || { echo assets_$build >&2; exit 42; }
  timeout 120 fio --name=smoke-read \
    --filename="$mnt/test_dir/rw_test.0.0:$mnt/test_dir/rw_test.31.0:$mnt/test_dir/rw_test.63.0:$mnt/test_dir/rw_test.127.0" \
    --rw=read --bs=256K --size=4M --direct=1 --ioengine=libaio --iodepth=1 --numjobs=1 \
    --group_reporting --readonly --allow_file_create=0 --fallocate=none \
    --output="$cell/fio.json" --output-format=json >"$cell/fio.stdout" 2>"$cell/fio.stderr"
  "$jfs" umount "$mnt" >"$cell/umount.stdout" 2>"$cell/umount.stderr"
  for _ in $(seq 1 90); do mountpoint -q "$mnt" || break; sleep 1; done
  mountpoint -q "$mnt" && { echo umount_timeout_$build >&2; exit 42; }
  rmdir -- "$mnt"
  printf 'SMOKE_PASS\n' >"$cell/PASS"
done
findmnt -rn -T /mnt/juicefs -o SOURCE,TARGET,FSTYPE,OPTIONS >"$OUT/reference.after"
cmp -s "$OUT/reference.before" "$OUT/reference.after" || { echo reference_changed >&2; exit 42; }
(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
printf 'T062B_SMOKE_PASS\n'
