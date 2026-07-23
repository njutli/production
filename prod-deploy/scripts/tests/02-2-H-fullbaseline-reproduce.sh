#!/bin/bash
set -e

# 02-2-H 全量基线复现验证  [v1 2026-07-24]
# 目的：确认"全量 9 项基线"在 soft-clean+OSD-restart 口径下【同组两遍可复现】，再上调优手段。
#   顺序（由 orchestrator 编排，本脚本每次跑【一组】全量 9 项）：
#     重建(一次,外部 rebuild-stable-ids.sh) → A → soft-clean → A2 → soft-clean → B → soft-clean → B2
#   - A/A2 = default 组两遍；B/B2 = ra0 组两遍。
#   - 组间清理全部用 soft-clean+OSD-restart（保 pool → pool_id/CRUSH 不变；重置 tmpfs 内存态）。
#   - 全程【一个集群，开头只重建一次】。⚑ 中途不重建：stable-ID 重建也会改 CRUSH 映射(波动源①)，
#     跨重建绝对值不可比。只在开头重建一次建立干净起点，此后靠 soft-clean 保持映射不变。
#
# 判据（本脚本产出数据，判定见任务书 §一）：
#   ① 变量守卫：OSD 集合 + pool_id + CRUSH md5 全程不变（每次运行都比对基线快照文件）。
#   ② 同组复现：|A2-A|/A < 5%、|B2-B|/B < 5%（随机项中位数；顺序项看趋势）。
#   ③ A vs B 冷态可比：同集群 CRUSH 不变 → readahead 效果 = B/A（顺带产出，非本轮判据）。
#
# 用法：./02-2-H-fullbaseline-reproduce.sh <LABEL> [RUNTIME] [REPEAT]
#   LABEL   = A | A2 | B | B2   （前缀 A→default, B→ra0；A2/B2 为同组复现轮）
#           = softclean          （组间清理模式：只做 soft-clean+OSD-restart，不跑测试；用于组之间）
#   RUNTIME = 随机/多流项每次秒数   默认 180（全量基线用长口径）
#   REPEAT  = 随机项每项重复次数     默认 3（取中位）
#
#   完整编排：
#     bash rebuild-stable-ids.sh                       # 开头重建一次
#     ./02-2-H-fullbaseline-reproduce.sh A  180 3      # R-A
#     ./02-2-H-fullbaseline-reproduce.sh softclean     # 组间清理
#     ./02-2-H-fullbaseline-reproduce.sh A2 180 3      # R-A2
#     ./02-2-H-fullbaseline-reproduce.sh softclean
#     ./02-2-H-fullbaseline-reproduce.sh B  180 3      # R-B
#     ./02-2-H-fullbaseline-reproduce.sh softclean
#     ./02-2-H-fullbaseline-reproduce.sh B2 180 3      # R-B2 (末尾自动算 A2/A、B2/B 复现偏差)
#
# 【与 02-2-G 的区别】02-2-G 是短口径验证性测试(只跑 layout+randread+mseqread 证 soft-clean 命题)；
#   本脚本是全量 9 项基线复现(seqread/seqwrite/mseqread/mseqwrite/layout/randwrite-true/randread/randrw/randwrite-ow)。
#   基础设施(soft_clean_restart / 变量守卫 / 起点自检 / 复现契约 / WekaIO 负载门控)沿用 02-2-G。
#   9 项 fio 命令沿用 02-2-p1-full-baseline.sh 的 run_group（口径一致）。
#
# 遵循 skills：TESTING-GUIDE(health/compact cooldown)、test-commands-reference(fio/§8.3)、
#            baseline-reproduction-skill(§2.2/§2.5/§3.1/§4)。
# 红线：157 上 WekaIO 在跑，禁动内核/网卡/RoCE/md0/WekaIO；本脚本不 rebuild OSD、不删 pool。
#   ⚑ soft-clean+OSD-restart 不删 pool → pool_id 不变 → CRUSH 映射不变（与 §9.6 禁止的 delete+recreate 不同）。

# ===== 配置 =====
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-02-2-h-fullbaseline"
NIC_IF="enp139s0f0np0"
POOL_DATA="juicefs-data"
FORENSIC="$(dirname "$0")/rebuild-topology-forensic.sh"
GUARD_BASE="${RESULTS_DIR}/variable-guard-baseline.txt"   # 首次运行(A)写入，后续运行(A2/B/B2)比对
LABEL="${1:-A}"
RUNTIME="${2:-180}"
REPEAT="${3:-3}"
WEKA_LOAD_MAX="${WEKA_LOAD_MAX:-20}"   # 157 共享客户端 1min 负载阈值；超过则读测可能被 WekaIO 抢占污染

case "${LABEL}" in
    A*) RA="default" ;;
    B*) RA="ra0" ;;
    *)  RA="default" ;;
esac

mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# ===== Helpers (与 02-2-G / 02-2-p1 一致) =====
drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
        sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

# compact_cooldown: 强制 compact 并轮询到 compact_running=0 AND compact_queue_len=0（02-2-G v3 修复）。
compact_cooldown() {
    local osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    local done_ok=false
    for i in $(seq 1 120); do   # 最多 120×5s=10min
        all_done=true
        for osd in ${osd_list}; do
            read -r running queued < <(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
            [ "$running" != "0" ] && all_done=false
            [ "$queued" != "0" ] && all_done=false
        done
        $all_done && { done_ok=true; break; }
        sleep 5
    done
    if $done_ok; then
        log "  compact_cooldown ✅ 全 OSD compact_running=0 且 compact_queue_len=0 (耗时 ~$((i*5))s)"
    else
        log "  ⚠️⚠️ compact_cooldown 超时(10min)仍未清空! 数据可能受 compaction 残留污染，须人工排查"
    fi
}

# 组内清卷（juicefs destroy，不 restart OSD）——用于组内 seq→randwrite、randwrite→layout 之间。
clean_volume() {
    log "=== 组内清卷 (juicefs destroy, 保 pool, 不 restart OSD) ==="
    fusermount -u "${MNT}" 2>/dev/null || true; pkill -f 'juicefs.*mount' 2>/dev/null || true; sleep 5
    sleep 65
    local UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    [ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tail -1
    compact_cooldown
    sleep 10
}

# restart_osds: 重启 OSD 但【不删 pool】→ pool_id/CRUSH 映射不变，仅重置 tmpfs/RocksDB 内存态。
restart_osds() {
    log "--- restart OSDs (重置 tmpfs/RocksDB 内存态；不删 pool → 映射不变) ---"
    for slave_ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
        sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${slave_ip} '
            for c in $(sudo podman ps --format "{{.Names}}" 2>/dev/null | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done
            for svc in $(systemctl list-units "ceph-osd@*" --no-legend 2>/dev/null | grep active | awk "{print \$1}"); do
                sudo systemctl reset-failed "$svc" 2>/dev/null || true; sudo systemctl restart "$svc" 2>/dev/null || true
            done' 2>/dev/null || true
    done
    log "等待 PG active+clean..."
    for i in $(seq 1 60); do
        pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
        echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
        sleep 5
    done
}

# soft-clean + OSD restart：组间清理（A→A2→B→B2 之间）。清数据(保 pool → 映射不变) + 重置 OSD 内存态。
# ⚑ 与 §9.6 禁止的 pool delete+recreate 不同：这里不删 pool，pool_id 不变，映射不变。
soft_clean_restart() {
    log "=== SOFT-CLEAN + OSD-RESTART (juicefs destroy 保留 pool + restart OSD 重置 tmpfs 内存态) ==="
    fusermount -u "${MNT}" 2>/dev/null || true; pkill -f 'juicefs.*mount' 2>/dev/null || true; sleep 5
    sleep 65
    local UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    [ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tail -1
    compact_cooldown
    local objs=$(sudo rados df -p "${POOL_DATA}" 2>/dev/null | awk -v p="${POOL_DATA}" '$1==p{print $3}')
    log "destroy 后 ${POOL_DATA} 对象数=${objs:-NA}"
    restart_osds                # ⚑ 重置 tmpfs/RocksDB 内存态（不删 pool）
    compact_cooldown            # restart 后再压一次，确保 compact_running=0
    drop_caches
    sleep 10
}

mount_jfs() {
    local opts="--max-uploads 150 --cache-size 0"
    [ "${RA}" = "ra0" ] && opts="$opts --max-readahead 0"
    juicefs format --storage ceph --bucket ceph://${POOL_DATA} --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 --force "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        juicefs mount -d $opts "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep juice | grep -q "max_read=" && break; sleep 10
    done
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "Mounted ${LABEL} (max_read=$(mount | grep juice | grep -o 'max_read=[0-9]*'))"
}

run_fio() {
    local label="$1"; local subdir="${RESULTS_DIR}/${LABEL}/${label}"; mkdir -p "${subdir}"
    drop_caches
    local load_pre=$(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)
    echo "load_pre: ${load_pre}" > "${subdir}/weka-load.txt"
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" & local nic_pid=$!
    shift; eval "$*" 2>&1 | tee "${subdir}/fio.txt"
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    echo "load_post: $(uptime 2>/dev/null | grep -oE 'load average:.*' || echo NA)" >> "${subdir}/weka-load.txt"
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true; rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw=$(grep -oE 'bw=[0-9]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    local l1=$(echo "${load_pre}" | grep -oE '[0-9.]+' | head -1)
    log "${label}: BW=${bw:-N/A} MiB/s  (157 load1min=${l1:-NA})"
}

# 全量 9 项（与 02-2-p1-full-baseline.sh 的 run_group 口径一致）
run_group() {
    # === 顺序项 (REPEAT=1) ===
    log "=== ${LABEL}: seqread ==="
    rm -rf "${TEST_DIR}/seqread"; mkdir -p "${TEST_DIR}/seqread"
    fio --name=prep --directory="${TEST_DIR}/seqread/" --rw=write --bs=4M --size=4G >/dev/null 2>&1
    run_fio "seqread-${LABEL}" "fio --name=seqread --directory='${TEST_DIR}/seqread/' --rw=read --refill_buffers --bs=256k --size=4G --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/seqread-${LABEL}' --log_avg_msec=1000"

    log "=== ${LABEL}: seqwrite ==="
    rm -rf "${TEST_DIR}/seqwrite"; mkdir -p "${TEST_DIR}/seqwrite"
    run_fio "seqwrite-${LABEL}" "fio --name=seqwrite --directory='${TEST_DIR}/seqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/seqwrite-${LABEL}' --log_avg_msec=1000"

    log "=== ${LABEL}: mseqread ==="
    rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
    fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
    run_fio "mseqread-${LABEL}" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/mseqread-${LABEL}' --log_avg_msec=1000"

    log "=== ${LABEL}: mseqwrite ==="
    rm -rf "${TEST_DIR}/mseqwrite"; mkdir -p "${TEST_DIR}/mseqwrite"
    run_fio "mseqwrite-${LABEL}" "fio --name=mseqwrite --directory='${TEST_DIR}/mseqwrite/' --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --write_bw_log='${BW_LOG_DIR}/mseqwrite-${LABEL}' --log_avg_msec=1000"

    # === 组内清卷 → randwrite-true ×REPEAT (fresh volume, create_on_open) ===
    clean_volume
    mount_jfs
    for r in $(seq 1 ${REPEAT}); do
        run_fio "randwrite-true-${LABEL}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --nrfiles=100 --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --create_on_open=1 --openfiles=128 --group_reporting --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/randwrite-true-${LABEL}-r${r}' --log_avg_msec=1000"
        compact_cooldown
    done

    # === 组内清卷 → layout → randread ×REPEAT → randrw ×REPEAT → randwrite-ow ×REPEAT ===
    clean_volume
    mount_jfs
    log "=== ${LABEL}: layout ==="
    run_fio "layout-${LABEL}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log='${BW_LOG_DIR}/layout-${LABEL}' --log_avg_msec=1000"
    compact_cooldown

    for r in $(seq 1 ${REPEAT}); do
        run_fio "randread-${LABEL}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/randread-${LABEL}-r${r}' --log_avg_msec=1000"
    done

    for r in $(seq 1 ${REPEAT}); do
        log "randrw r${r}: rebuilding layout (variant Y)..."
        rm -rf "${TEST_DIR}"; mkdir -p "${TEST_DIR}"
        fio --directory="${TEST_DIR}" --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 >/dev/null 2>&1
        compact_cooldown
        run_fio "randrw-${LABEL}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/randrw-${LABEL}-r${r}' --log_avg_msec=1000"
        compact_cooldown
    done

    for r in $(seq 1 ${REPEAT}); do
        run_fio "randwrite-ow-${LABEL}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/randwrite-ow-${LABEL}-r${r}' --log_avg_msec=1000"
        compact_cooldown
    done
}

# 复现契约：记录跨部署复现的前提条件。
capture_contract() {
    local out="${RESULTS_DIR}/reproduction-contract-${LABEL}.txt"
    {
        echo "# reproduction-contract  label=${LABEL} readahead=${RA}  captured=$(date '+%F %T')"
        echo "## 判定：下次复现前 diff 本文件，全一致才期待相近绝对值；有差异须重新标定。"
        echo
        echo "[OSD 集合]        $(sudo ceph osd ls 2>/dev/null | tr '\n' ',')"
        echo "[OSD up/in]       $(sudo ceph osd stat 2>/dev/null)"
        echo "[CRUSH map md5]   $(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')"
        echo "[pool EC/flags]   $(sudo ceph osd pool ls detail 2>/dev/null | grep -A0 "${POOL_DATA}" | head -2)"
        echo "[ceph version]    $(sudo ceph version 2>/dev/null)"
        echo "[juicefs version] $(juicefs version 2>/dev/null)"
        echo "[kernel 157]      $(uname -r)"
        echo "[WekaIO 负载]     $(uptime 2>/dev/null)   # 共享客户端，负载水平影响绝对值"
    } > "${out}"
    log "复现契约已写 -> ${out}"
}

# ============================================================
log "============================================"
log "=== 02-2-H 全量基线复现 label=${LABEL} readahead=${RA} runtime=${RUNTIME} repeat=${REPEAT} ==="
log "=== 顺序: 重建(1次,外部) → A → soft-clean → A2 → soft-clean → B → soft-clean → B2 ==="
log "=== 本次跑【${LABEL}】一组全量 9 项 ==="
log "============================================"

# Pre-test health
HEALTH=$(sudo ceph health 2>/dev/null); log "ceph health: ${HEALTH}"
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (expected 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: not all OSDs up"; exit 1; }

# === 组间清理模式：./02-2-H...sh softclean —— 只做 soft-clean+OSD-restart，不跑测试 ===
# ⚑ 组间清理(A→A2→B→B2 之间)用这个，复用与组内完全相同的已测函数，避免手抄命令出错。
#   不写变量守卫基线、不跑 run_group，仅清数据+重置 tmpfs 内存态(保 pool → 映射不变)。
if [ "${LABEL}" = "softclean" ] || [ "${LABEL}" = "clean" ]; then
    log "=== 组间清理模式 (soft-clean + OSD restart，不跑测试) ==="
    soft_clean_restart
    POST_MD5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    if [ -f "${GUARD_BASE}" ]; then
        BM=$(grep '^CRUSHMD5=' "${GUARD_BASE}" | cut -d= -f2-)
        [ "${POST_MD5}" = "${BM}" ] && log "✅ soft-clean 后 CRUSH md5 与基线一致(${POST_MD5})，映射未变" \
                                    || log "🔴 soft-clean 后 CRUSH md5 变了! ${BM} -> ${POST_MD5} (soft-clean 不应改映射，须排查)"
    else
        log "  (尚无守卫基线文件，跳过比对；当前 crush md5=${POST_MD5})"
    fi
    log "=== 组间清理完成，可跑下一组 ==="
    exit 0
fi

# === 变量守卫：首次运行(A)写基线快照文件；后续运行(A2/B/B2)比对该文件 ===
# ⚑ 与 02-2-G 不同：02-2-G 在单次进程内跨 cycle 比对；本脚本是【多次独立运行】(A/A2/B/B2 各一次进程)，
#   故把基线快照【持久化到文件】，跨运行比对——确保 A→A2→B→B2 全程 CRUSH 映射未被任何 soft-clean 改动。
NOW_OSDSET=$(sudo ceph osd ls 2>/dev/null | tr '\n' ',')
NOW_POOLID=$(sudo ceph osd lspools 2>/dev/null | awk -v p="${POOL_DATA}" '$2==p{print $1}')
NOW_CRUSHMD5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
log "本次控制变量: OSD 集合=${NOW_OSDSET}  pool_id=${NOW_POOLID}  crush_md5=${NOW_CRUSHMD5}"

GUARD_FAILED=false
if [ ! -f "${GUARD_BASE}" ]; then
    # 首次运行（应为 A，紧接重建之后）→ 写基线快照
    {
        echo "OSDSET=${NOW_OSDSET}"
        echo "POOLID=${NOW_POOLID}"
        echo "CRUSHMD5=${NOW_CRUSHMD5}"
        echo "CAPTURED_BY=${LABEL} at $(date '+%F %T')"
    } > "${GUARD_BASE}"
    log "变量守卫: 首次运行(${LABEL})，已写基线快照 -> ${GUARD_BASE}"
    if [ "${LABEL}" != "A" ]; then
        log "⚠️ 注意：首次写守卫基线的是 ${LABEL}(非 A)。正确顺序首跑应为 A(紧接重建)。若中途重跑请确认起点。"
    fi
else
    # 后续运行 → 比对
    BASE_OSDSET=$(grep '^OSDSET=' "${GUARD_BASE}" | cut -d= -f2-)
    BASE_POOLID=$(grep '^POOLID=' "${GUARD_BASE}" | cut -d= -f2-)
    BASE_CRUSHMD5=$(grep '^CRUSHMD5=' "${GUARD_BASE}" | cut -d= -f2-)
    [ "${NOW_OSDSET}" = "${BASE_OSDSET}" ]   || { log "🔴 变量守卫: OSD 集合变了! ${BASE_OSDSET} -> ${NOW_OSDSET} (疑似 purge/重建)"; GUARD_FAILED=true; }
    [ "${NOW_POOLID}" = "${BASE_POOLID}" ]   || { log "🔴 变量守卫: pool_id 变了! ${BASE_POOLID} -> ${NOW_POOLID} (疑似 pool delete+recreate，§9.6 禁止)"; GUARD_FAILED=true; }
    [ "${NOW_CRUSHMD5}" = "${BASE_CRUSHMD5}" ] || { log "🔴 变量守卫: CRUSH map 变了! ${BASE_CRUSHMD5} -> ${NOW_CRUSHMD5} (疑似重建/动 crush rule/pg_num/权重)"; GUARD_FAILED=true; }
    if ${GUARD_FAILED}; then
        log "🔴🔴 控制变量与基线快照(${GUARD_BASE})不符 → 本次(${LABEL})数据与 A 不可比。"
        log "     若这是【故意重建】(如误按字面在 B 前重建)，则 A vs B 绝对值不可比，只能各自自证复现。"
        log "     请查明原因；勿在此数据上跨组下 readahead 结论。"
    else
        log "✅ 变量守卫: OSD/pool_id/crush 与基线快照一致，本次(${LABEL})与 A 同布局、可比"
    fi
fi

# === 起点自检：确认起点干净 + 157 负载可接受 ===
log "=== 起点自检 (期望: pool 空 / 157 负载 < ${WEKA_LOAD_MAX}) ==="
STARTPOINT_OK=true
# data pool 对象数（JSON 精确取 num_objects）
POOL_OBJS=$(sudo rados df --format json 2>/dev/null | python3 -c "import sys,json;pools=json.load(sys.stdin).get('pools',[]);print(next((p['num_objects'] for p in pools if p['pool_name']=='${POOL_DATA}'),'NA'))" 2>/dev/null || echo "NA")
log "  ${POOL_DATA} num_objects = ${POOL_OBJS:-NA} (干净起点应 ≈0；A2/B/B2 起点由上一步 soft-clean 保证)"
[ "${POOL_OBJS}" != "NA" ] && [ "${POOL_OBJS}" -gt 100 ] 2>/dev/null && { log "  ⚠️ pool 非空(${POOL_OBJS} 对象)，起点不干净"; STARTPOINT_OK=false; }
[ "${POOL_OBJS}" = "NA" ] && { log "  ⚠️ 无法解析对象数，须人工 rados df 确认 pool 已清空"; STARTPOINT_OK=false; }
# 157 WekaIO 共享客户端负载
WEKA_LOAD1=$(uptime 2>/dev/null | grep -oE 'load average: [0-9.]+' | grep -oE '[0-9.]+' || echo "NA")
log "  157 load average(1min) = ${WEKA_LOAD1}  (共享客户端；过高会污染读测)"
if [ "${WEKA_LOAD1}" != "NA" ] && awk "BEGIN{exit !(${WEKA_LOAD1}>${WEKA_LOAD_MAX})}" 2>/dev/null; then
    log "  ⚠️⚠️ 157 负载 ${WEKA_LOAD1} > 阈值 ${WEKA_LOAD_MAX}：WekaIO 抢占严重，读测将被污染。建议改到 157 空闲时段跑。"
    STARTPOINT_OK=false
fi
${STARTPOINT_OK} && log "✅ 起点自检通过" || log "⚠️⚠️ 起点自检 WARN：起点不干净 / 负载过高。修好再跑，勿在污染起点上采数据。"

# 复现契约（测前采一次）
capture_contract

# === 挂载 + 跑一组全量 9 项 ===
mount_jfs
run_group

# === 取证快照 + 变量守卫复查（跑完后布局仍应不变） ===
if [ -x "${FORENSIC}" ]; then
    log "取证快照 FULLBASE-${LABEL} ..."
    bash "${FORENSIC}" "FULLBASE-${LABEL}" || true
fi
POST_CRUSHMD5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
[ "${POST_CRUSHMD5}" = "${NOW_CRUSHMD5}" ] && log "✅ 跑完 CRUSH md5 未变(${POST_CRUSHMD5})" || log "🔴 跑完 CRUSH md5 变了! ${NOW_CRUSHMD5} -> ${POST_CRUSHMD5} 数据存疑"

# ===== 汇总本组 9 项 =====
log "=== 汇总：${LABEL} 全量 9 项 (fio bw, MiB/s) ==="
for item in seqread seqwrite mseqread mseqwrite layout; do
    bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/${LABEL}/${item}-${LABEL}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    log "  ${item}: ${bw:-NA}"
done
for item in randwrite-true randread randrw randwrite-ow; do
    line="  ${item}:"
    for r in $(seq 1 ${REPEAT}); do
        bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/${LABEL}/${item}-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "${line}"
done

${GUARD_FAILED} && log "🔴 提醒：本次变量守卫触发，${LABEL} 与 A 不可比，跨组结论不可信。"
log "=== 02-2-H ${LABEL} DONE ==="
log "复现判定(|A2-A|/A、|B2-B|/B <5%)在跑完 A/A2/B/B2 四组后，用 compare 汇总（任务书 §一）。"
log "取证快照见 /tmp/opencode-rebuild-forensic/FULLBASE-${LABEL}/  复现契约见 ${RESULTS_DIR}/reproduction-contract-${LABEL}.txt"

# === 若四组齐全，自动算复现偏差 ===
compare_reproduce() {
    python3 - <<PY 2>/dev/null | while read l; do log "$l"; done || true
import re, os
base="${RESULTS_DIR}"; repeat=${REPEAT}
def bw(f):
    if os.path.exists(f):
        m=re.search(r'bw=([0-9]+)MiB', open(f).read())
        if m: return int(m.group(1))
    return None
def seq(item,label): return bw(f"{base}/{label}/{item}-{label}/fio.txt")
def med(item,label):
    xs=[bw(f"{base}/{label}/{item}-{label}-r{r}/fio.txt") for r in range(1,repeat+1)]
    xs=[x for x in xs if x]
    if not xs: return None
    xs.sort(); return xs[len(xs)//2] if len(xs)>1 else xs[0]
seq_items=["seqread","seqwrite","mseqread","mseqwrite","layout"]
rnd_items=["randwrite-true","randread","randrw","randwrite-ow"]
labels=[l for l in ["A","A2","B","B2"] if os.path.isdir(f"{base}/{l}")]
if not set(["A","A2"]).issubset(labels) and not set(["B","B2"]).issubset(labels):
    print("(复现偏差汇总：A/A2 或 B/B2 尚未齐全，跳过)"); raise SystemExit
def dev(pair):
    g1,g2=pair
    print(f"--- 同组复现偏差 {g2} vs {g1} (目标 <5%) ---")
    worst=0.0
    for it in seq_items:
        v1,v2=seq(it,g1),seq(it,g2)
        if v1 and v2:
            d=abs(v2-v1)/v1*100; worst=max(worst,d)
            print(f"  {it:16s}: {g1}={v1} {g2}={v2}  Δ={d:.1f}%  {'✅' if d<5 else '❌'}")
    for it in rnd_items:
        v1,v2=med(it,g1),med(it,g2)
        if v1 and v2:
            d=abs(v2-v1)/v1*100; worst=max(worst,d)
            print(f"  {it:16s}(中位): {g1}={v1} {g2}={v2}  Δ={d:.1f}%  {'✅' if d<5 else '❌'}")
    print(f"  → {g2} vs {g1} 最大偏差 = {worst:.1f}%  {'✅ 同组可复现' if worst<5 else '❌ 超阈，排查(compact/负载/变量)'}")
    return worst
if set(["A","A2"]).issubset(labels): dev(("A","A2"))
if set(["B","B2"]).issubset(labels): dev(("B","B2"))
if set(["A","B"]).issubset(labels):
    print("--- (顺带) A vs B 冷态对比 = readahead 效果 B/A ---")
    for it in seq_items:
        va,vb=seq(it,"A"),seq(it,"B")
        if va and vb: print(f"  {it:16s}: A={va} B={vb}  B/A={vb/va:.2f}")
    for it in rnd_items:
        va,vb=med(it,"A"),med(it,"B")
        if va and vb: print(f"  {it:16s}(中位): A={va} B={vb}  B/A={vb/va:.2f}")
print("")
print("⚑ 可复现性边界：以上仅证【同一部署】可复现；绝对值跨部署不可复现，跨部署只比相对结论。")
PY
}
compare_reproduce
