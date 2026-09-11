#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROMTOOL=${PROMTOOL:-/tmp/jfsportal-t05-20260910-165333/payload/bin/promtool}
export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}

[[ -x "$PROMTOOL" ]] || { printf 'promtool unavailable: %s\n' "$PROMTOOL" >&2; exit 1; }
mapfile -d '' go_sources < <(find "$ROOT/api" -name '*.go' -type f -print0 | sort -z)
[[ -z $(gofmt -d "${go_sources[@]}") ]] || { printf 'Go sources are not formatted\n' >&2; exit 1; }

(
  cd "$ROOT/api"
  go test ./...
  go vet ./...
)
node --check "$ROOT/web/app.js"
"$PROMTOOL" check config "$ROOT/deploy/prometheus/prometheus-t06.yml"

grep -Fq 'PORTAL_PROMETHEUS_URL' "$ROOT/api/cmd/portal/main.go"
grep -Fq 'etcd_server_(has_leader|is_leader)' "$ROOT/deploy/prometheus/prometheus-t06.yml"
for view in overview topology storage clients tikv ceph usage alerts; do
  grep -Fq "data-view=\"$view\"" "$ROOT/web/index.html"
done
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
PY
for script in "$ROOT"/deploy/scripts/t07-*.sh; do
  bash -n "$script"
done
printf 'T07_OFFLINE_GATE_PASS\n'
