#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t10-management-failure-isolation.sh /tmp/jfsportal-t10-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t10-* && -d "$STAGING" && ! -L "$STAGING" ]] || {
  printf 'invalid staging\n' >&2
  exit 1
}
cd "$STAGING"
sha256sum -c SHA256SUMS >/dev/null

[[ $(sha256sum /etc/systemd/system/juicefs-portal.service | awk '{print $1}') == 80d6808ca151c2cc946ab31d320c8daeb4270555847022db929e5737e8594c5f ]]
[[ $(sha256sum /etc/systemd/system/juicefs-prometheus.service | awk '{print $1}') == 8e26349e2354eb562808683fe41b0a541b30d9445ca6c0425764c6306163b09c ]]
[[ $(sha256sum /opt/juicefs-portal/bin/juicefs-portal | awk '{print $1}') == 3a0ccdc4604d9186595985792b6faf844045dc4b1faec3c53fa6baf6f9c33384 ]]
[[ $(sha256sum /etc/systemd/system/juicefs-namespace-mount.service | awk '{print $1}') == d6de55b966c530fa64bab39ffc893fc32433544cff81b4069edfc3f5b830bf5f ]]
[[ $(sha256sum /etc/systemd/system/juicefs-namespace-collector.service | awk '{print $1}') == 72a7c5e3812825cba6b555223860a52bb2ac7654c9f175519d9bcd72ebc167b2 ]]
[[ $(sha256sum /etc/systemd/system/juicefs-namespace-collector.timer | awk '{print $1}') == 7592b47dba45aa00220bafa3b742d329db91c49dd9df66e59de8ae6cc4efdd7f ]]
[[ $(sha256sum /etc/systemd/system/juicefs-portal.service.d/50-t09-namespace.conf | awk '{print $1}') == 9eb4a2b216168fbcaad2ce9a127298141d5d2d7058b85b543c1809c42879794f ]]
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
done
for service in juicefs-namespace-mount.service juicefs-namespace-collector.timer; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == static ]]
done
[[ $(systemctl is-active juicefs-namespace-collector.service 2>/dev/null || true) == inactive ]]
[[ $(systemctl is-enabled juicefs-namespace-collector.service 2>/dev/null || true) == static ]]

token=$(sed -n 's/^PORTAL_ADMIN_TOKEN=//p' /etc/juicefs-portal/portal.env)
[[ "$token" =~ ^[0-9a-f]{64}$ ]]
auth="Authorization: Bearer $token"
pd_before=$(pgrep -xo pd-server)
tikv_before=$(pgrep -xo tikv-server)
tikv_mount_before=$(findmnt -rn /mnt/jfs-tikv)
dbwal_mount_before=$(findmnt -rn /mnt/dbwal)
namespace_mount_before=$(findmnt -rn -M /var/lib/juicefs-portal/namespace-mount)
namespace_mount_pid_before=$(systemctl show juicefs-namespace-mount.service -p MainPID --value)
[[ -n "$pd_before" && -n "$tikv_before" && -n "$tikv_mount_before" && -n "$dbwal_mount_before" ]]
[[ -n "$namespace_mount_before" && "$namespace_mount_pid_before" =~ ^[1-9][0-9]*$ ]]

recover_management() {
  local rc=$?
  local recovery_failed=0
  trap - EXIT
  set +e
  systemctl is-active --quiet juicefs-prometheus.service || \
    systemctl start juicefs-prometheus.service || recovery_failed=1
  systemctl is-active --quiet juicefs-portal.service || \
    systemctl start juicefs-portal.service || recovery_failed=1
  if [[ $recovery_failed -ne 0 ]]; then
    printf 'T10_FAILURE_ISOLATION_RECOVERY_FAILED; manual management-service recovery required\n' >&2
  fi
  if [[ $rc -ne 0 ]]; then
    printf 'T10_FAILURE_ISOLATION_FAIL rc=%s; management services restored\n' "$rc" >&2
  fi
  exit "$rc"
}
trap recover_management EXIT

verify_business() {
  [[ $(pgrep -xo pd-server) == "$pd_before" ]]
  [[ $(pgrep -xo tikv-server) == "$tikv_before" ]]
  [[ $(findmnt -rn /mnt/jfs-tikv) == "$tikv_mount_before" ]]
  [[ $(findmnt -rn /mnt/dbwal) == "$dbwal_mount_before" ]]
}

verify_namespace() {
  systemctl is-active --quiet juicefs-namespace-mount.service
  systemctl is-active --quiet juicefs-namespace-collector.timer
  [[ $(systemctl show juicefs-namespace-mount.service -p MainPID --value) == "$namespace_mount_pid_before" ]]
  [[ $(findmnt -rn -M /var/lib/juicefs-portal/namespace-mount) == "$namespace_mount_before" ]]
  python3 - /var/lib/juicefs-portal/portal/namespace.db <<'PY'
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
db.close()
PY
}

verify_portal_namespace_isolation() {
  local portal_pid
  systemctl show juicefs-portal.service -p InaccessiblePaths --value | tr ' ' '\n' | \
    grep -Fxq /var/lib/juicefs-portal/namespace-mount
  portal_pid=$(systemctl show juicefs-portal.service -p MainPID --value)
  [[ "$portal_pid" =~ ^[1-9][0-9]*$ ]]
  ! nsenter -t "$portal_pid" -m -- test -e /var/lib/juicefs-portal/namespace-mount
}

verify_ceph_metric() {
  local body
  body=$(curl -fsS --max-time 5 'http://127.0.0.1:9090/api/v1/query?query=ceph_health_status')
  grep -Fq ',"0"]' <<<"$body"
}

wait_portal() {
  local ready=0
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/health >/dev/null && \
      curl -fsS --max-time 2 --cacert /etc/juicefs-portal/tls.crt \
        https://10.20.1.152:8443/api/v1/health >/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ $ready -eq 1 ]]
}

curl -fsS --max-time 10 -H "$auth" http://127.0.0.1:8080/api/v1/admin/overview >/dev/null
verify_ceph_metric
verify_business
verify_namespace
verify_portal_namespace_isolation

systemctl stop juicefs-portal.service
[[ $(systemctl is-active juicefs-portal.service 2>/dev/null || true) == inactive ]]
systemctl is-active --quiet juicefs-prometheus.service
if curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1; then
  printf 'portal endpoint remained reachable after stop\n' >&2
  exit 1
fi
verify_ceph_metric
verify_business
verify_namespace
systemctl start juicefs-portal.service
wait_portal
verify_portal_namespace_isolation

curl -fsS --max-time 10 -H "$auth" http://127.0.0.1:8080/api/v1/admin/overview >/dev/null
curl -fsS --max-time 10 -H "$auth" http://127.0.0.1:8080/api/v1/usage/roots | grep -Fq '"id":"juicefs-prod-root"'
systemctl stop juicefs-prometheus.service
[[ $(systemctl is-active juicefs-prometheus.service 2>/dev/null || true) == inactive ]]
systemctl is-active --quiet juicefs-portal.service
sleep 10
stale=$(curl -fsS --max-time 15 -H "$auth" http://127.0.0.1:8080/api/v1/admin/overview)
grep -Fq '"freshness":"stale"' <<<"$stale"
grep -Fq '"error":' <<<"$stale"
verify_business
verify_namespace

systemctl start juicefs-prometheus.service
prom_ready=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null; then
    up=$(curl -fsS --max-time 3 'http://127.0.0.1:9090/api/v1/query?query=sum%28up%29' || true)
    if grep -Fq ',"14"]' <<<"$up"; then
      prom_ready=1
      break
    fi
  fi
  sleep 1
done
[[ $prom_ready -eq 1 ]]

fresh=$(curl -fsS --max-time 15 -H "$auth" http://127.0.0.1:8080/api/v1/admin/overview)
grep -Fq '"freshness":"fresh"' <<<"$fresh"
verify_ceph_metric
verify_business
verify_namespace
verify_portal_namespace_isolation
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
  [[ $(systemctl show "$service" -p NRestarts --value) == 0 ]]
done

trap - EXIT
printf 'T10_FAILURE_ISOLATION_PASS portal_stop=true prometheus_stale=true targets=14 services_disabled=true\n'
