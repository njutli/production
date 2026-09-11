#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t05-install-base.sh ABSOLUTE_STAGING_DIR}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t05-* ]] || { printf 'staging path outside approved scope\n' >&2; exit 1; }
[[ -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging directory\n' >&2; exit 1; }

for path in /opt/juicefs-portal /etc/juicefs-portal /var/lib/juicefs-portal /var/log/juicefs-portal; do
  [[ ! -e "$path" ]] || { printf 'refuse existing target: %s\n' "$path" >&2; exit 1; }
done

required=(
  payload/bin/juicefs-portal
  payload/bin/prometheus
  payload/bin/promtool
  payload/grafana/bin/grafana
  payload/web/index.html
  payload/fixtures/overview.json
  config/prometheus.yml
  config/grafana.ini
  config/prometheus-datasource.yaml
  config/dashboard-provider.yaml
  systemd/juicefs-portal.service
  systemd/juicefs-prometheus.service
  systemd/juicefs-grafana.service
  SHA256SUMS
)
for item in "${required[@]}"; do
  [[ -e "$STAGING/$item" ]] || { printf 'missing staged item: %s\n' "$item" >&2; exit 1; }
done
(
  cd "$STAGING"
  sha256sum -c SHA256SUMS
)

getent group jfsportal >/dev/null || groupadd --system jfsportal
id -u jfsportal >/dev/null 2>&1 || useradd --system --gid jfsportal --home-dir /var/lib/juicefs-portal --shell /usr/sbin/nologin jfsportal

install -d -o root -g root -m 0755 /opt/juicefs-portal /opt/juicefs-portal/bin /opt/juicefs-portal/web /opt/juicefs-portal/fixtures /opt/juicefs-portal/grafana /opt/juicefs-portal/dashboards
install -d -o root -g jfsportal -m 0750 /etc/juicefs-portal /etc/juicefs-portal/prometheus /etc/juicefs-portal/grafana /etc/juicefs-portal/grafana/provisioning /etc/juicefs-portal/grafana/provisioning/datasources /etc/juicefs-portal/grafana/provisioning/dashboards
install -d -o jfsportal -g jfsportal -m 0750 /var/lib/juicefs-portal /var/lib/juicefs-portal/prometheus /var/lib/juicefs-portal/grafana /var/lib/juicefs-portal/portal /var/log/juicefs-portal /var/log/juicefs-portal/grafana

install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-portal" "$STAGING/payload/bin/prometheus" "$STAGING/payload/bin/promtool" /opt/juicefs-portal/bin/
cp -a -- "$STAGING/payload/grafana/." /opt/juicefs-portal/grafana/
cp -a -- "$STAGING/payload/web/." /opt/juicefs-portal/web/
cp -a -- "$STAGING/payload/fixtures/." /opt/juicefs-portal/fixtures/
chown -R root:root /opt/juicefs-portal

install -o root -g jfsportal -m 0640 "$STAGING/config/prometheus.yml" /etc/juicefs-portal/prometheus/prometheus.yml
install -o root -g jfsportal -m 0640 "$STAGING/config/grafana.ini" /etc/juicefs-portal/grafana/grafana.ini
install -o root -g jfsportal -m 0640 "$STAGING/config/prometheus-datasource.yaml" /etc/juicefs-portal/grafana/provisioning/datasources/prometheus.yaml
install -o root -g jfsportal -m 0640 "$STAGING/config/dashboard-provider.yaml" /etc/juicefs-portal/grafana/provisioning/dashboards/provider.yaml

admin_token=$(openssl rand -hex 32)
disabled_user_token=$(openssl rand -hex 32)
grafana_password=$(openssl rand -base64 36 | tr -d '\n')
grafana_secret=$(openssl rand -hex 32)
umask 0077
printf 'PORTAL_MODE=live\nPORTAL_ADDR=127.0.0.1:8080\nPORTAL_FIXTURES_DIR=/opt/juicefs-portal/fixtures\nPORTAL_WEB_DIR=/opt/juicefs-portal/web\nPORTAL_ADMIN_TOKEN=%s\nPORTAL_USER_TOKEN=%s\n' "$admin_token" "$disabled_user_token" >/etc/juicefs-portal/portal.env
printf '%s\n' "$grafana_password" >/etc/juicefs-portal/grafana-admin-password
printf '%s\n' "$grafana_secret" >/etc/juicefs-portal/grafana-secret-key
printf 'GF_SECURITY_ADMIN_PASSWORD__FILE=/etc/juicefs-portal/grafana-admin-password\nGF_SECURITY_SECRET_KEY__FILE=/etc/juicefs-portal/grafana-secret-key\n' >/etc/juicefs-portal/grafana.env
chown root:jfsportal /etc/juicefs-portal/portal.env /etc/juicefs-portal/grafana.env /etc/juicefs-portal/grafana-admin-password /etc/juicefs-portal/grafana-secret-key
chmod 0640 /etc/juicefs-portal/portal.env /etc/juicefs-portal/grafana.env /etc/juicefs-portal/grafana-admin-password /etc/juicefs-portal/grafana-secret-key

install -o root -g root -m 0644 "$STAGING/systemd/juicefs-portal.service" "$STAGING/systemd/juicefs-prometheus.service" "$STAGING/systemd/juicefs-grafana.service" /etc/systemd/system/
systemctl daemon-reload
printf 'T05_INSTALL_BASE_PASS services_not_started=true\n'
