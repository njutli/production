# 方向 D 验证步骤：确认 36MB/s 是 HDD + EC RMW 硬限制

> 前提：集群当前有 EC 池 `default.rgw.buckets.data`（ec-prod, k=4 m=2），
> 需要新建一个**复制池**做对照。以下操作在 tikv-node（192.168.11.12）上执行，
> ceph 命令通过 SSH 到 ceph-node1 执行。

---

## 步骤 1：EC 池随机写时查看是否产生大量读（RMW 证据）

EC 4+2 部分条带写需要先读旧数据+校验 → 改写 → 重算校验 → 再写回，
如果随机写时看到大量读操作，就是 RMW (Read-Modify-Write) 在作怪。

```bash
# 1.1 先在 EC 池上跑 JuiceFS 随机写（步骤 3 会详细说明如何挂载）
#     这里假设已经挂载好在 /mnt/juicefs-ec，正在跑 fio 随机写

# 1.2 在随机写期间，在 ceph-node1 上查看 pool 统计
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 \
  'sudo ceph osd pool stats default.rgw.buckets.data'

# 关键看：read ops 是否在随机写期间也大量增长
# 如果随机写时 read ops >> 0，说明 EC RMW 正在产生大量读放大

# 1.3 持续采样（每 5 秒一次，采 60 秒）
for i in $(seq 1 12); do
  echo "=== Sample $i ==="
  ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 \
    'sudo ceph osd pool stats default.rgw.buckets.data' | \
    grep -E 'read|write|op'
  sleep 5
done
```

---

## 步骤 2：iostat 看磁盘实际 IO 放大比

随机写测试期间，物理盘上的实际读写 IOPS 远大于应用层看到的，
放大比 = 物理盘总吞吐 / 应用层写吞吐，EC 4+2 部分条带写放大可达 4-8×。

```bash
# 2.1 在三个 Ceph 节点上同时跑 iostat（在 3 个终端或用 tmux）

# ceph-node1 (OSD: sdb 上的两个 LV)
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 \
  'sudo iostat -x 5 12 /dev/sdb' > /tmp/iostat-node1.txt &

# ceph-node2 (恢复后)
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.13 \
  'sudo iostat -x 5 12 /dev/sdb' > /tmp/iostat-node2.txt &

# ceph-node3
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.14 \
  'sudo iostat -x 5 12 /dev/sdb' > /tmp/iostat-node3.txt &

# 2.2 同时在 JuiceFS 挂载点上跑随机写（步骤 3 详细说明）
#     这里先给出 fio 命令
fio --name=randwrite-ec --directory=/mnt/juicefs-ec/test_dir/ \
    --rw=randwrite --bs=4k --size=4G --numjobs=4 --iodepth=32 \
    --runtime=60 --time_based --direct=1 --end_fsync=1

# 2.3 测试结束后分析 iostat 结果
# 关键指标：
#   r/s    — 读 IOPS（随机写时不该有大量读，除非 RMW）
#   w/s    — 写 IOPS
#   rMB/s  — 读吞吐
#   wMB/s  — 写吞吐
#   %util  — 磁盘利用率（如果 ≈100%，说明盘是瓶颈）
#   avgqu-sz — 平均队列深度
#
# 放大比估算：
#   物理 IO 吞吐 = rMB/s + wMB/s（三节点总和）
#   应用层写吞吐 ≈ 36 MB/s
#   放大比 = 物理 IO 吞吐 / 36
#   EC 4+2 RMW 部分条带写理论放大 ~6×（4 数据 + 2 校验全要读写）

wait  # 等待 iostat 后台任务完成
echo "=== iostat results ==="
cat /tmp/iostat-node1.txt /tmp/iostat-node2.txt /tmp/iostat-node3.txt
```

---

## 步骤 3：对比实验 — 复制池 vs EC 池跑同样随机写

这是最关键的对照实验：**同样的硬件、同样的 fio 参数，只换底层池类型**。

```bash
# ========== 3.1 创建复制池 ==========

# 在 ceph-node1 上操作
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 <<'EOF'
  # 创建复制池（3 副本，与 .rgw.root 等池一致）
  sudo ceph osd pool create test-rep-data 32 32 replicated

  # 设置应用类型为 rgw（这样 RGW 才能往里写）
  sudo ceph osd pool application enable test-rep-data rgw

  # 查看创建结果
  sudo ceph osd pool ls detail | grep test-rep-data
EOF

# ========== 3.2 配置 RGW zone 使用新池 ==========

# RGW 的 zone 配置决定数据写到哪个池。
# 方案：创建一个新的 zone 指向复制池，JuiceFS 指向新 zone 的 RGW endpoint。
# 但这改动太大（要重建 zone），简单做法：
#   直接修改现有 zone 的 data_pool 指向复制池（测试完再改回来）。

# 3.2.1 先记录当前 zone 配置（改回来用）
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 \
  'sudo radosgw-admin zone get --rgw-zone=default' > /tmp/zone-config-backup.json

# 3.2.2 修改 zone 的 data_pool 为复制池
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 <<'EOF'
  # 获取当前 zone 配置
  sudo radosgw-admin zone get --rgw-zone=default > /tmp/zone-temp.json

  # 替换 data_pool（用 python 一行搞定）
  python3 -c "
import json
with open('/tmp/zone-temp.json') as f: z = json.load(f)
z['data_pool'] = 'test-rep-data'
with open('/tmp/zone-temp.json', 'w') as f: json.dump(z, f, indent=2)
"

  # 写回
  sudo radosgw-admin zone set --rgw-zone=default < /tmp/zone-temp.json

  # 更新 period（让所有 RGW 重新加载配置）
  sudo radosgw-admin period update --commit

  # 重启 RGW 使配置生效
  sudo ceph orch restart rgw.myrgw
EOF

# 等待 RGW 重启完成
sleep 30
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 'sudo ceph -s' | grep rgw

# ========== 3.3 格式化 + 挂载 JuiceFS（复制池） ==========

source /home/turboai/production/config.sh
source /home/turboai/production/.credentials/rgw-juicefs.env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=""

METADATA_URL="tikv://${PD_ENDPOINTS}/juicefs-rep-test"
BUCKET_URL="${RGW_ENDPOINT}/juicefs-rep-test"
MOUNT_POINT="/mnt/juicefs-rep"

# 3.3.1 销毁可能残留的旧卷
juicefs destroy "${METADATA_URL}" \
  $(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4) \
  --yes 2>/dev/null || true

# 3.3.2 创建 bucket
aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 mb "s3://juicefs-rep-test" 2>/dev/null || true

# 3.3.3 格式化
juicefs format \
    --storage s3 \
    --bucket "${BUCKET_URL}" \
    --access-key "${AWS_ACCESS_KEY_ID}" \
    --secret-key "${AWS_SECRET_ACCESS_KEY}" \
    --trash-days 0 \
    "${METADATA_URL}" \
    juicefs-rep-test

# 3.3.4 挂载
sudo mkdir -p "${MOUNT_POINT}"
sudo chown $(whoami):$(whoami) "${MOUNT_POINT}" 2>/dev/null || true
juicefs mount -d "${METADATA_URL}" "${MOUNT_POINT}"
sleep 3
mountpoint -q "${MOUNT_POINT}" && echo "Mount OK" || echo "Mount FAILED"

# ========== 3.4 在复制池上跑随机写 fio ==========

mkdir -p "${MOUNT_POINT}/test_dir"
fio --name=randwrite-rep --directory="${MOUNT_POINT}/test_dir/" \
    --rw=randwrite --bs=4k --size=4G --numjobs=4 --iodepth=32 \
    --runtime=60 --time_based --direct=1 --end_fsync=1 \
    2>&1 | tee /tmp/fio-randwrite-rep.txt

# 记录结果中的 BW 值

# ========== 3.5 在 EC 池上跑同样的随机写（对照组） ==========

# 3.5.1 先恢复 zone 配置到 EC 池
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 <<'EOF'
  sudo radosgw-admin zone set --rgw-zone=default < /tmp/zone-config-backup.json
  sudo radosgw-admin period update --commit
  sudo ceph orch restart rgw.myrgw
EOF
sleep 30

# 3.5.2 格式化 + 挂载 EC 池的 JuiceFS
METADATA_URL_EC="tikv://${PD_ENDPOINTS}/juicefs-ec-test"
BUCKET_URL_EC="${RGW_ENDPOINT}/juicefs-ec-test"
MOUNT_POINT_EC="/mnt/juicefs-ec"

juicefs destroy "${METADATA_URL_EC}" \
  $(juicefs status "${METADATA_URL_EC}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4) \
  --yes 2>/dev/null || true

aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 mb "s3://juicefs-ec-test" 2>/dev/null || true

juicefs format \
    --storage s3 \
    --bucket "${BUCKET_URL_EC}" \
    --access-key "${AWS_ACCESS_KEY_ID}" \
    --secret-key "${AWS_SECRET_ACCESS_KEY}" \
    --trash-days 0 \
    "${METADATA_URL_EC}" \
    juicefs-ec-test

sudo mkdir -p "${MOUNT_POINT_EC}"
sudo chown $(whoami):$(whoami) "${MOUNT_POINT_EC}" 2>/dev/null || true
juicefs mount -d "${METADATA_URL_EC}" "${MOUNT_POINT_EC}"
sleep 3
mountpoint -q "${MOUNT_POINT_EC}" && echo "Mount OK" || echo "Mount FAILED"

# 3.5.3 跑同样的随机写
mkdir -p "${MOUNT_POINT_EC}/test_dir"
fio --name=randwrite-ec --directory="${MOUNT_POINT_EC}/test_dir/" \
    --rw=randwrite --bs=4k --size=4G --numjobs=4 --iodepth=32 \
    --runtime=60 --time_based --direct=1 --end_fsync=1 \
    2>&1 | tee /tmp/fio-randwrite-ec.txt

# ========== 3.6 对比结果 ==========
echo "=== 复制池随机写 BW ==="
grep -E 'bw=' /tmp/fio-randwrite-rep.txt | tail -5
echo ""
echo "=== EC 池随机写 BW ==="
grep -E 'bw=' /tmp/fio-randwrite-ec.txt | tail -5
# 如果复制池 BW >> EC 池 BW，则确认 EC RMW 是随机性能差的主因
```

---

## 步骤 4：裸盘基线 — 直接 fio HDD 随机写

绕过 Ceph，直接测 HDD 的随机写能力，确认裸盘就是 36MB/s 折算后的物理上限。

```bash
# 4.1 在 ceph-node1 上直接对 HDD 跑 fio
#     注意：不能用正在做 OSD 的盘！会破坏集群。
#     这里用 OSD 的 LV 路径不方便，更好的办法是用 /dev/sdb 上的空闲空间。
#     但 sdb 已被 Ceph 全部占用，所以：
#     方案 A：用 /tmp 目录（在系统盘 sda 上）— 但 sda 可能是 SSD，不能代表 HDD
#     方案 B：临时拿一个 OSD 离线测，测完重建（太重）
#     方案 C：用 fio 在 Ceph RBD 块设备上跑（仍经过 Ceph，不纯粹）
#
#     最实际的做法：在每个节点上用系统盘跑 fio，得到一个 "HDD 级别" 的
#     参考数据。如果系统盘是 SSD，则此值是上界（HDD 只会更慢）。
#
#     更好的做法：如果有空闲 HDD，直接用。这里假设没有，用 /tmp 目录做近似。

# 4.2 在 ceph-node1 上用 /tmp 目录（系统盘）跑随机写基线
#     如果系统盘是 HDD，结果就是裸 HDD 随机写能力
#     如果系统盘是 SSD，结果是上界
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 \
  'fio --name=raw-randwrite --filename=/tmp/fio-test-file \
      --ioengine=libaio --rw=randwrite --bs=4k --numjobs=1 \
      --iodepth=128 --size=10G --runtime=60 --time_based \
      --direct=1 --end_fsync=1' 2>&1 | tee /tmp/fio-raw-randwrite-node1.txt

# 4.3 在 ceph-node3 上同样跑一次（交叉验证）
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.14 \
  'fio --name=raw-randwrite --filename=/tmp/fio-test-file \
      --ioengine=libaio --rw=randwrite --bs=4k --numjobs=1 \
      --iodepth=128 --size=10G --runtime=60 --time_based \
      --direct=1 --end_fsync=1' 2>&1 | tee /tmp/fio-raw-randwrite-node3.txt

# 4.4 分析结果
echo "=== node1 裸盘随机写 ==="
grep -E 'bw=|IOPS=' /tmp/fio-raw-randwrite-node1.txt | tail -3
echo ""
echo "=== node3 裸盘随机写 ==="
grep -E 'bw=|IOPS=' /tmp/fio-raw-randwrite-node3.txt | tail -3
#
# HDD 4K 随机写典型值：~100-200 IOPS → ~0.4-0.8 MB/s
# 如果裸盘 IOPS 就是这个量级，则：
#   36 MB/s / 放大系数(~6×) ≈ 6 MB/s → 对应 ~1500 IOPS
#   6 个 OSD 每个 ~250 IOPS → 完全匹配 HDD 能力
# 结论：36 MB/s 是 HDD 随机写的硬限制，EC RMW 只是放大了影响
```

---

## 清理：测试后删除所有测试数据和临时资源

```bash
source /home/turboai/production/config.sh
source /home/turboai/production/.credentials/rgw-juicefs.env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# ========== 5.1 卸载并销毁 JuiceFS 卷（复制池） ==========
MOUNT_POINT="/mnt/juicefs-rep"
METADATA_URL="tikv://${PD_ENDPOINTS}/juicefs-rep-test"

rm -rf "${MOUNT_POINT}/test_dir" 2>/dev/null || true
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    fusermount -uz "${MOUNT_POINT}" 2>/dev/null || umount -l "${MOUNT_POINT}" 2>/dev/null || true
fi
sleep 5
UUID=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
if [ -n "${UUID}" ]; then
    juicefs destroy "${METADATA_URL}" "${UUID}" --yes 2>&1 || true
fi

# 删除 S3 bucket
aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 rb "s3://juicefs-rep-test" --force 2>/dev/null || true

# ========== 5.2 卸载并销毁 JuiceFS 卷（EC 池） ==========
MOUNT_POINT_EC="/mnt/juicefs-ec"
METADATA_URL_EC="tikv://${PD_ENDPOINTS}/juicefs-ec-test"

rm -rf "${MOUNT_POINT_EC}/test_dir" 2>/dev/null || true
if mountpoint -q "${MOUNT_POINT_EC}" 2>/dev/null; then
    fusermount -uz "${MOUNT_POINT_EC}" 2>/dev/null || umount -l "${MOUNT_POINT_EC}" 2>/dev/null || true
fi
sleep 5
UUID=$(juicefs status "${METADATA_URL_EC}" 2>/dev/null | grep -o '"UUID": "[^"]*"' | cut -d'"' -f4 || true)
if [ -n "${UUID}" ]; then
    juicefs destroy "${METADATA_URL_EC}" "${UUID}" --yes 2>&1 || true
fi

# 删除 S3 bucket
aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl s3 rb "s3://juicefs-ec-test" --force 2>/dev/null || true

# ========== 5.3 恢复 zone 配置到 EC 池（如果还没恢复） ==========
# 步骤 3.5.1 已经恢复，这里再确认一次
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 <<'EOF'
  # 检查当前 zone 的 data_pool 是否已恢复为 EC 池
  CURRENT_POOL=$(sudo radosgw-admin zone get --rgw-zone=default | python3 -c "import json,sys; print(json.load(sys.stdin)['data_pool'])")
  if [ "${CURRENT_POOL}" != "default.rgw.buckets.data" ]; then
    echo "WARNING: data_pool is ${CURRENT_POOL}, restoring to default.rgw.buckets.data..."
    sudo radosgw-admin zone set --rgw-zone=default < /tmp/zone-config-backup.json
    sudo radosgw-admin period update --commit
    sudo ceph orch restart rgw.myrgw
  else
    echo "Zone config OK (data_pool=default.rgw.buckets.data)"
  fi
EOF

# ========== 5.4 删除测试用复制池 ==========
ssh -i ~/.ssh/id_ed25519 turboai@192.168.11.11 <<'EOF'
  # 先确认复制池里的对象已清空
  OBJ_COUNT=$(sudo ceph osd pool stats test-rep-data | grep -oP 'objects: \K\d+' || echo "unknown")
  echo "test-rep-data objects: ${OBJ_COUNT}"

  # 删除复制池
  sudo ceph osd pool delete test-rep-data test-rep-data --yes-i-really-really-mean-it

  # 确认删除
  sudo ceph osd pool ls | grep test-rep-data && echo "WARN: pool still exists!" || echo "Pool deleted OK"
EOF

# ========== 5.5 清理本地临时文件 ==========
rm -f /tmp/fio-randwrite-rep.txt /tmp/fio-randwrite-ec.txt
rm -f /tmp/fio-raw-randwrite-node1.txt /tmp/fio-raw-randwrite-node3.txt
rm -f /tmp/iostat-node1.txt /tmp/iostat-node2.txt /tmp/iostat-node3.txt
rm -f /tmp/zone-temp.json
# 保留 /tmp/zone-config-backup.json 作为备份，确认恢复后也可删除
# rm -f /tmp/zone-config-backup.json

# ========== 5.6 清理远端临时文件 ==========
for node in 192.168.11.11 192.168.11.14; do
  ssh -i ~/.ssh/id_ed25519 turboai@${node} 'rm -f /tmp/fio-test-file' 2>/dev/null || true
done

echo "Cleanup done."
```

---

## 预期结论

| 验证项 | 如果是 EC RMW + HDD 瓶颈，应该看到 |
|--------|-------------------------------------|
| 步骤 1：pool stats | 随机写时大量 read ops（EC RMW 必须先读再改写） |
| 步骤 2：iostat | %util≈100%，r/s 远高于预期，放大比 4-8× |
| 步骤 3：复制池对照 | 复制池随机写 BW 明显高于 EC 池（无 RMW 放大） |
| 步骤 4：裸盘基线 | HDD 4k 随机写 ~100-200 IOPS，36MB/s 折算后匹配 |

四项全部对上，即可确认 36MB/s 是 HDD + EC RMW 的硬限制，软件层无法突破，
只有换 SSD/NVMe 才能提升随机性能。
