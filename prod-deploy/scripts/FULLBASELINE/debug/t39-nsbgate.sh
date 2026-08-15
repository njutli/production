#!/usr/bin/env bash
# t39-nsbgate.sh — ns/B 判档门（AUTHORING-GUIDE §二.10.3；03-9 段A/段B 共用）
# 模式1（V4 rounds 目录，探针轮次）:
#   bash t39-nsbgate.sh <rounds_dir> <LABEL> <item>
#   例: bash t39-nsbgate.sh /tmp/opencode-fullbaseline-v4 PROBE-T39-A1 mseqread
#   读取 <rounds_dir>/<LABEL>/<item>-<LABEL>-r*/jfs-stats-{pre,post}.txt
# 模式2（I1 逐秒 TSV，整窗，供记录/复核）:
#   bash t39-nsbgate.sh --i1 <i1-jfsstats-*.tsv>
# ns/B = Δ(fuse_ops_durations_histogram_seconds_sum)/Δ(..._total)
#      ÷ Δ(juicefs_fuse_read_size_bytes_sum)/Δ(juicefs_fuse_ops_total_read) × 1e9
# 判定：中位 ns/B 与参照 3.287 偏离 >10% ⇒ FAIL(坏档，须重挂)；否则 PASS
set -uo pipefail

REF="${NSB_REF:-3.287}"
TOL="${NSB_TOL:-10}"

if [ "${1:-}" = "--i1" ]; then
  TSV="${2:?}"
  [ -f "$TSV" ] || { echo "MISSING $TSV"; exit 3; }
  nsb=$(awk '
    function num(x){return (x+0==x)}
    { t=$1; k=$2; v=$3
      if (!(NF==3 && num(t) && num(v))) next
      if (!(k in lo)) { lo[k]=v; hi[k]=v } else hi[k]=v }
    END {
      dt=hi["juicefs_fuse_ops_durations_histogram_seconds_total"]-lo["juicefs_fuse_ops_durations_histogram_seconds_total"]
      ds=hi["juicefs_fuse_ops_durations_histogram_seconds_sum"]-lo["juicefs_fuse_ops_durations_histogram_seconds_sum"]
      dr=hi["juicefs_fuse_ops_total_read"]-lo["juicefs_fuse_ops_total_read"]
      dby=hi["juicefs_fuse_read_size_bytes_sum"]-lo["juicefs_fuse_read_size_bytes_sum"]
      if (dt>0 && dr>0 && dby>0) printf "%.3f", (ds/dt)/(dby/dr)*1e9
      else print "NA"
    }' "$TSV")
  echo "I1 $TSV ns/B=$nsb"
  if [ "$nsb" = "NA" ]; then echo "GATE I1 verdict=INDETERMINATE(数据不足)"; exit 1; fi
  dev=$(awk -v m="$nsb" -v r="$REF" 'BEGIN{printf "%.1f", (m-r)/r*100}')
  dabs=$(awk -v d="$dev" 'BEGIN{printf "%.1f", (d<0)?-d:d}')
  verdict=$(awk -v d="$dabs" -v t="$TOL" 'BEGIN{print (d>t)?"FAIL(坏档,须重挂)":"PASS"}')
  echo "GATE I1 ns/B=$nsb ref=$REF dev=${dev}% verdict=$verdict"
  [ "$verdict" = "PASS" ]
  exit $?
fi

R="${1:?}"; L="${2:?}"; IT="${3:?}"
[ -d "$R" ] || { echo "MISSING rounds_dir $R"; exit 3; }
vals=""
for d in "$R"/"$L"/"$IT"-"$L"-r*; do
  [ -d "$d" ] || continue
  pre="$d/jfs-stats-pre.txt"; post="$d/jfs-stats-post.txt"
  if [ ! -f "$pre" ] || [ ! -f "$post" ]; then
    echo "MISSING $d jfs-stats-{pre,post}.txt" >&2
    continue
  fi
  nsb=$(awk '
    function num(x){return (x+0==x)}
    NR==FNR { if (NF==2 && num($2)) k[$1]=$2; next }
    { if (NF==2 && num($2) && ($1 in k)) d[$1]=$2-k[$1] }
    END {
      dt=d["juicefs_fuse_ops_durations_histogram_seconds_total"]
      ds=d["juicefs_fuse_ops_durations_histogram_seconds_sum"]
      dr=d["juicefs_fuse_ops_total_read"]
      dby=d["juicefs_fuse_read_size_bytes_sum"]
      if (dt>0 && dr>0 && dby>0) printf "%.3f", (ds/dt)/(dby/dr)*1e9
      else print "NA"
    }' "$pre" "$post")
  echo "$L $(basename "$d") ns/B=$nsb"
  vals="$vals $nsb"
done
[ -z "${vals// /}" ] && { echo "GATE $L item=$IT 无可用轮次 ⇒ INDETERMINATE"; exit 1; }
med=$(printf '%s\n' $vals | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
dev=$(awk -v m="$med" -v r="$REF" 'BEGIN{printf "%.1f", (m-r)/r*100}')
dabs=$(awk -v d="$dev" 'BEGIN{printf "%.1f", (d<0)?-d:d}')
verdict=$(awk -v d="$dabs" -v t="$TOL" 'BEGIN{print (d>t)?"FAIL(坏档,须重挂)":"PASS"}')
echo "GATE $L item=$IT ns/B_median=$med ref=$REF dev=${dev}% verdict=$verdict"
[ "$verdict" = "PASS" ]
