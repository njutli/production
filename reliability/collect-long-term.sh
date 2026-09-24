#!/usr/bin/env bash
# Persist one completed LT result from the 192.168.11.12 LT client.
# No remote evidence or test data is removed by this script.
set -euo pipefail
export LC_ALL=C

cd "$(dirname -- "$0")"
source env/cluster-192.168.11.env
[[ "$LT_CONFIG_PROFILE" == slow-validation-192 && "$LT_RESULT_MOUNT" == /data ]] || {
    echo 'unexpected LT collection profile or result mount' >&2; exit 42;
}
client=turboai@192.168.11.12
ssh_config=/home/lilingfeng/.ssh/config
[[ -r "$ssh_config" && ! -L "$ssh_config" ]] || { echo 'SSH config unavailable' >&2; exit 42; }
ssh_to_lt_client() { ssh -F "$ssh_config" -o ConnectTimeout=10 "$client" "$@"; }

case_id=${1:-}; run_id=${2:-}
[[ "$case_id" =~ ^LT-00[1-4]$ ]] || { echo 'usage: collect-long-term.sh LT-00[1-4] YYYYMMDD-HHMMSS' >&2; exit 42; }
[[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo 'invalid RUN_ID' >&2; exit 42; }

remote="${LT_RESULT_MOUNT}/reliability-lt-results/${run_id}/${case_id}"
local_root="/mnt/c/SunRise/test/reliability/${run_id}"
target="${local_root}/${case_id}"
[[ ! -e "$target" && ! -L "$target" ]] || { echo "refuse existing target: $target" >&2; exit 42; }
[[ $(realpath -m -- "$local_root") == "$local_root" ]] || { echo "non-canonical local root: $local_root" >&2; exit 42; }

ssh_to_lt_client "test -f '$remote/manifest.sha256' -a -f '$remote/controller.done' && { test -f '$remote/derived/verdict.json' || grep -q '[[:space:]]FAILED[[:space:]]' '$remote/run-state.tsv'; }" \
    || { echo 'remote result is incomplete' >&2; exit 42; }
mkdir -m 0700 -p "$local_root"
tmp=$(mktemp -d "${local_root}/.${case_id}.incoming.XXXXXX")
cleanup_tmp() {
    [[ "$tmp" == "${local_root}/.${case_id}.incoming."* && -d "$tmp" && ! -L "$tmp" ]] || return 0
    rm -r -- "$tmp"
}
trap cleanup_tmp EXIT
ssh_to_lt_client "tar -C '${LT_RESULT_MOUNT}/reliability-lt-results/${run_id}' -czf - '$case_id'" | tar -C "$tmp" -xzf -
[[ -d "$tmp/$case_id" && ! -L "$tmp/$case_id" ]] || { echo 'archive shape mismatch' >&2; exit 42; }
(cd "$tmp/$case_id" && sha256sum -c manifest.sha256)
mv -- "$tmp/$case_id" "$target"
trap - EXIT
rmdir -- "$tmp"
printf 'LT_PERSISTENCE_PASS\trun=%s\tcase=%s\ttarget=%s\n' "$run_id" "$case_id" "$target"
