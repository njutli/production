#!/bin/bash
set -euo pipefail

# ============================================================
# Ceph Deployment (3 servers, NO RGW, direct RADOS)
#
# 3 nodes (150-152), 2 OSD disks per node (nvme2n1 + nvme3n1) = 6 OSDs.
# DATA on physical NVMe (1 disk = 1 OSD, LVM wrapper for ceph-volume).
# DB/WAL on tmpfs 内存盘 (loop device; ⚠️ 测试专用—断电丢，重建即可).
# EC 4+2, allow_ec_overwrites, failure-domain=osd.
# Dual network: public=10.3.1.0/24, cluster=10.3.2.0/24 (both 100GbE).
# JuiceFS uses --storage ceph (librados direct, no RGW).
#
# SSH: WSL → HK ECS → 157 → slaves (three-level jump host via _run).
#
# Prerequisites:
#   1. config.sh filled correctly
#   2. NOPASSWD sudo on all Ceph nodes
#   3. OSD disks (nvme2n1, nvme3n1) unmounted or remountable
#   4. tmpfs mounted at /mnt/dbwal (prepare-servers.sh handles)
#
# Usage: bash deploy-ceph.sh [--yes]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../${CONFIG_FILE:-config.sh}"

AUTO_YES=false
[ "${1:-}" = "--yes" ] && AUTO_YES=true

PRIMARY="${CEPH_PRIMARY}"

echo "========================================"
echo "Ceph Deployment (NO RGW — direct RADOS)"
echo "========================================"
echo "Nodes:    ${CEPH_SERVERS[*]}"
echo "Primary:  ${PRIMARY}"
echo "OSD disks: ${CEPH_OSD_DEVICES_PER_NODE[*]} per node (6 total)"
echo "DB/WAL:   tmpfs 内存盘 (loop device, ⚠️ 测试专用)"
echo "EC pool:  ${CEPH_EC_K}+${CEPH_EC_M} (failure-domain=${CEPH_FAILURE_DOMAIN})"
echo "Public:   ${CEPH_PUBLIC_NETWORK}  (${PUBLIC_NIC})"
echo "Cluster:  ${CEPH_CLUSTER_NETWORK}  (${CLUSTER_NIC})"
echo "========================================"
echo ""

# ============================================================
# Pre-flight: SSH + sudo + disk checks
# ============================================================

echo ">>> Pre-flight checks..."
for ip in "${CEPH_SERVERS[@]}"; do
    echo -n "  ${ip}: "
    _run "${ip}" "echo -n 'sudo='; sudo -n true 2>/dev/null && echo -n 'OK ' || echo -n 'FAIL '; echo -n 'tmpfs='; mountpoint -q ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} 2>/dev/null && echo -n 'OK ' || echo -n 'MISSING '; echo 'reachable'" 2>/dev/null || { echo "UNREACHABLE"; exit 1; }
done

# Verify OSD disks exist and are not mounted (or mountable)
echo ""
echo ">>> Disk checks..."
for ip in "${CEPH_SERVERS[@]}"; do
    echo "  ${ip}:"
    for dev in "${CEPH_OSD_DEVICES_PER_NODE[@]}"; do
        _run "${ip}" "
            if [ ! -b ${dev} ]; then
                echo '    ${dev}: NOT FOUND!'; exit 1
            fi
            if mount | grep -q '^${dev} '; then
                echo '    ${dev}: mounted (will unmount before OSD deploy)'
            else
                echo '    ${dev}: OK (not mounted)'
            fi
        " 2>/dev/null || true
    done
done

echo ""
if [ "${AUTO_YES}" = true ]; then
    echo ">>> Auto-confirmed (--yes)"
else
    read -rp "Continue with deployment? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ============================================================
# Step 1: Prepare all servers (podman, cephadm, root SSH)
# ============================================================

echo ""
echo ">>> Step 1: Preparing all servers..."

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo "  >>> ${ip} (${hostname})..."
    _run "${ip}" "
        set -e

        # Set hostname (nodes renamed to ceph-nodeN)
        sudo hostnamectl set-hostname ${hostname}

        sudo apt-get update -qq || true

        # Install podman (cephadm requires it)
        if ! command -v podman &>/dev/null; then
            echo '  installing podman...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman 2>/dev/null || {
                sudo apt-get --fix-broken install -y 2>/dev/null || true
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman 2>/dev/null || {
                    echo '  ERROR: podman install failed'; exit 1
                }
            }
        else echo '  podman OK'; fi

        # Install disk tools
        command -v sgdisk &>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted 2>/dev/null || true

        # Ensure ceph-volume is available (for OSD deployment in Step 4)
        command -v ceph-volume &>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ceph-osd 2>/dev/null || true

        # Stop docker if present (conflicts with podman)
        sudo systemctl stop docker docker.socket 2>/dev/null || true
        sudo systemctl disable docker docker.socket 2>/dev/null || true

        # Install cephadm + ceph-common
        if ! command -v cephadm &>/dev/null; then
            echo '  installing cephadm...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cephadm ceph-common 2>/dev/null || {
                echo '  apt failed, downloading cephadm...'
                curl -sSL -o /tmp/cephadm 'https://github.com/ceph/ceph/raw/reef/src/cephadm/cephadm'
                head -1 /tmp/cephadm | grep -q python && chmod +x /tmp/cephadm && sudo mv /tmp/cephadm /usr/local/bin/cephadm || {
                    echo '  ERROR: cephadm install failed'; exit 1
                }
            }
        else echo '  cephadm OK'; fi

        # Enable root SSH (cephadm inter-node SSH uses root)
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
        sudo passwd -S root | grep -q ' L ' && sudo passwd -u root 2>/dev/null || true

        # Pull Ceph container image
        if ! sudo podman image exists quay.io/ceph/ceph:v19 2>/dev/null; then
            echo '  pulling ceph container image...'
            sudo podman pull quay.io/ceph/ceph:v19 2>&1 | tail -1 || echo '  WARNING: pull failed (bootstrap will retry)'
        else echo '  ceph image cached'; fi

        echo '  done'
    " || { echo "  ERROR: prepare failed on ${ip}"; exit 1; }
done

# ============================================================
# Step 2: Bootstrap Ceph on PRIMARY
# ============================================================

echo ""
echo ">>> Step 2: Bootstrapping Ceph on ${PRIMARY}..."

_run "${PRIMARY}" "
    set -e
    if [ -d /etc/ceph ] && [ -f /etc/ceph/ceph.conf ]; then
        echo '  Ceph already bootstrapped, skipping.'
    else
        echo '  Running cephadm bootstrap...'
        sudo cephadm bootstrap \
            --mon-ip ${CEPH_PRIMARY_MON_IP} \
            --allow-fqdn-hostname \
            --skip-prepare-host \
            --skip-dashboard \
            --skip-monitoring-stack 2>&1 | grep -v 'Inferring\|Using ceph\|quay.io' || true
        echo '  Bootstrap complete.'
    fi
" || { echo "  ERROR: bootstrap failed"; exit 1; }

# ============================================================
# Step 2b: Dual network configuration
# ============================================================

echo ""
echo ">>> Step 2b: Configuring dual network..."

_run "${PRIMARY}" "
    sudo cephadm shell -- ceph config set global public_network '${CEPH_PUBLIC_NETWORK}' 2>/dev/null || true
    sudo cephadm shell -- ceph config set global cluster_network '${CEPH_CLUSTER_NETWORK}' 2>/dev/null || true
    # mon 级别覆盖：bootstrap 会设 mon public_network = MON IP 所在网段
    # 必须显式设为目标 public_network，否则 mon 一直用 bootstrap 时的网段
    sudo cephadm shell -- ceph config set mon public_network '${CEPH_PUBLIC_NETWORK}' 2>/dev/null || true
    sudo cephadm shell -- ceph config set mon cluster_network '${CEPH_CLUSTER_NETWORK}' 2>/dev/null || true
    echo '  public_network  = ${CEPH_PUBLIC_NETWORK}  (${PUBLIC_NIC})'
    echo '  cluster_network = ${CEPH_CLUSTER_NETWORK}  (${CLUSTER_NIC})'
"

# ============================================================
# Step 3: Root SSH between Ceph nodes + add secondary nodes
# ============================================================

echo ""
echo ">>> Step 3: Root SSH setup + adding secondary nodes..."

# Extract cephadm SSH public key
_CEPH_PUB=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph config-key get mgr/cephadm/ssh_identity_pub 2>/dev/null" 2>/dev/null || echo "")
if [ -n "${_CEPH_PUB}" ]; then
    for ip in "${CEPH_SERVERS[@]}"; do
        _run "${ip}" "
            sudo mkdir -p /root/.ssh
            echo '${_CEPH_PUB}' | sudo tee /root/.ssh/authorized_keys >/dev/null
            sudo chmod 600 /root/.ssh/authorized_keys
            sudo chown -R root:root /root/.ssh
        " 2>/dev/null || true
    done
fi

# Extract cephadm SSH private key
_CEPH_PRIV=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph config-key get mgr/cephadm/ssh_identity_key 2>/dev/null" 2>/dev/null || echo "")
if [ -n "${_CEPH_PRIV}" ]; then
    for ip in "${CEPH_SERVERS[@]}"; do
        _run "${ip}" "
            echo '${_CEPH_PRIV}' | sudo tee /root/.ssh/id_rsa >/dev/null
            sudo chmod 600 /root/.ssh/id_rsa
            sudo chown root:root /root/.ssh/id_rsa
        " 2>/dev/null || true
    done
fi
echo "  Root SSH keys deployed on all nodes."

# Add secondary nodes
for i in 1 2; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo "  Adding ${hostname} (${ip})..."
    _run "${PRIMARY}" "sudo cephadm shell -- ceph orch host add ${hostname} ${ip} 2>&1" 2>/dev/null || echo "  (may already exist)"
    _run "${PRIMARY}" "sudo cephadm shell -- ceph orch host label add ${hostname} _admin 2>/dev/null" || true
done

# Apply MON placement on all 3 nodes
_run "${PRIMARY}" "sudo cephadm shell -- ceph orch apply mon 'ceph-node1,ceph-node2,ceph-node3' 2>/dev/null || true"
echo "  Waiting for MON+MGR on all nodes (60s)..."
sleep 60

HOST_COUNT=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph orch host ls --format json 2>/dev/null" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "  Hosts online: ${HOST_COUNT} (expected 3)"

# ============================================================
# Step 3b: Extract bootstrap-osd keyring for ceph-volume
# ============================================================
# cephadm stores keyring inside /var/lib/ceph/<fsid>/, but ceph-volume
# (running on host) looks at /var/lib/ceph/bootstrap-osd/ceph.keyring.
# Extract from Ceph auth DB and place at the expected path on all nodes.

echo ""
echo ">>> Step 3b: Extracting bootstrap-osd keyring for ceph-volume..."
BOSD_KEYRING=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph auth get client.bootstrap-osd 2>/dev/null | grep -v exported" 2>/dev/null)
if [ -n "${BOSD_KEYRING}" ]; then
    BOSD_B64=$(echo "${BOSD_KEYRING}" | base64 -w0)
    for ip in "${CEPH_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        _run "${ip}" "sudo mkdir -p /var/lib/ceph/bootstrap-osd && echo '${BOSD_B64}' | base64 -d | sudo tee /var/lib/ceph/bootstrap-osd/ceph.keyring > /dev/null && sudo chmod 600 /var/lib/ceph/bootstrap-osd/ceph.keyring && echo OK" 2>/dev/null
    done
else
    echo "  WARNING: Could not extract bootstrap-osd keyring"
fi

# ============================================================
# Step 4: Deploy 6 OSDs via ceph orch (DATA on NVMe, DB/WAL on tmpfs)
# ============================================================
# DATA: NVMe → PV → VG → LV
# DB/WAL: tmpfs → file → loop → PV → VG → LV
# 三者均为 LV，通过 ceph orch daemon add osd 一步部署
# OSD 由 cephadm 容器管理（非宿主机进程），HEALTH_OK 无 stray daemon
# ============================================================

echo ""
echo ">>> Step 4: Deploying OSDs (ceph orch, DATA on NVMe, DB/WAL on tmpfs)..."

OSD_SEQ=0
for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"

    for dev in "${CEPH_OSD_DEVICES_PER_NODE[@]}"; do
        OSD_SEQ=$((OSD_SEQ + 1))
        echo "  ${hostname}: ${dev} (OSD #${OSD_SEQ})..."

        # Wipe data disk
        _run "${ip}" "
            sudo umount ${dev} 2>/dev/null || true
            sudo sgdisk -Z ${dev} 2>/dev/null || true
            sudo wipefs -af ${dev} 2>/dev/null || true
            sudo partprobe ${dev} 2>/dev/null || true
        " 2>/dev/null || true

        sleep 2

        # Prepare DATA/DB/WAL LVs on the target node
        _run "${ip}" "
            set -e
            DBWAL_MNT='${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}'
            DB_SIZE='${CEPH_DB_SIZE:-40G}'
            WAL_SIZE='${CEPH_WAL_SIZE:-10G}'

            # Ensure tmpfs mounted
            sudo mountpoint -q \${DBWAL_MNT} 2>/dev/null || {
                sudo mkdir -p \${DBWAL_MNT}
                sudo mount -t tmpfs -o size=${CEPH_DB_WAL_TMPFS_SIZE:-200G} tmpfs \${DBWAL_MNT}
            }

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
            echo \"  DB LV: /dev/\${db_vg}/osd-db (on \${db_loop})\"
            echo \"  WAL LV: /dev/\${wal_vg}/osd-wal (on \${wal_loop})\"

            # Create LVM LV for DATA
            data_vg=ceph-vg-osd${OSD_SEQ}
            sudo pvcreate -ff -y ${dev} 2>/dev/null || true
            sudo vgcreate \${data_vg} ${dev} 2>/dev/null || true
            sudo lvremove -f \${data_vg} 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd \${data_vg}
            echo \"  DATA LV: /dev/\${data_vg}/osd\"
        " || { echo "  ERROR: LV preparation failed on ${ip}:${dev}"; exit 1; }

        # Deploy OSD via ceph orch (cephadm-managed container)
        data_lv="/dev/ceph-vg-osd${OSD_SEQ}/osd"
        db_lv="/dev/ceph-vg-db${OSD_SEQ}/osd-db"
        wal_lv="/dev/ceph-vg-wal${OSD_SEQ}/osd-wal"
        echo "  Deploying via ceph orch: data=${data_lv} db=${db_lv} wal=${wal_lv}"
        result=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph orch daemon add osd ${hostname}:data_devices=${data_lv},db_devices=${db_lv},wal_devices=${wal_lv} 2>&1" 2>/dev/null)
        if echo "${result}" | grep -q "Created"; then
            echo "  ${result}" | grep "Created"
        else
            echo "  WARNING: ${result}"
        fi
    done
done

echo "  Waiting for OSDs (90s)..."
sleep 90

OSD_COUNT=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph osd stat 2>/dev/null" | grep -oP '\d+(?= osds)' || echo "0")
echo "  OSDs: ${OSD_COUNT} (expected 6)"

echo ""
echo ">>> OSD tree:"
_run "${PRIMARY}" "sudo cephadm shell -- ceph osd tree 2>/dev/null" 2>/dev/null || true

echo ""
echo ">>> Ceph health:"
_run "${PRIMARY}" "sudo cephadm shell -- ceph health 2>/dev/null" 2>/dev/null || true

# ============================================================
# Step 5: Create EC pool + cephx client
# ============================================================

echo ""
echo ">>> Step 5: Creating EC ${CEPH_EC_K}+${CEPH_EC_M} pool (${CEPH_POOL_NAME})..."

_run "${PRIMARY}" "
    set -e
    sudo cephadm shell -- ceph config set mon mon_allow_pool_delete true 2>/dev/null || true

    # EC profile
    sudo cephadm shell -- ceph osd erasure-code-profile set ec-prod \
        k=${CEPH_EC_K} m=${CEPH_EC_M} \
        crush-failure-domain=${CEPH_FAILURE_DOMAIN} 2>/dev/null || true

    # Delete old pool if exists (re-run safe)
    sudo cephadm shell -- ceph osd pool delete ${CEPH_POOL_NAME} ${CEPH_POOL_NAME} --yes-i-really-really-mean-it 2>/dev/null || true

    # Create EC pool
    sudo cephadm shell -- ceph osd pool create ${CEPH_POOL_NAME} ${CEPH_PG_NUM} ${CEPH_PG_NUM} erasure ec-prod 2>/dev/null

    # allow_ec_overwrites (JuiceFS 整对象写不触发 RMW)
    sudo cephadm shell -- ceph osd pool set ${CEPH_POOL_NAME} allow_ec_overwrites true 2>/dev/null || true

    # Application label
    sudo cephadm shell -- ceph osd pool application enable ${CEPH_POOL_NAME} juicefs 2>/dev/null || true

    # cephx client.juicefs (权限限定到 juicefs-data 池)
    sudo cephadm shell -- ceph auth get-or-create client.juicefs \
        mon 'allow r' osd 'allow class-read object_prefix rbd_directory_pool, allow rwx pool=${CEPH_POOL_NAME}' 2>/dev/null || true

    echo ''
    echo 'Pool details:'
    sudo cephadm shell -- ceph osd pool ls detail 2>/dev/null
    echo ''
    echo 'client.juicefs key:'
    sudo cephadm shell -- ceph auth get client.juicefs 2>/dev/null
" || { echo "  ERROR: pool creation failed"; exit 1; }

# ============================================================
# Step 6: Copy ceph.conf + keyring to 157 (JuiceFS client node)
# ============================================================

echo ""
echo ">>> Step 6: Copying ceph.conf + keyring to ${CLIENT_SERVER} (JuiceFS client)..."

# On PRIMARY, copy files to 157 via internal SSH (150 → 157)
_run "${PRIMARY}" "
    set -e
    # 157 is reachable on 10.20.1.0/24 (management network)
    # sunrise user on 157 has NOPASSWD sudo
    SSH_PASS='Sunrise@801'
    SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

    # Ensure /etc/ceph exists on 157
    sshpass -p \"\${SSH_PASS}\" ssh \${SSH_OPTS} sunrise@${CLIENT_SERVER} 'sudo mkdir -p /etc/ceph'

    # Copy ceph.conf
    sudo cat /etc/ceph/ceph.conf | sshpass -p \"\${SSH_PASS}\" ssh \${SSH_OPTS} sunrise@${CLIENT_SERVER} 'sudo tee /etc/ceph/ceph.conf > /dev/null'

    # Copy admin keyring (for ceph CLI on 157)
    sudo cat /etc/ceph/ceph.client.admin.keyring | sshpass -p \"\${SSH_PASS}\" ssh \${SSH_OPTS} sunrise@${CLIENT_SERVER} 'sudo tee /etc/ceph/ceph.client.admin.keyring > /dev/null'

    # Extract client.juicefs keyring and copy to 157
    sudo cephadm shell -- ceph auth get client.juicefs 2>/dev/null | grep -v 'exported' | sshpass -p \"\${SSH_PASS}\" ssh \${SSH_OPTS} sunrise@${CLIENT_SERVER} 'sudo tee /etc/ceph/ceph.client.juicefs.keyring > /dev/null'

    echo '  ceph.conf + admin keyring + client.juicefs keyring copied to 157'
    sshpass -p \"\${SSH_PASS}\" ssh \${SSH_OPTS} sunrise@${CLIENT_SERVER} 'ls -la /etc/ceph/'
" || { echo "  WARNING: keyring copy to 157 failed — copy manually"; }

# ============================================================
# Done
# ============================================================

echo ""
echo "========================================"
echo "Ceph Deployment Complete (NO RGW — direct RADOS)!"
echo "========================================"
echo ""
echo "EC pool:    ${CEPH_POOL_NAME} (${CEPH_EC_K}+${CEPH_EC_M}, allow_ec_overwrites=true)"
echo "Cephx user: ${CEPHX_CLIENT}"
echo "Network:    public=${CEPH_PUBLIC_NETWORK}  cluster=${CEPH_CLUSTER_NETWORK}"
echo "DB/WAL:     tmpfs 内存盘 (loop device, ⚠️ 测试专用—断电丢)"
echo ""
echo "Next: bash scripts/deploy-juicefs.sh format"
echo ""
echo "Cluster status:"
echo "  _run ${PRIMARY} 'sudo cephadm shell -- ceph status'"
