#!/bin/bash
# ============================================================
# 全配置 × 全指标矩阵（包含 bench-juicefs.sh 所有测试类型）
# ============================================================
# 用户口径：先把所有配置 × 所有指标测出来，再决定交付口径。
# 决策：顺序项跑 1 次（不受缓存/多轮影响），随机/混合项跑多轮（看冷 r1 → 热 r3）。
#
# 复用 bench-juicefs.sh 的 fio 口径，但用 driver 对每个配置重新挂载（换 readahead/cache 参数）。
# 复用已有 128G 布局（卸载重挂不删 ceph 数据）；顺序测试用独立目录，不碰布局。
#
# 指标（对齐 bench-juicefs.sh）：
#   顺序：seqread / seqwrite(fsync) / seqwrite(nofsync) / multi-seqread / multi-seqwrite （独立目录）
#   随机：randread / randwrite[analysis] / randrw[analysis] （多轮，复用 128G 布局）
#   spec randwrite/randrw（create_on_open）需 fresh 空卷，与复用布局冲突 →
#     本矩阵不含；如需，对选定配置单独用 bench-juicefs.sh 全量补测。
#
# 纪律：布局默认参数预建（不在此脚本建）；诊断走 stderr；杀 fio 后等待（10_issue-1）。
# ============================================================
set -u

META="${META:-tikv://192.168.11.12:2379/juicefs-prod}"
MNT="${MNT:-/mnt/juicefs}"
LAYOUT_DIR="${MNT}/test_dir"        # 128G 布局（随机项复用）
SEQ_DIR="${MNT}/seq_dir"            # 顺序项独立目录（不碰布局）
IFACE="${IFACE:-eno1}"
RUNTIME="${RUNTIME:-60}"
RNJOBS="${RNJOBS:-128}"
CACHE_DIR="${CACHE_DIR:-/data/jfsCache}"
ROUNDS="${ROUNDS:-3}"               # 随机/混合项轮数
OSD_NODES="${OSD_NODES:-192.168.11.11 192.168.11.13 192.168.11.14}"
OSD_PW1="${OSD_PW1:-TurboAi@303}"
OSD_PW23="${OSD_PW23:-TurboAi@303}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-results/fullmatrix-${TS}.txt}"
mkdir -p results
log(){ echo "$@" | tee -a "$OUT"; }

# 配置：标签|挂载参数|cold(1=cache0需OSD drop)
CONFIGS=(
  "c0-default|--cache-size 0|1"
  "c0-noRA|--cache-size 0 --max-readahead 0|1"
  "cache-default|--cache-size 102400 --cache-dir ${CACHE_DIR}|0"
  "cache-noRA|--cache-size 102400 --cache-dir ${CACHE_DIR} --max-readahead 0|0"
  "cache-noRA-wb|--cache-size 102400 --cache-dir ${CACHE_DIR} --max-readahead 0 --writeback|0"
  "cache-default-wb|--cache-size 102400 --cache-dir ${CACHE_DIR} --writeback|0"
)

log "============================================================"
log "全配置 × 全指标矩阵  ${TS}   目标各项 ≥59 MiB/s"
log "ROUNDS(随机/混合)=${ROUNDS}  RUNTIME=${RUNTIME}s  随机jobs=${RNJOBS}"
log "配置数=${#CONFIGS[@]}  指标=seqread/seqwrite-fsync/seqwrite-nofsync/mseqread/mseqwrite + randread/randwrite/randrw×${ROUNDS}"
log "============================================================"

drop_client(){ sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; }
drop_osd(){ for n in $OSD_NODES; do local pw="$OSD_PW23"; [ "$n" = "192.168.11.11" ] && pw="$OSD_PW1";
  timeout 15 sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 turboai@"$n" \
    "sync; echo 3|sudo tee /proc/sys/vm/drop_caches>/dev/null" 2>/dev/null && echo "  drop OSD $n ok">&2 || echo "  drop OSD $n fail">&2; done; }
wait_fio(){ while pgrep -x fio >/dev/null 2>&1; do sleep 1; done; sleep 2; }
bwget(){ grep -oP "$2: bw=\K[0-9.]+(?=MiB/s)" "$1" | head -1; }

# $1=name $2=fio_args... ; writes to $OF, echoes "READ|WRITE"
runf(){ local of="$1"; shift; echo "# mount: $MOPTS" > "$of"; echo "# $*" >> "$of"
  fio "$@" >> "$of" 2>&1; echo "$(bwget "$of" READ)|$(bwget "$of" WRITE)"; }

if ! mountpoint -q "$MNT"; then log "!! 需先挂载+128G布局"; exit 1; fi
[ "$(ls "$LAYOUT_DIR"/storage_test.* 2>/dev/null|wc -l)" -lt 1 ] && { log "!! 无128G布局"; exit 1; }

for cfg in "${CONFIGS[@]}"; do
  IFS='|' read TAG MOPTS COLD <<< "$cfg"
  log ""; log "########## ${TAG}  (${MOPTS})  cold=${COLD} ##########"
  juicefs umount "$MNT" 2>>"$OUT"; sleep 2
  juicefs mount -d $MOPTS "$META" "$MNT" >>"$OUT" 2>&1; sleep 3
  mountpoint -q "$MNT" || { log "  !! mount fail skip"; continue; }
  mkdir -p "$SEQ_DIR"

  # ---- 顺序项（各 1 次，独立目录，不碰布局）----
  # 读类先用同参数写出文件再读（4G << 100G cache，seqread 为热读口径）；写类直接写。
  [ "$COLD" = "1" ] && { drop_client; drop_osd; } || drop_client

  # seqread: 先写 4G 再读（热读口径，4G 数据在 cache 内）
  rm -rf "$SEQ_DIR"/*
  fio --name=prep --directory="$SEQ_DIR" --rw=write --bs=4M --size=4G >/dev/null 2>&1; wait_fio
  echo "# mount: $MOPTS" > "${OUT}.${TAG}-seqread"
  fio --name=sequential-read --directory="$SEQ_DIR" --rw=read --refill_buffers --bs=4M --size=4G >> "${OUT}.${TAG}-seqread" 2>&1
  sr=$(bwget "${OUT}.${TAG}-seqread" READ); wait_fio

  # seqwrite (fsync): 写完 fsync，含刷后端时间
  rm -rf "$SEQ_DIR"/*
  echo "# mount: $MOPTS" > "${OUT}.${TAG}-seqwrite-fsync"
  fio --name=sequential-write --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=4M --size=4G --end_fsync=1 >> "${OUT}.${TAG}-seqwrite-fsync" 2>&1
  swf=$(bwget "${OUT}.${TAG}-seqwrite-fsync" WRITE); wait_fio

  # seqwrite (nofsync): 写完不 fsync，暴露 writeback 对流式写的真实收益
  rm -rf "$SEQ_DIR"/*
  echo "# mount: $MOPTS" > "${OUT}.${TAG}-seqwrite-nofsync"
  fio --name=sequential-write --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=4M --size=4G >> "${OUT}.${TAG}-seqwrite-nofsync" 2>&1
  swn=$(bwget "${OUT}.${TAG}-seqwrite-nofsync" WRITE); wait_fio

  # multi-seqread: 先用 16 job 写再读
  rm -rf "$SEQ_DIR"/*
  fio --name=prep --directory="$SEQ_DIR" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1; wait_fio
  echo "# mount: $MOPTS" > "${OUT}.${TAG}-mseqread"
  fio --name=big-file-multi-read --directory="$SEQ_DIR" --rw=read --refill_buffers --bs=4M --size=4G --numjobs=16 --group_reporting >> "${OUT}.${TAG}-mseqread" 2>&1
  msr=$(bwget "${OUT}.${TAG}-mseqread" READ); wait_fio

  # multi-seqwrite
  rm -rf "$SEQ_DIR"/*
  echo "# mount: $MOPTS" > "${OUT}.${TAG}-mseqwrite"
  fio --name=big-file-multi-write --directory="$SEQ_DIR" --rw=write --refill_buffers --bs=4M --size=4G --numjobs=16 --end_fsync=1 --group_reporting >> "${OUT}.${TAG}-mseqwrite" 2>&1
  msw=$(bwget "${OUT}.${TAG}-mseqwrite" WRITE); wait_fio

  log "  [顺序] seqread=${sr:-NA} seqwrite-fsync=${swf:-NA} seqwrite-nofsync=${swn:-NA} multi-seqread=${msr:-NA} multi-seqwrite=${msw:-NA}"
  rm -rf "$SEQ_DIR"

  # ---- 随机/混合项（多轮，复用 128G 布局）----
  for rr in $(seq 1 "$ROUNDS"); do
    [ "$COLD" = "1" ] && { drop_client; drop_osd; } || drop_client
    res=$(runf "${OUT}.${TAG}-randread-r${rr}" --directory="$LAYOUT_DIR" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$RNJOBS" --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime="${RUNTIME}s"); rd=$(echo "$res"|cut -d'|' -f1); wait_fio
    [ "$COLD" = "1" ] && { drop_client; drop_osd; } || drop_client
    res=$(runf "${OUT}.${TAG}-randwrite-r${rr}" --directory="$LAYOUT_DIR" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs="$RNJOBS" --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime="${RUNTIME}s"); rw=$(echo "$res"|cut -d'|' -f2); wait_fio
    [ "$COLD" = "1" ] && { drop_client; drop_osd; } || drop_client
    res=$(runf "${OUT}.${TAG}-randrw-r${rr}" --directory="$LAYOUT_DIR" --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randrw --ioengine=libaio --iodepth=128 --numjobs="$RNJOBS" --direct=1 --fallocate=none --openfiles=100 --group_reporting --time_based --runtime="${RUNTIME}s"); mrd=$(echo "$res"|cut -d'|' -f1); mwr=$(echo "$res"|cut -d'|' -f2); wait_fio
    log "  [随机 r${rr}] randread=${rd:-NA} randwrite=${rw:-NA} randrw(R/W)=${mrd:-NA}/${mwr:-NA}"
  done
done

log ""
log "============================================================"
log "判读：找各项(顺序5 + 随机读/写/混合)同时 ≥59 的配置"
log "  cache=0 档看 r1（真冷态）；cache 档看 r1(冷)和 r3(热预热)"
log "  seqwrite-fsync vs seqwrite-nofsync：后者暴露 writeback 流式写收益"
log "  seqread 为热读口径（4G<<cache），非冷读后端"
log "  spec randwrite/randrw(create_on_open) 不在本矩阵，如需对选定配置用 bench-juicefs.sh 全量补"
log "  --writeback 有丢对象风险，交付须标注"
log "DONE OUT=$OUT"
