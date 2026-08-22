#!/usr/bin/env bash
# env-snapshot.sh — 测试前/后环境快照（统一口径，落盘单文件）
# 用法: bash env-snapshot.sh <OUTDIR> <TAG> [META_URL]
#   TAG 用 pre / post / <任务号>-pre 等；每任务至少 pre/post 两张。
#   快照内容：ceph health、ceph df、pool 对象数、OSD up_from、挂载参数、客户端、fio 版本、卷格式。
#   快照是"环境起点/终点"证据——事后分析漂移（对象数、档位、OSD 状态）全靠它。
set -uo pipefail
OUT="${1:?用法: env-snapshot.sh <OUTDIR> <TAG> [META]}"
TAG="${2:?}"
META="${3:-}"
F="$OUT/env-snapshot-$TAG.txt"
{
  echo "=== ENV-SNAPSHOT $TAG $(date '+%F %T %z') ==="
  echo "--- ceph health ---"
  sudo ceph health detail 2>&1 | head -3
  echo "--- ceph df ---"
  sudo ceph df 2>/dev/null | tail -4
  echo "--- pool objects (juicefs-data) ---"
  sudo ceph df --format=json 2>/dev/null | python3 -c \
    "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data'][0]['stats']; print('objects=',p['objects'],'stored=',p['stored'])" \
    2>/dev/null || echo NA
  echo "--- osd up_from ---"
  sudo ceph osd dump -f json 2>/dev/null | python3 -c \
    'import sys,json;d=json.load(sys.stdin);print(" ".join("%d:%d"%(o["osd"],o.get("up_from",0)) for o in sorted(d["osds"],key=lambda x:x["osd"])))' \
    2>/dev/null || echo NA
  echo "--- juicefs mount ---"
  mount | grep juice || echo "(无 juicefs 挂载)"
  grep juicefs /proc/mounts || true
  echo "--- juicefs 进程 ---"
  pgrep -af juicefs | grep -v instrument || true
  echo "--- 客户端 ---"
  uname -a; echo "cores=$(nproc)"
  echo "--- fio ---"
  fio --version
  if [ -n "$META" ]; then
    echo "--- 卷格式 ---"
    juicefs config "$META" 2>/dev/null | head -12
  fi
} > "$F" 2>&1
echo "env-snapshot → $F" | tee -a "$OUT/wrapper.log"
