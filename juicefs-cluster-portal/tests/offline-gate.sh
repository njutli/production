#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}

required=(
  "$ROOT/api/openapi-v1.yaml"
  "$ROOT/api/cmd/portal/main.go"
  "$ROOT/api/cmd/namespace-collector/main.go"
  "$ROOT/api/internal/portal/server.go"
  "$ROOT/api/internal/namespacecollector/collector.go"
  "$ROOT/api/schema/namespace-v1.sql"
  "$ROOT/web/index.html"
  "$ROOT/fixtures/overview.json"
  "$ROOT/configs/namespace-roots.example.json"
)
for path in "${required[@]}"; do
  [[ -f "$path" ]] || { printf 'missing: %s\n' "$path" >&2; exit 1; }
done

mapfile -d '' go_sources < <(find "$ROOT/api" -name '*.go' -type f -print0 | sort -z)
if [[ -n $(gofmt -d "${go_sources[@]}") ]]; then
  printf 'Go sources are not formatted\n' >&2
  exit 1
fi

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
allowed = {("/session", "post"), ("/session", "delete")}
assert observed == allowed, f"unexpected mutating API methods: {observed}"
required = {"/usage/roots", "/usage/tree"}
assert required <= set(contract.get("paths", {})), "T09 usage snapshot APIs missing"
for path in required:
    assert set(contract["paths"][path]) == {"get"}, f"{path} must remain GET-only"
PY

node --check "$ROOT/web/app.js"
python3 -m json.tool "$ROOT/configs/namespace-roots.example.json" >/dev/null

(
  cd "$ROOT/api"
  go test ./...
  go vet ./...
)

printf 'T03_OFFLINE_GATE_PASS\n'
