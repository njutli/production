#!/bin/bash
set -euo pipefail
export LC_ALL=C

# mount-gear-attrib-test.sh — R2：挂载实例"档位"的机制归因（只读实验，非基线、非调优）
#
# 上游结论（R1，报告 §十三）：
#   档位属于 JuiceFS 挂载实例 —— 组内两轮 ≤1.1%、组间 median 极差 29.9%（1334-1891 MiB/s）。
#   已排除：fio 进程（每轮新起）、集群侧（PG/config-md5/up_from 未变）、主机负载（最慢组 load 最低）。
#   未定：机制。线程落核（NUMA 奇偶）与档位不单调对应，且 R1 只采了挂载后的空载瞬时快照。
#
# 本实验要检验的主假设（2026-08-05 从 157 只读采集发现）：
#   到 OSD/TiKV 的流量走 eno12399（i40e，NUMA node0，src 10.20.1.157）。
#   该网卡有 119 个 TxRx 队列，IRQ 全部钉在偶核（node0）：
#     其中 9 个钉在 core 2/4/6/8/10/12/14/16 —— 正是被外部租户 100% 占满的 core 1-16 区间
#     （irq 694/710/711/713/730/731/744/778/785），另 1 个在 core 0，其余 109 个在 core>=17。
#     RPS 全关（rx-*/rps_cpus=0）⇒ 收包软中断只能在该 IRQ 的绑定核上跑。
#   每次 remount 会重建到 OSD/TiKV 的 TCP 连接，源端口随机 ⇒ RSS 4 元组哈希把连接分到不同队列。
#   若某条关键连接落到那 9 个饥饿队列之一，其收包处理被外部租户挤住 ⇒ 整档下移。
#   该假设与 R1 全部观测一致：锁定挂载实例（连接生命周期内端口不变）、多档连续（命中 0/1/2/3 条）、
#   −29% 量级、与线程 NUMA 无关、与 load 无关、与 fio 无关（fio 只走 FUSE，不走 TCP）。
#
# 设计（与 R1 的关键差别：在 fio 运行中采样，而非挂载后空载采一次）：
#   12 组 × 1 轮 randread（R1 已证组内 r1≈r2，单轮足够 ⇒ 同成本把组数翻倍，最大化相关性样本）
#   全部 12 组保持"现状挂载"（不绑核）—— 自变量是"这次抽签抽到哪些队列"，不能人为干预
#   每组：优雅 remount → 采挂载态 → fio 180s，期间每 15s 采 4 类数据
#     ① juicefs 线程落核（按 NUMA 奇偶归并）
#     ② /proc/interrupts 中 eno12399 各队列的中断增量（→ 本次流量落在哪些队列）
#     ③ ss -tin：juicefs 到 10.20.1.150-152 的连接（本地端口/rtt/cwnd/retrans/bytes_acked）
#     ④ mpstat -P ALL：各核 %usr/%sys/%soft（重点看饥饿核与活跃队列所在核）
#
# 判定（脚本自动给出）：
#   低档组的"饥饿队列中断占比"显著高于高档组，且随占比单调下降 ⇒ 机制定案（相关 + 剂量关系）
#   无相关 ⇒ 转候选：线程落核/内存首触 NUMA、Go runtime 一次性初始化；用 ①④ 的数据继续切
#
# 只读性质：不写测试数据、不改 ceph 配置、不动 pg_autoscale、不重启任何服务、
#           不改 IRQ 亲和性（/proc/irq/*/smp_affinity 只读不写）、不动 RPS/ethtool。
#           唯一写操作是 juicefs umount/mount 与 drop_caches（已授权）。
#           157 为 3075 用户共享机 ⇒ 禁止泛匹配 pkill，沿用四级优雅卸载。
#
# 用法：bash mount-gear-attrib-test.sh precheck            环境自检（1 分钟，正式跑前必做）
#       bash mount-gear-attrib-test.sh r3 [目标合格实例数]  R3 档位甄别协议（2026-08-05 主线，默认 12→建议 5）
#       bash mount-gear-attrib-test.sh r4                  R4 写历史效应（randrw 塌陷是否可由 gc --compact 复位）
#       bash mount-gear-attrib-test.sh [NGROUPS]           R2 机制归因，默认 12 组
#       ⚠️ 变量名不能用 GROUPS —— bash 的 GROUPS 是特殊数组变量（当前用户的组列表），
#          对它的赋值被**静默忽略**，${GROUPS} 会展开成主组 gid（157 上 = 1002）。
#          R1/R2 首次执行都因此把组数打印/循环成 1002，2026-08-05 改名为 NGROUPS 修复。
#       耗时 ≈ prep 10.5min + 12×(remount 1min + fio 3.3min + 采样开销) ≈ 1.1h
#
# 用完即弃：结论写入报告后删除本文件，不并入 FULLBASELINE_V4.sh
#           （若结论是"要迁 IRQ / 开 RPS / 绑核"，只把对应动作并入 V4 的挂载前置步骤）

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/r2-mount-gear-attrib"
POOL_DATA="juicefs-data"
STORE_IF="${STORE_IF:-eno12399}"          # 到 OSD/TiKV 的实际出口（ip route get 10.20.1.150 确认）
OSD_HOSTS="10.20.1.150 10.20.1.151 10.20.1.152"
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"

# 模式：precheck = 只做环境自检（约 1 分钟）不跑正式测试；run = R2 正式跑；r3 = 档位甄别协议验证
#       r4 = 写历史可逆性（阶段A 3 轮，2026-08-05 已跑，阴性/不可判）；r5 = 拐点定位（阶段A 最多 8 轮 + 早停）
MODE="run"
case "${1:-}" in
    precheck) MODE="precheck"; shift || true ;;
    r3)       MODE="r3";       shift || true ;;
    r4)       MODE="r4";       shift || true ;;
    r5)       MODE="r5";       shift || true ;;
esac
NGROUPS="${1:-12}"                       # r3 模式下含义 = 目标"高档合格实例"个数
case "${NGROUPS}" in ''|*[!0-9]*) echo "REFUSE: 组数必须是整数，收到 '${NGROUPS}'"; exit 1 ;; esac
[ "${NGROUPS}" -ge 1 ] && [ "${NGROUPS}" -le 40 ] || { echo "REFUSE: 组数需在 1-40，收到 ${NGROUPS}"; exit 1; }
# ⚑ R3 与 R2 用不同的结果目录/日志，避免把 a*/q* 数据混进 R2 的 g* 目录
LOGFILE="r2.log"
if [ "${MODE}" = "r3" ]; then RESULTS="/tmp/r3-mount-gear-attrib"; LOGFILE="r3.log"; fi
if [ "${MODE}" = "r4" ]; then RESULTS="/tmp/r4-write-history";     LOGFILE="r4.log"; fi
if [ "${MODE}" = "r5" ]; then RESULTS="/tmp/r5-write-knee";        LOGFILE="r5.log"; fi

RUNTIME=180
SAMPLE_EVERY=15
LAYOUT_JOBS=128
LAYOUT_SIZE="1G"

# ---------- R3 档位甄别协议参数（2026-08-05 定，依据 R1+R2 合并 22 次挂载）----------
# 高档带 = 1850-1891（12/22 命中，档内极差 2.2%）；判定带取 ±3% 余量
GEAR_LO="${GEAR_LO:-1830}"                # 高档下界 MiB/s
GEAR_HI="${GEAR_HI:-1930}"                # 高档上界 MiB/s
PROBE_RUNTIME="${PROBE_RUNTIME:-75}"      # 探针 fio 时长（判档窗口 15-60s，R2 复核 11/12 组误差 ≤1.6%）
PROBE_W_LO=15
PROBE_W_HI=60
R3_MAX_ATTEMPTS="${R3_MAX_ATTEMPTS:-0}"   # 0 = 自动取 3×目标+5
R3_RW_REPEAT="${R3_RW_REPEAT:-2}"         # 每个合格实例内的 randrw 轮数（同实例 L2）
PG_NUM_EXPECT="${PG_NUM_EXPECT:-32}"

# ---------- R4 写历史效应参数（2026-08-05 定，依据 R3 复核：r(randrw,累计写入)=-0.951）----------
# R3 观测：同一小时内 randrw 从 2506 跌到 1299（-48%），而高档 randread 只跌 7%；
#          中间插入 15 分钟纯读窗口后 randrw 未回升 ⇒ 不是瞬时队列效应。
#          池侧：juicefs-data 1.5 TiB / 6.30M objects（均值 250 KiB « 4 MiB 块）⇒ 疑随机写产生大量小切片。
# R4 只问一个问题：这个塌陷能不能被 `juicefs gc --compact` 复位？
#   可逆   ⇒ randrw 基线口径 = "compact 复位后第 1 轮"，调优每轮前复位 ⇒ randrw 可签收
#   不可逆 ⇒ randrw 绝对值永不签收，只能同实例 ABBA 配对 + 线性去趋势
R4_RW_BURST1="${R4_RW_BURST1:-3}"         # 阶段 A（compact 后）连续 randrw 轮数 —— 制造写历史
R4_RW_BURST2="${R4_RW_BURST2:-2}"         # 阶段 B（再次 compact 后）randrw 轮数 —— 看是否回升
R4_MAX_ATTEMPTS="${R4_MAX_ATTEMPTS:-4}"   # 为拿高档实例最多 remount 次数；用尽则降级继续（R4 是同实例内对比，档位只影响可比性）
R4_RECOVER_OK="${R4_RECOVER_OK:-80}"      # 恢复率 ≥ 此值(%) 判"可逆"
R4_RECOVER_PART="${R4_RECOVER_PART:-30}"  # 恢复率 ≥ 此值(%) 判"部分可逆"

# ---------- R5 拐点定位参数（2026-08-06 定，依据 R4 阴性结果）----------
# R4 实测：单实例内 5 轮 randrw（objects 2.36M→4.39M，累计写 846 GiB）极差仅 2.4%，塌陷未复现 ⇒ 不可判。
# R4 同时给出定量机制：每轮写 211 GiB ⇒ objects +757k（292 KiB/对象）⇒ 256k 随机写 = 1 个新对象，完全不合并；
#                       gc --compact 把 objects 精确复位到 2359506（与 prep 后逐位一致），stored 1059→576 GiB。
# R3 末态 6.30M objects 且已跌到 1202 ⇒ 拐点必在 4.4M-6.3M 之间，R4 根本没走到。
# R5 = 加长阶段 A 直到越过 6.5M objects，命中塌陷后再 compact 取恢复率。三出口 + 第四出口（彻底否证）。
R5_RW_BURST1="${R5_RW_BURST1:-8}"         # 阶段 A 最多 randrw 轮数（2.36M + 8×757k ≈ 8.4M，足以越过 6.3M）
R5_STOP_DROP="${R5_STOP_DROP:-15}"        # 阶段 A 早停：相对首轮跌幅 ≥ 此值(%) 即认为塌陷已充分，立即进复位段
R5_STOP_OBJ="${R5_STOP_OBJ:-7000000}"     # 阶段 A 早停：池 objects 超过此值即停（避免无意义堆空间）
R5_MAX_USED_GIB="${R5_MAX_USED_GIB:-6000}"  # 阶段 A 硬停：池 used 超过此值(GiB)立即停（MAX AVAIL 25 TiB，留足余量）
if [ "${MODE}" = "r5" ]; then
    R4_RW_BURST1="${R5_RW_BURST1}"
    R4_EARLY_STOP=1
fi
R4_EARLY_STOP="${R4_EARLY_STOP:-0}"

# ---------- 安全守卫（SYSTEM-SAFETY-SKILL.md §2.3 / §1.5）----------
# ⚠️ 必须定义在 safety_check_boot 调用之前 —— bash 是顺序解释，函数用在定义前会
#    报 "command not found"（2026-08-05 实测踩过：安装顺序错导致脚本第 69 行退出）。
safety_check() {
    local t="$1" what="${2:-path}"
    [ -n "${t}" ]            || { echo "REFUSE: empty ${what}"; exit 1; }
    [ "${t}" != "/" ]        || { echo "REFUSE: root path (${what})"; exit 1; }
    [ "${t:0:1}" = "/" ]     || { echo "REFUSE: relative ${what}=${t}"; exit 1; }
    case "${t}" in /tmp|/tmp/|/mnt|/mnt/|/proc*|/sys*|/dev*|/etc*|/boot*|/var|/var/|/usr*)
        echo "REFUSE: unsafe ${what}=${t}"; exit 1 ;; esac
    echo "SAFE: ${what}=${t}"
}

# 启动即做路径自检（SYSTEM-SAFETY-SKILL.md §2.3），任一不合规立即退出
safety_check_boot() {
    safety_check "${MNT}" MNT
    safety_check "${TEST_DIR}" TEST_DIR
    safety_check "${RESULTS}" RESULTS
    safety_check "${BW_LOG_DIR}" BW_LOG_DIR
    case "${BW_LOG_DIR}" in /tmp/jfs-bw) ;; *) echo "REFUSE: BW_LOG_DIR 必须是 /tmp/jfs-bw"; exit 1 ;; esac
    case "${MNT}" in /mnt/juicefs) ;; *) echo "REFUSE: MNT 必须是 /mnt/juicefs"; exit 1 ;; esac
}
safety_check_boot

mkdir -p "${RESULTS}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/${LOGFILE}"; }

# ---------- ⚑ 通配计数（勿用 `ls glob | wc -l`）----------
# set -o pipefail 下，glob 无匹配时 ls 返回非 0 ⇒ 整条管道非 0 ⇒ set -e 直接杀掉脚本。
# 2026-08-05 桩测试实证：启动清理里的 `n=$(ls ... | wc -l)` 让脚本在第一行日志前就静默退出。
count_glob() {
    local pat="$1" x; local -a m=()
    for x in ${pat}; do [ -e "${x}" ] && m+=("${x}"); done
    echo "${#m[@]}"
}

# ---------- ⚑ 启动即清空 BW_LOG_DIR（2026-08-05 修：R2 的 g1 被污染成 2162 的根因）----------
# 旧逻辑只在每轮 cp 之后清，若上一次跑被 kill，残留的 *_bw.*.log 会被**下一次跑的第一组**
# 用 `cp ${BW_LOG_DIR}/*_bw.*.log` 通配捞走 ⇒ 该组带宽被两次跑加总。
# R2 实测：g1-r1/ 里混进 128 个 g7-r1_bw.*.log（850B 的半截日志，来自被 kill 的 GROUPS-bug 跑），
# 逐秒均值 1886 被算成 2162（+14.6%），并把组间极差从 32.2% 夸大到 47.5%。
purge_bw_log_dir() {
    case "${BW_LOG_DIR}" in /tmp/jfs-bw) ;; *) echo "REFUSE: purge 目标必须是 /tmp/jfs-bw"; exit 1 ;; esac
    local n; n=$(count_glob "${BW_LOG_DIR}/*_bw.*.log")
    if [ "${n}" -gt 0 ]; then
        rm -f "${BW_LOG_DIR}"/*_bw.*.log 2>/dev/null || true
        log "  ⚑ 启动清理：BW_LOG_DIR 有 ${n} 个残留 bw log，已删除（防跨跑污染）"
    fi
}
purge_bw_log_dir

# ---------- 只匹配本挂载点的 juicefs 进程（157 为共享机，禁止泛匹配 pkill）----------
jfs_pid_of_mnt() {
    pgrep -af juicefs 2>/dev/null | awk -v m="${MNT}" '$0 ~ ("mount.*" m "([[:space:]]|$)") {print $1}' | head -1
}

# ---------- 安全守卫（SYSTEM-SAFETY-SKILL.md §2.3 / §1.5）----------

# 只允许杀"本挂载点、本用户、comm=juicefs"的进程；任何一项不符即拒绝（157 为 3075 用户共享机）
kill_guard() {
    local pid="$1"
    [ -n "${pid}" ] || { log "REFUSE kill: empty pid"; return 1; }
    case "${pid}" in ''|*[!0-9]*) log "REFUSE kill: non-numeric pid=${pid}"; return 1 ;; esac
    [ "${pid}" -gt 1 ] 2>/dev/null || { log "REFUSE kill: pid=${pid} <= 1"; return 1; }
    [ -d "/proc/${pid}" ] || { log "REFUSE kill: /proc/${pid} 不存在"; return 1; }
    local comm owner cmd
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null || echo "")
    [ "${comm}" = "juicefs" ] || { log "REFUSE kill: pid=${pid} comm=${comm} != juicefs"; return 1; }
    owner=$(stat -c %U "/proc/${pid}" 2>/dev/null || echo "")
    [ "${owner}" = "$(id -un)" ] || { log "REFUSE kill: pid=${pid} owner=${owner} != $(id -un)"; return 1; }
    cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || echo "")
    case "${cmd}" in *"${MNT}"*) ;; *) log "REFUSE kill: pid=${pid} cmdline 不含 ${MNT}：${cmd}"; return 1 ;; esac
    log "  kill_guard 通过: pid=${pid} comm=${comm} owner=${owner}"
    return 0
}

drop_caches() {
    sync
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    sleep 3
}

# ---------- 四级优雅卸载（与 FULLBASELINE_V4.sh 同一实现）----------
graceful_umount_jfs() {
    UMOUNT_MODE="none"
    if ! mountpoint -q "${MNT}" 2>/dev/null && [ -z "$(jfs_pid_of_mnt)" ]; then
        UMOUNT_MODE="already"; return 0
    fi
    log "  juicefs umount --flush ${MNT}"
    set +e
    juicefs umount --flush "${MNT}" 2>&1 | tail -2
    local rc=$?
    set -e
    if [ "${rc}" != "0" ]; then
        log "  ⚠️ juicefs umount rc=${rc}，回退 fusermount -u"
        fusermount -u "${MNT}" 2>/dev/null || true
    fi
    UMOUNT_MODE="graceful"
    local i pid
    for i in $(seq 30); do
        if ! mountpoint -q "${MNT}" 2>/dev/null && [ -z "$(jfs_pid_of_mnt)" ]; then
            log "  卸载完成（${i}s，优雅）"; return 0
        fi
        sleep 1
    done
    pid=$(jfs_pid_of_mnt)
    if [ -n "${pid}" ] && kill_guard "${pid}"; then
        log "  ⚠️ 30s 未退出，TERM pid=${pid}"
        kill -TERM "${pid}" 2>/dev/null || true
        UMOUNT_MODE="term"
        for i in $(seq 15); do
            [ -z "$(jfs_pid_of_mnt)" ] && { log "  TERM 后已退出（${i}s）"; return 0; }
            sleep 1
        done
        pid=$(jfs_pid_of_mnt)
        if [ -n "${pid}" ] && kill_guard "${pid}"; then
            log "  🔴 TERM 无效，KILL pid=${pid} —— 记录 UNCLEAN_UMOUNT"
            kill -KILL "${pid}" 2>/dev/null || true
            UMOUNT_MODE="kill"
            echo "UNCLEAN_UMOUNT mode=kill pid=${pid} $(date '+%F %T')" >> "${RESULTS}/UNCLEAN_UMOUNT.txt"
            sleep 5
        fi
    fi
}

remount_jfs() {
    graceful_umount_jfs
    for try in 1 2 3; do
        juicefs mount -d ${JUICEFS_MOUNT_OPTS} "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep -q juice && break; sleep 10
    done
    mount | grep -q juice || { log "FATAL: remount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
}

# ---------- 队列 IRQ → 绑定核（⚠️ 必须逐组采：157 上 irqbalance 处于 active，映射会漂移）----------
# 实测漂移（2026-08-05）：落在 core 1-16 的队列数 12:0x=9 → 12:25=11 → 12:3x=23
collect_irq_affinity() {
    local out="${1:-${RESULTS}/irq-affinity.txt}"
    {
        echo "# ts=$(date +%s) $(date '+%F %T')  irqbalance=$(systemctl is-active irqbalance 2>/dev/null || echo unknown)"
        echo "# irq core numa(0=偶核 1=奇核) starved(1=core 1-16 被外部租户占满)"
        grep -E "${STORE_IF}-TxRx" /proc/interrupts 2>/dev/null | sed 's/:.*//' | tr -d ' ' | while read -r i; do
            [ -z "${i}" ] && continue
            local c; c=$(cat /proc/irq/"${i}"/smp_affinity_list 2>/dev/null | head -1)
            [ -z "${c}" ] && continue
            local starved=0
            case "${c}" in
                *-*|*,*) ;;   # 多核掩码，保持 0
                *) [ "${c}" -ge 1 ] 2>/dev/null && [ "${c}" -le 16 ] 2>/dev/null && starved=1 ;;
            esac
            echo "${i} ${c} $(( c % 2 )) ${starved}"
        done
    } > "${out}" 2>/dev/null || true
    log "  IRQ 亲和性已记录 ${out##*/}（$(grep -c '^[0-9]' "${out}" 2>/dev/null || echo 0) 队列，饥饿核 $(awk '$4==1' "${out}" 2>/dev/null | wc -l) 个）"
}

irq_snapshot() {   # 每 IRQ 的总中断数（IRQ 已钉单核，跨核求和即该核处理量）
    grep -E "${STORE_IF}-TxRx" /proc/interrupts 2>/dev/null \
        | awk '{ irq=$1; sub(":","",irq); s=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print irq, s }'
}

thread_numa() {    # juicefs 线程按 NUMA 奇偶归并 + top 落核
    local pid="$1"
    [ -z "${pid}" ] && { echo "node0=NA node1=NA top=NA"; return; }
    local tmp; tmp=$(mktemp)
    for t in /proc/"${pid}"/task/*/stat; do awk '{print $39}' "${t}" 2>/dev/null; done > "${tmp}"
    awk '{ if ($1 % 2 == 0) a++; else b++; c[$1]++ }
         END { printf "node0=%d node1=%d top=", a+0, b+0;
               n=0; for (k in c) { printf "%s(%d) ", k, c[k]; if (++n>=6) break } ; print "" }' "${tmp}"
    rm -f "${tmp}"
}

ss_snapshot() {    # juicefs 到 OSD/TiKV 的连接：本地端口/rtt/cwnd/retrans
    local pid="$1"
    [ -z "${pid}" ] && { echo "(no pid)"; return; }
    # ss -tinp：带 users:(...) 的行是连接行，紧随其后的一行是 -i 的详细指标
    local out
    out=$(ss -tinp 2>/dev/null | awk -v p="pid=${pid}," '
        /users:\(/ { hit = (index($0, p) > 0); if (hit) print; next }
        hit == 1   { print; hit = 0 }' 2>/dev/null | head -80)
    if [ -n "${out}" ]; then
        echo "${out}"
    else
        echo "(ss -tinp 未匹配 pid=${pid}，回退按对端过滤)"
        ss -tin state established 2>/dev/null | grep -E -A1 '10\.20\.1\.15[012]' | head -80 || true
    fi
}

mpstat_snapshot() {
    if command -v mpstat >/dev/null 2>&1; then
        mpstat -P ALL 1 1 2>/dev/null | awk '
            /^Average/ { next }
            $2 == "all" { printf "all usr=%s sys=%s soft=%s idle=%s\n", $3, $5, $8, $NF; next }
            $2 ~ /^[0-9]+$/ {
                busy = $3 + $5 + $8;
                if (busy > 5.0) printf "c%s usr=%s sys=%s soft=%s ", $2, $3, $5, $8
            }
            END { print "" }'
    else
        echo "(mpstat 不可用)"
    fi
}

# ---------- 负载中采样器（fio 运行期间后台跑）----------
sampler() {
    local sub="$1"; local pid="$2"; local dur="$3"
    local t=0 n=0
    irq_snapshot > "${sub}/irq-t0.txt"
    while [ "${t}" -lt "${dur}" ]; do
        sleep "${SAMPLE_EVERY}"
        t=$((t + SAMPLE_EVERY)); n=$((n + 1))
        {
            echo "=== sample n=${n} t=${t}s ts=$(date '+%T') ==="
            echo "threads: $(thread_numa "${pid}")"
            echo "mpstat:  $(mpstat_snapshot)"
        } >> "${sub}/sampling.txt" 2>&1
        {
            echo "=== sample n=${n} t=${t}s ==="
            ss_snapshot "${pid}"
        } >> "${sub}/sampling-ss.txt" 2>&1
        # IRQ 亲和性漂移追踪（irqbalance active ⇒ 映射会变，必须随负载采）
        {
            echo "=== sample n=${n} t=${t}s ts=$(date +%s) 饥饿队列数=$(
                grep -E "${STORE_IF}-TxRx" /proc/interrupts 2>/dev/null | sed 's/:.*//' | tr -d ' ' | while read -r i; do
                    c=$(cat /proc/irq/"${i}"/smp_affinity_list 2>/dev/null | head -1)
                    case "${c}" in *-*|*,*) ;; *) [ "${c}" -ge 1 ] 2>/dev/null && [ "${c}" -le 16 ] 2>/dev/null && echo "${i} ${c}" ;; esac
                done | tee -a "${sub}/starved-irqs.txt" | wc -l)"
        } >> "${sub}/irq-affinity-trace.txt" 2>&1
        irq_snapshot > "${sub}/irq-t${t}.txt"
    done
}

# ---------- PG 只读门禁 ----------
pg_check() {
    local pid pgn pgp asc total nonclean dump
    pid=$(sudo ceph osd pool ls detail 2>/dev/null | grep -oP "^pool \K[0-9]+(?= '${POOL_DATA}')" | head -1)
    [ -z "${pid}" ] && { log "FATAL: 找不到 pool ${POOL_DATA}"; exit 1; }
    pgn=$(sudo ceph osd pool get "${POOL_DATA}" pg_num 2>/dev/null | awk '{print $2}')
    pgp=$(sudo ceph osd pool get "${POOL_DATA}" pgp_num 2>/dev/null | awk '{print $2}')
    asc=$(sudo ceph osd pool get "${POOL_DATA}" pg_autoscale_mode 2>/dev/null | awk '{print $2}')
    dump=$(sudo ceph pg dump pgs_brief 2>/dev/null || true)
    total=$(echo "${dump}" | awk -v p="${pid}." 'NR>1 && index($1,p)==1 {c++} END{print c+0}')
    nonclean=$(echo "${dump}" | awk -v p="${pid}." 'NR>1 && index($1,p)==1 && $2!="active+clean" {c++} END{print c+0}')
    log "PG: pool=${pid} pg_num=${pgn} pgp=${pgp} autoscale=${asc} pg_count=${total} nonclean=${nonclean}"
    [ "${pgn}" = "${PG_NUM_EXPECT}" ] || { log "FATAL: pg_num=${pgn} != ${PG_NUM_EXPECT}"; exit 1; }
    [ "${nonclean}" = "0" ] || { log "FATAL: nonclean=${nonclean}，PG 未全 active+clean"; exit 1; }
    [ "${asc}" = "off" ] || log "⚠️ pg_autoscale_mode=${asc}（应为 off）"
    echo "pool=${pid} pg_num=${pgn} pgp=${pgp} autoscale=${asc} pg_count=${total} nonclean=${nonclean}" > "${RESULTS}/pg-state.txt"
}

# ---------- ⚑ 池对象/容量快照（R4：碎片假设的直接观测量）----------
# 打印一行 "objects=<数> stored_gib=<数> used_gib=<数>"；失败打印 objects=NA
# 依据：6.30M objects / 1.5 TiB ⇒ 均值 250 KiB « JuiceFS 4 MiB 块 ⇒ 随机写切片碎裂
pool_stat() {
    sudo ceph df -f json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("objects=NA stored_gib=NA used_gib=NA"); sys.exit(0)
for p in d.get("pools", []):
    if p.get("name") == "'"${POOL_DATA}"'":
        s = p.get("stats", {})
        print("objects=%d stored_gib=%.1f used_gib=%.1f" % (
            s.get("objects", 0), s.get("stored", 0)/1073741824.0, s.get("bytes_used", 0)/1073741824.0))
        break
else:
    print("objects=NA stored_gib=NA used_gib=NA")
' 2>/dev/null || echo "objects=NA stored_gib=NA used_gib=NA"
}


# ---------- 挂载态快照（与 R1 的 placement.txt 同格式，便于跨实验对照）----------
collect_placement() {
    local outdir="$1"
    local pid; pid=$(jfs_pid_of_mnt)
    {
        echo "ts=$(date +%s) $(date '+%F %T')"
        echo "umount_mode=${UMOUNT_MODE:-none}"
        echo "pid=${pid:-NA}"
        echo "--- taskset"
        [ -n "${pid}" ] && taskset -cp "${pid}" 2>/dev/null || echo "NA"
        echo "--- 线程落核（挂载后空载）"
        [ -n "${pid}" ] && thread_numa "${pid}"
        echo "--- VmRSS / Threads"
        [ -n "${pid}" ] && grep -E 'VmRSS|Threads' /proc/"${pid}"/status 2>/dev/null || true
        echo "--- 连接（挂载后空载）"
        ss_snapshot "${pid}"
        echo "--- uptime"
        uptime
        echo "--- mount 行"
        mount | grep juice | head -1
    } > "${outdir}/placement.txt" 2>&1 || true
}

# ---------- 一次 fio 轮（规格与 FULLBASELINE_V4.sh item_randread / item_randrw 完全一致）----------
# run_round LABEL [rw=randread] [runtime=${RUNTIME}] [fio_name=read_test]
#   randread → --name=read_test（读 read_test.*.0）
#   randrw   → --name=rw_test  （读写 rw_test.*.0，与 V4 item_randrw 同一批文件，互不干扰）
run_round() {
    local label="$1"
    local rw="${2:-randread}"
    local rt="${3:-${RUNTIME}}"
    local fname="${4:-read_test}"
    local sub="${RESULTS}/${label}"
    mkdir -p "${sub}"
    drop_caches
    local pid; pid=$(jfs_pid_of_mnt)
    echo "load_pre: $(uptime | grep -oE 'load average:.*')" > "${sub}/load.txt"
    sudo ceph config dump 2>/dev/null | md5sum | awk '{print $1}' > "${sub}/config-md5.txt" 2>/dev/null || true
    sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json;d=json.load(sys.stdin)
print(" ".join("%d:%d"%(o["osd"],o.get("up_from",0)) for o in sorted(d["osds"],key=lambda x:x["osd"])))
' > "${sub}/up_from.txt" 2>/dev/null || true
    log "  fio ${label}（rw=${rw} runtime=${rt}s name=${fname}）...（负载中采样 每 ${SAMPLE_EVERY}s）"
    sampler "${sub}" "${pid}" "${rt}" &
    local sp=$!
    set +e
    timeout $((rt + 120)) fio --directory="${TEST_DIR}" --name="${fname}" \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw="${rw}" --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
        --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
        --group_reporting --time_based --runtime=${rt} \
        --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${sub}/fio.txt" >/dev/null
    local rc=${PIPESTATUS[0]}
    set -e
    wait "${sp}" 2>/dev/null || true
    irq_snapshot > "${sub}/irq-tend.txt"
    echo "load_post: $(uptime | grep -oE 'load average:.*')" >> "${sub}/load.txt"
    cp "${BW_LOG_DIR}/${label}"_bw.*.log "${sub}/" 2>/dev/null || true
    [ "${BW_LOG_DIR}" = "/tmp/jfs-bw" ] && rm -f "${BW_LOG_DIR}"/*_bw.*.log 2>/dev/null || true
    # ⚑ 2026-08-05 加：只 cp 本 label 前缀 + 校验个数，杜绝跨轮/跨跑污染（R2 g1 教训）
    local nlog; nlog=$(count_glob "${sub}/${label}_bw.*.log")
    local nall; nall=$(count_glob "${sub}/*_bw.*.log")
    if [ "${nlog}" != "${LAYOUT_JOBS}" ] || [ "${nall}" != "${LAYOUT_JOBS}" ]; then
        echo "BWLOG_ANOMALY 本label=${nlog} 全部=${nall} 期望=${LAYOUT_JOBS}" > "${sub}/INVALID.txt"
        log "  🔴 ${label}: bw log 个数异常（本label=${nlog} 全部=${nall} 期望=${LAYOUT_JOBS}）⇒ 已标 INVALID"
    fi
    [ "${rc}" = "0" ] || echo "INVALID rc=${rc}" > "${sub}/INVALID.txt"
    local bw; bw=$(grep -oE 'bw=[0-9.]+MiB' "${sub}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || echo NA)
    log "  ${label}: fio汇总 BW=${bw} MiB/s"
}


# ---------- 逐秒均值（验收口径）：per_sec_mean LABEL W_LO W_HI [r|w|all] ----------
# 只读该 label 自己前缀的 bw log（勿用 *_bw.*.log 通配 —— R2 g1 就是这么被污染的）
per_sec_mean() {
    python3 - "${RESULTS}/$1" "$1" "${2:-15}" "${3:-175}" "${4:-all}" <<'PYEOF'
import sys, os, glob, statistics
from collections import defaultdict
sub, label, lo, hi, dirsel = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
per = defaultdict(float)
for f in glob.glob(os.path.join(sub, label + "_bw.*.log")):
    for line in open(f):
        q = line.strip().split(",")
        if len(q) < 3: continue
        try: s = int(q[0]) // 1000; bw = float(q[1]); d = int(q[2])
        except ValueError: continue
        if dirsel == "r" and d != 0: continue
        if dirsel == "w" and d != 1: continue
        per[s] += bw
if not per:
    print("NA"); sys.exit(0)
ks = sorted(per); t0 = ks[0]
w = [per[k] / 1024.0 for k in ks if lo <= k - t0 <= hi]
print("%.0f" % statistics.mean(w) if w else "NA")
PYEOF
}

# ---------- R3：档位甄别协议（2026-08-05）----------
# 目的：不依赖机制归因也拿到 ≤5% 的稳定基线。
# 依据：R1+R2 合并 22 次挂载 ⇒ 档位离散且档内极紧，高档 1850-1891 命中 12/22(55%)、档内极差 2.2%。
# 协议：remount → 75s 探针判档 → 落在 [GEAR_LO,GEAR_HI] 才留用 → 该实例内跑 randrw ×N → 收尾再探针验漂移
r3_main() {
    local target="${NGROUPS}"
    local maxatt="${R3_MAX_ATTEMPTS}"
    [ "${maxatt}" -gt 0 ] 2>/dev/null || maxatt=$((target * 3 + 5))
    log "=== R3 档位甄别：目标 ${target} 个高档实例，高档带=[${GEAR_LO},${GEAR_HI}] MiB/s，最多 ${maxatt} 次挂载 ==="
    log "=== 探针 = randread ${PROBE_RUNTIME}s（判档窗口 ${PROBE_W_LO}-${PROBE_W_HI}s）；合格实例内跑 randrw ×${R3_RW_REPEAT} 轮 ==="
    : > "${RESULTS}/r3-attempts.tsv"
    echo -e "attempt\tprobe1\tgear\tqualified\tqid\trw_values\tprobe2" >> "${RESULTS}/r3-attempts.tsv"
    local att=0 qid=0
    while [ "${qid}" -lt "${target}" ] && [ "${att}" -lt "${maxatt}" ]; do
        att=$((att + 1))
        log "--- 挂载尝试 a${att}（已合格 ${qid}/${target}）：remount ---"
        remount_jfs
        mkdir -p "${RESULTS}/a${att}"
        collect_irq_affinity "${RESULTS}/a${att}/irq-affinity.txt"
        collect_placement "${RESULTS}/a${att}"
        run_round "a${att}-probe1" randread "${PROBE_RUNTIME}" read_test
        local p1; p1=$(per_sec_mean "a${att}-probe1" "${PROBE_W_LO}" "${PROBE_W_HI}" r)
        local ok=0
        case "${p1}" in ''|NA) ok=0 ;; *)
            [ "${p1}" -ge "${GEAR_LO}" ] 2>/dev/null && [ "${p1}" -le "${GEAR_HI}" ] 2>/dev/null && ok=1 ;;
        esac
        if [ "${ok}" != "1" ]; then
            log "  ✗ a${att} 探针=${p1} MiB/s 不在高档带 ⇒ 弃用该实例，重新 remount 抽签"
            echo -e "a${att}\t${p1}\tnon-top\tno\t-\t-\t-" >> "${RESULTS}/r3-attempts.tsv"
            continue
        fi
        qid=$((qid + 1))
        log "  ✓ a${att} 探针=${p1} MiB/s 判为高档 ⇒ 合格实例 q${qid}，开始同实例内 randrw ×${R3_RW_REPEAT}"
        echo "a${att} probe1=${p1} qid=q${qid}" > "${RESULTS}/a${att}/qualified.txt"
        # 实例身份（与 FULLBASELINE_V4.sh 的 jfs-instance 同格式）：pid + starttime + lstart
        { local ipid; ipid=$(jfs_pid_of_mnt)
          echo "pid=${ipid}"
          echo "starttime=$(awk '{print $22}' "/proc/${ipid}/stat" 2>/dev/null || echo NA)"
          echo "lstart=$(ps -o lstart= -p "${ipid}" 2>/dev/null || echo NA)"
        } > "${RESULTS}/a${att}/jfs-instance.txt" 2>/dev/null || true
        local rwvals=""
        local r=1
        while [ "${r}" -le "${R3_RW_REPEAT}" ]; do
            run_round "q${qid}-rw${r}" randrw "${RUNTIME}" rw_test
            local v; v=$(per_sec_mean "q${qid}-rw${r}" 15 175 all)
            rwvals="${rwvals}${v};"
            log "  q${qid}-rw${r}: 逐秒均值(读+写,15-175s)=${v} MiB/s"
            r=$((r + 1))
        done
        run_round "q${qid}-probe2" randread "${PROBE_RUNTIME}" read_test
        local p2; p2=$(per_sec_mean "q${qid}-probe2" "${PROBE_W_LO}" "${PROBE_W_HI}" r)
        log "  q${qid} 收尾探针=${p2}（对比开局 ${p1}）⇒ 判断档位在实例生命周期内是否漂移"
        echo -e "a${att}\t${p1}\ttop\tyes\tq${qid}\t${rwvals}\t${p2}" >> "${RESULTS}/r3-attempts.tsv"
    done
    log "=== R3 采集结束：${att} 次挂载 / ${qid} 个高档合格实例 ==="
    [ "${qid}" -ge 2 ] || log "🔴 合格实例不足 2 个，无法算 L3，请回报 r3-attempts.tsv"
}

# ---------- R4：写历史效应（randrw 塌陷是否可由 gc --compact 复位）2026-08-05 ----------
# 全程单实例（探针门控拿高档，拿不到则降级继续——R4 是同实例内对比）：
#   阶段 A：prep 已 gc --compact ⇒ probe → randrw ×R4_RW_BURST1 → probe
#   复位  ：juicefs gc --compact（计时 + 记 objects 变化）
#   阶段 B：probe → randrw ×R4_RW_BURST2 → probe
# 每一轮前后记 pool objects/stored，逐轮追加到 r4-rounds.tsv
r4_row() {   # r4_row 阶段 轮标签 值 说明
    echo -e "$1\t$2\t$3\t$4\t$(date '+%H:%M:%S')" >> "${RESULTS}/r4-rounds.tsv"
}
r4_rw_burst() {   # r4_rw_burst 阶段前缀 轮数
    local phase="$1" n="$2" i=1 v ps first="" ob="" ug="" drop=""
    while [ "${i}" -le "${n}" ]; do
        ps=$(pool_stat)
        r4_row "${phase}" "${phase}-rw${i}-before" "-" "${ps}"
        run_round "${phase}-rw${i}" randrw "${RUNTIME}" rw_test
        v=$(per_sec_mean "${phase}-rw${i}" 15 175 all)
        ps=$(pool_stat)
        log "  ${phase}-rw${i}: 逐秒均值(读+写,15-175s)=${v} MiB/s ｜ ${ps}"
        r4_row "${phase}" "${phase}-rw${i}" "${v}" "${ps}"
        i=$((i + 1))
        # ---- R5 早停：塌陷已充分 / objects 已越过目标 / 容量保护（阶段 A 才判）----
        if [ "${R4_EARLY_STOP}" = "1" ] && [ "${phase}" = "A" ] && [ "${i}" -le "${n}" ]; then
            case "${v}" in ''|NA|*[!0-9]*) v="" ;; esac
            if [ -n "${v}" ]; then
                [ -n "${first}" ] || first="${v}"
                drop=$(( (v - first) * 100 / first ))
                log "    [R5 早停判据] 相对首轮 ${first}: ${drop}%（阈值 -${R5_STOP_DROP}%）"
                if [ "${drop}" -le "-${R5_STOP_DROP}" ] 2>/dev/null; then
                    log "  ⏹ R5 早停：跌幅 ${drop}% 已达 -${R5_STOP_DROP}% ⇒ 塌陷充分，提前进复位段（已跑 $((i-1)) 轮）"
                    R4_BURST_STOP="drop${drop}"; break
                fi
            fi
            ob=$(echo "${ps}" | sed -n 's/.*objects=\([0-9]*\).*/\1/p')
            ug=$(echo "${ps}" | sed -n 's/.*used_gib=\([0-9]*\).*/\1/p')
            if [ -n "${ob}" ] && [ "${ob}" -gt "${R5_STOP_OBJ}" ] 2>/dev/null; then
                log "  ⏹ R5 早停：objects=${ob} 已越过 ${R5_STOP_OBJ}（R3 末态 6.30M）⇒ 进复位段（已跑 $((i-1)) 轮）"
                R4_BURST_STOP="obj${ob}"; break
            fi
            if [ -n "${ug}" ] && [ "${ug}" -gt "${R5_MAX_USED_GIB}" ] 2>/dev/null; then
                log "  ⏹ R5 硬停（容量保护）：used_gib=${ug} > ${R5_MAX_USED_GIB} ⇒ 立即进复位段（已跑 $((i-1)) 轮）"
                [ "$((i-1))" -ge 2 ] || log "  🔴 阶段A 只跑了 $((i-1)) 轮 ⇒ 无法算恢复率；请先扩容或调高 R5_MAX_USED_GIB 后重跑（precheck 会预估）"
                R4_BURST_STOP="used${ug}"; break
            fi
        fi
    done
}
r4_probe() {      # r4_probe 标签 → 打印探针值
    local label="$1" v
    run_round "${label}" randread "${PROBE_RUNTIME}" read_test
    v=$(per_sec_mean "${label}" "${PROBE_W_LO}" "${PROBE_W_HI}" r)
    log "  ${label}: 探针(randread ${PROBE_W_LO}-${PROBE_W_HI}s)=${v} MiB/s"
    r4_row "probe" "${label}" "${v}" "$(pool_stat)"
    R4_PROBE_LAST="${v}"
}
r4_main() {
    : > "${RESULTS}/r4-rounds.tsv"
    echo -e "phase\tlabel\tvalue\tnote\tts" >> "${RESULTS}/r4-rounds.tsv"
    R4_BURST_STOP="none"
    if [ "${MODE}" = "r5" ]; then
        log "=== R5 拐点定位：阶段A randrw ×最多${R4_RW_BURST1}（早停 -${R5_STOP_DROP}% 或 objects>${R5_STOP_OBJ}）→ gc --compact → 阶段B randrw ×${R4_RW_BURST2} ==="
        log "=== 依据 R4 阴性：objects 2.36M→4.39M 无塌陷（极差 2.4%）；R3 末态 6.30M 已跌至 1202 ⇒ 拐点在 4.4M-6.3M ==="
        log "=== 三问：①塌陷是否在更高 objects 处出现 ②出现后 compact 能否复位 ③若 objects>6.5M 仍不塌陷 ⇒ 写历史效应否证 ==="
    else
        log "=== R4 写历史效应：阶段A randrw ×${R4_RW_BURST1} → gc --compact → 阶段B randrw ×${R4_RW_BURST2} ==="
        log "=== 只问一件事：randrw 的塌陷能否被 gc --compact 复位（可逆 ⇒ randrw 基线口径 = 复位后第 1 轮）==="
    fi
    # ---- 探针门控：为可比性尽量拿高档实例，拿不到则降级继续 ----
    local att=0 gated=0 p1=NA
    while [ "${att}" -lt "${R4_MAX_ATTEMPTS}" ]; do
        att=$((att + 1))
        log "--- 挂载尝试 a${att}/${R4_MAX_ATTEMPTS}（为拿高档实例）：remount ---"
        remount_jfs
        mkdir -p "${RESULTS}/a${att}"
        collect_irq_affinity "${RESULTS}/a${att}/irq-affinity.txt"
        collect_placement "${RESULTS}/a${att}"
        r4_probe "a${att}-probe1"
        p1="${R4_PROBE_LAST}"
        case "${p1}" in ''|NA) ;; *)
            if [ "${p1}" -ge "${GEAR_LO}" ] 2>/dev/null && [ "${p1}" -le "${GEAR_HI}" ] 2>/dev/null; then
                gated=1; log "  ✓ a${att} 探针=${p1} 判为高档 ⇒ 本实例锁定为 R4 载体"; break
            fi ;;
        esac
        log "  ✗ a${att} 探针=${p1} 不在高档带 [${GEAR_LO},${GEAR_HI}]"
    done
    if [ "${gated}" != "1" ]; then
        log "  ⚠️ ${R4_MAX_ATTEMPTS} 次未抽到高档，降级用当前实例（探针=${p1}）继续 —— R4 是同实例内对比，档位只影响与 R3 的可比性"
    fi
    echo "gated=${gated} attempts=${att} probe1=${p1}" > "${RESULTS}/r4-carrier.txt"
    { local ipid; ipid=$(jfs_pid_of_mnt)
      echo "pid=${ipid}"
      echo "starttime=$(awk '{print $22}' "/proc/${ipid}/stat" 2>/dev/null || echo NA)"
      echo "lstart=$(ps -o lstart= -p "${ipid}" 2>/dev/null || echo NA)"
    } >> "${RESULTS}/r4-carrier.txt" 2>/dev/null || true
    # ---- 阶段 A：prep 里已做过一次 gc --compact，这里直接开始堆写历史 ----
    log "--- 阶段 A（起点：prep 的 gc --compact 之后）---"
    r4_rw_burst "A" "${R4_RW_BURST1}"
    r4_probe "A-probe2"
    # ---- 复位：gc --compact（本实验唯一新增写操作，已获授权）----
    local ob4 oaf t0 t1
    ob4=$(pool_stat)
    log "--- 复位：juicefs gc --compact（复位前 ${ob4}）---"
    t0=$(date +%s)
    set +e; juicefs gc --compact "${META}" > "${RESULTS}/gc-compact.txt" 2>&1; local grc=$?; set -e
    t1=$(date +%s)
    oaf=$(pool_stat)
    log "  gc --compact 完成 rc=${grc} 耗时 $((t1 - t0))s ｜ 复位后 ${oaf}"
    r4_row "compact" "gc-compact" "$((t1 - t0))s" "before[${ob4}] after[${oaf}] rc=${grc}"
    drop_caches
    # ---- 阶段 B：同一挂载实例内，看是否回升 ----
    log "--- 阶段 B（gc --compact 之后，同一挂载实例）---"
    r4_probe "B-probe1"
    r4_rw_burst "B" "${R4_RW_BURST2}"
    r4_probe "B-probe2"
    echo "burst_stop=${R4_BURST_STOP}" >> "${RESULTS}/r4-carrier.txt"
    log "=== ${MODE^^} 采集结束（阶段A 早停原因=${R4_BURST_STOP}）==="
}


# ---------- precheck：正式跑之前的环境自检（1 分钟，避免 1.1h 的跑白费）----------
# 2026-08-05 加：本脚本曾因"函数定义晚于调用"在第 69 行 command not found 直接退出，
# 单靠 bash -n 查不出这类问题，故加一个真实执行早期全路径的自检模式。
precheck() {
    local fail=0
    log "=== PRECHECK 开始（不跑正式测试）==="

    log "--- 1) 外部命令"
    for c in fio juicefs python3 mpstat ss taskset mountpoint pgrep stat tr awk md5sum; do
        if command -v "${c}" >/dev/null 2>&1; then log "  ✅ ${c}"; else log "  🔴 缺 ${c}"; fail=1; fi
    done

    log "--- 2) 本脚本内部函数是否都可调用"
    for f in jfs_pid_of_mnt drop_caches graceful_umount_jfs remount_jfs collect_irq_affinity \
             irq_snapshot thread_numa ss_snapshot mpstat_snapshot sampler pg_check \
             collect_placement run_round safety_check kill_guard \
             per_sec_mean count_glob purge_bw_log_dir pool_stat r3_main r4_main r4_row r4_rw_burst r4_probe; do
        if declare -F "${f}" >/dev/null 2>&1; then log "  ✅ ${f}()"; else log "  🔴 未定义 ${f}()"; fail=1; fi
    done

    log "--- 2b) R4/R5 参数与容量余量"
    log "  R4_RW_BURST1=${R4_RW_BURST1} R4_RW_BURST2=${R4_RW_BURST2} EARLY_STOP=${R4_EARLY_STOP}"
    log "  R5: BURST1=${R5_RW_BURST1} STOP_DROP=${R5_STOP_DROP}% STOP_OBJ=${R5_STOP_OBJ} MAX_USED_GIB=${R5_MAX_USED_GIB}"
    local pstat; pstat=$(pool_stat)
    log "  当前池状态: ${pstat}"
    local cur_ug; cur_ug=$(echo "${pstat}" | sed -n 's/.*used_gib=\([0-9]*\).*/\1/p')
    if [ -n "${cur_ug}" ]; then
        local need=$(( cur_ug + R5_RW_BURST1 * 320 ))
        log "  R5 阶段A 最坏用量估算: ${cur_ug} + ${R5_RW_BURST1}×320 ≈ ${need} GiB（硬停阈值 ${R5_MAX_USED_GIB}）"
        if [ "${need}" -gt "${R5_MAX_USED_GIB}" ]; then
            log "  ⚠️ 估算超硬停阈值 ⇒ 会触发容量早停（不是错误，但阶段A 可能跑不满 ${R5_RW_BURST1} 轮）"
        else
            log "  ✅ 容量余量够跑满阶段A"
        fi
    fi

    log "--- 3) kill_guard 反例（必须全部 REFUSE）"
    for bad in "" "abc" "1" "999999"; do
        if kill_guard "${bad}" 2>/dev/null; then log "  🔴 kill_guard 误放行 '${bad}'"; fail=1; else log "  ✅ 拒绝 '${bad}'"; fi
    done

    log "--- 4) 挂载与测试文件"
    if mount | grep -q juice; then log "  ✅ juicefs 已挂载"; else log "  ⚠️ 未挂载（prep 会挂）"; fi
    local pid; pid=$(jfs_pid_of_mnt)
    log "  juicefs pid=${pid:-无}"
    local nf; nf=$(count_glob "${TEST_DIR}/read_test.*.0")
    log "  read_test 文件数=${nf}"
    [ "${nf}" -ge 1 ] 2>/dev/null || { log "  🔴 找不到 read_test.*.0，无法只读测试"; fail=1; }
    local nw; nw=$(count_glob "${TEST_DIR}/rw_test.*.0")
    log "  rw_test 文件数=${nw}（R3/R4 的 randrw 用；R2 只读不需要）"
    [ "${nw}" -ge 1 ] 2>/dev/null || log "  ⚠️ 找不到 rw_test.*.0 ⇒ 只能跑 R2，R3/R4 会现场创建文件（耗时+污染写历史）"
    log "  池状态: $(pool_stat)"

    log "--- 5) IRQ 只读采集"
    collect_irq_affinity "${RESULTS}/precheck-irq-affinity.txt"
    local nq; nq=$(grep -c '^[0-9]' "${RESULTS}/precheck-irq-affinity.txt" 2>/dev/null || echo 0)
    [ "${nq}" -ge 1 ] 2>/dev/null && log "  ✅ 队列数=${nq}" || { log "  🔴 ${STORE_IF} 队列读不到"; fail=1; }
    irq_snapshot | head -2 | while read -r l; do log "  中断计数样例: ${l}"; done

    log "--- 6) 采样函数各跑一次"
    log "  threads: $(thread_numa "${pid}")"
    log "  mpstat:  $(mpstat_snapshot | head -c 200)"
    log "  ss 行数: $(ss_snapshot "${pid}" | wc -l)"

    log "--- 7) fio 冒烟（只读 5s / 4 jobs，不落正式数据）"
    local sm="${RESULTS}/precheck-fio"
    mkdir -p "${sm}"
    set +e
    timeout 90 fio --directory="${TEST_DIR}" --name=read_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=8 --numjobs=4 \
        --direct=1 --fallocate=none --openfiles=4 \
        --group_reporting --time_based --runtime=5 \
        > "${sm}/fio.txt" 2>&1
    local rc=$?
    set -e
    if [ "${rc}" = "0" ]; then
        log "  ✅ fio 冒烟通过：$(grep -oE 'bw=[0-9.]+[KMG]iB/s' "${sm}/fio.txt" | head -1)"
    else
        log "  🔴 fio 冒烟失败 rc=${rc}：$(tail -3 "${sm}/fio.txt" | tr '\n' ' ')"; fail=1
    fi

    if [ "${fail}" = "0" ]; then
        log "=== PRECHECK=OK  可以正式跑：R5 拐点定位 → bash $0 r5 ；R4 写历史 → bash $0 r4 ；R3 档位甄别 → bash $0 r3 5 ；R2 机制归因 → bash $0 12 ==="
        return 0
    else
        log "=== PRECHECK=FAIL  修好再跑，不要开正式跑 ==="
        return 1
    fi
}

# ================= 主流程 =================
log "============================================"
if [ "${MODE}" = "r3" ]; then
    log "=== R3 档位甄别协议验证 mode=r3 目标 ${NGROUPS} 个高档实例 ==="
    log "=== 目的：不依赖机制归因，用探针筛掉低档实例，拿到 L3 ≤5% 的可签收基线 ==="
    log "=== 会写数据：randrw 读写 rw_test.*.0（与 V4 item_randrw 同一批文件）；不改 ceph 配置/IRQ/RPS ==="
elif [ "${MODE}" = "r5" ]; then
    log "=== R5 拐点定位 mode=r5：阶段A randrw ×最多${R4_RW_BURST1}（早停 -${R5_STOP_DROP}% / objects>${R5_STOP_OBJ}）→ gc --compact → 阶段B randrw ×${R4_RW_BURST2} ==="
    log "=== 依据 R4 阴性：objects 2.36M→4.39M 跨 5 轮极差仅 2.4%，塌陷未复现；R3 末态 6.30M 已跌至 1202 ==="
    log "=== 会写数据：randrw 写 rw_test.*.0（阶段A 最多 ${R4_RW_BURST1} 轮 ≈ $((R4_RW_BURST1 * 211)) GiB）；会做 juicefs gc --compact（已授权）；不改 ceph 配置/IRQ/RPS/pg_num ==="
elif [ "${MODE}" = "r4" ]; then
    log "=== R4 写历史效应 mode=r4：阶段A randrw ×${R4_RW_BURST1} → gc --compact → 阶段B randrw ×${R4_RW_BURST2} ==="
    log "=== 依据 R3 复核：r(randrw, 累计写入)=-0.951，一小时内 randrw -48% 而高档 randread 只 -7% ==="
    log "=== 会写数据：randrw 写 rw_test.*.0；会做 juicefs gc --compact（已授权）；不改 ceph 配置/IRQ/RPS/pg_num ==="
else
    log "=== R2 挂载档位机制归因 mode=${MODE} ${NGROUPS} 组 × 1 轮 runtime=${RUNTIME}s ==="
    log "=== 主假设：RSS 把连接哈希到 IRQ 钉在 core 1-16（外部租户占满）的队列 ==="
    log "=== 只读：仅 randread(read_test.*)；不改 ceph 配置/IRQ 亲和性/RPS ==="
fi
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo ERROR)
log "ceph health: ${HEALTH}"
echo "${HEALTH}" | grep -qE 'HEALTH_OK|clock skew' || { log "FATAL: health=${HEALTH}"; exit 1; }
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
[ "${OSD_UP}" = "6" ] || { log "FATAL: OSD up=${OSD_UP} != 6"; exit 1; }
pg_check
log "存储出口网卡: ${STORE_IF}（$(ip route get 10.20.1.150 2>/dev/null | head -1 | grep -oE 'dev [^ ]+' || echo NA)）"
collect_irq_affinity

if [ "${MODE}" = "precheck" ]; then
    precheck; rc=$?
    log "=== PRECHECK 结束 rc=${rc}（未跑正式测试，未产生 g* 数据）==="
    exit "${rc}"
fi

# prep：与正常运行的起点同构
log "=== prep（一次性）==="
log "  juicefs gc --compact"
set +e; juicefs gc --compact "${META}" 2>&1 | tail -2; set -e
drop_caches
remount_jfs
log "  warmup: 顺序读 read_test 全部文件"
cnt=0
for f in ${TEST_DIR}/read_test.*.0; do [ -f "$f" ] || continue; dd if="$f" of=/dev/null bs=4M 2>/dev/null; cnt=$((cnt+1)); done
log "  warmup done: ${cnt} files"
drop_caches
case "${MODE}" in r4|r5) log "  prep 后池状态: $(pool_stat)" ;; esac

if [ "${MODE}" = "r4" ] || [ "${MODE}" = "r5" ]; then
    r4_main
    log "=== ${MODE^^} 分析（口径：randrw 逐秒均值 15-175s；探针 randread ${PROBE_W_LO}-${PROBE_W_HI}s）==="
    python3 - "${RESULTS}" "${R4_RECOVER_OK}" "${R4_RECOVER_PART}" "${MODE}" "${R5_STOP_OBJ}" <<'PYR4' 2>&1 | while read -r l; do log "$l"; done || true
import sys, os, csv, glob, re
R, OKV, PARTV = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
MODE   = sys.argv[4] if len(sys.argv) > 4 else "r4"
STOPOB = int(sys.argv[5]) if len(sys.argv) > 5 else 7000000
rows = list(csv.DictReader(open(os.path.join(R, "r4-rounds.tsv")), delimiter="\t"))

def num(s):
    try: return float(s)
    except Exception: return None

def objs(note):
    m = re.search(r"objects=(\d+)", note or "")
    return int(m.group(1)) if m else None

def written_gib(label):
    """该轮实际写入量（fio 汇总 WRITE bw × runtime）"""
    p = os.path.join(R, label, "fio.txt")
    if not os.path.exists(p): return 0.0
    t = open(p, errors="ignore").read()
    m = re.search(r"WRITE: bw=([0-9.]+)MiB/s", t)
    r = re.search(r"run=(\d+)-", t)
    if not m: return 0.0
    ms = int(r.group(1)) if r else 180000
    return float(m.group(1)) * (ms / 1000.0) / 1024.0

rw   = [r for r in rows if re.match(r"^[AB]-rw\d+$", r["label"])]
pre_note = {r["label"][:-7]: r["note"] for r in rows if r["label"].endswith("-before")}
prb  = [r for r in rows if r["phase"] == "probe"]
comp = [r for r in rows if r["phase"] == "compact"]

print("轮次表（randrw 逐秒均值 + 该轮前累计写入 + 池对象数 + 相对本阶段首轮）:")
print("%-12s %-9s %-9s %-14s %-12s %-11s %-9s" % (
    "轮", "randrw", "vs首轮%", "该轮前累计写GiB", "轮前objects", "轮后objects", "时刻"))
cum = 0.0
firsts = {}
knee = []
for r in rw:
    ph = r["label"][0]
    v = num(r["value"])
    if v and ph not in firsts:
        firsts[ph] = v
    rel = "%+.1f%%" % ((v / firsts[ph] - 1) * 100) if (v and firsts.get(ph)) else "NA"
    ob_pre = objs(pre_note.get(r["label"], ""))
    ob_post = objs(r["note"])
    print("%-12s %-9s %-9s %-14.0f %-12s %-11s %-9s" % (
        r["label"], r["value"], rel, cum, ob_pre or "NA", ob_post or "NA", r["ts"]))
    if v and ob_pre:
        knee.append((r["label"], v, ob_pre, cum))
    cum += written_gib(r["label"])
print("")

# ---- 拐点表（R5 主产物）：把 randrw 值对"轮前池对象数"排序，看退化从哪个 objects 开始 ----
if MODE == "r5" and len(knee) >= 4:
    print("拐点表（按轮前 objects 递增；基准 = 阶段A 首轮）:")
    base = knee[0][1]
    print("  %-12s %-11s %-9s %-9s %-9s" % ("轮", "轮前objects", "randrw", "vsA首轮", "累计写GiB"))
    for lb, v, ob, cw in knee:
        print("  %-12s %-11d %-9.0f %-9s %-9.0f" % (lb, ob, v, "%+.1f%%" % ((v / base - 1) * 100), cw))
    degr = [(lb, v, ob) for lb, v, ob in [(k[0], k[1], k[2]) for k in knee] if v / base - 1 <= -0.05]
    if degr:
        print("  ⇒ 首个跌破 -5%% 的轮次: %s（轮前 objects=%d, %.0f MiB/s）" % (degr[0][0], degr[0][2], degr[0][1]))
        print("  ⇒ 拐点区间: objects ∈ (%d, %d]" % (
            max([k[2] for k in knee if k[2] < degr[0][2]] or [0]), degr[0][2]))
    else:
        print("  ⇒ 全程未跌破 -5%%，最高轮前 objects=%d ⇒ 该区间内不存在拐点" % max(k[2] for k in knee))
    print("")
print("探针表（randread，看读路径是否同步退化）:")
for r in prb:
    print("  %-12s %-8s %s" % (r["label"], r["value"], r["note"]))
print("")
for r in comp:
    print("gc --compact: 耗时=%s  %s" % (r["value"], r["note"]))
    ob = re.search(r"before\[objects=(\d+)", r["note"] or "")
    oa = re.search(r"after\[objects=(\d+)",  r["note"] or "")
    if ob and oa:
        b, a = int(ob.group(1)), int(oa.group(1))
        print("  池对象数 %d → %d（%+.1f%%）" % (b, a, (a / b - 1) * 100 if b else 0))
print("")
A = [num(r["value"]) for r in rw if r["label"].startswith("A-") and num(r["value"])]
B = [num(r["value"]) for r in rw if r["label"].startswith("B-") and num(r["value"])]
if len(A) >= 2 and B:
    a1, aN, b1 = A[0], A[-1], B[0]
    drop = (aN / a1 - 1) * 100
    print("阶段A 塌陷: 首轮 %.0f → 末轮 %.0f（%+.1f%%）" % (a1, aN, drop))
    print("阶段B 首轮（compact 复位后）: %.0f" % b1)
    if abs(a1 - aN) < 1e-6:
        print("⚠️ 阶段A 未出现塌陷（首末轮相等）⇒ 本次未复现 R3 现象，需加长 burst 或查是否有他人负载变化")
    else:
        rec = (b1 - aN) / (a1 - aN) * 100
        print("恢复率 = (B首轮 − A末轮) / (A首轮 − A末轮) = %.0f%%" % rec)
        if drop > -3:
            obmax = max([k[2] for k in knee] + [objs(r["note"]) or 0 for r in rw])
            print("⚠️ 阶段A 塌陷仅 %.1f%%（<3%%）⇒ 现象未复现，恢复率无意义" % drop)
            if MODE == "r5" and obmax >= STOPOB * 0.9:
                print("🔵 出口4 写历史效应否证：objects 已推到 %d（≥R3 末态 6.30M）仍无塌陷" % obmax)
                print("   ⇒ R3 的 -48% 不能归因于累计写入/池碎片，改归外部租户负载与时段（r(时间)=-0.952 是真凶）")
                print("   ⇒ randrw 基线 = 单实例内多轮均值（R4 实测极差 2.4%），调优必须同实例 ABBA + 随机化轮序")
            else:
                print("   本次结论：不可判（最高 objects=%d，未达早停阈值 %d）" % (obmax, STOPOB))
        elif rec >= OKV:
            print("✅ 出口1 可逆（恢复率 ≥%.0f%%）⇒ randrw 塌陷源于可回收的写历史（碎片/垃圾）" % OKV)
            print("   ⇒ randrw 基线口径 = 'gc --compact 复位后第 1 轮'；调优每轮前必须复位；randrw 可签收")
            print("   ⇒ 并按上方拐点表设 objects 上限：每次 compact 后最多跑到拐点前一轮，超限即作废重测")
        elif rec >= PARTV:
            print("🟡 出口2 部分可逆（恢复率 %.0f%%，在 %.0f-%.0f%% 之间）⇒ 复位只回收一部分" % (rec, PARTV, OKV))
            print("   ⇒ randrw 基线取 '复位后第 1 轮' 且必须同实例 ABBA 配对；跨天绝对值不可比")
        else:
            print("🔴 出口3 不可逆（恢复率 %.0f%% < %.0f%%）⇒ 塌陷不在 JuiceFS 垃圾层，疑 OSD 侧（onode/RocksDB）" % (rec, PARTV))
            print("   ⇒ randrw 绝对值永不签收；只能同实例 ABBA 配对 + 线性去趋势；下一步查 bluestore onode/omap 与 pg_num=32")
else:
    print("🔴 数据不足（A=%d 轮 B=%d 轮），无法算恢复率，请回报 r4-rounds.tsv" % (len(A), len(B)))
# 探针对照
pv = [(r["label"], num(r["value"])) for r in prb if num(r["value"])]
if len(pv) >= 2:
    vs = [v for _, v in pv]
    print("")
    print("randread 对照: %s ⇒ 极差 %.1f%%（randrw 塌陷若远大于此，则塌陷是写路径专属）" % (
        " ".join("%s=%.0f" % (k, v) for k, v in pv), (max(vs) / min(vs) - 1) * 100))
PYR4
    log "=== ${MODE^^} 结束：原始数据 ${RESULTS}（r4-rounds.tsv / r4-carrier.txt / gc-compact.txt）==="
    exit 0
fi

if [ "${MODE}" = "r3" ]; then
    r3_main
    log "=== R3 分析（验收口径：逐秒均值；探针窗口 ${PROBE_W_LO}-${PROBE_W_HI}s，randrw 窗口 15-175s）==="
    python3 - "${RESULTS}" "${GEAR_LO}" "${GEAR_HI}" <<'PYR3' 2>&1 | while read -r l; do log "$l"; done || true
import sys, os, csv, statistics
R, lo, hi = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rows = list(csv.DictReader(open(os.path.join(R, "r3-attempts.tsv")), delimiter="\t"))
print("尝试表（挂载尝试 → 探针判档 → 合格实例 randrw）:")
print("%-6s %-8s %-9s %-6s %-24s %-8s" % ("尝试", "探针1", "判档", "合格", "randrw逐秒均值", "探针2"))
for r in rows:
    print("%-6s %-8s %-9s %-6s %-24s %-8s" % (r["attempt"], r["probe1"], r["gear"], r["qualified"], r["rw_values"], r["probe2"]))
q = [r for r in rows if r["qualified"] == "yes"]
print("")
print("命中率: 高档 %d / 总挂载 %d = %.0f%%（R1+R2 先验 55%%）" % (len(q), len(rows), 100.0*len(q)/max(1,len(rows))))
# 探针漂移
dr = [(r["qid"], float(r["probe1"]), float(r["probe2"])) for r in q
      if r["probe2"] not in ("-", "NA", "")]
if dr:
    print("档位漂移（同实例 开局探针 vs 收尾探针，间隔约 %d min）:" % 7)
    for qid, a, b in dr:
        print("  %-4s %6.0f → %6.0f  (%+.1f%%)" % (qid, a, b, (b-a)/a*100))
    mx = max(abs(b-a)/a*100 for _, a, b in dr)
    print("  最大漂移 %.1f%% ⇒ %s" % (mx, "档位在实例内稳定（探针可信）" if mx <= 3 else "🔴 档位在实例内会漂移，探针甄别不成立"))
# L2 / L3
allrw = []
print("")
print("randrw 结果:")
for r in q:
    vs = [float(x) for x in r["rw_values"].strip(";").split(";") if x not in ("", "NA")]
    if not vs: continue
    spread = (max(vs)-min(vs))/statistics.median(vs)*100 if len(vs) > 1 else 0.0
    print("  %-4s 轮值=%s  轮间极差=%.1f%% %s" % (r["qid"], "/".join("%.0f" % v for v in vs), spread,
          "OK" if spread <= 5 else "🔴FAIL"))
    allrw.append(statistics.median(vs))
if len(allrw) >= 2:
    med = statistics.median(allrw)
    dev = max(abs(v-med)/med*100 for v in allrw)
    rng = (max(allrw)-min(allrw))/med*100
    print("")
    print("L3（跨高档实例）: n=%d median=%.0f range=%.0f-%.0f 极差幅度=%.1f%% 最大偏差=%.1f%%"
          % (len(allrw), med, min(allrw), max(allrw), rng, dev))
    if dev <= 5:
        print("判定: ✅ L3 ≤5%% 达成 ⇒ 档位甄别协议成立，基线可签收，汇报值 randrw=%.0f MiB/s" % med)
    elif dev <= 10:
        print("判定: ⚠️ L3 在 5-10%%（%.1f%%）⇒ 按放宽门限签收，汇报值 randrw=%.0f MiB/s，调优必须用同实例 A-B-A" % (dev, med))
    else:
        print("判定: 🔴 L3 >10%%（%.1f%%）⇒ 探针甄别不足以稳定 randrw，改用探针归一化比值法" % dev)
else:
    print("🔴 合格实例 <2，无法算 L3")
PYR3
    guard_report 2>/dev/null || true
    log "=== R3 结束 ==="
    exit 0
fi

for g in $(seq 1 "${NGROUPS}"); do
    log "=== 组 g${g}/${NGROUPS}：remount（不绑核，保持自然抽签）==="
    remount_jfs
    mkdir -p "${RESULTS}/g${g}"
    collect_irq_affinity "${RESULTS}/g${g}/irq-affinity.txt"
    collect_placement "${RESULTS}/g${g}"
    log "  卸载方式=${UMOUNT_MODE:-none}  挂载态已记录 g${g}/placement.txt"
    run_round "g${g}-r1"
    mv "${RESULTS}/g${g}-r1"/irq-t*.txt "${RESULTS}/g${g}/" 2>/dev/null || true
    mv "${RESULTS}/g${g}-r1"/sampling*.txt "${RESULTS}/g${g}/" 2>/dev/null || true
done

# ================= 分析 =================
log "=== 分析（验收口径：逐秒均值 15-175s）==="
python3 - "${RESULTS}" <<'PYEOF' 2>&1 | while read -r l; do log "$l"; done || true
import os, sys, glob, re, statistics
from collections import defaultdict

# 结果目录由外层用 argv 传入（勿硬编码，否则与 RESULTS 变量重复定义会不一致）
R = sys.argv[1] if len(sys.argv) > 1 else "/tmp/r2-mount-gear-attrib"

# ---- IRQ → 核 / 是否饥饿核 ----
# 157 上 irqbalance active ⇒ 映射会漂移，优先用**该组自己**的快照，缺失才回退全局
def load_affinity(path):
    core, st = {}, set()
    if os.path.exists(path):
        for line in open(path):
            f = line.split()
            if len(f) < 4 or not f[0].isdigit():
                continue
            core[f[0]] = f[1]
            if f[3] == "1":
                st.add(f[0])
    return core, st

irq_core, starved = load_affinity(os.path.join(R, "irq-affinity.txt"))

def per_sec_mean(sub):
    per = defaultdict(float)
    # ⚑ 只认本目录同名 label 的前缀（目录 g1-r1 → g1-r1_bw.*.log）。
    #    用 *_bw.*.log 通配会把跨跑残留日志一起加总（R2 g1 被算成 2162，真值 1886）。
    label = os.path.basename(sub.rstrip("/"))
    pat = os.path.join(sub, label + "_bw.*.log")
    files = glob.glob(pat)
    stray = [f for f in glob.glob(os.path.join(sub, "*_bw.*.log")) if f not in files]
    if stray:
        print("  🔴 %s 有 %d 个非本轮 bw log（已忽略）: %s" % (label, len(stray), os.path.basename(stray[0])))
    for f in files:
        for line in open(f):
            q = line.strip().split(",")
            if len(q) < 3:
                continue
            try:
                s = int(q[0]) // 1000; bw = float(q[1]); d = int(q[2])
            except ValueError:
                continue
            if d == 0:
                per[s] += bw
    if not per:
        return None
    ks = sorted(per); t0 = ks[0]
    w = [per[k] / 1024.0 for k in ks if 15 <= k - t0 <= 175]
    return statistics.mean(w) if w else None

def snap(f):
    d = {}
    if os.path.exists(f):
        for line in open(f):
            q = line.split()
            if len(q) == 2 and q[0].isdigit():
                d[q[0]] = int(q[1])
    return d

def irq_delta(gdir):
    a = snap(os.path.join(gdir, "irq-t0.txt"))
    b = snap(os.path.join(gdir, "irq-tend.txt"))
    if not a or not b:
        return None
    return {k: b[k] - a.get(k, 0) for k in b if b[k] - a.get(k, 0) > 0}

def numa_of_threads(gdir):
    f = os.path.join(gdir, "sampling.txt")
    n0 = n1 = 0
    if os.path.exists(f):
        for line in open(f):
            m = re.search(r"node0=(\d+) node1=(\d+)", line)
            if m:
                n0 += int(m.group(1)); n1 += int(m.group(2))
    tot = n0 + n1
    return (100.0 * n1 / tot) if tot else None

rows = []
for g in range(1, 40):
    gdir = os.path.join(R, "g%d" % g)
    sub = os.path.join(R, "g%d-r1" % g)
    if not os.path.isdir(sub):
        continue
    if os.path.exists(os.path.join(sub, "INVALID.txt")):
        continue
    bw = per_sec_mean(sub)
    if bw is None:
        continue
    g_core, g_starved = load_affinity(os.path.join(gdir, "irq-affinity.txt"))
    if not g_core:
        g_core, g_starved = irq_core, starved
    d = irq_delta(gdir) or {}
    tot = sum(d.values())
    st = sum(v for k, v in d.items() if k in g_starved)
    share = 100.0 * st / tot if tot else None
    # "活跃队列" = 中断增量 >= 该组均值的一半（119 队列均分时每个约 0.84%，不能用固定 1% 阈值）
    thr = 0.5 * tot / len(d) if d else 0
    active = sum(1 for v in d.values() if v >= thr)
    act_starved = sum(1 for k, v in d.items() if k in g_starved and v >= thr)
    top = sorted(d.items(), key=lambda kv: -kv[1])[:5]
    top_s = " ".join("irq%s(c%s%s)=%.1f%%" % (
        k, g_core.get(k, "?"), "*" if k in g_starved else "", 100.0 * v / tot if tot else 0) for k, v in top)
    rows.append((g, bw, share, active, act_starved, numa_of_threads(gdir), top_s, len(g_starved)))

print("组   逐秒均值   饥饿队列中断占比   活跃队列数  其中饥饿  线程node1占比  本组饥饿队列数")
for g, bw, share, active, acts, n1, top_s, nst in rows:
    print("g%-3d %8.0f %14s %12d %9d %13s %13d" % (
        g, bw,
        "%.2f%%" % share if share is not None else "NA",
        active, acts,
        "%.0f%%" % n1 if n1 is not None else "NA", nst))
print("")
print("各组中断量 top5 队列（c=绑定核，* = 落在被外部租户占满的 core 1-16）：")
for r_ in rows:
    print("  g%-3d %s" % (r_[0], r_[6]))

if len(rows) >= 4:
    bws = [r[1] for r in rows]
    med = statistics.median(bws)
    rng = (max(bws) - min(bws)) / med * 100
    print("")
    print("组间: n=%d median=%.0f 极差幅度=%.1f%% range=%.0f-%.0f" % (len(bws), med, rng, min(bws), max(bws)))
    print("饥饿核队列数=%d / 总队列数=%d" % (len(starved), len(irq_core)))

    have = [r for r in rows if r[2] is not None]
    if len(have) >= 4:
        lo = [r for r in have if r[1] < med]
        hi = [r for r in have if r[1] >= med]
        sl = statistics.mean([r[2] for r in lo]) if lo else 0.0
        sh = statistics.mean([r[2] for r in hi]) if hi else 0.0
        # Pearson r（BW vs 饥饿占比）
        xs = [r[2] for r in have]; ys = [r[1] for r in have]
        mx = statistics.mean(xs); my = statistics.mean(ys)
        num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        den = (sum((x - mx) ** 2 for x in xs) * sum((y - my) ** 2 for y in ys)) ** 0.5
        r_p = num / den if den else 0.0
        print("低档组(<median) 饥饿占比均值=%.2f%%  高档组 饥饿占比均值=%.2f%%  Pearson r(BW,饥饿占比)=%.2f"
              % (sl, sh, r_p))
        print("")
        if rng <= 5:
            print("判定: 本次 12 组未复现多档（极差 %.1f%% ≤5%%）⇒ R1 的分散可能含当日外部租户瞬态，需重复 R1" % rng)
        elif r_p <= -0.6 and sl > sh:
            print("判定: 机制定案 —— RSS/IRQ 饥饿（r=%.2f，低档组饥饿占比 %.2f%% > 高档组 %.2f%%，负相关且有剂量关系）"
                  % (r_p, sl, sh))
            print("      解法候选（按侵入性从低到高，均需另行授权）：")
            print("      ① 开 RPS：把收包软中断从饥饿核搬到空闲核（rx-*/rps_cpus，可回滚、不影响其他租户）")
            print("      ② 迁 IRQ 亲和：把那 %d 个队列的 IRQ 从 core 1-16 移到 core>=17（/proc/irq/*/smp_affinity_list）" % len(starved))
            print("      ③ 减少 RSS 队列数至只覆盖空闲核（ethtool -L / -X，侵入最大）")
        elif sl > sh:
            print("判定: 方向一致但相关性弱（r=%.2f）⇒ 饥饿队列是部分因素，另有共因；看 sampling.txt 的 %%soft 与 ss rtt" % r_p)
        else:
            print("判定: 与饥饿队列无关（r=%.2f）⇒ 转候选：线程落核/内存首触 NUMA、Go runtime 一次性初始化" % r_p)
            print("      下一手：对照 线程node1占比 与档位；并看 sampling-ss.txt 中低档组是否存在个别高 rtt/低 cwnd 连接")

# ---- 守卫 ----
nu = 1 if os.path.exists(os.path.join(R, "UNCLEAN_UMOUNT.txt")) else 0
md5 = set(open(f).read().strip() for f in glob.glob(os.path.join(R, "g*-r1", "config-md5.txt")))
uf = set(open(f).read().strip() for f in glob.glob(os.path.join(R, "g*-r1", "up_from.txt")))
inv = len(glob.glob(os.path.join(R, "g*-r1", "INVALID.txt")))
ok = (nu == 0 and len(md5) <= 1 and len(uf) <= 1 and inv == 0)
print("")
print("GUARD: 非优雅卸载=%d  config-md5种类=%d  up_from种类=%d  INVALID轮=%d  %s"
      % (nu, len(md5), len(uf), inv, "OK" if ok else "FAIL"))
PYEOF

log "=== R2 完成，结果目录 ${RESULTS} ==="
