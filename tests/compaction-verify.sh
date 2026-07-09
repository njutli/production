#!/bin/bash
# ============================================================
# Compaction Verify: 验证"单job+积压"双条件
# 测试A: 制造积压 → 单job 8G → 预期stall
# 测试B: compact清除 → 单job 8G → 预期不stall
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
SEQ_DIR="${MNT}/seq_dir"
PARENT="/home/turboai/production/results/compaction-verify-20260706"
FSID="073f28e0-5fe0-11f1-8ce6-7369ee2be5a1"

mkdir -p "$PARENT" "$PARENT/testA" "$PARENT/testB"
cd /home/turboai/production

osd_host(){ case $1 in 0|1) echo "192.168.11.11" ;; 2|3) echo "192.168.11.13" ;; 4|5) echo "192.168.11.14" ;; esac; }
osd_pw(){ case $1 in 0|1) echo "TurboAi@303" ;; *) echo "TurboAi@303" ;; esac; }

# admin socket 直采 compaction 状态
check_compact_all(){
  local label="$1" out="$2"
  echo "### compact state: ${label} ($(date))" >> "$out"
  for o in 0 1 2 3 4 5; do
    local host pw
    host=$(osd_host $o); pw=$(osd_pw $o)
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "turboai@${host}" \
      "sudo ceph --admin-daemon /var/run/ceph/${FSID}/ceph-osd.${o}.asok perf dump 2>/dev/null" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('rocksdb',{})
bs=d.get('bluestore',{})
kv=bs.get('kv_sync_lat',{})
print('osd.${o} compact_queue_len:', r.get('compact_queue_len','?'), 'compact_running:', r.get('compact_running','?'), 'kv_sync_lat:', round(kv.get('avgtime',0)*1000,3), 'ms')
" 2>/dev/null >> "$out" || echo "osd.${o}: FAILED" >> "$out"
  done
  echo "" >> "$out"
}

check_health(){
  local label="$1" out="$2"
  echo "### health: ${label} ($(date))" >> "$out"
  sudo ceph health detail 2>&1 >> "$out"
  echo "" >> "$out"
}

drop_all_caches(){
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
  for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
    local pw="TurboAi@303"; [ "$ip" != "192.168.11.11" ] && pw="TurboAi@303"
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "turboai@$ip" "echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null" 2>/dev/null && echo "  $ip dropped" || echo "  $ip FAILED"
  done
}

restart_osd(){ sshpass -p "$(osd_pw $1)" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "turboai@$(osd_host $1)" "sudo cephadm shell -- ceph orch daemon restart osd.$1" 2>/dev/null | tail -1; }

compact_osd(){
  local o="$1"
  sshpass -p "$(osd_pw $o)" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "turboai@$(osd_host $o)" \
    "sudo ceph --admin-daemon /var/run/ceph/${FSID}/ceph-osd.${o}.asok compact 2>&1" 2>/dev/null
}

wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+" "$1" | head -1; }

# health timeline 后台采集
start_health_poll(){
  local out="$1"
  { while pgrep -x fio >/dev/null 2>&1; do echo "--- $(date) ---" >> "$out"; sudo ceph health detail 2>&1 >> "$out"; sleep 5; done
    echo "--- $(date) ---" >> "$out"; sudo ceph health detail 2>&1 >> "$out"; } &
  HPOLL_PID=$!
}
stop_health_poll(){ kill $HPOLL_PID 2>/dev/null; wait $HPOLL_PID 2>/dev/null || true; }

# ============================================================
# 测试 A：制造积压 → 单job 8G → 预期stall
# ============================================================
echo "=========================================="
echo "Test A: 制造积压 + 验证stall ($(date))"
echo "=========================================="

OUT="${PARENT}/testA"
log="${OUT}/run.log"
> "$log"

# 挂载
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true; sleep 3
juicefs mount -d --cache-size 0 --max-uploads 150 "$META" "$MNT" 2>&1 | tee "${OUT}/mount.log"
sleep 3; mountpoint -q "$MNT" || { echo "FATAL: mount failed"; exit 1; }
echo "mount OK" | tee -a "$log"

# 前置基线
check_compact_all "A-baseline-before" "${OUT}/compact-state.log"
check_health "A-baseline-before" "${OUT}/health-state.log"

# 步骤1: 单job 64G 制造积压
echo "## Step A1: 64G single-job write ($(date))" | tee -a "$log"
drop_all_caches
rm -rf "$SEQ_DIR"/* 2>/dev/null
start_health_poll "${OUT}/A1-health-timeline.txt"
fio --name=A1-64G --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=64G --end_fsync=1 > "${OUT}/A1-64G.txt" 2>&1
stop_health_poll
bw=$(bwget "${OUT}/A1-64G.txt" WRITE)
echo "  A1 WRITE=${bw} MiB/s" | tee -a "$log"
wait_fio

# 采集积压状态
check_compact_all "A-after-64G" "${OUT}/compact-state.log"
check_health "A-after-64G" "${OUT}/health-state.log"

# 步骤2: wait for stall alert to clear, then 8G
echo "## Step A2: 单job 8G on dirty OSD ($(date))" | tee -a "$log"
# 等 stall alert 消退（可能需要几分钟）+ 确认积压
sleep 30
check_compact_all "A-before-8G" "${OUT}/compact-state.log"
check_health "A-before-8G" "${OUT}/health-state.log"

drop_all_caches
rm -rf "$SEQ_DIR"/* 2>/dev/null
start_health_poll "${OUT}/A2-health-timeline.txt"
fio --name=A2-8G --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=8G --end_fsync=1 > "${OUT}/A2-8G.txt" 2>&1
stop_health_poll
bw=$(bwget "${OUT}/A2-8G.txt" WRITE)
echo "  A2 WRITE=${bw} MiB/s" | tee -a "$log"
wait_fio

check_compact_all "A-after-8G" "${OUT}/compact-state.log"
check_health "A-after-8G" "${OUT}/health-state.log"

# ============================================================
# 测试 B：compact 清除 → 单job 8G → 预期不stall
# ============================================================
echo "" | tee -a "$log"
echo "==========================================" | tee -a "$log"
echo "Test B: compact + verify no stall ($(date))" | tee -a "$log"

OUT="${PARENT}/testB"
log="${OUT}/run.log"
> "$log"

# 步骤 B1: restart 受影响 OSD，验证清 stall 但不清洁
stall_osds=$(sudo ceph health detail 2>&1 | grep -oP 'osd\.\d+' | sort -u)
echo "## Step B1: restart stalled OSDs: ${stall_osds} ($(date))" | tee -a "$log"
for o in ${stall_osds#osd.}; do
  [ -n "$o" ] && restart_osd "$o"
done
sleep 30
# 等 HEALTH_OK
elapsed=0
while [ $elapsed -lt 300 ]; do
  h=$(sudo ceph health 2>&1 | head -1)
  [ "$h" = "HEALTH_OK" ] && break
  sleep 10; elapsed=$((elapsed+10))
done
echo "  health after restart: $(sudo ceph health 2>&1 | head -1)" | tee -a "$log"
check_compact_all "B-after-restart" "${OUT}/compact-state.log"
check_health "B-after-restart" "${OUT}/health-state.log"

# 步骤 B2: compact all OSDs
echo "## Step B2: compact all OSDs ($(date))" | tee -a "$log"
for o in 0 1 2 3 4 5; do
  echo "  compacting osd.$o..."
  compact_osd "$o"
done
# 轮询直到全部 compact_running=0
elapsed=0
while [ $elapsed -lt 120 ]; do
  all_done=true
  for o in 0 1 2 3 4 5; do
    host=$(osd_host $o); pw=$(osd_pw $o)
    running=$(sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "turboai@${host}" \
      "sudo ceph --admin-daemon /var/run/ceph/${FSID}/ceph-osd.${o}.asok perf dump 2>/dev/null" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('rocksdb',{}).get('compact_running',1))" 2>/dev/null || echo 1)
    [ "$running" != "0" ] && all_done=false
  done
  $all_done && break
  sleep 10; elapsed=$((elapsed+10))
done
echo "  compact done after ${elapsed}s" | tee -a "$log"
check_compact_all "B-after-compact" "${OUT}/compact-state.log"
check_health "B-after-compact" "${OUT}/health-state.log"

# 步骤 B3: 单job 8G，预期不stall
echo "## Step B3: 单job 8G on clean OSD ($(date))" | tee -a "$log"
drop_all_caches
rm -rf "$SEQ_DIR"/* 2>/dev/null
start_health_poll "${OUT}/B3-health-timeline.txt"
fio --name=B3-8G --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=256K --size=8G --end_fsync=1 > "${OUT}/B3-8G.txt" 2>&1
stop_health_poll
bw=$(bwget "${OUT}/B3-8G.txt" WRITE)
echo "  B3 WRITE=${bw} MiB/s" | tee -a "$log"
wait_fio

check_compact_all "B-after-8G" "${OUT}/compact-state.log"
check_health "B-after-8G" "${OUT}/health-state.log"

echo "" | tee -a "$log"
echo "ALL DONE: $(date)" | tee -a "$log"
