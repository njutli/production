#!/bin/bash
set -euo pipefail

# ============================================================
# TiKV + PD Single-Node Deployment (1 Physical Server)
#
# Deploys TiKV v7.1.5 + PD v7.1.5 in single-replica mode
# on one physical server (no Raft group, no multi-node).
#
# Prerequisites:
#   1. Edit config.sh (TIKV_SERVER = your IP)
#   2. When deploying to remote: SSH key-based access
#   3. When deploying locally: sudo access (password may be prompted)
#   4. /data is mounted on a fast SSD
#   5. Ports 2379, 2380, 20160, 20180 are free
#
# Usage: bash deploy-tikv.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config/tikv"

source "${SCRIPT_DIR}/config.sh"

S="${TIKV_SERVER}"

# Check if target is the local machine
_is_local=0
for lip in $(hostname -I 2>/dev/null || ip -4 addr show scope global | grep -oP 'inet \K[\d.]+'); do
    [ "${lip}" = "${S}" ] && _is_local=1 && break
done
[ "${S}" = "127.0.0.1" ] || [ "${S}" = "localhost" ] && _is_local=1

# --- helpers (auto-select local vs SSH) ---
run_srv() {
    if [ "${_is_local}" -eq 1 ]; then
        sudo bash -c "$*"
    elif [ -n "${SSH_PASS}" ]; then
        sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${S}" "$@"
    else
        ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${S}" "$@"
    fi
}

copy_srv() {
    if [ "${_is_local}" -eq 1 ]; then
        sudo cp "$1" "$2"
    elif [ -n "${SSH_PASS}" ]; then
        sshpass -p "${SSH_PASS}" scp ${SSH_OPTS} "$1" "${SSH_USER}@${S}:$2"
    else
        scp ${SSH_OPTS} -i "${SSH_KEY}" "$1" "${SSH_USER}@${S}:$2"
    fi
}

# ============================================================
# Pre-flight
# ============================================================

echo "========================================"
echo "TiKV Single-Node Deployment"
echo "========================================"
echo "Target:  ${S}"
echo "Version: TiKV ${TIKV_VERSION}  PD ${PD_VERSION}"
echo "Mode:    single-replica (max-replicas=1)"
echo "========================================"
echo ""
if [ "${_is_local}" -eq 1 ]; then
    echo "Target ${S} is the local machine — deploying directly."
    sudo -v || { echo "ERROR: sudo access required."; exit 1; }
else
    echo ">>> Testing SSH to ${S}..."
    run_srv "echo ok" &>/dev/null || { echo "ERROR: Cannot reach ${S}. Check SSH config."; exit 1; }
    echo "   SSH OK"
fi
echo ""
echo ">>> Pre-flight checks on ${S}:"
run_srv "
    source /etc/os-release 2>/dev/null
    echo \"  OS: \${PRETTY_NAME:-unknown}\"
    free -h | awk '/^Mem:/{print \"  Memory: \"\$2}'
    df -h /data 2>/dev/null | tail -1 | awk '{print \"  /data: \"\$2\" total, \"\$4\" free\"}' || echo '  WARNING: /data not mounted'
    for p in 2379 2380 20160 20180; do
        ss -tlnp | grep -q \":\${p} \" && echo \"  WARNING: port \${p} in use!\" || true
    done
"

echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================
# Download binaries
# ============================================================

echo ""
echo ">>> Downloading binaries..."

CACHE_DIR="${SCRIPT_DIR}/downloads"
mkdir -p "${CACHE_DIR}"

TIKV_TAR="tikv-${TIKV_VERSION}-linux-amd64.tar.gz"
PD_TAR="pd-${PD_VERSION}-linux-amd64.tar.gz"

for tar in "${TIKV_TAR}" "${PD_TAR}"; do
    dest="${CACHE_DIR}/${tar}"
    if [ -f "${dest}" ]; then
        echo "[skip] ${tar}"
        continue
    fi
    echo ">>> Downloading ${tar}..."
    wget -q --show-progress -O "${dest}" "${TIKV_MIRROR}/${tar}" || {
        echo "ERROR: download failed"; exit 1
    }
done

# ============================================================
# Deploy PD
# ============================================================

echo ""
echo ">>> Deploying PD..."

run_srv "mkdir -p /opt/pd/bin /opt/pd/conf ${PD_DATA_DIR} /var/log/pd"

copy_srv "${CACHE_DIR}/${PD_TAR}" "/tmp/${PD_TAR}"
run_srv "
    cd /tmp
    tar xzf ${PD_TAR}
    mv -f pd-server /opt/pd/bin/
    rm -f ${PD_TAR}
    chown -R root:root /opt/pd ${PD_DATA_DIR} /var/log/pd
"

copy_srv "${CONFIG_DIR}/pd1.toml" "/tmp/pd.toml"
run_srv "mv /tmp/pd.toml /opt/pd/conf/pd.toml"

run_srv "tee /etc/systemd/system/pd.service" <<'EOF'
[Unit]
Description=PD (Placement Driver) — Single Node
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
EOF

run_srv "systemctl daemon-reload && systemctl enable pd"
echo ">>> Starting PD..."
run_srv "systemctl restart pd"
sleep 5

echo -n ">>> PD health: "
if run_srv "curl -s --noproxy '*' http://127.0.0.1:2379/pd/api/v1/health" 2>/dev/null | grep -q '"health"'; then
    echo "OK"
else
    echo "NOT READY (check journalctl -u pd)"
fi

# ============================================================
# Deploy TiKV
# ============================================================

echo ""
echo ">>> Deploying TiKV..."

run_srv "mkdir -p /opt/tikv/bin /opt/tikv/conf ${TIKV_DATA_DIR} /var/log/tikv"

copy_srv "${CACHE_DIR}/${TIKV_TAR}" "/tmp/${TIKV_TAR}"
run_srv "
    cd /tmp
    tar xzf ${TIKV_TAR}
    mv -f tikv-server /opt/tikv/bin/
    rm -f ${TIKV_TAR}
    chown -R root:root /opt/tikv ${TIKV_DATA_DIR} /var/log/tikv
"

copy_srv "${CONFIG_DIR}/tikv1.toml" "/tmp/tikv.toml"
run_srv "mv /tmp/tikv.toml /opt/tikv/conf/tikv.toml"

run_srv "tee /etc/systemd/system/tikv.service" <<'EOF'
[Unit]
Description=TiKV Server — Single Node
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
EOF

run_srv "systemctl daemon-reload && systemctl enable tikv"
echo ">>> Starting TiKV..."
run_srv "systemctl restart tikv"
sleep 5

# ============================================================
# Verify
# ============================================================

echo ""
echo ">>> Waiting for TiKV to register (10s)..."
sleep 10

echo ""
echo "========================================"
echo "Verification"
echo "========================================"

echo ""
echo ">>> PD members:"
curl -s --noproxy '*' "http://${S}:2379/pd/api/v1/members" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Not yet"

echo ""
echo ">>> TiKV store(s):"
curl -s --noproxy '*' "http://${S}:2379/pd/api/v1/stores" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Not yet"

echo ""
echo ">>> PD health:"
curl -s --noproxy '*' "http://${S}:2379/pd/api/v1/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Not yet"

echo ""
echo "========================================"
echo "Deployment Complete!"
echo "========================================"
echo ""
echo "PD API:   curl http://${S}:2379/pd/api/v1/health"
echo "TiKV API: curl http://${S}:20180/status"
echo ""
echo "JuiceFS metadata URL:"
echo "  tikv://${S}:2379/<fsname>"
echo ""
echo "Management:"
echo "  ssh ${SSH_USER}@${S} systemctl status pd tikv"
echo "  ssh ${SSH_USER}@${S} journalctl -u pd -f"
echo "  ssh ${SSH_USER}@${S} journalctl -u tikv -f"
