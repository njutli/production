#!/usr/bin/env bash
# Isolated evidence samplers for 03-22b. Modes: node, metrics, client.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

MODE=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
OUT=${5:-}
STOP_FILE=${6:-}
WATCHDOG=${7:-900}
NODE_IP=${8:-}
t65_check_run_id "$RUN_ID"
t65_check_cluster "$CLUSTER"
t65_check_instance "$INSTANCE"
case "$OUT" in
  /tmp/production/opencode-t3.22b-"$RUN_ID"/*|/tmp/jfs-t65-"$RUN_ID"-*) ;;
  *) t65_die "unsafe sampler OUT: $OUT";;
esac
case "$STOP_FILE" in "$OUT/control.stop") ;; *) t65_die 'stop file must be OUT/control.stop';; esac
[[ "$WATCHDOG" =~ ^[0-9]+$ ]] && (( WATCHDOG >= 900 && WATCHDOG <= 1200 )) || t65_die 'watchdog must be 900..1200s'
[[ ! -e "$STOP_FILE" ]] || t65_die 'sampler stop file already exists'
mkdir -p "$OUT"

keep_sampling() {
  (( SECONDS < DEADLINE )) && [[ ! -s "$STOP_FILE" ]]
}

sample_node() {
  t65_node_suffix "$NODE_IP" >/dev/null
  local lower state work pidfile config pid start md5 cfg actual_start actual_md5 epoch dev expected_devices role mnt used avail
  lower=$(t65_cluster_lower "$CLUSTER")
  state="/tmp/jfs-t65-${RUN_ID}-${CLUSTER}-${INSTANCE}-activation.tsv"
  work="/tmp/jfs-t65-${RUN_ID}-${INSTANCE}-${lower}"
  pidfile="$work/tikv.pid.tsv"
  config="$work/tikv.toml"
  [[ -s "$state" && -s "$pidfile" && -s "$config" ]] || t65_die 'node sampler state/config missing'
  IFS=$'\t' read -r pid start md5 cfg < "$pidfile"
  [[ "$cfg" == "$config" && -r /proc/$pid/stat ]] || t65_die 'node sampler PID state mismatch'
  actual_start=$(awk '{print $22}' /proc/$pid/stat)
  actual_md5=$(md5sum /proc/$pid/exe | awk '{print $1}')
  [[ "$actual_start" == "$start" && "$actual_md5" == "$md5" ]] || t65_die 'node sampler process fingerprint changed'
  mapfile -t DEVS < <(awk -F '\t' '$1=="loop"{print $3}' "$state")
  DEVS+=(/dev/nvme1n1)
  if [[ "$CLUSTER" == A1 ]]; then expected_devices=2; else expected_devices=3; fi
  (( ${#DEVS[@]} == expected_devices )) || t65_die 'unexpected loop device count'
  printf 'node=%s\npid=%s\nstarttime=%s\ndevices=%s\n' "$NODE_IP" "$pid" "$start" "${DEVS[*]}" > "$OUT/node-meta.txt"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    [[ -r /proc/$pid/stat && $(awk '{print $22}' /proc/$pid/stat) == "$start" ]] || t65_die 'TiKV process changed during sampling'
    epoch=$(date +%s%N)
    {
      printf 'BEGIN\t%s\t%s\n' "$epoch" "$NODE_IP"
      printf 'LOAD\t'; cat /proc/loadavg
      printf 'MEM\t'; awk '/^(MemAvailable|Dirty|Writeback):/{printf "%s=%s ",$1,$2} END{print ""}' /proc/meminfo
      printf 'IOPSI\t'; tr '\n' ' ' < /proc/pressure/io; printf '\n'
      printf 'CPUPSI\t'; tr '\n' ' ' < /proc/pressure/cpu; printf '\n'
      printf 'PIDSTAT\t'; cat "/proc/$pid/stat"
      printf 'PIDIO\t'; awk '{printf "%s=%s ",$1,$2} END{print ""}' "/proc/$pid/io"
      while IFS=$'\t' read -r role mnt; do
        read -r used avail < <(df -B1 --output=pcent,avail "$mnt" | awk 'NR==2{gsub(/%/,"",$1);print $1,$2}')
        printf 'DF\t%s\t%s\t%s\t%s\n' "$role" "$mnt" "$used" "$avail"
        if (( used >= 70 || avail < 8*1024*1024*1024 )); then
          [[ -e "$OUT/CAPACITY_SAFETY_ABORT" ]] || printf 'CAPACITY_SAFETY_ABORT role=%s mount=%s used_pct=%s avail=%s\n' "$role" "$mnt" "$used" "$avail"
          printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$role" "$mnt" "$used" "$avail" > "$OUT/CAPACITY_SAFETY_ABORT"
        fi
      done < <(awk -F '\t' '$1=="loop"{print $2"\t"$5}' "$state")
      iostat -dxk -y 1 1 "${DEVS[@]}" | sed 's/^/IOSTAT\t/'
      printf 'END\t%s\t%s\n' "$(date +%s%N)" "$NODE_IP"
    } >> "$OUT/node-samples.txt"
  done
  grep -Ein 'AlmostFull|AlreadyFull|No space left|disk[^[:alnum:]]*full' "$work/tikv.log" > "$OUT/tikv-capacity-errors.txt" || true
}

sample_metrics() {
  local epoch node dir
  dir="$OUT/metrics"
  mkdir -p "$dir"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    epoch=$(date +%s)
    for node in "${T65_NODES[@]}"; do
      curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T65_TIKV_STATUS_PORT}/metrics" \
        | gzip > "$dir/${epoch}-${node}.prom.gz"
      printf '%s\t%s\t%s\n' "$epoch" "$node" "$dir/${epoch}-${node}.prom.gz" >> "$OUT/metrics-heartbeat.tsv"
    done
    curl -fsS --connect-timeout 3 --max-time 8 "http://10.20.1.150:${T65_PD_CLIENT_PORT}/pd/api/v1/stores" | gzip > "$dir/${epoch}-pd-stores.json.gz"
    printf '%s\t%s\n' "$epoch" "$dir/${epoch}-pd-stores.json.gz" >> "$OUT/pd-stores-heartbeat.tsv"
    sleep 5
  done
}

sample_client() {
  local state="/tmp/production/opencode-t3.22b-${RUN_ID}/instances/${INSTANCE}/volume.tsv"
  local pid start expected_start nic
  [[ -s "$state" ]] || t65_die 'client sampler volume state missing'
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$state")
  start=$(awk -F '\t' '$1=="starttime"{print $2}' "$state")
  nic=${T65_CLIENT_NIC:-enp139s0f0np0}
  [[ -r "/sys/class/net/$nic/statistics/rx_bytes" ]] || t65_die "NIC missing: $nic"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    [[ -r /proc/$pid/stat ]] || t65_die 'JuiceFS process disappeared'
    expected_start=$(awk '{print $22}' /proc/$pid/stat)
    [[ "$expected_start" == "$start" ]] || t65_die 'JuiceFS process starttime changed'
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$nic" \
      "$(<"/sys/class/net/$nic/statistics/rx_bytes")" \
      "$(<"/sys/class/net/$nic/statistics/tx_bytes")" \
      "$(awk '{print $14+$15,$24}' /proc/$pid/stat)" \
      "$(awk '/^Threads:/{print $2}' /proc/$pid/status)" >> "$OUT/client.tsv"
    sleep 1
  done
}

case "$MODE" in
  node) sample_node;;
  metrics) sample_metrics;;
  client) sample_client;;
  *) t65_die 'usage: t65-sampler.sh node|metrics|client RUN_ID CLUSTER INSTANCE OUT STOP_FILE WATCHDOG [NODE_IP]';;
esac

if [[ -s "$STOP_FILE" ]]; then
  printf 'SAMPLER_EXIT_AFTER_FIO\t%s\n' "$(date +%s)" > "$OUT/sampler-status.tsv"
else
  printf 'SAMPLER_WATCHDOG_TIMEOUT\t%s\n' "$(date +%s)" > "$OUT/sampler-status.tsv"
  t65_die 'sampler watchdog expired before stop signal'
fi
