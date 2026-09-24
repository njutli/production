#!/bin/bash
set -euo pipefail

# Independent JuiceFS mount: validates the 8-worker client without touching /mnt/juicefs.
ACTION=${1:-}
MNT=/home/sunrise/lt-ceph8-canary-20260923
LOG=/home/sunrise/lt-ceph8-canary-20260923.log
JFS=/tmp/juicefs-1.4.1-patched
CONF=/home/sunrise/juicefs-ceph-msgr8.conf
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
MD5=24fae0852051c80ca571cb2f20275d46
UUID=e1b69ea9-0e3d-427d-bea9-8765928afa66
die() { printf 'CANARY_REFUSE %s\n' "$*" >&2; exit 42; }
[[ "$ACTION" == plan || "$ACTION" == execute || "$ACTION" == verify || "$ACTION" == umount ]] || die usage
[[ $(hostname) == oneasia-c1-cpu-node10 && $(id -u) == 1002 ]] || die wrong_host_or_user
[[ "$MNT" == /home/sunrise/lt-ceph8-canary-20260923 && ! -L "$MNT" ]] || die path_invalid
[[ -x "$JFS" && $(md5sum "$JFS" | awk '{print $1}') == "$MD5" ]] || die binary_mismatch
[[ -r "$CONF" && ! -L "$CONF" && $(ceph-conf --conf "$CONF" --name client.admin --lookup ms_async_op_threads) == 8 ]] || die conf_invalid
uuid=$("$JFS" status "$META" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("Setting") or d.get("Format") or d).get("UUID",""))') || die status_failed
[[ "$uuid" == "$UUID" ]] || die uuid_mismatch

if [[ "$ACTION" == plan ]]; then
  [[ ! -e "$MNT" ]] || die target_already_exists
  printf 'WILL_EXECUTE: mkdir -m 0700 %s\n' "$MNT"
  printf 'WILL_EXECUTE: CEPH_CONF=%s %s mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K --no-bgjob --backup-meta 0 --metrics 127.0.0.1:19568 %s %s\n' "$CONF" "$JFS" "$META" "$MNT"
  exit 0
fi

if [[ "$ACTION" == verify ]]; then
  [[ -d "$MNT" ]] || die mount_dir_missing
  options=$(findmnt -rn -M "$MNT" -o SOURCE,FSTYPE,OPTIONS) || die findmnt_failed
  [[ "$options" == *'JuiceFS:juicefs-prod fuse.juicefs '* ]] || die mount_identity_mismatch
  opts=${options##* }
  [[ ",$opts," == *,max_read=262144,* ]] || die fuse_max_read_mismatch
  workers_seen=0; matched=0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ $(readlink -f "/proc/$pid/exe" 2>/dev/null || true) == "$JFS" ]] || continue
    ((matched+=1))
    proc_conf=$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^CEPH_CONF=//p' | tail -n 1)
    [[ -z "$proc_conf" || "$proc_conf" == "$CONF" ]] || die process_conf_mismatch
    workers=$(ps -L -p "$pid" -o comm= | awk '/^msgr-worker-[0-9]+$/ {a[$0]=1} END {print length(a)}')
    [[ "$workers" == 0 || "$workers" == 8 ]] || die worker_count_mismatch
    [[ "$workers" == 8 ]] && workers_seen=1
    printf 'CANARY_PROCESS pid=%s workers=%s proc_conf=%s\n' "$pid" "$workers" "${proc_conf:-not_exposed}"
  done < <(pgrep -f 'juicefs.*mount.* /home/sunrise/lt-ceph8-canary-20260923' || true)
  [[ "$matched" -ge 1 && "$workers_seen" -eq 1 ]] || die worker_missing
  curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:19568/metrics >/dev/null || die metrics_unreachable
  echo 'CANARY_VERIFY_PASS'
  exit 0
fi

if [[ "$ACTION" == execute ]]; then
  [[ ${LT_CANARY_ACK:-} == I_ACK_157_CEPH8_CANARY ]] || die execute_ack_missing
  [[ ! -e "$MNT" ]] || die target_already_exists
  mkdir -m 0700 -- "$MNT"
  CEPH_CONF="$CONF" timeout 120 "$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K --no-bgjob --backup-meta 0 --metrics 127.0.0.1:19568 --log "$LOG" "$META" "$MNT" || die mount_failed_preserve_scene
  bash "$0" verify
  exit 0
fi

[[ "$ACTION" == umount ]] || die action_invalid
[[ ${LT_CANARY_ACK:-} == I_ACK_157_CEPH8_CANARY ]] || die umount_ack_missing
bash "$0" verify
timeout 90 "$JFS" umount --flush "$MNT" || die graceful_umount_failed
if mountpoint -q "$MNT"; then die mount_still_active; fi
echo 'CANARY_UMOUNT_PASS (directory and log retained)'
