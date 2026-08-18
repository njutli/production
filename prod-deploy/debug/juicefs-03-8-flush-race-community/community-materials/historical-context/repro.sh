#!/usr/bin/env bash
# repro.sh — JuiceFS 纯随机写崩塌复现（slice ID 异步登记竞态）
#
# 缺陷：写请求尺寸 = 数据块大小时，新 slice 的编号异步登记，上传环节误判"未登记"而跳过，
#       数据滞留触发客户端缓冲节流，纯随机写吞吐崩塌 ~5.8×。
# 复现：STOCK（未打补丁）挂载 randwrite ≈ 550 MiB/s；PATCHED 挂载 ≈ 3000 MiB/s（恢复）。
#
# 流程：环境信息落盘 → （可选）layout 覆盖写目标 → STOCK 臂 → PATCHED 臂 → summary
# 依赖：fio（>=3.30）、两个 juicefs 二进制（同一基座 commit，仅差补丁）
#
# 用法：
#   META=redis://... \
#   STOCK=/path/to/juicefs-main        PATCHED=/path/to/juicefs-main-flushfix \
#   [MOUNTPOINT=/mnt/juicefs] [TEST_DIR=$MOUNTPOINT/repro_test] [RUNTIME=120] [BS=256k] \
#   [LAYOUT=1] [NUMJOBS=128] [FILE_NAME=repro] [ROUNDS=6] \
#   ./repro.sh
#
# 触发条件（务必满足其一）：BS = 卷数据块大小（juicefs config $META 的 BlockSize）。
#   默认块 4 MiB 的卷请用 BS=4M（挂载侧 --max-fuse-io 自动跟随 BS）。
#
# ⚑ 多轮复现协议（2026-08-14 定稿）：
#   竞态本身每轮必现（首写检查 99.2% 跳过），但**可见崩塌**需要环境进入"退化区"
#   （对象积累 / TiKV-OSD 负载 / gc 积压）。因此脚本按臂跑 ROUNDS 轮：
#   - stock 臂：干净环境下前几轮可能健康（~3800），写量积累后塌（~550）并自锁；
#     已退化环境下第一轮即塌。
#   - patched 臂：无论环境如何，ROUNDS 轮全部健康（首写必刷，不依赖兜底清仓）。
#   判读：summary.tsv 逐轮 bw 曲线。若 stock 全程未塌 ⇒ 环境仍新鲜，加大 ROUNDS
#   或先做预热写入后再跑；⛔ 对比结论必须同会话（跨时段单跑对比会被环境漂移混淆）。
#
# ⚑ 模式 A（默认，RESET=1）：每臂开跑前做环境复位（gc --compact + OSD compact 追平 +
#   drop_caches）——用于"同起点对照"。
# ⚑ 模式 B（RESET=0）：无复位预热复现——两臂连续、环境持续累积退化。
#   用途：①从干净状态必现塌态起始（stock 臂逐轮下滑、跨节流阈值后自锁 ~550）；
#        ②同脚本验证补丁。基座预期（重要）：
#   - v1.3.1 基座（STOCK=v1.3.1 原版、PATCHED=v1.3.1+补丁）：stock 第 1 轮即自锁 ~550；
#     patched 全程明显更高（~1000+）⇒ 补丁有效可见。
#   - main 基座（STOCK=main 原版、PATCHED=main+补丁）：两臂**一起**随轮次下滑、
#     先后进入塌态 ⇒ 补丁对 main 无收益（既定结论 A.4.1），此模式在 main 上的
#     价值 = 演示"main 也会塌"+ 记录塌态起始轮次。
#   塌态判定（summary 自动标注）：bw<600 且该轮缓冲峰>300MiB ⇒ "塌态"。
set -uo pipefail

META="${META:?用法: META=... STOCK=... PATCHED=... ./repro.sh}"
STOCK="${STOCK:?}"; PATCHED="${PATCHED:?}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/juicefs}"
TEST_DIR="${TEST_DIR:-$MOUNTPOINT/repro_test}"
RUNTIME="${RUNTIME:-120}"
BS="${BS:-256k}"
NUMJOBS="${NUMJOBS:-128}"
FILE_NAME="${FILE_NAME:-repro}"
LAYOUT="${LAYOUT:-1}"
ROUNDS="${ROUNDS:-6}"

OUT="repro-out-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/repro.log"; }

# ---------- 0) 环境信息落盘 ----------
{
  echo "=== 客户端 ==="
  uname -a; echo "cores=$(nproc)"; free -h | head -2
  echo "=== juicefs 二进制（两者必须同基座，仅差补丁）==="
  echo "STOCK:   $("$STOCK" version 2>&1 | head -1)"
  echo "PATCHED: $("$PATCHED" version 2>&1 | head -1)"
  echo "=== 卷格式（触发条件：BlockSize = BS）==="
  "$STOCK" config "$META" 2>&1 | head -15
  echo "=== fio ==="
  fio --version
} > "$OUT/env-info.txt" 2>&1
log "环境信息 → $OUT/env-info.txt"

umount_jfs() {
  "$STOCK" umount "$MOUNTPOINT" 2>/dev/null || fusermount -u "$MOUNTPOINT" 2>/dev/null || true
  sleep 5
  mount | grep -q " $MOUNTPOINT " && { log "STOP umount 失败"; exit 1; }
  return 0
}

sample() {   # $1=arm —— 1Hz 计数器采样（缓冲水位 + FUSE 写延迟 + PUT/写op，为"吸烟枪"证据）
  ( printf 'ts\tkey\tvalue\n'
    while :; do
      t=$(date +%s)
      timeout 3 cat "$MOUNTPOINT/.stats" 2>/dev/null \
        | grep -E '^(juicefs_used_buffer_size_bytes|juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_write|juicefs_object_request_durations_histogram_seconds_PUT_(sum|total)) ' \
        | awk -v t="$t" '{print t"\t"$1"\t"$2}'
      sleep 1
    done ) > "$OUT/sample-$1.tsv" &
  SAMPLER=$!
}

RESET="${RESET:-1}"
RESET_HOSTS="${RESET_HOSTS:-}"
SSHPASS_CMD="${SSHPASS_CMD:-sshpass -p <REDACTED> ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise}"

# ---------- 0.5) 环境复位（RESET=1 默认开；每臂开跑前执行）----------
# 只做清理/压缩类操作：gc --compact + OSD compact 追平 + drop_caches。
# ⛔ 不 restart OSD、不 rebuild/destroy pool、不改任何数据——不影响 layout 与持久层。
reset_env() {   # $1=标签
  local tag="$1" osds osd running queued i
  log "=== 环境复位（$tag）：gc --compact + OSD compact 追平 + drop_caches ==="
  "$STOCK" gc --compact "$META" >> "$OUT/repro.log" 2>&1 || log "  ⚠ gc --compact 非零退出（继续）"
  osds=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
  for osd in $osds; do timeout 30 sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
  local done_ok=false
  for i in $(seq 1 60); do
    local all_done=true
    for osd in $osds; do
      read -r running queued < <(timeout 10 sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c \
        'import sys,json;r=json.load(sys.stdin).get("rocksdb",{});print(r.get("compact_running",1),r.get("compact_queue_len",1))' 2>/dev/null || echo "1 1")
      { [ "$running" != "0" ] || [ "$queued" != "0" ]; } && all_done=false
    done
    $all_done && { done_ok=true; break; }
    sleep 5
  done
  $done_ok && log "  compact ✅ (~$((i*5))s)" || log "  ⚠ compact 超时 300s（继续，记录）"
  sync -f "$MOUNTPOINT" 2>/dev/null || true
  echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
  for ip in $RESET_HOSTS; do
    ${SSHPASS_CMD}@${ip} 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null \
      && log "  drop_caches $ip ✅" || log "  ⚠ drop_caches $ip 失败"
  done
}

run_arm() {   # $1=arm(stock|patched) $2=二进制路径 —— 同一挂载内跑 ROUNDS 轮
  local arm="$1" BIN="$2"
  log "=== 臂 $arm：挂载 $BIN（$ROUNDS 轮 × ${RUNTIME}s，单挂载）==="
  [ "$RESET" = "1" ] && reset_env "$arm-pre"
  umount_jfs
  "$BIN" mount -d --max-uploads 150 --cache-size 0 --max-fuse-io "$BS" "$META" "$MOUNTPOINT" >> "$OUT/repro.log" 2>&1
  sleep 5
  mount | grep -q " $MOUNTPOINT " || { log "STOP $arm 挂载失败"; exit 1; }
  local mr
  mr=$(grep " $MOUNTPOINT " /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
  log "$arm max_read=${mr:-NA}（期望 = BS 字节数）"
  for r in $(seq 1 "$ROUNDS"); do
    log "=== $arm 第 $r/$ROUNDS 轮 ==="
    sample "$arm-r$r"
    fio --directory="$TEST_DIR" --name="$FILE_NAME" \
        --filesize=1G --size=1G --bs="$BS" --rw=randwrite --ioengine=libaio \
        --iodepth=128 --numjobs="$NUMJOBS" --direct=1 --fallocate=none \
        --openfiles="$NUMJOBS" --group_reporting --time_based --runtime="$RUNTIME" \
        > "$OUT/fio-$arm-r$r.txt" 2>&1
    local rc=$?
    kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
    local bw mbw peak flag
    bw=$(grep -E '^\s+WRITE: bw=' "$OUT/fio-$arm-r$r.txt" | head -1)
    mbw=$(echo "$bw" | grep -oE "[0-9.]+" | head -1)
    peak=$(awk -F'\t' '$2=="juicefs_used_buffer_size_bytes"{if($3+0>m)m=$3+0} END{printf "%.0f", m/1048576}' "$OUT/sample-$arm-r$r.tsv" 2>/dev/null || echo 0)
    flag=""
    if [ -n "$mbw" ] && [ -n "$peak" ]; then
      python3 -c "import sys; sys.exit(0 if float('$mbw')<600 and float('$peak')>300 else 1)" 2>/dev/null && flag="⚑塌态"
    fi
    printf '%s\tr%s\trc=%s\tmax_read=%s\t%s\t%s\n' "$arm" "$r" "$rc" "${mr:-NA}" "$bw" "$flag" \
      | tee -a "$OUT/summary.tsv" "$OUT/repro.log"
    sleep 10   # 轮间沉降，在飞 IO 落地
  done
  "$BIN" umount "$MOUNTPOINT" 2>/dev/null || true; sleep 5
}

# ---------- 1) layout（可选；已有覆盖写目标文件时 LAYOUT=0）----------
if [ "$LAYOUT" = "1" ]; then
  log "=== layout：$NUMJOBS × 1GiB 覆盖写目标 ==="
  umount_jfs
  "$STOCK" mount -d --max-uploads 150 --cache-size 0 "$META" "$MOUNTPOINT" >> "$OUT/repro.log" 2>&1
  sleep 5
  mount | grep -q " $MOUNTPOINT " || { log "STOP layout 挂载失败"; exit 1; }
  mkdir -p "$TEST_DIR"
  fio --name=layout --directory="$TEST_DIR" --rw=write --bs=4M --size=1G \
      --numjobs="$NUMJOBS" --direct=1 > "$OUT/fio-layout.txt" 2>&1
  "$STOCK" umount "$MOUNTPOINT" 2>/dev/null || true; sleep 5
fi

# ---------- 2) STOCK → PATCHED ----------
run_arm stock   "$STOCK"
run_arm patched "$PATCHED"

# ---------- 3) 汇总 ----------
log "=== 完成。结果：$OUT/summary.tsv ==="
cat "$OUT/summary.tsv"
log "预期：stock 臂随轮次进入塌态（~550，自锁）；patched 臂全程健康（~3000）。"
log "判读：stock 全程健康 ⇒ 环境仍新鲜，加大 ROUNDS 或预热后重跑；缓冲/延迟证据见 sample-*.tsv"
