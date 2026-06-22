#!/bin/bash
# ============================================================
# L1 localization — bare RADOS 256K random read on the EC pool (no JuiceFS/FUSE)
# (10 文档 步骤 A · L1：把 2.5× 读放大切第一刀 —— "网络/EC 层" vs "JuiceFS 内部")
#
# 目的：在 juicefs-data(EC 4+2) 池上跑 256K 对象的裸随机读（绕开 JuiceFS/FUSE，
#       直接 librados→EC→网络），同时采集发起节点网卡 RX/TX，算出
#         放大倍数 = 网卡 RX ÷ rados bench 有效读带宽
#       与 JuiceFS 单客户端 randread 的 RX/有效读 ~2.5× 对照：
#         L1 ≈ 2.5×  → 放大在 librados/EC/网络层（JuiceFS 无辜）
#         L1 ≈ 1.x   → 放大在 JuiceFS 内部（需 L2 CephFS 再切一刀区分 FUSE）
#
# 关键口径（否则不可比，参见 10 文档）：
#   - 对象大小 -b 262144(=256K)，与 JuiceFS 256K 卷对齐（不是默认 4M！）
#   - 并发扫 -t（默认 16 128），尽量逼近 JuiceFS iodepth/numjobs=128
#   - 从干净客户端(tikv-node)单点发起，OSD 主机当发起方会 RX/TX 混算
#   - 跑前先 write --no-cleanup 垫够对象，保证 rand 读到真实冷数据
#
# 用法: bash tests/bench-rados-256k-rand.sh [label]
# env:
#   CEPH_POOL=juicefs-data   目标池
#   RUNTIME=60               每次 rand 时长(s)
#   THREADS="16 128"         并发档(空格分隔，逐档跑)
#   PREFILL=120              write 垫数据时长(s)，对象数需 ≥ 并发*带宽*RUNTIME 才不重复读
#   NIC=eno1                 采样网卡
# 注意：长跑应由 setsid 后台启动；本脚本不依赖 JuiceFS，不动任何卷。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "${SCRIPT_DIR}")"
[ -f "${PROD_DIR}/config.sh" ] && source "${PROD_DIR}/config.sh"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY 2>/dev/null

LABEL="${1:-rados-256k-rand}"
CEPH_POOL="${CEPH_POOL:-juicefs-data}"
RUNTIME="${RUNTIME:-60}"
THREADS="${THREADS:-16 128}"
PREFILL="${PREFILL:-120}"
NIC="${NIC:-eno1}"
OBJSIZE=262144   # 256K, MUST match JuiceFS 256K volume object size
CLIENT="rados-l1-$(hostname)"

RES_DIR="${PROD_DIR}/results"
mkdir -p "${RES_DIR}"
TS=$(date +%Y%m%d-%H%M%S)
OUT="${RES_DIR}/rados-256k-rand-${LABEL}-${TS}.txt"
log() { echo "$@" | tee -a "${OUT}"; }

# ---- NIC counters via /proc/net/dev (portable, no extra tools) ----
nic_bytes() {  # -> "rxBytes txBytes" for local $NIC
    awk -v n="${NIC}" '$1 ~ n":" {gsub(/:/," "); print $2, $10}' /proc/net/dev
}

run_rand() {  # $1=threads ; runs rand for RUNTIME with concurrent NIC sampling
    local t="$1"
    log ""
    log "======================================================"
    log ">>> rados bench RAND  pool=${CEPH_POOL}  -b 256K  -t ${t}  ${RUNTIME}s"
    log "======================================================"
    # snapshot NIC, launch rand, snapshot NIC after
    local s e srx stx erx etx
    s=$(nic_bytes); srx=${s% *}; stx=${s#* }
    rados bench -p "${CEPH_POOL}" "${RUNTIME}" rand -b "${OBJSIZE}" -t "${t}" \
        --run-name "${CLIENT}" 2>&1 | tee -a "${OUT}" > "${OUT}.rand.t${t}"
    e=$(nic_bytes); erx=${e% *}; etx=${e#* }

    local rxmb txmb bw
    rxmb=$(awk "BEGIN{printf \"%.1f\", (${erx}-${srx})/1048576/${RUNTIME}}")
    txmb=$(awk "BEGIN{printf \"%.1f\", (${etx}-${stx})/1048576/${RUNTIME}}")
    # rados bench prints "Bandwidth (MB/sec): NNN"
    bw=$(grep -i "Bandwidth (MB/sec)" "${OUT}.rand.t${t}" | awk '{print $NF}' | head -1)
    local ampl="n/a"
    [ -n "${bw}" ] && ampl=$(awk "BEGIN{ if(${bw}+0>0) printf \"%.2f\", ${rxmb}/${bw}; else print \"n/a\" }")

    log "---- L1 RESULT (t=${t}) ----"
    log "  rados bench rand bandwidth (effective read) : ${bw:-?} MB/s"
    log "  NIC ${NIC} RX over window                    : ${rxmb} MB/s"
    log "  NIC ${NIC} TX over window                    : ${txmb} MB/s"
    log "  >>> amplification  RX/effective              : ${ampl}x"
    log "      (compare vs JuiceFS single-client ~2.5x:"
    log "         ~2.5x => amplification in librados/EC/network;"
    log "         ~1.x  => amplification inside JuiceFS, go L2 CephFS)"
}

log "======================================================"
log "L1 bare-RADOS 256K random-read localization"
log "host=$(hostname)  pool=${CEPH_POOL}  obj=256K  runtime=${RUNTIME}s  threads='${THREADS}'  nic=${NIC}"
log "ts=${TS}"
log "======================================================"

# ---- 0. sanity: ceph reachable ----
if ! rados -p "${CEPH_POOL}" ls >/dev/null 2>&1; then
    log "FATAL: cannot access pool '${CEPH_POOL}' via rados (check ceph.conf/keyring)."
    exit 1
fi

# ---- 1. prefill objects so rand reads real cold data (write --no-cleanup) ----
log ""
log ">>> Prefilling ${CEPH_POOL} with 256K objects for ${PREFILL}s (write --no-cleanup)..."
rados bench -p "${CEPH_POOL}" "${PREFILL}" write -b "${OBJSIZE}" -t 16 \
    --no-cleanup --run-name "${CLIENT}" 2>&1 | tee -a "${OUT}" | tail -8

# ---- 2. rand sweep over thread counts ----
for t in ${THREADS}; do
    run_rand "${t}"
done

# ---- 3. cleanup the objects we wrote ----
log ""
log ">>> Cleaning up prefill objects (rados cleanup --run-name ${CLIENT})..."
rados -p "${CEPH_POOL}" cleanup --run-name "${CLIENT}" 2>&1 | tail -3 | tee -a "${OUT}" || true

log ""
log ">>> DONE. Full output: ${OUT}"
log ">>> Per-thread raw: ${OUT}.rand.t*"
