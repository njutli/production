#!/usr/bin/env bash
# Offline Gate 0 for LT-001..LT-004.  It does not connect to the cluster.
set -euo pipefail
export LC_ALL=C
cd "$(dirname -- "$0")"

files=(lib/long_term.sh lib/ceph-readonly-sudo.sh lib/lt-analyze.py lib/lt-slice-analyze.py env/cluster-192.168.11.env collect-long-term.sh calibrate-randrw-qd.sh cases/LT-001-long-read-stability.sh cases/LT-002-fixed-dataset-overwrite-convergence.sh cases/LT-003-burst-idle-recovery.sh cases/LT-004-controlled-compact-maintenance.sh)
for file in "${files[@]}"; do [[ -f "$file" && ! -L "$file" ]] || { echo "missing or symlink: $file" >&2; exit 42; }; done
for file in lib/long_term.sh lib/ceph-readonly-sudo.sh env/cluster-192.168.11.env collect-long-term.sh calibrate-randrw-qd.sh cases/LT-*.sh; do bash -n "$file"; done
python3 -c 'compile(open("lib/lt-analyze.py", encoding="utf-8").read(), "lib/lt-analyze.py", "exec")'
python3 -c 'compile(open("lib/lt-slice-analyze.py", encoding="utf-8").read(), "lib/lt-slice-analyze.py", "exec")'
python3 lib/lt-analyze.py --self-test
python3 lib/lt-slice-analyze.py --self-test

for file in lib/long_term.sh collect-long-term.sh calibrate-randrw-qd.sh cases/LT-*.sh; do
    forbidden='drop_caches|systemctl|reboot|shutdown|mkfs|wipefs|losetup|dmsetup|juicefs[[:space:]]+gc|ceph[[:space:]].*(compact|delete)|pkill|killall|fuser[[:space:]]+-k'
    [[ "$file" == lib/long_term.sh ]] || forbidden="sudo|$forbidden"
    if sed '/^[[:space:]]*#/d' "$file" | grep -nE "$forbidden"; then
        echo "forbidden operation found in $file" >&2
        exit 42
    fi
done
readonly_sudo_line='            proc_md5=$(sudo -n /usr/bin/md5sum -- "/proc/$pid/exe" 2>/dev/null | awk '\''{print $1}'\'' || true)'
[[ $(grep -Fxc "$readonly_sudo_line" lib/long_term.sh) -eq 1 ]] || { echo 'readonly proc fingerprint command changed' >&2; exit 42; }
[[ $(sed '/^[[:space:]]*#/d' lib/long_term.sh | grep -c 'sudo') -eq 1 ]] || { echo 'unexpected sudo in LT engine' >&2; exit 42; }
grep -Fxq 'exec sudo -n /usr/bin/ceph --conf /etc/ceph/ceph.conf --keyring /etc/ceph/ceph.client.admin.keyring -n client.admin "$@"' lib/ceph-readonly-sudo.sh
if grep -nE 'reboot|shutdown|systemctl|rm |chown|chmod|mkfs|wipefs|losetup|dmsetup|ceph[[:space:]].*(compact|delete)|juicefs[[:space:]]+gc' lib/ceph-readonly-sudo.sh; then
    echo 'forbidden operation found in read-only ceph wrapper' >&2
    exit 42
fi
grep -Fq 'I_ACK_LT_PREPARE_' lib/long_term.sh
grep -Fq 'I_ACK_LT004_COMPACT_' lib/long_term.sh
grep -Fq 'scrub_disabled_for_long_test' lib/long_term.sh
grep -Fq 'LT_MIN_OSD_DB_FREE_GIB' lib/long_term.sh
grep -Fq 'long_run_requires_frozen_slo' lib/long_term.sh
grep -Fq 'operator-stop.request' lib/long_term.sh
grep -Fq 'SAMPLE_GUARD_PERSISTENT' lib/long_term.sh
grep -Fq 'SAMPLE_RETRY_RECOVERED' lib/long_term.sh
grep -Fq 'SAMPLE_ATTEMPT_FAILED' lib/long_term.sh
grep -Fq 'ceph_health_capacity_guard' lib/long_term.sh
grep -Fq 'run_id_already_started' lib/long_term.sh
grep -Fq '.start-once-lock' lib/long_term.sh
grep -Fq 'code_snapshot_changed' lib/long_term.sh
grep -Fq 'config_snapshot_changed' lib/long_term.sh
grep -Fq 'LT_IODEPTH_OVERRIDE' lib/long_term.sh
grep -Fq 'LT_RATE_READ_MIB_PER_JOB' lib/long_term.sh
grep -Fq 'LT_PREPARE_RATE_MIB_PER_JOB' lib/long_term.sh
grep -Fq 'fuse_max_read_mismatch_expected_' lib/long_term.sh
grep -Fq 'juicefs_process_ceph_conf_mismatch' lib/long_term.sh
grep -Fq 'private_ceph_ms_async_op_threads_not_8' lib/long_term.sh
grep -Fq 'ceph_msgr_worker_count_mismatch' lib/long_term.sh
if grep -Fq 'command -v jq' lib/long_term.sh; then echo 'LT engine still hard-depends on jq' >&2; exit 42; fi
grep -Fq -- '--lat_percentiles=1' lib/long_term.sh
grep -Fq 'for name, scale in (("lat_ns"' lib/lt-analyze.py
[[ $(grep -c -- "curl --noproxy '\*'" lib/long_term.sh) -eq 4 ]]
grep -Fq 'LT_QD_CALIBRATION_SET' calibrate-randrw-qd.sh
grep -Fq -- '--lat_percentiles=1' calibrate-randrw-qd.sh
grep -Fq 'manifest.sha256' collect-long-term.sh
grep -Fq 'LT长测不由run.sh编排' run.sh

for case in LT-001 LT-002 LT-003 LT-004; do
    count=$(find cases -maxdepth 1 -type f -name "${case}-*.sh" | wc -l)
    [[ "$count" -eq 1 ]] || { echo "case count mismatch: $case=$count" >&2; exit 42; }
done

CASE_ID=LT-002 PROFILE=randrw256k LT_IODEPTH_OVERRIDE=4 bash -c '
  LT_CASE_SCRIPT=$PWD/cases/LT-002-fixed-dataset-overwrite-convergence.sh
  source lib/long_term.sh; LT_CASE_ID=$CASE_ID; lt_defaults 20991231-235959 "$PROFILE"
  [[ $LT_JOBS -eq 128 && $LT_IODEPTH -eq 4 ]]
'
if CASE_ID=LT-002 PROFILE=randrw256k LT_IODEPTH_OVERRIDE=0 bash -c '
     LT_CASE_SCRIPT=$PWD/cases/LT-002-fixed-dataset-overwrite-convergence.sh
     source lib/long_term.sh; LT_CASE_ID=$CASE_ID; lt_defaults 20991231-235959 "$PROFILE"
   ' >/dev/null 2>&1; then
    echo 'invalid iodepth override unexpectedly passed' >&2
    exit 42
fi

tmp_config=$(mktemp -d /tmp/lt-config-hash-test.XXXXXX)
trap 'rm -rf -- "$tmp_config"' EXIT
printf 'LT_IODEPTH_OVERRIDE=4\nLT_MAX_P99_US=10000000\n' >"$tmp_config/config.env"
(cd "$tmp_config" && sha256sum config.env >config.sha256)
LT_RESULT_ROOT="$tmp_config" bash -c '
  source lib/long_term.sh
  lt_verify_config_snapshot
'
printf 'LT_MAX_P99_US=99999999\n' >>"$tmp_config/config.env"
if LT_RESULT_ROOT="$tmp_config" bash -c '
     source lib/long_term.sh
     lt_verify_config_snapshot
   ' >/dev/null 2>&1; then
    echo 'tampered config snapshot unexpectedly passed' >&2
    exit 42
fi
rm -rf -- "$tmp_config"; trap - EXIT

profiles=(LT-001:seqread LT-001:randread LT-002:seqwrite16m LT-002:randwrite256k LT-002:randrw256k LT-003:seqwrite16m LT-003:randwrite256k LT-003:randrw256k LT-004:compact-randread)
for spec in "${profiles[@]}"; do
    case_id=${spec%%:*}; profile=${spec#*:}
    CASE_ID="$case_id" PROFILE="$profile" bash -c '
      LT_CASE_SCRIPT=$PWD/cases/LT-001-long-read-stability.sh
      source lib/long_term.sh
      LT_CASE_ID=$CASE_ID
      LT_SOURCE_DATA_ROOT=
      lt_defaults 20991231-235959 "$PROFILE"
      [[ $LT_RW && $LT_BS && $LT_JOBS -gt 0 && $LT_RESULT_ROOT == /mnt/jfs-cache/reliability-lt-results/* ]]
    '
done

# Offline production-identity and option parser checks (no cluster calls).
LT_FIXTURE_ROOT=$(mktemp -d /tmp/lt-config-contract-test.XXXXXX)
trap 'rm -rf -- "$LT_FIXTURE_ROOT"' EXIT
LT_FIXTURE_ROOT="$LT_FIXTURE_ROOT" bash -c '
  source lib/long_term.sh
  LT_CONFIG_PROFILE=production-157
  LT_EXPECTED_VOLUME_UUID=e1b69ea9-0e3d-427d-bea9-8765928afa66
  LT_EXPECTED_BLOCK_SIZE_KIB=256
  LT_EXPECTED_MAX_READ=262144
  LT_EXPECTED_MS_ASYNC_OP_THREADS=8
  lt_volume_contract '\''{"Setting":{"UUID":"e1b69ea9-0e3d-427d-bea9-8765928afa66","BlockSize":256}}'\'' >/dev/null
  if (lt_volume_contract '\''{"Setting":{"UUID":"3e54dcc4-991e-425a-8e76-16c9c1fb6836","BlockSize":256}}'\'' >/dev/null 2>&1); then exit 41; fi
  if (lt_volume_contract '\''{"Setting":{"UUID":"e1b69ea9-0e3d-427d-bea9-8765928afa66","BlockSize":128}}'\'' >/dev/null 2>&1); then exit 42; fi
  lt_validate_mount_max_read rw,max_read=262144
  if (lt_validate_mount_max_read rw,max_read=131072 >/dev/null 2>&1); then exit 43; fi
  [[ $(printf "msgr-worker-0\\nmsgr-worker-1\\nmsgr-worker-7\\nmsgr-worker-7\\nother\\n" | lt_count_msgr_workers) == 3 ]]
  lt_validate_worker_counts 8 0 8
  if lt_validate_worker_counts 8 0; then exit 46; fi
  if lt_validate_worker_counts 8 0 3; then exit 47; fi
  if lt_validate_worker_counts 8 0 8 3; then exit 48; fi
  LT_EXPECTED_CEPH_CONF="$LT_FIXTURE_ROOT/private.conf"
  LT_CEPH_CONF="$LT_EXPECTED_CEPH_CONF"
  printf "[client]\nms_async_op_threads = 8\n" >"$LT_EXPECTED_CEPH_CONF"
  LT_EXPECTED_CEPH_CONF_SHA=$(sha256sum "$LT_EXPECTED_CEPH_CONF" | awk "{print \$1}")
  lt_require_private_ceph_conf "$LT_EXPECTED_CEPH_CONF" "$LT_EXPECTED_CEPH_CONF"
  lt_require_private_ceph_conf "" "$LT_EXPECTED_CEPH_CONF"
  if (lt_require_private_ceph_conf /etc/ceph/ceph.conf "$LT_EXPECTED_CEPH_CONF" >/dev/null 2>&1); then exit 44; fi
  printf "[client]\nms_async_op_threads = 3\n" >"$LT_EXPECTED_CEPH_CONF"
  if (lt_require_private_ceph_conf "$LT_EXPECTED_CEPH_CONF" "$LT_EXPECTED_CEPH_CONF" >/dev/null 2>&1); then exit 45; fi
'
rm -rf -- "$LT_FIXTURE_ROOT"; trap - EXIT
if LT_RESULT_ROOT=/tmp/unsafe CASE_ID=LT-002 PROFILE=randrw256k bash -c '
     LT_CASE_SCRIPT=$PWD/cases/LT-002-fixed-dataset-overwrite-convergence.sh
     source lib/long_term.sh; LT_CASE_ID=$CASE_ID; lt_defaults 20991231-235959 "$PROFILE"
   ' >/dev/null 2>&1; then
    echo 'unsafe path fixture unexpectedly passed' >&2
    exit 42
fi

# The periodic sampler tolerates one transient probe failure, but a second
# consecutive failure still stops the workload and records the failing stage.
tmp_sampler=$(mktemp -d /tmp/lt-sampler-test.XXXXXX)
LT_TEST_ROOT="$tmp_sampler/recovered" bash -c '
  source lib/long_term.sh
  LT_RESULT_ROOT=$LT_TEST_ROOT; LT_SAMPLE_INTERVAL_S=30
  mkdir -p "$LT_RESULT_ROOT"; : >"$LT_RESULT_ROOT/incidents.tsv"; : >"$LT_RESULT_ROOT/active-fio.tsv"
  sleep(){ :; }
  calls=0
  lt_sample_once(){ calls=$((calls+1)); if (( calls == 1 )); then LT_SAMPLE_LAST_FAILURE=tikv_metrics_fixture; return 7; fi; : >"$LT_RESULT_ROOT/controller.done"; return 0; }
  lt_sampler "$LT_RESULT_ROOT/active-fio.tsv"
  [[ ! -e "$LT_RESULT_ROOT/STOP.txt" ]]
  grep -Fq "SAMPLE_RETRY_RECOVERED" "$LT_RESULT_ROOT/incidents.tsv"
'
set +e
LT_TEST_ROOT="$tmp_sampler/stopped" bash -c '
  source lib/long_term.sh
  LT_RESULT_ROOT=$LT_TEST_ROOT; LT_SAMPLE_INTERVAL_S=30
  mkdir -p "$LT_RESULT_ROOT"; : >"$LT_RESULT_ROOT/incidents.tsv"; : >"$LT_RESULT_ROOT/active-fio.tsv"
  sleep(){ :; }
  lt_sample_once(){ LT_SAMPLE_LAST_FAILURE=storage_host_fixture; return 7; }
  lt_sampler "$LT_RESULT_ROOT/active-fio.tsv"
'
sampler_rc=$?
set -e
[[ "$sampler_rc" -eq 7 ]]
grep -Fq $'SAMPLE_GUARD_PERSISTENT\tfirst=storage_host_fixture\tfinal=storage_host_fixture' "$tmp_sampler/stopped/STOP.txt"
rm -r -- "$tmp_sampler"

CASE_ID=LT-002 PROFILE=randrw256k bash -c '
  LT_CASE_SCRIPT=$PWD/cases/LT-002-fixed-dataset-overwrite-convergence.sh
  source env/cluster-192.168.11.env
  source lib/long_term.sh
  LT_CASE_ID=$CASE_ID
  lt_defaults 20991231-235959 "$PROFILE"
  [[ $LT_CONFIG_PROFILE == slow-validation-192 && $LT_EXPECTED_MAX_READ == 131072 ]]
  [[ $LT_EXPECTED_VOLUME_UUID == 3e54dcc4-991e-425a-8e76-16c9c1fb6836 ]]
  [[ $LT_RESULT_ROOT == /data/reliability-lt-results/20991231-235959/LT-002 ]]
  [[ $LT_DATA_ROOT == /mnt/juicefs/reliability-lt-data/20991231-235959/LT-002/randrw256k ]]
  [[ $LT_OSD_IDS == 0,2,3,4,5,6 && $LT_STORAGE_IOSTAT_DEVICES == sdb ]]
'

for bad in '0,2,3,4,5,5' '0,2,3' '0,2,x,4,5,6'; do
  if LT_OSD_IDS=$bad LT_EXPECTED_OSD_COUNT=6 CASE_ID=LT-002 PROFILE=randrw256k bash -c '
       LT_CASE_SCRIPT=$PWD/cases/LT-002-fixed-dataset-overwrite-convergence.sh
       source lib/long_term.sh; LT_CASE_ID=$CASE_ID; lt_defaults 20991231-235959 "$PROFILE"
     ' >/dev/null 2>&1; then
      echo "invalid OSD contract unexpectedly passed: $bad" >&2
      exit 42
  fi
done

lib/ceph-readonly-sudo.sh osd destroy 0 >/dev/null 2>&1 && {
    echo 'read-only ceph wrapper accepted a write command' >&2
    exit 42
}

echo 'LT_GATE0_OFFLINE_PASS cases=4 common_engine=1 cluster_access=0'
