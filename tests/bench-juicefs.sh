#!/bin/bash
set -euo pipefail
# ============================================================
# JuiceFS Benchmark Test Script
# Full cycle: format → mount → fio(seq read/write + pure random read/write) → unmount → destroy
# 纯随机读/写用验收口径（256k iodepth=128 numjobs=128 direct=1），各自独立，
# 便于调优时排除互相干扰（随机读调优时不受随机写影响，反之亦然）。
#
# Usage:
#   bash tests/bench-juicefs.sh <label> [extra_mount_opts...]
#
# Env vars (for 08 tuning directions):
#   STORAGE=s3|ceph       后端存储类型（默认 s3，走 RGW；ceph=方向三去 RGW 直连 RADOS）
#   CEPH_POOL=<pool>      STORAGE=ceph 时的 Ceph 数据池（默认 default.rgw.buckets.data）
#   EXTRA_FORMAT_OPTS=".."  透传给 `juicefs format` 的额外参数（如 --max-uploads 40 --compress none）
#   WARMUP=1              在 randread/randrw 前执行 `juicefs warmup` 预热且不清缓存（热态/缓存口径，1.6）
#   LAYOUT_NUMJOBS           纯 randread(step9) 预铺文件的 job 数（默认 128，一次写入 128GB）
#   LAYOUT_FILESIZE=1G       上述预铺每文件大小（默认 1G）
#   SKIP_SEQ=1               跳过顺序测试（step4-7），只跑布局+随机三项（调参迭代省 ~20min）
#   REPEAT=N                 每个随机项重复跑 N 次（默认 5），取多次以排除单次波动。
#   SKIP_RANDWRITE=1         跳过随机写/混合项（step 9a/9b/10/11），只跑纯 randread（step 9）
#   SKIP_LAYOUT=1            跳过 destroy/format/mount/layout（step 1-8），直接在已挂载、已有布局数据的卷上跑
#                             随机读/分析写/混合读写（step 9/9a/9b），结束时不下卷不销毁。与 SKIP_SEQ/SKIP_RANDWRITE 可组合。
#   DO_LAYOUT_ONLY=1          仅建卷+布局后退出、不下卷不销毁。配合 SKIP_SEQ=1 跳过顺序测试，
#                             用于"建一个有 layout 的卷保留供后续 SKIP_LAYOUT=1 复用"。
#                            复用布局的项（randread/9a/9b）每次仅 +~60s；fresh_volume 项
#                            （纯 randwrite/randrw）每次重建卷+65s会话等待，成本较高。
#
# 注意：布局只做一次，randread 复用同一批文件（同 --name=storage_test）；
#       randwrite/randrw 通过 fresh_volume 隔开，不共享布局数据。
#
# 注意：extra_mount_opts 是 *mount* 参数（--max-downloads/--buffer-size/--prefetch...）；
#       format 期参数（--max-uploads/--compress...）请用 EXTRA_FORMAT_OPTS。
# 示例：
#   STORAGE=ceph bash tests/bench-juicefs.sh norgw                  # 方向三：去 RGW 直连 RADOS
#   EXTRA_FORMAT_OPTS="--compress none" bash tests/bench-juicefs.sh nocompress
#   WARMUP=1 bash tests/bench-juicefs.sh warm --cache-size 102400   # 1.6 热态/缓存
# ============================================================

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "${SCRIPT_DIR}")"
source "${PROD_DIR}/config.sh"
source "${PROD_DIR}/.credentials/rgw-juicefs.env"

LABEL="${1:-baseline}"
shift || true
EXTRA_MOUNT_OPTS="$@"

# Tuning knobs (overridable via env)
STORAGE="${STORAGE:-s3}"
RADOS_POOL="${RADOS_POOL:-${CEPH_POOL:-default.rgw.buckets.data}}"
EXTRA_FORMAT_OPTS="${EXTRA_FORMAT_OPTS:-}"
WARMUP="${WARMUP:-0}"
# Layout (pre-fill) size for pure-randread (step 10).
# Default 128 jobs × 1G = 128GB；一次写入，步骤 10 的 randread 复用这批数据。
LAYOUT_NUMJOBS="${LAYOUT_NUMJOBS:-128}"
LAYOUT_FILESIZE="${LAYOUT_FILESIZE:-1G}"
# SKIP_SEQ=1 跳过顺序测试（step4-7，单/多job 顺序读写），只跑布局 + 随机三项，
# 用于调参迭代时省掉约 20min 顺序测试时间（仅关心随机读写）。
SKIP_SEQ="${SKIP_SEQ:-0}"
# REPEAT=N 每个随机项重复跑 N 次（默认 5），取多次平均/中位以排除单次波动（randrw 读方差大）。
REPEAT="${REPEAT:-5}"
# SKIP_RANDWRITE=1 跳过随机写/混合项（step 9a/9b/10/11），只跑纯 randread（step 9）。
# 用于只看随机读的场景（如 2A EC-vs-副本对照）。
SKIP_RANDWRITE="${SKIP_RANDWRITE:-0}"

# SKIP_LAYOUT=1 跳过 destroy/format/mount/layout（step 1-8），直接在已挂载的卷上跑随机读/分析写/混
# 合读写（step 9/9a/9b），结束时不下卷不销毁。用于"layout 一次、反复测"的场景。
SKIP_LAYOUT="${SKIP_LAYOUT:-0}"

# DO_LAYOUT_ONLY=1 执行到 layout 完成后直接退出、不下卷不销毁。与 SKIP_SEQ=1 配合使用，
# 用于"建一个有 layout 数据的卷并保留供后续 SKIP_LAYOUT=1 复用"的场景。
DO_LAYOUT_ONLY="${DO_LAYOUT_ONLY:-0}"

METADATA_URL="tikv://${PD_ENDPOINTS}/${JUICEFS_FS_NAME}"
if [ "${STORAGE}" = "ceph" ]; then
    BUCKET_URL="ceph://${RADOS_POOL}"
else
    BUCKET_URL="${RGW_ENDPOINT}/${JUICEFS_FS_NAME}"
fi
RESULT_DIR="${PROD_DIR}/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="${RESULT_DIR}/${TIMESTAMP}-${LABEL}.txt"

mkdir -p "${RESULT_DIR}"

fail() {
    echo "FATAL: $1" | tee -a "${RESULT_FILE}"
    do_cleanup
    exit 1
}

# Drop OS page cache + JuiceFS read cache between cases so tests don't
# influence each other (e.g. a prior write/randrw warming the cache for the
# following read). Best-effort: skips silently if not permitted.
drop_caches() {
    sync 2>/dev/null || true
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    # JUICEFS_CACHE_DIR may be set in config.sh; otherwise probe the dir given
    # via --cache-dir in EXTRA_MOUNT_OPTS, then fall back to common defaults.
    local cdir="${JUICEFS_CACHE_DIR:-}"
    if [ -z "${cdir}" ]; then
        cdir=$(echo "${EXTRA_MOUNT_OPTS}" | grep -o -- '--cache-dir[ =][^ ]*' | head -1 | sed 's/--cache-dir[ =]//') || true
    fi
    for d in "${cdir}" /var/jfsCache "${HOME}/.juicefs/cache"; do
        [ -n "${d}" ] && [ -d "${d}" ] && find "${d}" -type f -path '*raw*' -delete 2>/dev/null || true
    done
}

do_cleanup() {
    echo ">>> Cleaning up..." | tee -a "${RESULT_FILE}"
    rm -rf "${JUICEFS_MOUNT_POINT}/test_dir" 2>/dev/null || true
    if mountpoint -q "${JUICEFS_MOUNT_POINT}" 2>/dev/null; then
        fusermount -uz "${JUICEFS_MOUNT_POINT}" 2>/dev/null || umount -l "${JUICEFS_MOUNT_POINT}" 2>/dev/null || true
    fi
    # Wait for session to expire (TTL ~60s) before destroy
    echo "Waiting for session to expire..." | tee -a "${RESULT_FILE}"
    sleep 65
    # Destroy volume (non-interactive)
    UUID=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "${UUID}" ]; then
        echo "Destroying JuiceFS volume..." | tee -a "${RESULT_FILE}"
        juicefs destroy "${METADATA_URL}" "${UUID}" --yes 2>&1 | tail -5 | tee -a "${RESULT_FILE}"
    fi
    rm -f /tmp/juicefs-test-* 2>/dev/null || true
}

do_format() {
    echo "" | tee -a "${RESULT_FILE}"
    echo ">>> Formatting JuiceFS (storage=${STORAGE})..." | tee -a "${RESULT_FILE}"

    if [ "${STORAGE}" = "ceph" ]; then
        # 方向三：去 RGW，JuiceFS 直连 RADOS（librados）。无需 bucket/AK/SK。
        # --access-key = Ceph 集群名（通常 ceph）
        # --secret-key = Ceph 用户名（keyring 存在 /etc/ceph/ceph.client.<user>.keyring）
        unset ACCESS_KEY SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
        juicefs format \
            --storage ceph \
            --bucket "${BUCKET_URL}" \
            --access-key ceph \
            --secret-key client.juicefs \
            --trash-days 0 \
            ${EXTRA_FORMAT_OPTS} \
            "${METADATA_URL}" \
            "${JUICEFS_FS_NAME}" 2>&1 | tee -a "${RESULT_FILE}"
    else
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        export AWS_DEFAULT_REGION=""
        # Pre-create bucket
        if command -v aws &>/dev/null; then
            aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 mb "s3://${JUICEFS_FS_NAME}" 2>/dev/null || true
        fi
        juicefs format \
            --storage s3 \
            --bucket "${BUCKET_URL}" \
            --access-key "${AWS_ACCESS_KEY_ID}" \
            --secret-key "${AWS_SECRET_ACCESS_KEY}" \
            --trash-days 0 \
            ${EXTRA_FORMAT_OPTS} \
            "${METADATA_URL}" \
            "${JUICEFS_FS_NAME}" 2>&1 | tee -a "${RESULT_FILE}"
    fi
    echo "Format OK." | tee -a "${RESULT_FILE}"
}

do_mount() {
    echo "" | tee -a "${RESULT_FILE}"
    echo ">>> Mounting JuiceFS..." | tee -a "${RESULT_FILE}"
    sudo mkdir -p "${JUICEFS_MOUNT_POINT}"
    sudo chown $(whoami):$(whoami) "${JUICEFS_MOUNT_POINT}" 2>/dev/null || true

    juicefs mount -d ${EXTRA_MOUNT_OPTS} "${METADATA_URL}" "${JUICEFS_MOUNT_POINT}" 2>&1 | tee -a "${RESULT_FILE}"
    sleep 3

    if ! mountpoint -q "${JUICEFS_MOUNT_POINT}"; then
        fail "Mount failed!"
    fi
    echo "Mount OK." | tee -a "${RESULT_FILE}"
}

# Verify the data bucket is truly empty after destroy; if any objects remain
# (destroy interrupted, async leftovers, etc.) force-empty it before re-format,
# so a new volume never reuses stale objects. Aborts if it cannot be emptied.
ensure_bucket_empty() {
    [ "${STORAGE}" = "ceph" ] && { echo "STORAGE=ceph: no S3 bucket, skip bucket verify (destroy clears RADOS objects)." | tee -a "${RESULT_FILE}"; return 0; }
    command -v aws &>/dev/null || { echo "WARN: aws cli missing, skip bucket verify." | tee -a "${RESULT_FILE}"; return 0; }
    local n
    n=$(aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl \
            s3api list-objects-v2 --bucket "${JUICEFS_FS_NAME}" \
            --query 'length(Contents)' --output text 2>/dev/null || echo "None")
    [ "${n}" = "None" ] && n=0
    if [ "${n}" != "0" ]; then
        echo ">>> Bucket still has ${n} objects after destroy — force-emptying..." | tee -a "${RESULT_FILE}"
        aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl \
            s3 rm "s3://${JUICEFS_FS_NAME}" --recursive 2>&1 | tail -3 | tee -a "${RESULT_FILE}"
        n=$(aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl \
                s3api list-objects-v2 --bucket "${JUICEFS_FS_NAME}" \
                --query 'length(Contents)' --output text 2>/dev/null || echo "None")
        [ "${n}" = "None" ] && n=0
        [ "${n}" != "0" ] && fail "Bucket still not empty (${n} objects) after force-empty; aborting to avoid stale-data contamination."
    fi
    echo "Bucket verified empty." | tee -a "${RESULT_FILE}"
}

# Provision a brand-new empty volume: destroy current → verify/empty bucket →
# format → mount. Used before each random case so they never share data/objects
# (same effect as a manual `deploy-juicefs.sh destroy`, plus a bucket check).
fresh_volume() {
    echo "" | tee -a "${RESULT_FILE}"
    echo ">>> Provisioning fresh volume (destroy → verify bucket → format → mount)..." | tee -a "${RESULT_FILE}"
    do_cleanup
    sleep 2
    ensure_bucket_empty
    do_format
    do_mount
    mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
}

# Between layout and the random test, set the desired cache state:
#   WARMUP=1 → hot: `juicefs warmup` preloads test_dir into local cache, caches NOT dropped
#              (1.6 缓存/warmup 热态口径，测缓存命中上限)
#   WARMUP=0 → cold: drop OS page cache + JuiceFS read cache so IO hits the backend
#              (默认真值口径)
prime_cache_or_drop() {
    if [ "${WARMUP}" = "1" ]; then
        echo ">>> WARMUP=1: warming up test_dir into local cache (hot mode, caches kept)..." | tee -a "${RESULT_FILE}"
        juicefs warmup "${JUICEFS_MOUNT_POINT}/test_dir" 2>&1 | tail -5 | tee -a "${RESULT_FILE}" || true
    else
        echo ">>> WARMUP=0: dropping caches (cold mode, backend真值)..." | tee -a "${RESULT_FILE}"
        drop_caches
    fi
}

# ============================================================
echo "========================================" | tee "${RESULT_FILE}"
echo "JuiceFS Benchmark — ${LABEL}" | tee -a "${RESULT_FILE}"
echo "Date: $(date)" | tee -a "${RESULT_FILE}"
echo "Config: ${METADATA_URL}" | tee -a "${RESULT_FILE}"
echo "Extra mount opts: ${EXTRA_MOUNT_OPTS}" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "" | tee -a "${RESULT_FILE}"

# ============================================================
# Gate: SKIP_LAYOUT=1 → skip destroy/format/mount/layout, go to randread directly
# ============================================================
if [ "${SKIP_LAYOUT}" = "1" ]; then
    echo ">>> SKIP_LAYOUT=1: reusing existing volume + layout, jumping to randread (step 9)." | tee -a "${RESULT_FILE}"
else

# ============================================================
# 1. Destroy any leftover (clean start)
# ============================================================
echo ">>> Destroying any previous volume..." | tee -a "${RESULT_FILE}"
do_cleanup 2>/dev/null || true
sleep 2

# ============================================================
# 2. Format
# ============================================================
do_format

# ============================================================
# 3. Mount
# ============================================================
do_mount

# ============================================================
# 4-7. Sequential Tests (skippable via SKIP_SEQ=1)
# ============================================================
if [ "${SKIP_SEQ}" = "1" ]; then
    echo "" | tee -a "${RESULT_FILE}"
    echo ">>> SKIP_SEQ=1: skipping sequential tests (step 4-7), jumping to layout + random." | tee -a "${RESULT_FILE}"
else
# ============================================================
# 4. Sequential Read Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Sequential Read Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=sequential-read --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=read --refill_buffers --bs=4M --size=4G 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 5. Sequential Write Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Sequential Write Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=sequential-write --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 6. Multi-job Sequential Read Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Multi-job Sequential Read Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=big-file-multi-read --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 2>&1 | tee -a "${RESULT_FILE}"

# ============================================================
# 7. Multi-job Sequential Write Test
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Multi-job Sequential Write Test" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --name=big-file-multi-write --directory="${JUICEFS_MOUNT_POINT}/test_dir/" \
    --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 2>&1 | tee -a "${RESULT_FILE}"
fi

# ============================================================
# 8. Layout (pre-fill data for randread — once)
#    一次性写入 LAYOUT_NUMJOBS × LAYOUT_FILESIZE 的数据（每 job 一个独立文件）。
#    步骤 9 randread 复用这批文件（同 --name=storage_test，同 numjobs/filesize）。
#    关键：纯 randread 必须读到这里铺好的真实数据，因此：
#      - 布局不用 --create_on_open（文件实打实建出来），不用 --nrfiles（避免 1G 被拆成
#        100 个 10MB 小文件，与 randread 的文件模型对不齐导致 short read 空转）；
#      - 每 job 一个 --filesize 的文件，randread 用同样的 job/filesize 打开它们读。
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Layout (pre-fill for randread, ${LAYOUT_NUMJOBS} jobs × ${LAYOUT_FILESIZE})" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
mkdir -p "${JUICEFS_MOUNT_POINT}/test_dir"
fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
    --name=storage_test \
    --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=4M \
    --rw=write --numjobs="${LAYOUT_NUMJOBS}" --fallocate=none \
    --group_reporting --end_fsync=1 2>&1 | tee -a "${RESULT_FILE}"

# Gate: DO_LAYOUT_ONLY=1 → layout done, exit (volume preserved for SKIP_LAYOUT=1 reuse)
if [ "${DO_LAYOUT_ONLY}" = "1" ]; then
    echo "" | tee -a "${RESULT_FILE}"
    echo ">>> DO_LAYOUT_ONLY=1: layout complete, exiting (volume preserved). Reuse with SKIP_LAYOUT=1." | tee -a "${RESULT_FILE}"
    exit 0
fi

fi   # end SKIP_LAYOUT=0 block (steps 1-8)

# ============================================================
# 9. Random Read Test (pure, acceptance spec)
#    复用步骤 8 布局的文件（同 --name/--numjobs/--filesize）。
#    无 --create_on_open（文件已存在，只读不建）、无 --nrfiles，确保不再 short read 空转。
#    bs=256k/iodepth=128/direct=1/time_based 保持验收规格。
#    仅 drop_caches（或 WARMUP=1 时 warmup），直接跑 randread。
#    重复 REPEAT 次（复用布局，每次仅 +~60s），排除单次波动。
# ============================================================
for i in $(seq 1 "${REPEAT}"); do
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Random Read Test (pure, spec params, rw=randread, ${LAYOUT_NUMJOBS} jobs × ${LAYOUT_FILESIZE}) [run ${i}/${REPEAT}]" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
prime_cache_or_drop
fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
    --name=storage_test \
    --filesize="${LAYOUT_FILESIZE}" \
    --size="${LAYOUT_FILESIZE}" \
    --bs=256k \
    --rw=randread \
    --ioengine=libaio \
    --iodepth=128 \
    --numjobs="${LAYOUT_NUMJOBS}" \
    --direct=1 \
    --fallocate=none \
    --group_reporting \
    --time_based \
    --runtime=60s 2>&1 | tee -a "${RESULT_FILE}"
done

# ============================================================
# Gate: SKIP_RANDWRITE=1 → skip all random write/rw steps
# ============================================================
if [ "${SKIP_RANDWRITE}" = "1" ]; then
    echo "" | tee -a "${RESULT_FILE}"
    if [ "${SKIP_LAYOUT}" = "1" ]; then
        echo ">>> SKIP_RANDWRITE=1 SKIP_LAYOUT=1: skipping random write/rw tests, exiting (volume preserved)." | tee -a "${RESULT_FILE}"
        exit 0
    fi
    echo ">>> SKIP_RANDWRITE=1: skipping random write/rw tests (step 9a-11), going to cleanup." | tee -a "${RESULT_FILE}"
    do_cleanup
    exit 0
fi

# ============================================================
# 9a. Pure Random Write (analysis, reuse layout files)
#    复用步骤 8 布局文件，不 fresh_volume、不 --create_on_open。
#    目的：隔离文件创建开销，测量已有数据上的纯稳态随机写。
#    重复 REPEAT 次。
# ============================================================
for i in $(seq 1 "${REPEAT}"); do
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Random Write Test (analysis, reuse layout, rw=randwrite, ${LAYOUT_NUMJOBS} jobs) [run ${i}/${REPEAT}]" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
prime_cache_or_drop
fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
    --name=storage_test \
    --filesize="${LAYOUT_FILESIZE}" \
    --size="${LAYOUT_FILESIZE}" \
    --bs=256k \
    --rw=randwrite \
    --ioengine=libaio \
    --iodepth=128 \
    --numjobs="${LAYOUT_NUMJOBS}" \
    --direct=1 \
    --fallocate=none \
    --openfiles=100 \
    --group_reporting \
    --time_based \
    --runtime=60s 2>&1 | tee -a "${RESULT_FILE}"
done

# ============================================================
# 9b. Random Read/Write Mixed (analysis, reuse layout files)
#    复用步骤 8 布局文件，不 fresh_volume、不 --create_on_open、不 --nrfiles。
#    目的：消除"读打到零数据区"的偏差，读写全在已有真实数据上进行。
#    重复 REPEAT 次。
# ============================================================
for i in $(seq 1 "${REPEAT}"); do
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Random Read/Write Mixed Test (analysis, reuse layout, rw=randrw, ${LAYOUT_NUMJOBS} jobs) [run ${i}/${REPEAT}]" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
prime_cache_or_drop
fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
    --name=storage_test \
    --filesize="${LAYOUT_FILESIZE}" \
    --size="${LAYOUT_FILESIZE}" \
    --bs=256k \
    --rw=randrw \
    --ioengine=libaio \
    --iodepth=128 \
    --numjobs="${LAYOUT_NUMJOBS}" \
    --direct=1 \
    --fallocate=none \
    --openfiles=100 \
    --group_reporting \
    --time_based \
    --runtime=60s 2>&1 | tee -a "${RESULT_FILE}"
done

# ============================================================
# Gate: SKIP_LAYOUT=1 → skip spec randwrite/randrw (need fresh volume) + skip cleanup (preserve volume)
# ============================================================
if [ "${SKIP_LAYOUT}" = "1" ]; then
    echo "" | tee -a "${RESULT_FILE}"
    echo ">>> SKIP_LAYOUT=1: skipping spec randwrite/randrw (step 10-11, require fresh volume), exiting (volume preserved)." | tee -a "${RESULT_FILE}"
    exit 0
fi

# ============================================================
# 10. Random Write Test (pure, acceptance spec)
#    纯随机写：fresh_volume 建新卷，--create_on_open=1 自建文件。
#    重复 REPEAT 次；每次都 fresh_volume，确保每次都在全新空卷上测（成本较高）。
# ============================================================
for i in $(seq 1 "${REPEAT}"); do
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Random Write Test (pure, spec params, rw=randwrite) [run ${i}/${REPEAT}]" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
fresh_volume
fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
    --name=storage_test \
    --nrfiles=100 \
    --filesize=1G \
    --size=1G \
    --bs=256k \
    --rw=randwrite \
    --ioengine=libaio \
    --iodepth=128 \
    --numjobs=128 \
    --direct=1 \
    --fallocate=none \
    --create_on_open=1 \
    --openfiles=100 \
    --group_reporting \
    --time_based \
    --runtime=60s 2>&1 | tee -a "${RESULT_FILE}"
done

# ============================================================
# 11. Random Read/Write Mixed Test (acceptance spec — verbatim)
#    符合规格的混合随机读写：fresh_volume + --create_on_open=1 自建文件。
#    WARMUP=1 时：先在小布局上 warmup（仅热态口径用）。
#    重复 REPEAT 次；每次都 fresh_volume，确保每次都在全新空卷上测（成本较高）。
# ============================================================
for i in $(seq 1 "${REPEAT}"); do
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Random Read/Write Mixed Test (acceptance spec, verbatim) [run ${i}/${REPEAT}]" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
fresh_volume
if [ "${WARMUP}" = "1" ]; then
    echo ">>> WARMUP=1: laying out files then warming up before randrw (hot mode)..." | tee -a "${RESULT_FILE}"
    fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
        --name=storage_test \
        --nrfiles=100 --filesize="${LAYOUT_FILESIZE}" --size="${LAYOUT_FILESIZE}" --bs=4M \
        --rw=write --numjobs=16 --fallocate=none --create_on_open=1 \
        --openfiles=100 --group_reporting --end_fsync=1 2>&1 | tail -5 | tee -a "${RESULT_FILE}"
    prime_cache_or_drop
fi
fio --directory="${JUICEFS_MOUNT_POINT}/test_dir" \
    --name=storage_test \
    --nrfiles=100 \
    --filesize=1G \
    --size=1G \
    --bs=256k \
    --rw=randrw \
    --ioengine=libaio \
    --iodepth=128 \
    --numjobs=128 \
    --direct=1 \
    --fallocate=none \
    --create_on_open=1 \
    --openfiles=100 \
    --group_reporting \
    --time_based \
    --runtime=60s 2>&1 | tee -a "${RESULT_FILE}"
done

# ============================================================
# 12. Cleanup + Destroy
# ============================================================
echo "" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"
echo "Test Complete — Destroying Volume" | tee -a "${RESULT_FILE}"
echo "========================================" | tee -a "${RESULT_FILE}"

rm -rf "${JUICEFS_MOUNT_POINT}/test_dir"
do_cleanup

echo "" | tee -a "${RESULT_FILE}"
echo "Results saved to: ${RESULT_FILE}" | tee -a "${RESULT_FILE}"
echo "Done." | tee -a "${RESULT_FILE}"
