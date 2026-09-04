#!/usr/bin/env bash
# 04-tmp3b Gate 0: local-only.  It never invokes an environment client.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXEC="$DIR/t04tmp3b-executor.sh"
ANALYZER="$DIR/t04tmp3b-analyze.py"
SCRUB="$DIR/u141d-scrub-control.sh"
OUT=${T04TMP3B_GATE0_OUT:-/mnt/c/SunRise/test/04-tmp3b/gate0-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; FAIL=0
pass(){ printf '[PASS]\t%s\n' "$*"; }
fail(){ printf '[FAIL]\t%s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

for f in "$EXEC" "$ANALYZER" "$SCRUB" "$0"; do check "present $(basename "$f")" test -s "$f"; done
check executor-bash-n bash -n "$EXEC"
check executor-bash-u-n bash -u -n "$EXEC"
check gate-bash-n bash -n "$0"
check analyzer-compile python3 -m py_compile "$ANALYZER"
check analyzer-self-test python3 "$ANALYZER" self-test
check executor-self-test "$EXEC" --self-test
check scrub-self-test "$SCRUB" --self-test

# D01/D02/D03: real completion, overlap weighting, and summary as旁证 only.
check analyzer-timing-contract grep -Fq 'completion - run_ms' "$ANALYZER"
check analyzer-overlap-contract grep -Fq 'overlap = min(end, s + 1)' "$ANALYZER"
check analyzer-four-windows grep -Fq 'windows_MiBs' "$ANALYZER"
check analyzer-percentiles grep -Fq 'formal_p10_MiBs' "$ANALYZER"
check analyzer-no-line-number-bucketing bash -c "! grep -nE 'enumerate.*sec|sec.*enumerate' '$ANALYZER'"

# D25/D26/D27/D31: source must not gain secrets, broad deletion, forced
# remount, cluster mutation, or an unguarded current-volume operation.
if grep -nEi 'sshpass|PASSWORD=|sudo[[:space:]]|pool[[:space:]]+(delete|create)|--force|pkill|killall|fuser[[:space:]]+-k|fusermount[[:space:]]+-u[[:space:]]*[zf]|umount[[:space:]]+-(l|f)|drop_caches' "$EXEC" >"$OUT/executor-forbidden.txt"; then fail executor-forbidden-scan; else pass executor-forbidden-scan; fi
check readonly-flag grep -Fq -- '--read-only' "$EXEC"
check no-old-ro-flag bash -c "! grep -Fq -- '-o ro' '$EXEC'"
check current-volume-fixed grep -Fq 'juicefs-prod' "$EXEC"
check fixed-binary-md5 grep -Fq '24fae0852051c80ca571cb2f20275d46' "$EXEC"
check exact-evidence-root grep -Fq '/mnt/c/SunRise/test/04-tmp3b' "$EXEC"
check exact-remote-root grep -Fq 'opencode-04tmp3b-' "$EXEC"

# Phase III/IV read path is now source-implemented; write/GC/destroy remain
# explicit refusal paths and no command is executed by this offline gate.
check step2-plan-entry grep -Fq 'step2_plan' "$EXEC"
check step2-create-entry grep -Fq 'step2_create_canary' "$EXEC"
check step2-read-entry grep -Fq 'step2_read_phase' "$EXEC"
check step2-format-guard grep -Fq 'format_settings_guard' "$EXEC"
check step2-format-no-force bash -c "! grep -nE -- '--force|format[^#]*--force' '$EXEC'"
check step2-format-no-update grep -Fq -- 'format --no-update' "$EXEC"
check step2-format-no-unsupported-flags bash -c "! grep -E 'local -a cmd=.*(--dir-stats|--min-client-version)' '$EXEC'"
check step2-no-rsa-misclassification bash -c "! grep -Fq 'encrypt-rsa-key' '$EXEC'"
check step2-runtime-freeze grep -Fq 'step2-runtime-scripts.sha256' "$EXEC"
check step2-plan-freeze grep -Fq 'step2-plan-contract.sha256' "$EXEC"
check step2-temp-identity grep -Fq 'temp_status' "$EXEC"
check step2-data-prefix-identity grep -Fq 'temp_data_prefix_identity' "$EXEC"
check step2-fixed-content grep -Fq -- '--buffer_pattern=0x5a' "$EXEC"
check step2-read-abba bash -c "grep -Fq 'for arm in b256 b4 b4 b256' '$EXEC'"
check step2-write-entry grep -Fq 'step2_write' "$EXEC"
check step2-write-dispatch grep -Fq 'step2_write "$3"' "$EXEC"
check step2-write-not-old-refusal bash -c "! grep -Fq 'step2_pending \"\$3\" STEP2_WRITE' '$EXEC'"
check step2-write-order bash -c "grep -Fq 'for arm in b256 b4 b4 b256' '$EXEC' && grep -Fq 'S2W%02d' '$EXEC'"
check step2-write-fiocontract grep -Fq -- '--bs=16M' "$EXEC"
check step2-write-runtime grep -Fq -- '--runtime=120' "$EXEC"
check step2-write-async-off grep -Fq 'SELECTED_ASYNC=off' "$EXEC"
check step2-write-close-analysis grep -Fq 'close_complete_MiBs' "$ANALYZER"
check step2-write-drain-timeout grep -Fq 'write_drain_timeout' "$EXEC"
check step2-write-drain-stability grep -Fq 'stable >= 3' "$EXEC"
check step2-write-drain-output grep -Fq 'python3 - "$prom" >"$out/drain-current.tsv"' "$EXEC"
check step2-write-plan-safe-reuse grep -Fq 'write_plan_existing_drift' "$EXEC"
check step2-write-exact-delete grep -Fq 'unlink -- "$file"' "$EXEC"
check step2-write-gc-temp-meta grep -Fq 'gc --delete --threads 32 "$meta"' "$EXEC"
check step2-write-gc-skipped-time grep -Fq 'JFS_GC_SKIPPEDTIME=0' "$EXEC"
check step2-write-first-failure-stop grep -Fq 'write_cell "$arm" "$cell"' "$EXEC"
check step2-write-plan-only-scrub grep -Fq 'external-lease-required' "$EXEC"
check step2-write-scrub-plan-set grep -Fq 'ceph osd set noscrub' "$EXEC"
check step2-write-scrub-plan-deep-set grep -Fq 'ceph osd set nodeep-scrub' "$EXEC"
check step2-write-scrub-plan-deep-unset grep -Fq 'ceph osd unset nodeep-scrub' "$EXEC"
check step2-write-scrub-plan-unset grep -Fq 'ceph osd unset noscrub' "$EXEC"
check step2-write-plan-only-destroy grep -Fq 'external-independent-authorization' "$EXEC"
check step2-write-gc-plan grep -Fq 'gc_cmd' "$EXEC"
check step2-write-unlink-plan grep -Fq 'unlink_cmd' "$EXEC"
check step2-write-destroy-plan grep -Fq 'destroy_cmd' "$EXEC"
check step2-write-tolerance grep -Fq 'step2-write-pool-tolerance.tsv' "$EXEC"
check step2-write-remount-hash grep -Fq 'write_remount_hash' "$EXEC"
check step2-write-unlink-exact grep -Fq 'unlink -- %q' "$EXEC"
check step2-write-gc-private-conf grep -Fq 'env JFS_GC_SKIPPEDTIME=0 CEPH_CONF=%q %s gc --delete --threads 32' "$EXEC"
check step2-write-destroy-private-conf grep -Fq 'env CEPH_CONF=%q %s destroy' "$EXEC"
check step2-write-bwlog-before-fio grep -Fq 'mkdir -m 0700 -p "$out" "$out/bwlog"' "$EXEC"
check step2-write-registered-start grep -Fq 'fio-registered-start-ns.txt' "$EXEC"
check step2-write-scrub-lease grep -Fq 'step2write-retry2-phase-a' "$EXEC"
check step2-write-previous-initialized grep -Fq 'previous= stable=0' "$EXEC"
check step2-write-resume-entry grep -Fq 'step2-write-resume-s2w01)' "$EXEC"
check step2-write-resume-exact-ack grep -Fq 'I_ACK_04TMP3B_STEP2_WRITE_RESUME_S2W01_' "$EXEC"
check step2-write-resume-exact-cell grep -Fq 'cell=S2W01 arm=b256' "$EXEC"
check step2-write-resume-requires-fio-evidence grep -Fq 'write_resume_fio_evidence' "$EXEC"
check step2-write-resume-no-rerun grep -Fq 'S2W01_RECOVERY_PASS' "$EXEC"
check graceful-umount-metrics-port-wait grep -Fq '_port_gone=0' "$EXEC"
check step2-write-resume-unmounted-stage grep -Fq 'write_resume_unmounted_stage_invalid' "$EXEC"
check step2-write-scrub-pause grep -Fq 'scrub_run pause "$ACTIVE_LEASE"' "$EXEC"
check step2-write-scrub-verify grep -Fq 'scrub_run verify-paused "$ACTIVE_LEASE"' "$EXEC"
check step2-write-scrub-restore grep -Fq 'scrub_run restore "$ACTIVE_LEASE"' "$EXEC"
check step2-write-scrub-restore-verify grep -Fq 'scrub_run verify-restored "$ACTIVE_LEASE"' "$EXEC"
check step2-write-new-ack grep -Fq 'STEP2_WRITE_EXECUTE' "$EXEC"
check step2-write-phase-preflight grep -Fq 'step2_write_preflight' "$EXEC"
check step2-write-preflight-contract grep -Fq 'step2-plan-contract.sha256' "$EXEC"
check step2-write-preflight-current grep -Fq 'verify_current_fingerprint' "$EXEC"
check step2-write-preflight-temp-status grep -Fq 'temp_status "$arm"' "$EXEC"
check step2-write-preflight-assets grep -Fq 'write_temp_assets_differ' "$EXEC"
check step2-write-preflight-no-residual grep -Fq 'residual_step2_mount' "$EXEC"
check step2-write-runtime-freeze grep -Fq 'step2-write-runtime-scripts.sha256' "$EXEC"
check step2-write-no-old-preflight bash -c "! sed -n '/^step2_write()/,/^cleanup_plan_step2()/p' '$EXEC' | grep -Fq 'step2_preflight'"
check step2-write-no-replan bash -c "! sed -n '/^step2_write()/,/^cleanup_plan_step2()/p' '$EXEC' | grep -Fq 'step2_plan'"
check step2-write-no-anchor-overwrite bash -c "! sed -n '/^step2_write()/,/^cleanup_plan_step2()/p' '$EXEC' | grep -Fq 'step2-pool-pre'"
check step2-cleanup-refusal grep -Fq 'STEP2_CLEANUP_NOT_IMPLEMENTED_NO_GC_DESTROY' "$EXEC"
check step2-pair-analyzer grep -Fq 'step2-pair' "$ANALYZER"
check step2-write-pair-analyzer grep -Fq 'step2-write-pair' "$ANALYZER"
check step2-clat-contract grep -Fq 'clat_p99_us' "$ANALYZER"
check step1-matrix-ra bash -c "grep -Fq 'ra8 ra16 ra32 ra32 ra16 ra8' '$EXEC'"
check step1-matrix-async bash -c "grep -Fq 'async-off async-on async-on async-off' '$EXEC'"
check fio-contract grep -Fq -- '--ioengine=psync' "$EXEC"
check fio-iodepth grep -Fq -- '--iodepth=1' "$EXEC"
check fio-20m grep -Fq -- '--bs=20M' "$EXEC"
check fio-read-only-file grep -Fq -- '--allow_file_create=0' "$EXEC"
check fio-uses-cell-mount bash -c "grep -Fq -- '--filename=\"\$file\"' '$EXEC' && ! grep -Fq -- '--filename=\"\$ASSET\"' '$EXEC'"
check erofs-probe grep -Fq 'EROFS' "$EXEC"
check erofs-probe-captures-command-stderr grep -Fq 'touch -- "$probe" 2>"$out/ro-probe.err"' "$EXEC"
check mount-process-scoped-by-log grep -Fq 'if log not in cmd: continue' "$EXEC"
check current-asset-exact-size grep -Fq 'seqread_asset_not_32GiB' "$EXEC"
check current-mount-exact-identity grep -Fq 'current_mount_identity_mismatch' "$EXEC"
check private-msgr8-contract grep -Fq 'ms_async_op_threads = 8' "$EXEC"
check current-fingerprint-postcheck grep -Fq 'verify_current_fingerprint' "$EXEC"
check runtime-sha-frozen grep -Fq 'runtime_script_drift' "$EXEC"
check foreign-fio-gate grep -Fq 'foreign_fio_exists' "$EXEC"
check residual-mount-gate grep -Fq 'residual_tmp3b_mount' "$EXEC"
check exact-nic-sidecar grep -Fq 'client-sidecar.tsv' "$EXEC"
check ceph-data-nic-route grep -Fq 'ip route get "$CEPH_ROUTE_TARGET"' "$EXEC"
check no-tikv-nic-route bash -c "! grep -Fq 'route-to-tikv.txt' '$EXEC'"
check juicefs-metric-sidecar grep -Fq 'juicefs-metrics.tsv' "$EXEC"
check juicefs14-object-label-filter grep -Fq 'juicefs_object_request_(durations_histogram_seconds_(sum|count)|data_bytes|errors|uploading)' "$EXEC"
check mechanism-metric-hard-gate grep -Fq 'mechanism metric formal-window coverage failed' "$EXEC"
check formal-sidecar-coverage grep -Fq 'sidecar-coverage.json' "$EXEC"
check remote-tar-bundle grep -Fq 'evidence.tar' "$EXEC"
check failure-preserves-scene grep -Fq 'preserves the scene' "$EXEC"
check scrub-delegated grep -Fq 'u141d-scrub-control.sh' "$EXEC"
check no-secret-output grep -Fq 'secret values are redacted' "$EXEC"

# Relevant defect-class markers must remain bound to the new implementation.
for id in D01 D02 D03 D04 D05 D06 D12 D16 D17 D18 D19 D21 D22 D23 D25 D26 D27 D28 D29 D30 D31; do
  check "defect-marker-$id" grep -R -Fq "DEFECT-$id" "$EXEC" "$ANALYZER" "$SCRUB"
done

# Existing 04-tmp3 history is optional in a clean checkout, but when present
# it is a zero-environment analyzer regression input.
HISTORY=/mnt/c/SunRise/test/04-tmp3/20260904-095827/opencode-04tmp3-20260904-095827
if [[ -d "$HISTORY" ]]; then
  if python3 "$ANALYZER" history-verify "$HISTORY" >"$OUT/history-verify.json" 2>"$OUT/history-verify.err"; then pass history-regression; else fail history-regression; fi
else
  pass history-regression-not-installed
fi

sha256sum "$EXEC" "$ANALYZER" "$SCRUB" "$0" >"$OUT/input-sha256.tsv"
printf 'failures\t%s\n' "$FAIL" >"$OUT/summary.tsv"
if (( FAIL )); then printf 'T04TMP3B_GATE0_FAIL\t%s\n' "$OUT"; exit 1; fi
printf 'T04TMP3B_GATE0_PASS\tout=%s\n' "$OUT"
