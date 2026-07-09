#!/bin/bash
# Stage F fix: Re-migrate all 6 OSDs' DB to tmpfs with CORRECT /dev/loopXX path
# Also handles node3 using docker instead of podman
set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709
OPS_LOG=$RESULT_DIR/ops.log
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1
CEPH_IMG=quay.io/ceph/ceph@sha256:a0f373aaaf5a5ca5c4379c09da24c771b8266a09dc9e2181f90eacf423d7326f
DB_SIZE=4294967296
PW="TurboAi@303"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }

# OSD_ID:NODE_IP:LOOP_DEV:TMPFS_DIR:CONTAINER_OSD_NAME
# LOOP_DEV now uses full /dev/ path
OSDS=(
  "0:192.168.11.11:/dev/loop20:/tmp/bs-db-osd0:ceph-0"
  "1:192.168.11.11:/dev/loop21:/tmp/bs-db-osd1:ceph-1"
  "2:192.168.11.13:/dev/loop20:/tmp/bs-db-osd2:ceph-2"
  "3:192.168.11.13:/dev/loop21:/tmp/bs-db-osd3:ceph-3"
  "4:192.168.11.14:/dev/loop20:/tmp/bs-db-osd4:ceph-4"
  "5:192.168.11.14:/dev/loop21:/tmp/bs-db-osd5:ceph-5"
)

log "=============================================="
log "Stage F fix: Re-migrate with /dev/loopXX path START"
log "=============================================="

migrate_osd() {
  local entry="$1"
  IFS=':' read -r osd_id node_ip loop_dev tmpfs_dir ceph_name <<< "$entry"
  
  log "==== OSD.${osd_id} on ${node_ip} (loop=${loop_dev}) ===="
  
  # Determine container runtime (podman or docker)
  local runtime=$(sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "which podman 2>/dev/null || which docker 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$runtime" ]; then
    log "  ERROR: no podman or docker on ${node_ip}"
    return 1
  fi
  log "  Container runtime: ${runtime}"
  
  # 1. Check/recreate tmpfs + loop if needed
  log "  Checking tmpfs + loop..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    mountpoint -q ${tmpfs_dir} 2>/dev/null || (sudo mkdir -p ${tmpfs_dir} && sudo mount -t tmpfs -o size=4G tmpfs ${tmpfs_dir})
    sudo losetup ${loop_dev} 2>/dev/null | grep -q ${tmpfs_dir} || (sudo truncate -s 4G ${tmpfs_dir}/db_device 2>/dev/null; sudo losetup ${loop_dev} ${tmpfs_dir}/db_device 2>/dev/null || sudo losetup --find ${tmpfs_dir}/db_device)
    sudo losetup -a | grep ${loop_dev}
  " 2>&1 | tee -a $OPS_LOG
  
  # 2. Stop OSD
  log "  Stopping osd.${osd_id}..."
  sudo ceph orch daemon stop osd.${osd_id} 2>&1 | tee -a $OPS_LOG
  sleep 15
  
  # 3. Clean up any old block.db symlink
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "sudo rm -f /var/lib/ceph/${FSID}/osd.${osd_id}/block.db 2>/dev/null; true"
  
  # 4. Run bluefs-bdev-new-db with CORRECT /dev/ path
  log "  Running bluefs-bdev-new-db (dev-target=${loop_dev})..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo ${runtime} run --rm --privileged \
      -v /dev:/dev \
      -v /var/lib/ceph/${FSID}/osd.${osd_id}:/var/lib/ceph/osd/${ceph_name}:z \
      -e CEPH_ARGS='--bluestore-block-db-size ${DB_SIZE}' \
      --entrypoint /usr/bin/ceph-bluestore-tool \
      ${CEPH_IMG} \
      --command bluefs-bdev-new-db --path /var/lib/ceph/osd/${ceph_name} --dev-target ${loop_dev}
  " 2>&1 | tee -a $OPS_LOG
  
  # 5. Verify block.db symlink (should be absolute /dev/loopXX)
  log "  Verifying block.db..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo ls -la /var/lib/ceph/${FSID}/osd.${osd_id}/block.db 2>&1
  " 2>&1 | tee -a $OPS_LOG
  
  # 6. Start OSD
  log "  Starting osd.${osd_id}..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "sudo systemctl reset-failed ceph-${FSID}@osd.${osd_id}.service 2>/dev/null || true" 2>&1 | tee -a $OPS_LOG
  sudo ceph orch daemon start osd.${osd_id} 2>&1 | tee -a $OPS_LOG
  sleep 25
  
  # 7. Verify up
  local state=$(sudo ceph osd tree 2>/dev/null | grep " osd.${osd_id} " | awk '{print $5}')
  log "  osd.${osd_id} status: ${state}"
  
  # 8. Verify block.db persists after start
  log "  Verifying block.db persists..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo ls -la /var/lib/ceph/${FSID}/osd.${osd_id}/block.db 2>&1
  " 2>&1 | tee -a $OPS_LOG
}

for entry in "${OSDS[@]}"; do
  migrate_osd "$entry"
done

log "=============================================="
log "Re-migration complete. Final verification..."
log "=============================================="
sudo ceph osd tree 2>&1 | tee -a $OPS_LOG
sudo ceph health 2>&1 | tee -a $OPS_LOG

for i in $(seq 1 30); do
  sleep 10
  state=$(sudo ceph health 2>/dev/null)
  log "  health check $i: $state"
  [ "$state" = "HEALTH_OK" ] && break
done

log "=============================================="
log "Stage F fix COMPLETE. Health: $(sudo ceph health 2>/dev/null)"
log "=============================================="
