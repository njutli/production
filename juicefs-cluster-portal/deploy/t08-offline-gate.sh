#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}

mapfile -d '' go_sources < <(find "$ROOT/api" -name '*.go' -type f -print0 | sort -z)
[[ -z $(gofmt -d "${go_sources[@]}") ]] || { printf 'Go sources are not formatted\n' >&2; exit 1; }
(
  cd "$ROOT/api"
  go test -count=1 ./...
  go vet ./...
)
node --check "$ROOT/web/app.js"
python3 - "$ROOT/api/openapi-v1.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    contract = yaml.safe_load(handle)
methods = {"post", "put", "patch", "delete"}
observed = {
    (path, method)
    for path, operations in contract.get("paths", {}).items()
    for method in operations
    if method in methods
}
assert observed == {("/session", "post"), ("/session", "delete")}, observed
assert "cookieAuth" in contract["components"]["securitySchemes"]
assert not any("files" in path or "namespace" in path for path in contract["paths"])
PY

grep -Fq 'PORTAL_USERS_FILE=/etc/juicefs-portal/users.json' "$ROOT/deploy/templates/portal.env"
grep -Fq 'PORTAL_SECURE_COOKIES=true' "$ROOT/deploy/templates/portal.env"
grep -Fq 'PORTAL_TLS_ADDR=10.20.1.152:8443' "$ROOT/deploy/templates/portal.env"
grep -Fq 'IPAddressAllow=localhost' "$ROOT/deploy/systemd/juicefs-portal.service"
grep -Fq 'IPAddressAllow=10.20.1.152/32' "$ROOT/deploy/systemd/juicefs-portal.service"
grep -Fq 'IPAddressAllow=10.20.1.157/32' "$ROOT/deploy/systemd/juicefs-portal.service"
! grep -Fq 'IPAddressAllow=10.20.1.0/24' "$ROOT/deploy/systemd/juicefs-portal.service"
grep -Fq 'PORTAL_USER_INIT_PASS' "$ROOT/api/cmd/portal-userctl/main.go"
grep -Fq 'jfsportal_session' "$ROOT/api/internal/portal/auth.go"
grep -Fq 'SameSiteStrictMode' "$ROOT/api/internal/portal/auth.go"
grep -Fq 'Content-Security-Policy' "$ROOT/api/internal/portal/server.go"
! grep -Fq 'fixture-admin-token' "$ROOT/web/index.html"
for script in "$ROOT"/deploy/scripts/t08-*.sh; do
  bash -n "$script"
done

test_dir=$(mktemp -d /tmp/jfsportal-t08-userctl.XXXXXX)
cleanup() {
  [[ "$test_dir" == /tmp/jfsportal-t08-userctl.* ]] && rm -rf -- "$test_dir"
}
trap cleanup EXIT
(
  cd "$ROOT/api"
  go run ./cmd/portal-userctl init \
    --users-file "$test_dir/users.json" \
    --secret-file "$test_dir/session-secret" \
    --credentials-file "$test_dir/bootstrap-credentials.txt" >/dev/null
)
python3 - "$test_dir" <<'PY'
import json
import pathlib
import re
import stat
import sys

root = pathlib.Path(sys.argv[1])
users = json.loads((root / "users.json").read_text())
assert users["version"] == 1
assert {item["role"] for item in users["users"]} == {"ADMIN", "USER"}
assert all(item["passwordHash"].startswith("$argon2id$v=19$") for item in users["users"])
assert re.fullmatch(r"[0-9a-f]{64}\n", (root / "session-secret").read_text())
for path in root.iterdir():
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, path
PY
printf 'T08_OFFLINE_GATE_PASS\n'
