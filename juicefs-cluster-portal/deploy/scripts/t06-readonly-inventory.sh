#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || {
  printf 'must run on the 157 client (hostname oneasia-c1-cpu-node10)\n' >&2
  exit 1
}

metric_names() {
  local url=$1 regex=$2
  curl -fsS --connect-timeout 3 --max-time 15 "$url" |
    awk -v re="$regex" '
      /^#/ {next}
      {
        name=$1
        sub(/\{.*/, "", name)
        if (name ~ re && !seen[name]++) print name
      }
    ' | sort
}

probe() {
  local label=$1 url=$2
  local result
  if result=$(curl -fsS --connect-timeout 3 --max-time 15 -o /dev/null -w '%{http_code}\t%{size_download}\t%{time_total}' "$url"); then
    printf 'HTTP\t%s\t%s\n' "$label" "$result"
  else
    printf 'HTTP_FAIL\t%s\n' "$label"
  fi
}

printf 'T06_INVENTORY_BEGIN\n'
printf 'CLIENT_HOST\t%s\n' "$(hostname -s)"
printf 'CLIENT_PORTS\n'
ss -ltnH | awk '$4 ~ /:(9100|9567|9633)$/ {print}'
printf 'CLIENT_PROCESSES\n'
pgrep -af 'node_exporter|juicefs.*mount' || true

probe juicefs-157 http://127.0.0.1:9567/metrics
printf 'JUICEFS_METRIC_NAMES\n'
metric_names http://127.0.0.1:9567/metrics '^juicefs_(fuse|object|blockcache|used|staging|uptime|cpu|memory|process)' || true
printf 'JUICEFS_LABEL_SAMPLES\n'
curl -fsS --connect-timeout 3 --max-time 15 http://127.0.0.1:9567/metrics |
  awk '/^juicefs_(fuse_ops_total|fuse_read_size_bytes_sum|fuse_written_size_bytes_sum|object_request_data_bytes|object_request_errors|blockcache_bytes|used_space|used_inodes|uptime)(\{| )/ {print; if (++n == 24) exit}' || true

probe node-157 http://127.0.0.1:9100/metrics
printf 'NODE157_METRIC_NAMES\n'
metric_names http://127.0.0.1:9100/metrics '^node_(cpu_seconds_total|memory_MemAvailable_bytes|network_(receive|transmit)_bytes_total|filesystem_(size|avail)_bytes|disk_)' || true

for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
  printf 'NODE_BEGIN\t%s\n' "$node"
  ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$node" '
    printf "HOST\t%s\n" "$(hostname -s)"
    printf "TOOLS\t"
    for tool in node_exporter smartctl nvme; do
      if command -v "$tool" >/dev/null 2>&1; then printf "%s=%s " "$tool" "$(command -v "$tool")"; else printf "%s=absent " "$tool"; fi
    done
    printf "\nPORT9100\t"
    if ss -ltnH "sport = :9100" | grep -q .; then printf "in-use\n"; else printf "free\n"; fi
    printf "NVME_SYSFS\n"
    for dev in /sys/class/nvme/nvme*; do
      [ -e "$dev" ] || continue
      printf "%s\tmodel=%s\tserial=%s\n" "$(basename "$dev")" "$(cat "$dev/model" 2>/dev/null || true)" "$(cat "$dev/serial" 2>/dev/null || true)"
    done
  '
  probe "pd-$node" "http://$node:2379/metrics"
  probe "tikv-$node" "http://$node:20180/metrics"
done

printf 'PD_METRIC_NAMES\n'
metric_names http://10.20.1.150:2379/metrics '^pd_(cluster_store_sync|regions_status|regions_offline_status|scheduler_hot_|.*heartbeat.*)' || true
printf 'TIKV_METRIC_NAMES\n'
metric_names http://10.20.1.150:20180/metrics '^tikv_(server_info|server_cpu_cores_quota|pd_|grpc_msg_duration_seconds|scheduler_|storage_|raftstore_|engine_)|^process_(cpu_seconds_total|resident_memory_bytes)$' || true

printf 'CEPH_ENDPOINTS\n'
for node in 10.20.1.150 10.20.1.151 10.20.1.152; do
  if curl -fsS --connect-timeout 2 --max-time 4 "http://$node:9283/metrics" -o /dev/null; then
    printf '%s\tready\n' "$node"
  else
    printf '%s\tunavailable\n' "$node"
  fi
done

printf 'T06_READONLY_INVENTORY_PASS\n'
