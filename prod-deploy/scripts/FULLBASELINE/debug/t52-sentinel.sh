#!/usr/bin/env bash
# t52-sentinel.sh — per-mount thread sentinel for 03-17f
# Usage: bash t52-sentinel.sh <label> <expected_msgr> <mount_point>
# Output: /tmp/t52-sentinel/<label>-threads.tsv
# STOP file: /tmp/t52-sentinel/<label>-STOP.txt
set -euo pipefail
export LC_ALL=C

LABEL="$1"
EXPECTED="$2"
MNT="${3:-/mnt/juicefs}"
OUTDIR=/tmp/t52-sentinel
mkdir -p "$OUTDIR"
OUTFILE="$OUTDIR/${LABEL}-threads.tsv"
STOPFILE="$OUTDIR/${LABEL}-STOP.txt"

# Find the juicefs IO process PID
find_pid() {
  local mnt_line pid best="" newest_st=0
  mnt_line=$(awk -v m="$MNT" '$2==m {print; exit}' /proc/mounts 2>/dev/null || true)
  [[ -n "$mnt_line" ]] || return 0
  # Find all juicefs mount processes for this mountpoint
  for p in $(pgrep -f "juicefs-03-8 mount" 2>/dev/null || true); do
    [[ -r "/proc/$p/stat" ]] || continue
    local st ppid
    st=$(awk '{print $22}' "/proc/$p/stat" 2>/dev/null || echo 0)
    ppid=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 0)
    # Prefer the child process (ppid matches another juicefs pid)
    if echo "$(pgrep -f 'juicefs-03-8' 2>/dev/null || true)" | grep -qx "$ppid" 2>/dev/null; then
      best="$p"
      break
    fi
    [[ -z "$best" ]] && best="$p"
  done
  echo "$best"
}

PID=""
STARTTIME=""
printf 'ts\tpid\tmsgr_workers\tio_context_pool\tworker_cpu_detail\n' > "$OUTFILE"

GRACE_DEADLINE=$(($(date +%s) + 30))
ZERO_COUNT=0

while true; do
  ts=$(date +%s)
  
  # Re-find PID if lost
  if [[ -z "$PID" ]] || [[ ! -r "/proc/$PID/stat" ]]; then
    PID=$(find_pid)
    if [[ -n "$PID" ]]; then
      STARTTIME=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null || echo NA)
      echo "[$(date '+%F %T')] sentinel: pid=$PID starttime=$STARTTIME expected_msgr=$EXPECTED" >> "$OUTDIR/${LABEL}-log.txt"
    fi
  fi
  
  if [[ -z "$PID" ]] || [[ ! -d "/proc/$PID/task" ]]; then
    echo -e "${ts}\tNA\t0\t0\tNA" >> "$OUTFILE"
    sleep 5
    continue
  fi
  
  # Count msgr workers
  msgr=$(cat "/proc/$PID/task/"*/comm 2>/dev/null | grep -c '^msgr-worker' || true)
  ioctx=$(cat "/proc/$PID/task/"*/comm 2>/dev/null | grep -c '^io_context_pool' || true)
  
  # Per-worker CPU detail
  cpu_detail=""
  for d in "/proc/$PID/task/"*; do
    [[ -r "$d/stat" ]] || continue
    comm=$(cat "$d/comm" 2>/dev/null || true)
    [[ "$comm" =~ ^msgr-worker ]] || continue
    read -r _ ut st _ < <(awk '{print $1, $14, $15, $39}' "$d/stat" 2>/dev/null || true)
    cpu_detail="${cpu_detail}${comm}:${ut}+${st};"
  done
  
  echo -e "${ts}\t${PID}\t${msgr:-0}\t${ioctx:-0}\t${cpu_detail}" >> "$OUTFILE"
  
  # STOP check (after 30s grace)
  if [[ $ts -ge $GRACE_DEADLINE ]]; then
    if [[ "${msgr:-0}" == "0" ]] || [[ "${msgr:-0}" != "$EXPECTED" ]]; then
      ZERO_COUNT=$((ZERO_COUNT + 1))
      if [[ $ZERO_COUNT -ge 2 ]]; then
        echo "[$(date '+%F %T')] STOP msgr_workers=${msgr:-0} != $EXPECTED (consecutive $ZERO_COUNT times) at pid=$PID" > "$STOPFILE"
        echo "STOP written to $STOPFILE"
        break
      fi
    else
      ZERO_COUNT=0
    fi
  fi
  
  # Check if process still alive
  kill -0 "$PID" 2>/dev/null || {
    echo "[$(date '+%F %T')] sentinel: pid=$PID exited, stopping sentinel" >> "$OUTDIR/${LABEL}-log.txt"
    break
  }
  
  sleep 5
done

echo "[$(date '+%F %T')] sentinel $LABEL done" >> "$OUTDIR/${LABEL}-log.txt"
