#!/usr/bin/env bash
# t49-read-concurrency-sweep.sh — 03-17d：读侧并发标度扫描（msgr 固定 8），只采集、不判定
#
# 2026-08-20 由 t47-librados-msgr-threads.sh（03-17c，md5 8b92e9a8f575bb2fc89c3d94a7d1dfd0）派生。
# t47 保持原样归档，本脚本只做 03-17d 任务书 §一 列出的 8 处改动，其余逐字不动：
#   1. 臂定义换成并发：ARMS=(J64 J96 J128)，ARM_JOBS=64/96/128；ARM_N 全部 = 8
#      （F58：数据面连接只有 6 条 = OSD 数，ms_async_op_threads > 6 不再增加并行度，取 8 只为防落位碰撞）。
#   2. CFG 不再是常量 P64，按臂取 P${jobs}；--numjobs 取自臂，其余 fio 参数逐字不变
#      （iodepth 保持 128：F59 实测在飞数 = numjobs，iodepth 不起作用，改它会破坏单变量）。
#   3. bw log 数量校验按臂 jobs 取值（64/96/128），不再硬比 64。
#   4. 批次锚点换成 J64 臂 vs 03-17c A8/P64 均值 5167.2（同二进制/同挂载参数/同 msgr=8/同 P64，
#      属完全一致配置，R16③ 满足）；±10% 打 NOTE，±25% 才 STOP。
#   5. ROUNDS 默认 3（3 臂 × 3 轮 = 9 次独立挂载）。
#   6. 臂序每轮左移一位（继续抵 F55 会话内慢漂移）。
#   7. pprof 采样条件从"第 2 轮的 A3/A8"改为"第 2 轮的 J64/J128"（对比低/高并发的排队结构）。
#   8. arm-covariates.tsv 增加 jobs 列，其余协变量列保留。
#   9. ⚑ 新增缺陷修复 B4-16：t47 用 `RUNTIME=180` 硬赋值，环境变量 RUNTIME 被静默吞掉，
#      03-17c 步骤 3 的 `RUNTIME=30` 冒烟其实按 180 s 跑了。本脚本改 ${RUNTIME:-180}（GAP 同理）。
#
# 继承 t47 的一切：ns/B 不停机（NSB_TOL=100000，verdict 恒 PASS，只取数值）；重复单位 = 独立挂载；
# ALL DONE 在压缩包之后（B4-13）；MANIFEST 相对路径（B4-15）；mount_pid 取实例进程（B4-8）；
# 背景监控清点剔除自身进程树（B4-9）；对象闸门单向（B4-10）。
#
# 红线：
#   - 只读；不运行 randwrite/randrw，不做 gc、compact、重启。
#   - ⛔ 绝不修改 /etc/ceph/ceph.conf，绝不执行 ceph config set。参数只经进程私有 conf + CEPH_CONF 注入。
#     脚本在起止两次记录 /etc/ceph/ceph.conf 的 md5，不一致立即 STOP。
#   - 判档 fio 也带 --readonly；数据集缺文件时必须 STOP，绝不允许由 fio 补写布局。
#   - 不卸载、不重挂、不改动业务挂载 /mnt/juicefs。
#   - 仅创建和卸载 /mnt/juicefs-p、/mnt/juicefs-q 两个专用挂载。
#   - 每个臂挂载后必须核对 msgr-worker 线程数等于 8（本任务它是常量，不是变量），不等即 STOP。
#   - io_context_pool 不再注入，但仍核对必须等于库默认 2（不等说明共享配置被改动，STOP）。
#   - 臂内冻结实例 PID+starttime，任一变化立即 STOP；每一轮都重挂（改线程数只能靠重挂生效）。
#   - 对象闸门口径固定为 Ceph pool juicefs-data objects（≤3,110,000），禁止改用 UsedInodes 等替代量。
#   - 不改 objecter_inflight_ops / objecter_inflight_op_bytes / --max-uploads / --max-fuse-io / --cache-size。
#   - ⛔ 并发只经 --numjobs 抬升；不改 iodepth，不扩数据集（read_test.*.0 恒 128 个，故 numjobs 上限 128）。
#
# 三种执行模式：
#   bash t49-read-concurrency-sweep.sh --preflight-msgr-only   # 只验证线程注入是否生效，不跑 fio
#   bash t49-read-concurrency-sweep.sh --preflight             # 无状态环境清点
#   ACK_SUDO_WRITES=YES bash t49-read-concurrency-sweep.sh     # 正式矩阵
#
# sudo 写入仅限：创建专用挂载目录、client+3 节点 drop_caches、卸载专用挂载。
# 只读 sudo：ceph health/pg/df、ceph tell osd.N perf dump、ss -tlnp（取 pprof 端口）。
set -euo pipefail
export LC_ALL=C

MODE="${1:-full}"
OUT="${OUT:-/tmp/production/opencode-t3.17d}"
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
TOL_NSB=18          # 仅写进表头留档；本脚本不据此停机（B4-11/B4-14）
NSB_TOL_DISABLED=100000  # 传给 t39-nsbgate.sh，使其 verdict 恒为 PASS —— 我们只要它算 ns/B，不要它判
OBJ_START_MAX=3110000
OBJ_SHRINK_MAX=1000 # 只读 run 内对象数允许的下跌幅度：后台 GC/trash 回收属无害，超此幅度才视为真删数据
RUNTIME="${RUNTIME:-180}"   # ⚑ B4-16：t47 里写成 RUNTIME=180 硬赋值，冒烟时的 RUNTIME=30 被静默吞掉
GAP="${GAP:-20}"
ANCHOR_MID=5167.2   # 03-17c A8/P64 四轮均值（msgr=8, numjobs=64），MiB/s —— 与 J64 臂完全同配置
ANCHOR_TOL_REPORT=10 # 只记录：J64 均值偏离超过它就打 NOTE
ANCHOR_TOL_STOP=25   # 才停机：F58 落位抽签使单次挂载天然散布 ±10%，窗口必须放宽
PREVERIFY_N=8
PREVERIFY_IO=0      # 不再注入 librados_thread_count（F57），只验 ms_async_op_threads
SKEW_EVENTS=0
SKEW_MAX_SEEN=0
HAVE_Q=0
PID_P=""; START_P=""; PID_Q=""; START_Q=""
ARM=""; ARM_TAG=""; ARM_THREADS_CUR=""; PASS=""

# 唯一旋钮：ARM_JOBS = fio --numjobs（= 在飞并发流数）。ms_async_op_threads 全臂恒为 8（F58 已封顶）。
# J64 既是并发下端锚点，也是与 03-17c A8/P64（均值 5167.2）对齐的批次锚点臂。
# J128 是数据集允许的上限（read_test.*.0 恰 128 个文件，再高会出现多 job 抢同一文件，破坏口径）。
# 每个臂在每一轮各挂载一次；ROUNDS 轮 = 每臂 ROUNDS 个独立挂载样本。
declare -a ARMS=(J64 J96 J128)
declare -A ARM_N=([J64]=8 [J96]=8 [J128]=8)
declare -A ARM_JOBS=([J64]=64 [J96]=96 [J128]=128)
ROUNDS="${ROUNDS:-3}"
IOCTX_DEFAULT=2

case "$MODE" in
  full|--preflight|--preflight-msgr-only) ;;
  *) echo "REFUSE: 未知模式 $MODE（可选 --preflight-msgr-only | --preflight | 空=正式矩阵）" >&2; exit 2 ;;
esac
if [[ "$MODE" == full ]]; then
  [[ "${ACK_SUDO_WRITES:-}" == YES ]] || {
    echo "REFUSE: 先审阅脚本中的 sudo 写操作，再以 ACK_SUDO_WRITES=YES 执行" >&2
    exit 2
  }
fi
[[ "$OUT" == /tmp/* && "$OUT" != /tmp ]] || {
  echo "REFUSE: OUT 必须是 /tmp 下的非根目录：$OUT" >&2
  exit 2
}
for f in "$BIN" "$GATE" "$SNAP" "$CEPH_CONF_SYS"; do
  [[ -f "$f" ]] || { echo "STOP 缺文件：$f" >&2; exit 2; }
done
BIN_MD5_GOT=$(md5sum "$BIN" | awk '{print $1}')
[[ "$BIN_MD5_GOT" == "$BIN_MD5_WANT" ]] || {
  echo "STOP 二进制 md5 不符：want $BIN_MD5_WANT got $BIN_MD5_GOT（03-17 必须与 03-16 同一构建）" >&2
  exit 3
}
if [[ "$MODE" == full ]]; then
  if [[ -e "$OUT/wrapper.log" ]] || [[ -n "$(find "$OUT" -maxdepth 1 -name 'run-*' -print -quit 2>/dev/null)" ]]; then
    echo "STOP: OUT 已含正式轮证据，禁止混入；请保留现场并由分析方指定新 OUT：$OUT" >&2
    exit 2
  fi
  [[ ! -e "$OUT.tar.gz" && ! -e "$OUT.tar.gz.md5" ]] || {
    echo "STOP: 目标归档已存在，禁止覆盖：$OUT.tar.gz{,.md5}" >&2
    exit 2
  }
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
  local now
  now="$(sysconf_md5)"
  printf '%s\t%s\n' "$(date +%s)" "$now" >> "$OUT/conf/sysconf-checks.tsv"
  [[ "$now" == "$SYSCONF_MD5_START" ]] || {
    log "STOP /etc/ceph/ceph.conf 被修改：start=$SYSCONF_MD5_START now=$now"; return 1;
  }
}

proc_fields() { # $1=pid → starttime utime stime threads；兼容 comm 中空格/右括号
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1;
        print f[20],f[12],f[13],f[18]}' "/proc/$1/stat" 2>/dev/null
}

mount_pid() { # $1=精确挂载点 → 真正服务 IO 的那个进程
  # juicefs mount -d 会留下两个进程：ppid=1 的守护父进程（约 34 线程、无 librados 线程）
  # 和它的子进程（约 46~56 线程、持有 msgr-worker）。2026-08-20 在 157 实测确认，
  # 只有子进程里存在 librados AsyncMessenger worker；取错进程会让 msgr 闸门永远读到 0，
  # 也会让 proc 采样落在一个不干活的进程上（03-16 的 proc-*.tsv 即如此）。
  # 选择规则：候选集中 ppid 也属于候选集的那个（即最深的子进程）。
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

mount_ppid() { # $1=挂载点 → 守护父进程 PID（仅留档，不参与冻结）
  local m="$1" cands first
  cands=$(pgrep -af juicefs 2>/dev/null | awk -v m="$m" '$0 ~ / mount / && $NF==m {print $1}')
  first=$(head -1 <<<"$cands")
  [[ -n "$first" ]] || { echo NA; return 0; }
  awk '{print $4}' "/proc/$first/stat" 2>/dev/null || echo NA
}

mount_line() { # $1=挂载点
  awk -v m="$1" '$2==m {print; exit}' /proc/mounts
}

ioctx_count() { # $1=pid → librados objecter 完成线程数（io_context_pool，受 librados_thread_count 控制）
  # 2026-08-20 在 157 实测：默认 2；注入 librados_thread_count=8 得 8（进程总线程 47 -> 53）。
  local n
  n=$(cat "/proc/$1/task/"*/comm 2>/dev/null | grep -c '^io_context_pool' || true)
  echo "${n:-0}"
}

msgr_count() { # $1=pid → librados AsyncMessenger worker 线程数
  # 直接读 /proc/<pid>/task/*/comm。2026-08-20 在 157 实测：默认=3、注入 1/3/6/12 各得 1/3/6/12。
  local n
  n=$(cat "/proc/$1/task/"*/comm 2>/dev/null | grep -c '^msgr-worker' || true)
  echo "${n:-0}"
}

read_bw_mib() { # $1=fio 输出文件 → READ 汇总带宽，统一换算成 MiB/s
  awk '/^[[:space:]]+READ: bw=/{
        if (match($0,/bw=[0-9.]+[KMG]iB\/s/)) {
          s=substr($0,RSTART+3,RLENGTH-3); v=s+0;
          if (s ~ /KiB/) v/=1024; else if (s ~ /GiB/) v*=1024;
          printf "%.1f", v; exit
        }}' "$1" 2>/dev/null
}

write_arm_conf() { # $1=ms_async_op_threads $2=librados_thread_count（0=不注入）
  # 两者都为 0 时返回空串，表示完全用系统默认。
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
  printf 'line=%q\npid=%s\nstarttime=%s\n' "$MAIN_LINE" "${MAIN_PID:-NA}" "${MAIN_START:-NA}" \
    > "$OUT/main-mount-before.txt"
}

verify_main_identity() {
  local line pid st
  line="$(mount_line "$MAIN_MNT" || true)"; pid="$(mount_pid "$MAIN_MNT" || true)"; st=""
  [[ -z "$pid" ]] || st="$(proc_fields "$pid" | awk '{print $1}')"
  printf 'line=%q\npid=%s\nstarttime=%s\n' "$line" "${pid:-NA}" "${st:-NA}" \
    >> "$OUT/main-mount-after-checks.txt"
  [[ "$line" == "$MAIN_LINE" && "$pid" == "$MAIN_PID" && "$st" == "$MAIN_START" ]] || {
    log "STOP 业务挂载身份变化；本脚本不再继续"; return 1;
  }
}

object_count() {
  # F45 实验有效性闸门指标 = Ceph pool juicefs-data 的对象数，口径与 probe/env-snapshot.sh 完全一致。
  # ⛔ 禁止用 UsedSpace / UsedInodes / TiKV disk size 替代（V02-PRE §十一、V02 §5 已明文立规）。
  local raw
  raw=$(timeout 30 sudo ceph df --format=json 2>/dev/null || true)
  printf '%s\t%s\n' "$(date +%s)" "$raw" >> "$OUT/objects-raw.jsonl"
  printf '%s' "$raw" | python3 -c \
    "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data']; assert len(p)==1; print(p[0]['stats']['objects'])" \
    2>/dev/null || true
}

health_gate() { # $1=tag；唯一告警是时钟漂移时"记录并继续"，其余一律 STOP（判据见 03-16 §2.1c）
  local tag="$1" h wrn nwrn skew
  { echo "=== $tag $(date '+%F %T') ==="; sudo ceph health detail; sudo ceph pg stat; } \
    > "$OUT/health-$tag.txt" 2>&1
  h=$(grep -m1 '^HEALTH_' "$OUT/health-$tag.txt" || true)
  grep -q '^HEALTH_OK' <<<"$h" && return 0
  nwrn=$(grep -cE '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  wrn=$(grep -m1 -E '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  { [[ "$nwrn" == 1 ]] && grep -qiE '^\[(WRN|ERR)\].*clock skew' "$OUT/health-$tag.txt"; } || {
    log "STOP $tag Ceph 非 HEALTH_OK：$h（告警条数=$nwrn，首条=$wrn）"; return 1;
  }
  skew=$(grep -oE 'clock skew [0-9]+(\.[0-9]+)?s' "$OUT/health-$tag.txt" \
    | sed -E 's/clock skew ([0-9.]+)s/\1/' | sort -g | tail -1)
  [[ "$skew" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
    log "STOP $tag 时钟漂移告警但无法解析漂移值，原文形态异常：$wrn"; return 1;
  }
  awk -v s="$skew" 'BEGIN{exit !(s<=0.5)}' || {
    log "STOP $tag 时钟漂移 ${skew}s > 0.5s 上限，超出 NTP 锯齿可解释范围"; return 1;
  }
  SKEW_EVENTS=$((SKEW_EVENTS+1))
  awk -v a="$skew" -v b="$SKEW_MAX_SEEN" 'BEGIN{exit !(a>b)}' && SKEW_MAX_SEEN="$skew"
  timeout 15 sudo ceph time-sync-status > "$OUT/time-sync-$tag.json" 2>&1 || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$tag" "$skew" "$SKEW_EVENTS" "$wrn" \
    >> "$OUT/skew-events.tsv"
  log "NOTE $tag 唯一告警为时钟漂移 ${skew}s（累计 $SKEW_EVENTS 次，峰值 ${SKEW_MAX_SEEN}s），记录后继续"
  return 0
}

drop_caches_all() {
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
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
  local rc=$?
  local p
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

mount_one() { # $1=挂载点 $2=label $3=私有 conf 路径（空=系统默认） $4=期望 msgr 数 $5=期望 io_context 数
  local m="$1" lab="$2" conf="$3" want="$4" want_io="$5" pid st mr got got_io
  if [[ -n "$conf" ]]; then
    CEPH_CONF="$conf" "$BIN" mount -d "${OPTS[@]}" "$META" "$m" >> "$OUT/mount.log" 2>&1
  else
    "$BIN" mount -d "${OPTS[@]}" "$META" "$m" >> "$OUT/mount.log" 2>&1
  fi
  sleep 5
  [[ -n "$(mount_line "$m" || true)" ]] || { log "STOP $lab mount failed: $m"; return 1; }
  mr=$(mount_line "$m" | grep -o 'max_read=[0-9]*' | cut -d= -f2)
  [[ "$mr" == 262144 ]] || { log "STOP $lab max_read=${mr:-NA} !=262144"; return 1; }
  pid=$(mount_pid "$m"); st=$(proc_fields "$pid" | awk '{print $1}')
  [[ -n "$pid" && -n "$st" ]] || { log "STOP $lab 无法解析 mount PID/starttime"; return 1; }
  # 核心闸门：两个旋钮的线程数都必须等于期望值，否则 CEPH_CONF 注入没生效
  ps -T -p "$pid" -o tid=,comm= > "$OUT/msgr-threads-$lab.txt" 2>&1 || true
  got=$(msgr_count "$pid"); got_io=$(ioctx_count "$pid")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$lab" "$m" "${conf:-SYSTEM_DEFAULT}" "$want" "$got" "$want_io" "$got_io" \
    >> "$OUT/msgr-threads.tsv"
  [[ "$got" == "$want" ]] || {
    log "STOP $lab msgr-worker 线程数 $got != 期望 $want（CEPH_CONF 注入未生效，禁止自行改注入方式后继续）"
    return 1
  }
  [[ "$got_io" == "$want_io" ]] || {
    log "STOP $lab io_context_pool 线程数 $got_io != 期望 $want_io（librados_thread_count 未生效）"
    return 1
  }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$lab" "$m" "$pid" "$st" "$mr" "$(mount_ppid "$m")" >> "$OUT/instances.tsv"
  log "MOUNT $lab $m io_pid=$pid daemon_pid=$(mount_ppid "$m") msgr-worker=$got io_context=$got_io conf=${conf:-SYSTEM_DEFAULT}"
}

sample_stats() { # $1=mount $2=file
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
  COLLECTOR_PIDS+=("$!")
  CHILD_PIDS+=("$!")
}

sample_proc() { # $1=pid $2=file
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
  COLLECTOR_PIDS+=("$!")
  CHILD_PIDS+=("$!")
}

# ---------- 逐线程 CPU 采样（从 t48 原样移植；T48 已在 157 用 209 线程进程与 ps psr 对账 209/209 一致）----------
# /proc/<tid>/stat 去掉 "pid (" 与 ") " 后：rest[12]=utime rest[13]=stime rest[37]=processor。
# comm 可能含空格与右括号，必须按最后一个 ") " 切分，不能按空格分列。
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

sample_threads() { # $1=pid $2=file；每 5s 一轮
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
  COLLECTOR_PIDS+=("$!")
  CHILD_PIDS+=("$!")
}

# msgr-worker 逐线程 CPU 离散度（协变量，不做判定）。T48：bw~CV r=-0.9907。
worker_cv() { # $1=threads-series 文件 → "cv_pct max_core_pct sum_core n_worker"
  awk -F'\t' 'NR>1 && $3 ~ /^msgr-worker/ {
      k=$3; c=$4+$5;
      if (!(k in first)) {first[k]=c; t0[k]=$1}
      last[k]=c; t1[k]=$1
    }
    END{
      n=0; s=0; el=0
      for (k in first) { d[k]=(last[k]-first[k])/100; s+=d[k]; n++
        if (t1[k]-t0[k] > el) el=t1[k]-t0[k] }
      if (n==0 || el<=0) { printf "NA\tNA\tNA\t0"; exit }
      m=s/n; v=0; mx=0
      for (k in first) { v+=(d[k]-m)^2; if (d[k]>mx) mx=d[k] }
      printf "%.1f\t%.1f\t%.2f\t%d", (m>0? sqrt(v/n)/m*100 : 0), mx/el*100, s/el, n
    }' "$1" 2>/dev/null || printf 'NA\tNA\tNA\t0'
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
  COLLECTOR_PIDS+=("$!")
  CHILD_PIDS+=("$!")
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

pprof_port() { # $1=pid
  sudo ss -tlnp 2>/dev/null | awk -v n="pid=$1," 'index($0,n){print $4; exit}' | sed -E 's/.*:([0-9]+)$/\1/'
}

pprof_after_120() { # $1=side $2=pid $3=tag
  local side="$1" pid="$2" tag="$3" port
  sleep 120
  port=$(pprof_port "$pid" || true)
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "pprof port missing side=$side pid=$pid" >> "$OUT/pprof-errors.log"; return 0; }
  timeout 15 curl -fsS "http://127.0.0.1:$port/debug/pprof/goroutine?debug=2" \
    > "$OUT/pprof-goroutine-$tag-$side.txt" 2>> "$OUT/pprof-errors.log" || true
}

host_state() { # $1=输出文件
  { uptime; free -m; { ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -25; } || true;
    echo "--- background monitors ---";
    pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh' || true;
    echo "--- fio 进程（应只有本任务）---"; pgrep -af fio || true;
    echo "--- 落盘空间 ---"; df -h "$OUT" | tail -1; } > "$1"
}

verify_arm() {
  local p q ps qs
  p=$(mount_pid "$MNT_P" || true)
  [[ -n "$p" ]] || { log "STOP $ARM_TAG 专用挂载 P 消失"; return 1; }
  ps=$(proc_fields "$p" | awk '{print $1}')
  if [[ "$HAVE_Q" == 1 ]]; then
    q=$(mount_pid "$MNT_Q" || true)
    [[ -n "$q" ]] || { log "STOP $ARM_TAG 专用挂载 Q 消失"; return 1; }
    qs=$(proc_fields "$q" | awk '{print $1}')
  else
    q=NA; qs=NA
    [[ -z "$(mount_line "$MNT_Q" || true)" ]] || {
      log "STOP $ARM_TAG 单挂载臂却发现 Q 已挂载"; return 1;
    }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ARM_TAG" "$p" "$ps" "$q" "$qs" \
    "$(msgr_count "$p")" >> "$OUT/instance-checks.tsv"
  [[ "$p" == "$PID_P" && "$ps" == "$START_P" ]] || {
    log "STOP $ARM_TAG P 实例漂移 got $p/$ps want $PID_P/$START_P"; return 1;
  }
  if [[ "$HAVE_Q" == 1 ]]; then
    [[ "$q" == "$PID_Q" && "$qs" == "$START_Q" ]] || {
      log "STOP $ARM_TAG Q 实例漂移 got $q/$qs want $PID_Q/$START_Q"; return 1;
    }
  fi
  verify_sysconf
  verify_main_identity
}

check_dataset() { # $1=arm-tag；P 必查，Q 仅双挂载臂
  local atag="$1" fp fq fmp fmq
  fp=$(find "$MNT_P/test_dir" -maxdepth 1 -type f -name 'read_test.*.0' | wc -l)
  fmp=$(find "$MNT_P/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' | wc -l)
  if [[ "$HAVE_Q" == 1 ]]; then
    fq=$(find "$MNT_Q/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' | wc -l)
    fmq=$(find "$MNT_Q/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' | wc -l)
  else
    fq=NA; fmq=NA
  fi
  printf '%s\tread_test=%s\trw_test=%s\tmseqread_P=%s\tmseqread_Q=%s\n' \
    "$atag" "$fp" "$fq" "$fmp" "$fmq" >> "$OUT/dataset-check.tsv"
  [[ "$fp" == 128 ]] || { log "STOP $atag 数据集不完整：read_test=$fp/128"; return 1; }
  [[ "$fmp" == 16 ]] || { log "STOP $atag 判档数据集不完整：mseqread_P=$fmp/16"; return 1; }
  if [[ "$HAVE_Q" == 1 ]]; then
    [[ "$fq" == 128 ]] || { log "STOP $atag 数据集不完整：rw_test=$fq/128"; return 1; }
    [[ "$fmq" == 16 ]] || { log "STOP $atag 判档数据集不完整：mseqread_Q=$fmq/16"; return 1; }
  fi
}

prepare_arm() { # $1=臂名（J64/J96/J128） $2=轮次
  local arm="$1" pass="$2" n conf want want_io
  ARM="$arm"; PASS="$pass"; ARM_TAG="T49D-$arm-r$pass"
  cleanup_mounts
  HAVE_Q=0; n="${ARM_N[$arm]}"
  conf="$(write_arm_conf "$n" 0)"; want="$n"; want_io="$IOCTX_DEFAULT"
  ARM_THREADS_CUR="msgr$want/ioctx$want_io"
  mount_one "$MNT_P" "$ARM_TAG-P" "$conf" "$want" "$want_io" || return 1
  check_dataset "$ARM_TAG" || return 1
  PID_P=$(mount_pid "$MNT_P"); START_P=$(proc_fields "$PID_P" | awk '{print $1}')
  PID_Q=NA; START_Q=NA
  printf 'P\t%s\t%s\nQ\t%s\t%s\n' "$PID_P" "$START_P" "$PID_Q" "$START_Q" > "$OUT/frozen-$ARM_TAG.tsv"
  # ⚑ 不再做 ns/B 判档停机（B4-11/B4-12/B4-14）：ns/B 从本轮 fio 的 i1 里算，只当协变量。
  bash "$SNAP" "$OUT" "$ARM_TAG-active" "$META"
  verify_arm || return 1
  log "ARM READY $ARM_TAG threads=$ARM_THREADS_CUR P=$PID_P/$START_P"
}

run_config() { # $1=rep $2=cfg（03-17d 为 P64/P96/P128，jobs 由臂决定）
  local rep="$1" cfg="$2" jobs side_q=0 tag dir rc_p=NA rc_q=NA obj_pre obj_post logs_p logs_q bw_p bw_q
  local -a cmd_p=() cmd_q=()
  jobs=${cfg//[^0-9]/}
  [[ "$cfg" == C* ]] && side_q=1
  [[ "$side_q" == 0 || "$HAVE_Q" == 1 ]] || { log "STOP $cfg 需要 Q 挂载但当前臂未挂 Q"; return 1; }
  tag="$ARM_TAG-rep$rep-$cfg"; dir="$OUT/run-$tag"; mkdir -p "$dir"
  log "START $tag（只采集；禁止现场判定）threads=$ARM_THREADS_CUR"
  health_gate "$tag-pre"; verify_arm
  obj_pre=$(object_count); echo "$obj_pre" > "$dir/objects-pre.txt"
  [[ "$obj_pre" =~ ^[0-9]+$ && "$obj_pre" -le "$OBJ_START_MAX" ]] || {
    log "STOP $tag objects=${obj_pre:-NA} > $OBJ_START_MAX 或不可解析"; return 1;
  }
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
  fi
  sample_net "$dir/net.tsv"
  PPROF_P=""; PPROF_Q=""
  # pprof 只在第 2 轮的 J64/J128 取，用于对比 64 vs 128 并发下的排队结构
  if [[ "$PASS" == 2 && ( "$ARM" == J64 || "$ARM" == J128 ) ]]; then
    pprof_after_120 P "$PID_P" "$tag" & PPROF_P=$!; CHILD_PIDS+=("$!")
  fi
  FIO_P=""; FIO_Q=""
  cmd_p=(timeout "$((RUNTIME+120))" fio --directory="$MNT_P/test_dir" --name=read_test --filesize=1G --size=1G --bs=256k
    --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$jobs" --direct=1
    --fallocate=none --openfiles=128 --readonly --group_reporting --time_based --runtime="$RUNTIME"
    --write_bw_log="$OUT/bwlog/$tag-P" --log_avg_msec=1000)
  printf '%q ' "${cmd_p[@]}" > "$dir/command-P.txt"; printf '\n' >> "$dir/command-P.txt"
  (
    date +%s%N > "$dir/fio-P-start-ns.txt"
    exec "${cmd_p[@]}"
  ) > "$dir/fio-P.txt" 2>&1 & FIO_P=$!; CHILD_PIDS+=("$!")
  if [[ "$side_q" == 1 ]]; then
    cmd_q=(timeout "$((RUNTIME+120))" fio --directory="$MNT_Q/test_dir" --name=rw_test --filesize=1G --size=1G --bs=256k
      --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$jobs" --direct=1
      --fallocate=none --openfiles=128 --readonly --group_reporting --time_based --runtime="$RUNTIME"
      --write_bw_log="$OUT/bwlog/$tag-Q" --log_avg_msec=1000)
    printf '%q ' "${cmd_q[@]}" > "$dir/command-Q.txt"; printf '\n' >> "$dir/command-Q.txt"
    (
      date +%s%N > "$dir/fio-Q-start-ns.txt"
      exec "${cmd_q[@]}"
    ) > "$dir/fio-Q.txt" 2>&1 & FIO_Q=$!; CHILD_PIDS+=("$!")
  fi
  if wait "$FIO_P"; then rc_p=0; else rc_p=$?; fi
  [[ -z "$FIO_Q" ]] || { if wait "$FIO_Q"; then rc_q=0; else rc_q=$?; fi; }
  [[ -z "$PPROF_P" ]] || { wait "$PPROF_P" || true; }
  [[ -z "$PPROF_Q" ]] || { wait "$PPROF_Q" || true; }
  thread_snapshot "$PID_P" "$dir/threads-post.tsv"
  stop_collectors
  ps -T -p "$PID_P" -o tid=,comm= > "$dir/msgr-threads-P-post.txt" 2>&1 || true
  osd_snapshot "$tag" post
  health_gate "$tag-post"; verify_arm
  obj_post=$(object_count); echo "$obj_post" > "$dir/objects-post.txt"
  host_state "$dir/host-state-post.txt"
  logs_p=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'-P_bw.*.log' | wc -l)
  logs_q=0
  [[ "$side_q" == 0 ]] || logs_q=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'-Q_bw.*.log' | wc -l)
  bw_p=$(read_bw_mib "$dir/fio-P.txt"); bw_q=""
  [[ "$side_q" == 0 ]] || bw_q=$(read_bw_mib "$dir/fio-Q.txt")
  {
    printf 'tag=%s arm=%s threads=%s pass=%s rep=%s cfg=%s jobs=%s rc_p=%s rc_q=%s bwlogs_p=%s bwlogs_q=%s\n' \
      "$tag" "$ARM" "$ARM_THREADS_CUR" "$PASS" "$rep" "$cfg" "$jobs" "$rc_p" "$rc_q" "$logs_p" "$logs_q"
    printf 'P_dataset=%s\nQ_dataset=%s\n' "$MNT_P/test_dir/read_test.*.0" \
      "$( [[ "$side_q" == 1 ]] && echo "$MNT_Q/test_dir/rw_test.*.0" || echo NA )"
    printf 'msgr_worker_P=%s io_context_P=%s\n' "$(msgr_count "$PID_P")" "$(ioctx_count "$PID_P")"
    [[ "$HAVE_Q" == 0 ]] || printf 'msgr_worker_Q=%s io_context_Q=%s\n' "$(msgr_count "$PID_Q")" "$(ioctx_count "$PID_Q")"
    grep -E '^\s+READ: bw=' "$dir/fio-P.txt" || true
    [[ ! -f "$dir/fio-Q.txt" ]] || grep -E '^\s+READ: bw=' "$dir/fio-Q.txt" || true
  } > "$dir/run-meta.txt"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$ARM" "$ARM_THREADS_CUR" "$PASS" "$rep" "$cfg" "$rc_p" "$rc_q" "${bw_p:-NA}" "${bw_q:-NA}" \
    >> "$OUT/progress.tsv"
  [[ "$rc_p" == 0 ]] && [[ "$rc_q" == 0 || "$rc_q" == NA ]] || {
    log "STOP $tag fio rc P=$rc_p Q=$rc_q"; return 1;
  }
  { grep -qE '^\s+READ: bw=' "$dir/fio-P.txt" && [[ "$logs_p" == "$jobs" ]]; } || {
    log "STOP $tag P 证据不完整：READ 行或 bw logs=$logs_p/$jobs"; return 1;
  }
  [[ "$side_q" == 0 ]] || { grep -qE '^\s+READ: bw=' "$dir/fio-Q.txt" && [[ "$logs_q" == "$jobs" ]]; } || {
    log "STOP $tag Q 证据不完整：READ 行或 bw logs=$logs_q/$jobs"; return 1;
  }
  # 对象闸门为单向：只拦"上涨"（只读任务生成对象、消耗 F45 窗口）。
  # "下跌"是 JuiceFS trash / Ceph 后台回收上一轮 cleanup 尾巴，与验收无关，只记录不停机；
  # 但跌幅超过 OBJ_SHRINK_MAX 视为可能真删数据，STOP。
  if [[ ! "$obj_post" =~ ^[0-9]+$ ]]; then
    log "STOP $tag objects-post 不可解析：${obj_post:-NA}"; return 1
  elif [[ "$obj_post" -gt "$obj_pre" ]]; then
    log "STOP $tag 只读任务但对象数上涨 $obj_pre -> $obj_post"; return 1
  elif [[ "$obj_post" -lt "$obj_pre" ]]; then
    local shrink=$(( obj_pre - obj_post ))
    printf '%s\t%s\t%s\t%s\n' "$tag" "$obj_pre" "$obj_post" "$shrink" >> "$OUT/objects-shrink.tsv"
    if [[ "$shrink" -gt "$OBJ_SHRINK_MAX" ]]; then
      log "STOP $tag 对象数下跌 $shrink > $OBJ_SHRINK_MAX，疑似数据集被删"; return 1
    fi
    log "NOTE $tag 对象数下跌 $obj_pre -> $obj_post（-$shrink，后台回收，容差内，继续）"
  fi
  # 批次锚点样本：J64 臂（msgr=8, numjobs=64）与 03-17c A8/P64 完全同配置
  if [[ "$ARM" == J64 && "$cfg" == P64 ]]; then
    printf '%s\t%s\n' "$tag" "$bw_p" >> "$OUT/anchor-j64.tsv"
  fi
  # ---------- 协变量（只记录，绝不据此停机）----------
  # 1) msgr-worker 逐线程 CPU：CV / 最忙 worker 占单核 / 三线程合计核数 / 实际 worker 数
  # 2) ns/B：借 t39-nsbgate.sh 算，但把 NSB_TOL 抬到 100000 使其 verdict 恒 PASS —— 只要数不要判（B4-14）
  local cvline nsb_out nsb
  cvline=$(worker_cv "$dir/threads-series.tsv")
  nsb_out=$(NSB_TOL="$NSB_TOL_DISABLED" NSB_REF="$REF_NSB" bash "$GATE" --i1 "$dir/i1-P.tsv" 2>&1 || true)
  printf '%s\n' "$nsb_out" >> "$OUT/probe-gate.log"
  nsb=$(awk -F'ns/B=' '/^I1 /{print $2; exit}' <<<"$nsb_out" | awk '{print $1}')
  [[ "$nsb" =~ ^[0-9]+([.][0-9]+)?$ ]] || nsb=NA
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tag" "$ARM" "${ARM_N[$ARM]}" "$jobs" "$PASS" "${bw_p:-NA}" "$nsb" "$cvline" >> "$OUT/arm-covariates.tsv"
  log "COVAR $tag msgr=${ARM_N[$ARM]} jobs=$jobs bw=${bw_p:-NA} ns/B=$nsb worker[cv%/max%core/sum_core/n]=$cvline"
  log "DONE $tag rc P=$rc_p Q=$rc_q bw_P=${bw_p:-NA} bw_Q=${bw_q:-NA} objects=$obj_pre"
  sleep "$GAP"
}

anchor_check() { # $1=期望样本数 $2=停机容差百分比 $3=阶段名
  local want="$1" tol="$2" stage="$3" n mean lo hi rlo rhi
  n=$(wc -l < "$OUT/anchor-j64.tsv" 2>/dev/null || echo 0)
  [[ "$n" -ge "$want" ]] || { log "STOP 锚点样本不足：$n < $want（$stage）"; return 1; }
  mean=$(awk -F'\t' '{s+=$2;c++} END{if(c)printf "%.1f",s/c}' "$OUT/anchor-j64.tsv")
  lo=$(awk -v m="$ANCHOR_MID" -v t="$tol" 'BEGIN{printf "%.1f",m*(1-t/100)}')
  hi=$(awk -v m="$ANCHOR_MID" -v t="$tol" 'BEGIN{printf "%.1f",m*(1+t/100)}')
  rlo=$(awk -v m="$ANCHOR_MID" -v t="$ANCHOR_TOL_REPORT" 'BEGIN{printf "%.1f",m*(1-t/100)}')
  rhi=$(awk -v m="$ANCHOR_MID" -v t="$ANCHOR_TOL_REPORT" 'BEGIN{printf "%.1f",m*(1+t/100)}')
  printf '%s\tn=%s\tmean=%s\tstop_lo=%s\tstop_hi=%s\treport_lo=%s\treport_hi=%s\n' \
    "$stage" "$n" "$mean" "$lo" "$hi" "$rlo" "$rhi" >> "$OUT/anchor-check.tsv"
  awk -v v="$mean" -v a="$rlo" -v b="$rhi" 'BEGIN{exit !(v>=a && v<=b)}' \
    || log "NOTE 批次锚点偏离 ±${ANCHOR_TOL_REPORT}% 窗口（$stage）：J64 mean=$mean 不在 $rlo~$rhi；F58 落位抽签方差可致，只记录不停机"
  awk -v v="$mean" -v a="$lo" -v b="$hi" 'BEGIN{exit !(v>=a && v<=b)}' || {
    log "STOP 批次锚点严重失配（$stage）：J64 mean=$mean 不在 $lo~$hi（03-17c A8/P64 基准 $ANCHOR_MID ±${tol}%）；臂间比较不可用"
    return 1
  }
  log "锚点通过（$stage）：J64 n=$n mean=$mean，停机窗口 $lo~$hi"
}

run_arm() { # $1=臂 $2=轮次；每次调用 = 一次独立挂载 + 一次 fio（F56/F58：重复单位必须是挂载）
  prepare_arm "$1" "$2" || return 1
  run_config 1 "P${ARM_JOBS[$1]}" || return 1
  bash "$SNAP" "$OUT" "$ARM_TAG-complete" "$META"
  cleanup_mounts
}

# ---------- 通用前置检查（三种模式共用） ----------
md5sum "$BIN" "$GATE" "$SNAP" "$0" > "$OUT/input-md5.txt"
fio --version > "$OUT/fio-version.txt" 2>&1
grep -q '^fio-3\.28' "$OUT/fio-version.txt" || {
  log "STOP fio 版本必须为 3.28（实测 $(cat "$OUT/fio-version.txt")）：更高版本对 --name+--directory+numjobs 的默认文件名解析不同，会与 --readonly 冲突"; exit 3;
}
DISK_FREE_MIB=$(df -BM --output=avail "$(dirname "$OUT")" 2>/dev/null | awk 'NR==2{gsub(/M/,"");print $1}')
echo "avail_mib=$DISK_FREE_MIB" > "$OUT/disk-preflight.txt"
df -h "$(dirname "$OUT")" >> "$OUT/disk-preflight.txt" 2>&1
[[ "$DISK_FREE_MIB" =~ ^[0-9]+$ && "$DISK_FREE_MIB" -ge 5120 ]] || {
  log "STOP 落盘空间不足或不可解析：avail=${DISK_FREE_MIB:-NA} MiB < 5120"; exit 3;
}
# 背景监控只清点，绝不 kill：kill 未知/他人进程超出本任务授权。
# 必须剔除本脚本自身的进程树：模式串里的 t4[0-9]- 会命中 t47 自己，
# 否则清点恒为非 0（03-16 的 count=2 就是这种自匹配，其实基线是干净的）。
self_tree() { local q=$$; while [[ -n "$q" && "$q" != 1 ]]; do echo "$q"; q=$(awk '{print $4}' "/proc/$q/stat" 2>/dev/null || true); done; }
SELF_PIDS="$(self_tree | paste -sd'|' -)"
pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh|nsbgate|t4[0-9]-' 2>/dev/null \
  | grep -vE "^(${SELF_PIDS:-0}) " > "$OUT/background-monitors-initial.txt" || true
wc -l < "$OUT/background-monitors-initial.txt" > "$OUT/background-monitors-count.txt"
echo "self_pids=$SELF_PIDS" > "$OUT/background-monitors-selfexcluded.txt"
snapshot_main_identity
verify_main_identity

# ---------- 模式：只验证线程注入 ----------
if [[ "$MODE" == "--preflight-msgr-only" ]]; then
  # 一次把两个旋钮都验：msgr（收发线程）与 io_context_pool（完成线程）
  log "PREVERIFY 线程注入：请求 ms_async_op_threads=$PREVERIFY_N（librados_thread_count 不注入，期望库默认 $IOCTX_DEFAULT）"
  [[ -z "$(mount_line "$MNT_P" || true)" ]] || { log "STOP 专用挂载点已在使用：$MNT_P"; exit 6; }
  sudo mkdir -p "$MNT_P"
  sudo chown "$(id -u):$(id -g)" "$MNT_P"
  PRE_CONF="$(write_arm_conf "$PREVERIFY_N" "$PREVERIFY_IO")"
  cp "$PRE_CONF" "$OUT/conf/preverify.conf"
  CEPH_CONF="$PRE_CONF" "$BIN" mount -d "${OPTS[@]}" "$META" "$MNT_P" >> "$OUT/mount.log" 2>&1
  sleep 5
  PRE_PID="$(mount_pid "$MNT_P" || true)"
  PRE_GOT=NA; PRE_GOT_IO=NA
  [[ -z "$PRE_PID" ]] || { PRE_GOT="$(msgr_count "$PRE_PID")"; PRE_GOT_IO="$(ioctx_count "$PRE_PID")"; }
  {
    echo "requested_ms_async_op_threads=$PREVERIFY_N"
    echo "requested_librados_thread_count=NONE (不注入，期望库默认 $IOCTX_DEFAULT)"
    echo "conf=$PRE_CONF"
    echo "--- conf 原文 ---"; cat "$PRE_CONF"
    echo "--- mount 行 ---"; mount_line "$MNT_P" || true
    echo "--- io_pid=$PRE_PID daemon_pid=$(mount_ppid "$MNT_P") 全部线程 ---"
    [[ -z "$PRE_PID" ]] || ps -T -p "$PRE_PID" -o tid=,comm= 2>&1 || true
    echo "--- 计数 ---"
    echo "msgr-worker=$PRE_GOT (期望 $PREVERIFY_N)"
    echo "io_context_pool=$PRE_GOT_IO (期望库默认 $IOCTX_DEFAULT)"
  } > "$OUT/msgr-preverify.txt" 2>&1
  cleanup_mounts
  log "PREVERIFY 结果：msgr 请求 $PREVERIFY_N / 观测 $PRE_GOT；io_context 期望默认 $IOCTX_DEFAULT / 观测 $PRE_GOT_IO（原文见 $OUT/msgr-preverify.txt）"
  [[ "$PRE_GOT" == "$PREVERIFY_N" && "$PRE_GOT_IO" == "$IOCTX_DEFAULT" ]] || {
    log "STOP CEPH_CONF 注入未生效；不进入正式矩阵。禁止自行改用第二种注入方式后继续，须由分析方签发。"
    exit 7
  }
  log "PREVERIFY PASS（两个旋钮均生效）；可继续 --preflight"
  exit 0
fi

# ---------- 模式：无状态环境清点 ----------
if [[ "$MODE" == "--preflight" ]]; then
  health_gate preflight
  PF_OBJ=$(object_count)
  {
    echo "bin=$BIN md5=$BIN_MD5_GOT"
    echo "fio=$(cat "$OUT/fio-version.txt")"
    echo "disk_avail_mib=$DISK_FREE_MIB"
    echo "objects=$PF_OBJ (闸门 <= $OBJ_START_MAX)"
    echo "background_monitors=$(cat "$OUT/background-monitors-count.txt") (应为 0)"
    echo "sysconf_md5=$SYSCONF_MD5_START"
    echo "--- 业务挂载 ---"; cat "$OUT/main-mount-before.txt"
    echo "--- 专用挂载点占用 ---"
    mount_line "$MNT_P" || echo "$MNT_P free"
    mount_line "$MNT_Q" || echo "$MNT_Q free"
    echo "--- OSD perf dump 预探 ---"
  } > "$OUT/preflight-summary.txt" 2>&1
  PF_FAIL=0
  for i in 0 1 2 3 4 5; do
    if [[ "$(timeout 15 sudo ceph tell "osd.$i" perf dump 2>/dev/null | wc -c)" -lt 1000 ]]; then
      PF_FAIL=$((PF_FAIL+1)); echo "osd.$i perf dump 空或超时" >> "$OUT/preflight-summary.txt"
    else
      echo "osd.$i OK" >> "$OUT/preflight-summary.txt"
    fi
  done
  cat "$OUT/preflight-summary.txt"
  [[ "$PF_FAIL" == 0 ]] || { log "STOP OSD perf dump 预探失败 $PF_FAIL/6"; exit 3; }
  [[ "$PF_OBJ" =~ ^[0-9]+$ && "$PF_OBJ" -le "$OBJ_START_MAX" ]] || {
    log "STOP 起点 objects=${PF_OBJ:-NA} > $OBJ_START_MAX"; exit 5;
  }
  log "PREFLIGHT 完成；清单见 $OUT/preflight-summary.txt，交用户确认后再跑正式矩阵"
  exit 0
fi

# ---------- 模式：正式矩阵 ----------
printf 'ts\tarm_tag\tpid_p\tstart_p\tpid_q\tstart_q\tmsgr_p\n' > "$OUT/instance-checks.tsv"
printf 'tag\tarm\tthreads\tround\trep\tcfg\trc_p\trc_q\tbw_p_mib\tbw_q_mib\n' > "$OUT/progress.tsv"
printf 'label\tmount\tconf\twant_msgr\tgot_msgr\twant_ioctx\tgot_ioctx\n' > "$OUT/msgr-threads.tsv"
printf 'tag\tobj_pre\tobj_post\tshrink\n' > "$OUT/objects-shrink.tsv"
# 分析方主表：每行 = 一次独立挂载的一次 fio（P64/P96/P128）。ns/B 与 worker CPU 全是协变量，无判定列。
printf 'tag\tarm\tmsgr_threads\tjobs\tround\tbw_mib\tns_per_B\tworker_cv_pct\tmax_worker_pct_core\tmsgr_sum_core\tn_worker\n' \
  > "$OUT/arm-covariates.tsv"

OSD_PROBE_FAIL=0
for i in 0 1 2 3 4 5; do
  if [[ "$(timeout 15 sudo ceph tell "osd.$i" perf dump 2>/dev/null | wc -c)" -lt 1000 ]]; then
    OSD_PROBE_FAIL=$((OSD_PROBE_FAIL+1)); echo "osd.$i perf dump 空或超时" >> "$OUT/osd-probe.txt"
  else
    echo "osd.$i OK" >> "$OUT/osd-probe.txt"
  fi
done
[[ "$OSD_PROBE_FAIL" == 0 ]] || {
  log "STOP OSD perf dump 预探失败 $OSD_PROBE_FAIL/6（疑 admin socket 竞争，见 osd-probe.txt）"; exit 3;
}

health_gate initial
START_OBJECTS=$(object_count)
echo "$START_OBJECTS" > "$OUT/objects-initial.txt"
[[ "$START_OBJECTS" =~ ^[0-9]+$ && "$START_OBJECTS" -le "$OBJ_START_MAX" ]] || {
  log "STOP 起点 objects=${START_OBJECTS:-NA} > $OBJ_START_MAX；禁止自动 gc，回传给分析方"; exit 5;
}
for m in "$MNT_P" "$MNT_Q"; do
  [[ -z "$(mount_line "$m" || true)" ]] || { log "STOP 专用挂载点已在使用：$m"; exit 6; }
  if [[ -d "$m" ]] && [[ -n "$(find "$m" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "STOP 专用目录非空，禁止 chown/覆盖：$m"; exit 6
  fi
done
sudo mkdir -p "$MNT_P" "$MNT_Q"
sudo chown "$(id -u):$(id -g)" "$MNT_P" "$MNT_Q"

log "矩阵开始：臂 ${ARMS[*]}（--numjobs=64/96/128，ms_async_op_threads 恒 8），共 $ROUNDS 轮"
log "每轮每臂各一次独立挂载 + 一次 fio（F56/F58：方差源是建连抽签，重复单位必须是挂载而不是 fio）"
log "⚑ ns/B 与 worker CPU 离散度只作协变量记录，任何值都不停机；judge 由分析方离线做"
ORDER=("${ARMS[@]}")
for r in $(seq 1 "$ROUNDS"); do
  log "==== ROUND $r/$ROUNDS 臂序：${ORDER[*]} ===="
  for arm in "${ORDER[@]}"; do
    run_arm "$arm" "$r"
  done
  # 每轮左移一位，抵消 F55 会话内慢漂移带来的时序混淆
  ORDER=("${ORDER[@]:1}" "${ORDER[0]}")
  [[ "$r" != 1 ]] || anchor_check 1 "$ANCHOR_TOL_STOP" "round1-J64"
done
anchor_check "$ROUNDS" "$ANCHOR_TOL_STOP" "final-J64"

verify_main_identity
verify_sysconf
FINAL_OBJECTS=$(object_count); echo "$FINAL_OBJECTS" > "$OUT/objects-final.txt"
cleanup_mounts
cp "$CEPH_CONF_SYS" "$OUT/conf/ceph.conf.system-after"
verify_sysconf
verify_main_identity
# B4-15：MANIFEST 用相对路径，异机解包后可直接 md5sum -c
( cd "$OUT" && find . -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > MANIFEST.md5 )
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
md5sum "$OUT.tar.gz" > "$OUT.tar.gz.md5"
# B4-13：ALL DONE 必须在压缩包与 md5 都生成之后才打印
log "ALL DONE；产物齐全（MANIFEST + tar.gz + md5）。只回传 $OUT.tar.gz 及 .md5，禁止现场下结论"
trap - EXIT INT TERM
