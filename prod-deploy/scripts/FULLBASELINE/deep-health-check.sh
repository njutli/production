#!/bin/bash
set -eu
# 注：本脚本为【只读】健康检查，不设 pipefail —— 大量"grep 无匹配"的探测管道
# （如 quorum/cluster_id 提取）在 pipefail 下会以退出码 1 传播并触发 set -e 误杀脚本。
# 无 chown/rm/dd/wipefs 等破坏性操作，无需 pipefail 保护（SYSTEM-SAFETY §2.2 针对破坏性脚本）。

# ============================================================
# deep-health-check.sh — 集群深层健康检查
#
# 在 WSL 上运行（config.sh 三层 SSH 跳板）。全部只读操作，不改任何状态。
#
# 覆盖"表面 HEALTH_OK 但深层异常"的场景（全部来自实测踩坑）：
#   - mon quorum 缺失/重组窗口期、mon 容器消失
#   - osdmap 层面数据丢失（pool/EC profile 创建后消失，auth 不消失）
#   - podman 镜像层属主污染（chown 事故后遗症 → daemon EACCES）
#   - 随机名 cephadm shell 容器 / Exited 容器 / digest 形式 image 漏检
#   - OSD 删除后孤儿 DM / deleted loop 残留
#   - keyring 复制假成功（返回 0 但文件为空）
#   - PD split-brain（cluster_id 不一致 / no leader）
#   - TiKV cluster_id 与 PD 不匹配（JuiceFS "unmatched cluster id"）
#   - 系统盘守卫自检（nvme0n1 不被误操作）
#
# 用法：bash deep-health-check.sh [--quick]
#   --quick  跳过慢速项（镜像属主检查需起容器，~10s/节点）
# 退出码：0=全 PASS，1=有 FAIL，2=有 WARN
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${PROD_DEPLOY_DIR}/config.sh"

QUICK=false
[ "${1:-}" = "--quick" ] && QUICK=true

PASS=0; WARN=0; FAIL=0
declare -a REPORT

# ok <PASS|WARN|FAIL> <检查项> <实际值>
ok() {
    local level="$1" item="$2" val="${3:-}"
    case "${level}" in
        PASS) PASS=$((PASS+1));;
        WARN) WARN=$((WARN+1));;
        FAIL) FAIL=$((FAIL+1));;
    esac
    printf '[%s] %-52s %s\n' "${level}" "${item}" "${val}"
    REPORT+=("[${level}] ${item} ${val}")
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

echo "============================================================"
echo "Deep Health Check $(date '+%F %T')  (quick=${QUICK})"
echo "============================================================"

# ============================================================
# Section 1: 节点层（容器 / 镜像 / 磁盘挂载 / loop / DM / 时钟 / 系统盘守卫）
# ============================================================
log "=== Section 1: node layer ==="
for ip in "${SLAVE_SERVERS[@]}"; do
    log "  --- ${ip} ---"
    # 单次远端调用拿全部节点层指标（减少三层 SSH 往返），所有命令只读
    out=$(_run "${ip}" '
        echo "ctn_total=$(sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -c . || true)"
        echo "ctn_exited=$(sudo podman ps -a --format "{{.Names}} {{.Status}}" 2>/dev/null | grep -ic exited || true)"
        echo "ctn_ceph=$(sudo podman ps --format "{{.Names}}" 2>/dev/null | grep -c ceph- || true)"
        echo "nvme1_mnt=$(mountpoint -q /mnt/jfs-tikv 2>/dev/null && echo yes || echo NO)"
        echo "dbwal_mnt=$(mountpoint -q /mnt/dbwal 2>/dev/null && echo yes || echo NO)"
        # 只查 /mnt/dbwal 相关的 deleted loop（我们的 DB/WAL loop）；
        # snapd 等系统自身的 deleted loop 与本集群无关且不可乱动
        echo "loop_deleted=$(sudo losetup -a 2>/dev/null | grep deleted | grep -c dbwal || true)"
        echo "loop_dbwal=$(sudo losetup -a 2>/dev/null | grep -c dbwal || true)"
        echo "dm_ceph=$(sudo dmsetup ls 2>/dev/null | grep -ic ceph || true)"
        echo "pv_osd=$(sudo pvs --noheadings -o pv_name 2>/dev/null | grep -c "nvme[23]" || true)"
        echo "tikv_proc=$(pgrep -xc tikv-server 2>/dev/null || true)"
        echo "pd_proc=$(pgrep -xc pd-server 2>/dev/null || true)"
        echo "sysdisk=$(findmnt -n -o SOURCE / 2>/dev/null | sed "s/p[0-9]*$//")"
        if systemctl is-active chronyd &>/dev/null || systemctl is-active chrony &>/dev/null; then
            chronyc tracking 2>/dev/null | awk "/System time/{print \"chrony_off=\" \$4 \"s\"}"
        elif timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
            echo "chrony_off=timesyncd-ok"
        else
            echo "chrony_off=NA"
        fi
    ' 2>/dev/null) || { ok FAIL "${ip} 可达性" "SSH 不通"; continue; }

    eval "${out}" 2>/dev/null || true
    # 容器
    [ "${ctn_exited}" = "0" ] && ok PASS "${ip} 无 Exited 容器" "exited=${ctn_exited}" \
                               || ok WARN "${ip} Exited 容器" "exited=${ctn_exited}（需 podman rm 清理）"
    [ "${ctn_ceph}" -ge 1 ] && ok PASS "${ip} ceph 容器运行中" "running=${ctn_ceph}" \
                            || ok WARN "${ip} 无运行中 ceph 容器" "running=${ctn_ceph}"
    # 挂载
    [ "${nvme1_mnt}" = "yes" ] && ok PASS "${ip} nvme1n1 挂载" "/mnt/jfs-tikv" || ok FAIL "${ip} nvme1n1 未挂载" "/mnt/jfs-tikv"
    [ "${dbwal_mnt}" = "yes" ] && ok PASS "${ip} tmpfs DB/WAL 挂载" "/mnt/dbwal" || ok FAIL "${ip} tmpfs 未挂载" "/mnt/dbwal"
    # loop / DM / PV
    [ "${loop_deleted}" = "0" ] && ok PASS "${ip} 无 deleted loop" "deleted=${loop_deleted}" \
                                || ok WARN "${ip} deleted loop 残留" "deleted=${loop_deleted}"
    [ "${pv_osd}" = "2" ] && ok PASS "${ip} OSD PV 数" "pv=${pv_osd}（nvme2/3）" \
                          || ok WARN "${ip} OSD PV 数异常" "pv=${pv_osd}（期望 2）"
    # 进程
    [ "${tikv_proc}" = "1" ] && [ "${pd_proc}" = "1" ] && ok PASS "${ip} TiKV/PD 进程" "tikv=${tikv_proc} pd=${pd_proc}" \
                             || ok FAIL "${ip} TiKV/PD 进程异常" "tikv=${tikv_proc} pd=${pd_proc}（期望各 1）"
    # 系统盘守卫自检：系统盘必须是 nvme0n1，绝不能是 nvme1/2/3
    [ "${sysdisk}" = "/dev/nvme0n1" ] && ok PASS "${ip} 系统盘守卫" "root=${sysdisk}（符合预期）" \
                                      || ok FAIL "${ip} 系统盘异常" "root=${sysdisk}（期望 /dev/nvme0n1）"
    # 时钟（chrony 偏移 < 0.5s；PD raft 依赖）
    if [ "${chrony_off:-NA}" = "timesyncd-ok" ]; then
        ok PASS "${ip} 时钟同步" "systemd-timesyncd synchronized"
    else
        _off=$(echo "${chrony_off:-NA}" | grep -oE "[0-9.]+" | head -1 || true)
        if [ -n "${_off}" ]; then
            _big=$(awk -v o="${_off}" 'BEGIN{print (o>0.5)?1:0}')
            [ "${_big}" = "0" ] && ok PASS "${ip} 时钟偏移" "${chrony_off}" || ok WARN "${ip} 时钟偏移偏大" "${chrony_off}"
        else
            ok WARN "${ip} 时钟同步状态未知" "${chrony_off:-NA}"
        fi
    fi

    # 慢速项：镜像属主（需起容器 ~10s）
    if [ "${QUICK}" = false ]; then
        _owner=$(_run "${ip}" "sudo podman run --rm ${CEPH_CONTAINER_IMAGE} stat -c '%u:%g' /var/lib/ceph 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
        [ "${_owner}" = "167:167" ] && ok PASS "${ip} ceph 镜像属主" "${_owner}" \
                                    || ok FAIL "${ip} ceph 镜像属主污染" "${_owner}（期望 167:167 → daemon EACCES）"
    fi
done

# ============================================================
# Section 2: Ceph 层（health / mon quorum / osd / PG / pool / profile / auth / osdmap 稳定性）
# ============================================================
log "=== Section 2: ceph layer ==="
CEPH="sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell --"

# 拆成单项独立 _run：三层 SSH 对"单次调用内多次 cephadm shell"的输出回传不完整
# （实测只回第一行）。每项一次 cephadm shell + 短输出，回传可靠。
health=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph health 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
[ "${health}" = "HEALTH_OK" ] && ok PASS "ceph health" "${health}" || ok WARN "ceph health" "${health:-NA}（OK 之外须看明细）"

_mo=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph -s 2>/dev/null | grep -E 'mon:|osd:'" 2>/dev/null)
_quorum_n=$(echo "${_mo}" | grep -oE 'ceph-node[0-9]' | sort -u | wc -l)
[ "${_quorum_n}" = "3" ] && ok PASS "mon quorum 3/3" "$(echo "${_mo}" | grep 'mon:' | tr -s ' ')" \
    || ok FAIL "mon quorum 异常" "$(echo "${_mo}" | grep 'mon:' | tr -s ' ')（期望 3）"
_osd_up=$(echo "${_mo}" | grep -oE '[0-9]+ osds' | grep -oE '^[0-9]+')
_osd_in=$(echo "${_mo}" | grep -oE '[0-9]+ in' | grep -oE '^[0-9]+' | head -1)
[ "${_osd_up:-0}" = "6" ] && [ "${_osd_in:-0}" = "6" ] && ok PASS "OSD 6 up/in" "up=${_osd_up} in=${_osd_in}" \
    || ok FAIL "OSD 异常" "up=${_osd_up:-?} in=${_osd_in:-?}（期望 6/6）"

_pg=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph pg stat 2>/dev/null" 2>/dev/null)
echo "${_pg}" | grep -qE "active\+clean" && ok PASS "PG 状态" "${_pg}" || ok WARN "PG 状态" "${_pg:-NA}"

_pools=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd pool ls 2>/dev/null" 2>/dev/null)
echo "${_pools}" | grep -q "${CEPH_POOL_NAME}" && ok PASS "EC pool 存在" "$(echo ${_pools})" \
    || ok FAIL "EC pool 缺失" "$(echo ${_pools})（期望含 ${CEPH_POOL_NAME}）"

_prof=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd erasure-code-profile get ec-prod 2>/dev/null | grep -E '^k=|^m=|^plugin='" 2>/dev/null)
echo "${_prof}" | grep -q "^k=${CEPH_EC_K}" && echo "${_prof}" | grep -q "^plugin=jerasure" \
    && ok PASS "EC profile 参数" "$(echo ${_prof} | tr '\n' ' ')" \
    || ok FAIL "EC profile 参数异常" "$(echo ${_prof} | tr '\n' ' ')（期望 k=${CEPH_EC_K} m=${CEPH_EC_M} jerasure）"

_jfs=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph auth get client.juicefs 2>/dev/null | grep -c 'key ='" 2>/dev/null | tr -d '[:space:]')
[ "${_jfs:-0}" = "1" ] && ok PASS "client.juicefs key 非空" "" || ok FAIL "client.juicefs 缺失" ""

# osdmap 稳定性（两次采样 epoch 不倒退；pool/profile 消失的本质是 osdmap 回滚）
_e1=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd dump 2>/dev/null | head -1 | grep -oE '[0-9]+'" 2>/dev/null | tr -d '[:space:]')
sleep 12
_e2=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd dump 2>/dev/null | head -1 | grep -oE '[0-9]+'" 2>/dev/null | tr -d '[:space:]')
if [ -n "${_e1}" ] && [ -n "${_e2}" ]; then
    [ "${_e2}" -ge "${_e1}" ] && ok PASS "osdmap epoch 不倒退" "e1=${_e1} e2=${_e2}" \
                              || ok FAIL "osdmap epoch 回滚" "e1=${_e1} -> e2=${_e2}（pool/profile 会消失!）"
else
    ok WARN "osdmap epoch 采样" "e1=${_e1:-NA} e2=${_e2:-NA}"
fi

# ============================================================
# Section 3: TiKV 层（PD health / cluster_id 一致性 / stores / leader）
# ============================================================
log "=== Section 3: tikv layer ==="
declare -A CID
_leader=""
for ip in "${TIKV_SERVERS[@]}"; do
    _h=$(_run "${ip}" 'curl -s --noproxy "*" --connect-timeout 5 http://127.0.0.1:2379/pd/api/v1/health 2>/dev/null | grep -c "\"health\": true" || echo 0' 2>/dev/null | tr -d '[:space:]')
    [ "${_h}" = "3" ] && ok PASS "${ip} PD health 3/3" "healthy=${_h}" || ok WARN "${ip} PD health" "healthy=${_h}/3"
    _cid=$(_run "${ip}" 'curl -s --noproxy "*" --connect-timeout 5 http://127.0.0.1:2379/pd/api/v1/members 2>/dev/null | grep -oE "\"cluster_id\": [0-9]+" | grep -oE "[0-9]+" | head -1' 2>/dev/null | tr -d '[:space:]')
    CID[${ip}]="${_cid:-NA}"
done
# cluster_id 三节点一致（split-brain 检测）
_cids=$(printf '%s\n' "${CID[@]}" | sort -u | wc -l)
[ "${_cids}" = "1" ] && ok PASS "PD cluster_id 一致" "${CID[${TIKV_SERVERS[0]}]}" \
    || ok FAIL "PD cluster_id 不一致(split-brain)" "150=${CID[${TIKV_SERVERS[0]}]:-?} 151=${CID[${TIKV_SERVERS[1]}]:-?} 152=${CID[${TIKV_SERVERS[2]}]:-?}"
_leader=$(_run "${TIKV_SERVERS[0]}" 'curl -s --noproxy "*" --connect-timeout 5 http://127.0.0.1:2379/pd/api/v1/members 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"leader\",{}).get(\"name\",\"\"))" 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
[ -n "${_leader}" ] && ok PASS "PD leader 存在" "${_leader}" || ok FAIL "PD no leader" ""
_stores=$(_run "${TIKV_SERVERS[0]}" 'curl -s --noproxy "*" --connect-timeout 5 http://127.0.0.1:2379/pd/api/v1/stores 2>/dev/null | grep -c "\"state_name\": \"Up\"" || echo 0' 2>/dev/null | tr -d '[:space:]')
[ "${_stores}" = "3" ] && ok PASS "TiKV stores 3 Up" "up=${_stores}" || ok FAIL "TiKV stores 异常" "up=${_stores}/3"

# ============================================================
# Section 4: JuiceFS 层（keyring / 挂载 / 元数据 / 冒烟读 / 容量）
# ============================================================
log "=== Section 4: juicefs layer ==="
out=$(ssh_to_client '
    for f in /etc/ceph/ceph.conf /etc/ceph/ceph.client.admin.keyring /etc/ceph/ceph.client.juicefs.keyring; do
        [ -s "$f" ] && echo "kf_ok_$(basename $f | tr ".:" "_")=1" || echo "kf_ok_$(basename $f | tr ".:" "_")=0"
    done
    echo "jfs_mnt=$(mountpoint -q /mnt/juicefs 2>/dev/null && echo yes || echo NO)"
    echo "jfs_df=$(df -h /mnt/juicefs 2>/dev/null | tail -1 | tr -s " " | tr " " "_")"
    echo "jfs_files=$(ls /mnt/juicefs/test_dir 2>/dev/null | wc -l)"
' 2>/dev/null) || out=""
eval "${out}" 2>/dev/null || true
[ "${kf_ok_ceph_conf:-0}" = "1" ] && [ "${kf_ok_ceph_client_admin_keyring:-0}" = "1" ] && [ "${kf_ok_ceph_client_juicefs_keyring:-0}" = "1" ] \
    && ok PASS "157 keyring 三文件非空" "" \
    || ok FAIL "157 keyring 缺失/空" "conf=${kf_ok_ceph_conf:-?} admin=${kf_ok_ceph_client_admin_keyring:-?} juicefs=${kf_ok_ceph_client_juicefs_keyring:-?}"
[ "${jfs_mnt}" = "yes" ] && ok PASS "JuiceFS 挂载" "/mnt/juicefs" || ok FAIL "JuiceFS 未挂载" ""

# 元数据可达（juicefs status 返回 volume 信息）
_jfs_st=$(ssh_to_client "juicefs status '${JUICEFS_METADATA_URL}' 2>/dev/null | grep -c '\"UUID\"' || echo 0" 2>/dev/null | tr -d '[:space:]')
[ "${_jfs_st:-0}" = "1" ] && ok PASS "JuiceFS 元数据可达" "" || ok FAIL "JuiceFS 元数据不可达" ""

# 冒烟读（test_dir 有文件时读第一个文件头 64MB；无文件是 deploy 移除 layout 后的预期态，不算异常）
if [ "${jfs_files:-0}" -gt 0 ]; then
    _bw=$(ssh_to_client 'dd if=/mnt/juicefs/test_dir/storage_test.0.0 of=/dev/null bs=4M count=16 2>&1 | tail -1 | grep -oE "[0-9.]+ [GMT]B/s"' 2>/dev/null | tr -d '[:space:]' || echo "")
    [ -n "${_bw}" ] && ok PASS "JuiceFS 冒烟读" "${_bw}" || ok WARN "JuiceFS 冒烟读" "无带宽输出"
else
    ok PASS "JuiceFS test_dir 空（未 layout，预期）" "跳过冒烟读"
fi
[ -n "${jfs_df:-}" ] && ok PASS "JuiceFS 容量" "${jfs_df}"

# ============================================================
# Section 5: 汇总
# ============================================================
echo "============================================================"
echo "SUMMARY: PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}  (quick=${QUICK})"
echo "============================================================"
if [ "${FAIL}" -gt 0 ]; then
    echo "FAIL 项:"
    printf '%s\n' "${REPORT[@]}" | grep '^\[FAIL\]'
    exit 1
elif [ "${WARN}" -gt 0 ]; then
    echo "WARN 项:"
    printf '%s\n' "${REPORT[@]}" | grep '^\[WARN\]'
    exit 2
fi
echo "ALL CHECKS PASSED"
exit 0
