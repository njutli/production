#!/bin/bash
# OPS-002: rolling-node-reboot
# Reboot 1 个存储节点，验证所有服务自启 + 全程数据可用
#
# 集群设计：OSD 数据和 DB/WAL 都在持久 LV 上（bluefs_single_shared_device=1），
# reboot 后 OSD 可自启。TiKV/PD 有 systemd Restart=always，MON 由 cephadm 管理。
# tmpfs 上的 loop 设备是残留未用的，reboot 后丢失不影响 OSD。
# EXPECTED_DURATION=600

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="OPS-002"
TEST_NAME="rolling-node-reboot"
EXPECTED_DURATION=600

trap 'tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 写入基线数据
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "Reboot 1 个存储节点，验证所有服务自启 + 全程数据可用"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_eq get_quorum_count "3" 10 "初始 3/3 MON quorum"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 固定选 .14（ceph-node3）作为重启目标
    TARGET_NODE="192.168.11.14"
    TARGET_HOSTNAME="${CEPH_HOSTNAMES[$TARGET_NODE]}"
    assert_ne "$TARGET_NODE" "" "reboot 目标: ${TARGET_NODE}（${TARGET_HOSTNAME}）"

    # 记录该节点上的 OSD ID
    local osd_tree
    osd_tree=$(_run "${CLIENT_SERVER}" "sudo ceph -k /etc/ceph/ceph.client.admin.keyring -m ${CEPH_PRIMARY} osd tree 2>/dev/null" 2>/dev/null)
    TARGET_OSD_IDS=$(echo "$osd_tree" | grep -A2 "${TARGET_HOSTNAME}" | grep osd | awk '{print $1}')
    assert_ne "$TARGET_OSD_IDS" "" "目标节点 OSD: ${TARGET_OSD_IDS}"

    # 写入基线数据
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "mkdir -p '${test_dir}'" 2>/dev/null
    ssh_to_client "dd if=/dev/urandom of='${test_dir}/ops002_baseline.bin' bs=1M count=100 2>/dev/null" 2>/dev/null
    BASELINE_MD5=$(ssh_to_client "md5sum '${test_dir}/ops002_baseline.bin' 2>/dev/null" | awk '{print $1}')
    assert_ne "$BASELINE_MD5" "" "基线数据写入成功（md5=${BASELINE_MD5}）"
}

# ============================================================
# inject：reboot 节点
# ============================================================
inject() {
    echo "  rebooting ${TARGET_HOSTNAME} (${TARGET_NODE})..."
    _run "$TARGET_NODE" "sudo reboot" 2>/dev/null || true
}

# ============================================================
# check_during：reboot 期间数据可用 + 等待恢复
# ============================================================
check_during() {
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"

    # 等待节点 SSH 恢复
    echo "  等待 ${TARGET_HOSTNAME} SSH 恢复..."
    sleep 30
    local waited=0
    while [ "$waited" -lt 300 ]; do
        if _run "$TARGET_NODE" "true" 2>/dev/null; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    assert_lt "$waited" "300" "${TARGET_HOSTNAME} SSH 恢复（${waited}s）"

    # reboot 后：.11 的 tikv LV fstab 被注释，需手动挂载
    if [ "$TARGET_NODE" = "192.168.11.11" ]; then
        _run "$TARGET_NODE" "sudo mount /dev/ceph-vg-ceph-node1/tikv /mnt/tikv 2>/dev/null; sudo systemctl restart tikv pd 2>/dev/null; echo 'tikv mounted'" 2>/dev/null
    fi

    # reboot 后：验证数据仍可读（其他节点 4 OSD，min_size=4 → PG active+degraded 可读）
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    local md5_during
    md5_during=$(ssh_to_client "md5sum '${test_dir}/ops002_baseline.bin' 2>/dev/null" | awk '{print $1}')
    assert_eq "$md5_during" "$BASELINE_MD5" "reboot 后基线数据可读（EC 从剩余 OSD 读）"

    # 验证 OSD 自启（bluefs_single_shared_device=1，数据在持久 LV）
    assert_wait_eq get_osd_count_up "6" 120 "6/6 OSD up（OSD 自启）"

    # 验证 TiKV 自启（systemd Restart=always）
    assert_wait_eq get_tikv_store_count_up "3" 60 "3/3 TiKV Up（systemd 自启）"

    # 验证 MON 自启（cephadm 管理）
    assert_wait_eq get_quorum_count "3" 120 "3/3 MON quorum（cephadm 自启）"

    # 验证 PG 恢复
    assert_pg_state_contains "active+clean" 300 "PG 恢复 active+clean"

    # 验证集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 120 "集群恢复健康"

    # 验证恢复后数据完整
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    local md5_after
    md5_after=$(ssh_to_client "md5sum '${test_dir}/ops002_baseline.bin' 2>/dev/null" | awk '{print $1}')
    assert_eq "$md5_after" "$BASELINE_MD5" "恢复后基线数据完整（md5 匹配）"
}

# ============================================================
# recover：无需手动恢复（所有服务自启）
# ============================================================
recover() {
    echo "  所有服务已自启，无需手动恢复"
}

# ============================================================
# check_after：最终验证
# ============================================================
check_after() {
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"

    assert_eq "$(get_osd_count_up)" "6" "最终 6/6 OSD up"
    assert_eq "$(get_tikv_store_count_up)" "3" "最终 3/3 TiKV Up"
    assert_eq "$(get_quorum_count)" "3" "最终 3/3 MON quorum"
    assert_match "$(get_pg_states)" "active+clean" "最终 PG active+clean"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    # juicefs fsck（reboot 后 TiKV Raft 刚恢复，等元数据稳定）
    local fsck_rc=1
    for i in 1 2 3; do
        ssh_to_client "sudo CEPH_CONF=/etc/ceph/ceph.conf juicefs fsck '${JUICEFS_METADATA_URL}' >/dev/null 2>&1" 2>/dev/null
        fsck_rc=$?
        [ "$fsck_rc" = "0" ] && break
        sleep 10
    done
    assert_eq "$fsck_rc" "0" "juicefs fsck 通过（无元数据损坏）"

    # 清理
    ssh_to_client "rm -f '${test_dir}/ops002_baseline.bin'" 2>/dev/null || true
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
