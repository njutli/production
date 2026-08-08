#!/bin/bash
# meta_probe.sh — 客户端后台元数据探针
#
# 在 JuiceFS 挂载点上循环 touch 唯一文件名，记录每个操作的耗时和退出码到 CSV。
# 不设 per-op timeout——阻塞的操作会自然等到 TiKV 选举完成后成功。
# 外层由调用方控制总时长（DUR 参数）。
#
# 用法: meta_probe.sh <mount_point> <csv_output> <duration_seconds>
# CSV 格式: start_ns end_ns rc dur_ms

MNT="$1"
OUT="$2"
DUR="${3:-60}"

end=$(( $(date +%s) + DUR ))
i=0
while [ "$(date +%s)" -lt "$end" ]; do
    i=$((i + 1))
    f="${MNT}/probe_${i}_$(date +%s%N)"
    s=$(date +%s%N)
    touch "$f" 2>/dev/null
    rc=$?
    e=$(date +%s%N)
    dur_ms=$(( (e - s) / 1000000 ))
    echo "$s $e $rc $dur_ms" >> "$OUT"
    [ $rc -eq 0 ] && rm -f "$f" 2>/dev/null
    sleep 0.3
done
