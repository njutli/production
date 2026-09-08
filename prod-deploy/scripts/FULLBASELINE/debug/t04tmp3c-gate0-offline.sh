#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXECUTOR="$SELF_DIR/t04tmp3c-executor.sh"
ANALYZER="$SELF_DIR/t04tmp3c-analyze.py"

fail() { printf 'T04TMP3C_GATE0_FAIL\t%s\n' "$*" >&2; exit 42; }
for file in "$EXECUTOR" "$ANALYZER" "$0"; do [[ -s "$file" && ! -L "$file" ]] || fail missing_input; done
bash -n "$EXECUTOR"; bash -n "$0"; python3 -m py_compile "$ANALYZER"
"$EXECUTOR" --self-test; python3 "$ANALYZER" self-test

forbidden='sudo|drop_caches|noscrub|nodeep-scrub|kill -9|pkill|killall|reboot|shutdown|systemctl|service |ceph[[:space:]]+(tell|config|osd[[:space:]]+(set|unset|primary-affinity|pool[[:space:]]+(create|delete)))|rm[[:space:]]+-rf|umount[[:space:]]+-(f|l)|fusermount[[:space:]]+-u[zl]|compact'
if grep -nEi "$forbidden" "$EXECUTOR" "$ANALYZER"; then fail forbidden_command; fi

for row in \
  'C01\tb256\t256K\t8M' 'C02\tb4\t4M\t8M' 'C03\tb4\t4M\t32M' \
  'C04\tb4\t4M\t32M' 'C05\tb4\t4M\t8M' 'C06\tb256\t256K\t8M'; do
  grep -Fq "$row" "$EXECUTOR" || fail matrix_contract
done
for marker in \
  'ms_async_op_threads = 8' 'current-pre' 'verify_current_unchanged' \
  'unique worker missing' 'ro_probe_not_EROFS' 'client-sidecar.tsv' \
  'juicefs-metrics.tsv' 'health_gate "$cell-pre"' 'health_gate "$cell-post"' \
  'cleanup_uuid_drift' 'cleanup_current_uuid' 'destroy_status_still_exists'; do
  grep -Fq "$marker" "$EXECUTOR" || fail "executor_marker_$marker"
done
for marker in \
  'completion - runtime_ms * 1_000_000' 'formal_seconds(rows)' \
  'juicefs_object_request_data_bytes' \
  'juicefs_object_request_durations_histogram_seconds_count' \
  'juicefs_object_request_durations_histogram_seconds_sum' \
  'avg_get_size_bytes' 'avg_get_latency_ms' 'inflight_little'; do
  grep -Fq "$marker" "$ANALYZER" || fail "analyzer_marker_$marker"
done

set +e
"$EXECUTOR" create-layout 20260904-000000 WRONG_ACK >/dev/null 2>&1
bad_ack_rc=$?
set -e
[[ "$bad_ack_rc" == 42 ]] || fail bad_ack_fixture

sha256sum "$EXECUTOR" "$ANALYZER" "$0"
printf 'T04TMP3C_GATE0_PASS\tremote_calls=0\tprivileged_calls=0\n'
