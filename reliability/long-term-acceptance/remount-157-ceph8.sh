#!/bin/bash
set -euo pipefail

# Only the known JuiceFS mount on 157. No sudo and no unrelated service action.
ACTION=${1:-}
MNT=/mnt/juicefs
JFS=/tmp/juicefs-1.4.1-patched
CONF=/home/sunrise/juicefs-ceph-msgr8.conf
META=tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod
JFS_MD5=24fae0852051c80ca571cb2f20275d46
CONF_SHA=c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48
UUID=e1b69ea9-0e3d-427d-bea9-8765928afa66
FSID=f8137e5a-8af2-11f1-aa1c-4df480fc234d
AUDIT=/home/sunrise/lt-remount-157-20260923.audit.log
die() { printf 'REMOUNT_REFUSE %s\n' "$*" >&2; exit 42; }

[[ "$ACTION" == plan || "$ACTION" == execute || "$ACTION" == verify ]] || die usage
for tool in awk ceph ceph-conf curl date df findmnt fuser grep md5sum mountpoint pgrep ps python3 readlink sha256sum sleep ss timeout tr; do
  command -v "$tool" >/dev/null || die "missing_tool_${tool}"
done
[[ $(hostname) == oneasia-c1-cpu-node10 && $(id -u) == 1002 ]] || die wrong_host_or_user
[[ "$MNT" == /mnt/juicefs && -d "$MNT" && ! -L "$MNT" ]] || die mount_path_invalid
[[ -x "$JFS" && ! -L "$JFS" && $(md5sum "$JFS" | awk '{print $1}') == "$JFS_MD5" ]] || die binary_mismatch
[[ -r "$CONF" && ! -L "$CONF" && $(sha256sum "$CONF" | awk '{print $1}') == "$CONF_SHA" ]] || die private_conf_mismatch
[[ $(ceph-conf --conf "$CONF" --name client.admin --lookup ms_async_op_threads) == 8 ]] || die private_conf_threads_mismatch
[[ $(ceph --conf "$CONF" --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin fsid) == "$FSID" ]] || die ceph_fsid_mismatch

check_mount() {
  local source fstype opts
  read -r source fstype opts < <(findmnt -rn -M "$MNT" -o SOURCE,FSTYPE,OPTIONS) || die mount_missing
  [[ "$source" == JuiceFS:juicefs-prod && "$fstype" == fuse.juicefs ]] || die mount_identity_mismatch
  python3 - "$opts" <<'PY' || die fuse_max_read_mismatch
import sys
values=[x.partition('=')[2] for x in sys.argv[1].split(',') if x.startswith('max_read=')]
raise SystemExit(0 if values == ['262144'] else 7)
PY
  [[ -r "$MNT/.config" ]] || die mounted_volume_config_unreadable
  python3 - "$MNT/.config" "$UUID" <<'PY' || die mounted_volume_mismatch
import json,sys
d=json.load(open(sys.argv[1])); x=d.get('Format') or d.get('Setting') or d
raise SystemExit(0 if x.get('UUID') == sys.argv[2] and x.get('BlockSize') == 256 else 7)
PY
}

check_processes() {
  local expected=$1 pid cmd proc_md5 workers n=0 valid=0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ -r "/proc/$pid/cmdline" ]] || die process_cmdline_unreadable
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ "$cmd" == "$JFS mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K $META $MNT"* ]] || continue
    ((n+=1))
    proc_md5=$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')
    [[ "$proc_md5" == "$JFS_MD5" ]] || die process_binary_mismatch
    workers=$(ps -L -p "$pid" -o comm= 2>/dev/null | awk '/^msgr-worker-[0-9]+$/ {a[$0]=1} END {print length(a)}')
    [[ "$workers" == 0 || "$workers" == "$expected" ]] || die "unexpected_worker_count_pid_${pid}_count_${workers}"
    [[ "$workers" == "$expected" ]] && valid=1
    printf 'PROCESS pid=%s starttime=%s workers=%s\n' "$pid" "$(awk '{print $22}' "/proc/$pid/stat")" "$workers"
  done < <(pgrep -f 'juicefs.*mount.* /mnt/juicefs' || true)
  [[ "$n" -ge 1 && "$valid" -eq 1 ]] || die expected_mount_worker_missing
}

check_no_external_users() {
  local output rc
  command -v fuser >/dev/null || die fuser_missing
  set +e
  output=$(fuser -m "$MNT" 2>&1); rc=$?
  set -e
  if [[ "$rc" -eq 1 && -z "$output" ]]; then return 0; fi
  [[ "$rc" -eq 0 && -n "$output" ]] && die "mount_busy_pids_${output}"
  die "fuser_check_failed_rc_${rc}_output_${output}"
}

check_mount
if [[ "$ACTION" == verify ]]; then
  check_processes 8
  curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:9567/metrics >/dev/null || die metrics_unreachable
  echo 'REMOUNT_VERIFY_PASS workers=8'
  exit 0
fi

check_processes 3
[[ -z $(pgrep -x fio || true) ]] || die fio_running
check_no_external_users
ceph --conf "$CONF" --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin -s | grep -Fq HEALTH_OK || die ceph_unhealthy
curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:9567/metrics |
  python3 -c 'import sys; wanted={"juicefs_staging_blocks","juicefs_staging_block_bytes","juicefs_staging_writing_blocks","juicefs_object_request_uploading"}; seen=set()
for line in sys.stdin:
    name=line.split("{",1)[0].split(" ",1)[0]
    if name in wanted:
        seen.add(name)
        if float(line.rsplit(" ",1)[-1]) != 0: raise SystemExit(7)
raise SystemExit(0 if seen==wanted else 7)' || die staging_not_drained

printf 'REMOUNT_PLAN host=%s user=%s path=%s uuid=%s private_conf_sha=%s\n' "$(hostname)" "$(id -un)" "$MNT" "$UUID" "$CONF_SHA"
printf 'WILL_EXECUTE: %s umount --flush %s\n' "$JFS" "$MNT"
printf 'WILL_EXECUTE: CEPH_CONF=%s %s mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K %s %s\n' "$CONF" "$JFS" "$META" "$MNT"
if [[ "$ACTION" == plan ]]; then exit 0; fi
[[ ${LT_REMOUNT_ACK:-} == I_ACK_157_JFS_CEPH8 ]] || die execute_ack_missing
[[ ! -e "$AUDIT" && ! -L "$AUDIT" ]] || die audit_target_exists_or_symlink
[[ $(df -B1 --output=avail /home/sunrise | awk 'NR==2{print $1}') -ge 1073741824 ]] || die audit_filesystem_low_space
( set -C; : >"$AUDIT" ) || die audit_create_failed
chmod 0600 "$AUDIT"

printf '%s\tPRE_UMOUNT\tconf_sha=%s\n' "$(date -Is)" "$CONF_SHA" >>"$AUDIT"
timeout 90 "$JFS" umount --flush "$MNT" || die graceful_umount_failed
mountpoint -q "$MNT" && die mount_still_active
for ((i=0; i<30; i++)); do
  if ! ss -lnt | grep -q '127.0.0.1:9567 '; then break; fi
  sleep 1
done
if ss -lnt | grep -q '127.0.0.1:9567 '; then die metrics_port_still_bound_after_umount; fi
[[ $(sha256sum "$CONF" | awk '{print $1}') == "$CONF_SHA" ]] || die private_conf_changed_after_umount

printf '%s\tMOUNT_BEGIN\tCEPH_CONF=%s\n' "$(date -Is)" "$CONF" >>"$AUDIT"
set +e
CEPH_CONF="$CONF" timeout 120 "$JFS" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io 256K "$META" "$MNT" >>"$AUDIT" 2>&1
rc=$?
set -e
printf '%s\tMOUNT_RC\t%s\n' "$(date -Is)" "$rc" >>"$AUDIT"
[[ "$rc" -eq 0 ]] || die "new_mount_failed_rc_${rc}_scene_preserved"
[[ $(sha256sum "$CONF" | awk '{print $1}') == "$CONF_SHA" ]] || die private_conf_changed_after_mount
bash "$0" verify || die new_mount_verify_failed_scene_preserved
printf '%s\tREMOUNT_PASS\tworkers=8\n' "$(date -Is)" >>"$AUDIT"
