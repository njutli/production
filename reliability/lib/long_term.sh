#!/usr/bin/env bash
# Long-duration reliability engine.  This file is sourced by cases/LT-*.sh.
# It never changes cluster configuration, deletes a dataset, or kills an
# unowned PID.  A cluster profile may select an audited read-only Ceph wrapper.
set -euo pipefail
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
umask 077

_LT_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_LT_ANALYZER="${_LT_LIB_DIR}/lt-analyze.py"
_LT_SLICE_ANALYZER="${_LT_LIB_DIR}/lt-slice-analyze.py"

lt_die() { printf 'LT_FAIL\t%s\n' "$*" >&2; exit 42; }
lt_note() { printf '%s\t%s\n' "$(date -Is)" "$*"; }
lt_record() { local f=$1; shift; printf '%q ' "$@" >>"$f"; printf '\n' >>"$f"; }
lt_state() { printf '%s\t%s\t%s\n' "$(date -Is)" "$1" "${2:-}" >>"$LT_RESULT_ROOT/run-state.tsv"; }

lt_valid_run_id() { [[ $1 =~ ^[0-9]{8}-[0-9]{6}$ ]]; }
lt_safe_paths() {
    local expected_result expected_data
    [[ "$LT_RESULT_MOUNT" == /* && "$LT_RESULT_MOUNT" != / ]] || lt_die unsafe_result_mount
    [[ "$LT_MOUNT_POINT" == /* && "$LT_MOUNT_POINT" != / ]] || lt_die unsafe_juicefs_mount
    expected_result="$(realpath -m -- "$LT_RESULT_MOUNT/reliability-lt-results/${LT_RUN_ID}/${LT_CASE_ID}")"
    [[ "$LT_RESULT_ROOT" == "$expected_result" ]] || lt_die unsafe_result_root
    [[ $(realpath -m -- "$LT_RESULT_ROOT") == "$LT_RESULT_ROOT" ]] || lt_die noncanonical_result_root
    if [[ "$LT_CASE_ID" == LT-004 && -n ${LT_SOURCE_DATA_ROOT:-} ]]; then
        [[ "$LT_DATA_ROOT" == "$LT_MOUNT_POINT"/reliability-lt-data/* ]] || lt_die unsafe_source_data_root
        [[ -e "$LT_DATA_ROOT" && $(realpath -e -- "$LT_DATA_ROOT") == "$LT_DATA_ROOT" ]] || lt_die noncanonical_source_data_root
    else
        expected_data="$(realpath -m -- "$LT_MOUNT_POINT/reliability-lt-data/${LT_RUN_ID}/${LT_CASE_ID}/${LT_PROFILE}")"
        [[ "$LT_DATA_ROOT" == "$expected_data" ]] || lt_die unsafe_data_root
        [[ $(realpath -m -- "$LT_DATA_ROOT") == "$LT_DATA_ROOT" ]] || lt_die noncanonical_data_root
    fi
    [[ "$LT_RESULT_ROOT" != / && "$LT_DATA_ROOT" != / && ! -L "$LT_RESULT_ROOT" && ! -L "$LT_DATA_ROOT" ]] || lt_die unsafe_or_symlink_root
}

lt_profile_contract() {
    case "${LT_CASE_ID}:${LT_PROFILE}" in
        LT-001:seqread)
            LT_RW=read; LT_BS=256K; LT_JOBS=1; LT_IOENGINE=psync; LT_IODEPTH=1; LT_FILESIZE=32G; LT_SIZE=32G ;;
        LT-001:randread)
            LT_RW=randread; LT_BS=256K; LT_JOBS=128; LT_IOENGINE=libaio; LT_IODEPTH=128; LT_FILESIZE=1G; LT_SIZE=1G ;;
        LT-002:seqwrite16m)
            LT_RW=write; LT_BS=16M; LT_JOBS=16; LT_IOENGINE=psync; LT_IODEPTH=1; LT_FILESIZE=4G; LT_SIZE=4G ;;
        LT-002:randwrite256k)
            LT_RW=randwrite; LT_BS=256K; LT_JOBS=128; LT_IOENGINE=libaio; LT_IODEPTH=128; LT_FILESIZE=1G; LT_SIZE=1G ;;
        LT-002:randrw256k)
            LT_RW=randrw; LT_BS=256K; LT_JOBS=128; LT_IOENGINE=libaio; LT_IODEPTH=128; LT_FILESIZE=1G; LT_SIZE=1G ;;
        LT-003:seqwrite16m)
            LT_RW=write; LT_BS=16M; LT_JOBS=16; LT_IOENGINE=psync; LT_IODEPTH=1; LT_FILESIZE=4G; LT_SIZE=4G ;;
        LT-003:randwrite256k)
            LT_RW=randwrite; LT_BS=256K; LT_JOBS=128; LT_IOENGINE=libaio; LT_IODEPTH=128; LT_FILESIZE=1G; LT_SIZE=1G ;;
        LT-003:randrw256k)
            LT_RW=randrw; LT_BS=256K; LT_JOBS=128; LT_IOENGINE=libaio; LT_IODEPTH=128; LT_FILESIZE=1G; LT_SIZE=1G ;;
        LT-004:compact-randread)
            LT_RW=randread; LT_BS=256K; LT_JOBS=128; LT_IOENGINE=libaio; LT_IODEPTH=128; LT_FILESIZE=1G; LT_SIZE=1G ;;
        *) lt_die "unsupported_profile=${LT_CASE_ID}:${LT_PROFILE}" ;;
    esac
    if [[ -n ${LT_IODEPTH_OVERRIDE:-} ]]; then
        [[ "$LT_IODEPTH_OVERRIDE" =~ ^[1-9][0-9]*$ && "$LT_IODEPTH_OVERRIDE" -le 128 ]] || lt_die invalid_iodepth_override
        [[ "$LT_IOENGINE" == libaio ]] || lt_die iodepth_override_requires_libaio
        LT_IODEPTH=$LT_IODEPTH_OVERRIDE
    fi
}

lt_defaults() {
    LT_RUN_ID=$1; LT_PROFILE=$2
    lt_valid_run_id "$LT_RUN_ID" || lt_die invalid_run_id
    LT_CONFIG_PROFILE=${LT_CONFIG_PROFILE:-production-157}
    case "$LT_CONFIG_PROFILE" in
        production-157)
            _lt_contract_uuid=e1b69ea9-0e3d-427d-bea9-8765928afa66
            _lt_contract_md5=24fae0852051c80ca571cb2f20275d46
            _lt_contract_block_kib=256; _lt_contract_max_read=262144
            _lt_contract_msgr=8
            _lt_contract_conf_sha=c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48 ;;
        slow-validation-192)
            _lt_contract_uuid=3e54dcc4-991e-425a-8e76-16c9c1fb6836
            _lt_contract_md5=24fae0852051c80ca571cb2f20275d46
            _lt_contract_block_kib=256; _lt_contract_max_read=131072
            _lt_contract_msgr=3
            _lt_contract_conf_sha= ;;
        *) lt_die "unknown_lt_config_profile=$LT_CONFIG_PROFILE" ;;
    esac
    LT_EXPECTED_VOLUME_UUID=${LT_EXPECTED_VOLUME_UUID:-$_lt_contract_uuid}
    LT_EXPECTED_BLOCK_SIZE_KIB=${LT_EXPECTED_BLOCK_SIZE_KIB:-$_lt_contract_block_kib}
    LT_EXPECTED_JFS_MD5=${LT_EXPECTED_JFS_MD5:-$_lt_contract_md5}
    LT_EXPECTED_MAX_READ=${LT_EXPECTED_MAX_READ:-$_lt_contract_max_read}
    LT_EXPECTED_MS_ASYNC_OP_THREADS=${LT_EXPECTED_MS_ASYNC_OP_THREADS:-$_lt_contract_msgr}
    LT_EXPECTED_CEPH_CONF_SHA=${LT_EXPECTED_CEPH_CONF_SHA:-$_lt_contract_conf_sha}
    LT_DURATION_S=${LT_DURATION_S:-7200}
    LT_WINDOW_S=${LT_WINDOW_S:-3600}
    LT_SAMPLE_INTERVAL_S=${LT_SAMPLE_INTERVAL_S:-60}
    # Optional fio per-job MiB/s caps. Zero means no cap; nonzero values are
    # explicit workload changes and are frozen in each RUN's config snapshot.
    LT_RATE_READ_MIB_PER_JOB=${LT_RATE_READ_MIB_PER_JOB:-0}
    LT_RATE_WRITE_MIB_PER_JOB=${LT_RATE_WRITE_MIB_PER_JOB:-0}
    LT_PREPARE_RATE_MIB_PER_JOB=${LT_PREPARE_RATE_MIB_PER_JOB:-0}
    LT_VERIFY_RATE_MIB_PER_JOB=${LT_VERIFY_RATE_MIB_PER_JOB:-0}
    LT_DRAIN_S=${LT_DRAIN_S:-600}
    LT_BURST_S=${LT_BURST_S:-600}
    LT_IDLE_S=${LT_IDLE_S:-600}
    LT_HOTSET_AFTER_CYCLES=${LT_HOTSET_AFTER_CYCLES:-3}
    LT_COMPACT_OFFSET_S=${LT_COMPACT_OFFSET_S:-300}
    LT_COMPACT_LIMIT=${LT_COMPACT_LIMIT:-16}
    LT_METADATA_DUMP_EVERY_WINDOWS=${LT_METADATA_DUMP_EVERY_WINDOWS:-6}
    LT_MOUNT_POINT=${LT_MOUNT_POINT:-/mnt/juicefs}
    LT_JFS=${LT_JFS:-/tmp/juicefs-1.4.1-patched}
    LT_META=${LT_META:-tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod}
    LT_METRICS_URL=${LT_METRICS_URL:-http://127.0.0.1:9567/metrics}
    LT_CEPH_CONF=${LT_CEPH_CONF:-/etc/ceph/ceph.conf}
    # Production acceptance requires the JuiceFS process to use an explicit
    # client-private Ceph config.  No default is intentional: missing this
    # value must stop plan/prepare/start instead of silently using system conf.
    LT_EXPECTED_CEPH_CONF=${LT_EXPECTED_CEPH_CONF:-}
    LT_CEPH_KEYRING=${LT_CEPH_KEYRING:-/etc/ceph/ceph.client.admin.keyring}
    LT_CEPH_READONLY_WRAPPER=${LT_CEPH_READONLY_WRAPPER:-}
    LT_CEPH_POOL=${LT_CEPH_POOL:-juicefs-data}
    LT_OSD_IDS=${LT_OSD_IDS:-0,1,2,3,4,5}
    LT_EXPECTED_OSD_COUNT=${LT_EXPECTED_OSD_COUNT:-6}
    LT_MIN_CLIENT_MEM_GIB=${LT_MIN_CLIENT_MEM_GIB:-64}
    LT_MIN_RESULT_FREE_GIB=${LT_MIN_RESULT_FREE_GIB:-20}
    LT_MIN_CEPH_MAX_AVAIL_TIB=${LT_MIN_CEPH_MAX_AVAIL_TIB:-5}
    LT_MIN_OSD_DB_FREE_GIB=${LT_MIN_OSD_DB_FREE_GIB:-4}
    LT_MAX_SLICE_AMP=${LT_MAX_SLICE_AMP:-128}
    LT_MAX_LOW_DRIFT_PCT=${LT_MAX_LOW_DRIFT_PCT:-10}
    LT_MIN_READ_BW_MIB=${LT_MIN_READ_BW_MIB:-1}
    LT_MIN_WRITE_BW_MIB=${LT_MIN_WRITE_BW_MIB:-1}
    LT_MAX_P99_US=${LT_MAX_P99_US:-10000000}
    LT_MIN_WINDOW_RATIO_PCT=${LT_MIN_WINDOW_RATIO_PCT:-70}
    LT_MAX_P99_RATIO=${LT_MAX_P99_RATIO:-3}
    LT_MAX_WINDOW_GAP_S=${LT_MAX_WINDOW_GAP_S:-30}
    # The defaults above are only emergency/safety bounds for the 2-hour
    # screen.  A 24/72-hour acceptance run must explicitly freeze its SLOs.
    LT_SLO_FROZEN=${LT_SLO_FROZEN:-0}
    # Explicit environment adaptation for slow validation clusters.  The
    # override is frozen into config.env and never changes job/file count.
    LT_IODEPTH_OVERRIDE=${LT_IODEPTH_OVERRIDE:-}
    LT_RESULT_MOUNT=${LT_RESULT_MOUNT:-/mnt/jfs-cache}
    LT_RESULT_ROOT=${LT_RESULT_ROOT:-${LT_RESULT_MOUNT}/reliability-lt-results/${LT_RUN_ID}/${LT_CASE_ID}}
    LT_EXPECTED_RESULT_DEVICE=${LT_EXPECTED_RESULT_DEVICE:-/dev/nvme1n1}
    if [[ "$LT_CASE_ID" == LT-004 && -n ${LT_SOURCE_DATA_ROOT:-} ]]; then
        LT_DATA_ROOT=$LT_SOURCE_DATA_ROOT
    else
        LT_DATA_ROOT=${LT_DATA_ROOT:-${LT_MOUNT_POINT}/reliability-lt-data/${LT_RUN_ID}/${LT_CASE_ID}/${LT_PROFILE}}
    fi
    LT_STORAGE_NODES=${LT_STORAGE_NODES:-10.20.1.150,10.20.1.151,10.20.1.152}
    LT_STORAGE_SSH_USER=${LT_STORAGE_SSH_USER:-sunrise}
    LT_STORAGE_SSH_KEY=${LT_STORAGE_SSH_KEY:-}
    LT_STORAGE_SSH_PASSWORD_FILE=${LT_STORAGE_SSH_PASSWORD_FILE:-}
    LT_STORAGE_IOSTAT_DEVICES=${LT_STORAGE_IOSTAT_DEVICES:-nvme1n1 nvme2n1 nvme3n1}
    [[ "$LT_DURATION_S" =~ ^[0-9]+$ && "$LT_DURATION_S" -ge 600 && "$LT_DURATION_S" -le 259200 ]] || lt_die duration_out_of_range
    [[ "$LT_WINDOW_S" =~ ^[0-9]+$ && "$LT_WINDOW_S" -ge 300 && "$LT_WINDOW_S" -le 3600 ]] || lt_die window_out_of_range
    [[ "$LT_SAMPLE_INTERVAL_S" =~ ^[0-9]+$ && "$LT_SAMPLE_INTERVAL_S" -ge 30 && "$LT_SAMPLE_INTERVAL_S" -le 300 ]] || lt_die sample_interval_out_of_range
    [[ "$LT_DRAIN_S" =~ ^[0-9]+$ && "$LT_DRAIN_S" -ge 60 && "$LT_DRAIN_S" -le 7200 ]] || lt_die drain_out_of_range
    [[ "$LT_BURST_S" =~ ^[0-9]+$ && "$LT_BURST_S" -ge 60 && "$LT_BURST_S" -le 3600 ]] || lt_die burst_out_of_range
    [[ "$LT_IDLE_S" =~ ^[0-9]+$ && "$LT_IDLE_S" -ge 60 && "$LT_IDLE_S" -le 3600 ]] || lt_die idle_out_of_range
    [[ "$LT_HOTSET_AFTER_CYCLES" =~ ^[0-9]+$ && "$LT_HOTSET_AFTER_CYCLES" -ge 1 && "$LT_HOTSET_AFTER_CYCLES" -le 100 ]] || lt_die hotset_cycle_out_of_range
    [[ "$LT_COMPACT_OFFSET_S" =~ ^[0-9]+$ && "$LT_COMPACT_OFFSET_S" -ge 1 && "$LT_COMPACT_OFFSET_S" -le 3600 ]] || lt_die compact_offset_out_of_range
    if [[ "$LT_CASE_ID" == LT-004 ]] && (( LT_COMPACT_OFFSET_S >= LT_WINDOW_S )); then lt_die compact_offset_not_inside_window; fi
    [[ "$LT_COMPACT_LIMIT" =~ ^[0-9]+$ && "$LT_COMPACT_LIMIT" -ge 1 && "$LT_COMPACT_LIMIT" -le 128 ]] || lt_die compact_limit_out_of_range
    [[ "$LT_METADATA_DUMP_EVERY_WINDOWS" =~ ^[0-9]+$ && "$LT_METADATA_DUMP_EVERY_WINDOWS" -ge 1 && "$LT_METADATA_DUMP_EVERY_WINDOWS" -le 24 ]] || lt_die metadata_dump_interval_out_of_range
    [[ "$LT_SLO_FROZEN" == 0 || "$LT_SLO_FROZEN" == 1 ]] || lt_die invalid_slo_frozen_flag
    [[ "$LT_EXPECTED_OSD_COUNT" =~ ^[1-9][0-9]*$ ]] || lt_die invalid_expected_osd_count
    [[ "$LT_OSD_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]] || lt_die invalid_osd_ids
    IFS=, read -r -a _lt_osd_ids <<<"$LT_OSD_IDS"
    [[ "${#_lt_osd_ids[@]}" -eq "$LT_EXPECTED_OSD_COUNT" ]] || lt_die osd_count_contract_mismatch
    [[ "$(printf '%s\n' "${_lt_osd_ids[@]}" | sort -un | wc -l)" -eq "$LT_EXPECTED_OSD_COUNT" ]] || lt_die duplicate_osd_ids
    [[ "$LT_STORAGE_IOSTAT_DEVICES" =~ ^[A-Za-z0-9._-]+([[:space:]]+[A-Za-z0-9._-]+)*$ ]] || lt_die invalid_iostat_devices
    [[ "$LT_EXPECTED_JFS_MD5" == "$_lt_contract_md5" ]] || lt_die juicefs_md5_contract_mismatch
    [[ "$LT_EXPECTED_VOLUME_UUID" == "$_lt_contract_uuid" ]] || lt_die volume_uuid_contract_mismatch
    [[ "$LT_EXPECTED_BLOCK_SIZE_KIB" == "$_lt_contract_block_kib" ]] || lt_die block_size_contract_mismatch
    [[ "$LT_EXPECTED_MAX_READ" == "$_lt_contract_max_read" ]] || lt_die fuse_max_read_contract_mismatch
    [[ "$LT_EXPECTED_MS_ASYNC_OP_THREADS" == "$_lt_contract_msgr" ]] || lt_die ceph_msgr_thread_contract_mismatch
    [[ "$LT_EXPECTED_CEPH_CONF_SHA" == "$_lt_contract_conf_sha" ]] || lt_die ceph_conf_hash_contract_mismatch
    for _lt_rate in "$LT_RATE_READ_MIB_PER_JOB" "$LT_RATE_WRITE_MIB_PER_JOB" "$LT_PREPARE_RATE_MIB_PER_JOB" "$LT_VERIFY_RATE_MIB_PER_JOB"; do
        [[ "$_lt_rate" =~ ^[0-9]+$ && "$_lt_rate" -le 64 ]] || lt_die invalid_rate_cap_mib_per_job
    done
    for _lt_value in "$LT_MIN_CLIENT_MEM_GIB" "$LT_MIN_RESULT_FREE_GIB" "$LT_MIN_CEPH_MAX_AVAIL_TIB" "$LT_MIN_OSD_DB_FREE_GIB" "$LT_MAX_SLICE_AMP" "$LT_MAX_LOW_DRIFT_PCT" "$LT_MIN_READ_BW_MIB" "$LT_MIN_WRITE_BW_MIB" "$LT_MAX_P99_US" "$LT_MIN_WINDOW_RATIO_PCT" "$LT_MAX_P99_RATIO" "$LT_MAX_WINDOW_GAP_S"; do
        [[ "$_lt_value" =~ ^[0-9]+([.][0-9]+)?$ ]] || lt_die invalid_numeric_threshold
    done
    lt_profile_contract
    lt_safe_paths
}

lt_ceph() {
    if [[ -n "$LT_CEPH_READONLY_WRAPPER" ]]; then
        "$LT_CEPH_READONLY_WRAPPER" "$@"
    else
        ceph --conf "$LT_CEPH_CONF" --keyring "$LT_CEPH_KEYRING" -n client.admin "$@"
    fi
}

lt_storage_ssh() {
    local node=$1; shift
    local -a opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
    if [[ -n "$LT_STORAGE_SSH_KEY" ]]; then
        ssh -i "$LT_STORAGE_SSH_KEY" "${opts[@]}" "${LT_STORAGE_SSH_USER}@${node}" "$@"
    elif [[ -n "$LT_STORAGE_SSH_PASSWORD_FILE" ]]; then
        sshpass -f "$LT_STORAGE_SSH_PASSWORD_FILE" ssh -o BatchMode=no "${opts[@]}" "${LT_STORAGE_SSH_USER}@${node}" "$@"
    else
        ssh "${opts[@]}" "${LT_STORAGE_SSH_USER}@${node}" "$@"
    fi
}

lt_volume_contract() {
    local json=$1
    python3 - "$LT_EXPECTED_VOLUME_UUID" "$LT_EXPECTED_BLOCK_SIZE_KIB" "$json" <<'PY'
import json, sys
expected_uuid, expected_bs, raw = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    doc = json.loads(raw)
    settings = doc.get("Setting") or doc.get("Format") or doc
    uuid = settings.get("UUID")
    bs = settings.get("BlockSize", settings.get("blockSize"))
except (ValueError, AttributeError, TypeError):
    raise SystemExit(7)
if uuid != expected_uuid:
    print("volume_uuid_mismatch", file=sys.stderr); raise SystemExit(8)
if bs != expected_bs:
    print("volume_block_size_mismatch", file=sys.stderr); raise SystemExit(9)
print(json.dumps({"UUID": uuid, "BlockSize": bs}, sort_keys=True))
PY
}

lt_require_private_ceph_conf() {
    local actual=$1 conf=$2
    [[ "$LT_CONFIG_PROFILE" == production-157 ]] || return 0
    [[ -n "$LT_EXPECTED_CEPH_CONF" ]] || lt_die expected_private_ceph_conf_required
    [[ "$LT_EXPECTED_CEPH_CONF" == /* && "$LT_EXPECTED_CEPH_CONF" != /etc/ceph/ceph.conf ]] || lt_die expected_private_ceph_conf_invalid
    [[ "$LT_CEPH_CONF" == "$LT_EXPECTED_CEPH_CONF" ]] || lt_die ceph_conf_path_contract_mismatch
    [[ -r "$conf" && ! -L "$conf" ]] || lt_die private_ceph_conf_unreadable_or_symlink
    [[ "$(realpath -e -- "$conf")" == "$LT_EXPECTED_CEPH_CONF" ]] || lt_die private_ceph_conf_path_mismatch
    # JuiceFS mount -d may clear CEPH_CONF in the daemon's /proc/environ.
    # An exposed value must match; actual eight worker threads remain required.
    [[ -z "$actual" || "$actual" == "$LT_EXPECTED_CEPH_CONF" ]] || lt_die juicefs_process_ceph_conf_mismatch
    [[ "$actual" != /etc/ceph/ceph.conf ]] || lt_die system_ceph_conf_not_accepted
    [[ $(sha256sum "$conf" | awk '{print $1}') == "$LT_EXPECTED_CEPH_CONF_SHA" ]] || lt_die private_ceph_conf_hash_mismatch
    python3 - "$conf" <<'PY' || lt_die private_ceph_ms_async_op_threads_not_8
import configparser, sys
parser = configparser.ConfigParser(interpolation=None, strict=True)
try:
    loaded = parser.read(sys.argv[1])
    value = parser.get("client", "ms_async_op_threads", fallback="").strip()
except (configparser.Error, OSError):
    raise SystemExit(7)
raise SystemExit(0 if loaded and value == "8" else 7)
PY
}

lt_validate_mount_max_read() {
    local options=$1 value
    value=$(python3 - "$options" <<'PY'
import sys
found = [part.split("=", 1)[1] for part in sys.argv[1].split(",")
         if part.startswith("max_read=") and "=" in part]
print(found[-1] if found else "")
PY
    )
    [[ "$value" == "$LT_EXPECTED_MAX_READ" ]] || lt_die "fuse_max_read_mismatch_expected_${LT_EXPECTED_MAX_READ}_actual_${value:-missing}"
}

lt_count_msgr_workers() {
    awk '/^msgr-worker-[0-9]+$/ { seen[$0]=1 } END { print length(seen) }'
}

lt_validate_worker_counts() {
    local expected=$1 count found=0
    shift
    (($# > 0)) || return 1
    for count in "$@"; do
        [[ "$count" =~ ^[0-9]+$ ]] || return 1
        (( count == 0 )) && continue
        (( count == expected )) || return 1
        found=1
    done
    (( found == 1 ))
}

lt_preflight() {
    local mode=${1:-execute} flags volume_json node metrics result_source expected_md5 expected_version pid proc_md5 cmdline mount_identity=0 ceph_conf_value mount_options local_workers
    local -a worker_counts=()
    command -v fio >/dev/null || lt_die fio_missing
    command -v python3 >/dev/null || lt_die python3_missing
    command -v ceph >/dev/null || lt_die ceph_missing
    [[ -x "$LT_JFS" && ! -L "$LT_JFS" ]] || lt_die juicefs_binary_invalid
    mountpoint -q "$LT_MOUNT_POINT" || lt_die juicefs_mount_missing
    result_source=$(findmnt -rn -M "$LT_RESULT_MOUNT" -o SOURCE) || lt_die result_mount_missing
    [[ "$result_source" == "$LT_EXPECTED_RESULT_DEVICE" ]] || lt_die result_mount_device_mismatch
    if [[ -r "$LT_MOUNT_POINT/.config" ]]; then
        volume_json=$(<"$LT_MOUNT_POINT/.config") || lt_die volume_config_unreadable
    else
        volume_json=$("$LT_JFS" status "$LT_META" 2>/dev/null) || lt_die volume_status_unreadable
    fi
    lt_volume_contract "$volume_json" >/dev/null || lt_die volume_config_invalid
    mount_options=$(findmnt -rn -M "$LT_MOUNT_POINT" -o OPTIONS) || lt_die juicefs_mount_options_unreadable
    lt_validate_mount_max_read "$mount_options"
    pgrep -x fio >/dev/null 2>&1 && lt_die foreign_fio_present
    [[ -r "$LT_CEPH_CONF" ]] || lt_die ceph_config_unreadable
    if [[ -n "$LT_CEPH_READONLY_WRAPPER" ]]; then
        [[ -x "$LT_CEPH_READONLY_WRAPPER" && ! -L "$LT_CEPH_READONLY_WRAPPER" ]] || lt_die ceph_readonly_wrapper_invalid
    else
        [[ -r "$LT_CEPH_KEYRING" ]] || lt_die ceph_credentials_unreadable
    fi
    lt_ceph -s -f json >/dev/null || lt_die ceph_query_failed
    metrics=$(curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 "$LT_METRICS_URL") || lt_die juicefs_metrics_unreachable
    grep -q '^juicefs_process_cpu_seconds_total' <<<"$metrics" || lt_die juicefs_metrics_identity_missing
    for _lt_metric in juicefs_staging_blocks juicefs_staging_block_bytes juicefs_staging_writing_blocks juicefs_object_request_uploading; do
        grep -Eq "^${_lt_metric}(\\{| )" <<<"$metrics" || lt_die "juicefs_metric_missing_${_lt_metric}"
    done
    expected_md5=$(md5sum "$LT_JFS" | awk '{print $1}')
    [[ "$expected_md5" == "$LT_EXPECTED_JFS_MD5" ]] || lt_die juicefs_binary_md5_mismatch
    expected_version=$("$LT_JFS" version 2>/dev/null | awk '{print $NF}') || lt_die juicefs_version_unreadable
    grep -Fq "juicefs_version=\"${expected_version}\"" <<<"$metrics" || lt_die juicefs_metrics_version_mismatch
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || continue
        cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
        proc_md5=
        if [[ -r "/proc/$pid/exe" ]]; then
            proc_md5=$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}' || true)
        elif [[ "$LT_CONFIG_PROFILE" == slow-validation-192 && "$cmdline" == "$LT_JFS mount "* && "$cmdline" == *" $LT_MOUNT_POINT"* ]]; then
            # The 192 client mounts JuiceFS as root. This is a read-only
            # fingerprint check; it does not grant the workload sudo access.
            proc_md5=$(sudo -n /usr/bin/md5sum -- "/proc/$pid/exe" 2>/dev/null | awk '{print $1}' || true)
            [[ -n "$proc_md5" ]] || lt_die juicefs_process_exe_unreadable
        elif [[ "$cmdline" == "$LT_JFS mount "* && "$cmdline" == *" $LT_MOUNT_POINT"* ]]; then
            lt_die juicefs_process_exe_unreadable
        fi
        if [[ "$proc_md5" == "$expected_md5" ]]; then
            mount_identity=1
            if [[ "$LT_CONFIG_PROFILE" == production-157 ]]; then
                ceph_conf_value=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^CEPH_CONF=//p' | tail -n 1)
                lt_require_private_ceph_conf "$ceph_conf_value" "$LT_CEPH_CONF"
                local_workers=$(ps -L -p "$pid" -o comm= 2>/dev/null | lt_count_msgr_workers)
                worker_counts+=("${local_workers:-unknown}")
            fi
        elif [[ "$cmdline" == "$LT_JFS mount "* && "$cmdline" == *" $LT_MOUNT_POINT"* ]]; then
            lt_die juicefs_mount_binary_identity_mismatch
        fi
    done < <(pgrep -f "juicefs.*mount.*${LT_MOUNT_POINT}" || true)
    (( mount_identity == 1 )) || lt_die juicefs_mount_binary_identity_mismatch
    if [[ "$LT_CONFIG_PROFILE" == production-157 ]]; then
        lt_validate_worker_counts "$LT_EXPECTED_MS_ASYNC_OP_THREADS" "${worker_counts[@]}" || lt_die "ceph_msgr_worker_count_mismatch=${worker_counts[*]:-none}"
    fi
    flags=$(lt_ceph osd dump -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); f=d.get("flags", []); print(",".join(f) if isinstance(f,list) else f)') || lt_die ceph_flags_query_failed
    if grep -Eq '(^|,)(noscrub|nodeep-scrub)(,|$)' <<<"$flags"; then lt_die scrub_disabled_for_long_test; fi
    IFS=, read -r -a _lt_nodes <<<"$LT_STORAGE_NODES"
    for node in "${_lt_nodes[@]}"; do
        lt_storage_ssh "$node" "test -r /proc/meminfo -a -r /proc/pressure/io; for dev in $LT_STORAGE_IOSTAT_DEVICES; do test -r /sys/class/block/\$dev/stat || exit 7; done" >/dev/null || lt_die "storage_readonly_probe_failed_${node}"
    done
    [[ "$mode" == plan ]] || lt_sample_once preflight
}

lt_write_config() {
    local file=$1 name
    : >"$file"
    for name in LT_CONFIG_PROFILE LT_EXPECTED_MAX_READ LT_EXPECTED_MS_ASYNC_OP_THREADS LT_CASE_ID LT_RUN_ID LT_PROFILE LT_DURATION_S LT_WINDOW_S LT_SAMPLE_INTERVAL_S LT_DRAIN_S LT_BURST_S LT_IDLE_S LT_HOTSET_AFTER_CYCLES LT_COMPACT_OFFSET_S LT_COMPACT_LIMIT LT_METADATA_DUMP_EVERY_WINDOWS LT_MOUNT_POINT LT_JFS LT_META LT_METRICS_URL LT_CEPH_CONF LT_EXPECTED_CEPH_CONF LT_CEPH_KEYRING LT_CEPH_READONLY_WRAPPER LT_CEPH_POOL LT_EXPECTED_VOLUME_UUID LT_EXPECTED_BLOCK_SIZE_KIB LT_EXPECTED_JFS_MD5 LT_OSD_IDS LT_EXPECTED_OSD_COUNT LT_MIN_CLIENT_MEM_GIB LT_MIN_RESULT_FREE_GIB LT_MIN_CEPH_MAX_AVAIL_TIB LT_MIN_OSD_DB_FREE_GIB LT_MAX_SLICE_AMP LT_MAX_LOW_DRIFT_PCT LT_MIN_READ_BW_MIB LT_MIN_WRITE_BW_MIB LT_MAX_P99_US LT_MIN_WINDOW_RATIO_PCT LT_MAX_P99_RATIO LT_MAX_WINDOW_GAP_S LT_SLO_FROZEN LT_IODEPTH_OVERRIDE LT_RESULT_ROOT LT_RESULT_MOUNT LT_EXPECTED_RESULT_DEVICE LT_DATA_ROOT LT_STORAGE_NODES LT_STORAGE_SSH_USER LT_STORAGE_SSH_KEY LT_STORAGE_SSH_PASSWORD_FILE LT_STORAGE_IOSTAT_DEVICES LT_SOURCE_DATA_ROOT; do
        printf '%s=%q\n' "$name" "${!name:-}" >>"$file"
    done
    printf 'LT_EXPECTED_CEPH_CONF_SHA=%q\n' "${LT_EXPECTED_CEPH_CONF_SHA:-}" >>"$file"
    for name in LT_RATE_READ_MIB_PER_JOB LT_RATE_WRITE_MIB_PER_JOB LT_PREPARE_RATE_MIB_PER_JOB LT_VERIFY_RATE_MIB_PER_JOB; do
        printf '%s=%q\n' "$name" "${!name:-}" >>"$file"
    done
    chmod 0600 "$file"
    (cd "$(dirname -- "$file")" && sha256sum "$(basename -- "$file")" >config.sha256)
    chmod 0400 "$file" "$(dirname -- "$file")/config.sha256"
}

lt_verify_config_snapshot() {
    [[ -s "$LT_RESULT_ROOT/config.sha256" ]] || lt_die config_checksum_missing
    (cd "$LT_RESULT_ROOT" && sha256sum -c config.sha256 >/dev/null) || lt_die config_snapshot_changed
}

lt_snapshot_code() {
    mkdir -m 0700 -p "$LT_RESULT_ROOT/code/cases" "$LT_RESULT_ROOT/code/lib"
    cp -- "$LT_CASE_SCRIPT" "$LT_RESULT_ROOT/code/cases/$(basename -- "$LT_CASE_SCRIPT")"
    cp -- "${_LT_LIB_DIR}/long_term.sh" "$LT_RESULT_ROOT/code/lib/long_term.sh"
    cp -- "$_LT_ANALYZER" "$LT_RESULT_ROOT/code/lib/lt-analyze.py"
    cp -- "$_LT_SLICE_ANALYZER" "$LT_RESULT_ROOT/code/lib/lt-slice-analyze.py"
    if [[ -n "$LT_CEPH_READONLY_WRAPPER" ]]; then cp -- "$LT_CEPH_READONLY_WRAPPER" "$LT_RESULT_ROOT/code/lib/$(basename -- "$LT_CEPH_READONLY_WRAPPER")"; fi
    chmod 0500 "$LT_RESULT_ROOT/code/cases/$(basename -- "$LT_CASE_SCRIPT")" "$LT_RESULT_ROOT/code/lib/long_term.sh" "$LT_RESULT_ROOT/code/lib/lt-analyze.py" "$LT_RESULT_ROOT/code/lib/lt-slice-analyze.py"
    (cd "$LT_RESULT_ROOT" && sha256sum code/cases/* code/lib/* >code.sha256)
}

lt_verify_code_snapshot() {
    [[ -s "$LT_RESULT_ROOT/code.sha256" ]] || lt_die code_checksum_missing
    (cd "$LT_RESULT_ROOT" && sha256sum -c code.sha256 >/dev/null) || lt_die code_snapshot_changed
}

lt_capture_inventory() {
    local pid start exe md5 cmdline
    mkdir -m 0700 -p "$LT_RESULT_ROOT/inventory"
    fio --version >"$LT_RESULT_ROOT/inventory/fio-version.txt"
    "$LT_JFS" version >"$LT_RESULT_ROOT/inventory/juicefs-version.txt" 2>&1
    md5sum "$LT_JFS" >"$LT_RESULT_ROOT/inventory/juicefs.md5"
    findmnt -rn -M "$LT_MOUNT_POINT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$LT_RESULT_ROOT/inventory/findmnt.tsv"
    findmnt -rn -M "$LT_RESULT_MOUNT" -o SOURCE,TARGET,FSTYPE,OPTIONS >"$LT_RESULT_ROOT/inventory/result-findmnt.tsv"
    if [[ -r "$LT_MOUNT_POINT/.config" ]]; then
        python3 - "$LT_MOUNT_POINT/.config" "$LT_EXPECTED_VOLUME_UUID" "$LT_EXPECTED_BLOCK_SIZE_KIB" >"$LT_RESULT_ROOT/inventory/volume-config.json" <<'PY'
import json, sys
doc=json.load(open(sys.argv[1])); s=doc.get("Setting") or doc.get("Format") or doc
out={"Setting":{"Name":s.get("Name"),"UUID":s.get("UUID"),"Storage":s.get("Storage"),"Bucket":s.get("Bucket"),"BlockSize":s.get("BlockSize",s.get("blockSize")),"Compression":s.get("Compression"),"TrashDays":s.get("TrashDays"),"MetaVersion":s.get("MetaVersion")}}
assert out["Setting"]["UUID"] == sys.argv[2] and out["Setting"]["BlockSize"] == int(sys.argv[3])
json.dump(out,sys.stdout,sort_keys=True,indent=2); print()
PY
    else
        "$LT_JFS" status "$LT_META" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("Setting") or d.get("Format") or d; out={"Setting":{k:s.get(k) for k in ("Name","UUID","Storage","Bucket","BlockSize","Compression","TrashDays","MetaVersion")}}; json.dump(out,sys.stdout,sort_keys=True,indent=2); print()' >"$LT_RESULT_ROOT/inventory/volume-config.json"
    fi
    findmnt -rn -M "$LT_MOUNT_POINT" -o OPTIONS >"$LT_RESULT_ROOT/inventory/fuse-options.txt"
    if [[ "$LT_CONFIG_PROFILE" == production-157 ]]; then
        sha256sum -- "$LT_EXPECTED_CEPH_CONF" >"$LT_RESULT_ROOT/inventory/private-ceph-conf.sha256"
    fi
    lt_ceph -s -f json >"$LT_RESULT_ROOT/inventory/ceph-status.json"
    lt_ceph osd dump -f json >"$LT_RESULT_ROOT/inventory/osd-dump.json"
    printf 'host\t%s\nuid\t%s\nkernel\t%s\n' "$(hostname)" "$(id -u)" "$(uname -r)" >"$LT_RESULT_ROOT/inventory/client.tsv"
    printf 'pid\tstarttime\texe_md5\texe\tcmdline\n' >"$LT_RESULT_ROOT/inventory/juicefs-processes.tsv"
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" && -r "/proc/$pid/cmdline" ]] || continue
        start=$(awk '{print $22}' "/proc/$pid/stat"); exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        md5=$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}' || true)
        [[ -n "$md5" ]] || md5=unreadable
        [[ -n "$exe" ]] || exe=unreadable
        cmdline=$(tr '\0\t\n' '   ' <"/proc/$pid/cmdline")
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$start" "$md5" "$exe" "$cmdline" >>"$LT_RESULT_ROOT/inventory/juicefs-processes.tsv"
    done < <(pgrep -f "juicefs.*mount.*${LT_MOUNT_POINT}" || true)
    ps -eo pid,ppid,comm,%cpu,rss,nlwp --no-headers | awk '$3 ~ /^(weka|wekafs|kubelet|containerd)/' >"$LT_RESULT_ROOT/inventory/protected-processes.tsv" || true
}

lt_init_sample_files() {
    local oid prefix
    local -a osd_ids
    IFS=, read -r -a osd_ids <<<"$LT_OSD_IDS"
    mkdir -m 0700 -p "$LT_RESULT_ROOT/samples"
    printf 'epoch\tlabel\thealth\tscrub_pgs\tobjects\tstored\traw_used\tmax_avail' >"$LT_RESULT_ROOT/samples/ceph.tsv"
    for prefix in db_free slow compact data_avail util; do for oid in "${osd_ids[@]}"; do printf '\t%s_%s' "$prefix" "$oid"; done; done >>"$LT_RESULT_ROOT/samples/ceph.tsv"
    printf '\n' >>"$LT_RESULT_ROOT/samples/ceph.tsv"
    printf 'epoch\tlabel\tmem_available_bytes\tresult_free_bytes\tload1\tjuicefs_pid\tjuicefs_rss_bytes\tjuicefs_threads\tjuicefs_fds\n' >"$LT_RESULT_ROOT/samples/client.tsv"
}

lt_expected_file_count() { printf '%s\n' "$LT_JOBS"; }
lt_manifest() {
    local out=$1
    find "$LT_DATA_ROOT" -maxdepth 1 -type f -name 'lt.*.0' -printf '%f\t%i\t%s\n' | sort -V >"$out"
    [[ $(wc -l <"$out") -eq $(lt_expected_file_count) ]] || lt_die dataset_file_count_mismatch
    awk -F '\t' -v n="$LT_FILESIZE" '
      function b(x){return x=="1G"?1073741824:x=="4G"?4294967296:x=="32G"?34359738368:-1}
      $3!=b(n){bad=1} END{exit bad}' "$out" || lt_die dataset_size_mismatch
}

lt_fio_common() {
    local jobs=${1:-$LT_JOBS}
    printf '%s\n' --directory="$LT_DATA_ROOT" --name=lt --filename_format='lt.$jobnum.0' --filesize="$LT_FILESIZE" --size="$LT_SIZE" --numjobs="$jobs" --ioengine="$LT_IOENGINE" --iodepth="$LT_IODEPTH" --direct=1 --fallocate=none --group_reporting --allow_file_create=0 --openfiles="$jobs"
}

lt_prepare() {
    [[ ${LT_PREPARE_ACK:-} == "I_ACK_LT_PREPARE_${LT_RUN_ID}" ]] || lt_die prepare_ack_missing
    if (( LT_DURATION_S > 7200 )) && [[ "$LT_SLO_FROZEN" != 1 ]]; then
        lt_die long_run_requires_frozen_slo
    fi
    if [[ "$LT_CASE_ID" == LT-003 ]] && (( LT_DURATION_S < LT_HOTSET_AFTER_CYCLES*(LT_BURST_S+LT_IDLE_S)+LT_BURST_S )); then
        lt_die duration_too_short_for_cold_set_phase
    fi
    [[ ! -e "$LT_RESULT_ROOT" ]] || lt_die prepare_result_target_exists
    if [[ "$LT_CASE_ID" == LT-004 ]]; then
        [[ -n ${LT_SOURCE_DATA_ROOT:-} && -d "$LT_DATA_ROOT" && ! -L "$LT_DATA_ROOT" ]] || lt_die lt004_source_data_missing
        mkdir -m 0700 -p "$LT_RESULT_ROOT"
    else
        [[ ! -e "$LT_DATA_ROOT" ]] || lt_die prepare_data_target_exists
        mkdir -m 0700 -p "$LT_RESULT_ROOT" "$LT_DATA_ROOT"
    fi
    lt_write_config "$LT_RESULT_ROOT/config.env"
    lt_snapshot_code
    : >"$LT_RESULT_ROOT/commands.sh"; : >"$LT_RESULT_ROOT/incidents.tsv"
    lt_capture_inventory
    lt_init_sample_files
    lt_sample_once prepare-preflight || lt_die prepare_capacity_or_health_guard
    mv -- "$LT_RESULT_ROOT/samples" "$LT_RESULT_ROOT/inventory/preflight-samples"
    if [[ "$LT_CASE_ID" == LT-004 ]]; then
        lt_manifest "$LT_RESULT_ROOT/dataset-prepared.tsv"
    else
        local -a common cmd
        mapfile -t common < <(lt_fio_common)
        cmd=(fio "${common[@]}" --allow_file_create=1 --rw=write --bs=4M --end_fsync=1 --verify=crc32c --verify_interval=256K --do_verify=0 --verify_fatal=1 --output-format=json --output="$LT_RESULT_ROOT/prepare.json")
        if (( LT_PREPARE_RATE_MIB_PER_JOB > 0 )); then cmd+=(--rate=,"${LT_PREPARE_RATE_MIB_PER_JOB}"M); fi
        lt_record "$LT_RESULT_ROOT/commands.sh" "${cmd[@]}"
        "${cmd[@]}" >"$LT_RESULT_ROOT/prepare.stdout" 2>"$LT_RESULT_ROOT/prepare.stderr" || lt_die dataset_prepare_failed
        lt_manifest "$LT_RESULT_ROOT/dataset-prepared.tsv"
    fi
    lt_verify_dataset prepare
    lt_state PREPARED "profile=$LT_PROFILE data=$LT_DATA_ROOT"
    printf 'LT_PREPARE_PASS\tcase=%s\trun=%s\tprofile=%s\n' "$LT_CASE_ID" "$LT_RUN_ID" "$LT_PROFILE"
}

lt_verify_dataset() {
    local label=$1 out="$LT_RESULT_ROOT/verify-${1}"
    local -a common cmd
    [[ ! -e "$out" ]] || lt_die "verify_evidence_exists_${label}"
    mkdir -m 0700 -p "$out"
    mapfile -t common < <(lt_fio_common)
    cmd=(fio "${common[@]}" --rw=read --bs=256K --verify=crc32c --verify_interval=256K --verify_only=1 --verify_fatal=1 --output-format=json --output="$out/fio.json")
    if (( LT_VERIFY_RATE_MIB_PER_JOB > 0 )); then cmd+=(--rate="${LT_VERIFY_RATE_MIB_PER_JOB}"M,); fi
    lt_record "$LT_RESULT_ROOT/commands.sh" "${cmd[@]}"
    set +e; "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr"; local rc=$?; set -e
    printf '%s\n' "$rc" >"$out/fio.rc"
    (( rc == 0 )) || lt_die "integrity_verify_failed_${label}"
    lt_manifest "$out/dataset.tsv"
    cmp -s "$LT_RESULT_ROOT/dataset-prepared.tsv" "$out/dataset.tsv" || lt_die "dataset_identity_changed_${label}"
}

lt_metadata_dump() {
    local label=$1
    [[ "$LT_CASE_ID" != LT-001 ]] || return 0
    local rel=${LT_DATA_ROOT#"$LT_MOUNT_POINT"} out="$LT_RESULT_ROOT/metadata/$label"
    [[ "$rel" == /reliability-lt-data/* ]] || lt_die metadata_dump_scope_invalid
    [[ -d "$LT_DATA_ROOT" && ! -L "$LT_DATA_ROOT" ]] || return 7
    mkdir -m 0700 -p "$out"
    local -a cmd=(timeout --signal=TERM --kill-after=15s 300s nice -n 15 ionice -c 2 -n 7 "$LT_JFS" dump --threads 1 --subdir "$rel" --skip-trash "$LT_META" "$out/meta.json.gz")
    lt_record "$LT_RESULT_ROOT/commands.sh" "${cmd[@]}"
    set +e; (ulimit -f 2097152; "${cmd[@]}") >"$out/dump.stdout" 2>"$out/dump.stderr"; local rc=$?; set -e
    printf '%s\n' "$rc" >"$out/dump.rc"; (( rc == 0 )) || return 7
    python3 "$LT_RESULT_ROOT/code/lib/lt-slice-analyze.py" "$out/meta.json.gz" >"$out/analysis.json" || return 7
}

lt_metadata_checkpoint() {
    local label=$1 rc
    set +e; lt_metadata_dump "$label"; rc=$?; set -e
    if (( rc != 0 )); then
        printf '%s\t%s\trc=%s\n' "$(date -Is)" "$label" "$rc" >>"$LT_RESULT_ROOT/metadata-evidence-gap.tsv"
        lt_state EVIDENCE_GAP "metadata=$label rc=$rc"
        if [[ "$LT_CASE_ID" == LT-004 && "$label" == pre ]]; then lt_die lt004_pre_metadata_required; fi
    fi
}

lt_assert_staging_drained() {
    local metrics epoch values= name value
    metrics=$(curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 "$LT_METRICS_URL") || lt_die drain_metrics_unreachable
    epoch=$(date +%s)
    for name in juicefs_staging_blocks juicefs_staging_block_bytes juicefs_staging_writing_blocks juicefs_object_request_uploading; do
        value=$(awk -v n="$name" '$1==n || index($1,n"{")==1 {sum+=$2; found=1} END{if(found) print sum}' <<<"$metrics")
        [[ -n "$value" ]] || lt_die "drain_metric_missing_${name}"
        values+="${values:+$'\t'}$value"
    done
    printf '%s\t%s\n' "$epoch" "$values" >"$LT_RESULT_ROOT/drain-final.tsv"
    python3 - "$values" <<'PY' || lt_die staging_not_drained
import sys
raise SystemExit(0 if all(float(value) == 0 for value in sys.argv[1].split('\t')) else 7)
PY
}

lt_sample_fail() {
    local tmp=$1 label=$2 attempt=$3 stage=$4
    LT_SAMPLE_LAST_FAILURE=$stage
    printf '%s\tSAMPLE_ATTEMPT_FAILED\tlabel=%s\tattempt=%s\tstage=%s\n' \
        "$(date -Is)" "$label" "$attempt" "$stage" >>"$LT_RESULT_ROOT/incidents.tsv"
    if [[ -n "$tmp" && -d "$tmp" && "$tmp" == "$LT_RESULT_ROOT"/.sample.* ]]; then
        rm -r -- "$tmp"
    fi
    return 7
}

lt_sample_once() {
    local label=${1:-sample} attempt=${2:-1} tmp status pool osddump osddf oid epoch client_mem result_free metrics
    local -a osd_ids
    LT_SAMPLE_LAST_FAILURE=
    IFS=, read -r -a osd_ids <<<"$LT_OSD_IDS"
    [[ -d "$LT_RESULT_ROOT" ]] || return 0
    epoch=$(date +%s)
    tmp=$(mktemp -d "$LT_RESULT_ROOT/.sample.XXXXXX")
    status="$tmp/status.json"; pool="$tmp/pool.json"; osddump="$tmp/osd-dump.json"; osddf="$tmp/osd-df.json"
    lt_ceph -s -f json >"$status" || { lt_sample_fail "$tmp" "$label" "$attempt" ceph_status; return 7; }
    lt_ceph df detail -f json >"$pool" || { lt_sample_fail "$tmp" "$label" "$attempt" ceph_df_detail; return 7; }
    lt_ceph osd dump -f json >"$osddump" || { lt_sample_fail "$tmp" "$label" "$attempt" ceph_osd_dump; return 7; }
    lt_ceph osd df -f json >"$osddf" || { lt_sample_fail "$tmp" "$label" "$attempt" ceph_osd_df; return 7; }
    for oid in "${osd_ids[@]}"; do
        lt_ceph tell "osd.$oid" perf dump >"$tmp/osd-$oid.json" || { lt_sample_fail "$tmp" "$label" "$attempt" "ceph_osd_perf_$oid"; return 7; }
    done
    if ! python3 - "$epoch" "$label" "$status" "$pool" "$osddump" "$osddf" "$tmp" "$LT_CEPH_POOL" "$LT_MIN_CEPH_MAX_AVAIL_TIB" "$LT_MIN_OSD_DB_FREE_GIB" "$LT_OSD_IDS" "$LT_EXPECTED_OSD_COUNT" >"$tmp/ceph-row.tsv" <<'PY'
import json, pathlib, sys
epoch,label,status_path,pool_path,dump_path,df_path,tmp,pool_name,min_tib,min_db,osd_csv,expected_count=sys.argv[1:]
osd_ids=[int(x) for x in osd_csv.split(',')]
if len(osd_ids) != int(expected_count) or len(set(osd_ids)) != len(osd_ids): raise SystemExit(7)
s=json.load(open(status_path)); d=json.load(open(dump_path)); odf=json.load(open(df_path)); pools=json.load(open(pool_path)).get('pools') or []
p=next((x for x in pools if x.get('name')==pool_name),None)
if p is None: raise SystemExit(7)
health=(s.get('health') or {}).get('status'); checks=set(((s.get('health') or {}).get('checks') or {}).keys())
flags=d.get('flags') or []
if isinstance(flags,str): flags=[x for x in flags.split(',') if x]
flags={x.replace('_','-') for x in flags}
if health!='HEALTH_OK' or checks or {'noscrub','nodeep-scrub'} & flags: raise SystemExit(7)
osd=s.get('osdmap') or {}; pg=s.get('pgmap') or {}
if osd.get('num_up_osds')!=len(osd_ids) or osd.get('num_in_osds')!=len(osd_ids): raise SystemExit(7)
states=pg.get('pgs_by_state') or []
if not states: raise SystemExit(7)
scrub_pgs=0
for item in states:
    parts=set((item.get('state_name') or '').split('+'))
    if not {'active','clean'} <= parts or parts-{'active','clean','scrubbing','deep'}:
        raise SystemExit(7)
    if 'scrubbing' in parts:
        scrub_pgs += int(item.get('count') or 0)
st=p.get('stats') or {}; max_avail=st.get('max_avail',0); objects=st.get('objects',0); stored=st.get('stored',st.get('stored_data',0)); raw=st.get('bytes_used',0)
if max_avail < float(min_tib)*1024**4: raise SystemExit(7)
nodes={int(x['id']):x for x in (odf.get('nodes') or [])}
if not set(osd_ids).issubset(nodes): raise SystemExit(7)
db=[]; slow=[]; compact=[]; data_avail=[]; util=[]
for oid in osd_ids:
    perf=json.load(open(pathlib.Path(tmp)/f'osd-{oid}.json')); blue=perf.get('bluefs') or {}; rocks=perf.get('rocksdb') or {}
    free=blue.get('db_total_bytes',0)-blue.get('db_used_bytes',0); sl=blue.get('slow_used_bytes',0)
    if free < float(min_db)*1024**3 or sl != 0: raise SystemExit(7)
    avail=nodes[oid].get('kb_avail'); use=nodes[oid].get('utilization')
    if not isinstance(avail,(int,float)) or not isinstance(use,(int,float)): raise SystemExit(7)
    db.append(str(int(free))); slow.append(str(int(sl))); compact.append(f"{rocks.get('compact_running','NA')}:{rocks.get('compact_queue_len','NA')}")
    data_avail.append(str(int(avail)*1024)); util.append(str(float(use)))
print('\t'.join(map(str,[epoch,label,health,scrub_pgs,objects,stored,raw,max_avail,*db,*slow,*compact,*data_avail,*util])))
PY
    then lt_sample_fail "$tmp" "$label" "$attempt" ceph_health_capacity_guard; return 7; fi
    client_mem=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)
    result_free=$(df -B1 --output=avail "$LT_RESULT_ROOT" | awk 'NR==2{print $1}')
    if ! python3 - "$client_mem" "$result_free" "$LT_MIN_CLIENT_MEM_GIB" "$LT_MIN_RESULT_FREE_GIB" <<'PY'
import sys
mem, free, min_mem, min_free = map(float, sys.argv[1:])
raise SystemExit(0 if mem >= min_mem * 1024**3 and free >= min_free * 1024**3 else 7)
PY
    then lt_sample_fail "$tmp" "$label" "$attempt" client_capacity_guard; return 7; fi
    local jpid=0 jrss=0 jthreads=0 jfds=NA
    jpid=$(pgrep -af "juicefs.*mount.*${LT_MOUNT_POINT}" | awk 'NR==1{print $1}' || true)
    if [[ "$jpid" =~ ^[0-9]+$ && -r /proc/$jpid/status ]]; then
        jrss=$(awk '/^VmRSS:/{print $2*1024}' "/proc/$jpid/status"); jthreads=$(awk '/^Threads:/{print $2}' "/proc/$jpid/status")
        if [[ -r "/proc/$jpid/fd" ]]; then jfds=$(find "/proc/$jpid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l || true); fi
        jrss=${jrss:-0}; jthreads=${jthreads:-0}; jfds=${jfds:-NA}
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$label" "$client_mem" "$result_free" "$(awk '{print $1}' /proc/loadavg)" "$jpid" "$jrss" "$jthreads" "$jfds" >"$tmp/client-row.tsv"
    metrics=$(curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 "$LT_METRICS_URL" 2>/dev/null) || { lt_sample_fail "$tmp" "$label" "$attempt" juicefs_metrics_fetch; return 7; }
    grep -q '^juicefs_process_cpu_seconds_total' <<<"$metrics" || { lt_sample_fail "$tmp" "$label" "$attempt" juicefs_metrics_identity; return 7; }
    grep -E '^(juicefs_(staging|blockcache|object_request_uploading|process_cpu|used_buffer|used_read_buffer|fuse_open_handlers))' <<<"$metrics" | awk -v e="$epoch" '{print e"\t"$0}' >"$tmp/juicefs.prom.tsv" || { lt_sample_fail "$tmp" "$label" "$attempt" juicefs_metrics_filter; return 7; }
    ps -eo pid,ppid,comm,%cpu,rss,nlwp --no-headers | awk -v e="$epoch" '$3 ~ /^(weka|wekafs|kubelet|containerd)/ {print e"\t"$0}' >"$tmp/protected-processes.tsv" || { lt_sample_fail "$tmp" "$label" "$attempt" protected_processes; return 7; }
    local node
    IFS=, read -r -a _lt_nodes <<<"$LT_STORAGE_NODES"
    for node in "${_lt_nodes[@]}"; do
        curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 "http://${node}:20180/metrics" 2>/dev/null | grep -E '^(tikv_engine_(size_bytes|pending_compaction_bytes)|tikv_storage_engine_async_request_duration_seconds|tikv_scheduler_command_duration_seconds)' | awk -v e="$epoch" -v n="$node" '{print e"\t"n"\t"$0}' >>"$tmp/tikv.prom.tsv" || { lt_sample_fail "$tmp" "$label" "$attempt" "tikv_metrics_$node"; return 7; }
        { printf 'BEGIN\t%s\t%s\n' "$epoch" "$node"; lt_storage_ssh "$node" "awk '/^MemAvailable:/{print}' /proc/meminfo; head -1 /proc/stat; cat /proc/pressure/cpu /proc/pressure/io; if command -v iostat >/dev/null; then iostat -y -x -d 1 1 $LT_STORAGE_IOSTAT_DEVICES; else for dev in $LT_STORAGE_IOSTAT_DEVICES; do printf 'diskstat %s ' \"\$dev\"; cat \"/sys/class/block/\$dev/stat\"; done; fi"; printf 'END\t%s\t%s\n' "$epoch" "$node"; } >>"$tmp/storage-hosts.log" || { lt_sample_fail "$tmp" "$label" "$attempt" "storage_host_$node"; return 7; }
    done
    cat "$tmp/ceph-row.tsv" >>"$LT_RESULT_ROOT/samples/ceph.tsv"
    cat "$tmp/client-row.tsv" >>"$LT_RESULT_ROOT/samples/client.tsv"
    cat "$tmp/juicefs.prom.tsv" >>"$LT_RESULT_ROOT/samples/juicefs.prom.tsv"
    cat "$tmp/protected-processes.tsv" >>"$LT_RESULT_ROOT/samples/protected-processes.tsv"
    cat "$tmp/tikv.prom.tsv" >>"$LT_RESULT_ROOT/samples/tikv.prom.tsv"
    cat "$tmp/storage-hosts.log" >>"$LT_RESULT_ROOT/samples/storage-hosts.log"
    rm -r -- "$tmp"
}

lt_sampler() {
    local fio_pid_file=$1 label first_failure final_failure
    while [[ ! -e "$LT_RESULT_ROOT/controller.done" ]]; do
        label=idle
        [[ -s "$fio_pid_file" ]] && label=load
        if ! lt_sample_once "$label" 1; then
            first_failure=${LT_SAMPLE_LAST_FAILURE:-unknown}
            sleep 5
            if ! lt_sample_once "$label-retry" 2; then
                final_failure=${LT_SAMPLE_LAST_FAILURE:-unknown}
                printf '%s\tSAMPLE_GUARD_PERSISTENT\tfirst=%s\tfinal=%s\n' \
                    "$(date -Is)" "$first_failure" "$final_failure" >"$LT_RESULT_ROOT/STOP.txt"
                return 7
            fi
            printf '%s\tSAMPLE_RETRY_RECOVERED\tfirst=%s\n' \
                "$(date -Is)" "$first_failure" >>"$LT_RESULT_ROOT/incidents.tsv"
        fi
        sleep "$LT_SAMPLE_INTERVAL_S"
    done
}

lt_run_window() {
    local idx=$1 runtime=$2 jobs=${3:-$LT_JOBS} out="$LT_RESULT_ROOT/windows/$(printf '%04d' "$idx")"
    mkdir -m 0700 -p "$out/bw" "$out/lat"
    local -a common cmd extra=()
    mapfile -t common < <(lt_fio_common "$jobs")
    if [[ "$LT_RW" == write || "$LT_RW" == randwrite || "$LT_RW" == randrw ]]; then
        extra=(--verify=crc32c --verify_interval=256K --do_verify=0 --verify_fatal=1)
    else
        extra=(--readonly)
    fi
    cmd=(fio "${common[@]}" --rw="$LT_RW" --bs="$LT_BS" --time_based --runtime="$runtime" --randrepeat=1 --refill_buffers --lat_percentiles=1 --percentile_list=95:99 --per_job_logs=1 --write_bw_log="$out/bw/fio" --write_lat_log="$out/lat/fio" --log_avg_msec=1000 --output-format=json --output="$out/fio.json" "${extra[@]}")
    if (( LT_RATE_READ_MIB_PER_JOB > 0 || LT_RATE_WRITE_MIB_PER_JOB > 0 )); then
        local read_rate= write_rate=
        if (( LT_RATE_READ_MIB_PER_JOB > 0 )); then read_rate="${LT_RATE_READ_MIB_PER_JOB}M"; fi
        if (( LT_RATE_WRITE_MIB_PER_JOB > 0 )); then write_rate="${LT_RATE_WRITE_MIB_PER_JOB}M"; fi
        cmd+=(--rate="${read_rate},${write_rate}")
    fi
    lt_record "$LT_RESULT_ROOT/commands.sh" "${cmd[@]}"
    date +%s%N >"$out/start-epoch-ns.txt"
    set +e; "${cmd[@]}" >"$out/fio.stdout" 2>"$out/fio.stderr" & LT_ACTIVE_FIO_PID=$!; set -e
    LT_ACTIVE_FIO_START=$(awk '{print $22}' "/proc/$LT_ACTIVE_FIO_PID/stat")
    printf '%s\t%s\n' "$LT_ACTIVE_FIO_PID" "$LT_ACTIVE_FIO_START" >"$LT_RESULT_ROOT/active-fio.tsv"
    local maintenance_pid=0
    if [[ "$LT_CASE_ID" == LT-004 && "$idx" -eq 1 ]]; then
        lt_compact_worker & maintenance_pid=$!; LT_MAINTENANCE_WORKER_PID=$maintenance_pid
    fi
    while kill -0 "$LT_ACTIVE_FIO_PID" 2>/dev/null; do
        if [[ -e "$LT_RESULT_ROOT/STOP.txt" || -e "$LT_RESULT_ROOT/operator-stop.request" ]]; then kill -TERM "$LT_ACTIVE_FIO_PID" 2>/dev/null || true; fi
        sleep 5
    done
    set +e; wait "$LT_ACTIVE_FIO_PID"; local rc=$?; set -e
    printf '%s\n' "$rc" >"$out/fio.rc"; date +%s%N >"$out/end-epoch-ns.txt"
    LT_ACTIVE_FIO_PID=; LT_ACTIVE_FIO_START=; : >"$LT_RESULT_ROOT/active-fio.tsv"
    if (( maintenance_pid > 0 )); then
        set +e; wait "$maintenance_pid"; local mrc=$?; set -e
        LT_MAINTENANCE_WORKER_PID=
        (( mrc == 0 )) || lt_die maintenance_failed
    fi
    (( rc == 0 )) || lt_die "fio_window_${idx}_failed_rc_${rc}"
}

lt_compact_worker() {
    sleep "$LT_COMPACT_OFFSET_S"
    [[ ${LT_MAINTENANCE_ACK:-} == "I_ACK_LT004_COMPACT_${LT_RUN_ID}" ]] || return 42
    local out="$LT_RESULT_ROOT/maintenance" n=0 file inode size
    mkdir -m 0700 -p "$out"; : >"$out/runtime.tsv"
    while IFS=$'\t' read -r file inode size; do
        (( n < LT_COMPACT_LIMIT )) || break
        local path="$LT_DATA_ROOT/$file" start end rc pid pid_start
        [[ -f "$path" && ! -L "$path" && $(stat -c %i "$path") == "$inode" && $(stat -c %s "$path") == "$size" ]] || return 42
        lt_record "$LT_RESULT_ROOT/commands.sh" timeout 3600 "$LT_JFS" compact --threads 1 "$path"
        start=$(date +%s%N)
        set +e
        timeout 3600 "$LT_JFS" compact --threads 1 "$path" >"$out/compact-$(printf '%03d' "$n").log" 2>&1 & pid=$!
        set -e
        pid_start=$(awk '{print $22}' "/proc/$pid/stat")
        printf '%s\t%s\n' "$pid" "$pid_start" >"$LT_RESULT_ROOT/maintenance-active.tsv"
        set +e; wait "$pid"; rc=$?; set -e
        : >"$LT_RESULT_ROOT/maintenance-active.tsv"
        end=$(date +%s%N)
        printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$file" "$start" "$end" "$rc" >>"$out/runtime.tsv"
        (( rc == 0 )) || return "$rc"
        n=$((n+1))
    done <"$LT_RESULT_ROOT/dataset-prepared.tsv"
    (( n > 0 )) || return 42
}

lt_execute_continuous() {
    local elapsed=0 idx=0 span
    lt_metadata_checkpoint pre
    while (( elapsed < LT_DURATION_S )); do
        span=$LT_WINDOW_S; (( elapsed + span > LT_DURATION_S )) && span=$((LT_DURATION_S-elapsed))
        idx=$((idx+1)); lt_run_window "$idx" "$span"; elapsed=$((elapsed+span))
        [[ ! -e "$LT_RESULT_ROOT/STOP.txt" && ! -e "$LT_RESULT_ROOT/operator-stop.request" ]] || break
        (( idx % LT_METADATA_DUMP_EVERY_WINDOWS != 0 )) || lt_metadata_checkpoint "window-$(printf '%04d' "$idx")"
    done
}

lt_execute_cycles() {
    local elapsed=0 idx=0 span idle_start jobs phase cold_files
    lt_metadata_checkpoint pre
    while (( elapsed < LT_DURATION_S )); do
        span=$LT_BURST_S; (( elapsed + span > LT_DURATION_S )) && span=$((LT_DURATION_S-elapsed))
        idx=$((idx+1))
        if (( idx <= LT_HOTSET_AFTER_CYCLES )); then
            jobs=$LT_JOBS; phase=full-set; cold_files=0
        else
            jobs=$((LT_JOBS/2)); phase=hot-half; cold_files=$((LT_JOBS-jobs))
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$(date +%s)" "$phase" "$jobs" "$cold_files" >>"$LT_RESULT_ROOT/window-contract.tsv"
        lt_run_window "$idx" "$span" "$jobs"; elapsed=$((elapsed+span))
        [[ ! -e "$LT_RESULT_ROOT/STOP.txt" && ! -e "$LT_RESULT_ROOT/operator-stop.request" ]] || break
        (( elapsed >= LT_DURATION_S )) && break
        span=$LT_IDLE_S; (( elapsed + span > LT_DURATION_S )) && span=$((LT_DURATION_S-elapsed)); idle_start=$(date +%s)
        printf '%s\t%s\t%s\n' "$idx" "$idle_start" "$span" >>"$LT_RESULT_ROOT/idle-windows.tsv"
        while (( $(date +%s) - idle_start < span )); do [[ ! -e "$LT_RESULT_ROOT/STOP.txt" && ! -e "$LT_RESULT_ROOT/operator-stop.request" ]] || break 2; sleep 5; done
        elapsed=$((elapsed+span))
        (( idx % LT_METADATA_DUMP_EVERY_WINDOWS != 0 )) || lt_metadata_checkpoint "cycle-$(printf '%04d' "$idx")-idle"
    done
}

lt_on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [[ ${LT_ACTIVE_FIO_PID:-} =~ ^[0-9]+$ && -r /proc/$LT_ACTIVE_FIO_PID/stat ]]; then
        [[ $(awk '{print $22}' "/proc/$LT_ACTIVE_FIO_PID/stat") == "${LT_ACTIVE_FIO_START:-}" ]] && kill -TERM "$LT_ACTIVE_FIO_PID" 2>/dev/null || true
        wait "$LT_ACTIVE_FIO_PID" 2>/dev/null || true
    fi
    if [[ -s "$LT_RESULT_ROOT/maintenance-active.tsv" ]]; then
        local maintenance_pid maintenance_start maintenance_now
        read -r maintenance_pid maintenance_start <"$LT_RESULT_ROOT/maintenance-active.tsv"
        maintenance_now=$(awk '{print $22}' "/proc/$maintenance_pid/stat" 2>/dev/null || true)
        [[ "$maintenance_now" == "$maintenance_start" ]] && kill -TERM "$maintenance_pid" 2>/dev/null || true
    fi
    if [[ ${LT_MAINTENANCE_WORKER_PID:-} =~ ^[0-9]+$ ]]; then
        kill -TERM "$LT_MAINTENANCE_WORKER_PID" 2>/dev/null || true
        wait "$LT_MAINTENANCE_WORKER_PID" 2>/dev/null || true
    fi
    if [[ ${LT_SAMPLER_PID:-} =~ ^[0-9]+$ ]]; then
        kill "$LT_SAMPLER_PID" 2>/dev/null || true
        wait "$LT_SAMPLER_PID" 2>/dev/null || true
    fi
    printf '%s\n' "$(date -Is)" >"$LT_RESULT_ROOT/controller.done"
    (( rc == 0 )) || lt_state FAILED "rc=$rc"
    (cd "$LT_RESULT_ROOT" && find . -type f ! -name manifest.sha256 ! -name controller-live.log -print0 | sort -z | xargs -0 sha256sum) >"$LT_RESULT_ROOT/manifest.sha256"
    exit "$rc"
}

lt_execute() {
    trap lt_on_exit EXIT INT TERM
    lt_verify_config_snapshot
    lt_verify_code_snapshot
    mkdir -m 0700 -p "$LT_RESULT_ROOT/windows"
    [[ ! -e "$LT_RESULT_ROOT/samples" ]] || lt_die execute_samples_already_exist
    lt_init_sample_files
    if [[ "$LT_CASE_ID" == LT-003 ]]; then printf 'window\tepoch\tphase\tactive_jobs\tcold_files\n' >"$LT_RESULT_ROOT/window-contract.tsv"; fi
    lt_preflight execute
    lt_state RUNNING "pid=$$"
    lt_sampler "$LT_RESULT_ROOT/active-fio.tsv" & LT_SAMPLER_PID=$!
    if [[ "$LT_CASE_ID" == LT-003 ]]; then lt_execute_cycles; else lt_execute_continuous; fi
    [[ ! -e "$LT_RESULT_ROOT/STOP.txt" && ! -e "$LT_RESULT_ROOT/operator-stop.request" ]] || lt_die stopped_by_guard_or_operator
    if [[ "$LT_RW" == write || "$LT_RW" == randwrite || "$LT_RW" == randrw ]]; then
        lt_state DRAINING "seconds=$LT_DRAIN_S"; sleep "$LT_DRAIN_S"
    fi
    [[ ! -e "$LT_RESULT_ROOT/STOP.txt" && ! -e "$LT_RESULT_ROOT/operator-stop.request" ]] || lt_die stopped_during_drain
    if [[ "$LT_RW" == write || "$LT_RW" == randwrite || "$LT_RW" == randrw ]]; then lt_assert_staging_drained; fi
    lt_verify_dataset final
    lt_metadata_checkpoint final
    [[ ! -e "$LT_RESULT_ROOT/STOP.txt" && ! -e "$LT_RESULT_ROOT/operator-stop.request" ]] || lt_die stopped_during_verify
    : >"$LT_RESULT_ROOT/controller.done"; kill "$LT_SAMPLER_PID" 2>/dev/null || true; wait "$LT_SAMPLER_PID" 2>/dev/null || true; LT_SAMPLER_PID=
    lt_verify_code_snapshot
    lt_verify_config_snapshot
    python3 "$LT_RESULT_ROOT/code/lib/lt-analyze.py" "$LT_RESULT_ROOT"
    lt_verify_config_snapshot
    lt_verify_code_snapshot
    lt_state COMPLETE "profile=$LT_PROFILE"
    (cd "$LT_RESULT_ROOT" && find . -type f ! -name manifest.sha256 ! -name controller-live.log -print0 | sort -z | xargs -0 sha256sum) >"$LT_RESULT_ROOT/manifest.sha256"
    trap - EXIT INT TERM
    printf 'LT_EXECUTE_PASS\tcase=%s\trun=%s\n' "$LT_CASE_ID" "$LT_RUN_ID"
}

lt_start() {
    [[ ${LT_EXECUTE_ACK:-} == "I_ACK_${LT_CASE_ID//-/_}_${LT_RUN_ID}" ]] || lt_die execute_ack_missing
    [[ -f "$LT_RESULT_ROOT/config.env" && -f "$LT_RESULT_ROOT/dataset-prepared.tsv" ]] || lt_die run_not_prepared
    [[ $(tail -n 1 "$LT_RESULT_ROOT/run-state.tsv" | cut -f2) == PREPARED ]] || lt_die run_state_not_prepared
    mkdir -m 0700 "$LT_RESULT_ROOT/.start-once-lock" 2>/dev/null || lt_die run_id_already_started
    lt_state START_ATTEMPTED "pid=$$"
    [[ ! -e "$LT_RESULT_ROOT/controller.pid" ]] || lt_die controller_state_exists
    lt_verify_config_snapshot
    local execute_ack=$LT_EXECUTE_ACK maintenance_ack=${LT_MAINTENANCE_ACK:-}
    # shellcheck disable=SC1090
    source "$LT_RESULT_ROOT/config.env"
    LT_EXECUTE_ACK=$execute_ack; LT_MAINTENANCE_ACK=$maintenance_ack
    lt_profile_contract; lt_safe_paths
    lt_verify_code_snapshot
    lt_verify_config_snapshot
    lt_preflight plan
    local copied="$LT_RESULT_ROOT/code/cases/$(basename -- "$LT_CASE_SCRIPT")"
    nohup env "LT_MAINTENANCE_ACK=${LT_MAINTENANCE_ACK:-}" bash "$copied" _execute "$LT_RESULT_ROOT/config.env" >"$LT_RESULT_ROOT/controller-live.log" 2>&1 </dev/null &
    local pid=$! start
    start=$(awk '{print $22}' "/proc/$pid/stat")
    printf '%s\t%s\n' "$pid" "$start" >"$LT_RESULT_ROOT/controller.pid"
    lt_state STARTED "pid=$pid starttime=$start"
    printf 'LT_START_PASS\tcase=%s\trun=%s\tpid=%s\n' "$LT_CASE_ID" "$LT_RUN_ID" "$pid"
}

lt_status() {
    [[ -d "$LT_RESULT_ROOT" ]] || lt_die run_not_found
    tail -n 20 "$LT_RESULT_ROOT/run-state.tsv" 2>/dev/null || true
    if [[ -s "$LT_RESULT_ROOT/controller.pid" ]]; then
        local pid start now; read -r pid start <"$LT_RESULT_ROOT/controller.pid"; now=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
        [[ "$now" == "$start" ]] && printf 'controller\tRUNNING\tpid=%s\n' "$pid" || printf 'controller\tSTOPPED\tpid=%s\n' "$pid"
    fi
    [[ -e "$LT_RESULT_ROOT/STOP.txt" ]] && cat "$LT_RESULT_ROOT/STOP.txt"
}

lt_stop() {
    [[ ${LT_STOP_ACK:-} == "I_ACK_LT_STOP_${LT_RUN_ID}" ]] || lt_die stop_ack_missing
    [[ -s "$LT_RESULT_ROOT/controller.pid" ]] || lt_die controller_pid_missing
    local pid start now; read -r pid start <"$LT_RESULT_ROOT/controller.pid"; now=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
    [[ "$now" == "$start" ]] || lt_die controller_identity_mismatch
    : >"$LT_RESULT_ROOT/operator-stop.request"
    lt_state STOP_REQUESTED "pid=$pid"
    printf 'LT_STOP_REQUESTED\tpid=%s\n' "$pid"
}

lt_plan() {
    lt_preflight plan
    cat <<EOF
case=$LT_CASE_ID
run_id=$LT_RUN_ID
profile=$LT_PROFILE
duration_s=$LT_DURATION_S
window_s=$LT_WINDOW_S
sample_interval_s=$LT_SAMPLE_INTERVAL_S
per_job_rate_caps_mib_s=read:$LT_RATE_READ_MIB_PER_JOB write:$LT_RATE_WRITE_MIB_PER_JOB prepare_write:$LT_PREPARE_RATE_MIB_PER_JOB verify_read:$LT_VERIFY_RATE_MIB_PER_JOB
data_root=$LT_DATA_ROOT
remote_result_root=$LT_RESULT_ROOT
persistent_copy=/mnt/c/SunRise/test/reliability/$LT_RUN_ID/$LT_CASE_ID
fio=rw:$LT_RW bs:$LT_BS jobs:$LT_JOBS qd:$LT_IODEPTH filesize:$LT_FILESIZE
guards=client_mem:${LT_MIN_CLIENT_MEM_GIB}GiB result_free:${LT_MIN_RESULT_FREE_GIB}GiB ceph_max_avail:${LT_MIN_CEPH_MAX_AVAIL_TIB}TiB per_osd_db_free:${LT_MIN_OSD_DB_FREE_GIB}GiB
stability_gates=window_bw>=${LT_MIN_WINDOW_RATIO_PCT}%_of_first p99<=${LT_MAX_P99_RATIO}x_first max_gap<=${LT_MAX_WINDOW_GAP_S}s
slo_frozen=$LT_SLO_FROZEN absolute_read_mib_s=$LT_MIN_READ_BW_MIB absolute_write_mib_s=$LT_MIN_WRITE_BW_MIB absolute_p99_us=$LT_MAX_P99_US
manual_actions=none
automatic_cleanup=none
EOF
}

lt_case_main() {
    LT_CASE_ID=$1; shift
    local action=${1:-plan}; shift || true
    if [[ "$action" == _execute ]]; then
        local cfg=${1:-}; [[ -f "$cfg" && ! -L "$cfg" ]] || lt_die execute_config_invalid
        LT_RESULT_ROOT=$(dirname -- "$cfg")
        lt_verify_config_snapshot
        # shellcheck disable=SC1090
        source "$cfg"; lt_verify_config_snapshot; lt_profile_contract; lt_safe_paths; lt_execute; return
    fi
    local run=${1:-} profile=${2:-}
    [[ -n "$run" && -n "$profile" ]] || lt_die "usage: $(basename "$LT_CASE_SCRIPT") {plan|prepare|start|status|stop|verify} RUN_ID PROFILE"
    lt_defaults "$run" "$profile"
    case "$action" in
        plan) lt_plan ;;
        prepare) lt_preflight plan; lt_prepare ;;
        start) lt_start ;;
        status) lt_status ;;
        stop) lt_stop ;;
        verify)
            [[ -f "$LT_RESULT_ROOT/config.env" ]] || lt_die run_not_found
            lt_verify_config_snapshot
            # shellcheck disable=SC1090
            source "$LT_RESULT_ROOT/config.env"
            lt_verify_config_snapshot; lt_profile_contract; lt_safe_paths
            lt_verify_dataset "manual-$(date +%Y%m%d-%H%M%S)"
            ;;
        *) lt_die unknown_action ;;
    esac
}
