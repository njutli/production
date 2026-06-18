#!/bin/bash
# ============================================================
# 256K block-size 参数调优 sweep
# 在消除读放大后，复测 08_2 B + 08 方向一的参数是否对 256k randread 有效。
#
# 后端：ceph 直连 RADOS，pool=juicefs-data，block-size=256K
# 每组跑三项：randread / randwrite(analysis) / randrw(analysis)
#
# Part 1: 读侧 mount 参数 sweep   (6组, ~15min)
# Part 2: 写侧参数                 (2组, ~5min)
# Part 3: 缓存热态                 (1组, ~5min)
#
# 用法: bash tests/bench-bs256k-sweep.sh
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROD_DIR}/config.sh"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

METADATA_URL="tikv://${PD_ENDPOINTS}/juicefs-prod"
CEPH_POOL="${CEPH_POOL:-juicefs-data}"
BUCKET_URL="ceph://${CEPH_POOL}"
LAYOUT_NUMJOBS="${LAYOUT_NUMJOBS:-32}"
LAYOUT_FILESIZE="1G"
RUNTIME="${RUNTIME:-60}"

MP="/mnt/juicefs"
RES_DIR="${PROD_DIR}/results"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${RES_DIR}/bs256k-sweep-${TS}.txt"
mkdir -p "${RES_DIR}"

log() { echo "$@" | tee -a "${OUT}"; }
sep()  { log ""; log "========================================================"; }

umount_mp() {
    mountpoint -q "${MP}" 2>/dev/null && { fusermount -uz "${MP}" 2>/dev/null || sudo umount -l "${MP}" 2>/dev/null; }
    sleep 2
}

mount_mp() {
    sudo mkdir -p "${MP}"; sudo chown "$(whoami):$(whoami)" "${MP}" 2>/dev/null || true
    juicefs mount -d "$@" "${METADATA_URL}" "${MP}" 2>&1 | tail -2 | tee -a "${OUT}"
    sleep 3
    mountpoint -q "${MP}" || { log "FATAL: mount ${MP} failed"; exit 1; }
}

destroy_vol() {
    umount_mp
    sleep 35
    local uuid
    uuid=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
    [ -n "${uuid}" ] && juicefs destroy "${METADATA_URL}" "${uuid}" --yes 2>&1 | tail -2 | tee -a "${OUT}"
    umount_mp
}

drop_caches() {
    sync 2>/dev/null || true
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
}

do_format() {
    log ">>> Formatting 256K ceph-direct volume..."
    juicefs format --storage ceph --bucket "${BUCKET_URL}" \
        --access-key ceph --secret-key client.juicefs \
        --block-size 256 --trash-days 0 \
        ${EXTRA_FORMAT_OPTS:-} \
        "${METADATA_URL}" juicefs-prod 2>&1 | tail -3 | tee -a "${OUT}"
}

do_layout() {
    mkdir -p "${MP}/test_dir"
    log ">>> Layout: ${LAYOUT_NUMJOBS} jobs x ${LAYOUT_FILESIZE} ..."
    fio --directory="${MP}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=4M \
        --rw=write --numjobs="${LAYOUT_NUMJOBS}" --fallocate=none \
        --group_reporting --end_fsync=1 2>&1 | grep -E "WRITE:|err=" | tee -a "${OUT}"
}

run_randread() {
    drop_caches
    fio --directory="${MP}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=256k \
        --rw=randread --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
        --direct=1 --fallocate=none --group_reporting --time_based --runtime="${RUNTIME}s" 2>&1
}

run_randwrite() {
    drop_caches
    fio --directory="${MP}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=256k \
        --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
        --direct=1 --fallocate=none --openfiles=100 \
        --group_reporting --time_based --runtime="${RUNTIME}s" 2>&1
}

run_randrw() {
    drop_caches
    fio --directory="${MP}/test_dir" --name=storage_test \
        --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=256k \
        --rw=randrw --ioengine=libaio --iodepth=128 --numjobs="${LAYOUT_NUMJOBS}" \
        --direct=1 --fallocate=none --openfiles=100 \
        --group_reporting --time_based --runtime="${RUNTIME}s" 2>&1
}

sweep_one() {  # $1=tag  $2..=mount opts
    local tag="$1"; shift
    sep
    log "PARAM: ${tag}  opts: $*"
    umount_mp
    mount_mp --cache-size 0 "$@"
    local rr rw rrw

    # randread
    log "--- randread ---"
    rr=$(run_randread | grep -E "READ: bw=" | head -1)
    log "  randread: ${rr}"

    # randwrite (analysis, reuse layout)
    log "--- randwrite (analysis) ---"
    rw=$(run_randwrite | grep -E "WRITE: bw=" | head -1)
    log "  randwrite: ${rw}"

    # randrw (analysis, reuse layout)
    log "--- randrw (analysis) ---"
    local rr_out; rr_out=$(run_randrw)
    rrw_read=$(echo "${rr_out}" | grep -E "READ: bw=" | head -1)
    rrw_write=$(echo "${rr_out}" | grep -E "WRITE: bw=" | head -1)
    log "  randrw read:  ${rrw_read}"
    log "  randrw write: ${rrw_write}"
    log "SUMMARY ${tag} | rr=${rr} | rw=${rw} | rrwR=${rrw_read} | rrwW=${rrw_write}"
}

# ============================================================
log "============================================================"
log "256K block-size parameter sweep"
log "Date: $(date)  layout=${LAYOUT_NUMJOBS}x${LAYOUT_FILESIZE}  runtime=${RUNTIME}s"
log "============================================================"

# Clean start: destroy any previous volume, format 256K, layout
destroy_vol 2>/dev/null || true
do_format
mount_mp --cache-size 0
do_layout

# ============================================================
# Part 1: 读侧参数 sweep (remount only)
# ============================================================
sep
log "### Part 1: Read-side parameters ###"
sweep_one baseline
sweep_one buf2g            --buffer-size 2048
sweep_one prefetch0        --prefetch 0
sweep_one prefetch16       --prefetch 16
sweep_one buf2g-prefetch16 --buffer-size 2048 --prefetch 16
sweep_one readahead        --buffer-size 2048 --max-readahead 512

# ============================================================
# Part 2: 写侧参数
# ============================================================
sep
log "### Part 2: Write-side parameters ###"

# 2a: --writeback (remount only, reuse layout)
log "# 2a: writeback"
sweep_one writeback --writeback

# 2b: --max-uploads 40 (need fresh format + re-layout)
log "# 2b: max-uploads=40"
destroy_vol 2>/dev/null || true
EXTRA_FORMAT_OPTS="--max-uploads 40" do_format
mount_mp --cache-size 0
do_layout
sweep_one max-uploads40

# ============================================================
# Part 3: 缓存热态 (remount only, reuse layout)
# ============================================================
sep
log "### Part 3: Cache warmup ###"
umount_mp
mount_mp --cache-dir /dev/shm/jfsCache --cache-size 10240 --cache-partial-only
log "--- warmup ---"
juicefs warmup "${MP}/test_dir" 2>&1 | tail -2 | tee -a "${OUT}"
drop_caches  # drop kernel pagecache but keep juicefs cache

sep
log "PARAM: warmup-cached"
local rr rw rrw rr_out
rr=$(run_randread | grep -E "READ: bw=" | head -1)
log "  randread: ${rr}"
rw=$(run_randwrite | grep -E "WRITE: bw=" | head -1)
log "  randwrite: ${rw}"
rr_out=$(run_randrw)
rrw_read=$(echo "${rr_out}" | grep -E "READ: bw=" | head -1)
rrw_write=$(echo "${rr_out}" | grep -E "WRITE: bw=" | head -1)
log "  randrw read:  ${rrw_read}"
log "  randrw write: ${rrw_write}"
log "SUMMARY warmup-cached | rr=${rr} | rw=${rw} | rrwR=${rrw_read} | rrwW=${rrw_write}"

# ============================================================
# Cleanup
# ============================================================
sep
log ">>> cleanup: destroy volume"
destroy_vol
log "DONE  results: ${OUT}"
echo "=== SWEEP DONE $(date) ==="
