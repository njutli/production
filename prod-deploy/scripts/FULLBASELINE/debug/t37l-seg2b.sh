#!/usr/bin/env bash
# /tmp/t37l-seg2b.sh — 段2 补强：S3 F3，带探针门（detect-and-replace）
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000
declare -A WANT=([F]=131072 [S]=262144)
BASE="--max-uploads 150 --cache-size 0"
declare -A PLAT=([F]=4195 [S]=4230); PROBE_TOL=3

mount_arm() {
  local arm="$1" lab="$2" io mr q bw dev
  case "$arm" in F) io=128K;; S) io=256K;; esac
  local OPTS="$BASE --max-fuse-io $io"
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { echo "STOP umount 失败"; return 2; }
  juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr:-0}" != "${WANT[$arm]}" ] && { echo "$lab max_read MISMATCH $mr" | tee -a "$OUT/arm-verify.txt"; return 2; }
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  echo "$lab arm=$arm opts='$OPTS' max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" \
    >> "$OUT/instances.txt"
  bash "$INSTR" start "$OUT" "probe-$lab"
  JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread" bash "$V4" "PROBE-$lab" 180 2 >> "$OUT/wrapper.log" 2>&1
  bash "$INSTR" stop  "$OUT" "probe-$lab"
  bw=$(awk -F'\t' -v L="PROBE-$lab" '$1==L{print $3}' /tmp/opencode-fullbaseline-v4/rounds.tsv \
       | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
  local pf=${PLAT[$arm]}
  dev=$(python3 -c "print(round(abs($bw-$pf)/$pf*100,2))" 2>/dev/null || echo 99)
  echo "$lab arm=$arm probe_mseqread=$bw platform=$pf dev=${dev}% tol=${PROBE_TOL}%" | tee -a "$OUT/probe-gate.log"
  python3 -c "import sys; sys.exit(0 if $dev<=$PROBE_TOL else 1)" && return 0 || return 1
}

echo "=== SEG2B START $(date) ===" | tee -a "$OUT/progress.txt"

for spec in S:3 F:3; do
  arm="${spec%%:*}"; idx="${spec##*:}"; LABEL="T37L-W${arm}${idx}"
  ok=0
  for try in 1 2 3; do
    mount_arm "$arm" "$LABEL" && { ok=1; break; }
    echo "$LABEL try=$try 探针不合格或挂载失败 => 重新 remount" >> "$OUT/remount-retry.log"
  done
  [ "$ok" -ne 1 ] && { echo "$LABEL 三次探针均不合格 => 跳过该挂载并回报" >> "$OUT/remount-retry.log"; continue; }

  case "$arm" in F) IO=128K;; S) IO=256K;; esac
  OPTS="$BASE --max-fuse-io $IO"
  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
  [ "${avail:-0}" -lt 5 ] && { echo "STOP disk ${avail}G"; break; }
  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in randwrite randrw; do
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && break
  done
  kill "$OW" 2>/dev/null || true
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  echo "$LABEL arm=$arm max_read_post=$mr want=${WANT[$arm]} rc=${rc:-NA}" | tee -a "$OUT/arm-verify.txt"
  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
done

echo "=== SEG2B DONE $(date) ===" | tee -a "$OUT/progress.txt"
