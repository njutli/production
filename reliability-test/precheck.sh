#!/bin/bash
# precheck.sh — 框架级前置健康检查
#
# 用法：
#   ./precheck.sh          # 全部检查
#   ./precheck.sh --quick  # 快速版（ceph health + OSD up + JuiceFS mount）
#
# 输出 TAP 格式。全部通过返回 0，否则返回 1。

cd "$(dirname "$0")" || exit 1
source config/env.sh
source lib/cluster.sh

QUICK=false
[ "${1:-}" = "--quick" ] && QUICK=true

PASS=0; FAIL=0

pass() { echo "ok $((PASS + FAIL + 1)) - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok $((PASS + FAIL + 1)) - $1"; FAIL=$((FAIL + 1)); }
header() { echo "# $1"; }

echo "TAP version 13"
echo "# precheck $( [ "$QUICK" = true ] && echo '(quick)' || echo '(full)' )"

# --- 1. Ceph 集群健康 ---
header "Ceph"
HEALTH=$(get_ceph_health 2>/dev/null)
if echo "$HEALTH" | grep -qE "^HEALTH_(OK|WARN)"; then
    pass "ceph health: $(echo "$HEALTH" | head -c 20)"
else
    fail "ceph health: $(echo "$HEALTH" | head -c 40)"
fi

# --- 2. OSD 全部 up ---
OSD_UP=$(get_osd_count_up 2>/dev/null)
if [ "$OSD_UP" = "6" ]; then
    pass "OSD: 6/6 up"
else
    fail "OSD: ${OSD_UP:-?}/6 up (expected 6)"
fi

if [ "$QUICK" = true ]; then
    # Quick 模式只检查 JuiceFS mount
    header "JuiceFS"
    JFS=$(get_juicefs_status 2>/dev/null)
    [ "$JFS" = "mounted" ] && pass "JuiceFS: mounted" || fail "JuiceFS: ${JFS:-?}"
    echo "1..$((PASS + FAIL))"
    [ "$FAIL" = 0 ] && exit 0 || exit 1
fi

# --- 3. MON quorum ---
header "MON"
QUORUM=$(get_quorum_count 2>/dev/null)
if [ "$QUORUM" = "3" ]; then
    pass "MON quorum: 3/3"
else
    fail "MON quorum: ${QUORUM:-?}/3 (expected 3)"
fi

# --- 4. PG 状态 ---
header "PG"
PG=$(get_pg_states 2>/dev/null)
if echo "$PG" | grep -q "active"; then
    pass "PG: ${PG}"
else
    fail "PG: ${PG:-empty} (expected active)"
fi

# --- 5. PD / TiKV ---
header "PD/TiKV"
PD_HEALTH=$(get_pd_health 2>/dev/null)
if [ "$PD_HEALTH" = "3" ]; then
    pass "PD: 3/3 healthy"
else
    fail "PD: ${PD_HEALTH:-?}/3 healthy (expected 3)"
fi

TIKV_UP=$(get_tikv_store_count_up 2>/dev/null)
if [ "$TIKV_UP" = "3" ]; then
    pass "TiKV: 3/3 store Up"
else
    fail "TiKV: ${TIKV_UP:-?}/3 store Up (expected 3)"
fi

# --- 6. JuiceFS mount ---
header "JuiceFS"
JFS=$(get_juicefs_status 2>/dev/null)
[ "$JFS" = "mounted" ] && pass "JuiceFS: mounted" || fail "JuiceFS: ${JFS:-?}"

# --- 6.5 FUSE max_background（128 并发规格需要 >= 128）---
# max_background: 内核允许同时在途的异步 FUSE 请求数（writeback 脏页刷盘等）
# congestion_threshold: 在途请求超过此值时内核标记 BDI 拥塞，阻塞所有新 write()
# 128 并发 fio 的 writeback 会快速填满默认 50 个槽位（37 即触发拥塞）→ 故障期间请求卡死 → 永久拥塞
# max_background=512 = 128 并发 × 4 倍余量（每个 job 产生多个 writeback 请求，故障期间需容纳全部卡住请求）
# congestion_threshold=480 = max_background - 32，留 32 槽给突发请求
FUSE_BG=$(ssh_to_client "sudo bash -c 'cat /sys/fs/fuse/connections/*/max_background 2>/dev/null | head -1'" 2>/dev/null)
if [ -n "$FUSE_BG" ] && [ "$FUSE_BG" -lt 128 ] 2>/dev/null; then
    ssh_to_client "echo 512 | sudo tee /sys/fs/fuse/connections/*/max_background > /dev/null 2>&1; echo 480 | sudo tee /sys/fs/fuse/connections/*/congestion_threshold > /dev/null 2>&1" 2>/dev/null
    NEW_BG=$(ssh_to_client "sudo bash -c 'cat /sys/fs/fuse/connections/*/max_background 2>/dev/null | head -1'" 2>/dev/null)
    pass "FUSE max_background: ${FUSE_BG}→${NEW_BG}（已调大支持 128 并发）"
elif [ -n "$FUSE_BG" ]; then
    pass "FUSE max_background: ${FUSE_BG}（>= 128，满足 128 并发）"
else
    fail "FUSE max_background: 无法读取"
fi

# --- 7. SSH 可达性（全部节点）---
header "SSH"
ALL_OK=true
for ip in "${ALL_SERVERS[@]}"; do
    if _run "$ip" "true" 2>/dev/null; then
        pass "SSH: ${ip} reachable"
    else
        fail "SSH: ${ip} unreachable"
        ALL_OK=false
    fi
done

# --- 8. 必要工具（fio on 157, curl on slave）---
header "Tools"
if ssh_to_client "which fio >/dev/null 2>&1"; then
    pass "fio on 157"
else
    fail "fio not found on 157"
fi

if _run "${SLAVE_SERVERS[0]}" "which curl >/dev/null 2>&1"; then
    pass "curl on storage nodes"
else
    fail "curl not found on ${SLAVE_SERVERS[0]}"
fi

# --- 9. 残留故障检查 ---
header "Residual"
RESIDUAL=false
for ip in "${SLAVE_SERVERS[@]}"; do
    # 检查残留 iptables 规则（reliability 标记）
    RULES=$(_run "$ip" "sudo iptables-save 2>/dev/null | grep reliability" 2>/dev/null)
    if [ -n "$RULES" ]; then
        fail "残留 iptables on ${ip}: $(echo "$RULES" | head -1)"
        RESIDUAL=true
    fi
done
[ "$RESIDUAL" = false ] && pass "无残留 iptables 规则"

# 检查 noout 标记
NOOUT=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd dump 2>/dev/null | grep noout" 2>/dev/null)
if [ -n "$NOOUT" ]; then
    fail "ceph noout 标记残留: $NOOUT"
else
    pass "无 noout 残留"
fi

# --- 10. 网络口径（记录，不判 pass/fail）---
header "Network"
NET=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph config get mon public_network 2>/dev/null" 2>/dev/null)
echo "# 当前 Ceph public_network: ${NET:-unknown}"

# --- 结果 ---
TOTAL=$((PASS + FAIL))
echo "1..${TOTAL}"
echo "# Result: ${PASS}/${TOTAL} passed, ${FAIL} failed"

[ "$FAIL" = 0 ] && exit 0 || exit 1
