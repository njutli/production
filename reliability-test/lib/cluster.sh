#!/bin/bash
# lib/cluster.sh — 集群状态查询
#
# 所有集群操作经 SSH 直连对应节点执行：
#   - ceph 命令：_ceph / _ceph_json 从 CLIENT_SERVER(.12) 用 admin keyring + -m flag 遍历 MON
#   - PD/TiKV：_pd_api 从 CLIENT_SERVER curl 各 PD 节点 REST API
#   - JuiceFS：ssh_to_client "..."

# Auto-load config if not already loaded
if [ -z "${RELIABILITY_CONFIG_LOADED:-}" ]; then
    _cluster_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_cluster_dir}/../config/env.sh"
fi

# Check jq dependency
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed. Install: sudo apt install jq" >&2
    return 1 2>/dev/null || exit 1
fi


# ============================================================
# Internal helpers
# ============================================================

# Internal: run ceph command from CLIENT_SERVER via admin keyring + -m flag.
# Iterates MONs to skip blocked nodes (iptables crash). Works during node crash.
# Port check (timeout 2) skips blocked MONs in ~2s instead of ~15s SYN-DROP hang.
# rados_mon_op_timeout=10 on .12 ensures busy MON gets enough time.
# Usage: _ceph health / _ceph mon stat
_ceph() {
    local keyring="/etc/ceph/ceph.client.admin.keyring"
    local mon_ip result
    for mon_ip in "${SLAVE_SERVERS[@]}"; do
        result=$(timeout 20 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
            "${SSH_USER}@${CLIENT_SERVER}" \
            "timeout 2 bash -c 'echo > /dev/tcp/${mon_ip}/6789' 2>/dev/null && timeout 15 sudo ceph -k ${keyring} -m ${mon_ip} $* 2>/dev/null" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
    done
}

# Internal: run ceph command and return JSON (same remote approach).
# Usage: _ceph_json status / _ceph_json osd tree
_ceph_json() {
    local keyring="/etc/ceph/ceph.client.admin.keyring"
    local mon_ip result
    for mon_ip in "${SLAVE_SERVERS[@]}"; do
        result=$(timeout 20 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
            "${SSH_USER}@${CLIENT_SERVER}" \
            "timeout 2 bash -c 'echo > /dev/tcp/${mon_ip}/6789' 2>/dev/null && timeout 15 sudo ceph -k ${keyring} -m ${mon_ip} $* --format json 2>/dev/null" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
    done
}

# Query PD REST API — 遍历所有 PD 节点找第一个可达的
# （宕机场景下 TIKV_SERVERS[0] 可能不可达；leader 选举期间 follower 可能不响应）
# --connect-timeout 3: 快速跳过被 iptables 阻断的节点（SYN DROP）
# --max-time 5: 限制总请求时间，防止 PD leader 选举期间 curl 挂起
# timeout 10: SSH 外层兜底
_pd_api() {
    local path=$1 ip result
    for ip in "${TIKV_SERVERS[@]}"; do
        result=$(timeout 10 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" \
            "curl -s --connect-timeout 3 --max-time 5 http://${ip}:2379/pd/api/v1/${path} 2>/dev/null" 2>/dev/null)
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
    done
}


# ============================================================
# Ceph health
# ============================================================

# → "HEALTH_OK" / "HEALTH_WARN" / "HEALTH_ERR"
get_ceph_health() {
    _ceph health
}

# → 详细健康检查（多行文本）
get_ceph_health_detail() {
    _ceph health detail
}


# ============================================================
# PG states
# ============================================================

# → "active+clean" / "active+clean active+degraded" / ...
get_pg_states() {
    local json
    json=$(_ceph_json status)
    echo "$json" | jq -r '.pgmap.pgs_by_state | map(.state_name) | join(" ")' 2>/dev/null
}


# ============================================================
# OSD
# ============================================================

# get_osd_status <id> → "up" / "down"
get_osd_status() {
    local osd_id=$1 json
    json=$(_ceph_json osd tree)
    echo "$json" | jq -r --argjson id "$osd_id" \
        '.nodes[] | select(.type == "osd" and .id == $id) | .status' 2>/dev/null
}

# → 6 (count of up OSDs)
get_osd_count_up() {
    local json
    json=$(_ceph_json osd tree)
    echo "$json" | jq '[.nodes[] | select(.type == "osd" and .status == "up")] | length' 2>/dev/null
}

# → "0 2 8 9 10 11" (only up+in OSDs)
list_osd_ids() {
    local json
    json=$(_ceph_json osd tree)
    echo "$json" | jq -r \
        '[.nodes[] | select(.type == "osd" and .status == "up" and .reweight == 1) | .id] | sort | map(tostring) | join(" ")' 2>/dev/null
}

# → random up+in OSD id
pick_random_osd() {
    local ids
    ids=$(list_osd_ids)
    [ -z "$ids" ] && return 1
    echo "$ids" | tr ' ' '\n' | shuf -n 1
}

# pick_osd_on_node <node_ip> → first OSD id on that node
pick_osd_on_node() {
    local node_ip=$1
    local hostname="${CEPH_HOSTNAMES[$node_ip]}"
    if [ -z "$hostname" ]; then
        echo "unknown host for $node_ip" >&2
        return 1
    fi
    local json
    json=$(_ceph_json osd tree)
    echo "$json" | jq -r --arg host "$hostname" \
        '.nodes[] | select(.type == "host" and .name == $host) | .children[]' 2>/dev/null \
        | head -1
}

# get_osd_node <id> → node IP (e.g. "192.168.11.11")
get_osd_node() {
    local osd_id=$1 json hostname ip
    json=$(_ceph_json osd tree)
    hostname=$(echo "$json" | jq -r --argjson id "$osd_id" \
        '.nodes[] | select(.type == "host" and (.children | index($id))) | .name' 2>/dev/null)
    for ip in "${!CEPH_HOSTNAMES[@]}"; do
        if [ "${CEPH_HOSTNAMES[$ip]}" = "$hostname" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo "unknown"
}

# ensure_osd_up <id> — teardown 兜底，幂等（start 对已 up 的 OSD 无副作用）
ensure_osd_up() {
    local osd_id=$1 status
    status=$(get_osd_status "$osd_id")
    if [ "$status" != "up" ]; then
        _run "${CEPH_PRIMARY}" \
            "sudo cephadm shell -- ceph orch daemon start osd.${osd_id} 2>/dev/null" || true
    fi
}


# ============================================================
# MON quorum
# ============================================================

# → 3 (quorum member count)
get_quorum_count() {
    local result
    result=$(_ceph mon stat)
    echo "$result" | grep -oP 'quorum \K[0-9,]*' | tr ',' '\n' | wc -l
}


# ============================================================
# Recovery
# ============================================================

# → recovery stats JSON (empty if no recovery in progress)
get_recovery_status() {
    local json
    json=$(_ceph_json status)
    echo "$json" | jq '.pgmap.recovery_stats // empty' 2>/dev/null
}


# ============================================================
# PD / TiKV
# ============================================================

# → count of healthy PDs (e.g. 3)
get_pd_health() {
    local json
    json=$(_pd_api health)
    echo "$json" | jq '[.[] | select(.health == true)] | length' 2>/dev/null
}

# → raw stores JSON
get_tikv_stores() {
    _pd_api stores
}

# → count of Up TiKV stores (e.g. 3)
get_tikv_store_count_up() {
    local json
    json=$(_pd_api stores)
    echo "$json" | jq '[.stores[] | select(.store.state_name == "Up")] | length' 2>/dev/null
}

# → PD leader 名称 (e.g. "pd-1")
get_tikv_leader() {
    local json
    json=$(_pd_api leader)
    echo "$json" | jq -r '.name // empty' 2>/dev/null
}


# ============================================================
# JuiceFS
# ============================================================

# → "mounted" / "unmounted"
get_juicefs_status() {
    ssh_to_client "mountpoint -q ${JUICEFS_MOUNT_POINT} 2>/dev/null && echo mounted || echo unmounted"
}

# → juicefs stats 实时快照（timeout 2s 限制，避免交互式命令挂起）
get_juicefs_stats() {
    ssh_to_client "timeout 2 juicefs stats ${JUICEFS_MOUNT_POINT} 2>/dev/null"
}


# ============================================================
# 集群快照采集与校验
# 快照只保存 OSD 底层设备映射（会因用例操作而变化，需恢复）
# 校验时其余指标检查已知正确值（OSD=6, quorum=3, PG=active+clean 等）
# ============================================================

_SNAPSHOT_FILE=""

# capture_cluster_snapshot — 采集各存储节点的 PV→VG 映射（OSD 底层设备）
capture_cluster_snapshot() {
    local ts
    ts=$(date +%s)
    local snap_dir="/tmp/reliability-snapshot"
    mkdir -p "$snap_dir"
    _SNAPSHOT_FILE="${snap_dir}/snapshot_${ts}.txt"

    for ip in "${SLAVE_SERVERS[@]}"; do
        local hostname="${CEPH_HOSTNAMES[$ip]}"
        echo "[${hostname}]"
        # pvs 输出：PV 设备名 + VG 名，一行一对
        _run "$ip" "sudo pvs --noheadings -o pv_name,vg_name 2>/dev/null" 2>/dev/null \
            | tr -s ' ' | sort
        echo ""
    done > "$_SNAPSHOT_FILE" 2>/dev/null

    echo "$_SNAPSHOT_FILE"
}

# verify_cluster_snapshot — 校验集群是否恢复
# 固定校验项检查已知正确值；快照对比项检查设备映射是否变化
# 返回 0 = 通过，1 = 有异常
verify_cluster_snapshot() {
    local snap="${_SNAPSHOT_FILE:-}"
    local errors=0

    echo "  [verify] 开始校验（9 项固定 + 快照对比）"

    # 1. 集群非 ERR
    echo -n "  [verify] 1/9 ceph health... "
    local health
    health=$(get_ceph_health 2>/dev/null | head -1)
    if echo "$health" | grep -q "HEALTH_ERR"; then
        echo "FAIL"
        echo "  FAIL: 集群 HEALTH_ERR（$health）"
        errors=$((errors + 1))
    else
        echo "ok ($(echo "$health" | head -c 15))"
    fi

    # 2. OSD 数量 = 6
    echo -n "  [verify] 2/9 osd count up... "
    local osd_up
    osd_up=$(get_osd_count_up 2>/dev/null)
    if [ "${osd_up:-0}" != "6" ]; then
        echo "FAIL"
        echo "  FAIL: OSD up=${osd_up}（应为 6）"
        errors=$((errors + 1))
    else
        echo "ok (${osd_up})"
    fi

    # 3. PG 状态为 active+clean
    echo -n "  [verify] 3/9 pg states... "
    local pg
    pg=$(get_pg_states 2>/dev/null)
    if ! echo "$pg" | grep -q "active+clean"; then
        echo "FAIL"
        echo "  FAIL: PG 非 active+clean（当前=${pg}）"
        errors=$((errors + 1))
    else
        echo "ok"
    fi

    # 4. MON quorum = 3
    echo -n "  [verify] 4/9 mon quorum... "
    local quorum
    quorum=$(get_quorum_count 2>/dev/null)
    if [ "${quorum:-0}" != "3" ]; then
        echo "FAIL"
        echo "  FAIL: MON quorum=${quorum}（应为 3）"
        errors=$((errors + 1))
    else
        echo "ok (${quorum})"
    fi

    # 5. TiKV store = 3
    echo -n "  [verify] 5/9 tikv store... "
    local tikv
    tikv=$(get_tikv_store_count_up 2>/dev/null)
    if [ "${tikv:-0}" != "3" ]; then
        echo "FAIL"
        echo "  FAIL: TiKV store=${tikv}（应为 3）"
        errors=$((errors + 1))
    else
        echo "ok (${tikv})"
    fi

    # 6. JuiceFS 挂载
    echo -n "  [verify] 6/9 juicefs mount... "
    if [ "$(get_juicefs_status 2>/dev/null)" != "mounted" ]; then
        echo "FAIL"
        echo "  FAIL: JuiceFS 未挂载"
        errors=$((errors + 1))
    else
        echo "ok"
    fi

    # 7. 无 noout 残留
    echo -n "  [verify] 7/9 noout check... "
    local noout
    noout=$(_ceph osd dump | grep noout 2>/dev/null)
    if [ -n "$noout" ]; then
        echo "FAIL"
        echo "  FAIL: noout 标记残留"
        errors=$((errors + 1))
    else
        echo "ok"
    fi

    # 8. 无 iptables 残留
    echo -n "  [verify] 8/9 iptables (3 nodes)... "
    local residual_iptables=0
    local ip
    for ip in "${SLAVE_SERVERS[@]}"; do
        local rules
        rules=$(_run "$ip" "sudo iptables-save 2>/dev/null | grep reliability" 2>/dev/null)
        [ -n "$rules" ] && residual_iptables=1
    done
    if [ "$residual_iptables" = 1 ]; then
        echo "FAIL"
        echo "  FAIL: iptables 残留规则"
        errors=$((errors + 1))
    else
        echo "ok"
    fi

    # 9. 无 dmsetup 挂起设备残留
    echo -n "  [verify] 9/9 dmsetup (3 nodes)... "
    local residual_suspended=0
    for ip in "${SLAVE_SERVERS[@]}"; do
        local suspended
        suspended=$(_run "$ip" \
            "sudo dmsetup info 2>/dev/null | grep -c Suspended" 2>/dev/null)
        [ "${suspended:-0}" -gt 0 ] && residual_suspended=1
    done
    if [ "$residual_suspended" = 1 ]; then
        echo "FAIL"
        echo "  FAIL: dmsetup 挂起设备残留"
        errors=$((errors + 1))
    else
        echo "ok"
    fi

    # --- 快照对比（OSD 底层设备映射）---

    if [ -n "$snap" ] && [ -f "$snap" ]; then
        echo -n "  [verify] snapshot diff (3 nodes)... "
        local snap_errors=0
        for ip in "${SLAVE_SERVERS[@]}"; do
            local hostname="${CEPH_HOSTNAMES[$ip]}"
            # 从快照提取该节点的 pvs 输出
            local snap_pvs
            snap_pvs=$(sed -n "/^\[${hostname}\]/,/^\[/p" "$snap" \
                | grep -v '^\[' | grep -v '^$' | sort)
            # 采集当前 pvs
            local cur_pvs
            cur_pvs=$(_run "$ip" "sudo pvs --noheadings -o pv_name,vg_name 2>/dev/null" 2>/dev/null \
                | tr -s ' ' | sort)

            if [ "$snap_pvs" != "$cur_pvs" ]; then
                [ "$snap_errors" = 0 ] && echo "FAIL"
                echo "  FAIL: ${hostname} 设备映射变化"
                echo "  快照:"
                echo "$snap_pvs" | sed 's/^/    /'
                echo "  当前:"
                echo "$cur_pvs" | sed 's/^/    /'
                snap_errors=$((snap_errors + 1))
                errors=$((errors + 1))
            fi
        done
        [ "$snap_errors" = 0 ] && echo "ok"
    fi

    echo "  [verify] 完成: ${errors} 个异常"
    [ "$errors" = 0 ] && return 0 || return 1
}

# remove_cluster_snapshot — 移除快照文件
remove_cluster_snapshot() {
    [ -n "$_SNAPSHOT_FILE" ] && rm -f "$_SNAPSHOT_FILE" 2>/dev/null
    _SNAPSHOT_FILE=""
}
