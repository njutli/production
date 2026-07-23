#!/bin/bash
set -e

# 02-2-G soft-clean(+OSD restart) stable-baseline validation  [v2 2026-07-23]
# 目的：验证"清数据不重建 + 重置 OSD 内存态"能否得到跨轮次可复现的稳定基线。
#   已证根因：① 重建 OSD(§九) ② pool delete+recreate(§9.6) ③ tmpfs/RocksDB 内存态逐轮累积(00-baseline-20260723-2)
#   对策：soft-clean(juicefs destroy 保留 pool → 映射不变) + OSD restart(不删 pool → 重置 tmpfs/RocksDB 内存态到相同起点)
#         → 期望跨 cycle CV 回落，且 mseqread 不再单调下降。
#
# 探针 = randread(稳定性) + mseqread(tmpfs 累积试金石：若仍单调下降说明 OSD restart 未解决第三源)。
# 用法：./02-2-G-softclean-stability.sh <GROUP> <CYCLES> <RUNTIME> <REPEAT>
#   GROUP   = A(default) | B(ra0)      默认 A
#   CYCLES  = 轮次数                    默认 4   (cycle1=预热/参照轮，CV 从 cycle2 起算)
#   RUNTIME = 每次 randread 秒数        默认 90
#   REPEAT  = 每轮 randread 内部重复    默认 2
#
# 【验证性测试定位】只跑 layout + randread + mseqread，短口径快速证命题（≈40min/组）。
#   compact cooldown 不可省。
#
# 遵循 skills：TESTING-GUIDE(health/compact cooldown)、test-commands-reference(fio/§8.3)
# 红线：157 上 WekaIO 在跑，禁动内核/网卡/RoCE/md0/WekaIO；本脚本不 rebuild OSD、不删 pool。
#   ⚑ OSD restart 不删 pool → pool_id 不变 → CRUSH 映射不变（与 §9.6 禁止的 delete+recreate 不同）。

# ===== 配置 =====
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-02-2-g-softclean"
NIC_IF="enp139s0f0np0"
POOL_DATA="juicefs-data"
FORENSIC="$(dirname "$0")/rebuild-topology-forensic.sh"
GROUP="${1:-A}"
CYCLES="${2:-4}"
RUNTIME="${3:-90}"
REPEAT="${4:-2}"
WEKA_LOAD_MAX="${WEKA_LOAD_MAX:-20}"   # 157 共享客户端 1min 负载阈值；超过则读测可能被 WekaIO 抢占污染

case "${GROUP}" in
    A*) RA="default" ;;
    B*) RA="ra0" ;;
    *)  RA="default" ;;
esac
LABEL="${GROUP}"

mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# ===== Helpers (与 02-2-p1-full-baseline.sh 一致) =====
drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
        sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

# compact_cooldown: 强制 compact 并轮询到 compact_running=0 AND compact_queue_len=0。
# ⚑ 修复(02-2-G v3)：旧版只查 compact_running，且超时静默继续 → 曾出现 57s 未压完就进下一轮，
#    导致 compaction 残留逐轮叠加，被误判为"tmpfs 累积"。现同时查 queue_len，并把最终状态打日志、
#    超时显式 WARN，绝不静默放行。
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

# soft-clean + OSD restart: 清数据(保留 pool → 映射不变) + 重置 OSD 内存态(不删 pool)。
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
    local label="$1"; local subdir="${RESULTS_DIR}/${label}"; mkdir -p "${subdir}"
    drop_caches
    # 记录 157 WekaIO 负载(前)——读带宽虚低时用于判定是否客户端抢占所致
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

# 一轮：layout → randread ×REPEAT(稳定性探针) + mseqread ×1(tmpfs 累积试金石)
run_cycle() {
    local cyc="$1"
    log "=== [cycle ${cyc}] layout ==="
    run_fio "c${cyc}-layout-${LABEL}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log='${BW_LOG_DIR}/c${cyc}-layout-${LABEL}' --log_avg_msec=1000"
    compact_cooldown
    for r in $(seq 1 ${REPEAT}); do
        run_fio "c${cyc}-randread-${LABEL}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/c${cyc}-randread-${LABEL}-r${r}' --log_avg_msec=1000"
    done
    # mseqread 试金石：tmpfs/RocksDB 累积若未被 OSD restart 消除 → mseqread 跨 cycle 单调下降
    log "=== [cycle ${cyc}] mseqread (tmpfs 累积试金石) ==="
    rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
    fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
    run_fio "c${cyc}-mseqread-${LABEL}" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/c${cyc}-mseqread-${LABEL}' --log_avg_msec=1000"
    compact_cooldown
}

# 复现契约：记录"跨部署复现的前提条件"。下次复现前 diff 这份，全一致才期待相近绝对值。
# 6轮稳=会话内可复现；此契约保证下次能判定"下次"是否处于同一物理布局。
capture_contract() {
    local out="${RESULTS_DIR}/reproduction-contract-${LABEL}.txt"
    {
        echo "# reproduction-contract  group=${LABEL} readahead=${RA}  captured=$(date '+%F %T')"
        echo "## 判定：下次复现前 diff 本文件，全一致才期待相近绝对值；有差异须重新标定。"
        echo
        echo "[OSD 集合]        $(sudo ceph osd ls 2>/dev/null | tr '\n' ',')"
        echo "[OSD up/in]       $(sudo ceph osd stat 2>/dev/null)"
        echo "[CRUSH map md5]   $(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')"
        echo "[pool EC/flags]   $(sudo ceph osd pool ls detail 2>/dev/null | grep -A0 "${POOL_DATA}" | head -2)"
        echo "[ceph version]    $(sudo ceph version 2>/dev/null)"
        echo "[juicefs version] $(juicefs version 2>/dev/null)"
        echo "[kernel 157]      $(uname -r)"
        echo "[NUMA 157]        $(lscpu 2>/dev/null | grep -i 'NUMA node(s)')"
        echo "[WekaIO 负载]     $(uptime 2>/dev/null)   # 共享客户端，负载水平影响绝对值"
        echo
        echo "## OSD -> host/device (tmpfs 落点，跨部署会变):"
        sudo ceph osd metadata 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(f"  osd.{o[\"id\"]}  host={o.get(\"hostname\")}  bluestore={o.get(\"bluestore_bdev_partition_path\",o.get(\"devices\"))}") for o in d]' 2>/dev/null || echo "  (metadata 解析失败，见取证快照 05-osd-metadata.txt)"
        echo
        echo "## primary-OSD 分布 (布局指纹，见取证 10-primary-osd-histogram.txt)"
    } > "${out}"
    log "复现契约已写 -> ${out}"
}

# ============================================================
log "============================================"
log "=== 02-2-G soft-clean+OSD-restart 稳定性验证 group=${LABEL} readahead=${RA} cycles=${CYCLES} rt=${RUNTIME} rep=${REPEAT} ==="
log "=== 探针: randread(稳定性) + mseqread(tmpfs 累积试金石); cycle1=预热轮 ==="
log "============================================"

# Pre-test health
HEALTH=$(sudo ceph health 2>/dev/null); log "ceph health: ${HEALTH}"
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (expected 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: not all OSDs up"; exit 1; }

# === 变量守卫：捕获控制变量基线 (pool_id / OSD 集合 / crush md5)，每 cycle 比对，被动则报警 ===
# 目的：即使执行者(或脚本)误改了控制变量(如误删 pool→pool_id 变、purge→OSD 变)，也当场暴露，
#       而非事后靠人工审计。这些是本实验的"唯一变量之外"必须恒定的量。
BASE_OSDSET=$(sudo ceph osd ls 2>/dev/null | tr '\n' ',')
BASE_POOLID=$(sudo ceph osd lspools 2>/dev/null | awk -v p="${POOL_DATA}" '$2==p{print $1}')
BASE_CRUSHMD5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
log "变量守卫基线: OSD 集合=${BASE_OSDSET}  pool_id=${BASE_POOLID}  crush_md5=${BASE_CRUSHMD5}"
log "  (以上三者全程必须不变；soft-clean+restart 不应改变任一项)"

variable_guard() {
    local cyc="$1"; local bad=false
    local now_osd=$(sudo ceph osd ls 2>/dev/null | tr '\n' ',')
    local now_pid=$(sudo ceph osd lspools 2>/dev/null | awk -v p="${POOL_DATA}" '$2==p{print $1}')
    local now_md5=$(sudo ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print $1}')
    [ "${now_osd}" = "${BASE_OSDSET}" ]   || { log "[cycle ${cyc}] 🔴 变量守卫: OSD 集合变了! ${BASE_OSDSET} -> ${now_osd} (疑似 purge/重建)"; bad=true; }
    [ "${now_pid}" = "${BASE_POOLID}" ]   || { log "[cycle ${cyc}] 🔴 变量守卫: pool_id 变了! ${BASE_POOLID} -> ${now_pid} (疑似 pool delete+recreate，§9.6 禁止)"; bad=true; }
    [ "${now_md5}" = "${BASE_CRUSHMD5}" ] || { log "[cycle ${cyc}] 🔴 变量守卫: CRUSH map 变了! (疑似动了 crush rule/pg_num/OSD 权重)"; bad=true; }
    if ${bad}; then
        log "[cycle ${cyc}] 🔴🔴 控制变量被破坏 → 本实验结果无效。请勿在此数据上下结论；须查明是谁改了变量(脚本/执行者)。"
        return 1
    fi
    log "[cycle ${cyc}] ✅ 变量守卫: OSD/pool_id/crush 全部不变"
    return 0
}

# === cycle1 起点自检：确认从"干净起点"开始(应刚做过 stable-ID 重建) ===
# 判据：① OSD 刚重建 → uptime 短(fresh BlueStore) ② data pool 对象数≈0 ③ tmpfs DB 占用低
log "=== cycle1 起点自检 (期望: OSD fresh + pool 空 + tmpfs 占用低) ==="
STARTPOINT_OK=true
# ① OSD uptime (刚重建应 < 30min=1800s)
for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    up=$(sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${ip} \
        'p=$(pgrep -f ceph-osd | head -1); [ -n "$p" ] && ps -o etimes= -p $p | tr -d " "' 2>/dev/null || echo "NA")
    log "  ${ip} OSD uptime(s) = ${up}"
    if [ "${up}" != "NA" ] && [ "${up}" -gt 1800 ] 2>/dev/null; then
        log "  ⚠️ ${ip} OSD 已运行 >30min，可能非 fresh 重建起点"; STARTPOINT_OK=false
    fi
done
# ② data pool 对象数(干净起点应≈0)
# ⚑ 修复(v3)：旧版用 `rados df` 文本列取到了单位"B/GiB"而非数字，自检形同虚设。改用 JSON 精确取 num_objects。
POOL_OBJS=$(sudo rados df --format json 2>/dev/null | python3 -c "import sys,json;pools=json.load(sys.stdin).get('pools',[]);print(next((p['num_objects'] for p in pools if p['pool_name']=='${POOL_DATA}'),'NA'))" 2>/dev/null || echo "NA")
log "  ${POOL_DATA} num_objects = ${POOL_OBJS:-NA} (干净起点应 ≈0)"
[ "${POOL_OBJS}" != "NA" ] && [ "${POOL_OBJS}" -gt 100 ] 2>/dev/null && { log "  ⚠️ pool 非空(${POOL_OBJS} 对象)，起点不干净"; STARTPOINT_OK=false; }
[ "${POOL_OBJS}" = "NA" ] && { log "  ⚠️ 无法解析对象数，自检该项失效，须人工确认 pool 已清空"; STARTPOINT_OK=false; }
# ③ tmpfs DB/WAL 占用(fresh 应低)
for ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
    used=$(sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise@${ip} \
        "df -h /mnt/dbwal 2>/dev/null | awk 'NR==2{print \$5}'" 2>/dev/null || echo "NA")
    log "  ${ip} tmpfs(/mnt/dbwal) 占用 = ${used}"
done
# ④ 157 WekaIO 共享客户端负载(致命混淆变量：负载高会抢占 fio → 读带宽虚低)
WEKA_LOAD1=$(uptime 2>/dev/null | grep -oE 'load average: [0-9.]+' | grep -oE '[0-9.]+' || echo "NA")
log "  157 load average(1min) = ${WEKA_LOAD1}  (共享客户端；过高会污染读测)"
if [ "${WEKA_LOAD1}" != "NA" ]; then
    if awk "BEGIN{exit !(${WEKA_LOAD1}>${WEKA_LOAD_MAX})}" 2>/dev/null; then
        log "  ⚠️⚠️ 157 负载 ${WEKA_LOAD1} > 阈值 ${WEKA_LOAD_MAX}：WekaIO 抢占严重，读测将被污染。建议改到 157 空闲时段跑。"
        STARTPOINT_OK=false
    fi
fi
if ${STARTPOINT_OK}; then
    log "✅ 起点自检通过：从干净起点开始，cycle1 有效"
else
    log "⚠️⚠️ 起点自检 WARN：起点不干净 / 负载过高 / 对象数无法确认。"
    log "     处置：① 未重建→先跑 rebuild-stable-ids.sh(见任务书步骤2.5)；② 157负载高→等空闲时段；"
    log "          ③ 对象数解析失败→人工 rados df 确认。修好再跑，勿在污染起点上采数据。"
fi

# 复现契约(跨部署复现前提)——测前采一次
capture_contract

GUARD_FAILED=false
for cyc in $(seq 1 ${CYCLES}); do
    log "########## CYCLE ${cyc}/${CYCLES} ##########"
    [ "${cyc}" -eq 1 ] && log "(cycle1 = 预热/参照轮，CV 从 cycle2 起算)"
    [ "${cyc}" -eq 1 ] || soft_clean_restart
    mount_jfs
    run_cycle "${cyc}"

    # === 取证快照 + 变量守卫：控制变量(OSD/pool_id/crush)是否被动 ===
    if [ -x "${FORENSIC}" ]; then
        log "[cycle ${cyc}] 取证快照..."
        bash "${FORENSIC}" "SOFTCLEAN-c${cyc}" || true
    fi
    variable_guard "${cyc}" || GUARD_FAILED=true
done
${GUARD_FAILED} && log "🔴🔴 变量守卫在某 cycle 触发：控制变量被破坏，下方稳定性判定【不可信】，须先查明变量为何改变。"

# ===== 汇总：跨 cycle 稳定性 =====
log "=== 汇总：跨 cycle randread (fio bw, MiB/s) ==="
for cyc in $(seq 1 ${CYCLES}); do
    line="cycle${cyc}:"
    for r in $(seq 1 ${REPEAT}); do
        bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/c${cyc}-randread-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "  ${line}"
done
log "=== 汇总：跨 cycle mseqread (tmpfs 累积试金石, fio bw MiB/s) ==="
for cyc in $(seq 1 ${CYCLES}); do
    bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/c${cyc}-mseqread-${LABEL}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    log "  cycle${cyc}: mseqread=${bw:-NA}"
done

# 判定：① randread 跨 cycle CV(从 cycle2 起算，排除预热轮) ② mseqread 是否停止单调下降
python3 - <<PY 2>/dev/null | while read l; do log "$l"; done || true
import statistics as s, re, os
base="${RESULTS_DIR}"; label="${LABEL}"; cycles=${CYCLES}; repeat=${REPEAT}
def bw(f):
    if os.path.exists(f):
        m=re.search(r'bw=([0-9]+)MiB', open(f).read())
        if m: return int(m.group(1))
    return None
# randread 每 cycle 中位
rr=[]
for c in range(1,cycles+1):
    rs=[bw(f"{base}/c{c}-randread-{label}-r{r}/fio.txt") for r in range(1,repeat+1)]
    rs=[x for x in rs if x]
    if rs: rs.sort(); rr.append(rs[len(rs)//2] if len(rs)>1 else rs[0])
    else: rr.append(None)
# mseqread 每 cycle
mr=[bw(f"{base}/c{c}-mseqread-{label}/fio.txt") for c in range(1,cycles+1)]

print(f"randread 逐 cycle 中位 = {rr}")
print(f"mseqread 逐 cycle       = {mr}")

# ① randread CV：排除 cycle1 预热轮，从 cycle2 起算
stable=[x for x in rr[1:] if x]
if len(stable)>=2:
    cv=100*s.pstdev(stable)/s.mean(stable)
    print(f"[判据①] randread 跨 cycle CV(排除 cycle1) = {cv:.2f}%  (目标 <5%)")
    verdict1 = cv<5
    print("        " + ("✅ 稳态可复现" if verdict1 else "❌ 仍不稳"))
else:
    verdict1=False; print("[判据①] 数据不足")

# ② mseqread 是否停止单调下降(从 cycle2 起，逐 cycle 增量不应持续为负且加速)
ms=[x for x in mr[1:] if x]
if len(ms)>=2:
    incs=[100*(ms[i+1]-ms[i])/ms[i] for i in range(len(ms)-1)]
    mono_down = all(x < -3 for x in incs)  # 每步都跌>3% = 单调下降未解决
    print(f"[判据②] mseqread(排除c1) 逐步Δ = {[f'{x:+.1f}%' for x in incs]}")
    print("        " + ("❌ 仍单调下降 → tmpfs 累积未被 OSD restart 消除，需上方案C(每轮 stable-ID 重建)"
                         if mono_down else "✅ 不再单调下降 → tmpfs 累积已被 OSD restart 消除"))
    verdict2 = not mono_down
else:
    verdict2=False; print("[判据②] 数据不足")

print("")
print("=== 总判定 ===")
if verdict1 and verdict2:
    print("✅ soft-clean+OSD-restart 得到稳态可复现基线：randread 稳(CV<5%) + mseqread 不再单调降")
    print("   → 可锁基线，进入 P2-P4；调优对比用同口径背靠背比 Δ")
else:
    print("❌ 未完全达成。若判据②失败(mseqread 仍降)=第三源未解 → 方案C；若判据①失败=另有源，人工复审")
print("")
print("⚑ 可复现性边界: 本 CV 仅证明【同一部署】上可复现。绝对值跨部署不可复现(§九)，")
print("  跨部署只复现相对结论(比值/Δ)。复现前先 diff reproduction-contract。")
PY

log "=== 02-2-G DONE ==="
log "取证快照见 /tmp/opencode-rebuild-forensic/SOFTCLEAN-c*/  (确认 pool_id + OSD 集合逐 cycle 不变)"
log "复现契约见 ${RESULTS_DIR}/reproduction-contract-${LABEL}.txt"
