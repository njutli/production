#!/bin/bash
set -euo pipefail
export LC_ALL=C

# stability-test.sh — 精简稳定性测试（基于 V4-COMPACT-TEST）
#
# ⚠️ 2026-08-05：本脚本验证过的四项措施（每轮 gc --compact / PG 门禁 / 统一口径判据 / ITEMS）
#    已全部并入 ../FULLBASELINE_V4.sh，此文件**冻结、不再维护，勿用于出数**。
#    基线与调优一律用 FULLBASELINE_V4.sh（ITEMS 可裁剪成单项）。
#
# 只跑 randread + randrw + randwrite（3 项 × 5 轮），验证 gc --compact + remount 下的：
#   - 单轮内多次 repeat 稳定性
#   - 多轮全量测试间的跨轮稳定性
#
# 与 V4-COMPACT-TEST 的唯一差异：跳过 seqread/mseqread/seqwrite/mseqwrite 4 项
# 其他（run_fio/数据采集/aggressive_cleanup/set_cache_config/reset_state）完全一致
#
# 用法：
#   bash stability-test.sh S1 180 5          # 默认 30GB 缓存
#   CACHE_SIZE_GB=100 bash stability-test.sh S1 180 5  # 100GB 缓存
#
# 遵循：SYSTEM-SAFETY-SKILL.md

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v4"
POOL_DATA="juicefs-data"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-A}"
RUNTIME=180
REPEAT=5
DO_LAYOUT=false
DO_REMOUNT=false
ALLOW_RESTART=false
LAYOUT_JOBS=128
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"
LAYOUT_SIZE="1G"
SEQ_SIZE="32G"
MSEQ_JOBS=16
MSEQ_SIZE="4G"
DISK_SPACE_MIN_GB=20
CACHE_SIZE_GB="${CACHE_SIZE_GB:-30}"
RANDREAD_REPEAT="${RANDREAD_REPEAT:-10}"
# ===== PG 门禁（2026-08-04 加）=====
# 依据：pg128 重建测试中 pg_autoscale 把 pg_num 从 128 一路并到 32，
# 整个 S1 都在 backfill/peering 中测，randread 轮间波动 17.8%；
# 合并结束（pg_num=32 全 active+clean）后同一负载轮间 CV 仅 0.25%。
PG_GATE="${PG_GATE:-true}"            # false 关闭门禁
PG_NUM_EXPECT="${PG_NUM_EXPECT:-32}"  # 期望 pg_num（同时要求 pgp_num 一致）
PG_GATE_WAIT="${PG_GATE_WAIT:-1800}"  # PG 未 clean 时最长等待秒数
SKIP_ROUNDS="${SKIP_ROUNDS:-0}"       # 稳态统计额外弃前 N 轮
PG_GATE_STATUS="CLEAN"
# ===== 测试项选择（2026-08-05 加，默认与原行为一致）=====
# 依据：S3→S4 跨运行 randread 差 +8.0%（轮内 CV 仅 0.45-0.52%），
# 需要一次只读运行（ITEMS="randread"）判断该 8% 是首运行效应/写后效应/单调上漂。
# 测试规格（runtime/numjobs/bs/size/文件）一律不改，只改"跑哪几项"。
ITEMS="${ITEMS:-randread randrw randwrite}"
# ===== 稳定性判据（2026-08-05 定，读写共用 L2/L3；L1 见 gear_stat）=====
# L2 轮间（同一运行内）：极差幅度 ≤10% 且 max_dev ≤5% 且 CV ≤3%，三条同时满足
# L3 跨运行：与 REF_LABEL 的 median 偏差 ≤5%，且两跑合并后极差幅度仍 ≤10%
L2_RANGE_MAX="${L2_RANGE_MAX:-10}"
L2_MAXDEV_MAX="${L2_MAXDEV_MAX:-5}"
L2_CV_MAX="${L2_CV_MAX:-3}"
L3_DEV_MAX="${L3_DEV_MAX:-5}"
REF_LABEL="${REF_LABEL:-}"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

safety_check() {
    local t="$1"
    [ -n "$t" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$t" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${t:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
}

# ===== Helpers =====

check_disk_space() {
    local avail_blocks block_size avail_gb
    avail_blocks=$(stat -f -c '%a' / 2>/dev/null)
    block_size=$(stat -f -c '%S' / 2>/dev/null)
    avail_gb=$((avail_blocks * block_size / 1024 / 1024 / 1024))
    if [ "${avail_gb}" -lt "${DISK_SPACE_MIN_GB}" ]; then
        log "FATAL: 根分区余量 ${avail_gb}G < ${DISK_SPACE_MIN_GB}G，abort"
        exit 1
    fi
    log "  根分区余量: ${avail_gb}G"
}

# ===== PG 门禁 / PG 摘要 / 双模守卫（2026-08-04 加）=====

pool_id() {
    sudo ceph osd pool ls detail 2>/dev/null | grep -oP "^pool \K[0-9]+(?= '${POOL_DATA}')" | head -1
}

# 输出: pool_id pg_num pgp_num autoscale pg_count nonclean
pg_state_snapshot() {
    local pid pgn pgp asc dump total nonclean
    pid=$(pool_id || true)
    if [ -z "${pid}" ]; then echo "NA NA NA NA NA NA"; return 0; fi
    pgn=$(sudo ceph osd pool get "${POOL_DATA}" pg_num 2>/dev/null | awk '{print $2}' || true)
    pgp=$(sudo ceph osd pool get "${POOL_DATA}" pgp_num 2>/dev/null | awk '{print $2}' || true)
    asc=$(sudo ceph osd pool get "${POOL_DATA}" pg_autoscale_mode 2>/dev/null | awk '{print $2}' || true)
    dump=$(sudo ceph pg dump pgs_brief 2>/dev/null || true)
    total=$(echo "${dump}" | awk -v p="${pid}." 'NR>1 && index($1,p)==1 {c++} END{print c+0}')
    nonclean=$(echo "${dump}" | awk -v p="${pid}." 'NR>1 && index($1,p)==1 && $2!="active+clean" {c++} END{print c+0}')
    echo "${pid} ${pgn:-NA} ${pgp:-NA} ${asc:-NA} ${total} ${nonclean}"
}

# 每轮开测前门禁：pg_num == PG_NUM_EXPECT 且 pgp_num 一致 且全部 active+clean
pg_gate() {
    PG_GATE_STATUS="CLEAN"
    if [ "${PG_GATE}" != "true" ]; then PG_GATE_STATUS="DISABLED"; return 0; fi
    local waited=0 pid pgn pgp asc total nonclean reason
    while :; do
        read -r pid pgn pgp asc total nonclean < <(pg_state_snapshot)
        reason=""
        [ "${pgn}" = "${PG_NUM_EXPECT}" ] || reason="pg_num=${pgn}!=${PG_NUM_EXPECT}"
        [ "${pgp}" = "${pgn}" ] || reason="${reason} pgp_num=${pgp}!=pg_num=${pgn}"
        [ "${total}" = "${pgn}" ] || reason="${reason} pg_count=${total}!=pg_num=${pgn}"
        [ "${nonclean}" = "0" ] || reason="${reason} nonclean=${nonclean}"
        if [ -z "${reason}" ]; then
            [ "${asc}" = "off" ] || log "  ⚠️ PG 门禁: pg_autoscale_mode=${asc}（应为 off，否则 pg_num 会在测试中漂移）"
            [ "${waited}" -gt 0 ] && log "  PG 门禁 ✅（等待 ${waited}s 后 pg_num=${pgn} 全 active+clean）"
            return 0
        fi
        if [ "${waited}" -ge "${PG_GATE_WAIT}" ]; then
            PG_GATE_STATUS="UNSTABLE:$(echo ${reason} | tr ' ' ',')"
            log "  🔴 PG 门禁超时 ${waited}s：${reason} — 本轮标记 PG_UNSTABLE，不计入稳态统计"
            return 0
        fi
        [ "${waited}" = "0" ] && log "  ⏳ PG 门禁等待（每 30s 复查）：${reason}"
        sleep 30; waited=$((waited+30))
    done
}

# 每轮 PG 摘要：pg_count / nonclean / primary 分布（主流量倾斜是双模的候选来源）
pg_summary() {
    local outdir="$1" pid
    pid=$(pool_id || true)
    [ -n "${pid}" ] || return 0
    awk -v p="${pid}." '
        NR>1 && index($1,p)==1 { n++; if ($2!="active+clean") nc++; prim[$NF]++ }
        END {
            d="";
            for (i=0;i<16;i++) if (i in prim) d=d sprintf("%s%d:%d",(d==""?"":" "),i,prim[i])
            printf "pg_count=%d nonclean=%d primary=[%s]\n", n+0, nc+0, d
        }
    ' "${outdir}/pg-map.txt" > "${outdir}/pg-summary.txt" 2>/dev/null || true
    log "  pg: $(cat "${outdir}/pg-summary.txt" 2>/dev/null || echo NA)"
}

# 双模守卫：逐秒聚合 BW 做 1-D 2-means，输出两档中心 + 快档时间占比
# 轮间波动的直接观测量 = fast_frac（档位中心跨轮固定，只有占比在变）
gear_stat() {
    local outdir="$1" label="$2" direction=0 kind=read
    case "${label}" in
        randrw*) direction=0 ;;
        *write*) direction=1; kind=write ;;
    esac
    # L1 判据（2026-08-05 加）：读项 stall ≤1% 且逐秒 CV <6% 为干净轮；
    # 写项因 FUSE flush/sync 天生双模（实测 stall 1.2-22.3%），只记录不判 PASS/FAIL。
    python3 - "${outdir}" "${direction}" "${kind}" > "${outdir}/gear.txt" 2>/dev/null <<'PYEOF' || true
import sys, os, glob, statistics
from collections import defaultdict
outdir, direction = sys.argv[1], int(sys.argv[2])
kind = sys.argv[3] if len(sys.argv) > 3 else "read"
L1_STALL_MAX, L1_CV_MAX = 1.0, 6.0
per = defaultdict(float)
for f in glob.glob(os.path.join(outdir, "*_bw.*.log")):
    for line in open(f):
        p = line.strip().split(",")
        if len(p) < 3:
            continue
        try:
            s = int(p[0]) // 1000; bw = float(p[1]); d = int(p[2])
        except ValueError:
            continue
        if d == direction:
            per[s] += bw
ks = sorted(per)
if not ks:
    print("gear=N/A"); sys.exit(0)
t0 = ks[0]
v = [per[k] / 1024.0 for k in ks if 15 <= k - t0 <= 175]
if len(v) < 20:
    print("gear=N/A (samples=%d)" % len(v)); sys.exit(0)
sv = sorted(v); n = len(sv)
med = statistics.median(sv)
# 掉底秒（<50% median，通常是 1s 级 stall）单独计数，不参与聚类，避免把离群点当成一个档
stall = 100.0 * sum(1 for x in v if x < 0.5 * med) / n
lo_t, hi_t = sv[int(0.02 * n)], sv[min(n - 1, int(0.98 * n))]
core = [x for x in v if lo_t <= x <= hi_t and x >= 0.5 * med]
if len(core) < 20:
    core = [x for x in v if x >= 0.5 * med] or v
lo, hi = min(core), max(core)
c1, c2 = lo + (hi - lo) * 0.25, lo + (hi - lo) * 0.75
for _ in range(50):
    g1 = [x for x in core if abs(x - c1) <= abs(x - c2)]
    g2 = [x for x in core if abs(x - c1) > abs(x - c2)]
    if not g1 or not g2:
        break
    n1, n2 = statistics.mean(g1), statistics.mean(g2)
    done = abs(n1 - c1) < 0.1 and abs(n2 - c2) < 0.1
    c1, c2 = n1, n2
    if done:
        break
g2 = [x for x in core if abs(x - c1) > abs(x - c2)]
sec_cv = statistics.pstdev(v) / statistics.mean(v) * 100
if kind == "write":
    l1 = "L1=NA(write)"
else:
    l1 = "L1=%s" % ("PASS" if (stall <= L1_STALL_MAX and sec_cv < L1_CV_MAX) else "FAIL")
print("gear slow=%.0f fast=%.0f sep=%.1f%% fast_frac=%.1f%% stall=%.1f%% p10=%.0f p50=%.0f p90=%.0f cv=%.1f%% n=%d %s" % (
    c1, c2, (c2 / c1 - 1) * 100 if c1 else 0, 100.0 * len(g2) / len(core), stall,
    sv[int(0.1 * n)], med, sv[int(0.9 * n)],
    sec_cv, n, l1))
PYEOF
    log "  $(cat "${outdir}/gear.txt" 2>/dev/null || echo 'gear=N/A')"
}

drop_caches() {
    sync -f "${MNT}" 2>/dev/null || true; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    local ok_count=0
    for ip in "${SLAVES[@]}"; do
        if ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
            ok_count=$((ok_count+1))
        fi
    done
    if [ "${ok_count}" -lt 3 ]; then
        log "  ⚠️ drop_caches: ${ok_count}/3 节点成功"
    fi
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    local done_ok=false
    for i in $(seq 1 60); do
        local all_done=true
        for osd in ${osd_list}; do
            local running queued
            read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
                'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
            if [ "$running" != "0" ]; then all_done=false; fi
            if [ "$queued" != "0" ]; then all_done=false; fi
        done
        $all_done && { done_ok=true; break; }
        sleep 5
    done
    $done_ok && log "  compact ✅ (~$((i*5))s)" || log "  ⚠️ compact 超时"
}

aggressive_cleanup() {
    log "  aggressive_cleanup"
    compact_cooldown
    sleep 30
    compact_cooldown
    log "  juicefs gc --compact (清理切片碎片)"
    set +e
    juicefs gc --compact "${META}" 2>&1 | tail -3
    set -e
    log "  gc --compact done"
    drop_caches
}

deterministic_warmup() {
    log "  warmup: 顺序读全部 layout + prep 文件"
    local count=0
    for f in ${TEST_DIR}/storage_test.*.0 ${TEST_DIR}/read_test.*.0 ${TEST_DIR}/rw_test.*.0 \
             ${TEST_DIR}/seqread/seqread.*.0 ${TEST_DIR}/mseqread/mseqread.*.0 \
             ${TEST_DIR}/seqwrite/seqwrite.*.0 ${TEST_DIR}/mseqwrite/mseqwrite.*.0; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
        count=$((count+1))
    done
    log "  warmup done: ${count} files"
    compact_cooldown
    drop_caches
}

mount_jfs() {
    if mount | grep -q juice; then
        log "  JuiceFS 已挂载，跳过 format + mount"
        mkdir -p "${TEST_DIR}"
        return 0
    fi
    juicefs format --storage ceph --bucket ceph://${POOL_DATA} --access-key ceph \
        --secret-key client.juicefs --block-size 256K --trash-days 0 --force \
        "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

remount_jfs() {
    log "  remount JuiceFS（参数: ${JUICEFS_MOUNT_OPTS}）"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: remount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

set_cache_config() {
    local cache_bytes=$((CACHE_SIZE_GB * 1024 * 1024 * 1024))
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    log "  set cache: autotune=false, size=${CACHE_SIZE_GB}GB (onode=$((CACHE_SIZE_GB/20))GB, kv=$((CACHE_SIZE_GB*3/10))GB, data=$((CACHE_SIZE_GB*13/20))GB)"
    for osd in ${osd_list}; do
        sudo ceph config set osd.${osd} bluestore_cache_autotune false 2>/dev/null || true
        sudo ceph config set osd.${osd} bluestore_cache_size ${cache_bytes} 2>/dev/null || true
        sudo ceph config set osd.${osd} bluestore_cache_meta_ratio 0.05 2>/dev/null || true
        sudo ceph config set osd.${osd} bluestore_cache_kv_ratio 0.30 2>/dev/null || true
        sudo ceph config set osd.${osd} bluestore_cache_data_ratio 0.65 2>/dev/null || true
    done
    for osd in ${osd_list}; do
        sudo ceph tell osd.${osd} injectargs --bluestore_cache_autotune false --bluestore_cache_size ${cache_bytes} 2>/dev/null || true
    done
    log "  cache config done"
}

reset_state() {
    log "=== reset_state ==="
    log "  juicefs gc --compact"
    set +e
    juicefs gc --compact "${META}" 2>&1 | tail -3
    set -e
    log "  gc --compact done"
    compact_cooldown
    drop_caches
    log "  remount JuiceFS"
    remount_jfs
}

# hit% 采集：6 OSD 聚合，pre/post 差分
collect_hitrate() {
    local tag="$1"; local outdir="$2"
    local osd_list; osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local hb=0 mb=0 oh=0 om=0
    for osd in ${osd_list}; do
        read -r h m o_h o_m < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c '
import sys,json;b=json.load(sys.stdin).get("bluestore",{})
print(int(b.get("buffer_hit_bytes",0)),int(b.get("buffer_miss_bytes",0)),int(b.get("onode_hits",0)),int(b.get("onode_misses",0)))
' 2>/dev/null || echo "0 0 0 0")
        hb=$((hb+h)); mb=$((mb+m)); oh=$((oh+o_h)); om=$((om+o_m))
    done
    echo "${tag} ts=$(date +%s) hit_bytes=${hb} miss_bytes=${mb} onode_hits=${oh} onode_misses=${om}" >> "${outdir}/hit-rate.txt"
}

# C_amp 守卫：NIC 首末差分 ÷ fio 读字节
compute_c_amp() {
    local nic_file="$1"; local fio_file="$2"; local outdir="$3"
    python3 - "${nic_file}" "${fio_file}" 2>/dev/null >> "${outdir}/c_amp.txt" <<'PYEOF' || true
import sys, re

nic_file, fio_file = sys.argv[1], sys.argv[2]

# NIC RX 首末差分
lines = [l.strip() for l in open(nic_file) if l.strip()]
if len(lines) < 2:
    print("c_amp=N/A (nic too short)")
    sys.exit(0)

def get_rx_bytes(line):
    parts = line.split("|")
    if len(parts) < 2:
        return 0
    fields = parts[1].split()
    for i, f in enumerate(fields):
        if "bytes" in f:
            return int(f.split(":")[1].replace(",", ""))
    # fallback: look for the RX bytes field (usually index 1)
    stats = parts[1].split()
    return int(stats[1]) if len(stats) > 1 else 0

first_rx = get_rx_bytes(lines[0])
last_rx = get_rx_bytes(lines[-1])
nic_delta = last_rx - first_rx

# fio 读字节
fio_text = open(fio_file).read()
m = re.search(r'READ:.*?io=([0-9.]+)([KMG]iB)', fio_text)
if m:
    val = float(m.group(1))
    unit = m.group(2)
    if unit == "GiB": fio_bytes = val * 1024**3
    elif unit == "MiB": fio_bytes = val * 1024**2
    elif unit == "KiB": fio_bytes = val * 1024
    else: fio_bytes = val
else:
    fio_bytes = 0

if fio_bytes > 0:
    c_amp = nic_delta / fio_bytes
    status = ""
    if c_amp < 0.9 or c_amp > 2.2:
        status = " ⚠️ OUT OF RANGE"
    print("c_amp=%.2f (nic_delta=%d fio_read=%d)%s" % (c_amp, nic_delta, fio_bytes, status))
else:
    print("c_amp=N/A (no fio io= found)")
PYEOF
}

# ===== Fio 运行器 =====

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"
    mkdir -p "${subdir}"
    rm -f "${subdir}/hit-rate.txt" "${subdir}/PG_UNSTABLE.txt" 2>/dev/null || true
    pg_gate
    drop_caches
    local load_pre
    load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    # NIC 采集
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    # 配置快照（Opus S0.4）
    mount | grep juice | head -1 > "${subdir}/mount-cmd.txt" 2>/dev/null || true
    sudo ceph config dump 2>/dev/null | md5sum | awk '{print $1}' > "${subdir}/config-md5.txt" 2>/dev/null || true
    sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json;d=json.load(sys.stdin)
print(" ".join("%d:%d"%(o["osd"],o.get("up_from",0)) for o in sorted(d["osds"],key=lambda x:x["osd"])))
' 2>/dev/null > "${subdir}/up_from.txt" || true
    # jfs-stats PRE
    local jfs_pid
    jfs_pid=$(pgrep -f 'juicefs.*mount' | head -1 || true)
    if [ -n "${jfs_pid}" ]; then
        { echo "=== PRE $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-pre.txt"
    fi
    # pg-map 采集 + PG 摘要 + 门禁结论落盘
    sudo ceph pg dump pgs_brief 2>/dev/null > "${subdir}/pg-map.txt" || true
    pg_summary "${subdir}"
    case "${PG_GATE_STATUS}" in
        UNSTABLE:*) echo "${PG_GATE_STATUS} $(date '+%F %T')" > "${subdir}/PG_UNSTABLE.txt" ;;
    esac
    # hit% PRE
    collect_hitrate "pre" "${subdir}"
    # fio
    log "  fio ${label}..."
    local fio_timeout=$((RUNTIME + 120))
    set +e
    timeout "${fio_timeout}" fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt"
    local fio_rc=${PIPESTATUS[0]}
    set -e
    local invalid_reason=""
    if [ "${fio_rc}" = "124" ] || [ "${fio_rc}" = "137" ]; then
        invalid_reason="timeout>${fio_timeout}s(rc=${fio_rc})"
    elif [ "${fio_rc}" != "0" ]; then
        invalid_reason="fio_exit=${fio_rc}"
    elif ! grep -qE '^[[:space:]]*(READ|WRITE):' "${subdir}/fio.txt"; then
        invalid_reason="no_fio_summary"
    fi
    # hit% POST
    collect_hitrate "post" "${subdir}"
    # C_amp 守卫
    compute_c_amp "${subdir}/nic.txt" "${subdir}/fio.txt" "${subdir}"
    # jfs-stats POST
    if [ -n "${jfs_pid:-}" ]; then
        { echo "=== POST $(date '+%H:%M:%S') ==="; sudo cat /proc/${jfs_pid}/status 2>/dev/null | grep -E 'VmRSS|Threads' || true; timeout 5 cat /mnt/juicefs/.stats 2>/dev/null || echo "(.stats N/A)"; } > "${subdir}/jfs-stats-post.txt"
    fi
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    echo "load_post: $(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)" >> "${subdir}/weka-load.txt"
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    gear_stat "${subdir}" "${label}"
    local bw
    bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
    local hr
    hr=$(python3 - "${subdir}/hit-rate.txt" 2>/dev/null <<'PYEOF' || echo "N/A"
import sys
L=[l.strip() for l in open(sys.argv[1]) if l.strip()]
p=q=None
for l in L:
    if l.startswith("pre "): p=l
    if l.startswith("post "): q=l
if not p or not q: sys.exit(0)
def pa(l):
    d={}
    for x in l.split()[1:]: k,v=x.split("=",1); d[k]=int(v)
    return d
pd,qd=pa(p),pa(q)
dh=qd["hit_bytes"]-pd["hit_bytes"]; dm=qd["miss_bytes"]-pd["miss_bytes"]
print("hit_rate=%.1f%%"%(dh/(dh+dm)*100) if (dh+dm)>0 else "hit_rate=N/A")
PYEOF
    )
    if [ -z "${bw:-}" ] && [ -z "${invalid_reason}" ]; then
        invalid_reason="bw_unparsable"
    fi
    if [ -n "${invalid_reason}" ]; then
        echo "INVALID ${label} reason=${invalid_reason} $(date '+%F %T')" > "${subdir}/INVALID.txt"
        log "  ${label}: ❌ INVALID (${invalid_reason}) — 不计入统计"
    else
        log "  ${label}: BW=${bw:-N/A} MiB/s  ${hr}"
    fi
    [ -f "${RESULTS}/rounds.tsv" ] || printf 'LABEL\tround\tBW_MiBs\thit\tstatus\tpg_gate\tpg\tgear\n' > "${RESULTS}/rounds.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${LABEL}" "${label}" "${bw:-NA}" "${hr}" "${invalid_reason:-VALID}" \
        "${PG_GATE_STATUS}" "$(head -1 "${subdir}/pg-summary.txt" 2>/dev/null || echo NA)" \
        "$(head -1 "${subdir}/gear.txt" 2>/dev/null || echo NA)" >> "${RESULTS}/rounds.tsv"
}

# ===== Phase 0: 一次性 layout =====

phase0_layout() {
    log "=== Phase 0: 一次性 layout ==="
    safety_check "${TEST_DIR}"
    mount_jfs
    check_disk_space
    rm -rf "${TEST_DIR}"/* 2>/dev/null || true
    mkdir -p "${TEST_DIR}/seqread" "${TEST_DIR}/seqwrite" "${TEST_DIR}/mseqread" "${TEST_DIR}/mseqwrite"
    # 主 layout（128×1G，用于 randwrite 覆盖写）
    log "  layout: storage_test ${LAYOUT_JOBS}×${LAYOUT_SIZE} (bs=4M)"
    fio --directory="${TEST_DIR}" --name=storage_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # 读项专用文件（randread 用，永不被写测试覆盖）
    log "  layout: read_test ${LAYOUT_JOBS}×${LAYOUT_SIZE} (randread 专用)"
    fio --directory="${TEST_DIR}" --name=read_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # 读写项专用文件（randrw 用）
    log "  layout: rw_test ${LAYOUT_JOBS}×${LAYOUT_SIZE} (randrw 专用)"
    fio --directory="${TEST_DIR}" --name=rw_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=${LAYOUT_JOBS} --fallocate=none --direct=1 \
        --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
    # seqread prep
    log "  seqread prep: ${SEQ_SIZE}"
    fio --name=seqread --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
    # seqwrite prep
    log "  seqwrite prep: ${SEQ_SIZE}"
    fio --name=seqwrite --directory="${TEST_DIR}/seqwrite/" --rw=write --bs=4M --size=${SEQ_SIZE} --direct=1 >/dev/null 2>&1
    # mseqread prep
    log "  mseqread prep: ${MSEQ_JOBS}×${MSEQ_SIZE}"
    fio --name=mseqread --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
    # mseqwrite prep
    log "  mseqwrite prep: ${MSEQ_JOBS}×${MSEQ_SIZE}"
    fio --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" --rw=write --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} --direct=1 >/dev/null 2>&1
    compact_cooldown
    drop_caches
    # 布局指纹
    local crush_md5 uuid phase0_ts osd_stat osd_up_from
    crush_md5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    phase0_ts=$(date +%s)
    osd_stat=$(sudo ceph osd stat 2>/dev/null)
    osd_up_from=$(sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(" ".join("%d:%d" % (o["osd"], o.get("up_from",0)) for o in sorted(d["osds"], key=lambda x:x["osd"])))
' 2>/dev/null || echo "N/A")
    {
        echo "UUID=${uuid}"
        echo "PHASE0_TS=${phase0_ts}"
        echo "CRUSHMD5=${crush_md5}"
        echo "OSD_STAT=${osd_stat}"
        echo "OSD_UP_FROM=${osd_up_from}"
    } > "${RESULTS}/guard-baseline.txt"
    log "  layout done. UUID=${uuid} CRUSH=${crush_md5} TS=${phase0_ts}"
    log "  OSD up_from: ${osd_up_from}"
}

# ===== 7 项（128-job，读项/写项文件分离）=====

item_seqread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqread-${LABEL}-r${r}" --name=seqread --directory="${TEST_DIR}/seqread/" \
            --rw=read --refill_buffers --bs=256k --size=${SEQ_SIZE} \
            --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
    done
}

item_mseqread() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqread-${LABEL}-r${r}" --name=mseqread --directory="${TEST_DIR}/mseqread/" \
            --rw=read --refill_buffers --bs=256k --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
    done
}

item_randread() {
    # 用 read_test.*.0（专用，永不被写测试覆盖）
    for r in $(seq 1 "${RANDREAD_REPEAT}"); do
        run_fio "randread-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=read_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
    done
}

item_randrw() {
    # 用 rw_test.*.0（专用，与 randread 隔离）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randrw-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=rw_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
    done
}

item_seqwrite() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "seqwrite-${LABEL}-r${r}" --name=seqwrite --directory="${TEST_DIR}/seqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${SEQ_SIZE} \
            --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        compact_cooldown
    done
}

item_mseqwrite() {
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "mseqwrite-${LABEL}-r${r}" --name=mseqwrite --directory="${TEST_DIR}/mseqwrite/" \
            --rw=write --refill_buffers --bs=4M --size=${MSEQ_SIZE} --numjobs=${MSEQ_JOBS} \
            --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
            --time_based --runtime=${RUNTIME}
        compact_cooldown
    done
    aggressive_cleanup
}

item_randwrite() {
    # 用 storage_test.*.0（覆盖写）
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randwrite-${LABEL}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
            --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
            --group_reporting --time_based --runtime=${RUNTIME}
        aggressive_cleanup
    done
}

# ===== softclean =====

soft_clean_restart() {
    log "=== SOFT-CLEAN（compact + drop_caches）==="
    compact_cooldown
    drop_caches
    sleep 10
}

# ===== 汇总 =====

summary() {
    log "=== 汇总 ${LABEL} (fio BW, MiB/s) ==="
    for item in seqread mseqread randread randrw seqwrite mseqwrite randwrite; do
        local line="  ${item}:"
        local item_repeat="${REPEAT}"
        [ "$item" = "randread" ] && item_repeat="${RANDREAD_REPEAT}"
        for r in $(seq 1 "${item_repeat}"); do
            local bw
            bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/${item}-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
            line="${line} r${r}=${bw:-NA}"
        done
        log "${line}"
    done
    # 布局指纹复查
    local current_uuid current_crush current_up_from base_uuid base_crush base_up_from
    current_uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    current_crush=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    current_up_from=$(sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(" ".join("%d:%d" % (o["osd"], o.get("up_from",0)) for o in sorted(d["osds"], key=lambda x:x["osd"])))
' 2>/dev/null || echo "N/A")
    base_uuid=$(grep '^UUID=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_crush=$(grep '^CRUSHMD5=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_up_from=$(grep '^OSD_UP_FROM=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    if [ "${base_uuid}" != "N/A" ]; then
        [ "${current_uuid}" = "${base_uuid}" ] && log "  ✅ UUID 不变" || log "  🔴 UUID 变了!"
        [ "${current_crush}" = "${base_crush}" ] && log "  ✅ CRUSH 不变" || log "  🔴 CRUSH 变了!"
        [ "${current_up_from}" = "${base_up_from}" ] && log "  ✅ up_from 不变" || log "  ⚠️ up_from 变了"
    fi
}

# ===== 稳态评估 =====

steady_state_eval() {
    log "=== 稳态评估（bw_log 截前15s 取中位数）==="
    python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, re, statistics, glob
from collections import defaultdict

base = "${RESULTS}/${LABEL}"
repeat = ${REPEAT}
randread_repeat = ${RANDREAD_REPEAT}
read_trim = 15
skip_rounds = ${SKIP_ROUNDS}
# 判据（2026-08-05 定）：L2 轮间三条同时满足；L3 跨运行 median 偏差 ≤5%
L2_RANGE_MAX = ${L2_RANGE_MAX}
L2_MAXDEV_MAX = ${L2_MAXDEV_MAX}
L2_CV_MAX = ${L2_CV_MAX}
L3_DEV_MAX = ${L3_DEV_MAX}
ref_label = "${REF_LABEL}"

item_cfg = {
    "seqread":   (0, read_trim),
    "mseqread":  (0, read_trim),
    "randread":  (0, read_trim),
    "randrw":    (0, read_trim),
    "seqwrite":  (1, read_trim),
    "mseqwrite": (1, read_trim),
    "randwrite": (1, read_trim),
}

def parse_bwlog(subdir, direction, trim_sec):
    files = sorted(glob.glob(os.path.join(subdir, "*_bw.*.log")))
    if not files:
        return None
    per_sec = defaultdict(float)
    for f in files:
        for line in open(f):
            parts = line.strip().split(",")
            if len(parts) < 3:
                continue
            try:
                sec = int(parts[0]) // 1000
                bw = float(parts[1])
                d = int(parts[2])
                if d == direction:
                    per_sec[sec] += bw
            except (ValueError, IndexError):
                pass
    all_vals = [(s, v) for s, v in sorted(per_sec.items()) if s >= trim_sec]
    if not all_vals:
        return None
    return statistics.median([v for _, v in all_vals])

def bw_from_fio(f):
    if os.path.exists(f):
        m = re.search(r'(?:READ|WRITE):.*?bw=([0-9.]+)MiB', open(f).read())
        if m:
            return float(m.group(1)) * 1024
    return None

items = ["seqread", "mseqread", "randread", "randrw", "seqwrite", "mseqwrite", "randwrite"]

def collect(lbl, item, direction, trim):
    """返回 (fio汇总BW列表, 逐秒中位数列表, 轮号, 排除说明)"""
    b = os.path.join("${RESULTS}", lbl)
    fio_vals, sec_vals, rounds, excluded = [], [], [], []
    for r in range(1, (randread_repeat if item == "randread" else repeat) + 1):
        subdir = os.path.join(b, "%s-%s-r%d" % (item, lbl, r))
        if not os.path.isdir(subdir):
            continue
        if os.path.exists(os.path.join(subdir, "INVALID.txt")):
            excluded.append("r%d:INVALID" % r); continue
        if os.path.exists(os.path.join(subdir, "PG_UNSTABLE.txt")):
            excluded.append("r%d:PG_UNSTABLE" % r); continue
        f = bw_from_fio(os.path.join(subdir, "fio.txt"))
        s = parse_bwlog(subdir, direction, trim)
        if f is None and s is None:
            continue
        rounds.append(r)
        fio_vals.append((f if f is not None else s) / 1024)
        sec_vals.append((s if s is not None else f) / 1024)
    return fio_vals, sec_vals, rounds, excluded

def stats(vs):
    med = statistics.median(vs)
    cv = statistics.stdev(vs) / statistics.mean(vs) * 100 if len(vs) > 1 else 0
    max_dev = max(abs(v - med) for v in vs) / med * 100 if med else 0
    rng = (max(vs) - min(vs)) / med * 100 if med else 0
    return med, cv, max_dev, rng

for item in items:
    direction, trim = item_cfg[item]
    fio_vals, sec_vals, rounds, excluded = collect("${LABEL}", item, direction, trim)

    def report(suffix, vf, vs_sec):
        med, cv, max_dev, rng = stats(vf)
        # L2 判据（2026-08-05 加）：轮间 极差幅度 ≤10% 且 max_dev ≤5% 且 CV ≤3%，
        # 三者缺一不可 —— 单用 CV 会漏掉单点离群（20 轮里 1 轮掉 10% 只有 CV 2.2%），
        # 单用极差会放过整档跃迁（S3+S4 合并 randread 极差 9.62% 却含 +8.0% 跃迁）。
        v2 = "PASS" if (rng <= L2_RANGE_MAX and max_dev <= L2_MAXDEV_MAX and cv <= L2_CV_MAX) else "FAIL"
        m2, c2, d2, r2 = stats(vs_sec)
        print("  %s%s: n=%d median=%.0f 极差幅度=%.1f%% max_dev=%.1f%% CV=%.1f%% range=%.0f-%.0f MiB/s  L2=%s" % (
            item, suffix, len(vf), med, rng, max_dev, cv, min(vf), max(vf), v2))
        print("    └ 逐秒中位数口径(参考): median=%.0f 极差幅度=%.1f%% max_dev=%.1f%% CV=%.1f%% range=%.0f-%.0f" % (
            m2, r2, d2, c2, min(vs_sec), max(vs_sec)))
        return med

    if fio_vals:
        med_now = report("", fio_vals, sec_vals)
        if skip_rounds > 0 and len(fio_vals) > skip_rounds + 1:
            report("[弃前%d轮]" % skip_rounds, fio_vals[skip_rounds:], sec_vals[skip_rounds:])
        print("    轮值(fio汇总): %s" % " ".join("r%d=%.0f" % (rn, v) for rn, v in zip(rounds, fio_vals)))
        # L3 判据：与参照运行的 median 偏差 ≤5%（跨运行可复现性）
        if ref_label:
            rf, rs, rr, _ = collect(ref_label, item, direction, trim)
            if rf:
                med_ref = statistics.median(rf)
                dev = (med_now - med_ref) / med_ref * 100
                v3 = "PASS" if abs(dev) <= L3_DEV_MAX else "FAIL"
                pool = fio_vals + rf
                _, _, _, rng_pool = stats(pool)
                v3r = "PASS" if rng_pool <= L2_RANGE_MAX else "FAIL"
                print("    └ L3 vs %s: median %.0f→%.0f 偏差=%+.1f%% (判据 ≤%.0f%%) %s | 合并 n=%d 极差幅度=%.1f%% %s" % (
                    ref_label, med_ref, med_now, dev, L3_DEV_MAX, v3, len(pool), rng_pool, v3r))
    else:
        print("  %s: no data" % item)
    if excluded:
        print("    ⚠️ 已排除: %s" % ", ".join(excluded))
PYEOF
}

# ===== 入口 =====

case "${1:-}" in
    softclean|clean)
        soft_clean_restart
        exit 0
        ;;
    dry-run)
        log "=== DRY-RUN ==="
        check_disk_space
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
        log "OSDs up: ${OSD_UP} (期望 6)"
        mount | grep -q juice && log "JuiceFS: ✅" || log "JuiceFS: ❌"
        [ -f "${TEST_DIR}/storage_test.0.0" ] && log "storage_test: ✅" || log "storage_test: ⚠️ 需 --layout"
        [ -f "${TEST_DIR}/read_test.0.0" ] && log "read_test: ✅" || log "read_test: ⚠️ 需 --layout"
        [ -f "${TEST_DIR}/rw_test.0.0" ] && log "rw_test: ✅" || log "rw_test: ⚠️ 需 --layout"
        [ -f "${TEST_DIR}/seqread/seqread.0.0" ] && log "seqread prep: ✅" || log "seqread prep: ⚠️"
        [ -f "${TEST_DIR}/mseqread/mseqread.0.0" ] && log "mseqread prep: ✅" || log "mseqread prep: ⚠️"
        [ -f "${TEST_DIR}/seqwrite/seqwrite.0.0" ] && log "seqwrite prep: ✅" || log "seqwrite prep: ⚠️"
        [ -f "${TEST_DIR}/mseqwrite/mseqwrite.0.0" ] && log "mseqwrite prep: ✅" || log "mseqwrite prep: ⚠️"
        command -v fio >/dev/null && log "fio: ✅" || log "fio: ❌"
        command -v juicefs >/dev/null && log "juicefs: ✅" || log "juicefs: ❌"
        command -v python3 >/dev/null && log "python3: ✅" || log "python3: ❌"
        log "mount 参数: ${JUICEFS_MOUNT_OPTS}"
        log "结果目录: ${RESULTS}"
        log "用法: bash $0 <LABEL> 180 5 --layout"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT] [--layout] [--remount] [--allow-restart]"
        echo "      $0 dry-run"
        echo "      $0 softclean"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-5}"
        for arg in "${@:4}"; do
            if [ "$arg" = "--layout" ]; then DO_LAYOUT=true; fi
            if [ "$arg" = "--remount" ]; then DO_REMOUNT=true; fi
            if [ "$arg" = "--allow-restart" ]; then ALLOW_RESTART=true; fi
        done
        ;;
esac

log "============================================"
log "=== FULLBASELINE V4 label=${LABEL} runtime=${RUNTIME}s repeat=${REPEAT} items=${ITEMS} ==="
log "=== V2 基础 + 确定性预热 + hit% + 文件分离 + C_amp 守卫 ==="
log "=== layout=${DO_LAYOUT} remount=${DO_REMOUNT} ==="
log "=== mount_opts=${JUICEFS_MOUNT_OPTS} ==="
log "=== cache_size=${CACHE_SIZE_GB}GB aggressive_cleanup=gc --compact ==="
log "============================================"

check_disk_space

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || { echo "${HEALTH}" | grep -q "clock skew" && log "  ⚠️ clock skew，继续" || { log "ERROR: health 非 OK"; exit 1; }; }
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

# PG 门禁（开测前必须 pg_num 稳定且全 active+clean，否则整跑作废）
log "PG 状态: $(pg_state_snapshot)  (pool_id pg_num pgp_num autoscale pg_count nonclean)"
pg_gate
case "${PG_GATE_STATUS}" in
    UNSTABLE:*) log "ERROR: PG 未就绪（${PG_GATE_STATUS}），abort。确认要带病测请用 PG_GATE=false"; exit 1 ;;
esac

if [ "${DO_REMOUNT}" = "true" ]; then
    remount_jfs
fi

if [ "${DO_LAYOUT}" = "true" ]; then
    phase0_layout
else
    log "=== 跳过 Phase 0（复用已有 layout）==="
    if ! mount | grep -q juice; then
        log "  JuiceFS 未挂载，re-mount"
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3
        mount | grep -q juice || { log "ERROR: mount failed"; exit 1; }
    fi
    mkdir -p "${TEST_DIR}"
    [ -f "${TEST_DIR}/storage_test.0.0" ] || { log "ERROR: storage_test 不存在，需 --layout"; exit 1; }
    [ -f "${TEST_DIR}/read_test.0.0" ] || { log "ERROR: read_test 不存在，需先跑 --layout"; exit 1; }
    [ -f "${TEST_DIR}/rw_test.0.0" ] || { log "ERROR: rw_test 不存在，需先跑 --layout"; exit 1; }
    log "  layout 数据确认存在，复用（randread/randrw/randwrite）"
    # 布局指纹检查
    current_uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    current_crush=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    current_up_from=$(sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(" ".join("%d:%d" % (o["osd"], o.get("up_from",0)) for o in sorted(d["osds"], key=lambda x:x["osd"])))
' 2>/dev/null || echo "N/A")
    base_uuid=$(grep '^UUID=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_crush=$(grep '^CRUSHMD5=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    base_up_from=$(grep '^OSD_UP_FROM=' "${RESULTS}/guard-baseline.txt" 2>/dev/null | cut -d= -f2- || echo "N/A")
    if [ "${base_uuid}" != "N/A" ]; then
        [ "${current_uuid}" = "${base_uuid}" ] && log "  ✅ UUID 一致" || { log "  🔴 UUID 变了!"; exit 1; }
        [ "${current_crush}" = "${base_crush}" ] && log "  ✅ CRUSH 一致" || { log "  🔴 CRUSH 变了!"; exit 1; }
        if [ "${base_up_from}" != "N/A" ] && [ "${current_up_from}" != "N/A" ]; then
            [ "${current_up_from}" = "${base_up_from}" ] && log "  ✅ up_from 不变" || {
                [ "${ALLOW_RESTART}" = "true" ] && log "  ⚠️ up_from 变了，--allow-restart 已确认" || { log "  🔴 up_from 变了! 需 --allow-restart"; exit 1; }
            }
        fi
    fi
fi

# 缓存配置 + 状态重置（每轮测试前执行）
set_cache_config
reset_state

# 确定性预热
deterministic_warmup

# 3 项测试（不稳定项，验证 gc --compact + remount 下的稳定性）
# ITEMS 可裁剪（如 ITEMS="randread" 做只读运行），规格不变
for _item in ${ITEMS}; do
    case "${_item}" in
        randread)  log "=== ${LABEL}: randread ===";  item_randread ;;
        randrw)    log "=== ${LABEL}: randrw ===";    item_randrw ;;
        randwrite) log "=== ${LABEL}: randwrite ==="; item_randwrite ;;
        *) log "ERROR: 未知 ITEMS 项 '${_item}'（可选 randread/randrw/randwrite）"; exit 1 ;;
    esac
done

summary
steady_state_eval
log "=== ${LABEL} DONE ==="
