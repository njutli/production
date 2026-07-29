#!/bin/bash
set -euo pipefail

# cluster-teardown.sh — 彻底清除 Ceph+TiKV，恢复到部署前状态
# 在 WSL 上运行（config.sh 三层 SSH 跳板：WSL → HK ECS → 157 → slaves）
# ⛔ 不碰 157 上的任何业务（WekaIO/K8s/SSH 等）
# 必须遵守 SYSTEM-SAFETY-SKILL.md
#
# FSID 自动探测（不硬编码）：157 ceph CLI(带timeout) → 首节点 ceph.conf → /var/lib/ceph；
# 节点本地另有 ceph.conf → systemd unit 名兜底。
# 系统盘守卫：对每个待操作设备先验证「非系统盘且无残留挂载」，拒绝即跳过并告警。
#
# 注：cephadm rm-cluster 是节点本地操作，在 157 上跑是无效空转；
#     真正的拆除由 Step 2 逐节点清理完成（容器/systemd 单元/数据目录）。
#
# 用法：bash cluster-teardown.sh                # 全部三节点
#       TEARDOWN_NODES=10.20.1.150 bash cluster-teardown.sh   # 单节点调试（§1.4 逐节点）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${PROD_DEPLOY_DIR}/config.sh"

# 目标节点（默认 config.sh 全部 slaves；可用 TEARDOWN_NODES 覆盖做单节点调试）
TARGET_NODES=( ${TEARDOWN_NODES:-${SLAVE_SERVERS[@]}} )
PRIMARY_IP="${TARGET_NODES[0]}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ===== FSID 自动探测（只读）=====
detect_fsid() {
    local fsid=""
    # 1) 157 ceph CLI（mon 可达时最可靠；无 quorum 会挂死 → 必须 timeout 强杀）
    fsid=$(ssh_to_client 'timeout -k 5 10 sudo ceph fsid 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || true)
    # 2) 首节点 /etc/ceph/ceph.conf（cephadm 生成的配置 fsid 行有 TAB 缩进 → 须允许前导空白）
    if [ -z "${fsid}" ]; then
        fsid=$(ssh_to_slave "${PRIMARY_IP}" 'awk -F" = " "/^[[:space:]]*fsid/{print \$2}" /etc/ceph/ceph.conf 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || true)
    fi
    # 3) 首节点 /var/lib/ceph/<fsid> 目录名
    if [ -z "${fsid}" ]; then
        fsid=$(ssh_to_slave "${PRIMARY_IP}" 'sudo ls /var/lib/ceph/ 2>/dev/null | grep -oE "[0-9a-f-]{36}" | head -1' 2>/dev/null | tr -d '[:space:]' || true)
    fi
    echo "${fsid}"
}

FSID=$(detect_fsid)
if [ -n "${FSID}" ]; then
    log "Detected FSID: ${FSID}"
else
    log "WARN: FSID 探测失败（集群可能已部分拆除）；跳过集群层操作，继续逐节点通用清理"
fi

# ===== Step 1: 157 客户端侧拆除（best-effort，全部带 timeout）=====
step1_client_teardown() {
    log "=== Step 1: client-side teardown (157) ==="
    ssh_to_client '
        # 注：mon 无 quorum 时所有 ceph CLI 都会挂死 → 一律 timeout -k 强杀
        timeout -k 5 10 sudo ceph osd set noout 2>/dev/null || true
        timeout -k 5 10 sudo ceph osd set norebalance 2>/dev/null || true
        # 卸载 JuiceFS
        fusermount -u /mnt/juicefs 2>/dev/null || true
        pkill -f "juicefs.*mount" 2>/dev/null || true
        # 删 pool（best-effort；无 quorum 时超时跳过，由逐节点清理兜底）
        timeout -k 5 10 sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null || true
        echo "  client-side teardown done"
    ' 2>/dev/null || true
}

# ===== Step 2: 逐节点清理（TiKV + Ceph 残留 + 设备）=====
step2_clean_nodes() {
    for ip in "${TARGET_NODES[@]}"; do
        log "=== cleaning ${ip} ==="

        log "  stopping TiKV/PD"
        ssh_to_slave "${ip}" '
            sudo systemctl stop tikv 2>/dev/null || true
            sudo systemctl stop pd 2>/dev/null || true
            sudo systemctl disable tikv 2>/dev/null || true
            sudo systemctl disable pd 2>/dev/null || true
            sudo kill $(pgrep -f tikv-server) 2>/dev/null || true
            sudo kill $(pgrep -f pd-server) 2>/dev/null || true
            sleep 3
        ' 2>/dev/null || true

        log "  stopping Ceph containers"
        ssh_to_slave "${ip}" '
            # 按 image 字符串过滤：cephadm shell 临时容器是随机名（zen_shirley 等，名字不含 ceph），
            # 且 cephadm 创建的 daemon 容器 image 是 digest 形式（ceph@sha256:...），
            # 按名字或 ancestor=tag 都会漏 → 直接匹配 image 字段含 ceph/ceph
            for c in $(sudo podman ps -a --format "{{.Names}} {{.Image}}" 2>/dev/null | grep "ceph/ceph" | awk "{print \$1}"); do
                echo "    rm container $c"
                sudo podman rm -f "$c" >/dev/null 2>&1 || true
            done
        ' 2>/dev/null || true

        log "  removing cephadm systemd units + ceph data (per-node FSID detect)"
        ssh_to_slave "${ip}" '
            # 节点本地探测 FSID（ceph.conf 可能已移除 → fallback systemd unit 名）
            # 注意 cephadm 生成的 ceph.conf fsid 行有 TAB 缩进 → 须允许前导空白
            fsid=$(awk -F" = " "/^[[:space:]]*fsid/{print \$2}" /etc/ceph/ceph.conf 2>/dev/null || true)
            if [ -z "${fsid}" ]; then
                fsid=$(ls /etc/systemd/system/ 2>/dev/null | grep -oE "ceph-[0-9a-f-]{36}" | head -1 | sed "s/^ceph-//")
            fi
            # fsid 仅用于 stop/disable 当前集群 target；unit 文件无条件全删
            # （历次 bootstrap 会在 /etc/systemd/system 留下不同 fsid 的 unit，单删当前 fsid 清不干净）
            if [ -n "${fsid}" ]; then
                sudo systemctl stop ceph-${fsid}.target 2>/dev/null || true
                sudo systemctl disable ceph-${fsid}.target 2>/dev/null || true
                echo "    fsid=${fsid} target stopped"
            fi
            sudo rm -f /etc/systemd/system/ceph-*.service /etc/systemd/system/ceph-*.target
            sudo rm -rf /etc/systemd/system/ceph-*.target.wants
            sudo rm -f /etc/systemd/system/multi-user.target.wants/ceph-*
            sudo systemctl daemon-reload
            # 全量清 ceph 数据/日志目录（容器已停；多 fsid 目录残留会导致 cephadm shell infer 冲突）
            # 必须 sudo bash -c 让 root shell 展开 glob：/var/lib/ceph 是 750 167:167，非 root glob 不展开。
            # 注意：本远端块整体是单引号字符串，bash -c 的参数必须用双引号（内层单引号会截断外层块！）
            [ -d /var/lib/ceph ] && sudo bash -c "rm -rf /var/lib/ceph/*" 2>/dev/null || true
            [ -d /var/log/ceph ] && sudo bash -c "rm -rf /var/log/ceph/*" 2>/dev/null || true
            sudo rm -f /etc/ceph/ceph.conf /etc/ceph/ceph.pub /etc/ceph/ceph.client.admin.keyring 2>/dev/null || true
            sudo systemctl daemon-reload
        ' 2>/dev/null || true

        log "  cleaning tmpfs DB/WAL (loops + images)"
        ssh_to_slave "${ip}" '
            for img in /mnt/dbwal/db-osd*.img /mnt/dbwal/wal-osd*.img; do
                [ -e "${img}" ] || continue
                loop=$(sudo losetup -j "${img}" 2>/dev/null | cut -d: -f1 | head -1)
                if [ -n "${loop}" ]; then
                    echo "    detach ${loop} (${img})"
                    sudo losetup -d "${loop}" 2>/dev/null || true
                fi
            done
            # deleted 状态的残留 loop：losetup -j 按现存文件匹配不到，按路径名 grep 兜底
            for l in $(sudo losetup -a 2>/dev/null | grep dbwal | cut -d: -f1); do
                echo "    detach stale ${l}"
                sudo losetup -d "${l}" 2>/dev/null || true
            done
            sudo rm -f /mnt/dbwal/db-osd*.img /mnt/dbwal/wal-osd*.img
            echo "    dbwal imgs left: $(ls /mnt/dbwal/*.img 2>/dev/null | wc -l)"
            echo "    dbwal loops left: $(sudo losetup -a 2>/dev/null | grep -c dbwal || true)"
        ' 2>/dev/null || true

        log "  cleaning LVM on nvme2n1/nvme3n1 (with system-disk guard)"
        ssh_to_slave "${ip}" '
            # ===== 系统盘守卫（§一最高原则：不能动系统盘）=====
            # 判定：目标盘 != / 所在顶层磁盘，且整盘（含 LVM 子设备）无残留挂载。
            # 任一不满足 → 拒绝操作该盘并跳过（宁可留残留，不可误伤）。
            guard_not_system_disk() {
                local dev="$1"
                [ -b "${dev}" ] || { echo "    REFUSE: not a block device: ${dev}"; return 1; }
                local root_src root_disk target_disk pk
                root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
                root_disk=$(lsblk -no PKNAME "${root_src}" 2>/dev/null || true)
                [ -z "${root_disk}" ] && root_disk=$(basename "${root_src}")
                target_disk=$(basename "${dev}")
                pk=$(lsblk -no PKNAME "${dev}" 2>/dev/null || true)
                [ -n "${pk}" ] && target_disk="${pk}"
                if [ "${target_disk}" = "${root_disk}" ]; then
                    echo "    REFUSE: ${dev} IS the system disk (root disk=${root_disk})"
                    return 1
                fi
                if lsblk -nr -o MOUNTPOINT "${dev}" 2>/dev/null | grep -q "[[:alnum:]]"; then
                    echo "    REFUSE: ${dev} still has mounts:"
                    lsblk -nr -o NAME,MOUNTPOINT "${dev}" 2>/dev/null | grep "[[:alnum:]]" | sed "s/^/      /"
                    return 1
                fi
                echo "    SAFE: ${dev} (system disk=${root_disk})"
                return 0
            }

            # ceph DM 设备（容器删除后 DM 释放有延迟 → 两轮清理，间隔 5s）
            for _round in 1 2; do
                for dm in $(sudo dmsetup ls --noheadings 2>/dev/null | grep -i ceph | awk "{print \$1}"); do
                    sudo dmsetup remove "${dm}" 2>/dev/null || true
                done
                _left=$(sudo dmsetup ls --noheadings 2>/dev/null | grep -ic ceph || true)
                [ "${_left}" = "0" ] && break
                sleep 5
            done

            for dev in /dev/nvme2n1 /dev/nvme3n1; do
                [ -b "${dev}" ] || continue
                guard_not_system_disk "${dev}" || continue
                for vg in $(sudo vgs --noheadings -o vg_name "${dev}" 2>/dev/null | tr -d " "); do
                    [ -n "${vg}" ] && sudo vgremove --force "${vg}" 2>/dev/null || true
                done
                sudo pvremove -ffy "${dev}" 2>/dev/null || true
                sudo wipefs -a "${dev}" 2>/dev/null || true
                sudo dd if=/dev/zero of="${dev}" bs=1M count=10 2>/dev/null
                echo "    ${dev} wiped"
            done

            # 收尾再补一轮：OSD 容器删除后 db/wal loop 引用延迟释放（deleted 残留）
            for l in $(sudo losetup -a 2>/dev/null | grep dbwal | cut -d: -f1); do
                sudo losetup -d "${l}" 2>/dev/null || true
            done
            # 收尾再补一轮：vgremove 后可能仍有孤儿 DM
            for dm in $(sudo dmsetup ls --noheadings 2>/dev/null | grep -i ceph | awk "{print \$1}"); do
                sudo dmsetup remove "${dm}" 2>/dev/null || true
            done
        ' 2>/dev/null || true

        log "  cleaning TiKV data (nvme1n1, with system-disk guard)"
        ssh_to_slave "${ip}" '
            guard_not_system_disk() {
                local dev="$1"
                [ -b "${dev}" ] || { echo "    REFUSE: not a block device: ${dev}"; return 1; }
                local root_src root_disk target_disk pk
                root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
                root_disk=$(lsblk -no PKNAME "${root_src}" 2>/dev/null || true)
                [ -z "${root_disk}" ] && root_disk=$(basename "${root_src}")
                target_disk=$(basename "${dev}")
                pk=$(lsblk -no PKNAME "${dev}" 2>/dev/null || true)
                [ -n "${pk}" ] && target_disk="${pk}"
                if [ "${target_disk}" = "${root_disk}" ]; then
                    echo "    REFUSE: ${dev} IS the system disk (root disk=${root_disk})"
                    return 1
                fi
                return 0
            }
            dev=/dev/nvme1n1
            sudo umount /mnt/jfs-tikv 2>/dev/null || true
            if [ -b "${dev}" ] && guard_not_system_disk "${dev}"; then
                # 残留挂载检查（/mnt/jfs-tikv 已 umount，其余挂载视为异常 → 拒绝）
                if lsblk -nr -o MOUNTPOINT "${dev}" 2>/dev/null | grep -q "[[:alnum:]]"; then
                    echo "    REFUSE: ${dev} still has unexpected mounts, skip wipe"
                else
                    sudo wipefs -a "${dev}" 2>/dev/null || true
                    echo "    ${dev} wiped"
                fi
            fi
        ' 2>/dev/null || true

        log "  ${ip} done"
    done
}

# ===== Step 3: 清理 157 上的 ceph 客户端配置 =====
step3_clean_client() {
    log "=== Step 3: clean 157 ceph client ==="
    ssh_to_client '
        sudo rm -f /etc/ceph/ceph.conf /etc/ceph/ceph.pub /etc/ceph/ceph.client.admin.keyring /etc/ceph/ceph.client.juicefs.keyring 2>/dev/null || true
        echo "  157 ceph client config removed"
    ' 2>/dev/null || true
}

# ===== Step 4: 验证 =====
step4_verify() {
    log "=== Step 4: verify clean state ==="
    for ip in "${TARGET_NODES[@]}"; do
        log "  checking ${ip}"
        ssh_to_slave "${ip}" '
            echo "    ceph containers: $(sudo podman ps -a --format "{{.Names}}" 2>/dev/null | grep -c . || true)"
            echo "    tikv processes: $(pgrep -xc tikv-server 2>/dev/null || true)"
            echo "    pd processes: $(pgrep -xc pd-server 2>/dev/null || true)"
            echo "    nvme1n1 mount: $(mount | grep -c nvme1n1 || true)"
            echo "    LVM PVs on nvme2/3: $(sudo pvs 2>/dev/null | grep -c "nvme[23]" || true)"
            echo "    DM ceph devices: $(sudo dmsetup ls 2>/dev/null | grep -ic ceph || true)"
            echo "    dbwal imgs: $(ls /mnt/dbwal/*.img 2>/dev/null | wc -l)"
            echo "    loops on dbwal: $(sudo losetup -a 2>/dev/null | grep -c dbwal || true)"
        ' 2>&1
    done
    log "=== TEARDOWN COMPLETE ==="
}

# ===== 主入口 =====
log "===== CLUSTER TEARDOWN START ====="
log "Target nodes: ${TARGET_NODES[*]}"
log "⚠️  This will destroy ALL Ceph+TiKV data on target nodes"
log "⚠️  157 业务不受影响 (WekaIO/K8s safe)"
log "⚠️  系统盘守卫已启用：任何挂载着系统分区的盘会被拒绝操作"

step1_client_teardown
step2_clean_nodes
step3_clean_client
step4_verify
