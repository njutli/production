#!/bin/bash
# OPS-001: disk-replacement
# 磁盘故障换盘重建：销毁 OSD A → tmpfs 备用盘替代 → 验证备用盘有数据 → down 2 OSD 验证备用盘生效
# EXPECTED_DURATION=1200

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="OPS-001"
TEST_NAME="disk-replacement"
EXPECTED_DURATION=1200

trap 'ensure_osd_up "$OSD_B" 2>/dev/null; ensure_osd_up "$OSD_C" 2>/dev/null; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 获取 OSD 数据 LV 路径（ceph osd metadata → dm 路径 → mapper → lvs → LV 路径）
_get_osd_data_lv() {
    local osd_id=$1 node=$2
    local meta dm_path dm_dev mapper_name lv_path
    meta=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd metadata ${osd_id} 2>/dev/null" 2>/dev/null)
    dm_path=$(echo "$meta" | grep 'bluestore_bdev_partition_path' | head -1 | awk -F'"' '{print $4}')
    [ -z "$dm_path" ] && return 1
    dm_dev=$(basename "$dm_path")  # e.g., "dm-1"
    # Resolve: ls /dev/mapper/ → find symlink → dm device → get mapper name → lvs → VG/LV
    mapper_name=$(_run "$node" "ls -la /dev/mapper/ 2>/dev/null | grep '${dm_dev}' | head -1 | awk '{print \$9}'" 2>/dev/null | tr -d ' ')
    if [ -n "$mapper_name" ]; then
        lv_path=$(_run "$node" "sudo lvs --noheadings -o vg_name,lv_name --separator '/' /dev/mapper/${mapper_name} 2>/dev/null | tr -d ' '" 2>/dev/null)
        if [ -n "$lv_path" ]; then
            echo "/dev/${lv_path}"
            return 0
        fi
    fi
    echo "$dm_path"
}

# 在目标节点上停止 OSD 守护进程（防止 cephadm 自动重启）
_stop_osd_via_cephadm() {
    local osd_id=$1
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon stop osd.${osd_id} 2>/dev/null" || true
}

# 在目标节点上启动 OSD 守护进程
_start_osd_via_cephadm() {
    local osd_id=$1
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon start osd.${osd_id} 2>/dev/null" || true
}

# 完全销毁 OSD（purge 彻底从 OSD map 删除，避免 ID 回用导致 auth keyring 冲突）
_destroy_osd() {
    local osd_id=$1 node=$2
    # 1) 停止 OSD
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon stop osd.${osd_id} 2>/dev/null" || true
    sleep 3
    # 2) 杀残留 podman 容器（集群用 podman）
    _run "$node" "sudo podman ps -a --format '{{.Names}}' 2>/dev/null | grep 'osd.*${osd_id}' | xargs -r sudo podman rm -f 2>/dev/null" 2>/dev/null || true
    # 3) purge（彻底从 OSD map 删除，含 destroy + crush rm + auth del + osd rm）
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd purge ${osd_id} --force 2>/dev/null" || true
    # 4) 删 cephadm spec
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon rm osd.${osd_id} --force 2>/dev/null" || true
}

# 重建 LV（lvremove+lvcreate 清除 ceph LVM 标签，wipefs 不清 LVM 标签）
_zap_lv() {
    local lv_path=$1 node=$2
    local vg_lv size vg lv
    # Parse VG/LV from path like /dev/ceph-vg-ceph-node1/osd_2
    vg_lv=$(echo "$lv_path" | sed 's|^/dev/||')
    vg=$(echo "$vg_lv" | cut -d/ -f1)
    lv=$(echo "$vg_lv" | cut -d/ -f2)
    if [ -n "$vg" ] && [ -n "$lv" ]; then
        size=$(_run "$node" "sudo lvs --noheadings --units g -o lv_size ${lv_path} 2>/dev/null | tr -d ' '" 2>/dev/null)
        _run "$node" "sudo lvremove -f ${vg}/${lv} 2>/dev/null; sudo lvcreate -y -L ${size} -n ${lv} ${vg} 2>/dev/null" 2>/dev/null
        echo "  LV 重建完成（清除 LVM ceph 标签）"
    else
        echo "  WARNING: 无法解析 VG/LV from ${lv_path}"
    fi
    _run "$node" "sudo dd if=/dev/zero of=${lv_path} bs=1M count=10 2>/dev/null" 2>/dev/null || true
}

# 在节点上部署 OSD（用 ceph orch daemon add；ceph-volume lvm create 会扫描所有 VG 的旧 OSD 元数据并销毁 LV）
_deploy_osd() {
    local hostname=$1 data_lv=$2
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon add osd ${hostname}:${data_lv} 2>&1" 2>/dev/null
}

# ============================================================
# setup：前置检查 + 写入基线数据 + 选择三个目标 OSD
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "磁盘故障换盘重建：销毁 OSD A → tmpfs 备用盘替代 → down 2 OSD 验证备用盘生效"

    # 确保所有 OSD 都是 started 状态（上次测试可能残留 stopped）
    local _osd_ids
    _osd_ids=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd ls 2>/dev/null" 2>/dev/null)
    for _oid in $_osd_ids; do
        _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon start osd.${_oid} 2>/dev/null" 2>/dev/null || true
    done

    # 加速 backfill（ceph config set 在 Quincy 不生效，用 injectargs 直接注入 OSD）
    _run "${CEPH_PRIMARY}" 'sudo cephadm shell -- ceph tell "osd.*" injectargs "--osd-max-backfills 8 --osd-recovery-sleep 0"' 2>/dev/null || true

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 30 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 写入基线数据（100MB + md5sum）
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "mkdir -p '${test_dir}'" 2>/dev/null
    ssh_to_client "dd if=/dev/urandom of='${test_dir}/baseline.bin' bs=1M count=100 2>/dev/null" 2>/dev/null
    BASELINE_MD5=$(ssh_to_client "md5sum '${test_dir}/baseline.bin'" 2>/dev/null | awk '{print $1}')
    assert_ne "$BASELINE_MD5" "" "基线数据写入成功 (md5=${BASELINE_MD5:0:16}...)"

    # 选择 OSD A（要被替换的）和 OSD B/C（用来验证备用盘）
    # A 在 .11，B 在 .13，C 在 .14——不同节点
    local node_a="${SLAVE_SERVERS[0]}"
    local node_b="${SLAVE_SERVERS[1]}"
    local node_c="${SLAVE_SERVERS[2]}"
    OSD_A=$(pick_osd_on_node "$node_a")
    OSD_B=$(pick_osd_on_node "$node_b")
    OSD_C=$(pick_osd_on_node "$node_c")
    assert_ne "$OSD_A" "" "OSD A（将被替换）: ${OSD_A} on ${node_a}"
    assert_ne "$OSD_B" "" "OSD B（验证用）: ${OSD_B} on ${node_b}"
    assert_ne "$OSD_C" "" "OSD C（验证用）: ${OSD_C} on ${node_c}"

    NODE_A="$node_a"
    NODE_B="$node_b"
    NODE_C="$node_c"
    HOST_A="${CEPH_HOSTNAMES[$NODE_A]}"
    HOST_B="${CEPH_HOSTNAMES[$NODE_B]}"
    HOST_C="${CEPH_HOSTNAMES[$NODE_C]}"
    LV_A=$(_get_osd_data_lv "$OSD_A" "$NODE_A")
    assert_ne "$LV_A" "" "OSD A 数据 LV: ${LV_A}"

    echo "# OSD A=${OSD_A} on ${NODE_A} (${LV_A}) — 将被销毁替换"
    echo "# OSD B=${OSD_B} on ${NODE_B} — 将 SIGKILL 验证备用盘"
    echo "# OSD C=${OSD_C} on ${NODE_C} — 将 SIGKILL 验证备用盘"
}

# ============================================================
# Phase 1：销毁 OSD A + tmpfs 备用盘替代
# ============================================================
phase1_destroy_and_replace() {
    echo ""
    echo "=== Phase 1: 销毁 OSD A + 原盘重建 ==="

    # 1) 停止 OSD A（通过 cephadm，防止自动重启）
    _stop_osd_via_cephadm "$OSD_A"
    sleep 5

    # 2) 验证集群容错
    assert_wait_eq get_osd_count_up "5" 30 "OSD A down: 5/6 OSD up"
    assert_pg_state_contains "degraded" 35 "PG degraded（OSD A 故障）"

    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local md5
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据可读（EC 容忍，md5 匹配）"

    # 3) 完全销毁 OSD A（从 Ceph + cephadm 移除）
    _destroy_osd "$OSD_A" "$NODE_A"

    # 4) 重建 LV（清除 ceph LVM 标签）+ 在原盘重建 OSD
    _zap_lv "$LV_A" "$NODE_A"
    _deploy_osd "$HOST_A" "$LV_A"

    echo "  等待新 OSD 启动 + EC 恢复..."
    sleep 30

    # 5) 等待 OSD 恢复 + 所有 PG clean
    assert_wait_eq get_osd_count_up "6" 120 "OSD 重建后 6/6 OSD up"
    assert_pg_state_contains "active+clean" 600 "PG 恢复 active+clean（EC 恢复到重建 OSD）"

    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（OSD 重建后 md5 匹配）"

    echo "=== Phase 1 完成：OSD A 已在原盘重建 ==="

    # 等 EC 完全恢复后再注入下一个故障
    assert_pg_state_contains "active+clean" 1800 "Phase 1 后 PG 全部 active+clean（EC 恢复完成）"

    # 验证重建 OSD 有数据
    local osd_df spare_kb=0
    osd_df=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd df --format json 2>/dev/null | sed -n '/^{/,\$p'" 2>/dev/null)
    spare_kb=$(echo "$osd_df" | jq --argjson osd "$OSD_A" '.nodes[] | select(.id == $osd) | .kb_used' 2>/dev/null)
    assert_gt "$spare_kb" "0" "重建 OSD ${OSD_A} 已有数据（${spare_kb} KB used）"

    # 等待 OSD 加入所有 pool 63 PG acting set
    echo "#  等待 OSD ${OSD_A} 完成所有 PG backfill（加入 acting set）..."
    local _acting_wait=0 _pg_unclean="init"
    while [ "$_acting_wait" -lt 3600 ]; do
        _pg_unclean=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph pg ls 2>/dev/null" 2>/dev/null | grep "^63" | grep -v "active+clean" | head -1)
        [ -z "$_pg_unclean" ] && break
        echo "#  pool 63 仍有未 clean PG，等待 backfill...（${_acting_wait}s）"
        sleep 30
        _acting_wait=$((_acting_wait + 30))
    done
    local _acting_ok="yes"
    [ -n "$_pg_unclean" ] && _acting_ok="no"
    assert_eq "$_acting_ok" "yes" "OSD 已加入所有 pool 63 PG acting set（PG 全部 active+clean，等待 ${_acting_wait}s）"
}

# ============================================================
# Phase 2：SIGKILL B+C，验证备用盘生效
# down 2 个非备用盘 OSD → 剩 4 个（含备用盘）→ 读需 k=4 → 必须读到备用盘 chunk
# min_size=4，4 OSD ≥ 4 → PG active+degraded 可读
# ============================================================
phase2_verify_spare() {
    echo ""
    echo "=== Phase 2: SIGKILL OSD B+C，验证备用盘生效 ==="

    # 1) SIGKILL OSD B 和 C（stop_osd 使用 systemctl stop + docker kill，cephadm 不会重启）
    stop_osd "$OSD_B"
    stop_osd "$OSD_C"
    # 等 OSD 心跳超时（osd_heartbeat_grace=20s）+ peering 完成
    echo "# 等待 OSD 心跳超时 + PG peering..."
    sleep 30

    # 2) 验证 OSD B+C down → PG degraded
    assert_pg_state_contains "degraded" 30 "PG 进入 degraded（OSD B+C SIGKILL 后 peering）"
    assert_wait_eq get_osd_count_up "4" 30 "4/6 OSD up（OSD B+C down）"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（min_size=4，4 >= 4 可读）"

    # 核心断言：基线数据可读
    # 4 个 OSD 剩余（含备用盘），读需 k=4 → 必须读到备用盘 chunk → 证明备用盘有数据
    # 1GB 文件在 2 OSD down（EC 重建读）下较慢，给 300s 超时
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local md5
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 300 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据可读（备用盘生效，4 OSD 刚好 k=4，md5 匹配）"

    echo "=== Phase 2 完成：备用盘验证通过 ==="
}

# ============================================================
# Phase 3：恢复 OSD B+C + 最终验证
# ============================================================
phase3_recover_and_verify() {
    echo ""
    echo "=== Phase 3: 恢复 OSD B+C ==="

    # 1) 启动 OSD B 和 C
    start_osd "$OSD_B"
    start_osd "$OSD_C"

    assert_pg_state_contains "active+clean" 600 "PG 恢复 active+clean"
    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local md5
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（最终 md5 匹配）"

    echo "=== Phase 3 完成 ==="
}

# ============================================================
# Phase 4：最终验证（OSD 已在原盘，无需重建）
# ============================================================
phase4_final_verify() {
    echo ""
    echo "=== Phase 4: 最终验证 ==="

    assert_wait_eq get_osd_count_up "6" 120 "最终 6/6 OSD up"
    assert_pg_state_contains "active+clean" 600 "PG 恢复 active+clean"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康"

    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local md5
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（最终 md5 匹配）"

    echo "=== Phase 4 完成 ==="
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    ensure_osd_up "$OSD_B" 2>/dev/null || true
    ensure_osd_up "$OSD_C" 2>/dev/null || true
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "timeout 10 rm -f '${test_dir}/baseline.bin'" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() {
    setup
    phase1_destroy_and_replace
    phase2_verify_spare
    phase3_recover_and_verify
    phase4_final_verify
    teardown
}
main "$@"
