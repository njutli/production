#!/usr/bin/env bash
# Read-only online gate for the pinned JuiceFS binary features required by the seed protocol.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t64-common.sh"

RUN_ID=${1:-}
t64_check_run_id "$RUN_ID"
t64_require_tools "$T64_JUICEFS_BIN" md5sum grep sha256sum
OUT="/tmp/production/opencode-t3.22-${RUN_ID}/seed-interface-gate"
[[ ! -e "$OUT" ]] || t64_die "seed interface gate output already exists: $OUT"
[[ $(md5sum "$T64_JUICEFS_BIN" | awk '{print $1}') == "$T64_JUICEFS_MD5" ]] || t64_die 'JuiceFS binary MD5 mismatch'
mkdir -p "$OUT"

"$T64_JUICEFS_BIN" version > "$OUT/version.txt" 2>&1
for cmd in dump load clone gc; do
  "$T64_JUICEFS_BIN" "$cmd" --help > "$OUT/$cmd-help.txt" 2>&1
done
grep -Fq -- '--keep-secret-key' "$OUT/dump-help.txt" || t64_die 'pinned binary dump lacks --keep-secret-key'
grep -Fq -- 'META-URL' "$OUT/dump-help.txt" || t64_die 'pinned binary dump syntax is unexpected'
grep -Fq -- 'META-URL' "$OUT/load-help.txt" || t64_die 'pinned binary load syntax is unexpected'
grep -Fq -- 'SRC DST' "$OUT/clone-help.txt" || t64_die 'pinned binary clone syntax is unexpected'
grep -Fq -- '--delete' "$OUT/gc-help.txt" || t64_die 'pinned binary gc lacks --delete'
grep -Fq -- '--threads' "$OUT/gc-help.txt" || t64_die 'pinned binary gc lacks --threads'
sha256sum "$OUT"/*.txt > "$OUT/SHA256SUMS"
printf 'SEED_INTERFACE_GATE_PASS run_id=%s binary=%s md5=%s\n' "$RUN_ID" "$T64_JUICEFS_BIN" "$T64_JUICEFS_MD5"
