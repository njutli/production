#!/usr/bin/env bash
# Thin compatibility entry point; implementation lives in the reviewed orchestrator.
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ACTION=${1:-}; RUN_ID=${2:-}; ARM=${3:-}; INSTANCE=${4:-}
if [[ $ACTION == plan ]]; then
  printf 'PLAN_ONLY\nrun_id=%s\narm=%s\ninstance=%s\nactions=render,start-pd,start-tikv,verify,stop-tikv,stop-pd\n' \
    "$RUN_ID" "$ARM" "$INSTANCE"
  exit 0
fi
exec "$DIR/s04a1-cluster-orchestrator.sh" "$@"
