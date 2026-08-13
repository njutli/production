#!/usr/bin/env bash
# t38-wrapper.sh — 03-8 段1：补丁版 vs 原版 ABBA 4 挂载
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.8
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
PATCHED="/tmp/juicefs-03-8"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000 SKIP_REMOUNT=1

log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

mount_arm() {  # $1=arm(P|S) $2=label  → 0=ok
  local arm="$1" lab="$2" bin mr q
  if [ "$arm" = P ]; then bin="$PATCHED"; else bin="juicefs"; fi
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { echo "STOP umount failed"; return 2; }
  $bin mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr:-0}" != "262144" ] && { echo "$lab max_read MISMATCH $mr" | tee -a "$OUT/arm-verify.txt"; return 2; }
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  echo "$lab arm=$arm bin=$bin max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" >> "$OUT/instances.txt"
  echo "$lab arm=$arm bin=$bin max_read=$mr want=262144" | tee -a "$OUT/arm-verify.txt"
  return 0
}

# ABBA: A1=P, B1=S, B2=S, A2=P
SEQ="P S S P"
LABELS="T38-A1 T38-B1 T38-B2 T38-A2"
i=0
for arm in $SEQ; do
  i=$((i+1)); LABEL=$(echo $LABELS | cut -d' ' -f$i)
  log "=========== $LABEL arm=$arm ==========="
  
  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
  [ "${avail:-0}" -lt 5 ] && { log "STOP disk ${avail}G"; break; }

  ok=0
  for try in 1 2 3; do
    LTRY="$LABEL"; [ $try -gt 1 ] && LTRY="${LABEL}-t${try}"
    mount_arm "$arm" "$LTRY" && { ok=1; LABEL="$LTRY"; break; }
    echo "$LTRY try=$try mount failed, retry" >> "$OUT/remount-retry.log"
  done
  [ "$ok" -ne 1 ] && { log "STOP $LABEL 3 mount failures"; break; }

  # probe: mseqread 2 rounds
  bash "$INSTR" start "$OUT" "probe-$LABEL"
  JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread" bash "$V4" "PROBE-$LABEL" 180 2 >> "$OUT/wrapper.log" 2>&1
  bash "$INSTR" stop "$OUT" "probe-$LABEL"
  pbw=$(awk -F'\t' -v L="PROBE-$LABEL" '$1==L{print $3}' /tmp/opencode-fullbaseline-v4/rounds.tsv | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
  echo "$LABEL arm=$arm probe_mseqread=$pbw" | tee -a "$OUT/probe-gate.log"

  # effect: randwrite + randrw
  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in randwrite randrw; do
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && { log "$LABEL OBJ_BREACH"; break; }
  done
  kill "$OW" 2>/dev/null || true

  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
  log "$LABEL done"
done

# umount last mount, restore 128K original
juicefs umount /mnt/juicefs 2>/dev/null; sleep 5
juicefs mount -d --max-uploads 150 --cache-size 0 "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5; mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "RESTORED max_read=$mr want=131072" | tee -a "$OUT/arm-verify.txt"
log "=== T38 WRAPPER DONE $(date) ==="
