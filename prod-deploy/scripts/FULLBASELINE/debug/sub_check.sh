#!/bin/bash
set -eu
# 注：只读检查脚本，不含破坏性操作，不设 pipefail（同 deep-health-check.sh）

# ============================================================
# sub_check.sh — 实验就绪补充检查
#
# 在 WSL 上运行（config.sh 三层 SSH 跳板）。全部只读操作。
# 补充 deep-health-check.sh 未覆盖的实验前置检查项：
#   - 157 负载（load average < 20 阈值，影响 randread 波动）
#   - pool 对象数（确认干净起点）
#   - fast_read 标志（EC 读路径，影响实验设计）
#   - 157 工具链（fio / sshpass / python3 / juicefs）
#   - monitors 存在性（load-monitor.sh / osd-monitor.sh）
#   - EC pool 细节（pg_num / ec_overwrites / stripe_width / min_size）
#   - OSD 拓扑（每节点 2 OSD，CRUSH md5 基线）
#   - PG primary 分布均衡度（stdev，预告 C 组波动幅度）
#
# 用法：bash sub_check.sh
# 退出码：0=全 PASS，1=有 FAIL，2=有 WARN
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${PROD_DEPLOY_DIR}/config.sh"

PASS=0; WARN=0; FAIL=0
declare -a REPORT

ok() {
    local level="$1" item="$2" val="${3:-}"
    case "${level}" in
        PASS) PASS=$((PASS+1));;
        WARN) WARN=$((WARN+1));;
        FAIL) FAIL=$((FAIL+1));;
    esac
    printf '[%s] %-52s %s\n' "${level}" "${item}" "${val}"
    REPORT+=("[${level}] ${item} ${val}")
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

echo "============================================================"
echo "Experiment Readiness Sub-Check $(date '+%F %T')"
echo "============================================================"

# ============================================================
# Section 1: 157 客户端前置（负载 / 工具链 / monitors）
# ============================================================
log "=== Section 1: 157 client prerequisites ==="

out=$(ssh_to_client '
    echo "load1=$(cat /proc/loadavg | awk "{print \$1}")"
    echo "load5=$(cat /proc/loadavg | awk "{print \$2}")"
    echo "load15=$(cat /proc/loadavg | awk "{print \$3}")"
    echo "fio_path=$(command -v fio 2>/dev/null || echo MISSING)"
    echo "fio_ver=$(fio --version 2>/dev/null | head -1 || echo MISSING)"
    echo "sshpass=$(command -v sshpass 2>/dev/null || echo MISSING)"
    echo "python3=$(command -v python3 2>/dev/null || echo MISSING)"
    echo "juicefs=$(command -v juicefs 2>/dev/null || echo MISSING)"
    echo "load_monitor=$([ -x /tmp/load-monitor.sh ] && echo EXISTS || echo MISSING)"
    echo "osd_monitor=$([ -x /tmp/osd-monitor.sh ] && echo EXISTS || echo MISSING)"
    echo "jfs_mounted=$(mountpoint -q /mnt/juicefs 2>/dev/null && echo yes || echo NO)"
    echo "test_dir_files=$(ls /mnt/juicefs/test_dir 2>/dev/null | wc -l)"
' 2>/dev/null) || { ok FAIL "157 可达性" "SSH 不通"; exit 1; }

# 过滤赋值行（排除 bash warning），逐行 eval
_filtered=$(echo "${out}" | grep '^[a-zA-Z_][a-zA-Z0-9_]*=')
while IFS= read -r line; do
    [ -n "$line" ] && eval "$line" 2>/dev/null || true
done <<< "${_filtered}"

# 157 负载（analysis.md 5.0.2：load < 20 → randread Δ < 1.2%，6/6 零反例）
if [ -n "${load1:-}" ]; then
    _high=$(awk -v l="${load1}" 'BEGIN{print (l>20)?1:0}')
    if [ "${_high}" = "0" ]; then
        ok PASS "157 load(1min) < 20" "load=${load1} (5min=${load5} 15min=${load15})"
    else
        ok WARN "157 load(1min) > 20" "load=${load1} (5min=${load5} 15min=${load15}) — randread 波动风险"
    fi
else
    ok FAIL "157 load 读取" "无法获取"
fi

# 工具链
[ "${fio_path:-MISSING}" != "MISSING" ] && ok PASS "157 fio" "${fio_path} (${fio_ver:-?})" || ok FAIL "157 fio 缺失" "需安装"
[ "${sshpass:-MISSING}" != "MISSING" ] && ok PASS "157 sshpass" "${sshpass}" || ok FAIL "157 sshpass 缺失" "需安装"
[ "${python3:-MISSING}" != "MISSING" ] && ok PASS "157 python3" "${python3}" || ok FAIL "157 python3 缺失" "需安装"
[ "${juicefs:-MISSING}" != "MISSING" ] && ok PASS "157 juicefs" "${juicefs}" || ok FAIL "157 juicefs 缺失" "需安装"

# monitors
[ "${load_monitor:-MISSING}" = "EXISTS" ] && ok PASS "157 load-monitor.sh" "EXISTS" || ok WARN "157 load-monitor.sh 缺失" "采集器降级（脚本跳过不报错）"
[ "${osd_monitor:-MISSING}" = "EXISTS" ] && ok PASS "157 osd-monitor.sh" "EXISTS" || ok WARN "157 osd-monitor.sh 缺失" "采集器降级（脚本跳过不报错）"

# JuiceFS 挂载
[ "${jfs_mounted:-NO}" = "yes" ] && ok PASS "157 JuiceFS 挂载" "/mnt/juicefs" || ok FAIL "157 JuiceFS 未挂载" ""

# test_dir 状态
if [ "${test_dir_files:-0}" = "0" ]; then
    ok PASS "157 test_dir 空" "未 layout（预期）"
else
    ok WARN "157 test_dir 非空" "${test_dir_files} 文件（需 destroy 后重新 layout）"
fi

# ============================================================
# Section 2: Ceph pool / EC 细节 / fast_read
# ============================================================
log "=== Section 2: ceph pool & EC details ==="

CEPH="sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell --"

# pool 详情
_pool_detail=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd pool ls detail 2>/dev/null | grep juicefs-data" 2>/dev/null)
echo "${_pool_detail}" | grep -q "ec_overwrites" && ok PASS "ec_overwrites 启用" "" || ok WARN "ec_overwrites 未启用" "JuiceFS 整对象写可能触发 RMW"
echo "${_pool_detail}" | grep -q "pg_num 32" && ok PASS "pg_num=32" "" || ok WARN "pg_num 异常" "$(echo ${_pool_detail} | grep -oE 'pg_num [0-9]+')"
echo "${_pool_detail}" | grep -q "stripe_width 16384" && ok PASS "stripe_width=16384" "" || ok WARN "stripe_width 异常" "$(echo ${_pool_detail} | grep -oE 'stripe_width [0-9]+')"
echo "${_pool_detail}" | grep -q "min_size 5" && ok PASS "min_size=5" "" || ok WARN "min_size 异常" "$(echo ${_pool_detail} | grep -oE 'min_size [0-9]+')"

# fast_read（EC 读路径关键配置）
_fast_read=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd pool get juicefs-data fast_read 2>/dev/null | grep -oE '[0-9]+'" 2>/dev/null | tr -d '[:space:]')
[ "${_fast_read:-0}" = "1" ] && ok PASS "fast_read=1" "EC 并行读启用" \
    || ok WARN "fast_read=0" "EC 读走 primary → C 组 primary 变化会污染波动归因"

# pool 对象数（干净起点）— 用 JSON 精确提取
_pool_objs=$(_run "${CEPH_PRIMARY}" "${CEPH} rados df --format json 2>/dev/null | python3 -c \"import sys,json;pools=json.load(sys.stdin).get('pools',[]);print(next((p['num_objects'] for p in pools if p['name']=='juicefs-data'),'NA'))\"" 2>/dev/null | tr -d '[:space:]')
if [ -n "${_pool_objs:-}" ] && [ "${_pool_objs}" != "NA" ] && [ "${_pool_objs}" -lt 100 ] 2>/dev/null; then
    ok PASS "pool 对象数（干净）" "objects=${_pool_objs}"
elif [ -n "${_pool_objs:-}" ] && [ "${_pool_objs}" != "NA" ]; then
    ok WARN "pool 非空" "objects=${_pool_objs}（需 destroy 清理）"
else
    ok WARN "pool 对象数" "无法读取"
fi

# ============================================================
# Section 3: OSD 拓扑 & CRUSH 基线 & PG primary 分布
# ============================================================
log "=== Section 3: OSD topology & PG primary distribution ==="

_osd_tree=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd tree 2>/dev/null" 2>/dev/null)
echo "${_osd_tree}" | grep -q "osd.0.*up" && echo "${_osd_tree}" | grep -q "osd.5.*up" \
    && ok PASS "6 OSD 全 up" "osd.0-5" || ok FAIL "OSD 不全" "$(echo ${_osd_tree} | grep osd)"

# CRUSH md5 基线（实验全程不变，lc-nvme-attribution.sh 变量守卫比对）
_crush_md5=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph osd getcrushmap 2>/dev/null | md5sum | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
[ -n "${_crush_md5}" ] && ok PASS "CRUSH md5 基线" "${_crush_md5}" || ok WARN "CRUSH md5" "无法读取"

# PG primary 分布均衡度（stdev，预告 C 组波动幅度）
_pg_brief=$(_run "${CEPH_PRIMARY}" "${CEPH} ceph pg dump pgs_brief 2>/dev/null" 2>/dev/null)
_prim_dist=$(echo "${_pg_brief}" | grep '^\s*2\.' | awk '{print $4}' | sort | uniq -c | sort -rn)
_prim_stdev=$(echo "${_pg_brief}" | grep '^\s*2\.' | awk '{print $4}' | python3 -c "
import sys, statistics
vals = [int(l.strip()) for l in sys.stdin if l.strip()]
if vals:
    m = statistics.mean(vals)
    sd = statistics.stdev(vals) if len(vals) > 1 else 0
    print(f'mean={m:.1f} stdev={sd:.2f} range={min(vals)}-{max(vals)} n={len(vals)}')
else:
    print('N/A')
" 2>/dev/null || echo "N/A")
ok PASS "PG primary 分布" "${_prim_stdev}"
echo "  primary 分布明细:"
echo "${_prim_dist}" | while read -r line; do echo "    ${line}"; done

# ============================================================
# Section 4: 汇总
# ============================================================
echo "============================================================"
echo "SUMMARY: PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}"
echo "============================================================"
if [ "${FAIL}" -gt 0 ]; then
    echo "FAIL 项:"
    printf '%s\n' "${REPORT[@]}" | grep '^\[FAIL\]'
    exit 1
elif [ "${WARN}" -gt 0 ]; then
    echo "WARN 项:"
    printf '%s\n' "${REPORT[@]}" | grep '^\[WARN\]'
    exit 2
fi
echo "ALL CHECKS PASSED"
exit 0
