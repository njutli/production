#!/bin/bash
set -euo pipefail

# ============================================================
# Deploy MinIO Distributed Object Storage
#
# Replaces Ceph with MinIO on the 3 storage nodes.  Each node
# uses /dev/sdb formatted as XFS, with 2 directories (drive1/2)
# per node → 3×2=6 drives for EC 4+2.
#
# Prerequisites: run remove-ceph.sh first if Ceph is using sdb.
#
# Usage: bash deploy-minio.sh [deploy|status|remove]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ "${STORAGE_BACKEND}" != "minio" ]; then
    echo "ERROR: STORAGE_BACKEND is not 'minio' in config.sh."
    echo "  Set STORAGE_BACKEND=minio in config.sh first."
    exit 1
fi

ACTION="${1:-deploy}"

MINIO_VERSION="2025-05-01T15-46-28Z"
MINIO_BIN="/usr/local/bin/minio"
MINIO_USER="minio"
MINIO_GROUP="minio"

# MinIO node names for the server pool
MINIO_HOSTS=()
for ip in "${MINIO_SERVERS[@]}"; do
    MINIO_HOSTS+=("http://${ip}:${MINIO_PORT}")
done

ssh_srv() {
    local ip=$1; shift
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" "$@"
}

scp_srv() {
    local ip=$1 local_file=$2 remote_path=$3
    scp ${SSH_OPTS} -i "${SSH_KEY}" "${local_file}" "${SSH_USER}@${ip}:${remote_path}"
}

preflight() {
    echo ">>> Checking SSH + sudo to all MinIO nodes..."
    for ip in "${MINIO_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        if ssh_srv "${ip}" "sudo -n true" 2>/dev/null; then
            echo "OK"
        else
            echo "FAILED"
            exit 1
        fi
    done
}

# ============================================================
# deploy
# ============================================================

do_deploy() {
    echo "========================================"
    echo "MinIO Distributed Deployment"
    echo "========================================"
    echo "Nodes:   ${MINIO_SERVERS[*]}"
    echo "Data:    ${MINIO_DATA_DEVICE} → ${MINIO_MOUNT}"
    echo "Port:    ${MINIO_PORT}"
    echo "Console: ${MINIO_CONSOLE_PORT}"
    echo "EC:      ${MINIO_EC_K}+${MINIO_EC_M}"
    echo "Bucket:  ${JUICEFS_FS_NAME}"
    echo "========================================"
    echo ""

    preflight

    # ——— 1. Download MinIO binary ———
    echo ">>> Step 1: Downloading MinIO ${MINIO_VERSION}..."
    MINIO_URL="https://dl.min.io/server/minio/release/linux-amd64/archive/minio.${MINIO_VERSION}"
    if [ ! -f /tmp/minio ]; then
        curl -sSL -o /tmp/minio "${MINIO_URL}" || {
            echo "  ERROR: download failed (network issue?)"
            exit 1
        }
        chmod +x /tmp/minio
        echo "  Downloaded to /tmp/minio"
    else
        echo "  /tmp/minio already exists, reusing"
    fi

    MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"
    if [ ! -f /tmp/mc ]; then
        curl -sSL -o /tmp/mc "${MC_URL}" || {
            echo "  WARNING: mc download failed (bucket creation will need manual setup)"
        }
        chmod +x /tmp/mc 2>/dev/null || true
    fi

    # ——— 2. Prepare each node ———
    for ip in "${MINIO_SERVERS[@]}"; do
        echo ""
        echo "——— Preparing ${ip} ———"

        # 2a. Create system user
        ssh_srv "${ip}" "
            if ! id ${MINIO_USER} &>/dev/null; then
                sudo useradd -r -s /sbin/nologin ${MINIO_USER}
                echo '  User ${MINIO_USER} created.'
            else
                echo '  User ${MINIO_USER} already exists.'
            fi
        "

        # 2b. Format + mount data disk
        ssh_srv "${ip}" "
            set -e
            dev='${MINIO_DATA_DEVICE}'
            mnt='${MINIO_MOUNT}'

            # Safety: refuse to operate on system disk
            root_dev=\$(findmnt -n -o SOURCE / | sed 's/[0-9]*\$//;s/p[0-9]*\$//')
            if [ \"\${root_dev}\" = \"\${dev}\" ]; then
                echo \"  FATAL: \${dev} is the system disk!\"; exit 1
            fi

            # If dev is already mounted, skip
            if mount | grep -q \"^\${dev} \"; then
                echo \"  \${dev} already mounted, skipping format\"
                exit 0
            fi

            # Check if dev has LVM — warn and skip
            if sudo pvs 2>/dev/null | grep -q \"\${dev}\"; then
                echo \"  WARNING: \${dev} has LVM (Ceph leftover?). Run remove-ceph.sh first.\"
                exit 1
            fi

            # Format as XFS
            echo '  Formatting \${dev} as XFS...'
            sudo mkfs.xfs -f \${dev} 2>&1 | tail -3

            # Create mount point + fstab entry
            sudo mkdir -p \${mnt}

            # Get UUID
            uuid=\$(sudo blkid -s UUID -o value \${dev})
            if grep -q \"\${mnt}\" /etc/fstab 2>/dev/null; then
                echo '  \${mnt} already in fstab'
            else
                echo \"UUID=\${uuid} \${mnt} xfs defaults,noatime 0 2\" | sudo tee -a /etc/fstab
                echo '  fstab entry added.'
            fi

            # Mount
            sudo mount \${mnt}
            echo '  Disk formatted and mounted at \${mnt}.'
        "

        # 2c. Create drive directories
        ssh_srv "${ip}" "
            mnt='${MINIO_MOUNT}'
            sudo mkdir -p \${mnt}/drive1 \${mnt}/drive2
            sudo chown -R ${MINIO_USER}:${MINIO_GROUP} \${mnt}
            echo '  Drive dirs: \${mnt}/drive1 \${mnt}/drive2'
        "

        # 2d. Install MinIO binary (scp from local /tmp/minio)
        ssh_srv "${ip}" "
            if [ -f ${MINIO_BIN} ] && ${MINIO_BIN} --version 2>/dev/null | grep -q '${MINIO_VERSION}'; then
                echo '  MinIO already installed (correct version).'
            else
                echo '  MinIO not installed or version mismatch — will reinstall.'
                touch /tmp/minio-needs-install
            fi
        " 2>/dev/null || true

        if ssh_srv "${ip}" "test -f /tmp/minio-needs-install" 2>/dev/null; then
            scp_srv "${ip}" /tmp/minio /tmp/minio
            ssh_srv "${ip}" "
                sudo cp /tmp/minio ${MINIO_BIN}
                sudo chmod +x ${MINIO_BIN}
                rm -f /tmp/minio-needs-install
                echo '  MinIO binary installed: ${MINIO_BIN}'
            "
        fi
        echo "  MinIO binary: ${MINIO_BIN}"
    done

    [ -f /tmp/mc ] && sudo cp /tmp/mc /usr/local/bin/mc && sudo chmod +x /usr/local/bin/mc && echo "  mc installed locally" || true

    # ——— 3. Build MinIO server pool argument ———
    MINIO_POOL=""
    for ip in "${MINIO_SERVERS[@]}"; do
        MINIO_POOL="${MINIO_POOL} http://${ip}:${MINIO_PORT}${MINIO_MOUNT}/drive{1...2}"
    done

    # ——— 4. Create systemd service on each node ———
    for ip in "${MINIO_SERVERS[@]}"; do
        echo ""
        echo ">>> Setting up systemd on ${ip}..."

        # Environment file
        ssh_srv "${ip}" "
            sudo tee /etc/default/minio > /dev/null <<EOF
# MinIO configuration (managed by deploy-minio.sh)
MINIO_ROOT_USER=${MINIO_ACCESS_KEY}
MINIO_ROOT_PASSWORD=${MINIO_SECRET_KEY}
MINIO_VOLUMES=\"${MINIO_POOL# }\"
MINIO_STORAGE_CLASS_STANDARD=EC:${MINIO_EC_K}
MINIO_OPTS=\"--console-address :${MINIO_CONSOLE_PORT}\"
EOF
            echo '  /etc/default/minio written.'
        "

        # Systemd unit
        ssh_srv "${ip}" "
            sudo tee /etc/systemd/system/minio.service > /dev/null <<UNITEOF
[Unit]
Description=MinIO Object Storage
Documentation=https://min.io/docs/minio/linux/index.html
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${MINIO_USER}
Group=${MINIO_GROUP}
EnvironmentFile=/etc/default/minio
ExecStartPre=/bin/bash -c \"if [ -z \\\"\\\${MINIO_VOLUMES}\\\" ]; then echo 'MINIO_VOLUMES not set'; exit 1; fi\"
ExecStart=${MINIO_BIN} server \\\$MINIO_OPTS \\\$MINIO_VOLUMES
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
TasksMax=infinity
TimeoutStopSec=infinity
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
UNITEOF

            sudo systemctl daemon-reload
            echo '  systemd unit installed.'
        "
    done

    # ——— 5. Start MinIO on all nodes ———
    echo ""
    echo ">>> Step 5: Starting MinIO on all nodes..."
    for ip in "${MINIO_SERVERS[@]}"; do
        echo "  Starting on ${ip}..."
        ssh_srv "${ip}" "sudo systemctl enable minio && sudo systemctl restart minio"
    done

    # ——— 6. Wait for cluster ———
    echo ""
    echo ">>> Waiting for MinIO cluster to form (60s)..."
    sleep 60

    # Check services
    for ip in "${MINIO_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        ssh_srv "${ip}" "systemctl is-active minio 2>/dev/null || echo 'inactive'"
    done

    # ——— 7. Deploy MinIO LB (HAProxy) ———
    echo ""
    echo ">>> Step 7: Deploying MinIO LB (HAProxy) on ${LB_HOST}..."

    local lb_cfg="/tmp/haproxy-minio.cfg"
    {
        # Only frontend + backend blocks — the global/defaults are already
        # in the existing haproxy.cfg.  Do NOT include global/defaults here;
        # regenerating them would overwrite settings from deploy-lb.sh.
        echo "frontend minio_in"
        echo "    bind *:${MINIO_LB_PORT}"
        echo "    default_backend minio_pool"
        echo ""
        echo "backend minio_pool"
        echo "    balance roundrobin"
        echo "    option httpchk GET /minio/health/live"
        echo "    http-check expect status 200"
        local i=1
        for b in "${MINIO_BACKENDS[@]}"; do
            echo "    server minio${i} ${b} check inter 3s fall 3 rise 2"
            i=$((i + 1))
        done
    } > "${lb_cfg}"

    # Install HAProxy on LB_HOST if not already
    ssh_srv "${LB_HOST}" "
        if ! command -v haproxy >/dev/null 2>&1; then
            sudo apt-get update -qq || true
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy >/dev/null 2>&1 || {
                echo '  ERROR: haproxy install failed'; exit 1; }
        fi
    "

    # Push MinIO-specific config as a separate HAProxy instance
    # (merge with existing config if RGW LB is also running)
    scp_srv "${LB_HOST}" "${lb_cfg}" "/tmp/haproxy-minio.cfg"
    ssh_srv "${LB_HOST}" "
        # Merge MinIO frontend/backend into existing haproxy.cfg
        if grep -q 'frontend minio_in' /etc/haproxy/haproxy.cfg 2>/dev/null; then
            echo '  MinIO LB config already present, replacing...'
            # Remove old MinIO section, then append new one
            sudo sed -i '/^# --- MinIO LB \[managed by deploy-minio.sh\]/,/^# --- end MinIO LB/d' /etc/haproxy/haproxy.cfg 2>/dev/null || true
        fi
        {
            echo ''
            echo '# --- MinIO LB [managed by deploy-minio.sh] ---'
            cat /tmp/haproxy-minio.cfg
            echo '# --- end MinIO LB ---'
        } | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null

        if ! sudo haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
            echo '  ERROR: haproxy config validation failed:'
            sudo haproxy -c -f /etc/haproxy/haproxy.cfg || true
            exit 1
        fi
        sudo systemctl enable haproxy >/dev/null 2>&1 || true
        sudo systemctl restart haproxy
    "
    rm -f "${lb_cfg}"

    echo "  MinIO LB: http://${LB_HOST}:${MINIO_LB_PORT}"
    sleep 5

    # ——— 8. Create bucket ———
    echo ""
    echo ">>> Step 8: Creating S3 bucket '${JUICEFS_FS_NAME}'..."

    if command -v mc &>/dev/null; then
        mc alias set minio-prod "http://${MINIO_SERVERS[0]}:${MINIO_PORT}" \
            "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" 2>/dev/null || true
        mc mb --ignore-existing "minio-prod/${JUICEFS_FS_NAME}" 2>/dev/null || {
            echo "  WARNING: bucket creation via mc failed (will retry via awscli)"
        }
    fi

    if command -v aws &>/dev/null; then
        export AWS_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}"
        export AWS_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}"
        export AWS_DEFAULT_REGION=""
        aws --endpoint-url="${S3_ENDPOINT}" --no-verify-ssl \
            s3 mb "s3://${JUICEFS_FS_NAME}" 2>/dev/null || true
        echo "  Bucket created via awscli."
    fi

    # ——— 9. Save credentials ———
    mkdir -p "${SCRIPT_DIR}/.credentials"
    cat > "${SCRIPT_DIR}/.credentials/minio-juicefs.env" <<EOF
# MinIO S3 credentials for JuiceFS
AWS_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}
AWS_DEFAULT_REGION=
EOF
    chmod 600 "${SCRIPT_DIR}/.credentials/minio-juicefs.env"
    echo "  Credentials saved: .credentials/minio-juicefs.env"

    do_status

    echo ""
    echo "========================================"
    echo "MinIO deployed!"
    echo "  Endpoint:  ${S3_ENDPOINT}"
    echo "  Console:   http://${MINIO_SERVERS[0]}:${MINIO_CONSOLE_PORT}"
    echo "  Bucket:    ${JUICEFS_FS_NAME}"
    echo "========================================"
    echo ""
    echo "NEXT: bash deploy-juicefs.sh status"
}

# ============================================================
# status
# ============================================================

do_status() {
    echo ""
    echo ">>> MinIO cluster status:"
    for ip in "${MINIO_SERVERS[@]}"; do
        echo -n "  ${ip}: "
        ssh_srv "${ip}" "
            if systemctl is-active minio >/dev/null 2>&1; then
                echo 'running'
            else
                echo 'STOPPED'
            fi
        " 2>/dev/null || echo "unreachable"
    done

    echo ""
    echo ">>> S3 endpoint check (${S3_ENDPOINT})..."
    if curl -s --noproxy '*' --connect-timeout 5 -o /dev/null -w '%{http_code}' "${S3_ENDPOINT}/" 2>/dev/null | grep -qE '^(200|403|404)$'; then
        echo "  Responding."
    else
        echo "  WARNING: not responding."
    fi

    echo ""
    echo ">>> Bucket listing:"
    if command -v aws &>/dev/null; then
        export AWS_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}"
        export AWS_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}"
        export AWS_DEFAULT_REGION=""
        aws --endpoint-url="${S3_ENDPOINT}" --no-verify-ssl \
            s3 ls 2>/dev/null || echo "  (no buckets or unreachable)"
    fi
}

# ============================================================
# main
# ============================================================

case "${ACTION}" in
    deploy) do_deploy ;;
    status) do_status ;;
    *)
        echo "Usage: bash deploy-minio.sh [deploy|status]"
        echo ""
        echo "  deploy  - Deploy MinIO cluster on all nodes"
        echo "  status  - Show cluster health and S3 endpoint"
        ;;
esac