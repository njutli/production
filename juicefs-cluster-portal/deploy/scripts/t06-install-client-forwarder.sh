#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t06-install-client-forwarder.sh STAGING}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == oneasia-c1-cpu-node10 ]] || { printf 'wrong host\n' >&2; exit 1; }
ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq 10.20.1.157 || { printf 'expected IP absent\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t06-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging path\n' >&2; exit 1; }
for item in payload/bin/juicefs-metrics-forwarder systemd/juicefs-metrics-forwarder.service SHA256SUMS; do
  [[ -f "$STAGING/$item" && ! -L "$STAGING/$item" ]] || { printf 'missing staged file: %s\n' "$item" >&2; exit 1; }
done
(cd "$STAGING" && sha256sum -c SHA256SUMS)
curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:9567/metrics >/dev/null
ss -ltnH 'sport = :9633' | grep -q . && { printf 'port 9633 already in use\n' >&2; exit 1; }
for target in /opt/juicefs-portal/bin/juicefs-metrics-forwarder /etc/systemd/system/juicefs-metrics-forwarder.service; do
  [[ ! -e "$target" ]] || { printf 'refuse existing target: %s\n' "$target" >&2; exit 1; }
done
id -u jfsmetrics >/dev/null 2>&1 && { printf 'refuse existing user: jfsmetrics\n' >&2; exit 1; }
getent group jfsmetrics >/dev/null && { printf 'refuse existing group: jfsmetrics\n' >&2; exit 1; }
for parent in /opt/juicefs-portal /opt/juicefs-portal/bin; do
  [[ ! -e "$parent" || -d "$parent" && ! -L "$parent" ]] || { printf 'unsafe parent path: %s\n' "$parent" >&2; exit 1; }
done

useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin jfsmetrics
install -d -o root -g root -m 0755 /opt/juicefs-portal /opt/juicefs-portal/bin
install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-metrics-forwarder" /opt/juicefs-portal/bin/juicefs-metrics-forwarder
install -o root -g root -m 0644 "$STAGING/systemd/juicefs-metrics-forwarder.service" /etc/systemd/system/juicefs-metrics-forwarder.service
systemctl daemon-reload
[[ $(systemctl is-enabled juicefs-metrics-forwarder.service 2>/dev/null || true) == disabled ]]
[[ $(systemctl is-active juicefs-metrics-forwarder.service 2>/dev/null || true) == inactive ]]
printf 'T06_FORWARDER_INSTALL_PASS services_started=false enabled=false\n'
