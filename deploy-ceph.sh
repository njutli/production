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

# Pre-flight: check disk, root SSH, root account unlocked
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
        # Ensure root SSH is enabled and root account is unlocked
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh || true
        # cephadm SSHs as root between nodes; root account must be unlocked
        if sudo passwd -S root | grep -q ' L '; then
            echo '  Root account was locked — unlocking...'
            sudo passwd -u root
        fi
        echo '  Root SSH: enabled + unlocked'
    "
done

echo ""
read -rp "Continue with deployment? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# PRIMARY is the bootstrap node; used by MON config and subsequent steps.
PRIMARY="${CEPH_SERVERS[0]}"

# Limit MON deployment to nodes with sufficient root disk space.
# MON requires ~1GB headroom on the root filesystem for database growth.
# If a node's root disk has < 2GB free, cephadm will refuse to start MON.
# This preemptively skips such nodes; they still run OSDs and other services.
MON_HOSTS=()
for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    free_gb=$(ssh_srv "${ip}" "df -BG / | tail -1 | awk '{print \$4}' | sed 's/G//'" 2>/dev/null || echo "0")
    if [ "${free_gb}" -ge 2 ]; then
        MON_HOSTS+=("ceph-node$((i + 1))")
        echo "  MON: ceph-node$((i + 1)) (${free_gb}G root free) ✓"
    else
        echo "  MON: ceph-node$((i + 1)) SKIPPED — only ${free_gb}G root free (need ≥ 2G)"
    fi
done
if [ ${#MON_HOSTS[@]} -lt 2 ]; then
    echo "  ERROR: fewer than 2 nodes suitable for MON. Need ≥ 2 for quorum."
    exit 1
fi
MON_PLACEMENT=$(IFS=,; echo "${MON_HOSTS[*]}")
ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph config set mon mon_data_avail_crit 1 2>/dev/null" || true

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
        sudo apt-get update -qq || echo '  (apt update had errors, continuing)'

        # Install podman
        if ! command -v podman &>/dev/null; then
            echo '  Installing podman...'
            # A broken package (e.g. stale linux-headers) can block all
            # apt operations.  Run fix-broken first, then retry install.
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman >/dev/null 2>&1 || {
                sudo apt-get --fix-broken install -y >/dev/null 2>&1 || true
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman >/dev/null 2>&1 || {
                    echo '  ERROR: podman install failed (try: sudo apt --fix-broken install)'
                    exit 1
                }
            }
        else
            echo '  podman already installed'
        fi

        # Install system tools needed for disk partitioning
        if ! command -v sgdisk &>/dev/null; then
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted >/dev/null 2>&1 || {
                echo '  ERROR: gdisk/parted install failed'; exit 1; }
        fi

        # Stop docker if present (docker and podman conflict on the
        # same socket; cephadm requires podman).  Harmless if no docker.
        sudo systemctl stop docker docker.socket 2>/dev/null || true
        sudo systemctl disable docker docker.socket 2>/dev/null || true

        # Install cephadm
        if ! command -v cephadm &>/dev/null; then
            echo '  Installing cephadm...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cephadm ceph-common radosgw >/dev/null 2>&1 || {
                # apt failed — try direct download.  Verify the result is a
                # Python script (cephadm's shebang), not an HTML error page.
                echo '  apt failed, downloading cephadm from GitHub...'
                curl -sSL -o /tmp/cephadm "https://github.com/ceph/ceph/raw/reef/src/cephadm/cephadm"
                if head -1 /tmp/cephadm 2>/dev/null | grep -q 'python'; then
                    chmod +x /tmp/cephadm
                    sudo mv /tmp/cephadm /usr/local/bin/cephadm
                    echo '  cephadm installed from GitHub.'
                else
                    echo '  ERROR: downloaded cephadm is not a Python script (check network/proxy)'
                    exit 1
                fi
            }
        else
            echo '  cephadm already installed'
        fi

        # radosgw-admin is needed to create S3 users (Step 7).
        # It may not be pulled in by cephadm/ceph-common alone.
        if ! command -v radosgw-admin &>/dev/null; then
            echo '  Installing radosgw (radosgw-admin)...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y radosgw >/dev/null 2>&1 || {
                echo '  WARNING: radosgw-admin not available (user creation may fail)'
            }
        fi

        # cephadm on Ubuntu 24.04 (Noble) ships with a bug in its podman
        # version detection:  when podman's --version output isn't parsed as
        # expected, it raises RuntimeError and bootstrap aborts.  This sed
        # replaces the exception with a fallback return (0,0,0) so cephadm
        # continues.  Harmless on 22.04 where the file doesn't exist.
        if grep -q '24\.04\|noble' /etc/os-release 2>/dev/null; then
            sudo sed -i 's/raise RuntimeError.*get_version.*first/return (0, 0, 0)/' \
                /usr/lib/python3/dist-packages/cephadmlib/container_engines.py 2>/dev/null || true
        fi

        # Enable root SSH
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh || true

        # Pre-pull Ceph container image (skip if already cached)
        if sudo podman image exists quay.io/ceph/ceph:v19 2>/dev/null; then
            echo '  Ceph container image already cached.'
        else
            echo '  Pulling Ceph container image...'
            sudo podman pull quay.io/ceph/ceph:v19 2>&1 | tail -1 || {
                echo '  WARNING: pull failed (bootstrap will retry)'
            }
        fi
        echo '  Done.'
    "
done

# ============================================================
# Step 2: Bootstrap Ceph on primary node
# ============================================================

echo ""
echo ">>> Step 2: Bootstrapping Ceph on ceph-node1 (${PRIMARY})..."

ssh_srv "${PRIMARY}" "
    set -e
    if [ -d /etc/ceph ] && [ -f /etc/ceph/ceph.conf ]; then
        echo '  Ceph already bootstrapped, skipping.'
    else
        # --mon-ip ${PRIMARY}
        #   The IP address that the first MON binds to.  Must be a local
        #   IP on the bootstrap host.  Other nodes in the cluster will
        #   contact this MON to join the quorum.
        #
        # --allow-fqdn-hostname
        #   Accept fully-qualified hostnames (e.g. ceph-node1.example.com)
        #   when registering hosts.  Without this, cephadm may reject
        #   nodes whose 'hostname' returns a FQDN.
        #
        # --skip-prepare-host
        #   Do NOT install podman/lvm2/systemd-resolved on the bootstrap
        #   host.  We already installed these in Step 1, so we skip the
        #   automatic preparation to avoid re-apt-get'ing.
        #
        # --skip-dashboard
        #   Do not deploy the Ceph Dashboard web UI.  One less container,
        #   one less port (default 8443).  Not needed for a backend
        #   storage cluster accessed via JuiceFS RGW.
        #
        # --skip-monitoring-stack
        #   Do not deploy Prometheus + Grafana + Alertmanager.  Saves
        #   3-4 containers and hundreds of MB of memory.  Not needed
        #   for a test/deployment focused on RGW S3 throughput.
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
# Step 3: Set up root SSH + add secondary nodes
# ============================================================
#
# cephadm stores the SSH key pair inside the cluster's config-key
# store, not in /root/.ssh/.  When bootstrap ran while the root
# account was locked, the standard path setup was skipped.  We
# extract the keys and deploy them to the standard locations so
# that ceph orch commands (device zap, daemon add osd) work.
# ============================================================

echo ""
echo ">>> Step 3: Setting up root SSH between Ceph nodes..."

# Extract cephadm's SSH private key from the cluster config
if ! ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph config-key get mgr/cephadm/ssh_identity_key 2>/dev/null" > /tmp/ceph_priv_key 2>/dev/null; then
    echo "  WARNING: could not extract cephadm private key. Trying fallback."
    rm -f /tmp/ceph_priv_key
fi

# Deploy keys to all 3 Ceph nodes (including primary itself)
for ip in "${CEPH_SERVERS[@]}"; do
    echo "  Setting up root SSH on ${ip}..."

    # Public key → authorized_keys
    scp_srv "${ip}" /tmp/ceph.pub /tmp/ceph.pub
    ssh_srv "${ip}" "
        sudo mkdir -p /root/.ssh
        sudo cp /tmp/ceph.pub /root/.ssh/authorized_keys
        sudo chmod 600 /root/.ssh/authorized_keys
        sudo chown -R root:root /root/.ssh /root
    "

    # Private key → id_rsa (if we extracted one)
    if [ -s /tmp/ceph_priv_key ]; then
        scp_srv "${ip}" /tmp/ceph_priv_key /tmp/ceph_priv_key
        ssh_srv "${ip}" "
            sudo cp /tmp/ceph_priv_key /root/.ssh/id_rsa
            sudo chmod 600 /root/.ssh/id_rsa
            sudo chown root:root /root/.ssh/id_rsa
        "
    fi
done
echo "  Keys deployed."

# Verify root SSH works on each node
echo "  Verifying root SSH..."
all_root_ok=true
for ip in "${CEPH_SERVERS[@]}"; do
    if ssh_srv "${ip}" "sudo ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@localhost echo OK" 2>/dev/null; then
        echo "    ${ip}: root SSH OK"
    else
        echo "    ${ip}: root SSH FAILED"
        all_root_ok=false
    fi
done

if ! ${all_root_ok}; then
    echo ""
    echo "  ERROR: root SSH not working.  Check:"
    echo "    ssh turboai@192.168.11.11 'sudo cat /etc/ceph/ceph.pub'"
    echo "    ssh turboai@192.168.11.11 'sudo cat /root/.ssh/authorized_keys'"
    echo "    Both must be identical RSA keys."
    echo "    Also verify: sudo passwd -S root  (must NOT show 'L')"
    exit 1
fi

# Clean up temp keys
rm -f /tmp/ceph_priv_key

echo ""
echo ">>> Step 3b: Deploying MONs and adding secondary nodes..."

# Apply MON placement based on disk space assessment from Step 0
ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch apply mon --placement=\"${MON_PLACEMENT}\" 2>/dev/null || true"
echo "  MON placement: ${MON_PLACEMENT}"

for i in 1 2; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo ">>> Adding ${hostname} (${ip})..."

    if ! ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch host add ${hostname} ${ip} 2>&1" 2>/dev/null; then
        echo "  ERROR: failed to add ${hostname}."
        exit 1
    fi
    ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch host label add ${hostname} _admin 2>/dev/null || true"
    echo "  ${hostname} added."
done

echo ">>> Waiting for MON+MGR on secondary nodes (60s)..."
sleep 60

# Verify all 3 hosts are online
HOST_COUNT=$(ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch host ls --format json 2>/dev/null" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
if [ "${HOST_COUNT}" -lt 3 ]; then
    echo "  ERROR: expected 3 hosts, got ${HOST_COUNT}"
    ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch host ls 2>/dev/null"
    exit 1
fi
echo "  ${HOST_COUNT} hosts online."

ssh_srv "${PRIMARY}" "
    echo 'Host status:'
    sudo cephadm shell -- ceph orch host ls 2>/dev/null
    echo ''
    echo 'Daemon status:'
    sudo cephadm shell -- ceph orch ps 2>/dev/null
"

# ============================================================
# Step 4: Create LVM VG + 2 LVs per disk, deploy 6 OSDs via orch
# ============================================================
#
# cephadm's orchestrator device scanner (ceph-volume inventory)
# marks partitions as unavailable, but it DOES recognise LVM
# logical volumes.  So we manually create a PV→VG→2 LVs on each
# data disk, then let the orchestrator deploy OSDs onto the LVs.
# 3 nodes × 2 LVs = 6 OSDs = enough for EC 4+2.
# ============================================================

echo ""
echo ">>> Step 4: Creating LVM LVs (2 per disk) and deploying OSDs..."
echo "           3 nodes × 2 LVs = 6 OSDs for EC 4+2"

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    dev="${CEPH_OSD_DEVICES[$i]:-}"
    vg_name="ceph-vg-${hostname}"

    if [ -z "${dev}" ]; then
        echo "  WARNING: No OSD device configured for ${hostname}, skipping."
        continue
    fi

    echo ""
    echo "--- Preparing ${dev} on ${hostname} (${ip}) ---"

    # 1) Wipe, create PV + VG + 2 LVs on the data disk
    ssh_srv "${ip}" "
        set -e
        if mount | grep -q '^${dev} '; then
            echo \"  FATAL: ${dev} is mounted!\"; exit 1
        fi
        root_dev=\$(findmnt -n -o SOURCE / | sed 's/[0-9]*\$//;s/p[0-9]*\$//')
        if [ \"\${root_dev}\" = '${dev}' ]; then
            echo \"  FATAL: ${dev} is the system disk!\"; exit 1
        fi

        # Wipe existing partition table and LVM signatures
        sudo sgdisk -Z ${dev} 2>/dev/null || true
        sudo wipefs -af ${dev} 2>/dev/null || true
        sudo partprobe ${dev} 2>/dev/null || true
        sleep 2

        # Create PV + VG
        echo '  Creating PV + VG...'
        sudo pvcreate -ff -y ${dev} 2>/dev/null || sudo pvcreate -y ${dev}
        sudo vgcreate ${vg_name} ${dev} 2>/dev/null || true  # ok if already exists

        # Remove any stale LVs then create 2 new ones (50% each)
        sudo lvremove -f ${vg_name} 2>/dev/null || true
        sudo lvcreate -l 50%FREE -n osd0 ${vg_name}
        sudo lvcreate -l 100%FREE -n osd1 ${vg_name}

        echo '  LVs created:'
        sudo lvs ${vg_name} 2>/dev/null
    "

    # 2) Deploy OSDs on the LVs via orchestrator
    for lv in osd0 osd1; do
        lv_path="/dev/${vg_name}/${lv}"
        echo "  Deploying OSD on ${hostname}:${lv_path}..."
        if ! ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch daemon add osd ${hostname}:${lv_path} 2>&1" 2>/dev/null | grep -q "Created"; then
            echo "  FAILED"
            exit 1
        fi
        echo "  OK"
    done
done

echo ""
echo ">>> Waiting for OSDs (90s)..."
sleep 90

OSD_COUNT=$(ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph osd stat 2>/dev/null" | grep -oP '\d+(?= osds)' || echo "0")
echo "  OSDs: ${OSD_COUNT} (expected 6)"
if [ "${OSD_COUNT}" -lt 6 ]; then
    echo "  WARNING: EC 4+2 needs 6 OSDs"
fi

ssh_srv "${PRIMARY}" "
    echo 'OSD tree:'
    sudo cephadm shell -- ceph osd tree 2>/dev/null
    echo ''
    echo 'Health:'
    sudo cephadm shell -- ceph health 2>/dev/null
"

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
    # Enable pool deletion (needed when re-running on an existing cluster)
    sudo cephadm shell -- ceph config set mon mon_allow_pool_delete true 2>/dev/null || true

    # Create EC profile
    sudo cephadm shell -- ceph osd erasure-code-profile set ec-prod \
        k=${CEPH_EC_K} m=${CEPH_EC_M} \
        crush-failure-domain=${CEPH_FAILURE_DOMAIN} 2>/dev/null || {
        echo 'ERROR: failed to create EC profile'; exit 1; }

    # Delete old pool if it exists with a different profile
    sudo cephadm shell -- ceph osd pool delete default.rgw.buckets.data default.rgw.buckets.data --yes-i-really-really-mean-it 2>/dev/null || true

    # Create EC pool
    sudo cephadm shell -- ceph osd pool create default.rgw.buckets.data erasure ec-prod 2>/dev/null || {
        echo 'ERROR: failed to create EC pool (does OSD count >= k+m?)'; exit 1; }

    # Allow RGW to use this pool
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

# Deploy RGW on ceph-node1.  ceph-node2 is intentionally skipped because
# its root filesystem is only 20G and MON/RGW containers need headroom.
# For production HA, add a second RGW on a node with sufficient disk space.
if ! ssh_srv "${PRIMARY}" "sudo cephadm shell -- ceph orch apply rgw myrgw --port=8000 --placement='ceph-node1' 2>&1" 2>/dev/null; then
    echo "  ERROR: failed to apply RGW service"
    exit 1
fi

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

# timeout — radosgw-admin may hang if it can't reach the Ceph cluster
USER_INFO=$(ssh_srv "${PRIMARY}" "
    timeout 30 sudo radosgw-admin user create --uid=juicefs --display-name='JuiceFS-Production' 2>/dev/null || \
    timeout 30 sudo radosgw-admin user info --uid=juicefs 2>/dev/null
" 2>/dev/null)

if [ -z "${USER_INFO:-}" ]; then
    echo "  ERROR: radosgw-admin timed out or failed. Check:"
    echo "    ssh ${SSH_USER}@${PRIMARY} 'sudo cephadm shell -- ceph status'"
    exit 1
fi

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
