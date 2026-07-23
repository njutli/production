#!/bin/bash
set -e

# rebuild-stable-ids.sh  [v2 2026-07-23]
# Stable-ID 重建：ceph osd destroy + ceph-volume lvm create --osd-id
# 保持 OSD ID 0-5 不变、不删 pool → CRUSH PG→OSD 映射跨重建一致
#
# v2 修复（见 pre-skills/stable-rebuild-skill.md）：
#   - Step 1: systemctl mask+stop 替代 pkill（systemd 自动重启问题）
#   - Step 2: ceph osd down + 验证 destroyed 标志（destroy 对 up OSD 无效）
#   - Step 4: LVM 创建后验证（node 3 曾静默失败）

SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
HOSTS=(ceph-node1 ceph-node2 ceph-node3)
DEVS=(/dev/nvme2n1 /dev/nvme3n1)
DBWAL_MNT=/mnt/dbwal
DB_SIZE=40G
WAL_SIZE=10G
SSHPASS="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

# OSD ID 到 (node_index, device) 的映射
# node 0=150: osd.0=nvme2n1, osd.1=nvme3n1
# node 1=151: osd.2=nvme2n1, osd.3=nvme3n1
# node 2=152: osd.4=nvme2n1, osd.5=nvme3n1
OSD_MAP=("0:0:0" "1:0:1" "2:1:0" "3:1:1" "4:2:0" "5:2:1")

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Step 1: Stop OSDs (systemctl mask+stop, NOT just pkill — systemd auto-restarts)
log ">>> Step 1: Stop+mask ceph-osd on all nodes (systemctl mask+stop)"
for ip in "${SLAVES[@]}"; do
  $SSHPASS@$ip '
    for id in $(systemctl list-units "ceph-osd@*" --no-legend 2>/dev/null | awk "{print \$1}" | grep -oP "osd@\K[0-9]+"); do
      sudo systemctl mask ceph-osd@${id} 2>/dev/null || true
      sudo systemctl stop ceph-osd@${id} 2>/dev/null || true
    done
    sudo pkill -9 ceph-osd 2>/dev/null || true
  ' 2>/dev/null || true
  echo "  ${ip} stopped"
done
sleep 3
# 验证所有 OSD 进程已停止
ALL_STOPPED=true
for ip in "${SLAVES[@]}"; do
  running=$($SSHPASS@$ip "pgrep ceph-osd 2>/dev/null | head -1" 2>/dev/null)
  if [ -n "$running" ]; then
    log "  ⚠️ ${ip} 仍有 ceph-osd 进程 (pid=$running)!"
    ALL_STOPPED=false
  fi
done
if $ALL_STOPPED; then
  log "  ✅ 所有节点 ceph-osd 已停止"
else
  log "  ⚠️ 部分节点仍有进程，继续但 destroy 可能无效"
fi

# Step 2: Mark down + Destroy OSDs (keep ID + crush + auth, NOT purge)
log ">>> Step 2: ceph osd down + destroy (keep IDs)"
for entry in "${OSD_MAP[@]}"; do
  osd_id=${entry%%:*}
  sudo ceph osd down ${osd_id} 2>/dev/null || true
done
sleep 5
for entry in "${OSD_MAP[@]}"; do
  osd_id=${entry%%:*}
  log "  Destroying osd.${osd_id}..."
  sudo ceph osd destroy ${osd_id} --yes-i-really-mean-it 2>/dev/null || true
done
sleep 3
# Step 2b: 验证 destroyed 标志（关键！ceph-volume --osd-id 需要此标志才能复用 ID）
log ">>> Step 2b: 验证 destroyed 标志"
DESTROY_OK=true
for entry in "${OSD_MAP[@]}"; do
  osd_id=${entry%%:*}
  state=$(sudo ceph osd info ${osd_id} 2>/dev/null | grep -oP 'destroyed' || true)
  if [ -n "$state" ]; then
    log "  osd.${osd_id}: ✅ destroyed"
  else
    log "  osd.${osd_id}: ❌ NOT destroyed — 需排查（OSD 可能仍 up）"
    DESTROY_OK=false
  fi
done
if ! $DESTROY_OK; then
  log "⚠️ 部分 OSD 未正确 destroy，ceph-volume create 将失败。请先确保 OSD 已 down。"
  log "  尝试重新 destroy..."
  for entry in "${OSD_MAP[@]}"; do
    osd_id=${entry%%:*}
    sudo ceph osd down ${osd_id} 2>/dev/null || true
  done
  sleep 10
  for entry in "${OSD_MAP[@]}"; do
    osd_id=${entry%%:*}
    state=$(sudo ceph osd info ${osd_id} 2>/dev/null | grep -oP 'destroyed' || true)
    if [ -z "$state" ]; then
      log "  osd.${osd_id}: 重新 destroy..."
      sudo ceph osd destroy ${osd_id} --yes-i-really-mean-it 2>/dev/null || true
    fi
  done
  sleep 3
fi

# Step 3: Clean LVM/dm/tmpfs on all nodes
log ">>> Step 3: Clean LVM/dm/tmpfs on all nodes"
for ip in "${SLAVES[@]}"; do
  $SSHPASS@$ip "sudo bash /tmp/cleanup-node.sh" 2>/dev/null || true
done

# Step 4: Recreate LVMs (using OSD ID in VG name)
log ">>> Step 4: Recreate LVMs with stable VG names (osd-id based)"
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}; host=${HOSTS[$node_idx]}; dev=${DEVS[$dev_idx]}
  osd_seq=$((osd_id + 1))

  log "  ${host}: osd.${osd_id} on ${dev}"
  $SSHPASS@$ip bash -s << EOF
set -e
db_file=${DBWAL_MNT}/db-osd${osd_seq}.img
wal_file=${DBWAL_MNT}/wal-osd${osd_seq}.img
sudo truncate -s ${DB_SIZE} \$db_file
sudo truncate -s ${WAL_SIZE} \$wal_file
db_loop=\$(sudo losetup -f --show \$db_file)
wal_loop=\$(sudo losetup -f --show \$wal_file)
db_vg=ceph-vg-db${osd_seq}
wal_vg=ceph-vg-wal${osd_seq}
sudo pvcreate -ff -y \$db_loop 2>/dev/null || true
sudo pvcreate -ff -y \$wal_loop 2>/dev/null || true
sudo vgcreate \$db_vg \$db_loop 2>/dev/null || true
sudo vgcreate \$wal_vg \$wal_loop 2>/dev/null || true
sudo lvcreate -l 100%FREE -n osd-db \$db_vg 2>/dev/null || true
sudo lvcreate -l 100%FREE -n osd-wal \$wal_vg 2>/dev/null || true
data_vg=ceph-vg-osd${osd_seq}
sudo pvcreate -ff -y ${dev} 2>/dev/null || true
sudo vgcreate \$data_vg ${dev} 2>/dev/null || true
sudo lvcreate -l 100%FREE -n osd \$data_vg 2>/dev/null || true
echo "  OK: osd${osd_seq} on ${host}"
EOF
done
log "  All LVs prepared"

# Step 4b: 验证 LVMs（node 3 曾在此步静默失败）
log ">>> Step 4b: 验证 LVMs"
for ip in "${SLAVES[@]}"; do
  count=$($SSHPASS@$ip "sudo lvs --noheadings -o vg_name,lv_name 2>/dev/null | grep ceph | wc -l" 2>/dev/null || echo 0)
  if [ "$count" -ge 6 ]; then
    log "  ${ip}: ✅ ${count} LVs"
  else
    log "  ${ip}: ❌ 只有 ${count} LVs（应为 6）— 需手动修复"
  fi
done

# Step 5: Create OSDs with same IDs (NOT ceph orch)
log ">>> Step 5: ceph-volume lvm create --osd-id (preserve IDs)"
# Unmask services first
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}
  $SSHPASS@$ip "sudo systemctl unmask ceph-osd@${osd_id} 2>/dev/null || true" 2>/dev/null || true
done
sleep 5
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}; host=${HOSTS[$node_idx]}
  osd_seq=$((osd_id + 1))
  data_lv="/dev/ceph-vg-osd${osd_seq}/osd"
  db_lv="/dev/ceph-vg-db${osd_seq}/osd-db"
  wal_lv="/dev/ceph-vg-wal${osd_seq}/osd-wal"
  log "  ${host}: osd.${osd_id}"
  $SSHPASS@$ip "sudo ceph-volume lvm create --bluestore --osd-id ${osd_id} --data ${data_lv} --block.db ${db_lv} --block.wal ${wal_lv} --crush-device-class ssd 2>&1 | tail -5"
  sleep 2
done

# Step 6: Start any OSDs that didn't auto-start
log ">>> Step 6: Ensure all OSDs started"
sleep 10
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}
  $SSHPASS@$ip "sudo systemctl reset-failed ceph-osd@${osd_id} 2>/dev/null || true; sudo systemctl start ceph-osd@${osd_id} 2>/dev/null || true" 2>/dev/null || true
done

# Step 7: Wait for PG active+clean
log ">>> Step 7: Waiting for PG active+clean..."
for i in $(seq 1 60); do
  pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
  echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
  sleep 5
done
log "  $(sudo ceph -s 2>/dev/null | grep -E 'osd:|pgs:' | head -2 | tr '\n' ' ')"

# Step 8: Fix .mgr pool if needed
if sudo ceph -s 2>/dev/null | grep -q "stale\|down"; then
  log ">>> Step 8: Fixing .mgr pool..."
  sudo ceph config set mon mon_allow_pool_delete true 2>/dev/null || true
  sudo ceph osd pool delete .mgr .mgr --yes-i-really-really-mean-it 2>/dev/null || true
  sudo ceph mgr fail 2>/dev/null || true
  sleep 30
fi

# Step 9: Pool - keep existing (preserve pool ID for stable CRUSH mapping)
log ">>> Step 9: Check/recreate EC pool..."
if sudo ceph osd pool ls 2>/dev/null | grep -q "^juicefs-data$"; then
  log "  Pool juicefs-data exists (preserving pool ID for stable CRUSH mapping)"
  for i in $(seq 1 30); do
    pg=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
    echo "$pg" | grep -qE "active\+clean" && break
    sleep 5
  done
else
  log "  Pool not found, creating..."
  sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
  sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
  sudo ceph osd pool set juicefs-data fast_read true 2>/dev/null
  sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null
fi
log "  Pool: $(sudo ceph osd pool get juicefs-data fast_read 2>/dev/null)"

# Step 10: Verify ceph.conf + keyring on 157
log ">>> Step 10: Verify ceph.conf + keyring..."
if [ ! -f /etc/ceph/ceph.conf ]; then
  sudo tee /etc/ceph/ceph.conf > /dev/null << 'CONF'
# minimal ceph.conf for 4f4e3ca0-8297-11f1-a671-97520597268c
[global]
	fsid = 4f4e3ca0-8297-11f1-a671-97520597268c
	mon_host = [v2:10.3.1.6:3300/0,v1:10.3.1.6:6789/0] [v2:10.3.1.7:3300/0,v1:10.3.1.7:6789/0] [v2:10.3.1.8:3300/0,v1:10.3.1.8:6789/0]
CONF
  sudo chmod 644 /etc/ceph/ceph.conf
fi
sudo ceph auth get client.juicefs 2>/dev/null | sudo tee /etc/ceph/ceph.client.juicefs.keyring > /dev/null
sudo chmod 644 /etc/ceph/ceph.client.juicefs.keyring

# Verify
log ">>> Verification:"
log "  $(sudo ceph osd stat 2>/dev/null)"
log "  $(sudo ceph osd tree 2>/dev/null | grep osd | head -6 | tr '\n' ' ')"
log "  $(sudo ceph osd pool get juicefs-data fast_read 2>/dev/null)"
log "  $(sudo ceph health 2>/dev/null)"
log ">>> Rebuild (stable IDs) DONE"
