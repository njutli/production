#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${1:?usage: t05-prepare-staging.sh OUT PROM_TGZ PROM_SHA256 GRAFANA_TGZ GRAFANA_SHA256}
PROM_TGZ=${2:?missing Prometheus archive}
PROM_SHA=${3:?missing Prometheus SHA256}
GRAFANA_TGZ=${4:?missing Grafana archive}
GRAFANA_SHA=${5:?missing Grafana SHA256}

[[ "$OUT" == /* && ! -e "$OUT" ]] || { printf 'output must be a new absolute path\n' >&2; exit 2; }
[[ "$PROM_SHA" =~ ^[0-9a-f]{64}$ && "$GRAFANA_SHA" =~ ^[0-9a-f]{64}$ ]] || { printf 'invalid SHA256\n' >&2; exit 2; }
printf '%s  %s\n' "$PROM_SHA" "$PROM_TGZ" | sha256sum -c -
printf '%s  %s\n' "$GRAFANA_SHA" "$GRAFANA_TGZ" | sha256sum -c -

for archive in "$PROM_TGZ" "$GRAFANA_TGZ"; do
  if tar -tzf "$archive" | awk -F/ '$1=="" {bad=1} {for(i=1;i<=NF;i++) if($i=="..") bad=1} END {exit !bad}'; then
    printf 'unsafe archive member: %s\n' "$archive" >&2
    exit 1
  fi
done

work=$(mktemp -d /tmp/jfsportal-t05-stage.XXXXXX)
cleanup() {
  [[ "$work" == /tmp/jfsportal-t05-stage.* ]] && rm -rf -- "$work"
}
trap cleanup EXIT

"$ROOT/deploy/scripts/t04-build-portal.sh" "$OUT/payload"
install -d -m 0755 "$OUT/config" "$OUT/systemd" "$OUT/scripts" "$work/prom" "$work/grafana"
tar -xzf "$PROM_TGZ" --no-same-owner --no-same-permissions -C "$work/prom"
tar -xzf "$GRAFANA_TGZ" --no-same-owner --no-same-permissions -C "$work/grafana"

prom_bin=$(find "$work/prom" -type f -name prometheus -perm -u+x -print -quit)
promtool_bin=$(find "$work/prom" -type f -name promtool -perm -u+x -print -quit)
grafana_bin=$(find "$work/grafana" -path '*/bin/grafana' -type f -perm -u+x -print -quit)
[[ -n "$prom_bin" && -n "$promtool_bin" && -n "$grafana_bin" ]] || { printf 'expected release binaries not found\n' >&2; exit 1; }

install -m 0755 "$prom_bin" "$OUT/payload/bin/prometheus"
install -m 0755 "$promtool_bin" "$OUT/payload/bin/promtool"
grafana_home=$(dirname -- "$(dirname -- "$grafana_bin")")
install -d -m 0755 "$OUT/payload/grafana"
cp -a -- "$grafana_home/." "$OUT/payload/grafana/"

install -m 0644 "$ROOT/deploy/prometheus/prometheus.yml" "$OUT/config/prometheus.yml"
install -m 0644 "$ROOT/deploy/grafana/grafana.ini" "$OUT/config/grafana.ini"
install -m 0644 "$ROOT/deploy/grafana/provisioning/datasources/prometheus.yaml" "$OUT/config/prometheus-datasource.yaml"
install -m 0644 "$ROOT/deploy/grafana/provisioning/dashboards/provider.yaml" "$OUT/config/dashboard-provider.yaml"
install -m 0644 "$ROOT"/deploy/systemd/*.service "$OUT/systemd/"
install -m 0755 "$ROOT"/deploy/scripts/t05-{node-preflight,install-base,activate-base,readonly-verify,deactivate-base}.sh "$OUT/scripts/"

(
  cd "$OUT"
  find payload config systemd scripts -type f -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
printf 'T05_STAGING_PASS output=%s\n' "$OUT"
