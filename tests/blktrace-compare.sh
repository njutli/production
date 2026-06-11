#!/bin/bash
# ============================================================
# 用 blktrace 对比"本地 ext4 直写 HDD" vs "JuiceFS+Ceph 落 OSD HDD"
# 两种场景下，真正落到磁盘的 IO 模型（大小/读写比/顺序性/队列）。
#
# 背景：同样 fio 顺序读写，本地 ext4 ~270MB/s 写，而 JuiceFS+Ceph 只有
# ~80MB/s。理论上差异来自 EC 写放大 + BlueStore 元数据小 IO + 跨节点同步，
# 本脚本用 blktrace 拿"落盘 IO 的实测分布"来量化验证，而非只靠推断。
#
# 运行位置：ceph-node1（同时有可测的两块同型号 HDD）
#   - sda：系统盘所在 HDD，ubuntu-vg 有空闲，临时建 ext4 LV 做"本地基线"
#   - sdb：OSD 数据盘 HDD，抓 JuiceFS+Ceph 落盘 IO
#
# 用法（在 ceph-node1 上）：
#   sudo bash blktrace-compare.sh local     # 场景A：本地 ext4 直写，抓 sda
#   sudo bash blktrace-compare.sh ceph       # 场景B：抓 sdb（需另一端在跑 JuiceFS fio）
#   sudo bash blktrace-compare.sh report     # 汇总两份 btt 结果对比
#
# 注意：
#   - 场景A 会在 ubuntu-vg 临时建 20G LV (fio-baseline)，测完自动删除。
#   - 场景B 只读不写 OSD 盘的 trace，不影响 OSD 数据；需要你在客户端
#     (tikv-node) 另跑 JuiceFS 顺序写 fio，本脚本只负责抓 sdb 的 blktrace。
# ============================================================

set -uo pipefail
ACTION="${1:-help}"
DUR="${2:-30}"                 # 采集时长（秒）
OUT=/tmp/blktrace-compare
mkdir -p "${OUT}"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }; }

# ---- 用 btt 汇总一份 trace 的关键指标 ----
# 参数：$1 = trace 前缀（sda=本地 ext4 基线 / sdb=Ceph OSD），$2 = 中文标签
summarize() {
    local pfx="$1" label="$2"
    local f="${OUT}/${pfx}.btt.txt"
    if ! ls "${OUT}/${pfx}.blktrace."* >/dev/null 2>&1; then
        echo "===== ${label} (${pfx}): 无 trace 数据，跳过 ====="; return
    fi
    echo "===== btt 汇总：${label} (dev 前缀=${pfx}) ====="
    blkparse -i "${OUT}/${pfx}" -d "${OUT}/${pfx}.bin" >/dev/null 2>&1
    btt -i "${OUT}/${pfx}.bin" 2>/dev/null > "$f"
    echo "--- D2C 单 IO 盘上服务延迟(秒)：MIN AVG MAX N ---"
    grep -E "^D2C" "$f" | head -1
    echo "--- IO 大小/合并(Merge Info)：#Q下发 #D完成 Ratio | BLKavg(扇区,×512=字节) ---"
    grep -A4 "Device Merge Information" "$f" | grep -E "^[[:space:]]*\(" | head -1
    echo "--- 顺序性(D2D Seek)：NSEEKS  MEAN  MEDIAN | MODE  —— MODE=0(N) 中 N 越大越顺序 ---"
    grep -A4 "D2D Seek Information" "$f" | grep -E "^[[:space:]]*\(" | head -1
    echo "--- 读/写占比（随机写时若读多 = EC RMW 读改写放大证据）---"
    # 从 blkparse 的统计尾部取 Reads/Writes Queued
    blkparse -i "${OUT}/${pfx}" 2>/dev/null | grep -iE "Reads Queued|Writes Queued|Read Dispatches|Write Dispatches" | head -4
}

case "${ACTION}" in
  local)
    need_root
    RW="${3:-seq}"             # seq=顺序大IO / rand=256k随机读写(规格口径)
    echo ">>> 场景A：本地 ext4 直写 HDD（sda 的 ubuntu-vg 临时 LV），模式=${RW}"
    VG=ubuntu-vg; LV=fio-baseline; DEV=/dev/sda
    # 1) 建临时 LV + ext4（随机测试用更大的 LV 容纳并发文件）
    [ "${RW}" = rand ] && LVSIZE=20G || LVSIZE=20G
    lvcreate -y -L ${LVSIZE} -n ${LV} ${VG} || { echo "建 LV 失败（空间不足？）"; exit 1; }
    mkfs.ext4 -q /dev/${VG}/${LV}
    mkdir -p /mnt/fio-baseline
    mount /dev/${VG}/${LV} /mnt/fio-baseline
    # 3) 跑 fio
    if [ "${RW}" = rand ]; then
        # 规格口径：256k 随机读写、direct、高 iodepth。HDD 上 32 并发极慢，
        # 故缩规模：8 jobs × 1G。关键：先 layout 文件（不计入 trace），
        # 再启动 blktrace + 跑随机阶段，保证 trace 窗口对准随机读写。
        mkdir -p /mnt/fio-baseline/test_dir
        echo ">>> 预创建文件（layout，不抓 trace）..."
        fio --directory=/mnt/fio-baseline/test_dir --name=lay --rw=randrw \
            --bs=256k --size=1G --numjobs=8 --create_only=1 >/dev/null 2>&1
        echo ">>> 启动 blktrace + 随机读写 ${DUR}s..."
        blktrace -d ${DEV} -o sda -D "${OUT}" >/dev/null 2>&1 &
        BTPID=$!
        sleep 1
        fio --directory=/mnt/fio-baseline/test_dir --name=randrw \
            --rw=randrw --bs=256k --ioengine=libaio --iodepth=64 \
            --numjobs=8 --size=1G --direct=1 --group_reporting \
            --time_based --runtime=${DUR} 2>&1 | grep -E "READ:|WRITE:"
        sleep 1; kill -INT ${BTPID} 2>/dev/null; sleep 2
    else
        echo ">>> blktrace 抓 ${DEV} ${DUR}s..."
        blktrace -d ${DEV} -o sda -D "${OUT}" >/dev/null 2>&1 &
        BTPID=$!
        sleep 1
        fio --name=seqwrite --directory=/mnt/fio-baseline --rw=write \
            --bs=4M --size=4G --numjobs=1 --end_fsync=1 --runtime=${DUR} \
            --time_based 2>&1 | grep -E "WRITE:|bw="
        sleep 1; kill -INT ${BTPID} 2>/dev/null; sleep 2
    fi
    # 5) 清理
    umount /mnt/fio-baseline; lvremove -y ${VG}/${LV}
    echo ">>> 场景A trace 存于 ${OUT}/sda.blktrace.*；用 report 汇总"
    ;;

  ceph)
    need_root
    echo ">>> 场景B：抓 OSD 盘 sdb 的落盘 IO ${DUR}s"
    echo ">>> 请确认此刻客户端(tikv-node)正在对 JuiceFS 跑顺序写 fio！"
    echo ">>> 3 秒后开始抓..."
    sleep 3
    blktrace -d /dev/sdb -o sdb -D "${OUT}" 2>/dev/null &
    BTPID=$!
    sleep ${DUR}
    kill -INT ${BTPID} 2>/dev/null; sleep 2
    echo ">>> 场景B trace 存于 ${OUT}/sdb.*；用 report 汇总"
    ;;

  report)
    echo ">>> 汇总对比两种场景的落盘 IO 模型"
    echo ""
    summarize sda "本地 ext4 直写 HDD"
    echo ""
    summarize sdb "Ceph-OSD (EC + BlueStore)"
    echo ""
    echo ">>> 对比要点："
    echo "  - 平均 IO 大小：本地 ext4 顺序写应是大块(接近 bs)；"
    echo "    Ceph 侧若被拆小 + 混入元数据小 IO，平均会明显更小。"
    echo "  - 读占比：Ceph 顺序写时若出现可观读(EC RMW/元数据)，是放大证据。"
    echo "  - seek（寻道）次数/距离：Ceph 侧若 seek 远多于本地，说明磁头来回"
    echo "    在数据与元数据/分片之间跳 → 顺序写被随机化。"
    echo "  - D2C 延迟：单个 IO 在盘上的服务时间，反映寻道+介质开销。"
    ;;

  *)
    echo "用法: sudo bash blktrace-compare.sh [local|ceph|report] [时长秒=30] [seq|rand]"
    echo "  local seq   - 本地 ext4 顺序大IO直写 sda，抓 blktrace（自含 fio）"
    echo "  local rand  - 本地 ext4 256k 随机读写直写 sda（规格口径），抓 blktrace"
    echo "  ceph        - 抓 sdb 落盘 IO（需在 tikv-node 另跑 JuiceFS fio，顺序或随机均可）"
    echo "  report      - 用 btt 汇总对比两份 trace（IO大小/顺序性/读写占比）"
    ;;
esac
