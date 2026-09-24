#!/usr/bin/env bash
# LT-001: fixed-dataset sequential/random read stability (2h -> 24h -> 72h).
set -euo pipefail
LT_CASE_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
source "$(dirname -- "$LT_CASE_SCRIPT")/../lib/long_term.sh"
lt_case_main LT-001 "$@"
