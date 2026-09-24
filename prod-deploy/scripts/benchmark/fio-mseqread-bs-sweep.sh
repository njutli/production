#!/bin/bash
# Competitor mseqread BS sweep: 16 jobs, psync/QD1, 16 x 4 GiB files.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROFILE=mseqread ENTRY_SCRIPT="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
exec "${SCRIPT_DIR}/fio-bs-sweep-common.sh" "$@"
