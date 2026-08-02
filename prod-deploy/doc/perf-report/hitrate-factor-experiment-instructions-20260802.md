# GLM 执行指令：BlueStore 缓存命中率因子分解与稳定化实验（HR 系列）

> 来源：analyst `/tmp/bridge/analysis.md` §-V3BASE / §-HITRATE。
> 前序结论：randread 波动源已收敛到 **BlueStore 数据 buffer 命中率**（02-2h §-STEP1 ρ=1.000 n=9；LC.12 D 组 ρ=1.0000）。V3 确定性预热已消除 r1 冷启动，但**跨轮一致性未验证**、**hit% 从未在 V3/补测中采集**。
> 本实验目标：①解开"12% 缓存覆盖率产出 75% 命中率"的算术悖论；②把决定 hit% 的因子逐个分解；③找出让 hit% 稳定的可控手段，产出可发布的基线口径。

---

## 零、授权与红线

- **授权**：环境/脚本 bug 可自主修但**须报告**；**禁止擅改控制变量**。本指令中标 ⚠️ 的步骤（E1.5/E6/E7 涉及 `ceph config set`）**必须先报告 analyst 并等批准**。
- **红线（违反即数据全废）**：
  1. ⛔ 禁止 `juicefs format` / `destroy` / `rm -rf` 测试数据 / pool 删建 / OSD purge·zap·create —— **当前 layout 必须全程锁定**（UUID + CRUSH md5 不变）。
  2. ⛔ 禁止 OSD restart（**唯一例外**：E4 最后一步，且须先报告）。
  3. **runtime = 180s 不得改小**；所有 fio 必须带 `--write_bw_log` + `--log_avg_msec=1000`，并保留全部 job 的 bw log（analyst 一律用**稳态中位数**评估，不看 fio 聚合均值）。
  4. 禁改 fio 的 `bs / iodepth / direct / rw`；只允许按本文矩阵改 `numjobs` 与 `filename 列表`。
  5. 累积计数器（buffer_hit/miss、onode_hits/misses、NIC、`.stats`）**必须窗口首末差分**，禁止报绝对值。
- 遇到前置验证失败、需改控制变量、或发现指纹变化 —— **停下报告 analyst**。

---

## 一、E0：仪表化 + 悖论判别（前置，必做）

### 1.1 背景（为什么必须先做这一步）
hit% 的定义是 `Δbuffer_hit_bytes/(Δhit+Δmiss)`。但工作集 128G、缓存仅 ~15GB（覆盖率 12%），均匀随机读的理论命中率应 ≈12%，实测却是 60~84%，**差 6 倍**。在解释清楚之前，任何调 `osd_memory_target`/cache 的动作都是盲调。

候选解释：①**客户端预取放大**（周报 20260725 §4.1 记载 256K 口径预读 2.02× 放大；ra0 使 randread +72%）；②EC fast_read 全 6 shard（1.5× 物理放大）；③计数器语义。

### 1.2 每轮 fio 的**窗口首末**采集（pre / post 各一次，6 个 OSD 全采）
```bash
# 在 150 上执行；OSD=0..5
for i in 0 1 2 3 4 5; do
  sudo ceph tell osd.$i perf dump        > ${OUT}/perf-osd$i-${PHASE}.json   # PHASE=pre|post
  sudo ceph tell osd.$i dump_mempools    > ${OUT}/mempool-osd$i-${PHASE}.json
done
sudo ceph osd dump | head -20            > ${OUT}/osddump-${PHASE}.txt        # 含 flags / up_from
```
```bash
# 在 157 上执行（客户端侧放大）
cat /mnt/jfs/.stats                      > ${OUT}/jfs-stats-${PHASE}.txt
```
**必须提取的字段**（`perf dump` 全 JSON 请原样保留，analyst 离线取值；下列为最少集）：

| 分类 | 字段 |
|---|---|
| 数据命中 | bluestore: `buffer_hit_bytes`、`buffer_miss_bytes`、`buffer_bytes` |
| 元数据命中 | bluestore: `onode_hits`、`onode_misses`、`onode_shard_hits`、`onode_shard_misses` |
| 缓存实际分区 | `dump_mempools` 的 `bluestore_cache_data` / `bluestore_cache_onode` / `bluestore_cache_other` 的 bytes；`perf dump` 中所有 `prioritycache*` 段（target/committed/cache/heap bytes） |
| kv / spillover | `rocksdb` 段的 get 相关延迟；`bluefs` 段的 `slow_used_bytes`、`db_used_bytes` |
| 读路径 | bluestore 的读延迟类计数（`read_lat` / `read_wait_aio_lat` / `read_onode_meta_lat` 或本版本实际存在的同类字段） |

> ⚠️ **字段名不确定时不要猜**：`perf dump` 全文已保留，只需在报告里注明"本版本实际字段名为 X"，analyst 自行对齐。

### 1.3 判别计算（每轮一行）
```
R_backend = Σ_osd Δ(buffer_hit_bytes + buffer_miss_bytes) ÷ fio READ io 字节数
R_client  = Δ(.stats 中 object GET 字节)                  ÷ fio READ io 字节数
hit%      = Σ_osd Δbuffer_hit_bytes ÷ Σ_osd Δ(hit+miss)
```
| 观测 | 结论 |
|---|---|
| R_backend ≈ 1.5 且 R_client ≈ 1.0 | 只有 EC 放大 ⇒ 候选②/③，高 hit% 必来自跨轮残留，需另找解释 |
| R_client ≈ 2 且 R_backend ≈ 3 | **候选①成立：预取主导** ⇒ 直接进 E1，ra0 很可能同时是性能解和稳定解 |
| R_backend < 1.0 | 采集口径错（漏 OSD 或算错窗口），停下报告 |

### 1.4 E0 执行
用当前锁定 layout 跑 **randread 128job × 1 轮 180s**（参数同 V3 的 randrw-128 但 rw=randread），前后各采一次上述数据，出上面 3 个数。**报告后再进 E5/E1。**

---

## 二、E5：后台污染排除（10 分钟，必做）

```bash
sudo ceph osd dump | grep -E "^flags"                 # 看有无 noscrub / nodeep-scrub
sudo ceph config get osd osd_scrub_begin_hour; sudo ceph config get osd osd_scrub_end_hour
sudo grep -iE "scrub" /var/log/ceph/*/ceph-osd.*.log | tail -50   # 或 cephadm logs
```
- 若**未**设 noscrub：报告后置上 `sudo ceph osd set noscrub && sudo ceph osd set nodeep-scrub`（这是测试期标准做法，不算控制变量变更，但仍需在报告里记录时间点），并把 scrub 日志时间戳与历史坏轮时间对齐一次。
- 交付：flags 现状 + 是否有 scrub 落在历史坏轮窗口内。

---

## 三、E1★：readahead × 并发 2×2（最高优先，~4h）

### 3.1 矩阵（工作集固定 128G，每格 randread **5 轮**，每轮 180s）
| 格 | 挂载参数 | numjobs | fio 文件 |
|---|---|---|---|
| A | `--max-uploads 150 --cache-size 0`（default） | 128 | 每 job 一个 layout 文件 |
| B | `--max-uploads 150 --cache-size 0 --max-readahead 0` | 128 | 同上 |
| C | default | 1 | 128 文件列表 |
| D | `--max-readahead 0` | 1 | 同上 |

切换挂载参数只允许 `fusermount -u` + `juicefs mount -d`（复用 FULLBASELINE_V2.sh 的 `--remount` 路径），**禁止 format**。

### 3.2 fio 命令
```bash
# 128-job（沿用历史口径，job i 对应 storage_test.i.0）
fio --directory=${TEST_DIR} --name=storage_test --filesize=1G --size=1G \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 --group_reporting \
    --time_based --runtime=180 --write_bw_log=${BW}/randread-${CELL}-r${r} --log_avg_msec=1000

# 单进程 128G（★必须用 filename 列表读**已有**文件，禁止让 fio 新建文件）
FL=$(ls ${TEST_DIR}/storage_test.*.0 | sort | paste -sd:)
fio --name=storage_test --filename="${FL}" --file_service_type=random \
    --bs=256k --rw=randread --ioengine=libaio --iodepth=128 --numjobs=1 \
    --direct=1 --fallocate=none --group_reporting \
    --time_based --runtime=180 --write_bw_log=${BW}/randread-${CELL}-r${r} --log_avg_msec=1000
```
轮间：仅 `drop_caches`（3 节点）+ `compact_cooldown`；**不做 aggressive_cleanup**（纯读无写入，不需要）；**不重启 OSD**。
每格开始前做一次确定性预热（顺序读 128 个 layout 文件，同 V3 `deterministic_warmup`），并记录预热耗时。

### 3.3 预注册判读（先写下预期，事后不得改）
| 观测 | 结论 |
|---|---|
| B/D（ra0）R_client→1.0、hit%↓（趋近 12%）、**hit% 轮间极差↓**、BW↑ | 坐实"预取放大是 hit% 方差主源"⇒ **基线口径直接采 ra0**（性能与稳定双收，不动任何 Ceph 参数） |
| A（ra-default+128job）hit% 极差最大 | 与历史 60~84% 区间对齐，机制自洽 |
| C/D（单进程）hit% 高且极差≈0 但 BW 很低（~150 MiB/s） | 单进程稳定性来自小/顺序化访问，**不是**预热之功（对应 E2 验证） |
| ra0 后 hit% 降但 BW 方差**没降** | 预取假说不成立，回炉：优先查 B 层（autotune 分配漂移），报告 analyst |

### 3.4 交付
每格 5 轮的表：稳态中位数 / 范围 / 最大偏差 / CV / hit% 每轮值与极差 / R_client / R_backend；加 Spearman(hit%, 稳态BW)。

---

## 四、E1.5★★：干预式因果验证（⚠️ 需批准，~40min）

**目的**：把 ρ=1.0 的**相关**升级为**因果**——直接关掉数据 buffer，看方差是否随之消失。这是当前证据链最缺的一环。

```bash
# ⚠️ 报告并获批后执行；运行时配置，不重启 OSD，不动 CRUSH/UUID
sudo ceph config set osd bluestore_default_buffered_read false
sudo ceph config get osd bluestore_default_buffered_read     # 确认生效
# 跑 randread 128job × 5 轮（其余同 E1 A 格）
# 回滚：
sudo ceph config set osd bluestore_default_buffered_read true
```
- ⛔ **不要**用"把 `bluestore_cache_size` 调小"来代替：那会同时挤压 onode/kv 缓存，元数据 miss 全打 RocksDB（当前 DB 已 spillover），会**新增**波动源。只关数据 buffer，保 onode/kv。
- 必须同时报告 onode hit% 与 rocksdb get 延迟的轮间稳定性（验证没冒出新波动源）。
- 判读：hit%→≈0 且 BW 最大偏差 <2% ⇒ **hit% 是因**；若方差仍在 ⇒ 现有归因不完整，立即停下报告。
- 记录：把 `bluestore_default_buffered_read` 的值加入布局守卫快照（第 6 要素），防后续轮次口径串味。

---

## 五、E2：工作集阶梯（~2h）

单进程（numjobs=1，filename 列表），工作集 = 1G / 16G / 64G / 128G（分别取 layout 文件的前 1 / 16 / 64 / 128 个），每档 **4 轮**；另加 128job@128G 一档对照。
判读：最大偏差随 `工作集/缓存比` 单调上升；1G 档 hit% 是否饱和且极差≈0 ⇒ 坐实 V3 单进程 0.6% 来自小工作集，而非确定性预热。

---

## 六、E3：预热协议（2Q 准入，~1.5h）

BlueStore 默认 `bluestore_cache_type=2q`：顺序读一遍只把数据放进 probation（kin）队列，**两遍才升入 hot 队列**。
设计：预热 **0 遍 / 1 遍 / 2 遍** × 各 randread **3 轮**（128job）。判读：2 遍预热 → hit% 起点更高、轮间极差更小 ⇒ 把 V3 的"读一遍"升级为标准协议。

---

## 七、E4：写压力挤占 + 可逆性阶梯（~2h，解释 randrw-128 单调下降）

### 7.1 读写分解
- **randread-128 × 10 轮**（只读）vs **randrw-128 × 10 轮**（同 V3 参数）。全程每轮采 E0 全套（重点 `prioritycache` 的 data/kv 分配 + `bluefs slow_used_bytes`）。
- 判读：
  | 观测 | 结论 |
  |---|---|
  | randread-128 平稳、randrw-128 单调降 | 下降是**写**驱动（tombstone/碎片），"缓存被逐轮驱逐"说法作废 |
  | 两者都单调降 | 才是缓存驱逐 |
  | randrw 轮 kv_bytes↑ / data_bytes↓ 且 hit%↓ | **RocksDB 挤占**（可用 E6 的显式 pin 修） |

### 7.2 可逆性阶梯（在 randrw-128 十轮的衰减态上，顺序执行，逐步升级干预）
1. 直接再测 1 轮（预期 ~550 MiB/s，与 V2 四轮 544~568 对齐）。
2. `deterministic_warmup` 后测 1 轮 → **回到 ~1200 ⇒ 纯读缓存瞬态**（则 V3 附录 C.4-4 的"生产退化"结论必须改写）。
3. 若②未恢复：**⚠️ 先报告**，再 `ceph orch daemon restart osd.N`（全 6 个，逐个等 active+clean）后测 1 轮 → 恢复 ⇒ OSD 内存态；仍不恢复 ⇒ 落盘碎片/tombstone 累积。
4. ★ 步骤 3 会改变 `up_from`，**必须排在本 layout 所有实验的最后**，并记录新 epoch。

---

## 八、E6 / E7（⚠️ 需批准，仅在 E1/E1.5 未解决时才做）

- **E6 缓存确定化**：`bluestore_cache_autotune=false` + 显式 pin（`bluestore_cache_size_ssd` / `bluestore_cache_meta_ratio` / `bluestore_cache_kv_ratio`），对照现状各 5 轮，看 `prioritycache` 分配漂移与 hit% 极差是否收敛。
- **E7 EC fast_read 0/1**：仅当 E0 显示 EC 放大占主导时做；观察 R_backend 从 1.5 → 1.0 后 hit% 与方差变化。

---

## 九、验收判据（analyst 侧统一口径，先钉死防事后挑数）

1. 同轮内 5 次：**hit% 极差 ≤ 1pp** 且 稳态 BW 最大偏差 **<3%**；
2. 跨轮（背靠背两轮同协议）：hit% 中位数偏差 ≤ 1pp 且 BW 偏差 ≤ 5%；
3. **机制自检**：组内 Spearman(hit%, 稳态BW) 仍 ρ≥0.9（若 hit% 稳了而 ρ 崩 ⇒ 主因已换人，须重新归因）；
4. **灵敏度正对照**：所选口径必须能测出 ra0/default 的已知差异（128job 下为 randread 1.72×、seqread 0.14×），测不出则该口径不可用于 A/B 判定。

---

## 十、执行顺序与交付

```
E0（改脚本+1 轮，报告）→ E5（10min，报告）→ E1（4h，报告）→ ⚠️E1.5（报批，40min）
   → E2（2h）→ E3（1.5h）→ E4（2h，末步 restart 须报批）→ [按结果] ⚠️E6 / ⚠️E7
```
- E0~E4 全程不改 Ceph 配置、不重启 OSD、不重灌 layout —— 布局锁定可保。总机时 ~10h。
- 每个实验单独交付：①数据表（稳态中位数/范围/最大偏差/CV）；②hit% 与 R_amp 每轮值；③原始 `perf dump`/`mempool`/`.stats` JSON 目录路径；④布局指纹复查（UUID + CRUSH md5 + up_from + `bluestore_default_buffered_read`）。
- 每步做完先报告再进下一步，**不要连跑到底**。
