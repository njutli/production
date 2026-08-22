#!/usr/bin/env bash
# t46-n1n2-read-boundary.sh — 03-16：N1/N2 单/双挂载读边界，只采集、不判定
#
# 红线：
#   - 只读；不运行 randwrite/randrw，不做 gc、compact、重启或 Ceph 配置修改。
#   - 判档 fio 也带 --readonly；数据集缺文件时必须 STOP，绝不允许由 fio 补写布局。
#   - 不卸载、不重挂、不改动业务挂载 /mnt/juicefs。
#   - 仅创建和卸载 /mnt/juicefs-p、/mnt/juicefs-q 两个专用挂载。
#   - 每个 pair 判档后冻结两实例 PID+starttime，任一变化立即 STOP。
#   - 对象闸门口径固定为 Ceph pool juicefs-data objects（≤3,110,000），禁止改用 UsedInodes 等替代量。
#
# 执行：ACK_SUDO_WRITES=YES bash /tmp/t46-n1n2-read-boundary.sh
# sudo 写入仅限：创建专用挂载目录、client+3 节点 drop_caches、卸载专用挂载。
# 只读 sudo：ceph health/pg/df、ceph tell osd.N perf dump、ss -tlnp（取 pprof 端口）。
set -euo pipefail
export LC_ALL=C

OUT="${OUT:-/tmp/opencode-t3.16}"
BIN="${BIN:-/tmp/juicefs-03-8}"
GATE="${GATE:-/tmp/t39-nsbgate.sh}"
SNAP="${SNAP:-/tmp/env-snapshot.sh}"
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT_P=/mnt/juicefs-p
MNT_Q=/mnt/juicefs-q
MAIN_MNT=/mnt/juicefs
OPTS=(--max-uploads 150 --cache-size 0 --max-fuse-io 256K)
NIC_PUB=enp139s0f0np0
NIC_MGMT=eno12399
SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSHPASS_CMD=(sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise)
REF_NSB=3.287
TOL_NSB=10
OBJ_START_MAX=3110000
RUNTIME=180
GAP=20
SKEW_EVENTS=0
SKEW_MAX_SEEN=0

[[ "${ACK_SUDO_WRITES:-}" == YES ]] || {
  echo "REFUSE: 先审阅脚本中的 sudo 写操作，再以 ACK_SUDO_WRITES=YES 执行" >&2
  exit 2
}
[[ "$OUT" == /tmp/* && "$OUT" != /tmp ]] || {
  echo "REFUSE: OUT 必须是 /tmp 下的非根目录：$OUT" >&2
  exit 2
}
for f in "$BIN" "$GATE" "$SNAP"; do
  [[ -f "$f" ]] || { echo "STOP 缺文件：$f" >&2; exit 2; }
done
if [[ -e "$OUT" ]] && [[ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "STOP: OUT 已非空，禁止混入旧证据；请保留现场并由分析方指定新 OUT：$OUT" >&2
  exit 2
fi
[[ ! -e "$OUT.tar.gz" && ! -e "$OUT.tar.gz.md5" ]] || {
  echo "STOP: 目标归档已存在，禁止覆盖：$OUT.tar.gz{,.md5}" >&2
  exit 2
}
mkdir -p "$OUT" "$OUT/bwlog" "$OUT/osd"
COLLECTOR_PIDS=()
CHILD_PIDS=()

log() { echo "[$(date '+%F %T')] $*" | tee -a "$OUT/wrapper.log"; }

proc_fields() { # $1=pid → starttime utime stime threads；兼容 comm 中空格/右括号
  awk '{line=$0; sub(/^[0-9]+ \(/,"",line); if (!match(line,/\) [^)]*$/)) exit 1;
        rest=substr(line,RSTART+2); n=split(rest,f,/[[:space:]]+/); if(n<20) exit 1;
        print f[20],f[12],f[13],f[18]}' "/proc/$1/stat" 2>/dev/null
}

mount_pid() { # $1=精确挂载点
  local m="$1"
  pgrep -af juicefs 2>/dev/null | awk -v m="$m" '$0 ~ / mount / && $NF==m {print $1; exit}'
}

mount_line() { # $1=挂载点
  awk -v m="$1" '$2==m {print; exit}' /proc/mounts
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
  # ⛔ 禁止用 UsedSpace / UsedInodes / TiKV disk size 替代（V02-PRE §十一、V02 §5 已明文立规；
  #    UsedInodes 实测量级为 10^2，与 3.11M 阈值差 4 个数量级，会使闸门永远通过）。
  # 每次调用把 ceph df 原文追加落盘，供分析方复核逐轮对象轨迹（B7 轮内看门狗证据）。
  local raw
  raw=$(timeout 30 sudo ceph df --format=json 2>/dev/null || true)
  printf '%s\t%s\n' "$(date +%s)" "$raw" >> "$OUT/objects-raw.jsonl"
  printf '%s' "$raw" | python3 -c \
    "import json,sys; p=[x for x in json.load(sys.stdin)['pools'] if x['name']=='juicefs-data']; assert len(p)==1; print(p[0]['stats']['objects'])" \
    2>/dev/null || true
}

health_gate() { # $1=tag；唯一告警是时钟漂移时"记录并继续"，其余一律 STOP
  local tag="$1" h wrn nwrn skew
  { echo "=== $tag $(date '+%F %T') ==="; sudo ceph health detail; sudo ceph pg stat; } \
    > "$OUT/health-$tag.txt" 2>&1
  h=$(grep -m1 '^HEALTH_' "$OUT/health-$tag.txt" || true)
  grep -q '^HEALTH_OK' <<<"$h" && return 0
  nwrn=$(grep -cE '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  wrn=$(grep -m1 -E '^\[(WRN|ERR)\]' "$OUT/health-$tag.txt" || true)
  # 唯一告警是 mon 时钟漂移时不中断：157 集群 node2 用公网 ntp.ubuntu.com（delay 319ms、
  # poll 34min、drift -11.157ppm ≈ 40.2ms/h），两次校准间累积 ~22.8ms 叠在 +27.8ms 基础偏移上，
  # 峰值必然顶到 mon_clock_drift_allowed=0.05s，跨线是该 NTP 拓扑的固有周期现象（约 34min 一次），
  # 不是集群健康信号；且对本任务测量无影响（对齐用本机 date +%s%N，OSD 指标取计数器差值）。
  { [[ "$nwrn" == 1 ]] && grep -qiE '^\[(WRN|ERR)\].*clock skew' "$OUT/health-$tag.txt"; } || {
    log "STOP $tag Ceph 非 HEALTH_OK：$h（告警条数=$nwrn，首条=$wrn）"; return 1;
  }
  # 从告警原文取漂移值（形如 "mon.X clock skew 0.0637237s > max 0.05s"），取最大者
  skew=$(grep -oE 'clock skew [0-9]+(\.[0-9]+)?s' "$OUT/health-$tag.txt" \
    | sed -E 's/clock skew ([0-9.]+)s/\1/' | sort -g | tail -1)
  [[ "$skew" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
    log "STOP $tag 时钟漂移告警但无法解析漂移值，原文形态异常：$wrn"; return 1;
  }
  # 量级护栏：>0.5s（10× 阈值）不再视为 NTP 锯齿，可能真出了问题
  awk -v s="$skew" 'BEGIN{exit !(s<=0.5)}' || {
    log "STOP $tag 时钟漂移 ${skew}s > 0.5s 上限，超出 NTP 锯齿可解释范围"; return 1;
  }
  SKEW_EVENTS=$((SKEW_EVENTS+1))
  awk -v a="$skew" -v b="$SKEW_MAX_SEEN" 'BEGIN{exit !(a>b)}' && SKEW_MAX_SEEN="$skew"
  timeout 15 sudo ceph time-sync-status > "$OUT/time-sync-$tag.json" 2>&1 || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$tag" "$skew" "$SKEW_EVENTS" "$wrn" \
    >> "$OUT/skew-events.tsv"
  log "NOTE $tag 唯一告警为时钟漂移 ${skew}s（累计 $SKEW_EVENTS 次，峰值 ${SKEW_MAX_SEEN}s），按 §2.1c 记录后继续"
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

cleanup_pair() {
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
  cleanup_pair
  verify_main_identity || rc=90
  log "exit rc=$rc"
  exit "$rc"
}
trap on_exit EXIT INT TERM

mount_one() { # $1=挂载点 $2=label
  local m="$1" lab="$2" pid st mr
  "$BIN" mount -d "${OPTS[@]}" "$META" "$m" >> "$OUT/mount.log" 2>&1
  sleep 5
  [[ -n "$(mount_line "$m" || true)" ]] || { log "STOP $lab mount failed: $m"; return 1; }
  mr=$(mount_line "$m" | grep -o 'max_read=[0-9]*' | cut -d= -f2)
  [[ "$mr" == 262144 ]] || { log "STOP $lab max_read=${mr:-NA} !=262144"; return 1; }
  pid=$(mount_pid "$m"); st=$(proc_fields "$pid" | awk '{print $1}')
  [[ -n "$pid" && -n "$st" ]] || { log "STOP $lab 无法解析 mount PID/starttime"; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$lab" "$m" "$pid" "$st" "$mr" >> "$OUT/instances.tsv"
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
    printf 'ts\tpid\tstarttime\tutime\tstime\tthreads\trss_kb\n'
    while [[ -r "/proc/$pid/stat" ]]; do
      local_t=$(date +%s); read -r st ut sy th < <(proc_fields "$pid")
      rss=$(awk '/VmRSS/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$local_t" "$pid" "$st" "$ut" "$sy" "$th" "${rss:-NA}"
      sleep 1
    done
  ) > "$f" 2>/dev/null &
  COLLECTOR_PIDS+=("$!")
  CHILD_PIDS+=("$!")
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

gate_mount() { # $1=P|Q $2=mount $3=pair-label；同一实例上连续 2 次，按中位数判
  local side="$1" m="$2" pair="$3" r tag sp out nsb med dev fio_rc gate_logs obj vals=()
  for r in 1 2; do
    tag="${pair}-gate-${side}-r$r"
    health_gate "$tag-pre"; verify_main_identity
    obj=$(object_count); echo "$obj" > "$OUT/objects-$tag-pre.txt"
    [[ "$obj" =~ ^[0-9]+$ && "$obj" -le "$OBJ_START_MAX" ]] || {
      log "STOP $tag objects=${obj:-NA} > $OBJ_START_MAX 或不可解析"; return 1;
    }
    drop_caches_all
    COLLECTOR_PIDS=()
    sample_stats "$m" "$OUT/i1-$tag.tsv"; sp="${COLLECTOR_PIDS[-1]}"
    if timeout 300 fio --name=mseqread --directory="$m/test_dir/mseqread/" --rw=read --refill_buffers --bs=256k \
        --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --readonly \
        --time_based --runtime=180 --write_bw_log="$OUT/bwlog/$tag" --log_avg_msec=1000 \
        > "$OUT/fio-$tag.txt" 2>&1; then fio_rc=0; else fio_rc=$?; fi
    kill "$sp" 2>/dev/null || true; wait "$sp" 2>/dev/null || true; COLLECTOR_PIDS=()
    [[ "$fio_rc" == 0 ]] || { log "STOP $tag fio rc=$fio_rc"; return 1; }
    gate_logs=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'_bw.*.log' | wc -l)
    grep -qE '^\s+READ: bw=' "$OUT/fio-$tag.txt" || { log "STOP $tag 缺 READ 汇总行"; return 1; }
    [[ "$gate_logs" == 16 ]] || { log "STOP $tag bw logs=$gate_logs/16"; return 1; }
    out=$(bash "$GATE" --i1 "$OUT/i1-$tag.tsv" 2>&1 || true)
    printf '%s\n' "$out" | tee -a "$OUT/probe-gate.log"
    nsb=$(awk -F'ns/B=' '/^I1 /{print $2; exit}' <<<"$out")
    [[ "$nsb" =~ ^[0-9]+([.][0-9]+)?$ ]] || { log "STOP $tag ns/B 不可解析"; return 1; }
    vals+=("$nsb")
  done
  med=$(awk -v a="${vals[0]}" -v b="${vals[1]}" 'BEGIN{printf "%.3f",(a+b)/2}')
  dev=$(awk -v m="$med" -v ref="$REF_NSB" 'BEGIN{d=(m-ref)/ref*100; if(d<0)d=-d; printf "%.1f",d}')
  printf '%s\t%s\t%s\t%s\n' "$pair" "$side" "$med" "$dev" >> "$OUT/gate-summary.tsv"
  awk -v d="$dev" -v t="$TOL_NSB" 'BEGIN{exit !(d<=t)}' || {
    log "判档 FAIL pair=$pair side=$side median_ns/B=$med abs_dev=${dev}%"; return 1;
  }
}

freeze_pair() {
  PID_P=$(mount_pid "$MNT_P"); PID_Q=$(mount_pid "$MNT_Q")
  START_P=$(proc_fields "$PID_P" | awk '{print $1}'); START_Q=$(proc_fields "$PID_Q" | awk '{print $1}')
  printf 'P\t%s\t%s\nQ\t%s\t%s\n' "$PID_P" "$START_P" "$PID_Q" "$START_Q" \
    > "$OUT/frozen-$PAIR.tsv"
}

verify_pair() {
  local p q ps qs
  p=$(mount_pid "$MNT_P"); q=$(mount_pid "$MNT_Q")
  [[ -n "$p" && -n "$q" ]] || { log "STOP $PAIR 专用挂载消失"; return 1; }
  ps=$(proc_fields "$p" | awk '{print $1}'); qs=$(proc_fields "$q" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$PAIR" "$p" "$ps" "$q" "$qs" \
    >> "$OUT/instance-checks.tsv"
  [[ "$p" == "$PID_P" && "$ps" == "$START_P" && "$q" == "$PID_Q" && "$qs" == "$START_Q" ]] || {
    log "STOP $PAIR 实例漂移 got P=$p/$ps Q=$q/$qs want P=$PID_P/$START_P Q=$PID_Q/$START_Q"; return 1;
  }
  verify_main_identity
}

run_config() { # $1=round $2=P64|Q64|C64|P128|Q128|C128
  local round="$1" cfg="$2" jobs side_p=0 side_q=0 tag dir rc_p=NA rc_q=NA obj_pre obj_post logs_p logs_q
  local -a cmd_p=() cmd_q=()
  jobs=${cfg//[^0-9]/}
  [[ "$cfg" == P* || "$cfg" == C* ]] && side_p=1
  [[ "$cfg" == Q* || "$cfg" == C* ]] && side_q=1
  tag="$PAIR-r$round-$cfg"; dir="$OUT/run-$tag"; mkdir -p "$dir"
  log "START $tag（只采集；禁止现场判定）"
  health_gate "$tag-pre"; verify_pair
  obj_pre=$(object_count); echo "$obj_pre" > "$dir/objects-pre.txt"
  [[ "$obj_pre" =~ ^[0-9]+$ && "$obj_pre" -le "$OBJ_START_MAX" ]] || {
    log "STOP $tag objects=${obj_pre:-NA} > $OBJ_START_MAX 或不可解析"; return 1;
  }
  { uptime; free -m; { ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -25; } || true;
    echo "--- background monitors ---";
    pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh' || true;
    echo "--- fio 进程（应只有本任务）---"; pgrep -af fio || true; } > "$dir/host-state-pre.txt"
  drop_caches_all
  osd_snapshot "$tag" pre
  COLLECTOR_PIDS=()
  sample_stats "$MNT_P" "$dir/i1-P.tsv"; sample_stats "$MNT_Q" "$dir/i1-Q.tsv"
  sample_proc "$PID_P" "$dir/proc-P.tsv"; sample_proc "$PID_Q" "$dir/proc-Q.tsv"
  sample_net "$dir/net.tsv"
  PPROF_P=""; PPROF_Q=""
  if [[ "$round" == 2 && "$side_p" == 1 ]]; then pprof_after_120 P "$PID_P" "$tag" & PPROF_P=$!; CHILD_PIDS+=("$!"); fi
  if [[ "$round" == 2 && "$side_q" == 1 ]]; then pprof_after_120 Q "$PID_Q" "$tag" & PPROF_Q=$!; CHILD_PIDS+=("$!"); fi
  FIO_P=""; FIO_Q=""
  if [[ "$side_p" == 1 ]]; then
    cmd_p=(timeout "$((RUNTIME+120))" fio --directory="$MNT_P/test_dir" --name=read_test --filesize=1G --size=1G --bs=256k
      --rw=randread --ioengine=libaio --iodepth=128 --numjobs="$jobs" --direct=1
      --fallocate=none --openfiles=128 --readonly --group_reporting --time_based --runtime="$RUNTIME"
      --write_bw_log="$OUT/bwlog/$tag-P" --log_avg_msec=1000)
    printf '%q ' "${cmd_p[@]}" > "$dir/command-P.txt"; printf '\n' >> "$dir/command-P.txt"
    (
      date +%s%N > "$dir/fio-P-start-ns.txt"
      exec "${cmd_p[@]}"
    ) > "$dir/fio-P.txt" 2>&1 & FIO_P=$!; CHILD_PIDS+=("$!")
  fi
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
  [[ -z "$FIO_P" ]] || { if wait "$FIO_P"; then rc_p=0; else rc_p=$?; fi; }
  [[ -z "$FIO_Q" ]] || { if wait "$FIO_Q"; then rc_q=0; else rc_q=$?; fi; }
  [[ -z "$PPROF_P" ]] || { wait "$PPROF_P" || true; }
  [[ -z "$PPROF_Q" ]] || { wait "$PPROF_Q" || true; }
  stop_collectors
  osd_snapshot "$tag" post
  health_gate "$tag-post"; verify_pair
  obj_post=$(object_count); echo "$obj_post" > "$dir/objects-post.txt"
  { uptime; free -m; { ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -25; } || true;
    echo "--- background monitors ---";
    pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh' || true;
    echo "--- 落盘空间 ---"; df -h "$OUT" | tail -1; } > "$dir/host-state-post.txt"
  logs_p=0; logs_q=0
  [[ "$side_p" == 0 ]] || logs_p=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'-P_bw.*.log' | wc -l)
  [[ "$side_q" == 0 ]] || logs_q=$(find "$OUT/bwlog" -maxdepth 1 -type f -name "$tag"'-Q_bw.*.log' | wc -l)
  {
    printf 'tag=%s round=%s cfg=%s jobs=%s rc_p=%s rc_q=%s bwlogs_p=%s bwlogs_q=%s\n' "$tag" "$round" "$cfg" "$jobs" "$rc_p" "$rc_q" "$logs_p" "$logs_q"
    printf 'P_dataset=%s\nQ_dataset=%s\n' "$MNT_P/test_dir/read_test.*.0" "$MNT_Q/test_dir/rw_test.*.0"
    [[ ! -f "$dir/fio-P.txt" ]] || grep -E '^\s+READ: bw=' "$dir/fio-P.txt" || true
    [[ ! -f "$dir/fio-Q.txt" ]] || grep -E '^\s+READ: bw=' "$dir/fio-Q.txt" || true
  } > "$dir/run-meta.txt"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$round" "$cfg" "$rc_p" "$rc_q" "$obj_post" \
    >> "$OUT/progress.tsv"
  [[ "$rc_p" == 0 || "$rc_p" == NA ]] && [[ "$rc_q" == 0 || "$rc_q" == NA ]] || {
    log "STOP $tag fio rc P=$rc_p Q=$rc_q"; return 1;
  }
  [[ "$side_p" == 0 ]] || { grep -qE '^\s+READ: bw=' "$dir/fio-P.txt" && [[ "$logs_p" == "$jobs" ]]; } || {
    log "STOP $tag P 证据不完整：READ 行或 bw logs=$logs_p/$jobs"; return 1;
  }
  [[ "$side_q" == 0 ]] || { grep -qE '^\s+READ: bw=' "$dir/fio-Q.txt" && [[ "$logs_q" == "$jobs" ]]; } || {
    log "STOP $tag Q 证据不完整：READ 行或 bw logs=$logs_q/$jobs"; return 1;
  }
  log "DONE $tag rc P=$rc_p Q=$rc_q objects=$obj_pre->$obj_post"
  sleep "$GAP"
}

prepare_pair() { # $1=A|B；失败时最多换挂载实例 3 次
  local base="$1" try files_p files_q files_mp files_mq
  for try in 1 2 3; do
    PAIR="T46-$base-t$try"; cleanup_pair
    mount_one "$MNT_P" "$PAIR-P" || continue
    mount_one "$MNT_Q" "$PAIR-Q" || continue
    files_p=$(find "$MNT_P/test_dir" -maxdepth 1 -type f -name 'read_test.*.0' | wc -l)
    files_q=$(find "$MNT_Q/test_dir" -maxdepth 1 -type f -name 'rw_test.*.0' | wc -l)
    [[ "$files_p" == 128 && "$files_q" == 128 ]] || {
      log "STOP 数据集不完整：P read_test=$files_p/128 Q rw_test=$files_q/128"; return 1;
    }
    # 判档数据集必须齐全：mseqread 16×4G。缺文件时 --readonly 会让 fio 直接失败而非补写，
    # 这里先显式核对，避免把"只读任务"的 STOP 推迟到 fio 层。
    files_mp=$(find "$MNT_P/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' | wc -l)
    files_mq=$(find "$MNT_Q/test_dir/mseqread" -maxdepth 1 -type f -name 'mseqread.*.0' | wc -l)
    printf '%s\tread_test=%s\trw_test=%s\tmseqread_P=%s\tmseqread_Q=%s\n' \
      "$PAIR" "$files_p" "$files_q" "$files_mp" "$files_mq" >> "$OUT/dataset-check.tsv"
    [[ "$files_mp" == 16 && "$files_mq" == 16 ]] || {
      log "STOP 判档数据集不完整：mseqread P=$files_mp/16 Q=$files_mq/16"; return 1;
    }
    if gate_mount P "$MNT_P" "$PAIR" && gate_mount Q "$MNT_Q" "$PAIR"; then
      freeze_pair
      bash "$SNAP" "$OUT" "$PAIR-active" "$META"
      verify_pair
      log "PAIR PASS $PAIR P=$PID_P/$START_P Q=$PID_Q/$START_Q"
      return 0
    fi
    log "$PAIR 判档失败；整对专用挂载重建，禁止只换一侧"
  done
  log "STOP pair=$base 三次双挂载判档均失败"
  return 1
}

snapshot_main_identity
verify_main_identity
printf 'pair\tside\tmedian_ns_per_B\tabs_dev_pct\n' > "$OUT/gate-summary.tsv"
printf 'ts\tpair\tpid_p\tstart_p\tpid_q\tstart_q\n' > "$OUT/instance-checks.tsv"
printf 'tag\tround\tcfg\trc_p\trc_q\tobjects_post\n' > "$OUT/progress.tsv"
md5sum "$BIN" "$GATE" "$SNAP" "$0" > "$OUT/input-md5.txt"
fio --version > "$OUT/fio-version.txt" 2>&1
grep -q '^fio-3\.28' "$OUT/fio-version.txt" || {
  log "STOP fio 版本必须为 3.28（实测 $(cat "$OUT/fio-version.txt")）：更高版本对 --name+--directory+numjobs 的默认文件名解析不同，会与 --readonly 冲突"; exit 3;
}

# 落盘空间：157 根分区长期在 98%。OSD perf dump 6×2×36×34KB≈15MB、pprof/i1/bwlog 合计约 200MB。
DISK_FREE_MIB=$(df -BM --output=avail "$(dirname "$OUT")" 2>/dev/null | awk 'NR==2{gsub(/M/,"");print $1}')
echo "avail_mib=$DISK_FREE_MIB" > "$OUT/disk-preflight.txt"
df -h "$(dirname "$OUT")" >> "$OUT/disk-preflight.txt" 2>&1
[[ "$DISK_FREE_MIB" =~ ^[0-9]+$ && "$DISK_FREE_MIB" -ge 5120 ]] || {
  log "STOP 落盘空间不足或不可解析：avail=${DISK_FREE_MIB:-NA} MiB < 5120"; exit 3;
}

# 已知遗留监控进程清点（07-27 起的 lcnvme/pool-tracer/instrument 孤儿）。
# 只记录，绝不 kill：kill 未知/他人进程超出本任务授权。分析方据此判断背景噪音。
pgrep -af 'load-monitor|osd-monitor|pool-tracer|instrument\.sh|nsbgate|t4[0-9]-' \
  > "$OUT/background-monitors-initial.txt" 2>/dev/null || true
wc -l < "$OUT/background-monitors-initial.txt" > "$OUT/background-monitors-count.txt"

# OSD admin socket 可用性预探：遗留 osd-monitor.sh 每 5s 对 6 个 OSD 打 perf dump，
# 与本脚本的 osd_snapshot 竞争 admin socket。先确认 6 个 OSD 都能在 15s 内返回非空。
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

for base in A B; do
  prepare_pair "$base"
  for round in 1 2 3; do
    case "$round" in
      1) ORDER=(P64 Q64 C64 P128 Q128 C128) ;;
      2) ORDER=(Q128 C128 P128 Q64 C64 P64) ;;
      3) ORDER=(C64 P64 Q64 C128 P128 Q128) ;;
    esac
    for cfg in "${ORDER[@]}"; do run_config "$round" "$cfg"; done
  done
  bash "$SNAP" "$OUT" "$PAIR-complete" "$META"
  cleanup_pair
done

verify_main_identity
FINAL_OBJECTS=$(object_count); echo "$FINAL_OBJECTS" > "$OUT/objects-final.txt"
cleanup_pair
verify_main_identity
log "ALL DONE；只回传原始目录 $OUT、压缩包 $OUT.tar.gz 及 md5，禁止现场下结论"
find "$OUT" -type f ! -name MANIFEST.md5 -print0 | sort -z | xargs -0 md5sum > "$OUT/MANIFEST.md5"
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
md5sum "$OUT.tar.gz" > "$OUT.tar.gz.md5"
trap - EXIT INT TERM
