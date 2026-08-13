#!/usr/bin/env bash
# t37l-seg2.sh — 段2：写侧 128K vs 256K 交错
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000
declare -A WANT=([F]=131072 [S]=262144)
BASE="--max-uploads 150 --cache-size 0"

echo "=== SEG2 START $(date) ===" | tee -a "$OUT/progress.txt"

for spec in F:1 S:1 F:2 S:2; do
  arm="${spec%%:*}"; idx="${spec##*:}"; LABEL="T37L-W${arm}${idx}"
  case "$arm" in F) IO=128K;; S) IO=256K;; esac
  OPTS="$BASE --max-fuse-io $IO"

  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
  [ "${avail:-0}" -lt 5 ] && { echo "STOP disk ${avail}G"; break; }

  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { echo "STOP umount failed"; break; }
  juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
  sleep 5
  mr_pre=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr_pre:-0}" != "${WANT[$arm]}" ] && { echo "$LABEL max_read PRE MISMATCH $mr_pre" | tee -a "$OUT/arm-verify.txt"; break; }
  pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}' \
    | while read -r q; do echo "$LABEL pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" >> "$OUT/instances.txt"; done

  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in randwrite randrw; do
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && { echo "$LABEL OBJ_BREACH"; break; }
  done
  kill "$OW" 2>/dev/null || true

  mr_post=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  echo "$LABEL arm=$arm opts='$OPTS' rc=${rc:-NA} max_read_pre=$mr_pre max_read_post=$mr_post want=${WANT[$arm]}" \
    | tee -a "$OUT/arm-verify.txt"
  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
done

echo "=== SEG2 DONE $(date) ===" | tee -a "$OUT/progress.txt"
