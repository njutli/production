#!/bin/bash
# ============================================================
# A/B/C bottleneck-localization tests (08_1 第六节)
# 针对随机读并发瓶颈，在 使用RGW(s3) / 不使用RGW(ceph直连RADOS) 两种后端下分别跑：
#   A. juicefs stats + randread 同跑，采集 object in-flight 并发数
#   B. 调 --max-downloads / --buffer-size，看 randread 带宽是否随并发上限上升
#   C. 多客户端(2 个挂载点)并发 randread，看聚合带宽是否≈2×
#
# 用法: bash tests/bench-abc.sh <storage: ceph|s3> <label>
#   STORAGE 通过第1参数；结果与 stats 采集落到 results/abc-<label>-*.txt
#
# env:
#   LAYOUT_NUMJOBS (默认 32)  工作集 job 数（每 job 1G）；用于 randread 读真实数据
#   RUNTIME       (默认 60)   每次 randread 的 fio runtime 秒
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROD_DIR}/config.sh"
source "${PROD_DIR}/.credentials/rgw-juicefs.env"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

STORAGE="${1:?usage: bench-abc.sh <ceph|s3> <label>}"
LABEL="${2:?usage: bench-abc.sh <ceph|s3> <label>}"
LAYOUT_NUMJOBS="${LAYOUT_NUMJOBS:-32}"
LAYOUT_FILESIZE="1G"
RUNTIME="${RUNTIME:-60}"

METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"
CEPH_POOL="${CEPH_POOL:-juicefs-data}"
if [ "${STORAGE}" = "ceph" ]; then
    BUCKET_URL="ceph://${CEPH_POOL}"
else
    BUCKET_URL="${RGW_ENDPOINT}/${JUICEFS_FS_NAME}"
fi

MP1="/mnt/juicefs"
MP2="/mnt/juicefs2"
RES_DIR="${PROD_DIR}/results"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${RES_DIR}/abc-${LABEL}-${TS}.txt"
mkdir -p "${RES_DIR}"

log() { echo "$@" | tee -a "${OUT}"; }

do_format() {
    log ">>> Formatting (storage=${STORAGE}, bucket=${BUCKET_URL})..."
    if [ "${STORAGE}" = "ceph" ]; then
        juicefs format --storage ceph --bucket "${BUCKET_URL}" \
            --access-key ceph --secret-key client.juicefs \
            --trash-days 0 "${METADATA_URL}" "${JUICEFS_FS_NAME}" 2>&1 | tail -3 | tee -a "${OUT}"
    else
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=""
        # 清空可能残留的同名 bucket，避免 "Storage is not empty"
        if command -v aws &>/dev/null; then
            aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 rm "s3://${JUICEFS_FS_NAME}" --recursive >/dev/null 2>&1 || true
            aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 mb "s3://${JUICEFS_FS_NAME}" >/dev/null 2>&1 || true
        fi
        juicefs format --storage s3 --bucket "${BUCKET_URL}" \
            --access-key "${AWS_ACCESS_KEY_ID}" --secret-key "${AWS_SECRET_ACCESS_KEY}" \
            --trash-days 0 "${METADATA_URL}" "${JUICEFS_FS_NAME}" 2>&1 | tail -3 | tee -a "${OUT}"
    fi
}

mount_at() {  # $1=mountpoint  $2..=extra opts
    local mp="$1"; shift
    sudo mkdir -p "${mp}"; sudo chown "$(whoami):$(whoami)" "${mp}" 2>/dev/null || true
    juicefs mount -d "$@" "${METADATA_URL}" "${mp}" 2>&1 | tail -2 | tee -a "${OUT}"
    sleep 3
    mountpoint -q "${mp}" || { log "FATAL: mount ${mp} failed"; return 1; }
}

umount_at() {
    local mp="$1"
    mountpoint -q "${mp}" 2>/dev/null && { fusermount -uz "${mp}" 2>/dev/null || sudo umount -l "${mp}" 2>/dev/null; }
}

destroy_vol() {
    umount_at "${MP1}"; umount_at "${MP2}"
    sleep 65
    local uuid
    uuid=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
    [ -n "${uuid}" ] && juicefs destroy "${METADATA_URL}" "${uuid}" --yes 2>&1 | tail -2 | tee -a "${OUT}"
}

drop_caches() {
    sync 2>/dev/null || true
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    for d in /var/jfsCache "${HOME}/.juicefs/cache"; do
        [ -d "${d}" ] && find "${d}" -type f -path '*raw*' -delete 2>/dev/null || true
    done
}

layout() {  # populate test_dir on MP1
    mkdir -p "${MP1}/test_dir"
    log ">>> Layout: ${LAYOUT_NUMJOBS} jobs x ${LAYOUT_FILESIZE} ..."
    fio --directory="${MP1}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=4M \
        --rw=write --numjobs="${LAYOUT_NUMJOBS}" --fallocate=none \
        --group_reporting --end_fsync=1 2>&1 | grep -E "WRITE:|err=" | tee -a "${OUT}"
}

randread_on() {  # $1=mountpoint  -> prints "BW=... bw_line"
    local mp="$1"
    fio --directory="${mp}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=256k \
        --rw=randread --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
        --direct=1 --fallocate=none --group_reporting --time_based --runtime="${RUNTIME}s" 2>&1
}

# ============================================================
log "============================================================"
log "A/B/C bottleneck test — storage=${STORAGE} label=${LABEL}"
log "Date: $(date)  layout=${LAYOUT_NUMJOBS}x${LAYOUT_FILESIZE} runtime=${RUNTIME}s"
log "============================================================"

# Clean start + fresh volume + layout (shared by A/B; C remounts)
umount_at "${MP1}"; umount_at "${MP2}"; sleep 2
destroy_vol 2>/dev/null || true
do_format
mount_at "${MP1}" --cache-size 0 || exit 1
layout

# ============================================================
# TEST A: juicefs stats + randread 同跑，采集 object 并发
# ============================================================
log ""
log "########## TEST A: stats + randread (concurrency) ##########"
drop_caches
log ">>> capturing juicefs stats (object section) during randread..."
juicefs stats "${MP1}" -l 1 --interval 1 --count $((RUNTIME+5)) > "${RES_DIR}/abc-${LABEL}-A-stats.txt" 2>&1 &
STATS_PID=$!
randread_on "${MP1}" > "${RES_DIR}/abc-${LABEL}-A-randread.txt" 2>&1
wait "${STATS_PID}" 2>/dev/null || true
A_BW=$(grep -E "READ: bw=" "${RES_DIR}/abc-${LABEL}-A-randread.txt" | head -1)
log "A randread: ${A_BW}"
log "A stats saved: abc-${LABEL}-A-stats.txt (see object/fuse columns)"

# ============================================================
# TEST B: 调读并发相关参数，看 randread 带宽趋势
#   注意: JuiceFS 1.3.1 没有 --max-downloads；控制读并发的是
#         --buffer-size(默认300M) / --prefetch(默认1) / --max-readahead。
#   数据已在后端，B 各档只需重挂载（不同 mount 参数），无需重新 layout
# ============================================================
log ""
log "########## TEST B: read-concurrency params sweep (buffer-size/prefetch/readahead) ##########"
run_b() {  # $1=tag  $2..=mount opts
    local tag="$1"; shift
    umount_at "${MP1}"; sleep 2
    mount_at "${MP1}" --cache-size 0 "$@" || { log "B[${tag}] mount fail"; return; }
    drop_caches
    local out="${RES_DIR}/abc-${LABEL}-B-${tag}.txt"
    randread_on "${MP1}" > "${out}" 2>&1
    local bw; bw=$(grep -E "READ: bw=" "${out}" | head -1)
    log "B[${tag}] opts='$*' -> ${bw}"
}
run_b baseline
run_b buf2g            --buffer-size 2048
run_b prefetch16       --prefetch 16
run_b prefetch0        --prefetch 0
run_b buf2g-prefetch16 --buffer-size 2048 --prefetch 16
run_b readahead        --buffer-size 2048 --max-readahead 512

# ============================================================
# TEST C: 多客户端并发 (2 mountpoints) randread，看聚合带宽
# ============================================================
log ""
log "########## TEST C: 2-client aggregate randread ##########"
umount_at "${MP1}"; sleep 2
mount_at "${MP1}" --cache-size 0 || exit 1
mount_at "${MP2}" --cache-size 0 || exit 1
drop_caches
log ">>> running randread on BOTH mountpoints simultaneously..."
randread_on "${MP1}" > "${RES_DIR}/abc-${LABEL}-C-client1.txt" 2>&1 &
C1=$!
randread_on "${MP2}" > "${RES_DIR}/abc-${LABEL}-C-client2.txt" 2>&1 &
C2=$!
wait "${C1}" "${C2}"
C1_BW=$(grep -E "READ: bw=" "${RES_DIR}/abc-${LABEL}-C-client1.txt" | head -1)
C2_BW=$(grep -E "READ: bw=" "${RES_DIR}/abc-${LABEL}-C-client2.txt" | head -1)
log "C client1: ${C1_BW}"
log "C client2: ${C2_BW}"

# ============================================================
# Cleanup
# ============================================================
log ""
log ">>> cleanup: unmount + destroy volume"
destroy_vol
log ""
log "DONE storage=${STORAGE} label=${LABEL}"
log "Results: ${OUT}"
echo "=== ABC DONE storage=${STORAGE} exit=0 ==="
