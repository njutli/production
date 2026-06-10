#!/bin/bash
# ============================================================
# 压测期间节点资源采样脚本（瓶颈分析用）
#
# 在每个存储节点上、压测开始前启动；压测结束后 Ctrl-C 停止。
# 采集：
#   - CPU：整机利用率 + radosgw / ceph-osd 进程占用
#   - 网卡：默认网卡收发 MB/s + 占千兆百分比
#   - OSD 盘：%util、读写 MB/s、IOPS、平均队列深度（sysstat 模式还多采 await）
# 每个采样间隔打印一行汇总，同时写入 CSV，便于事后画图/找峰值。
#
# 数据源（--source）：
#   kernel  （默认）只读 /proc 和 /sys，零依赖、不需要 root，三节点通用。
#   sysstat 借用 iostat 采盘指标（%util/await/aqu-sz 更准），需装 sysstat。
#           若选 sysstat 但本机没装 iostat，自动回退 kernel。
# CPU 与网卡两种模式都用 /proc + /sys（足够准，无需 sar）。
#
# 用法：
#   bash node-monitor.sh [间隔秒=2] [盘=sdb] [网卡=自动] [--source kernel|sysstat]
#   例：bash node-monitor.sh 2 sdb eno1                  # 内核接口（默认）
#       bash node-monitor.sh 2 sdb eno1 --source sysstat # 用 iostat
#
# 输出：
#   屏幕实时一行行打印；CSV 存到 /tmp/node-monitor-<host>-<时间>.csv
#   停止后打印峰值/均值小结。
# ============================================================

SOURCE="kernel"
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE="${2:-kernel}"; shift 2 ;;
        --source=*) SOURCE="${1#*=}"; shift ;;
        *) POS+=("$1"); shift ;;
    esac
done

INTERVAL="${POS[0]:-2}"
DISK="${POS[1]:-sdb}"
NIC="${POS[2]:-$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)}"

if [ "${SOURCE}" != "kernel" ] && [ "${SOURCE}" != "sysstat" ]; then
    echo "ERROR: --source 只能是 kernel 或 sysstat（默认 kernel）"; exit 1
fi
# 选了 sysstat 但没装 iostat → 自动回退 kernel
if [ "${SOURCE}" = "sysstat" ] && ! command -v iostat >/dev/null 2>&1; then
    echo "WARNING: 本机未安装 iostat（sysstat），自动回退到 kernel 模式。"
    SOURCE="kernel"
fi

HOST="$(hostname)"
NCPU="$(nproc)"
TS="$(date +%Y%m%d-%H%M%S)"
CSV="/tmp/node-monitor-${HOST}-${TS}.csv"

# 时钟节拍（用户/系统时间换算秒）；扇区固定 512B
CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

# sysfs 里磁盘的 statistics 比 /proc/diskstats 更直观
DISK_STAT="/sys/block/${DISK}/stat"
NIC_RX="/sys/class/net/${NIC}/statistics/rx_bytes"
NIC_TX="/sys/class/net/${NIC}/statistics/tx_bytes"

# 网卡线速（Mb/s）→ 字节/秒，用于算占用百分比
NIC_SPEED_MB="$(cat /sys/class/net/${NIC}/speed 2>/dev/null || echo 1000)"
NIC_LINE_BPS=$(( NIC_SPEED_MB * 1000 * 1000 / 8 ))

# --- 前置检查 ---
if [ ! -r "${DISK_STAT}" ]; then
    echo "ERROR: 找不到磁盘 ${DISK}（${DISK_STAT} 不可读）。用法见脚本头部。"
    echo "可用块设备：$(ls /sys/block | tr '\n' ' ')"
    exit 1
fi
if [ ! -r "${NIC_RX}" ]; then
    echo "ERROR: 找不到网卡 ${NIC}。可用网卡：$(ls /sys/class/net | tr '\n' ' ')"
    exit 1
fi

echo "========================================================"
echo " 节点资源监控  host=${HOST}  cpu核数=${NCPU}"
echo " 间隔=${INTERVAL}s  盘=${DISK}  网卡=${NIC}(${NIC_SPEED_MB}Mb/s)  数据源=${SOURCE}"
echo " CSV=${CSV}"
echo " 压测结束后按 Ctrl-C 停止，会打印小结。"
echo "========================================================"

# CSV 表头（await 列仅 sysstat 模式有值）
echo "time,cpu_util%,radosgw_cpu%,ceph_osd_cpu%,rx_MBps,tx_MBps,net_util%,disk_util%,rd_MBps,wr_MBps,rd_iops,wr_iops,aqu,await_ms" > "${CSV}"

# --- 采样辅助：读 /proc/stat 第一行的总 jiffies 与 idle jiffies ---
read_cpu() {
    # 返回 "total idle"
    awk '/^cpu /{idle=$5+$6; tot=0; for(i=2;i<=NF;i++)tot+=$i; print tot, idle; exit}' /proc/stat
}

# 某类进程占用的 CPU jiffies（utime+stime 累加），用 comm 匹配
read_proc_jiffies() {
    local name="$1" sum=0 j
    for p in $(pgrep -x "$name" 2>/dev/null); do
        # /proc/<pid>/stat 第 14、15 字段是 utime、stime
        j=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null || echo 0)
        sum=$(( sum + j ))
    done
    echo "$sum"
}

# 读磁盘 stat：字段 3=读扇区 7=写扇区 10=正在进行的IO 11=io耗时ms(util)
# 还需要读次数(1)、写次数(5)算 IOPS，加权io时间(11)算 util，队列(11/区间)
read_disk() {
    # rd_ios rd_sec wr_ios wr_sec io_ms weighted_ms
    awk '{print $1, $3, $5, $7, $10, $11}' "${DISK_STAT}"
}

# --- 初值 ---
read CPU_TOT0 CPU_IDLE0 < <(read_cpu)
RGW_J0=$(read_proc_jiffies radosgw)
OSD_J0=$(read_proc_jiffies ceph-osd)
RX0=$(cat "${NIC_RX}"); TX0=$(cat "${NIC_TX}")
read DRD0 DRDSEC0 DWR0 DWRSEC0 DIOMS0 DWMS0 < <(read_disk)
T0=$(date +%s.%N)

# --- 小结用累计 ---
MAX_DISK=0; MAX_NET=0; MAX_CPU=0; SUM_WR=0; SUM_RD=0; N=0

# 表头（屏幕）
printf "%-8s %6s %7s %7s %8s %8s %6s %7s %8s %8s %7s %7s %5s %7s\n" \
  "time" "cpu%" "rgw%" "osd%" "rxMB/s" "txMB/s" "net%" "disk%" "rdMB/s" "wrMB/s" "rIOPS" "wIOPS" "aqu" "await"

cleanup_summary() {
    echo ""
    echo "========================================================"
    echo " 小结（host=${HOST}，样本数=${N}）"
    if [ "${N}" -gt 0 ]; then
        echo "  峰值 CPU 利用率 : ${MAX_CPU}%"
        echo "  峰值 网卡占用   : ${MAX_NET}%  （${NIC_SPEED_MB}Mb/s 线速，单方向）"
        echo "  峰值 OSD盘 util : ${MAX_DISK}%"
        echo "  均值 写吞吐     : $(awk "BEGIN{printf \"%.1f\", ${SUM_WR}/${N}}") MB/s"
        echo "  均值 读吞吐     : $(awk "BEGIN{printf \"%.1f\", ${SUM_RD}/${N}}") MB/s"
        echo ""
        echo " 判读提示（rgw%/osd% 是进程多线程 CPU 之和，可远超 100%；"
        echo "          本机 ${NCPU} 核，满载约 ${NCPU}00%）："
        echo "  - OSD盘 util 接近 100% 且网卡未满、CPU 不高 → 瓶颈在 HDD/EC"
        echo "    随机小写读改写放大；此时加 RGW 无用（流量最终还是落这些盘）。"
        echo "  - 网卡占用接近 100%（单方向打满千兆）→ 瓶颈在网络链路"
        echo "    多 RGW + LB 把流量分到多节点多链路，可能有效。"
        echo "  - radosgw 进程 CPU 居高（占满若干核）而盘/网卡都没满 → RGW 进程瓶颈"
        echo "    加 RGW 分摊请求有效。"
    fi
    echo " CSV 已保存：${CSV}"
    echo "========================================================"
    exit 0
}
trap cleanup_summary INT TERM

# --- 主循环 ---
while true; do
    sleep "${INTERVAL}"

    T1=$(date +%s.%N)
    DT=$(awk "BEGIN{print ${T1}-${T0}}")

    # CPU 整机
    read CPU_TOT1 CPU_IDLE1 < <(read_cpu)
    DTOT=$(( CPU_TOT1 - CPU_TOT0 )); DIDLE=$(( CPU_IDLE1 - CPU_IDLE0 ))
    CPU_UTIL=$(awk "BEGIN{ if(${DTOT}>0) printf \"%.0f\", (1-${DIDLE}/${DTOT})*100; else print 0 }")

    # 进程 CPU（百分比，可超过 100%，因多核）
    RGW_J1=$(read_proc_jiffies radosgw)
    OSD_J1=$(read_proc_jiffies ceph-osd)
    RGW_CPU=$(awk "BEGIN{printf \"%.0f\", (${RGW_J1}-${RGW_J0})/${CLK_TCK}/${DT}*100}")
    OSD_CPU=$(awk "BEGIN{printf \"%.0f\", (${OSD_J1}-${OSD_J0})/${CLK_TCK}/${DT}*100}")

    # 网卡（千兆全双工：rx 和 tx 各有独立 1Gb，分方向算占用，取较大者）
    RX1=$(cat "${NIC_RX}"); TX1=$(cat "${NIC_TX}")
    RX_MB=$(awk "BEGIN{printf \"%.1f\", (${RX1}-${RX0})/${DT}/1048576}")
    TX_MB=$(awk "BEGIN{printf \"%.1f\", (${TX1}-${TX0})/${DT}/1048576}")
    NET_UTIL=$(awk "BEGIN{ rx=(${RX1}-${RX0})/${DT}/${NIC_LINE_BPS}*100; tx=(${TX1}-${TX0})/${DT}/${NIC_LINE_BPS}*100; m=(rx>tx?rx:tx); if(m>100)m=100; printf \"%.0f\", m }")

    # 磁盘
    if [ "${SOURCE}" = "sysstat" ]; then
        # 用 iostat 取一段 1s 采样（取第 2 份报告=区间均值）。
        # 字段名随版本略有差异，按表头定位列，兼容 r/s w/s rkB/s wkB/s
        # aqu-sz(或 avgqu-sz) r_await w_await %util。
        read DISK_UTIL RD_MB WR_MB RD_IOPS WR_IOPS AQU AWAIT < <(
          LC_ALL=C iostat -dxk "${DISK}" 1 2 2>/dev/null | awk -v dev="${DISK}" '
            /^Device/ { for(i=1;i<=NF;i++) col[$i]=i; rep++; next }
            rep>=2 && $1==dev {
              rkB=$(col["rkB/s"]); wkB=$(col["wkB/s"])
              rs=$(col["r/s"]);    ws=$(col["w/s"])
              util=$(col["%util"])
              aqu=(col["aqu-sz"]?$(col["aqu-sz"]):(col["avgqu-sz"]?$(col["avgqu-sz"]):0))
              rwt=(col["r_await"]?$(col["r_await"]):0)
              wwt=(col["w_await"]?$(col["w_await"]):0)
              await=(rwt>wwt?rwt:wwt)
              printf "%.0f %.1f %.1f %.0f %.0f %.1f %.2f",
                     util, rkB/1024, wkB/1024, rs, ws, aqu, await
              found=1
            }
            END{ if(!found) print "0 0.0 0.0 0 0 0.0 0.00" }')
        : "${DISK_UTIL:=0}" "${RD_MB:=0.0}" "${WR_MB:=0.0}" "${RD_IOPS:=0}" "${WR_IOPS:=0}" "${AQU:=0.0}" "${AWAIT:=0.00}"
    else
        # 内核接口：/sys/block/<dev>/stat 自算
        read DRD1 DRDSEC1 DWR1 DWRSEC1 DIOMS1 DWMS1 < <(read_disk)
        RD_MB=$(awk "BEGIN{printf \"%.1f\", (${DRDSEC1}-${DRDSEC0})*512/${DT}/1048576}")
        WR_MB=$(awk "BEGIN{printf \"%.1f\", (${DWRSEC1}-${DWRSEC0})*512/${DT}/1048576}")
        RD_IOPS=$(awk "BEGIN{printf \"%.0f\", (${DRD1}-${DRD0})/${DT}}")
        WR_IOPS=$(awk "BEGIN{printf \"%.0f\", (${DWR1}-${DWR0})/${DT}}")
        # %util = io_ms 增量 / 区间ms；aqu = weighted_ms 增量 / 区间ms
        DISK_UTIL=$(awk "BEGIN{u=(${DIOMS1}-${DIOMS0})/(${DT}*1000)*100; if(u>100)u=100; printf \"%.0f\", u}")
        AQU=$(awk "BEGIN{printf \"%.1f\", (${DWMS1}-${DWMS0})/(${DT}*1000)}")
        AWAIT=""   # 内核模式不算 await
        DRD0="${DRD1}"; DRDSEC0="${DRDSEC1}"; DWR0="${DWR1}"; DWRSEC0="${DWRSEC1}"
        DIOMS0="${DIOMS1}"; DWMS0="${DWMS1}"
    fi

    NOW=$(date +%H:%M:%S)
    printf "%-8s %6s %7s %7s %8s %8s %6s %7s %8s %8s %7s %7s %5s %7s\n" \
      "${NOW}" "${CPU_UTIL}" "${RGW_CPU}" "${OSD_CPU}" "${RX_MB}" "${TX_MB}" \
      "${NET_UTIL}" "${DISK_UTIL}" "${RD_MB}" "${WR_MB}" "${RD_IOPS}" "${WR_IOPS}" "${AQU}" "${AWAIT:--}"

    echo "${NOW},${CPU_UTIL},${RGW_CPU},${OSD_CPU},${RX_MB},${TX_MB},${NET_UTIL},${DISK_UTIL},${RD_MB},${WR_MB},${RD_IOPS},${WR_IOPS},${AQU},${AWAIT}" >> "${CSV}"

    # 累计/峰值
    N=$(( N + 1 ))
    SUM_WR=$(awk "BEGIN{print ${SUM_WR}+${WR_MB}}")
    SUM_RD=$(awk "BEGIN{print ${SUM_RD}+${RD_MB}}")
    [ "${DISK_UTIL}" -gt "${MAX_DISK}" ] 2>/dev/null && MAX_DISK="${DISK_UTIL}"
    [ "${NET_UTIL}" -gt "${MAX_NET}" ] 2>/dev/null && MAX_NET="${NET_UTIL}"
    [ "${CPU_UTIL}" -gt "${MAX_CPU}" ] 2>/dev/null && MAX_CPU="${CPU_UTIL}"

    # 滚动基线（CPU/网卡两模式都用；磁盘基线在 kernel 分支内已更新）
    CPU_TOT0="${CPU_TOT1}"; CPU_IDLE0="${CPU_IDLE1}"
    RGW_J0="${RGW_J1}"; OSD_J0="${OSD_J1}"
    RX0="${RX1}"; TX0="${TX1}"
    T0="${T1}"
done
