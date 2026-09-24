#!/bin/bash
set -euo pipefail

# Operator-held recovery: only mounts the exact JuiceFS volume if /mnt/juicefs is absent.
ACTION=${1:-}
MNT=/mnt/juicefs
JFS=/tmp/juicefs-1.4.1-patched
CONF=/home/sunrise/juicefs-ceph-msgr8.conf
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
VERIFY=/tmp/remount-157-ceph8-20260923.sh
die() { printf 'RECOVERY_REFUSE %s\n' "$*" >&2; exit 42; }
[[ "$ACTION" == plan || "$ACTION" == execute ]] || die usage
[[ $(hostname) == oneasia-c1-cpu-node10 && $(id -u) == 1002 ]] || die wrong_host_or_user
[[ "$MNT" == /mnt/juicefs && -d "$MNT" && ! -L "$MNT" ]] || die mount_path_invalid
[[ -x "$JFS" && $(md5sum "$JFS" | awk '{print $1}') == 24fae0852051c80ca571cb2f20275d46 ]] || die binary_mismatch
[[ -r "$CONF" && ! -L "$CONF" && $(sha256sum "$CONF" | awk '{print $1}') == c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48 ]] || die conf_mismatch
[[ -r "$VERIFY" && ! -L "$VERIFY" ]] || die verify_script_missing
uuid=$("$JFS" status "$META" 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("Setting") or d.get("Format") or d).get("UUID",""))') || die volume_status_failed
[[ "$uuid" == e1b69ea9-0e3d-427d-bea9-8765928afa66 ]] || die volume_uuid_mismatch
printf 'RECOVERY_PLAN: only if %s is unmounted; CEPH_CONF=%s %s mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K %s %s\n' "$MNT" "$CONF" "$JFS" "$META" "$MNT"
if [[ "$ACTION" == plan ]]; then exit 0; fi
[[ ${LT_RECOVERY_ACK:-} == I_ACK_157_JFS_RECOVERY ]] || die execute_ack_missing
if mountpoint -q "$MNT"; then
  echo 'RECOVERY_NO_ACTION: mount already exists; inspect before any change'
  exit 0
fi
if ss -lnt | grep -q '127.0.0.1:9567 '; then die metrics_port_bound; fi
CEPH_CONF="$CONF" timeout 120 "$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "$META" "$MNT" || die mount_failed_preserve_scene
bash "$VERIFY" verify || die mounted_but_verify_failed_preserve_scene
echo 'RECOVERY_MOUNT_PASS'
