#!/usr/bin/env bash
# t39-segA.sh — 03-9 段A：-o max_read 读写分离挂载验证（现网原版二进制，不依赖补丁）
# 目标：读请求 256K（吃 03-6 的 +115.6%）+ 写请求 128K（避开 03-8 的 FlushTo 竞态）
# 判据见任务书 §3.1；🔴 统计由 opencode 复算，本脚本只采集+首级门禁（ns/B 判档）。
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.9; GATE=/tmp/t39-nsbgate.sh
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
TD=/mnt/juicefs/test_dir
BASE="--max-uploads 150 --cache-size 0"
FORM1="$BASE --max-fuse-io 128K -o max_read=262144"    # 首选：写 128K、读拉满
FORM2="$BASE --max-fuse-io 256K -o max_write=131072"   # 备选（-o 顺序不生效时）：读 256K、写压回 128K
mkdir -p "$OUT"; export OBJ_GATE=1 OBJ_GC_PASSES=1 OBJ_MAX=6000000 SKIP_REMOUNT=1 I2B_SEC=30
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

# ---- 环境前置：ceph health 必须 OK（GUIDE §二.2）----
H=$(sudo ceph health 2>&1 | head -1)
echo "ceph_health_start: $H $(date '+%F %T')" | tee -a "$OUT/health.txt"
echo "$H" | grep -q HEALTH_OK || { log "STOP ceph health 非 OK：$H"; exit 2; }
avail=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
[ "${avail:-0}" -lt 5 ] && { log "STOP /tmp 余量 ${avail}G < 5G"; exit 2; }

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

# $1=OPTS $2=label → 0=挂载成功且 /proc/mounts 读写尺寸符合分离
mount_split() {
  local OPTS="$1" lab="$2" mr mw q
  umount_jfs || return 2
  juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mount | grep -q juice || { log "$lab mount failed"; return 2; }
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  mw=$(grep juicefs /proc/mounts | grep -o 'max_write=[0-9]*' | head -1 | cut -d= -f2)
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  echo "$lab opts='$OPTS' max_read=${mr:-NA} max_write=${mw:-UNSET} pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" | tee -a "$OUT/instances.txt"
  echo "$lab max_read=${mr:-NA} max_write=${mw:-UNSET} want_read=262144 want_write=131072" | tee -a "$OUT/arm-verify.txt"
  [ "${mr:-0}" = "262144" ] || { log "$lab max_read=${mr:-NA} ≠262144 FAIL"; return 1; }
  if [ -n "${mw:-}" ] && [ "$mw" != "131072" ]; then
    log "$lab max_write=$mw ≠131072 FAIL"; return 1
  fi
  [ -z "${mw:-}" ] && log "$lab ⚑ /proc/mounts 无 max_write 项 ⇒ 写侧以行为学验证为准（jfsstats 写尺寸，opencode 复核）"
  return 0
}

verify_instance() {   # $1=label → 打印当前实例身份，供 opencode 比对
  local q st
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  st=$(awk '{print $22}' /proc/$q/stat 2>/dev/null || echo NA)
  echo "verify pid=$q starttime_ticks=$st $(date '+%F %T')" | tee -a "$OUT/instances.txt"
}

# ---- 阶段1：挂载形式 + ns/B 判档门（GUIDE §二.10.4.1：重试必须换 label）----
ok=0; try=0
for FORM in "$FORM1" "$FORM2"; do
  for t in 1 2 3; do
    try=$((try+1)); LAB="T39-A1"; [ $try -gt 1 ] && LAB="T39-A1-t${try}"
    log "=== mount try=$try form='$FORM' label=$LAB ==="
    mount_split "$FORM" "$LAB" || { echo "$LAB try=$try form='$FORM' mount/verify FAIL" >> "$OUT/remount-retry.log"; continue; }
    # 探针门：mseqread 2 轮 → ns/B vs 3.287 ±10%
    bash "$INSTR" start "$OUT" "probe-$LAB"
    JUICEFS_MOUNT_OPTS="$FORM" ITEMS="mseqread" bash "$V4" "PROBE-$LAB" 180 2 >> "$OUT/wrapper.log" 2>&1
    bash "$INSTR" stop "$OUT" "probe-$LAB"
    GATELOG=$(bash "$GATE" /tmp/opencode-fullbaseline-v4 "PROBE-$LAB" mseqread 2>&1 | tee -a "$OUT/probe-gate.log")
    echo "$GATELOG" | grep -q "verdict=PASS" && { ok=1; EFFECT_FORM="$FORM"; EFFECT_LAB="$LAB"; break 2; }
    echo "$LAB try=$try form='$FORM' 判档 FAIL ⇒ remount（重试换 label）" | tee -a "$OUT/remount-retry.log"
  done
done
[ "$ok" = 1 ] || { log "STOP 两种形式 × 3 次均未过判档门 ⇒ 停，回报"; exit 3; }
log "gate PASS: form='$EFFECT_FORM' label=$EFFECT_LAB"
echo "EFFECTIVE form='$EFFECT_FORM' label=$EFFECT_LAB" | tee -a "$OUT/arm-verify.txt"
verify_instance "$EFFECT_LAB"

# ---- 阶段2：效应项（同一实例，SKIP_REMOUNT=1；顺序 = V4 内部顺序）----
# 段D 前置：TiKV/PD 指标可达性侦察（F44 候选验证的输入，只探测+抓取，不下结论）
log "段D 可达性侦察：TiKV/PD metrics 端点..."
for ep in "10.20.1.150:2379/metrics" "10.20.1.150:9090/metrics" "10.20.1.150:20180/metrics" "10.20.1.150:20181/metrics" \
          "10.20.1.151:20180/metrics" "10.20.1.152:20180/metrics"; do
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' "http://$ep" 2>/dev/null || echo ERR)
  echo "reach $ep http=$code $(date '+%F %T')" | tee -a "$OUT/tikv-reach.log"
done
bash /tmp/t37l-objwatch.sh "$OUT" "$EFFECT_LAB" & OW=$!
for it in randread randrw randwrite; do
  # 段D：randwrite 期间抓 TiKV/PD 指标（1Hz；失败只记录不重试）
  TIKV_PID=""
  if [ "$it" = randwrite ]; then
    ( for i in $(seq 1 240); do
        echo "=== t=$i $(date '+%F %T') ===" >> "$OUT/tikv-metrics-${EFFECT_LAB}.txt"
        for ep in "10.20.1.150:2379/metrics" "10.20.1.150:20180/metrics" "10.20.1.151:20180/metrics" "10.20.1.152:20180/metrics"; do
          echo "--- $ep ---" >> "$OUT/tikv-metrics-${EFFECT_LAB}.txt"
          timeout 2 curl -s "http://$ep" 2>/dev/null | grep -E '^(grpc_server_handling|pd_server|tikv_grpc_msg_duration|tikv_scheduler|tikv_engine|etcd_server|tikv_server_report)' | head -40 >> "$OUT/tikv-metrics-${EFFECT_LAB}.txt"
        done
        sleep 1
      done ) & TIKV_PID=$!
  fi
  bash "$INSTR" start "$OUT" "${it}-${EFFECT_LAB}"
  JUICEFS_MOUNT_OPTS="$EFFECT_FORM" ITEMS="$it" bash "$V4" "$EFFECT_LAB" 180 2 >> "$OUT/wrapper.log" 2>&1; rc=$?
  bash "$INSTR" stop "$OUT" "${it}-${EFFECT_LAB}"
  [ -n "$TIKV_PID" ] && kill "$TIKV_PID" 2>/dev/null || true
  verify_instance "$EFFECT_LAB"
  echo "$EFFECT_LAB item=$it rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
  [ -f "$OUT/OBJ_BREACH-$EFFECT_LAB" ] && { log "$EFFECT_LAB OBJ_BREACH 停"; break; }
done
kill "$OW" 2>/dev/null || true
{ echo "=== $EFFECT_LAB end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"

# ---- 阶段2b（段A2）：并发读写共享性——F42（读侧 ~4.1 GiB/s）是否被写路径共用 ----
# 同一分离挂载实例；两个 fio 并行：randread(read_test) + randwrite(storage_test)
# 预登记：A2a 独立 ⇒ 读≈[3906,4219] 且写≈[2817,3397] 且合计≈7 GiB/s；
#         A2b 共享 ⇒ 合计≈4.1 GiB/s 墙；A2c 部分共享 ⇒ 合计介于两者
tag="T39A2-rwcon"
bash "$INSTR" start "$OUT" "$tag"
fio --directory="$TD" --name=read_test \
    --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 --readonly \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="$OUT/bwlog/$tag-read" --log_avg_msec=1000 > "$OUT/fio-$tag-read.txt" 2>&1 &
FR=$!
fio --directory="$TD" --name=storage_test \
    --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="$OUT/bwlog/$tag-write" --log_avg_msec=1000 > "$OUT/fio-$tag-write.txt" 2>&1 &
FW=$!
wait "$FR"; rc1=$?; wait "$FW"; rc2=$?
bash "$INSTR" stop "$OUT" "$tag"
printf '%s\t%s\t%s\t%s\t%s\n' "$tag-read" 128 rwcon "$rc1" \
  "$(grep -E '^\s+READ: bw=' "$OUT/fio-$tag-read.txt" | head -1)" >> "$OUT/s1v3-bw.tsv"
printf '%s\t%s\t%s\t%s\t%s\n' "$tag-write" 128 rwcon "$rc2" \
  "$(grep -E '^\s+WRITE: bw=' "$OUT/fio-$tag-write.txt" | head -1)" >> "$OUT/s1v3-bw.tsv"
verify_instance "$EFFECT_LAB"
echo "T39A2-rwcon rc_read=$rc1 rc_write=$rc2 $(date '+%F %T')" | tee -a "$OUT/progress.txt"
log "=== SEGA DONE $(date) ==="
