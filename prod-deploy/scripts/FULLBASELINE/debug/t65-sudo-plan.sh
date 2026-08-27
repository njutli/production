#!/usr/bin/env bash
# Render the complete mutation vocabulary for human review; execute nothing.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

RUN_ID=${1:-}; PHASE=${2:-all}; NODE_IP=${3:-all}; ARM=${4:-A1}; INSTANCE=${5:-SMOKE-A1}
t65_check_run_id "$RUN_ID"
case "$NODE_IP" in all) ;; *) t65_node_suffix "$NODE_IP" >/dev/null;; esac
case "$PHASE" in all|prod-stop|prod-start|storage-create|activate|deactivate|storage-destroy) ;; *) t65_die 'invalid plan phase';; esac
t65_check_cluster "$ARM"; t65_check_instance "$INSTANCE"
INV="/tmp/production/opencode-t3.22b-${RUN_ID}/inventory"
[[ -s "$INV/INVENTORY_PASS" && -s "$INV/contract.tsv" ]] || t65_die 'signed-off inventory is required'
UID_FROZEN=$(t65_state_value "$INV/contract.tsv" uid); GID_FROZEN=$(t65_state_value "$INV/contract.tsv" gid)

nodes() { if [[ "$NODE_IP" == all ]]; then printf '%s\n' "${T65_NODES[@]}"; else printf '%s\n' "$NODE_IP"; fi; }
want() { [[ "$PHASE" == all || "$PHASE" == "$1" ]]; }

while read -r node; do
  backing="/mnt/jfs-tikv/jfs-t65-${RUN_ID}-backing"; root="/mnt/jfs-t65-${RUN_ID}"
  printf 'PLAN_BEGIN node=%s run_id=%s\n' "$node" "$RUN_ID"
  if want prod-stop; then printf 'sudo systemctl stop tikv  # only through t65-prod-stop-one.sh with fingerprint-bound token\n'; fi
  if want storage-create; then
    printf 'sudo install -d -m 0700 -o %s -g %s %q %q\n' "$UID_FROZEN" "$GID_FROZEN" "$backing" "$root"
    printf 'fallocate -l 137438953472 -- %q\n' "$backing/a1-shared.img"
    printf 'fallocate -l 103079215104 -- %q\n' "$backing/b1-kv.img"
    printf 'fallocate -l 34359738368 -- %q\n' "$backing/b1-logs.img"
  fi
  if want activate; then
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/pd"
    printf 'sudo mount -t tmpfs -o size=8G,mode=0700,nodev,nosuid,noexec t65-pd-%s-%s %q\n' "$RUN_ID" "${INSTANCE,,}" "$root/pd"
    printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/pd"
    if [[ "$ARM" == A1 ]]; then roles=(shared); files=(a1-shared.img); mnts=(a1-shared); else roles=(kv logs); files=(b1-kv.img b1-logs.img); mnts=(b1-kv b1-logs); fi
    for i in "${!roles[@]}"; do
      printf 'sudo losetup --find --show --nooverlap %q\n' "$backing/${files[$i]}"
      printf 'sudo mkfs.ext4 -F -m 0 -T largefile -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 <identity-verified-loop-%s>\n' "${roles[$i]}"
      printf 'sudo install -d -m 0700 -o %s -g %s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/${mnts[$i]}"
      printf 'sudo mount -o noatime,nodiscard <identity-verified-loop-%s> %q\n' "${roles[$i]}" "$root/${mnts[$i]}"
      printf 'sudo chown %s:%s %q\n' "$UID_FROZEN" "$GID_FROZEN" "$root/${mnts[$i]}"
    done
  fi
  if want deactivate; then
    printf 'sudo umount <identity-verified-t65-filesystem-mount>\n'
    printf 'sudo losetup -d <identity-verified-loop>\n'
    printf 'sudo umount %q\n' "$root/pd"
  fi
  if want storage-destroy; then
    printf 'unlink %q\nunlink %q\nunlink %q\n' "$backing/a1-shared.img" "$backing/b1-kv.img" "$backing/b1-logs.img"
    printf 'sudo rmdir %q %q\n' "$backing" "$root"
  fi
  if want prod-start; then printf 'sudo systemctl start tikv  # only through t65-prod-start-one.sh with stopped-state-bound token\n'; fi
  printf 'PLAN_END node=%s\n' "$node"
done < <(nodes)

printf 'FORBIDDEN_NOT_PRESENT=rm-rf,wipefs,blkdiscard,losetup-D,fstrim,force-umount,SIGKILL,reboot,raw-NVMe-write,pool-delete,OSD-restart,drop-caches\n'
