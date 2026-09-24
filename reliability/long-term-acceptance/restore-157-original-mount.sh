#!/bin/bash
set -euo pipefail

# Restore only the pre-2026-09-23 JuiceFS client mount on 157.
# No sudo, no cluster configuration changes, no deletion.
ACTION=${1:-}
MNT=/mnt/juicefs
JFS=/tmp/juicefs-1.4.1-patched
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
PRIVATE_CONF=/home/sunrise/juicefs-ceph-msgr8.conf
AUDIT=/home/sunrise/lt-restore-157-original-20260923.audit.log
JFS_MD5=24fae0852051c80ca571cb2f20275d46
UUID=e1b69ea9-0e3d-427d-bea9-8765928afa66
FSID=f8137e5a-8af2-11f1-aa1c-4df480fc234d
die() { printf 'RESTORE_REFUSE %s\n' "$*" >&2; exit 42; }

[[ "$ACTION" == plan || "$ACTION" == execute || "$ACTION" == verify ]] || die usage
[[ $(hostname) == oneasia-c1-cpu-node10 && $(id -u) == 1002 ]] || die wrong_host_or_user
[[ "$MNT" == /mnt/juicefs && -d "$MNT" && ! -L "$MNT" ]] || die target_path_invalid
[[ -x "$JFS" && ! -L "$JFS" && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die binary_mismatch
[[ -r "$PRIVATE_CONF" && ! -L "$PRIVATE_CONF" ]] || die fallback_conf_missing
[[ $(sha256sum "$PRIVATE_CONF" | awk '{print $1}') == c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48 ]] || die fallback_conf_mismatch
[[ $(ceph --conf /etc/ceph/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin config get client ms_async_op_threads) == 3 ]] || die original_effective_conf_not_three
[[ $(ceph --conf /etc/ceph/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin fsid) == "$FSID" ]] || die ceph_fsid_mismatch

check_mount() {
  local source fstype opts
  read -r source fstype opts < <(findmnt -rn -M "$MNT" -o SOURCE,FSTYPE,OPTIONS) || die mount_missing
  [[ "$source" == JuiceFS:juicefs-prod && "$fstype" == fuse.juicefs && ",$opts," == *,max_read=262144,* ]] || die mount_identity_mismatch
  python3 - "$MNT/.config" "$UUID" <<'PY' || die volume_identity_mismatch
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get('Setting') or d.get('Format') or d
raise SystemExit(0 if s and s.get('UUID') == sys.argv[2] and s.get('BlockSize') == 256 else 7)
PY
}

check_workers() {
  local expected=$1 pid cmd md5 workers seen=0 active=0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || continue
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ "$cmd" == "$JFS mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K $META $MNT"* ]] || continue
    md5=$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')
    [[ "$md5" == "$JFS_MD5" ]] || die process_binary_mismatch
    workers=$(ps -L -p "$pid" -o comm= | awk '/^msgr-worker-[0-9]+$/ {a[$0]=1} END {print length(a)}')
    [[ "$workers" == 0 || "$workers" == "$expected" ]] || die "unexpected_workers_pid_${pid}_count_${workers}"
    [[ "$workers" == "$expected" ]] && active=1
    seen=$((seen+1))
    printf 'PROCESS pid=%s workers=%s\n' "$pid" "$workers"
  done < <(pgrep -f 'juicefs.*mount.* /mnt/juicefs' || true)
  [[ "$seen" -ge 1 && "$active" -eq 1 ]] || die "expected_${expected}_worker_process_missing"
}

check_health() {
  ceph --conf /etc/ceph/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin -s | grep -Fq HEALTH_OK || die ceph_unhealthy
}

check_mount
if [[ "$ACTION" == verify ]]; then
  check_workers 3
  curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:9567/metrics >/dev/null || die metrics_unreachable
  check_health
  echo RESTORE_VERIFY_PASS
  exit 0
fi

check_workers 8
[[ -z $(pgrep -x fio || true) ]] || die fio_running
set +e
fuser_output=$(fuser -m "$MNT" 2>&1); fuser_rc=$?
set -e
[[ "$fuser_rc" -eq 1 && -z "$fuser_output" ]] || die "mount_in_use_or_fuser_failed_rc_${fuser_rc}_output_${fuser_output}"
check_health
curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:9567/metrics |
  python3 -c 'import sys
wanted={"juicefs_staging_blocks","juicefs_staging_block_bytes","juicefs_staging_writing_blocks","juicefs_object_request_uploading"}; seen=set()
for line in sys.stdin:
    name=line.split("{",1)[0].split(" ",1)[0]
    if name in wanted:
        seen.add(name)
        if float(line.rsplit(" ",1)[-1]) != 0: raise SystemExit(7)
raise SystemExit(0 if seen==wanted else 7)' || die staging_not_drained

printf 'RESTORE_PLAN host=%s user=%s mount=%s uuid=%s current_workers=8 target_workers=3\n' "$(hostname)" "$(id -un)" "$MNT" "$UUID"
printf 'WILL_EXECUTE: %s umount --flush %s\n' "$JFS" "$MNT"
printf 'WILL_EXECUTE: env -u CEPH_CONF %s mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K %s %s\n' "$JFS" "$META" "$MNT"
printf 'ON_MOUNT_FAILURE: restore previous 8-worker mount with exact private config\n'
if [[ "$ACTION" == plan ]]; then exit 0; fi

[[ ${LT_RESTORE_ACK:-} == I_ACK_157_ORIGINAL_MOUNT ]] || die execute_ack_missing
[[ ! -e "$AUDIT" && ! -L "$AUDIT" ]] || die audit_target_exists
[[ $(df -B1 --output=avail /home/sunrise | awk 'NR==2{print $1}') -ge 1073741824 ]] || die audit_space_low
( set -C; : >"$AUDIT" ) || die audit_create_failed
chmod 0600 "$AUDIT"
printf '%s\tPRE_UMOUNT\n' "$(date -Is)" >>"$AUDIT"
timeout 90 "$JFS" umount --flush "$MNT" || die graceful_umount_failed
mountpoint -q "$MNT" && die mount_still_active
for ((i=0; i<30; i++)); do
  if ! ss -lnt | grep -q '127.0.0.1:9567 '; then break; fi
  sleep 1
done
ss -lnt | grep -q '127.0.0.1:9567 ' && die metrics_port_still_bound

printf '%s\tMOUNT_ORIGINAL_BEGIN\n' "$(date -Is)" >>"$AUDIT"
set +e
timeout 120 env -u CEPH_CONF "$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "$META" "$MNT" >>"$AUDIT" 2>&1
rc=$?
set -e
printf '%s\tMOUNT_ORIGINAL_RC\t%s\n' "$(date -Is)" "$rc" >>"$AUDIT"
if (( rc != 0 )); then
  mountpoint -q "$MNT" && die original_mount_failed_but_mount_present_preserve_scene
  printf '%s\tFALLBACK_EIGHT_BEGIN\n' "$(date -Is)" >>"$AUDIT"
  CEPH_CONF="$PRIVATE_CONF" timeout 120 "$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "$META" "$MNT" >>"$AUDIT" 2>&1 || die original_and_fallback_mount_failed
  check_mount
  check_workers 8
  die original_mount_failed_fallback_eight_restored
fi
bash "$0" verify || die original_mount_verify_failed_preserve_scene
printf '%s\tRESTORE_PASS\tworkers=3\n' "$(date -Is)" >>"$AUDIT"
echo RESTORE_PASS
