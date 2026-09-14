#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { printf 'must run as root to read the admin verification token\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }

for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl show "$service" -p NRestarts --value) == 0 ]]
done
grep -Fq 'id="bandwidth-svg"' /opt/juicefs-portal/web/index.html
grep -Fq 'refreshBandwidthChart' /opt/juicefs-portal/web/app.js

token=$(sed -n 's/^PORTAL_ADMIN_TOKEN=//p' /etc/juicefs-portal/portal.env)
[[ "$token" =~ ^[0-9a-f]{64}$ ]]
from=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
to=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for metric in jfs.fuse.read_bps jfs.fuse.write_bps ceph.pool.read_bps ceph.pool.write_bps; do
  body=$(curl -fsS --max-time 8 --get \
    -H "Authorization: Bearer $token" \
    --data-urlencode "metric=$metric" \
    --data-urlencode "from=$from" \
    --data-urlencode "to=$to" \
    --data-urlencode 'step=30' \
    http://127.0.0.1:8080/api/v1/admin/timeseries)
  python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["sample"]["source"] == "prometheus"; assert data["sample"]["freshness"] == "fresh"; assert len(data["data"]["points"]) >= 1' <<<"$body"
done

printf 'T12_READONLY_VERIFY_PASS metrics=4 window=1h step=30 services_restarted=false\n'
