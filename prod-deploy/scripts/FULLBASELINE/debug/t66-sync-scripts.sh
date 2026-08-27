#!/usr/bin/env bash
# Plan or synchronize the reviewed t66 bundle to node-local /tmp scopes.
# It performs no service/storage/test action; resync uses sudo only for a
# read-only loop-identity quiescence check before swapping script directories.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t66-common.sh"

ACTION=${1:-plan}; RUN_ID=${2:-}; EXPECTED_OLD_REMOTE_SHA=${3:-}
t66_check_run_id "$RUN_ID"; case "$ACTION" in plan|sync|resync-plan|resync) ;; *) t66_die 'action must be plan, sync, resync-plan, or resync';; esac
t66_require_tools sha256sum
REMOTE_DIR="/tmp/jfs-t66-${RUN_ID}-scripts"; t66_assert_abs_scoped_path "$REMOTE_DIR" "$RUN_ID"
mapfile -t FILES < <(find "$SCRIPT_DIR" -maxdepth 1 -type f \( -name 't66-*.sh' -o -name 't66-analyze.py' \) -printf '%f\n' | sort)
(( ${#FILES[@]} >= 20 )) || t66_die "incomplete t66 bundle: ${#FILES[@]} files"
MANIFEST=$(for f in "${FILES[@]}"; do sha256sum "$SCRIPT_DIR/$f"; done)
MANIFEST_SHA=$(printf '%s\n' "$MANIFEST" | sha256sum | awk '{print $1}')
REMOTE_MANIFEST=$(printf '%s\n' "$MANIFEST" | sed 's#  .*/#  #')
REMOTE_MANIFEST_SHA=$(printf '%s\n' "$REMOTE_MANIFEST" | sha256sum | awk '{print $1}')

if [[ "$ACTION" == plan ]]; then
  printf 'MODE=SYNC_PLAN_ONLY\nrun_id=%s\nremote_dir=%s\nmanifest_sha256=%s\nfiles=%s\n' "$RUN_ID" "$REMOTE_DIR" "$MANIFEST_SHA" "${#FILES[@]}"
  printf '%s\n' "$MANIFEST"
  printf 'remote writes: mkdir -p %q; scp only the listed files; write manifest.sha256; no sudo\n' "$REMOTE_DIR"
  exit 0
fi

t66_make_ssh_array; t66_require_tools sshpass ssh scp
remote_old_manifest_sha() {
  local node=$1
  "${T66_SSH[@]}" "$node" "set -e; test -d '$REMOTE_DIR'; test -f '$REMOTE_DIR/manifest.sha256'; cd '$REMOTE_DIR'; sha256sum -c manifest.sha256 >/dev/null; sha256sum manifest.sha256" | awk '{print $1}'
}

assert_remote_quiescent() {
  local node=$1
  "${T66_SSH[@]}" "$node" bash -s -- "$RUN_ID" <<'REMOTE'
set -euo pipefail
run=$1; mroot="/mnt/jfs-t66-${run}"; backing="/mnt/jfs-tikv/jfs-t66-${run}-backing/"
! findmnt -rn -o TARGET | awk -v p="$mroot" '$1==p||index($1,p"/")==1{found=1} END{exit !found}'
! sudo losetup -l -n -O BACK-FILE | awk -v p="$backing" 'index($1,p)==1{found=1} END{exit !found}'
! ps -eo args= | grep -F -- "jfs-t66-${run}" | grep -v -F -- 'grep -F' | grep -q .
REMOTE
}

if [[ "$ACTION" == resync-plan || "$ACTION" == resync ]]; then
  old_sha=''
  for node in "${T66_NODES[@]}"; do
    assert_remote_quiescent "$node"
    node_old_sha=$(remote_old_manifest_sha "$node")
    [[ "$node_old_sha" =~ ^[0-9a-f]{64}$ ]] || t66_die "invalid old remote manifest SHA: $node"
    [[ -z "$old_sha" || "$old_sha" == "$node_old_sha" ]] || t66_die 'old remote manifests differ across nodes'
    old_sha=$node_old_sha
    printf 'RESYNC_PREFLIGHT_PASS node=%s old_remote_manifest_sha256=%s\n' "$node" "$node_old_sha"
  done
  stage="/tmp/jfs-t66-${RUN_ID}-scripts-stage-${REMOTE_MANIFEST_SHA:0:16}"
  backup="/tmp/jfs-t66-${RUN_ID}-scripts-prev-${old_sha:0:16}"
  t66_assert_abs_scoped_path "$stage" "$RUN_ID"; t66_assert_abs_scoped_path "$backup" "$RUN_ID"
  expected="03-22c-resync-${RUN_ID}-${old_sha}-${REMOTE_MANIFEST_SHA}"
  printf 'RESYNC_CONTRACT run_id=%s old_remote_manifest_sha256=%s new_remote_manifest_sha256=%s stage=%s backup=%s\n' \
    "$RUN_ID" "$old_sha" "$REMOTE_MANIFEST_SHA" "$stage" "$backup"
  printf 'AUTH_REQUIRED=T66_RESYNC_AUTH=%s\n' "$expected"
  [[ "$ACTION" == resync-plan ]] && exit 0
  [[ "$EXPECTED_OLD_REMOTE_SHA" == "$old_sha" ]] || t66_die 'resync old-manifest argument mismatch'
  t66_check_auth "${T66_RESYNC_AUTH:-}" "$expected"
  t66_record_authorization "$RUN_ID" script-resync "$expected"
  for node in "${T66_NODES[@]}"; do
    assert_remote_quiescent "$node"
    [[ $(remote_old_manifest_sha "$node") == "$old_sha" ]] || t66_die "old remote manifest changed: $node"
    "${T66_SSH[@]}" "$node" "set -e; test ! -e '$stage'; test ! -e '$backup'; mkdir -m 0700 '$stage'"
    args=(); for f in "${FILES[@]}"; do args+=("$SCRIPT_DIR/$f"); done
    "${T66_SCP[@]}" "${args[@]}" "$node:$stage/"
    printf '%s\n' "$REMOTE_MANIFEST" | "${T66_SSH[@]}" "$node" "set -e; sed 's#  .*/#  #' > '$stage/manifest.sha256'; cd '$stage'; sha256sum -c manifest.sha256 >/dev/null; test \"\$(sha256sum manifest.sha256 | awk '{print \$1}')\" = '$REMOTE_MANIFEST_SHA'"
    "${T66_SSH[@]}" "$node" "set -e; mv '$REMOTE_DIR' '$backup'; mv '$stage' '$REMOTE_DIR'; cd '$REMOTE_DIR'; sha256sum -c manifest.sha256 >/dev/null; test \"\$(sha256sum manifest.sha256 | awk '{print \$1}')\" = '$REMOTE_MANIFEST_SHA'"
    printf 'RESYNC_NODE_PASS node=%s old=%s new=%s backup=%s\n' "$node" "$old_sha" "$REMOTE_MANIFEST_SHA" "$backup"
  done
  printf 'RESYNC_PASS run_id=%s old=%s new=%s\n' "$RUN_ID" "$old_sha" "$REMOTE_MANIFEST_SHA"
  exit 0
fi

EXPECTED="03-22c-sync-${RUN_ID}-${MANIFEST_SHA}"
t66_check_auth "${T66_SYNC_AUTH:-}" "$EXPECTED"
t66_record_authorization "$RUN_ID" script-sync "$EXPECTED"
for node in "${T66_NODES[@]}"; do
  "${T66_SSH[@]}" "$node" "set -e; if test ! -e '$REMOTE_DIR'; then mkdir -m 0700 '$REMOTE_DIR'; else test -d '$REMOTE_DIR' && test ! -e '$REMOTE_DIR/manifest.sha256'; fi"
  args=(); for f in "${FILES[@]}"; do args+=("$SCRIPT_DIR/$f"); done
  "${T66_SCP[@]}" "${args[@]}" "$node:$REMOTE_DIR/"
  printf '%s\n' "$MANIFEST" | "${T66_SSH[@]}" "$node" "sed 's#  .*/#  #' > '$REMOTE_DIR/manifest.sha256'; cd '$REMOTE_DIR'; sha256sum -c manifest.sha256 >/dev/null"
  printf 'SYNC_NODE_PASS node=%s manifest_sha256=%s\n' "$node" "$MANIFEST_SHA"
done
printf 'SYNC_PASS run_id=%s manifest_sha256=%s\n' "$RUN_ID" "$MANIFEST_SHA"
