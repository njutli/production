#!/bin/bash
set -euo pipefail
export LC_ALL=C

# t1-interleave-wrapper.sh — 03-3 T1.0 阴性对照
# 臂序: A B A' B' A'' B'' (紧邻交错)
# A=balanced, B=high_client_ops

EXPECTED_PID=1631722
EXPECTED_ST=1502152363
V4_SCRIPT="/tmp/FULLBASELINE_V4.sh"
RESULTS_DIR="/tmp/opencode-t1.0"
OUTDIR="/tmp/opencode-fullbaseline-v4"

# 臂定义
ARMS=("balanced" "high_client_ops" "balanced" "high_client_ops" "balanced" "high_client_ops")
LABELS=("T10-A1" "T10-B1" "T10-A2" "T10-B2" "T10-A3" "T10-B3")
NUM_RUNS=6

log() { echo "[$(date '+%F %T')] $*"; }

# trap: 无论何种退出都恢复 balanced
restore_balanced() {
    log "RESTORING osd_mclock_profile=balanced (trap)"
    sudo ceph config set osd osd_mclock_profile balanced 2>/dev/null || true
    for i in 0 1 2 3 4 5; do sudo ceph tell osd.$i config set osd_mclock_profile balanced 2>/dev/null || true; done
}
trap restore_balanced EXIT INT TERM

log "=== T1.0 INTERLEAVE WRAPPER START ==="
log "=== $(date) ==="

# commands.sh
cat > "${RESULTS_DIR}/commands.sh" << 'CMDS'
# Arm order: A B A' B' A'' B''
# A arm: ceph config set osd osd_mclock_profile balanced
# B arm: ceph config set osd osd_mclock_profile high_client_ops
# Per run: set knob -> ceph tell verify -> wait 60s -> V4 -> H1 data -> gear check
# V4: ITEMS="mseqread randread" SKIP_REMOUNT=1 bash /tmp/FULLBASELINE_V4.sh <LABEL> 180 5
CMDS

FIRST_RUN_RANDREAD=""
GEAR_LOW=1830
GEAR_HIGH=1930

for idx in $(seq 0 $((NUM_RUNS-1))); do
    LABEL="${LABELS[$idx]}"
    PROFILE="${ARMS[$idx]}"
    RUN_NUM=$((idx+1))

    log ""
    log "============================================"
    log "=== Run ${RUN_NUM}/${NUM_RUNS}: ${LABEL} (profile=${PROFILE}) ==="
    log "============================================"

    # 门禁
    HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
    log "  health: ${HEALTH}"
    [ "${HEALTH}" = "HEALTH_OK" ] || { log "STOP: health=${HEALTH}"; restore_balanced; exit 1; }

    RECOVERY=$(sudo ceph -s 2>/dev/null | grep -E "recovery|backfill" || true)
    [ -z "${RECOVERY}" ] || { log "STOP: recovery/backfill detected: ${RECOVERY}"; restore_balanced; exit 1; }

    PID=$(pgrep -f "^juicefs mount" | head -1)
    ST=$(awk '{print $22}' /proc/${PID}/stat 2>/dev/null || echo "NA")
    log "  pid=${PID} st=${ST} (expect ${EXPECTED_PID}/${EXPECTED_ST})"
    [ "${PID}" = "${EXPECTED_PID}" ] || { log "STOP: pid changed"; restore_balanced; exit 1; }
    [ "${ST}" = "${EXPECTED_ST}" ] || { log "STOP: starttime changed"; restore_balanced; exit 1; }

    AVAIL=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
    log "  disk: ${AVAIL}G available"
    [ "${AVAIL}" -ge 25 ] || { log "STOP: disk <25G"; restore_balanced; exit 1; }

    # 设旋钮
    log "  Setting osd_mclock_profile=${PROFILE}"
    sudo ceph config set osd osd_mclock_profile "${PROFILE}"
    for i in 0 1 2 3 4 5; do
        sudo ceph tell osd.$i config set osd_mclock_profile "${PROFILE}" 2>/dev/null || true
    done

    # 验证旋钮生效
    VERIFY_OK=true
    for i in 0 1 2 3 4 5; do
        VAL=$(sudo ceph tell osd.$i config get osd_mclock_profile 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('osd_mclock_profile',''))" 2>/dev/null || echo "")
        [ "${VAL}" = "${PROFILE}" ] || { log "  VERIFY FAIL: osd.$i=${VAL} (expect ${PROFILE})"; VERIFY_OK=false; }
    done
    [ "${VERIFY_OK}" = "true" ] || { log "STOP: knob verify failed"; restore_balanced; exit 1; }
    for i in 0 1 2 3 4 5; do sudo ceph tell osd.$i config get osd_mclock_profile 2>/dev/null; done | tee "${RESULTS_DIR}/knob-${LABEL}.txt" >/dev/null
    log "  knob verified: ${PROFILE} on all 6 OSDs"

    # 等 60s 让 mclock 重算配额
    log "  Waiting 60s for mclock quota recalc..."
    sleep 60

    # 复查 health
    HEALTH2=$(sudo ceph health 2>/dev/null || echo "ERROR")
    [ "${HEALTH2}" = "HEALTH_OK" ] || { log "STOP: health degraded after knob: ${HEALTH2}"; restore_balanced; exit 1; }

    # H1 数据 pre-run
    log "  Collecting H1 pre-run data..."
    for i in 0 1 2 3 4 5; do
        sudo ceph tell osd.$i perf dump > "${RESULTS_DIR}/perf-osd${i}-${LABEL}-pre.json" 2>/dev/null || true
        sudo ceph tell osd.$i dump_mempools > "${RESULTS_DIR}/mempool-osd${i}-${LABEL}-pre.json" 2>/dev/null || true
    done

    # 起跑时间
    RUN_START=$(date +%s)

    # 跑 V4
    log "  Starting V4: ITEMS=mseqread randread SKIP_REMOUNT=1 ${LABEL} 180 5"
    set +e
    ITEMS="mseqread randread" SKIP_REMOUNT=1 bash "${V4_SCRIPT}" "${LABEL}" 180 5
    V4_RC=$?
    set -e
    RUN_END=$(date +%s)
    RUN_ELAPSED=$(( (RUN_END - RUN_START) / 60 ))
    log "  V4 done: rc=${V4_RC} elapsed=${RUN_ELAPSED}min"

    # H1 数据 post-run
    log "  Collecting H1 post-run data..."
    for i in 0 1 2 3 4 5; do
        sudo ceph tell osd.$i perf dump > "${RESULTS_DIR}/perf-osd${i}-${LABEL}-post.json" 2>/dev/null || true
        sudo ceph tell osd.$i dump_mempools > "${RESULTS_DIR}/mempool-osd${i}-${LABEL}-post.json" 2>/dev/null || true
    done

    # forced-mount 检查
    if grep -q "forced-mount" "${OUTDIR}/jfs-instance-${LABEL}.txt" 2>/dev/null; then
        log "STOP: forced-mount on ${LABEL}"
        restore_balanced
        exit 1
    fi

    # 档位监视：提取 randread median (from V4 steady_state_eval)
    RANDREAD_MEDIAN=$(grep "randread: n=" "${OUTDIR}/test.log" 2>/dev/null | tail -1 | sed -n 's/.*median=\([0-9]*\).*/\1/p')
    [ -z "${RANDREAD_MEDIAN}" ] && RANDREAD_MEDIAN=0
    log "  randread median: ${RANDREAD_MEDIAN}"

    if [ "${RANDREAD_MEDIAN}" -gt 0 ]; then
        if [ -z "${FIRST_RUN_RANDREAD}" ]; then
            FIRST_RUN_RANDREAD="${RANDREAD_MEDIAN}"
            log "  First run randread=${FIRST_RUN_RANDREAD} (baseline for gear monitor)"
        fi

        GEAR_OK=true
        if [ "${RANDREAD_MEDIAN}" -lt "${GEAR_LOW}" ] || [ "${RANDREAD_MEDIAN}" -gt "${GEAR_HIGH}" ]; then
            log "  GEAR WARNING: ${RANDREAD_MEDIAN} outside [${GEAR_LOW},${GEAR_HIGH}]"
            GEAR_OK=false
        fi

        DEVIATION=$(python3 -c "print(round(abs(${RANDREAD_MEDIAN} - ${FIRST_RUN_RANDREAD}) / ${FIRST_RUN_RANDREAD} * 100, 2))" 2>/dev/null || echo "0")
        log "  deviation from first run: ${DEVIATION}%"
        GEAR_DRIFT=$(python3 -c "print(1 if ${DEVIATION} > 2.0 else 0)" 2>/dev/null || echo "0")
        if [ "${GEAR_OK}" = "false" ] || [ "${GEAR_DRIFT}" = "1" ]; then
            log "STOP: gear drift detected (median=${RANDREAD_MEDIAN}, deviation=${DEVIATION}%)"
            restore_balanced
            exit 1
        fi
    fi

    # 记录 ceph df
    sudo ceph df 2>/dev/null | grep juicefs-data >> "${RESULTS_DIR}/ceph-df-per-run.txt"

    log "  Run ${LABEL} complete"
done

# 收尾
log "=== RESTORING balanced ==="
restore_balanced

sudo ceph config dump > "${RESULTS_DIR}/config-snapshot-post.txt" 2>/dev/null || true

log "=== T1.0 INTERLEAVE WRAPPER DONE ==="
log "=== $(date) ==="
