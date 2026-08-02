#!/bin/bash
# OPS-002: rolling-node-reboot
# 逐节点 reboot（tmpfs 丢失 = OSD 重建），验证全程数据可用、重建可重复
# ⚠️ 暂不执行（需 reboot 节点，影响大）
# EXPECTED_DURATION=1800

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="OPS-002"
TEST_NAME="rolling-node-reboot"
EXPECTED_DURATION=1800

trap 'tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 获取 OSD 数据 LV 路径
_get_osd_data_lv() {
    local osd_id=$1 node=$2
    local cv_output
    cv_output=$(_run "$node" "sudo ceph-volume lvm list osd.${osd_id} 2>/dev/null" 2>/dev/null)
    echo "$cv_output" | grep '\[block\]' | head -1 | awk '{print $2}'
}

# 等待节点 SSH 恢复
_wait_node_ssh() {
    local ip=$1 max_wait=${2:-120}
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if _run "$ip" "true" 2>/dev/null; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# 在节点上重建所有 OSD（tmpfs 丢失后）
_rebuild_osds_on_node() {
    local ip=$1
    local hostname="${CEPH_HOSTNAMES[$ip]}"
    local dbwal_mnt="${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}"
    local db_size="${CEPH_DB_SIZE:-40G}"
    local wal_size="${CEPH_WAL_SIZE:-10G}"
    local tmpfs_size="${CEPH_DB_WAL_TMPFS_SIZE:-200G}"

    # 找到该节点上的 OSD ID 和数据设备
    local osd_ids
    osd_ids=$(ssh_to_client \
        "sudo cephadm shell -- ceph osd tree 2>/dev/null | grep '${hostname}' -A2 | grep osd | awk '{print \$1}'" \
        2>/dev/null)

    # 销毁旧 OSD
    for osd_id in $osd_ids; do
        ssh_to_client \
            "sudo ceph osd destroy ${osd_id} --yes-i-really-really-mean-it 2>/dev/null" 2>/dev/null || true
        ssh_to_client "sudo ceph osd crush remove osd.${osd_id} 2>/dev/null" 2>/dev/null || true
        ssh_to_client "sudo ceph auth del osd.${osd_id} 2>/dev/null" 2>/dev/null || true
    done

    # 清理旧 LVM/dm/loop
    _run "$ip" "
        for loop in \$(sudo losetup -l --noheadings 2>/dev/null | awk '{print \$1}'); do
            sudo losetup -d \$loop 2>/dev/null || true
        done
        for lv in \$(sudo lvs --noheadings 2>/dev/null | awk '{print \$2\"/\"\$1}'); do
            sudo lvremove -f \$lv 2>/dev/null || true
        done
        for vg in \$(sudo vgs --noheadings 2>/dev/null | awk '{print \$1}'); do
            sudo vgremove --force \$vg 2>/dev/null || true
        done
        for pv in \$(sudo pvs --no-headings 2>/dev/null | awk '{print \$1}'); do
            sudo pvremove --force \$pv 2>/dev/null || true
        done
        sudo dmsetup remove_all --force 2>/dev/null || true
        sudo umount ${dbwal_mnt} 2>/dev/null || true
        sudo mkdir -p ${dbwal_mnt}
        sudo mount -t tmpfs -o size=${tmpfs_size} tmpfs ${dbwal_mnt}
        echo '  清理+tmpfs 完成'
    " 2>/dev/null

    # 重建每个 OSD
    local seq=0
    for osd_id in $osd_ids; do
        seq=$((seq + 1))
        local dev
        # 交替使用 nvme2n1 和 nvme3n1
        if [ "$seq" = 1 ]; then
            dev="/dev/nvme2n1"
        else
            dev="/dev/nvme3n1"
        fi

        # 擦除数据盘
        _run "$ip" "sudo wipefs -af ${dev} 2>/dev/null; sudo sgdisk --zap-all ${dev} 2>/dev/null; sudo dd if=/dev/zero of=${dev} bs=1M count=100 oflag=direct 2>/dev/null; sudo partprobe 2>/dev/null" 2>/dev/null

        # 创建 DB/WAL + DATA LV
        _run "$ip" "
            set -e
            sudo truncate -s ${db_size} ${dbwal_mnt}/db-osd${seq}.img
            sudo truncate -s ${wal_size} ${dbwal_mnt}/wal-osd${seq}.img
            db_loop=\$(sudo losetup -f --show ${dbwal_mnt}/db-osd${seq}.img)
            wal_loop=\$(sudo losetup -f --show ${dbwal_mnt}/wal-osd${seq}.img)
            sudo pvcreate -ff -y \$db_loop 2>/dev/null || true
            sudo vgcreate ceph-vg-db${seq} \$db_loop 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd-db ceph-vg-db${seq}
            sudo pvcreate -ff -y \$wal_loop 2>/dev/null || true
            sudo vgcreate ceph-vg-wal${seq} \$wal_loop 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd-wal ceph-vg-wal${seq}
            sudo pvcreate -ff -y ${dev} 2>/dev/null || true
            sudo vgcreate ceph-vg-osd${seq} ${dev} 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd ceph-vg-osd${seq}
        " 2>/dev/null

        # 部署 OSD
        ssh_to_client \
            "sudo ceph orch daemon add osd ${hostname}:data_devices=/dev/ceph-vg-osd${seq}/osd,db_devices=/dev/ceph-vg-db${seq}/osd-db,wal_devices=/dev/ceph-vg-wal${seq}/osd-wal 2>&1" \
            2>/dev/null
        sleep 5
    done

    # activate + start
    _run "$ip" "sudo ceph-volume lvm activate --all 2>/dev/null || true" 2>/dev/null
    _run "$ip" "
        for osd_dir in /var/lib/ceph/osd/ceph-*; do
            [ -d \"\$osd_dir\" ] || continue
            osd_id=\$(basename \"\$osd_dir\" | sed 's/ceph-//')
            sudo systemctl reset-failed ceph-osd@\$osd_id 2>/dev/null || true
            sudo systemctl start ceph-osd@\$osd_id 2>/dev/null || true
        done
    " 2>/dev/null
}

# ============================================================
# setup：前置检查 + 写入基线数据
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "逐节点 reboot（tmpfs 丢失=OSD 重建），验证全程数据可用、重建可重复"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    # 写入基线数据
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "mkdir -p '${test_dir}'" 2>/dev/null
    ssh_to_client "dd if=/dev/urandom of='${test_dir}/baseline.bin' bs=1M count=100 2>/dev/null" 2>/dev/null
    BASELINE_MD5=$(ssh_to_client "md5sum '${test_dir}/baseline.bin'" 2>/dev/null | awk '{print $1}')
    assert_ne "$BASELINE_MD5" "" "基线数据写入成功"

    echo "# 将逐节点 reboot: ${SLAVE_SERVERS[*]}"
}

# ============================================================
# 逐节点处理：每个节点 reboot → 等待恢复 → 重建 OSD → 验证
# ============================================================
run_rolling_reboot() {
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"

    for ip in "${SLAVE_SERVERS[@]}"; do
        local hostname="${CEPH_HOSTNAMES[$ip]}"
        echo ""
        echo "=== 节点 ${hostname} (${ip}) ==="

        # 1. reboot 前：验证基线数据可读
        local md5_before
        md5_before=$(ssh_to_client "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
        assert_eq "$md5_before" "$BASELINE_MD5" "${hostname} reboot 前基线数据可读"

        # 2. reboot 节点
        echo "  rebooting ${hostname}..."
        _run "$ip" "sudo reboot" 2>/dev/null || true

        # 3. 等待 SSH 恢复
        sleep 30  # 等待 reboot 生效
        _wait_node_ssh "$ip" 120
        assert_ne "$?" "1" "${hostname} SSH 恢复"

        # 4. 验证 reboot 期间数据仍可读（其他节点的 4 个 OSD 服务，EC k=4 刚好够）
        local md5_during
        md5_during=$(ssh_to_client "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
        assert_eq "$md5_during" "$BASELINE_MD5" "${hostname} reboot 期间基线数据可读（EC 从剩余 OSD 读）"

        # 5. 重建 OSD（tmpfs 丢失，OSD 无法自启）
        echo "  重建 OSD on ${hostname}..."
        _rebuild_osds_on_node "$ip"

        # 6. 等待 OSD up + PG clean
        assert_wait_eq get_osd_count_up "6" 120 "${hostname} 重建后 6/6 OSD up"
        assert_pg_state_contains "active+clean" 300 "${hostname} 重建后 PG active+clean"

        # 7. 验证重建后基线数据可读
        local md5_after
        md5_after=$(ssh_to_client "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
        assert_eq "$md5_after" "$BASELINE_MD5" "${hostname} 重建后基线数据可读"

        echo "  ${hostname} 完成"
    done
}

# ============================================================
# check_after：最终验证
# ============================================================
check_after() {
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"

    # 全部节点重建后集群状态
    assert_wait_eq get_osd_count_up "6" 60 "最终 6/6 OSD up"
    assert_match "$(get_pg_states)" "active+clean" "最终 PG active+clean"
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群健康（非 ERR）"

    # 基线数据完整
    local md5
    md5=$(ssh_to_client "md5sum '${test_dir}/baseline.bin' 2>/dev/null" 2>/dev/null | awk '{print $1}')
    assert_eq "$md5" "$BASELINE_MD5" "基线数据完整（3 节点重建后 md5 匹配）"

    # juicefs fsck
    local fsck_rc
    ssh_to_client "juicefs fsck '${JUICEFS_METADATA_URL}' >/dev/null 2>&1" 2>/dev/null
    fsck_rc=$?
    assert_eq "$fsck_rc" "0" "juicefs fsck 通过（无元数据损坏）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "rm -f '${test_dir}/baseline.bin'" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; run_rolling_reboot; check_after; teardown; }
main "$@"
