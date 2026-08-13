#!/usr/bin/env bash
# t3.6-wrapper.sh — 03-6 --max-fuse-io A B C ×3 交错 9 挂载
set -uo pipefail
export LC_ALL=C

V4=/tmp/FULLBASELINE_V4.sh
INSTR=/tmp/instrument.sh
OUT=/tmp/opencode-t3.6
BASE_OPTS="--max-uploads 150 --cache-size 0"
mkdir -p "$OUT"

declare -A ARM=( [A]="128K" [B]="256K" [C]="1M" )
declare -A WANT=( [A]=131072 [B]=262144 [C]=1048576 )
FAILS=0
SKIP_COUNT="${SKIP_COUNT:-0}"   # skip first N mounts (resume)

log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

log "=== T3.6 WRAPPER START $(date) SKIP_COUNT=$SKIP_COUNT ==="

MOUNT_IDX=0
for cycle in 1 2 3; do
  for arm in A B C; do
    LABEL="T36-${arm}${cycle}"
    MOUNT_IDX=$((MOUNT_IDX + 1))

    # Skip already-done mounts
    if [ "${MOUNT_IDX}" -le "${SKIP_COUNT}" ]; then
      log "Skipping ${LABEL} (mount ${MOUNT_IDX} <= ${SKIP_COUNT})"
      continue
    fi

    OPTS="${BASE_OPTS} --max-fuse-io ${ARM[$arm]}"

    # (1) Disk / health
    avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
    [ "${avail:-0}" -lt 5 ] && { log "STOP disk ${avail}G <5G"; break 2; }
    health=$(sudo ceph health 2>/dev/null || echo "ERROR")
    [ "${health}" = "HEALTH_OK" ] || { log "STOP health=${health}"; break 2; }

    # (2) Instrument start
    log "=========== ${LABEL} arm=${arm} fuse-io=${ARM[$arm]} ==========="
    bash "$INSTR" start "$OUT" "$LABEL"
    sleep 2

    # (3) V4 with --remount
    RUN_START=$(date +%s)
    log "  Starting V4: ${LABEL} opts='${OPTS}'"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread randread randrw" \
      bash "$V4" "$LABEL" 180 2 --remount >> "$OUT/v4-${LABEL}.log" 2>&1
    rc=$?
    RUN_MIN=$(( ($(date +%s) - RUN_START) / 60 ))

    # (4) Instrument stop
    bash "$INSTR" stop "$OUT" "$LABEL"

    # (5) max_read verify
    mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
    echo "${LABEL} arm=${arm} opts='${OPTS}' rc=${rc} max_read=${mr} want=${WANT[$arm]}" | tee -a "$OUT/arm-verify.txt"
    [ "${mr:-0}" != "${WANT[$arm]}" ] && echo "${LABEL} max_read MISMATCH" >> "$OUT/arm-verify.txt"

    # (6) Instance record
    pid=$(pgrep -af juicefs | awk '/mount/{print $1;exit}')
    echo "${LABEL} pid=${pid} starttime_ticks=$(awk '{print $22}' /proc/${pid}/stat 2>/dev/null)" >> "$OUT/instances.txt"

    # (7) Progress
    echo "${LABEL} arm=${arm} rc=${rc} max_read=${mr} ts=$(date '+%F %T')" >> "$OUT/progress.txt"

    # (8) Health record
    { echo "=== ${LABEL} $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"

    # (9) Consecutive failure (rc=1 is V4 summary known issue with 3-item runs, only rc>=2 counts)
    if [ "${rc}" -ge 2 ]; then
      FAILS=$((FAILS+1))
      log "  ${LABEL} rc=${rc} (consecutive ${FAILS})"
      [ "${FAILS}" -ge 2 ] && { log "STOP 2 consecutive real failures"; break 2; }
    else
      FAILS=0
    fi

    # (10) First mount checkpoint
    if [ "${LABEL}" = "T36-A1" ]; then
      log "=== FIRST MOUNT CHECKPOINT — stopping for confirmation ==="
      python3 /tmp/latency-budget.py /tmp/opencode-fullbaseline-v4 T36-A1 \
        --instr "$OUT" | tee "$OUT/checkpoint-A1.txt" 2>&1
      log "  Waiting for confirmation. To resume: SKIP=1 bash /tmp/t3.6-wrapper.sh"
      break 2
    fi

    log "  ${LABEL} done"
  done
done

log "=== T3.6 WRAPPER DONE $(date) ==="
