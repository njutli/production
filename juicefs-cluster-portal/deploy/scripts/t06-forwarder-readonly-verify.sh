#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || { printf 'wrong host\n' >&2; exit 1; }
systemctl is-active --quiet juicefs-metrics-forwarder.service
[[ $(systemctl is-enabled juicefs-metrics-forwarder.service 2>/dev/null || true) == disabled ]]
systemctl show juicefs-metrics-forwarder.service -p MainPID -p CPUQuotaPerSecUSec -p MemoryMax -p IOWeight -p NRestarts --no-pager
ss -ltnH 'sport = :9633' | awk '{print $4}' | grep -Fxq '10.20.1.157:9633'
metrics=$(curl -fsS --connect-timeout 2 --max-time 10 http://127.0.0.1:9567/metrics)
grep -q '^juicefs_' <<<"$metrics"
pgrep -af '/tmp/juicefs-1[.]4[.]1-patched mount' >/dev/null
printf 'T06_FORWARDER_VERIFY_PASS enabled=false\n'
