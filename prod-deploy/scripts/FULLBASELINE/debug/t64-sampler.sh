#!/usr/bin/env bash
# Isolated evidence samplers for 03-22. Modes: node, metrics, client.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

MODE=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
OUT=${5:-}
DURATION=${6:-220}
NODE_IP=${7:-}
t64_check_run_id "$RUN_ID"
t64_check_cluster "$CLUSTER"
t64_check_instance "$INSTANCE"
case "$OUT" in
  /tmp/production/opencode-t3.22-"$RUN_ID"/*|/tmp/jfs-t64-"$RUN_ID"-*) ;;
  *) t64_die "unsafe sampler OUT: $OUT";;
esac
[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 200 && DURATION <= 300 )) || t64_die 'duration must be 200..300s'
mkdir -p "$OUT"

sample_node() {
  t64_node_suffix "$NODE_IP" >/dev/null
  local lower state work pidfile config pid start md5 cfg actual_start actual_md5 end epoch dev expected_devices
  lower=$(t64_cluster_lower "$CLUSTER")
  state="/tmp/jfs-t64-${RUN_ID}-${lower}-storage.tsv"
  work="/tmp/jfs-t64-${RUN_ID}-${INSTANCE}-${lower}"
  pidfile="$work/tikv.pid.tsv"
  config="$work/tikv.toml"
  [[ -s "$state" && -s "$pidfile" && -s "$config" ]] || t64_die 'node sampler state/config missing'
  IFS=$'\t' read -r pid start md5 cfg < "$pidfile"
  [[ "$cfg" == "$config" && -r /proc/$pid/stat ]] || t64_die 'node sampler PID state mismatch'
  actual_start=$(awk '{print $22}' /proc/$pid/stat)
  actual_md5=$(md5sum /proc/$pid/exe | awk '{print $1}')
  [[ "$actual_start" == "$start" && "$actual_md5" == "$md5" ]] || t64_die 'node sampler process fingerprint changed'
  mapfile -t DEVS < <(awk -F '\t' '$1=="loop"{print $3}' "$state")
  if [[ "$CLUSTER" == A ]]; then expected_devices=1; else expected_devices=2; fi
  (( ${#DEVS[@]} == expected_devices )) || t64_die 'unexpected loop device count'
  printf 'node=%s\npid=%s\nstarttime=%s\ndevices=%s\n' "$NODE_IP" "$pid" "$start" "${DEVS[*]}" > "$OUT/node-meta.txt"
  end=$((SECONDS + DURATION))
  while (( SECONDS < end )); do
    [[ -r /proc/$pid/stat && $(awk '{print $22}' /proc/$pid/stat) == "$start" ]] || t64_die 'TiKV process changed during sampling'
    epoch=$(date +%s%N)
    {
      printf 'BEGIN\t%s\t%s\n' "$epoch" "$NODE_IP"
      printf 'LOAD\t'; cat /proc/loadavg
      printf 'MEM\t'; awk '/^(MemAvailable|Dirty|Writeback):/{printf "%s=%s ",$1,$2} END{print ""}' /proc/meminfo
      printf 'IOPSI\t'; tr '\n' ' ' < /proc/pressure/io; printf '\n'
      printf 'CPUPSI\t'; tr '\n' ' ' < /proc/pressure/cpu; printf '\n'
      printf 'PIDSTAT\t'; cat "/proc/$pid/stat"
      printf 'PIDIO\t'; awk '{printf "%s=%s ",$1,$2} END{print ""}' "/proc/$pid/io"
      iostat -dxk -y 1 1 "${DEVS[@]}" | sed 's/^/IOSTAT\t/'
      printf 'END\t%s\t%s\n' "$(date +%s%N)" "$NODE_IP"
    } >> "$OUT/node-samples.txt"
  done
}

sample_metrics() {
  local end=$((SECONDS + DURATION)) epoch node dir
  dir="$OUT/metrics"
  mkdir -p "$dir"
  while (( SECONDS < end )); do
    epoch=$(date +%s)
    for node in "${T64_NODES[@]}"; do
      curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T64_TIKV_STATUS_PORT}/metrics" \
        | gzip > "$dir/${epoch}-${node}.prom.gz"
      printf '%s\t%s\t%s\n' "$epoch" "$node" "$dir/${epoch}-${node}.prom.gz" >> "$OUT/metrics-heartbeat.tsv"
    done
    sleep 5
  done
}

sample_client() {
  local state="/tmp/production/opencode-t3.22-${RUN_ID}/instances/${INSTANCE}/volume.tsv"
  local pid start expected_start nic end=$((SECONDS + DURATION))
  [[ -s "$state" ]] || t64_die 'client sampler volume state missing'
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$state")
  start=$(awk -F '\t' '$1=="starttime"{print $2}' "$state")
  nic=${T64_CLIENT_NIC:-enp139s0f0np0}
  [[ -r "/sys/class/net/$nic/statistics/rx_bytes" ]] || t64_die "NIC missing: $nic"
  while (( SECONDS < end )); do
    [[ -r /proc/$pid/stat ]] || t64_die 'JuiceFS process disappeared'
    expected_start=$(awk '{print $22}' /proc/$pid/stat)
    [[ "$expected_start" == "$start" ]] || t64_die 'JuiceFS process starttime changed'
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
  *) t64_die 'usage: t64-sampler.sh node|metrics|client RUN_ID CLUSTER INSTANCE OUT DURATION [NODE_IP]';;
esac
