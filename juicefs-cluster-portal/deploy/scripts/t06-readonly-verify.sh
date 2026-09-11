#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) == ceph-node3 ]] || { printf 'wrong host\n' >&2; exit 1; }
systemctl is-active --quiet juicefs-prometheus.service
[[ $(systemctl is-enabled juicefs-prometheus.service 2>/dev/null || true) == disabled ]]
curl -fsS --max-time 5 http://127.0.0.1:9090/-/ready >/dev/null

targets=$(mktemp /tmp/jfsportal-t06-targets.XXXXXX)
cleanup() {
  [[ "$targets" == /tmp/jfsportal-t06-targets.* ]] && rm -f -- "$targets"
}
trap cleanup EXIT
curl -fsS --max-time 10 http://127.0.0.1:9090/api/v1/targets >"$targets"
python3 - "$targets" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("status") != "success":
    raise SystemExit("Prometheus targets API failed")
active = payload["data"]["activeTargets"]
health = {}
for target in active:
    labels = target.get("labels", {})
    key = (labels.get("job"), labels.get("instance"))
    health[key] = target.get("health")

required = {
    ("prometheus", "127.0.0.1:9090"),
    ("juicefs-client", "10.20.1.157:9633"),
    *(("pd", f"10.20.1.{node}:2379") for node in (150, 151, 152)),
    *(("tikv", f"10.20.1.{node}:20180") for node in (150, 151, 152)),
    *(("node", f"10.20.1.{node}:9100") for node in (150, 151, 152, 157)),
}
bad = sorted((key, health.get(key, "missing")) for key in required if health.get(key) != "up")
if bad:
    raise SystemExit(f"required target failure: {bad}")
ceph = [(key, value) for key, value in health.items() if key[0] == "ceph"]
if not ceph or not any(value == "up" for _, value in ceph):
    raise SystemExit(f"no healthy Ceph target: {ceph}")
print(f"TARGET_CONTRACT_PASS required={len(required)} ceph_up={sum(value == 'up' for _, value in ceph)}")
PY

query() {
  local promql=$1
  curl -fsS --max-time 10 --get --data-urlencode "query=$promql" http://127.0.0.1:9090/api/v1/query
}
for check in \
  'count(up{job="juicefs-client"} == 1)' \
  'count(up{job="pd"} == 1)' \
  'count(up{job="tikv"} == 1)' \
  'count(up{job="node"} == 1)' \
  'count(jfsportal_nvme_info)' \
  'count(ceph_health_status)'; do
  result=$(query "$check")
  python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="success" and d["data"]["result"]' <<<"$result"
done
pgrep -x pd-server >/dev/null
pgrep -x tikv-server >/dev/null
findmnt -rn /mnt/jfs-tikv >/dev/null
findmnt -rn /mnt/dbwal >/dev/null
printf 'T06_GLOBAL_VERIFY_PASS enabled=false\n'
