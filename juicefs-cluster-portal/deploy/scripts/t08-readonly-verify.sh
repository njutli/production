#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { printf 'must run as root to read authentication fixtures\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }

for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
done
ss -H -ltn 'sport = :8080' | grep -Fq '127.0.0.1:8080'
ss -H -ltn 'sport = :8443' | grep -Fq '10.20.1.152:8443'
curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/health | grep -Fq '"mode":"live"'
curl -fsS --max-time 5 --cacert /etc/juicefs-portal/tls.crt https://10.20.1.152:8443/api/v1/health | grep -Fq '"mode":"live"'
openssl x509 -in /etc/juicefs-portal/tls.crt -noout -checkend 2592000 >/dev/null

verify_dir=$(mktemp -d /tmp/jfsportal-t08-verify.XXXXXX)
cleanup() {
  [[ "$verify_dir" == /tmp/jfsportal-t08-verify.* ]] && rm -rf -- "$verify_dir"
}
trap cleanup EXIT

admin_password=$(sed -n 's/^admin=//p' /etc/juicefs-portal/bootstrap-credentials.txt)
user_password=$(sed -n 's/^user=//p' /etc/juicefs-portal/bootstrap-credentials.txt)
[[ "$admin_password" =~ ^[0-9a-f]{48}$ ]]
[[ "$user_password" =~ ^[0-9a-f]{48}$ ]]

login() {
  local username=$1
  local password=$2
  local prefix=$3
  local status
  status=$(printf '{"username":"%s","password":"%s"}' "$username" "$password" | \
    curl -sS --max-time 10 --cacert /etc/juicefs-portal/tls.crt \
      -D "$verify_dir/$prefix.headers" -c "$verify_dir/$prefix.cookies" \
      -o "$verify_dir/$prefix.login.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary @- \
      https://10.20.1.152:8443/api/v1/session)
  [[ "$status" == 200 ]]
  grep -Eiq '^Set-Cookie: jfsportal_session=.*HttpOnly.*Secure.*SameSite=Strict' "$verify_dir/$prefix.headers"
}

login admin "$admin_password" admin
curl -fsS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/admin.cookies" \
  https://10.20.1.152:8443/api/v1/me >"$verify_dir/admin.me.json"
grep -Fq '"subject":"admin"' "$verify_dir/admin.me.json"
grep -Fq '"role":"ADMIN"' "$verify_dir/admin.me.json"
curl -fsS --max-time 10 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/admin.cookies" \
  https://10.20.1.152:8443/api/v1/admin/overview | grep -Fq '"source":"prometheus"'

login user "$user_password" user
curl -fsS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/user.cookies" \
  https://10.20.1.152:8443/api/v1/me >"$verify_dir/user.me.json"
grep -Fq '"subject":"user"' "$verify_dir/user.me.json"
grep -Fq '"role":"USER"' "$verify_dir/user.me.json"
user_admin_status=$(curl -sS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/user.cookies" \
  -o /dev/null -w '%{http_code}' https://10.20.1.152:8443/api/v1/admin/overview)
[[ "$user_admin_status" == 403 ]]
anonymous_status=$(curl -sS --max-time 8 --cacert /etc/juicefs-portal/tls.crt \
  -o /dev/null -w '%{http_code}' https://10.20.1.152:8443/api/v1/admin/overview)
[[ "$anonymous_status" == 401 ]]
write_status=$(curl -sS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/admin.cookies" \
  -X POST -o /dev/null -w '%{http_code}' https://10.20.1.152:8443/api/v1/admin/overview)
[[ "$write_status" == 405 ]]
grep -Eiq '^Strict-Transport-Security: max-age=31536000' "$verify_dir/admin.headers"
grep -Eiq '^Content-Security-Policy:' "$verify_dir/admin.headers"

pgrep -x pd-server >/dev/null
pgrep -x tikv-server >/dev/null
findmnt -rn /mnt/jfs-tikv >/dev/null
findmnt -rn /mnt/dbwal >/dev/null
printf 'T08_READONLY_VERIFY_PASS admin=200 user_admin=403 anonymous=401 write=405 services_disabled=true\n'
