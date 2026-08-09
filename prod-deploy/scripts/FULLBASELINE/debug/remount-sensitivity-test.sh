#!/bin/bash
set -euo pipefail
export LC_ALL=C

# remount-sensitivity-test.sh — R1：remount 敏感性（归因实验，非基线、非调优）
#
# 目的：判定 S3→S4 的跨运行整档跃迁（randread +8.0%、randrw +4.3%）是否由
#       "每次运行都会换一个新的 JuiceFS 进程"（落核 / NUMA / 一次性初始化）造成。
#
# 事实依据：
#   - reset_state() 内无条件 remount，且只在 prep 执行一次 ⇒ 运行内 10 轮共用同一进程
#   - 实测：运行内 p50 完全平坦（S3 1690-1713 / S4 1828-1860），运行间整档跃迁
#   - jfs-stats 证明 S4 是全新进程（cpu_usage 1182s vs 1163s，非累加）
#   - PG/config-md5/up_from/load/c_amp/命中率 全部相同 ⇒ 差异不在集群侧
#   - 157 的 core 1-16 被外部租户 100% 占满 ⇒ 落核不同足以造成 8%
#
# 设计：池状态固定，只跑 randread（读 read_test.*，永不被写覆盖），
#       连续 6 组，每组"优雅 remount → 采集落核 → 2 轮 randread"，判档用第 2 轮。
#
# 只读性质：不写测试数据、不改 ceph 配置、不动 pg_autoscale、不重启任何服务。
#           唯一的写操作是 juicefs umount/mount 与 drop_caches（已获授权）。
#
# 判定：
#   6 组组间极差 ≤5%                  ⇒ 单档收敛：排除进程级，档位由池侧状态决定（"弃首运行"规则成立）
#   出现两簇且簇间差 ≥5%              ⇒ 双档：与落核对照，若相关则解 = numactl/taskset 绑核
#   随组序单调                        ⇒ 漂移：转 OSD 侧采集，另立实验
#
# 用法：bash remount-sensitivity-test.sh [NGROUPS] [ROUNDS_PER_GROUP]
#       默认 6 组 × 2 轮，耗时 ≈ prep 11min + 6×(remount 1min + 2×3.3min) ≈ 1h
#
# 用完即弃：结论写入报告后删除本文件，不并入 FULLBASELINE_V4.sh
#           （若结论是"要绑核"，只把 numactl/taskset 加进 V4 的挂载命令）

META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS="/tmp/r1-remount-sensitivity"
POOL_DATA="juicefs-data"
NIC_IF="${NIC_IF:-bond0}"
JUICEFS_MOUNT_OPTS="${JUICEFS_MOUNT_OPTS:---max-uploads 150 --cache-size 0}"

NGROUPS="${1:-6}"
ROUNDS_PER_GROUP="${2:-2}"
RUNTIME=180
LAYOUT_JOBS=128
LAYOUT_SIZE="1G"
PG_NUM_EXPECT="${PG_NUM_EXPECT:-32}"

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
# ⚑ 2026-08-05：启动即清空残留 bw log（被 kill 的上一次跑会污染本次第一组，R2 g1 教训）
rm -f "${BW_LOG_DIR}"/*_bw.*.log 2>/dev/null || true
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS}/r1.log"; }

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

# ---------- 落核 / CPU 争抢采集（本实验的核心自变量）----------
collect_placement() {
    local outdir="$1"
    local pid; pid=$(jfs_pid_of_mnt)
    {
        echo "ts=$(date +%s) $(date '+%F %T')"
        echo "umount_mode=${UMOUNT_MODE:-none}"
        echo "pid=${pid:-NA}"
        echo "--- taskset (进程级亲和性)"
        [ -n "${pid}" ] && taskset -cp "${pid}" 2>/dev/null || echo "NA"
        echo "--- 线程数 / 线程当前所在 CPU 直方图 (stat 第39字段)"
        if [ -n "${pid}" ]; then
            ls /proc/${pid}/task 2>/dev/null | wc -l
            for t in /proc/${pid}/task/*/stat; do awk '{print $39}' "$t" 2>/dev/null; done \
                | sort -n | uniq -c | sort -rn | head -24
        fi
        echo "--- VmRSS / Threads"
        [ -n "${pid}" ] && grep -E 'VmRSS|Threads' /proc/${pid}/status 2>/dev/null || true
        echo "--- uptime"
        uptime
        echo "--- per-core 利用率（外部租户占用情况）"
        if command -v mpstat >/dev/null 2>&1; then
            mpstat -P ALL 1 5 2>/dev/null | tail -n +4
        else
            echo "(mpstat 不可用，用 /proc/stat 5s 差分)"
            awk '/^cpu[0-9]/{print $1,$2,$3,$4,$5}' /proc/stat > /tmp/r1_stat_a
            sleep 5
            awk '/^cpu[0-9]/{print $1,$2,$3,$4,$5}' /proc/stat > /tmp/r1_stat_b
            join /tmp/r1_stat_a /tmp/r1_stat_b | awk '{
                du=$6-$2; dn=$7-$3; ds=$8-$4; di=$9-$5; tot=du+dn+ds+di;
                if (tot>0) printf "%s busy=%.1f%%\n", $1, 100.0*(du+dn+ds)/tot }' | sort -t= -k2 -rn | head -24
        fi
        echo "--- mount 行"
        mount | grep juice | head -1
    } > "${outdir}/placement.txt" 2>&1 || true
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

# ---------- 一次 randread（规格与 FULLBASELINE_V4.sh item_randread 完全一致）----------
run_randread() {
    local label="$1"
    local subdir="${RESULTS}/${label}"
    mkdir -p "${subdir}"
    drop_caches
    echo "load_pre: $(uptime | grep -oE 'load average:.*')" > "${subdir}/load.txt"
    sudo ceph config dump 2>/dev/null | md5sum | awk '{print $1}' > "${subdir}/config-md5.txt" 2>/dev/null || true
    sudo ceph osd dump -f json 2>/dev/null | python3 -c '
import sys,json;d=json.load(sys.stdin)
print(" ".join("%d:%d"%(o["osd"],o.get("up_from",0)) for o in sorted(d["osds"],key=lambda x:x["osd"])))
' > "${subdir}/up_from.txt" 2>/dev/null || true
    log "  fio ${label}..."
    set +e
    timeout $((RUNTIME + 120)) fio --directory="${TEST_DIR}" --name=read_test \
        --filesize=${LAYOUT_SIZE} --size=${LAYOUT_SIZE} \
        --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=${LAYOUT_JOBS} \
        --direct=1 --fallocate=none --openfiles=${LAYOUT_JOBS} \
        --group_reporting --time_based --runtime=${RUNTIME} \
        --write_bw_log="${BW_LOG_DIR}/${label}" --log_avg_msec=1000 \
        2>&1 | tee "${subdir}/fio.txt" >/dev/null
    local rc=${PIPESTATUS[0]}
    set -e
    echo "load_post: $(uptime | grep -oE 'load average:.*')" >> "${subdir}/load.txt"
    cp "${BW_LOG_DIR}/${label}"_bw.*.log "${subdir}/" 2>/dev/null || true   # ⚑ 只 cp 本 label 前缀（防跨跑污染）
    [ "${BW_LOG_DIR}" = "/tmp/jfs-bw" ] && rm -f "${BW_LOG_DIR}"/*_bw.*.log 2>/dev/null || true
    [ "${rc}" = "0" ] || echo "INVALID rc=${rc}" > "${subdir}/INVALID.txt"
    local bw; bw=$(grep -oE 'bw=[0-9.]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || echo NA)
    log "  ${label}: fio汇总 BW=${bw} MiB/s"
}

# ================= 主流程 =================
log "============================================"
log "=== R1 remount 敏感性测试 ${NGROUPS} 组 × ${ROUNDS_PER_GROUP} 轮 runtime=${RUNTIME}s ==="
log "=== 只读：仅 randread(read_test.*)，不写数据、不改 ceph 配置 ==="
log "============================================"

HEALTH=$(sudo ceph health 2>/dev/null || echo ERROR)
log "ceph health: ${HEALTH}"
echo "${HEALTH}" | grep -qE 'HEALTH_OK|clock skew' || { log "FATAL: health=${HEALTH}"; exit 1; }
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
[ "${OSD_UP}" = "6" ] || { log "FATAL: OSD up=${OSD_UP} != 6"; exit 1; }
pg_check

# prep：与正常运行的起点同构（gc --compact + drop_caches + 优雅 remount + 顺序预热）
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

for g in $(seq 1 "${NGROUPS}"); do
    log "=== 组 g${g}/${NGROUPS}：remount ==="
    remount_jfs
    mkdir -p "${RESULTS}/g${g}"
    collect_placement "${RESULTS}/g${g}"
    log "  卸载方式=${UMOUNT_MODE:-none}  落核已记录 g${g}/placement.txt"
    for r in $(seq 1 "${ROUNDS_PER_GROUP}"); do
        run_randread "g${g}-r${r}"
    done
done

# ================= 分析 =================
log "=== 分析（验收口径：逐秒均值 15-175s；判档用每组最后一轮）==="
python3 - <<PYEOF 2>/dev/null | while read -r l; do log "$l"; done || true
import os, glob, re, statistics
from collections import defaultdict
R = "${RESULTS}"
G = ${NGROUPS}
RPG = ${ROUNDS_PER_GROUP}

def per_sec_mean(sub):
    per = defaultdict(float)
    _lb = os.path.basename(sub.rstrip("/"))
    for f in glob.glob(os.path.join(sub, _lb + "_bw.*.log")):
        for line in open(f):
            p = line.strip().split(",")
            if len(p) < 3: continue
            try:
                s = int(p[0]) // 1000; bw = float(p[1]); d = int(p[2])
            except ValueError: continue
            if d == 0: per[s] += bw
    if not per: return None
    ks = sorted(per); t0 = ks[0]
    w = [per[k] / 1024.0 for k in ks if 15 <= k - t0 <= 175]
    return statistics.mean(w) if w else None

def cpuinfo(g):
    f = os.path.join(R, "g%d" % g, "placement.txt")
    if not os.path.exists(f): return "NA", "NA"
    txt = open(f, errors="ignore").read()
    m = re.search(r"pid=(\S+)", txt)
    pid = m.group(1) if m else "NA"
    # 线程落核直方图里出现的 CPU 号（前 8 个）
    cpus = re.findall(r"^\s+\d+\s+(\d+)$", txt, re.M)
    return pid, ",".join(cpus[:8]) if cpus else "NA"

rows = []
for g in range(1, G + 1):
    vals = []
    for r in range(1, RPG + 1):
        sub = os.path.join(R, "g%d-r%d" % (g, r))
        if os.path.exists(os.path.join(sub, "INVALID.txt")): continue
        v = per_sec_mean(sub)
        if v: vals.append(v)
    if not vals: continue
    pid, cpus = cpuinfo(g)
    rows.append((g, vals, vals[-1], pid, cpus))

print("组   各轮(逐秒均值)                判档值   pid      线程主要落核")
for g, vals, judge, pid, cpus in rows:
    print("g%-3d %-28s %7.0f  %-8s %s" % (g, " ".join("%.0f" % v for v in vals), judge, pid, cpus))

if len(rows) >= 2:
    js = [x[2] for x in rows]
    med = statistics.median(js)
    rng = (max(js) - min(js)) / med * 100
    print("")
    print("组间: n=%d median=%.0f 极差幅度=%.1f%% range=%.0f-%.0f" % (len(js), med, rng, min(js), max(js)))
    S3, S4 = 1697.0, 1834.0   # S3/S4 randread 的验收口径 median（逐秒均值）
    if rng <= 5:
        near = "S4档(~1834)" if abs(med - S4) < abs(med - S3) else "S3档(~1697)"
        print("判定: 单档收敛（组间极差 %.1f%% ≤5%%）⇒ 排除 remount/进程级；档位由池侧状态决定" % rng)
        print("      本次落在 %s，'弃首运行'规则成立；8%% 不会再由 remount 触发" % near)
    else:
        lo = [v for v in js if v < med]; hi = [v for v in js if v >= med]
        mono = (len(js) >= 3 and (js == sorted(js) or js == sorted(js, reverse=True)))
        if mono:
            print("判定: 单调（%.0f→%.0f，组间极差 %.1f%%）⇒ 漂移而非进程级；"
                  % (js[0], js[-1], rng))
            print("      转 OSD 侧采集另立实验；此形态下'弃首运行'无效，基线不成立")
        elif lo and hi and (statistics.mean(hi) / statistics.mean(lo) - 1) * 100 >= 5:
            print("判定: 双档（低档 %.0f / 高档 %.0f，差 %.1f%%）⇒ 与上表落核逐组对照；"
                  % (statistics.mean(lo), statistics.mean(hi),
                     (statistics.mean(hi) / statistics.mean(lo) - 1) * 100))
            print("      若档位与落核相关 ⇒ 归因 CPU 争抢，解 = numactl/taskset 绑核后并入 V4 挂载命令")
            print("      若与落核无关 ⇒ 仍归因进程级（一次性初始化/NUMA），解 = 固定进程启动方式")
        else:
            print("判定: 组间极差 %.1f%% >5%% 但无明显两簇/单调 ⇒ 需人工看 placement.txt" % rng)

# 守卫
nu = len(glob.glob(os.path.join(R, "UNCLEAN_UMOUNT.txt")))
md5 = set()
for f in glob.glob(os.path.join(R, "g*-r*", "config-md5.txt")):
    md5.add(open(f).read().strip())
uf = set()
for f in glob.glob(os.path.join(R, "g*-r*", "up_from.txt")):
    uf.add(open(f).read().strip())
print("")
print("GUARD: 非优雅卸载=%d  config-md5种类=%d  up_from种类=%d  %s" % (
    nu, len(md5), len(uf), "OK" if (nu == 0 and len(md5) <= 1 and len(uf) <= 1) else "FAIL"))
PYEOF

log "=== R1 DONE  结果目录: ${RESULTS} ==="
