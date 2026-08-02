#!/bin/bash
# FT-010: juicefs-fuse-crash
# kill JuiceFS FUSE 进程，验证 mount 不可用、已 fsync 数据完整、重启后恢复
# EXPECTED_DURATION=180

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"

TEST_ID="FT-010"
TEST_NAME="juicefs-fuse-crash"
EXPECTED_DURATION=180

trap '_restart_fuse; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# 重启 JuiceFS FUSE（umount stale + 重新挂载）
_restart_fuse() {
    ssh_to_client "sudo umount -l ${JUICEFS_MOUNT_POINT} 2>/dev/null; sleep 2" 2>/dev/null
    ssh_to_client "nohup juicefs mount '${JUICEFS_METADATA_URL}' ${JUICEFS_MOUNT_POINT} ${JUICEFS_MOUNT_OPTS[*]} > /dev/null 2>&1 &" 2>/dev/null
    sleep 5
}

# ============================================================
# setup：前置检查 + 写入测试文件
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "kill JuiceFS FUSE 进程，验证 mount 不可用、已 fsync 数据完整、重启后恢复"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_eq "$(get_juicefs_status)" "mounted" "初始 JuiceFS 已挂载"

    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "mkdir -p '${test_dir}'" 2>/dev/null

    # 写入已 fsync 的文件（数据保证在后端，FUSE crash 不丢失）
    ssh_to_client \
        "echo 'fsync-data' > '${test_dir}/ft010_fsync.txt' && sync '${test_dir}/ft010_fsync.txt'" \
        2>/dev/null
    local fsync_content
    fsync_content=$(ssh_to_client "cat '${test_dir}/ft010_fsync.txt' 2>/dev/null" 2>/dev/null)
    assert_eq "$fsync_content" "fsync-data" "fsync 文件写入成功"

    # 写入未 fsync 的文件（数据可能在 FUSE 进程内存中，crash 后可能丢失）
    ssh_to_client "echo 'nofsync-data' > '${test_dir}/ft010_nofsync.txt'" 2>/dev/null
    # 不做断言——POSIX 不保证未 fsync 数据的持久性
}

# ============================================================
# inject：kill JuiceFS FUSE 进程
# ============================================================
inject() {
    ssh_to_client "sudo kill -9 \$(pgrep -f 'juicefs.*mount.*${JUICEFS_MOUNT_POINT}') 2>/dev/null" 2>/dev/null
    sleep 2
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # mount 点不可用
    local status
    status=$(ssh_to_client "mountpoint -q ${JUICEFS_MOUNT_POINT} 2>/dev/null && echo mounted || echo unmounted" 2>/dev/null)
    assert_eq "$status" "unmounted" "JuiceFS mount 不可用（FUSE 进程已 kill）"

    # 文件不可访问
    local read_test
    read_test=$(ssh_to_client "cat '${JUICEFS_MOUNT_POINT}/reliability-test/ft010_fsync.txt' 2>/dev/null" 2>/dev/null)
    assert_eq "$read_test" "" "文件不可访问（mount 点不可用）"

    # 后端集群不受影响（Ceph/TiKV 仍在运行）
    assert_eq "$(get_osd_count_up)" "6" "OSD 仍 6/6 up（后端不受 FUSE crash 影响）"
    assert_eq "$(get_tikv_store_count_up)" "3" "TiKV 仍 3/3 Up（后端不受 FUSE crash 影响）"
}

# ============================================================
# recover：重启 JuiceFS FUSE
# ============================================================
recover() {
    _restart_fuse
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # mount 恢复
    assert_eq "$(get_juicefs_status)" "mounted" "JuiceFS 重新挂载"

    # 已 fsync 的数据完整（数据在后端，FUSE crash 不影响）
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    local fsync_content
    fsync_content=$(ssh_to_client "cat '${test_dir}/ft010_fsync.txt' 2>/dev/null" 2>/dev/null)
    assert_eq "$fsync_content" "fsync-data" "已 fsync 数据完整（后端持久化）"

    # 未 fsync 的数据：记录实际行为（POSIX 不保证，可能丢失也可能保留）
    local nofsync_content
    nofsync_content=$(ssh_to_client "cat '${test_dir}/ft010_nofsync.txt' 2>/dev/null" 2>/dev/null)
    if [ "$nofsync_content" = "nofsync-data" ]; then
        echo "# 未 fsync 数据保留（crash 前已被 JuiceFS flush 到后端）"
    else
        echo "# 未 fsync 数据丢失（POSIX 语义：未 fsync 数据不保证持久性）"
    fi

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群健康（非 ERR）"
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    # 确保 JuiceFS 已挂载
    if [ "$(get_juicefs_status 2>/dev/null)" != "mounted" ]; then
        _restart_fuse
    fi
    # 清理测试文件
    local test_dir="${JUICEFS_MOUNT_POINT}/reliability-test"
    ssh_to_client "rm -f '${test_dir}/ft010_fsync.txt' '${test_dir}/ft010_nofsync.txt'" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
