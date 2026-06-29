# 10_A_4 readahead/prefetch 分离测试（2026-06-24）

> 本文完成 `10_A` 顺位4 的验证：在 128G 大工作集上测试 `--max-readahead 0` 的效果，并带 NIC RX 采样计算放大倍数。
> 前置文档：[`10_3`](./10_3-l1-rados-and-cache-compare-results.md) §三（16G 小工作集 G1-G4 对照）
>
> ⚠️ **数据订正历史**：
> 1. 初版基于未保存的终端输出，数据不可追溯 → 用户要求重跑
> 2. 重跑发现 `bench-juicefs.sh` 未传 `--block-size 256K`，导致全部在 4K block 下测试 → 结论错误
> 3. 第二版用 4K block 测试，得出"readahead 关停无效"的错误结论 → 已作废
> 4. 第三版用 `EXTRA_FORMAT_OPTS="--block-size 256K"` 正确创建卷，数据有原始文件支撑
> 5. **🔴 第四版（`readahead-sweep-20260624-162801`，真冷态 sweep）推翻"readahead 是放大主因"的结论**——
>    见 §六。第三版的 73.2/77.7 是 **`--cache-size` 默认 100G（未显式传 0）口径**，prefetch 仍开启；
>    真冷态（显式 `--cache-size 0`，会强制关 prefetch）下关 readahead 只到 **52.0 MB/s，不达标**。
>
> ⚠️ **2026-06-24 二次复核（opencode）：第三版 73.2「冷态达标」口径不干净，已被第四版推翻。**
> - 第三版未显式传 `--cache-size 0`，实际带 100G 默认缓存且 prefetch 开启 → 73.2 非真冷态。
> - 第四版显式 `--cache-size 0`（日志可见 `cache-size is 0, writeback and prefetch will be disabled`）→
>   真冷态下 readahead 各档随机读见 §六：default 37.2、关停(0) 仅 52.0，**真冷态无任何档达标**。
> - **结论修正：readahead 不是 2.5× 放大的主因**（详见 §六判读）。
>
> 📋 **批次有效性标注（已更新）**：
> | 批次 | 文件前缀 | Block / cache | 有效性 | 说明 |
> |------|---------|--------------|--------|------|
> | 第二版 | `readahead-split-20260624-103426` | 4K | ❌ 作废 | 未传 block-size |
> | 4K+NIC | `nic-randread-20260624-121726` | 4K | ❌ 作废 | 基线 17，4K |
> | 第三版 | `nic-randread-256k-20260624-132740` | 256K / **cache=100G** | ⚠️ **口径不纯** | prefetch 开，73.2 非真冷态 |
> | **第四版 sweep** | **`readahead-sweep-20260624-162801`** | 256K / **cache=0** | ✅ **真冷态，以此为准** | default 37.2、关停 52.0，readahead 非主因 |
>
> 📋 **opus 建议改进（未来采纳）**：
> - 每次 run 的原始文件应包含 mount 命令（当前仅汇总日志有，单 run 文件无）
> - OSD 端也应 drop_caches（当前仅客户端清，OSD BlueStore cache 不可控）
> - `--max-readahead 0` 有副作用：顺序写从 ~117 降到 ~35-67 MB/s，交付时需按负载类型选择

---

## 一、测试目的

确认 `--max-readahead 0` 在 **256K block + 128G 大工作集** 下是否有效，并带 NIC RX 采样计算放大倍数。

## 二、测试配置

| 项 | 值 |
|----|----|
| 池 | `juicefs-data` EC 4+2 |
| **block-size** | **256K**（`EXTRA_FORMAT_OPTS="--block-size 256K"`） |
| layout | 128 jobs × 1G = 128G（默认参数写入，保留卷复用） |
| fio | bs=256k randread iodepth=128 numjobs=128 direct=1 runtime=60s |
| 缓存 | cache=0（Config A/B），cache=10G（Config C） |
| 每次跑前 | drop_caches（内核 + JuiceFS cache） |
| NIC 采样 | eno1（`/proc/net/dev` 跑前跑后取差） |
| 重复 | 3 次 |

| Config | 挂载参数 | 说明 |
|--------|---------|------|
| A | （无，全默认） | 基线（readahead on, prefetch on, cache=0） |
| B | `--max-readahead 0` | 只关 readahead，prefetch=默认(1), cache=0 |
| C | `--cache-size 10240 --cache-dir /data/jfsCache --max-readahead 0 --prefetch 0` | G4 交付候选 |

## 三、结果

| Config | Run1 | Run2 | Run3 | AVG | NIC RX AVG | 放大 AVG | 达标? |
|--------|------|------|------|-----|-----------|---------|-------|
| **A: 默认** | 44.9 | 45.6 | 45.4 | **45.3** | 118.2 | **2.61×** | ❌ |
| **B: `--max-readahead 0`** | 73.2 | 78.9 | 80.9 | **77.7** | 116.9 | **1.51×** | ✅ |
| **C: G4** | 75.6 | 76.1 | 76.1 | **75.9** | 117.2 | **1.55×** | ✅ |

> Config A 与 09 基线吻合（45.3 vs 45.9 MB/s，2.61× vs ~2.5×），数据可信。

### 放大分解

| 层 | 放大 | 来源 |
|----|------|------|
| L1 裸 librados / EC / 网络 | 1.04× | `10_3` §一 L1 |
| **JuiceFS readahead**（A→B 差） | **1.73×**（2.61÷1.51） | **readahead 是主要放大来源** |
| JuiceFS 其他内部（元数据/调度/FUSE） | 1.45×（1.51÷1.04） | 仍有残余，但小于 readahead |
| **A 总放大** | **2.61×** | 三者叠加 |

## 四、关键发现

### 4.1 ✅ readahead 是主要放大来源

`--max-readahead 0` 将放大从 2.61× 降到 1.51×，READ 从 45.3 暴涨到 77.7 MB/s（+71%）。readahead 贡献了约 1.73× 的放大，是 JuiceFS 内部放大的主要来源。

**这与 `10_3` §三 16G 小工作集的结论方向一致**（16G: 3.12→2.04, readahead 贡献 ~1.53×）。

### 4.2 G4（加 cache + --prefetch 0）不比单独 --max-readahead 0 好

| 对比 | READ | 放大 | 说明 |
|------|------|------|------|
| B: `--max-readahead 0` | 77.7 | 1.51× | 最佳 |
| C: G4 (cache + `--max-readahead 0 --prefetch 0`) | 75.9 | 1.55× | 加 cache + --prefetch 0 反而略降 |

128G 数据 >> 10G cache，缓存命中率极低。`--prefetch 0` 的负协同效应（`10_A_4` 初版发现的）在 256K block 下仍然存在但幅度很小（77.7→75.9，−2%）。

### 4.3 Run1 冷态即达标

Config B 的 Run1（最冷态）= 73.2 MB/s > 59 目标。不需要 OSD 缓存预热，冷态即可达标。

### 4.4 之前 10_A_4 "证伪"的原因：4K block size

| Block size | `--max-readahead 0` 效果 | 说明 |
|-----------|-------------------------|------|
| 4K（错误） | 42.9 MB/s（↓6%） | 4K block 下每个 256K 读拉 64 个对象，瓶颈在对象数而非放大 |
| **256K（正确）** | **77.7 MB/s（↑71%）** | 256K block 下 readahead 预读相邻 block 是放大主因 |

`bench-juicefs.sh` 不自动传 `--block-size`，需 `EXTRA_FORMAT_OPTS="--block-size 256K"`。此前所有用 `bench-juicefs.sh` 跑的测试（包括 10_A_4 初版/重跑）都用了 4K block，**结论需以本轮 256K 数据为准**。

## 五、结论

### 5.1 推荐配置

**`--max-readahead 0` 单独使用**（保留 prefetch 默认值=1，不开 cache）：
- randread 冷态 = **77.7 MB/s**（目标的 1.32×）
- 放大 = **1.51×**（基线的 58%）
- 零成本（仅 mount 参数）

### 5.2 不需要 cache

G4（加 cache=10G + --prefetch 0）不比单独 `--max-readahead 0` 好。128G 数据下 10G cache 命中率太低，不值得增加复杂度。

### 5.3 ⚠️ 交付适用边界（`--max-readahead 0` 的副作用）

`--max-readahead 0` 对随机读有利但对顺序写有害。256K block 下实测数据：

| 负载 | 默认（readahead on） | `--max-readahead 0` | 变化 | 达标(59)? |
|------|---------------------|---------------------|------|----------|
| randread（128G 冷态 r1） | 44.9 MB/s | **73.2 MB/s** | +63% | 默认❌ → 关后✅ |
| seqwrite（1job×4G, bs=4M） | 70.1 MB/s | **54.2 MB/s** | −23% | 默认✅ → 关后❌ |
| seqwrite + `--prefetch 0` | — | 48.4 MB/s | −31% | ❌ |

> 09 基线 seqwrite 为 ~117 MB/s（可能含 OSD 热态因素），本轮空卷首写 70 MB/s。同批次相对比较（A vs B）有效。

交付时不能无差别全局关停，需按负载类型选择：

| 负载类型 | 是否关 readahead | 理由 |
|---------|-----------------|------|
| **随机读为主**（推理/随机采样） | ✅ 关 | randread 45→73 MB/s，冷态达标 |
| **顺序写/顺序读**（数据导入/checkpoint） | ❌ 不关 | 顺序写 70→54 MB/s，跌破目标 |
| **混合负载** | 分挂载点 | 用两个 JuiceFS 挂载点分离读写负载，各自配置 |

理想方案：确认 JuiceFS 是否支持按 IO 模式自适应（随机关预读、顺序开预读），避免手动分挂载点。

原始数据：
- [`results/seqwrite-256k-20260624-143523-a-default.txt`](../../results/seqwrite-256k-20260624-143523-a-default.txt) — 默认 seqwrite
- [`results/seqwrite-256k-20260624-143523-b-no-readahead.txt`](../../results/seqwrite-256k-20260624-143523-b-no-readahead.txt) — `--max-readahead 0` seqwrite
- [`results/seqwrite-256k-20260624-143523-c-no-both.txt`](../../results/seqwrite-256k-20260624-143523-c-no-both.txt) — `--max-readahead 0 --prefetch 0` seqwrite

### 5.3 瓶颈定位更新（🔴 已被 §七 真冷态 sweep 推翻）

> 下表是 cache=100G 口径（prefetch 开）下的旧推断，**已作废**。真冷态见 §七。

| 放大来源 | 旧推断（cache=100G） | §七 真冷态修正 |
|---------|---------------------|---------------|
| EC/网络 | 1.04× | 1.04×（不变，L1 实测）|
| ~~readahead 预读~~ | ~~1.73×（主要来源）~~ | ❌ **非主因**：真冷态 readahead 量 1~default 间随机读不变（37.2~37.7）|
| EC 取片 + librados 协议帧 | — | ✅ **真主因**：strace 139≈4 OSD×35，对齐 EC 4+2 四分片 |
| **总放大** | 2.61×（cache=100G）| ~2.5×（真冷态，主体来自 EC 取片）|

## 六、真冷态 readahead sweep（`--cache-size 0`，2026-06-24，决定性）

> 批次 `readahead-sweep-20260624-162801`（`tests/bench-readahead-sweep.sh`）。
> 与第三版的关键区别：**显式 `--cache-size 0`**（日志可见 `cache-size is 0, writeback and prefetch will be disabled`，
> 即 cache=0 连带强制关 prefetch），客户端 + 3 台 OSD 都 drop_caches。这是迄今最干净的真冷态口径。
> 数据从各档独立 fio 文件提取（汇总表因脚本 awk 输出污染 bug 失真，已修；独立文件不受影响）。

### 6.1 结果（128G 256K 真冷态，r1）

| readahead(MiB) | 随机读 | 顺序读(4M) | 顺序写(4M) |
|---------------|--------|-----------|-----------|
| 0（全关） | **52.0** | 51.9 | 59.5 |
| 1 | 37.7 | 90.3 | 66.3 |
| 4 | 37.5 | 97.1 | 58.6 |
| 8 | 37.4 | 97.1 | 62.0 |
| default | 37.2 | 95.7 | 69.4 |

### 6.2 判读：readahead **不是** 2.5× 放大的主因

1. **readahead 量在 1~default 间变化，随机读纹丝不动（37.2→37.7）。** 若预读相邻 block 是 2.5× 放大主因，
   预读量从 default 减到 1MiB 应显著降放大、提随机读——实测不动。说明**随机读时 readahead 基本没触发/没放大**
   （随机偏移下预读命中率本就极低）。
2. **只有 ra=0 这个"完全禁用"档跳到 52.0**，且 37→52 的幅度**不足以解释消除 2.5× 放大**
   （若 readahead 是主因，真冷态关掉应把放大压到接近 1×、随机读冲 70+，实测只到 52）。ra=0 的提升更像
   走了不同的内部读路径/连带效应，而非"减少预读流量"。
3. **真冷态最高随机读 = 52.0（关 readahead），仍不达标（<59）。** 第三版的 73.2「冷态达标」是
   **cache=100G（prefetch 开）口径**，非真冷态——`--cache-size 0` 会强制关 prefetch，73.2 复现不出。
4. **2.5× 真主因 = EC 取片 + librados 协议帧**（strace 铁证：每 256K 读 = 139 次 socket read ≈ 4 OSD × 35，
   精确对齐 EC 4+2 四分片），与 readahead 无关。

### 6.3 真冷态无完美档 + 一个关键副作用

- **没有任何 readahead 档能让 随机读/顺序读/顺序写 三线同时 ≥59。** 随机读要小预读（ra=0 最好但只 52），
  顺序读要大预读（ra≥1 才上 90+，ra=0 崩到 51.9），二者对立。
- **真冷态单客户端随机读做不到 59**（最高 52）。59 达标只在 **cache=100G（prefetch 开）** 口径下成立（73.2）。
  → 单客户端是否达标，**取决于业务是真冷态一次扫，还是允许缓存的重复读**（待业务确认）。

### 6.4 真冷态原始数据
- 汇总（注：表因 awk bug 失真，以独立文件为准）：`results/readahead-sweep-20260624-162801.txt`
- 各档独立：`results/readahead-sweep-20260624-162801.txt.ra{0,1,4,8,default}-{randread,seqread,seqwrite}`

---

## 七、原始数据（第三版 cache=100G 批次，口径不纯，留档）

| 文件 | 说明 |
|------|------|
| [`results/20260624-123032-g4-layout-256k.txt`](../../results/20260624-123032-g4-layout-256k.txt) | 128G layout（256K block, `"BlockSize": 256`） |
| [`results/nic-randread-256k-20260624-132740.txt`](../../results/nic-randread-256k-20260624-132740.txt) | 三组配置汇总日志 + NIC RX |
| [`results/nic-randread-256k-20260624-132740-a-r1.txt`](../../results/nic-randread-256k-20260624-132740-a-r1.txt) | Config A Run1 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-a-r2.txt`](../../results/nic-randread-256k-20260624-132740-a-r2.txt) | Config A Run2 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-a-r3.txt`](../../results/nic-randread-256k-20260624-132740-a-r3.txt) | Config A Run3 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-b-r1.txt`](../../results/nic-randread-256k-20260624-132740-b-r1.txt) | Config B Run1 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-b-r2.txt`](../../results/nic-randread-256k-20260624-132740-b-r2.txt) | Config B Run2 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-b-r3.txt`](../../results/nic-randread-256k-20260624-132740-b-r3.txt) | Config B Run3 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-c-r1.txt`](../../results/nic-randread-256k-20260624-132740-c-r1.txt) | Config C Run1 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-c-r2.txt`](../../results/nic-randread-256k-20260624-132740-c-r2.txt) | Config C Run2 fio 原始 |
| [`results/nic-randread-256k-20260624-132740-c-r3.txt`](../../results/nic-randread-256k-20260624-132740-c-r3.txt) | Config C Run3 fio 原始 |

---

环境：tikv-node (192.168.11.12)，JuiceFS v1.3.1，Ceph HEALTH_OK，2026-06-24。
