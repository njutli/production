#!/bin/bash
# ============================================================
# --max-readahead 档位扫描：权衡 随机读 vs 顺序读 vs 顺序写
# ============================================================
# 背景：10_A_4 证实 --max-readahead 0 让 128G 冷态随机读 44.9→73.2（达标），
#   但顺序写 70.1→54.2（−23%），且顺序读从未测过。
#   本脚本扫描 --max-readahead 多个档位，每档同测三条线，找权衡甜点。
#
# 参数语义：--max-readahead 单位 MiB（per read session）。0=关闭预读。
#
# 口径：128G 256K 冷态（cache=0）。每档重新挂载。每项跑前 client+OSD drop_caches。
#   r1 取冷态值；r2/r3 含 OSD BlueStore cache 预热，仅供观察。
#
# ⚠️ 依赖：卷已 format 为 256K block + 已铺 128G 布局（test_dir/storage_test.* ×128）。
#   若未就绪，先：EXTRA_FORMAT_OPTS="--block-size 256K" DO_LAYOUT_ONLY=1 bash tests/bench-juicefs.sh
# ============================================================
set -u

META="${META:-tikv://192.168.11.12:2379/juicefs-prod}"
MNT="${MNT:-/mnt/juicefs}"
DIR="${MNT}/test_dir"
IFACE="${IFACE:-eno1}"
RUNTIME="${RUNTIME:-60}"
NUMJOBS="${NUMJOBS:-128}"           # 随机读用；注意 10_issue-1 高并发偶发卡，必要时降 32
FILESIZE="${FILESIZE:-1G}"
# 扫描档位（MiB）；0=关，default=不带该参数用 JuiceFS 默认
READAHEAD_LIST="${READAHEAD_LIST:-0 1 4 8 default}"
# OSD 节点（用于 drop_caches 取真冷态）
OSD_NODES="${OSD_NODES:-192.168.11.11 192.168.11.13 192.168.11.14}"
OSD_PW1="${OSD_PW1:-TurboAi@303}"   # node1
OSD_PW23="${OSD_PW23:-123456}"      # node2/3
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-results/readahead-sweep-${TS}.txt}"
mkdir -p results
log(){ echo "$@" | tee -a "$OUT"; }

log "============================================================"
log "--max-readahead 档位扫描（128G 256K 冷态）  ${TS}"
log "档位(MiB): ${READAHEAD_LIST}   NUMJOBS=${NUMJOBS}  RUNTIME=${RUNTIME}s"
log "目标 59；随机读越高越好，顺序读/写不应跌破 59"
log "============================================================"

rxget(){ grep "$IFACE" /proc/net/dev | sed 's/:/ /' | awk '{print $2}'; }

drop_all(){
  # 所有诊断输出走 stderr，避免污染被 $(run_one) 捕获的 stdout 返回值
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  for n in $OSD_NODES; do
    local pw="$OSD_PW23"; [ "$n" = "192.168.11.11" ] && pw="$OSD_PW1"
    timeout 15 sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      turboai@"$n" "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null" 2>/dev/null \
      && echo "    drop OSD $n ok" >&2 || echo "    drop OSD $n FAIL(skip)" >&2
  done
}

# $1=rw $2=bs $3=njobs $4=tag
run_one(){
  local rw="$1" bs="$2" nj="$3" tag="$4"
  local tmp="${OUT}.${tag}"
  drop_all
  local rx0; rx0=$(rxget)
  fio --directory="$DIR" --name=storage_test --filesize="$FILESIZE" --size="$FILESIZE" \
      --bs="$bs" --rw="$rw" --ioengine=libaio --iodepth=128 --numjobs="$nj" \
      --direct=1 --fallocate=none --openfiles=100 --group_reporting \
      --time_based --runtime="${RUNTIME}s" --output="$tmp" >/dev/null 2>&1
  local rx1; rx1=$(rxget)
  local rxmb; rxmb=$(awk "BEGIN{printf \"%.1f\",($rx1-$rx0)/1048576/$RUNTIME}")
  local rd wr
  rd=$(grep -oP 'READ: bw=\K[0-9.]+(?=MiB/s)' "$tmp" | head -1)
  wr=$(grep -oP 'WRITE: bw=\K[0-9.]+(?=MiB/s)' "$tmp" | head -1)
  echo "${rd:-NA}|${wr:-NA}|${rxmb}"
}

mount_ra(){  # $1=readahead spec
  juicefs umount "$MNT" 2>/dev/null || true; sleep 2
  local opt=""
  [ "$1" != "default" ] && opt="--max-readahead $1"
  juicefs mount -d --cache-size 0 $opt "$META" "$MNT" >>"$OUT" 2>&1
  sleep 3
  mountpoint -q "$MNT" || { log "!! mount failed for readahead=$1"; return 1; }
}

if ! mountpoint -q "$MNT"; then log "!! 先挂载并准备 128G 256K 布局"; exit 1; fi
NF=$(ls "$DIR"/storage_test.* 2>/dev/null | wc -l)
log ">>> 布局文件数=$NF（期望128）"; [ "$NF" -lt 1 ] && { log "!! 无布局"; exit 1; }

log ""
log "readahead(MiB) | randread256k | seqread4M | seqwrite4M | (randread放大)"
log "---------------|--------------|-----------|------------|---------------"
for ra in $READAHEAD_LIST; do
  mount_ra "$ra" || continue
  IFS='|' read rr rrw rrx <<< "$(run_one randread 256k "$NUMJOBS" "ra${ra}-randread")"
  IFS='|' read sr srw srx <<< "$(run_one read    4M   16        "ra${ra}-seqread")"
  IFS='|' read sw sww swx <<< "$(run_one write   4M   16        "ra${ra}-seqwrite")"
  ampl=$(awk "BEGIN{ if(\"$rr\"!=\"NA\"&&$rr>0) printf \"%.2fx\", $rrx/($rr*1.048576); else print \"NA\" }")
  printf "  %-12s | %-12s | %-9s | %-10s | %s\n" "$ra" "${rr:-NA}" "${sr:-NA}" "${sww:-NA}" "$ampl" | tee -a "$OUT"
done

log ""
log ">>> 判读：找 randread 尽量高(≥59)、且 seqread/seqwrite 都不跌破 59 的最大档位"
log "    预期甜点在 256K(=1block)~1M 之间：够顺序流水、又不在随机读拉太多无用块"
log "DONE OUT=$OUT"
