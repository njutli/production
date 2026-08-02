#!/bin/bash
set -euo pipefail
export LC_ALL=C

# P0-5-SENSITIVITY.sh — 单进程 randread ra-default vs ra0 灵敏度验证
#
# 验证问题：V3 单进程 randread（1G 工作集，15GB 缓存）能否测出 ra0 vs default 的已知差异？
# 已知 128-job 下 ra0/default = 1.72x（V2 四轮一致）。
# 若单进程测不出 → "稳但瞎"，基线不可用于 A/B 判定，需增大工作集。
# 若测出（同方向）→ 单进程基线可用于调优。
#
# 前提：V3 主测试已完成 --layout（layout 文件存在）
#
# 用法：
#   bash P0-5-SENSITIVITY.sh dry-run
#   bash P0-5-SENSITIVITY.sh S 180 5
#
# 遵循：SYSTEM-SAFETY-SKILL.md

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/opencode-fullbaseline-v3"
NIC_IF="enp139s0f0np0"
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

LABEL="${1:-S}"
RUNTIME=180
REPEAT=5
LAYOUT_SIZE="1G"
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

# ===== Helpers（与 V3 一致）=====

drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    local ok_count=0
    for ip in "${SLAVES[@]}"; do
        if ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null; then
            ok_count=$((ok_count+1))
        fi
    done
    if [ "${ok_count}" -lt 3 ]; then log "  ⚠️ drop_caches: ${ok_count}/3"; fi
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

deterministic_warmup() {
    log "  warmup: 顺序读 128G layout"
    local count=0
    for f in ${TEST_DIR}/storage_test.*.0; do
        [ -f "$f" ] || continue
        dd if="$f" of=/dev/null bs=4M 2>/dev/null
        count=$((count+1))
    done
    log "  warmup done: ${count} files"
    compact_cooldown
    drop_caches
}

remount_jfs() {
    local opts="$1"
    log "  remount JuiceFS（${opts}）"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5
    for try in 1 2 3; do
        juicefs mount -d ${opts} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: remount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

collect_hitrate() {
    local tag="$1"
    local outdir="$2"
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local hit_bytes=0 miss_bytes=0 onode_hits=0 onode_misses=0
    for osd in ${osd_list}; do
        read -r h m oh om < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
b=d.get("bluestore",{})
print(int(b.get("buffer_hit_bytes",0)), int(b.get("buffer_miss_bytes",0)), int(b.get("onode_hits",0)), int(b.get("onode_misses",0)))
' 2>/dev/null || echo "0 0 0 0")
        hit_bytes=$((hit_bytes + h))
        miss_bytes=$((miss_bytes + m))
        onode_hits=$((onode_hits + oh))
        onode_misses=$((onode_misses + om))
    done
    echo "${tag} ts=$(date +%s) hit_bytes=${hit_bytes} miss_bytes=${miss_bytes} onode_hits=${onode_hits} onode_misses=${onode_misses}" >> "${outdir}/hit-rate.txt"
}

run_fio() {
    local label="$1"; shift
    local subdir="${RESULTS}/${LABEL}/${label}"
    mkdir -p "${subdir}"
    rm -f "${subdir}/hit-rate.txt" 2>/dev/null || true
    drop_caches
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) \
        > "${subdir}/nic.txt" & local nic_pid=$!
    sudo ceph pg dump pgs_brief 2>/dev/null > "${subdir}/pg-map.txt" || true
    collect_hitrate "pre" "${subdir}"
    log "  fio ${label}..."
    fio "$@" --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" || true
    collect_hitrate "post" "${subdir}"
    local hitrate
    hitrate=$(python3 - "${subdir}/hit-rate.txt" <<'PYEOF' 2>/dev/null || echo "N/A"
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
pre = post = None
for l in lines:
    if l.startswith("pre "): pre = l
    if l.startswith("post "): post = l
if not pre or not post: sys.exit(0)
def parse(l):
    d = {}
    for p in l.split()[1:]:
        k,v = p.split("=",1); d[k] = int(v)
    return d
pd, ps = parse(pre), parse(post)
dh = ps["hit_bytes"] - pd["hit_bytes"]
dm = ps["miss_bytes"] - pd["miss_bytes"]
hit_pct = dh/(dh+dm)*100 if (dh+dm)>0 else 0
print(f"hit_rate={hit_pct:.2f}%")
PYEOF
    )
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw
    bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
    log "  ${label}: BW=${bw:-N/A} MiB/s  ${hitrate}"
}

# ===== 测试逻辑 =====

test_config() {
    local config_name="$1"
    local mount_opts="$2"
    remount_jfs "${mount_opts}"
    deterministic_warmup
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randread-${LABEL}-${config_name}-r${r}" --directory="${TEST_DIR}" --name=storage_test \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=1 \
            --direct=1 --fallocate=none --openfiles=1 \
            --group_reporting --time_based --runtime=${RUNTIME}
    done
}

# ===== 汇总 =====

summary() {
    log "=== 汇总 ${LABEL}（单进程 randread ra-default vs ra0）==="
    for config in default ra0; do
        local line="  ${config}:"
        for r in $(seq 1 "${REPEAT}"); do
            local bw
            bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/randread-${LABEL}-${config}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
            line="${line} r${r}=${bw:-NA}"
        done
        log "${line}"
    done
    # 比值计算
    local def_med ra0_med
    def_med=$(python3 -c "
import statistics,glob,os,re
vals=[]
for r in range(1,${REPEAT}+1):
    f='${RESULTS}/${LABEL}/randread-${LABEL}-default-r%d/fio.txt' % r
    if os.path.exists(f):
        m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
        if m: vals.append(float(m.group(1)))
print('%.0f' % statistics.median(vals) if vals else 'NA')
" 2>/dev/null || echo "NA")
    ra0_med=$(python3 -c "
import statistics,glob,os,re
vals=[]
for r in range(1,${REPEAT}+1):
    f='${RESULTS}/${LABEL}/randread-${LABEL}-ra0-r%d/fio.txt' % r
    if os.path.exists(f):
        m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
        if m: vals.append(float(m.group(1)))
print('%.0f' % statistics.median(vals) if vals else 'NA')
" 2>/dev/null || echo "NA")
    log "  default median=${def_med} MiB/s  ra0 median=${ra0_med} MiB/s"
    if [ "${def_med}" != "NA" ] && [ "${ra0_med}" != "NA" ] && [ "${def_med}" != "0" ]; then
        local ratio
        ratio=$(python3 -c "print('%.2f' % (${ra0_med}/${def_med}))" 2>/dev/null || echo "N/A")
        log "  ra0/default = ${ratio}x"
        log "  已知 128-job 比值 = 1.72x"
        python3 -c "
r=${ra0_med}/${def_med}
if r > 1.2: print('  ✅ 单进程测出 ra0 > default（方向一致）')
elif r < 0.8: print('  ✅ 单进程测出 ra0 < default（方向一致，seqread 权衡）')
else: print('  ❌ 单进程测不出差异（稳但瞎），需增大工作集')
" 2>/dev/null || true
    fi
}

# ===== 入口 =====

case "${1:-}" in
    dry-run)
        log "=== DRY-RUN（P0-5 灵敏度验证）==="
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        mount | grep -q juice && log "JuiceFS 挂载: ✅" || log "JuiceFS 挂载: ❌"
        [ -f "${TEST_DIR}/storage_test.0.0" ] && log "layout: ✅" || log "layout: ❌ 不存在（需先跑 V3 --layout）"
        log "  用法: bash $0 <LABEL> 180 5"
        log "  预期耗时: ~1h（2 轮 × warmup 12min + 5×3.5min）"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT]"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-5}"
        ;;
esac

log "============================================"
log "=== P0-5 灵敏度验证 label=${LABEL} ==="
log "=== 单进程 randread: ra-default vs ra0 ==="
log "=== 验证 1G 工作集能否测出已知 1.72x 差异 ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || {
    echo "${HEALTH}" | grep -q "clock skew" && log "  ⚠️ clock skew，继续" || { log "ERROR: health 非 OK"; exit 1; }
}
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }
[ -f "${TEST_DIR}/storage_test.0.0" ] || { log "ERROR: layout 不存在"; exit 1; }

# Round 1: ra-default
log "=== ${LABEL}: ra-default ==="
test_config "default" "--max-uploads 150 --cache-size 0"

# Round 2: ra0
log "=== ${LABEL}: ra0 ==="
test_config "ra0" "--max-uploads 150 --cache-size 0 --max-readahead 0"

# 汇总
summary
log "=== ${LABEL} DONE ==="
