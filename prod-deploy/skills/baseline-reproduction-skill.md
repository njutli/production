# 基线复现 Skill

> 状态：**已验证**。2026-07-21 通过 A/B/C/D 四轮对比测试验证了清理方法的有效性。
> 结论：轮间清理（delete+recreate pool + restart OSD）在干净环境下有效（偏差 <1%），但脏环境下 SST 积压导致 mseqwrite 偏差 +21%。因此基线测试必须在集群重建后的干净环境下开始，每 2-3 轮全量基线后需重建集群。
> **定位**：完整工作流文档（集群配置 + 缓存/清理管理 + 测试流程 + 复现验证）。fio 命令见 `test-commands-reference.md`，方法论原则见 `TESTING-GUIDE.md`。

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
| **fast_read** | **true** | 消除 EC 读轮间波动（19.3%→2.6%，02-1 Z6 验证） |
| PG_NUM | 32 | config.sh |
| DB/WAL | tmpfs 内存盘 | 每节点 200G tmpfs, 每 OSD 40G DB + 10G WAL |
| **cluster_network** | **10.3.2.0/24**（独立网卡 enp139s0f1np1） | config.sh + 01-2d §7 |
| public_network | 10.3.1.0/24（网卡 enp139s0f0np0） | config.sh |
| MTU | 4200（100GbE，WekaIO 设置，不动） | 红线 |
| osd_memory_target | 当前值（采集记录） | `ceph config get osd osd_memory_target` |

> **关键**：01-2d 的 cluster_network = 10.3.2.0/24（双网分离）。之前错误的"复现"把它改成了 10.3.1.0/24（合并），与 01-2d 条件完全相反。

### 1.2 JuiceFS 配置

| 配置项 | Group A (default) | Group B (ra0) | 来源 |
|--------|:-:|:-:|------|
| --max-uploads | 150 | 150 | config.sh |
| --cache-size | 0 | 0 | 冷态基线 |
| --max-readahead | 不设（默认） | **0** | ra0 = 关预读 |
| --max-fuse-io | 不设（默认 128K） | 不设（默认 128K） | 01-2d 未设置 |
| --block-size | 256K | 256K | format 时设置 |
| --storage | ceph | ceph | 直连 RADOS |
| --openfiles | 128 | 128 | = numjobs（01-2d 红线7） |

### 1.3 网络验证（每次测试前确认）

```bash
sudo ceph config get osd cluster_network  # 应为 10.3.2.0/24
sudo ceph osd metadata 0 | grep back_addr  # 应为 10.3.2.x
cat /proc/net/dev | grep enp139s0f1np1  # cluster NIC 应有 RX/TX 数据
```

---

## 二、OSD 缓存状态管理

### 2.1 01-2d 的实际做法

根据 01-2d summary：
- **Group A (default)**："补测（清卷+**OSD重启**+HEALTH_OK）"——OSD 重启，冷缓存
- **Group B (ra0)**："综合脚本（清卷+HEALTH_OK+compact cooldown）"——**没有 OSD 重启**

Group B 在 Group A 之后跑，OSD 缓存被 Group A 的测试数据预热。

> **关键**：Group B（ra0）的 OSD 缓存是**热的**（被 Group A 预热），不是冷的。

### 2.2 清理层级

| 场景 | 操作 | 耗时 | 清除范围 |
|------|------|------|---------|
| **基线测试起点**（首次 / 每 2-3 轮后） | 重建集群（deploy-ceph.sh + deploy-tikv.sh） | 30-60min | 全清：pool 数据 + BlueStore 内存 + RocksDB SST 磁盘文件 + TiKV + CephFS |
| **轮间清理**（A→B 切换 / 同一重建周期内的第 2 轮） | delete+recreate pool + restart OSD（见 §2.5） | 5-10min | pool 数据 + BlueStore 内存 + RocksDB memtable；**不清磁盘 SST 文件** |
| **组内清卷**（seq→randwrite 之间 / randwrite-true→layout 之间） | juicefs destroy + compact cooldown（见 §3.3） | 5-20min | pool 对象 + TiKV 元数据 + RocksDB tombstone 合并；**不清内存、不清 SST** |

> **关键结论（A/B/C/D 四轮验证）**：
> - 轮间清理在**干净环境**下有效（C≈D，偏差 <1%）
> - 轮间清理在**脏环境**下**不足**（A/B 的 mseqwrite 比 C/D 低 21%，SST 积压导致）
> - **基线测试必须从集群重建开始**，每 2-3 轮全量基线后重建
> - 轮间清理仅在**同一重建周期内**的轮间切换（A→B）使用

### 2.3 重建周期

- **每轮全量基线**（A+B 组）写入数据量：~300-500GB（layout 128G + randwrite + randrw + randwrite-ow）
- **2-3 轮后**：累计写入 ~1-1.5TB，SST 积压开始影响写性能
- **重建频率**：每 2-3 轮全量基线后重建集群（~40min 重建时间）
- **判定**：如某轮 mseqwrite 比前轮低 >10%，提前重建

### 2.4 SST 积压检查

> 详见 `TESTING-GUIDE.md` §1.3 的 compact 三指标检查。此处补充 SST 专项检查。

RocksDB SST 文件积累过多会导致读性能下降。每次测试前检查：

```bash
for osd in 0 1 2 3 4 5; do
  echo "=== osd.${osd} ==="
  sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('rocksdb',{})
print(f\"  compact_queue_len: {r.get('compact_queue_len','N/A')}\")
print(f\"  compact_running: {r.get('compact_running','N/A')}\")
gl = r.get('get_latency',{})
print(f\"  get_latency avg: {gl.get('avgtime','N/A')}s\")
sl = r.get('submit_latency',{})
print(f\"  submit_latency avg: {sl.get('avgtime','N/A')}s\")
"
done
```

**干净态判据**（三项全绿才继续）：
- `compact_queue_len = 0`（无待合并队列）
- `compact_running = 0`（无进行中合并）
- `get_latency avg < 0.002s`（2ms，KV 查询延迟正常）

> **注意**：Ceph 17.2.8 的 perf dump 不暴露 level-0 文件数（`l0_files`）。三项指标全绿不保证 LSM tree 最优，但 `get_latency` 正常（<2ms）说明实际查询性能未受影响。若 `get_latency > 2ms`，需强制 compact：
> ```bash
> for osd in 0 1 2 3 4 5; do sudo ceph tell osd.${osd} compact 2>/dev/null; done
> # 轮询至 compact_running=0
> ```

### 2.5 轮间清理流程（同一重建周期内的 A→B 切换）

> **前提**：在集群重建后的干净环境下使用（见 §2.3）。每 2-3 轮全量基线后需重建集群。

```bash
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"

# 1. 卸载 JuiceFS
fusermount -u "${MNT}" 2>/dev/null
pkill -f 'juicefs.*mount' 2>/dev/null
sleep 5

# 2. 删除 + 重建 Ceph pool（彻底清数据）
sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it 2>/dev/null
sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod 2>/dev/null
sudo ceph osd pool set juicefs-data allow_ec_overwrites true 2>/dev/null
sudo ceph osd pool application enable juicefs-data juicefs 2>/dev/null

# 3. 重启所有 OSD（清 BlueStore 内存缓存 + RocksDB memtable）
# 在每个 slave 节点上执行（157 上没有 podman）：
for slave_ip in 10.20.1.150 10.20.1.151 10.20.1.152; do
  sshpass -p 'Sunrise@801' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    sunrise@${slave_ip} 'for c in $(sudo podman ps --format "{{.Names}}" | grep osd); do sudo podman restart "$c" >/dev/null 2>&1; done' 2>/dev/null
done
# 等待所有 OSD up + PG active+clean
for i in $(seq 1 60); do
  pg_line=$(sudo ceph -s 2>/dev/null | grep "pgs:" | head -1)
  echo "$pg_line"
  echo "$pg_line" | grep -qE "unknown|not active|creating|peering|recovering|degraded|incomplete" || break
  sleep 5
done
sudo ceph health  # 必须 HEALTH_OK

# 4. SST 检查（见 §2.4）

# 5. format 新 JuiceFS 卷
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
  --force "${META}" juicefs-prod

# 6. mount（按组选择 readahead）
# Group A: juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}"
# Group B: juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 "${META}" "${MNT}"
mkdir -p "${MNT}/test_dir"
```

### 2.6 BlueStore 缓存指标采集（每次测试前后）

```bash
for osd in 0 1 2 3 4 5; do
  sudo ceph tell osd.${osd} perf dump 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
b=d.get('bluestore',{})
print(f'osd.${osd}: buffer_hit={b.get(\"buffer_hit_bytes\",0)} buffer_miss={b.get(\"buffer_miss_bytes\",0)} onode_hits={b.get(\"onode_hits\",0)} onode_misses={b.get(\"onode_misses\",0)}')
"
done
```

---

## 三、测试流程

### 3.1 组内执行顺序

```
rados bench（后端裸能力，可选）
  → seqread → seqwrite → mseqread → mseqwrite
  → 清卷（juicefs destroy + compact cooldown + format + mount）
  → randwrite-true ×3（fresh volume, create_on_open, 轮间 compact cooldown）
  → 清卷（juicefs destroy + compact cooldown + format + mount）
  → layout 128G（end_fsync=1）
  → compact cooldown
  → randread ×3（reuse layout, 轮间 drop_caches）
  → randrw ×3（reuse layout, 轮间 compact cooldown）
  → randwrite-ow ×3（reuse layout, 轮间 compact cooldown）
```

### 3.2 组间切换

```
Group A (default) → 全量 9 项（不重启 OSD）
    ↓ 重挂 JuiceFS（改 readahead），不切网络
Group B (ra0) → 全量 9 项（不重启 OSD，缓存被 A 预热）
```

> **关键**：A→B 切换只需 `fusermount -u → juicefs mount (改 readahead)`，**不重启 OSD、不切网络**。

### 3.3 组内清卷方法（juicefs destroy）

> 详见 `TESTING-GUIDE.md` §3.5 和 `test-commands-reference.md` §2.5 的完整清卷命令。此处仅列出关键步骤：

1. 卸载 JuiceFS
2. 等会话过期 65s
3. 提取 UUID → `juicefs destroy`
4. compact cooldown（轮询至 `compact_running=0`）
5. `juicefs format`
6. mount（按组选择 readahead）

> **注意**：`ceph osd pool delete+create` 用于轮间清理（§2.5），组内清卷用 `juicefs destroy`。

### 3.4 每项测试前

> 详见 `TESTING-GUIDE.md` §4.4。

```bash
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
rm -f /tmp/jfs-bw/*
```

### 3.5 layout 后 / 写项之间

> 详见 `TESTING-GUIDE.md` §3.2 的 compact cooldown 流程。

### 3.6 fio 命令

> **见 `test-commands-reference.md` §4-§6**。所有 9 项的完整可执行 fio 命令在那里统一维护，本文不重复。

### 3.7 REPEAT 规则

- 顺序项（seqread/seqwrite/mseqread/mseqwrite/layout）：REPEAT=1（单轮）
- 随机项（randread/randwrite-true/randrw/randwrite-ow）：REPEAT≥3，取中位数（第 2 大值）
- 基线复现验证：REPEAT≥5（对抗基线漂移）
- 禁止取平均、禁止挑轮次、禁止丢弃任何一轮

### 3.8 数据采集与稳态中位数

> **见 `test-commands-reference.md` §8-§9** 和 `TESTING-GUIDE.md` §5.6 的完整规范。本文不重复。

关键要点：
- 所有 fio 命令加 `--write_bw_log --log_avg_msec=1000`
- 保留全部 per-job bw_log 文件（128 job → 128 个文件）
- 达标值 = fio 瞬时带宽稳态段中位数（截首 1/4），不是 fio 平均值

---

## 四、复现验证流程

### 4.1 目标

在 01-5 集群上连续跑多轮 A→B，验证轮间波动 <5%（随机项中位数）。

### 4.2 流程

```
第 1 轮：
  1. 设 cluster_network=10.3.2.0/24
  2. 重建集群（deploy-ceph.sh + deploy-tikv.sh，确保 SST 全清）
  3. 等 HEALTH_OK + PG active+clean
  4. format+mount Group A（default）
  5. 跑 Group A（default）全量 9 项
  6. 不重启 OSD，重挂 JuiceFS（改 readahead=0）
  7. 跑 Group B（ra0）全量 9 项

第 2 轮（同一重建周期）：
  8. 轮间清理（delete+recreate pool + restart OSD，见 §2.5）
  9. 等 HEALTH_OK
  10. format+mount Group A（default）
  11. 跑 Group A（default）全量 9 项
  12. 不重启 OSD，重挂 JuiceFS
  13. 跑 Group B（ra0）全量 9 项

第 3 轮起：
  14. 重建集群（每 2-3 轮后必须重建，见 §2.3）
  15. 重复步骤 3-13
```

### 4.3 判定

- 随机项轮间波动 <5% → 复现验证通过
- 波动 >5% → 排查原因（SST 积压、compact、cluster_network 等），必要时重建集群

### 4.4 验证通过后

- 基于验证后的可复现基线，叠加调优配置（如 256K+buf1024）做对比
- 对比基线 = 同集群、同条件的 128K 基线（非 01-2d 跨集群数据）

---

## 五、01-2d 基线数据（跨集群参考，不作为对比基线）

> 01-2d 在不同集群（不同 FSID）上测试，RADOS 能力不同（write 3361 vs 01-5 的 2778 MB/s, -17%）。
> 写类测试跨集群不可比（-19%~-22% 差异）。读类测试部分可比（seqread/randrw 误差 <1%）。
> **仅作参考，不作为调优对比基线。**

### Group A（default）

| 测试项 | §8.3 中位数 (MiB/s) |
|--------|:---:|
| seqread | 1263.2 |
| seqwrite | 1530.0 |
| mseqread | 3803.8 |
| mseqwrite | 4906.0 |
| layout | 4217.6 |
| randwrite-true | 3634.7 |
| randread | 1480.0 |
| randrw R | 1031.8 |
| randrw W | 1037.5 |
| randwrite-ow | 2143.6 |

### Group B（ra0）

| 测试项 | §8.3 中位数 (MiB/s) |
|--------|:---:|
| seqread | 177.5 |
| seqwrite | 1550.0 |
| mseqread | 1908.5 |
| mseqwrite | 4148.0 |
| layout | 3170.6 |
| randwrite-true | 4274.3 |
| randread | 2404.2 |
| randrw R | 1316.3 |
| randrw W | 1319.0 |
| randwrite-ow | 3651.0 |

### rados bench

| 模式 | -t | 中位数 (MB/s) |
|------|:---:|:---:|
| Write | 128 | 3361 |
| Write | 4096 | 3516 |
| Seq read | 128 | 4489 |
| Seq read | 4096 | 4388 |
| Rand read | 128 | 4417 |
| Rand read | 4096 | 4383 |
