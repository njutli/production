#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t06-install-node-observability.sh STAGING EXPECTED_HOST EXPECTED_IP}
EXPECTED_HOST=${2:?missing expected hostname}
EXPECTED_IP=${3:?missing expected IP}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ "$EXPECTED_HOST" =~ ^ceph-node[123]$ ]] || { printf 'invalid expected host\n' >&2; exit 2; }
[[ "$EXPECTED_IP" =~ ^10[.]20[.]1[.](150|151|152)$ ]] || { printf 'invalid expected IP\n' >&2; exit 2; }
[[ $(hostname -s) == "$EXPECTED_HOST" ]] || { printf 'wrong host\n' >&2; exit 1; }
ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$EXPECTED_IP" || { printf 'expected IP absent\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t06-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging path\n' >&2; exit 1; }

required=(
  payload/bin/node_exporter
  payload/bin/collect-nvme-metrics
  systemd/juicefs-node-exporter.service
  systemd/juicefs-nvme-collector.service
  systemd/juicefs-nvme-collector.timer
  SHA256SUMS
)
for item in "${required[@]}"; do
  [[ -f "$STAGING/$item" && ! -L "$STAGING/$item" ]] || { printf 'missing staged file: %s\n' "$item" >&2; exit 1; }
done
(cd "$STAGING" && sha256sum -c SHA256SUMS)
"$STAGING/payload/bin/node_exporter" --version 2>&1 | grep -Fq 'version 1.12.1'

for target in \
  /opt/juicefs-portal/bin/node_exporter \
  /opt/juicefs-portal/bin/collect-nvme-metrics \
  /etc/juicefs-portal/node-exporter.env \
  /var/lib/juicefs-node-exporter \
  /etc/systemd/system/juicefs-node-exporter.service \
  /etc/systemd/system/juicefs-nvme-collector.service \
  /etc/systemd/system/juicefs-nvme-collector.timer; do
  [[ ! -e "$target" ]] || { printf 'refuse existing target: %s\n' "$target" >&2; exit 1; }
done
id -u jfsnode >/dev/null 2>&1 && { printf 'refuse existing user: jfsnode\n' >&2; exit 1; }
getent group jfsnode >/dev/null && { printf 'refuse existing group: jfsnode\n' >&2; exit 1; }
ss -ltnH 'sport = :9100' | grep -q . && { printf 'port 9100 already in use\n' >&2; exit 1; }
for device in /dev/nvme0 /dev/nvme1 /dev/nvme2 /dev/nvme3; do
  [[ -c "$device" ]] || { printf 'missing NVMe controller: %s\n' "$device" >&2; exit 1; }
done
[[ -x /usr/sbin/nvme && -x /usr/bin/python3 ]] || { printf 'required NVMe collector tools absent\n' >&2; exit 1; }
for parent in /opt/juicefs-portal /opt/juicefs-portal/bin /etc/juicefs-portal; do
  [[ ! -e "$parent" || -d "$parent" && ! -L "$parent" ]] || { printf 'unsafe parent path: %s\n' "$parent" >&2; exit 1; }
done

useradd --system --user-group --home-dir /var/lib/juicefs-node-exporter --shell /usr/sbin/nologin jfsnode
install -d -o root -g root -m 0755 /opt/juicefs-portal /opt/juicefs-portal/bin
install -d -o root -g root -m 0755 /etc/juicefs-portal
install -d -o root -g jfsnode -m 0750 /var/lib/juicefs-node-exporter /var/lib/juicefs-node-exporter/textfile
install -o root -g root -m 0755 "$STAGING/payload/bin/node_exporter" "$STAGING/payload/bin/collect-nvme-metrics" /opt/juicefs-portal/bin/
printf 'NODE_EXPORTER_ADDR=%s:9100\n' "$EXPECTED_IP" >/etc/juicefs-portal/node-exporter.env
chown root:jfsnode /etc/juicefs-portal/node-exporter.env
chmod 0640 /etc/juicefs-portal/node-exporter.env
install -o root -g root -m 0644 "$STAGING/systemd/juicefs-node-exporter.service" "$STAGING/systemd/juicefs-nvme-collector.service" "$STAGING/systemd/juicefs-nvme-collector.timer" /etc/systemd/system/
systemctl daemon-reload
[[ $(systemctl is-enabled juicefs-node-exporter.service 2>/dev/null || true) == disabled ]]
[[ $(systemctl is-enabled juicefs-nvme-collector.timer 2>/dev/null || true) == disabled ]]
[[ $(systemctl is-active juicefs-node-exporter.service 2>/dev/null || true) == inactive ]]
[[ $(systemctl is-active juicefs-nvme-collector.timer 2>/dev/null || true) == inactive ]]
printf 'T06_NODE_INSTALL_PASS host=%s ip=%s services_started=false enabled=false\n' "$EXPECTED_HOST" "$EXPECTED_IP"
