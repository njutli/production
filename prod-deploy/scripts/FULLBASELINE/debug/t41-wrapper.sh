#!/usr/bin/env bash
# t41-wrapper.sh — 03-11：夜间补充包
#   段A：F44 敏感性 —— 补丁版 randwrite numjobs {32,64,128} × 1 轮（需求侧证明）
#   段B2：F42 第二实例 sweep（复用 t39-segB.sh）
#   段C：坏档率 p 精确化 —— 20 连挂 mseqread 探针（只读，stock 128K，直连 fio 不经 V4）
# 判据见任务书 §三；🔴 统计由 opencode 复算。
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.11; GATE=/tmp/t39-nsbgate.sh
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
TD=/mnt/juicefs/test_dir
PATCHED=/tmp/juicefs-03-8
RUN_A="${RUN_A:-1}"; RUN_B2="${RUN_B2:-1}"; RUN_C="${RUN_C:-1}"
mkdir -p "$OUT" "$OUT/bwlog"; export I2B_SEC=30
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

jfs_port() { sudo ss -tlnp 2>/dev/null | grep -i juicefs | awk '{print $4}' | grep -oE ':[0-9]+$' | head -1 | tr -d ':' ; }

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

direct_gate() {   # $1=label $2=item(默认 mseqread) → 0=ns/B 合格（I1 直连探针，不经 V4）
  local lab="$1" it="${2:-mseqread}" gateout
  bash "$INSTR" start "$OUT" "probe-$lab"
  if [ "$it" = mseqread ]; then
    fio --name=mseqread --directory="${TD}/mseqread/" \
        --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 \
        --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
        --time_based --runtime=180 > "$OUT/fio-probe-$lab.txt" 2>&1
  fi
  bash "$INSTR" stop "$OUT" "probe-$lab"
  gateout=$(bash "$GATE" --i1 "$OUT/i1-jfsstats-probe-$lab.tsv" 2>&1 | tee -a "$OUT/probe-gate.log")
  echo "$gateout" | grep -q "verdict=PASS"
}

# ===================== 段A：F44 敏感性 =====================
if [ "$RUN_A" = "1" ]; then
  log "===== 段A F44 敏感性（补丁版 randwrite numjobs 32/64/128）====="
  OBJWATCH=/tmp/t41-objwatch.sh
  sed 's/HARD=8000000/HARD=15000000/' /tmp/t37l-objwatch.sh > "$OBJWATCH" && chmod +x "$OBJWATCH"
  echo "objwatch HARD=15M (declared: 03-11 段A 3 点覆盖写)" | tee -a "$OUT/wrapper.log"
  H=$(sudo ceph health 2>&1 | head -1)
  echo "ceph_health_段A_start: $H $(date '+%F %T')" | tee -a "$OUT/health.txt"
  echo "$H" | grep -q HEALTH_OK || { log "STOP health 非 OK"; exit 2; }

  OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
  ok=0
  for t in 1 2 3; do
    LAB="T41A"; [ $t -gt 1 ] && LAB="T41A-t${t}"
    umount_jfs || continue
    "$PATCHED" mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
    mount | grep -q juice || { log "$LAB mount failed"; continue; }
    mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
    [ "${mr:-0}" = "262144" ] || { log "$LAB max_read=${mr:-NA} FAIL"; continue; }
    q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
    echo "$LAB arm=P bin=$PATCHED max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat) metrics_port=$(jfs_port)" | tee -a "$OUT/instances.txt"
    echo "$LAB arm=P bin=$PATCHED max_read=$mr want=262144" | tee -a "$OUT/arm-verify.txt"
    direct_gate "$LAB" && { ok=1; break; }
    echo "$LAB try=$t 判档 FAIL ⇒ remount" | tee -a "$OUT/remount-retry.log"
  done
  [ "$ok" = 1 ] || { log "STOP 段A 三次判档 FAIL"; exit 3; }
  log "段A gate PASS: $LAB"

  bash "$OBJWATCH" "$OUT" "$LAB" & OW=$!
  for j in 32 64 128; do
    tag="T41A-j${j}-r1"
    bash "$INSTR" start "$OUT" "$tag"
    fio --directory="$TD" --name=storage_test \
        --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs="$j" \
        --direct=1 --fallocate=none --openfiles=128 \
        --group_reporting --time_based --runtime=180 \
        --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 > "$OUT/fio-$tag.txt" 2>&1
    rc=$?
    bash "$INSTR" stop "$OUT" "$tag"
    printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$j" f44 "$rc" \
      "$(grep -E '^\s+WRITE: bw=' "$OUT/fio-$tag.txt" | head -1)" >> "$OUT/s1v3-bw.tsv"
    echo "$tag numjobs=$j rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    [ "$rc" -ne 0 ] && { log "STOP $tag rc=$rc"; break; }
    [ -f "$OUT/OBJ_BREACH-$LAB" ] && { log "$LAB OBJ_BREACH 停"; break; }
    sleep 20
  done
  kill "$OW" 2>/dev/null || true
  { echo "=== 段A end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; } >> "$OUT/health.txt"
  log "段A 写后 compact cooldown..."
  for osd in $(sudo ceph osd ls 2>/dev/null); do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
  sleep 30
fi

# ===================== 段B2：F42 第二实例 sweep（复用 t39-segB.sh）=====================
if [ "$RUN_B2" = "1" ]; then
  log "===== 段B2 F42 第二实例 sweep ====="
  OUT=/tmp/opencode-t3.11 LP=T41B RUN_SEGC=0 bash /tmp/t39-segB.sh >> "$OUT/wrapper.log" 2>&1 || log "SEGB2 异常退出（见上，回报不自行处理）"
fi

# ===================== 段C：p 精确化（20 连挂探针，只读，stock 128K）=====================
if [ "$RUN_C" = "1" ]; then
  log "===== 段C p 精确化：20 连挂 mseqread 探针 ====="
  OPTS="--max-uploads 150 --cache-size 0"   # 默认 128K，与参照群 n=15 同配置
  for i in $(seq 1 20); do
    LAB="T41C-m${i}"
    umount_jfs
    juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
    if ! mount | grep -q juice; then
      echo "$LAB FAIL mount $(date '+%F %T')" | tee -a "$OUT/p-probe.tsv"
      continue
    fi
    mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
    q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
    echo "$LAB max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat) metrics_port=$(jfs_port)" | tee -a "$OUT/instances.txt"
    [ "${mr:-0}" = "131072" ] && echo "$LAB max_read=131072 want=131072" | tee -a "$OUT/arm-verify.txt" \
      || echo "$LAB ⚑ max_read=$mr ≠131072" | tee -a "$OUT/arm-verify.txt"
    bash "$INSTR" start "$OUT" "probe-$LAB"
    fio --name=mseqread --directory="${TD}/mseqread/" \
        --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 \
        --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
        --time_based --runtime=180 > "$OUT/fio-probe-$LAB.txt" 2>&1
    rc=$?
    bash "$INSTR" stop "$OUT" "probe-$LAB"
    gateout=$(bash "$GATE" --i1 "$OUT/i1-jfsstats-probe-$LAB.tsv" 2>&1)
    nsb=$(echo "$gateout" | grep -oE 'ns/B=[0-9.]+' | head -1 | cut -d= -f2)
    verdict=$(echo "$gateout" | grep -oE 'verdict=\S+' | tail -1)
    bw=$(grep -E '^\s+READ: bw=' "$OUT/fio-probe-$LAB.txt" | head -1 | grep -oE '\([0-9.]+MiB/s\)' | grep -oE '[0-9.]+')
    echo "$LAB rc=$rc nsB=${nsb:-NA} ${verdict:-NA} probe_bw=${bw:-NA}" | tee -a "$OUT/p-probe.tsv" "$OUT/probe-gate.log"
    juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5
  done
fi

# ===================== 收尾：恢复 128K =====================
umount_jfs
juicefs mount -d --max-uploads 150 --cache-size 0 "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "RESTORED max_read=$mr want=131072" | tee -a "$OUT/arm-verify.txt"
{ echo "=== T41 end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
log "=== T41 WRAPPER DONE $(date) ==="
