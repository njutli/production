#!/usr/bin/env bash
# t48-mount-state-worker-balance.sh — 03-17b：读侧双稳态（阻塞 B8）定性，只采集、不判定
#
# 要回答的唯一问题：03-16/03-17 两次出现的"坏档"（对象层 in-flight 97.4 -> 80.0）是什么引起的。
#   H1 msgr worker 连接分配不均  -> 判别信号：坏档时 msgr-worker-N 逐线程 CPU 严重不均
#   H2 线程 CPU/NUMA 落位        -> 判别信号：坏档与线程所在 CPU / NUMA node 相关，worker 间却均衡
#   H3 objecter 全局锁           -> H1/H2 都不成立时的兜底
#
# 与 03-17 的关键差别：
#   - ⛔ 不注入任何参数。不写私有 conf、不设 CEPH_CONF，全程用系统默认（期望 msgr-worker=3、io_context_pool=2）。
#     线程数不等于默认值即 STOP —— 那意味着共享配置被人改了，本任务的对照失去意义。
#   - ⛔ 判档结果不作为停机条件。好档坏档都要跑完、都要落盘。这是本任务的观测对象，不是准入门槛。
#   - 新增 t47 没有的逐线程采样：每个线程的 comm / utime / stime / 所在 CPU。H1 只能靠这个证。
#
# 红线（与 03-16/03-17 一致）：
#   - 只读；fio 带 --readonly；不跑 randwrite/randrw；不做 gc、compact、重启。
#   - ⛔ 绝不修改 /etc/ceph/ceph.conf，绝不执行 ceph config set；起止两次核 md5，不一致立即 STOP。
#   - 不卸载、不重挂、不改动业务挂载 /mnt/juicefs；仅使用 /mnt/juicefs-p。
#   - 对象闸门单向：上涨 STOP；下跌 <=OBJ_SHRINK_MAX 记录续跑；下跌超限 STOP；不可解析 STOP。
#   - 不改 objecter_inflight_ops / objecter_inflight_op_bytes / --max-uploads / --max-fuse-io / --cache-size。
#
# 两种模式：
#   bash t48-mount-state-worker-balance.sh --preflight        # 无状态清点
#   ACK_SUDO_WRITES=YES bash t48-mount-state-worker-balance.sh full
#
# sudo 写入仅限：创建专用挂载目录、client+3 节点 drop_caches、卸载专用挂载。
# 只读 sudo：ceph health/pg/df、ceph tell osd.N perf dump、ss -tnp。
set -euo pipefail
export LC_ALL=C

MODE="${1:-full}"
OUT="${OUT:-/tmp/production/opencode-t3.17b}"
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
OBJ_START_MAX=3110000
OBJ_SHRINK_MAX=1000
# 下面 5 个允许用环境变量覆盖，只为执行方做管路冒烟测试（例如 ITERS=1 RUNTIME=30 OUT=..._smoke）。
# ⚑ 正式轮必须用默认值：RUNTIME=180 是 REF_NSB=3.287 的标定形状，改了 ns/B 就不可比。
# 脚本会把实际生效值写入 params.txt，分析方据此判定该批数据是否可用。
RUNTIME="${RUNTIME:-180}"
GAP="${GAP:-20}"
ITERS="${ITERS:-8}"
RECOVER_ITER="${RECOVER_ITER:-5}"   # 该次迭代前先空转 RECOVER_SLEEP 秒，测坏档能否自行脱离
RECOVER_SLEEP="${RECOVER_SLEEP:-180}"
MSGR_DEFAULT=3      # 系统默认 ms_async_op_threads（157 实测）
IOCTX_DEFAULT=2     # 系统默认 librados_thread_count（157 实测）
THREAD_SAMPLE_SEC=5
SKEW_EVENTS=0
SKEW_MAX_SEEN=0

case "$MODE" in
  full|--preflight) ;;
  *) echo "REFUSE: 未知模式 $MODE（可选 --preflight | full）" >&2; exit 2 ;;
esac
if [[ "$MODE" == full ]]; then
  [[ "${ACK_SUDO_WRITES:-}" == YES ]] || {
    echo "REFUSE: 先审阅脚本中的 sudo 写操作，再以 ACK_SUDO_WRITES=YES 执行" >&2; exit 2; }
fi
[[ "$OUT" == /tmp/* && "$OUT" != /tmp ]] || { echo "REFUSE: OUT 必须是 /tmp 下的非根目录：$OUT" >&2; exit 2; }
for f in "$BIN" "$GATE" "$SNAP" "$CEPH_CONF_SYS"; do
  [[ -f "$f" ]] || { echo "STOP 缺文件：$f" >&2; exit 2; }
done
BIN_MD5_GOT=$(md5sum "$BIN" | awk '{print $1}')
[[ "$BIN_MD5_GOT" == "$BIN_MD5_WANT" ]] || {
  echo "STOP 二进制 md5 不符：want $BIN_MD5_WANT got $BIN_MD5_GOT（必须与 03-16/03-17 同一构建）" >&2; exit 3; }
if [[ "$MODE" == full ]]; then
  if [[ -e "$OUT/wrapper.log" ]] || [[ -n "$(find "$OUT" -maxdepth 1 -name 'iter-*' -print -quit 2>/dev/null)" ]]; then
    echo "STOP: OUT 已含正式轮证据，禁止混入；请保留现场并由分析方指定新 OUT：$OUT" >&2; exit 2
  fi
  [[ ! -e "$OUT.tar.gz" && ! -e "$OUT.tar.gz.md5" ]] || {
    echo "STOP: 目标归档已存在，禁止覆盖：$OUT.tar.gz{,.md5}" >&2; exit 2; }
fi
mkdir -p "$OUT" "$OUT/bwlog" "$OUT/osd" "$OUT/conf" "$OUT/threads"
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
  [[ "$now" == "$SYSCONF_MD5_START" ]] || { log "STOP /etc/ceph/ceph.conf 被修改：start=$SYSCONF_MD5_START now=$now"; return 1; }
}

proc_fields() { # $1=pid → starttime utime stime threads
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1;
        print f[20],f[12],f[13],f[18]}' "/proc/$1/stat" 2>/dev/null
}

mount_pid() { # $1=精确挂载点 → 真正服务 IO 的那个进程（B4-8 的正确实现）
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

mount_ppid() { # $1=挂载点 → 守护父进程 PID（仅留档）
  local m="$1" cands first
  cands=$(pgrep -af juicefs 2>/dev/null | awk -v m="$m" '$0 ~ / mount / && $NF==m {print $1}')
  first=$(head -1 <<<"$cands"); [[ -n "$first" ]] || { echo NA; return 0; }
  awk '{print $4}' "/proc/$first/stat" 2>/dev/null || echo NA
}

mount_line() { awk -v m="$1" '$2==m {print; exit}' /proc/mounts; }
msgr_count()  { local n; n=$(cat "/proc/$1/task/"*/comm 2>/dev/null | grep -c '^msgr-worker' || true); echo "${n:-0}"; }
ioctx_count() { local n; n=$(cat "/proc/$1/task/"*/comm 2>/dev/null | grep -c '^io_context_pool' || true); echo "${n:-0}"; }

read_bw_mib() { # $1=fio 输出 → READ 汇总带宽，统一 MiB/s
  awk '/^[[:space:]]+READ: bw=/{
        if (match($0,/bw=[0-9.]+[KMG]iB\/s/)) {
          s=substr($0,RSTART+3,RLENGTH-3); v=s+0;
          if (s ~ /KiB/) v/=1024; else if (s ~ /GiB/) v*=1024;
          printf "%.1f", v; exit }}' "$1" 2>/dev/null
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
  printf 'line=%q\npid=%s\nstarttime=%s\n' "$line" "${pid:-NA}" "${st:-NA}" >> "$OUT/main-mount-after-checks.txt"
  [[ "$line" == "$MAIN_LINE" && "$pid" == "$MAIN_PID" && "$st" == "$MAIN_START" ]] || {
    log "STOP 业务挂载身份变化；本脚本不再继续"; return 1; }
}

object_count() {
  local raw
  raw=$(timeout 30 sudo ceph df --format=json 2>/dev/null || true)
  printf '%s\t%s\n' "$(date +%s)" "$raw" >> "$OUT/objects-raw.jsonl"
  printf '%s' "$raw" | python3 -c \
    "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data']; assert len(p)==1; print(p[0]['stats']['objects'])" \
    2>/dev/null || true
}

health_gate() { # $1=tag；唯一告警是时钟漂移且 <=0.5s 时记录并继续，其余 STOP
  local tag="$1" h wrn nwrn skew
  { echo "=== $tag $(date '+%F %T') ==="; sudo ceph health detail; sudo ceph pg stat; } > "$OUT/health-$tag.txt" 2>&1
  h=$(grep -m1 '^HEALTH_' "$OUT/health-$tag.txt" || true)
  grep -q '^HEALTH_OK' <<<"$h" && return 0
  nwrn=$(grep -cE '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  wrn=$(grep -m1 -E '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  { [[ "$nwrn" == 1 ]] && grep -qiE '^\[(WRN|ERR)\].*clock skew' "$OUT/health-$tag.txt"; } || {
    log "STOP $tag Ceph 非 HEALTH_OK：$h（告警条数=$nwrn，首条=$wrn）"; return 1; }
  skew=$(grep -oE 'clock skew [0-9]+(\.[0-9]+)?s' "$OUT/health-$tag.txt" | sed -E 's/clock skew ([0-9.]+)s/\1/' | sort -g | tail -1)
  [[ "$skew" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { log "STOP $tag 时钟漂移告警但无法解析漂移值：$wrn"; return 1; }
  awk -v s="$skew" 'BEGIN{exit !(s<=0.5)}' || { log "STOP $tag 时钟漂移 ${skew}s > 0.5s"; return 1; }
  SKEW_EVENTS=$((SKEW_EVENTS+1))
  awk -v a="$skew" -v b="$SKEW_MAX_SEEN" 'BEGIN{exit !(a>b)}' && SKEW_MAX_SEEN="$skew"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$tag" "$skew" "$SKEW_EVENTS" "$wrn" >> "$OUT/skew-events.tsv"
  log "NOTE $tag 唯一告警为时钟漂移 ${skew}s（累计 $SKEW_EVENTS 次，峰值 ${SKEW_MAX_SEEN}s），记录后继续"
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
  log "exit rc=$rc"
  exit "$rc"
}
trap on_exit EXIT INT TERM

# ---------- 逐线程采样：H1 的唯一证据来源 ----------
# /proc/<tid>/stat 去掉 "pid (" 与 ") " 后，rest[i] 对应 stat 字段 i+2：
#   rest[12]=utime(14) rest[13]=stime(15) rest[20]=starttime(22) rest[37]=processor(39)
thread_snapshot() { # $1=pid $2=输出文件（一次性全量快照）
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

sample_threads() { # $1=pid $2=输出文件（周期采样，看落位是否漂移）
  local pid="$1" f="$2"
  (
    printf 'ts\ttid\tcomm\tutime\tstime\tprocessor\n'
    while [[ -d "/proc/$pid" ]]; do
      local_t=$(date +%s)
      for d in "/proc/$pid/task/"*; do
        [[ -r "$d/stat" ]] || continue
        awk -v ts="$local_t" '{line=$0; sub(/^[0-9]+ \(/,"",line);
          if (!match(line,/\) [^)]*$/)) next;
          name=substr(line,1,RSTART-1); rest=substr(line,RSTART+2);
          n=split(rest,f,/[[:space:]]+/); if(n<37) next;
          print ts"\t"$1"\t"name"\t"f[12]"\t"f[13]"\t"f[37]}' "$d/stat" 2>/dev/null || true
      done
      sleep "$THREAD_SAMPLE_SEC"
    done
  ) > "$f" 2>/dev/null &
  COLLECTOR_PIDS+=("$!"); CHILD_PIDS+=("$!")
}

sample_stats() { # $1=mount $2=file（键集合与 t46/t47 完全一致，保证 ns/B 可比）
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

sample_net() { # $1=file
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

osd_snapshot() { # $1=tag $2=pre|post
  local tag="$1" when="$2" i
  for i in 0 1 2 3 4 5; do
    timeout 15 sudo ceph tell "osd.$i" perf dump > "$OUT/osd/$tag-$when-osd$i.json" 2>&1 || true
  done
}

conn_snapshot() { # $1=pid $2=文件；连接清单（期望 6 个 OSD + mon/mgr），H1 的旁证
  { echo "=== ss -tnp pid=$1 $(date '+%F %T') ==="
    sudo ss -tnp 2>/dev/null | grep "pid=$1," || echo "（无匹配）"
  } > "$2" 2>&1
}

host_state() { # $1=输出文件
  { uptime; free -m; ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -25
    echo "--- background monitors ---"
    pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh' || true
    echo "--- fio 进程（应只有本任务）---"; pgrep -af fio || true
    echo "--- 落盘空间 ---"; df -h "$OUT" | tail -1; } > "$1"
}

check_dataset() { # $1=tag；判档形状用 mseqread 的 16 个文件
  local tag="$1" fmp
  fmp=$(find "$MNT_P/test_dir/mseqread/" -maxdepth 1 -type f -name 'mseqread.*.0' 2>/dev/null | wc -l)
  [[ "$fmp" == 16 ]] || { log "STOP $tag 数据集不完整：mseqread=$fmp/16（禁止由 fio 补写布局）"; return 1; }
}

mount_default() { # $1=iter → 用系统默认参数挂载，并核对默认线程数
  local it="$1" pid st mr got got_io
  "$BIN" mount -d "${OPTS[@]}" "$META" "$MNT_P" >> "$OUT/mount.log" 2>&1
  sleep 5
  [[ -n "$(mount_line "$MNT_P" || true)" ]] || { log "STOP iter$it mount failed: $MNT_P"; return 1; }
  mr=$(mount_line "$MNT_P" | grep -o 'max_read=[0-9]*' | cut -d= -f2)
  [[ "$mr" == 262144 ]] || { log "STOP iter$it max_read=${mr:-NA} !=262144"; return 1; }
  ITER_PID=$(mount_pid "$MNT_P"); ITER_START=$(proc_fields "$ITER_PID" | awk '{print $1}')
  [[ -n "$ITER_PID" && -n "$ITER_START" ]] || { log "STOP iter$it 无法解析 mount PID/starttime"; return 1; }
  ps -T -p "$ITER_PID" -o tid=,comm= > "$OUT/threads/iter$it-comm.txt" 2>&1 || true
  got=$(msgr_count "$ITER_PID"); got_io=$(ioctx_count "$ITER_PID")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$it" "$ITER_PID" "$ITER_START" "$got" "$got_io" "$(mount_ppid "$MNT_P")" \
    >> "$OUT/instances.tsv"
  # 本任务不注入参数，因此线程数必须等于系统默认；不等意味着共享配置被改，对照失效
  [[ "$got" == "$MSGR_DEFAULT" ]] || {
    log "STOP iter$it msgr-worker=$got != 系统默认 $MSGR_DEFAULT（疑 /etc/ceph/ceph.conf 或 ceph config 被改动）"; return 1; }
  [[ "$got_io" == "$IOCTX_DEFAULT" ]] || {
    log "STOP iter$it io_context_pool=$got_io != 系统默认 $IOCTX_DEFAULT"; return 1; }
  log "MOUNT iter$it io_pid=$ITER_PID daemon_pid=$(mount_ppid "$MNT_P") msgr-worker=$got io_context=$got_io"
}

verify_instance() { # $1=iter；实例身份冻结
  local it="$1" p st
  p=$(mount_pid "$MNT_P" || true)
  [[ -n "$p" ]] || { log "STOP iter$it 专用挂载消失"; return 1; }
  st=$(proc_fields "$p" | awk '{print $1}')
  [[ "$p" == "$ITER_PID" && "$st" == "$ITER_START" ]] || {
    log "STOP iter$it 实例漂移 got $p/$st want $ITER_PID/$ITER_START"; return 1; }
  verify_sysconf
  verify_main_identity
}

run_iter() { # $1=iter
  local it="$1" tag dir obj_pre obj_post shrink nsb dev out fio_rc bw logs sp tp np
  tag="T48-iter$it"; dir="$OUT/iter-$it"; mkdir -p "$dir"

  if [[ "$it" == "$RECOVER_ITER" ]]; then
    log "iter$it 前置空转 ${RECOVER_SLEEP}s（无挂载状态），用于判定坏档能否自行脱离"
    sleep "$RECOVER_SLEEP"
  fi

  health_gate "$tag-pre"
  obj_pre=$(object_count); echo "$obj_pre" > "$dir/objects-pre.txt"
  [[ "$obj_pre" =~ ^[0-9]+$ && "$obj_pre" -le "$OBJ_START_MAX" ]] || {
    log "STOP $tag objects=${obj_pre:-NA} > $OBJ_START_MAX 或不可解析"; return 1; }

  mount_default "$it" || return 1
  check_dataset "$tag" || return 1
  conn_snapshot "$ITER_PID" "$dir/conns-pre.txt"
  host_state "$dir/host-state-pre.txt"
  drop_caches_all
  osd_snapshot "$tag" pre

  COLLECTOR_PIDS=()
  thread_snapshot "$ITER_PID" "$dir/threads-pre.tsv"
  sample_stats "$MNT_P" "$dir/i1.tsv"; sp="${COLLECTOR_PIDS[-1]}"
  sample_threads "$ITER_PID" "$dir/threads-series.tsv"; tp="${COLLECTOR_PIDS[-1]}"
  sample_net "$dir/net.tsv"; np="${COLLECTOR_PIDS[-1]}"

  # 判档形状：与 t46/t47 的判档 fio 逐字符相同，保证 ns/B 与 REF_NSB=3.287 同口径
  if timeout $((RUNTIME+120)) fio --name=mseqread --directory="$MNT_P/test_dir/mseqread/" --rw=read \
      --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 \
      --ioengine=psync --iodepth=1 --readonly --time_based --runtime="$RUNTIME" \
      --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 \
      > "$dir/fio.txt" 2>&1; then fio_rc=0; else fio_rc=$?; fi

  thread_snapshot "$ITER_PID" "$dir/threads-post.tsv"
  stop_collectors
  osd_snapshot "$tag" post
  conn_snapshot "$ITER_PID" "$dir/conns-post.txt"
  host_state "$dir/host-state-post.txt"
  health_gate "$tag-post"
  verify_instance "$it" || return 1

  [[ "$fio_rc" == 0 ]] || { log "STOP $tag fio rc=$fio_rc"; return 1; }
  grep -qE '^\s+READ: bw=' "$dir/fio.txt" || { log "STOP $tag 缺 READ 汇总行"; return 1; }
  logs=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'_bw.*.log' | wc -l)
  [[ "$logs" == 16 ]] || { log "STOP $tag bw logs=$logs/16"; return 1; }
  bw=$(read_bw_mib "$dir/fio.txt")

  out=$(bash "$GATE" --i1 "$dir/i1.tsv" 2>&1 || true)
  printf '%s\n' "$out" | tee -a "$OUT/probe-gate.log"
  nsb=$(awk -F'ns/B=' '/^I1 /{print $2; exit}' <<<"$out")
  [[ "$nsb" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log "STOP $tag ns/B 不可解析（判别器输出见 probe-gate.log）"; return 1; }
  dev=$(awk -v m="$nsb" -v ref="$REF_NSB" 'BEGIN{d=(m-ref)/ref*100; if(d<0)d=-d; printf "%.1f",d}')

  obj_post=$(object_count); echo "$obj_post" > "$dir/objects-post.txt"
  if [[ ! "$obj_post" =~ ^[0-9]+$ ]]; then
    log "STOP $tag objects-post 不可解析：${obj_post:-NA}"; return 1
  elif [[ "$obj_post" -gt "$obj_pre" ]]; then
    log "STOP $tag 只读任务但对象数上涨 $obj_pre -> $obj_post"; return 1
  elif [[ "$obj_post" -lt "$obj_pre" ]]; then
    shrink=$(( obj_pre - obj_post ))
    printf '%s\t%s\t%s\t%s\n' "$tag" "$obj_pre" "$obj_post" "$shrink" >> "$OUT/objects-shrink.tsv"
    if [[ "$shrink" -gt "$OBJ_SHRINK_MAX" ]]; then
      log "STOP $tag 对象数下跌 $shrink > $OBJ_SHRINK_MAX，疑似数据集被删"; return 1
    fi
    log "NOTE $tag 对象数下跌 $obj_pre -> $obj_post（-$shrink，后台回收，容差内，继续）"
  fi

  # ⚑ ns/B 只记录、不判定：档位就是本任务的观测对象，坏档不停机
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$it" "$ITER_PID" "$ITER_START" "${bw:-NA}" "$nsb" "$dev" "$TOL_NSB" >> "$OUT/iters.tsv"
  log "DONE $tag bw=${bw:-NA} MiB/s ns/B=$nsb dev=${dev}%（tol ${TOL_NSB}% 仅供参考，本任务不据此停机）objects=$obj_pre"

  bash "$SNAP" "$OUT" "$tag-complete" "$META" || true
  cleanup_mounts
  sleep "$GAP"
}

# ---------- 通用前置检查 ----------
md5sum "$BIN" "$GATE" "$SNAP" "$0" > "$OUT/input-md5.txt"
# 实际生效参数落盘：分析方据此判定该批数据能否用于 ns/B 对比
{ echo "mode=$MODE"; echo "iters=$ITERS"; echo "runtime=$RUNTIME"; echo "gap=$GAP"
  echo "recover_iter=$RECOVER_ITER"; echo "recover_sleep=$RECOVER_SLEEP"
  echo "ref_nsb=$REF_NSB"; echo "tol_nsb_reference_only=$TOL_NSB"
  echo "msgr_default_expected=$MSGR_DEFAULT"; echo "ioctx_default_expected=$IOCTX_DEFAULT"
  echo "out=$OUT"
  if [[ "$RUNTIME" != 180 || "$ITERS" != 8 ]]; then
    echo "SMOKE=YES  # ⚑ 非标定形状或非完整迭代数，仅可用于管路冒烟，数据不得进入分析"
  else
    echo "SMOKE=NO"
  fi; } > "$OUT/params.txt"
cat "$OUT/params.txt" | tee -a "$LOGFILE" >/dev/null
fio --version > "$OUT/fio-version.txt" 2>&1
grep -q '^fio-3\.28' "$OUT/fio-version.txt" || {
  log "STOP fio 版本必须为 3.28（实测 $(cat "$OUT/fio-version.txt")）"; exit 3; }
DISK_FREE_MIB=$(df -BM --output=avail "$(dirname "$OUT")" 2>/dev/null | awk 'NR==2{gsub(/M/,"");print $1}')
{ echo "avail_mib=$DISK_FREE_MIB"; df -h "$(dirname "$OUT")"; } > "$OUT/disk-preflight.txt" 2>&1
[[ "$DISK_FREE_MIB" =~ ^[0-9]+$ && "$DISK_FREE_MIB" -ge 5120 ]] || {
  log "STOP 落盘空间不足或不可解析：avail=${DISK_FREE_MIB:-NA} MiB < 5120"; exit 3; }
# 背景监控只清点不 kill；必须剔除自身进程树（B4-9）
self_tree() { local q=$$; while [[ -n "$q" && "$q" != 1 ]]; do echo "$q"; q=$(awk '{print $4}' "/proc/$q/stat" 2>/dev/null || true); done; }
SELF_PIDS="$(self_tree | paste -sd'|' -)"
pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh|nsbgate|t4[0-9]-' 2>/dev/null \
  | grep -vE "^(${SELF_PIDS:-0}) " > "$OUT/background-monitors-initial.txt" || true
wc -l < "$OUT/background-monitors-initial.txt" > "$OUT/background-monitors-count.txt"
echo "self_pids=$SELF_PIDS" > "$OUT/background-monitors-selfexcluded.txt"
# CPU 拓扑：H2 的判读底图
{ echo "=== lscpu ==="; lscpu
  echo "=== numactl -H ==="; numactl -H 2>/dev/null || echo "（无 numactl）"
  echo "=== cpu -> node/package ==="
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    printf '%s\tpkg=%s\n' "$(basename "$c")" "$(cat "$c/topology/physical_package_id" 2>/dev/null || echo NA)"
  done
  echo "=== node cpulist ==="
  for n in /sys/devices/system/node/node[0-9]*; do
    printf '%s\t%s\n' "$(basename "$n")" "$(cat "$n/cpulist" 2>/dev/null || echo NA)"
  done; } > "$OUT/cpu-topology.txt" 2>&1
snapshot_main_identity
verify_main_identity

# ---------- 模式：无状态清点 ----------
if [[ "$MODE" == "--preflight" ]]; then
  health_gate preflight
  PF_OBJ=$(object_count)
  { echo "bin=$BIN md5=$BIN_MD5_GOT"
    echo "fio=$(cat "$OUT/fio-version.txt")"
    echo "disk_avail_mib=$DISK_FREE_MIB"
    echo "objects=$PF_OBJ (闸门 <= $OBJ_START_MAX)"
    echo "background_monitors=$(cat "$OUT/background-monitors-count.txt") (应为 0)"
    echo "sysconf_md5=$SYSCONF_MD5_START"
    echo "期望系统默认线程：msgr-worker=$MSGR_DEFAULT io_context_pool=$IOCTX_DEFAULT"
    echo "迭代数=$ITERS，其中 iter$RECOVER_ITER 前空转 ${RECOVER_SLEEP}s"
    echo "预计时长≈$(( (ITERS*(RUNTIME+55)+RECOVER_SLEEP)/60 )) 分钟"
    echo "--- 业务挂载 ---"; cat "$OUT/main-mount-before.txt"
    echo "--- 专用挂载点占用 ---"; mount_line "$MNT_P" || echo "$MNT_P free"; mount_line "$MNT_Q" || echo "$MNT_Q free"
    echo "--- OSD perf dump 预探 ---"; } > "$OUT/preflight-summary.txt" 2>&1
  PF_FAIL=0
  for i in 0 1 2 3 4 5; do
    if [[ "$(timeout 15 sudo ceph tell "osd.$i" perf dump 2>/dev/null | wc -c)" -lt 1000 ]]; then
      PF_FAIL=$((PF_FAIL+1)); echo "osd.$i perf dump 空或超时" >> "$OUT/preflight-summary.txt"
    else echo "osd.$i OK" >> "$OUT/preflight-summary.txt"; fi
  done
  cat "$OUT/preflight-summary.txt"
  [[ "$PF_FAIL" == 0 ]] || { log "STOP OSD perf dump 预探失败 $PF_FAIL/6"; exit 3; }
  [[ "$PF_OBJ" =~ ^[0-9]+$ && "$PF_OBJ" -le "$OBJ_START_MAX" ]] || {
    log "STOP 起点 objects=${PF_OBJ:-NA} > $OBJ_START_MAX"; exit 5; }
  log "PREFLIGHT 完成；清单见 $OUT/preflight-summary.txt，交用户确认后再跑正式轮"
  exit 0
fi

# ---------- 模式：正式轮 ----------
printf 'iter\tio_pid\tstarttime\tbw_mib\tns_per_B\tabs_dev_pct\ttol_pct_ref_only\n' > "$OUT/iters.tsv"
printf 'iter\tio_pid\tstarttime\tmsgr_workers\tio_context\tdaemon_pid\n' > "$OUT/instances.tsv"
printf 'tag\tobj_pre\tobj_post\tshrink\n' > "$OUT/objects-shrink.tsv"

OSD_PROBE_FAIL=0
for i in 0 1 2 3 4 5; do
  if [[ "$(timeout 15 sudo ceph tell "osd.$i" perf dump 2>/dev/null | wc -c)" -lt 1000 ]]; then
    OSD_PROBE_FAIL=$((OSD_PROBE_FAIL+1)); echo "osd.$i perf dump 空或超时" >> "$OUT/osd-probe.txt"
  else echo "osd.$i OK" >> "$OUT/osd-probe.txt"; fi
done
[[ "$OSD_PROBE_FAIL" == 0 ]] || { log "STOP OSD perf dump 预探失败 $OSD_PROBE_FAIL/6"; exit 3; }

health_gate initial
START_OBJECTS=$(object_count); echo "$START_OBJECTS" > "$OUT/objects-initial.txt"
[[ "$START_OBJECTS" =~ ^[0-9]+$ && "$START_OBJECTS" -le "$OBJ_START_MAX" ]] || {
  log "STOP 起点 objects=${START_OBJECTS:-NA} > $OBJ_START_MAX；禁止自动 gc，回传给分析方"; exit 5; }
for m in "$MNT_P" "$MNT_Q"; do
  [[ -z "$(mount_line "$m" || true)" ]] || { log "STOP 专用挂载点已在使用：$m"; exit 6; }
  if [[ -d "$m" ]] && [[ -n "$(find "$m" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "STOP 专用目录非空，禁止 chown/覆盖：$m"; exit 6
  fi
done
sudo mkdir -p "$MNT_P"
sudo chown "$(id -u):$(id -g)" "$MNT_P"

log "T48 开始：$ITERS 次「新挂载 -> 判档形状 fio ${RUNTIME}s -> 卸载」，全程系统默认参数，不注入任何旋钮"
log "⚑ 坏档不停机：ns/B 只记录不判定，好坏两档都必须跑完 $ITERS 次"
for it in $(seq 1 "$ITERS"); do
  run_iter "$it" || exit 1
done

verify_main_identity
verify_sysconf
FINAL_OBJECTS=$(object_count); echo "$FINAL_OBJECTS" > "$OUT/objects-final.txt"
cleanup_mounts
cp "$CEPH_CONF_SYS" "$OUT/conf/ceph.conf.system-after"
verify_sysconf
log "ALL DONE；只回传原始目录 $OUT、压缩包 $OUT.tar.gz 及 md5，禁止现场下结论"
find "$OUT" -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > "$OUT/MANIFEST.md5"
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
md5sum "$OUT.tar.gz" > "$OUT.tar.gz.md5"
trap - EXIT INT TERM
