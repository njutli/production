#!/bin/bash
set -euo pipefail
export LC_ALL=C

EXPECTED_PID=1631722
EXPECTED_ST=1502152363
V4_SCRIPT="/tmp/FULLBASELINE_V4.sh"
N=10
Y1_T0=$(date -d "2026-08-06 21:18:01" +%s 2>/dev/null || echo 0)
WALL_LIMIT=$((Y1_T0 + 39600))

log() { echo "[$(date '+%F %T')] $*"; }

log "=== Y2-Y${N} LOOP START ==="
log "=== wall limit: $(date -d @${WALL_LIMIT} '+%F %T' 2>/dev/null || echo ${WALL_LIMIT}) ==="

cat > /tmp/opencode-y-drift/commands.sh << 'CMDS'
# Y1: ITEMS="seqread mseqread randread" SKIP_REMOUNT=1 bash /tmp/FULLBASELINE_V4.sh Y1 180 5
# Y2-Y10: same command, per-run pre-flight (health + pid + disk)
CMDS

for i in $(seq 2 ${N}); do
    LABEL="Y${i}"

    NOW=$(date +%s)
    [ ${NOW} -lt ${WALL_LIMIT} ] || { log "STOP: wall clock T+11h reached"; break; }

    log "=== ${LABEL} pre-flight ==="
    HEALTH=$(sudo ceph health 2>/dev/null || echo "ERROR")
    log "  health: ${HEALTH}"
    [ "${HEALTH}" = "HEALTH_OK" ] || { log "STOP: health=${HEALTH}"; break; }

    PID=$(pgrep -f "^juicefs mount" | head -1)
    ST=$(awk '{print $22}' /proc/${PID}/stat 2>/dev/null || echo "NA")
    log "  pid=${PID} st=${ST} (expect ${EXPECTED_PID}/${EXPECTED_ST})"
    [ "${PID}" = "${EXPECTED_PID}" ] || { log "STOP: pid changed"; break; }
    [ "${ST}" = "${EXPECTED_ST}" ] || { log "STOP: starttime changed"; break; }

    AVAIL=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
    log "  disk: ${AVAIL}G available"
    [ "${AVAIL}" -ge 25 ] || { log "STOP: disk <25G"; break; }

    log "=== ${LABEL} run start ==="
    set +e
    ITEMS="seqread mseqread randread" SKIP_REMOUNT=1 bash "${V4_SCRIPT}" "${LABEL}" 180 5
    RC=$?
    set -e
    log "=== ${LABEL} run done: rc=${RC} ==="

    sudo ceph df 2>/dev/null | grep juicefs-data >> /tmp/opencode-y-drift/ceph-df-per-run.txt

    if grep -q "forced-mount" "/tmp/opencode-fullbaseline-v4/jfs-instance-${LABEL}.txt" 2>/dev/null; then
        log "STOP: forced-mount on ${LABEL}"
        break
    fi
done

log "=== Y2-Y${N} LOOP DONE ==="
