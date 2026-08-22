#!/usr/bin/env bash
# t51-newconfig-baseline-wrapper.sh — 03-17e Seg B：新配置全量七项基线
#
# 只做环境准备（PATH shim + CEPH_CONF + 线程哨兵），⛔ 不改 FULLBASELINE_V4.sh 一个字符。
# 调用 V4 的方式完全按任务书 §五：
#   预检: bash FULLBASELINE_V4.sh dry-run
#   NB8:  OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 bash FULLBASELINE_V4.sh NB8 180 3 --remount
#   NB3:  ITEMS="randread randrw" OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 bash FULLBASELINE_V4.sh NB3 180 3 --remount
#
# ⚠ V4 的 RUNTIME/REPEAT 只认位置参数（$2/$3），环境变量会被忽略（B4-16 同族）
# ⚠ /usr/local/bin/juicefs 是另一个构建（md5 bdd182cf...），不做 PATH 注入会测错二进制
# ⚠ NB3 不设 CEPH_CONF（系统默认 msgr=3），NB8 设 CEPH_CONF 注入 msgr=8
# ⚠ JUICEFS_MOUNT_OPTS 保持 V4 默认（不加 --max-fuse-io 256K，与历史 E6/03-10 同口径）
#
# 红线：不改 ceph.conf；不 ceph config set；不改 V4；不改 t39；不动 TiKV
set -euo pipefail
export LC_ALL=C

OUT="${OUT:-/tmp/production/opencode-t3.17e-segB}"
BIN=/tmp/juicefs-03-8
BIN_MD5_WANT=de93563f11a5ff3bd94dd25a4e0283b1
V4=/tmp/FULLBASELINE_V4.sh
CEPH_CONF_SYS=/etc/ceph/ceph.conf
SENTINEL_DIR=/tmp/t51-sentinel

mkdir -p "$OUT" "$SENTINEL_DIR"
LOGFILE="$OUT/wrapper.log"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

# ---------- 1. PATH 注入 ----------
log "=== PATH 注入 ==="
mkdir -p /tmp/t51-bin
ln -sf "$BIN" /tmp/t51-bin/juicefs
export PATH=/tmp/t51-bin:$PATH
WHICH=$(command -v juicefs)
REAL=$(readlink -f "$WHICH")
log "command -v juicefs = $WHICH"
log "readlink -f = $REAL"
[[ "$REAL" == "$BIN" ]] || { log "STOP: PATH 注入后 juicefs 不指向 $BIN"; exit 4; }
BIN_MD5_GOT=$(md5sum "$BIN" | awk '{print $1}')
[[ "$BIN_MD5_GOT" == "$BIN_MD5_WANT" ]] || { log "STOP: 二进制 md5 不符"; exit 4; }
VERSION=$("$BIN" version 2>&1)
log "version = $VERSION"
echo "$VERSION" | grep -q 'e0032b2a$' || { log "STOP: version 末尾无 a（指向了错误构建）"; exit 4; }
log "PATH 注入验证通过"

# ---------- 2. ceph.conf 起始 md5 ----------
SYSCONF_MD5_START=$(md5sum "$CEPH_CONF_SYS" | awk '{print $1}')
log "ceph.conf md5 start = $SYSCONF_MD5_START"
cp "$CEPH_CONF_SYS" "$OUT/ceph.conf.system-before"

# ---------- 3. 私有 conf（仅 NB8） ----------
mkdir -p /tmp/t51-conf
cp "$CEPH_CONF_SYS" /tmp/t51-conf/ceph-msgr8.conf
printf '\n[client]\n\tms_async_op_threads = 8\n' >> /tmp/t51-conf/ceph-msgr8.conf
log "私有 conf 已生成: /tmp/t51-conf/ceph-msgr8.conf"

# ---------- 4. 线程哨兵 ----------
start_sentinel() { # $1=期望 msgr 数
  local want="$1"
  (
    printf 'ts\tpid\tmsgr_workers\tio_context_pool\tworker_cpu_detail\n'
    while true; do
      local pid
      pid=$(pgrep -af 'juicefs.*mount.*juicefs-prod' 2>/dev/null | awk '$0 ~ / mount / {print $1}' | head -1)
      if [[ -n "$pid" ]]; then
        local msgr ioctx
        msgr=$(cat "/proc/$pid/task/"*/comm 2>/dev/null | grep -c '^msgr-worker' || true)
        ioctx=$(cat "/proc/$pid/task/"*/comm 2>/dev/null | grep -c '^io_context_pool' || true)
        local cpu_detail=""
        for d in "/proc/$pid/task/"*; do
          [[ -r "$d/stat" ]] || continue
          local comm ut st
          comm=$(cat "$d/comm" 2>/dev/null || true)
          [[ "$comm" =~ ^msgr-worker ]] || continue
          read -r _ ut st _ < <(awk '{print $1, $14, $15, $39}' "$d/stat" 2>/dev/null || true)
          cpu_detail="${cpu_detail}${comm}:${ut}+${st};"
        done
        printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$pid" "${msgr:-NA}" "${ioctx:-NA}" "$cpu_detail"
        if [[ "${msgr:-0}" != "$want" ]]; then
          echo "[$(date '+%F %T')] STOP 哨兵: msgr-worker=$msgr != $want" >> "$SENTINEL_DIR/stop.log"
        fi
      fi
      sleep 30
    done
  ) > "$SENTINEL_DIR/threads-series.tsv" 2>/dev/null &
  SENTINEL_PID=$!
  log "线程哨兵已启动 (PID=$SENTINEL_PID, 期望 msgr=$want)"
}

stop_sentinel() {
  [[ -n "${SENTINEL_PID:-}" ]] || return 0
  kill "$SENTINEL_PID" 2>/dev/null || true
  wait "$SENTINEL_PID" 2>/dev/null || true
  log "线程哨兵已停止"
}

# ---------- 5. dry-run ----------
log "=== dry-run ==="
bash "$V4" dry-run 2>&1 | tee "$OUT/dry-run.txt"
DRY_RC=${PIPESTATUS[0]}
log "dry-run rc=$DRY_RC"
if [[ $DRY_RC -ne 0 ]]; then
  log "dry-run 失败，尝试 --layout"
  bash "$V4" --layout 2>&1 | tee -a "$OUT/dry-run.txt"
  log "layout 重建完成（已记录）"
  bash "$V4" dry-run 2>&1 | tee -a "$OUT/dry-run.txt"
  DRY_RC=${PIPESTATUS[0]}
  [[ $DRY_RC -eq 0 ]] || { log "STOP: dry-run 仍失败"; stop_sentinel; exit 1; }
fi

# ---------- 6. NB8（主，七项 × 3 轮）----------
log "=== NB8 开始（msgr=8，七项 × 3 轮）==="
export CEPH_CONF=/tmp/t51-conf/ceph-msgr8.conf
start_sentinel 8

OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 bash "$V4" NB8 180 3 --remount 2>&1 | tee "$OUT/nb8.log"
NB8_RC=${PIPESTATUS[0]}
log "NB8 rc=$NB8_RC"

stop_sentinel
unset CEPH_CONF

# ---------- 7. NB3（对照，2 项 × 3 轮）----------
log "=== NB3 开始（msgr=3 系统默认，2 项 × 3 轮）==="
start_sentinel 3

ITEMS="randread randrw" OBJ_GATE=1 OBJ_TARGET=2500000 OBJ_MAX=8000000 bash "$V4" NB3 180 3 --remount 2>&1 | tee "$OUT/nb3.log"
NB3_RC=${PIPESTATUS[0]}
log "NB3 rc=$NB3_RC"

stop_sentinel

# ---------- 8. 收尾 ----------
SYSCONF_MD5_END=$(md5sum "$CEPH_CONF_SYS" | awk '{print $1}')
cp "$CEPH_CONF_SYS" "$OUT/ceph.conf.system-after"
log "ceph.conf md5 end = $SYSCONF_MD5_END"
[[ "$SYSCONF_MD5_END" == "$SYSCONF_MD5_START" ]] || { log "STOP: ceph.conf 被修改"; exit 2; }

cp -r "$SENTINEL_DIR" "$OUT/sentinel"

( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
md5sum "$OUT.tar.gz" > "$OUT.tar.gz.md5"
log "ALL DONE；产物齐全（MANIFEST + tar.gz + md5）"
