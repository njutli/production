#!/usr/bin/env bash
# Render the complete mutation vocabulary for human review; execute nothing.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

RUN_ID=${1:-}; PHASE=${2:-all}; NODE_IP=${3:-all}; ARM=${4:-B1c}; INSTANCE=${5:-SMOKE-B1c}
t66_check_run_id "$RUN_ID"
case "$NODE_IP" in all) ;; *) t66_node_suffix "$NODE_IP" >/dev/null;; esac
case "$PHASE" in all|prod-stop|prod-start|storage-create|activate|deactivate|storage-destroy) ;; *) t66_die 'invalid plan phase';; esac
t66_check_cluster "$ARM"; t66_check_instance "$INSTANCE"
INV="/tmp/production/opencode-t3.22c-${RUN_ID}/inventory"
[[ -s "$INV/INVENTORY_PASS" && -s "$INV/contract.tsv" ]] || t66_die 'signed-off inventory is required'
UID_FROZEN=$(t66_state_value "$INV/contract.tsv" uid); GID_FROZEN=$(t66_state_value "$INV/contract.tsv" gid)

nodes() { if [[ "$NODE_IP" == all ]]; then printf '%s\n' "${T66_NODES[@]}"; else printf '%s\n' "$NODE_IP"; fi; }
want() { [[ "$PHASE" == all || "$PHASE" == "$1" ]]; }

while read -r node; do
  backing="/mnt/jfs-tikv/jfs-t66-${RUN_ID}-backing"; root="/mnt/jfs-t66-${RUN_ID}"
  printf 'PLAN_BEGIN node=%s run_id=%s\n' "$node" "$RUN_ID"
  if want prod-stop; then printf 'sudo systemctl stop tikv  # only through t66-prod-stop-one.sh with fingerprint-bound token\n'; fi
  if want storage-create; then
    printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$UID_FROZEN" "$GID_FROZEN" "$backing" "$root"
    printf 'fallocate -l 103079215104 -- %q\n' "$backing/kv.img"
    printf 'fallocate -l 34359738368 -- %q\n' "$backing/b1c-logs.img"
  fi
  if want activate; then
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/pd"
    printf 'sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec t66-pd-%s-%s %q\n' "$RUN_ID" "${INSTANCE,,}" "$root/pd"
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/pd"
    if [[ "$ARM" == B1c ]]; then
      roles=(kv logs); files=("$backing/kv.img" "$backing/b1c-logs.img"); mnts=(b1c-kv b1c-logs)
    else
      logs_tmpfs="$root/d1-${INSTANCE,,}-logs-backing"
      printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$logs_tmpfs"
      printf 'sudo mount -t tmpfs -o size=34G,mode=0700,nodev,nosuid,noexec t66-logs-%s-%s %q\n' "$RUN_ID" "${INSTANCE,,}" "$logs_tmpfs"
      printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$logs_tmpfs"
      printf 'fallocate -l 34359738368 -- %q\n' "$logs_tmpfs/t66-d1-logs.img"
      roles=(kv logs); files=("$backing/kv.img" "$logs_tmpfs/t66-d1-logs.img"); mnts=(d1-kv d1-logs)
    fi
    for i in "${!roles[@]}"; do
      printf 'sudo losetup --find --show --nooverlap %q\n' "${files[$i]}"
      printf 'sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <identity-verified-loop-%s>\n' "${roles[$i]}"
      printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/${mnts[$i]}"
      printf 'sudo mount -o noatime,nodiscard <identity-verified-loop-%s> %q\n' "${roles[$i]}" "$root/${mnts[$i]}"
      printf 'sudo chown %s:%s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/${mnts[$i]}"
    done
  fi
  if want deactivate; then
    printf 'sudo umount <identity-verified-t66-filesystem-mount>\n'
    printf 'sudo losetup -d <identity-verified-loop>\n'
    if [[ "$ARM" == D1 ]]; then
      logs_tmpfs="$root/d1-${INSTANCE,,}-logs-backing"
      printf 'unlink %q\n' "$logs_tmpfs/t66-d1-logs.img"
      printf 'sudo umount %q  # source must be t66-logs-%s-%s\n' "$logs_tmpfs" "$RUN_ID" "${INSTANCE,,}"
      printf 'rmdir %q\n' "$logs_tmpfs"
    fi
    printf 'sudo umount %q\n' "$root/pd"
  fi
  if want storage-destroy; then
    printf 'unlink %q\nunlink %q\n' "$backing/kv.img" "$backing/b1c-logs.img"
    printf 'sudo rmdir %q %q\n' "$backing" "$root"
  fi
  if want prod-start; then printf 'sudo systemctl start tikv  # only through t66-prod-start-one.sh with stopped-state-bound token\n'; fi
  printf 'PLAN_END node=%s\n' "$node"
done < <(nodes)

printf 'FORBIDDEN_NOT_PRESENT=rm-rf,wipefs,blkdiscard,losetup-D,fstrim,force-umount,SIGKILL,reboot,raw-NVMe-write,pool-delete,OSD-restart,drop-caches\n'
printf '%s\n' 'READ_ONLY_SUDO_VOCABULARY=losetup -l/-j; cat /sys/block/loop*/loop/backing_file; smartctl -a -j /dev/nvme1n1; ceph health/-s/df/osd ls/osd dump/tell osd.N perf dump'
printf '%s\n' 'PREAUTHORIZED_BOUNDED_CEPH_MUTATION=sudo ceph tell osd.<frozen-id-0..5> compact; no OSD restart and no pool create/delete'
