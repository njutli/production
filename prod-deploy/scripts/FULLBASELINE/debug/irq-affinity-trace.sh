#!/bin/bash
set -euo pipefail
export LC_ALL=C

# irq-affinity-trace.sh — 记录网卡队列 IRQ → 绑定核 的漂移轨迹（**纯只读，不含任何 sudo**）
#
# 为什么需要：157 上 irqbalance 处于 active，队列 IRQ 的绑定核**会随时间变化**。
#   实测 2026-08-05：落在 core 1-16（被外部租户 100% 占满）的队列数
#     12:0x = 9 个  →  12:25 = 11 个  →  12:3x = 23 个
#   若只在实验开头采一次映射，逐组归因会错配。
#
# 用途：给一个**正在运行**的 R2（mount-gear-attrib-test.sh 旧版，开头只采一次）补上逐时映射，
#       事后用 r2-analyze.py --trace 按时间就近匹配到各组。
#       新版 R2 已内建逐组 + 每 15s 采样，正常情况下不需要本脚本。
#
# 安全性（遵循 SYSTEM-SAFETY-SKILL.md）：
#   - 只读 /proc/interrupts 与 /proc/irq/<n>/smp_affinity_list，**不写任何系统文件**
#   - **无 sudo**、无 kill、无 mount/umount、无 rm、无 -R 递归
#   - **有界**：默认最多跑 DURATION_MIN 分钟即自行退出（禁止 while true 无界循环）
#   - 输出文件大小上限 MAX_MB，超过即停，避免占满 /tmp
#   - 只追加写一个硬编码路径的文件；不删除任何文件
#
# 用法：bash irq-affinity-trace.sh [DURATION_MIN] [INTERVAL_SEC]
#       默认 120 分钟 / 30 秒；后台跑：nohup bash irq-affinity-trace.sh 120 30 >/dev/null 2>&1 &
#       提前停止：kill <本脚本 pid>（或等它自己到点退出）

OUT="/tmp/r2-irq-affinity-trace.txt"
STORE_IF="eno12399"          # 到 OSD/TiKV 的实际出口，硬编码（ip route get 10.20.1.150 确认）
DURATION_MIN="${1:-120}"
INTERVAL_SEC="${2:-30}"
MAX_MB=20
MAX_ITER_HARD=2000           # 硬上限，双保险

# ---- 参数守卫（变量名避开 bash 特殊变量：不要用 GROUPS/UID/PWD/SECONDS 等）----
case "${DURATION_MIN}" in ''|*[!0-9]*) echo "REFUSE: DURATION_MIN 必须是整数"; exit 1 ;; esac
case "${INTERVAL_SEC}" in ''|*[!0-9]*) echo "REFUSE: INTERVAL_SEC 必须是整数"; exit 1 ;; esac
[ "${DURATION_MIN}" -ge 1 ] && [ "${DURATION_MIN}" -le 240 ] || { echo "REFUSE: DURATION_MIN 需在 1-240"; exit 1; }
[ "${INTERVAL_SEC}" -ge 5 ] && [ "${INTERVAL_SEC}" -le 300 ] || { echo "REFUSE: INTERVAL_SEC 需在 5-300"; exit 1; }
[ "${OUT}" = "/tmp/r2-irq-affinity-trace.txt" ] || { echo "REFUSE: OUT 路径被改动"; exit 1; }
grep -qE "${STORE_IF}-TxRx" /proc/interrupts 2>/dev/null || { echo "REFUSE: /proc/interrupts 中找不到 ${STORE_IF}-TxRx"; exit 1; }

MAX_ITER=$(( DURATION_MIN * 60 / INTERVAL_SEC ))
[ "${MAX_ITER}" -gt "${MAX_ITER_HARD}" ] && MAX_ITER="${MAX_ITER_HARD}"

{
    echo "########## session start $(date '+%F %T') pid=$$ if=${STORE_IF} interval=${INTERVAL_SEC}s max_iter=${MAX_ITER} ##########"
    echo "# irqbalance=$(systemctl is-active irqbalance 2>/dev/null || echo unknown)"
} >> "${OUT}"

echo "irq-affinity-trace: 每 ${INTERVAL_SEC}s 采一次，最多 ${MAX_ITER} 次（≈${DURATION_MIN} 分钟）后自动退出"
echo "输出: ${OUT}"

n=0
while [ "${n}" -lt "${MAX_ITER}" ]; do
    n=$((n + 1))
    sz_kb=$(du -k "${OUT}" 2>/dev/null | awk '{print $1}')
    if [ -n "${sz_kb:-}" ] && [ "${sz_kb}" -gt $(( MAX_MB * 1024 )) ]; then
        echo "# STOP: 输出已达 ${MAX_MB}MB 上限，第 ${n} 次采样前退出 $(date '+%F %T')" >> "${OUT}"
        echo "已达大小上限，退出"
        break
    fi
    {
        echo "=== ts=$(date +%s) $(date '+%T') iter=${n}"
        grep -E "${STORE_IF}-TxRx" /proc/interrupts 2>/dev/null | sed 's/:.*//' | tr -d ' ' | while read -r i; do
            [ -z "${i}" ] && continue
            c=$(cat "/proc/irq/${i}/smp_affinity_list" 2>/dev/null | head -1)
            [ -n "${c}" ] && echo "${i} ${c}"
        done
    } >> "${OUT}"
    [ "${n}" -lt "${MAX_ITER}" ] && sleep "${INTERVAL_SEC}"
done

{
    echo "########## session end $(date '+%F %T') iters=${n} ##########"
} >> "${OUT}"
echo "结束：共 ${n} 次采样，输出 ${OUT}"
