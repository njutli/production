#!/bin/bash
set -e

# rebuild-topology-forensic.sh
# 取证脚本：证明"跨重建大幅波动"的因果根因 = 重建改变 Ceph 物理布局
# (CRUSH PG->OSD 映射 / primary OSD / tmpfs OSD 分配 每次重建都不同)
#
# 用法：在【每次重建 layout 铺完数据后、跑 fio 之前】各调一次，快照一次拓扑。
#   ./rebuild-topology-forensic.sh <REBUILD_TAG>
#   例：R1-A / R2-B / R3-A / R4-B  （与 00-baseline 的轮次标签对齐）
#
# 零性能开销：只读 ceph 元数据 + 一次 rados object 定位，不跑任何 fio。
# 遵循 skills：只读操作，不动 157 内核/网卡/WekaIO 红线。

# ===== 配置 =====
POOL_DATA="juicefs-data"          # JuiceFS 数据 pool（EC）
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSH_USER="sunrise"
SSH_PASS='Sunrise@801'
OUT_ROOT="/tmp/opencode-rebuild-forensic"

TAG="${1:?用法: $0 <REBUILD_TAG>  例如 R1-A}"
TS="$(date '+%Y%m%d-%H%M%S')"
OUT="${OUT_ROOT}/${TAG}-${TS}"
mkdir -p "${OUT}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${OUT}/forensic.log"; }
CEPH() { sudo ceph "$@"; }
SSH() { sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${SSH_USER}@$1" "${@:2}"; }

log "=== 重建拓扑取证快照：TAG=${TAG} ==="
log "输出目录：${OUT}"

# ---------- 1. 集群健康 & OSD 树（含 tmpfs OSD 的物理落点）----------
log "[1/6] ceph health + osd tree + osd df"
CEPH -s                    > "${OUT}/01-ceph-status.txt"      2>&1 || true
CEPH osd tree              > "${OUT}/02-osd-tree.txt"         2>&1 || true
CEPH osd df tree           > "${OUT}/03-osd-df-tree.txt"      2>&1 || true
CEPH osd dump              > "${OUT}/04-osd-dump.txt"         2>&1 || true

# ---------- 2. OSD -> 物理设备/主机 映射（tmpfs 分配每次重建可能不同）----------
log "[2/6] OSD -> host/device metadata"
CEPH osd metadata          > "${OUT}/05-osd-metadata.txt"     2>&1 || true

# ---------- 3. PG -> OSD 全量映射表（核心证据：同一 PG 落到不同 OSD）----------
log "[3/6] pg dump (PG->OSD up/acting set)"
CEPH pg dump               > "${OUT}/06-pg-dump-full.txt"     2>&1 || true
# 精简出 pgid / acting_primary / acting_set，便于跨重建 diff
# pgs_brief 列：PG_STAT UP UP_PRIMARY ACTING ACTING_PRIMARY (末两列=acting set + primary)
CEPH pg dump pgs_brief 2>/dev/null \
  | awk 'NR==1 {print "PG_STAT ACTING_PRIMARY ACTING"; next}
         $1 ~ /^[0-9]+\.[0-9a-f]+$/ {print $1, $NF, $(NF-1)}' \
  > "${OUT}/07-pg-brief.txt" 2>&1 || true

# ---------- 4. CRUSH map（决定映射的规则本身；规则不变、输入 OSD 状态变）----------
log "[4/6] crush dump"
CEPH osd getcrushmap -o "${OUT}/08-crushmap.bin" 2>/dev/null || true
CEPH osd crush dump        > "${OUT}/09-crush-dump.txt"       2>&1 || true

# ---------- 5. 目标数据 pool 的 primary-OSD 分布（真·直方图：每 OSD 承载多少 primary PG）----------
log "[5/6] data-pool primary-OSD 分布直方图"
PID=$(CEPH osd lspools 2>/dev/null | awk -v p="${POOL_DATA}" '$2==p{print $1}')
log "  data pool id = ${PID:-未解析(见 06-pg-dump-full)}"
if [ -n "${PID}" ]; then
    # 07-pg-brief 第2列=ACTING_PRIMARY；按 pool 前缀过滤后统计每个 primary OSD 出现次数
    awk -v pid="${PID}." 'NR>1 && $1 ~ ("^"pid) {print $2}' "${OUT}/07-pg-brief.txt" 2>/dev/null \
      | sort -n | uniq -c | sort -rn \
      | awk '{printf "  primary_osd=%s  pg_count=%s\n", $2, $1}' \
      > "${OUT}/10-primary-osd-histogram.txt" || true
    log "  primary-OSD 直方图 -> 10-primary-osd-histogram.txt"
fi

# ---------- 6. 采一个固定 JuiceFS 对象的 OSD 落点（同名对象跨重建映射对比）----------
log "[6/6] 采样对象的 acting OSD 落点"
# 取该 pool 前 5 个真实对象，记录各自 up/acting set
mapfile -t OBJS < <(sudo rados -p "${POOL_DATA}" ls 2>/dev/null | head -5)
{
  echo "# object    ->  osd map (acting set)"
  for o in "${OBJS[@]}"; do
    m=$(sudo ceph osd map "${POOL_DATA}" "${o}" 2>/dev/null | grep -o 'acting.*')
    echo "${o}    ${m}"
  done
} > "${OUT}/11-object-osd-map.txt" 2>&1 || true

# ---------- 汇总关键指纹（一行式，便于跨重建速览）----------
{
  echo "TAG=${TAG}  TS=${TS}"
  echo "data_pool=${POOL_DATA}  pool_id=${PID:-NA}"
  echo "osd_up=$(CEPH osd ls 2>/dev/null | tr '\n' ',' )"
  echo "--- primary-OSD histogram (data pool) ---"
  cat "${OUT}/10-primary-osd-histogram.txt" 2>/dev/null || echo "(NA)"
  echo "--- sample object acting sets ---"
  cat "${OUT}/11-object-osd-map.txt" 2>/dev/null || echo "(NA)"
} > "${OUT}/00-FINGERPRINT.txt"

log "=== 完成。指纹见 ${OUT}/00-FINGERPRINT.txt ==="
log "跨重建对比：diff 两次的 07-pg-brief.txt / 10-primary-osd-histogram.txt / 11-object-osd-map.txt"
echo "${OUT}"
