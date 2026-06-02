#!/bin/bash
set -euo pipefail

# ============================================================
# Ceph RGW Production Deployment (3 Physical Servers)
# Part of the 4-machine topology: 1 TiKV + 3 Ceph.
#
# All servers use user 'turboai'.  Root-required commands use sudo.
# cephadm inter-node SSH uses root; this script distributes the
# ceph.pub key to /root/.ssh/authorized_keys on each node.
#
# Usage: bash deploy-ceph.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"

# --- Helpers ---

ssh_srv() {
    local ip=$1; shift
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" "$@"
}

scp_srv() {
    local ip=$1 local_file=$2 remote_path=$3
    scp ${SSH_OPTS} -i "${SSH_KEY}" "${local_file}" "${SSH_USER}@${ip}:${remote_path}"
}

wait_ssh() {
    local ip=$1 max=60
    echo -n ">>> Waiting for SSH on ${ip}..."
    for i in $(seq 1 ${max}); do
        if ssh_srv "${ip}" "echo ok" 2>/dev/null; then echo " ready!"; return 0; fi
        sleep 2; echo -n "."
    done
    echo " timeout!"; return 1
}

# ============================================================
# Step 0: Pre-flight checks
# ============================================================

echo "========================================"
echo "Ceph RGW Production Deployment"
echo "========================================"
echo "Nodes: ${CEPH_SERVERS[0]}, ${CEPH_SERVERS[1]}, ${CEPH_SERVERS[2]}"
echo "EC pool: ${CEPH_EC_K}+${CEPH_EC_M} (failure-domain=${CEPH_FAILURE_DOMAIN})"
echo "User:   ${SSH_USER} (sudo for privileged ops)"
echo "========================================"
echo ""

# Verify SSH + sudo
for ip in "${CEPH_SERVERS[@]}"; do
    wait_ssh "${ip}" || { echo "ERROR: Cannot SSH to ${ip}."; exit 1; }
done
echo ">>> Checking sudo access on all servers..."
sudo_ok=true
for ip in "${CEPH_SERVERS[@]}"; do
    echo -n "  ${ip}: "
    if ssh_srv "${ip}" "sudo -n true" 2>/dev/null; then
        echo "passwordless sudo OK"
    else
        echo "REQUIRES PASSWORD — run prepare-servers.sh on this machine first"
        sudo_ok=false
    fi
done
if ! ${sudo_ok}; then
    echo ""
    echo "ERROR: Passwordless sudo is required on all Ceph servers."
    echo "  Run on each server: sudo bash prepare-servers.sh ceph"
    echo "  Or manually:  echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/${SSH_USER}"
    exit 1
fi
echo ">>> All 3 servers reachable."
echo ""

# Pre-flight: check disk, root SSH, port conflicts
for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    echo ">>> Checking ${ip}..."
    ssh_srv "${ip}" "
        source /etc/os-release 2>/dev/null
        echo \"  OS: \${PRETTY_NAME:-unknown}\"
        echo \"  Memory: \$(free -h | awk '/^Mem:/{print \$2}')\"
        echo \"  Disk: \$(df -h / | tail -1 | awk '{print \$2,\"free:\",\$4}')\"
        dev='${CEPH_OSD_DEVICES[$i]:-}'
        if [ -n \"\${dev}\" ] && [ -b \"\${dev}\" ]; then
            echo \"  OSD device \${dev}: \$(lsblk -dn -o SIZE \${dev} 2>/dev/null || echo unknown)\"
        elif [ -n \"\${dev}\" ]; then
            echo \"  WARNING: OSD device \${dev} NOT FOUND!\"
        fi
        # Ensure root SSH is enabled (cephadm requirement)
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh || true
        echo '  Root SSH: enabled'
    "
done

echo ""
read -rp "Continue with deployment? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================
# Step 1: Prepare all servers
# ============================================================

echo ""
echo ">>> Step 1: Preparing all servers (hostname, podman, cephadm, root SSH)..."

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo ">>> Preparing ${hostname} (${ip})..."
    ssh_srv "${ip}" "
        set -e

        # Set hostname to match ceph orch labels used throughout this script
        sudo hostnamectl set-hostname ${hostname}
        echo \"  hostname set to: ${hostname}\"

        # Refresh package cache once (used by all subsequent apt-get calls)
        sudo apt-get update -qq 2>/dev/null

        # Install podman
        if ! command -v podman &>/dev/null; then
            echo '  Installing podman...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman >/dev/null 2>&1
        else
            echo '  podman already installed'
        fi

        # Install system tools needed for disk partitioning
        if ! command -v sgdisk &>/dev/null; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted >/dev/null 2>&1
        fi

        # Stop docker if present (conflicts with cephadm)
        sudo systemctl stop docker docker.socket 2>/dev/null || true
        sudo systemctl disable docker docker.socket 2>/dev/null || true

        # Install cephadm
        if ! command -v cephadm &>/dev/null; then
            echo '  Installing cephadm...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cephadm ceph-common >/dev/null 2>&1 || {
                curl -sSL --remote-name https://github.com/ceph/ceph/raw/reef/src/cephadm/cephadm
                chmod +x cephadm
                sudo mv cephadm /usr/local/bin/
            }
        else
            echo '  cephadm already installed'
        fi

        # Fix cephadm container-engine detection bug (Ubuntu 24.04)
        sudo sed -i 's/raise RuntimeError.*get_version.*first/return (0, 0, 0)/' \
            /usr/lib/python3/dist-packages/cephadmlib/container_engines.py 2>/dev/null || true

        # Enable root SSH
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh || true

        # Pre-pull Ceph container image
        echo '  Pulling Ceph container image...'
        sudo podman pull quay.io/ceph/ceph:v19 2>&1 | tail -1 || {
            echo '  WARNING: pull failed (bootstrap will retry)'
        }
        echo '  Done.'
    "
done

# ============================================================
# Step 2: Bootstrap Ceph on primary node
# ============================================================

echo ""
echo ">>> Step 2: Bootstrapping Ceph on ceph-node1 (${CEPH_SERVERS[0]})..."

PRIMARY="${CEPH_SERVERS[0]}"

ssh_srv "${PRIMARY}" "
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
"

# Copy admin artefacts to deployment host
echo ">>> Copying Ceph admin artefacts..."
if ! ssh_srv "${PRIMARY}" "sudo test -f /etc/ceph/ceph.conf" 2>/dev/null; then
    echo "ERROR: Bootstrap appears to have failed — /etc/ceph/ceph.conf not found."
    echo "  Check: ssh ${SSH_USER}@${PRIMARY} 'sudo cephadm shell -- ceph status'"
    exit 1
fi
ssh_srv "${PRIMARY}" "sudo cat /etc/ceph/ceph.conf" > /tmp/ceph.conf
ssh_srv "${PRIMARY}" "sudo cat /etc/ceph/ceph.client.admin.keyring" > /tmp/ceph.client.admin.keyring
ssh_srv "${PRIMARY}" "sudo cat /etc/ceph/ceph.pub" > /tmp/ceph.pub
echo "   /tmp/ceph.conf, /tmp/ceph.client.admin.keyring, /tmp/ceph.pub saved."

# ============================================================
# Step 3: Add secondary nodes
# ============================================================

echo ""
echo ">>> Step 3: Adding secondary nodes..."

for i in 1 2; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo ">>> Adding ${hostname} (${ip})..."

    # Distribute ceph.pub to root on secondary node
    scp_srv "${ip}" /tmp/ceph.pub /tmp/ceph.pub
    ssh_srv "${ip}" "
        sudo mkdir -p /root/.ssh
        sudo cp /tmp/ceph.pub /root/.ssh/authorized_keys
        sudo chmod 600 /root/.ssh/authorized_keys
        sudo chown root:root /root/.ssh /root/.ssh/authorized_keys /root
    "

    # Add host to orchestrator
    ssh_srv "${PRIMARY}" "
        sudo cephadm shell -- ceph orch host add ${hostname} ${ip} 2>/dev/null || true
        sudo cephadm shell -- ceph orch host label add ${hostname} _admin 2>/dev/null || true
    "
    echo "  ${hostname} added."
done

echo ">>> Waiting for MON+MGR on secondary nodes (60s)..."
sleep 60

ssh_srv "${PRIMARY}" "
    echo 'Host status:'
    sudo cephadm shell -- ceph orch host ls 2>/dev/null
    echo ''
    echo 'Daemon status:'
    sudo cephadm shell -- ceph orch ps 2>/dev/null
"

# ============================================================
# Step 4: Partition disks + deploy OSDs (3 servers × 2 = 6 OSDs)
# ============================================================

echo ""
echo ">>> Step 4: Partitioning disks and deploying OSDs..."

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    dev="${CEPH_OSD_DEVICES[$i]:-}"

    if [ -z "${dev}" ]; then
        echo "  WARNING: No OSD device configured for ${hostname}, skipping."
        continue
    fi

    echo ""
    echo "--- Partitioning ${dev} on ${hostname} (${ip}) ---"

    ssh_srv "${ip}" "
        set -e
        echo '  Wiping partition table...'
        sudo sgdisk -Z ${dev} 2>/dev/null || sudo wipefs -a ${dev}
        sleep 2
        sudo partprobe ${dev} 2>/dev/null || true
        sleep 2

        sectors=\$(sudo blockdev --getsz ${dev})
        half=\$(( sectors / 2 ))
        echo \"  Disk ${dev}: \${sectors} sectors → 2 × \${half}\"

        sudo sgdisk -n 1:0:+\${half} -t 1:8300 ${dev}
        sudo sgdisk -n 2:0:0 -t 2:8300 ${dev}
        sudo partprobe ${dev} 2>/dev/null || true
        sleep 3

        echo '  Partitions created:'
        lsblk ${dev} 2>/dev/null || true
    "

    for part_num in 1 2; do
        part="${dev}${part_num}"
        echo "  Deploying OSD on ${hostname}:${part}..."

        ssh_srv "${PRIMARY}" "
            sudo cephadm shell -- ceph orch device zap ${hostname} ${part} --force 2>/dev/null || true
        "
        sleep 3
        ssh_srv "${PRIMARY}" "
            sudo cephadm shell -- ceph orch daemon add osd ${hostname}:${part} 2>/dev/null || true
        "
    done
done

echo ">>> Waiting for OSDs (90s)..."
sleep 90

ssh_srv "${PRIMARY}" "
    echo 'OSD tree:'
    sudo cephadm shell -- ceph osd tree 2>/dev/null
    echo ''
    echo 'OSD stat:'
    sudo cephadm shell -- ceph osd stat 2>/dev/null
"

# ============================================================
# Step 5: Create EC pool
# ============================================================

echo ""
echo ">>> Step 5: Creating EC ${CEPH_EC_K}+${CEPH_EC_M} pool..."

ssh_srv "${PRIMARY}" "
    sudo cephadm shell -- ceph osd erasure-code-profile set ec42-prod \
        k=${CEPH_EC_K} m=${CEPH_EC_M} \
        crush-failure-domain=${CEPH_FAILURE_DOMAIN} 2>/dev/null || true

    sudo cephadm shell -- ceph osd pool create default.rgw.buckets.data erasure ec42-prod 2>/dev/null || true
    sudo cephadm shell -- ceph osd pool application enable default.rgw.buckets.data rgw 2>/dev/null || true

    echo ''
    echo 'Pool details:'
    sudo cephadm shell -- ceph osd pool ls detail 2>/dev/null
"

# ============================================================
# Step 6: Deploy RGW
# ============================================================

echo ""
echo ">>> Step 6: Deploying RGW service..."

ssh_srv "${PRIMARY}" "
    sudo cephadm shell -- ceph orch apply rgw myrgw --placement='ceph-node1 ceph-node2' 2>/dev/null || true
"

echo ">>> Waiting for RGW (30s)..."
sleep 30

ssh_srv "${PRIMARY}" "
    echo 'RGW daemons:'
    sudo cephadm shell -- ceph orch ps --daemon-type rgw 2>/dev/null
"

# ============================================================
# Step 7: Create RGW user for JuiceFS
# ============================================================

echo ""
echo ">>> Step 7: Creating RGW user for JuiceFS..."

USER_INFO=$(ssh_srv "${PRIMARY}" "
    sudo radosgw-admin user create --uid=juicefs --display-name='JuiceFS-Production' 2>/dev/null || \
    sudo radosgw-admin user info --uid=juicefs 2>/dev/null
" 2>/dev/null)

ACCESS_KEY=$(echo "${USER_INFO}" | grep -o '"access_key": *"[^"]*"' | cut -d'"' -f4 || echo "")
SECRET_KEY=$(echo "${USER_INFO}" | grep -o '"secret_key": *"[^"]*"' | cut -d'"' -f4 || echo "")

# ============================================================
# Done
# ============================================================

echo ""
echo "========================================"
echo "Ceph RGW Deployment Complete!"
echo "========================================"
echo ""
echo "RGW Endpoints:"
echo "  http://${CEPH_SERVERS[0]}:8000"
echo "  http://${CEPH_SERVERS[1]}:8000"
echo ""

if [ -n "${ACCESS_KEY}" ] && [ -n "${SECRET_KEY}" ]; then
    mkdir -p "${SCRIPT_DIR}/.credentials"
    cat > "${SCRIPT_DIR}/.credentials/rgw-juicefs.env" <<EOF
# JuiceFS RGW credentials
AWS_ACCESS_KEY_ID=${ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${SECRET_KEY}
AWS_DEFAULT_REGION=
RGW_ENDPOINT=http://${CEPH_SERVERS[0]}:8000
EOF
    chmod 600 "${SCRIPT_DIR}/.credentials/rgw-juicefs.env"
    echo "Credentials saved: ${SCRIPT_DIR}/.credentials/rgw-juicefs.env"
    echo "  Access Key: ${ACCESS_KEY}"
    echo "  Secret Key: ${SECRET_KEY}"
else
    echo "RGW user (check manually):"
    echo "  ssh ${SSH_USER}@${PRIMARY} 'sudo radosgw-admin user info --uid=juicefs'"
fi

echo ""
echo "Cluster status:"
echo "  ssh ${SSH_USER}@${PRIMARY} 'sudo cephadm shell -- ceph status'"
echo ""
echo "Firewall ports: TCP 3300,6789 (MON) / TCP 8000 (RGW) / TCP 6800-7300 (OSD)"
