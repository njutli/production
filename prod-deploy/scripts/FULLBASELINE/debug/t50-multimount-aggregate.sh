#!/usr/bin/env bash
# t50-multimount-aggregate.sh — 03-17e Seg A：多挂载聚合验 F51
#
# 以 t49-read-concurrency-sweep.sh（md5 2cf5cd4479e96b6667c4a1ec1f1d9e76）为模板复制修改。
# 继承 t49 全部缺陷修复：B4-8/9/11/12/15/16。
#
# 与 t49 的差异（按 03-17e 任务书 §三）：
#   1. 臂定义换成 S128/D64/D128（单挂载128/双挂载各64/双挂载各128）+ CAL3（msgr=3 判档标定）
#   2. S128/D64/D128 用 msgr=8（私有 conf 注入）；CAL3 用系统默认 msgr=3（不注入）
#   3. S128 是单挂载、D64/D128 是双挂载（P+Q 同时 fio）
#   4. 批次锚点换成 S128 vs 03-17d J128 均值 5516.7（±25% STOP，±10% NOTE）
#   5. 每轮额外跑 CAL3 cell（只记录，不据此停机/重挂/剔除）
#   6. arm-covariates.tsv 增加 active_only_cv_pct 列（只统计 CPU>2% 的 worker）
#   7. ns/B 不与 REF_NSB=3.287 比较（B4-17：跨 numjobs 不可比），只记录
#   8. ROUNDS 默认 3，臂序每轮左移
#   9. fio 参数与 t49 逐字符相同（randread/256k/iodepth=128/direct=1/readonly/runtime）
#
# 红线：只读；不改 ceph.conf；不 ceph config set；不 gc/compact/重启；不动 /mnt/juicefs；
#   判档值只记录不重挂不剔除；注入不生效 STOP 不换方式。
set -euo pipefail
export LC_ALL=C

MODE="${1:-full}"
OUT="${OUT:-/tmp/production/opencode-t3.17e-segA}"
BIN="${BIN:-/tmp/juicefs-03-8}"
BIN_MD5_WANT="${BIN_MD5_WANT:-de93563f11a5ff3bd94dd25a4e0283b1}"
GATE="${GATE:-/tmp/t39-nsbgate.sh}"
SNAP="${SNAP:-/tmp/env-snapshot.sh}"
CEPH_CONF_SYS=/etc/ceph/ceph.conf
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT_P=/mnt/juicefs-p
MNT_Q=/mnt/juicefs-q
MAIN_MNT=/mnt/juicefs
OPTS=(--max-uploads 150 --cache-size 0 --max-fuse-io 256K)
NIC_PUB=enp139s0f0np0
NIC_MGMT=eno12399
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD=(sshpass -p "${SLAVE_PASS:-Sunrise@801}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise)
REF_NSB=3.287
TOL_NSB=18
NSB_TOL_DISABLED=100000
OBJ_START_MAX=3110000
OBJ_SHRINK_MAX=1000
RUNTIME="${RUNTIME:-180}"
GAP="${GAP:-20}"
ANCHOR_MID=5516.7
ANCHOR_TOL_REPORT=10
ANCHOR_TOL_STOP=25
PREVERIFY_N=8
PREVERIFY_IO=0
SKEW_EVENTS=0
SKEW_MAX_SEEN=0
HAVE_Q=0
PID_P=""; START_P=""; PID_Q=""; START_Q=""
ARM=""; ARM_TAG=""; ARM_THREADS_CUR=""; PASS=""

# 臂定义：S128=单挂载128jobs, D64=双挂载各64, D128=双挂载各128, CAL3=单挂载128jobs(msgr=3)
declare -a ARMS=(S128 D64 D128)
declare -A ARM_N=([S128]=8 [D64]=8 [D128]=8 [CAL3]=3)
declare -A ARM_JOBS_P=([S128]=128 [D64]=64 [D128]=128 [CAL3]=128)
declare -A ARM_JOBS_Q=([S128]=0 [D64]=64 [D128]=128 [CAL3]=0)
declare -A ARM_DUAL=([S128]=0 [D64]=1 [D128]=1 [CAL3]=0)
ROUNDS="${ROUNDS:-3}"
IOCTX_DEFAULT=2

case "$MODE" in
  full|--preflight|--preflight-msgr-only) ;;
  *) echo "REFUSE: 未知模式 $MODE" >&2; exit 2 ;;
esac
if [[ "$MODE" == full ]]; then
  [[ "${ACK_SUDO_WRITES:-}" == YES ]] || { echo "REFUSE: 先审阅脚本中的 sudo 写操作，再以 ACK_SUDO_WRITES=YES 执行" >&2; exit 2; }
fi
[[ "$OUT" == /tmp/* && "$OUT" != /tmp ]] || { echo "REFUSE: OUT 必须是 /tmp 下的非根目录" >&2; exit 2; }
for f in "$BIN" "$GATE" "$SNAP" "$CEPH_CONF_SYS"; do
  [[ -f "$f" ]] || { echo "STOP 缺文件：$f" >&2; exit 2; }
done
BIN_MD5_GOT=$(md5sum "$BIN" | awk '{print $1}')
[[ "$BIN_MD5_GOT" == "$BIN_MD5_WANT" ]] || { echo "STOP 二进制 md5 不符" >&2; exit 3; }
if [[ "$MODE" == full ]]; then
  if [[ -e "$OUT/wrapper.log" ]] || [[ -n "$(find "$OUT" -maxdepth 1 -name 'run-*' -print -quit 2>/dev/null)" ]]; then
    echo "STOP: OUT 已含正式轮证据" >&2; exit 2
  fi
  [[ ! -e "$OUT.tar.gz" && ! -e "$OUT.tar.gz.md5" ]] || { echo "STOP: 目标归档已存在" >&2; exit 2; }
fi
mkdir -p "$OUT" "$OUT/bwlog" "$OUT/osd" "$OUT/conf"
if [[ "$MODE" == full ]]; then LOGFILE="$OUT/wrapper.log"; else LOGFILE="$OUT/preflight.log"; fi
COLLECTOR_PIDS=()
CHILD_PIDS=()

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
sysconf_md5() { md5sum "$CEPH_CONF_SYS" | awk '{print $1}'; }
SYSCONF_MD5_START="$(sysconf_md5)"
cp "$CEPH_CONF_SYS" "$OUT/conf/ceph.conf.system-before"

verify_sysconf() {
  local now; now="$(sysconf_md5)"
  printf '%s\t%s\n' "$(date +%s)" "$now" >> "$OUT/conf/sysconf-checks.tsv"
  [[ "$now" == "$SYSCONF_MD5_START" ]] || { log "STOP /etc/ceph/ceph.conf 被修改"; return 1; }
}

proc_fields() {
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1;
        print f[20],f[12],f[13],f[18]}' "/proc/$1/stat" 2>/dev/null
}

mount_pid() {
  local m="$1" cands p ppid best=""
  cands=$(pgrep -af juicefs 2>/dev/null | awk -v m="$m" '$0 ~ / mount / && $NF==m {print $1}')
  [[ -n "$cands" ]] || return 0
  for p in $cands; do
    ppid=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 0)
    if grep -qx "$ppid" <<<"$cands"; then best="$p"; fi
  done
  [[ -n "$best" ]] || best=$(head -1 <<<"$cands")
  echo "$best"
}

mount_ppid() {
  local m="$1" cands first
  cands=$(pgrep -af juicefs 2>/dev/null | awk -v m="$m" '$0 ~ / mount / && $NF==m {print $1}')
  first=$(head -1 <<<"$cands")
  [[ -n "$first" ]] || { echo NA; return 0; }
  awk '{print $4}' "/proc/$first/stat" 2>/dev/null || echo NA
}

mount_line() { awk -v m="$1" '$2==m {print; exit}' /proc/mounts; }

ioctx_count() {
  local n; n=$(cat "/proc/$1/task/"*/comm 2>/dev/null | grep -c '^io_context_pool' || true); echo "${n:-0}"
}

msgr_count() {
  local n; n=$(cat "/proc/$1/task/"*/comm 2>/dev/null | grep -c '^msgr-worker' || true); echo "${n:-0}"
}

read_bw_mib() {
  awk '/^[[:space:]]+READ: bw=/{
        if (match($0,/bw=[0-9.]+[KMG]iB\/s/)) {
          s=substr($0,RSTART+3,RLENGTH-3); v=s+0;
          if (s ~ /KiB/) v/=1024; else if (s ~ /GiB/) v*=1024;
          printf "%.1f", v; exit
        }}' "$1" 2>/dev/null
}

write_arm_conf() {
  local n="$1" io="$2" f
  [[ "$n" != 0 || "$io" != 0 ]] || { echo ""; return 0; }
  if [[ "$io" == 0 ]]; then f="$OUT/conf/ceph-msgr$n.conf"; else f="$OUT/conf/ceph-msgr$n-ioctx$io.conf"; fi
  if [[ ! -f "$f" ]]; then
    cp "$CEPH_CONF_SYS" "$f"
    printf '\n[client]\n' >> "$f"
    [[ "$n" == 0 ]] || printf '\tms_async_op_threads = %s\n' "$n" >> "$f"
    [[ "$io" == 0 ]] || printf '\tlibrados_thread_count = %s\n' "$io" >> "$f"
  fi
  echo "$f"
}

snapshot_main_identity() {
  MAIN_LINE="$(mount_line "$MAIN_MNT" || true)"
  MAIN_PID="$(mount_pid "$MAIN_MNT" || true)"
  MAIN_START=""
  [[ -z "$MAIN_PID" ]] || MAIN_START="$(proc_fields "$MAIN_PID" | awk '{print $1}')"
  printf 'line=%q\npid=%s\nstarttime=%s\n' "$MAIN_LINE" "${MAIN_PID:-NA}" "${MAIN_START:-NA}" > "$OUT/main-mount-before.txt"
}

verify_main_identity() {
  local line pid st
  line="$(mount_line "$MAIN_MNT" || true)"; pid="$(mount_pid "$MAIN_MNT" || true)"; st=""
  [[ -z "$pid" ]] || st="$(proc_fields "$pid" | awk '{print $1}')"
  printf 'line=%q\npid=%s\nstarttime=%s\n' line pid st >> "$OUT/main-mount-after-checks.txt"
  [[ "$line" == "$MAIN_LINE" && "$pid" == "$MAIN_PID" && "$st" == "$MAIN_START" ]] || { log "STOP 业务挂载身份变化"; return 1; }
}

object_count() {
  local raw
  raw=$(timeout 30 sudo ceph df --format=json 2>/dev/null || true)
  printf '%s\t%s\n' "$(date +%s)" "$raw" >> "$OUT/objects-raw.jsonl"
  printf '%s' "$raw" | python3 -c \
    "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data']; assert len(p)==1; print(p[0]['stats']['objects'])" 2>/dev/null || true
}

health_gate() {
  local tag="$1" h wrn nwrn skew
  { echo "=== $tag $(date '+%F %T') ==="; sudo ceph health detail; sudo ceph pg stat; } > "$OUT/health-$tag.txt" 2>&1
  h=$(grep -m1 '^HEALTH_' "$OUT/health-$tag.txt" || true)
  grep -q '^HEALTH_OK' <<<"$h" && return 0
  nwrn=$(grep -cE '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  wrn=$(grep -m1 -E '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  { [[ "$nwrn" == 1 ]] && grep -qiE '^\[(WRN|ERR)\].*clock skew' "$OUT/health-$tag.txt"; } || { log "STOP $tag Ceph 非 HEALTH_OK"; return 1; }
  skew=$(grep -oE 'clock skew [0-9]+(\.[0-9]+)?s' "$OUT/health-$tag.txt" | sed -E 's/clock skew ([0-9.]+)s/\1/' | sort -g | tail -1)
  [[ "$skew" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { log "STOP $tag 时钟漂移无法解析"; return 1; }
  awk -v s="$skew" 'BEGIN{exit !(s<=0.5)}' || { log "STOP $tag 时钟漂移 ${skew}s > 0.5s"; return 1; }
  SKEW_EVENTS=$((SKEW_EVENTS+1))
  awk -v a="$skew" -v b="$SKEW_MAX_SEEN" 'BEGIN{exit !(a>b)}' && SKEW_MAX_SEEN="$skew"
  timeout 15 sudo ceph time-sync-status > "$OUT/time-sync-$tag.json" 2>&1 || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$tag" "$skew" "$SKEW_EVENTS" "$wrn" >> "$OUT/skew-events.tsv"
  log "NOTE $tag 时钟漂移 ${skew}s（累计 $SKEW_EVENTS 次），记录后继续"
  return 0
}

drop_caches_all() {
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  local ip
  for ip in "${SLAVES[@]}"; do
    "${SSHPASS_CMD[@]}@$ip" 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null'
  done
}

cleanup_mounts() {
  local m
  for m in "$MNT_P" "$MNT_Q"; do
    if [[ -n "$(mount_line "$m" || true)" ]]; then
      "$BIN" umount "$m" >> "$OUT/mount.log" 2>&1 || sudo umount "$m" >> "$OUT/mount.log" 2>&1 || true
      sleep 3
    fi
  done
}

on_exit() {
  local rc=$? p
  trap - EXIT INT TERM
  for p in "${CHILD_PIDS[@]:-}"; do [[ -z "$p" ]] || kill "$p" 2>/dev/null || true; done
  for p in "${CHILD_PIDS[@]:-}"; do [[ -z "$p" ]] || wait "$p" 2>/dev/null || true; done
  cleanup_mounts
  cp "$CEPH_CONF_SYS" "$OUT/conf/ceph.conf.system-after" 2>/dev/null || true
  verify_sysconf || rc=91
  [[ "$MODE" != full ]] || verify_main_identity || rc=90
  log "exit rc=$rc"; exit "$rc"
}
trap on_exit EXIT INT TERM

mount_one() {
  local m="$1" lab="$2" conf="$3" want="$4" want_io="$5" pid st mr got got_io
  if [[ -n "$conf" ]]; then
    CEPH_CONF="$conf" "$BIN" mount -d "${OPTS[@]}" "$META" "$m" >> "$OUT/mount.log" 2>&1
  else
    "$BIN" mount -d "${OPTS[@]}" "$META" "$m" >> "$OUT/mount.log" 2>&1
  fi
  sleep 5
  [[ -n "$(mount_line "$m" || true)" ]] || { log "STOP $lab mount failed"; return 1; }
  mr=$(mount_line "$m" | grep -o 'max_read=[0-9]*' | cut -d= -f2)
  [[ "$mr" == 262144 ]] || { log "STOP $lab max_read=${mr:-NA} !=262144"; return 1; }
  pid=$(mount_pid "$m"); st=$(proc_fields "$pid" | awk '{print $1}')
  [[ -n "$pid" && -n "$st" ]] || { log "STOP $lab 无法解析 PID/starttime"; return 1; }
  ps -T -p "$pid" -o tid=,comm= > "$OUT/msgr-threads-$lab.txt" 2>&1 || true
  got=$(msgr_count "$pid"); got_io=$(ioctx_count "$pid")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lab" "$m" "${conf:-SYSTEM_DEFAULT}" "$want" "$got" "$want_io" "$got_io" >> "$OUT/msgr-threads.tsv"
  [[ "$got" == "$want" ]] || { log "STOP $lab msgr-worker $got != $want"; return 1; }
  [[ "$got_io" == "$want_io" ]] || { log "STOP $lab io_context_pool $got_io != $want_io"; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$lab" "$m" "$pid" "$st" "$mr" "$(mount_ppid "$m")" >> "$OUT/instances.tsv"
  log "MOUNT $lab $m io_pid=$pid msgr-worker=$got io_context=$got_io conf=${conf:-SYSTEM_DEFAULT}"
}

sample_stats() {
  local m="$1" f="$2"
  (
    printf 'ts\tkey\tvalue\n'
    while :; do
      local_t=$(date +%s)
      timeout 3 cat "$m/.stats" 2>/dev/null \
        | grep -E '^(juicefs_fuse_ops_durations_histogram_seconds_(sum|total)|juicefs_fuse_ops_total_(read|write)|juicefs_fuse_(read|write)_size_bytes_sum|juicefs_meta_ops_durations_histogram_seconds_(sum|total)|juicefs_object_request_durations_histogram_seconds_(GET|PUT)_(sum|total)|juicefs_object_request_data_bytes_(GET|PUT)|juicefs_object_request_uploading|juicefs_process_cpu_seconds_total|juicefs_used_(read_)?buffer_size_bytes|juicefs_staging_blocks|juicefs_fuse_open_handlers) ' \
        | awk -v t="$local_t" '{print t"\t"$1"\t"$2}' || true
      sleep 1
    done
  ) > "$f" 2>/dev/null &
  COLLECTOR_PIDS+=("$!"); CHILD_PIDS+=("$!")
}

sample_proc() {
  local pid="$1" f="$2"
  (
    printf 'ts\tpid\tstarttime\tutime\tstime\tthreads\tmsgr_workers\trss_kb\n'
    while [[ -r "/proc/$pid/stat" ]]; do
      local_t=$(date +%s); read -r st ut sy th < <(proc_fields "$pid")
      mw=$(cat "/proc/$pid/task/"*/comm 2>/dev/null | grep -c '^msgr-worker' || true)
      rss=$(awk '/VmRSS/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$local_t" "$pid" "$st" "$ut" "$sy" "$th" "${mw:-NA}" "${rss:-NA}"
      sleep 1
    done
  ) > "$f" 2>/dev/null &
  COLLECTOR_PIDS+=("$!"); CHILD_PIDS+=("$!")
}

thread_snapshot() {
  local pid="$1" f="$2" d
  printf 'ts\ttid\tcomm\tutime\tstime\tprocessor\n' > "$f"
  for d in "/proc/$pid/task/"*; do
    [[ -r "$d/stat" ]] || continue
    awk -v ts="$(date +%s)" '{line=$0; sub(/^[0-9]+ \(/,"",line);
      if (!match(line,/\) [^)]*$/)) next;
      name=substr(line,1,RSTART-1); rest=substr(line,RSTART+2);
      n=split(rest,f,/[[:space:]]+/); if(n<37) next;
      print ts"\t"$1"\t"name"\t"f[12]"\t"f[13]"\t"f[37]}' "$d/stat" >> "$f" 2>/dev/null || true
  done
}

sample_threads() {
  local pid="$1" f="$2"
  (
    printf 'ts\ttid\tcomm\tutime\tstime\tprocessor\n'
    while [[ -d "/proc/$pid/task" ]]; do
      for d in "/proc/$pid/task/"*; do
        [[ -r "$d/stat" ]] || continue
        awk -v ts="$(date +%s)" '{line=$0; sub(/^[0-9]+ \(/,"",line);
          if (!match(line,/\) [^)]*$/)) next;
          name=substr(line,1,RSTART-1); rest=substr(line,RSTART+2);
          n=split(rest,f,/[[:space:]]+/); if(n<37) next;
          print ts"\t"$1"\t"name"\t"f[12]"\t"f[13]"\t"f[37]}' "$d/stat" 2>/dev/null || true
      done
      sleep 5
    done
  ) > "$f" 2>/dev/null &
  COLLECTOR_PIDS+=("$!"); CHILD_PIDS+=("$!")
}

worker_cv_active_only() {
  awk -F'\t' 'NR>1 && $3 ~ /^msgr-worker/ {
      k=$3; c=$4+$5
      if (!(k in first)) {first[k]=c; t0[k]=$1}
      last[k]=c; t1[k]=$1
    }
    END{
      n=0; s=0; el=0; n_active=0
      for (k in first) { d[k]=(last[k]-first[k])/100; s+=d[k]; n++
        if (t1[k]-t0[k] > el) el=t1[k]-t0[k] }
      if (n==0 || el<=0) { printf "NA\tNA\tNA\tNA\t0\t0"; exit }
      m=s/n; v=0; mx=0
      for (k in first) {
        v+=(d[k]-m)^2
        if (d[k]>mx) mx=d[k]
        if (d[k]/el*100 > 2) n_active++
      }
      # active-only CV: only workers with >2% core usage
      if (n_active > 1) {
        s_a=0; n_a=0; v_a=0
        for (k in first) {
          if (d[k]/el*100 > 2) { s_a+=d[k]; n_a++ }
        }
        m_a=s_a/n_a
        for (k in first) {
          if (d[k]/el*100 > 2) { v_a+=(d[k]-m_a)^2 }
        }
        cv_a=(m_a>0 ? sqrt(v_a/n_a)/m_a*100 : 0)
      } else { cv_a=0 }
      printf "%.1f\t%.1f\t%.2f\t%d\t%.1f\t%d", (m>0? sqrt(v/n)/m*100 : 0), mx/el*100, s/el, n, cv_a, n_active
    }' "$1" 2>/dev/null || printf 'NA\tNA\tNA\t0\tNA\t0'
}

sample_net() {
  local f="$1"
  (
    printf 'ts\tpub_rx\tpub_tx\tmgmt_rx\tmgmt_tx\n'
    while :; do
      local_t=$(date +%s)
      awk -v t="$local_t" -v a="$NIC_PUB" -v b="$NIC_MGMT" '
        {gsub(/:/,"",$1)} $1==a{pr=$2;pt=$10} $1==b{mr=$2;mt=$10}
        END{print t"\t"pr"\t"pt"\t"mr"\t"mt}' /proc/net/dev
      sleep 1
    done
  ) > "$f" 2>/dev/null &
  COLLECTOR_PIDS+=("$!"); CHILD_PIDS+=("$!")
}

stop_collectors() {
  local p
  for p in "${COLLECTOR_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  for p in "${COLLECTOR_PIDS[@]:-}"; do wait "$p" 2>/dev/null || true; done
  COLLECTOR_PIDS=()
}

osd_snapshot() {
  local tag="$1" when="$2" i
  for i in 0 1 2 3 4 5; do
    timeout 15 sudo ceph tell "osd.$i" perf dump > "$OUT/osd/$tag-$when-osd$i.json" 2>&1 || true
  done
}

host_state() {
  { uptime; free -m; { ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -25; } || true;
    echo "--- background monitors ---"; pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh' || true;
    echo "--- fio 进程 ---"; pgrep -af fio || true;
    echo "--- 落盘空间 ---"; df -h "$OUT" | tail -1; } > "$1"
}

verify_arm() {
  local p q ps qs
  p=$(mount_pid "$MNT_P" || true)
  [[ -n "$p" ]] || { log "STOP $ARM_TAG P 消失"; return 1; }
  ps=$(proc_fields "$p" | awk '{print $1}')
  if [[ "$HAVE_Q" == 1 ]]; then
    q=$(mount_pid "$MNT_Q" || true)
    [[ -n "$q" ]] || { log "STOP $ARM_TAG Q 消失"; return 1; }
    qs=$(proc_fields "$q" | awk '{print $1}')
  else q=NA; qs=NA; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ARM_TAG" "$p" "$ps" "$q" "$qs" "$(msgr_count "$p")" >> "$OUT/instance-checks.tsv"
  [[ "$p" == "$PID_P" && "$ps" == "$START_P" ]] || { log "STOP $ARM_TAG P 漂移"; return 1; }
  if [[ "$HAVE_Q" == 1 ]]; then
    [[ "$q" == "$PID_Q" && "$qs" == "$START_Q" ]] || { log "STOP $ARM_TAG Q 漂移"; return 1; }
  fi
  verify_sysconf; verify_main_identity
}

check_dataset() {
  local atag="$1" fp fq fmp fmq
  fp=$(find "$MNT_P/test_dir" -maxdepth 1 -type f -name 'read_test.*.0' | wc -l)
  fmp=$(find "$MNT_P/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' | wc -l)
  if [[ "$HAVE_Q" == 1 ]]; then
    fq=$(find "$MNT_Q/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' | wc -l)
    fmq=$(find "$MNT_Q/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' | wc -l)
  else fq=NA; fmq=NA; fi
  printf '%s\tread_test=%s\trw_test=%s\tmseqread_P=%s\tmseqread_Q=%s\n' "$atag" "$fp" "$fq" "$fmp" "$fmq" >> "$OUT/dataset-check.tsv"
  [[ "$fp" == 128 ]] || { log "STOP $atag read_test=$fp/128"; return 1; }
  [[ "$fmp" == 16 ]] || { log "STOP $atag mseqread_P=$fmp/16"; return 1; }
  if [[ "$HAVE_Q" == 1 ]]; then
    [[ "$fq" == 128 ]] || { log "STOP $atag rw_test=$fq/128"; return 1; }
    [[ "$fmq" == 16 ]] || { log "STOP $atag mseqread_Q=$fmq/16"; return 1; }
  fi
}

prepare_arm() {
  local arm="$1" pass="$2" n conf want want_io
  ARM="$arm"; PASS="$pass"; ARM_TAG="T50E-$arm-r$pass"
  cleanup_mounts
  HAVE_Q="${ARM_DUAL[$arm]:-0}"; n="${ARM_N[$arm]}"
  if [[ "$arm" == CAL3 ]]; then
    conf=""; want=3; want_io="$IOCTX_DEFAULT"
  else
    conf="$(write_arm_conf "$n" 0)"; want="$n"; want_io="$IOCTX_DEFAULT"
  fi
  ARM_THREADS_CUR="msgr$want/ioctx$want_io"
  mount_one "$MNT_P" "$ARM_TAG-P" "$conf" "$want" "$want_io" || return 1
  PID_P=$(mount_pid "$MNT_P"); START_P=$(proc_fields "$PID_P" | awk '{print $1}')
  if [[ "$HAVE_Q" == 1 ]]; then
    mount_one "$MNT_Q" "$ARM_TAG-Q" "$conf" "$want" "$want_io" || return 1
    PID_Q=$(mount_pid "$MNT_Q"); START_Q=$(proc_fields "$PID_Q" | awk '{print $1}')
  else
    PID_Q=NA; START_Q=NA
  fi
  check_dataset "$ARM_TAG" || return 1
  printf 'P\t%s\t%s\nQ\t%s\t%s\n' "$PID_P" "$START_P" "$PID_Q" "$START_Q" > "$OUT/frozen-$ARM_TAG.tsv"
  bash "$SNAP" "$OUT" "$ARM_TAG-active" "$META"
  verify_arm || return 1
  log "ARM READY $ARM_TAG threads=$ARM_THREADS_CUR P=$PID_P/$START_P Q=$PID_Q/$START_Q"
}

run_config() {
  local rep="$1" jobs_p="$2" jobs_q="$3" tag dir rc_p=NA rc_q=NA obj_pre obj_post logs_p logs_q bw_p bw_q
  local -a cmd_p=() cmd_q=()
  tag="$ARM_TAG-rep$rep"; dir="$OUT/run-$tag"; mkdir -p "$dir"
  log "START $tag（只采集）threads=$ARM_THREADS_CUR"
  health_gate "$tag-pre"; verify_arm
  obj_pre=$(object_count); echo "$obj_pre" > "$dir/objects-pre.txt"
  [[ "$obj_pre" =~ ^[0-9]+$ && "$obj_pre" -le "$OBJ_START_MAX" ]] || { log "STOP $tag objects=${obj_pre:-NA}"; return 1; }
  host_state "$dir/host-state-pre.txt"
  ps -T -p "$PID_P" -o tid=,comm= > "$dir/msgr-threads-P.txt" 2>&1 || true
  [[ "$HAVE_Q" == 0 ]] || ps -T -p "$PID_Q" -o tid=,comm= > "$dir/msgr-threads-Q.txt" 2>&1 || true
  drop_caches_all
  osd_snapshot "$tag" pre
  COLLECTOR_PIDS=()
  thread_snapshot "$PID_P" "$dir/threads-pre.tsv"
  sample_stats "$MNT_P" "$dir/i1-P.tsv"; sample_proc "$PID_P" "$dir/proc-P.tsv"
  sample_threads "$PID_P" "$dir/threads-series.tsv"
  if [[ "$HAVE_Q" == 1 ]]; then
    sample_stats "$MNT_Q" "$dir/i1-Q.tsv"; sample_proc "$PID_Q" "$dir/proc-Q.tsv"
    sample_threads "$PID_Q" "$dir/threads-series-Q.tsv"
  fi
  sample_net "$dir/net.tsv"
  FIO_P=""; FIO_Q=""
  cmd_p=(timeout "$((RUNTIME+120))" fio --directory="$MNT_P/test_dir" --name=read_test --filesize=1G --size=1G --bs=256k
    --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$jobs_p" --direct=1
    --fallocate=none --openfiles="$jobs_p" --readonly --group_reporting --time_based --runtime="$RUNTIME"
    --write_bw_log="$OUT/bwlog/$tag-P" --log_avg_msec=1000)
  printf '%q ' "${cmd_p[@]}" > "$dir/command-P.txt"; printf '\n' >> "$dir/command-P.txt"
  ( date +%s%N > "$dir/fio-P-start-ns.txt"; exec "${cmd_p[@]}" ) > "$dir/fio-P.txt" 2>&1 & FIO_P=$!; CHILD_PIDS+=("$!")
  if [[ "$jobs_q" -gt 0 ]]; then
    cmd_q=(timeout "$((RUNTIME+120))" fio --directory="$MNT_Q/test_dir" --name=rw_test --filesize=1G --size=1G --bs=256k
      --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$jobs_q" --direct=1
      --fallocate=none --openfiles="$jobs_q" --readonly --group_reporting --time_based --runtime="$RUNTIME"
      --write_bw_log="$OUT/bwlog/$tag-Q" --log_avg_msec=1000)
    printf '%q ' "${cmd_q[@]}" > "$dir/command-Q.txt"; printf '\n' >> "$dir/command-Q.txt"
    ( date +%s%N > "$dir/fio-Q-start-ns.txt"; exec "${cmd_q[@]}" ) > "$dir/fio-Q.txt" 2>&1 & FIO_Q=$!; CHILD_PIDS+=("$!")
  fi
  if wait "$FIO_P"; then rc_p=0; else rc_p=$?; fi
  [[ -z "$FIO_Q" ]] || { if wait "$FIO_Q"; then rc_q=0; else rc_q=$?; fi; }
  thread_snapshot "$PID_P" "$dir/threads-post.tsv"
  [[ "$HAVE_Q" == 0 ]] || thread_snapshot "$PID_Q" "$dir/threads-post-Q.tsv"
  stop_collectors
  osd_snapshot "$tag" post
  health_gate "$tag-post"; verify_arm
  obj_post=$(object_count); echo "$obj_post" > "$dir/objects-post.txt"
  host_state "$dir/host-state-post.txt"
  logs_p=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'-P_bw.*.log' | wc -l)
  logs_q=0; [[ "$jobs_q" == 0 ]] || logs_q=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'-Q_bw.*.log' | wc -l)
  bw_p=$(read_bw_mib "$dir/fio-P.txt"); bw_q=""
  [[ "$jobs_q" == 0 ]] || bw_q=$(read_bw_mib "$dir/fio-Q.txt")
  local bw_sum="NA"
  if [[ "$bw_p" != "" && "$bw_q" != "" ]]; then bw_sum=$(awk -v a="$bw_p" -v b="$bw_q" 'BEGIN{printf "%.1f",a+b}')
  elif [[ "$bw_p" != "" ]]; then bw_sum="$bw_p"; fi
  {
    printf 'tag=%s arm=%s threads=%s pass=%s rep=%s jobs_p=%s jobs_q=%s rc_p=%s rc_q=%s bwlogs_p=%s bwlogs_q=%s\n' \
      "$tag" "$ARM" "$ARM_THREADS_CUR" "$PASS" "$rep" "$jobs_p" "$jobs_q" "$rc_p" "$rc_q" "$logs_p" "$logs_q"
    printf 'msgr_worker_P=%s io_context_P=%s\n' "$(msgr_count "$PID_P")" "$(ioctx_count "$PID_P")"
    [[ "$HAVE_Q" == 0 ]] || printf 'msgr_worker_Q=%s io_context_Q=%s\n' "$(msgr_count "$PID_Q")" "$(ioctx_count "$PID_Q")"
    grep -E '^\s+READ: bw=' "$dir/fio-P.txt" || true
    [[ ! -f "$dir/fio-Q.txt" ]] || grep -E '^\s+READ: bw=' "$dir/fio-Q.txt" || true
  } > "$dir/run-meta.txt"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$ARM" "$ARM_THREADS_CUR" "$PASS" "$rep" "$rc_p" "$rc_q" "${bw_p:-NA}" "${bw_q:-NA}" "${bw_sum:-NA}" >> "$OUT/progress.tsv"
  printf '%s\n' "$tag" >> "$OUT/rounds.tsv"
  [[ "$rc_p" == 0 ]] && [[ "$rc_q" == 0 || "$rc_q" == NA ]] || { log "STOP $tag fio rc P=$rc_p Q=$rc_q"; return 1; }
  { grep -qE '^\s+READ: bw=' "$dir/fio-P.txt" && [[ "$logs_p" == "$jobs_p" ]]; } || { log "STOP $tag P 证据不完整"; return 1; }
  if [[ "$jobs_q" -gt 0 ]]; then
    grep -qE '^\s+READ: bw=' "$dir/fio-Q.txt" && [[ "$logs_q" == "$jobs_q" ]] || { log "STOP $tag Q 证据不完整"; return 1; }
  fi
  if [[ ! "$obj_post" =~ ^[0-9]+$ ]]; then log "STOP $tag objects-post 不可解析"; return 1
  elif [[ "$obj_post" -gt "$obj_pre" ]]; then log "STOP $tag 对象数上涨 $obj_pre->$obj_post"; return 1
  elif [[ "$obj_post" -lt "$obj_pre" ]]; then
    local shrink=$(( obj_pre - obj_post ))
    printf '%s\t%s\t%s\t%s\n' "$tag" "$obj_pre" "$obj_post" "$shrink" >> "$OUT/objects-shrink.tsv"
    [[ "$shrink" -le "$OBJ_SHRINK_MAX" ]] || { log "STOP $tag 对象数下跌 $shrink > $OBJ_SHRINK_MAX"; return 1; }
    log "NOTE $tag 对象数下跌 $obj_pre->$obj_post（-$shrink，容差内，继续）"
  fi
  if [[ "$ARM" == S128 ]]; then printf '%s\t%s\n' "$tag" "${bw_p:-NA}" >> "$OUT/anchor-s128.tsv"; fi
  local cvline nsb_out nsb
  cvline=$(worker_cv_active_only "$dir/threads-series.tsv")
  nsb_out=$(NSB_TOL="$NSB_TOL_DISABLED" NSB_REF="$REF_NSB" bash "$GATE" --i1 "$dir/i1-P.tsv" 2>&1 || true)
  printf '%s\n' "$nsb_out" >> "$OUT/probe-gate.log"
  nsb=$(awk -F'ns/B=' '/^I1 /{print $2; exit}' <<<"$nsb_out" | awk '{print $1}')
  [[ "$nsb" =~ ^[0-9]+([.][0-9]+)?$ ]] || nsb=NA
  local nsb_q="NA"
  if [[ "$HAVE_Q" == 1 && -f "$dir/i1-Q.tsv" ]]; then
    local nsb_out_q
    nsb_out_q=$(NSB_TOL="$NSB_TOL_DISABLED" NSB_REF="$REF_NSB" bash "$GATE" --i1 "$dir/i1-Q.tsv" 2>&1 || true)
    nsb_q=$(awk -F'ns/B=' '/^I1 /{print $2; exit}' <<<"$nsb_out_q" | awk '{print $1}')
    [[ "$nsb_q" =~ ^[0-9]+([.][0-9]+)?$ ]] || nsb_q=NA
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$ARM" "${ARM_N[$ARM]}" "$PASS" "$rep" "${ARM_JOBS_P[$ARM]}" "${ARM_JOBS_Q[$ARM]}" \
    "${bw_p:-NA}" "${bw_q:-NA}" "${bw_sum:-NA}" "$nsb" "$nsb_q" "$cvline" >> "$OUT/arm-covariates.tsv"
  log "COVAR $tag msgr=${ARM_N[$ARM]} jobs_p=${ARM_JOBS_P[$ARM]} jobs_q=${ARM_JOBS_Q[$ARM]} bw_p=${bw_p:-NA} bw_q=${bw_q:-NA} bw_sum=${bw_sum:-NA} worker[$cvline]"
  log "DONE $tag rc P=$rc_p Q=$rc_q bw_P=${bw_p:-NA} bw_Q=${bw_q:-NA} bw_sum=${bw_sum:-NA} objects=$obj_pre"
  log "CELL $tag / $(date '+%F %T %z') / $(tail -1 "$OUT/rounds.tsv")"
  sleep "$GAP"
}

anchor_check() {
  local want="$1" tol="$2" stage="$3" n mean lo hi rlo rhi
  n=$(wc -l < "$OUT/anchor-s128.tsv" 2>/dev/null || echo 0)
  [[ "$n" -ge "$want" ]] || { log "STOP 锚点样本不足：$n < $want（$stage）"; return 1; }
  mean=$(awk -F'\t' '{s+=$2;c++} END{if(c)printf "%.1f",s/c}' "$OUT/anchor-s128.tsv")
  lo=$(awk -v m="$ANCHOR_MID" -v t="$tol" 'BEGIN{printf "%.1f",m*(1-t/100)}')
  hi=$(awk -v m="$ANCHOR_MID" -v t="$tol" 'BEGIN{printf "%.1f",m*(1+t/100)}')
  rlo=$(awk -v m="$ANCHOR_MID" -v t="$ANCHOR_TOL_REPORT" 'BEGIN{printf "%.1f",m*(1-t/100)}')
  rhi=$(awk -v m="$ANCHOR_MID" -v t="$ANCHOR_TOL_REPORT" 'BEGIN{printf "%.1f",m*(1+t/100)}')
  printf '%s\tn=%s\tmean=%s\tstop_lo=%s\tstop_hi=%s\treport_lo=%s\treport_hi=%s\n' "$stage" "$n" "$mean" "$lo" "$hi" "$rlo" "$rhi" >> "$OUT/anchor-check.tsv"
  awk -v v="$mean" -v a="$rlo" -v b="$rhi" 'BEGIN{exit !(v>=a && v<=b)}' || log "NOTE 批次锚点偏离 ±${ANCHOR_TOL_REPORT}%（$stage）：S128 mean=$mean 不在 $rlo~$rhi"
  awk -v v="$mean" -v a="$lo" -v b="$hi" 'BEGIN{exit !(v>=a && v<=b)}' || { log "STOP 批次锚点严重失配（$stage）：S128 mean=$mean 不在 $lo~$hi"; return 1; }
  log "锚点通过（$stage）：S128 n=$n mean=$mean"
}

run_arm() {
  local arm="$1" pass="$2"
  prepare_arm "$arm" "$pass" || return 1
  run_config 1 "${ARM_JOBS_P[$arm]}" "${ARM_JOBS_Q[$arm]}" || return 1
  bash "$SNAP" "$OUT" "$ARM_TAG-complete" "$META"
  cleanup_mounts
}

run_cal3() {
  local pass="$1"
  ARM="CAL3"; PASS="$pass"; ARM_TAG="T50E-CAL3-r$pass"
  cleanup_mounts
  HAVE_Q=0
  mount_one "$MNT_P" "$ARM_TAG-P" "" 3 "$IOCTX_DEFAULT" || return 1
  PID_P=$(mount_pid "$MNT_P"); START_P=$(proc_fields "$PID_P" | awk '{print $1}')
  PID_Q=NA; START_Q=NA
  check_dataset "$ARM_TAG" || return 1
  printf 'P\t%s\t%s\nQ\t%s\t%s\n' "$PID_P" "$START_P" "$PID_Q" "$START_Q" > "$OUT/frozen-$ARM_TAG.tsv"
  bash "$SNAP" "$OUT" "$ARM_TAG-active" "$META"
  verify_arm || return 1
  log "ARM READY $ARM_TAG threads=msgr3/ioctx2 (CAL3, 只记录不判定)"
  run_config 1 128 0 || return 1
  bash "$SNAP" "$OUT" "$ARM_TAG-complete" "$META"
  cleanup_mounts
}

# ---------- 通用前置检查 ----------
md5sum "$BIN" "$GATE" "$SNAP" "$0" > "$OUT/input-md5.txt"
fio --version > "$OUT/fio-version.txt" 2>&1
grep -q '^fio-3\.28' "$OUT/fio-version.txt" || { log "STOP fio 必须 3.28"; exit 3; }
DISK_FREE_MIB=$(df -BM --output=avail "$(dirname "$OUT")" 2>/dev/null | awk 'NR==2{gsub(/M/,"");print $1}')
echo "avail_mib=$DISK_FREE_MIB" > "$OUT/disk-preflight.txt"
df -h "$(dirname "$OUT")" >> "$OUT/disk-preflight.txt" 2>&1
[[ "$DISK_FREE_MIB" =~ ^[0-9]+$ && "$DISK_FREE_MIB" -ge 5120 ]] || { log "STOP 落盘不足"; exit 3; }
self_tree() { local q=$$; while [[ -n "$q" && "$q" != 1 ]]; do echo "$q"; q=$(awk '{print $4}' "/proc/$q/stat" 2>/dev/null || true); done; }
SELF_PIDS="$(self_tree | paste -sd'|' -)"
pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh|nsbgate|t4[0-9]-' 2>/dev/null \
  | grep -vE "^(${SELF_PIDS:-0}) " > "$OUT/background-monitors-initial.txt" || true
wc -l < "$OUT/background-monitors-initial.txt" > "$OUT/background-monitors-count.txt"
echo "self_pids=$SELF_PIDS" > "$OUT/background-monitors-selfexcluded.txt"
snapshot_main_identity
verify_main_identity

if [[ "$MODE" == "--preflight-msgr-only" ]]; then
  log "PREVERIFY 线程注入：请求 ms_async_op_threads=$PREVERIFY_N"
  [[ -z "$(mount_line "$MNT_P" || true)" ]] || { log "STOP 专用挂载点已在使用"; exit 6; }
  sudo mkdir -p "$MNT_P"; sudo chown "$(id -u):$(id -g)" "$MNT_P"
  PRE_CONF="$(write_arm_conf "$PREVERIFY_N" "$PREVERIFY_IO")"
  cp "$PRE_CONF" "$OUT/conf/preverify.conf"
  CEPH_CONF="$PRE_CONF" "$BIN" mount -d "${OPTS[@]}" "$META" "$MNT_P" >> "$OUT/mount.log" 2>&1
  sleep 5
  PRE_PID="$(mount_pid "$MNT_P" || true)"
  PRE_GOT=NA; PRE_GOT_IO=NA
  [[ -z "$PRE_PID" ]] || { PRE_GOT="$(msgr_count "$PRE_PID")"; PRE_GOT_IO="$(ioctx_count "$PRE_PID")"; }
  { echo "requested_ms_async_op_threads=$PREVERIFY_N"
    echo "conf=$PRE_CONF"; echo "--- conf 原文 ---"; cat "$PRE_CONF"
    echo "--- mount 行 ---"; mount_line "$MNT_P" || true
    echo "--- io_pid=$PRE_PID 全部线程 ---"
    [[ -z "$PRE_PID" ]] || ps -T -p "$PRE_PID" -o tid=,comm= 2>&1 || true
    echo "--- 计数 ---"
    echo "msgr-worker=$PRE_GOT (期望 $PREVERIFY_N)"
    echo "io_context_pool=$PRE_GOT_IO (期望 $IOCTX_DEFAULT)"
  } > "$OUT/msgr-preverify.txt" 2>&1
  cleanup_mounts
  log "PREVERIFY 结果：msgr $PREVERIFY_N / $PRE_GOT；io_context $IOCTX_DEFAULT / $PRE_GOT_IO"
  [[ "$PRE_GOT" == "$PREVERIFY_N" && "$PRE_GOT_IO" == "$IOCTX_DEFAULT" ]] || { log "STOP 注入未生效"; exit 7; }
  log "PREVERIFY PASS"; exit 0
fi

if [[ "$MODE" == "--preflight" ]]; then
  health_gate preflight
  PF_OBJ=$(object_count)
  { echo "bin=$BIN md5=$BIN_MD5_GOT"; echo "fio=$(cat "$OUT/fio-version.txt")"
    echo "disk_avail_mib=$DISK_FREE_MIB"; echo "objects=$PF_OBJ (闸门 <= $OBJ_START_MAX)"
    echo "background_monitors=$(cat "$OUT/background-monitors-count.txt") (应为 0)"
    echo "sysconf_md5=$SYSCONF_MD5_START"; echo "--- 业务挂载 ---"; cat "$OUT/main-mount-before.txt"
    echo "--- 专用挂载点占用 ---"; mount_line "$MNT_P" || echo "$MNT_P free"; mount_line "$MNT_Q" || echo "$MNT_Q free"
    echo "--- OSD perf dump 预探 ---"
  } > "$OUT/preflight-summary.txt" 2>&1
  PF_FAIL=0
  for i in 0 1 2 3 4 5; do
    if [[ "$(timeout 15 sudo ceph tell "osd.$i" perf dump 2>/dev/null | wc -c)" -lt 1000 ]]; then
      PF_FAIL=$((PF_FAIL+1)); echo "osd.$i perf dump 空或超时" >> "$OUT/preflight-summary.txt"
    else echo "osd.$i OK" >> "$OUT/preflight-summary.txt"; fi
  done
  cat "$OUT/preflight-summary.txt"
  [[ "$PF_FAIL" == 0 ]] || { log "STOP OSD 预探失败 $PF_FAIL/6"; exit 3; }
  [[ "$PF_OBJ" =~ ^[0-9]+$ && "$PF_OBJ" -le "$OBJ_START_MAX" ]] || { log "STOP objects=${PF_OBJ:-NA} > $OBJ_START_MAX"; exit 5; }
  log "PREFLIGHT 完成"; exit 0
fi

# ---------- 正式矩阵 ----------
printf 'ts\tarm_tag\tpid_p\tstart_p\tpid_q\tstart_q\tmsgr_p\n' > "$OUT/instance-checks.tsv"
printf 'tag\tarm\tthreads\tround\trep\trc_p\trc_q\tbw_p\tbw_q\tbw_sum\n' > "$OUT/progress.tsv"
printf 'tag\n' > "$OUT/rounds.tsv"
printf 'label\tmount\tconf\twant_msgr\tgot_msgr\twant_ioctx\tgot_ioctx\n' > "$OUT/msgr-threads.tsv"
printf 'tag\tobj_pre\tobj_post\tshrink\n' > "$OUT/objects-shrink.tsv"
printf 'tag\tarm\tmsgr_threads\tround\trep\tjobs_p\tjobs_q\tbw_p\tbw_q\tbw_sum\tns_per_B_P\tns_per_B_Q\tworker_cv_pct\tmax_worker_pct_core\tmsgr_sum_core\tn_worker\tactive_only_cv_pct\tactive_worker_n\n' \
  > "$OUT/arm-covariates.tsv"

OSD_PROBE_FAIL=0
for i in 0 1 2 3 4 5; do
  if [[ "$(timeout 15 sudo ceph tell "osd.$i" perf dump 2>/dev/null | wc -c)" -lt 1000 ]]; then
    OSD_PROBE_FAIL=$((OSD_PROBE_FAIL+1)); echo "osd.$i perf dump 空或超时" >> "$OUT/osd-probe.txt"
  else echo "osd.$i OK" >> "$OUT/osd-probe.txt"; fi
done
[[ "$OSD_PROBE_FAIL" == 0 ]] || { log "STOP OSD 预探失败 $OSD_PROBE_FAIL/6"; exit 3; }

health_gate initial
START_OBJECTS=$(object_count); echo "$START_OBJECTS" > "$OUT/objects-initial.txt"
[[ "$START_OBJECTS" =~ ^[0-9]+$ && "$START_OBJECTS" -le "$OBJ_START_MAX" ]] || { log "STOP objects > $OBJ_START_MAX"; exit 5; }
for m in "$MNT_P" "$MNT_Q"; do
  [[ -z "$(mount_line "$m" || true)" ]] || { log "STOP $m 已在使用"; exit 6; }
  if [[ -d "$m" ]] && [[ -n "$(find "$m" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "STOP $m 非空"; exit 6; fi
done
sudo mkdir -p "$MNT_P" "$MNT_Q"; sudo chown "$(id -u):$(id -g)" "$MNT_P" "$MNT_Q"

log "矩阵开始：臂 ${ARMS[*]}（S128/D64/D128 msgr=8）+ CAL3（msgr=3 标定），共 $ROUNDS 轮"
log "⚑ ns/B 与 worker CPU 只作协变量，任何值都不停机"
ORDER=("${ARMS[@]}")
for r in $(seq 1 "$ROUNDS"); do
  log "==== ROUND $r/$ROUNDS 臂序：${ORDER[*]} ===="
  for arm in "${ORDER[@]}"; do
    run_arm "$arm" "$r"
  done
  run_cal3 "$r"
  ORDER=("${ORDER[@]:1}" "${ORDER[0]}")
  [[ "$r" != 1 ]] || anchor_check 1 "$ANCHOR_TOL_STOP" "round1-S128"
done
anchor_check "$ROUNDS" "$ANCHOR_TOL_STOP" "final-S128"

verify_main_identity; verify_sysconf
FINAL_OBJECTS=$(object_count); echo "$FINAL_OBJECTS" > "$OUT/objects-final.txt"
cleanup_mounts
cp "$CEPH_CONF_SYS" "$OUT/conf/ceph.conf.system-after"
verify_sysconf; verify_main_identity
( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
md5sum "$OUT.tar.gz" > "$OUT.tar.gz.md5"
log "ALL DONE；产物齐全（MANIFEST + tar.gz + md5）"
trap - EXIT INT TERM
