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
source "${SCRIPT_DIR}/../config.sh"

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
            --mon-ip ${PRIMARY} \
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
# Step 4: Deploy OSDs (6 physical disks via ceph orch)
# ============================================================
# ceph orch manages keyring, ceph-volume, and device setup internally.
# DB/WAL co-located on data disk (cephadm native deployment).
# (Original design had DB/WAL on tmpfs loop device, but cephadm container
#  doesn't expose bootstrap-osd keyring to ceph-volume for manual runs.
#  ceph orch handles this internally, so we use it instead.)

echo ""
echo ">>> Step 4: Deploying OSDs (6 physical disks via ceph orch)..."

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"

    for dev in "${CEPH_OSD_DEVICES_PER_NODE[@]}"; do
        echo "  ${hostname}: ${dev}..."
        # Wipe disk first
        _run "${ip}" "sudo umount ${dev} 2>/dev/null || true; sudo sgdisk -Z ${dev} 2>/dev/null || true; sudo wipefs -af ${dev} 2>/dev/null || true; sudo partprobe ${dev} 2>/dev/null || true" 2>/dev/null || true
        sleep 2
        # Deploy OSD via ceph orch
        _run "${PRIMARY}" "sudo cephadm shell -- ceph orch daemon add osd ${hostname}:${dev} 2>&1" 2>/dev/null || echo "  (may already exist)"
    done
done

echo "  Waiting for OSDs (60s)..."
sleep 60

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
# Get file contents from PRIMARY via _run, write to 157 via ssh_to_client.
# Uses base64 encoding to safely transfer through 3-level SSH.

echo ""
echo ">>> Step 6: Copying ceph.conf + keyring to ${CLIENT_SERVER} (JuiceFS client)..."

CEPH_CONF_B64=$(_run "${PRIMARY}" "sudo cat /etc/ceph/ceph.conf 2>/dev/null | base64 -w0" 2>/dev/null)
ADMIN_KEY_B64=$(_run "${PRIMARY}" "sudo cat /etc/ceph/ceph.client.admin.keyring 2>/dev/null | base64 -w0" 2>/dev/null)
JUICEFS_KEY_B64=$(_run "${PRIMARY}" "sudo cephadm shell -- ceph auth get client.juicefs 2>/dev/null | grep -v exported | base64 -w0" 2>/dev/null)

ssh_to_client "sudo mkdir -p /etc/ceph && echo '${CEPH_CONF_B64}' | base64 -d | sudo tee /etc/ceph/ceph.conf > /dev/null && echo '${ADMIN_KEY_B64}' | base64 -d | sudo tee /etc/ceph/ceph.client.admin.keyring > /dev/null && echo '${JUICEFS_KEY_B64}' | base64 -d | sudo tee /etc/ceph/ceph.client.juicefs.keyring > /dev/null && sudo chmod 600 /etc/ceph/ceph.client.*.keyring && echo '  Files copied:' && ls -la /etc/ceph/" 2>/dev/null || echo "  WARNING: keyring copy to 157 failed — copy manually"

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
echo "DB/WAL:     co-located on data disk (cephadm native deployment)"
echo ""
echo "Next: bash scripts/deploy-juicefs.sh format"
echo ""
echo "Cluster status:"
echo "  _run ${PRIMARY} 'sudo cephadm shell -- ceph status'"
