#!/bin/bash
# Stage F: Migrate all 6 OSDs' DB to tmpfs (4GB each)
# Uses loop device to bypass tmpfs O_DIRECT limitation
# Sequential: stop OSD → create tmpfs+loop → bluefs-bdev-new-db → start OSD → verify

set -uo pipefail

RESULT_DIR=/home/turboai/production/results/node2-raid-fix-memdisk-ceiling-20260709
OPS_LOG=$RESULT_DIR/ops.log
FSID=073f28e0-5fe0-11f1-8ce6-7369ee2be5a1
CEPH_IMG=quay.io/ceph/ceph@sha256:a0f373aaaf5a5ca5c4379c09da24c771b8266a09dc9e2181f90eacf423d7326f
DB_SIZE=4294967296  # 4GB
PW="TurboAi@303"

mkdir -p $RESULT_DIR

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $OPS_LOG; }

# OSD_ID:NODE_IP:LOOP_DEV:TMPFS_DIR:CONTAINER_OSD_NAME
OSDS=(
  "0:192.168.11.11:loop20:/tmp/bs-db-osd0:ceph-0"
  "1:192.168.11.11:loop21:/tmp/bs-db-osd1:ceph-1"
  "2:192.168.11.13:loop20:/tmp/bs-db-osd2:ceph-2"
  "3:192.168.11.13:loop21:/tmp/bs-db-osd3:ceph-3"
  "4:192.168.11.14:loop20:/tmp/bs-db-osd4:ceph-4"
  "5:192.168.11.14:loop21:/tmp/bs-db-osd5:ceph-5"
)

log "=============================================="
log "Stage F: Full 6 OSD tmpfs DB migration START"
log "=============================================="

migrate_osd() {
  local entry="$1"
  IFS=':' read -r osd_id node_ip loop_dev tmpfs_dir ceph_name <<< "$entry"
  
  log "==== OSD.${osd_id} on ${node_ip} (loop=${loop_dev}, tmpfs=${tmpfs_dir}) ===="
  
  # 1. Create tmpfs + loop device on the node
  log "  Creating tmpfs + loop device..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo mkdir -p ${tmpfs_dir} && \
    sudo mount -t tmpfs -o size=4G tmpfs ${tmpfs_dir} && \
    sudo truncate -s 4G ${tmpfs_dir}/db_device && \
    sudo losetup ${loop_dev} ${tmpfs_dir}/db_device 2>/dev/null || sudo losetup --find ${tmpfs_dir}/db_device && \
    sudo losetup -a | grep ${loop_dev} && \
    echo 'tmpfs+loop ready'
  " 2>&1 | tee -a $OPS_LOG
  
  # 2. Stop OSD from .12
  log "  Stopping osd.${osd_id}..."
  sudo ceph orch daemon stop osd.${osd_id} 2>&1 | tee -a $OPS_LOG
  sleep 15
  
  # Verify down
  local state=$(sudo ceph osd tree 2>/dev/null | grep "osd.${osd_id} " | awk '{print $4}')
  log "  osd.${osd_id} status: ${state}"
  
  # 3. Run bluefs-bdev-new-db from podman container on the node
  log "  Running bluefs-bdev-new-db..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo podman run --rm --privileged \
      -v /dev:/dev \
      -v /var/lib/ceph/${FSID}/osd.${osd_id}:/var/lib/ceph/osd/${ceph_name}:z \
      -e CEPH_ARGS='--bluestore-block-db-size ${DB_SIZE}' \
      --entrypoint /usr/bin/ceph-bluestore-tool \
      ${CEPH_IMG} \
      --command bluefs-bdev-new-db --path /var/lib/ceph/osd/${ceph_name} --dev-target ${loop_dev}
  " 2>&1 | tee -a $OPS_LOG
  
  # 4. Verify block.db symlink created
  log "  Verifying block.db symlink..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo ls -la /var/lib/ceph/${FSID}/osd.${osd_id}/block.db 2>&1
  " 2>&1 | tee -a $OPS_LOG
  
  # 5. Reset systemd failure count and start OSD
  log "  Resetting systemd + starting osd.${osd_id}..."
  sshpass -p "$PW" ssh -o StrictHostKeyChecking=no turboai@${node_ip} "
    sudo systemctl reset-failed ceph-${FSID}@osd.${osd_id}.service 2>/dev/null || true
  " 2>&1 | tee -a $OPS_LOG
  sudo ceph orch daemon start osd.${osd_id} 2>&1 | tee -a $OPS_LOG
  sleep 20
  
  # 6. Verify up/in
  local state=$(sudo ceph osd tree 2>/dev/null | grep "osd.${osd_id} " | awk '{print $4}')
  log "  osd.${osd_id} status after start: ${state}"
  if [ "$state" = "up" ]; then
    log "  OSD.${osd_id} MIGRATION SUCCESS"
  else
    log "  WARNING: osd.${osd_id} not up yet, waiting 30s more..."
    sleep 30
    state=$(sudo ceph osd tree 2>/dev/null | grep "osd.${osd_id} " | awk '{print $4}')
    log "  osd.${osd_id} status: ${state}"
  fi
}

# Migrate all 6 OSDs sequentially
for entry in "${OSDS[@]}"; do
  migrate_osd "$entry"
done

# Final verification
log "=============================================="
log "Migration complete. Final verification..."
log "=============================================="
sudo ceph osd tree 2>&1 | tee -a $OPS_LOG
sudo ceph health 2>&1 | tee -a $OPS_LOG

# Wait for HEALTH_OK (up to 5 min)
for i in $(seq 1 30); do
  sleep 10
  state=$(sudo ceph health 2>/dev/null)
  log "  health check $i: $state"
  [ "$state" = "HEALTH_OK" ] && break
done

log "=============================================="
log "Stage F migration COMPLETE. Health: $(sudo ceph health 2>/dev/null)"
log "=============================================="
