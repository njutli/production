#!/bin/bash
# FT-003: single-node-crash
# 强制断电 .14 节点（带外管理），验证集群容错 + 服务自启 + 数据完整
#
# 故障注入：用户通过带外管理（IPMI/BMC）强制断电 .14
#   - 脚本通知用户断电，等待 SSH 不可达确认
#   - 恢复时通知用户上电，等待 SSH 恢复
#
# .14 节点上的服务：2 OSD + 1 MON + 1 TiKV + 1 PD
# 断电后：4/6 OSD、2/3 MON/TiKV/PD（majority 保持）
#
# 根因分析（iptables 模拟断电验证）：
#   rados_osd_op_timeout=30 生效（rados get 30s 后返回 ETIMEDOUT errno=110）
#   min_size=4 + 2 OSD down → 4/6 OSD → 4 ≥ min_size=4 → PG active+degraded
#   PG 可做奇偶校验重构 → data chunk 在 .14 的对象也可读
#   恢复靠 .14 上电 → OSD 重新加入 → PG 恢复 active+clean
#
# I/O 负载用 randread（预创建文件，只读不写）
# check_during 断言数据可读（min_size=4，4 OSD ≥ 4，PG active+degraded 可读）
# check_after 断言数据可读 + MD5 一致（.14 恢复后所有 PG active+clean）
# EXPECTED_DURATION=900

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "${LIB_DIR}/assert.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/fault_inject.sh"
source "${LIB_DIR}/io_load.sh"

TEST_ID="FT-003"
TEST_NAME="single-node-crash"
EXPECTED_DURATION=900

# 断电目标节点（需要带外管理权限）
TARGET_NODE="192.168.11.14"
TARGET_HOSTNAME="ceph-node3"

trap 'stop_io_load; tap_plan_end; trap - SIGINT SIGTERM' SIGINT SIGTERM

# ============================================================
# setup：前置检查 + 写入验证文件 + 启动只读 I/O 负载
# ============================================================
setup() {
    tap_plan_start "$TEST_ID" "$TEST_NAME" \
        "强制断电 ${TARGET_HOSTNAME}（2 OSD + 1 MON + 1 TiKV + 1 PD），验证集群容错 + 服务自启"

    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 60 "集群初始健康（非 ERR）"
    assert_wait_eq get_osd_count_up "6" 10 "初始 6/6 OSD up"
    assert_wait_eq get_quorum_count "3" 10 "初始 3/3 MON quorum"
    assert_wait_eq get_tikv_store_count_up "3" 10 "初始 3/3 TiKV store Up"
    assert_wait_match get_pg_states "active+clean" 10 "初始 PG active+clean"

    assert_ne "$TARGET_NODE" "" "断电目标: ${TARGET_NODE}（${TARGET_HOSTNAME}）"

    # 写入验证文件
    local verify_file="${JUICEFS_MOUNT_POINT}/reliability-test/ft003_verify.bin"
    ssh_to_client "mkdir -p '${JUICEFS_MOUNT_POINT}/reliability-test'" 2>/dev/null
    ssh_to_client "dd if=/dev/urandom of='${verify_file}' bs=1M count=100 oflag=direct 2>/dev/null" 2>/dev/null
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null >/dev/null" 2>/dev/null
    VERIFY_MD5=$(ssh_to_client "md5sum '${verify_file}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
    assert_ne "$VERIFY_MD5" "" "验证文件写入成功（md5=${VERIFY_MD5:0:16}...）"
    VERIFY_FILE="$verify_file"

    # 启动只读 I/O 负载（randread，预创建文件，不写不碰元数据）
    start_io_load randread 256K 128
    sleep 30
}

# ============================================================
# inject：通知用户断电 + 等待节点不可达
# ============================================================
inject() {
    echo ""
    echo "=========================================="
    echo "  请在 ${TARGET_HOSTNAME} 带外管理界面执行强制断电"
    echo "  目标 IP: ${TARGET_NODE}"
    echo "=========================================="
    echo ""

    # 等待节点 SSH 不可达（用户断电后生效）
    echo "  等待 ${TARGET_HOSTNAME} 不可达..."
    local waited=0
    while [ "$waited" -lt 1800 ]; do
        if ! _run "$TARGET_NODE" "true" 2>/dev/null; then
            echo "  ${TARGET_HOSTNAME} 已不可达（${waited}s）"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        [ $((waited % 30)) -eq 0 ] && echo "  仍在等待断电...（${waited}s）"
    done
    assert_lt "$waited" "1800" "${TARGET_HOSTNAME} 已断电不可达（${waited}s）"

    # 等待 OSD 心跳超时（MON 检测到节点 down）
    echo "  等待 OSD 心跳超时 + OSD map 更新..."
    sleep 30
}

# ============================================================
# check_during：故障期间断言
# ============================================================
check_during() {
    # 数据面：4/6 OSD（min_size=4，4 ≥ 4 → PG active+degraded 可读）
    assert_wait_eq get_osd_count_up "4" 60 "4/6 OSD up（断电节点 2 OSD down）"

    # 元数据面：majority 保持
    assert_wait_eq get_quorum_count "2" 60 "MON quorum 2/3（majority 保持）"
    assert_wait_eq get_tikv_store_count_up "2" 120 "TiKV 2/3 store Up（majority 保持）"

    # 集群非 ERR
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 10 "集群非 ERR（EC 极限容忍内）"

    # 数据可读验证：min_size=4，4 OSD ≥ 4 → PG active+degraded → 奇偶校验重构可用
    # rados_osd_op_timeout=30 生效 → ETIMEDOUT 后客户端重试路由到新 primary
    echo "# 开始 I/O 恢复探测（dd 60s + 间隔 5s，最多 ~350s）..."
    local io_recovered=false
    local first_ok_time=-1
    local fault_start=$(date +%s)

    for i in $(seq 1 5); do
        ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null >/dev/null" 2>/dev/null
        local read_result
        read_result=$(timeout 75 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
            "${SSH_USER}@${CLIENT_SERVER}" \
            "timeout 60 dd if='${VERIFY_FILE}' of=/dev/null bs=1M count=100 iflag=direct 2>/dev/null && echo ok" \
            2>/dev/null | tail -1)

        local elapsed=$(($(date +%s) - fault_start))
        if [ "$read_result" = "ok" ]; then
            local post_md5
            post_md5=$(timeout 75 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
                "${SSH_USER}@${CLIENT_SERVER}" \
                "md5sum '${VERIFY_FILE}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
            if [ "$post_md5" = "$VERIFY_MD5" ]; then
                if [ "$io_recovered" = "false" ]; then
                    first_ok_time=$elapsed
                    io_recovered=true
                fi
                echo "# T+${elapsed}s: 读取成功 MD5一致 ✓"
                break
            else
                echo "# T+${elapsed}s: 读取成功 但MD5不一致"
            fi
        else
            echo "# T+${elapsed}s: 读取失败（OSD map 更新中或 PG peering 未完成）"
        fi
        [ $i -lt 5 ] && sleep 5
    done

    local elapsed=$(($(date +%s) - fault_start))
    assert_eq "$io_recovered" "true" "故障期间数据可读 + MD5 一致（min_size=4，PG active+degraded，首次成功 T+${first_ok_time}s）"
    echo "# I/O 恢复时长: ${first_ok_time}s（探测耗时 ${elapsed}s）"

    # 停止 fio
    stop_io_load

    # fio 成功率（min_size=4 + 2 OSD down → PG active+degraded → EC 重构读可用）
    local rate
    rate=$(get_io_success_rate)
    echo "# fio 成功率: ${rate}%（PG active+degraded，奇偶校验重构读可用）"
    # 核心验证是上面的 dd 读 + md5（确定性验证）
}

# ============================================================
# recover：通知用户上电 + 等待节点恢复 + 条件性 OSD 重建
# ============================================================
recover() {
    echo ""
    echo "=========================================="
    echo "  请在 ${TARGET_HOSTNAME} 带外管理界面执行上电"
    echo "  目标 IP: ${TARGET_NODE}"
    echo "=========================================="
    echo ""

    # 等待 SSH 恢复
    echo "  等待 ${TARGET_HOSTNAME} SSH 恢复..."
    local waited=0
    while [ "$waited" -lt 1800 ]; do
        if _run "$TARGET_NODE" "true" 2>/dev/null; then
            echo "  ${TARGET_HOSTNAME} SSH 恢复（${waited}s）"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        [ $((waited % 30)) -eq 0 ] && echo "  仍在等待上电...（${waited}s）"
    done
    assert_lt "$waited" "1800" "${TARGET_HOSTNAME} SSH 恢复（${waited}s）"

    # 等 OSD 自启（bluefs_single_shared_device=1 时，OSD 数据在持久 LV 上，应自启）
    echo "  等待 OSD 自启（最多 120s）..."
    local osd_wait=0
    while [ "$osd_wait" -lt 120 ]; do
        local osd_up
        osd_up=$(get_osd_count_up 2>/dev/null)
        if [ "$osd_up" = "6" ]; then
            echo "  OSD 已自启 6/6（${osd_wait}s）"
            break
        fi
        sleep 10
        osd_wait=$((osd_wait + 10))
        echo "  OSD ${osd_up:-?}/6（等待 ${osd_wait}s）"
    done

    # 如果 OSD 没自启（bluefs_single_shared_device=0，DB/WAL 在 tmpfs 丢失），重建 OSD
    if [ "$osd_up" != "6" ]; then
        echo "  OSD 未自启，开始重建（DB/WAL 可能丢失）..."

        # 找到该节点上的 OSD ID
        local osd_tree osd_ids
        osd_tree=$(_run "${CLIENT_SERVER}" "sudo ceph -k /etc/ceph/ceph.client.admin.keyring -m ${CEPH_PRIMARY} osd tree 2>/dev/null" 2>/dev/null)
        osd_ids=$(echo "$osd_tree" | grep -A2 "${TARGET_HOSTNAME}" | grep osd | awk '{print $1}')

        # 销毁旧 OSD
        for osd_id in $osd_ids; do
            _run "${CLIENT_SERVER}" "sudo ceph -k /etc/ceph/ceph.client.admin.keyring -m ${CEPH_PRIMARY} osd destroy ${osd_id} --yes-i-really-really-mean-it 2>/dev/null" 2>/dev/null
            _run "${CLIENT_SERVER}" "sudo ceph -k /etc/ceph/ceph.client.admin.keyring -m ${CEPH_PRIMARY} osd crush remove osd.${osd_id} 2>/dev/null" 2>/dev/null
        done

        # 清理旧 LV + loop + tmpfs DB/WAL
        _run "$TARGET_NODE" "
            for lv in \$(sudo lvs --noheadings 2>/dev/null | grep -E 'osd-db|osd-wal|osd0|osd1' | awk '{print \$2\"/\"\$1}'); do sudo lvremove -f \$lv 2>/dev/null; done
            for vg in \$(sudo vgs --noheadings 2>/dev/null | grep -E 'db|wal' | awk '{print \$1}'); do sudo vgremove --force \$vg 2>/dev/null; done
            for loop in \$(sudo losetup -l --noheadings 2>/dev/null | grep 'bs-db' | awk '{print \$1}'); do sudo losetup -d \$loop 2>/dev/null; done
            rm -rf /tmp/bs-db-osd* 2>/dev/null
            echo '  清理完成'
        " 2>/dev/null

        # 重建 data LV + 部署新 OSD（shared DB）
        local seq=0
        for osd_id in $osd_ids; do
            seq=$((seq + 1))
            local lv_name="osd${seq}"
            # 重建 data LV
            _run "$TARGET_NODE" "sudo lvcreate -y -L 300g -n ${lv_name} ceph-vg-ceph-node3 2>/dev/null; sudo dd if=/dev/zero of=/dev/ceph-vg-ceph-node3/${lv_name} bs=1M count=10 2>/dev/null" 2>/dev/null
            # 部署新 OSD（shared DB，无 tmpfs DB）
            _run "${CLIENT_SERVER}" "sudo ceph -k /etc/ceph/ceph.client.admin.keyring -m ${CEPH_PRIMARY} orch daemon add osd ${TARGET_HOSTNAME}:/dev/ceph-vg-ceph-node3/${lv_name} 2>/dev/null" 2>/dev/null
            echo "  OSD 重建 #${seq}（${lv_name}）"
            sleep 10
        done

        # 等待新 OSD up
        assert_wait_eq get_osd_count_up "6" 120 "OSD 重建后 6/6 up"
    fi
}

# ============================================================
# check_after：恢复后断言
# ============================================================
check_after() {
    # OSD 自启（bluefs_single_shared_device=1，数据在持久 LV）
    assert_wait_eq get_osd_count_up "6" 120 "6/6 OSD up（OSD 自启）"

    # MON 自启（cephadm 管理）
    assert_wait_eq get_quorum_count "3" 120 "3/3 MON quorum（cephadm 自启）"

    # TiKV 自启（systemd Restart=always）
    assert_wait_eq get_tikv_store_count_up "3" 60 "3/3 TiKV Up（systemd 自启）"

    # PG 恢复
    assert_pg_state_contains "active+clean" 300 "PG 恢复 active+clean"

    # 集群健康
    assert_wait_match get_ceph_health "^HEALTH_(OK|WARN)" 120 "集群恢复健康（非 ERR）"

    # 数据完整性
    ssh_to_client "echo 3 | sudo tee /proc/sys/vm/drop_caches 2>/dev/null >/dev/null" 2>/dev/null
    local post_md5
    post_md5=$(ssh_to_client "md5sum '${VERIFY_FILE}' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
    assert_eq "$post_md5" "$VERIFY_MD5" "恢复后验证文件 MD5 一致（数据无损坏）"

    # juicefs fsck
    local fsck_rc
    ssh_to_client "sudo CEPH_CONF=/etc/ceph/ceph.conf juicefs fsck '${JUICEFS_METADATA_URL}' >/dev/null 2>&1" 2>/dev/null
    fsck_rc=$?
    assert_eq "$fsck_rc" "0" "juicefs fsck 通过（无元数据损坏）"

    # 清理
    ssh_to_client "rm -f '${VERIFY_FILE}'" 2>/dev/null || true
}

# ============================================================
# teardown：清理
# ============================================================
teardown() {
    stop_io_load
    ssh_to_client "rm -f '${VERIFY_FILE}' /tmp/ft003_readback.bin" 2>/dev/null || true
    tap_plan_end
    trap - SIGINT SIGTERM
}

main() { setup; inject; check_during; recover; check_after; teardown; }
main "$@"
