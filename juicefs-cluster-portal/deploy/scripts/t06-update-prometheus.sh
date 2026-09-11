#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t06-update-prometheus.sh STAGING}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t06-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging path\n' >&2; exit 1; }
for item in config/prometheus.yml systemd/juicefs-prometheus.service baseline/prometheus-t05.yml baseline/juicefs-prometheus-t05.service SHA256SUMS; do
  [[ -f "$STAGING/$item" && ! -L "$STAGING/$item" ]] || { printf 'missing staged file: %s\n' "$item" >&2; exit 1; }
done
(cd "$STAGING" && sha256sum -c SHA256SUMS)

config=/etc/juicefs-portal/prometheus/prometheus.yml
unit=/etc/systemd/system/juicefs-prometheus.service
[[ -f "$config" && ! -L "$config" && -f "$unit" && ! -L "$unit" ]] || { printf 'invalid installed Prometheus files\n' >&2; exit 1; }
cmp -s "$config" "$STAGING/baseline/prometheus-t05.yml" || { printf 'installed config differs from T05 baseline\n' >&2; exit 1; }
cmp -s "$unit" "$STAGING/baseline/juicefs-prometheus-t05.service" || { printf 'installed unit differs from T05 baseline\n' >&2; exit 1; }
systemctl is-active --quiet juicefs-prometheus.service || { printf 'Prometheus is not active\n' >&2; exit 1; }
[[ $(systemctl is-enabled juicefs-prometheus.service 2>/dev/null || true) == disabled ]] || { printf 'Prometheus must remain disabled\n' >&2; exit 1; }
/opt/juicefs-portal/bin/promtool check config "$STAGING/config/prometheus.yml"

backup=/var/lib/juicefs-portal/t06-backup
[[ ! -e "$backup" ]] || { printf 'refuse existing backup path: %s\n' "$backup" >&2; exit 1; }
install -d -o root -g jfsportal -m 0750 "$backup"
install -o root -g jfsportal -m 0640 "$config" "$backup/prometheus.yml"
install -o root -g root -m 0644 "$unit" "$backup/juicefs-prometheus.service"

rollback() {
  printf 'T06_PROMETHEUS_ROLLBACK_BEGIN\n' >&2
  install -o root -g jfsportal -m 0640 "$backup/prometheus.yml" "$config"
  install -o root -g root -m 0644 "$backup/juicefs-prometheus.service" "$unit"
  systemctl daemon-reload
  systemctl restart juicefs-prometheus.service
  printf 'T06_PROMETHEUS_ROLLBACK_COMPLETE\n' >&2
}

install -o root -g jfsportal -m 0640 "$STAGING/config/prometheus.yml" "$config"
install -o root -g root -m 0644 "$STAGING/systemd/juicefs-prometheus.service" "$unit"
systemctl daemon-reload
if ! systemctl restart juicefs-prometheus.service; then
  rollback
  exit 1
fi
ready=false
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  rollback
  exit 1
fi
[[ $(systemctl is-enabled juicefs-prometheus.service 2>/dev/null || true) == disabled ]] || { printf 'Prometheus unexpectedly enabled\n' >&2; exit 1; }
printf 'T06_PROMETHEUS_UPDATE_PASS backup=%s enabled=false\n' "$backup"
