#!/bin/bash
# ============================================================
# 热态多轮带宽测试（验收口径，全程不 drop cache，自然预热）
# ============================================================
# 目的：在"当前证实有效的调优措施 + 大缓存"基础上，测一轮 vs 多轮带宽，
#       验证缓存（客户端 JuiceFS cache + 服务端 OSD BlueStore cache）逐轮预热下
#       带宽是否递增并最终稳定达标。这是"重复访问/热态"业务场景的验收口径。
#
# 与 bench-juicefs.sh 的区别：
#   - 全程不 drop_caches、不每轮重灌 warmup —— 缓存自然累积，才能看出"一轮 vs 多轮"差异
#   - 复用一份已有 128G 布局（不销毁卷），多轮跑 纯randread(读) + randrw(混合) 两项
#   - 每轮记录读/写带宽，观察 Run1→RunN 递增曲线与稳态
#
# ⚠️ 口径声明：本测试是【热态/缓存命中口径】，代表重复访问场景的上限，
#    不是冷态真值。冷态瓶颈定位另见 10_A 系列。
#
# 已证实有效、已纳入的调优：block-size 256K（format 时已定）、ceph 直连 RADOS、
#    EC 4+2、大 --cache-size（本脚本核心变量）。
# 已证伪、绝不纳入：--max-readahead 0 / --prefetch 0（10_A_4 冷态无改善+顺序写退化）、
#    FUSE congestion_threshold / 元数据强缓存 / splice（10_A_1/2_3/7 证伪或不支持）。
# ============================================================
set -u

# ---- 配置（可用环境变量覆盖）----
META="${META:-tikv://192.168.11.12:2379/juicefs-prod}"
MNT="${MNT:-/mnt/juicefs}"
DIR="${MNT}/test_dir"
CACHE_SIZE="${CACHE_SIZE:-102400}"          # MB，默认 100G，尽量装下 128G 工作集的大部分
CACHE_DIR="${CACHE_DIR:-/data/jfsCache}"
ROUNDS="${ROUNDS:-5}"                        # 多轮次数
RUNTIME="${RUNTIME:-60}"                     # 每项时长
NUMJOBS="${NUMJOBS:-128}"                    # 与 spec 对齐；若触发 10_issue-1 卡住可降到 32/8
FILESIZE="${FILESIZE:-1G}"                   # 与 128×1G 布局对齐
DO_WARMUP_ONCE="${DO_WARMUP_ONCE:-1}"       # 1=测试前先 warmup 一次预灌缓存；0=完全靠多轮自然预热
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-results/hot-multiround-${TS}.txt}"

mkdir -p results
log(){ echo "$@" | tee -a "$OUT"; }

log "========================================"
log "热态多轮带宽测试（验收口径，不 drop cache）  ${TS}"
log "META=${META}  CACHE_SIZE=${CACHE_SIZE}MB  CACHE_DIR=${CACHE_DIR}"
log "ROUNDS=${ROUNDS}  RUNTIME=${RUNTIME}s  NUMJOBS=${NUMJOBS}  FILESIZE=${FILESIZE}"
log "口径：热态/缓存命中，代表重复访问场景上限，非冷态真值"
log "========================================"

# ---- 前置检查：卷已挂载且有 128G 布局 ----
if ! mountpoint -q "$MNT"; then
  log "!! ${MNT} 未挂载。请先用大缓存挂载并准备好 128G 布局，例如："
  log "   juicefs mount -d --cache-size ${CACHE_SIZE} --cache-dir ${CACHE_DIR} ${META} ${MNT}"
  log "   （布局可复用 bench-juicefs.sh 的 DO_LAYOUT_ONLY=1，或已有 test_dir/storage_test.* 128 个文件）"
  exit 1
fi
NFILES=$(ls "$DIR"/storage_test.* 2>/dev/null | wc -l)
log ">>> 当前挂载参数："
grep -o "max_read=[0-9]*" /proc/mounts | head -1 | sed 's/^/   /' | tee -a "$OUT"
cat /proc/mounts | grep -i juicefs | sed 's/^/   /' | tee -a "$OUT"
log ">>> test_dir 布局文件数=${NFILES}（期望 128）"
[ "$NFILES" -lt 1 ] && { log "!! test_dir 无布局数据，先铺 128G 布局再跑。"; exit 1; }

# ---- 可选：测试前 warmup 一次（预灌缓存）----
if [ "$DO_WARMUP_ONCE" = "1" ]; then
  log ">>> 测试前 warmup 一次（预灌 test_dir 进缓存，之后全程不再清/不再重灌）"
  juicefs warmup "$DIR" 2>&1 | tail -3 | tee -a "$OUT" || true
fi

# fio 提取
bw_read(){ grep -oP 'READ: bw=\K[0-9.]+MiB/s' "$1" | head -1; }
bw_write(){ grep -oP 'WRITE: bw=\K[0-9.]+MiB/s' "$1" | head -1; }

run_fio(){  # $1=rw  $2=tag  $3=round
  local rw="$1" tag="$2" rnd="$3"
  local tmp="${OUT}.${tag}.r${rnd}"
  fio --directory="$DIR" --name=storage_test \
      --filesize="$FILESIZE" --size="$FILESIZE" \
      --bs=256k --rw="$rw" --ioengine=libaio --iodepth=128 \
      --numjobs="$NUMJOBS" --direct=1 --fallocate=none \
      --openfiles=100 --group_reporting \
      --time_based --runtime="${RUNTIME}s" \
      --output="$tmp" >/dev/null 2>&1
  echo "$tmp"
}

log ""
log "================ 多轮测试开始（全程不 drop cache）================"
declare -a RR_RES RW_RR RW_WR
for r in $(seq 1 "$ROUNDS"); do
  log ""
  log "------ Round ${r}/${ROUNDS} ------"

  # 纯随机读（缓存对纯读效果最好）
  f=$(run_fio randread rr "$r")
  rr=$(bw_read "$f"); RR_RES[$r]="${rr:-NA}"
  log "  [randread]  READ=${rr:-NA} MiB/s   ($f)"

  # 混合随机读写（9b 口径：复用布局、无 create_on_open）
  f=$(run_fio randrw rw "$r")
  wr=$(bw_read "$f"); ww=$(bw_write "$f")
  RW_RR[$r]="${wr:-NA}"; RW_WR[$r]="${ww:-NA}"
  log "  [randrw]    READ=${wr:-NA} MiB/s  WRITE=${ww:-NA} MiB/s   ($f)"
done

log ""
log "================ 汇总（MiB/s，验收目标 59）================"
log "Round | randread | randrw-READ | randrw-WRITE"
for r in $(seq 1 "$ROUNDS"); do
  printf "  %d   |   %-6s |   %-6s    |   %-6s\n" \
    "$r" "${RR_RES[$r]}" "${RW_RR[$r]}" "${RW_WR[$r]}" | tee -a "$OUT"
done
log ""
log ">>> 判读："
log "    - 若 randread / randrw 逐轮递增并最终稳定 ≥59 → 热态/重复访问场景达标（有效交付证据）"
log "    - 若多轮后仍 <59 → 缓存对该负载无效（命中率不足，工作集 ≫ 缓存）"
log "    - 注意：randrw 含写、随机偏移重复命中率天然低于纯 randread，二者不互相代证"
log "    - 服务端 OSD BlueStore cache 未清，递增中含其贡献（本就是热态口径的一部分，符合验收设定）"
log "DONE  OUT=$OUT"
