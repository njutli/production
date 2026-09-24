#!/usr/bin/env bash
# Narrow, audited read-only Ceph query wrapper for LT sampling on clients where
# the admin keyring is root-readable only.  No arbitrary ceph subcommand passes.
set -euo pipefail
export LC_ALL=C

allowed=0
if [[ $# -eq 3 && $1 == -s && $2 == -f && $3 == json ]]; then
    allowed=1
elif [[ $# -eq 4 && $1 == df && $2 == detail && $3 == -f && $4 == json ]]; then
    allowed=1
elif [[ $# -eq 4 && $1 == osd && $2 == dump && $3 == -f && $4 == json ]]; then
    allowed=1
elif [[ $# -eq 4 && $1 == osd && $2 == df && $3 == -f && $4 == json ]]; then
    allowed=1
elif [[ $# -eq 4 && $1 == tell && $2 =~ ^osd\.[0-9]+$ && $3 == perf && $4 == dump ]]; then
    allowed=1
fi

(( allowed == 1 )) || { printf 'LT_CEPH_READONLY_REFUSE\t%q ' "$@" >&2; printf '\n' >&2; exit 42; }
exec sudo -n /usr/bin/ceph --conf /etc/ceph/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin "$@"
