#!/usr/bin/env bash
set -uo pipefail
OUT="$1"; LABEL="$2"; HARD=8000000
while :; do
  line=$(sudo ceph df --format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    p=[x for x in d['pools'] if x['name']=='juicefs-data'][0]['stats']
    print(p['objects'], p['stored'])
except Exception: print('')")
  [ -z "$line" ] && { sleep 15; continue; }
  obj=$(echo "$line" | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$(date +%s)" "$LABEL" "$line" >> "$OUT/objwatch-$LABEL.tsv"
  if [ "${obj:-0}" -gt "$HARD" ] 2>/dev/null; then
    echo "$(date '+%F %T') RUNTIME_OBJ_BREACH objects=$obj > $HARD" >> "$OUT/objwatch-$LABEL.tsv"
    pgrep -af fio | awk '/fio --name|fio --directory/ {print $1}' | while read -r pid; do kill "$pid" 2>/dev/null || true; done
    touch "$OUT/OBJ_BREACH-$LABEL"; break
  fi
  sleep 15
done
