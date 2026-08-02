#!/bin/bash
set -euo pipefail

# ============================================================
# Ceph Deployment (3 servers, NO RGW, direct RADOS)
#
# 3 nodes (150-152), 2 OSD disks per node (nvme2n1 + nvme3n1) = 6 OSDs.
# DATA on physical NVMe (1 disk = 1 OSD, LVM wrapper for ceph-volume).
# DB/WAL on tmpfs 内存盘 (loop device; ⚠️ 测试专用—断电丢，重建即可).
# EC 4+2, allow_ec_overwrites, failure-domain=osd.
# Dual network: public=10.3.1.0/24, cluster=10.3.2.0/24 (both 100GbE).
# JuiceFS uses --storage ceph (librados direct, no RGW).
#
# SSH: WSL → HK ECS → 157 → slaves (three-level jump host via _run).
#
# Prerequisites:
#   1. config.sh filled correctly
#   2. NOPASSWD sudo on all Ceph nodes
#   3. OSD disks (nvme2n1, nvme3n1) unmounted or remountable
#   4. tmpfs mounted at /mnt/dbwal (prepare-servers.sh handles)
#
# Usage: bash deploy-ceph.sh [--yes]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../${CONFIG_FILE:-config.sh}"

AUTO_YES=false
[ "${1:-}" = "--yes" ] && AUTO_YES=true

PRIMARY="${CEPH_PRIMARY}"

echo "========================================"
echo "Ceph Deployment (NO RGW — direct RADOS)"
echo "========================================"
echo "Nodes:    ${CEPH_SERVERS[*]}"
echo "Primary:  ${PRIMARY}"
echo "OSD disks: ${CEPH_OSD_DEVICES_PER_NODE[*]} per node (6 total)"
echo "DB/WAL:   tmpfs 内存盘 (loop device, ⚠️ 测试专用)"
echo "EC pool:  ${CEPH_EC_K}+${CEPH_EC_M} (failure-domain=${CEPH_FAILURE_DOMAIN})"
echo "Public:   ${CEPH_PUBLIC_NETWORK}  (${PUBLIC_NIC})"
echo "Cluster:  ${CEPH_CLUSTER_NETWORK}  (${CLUSTER_NIC})"
echo "========================================"
echo ""

# ============================================================
# Pre-flight: SSH + sudo + disk checks
# ============================================================

echo ">>> Pre-flight checks..."
for ip in "${CEPH_SERVERS[@]}"; do
    echo -n "  ${ip}: "
    _run "${ip}" "echo -n 'sudo='; sudo -n true 2>/dev/null && echo -n 'OK ' || echo -n 'FAIL '; echo -n 'tmpfs='; mountpoint -q ${CEPH_DB_WAL_MOUNT:-/mnt/dbwal} 2>/dev/null && echo -n 'OK ' || echo -n 'MISSING '; echo 'reachable'" 2>/dev/null || { echo "UNREACHABLE"; exit 1; }
done

# Verify OSD disks exist and are not mounted (or mountable)
echo ""
echo ">>> Disk checks..."
for ip in "${CEPH_SERVERS[@]}"; do
    echo "  ${ip}:"
    for dev in "${CEPH_OSD_DEVICES_PER_NODE[@]}"; do
        _run "${ip}" "
            if [ ! -b ${dev} ]; then
                echo '    ${dev}: NOT FOUND!'; exit 1
            fi
            if mount | grep -q '^${dev} '; then
                echo '    ${dev}: mounted (will unmount before OSD deploy)'
            else
                echo '    ${dev}: OK (not mounted)'
            fi
        " 2>/dev/null || true
    done
done

echo ""
if [ "${AUTO_YES}" = true ]; then
    echo ">>> Auto-confirmed (--yes)"
else
    read -rp "Continue with deployment? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ============================================================
# Step 1: Prepare all servers (podman, cephadm, root SSH)
# ============================================================

echo ""
echo ">>> Step 1: Preparing all servers..."

for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo "  >>> ${ip} (${hostname})..."
    _run "${ip}" "
        set -e

        # Set hostname (nodes renamed to ceph-nodeN)
        sudo hostnamectl set-hostname ${hostname}

        sudo apt-get update -qq || true

        # Install podman (cephadm requires it)
        if ! command -v podman &>/dev/null; then
            echo '  installing podman...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman 2>/dev/null || {
                sudo apt-get --fix-broken install -y 2>/dev/null || true
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman 2>/dev/null || {
                    echo '  ERROR: podman install failed'; exit 1
                }
            }
        else echo '  podman OK'; fi

        # Install disk tools
        command -v sgdisk &>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk parted 2>/dev/null || true

        # Ensure ceph-volume is available (for OSD deployment in Step 4)
        command -v ceph-volume &>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ceph-osd 2>/dev/null || true

        # Stop docker if present (conflicts with podman)
        sudo systemctl stop docker docker.socket 2>/dev/null || true
        sudo systemctl disable docker docker.socket 2>/dev/null || true

        # Install cephadm + ceph-common
        if ! command -v cephadm &>/dev/null; then
            echo '  installing cephadm...'
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cephadm ceph-common 2>/dev/null || {
                echo '  apt failed, downloading cephadm...'
                curl -sSL -o /tmp/cephadm 'https://github.com/ceph/ceph/raw/reef/src/cephadm/cephadm'
                head -1 /tmp/cephadm | grep -q python && chmod +x /tmp/cephadm && sudo mv /tmp/cephadm /usr/local/bin/cephadm || {
                    echo '  ERROR: cephadm install failed'; exit 1
                }
            }
        else echo '  cephadm OK'; fi

        # Enable root SSH (cephadm inter-node SSH uses root)
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
        sudo passwd -S root | grep -q ' L ' && sudo passwd -u root 2>/dev/null || true

        # Pull Ceph container image (钉死版本 = ${CEPH_CONTAINER_IMAGE})
        if ! sudo podman image exists ${CEPH_CONTAINER_IMAGE} 2>/dev/null; then
            echo '  pulling ceph container image (${CEPH_CONTAINER_IMAGE})...'
            sudo podman pull ${CEPH_CONTAINER_IMAGE} 2>&1 | tail -1 || echo '  WARNING: pull failed (bootstrap will retry)'
        else echo '  ceph image cached'; fi

        # 镜像健康检查（chown 事故后遗症根治，§1.3 已确认）:
        # 2026-07-27 chown 事故把本机 podman 存储解包层属主从 167 改成 root，
        # 导致镜像内 /var/lib/ceph = 0:0 750 → cephadm extract_uid_gid=0:0 →
        # daemon 数据目录 root:root 0700 → ceph-mon/osd --setuser ceph EACCES。
        # 根治：删本地镜像重新 pull，blob 重新解包恢复上游原生 167:167 750。
        # 不可用 podman commit 修补：cephadm 生成的 systemd unit 启动时会 pull，
        # 会把 tag 顶回 registry 原始镜像，commit 补丁被静默冲掉（已实测）。
        _owner=\$(sudo podman run --rm ${CEPH_CONTAINER_IMAGE} stat -c '%u:%g' /var/lib/ceph 2>/dev/null || echo \"unknown\")
        if [ \"\${_owner}\" != \"167:167\" ]; then
            echo \"  image layer polluted (/var/lib/ceph owner=\${_owner}), re-pulling...\"
            sudo podman rmi ${CEPH_CONTAINER_IMAGE} >/dev/null 2>&1 || {
                echo '  ERROR: image in use by containers, clean ceph containers first'
                exit 1
            }
            sudo podman pull ${CEPH_CONTAINER_IMAGE} 2>&1 | tail -1
            _owner=\$(sudo podman run --rm ${CEPH_CONTAINER_IMAGE} stat -c '%u:%g' /var/lib/ceph 2>/dev/null || echo \"unknown\")
            [ \"\${_owner}\" = \"167:167\" ] || { echo \"  ERROR: re-pulled image still polluted (\${_owner})\"; exit 1; }
            echo '  image re-pulled, owner OK (167:167)'
        else echo '  image owner OK (167:167)'; fi

        echo '  done'
    " || { echo "  ERROR: prepare failed on ${ip}"; exit 1; }
done

# ============================================================
# Step 2: Bootstrap Ceph on PRIMARY
# ============================================================

echo ""
echo ">>> Step 2: Bootstrapping Ceph on ${PRIMARY}..."

_run "${PRIMARY}" "
    set -e
    if [ -d /etc/ceph ] && [ -f /etc/ceph/ceph.conf ]; then
        echo '  Ceph already bootstrapped, skipping.'
    else
        # 清上次 bootstrap 失败残留（ceph.conf 不存在 = 非活集群，安全；§2.3 守卫：仅清固定目录下一级）
        # 注意：必须 sudo bash -c 让 glob 由 root shell 展开 —— /var/lib/ceph 是 750 167:167，
        # 非 root shell 无权限读目录 → glob 不展开 → rm 收到字面量 '*' 静默失败
        sudo rm -f /etc/ceph/ceph.pub 2>/dev/null || true
        [ -d /var/lib/ceph ] && sudo bash -c 'rm -rf /var/lib/ceph/*' 2>/dev/null || true
        [ -d /var/log/ceph ] && sudo bash -c 'rm -rf /var/log/ceph/*' 2>/dev/null || true
        echo '  Running cephadm bootstrap...'
        # 失败必须显式退出：原 \"| grep ... || true\" 写法会吞掉 bootstrap 失败，
        # 导致后续 orch/pool 步骤在没有 mon 的残缺集群上空跑且报误导性错误
        # --skip-pull 必须加：cephadm bootstrap 默认重新 pull 镜像，
        # 会把 Step 1 里 commit 修复的 v17 tag 重新指回上游原始镜像（750 root:root），
        # 导致镜像权限修复被静默冲掉（extract_uid_gid=0:0 → mon 目录 root 0700 → EACCES）
        sudo cephadm --image ${CEPH_CONTAINER_IMAGE} bootstrap \
            --mon-ip ${CEPH_PRIMARY_MON_IP} \
            --skip-pull \
            --allow-fqdn-hostname \
            --skip-prepare-host \
            --skip-dashboard \
            --skip-monitoring-stack > /tmp/cephadm-bootstrap.log 2>&1 || {
            echo '  ERROR: cephadm bootstrap FAILED. Last 20 lines:'
            tail -20 /tmp/cephadm-bootstrap.log
            exit 1
        }
        grep -v 'Inferring\|Using ceph\|quay.io' /tmp/cephadm-bootstrap.log || true
        echo '  Bootstrap complete.'
        # 钉死后续所有 daemon（OSD/mgr）用同一镜像，防 cephadm 自动升级到 v19
        sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph config set global container_image ${CEPH_CONTAINER_IMAGE} 2>/dev/null || true
    fi
    # cephadm 模块实际读 mgr/cephadm/container_image（global container_image 不被使用）。
    # 显式钉到 tag：镜像 755 修复走 podman commit 会换镜像 ID，tag 始终指向修复后的镜像，
    # 防止 cephadm 继续引用修复前的旧 SHA（§SYSTEM-SAFETY-SKILL 1.3 已确认）。
    sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph config set mgr mgr/cephadm/container_image ${CEPH_CONTAINER_IMAGE} 2>/dev/null || true
" || { echo "  ERROR: bootstrap failed"; exit 1; }

# ============================================================
# Step 2b: Dual network configuration
# ============================================================

echo ""
echo ">>> Step 2b: Configuring dual network..."

# 拆为独立 _run（内联多长块在三层 SSH 下假成功——实测只执行到一半）
for _cfg in "global public_network ${CEPH_PUBLIC_NETWORK}" \
            "global cluster_network ${CEPH_CLUSTER_NETWORK}" \
            "mon public_network ${CEPH_PUBLIC_NETWORK}" \
            "mon cluster_network ${CEPH_CLUSTER_NETWORK}"; do
    # mon 级别覆盖必须显式设，否则 mon 一直用 bootstrap 时的网段
    _run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph config set ${_cfg} 2>/dev/null" 2>/dev/null || true
done
echo "  public_network  = ${CEPH_PUBLIC_NETWORK}  (${PUBLIC_NIC})"
echo "  cluster_network = ${CEPH_CLUSTER_NETWORK}  (${CLUSTER_NIC})"

# ============================================================
# Step 3: Root SSH between Ceph nodes + add secondary nodes
# ============================================================

echo ""
echo ">>> Step 3: Root SSH setup + adding secondary nodes..."

# Extract cephadm SSH public key
_CEPH_PUB=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph config-key get mgr/cephadm/ssh_identity_pub 2>/dev/null" 2>/dev/null || echo "")
if [ -n "${_CEPH_PUB}" ]; then
    for ip in "${CEPH_SERVERS[@]}"; do
        _run "${ip}" "
            sudo mkdir -p /root/.ssh
            echo '${_CEPH_PUB}' | sudo tee /root/.ssh/authorized_keys >/dev/null
            sudo chmod 600 /root/.ssh/authorized_keys
            sudo chown -R root:root /root/.ssh
        " 2>/dev/null || true
    done
fi

# Extract cephadm SSH private key
_CEPH_PRIV=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph config-key get mgr/cephadm/ssh_identity_key 2>/dev/null" 2>/dev/null || echo "")
if [ -n "${_CEPH_PRIV}" ]; then
    for ip in "${CEPH_SERVERS[@]}"; do
        _run "${ip}" "
            echo '${_CEPH_PRIV}' | sudo tee /root/.ssh/id_rsa >/dev/null
            sudo chmod 600 /root/.ssh/id_rsa
            sudo chown root:root /root/.ssh/id_rsa
        " 2>/dev/null || true
    done
fi
echo "  Root SSH keys deployed on all nodes."

# Add secondary nodes
for i in 1 2; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"
    echo "  Adding ${hostname} (${ip})..."
    _run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph orch host add ${hostname} ${ip} 2>&1" 2>/dev/null || echo "  (may already exist)"
    _run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph orch host label add ${hostname} _admin 2>/dev/null" || true
done

# Apply MON placement on all 3 nodes
_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph orch apply mon 'ceph-node1,ceph-node2,ceph-node3' 2>/dev/null || true"
echo "  Waiting for MON+MGR on all nodes (60s)..."
sleep 60

HOST_COUNT=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph orch host ls --format json 2>/dev/null" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "  Hosts online: ${HOST_COUNT} (expected 3)"

# ============================================================
# Step 3b: Extract bootstrap-osd keyring for ceph-volume
# ============================================================
# cephadm stores keyring inside /var/lib/ceph/<fsid>/, but ceph-volume
# (running on host) looks at /var/lib/ceph/bootstrap-osd/ceph.keyring.
# Extract from Ceph auth DB and place at the expected path on all nodes.

echo ""
echo ">>> Step 3b: Extracting bootstrap-osd keyring for ceph-volume..."
# 加固：cephadm shell 偶发失败（三层 SSH/mgr 未就绪），重试 3 次仍失败即停
# （bootstrap-osd keyring 是 ceph-volume 创建 OSD 的硬依赖，缺失会让后续 OSD 部署静默失败）
BOSD_KEYRING=""
for _try in 1 2 3; do
    BOSD_KEYRING=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph auth get client.bootstrap-osd 2>/dev/null | grep -v exported" 2>/dev/null)
    [ -n "${BOSD_KEYRING}" ] && break
    echo "  [retry ${_try}/3] bootstrap-osd keyring extract, sleep 10s..."
    sleep 10
done
[ -n "${BOSD_KEYRING}" ] || { echo "  ERROR: bootstrap-osd keyring extract failed after 3 attempts"; exit 1; }
BOSD_B64=$(echo "${BOSD_KEYRING}" | base64 -w0)
for ip in "${CEPH_SERVERS[@]}"; do
    echo -n "  ${ip}: "
    _run "${ip}" "sudo mkdir -p /var/lib/ceph/bootstrap-osd && echo '${BOSD_B64}' | base64 -d | sudo tee /var/lib/ceph/bootstrap-osd/ceph.keyring > /dev/null && sudo chmod 600 /var/lib/ceph/bootstrap-osd/ceph.keyring && echo OK" 2>/dev/null
done

# ============================================================
# Step 4: Deploy 6 OSDs via ceph orch (DATA on NVMe, DB/WAL on tmpfs)
# ============================================================
# DATA: NVMe → PV → VG → LV
# DB/WAL: tmpfs → file → loop → PV → VG → LV
# 三者均为 LV，通过 ceph orch daemon add osd 一步部署
# OSD 由 cephadm 容器管理（非宿主机进程），HEALTH_OK 无 stray daemon
# ============================================================

echo ""
echo ">>> Step 4: Deploying OSDs (ceph orch, DATA on NVMe, DB/WAL on tmpfs)..."

OSD_SEQ=0
for i in "${!CEPH_SERVERS[@]}"; do
    ip="${CEPH_SERVERS[$i]}"
    hostname="ceph-node$((i + 1))"

    for dev in "${CEPH_OSD_DEVICES_PER_NODE[@]}"; do
        OSD_SEQ=$((OSD_SEQ + 1))
        echo "  ${hostname}: ${dev} (OSD #${OSD_SEQ})..."

        # Wipe data disk
        _run "${ip}" "
            sudo umount ${dev} 2>/dev/null || true
            sudo sgdisk -Z ${dev} 2>/dev/null || true
            sudo wipefs -af ${dev} 2>/dev/null || true
            sudo partprobe ${dev} 2>/dev/null || true
        " 2>/dev/null || true

        sleep 2

        # Prepare DATA/DB/WAL LVs on the target node
        _run "${ip}" "
            set -e
            DBWAL_MNT='${CEPH_DB_WAL_MOUNT:-/mnt/dbwal}'
            DB_SIZE='${CEPH_DB_SIZE:-40G}'
            WAL_SIZE='${CEPH_WAL_SIZE:-10G}'

            # Ensure tmpfs mounted
            sudo mountpoint -q \${DBWAL_MNT} 2>/dev/null || {
                sudo mkdir -p \${DBWAL_MNT}
                sudo mount -t tmpfs -o size=${CEPH_DB_WAL_TMPFS_SIZE:-200G} tmpfs \${DBWAL_MNT}
            }

            # Create DB + WAL files on tmpfs
            db_file=\${DBWAL_MNT}/db-osd${OSD_SEQ}.img
            wal_file=\${DBWAL_MNT}/wal-osd${OSD_SEQ}.img
            sudo rm -f \${db_file} \${wal_file}
            sudo truncate -s \${DB_SIZE} \${db_file}
            sudo truncate -s \${WAL_SIZE} \${wal_file}

            # Create loop devices + LVM LVs for DB/WAL
            db_loop=\$(sudo losetup -f --show \${db_file})
            wal_loop=\$(sudo losetup -f --show \${wal_file})
            db_vg=ceph-vg-db${OSD_SEQ}
            wal_vg=ceph-vg-wal${OSD_SEQ}
            sudo pvcreate -ff -y \${db_loop} 2>/dev/null || true
            sudo pvcreate -ff -y \${wal_loop} 2>/dev/null || true
            sudo vgcreate \${db_vg} \${db_loop} 2>/dev/null || true
            sudo vgcreate \${wal_vg} \${wal_loop} 2>/dev/null || true
            sudo lvremove -f \${db_vg} 2>/dev/null || true
            sudo lvremove -f \${wal_vg} 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd-db \${db_vg}
            sudo lvcreate -l 100%FREE -n osd-wal \${wal_vg}
            sudo dmsetup mknodes 2>/dev/null || true
            echo \"  DB LV: /dev/\${db_vg}/osd-db (on \${db_loop})\"
            echo \"  WAL LV: /dev/\${wal_vg}/osd-wal (on \${wal_loop})\"

            # Create LVM LV for DATA
            data_vg=ceph-vg-osd${OSD_SEQ}
            sudo pvcreate -ff -y ${dev} 2>/dev/null || true
            sudo vgcreate \${data_vg} ${dev} 2>/dev/null || true
            sudo lvremove -f \${data_vg} 2>/dev/null || true
            sudo lvcreate -l 100%FREE -n osd \${data_vg}
            echo \"  DATA LV: /dev/\${data_vg}/osd\"
        " || { echo "  ERROR: LV preparation failed on ${ip}:${dev}"; exit 1; }

        # Deploy OSD via ceph orch (cephadm-managed container)
        data_lv="/dev/ceph-vg-osd${OSD_SEQ}/osd"
        db_lv="/dev/ceph-vg-db${OSD_SEQ}/osd-db"
        wal_lv="/dev/ceph-vg-wal${OSD_SEQ}/osd-wal"
        echo "  Deploying via ceph orch: data=${data_lv} db=${db_lv} wal=${wal_lv}"
        result=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph orch daemon add osd ${hostname}:data_devices=${data_lv},db_devices=${db_lv},wal_devices=${wal_lv} 2>&1" 2>/dev/null)
        if echo "${result}" | grep -q "Created"; then
            echo "  ${result}" | grep "Created"
        else
            echo "  WARNING: ${result}"
        fi
    done
done

echo "  Waiting for OSDs (90s)..."
sleep 90

# 加固：OSD 计数循环等待（最多再补 3×30s），不足 6 即停（ceph orch 创建是异步的，
# 偶发慢于预期；不满足 6 个直接判失败，避免带着残缺集群往下走）
OSD_COUNT=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph osd stat 2>/dev/null" | grep -oP '\d+(?= osds)' || echo "0")
for _try in 1 2 3; do
    [ "${OSD_COUNT}" -ge 6 ] && break
    echo "  OSDs: ${OSD_COUNT}/6, waiting 30s more (retry ${_try}/3)..."
    sleep 30
    OSD_COUNT=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph osd stat 2>/dev/null" | grep -oP '\d+(?= osds)' || echo "0")
done
echo "  OSDs: ${OSD_COUNT} (expected 6)"
[ "${OSD_COUNT}" -ge 6 ] || { echo "  ERROR: only ${OSD_COUNT}/6 OSDs up"; exit 1; }

echo ""
echo ">>> OSD tree:"
_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph osd tree 2>/dev/null" 2>/dev/null || true

echo ""
echo ">>> Ceph health:"
_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph health 2>/dev/null" 2>/dev/null || true

# ============================================================
# Step 5: Create EC pool + cephx client
# ============================================================

echo ""
echo ">>> Step 5: Creating EC ${CEPH_EC_K}+${CEPH_EC_M} pool (${CEPH_POOL_NAME})..."

# 单命令 ceph 调用封装：三层 SSH 下"单次 _run 内嵌多次 cephadm shell"的超长块会
# 假成功（实测只执行到一半，profile/pool/auth 从未真创建——反复"消失"的真凶）。
# 拆成每次 _run 一次 cephadm shell + 独立验证（deep-health-check 已验证的可靠模式）。
_ceph() { _run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph $* 2>/dev/null" 2>/dev/null; }

# 1) 等 mon quorum 稳定（apply mon 后新 mon 同步 store 需时间，窗口期写入不可靠）
for _t in $(seq 1 9); do
    _q=$(_ceph "-s" | grep -oE 'quorum [a-z0-9,-]+' | grep -c 'ceph-node3' || true)
    [ "${_q}" = "1" ] && break
    echo "  waiting for 3-mon quorum (${_t}/9)..."; sleep 20
done
_ceph "-s" | grep -E 'mon:' || true
echo '  quorum stable, settling 20s...'; sleep 20

# 2) EC profile（写 + 内容级验证，重试 3 次）
for _t in 1 2 3; do
    _ceph "osd erasure-code-profile set ec-prod k=${CEPH_EC_K} m=${CEPH_EC_M} crush-failure-domain=${CEPH_FAILURE_DOMAIN} plugin=jerasure technique=reed_sol_van" >/dev/null || true
    _ceph "osd erasure-code-profile get ec-prod" | grep -q "^k=${CEPH_EC_K}\$" && break
    echo "  [retry ${_t}/3] ec profile"; sleep 10
    [ ${_t} = 3 ] && { echo "  ERROR: ec profile failed"; exit 1; }
done
echo '  ec profile OK'

# 3) EC pool（先查存在；创建+验证；再设属性）
if ! _ceph "osd pool ls" | grep -q "^${CEPH_POOL_NAME}\$"; then
    for _t in 1 2 3; do
        _ceph "osd pool create ${CEPH_POOL_NAME} ${CEPH_PG_NUM} ${CEPH_PG_NUM} erasure ec-prod" >/dev/null && break
        echo "  [retry ${_t}/3] pool create"; sleep 10
    done
fi
_ceph "osd pool ls" | grep -q "^${CEPH_POOL_NAME}\$" || { echo "  ERROR: pool ${CEPH_POOL_NAME} create failed"; exit 1; }
_ceph "osd pool set ${CEPH_POOL_NAME} allow_ec_overwrites true" || true
_ceph "osd pool set ${CEPH_POOL_NAME} fast_read true" || true
_ceph "osd pool application enable ${CEPH_POOL_NAME} juicefs" || true
echo '  ec pool OK'

# 4) cephx client.juicefs（重试 + key 非空验证）
for _t in 1 2 3; do
    _ceph "auth get-or-create client.juicefs mon 'allow r' osd 'allow class-read object_prefix rbd_directory_pool, allow rwx pool=${CEPH_POOL_NAME}'" >/dev/null && break
    echo "  [retry ${_t}/3] auth get-or-create"; sleep 10
done
_ceph "auth get client.juicefs" | grep -q 'key =' || { echo "  ERROR: client.juicefs auth get failed (empty key)"; exit 1; }
echo '  cephx client.juicefs OK'

# 5) 稳定期二次验证闭环（任一缺失则幂等重建，最多 3 轮）
for _r in 1 2 3; do
    sleep 45
    _ok=1
    _ceph "osd erasure-code-profile get ec-prod" | grep -q "^k=${CEPH_EC_K}\$" || _ok=0
    _ceph "osd pool ls" | grep -q "^${CEPH_POOL_NAME}\$" || _ok=0
    _ceph "auth get client.juicefs" | grep -q 'key =' || _ok=0
    [ "${_ok}" = "1" ] && break
    echo "  [stability ${_r}/3] profile/pool/auth vanished, recreating..."
    _ceph "osd erasure-code-profile set ec-prod k=${CEPH_EC_K} m=${CEPH_EC_M} crush-failure-domain=${CEPH_FAILURE_DOMAIN} plugin=jerasure technique=reed_sol_van" || true
    _ceph "osd pool ls" | grep -q "^${CEPH_POOL_NAME}\$" || \
        _ceph "osd pool create ${CEPH_POOL_NAME} ${CEPH_PG_NUM} ${CEPH_PG_NUM} erasure ec-prod" || true
    _ceph "osd pool set ${CEPH_POOL_NAME} allow_ec_overwrites true" || true
    _ceph "osd pool set ${CEPH_POOL_NAME} fast_read true" || true
    _ceph "osd pool application enable ${CEPH_POOL_NAME} juicefs" || true
    _ceph "auth get-or-create client.juicefs mon 'allow r' osd 'allow class-read object_prefix rbd_directory_pool, allow rwx pool=${CEPH_POOL_NAME}'" || true
done
# 终验
_ok=1
_ceph "osd erasure-code-profile get ec-prod" | grep -q "^k=${CEPH_EC_K}\$" || _ok=0
_ceph "osd pool ls" | grep -q "^${CEPH_POOL_NAME}\$" || _ok=0
_ceph "osd pool get ${CEPH_POOL_NAME} fast_read" | grep -q "1" || _ok=0
_ceph "auth get client.juicefs" | grep -q 'key =' || _ok=0
[ "${_ok}" = "1" ] || { echo "  ERROR: profile/pool/auth not stable after 3 rounds"; exit 1; }
echo '  profile/pool/auth stable (survived 45s×3 checks)'

# ============================================================
# Step 6: Copy ceph.conf + keyring to 157 (JuiceFS client node)
# ============================================================

echo ""
echo ">>> Step 6: Copying ceph.conf + keyring to ${CLIENT_SERVER} (JuiceFS client)..."

# 加固：传输路径统一到 config.sh 标准三层跳板（WSL→HK→157），
# 弃用 150→157 的 sshpass stdin 流式复制（实测会"返回 0 但内容为空"）。
# base64 作为命令参数传输，截断即 base64 -d 失败（显式错误，不假成功）。
_copy_to_157() {
    # _copy_to_157 <150_src_path> <157_dest_name>
    local src="$1" dst="$2" b64
    b64=$(_run "${PRIMARY}" "sudo base64 -w0 ${src}" 2>/dev/null | tr -d '[:space:]')
    [ -n "${b64}" ] || { echo "  ERROR: read ${src} on ${PRIMARY} failed"; return 1; }
    ssh_to_client "echo '${b64}' | base64 -d | sudo tee /etc/ceph/${dst} > /dev/null && echo \"  ${dst} -> 157 OK\"" \
        || { echo "  ERROR: write ${dst} to 157 failed"; return 1; }
}

_copy_to_157 /etc/ceph/ceph.conf ceph.conf \
    || exit 1
_copy_to_157 /etc/ceph/ceph.client.admin.keyring ceph.client.admin.keyring \
    || exit 1

# juicefs keyring：150 上 ceph auth get 提取（重试 3 次），再传到 157
_jfs_b64=""
for _t in 1 2 3; do
    _jfs_b64=$(_run "${PRIMARY}" "sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph auth get client.juicefs 2>/dev/null | grep -v exported | base64 -w0" 2>/dev/null | tr -d '[:space:]')
    [ -n "${_jfs_b64}" ] && break
    echo "  [retry ${_t}/3] extract client.juicefs, sleep 10s..."; sleep 10
done
[ -n "${_jfs_b64}" ] || { echo "  ERROR: extract client.juicefs failed"; exit 1; }
ssh_to_client "echo '${_jfs_b64}' | base64 -d | sudo tee /etc/ceph/ceph.client.juicefs.keyring > /dev/null && echo '  ceph.client.juicefs.keyring -> 157 OK'" \
    || { echo "  ERROR: write juicefs keyring to 157 failed"; exit 1; }

# 157 端验证三文件非空
ssh_to_client "
    ok=true
    for f in /etc/ceph/ceph.conf /etc/ceph/ceph.client.admin.keyring /etc/ceph/ceph.client.juicefs.keyring; do
        [ -s \"\$f\" ] || { echo \"  MISSING/EMPTY: \$f\"; ok=false; }
    done
    \$ok && echo '  keyring verified on 157 (3 files non-empty)' || exit 1
" || { echo "  ERROR: keyring verify on 157 failed"; exit 1; }

# ============================================================
# Done
# ============================================================

echo ""
echo "========================================"
echo "Ceph Deployment Complete (NO RGW — direct RADOS)!"
echo "========================================"
echo ""
echo "EC pool:    ${CEPH_POOL_NAME} (${CEPH_EC_K}+${CEPH_EC_M}, allow_ec_overwrites=true, fast_read=true)"
echo "Cephx user: ${CEPHX_CLIENT}"
echo "Network:    public=${CEPH_PUBLIC_NETWORK}  cluster=${CEPH_CLUSTER_NETWORK}"
echo "DB/WAL:     tmpfs 内存盘 (loop device, ⚠️ 测试专用—断电丢)"
echo ""
echo "Next: bash scripts/deploy-juicefs.sh format"
echo ""
echo "Cluster status:"
echo "  _run ${PRIMARY} 'sudo cephadm --image ${CEPH_CONTAINER_IMAGE} shell -- ceph status'"
