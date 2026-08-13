#!/usr/bin/env bash
# /tmp/t37l-osdknobs.sh — K3/K4/K7 单实例内 ABBA 筛查
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000 SKIP_REMOUNT=1

# ---- 挂一次 256K，全程复用（单实例配对）----
P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
[ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
MR=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
[ "${MR:-0}" != "262144" ] && { echo "STOP OSD块 max_read=$MR !=262144"; exit 1; }
Q0=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
T0=$(awk '{print $22}' /proc/$Q0/stat)
echo "OSDBLOCK_BEGIN pid=$Q0 starttime_ticks=$T0 max_read=$MR $(date '+%F %T')" | tee -a "$OUT/instances.txt"
sudo ceph config dump > "$OUT/config-snapshot-pre.txt"

echo "=== OSDBLOCK START $(date) ===" | tee -a "$OUT/progress.txt"

settle() {
  local t0=$(date +%s) ok=0 i st rec wb
  for i in $(seq 1 60); do
    st=$(sudo ceph status --format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); p=d['pgmap']
    print(int(p.get('recovering_objects_per_sec',0)), int(p.get('write_bytes_sec',0)))
except Exception: print('ERR 0')")
    rec=$(echo "$st" | awk '{print $1}'); wb=$(echo "$st" | awk '{print $2}')
    [ "$rec" = ERR ] && { sleep 10; continue; }
    if [ "${rec:-1}" -eq 0 ] 2>/dev/null && [ "${wb:-99999999}" -lt 10485760 ] 2>/dev/null; then
      ok=$((ok+1)); [ "$ok" -ge 3 ] && break
    else ok=0; fi
    sleep 10
  done
  echo "settle label=$1 sec=$(( $(date +%s) - t0 )) consecutive_quiet=$ok $(date '+%F %T')" >> "$OUT/settle.txt"
}

KNOBS=(
 "K3|sudo ceph config set osd bluestore_throttle_bytes 268435456;sudo ceph config set osd bluestore_throttle_deferred_bytes 536870912|sudo ceph config rm osd bluestore_throttle_bytes;sudo ceph config rm osd bluestore_throttle_deferred_bytes|randwrite randrw|bluestore_throttle_bytes bluestore_throttle_deferred_bytes|osd"
 "K4|sudo ceph config set osd bluestore_prefer_deferred_size_ssd 65536;sudo ceph config set osd bluestore_deferred_batch_ops_ssd 64|sudo ceph config rm osd bluestore_prefer_deferred_size_ssd;sudo ceph config rm osd bluestore_deferred_batch_ops_ssd|randwrite randrw|bluestore_prefer_deferred_size_ssd bluestore_deferred_batch_ops_ssd|osd"
 "K7|sudo ceph config set osd.3 osd_mclock_max_capacity_iops_ssd 70000|sudo ceph config rm osd.3 osd_mclock_max_capacity_iops_ssd|randread randrw|osd_mclock_max_capacity_iops_ssd|osd.3"
)
SEQ=(A B B A)

for entry in "${KNOBS[@]}"; do
  IFS='|' read -r KID SETC RMC ITEMS_K KEYS SCOPE <<< "$entry"
  declare -A IDX=([A]=0 [B]=0)
  for run in 1 2 3 4; do
    ARM=${SEQ[$((run-1))]}; IDX[$ARM]=$(( ${IDX[$ARM]} + 1 ))
    LABEL="T37L-${KID}-${ARM}${IDX[$ARM]}"
    if [ "$ARM" = A ]; then CMD="$RMC"; else CMD="$SETC"; fi
    IFS=';' read -ra CS <<< "$CMD"; for c in "${CS[@]}"; do eval "$c" >> "$OUT/knob.log" 2>&1; done
    settle "$LABEL"
    if [ "$SCOPE" = osd ]; then RANGE="0 1 2 3 4 5"; else RANGE="3"; fi
    for k in $KEYS; do for i in $RANGE; do
      printf '%s\t%s\t%s\tosd.%s\t%s\n' "$LABEL" "$ARM" "$k" "$i" \
        "$(sudo ceph tell osd.$i config get $k 2>/dev/null | tr -d '\n')" >> "$OUT/knob-verify.tsv"
    done; done

    avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
    [ "${avail:-0}" -lt 5 ] && { echo "STOP disk ${avail}G"; break 2; }
    bash /tmp/t37l-objwatch.sh "$OUT" "$LABEL" & OW=$!
    for it in $ITEMS_K; do
      bash "$INSTR" start "$OUT" "${it}-${LABEL}"
      ITEMS="$it" bash "$V4" "$LABEL" 180 3 >> "$OUT/wrapper.log" 2>&1; rc=$?
      bash "$INSTR" stop "$OUT" "${it}-${LABEL}"
      echo "$LABEL item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
      [ -f "$OUT/OBJ_BREACH-$LABEL" ] && break
    done
    kill "$OW" 2>/dev/null || true
    QN=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
    echo "$LABEL pid_now=$QN pid_begin=$Q0 same=$([ "$QN" = "$Q0" ] && echo YES || echo NO)" >> "$OUT/instances.txt"
    [ "$QN" != "$Q0" ] && { echo "RED $LABEL instance changed, stop"; break 2; }
    { echo "=== $LABEL $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
  done
  IFS=';' read -ra RS <<< "$RMC"; for c in "${RS[@]}"; do eval "$c" >> "$OUT/knob.log" 2>&1; done
  settle "${KID}-restored"
done

QE=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
echo "OSDBLOCK_END pid=$QE starttime_ticks=$(awk '{print $22}' /proc/$QE/stat) same_as_begin=$([ "$QE" = "$Q0" ] && echo YES || echo NO)" | tee -a "$OUT/instances.txt"
sudo ceph config dump > "$OUT/config-snapshot-post.txt"
diff "$OUT/config-snapshot-pre.txt" "$OUT/config-snapshot-post.txt" > "$OUT/config-diff.txt" 2>&1 || true

echo "=== OSDBLOCK DONE $(date) ===" | tee -a "$OUT/progress.txt"
