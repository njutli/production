#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }

wait_http() {
  local name=$1 url=$2
  local attempt
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 2 "$url" >/dev/null; then
      printf 'READY service=%s attempt=%s\n' "$name" "$attempt"
      return 0
    fi
    sleep 2
  done
  systemctl --no-pager --full status "$name" || true
  journalctl -u "$name" -n 80 --no-pager || true
  printf 'service readiness timeout: %s\n' "$name" >&2
  return 1
}

systemctl start juicefs-prometheus.service
wait_http juicefs-prometheus.service http://127.0.0.1:9090/-/ready
systemctl start juicefs-grafana.service
wait_http juicefs-grafana.service http://127.0.0.1:3000/api/health
systemctl start juicefs-portal.service
wait_http juicefs-portal.service http://127.0.0.1:8080/api/v1/health
printf 'T05_ACTIVATE_BASE_PASS loopback_only=true enabled=false\n'
