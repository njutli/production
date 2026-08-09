#!/bin/bash
set -uo pipefail
export LC_ALL=C

# 03-4 周末无人值守连跑
# 设计原则：时间盒终止 + 优雅降级 + 自愈；只为真安全项停机

EXPECTED_PID=1631722
EXPECTED_ST=1502152363
V4_SCRIPT="/tmp/FULLBASELINE_V4.sh"
RESULTS_DIR="/tmp/opencode-w-drift"
V4_RESULTS="/tmp/opencode-fullbaseline-v4"
STATUS="/tmp/opencode-03-4-CAMPAIGN-STATUS.md"

MAX_RUNS=12
NO_START_AFTER=$(date -d '2026-08-10 02:00:00' +%s)
HARD_BACKSTOP=$(date -d '2026-08-10 07:30:00' +%s)

export OBJ_TARGET=2900000
export OBJ_START_MAX=3000000
export OBJ_MAX=10000000
export OBJ_GC_PASSES=2
export OBJ_GC_SETTLE=60

mkdir -p "${RESULTS_DIR}"
log() { echo "[$(date '+%F %T')] $*" | tee -a "${RESULTS_DIR}/wrapper.log"; }
st()  { echo "$*" >> "${STATUS}"; }

pool_obj() {
    local l
    l=$(sudo ceph df --format=json 2>/dev/null | python3 -c 'import sys,json
p=[x for x in json.load(sys.stdin)["pools"] if x["name"]=="juicefs-data"][0]["stats"]
print(p["objects"], p["max_avail"])
' 2>/dev/null)
    [ -n "${l}" ] || return 1
    read -r POOL_OBJ POOL_MAX <<< "${l}"
    [ -n "${POOL_OBJ}" ] && [ "${POOL_OBJ}" != "0" ] || return 1
    return 0
}

ensure_tracer() {
    if ! pgrep -f pool-tracer.sh > /dev/null 2>&1; then
        log "  tracer dead, restarting"
        st "- tracer restarted at $(date '+%F %T'), gap in pool-trace.tsv"
        setsid nohup /tmp/pool-tracer.sh > /tmp/pool-tracer.log 2>&1 &
        sleep 20
    fi
    log "  tracer pid=$(pgrep -f pool-tracer.sh | head -1)"
}

drain_ladder() {
    local i
    pool_obj || return 0
    [ "${POOL_OBJ}" -le 3500000 ] 2>/dev/null && return 0
    log "  drain_ladder: pool ${POOL_OBJ} > 3.50M, starting ladder cleanup"
    for i in 1 2; do
        log "  drain_ladder: gc --compact pass ${i}"
        juicefs gc --compact "tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod" \
            > "${RESULTS_DIR}/ladder-compact-$(date +%s).log" 2>&1
        sleep 60
        pool_obj && log "  drain_ladder: now ${POOL_OBJ}"
        [ "${POOL_OBJ}" -le 3500000 ] 2>/dev/null && { log "  drain_ladder: below threshold"; return 0; }
    done
    log "  drain_ladder: compact ineffective, escalating to gc --delete"
    st "- $(date '+%F %T') gc --delete escalation, pool was ${POOL_OBJ}"
    juicefs gc --delete "tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod" \
        > "${RESULTS_DIR}/ladder-delete-$(date +%s).log" 2>&1
    sleep 120
    pool_obj && log "  drain_ladder: post-delete ${POOL_OBJ}"
    return 0
}

log "=== 03-4 WEEKEND CAMPAIGN START $(date) ==="
st ""
st "## campaign start $(date '+%F %T')"

CONSEC_FAIL=0
CONSEC_SLOW=0
COMPLETED=0

for i in $(seq 1 ${MAX_RUNS}); do
    LABEL="WD${i}"
    NOW=$(date +%s)

    if [ "${NOW}" -ge "${NO_START_AFTER}" ]; then
        log "STOP: past Mon 02:00, no new runs"; st "- stop: time box, completed ${COMPLETED} runs"; break
    fi
    if [ "${NOW}" -ge "${HARD_BACKSTOP}" ]; then
        log "STOP: hard backstop"; break
    fi

    log ""; log "=========== Run ${i}/${MAX_RUNS}: ${LABEL} ==========="

    ensure_tracer

    HEALTH="ERROR"
    for h in 1 2 3; do
        HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
        [ "${HEALTH}" = "HEALTH_OK" ] && break
        log "  health=${HEALTH} (try ${h}/3), 5min retry"
        sleep 300
    done
    if [ "${HEALTH}" != "HEALTH_OK" ]; then
        log "STOP: health not OK after 3 tries: ${HEALTH}"; st "- STOP: health=${HEALTH} @ $(date '+%F %T')"; break
    fi

    PID=$(pgrep -f "^juicefs mount" | head -1)
    ST_TICKS=$(awk '{print $22}' /proc/${PID}/stat 2>/dev/null || echo "NA")
    log "  pid=${PID} starttime_ticks=${ST_TICKS}"
    if [ "${PID}" != "${EXPECTED_PID}" ] || [ "${ST_TICKS}" != "${EXPECTED_ST}" ]; then
        log "STOP: instance changed (pid ${PID} / st ${ST_TICKS})"
        st "- STOP: JuiceFS instance changed @ $(date '+%F %T'), pid=${PID} st=${ST_TICKS}"; break
    fi

    AVAIL=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
    log "  /tmp avail=${AVAIL}G"
    [ "${AVAIL}" -ge 5 ] 2>/dev/null || { log "STOP: /tmp <5G"; st "- STOP: disk ${AVAIL}G"; break; }

    if pool_obj; then
        log "  pool objects=${POOL_OBJ} max_avail=${POOL_MAX}"
        [ "${POOL_MAX}" -ge 1099511627776 ] 2>/dev/null || { log "STOP: max_avail <10TiB"; break; }
        drain_ladder
        pool_obj && log "  pool start objects=${POOL_OBJ}"
        if [ "${POOL_OBJ}" -gt 5000000 ] 2>/dev/null; then
            log "STOP: pool >5.00M after ladder (${POOL_OBJ})"
            st "- STOP: pool overflow ${POOL_OBJ} @ $(date '+%F %T')"; break
        fi
    else
        log "  pool read failed, skipping pool check"
    fi
    RUN_START_OBJ="${POOL_OBJ:-NA}"

    RUN_START=$(date +%s)
    ITEMS="randread randrw seqwrite mseqwrite randwrite" SKIP_REMOUNT=1 OBJ_GATE=1 \
        bash "${V4_SCRIPT}" "${LABEL}" 180 5
    V4_RC=$?
    RUN_MIN=$(( ($(date +%s) - RUN_START) / 60 ))
    log "  V4 done rc=${V4_RC} elapsed=${RUN_MIN}min"

    sudo ceph df 2>/dev/null | grep juicefs-data >> "${RESULTS_DIR}/ceph-df-per-run.txt"
    df -h /tmp | tail -1 >> "${RESULTS_DIR}/disk-per-run.txt"

    RRM=$(grep "randread: n=" "${V4_RESULTS}/test.log" 2>/dev/null | tail -1 | sed -n 's/.*median=\([0-9]*\).*/\1/p')
    [ -n "${RRM}" ] || RRM=0
    UNAL=$(cat "${V4_RESULTS}/obj-unaligned-${LABEL}.tsv" 2>/dev/null | wc -l)
    log "  randread median=${RRM}  unaligned=${UNAL}"

    echo "${LABEL} rc=${V4_RC} min=${RUN_MIN} randread_median=${RRM} start_obj=${RUN_START_OBJ} unaligned=${UNAL} ts=$(date '+%F %T')" \
        >> "${RESULTS_DIR}/PROGRESS.txt"
    st "- ${LABEL}: rc=${V4_RC} ${RUN_MIN}min randread_median=${RRM} start_pool=${RUN_START_OBJ} unaligned=${UNAL} ($(date '+%F %T'))"

    if grep -q "forced-mount" "${V4_RESULTS}/jfs-instance-${LABEL}.txt" 2>/dev/null; then
        log "STOP: forced-mount on ${LABEL}"; st "- STOP: ${LABEL} forced-mount"; break
    fi

    if [ "${V4_RC}" != "0" ]; then
        CONSEC_FAIL=$((CONSEC_FAIL+1))
        log "  ${LABEL} rc=${V4_RC} (consecutive ${CONSEC_FAIL})"
        [ "${CONSEC_FAIL}" -ge 2 ] && { log "STOP: 2 consecutive rc!=0"; st "- STOP: 2 consecutive failures"; break; }
    else
        CONSEC_FAIL=0
        COMPLETED=$((COMPLETED+1))
    fi

    if [ "${RRM}" != "0" ] && [ "${RRM}" -lt 1700 ] 2>/dev/null; then
        CONSEC_SLOW=$((CONSEC_SLOW+1))
        log "  randread median ${RRM} <1700 (consecutive ${CONSEC_SLOW})"
        [ "${CONSEC_SLOW}" -ge 2 ] && { log "STOP: 2 consecutive randread<1700"; st "- STOP: 2 consecutive randread<1700"; break; }
    else
        CONSEC_SLOW=0
    fi

    log "  ${LABEL} done"
done

log "=== CAMPAIGN DONE $(date) ==="
log "=== completed ${COMPLETED} runs, PROGRESS.txt $(wc -l < ${RESULTS_DIR}/PROGRESS.txt 2>/dev/null || echo 0) lines ==="
st "## campaign end $(date '+%F %T'), completed ${COMPLETED} runs"
