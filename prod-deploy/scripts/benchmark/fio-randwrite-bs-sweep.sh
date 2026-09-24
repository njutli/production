#!/bin/bash
# Competitor randwrite BS sweep: 128 jobs, libaio/QD128, 128 x 1 GiB files.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROFILE=randwrite ENTRY_SCRIPT="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
exec "${SCRIPT_DIR}/fio-bs-sweep-common.sh" "$@"
