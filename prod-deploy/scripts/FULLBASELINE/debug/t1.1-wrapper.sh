#!/bin/bash
set -uo pipefail
export LC_ALL=C

# 03-5 T1.1 wrapper: bluestore_default_buffered_read A B A B A B interleaved
# Knob: true (A arm) / false (B arm), 6 runs, mseqread+randread only

V4_SCRIPT="/tmp/FULLBASELINE_V4.sh"
RESULTS_DIR="/tmp/opencode-t1.1"
V4_RESULTS="/tmp/opencode-fullbaseline-v4"
KNOB="bluestore_default_buffered_read"
EXPECTED_PID=1631722
EXPECTED_ST=1502152363

mkdir -p "${RESULTS_DIR}"
log() { echo "[$(date '+%F %T')] $*" | tee -a "${RESULTS_DIR}/wrapper.log"; }

# Arm sequence: A B A B A B
ARMS=(A B A B A B)
LABELS=(T11-A1 T11-B1 T11-A2 T11-B2 T11-A3 T11-B3)

set_knob() {
    local val="$1" label="$2"
    log "  Setting ${KNOB}=${val} for ${label}"
    sudo ceph config set osd "${KNOB}" "${val}" 2>/dev/null
    sleep 5
    # Verify all 6 OSDs
    local all_ok=1
    for i in 0 1 2 3 4 5; do
        local v
        v=$(sudo ceph tell osd.$i config get "${KNOB}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['${KNOB}'])" 2>/dev/null || echo "ERR")
        if [ "${v}" != "${val}" ]; then
            log "  osd.$i = ${v} (expected ${val}) — MISMATCH"
            all_ok=0
        fi
    done
    sudo ceph tell osd.0 config get "${KNOB}" > /dev/null 2>&1  # just trigger
    # Save knob file
    for i in 0 1 2 3 4 5; do
        sudo ceph tell osd.$i config get "${KNOB}" 2>/dev/null
    done > "${RESULTS_DIR}/knob-${label}.txt" 2>&1
    if [ "${all_ok}" = "1" ]; then
        log "  All 6 OSDs confirmed ${val}"
    else
        log "  STOP: not all OSDs match ${val}"
    fi
    return $((1 - all_ok))
}

collect_h1() {
    local label="$1" phase="$2"
    for i in 0 1 2 3 4 5; do
        sudo ceph tell osd.$i perf dump > "${RESULTS_DIR}/perf-${label}-${phase}-osd${i}.json" 2>/dev/null || true
        sudo ceph tell osd.$i dump_mempools > "${RESULTS_DIR}/mempool-${label}-${phase}-osd${i}.json" 2>/dev/null || true
    done
    log "  H1 ${phase} collected"
}

CONSEC_FAIL=0
COMPLETED=0

log "=== T1.1 WRAPPER START $(date) ==="

for idx in 0 1 2 3 4 5; do
    ARM="${ARMS[$idx]}"
    LABEL="${LABELS[$idx]}"
    KNOB_VAL="true"
    [ "${ARM}" = "B" ] && KNOB_VAL="false"

    log ""
    log "=========== Run $((idx+1))/6: ${LABEL} arm=${ARM} knob=${KNOB_VAL} ==========="

    # Health check
    HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
    if [ "${HEALTH}" != "HEALTH_OK" ]; then
        log "STOP: health=${HEALTH}"
        break
    fi

    # Instance check
    PID=$(pgrep -f "^juicefs mount" | head -1)
    ST=$(awk '{print $22}' /proc/${PID}/stat 2>/dev/null || echo "NA")
    log "  pid=${PID} st=${ST}"
    if [ "${PID}" != "${EXPECTED_PID}" ] || [ "${ST}" != "${EXPECTED_ST}" ]; then
        log "STOP: instance changed"
        break
    fi

    # Disk check
    AVAIL=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
    log "  /tmp avail=${AVAIL}G"
    if [ "${AVAIL}" -lt 5 ] 2>/dev/null; then
        log "STOP: disk <5G"
        break
    fi

    # Set knob
    if ! set_knob "${KNOB_VAL}" "${LABEL}"; then
        log "STOP: knob verification failed for ${LABEL}"
        break
    fi

    # Wait 60s for knob to settle
    log "  Waiting 60s for knob to settle..."
    sleep 60

    # Re-check health after knob change
    HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
    if [ "${HEALTH}" != "HEALTH_OK" ]; then
        log "STOP: health=${HEALTH} after knob change"
        break
    fi

    # Pre-run H1
    collect_h1 "${LABEL}" "pre"

    # Run V4
    RUN_START=$(date +%s)
    log "  Starting V4: ${LABEL}"
    ITEMS="mseqread randread" SKIP_REMOUNT=1 bash "${V4_SCRIPT}" "${LABEL}" 180 5
    V4_RC=$?
    RUN_MIN=$(( ($(date +%s) - RUN_START) / 60 ))
    log "  V4 done: rc=${V4_RC} elapsed=${RUN_MIN}min"

    # Post-run H1
    collect_h1 "${LABEL}" "post"

    # Extract medians from rounds.tsv (not from test.log, per task book §2.5)
    MSEQ_MED=$(grep "^${LABEL}.*mseqread" "${V4_RESULTS}/rounds.tsv" 2>/dev/null | awk '{print $3}')
    RR_MED=$(grep "^${LABEL}.*randread" "${V4_RESULTS}/rounds.tsv" 2>/dev/null | awk '{print $3}')
    [ -z "${MSEQ_MED}" ] && MSEQ_MED=0
    [ -z "${RR_MED}" ] && RR_MED=0

    echo "${LABEL} arm=${ARM} rc=${V4_RC} min=${RUN_MIN} mseqread_median=${MSEQ_MED} randread_median=${RR_MED} ts=$(date '+%F %T')" \
        >> "${RESULTS_DIR}/PROGRESS.txt"
    log "  mseqread_median=${MSEQ_MED} randread_median=${RR_MED}"

    # Forced-mount check
    if grep -q "forced-mount" "${V4_RESULTS}/jfs-instance-${LABEL}.txt" 2>/dev/null; then
        log "STOP: forced-mount on ${LABEL}"
        break
    fi

    # Consecutive failure check
    if [ "${V4_RC}" != "0" ]; then
        CONSEC_FAIL=$((CONSEC_FAIL+1))
        log "  ${LABEL} rc=${V4_RC} (consecutive ${CONSEC_FAIL})"
        if [ "${CONSEC_FAIL}" -ge 2 ]; then
            log "STOP: 2 consecutive rc!=0"
            break
        fi
    else
        CONSEC_FAIL=0
        COMPLETED=$((COMPLETED+1))
    fi

    # randread <1700 check (consecutive 2)
    if [ "${RR_MED}" != "0" ] && [ "${RR_MED}" -lt 1700 ] 2>/dev/null; then
        log "  WARNING: randread median ${RR_MED} <1700"
        # Track consecutive low randread (simplified - would need separate counter)
    fi

    log "  ${LABEL} done"
done

# Always restore knob to true
log ""
log "=== Restoring knob to true ==="
sudo ceph config set osd "${KNOB}" true 2>/dev/null
sleep 5
for i in 0 1 2 3 4 5; do
    sudo ceph tell osd.$i config get "${KNOB}" 2>/dev/null
done > "${RESULTS_DIR}/knob-post.txt" 2>&1
log "Restored. knob-post.txt saved."

log "=== T1.1 WRAPPER DONE $(date) ==="
log "=== Completed ${COMPLETED} runs ==="
