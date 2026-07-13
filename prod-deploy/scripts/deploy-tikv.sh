#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV + PD 3-Node Deployment
#
# Deploys TiKV v7.1.5 + PD v7.1.5 in 3-replica mode
# on 3 slave servers (150/151/152), each with PD + TiKV co-located
# on nvme1n1 (894G ext4, mounted at /mnt/jfs-tikv).
#
# Raft group: 3 PD peers + 3 TiKV stores, max-replicas=3.
# Tolerates 1 node failure.
#
# SSH: WSL → HK ECS → 157 → slaves (three-level jump host).
# Binaries: downloaded on each target node directly (wget).
#
# Prerequisites:
#   1. config.sh filled with correct IPs
#   2. NOPASSWD sudo on all TiKV nodes (prepare-servers.sh)
#   3. nvme1n1 mounted at /mnt/jfs-tikv (prepare-servers.sh)
#
# Usage: bash deploy-tikv.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config/tikv"

source "${SCRIPT_DIR}/../config.sh"

# Build initial-cluster string: pd-1=http://IP1:2380,pd-2=http://IP2:2380,...
INITIAL_CLUSTER=""
PD_ENDPOINTS_TOML="["
for i in "${!TIKV_SERVERS[@]}"; do
    ip="${TIKV_SERVERS[$i]}"
    name="pd-$((i + 1))"
    [ -n "${INITIAL_CLUSTER}" ] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${name}=http://${ip}:2380"
    [ $i -gt 0 ] && PD_ENDPOINTS_TOML+=","
    PD_ENDPOINTS_TOML+="\"${ip}:2379\""
done
PD_ENDPOINTS_TOML+="]"

echo "========================================"
echo "TiKV + PD 3-Node Deployment"
echo "========================================"
echo "Nodes:  ${TIKV_SERVERS[*]}"
echo "Version: TiKV ${TIKV_VERSION}  PD ${PD_VERSION}"
echo "Mode:    3-replica (max-replicas=${TIKV_MAX_REPLICAS})"
echo "Data:    ${TIKV_MOUNT_POINT} (nvme1n1, ext4)"
echo "========================================"
echo ""

# ============================================================
# Pre-flight: check SSH + mount on all nodes
# ============================================================

echo ">>> Pre-flight checks..."
all_ok=true
for i in "${!TIKV_SERVERS[@]}"; do
    ip="${TIKV_SERVERS[$i]}"
    echo -n "  ${ip}: "
    result=$(_run "${ip}" "
        mountpoint -q ${TIKV_MOUNT_POINT} 2>/dev/null && echo 'mount OK' || echo 'mount FAIL'
        df -h ${TIKV_MOUNT_POINT} 2>/dev/null | tail -1 | awk '{print \"  disk:\" \$2 \" free:\" \$4}'
    " 2>/dev/null || true)
    if echo "${result}" | grep -q "mount OK"; then
        echo "OK (${result})"
    else
        echo "MOUNT FAIL — run prepare-servers.sh first"
        all_ok=false
    fi
done
${all_ok} || { echo "ERROR: mount not ready on some nodes."; exit 1; }
echo ""

read -rp "Continue with deployment? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================
# Download binaries on each node (remote wget)
# ============================================================

echo ">>> Downloading binaries on all 3 nodes..."

TIKV_TAR="tikv-${TIKV_VERSION}-linux-amd64.tar.gz"
PD_TAR="pd-${PD_VERSION}-linux-amd64.tar.gz"

for ip in "${TIKV_SERVERS[@]}"; do
    echo "  >>> ${ip}..."
    _run "${ip}" "
        set -e
        mkdir -p /tmp/tikv-deploy
        cd /tmp/tikv-deploy
        for tar in ${TIKV_TAR} ${PD_TAR}; do
            if [ -f \"\${tar}\" ]; then
                echo \"    [skip] \${tar}\"
            else
                echo \"    downloading \${tar}...\"
                wget -q --show-progress -O \"\${tar}\" \"${TIKV_MIRROR}/\${tar}\" || {
                    echo \"    ERROR: download failed\"; exit 1
                }
            fi
        done
        echo '    done'
    " || { echo "  ERROR: download on ${ip} failed"; exit 1; }
done

# ============================================================
# Generate per-node configs from templates
# ============================================================

echo ""
echo ">>> Generating per-node configs..."

for i in "${!TIKV_SERVERS[@]}"; do
    ip="${TIKV_SERVERS[$i]}"
    name="pd-$((i + 1))"

    # PD config
    sed -e "s/__NODE_NAME__/${name}/g" \
        -e "s/__NODE_IP__/${ip}/g" \
        -e "s|__INITIAL_CLUSTER__|${INITIAL_CLUSTER}|g" \
        "${CONFIG_DIR}/pd.toml" > "/tmp/pd-${name}.toml"

    # TiKV config
    sed -e "s/__NODE_NAME__/${name}/g" \
        -e "s/__NODE_IP__/${ip}/g" \
        -e "s|__PD_ENDPOINTS_TOML__|${PD_ENDPOINTS_TOML}|g" \
        "${CONFIG_DIR}/tikv.toml" > "/tmp/tikv-${name}.toml"
done
echo "  Generated 3 PD configs + 3 TiKV configs."

# ============================================================
# Deploy PD + TiKV on each node
# ============================================================

for i in "${!TIKV_SERVERS[@]}"; do
    ip="${TIKV_SERVERS[$i]}"
    name="pd-$((i + 1))"

    echo ""
    echo "========================================"
    echo "Deploying on ${ip} (${name})"
    echo "========================================"

    # Copy configs
    scp_to "/tmp/pd-${name}.toml" "${ip}" "/tmp/pd.toml"
    scp_to "/tmp/tikv-${name}.toml" "${ip}" "/tmp/tikv.toml"

    _run "${ip}" "
        set -e

        # --- Install PD ---
        echo '>>> Installing PD...'
        mkdir -p /opt/pd/bin /opt/pd/conf ${PD_DATA_DIR} /var/log/pd
        cd /tmp/tikv-deploy
        tar xzf ${PD_TAR}
        mv -f pd-server /opt/pd/bin/
        mv /tmp/pd.toml /opt/pd/conf/pd.toml
        chown -R root:root /opt/pd ${PD_DATA_DIR} /var/log/pd

        # --- Install TiKV ---
        echo '>>> Installing TiKV...'
        mkdir -p /opt/tikv/bin /opt/tikv/conf ${TIKV_DATA_DIR} /var/log/tikv
        tar xzf ${TIKV_TAR}
        mv -f tikv-server /opt/tikv/bin/
        ln -sf /opt/tikv/bin/tikv-server /opt/tikv/bin/tikv-ctl
        mv /tmp/tikv.toml /opt/tikv/conf/tikv.toml
        chown -R root:root /opt/tikv ${TIKV_DATA_DIR} /var/log/tikv
        echo '  Binaries installed.'
    " || { echo "  ERROR: install failed on ${ip}"; exit 1; }
done

# ============================================================
# Create systemd units (same on all nodes)
# ============================================================

echo ""
echo ">>> Creating systemd units on all nodes..."

for ip in "${TIKV_SERVERS[@]}"; do
    # PD service unit
    _run "${ip}" "cat > /etc/systemd/system/pd.service <<'UNIT'
[Unit]
Description=PD (Placement Driver)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/pd/bin/pd-server --config=/opt/pd/conf/pd.toml --log-file=/var/log/pd/pd.log
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT"

    # TiKV service unit
    _run "${ip}" "cat > /etc/systemd/system/tikv.service <<'UNIT'
[Unit]
Description=TiKV Server
After=network.target pd.service
Wants=pd.service

[Service]
Type=simple
User=root
ExecStart=/opt/tikv/bin/tikv-server --config=/opt/tikv/conf/tikv.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT"

    _run "${ip}" "systemctl daemon-reload && systemctl enable pd tikv"
done

# ============================================================
# Start PD on all nodes (simultaneously for Raft bootstrap)
# ============================================================

echo ""
echo ">>> Starting PD on all 3 nodes..."

for ip in "${TIKV_SERVERS[@]}"; do
    echo "  starting PD on ${ip}..."
    _run "${ip}" "systemctl restart pd" 2>/dev/null || true
done

echo "  Waiting for PD Raft bootstrap (10s)..."
sleep 10

# Check PD health
echo ""
echo ">>> PD health:"
for ip in "${TIKV_SERVERS[@]}"; do
    echo -n "  ${ip}: "
    result=$(_run "${ip}" "curl -s --noproxy '*' http://127.0.0.1:2379/pd/api/v1/health 2>/dev/null" 2>/dev/null || echo "")
    if echo "${result}" | grep -q '"health"'; then
        echo "OK"
    else
        echo "NOT READY (may need more time)"
    fi
done

# ============================================================
# Start TiKV on all nodes
# ============================================================

echo ""
echo ">>> Starting TiKV on all 3 nodes..."

for ip in "${TIKV_SERVERS[@]}"; do
    echo "  starting TiKV on ${ip}..."
    _run "${ip}" "systemctl restart tikv" 2>/dev/null || true
done

echo "  Waiting for TiKV to register with PD (15s)..."
sleep 15

# ============================================================
# Verify
# ============================================================

echo ""
echo "========================================"
echo "Verification"
echo "========================================"

echo ""
echo ">>> PD members:"
_first_ip="${TIKV_SERVERS[0]}"
_run "${_first_ip}" "curl -s --noproxy '*' 'http://127.0.0.1:2379/pd/api/v1/members' 2>/dev/null" | python3 -m json.tool 2>/dev/null || echo "  Not yet"

echo ""
echo ">>> TiKV stores:"
_run "${_first_ip}" "curl -s --noproxy '*' 'http://127.0.0.1:2379/pd/api/v1/stores' 2>/dev/null" | python3 -m json.tool 2>/dev/null || echo "  Not yet"

echo ""
echo ">>> PD health:"
_run "${_first_ip}" "curl -s --noproxy '*' 'http://127.0.0.1:2379/pd/api/v1/health' 2>/dev/null" | python3 -m json.tool 2>/dev/null || echo "  Not yet"

# Count stores
STORE_COUNT=$(_run "${_first_ip}" "curl -s --noproxy '*' 'http://127.0.0.1:2379/pd/api/v1/stores' 2>/dev/null" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('stores',[])))" 2>/dev/null || echo "0")
echo ""
echo "  TiKV stores UP: ${STORE_COUNT} (expected 3)"

echo ""
echo "========================================"
echo "TiKV + PD Deployment Complete!"
echo "========================================"
echo ""
echo "PD endpoints: ${PD_ENDPOINTS}"
echo "JuiceFS metadata URL: ${JUICEFS_METADATA_URL}"
echo ""
echo "Management:"
echo "  _run <ip> 'systemctl status pd tikv'"
echo "  _run <ip> 'journalctl -u pd -f'"
echo "  _run <ip> 'journalctl -u tikv -f'"
