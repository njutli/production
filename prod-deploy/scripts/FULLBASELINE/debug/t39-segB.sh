#!/usr/bin/env bash
# t39-segB.sh — 03-9 段B：F42 客户端 ~4.1 GiB/s 串行资源定位 v3（只读 sweep）+ 可选段C 负控
# v3 修法（v2 教训：共享文件清单致多 job 争用同一组文件，sweep 20~111 MiB/s 全废）：
#   fio jobfile：每个并发点生成 J 个 [jobNNN] 段，每段独占 128/J 个互斥文件（总工作集恒 128 GiB、总打开数恒 128）
# 锚点 = V4 randread 逐字命令（directory 模式，numjobs=128），用于证明本段 fio 口径与 V4 可比。
# 判档门 = ns/B（mseqread 探针，GUIDE §二.10）；锚点 BW 与 4058±3% 比对仅作描述（防基线漂移误杀，§二.10.4.2）。
# pprof：每点抓 goroutine dump（t=100s），锚点与 j128-p2 加 30s CPU profile ⇒ F42 点名证据。
# 复用（03-11 段B2 第二实例）：OUT=/tmp/opencode-t3.11 LP=T41B bash /tmp/t39-segB.sh
set -uo pipefail
V4=/tmp/FULLBASELINE_V4.sh; INSTR=/tmp/instrument.sh; OUT="${OUT:-/tmp/opencode-t3.9}"; GATE=/tmp/t39-nsbgate.sh
LP="${LP:-T39B}"          # label 前缀
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
TD=/mnt/juicefs/test_dir
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
PLAT=4058; TOLPCT=3
RUN_SEGC="${RUN_SEGC:-1}"   # 段C 负控开关：1=跑（默认）；砍单时 RUN_SEGC=0
mkdir -p "$OUT" "$OUT/bwlog"; export I2B_SEC=10
# 判档门与效应轮必须是同一 mount 实例；否则 V4 会按 JUICEFS_MOUNT_OPTS 自行 remount。
export SKIP_REMOUNT=1
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

proc_starttime() { # $1=pid；兼容 comm 中空格/右括号
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1; print f[20]}' \
      "/proc/$1/stat" 2>/dev/null
}

jfs_port() { sudo ss -tlnp 2>/dev/null | grep -i juicefs | awk '{print $4}' | grep -oE ':[0-9]+$' | head -1 | tr -d ':' ; }
pprof_goroutine() {   # $1=tag —— 须在 fio 运行中调用
  local p tag="$1"
  p=$(jfs_port); [ -z "${p:-}" ] && { echo "pprof 端口未发现 (${tag})" | tee -a "$OUT/wrapper.log"; return 1; }
  timeout 10 curl -s "http://127.0.0.1:${p}/debug/pprof/goroutine?debug=2" > "$OUT/pprof-goroutine-${tag}.txt" 2>/dev/null \
    && echo "pprof goroutine → pprof-goroutine-${tag}.txt port=${p}" | tee -a "$OUT/wrapper.log" \
    || echo "pprof goroutine 失败 port=${p} (${tag})" | tee -a "$OUT/wrapper.log"
}
pprof_cpu() {   # $1=tag —— 30s CPU profile，须在 fio 运行中调用
  local p tag="$1"
  p=$(jfs_port); [ -z "${p:-}" ] && { echo "pprof 端口未发现 (${tag})" | tee -a "$OUT/wrapper.log"; return 1; }
  timeout 45 curl -s "http://127.0.0.1:${p}/debug/pprof/profile?seconds=30" -o "$OUT/pprof-cpu-${tag}.pprof" 2>/dev/null \
    && echo "pprof cpu → pprof-cpu-${tag}.pprof port=${p}" | tee -a "$OUT/wrapper.log" \
    || echo "pprof cpu 失败 port=${p} (${tag})" | tee -a "$OUT/wrapper.log"
}

# ---- prep：前序写项之后的 compact cooldown（GUIDE §二.4）----
log "compact cooldown（写后净化）..."
for osd in $(sudo ceph osd ls 2>/dev/null); do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
for i in $(seq 1 60); do
  all_done=1
  for osd in $(sudo ceph osd ls 2>/dev/null); do
    read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
      'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
    { [ "$running" != "0" ] || [ "$queued" != "0" ]; } && all_done=0
  done
  $all_done && { log "  compact ✅ (~$((i*5))s)"; break; }
  sleep 5
done

umount_jfs() {
  P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  [ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
  mount | grep -q juice && { log "STOP umount 失败"; return 2; }
  return 0
}

mount_256k() {   # $1=label；成功时冻结 GATE_PID/GATE_START
  local lab="$1" mr q
  umount_jfs || return 2
  juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1; sleep 5
  mount | grep -q juice || { log "$lab mount failed"; return 2; }
  mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  [ "${mr:-0}" = "262144" ] || { log "$lab max_read=${mr:-NA} ≠262144 FAIL"; return 1; }
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  GATE_PID="$q"; GATE_START="$(proc_starttime "$q")"
  [ -n "${GATE_START:-}" ] || { log "$lab 无法读取 pid=$q starttime"; return 1; }
  echo "$lab max_read=$mr pid=$GATE_PID starttime_ticks=$GATE_START metrics_port=$(jfs_port)" | tee -a "$OUT/instances.txt"
  echo "$lab max_read=$mr want=262144 metrics_port=$(jfs_port)" | tee -a "$OUT/arm-verify.txt"
  return 0
}

verify_instance() { # $1=expected pid $2=expected starttime
  local want_pid="$1" want_st="$2" q st
  q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
  st=$(proc_starttime "$q")
  echo "verify pid=$q starttime_ticks=$st want_pid=$want_pid want_starttime=$want_st $(date '+%F %T')" | tee -a "$OUT/instances.txt"
  [ "$q" = "$want_pid" ] && [ "$st" = "$want_st" ] || {
    log "STOP mount 实例漂移：got pid/start=$q/$st want=$want_pid/$want_st"; return 1;
  }
}

gen_jobfile() {   # $1=numjobs J  $2=jobfile 路径；J 个段，每段独占 128/J 个文件
  local j=$1 f=$2 per=$((128/j)) k=0 n=0
  [ $((per*j)) -ne 128 ] && { log "STOP 128%$j≠0"; exit 1; }
  {
    # ⚠ readonly 是 fio 命令行旗标、不是 jobfile 选项（readonly=1 会整段丢弃 global）⇒ 调用时以 --readonly 传入
    printf '[global]\nbs=256k\nrw=randread\nioengine=libaio\niodepth=128\ndirect=1\nfallocate=none\nfile_service_type=random\ntime_based\nruntime=180\ngroup_reporting\nfilesize=1g\nsize=1g\nopenfiles=%d\n\n' "$per"
    for fp in $(ls "$TD"/read_test.*.0 2>/dev/null | sort); do
      if [ $((k % per)) -eq 0 ]; then
        n=$((n+1))
        [ $k -gt 0 ] && printf '\n'
        printf '[job%03d]\nfilename=' "$n"
      else
        printf ':'
      fi
      printf '%s' "$fp"
      k=$((k+1))
    done
    printf '\n'
  } > "$f"
  [ "$k" -eq 128 ] || { log "STOP jobfile 文件数 $k ≠128"; exit 1; }
  echo "jobfile $f: $n jobs × $per files" | tee -a "$OUT/progress.txt"
}

# ===== 阶段1：挂 256K + ns/B 判档门（重试换 label）=====
ok=0
for t in 1 2 3; do
  LAB="$LP"; [ $t -gt 1 ] && LAB="$LP-t${t}"
  log "=== mount try=$t label=$LAB ==="
  mount_256k "$LAB" || { echo "$LAB try=$t mount FAIL" >> "$OUT/remount-retry.log"; continue; }
  bash "$INSTR" start "$OUT" "probe-$LAB"
  JUICEFS_MOUNT_OPTS="$OPTS" ITEMS="mseqread" bash "$V4" "PROBE-$LAB" 180 2 >> "$OUT/wrapper.log" 2>&1
  bash "$INSTR" stop "$OUT" "probe-$LAB"
  GATELOG=$(bash "$GATE" /tmp/opencode-fullbaseline-v4 "PROBE-$LAB" mseqread 2>&1 | tee -a "$OUT/probe-gate.log")
  echo "$GATELOG" | grep -q "verdict=PASS" && { ok=1; break; }
  echo "$LAB try=$t 判档 FAIL ⇒ remount" | tee -a "$OUT/remount-retry.log"
done
[ "$ok" = 1 ] || { log "STOP 三次判档均 FAIL ⇒ 停，回报"; exit 3; }
log "gate PASS: label=$LAB"
verify_instance "$GATE_PID" "$GATE_START" || exit 8

# ===== 阶段2：锚点（V4 randread 逐字，directory 模式 + numjobs=128）=====
ATAG="$LP-anchor"
verify_instance "$GATE_PID" "$GATE_START" || exit 8
bash "$INSTR" start "$OUT" "$ATAG"
( sleep 100; pprof_goroutine "$ATAG" ) & D1=$!
( sleep 90; pprof_cpu "$ATAG" ) & D2=$!
fio --directory="$TD" --name=read_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 --readonly \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log="$OUT/bwlog/$ATAG" --log_avg_msec=1000 > "$OUT/fio-$ATAG.txt" 2>&1
arc=$?
kill "$D1" "$D2" 2>/dev/null || true; wait "$D1" "$D2" 2>/dev/null || true
bash "$INSTR" stop "$OUT" "$ATAG"
abw=$(grep -E '^\s+READ: bw=' "$OUT/fio-$ATAG.txt" | head -1)
adev=$(echo "$abw" | grep -oE '\([0-9.]+MiB/s\)' | grep -oE '[0-9.]+' | awk -v p="$PLAT" '{printf "%.1f", ($1-p)/p*100}' 2>/dev/null || echo NA)
printf '%s\t%s\t%s\t%s\t%s\n' "$ATAG" 128 anchor "$arc" "$abw" >> "$OUT/s1v3-bw.tsv"
echo "$ATAG anchor rc=$arc dev_vs_4058=${adev}% $(date '+%F %T')" | tee -a "$OUT/progress.txt"
# I1 窗 ns/B 落盘（供 opencode 复核；判档以阶段1 mseqread 门为准）
bash "$GATE" --i1 "$OUT/i1-jfsstats-$ATAG.tsv" 2>&1 | tee -a "$OUT/probe-gate.log" || true
if [ "$arc" -ne 0 ] || ! grep -qE '^\s+READ: bw=' "$OUT/fio-$ATAG.txt"; then
  log "STOP 锚点 rc=$arc 或无 READ:bw 行 ⇒ 报错原文见 fio-$ATAG.txt"; exit 9
fi
sleep 20

# ===== 阶段3：sweep（3 pass 升/降/升，F17 漂移对冲；首点即校验；每点 pprof）=====
for p in 1 2 3; do
  case $p in 1|3) SEQ="8 16 32 64 128";; 2) SEQ="128 64 32 16 8";; esac
  for j in $SEQ; do
    tag="$LP-j${j}-p${p}"
    verify_instance "$GATE_PID" "$GATE_START" || exit 8
    JF="$OUT/job-j${j}.job"
    [ -f "$JF" ] || gen_jobfile "$j" "$JF"
    bash "$INSTR" start "$OUT" "$tag"
    D=""; D2=""
    ( sleep 100; pprof_goroutine "$tag" ) & D=$!
    if [ "$j" = 128 ] && [ "$p" = 2 ]; then ( sleep 90; pprof_cpu "$tag" ) & D2=$!; fi
    fio --readonly "$JF" --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 > "$OUT/fio-$tag.txt" 2>&1
    rc=$?
    kill "$D" ${D2:-} 2>/dev/null || true; wait "$D" ${D2:-} 2>/dev/null || true
    bash "$INSTR" stop "$OUT" "$tag"
    printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$j" sweep "$rc" \
      "$(grep -E '^\s+READ: bw=' "$OUT/fio-$tag.txt" | head -1)" >> "$OUT/s1v3-bw.tsv"
    echo "$tag jobs=$j rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
    if [ "$rc" -ne 0 ] || ! grep -qE '^\s+READ: bw=' "$OUT/fio-$tag.txt"; then
      log "STOP $tag rc=$rc 且无 READ:bw 行（首点校验失败，禁再空跑 15 点）"; exit 9
    fi
    sleep 20
  done
done

# ===== 阶段4（可选）：段C 负控 —— bs=128k randwrite @256K 挂载（bugzilla §5.3 边界预测）=====
if [ "$RUN_SEGC" = "1" ]; then
  tag="${LP%B}C-bs128k"
  verify_instance "$GATE_PID" "$GATE_START" || exit 8
  bash "$INSTR" start "$OUT" "$tag"
  fio --directory="$TD" --name=storage_test \
      --filesize=1G --size=1G \
      --bs=128k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=128 \
      --group_reporting --time_based --runtime=180 \
      --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 > "$OUT/fio-$tag.txt" 2>&1
  rc=$?
  bash "$INSTR" stop "$OUT" "$tag"
  printf '%s\t%s\t%s\t%s\t%s\n' "$tag" 128 segc "$rc" \
    "$(grep -E '^\s+WRITE: bw=' "$OUT/fio-$tag.txt" | head -1)" >> "$OUT/s1v3-bw.tsv"
  echo "$tag rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
  log "段C 写后 compact cooldown..."
  for osd in $(sudo ceph osd ls 2>/dev/null); do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
  sleep 30
fi

# ===== 收尾：恢复默认 128K 挂载（t38 约定）=====
umount_jfs
juicefs mount -d --max-uploads 150 --cache-size 0 "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5
mr=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
echo "RESTORED max_read=$mr want=131072" | tee -a "$OUT/arm-verify.txt"
{ echo "=== SEGB end $(date '+%F %T') ==="; sudo ceph health detail 2>&1 | head -3; sudo ceph pg stat; } >> "$OUT/health.txt"
log "=== SEGB DONE $(date) ==="
