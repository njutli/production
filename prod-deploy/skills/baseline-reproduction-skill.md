# 基线复现 Skill

> 状态：**已验证**。2026-07-23 通过 02-2-G v3 验证了 soft-clean + OSD restart 的稳态可复现性（randread CV=2.88% <5%，mseqread 不单调降，变量守卫 4/4 全绿）。
> 结论：**轮间清理必须用 soft-clean（`juicefs destroy` 保留 pool → pool_id 不变 → CRUSH 映射不变）+ OSD restart（重置 tmpfs/RocksDB 内存态）**，禁止 `pool delete+recreate`（会改 pool_id → 重映射 → 跨 cycle 不可比）、禁止用重建 OSD 作轮间清理（会改 CRUSH 映射）。集群重建/半损坏恢复口径见 `../pre-skills/stable-rebuild-skill.md`（规范重建）与 `../pre-skills/cluster-rebuild-skill.md`（分层诊断）。
> **定位**：完整工作流文档（集群配置 + 缓存/清理管理 + 测试流程 + 复现验证）。fio 命令见 `test-commands-reference.md`，方法论原则见 `TESTING-GUIDE.md`。
>
> **⚑ 波动根因链（已闭环，02-2-G v3 证实）**：跨部署绝对值不可复现，只复现相对结论；同部署内 soft-clean 可复现。三个波动源与对策：
> | 波动源 | 对策 | 状态 |
> |--------|------|:----:|
> | ① 重建 OSD → CRUSH 重映射（32 PG 映射全变） | stable-ID 重建（destroy + ceph-volume 复用 LV，见 stable-rebuild-skill） | ✅ 消除 |
> | ② pool delete+recreate → pool_id 变 → PG 重算 | soft-clean 保留 pool | ✅ 消除 |
> | ③ tmpfs/RocksDB 内存态逐轮累积 | OSD restart（不删 pool，只重置内存态） | ✅ 消除 |

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
| **基线测试起点 / 集群重建**（首次 / 半损坏恢复） | stable-ID 重建（destroy + `ceph auth rm` + `ceph-volume lvm` 复用现有 LV，禁 zap，见 `../pre-skills/stable-rebuild-skill.md`） | ~15min | 全清：BlueStore + tmpfs RocksDB + 保 pool_id/CRUSH |
| **轮间清理（soft-clean + OSD restart）**（cycle 间 / A→B 切换） | `juicefs destroy`（保留 pool → pool_id 不变）+ compact cooldown + OSD restart（重置 tmpfs 内存态）+ drop_caches（见 §2.5） | 5-10min | pool 对象 + TiKV 元数据 + BlueStore/RocksDB 内存态；**不删 pool、不重建 OSD** |
| **组内清卷**（seq→randwrite 之间 / randwrite-true→layout 之间） | `juicefs destroy` + compact cooldown（见 §3.3） | 5-20min | pool 对象 + TiKV 元数据 + RocksDB tombstone 合并；**不清内存、不 restart OSD** |

> **关键结论（02-2-G v3 验证）**：
> - soft-clean + OSD restart 在保持不变量（OSD 集合 + pool_id + CRUSH md5 逐 cycle 不变）的前提下得到稳态可复现基线（randread CV=2.88%，mseqread 不单调降）。
> - **禁止 `pool delete+recreate`**：会改 pool_id → PG→OSD 映射重算 → 跨 cycle 不可比（上一轮无效数据 CV=12.35%）。
> - **禁止用重建 OSD 作轮间清理**：会改 CRUSH 映射（32 PG 全变）。重建 OSD 仅用于集群重建/半损坏恢复（见 stable-rebuild-skill）。
> - 跨部署只复现相对结论，同部署内 soft-clean 复现绝对值。

### 2.3 清理周期

- soft-clean + OSD restart 保持不变量恒定，同部署内可无限轮复现（02-2-G v3：c2-c4 CV=2.88%）。
- **无需定期重建集群**（不再需要"每 2-3 轮重建"——重建反而会改 CRUSH 映射引入波动源①）。
- **仅在集群半损坏 / 跨部署迁移时**才做 stable-ID 重建（见 `../pre-skills/stable-rebuild-skill.md`）。
- cycle1 恒为预热轮（CV/趋势判定从 c2 起算）。

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
- `compact_queue_len = 0`（无待合并队列 —— 02-2-G v3 必查，旧版只查 running 曾致 57s 未压完误进下轮）
- `compact_running = 0`（无进行中合并）
- `get_latency avg < 0.002s`（2ms，KV 查询延迟正常）

> **注意**：Ceph 17.2.8 的 perf dump 不暴露 level-0 文件数（`l0_files`）。三项指标全绿不保证 LSM tree 最优，但 `get_latency` 正常（<2ms）说明实际查询性能未受影响。若 `get_latency > 2ms`，需强制 compact：
> ```bash
> for osd in 0 1 2 3 4 5; do sudo ceph tell osd.${osd} compact 2>/dev/null; done
> # 轮询至 compact_running=0
> ```

### 2.5 轮间清理流程（soft-clean + OSD restart，cycle 间 / A→B 切换）

> **核心不变量**：全程 **不删 pool、不重建 OSD**，保持 OSD 集合 + pool_id + CRUSH md5 恒定（02-2-G v3 变量守卫 4/4 全绿）。禁止 `ceph osd pool delete+create`（改 pool_id）、禁止 `ceph-volume` 重建 OSD（改 CRUSH 映射）。

```bash
META="tikv://10.20.1.150:2379,10.20.1.151:2379,10.20.1.152:2379/juicefs-prod"
MNT="/mnt/juicefs"

# 1. 卸载 JuiceFS
fusermount -u "${MNT}" 2>/dev/null
pkill -f 'juicefs.*mount' 2>/dev/null
sleep 5

# 2. soft-clean：juicefs destroy（保留 pool → pool_id 不变 → CRUSH 映射不变）
#    等会话过期 65s → 提取 UUID → juicefs destroy --force
sleep 65
UUID=$(juicefs status "${META}" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['Setting']['UUID'])")
juicefs destroy --force "${META}" "${UUID}"

# 3. 重启所有 OSD（清 BlueStore 内存缓存 + RocksDB memtable，重置 tmpfs 内存态；不删 pool）
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

# 4. compact cooldown（compact_running=0 且 compact_queue_len=0，见 §2.4）+ SST 检查

# 5. format 新 JuiceFS 卷
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs --block-size 256K --trash-days 0 \
  --force "${META}" juicefs-prod

# 6. mount（按组选择 readahead）
# Group A: juicefs mount -d --max-uploads 150 --cache-size 0 "${META}" "${MNT}"
# Group B: juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 "${META}" "${MNT}"
mkdir -p "${MNT}/test_dir"

# 7. 变量守卫：比对 OSD 集合 / pool_id / CRUSH md5 与基线快照是否一致（任一不符 → 停，数据无效）
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
4. compact cooldown（轮询至 `compact_running=0` 且 `compact_queue_len=0`）
5. `juicefs format`
6. mount（按组选择 readahead）

> **注意**：轮间清理用 soft-clean + OSD restart（§2.5，`juicefs destroy` 保 pool + restart OSD），组内清卷用 `juicefs destroy`（不 restart OSD）。**任何场景都不用 `ceph osd pool delete+create`**。

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

连续跑多 cycle（可跨 A→B），验证轮间波动 <5%（随机项中位数），且不变量（OSD 集合 + pool_id + CRUSH md5）逐 cycle 恒定。参考实现 = `scripts/tests/02-2-G-softclean-stability.sh`（v3，已通过：CV=2.88%）。

### 4.2 流程

```
起点（一次性）：
  1. 设 cluster_network=10.3.2.0/24
  2. 集群若半损坏/跨部署迁移 → stable-ID 重建（../pre-skills/stable-rebuild-skill.md）；否则直接用现有集群
  3. 等 HEALTH_OK + PG active+clean，记录基线快照（OSD 集合 / pool_id / CRUSH md5）
  4. format+mount Group A（default）

cycle 1（预热，判定不计入）：
  5. 跑 Group A（default）全量 9 项
  6. 不重启 OSD，重挂 JuiceFS（改 readahead=0）→ 跑 Group B（ra0）全量 9 项

cycle 2 起（判定从此计入）：
  7. soft-clean + OSD restart（juicefs destroy 保 pool + restart OSD + compact cooldown，见 §2.5）
  8. 变量守卫：比对 OSD 集合 / pool_id / CRUSH md5 == 基线快照（任一不符 → 停，数据无效）
  9. 等 HEALTH_OK → format+mount Group A → 跑全量 → 重挂改 ra0 → 跑 Group B
  10. 重复步骤 7-9 至 cycle 4
```

### 4.3 判定

- 三判据（02-2-G v3 口径）全过 → 稳态可复现基线确立：
  1. **不变量**：OSD 集合 + pool_id + CRUSH md5 逐 cycle 不变（变量守卫全绿）
  2. **稳定性**：randread CV（从 c2 起算）< 5%
  3. **第三源试金石**：mseqread 不再单调下降
- 判据② 失败（CV >5%）→ 排查（compact queue_len 未清 / 变量被破坏 / WekaIO 负载混淆），必要时转方案 C（每轮 stable-ID 重建）。

### 4.4 验证通过后

- 基于验证后的可复现基线，同周期背靠背叠加调优配置做对比 Δ（如 256K+buf1024）。
- 对比基线 = 同部署、同条件基线（**跨部署只比相对结论，不比绝对值**；非 01-2d 跨集群数据）。

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
