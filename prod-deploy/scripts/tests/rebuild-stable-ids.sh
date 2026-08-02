#!/bin/bash
set -e

# rebuild-stable-ids.sh  [v2 2026-07-23]
# Stable-ID 重建：ceph osd destroy + ceph-volume lvm create --osd-id
# 保持 OSD ID 0-5 不变、不删 pool → CRUSH PG→OSD 映射跨重建一致
#
# v2 修复（见 pre-skills/stable-rebuild-skill.md）：
#   - Step 1: systemctl mask+stop 替代 pkill（systemd 自动重启问题）
#   - Step 2: ceph osd down + 验证 destroyed 标志（destroy 对 up OSD 无效）
#   - Step 4: LVM 创建后验证（node 3 曾静默失败）

SLAVES=(10.20.1.150 10.20.1.151 10.20.1.152)
HOSTS=(ceph-node1 ceph-node2 ceph-node3)
DEVS=(/dev/nvme2n1 /dev/nvme3n1)
DBWAL_MNT=/mnt/dbwal
DB_SIZE=40G
WAL_SIZE=10G
SSHPASS="sshpass -p Sunrise@801 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR sunrise"

# OSD ID 到 (node_index, device) 的映射
# node 0=150: osd.0=nvme2n1, osd.1=nvme3n1
# node 1=151: osd.2=nvme2n1, osd.3=nvme3n1
# node 2=152: osd.4=nvme2n1, osd.5=nvme3n1
OSD_MAP=("0:0:0" "1:0:1" "2:1:0" "3:1:1" "4:2:0" "5:2:1")

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Step 0: 【前置门禁 2026-07-24】mon quorum 必须健康才允许重建。
# 教训：mon 亚健康（如 3-mon 退化到单 mon、probing 无 quorum）时跑 create，
#   ceph osd new 请求会堆积把 mon 彻底拖 hung（398 slow ops 事故）。
# 门禁：ceph -s 必须在 25s 内返回、HEALTH 非 mon 相关错误、且 mon quorum 数 == monmap 中 mon 数。
# 不满足 → 直接退出，不进入任何 destroy/create（见 pre-skills/cluster-rebuild-skill.md §三.F）。
log ">>> Step 0: mon quorum 前置门禁"
MON_CHECK_IP=${SLAVES[0]}
qs=$($SSHPASS@$MON_CHECK_IP "sudo timeout 25 ceph quorum_status --format json 2>/dev/null" 2>/dev/null)
if [ -z "$qs" ]; then
  log "  🔴 ceph quorum_status 超时/无输出 → mon 无响应（可能单 mon probing）。禁止重建。"
  log "     排查见 pre-skills/cluster-rebuild-skill.md §三.F（mon 容器 hung / monmap 退化）。停下报告，勿跑 create。"
  exit 1
fi
mon_in_quorum=$(echo "$qs" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['quorum']))" 2>/dev/null || echo 0)
mon_in_map=$(echo "$qs" | python3 -c "import sys,json;print(len(json.load(sys.stdin)['monmap']['mons']))" 2>/dev/null || echo 0)
if [ "$mon_in_quorum" -lt 1 ] || [ "$mon_in_quorum" -ne "$mon_in_map" ]; then
  log "  🔴 mon quorum 不健康：quorum=${mon_in_quorum} / monmap=${mon_in_map}（不相等或为 0）。禁止重建。"
  log "     monmap 里可能挂着已消失的 mon（如 node1/node2），需先 monmap 手术恢复 quorum（cluster-rebuild-skill §三.F）。停下报告。"
  exit 1
fi
log "  ✅ mon quorum 健康：${mon_in_quorum}/${mon_in_map} in quorum"

# Step 1: Stop OSDs (systemctl mask+stop, NOT just pkill — systemd auto-restarts)
log ">>> Step 1: Stop+mask ceph-osd on all nodes (systemctl mask+stop)"
for ip in "${SLAVES[@]}"; do
  $SSHPASS@$ip '
    for id in $(systemctl list-units "ceph-osd@*" --no-legend 2>/dev/null | awk "{print \$1}" | grep -oP "osd@\K[0-9]+"); do
      sudo systemctl mask ceph-osd@${id} 2>/dev/null || true
      sudo systemctl stop ceph-osd@${id} 2>/dev/null || true
    done
    sudo pkill -9 ceph-osd 2>/dev/null || true
  ' 2>/dev/null || true
  echo "  ${ip} stopped"
done
sleep 3
# 验证所有 OSD 进程已停止
ALL_STOPPED=true
for ip in "${SLAVES[@]}"; do
  running=$($SSHPASS@$ip "pgrep ceph-osd 2>/dev/null | head -1" 2>/dev/null)
  if [ -n "$running" ]; then
    log "  ⚠️ ${ip} 仍有 ceph-osd 进程 (pid=$running)!"
    ALL_STOPPED=false
  fi
done
if $ALL_STOPPED; then
  log "  ✅ 所有节点 ceph-osd 已停止"
else
  log "  ⚠️ 部分节点仍有进程，继续但 destroy 可能无效"
fi

# Step 2: Mark down + Destroy OSDs (keep ID + crush + auth, NOT purge)
log ">>> Step 2: ceph osd down + destroy (keep IDs)"
for entry in "${OSD_MAP[@]}"; do
  osd_id=${entry%%:*}
  sudo ceph osd down ${osd_id} 2>/dev/null || true
done
sleep 5
for entry in "${OSD_MAP[@]}"; do
  osd_id=${entry%%:*}
  log "  Destroying osd.${osd_id}..."
  sudo ceph osd destroy ${osd_id} --yes-i-really-mean-it 2>/dev/null || true
done
sleep 3
# Step 2b: 验证 destroyed 标志（关键！ceph-volume --osd-id 需要此标志才能复用 ID）
log ">>> Step 2b: 验证 destroyed 标志"
DESTROY_OK=true
for entry in "${OSD_MAP[@]}"; do
  osd_id=${entry%%:*}
  state=$(sudo ceph osd info ${osd_id} 2>/dev/null | grep -oP 'destroyed' || true)
  if [ -n "$state" ]; then
    log "  osd.${osd_id}: ✅ destroyed"
  else
    log "  osd.${osd_id}: ❌ NOT destroyed — 需排查（OSD 可能仍 up）"
    DESTROY_OK=false
  fi
done
if ! $DESTROY_OK; then
  log "⚠️ 部分 OSD 未正确 destroy，ceph-volume create 将失败。请先确保 OSD 已 down。"
  log "  尝试重新 destroy..."
  for entry in "${OSD_MAP[@]}"; do
    osd_id=${entry%%:*}
    sudo ceph osd down ${osd_id} 2>/dev/null || true
  done
  sleep 10
  for entry in "${OSD_MAP[@]}"; do
    osd_id=${entry%%:*}
    state=$(sudo ceph osd info ${osd_id} 2>/dev/null | grep -oP 'destroyed' || true)
    if [ -z "$state" ]; then
      log "  osd.${osd_id}: 重新 destroy..."
      sudo ceph osd destroy ${osd_id} --yes-i-really-mean-it 2>/dev/null || true
    fi
  done
  sleep 3
fi

# Step 3: Clean LVM/dm/tmpfs on all nodes
log ">>> Step 3: Clean LVM/dm/tmpfs on all nodes"
for ip in "${SLAVES[@]}"; do
  $SSHPASS@$ip "sudo bash /tmp/cleanup-node.sh" 2>/dev/null || true
done

# Step 4: Recreate LVMs (using OSD ID in VG name)
log ">>> Step 4: Recreate LVMs with stable VG names (osd-id based)"
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}; host=${HOSTS[$node_idx]}; dev=${DEVS[$dev_idx]}
  osd_seq=$((osd_id + 1))

  log "  ${host}: osd.${osd_id} on ${dev}"
  $SSHPASS@$ip bash -s << EOF
set -e
db_file=${DBWAL_MNT}/db-osd${osd_seq}.img
wal_file=${DBWAL_MNT}/wal-osd${osd_seq}.img
sudo truncate -s ${DB_SIZE} \$db_file
sudo truncate -s ${WAL_SIZE} \$wal_file
db_loop=\$(sudo losetup -f --show \$db_file)
wal_loop=\$(sudo losetup -f --show \$wal_file)
db_vg=ceph-vg-db${osd_seq}
wal_vg=ceph-vg-wal${osd_seq}
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
echo "  OK: osd${osd_seq} on ${host}"
EOF
done
log "  All LVs prepared"

# Step 4b: 验证 LVMs（node 3 曾在此步静默失败）
log ">>> Step 4b: 验证 LVMs"
for ip in "${SLAVES[@]}"; do
  count=$($SSHPASS@$ip "sudo lvs --noheadings -o vg_name,lv_name 2>/dev/null | grep ceph | wc -l" 2>/dev/null || echo 0)
  if [ "$count" -ge 6 ]; then
    log "  ${ip}: ✅ ${count} LVs"
  else
    log "  ${ip}: ❌ 只有 ${count} LVs（应为 6）— 需手动修复"
  fi
done

# Step 5: Create OSDs with same IDs (NOT ceph orch)
log ">>> Step 5: ceph-volume lvm create --osd-id (preserve IDs)"
# Unmask services first
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}
  $SSHPASS@$ip "sudo systemctl unmask ceph-osd@${osd_id} 2>/dev/null || true" 2>/dev/null || true
done
sleep 5
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}; host=${HOSTS[$node_idx]}
  osd_seq=$((osd_id + 1))
  data_lv="/dev/ceph-vg-osd${osd_seq}/osd"
  db_lv="/dev/ceph-vg-db${osd_seq}/osd-db"
  wal_lv="/dev/ceph-vg-wal${osd_seq}/osd-wal"
  log "  ${host}: osd.${osd_id}"
  $SSHPASS@$ip "sudo ceph-volume lvm create --bluestore --osd-id ${osd_id} --data ${data_lv} --block.db ${db_lv} --block.wal ${wal_lv} --crush-device-class ssd 2>&1 | tail -5"
  sleep 2
done

# Step 5b: 【路线乙 2026-07-24】保证交付 restart-safe 集群（见 pre-skills/stable-rebuild-skill.md 问题 11）
# 背景：ceph-volume lvm create 若检测到 LV 已 prepare 会跳过 osd new → destroyed 标志残留；
#   或 destroy 删了 auth 后未重建 key。任一残留 → 后续 softclean 的 OSD restart 会触发
#   "osdmap says I am destroyed" 而退出（02-2-H 事故）。此处逐 OSD 校验并用 rm+new+activate 补齐。
# ⚑ 已实测 rm+new 不改 CRUSH 拓扑（weight/host 位置保留）→ CRUSH md5 不变，stable-ID 安全。
log ">>> Step 5b: 校验 restart-safe（destroyed 标志清 + auth 齐），不齐则 rm+new+activate 补齐"
sleep 5
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}
  # (1) 取该 OSD 的真实 fsid（优先 ceph-volume lvm list，回退 LV tag）
  fsid=$($SSHPASS@$ip "sudo ceph-volume lvm list ${osd_id} 2>/dev/null | grep -m1 'osd fsid' | awk '{print \$NF}'" 2>/dev/null)
  # (2) 检查 destroyed 标志
  is_destroyed=$(sudo ceph osd dump 2>/dev/null | grep -E "^osd\.${osd_id} " | grep -o destroyed || true)
  # (3) 检查 auth key
  has_auth=$(sudo ceph auth get osd.${osd_id} 2>/dev/null | grep -o "key" || true)
  if [ -n "$is_destroyed" ] || [ -z "$has_auth" ]; then
    log "  osd.${osd_id}: 需补齐 (destroyed=${is_destroyed:-no} auth=${has_auth:-MISSING} fsid=${fsid:-?})"
    if [ -z "$fsid" ]; then
      log "  ⚠️ osd.${osd_id} 取不到 fsid，跳过自动补齐，须人工处理（ceph-volume lvm list ${osd_id}）"
      continue
    fi
    sudo ceph auth rm osd.${osd_id} 2>/dev/null || true   # 清残留 auth（问题 5）
    sudo ceph osd rm ${osd_id} 2>/dev/null || true        # 从 OSDMap 移除 → 清 destroyed 标志
    sudo ceph osd new ${fsid} ${osd_id} 2>/dev/null || true  # 用真实 fsid 关联回同 ID（不改 CRUSH）
    $SSHPASS@$ip "sudo vgchange -ay 2>/dev/null; sudo ceph-volume lvm activate ${osd_id} ${fsid} 2>&1 | tail -3" 2>/dev/null || true
    sleep 3
    # 复验
    still=$(sudo ceph osd dump 2>/dev/null | grep -E "^osd\.${osd_id} " | grep -o destroyed || true)
    au=$(sudo ceph auth get osd.${osd_id} 2>/dev/null | grep -o "key" || true)
    [ -z "$still" ] && [ -n "$au" ] && log "  osd.${osd_id}: ✅ 已 restart-safe" || log "  osd.${osd_id}: 🔴 仍未补齐(destroyed=${still:-no} auth=${au:-MISSING})，须人工排查"
  else
    log "  osd.${osd_id}: ✅ restart-safe (未 destroyed + auth 齐)"
  fi
done

# Step 6: Start any OSDs that didn't auto-start
log ">>> Step 6: Ensure all OSDs started"
sleep 10
for entry in "${OSD_MAP[@]}"; do
  IFS=':' read osd_id node_idx dev_idx <<< "$entry"
  ip=${SLAVES[$node_idx]}
  $SSHPASS@$ip "sudo systemctl reset-failed ceph-osd@${osd_id} 2>/dev/null || true; sudo systemctl start ceph-osd@${osd_id} 2>/dev/null || true" 2>/dev/null || true
done

# Step 7: Wait for PG active+clean
log ">>> Step 7: Waiting for PG active+clean..."
for i in $(seq 1 60); do
  pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
  echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
  sleep 5
done
log "  $(sudo ceph -s 2>/dev/null | grep -E 'osd:|pgs:' | head -2 | tr '\n' ' ')"

# Step 8: Fix .mgr pool if needed
if sudo ceph -s 2>/dev/null | grep -q "stale\|down"; then
  log ">>> Step 8: Fixing .mgr pool..."
  sudo ceph config set mon mon_allow_pool_delete true 2>/dev/null || true
  sudo ceph osd pool delete .mgr .mgr --yes-i-really-really-mean-it 2>/dev/null || true
  sudo ceph mgr fail 2>/dev/null || true
  sleep 30
fi

# Step 9: Pool - keep existing (preserve pool ID for stable CRUSH mapping)
log ">>> Step 9: Check/recreate EC pool..."
if sudo ceph osd pool ls 2>/dev/null | grep -q "^juicefs-data$"; then
  log "  Pool juicefs-data exists (preserving pool ID for stable CRUSH mapping)"
  for i in $(seq 1 30); do
    pg=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
    echo "$pg" | grep -qE "active\+clean" && break
    sleep 5
  done
else
  log "  Pool not found, creating..."
  sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
  sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
  sudo ceph osd pool set juicefs-data fast_read true 2>/dev/null
  sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null
fi
log "  Pool: $(sudo ceph osd pool get juicefs-data fast_read 2>/dev/null)"

# Step 10: Verify ceph.conf + keyring on 157
log ">>> Step 10: Verify ceph.conf + keyring..."
if [ ! -f /etc/ceph/ceph.conf ]; then
  sudo tee /etc/ceph/ceph.conf > /dev/null << 'CONF'
# minimal ceph.conf for 020ed5ec-8703-11f1-a671-97520597268c
[global]
	fsid = 020ed5ec-8703-11f1-a671-97520597268c
	mon_host = [v2:10.3.1.6:3300/0,v1:10.3.1.6:6789/0] [v2:10.3.1.7:3300/0,v1:10.3.1.7:6789/0] [v2:10.3.1.8:3300/0,v1:10.3.1.8:6789/0]
CONF
  sudo chmod 644 /etc/ceph/ceph.conf
fi
sudo ceph auth get client.juicefs 2>/dev/null | sudo tee /etc/ceph/ceph.client.juicefs.keyring > /dev/null
sudo chmod 644 /etc/ceph/ceph.client.juicefs.keyring

# Verify
log ">>> Verification:"
log "  $(sudo ceph osd stat 2>/dev/null)"
log "  $(sudo ceph osd tree 2>/dev/null | grep osd | head -6 | tr '\n' ' ')"
log "  $(sudo ceph osd pool get juicefs-data fast_read 2>/dev/null)"
log "  $(sudo ceph health 2>/dev/null)"

# 交付门禁（路线乙）：任一 OSD 仍 destroyed / 缺 auth / 存在多余 ID → 显式 FAIL，禁止交付给 02-2-H
log ">>> restart-safe 交付门禁校验"
DESTROY_LEFT=$(sudo ceph osd dump 2>/dev/null | grep -E "^osd\.[0-5] " | grep -c destroyed || echo 0)
OSD_COUNT=$(sudo ceph osd ls 2>/dev/null | wc -l)
NO_AUTH=0
for id in 0 1 2 3 4 5; do sudo ceph auth get osd.${id} 2>/dev/null | grep -q key || NO_AUTH=$((NO_AUTH+1)); done
log "  destroyed 残留=${DESTROY_LEFT}  OSD 总数=${OSD_COUNT}(应为6)  缺 auth 数=${NO_AUTH}"
if [ "${DESTROY_LEFT}" = "0" ] && [ "${OSD_COUNT}" = "6" ] && [ "${NO_AUTH}" = "0" ]; then
  log "  ✅ 交付门禁通过：集群 restart-safe（0 destroyed + 6 OSD + auth 齐），可交付 02-2-H"
else
  log "  🔴🔴 交付门禁未过：集群非 restart-safe！若此时跑 02-2-H，softclean 的 OSD restart 会触发"
  log "       'osdmap says I am destroyed'。禁止交付。按问题 11 手动 rm+new+activate 补齐，或排查多余 OSD ID。"
fi
log ">>> Rebuild (stable IDs) DONE"
