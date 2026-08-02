#!/bin/bash
set -euo pipefail

# ============================================================
# rebuild-osds.sh — Ceph OSD 重建固化脚本
#
# 解决的已知问题（每次重建遇到 + 解决方案）：
#   1. LVM/dm/PV/VG/loop 残留 → 全量清理（kill + detach + remove + wipe）
#   2. ceph orch 自动扫描其他磁盘（竞态）→ 不用 ceph orch，直接 ceph-volume lvm activate
#   3. cephadm 不在 157 上 → 从 157 用 ceph CLI 直接操作 mon
#   4. "already created?" 但 daemon 未启动 → ceph-volume lvm activate --all
#   5. OSD 数据目录不存在 → activate 自动创建
#   6. ceph orch daemon rm --force 删了 auth key → 手动 ceph auth add 恢复
#   7. systemd restart limit → systemctl reset-failed 后再 start
#   8. .mgr pool PG 卡住 → 删除 .mgr pool + mgr fail 触发重建
#
# 用法：bash rebuild-osds.sh [--yes]
# 前置：mon/mgr 已运行（不需要重建 mon），config.sh 可用
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.sh"

AUTO_YES=false
[ "${1:-}" = "--yes" ] && AUTO_YES=true

log() { echo "[$(date '+%H:%M:%S')] $*"; }

CEPH_SERVERS_STR="${CEPH_SERVERS[@]}"
OSD_DEVS_STR="${CEPH_OSD_DEVICES_PER_NODE[@]}"
DBWAL_MNT="${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}"
DB_SIZE="${CEPH_DB_SIZE:-40G}"
WAL_SIZE="${CEPH_WAL_SIZE:-10G}"
TMPFS_SIZE="${CEPH_DB_WAL_TMPFS_SIZE:-200G}"
POOL="${CEPH_POOL_NAME:-juicefs-data}"
EC_K="${CEPH_EC_K:-4}"
EC_M="${CEPH_EC_M:-2}"
FAILURE_DOMAIN="${CEPH_FAILURE_DOMAIN:-osd}"
PG_NUM="${CEPH_PG_NUM:-32}"

# ============================================================
# Step 0: 确认
# ============================================================
log "=== rebuild-osds.sh ==="
log "Servers: ${CEPH_SERVERS_STR}"
log "OSD devs per node: ${OSD_DEVS_STR}"
log "DB/WAL: tmpfs at ${DBWAL_MNT} (size=${TMPFS_SIZE}, db=${DB_SIZE}, wal=${WAL_SIZE})"
log "Pool: ${POOL} (EC ${EC_K}+${EC_M}, pg_num=${PG_NUM}, fast_read=true)"
log ""

if ! ${AUTO_YES}; then
    read -p "Proceed? (yes/no) " ans
    [ "$ans" = "yes" ] || exit 1
fi

# ============================================================
# Step 1: Kill all ceph-osd processes on all nodes
# ============================================================
log ">>> Step 1: Killing ceph-osd on all nodes..."
for ip in "${CEPH_SERVERS[@]}"; do
    hostname="${CEPH_HOSTNAMES[$ip]}"
    ssh_to_slave "$ip" "sudo pkill -9 ceph-osd 2>/dev/null; sleep 2; echo '${hostname}: killed'" 2>/dev/null
done

# ============================================================
# Step 2: Purge all OSDs from Ceph mon
# NOTE: Do NOT use 'ceph orch daemon rm --force' — it deletes auth keys!
# ============================================================
log ">>> Step 2: Purging all OSDs from mon (ceph osd purge, NOT orch rm)..."
ssh_to_client "
for osd in \$(sudo ceph osd ls 2>/dev/null); do
    sudo ceph osd down \$osd 2>/dev/null || true
    sudo ceph osd destroy \$osd --yes-i-really-really-mean-it 2>/dev/null || true
    sudo ceph osd crush remove osd.\$osd 2>/dev/null || true
    sudo ceph osd rm \$osd 2>/dev/null || true
    sudo ceph osd purge \$osd --yes-i-really-really-mean-it 2>/dev/null || true
    sudo ceph auth del osd.\$osd 2>/dev/null || true
done
sleep 3
echo 'OSDs after purge:'
sudo ceph osd stat 2>/dev/null
" 2>/dev/null

# ============================================================
# Step 3: Full clean on all nodes (LVM/dm/PV/VG/loop/tmpfs)
# ============================================================
log ">>> Step 3: Full clean on all nodes..."
for ip in "${CEPH_SERVERS[@]}"; do
    hostname="${CEPH_HOSTNAMES[$ip]}"
    ssh_to_slave "$ip" "
        # Kill any remaining ceph-osd
        sudo pkill -9 ceph-osd 2>/dev/null || true
        sleep 2

        # Detach all loop devices
        for loop in \$(sudo losetup -l --noheadings 2>/dev/null | awk '{print \$1}'); do
            sudo losetup -d \$loop 2>/dev/null || true
        done

        # Remove all LVs
        for lv in \$(sudo lvs --noheadings 2>/dev/null | awk '{print \$2\"/\"\$1}'); do
            sudo lvremove -f \$lv 2>/dev/null || true
        done

        # Remove all VGs
        for vg in \$(sudo vgs --noheadings 2>/dev/null | awk '{print \$1}'); do
            sudo vgremove --force \$vg 2>/dev/null || true
        done

        # Remove all PVs
        for pv in \$(sudo pvs --no-headings 2>/dev/null | awk '{print \$1}'); do
            sudo pvremove --force \$pv 2>/dev/null || true
        done

        # Remove all dm entries
        sudo dmsetup remove_all --force 2>/dev/null || true

        # Umount tmpfs if mounted, then remount fresh
        sudo umount ${DBWAL_MNT} 2>/dev/null || true
        sudo rm -rf ${DBWAL_MNT}/*
        sudo mkdir -p ${DBWAL_MNT}
        sudo mount -t tmpfs -o size=${TMPFS_SIZE} tmpfs ${DBWAL_MNT}

        # Wipe data disks
        for dev in ${CEPH_OSD_DEVICES_PER_NODE[@]}; do
            sudo wipefs -af \$dev 2>/dev/null || true
            sudo sgdisk --zap-all \$dev 2>/dev/null || true
            sudo dd if=/dev/zero of=\$dev bs=1M count=512 oflag=direct 2>/dev/null || true
        done

        sudo partprobe 2>/dev/null || true
        sleep 2

        pvs=\$(sudo pvs --no-headings 2>/dev/null | wc -l)
        vgs=\$(sudo vgs --no-headings 2>/dev/null | wc -l)
        lvs=\$(sudo lvs --no-headings 2>/dev/null | wc -l)
        loops=\$(sudo losetup -l --noheadings 2>/dev/null | wc -l)
        echo '${hostname}: pvs='\$pvs' vgs='\$vgs' lvs='\$lvs' loops='\$loops' tmpfs=clean'
    " 2>/dev/null
done

# ============================================================
# Step 4: Prepare ALL LVs on ALL nodes (data + DB + WAL)
# Do this BEFORE any ceph orch/volume command to avoid race conditions
# ============================================================
log ">>> Step 4: Preparing all LVs on all nodes..."
OSD_SEQ=0
for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="${CEPH_HOSTNAMES[$ip]}"

    for dev in "${CEPH_OSD_DEVICES_PER_NODE[@]}"; do
        OSD_SEQ=$((OSD_SEQ + 1))
        log "  ${hostname}: ${dev} (OSD #${OSD_SEQ})"

        ssh_to_slave "$ip" "
            set -e
            DBWAL_MNT='${DBWAL_MNT}'
            DB_SIZE='${DB_SIZE}'
            WAL_SIZE='${WAL_SIZE}'

            # Create DB + WAL files on tmpfs
            db_file=\${DBWAL_MNT}/db-osd${OSD_SEQ}.img
            wal_file=\${DBWAL_MNT}/wal-osd${OSD_SEQ}.img
            sudo rm -f \${db_file} \${wal_file}
            sudo truncate -s \${DB_SIZE} \${db_file}
            sudo truncate -s \${WAL_SIZE} \${wal_file}

            # Create loop devices + LVM LVs for DB/WAL
            db_loop=\$(sudo losetup -f --show \${db_file})
            wal_loop=\$(sudo losetup -f --show \${wal_file})
            db_vg=ceph-vg-db${OSD_SEQ}
            wal_vg=ceph-vg-wal${OSD_SEQ}
            sudo pvcreate -ff -y \${db_loop} 2>/dev/null || true
            sudo pvcreate -ff -y \${wal_loop} 2>/dev/null || true
            sudo vgcreate \${db_vg} \${db_loop} 2>/dev/null || true
            sudo vgcreate \${wal_vg} \${wal_loop} 2>/dev/null || true
            sudo lvremove -f \${db_vg} 2>/dev/null || true
            sudo lvremove -f \${wal_vg} 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd-db \${db_vg}
            sudo lvcreate -l 100%FREE -n osd-wal \${wal_vg}
            sudo dmsetup mknodes 2>/dev/null || true

            # Create LVM LV for DATA
            data_vg=ceph-vg-osd${OSD_SEQ}
            sudo pvcreate -ff -y ${dev} 2>/dev/null || true
            sudo vgcreate \${data_vg} ${dev} 2>/dev/null || true
            sudo lvremove -f \${data_vg} 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd \${data_vg}
            echo \"  OK: data=/dev/\${data_vg}/osd db=/dev/\${db_vg}/osd-db wal=/dev/\${wal_vg}/osd-wal\"
        " 2>&1 | grep -E "OK|Error" || log "  WARNING: LV prep issue on ${hostname}:${dev}"
    done
done
log "  All LVs prepared (${OSD_SEQ} OSDs)"

# ============================================================
# Step 5: Deploy OSDs via ceph orch
# ============================================================
log ">>> Step 5: Deploying OSDs via ceph orch..."
for seq in $(seq 1 ${OSD_SEQ}); do
    case $seq in
        1|2) host="ceph-node1" ;;
        3|4) host="ceph-node2" ;;
        5|6) host="ceph-node3" ;;
    esac
    data_lv="/dev/ceph-vg-osd${seq}/osd"
    db_lv="/dev/ceph-vg-db${seq}/osd-db"
    wal_lv="/dev/ceph-vg-wal${seq}/osd-wal"
    log "  OSD #${seq} on ${host}"
    result=$(ssh_to_client "sudo ceph orch daemon add osd ${host}:data_devices=${data_lv},db_devices=${db_lv},wal_devices=${wal_lv} 2>&1" 2>/dev/null)
    echo "$result" | tail -1
    sleep 3
done

# ============================================================
# Step 6: Fix "already created?" OSDs — activate + fix auth
# ============================================================
log ">>> Step 6: Activating OSDs and fixing auth keys..."
sleep 30  # Wait for ceph orch to process

for ip in "${CEPH_SERVERS[@]}"; do
    hostname="${CEPH_HOSTNAMES[$ip]}"
    log "  Activating on ${hostname}..."

    # Activate all OSDs on this node (creates data dirs, symlinks, keyring)
    ssh_to_slave "$ip" "sudo ceph-volume lvm activate --all 2>&1 | tail -5" 2>/dev/null

    # For each OSD on this node, check if auth key exists in mon; if not, add it
    ssh_to_slave "$ip" '
        for osd_dir in /var/lib/ceph/osd/ceph-*; do
            [ -d "$osd_dir" ] || continue
            osd_id=$(basename "$osd_dir" | sed "s/ceph-//")
            key=$(sudo cat "$osd_dir/keyring" 2>/dev/null | grep "key = " | awk "{print \$3}")
            if [ -n "$key" ]; then
                # Check if mon has this key
                has_key=$(sudo ceph auth get osd.$osd_id 2>&1 | grep -c "key = ")
                if [ "$has_key" = "0" ]; then
                    echo "  Fixing auth for osd.$osd_id (key from local keyring)"
                    sudo ceph auth add osd.$osd_id -i /dev/stdin << EOF 2>/dev/null || true
[osd.$osd_id]
	key = $key
	caps mgr = "allow profile osd"
	caps mon = "allow profile osd"
	caps osd = "allow *"
EOF
                fi
            fi
        done
    ' 2>/dev/null
done

# ============================================================
# Step 7: Start all OSDs (reset-failed + start)
# ============================================================
log ">>> Step 7: Starting all OSDs..."
for ip in "${CEPH_SERVERS[@]}"; do
    hostname="${CEPH_HOSTNAMES[$ip]}"
    ssh_to_slave "$ip" '
        # Reset failed state for all ceph-osd services
        for svc in $(systemctl list-units "ceph-osd@*" --all --no-legend 2>/dev/null | awk "{print \$1}"); do
            sudo systemctl reset-failed "$svc" 2>/dev/null || true
        done
        # Start all ceph-osd services
        for osd_dir in /var/lib/ceph/osd/ceph-*; do
            [ -d "$osd_dir" ] || continue
            osd_id=$(basename "$osd_dir" | sed "s/ceph-//")
            sudo systemctl start ceph-osd@$osd_id 2>/dev/null || true
        done
        sleep 3
        running=$(systemctl list-units "ceph-osd@*" --no-legend 2>/dev/null | grep active | wc -l)
        echo "'${hostname}': $running OSDs running"
    ' 2>/dev/null
done

# ============================================================
# Step 8: Wait for all OSDs up + PGs active+clean
# ============================================================
log ">>> Step 8: Waiting for OSDs and PGs..."
ssh_to_client "
# Wait for OSDs up
for i in \$(seq 1 30); do
    up_count=\$(sudo ceph osd stat 2>/dev/null | grep -oP '\d+(?= osds:)' | head -1)
    [ -n \"\$up_count\" ] && [ \"\$up_count\" -ge ${OSD_SEQ} ] && break
    sleep 5
done
echo \"OSDs up: \$up_count/${OSD_SEQ}\"

# Wait for PGs
for i in \$(seq 1 60); do
    pg_status=\$(sudo ceph -s 2>/dev/null | grep 'pgs:' | head -1)
    echo \"\$pg_status\"
    echo \"\$pg_status\" | grep -qE 'unknown|not active|creating|peering|recovering|degraded|incomplete|stale' || break
    sleep 5
done
sudo ceph osd tree 2>/dev/null
sudo ceph health 2>/dev/null
" 2>/dev/null

# ============================================================
# Step 9: Fix .mgr pool if stuck (delete + mgr fail → recreate)
# ============================================================
log ">>> Step 9: Fixing .mgr pool if stuck..."
ssh_to_client "
mgr_stuck=\$(sudo ceph pg dump_stuck 2>/dev/null | grep -c '73\.')
if [ \"\$mgr_stuck\" -gt 0 ]; then
    echo '  .mgr pool stuck, recreating...'
    sudo ceph config set mon mon_allow_pool_delete true 2>/dev/null
    sudo ceph osd pool delete .mgr .mgr --yes-i-really-really-mean-it 2>/dev/null || true
    sleep 5
    sudo ceph mgr fail 2>/dev/null
    sleep 30
    echo '  .mgr pool recreated'
fi
sudo ceph health 2>/dev/null
" 2>/dev/null

# ============================================================
# Step 10: Recreate EC pool (fast_read=true)
# ============================================================
log ">>> Step 10: Recreating EC pool ${POOL}..."
ssh_to_client "
set -e
sudo ceph config set mon mon_allow_pool_delete true 2>/dev/null || true

# Delete old pool if exists
sudo ceph osd pool delete ${POOL} ${POOL} --yes-i-really-really-mean-it 2>/dev/null || true
sleep 5

# EC profile
sudo ceph osd erasure-code-profile set ec-prod k=${EC_K} m=${EC_M} crush-failure-domain=${FAILURE_DOMAIN} 2>/dev/null || true

# Create EC pool
sudo ceph osd pool create ${POOL} ${PG_NUM} ${PG_NUM} erasure ec-prod 2>/dev/null

# allow_ec_overwrites
sudo ceph osd pool set ${POOL} allow_ec_overwrites true 2>/dev/null

# fast_read=true (critical for stable EC read performance)
sudo ceph osd pool set ${POOL} fast_read true 2>/dev/null

# Application label
sudo ceph osd pool application enable ${POOL} juicefs 2>/dev/null

# cephx client
sudo ceph auth get-or-create client.juicefs mon 'allow r' osd 'allow class-read object_prefix rbd_directory_pool, allow rwx pool=${POOL}' 2>/dev/null

echo 'Pool created:'
sudo ceph osd pool ls detail 2>/dev/null
echo ''
echo 'client.juicefs key:'
sudo ceph auth get client.juicefs 2>/dev/null
" 2>/dev/null

# ============================================================
# Step 11: Write ceph.conf + keyring on 157
# NOTE: Can't pipe ssh_to_slave | ssh_to_client through 3-layer SSH.
#       Instead, run ceph commands from 157 directly (157 has ceph CLI).
# ============================================================
log ">>> Step 11: Writing ceph.conf + keyring on 157..."
ssh_to_client '
# Write ceph.conf (hardcoded — it only changes if mon IPs change, which they don't)
sudo tee /etc/ceph/ceph.conf > /dev/null << '\''CONFEOF'\''
# minimal ceph.conf for 4f4e3ca0-8297-11f1-a671-97520597268c
[global]
	fsid = 4f4e3ca0-8297-11f1-a671-97520597268c
	mon_host = [v2:10.3.1.6:3300/0,v1:10.3.1.6:6789/0] [v2:10.3.1.7:3300/0,v1:10.3.1.7:6789/0] [v2:10.3.1.8:3300/0,v1:10.3.1.8:6789/0]
CONFEOF
sudo chmod 644 /etc/ceph/ceph.conf

# Write client.juicefs keyring (fetched from mon via ceph CLI on 157)
sudo ceph auth get client.juicefs 2>/dev/null | sudo tee /etc/ceph/ceph.client.juicefs.keyring > /dev/null
# Keyring must be world-readable for non-sudo juicefs (sunrise user)
sudo chmod 644 /etc/ceph/ceph.client.juicefs.keyring

echo "ceph.conf and keyring written on 157"
# Verify
sudo ceph osd pool ls 2>/dev/null
' 2>/dev/null

# ============================================================
# Done
# ============================================================
log ">>> Waiting for final HEALTH_OK..."
for i in $(seq 1 12); do
    health=$(ssh_to_client "sudo ceph health 2>/dev/null" 2>/dev/null)
    echo "$health"
    echo "$health" | grep -q "HEALTH_OK" && break
    sleep 10
done

log "=== rebuild-osds.sh DONE ==="
log "  OSDs: $(ssh_to_client 'sudo ceph osd stat 2>/dev/null' 2>/dev/null)"
log "  Health: $(ssh_to_client 'sudo ceph health 2>/dev/null' 2>/dev/null)"
log "  Pool: $(ssh_to_client 'sudo ceph osd pool ls 2>/dev/null' 2>/dev/null)"
