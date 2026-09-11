#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export GOCACHE=${GOCACHE:-/tmp/juicefs-cluster-portal-go-cache}

scripts=("$ROOT"/deploy/scripts/*.sh "$ROOT"/tests/offline-gate.sh)
for script in "${scripts[@]}"; do
  bash -n "$script"
done

python3 - "$ROOT" <<'PY'
import configparser
import json
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
for path in [
    root / "deploy/prometheus/prometheus.yml",
    root / "deploy/grafana/provisioning/datasources/prometheus.yaml",
    root / "deploy/grafana/provisioning/dashboards/provider.yaml",
    root / "api/openapi-v1.yaml",
]:
    with path.open(encoding="utf-8") as handle:
        yaml.safe_load(handle)

parser = configparser.ConfigParser()
with (root / "deploy/grafana/grafana.ini").open(encoding="utf-8") as handle:
    parser.read_file(handle)
assert parser["server"]["http_addr"] == "127.0.0.1"
assert parser["auth.anonymous"].getboolean("enabled") is False

for path in (root / "fixtures").glob("*.json"):
    with path.open(encoding="utf-8") as handle:
        json.load(handle)
PY

for unit in \
  "$ROOT/deploy/systemd/juicefs-portal.service" \
  "$ROOT/deploy/systemd/juicefs-prometheus.service" \
  "$ROOT/deploy/systemd/juicefs-grafana.service"; do
  grep -Fq 'User=jfsportal' "$unit"
  grep -Fq 'NoNewPrivileges=true' "$unit"
  grep -Fq 'ProtectSystem=strict' "$unit"
  grep -Fq 'IOWeight=10' "$unit"
  grep -Fq 'IPAddressDeny=any' "$unit"
  grep -Fq 'IPAddressAllow=localhost' "$unit"
done

grep -Fq '127.0.0.1:9090' "$ROOT/deploy/prometheus/prometheus.yml"
grep -Fq 'PORTAL_MODE=live' "$ROOT/deploy/templates/portal.env"
if grep -R -Eq '/mnt/(jfs-tikv|dbwal)|/dev/nvme[123]' \
  "$ROOT/deploy/systemd/juicefs-portal.service" \
  "$ROOT/deploy/systemd/juicefs-prometheus.service" \
  "$ROOT/deploy/systemd/juicefs-grafana.service" \
  "$ROOT/deploy/prometheus/prometheus.yml" \
  "$ROOT/deploy/grafana" "$ROOT/deploy/templates"; then
  printf 'forbidden data path in runtime configuration\n' >&2
  exit 1
fi

"$ROOT/tests/offline-gate.sh"
stage=$(mktemp -d /tmp/jfsportal-t04-gate.XXXXXX)
"$ROOT/deploy/scripts/t04-build-portal.sh" "$stage/payload"
(
  cd "$stage/payload"
  sha256sum -c portal-manifest.sha256
)
[[ $stage == /tmp/jfsportal-t04-gate.* ]] || exit 1
rm -rf -- "$stage"

printf 'T04_OFFLINE_GATE_PASS\n'
