#!/usr/bin/env bash
set -euo pipefail

STAGING=${1:?usage: t09-readonly-verify.sh /tmp/jfsportal-t09-RUN_ID /var/lib/juicefs-portal/t09-backup-RUN_ID}
BACKUP=${2:?usage: t09-readonly-verify.sh /tmp/jfsportal-t09-RUN_ID /var/lib/juicefs-portal/t09-backup-RUN_ID}
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
[[ "$STAGING" == /tmp/jfsportal-t09-* && -d "$STAGING" && ! -L "$STAGING" ]] || { printf 'invalid staging\n' >&2; exit 1; }
[[ "$BACKUP" == /var/lib/juicefs-portal/t09-backup-* && -d "$BACKUP" && ! -L "$BACKUP" ]] || { printf 'invalid backup\n' >&2; exit 1; }

for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service juicefs-namespace-mount.service juicefs-namespace-collector.timer; do
  systemctl is-active --quiet "$service"
done
for service in juicefs-portal.service juicefs-prometheus.service juicefs-grafana.service; do
  [[ $(systemctl is-enabled "$service" 2>/dev/null || true) == disabled ]]
done
for service in juicefs-namespace-mount.service juicefs-namespace-collector.service juicefs-namespace-collector.timer; do
  state=$(systemctl is-enabled "$service" 2>/dev/null || true)
  [[ "$state" == static || "$state" == disabled ]]
done
[[ $(stat -Lc '%a %U:%G' /etc/ceph/ceph.client.juicefs.keyring) == '640 root:jfsportal' ]]
runuser -u jfsportal -- ceph --name client.juicefs --keyring /etc/ceph/ceph.client.juicefs.keyring osd pool ls 2>/dev/null | grep -Fxq juicefs-data

mount_row=$(findmnt -rn -o SOURCE,FSTYPE,OPTIONS /var/lib/juicefs-portal/namespace-mount)
grep -Fq 'JuiceFS:juicefs-prod' <<<"$mount_row"
grep -Fq 'fuse.juicefs' <<<"$mount_row"
mount_options=$(awk '{print $3}' <<<"$mount_row")
grep -Eq '(^|,)rw(,|$)' <<<"$mount_options"
! grep -Eq '(^|,)(allow_other|allow_root)(,|$)' <<<"$mount_options"
systemctl show juicefs-portal.service -p InaccessiblePaths --value | tr ' ' '\n' | grep -Fxq /var/lib/juicefs-portal/namespace-mount

python3 - /var/lib/juicefs-portal/portal/namespace.db <<'PY'
import datetime, pathlib, sqlite3, sys
path = pathlib.Path(sys.argv[1])
assert path.is_file() and not path.is_symlink()
db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert db.execute("PRAGMA user_version").fetchone()[0] == 1
row = db.execute("SELECT current_generation, file_count, dir_count, collected_at, status FROM snapshot_roots WHERE root_id=?", ("juicefs-prod-root",)).fetchone()
assert row and row[0] >= 1 and row[1] >= 0 and row[2] >= 0 and row[4] == "ready"
collected = datetime.datetime.fromisoformat(row[3].replace("Z", "+00:00"))
assert 0 <= (datetime.datetime.now(datetime.timezone.utc) - collected).total_seconds() <= 180
assert db.execute("SELECT count(*) FROM namespace_entries WHERE root_id=? AND generation=?", ("juicefs-prod-root", row[0])).fetchone()[0] >= 1
assert db.execute("SELECT count(*) FROM namespace_entries WHERE root_id=? AND generation=? AND kind NOT IN ('directory','file','aggregate')", ("juicefs-prod-root", row[0])).fetchone()[0] == 0
assert db.execute("SELECT count(*) FROM namespace_entries WHERE root_id=? AND generation=? AND kind='file' AND (dir_count != 0 OR file_count != 1)", ("juicefs-prod-root", row[0])).fetchone()[0] == 0
assert db.execute("SELECT count(*) FROM namespace_entries WHERE root_id=? AND generation=? AND kind='aggregate' AND dir_count = 0 AND file_count = 0", ("juicefs-prod-root", row[0])).fetchone()[0] == 0
db.close()
PY

run_id=${STAGING##*/jfsportal-t09-}
verify_dir=/tmp/jfsportal-t09-verify-$run_id
[[ ! -e "$verify_dir" ]]
install -d -o root -g root -m 0700 "$verify_dir"
admin_password=$(sed -n 's/^admin=//p' /etc/juicefs-portal/bootstrap-credentials.txt)
user_password=$(sed -n 's/^user=//p' /etc/juicefs-portal/bootstrap-credentials.txt)
[[ "$admin_password" =~ ^[0-9a-f]{48}$ && "$user_password" =~ ^[0-9a-f]{48}$ ]]

login() {
  local username=$1 password=$2 prefix=$3 status
  status=$(printf '{"username":"%s","password":"%s"}' "$username" "$password" | \
    curl -sS --max-time 10 --cacert /etc/juicefs-portal/tls.crt \
      -D "$verify_dir/$prefix.headers" -c "$verify_dir/$prefix.cookies" \
      -o "$verify_dir/$prefix.login.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary @- \
      https://10.20.1.152:8443/api/v1/session)
  [[ "$status" == 200 ]]
}
login admin "$admin_password" admin
login user "$user_password" user
curl -fsS --max-time 10 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/admin.cookies" https://10.20.1.152:8443/api/v1/usage/roots >"$verify_dir/admin.roots.json"
curl -fsS --max-time 10 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/user.cookies" https://10.20.1.152:8443/api/v1/usage/roots >"$verify_dir/user.roots.json"
curl -fsS --max-time 10 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/user.cookies" 'https://10.20.1.152:8443/api/v1/usage/tree?rootId=juicefs-prod-root&maxDepth=3' >"$verify_dir/user.tree.json"
python3 - "$verify_dir/admin.roots.json" "$verify_dir/user.roots.json" "$verify_dir/user.tree.json" <<'PY'
import json, pathlib, sys
documents = [json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:]]
for document in documents:
    raw = json.dumps(document)
    assert "tikv://" not in raw and "/var/lib/juicefs-portal/namespace-mount" not in raw
    assert document.get("sample", {}).get("freshness") == "fresh"
assert [r["id"] for r in documents[0]["data"]["roots"]] == ["juicefs-prod-root"]
assert [r["id"] for r in documents[1]["data"]["roots"]] == ["juicefs-prod-root"]
assert documents[2]["data"]["root"]["id"] == "juicefs-prod-root"
assert documents[2]["data"]["maxDepth"] == 3
PY
user_admin_status=$(curl -sS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/user.cookies" -o /dev/null -w '%{http_code}' https://10.20.1.152:8443/api/v1/admin/overview)
anonymous_status=$(curl -sS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -o /dev/null -w '%{http_code}' https://10.20.1.152:8443/api/v1/usage/roots)
write_status=$(curl -sS --max-time 8 --cacert /etc/juicefs-portal/tls.crt -b "$verify_dir/admin.cookies" -X POST -o /dev/null -w '%{http_code}' https://10.20.1.152:8443/api/v1/usage/roots)
[[ "$user_admin_status" == 403 && "$anonymous_status" == 401 && "$write_status" == 405 ]]

cmp -s "$BACKUP/pd.pid" <(pgrep -xo pd-server)
cmp -s "$BACKUP/tikv.pid" <(pgrep -xo tikv-server)
cmp -s "$BACKUP/jfs-tikv.findmnt" <(findmnt -rn /mnt/jfs-tikv)
cmp -s "$BACKUP/dbwal.findmnt" <(findmnt -rn /mnt/dbwal)
rm -f -- "$verify_dir/admin.headers" "$verify_dir/admin.cookies" "$verify_dir/admin.login.json" "$verify_dir/admin.roots.json" "$verify_dir/user.headers" "$verify_dir/user.cookies" "$verify_dir/user.login.json" "$verify_dir/user.roots.json" "$verify_dir/user.tree.json"
rmdir -- "$verify_dir"
printf 'T09_READONLY_VERIFY_PASS root=juicefs-prod-root freshness=fresh user_admin=403 anonymous=401 write=405 services_not_enabled=true\n'
