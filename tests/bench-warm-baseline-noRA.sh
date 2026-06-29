#!/bin/bash
# ============================================================
# 暖态基线 noRA 测试：模拟真实生产场景，连跑 7 轮看收敛
# ============================================================
# 口径：
#   - STORAGE=ceph (RADOS 直连), block-size 256K
#   - --cache-size 102400 --max-readahead 0 (100G, JuiceFS 默认)
#   - --cache-dir /data/jfsCache
#   - 不 drop_caches（客户端 + OSD 都不 drop）
#   - 不 destroy/reformat（复用冷态基线的卷和 128G 布局）
#   - 顺序项仅跑 1 次（暖态下顺序读写受 cache 影响小）
#   - 随机项跑 7 轮，观察 r1→r7 收敛趋势
#
# 前置条件：
#   - 卷已 format 为 256K block
#   - 128G 布局已存在 (test_dir/storage_test.* ×128)
#   - /data/jfsCache 已清空（确保 r1 从冷 cache 开始）
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
SEQ_DIR="${MNT}/seq_dir"
CACHE_DIR="/data/jfsCache"
ROUNDS="${ROUNDS:-7}"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="results/warm-baseline-noRA-20260625"
OUT="${OUTDIR}/summary.txt"
mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

# ---- 环境快照 ----
log "============================================================"
log "暖态基线 noRA 测试（可追溯） ${TS}"
log "============================================================"
log ""
log "## 测试方法"
log "  脚本: tests/bench-warm-baseline-noRA.sh"
log "  启动命令: cd /home/turboai/production && bash tests/bench-warm-baseline.sh"
log "  输出目录: results/warm-baseline-noRA-20260625/"
log "  口径: 复用冷态基线的卷和 128G 布局, 不 destroy/reformat"
log "  挂载: --cache-size 102400 --max-readahead 0 --cache-dir /data/jfsCache (100G, JuiceFS 默认)"
log "  不 drop_caches (客户端 + OSD 都不 drop, 模拟生产暖态)"
log "  顺序项各 1 次; 随机项 7 轮, 观察收敛趋势"
log "  每轮记录: cache 大小 + NIC RX"
log ""
log "## 环境快照"
log ""
log "### 集群状态"
{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
  echo "### ceph osd pool get juicefs-data all"
  sudo ceph osd pool get juicefs-data all 2>&1
  echo "### ceph df"
  sudo ceph df 2>&1
  echo "### OSD perf dump (before test)"
  for osd in 0 1 2 3 4 5; do
    echo "--- osd.$osd ---"
    sudo ceph daemon osd.$osd perf dump 2>&1 | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    o=d.get('osd',{})
    print('op_latency sum:', o.get('op_latency',{}).get('sum','N/A'))
    print('op_in_queue avgcount:', o.get('op_in_queue',{}).get('avgcount','N/A'))
    print('op_r_latency sum:', o.get('op_r_latency',{}).get('sum','N/A'))
except: print('parse error')
" 2>&1
  done
} > "${OUTDIR}/ceph-status-before.txt" 2>&1
log "  ceph status -> ${OUTDIR}/ceph-status-before.txt"

log "### 客户端状态"
{
  echo "### date: $(date)"
  echo "### uname"
  uname -a
  echo "### cpu"
  lscpu | head -15
  echo "### memory"
  free -h
  echo "### disk"
  df -h / /data
  echo "### juicefs version"
  juicefs --version 2>&1
  echo "### fio version"
  fio --version 2>&1
  echo "### network"
  ip addr show eno1 | head -5
  echo "### mtu"
  cat /sys/class/net/eno1/mtu
  echo "### cache dir"
  ls -la "$CACHE_DIR" 2>/dev/null
  du -sh "$CACHE_DIR" 2>/dev/null
} > "${OUTDIR}/client-status-before.txt" 2>&1
log "  client status -> ${OUTDIR}/client-status-before.txt"
log ""

# ---- 挂载（100G cache，不 drop） ----
log "## 挂载"
log "  --cache-size 102400 --max-readahead 0 --cache-dir /data/jfsCache (100G, JuiceFS 默认)"
log "  不 drop_caches（暖态，模拟生产）"

# 清空 cache 目录确保 r1 从冷 cache 开始
log "  清空 cache 目录（确保 r1 cache 为空）"
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
sleep 3
rm -rf "$CACHE_DIR"/* 2>/dev/null || true
rm -rf ~/.juicefs/cache/* 2>/dev/null || true

juicefs mount -d --cache-size 102400 --max-readahead 0 --cache-dir "$CACHE_DIR" "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 3
mountpoint -q "$MNT" || { log "FATAL: mount failed"; exit 1; }
log "  mount OK"

# 检查布局
NF=$(ls "$DIR"/storage_test.* 2>/dev/null | wc -l)
log "  布局文件数=${NF}（期望128）"
if [ "$NF" -lt 1 ]; then
  log "FATAL: 无 128G 布局，请先跑冷态基线"
  exit 1
fi

# ---- 辅助函数 ----
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || true; }
rxget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }

run_seq(){
  local name="$1" rw="$2" bs="$3" size="$4" nj="$5" fsync="$6"
  local of="${OUTDIR}/${name}.txt"
  echo "# ${name}: rw=${rw} bs=${bs} size=${size} numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: --cache-size 102400 --max-readahead 0 --cache-dir ${CACHE_DIR}" >> "$of"
  echo "# date: $(date)" >> "$of"
  check_ceph_health "before ${name}"
  local args="--name=${name} --directory=${SEQ_DIR} --rw=${rw} --refill_buffers --bs=${bs} --size=${size}"
  [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
  [ "$fsync" = "1" ] && args="$args --end_fsync=1"
  local rx0; rx0=$(rxget)
  fio $args >> "$of" 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA} NIC_RX=${rxmb}"
  wait_fio
}

run_rand(){
  local name="$1" rw="$2" round="$3"
  local of="${OUTDIR}/${name}-r${round}.txt"
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: --cache-size 102400 --max-readahead 0 --cache-dir ${CACHE_DIR}" >> "$of"
  echo "# date: $(date)" >> "$of"
  echo "# cache_dir_size: $(du -s ${CACHE_DIR} 2>/dev/null | awk '{print $1}')KB" >> "$of"
  local rx0; rx0=$(rxget)
  check_ceph_health "before ${name} r${round}"
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576}")
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA} NIC_RX=${rxmb}"
  wait_fio
}

# ---- 顺序测试（1次，独立目录）----
log ""
log "## 顺序测试 (100G cache, 不 drop_caches)"
mkdir -p "$SEQ_DIR"

# seqread: 先写 4G 再读
log "### seqread prep (write 4G)"
check_ceph_health "before seqread prep"
rm -rf "$SEQ_DIR"/*
fio --name=prep --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=4M --size=4G >/dev/null 2>&1; wait_fio

run_seq "seqread" read 4M 4G 1 0
run_seq "seqwrite" write 4M 4G 1 1
run_seq "multi-seqread" read 4M 4G 16 0
run_seq "multi-seqwrite" write 4M 4G 16 1
rm -rf "$SEQ_DIR"

# ---- 随机测试（7轮，不 drop_caches，观察收敛）----
log ""
log "## 随机测试 (reuse 128G layout, 100G cache, 不 drop_caches, ${ROUNDS} rounds)"
log "  目标：观察 r1→r${ROUNDS} 收敛趋势，连续两轮变化 <5% 视为稳态"

for i in $(seq 1 "$ROUNDS"); do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
done

# ---- OSD 后状态 ----
log ""
log "## OSD 后状态"
{
  echo "### date: $(date)"
  echo "### OSD perf dump (after test)"
  for osd in 0 1 2 3 4 5; do
    echo "--- osd.$osd ---"
    sudo ceph daemon osd.$osd perf dump 2>&1 | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    o=d.get('osd',{})
    print('op_latency sum:', o.get('op_latency',{}).get('sum','N/A'))
    print('op_in_queue avgcount:', o.get('op_in_queue',{}).get('avgcount','N/A'))
    print('op_r_latency sum:', o.get('op_r_latency',{}).get('sum','N/A'))
except: print('parse error')
" 2>&1
  done
  echo "### cache dir final size"
  du -sh "$CACHE_DIR" 2>/dev/null
} > "${OUTDIR}/ceph-status-after.txt" 2>&1
log "  ceph status after -> ${OUTDIR}/ceph-status-after.txt"

# ---- 汇总 ----
log ""
log "============================================================"
log "## 汇总"
log "============================================================"
log ""
log "所有原始 fio 输出保存在: ${OUTDIR}/"
log "  - ceph-status-before.txt / ceph-status-after.txt (集群状态前后对比)"
log "  - client-status-before.txt (客户端状态快照)"
log "  - mount.log (挂载参数)"
log "  - seqread.txt / seqwrite.txt / multi-seqread.txt / multi-seqwrite.txt"
log "  - randread-r{1..${ROUNDS}}.txt / randwrite-r{1..${ROUNDS}}.txt / randrw-r{1..${ROUNDS}}.txt"
log "  - summary.txt (本文件)"
log ""
log "每轮 fio 文件包含: mount 参数 + 日期 + cache 大小 + fio 完整输出"
log "每轮 summary 记录: READ/WRITE/NIC_RX"
log ""
log "DONE"
