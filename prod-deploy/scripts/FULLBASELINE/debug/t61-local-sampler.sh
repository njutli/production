#!/usr/bin/env bash
# Local sampler processes for 03-20B-R2.  One invocation is one sampler PGID.
set -euo pipefail
export LC_ALL=C

die() {
  printf 'E_LOCAL_SAMPLER\t%s\n' "$*" >&2
  exit 42
}

sleep_to_deadline() {
  local deadline=$1 now
  now=$(date +%s)
  (( deadline > now )) && sleep $((deadline - now))
}

client_host_line() {
  local ts cpu mem
  ts=$(date +%s)
  cpu=$(awk '/^cpu /{for(i=2;i<=11;i++) printf "%s%s",$i,(i==11?ORS:OFS); exit}' /proc/stat)
  [[ $(awk '{print NF}' <<<"$cpu") -eq 10 ]] || die "client cpu schema"
  cpu=${cpu// /$'\t'}
  mem=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  [[ "$mem" =~ ^[0-9]+$ ]] || die "MemAvailable schema"
  printf '%s\t%s\t%s\n' "$ts" "$cpu" "$mem"
}

parse_pool_json() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
p=next(item for item in d["pools"] if item["name"]=="juicefs-data")
s=p["stats"]
print(s["objects"],s["bytes_used"],s["max_avail"])
'
}

mode=${1:-}
shift || true
case "$mode" in
  --self-test)
    line=$(client_host_line)
    awk -F '\t' 'NF!=12{exit 1} {for(i=1;i<=NF;i++)if($i!~/^[0-9]+$/)exit 1}' <<<"$line" || die "client host fixture"
    pool=$(printf '%s\n' '{"pools":[{"name":"juicefs-data","stats":{"objects":2434672,"bytes_used":11,"max_avail":22}}]}' | parse_pool_json)
    [[ "$pool" == '2434672 11 22' ]] || die "pool JSON fixture"
    echo 't61 local sampler self-test: PASS'
    ;;

  --parse-pool)
    parse_pool_json
    ;;

  client-runtime)
    out=$1 run=$2 regex=$3
    next=$(date +%s)
    while :; do
      ts=$(date +%s)
      tmp="/tmp/t61-client-${run}.tmp"
      curl -fsS --connect-timeout 2 --max-time 4 http://127.0.0.1:9567/metrics > "$tmp"
      grep -E "$regex" "$tmp" | grep -v '^#' | awk -v stamp="$ts" '{print stamp"\t"$0}' >> "$out/samplers/client-runtime.tsv"
      rm -f "$tmp"
      printf '%s\n' "$ts" >> "$out/samplers/client-runtime.heartbeat"
      next=$((next + 1)); sleep_to_deadline "$next" || true
      (( next >= $(date +%s) )) || next=$(date +%s)
    done
    ;;

  client-host)
    out=$1
    next=$(date +%s)
    while :; do
      line=$(client_host_line)
      printf '%s\n' "$line" >> "$out/samplers/client-host.tsv"
      printf '%s\n' "${line%%$'\t'*}" >> "$out/samplers/client-host.heartbeat"
      next=$((next + 1)); sleep_to_deadline "$next" || true
      (( next >= $(date +%s) )) || next=$(date +%s)
    done
    ;;

  tikv-metrics)
    out=$1 run=$2 ip=$3 regex=$4
    next=$(date +%s)
    while :; do
      ts=$(date +%s)
      tmp="/tmp/t61-metrics-${run}-${ip}.tmp"
      curl -fsS --connect-timeout 2 --max-time 4 "http://${ip}:20180/metrics" > "$tmp"
      grep -E "$regex" "$tmp" | grep -v '^#' | awk -v stamp="$ts" -v node="$ip" '{print stamp"\t"node"\t"$0}' >> "$out/samplers/tikv-metrics-${ip}.tsv"
      rm -f "$tmp"
      printf '%s\n' "$ts" >> "$out/samplers/tikv-metrics-${ip}.heartbeat"
      next=$((next + 5)); sleep_to_deadline "$next" || true
      (( next >= $(date +%s) )) || next=$(date +%s)
    done
    ;;

  bridge-device)
    out=$1 ip=$2
    shift 2
    (( $# > 0 )) || die "device list empty"
    sshpass -p Sunrise@801 ssh \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 \
      "$ip" bash /tmp/t61-remote-resource-sampler.sh device "$@" \
      | while IFS= read -r line; do
          printf '%s\n' "$line" >> "$out/samplers/tikv-device-${ip}.tsv"
          printf '%s\n' "${line%%$'\t'*}" >> "$out/samplers/tikv-device-${ip}.heartbeat"
        done
    ;;

  bridge-host)
    out=$1 ip=$2 pid=$3
    [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid TiKV PID"
    sshpass -p Sunrise@801 ssh \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 \
      "$ip" bash /tmp/t61-remote-resource-sampler.sh host "$pid" \
      | while IFS= read -r line; do
          printf '%s\n' "$line" >> "$out/samplers/tikv-host-${ip}.tsv"
          printf '%s\n' "${line%%$'\t'*}" >> "$out/samplers/tikv-host-${ip}.heartbeat"
        done
    ;;

  ceph)
    out=$1
    next=$(date +%s)
    while :; do
      ts=$(date +%s)
      health=$(sudo ceph health)
      pg=$(sudo ceph pg stat | sed -n '1p')
      printf '%s\t%s\t%s\n' "$ts" "$health" "$pg" >> "$out/samplers/ceph.tsv"
      printf '%s\n' "$ts" >> "$out/samplers/ceph.heartbeat"
      next=$((next + 30)); sleep_to_deadline "$next" || true
      (( next >= $(date +%s) )) || next=$(date +%s)
    done
    ;;

  pool)
    out=$1 hard=$2
    [[ "$hard" =~ ^[0-9]+$ ]] || die "invalid hard object limit"
    next=$(date +%s)
    while :; do
      ts=$(date +%s)
      values=$(sudo ceph df --format=json | parse_pool_json)
      read -r objects used avail <<<"$values"
      [[ "$objects $used $avail" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || die "pool schema"
      printf '%s\t%s\t%s\t%s\n' "$ts" "$objects" "$used" "$avail" >> "$out/samplers/pool.tsv"
      printf '%s\n' "$ts" >> "$out/samplers/pool.heartbeat"
      if (( objects > hard )); then
        printf '%s\tS07\tobjects=%s>hard=%s\n' "$ts" "$objects" "$hard" >> "$out/STOP.txt"
        exit 7
      fi
      next=$((next + 15)); sleep_to_deadline "$next" || true
      (( next >= $(date +%s) )) || next=$(date +%s)
    done
    ;;

  *)
    die "unknown mode $mode"
    ;;
esac
