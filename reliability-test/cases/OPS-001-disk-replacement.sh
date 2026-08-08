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

_ORIG_MIN_SIZE=""

_restore_min_size() {
    if [ -n "$_ORIG_MIN_SIZE" ]; then
        _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd pool set juicefs-data min_size ${_ORIG_MIN_SIZE} 2>/dev/null" 2>/dev/null || true
        _ORIG_MIN_SIZE=""
    fi
}

trap 'ensure_osd_up "$OSD_B" 2>/dev/null; ensure_osd_up "$OSD_C" 2>/dev/null; _restore_min_size; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 获取 OSD 数据 LV 路径（通过 ceph osd metadata + dmsetup）
_get_osd_data_lv() {
    local osd_id=$1 node=$2
    local meta
    meta=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd metadata ${osd_id} 2>/dev/null" 2>/dev/null)
    echo "$meta" | grep 'bluestore_bdev_partition_path' | head -1 | awk -F'"' '{print $4}'
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
    # 2) 杀残留 docker 容器（集群用 docker 不是 podman）
    _run "$node" "sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'osd.*${osd_id}' | xargs -r sudo docker rm -f 2>/dev/null" 2>/dev/null || true
    # 3) purge（彻底从 OSD map 删除，含 destroy + crush rm + auth del + osd rm）
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd purge ${osd_id} --force 2>/dev/null" || true
    # 4) 删 cephadm spec
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph orch daemon rm osd.${osd_id} --force 2>/dev/null" || true
}

# 清除 LV 上的 ceph LVM 标签（dd 不清 LVM 标签，需 lvremove+lvcreate 重建）
_zap_lv() {
    local lv_path=$1 node=$2
    local dm_name mapper_path vg_lv size vg lv
    dm_name=$(_run "$node" "sudo dmsetup info --columns --noheadings -o name ${lv_path} 2>/dev/null" 2>/dev/null | tr -d ' ')
    if [ -n "$dm_name" ]; then
        mapper_path="/dev/mapper/${dm_name}"
        vg_lv=$(_run "$node" "sudo lvs --noheadings -o vg_name,lv_name --separator '/' ${mapper_path} 2>/dev/null | tr -d ' '" 2>/dev/null)
        if [ -n "$vg_lv" ]; then
            size=$(_run "$node" "sudo lvs --noheadings --units g -o lv_size ${mapper_path} 2>/dev/null | tr -d ' '" 2>/dev/null)
            vg=$(echo "$vg_lv" | cut -d/ -f1)
            lv=$(echo "$vg_lv" | cut -d/ -f2)
            _run "$node" "sudo lvremove -f ${vg}/${lv} 2>/dev/null; sudo lvcreate -y -L ${size} -n ${lv} ${vg} 2>/dev/null" 2>/dev/null
            echo "  LV 重建完成（清除 LVM ceph 标签）"
        else
            echo "  WARNING: 无法解析 VG/LV from ${mapper_path}"
        fi
    else
        echo "  WARNING: 无法获取 dm name from ${lv_path}"
    fi
    _run "$node" "sudo dd if=/dev/zero of=${lv_path} bs=1M count=10 2>/dev/null" 2>/dev/null || true
}

# 在节点上部署 OSD（通过 cephadm orch）
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

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
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
    echo "=== Phase 1: 销毁 OSD A + tmpfs 备用盘替代 ==="

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

    # 4) 在 NODE_A 上创建 tmpfs 备用盘（仅 data LV，不用 DB/WAL）
    _run "$NODE_A" "
        set -e
        sudo mkdir -p /tmp/osd-spare
        sudo mount -t tmpfs -o size=50G tmpfs /tmp/osd-spare
        sudo truncate -s 50G /tmp/osd-spare/spare.img
        spare_loop=\$(sudo losetup -f --show /tmp/osd-spare/spare.img)
        sudo pvcreate -ff -y \$spare_loop 2>/dev/null || true
        sudo vgcreate ceph-vg-spare \$spare_loop 2>/dev/null || true
        sudo lvcreate -y -l 100%FREE -n osd ceph-vg-spare
        echo '  tmpfs 备用盘准备完成'
    " 2>/dev/null

    # 5) 部署新 OSD（仅 data，不用 DB/WAL——tmpfs 备用盘不需要优化）
    _deploy_osd "$HOST_A" "/dev/ceph-vg-spare/osd"

    echo "  等待新 OSD 启动 + EC 恢复..."
    sleep 30

    # 6) 等待 OSD 恢复 + 所有 PG clean
    assert_wait_eq get_osd_count_up "6" 120 "备用盘加入后 6/6 OSD up"
    assert_pg_state_contains "active+clean" 600 "PG 恢复 active+clean（EC 恢复到备用盘）"

    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（备用盘恢复后 md5 匹配）"

    echo "=== Phase 1 完成：备用盘已加入集群 ==="

    # 等 EC 完全恢复后再注入下一个故障（backfill 未完成时叠加故障会导致 PG peering 卡住）
    assert_wait_match get_ceph_health "HEALTH_OK" 1800 "Phase 1 后集群完全恢复 HEALTH_OK"

    # 验证备用盘 OSD 有数据（kb_used > 0，HEALTH_OK = PG active+clean 数据已完整同步）
    local osd_df spare_kb=0
    osd_df=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd df --format json 2>/dev/null | sed -n '/^{/,\$p'" 2>/dev/null)
    spare_kb=$(echo "$osd_df" | jq --argjson osd "$OSD_A" '.nodes[] | select(.id == $osd) | .kb_used' 2>/dev/null)
    assert_gt "$spare_kb" "0" "备用盘 OSD ${OSD_A} 已有数据（${spare_kb} KB used，HEALTH_OK = 数据完整同步）"

    # 验证备用盘已在所有 pool 63 PG 的 acting set 中（HEALTH_OK 只保证 5 OSD active+clean，
    # 不保证第 6 个 OSD 已完成 backfill 加入 acting set。Phase 2 kill 2 OSD 后，如果备用盘
    # 不在 acting set 中，acting set 只剩 3 OSD < min_size=4 → PG down → I/O error）
    echo "#  等待备用盘 OSD ${OSD_A} 完成所有 PG backfill（加入 acting set）..."
    local _acting_wait=0 _pg_unclean="init"
    while [ "$_acting_wait" -lt 600 ]; do
        _pg_unclean=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph pg ls 2>/dev/null" 2>/dev/null | grep "^63" | grep -v "active+clean" | head -1)
        [ -z "$_pg_unclean" ] && break
        echo "#  pool 63 仍有未 clean PG，等待 backfill...（${_acting_wait}s）"
        sleep 30
        _acting_wait=$((_acting_wait + 30))
    done
    local _acting_ok="yes"
    [ -n "$_pg_unclean" ] && _acting_ok="no"
    assert_eq "$_acting_ok" "yes" "备用盘已加入所有 pool 63 PG acting set（PG 全部 active+clean，等待 ${_acting_wait}s）"
}

# ============================================================
# Phase 2：临时降 min_size + SIGKILL B+C，验证备用盘生效
# down 2 个非备用盘 OSD → 剩 4 个（含备用盘）→ 读需 k=4 → 必须读到备用盘 chunk
# ============================================================
phase2_verify_spare() {
    echo ""
    echo "=== Phase 2: SIGKILL OSD B+C，验证备用盘生效 ==="

    # 1) 临时降 min_size 到 4（默认 k=4，down 2 剩 4 >= 4 → PG active）
    _ORIG_MIN_SIZE=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd pool get juicefs-data min_size --format json 2>/dev/null | sed -n '/^{/,\$p'" 2>/dev/null | jq -r '.min_size' 2>/dev/null)
    echo "# 当前 min_size=${_ORIG_MIN_SIZE}，临时降为 4"
    _run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd pool set juicefs-data min_size 4 2>&1" 2>/dev/null
    local _verify_min_size
    _verify_min_size=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd pool get juicefs-data min_size 2>/dev/null" 2>/dev/null | awk '{print $2}')
    assert_eq "$_verify_min_size" "4" "min_size 已临时降为 4（原值 ${_ORIG_MIN_SIZE}）"

    # 2) SIGKILL OSD B 和 C（stop_osd 使用 systemctl stop + docker kill，cephadm 不会重启）
    stop_osd "$OSD_B"
    stop_osd "$OSD_C"
    # 等 OSD 心跳超时（osd_heartbeat_grace=20s）+ peering 完成
    echo "# 等待 OSD 心跳超时 + PG peering..."
    sleep 30

    # 3) 验证 OSD B+C down → PG degraded
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
# Phase 3：恢复 OSD B+C + 恢复 min_size + 最终验证
# ============================================================
phase3_recover_and_verify() {
    echo ""
    echo "=== Phase 3: 恢复 OSD B+C + 恢复 min_size ==="

    # 1) 启动 OSD B 和 C
    start_osd "$OSD_B"
    start_osd "$OSD_C"

    assert_pg_state_contains "active+clean" 600 "PG 恢复 active+clean"
    assert_wait_eq get_osd_count_up "6" 60 "6/6 OSD up"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康（非 ERR）"

    # 2) 恢复 min_size 到原值
    _restore_min_size
    echo "# min_size 已恢复为 ${_ORIG_MIN_SIZE:-5}"
    _ORIG_MIN_SIZE=""

    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local md5
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（最终 md5 匹配）"

    echo "=== Phase 3 完成 ==="
}

# ============================================================
# Phase 4：恢复 OSD A 到原始物理盘 + 最终验证
# ============================================================
phase4_restore_osd_a() {
    echo ""
    echo "=== Phase 4: 恢复 OSD A 到原始物理盘 ==="

    # 1) 找到并销毁 tmpfs 备用盘 OSD
    local osd_tree osd_ids spare_osd=""
    osd_tree=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd tree --format json 2>/dev/null" 2>/dev/null)
    osd_ids=$(echo "$osd_tree" | jq -r --arg host "$HOST_A" \
        '.nodes[] | select(.type == "host" and .name == $host) | .children[]' 2>/dev/null)

    for sid in $osd_ids; do
        local meta dm_path lv_name
        meta=$(_run "${CEPH_PRIMARY}" "sudo cephadm shell -- ceph osd metadata ${sid} 2>/dev/null" 2>/dev/null)
        dm_path=$(echo "$meta" | grep 'bluestore_bdev_partition_path' | head -1 | awk -F'"' '{print $4}')
        lv_name=$(_run "$NODE_A" "sudo dmsetup info --columns --noheadings -o name ${dm_path} 2>/dev/null" 2>/dev/null)
        if echo "$lv_name" | grep -q "spare"; then
            spare_osd="$sid"
            break
        fi
    done

    if [ -n "$spare_osd" ]; then
        _destroy_osd "$spare_osd" "$NODE_A"
        echo "  备用盘 OSD ${spare_osd} 已销毁"
    else
        echo "  WARNING: 未找到备用盘 OSD，跳过销毁"
    fi

    # 2) 清理 tmpfs 备用盘 LVM + 文件
    _run "$NODE_A" "
        sudo lvremove -f ceph-vg-spare/osd 2>/dev/null || true
        sudo vgremove -f ceph-vg-spare 2>/dev/null || true
        for loop in \$(sudo losetup -l --noheadings 2>/dev/null | grep 'spare' | awk '{print \$1}'); do
            sudo losetup -d \$loop 2>/dev/null || true
        done
        sudo umount /tmp/osd-spare 2>/dev/null || true
        sudo rm -rf /tmp/osd-spare
        echo '  tmpfs 备用盘已清理'
    " 2>/dev/null

    # 3) 恢复原始 LV
    _run "$NODE_A" "sudo dmsetup resume ${LV_A} 2>/dev/null" 2>/dev/null || true

    # 4) 在原始 LV 上重建 OSD
    _run "$NODE_A" "sudo dmsetup resume ${LV_A} 2>/dev/null" 2>/dev/null || true
    if [ -n "${spare_osd:-}" ]; then
        _run "$NODE_A" "sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'osd-${spare_osd}\$' | xargs -r sudo docker rm -f 2>/dev/null" 2>/dev/null || true
    fi
    sleep 2

    # zap 清除 ceph LVM 标签
    _zap_lv "$LV_A" "$NODE_A"

    # 获取 LV 路径（zap 后可能重建了 LV，需要重新获取）
    local rebuild_lv
    rebuild_lv=$(_run "$NODE_A" \
        "sudo lvs ceph-vg-ceph-node1 --noheadings -o lv_path 2>/dev/null | grep -vE 'tikv|osd_fresh|osd_second' | head -1 | tr -d ' '" \
        2>/dev/null)
    if [ -z "$rebuild_lv" ]; then
        rebuild_lv="/dev/ceph-vg-ceph-node1/osd_rebuild"
        _run "$NODE_A" "sudo lvcreate -y -L 300G -n osd_rebuild ceph-vg-ceph-node1 2>/dev/null" 2>/dev/null
    fi
    _run "$NODE_A" "sudo dd if=/dev/zero of=${rebuild_lv} bs=1M count=10 2>/dev/null" 2>/dev/null || true

    _deploy_osd "$HOST_A" "$rebuild_lv"

    echo "  等待 OSD A 重建 + EC 恢复..."
    sleep 30

    assert_wait_eq get_osd_count_up "6" 120 "OSD A 重建后 6/6 OSD up"
    assert_pg_state_contains "active+clean" 600 "PG 恢复 active+clean（OSD A 重建后）"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群恢复健康"

    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local md5
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null" 2>/dev/null
    md5=$(timeout 30 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} "${SSH_USER}@${CLIENT_SERVER}" "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（OSD A 重建后 md5 匹配）"

    echo "=== Phase 4 完成：OSD A 已在原始物理盘上重建 ==="
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    ensure_osd_up "$OSD_B" 2>/dev/null || true
    ensure_osd_up "$OSD_C" 2>/dev/null || true
    _restore_min_size
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
    phase4_restore_osd_a
    teardown
}
main "$@"
