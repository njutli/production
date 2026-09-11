#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t08-update-auth.sh /tmp/jfsportal-t08-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t08-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging\n' >&2; exit 1; }
cd "$STAGING"
sha256sum -c SHA256SUMS >/dev/null

expected_binary=252cceb69cd283024f83680a5de64698c64a425131a7056f16ac8c7da91b1883
expected_index=68b7b0a0a7fdd77d3028b5e300ed2571a5e7c0f5bfb58c179afc7235217cf3d3
expected_styles=c70f44f92855f7792cec14dc614946b90f5b5744c4ae47af52a6dbfd15c8aca6
expected_app=fe5a62fc7b2e51fb05443af0376f684e5e54ff907b2ef159d34ffa0981dc9f1d
expected_unit=01fa8ecb8f1ff26cf5754a1ea92886bc0153011d93cef31c29e1c9543ecd63fe
[[ $(sha256sum /opt/juicefs-portal/bin/juicefs-portal | awk '{print $1}') == "$expected_binary" ]]
[[ $(sha256sum /opt/juicefs-portal/web/index.html | awk '{print $1}') == "$expected_index" ]]
[[ $(sha256sum /opt/juicefs-portal/web/styles.css | awk '{print $1}') == "$expected_styles" ]]
[[ $(sha256sum /opt/juicefs-portal/web/app.js | awk '{print $1}') == "$expected_app" ]]
[[ $(sha256sum /etc/systemd/system/juicefs-portal.service | awk '{print $1}') == "$expected_unit" ]]
systemctl is-active --quiet juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service
[[ $(systemctl is-enabled juicefs-portal.service 2>/dev/null || true) == disabled ]]
[[ -z $(ss -H -ltn 'sport = :8443') ]]
for path in \
  /opt/juicefs-portal/bin/portal-userctl \
  /etc/juicefs-portal/users.json \
  /etc/juicefs-portal/session-secret \
  /etc/juicefs-portal/bootstrap-credentials.txt \
  /etc/juicefs-portal/tls.crt \
  /etc/juicefs-portal/tls.key; do
  [[ ! -e "$path" ]] || { printf 'refuse existing T08 path: %s\n' "$path" >&2; exit 1; }
done

run_id=${STAGING##*/jfsportal-t08-}
backup=/var/lib/juicefs-portal/t08-backup-$run_id
[[ ! -e "$backup" ]] || { printf 'backup exists: %s\n' "$backup" >&2; exit 1; }
install -d -o root -g root -m 0700 "$backup/web"
install -m 0755 /opt/juicefs-portal/bin/juicefs-portal "$backup/juicefs-portal"
install -m 0640 /etc/juicefs-portal/portal.env "$backup/portal.env"
install -m 0644 /etc/systemd/system/juicefs-portal.service "$backup/juicefs-portal.service"
cp -a -- /opt/juicefs-portal/web/. "$backup/web/"

pd_before=$(pgrep -xo pd-server)
tikv_before=$(pgrep -xo tikv-server)
rollback() {
  rc=$?
  trap - ERR
  printf 'T08_UPDATE_FAIL rc=%s; restoring backup\n' "$rc" >&2
  install -o root -g root -m 0755 "$backup/juicefs-portal" /opt/juicefs-portal/bin/juicefs-portal
  rm -f -- /opt/juicefs-portal/bin/portal-userctl
  rm -f -- /opt/juicefs-portal/web/index.html /opt/juicefs-portal/web/styles.css /opt/juicefs-portal/web/app.js
  cp -a -- "$backup/web/." /opt/juicefs-portal/web/
  install -o root -g jfsportal -m 0640 "$backup/portal.env" /etc/juicefs-portal/portal.env
  install -o root -g root -m 0644 "$backup/juicefs-portal.service" /etc/systemd/system/juicefs-portal.service
  rm -f -- /etc/juicefs-portal/users.json /etc/juicefs-portal/session-secret /etc/juicefs-portal/bootstrap-credentials.txt /etc/juicefs-portal/tls.crt /etc/juicefs-portal/tls.key
  systemctl daemon-reload
  systemctl restart juicefs-portal.service || true
  exit "$rc"
}
trap rollback ERR

install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-portal" /opt/juicefs-portal/bin/juicefs-portal
install -o root -g root -m 0755 "$STAGING/payload/bin/portal-userctl" /opt/juicefs-portal/bin/portal-userctl
install -o root -g root -m 0644 "$STAGING/payload/web/index.html" "$STAGING/payload/web/styles.css" "$STAGING/payload/web/app.js" /opt/juicefs-portal/web/

/opt/juicefs-portal/bin/portal-userctl init \
  --users-file /etc/juicefs-portal/users.json \
  --secret-file /etc/juicefs-portal/session-secret \
  --credentials-file /etc/juicefs-portal/bootstrap-credentials.txt >/dev/null
chown root:jfsportal /etc/juicefs-portal/users.json /etc/juicefs-portal/session-secret
chmod 0640 /etc/juicefs-portal/users.json /etc/juicefs-portal/session-secret
chown root:root /etc/juicefs-portal/bootstrap-credentials.txt
chmod 0600 /etc/juicefs-portal/bootstrap-credentials.txt

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 397 \
  -subj '/CN=ceph-node3' \
  -addext 'subjectAltName=DNS:ceph-node3,DNS:localhost,IP:10.20.1.152,IP:127.0.0.1' \
  -keyout /etc/juicefs-portal/tls.key \
  -out /etc/juicefs-portal/tls.crt >/dev/null 2>&1
chown root:jfsportal /etc/juicefs-portal/tls.key
chmod 0640 /etc/juicefs-portal/tls.key
chown root:root /etc/juicefs-portal/tls.crt
chmod 0644 /etc/juicefs-portal/tls.crt

cp -- "$backup/portal.env" "$backup/portal.env.t08"
grep -E '^PORTAL_(USERS_FILE|SESSION_SECRET_FILE|SESSION_TTL|SECURE_COOKIES|TLS_ADDR|TLS_CERT_FILE|TLS_KEY_FILE)=' "$STAGING/config/portal.env.template" >>"$backup/portal.env.t08"
install -o root -g jfsportal -m 0640 "$backup/portal.env.t08" /etc/juicefs-portal/portal.env
install -o root -g root -m 0644 "$STAGING/systemd/juicefs-portal.service" /etc/systemd/system/juicefs-portal.service
systemctl daemon-reload
systemctl restart juicefs-portal.service

for _ in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/health >/dev/null && \
    curl -fsS --max-time 2 --cacert /etc/juicefs-portal/tls.crt https://10.20.1.152:8443/api/v1/health >/dev/null && break
  sleep 1
done
"$STAGING/scripts/t08-readonly-verify.sh"
[[ $(pgrep -xo pd-server) == "$pd_before" ]]
[[ $(pgrep -xo tikv-server) == "$tikv_before" ]]

trap - ERR
printf 'T08_UPDATE_PASS backup=%s bootstrap=/etc/juicefs-portal/bootstrap-credentials.txt services_disabled=true\n' "$backup"
