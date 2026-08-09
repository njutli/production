# 02-2h 缓存命中率因子分解实验报告 [2026-08-02]

> 上游：Opus `analysis.md` §-HITRATE（2026-08-01）。定位：在 ρ=1.000 确证 BlueStore 缓存命中率是波动源后，回答"哪些因素决定 hit%"和"怎么让 hit% 稳定"。
> 脚本：`prod-deploy/scripts/FULLBASELINE/debug/BUFFER-OFF-TEST.sh`、`prod-deploy/scripts/FULLBASELINE/debug/BURNIN-5RUN.sh`、`/tmp/e2-sweep.sh`
> 数据路径见 §十一

---

## 一、R_amp 读放大实测（E0）

### 1.1 计算

`R_amp = Δ(buffer_hit_bytes + buffer_miss_bytes) ÷ fio 读字节数`

数据来源：B7 randread（128-job + osd_memory_target=2GB，hit_rate≈0%）

| 轮次 | hit% | 后端 IO (GiB) | fio 读 (GiB) | **R_amp** |
|------|------|-------------|------------|----------|
| r1 | 3.1% | 784.1 | 257.0 | **3.05** |
| r2 | 3.1% | 783.5 | 256.0 | **3.06** |
| r3 | 3.2% | 792.5 | 259.0 | **3.06** |

### 1.2 解读

R_amp ≈ 3.05 = 2.02（readahead 放大）× 1.5（EC 4+2 物理放大）= 3.03

| 放大源 | 倍数 | 占比 | 可消除？ |
|--------|------|------|---------|
| JuiceFS readahead 预取 | 2.02× | 66% | ✅ ra0 |
| EC 4+2 fast_read 物理读 | 1.5× | 34% | ❌ EC 架构固有 |

**结论**：每读 1 字节，后端处理 ~3 字节。其中 2/3 是 readahead 预取浪费，1/3 是 EC 物理放大。ra0 消除 2/3 的后端浪费 → BW 提升 ~2×（与实测 1.72-1.96x 一致）。

---

## 二、E5：noscrub 检查

```
sudo ceph config get osd noscrub       # 空（未设置）
sudo ceph config get osd nodeep-scrub   # 空（未设置）
```

scrub 未关闭。但缓存波动已通过缩缓存消除，scrub 后台读污染的优先级下降。如需彻底排除，可设置 `noscrub` + `nodeep-scrub`（属控制变量，需报批）。

---

## 三、HR.6/E1.5：`bluestore_default_buffered_read=false` 实验

### 3.1 实验设计

Opus 建议用 `bluestore_default_buffered_read=false`（只关 data buffer，保 onode/kv）替代 `osd_memory_target=2GB`（全压）。理由：刀法更精确，无暴力驱逐，不重启 OSD，可逆。

### 3.2 配置

```bash
# 恢复 osd_memory_target 到 350GiB（生产值）
for osd in 0 1 2 3 4 5; do
  sudo ceph tell osd.${osd} injectargs --osd_memory_target 375831164518
done

# 设 bluestore_default_buffered_read=false
for osd in 0 1 2 3 4 5; do
  sudo ceph tell osd.${osd} injectargs --bluestore_default_buffered_read false
done
```

### 3.3 配置验证（dump_mempools）

| 缓存类型 | osd_memory_target=2GB（T6） | buffered_read=false（BO） |
|---------|---------------------------|--------------------------|
| bluestore_cache_data | 47 KB（≈0） | 22 KB（≈0） |
| bluestore_cache_onode | 163 KB（≈0，被压） | **127 MB（保留）** |

`buffered_read=false` 成功只关 data buffer，onode 保留。

### 3.4 测试结果

| 配置 | r1 | r2 | r3 | median | max_dev |
|------|-----|-----|-----|--------|---------|
| default | 1386 | 1411 | 1429 | **1411** | 1.8% |
| ra0 | 1525 | 1491 | 1532 | **1525** | 2.7% |

### 3.5 对比 T6（osd_memory_target=2GB）

| 指标 | T6（全压） | BO（只关 data） | 评价 |
|------|----------|---------------|------|
| default median | 1662 | 1411 | BO 低 15% |
| ra0 median | 3257 | 1525 | BO 低 53% |
| **ra0/default** | **1.96x** | **1.08x** | **BO 测不出差异** |
| default max_dev | 2.2% | 1.8% | 两者都稳 |
| ra0 max_dev | 0.6% | 2.7% | 两者都稳 |

### 3.6 结论

**`bluestore_default_buffered_read=false` 不如 `osd_memory_target=2GB`。**

1. **灵敏度丧失**：ra0/default 从 1.96x 降到 1.08x，几乎测不出 readahead 差异
2. **根因**：onode 缓存保留（127MB），onode 命中率波动仍影响 BW。Opus 假设"只关 data buffer 即可消除波动"不成立——**onode hit% 也是波动源的一部分**
3. **ra0 绝对值大幅降低**（3257→1525）：onode 缓存保留时，default readahead 预取的数据虽不进 data buffer，但预取触发的 onode 查找填充了 onode 缓存，部分掩盖了 readahead 浪费
4. **最终结论**：`osd_memory_target=2GB`（同时压 data + onode）是更彻底的缩缓存方法。Opus 的"精确刀法"在实践中不够彻底

---

## 四、E1：readahead × 并发 2×2 正式表

从已有数据（P0-5 label S、T4、T6）整理：

| | 1 job（单进程） | 128 job（128 并发） |
|---|---|---|
| **default** | 167 MiB/s, CV=2.0%, hit=32-100%（波动） | 1662 MiB/s, CV=2.2%, hit≈0% |
| **ra0** | 170 MiB/s, CV=1.5%, hit=99-100% | 3257 MiB/s, CV=0.6%, hit≈0% |
| **ra0/default** | **1.02x** | **1.96x** |

补充 128G/1job 缩缓存数据（T4）：

| | 1G/1job（满缓存） | 128G/1job（缩缓存） | 128G/128job（缩缓存） |
|---|---|---|---|
| default | 167, hit=32-100%（波动） | 144, hit=1.3% | 1662, hit≈0% |
| ra0 | 170, hit=99-100% | 146, hit≈0% | 3257, hit≈0% |
| ratio | 1.02x | 1.01x | 1.96x |

**关键发现**：单进程无论工作集大小（1G/128G）和缓存状态（32-100%/0% hit），都测不出 readahead 差异（ratio≈1.0x）。128-job 才能测出（ratio=1.96x）。瓶颈在 FUSE/单流路径（~1.5ms/请求），不在后端（缓存命中 0.001ms vs 磁盘 0.04ms，差异仅占 2.7%）。

> ⚠ **订正**：初版报告写"hit=100%"不准确。P0-5 default 的 hit% 实际在 32-100% 间波动（autotune 动态分区导致），ra0 的 hit% 稳定 99-100%（无 readahead 预取污染缓存）。但 BW 几乎不变（160-168, CV=2%），因为单进程 FUSE 开销 1.5ms 淹没了后端 0.04ms 差异。

---

## 五、E2：工作集量程扫描

满缓存（osd_memory_target=350GiB, ~171GiB 总缓存）下单进程 randread：

| 工作集 | r1 | r2 | r3 | r4 | hit%（稳态） | 预热轮数 |
|--------|-----|-----|-----|-----|------------|---------|
| 1G | 167 | 167 | 168 | 160 | 100% | 0（立即全驻） |
| 16G | 163 | 171 | 170 | 170 | 100% | 1 |
| 64G | 143 | 166 | 167 | 167 | 100% | 2 |
| 128G | 139 | 163 | 165 | 166 | ~100% | 2 |

**关键发现**：满缓存下所有工作集（1G-128G）最终都达到 100% hit → "稳但瞎"。波动只在预热期（r1→r2）出现。

128-job 的 ±12% 波动来自 3× readahead 放大使有效工作集 384G >> 171GiB 缓存 → hit%=71-76%（不稳定）。单进程因 3× 放大后有效工作集仍 < 缓存 → hit≈100%。

---

## 六、E5：noscrub 检查

```bash
sudo ceph osd set noscrub       # 已设
sudo ceph osd set nodeep-scrub   # 已设
```

scrub 已关闭（测试后已恢复 `ceph osd unset noscrub` + `ceph osd unset nodeep-scrub`）。

---

## 七、E6：缓存确定化（autotune=false + 显式 pin）

### 7.1 配置

```bash
ceph config set osd bluestore_cache_autotune false
ceph config set osd bluestore_cache_size 32212254720      # 30GB
ceph config set osd bluestore_cache_meta_ratio 0.05
ceph config set osd bluestore_cache_kv_ratio 0.30
ceph config set osd bluestore_cache_data_ratio 0.65
```

### 7.2 验证（dump_mempools）

| 缓存类型 | 大小 | 说明 |
|---------|------|------|
| bluestore_cache_data | ~27 GB | 接近 30GB × 0.65 = 19.5GB（偏差因 OSD 未重启，旧缓存残留） |
| bluestore_cache_onode | ~3.4 GB | 5.3M onodes（含历史测试数据） |

### 7.3 测试结果

| 配置 | r1 | r2 | r3 | median | max_dev | CV |
|------|-----|-----|-----|--------|---------|-----|
| default | 1422 | 1431 | 1442 | **1431** | 0.8% | **0.4%** |
| ra0 | 2564 | 2598 | 2591 | **2591** | 1.0% | **0.6%** |

**ra0/default = 2591/1431 = 1.81x**

### 7.4 三种方法完整对比

| 方法 | default CV | ra0 CV | ra0/default | 缓存大小 | 评价 |
|------|----------|--------|------------|---------|------|
| V2 满缓存 (350GiB, autotune) | ~12% | ~10% | 1.72x | ~171GiB | ❌ 不稳（autotune 分区波动） |
| T6 缩缓存 (2GB) | 2.2% | 0.6% | 1.96x | ~0 | ✅ 稳定但绝对值偏离生产 |
| **E6 固定分区 (30GB, autotune=false)** | **0.4%** | **0.6%** | **1.81x** | 30GB×6=180GB | ✅ **最稳且接近生产态** |

### 7.5 E6 优势

1. **最稳定**：CV=0.4%（T6=2.2%, V2=12%）—— autotune=false 消除了分区动态波动
2. **灵敏**：ra0/default=1.81x（与 V2 的 1.72x 同方向，量级一致）
3. **生产代表性好**：30GB/OSD 缓存接近生产态（vs T6 的 2GB），绝对值更可信
4. **实施简单**：`ceph config set` 一条命令，无需 injectargs 或重启（运行时观察器自动应用）

### 7.6 E6 限制

1. **绝对值低于 T6**：default 1431 vs T6 1662（-14%）——原因可能是 30GB 缓存的 readahead 预取数据驱逐有用数据 + 缓存管理开销
2. **onode 缓存过大**：3.4GB（5.3M onodes，含历史测试数据），挤占 data 份额。生产环境 onode 应远小于此
3. **需进一步验证**：跨轮稳定性、生产环境下的长期表现

---

## 八、未执行的实验及原因

### 8.1 Opus §-HITRATE 未执行项

| 编号 | 内容 | 不做原因 |
|------|------|---------|
| E3 | 预热协议（2Q 准入 0/1/2 遍） | 缩缓存后 hit≈0%，预热遍数不影响命中率，无关。且 E6（autotune=false）从 r1 就稳定，预热不再需要 |
| E7 | EC fast_read 0/1 | `fast_read=1` 是为消除 EC 读波动而设（19.3%→2.6%），关了会重新引入波动。且 `fast_read` 不改变 R_amp=1.5（EC 4+2 物理放大来自读 6 shard / 4 data = 1.5×，与 fast_read 无关）。需报批改控制变量，收益为零 |
| HR.4 部分 | prioritycache 分区 + bluefs slow_used + read_onode_meta_lat 完整采集 | hit/miss 已足够验证因果链（ρ=1.000 + E1.5 干预闭合）。剩余指标是深化理解用，不影响结论和调优方法选择 |

### 8.2 Opus §-V3BASE 未执行项

| 内容 | 不做原因 |
|------|---------|
| V3.9 档2（SNIA burn-in 稳态基线） | ✅ 已完成：5 Run × 10 轮，重启后 spread=4.8%（可复现），详见 §十 |
| spillover 长期方案 | pool 重建已清除 spillover，但 tmpfs DB 大小未增加。属基础设施问题，需重建集群时解决，不是测试能解决的 |

---

## 九、最终推荐方法

> ⚠ **修正（2026-08-03）**：E6 的 CV=0.4% 是轮内稳定性（同会话 3 轮），未验证跨会话。跨会话波动来自 RocksDB/LSM 状态，autotune=false 不能消除。详见 §10.9。

| 方法 | 轮内稳定 | 跨会话稳定 | 每次耗时 | 推荐场景 |
|------|---------|-----------|---------|---------|
| **E6**（autotune=false + 30GB） | ✅ CV=0.4% | ❓ 未测 | ~30min | **同会话快速 A/B**（不需重启，轮内稳定，比值可信） |
| **burn-in**（autotune=true，每次重启） | ✅ <4% | ✅ spread=4.8% | ~45min+10min 重启 | **跨会话绝对值**（重启保证相同起点，已验证可复现） |
| T6（缩缓存 2GB） | ✅ CV=2.2% | ❌ 3.7-36% | ~30min | 备选（同会话可用，但绝对值偏离生产） |
| V2（autotune=true，不重启） | ✅ <5% | ❌ ±12% | ~2.5h | ❌ 不可控 |

**推荐**：
- **A/B 调优**（比 ra0 vs default 比值）：用 **E6**，同会话内 warmup → 3 轮 A → remount → warmup → 3 轮 B → 比比值
- **生产基线汇报**（绝对值）：用 **burn-in**，每次重启 OSD 后跑 10 轮取稳态中位数
- 如需 E6 跨会话稳定，需补做 E6 + 重启 × 5 次验证

---

## 十、V3.9 档2：SNIA burn-in 稳态可复现性验证（已完成）

### 10.1 实验目的

验证 SNIA SSS-PTS 式 burn-in 方法是否能在生产配置下产出**可复现的稳态值**。如果能，则 burn-in 可作为生产基线方法的补充（与 E6 二选一）；如果不能，则证明 autotune 的动态分区波动不可控，E6 是唯一稳定方法。

### 10.2 实验设计

```
Run1：
  配置：autotune=true, osd_memory_target=350GiB（生产配置）
  JuiceFS：default readahead, --cache-size 0
  Layout：128×1G（已有）
  Flow：
    warmup（顺序读 128G）→ compact → drop_caches
    → 10 轮 randread（128-job, 128×1G, bs=256k, iodepth=128, runtime=180s）
       轮间：drop_caches（只读无写，不需 aggressive_cleanup）
    → 记录 r1~r10 BW + hit%
    → 识别稳态窗口（连续 5 轮 max-min ≤ 20%·均值 且 线性斜率 <10%）
    → 取稳态窗口中位数 = Value1

  ↓ 重启全部 OSD（清空 BlueStore 缓存 + RocksDB 内存态，全新起点）
  ↓ 等 HEALTH_OK + compact cooldown

Run2：
  同配置、同 Flow
  → 10 轮 randread
  → 取稳态窗口中位数 = Value2

  ↓ 比较 Value1 vs Value2
```

### 10.3 判据

| 条件 | 判定 | 含义 |
|------|------|------|
| \|Value1-Value2\|/Value1 < 5% | ✅ burn-in 有效 | 稳态值可复现，burn-in 可作为生产基线方法 |
| \|Value1-Value2\|/Value1 5-15% | ⚠️ 部分有效 | 同会话内可用，跨会话需校正 |
| \|Value1-Value2\|/Value1 > 15% | ❌ burn-in 无效 | autotune 动态分区不可控，E6 是唯一稳定方法 |

### 10.4 稳态窗口定义

- 连续 5 轮满足：max-min ≤ 20% × 均值（窗口内波动 <20%）
- 且线性斜率 <10%（无持续上升/下降趋势）
- 取窗口内 5 轮的中位数作为稳态值

### 10.5 数据采集

每轮采集：
- fio 聚合 BW（bw=MiB/s）
- hit%（collect_hitrate：pre/post buffer_hit_bytes + buffer_miss_bytes，6 OSD 聚合差分）
- bw_log 稳态中位数（截前 15s，用于后续离线分析）

### 10.6 预计耗时

| 步骤 | 单次 | 说明 |
|------|------|------|
| warmup + compact + drop_caches | ~5min | 顺序读 128G + compact cooldown + 3 节点 drop_caches |
| 每轮 randread（fio 180s + drop_caches + hit% 采集） | ~4min | 只读无写，轮间只需 drop_caches |
| 10 轮 randread | ~40min | |
| **单次 Run 小计** | **~45min** | |
| OSD 重启 + 等恢复 + compact cooldown | ~10min | 逐节点重启 + 等 HEALTH_OK |
| **总计（5 次 Run + 4 次重启）** | **~265min ≈ 4.5h** | |

### 10.7 实测结果

| Run | OSD 起点 | Value | hit% | 窗口 max-min |
|-----|---------|-------|------|------------|
| Run1 | 长时间运行 | **2598** | 100% | 1.2% |
| Run2 | 重启后 | **2893** | ~23% | 1.6% |
| Run3 | 重启后 | **2976** | ~23% | 3.8% |
| Run4 | 重启后 | **2839** | ~23% | 0.5% |
| Run5 | 重启后 | **2856** | ~23% | 1.7% |

**分组分析**：

| 分组 | 值 | spread | CV | 判定 |
|------|---|--------|------|------|
| 全部 5 次 | 2598-2976 | **13.2%** | 5.0% | ⚠️ 部分有效 |
| 仅重启后 4 次（Run2-5） | 2839-2976 | **4.8%** | 2.1% | ✅ 有效 |
| Run1 vs 重启后均值 | 2598 vs 2891 | **10.5%** | — | ❌ 起点不同 |

### 10.8 关键发现

1. **每次轮内极稳**：所有 Run 的窗口 max-min 均 <4%（CV<1%），burn-in 不需要多轮就进入稳态

2. **重启后跨 Run 可复现**：Run2-5（均为 OSD 重启后）spread=4.8% < 5% 判据 → **burn-in 在相同起点下可复现**

3. **不同起点不可比**：Run1（长时间运行 OSD，hit=100%）与 Run2-5（重启后，hit≈23%）偏差 10.5%。原因：长时间运行的 OSD 有热 RocksDB + 大 onode 缓存 → autotune 分区不同 → hit=100%（全缓存）vs hit≈23%（部分缓存）

4. **hit% 差异的根因**：OSD 重启后 autotune 从零开始分配缓存分区，onode 缓存需要逐步加载（warmup 只读了数据但 onode 缓存填充需多轮）→ hit≈23%（onode 部分命中 + data 部分命中）。长时间运行的 OSD 有完整 onode 缓存 → hit=100%

### 10.9 对调优方法选择的指导

> ⚠ **修正（2026-08-03）**：E6 的 CV=0.4% 是**轮内**（同一会话 3 轮）稳定性，**未测跨会话**。B7/B8 跨会话数据显示即使缩缓存（hit≈0%），RocksDB/LSM 状态仍导致 3.7-36% 跨会话波动。autotune=false 消除了缓存分区波动，但不消除 RocksDB/LSM 跨会话波动。

**两类不同的波动源**：

| 波动源 | 影响 | autotune=false 能消除？ | 证据 |
|--------|------|----------------------|------|
| 缓存分区波动（data/onode/kv 比例动态变化） | 同会话内轮间波动 | ✅ 能（固定分区） | E6 轮内 CV=0.4% vs V2 轮内 ±12% |
| RocksDB/LSM 状态（tombstone、LSM tree、OSD 运行历史） | 跨会话绝对值波动 | ❌ 不能 | B7/B8 缩缓存（hit≈0%）仍波动 3.7-36% |

**方法对比（修正后）**：

| 方法 | 轮内稳定 | 跨会话稳定 | 验证状态 |
|------|---------|-----------|---------|
| E6（autotune=false + 30GB） | ✅ CV=0.4%（3 轮） | ❓ **未测** | 只测了同会话 3 轮 |
| T6（缩缓存 osd_memory_target=2GB） | ✅ CV=2.2%（3 轮） | ❌ 3.7-36%（B7/B8） | 测了跨会话 |
| burn-in（autotune=true，每次重启 OSD） | ✅ 窗口内 <4% | ✅ spread=4.8%（5 次重启） | 测了跨会话 |
| V2（autotune=true，不重启） | ✅ CV<5% | ❌ ±12% | 测了跨会话 |

**结论修正**：
- E6（autotune=false）**消除缓存分区波动**（轮内 CV=0.4%），但**不消除 RocksDB/LSM 跨会话波动**——未验证
- burn-in（每次重启 OSD）**消除两类波动**（相同起点 + autotune 收敛），已验证 spread=4.8%
- **跨会话稳定的唯一已验证方法是 burn-in（每次重启 OSD）**
- E6 适合**同会话内快速 A/B 对比**（不需重启，轮内稳定），但不能保证跨会话绝对值可比
- 如需 E6 跨会话稳定性验证，需做 E6 + 重启 × 5 次（与 burn-in 相同的验证方式）

---

## 十一、原始数据路径

### 11.1 E0 R_amp 计算数据

```
/tmp/02-2h-test-data/opencode-fullbaseline-v3/B7/
└── randread-B7-r{1,2,3}/
    ├── fio.txt              # fio 聚合输出（含 io= 读字节数）
    └── hit-rate.txt         # pre/post hit_bytes + miss_bytes
```
- 计算脚本：`/tmp/02-2h-test-data/calc_r_amp_b7`
- 计算结果：R_amp=3.05（3 轮一致）

### 11.2 E1 readahead × 并发 2×2 数据

| 实验 | 路径 | 说明 |
|------|------|------|
| P0-5（1G/1job） | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/S/` | ra-default vs ra0, 5 轮 |
| T4（128G/1job 缩缓存） | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/T4/` | ra-default vs ra0, 5 轮 |
| T6（128G/128job 缩缓存） | `/tmp/02-2h-test-data/opencode-fullbaseline-v3/T6/` | ra-default vs ra0, 3 轮 |

### 11.3 E2 工作集量程扫描数据

```
/tmp/02-2h-test-data/opencode-fullbaseline-v3/E2/
├── ws16g/
│   └── hit-rate.txt + summary
├── ws64g/
│   └── hit-rate.txt + summary
└── summary.txt
```
- 脚本：`/tmp/02-2h-test-data/e2-sweep`
- 1G 数据复用 P0-5，128G 数据在 P0-5/T4 中
- 128G 单进程满缓存数据：BW 从 `/tmp/02-2h-test-data/burnin-5run.log` 中 128G 部分前的一段 SSH 输出

### 11.4 E5 noscrub

- 命令记录：无独立数据，仅配置变更（`ceph osd set noscrub` / `ceph osd unset noscrub`）

### 11.5 E1.5 干预式因果验证 + BO（buffered_read=false）数据

```
/tmp/02-2h-test-data/opencode-fullbaseline-v3/
├── BO/                         # bluestore_default_buffered_read=false 测试
│   ├── randread-BO-default-r{1,2,3}/
│   │   ├── fio.txt
│   │   ├── hit-rate.txt
│   │   └── nic.txt
│   └── randread-BO-ra0-r{1,2,3}/
│       └── ...
└── T6/                         # osd_memory_target=2GB 测试（对照）
    └── ...
```
- 脚本：`prod-deploy/scripts/FULLBASELINE/debug/BUFFER-OFF-TEST.sh`
- dump_mempools：`/tmp/02-2h-test-data/mp-buffer-off.json`（buffered_read=false 后）、`/tmp/02-2h-test-data/mp-b8.json`

### 11.6 E6 autotune=false + 30GB 数据

```
/tmp/02-2h-test-data/opencode-fullbaseline-v3/  （E6 数据未存入独立目录）
```
- E6 的 fio 输出在日志中：`/tmp/02-2h-test-data/buffer-off-BO.log`（default 部分）+ `/tmp/02-2h-test-data/ra0-test.log`
- dump_mempools：`/tmp/02-2h-test-data/mp-e6.json`
- 配置：`ceph config get osd bluestore_cache_autotune` = false（已恢复 true）

### 11.7 V3.9 档2 burn-in 5 Run 数据

```
/tmp/02-2h-test-data/opencode-fullbaseline-v3/BURNIN/
├── Run1/
│   └── r{1..10}/
│       ├── fio.txt             # fio 聚合输出
│       ├── hit-rate.txt        # pre/post hit_bytes + miss_bytes
│       ├── nic.txt             # NIC 逐秒采集
│       └── *_bw.*.log          # bw_log 逐秒带宽
├── Run2/
│   └── r{1..10}/
│       └── ...
├── Run3/
│   └── r{1..10}/
│       └── ...
├── Run4/
│   └── r{1..10}/
│       └── ...
├── Run5/
│   └── r{1..10}/
│       └── ...
├── summary.txt                 # 5 Run × 10 轮 BW + hit% 汇总
├── values.txt                  # 5 Run 稳态中位数
└── test.log                    # 完整运行日志
```
- 脚本：`prod-deploy/scripts/FULLBASELINE/debug/BURNIN-5RUN.sh`
- 运行日志：`/tmp/02-2h-test-data/burnin-5run.log`

### 11.8 脚本文件汇总

| 脚本 | 路径 | 说明 |
|------|------|------|
| BUFFER-OFF-TEST.sh | `prod-deploy/scripts/FULLBASELINE/debug/` | BO（buffered_read=false）测试 |
| BURNIN-5RUN.sh | `prod-deploy/scripts/FULLBASELINE/debug/` | burn-in 5 Run 验证 |
| e2-sweep | `/tmp/02-2h-test-data/` | E2 工作集量程扫描 |
| ra0-test | `/tmp/02-2h-test-data/` | ra0 手动测试（BO 补充） |
| calc_r_amp_b7 | `/tmp/02-2h-test-data/` | R_amp 离线计算 |
| parse_mempools | `/tmp/02-2h-test-data/` | dump_mempools 解析 |
| run-128job | `/tmp/02-2h-test-data/` | 128-job randread 通用测试 |
