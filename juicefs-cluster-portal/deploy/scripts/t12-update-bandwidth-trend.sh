#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t12-update-bandwidth-trend.sh /tmp/jfsportal-t12-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t12-* && -d "$STAGING/payload/web" && ! -L "$STAGING" ]] || { printf 'invalid staging\n' >&2; exit 1; }

target=/opt/juicefs-portal/web
[[ -d "$target" && ! -L "$target" ]]
for name in index.html app.js styles.css; do
  [[ -f "$target/$name" && ! -L "$target/$name" ]]
  [[ -f "$STAGING/payload/web/$name" && ! -L "$STAGING/payload/web/$name" ]]
done

printf '%s  %s\n' \
  9d2d639ba8bda07ad4440e34f954c6cc2889190b424c3c17955fe29d0787353d "$STAGING/payload/web/index.html" \
  205e248c2a65f25888ab0597e010c9ef4c08a836104942ec4140940a0cdb9fed "$STAGING/payload/web/app.js" \
  d2dfefcdfb166bf86cbdc9afea3eea62a85c232fc70e2590675db24d9a58b706 "$STAGING/payload/web/styles.css" | sha256sum -c - >/dev/null

printf '%s  %s\n' \
  cd3d850a458aa1fcc2ae476f1c31f73cf8ace0285d478001664c3dcd8ba0a2d2 "$target/index.html" \
  0400fe989ee5ad95931cc466bf87d96c78057ffb9f5ec4f1f2a3331e7e562999 "$target/app.js" \
  4d6efab26d331bb31014bf167150b5a95f695b281d1db17e07152e54c51ec0df "$target/styles.css" | sha256sum -c - >/dev/null

for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl show "$service" -p NRestarts --value) == 0 ]]
done

run_id=${STAGING##*/jfsportal-t12-}
backup=/var/lib/juicefs-portal/t12-backup-$run_id
[[ ! -e "$backup" ]]
install -d -o root -g root -m 0700 "$backup"
install -o root -g root -m 0644 "$target/index.html" "$target/app.js" "$target/styles.css" "$backup/"

rollback() {
  rc=$?
  trap - ERR
  install -o root -g root -m 0644 "$backup/index.html" "$backup/app.js" "$backup/styles.css" "$target/"
  printf 'T12_UPDATE_FAIL rc=%s restored=%s\n' "$rc" "$backup" >&2
  exit "$rc"
}
trap rollback ERR

install -o root -g root -m 0644 \
  "$STAGING/payload/web/index.html" "$STAGING/payload/web/app.js" "$STAGING/payload/web/styles.css" \
  "$target/"

printf '%s  %s\n' \
  9d2d639ba8bda07ad4440e34f954c6cc2889190b424c3c17955fe29d0787353d "$target/index.html" \
  205e248c2a65f25888ab0597e010c9ef4c08a836104942ec4140940a0cdb9fed "$target/app.js" \
  d2dfefcdfb166bf86cbdc9afea3eea62a85c232fc70e2590675db24d9a58b706 "$target/styles.css" | sha256sum -c - >/dev/null

curl -fsS --max-time 5 http://127.0.0.1:8080/ | grep -Fq 'id="bandwidth-svg"'
curl -fsS --max-time 5 'http://127.0.0.1:8080/app.js?v=20260914-bandwidth' | grep -Fq 'refreshBandwidthChart'
curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/health | grep -Fq '"status":"ok"'
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  systemctl is-active --quiet "$service"
  [[ $(systemctl show "$service" -p NRestarts --value) == 0 ]]
done

trap - ERR
printf 'T12_UPDATE_PASS backup=%s services_restarted=false\n' "$backup"
