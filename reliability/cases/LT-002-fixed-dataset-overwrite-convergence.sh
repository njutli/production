#!/usr/bin/env bash
# LT-002: fixed logical dataset overwrite and automatic space-convergence test.
set -euo pipefail
LT_CASE_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
source "$(dirname -- "$LT_CASE_SCRIPT")/../lib/long_term.sh"
lt_case_main LT-002 "$@"
