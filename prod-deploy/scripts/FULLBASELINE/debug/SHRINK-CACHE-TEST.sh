#!/bin/bash
set -euo pipefail
export LC_ALL=C

# SHRINK-CACHE-TEST.sh — 缩缓存 + 128G 单进程灵敏度验证
#
# 验证：缩 BlueStore cache 后，单进程 128G 工作集 randread 是否"稳定且敏感"
# 流程：清理→建layout→测onode→缩缓存→重启→warmup→ra-default vs ra0→判定
#
# 用法：
#   bash SHRINK-CACHE-TEST.sh dry-run
#   bash SHRINK-CACHE-TEST.sh T 180 5
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

LABEL="${1:-T}"
RUNTIME=180
REPEAT=5
LAYOUT_SIZE="128G"
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/test.log"; }

# ===== Helpers =====

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

aggressive_cleanup() {
    compact_cooldown
    sleep 30
    compact_cooldown
    drop_caches
}

deterministic_warmup() {
    log "  warmup: 顺序读 ${LAYOUT_SIZE} layout"
    local count=0
    for f in ${TEST_DIR}/bigfile*; do
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
lines=[l.strip() for l in open(sys.argv[1]) if l.strip()]
pre=post=None
for l in lines:
    if l.startswith("pre "): pre=l
    if l.startswith("post "): post=l
if not pre or not post: sys.exit(0)
def parse(l):
    d={}
    for p in l.split()[1:]:
        k,v=p.split("=",1); d[k]=int(v)
    return d
pd,ps=parse(pre),parse(post)
dh=ps["hit_bytes"]-pd["hit_bytes"]; dm=ps["miss_bytes"]-pd["miss_bytes"]
hit_pct=dh/(dh+dm)*100 if (dh+dm)>0 else 0
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

# ===== Phase 1: 清理 + 重建 + 建 layout + 测 onode =====

phase1_cleanup_layout() {
    log "=== Phase 1: 清理 + 重建 + 建 layout ==="

    # 1.1 卸载 JuiceFS
    log "  1.1 卸载 JuiceFS"
    fusermount -u "${MNT}" 2>/dev/null || true
    pkill -f 'juicefs.*mount' 2>/dev/null || true
    sleep 5

    # 1.2 销毁旧卷（清空 pool）
    log "  1.2 销毁旧卷（清空 pool）"
    sleep 65
    local uuid
    uuid=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    if [ -n "${uuid}" ]; then
        juicefs destroy --force "${META}" "${uuid}" 2>&1 | tail -3
        log "  destroy done (UUID=${uuid})"
    else
        log "  ⚠️ 无法获取 UUID，跳过 destroy"
    fi

    # 1.3 compact 清理 destroy 产生的 tombstone
    log "  1.3 compact cleanup"
    compact_cooldown

    # 1.4 format + mount
    log "  1.4 format + mount"
    juicefs format --storage ceph --bucket ceph://juicefs-data \
        --access-key ceph --secret-key client.juicefs \
        --block-size 256K --trash-days 0 --force \
        "${META}" juicefs-prod 2>&1 | tail -1
    juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
    sleep 3
    mount | grep -q juice || { log "FATAL: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"

    # 1.5 创建 128G 单文件 layout
    log "  1.5 创建 128G 单文件 layout"
    fio --name=bigfile --directory="${TEST_DIR}" \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} --bs=4M --rw=write \
        --numjobs=1 --direct=1 --ioengine=libaio --iodepth=128 \
        --group_reporting --end_fsync=1 >/dev/null 2>&1
    log "  layout done (bigfile ${LAYOUT_SIZE})"

    # 1.6 compact + drop_caches
    log "  1.6 compact + drop_caches"
    compact_cooldown
    drop_caches

    # 1.7 测 onode 占用
    log "  1.7 测 onode 实际占用（dump_mempools）"
    local osd_list
    osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    local total_onode_mb=0
    for osd in ${osd_list}; do
        local onode_bytes
        onode_bytes=$(timeout 15 sudo ceph tell osd.${osd} dump_mempools 2>/dev/null | \
            python3 -c '
import sys,json
d=json.load(sys.stdin)
total=0
for k,v in d.items():
    if "onode" in k.lower() and isinstance(v,dict) and "bytes" in v:
        total+=v["bytes"]
print(int(total))
' 2>/dev/null || echo "0")
        local onode_mb=$((onode_bytes / 1024 / 1024))
        total_onode_mb=$((total_onode_mb + onode_mb))
        log "  osd.${osd}: onode=${onode_mb} MB"
    done
    log "  总 onode: ${total_onode_mb} MB (6 OSD)"

    # 计算建议缓存大小 = onode × 1.5 + 256MB
    local suggested_cache_mb=$(( total_onode_mb * 3 / 2 + 256 ))
    local suggested_cache_bytes=$(( suggested_cache_mb * 1024 * 1024 ))
    log "  建议缓存: ${suggested_cache_mb} MB (onode×1.5 + 256MB)"

    # 写入文件供 Phase 2 使用
    echo "${suggested_cache_bytes}" > "${RESULTS}/suggested-cache-size.txt"
    echo "${total_onode_mb}" > "${RESULTS}/measured-onode-mb.txt"
}

# ===== Phase 2: 缩缓存 + 重启 OSD =====

phase2_shrink_cache() {
    log "=== Phase 2: 缩缓存 + 重启 OSD ==="

    local cache_bytes
    cache_bytes=$(cat "${RESULTS}/suggested-cache-size.txt")
    local cache_mb=$(( cache_bytes / 1024 / 1024 ))
    log "  2.1 设 bluestore_cache_size=${cache_mb} MB (${cache_bytes} bytes)"

    sudo ceph config set osd bluestore_cache_size "${cache_bytes}"
    log "  config set done, verify:"
    sudo ceph config get osd bluestore_cache_size

    log "  2.2 重启全部 OSD（逐节点）"
    for slave_ip in "${SLAVES[@]}"; do
        log "  restarting OSDs on ${slave_ip}..."
        ${SSHPASS_CMD}@${slave_ip} \
            'for c in $(sudo podman ps --format "{{.Names}}" | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done' 2>/dev/null
        log "  ${slave_ip}: done"
    done

    # 等 OSD 全 up + PG active+clean
    log "  2.3 等 OSD 恢复"
    for i in $(seq 1 60); do
        local pg_line
        pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
        echo -n "."
        echo "$pg_line" | grep -qE "active.*clean" && break
        sleep 5
    done
    echo ""
    local health
    health=$(sudo ceph health 2>/dev/null)
    log "  health: ${health}"

    # compact 清理重启后残留
    log "  2.4 post-restart compact"
    compact_cooldown

    # 确认 layout 仍在
    log "  2.5 确认 layout 存在"
    if [ -f "${TEST_DIR}/bigfile.0.0" ]; then
        log "  ✅ bigfile.0.0 存在"
    else
        log "  ❌ bigfile.0.0 不存在！可能 JuiceFS 需要重新 mount"
        if ! mount | grep -q juice; then
            log "  JuiceFS 未挂载，重新 mount"
            juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
            sleep 3
        fi
        [ -f "${TEST_DIR}/bigfile.0.0" ] && log "  ✅ bigfile.0.0 确认存在" || { log "FATAL: layout 丢失"; exit 1; }
    fi
}

# ===== Phase 3: 灵敏度验证 =====

phase3_sensitivity_test() {
    log "=== Phase 3: 灵敏度验证（ra-default vs ra0）==="

    # 3.1 ra-default
    log "  3.1 ra-default"
    remount_jfs "--max-uploads 150 --cache-size 0"
    deterministic_warmup
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randread-${LABEL}-default-r${r}" --name=bigfile --directory="${TEST_DIR}" \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=1 \
            --direct=1 --fallocate=none --openfiles=1 \
            --group_reporting --time_based --runtime=${RUNTIME}
    done

    # 3.2 ra0
    log "  3.2 ra0"
    remount_jfs "--max-uploads 150 --cache-size 0 --max-readahead 0"
    deterministic_warmup
    for r in $(seq 1 "${REPEAT}"); do
        run_fio "randread-${LABEL}-ra0-r${r}" --name=bigfile --directory="${TEST_DIR}" \
            --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
            --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=1 \
            --direct=1 --fallocate=none --openfiles=1 \
            --group_reporting --time_based --runtime=${RUNTIME}
    done
}

# ===== 汇总 + 判定 =====

summary() {
    log "=== 汇总 ${LABEL}（缩缓存单进程 128G randread）==="
    local cache_mb
    cache_mb=$(cat "${RESULTS}/suggested-cache-size.txt" 2>/dev/null | awk '{print int($1/1024/1024)}')
    local onode_mb
    onode_mb=$(cat "${RESULTS}/measured-onode-mb.txt" 2>/dev/null || echo "N/A")
    log "  bluestore_cache_size: ${cache_mb} MB"
    log "  measured onode: ${onode_mb} MB"

    for config in default ra0; do
        local line="  ${config}:"
        for r in $(seq 1 "${REPEAT}"); do
            local bw
            bw=$(grep -oE 'bw=[0-9.]+MiB' "${RESULTS}/${LABEL}/randread-${LABEL}-${config}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
            line="${line} r${r}=${bw:-NA}"
        done
        log "${line}"
    done

    local def_med ra0_med
    def_med=$(python3 -c "
import statistics,os,re
vals=[]
for r in range(1,${REPEAT}+1):
    f='${RESULTS}/${LABEL}/randread-${LABEL}-default-r%d/fio.txt'%r
    if os.path.exists(f):
        m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
        if m: vals.append(float(m.group(1)))
print('%.0f'%statistics.median(vals) if vals else 'NA')
" 2>/dev/null || echo "NA")
    ra0_med=$(python3 -c "
import statistics,os,re
vals=[]
for r in range(1,${REPEAT}+1):
    f='${RESULTS}/${LABEL}/randread-${LABEL}-ra0-r%d/fio.txt'%r
    if os.path.exists(f):
        m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
        if m: vals.append(float(m.group(1)))
print('%.0f'%statistics.median(vals) if vals else 'NA')
" 2>/dev/null || echo "NA")
    log "  default median=${def_med} MiB/s  ra0 median=${ra0_med} MiB/s"

    if [ "${def_med}" != "NA" ] && [ "${ra0_med}" != "NA" ] && [ "${def_med}" != "0" ]; then
        local ratio
        ratio=$(python3 -c "print('%.2f'%(${ra0_med}/${def_med}))" 2>/dev/null || echo "N/A")
        log "  ra0/default = ${ratio}x  (已知 128-job = 1.72x)"
        python3 -c "
r=${ra0_med}/${def_med}
if r>1.1: print('  ✅ 敏感：ra0 > default（方向一致）')
elif r<0.9: print('  ✅ 敏感：ra0 < default（方向一致）')
else: print('  ❌ 不敏感：测不出差异（稳但瞎）')
" 2>/dev/null || true
    fi

    # CV 判定
    python3 -c "
import statistics,os,re,glob
for config in ['default','ra0']:
    vals=[]
    for r in range(1,${REPEAT}+1):
        f='${RESULTS}/${LABEL}/randread-${LABEL}-%s-r%d/fio.txt'%(config,r)
        if os.path.exists(f):
            m=re.search(r'bw=([0-9.]+)MiB',open(f).read())
            if m: vals.append(float(m.group(1)))
    if len(vals)>1:
        cv=statistics.stdev(vals)/statistics.mean(vals)*100
        med=statistics.median(vals)
        max_dev=max(abs(v-med) for v in vals)/med*100
        if cv<3 and max_dev<5:
            print(f'  ✅ {config} 稳定：CV={cv:.1f}% max_dev={max_dev:.1f}%')
        else:
            print(f'  ❌ {config} 不稳：CV={cv:.1f}% max_dev={max_dev:.1f}%')
" 2>/dev/null || true
}

# ===== 入口 =====

case "${1:-}" in
    dry-run)
        log "=== DRY-RUN（缩缓存灵敏度验证）==="
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        log "ceph health: ${HEALTH}"
        OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
        log "OSDs up: ${OSD_UP} (期望 6)"
        mount | grep -q juice && log "JuiceFS: ✅" || log "JuiceFS: ❌"
        log "current bluestore_cache_size: $(sudo ceph config get osd bluestore_cache_size 2>/dev/null)"
        log ""
        log "  用法: bash $0 <LABEL> 180 5"
        log "  Phase 1: 清理→建layout→测onode (~15min)"
        log "  Phase 2: 缩缓存→重启OSD→等恢复 (~10min)"
        log "  Phase 3: warmup→default 5轮→ra0 5轮 (~50min)"
        log "  预期总耗时: ~75min"
        exit 0
        ;;
    "")
        echo "用法: $0 <LABEL> [RUNTIME] [REPEAT]"
        echo "      $0 dry-run"
        exit 0
        ;;
    *)
        LABEL="$1"; RUNTIME="${2:-180}"; REPEAT="${3:-5}"
        ;;
esac

log "============================================"
log "=== SHRINK-CACHE-TEST label=${LABEL} ==="
log "=== 缓存→测onode→缩缓存→验证灵敏度 ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
log "ceph health: ${HEALTH}"
[ "${HEALTH}" = "HEALTH_OK" ] || {
    echo "${HEALTH}" | grep -q "clock skew" && log "  ⚠️ clock skew，继续" || { log "ERROR: health 非 OK"; exit 1; }
}
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (期望 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: OSD 不全"; exit 1; }

# Phase 1: 清理 + 建 layout + 测 onode
phase1_cleanup_layout

# Phase 2: 缩缓存 + 重启 OSD
phase2_shrink_cache

# Phase 3: 灵敏度验证
phase3_sensitivity_test

# 汇总 + 判定
summary
log "=== ${LABEL} DONE ==="
log ""
log "=== 恢复命令 ==="
log "  sudo ceph config set osd bluestore_cache_size 0  # 恢复 auto"
log "  # 然后重启 OSD 生效"
