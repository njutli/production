#!/bin/bash
set -euo pipefail

# soft-clean.sh — 轮间清理（juicefs destroy + OSD restart + compact + drop caches）
# 在 157 上运行。用于 FULLBASELINE 测试轮间清理。
#
# ⚠️ 本脚本会重启 OSD 容器 → PG primary 重选举 → 物理布局映射变化。
#    是否影响 randread 波动是实验研究的问题，按需使用。
#
# 用法：bash soft-clean.sh [config_file]
# 必须遵守 SYSTEM-SAFETY-SKILL.md

# ===== 参数 =====

SSH_USER="${SSH_USER:-sunrise}"
SSH_PASS="${SSH_PASS:-Sunrise@801}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

SLAVE_IPS="${SLAVE_IPS:-10.20.1.150 10.20.1.151 10.20.1.152}"
PRIMARY_IP="${PRIMARY_IP:-10.20.1.150}"

POOL_NAME="${POOL_NAME:-juicefs-data}"

JUICEFS_META="${JUICEFS_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}"
JUICEFS_VOL="${JUICEFS_VOL:-juicefs-prod}"
JUICEFS_MNT="${JUICEFS_MNT:-/mnt/juicefs}"

# ===== 函数 =====

log() { echo "[$(date '+%H:%M:%S')] $*"; }

ssh_node() {
    local ip="$1"; shift
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "$@"
}

drop_caches() {
    log "  drop_caches"
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in ${SLAVE_IPS}; do
        ssh_node "${ip}" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
}

compact_cooldown() {
    log "  compact_cooldown"
    local osd_ids
    osd_ids=$(ssh_node "${PRIMARY_IP}" "sudo ceph osd ls 2>/dev/null")
    
    for osd in ${osd_ids}; do
        ssh_node "${PRIMARY_IP}" "sudo ceph tell osd.${osd} compact 2>/dev/null" || true
    done
    
    for i in $(seq 1 120); do
        local all_done=true
        for osd in ${osd_ids}; do
            local running queued
            read -r running queued < <(ssh_node "${PRIMARY_IP}" \
                "sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
                'import sys,json;r=json.load(sys.stdin).get(\"rocksdb\",{});print(r.get(\"compact_running\",1),r.get(\"compact_queue_len\",1))' 2>/dev/null" \
                || echo "0 0")
            [ "${running}" != "0" ] && all_done=false
            [ "${queued}" != "0" ] && all_done=false
        done
        $all_done && { log "  compact done (~$((i*5))s)"; return 0; }
        sleep 5
    done
    log "  WARN: compact not clean after 10min"
}

restart_osds() {
    log "  restart OSD containers"
    for ip in ${SLAVE_IPS}; do
        ssh_node "${ip}" \
            'for c in $(sudo podman ps --format "{{.Names}}" 2>/dev/null | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done' \
            2>/dev/null || true
    done
    
    log "  waiting for PG active+clean..."
    for i in $(seq 1 120); do
        local pg
        pg=$(ssh_node "${PRIMARY_IP}" "sudo ceph -s 2>/dev/null | grep 'pgs:' | head -1")
        echo "${pg}" | grep -qE "active\+clean" && { log "  PG active+clean"; break; }
        echo "  ${pg}"
        sleep 5
    done
}

juicefs_destroy() {
    log "  juicefs destroy"
    fusermount -u "${JUICEFS_MNT}" 2>/dev/null || true
    pkill -f "juicefs.*mount" 2>/dev/null || true
    sleep 5
    
    # 等会话过期
    log "  waiting for session timeout (65s)..."
    sleep 65
    
    local uuid
    uuid=$(juicefs status "${JUICEFS_META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    if [ -n "${uuid}" ]; then
        juicefs destroy "${JUICEFS_META}" "${uuid}" --yes 2>&1 | tail -1
    else
        log "  WARN: no JuiceFS UUID found"
    fi
    
    # rados purge 确保清空
    log "  rados purge"
    ssh_node "${PRIMARY_IP}" \
        "sudo rados purge '${POOL_NAME}' --yes-i-really-really-mean-it 2>/dev/null" || true
}

juicefs_format_mount() {
    log "  juicefs format + mount"
    juicefs format \
        --storage ceph --bucket "ceph://${POOL_NAME}" \
        --access-key ceph --secret-key client.juicefs \
        --block-size 256K --trash-days 0 --force \
        "${JUICEFS_META}" "${JUICEFS_VOL}" 2>/dev/null | tail -1
    
    juicefs mount -d --max-uploads 150 --cache-size 0 \
        "${JUICEFS_META}" "${JUICEFS_MNT}" 2>&1 | tail -1
    sleep 3
    mount | grep -q juice || { log "FATAL: mount failed"; exit 1; }
    mkdir -p "${JUICEFS_MNT}/test_dir"
}

# ===== 主入口 =====

if [ -n "${1:-}" ] && [ -f "$1" ]; then
    log "loading config: $1"
    source "$1"
fi

log "===== SOFT-CLEAN START ====="

juicefs_destroy
compact_cooldown
restart_osds
compact_cooldown
drop_caches
juicefs_format_mount

log "===== SOFT-CLEAN DONE ====="
