#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t07-update-live-portal.sh /tmp/jfsportal-t07-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t07-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging\n' >&2; exit 1; }
cd "$STAGING"
sha256sum -c SHA256SUMS >/dev/null

expected_t06_prometheus=efbb0c2144add86c0d44e06ad2a324c75c4b8c867084728b2b5ae6d8a3c98ce9
current_prometheus=$(sha256sum /etc/juicefs-portal/prometheus/prometheus.yml | awk '{print $1}')
[[ "$current_prometheus" == "$expected_t06_prometheus" ]] || { printf 'unexpected installed Prometheus config: %s\n' "$current_prometheus" >&2; exit 1; }
/opt/juicefs-portal/bin/promtool check config "$STAGING/config/prometheus.yml" >/dev/null

run_id=${STAGING##*/jfsportal-t07-}
backup=/var/lib/juicefs-portal/t07-backup-$run_id
[[ ! -e "$backup" ]] || { printf 'backup exists: %s\n' "$backup" >&2; exit 1; }
install -d -o root -g root -m 0700 "$backup/web"
install -m 0755 /opt/juicefs-portal/bin/juicefs-portal "$backup/juicefs-portal"
install -m 0640 /etc/juicefs-portal/prometheus/prometheus.yml "$backup/prometheus.yml"
cp -a -- /opt/juicefs-portal/web/. "$backup/web/"

pd_before=$(pgrep -xo pd-server)
tikv_before=$(pgrep -xo tikv-server)
rollback() {
  rc=$?
  trap - ERR
  printf 'T07_UPDATE_FAIL rc=%s; restoring backup\n' "$rc" >&2
  install -o root -g root -m 0755 "$backup/juicefs-portal" /opt/juicefs-portal/bin/juicefs-portal
  rm -f -- /opt/juicefs-portal/web/index.html /opt/juicefs-portal/web/styles.css /opt/juicefs-portal/web/app.js
  cp -a -- "$backup/web/." /opt/juicefs-portal/web/
  install -o root -g jfsportal -m 0640 "$backup/prometheus.yml" /etc/juicefs-portal/prometheus/prometheus.yml
  systemctl restart juicefs-prometheus.service juicefs-portal.service || true
  exit "$rc"
}
trap rollback ERR

install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-portal" /opt/juicefs-portal/bin/juicefs-portal
install -o root -g root -m 0644 "$STAGING/payload/web/index.html" "$STAGING/payload/web/styles.css" "$STAGING/payload/web/app.js" /opt/juicefs-portal/web/
install -o root -g jfsportal -m 0640 "$STAGING/config/prometheus.yml" /etc/juicefs-portal/prometheus/prometheus.yml

systemctl restart juicefs-prometheus.service
for _ in $(seq 1 15); do
  curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null && break
  sleep 1
done
curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null
for _ in $(seq 1 30); do
  result=$(curl -fsS --max-time 3 --get --data-urlencode 'query=count(etcd_server_is_leader{job="pd"})' http://127.0.0.1:9090/api/v1/query)
  grep -Fq '"3"' <<<"$result" && break
  sleep 1
done
grep -Fq '"3"' <<<"$result"

systemctl restart juicefs-portal.service
for _ in $(seq 1 15); do
  curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/health >/dev/null && break
  sleep 1
done
t06_ready=false
for _ in $(seq 1 18); do
  if "$STAGING/scripts/t06-readonly-verify.sh" "$STAGING"; then
    t06_ready=true
    break
  fi
  sleep 5
done
[[ "$t06_ready" == true ]] || { printf 'T06 target readiness did not converge\n' >&2; false; }
"$STAGING/scripts/t07-readonly-verify.sh"
[[ $(pgrep -xo pd-server) == "$pd_before" ]]
[[ $(pgrep -xo tikv-server) == "$tikv_before" ]]

trap - ERR
printf 'T07_UPDATE_PASS backup=%s services_disabled=true\n' "$backup"
