#!/bin/bash
set -e

# 02-2-G-planC stable-ID-rebuild stable-baseline validation  [2026-07-23]
# 方案 C：每轮 stable-ID 重建（destroy + ceph-volume --osd-id + auth fix + 不删 pool）
#   02-2-G 结论：soft-clean+OSD restart 未能消除第三源（tmpfs/RocksDB SST 累积）
#   方案 C 每轮 fresh BlueStore → 彻底清除 tmpfs RocksDB → 预期 mseqread 不再单调降
#
# 探针 = randread(稳定性) + mseqread(tmpfs 累积试金石)
# 用法：./02-2-G-planC.sh <GROUP> <CYCLES> <RUNTIME> <REPEAT>
#   GROUP=A CYCLES=4 RUNTIME=90 REPEAT=2 （≈100min，含每轮 ~15min rebuild）
#
# 红线：157 上 WekaIO 在跑，禁动内核/网卡/RoCE/md0/WekaIO
#   ⚑ destroy 保留 OSD ID + CRUSH + pool_id → 映射不变
#   ⚑ auth key 不匹配：destroy 保留旧 key → ceph auth rm + ceph auth add 修复
#   ⚑ 不删 pool → pool_id 不变 → PG→OSD 映射不变

# ===== 配置 =====
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"
TEST_DIR="${MNT}/test_dir"
BW_LOG_DIR="/tmp/jfs-bw"
RESULTS_DIR="/tmp/opencode-02-2-g-planc"
NIC_IF="enp139s0f0np0"
POOL_DATA="juicefs-data"
FORENSIC="$(dirname "$0")/rebuild-topology-forensic.sh"
GROUP="${1:-A}"
CYCLES="${2:-4}"
RUNTIME="${3:-90}"
REPEAT="${4:-2}"

SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
HOSTS=(ceph-node1 ceph-node2 ceph-node3)
DEVS=(/dev/nvme2n1 /dev/nvme3n1)
DBWAL_MNT=/mnt/dbwal
DB_SIZE=40G
WAL_SIZE=10G
OSD_MAP=("0:0:0" "1:0:1" "2:1:0" "3:1:1" "4:2:0" "5:2:1")
SSHPASS="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

case "${GROUP}" in
    A*) RA="default" ;;
    B*) RA="ra0" ;;
    *)  RA="default" ;;
esac
LABEL="${GROUP}"

mkdir -p "${RESULTS_DIR}" "${BW_LOG_DIR}"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${RESULTS_DIR}/test.log"; }

# ===== Helpers =====
drop_caches() {
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    for ip in ${SLAVES[@]}; do
        $SSHPASS@$ip 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null' 2>/dev/null || true
    done
    rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
}

compact_cooldown() {
    local osd_list=$(sudo ceph osd ls 2>/dev/null | tr '\n' ' ')
    for osd in ${osd_list}; do sudo ceph tell osd.${osd} compact 2>/dev/null || true; done
    for i in $(seq 1 60); do
        all_done=true; for osd in ${osd_list}; do
            running=$(sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("rocksdb",{}).get("compact_running",0))' 2>/dev/null || echo "1")
            [ "$running" != "0" ] && all_done=false
        done; $all_done && break; sleep 5
    done
}

# ===== 方案 C 核心：stable-ID 重建（destroy + ceph-volume --osd-id + auth fix）=====
# 每轮 fresh BlueStore → 清除 tmpfs RocksDB SST 累积
# 不删 pool → pool_id 不变 → PG→OSD 映射不变
stable_id_rebuild() {
    log "=== STABLE-ID REBUILD (destroy + ceph-volume --osd-id + auth fix; 不删 pool) ==="

    # 1. 卸载 JuiceFS + 等 TTL
    fusermount -u "${MNT}" 2>/dev/null || true; pkill -f 'juicefs.*mount' 2>/dev/null || true; sleep 5; sleep 65
    local UUID=$(juicefs status "${META}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4)
    [ -n "${UUID}" ] && juicefs destroy "${META}" "${UUID}" --yes 2>&1 | tail -1
    compact_cooldown

    # 2. 停 OSD（mask+stop，防 systemd 自动重启）
    log "--- 停 OSD ---"
    for ip in ${SLAVES[@]}; do
        $SSHPASS@$ip '
            for id in $(systemctl list-units "ceph-osd@*" --all --no-legend 2>/dev/null | awk "{print \$1}" | grep -oP "osd@\K[0-9]+"); do
                sudo systemctl mask ceph-osd@${id} 2>/dev/null || true
                sudo systemctl stop ceph-osd@${id} 2>/dev/null || true
            done
            sudo pkill -9 ceph-osd 2>/dev/null || true
        ' 2>/dev/null || true
    done
    sleep 3
    log "--- 验证已停止 ---"
    for ip in ${SLAVES[@]}; do
        running=$($SSHPASS@$ip "pgrep ceph-osd | head -1" 2>/dev/null)
        [ -n "$running" ] && log "  ⚠️ ${ip} 仍有 ceph-osd (pid=$running)" || true
    done

    # 3. ceph osd down + destroy（保留 ID + CRUSH + auth）
    log "--- destroy OSDs ---"
    for entry in "${OSD_MAP[@]}"; do
        osd_id=${entry%%:*}
        sudo ceph osd down ${osd_id} 2>/dev/null || true
    done
    sleep 5
    for entry in "${OSD_MAP[@]}"; do
        osd_id=${entry%%:*}
        log "  destroy osd.${osd_id}..."
        sudo ceph osd destroy ${osd_id} --yes-i-really-mean-it 2>/dev/null || true
    done
    sleep 3

    # 4. 验证 destroyed 标志
    log "--- 验证 destroyed ---"
    for entry in "${OSD_MAP[@]}"; do
        osd_id=${entry%%:*}
        state=$(sudo ceph osd info ${osd_id} 2>/dev/null | grep -oP 'destroyed' || true)
        [ -n "$state" ] && log "  osd.${osd_id}: ✅ destroyed" || log "  osd.${osd_id}: ⚠️ NOT destroyed"
    done

    # 5. 删除旧 auth key（destroy 保留的旧 key）
    log "--- ceph auth rm (删旧 key) ---"
    for entry in "${OSD_MAP[@]}"; do
        osd_id=${entry%%:*}
        sudo ceph auth rm osd.${osd_id} 2>/dev/null || true
    done

    # 6. 清 LVM + 重建 LVM
    log "--- clean + recreate LVMs ---"
    for ip in ${SLAVES[@]}; do
        $SSHPASS@$ip "sudo bash /tmp/cleanup-node.sh" 2>/dev/null || true
    done
    for entry in "${OSD_MAP[@]}"; do
        IFS=':' read osd_id node_idx dev_idx <<< "$entry"
        ip=${SLAVES[$node_idx]}; host=${HOSTS[$node_idx]}; dev=${DEVS[$dev_idx]}
        osd_seq=$((osd_id + 1))
        $SSHPASS@$ip bash -s << EOF
set -e
db_file=${DBWAL_MNT}/db-osd${osd_seq}.img
wal_file=${DBWAL_MNT}/wal-osd${osd_seq}.img
sudo truncate -s ${DB_SIZE} \$db_file
sudo truncate -s ${WAL_SIZE} \$wal_file
db_loop=\$(sudo losetup -f --show \$db_file)
wal_loop=\$(sudo losetup -f --show \$wal_file)
db_vg=ceph-vg-db${osd_seq}; wal_vg=ceph-vg-wal${osd_seq}
sudo pvcreate -ff -y \$db_loop 2>/dev/null || true
sudo pvcreate -ff -y \$wal_loop 2>/dev/null || true
sudo vgcreate \$db_vg \$db_loop 2>/dev/null || true
sudo vgcreate \$wal_vg \$wal_loop 2>/dev/null || true
sudo lvcreate -l 100%FREE -n osd-db \$db_vg 2>/dev/null || true
sudo lvcreate -l 100%FREE -n osd-wal \$wal_vg 2>/dev/null || true
data_vg=ceph-vg-osd${osd_seq}
sudo pvcreate -ff -y ${dev} 2>/dev/null || true
sudo vgcreate \$data_vg ${dev} 2>/dev/null || true
sudo lvcreate -l 100%FREE -n osd \$data_vg 2>/dev/null || true
EOF
    done
    # 验证 LVMs
    for ip in ${SLAVES[@]}; do
        count=$($SSHPASS@$ip "sudo lvs --noheadings -o vg_name,lv_name 2>/dev/null | grep ceph | wc -l" 2>/dev/null || echo 0)
        [ "$count" -ge 6 ] && log "  ${ip}: ✅ ${count} LVs" || log "  ${ip}: ❌ ${count} LVs"
    done

    # 7. ceph-volume lvm prepare（fresh BlueStore + 新 keyring，但不启动 OSD）
    log "--- ceph-volume lvm prepare --osd-id ---"
    for entry in "${OSD_MAP[@]}"; do
        IFS=':' read osd_id node_idx dev_idx <<< "$entry"
        ip=${SLAVES[$node_idx]}
        osd_seq=$((osd_id + 1))
        data_lv="/dev/ceph-vg-osd${osd_seq}/osd"
        db_lv="/dev/ceph-vg-db${osd_seq}/osd-db"
        wal_lv="/dev/ceph-vg-wal${osd_seq}/osd-wal"
        $SSHPASS@$ip "sudo ceph-volume lvm prepare --bluestore --osd-id ${osd_id} --data ${data_lv} --block.db ${db_lv} --block.wal ${wal_lv} --crush-device-class ssd 2>&1 | tail -2" 2>/dev/null
        sleep 1
    done

    # 8. 修复 auth key（prepare 生成新 key → ceph auth add 注册到 mon → 然后才启动 OSD）
    log "--- ceph auth add (注册新 key) ---"
    for entry in "${OSD_MAP[@]}"; do
        IFS=':' read osd_id node_idx dev_idx <<< "$entry"
        ip=${SLAVES[$node_idx]}
        key=$($SSHPASS@$ip "sudo grep ^key /var/lib/ceph/osd/ceph-${osd_id}/keyring | head -1 | sed 's/key = //'" 2>/dev/null)
        if [ -n "$key" ]; then
            cat > /tmp/planc-osd-${osd_id}.keyring << KEYRING
[osd.${osd_id}]
	key = $key
	caps mgr = "allow profile osd"
	caps mon = "allow profile osd"
	caps osd = "allow *"
KEYRING
            sudo ceph auth add osd.${osd_id} -i /tmp/planc-osd-${osd_id}.keyring 2>&1 | tail -1
            rm -f /tmp/planc-osd-${osd_id}.keyring
        else
            log "  ⚠️ osd.${osd_id}: no key found"
        fi
    done

    # 9. 启动 OSD（auth key 已注册，beacon 可认证）
    log "--- start OSDs ---"
    for entry in "${OSD_MAP[@]}"; do
        IFS=':' read osd_id node_idx dev_idx <<< "$entry"
        ip=${SLAVES[$node_idx]}
        $SSHPASS@$ip "sudo systemctl unmask ceph-osd@${osd_id} 2>/dev/null || true; sudo systemctl reset-failed ceph-osd@${osd_id} 2>/dev/null || true; sudo systemctl start ceph-osd@${osd_id} 2>/dev/null || true" 2>/dev/null
    done
    log "--- 等 PG active+clean ---"
    for i in $(seq 1 60); do
        pg=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
        echo "$pg" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
        sleep 5
    done
    log "  $(sudo ceph -s 2>/dev/null | grep -E 'osd:|pgs:' | head -2 | tr '\n' ' ')"

    # 10. compact + drop_caches
    compact_cooldown
    drop_caches
    sleep 5
    log "--- stable-ID rebuild done ---"
}

mount_jfs() {
    local opts="--max-uploads 150 --cache-size 0"
    [ "${RA}" = "ra0" ] && opts="$opts --max-readahead 0"
    juicefs format --storage ceph --bucket ceph://${POOL_DATA} --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 --force "${META}" juicefs-prod 2>/dev/null | tail -1
    for try in 1 2 3; do
        juicefs mount -d $opts "${META}" "${MNT}" 2>&1 | tail -1
        sleep 3; mount | grep juice | grep -q "max_read=" && break; sleep 10
    done
    mount | grep juice | grep -q "max_read=" || { log "ERROR: mount failed"; exit 1; }
    mkdir -p "${TEST_DIR}"
    log "Mounted ${LABEL} (max_read=$(mount | grep juice | grep -o 'max_read=[0-9]*'))"
}

run_fio() {
    local label="$1"; local subdir="${RESULTS_DIR}/${label}"; mkdir -p "${subdir}"
    drop_caches
    ( while true; do echo "$(date +%s) | $(cat /proc/net/dev | grep ${NIC_IF})"; sleep 1; done ) > "${subdir}/nic.txt" & local nic_pid=$!
    shift; eval "$*" 2>&1 | tee "${subdir}/fio.txt"
    kill ${nic_pid} 2>/dev/null || true; wait ${nic_pid} 2>/dev/null || true
    cp ${BW_LOG_DIR}/*_bw.*.log "${subdir}/" 2>/dev/null || true; rm -f ${BW_LOG_DIR}/*_bw.*.log 2>/dev/null || true
    local bw=$(grep -oE 'bw=[0-9]+MiB' "${subdir}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    log "${label}: BW=${bw:-N/A} MiB/s"
}

run_cycle() {
    local cyc="$1"
    log "=== [cycle ${cyc}] layout ==="
    run_fio "c${cyc}-layout-${LABEL}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=4M --rw=write --numjobs=128 --fallocate=none --direct=1 --ioengine=libaio --iodepth=128 --group_reporting --end_fsync=1 --write_bw_log='${BW_LOG_DIR}/c${cyc}-layout-${LABEL}' --log_avg_msec=1000"
    compact_cooldown
    for r in $(seq 1 ${REPEAT}); do
        run_fio "c${cyc}-randread-${LABEL}-r${r}" "fio --directory='${TEST_DIR}' --name=storage_test --filesize=1G --size=1G --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/c${cyc}-randread-${LABEL}-r${r}' --log_avg_msec=1000"
    done
    log "=== [cycle ${cyc}] mseqread (tmpfs 累积试金石) ==="
    rm -rf "${TEST_DIR}/mseqread"; mkdir -p "${TEST_DIR}/mseqread"
    fio --name=prep --directory="${TEST_DIR}/mseqread/" --rw=write --bs=4M --size=4G --numjobs=16 >/dev/null 2>&1
    run_fio "c${cyc}-mseqread-${LABEL}" "fio --name=mseqread --directory='${TEST_DIR}/mseqread/' --rw=read --refill_buffers --bs=256k --size=4G --numjobs=16 --group_reporting --direct=1 --ioengine=psync --iodepth=1 --time_based --runtime=${RUNTIME} --write_bw_log='${BW_LOG_DIR}/c${cyc}-mseqread-${LABEL}' --log_avg_msec=1000"
    compact_cooldown
}

capture_contract() {
    local out="${RESULTS_DIR}/reproduction-contract-${LABEL}.txt"
    {
        echo "# reproduction-contract  group=${LABEL} readahead=${RA}  captured=$(date '+%F %T')"
        echo "[OSD 集合]        $(sudo ceph osd ls 2>/dev/null | tr '\n' ',')"
        echo "[pool_id]         $(sudo ceph osd pool ls detail 2>/dev/null | grep juicefs-data | head -1)"
        echo "[ceph version]    $(sudo ceph version 2>/dev/null)"
        echo "[juicefs version] $(juicefs version 2>/dev/null)"
    } > "${out}"
    log "复现契约已写 -> ${out}"
}

# ============================================================
log "============================================"
log "=== 02-2-G-planC stable-ID-rebuild group=${LABEL} readahead=${RA} cycles=${CYCLES} rt=${RUNTIME} rep=${REPEAT} ==="
log "=== 方案 C：每轮 destroy+ceph-volume --osd-id+auth fix；不删 pool ==="
log "=== 探针: randread(稳定性) + mseqread(tmpfs 累积试金石); cycle1=预热轮 ==="
log "============================================"

# Pre-test health
HEALTH=$(sudo ceph health 2>/dev/null); log "ceph health: ${HEALTH}"
OSD_UP=$(sudo ceph osd stat 2>/dev/null | grep -oE '[0-9]+ up' | grep -oE '^[0-9]+' || echo 0)
log "OSDs up: ${OSD_UP} (expected 6)"
[ "${OSD_UP}" = "6" ] || { log "ERROR: not all OSDs up"; exit 1; }

BASE_OSDSET=$(sudo ceph osd ls 2>/dev/null | tr '\n' ',')
log "起始 OSD 集合 = ${BASE_OSDSET}  (全程应保持不变)"
capture_contract

for cyc in $(seq 1 ${CYCLES}); do
    log "########## CYCLE ${cyc}/${CYCLES} ##########"
    [ "${cyc}" -eq 1 ] && log "(cycle1 = 预热/参照轮，CV 从 cycle2 起算)"
    [ "${cyc}" -eq 1 ] || stable_id_rebuild
    mount_jfs
    run_cycle "${cyc}"

    # 取证自证
    if [ -x "${FORENSIC}" ]; then
        log "[cycle ${cyc}] 取证快照..."
        bash "${FORENSIC}" "PLANC-c${cyc}" || true
    fi
    NOW_OSDSET=$(sudo ceph osd ls 2>/dev/null | tr '\n' ',')
    if [ "${NOW_OSDSET}" = "${BASE_OSDSET}" ]; then
        log "[cycle ${cyc}] ✅ OSD 集合不变 (${NOW_OSDSET})"
    else
        log "[cycle ${cyc}] ⚠️ OSD 集合变了! base=${BASE_OSDSET} now=${NOW_OSDSET}"
    fi
done

# ===== 汇总 =====
log "=== 汇总：跨 cycle randread (fio bw, MiB/s) ==="
for cyc in $(seq 1 ${CYCLES}); do
    line="cycle${cyc}:"
    for r in $(seq 1 ${REPEAT}); do
        bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/c${cyc}-randread-${LABEL}-r${r}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
        line="${line} r${r}=${bw:-NA}"
    done
    log "  ${line}"
done
log "=== 汇总：跨 cycle mseqread (fio bw MiB/s) ==="
for cyc in $(seq 1 ${CYCLES}); do
    bw=$(grep -oE 'bw=[0-9]+MiB' "${RESULTS_DIR}/c${cyc}-mseqread-${LABEL}/fio.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    log "  cycle${cyc}: mseqread=${bw:-NA}"
done

# 判定
python3 - <<PY 2>/dev/null | while read l; do log "$l"; done || true
import statistics as s, re, os
base="${RESULTS_DIR}"; label="${LABEL}"; cycles=${CYCLES}; repeat=${REPEAT}
def bw(f):
    if os.path.exists(f):
        m=re.search(r'bw=([0-9]+)MiB', open(f).read())
        if m: return int(m.group(1))
    return None
rr=[]
for c in range(1,cycles+1):
    rs=[bw(f"{base}/c{c}-randread-{label}-r{r}/fio.txt") for r in range(1,repeat+1)]
    rs=[x for x in rs if x]
    if rs: rs.sort(); rr.append(rs[len(rs)//2] if len(rs)>1 else rs[0])
    else: rr.append(None)
mr=[bw(f"{base}/c{c}-mseqread-{label}/fio.txt") for c in range(1,cycles+1)]

print(f"randread 逐 cycle 中位 = {rr}")
print(f"mseqread 逐 cycle       = {mr}")

stable=[x for x in rr[1:] if x]
if len(stable)>=2:
    cv=100*s.pstdev(stable)/s.mean(stable)
    print(f"[判据①] randread CV(排除c1) = {cv:.2f}%  (目标<5%)")
    print("        " + ("✅ 稳态可复现" if cv<5 else "❌ 仍不稳"))
else:
    print("[判据①] 数据不足")

ms=[x for x in mr[1:] if x]
if len(ms)>=2:
    incs=[100*(ms[i+1]-ms[i])/ms[i] for i in range(len(ms)-1)]
    mono_down = all(x < -3 for x in incs)
    print(f"[判据②] mseqread(排除c1) 逐步Δ = {[f'{x:+.1f}%' for x in incs]}")
    print("        " + ("❌ 仍单调下降 → 方案C也失败" if mono_down else "✅ 不再单调下降 → fresh BlueStore 消除了 tmpfs 累积"))
else:
    print("[判据②] 数据不足")

print("")
print("=== 总判定 ===")
if len(stable)>=2 and len(ms)>=2:
    if cv<5 and not mono_down:
        print("✅ 方案C成功：每轮 stable-ID 重建得到稳态可复现基线")
        print("   → 锁基线，进入 P2-P4")
    elif not mono_down:
        print("⚠️ mseqread 已稳定但 randread CV 仍 >5% → 需人工复审")
    else:
        print("❌ 方案C失败：fresh BlueStore 也未能消除单调下降 → 接受区间基线，直接进 P2-P4")
print("")
print("⚑ 可复现性边界: 本 CV 仅证明【同一部署】上可复现。跨部署不可复现(§九)。")
PY

log "=== 02-2-G-planC DONE ==="
log "取证快照见 /tmp/opencode-rebuild-forensic/PLANC-c*/"
