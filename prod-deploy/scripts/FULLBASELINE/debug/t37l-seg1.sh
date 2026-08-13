#!/usr/bin/env bash
# /tmp/t37l-seg1.sh — 段1：客户端并发定位（只读）
# 🔴 2026-08-12 修订版（v2）。v1 全废，两个 bug：
#   B1 fio 单个选项值上限 4096 字符，128 个绝对路径 ≈5.3KB ⇒ "value exceeds max length of 4096"，
#      15 个 sweep 点全 rc=1。修法：改用 --directory + 相对路径列表（≈2.0KB），并加长度自检。
#   B2 本脚本【没有挂载步骤】，跑在 03-6 收尾留下的 128K 挂载上（锚点 1858 ≈128K 平台 1880 即为证据）。
#      修法：段首自行 umount + mount 256K + 验 max_read + 记实例身份。
set -uo pipefail
INSTR=/tmp/instrument.sh; OUT=/tmp/opencode-t3.7l; TD=/mnt/juicefs/test_dir
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
OPTS="--max-uploads 150 --cache-size 0 --max-fuse-io 256K"
mkdir -p "$OUT"; export I2B_SEC=10

# ---- (0) 挂 256K（B2 修复）----
P=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
[ -n "${P:-}" ] && { juicefs umount /mnt/juicefs 2>/dev/null || true; sleep 5; }
mount | grep -q juice && { echo "STOP umount 失败"; exit 1; }
juicefs mount -d $OPTS "$META" /mnt/juicefs >> "$OUT/mount.log" 2>&1
sleep 5
MR=$(grep juicefs /proc/mounts | grep -o 'max_read=[0-9]*' | head -1 | cut -d= -f2)
[ "${MR:-0}" != "262144" ] && { echo "STOP 段1 max_read=$MR ≠262144"; exit 1; }
Q=$(pgrep -af juicefs | awk '/mount.*\/mnt\/juicefs([[:space:]]|$)/{print $1; exit}')
echo "SEG1v2 max_read=$MR pid=$Q starttime_ticks=$(awk '{print $22}' /proc/$Q/stat) $(date '+%F %T')" \
  | tee -a "$OUT/arm-verify.txt"

# ---- (1) 恒定工作集文件列表：相对路径（B1 修复）----
cd "$TD" || { echo "STOP 无 $TD"; exit 1; }
N=$(ls read_test.*.0 2>/dev/null | wc -l)
[ "$N" -ne 128 ] && { echo "STOP read_test 文件数=$N ≠128"; exit 1; }
FLIST=$(ls read_test.*.0 | sort | tr '\n' ':' | sed 's/:$//')
echo "SEG1v2 flist_len=${#FLIST} nfiles=$N" | tee -a "$OUT/arm-verify.txt"
[ "${#FLIST}" -ge 4000 ] && { echo "STOP filename 长度 ${#FLIST} 接近 fio 4096 上限"; exit 1; }

run_point() {   # $1=tag  $2=numjobs  $3=mode(anchor|sweep)
  local tag="$1" j="$2" mode="$3" rc
  bash "$INSTR" start "$OUT" "$tag"
  if [ "$mode" = anchor ]; then
    # 与 V4 item_randread 逐字相同（每 job 一个文件），用于证明本段 fio 口径与 V4 可比
    fio --directory="$TD" --name=read_test \
        --filesize=1G --size=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
        --direct=1 --fallocate=none --openfiles=128 --readonly \
        --group_reporting --time_based --runtime=180 > "$OUT/fio-$tag.txt" 2>&1
  else
    # 恒定工作集：所有并发点都跨全部 128 个文件（128 GiB），避免低并发点被 OSD 缓存虚高
    fio --directory="$TD" --name=sweep \
        --filename="$FLIST" --file_service_type=random \
        --filesize=1G \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$j" \
        --direct=1 --fallocate=none --openfiles=128 --readonly \
        --group_reporting --time_based --runtime=180 > "$OUT/fio-$tag.txt" 2>&1
  fi
  rc=$?
  bash "$INSTR" stop "$OUT" "$tag"
  printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$j" "$mode" "$rc" \
    "$(grep -E '^\s+READ: bw=' "$OUT/fio-$tag.txt" | head -1)" >> "$OUT/s1v2-bw.tsv"
  echo "$tag jobs=$j mode=$mode rc=$rc $(date '+%F %T')" >> "$OUT/progress.txt"
  # 🔴 首点即校验：rc≠0 或无 bw 行 ⇒ 立即停，禁把 15 个点全跑成空（v1 的教训）
  if [ "$rc" -ne 0 ] || ! grep -qE '^\s+READ: bw=' "$OUT/fio-$tag.txt"; then
    echo "STOP $tag rc=$rc 且无 READ:bw 行，报错原文见 fio-$tag.txt"; return 9
  fi
  sleep 20   # 让在飞 IO 落地，避免相邻点互相污染
}

run_point "S1v2-anchor" 128 anchor || exit 9
for p in 1 2 3; do
  case $p in 1|3) SEQ="8 16 32 64 128";; 2) SEQ="128 64 32 16 8";; esac
  for j in $SEQ; do run_point "S1v2-j${j}-p${p}" "$j" sweep || exit 9; done
done
echo "=== SEG1v2 DONE $(date) ===" >> "$OUT/progress.txt"
