#!/usr/bin/env bash
# t37l-seg3.sh — 段3：K7 筛查（A B A B）
# 注意：原任务书 §七最后一行 $OOUT 已修正为 $OUT
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
KEY=osd_mclock_max_capacity_iops_ssd
sudo ceph config dump > "$OUT/config-snapshot-pre.txt"

echo "=== SEG3 START $(date) ===" | tee -a "$OUT/progress.txt"

for run in 1 2 3 4; do
  if [ $((run % 2)) -eq 1 ]; then ARM=A; sudo ceph config rm osd.3 $KEY >> "$OUT/knob.log" 2>&1
  else ARM=B; sudo ceph config set osd.3 $KEY 70000 >> "$OUT/knob.log" 2>&1; fi
  LABEL="T37L-K7-${ARM}$(( (run+1)/2 ))"
  sleep 60
  printf '%s\t%s\tosd.3\t%s\n' "$LABEL" "$KEY" \
    "$(sudo ceph tell osd.3 config get $KEY 2>/dev/null | tr -d '\n')" >> "$OUT/knob-verify.tsv"

  avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
  [ "${avail:-0}" -lt 5 ] && { echo "STOP disk ${avail}G"; break; }

  bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
  for it in randread randrw; do
    bash "$INSTR" start "$OUT" "${it}-${LABEL}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$LABEL" 180 3 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
    echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$LABEL" ] && break
  done
  kill "$OW" 2>/dev/null || true
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  echo "$LABEL arm=$ARM max_read=$mr want=262144 rc=${rc:-NA}" | tee -a "$OUT/arm-verify.txt"
  { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
done

sudo ceph config rm osd.3 $KEY >> "$OUT/knob.log" 2>&1; sleep 60
sudo ceph config dump > "$OUT/config-snapshot-post.txt"
diff "$OUT/config-snapshot-pre.txt" "$OUT/config-snapshot-post.txt" > "$OUT/config-diff.txt" 2>&1 || true

echo "=== SEG3 DONE $(date) ===" | tee -a "$OUT/progress.txt"
