#!/bin/bash
# ============================================================
# 冷态全量基线复测 + 全程 stall 检查
# ============================================================
# 目的：复现旧基线(full-bs256k-cold-r1-20260626-200742)的测试流程，
#       全程采集后端 stall/状态时间线，回答"过去冷态数据准不准"
# 二进制：patched v1.3.1+2025-12-02.e0032b2a
# 挂载：--cache-size 0（匹配旧基线，无 mu 无 ra）
# fio 口径：bs=256K seq / bs=4M layout / bs=256k rand（匹配旧基线）
# 只认 r1；随机 3 轮看稳定性
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
SEQ_DIR="${MNT}/seq_dir"
TEST_DIR="${MNT}/test_dir"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="results/cold-baseline-recheck-20260706"
OUT="${OUTDIR}/summary.md"
BACKEND="${OUTDIR}/backend"

NODE1="192.168.11.11"; NODE1_OSDS="0 1"
NODE2="192.168.11.13"; NODE2_OSDS="2 3"
NODE3="192.168.11.14"; NODE3_OSDS="4 5"
OSD_PW="TurboAi@303"
HEALTH_PID=""

cd /home/turboai/production
SCRIPT_DIR="/home/turboai/production/tests"
mkdir -p "$OUTDIR" "$BACKEND"

log(){ echo "$@" | tee -a "$OUT"; }

drop_client(){ sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; }
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || true; }

snapshot_backend(){
  local tag="$1"
  local f="${BACKEND}/${tag}.txt"
  {
    echo "### date: $(date)"
    echo "== ceph health detail =="; sudo ceph health detail 2>&1
    echo "== ceph status =="; sudo ceph -s 2>&1
    echo "== osd perf =="; sudo ceph osd perf 2>&1
    echo "== ceph df detail =="; sudo ceph df detail 2>&1
    echo "== osd df =="; sudo ceph osd df 2>&1
  } > "$f" 2>&1
  echo "  snapshot_backend $tag -> $f"
}

check_stall(){
  local health
  health=$(sudo ceph health detail 2>&1)
  if echo "$health" | grep -qi "stalled\|slow_ops\|SLOW_OPS\|STALLED"; then
    return 0
  else
    return 1
  fi
}

restart_stalled_osds(){
  local stalled
  stalled=$(sudo ceph health detail 2>&1 | grep -oP "osd\.\d+" | sort -u)
  if [ -z "$stalled" ]; then
    echo "  no stalled OSDs found"
    return
  fi
  for osd_id in $stalled; do
    echo "  restarting $osd_id at $(date) ..."
    sudo ceph orch daemon restart "$osd_id" 2>&1 | tee -a "${OUTDIR}/restart.log"
  done
  echo "  waiting for HEALTH_OK ..."
  for i in $(seq 1 60); do
    if [ "$(sudo ceph health 2>&1)" = "HEALTH_OK" ]; then
      echo "  HEALTH_OK after $((i*5))s"
      return
    fi
    sleep 5
  done
  echo "  WARNING: HEALTH not OK after 300s"
}

# ---- 启动后台监控 ----
start_monitoring(){
  echo "### Starting background monitoring at $(date) ###"

  # 1. health timeline (on master, every 5s)
  (
    while true; do
      echo "=== $(date +%s) $(date) ==="
      sudo ceph health detail 2>&1
      echo ""
      sleep 5
    done
  ) > "${BACKEND}/health-timeline.txt" 2>&1 &
  HEALTH_PID=$!
  echo "  health timeline PID=$HEALTH_PID"

  # 2. OSD perf timeline (on each OSD node, every 5s, admin socket)
  # SCP monitor script to each node, then start via SSH
  for node_info in "${NODE1}:${NODE1_OSDS}" "${NODE2}:${NODE2_OSDS}" "${NODE3}:${NODE3_OSDS}"; do
    local ip="${node_info%%:*}"
    local osds="${node_info#*:}"
    sshpass -p "$OSD_PW" scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/osd-perf-monitor.sh" turboai@"$ip":/tmp/osd-perf-monitor.sh 2>/dev/null
    for osd_id in $osds; do
      sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$ip" \
        "chmod +x /tmp/osd-perf-monitor.sh && nohup /tmp/osd-perf-monitor.sh $osd_id /tmp/osd${osd_id}-perf-timeline.txt >/dev/null 2>&1 & echo \$!" 2>/dev/null
      echo "  started osd.$osd_id perf monitor on $ip"
    done
  done

  # 3. iostat (on each OSD node, continuous)
  for node in "$NODE1" "$NODE2" "$NODE3"; do
    local hname
    hname=$(sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$node" "hostname" 2>/dev/null)
    sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$node" \
      "nohup iostat -x 1 > /tmp/iostat-${hname}.log 2>&1 & echo \$!" 2>/dev/null
    echo "  started iostat on $node ($hname)"
  done

  echo "  monitoring started, sleep 5 to verify"
  sleep 5

  # verify health timeline
  if kill -0 "$HEALTH_PID" 2>/dev/null; then
    local lines
    lines=$(wc -l < "${BACKEND}/health-timeline.txt" 2>/dev/null || echo 0)
    echo "  health timeline verified ($lines lines)"
  else
    echo "  WARNING: health timeline not running!"
  fi

  # verify OSD perf monitors
  for node_info in "${NODE1}:${NODE1_OSDS}" "${NODE2}:${NODE2_OSDS}" "${NODE3}:${NODE3_OSDS}"; do
    local ip="${node_info%%:*}"
    local osds="${node_info#*:}"
    for osd_id in $osds; do
      local lines
      lines=$(sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$ip" "wc -l < /tmp/osd${osd_id}-perf-timeline.txt 2>/dev/null || echo 0" 2>/dev/null)
      if [ "${lines:-0}" -gt 0 ]; then
        echo "  osd.$osd_id perf monitor verified ($lines lines)"
      else
        echo "  WARNING: osd.$osd_id perf monitor not running on $ip"
      fi
    done
  done
}

stop_monitoring(){
  echo "### Stopping background monitoring at $(date) ###"

  kill "${HEALTH_PID:-}" 2>/dev/null || true
  echo "  health timeline stopped"

  for node_info in "${NODE1}:${NODE1_OSDS}" "${NODE2}:${NODE2_OSDS}" "${NODE3}:${NODE3_OSDS}"; do
    local ip="${node_info%%:*}"
    local osds="${node_info#*:}"

    # kill monitors and collect perf data
    for osd_id in $osds; do
      sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$ip" \
        "pkill -f 'osd-perf-monitor.sh $osd_id' 2>/dev/null; true" 2>/dev/null
      sshpass -p "$OSD_PW" scp -o StrictHostKeyChecking=no turboai@"$ip":/tmp/osd${osd_id}-perf-timeline.txt "${BACKEND}/osd${osd_id}-perf-timeline.txt" 2>/dev/null || echo "  failed to collect osd.$osd_id perf"
      local lines
      lines=$(wc -l < "${BACKEND}/osd${osd_id}-perf-timeline.txt" 2>/dev/null || echo 0)
      echo "  collected osd.$osd_id perf timeline ($lines lines)"
    done
  done

  # kill iostat and collect
  for node in "$NODE1" "$NODE2" "$NODE3"; do
    sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$node" "pkill iostat 2>/dev/null; true" 2>/dev/null
    local hname
    hname=$(sshpass -p "$OSD_PW" ssh -o StrictHostKeyChecking=no turboai@"$node" "hostname" 2>/dev/null)
    sshpass -p "$OSD_PW" scp -o StrictHostKeyChecking=no turboai@"$node":/tmp/iostat-${hname}.log "${BACKEND}/iostat-${hname}.log" 2>/dev/null || echo "  failed to collect iostat from $node"
    echo "  collected iostat from $hname"
  done
}

run_seq(){
  local name="$1" rw="$2" bs="$3" size="$4" nj="$5" fsync="$6"
  local of="${OUTDIR}/${name}.txt"
  drop_client
  echo "# ${name}: rw=${rw} bs=${bs} size=${size} numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: --cache-size 0 (patched v1.3.1)" >> "$of"
  echo "# date: $(date)" >> "$of"
  snapshot_backend "${name}-before"
  local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=${bs} --size=${size}"
  [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
  [ "$fsync" = "1" ] && args="$args --end_fsync=1"
  fio $args >> "$of" 2>&1
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA}"
  wait_fio
  snapshot_backend "${name}-after"
  if check_stall; then
    log "  *** STALL DETECTED after ${name} ***"
    sudo ceph health detail 2>&1 | tee -a "${OUTDIR}/stall-events.log"
  fi
}

run_rand(){
  local name="$1" rw="$2" round="$3"
  local of="${OUTDIR}/${name}-r${round}.txt"
  drop_client
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: --cache-size 0 (patched v1.3.1)" >> "$of"
  echo "# date: $(date)" >> "$of"
  snapshot_backend "${name}-r${round}-before"
  fio --directory="$TEST_DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA}"
  wait_fio
  snapshot_backend "${name}-r${round}-after"
  if check_stall; then
    log "  *** STALL DETECTED after ${name} r${round} ***"
    sudo ceph health detail 2>&1 | tee -a "${OUTDIR}/stall-events.log"
  fi
}

# ============================================================
# 主测试流程
# ============================================================

log "============================================================"
log "冷态全量基线复测（加强 stall 检查） ${TS}"
log "============================================================"
log ""
log "## 测试方法"
log "  脚本: tests/bench-cold-baseline-recheck.sh"
log "  口径: patched v1.3.1, cache=0, 无 mu 无 ra"
log "  fio bs: seq=256K / layout=4M / rand=256k（匹配旧基线）"
log "  目的: 复现旧基线流程,全程采集 stall,回答过去数据准不准"
log "  对照旧基线: results/full-bs256k-cold-r1-20260626-200742/"
log ""

# ---- 环境快照 ----
log "## 环境快照"
{
  echo "### date: $(date)"
  echo "### juicefs version"
  /usr/local/bin/juicefs --version 2>&1
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
  echo "### ceph osd pool get juicefs-data all"
  sudo ceph osd pool get juicefs-data all 2>&1
  echo "### ceph osd erasure-code-profile get ec-prod"
  sudo ceph osd erasure-code-profile get ec-prod 2>&1
  echo "### ceph df"
  sudo ceph df 2>&1
  echo "### uname"
  uname -a
  echo "### cpu"
  lscpu | head -10
  echo "### memory"
  free -h
  echo "### disk"
  df -h / /data
  echo "### fio version"
  fio --version 2>&1
  echo "### network mtu"
  cat /sys/class/net/eno1/mtu
} > "${OUTDIR}/env-snapshot.txt" 2>&1
log "  env snapshot -> ${OUTDIR}/env-snapshot.txt"

# ---- 启动监控 ----
log ""
log "## 启动后台监控"
start_monitoring | tee -a "$OUT"

# ---- 格式化卷 ----
log ""
log "## 格式化卷"
log "  STORAGE=ceph, pool=juicefs-data, block-size=256K"
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
sleep 2
unset ACCESS_KEY SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
/usr/local/bin/juicefs format \
  --storage ceph \
  --bucket ceph://juicefs-data \
  --access-key ceph \
  --secret-key client.juicefs \
  --block-size 256K \
  --trash-days 0 \
  "$META" juicefs-prod 2>&1 | tee "${OUTDIR}/format.log"

# ---- 挂载 ----
log ""
log "## 挂载"
log "  --cache-size 0 (patched v1.3.1, 无 mu 无 ra)"
sleep 2
/usr/local/bin/juicefs mount -d --cache-size 0 "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 5
mountpoint -q "$MNT" || { log "FATAL: mount failed"; stop_monitoring; exit 1; }
log "  mount OK"

# ---- 顺序测试 (bs=256K, 匹配旧基线) ----
log ""
log "## 顺序测试 (bs=256K, cache=0, 匹配旧基线口径)"
mkdir -p "$SEQ_DIR"

log "### seqread prep (write 4G)"
snapshot_backend "seqread-prep-before"
rm -rf "$SEQ_DIR"/*
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=4G >/dev/null 2>&1; wait_fio
snapshot_backend "seqread-prep-after"

run_seq "seqread" read 256K 4G 1 0
run_seq "seqwrite" write 256K 4G 1 1
run_seq "multi-seqread" read 256K 4G 16 0
run_seq "multi-seqwrite" write 256K 4G 16 1

# ---- 布局 (128G, bs=4M, 匹配旧基线) ----
log ""
log "## 布局 (128 jobs x 1G = 128G, bs=4M)"
rm -rf "$SEQ_DIR"/*
mkdir -p "$TEST_DIR"
rm -rf "$TEST_DIR"/*
snapshot_backend "layout-before"
echo "# layout: 128 jobs x 1G, bs=4M, rw=write, end_fsync=1" > "${OUTDIR}/layout.txt"
echo "# date: $(date)" >> "${OUTDIR}/layout.txt"
fio --directory="$TEST_DIR" --name=storage_test --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 \
    >> "${OUTDIR}/layout.txt" 2>&1
lw=$(bwget "${OUTDIR}/layout.txt" WRITE)
log "  layout: WRITE=${lw:-NA}"
wait_fio
snapshot_backend "layout-after"

# ---- layout 后 stall 检查 ----
log ""
log "## layout 后 stall 检查"
if check_stall; then
  log "  *** STALL DETECTED after layout ***"
  sudo ceph health detail 2>&1 | tee "${OUTDIR}/layout-stall-detail.txt"
  echo "$(date): stall detected after layout" >> "${OUTDIR}/stall-events.log"

  log "  等待 120s cooldown (匹配旧基线)..."
  sleep 120
  snapshot_backend "layout-cooldown-120s"
  if check_stall; then
    log "  *** STALL 持续 120s 未自愈 → 旧基线的随机测试确实在 stall 下运行 ***"
    echo "$(date): stall persisted after 120s cooldown" >> "${OUTDIR}/stall-events.log"
    log "  restart stalled OSDs 以获取干净态数据..."
    restart_stalled_osds | tee -a "${OUTDIR}/restart.log"
    snapshot_backend "layout-restart-after"
    echo "$(date): restarted stalled OSDs, HEALTH_OK" >> "${OUTDIR}/stall-events.log"
  else
    log "  stall 在 120s 内自愈 → 旧基线可能未受影响"
    echo "$(date): stall self-healed within 120s" >> "${OUTDIR}/stall-events.log"
  fi
else
  log "  layout 后无 stall"
  log "  等待 120s cooldown (匹配旧基线)..."
  sleep 120
  snapshot_backend "layout-cooldown-120s"
fi

# ---- 随机测试 (3 轮, bs=256k, 匹配旧基线) ----
log ""
log "## 随机测试 (reuse layout, cache=0, 3 rounds)"

for i in 1 2 3; do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
done

# ---- 停止监控 ----
log ""
log "## 停止监控"
stop_monitoring | tee -a "$OUT"

# ---- 汇总 ----
log ""
log "============================================================"
log "## 汇总"
log "============================================================"
log ""
log "所有原始 fio 输出保存在: ${OUTDIR}/"
log "  - env-snapshot.txt / format.log / mount.log"
log "  - seqread.txt / seqwrite.txt / multi-seqread.txt / multi-seqwrite.txt"
log "  - layout.txt"
log "  - randread-r{1,2,3}.txt / randwrite-r{1,2,3}.txt / randrw-r{1,2,3}.txt"
log "  - backend/ (health-timeline, osd-perf-timelines, iostat, snapshots)"
log "  - stall-events.log / restart.log (如有)"
log ""
log "DONE"
