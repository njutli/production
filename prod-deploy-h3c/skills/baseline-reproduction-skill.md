# 基线复现 Skill（H3C 对比口径）

> 定位：H3C 对比测试的完整工作流文档（集群配置 + 缓存/清理管理 + 测试流程 + 复现验证）。
> 测试项只有 4 项（cp 读/cp 写/fio 顺序读/fio 顺序写）。fio 命令见 `test-commands-reference.md`，方法论原则见 `TESTING-GUIDE.md`。
> **⚑ 2026-07-22 与 prod 主 skill 的差异说明**：prod 主 skill 的 2026-07-22 三点修正（randrw 每轮重建 layout 防污染、轮间清理对读类偏高、randread 区间基线）**均不适用于本口径**——h3c 无 randrw/randwrite-ow、无 A/B 组 OSD-restart 切换，且 4 项读全是大块顺序读；P1 六段数据中顺序读跨重建收敛（Δ<4%），12-20% 漂移只发生在 randread（本口径不跑）。故本文判据（§4.3 <5%）对顺序读仍成立，保持不变。

---

## 一、集群配置

### 1.1 Ceph 配置

| 配置项 | 值 | 来源 |
|--------|-----|------|
| FSID | 当前集群的 FSID | `ceph fsid` |
| Ceph 版本 | 17.2.8 quincy | config.sh |
| OSD 数 | 6（3 节点 × 2 NVMe） | config.sh: nvme2n1 + nvme3n1 |
| EC 配置 | k=4, m=2, failure_domain=osd | config.sh: ec-prod profile |
| allow_ec_overwrites | true | JuiceFS 整对象写 |
| fast_read | true | 消除 EC 读轮间波动 |
| PG_NUM | 32 | config.sh |
| DB/WAL | tmpfs 内存盘 | 每节点 200G tmpfs, 每 OSD 40G DB + 10G WAL |
| cluster_network | 10.3.2.0/24（独立网卡 enp139s0f1np1） | config.sh |
| public_network | 10.3.1.0/24（网卡 enp139s0f0np0） | config.sh |
| MTU | 4200（100GbE，WekaIO 设置，不动） | 红线 |

### 1.2 JuiceFS 配置

| 配置项 | 值 | 来源 |
|--------|-----|------|
| --block-size | **4M** | format 时设置（H3C 大块顺序口径，独立卷 juicefs-h3c） |
| --max-fuse-io | **1M** | kernel 5.15 FUSE 硬上限；大块顺序 dispatch 数↓（02-1 §9.2 mseqwrite +89%） |
| --buffer-size | **1024** | 配合 max-fuse-io 1M 防 write sleep（02-1b） |
| --max-readahead | **8M** ⚑ | 顺序读预取；⚑ 经验外推，须 sweep 验证 |
| --max-uploads | 150 | config.sh |
| --cache-size | 0 | 冷态基线 |
| --storage | ceph | 直连 RADOS |
| 挂载点 | /mnt/epc | EPC_MOUNT_POINT |

### 1.3 网络验证（每次测试前确认）

```bash
sudo ceph config get osd cluster_network  # 应为 10.3.2.0/24
sudo ceph osd metadata 0 | grep back_addr  # 应为 10.3.2.x
cat /proc/net/dev | grep enp139s0f1np1  # cluster NIC 应有 RX/TX 数据
```

---

## 二、OSD 缓存状态管理

### 2.1 清理层级

| 场景 | 操作 | 耗时 | 清除范围 |
|------|------|------|---------|
| **h3c 首测前（一次性）** | stable-ID 重建 / pool 级重建（指针页 `pre-skills/cluster-rebuild-skill.md` → prod-deploy stable-rebuild-skill），清 prod 256K 旧数据 | 15-30min | 全清 |
| **轮间清理（h3c 默认）** | juicefs destroy + compact cooldown | 5-20min | pool 对象 + TiKV 元数据 |
| **兜底重建（仅 SST 积压确诊）** | delete+recreate pool + restart OSD，或全盘重建 | 5-30min | pool 数据 + BlueStore 内存 |

### 2.2 重建周期（h3c 口径）

- 每轮写入 ~50-80GB（cp 20G×2 + fio 10G×2，含 REPEAT），但 **h3c 是大块顺序单线程、低 IOPS，对 RocksDB LSM 压力远小于 prod 的 256K 随机高并发**。
- **默认不做过程性重建**，轮间用 juicefs destroy 清卷即可。
- 兜底判定：仅当某轮 BW 比前轮低 >10% 且排查确认为 SST 积压（compact 三指标非全绿、compact 后仍不恢复）时，才触发一次重建。

### 2.3 SST 积压检查

```bash
for osd in $(sudo ceph osd ls); do
  echo "=== osd.${osd} ==="
  sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('rocksdb',{})
print(f\"  compact_queue_len: {r.get('compact_queue_len','N/A')}\")
print(f\"  compact_running: {r.get('compact_running','N/A')}\")
"
done
```

干净态判据：`compact_queue_len=0` + `compact_running=0`

### 2.4 轮间清理流程

```bash
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-h3c"
MNT="/mnt/epc"

# 1. 卸载
fusermount -u "${MNT}" 2>/dev/null
pkill -f 'juicefs.*mount' 2>/dev/null
sleep 5

# 2. 删除 + 重建 Ceph pool
sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null
sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null

# 3. 重启所有 OSD（podman + systemd 全覆盖）
for slave_ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
  sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    sunrise@${slave_ip} 'for c in $(sudo podman ps --format "{{.Names}}" | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done' 2>/dev/null
done
# 等 PG active+clean + HEALTH_OK

# 4. format + mount
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs --block-size 4M --trash-days 0 \
  --force "${META}" juicefs-h3c
juicefs mount -d --block-size 4M --max-fuse-io 1M --buffer-size 1024 \
  --max-uploads 150 --cache-size 0 --max-readahead 8M "${META}" "${MNT}"
```

---

## 三、测试流程

### 3.1 组内执行顺序

```
1. 准备测试文件
   - 存储端 20Gfile：dd if=/dev/zero of=/mnt/epc/20Gfile bs=4M count=5120
   - 本地端 20Gfile：dd if=/dev/zero of=/mnt/jfs-cache/20Gfile bs=4M count=5120

2. cp 读：time cp /mnt/epc/20Gfile /mnt/jfs-cache/20Gfile.cpread
   → 清理 /mnt/jfs-cache/20Gfile.cpread（只删副本，不删 cp 写源文件）

3. cp 写：time cp /mnt/jfs-cache/20Gfile /mnt/epc/
   → 清理 /mnt/epc/20Gfile
   → compact cooldown

4. fio 顺序读：--bs=20M --rw=read --runtime=60
   → 删除 testfile1
   → drop_caches

5. fio 顺序写：--bs=16M --rw=write --runtime=120
   → 删除 testfile1
   → compact cooldown
```

### 3.2 每项测试前

```bash
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
```

### 3.3 REPEAT 规则

- 4 项各 REPEAT≥3，取中位数
- cp 测试取 `time` 的 real 时间，带宽 = 20G / real_seconds
- fio 测试取 fio 报告的 BW
- 禁止取平均、禁止挑轮次、禁止丢弃任何一轮

---

## 四、复现验证流程

### 4.1 目标

连续跑多轮，验证轮间波动 <5%。

### 4.2 流程

```
首测前（一次性）：
  0. 彻底清 prod 旧数据：stable-ID 重建 / pool 级重建（pre-skills/cluster-rebuild-skill.md 指针页 → prod-deploy stable-rebuild-skill）
     → rados df 确认 juicefs-data OBJECTS=0

第 1 轮：
  1. 等 HEALTH_OK + PG active+clean + compaction 三指标全绿
  2. format juicefs-h3c（4M）+ mount（全参数）
  3. 准备测试文件
  4. 跑 4 项（REPEAT=3）

第 2 轮起（默认清卷，不重建）：
  5. 轮间清卷（juicefs destroy + compact cooldown，见 §三·五）
  6. 等 HEALTH_OK + compaction 全绿
  7. format + mount + 准备文件
  8. 跑 4 项（REPEAT=3）
  9. 重复，直到 3 轮收敛

兜底（仅 SST 积压确诊时）：
  - 某轮 BW 比前轮低 >10% 且 compact 后仍不恢复 → 触发一次重建，重来第 1 轮
```

### 4.3 判定

- 各项轮间波动 <5% → 复现验证通过
- 波动 >5% → 排查原因（SST 积压、compact 等）；确诊 SST 积压才重建（h3c 口径重建应罕见）

### 4.4 一键执行

```bash
bash scripts/tests/h3c-4item-test.sh --repeat 3 --label h3c-baseline
```

---

## 五、测试项与指标

| # | 测试项 | 关键指标 | 计算方式 |
|---|--------|---------|---------|
| 1 | cp 读 | 带宽 (MB/s) | 20G / real_seconds |
| 2 | cp 写 | 带宽 (MB/s) | 20G / real_seconds |
| 3 | fio 顺序读 | BW (MB/s) | fio 报告 READ: bw= |
| 4 | fio 顺序写 | BW (MB/s) | fio 报告 WRITE: bw= |

> 对比维度：与 H3C 存储方案在相同 4 项测试下的结果横向对比。
> 对比基线 = 本集群在同口径下的 3 轮中位数。
