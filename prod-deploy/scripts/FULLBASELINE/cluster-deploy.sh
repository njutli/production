#!/bin/bash
set -euo pipefail

# ============================================================
# cluster-deploy.sh — 一键部署：干净环境 → TiKV + Ceph + JuiceFS + 冒烟验证
#
# 在 WSL 上运行（config.sh 三层 SSH 跳板：WSL → HK ECS → 157 → slaves）。
# 前置条件：干净环境。若集群有残留，先运行 cluster-teardown.sh。
#
# 编排（各步骤调用 prod-deploy/scripts/ 下已有脚本，其内部 sudo 写操作
# 均已按 SYSTEM-SAFETY-SKILL §1.3 确认，本脚本自身只含只读检查）：
#
#   Step 0  preflight        节点可达 + sudo NOPASSWD + 干净状态检查（只读）
#   Step 1  prepare-all-servers.sh   包/挂载(nvme1n1)/tmpfs/limits（幂等）
#   Step 2  deploy-tikv.sh --yes     3 PD + 3 TiKV (v7.1.5)
#   Step 3  deploy-ceph.sh --yes     bootstrap + 镜像污染检测 + 6 OSD + EC4+2 pool + keyring→157
#   Step 4  deploy-juicefs.sh format + mount
#   Step 5  smoke test               冒烟读写（64MB 写+读回 md5 校验，秒级，不留数据）
#   Step 6  verify                   TiKV stores=3 / ceph health / 6 OSD up / mount
#
# 注：数据布局（128×1G）是 FULLBASELINE.sh item_layout 的职责，本脚本不做——
#     部署只需证明集群可读写（冒烟），大写入既耗时又占空间且与基线测试重复。
#
# 用法：bash cluster-deploy.sh [--resume]
#   --resume  断点续跑：跳过干净状态检查（各 deploy 脚本幂等，可在
#             中途失败修复后重跑；TiKV 重装配置重启、Ceph 跳过已 bootstrap）
# 日志：/tmp/opencode/cluster-deploy-<timestamp>.log（全量输出）
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${PROD_DEPLOY_DIR}/config.sh"

RESUME=false
for arg in "$@"; do
    case "${arg}" in
        --resume) RESUME=true ;;
    esac
done

LOG_FILE="/tmp/opencode/cluster-deploy-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /tmp/opencode

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

# run_step <name> <cmd...> — 输出实时打到控制台并全量进日志，失败即停
run_step() {
    local name="$1"; shift
    log "===== ${name} START ====="
    local rc=0
    "$@" 2>&1 | tee -a "${LOG_FILE}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        log "===== ${name} FAILED (rc=${rc}) — 完整日志: ${LOG_FILE} ====="
        exit "${rc}"
    fi
    log "===== ${name} OK ====="
}

log "===== CLUSTER DEPLOY START ====="
log "Nodes:      ${SLAVE_SERVERS[*]}  (client: ${CLIENT_SERVER})"
log "OSD:        ${CEPH_OSD_DEVICES_PER_NODE[*]} per node × 3 = 6"
log "EC:         ${CEPH_EC_K}+${CEPH_EC_M}, pool=${CEPH_POOL_NAME}, pg=${CEPH_PG_NUM}"
log "Ceph image: ${CEPH_CONTAINER_IMAGE} (镜像属主污染检测)"
log "Log:        ${LOG_FILE}"
log ""

# ============================================================
# Step 0: Preflight（只读）— 可达性 / sudo NOPASSWD / 干净状态
# ============================================================

log "===== Step 0: preflight ====="
for ip in "${SLAVE_SERVERS[@]}"; do
    info=$(_run "${ip}" "
        sudo -n true 2>/dev/null && echo -n 'sudo=OK ' || echo -n 'sudo=FAIL '
        echo -n \"ceph_ctn=\$(sudo podman ps -a --format '{{.Names}}' 2>/dev/null | grep -c . || true) \"
        echo -n \"tikv=\$(pgrep -xc tikv-server 2>/dev/null || true)/\$(pgrep -xc pd-server 2>/dev/null || true) \"
        echo -n \"osd_pv=\$(sudo pvs --noheadings -o pv_name 2>/dev/null | grep -c 'nvme[23]' || true)\"
    " 2>/dev/null) || { log "  ${ip}: UNREACHABLE — 检查三层 SSH 链路"; exit 1; }
    log "  ${ip}: ${info}"
    echo "${info}" | grep -q 'sudo=OK' || { log "ERROR: ${ip} 无 sudo NOPASSWD"; exit 1; }
    if [ "${RESUME}" = false ]; then
        if ! echo "${info}" | grep -q 'ceph_ctn=0' || \
           ! echo "${info}" | grep -q 'tikv=0/0' || \
           ! echo "${info}" | grep -q 'osd_pv=0'; then
            log "ERROR: ${ip} 存在集群残留，不是干净环境。"
            log "       请先运行: bash cluster-teardown.sh"
            log "       或若为断点续跑: bash cluster-deploy.sh --resume"
            exit 1
        fi
    fi
done
if [ "${RESUME}" = true ]; then
    log "  preflight OK (--resume: 跳过干净检查，依赖各 deploy 脚本幂等性)"
else
    log "  preflight OK (3 nodes reachable, sudo OK, clean)"
fi

# ============================================================
# Step 1-4: 编排已有 deploy 脚本
# ============================================================

run_step "Step 1: prepare-all-servers" \
    bash "${PROD_DEPLOY_DIR}/scripts/prepare-all-servers.sh"

run_step "Step 2: deploy-tikv" \
    bash "${PROD_DEPLOY_DIR}/scripts/deploy-tikv.sh" --yes

run_step "Step 3: deploy-ceph" \
    bash "${PROD_DEPLOY_DIR}/scripts/deploy-ceph.sh" --yes

run_step "Step 4a: juicefs format" \
    bash "${PROD_DEPLOY_DIR}/scripts/deploy-juicefs.sh" format

run_step "Step 4b: juicefs mount" \
    bash "${PROD_DEPLOY_DIR}/scripts/deploy-juicefs.sh" mount

# ============================================================
# Step 5: 冒烟读写测试（64MB 写 + 读回 md5 校验，秒级，不留数据）
# ============================================================

log "===== Step 5: smoke R/W test START ====="
ssh_to_client '
    set -e
    dd if=/dev/urandom of=/mnt/juicefs/.smoke.bin bs=1M count=64 2>/dev/null
    w=$(md5sum /mnt/juicefs/.smoke.bin | awk "{print \$1}")
    r=$(dd if=/mnt/juicefs/.smoke.bin of=/dev/stdout bs=1M 2>/dev/null | md5sum | awk "{print \$1}")
    rm -f /mnt/juicefs/.smoke.bin
    [ "$w" = "$r" ] && echo "smoke R/W OK (64MB, md5 match)" || { echo "smoke R/W MISMATCH"; exit 1; }
' 2>/dev/null | tee -a "${LOG_FILE}" || { log "===== Step 5 FAILED ====="; exit 1; }
log "===== Step 5: smoke R/W test OK ====="

# ============================================================
# Step 6: 验证（只读）
# ============================================================

log "===== Step 6: verify ====="

log "--- TiKV stores (expect 3 UP):"
_run "${TIKV_SERVERS[0]}" \
    "curl -s --noproxy '*' 'http://127.0.0.1:2379/pd/api/v1/stores' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(\"  store\", s[\"store\"][\"id\"], s[\"store\"][\"address\"], s[\"store\"][\"state_name\"]) for s in d.get(\"stores\",[])]'" \
    2>/dev/null | tee -a "${LOG_FILE}" || log "  WARN: PD API 查询失败"

log "--- Ceph health / OSD tree:"
_run "${CEPH_PRIMARY}" "
    sudo cephadm shell -- ceph health 2>/dev/null
    sudo cephadm shell -- ceph osd stat 2>/dev/null
    sudo cephadm shell -- ceph osd tree 2>/dev/null
" 2>/dev/null | tee -a "${LOG_FILE}" || log "  WARN: ceph 查询失败"

log "--- JuiceFS mount on ${CLIENT_SERVER}:"
ssh_to_client "mountpoint -q ${JUICEFS_MOUNT_POINT} && df -h ${JUICEFS_MOUNT_POINT} | tail -1 || echo 'NOT MOUNTED'" \
    2>/dev/null | tee -a "${LOG_FILE}"

log ""
log "===== DEPLOY COMPLETE ====="
log "PD endpoints: ${PD_ENDPOINTS}"
log "JuiceFS:      ${JUICEFS_METADATA_URL} → ${JUICEFS_MOUNT_POINT}"
log "Log:          ${LOG_FILE}"
log "下一步: 在 157 上运行 FULLBASELINE.sh / FULLBASELINE-DEBUG.sh"
