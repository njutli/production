#!/bin/bash
set -euo pipefail

# ============================================================
# RGW Load Balancer Deployment (HAProxy)
#
# Part of the 4-machine topology.  Only useful when more than one
# RGW is deployed (see deploy-ceph.sh).  A single RGW is a single
# point that all S3 traffic hits; with multiple RGWs, JuiceFS still
# connects to ONE endpoint, so without an LB the extra RGWs get no
# traffic.  This script installs HAProxy on LB_HOST and balances
# LB_PORT across RGW_BACKENDS (round-robin + HTTP health checks).
#
# After running:  set RGW_ENDPOINT in config.sh to
#   http://${LB_HOST}:${LB_PORT}
# then (re)format/mount JuiceFS so it talks to the LB.
#
# Usage: bash deploy-lb.sh [deploy|status|remove]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/config.sh"

ACTION="${1:-deploy}"

# --- Helpers (same style as deploy-ceph.sh) ---

# Detect if LB_HOST is the local machine so we don't SSH to ourselves
_is_local=0
for lip in $(hostname -I 2>/dev/null || ip -4 addr show scope global | grep -oP 'inet \K[\d.]+'); do
    [ "${lip}" = "${LB_HOST}" ] && _is_local=1 && break
done
[ "${LB_HOST}" = "127.0.0.1" ] || [ "${LB_HOST}" = "localhost" ] && _is_local=1

ssh_srv() {
    local ip=$1; shift
    if [ "${_is_local}" -eq 1 ]; then
        bash -c "$*"
    else
        ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${ip}" "$@"
    fi
}

scp_srv() {
    local ip=$1 local_file=$2 remote_path=$3
    if [ "${_is_local}" -eq 1 ]; then
        [ "${local_file}" = "${remote_path}" ] || cp "${local_file}" "${remote_path}"
    else
        scp ${SSH_OPTS} -i "${SSH_KEY}" "${local_file}" "${SSH_USER}@${ip}:${remote_path}"
    fi
}

# ============================================================
# Pre-flight
# ============================================================

preflight() {
    if [ "${#RGW_BACKENDS[@]}" -lt 1 ]; then
        echo "ERROR: RGW_BACKENDS is empty (config.sh)."; exit 1
    fi
    if [ "${#RGW_BACKENDS[@]}" -lt 2 ]; then
        echo "NOTE: only 1 RGW backend configured — an LB adds little here."
        echo "      Multi-RGW is what makes the LB worthwhile."
    fi

    echo -n ">>> Checking SSH to LB host ${LB_HOST}... "
    if ssh_srv "${LB_HOST}" "echo ok" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        echo "ERROR: cannot SSH to ${LB_HOST}. Run setup-ssh-keys.sh first."
        exit 1
    fi

    echo -n ">>> Checking passwordless sudo on ${LB_HOST}... "
    if ssh_srv "${LB_HOST}" "sudo -n true" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        echo "ERROR: passwordless sudo required on ${LB_HOST}."
        echo "  Run there: echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/${SSH_USER}"
        exit 1
    fi

    # Warn if the LB shares a host with one of its own RGW backends:
    # the LB and that RGW then fight for the same NIC, defeating the
    # point of spreading traffic.
    for b in "${RGW_BACKENDS[@]}"; do
        if [ "${b%%:*}" = "${LB_HOST}" ]; then
            echo "  WARNING: LB_HOST ${LB_HOST} also runs RGW backend ${b}."
            echo "           Prefer an LB host that is NOT an RGW node."
        fi
    done
}

# ============================================================
# deploy
# ============================================================

do_deploy() {
    echo "========================================"
    echo "RGW Load Balancer (HAProxy) Deployment"
    echo "========================================"
    echo "LB:        ${LB_HOST}:${LB_PORT}"
    echo "Backends:  ${RGW_BACKENDS[*]}"
    echo "========================================"
    echo ""

    preflight

    # 1) Install HAProxy
    echo ">>> Installing HAProxy on ${LB_HOST}..."
    ssh_srv "${LB_HOST}" "
        if command -v haproxy >/dev/null 2>&1; then
            echo '  haproxy already installed'
        else
            sudo apt-get update -qq || true
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy >/dev/null 2>&1 || {
                echo '  ERROR: haproxy install failed'; exit 1; }
            echo '  haproxy installed'
        fi
    "

    # 2) Build haproxy.cfg locally, then push it
    #    - mode http: RGW speaks HTTP/S3; L7 lets us health-check and
    #      reuse keep-alive connections to backends.
    #    - balance roundrobin: even spread of the 128-way JuiceFS load.
    #    - option httpchk GET /: RGW returns 200 on "/" (anonymous list),
    #      so a failed RGW is pulled out automatically.
    local cfg="/tmp/haproxy-rgw.cfg"
    {
        echo "# Managed by deploy-lb.sh — do not edit by hand"
        echo "global"
        echo "    log /dev/log local0"
        echo "    maxconn 4096"
        echo "    daemon"
        echo "    stats socket /run/haproxy/admin.sock mode 660 level admin"
        echo ""
        echo "defaults"
        echo "    mode http"
        echo "    log global"
        echo "    option httplog"
        echo "    option dontlognull"
        echo "    timeout connect 10s"
        echo "    timeout client  300s"
        echo "    timeout server  300s"
        echo ""
        echo "frontend rgw_in"
        echo "    bind *:${LB_PORT}"
        echo "    default_backend rgw_pool"
        echo ""
        echo "backend rgw_pool"
        echo "    balance roundrobin"
        echo "    option httpchk GET /"
        echo "    http-check expect status 200"
        local i=1
        for b in "${RGW_BACKENDS[@]}"; do
            echo "    server rgw${i} ${b} check inter 3s fall 3 rise 2"
            i=$((i + 1))
        done
    } > "${cfg}"

    echo ">>> Pushing HAProxy config..."
    scp_srv "${LB_HOST}" "${cfg}" "/tmp/haproxy-rgw.cfg"
    ssh_srv "${LB_HOST}" "
        sudo cp /tmp/haproxy-rgw.cfg /etc/haproxy/haproxy.cfg
        # Validate before (re)starting so a bad config doesn't take the LB down
        if ! sudo haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
            echo '  ERROR: haproxy config validation failed:'
            sudo haproxy -c -f /etc/haproxy/haproxy.cfg || true
            exit 1
        fi
        sudo systemctl enable haproxy >/dev/null 2>&1 || true
        sudo systemctl restart haproxy
    "
    rm -f "${cfg}"

    echo ">>> Waiting for HAProxy (5s)..."
    sleep 5

    do_status

    echo ""
    echo "========================================"
    echo "LB deployed: http://${LB_HOST}:${LB_PORT}"
    echo "========================================"
    echo ""
    echo "NEXT: point JuiceFS at the LB. In config.sh set:"
    echo "    RGW_ENDPOINT=\"http://${LB_HOST}:${LB_PORT}\""
    echo "then re-run deploy-juicefs.sh format/mount as needed."
}

# ============================================================
# status
# ============================================================

do_status() {
    echo ">>> HAProxy service on ${LB_HOST}:"
    ssh_srv "${LB_HOST}" "systemctl is-active haproxy 2>/dev/null && echo '  active' || echo '  NOT active'"

    echo ">>> LB endpoint check (http://${LB_HOST}:${LB_PORT})..."
    if ssh_srv "${LB_HOST}" "curl -s --noproxy '*' --connect-timeout 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${LB_PORT}/ 2>/dev/null" | grep -qE '^(200|403|404)$'; then
        echo "  LB responding."
    else
        echo "  WARNING: LB not responding as expected."
    fi

    echo ">>> Backend reachability:"
    for b in "${RGW_BACKENDS[@]}"; do
        echo -n "  ${b}: "
        if ssh_srv "${LB_HOST}" "curl -s --noproxy '*' --connect-timeout 5 -o /dev/null -w '%{http_code}' http://${b}/ 2>/dev/null" | grep -qE '^(200|403|404)$'; then
            echo "reachable"
        else
            echo "UNREACHABLE"
        fi
    done
}

# ============================================================
# remove
# ============================================================

do_remove() {
    echo ">>> Removing HAProxy on ${LB_HOST}..."
    ssh_srv "${LB_HOST}" "
        sudo systemctl stop haproxy 2>/dev/null || true
        sudo systemctl disable haproxy 2>/dev/null || true
    "
    echo "  HAProxy stopped. (package left installed; purge manually if desired)"
    echo "  Remember to point RGW_ENDPOINT back to a single RGW in config.sh."
}

# ============================================================
# clear-stats
# ============================================================

do_clear_stats() {
    local sock="/run/haproxy/admin.sock"
    echo ">>> Resetting HAProxy counters on ${LB_HOST} (full restart)..."
    ssh_srv "${LB_HOST}" "
        command -v socat >/dev/null 2>&1 || {
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y socat >/dev/null 2>&1 || {
                echo '  ERROR: socat install failed'; exit 1; }
        }
    "
    _print_stat() {
        ssh_srv "${LB_HOST}" "echo 'show stat' | sudo socat - ${sock}" \
            2>/dev/null | awk -F, '/rgw/{printf "  %-10s %-10s req: %-8s bytes: %s\n", $1, $2, $28, $9}'
    }
    echo "Before:"
    _print_stat
    ssh_srv "${LB_HOST}" "sudo systemctl restart haproxy"
    sleep 2
    echo "After restart:"
    _print_stat
    ssh_srv "${LB_HOST}" "systemctl is-active haproxy 2>/dev/null && echo '  HAProxy: active' || echo '  HAProxy: NOT active'"
}

do_restart_haproxy() {
    do_clear_stats
}

# ============================================================
# Main
# ============================================================

case "${ACTION}" in
    deploy)         do_deploy ;;
    status)         do_status ;;
    remove)         do_remove ;;
    clear-stats)    do_clear_stats ;;
    restart-haproxy) do_restart_haproxy ;;
    *)
        echo "Usage: bash deploy-lb.sh [deploy|status|remove|clear-stats|restart-haproxy]"
        echo ""
        echo "  deploy          - Install + configure HAProxy on LB_HOST over RGW_BACKENDS"
        echo "  status          - Show LB service + backend reachability"
        echo "  remove          - Stop/disable HAProxy"
        echo "  clear-stats     - Reset request counters via admin socket"
        echo "  restart-haproxy - Full restart to reset all counters including byte accumulators"
        ;;
esac
