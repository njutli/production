#!/bin/bash
# lib/io_load.sh — I/O 负载生成
#
# 在客户端 157 上通过 ssh_to_client 运行 fio，对 JuiceFS 挂载点加压。
# 后台运行（--time_based --runtime=999999），stop 时发 SIGINT 收集 JSON 结果。

# Auto-load config if not already loaded
if [ -z "${RELIABILITY_CONFIG_LOADED:-}" ]; then
    _io_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_io_dir}/../config/env.sh"
fi

# Global state
_IO_FIO_PID=""
_IO_FIO_TYPE=""
_IO_FIO_RESULT="/tmp/reliability-fio-result.json"
_IO_FIO_BASELINE="/tmp/reliability-fio-baseline.json"
_IO_FIO_JSON=""
_IO_BASELINE_BW=0
_IO_BASELINE_P99=0

_TEST_DIR="${JUICEFS_MOUNT_POINT}/reliability-test"
_FILESIZE="${IO_LOAD_FILESIZE:-64M}"


# ============================================================
# start_io_load <type> <bs> <jobs>
#   type: randread / randwrite / randrw / seqread / seqwrite
#   bs: block size (e.g. 256k, 4M)
#   jobs: number of jobs (e.g. 1, 16, 128)
# ============================================================
start_io_load() {
    local type=$1 bs=$2 jobs=$3
    local rw ioengine iodepth

    case "$type" in
        randread)  rw=randread  ;;
        randwrite) rw=randwrite ;;
        randrw)    rw=randrw    ;;
        seqread)   rw=read      ;;
        seqwrite)  rw=write     ;;
        *) echo "ERROR: unknown io type '$type'" >&2; return 1 ;;
    esac

    if [ "$jobs" = 1 ]; then
        ioengine=psync
        iodepth=1
    else
        ioengine=libaio
        iodepth=128
    fi

    _IO_FIO_TYPE="$type"

    # 1) Create test directory
    ssh_to_client "mkdir -p '${_TEST_DIR}'" 2>/dev/null

    # 2) For read tests: pre-create files (one quick write run)
    # 注意：prep 的 --name 必须和主 fio 一致，否则主 fio 找不到预创建的文件
    if [[ "$rw" =~ read ]]; then
        echo "  prep: creating ${jobs} × ${_FILESIZE} files on ${JUICEFS_CLIENT}..."
        ssh_to_client "fio \
            --directory='${_TEST_DIR}' \
            --name=io_load \
            --rw=write \
            --bs=4M \
            --filesize=${_FILESIZE} \
            --size=${_FILESIZE} \
            --numjobs=${jobs} \
            --fallocate=none \
            --direct=1 \
            --ioengine=libaio \
            --iodepth=${iodepth} \
            --output-format=terse \
            > /dev/null 2>&1" 2>/dev/null || true
        echo "  prep: done"
    fi

    # 3) Start fio in background (nohup to survive SSH session close)
    local create_opt=""
    [[ "$rw" =~ read ]] || create_opt="--create_on_open=1"
    local openfiles=$jobs
    [ "$jobs" = 1 ] && openfiles=1

    ssh_to_client "nohup fio \
        --directory='${_TEST_DIR}' \
        --name=io_load \
        --rw=${rw} \
        --bs=${bs} \
        --ioengine=${ioengine} \
        --iodepth=${iodepth} \
        --numjobs=${jobs} \
        --direct=1 \
        --fallocate=none \
        ${create_opt} \
        --openfiles=${openfiles} \
        --filesize=${_FILESIZE} \
        --size=${_FILESIZE} \
        --group_reporting \
        --time_based \
        --runtime=999999 \
        --output-format=json \
        --output=${_IO_FIO_RESULT} \
        > /dev/null 2>&1 &" 2>/dev/null

    # 4) Get fio PID
    sleep 1
    _IO_FIO_PID=$(ssh_to_client "pgrep -f 'fio.*io_load' | head -1" 2>/dev/null)

    if [ -n "$_IO_FIO_PID" ]; then
        echo "fio started: type=${type} bs=${bs} jobs=${jobs} pid=${_IO_FIO_PID}"
    else
        echo "WARNING: fio PID not found, I/O load may not have started"
    fi
}


# ============================================================
# stop_io_load — 停止 fio + 采集结果
# 发 SIGINT 让 fio 正常退出并写 JSON 输出
# ============================================================
stop_io_load() {
    if [ -z "$_IO_FIO_PID" ]; then
        echo "stop_io_load: no fio running"
        return 0
    fi

    # Try SIGINT first (fio handles it, writes output)
    ssh_to_client "kill -INT ${_IO_FIO_PID} 2>/dev/null" 2>/dev/null

    # Wait up to 10s for fio to exit
    local waited=0
    while [ "$waited" -lt 10 ]; do
        local still_running
        still_running=$(ssh_to_client "kill -0 ${_IO_FIO_PID} 2>/dev/null && echo yes || echo no" 2>/dev/null)
        [ "$still_running" = "no" ] && break
        sleep 1
        waited=$((waited + 1))
    done

    # If still running, SIGKILL (no output will be available)
    if [ "$waited" = 10 ]; then
        ssh_to_client "kill -KILL ${_IO_FIO_PID} 2>/dev/null" 2>/dev/null
        echo "WARNING: fio did not respond to SIGINT in 10s, sent SIGKILL"
    fi

    # Read JSON result (sed 跳过 fio 写的非 JSON 前缀行，如 "fio: terminating on signal 2")
    _IO_FIO_JSON=$(ssh_to_client "sed -n '/^{/,\$p' ${_IO_FIO_RESULT} 2>/dev/null" 2>/dev/null)

    # 保存到本地文件，供 run.sh 收集 artifacts
    echo "$_IO_FIO_JSON" > /tmp/reliability-fio-result.json 2>/dev/null || true

    if [ -n "$_IO_FIO_JSON" ]; then
        echo "fio stopped, results collected"
    else
        echo "WARNING: no fio output found (I/O may have been hung during kill)"
        _IO_FIO_JSON=""
    fi

    _IO_FIO_PID=""

    # Clean up test files
    # 注意：glob * 不能在单引号内，否则远程 shell 不展开
    # timeout 15 防止 JuiceFS 元数据不可用时 rm 挂起
    timeout 15 ssh_to_client "cd '${_TEST_DIR}' && rm -f io_load.* prep.* baseline_prep.*" 2>/dev/null || true
    echo "  cleanup: test files removed"
}


# ============================================================
# 结果查询函数
# ============================================================

# → 0-100 (成功率百分比)
get_io_success_rate() {
    [ -z "$_IO_FIO_JSON" ] && { echo 0; return; }
    local total errs
    total=$(echo "$_IO_FIO_JSON" | jq -r '
        (.jobs[0].read.total_ios // 0) +
        (.jobs[0].write.total_ios // 0)' 2>/dev/null)
    errs=$(echo "$_IO_FIO_JSON" | jq -r '.jobs[0].total_io_errors // 0' 2>/dev/null)
    if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
        echo $(( (total - errs) * 100 / total ))
    else
        echo 0
    fi
}

# → 微秒 (P99 延迟)
get_io_lat_p99() {
    [ -z "$_IO_FIO_JSON" ] && { echo 0; return; }
    # fio clat_ns 报告纳秒，转为微秒（/1000）
    local ns
    ns=$(echo "$_IO_FIO_JSON" | jq -r '
        (.jobs[0].read.clat_ns.percentile["99.000000"] //
         .jobs[0].write.clat_ns.percentile["99.000000"] //
         .jobs[0].read.lat_ns.percentile["99.000000"] //
         .jobs[0].write.lat_ns.percentile["99.000000"] //
         0)' 2>/dev/null)
    echo $(( ns / 1000 ))
}

# → 微秒 (最大完成延迟)
# 检测故障期间是否有单个 IO 被长时间阻塞（P99 可能漏检少量阻塞）
get_io_lat_max() {
    [ -z "$_IO_FIO_JSON" ] && { echo 0; return; }
    local ns
    ns=$(echo "$_IO_FIO_JSON" | jq -r '
        ([
          (.jobs[0].read.clat_ns.max // 0),
          (.jobs[0].write.clat_ns.max // 0)
        ] | max)' 2>/dev/null)
    echo $(( ns / 1000 ))
}

# → MiB/s (带宽)
get_io_bw() {
    [ -z "$_IO_FIO_JSON" ] && { echo 0; return; }
    local kib
    kib=$(echo "$_IO_FIO_JSON" | jq -r '
        (.jobs[0].read.bw //
         .jobs[0].write.bw //
         0)' 2>/dev/null)
    echo $(( kib / 1024 ))
}


# ============================================================
# capture_io_baseline — 采集故障前基线
# 运行 10s 短测试，记录基线 BW 和 P99
# read 测试前先创建文件（与 start_io_load 的 prep 独立，用 --name=baseline_prep 文件）
#
# 缓存影响说明：
#   read：--cache-size 0 + --direct=1 绕过客户端缓存，BlueStore 元数据缓存可能未完全热
#         → 基线偏低（保守方向，阈值偏低，更容易通过）
#   write：BlueStore WAL 在 tmpfs 上，10s 内写缓冲未填满，BW 反映缓冲吸收速度非持久化速度
#         → 基线虚高（过严方向，阈值虚高，更难通过）
#   当前所有用例均为 randread，write 场景如需添加应将基线时间增至 30s+
# ============================================================
capture_io_baseline() {
    local type=${_IO_FIO_TYPE:-randread}
    local bs=256k jobs=128
    local rw

    case "$type" in
        randread)  rw=randread  ;;
        randwrite) rw=randwrite ;;
        randrw)    rw=randrw    ;;
        seqread)   rw=read      ;;
        seqwrite)  rw=write     ;;
        *) rw=randread ;;
    esac

    # read 测试需要先创建文件
    if [[ "$rw" =~ read ]]; then
        ssh_to_client "fio \
            --directory='${_TEST_DIR}' \
            --name=baseline_prep \
            --rw=write \
            --bs=4M \
            --filesize=${_FILESIZE} \
            --size=${_FILESIZE} \
            --numjobs=${jobs} \
            --fallocate=none \
            --direct=1 \
            --ioengine=libaio \
            --iodepth=128 \
            > /dev/null 2>&1" 2>/dev/null || true
    fi

    local create_opt=""
    [[ "$rw" =~ read ]] || create_opt="--create_on_open=1"

    ssh_to_client "fio \
        --directory='${_TEST_DIR}' \
        --name=baseline_prep \
        --rw=${rw} \
        --bs=${bs} \
        --ioengine=libaio \
        --iodepth=128 \
        --numjobs=${jobs} \
        --direct=1 \
        --fallocate=none \
        ${create_opt} \
        --openfiles=${jobs} \
        --filesize=${_FILESIZE} \
        --size=${_FILESIZE} \
        --group_reporting \
        --time_based \
        --runtime=10 \
        --output-format=json \
        --output=${_IO_FIO_BASELINE} \
        > /dev/null 2>&1" 2>/dev/null

    local json
    json=$(ssh_to_client "sed -n '/^{/,\$p' ${_IO_FIO_BASELINE} 2>/dev/null" 2>/dev/null)

    # 保存到本地文件，供 run.sh 收集 artifacts
    echo "$json" > /tmp/reliability-fio-baseline.json 2>/dev/null || true

    _IO_BASELINE_BW=$(echo "$json" | jq -r '(.jobs[0].read.bw // .jobs[0].write.bw // 0)' 2>/dev/null)
    _IO_BASELINE_BW=$(( _IO_BASELINE_BW / 1024 ))  # KiB → MiB

    local ns
    ns=$(echo "$json" | jq -r '
        (.jobs[0].read.clat_ns.percentile["99.000000"] //
         .jobs[0].write.clat_ns.percentile["99.000000"] //
         0)' 2>/dev/null)
    _IO_BASELINE_P99=$(( ns / 1000 ))  # ns → us

    echo "baseline: bw=${_IO_BASELINE_BW} MiB/s  p99=${_IO_BASELINE_P99} us"
}

get_baseline_bw() {
    echo "$_IO_BASELINE_BW"
}

# ============================================================
# during_fault_io_test — 故障期间同步 I/O 测试
# 写随机数据 → MD5 → 读回 → MD5 对比，验证 I/O 可靠性
# 不依赖 fio（fio 可能卡在 D 状态）
# 返回: "write_rc read_rc md5_match"
#   write_rc:  0=ok, 1=dd错误, 124=dd超时, timeout=SSH超时
#   read_rc:   0=ok, 1=dd错误, 124=dd超时, skip=写失败跳过
#   md5_match: true=一致, false=不一致(数据损坏), skip=未验证
# ============================================================
during_fault_io_test() {
    local test_dir="${_TEST_DIR}"
    local result

    result=$(timeout 330 sshpass -p "${SSH_PASSWORD}" ssh ${SSH_OPTS} \
        "${SSH_USER}@${CLIENT_SERVER}" "
        T0=\$(date +%s)

        # 1. 生成随机数据到 /tmp，算源 MD5
        dd if=/dev/urandom of=/tmp/df_source.bin bs=1M count=10 2>/dev/null
        md5_src=\$(md5sum /tmp/df_source.bin 2>/dev/null | awk '{print \$1}')
        T1=\$(date +%s)

        # 2. 写到 JuiceFS（oflag=direct，数据直达存储）
        timeout 300 dd if=/tmp/df_source.bin of='${test_dir}/during_fault.bin' bs=1M count=10 oflag=direct 2>/dev/null
        write_rc=\$?
        T2=\$(date +%s)

        # 默认值
        read_rc=skip
        md5_match=skip

        if [ \"\$write_rc\" = \"0\" ]; then
            # 3. 读回到 /tmp（iflag=direct，从存储读，不走缓存）
            timeout 90 dd if='${test_dir}/during_fault.bin' of=/tmp/df_readback.bin bs=1M count=10 iflag=direct 2>/dev/null
            read_rc=\$?
            T3=\$(date +%s)

            if [ \"\$read_rc\" = \"0\" ]; then
                # 4. 对比源 MD5 vs 回读 MD5
                md5_rb=\$(md5sum /tmp/df_readback.bin 2>/dev/null | awk '{print \$1}')
                if [ \"\$md5_src\" = \"\$md5_rb\" ]; then
                    md5_match=true
                else
                    md5_match=false
                fi
            fi
        else
            T3=\$T2
        fi

        # 清理
        rm -f /tmp/df_source.bin /tmp/df_readback.bin '${test_dir}/during_fault.bin' 2>/dev/null

        echo \"\$write_rc \$read_rc \$md5_match \$md5_src \$md5_rb t_gen=\$((T1-T0))s t_write=\$((T2-T1))s t_read=\$((T3-T2))s t_total=\$((T3-T0))s\"
    " 2>/dev/null)

    [ -z "$result" ] && result="timeout skip skip - -"
    echo "$result"
    echo "# during_fault_io_test: $result" >&2
}
