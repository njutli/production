#!/usr/bin/env bash
set -euo pipefail

EXPECTED_HOST=${1:?usage: t06-node-readonly-verify.sh EXPECTED_HOST EXPECTED_IP}
EXPECTED_IP=${2:?missing expected IP}
[[ "$EXPECTED_HOST" =~ ^ceph-node[123]$ ]] || { printf 'invalid expected host\n' >&2; exit 2; }
[[ "$EXPECTED_IP" =~ ^10[.]20[.]1[.](150|151|152)$ ]] || { printf 'invalid expected IP\n' >&2; exit 2; }
[[ $(hostname -s) == "$EXPECTED_HOST" ]] || { printf 'wrong host\n' >&2; exit 1; }
ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$EXPECTED_IP"

systemctl is-active --quiet juicefs-node-exporter.service
systemctl is-active --quiet juicefs-nvme-collector.timer
[[ $(systemctl is-enabled juicefs-node-exporter.service 2>/dev/null || true) == disabled ]]
[[ $(systemctl is-enabled juicefs-nvme-collector.timer 2>/dev/null || true) == disabled ]]
systemctl show juicefs-node-exporter.service -p MainPID -p CPUQuotaPerSecUSec -p MemoryMax -p IOWeight -p NRestarts --no-pager
systemctl show juicefs-nvme-collector.timer -p ActiveState -p NextElapseUSecRealtime --no-pager

metrics=$(curl -fsS --connect-timeout 2 --max-time 10 "http://$EXPECTED_IP:9100/metrics")
grep -q '^node_cpu_seconds_total{' <<<"$metrics"
grep -q '^node_disk_read_bytes_total{' <<<"$metrics"
[[ $(grep -c '^jfsportal_nvme_info{' <<<"$metrics") -eq 4 ]]
[[ $(grep -c '^jfsportal_nvme_temperature_celsius{' <<<"$metrics") -eq 4 ]]

pgrep -x pd-server >/dev/null
pgrep -x tikv-server >/dev/null
findmnt -rn /mnt/jfs-tikv >/dev/null
findmnt -rn /mnt/dbwal >/dev/null
printf 'T06_NODE_VERIFY_PASS host=%s ip=%s enabled=false nvme_controllers=4\n' "$EXPECTED_HOST" "$EXPECTED_IP"
