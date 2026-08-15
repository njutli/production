#!/bin/bash
# lib/fault_inject.sh — 故障注入原语
#
# 安全边界：注入目标是存储节点，模拟后端集群故障。
# 禁止：iptables on ${MGMT_NETWORK_PREFIX}.0/24（SSH 生命线）；iptables 整网段 DROP。

# Auto-load config if not already loaded
if [ -z "${RELIABILITY_CONFIG_LOADED:-}" ]; then
    _fi_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_fi_dir}/../config/env.sh"
fi


# ============================================================
# OSD 操作
# ============================================================

# stop_osd <id> — SIGKILL 立即杀死 OSD（模拟进程崩溃，触发 fast fail）
# systemctl stop --no-block 防止 systemd 自动重启，podman kill --signal KILL 立即杀容器
stop_osd() {
    local osd_id=$1
    local node
    node=$(get_osd_node "$osd_id")
    if [ -n "$node" ] && [ "$node" != "unknown" ]; then
        # 1. 告诉 systemd 停止（--no-block 立即返回，防止 on-failure 重启）
        _run "$node" "sudo systemctl stop --no-block ceph-*@osd.${osd_id}.service 2>/dev/null"
        # 2. 立即 SIGKILL 容器（cephadm 用 podman，不等 SIGTERM 10s 超时）
        local cid
        cid=$(_run "$node" "sudo podman ps --format '{{.Names}} {{.ID}}'" 2>/dev/null | awk -v id="osd[-.]${osd_id}\$" '$1 ~ id {print $2}')
        if [ -n "$cid" ]; then
            _run "$node" "sudo podman kill --signal KILL $cid 2>/dev/null"
        fi
    fi
}

# start_osd <id> — 启动（幂等：对已 up 的 OSD 无副作用）
# SIGKILL 后 systemd 服务处于 failed 状态，需 reset-failed 才能重启
start_osd() {
    local osd_id=$1
    local node
    node=$(get_osd_node "$osd_id")
    if [ -n "$node" ] && [ "$node" != "unknown" ]; then
        _run "$node" "sudo systemctl reset-failed ceph-*@osd.${osd_id}.service 2>/dev/null; sudo systemctl start ceph-*@osd.${osd_id}.service 2>/dev/null"
    fi
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon start osd.${osd_id} 2>/dev/null"
}

# out_osd <id> — 标记淘汰（触发 rebalance；零 spare 架构下 PG 卡 degraded）
out_osd() {
    local osd_id=$1
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd out ${osd_id} 2>/dev/null"
}

# in_osd <id> — 标记回归
in_osd() {
    local osd_id=$1
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd in ${osd_id} 2>/dev/null"
}


# ============================================================
# TiKV / PD / MON 操作
# ============================================================

# stop_tikv <ip> / start_tikv <ip> — systemd 服务
stop_tikv() {
    _run "$1" "sudo systemctl stop tikv 2>/dev/null"
}

start_tikv() {
    _run "$1" "sudo systemctl start tikv 2>/dev/null"
}

# freeze_tikv <ip> — kill -STOP 冻结 TiKV 进程（模拟节点假死）
# 进程不死→不触发 Restart=always，无 TCP RST→follower 心跳超时→真实选举
freeze_tikv() {
    local ip=$1
    _run "$ip" "sudo kill -STOP \$(pgrep -x tikv-server | head -1) 2>/dev/null"
}

# unfreeze_tikv <ip> — kill -CONT 恢复冻结的 TiKV
unfreeze_tikv() {
    local ip=$1
    _run "$ip" "sudo kill -CONT \$(pgrep -x tikv-server | head -1) 2>/dev/null"
}

# freeze_pd <ip> — kill -STOP 冻结 PD 进程（模拟节点假死）
freeze_pd() {
    local ip=$1
    _run "$ip" "sudo kill -STOP \$(pgrep -x pd-server | head -1) 2>/dev/null"
}

# unfreeze_pd <ip> — kill -CONT 恢复冻结的 PD
unfreeze_pd() {
    local ip=$1
    _run "$ip" "sudo kill -CONT \$(pgrep -x pd-server | head -1) 2>/dev/null"
}

# mask_tikv_runtime <ip> — 运行时遮蔽 tikv service（在 /run/systemd/system 建遮蔽）
# 不与 /etc/systemd/system/tikv.service 冲突，重启后自动失效
mask_tikv_runtime() {
    local ip=$1
    _run "$ip" "sudo systemctl mask --runtime tikv 2>/dev/null"
}

# unmask_tikv_runtime <ip> — 取消运行时遮蔽
unmask_tikv_runtime() {
    local ip=$1
    _run "$ip" "sudo systemctl unmask --runtime tikv 2>/dev/null"
}

# get_meta_region_leader_node — 查 PD API，返回 JuiceFS metadata region leader 所在节点 IP
# 如果查询失败，返回空字符串（调用方应 fallback 到随机选择）
get_meta_region_leader_node() {
    local pd_ep="${TIKV_SERVERS[0]}:2379"
    local fs_name_hex
    fs_name_hex=$(printf '%s' "${JUICEFS_FS_NAME}" | xxd -p 2>/dev/null | tr -d '\n')
    if [ -z "$fs_name_hex" ]; then
        echo ""
        return 1
    fi

    local region_json leader_store_id
    region_json=$(curl -s --max-time 5 "http://${pd_ep}/pd/api/v1/region/key/${fs_name_hex}" 2>/dev/null)
    leader_store_id=$(echo "$region_json" | jq -r '.leader.store_id // empty' 2>/dev/null)

    if [ -z "$leader_store_id" ]; then
        echo ""
        return 1
    fi

    local stores_json store_addr
    stores_json=$(curl -s --max-time 5 "http://${pd_ep}/pd/api/v1/stores" 2>/dev/null)
    store_addr=$(echo "$stores_json" | jq -r ".stores[] | select(.store.id == ${leader_store_id}) | .store.address" 2>/dev/null)

    # store_addr 格式: "192.168.11.13:20160"
    echo "$store_addr" | cut -d: -f1
}

stop_pd() {
    _run "$1" "sudo systemctl stop pd 2>/dev/null"
}

start_pd() {
    _run "$1" "sudo systemctl start pd 2>/dev/null"
}

# stop_mon <node_ip> / start_mon <node_ip> — cephadm 容器
stop_mon() {
    local node_ip=$1
    local hostname="${CEPH_HOSTNAMES[$node_ip]}"
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon stop mon.${hostname} 2>/dev/null"
}

start_mon() {
    local node_ip=$1
    local hostname="${CEPH_HOSTNAMES[$node_ip]}"
    # 在 quorum 中的节点上跑 cephadm（如果目标节点 MON down，cephadm 在该节点可能连不上 MON）
    local mon_up_ip=""
    for ip in "${SLAVE_SERVERS[@]}"; do
        [ "$ip" = "$node_ip" ] && continue
        mon_up_ip="$ip"
        break
    done
    [ -z "$mon_up_ip" ] && mon_up_ip="${SLAVE_SERVERS[0]}"
    # cephadm 可能还在处理 stop 命令，等几秒再 start
    sleep 3
    echo "  start_mon: cephadm on ${mon_up_ip} starting mon.${hostname}..."
    # cephadm 有时返回非零但实际已调度 start，不依赖退出码
    timeout 60 sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
        "${SSH_USER}@${mon_up_ip}" "sudo cephadm shell -- ceph orch daemon start mon.${hostname}" 2>&1 || true
    # 也尝试 systemctl 兜底
    _run "$node_ip" "sudo systemctl start ceph-*@mon.${hostname}.service 2>/dev/null" 2>/dev/null || true
}


# ============================================================
# 节点级操作
# ============================================================

# stop_node_storage <ip> — 优雅停止节点全部存储服务
# TiKV/PD 用 systemctl stop；Ceph OSD/MON 用 ceph orch daemon stop
stop_node_storage() {
    local ip=$1
    local hostname="${CEPH_HOSTNAMES[$ip]}"

    # TiKV + PD
    _run "$ip" "sudo systemctl stop tikv pd 2>/dev/null" || true

    # Ceph OSDs on this node
    local osd_tree osd_ids
    osd_tree=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd tree --format json 2>/dev/null")
    osd_ids=$(echo "$osd_tree" | jq -r --arg host "$hostname" \
        '.nodes[] | select(.type == "host" and .name == $host) | .children[]' 2>/dev/null)
    for id in $osd_ids; do
        _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon stop osd.${id}" 2>/dev/null || true
    done

    # Ceph MON
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon stop mon.${hostname}" 2>/dev/null || true
}

# start_node_storage <ip> — 启动节点全部存储服务
start_node_storage() {
    local ip=$1
    local hostname="${CEPH_HOSTNAMES[$ip]}"

    # TiKV + PD
    _run "$ip" "sudo systemctl start pd tikv 2>/dev/null" || true

    # Ceph OSDs on this node
    local osd_tree osd_ids
    osd_tree=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd tree --format json 2>/dev/null")
    osd_ids=$(echo "$osd_tree" | jq -r --arg host "$hostname" \
        '.nodes[] | select(.type == "host" and .name == $host) | .children[]' 2>/dev/null)
    for id in $osd_ids; do
        _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon start osd.${id}" 2>/dev/null || true
    done

    # Ceph MON
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon start mon.${hostname}" 2>/dev/null || true
}

# crash_node_storage <ip> — iptables 阻断目标节点所有流量（模拟节点不可达）
# 保留 SSH（端口 22）用于恢复，10 分钟自动恢复作为安全网
crash_node_storage() {
    local ip=$1
    local keyring="/etc/ceph/ceph.client.admin.keyring"

    # 1) 从 .12 设置 noout（admin keyring，防 rebalance）
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" \
        "sudo ceph -k ${keyring} osd set noout 2>/dev/null" || true

    # 2) iptables 阻断目标节点所有流量（保留 SSH）
    # nohup 确保自动恢复在 SSH 会话关闭后仍能运行
    _run "$ip" "
        sudo iptables -F
        sudo iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
        sudo iptables -I OUTPUT 1 -p tcp --sport 22 -j ACCEPT
        sudo iptables -A INPUT -j DROP
        sudo iptables -A OUTPUT -j DROP
        nohup bash -c 'sleep 600; sudo iptables -F' > /dev/null 2>&1 &
        echo blocked
    " || true
}

# restart_node_storage <ip> — 清除 iptables 规则，节点恢复通信
restart_node_storage() {
    local ip=$1
    local keyring="/etc/ceph/ceph.client.admin.keyring"

    # 1) 清除 iptables（SSH 仍可用，可以直接连）
    _run "$ip" "sudo iptables -F; echo cleared" || true

    # 2) 从 .12 取消 noout
    sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" \
        "sudo ceph -k ${keyring} osd unset noout 2>/dev/null" || true
}


# ============================================================
# 网络操作
# ============================================================

# net_partition <src_ip> <dst_ip> <ports...> — iptables 端口级 DROP
# 拒绝管理网段 10.20.1.0/24（SSH 生命线）
net_partition() {
    local src_ip=$1 dst_ip=$2
    shift 2
    local ports=("$@")

    [ ${#ports[@]} -eq 0 ] && { echo "ERROR: net_partition: no ports specified" >&2; return 1; }

    # 安全 guard：拒绝管理网段
    case "${src_ip}|${dst_ip}" in
        *${MGMT_NETWORK_PREFIX}.*)
            echo "ERROR: net_partition: 拒绝操作管理网段 ${MGMT_NETWORK_PREFIX}.0/24（SSH 生命线）" >&2
            return 1
            ;;
    esac

    local port
    for port in "${ports[@]}"; do
        _run "$src_ip" "sudo iptables -I INPUT -s ${dst_ip} -p tcp --dport ${port} -j DROP -m comment --comment reliability 2>/dev/null" || true
        _run "$src_ip" "sudo iptables -I OUTPUT -d ${dst_ip} -p tcp --dport ${port} -j DROP -m comment --comment reliability 2>/dev/null" || true
    done
}

# net_partition_clear <ip> — 清除本框架安装的 iptables 规则（按 comment 标记）
net_partition_clear() {
    local ip=$1
    _run "$ip" "sudo iptables-save 2>/dev/null | grep reliability | sed 's/^-A /-D /' | while read -r rule; do sudo iptables \$rule 2>/dev/null; done || true"
}
