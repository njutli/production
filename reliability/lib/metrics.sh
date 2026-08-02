#!/bin/bash
# lib/metrics.sh — 指标采集（快照 + 连续采集双模式）
#
# 快照模式：一次性采集，保存到文件
# 连续采集模式：后台轮询集群状态，写入 CSV 时序文件，供回溯查询

# Auto-load config if not already loaded
if [ -z "${RELIABILITY_CONFIG_LOADED:-}" ]; then
    _metrics_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_metrics_dir}/../config/env.sh"
fi

# Auto-load cluster.sh if not already loaded
if ! command -v get_ceph_health &>/dev/null; then
    source "${_metrics_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/cluster.sh"
fi

# Global state for continuous monitoring
_METRICS_CSV_FILE=""
_METRICS_MONITOR_PID=""

# Default output directory for snapshots
: "${METRICS_DIR:=/tmp/reliability-metrics}"


# ============================================================
# 快照模式（点采样）
# ============================================================

# ceph status JSON → 文件，返回文件路径
snapshot_ceph_status() {
    local ts dir f
    ts=$(date +%s)
    dir="${METRICS_DIR}/snapshots"
    mkdir -p "$dir"
    f="${dir}/ceph_status_${ts}.json"
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph status --format json 2>/dev/null" > "$f"
    echo "$f"
}

# ceph report（完整集群报告）→ 文件
snapshot_ceph_report() {
    local ts dir f
    ts=$(date +%s)
    dir="${METRICS_DIR}/snapshots"
    mkdir -p "$dir"
    f="${dir}/ceph_report_${ts}.json"
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph report 2>/dev/null" > "$f"
    echo "$f"
}

# juicefs stats → 文件
snapshot_juicefs_stats() {
    local ts dir f
    ts=$(date +%s)
    dir="${METRICS_DIR}/snapshots"
    mkdir -p "$dir"
    f="${dir}/juicefs_stats_${ts}.txt"
    ssh_to_client "timeout 2 juicefs stats ${JUICEFS_MOUNT_POINT} 2>/dev/null" > "$f"
    echo "$f"
}

# 各节点 /proc/net/dev → 每节点一个文件
snapshot_nic() {
    local ts dir ip
    ts=$(date +%s)
    dir="${METRICS_DIR}/snapshots"
    mkdir -p "$dir"
    for ip in "${ALL_SERVERS[@]}"; do
        _run "$ip" "cat /proc/net/dev 2>/dev/null" > "${dir}/nic_${ip}_${ts}.txt"
    done
    echo "$dir"
}

# 各存储节点 iostat → 每节点一个文件
snapshot_iostat() {
    local ts dir ip
    ts=$(date +%s)
    dir="${METRICS_DIR}/snapshots"
    mkdir -p "$dir"
    for ip in "${SLAVE_SERVERS[@]}"; do
        _run "$ip" "iostat -x 1 1 2>/dev/null || cat /proc/diskstats 2>/dev/null" \
            > "${dir}/iostat_${ip}_${ts}.txt"
    done
    echo "$dir"
}


# ============================================================
# 连续采集模式（后台轮询，写入 CSV 时序文件）
# ============================================================

# start_monitoring [interval_s]
# 启动后台连续采集，返回 CSV 文件路径
# 默认间隔 2s（每次轮询需 2 次 SSH 调用，间隔为 SSH 耗时 + interval）
start_monitoring() {
    local interval=${1:-2}

    # 如果已有监控在跑，先停止
    if [ -n "$_METRICS_MONITOR_PID" ]; then
        stop_monitoring
    fi

    _METRICS_CSV_FILE=$(mktemp /tmp/reliability_monitor_XXXXXX.csv)

    # CSV 表头
    echo "epoch,osd_count_up,pg_states,quorum_count,health,tikv_store_count_up,tikv_leader" \
        > "$_METRICS_CSV_FILE"

    # 后台采集循环（stdin/stdout/stderr 全部重定向，避免 $(...) 管道挂起）
    (
        while true; do
            local ts osd_up pg quorum hlt tikv_up tikv_lead
            ts=$(date +%s)

            # 单次 ceph status --format json 提取 4 项 Ceph 指标
            local status_json
            status_json=$(_run "${CEPH_PRIMARY}" \
                "sudo cephadm shell -- ceph status --format json 2>/dev/null")
            osd_up=$(echo "$status_json" | jq -r '.osdmap.num_up_osds // ""' 2>/dev/null)
            pg=$(echo "$status_json" | jq -r \
                '.pgmap.pgs_by_state | map(.state_name) | join(" ") // ""' 2>/dev/null)
            quorum=$(echo "$status_json" | jq '.quorum | length // ""' 2>/dev/null)
            hlt=$(echo "$status_json" | jq -r '.health.status // ""' 2>/dev/null)

            # 单次 PD stores API 提取 2 项 TiKV 指标
            local stores_json
            stores_json=$(_run "${TIKV_SERVERS[0]}" \
                "curl -s http://127.0.0.1:2379/pd/api/v1/stores 2>/dev/null")
            tikv_up=$(echo "$stores_json" | jq \
                '[.stores[] | select(.store.state_name == "Up")] | length // ""' 2>/dev/null)

            local leader_json
            leader_json=$(_run "${TIKV_SERVERS[0]}" \
                "curl -s http://127.0.0.1:2379/pd/api/v1/leader 2>/dev/null")
            tikv_lead=$(echo "$leader_json" | jq -r '.name // ""' 2>/dev/null)

            # 写入 CSV（空值留空，不写 "null"）
            echo "${ts},${osd_up:-},${pg:-},${quorum:-},${hlt:-},${tikv_up:-},${tikv_lead:-}" \
                >> "$_METRICS_CSV_FILE"

            sleep "$interval"
        done
    ) </dev/null >/dev/null 2>&1 &
    _METRICS_MONITOR_PID=$!

    echo "$_METRICS_CSV_FILE"
}

# stop_monitoring
# 停止后台采集，返回 CSV 文件路径
stop_monitoring() {
    if [ -n "$_METRICS_MONITOR_PID" ]; then
        kill "$_METRICS_MONITOR_PID" 2>/dev/null
        wait "$_METRICS_MONITOR_PID" 2>/dev/null
        _METRICS_MONITOR_PID=""
    fi
    echo "${_METRICS_CSV_FILE:-}"
}

# get_metric_change_time <column> <value>
# 回溯 CSV 时序，找到指定列的值首次匹配 value 的时间戳
#   数值列：精确匹配（osd_count_up=4）
#   字符串列：包含匹配（pg_states contains "degraded"）
# 返回 epoch_seconds；未找到返回 0
get_metric_change_time() {
    local column=$1 value=$2
    local csv_file="${_METRICS_CSV_FILE:-}"

    if [ -z "$csv_file" ] || [ ! -f "$csv_file" ]; then
        echo 0
        return
    fi

    # 从表头找列号
    local col_idx
    col_idx=$(head -1 "$csv_file" | tr ',' '\n' | grep -n "^${column}$" | cut -d: -f1)
    [ -z "$col_idx" ] && { echo 0; return; }

    # 数值：精确匹配；字符串：包含匹配
    local result
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        result=$(awk -F, -v col="$col_idx" -v val="$value" \
            'NR>1 && $col == val { print $1; exit }' "$csv_file" 2>/dev/null)
    else
        result=$(awk -F, -v col="$col_idx" -v val="$value" \
            'NR>1 && index($col, val) { print $1; exit }' "$csv_file" 2>/dev/null)
    fi

    echo "${result:-0}"
}
