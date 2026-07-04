#!/bin/bash
# ============================================================
# 冷态 mu=150 精简测试：仅 randread + randwrite + randrw 3轮
# 跳过顺序测试避免 BlueFS stall
# ============================================================
set -uo pipefail

META="tikv://192.168.11.12:2379/juicefs-prod"
MNT="/mnt/juicefs"
DIR="${MNT}/test_dir"
TS="$(date +%Y%m%d-%H%M%S)"
PARENT="results/patched-v1.3.1-retest-20260702"
MOUNT_OPTS="--cache-size 0 --max-uploads 150"
OUTDIR="${PARENT}/cold-cache0-mu150"
OUT="${OUTDIR}/summary.md"

mkdir -p "$OUTDIR"
cd /home/turboai/production
source tests/lib/ceph-health-check.sh
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "冷态 mu=150 精简测试 ${TS}（仅随机测试）"
log "============================================================"
log "## 口径:"
log "  block-size=256K, cache=0, max-uploads=150"
log "  rand: 3轮（跳过顺序测试避免 BlueFS stall）"
log "  复用已有 128G 布局"
log ""

# ---- OSD cache drop ----
log "## Drop OSD page cache"
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  sshpass -p "TurboAi@303" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    turboai@$ip "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null" 2>/dev/null \
    && log "  $ip cache dropped" || log "  $ip FAILED"
done

# ---- 环境快照 ----
{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
  echo "### ceph osd tree"
  sudo ceph osd tree 2>&1
  echo "### juicefs version"
  juicefs --version 2>&1
  echo "### mount opts: ${MOUNT_OPTS}"
} > "${OUTDIR}/env-snapshot.txt" 2>&1

# ---- 挂载 ----
log "## 挂载"
juicefs umount "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
sleep 3
juicefs mount -d ${MOUNT_OPTS} "$META" "$MNT" 2>&1 | tee "${OUTDIR}/mount.log"
sleep 3
mountpoint -q "$MNT" || { log "FATAL: mount failed"; exit 1; }
log "  mount OK"

# ---- 工具函数 ----
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){
  local val unit
  val=$(grep -oP "$2: bw=\K[0-9.]+" "$1" | head -1)
  unit=$(grep -oP "$2: bw=[0-9.]+\K[a-zA-Z]+/s" "$1" | head -1)
  if [ -z "$val" ]; then echo ""; return; fi
  if [ "$unit" = "KiB/s" ]; then
    awk "BEGIN{printf \"%.1f\", $val/1024}"
  else
    echo "$val"
  fi
}
rxget(){ grep eno1 /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }
drop_client_cache(){
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
}

run_rand(){
  local name="$1" rw="$2" round="$3"
  local of="${OUTDIR}/${name}-r${round}.txt"
  drop_client_cache
  check_ceph_health "before ${name} r${round}"
  echo "# ${name} round ${round}: rw=${rw} bs=256k iodepth=128 numjobs=128 direct=1 runtime=60s" > "$of"
  echo "# mount: ${MOUNT_OPTS}" >> "$of"
  echo "# date: $(date)" >> "$of"
  local rx0; rx0=$(rxget)
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

# ---- 随机测试 ----
log ""
log "## 随机测试 (3轮, bs=256K, 128jobs, iodepth=128, direct=1, runtime=60s)"
for i in 1 2 3; do
  log "### Round ${i}"
  run_rand "randread" randread "$i"
  run_rand "randwrite" randwrite "$i"
  run_rand "randrw" randrw "$i"
done

# ---- 收尾 ----
{
  echo "### date: $(date)"
  echo "### ceph health"
  sudo ceph health 2>&1
} > "${OUTDIR}/ceph-status-after.txt" 2>&1

log ""
log "DONE"

# ---- commands.sh ----
cat > "${OUTDIR}/commands.sh" << CMDEOF
#!/bin/bash
# Commands: cold-cache0-mu150 randonly (patched v1.3.1)
# binary: /usr/local/bin/juicefs (patched, v1.3.1+2025-12-02.e0032b2a)
# 注：跳过顺序测试，仅随机测试（避免 BlueFS stall）

# drop OSD cache
for ip in 192.168.11.11 192.168.11.13 192.168.11.14; do
  sshpass -p "TurboAi@303" ssh turboai@\$ip "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null"
done

# mount
juicefs mount -d --cache-size 0 --max-uploads 150 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

# random tests (bs=256K, 3 rounds)
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G \\
    --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 \\
    --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime=60s
CMDEOF
chmod +x "${OUTDIR}/commands.sh"

log "  commands.sh generated"
