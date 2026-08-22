#!/usr/bin/env bash
# instrument.sh — I1-I4 瓶颈定位采集器（只读，与 FULLBASELINE_V4.sh 解耦）
#
# 用途：任何调参战役搭车产出跨层延迟预算数据。不修改 V4 主体（V4 md5 是判据锚点）。
#
# 用法：
#   bash instrument.sh start <OUTDIR> <TAG>
#   bash instrument.sh stop  <OUTDIR> <TAG>
#
# 采集项（全部只读，实测开销 <1% CPU）：
#   I1  1Hz JuiceFS .stats 子集      → i1-jfsstats-<TAG>.tsv
#   I2a 1Hz 进程级 CPU（/proc/PID/stat）→ i2-proc-<TAG>.tsv
#   I2b 30s 间隔逐线程 CPU 快照        → i2-threads-<TAG>.tsv
#   I3  1Hz 双网卡计数器 + TiKV RTT    → i3-net-<TAG>.tsv
#   I4  6 OSD op 延迟计数器 pre/post   → i4-osdperf-<TAG>-{pre,post}-osdN.json
#
# 遵循 skills/SYSTEM-SAFETY-SKILL.md：无 pkill -f、无 remount、无写入 /mnt/juicefs
set -uo pipefail

ACTION="${1:-}"; OUTDIR="${2:-}"; TAG="${3:-}"
[ -z "${ACTION}" ] || [ -z "${OUTDIR}" ] || [ -z "${TAG}" ] && { echo "用法: $0 {start|stop} <OUTDIR> <TAG>"; exit 2; }
mkdir -p "${OUTDIR}" || exit 1

MNT="/mnt/juicefs"
NIC_PUB="enp139s0f0np0"      # 100GbE Ceph public（数据面）
NIC_MGMT="eno12399"          # 10GbE 管理网（TiKV 元数据 + SSH，与外部租户共享）
TIKV_IP="10.20.1.150"
PIDFILE="${OUTDIR}/.instr-${TAG}.pids"

# .stats 只取瓶颈定位需要的键，控制体积
STAT_KEYS='juicefs_fuse_ops_durations_histogram_seconds_sum|juicefs_fuse_ops_durations_histogram_seconds_total|juicefs_fuse_ops_total_read|juicefs_fuse_ops_total_write|juicefs_fuse_read_size_bytes_sum|juicefs_fuse_write_size_bytes_sum|juicefs_meta_ops_durations_histogram_seconds_sum|juicefs_meta_ops_durations_histogram_seconds_total|juicefs_object_request_durations_histogram_seconds_GET_sum|juicefs_object_request_durations_histogram_seconds_GET_total|juicefs_object_request_durations_histogram_seconds_PUT_sum|juicefs_object_request_durations_histogram_seconds_PUT_total|juicefs_object_request_data_bytes_GET|juicefs_object_request_data_bytes_PUT|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_buffer_size_bytes|juicefs_used_read_buffer_size_bytes|juicefs_staging_blocks|juicefs_blockcache_hit_bytes|juicefs_blockcache_miss_bytes|juicefs_fuse_open_handlers'

jfs_pid() {
    # 与 V4 同口径：取 juicefs mount 主进程，禁用 pgrep -c（会匹配内核线程）
    pgrep -af "juicefs" 2>/dev/null | awk '/mount/ && !/instrument/ {print $1; exit}'
}

case "${ACTION}" in
start)
    : > "${PIDFILE}"
    PID="$(jfs_pid)"
    if [ -z "${PID:-}" ]; then
        echo "WARN: 未找到 juicefs mount 进程，I1/I2 跳过" >&2
    fi
    echo "instrument_start tag=${TAG} ts=$(date +%s) jfs_pid=${PID:-NA} $(date '+%F %T')" \
        > "${OUTDIR}/i0-meta-${TAG}.txt"
    if [ -n "${PID:-}" ] && [ -r "/proc/${PID}/stat" ]; then
        awk '{print "starttime_ticks="$22}' "/proc/${PID}/stat" >> "${OUTDIR}/i0-meta-${TAG}.txt"
    fi

    # ---- I1: 1Hz .stats 子集 ----
    (
        printf 'ts\tkey\tvalue\n'
        while :; do
            _t=$(date +%s)
            timeout 3 cat "${MNT}/.stats" 2>/dev/null \
                | grep -E "^(${STAT_KEYS}) " \
                | awk -v t="${_t}" '{print t"\t"$1"\t"$2}'
            sleep 1
        done
    ) > "${OUTDIR}/i1-jfsstats-${TAG}.tsv" 2>/dev/null &
    echo "$!" >> "${PIDFILE}"

    # ---- I2a: 1Hz 进程级 CPU ----
    # 🔴 2026-08-12 修：原实现把循环条件绑在启动时的 PID 上（while [ -r /proc/$PID/stat ]）。
    # V4 在收到 JUICEFS_MOUNT_OPTS 且未设 SKIP_REMOUNT 时会 remount，juicefs PID 随之变化，
    # 循环立即退出 ⇒ 03-6 全部 9 个 label 的 I2a 只采到 8 个样本、I2b 只采到 1 张快照。
    # 现改为每次迭代重解析 PID，并落 pid 列（该列同时是 remount 事件的免费探测器）。
    (
        printf 'ts\tpid\tutime\tstime\tnum_threads\trss_kb\n'
        while :; do
            _t=$(date +%s)
            _p="$(jfs_pid)"
            if [ -n "${_p:-}" ] && [ -r "/proc/${_p}/stat" ]; then
                _rss="$(awk '/VmRSS/{print $2; exit}' "/proc/${_p}/status" 2>/dev/null)"
                awk -v t="${_t}" -v p="${_p}" -v r="${_rss:-NA}" \
                    '{print t"\t"p"\t"$14"\t"$15"\t"$20"\t"r}' "/proc/${_p}/stat" 2>/dev/null
            fi
            sleep 1
        done
    ) > "${OUTDIR}/i2-proc-${TAG}.tsv" 2>/dev/null &
    echo "$!" >> "${PIDFILE}"

    # ---- I2b: 逐线程 CPU（间隔 I2B_SEC，默认 30s；定位单线程饱和时设 10s）----
    # /proc/<pid>/task/<tid>/stat 的 comm 字段允许包含空格和右括号，不能直接用
    # awk 的 $14/$15；必须以最后一个 ") " 为边界再按 Linux proc(5) 字段编号解析。
    (
        _interval="${I2B_SEC:-30}"
        printf 'ts\tpid\ttid\tcomm\tutime\tstime\n'
        while :; do
            _t=$(date +%s)
            _p="$(jfs_pid)"
            if [ -n "${_p:-}" ] && [ -d "/proc/${_p}/task" ]; then
                for _s in /proc/${_p}/task/*/stat; do
                    [ -r "${_s}" ] || continue
                    awk -v t="${_t}" -v p="${_p}" \
                        '{
                          tid=$1
                          line=$0
                          sub(/^[0-9]+ \(/, "", line)
                          # POSIX awk 的匹配是最左最长；尾部禁止再出现右括号，故命中最后一个 ") ".
                          if (!match(line, /\) [^)]*$/)) next
                          comm=substr(line, 1, RSTART-1)
                          rest=substr(line, RSTART+2)
                          n=split(rest, f, /[[:space:]]+/)
                          # rest 从原 field 3(state) 开始：f[12]/f[13] = field 14/15。
                          if (n >= 13 && f[12] ~ /^[0-9]+$/ && f[13] ~ /^[0-9]+$/)
                            print t"\t"p"\t"tid"\t"comm"\t"f[12]"\t"f[13]
                        }' "${_s}" 2>/dev/null
                done
            fi
            sleep "${_interval}"
        done
    ) > "${OUTDIR}/i2-threads-${TAG}.tsv" 2>/dev/null &
    echo "$!" >> "${PIDFILE}"
    echo "i2b_interval_sec=${I2B_SEC:-30}" >> "${OUTDIR}/i0-meta-${TAG}.txt"

    # ---- I3: 1Hz 双网卡计数器 + TiKV RTT ----
    (
        printf 'ts\tpub_rx\tpub_tx\tmgmt_rx\tmgmt_tx\n'
        while :; do
            _t=$(date +%s)
            awk -v t="${_t}" -v a="${NIC_PUB}" -v b="${NIC_MGMT}" '
                {gsub(/:/,"",$1)}
                $1==a {pr=$2; pt=$10}
                $1==b {mr=$2; mt=$10}
                END {print t"\t"pr"\t"pt"\t"mr"\t"mt}' /proc/net/dev
            sleep 1
        done
    ) > "${OUTDIR}/i3-net-${TAG}.tsv" 2>/dev/null &
    echo "$!" >> "${PIDFILE}"

    # TiKV RTT：跑测期间持续采（0.061ms 是空闲值，需看负载下是否退化）
    ( timeout 3600 ping -i 1 -D "${TIKV_IP}" 2>/dev/null ) > "${OUTDIR}/i3-tikv-rtt-${TAG}.txt" 2>/dev/null &
    echo "$!" >> "${PIDFILE}"

    # ---- I4: OSD op 延迟 pre ----
    for i in 0 1 2 3 4 5; do
        timeout 15 sudo ceph tell "osd.${i}" perf dump 2>/dev/null \
            > "${OUTDIR}/i4-osdperf-${TAG}-pre-osd${i}.json" || true
    done
    echo "instrument started tag=${TAG} samplers=$(wc -l < "${PIDFILE}")"
    ;;

stop)
    # ---- I4: OSD op 延迟 post（先采后停，避免漏窗口）----
    for i in 0 1 2 3 4 5; do
        timeout 15 sudo ceph tell "osd.${i}" perf dump 2>/dev/null \
            > "${OUTDIR}/i4-osdperf-${TAG}-post-osd${i}.json" || true
    done
    if [ -f "${PIDFILE}" ]; then
        while read -r p; do
            [ -n "${p}" ] && kill "${p}" 2>/dev/null || true
        done < "${PIDFILE}"
        sleep 1
        while read -r p; do
            [ -n "${p}" ] && kill -9 "${p}" 2>/dev/null || true
        done < "${PIDFILE}"
        rm -f "${PIDFILE}"
    fi
    echo "instrument_stop tag=${TAG} ts=$(date +%s) $(date '+%F %T')" >> "${OUTDIR}/i0-meta-${TAG}.txt"
    echo "instrument stopped tag=${TAG}"
    ;;
*)
    echo "用法: $0 {start|stop} <OUTDIR> <TAG>"; exit 2 ;;
esac
