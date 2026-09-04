#!/usr/bin/env bash
# Exact production test-mount lifecycle used only around the 04-2 TiKV window.
set -euo pipefail
export LC_ALL=C

ACTION=${1:-}
RUN_ID=${2:-}
[[ $RUN_ID =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo 'invalid RUN_ID' >&2; exit 42; }
ROOT="/tmp/production/opencode-04-2-$RUN_ID"
OUT="$ROOT/production-mount"
JFS=/tmp/juicefs-1.4.1-patched
JFS_MD5=24fae0852051c80ca571cb2f20275d46
MNT=/mnt/juicefs
META='tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod'

die() { printf 'E_S04A1_PROD_MOUNT\t%s\n' "$*" >&2; exit 42; }
binary_guard() { [[ $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die 'binary MD5 mismatch'; }
mounted_guard() {
  local src target fs
  read -r src target fs < <(findmnt -rn -M "$MNT" -o SOURCE,TARGET,FSTYPE)
  [[ $src == JuiceFS:juicefs-prod && $target == "$MNT" && $fs == fuse.juicefs ]] || die 'mount identity mismatch'
}
services_guard() {
  local n
  for n in 10.20.1.150 10.20.1.151 10.20.1.152; do
    [[ $(ssh -o BatchMode=yes -o ConnectTimeout=8 sunrise@$n 'systemctl is-active pd 2>/dev/null || true') == active ]] || die "PD inactive: $n"
    [[ $(ssh -o BatchMode=yes -o ConnectTimeout=8 sunrise@$n 'systemctl is-active tikv 2>/dev/null || true') == active ]] || die "TiKV inactive: $n"
  done
}

case "$ACTION" in
  plan)
    printf 'PLAN_ONLY\nUNMOUNT=%q umount %q\nREMOUNT=%q mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K %q %q\n' "$JFS" "$MNT" "$JFS" "$META" "$MNT"
    ;;
  unmount)
    [[ ${S04A1_PROD_MOUNT_AUTH:-} == "04-2-prod-unmount-$RUN_ID" ]] || die 'exact unmount auth missing'
    binary_guard; mounted_guard
    mkdir -p "$OUT"
    "$JFS" status "$META" > "$OUT/status-before-unmount.json"
    "$JFS" umount "$MNT" > "$OUT/umount.stdout" 2> "$OUT/umount.stderr"
    ! findmnt -rn -M "$MNT" >/dev/null 2>&1 || die 'mount remains after umount'
    printf '%s\n' "$(date +%s)" > "$OUT/UNMOUNT_PASS"
    printf 'PROD_TEST_MOUNT_UNMOUNT_PASS\n'
    ;;
  remount)
    [[ ${S04A1_PROD_MOUNT_AUTH:-} == "04-2-prod-remount-$RUN_ID" ]] || die 'exact remount auth missing'
    binary_guard; services_guard
    [[ ! -e $MNT ]] || { [[ -d $MNT && ! -L $MNT ]] || die 'mount path unsafe'; }
    mkdir -p "$MNT" "$OUT"
    ! findmnt -rn -M "$MNT" >/dev/null 2>&1 || die 'mount already active'
    "$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "$META" "$MNT" > "$OUT/remount.stdout" 2> "$OUT/remount.stderr"
    sleep 5; mounted_guard
    "$JFS" status "$META" > "$OUT/status-after-remount.json"
    printf '%s\n' "$(date +%s)" > "$OUT/REMOUNT_PASS"
    printf 'PROD_TEST_MOUNT_REMOUNT_PASS\n'
    ;;
  verify)
    binary_guard; mounted_guard; services_guard; printf 'PROD_TEST_MOUNT_VERIFY_PASS\n'
    ;;
  *) die 'usage: s04a1-prod-mount.sh plan|unmount|remount|verify RUN_ID' ;;
esac
