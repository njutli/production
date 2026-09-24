#!/bin/bash
# Competitor seqread BS sweep: 1 job, psync/QD1, one 32 GiB file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROFILE=seqread ENTRY_SCRIPT="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
exec "${SCRIPT_DIR}/fio-bs-sweep-common.sh" "$@"
