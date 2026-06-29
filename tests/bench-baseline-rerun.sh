#!/bin/bash
# ============================================================
# 基线重测：可追溯、全原始数据保存
# ============================================================
# 目的：09 基线数据原始日志丢失 + 标注错误(cache声称0实际100G)，
#   需要一组干净、可复核的基准数据。
#
# 口径：
#   - STORAGE=ceph (RADOS 直连), block-size 256K
#   - cache-size 0 (真冷态, 无客户端缓存)
#   - 每项跑前 client drop_caches
#   - 不 drop OSD (模拟生产，OSD 自然状态)
#   - 每项 fio 原始输出保存到独立文件
#   - REPEAT=3 (取均值，排除单次波动)
#
# 测试项（对齐 bench-juicefs.sh step4-9b）：
#   1. seqread (4M bs, 1job, 4G)
#   2. seqwrite (4M bs, 1job, 4G, end_fsync=1)
#   3. multi-seqread (4M bs, 16job, 4G each)
#   4. multi-seqwrite (4M bs, 16job, 4G each, end_fsync=1)
#   5. layout (128job x 1G = 128G)
#   6. randread (256k bs, 128job, 1G each, REPEAT=3)
#   7. randwrite (256k bs, 128job, 1G each, REPEAT=3, reuse layout)
#   8. randrw (256k bs, 128job, 1G each, REPEAT=3, reuse layout)
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="results/baseline-rerun-20260625"
OUT="${OUTDIR}/summary.txt"
mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

# ---- 环境快照 ----
log "============================================================"
log "基线重测（可追溯） ${TS}"
log "============================================================"
log ""
log "## 测试方法"
log "  脚本: tests/bench-baseline-rerun.sh"
log "  启动命令: cd /home/turboai/production && bash tests/bench-baseline-rerun.sh"
log "  输出目录: results/baseline-rerun-20260625/"
log "  口径: STORAGE=ceph (RADOS 直连), block-size 256K, cache-size 0 (真冷态)"
log "  每项跑前 client drop_caches, 不 drop OSD"
log "  顺序项各 1 次; 随机项 REPEAT=3"
log ""
log "## 环境快照"
log ""
log "### 集群状态"
{
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
} > "${OUTDIR}/ceph-status.txt" 2>&1
log "  ceph status -> ${OUTDIR}/ceph-status.txt"

log "### 客户端状态"
{
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
  echo "### kernel modules"
  cat /proc/modules | grep fuse || echo "(fuse built-in, not module)"
  echo "### fuse version"
  fusermount -V 2>&1
  echo "### network"
  ip addr show eno1 | head -5
  echo "### mtu"
  cat /sys/class/net/eno1/mtu
} > "${OUTDIR}/client-status.txt" 2>&1
log "  client status -> ${OUTDIR}/client-status.txt"
log ""

# ---- 格式化卷 ----
log "## 格式化卷"
log "  STORAGE=ceph, pool=juicefs-data, block-size=256K"
# 先卸载，再销毁
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
sleep 5
# 等 session 过期
UUID=$(juicefs status "$META" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
if [ -n "$UUID" ]; then
  juicefs destroy --yes "$META" "$UUID" 2>&1 | tee "${OUTDIR}/destroy.log" || true
else
  echo "No existing volume to destroy" | tee "${OUTDIR}/destroy.log"
fi
sleep 65

unset ACCESS_KEY SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
juicefs format \
  --storage ceph \
  --bucket ceph://juicefs-data \
  --access-key ceph \
  --secret-key client.juicefs \
  --block-size 256K \
  --trash-days 0 \
  "$META" juicefs-prod 2>&1 | tee "${OUTDIR}/format.log"

log "## 挂载"
log "  --cache-size 0 (真冷态, 无客户端缓存)"
juicefs umount "$MNT" 2>/dev/null || true; sleep 2
juicefs mount -d --cache-size 0 "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 3
mountpoint -q "$MNT" || { log "FATAL: mount failed"; exit 1; }
log "  mount OK"

# ---- 辅助函数 ----
drop_client(){ sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; }
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1 || true; }

run_seq(){
  local name="$1" rw="$2" bs="$3" size="$4" nj="$5" fsync="$6"
  local of="${OUTDIR}/${name}.txt"
  drop_client
  echo "# ${name}: rw=${rw} bs=${bs} size=${size} numjobs=${nj} fsync=${fsync}" > "$of"
  echo "# mount: --cache-size 0" >> "$of"
  echo "# date: $(date)" >> "$of"
  check_ceph_health "before ${name}"
  local args="--name=${name} --directory=${DIR} --rw=${rw} --refill_buffers --bs=${bs} --size=${size}"
  [ "$nj" -gt 1 ] && args="$args --numjobs=${nj} --group_reporting"
  [ "$fsync" = "1" ] && args="$args --end_fsync=1"
  fio $args >> "$of" 2>&1
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name}: READ=${rd:-NA} WRITE=${wr:-NA}"
  wait_fio
}

run_rand(){
  local name="$1" rw="$2" round="$3"
  local of="${OUTDIR}/${name}-r${round}.txt"
  drop_client
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: --cache-size 0" >> "$of"
  echo "# date: $(date)" >> "$of"
  check_ceph_health "before ${name} r${round}"
  fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G \
      --bs=256k --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs=128 \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime=60s >> "$of" 2>&1
  local rd wr
  rd=$(bwget "$of" READ); wr=$(bwget "$of" WRITE)
  log "  ${name} r${round}: READ=${rd:-NA} WRITE=${wr:-NA}"
  wait_fio
}

# ---- 顺序测试 (test_dir) ----
log ""
log "## 顺序测试 (cache-size 0, client drop_caches per item)"
mkdir -p "$DIR"

# seqread: 先写 4G 再读
log "### seqread prep (write 4G)"
check_ceph_health "before seqread prep"
rm -rf "$DIR"/*
fio --name=prep --directory="$DIR" --rw=write --refill_buffers --bs=4M --size=4G >/dev/null 2>&1; wait_fio

run_seq "seqread" read 4M 4G 1 0
run_seq "seqwrite" write 4M 4G 1 1
run_seq "multi-seqread" read 4M 4G 16 0
run_seq "multi-seqwrite" write 4M 4G 16 1

# ---- 布局 (128G) ----
log ""
log "## 布局 (128 jobs x 1G = 128G)"
rm -rf "$DIR"/*
mkdir -p "$DIR"
check_ceph_health "before layout"
echo "# layout: 128 jobs x 1G, bs=4M, rw=write, end_fsync=1" > "${OUTDIR}/layout.txt"
echo "# date: $(date)" >> "${OUTDIR}/layout.txt"
fio --directory="$DIR" --name=storage_test --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 \
    >> "${OUTDIR}/layout.txt" 2>&1
lw=$(bwget "${OUTDIR}/layout.txt" WRITE)
log "  layout: WRITE=${lw:-NA}"
wait_fio

# ---- 随机测试 (REPEAT=3) ----
log ""
log "## 随机测试 (reuse layout, cache-size 0, client drop_caches per round)"

for i in 1 2 3; do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
done

# ---- 汇总 ----
log ""
log "============================================================"
log "## 汇总"
log "============================================================"
log ""
log "所有原始 fio 输出保存在: ${OUTDIR}/"
log "  - ceph-status.txt (集群状态快照)"
log "  - client-status.txt (客户端状态快照)"
log "  - format.log / mount.log (卷配置)"
log "  - seqread.txt / seqwrite.txt / multi-seqread.txt / multi-seqwrite.txt"
log "  - layout.txt"
log "  - randread-r{1,2,3}.txt / randwrite-r{1,2,3}.txt / randrw-r{1,2,3}.txt"
log "  - summary.txt (本文件)"
log ""
log "DONE"
