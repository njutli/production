# E6 配置基线测试报告 [2026-08-03]

> 配置：autotune=false + cache_size=30GB（固定缓存分区）
> 包含两部分：E6 randread A/B 补测 + V4 全量测试
> 日期：2026-08-03

---

## 一、E6 randread A/B 补测

> 背景：Opus AU.2 指出上次 E6 无原始数据（内联 `fio | grep` 跑，无 fio.txt/hit-rate.txt/nic.txt/bw_log），整章作废。本次用 `run_fio()` 重测，保存全部原始数据。
> 来源：`02-2h-opus-v3-review-execution-20260802.md` §九

### 1.1 配置

```
bluestore_cache_autotune = false
bluestore_cache_size = 30GB（每 OSD，6 OSD 合计 180GB）
JuiceFS: default readahead / ra0（--max-readahead 0），--max-uploads 150，--cache-size 0
Layout: 128×1G storage_test.*.0
```

### 1.2 方法

同会话背靠背 A/B：mount default → warmup → compact → drop_caches → 3 轮 randread → remount ra0 → warmup → compact → drop_caches → 3 轮 randread。每轮 180s，128-job，bs=256k，iodepth=128。

### 1.3 结果

| 配置 | r1 | r2 | r3 | median | CV | hit% | C_amp |
|------|-----|-----|-----|--------|------|------|-------|
| default | 1611 | 1498 | 1546 | **1546** | 3.7% | ~50% | **2.08** ✅ |
| ra0 | 2855 | 2876 | 2880 | **2876** | 0.5% | ~24% | **1.02** ✅ |

- ra0/default = 2876/1546 = **1.86x**
- C_amp：default 2.08 在 2.0±0.1 范围内；ra0 1.02 在 1.0±0.1 范围内
- 原始数据完整（fio.txt + hit-rate.txt + nic.txt + bw_log + mount-cmd + config-md5 + c_amp）

### 1.4 数据路径

```
157:/tmp/opencode-fullbaseline-v3/E6R/
├── randread-E6R-default-r{1,2,3}/
└── randread-E6R-ra0-r{1,2,3}/
```

---

## 二、CephFS 事故

### 2.1 经过

V4 全量测试第一次运行（`--remount --layout`）在完成 layout 创建、warmup、seqread 5 轮、mseqread 5 轮、randread（r1-r4 有结果、r5 BW=N/A）后，于 randrw r1 的 `aggressive_cleanup` 阶段卡住。日志停在两个 compact ✅ 之后（下一条语句是 `drop_caches()` → `sync`）。

### 2.2 根因（已验证）

157 上存在陈旧 CephFS 内核挂载（`/mnt/cephfs-kernel`，FSID `4f4e3ca0-8297-11f1-a671-97520597268c`），来自上一轮 Ceph 集群部署（当前集群 FSID 为 `f8137e5a-8af2-11f1-aa1c-4df480fc234d`）。旧 admin keyring 对当前 MON 无效，dmesg 每 10s 报 `cephx auth failed: -13`。

`drop_caches()` 中的裸 `sync` 遍历所有 superblock，碰到悬空 CephFS sb 后调用 `ceph_sync_fs()`，等待 MDS 响应（永不返回，无超时），脚本无限阻塞。

### 2.3 处理

1. `sudo umount -l /mnt/cephfs-kernel`（lazy unmount，从 VFS 命名空间摘除）
2. 杀掉第一次运行的脚本和 fio 进程
3. 重启 JuiceFS（fresh mount）
4. 第二次运行（不重建 layout，复用已有文件）

### 2.4 残留影响

D-state 进程卡在 `ceph_mdsc_wait_request`（`TASK_KILLABLE`，可被 `kill -9` 回收部分）。通过 `dd` 测试确认不影响 JuiceFS I/O 路径。详细分析见 WSL `/tmp/d-state-analysis.md`（注：该文档中 D-state 进程数量和可杀性描述需修正）。

### 2.5 V4 脚本修复

针对本次事故，V4 脚本做了 3 处预防性修复（E6C 测试中已生效，E6 测试使用原始版本）：

| 改动 | 原代码 | 修复 | 作用 |
|------|--------|------|------|
| `drop_caches()` | `sync` | `sync -f "${MNT}"` | 只同步 JuiceFS 文件系统，免疫悬空 sb |
| `check_disk_space()` | `df -k /` | `stat -f -c '%a'` | 不遍历挂载表，免疫悬空挂载 |
| `run_fio()` | `fio \| tee \|\| true` | `timeout` + `PIPESTATUS[0]` + `INVALID.txt` | fio 超时保护 + 退出码捕获 + 坏轮标记 |

修复细节见 `/tmp/v4-fix-instructions-20260803.md`。

---

## 三、V4 全量测试

### 3.1 配置

| 配置项 | 值 |
|--------|-----|
| JuiceFS Mount | `--max-uploads 150 --cache-size 0`（default，无 --max-readahead） |
| Block size | 256K |
| Storage | ceph（直连 RADOS） |
| Layout 文件 | storage_test（randwrite）/ read_test（randread）/ rw_test（randrw），各 128×1G |
| Prep 文件 | seqread 32G / seqwrite 32G / mseqread 16×4G / mseqwrite 16×4G |
| OSD up_from | 0:889 1:888 2:884 3:892 4:896 5:895 |
| Config MD5 | `0352ef93ec9d84510fcc0cf414d6de97` |

### 3.2 流程

```
复用已有 layout（不重建）
→ 确定性预热（顺序读全部 layout + prep 文件，418 files，~10min）
→ compact_cooldown
→ 7 项 × 5 轮（180s/轮）：
  seqread → mseqread → randread → randrw → seqwrite → mseqwrite → randwrite
→ 所有项每轮前：drop_caches
→ randrw/randwrite 轮后：aggressive_cleanup（compact_cooldown → sleep 30 → compact_cooldown → drop_caches）
→ seqwrite/mseqwrite 轮后：compact_cooldown
→ 稳态评估（bw_log 截前 15s 取中位数）
```

### 3.3 fio 汇总 BW（MiB/s）

| 项 | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| seqread | 1242 | 1253 | 1256 | 1242 | 1254 |
| mseqread | 3812 | 3813 | 3826 | 3816 | 3833 |
| randread | 1697 | 1702 | 1712 | 1721 | 1700 |
| randrw | 1089 | 1133 | 1121 | 1048 | 883 |
| seqwrite | 1462 | 1495 | 1483 | 1511 | 1540 |
| mseqwrite | 3998 | 4010 | 3977 | 3975 | 3952 |
| randwrite | 3056 | 1785 | 1377 | 963 | 794 |

### 3.4 hit_rate（%）

| 项 | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| seqread | 85.3 | 100.0 | 100.0 | 100.0 | 100.0 |
| mseqread | 90.4 | 100.0 | 100.0 | 100.0 | 100.0 |
| randread | 46.1 | 49.5 | 51.5 | 51.1 | 51.5 |
| randrw | 29.4 | 37.4 | 38.1 | 38.0 | 37.5 |
| seqwrite | N/A | N/A | N/A | N/A | N/A |
| mseqwrite | N/A | N/A | N/A | N/A | N/A |
| randwrite | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |

### 3.5 C_amp（NIC 首末差分 ÷ fio 读字节）

| 项 | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| seqread | 1.02 | 1.02 | 1.02 | 1.02 | 1.02 |
| mseqread | 1.02 | 1.02 | 1.02 | 1.02 | 1.02 |
| randread | 2.08 | 2.08 | 2.08 | 2.07 | 2.07 |
| randrw | 2.31 | 2.23 | 2.19 | 2.18 | 2.18 |
| 写项 | N/A | N/A | N/A | N/A | N/A |

V4 脚本定义的 C_amp 范围：default 2.0±0.1，ra0 1.0±0.1。randread 通过；randrw 全部 5 轮（2.31-2.18）超出 2.1 范围。扣除 compaction 读回后（`C_amp_corr = (nic_delta − compact_bytes) / fio_read`），randrw 10/10 轮落在 2.076-2.090，2.0±0.1 门限成立（详见 §五-3）。

### 3.6 稳态评估（bw_log 截前 15s 取中位数）

| 项 | Median (MiB/s) | Max Dev | CV | Range | CV<2%? |
|---|---|---|---|---|---|
| seqread | 1247 | 0.7% | 0.5% | 1238-1253 | ✅ |
| mseqread | 3821 | 0.4% | 0.2% | 3815-3835 | ✅ |
| randread | 1702 | 0.8% | 0.4% | 1701-1716 | ✅ |
| randrw | 1095 | 13.2% | 6.8% | 951-1128 | ❌ |
| seqwrite | 1516 | 2.6% | 1.9% | 1476-1556 | ✅ |
| mseqwrite | 4004 | 1.3% | 0.8% | 3972-4058 | ✅ |
| randwrite | 1116 | 186.1% | 71.4% | 671-3194 | ❌ |

**5/7 项 CV < 2%**。读项 CV 0.2-0.5%，写项（seqwrite/mseqwrite）CV 0.8-1.9%。

### 3.7 两次 randread 对比

| 指标 | §一 补测（randread only） | §三 V4 全量（randread 5 轮） |
|------|-------------------------|------------------------|
| median | 1546 | 1702 |
| CV | 3.7% | 0.4% |
| hit% | ~50% | ~50% |
| C_amp | 2.08 | 2.08 |

差异可能原因（均为推测，未验证）：
- V4 使用 read_test 文件（独立文件集），补测使用 storage_test
- V4 有确定性预热（418 files），补测只预热 128G layout
- 会话不同，OSD 内部状态不同（跨会话波动，已知问题）

---

## 四、randwrite 单调下降根因

### 4.1 现象

randwrite BW：3056 → 1785 → 1377 → 963 → 794（-74%），单调下降。CV=71.4%。每轮间有 `aggressive_cleanup`（compact_cooldown → sleep 30 → compact_cooldown → drop_caches），compact 均显示 ✅，但 BW 继续下降。

### 4.2 根因：JuiceFS 切片 compaction（已验证）

**机制**：

1. fio 256K 随机覆盖写 → JuiceFS COW（copy-on-write）追加新切片，不覆盖原数据
2. 同一 128GB 工作集上多轮覆盖写 → chunk 切片链逐轮加深（每个 chunk 被多次追加切片）
3. 切片链变长 → JuiceFS 写路径每次写入都要在 TiKV 上读/改更长的切片列表 → **元数据事务延迟膨胀**
4. 事务延迟膨胀导致写吞吐下降（非网络/OSD 带宽竞争——实测总网络流量反降 53%，后端 per-op 延迟反变快）
5. 每轮加深切片链 → 下一轮事务延迟更高 → 单调下降

**事务延迟数据**（`transaction_durations_histogram_seconds_sum / _total` 差分）：

| 轮次 | E6 BW | E6 tx_avg | E6C BW | E6C tx_avg |
|------|-------|-----------|--------|------------|
| r1 | 3056 | 8.23 ms | 2896 | 9.36 ms |
| r2 | 1785 | 22.27 ms | 2895 | 9.98 ms |
| r3 | 1377 | 27.45 ms | 2852 | 10.26 ms |
| r4 | 963 | 24.83 ms | 2884 | 9.80 ms |
| r5 | 794 | 5.54 ms ⚠️ | 2814 | 10.24 ms |

E6 r1→r4 事务延迟膨胀 3.3x，与 BW 反向一一对应；E6C 全程钉在 9.4-10.3 ms，与 BW 持平一一对应。

⚠️ E6 r5 的 tx_avg 反而降到 5.54 ms（同时 DELETE 数从 182K→1.169M），属另一种状态（大批切片删除），单靠 tx_avg 解释不了，需单列。

**证据 1：GET 与 compaction 字节逐轮精确相等**

randwrite 5 轮中，`object_request_data_bytes_GET` 的增量与 `compact_size_histogram_bytes_sum` 的增量完全相等：

| 轮次 | GET_delta (bytes) | compact_delta (bytes) | 相等？ |
|------|-------------------|----------------------|--------|
| r1 | 30,198,988,800 | 30,198,988,800 | ✅ |
| r2 | 15,904,800,768 | 15,904,800,768 | ✅ |
| r3 | 16,642,998,272 | 16,642,998,272 | ✅ |
| r4 | 28,252,831,744 | 28,252,831,744 | ✅ |
| r5 | 64,760,053,760 | 64,760,053,760 | ✅ |

randwrite 是纯写测试（hit_rate=0%，无 fio 读），客户端从对象存储读回的每个字节都是切片合并。

**证据 2：7 项 1:1 判别无例外**

| 测试项 | 产生碎片？ | compactN（每轮增量） | GET_delta | CV | 稳定？ |
|--------|-----------|----------------------|-----------|------|--------|
| seqread | 否（纯读） | 0 | >0（fio 读） | 0.5% | ✅ |
| mseqread | 否（纯读） | 0 | >0（fio 读） | 0.2% | ✅ |
| randread | 否（纯读） | 0 | >0（fio 读） | 0.4% | ✅ |
| randrw | 是（50% 随机覆盖写） | 693/454/324/269/257 | >0（fio 读+compaction） | 6.8% | ❌ |
| seqwrite | 否（整块顺序写） | 0 | 0 | 1.9% | ✅ |
| mseqwrite | 否（整块顺序写） | 0 | 0 | 0.8% | ✅ |
| randwrite | 是（100% 随机覆盖写） | 450/237/248/421/965 | =compact_delta | 71.4% | ❌ |

- 会产生切片碎片的（randwrite / randrw）→ compactN>0，退化
- 不产生碎片的（seqwrite / mseqwrite / 纯读项）→ compactN=0，稳定
- 不稳定的 2 项恰好就是会碎片化的那 2 项，1:1 对应无例外

**证据 3：gc --compact 将每轮 compaction 量钉在首轮水平（非消除 compaction）**

E6 vs E6C randwrite 每轮 compaction（`compact_size_histogram_bytes_{total,sum}` 差分）：

| 轮次 | E6 次数/字节 | E6C 次数/字节 |
|------|-------------|--------------|
| r1 | 450 / 28.1 GiB | 489 / 30.6 GiB |
| r2 | 237 / 14.8 GiB | 302 / 18.9 GiB |
| r3 | 248 / 15.5 GiB | 496 / 31.0 GiB |
| r4 | 421 / 26.3 GiB | 508 / 31.8 GiB |
| r5 | 965 / 60.3 GiB | 502 / 31.4 GiB |

E6C 轮内 compaction 不低反略高于 E6 前几轮，只是**不再增长**（稳定在 ~31 GiB），而 E6 一路长到 60.3 GiB。gc --compact 消除的是切片链深度的逐轮累积，不是 compaction 本身。

### 4.3 已推翻的假设（调查过程记录）

**假设 1：RocksDB tombstone 累积**

推测 randwrite 产生 tombstone 累积在 RocksDB 中，compact 无法清除，导致性能下降。

推翻理由：tombstone 在 JuiceFS 元数据层（TiKV），`ceph tell osd.* compact` 压缩的是 BlueStore RocksDB（OSD 层），两者不是同一个 RocksDB。

**假设 2：孤立 RADOS 对象累积**

推测 JuiceFS GC 跟不上对象创建速度，孤立对象累积导致 BlueStore RocksDB 膨胀。

推翻理由：运行 `juicefs gc --delete --threads 50` 后，GC 扫描全部 28.68M 对象，报告 0 leaked，全部 valid。

GC 输出：
```
using 6366159 slices (7517345153024 bytes)
scanned 28676912 objects, 28676912 valid, 0 pending delete, 0 leaked
```

### 4.4 randrw r5 突降

randrw 同样产生切片碎片（compactN>0），但模式不同于 randwrite：
- compactN 逐轮递减（693→454→324→269→257），compaction 字节也递减
- r1-r4 BW 稳定（1048-1133），r5 突降到 883
- randrw r5 突降的具体原因未确认，可能与 5 轮累积的 compaction 开销跨过某个阈值有关

### 4.5 修复方向

- **r1 值**：randwrite r1（BW=3056）无 compaction 累积，最能代表稳态写能力
- **交错 A/B**：tombstone/碎片累积均匀摊入两组，抵消趋势
- **每轮 fresh volume**：destroy + format 彻底清零碎片，但改变 UUID
- `aggressive_cleanup` 的 compact 针对的是 BlueStore RocksDB，无法清理 JuiceFS 切片碎片
- **aggressive_cleanup 加 `juicefs gc --compact`**：已验证有效，详见 §八

---

## 五、待确认问题

1. **randwrite 单调下降根因**：✅ 已确认，切片链深度累积 → TiKV 元数据事务延迟膨胀（详见 §4.2）。修复方案见 §八
2. **randrw r5 突降**：✅ 已解决，`juicefs gc --compact` 消除（详见 §八）
3. **randrw C_amp 超范围**：✅ 已结案。扣除 compaction 读回后（`C_amp_corr = (nic_delta − compact_bytes) / fio_read`），randrw 10/10 轮落在 2.076-2.090，2.0±0.1 门限成立
4. **跨会话稳定性**：E6 消除了缓存分区波动（轮内读项 CV 0.2-0.5%），但跨会话波动来自 RocksDB/LSM 状态，autotune=false 不能消除。跨会话稳定的唯一已验证方法是 burn-in（每次重启 OSD，spread=4.8%）
5. **同实例内读项退化**：E6C 读项比 E6 低 2-15%，但非跨会话（同一 mount 实例，`juicefs_uptime` 连续）。退化与数据 hit% 无关（两轮一致），与 onode 缓存状态相关（E6 onode_misses=0，E6C 每轮 25M）。全部发生在首次 gc --compact 之前，与 gc --compact 无因果关系
6. **E6 randwrite r5 异常态**：tx_avg 反而降到 5.54 ms（r1-r4 为 8.2-27.5 ms），同时 DELETE 数从 182K→1.169M，属另一种状态（大批切片删除），待排查
7. **E6C 仅 N=1**：「≤10%」目前是单次观测，尚未证明可复现

---

## 六、原始数据

### 6.1 V4 全量测试（E6，无 gc --compact）

```
WSL: ~/demo/production/prod-deploy/results/E6/opencode-fullbaseline-v4/
├── test.log                         完整运行日志
└── E6/
    ├── seqread-E6-r1~r5/            每轮含：
    ├── mseqread-E6-r1~r5/           fio.txt, hit-rate.txt, nic.txt,
    ├── randread-E6-r1~r5/           bw_log (128 files), c_amp.txt,
    ├── randrw-E6-r1~r5/             mount-cmd.txt, config-md5.txt,
    ├── seqwrite-E6-r1~r5/           up_from.txt, jfs-stats-pre/post.txt,
    ├── mseqwrite-E6-r1~r5/          pg-map.txt, weka-load.txt
    └── randwrite-E6-r1~r5/
```

### 6.2 E6 randread A/B 补测

```
157:/tmp/opencode-fullbaseline-v3/E6R/
├── randread-E6R-default-r{1,2,3}/
└── randread-E6R-ra0-r{1,2,3}/
```

### 6.3 E6C 全量测试（有 gc --compact）

```
WSL: ~/demo/production/prod-deploy/results/E6/opencode-fullbaseline-v4/E6C/
├── seqread-E6C-r1~r5/
├── mseqread-E6C-r1~r5/
├── randread-E6C-r1~r5/
├── randrw-E6C-r1~r5/
├── seqwrite-E6C-r1~r5/
├── mseqwrite-E6C-r1~r5/
└── randwrite-E6C-r1~r5/

test.log 在 opencode-fullbaseline-v4/ 下（仅含 E6C 日志；E6 运行日志已被覆盖，但 E6 的 35 轮子目录数据完整）
```

### 6.4 其他

| 文件 | 位置 | 说明 |
|------|------|------|
| D-state 分析 | WSL `/tmp/d-state-analysis.md` | CephFS D-state 进程分析（数量和可杀性描述需修正） |
| V4 修复说明 | WSL `/tmp/v4-fix-instructions-20260803.md` | 3 处修复的详细说明 |
| V4-COMPACT-TEST 脚本 | `scripts/FULLBASELINE/debug/FULLBASELINE_V4-COMPACT-TEST.sh` | aggressive_cleanup 含 gc --compact 的 V4 变体 |

---

## 七、JuiceFS GC 排查结果（2026-08-03）

### 7.1 背景

§4.2 假设 2"孤立 RADOS 对象累积"被推翻后，运行 `juicefs gc --delete --threads 50` 验证。

### 7.2 JuiceFS 内部计数器（.stats）

| 指标 | 值 | 来源 |
|------|-----|------|
| PUT_total（创建对象总数） | 31,156,985 | `.stats` object_request PUT_total |
| DELETE_total（删除对象总数） | 4,898,629 | `.stats` object_request DELETE_total |
| GET_total（读取对象总数） | 52,486,000 | `.stats` object_request GET_total |
| Ceph 池对象数 | 28,676,912 | `ceph df` |

### 7.3 GC 执行结果

```
2026/08/03 21:14:02  using 6366159 slices (7517345153024 bytes)
2026/08/03 21:20:36  Deleted 0 pending slices
2026/08/03 21:20:36  scanned 28676912 objects, 28676912 valid, 0 pending delete,
                     0 compacted, 0 leaked, 0 delslices, 0 delfiles, 0 skipped
```

GC 报告 0 leaked，所有对象均为 valid。该结果推翻了"孤立对象累积"假设，但未否定"切片 compaction"根因——gc --delete 检查的是 RADOS 层孤立对象，而切片碎片问题在 JuiceFS 元数据层（TiKV）。

---

## 八、gc --compact 修复验证（E6C，2026-08-03）

### 8.1 方案

在 V4 脚本的 `aggressive_cleanup()` 中增加 `juicefs gc --compact`，在每轮 randrw/randwrite 后清理 JuiceFS 切片碎片。脚本：`scripts/FULLBASELINE/debug/FULLBASELINE_V4-COMPACT-TEST.sh`。

```bash
aggressive_cleanup() {
    log "  aggressive_cleanup"
    compact_cooldown
    sleep 30
    compact_cooldown
    log "  juicefs gc --compact (清理切片碎片)"
    set +e
    juicefs gc --compact "${META}" 2>&1 | tail -3
    set -e
    log "  gc --compact done"
    drop_caches
}
```

### 8.2 配置

与 §3.1 相同，标签改为 E6C。复用已有 layout，不重建。

### 8.3 结果

**fio 汇总 BW（MiB/s）：**

| 项 | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| seqread | 1195 | 1219 | 1223 | 1225 | 1222 |
| mseqread | 3303 | 3316 | 3349 | 3296 | 3301 |
| randread | 1462 | 1469 | 1446 | 1512 | 1548 |
| randrw | 1030 | 1026 | 1002 | 1000 | 1001 |
| seqwrite | 1413 | 1388 | 1376 | 1402 | 1411 |
| mseqwrite | 3928 | 3951 | 3970 | 3879 | 3974 |
| randwrite | 2896 | 2895 | 2852 | 2884 | 2814 |

**稳态评估：**

| 项 | Median (MiB/s) | Max Dev | CV | Range | CV<2%? |
|---|---|---|---|---|---|
| seqread | 1220 | 1.5% | 0.8% | 1202-1226 | ✅ |
| mseqread | 3299 | 1.8% | 0.9% | 3284-3357 | ✅ |
| randread | 1440 | 8.3% | 3.6% | 1436-1560 | ❌ |
| randrw | 999 | 6.3% | 2.8% | 992-1062 | ❌ |
| seqwrite | 1390 | 2.4% | 1.4% | 1356-1408 | ✅ |
| mseqwrite | 3996 | 1.3% | 0.7% | 3944-4012 | ✅ |
| randwrite | 3089 | 4.1% | 2.7% | 2963-3196 | ❌ |

### 8.4 E6 vs E6C 对比

| 项 | E6 median | E6 CV | E6C median | E6C CV | 结论 |
|---|---|---|---|---|---|
| seqread | 1247 | 0.5% | 1220 | 0.8% | -2.2%（同实例退化） |
| mseqread | 3821 | 0.2% | 3299 | 0.9% | -13.7%（同实例退化） |
| randread | 1702 | 0.4% | 1440 | 3.6% | -15.4%，CV 升高（同实例退化） |
| randrw | 1095 | 6.8% | 999 | 2.8% | **CV 改善，r5 突降消除** |
| seqwrite | 1516 | 1.9% | 1390 | 1.4% | -8.3%（同实例退化） |
| mseqwrite | 4004 | 0.8% | 3996 | 0.7% | -0.2%（持平） |
| randwrite | 1116 | 71.4% | 3089 | 2.7% | **单调下降消除** |

**注**：E6 与 E6C 是同一挂载实例（`juicefs_uptime` 从 643s 连续增长到 35147s，`up_from` 未变，`used_space` 全程不变），非跨会话。读项 2-15% 退化是 E6 的 2.7TB 随机覆盖写 + `gc --delete` 全量扫描遗留的状态退化。退化与数据 hit% 无关（两轮 hit% 一致），与元数据（onode）缓存状态相关：E6 读项 onode_misses 为 0，E6C 每轮 25M（seqread）/5-7M（mseqread）。

**randwrite 逐轮对比：**

| 轮次 | E6（无 gc） | E6C（有 gc） | 说明 |
|------|------------|-------------|------|
| r1 | 3056 | 2896 | 起点接近（同实例退化 ~5%） |
| r2 | 1785 | 2895 | E6 暴跌 42%，E6C 持平 |
| r3 | 1377 | 2852 | E6 继续跌，E6C 稳定 |
| r4 | 963 | 2884 | E6 腰斩，E6C 持平 |
| r5 | 794 | 2814 | E6 跌到 1/4，E6C 仅降 3% |

### 8.5 gc --compact 耗时

| 轮次 | gc 耗时 | 说明 |
|------|---------|------|
| mseqwrite 尾部 cleanup | ~9 min | 清理 E6 遗留的历史碎片 |
| randrw r1 cleanup | ~10 min | 清理 randrw r1 碎片（含历史残留） |
| randrw r2-r5 cleanup | ~3 min/轮 | 只清理当轮碎片 |
| randwrite r1 cleanup | ~9 min | 清理 randrw 遗留碎片 |
| randwrite r2-r5 cleanup | ~5-6 min/轮 | 稳定状态 |

### 8.6 结论

1. **randwrite 单调下降完全消除**：CV 71.4% → 2.7%。r1-r5 从 3056→794（-74%）变为 2896→2814（-3%）。gc --compact 不提高峰值能力（E6 r1 稳态 3194 vs E6C r1 稳态 3116，-2.4%），只消除衰减
2. **randrw r5 突降消除**：CV 6.8% → 2.8%，r5 从 883 → 1001
3. **gc --compact 耗时可接受**：首轮 ~10 分钟（清理历史碎片），后续稳定在 ~5 分钟/轮。累计 64.4 min，占总墙钟 217.7 min 的 29.6%
4. **机制**：切片链深度逐轮累积 → TiKV 元数据事务延迟膨胀（8.2→27.5 ms）→ 写吞吐塌陷；gc --compact 截断切片链使事务延迟复位到 ~10 ms。不是网络/OSD 带宽竞争（总流量反降 53%、后端 op 反而更快）
5. **无读侧代价**：三个读项的退化（seqread -2.2%、mseqread -13.7%、randread -15.4%）全部发生在首次 gc --compact 之前，与 gc --compact 无因果关系
6. **C_amp 判据结案**：扣除 compaction 读回后（`C_amp_corr = (nic_delta − compact_bytes) / fio_read`），randrw 10/10 轮落在 2.076-2.090，2.0±0.1 门限成立
7. **仍待解**：①同实例内读项 2-15% 退化（相关量 = onode miss 由 0 变 25M/轮，与数据 hit% 无关）；②E6 randwrite r5 的低 tx_avg + 高 DELETE 异常态；③E6C 仅 N=1，「≤10%」需再跑一次确认可复现

---

## 九、稳定性验证 S1/S2（2026-08-04）

### 9.1 方案

使用精简脚本 `scripts/FULLBASELINE/debug/stability-test.sh`（基于 V4-COMPACT-TEST，仅跑 randread + randrw + randwrite 3 项 × 5 轮），验证 gc --compact + reset_state（含 remount）下的：

- 单轮内多次 repeat 稳定性
- 多轮全量测试间的跨轮稳定性

与 V4-COMPACT-TEST 的差异：仅去掉 seqread/mseqread/seqwrite/mseqwrite 4 项，其余（run_fio/数据采集/aggressive_cleanup/set_cache_config/reset_state）完全一致。

新增 `set_cache_config()` + `reset_state()`（测试前自动执行）：
- `set_cache_config`：per-OSD `ceph config set` + `injectargs`（autotune=false, cache_size=CACHE_SIZE_GB, meta/kv/data ratio）
- `reset_state`：gc --compact → compact_cooldown → drop_caches → remount JuiceFS

配置：`CACHE_SIZE_GB=30`（与 E6/E6C 一致），复用已有 layout，不重建。

### 9.2 S1 结果

**fio 汇总 BW（MiB/s）：**

| 项 | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randread | 1465 | 1491 | 1464 | 1476 | 1485 |
| randrw | 1013 | 1005 | 1033 | 1018 | 1017 |
| randwrite | 3156 | 2875 | 2842 | 2857 | 2837 |

**稳态评估：**

| 项 | Median (MiB/s) | Max Dev | CV | Range |
|---|---|---|---|---|
| randread | 1475 | 0.4% | 0.3% | 1470-1480 |
| randrw | 1020 | 1.6% | 0.8% | 1016-1036 |
| randwrite | 3009 | 3.9% | 2.0% | 2968-3126 |

3/3 项 CV ≤ 2.0%。remount 修复了 E6C 的 randread 退化（CV 3.6% → 0.3%）。

### 9.3 S2 结果

**fio 汇总 BW（MiB/s）：**

| 项 | r1 | r2 | r3 | r4 | r5 |
|---|---|---|---|---|---|
| randread | 1628 | 1540 | 1521 | 1488 | 1477 |
| randrw | 1014 | 1013 | 1009 | 1001 | 1001 |
| randwrite | 2845 | 2838 | 2845 | 2845 | 2855 |

**稳态评估：**

| 项 | Median (MiB/s) | Max Dev | CV | Range |
|---|---|---|---|---|
| randread | 1490 | 11.7% | 5.2% | 1478-1665 |
| randrw | 1011 | 1.6% | 1.0% | 1002-1026 |
| randwrite | 2961 | 2.1% | 1.8% | 2910-3024 |

### 9.4 S1 vs S2 对比

| 项 | S1 CV | S2 CV | S1 median | S2 median | 跨轮偏差 |
|---|---|---|---|---|---|
| randread | 0.3% | 5.2% | 1475 | 1490 | +1.0% |
| randrw | 0.8% | 1.0% | 1020 | 1011 | -0.9% |
| randwrite | 2.0% | 1.8% | 3009 | 2961 | -1.6% |

### 9.5 randread 分析

**S2 randread 逐轮下降**（1628→1477），S1 平坦（1465-1491）。S2 r5=1477 ≈ S1 r5=1485 ≈ S1 median=1475，两轮最终收敛到同一水平。

**onode_misses 数据（6 OSD 聚合累计值，每轮 delta）：**

| 轮次 | S1 delta | S2 delta |
|------|---------|---------|
| r1 | 3.1M | 3.1M |
| r2 | 0 | 0.4M |
| r3 | 0 | 0.07M |
| r4 | 0 | 0 |
| r5 | 0 | 0.45M |

S1 和 S2 的 onode_misses 模式几乎一致——r2 后 delta ≈ 0。onode 缓存退化不是 S2 randread 下降的原因。

**未解问题**：S1 r1 和 S2 r1 的条件完全相同（相同 hit_rate ~45%、相同 onode_misses delta 3.1M、相同 warmup、相同 reset_state），但 BW 差 11%（1465 vs 1628）。所有已采集指标（data hit_rate、onode_misses）在两轮 r1 中一致，差异来源未确认——可能是 BlueStore buffer cache 内部状态、RocksDB SST 文件结构、TiKV 元数据查询延迟、或随机波动。

**实际建议**：增加 randread REPEAT（如 10 轮），丢弃前几轮瞬态，取稳定值。S2 r5=1477 ≈ S1 稳定区间 ~1475，多轮后应收敛到同一水平。

### 9.6 randrw / randwrite 分析

**randrw**：S1 CV 0.8%，S2 CV 1.0%，跨轮 median 偏差 -0.9%。两轮均稳定，r5 无突降（S1=1017, S2=1001）。✅

**randwrite**：S1 CV 2.0%，S2 CV 1.8%，跨轮 median 偏差 -1.6%。两轮均稳定，无单调下降。gc --compact + remount 有效。✅

S2 randwrite r1=2845（低于 S1 r1=3156），但 r2-r5 稳定在 2838-2855。S1 r1=3156 可能是 reset_state 后干净状态的瞬态高点。

### 9.7 结论

1. **randwrite 和 randrw 稳定性已确认**：gc --compact + reset_state（含 remount）有效，跨轮 CV ≤ 2.0%，median 偏差 < 2%
2. **randread 跨轮稳定但轮内可能出现瞬态**：S1 平坦（CV 0.3%），S2 有瞬态下降（CV 5.2%），但两轮最终收敛到同一水平（~1475）。增加 REPEAT 可取稳定值
3. **randread r1 跨轮差异原因未确认**：S1 r1=1465 vs S2 r1=1628，所有已采集指标一致但 BW 差 11%。未采集到的因素（buffer cache 内部状态/RocksDB/TiKV 延迟/随机波动）可能是原因
4. **reset_state（gc --compact + compact + drop_caches + remount）保证跨轮起点一致性**：除 randread r1 瞬态外，跨轮 median 偏差 < 2%

### 9.8 原始数据

```
157:/tmp/opencode-fullbaseline-v4/
├── test.log                         含 E6/E6C/S1/S2 日志（E6 日志已被覆盖）
├── E6/                              E6 全量（7×5 轮，无 gc --compact）
├── E6C/                             E6C 全量（7×5 轮，有 gc --compact，无 remount）
├── S1/                              S1 精简（3×5 轮，有 gc --compact + remount）
│   ├── randread-S1-r1~r5/
│   ├── randrw-S1-r1~r5/
│   └── randwrite-S1-r1~r5/
└── S2/                              S2 精简（3×5 轮，有 gc --compact + remount）
    ├── randread-S2-r1~r5/
    ├── randrw-S2-r1~r5/
    └── randwrite-S2-r1~r5/

WSL: ~/demo/production/prod-deploy/results/E6/opencode-fullbaseline-v4/
├── E6/                              已转移
├── E6C/                             已转移
├── S1/                              已转移（12M，3×5 轮）
└── S2/                              已转移（12M，3×5 轮）
```

---

## 十、OSD 侧只读采集实验（2026-08-04）

### 10.1 背景

§9.5 中 randread S1 vs S2 的 r1 差异（1465 vs 1628，11%）无法用已采集指标（hit_rate、onode_misses）解释。Opus 校验（`/tmp/e6c-report-issues-20260804.md` §五-§十二）发现：

- hit% 与 BW 相关性为 0 甚至反号（S2 r1 hit% 最低 45.9% 却最快）
- 逐秒 BW 呈双模（快档 ~1700 MiB/s / 慢档 ~1470 MiB/s，档位比 1.15），S2 的"下降"是快档占比从 64% 衰减到 3.7%
- BW × GET 延迟 = 16.12e3（常数，±0.15%），波动 100% 来自后端服务速率
- 所有工作量指标（bluestore 服务字节/fio 字节=3.058、GET 次数/IOPS=3.01、客户端 CPU/GET=269-278µs、TiKV 读=0、访问序列）逐位相同
- 推测根因：PG 主分布倾斜（osd.3/osd.5 承担 25% primary，osd.0/osd.2 仅 6.25%），热点 primary 的秒级停顿导致 ~10% BW 台阶

实验目的：通过 180s randread + OSD 侧只读采集，确认 PG 主分布倾斜和 straggler。

### 10.2 方法

脚本：`scripts/FULLBASELINE/debug/osd-profile-test.sh`

在 157 上跑 180s randread（128-job，bs=256k，iodepth=128），同时采集：

| 采集项 | 位置 | 频率 | 采集方式 |
|--------|------|------|---------|
| mpstat -P ALL | 157 | 1s | 本地 mpstat |
| pidstat -p <jfs_pid> | 157 | 1s | 本地 pidstat |
| NIC rx bytes | 157 | 1s | /proc/net/dev |
| iostat -x | 150/151/152 | 1s | SSH 远程 |
| ceph tell osd.{0-5} perf dump | 157→OSD | 2s | 并行查询 6 OSD |
| ceph osd pool get all | 157 | 一次性 | 静态采集 |
| ceph pg dump pgs_brief | 157 | 一次性 | 静态采集 |
| fio bw_log | 157 | 1s | fio --write_bw_log |

全部只读操作，无 sudo 写操作。

### 10.3 结果

**fio BW**：1492 MiB/s（在 S1 ~1475 和 S2 ~1628 之间）

**pool 配置确认**：

| 配置项 | 值 | 说明 |
|--------|-----|------|
| size | 6 | EC 4+2 |
| min_size | 5 | |
| pg_num | 32 | |
| fast_read | **1** | ✅ 确认 EC 4+2 + fast_read，读放大 6/4=1.5x |
| allow_ec_overwrites | true | |
| pg_autoscale_mode | on | |

**PG primary 分布（32 PG）**：

| OSD | primary PG 数 | 占比 |
|-----|--------------|------|
| osd.0 | 1 | 3.1% |
| osd.1 | 6 | 18.75% |
| osd.2 | 2 | 6.25% |
| osd.3 | **9** | **28.1%** |
| osd.4 | 6 | 18.75% |
| osd.5 | **8** | **25.0%** |

osd.3 + osd.5 合计 53% primary 职责，osd.0 + osd.2 仅 9.4%。最大倾斜 9:1（osd.3 vs osd.0），比 Opus 之前推算的 8:2 更倾斜。

**op_r 读操作量（180s fio 期间 delta）**：

| 分组 | op_r delta | 对应 OSD | PG 占比 |
|------|-----------|---------|--------|
| 高 | ~1.6M | osd.3 (9 PGs) + osd.5 (8 PGs) | 53.1% |
| 中 | ~0.8M | osd.1 (6 PGs) + osd.4 (6 PGs) | 37.5% |
| 低 | ~0.4M | osd.0 (1 PG) + osd.2 (2 PGs) | 9.4% |

高 primary OSD 承担 **4 倍于**低 primary 的读操作量。PG 主分布倾斜导致读负载不均确认。

**op_r_latency（累计平均值）**：

OSD 间 op_r_latency avg 差异 0.23-0.61ms，但因累计平均值变化极慢（每次迭代仅增加 ~0.02M 到 ~190M 累计值中），无法从累计值直接观测 per-2s 延迟波动。需要 sum/count delta 计算区间平均延迟才能做 straggler 分析。

### 10.4 结论

1. **fast_read=1 确认**：EC 4+2 + fast_read，读放大 1.5x。这是 C_amp≈2.08 中 1.5x 的来源（另 0.5x 来自 JuiceFS 客户端预读）
2. **PG 主分布倾斜确认**：1/6/2/9/6/8，osd.3 和 osd.5 承担 53% primary，osd.0 和 osd.2 仅 9.4%。op_r 量差 4 倍
3. **straggler 待确认**：当前采集因并行执行导致 OSD 输出顺序混乱，无法配对计算 per-2s 区间延迟。需重跑（改为顺序查询）或离线分析原始 perf dump

### 10.5 原始数据

```
157:/tmp/osd-profile-test/
├── fio.txt                      fio 输出（BW=1492 MiB/s）
├── randread_bw.1~128.log       fio bw_log（128 job，逐秒）
├── pool-settings.txt            ceph osd pool get all
├── pg-map.txt                   ceph pg dump pgs_brief
├── osd-tree.txt                 ceph osd tree
├── osd-perf.txt                 每 2s × 6 OSD perf dump（并行，顺序混乱）
├── mpstat.txt                   157 逐秒 CPU（mpstat -P ALL 1）
├── pidstat.txt                  157 逐秒 juicefs 进程（pidstat -ru 1）
├── nic.txt                      157 逐秒 NIC rx
├── iostat-10.20.1.150.txt       150 逐秒磁盘 I/O
├── iostat-10.20.1.151.txt       151 逐秒磁盘 I/O
└── iostat-10.20.1.152.txt       152 逐秒磁盘 I/O

脚本：scripts/FULLBASELINE/debug/osd-profile-test.sh
```

---

## 十一、pg_num 128 重建测试（2026-08-04）

### 11.1 背景

§十 OSD 侧采集确认 PG 主分布倾斜（1/6/2/9/6/8，max:min=9:1）和 straggler（osd.4 持续高延迟 0.88-1.26ms，是 osd.0/osd.2 的 4-5 倍）。删除池重建为 pg_num=128，验证均匀 PG 分布对稳定性和绝对 BW 的影响。

### 11.2 操作

1. `ceph osd pool delete juicefs-data`（删旧池）
2. `ceph osd pool create juicefs-data 128 128 erasure ec-prod`（重建 128 PG）
3. `ceph osd pool set juicefs-data fast_read 1` + `allow_ec_overwrites true`
4. `ceph osd pool application enable juicefs-data juicefs`
5. `juicefs format --force` + mount
6. stability-test.sh S1 --layout（创建 layout + 3 项测试）
7. stability-test.sh S2（复用 layout + 3 项测试，中途暂停）

### 11.3 PG 分布对比

| OSD | 旧（pg_num=32） | 新（pg_num=128） |
|-----|:---:|:---:|
| osd.0 | 1 (3.1%) | 21 (16.4%) |
| osd.1 | 6 (18.8%) | 13 (10.2%) |
| osd.2 | 2 (6.3%) | 20 (15.6%) |
| osd.3 | 9 (28.1%) | 16 (12.5%) |
| osd.4 | 6 (18.8%) | 19 (14.8%) |
| osd.5 | 8 (25.0%) | 15 (11.7%) |
| **max:min** | **9:1** | **1.6:1** |

### 11.4 S1 结果（pg_num=128）

**fio 汇总 BW（MiB/s）：**

| 项 | r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8 | r9 | r10 |
|---|---|---|---|---|---|---|---|---|---|---|
| randread | 1580 | 1515 | 1395 | 1479 | 1553 | 1595 | 1575 | 1621 | 1644 | 1577 |
| randrw | 1112 | 1125 | 1196 | 1191 | 1189 | — | — | — | — | — |
| randwrite | 3062 | 2967 | 2959 | 2942 | 3037 | — | — | — | — | — |

**稳态评估：**

| 项 | Median (MiB/s) | CV | Max Dev | Range | 旧 S1 CV (pg32) | 绝对值变化 |
|---|---|---|---|---|---|---|
| randread | 1577 | 4.3% | 7.8% | 1501-1699 | 0.3% | +6.9% |
| randrw | 1182 | 2.2% | 4.8% | 1125-1186 | 0.8% | +15.9% |
| randwrite | 3051 | 5.4% | 9.7% | 2755-3152 | 2.0% | +1.4% |

**S1 模式**：randread 呈先降后升（r3 低点 1395，r9 峰值 1644），与旧 S1（平坦 1465-1491）和旧 S2（单调下降 1628→1477）都不同。Fresh pool 后 OSD 需要多轮预热。

### 11.5 S2 部分结果（randread r1-r6，中途暂停）

| 轮次 | S2 BW (MiB/s) | S2 hit% | S1 BW (pg128) | 旧 S1 (pg32) |
|------|---|---|---|---|
| r1 | 1684 | 46.1 | 1580 | 1465 |
| r2 | 1679 | 49.5 | 1515 | 1491 |
| r3 | 1689 | 51.6 | 1395 | 1464 |
| r4 | 1691 | 51.3 | 1479 | 1476 |
| r5 | 1685 | 51.7 | 1553 | 1485 |
| r6 | 1681 | 51.3 | 1595 | — |

**S2 randread 极度稳定**：range 1679-1691（仅 0.7%），CV ~0.3%。绝对值比旧 S1（~1475）高 **14%**。

### 11.6 S1 vs S2 对比（pg_num=128）

| 项 | S1 median | S1 CV | S2 median (部分) | S2 CV (部分) | 跨轮偏差 | 旧跨轮偏差 (pg32) |
|---|---|---|---|---|---|---|
| randread | 1577 | 4.3% | ~1685 | ~0.3% | +6.8% | +1.0% |
| randrw | 1182 | 2.2% | — | — | — | -0.9% |
| randwrite | 3051 | 5.4% | — | — | — | -1.6% |

### 11.7 分析

**模式反转**：pg_num=128 下 S1→S2 的模式与 pg32 相反：

| | 旧 S1→S2 (pg32) | 新 S1→S2 (pg128) |
|---|---|---|
| S1 | 平坦（CV 0.3%） | 上升（CV 4.3%，预热中） |
| S2 | 下降（CV 5.2%，退化） | **平坦（CV 0.3%，稳定）** |
| S2 vs S1 | 退化（-15%） | **提升（+7%）** |

- 旧 S1 平坦是因为 E6C + gc --delete 已经预热过系统；S2 下降是因为 S1 的写操作产生 straggler 效应
- 新 S1 上升是因为 fresh pool 后需要预热；S2 平坦是因为预热完成后稳定，且 S1 的写操作不再产生 straggler 退化

**pg_num=128 的效果**：
1. **绝对 BW 提升**：randread +14%（~1685 vs ~1475），randrw +16%（~1182 vs ~1020）
2. **S1 的写操作不再导致 S2 读退化**：这是关键改善——pg32 下 S2 randread 比 S1 低 15%，pg128 下 S2 比 S1 高 7%
3. **双模未完全消除**：S1 randread 仍有双模（range 1501-1699，档位比 1.13），但 S2 消除了（range 1679-1691，几乎单模）
4. **S1 需要预热**：fresh pool 后 randread 需要 ~10 轮才收敛，r3 低点 1395 是预热过程

### 11.8 结论

1. **pg_num=128 提升绝对 BW**：randread +14%，randrw +16%，randwrite 持平
2. **pg_num=128 消除跨轮退化**：S1 的写操作不再导致 S2 读退化（S2 > S1，而非 S2 < S1）
3. **pg_num=128 不消除双模**：S1（预热阶段）仍有双模，但 S2（稳定后）消除
4. **straggler (osd.4) 仍有影响**：PG 分布均匀后，osd.4 的固有高延迟仍有影响，但跨轮退化消除说明影响减弱
5. **建议**：弃前 2-3 轮（预热），取后续稳定值；或增加 deterministic warmup 的读取量以加速预热

### 11.9 原始数据

```
WSL: ~/demo/production/prod-deploy/results/E6/opencode-fullbaseline-v4/
├── S1/                              pg128 S1（3×5 轮，randread 10 轮，已转移）
│   ├── randread-S1-r1~r10/
│   ├── randrw-S1-r1~r5/
│   └── randwrite-S1-r1~r5/
├── S2/                              pg128 S2 部分（randread r1~r6，中途暂停）
│   └── randread-S2-r1~r6/
└── test.log                         含 pg128 S1+S2 日志

脚本：scripts/FULLBASELINE/debug/stability-test.sh
```

---

## 十二、S3/S4 基线验证（2026-08-04/05）

### 12.1 背景

§十一 中 pg_num=128 被 `pg_autoscale_mode=on` 自动合并回 32（S1 期间 56→40→32）。Opus 校验（`/tmp/e6c-report-issues-20260804.md` §十八-§二十七）发现：

1. S1 的"先降后升"是 PG 合并 + backfill 干扰，不是预热
2. S2 的稳定性来自合并完成后（pg_num=32，全部 active+clean），不是 pg_num=128 的效果
3. E6（老池干净态）就达到过 randread 1697-1721，+14% 不是新高度
4. +14% 来自删池重建（对象数 ÷12），不是 pg_num

Opus 已执行修复：
- `ceph osd pool set juicefs-data pg_autoscale_mode off`（冻结 pg_num=32）
- 脚本新增 `pg_gate()`（每轮检查 pg_num/nonclean，非 clean 轮不进统计）、`gear_stat()`（每轮输出 fast/slow/stall 指标）、`rounds.tsv`（含 pg_gate/pg/gear 三列）

### 12.2 配置

- pool 3, pg_num=32, pgp_num=32, autoscale off
- EC 4+2, fast_read=1, allow_ec_overwrites=true
- CACHE_SIZE_GB=30, layout 复用（不重建）
- 脚本：stability-test.sh（含 pg_gate + gear_stat + gc --compact + remount）
- randread 10 轮，randrw/randwrite 各 5 轮

### 12.3 S3 结果

**fio 汇总 BW（MiB/s）** ← 验收口径：

| 项 | r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8 | r9 | r10 |
|---|---|---|---|---|---|---|---|---|---|---|
| randread | 1690 | 1703 | 1706 | 1686 | 1701 | 1701 | 1691 | 1712 | 1704 | 1685 |
| randrw | 1166 | 1169 | 1169 | 1157 | 1166 | — | — | — | — | — |
| randwrite | 2997 | 2976 | 3018 | 3087 | 3013 | — | — | — | — | 

⚑ 上表（fio 汇总 BW）逐轮统计 —— **这才是验收用的数**（判据见 §12.7.1：极差 ≤10% / max_dev ≤5% / CV ≤3%）：

| 项 | n | Median | 极差幅度 | Max Dev | CV | Range | L2 |
|---|---|---|---|---|---|---|---|
| randread | 10 | 1701 | 1.59% | 0.94% | **0.52%** | 1685-1712 | ✅ |
| randrw | 5 | 1166 | 1.03% | 0.77% | **0.38%** | 1157-1169 | ✅ |
| randwrite | 5 | 3013 | 3.68% | 2.46% | **1.24%** | 2976-3087 | ✅ |

**~~稳态评估（全部 pg_gate=CLEAN，stall=0.0%）~~**
⚑ 订正（Opus 2026-08-05 从 `*_bw.*.log` 重算）：①本表不是 fio 汇总 BW，而是 `steady_state_eval` 的**逐秒 BW 中位数（截前 15s）+ 样本标准差**，两个口径不可混引（randwrite 本表 3093 不等于任何一轮的 fio 值 3013）；②**"stall=0.0%" 只对 randread 成立**，实测 randrw 0.0-0.6%、**randwrite S3 = 22.3 / 6.0 / 1.8 / 1.2 / 4.8%**（与 `rounds.tsv` 的 gear 列一致）。表内数值本身复算无误：

| 项 | n | Median（逐秒中位数） | CV | Max Dev | Range | stall |
|---|---|---|---|---|---|---|
| randread | 10 | 1702 | 0.4% | 0.7% | 1692-1713 | 0.0%（10/10 轮） |
| randrw | 5 | 1162 | 0.5% | 0.7% | 1153-1169 | ⚑ 0.0-0.6% |
| randwrite | 5 | 3093 | 6.0% | 8.4% | 2902-3351 | ⚑ 1.2-22.3% |

**per-round gear（S3 randread 示例）：**

| 轮次 | slow | fast | 档位差 | 快档占比 | stall | 逐秒 CV |
|---|---|---|---|---|---|---|
| r1 | 1546 | 1710 | 10.6% | 87.1% | 0.0% | 5.2% |
| r4 | 1581 | 1713 | 8.4% | 79.4% | 0.0% | 4.8% |
| r8 | 1674 | 1796 | 7.3% | 29.0% | 0.0% | 5.4% |

primary 分布（全程一致）：`[0:6 1:6 2:5 3:6 4:5 5:4]`（max:min=1.5:1）

### 12.4 S4 结果

**fio 汇总 BW（MiB/s）** ← 验收口径：

| 项 | r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8 | r9 | r10 |
|---|---|---|---|---|---|---|---|---|---|---|
| randread | 1824 | 1842 | 1839 | 1831 | 1834 | 1836 | 1841 | 1839 | 1855 | 1827 |
| randrw | 1228 | 1228 | 1210 | 1205 | 1216 | — | — | — | — | — |
| randwrite | 2979 | 3004 | 3045 | 2972 | 2961 | — | — | — | — | — |

⚑ 上表（fio 汇总 BW）逐轮统计：

| 项 | n | Median | 极差幅度 | Max Dev | CV | Range | L2 |
|---|---|---|---|---|---|---|---|
| randread | 10 | 1838 | 1.69% | 0.95% | **0.45%** | 1824-1855 | ✅ |
| randrw | 5 | 1216 | 1.89% | 0.99% | **0.77%** | 1205-1228 | ✅ |
| randwrite | 5 | 2979 | 2.82% | 2.22% | **1.00%** | 2961-3045 | ✅ |

**~~稳态评估（全部 pg_gate=CLEAN，stall=0.0%）~~**
⚑ 订正同 12.3：本表为逐秒中位数口径；**stall 非 0**，实测 randrw 0.0-0.6%、**randwrite = 11.4 / 8.4 / 6.6 / 1.8 / 3.0%**。数值本身复算无误：

| 项 | n | Median（逐秒中位数） | CV | Max Dev | Range | stall |
|---|---|---|---|---|---|---|
| randread | 10 | 1843 | 0.5% | 0.9% | 1828-1860 | 0.0%（10/10 轮） |
| randrw | 5 | 1224 | 1.0% | 1.5% | 1213-1243 | ⚑ 0.0-0.6% |
| randwrite | 5 | 3031 | 7.0% | 11.2% | 2691-3163 | ⚑ 1.8-11.4% |

### 12.5 S3 vs S4 对比

| 项 | S3 median | S4 median | 跨运行偏差 | 判定（L3 ≤5%） | 两跑合并极差幅度（≤10%） |
|---|---|---|---|---|---|
| randread（fio 口径，验收） | 1701 | 1838 | **+8.0%** | ❌ | **9.6%** ⚠️ 擦线 |
| randrw（fio 口径，验收） | 1166 | 1216 | +4.3% | ✅ | 6.0% ✅ |
| randwrite（fio 口径，验收） | 3013 | 2979 | −1.1% | ✅ | 4.2% ✅ |
| randread（逐秒口径，参考） | 1702 | 1843 | +8.3% | ❌ | — |
| randrw（逐秒口径，参考） | 1162 | 1224 | +5.3% | ❌ | — |
| randwrite（逐秒口径，参考） | 3093 | 3031 | −2.0% | ✅ | — |

⚑ 原文只列了偏差数字未给判定。按 2026-08-05 定的 L3 ≤5%：**randread 未达标（+8.0%，且合并极差 9.6% 擦 10% 线），randrw / randwrite 达标。**

### 12.6 数据状态

- 全程 nonclean=0（30 轮全部 pg_gate=CLEAN）✅ 复核一致
- 无 INVALID / PG_UNSTABLE ✅ 复核一致
- 无 OSD 重启 / 配置漂移（up_from 恒 `0:889 1:888 2:884 3:892 4:896 5:895`、`config-md5` 恒 `ea35053a582b8e36d010da90307e8370`）✅ 复核一致
- primary 分布全程 `[0:6 1:6 2:5 3:6 4:5 5:4]`（1.5:1）
- 总耗时 ⚑ 订正：**S3 2.2h（157 时间 21:25→23:37）+ S4 2.2h（00:05→02:17）**，含中间间隔的墙钟合计 4.9h。注意 **157 时间比 WSL 文件 mtime 早 1 小时**，此前按 mtime 估的 2.7h/2.5h 偏高；prep 实测 **≈10.5min**（非 29min）
- rounds.tsv 含全部 30 轮的 pg_gate / pg / gear 三列

### 12.7 ⚑ 基线签收判定（Opus 2026-08-05，从原始数据复核后）

**结论：轮间波动已解决，跨运行复现性未达标 → 基线暂不签收，当前配置只能用于"同一次运行内的 A/B 对比"。**

#### 12.7.1 判据定义（2026-08-05 定，三层，已写进脚本）

验收口径 = **fio 汇总 BW**（逐秒中位数口径仅作参考并列打印）。

| 层 | 指标 | 判据 | 说明 |
|---|---|---|---|
| **L1 逐秒（轮内）** | `stall` | 读项 ≤1%；写项只记录 | 见 12.7.2 定义 |
| L1 | 逐秒 CV | 读项 <6%；写项只记录 | randwrite 结构性双模，30-38% 属正常 |
| **L2 轮间（同一运行内）** | **极差幅度** = (max−min)/median | **≤10%**（沿用最初判据） | 管"最坏单轮" |
| L2 | max_dev = max\|x−median\|/median | ≤5% | 管"离中位数最远的轮" |
| L2 | CV（样本标准差） | ≤3% | 管"整体离散" |
| **L3 跨运行** | median 偏差 | **≤5%** | 2026-08-05 定为 5% |
| L3 | 两跑合并后极差幅度 | ≤10% | 防整档跃迁被单指标放过 |

**为什么 L2 三条必须同时满足（两个都会漏检）：**
- 只看 CV 会漏掉**单点离群**：20 轮里 19 轮 1700、1 轮掉到 1530（−10%），CV 仅 **2.19%** 通过 ≤3%，但极差 10% 能卡住它。
- 只看极差会放过**整档跃迁**：S3+S4 合并 randread 极差幅度 **9.6%**，差 0.4pp 就通过 ≤10%，而其中含 +8.0% 的运行间跃迁。若单用极差，基线会被误签收，后续调优分辨力下限就只有 ~10%。

#### 12.7.2 `stall` 是什么

`gear_stat()` 的逐秒指标：把该轮 128 个 `*_bw.*.log` 按秒聚合成整体 BW 序列 → 只取 15-175s（161 个样本）→ 取该轮**自身**的逐秒中位数 `med` → **`stall% = BW < 0.5×med 的秒数占比`**。

- 抓的是**1 秒级掉底**（吞吐掉到一半以下），典型来源是 `sync`/flush 卡点、backfill/peering 暂停；与"慢档"（`slow`，只比快档低 8-13%）是两回事。
- 这些秒**先被剔除**再做 2-means 聚类，所以 `slow`/`fast` 两档中心不被掉底点污染。
- 判据相对自身 median ⇒ **整体慢 20% 但平稳的轮，stall 仍是 0**。它测抖动，不测快慢。
- 对写项是**真实吞吐损失**：randwrite S3 r1 stall=22.3% ⇒ 180s 里约 36s 不到半速，轮均值被拉低是实况，不是测量误差。
- 读写不能同判据：randread 30 轮全 0.0%；randwrite S3 1.2-22.3%、S4 1.8-11.4%。

#### 12.7.3 达标情况（按三层判据逐项判）

| 层 | 项 | 实测 | 判定 |
|---|---|---|---|
| L1 | randread stall / 逐秒 CV | 0.0%（20/20 轮） / 4.2-5.5% | ✅ 20/20 |
| L1 | randrw stall | 0.0-0.6% | ✅ |
| L1 | randwrite stall | S3 1.2-22.3% / S4 1.8-11.4% | 记录（结构性，不判） |
| L2 | 极差幅度（6 组） | 1.03 / 1.59 / 1.69 / 1.89 / 2.82 / 3.68% | ✅ 6/6（判据 ≤10%） |
| L2 | max_dev（6 组） | 0.77-2.46% | ✅ 6/6（判据 ≤5%） |
| L2 | CV（6 组） | 0.42-1.39% | ✅ 6/6（判据 ≤3%） |
| L2 | PG / 配置 / 负载受控 | 30/30 轮 CLEAN，up_from、config-md5、load_pre(27.9-31.5) 全一致 | ✅ |
| **L3** | **randread median 偏差** | **+8.0%**（1701→1838） | **❌**（判据 ≤5%） |
| L3 | randrw median 偏差 | +4.3%（1166→1216） | ✅ |
| L3 | randwrite median 偏差 | −1.1%（3013→2979） | ✅ |
| L3 | 合并极差幅度 | randread **9.6%** / randrw 6.0% / randwrite 4.2% | ⚠️ randread 擦线（0.4pp） |

**L1/L2 全绿（含最初的 10% 极差判据），L3 randread 红且合并极差擦线 ⇒ 基线不签收。**

历史数据同判据回算（验证判据能区分好坏数据）：

| 组 | 极差幅度 | max_dev | CV | L2 |
|---|---|---|---|---|
| S1-randread（PG 合并期） | **15.80%** | 11.48% | 4.72% | ❌ 三条全破 |
| S1-randrw | 7.06% | 6.48% | **3.49%** | ❌（极差过但 max_dev/CV 破） |
| S1-randwrite | 4.04% | 3.20% | 1.76% | ✅ |
| S2-randread | 0.71% | 0.39% | 0.27% | ✅ |
| S3/S4 全 6 组 | ≤3.68% | ≤2.46% | ≤1.39% | ✅ |

**+8% 已排除的原因**（逐项从原始数据核对）：

| 候选 | 证据 | 结论 |
|---|---|---|
| PG 变动 / backfill | 两跑 pg_count=32、nonclean=0、primary 分布完全相同 | 排除 |
| 配置漂移 | `config-md5` 两跑完全相同 | 排除 |
| OSD 重启 | `up_from` 两跑完全相同 | 排除 |
| 主机负载/时段 | `load_pre` S3 28.8-31.5 vs S4 27.9-31.0 | 排除 |
| 工作量/放大率变化 | `c_amp` S3 2.08 vs S4 2.07；每轮 onode_misses 增量均为 0（缓存都已暖） | 排除 |
| 客户端缓存命中 | hit_rate S3 51.2-51.8% vs S4 49.9-50.3%（**S4 命中更低却更快**） | 排除 |

**差异定位到客户端 FUSE 延迟**：`lat avg` 2392.6ms → 2218.9ms（−7.2%），`clat p50` 2366 → 2198ms，`>=2000ms 占比` 94.99% → 86.78%，与 BW +8% 完全对应。

**形态是"整档跃迁"而非"渐变漂移"**：各运行内 p50 完全平坦（S3 1690-1713、S4 1828-1860），gear 快档中心 S3 ~1710-1729 → S4 ~1842-1875。唯一未受控的变量是**池侧/后端跨运行残留状态**（S4 的 randread 发生在 S3 的写阶段之后，而 prep 的 `gc --compact` + `reset_state` + remount 只复位客户端，不复位这个状态）。

**影响**：此刻若进入调优，任何 ≤8% 的"收益"都无法与运行间跃迁区分（L3 判据放宽到 5% 后，分辨力下限仍是 8%）。**先定档，再调优。**

### 12.8 ⚑ S5 已取消，改为 R1 归因实验 + 全量基线（2026-08-05 定）

**S5（只读定档）取消**，理由：它只是分类器（首运行效应/写后效应/漂移），三个出口都只产出"采集规则"，**不产出机制、也不消除那 8%**；而汇报基线必须出自 7 项的 `FULLBASELINE_V4.sh`、且无论如何要连跑 ≥2-3 次，run1/run2/run3 的相互对比会自动完成同一分类，专门跑 S5 是重复劳动。

**替代方案 R1 = remount 敏感性实验**（`debug/remount-sensitivity-test.sh`，1h，只读）。

立论依据（结构事实）：`reset_state()` 内**无条件** remount，且只在 prep 执行一次 ⇒ **运行内 10 轮共用同一个 JuiceFS 进程，运行间是全新进程**。这与实测形态完全吻合（运行内 p50 平坦、运行间整档跃迁）。`jfs-stats` 佐证 S4 为全新进程（`cpu_usage` 1182s vs 1163s、`fuse_ops_total` 4739094 vs 4738897，非累加）。加上 157 的 core 1-16 被外部租户 100% 占满，**进程落核/NUMA/一次性初始化足以造成 8%**。

设计：池状态固定、只跑 randread（读 `read_test.*`，永不被写覆盖），prep 一次后做 **6 组 × [优雅 remount → 采集落核/mpstat → 2 轮 randread]**，判档用每组第 2 轮。

| R1 结果 | 归因 | 解决动作 |
|---|---|---|
| 组间极差 ≤5%（单档） | 排除进程级 ⇒ 档位由池侧状态决定 | "弃首运行"规则成立，8% 不再由 remount 触发 |
| **两簇且簇间 ≥5%** | **进程级** | 与落核相关 ⇒ `numactl/taskset` 绑核并入 V4；无关 ⇒ 固定进程启动方式 |
| 随组序单调 | 漂移 | "弃首运行"无效，转 OSD 侧采集另立实验 |

命令（GLM 执行）：`bash debug/remount-sensitivity-test.sh 6 2`

⚑ **2026-08-05 已执行完毕，命中第二出口（多档，组间极差 29.9%）** —— 结果与判定见 **§十三**。本节的"6 组 × 2 轮"设计实际跑成 10 组 + 1 轮（调用参数误传），数据量反而更充分。

### 12.9 原始数据

```
WSL: ~/demo/production/prod-deploy/results/E6/opencode-fullbaseline-v4/
├── README-目录含义.md               ⚑ 2026-08-05 新增：7 组数据的池/脚本/可用性对照
├── E6/    老池 pool 2，7 项，无每轮 compact（randwrite 崩塌 3056→794）
├── E6C/   老池 pool 2，7 项 + 每轮 compact（写项已稳；randread 为污染态）
├── S1-pg-merging/   ⚑ 原 S1/，新池但全程在 PG 合并期，L2 FAIL，仅作反面对照
├── S2-newpool/      ⚑ 原 S2/，新池 32PG 干净期，只有 randread r1-r7（r7 无 bw log）
├── S2-oldpool/      ⚑ 新建：原混装在 S2/ 里的老池 randrw-S2-r*、randwrite-S2-r*
├── S3/    新池，randread 10 轮 + randrw/randwrite 各 5 轮
├── S4/    新池，同上
└── rounds.tsv       LABEL 仍为历史 S1/S2（未改），对应关系见 README

WSL: ~/demo/production/prod-deploy/results/E6/test-S3S4.log    S3+S4 日志（157 时间）

脚本（2026-08-05 后唯一出数脚本）：
  scripts/FULLBASELINE/FULLBASELINE_V4.sh        ~~1177 行 md5 4143519681c6964a66f4bd09aa57eeb0~~
    ⚑ 2026-08-05 二次更新：**1242 行 md5 6aab2a65bbd1806078ed072d15ee5af2**（新增 SKIP_REMOUNT + 挂载实例身份记录）
    └ 已并入：每轮 gc --compact / PG 门禁 / 统一口径判据+GUARD / gear 诊断 / 四级优雅卸载 / ITEMS / SKIP_REMOUNT
  scripts/FULLBASELINE/debug/remount-sensitivity-test.sh  325 行 md5 ed3d2b6ff95fdd1ccfdb7f9f968ee35c（R1，已完成，用完即弃）
  scripts/FULLBASELINE/debug/mount-gear-attrib-test.sh    ⚑ 487 行 md5 de5773460e5a67165e94b8611d83fb6d（R2，待执行，用完即弃）
  scripts/FULLBASELINE/debug/stability-test.sh   ⚑ 已冻结，勿用于出数（措施已并入 V4）
```

### 12.10 ⚑ 基线成立的前提条件（2026-08-05 固化）

| 类别 | 值 |
|---|---|
| 池 | pool 3 `juicefs-data`，EC 4+2（`ec-prod` size 6 min_size 5），`pg_num 32 pgp_num 32`，**`pg_autoscale_mode off`**，`fast_read 1`，`hashpspool,ec_overwrites`，`crush_rule 1`，`stripe_width 16384` |
| PG 分布 | primary `[0:6 1:6 2:5 3:6 4:5 5:4]`（1.5:1） |
| OSD | 6 个全 up，`up_from 0:889 1:888 2:884 3:892 4:896 5:895`；`osd.3` 缺 `osd_mclock_max_capacity_iops_ssd`（回落 21500） |
| ceph 配置 | `config dump` md5 `ea35053a582b8e36d010da90307e8370`；`bluestore_cache_size=30GiB`、meta 0.05/kv 0.30/data 0.65、`autotune=false` |
| 挂载 | `juicefs mount -d --max-uploads 150 --cache-size 0`，`BlockSize=256K`、`TrashDays=0` |
| 客户端 | 157 core 1-16 被外部租户 100% 占满；`load_pre` 常态 27.6-32.0；11-12 个 D 态进程（`ceph_mdsc_wait_request` 残留 sb，与 JuiceFS/TiKV 无关） |
| 判据 | 口径 逐秒均值(15-175s)；L2 轮间极差 ≤5%；L3 跨运行 median 偏差 ≤5%；GUARD=OK<br>⚑ 2026-08-05 追加：**L3 只在"探针判定为同档的实例之间"有意义**；用户已授权在 R3 不达标时把 L3 放宽到 ≤10%（见 §14.6） |
| 已知未归因 | ~~**跨运行 randread +8.0% / randrw +4.3% 整档跃迁**（R1 待查）~~ ⚑ 2026-08-05 **已归因：档位由 JuiceFS 挂载实例决定，跨实例极差 29.9%（1334-1891 MiB/s），8% 只是其中一次抽样** —— 见 §十三。**机制（落核/NUMA/连接哈希）仍未定，R2 待查。** ⚑ 2026-08-05 **R2 已跑完：RSS/IRQ 饥饿假设被否证（r=+0.01），机制放弃归因**；改走 §14.5 R3 档位甄别协议（探针验签，不消除抽签），高档命中 55%、档内极差 2.2% |
| ⚑ 追加前提 | **同一挂载实例内比较**。跨 remount 的两次运行不可直接比较（含 L3 判据、含历史各 LABEL 之间的对比）。<br>⚑ 2026-08-05 放宽：跨实例比较需**两实例均经 75s 探针判为同档**（高档带 1830-1930）方可进行。 |
| ⚑ randrw/randwrite 专属前提（2026-08-06 R4 定，R5 收紧） | ①**每个测量块前 `juicefs gc --compact`**（R4/R5 实测均可把 `juicefs-data` objects 精确复位到 235950x）；②**每轮前后必须记 `ceph df` objects**（脚本 `pool_stat()` 已内建）；③~~objects ≤4.4M 可用 A-B-A~~ ⚑ R5 收紧为 **轮前 objects ≤3.11M（compact 后最多 2 轮），判定只认第 1 轮**（§18.6.2：3.78M 那轮的轮内趋势已转负）；④越界数据一律作废重测，并以"轮内 q1→q4 趋势跌破 −5%"作为越界的领先报警；⑤`gc --compact` 成本 ≈ **1.95e-4 s × 回收对象数**（只跑 1 轮 ⇒ ≈148s；R5 跑 5 轮 ⇒ 576s），须计入预算。 |
| ✅ **randrw 基线签收（2026-08-06 R5 定，§18.6.4）** | **2400 MiB/s**；口径三条同时满足：①实例经 75s randread 探针门控落在 [1830,1930]；②该轮前刚做过 `gc --compact`（轮前 objects=2.36M）；③逐秒均值 15-175s。样本 n=4（R4 A-rw1/B-rw1 = 2381/2395、R5 A-rw1/B-rw1 = 2408/2435），均值 2405、极差 2.3% ⇒ 可检出 ≥3% 调优效应。 |

---

## 十三、R1 remount 敏感性实验（2026-08-05）

### 13.1 背景

§12.7 中 S3→S4 randread 跨运行 +8.0% 整档跃迁未归因。`reset_state()` 内无条件 remount 且只在 prep 执行一次 ⇒ 运行内 10 轮共用同一 JuiceFS 进程，运行间是全新进程，与实测形态吻合（运行内平坦、运行间跃迁）。

R1 实验：池状态固定，只跑 randread（读 `read_test.*`，永不被写覆盖），prep 一次后做 6+ 组 × [优雅 remount → 采集落核/mpstat → 2 轮 randread]，判档用每组第 2 轮。

### 13.2 执行

- 脚本：`debug/remount-sensitivity-test.sh`（md5 `ed3d2b6ff95fdd1ccfdb7f9f968ee35c`）
- 命令：`bash /tmp/remount-sensitivity-test.sh 6 2`，`r1.log` 第 2 行为 `R1 remount 敏感性测试 1002 组 × 2 轮`，跑到 g11-r1 后手动 kill，实得 **10 组完整 + g11-r1**（多出的 4 组反而提高了结论强度）
  - ~~⚑ 订正：脚本 `GROUPS="${1:-6}"` 解析正常，是调用时把第一个参数传成了 1002（非脚本 bug，勿去修脚本）~~
  - ⚑⚑ **二次订正（2026-08-05，R2 复现同一现象后定位）：这是脚本 bug，GLM 的原始判断是对的，我上一版订正判错了。**
    根因：**`GROUPS` 是 bash 的特殊数组变量**（当前用户所属组列表），**对它的赋值被静默忽略**，`${GROUPS}` 展开为主组 gid —— 157 上用户 `sunrise` 的 gid = **1002**，WSL 上 = 1000。
    证据：R2 以 `bash /tmp/mount-gear-attrib-test.sh 12` 启动（`ps` 确认 argv 就是 `12`，脚本 md5 与仓库一致），日志仍打印 `1002 组`；本地 `GROUPS="${1:-12}"; echo ${GROUPS}` 复现输出 `1000`（= WSL gid）。
    修复：R1/R2 的变量一律改名 **`NGROUPS`**，并在脚本头注写明该坑。**教训：变量名不得使用 bash 特殊变量（`GROUPS`/`UID`/`PWD`/`SECONDS`/`RANDOM`/`LINENO`/`PPID`/`FUNCNAME`/`BASH_*`）。**
- 起止（157 本地时间）：10:28:51 → ~11:41（prep 含 `gc --compact` 44s + warmup 111s，10:28:53→10:31:42）
- 全程只读：不写测试数据、不改 ceph 配置、不动 pg_autoscale、不重启任何服务
- PG 状态（pg-state.txt）：全程 pool=3 pg_num=32 nonclean=0；每轮 `config-md5.txt`/`up_from.txt` 无变化

### 13.3 结果

⚑ **本节原表用的是 fio 汇总口径且只取 r2**，违反 §12.7 定的验收口径，且丢掉了 r1 —— 而 **r1 vs r2 正是本实验唯一的隔离证据**。下表按验收口径（**逐秒均值 15-175s**，与 `FULLBASELINE_V4.sh` 的 `parse_bwlog_mean` 同一实现）从 21 轮 `*_bw.*.log` 全量重算，fio 汇总作参考并列。

| 组 | r1 逐秒均值 | r2 逐秒均值 | 组内 r1→r2 | r2 fio汇总 | stall | pid | taskset 掩码 |
|---|---|---|---|---|---|---|---|
| g1 | 1876 | 1868 | −0.4% | 1872 | 0 | 3689305 | 0,17-64,81-127 |
| g2 | 1869 | 1864 | −0.3% | 1867 | 0 | 3747384 | 同 |
| g3 | 1858 | 1857 | −0.0% | 1860 | 0 | 3805965 | 同 |
| **g4** | **1714** | **1714** | **+0.0%** | 1720 | 0 | 3864092 | 同 |
| g5 | 1870 | 1870 | −0.0% | 1872 | 0 | 3922962 | 同 |
| **g6** | **1328** | **1334** | **+0.5%** | 1332 | 0 | 3981336 | 同 |
| g7 | 1730 | 1749 | +1.1% | 1756 | 0 | 4039485 | 同 |
| g8 | 1887 | 1891 | +0.2% | 1891 | **12.4%(r1)** | 4098046 | 同 |
| g9 | 1885 | 1879 | −0.3% | 1880 | 0 | 4156586 | 同 |
| g10 | 1740 | 1792 | +3.0% | 1793 | 0 | 22189 | 同 |
| g11 | 1746 | (kill) | — | — | 0 | 80878 | 同 |

- **组内**：两轮差 ≤1.1%（g10 例外 +3.0%）。
- **组间**（r2 十组）：median **1860**，极差幅度 **29.9%**，max_dev 28.3%，CV 9.4%，range **1334-1891**。
  ~~极差 42%~~ ⚑ 42% 是 `max/min−1`；本报告统一定义为 `(max−min)/median` = **29.9%**。
- ~~g6 异常低（1332），g4 偏低（1720）~~ ⚑ **订正：二者都不是离群值**。g6 = 1328/1334（两轮差 0.5%）、g4 = 1714/1714，是**稳定的低档**；按"异常值剔除"处理会直接毁掉结论。
- 档位**从第 2 秒即成立**并保持全程（g6-r1 前 12 秒 `40 1046 1331 1344 1345 1315 1280 1424 1222 1372 1589 1089`，g8-r2 `25 1674 1871 1909 1839 1854 1866 1804 1943 1936 1944 1955`），低档轮 `stall=0`、序列**整体下移**而非掉坑。
- 主机负载**不解释**档位：g6（最慢 1334）的 `load_pre` 28.93-29.85，是全部 21 轮中**最低**的一档；g8（最快 1891）的 `load_pre` 反而 29.00-31.13。
- ~~全 10 组 affinity 完全相同：`0,17-64,81-127`（排除 core 1-16 被外部租户占满的区域）~~ ⚑ **订正：掩码相同不能排除落核**。`taskset` 只是**允许集合**，不是实际落核。实际线程落核（`placement.txt` 直方图，157 = 2×32c/128t，**NUMA 奇偶交错**：node0 = 偶核、node1 = 奇核）：

| 组 | r2 BW | 线程在 node0 | node1 | node1 占比 |
|---|---|---|---|---|
| g1 | 1868 | 2 | 24 | 92% |
| g2 | 1864 | 24 | 2 | 8% |
| g3 | 1857 | 26 | 4 | 13% |
| g4 | 1714 | 1 | 29 | 97% |
| g5 | 1870 | 2 | 26 | 93% |
| g6 | 1334 | 24 | 1 | 4% |
| g7 | 1749 | 5 | 21 | 81% |
| g8 | 1891 | 1 | 27 | 96% |
| g9 | 1879 | 1 | 27 | 96% |
| g10 | 1792 | 4 | 23 | 85% |
| g11 | 1746 | 4 | 24 | 86% |

  ⇒ **每个挂载实例的 34 个线程几乎全压在单个 NUMA node 上，且该 node 逐实例随机**；但与档位**不单调对应**（g2 在 node0 却快 1864、g6 在 node0 最慢 1334；g4 在 node1 却慢 1714）。落核仍是**活候选**，但 `placement.txt` 是挂载后的**瞬时空载快照**，不足以定论 —— 需负载中采样（R2）。

### 13.4 原始数据

```
WSL: /tmp/r1-remount-sensitivity/    10 组完整 + g11-r1（g11-r2 被 kill，无 fio.txt）
├── g1~g11/                          每组含 placement.txt（pid + taskset + 线程落核直方图 + VmRSS + uptime + mpstat -P ALL + mount 行）
├── g1-r1~g11-r2/                    每轮含 fio.txt、128 个 *_bw.*.log、load.txt、config-md5.txt、up_from.txt
├── pg-state.txt                     PG 状态快照
└── r1.log                           脚本自身日志（含 "1002 组" 的参数误传证据）

WSL: /tmp/r1-run.log                完整运行日志（stdout+stderr）
157: /tmp/r1-remount-sensitivity/   原始数据仍在 157 上

脚本：scripts/FULLBASELINE/debug/remount-sensitivity-test.sh
复核脚本：/tmp/opencode/r1_verify.py（逐秒均值/中位数/stall/组内差/落核相关性，可弃）
```

### 13.5 ⚑ 判定：命中"多档"出口 —— 档位属于 JuiceFS 挂载实例

脚本因参数误传未跑到判定行，判定由原始数据补出：

| 事实 | 排除对象 |
|---|---|
| fio **每轮都是新进程**，而组内 r1≈r2（≤1.1%） | 档位**不属于 fio 进程** |
| 池/PG/`config-md5`/`up_from` 全程未变，同一份 `read_test.*` | 不属于**集群侧** |
| `load_pre` 全程 27.9-31.5，最慢组反而负载最低 | 不属于**主机负载** |
| 组间 median 极差 **29.9%**，档位从第 2 秒即成立并锁定整组 | ⇒ **唯一跨 r1/r2 保持、跨组变化的实体 = JuiceFS 挂载实例（含其 FUSE 连接）** |

**结论**：`remount` 本身不是波动源，它是**抽签动作**；真正的源是**每个挂载实例被"抽"到的档位**。

**这不是"另一个"波动源，而是把 §12.7 的 +8.0% 收编进来的同一个源**：S3 = 1698、S4 = 1834 都落在 R1 观测区间 **1334-1891** 内 ⇒ 跨运行 +8.0% 就是该分布的一次抽样，**8% 并非上限，最坏 −29%**。

档位分布看起来不是二元的，而是若干档（≈1870 / ≈1790 / ≈1750 / ≈1714 / ≈1334，叠加历史 S3 1698、S4 1834）⇒ 更像"连续的落核/连接质量"而非单一开关。**机制未定**，候选（按可检验性排序）：

1. **到 OSD/TiKV 的 TCP 连接被 RSS 哈希到"饥饿队列"** ⚑ **2026-08-05 只读采集，已升级为主假设**（详见 §13.5.1）
2. 线程落核 / 内存首触 NUMA 页分配（node 逐实例集中且随机，已见；但空载快照与档位不单调对应）
3. Go runtime 一次性初始化差异（GOMAXPROCS/P 绑定）

#### 13.5.1 ⚑ 主假设：RSS/IRQ 饥饿（157 只读采集的硬事实）

| 事实 | 来源（只读命令） |
|---|---|
| 到 OSD 的流量实际走 **`eno12399`**（i40e），`src 10.20.1.157` | `ip route get 10.20.1.150` |
| `eno12399` 的 PCI 设备在 **NUMA node0**；另两张 `enp139s0f*` 在 node1（本路径不走） | `/sys/class/net/*/device/numa_node` |
| 该网卡有 **119 个 `i40e-eno12399-TxRx-*` 队列**，IRQ **全部钉在偶核（node0）** | `/proc/interrupts` + `/proc/irq/<n>/smp_affinity_list` |
| **其中 9 个 IRQ 钉在 core 2/4/6/8/10/12/14/16** —— 正是被外部租户 100% 占满的 core 1-16 区间（`irq 694/710/711/713/730/731/744/778/785`）；1 个在 core 0，其余 109 个在 core≥17 | 同上 |
| **RPS 全关**（`rx-*/rps_cpus = 0`）⇒ 收包软中断只能在该 IRQ 的绑定核上执行，无法迁移 | `/sys/class/net/eno12399/queues/rx-*/rps_cpus` |
| 157 = 2×Xeon 8462Y+，NUMA 奇偶交错（node0=偶核、node1=奇核） | `lscpu` |

**推论**：每次 remount 都会重建到 OSD/TiKV 的 TCP 连接，**源端口随机** ⇒ RSS 四元组哈希把连接分到不同队列。某条关键连接一旦落到那 9 个饥饿队列之一，其收包处理被外部租户挤住，**整档下移**。

与 R1 全部观测的一致性：

| R1 观测 | 本假设的解释 |
|---|---|
| 档位锁定挂载实例 | 连接生命周期内源端口不变 ⇒ 队列不变 |
| 多档且连续（不是二元） | 命中 0/1/2/3 条饥饿连接的剂量差异 |
| 最坏 −29% | 单条关键连接被 100% 占满的核拖住，量级吻合 |
| 与线程 NUMA 落核不相关 | 差异发生在**软中断侧的核**，不在 juicefs 线程所在核 |
| 与 `load average` 不相关（最慢组 load 最低） | 饥饿核**始终**满载；变化的是"你的流是否落在那儿" |
| 与 fio 无关（fio 每轮新起而档位不变） | fio 只走 FUSE，不建 TCP |

**待验**：以上是静态配置 + 逻辑推演，尚缺"低档组的流量确实落在饥饿队列"的直接观测 ⇒ R2（§13.7）。

### 13.6 ⚑ 对基线与调优的影响（比 8% 本身严重）

1. **全量基线 B1/B2 按现方式跑必然 L3 FAIL，应暂停**。`reset_state()` 每次运行无条件 remount ⇒ 每次运行等于重新抽签，L3 ≤5% 在档位极差 29.9% 下不可能达成。**这不是判据太严，是采集方式与判据不兼容。**
2. **调优 A-B-A 必须共用同一挂载实例**。旋钮走 `ceph config set` 在线切换、全程不 remount，否则档位噪声（≤30%）压倒任何调优效应（预期收益量级 5-15%）。⇒ V4 需增 `SKIP_REMOUNT=1`，或把 A-B-A 放进一次脚本调用内完成。
3. **历史跨 LABEL 的同配置对比全部存疑**（E6→E6C 的 −14%、S2-newpool 的 +14%、S1/S2/S3/S4 相互之间），因为每个 LABEL 都是独立挂载实例。按既定原则（不追不影响结论的旧问题）**不回溯重测**，但**不得再用这些跨 LABEL 差值支撑任何机制结论**。
4. **§12.10 前提条件追加一条**：*同一挂载实例内比较*。
5. 判据本身**不改**（1 口径 + 2 判据 + 1 守卫仍然有效）：L2 描述的是"同一挂载实例内的轮间稳定性"，R1 中 10 个组的组内表现（≤1.1%）恰好证明 **L2 是可达成的**；问题只在 L3。

### 13.7 下一步（R2 + V4 补丁，脚本已就绪）

详细交接见 `/tmp/bridge/analysis.md` 的 **§-R1-RESULT**。

**R2 = `debug/mount-gear-attrib-test.sh`（487 行，md5 `de5773460e5a67165e94b8611d83fb6d`，`bash -n` + python 段语法均通过，三个判定出口已用构造数据自测命中）**

- **12 组 × 1 轮 randread**（R1 已证组内 r1≈r2 ⇒ 单轮足够；同成本把组数翻倍，最大化相关性样本），≈1.1h
- **12 组全部保持"现状挂载"（不绑核）**：自变量是"这次抽签抽到哪些队列"，人为绑核会破坏抽签
  ~~原计划 A/B 两臂各 6 组（不绑核 / `numactl` 绑核）~~ ⚑ 改为单臂 —— §13.5.1 把主假设从"线程落核"换成"RSS/IRQ 饥饿"后，绑核不影响队列选择，且两臂会把相关性样本砍半；绑核降为 R3 的解法验证
- **在 fio 运行中**每 15s 采样（与 R1 只采挂载后空载快照的关键差别）：
  1. `/proc/interrupts` 中 `eno12399` 各队列的中断增量（t0 → tend 差分）⇒ 本次流量落在哪些队列
  2. `ss -tinp` juicefs 的连接：本地端口 / rtt / cwnd / retrans
  3. juicefs 线程落核（按 NUMA 奇偶归并）
  4. `mpstat -P ALL` 各核 `%usr/%sys/%soft`
- **判定出口（脚本自动打印）**：
  | 条件 | 判定 |
  |---|---|
  | Pearson `r(BW, 饥饿队列中断占比) ≤ −0.6` 且低档组占比 > 高档组 | **机制定案 = RSS/IRQ 饥饿**，给出三级解法 |
  | 方向一致但相关弱 | 饥饿队列只是部分因素，另有共因 ⇒ 看 `%soft` 与 `ss` rtt |
  | 无相关 | 转候选 2/3（线程落核 / Go 初始化） |
  | 12 组极差 ≤5% | 本次未复现多档 ⇒ R1 的分散可能含当日外部租户瞬态，需重复 R1 |
- **只读**：不改 ceph 配置、**不改 IRQ 亲和性**（`/proc/irq/*/smp_affinity*` 只读）、不动 RPS/ethtool、不动 pg_autoscale、不重启服务；唯一写操作是 `juicefs umount/mount` 与 `drop_caches`（已授权）；沿用四级优雅卸载

**解法候选（R2 定案后再选，均需另行授权）**：① 开 RPS 把软中断搬到空闲核（可回滚、对其他租户无害）；② 迁那 9 个队列的 IRQ 亲和到 core≥17；③ `ethtool -L/-X` 缩减 RSS 队列集（侵入最大）。

**V4 补丁：`SKIP_REMOUNT=1`（已实现）**

| 取值 | 行为 | 用途 |
|---|---|---|
| `0`（默认） | 原行为，每次运行 remount | 出汇报基线；**此时 L3 FAIL 属预期**，直到档位问题定解 |
| `1` | `reset_state` 不 remount，沿用现有挂载实例（`gc --compact` 与 `drop_caches` 仍执行） | **调优 A→B→A 必须用**，使三次跑落在同一档位，消除 ≤30% 档位噪声；旋钮走 `ceph config set` 在线切换 |

配套：每次运行把挂载实例身份（pid + `/proc/<pid>/stat` starttime + `ps lstart`）落盘 `jfs-instance-<LABEL>.txt`；`guard_report` 会与 `REF_LABEL` 比对 starttime，**不同实例时明确打印"该 L3 判定不足以支撑结论"**。若 `SKIP_REMOUNT=1` 但当前未挂载，会 forced-mount 并留痕。

---

## 十四、R2 挂载档位机制归因实验（2026-08-05）

### 14.1 背景

§13.5 R1 判定档位属于 JuiceFS 挂载实例，主假设为 RSS/IRQ 饥饿（§13.5.1）。R2 验证该假设：12 组 × 1 轮 randread，每组 remount 后在负载中采集 IRQ 中断分布、ss 连接状态、线程落核、mpstat。

### 14.2 执行

- 脚本：`debug/mount-gear-attrib-test.sh`（md5 `2d738d3bceaa739d48482409758413b5`）
  - 第一版（md5 `d3900622a7e350db8e4df4effea80306`）因 `safety_check_boot` 在 `safety_check` 定义前调用而 crash（`command not found`），修复函数定义顺序后重跑
- 命令：`bash /tmp/mount-gear-attrib-test.sh 12`（参数 12 正确解析为 12 组 × 1 轮）
- 起止（157 本地时间）：13:25:06 → 14:08:48
- 全程只读：不写测试数据、不改 ceph 配置、不改 IRQ 亲和性、不动 RPS/ethtool、不重启服务
- PG 状态：全程 pool=3 pg_num=32 nonclean=0

### 14.3 结果

**12 组表（逐秒均值 / 饥饿队列中断占比 / 活跃队列数 / 其中饥饿 / 线程node1占比 / 本组饥饿队列数）：**

| 组 | 逐秒均值 | 饥饿队列中断占比 | 活跃队列数 | 其中饥饿 | 线程node1占比 | 本组饥饿队列数 |
|---|---|---|---|---|---|---|
| g1 | ~~2162~~ **1886** ⚑ | 10.88% | 91 | 11 | 5% | 15 |
| g2 | 1310 | 15.09% | 88 | 14 | 88% | 17 |
| g3 | 1889 | 17.63% | 93 | 18 | 84% | 21 |
| g4 | 1883 | 17.60% | 94 | 18 | 27% | 20 |
| g5 | 1402 | 18.87% | 88 | 19 | 92% | 22 |
| g6 | 1851 | 18.45% | 90 | 16 | 87% | 18 |
| g7 | 1728 | 20.90% | 89 | 19 | 94% | 22 |
| g8 | 1719 | 18.47% | 92 | 19 | 16% | 22 |
| g9 | 1863 | 19.19% | 90 | 16 | 83% | 22 |
| g10 | 1401 | 19.09% | 89 | 17 | 81% | 18 |
| g11 | 1880 | 21.82% | 91 | 19 | 88% | 22 |
| g12 | 1741 | 17.40% | 89 | 14 | 14% | 19 |

> ⚑ **g1 = 1886，不是 2162（GLM 第 7 处错误，2026-08-05 Opus 复核）**
> 根因：`g1-r1/` 目录里混进了 **128 个 `g7-r1_bw.*.log`**（850 B 的半截日志，来自 8-05 上午被 kill 的
> GROUPS-bug 那次跑），而分析器用 `*_bw.*.log` 通配 ⇒ g1 把两次跑的带宽加总。
> 脚本层根因见 §14.4.1。影响：①g1 真值 1886（fio 汇总 1888 亦为此值，两者本就一致，
> 当时应当发现矛盾）；②组间极差 **47.5% → 32.2%**（与 R1 的 29.9% 一致）；
> ③Pearson r **−0.24 → +0.01**，即**主假设从"弱相关"变成"完全无相关"**。

**fio 汇总 BW（参考）：**

| 组 | g1 | g2 | g3 | g4 | g5 | g6 | g7 | g8 | g9 | g10 | g11 | g12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| BW | 1888 | 1305 | 1889 | 1884 | 1402 | 1854 | 1750 | 1719 | 1864 | 1402 | 1882 | 1743 |

**各组中断量 top5 队列：**

```
g1   irq688(c30)=4.6% irq737(c0)=4.0% irq707(c106)=2.6% irq782(c70)=2.2% irq740(c114)=2.0%
g2   irq688(c30)=5.5% irq737(c0)=3.5% irq745(c120)=2.2% irq777(c14*)=2.1% irq705(c38)=1.7%
g3   irq688(c30)=4.0% irq737(c0)=3.7% irq729(c124)=2.9% irq707(c106)=2.2% irq790(c60)=1.9%
g4   irq688(c30)=3.8% irq737(c0)=3.3% irq728(c108)=2.9% irq690(c38)=2.3% irq726(c92)=2.3%
g5   irq688(c30)=4.5% irq737(c0)=3.5% irq726(c92)=2.5% irq801(c48)=2.3% irq798(c78)=2.3%
g6   irq688(c30)=4.0% irq737(c0)=3.4% irq726(c92)=2.8% irq728(c108)=2.5% irq751(c66)=2.3%
g7   irq688(c30)=4.5% irq737(c0)=3.9% irq729(c68)=2.4% irq726(c92)=2.3% irq722(c82)=2.2%
g8   irq688(c30)=3.8% irq737(c0)=3.5% irq726(c92)=2.7% irq709(c68)=2.6% irq788(c42)=2.0%
g9   irq737(c0)=5.2% irq688(c30)=4.6% irq771(c106)=3.9% irq705(c14*)=1.9% irq728(c108)=1.9%
g10  irq688(c30)=4.7% irq737(c0)=4.1% irq734(c46)=2.1% irq741(c114)=2.1% irq739(c4*)=2.0%
g11  irq688(c30)=4.2% irq737(c0)=3.9% irq713(c4*)=2.6% irq752(c116)=2.3% irq775(c116)=2.2%
g12  irq737(c0)=5.3% irq688(c30)=4.3% irq710(c2*)=2.7% irq692(c14*)=2.5% irq705(c14*)=1.8%
```

（`c14*` = 钉在 core 14 的饥饿队列）

**组间统计 + 判定 + GUARD：**

```
~~组间: n=12 median=1796 极差幅度=47.5% range=1310-2162~~
~~低档组(<median) 饥饿占比均值=18.30%  高档组 饥饿占比均值=17.60%  Pearson r(BW,饥饿占比)=-0.24~~
~~判定: 方向一致但相关性弱（r=-0.24）⇒ 饥饿队列是部分因素，另有共因~~

⚑ 修正后（Opus 2026-08-05 从原始 bw log 复核）：
组间: n=12 median=1796 极差幅度=32.2% range=1310-1889
饥饿核队列数=7 / 总队列数=119
低档组(<median) 饥饿占比均值=18.30%  高档组 饥饿占比均值=17.60%  Pearson r(BW,饥饿占比)=+0.01

判定: 🔴 主假设被否证 —— 与饥饿队列无相关（r=+0.01，两组差 0.7pp）

GUARD: 非优雅卸载=0  config-md5种类=1  up_from种类=1  INVALID轮=0  OK
```

### 14.4 ⚑ 判定：RSS/IRQ 饥饿假设被否证；但档位结构清晰可用

**主假设不成立。** 修正后 `Pearson r(BW, 饥饿队列中断占比) = +0.01`，低档组 18.30% vs 高档组 17.60%（差 0.7pp，
方向还与假设相反）。逐组快照证明 12 组的饥饿队列命中数（14-22 个）与档位无任何单调关系：
g11 命中 19 个却是 1880（高档），g2 命中 17 个却是 1310（最低档）。**IRQ/RSS 路线到此终止，不再追。**

同时否证/排除的还有：线程落核 NUMA（g1 线程 95% 在 node0 → 1886；g4 27% 在 node1 → 1882；
g2 88% 在 node1 → 1310 ⇒ 无关）、活跃队列数（88-94，与档位无关）。

**但排序后档位结构非常干净（这才是有用的发现）：**

| 档 | 值（MiB/s） | R2 组 | 档内极差 |
|---|---|---|---|
| 高档 | 1850 / 1863 / 1880 / 1882 / 1886 / 1888 | g6 g9 g11 g4 g1 g3 | **2.0%** |
| 中档 | 1719 / 1732 / 1738 | g8 g7 g12 | 1.1% |
| 低档 | 1401 / 1403 | g10 g5 | 0.1% |
| 最低 | 1310 | g2 | — |

**R1 + R2 合并 22 次独立挂载**：高档带（1850-1891）命中 **12/22 = 55%**，**档内极差仅 2.2%**。
⇒ **结论：不需要查清机制也能拿到可签收基线 —— 只要不再"抽完签就认"，而是抽完签后验签。**
这正是 §13.6 里被忽略的一条出路：波动源是随机抽签，而抽签结果是**可观测**的。

### 14.4.1 ⚑ 三个脚本层 bug（均已修，均由本次复核暴露）

| # | bug | 后果 | 修法 |
|---|---|---|---|
| 1 | `BW_LOG_DIR` 只在每轮 cp 之后清，不在启动时清 | 被 kill 的上一次跑的残留 bw log 被**下一次跑的第一组**通配捞走并加总 ⇒ R2 g1 = 2162（真值 1886） | 启动即 `purge_bw_log_dir()`；`cp` 改为只取 `${label}_bw.*.log` 前缀；落盘后校验个数必须 = 128，否则标 INVALID；分析器同样按目录名前缀取文件并对残留告警 |
| 2 | `n=$(ls glob 2>/dev/null \| wc -l)` 在 `set -o pipefail` 下，**glob 无匹配时 ls 返回 2 ⇒ 整条管道非 0 ⇒ `set -e` 静默杀掉脚本** | R3 首次桩测试在第一行日志前就退出（无任何报错） | 新增 `count_glob()` 用 bash 数组计数，全脚本替换 4 处 |
| 3 | **`FULLBASELINE_V4.sh` 的 `guard_report` 同时中招**：`nu=$(ls ${RESULTS}/UNCLEAN_UMOUNT.txt \| wc -l)` 等 3 处 + `[ ... ] && reasons=...` 形式的 AND-list 末位失败 | 这三个守卫文件**不存在才是正常情况** ⇒ **每次成功的跑都在收尾 exit 2，`GUARD=OK` 从未真正打印过**（S3/S4 报告里的 GUARD=OK 是人工从原始数据核出来的，不是脚本产出） | 同样改 `count_glob()`，AND-list 补 `\|\| true`，调用点改 `guard_report \|\| true`；隔离验证 OK/FAIL 两分支均正常返回 0 |

> bug 2/3 属同一类：**`set -euo pipefail` + `ls glob | wc -l` / 末位 AND-list**。`bash -n` 与
> `fnorder_check.py` 都查不出，只有真实执行能暴露 ⇒ 今后新脚本一律先过桩测试再上 157。

### 14.5 ⚑ R3 档位甄别协议（取代继续追机制，2026-08-05 定）

**协议**：`remount → 75s 探针判档 → 落在 [1830,1930] 才留用，否则丢弃重新 remount → 合格实例内跑正式轮`。

探针可行性已用 R2 原始数据验证（15-60s 窗口 vs 15-175s 全窗口）：

| 组 | g1 | g2 | g3 | g4 | g5 | g6 | g7 | g8 | g9 | g10 | g11 | g12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 探针误差 | +0.7% | −1.4% | +0.7% | +0.5% | +1.1% | +0.7% | +3.4% | +1.6% | +1.0% | +1.1% | +0.7% | +0.7% |

11/12 组 ≤1.6%（g7 为 +3.4%）。而**档间差距 8%-25% ⇒ 12/12 判档正确**。
成本：命中率 55% ⇒ 期望 1.8 次挂载即合格，每次约 2 分钟，可忽略。

**R3 采集内容**（`mount-gear-attrib-test.sh r3 5`，约 1.5h）：5 个高档合格实例，每个跑
`探针 → randrw ×2（同实例内，验 L2）→ 收尾探针（验档位在实例生命周期内是否漂移）`。三个判定出口：

- L3 ≤5% ⇒ **基线签收**，汇报 randrw 高档值，立即开调优
- L3 在 5-10% ⇒ 按放宽门限签收，调优**必须**用同实例 A-B-A
- L3 >10% ⇒ 探针甄别不足，改用**探针归一化比值法**（§14.6 方法 2）

### 14.6 ⚑ 基线汇报值与"波动下如何看调优效果"（2026-08-05 定，两天时限内的收敛口径）

**基线汇报值**（R3 不达标时的兜底，现有数据已足够）：

> ⚑ **已被 §15.6 取代（2026-08-05 R3 后）**：签收值改为 **randread 1880 MiB/s**（R2+R3 高档 n=11，档内 2.9%），
> 高档命中率改为 **49%**（R1+R2+R3 合并 17/35）。下面的 1870/55% 为 R3 前的兜底口径，保留备查。

> randread ~~**1870 MiB/s**（高档带，n=12 次独立挂载，档内 ±1.1%）~~ 见 §15.6。
> 平台特性说明：JuiceFS 挂载实例存在 **4 个离散性能档位**，档位在实例生命周期内恒定（同实例两轮 ≤1.1%），
> 每次 remount 重新随机落档，高档命中率 ~~55%~~ **49%**，最坏档为高档的 −30%。机制未定（已排除 fio 进程、
> 集群侧配置/OSD 重启、主机负载、RSS/IRQ 饥饿、线程落核 NUMA）。

这个写法比报单一均值更诚实：**把波动作为已知平台特性披露，而不是当作测量误差**。

**调优效果的判定方法**（按旋钮是否需要 remount 分层，优先级从上到下）：

| # | 方法 | 适用旋钮 | 做法 | 可检出增幅 |
|---|---|---|---|---|
| 1 | **同实例内 A-B-A 配对** | `ceph config set` 类在线旋钮 | 同一挂载实例内切换配置，档位噪声完全消掉；**要求 A1 vs A2 回归 ≤2% 才认 B 的结果** | **≥3%** |
| 2 | **探针归一化比值** | 必须 remount 才生效（`--buffer-size` / `--max-uploads` / `--cache-size`） | 每轮前后各跑 75s 探针，汇报 `test/probe` 比值而非绝对值 | ≥5% |
| 3 | 配对随机化 + 多重复 | 方法 1、2 均不适用时 | A/B 交替各 5-6 次挂载，比 median | ≥10%，成本高 |

⚑ **§12.10 前提再追加一条**：跨挂载实例的绝对值对比一律无效，除非两个实例都经探针判定为**同档**。

⚑ **2026-08-05 R3 后再追加一条（§十六）**：**randrw/randwrite 的任何绝对值对比还必须同"写历史"**（自上次 `gc --compact` 起的累计写入量）—— 否则先跑的必然更快（r=−0.95）。方法 1 的 A-B-A 在有单调漂移时应升级为 **ABBA**（A→B→B→A）或 A-B-A 且要求首末 A 回归 ≤2%。

### 14.7 原始数据

```
WSL: /tmp/r2-mount-gear-attrib/    12 组完整
├── g1~g12/                         每组含 placement.txt、irq-affinity.txt、sampling.txt、sampling-ss.txt
├── g1-r1~g12-r1/                   每轮含 fio.txt、128 个 *_bw.*.log、irq-affinity-trace.txt
├── irq-affinity.txt                 全局 IRQ 亲和性快照（119 队列）
├── pg-state.txt
└── r2.log                           脚本运行日志

WSL: /tmp/r2-run.log                完整 stdout+stderr
157: /tmp/r2-mount-gear-attrib/     原始数据仍在 157 上
157: /tmp/r2-attic-20260805-groupsbug/  旧版（GROUPS bug）数据留档

脚本：scripts/FULLBASELINE/debug/mount-gear-attrib-test.sh（md5 81fd3edb7ebe8145595ff7640fd65151，843 行，含 precheck / r3 两模式）
备用分析器：scripts/FULLBASELINE/debug/r2-analyze.py（md5 f94dfa38a3208b2f21adf4c0e8e9a393）
函数顺序检查器：scripts/FULLBASELINE/debug/fnorder_check.py（md5 fa11986e090574f1463a8170fcfe1ff6）
⚑ g1 复核命令（按前缀取文件，勿用 *_bw.*.log 通配）：
   python3 scripts/FULLBASELINE/debug/r2-analyze.py /tmp/r2-mount-gear-attrib
```

---

## 十五、R3 档位甄别实验（2026-08-05）

### 15.1 背景

§14.4 R2 发现 4 档结构，高档带命中率 55%。R3 验证"探针甄别"协议：remount → 75s 探针判档 → 落在 [1830,1930] 才留用 → 合格实例内跑 randrw ×2 → 收尾探针验漂移。目标：5 个高档实例，验证 L3 ≤5%。

### 15.2 执行

- 脚本：`debug/mount-gear-attrib-test.sh`（md5 `81fd3edb7ebe8145595ff7640fd65151`）
- 先过 `fnorder_check.py`（✅）+ `precheck`（PRECHECK=OK ✅）
- 命令：`bash /tmp/mount-gear-attrib-test.sh r3 5`
- 起止（157 本地时间）：15:19:25 → 16:22:20
- 全程只读（探针用 randread，正式轮用 randrw 读写 rw_test.*.0）：不改 ceph 配置/IRQ/RPS、不重启服务
- PG 状态：全程 pool=3 pg_num=32 nonclean=0
- ceph health 全程 HEALTH_OK

### 15.3 结果

**r3-attempts.tsv 全文：**

```
attempt  probe1  gear     qualified  qid  rw_values       probe2
a1       1451    non-top  no         -    -               -
a2       1727    non-top  no         -    -               -
a3       1878    top      yes        q1   2507;2533;      1891
a4       1901    top      yes        q2   2337;2175;      1897
a5       1331    non-top  no         -    -               -
a6       1425    non-top  no         -    -               -
a7       1904    top      yes        q3   1851;1624;      1872
a8       1744    non-top  no         -    -               -
a9       1780    non-top  no         -    -               -
a10      1750    non-top  no         -    -               -
a11      1750    non-top  no         -    -               -
a12      1878    top      yes        q4   1281;1200;      1812
a13      1857    top      yes        q5   1502;1299;      1808
```

**命中率：** 高档 5 / 总挂载 13 = 38%（R1+R2 先验 55%）

**档位漂移（同实例开局探针 vs 收尾探针，间隔约 7min）：**

| 实例 | 开局 | 收尾 | 漂移 |
|---|---|---|---|
| q1 | 1878 | 1891 | +0.7% |
| q2 | 1901 | 1897 | -0.2% |
| q3 | 1904 | 1872 | -1.7% |
| q4 | 1878 | 1812 | -3.5% |
| q5 | 1857 | 1808 | -2.6% |

~~最大漂移 3.5% ⇒ 🔴 档位在实例内会漂移，探针甄别不成立~~

> ⚑ **订正（Opus 2026-08-05，从原始 bw log 复核）**：**该结论错误**。q4/q5 的收尾探针低（1778/1808），但**同期新挂载实例的开局探针也同步下滑**（a13-probe1=1858，而前半程 a4/a7=1903）⇒ 不是"实例内漂移"，而是**全场随时间/累计写入的整体退化**（见 §十六）。
> 扣掉全局退化后，同实例内探针复现性：q1 +0.7%、q2 −0.2%、q3 −1.7%（前半程无退化时段）⇒ **档位在实例内稳定，探针甄别成立**。

**randrw 结果（逐秒均值 读+写，15-175s）：**

| 实例 | rw1 | rw2 | 轮间极差 | L2 判定 |
|---|---|---|---|---|
| q1 | 2507 | 2533 | 1.0% | ✅ OK |
| q2 | 2337 | 2175 | 7.2% | 🔴 FAIL |
| q3 | 1851 | 1624 | 13.1% | 🔴 FAIL |
| q4 | 1281 | 1200 | 6.5% | 🔴 FAIL |
| q5 | 1502 | 1299 | 14.5% | 🔴 FAIL |

**L3 统计（跨高档实例）：**

```
L3（跨高档实例）: n=5 median=1738 range=1240-2520 极差幅度=73.6% 最大偏差=45.0%
判定: 🔴 L3 >10%（45.0%）⇒ 探针甄别不足以稳定 randrw，改用探针归一化比值法
```

> ⚑ **订正（Opus 2026-08-05）**：L3=45% **不能归因于实例差异**。这 5 个实例是按时间先后测的，randrw 值与**测试顺序/累计写入**的相关性 **r = −0.95**（§16.2）⇒ 该 45% 主要是**写历史效应**，不是"探针甄别不足"。原始数字本身无误（复核偏差 ≤0.6%）。

### 15.4 结论

1. ~~**探针甄别不成立**：档位在实例生命周期内会漂移（最大 3.5%），开局探针判档不能保证全程不跨档~~
   ⚑ **订正：探针甄别成立**。所谓 3.5% 漂移与同期新实例探针同步下滑 ⇒ 是全局退化，不是实例内漂移。**randread 的 4 档结构在 R3 完整复现且跨实验对齐**（§15.6）。
2. **randrw 轮间极不稳定**：5 个高档实例中 4/5 的 L2 FAIL（6.5-14.5%）—— 数字成立，但原因是写历史（同实例内 rw2 总低于 rw1）
3. ~~**L3 远超判据**：median=1738，极差 73.6%，最大偏差 45.0% ⇒ L3 >10%~~
   ⚑ **订正**：该极差由测试顺序驱动（r=−0.95），**不是实例间差异**
4. **判定出口**：⚑ 改为 → **randread 基线直接签收（§15.6）；randrw 先做 R4 判定写历史效应是否可逆（§十六）**

### 15.6 ⚑ randread 基线签收（Opus 2026-08-05，R2+R3 跨实验复核）

R3 的 18 个探针轮（randread，各 75s，判档窗 15-60s）复核值：

| 档 | R2（8-05 上午，175s 口径） | R3（8-05 下午，75s 探针） | 档内极差 |
|---|---|---|---|
| 高 | 1850 1863 1880 1882 1886 1888 | 1880(a3) 1903(a4) 1903(a7) 1881(a12) 1858(a13) | **2.4%** |
| 中 | 1719 1732 1738 | 1726(a2) 1744(a8) 1772(a9) 1748(a10) 1752(a11) | 3.1% |
| 低 | 1401 1403 | 1423(a1) 1448(a6) | 3.3% |
| 最低 | 1310 | 1331(a5) | — |

**⇒ 4 档结构跨两次独立实验、跨半天完整复现（各档对齐，偏差 ≤1.7%）**，命中率合并 **17/35 = 49%**。

**签收值：randread = 1880 MiB/s（探针门控高档带）**

> ⚑ **2026-08-06 追加 R5 四探针**（1900/1932/1894/1907，Opus 重算，极差 2.0%）⇒ **合并 n=19（R2+R3 高档 11 + R4 四点 + R5 四点），
> 区间 1850-1932、极差 4.4% ≤5% ⇒ 签收值 1880 不变**。R5 再证 randread 与写历史解耦（跨 1222 GiB 写入、两次 compact）。详见 §18.6.5。
- 样本：R2+R3 高档 n=11（1850-1903），档内极差 2.9%，**满足 L3 ≤5%**
- ⚑ 2026-08-06 追加 R4 四点探针复核（Opus 从 bw log 独立重算）：**1888 / 1915 / 1902 / 1926**，极差 2.0%，
  与高档带一致（R4 落在带内偏上，因当晚外部租户负载轻）。合并 **n=15（1850-1926），极差 4.1%，仍满足 L3 ≤5%**。
  **签收值不变（1880，取 R2+R3 保守中位）**；R4 探针另证：randread 在 5 轮 randrw（累计写 846 GiB、
  objects 2.36M→4.39M）与一次 `gc --compact` 前后**不受影响**（极差 2.0%），即 randread 基线与写历史解耦。
- 前提：**必须 75s 探针门控**（判档窗 15-60s，判档准确率 R2 复核 12/12）；未门控时期望值 ≈1700、最坏 −30%
- 披露口径：4 个离散档位 / 档位锁定挂载实例 / remount 重抽 / 高档命中 49% / 机制未定（IRQ-RSS 假设已否证）

### 15.5 原始数据

```
WSL: /tmp/r3-mount-gear-attrib/    13 次挂载尝试 + 5 个合格实例
├── a1~a13/                        每次尝试含 placement.txt
├── a1-probe1~a13-probe1/         探针轮含 fio.txt、128 个 *_bw.*.log、sampling.txt、sampling-ss.txt
├── q1~q5/                         合格实例含 placement.txt
├── q1-rw1~q5-rw2/                正式轮含 fio.txt、128 个 *_bw.*.log
├── q1-probe2~q5-probe2/           收尾探针轮
├── r3-attempts.tsv                全量尝试表（attempt / probe1 / gear / qualified / qid / rw_values / probe2）
├── r3.log                         脚本运行日志
└── pg-state.txt                   PG 状态快照

WSL: /tmp/r3-run.log              完整 stdout+stderr
157: /tmp/r3-mount-gear-attrib/   原始数据仍在 157 上

脚本：scripts/FULLBASELINE/debug/mount-gear-attrib-test.sh（md5 81fd3edb7ebe8145595ff7640fd65151）
```


### 15.7 ⚑ GLM 计算复核（Opus 2026-08-05；R4 轮的复核见 §17.6，同样无计算错误）

本次 **GLM 的数字全部正确**（前 7 次错误的记录见 §14.4）。从 157 原始 bw log 独立重算（按目录名前缀取文件）：

| 轮 | 复核真值 | GLM 报告 | 偏差 |
|---|---|---|---|
| q1-rw1 / rw2 | 2506 / 2529 | 2507 / 2533 | +0.0% / +0.2% |
| q2-rw1 / rw2 | 2342 / 2185 | 2337 / 2175 | −0.2% / −0.5% |
| q3-rw1 / rw2 | 1862 / 1629 | 1851 / 1624 | −0.6% / −0.3% |
| q4-rw1 / rw2 | 1287 / 1202 | 1281 / 1200 | −0.5% / −0.1% |
| q5-rw1 / rw2 | 1508 / 1299 | 1502 / 1299 | −0.4% / −0.0% |

bw log 无污染（每目录 128 个、前缀唯一）。唯一需注记：**q3-rw2 的 fio 全程汇总 1557 vs 逐秒均值(15-175s) 1629 差 +4.6%**（超过 §14.7 定的 3% 告警线），原因是该轮前 15s 爬坡特别低而非数据污染（其余 9 轮偏差 ≤2.5%）。

---

## 十六、⚑ 写历史效应：randrw 塌陷的真凶（2026-08-05 从 R3 原始数据发现，2026-08-06 由 R5 确证）

> ⚑ **订正轨迹（两次，均已收敛）**：
> 1. **2026-08-06（R4 后）曾降级**：R4 在单实例跑 5 轮、累计写 846 GiB、objects 2.36M→4.39M，塌陷**没有复现**（极差 2.4%），
>    故一度降级为"待 R5 判定的候选机制"。事后判明原因是 **R4 的 objects 上界 4.39M 刚好卡在拐点上，没走过去**。
> 2. **2026-08-06（R5 后）恢复并修正机制表述**：R5 把 objects 推到 4.98M，塌陷 −21.2% 复现，`gc --compact` 后**恢复率 105%**（✅ 出口1）。
>    ⇒ 本节结论**成立且效应可逆**，但**控制变量须从"累计写入量"改为"当前池未回收对象数"**：
>    R5 的同 objects 重复点显示，累计写入相差 1010 GiB、时间相差 30min，只要 objects 相同 randrw 就复现在 1.1% 内
>    （r(objects)=−0.807 vs r(累计写)=−0.159 vs r(时间)=−0.136，见 §18.6.1）。
>    §16.2 那条 r(累计写入)=−0.951 与 r(时间)=−0.952 的共线困局，**已被 R5 的 compact 复位段打破**。
>
> **引用本节时须连读 §18.6.1（机制修正）与 §18.6.4（randrw 签收口径）。**

### 16.1 现象

R3 的 10 个 randrw 轮按**时间顺序**排列后：

| 轮 | t（自 15:19 起，min） | randrw 逐秒均值 | 该轮前累计已写 | 同期 randread 探针 |
|---|---|---|---|---|
| q1-rw1 | 8 | **2506** | 0 GiB | a3 1880 |
| q1-rw2 | 11 | 2529 | 221 GiB | q1-probe2 1892 |
| q2-rw1 | 17 | 2342 | 444 GiB | a4 1903 |
| q2-rw2 | 21 | 2185 | 648 GiB | q2-probe2 1897 |
| q3-rw1 | 30 | 1862 | 838 GiB | a7 1903 |
| q3-rw2 | 33 | 1629 | 1003 GiB | q3-probe2 1876 |
| q4-rw1 | 46 | 1287 | 1140 GiB | a12 1881 |
| q4-rw2 | 49 | 1202 | 1252 GiB | q4-probe2 1778 |
| q5-rw1 | 55 | 1508 | 1358 GiB | a13 1858 |
| q5-rw2 | 58 | **1299** | 1489 GiB | q5-probe2 1808 |

- **r(randrw, 累计写入) = −0.951**；**r(randrw, 时间) = −0.952**（两者高度共线，无法在本数据内分离）
- 一小时内 randrw **−48%**，同期高档 randread 只 **−7%**（r = −0.73）
- **a8-a11 这 15 分钟纯读窗口（无写入）之后 randrw 未回升**（q3-rw2 1629 → q4-rw1 1287）⇒ 不是瞬时队列/缓存效应
- 每个实例内 **rw2 恒低于 rw1**（−7%/−17%/−6%/−14%，仅 q1 +0.9%）⇒ 单轮 221 GiB 写入就足以自伤

### 16.2 池侧观测（2026-08-05 18:0x 只读采集）

```
juicefs-data (pool 3, EC 4+2, pg_num=32, ec_overwrites, fast_read=1)
STORED 1.5 TiB   OBJECTS 6.30M   USED 2.3 TiB   %USED 5.66   MAX AVAIL 25 TiB
RAW: 42 TiB 总 / 40 TiB 可用 / 5.90% 已用      HEALTH_OK
```

- **不是容量问题**（仅用 5.66%）
- **平均对象 250 KiB**，而 JuiceFS 块应为 4 MiB ⇒ **差 16 倍**
- **~197k objects / PG**（6.30M ÷ 32）—— pg_num=32 是 PG 实验时定的，放大了每 PG 的元数据压力

**候选机制**：256k 随机写在 JuiceFS 侧产生大量小切片/小对象 → OSD 侧 onode/RocksDB(omap) 负担随累计写入单调上升 → 写路径塌陷，读路径被间接拖累 7%。

> ⚑ **2026-08-06 机制修正（R5 §18.6.1/§18.6.6）**：前半段证实 —— 每 292 KiB 随机写产生 **1 个新对象**（≈块大小 256k，JuiceFS 完全不合并），
> 空间放大 1.84-1.88×、其中 46-56% 是垃圾。但负担的自变量**不是"累计写入"而是"当前存活对象数"**：`gc --compact` 把对象数复位后性能 100% 回来。
> 至于 OSD 侧究竟是 onode 还是 RocksDB omap，R5 未区分（出口1 下无需区分即可拿到可签收基线）；
> 读路径被拖累 7% 一说**已被 R4/R5 否证**（randread 跨两次 compact、objects 2.36M↔5.39M 极差仅 2.0%，见 §18.6.5）。

### 16.3 ⚑ 连带影响：历史 randrw/randwrite 跨轮次对比全部作废

> ⚑ 2026-08-06（R4 后）：本节的**作废结论不变**，但**作废理由改写** —— 不再是"已确证的写历史效应"，
> 而是"**这些历史轮次的池 objects 完全未记录，且先跑的必然更快（r(时间)=−0.952）**"，即缺乏可比性本身就足以作废。
> 无论 R5 走哪个出口，这批数据都不会复活（新口径要求每轮记 objects + 每块前 compact，历史数据两者皆无）。

任何"先跑 A 后跑 B"的 randrw/randwrite 对比都被写历史混淆 —— **先跑的必然更快，与配置无关**。据此作废：

| 作废项 | 原结论 | 现状 |
|---|---|---|
| E6 → E6C randrw −14% | 曾疑 config 变更 | **不追**（§12.7 已记"不追"，现在有机制解释） |
| S1/S2/S3/S4 之间的 randrw/randwrite 横比 | 用于判 pool/pg 影响 | **不得再用于论证任何配置效应** |
| "randwrite 180s 内未进稳态" | 疑 runtime 不够 | 更可能是写历史 + 碎片；口径待 R4 后重定 |

randread 不受影响（read_test.*.0 从不被写）⇒ §15.6 的签收值不受此发现影响。

### 16.4 R4 实验协议（~~脚本已就绪，待执行~~ ⚑ 2026-08-05 已执行，结果见 §十七；判定 = 不可判，继任协议见 §17.7 R5）

**唯一问题：这个塌陷能否被 `juicefs gc --compact` 复位？**

单挂载实例内（探针门控拿高档，4 次抽不到则降级继续 —— R4 是同实例内对比）：

```
prep（含一次 gc --compact）
  → 探针 randread 75s 判档（[1830,1930]）
阶段 A：randrw 180s ×3（每轮前后记 ceph df objects）→ 探针
复位  ：juicefs gc --compact（计时 + 记 objects 变化）
阶段 B：探针 → randrw 180s ×2 → 探针
```

**判据（脚本自动给出三出口）**：恢复率 = (B首轮 − A末轮) / (A首轮 − A末轮)

| 出口 | 条件 | 结论与后续口径 |
|---|---|---|
| ✅ 可逆 | ≥80% | 塌陷源于可回收的写历史 ⇒ **randrw 基线口径 = "gc --compact 复位后第 1 轮"**，调优每轮前必须复位 ⇒ randrw 可签收 |
| 🟡 部分可逆 | 30-80% | 基线取"复位后第 1 轮"且必须同实例 ABBA 配对；跨天绝对值不可比 |
| 🔴 不可逆 | <30% | randrw 绝对值永不签收；只能同实例 ABBA 配对 + 线性去趋势；下一步查 bluestore onode/omap 与 pg_num=32 |

保护：若阶段 A 塌陷 <3%（现象未复现），脚本打印"不可判"，不给恢复率结论。

- 脚本：`debug/mount-gear-attrib-test.sh r4`（1063 行，md5 `00665abed24c1068db507e5bc57d3150`）
- 耗时 ≈ prep 10.5min + 门控 ≤4×2min + (3+2)×3.3min + 4 探针 ×1.5min + compact ≈ **70-80 min**
- 写操作：randrw 写 `rw_test.*.0` + **`juicefs gc --compact` ×2**（已获授权）；不改 ceph 配置/IRQ/RPS/pg_num
- 结果目录 `/tmp/r4-write-history`（`r4-rounds.tsv` / `r4-carrier.txt` / `gc-compact.txt` / `r4.log`）
- 桩测试（`/tmp/opencode/r2harness`，加入写历史塌陷模型）：三出口全部命中 —— 可逆 96% ✅、不可逆 −37% 🔴、"塌陷 <3% ⇒ 不可判"保护也触发过；R3/precheck 无回归，结果目录隔离（`results4/`）

### 16.5 ⚑ 后续脚本化计划（用户 2026-08-05 定，R4/randrw 收口后再做）

| 顺序 | 动作 | 说明 |
|---|---|---|
| 1 | ~~完成 R4 + randrw 口径收口~~ | ⚑ R4 已跑，判定"不可判"（§十七）⇒ 拆成 1a/1b |
| 1a | **R5 拐点定位（当前项，≈50-60min）** | 阶段A 最多 8 轮压到 objects>6.5M + 三重早停；四出口见 §17.7；跑完即定 randrw 口径 |
| 1b | 按 R5 出口签收 randrw 并写入 §12 判据 | 出口1/4 ⇒ 可签收 ≈2420；出口2/3 ⇒ 只做 ABBA 相对量 |
| 2 | 新建 `RANDREADBASELINE.sh` | 专测 randread，**内建探针甄别**（75s 判档 → 只在高档实例上出数），产出可签收的 randread 基线 |
| 3 | `FULLBASELINE_V4.sh` 加探针甄别后跑一次全量 | 全部 item 都在"探针判为高档"的实例上测，消除档位混淆 |
| 4 | 对仍有大波动的单项再拆专用脚本 | 参照 RANDREADBASELINE.sh 的模式，一项一脚本（如 randwrite） |

---

## 十七、R4 写历史可逆性实验（2026-08-05）

### 17.1 背景

§16 发现 randrw 塌陷与累计写入高度相关（r=−0.951），一小时内 −48%。R4 回答唯一问题：这个塌陷能否被 `juicefs gc --compact` 复位？

协议：单实例内 prep（gc --compact）→ 探针门控 → 阶段 A randrw ×3 → 探针 → gc --compact → 阶段 B 探针 → randrw ×2 → 探针。恢复率 = (B首轮 − A末轮) / (A首轮 − A末轮)。

### 17.2 执行

- 脚本：`debug/mount-gear-attrib-test.sh`（md5 `00665abed24c1068db507e5bc57d3150`）
- `fnorder_check.py` ✅ + `PRECHECK=OK` ✅
- 命令：`bash /tmp/mount-gear-attrib-test.sh r4`
- 起止（157 本地时间）：18:02:57 → 18:46:42（~44min）
- ceph health 全程 HEALTH_OK，无变化
- PG 全程 pool=3 pg_num=32 nonclean=0

### 17.3 结果

**轮次表（randrw 逐秒均值 + 该轮前累计写入 + 池对象数）：**

| 轮 | randrw | 该轮前累计写 GiB | 池 objects | 时刻 |
|---|---|---|---|---|
| A-rw1 | 2382 | 0 | 3117011 | 18:22:11 |
| A-rw2 | 2440 | 209 | 3789399 | 18:25:31 |
| A-rw3 | 2399 | 423 | 4387631 | 18:28:50 |
| B-rw1 | 2395 | 634 | 3126717 | 18:41:56 |
| B-rw2 | 2463 | 846 | 3795999 | 18:45:16 |

**探针表（randread，看读路径是否同步退化）：**

| 探针 | 值 | objects | stored_gib | used_gib |
|---|---|---|---|---|
| a1-probe1 | 1888 | 2359506 | 576.2 | 864.3 |
| A-probe2 | 1915 | 4337016 | 1059.0 | 1588.5 |
| B-probe1 | 1898 | 2359506 | 576.2 | 864.3 |
| B-probe2 | 1919 | 3728438 | 910.4 | 1365.6 |

**gc --compact：**

```
耗时=412s  before[objects=4337016 stored_gib=1059.0 used_gib=1588.5] after[objects=2359506 stored_gib=576.2 used_gib=864.3] rc=0
池对象数 4337016 → 2359506（-45.6%）
```

**判定行：**

```
阶段A 塌陷: 首轮 2382 → 末轮 2399（+0.7%）
阶段B 首轮（compact 复位后）: 2395
恢复率 = (B首轮 − A末轮) / (A首轮 − A末轮) = 24%
⚠️ 阶段A 塌陷仅 0.7%（<3%）⇒ 现象未复现，恢复率无意义；本次结论：不可判

randread 对照: a1-probe1=1888 A-probe2=1915 B-probe1=1898 B-probe2=1919 ⇒ 极差 1.6%
```

### 17.4 结论

1. **写历史塌陷未复现**：阶段 A 三轮 randrw（2382/2440/2399）极差仅 2.4%（+0.7%），远低于 §16 中 R3 的 −48%/小时
2. **恢复率无意义**：因阶段 A 塌陷 <3%，脚本保护触发"不可判"
3. **randread 极稳定**：4 次探针极差 1.6%（1888-1919），与 R2/R3 高档带一致
4. **gc --compact 有效**：objects 从 4.34M 降至 2.36M（−45.6%），stored_gib 从 1059 降至 576

### 17.6 ⚑ Opus 独立复核与再判定（2026-08-06，从 157 原始 bw log 重算）

**复核方法**：`/tmp/r4-write-history/<label>/*_bw.*.log` 共 9 轮 × 128 文件，按 `time_ms//1000` 聚合逐秒总带宽
（randrw 取读+写两方向之和），窗口 randrw 15-175s / 探针 15-60s，与 GLM 同口径。

| 轮 | Opus 复核 | GLM 上报 | 偏差 | 轮内趋势 q1→q4 | fio 汇总(READ+WRITE) |
|---|---|---|---|---|---|
| A-rw1 | 2381 | 2382 | −0.04% | **+2.8%** | 1191+1190 |
| A-rw2 | 2440 | 2440 | 0 | **+7.7%** | 1218+1218 |
| A-rw3 | 2398 | 2399 | −0.04% | **+2.3%** | 1200+1199 |
| B-rw1 | 2395 | 2395 | 0 | **+2.3%** | 1203+1202 |
| B-rw2 | 2461 | 2463 | −0.08% | **+5.5%** | 1233+1233 |
| a1-probe1 | 1888 | 1888 | 0 | −2.9% | 1872 |
| A-probe2 | 1915 | 1915 | 0 | −0.4% | 1887 |
| B-probe1 | 1902 | 1898 | +0.2% | −1.7% | 1882 |
| B-probe2 | 1926 | 1919 | +0.4% | +1.4% | 1883 |

**⇒ GLM 数字全部可信（偏差 ≤0.4%），R4 无计算错误**（连续第二次，§15.7 之后再未发现算错）。

**复核额外挖出三条 GLM 未报的事实：**

1. **轮内趋势全为正**（randrw 五轮 +2.3% ~ +7.7%，窗口内仍在爬升），而 §15.3 里 R3 的 randrw 轮内是**衰减**的
   ⇒ R4 全程处在"健康区"、R3 全程处在"已塌陷区"，两者不是同一工作点。
2. **`config-md5.txt` 与 R3 `q1-rw1` 逐位一致**（`ea35053a582b8e36d010da90307e8370`）⇒ fio 参数完全相同，
   **R3/R4 可直接横比**：R4 的 2382-2463 与 R3 首轮 2506 同量级，与 R3 末轮 1202 差 2 倍。
3. **碎片机制被定量锁死**：每轮写 211 GiB ⇒ objects **+757k**，即 **292 KiB/对象** ≈ fio 块大小 256k
   ⇒ **256k 随机写 = 1 个新对象，JuiceFS 完全不合并成 4 MiB 块**；`gc --compact` 把 objects 精确复位到
   **2359506（与 prep 后逐位相同）**、stored 1059→576 GiB ⇒ **复位是完全的，且 483 GiB（46%）是垃圾**。

**⚑ 再判定：R4 是"阴性但有信息"，不是白跑**

| 项 | 结论 | 依据 |
|---|---|---|
| randrw 低对象区稳定性 | **极差 2.4%（5 轮，跨 compact，累计写 846 GiB）⇒ 满足 L2 ≤5%，可支持 A-B-A（检出 ≥3%）** | 17.3 轮次表 |
| §16 写历史效应 | **既未证实也未否证**：R4 objects 最高 4.39M，R3 末态 6.30M ⇒ **拐点区间 4.4M-6.3M 完全没碰到** | 17.3 + §16.2 |
| gc --compact 恢复率 | 空（塌陷 <3%，判据保护正确触发） | 17.3 判定行 |
| randread | 再次确认，且与写历史解耦 | §15.6 追加段 |
| **空间放大（新，可直接进周报）** | 634 GiB 随机写 ⇒ stored 576→1059 GiB、used 864→1589 GiB，**放大 1.84×**，compact 耗时 **412s** 全部回收 | gc-compact.txt |

**风险**：不知道拐点在哪 ⇒ 调优阶段一旦连跑 >3 轮 randrw 就可能越过 4.4M，届时对比数据会像 E6/S1-S4 一样整批作废（§16.3）。
故 **randrw 不在此处签收**，先做 R5 定位拐点。

### 17.7 R5 拐点定位协议（2026-08-06 定，脚本已就绪待跑）

**唯一目标**：把 §16 的写历史效应从"不可判"推到可判 —— 要么找到拐点并测出恢复率，要么彻底否证。

| 项 | 设置 | 理由 |
|---|---|---|
| 阶段 A | randrw **最多 8 轮**（不中途 compact） | 2.36M + 8×757k ≈ 8.4M objects，越过 R3 末态 6.30M |
| 早停① 塌陷 | 相对首轮跌幅 ≥ **15%** 即进复位段 | 塌陷已充分，无需再堆 |
| 早停② 对象 | objects > **7.0M** 即进复位段 | 已越过 R3 末态，再堆只浪费 |
| 早停③ 容量 | used_gib > **6000** 立即停（precheck 预估并告警） | MAX AVAIL 25 TiB 留足余量；<2 轮会明确报"无法算恢复率" |
| 复位 | `juicefs gc --compact`（记耗时 + objects 前后） | R4 已证复位是精确的 |
| 阶段 B | randrw **2 轮** | 取恢复率 |
| 探针 | a*-probe1 / A-probe2 / B-probe1 / B-probe2 | randread 全局漂移对照 |
| 口径 | randrw 逐秒均值 15-175s（读+写）；探针 15-60s | 与 R2/R3/R4 一致 |

**四出口（脚本自动打印）：**

| 出口 | 条件 | randrw 基线口径 | 下一步 |
|---|---|---|---|
| ✅ 出口1 可逆 | 塌陷 ≥3% 且恢复率 ≥80% | **= "compact 复位后第 1 轮"，值 ≈2420，可签收** | 调优每轮前复位 + 按拐点表设 objects 上限 |
| 🟡 出口2 部分可逆 | 恢复率 30-80% | = 复位后第 1 轮，且必须同实例 ABBA 配对 | 跨天绝对值不可比 |
| 🔴 出口3 不可逆 | 恢复率 <30% | **绝对值永不签收**，只能 ABBA + 线性去趋势 | 转查 bluestore onode/omap 与 pg_num=32 |
| 🔵 出口4 否证 | objects 推到 ≥6.3M 仍无塌陷（<3%） | = **单实例内多轮均值 ≈2420（R4 极差 2.4%）** | §16 写历史效应作废，R3 的 −48% 改归外部租户/时段；调优强制 ABBA + 随机轮序 |

**主产物 = 拐点表**（randrw × 轮前 objects × 累计写入，自动标出首个跌破 −5% 的轮次与拐点区间），
无论走哪个出口都直接给出"每次 compact 后最多能跑几轮 randrw"这个调优操作参数。

**预计耗时**：prep 10.5min + 探针门控 ~2min + 阶段A ≤8×3.4min + compact ~7min + 阶段B 2×3.4min + 探针 ~3min ≈ **50-60min**（早停更短）。

**脚本**：`debug/mount-gear-attrib-test.sh` 新增 `r5` 模式（1174 行，md5 `1c716c11bd6eed01e25f7d5078946d66`），
结果目录 `/tmp/r5-write-knee`；桩测试四出口全绿（见 17.8）。

### 17.8 R5 脚本桩测试（2026-08-06，`/tmp/opencode/r2harness`）

桩里给 fio 加了 `KNEE`（拐点，GiB 累计写）与 `FRAGX`（写入放大）两个旋钮，`ceph df` 的 objects/stored/used 随碎片增长：

| 场景 | 阶段A | 拐点表输出 | 恢复率 | 出口 |
|---|---|---|---|---|
| `KNEE=1000 R4SIM=rev` | 6 轮后早停（−20.2%） | 首个跌破 −5%：A-rw5，拐点区间 objects ∈ (4.44M, 5.78M] | 100% | ✅ 出口1 |
| `KNEE=1000 R4SIM=irrev` | 6 轮后早停（−20.7%） | 同上（4.43M, 5.78M] | −42% | 🔴 出口3 |
| `KNEE=99999`（永不塌陷） | 跑满 8 轮 | 全程未跌破 −5%，最高轮前 objects=5.78M | 无意义 | 🔵 出口4 否证 |
| `R5_MAX_USED_GIB=1200`（容量保护） | 1 轮即硬停 | — | — | 🔴 明确报"阶段A 只跑 1 轮，无法算恢复率" |

**回归**：`precheck` rc=0 且容量预估打印正常；`r4` 模式在同一桩模型下**精确复现真实 R4 的"不可判"**
（塌陷 +0.3%，最高 objects 4.42M）—— 反向印证"拐点在 4.4M 以上"这一假设自洽；`r3` 模式 rc=0 无回归（L3 0.5% ✅）。
`bash -n` + `fnorder_check.py`（27 函数 / 46 顶层调用）双通过。

### 17.9 原始数据

```
WSL: /tmp/r4-write-history/    R4 完整数据
├── r4-rounds.tsv              全量轮次表（phase / label / value / note / ts）
├── r4-carrier.txt             载体实例身份（gated=1 attempts=1 probe1=1888）
├── gc-compact.txt             gc --compact 日志
├── r4.log                     脚本运行日志
├── a1/ a1-probe1/             挂载尝试 + 探针
├── A-rw1~A-rw3/              阶段 A randrw 轮
├── A-probe2/                  阶段 A 收尾探针
├── B-probe1~B-probe2/         阶段 B 探针
├── B-rw1~B-rw2/              阶段 B randrw 轮
└── pg-state.txt               PG 状态快照

WSL: /tmp/r4-run.log          完整 stdout+stderr
157: /tmp/r4-write-history/   原始数据仍在 157 上

脚本：scripts/FULLBASELINE/debug/mount-gear-attrib-test.sh
      R4 执行时 md5 = 00665abed24c1068db507e5bc57d3150（1063 行）
      加 r5 模式后 md5 = 1c716c11bd6eed01e25f7d5078946d66（1174 行，r4 模式行为不变，已回归验证）

Opus 复核脚本（临时，只读）：/tmp/opencode/r4chk.py   逐秒均值 + 轮内 q1-q4 趋势重算
R5 待产出：157 及 WSL /tmp/r5-write-knee/（r4-rounds.tsv / r4-carrier.txt / gc-compact.txt / r5.log）
           日志关键行：拐点表 / 首个跌破 -5% / 拐点区间 / 阶段A 塌陷 / 恢复率 / 出口1-4
```

---

## 十八、R5 拐点定位实验（2026-08-05）

### 18.1 背景

§17 R4 在 objects 2.36M→4.39M 范围内未复现 randrw 塌陷（极差 2.4%），R3 末态 6.30M 时已跌至 1202。拐点区间 4.4M-6.3M。R5 把阶段 A 拉到最多 8 轮压过 6.5M objects，一次性收口 randrw。

### 18.2 执行

- 脚本：`debug/mount-gear-attrib-test.sh`（md5 `1c716c11bd6eed01e25f7d5078946d66`，1174 行）
- `fnorder_check.py` ✅ + `PRECHECK=OK` ✅
- 命令：`bash /tmp/mount-gear-attrib-test.sh r5`
- 起止（157 本地时间）：19:54:31 → 20:40:30（~46min）
- ceph health 全程 HEALTH_OK，无变化
- PG 全程 pool=3 pg_num=32 nonclean=0

### 18.3 结果

**轮次表（randrw 逐秒均值 + 该轮前累计写入 + 池对象数）：**

| 轮 | randrw | 该轮前累计写 GiB | 池 objects | 时刻 |
|---|---|---|---|---|
| A-rw1 | 2408 | 0 | 2359508 | 20:06:36 |
| A-rw2 | 2477 | 212 | 3111151 | 20:09:55 |
| A-rw3 | 2439 | 429 | 3781993 | 20:13:15 |
| A-rw4 | 2218 | 644 | 4404850 | 20:16:35 |
| A-rw5 | 1897 | 839 | 4977418 | 20:19:54 |
| B-rw1 | 2438 | 1008 | 2359508 | 20:35:45 |
| B-rw2 | 2491 | 1222 | 3102821 | 20:39:05 |

**拐点表（按轮前 objects 递增；基准 = 阶段A 首轮）：**

| 轮 | 轮前 objects | randrw | vs A 首轮 | 累计写 GiB |
|---|---|---|---|---|
| A-rw1 | 2359508 | 2408 | +0.0% | 0 |
| A-rw2 | 3111151 | 2477 | +2.9% | 212 |
| A-rw3 | 3781993 | 2439 | +1.3% | 429 |
| A-rw4 | 4404850 | 2218 | -7.9% | 644 |
| A-rw5 | 4977418 | 1897 | -21.2% | 839 |
| B-rw1 | 2359508 | 2438 | +1.2% | 1008 |
| B-rw2 | 3102821 | 2491 | +3.4% | 1222 |

⇒ 首个跌破 -5% 的轮次: A-rw4（轮前 objects=4404850, 2218 MiB/s）
⇒ 拐点区间: objects ∈ (3781993, 4404850]

**早停：** A-rw5 跌幅 -21% 已达 -15% 阈值 ⇒ 塌陷充分，提前进复位段（已跑 5 轮，burst_stop=drop-21）

**探针表（randread，看读路径是否同步退化）：**

| 探针 | 值 | objects | stored_gib | used_gib |
|---|---|---|---|---|
| a1-probe1 | 1900 | 2359508 | 576.2 | 864.2 |
| A-probe2 | 1925 | 5390600 | 1316.2 | 1974.3 |
| B-probe1 | 1888 | 2359508 | 576.2 | 864.2 |
| B-probe2 | 1902 | 3740761 | 913.4 | 1370.1 |

**gc --compact：**

```
耗时=576s  before[objects=5390600 stored_gib=1316.2 used_gib=1974.3] after[objects=2359508 stored_gib=576.2 used_gib=864.2] rc=0
池对象数 5390600 → 2359508（-56.2%）
```

**判定行：**

```
阶段A 塌陷: 首轮 2408 → 末轮 1897（-21.2%）
阶段B 首轮（compact 复位后）: 2438
恢复率 = (B首轮 − A末轮) / (A首轮 − A末轮) = 106%
✅ 出口1 可逆（恢复率 ≥80%）⇒ randrw 塌陷源于可回收的写历史（碎片/垃圾）
⇒ randrw 基线口径 = 'gc --compact 复位后第 1 轮'；调优每轮前必须复位；randrw 可签收
⇒ 并按上方拐点表设 objects 上限：每次 compact 后最多跑到拐点前一轮，超限即作废重测

randread 对照: a1-probe1=1900 A-probe2=1925 B-probe1=1888 B-probe2=1902 ⇒ 极差 2.0%
```

**跑完后 ceph df：**

```
juicefs-data  pool 3, 32 PGs, 913 GiB stored, 3.74M objects, 1.3 TiB used, 3.36% used
```

### 18.4 结论

1. **✅ 出口1 可逆**：恢复率 106%（≥80%），randrw 塌陷源于可回收的写历史（碎片/垃圾）
2. **拐点定位**：objects ∈ (3.78M, 4.40M]，首个跌破 -5% 在 A-rw4（轮前 objects=4.40M）
3. **randrw 基线口径 = gc --compact 复位后第 1 轮**：B-rw1=2438、B-rw2=2491
4. ~~**调优操作参数**：每次 compact 后最多跑到拐点前一轮（objects ≤3.78M），超限即作废重测~~
   ⚑ **2026-08-06 订正（见 §18.6.2）**：上限偏松。A-rw3（轮前 3.78M）的**轮内趋势已转负 −3.0%**，本身已在拐点上。
   改为 **轮前 objects ≤3.11M（compact 后最多 2 轮），判定只认第 1 轮**；并以"轮内 q1→q4 趋势跌破 −5%"作为越界的领先报警。
5. **randread 与写历史解耦**：探针极差 2.0%（1900-1925），§15.6 签收值 1880 不受影响
6. **gc --compact 耗时 576s**（5.39M→2.36M，-56.2%），调优预算需计入

### 18.5 原始数据

```
WSL: /tmp/r5-write-knee/    R5 完整数据
├── r4-rounds.tsv              全量轮次表（phase / label / value / note / ts）
├── r4-carrier.txt             载体实例身份（gated=1 attempts=1 probe1=1900 burst_stop=drop-21）
├── gc-compact.txt             gc --compact 日志
├── r5.log                     脚本运行日志
├── a1/ a1-probe1/             挂载尝试 + 探针
├── A-rw1~A-rw5/              阶段 A randrw 轮
├── A-probe2/                  阶段 A 收尾探针
├── B-probe1~B-probe2/         阶段 B 探针
├── B-rw1~B-rw2/              阶段 B randrw 轮
└── pg-state.txt               PG 状态快照

WSL: /tmp/r5-run.log          完整 stdout+stderr
157: /tmp/r5-write-knee/     原始数据仍在 157 上

脚本：scripts/FULLBASELINE/debug/mount-gear-attrib-test.sh（md5 1c716c11bd6eed01e25f7d5078946d66）
```

### 18.6 ⚑ Opus 独立复核与 randrw 基线签收（2026-08-06）

**复核方法**：从 157 原始 `*_bw.*.log`（每轮 128 个文件）逐秒重算，口径 = 逐秒总带宽在 15-175s（探针 15-60s）窗口的均值；脚本 `/tmp/opencode/r5chk.py`。

| 轮/探针 | GLM 上报 | Opus 重算 | 偏差 | 轮内 q1→q4 趋势 |
|---|---|---|---|---|
| A-rw1 | 2408 | 2408 | 0.0% | +1.2% |
| A-rw2 | 2477 | 2475 | 0.1% | +7.1% |
| A-rw3 | 2439 | 2440 | 0.0% | **−3.0%** |
| A-rw4 | 2218 | 2219 | 0.0% | **−8.3%** |
| A-rw5 | 1897 | 1895 | 0.1% | **−8.3%** |
| B-rw1 | 2438 | 2435 | 0.1% | +0.2% |
| B-rw2 | 2491 | 2490 | 0.0% | +3.2% |
| a1-probe1 | 1900 | 1900 | 0.0% | −0.2% |
| A-probe2 | 1925 | 1932 | 0.4% | −4.1% |
| B-probe1 | 1888 | 1894 | 0.3% | −3.9% |
| B-probe2 | 1902 | 1907 | 0.3% | −2.9% |

⇒ **偏差全部 ≤0.4%，GLM 连续第三轮（R3/R4/R5）无计算错误**；恢复率复算 = (2435−1895)/(2408−1895) = **105%**，✅ 出口1 成立。

#### 18.6.1 ★ 共线性被打破：控制变量是"当前池对象数"，不是时间、也不是累计写入

§16.2 的困局是 r(累计写入)=−0.951 与 r(时间)=−0.952 完全共线，无法分离。R5 的 compact 复位段把三者**强行解耦**（阶段 B 时间更晚、累计写入更多，但 objects 被复位），结果：

| 自变量 | r(randrw, x)，n=7 |
|---|---|
| **轮前池对象数** | **−0.807** |
| 累计写入 GiB | −0.159 |
| 时间序 | −0.136 |

**同 objects 重复点（决定性证据）：**

| objects | 阶段A | 阶段B | 差 | 累计写入差 |
|---|---|---|---|---|
| 2359508 | 2408 | 2435 | +1.1% | 0 → 1008 GiB |
| ≈3.11M | 2475 | 2490 | +0.6% | 212 → 1222 GiB |

⇒ 累计写入相差 1008-1010 GiB、时间相差 ~30min，但只要 objects 相同，randrw **复现在 1.1% 以内**。
**结论：randrw 的唯一控制变量是"跑该轮之前池里有多少对象（= 未回收垃圾量）"。** §16 的写历史效应**成立且可逆**，但机制表述须修正为"垃圾对象数"而非"累计写入量"；R3 的 −48% 是因为它连续 10 轮从不 compact，末态 6.30M。

#### 18.6.2 ★ 轮内趋势 = 拐点的领先指标（顺带修正安全上限）

A-rw3 的**均值**还在健康区（2440，+1.3%，落在健康 4 点带内），但它的**轮内趋势已经转负（−3.0%）**，而 A-rw1/A-rw2 是 +1.2%/+7.1%。A-rw3 跑的区间正是 objects 3.78M→4.40M ⇒ **塌陷在 A-rw3 的后半段就已经开始，只是被前半段的高值在均值里抹平了**。

⚑ 据此**订正 §18.4 第 4 条的安全上限**：GLM 给的"轮前 objects ≤3.78M（compact 后可跑 3 轮）"**偏松**（A-rw3 本身已在拐点上）。改为：

> **轮前 objects ≤3.11M，即 `gc --compact` 后最多跑 2 轮 randrw；判定只认第 1 轮，第 2 轮仅作轮内一致性校验。**
> 越界的数据一律作废重测。同时要求每轮打印 q1→q4 轮内趋势，**趋势跌破 −5% 即视为已越界**（比均值更早报警）。

#### 18.6.3 ★ gc --compact 成本是线性的（可用于排预算）

| 实验 | 回收对象数 | 耗时 | 单位成本 |
|---|---|---|---|
| R4 | 4.39M→2.36M = 2.03M | 412s | 203 μs/对象 |
| R5 | 5.39M→2.36M = 3.03M | 576s | 190 μs/对象 |

⇒ **compact_秒 ≈ 1.95e-4 × 回收对象数**（两点一致，误差 6%）。调优时若只跑 1 轮（增 757k 对象），compact ≈ **148s ≈ 2.5min**，而非 R5 的 576s ⇒ 单点成本可压到 ~6min。

#### 18.6.4 ⚑ randrw 基线签收

**口径（三条同时满足才算有效样本）**：① 挂载实例经 75s randread 探针门控落在 [1830,1930]；② 该轮之前刚做过 `gc --compact`（轮前 objects = 2.36M）；③ 逐秒均值取 15-175s。

**样本（R4 + R5 全部"复位后第 1 轮"）：**

| 实验 | 轮 | 值 |
|---|---|---|
| R4 | A-rw1 | 2381 |
| R4 | B-rw1 | 2395 |
| R5 | A-rw1 | 2408 |
| R5 | B-rw1 | 2435 |

**n=4，均值 2405，极差 2.3% ⇒ 满足 L2/L3 ≤5%。**

> ### ✅ **randrw 基线签收值 = 2400 MiB/s**（复位后第 1 轮，探针门控实例，n=4，极差 2.3%）
>
> 参考：健康区（轮前 objects ≤3.11M）4 点 = 2408/2475/2435/2490，均值 2452、极差 3.4%，同样达标，
> 但**签收口径统一采用更严的"复位后第 1 轮"**（精度 2.3% 优于 3.4%，且定义无歧义）。

**调优分辨力**：单点重复性 2.3% ⇒ 同实例 A-B-A（A1/B/A2，每点 compact + 1 轮）可检出 **≥3%** 的效应，单组耗时 ≈18min。

⇒ **randread 1880（§15.6）+ randrw 2400（本节）两项基线全部签收，基线阶段收口，转入调优。**

#### 18.6.5 randread 样本合并（n=19）

R5 四个探针 1900/1932/1894/1907（Opus 重算，极差 2.0%）并入 §15.6：**R2+R3 高档 n=11 + R4 四点 + R5 四点 = n=19，合并区间 1850-1932、极差 4.4%**，仍 ≤5% ⇒ **签收值 1880 不变**。R5 再次证明 randread 与写历史解耦（跨 1222 GiB 写入、objects 2.36M↔5.39M、两次 compact，读带宽极差 2.0%）。

#### 18.6.6 空间放大（供周报）

R5 阶段 A 写 1050 GiB 随机写 ⇒ stored 576→1316 GiB、used 864→1974 GiB，`gc --compact` 全部回收。合并 R4：

| 实验 | 随机写量 | stored 增 | used 增 | 放大 | compact 后 |
|---|---|---|---|---|---|
| R4 | 634 GiB | 576→1059 | 864→1589 | 1.84× | 精确复位 2359506 |
| R5 | 1050 GiB | 576→1316 | 864→1974 | 1.88× | 精确复位 2359508 |

⇒ **256k 随机写的空间放大稳定在 1.84-1.88×，其中约 46-56% 是可回收垃圾**；每 292 KiB 写入产生 1 个新对象（≈块大小 256k，JuiceFS 不做对象合并）。**运维含义：256k 随机写场景必须定期 `gc --compact`，否则每 ~5.4M 对象（≈1.5 TB 写入）性能掉 20%+。**

### 18.7 ⚑ §16 的最终裁定

§16 标题的"真凶"**予以恢复**（R4 阶段曾降级为"候选机制"）：R5 出口1 + §18.6.1 的同 objects 重复点已确证写历史效应真实存在且**完全可逆**，控制变量修正为**当前池未回收对象数**。§16.3 的"历史 randrw/randwrite 跨轮次对比全部作废"结论与理由**均维持**（历史轮次既无 objects 记录、也无每块前 compact）。§17.7 的出口4（否证）**未被触发**，作废。
