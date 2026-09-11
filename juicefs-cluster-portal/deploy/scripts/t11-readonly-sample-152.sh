#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) == ceph-node3 ]]

for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service juicefs-namespace-mount.service juicefs-namespace-collector.timer; do
  [[ $(systemctl is-active "$service") == active ]]
done
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
  [[ $(systemctl show "$service" -p NRestarts --value) == 0 ]]
done
for service in juicefs-namespace-mount.service juicefs-namespace-collector.service juicefs-namespace-collector.timer; do
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == static ]]
done

[[ $(sudo -n /usr/bin/pgrep -xo pd-server) == 1589960 ]]
[[ $(sudo -n /usr/bin/pgrep -xo tikv-server) == 2088516 ]]
sudo -n /usr/bin/findmnt -rn -M /mnt/jfs-tikv >/dev/null
sudo -n /usr/bin/findmnt -rn -M /mnt/dbwal >/dev/null
sudo -n /usr/bin/findmnt -rn -M /var/lib/juicefs-portal/namespace-mount >/dev/null
[[ $(sudo -n /usr/bin/ceph health) == HEALTH_OK ]]

curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/health >/dev/null
curl -fsS --max-time 5 --cacert /etc/juicefs-portal/tls.crt https://10.20.1.152:8443/api/v1/health >/dev/null
curl -fsS --max-time 5 http://127.0.0.1:9090/-/ready >/dev/null
up_now=$(curl -fsS --max-time 5 'http://127.0.0.1:9090/api/v1/query?query=sum%28up%29')
grep -Fq ',"14"]' <<<"$up_now"
up_window=$(curl -fsS --max-time 5 'http://127.0.0.1:9090/api/v1/query?query=sum%28min_over_time%28up%5B5m%5D%29%29')
grep -Fq ',"14"]' <<<"$up_window"

sudo -n /usr/bin/python3 - /var/lib/juicefs-portal/portal/namespace.db <<'PY'
import datetime, sqlite3, sys

db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
row = db.execute(
    "SELECT current_generation,collected_at,status FROM snapshot_roots "
    "WHERE root_id='juicefs-prod-root'"
).fetchone()
assert row and row[0] >= 1 and row[2] == "ready"
collected = datetime.datetime.fromisoformat(row[1].replace("Z", "+00:00"))
age = (datetime.datetime.now(datetime.timezone.utc) - collected).total_seconds()
assert 0 <= age <= 180
print(f"namespace_generation={row[0]} namespace_age_seconds={age:.1f}")
db.close()
PY

portal_pid=$(systemctl show juicefs-portal.service -p MainPID --value)
[[ "$portal_pid" =~ ^[1-9][0-9]*$ ]]
! sudo -n /usr/bin/nsenter -t "$portal_pid" -m -- /usr/bin/test -e /var/lib/juicefs-portal/namespace-mount

available=$(df -PB1 /var/lib/juicefs-portal | awk 'NR==2 {print $4}')
[[ "$available" =~ ^[0-9]+$ && "$available" -ge 2147483648 ]]
printf 'SAMPLE_152_PASS epoch=%s disk_available_bytes=%s\n' "$(date +%s)" "$available"
