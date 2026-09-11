#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t09-update-namespace.sh /tmp/jfsportal-t09-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t09-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging\n' >&2; exit 1; }
"$STAGING/scripts/t09-readonly-preflight.sh" "$STAGING"

run_id=${STAGING##*/jfsportal-t09-}
backup=/var/lib/juicefs-portal/t09-backup-$run_id
[[ ! -e "$backup" ]] || { printf 'backup exists: %s\n' "$backup" >&2; exit 1; }
install -d -o root -g root -m 0700 "$backup"
install -m 0755 /opt/juicefs-portal/bin/juicefs-portal "$backup/juicefs-portal"
install -m 0644 /opt/juicefs-portal/web/index.html "$backup/index.html"
install -m 0644 /opt/juicefs-portal/web/styles.css "$backup/styles.css"
install -m 0644 /opt/juicefs-portal/web/app.js "$backup/app.js"
install -m 0640 /etc/juicefs-portal/users.json "$backup/users.json"
install -m 0640 /etc/juicefs-portal/portal.env "$backup/portal.env"
install -m 0755 "$STAGING/scripts/t09-rollback-namespace.sh" "$backup/t09-rollback-namespace.sh"
pgrep -xo pd-server >"$backup/pd.pid"
pgrep -xo tikv-server >"$backup/tikv.pid"
findmnt -rn /mnt/jfs-tikv >"$backup/jfs-tikv.findmnt"
findmnt -rn /mnt/dbwal >"$backup/dbwal.findmnt"

python3 - "$backup/users.json" "$backup/users.updated.json" <<'PY'
import json, pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
document = json.loads(source.read_text())
matches = [u for u in document.get("users", []) if u.get("username") == "user"]
assert document.get("version") == 1 and len(matches) == 1 and matches[0].get("role") == "USER"
roots = matches[0].setdefault("namespaceRoots", [])
assert "juicefs-prod-root" not in roots
roots.append("juicefs-prod-root")
target.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
target.chmod(0o600)
PY
cp -- "$backup/portal.env" "$backup/portal.env.updated"
printf 'PORTAL_NAMESPACE_DB=/var/lib/juicefs-portal/portal/namespace.db\n' >>"$backup/portal.env.updated"

rollback() {
  local rc=$?
  trap - ERR
  printf 'T09_UPDATE_FAIL rc=%s; invoking exact rollback\n' "$rc" >&2
  "$STAGING/scripts/t09-rollback-namespace.sh" "$backup" || printf 'T09_ROLLBACK_FAILED; preserve host state and inspect manually\n' >&2
  exit "$rc"
}
trap rollback ERR

keyring_temp=$backup/ceph.client.juicefs.keyring.new
keyring_marker=$backup/ceph.client.juicefs.keyring.sha256
(
  umask 0077
  ceph auth get client.juicefs >"$keyring_temp" 2>/dev/null
)
[[ -s "$keyring_temp" && ! -L "$keyring_temp" ]]
grep -Fxq '[client.juicefs]' "$keyring_temp"
grep -Fq 'caps mon = "allow r"' "$keyring_temp"
grep -Fq 'caps osd = "allow class-read object_prefix rbd_directory_pool, allow rwx pool=juicefs-data"' "$keyring_temp"
sha256sum "$keyring_temp" | awk '{print $1}' >"$keyring_marker"

install -d -o jfsportal -g jfsportal -m 0700 /var/lib/juicefs-portal/namespace-mount /var/lib/juicefs-portal/namespace-runtime
install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-portal" /opt/juicefs-portal/bin/juicefs-portal
install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-namespace-collector" /opt/juicefs-portal/bin/juicefs-namespace-collector
install -o root -g root -m 0755 "$STAGING/payload/bin/juicefs-ro" /opt/juicefs-portal/bin/juicefs-ro
install -o root -g root -m 0644 "$STAGING/payload/web/index.html" "$STAGING/payload/web/styles.css" "$STAGING/payload/web/app.js" /opt/juicefs-portal/web/
install -o root -g jfsportal -m 0640 "$keyring_temp" /etc/ceph/ceph.client.juicefs.keyring
rm -f -- "$keyring_temp"
runuser -u jfsportal -- ceph --name client.juicefs --keyring /etc/ceph/ceph.client.juicefs.keyring osd pool ls 2>/dev/null | grep -Fxq juicefs-data
install -o root -g jfsportal -m 0640 "$backup/users.updated.json" /etc/juicefs-portal/users.json
install -o root -g jfsportal -m 0640 "$backup/portal.env.updated" /etc/juicefs-portal/portal.env
install -o root -g jfsportal -m 0640 "$STAGING/config/namespace.env" /etc/juicefs-portal/namespace.env
install -o root -g jfsportal -m 0640 "$STAGING/config/namespace-roots.json" /etc/juicefs-portal/namespace-roots.json
install -o root -g root -m 0644 "$STAGING/systemd/juicefs-namespace-mount.service" "$STAGING/systemd/juicefs-namespace-collector.service" "$STAGING/systemd/juicefs-namespace-collector.timer" /etc/systemd/system/
portal_dropin=/etc/systemd/system/juicefs-portal.service.d/50-t09-namespace.conf
sha256sum "$STAGING/systemd/juicefs-portal-t09-namespace.conf" | awk '{print $1}' >"$backup/portal-t09-namespace.sha256"
install -d -o root -g root -m 0755 /etc/systemd/system/juicefs-portal.service.d
install -o root -g root -m 0644 "$STAGING/systemd/juicefs-portal-t09-namespace.conf" "$portal_dropin"
systemctl daemon-reload
systemctl start juicefs-namespace-mount.service
for _ in $(seq 1 60); do
  if findmnt -rn /var/lib/juicefs-portal/namespace-mount >/dev/null 2>&1; then break; fi
  sleep 1
done
findmnt -rn /var/lib/juicefs-portal/namespace-mount >/dev/null
systemctl start juicefs-namespace-collector.service
[[ -s /var/lib/juicefs-portal/portal/namespace.db ]] || {
  printf 'collector did not create namespace database\n' >&2
  exit 1
}
systemctl start juicefs-namespace-collector.timer
systemctl restart juicefs-portal.service
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/health >/dev/null && break
  sleep 1
done
"$STAGING/scripts/t09-readonly-verify.sh" "$STAGING" "$backup"

trap - ERR
printf 'T09_UPDATE_PASS backup=%s rollback=%s/t09-rollback-namespace.sh services_not_enabled=true\n' "$backup" "$backup"
