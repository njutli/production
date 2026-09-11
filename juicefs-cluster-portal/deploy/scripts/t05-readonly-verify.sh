#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
for service in juicefs-prometheus.service juicefs-grafana.service juicefs-portal.service; do
  systemctl is-active "$service"
  systemctl show "$service" -p MainPID -p CPUQuotaPerSecUSec -p MemoryMax -p IOWeight -p User -p Group --no-pager
done
curl -fsS --max-time 5 http://127.0.0.1:9090/-/ready
curl -fsS --max-time 5 http://127.0.0.1:3000/api/health
curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/health
ss -ltnp | awk '$4 ~ /127[.]0[.]0[.]1:(3000|8080|9090)$/ {print}'
findmnt -rn /mnt/jfs-tikv
findmnt -rn /mnt/dbwal
printf 'T05_READONLY_VERIFY_PASS\n'
