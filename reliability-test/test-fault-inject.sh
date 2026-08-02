#!/bin/bash
# 临时测试脚本：验证 fault_inject.sh 各函数
# 使用 mock（不连接集群，不影响性能测试）
# 用法：bash test-fault-inject.sh

cd "$(dirname "$0")" || exit 1
source config/env.sh

PASS=0; FAIL=0
ok()   { echo "  ok  - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# ============================================================
# Mock _run：捕获命令，不实际执行
# ============================================================
CALLS=()
_run() {
    local ip=$1; shift
    CALLS+=("[${ip}] $*")
    # 对 ceph osd tree 返回 mock JSON
    case "$*" in
        *ceph\ osd\ tree\ --format\ json*)
            echo '{"nodes":[{"id":-3,"name":"ceph-node1","type":"host","children":[0,1]},{"id":0,"name":"osd.0","type":"osd"},{"id":1,"name":"osd.1","type":"osd"}]}'
            ;;
    esac
}
ssh_to_client() {
    CALLS+=("[client] $*")
}

source lib/fault_inject.sh 2>/dev/null

show_calls() {
    local label=$1
    echo "  --- ${label} ---"
    local i
    for i in "${!CALLS[@]}"; do
        echo "  [${i}] ${CALLS[$i]}"
    done
}

echo "=========================================="
echo " fault_inject.sh mock 测试"
echo "=========================================="

# ============================================================
# 1. OSD 操作
# ============================================================
echo ""
echo "--- 1. OSD 操作 ---"

CALLS=()
stop_osd 3
[ "${#CALLS[@]}" = 1 ] && ok "stop_osd: 1 次调用" || fail "stop_osd: ${#CALLS[@]} 次调用"
[[ "${CALLS[0]}" == *"ceph orch daemon stop osd.3"* ]] && ok "stop_osd: 命令正确" || fail "stop_osd: ${CALLS[0]}"

CALLS=()
start_osd 5
[[ "${CALLS[0]}" == *"ceph orch daemon start osd.5"* ]] && ok "start_osd: 命令正确" || fail "start_osd: ${CALLS[0]}"

CALLS=()
out_osd 2
[[ "${CALLS[0]}" == *"ceph osd out 2"* ]] && ok "out_osd: 命令正确" || fail "out_osd: ${CALLS[0]}"

CALLS=()
in_osd 2
[[ "${CALLS[0]}" == *"ceph osd in 2"* ]] && ok "in_osd: 命令正确" || fail "in_osd: ${CALLS[0]}"

# ============================================================
# 2. TiKV / PD / MON 操作
# ============================================================
echo ""
echo "--- 2. TiKV / PD / MON ---"

CALLS=()
stop_tikv 192.168.11.11
[ "${CALLS[0]}" = "[192.168.11.11] sudo systemctl stop tikv 2>/dev/null" ] && ok "stop_tikv" || fail "stop_tikv: ${CALLS[0]}"

CALLS=()
start_tikv 192.168.11.13
[ "${CALLS[0]}" = "[192.168.11.13] sudo systemctl start tikv 2>/dev/null" ] && ok "start_tikv" || fail "start_tikv: ${CALLS[0]}"

CALLS=()
stop_pd 192.168.11.11
[ "${CALLS[0]}" = "[192.168.11.11] sudo systemctl stop pd 2>/dev/null" ] && ok "stop_pd" || fail "stop_pd: ${CALLS[0]}"

CALLS=()
start_pd 192.168.11.14
[ "${CALLS[0]}" = "[192.168.11.14] sudo systemctl start pd 2>/dev/null" ] && ok "start_pd" || fail "start_pd: ${CALLS[0]}"

CALLS=()
stop_mon 192.168.11.11
[[ "${CALLS[0]}" == *"ceph orch daemon stop mon.ceph-node1"* ]] && ok "stop_mon: hostname 映射正确" || fail "stop_mon: ${CALLS[0]}"

CALLS=()
start_mon 192.168.11.14
[[ "${CALLS[0]}" == *"ceph orch daemon start mon.ceph-node3"* ]] && ok "start_mon: hostname 映射正确" || fail "start_mon: ${CALLS[0]}"

# ============================================================
# 3. stop_node_storage — 优雅停止
# ============================================================
echo ""
echo "--- 3. stop_node_storage ---"

CALLS=()
stop_node_storage 192.168.11.11

# stop_node_storage 调用序列：
#   1) systemctl stop tikv pd
#   2) ceph osd tree --format json（在 $(...) 子 shell 中，CALLS 不记录）
#   3) ceph orch daemon stop osd.0
#   4) ceph orch daemon stop osd.1
#   5) ceph orch daemon stop mon.ceph-node1
# 父 shell 只看到 4 次（子 shell 中的 osd tree 查询不回传 CALLS）
[ "${#CALLS[@]}" = 4 ] && ok "stop_node_storage: ${#CALLS[@]} 次调用 (expected 4)" || { echo "  calls=${#CALLS[@]}"; fail "stop_node_storage: 调用次数"; show_calls "all calls"; }

# 验证 systemctl stop tikv pd
found_systemctl=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"systemctl stop tikv pd"* ]] && found_systemctl=1
done
[ "$found_systemctl" = 1 ] && ok "stop_node_storage: 含 systemctl stop tikv pd" || fail "stop_node_storage: 不含 systemctl stop"

# 验证 ceph orch daemon stop osd.0 和 osd.1
found_osd0=0; found_osd1=0; found_mon=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"stop osd.0"* ]] && found_osd0=1
    [[ "$c" == *"stop osd.1"* ]] && found_osd1=1
    [[ "$c" == *"stop mon.ceph-node1"* ]] && found_mon=1
done
[ "$found_osd0" = 1 ] && ok "stop_node_storage: 停 osd.0" || fail "stop_node_storage: 未停 osd.0"
[ "$found_osd1" = 1 ] && ok "stop_node_storage: 停 osd.1" || fail "stop_node_storage: 未停 osd.1"
[ "$found_mon" = 1 ] && ok "stop_node_storage: 停 mon.ceph-node1" || fail "stop_node_storage: 未停 mon"

# ============================================================
# 4. start_node_storage — 启动
# ============================================================
echo ""
echo "--- 4. start_node_storage ---"

CALLS=()
start_node_storage 192.168.11.11

found_systemctl=0; found_osd0=0; found_osd1=0; found_mon=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"systemctl start pd tikv"* ]] && found_systemctl=1
    [[ "$c" == *"start osd.0"* ]] && found_osd0=1
    [[ "$c" == *"start osd.1"* ]] && found_osd1=1
    [[ "$c" == *"start mon.ceph-node1"* ]] && found_mon=1
done
[ "$found_systemctl" = 1 ] && ok "start_node_storage: systemctl start pd tikv" || fail "start_node_storage: systemctl"
[ "$found_osd0" = 1 ] && ok "start_node_storage: 启动 osd.0" || fail "start_node_storage: osd.0"
[ "$found_osd1" = 1 ] && ok "start_node_storage: 启动 osd.1" || fail "start_node_storage: osd.1"
[ "$found_mon" = 1 ] && ok "start_node_storage: 启动 mon" || fail "start_node_storage: mon"

# ============================================================
# 5. crash_node_storage — SIGKILL 模拟宕机
# ============================================================
echo ""
echo "--- 5. crash_node_storage ---"

CALLS=()
crash_node_storage 192.168.11.11

# 验证步骤序列
found_noout=0; found_maint=0; found_mask=0; found_kill=0; found_podman=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"ceph osd set noout"* ]] && found_noout=1
    [[ "$c" == *"set-status ceph-node1 maintenance"* ]] && found_maint=1
    [[ "$c" == *"systemctl mask tikv pd"* ]] && found_mask=1
    [[ "$c" == *"kill -9"* ]] && found_kill=1
    [[ "$c" == *"podman kill"* ]] && found_podman=1
done
[ "$found_noout" = 1 ] && ok "crash: set noout" || fail "crash: 未 set noout"
[ "$found_maint" = 1 ] && ok "crash: set maintenance" || fail "crash: 未 set maintenance"
[ "$found_mask" = 1 ] && ok "crash: mask tikv pd" || fail "crash: 未 mask"
[ "$found_kill" = 1 ] && ok "crash: kill -9 tikv/pd 进程" || fail "crash: 未 kill"
[ "$found_podman" = 1 ] && ok "crash: podman kill ceph 容器" || fail "crash: 未 podman kill"

# 验证 mask 在 kill 之前
mask_idx=-1; kill_idx=-1
for i in "${!CALLS[@]}"; do
    [[ "${CALLS[$i]}" == *"mask tikv pd"* ]] && mask_idx=$i
    [[ "${CALLS[$i]}" == *"kill -9"* ]] && kill_idx=$i
done
[ "$mask_idx" -lt "$kill_idx" ] && ok "crash: mask 在 kill 之前 (mask=$mask_idx kill=$kill_idx)" || fail "crash: mask 应在 kill 之前 (mask=$mask_idx kill=$kill_idx)"

# ============================================================
# 6. restart_node_storage — 从 crash 恢复
# ============================================================
echo ""
echo "--- 6. restart_node_storage ---"

CALLS=()
restart_node_storage 192.168.11.11

found_unmask=0; found_start=0; found_active=0; found_unset=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"systemctl unmask tikv pd"* ]] && found_unmask=1
    [[ "$c" == *"systemctl start pd tikv"* ]] && found_start=1
    [[ "$c" == *"set-status ceph-node1 active"* ]] && found_active=1
    [[ "$c" == *"ceph osd unset noout"* ]] && found_unset=1
done
[ "$found_unmask" = 1 ] && ok "restart: unmask tikv pd" || fail "restart: 未 unmask"
[ "$found_start" = 1 ] && ok "restart: start pd tikv" || fail "restart: 未 start"
[ "$found_active" = 1 ] && ok "restart: set host active" || fail "restart: 未 set active"
[ "$found_unset" = 1 ] && ok "restart: unset noout" || fail "restart: 未 unset noout"

# 验证 unmask 在 start 之前
unmask_idx=-1; start_idx=-1
for i in "${!CALLS[@]}"; do
    [[ "${CALLS[$i]}" == *"unmask tikv pd"* ]] && unmask_idx=$i
    [[ "${CALLS[$i]}" == *"systemctl start pd tikv"* ]] && start_idx=$i
done
[ "$unmask_idx" -lt "$start_idx" ] && ok "restart: unmask 在 start 之前" || fail "restart: unmask 应在 start 之前"

# ============================================================
# 7. net_partition — 安全 guard
# ============================================================
echo ""
echo "--- 7. net_partition 安全 guard ---"

CALLS=()
net_partition 192.168.11.11 192.168.11.13 6800 6801 2>/dev/null
RC=$?
[ "$RC" -ne 0 ] && ok "net_partition: 拒绝管理网段 (rc=$RC)" || fail "net_partition: 未拒绝管理网段"
[ "${#CALLS[@]}" = 0 ] && ok "net_partition: 管理网段不产生任何调用" || fail "net_partition: 管理网段不应有调用"

CALLS=()
net_partition 10.0.0.6 10.0.0.7 6800 6801 2>/dev/null
RC=$?
[ "$RC" = 0 ] && ok "net_partition: 允许非管理网段" || fail "net_partition: 应允许非管理网段"
[ "${#CALLS[@]}" -gt 0 ] && ok "net_partition: 产生 ${#CALLS[@]} 次调用" || fail "net_partition: 无调用"

# 验证 iptables 规则含端口和对端 IP
found_port=0; found_dst=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"--dport 6800"* ]] && found_port=1
    [[ "$c" == *"10.0.0.7"* ]] && found_dst=1
done
[ "$found_port" = 1 ] && ok "net_partition: 含 --dport 6800" || fail "net_partition: 不含端口"
[ "$found_dst" = 1 ] && ok "net_partition: 含对端 IP 10.0.0.7" || fail "net_partition: 不含对端 IP"

# 验证含 reliability comment 标记（用于 net_partition_clear 定向清理）
found_comment=0
for c in "${CALLS[@]}"; do
    [[ "$c" == *"--comment reliability"* ]] && found_comment=1
done
[ "$found_comment" = 1 ] && ok "net_partition: 含 --comment reliability 标记" || fail "net_partition: 不含 comment 标记"

# ============================================================
# 8. net_partition_clear — 按标记清理
# ============================================================
echo ""
echo "--- 8. net_partition_clear ---"

CALLS=()
net_partition_clear 10.0.0.6
[ "${#CALLS[@]}" = 1 ] && ok "net_partition_clear: 1 次调用" || fail "net_partition_clear: ${#CALLS[@]} 次调用"
[[ "${CALLS[0]}" == *"iptables-save"* ]] && ok "net_partition_clear: 含 iptables-save" || fail "net_partition_clear: 不含 iptables-save"
[[ "${CALLS[0]}" == *"grep reliability"* ]] && ok "net_partition_clear: 含 grep reliability" || fail "net_partition_clear: 不含 grep"

# ============================================================
# 9. net_partition 无端口参数
# ============================================================
echo ""
echo "--- 9. net_partition 无端口 ---"

CALLS=()
net_partition 10.0.0.6 10.0.0.7 2>/dev/null
RC=$?
[ "$RC" -ne 0 ] && ok "net_partition: 无端口时报错" || fail "net_partition: 无端口应报错"
[ "${#CALLS[@]}" = 0 ] && ok "net_partition: 无端口不产生调用" || fail "net_partition: 无端口不应有调用"


echo ""
echo "=========================================="
echo " 结果: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" = 0 ] && echo "全部通过" || echo "有失败项，检查上方输出"
