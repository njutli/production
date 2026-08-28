#!/usr/bin/env bash
# Isolated evidence samplers for 03-22c. Modes: node, metrics, client, osd.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

MODE=${1:-}
RUN_ID=${2:-}
CLUSTER=${3:-}
INSTANCE=${4:-}
OUT=${5:-}
STOP_FILE=${6:-}
WATCHDOG=${7:-900}
NODE_IP=${8:-}
t66_check_run_id "$RUN_ID"
t66_check_cluster "$CLUSTER"
t66_check_instance "$INSTANCE"
case "$OUT" in
  /tmp/production/opencode-t3.22c-"$RUN_ID"/*|/tmp/jfs-t66-"$RUN_ID"-*) ;;
  *) t66_die "unsafe sampler OUT: $OUT";;
esac
case "$STOP_FILE" in "$OUT/control.stop") ;; *) t66_die 'stop file must be OUT/control.stop';; esac
[[ "$WATCHDOG" =~ ^[0-9]+$ ]] && (( WATCHDOG >= 900 && WATCHDOG <= 1200 )) || t66_die 'watchdog must be 900..1200s'
[[ ! -e "$STOP_FILE" ]] || t66_die 'sampler stop file already exists'
mkdir -p "$OUT"

keep_sampling() {
  (( SECONDS < DEADLINE )) && [[ ! -s "$STOP_FILE" ]]
}

sample_node() {
  t66_node_suffix "$NODE_IP" >/dev/null
  t66_require_tools awk df iostat smartctl sudo
  local lower state work pidfile config pid start md5 cfg actual_start actual_md5 epoch dev expected_devices role mnt used avail mem_avail swap_free pswpin pswpout base_swap base_in base_out
  lower=$(t66_cluster_lower "$CLUSTER")
  state="/tmp/jfs-t66-${RUN_ID}-${CLUSTER}-${INSTANCE}-activation.tsv"
  work="/tmp/jfs-t66-${RUN_ID}-${INSTANCE}-${lower}"
  pidfile="$work/tikv.pid.tsv"
  config="$work/tikv.toml"
  [[ -s "$state" && -s "$pidfile" && -s "$config" ]] || t66_die 'node sampler state/config missing'
  IFS=$'\t' read -r pid start md5 cfg < "$pidfile"
  [[ "$cfg" == "$config" && -r /proc/$pid/stat ]] || t66_die 'node sampler PID state mismatch'
  actual_start=$(awk '{print $22}' /proc/$pid/stat)
  actual_md5=$(md5sum /proc/$pid/exe | awk '{print $1}')
  [[ "$actual_start" == "$start" && "$actual_md5" == "$md5" ]] || t66_die 'node sampler process fingerprint changed'
  mapfile -t DEVS < <(awk -F '\t' '$1=="loop"{print $3}' "$state")
  DEVS+=(/dev/nvme1n1)
  expected_devices=3
  (( ${#DEVS[@]} == expected_devices )) || t66_die 'unexpected loop device count'
  read -r base_swap base_in base_out < <(awk -F '\t' '$1=="memory_baseline"{print $3,$4,$5}' "$state")
  [[ "$base_swap" =~ ^[0-9]+$ && "$base_in" =~ ^[0-9]+$ && "$base_out" =~ ^[0-9]+$ ]] || t66_die 'activation memory baseline missing'
  command -v smartctl >/dev/null || t66_die 'smartctl missing on TiKV node'
  sudo smartctl -a -j /dev/nvme1n1 > "$OUT/nvme-smart-pre.json"
  printf 'node=%s\narm=%s\npid=%s\nstarttime=%s\ndevices=%s\n' "$NODE_IP" "$CLUSTER" "$pid" "$start" "${DEVS[*]}" > "$OUT/node-meta.txt"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    [[ -r /proc/$pid/stat && $(awk '{print $22}' /proc/$pid/stat) == "$start" ]] || t66_die 'TiKV process changed during sampling'
    epoch=$(date +%s%N)
    {
      printf 'BEGIN\t%s\t%s\n' "$epoch" "$NODE_IP"
      printf 'LOAD\t'; cat /proc/loadavg
      printf 'MEM\t'; awk '/^(MemAvailable|SwapTotal|SwapFree|Dirty|Writeback):/{printf "%s=%s ",$1,$2} END{print ""}' /proc/meminfo
      printf 'VMSTAT\t'; awk '/^(pswpin|pswpout|pgmajfault) /{printf "%s=%s ",$1,$2} END{print ""}' /proc/vmstat
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
      mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
      swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
      pswpin=$(awk '$1=="pswpin"{print $2}' /proc/vmstat)
      pswpout=$(awk '$1=="pswpout"{print $2}' /proc/vmstat)
      if (( mem_avail < 64*1024*1024 || swap_free < base_swap || pswpin != base_in || pswpout != base_out )); then
        printf 'MEMORY_SAFETY_ABORT mem_available_kib=%s swap_free_kib=%s/%s pswpin=%s/%s pswpout=%s/%s\n' \
          "$mem_avail" "$swap_free" "$base_swap" "$pswpin" "$base_in" "$pswpout" "$base_out" > "$OUT/MEMORY_SAFETY_ABORT"
      fi
      if [[ "$CLUSTER" == D1 ]]; then
        logs_tmpfs=$(awk -F '\t' '$1=="ram_logs"{print $3}' "$state")
        [[ -n "$logs_tmpfs" ]] || t66_die 'D1 ram_logs state missing'
        read -r used avail < <(df -B1 --output=pcent,avail "$logs_tmpfs" | awk 'NR==2{gsub(/%/,"",$1);print $1,$2}')
        printf 'TMPFS_DF\t%s\t%s\t%s\n' "$logs_tmpfs" "$used" "$avail"
        # The parent tmpfs is frozen at 36 GiB and contains one fully
        # allocated 32 GiB backing file.  Keep at least 2 GiB of quota
        # headroom and fail before 95% usage; the inner ext4 logs filesystem
        # retains its independent used<70% / avail>=8GiB data-capacity gate.
        if (( used >= 95 || avail < 2*1024*1024*1024 )); then
          printf 'MEMORY_SAFETY_ABORT d1_tmpfs=%s used_pct=%s avail=%s\n' "$logs_tmpfs" "$used" "$avail" > "$OUT/MEMORY_SAFETY_ABORT"
        fi
      fi
      iostat -dxk -y 1 1 "${DEVS[@]}" | sed 's/^/IOSTAT\t/'
      printf 'END\t%s\t%s\n' "$(date +%s%N)" "$NODE_IP"
    } >> "$OUT/node-samples.txt"
    if [[ -s "$OUT/CAPACITY_SAFETY_ABORT" || -s "$OUT/MEMORY_SAFETY_ABORT" ]]; then
      sudo smartctl -a -j /dev/nvme1n1 > "$OUT/nvme-smart-post.json"
      t66_die 'node safety abort'
    fi
  done
  sudo smartctl -a -j /dev/nvme1n1 > "$OUT/nvme-smart-post.json"
  grep -Ein 'AlmostFull|AlreadyFull|No space left|disk[^[:alnum:]]*full' "$work/tikv.log" > "$OUT/tikv-capacity-errors.txt" || true
}

sample_metrics() {
  local epoch node dir
  dir="$OUT/metrics"
  mkdir -p "$dir"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    epoch=$(date +%s)
    for node in "${T66_NODES[@]}"; do
      curl -fsS --connect-timeout 3 --max-time 8 "http://${node}:${T66_TIKV_STATUS_PORT}/metrics" \
        | gzip > "$dir/${epoch}-${node}.prom.gz"
      printf '%s\t%s\t%s\n' "$epoch" "$node" "$dir/${epoch}-${node}.prom.gz" >> "$OUT/metrics-heartbeat.tsv"
    done
    curl -fsS --connect-timeout 3 --max-time 8 "http://10.20.1.150:${T66_PD_CLIENT_PORT}/pd/api/v1/stores" | gzip > "$dir/${epoch}-pd-stores.json.gz"
    printf '%s\t%s\n' "$epoch" "$dir/${epoch}-pd-stores.json.gz" >> "$OUT/pd-stores-heartbeat.tsv"
    sleep 5
  done
}

sample_client() {
  local state="/tmp/production/opencode-t3.22c-${RUN_ID}/instances/${INSTANCE}/volume.tsv"
  local pid start expected_start nic
  [[ -s "$state" ]] || t66_die 'client sampler volume state missing'
  pid=$(awk -F '\t' '$1=="pid"{print $2}' "$state")
  start=$(awk -F '\t' '$1=="starttime"{print $2}' "$state")
  nic=${T66_CLIENT_NIC:-enp139s0f0np0}
  [[ -r "/sys/class/net/$nic/statistics/rx_bytes" ]] || t66_die "NIC missing: $nic"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    [[ -r /proc/$pid/stat ]] || t66_die 'JuiceFS process disappeared'
    expected_start=$(awk '{print $22}' /proc/$pid/stat)
    [[ "$expected_start" == "$start" ]] || t66_die 'JuiceFS process starttime changed'
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$nic" \
      "$(<"/sys/class/net/$nic/statistics/rx_bytes")" \
      "$(<"/sys/class/net/$nic/statistics/tx_bytes")" \
      "$(awk '{print $14+$15,$24}' /proc/$pid/stat)" \
      "$(awk '/^Threads:/{print $2}' /proc/$pid/status)" >> "$OUT/client.tsv"
    sleep 1
  done
}

sample_osd() {
  local epoch osd file
  t66_require_tools ceph python3 sudo
  mapfile -t OSD_IDS < <(sudo ceph osd ls)
  (( ${#OSD_IDS[@]} == 6 )) || t66_die "expected 6 OSDs, got ${#OSD_IDS[@]}"
  mkdir -p "$OUT/osd"
  DEADLINE=$((SECONDS + WATCHDOG))
  while keep_sampling; do
    epoch=$(date +%s)
    for osd in "${OSD_IDS[@]}"; do
      [[ "$osd" =~ ^[0-9]+$ ]] || t66_die "invalid OSD id: $osd"
      file="$OUT/osd/${epoch}-osd-${osd}.json"
      sudo ceph tell "osd.$osd" perf dump > "$file"
      python3 -m json.tool "$file" >/dev/null
      printf '%s\t%s\t%s\n' "$epoch" "$osd" "$file" >> "$OUT/osd-heartbeat.tsv"
    done
    local elapsed=$(( $(date +%s) - epoch ))
    (( elapsed < 5 )) && sleep $((5 - elapsed))
  done
}

case "$MODE" in
  node) sample_node;;
  metrics) sample_metrics;;
  client) sample_client;;
  osd) sample_osd;;
  *) t66_die 'usage: t66-sampler.sh node|metrics|client|osd RUN_ID CLUSTER INSTANCE OUT STOP_FILE WATCHDOG [NODE_IP]';;
esac

if [[ -s "$STOP_FILE" ]]; then
  printf 'SAMPLER_EXIT_AFTER_FIO\t%s\n' "$(date +%s)" > "$OUT/sampler-status.tsv"
else
  printf 'SAMPLER_WATCHDOG_TIMEOUT\t%s\n' "$(date +%s)" > "$OUT/sampler-status.tsv"
  t66_die 'sampler watchdog expired before stop signal'
fi
