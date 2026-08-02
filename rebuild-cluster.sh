#!/bin/bash
set -euo pipefail

# ============================================================
# rebuild-cluster.sh — 重建 Ceph OSD + 部署 TiKV/PD（3 节点）
#
# 在 .11/.13/.14 上：
#   1. 销毁现有 6 个 OSD（tmpfs 上的，数据全丢——可接受）
#   2. sdb 重建 VG → 3 LV（osd0 ~300G + osd1 ~300G + tikv ~350G）
#   3. tmpfs DB 设备（10G/OSD，loop device）
#   4. 部署 2 OSD/节点（block=sdb LV, DB=tmpfs loop）
#   5. 部署 PD + TiKV（3 节点 3 副本 Raft，数据在 sdb LV3）
#   6. 创建 cephx client.juicefs
#
# 前提：
#   - MON/MGR 已就位（不重建）
#   - EC pool juicefs-data 已存在（OSD 重建后 PG 重新映射）
#   - sshpass 可用，turboai NOPASSWD sudo
# ============================================================

PW="TurboAi@303"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

NODES=("192.168.11.11" "192.168.11.13" "192.168.11.14")
HOSTNAMES=("ceph-node1" "ceph-node2" "ceph-node3")
PRIMARY="192.168.11.11"

run() {
    local ip=$1; shift
    sshpass -p "$PW" ssh $SSH_OPTS "turboai@${ip}" "$@"
}

ceph_cmd() {
    run "$PRIMARY" "sudo cephadm shell -- ceph $* 2>/dev/null" 2>/dev/null
}

echo "========================================"
echo " Cluster Rebuild: 3 LV on sdb + TiKV/PD"
echo "========================================"
echo "Nodes: ${NODES[*]}"
echo "Primary: ${PRIMARY}"
echo ""

# ============================================================
# Step 1: Destroy existing OSDs
# ============================================================
echo ">>> Step 1: Destroying existing OSDs..."

# Set noout to prevent rebalance during destroy
ceph_cmd osd set noout 2>/dev/null || true

# Get all OSD IDs
OSD_IDS=$(ceph_cmd osd ls 2>/dev/null | tr '\n' ' ')
echo "  OSDs to destroy: ${OSD_IDS}"

for id in $OSD_IDS; do
    echo -n "  Destroying osd.${id}... "
    ceph_cmd orch daemon stop osd.${id} 2>/dev/null || true
    sleep 3
    ceph_cmd osd destroy ${id} --yes-i-really-really-mean-it 2>/dev/null || true
    ceph_cmd osd crush rm osd.${id} 2>/dev/null || true
    ceph_cmd auth del osd.${id} 2>/dev/null || true
    echo "done"
done

ceph_cmd osd unset noout 2>/dev/null || true
echo "  OSDs destroyed."

# ============================================================
# Step 2: Clean up on each node (loop devices, tmpfs, VGs)
# ============================================================
echo ""
echo ">>> Step 2: Cleaning up loop devices, tmpfs, VGs on each node..."

for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"
    echo "--- ${host} (${ip}) ---"
    run "$ip" "
        # Detach all loop devices used by ceph
        for dev in /dev/loop{20,21,30,31}; do
            sudo losetup -d \$dev 2>/dev/null || true
        done
        # Also detach any remaining ceph-related loops
        sudo losetup -l 2>/dev/null | grep -E 'memdisk|bs-db' | awk '{print \$1}' | while read -r ldev; do
            sudo losetup -d \"\$ldev\" 2>/dev/null || true
        done

        # Unmount tmpfs
        sudo umount /tmp/memdisk 2>/dev/null || true
        sudo umount /tmp/bs-db-osd0 2>/dev/null || true
        sudo umount /tmp/bs-db-osd1 2>/dev/null || true
        sudo umount /mnt/dbwal 2>/dev/null || true

        # Remove all ceph-related VGs
        sudo vgremove -f ceph-vg-${host} 2>/dev/null || true
        for vg in ceph-vg-data0 ceph-vg-data1 ceph-vg-db0 ceph-vg-db1 ceph-vg; do
            sudo vgremove -f \$vg 2>/dev/null || true
        done

        # Remove PVs on sdb
        sudo pvremove -ff -y /dev/sdb 2>/dev/null || true

        # Wipe sdb partition table
        sudo sgdisk -Z /dev/sdb 2>/dev/null || true
        sudo wipefs -af /dev/sdb 2>/dev/null || true
        sudo partprobe /dev/sdb 2>/dev/null || true

        # Clean up old tmp dirs
        sudo rm -rf /tmp/memdisk /tmp/bs-db-osd0 /tmp/bs-db-osd1 2>/dev/null || true

        echo '  cleanup done'
    " 2>/dev/null
done

# ============================================================
# Step 3: On each node — set up tmpfs DB + sdb 3 LVs
# ============================================================
echo ""
echo ">>> Step 3: Setting up tmpfs DB + 3 LVs on sdb..."

for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"
    vg_name="ceph-vg-${host}"
    echo "--- ${host} (${ip}) ---"
    run "$ip" "
        set -e

        # --- tmpfs for DB (10G per OSD = 20G per node) ---
        sudo mkdir -p /tmp/bs-db-osd0 /tmp/bs-db-osd1
        sudo mount -t tmpfs -o size=10G tmpfs /tmp/bs-db-osd0
        sudo mount -t tmpfs -o size=10G tmpfs /tmp/bs-db-osd1
        # Create DB files
        dd if=/dev/zero of=/tmp/bs-db-osd0/db_device bs=1M count=10240 status=none
        dd if=/dev/zero of=/tmp/bs-db-osd1/db_device bs=1M count=10240 status=none
        # Setup loop devices
        sudo losetup /dev/loop20 /tmp/bs-db-osd0/db_device
        sudo losetup /dev/loop21 /tmp/bs-db-osd1/db_device
        # Create PV + VG + LV for DB
        sudo pvcreate -ff -y /dev/loop20 /dev/loop21 2>/dev/null
        sudo vgcreate ceph-vg-db0 /dev/loop20
        sudo vgcreate ceph-vg-db1 /dev/loop21
        sudo lvcreate -l 100%FREE -n osd-db0 ceph-vg-db0
        sudo lvcreate -l 100%FREE -n osd-db1 ceph-vg-db1
        echo '  DB tmpfs + loop devices ready'

        # --- sdb: PV + VG + 3 LVs ---
        sudo pvcreate -ff -y /dev/sdb
        sudo vgcreate ${vg_name} /dev/sdb
        # 2 OSD LVs (~300G each) + 1 TiKV LV (rest ~350G)
        sudo lvcreate -L 300G -n osd0 ${vg_name}
        sudo lvcreate -L 300G -n osd1 ${vg_name}
        sudo lvcreate -l 100%FREE -n tikv ${vg_name}
        echo '  sdb 3 LVs created:'
        sudo lvs --noheadings -o lv_name,lv_size ${vg_name}
    " 2>/dev/null
    echo ""
done

# ============================================================
# Step 4: Deploy OSDs via ceph orch (block=sdb LV, DB=tmpfs LV)
# ============================================================
echo ""
echo ">>> Step 4: Deploying OSDs (2 per node, block=sdb LV, DB=tmpfs LV)..."

for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"
    vg_name="ceph-vg-${host}"

    for lv in osd0 osd1; do
        lv_num=$(echo "$lv" | grep -oP '\d')
        db_vg="ceph-vg-db${lv_num}"
        db_lv="osd-db${lv_num}"
        data_path="/dev/${vg_name}/${lv}"
        db_path="/dev/${db_vg}/${db_lv}"

        echo -n "  ${host}: OSD data=${data_path} db=${db_path}... "
        result=$(run "$PRIMARY" \
            "sudo cephadm shell -- ceph orch daemon add osd ${host}:data_devices=${data_path},db_devices=${db_path} 2>&1" 2>/dev/null)
        if echo "$result" | grep -q "Created"; then
            echo "OK"
        else
            echo "RESULT: $result"
        fi
    done
done

echo ""
echo ">>> Waiting for OSDs (60s)..."
sleep 60

OSD_COUNT=$(ceph_cmd osd stat 2>/dev/null | grep -oP '\d+(?= osds)' || echo "0")
echo "  OSDs: ${OSD_COUNT} (expected 6)"

if [ "${OSD_COUNT}" -lt 6 ]; then
    echo "  WARNING: not all OSDs up yet, waiting more (60s)..."
    sleep 60
    OSD_COUNT=$(ceph_cmd osd stat 2>/dev/null | grep -oP '\d+(?= osds)' || echo "0")
    echo "  OSDs: ${OSD_COUNT}"
fi

ceph_cmd osd tree 2>/dev/null || true

# ============================================================
# Step 5: Verify EC pool + create cephx client.juicefs
# ============================================================
echo ""
echo ">>> Step 5: Verifying EC pool + creating cephx client..."

# Wait for PGs to settle
echo "  Waiting for PGs (60s)..."
sleep 60

echo "  Ceph health:"
ceph_cmd health 2>/dev/null || true
echo ""
echo "  Pool list:"
ceph_cmd osd pool ls 2>/dev/null || true

# Ensure EC pool exists (recreate if missing)
if ! ceph_cmd osd pool ls 2>/dev/null | grep -q "juicefs-data"; then
    echo "  juicefs-data pool missing, recreating..."
    ceph_cmd osd erasure-code-profile set ec-prod k=4 m=2 crush-failure-domain=osd 2>/dev/null || true
    ceph_cmd osd pool create juicefs-data erasure ec-prod 2>/dev/null || true
    ceph_cmd osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null || true
fi

# Create cephx client.juicefs
echo "  Creating cephx client.juicefs..."
ceph_cmd auth get-or-create client.juicefs mon "'allow r'" osd "'allow rwx pool=juicefs-data'" 2>/dev/null || true
echo "  client.juicefs key:"
ceph_cmd auth get client.juicefs 2>/dev/null || true

# ============================================================
# Step 6: Deploy TiKV + PD (3 nodes)
# ============================================================
echo ""
echo ">>> Step 6: Deploying TiKV + PD on 3 nodes..."

# Download TiKV + PD binaries to each node
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"
    vg_name="ceph-vg-${host}"
    tikv_data="/dev/${vg_name}/tikv"

    echo "--- ${host} (${ip}) ---"
    run "$ip" "
        set -e

        # Mount the tikv LV
        sudo mkdir -p /mnt/tikv
        sudo mkfs.ext4 -q ${tikv_data} 2>/dev/null || true
        sudo mount ${tikv_data} /mnt/tikv 2>/dev/null || true

        # Subdirs for PD + TiKV data
        sudo mkdir -p /mnt/tikv/pd /mnt/tikv/tikv
        sudo chown -R turboai:turboai /mnt/tikv

        # Add to fstab for persistence
        if ! grep -q '/mnt/tikv' /etc/fstab 2>/dev/null; then
            echo \"${tikv_data} /mnt/tikv ext4 defaults,noatime 0 0\" | sudo tee -a /etc/fstab > /dev/null
        fi

        # Download TiKV + PD if not present
        if [ ! -f /mnt/tikv/tikv-server ]; then
            echo '  Downloading TiKV v7.1.5...'
            curl -sSL -o /tmp/tikv.tar.gz 'https://tiup-mirrors.pingcap.com/tikv-v7.1.5-linux-amd64.tar.gz' 2>/dev/null || {
                echo '  ERROR: download failed'; exit 1; }
            tar -xzf /tmp/tikv.tar.gz -C /tmp
            cp /tmp/tikv-v7.1.5-linux-amd64/bin/tikv-server /mnt/tikv/
            echo '  TiKV downloaded'
        else
            echo '  TiKV already present'
        fi

        if [ ! -f /mnt/tikv/pd-server ]; then
            echo '  Downloading PD v7.1.5...'
            curl -sSL -o /tmp/pd.tar.gz 'https://tiup-mirrors.pingcap.com/pd-v7.1.5-linux-amd64.tar.gz' 2>/dev/null || {
                echo '  ERROR: download failed'; exit 1; }
            tar -xzf /tmp/pd.tar.gz -C /tmp
            cp /tmp/pd-v7.1.5-linux-amd64/bin/pd-server /mnt/tikv/
            echo '  PD downloaded'
        else
            echo '  PD already present'
        fi

        echo '  Binaries ready'
    " 2>/dev/null
    echo ""
done

# Build PD endpoints (http://ip:2379 for TiKV --pd-endpoints)
PD_ENDPOINTS=""
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    if [ -n "$PD_ENDPOINTS" ]; then
        PD_ENDPOINTS+=","
    fi
    PD_ENDPOINTS+="http://${ip}:2379"
done

# Build PD initial-cluster (name=http://ip:2380)
PD_INITIAL_CLUSTER=""
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"
    if [ -n "$PD_INITIAL_CLUSTER" ]; then
        PD_INITIAL_CLUSTER+=","
    fi
    PD_INITIAL_CLUSTER+="${host}=http://${ip}:2380"
done

echo "  PD endpoints: ${PD_ENDPOINTS}"
echo "  PD initial cluster: ${PD_INITIAL_CLUSTER}"
echo ""

# Create PD config and start PD on each node
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"

    echo "  Starting PD on ${host} (${ip})..."
    run "$ip" "
        # Stop existing PD if any
        sudo systemctl stop pd 2>/dev/null || true

        # Create systemd unit for PD
        sudo tee /etc/systemd/system/pd.service > /dev/null <<'PDEOF'
[Unit]
Description=PD Server
After=network.target

[Service]
User=turboai
ExecStart=/mnt/tikv/pd-server --name=__NAME__ --data-dir=/mnt/tikv/pd --client-urls=http://0.0.0.0:2379 --peer-urls=http://0.0.0.0:2380 --initial-cluster=__CLUSTER__ --log-file=/mnt/tikv/pd.log
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
PDEOF

        # Replace placeholders
        sudo sed -i 's|__NAME__|${host}|g' /etc/systemd/system/pd.service
        sudo sed -i 's|__CLUSTER__|${PD_INITIAL_CLUSTER}|g' /etc/systemd/system/pd.service

        sudo systemctl daemon-reload
        sudo systemctl enable pd
        sudo systemctl start pd
        sleep 3
        sudo systemctl is-active pd && echo '  PD running' || echo '  PD FAILED to start'
    " 2>/dev/null
done

echo ""
echo "  Waiting for PD cluster (10s)..."
sleep 10

# Verify PD health
echo "  PD health:"
curl -s http://${PRIMARY}:2379/pd/api/v1/health 2>/dev/null || echo "  (checking from WSL may fail if network route)"

# Create systemd service files for TiKV on each node
for i in "${!NODES[@]}"; do
    ip="${NODES[$i]}"
    host="${HOSTNAMES[$i]}"

    echo "  Starting TiKV on ${host} (${ip})..."
    run "$ip" "
        # Stop existing TiKV if any
        sudo systemctl stop tikv 2>/dev/null || true

        # Create systemd unit for TiKV
        sudo tee /etc/systemd/system/tikv.service > /dev/null <<'TKEOF'
[Unit]
Description=TiKV Server
After=network.target pd.service

[Service]
User=turboai
ExecStart=/mnt/tikv/tikv-server --pd-endpoints=__PD__ --addr=0.0.0.0:20160 --data-dir=/mnt/tikv/tikv --log-file=/mnt/tikv/tikv.log
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
TKEOF

        # Replace placeholder
        sudo sed -i 's|__PD__|${PD_ENDPOINTS}|g' /etc/systemd/system/tikv.service

        sudo systemctl daemon-reload
        sudo systemctl enable tikv
        sudo systemctl start tikv
        sleep 5
        sudo systemctl is-active tikv && echo '  TiKV running' || echo '  TiKV FAILED to start'
    " 2>/dev/null
done

echo ""
echo "  Waiting for TiKV to register with PD (15s)..."
sleep 15

# ============================================================
# Step 7: Verify
# ============================================================
echo ""
echo ">>> Step 7: Final verification..."

echo ""
echo "=== Ceph status ==="
ceph_cmd status 2>/dev/null || true

echo ""
echo "=== OSD tree ==="
ceph_cmd osd tree 2>/dev/null || true

echo ""
echo "=== PD/TiKV status (from .11) ==="
run "$PRIMARY" "curl -s http://127.0.0.1:2379/pd/api/v1/health 2>/dev/null; echo; curl -s http://127.0.0.1:2379/pd/api/v1/stores 2>/dev/null | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(f'  store {s[\\\"store\\\"][\\\"id\\\"]}: {s[\\\"store\\\"][\\\"address\\\"]} state={s[\\\"store\\\"][\\\"state_name\\\"]}') for s in d.get('stores',[])]\" 2>/dev/null" 2>/dev/null || true

echo ""
echo "========================================"
echo " Rebuild complete"
echo "========================================"
echo "PD endpoints: ${PD_ENDPOINTS}"
echo "TiKV data: /mnt/tikv/tikv (on sdb LV3 per node)"
echo "PD data: /mnt/tikv/pd (on sdb LV3 per node)"
echo "OSD block: sdb LV1+LV2 per node"
echo "OSD DB: tmpfs loop device (10G per OSD)"
echo ""
echo "Next: set up JuiceFS client on WSL"
