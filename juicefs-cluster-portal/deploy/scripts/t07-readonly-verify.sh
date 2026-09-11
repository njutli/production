#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
systemctl is-active --quiet juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
done
curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/health | grep -Fq '"mode":"live"'

token=$(sed -n 's/^PORTAL_ADMIN_TOKEN=//p' /etc/juicefs-portal/portal.env)
[[ "$token" =~ ^[0-9a-f]{64}$ ]] || { printf 'invalid admin token file\n' >&2; exit 1; }
auth="Authorization: Bearer $token"
for path in \
  admin/overview admin/topology admin/nodes admin/juicefs/clients \
  admin/tikv admin/ceph admin/usage admin/alerts \
  admin/nodes/150/disks admin/nodes/151/disks admin/nodes/152/disks; do
  body=$(curl -fsS --max-time 8 -H "$auth" "http://127.0.0.1:8080/api/v1/$path")
  grep -Fq '"source":"prometheus"' <<<"$body"
  ! grep -Fq '"source":"fixture"' <<<"$body"
done

leader_count=$(curl -fsS --max-time 5 --get --data-urlencode 'query=count(etcd_server_is_leader{job="pd"})' http://127.0.0.1:9090/api/v1/query)
grep -Fq '"3"' <<<"$leader_count"
pgrep -x pd-server >/dev/null
pgrep -x tikv-server >/dev/null
findmnt -rn /mnt/jfs-tikv >/dev/null
findmnt -rn /mnt/dbwal >/dev/null
printf 'T07_READONLY_VERIFY_PASS services_disabled=true\n'
