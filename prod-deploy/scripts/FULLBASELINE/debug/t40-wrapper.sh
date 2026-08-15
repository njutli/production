#!/usr/bin/env bash
# t40-wrapper.sh — 03-10：补丁版 256K 全 7 项基线（2 挂载，夜间长块）
# 目的：补丁路线固化证据集 + 填 seqwrite/mseqwrite/seqread@256K 未测格 + F44 meta 率再确认
# 判据见任务书 §三；🔴 统计由 opencode 复算，本脚本只采集+判档门（t39-nsbgate.sh）。
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.10; GATE=/tmp/t39-nsbgate.sh
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
PATCHED="/tmp/juicefs-03-8"
OBJWATCH=/tmp/t40-objwatch.sh
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=12000000 SKIP_REMOUNT=1 I2B_SEC=30
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

# objwatch HARD 8M→12M（本任务 2 挂载全 7 项，对象净增预估 ~7M；声明改动）
sed 's/HARD=8000000/HARD=12000000/' /tmp/t37l-objwatch.sh > "$OBJWATCH" && chmod +x "$OBJWATCH"
echo "objwatch HARD=12M (declared: 本任务 2 挂载全项，起始 2.36M 对象)" | tee -a "$OUT/wrapper.log"

# ---- 环境前置 ----
H=$(sudo ceph health 2>&1 | head -1)
echo "ceph_health_start: $H $(date '+%F %T')" | tee -a "$OUT/health.txt"
echo "$H" | grep -q HEALTH_OK || { log "STOP ceph health 非 OK：$H"; exit 2; }
avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
[ "${avail:-0}" -lt 5 ] && { log "STOP /tmp 余量 ${avail}G < 5G"; exit 2; }
objs=$(sudo ceph df --format=json 2>/dev/null | python3 -c "import json,sys;print([x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data'][0]['stats']['objects'])" 2>/dev/null || echo NA)
echo "pool_objects_start=$objs" | tee -a "$OUT/health.txt"
[ "${objs:-0}" -gt 12000000 ] 2>/dev/null && { log "STOP 起始对象已超 12M"; exit 2; }

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

mount_p() {   # $1=label → 0=挂载成功且 max_read 正确
  local lab="$1" mr q
  umount_jfs || return 2
  "$PATCHED" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mount | grep -q juice || { log "$lab mount failed"; return 2; }
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr:-0}" = "262144" ] || { log "$lab max_read=${mr:-NA} ≠262144 FAIL"; return 1; }
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  echo "$lab arm=P bin=$PATCHED max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" | tee -a "$OUT/instances.txt"
  echo "$lab arm=P bin=$PATCHED max_read=$mr want=262144" | tee -a "$OUT/arm-verify.txt"
  return 0
}

verify_instance() {
  local q st
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  st=$(awk '{print $22}' /proc/$q/stat 2>/dev/null || echo NA)
  echo "verify pid=$q starttime_ticks=$st $(date '+%F %T')" | tee -a "$OUT/instances.txt"
}

# ---- 2 挂载（P1 P2），每挂载：判档门（≤3 试，重试换 label）→ 全 7 项 V4 ----
for idx in 1 2; do
  LAB="T40-P${idx}"
  ok=0
  for t in 1 2 3; do
    LTRY="$LAB"; [ $t -gt 1 ] && LTRY="${LAB}-t${t}"
    log "=== T40 P${idx} try=$t label=$LTRY ==="
    mount_p "$LTRY" || { echo "$LTRY try=$t mount FAIL" >> "$OUT/remount-retry.log"; continue; }
    bash "$INSTR" start "$OUT" "probe-$LTRY"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread" bash "$V4" "PROBE-$LTRY" 180 2 >> "$OUT/wrapper.log" 2>&1
    bash "$INSTR" stop "$OUT" "probe-$LTRY"
    GATELOG=$(bash "$GATE" /tmp/opencode-fullbaseline-v4 "PROBE-$LTRY" mseqread 2>&1 | tee -a "$OUT/probe-gate.log")
    echo "$GATELOG" | grep -q "verdict=PASS" && { ok=1; EFF="$LTRY"; break; }
    echo "$LTRY try=$t 判档 FAIL ⇒ remount" | tee -a "$OUT/remount-retry.log"
  done
  [ "$ok" = 1 ] || { log "STOP T40 P${idx} 三次判档 FAIL ⇒ 停，回报"; exit 3; }
  log "gate PASS: label=$EFF"
  verify_instance "$EFF"

  # 全 7 项 × 2 轮（V4 默认 ITEMS 顺序：seqread mseqread randread randrw seqwrite mseqwrite randwrite）
  bash "$OBJWATCH" "$OUT" "$EFF" & OW=$!
  for it in seqread mseqread randread randrw seqwrite mseqwrite randwrite; do
    bash "$INSTR" start "$OUT" "${it}-${EFF}"
    JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="$it" bash "$V4" "$EFF" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
    bash "$INSTR" stop "$OUT" "${it}-${EFF}"
    verify_instance "$EFF"
    echo "$EFF item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ -f "$OUT/OBJ_BREACH-$EFF" ] && { log "$EFF OBJ_BREACH 停"; break; }
  done
  kill "$OW" 2>/dev/null || true
  { echo "=== $EFF end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
  log "$EFF done"
done

# ---- 收尾：恢复 128K 默认挂载 ----
umount_jfs
juicefs mount -d --max-uploads 150 --cache-size 0 "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "RESTORED max_read=$mr want=131072" | tee -a "$OUT/arm-verify.txt"
log "=== T40 WRAPPER DONE $(date) ==="
