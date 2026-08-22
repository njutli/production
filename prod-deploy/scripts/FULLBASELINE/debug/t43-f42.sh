#!/usr/bin/env bash
# t43-f42.sh — 03-13 F42 最后点名：T1 max-downloads 扫描 + 条件性 T2 librados 参数
# T1（无条件）：main（edabf9c2，含 #6472 --max-downloads 默认 200）挂载，
#   --max-downloads {200, 512, 1024} 三档 × randread j128 各 1 轮，每点 pprof goroutine + i1。
# 分支判据（脚本自动）：1024 档 bw ≥ 4200 或 相对 200 档 ≥ +3% ⇒ 破墙 ⇒ T2 跳过；
#   否则（不破墙）⇒ T2 执行。
# T2（条件）：ceph.conf [client] 参数两档——t2a ms_async_op_threads=8；t2b 再叠加 objecter_inflight_ops=4096；
#   各 remount 过门 + 1 轮 randread。⛔ ceph.conf 强制备份/还原 + md5 双校验。
set -uo pipefail
OUT=/tmp/opencode-t3.13
GATE=/tmp/t39-nsbgate.sh
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
TD=/mnt/juicefs/test_dir
BIN=/tmp/juicefs-main-stock
BASE_OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
CCF=/etc/ceph/ceph.conf
CCF_BAK=/etc/ceph/ceph.conf.t43bak
mkdir -p "$OUT" "$OUT/bwlog"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }
CCF_CHANGED=0
restore_ccf() {
  if [ "$CCF_CHANGED" = 1 ] && [ -f "$CCF_BAK" ]; then
    cp "$CCF_BAK" "$CCF"
    echo "trap_restore ceph.conf $(date '+%F %T')" >> "$OUT/ceph-conf-restore.log"
  fi
}
trap restore_ccf EXIT

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { "$BIN" umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

jfs_port() { sudo ss -tlnp 2>/dev/null | grep -i juicefs | awk '{print $4}' | grep -oE ':[0-9]+$' | head -1 | tr -d ':' ; }

gate() {   # 当前挂载上跑 ns/B 判档门（I1 直连 mseqread）；$1=label → 0=过
  local lab="$1"
  ( printf 'ts\tkey\tvalue\n'
    while :; do t=$(date +%s); timeout 3 cat /mnt/juicefs/.stats 2>/dev/null \
      | grep -E '^(juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_read_size_bytes_sum|juicefs_fuse_ops_total_read) ' \
      | awk -v t="$t" '{print t"\t"$1"\t"$2}'; sleep 1; done ) > "$OUT/i1-probe-$lab.tsv" &
  SAMP=$!
  fio --name=mseqread --directory="$TD/mseqread/" --rw=read --refill_buffers --bs=256k \
      --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 \
      --time_based --runtime=180 --write_bw_log="$OUT/bwlog/probe-$lab" --log_avg_msec=1000 \
      > "$OUT/fio-probe-$lab.txt" 2>&1
  kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null
  bash "$GATE" --i1 "$OUT/i1-probe-$lab.tsv" 2>&1 | tee -a "$OUT/probe-gate.log" | grep -q "verdict=PASS"
}

mount_and_run() {   # $1=label $2=额外挂载参数 $3=纯数字结果文件
  local lab="$1" extra="$2" result="$3" mr q bw rc
  umount_jfs || return 2
  "$BIN" mount -d $BASE_OPTS $extra "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mount | grep -q juice || { log "$lab mount failed"; return 2; }
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  echo "$lab opts='$extra' max_read=$mr pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" | tee -a "$OUT/instances.txt"
  ok=0
  for t in 1 2 3; do
    LTRY="$lab"; [ $t -gt 1 ] && LTRY="${lab}-t${t}"
    if gate "$LTRY"; then ok=1; lab="$LTRY"; break; fi
    echo "$lab try=$t 判档 FAIL ⇒ remount" | tee -a "$OUT/remount-retry.log"
    umount_jfs; "$BIN" mount -d $BASE_OPTS $extra "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
    mount | grep -q juice || { log "$lab remount failed"; return 2; }
    q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
    echo "remount $LTRY pid=$q starttime_ticks=$(awk '{print $22}' /proc/$q/stat)" >> "$OUT/instances.txt"
  done
  [ "$ok" = 1 ] || { log "STOP $lab 三次判档 FAIL"; return 3; }
  # 1 轮 randread j128 + pprof goroutine + i1
  ( printf 'ts\tkey\tvalue\n'
    while :; do t=$(date +%s); timeout 3 cat /mnt/juicefs/.stats 2>/dev/null \
      | grep -E '^(juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_(read|write)|juicefs_fuse_(read|write)_size_bytes_sum|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_object_request_durations_histogram_seconds_(GET|PUT)_(sum|total)|juicefs_object_request_data_bytes_(GET|PUT)|juicefs_used_(read_)?buffer_size_bytes) ' \
      | awk -v t="$t" '{print t"\t"$1"\t"$2}'; sleep 1; done ) > "$OUT/i1-$lab.tsv" &
  SAMP=$!
  ( sleep 120; p=$(jfs_port); timeout 10 curl -s "http://127.0.0.1:${p}/debug/pprof/goroutine?debug=2" \
      > "$OUT/pprof-goroutine-$lab.txt" 2>/dev/null ) & DUMP=$!
  fio --directory="$TD" --name=read_test --filesize=1G --size=1G --bs=256k --rw=randread \
      --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 \
      --readonly --group_reporting --time_based --runtime=180 \
      --write_bw_log="$OUT/bwlog/$lab" --log_avg_msec=1000 > "$OUT/fio-$lab.txt" 2>&1
  rc=$?
  kill "$SAMP" "$DUMP" 2>/dev/null; wait "$SAMP" "$DUMP" 2>/dev/null
  bw=$(grep -E '^\s+READ: bw=' "$OUT/fio-$lab.txt" | head -1 | grep -oE '[0-9.]+MiB/s' | head -1 | sed 's#MiB/s##')
  echo "$lab rc=$rc bw=${bw:-NA}MiB/s" | tee -a "$OUT/progress.txt" "$OUT/wrapper.log"
  [ "$rc" -eq 0 ] && [[ "${bw:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    log "STOP $lab 结果不是纯数字或 fio rc=$rc"; return 4;
  }
  printf '%s\n' "$bw" > "$result"
}

read_bw_result() { # $1=file $2=variable name
  local f="$1" var="$2" v
  IFS= read -r v < "$f" || return 1
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log "STOP 非法 BW 结果：$f='$v'"; return 1; }
  printf -v "$var" '%s' "$v"
}

# ================= T1：max-downloads 扫描 =================
log "=== T1：--max-downloads 扫描（main edabf9c2）==="
mount_and_run "T43A-md200"  "--max-downloads 200"  "$OUT/result-md200.txt"  || { log "STOP T1-200 失败"; exit 3; }
mount_and_run "T43A-md512"  "--max-downloads 512"  "$OUT/result-md512.txt"  || { log "STOP T1-512 失败"; exit 3; }
mount_and_run "T43A-md1024" "--max-downloads 1024" "$OUT/result-md1024.txt" || { log "STOP T1-1024 失败"; exit 3; }
read_bw_result "$OUT/result-md200.txt" B1 || exit 3
read_bw_result "$OUT/result-md512.txt" B2 || exit 3
read_bw_result "$OUT/result-md1024.txt" B3 || exit 3
DELTA=$(awk -v a="$B3" -v b="$B1" 'BEGIN{if ((b+0)<=0) exit 2; printf "%.1f", ((a+0)-(b+0))/(b+0)*100}') || {
  log "STOP T1 delta 计算失败"; exit 3;
}
log "T1 结果：200=${B1} 512=${B2} 1024=${B3} Δ(1024 vs 200)=${DELTA}%"
if awk -v b="$B3" -v d="$DELTA" 'BEGIN{exit !((b+0)>=4200 || (d+0)>=3)}'; then
  log "分支触发（bw>=4200 或 Δ>=3%）⇒ 按预登记跳过 T2；归因由分析方复核，脚本不点名 F42"
else
  # ================= T2：librados 参数（条件执行）=================
  log "⚑ 不破墙 ⇒ T2 执行：ceph.conf [client] 参数"
  cp "$CCF" "$CCF_BAK"
  CCF_CHANGED=1
  md5sum "$CCF" "$CCF_BAK" | tee -a "$OUT/ceph-conf-md5.txt"
  cp "$CCF_BAK" "$OUT/ceph.conf.original"
  # t2a：ms_async_op_threads=8
  cp "$CCF_BAK" "$CCF" && printf '\n[client]\n\tms_async_op_threads = 8\n' >> "$CCF"
  log "t2a 生效参数：$(tail -3 $CCF | tr '\n' ' ')"
  mount_and_run "T43B-t2a" "" "$OUT/result-t2a.txt" || { log "STOP T2a 失败"; exit 3; }
  read_bw_result "$OUT/result-t2a.txt" B4 || exit 3
  # t2b：叠加 objecter_inflight_ops=4096
  printf '\tobjecter_inflight_ops = 4096\n' >> "$CCF"
  log "t2b 生效参数：$(tail -4 $CCF | tr '\n' ' ')"
  mount_and_run "T43B-t2b" "" "$OUT/result-t2b.txt" || { log "STOP T2b 失败"; exit 3; }
  read_bw_result "$OUT/result-t2b.txt" B5 || exit 3
  # ⛔ 强制还原 + md5 校验
  cp "$CCF_BAK" "$CCF"
  CCF_CHANGED=0
  md5sum "$CCF" | tee -a "$OUT/ceph-conf-md5.txt"
  md5sum -c "$OUT/ceph-conf-md5.txt" > "$OUT/ceph-conf-verify.txt" 2>&1
  log "T2 结果：t2a=${B4} t2b=${B5}（ceph.conf 还原校验见 ceph-conf-verify.txt）"
fi

umount_jfs
"$BIN" mount -d --max-uploads 150 --cache-size 0 "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "RESTORED max_read=$mr want=131072" | tee -a "$OUT/progress.txt"
{ echo "=== T43 end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; } >> "$OUT/health.txt"
log "=== T43 DONE $(date) ==="
