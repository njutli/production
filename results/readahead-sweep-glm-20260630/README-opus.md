# max-readahead sweep + 多客户端复测 分析（opus 复核）

> 日期：2026-07-01
> 数据来源：本目录 `readahead-sweep-glm-20260630/`（GLM 采集，opus 独立对账 + 分析）
> 环境：JuiceFS v1.3.1 / Ceph 17.2.8 EC 4+2 (6 OSD) / 1Gbps / `--cache-size 0` / 128G(128×1G) / block-size=256K / fio nj=128,bs=256k,direct=1,runtime=60s
> 结论预告：**ra=0 把随机读放大从 3.30× 降到 2.17×、单客户端随机读 34→52、多客户端聚合 51→76（破 59）；但对验收口径 randrw 无改善（仍 ~50）。**

---

## 一、数据可靠性评估：可信（这次过程和数据都过硬）

我逐项独立重算 + 核对过程，GLM 这次的质量明显高于前几次：

### 过程正确性 ✓
- **冷态纪律到位**：`test-script.log` 每个 fio 前都有 `DROP ALL` → `client(.12): OK` + 3 台 OSD 各 `OK` → `DROP COMPLETE`；每个 ra 值重挂载都有 `mount-raX.log` 确认 `cache-size is 0, writeback and prefetch will be disabled`。
- **节奏合理（不是赶工）**：27 个 fio 从 12:23 跑到 13:23，约 60 分钟，每个 fio ~133s（含 drop + OSD before/after 采集）。对比 deepseek 曾经 6 秒间隔的赶工，这次每轮之间有充分 drop 时间。
- **OSD 采集成功**：324 个 json 全部有内容，log 里每轮 `OSD before: 6/6 OK` `OSD after: 6/6 OK`；after 在 fio 运行至 ~50s 时采（fio 仍在跑），窗口正确。
- **NIC RX 每 run 都记**（`*-nic.txt`，含 rx_before/after/delta），补上了 deepseek 漏采的项。
- **步骤 B 多客户端**：3 客户端挂载日志齐全（均 cache=0, ra=0），node2 时区已修正；每轮 3 客户端 fio 完成时刻**完全相同**（如 round1 三个都 13:38:19）→ 确认真并发。

### 数据自洽性 ✓（我独立重算，与 README 完全一致）
- randread 三轮极差 <0.5（ra0: 51.6/51.7/52.0），冷态稳定。
- 我用 python 独立算的 op_r_out_bytes 放大（下详）与 README 分毫不差。
- OSD 吐出量 ~6800-6900 MiB 恒定、每 op ~127 KiB，与 deepseek `seqrand-osd-compare-final`（126.7 KiB）独立测量吻合 → 跨测试交叉印证。

### 小瑕疵（不影响结论）
- randwrite/randrw 方差较大（见下），GLM 已如实标注，不是错误而是负载本身波动。

**判定：数据可信、过程可追溯，可用于分析。**

---

## 二、核心结果

### 主表 1：readahead 对随机读后端放大的影响

| max-readahead | randread BW | fio io (MiB) | Σop_r_out_bytes (MiB) | **后端放大** | NIC 放大 | IO depth≥64 |
|---------------|-------------|--------------|-----------------------|-------------|---------|-------------|
| **0** | **51.8** | 3139 | 6807 | **2.17×** | 2.33× | 35.6% |
| 4 | 34.2 | 2086 | 6902 | 3.31× | 3.60× | 8.8% |
| default(2MiB) | 34.3 | 2091 | 6886 | 3.29× | 3.58× | 8.7% |

（BW/放大为 3 轮均值）

### 主表 2：三类负载 BW（验收视角）

| max-readahead | randread | randwrite | randrw R | randrw W | **randrw 总计** |
|---------------|----------|-----------|----------|----------|----------------|
| **0** | **51.8** | 54.3 | 25.1 | 24.7 | 49.8 |
| 4 | 34.2 | 49.0 | 25.0 | 24.6 | 49.7 |
| default | 34.3 | 49.9 | 25.5 | 25.2 | 50.7 |

### 主表 3：多客户端聚合 @ ra=0（3 客户端同时 randread）

| 轮次 | tikv | node1 | node2 | **聚合** |
|------|------|-------|-------|---------|
| 1 | 26.2 | 29.8 | 19.2 | 75.2 |
| 2 | 23.9 | 28.5 | 24.0 | 76.4 |
| 3 | 27.3 | 26.6 | 23.0 | 76.9 |
| 均值 | 25.8 | 28.3 | 22.1 | **76.2** |

对比 default ra（deepseek 测）：聚合天花板 ~51。**ra=0 聚合 76.2，+49%，破 59。**

---

## 三、关键发现（每条都给数据依据 + 从原始文件的计算过程）

### 发现1：ra=0 把随机读后端放大从 3.30× 降到 2.17×，但没到 1×

**数据依据 + 计算过程**（我独立重算，与 GLM 一致）：

后端放大 = Σ(6 OSD 的 op_r_out_bytes after−before) / (fio io × 1048576)

以 **ra=0 randread r1** 为例，逐 OSD 从 json 取 `op_r_out_bytes`（after − before）：
```
数据来源：ra0-randread-r1-osd{N}-{before,after}.json 的 "op_r_out_bytes" 字段
osd0: (after−before) = 198,010,368  ≈ 188.8 MiB
osd1: 1,016,795,136  ≈ 969.7 MiB
osd2: 1,363,148,800  ≈ 1300.1 MiB
osd3: 1,582,133,248  ≈ 1508.8 MiB
osd4: 1,353,220,096  ≈ 1290.5 MiB
osd5: 1,614,027,776  ≈ 1539.2 MiB
Σ = 7,127,335,424 byte = 6797 MiB
fio io = 3131 MiB（来源 ra0-randread-r1-fio.txt 的 "io=3131MiB"）
后端放大 = 6797 / 3131 = 2.17×
```
三个 ra 值 × 3 轮，我全部独立重算：

| ra | r1 | r2 | r3 |
|----|----|----|----|
| 0 | 2.17× | 2.17× | 2.17× |
| 4 | 3.30× | 3.30× | 3.33× |
| default | 3.29× | 3.30× | 3.29× |

→ **ra=0 确实降了放大（3.30→2.17），但停在 2.17×，未趋近 1×。** 说明 readahead 只是放大的一部分（约 1/3），还有残余 2.17× 来自非 readahead 机制。

### 发现2：readahead 不增加 OSD 吐出总量，只降低有效利用率 —— 这是理解放大的关键

**数据依据**：三个 ra 值的 OSD 吐出总量几乎相同（6807 / 6902 / 6886 MiB，主表1 第4列），**但 fio io 差异巨大**（ra0=3139 vs 默认=2091 MiB）。

**含义（重要）**：
- OSD 无论 ra 多少，都吐出 ~6800-6900 MiB。
- ra=默认时，这 6886 MiB 里只有 2091 MiB 被 fio 用上（利用率 30%）→ 放大 3.29×。
- ra=0 时，同样 ~6800 MiB 里有 3139 MiB 被用上（利用率 46%）→ 放大 2.17×。
- **也就是说：readahead 预读的数据"混"在 OSD 吐出流里，ra=0 后这部分不再被预读浪费，同样的后端吐出量能转化出更多有效数据。** 这解释了为什么 ra=0 单客户端 BW 从 34→52（+51%）：不是后端吐得更多，是浪费得更少。

**每 op 吐出恒定 ~127 KiB（跨 ra、跨测试一致）**：
```
ra0-randread-r1：Σop_r_out_bytes 6797 MiB / Σop_r 54960 ops = 126.8 KiB/op
数据来源：op_r_out_bytes 与 op_r 字段（同 json），6 OSD 增量求和后相除
```
与 deepseek seqrand-osd-compare-final 的 126.7 KiB/op 独立吻合 → 服务端行为不随 ra 变化，放大差异全在客户端读多读少。

### 发现3：ra=4 与 default(2MiB) 完全一致 —— 中间值无效，只有全关有意义

**数据依据**：主表1 ra=4（3.31×/34.2）与 default（3.29×/34.3）几乎相同。印证 GLM 之前 sweep 的"中间值无差别"结论。→ readahead 只要开着（哪怕 2-4MiB），随机读多读就发生；要么全关（0），要么白搭。所以本次只测 0/4/default 三点是对的，不必全扫。

### 发现4：**ra=0 对验收口径 randrw 无改善，仍不达标** —— 最重要的负面结论

**数据依据**（主表2 + 逐轮，来源 `raX-randrw-rN-fio.txt` 的 read/write BW 行）：

| ra | randrw 总计（R+W 均值） |
|----|------------------------|
| 0 | 49.8（r1=29.9, r2=56.3, r3=63.2）|
| 4 | 49.7 |
| default | 50.7 |

- **三档 randrw 都在 49.7-50.7，都不达标（目标 59）。**
- ra=0 对纯随机读 +51%，**但对 randrw 无改善**（49.8 vs default 50.7，甚至略低）。
- ra=0 randrw 方差极大（r1 只有 29.9，r2/r3 才 56-63），不可靠。
- **randrw 的 IO depth≥64 仅 1.7%（ra=0），远低于纯 randread 的 35.6%** → 读写混合时并发严重受限，这是 randrw 上不去的直接表现。

**这坐实了之前的历史提示**：ra=0 是"救纯随机读/随机写，但救不了 randrw"。randrw ≠ 纯随机读，不能用纯读达标推断混合达标。

### 发现5：ra=0 让多客户端聚合从 51 突破到 76，超过 59（纯 randread 口径）

**数据依据**（主表3，来源 `stepB-multiclient/pN-{client}.txt`，每轮 3 客户端完成时刻相同=真并发）：
- 聚合 75.2 / 76.4 / 76.9，均值 76.2。
- 对比 default ra 的 51.3（deepseek）→ +49%。

**机制（用数据算后端总能力）**：
```
default ra：后端有效负载 = 聚合 51.3 × 放大 3.48 = 178.5 MiB/s
ra=0     ：后端有效负载 = 聚合 76.2 × 放大 2.17 = 165.3 MiB/s
```
两者后端总负载接近（~165-180 MiB/s）→ **后端总能力（网络+OSD）是物理瓶颈**。降低放大让更多后端带宽转化为有效数据：ra=0 理论聚合天花板 ≈ 170/2.17 ≈ 78，与实测 76 吻合。

---

## 四、残余 2.17× 放大是什么？（尚未锁定，标注为待查）

ra=0 已完全关预读（源码 `reader.go:714`，ra=0 时 readAheadMax=0，预读条件永不成立），但仍有 2.17× 后端放大。可能来源（**均为推论，无本次数据直接拆解**）：
- EC 4+2 的读取粒度 / 条带对齐：每 op 吐 ~127 KiB（≈256K/2），6 OSD 分摊；但 deepseek 已证副本池也 3.2×，所以 EC 不是主体 —— 那副本池在 ra=0 下残余放大是多少？**本次未测副本池 + ra=0 组合**，是缺口。
- JuiceFS chunk/block 读取粒度的固有开销。
- 需要后续实验拆解（如 ra=0 + 副本池、或 block-size sweep）。

> 注意：这 2.17× 与 deepseek 之前的 3.48× 不矛盾——deepseek 那次是 default ra（放大含预读部分），本次 ra=0 剥离了预读那约 1/3，剩 2.17×。

---

## 五、结论与建议

**数据已证明（可作结论）：**
1. readahead 贡献了随机读约 1/3 的放大（3.30→2.17×）；ra=0 使单客户端随机读 34→52、多客户端聚合 51→76（破 59）。
2. readahead 不增加 OSD 吐出量，只降低有效利用率（30%→46%）。
3. **ra=0 对验收口径 randrw 无改善，三档都卡在 ~50，不达标。** randrw 的并发（IO depth≥64）严重受限（1.7%）。
4. 残余 2.17× 放大非 readahead，来源待查。

**对验收的含义（关键）：**
- 验收口径是 **randrw**。**ra=0 解决不了 randrw** —— 这是本轮最重要的结论。纯随机读达标（多客户端 76）不等于 randrw 达标。
- 攻坚重心应转向 **randrw 为什么并发上不去（IO depth≥64 只有 1.7%）**：读写混合时，写操作是否阻塞了读、或 FUSE/JuiceFS 的读写调度串行化了在途请求。

**下一步建议：**
1. **多客户端 randrw**（本轮只测了多客户端 randread）：ra=0 或 default 下，3 客户端同时跑 randrw，看聚合能否达标。这是最贴近验收、且可能绕过单客户端 randrw 并发限制的方向。
2. **randrw 并发受限根因**：randrw 运行时采 JuiceFS 线程状态 / IO depth 时间序列，定位读写混合为何压不满队列。
3. （可选）ra=0 + 副本池，拆解残余 2.17× 是不是 EC。

---

## 六、文件与可追溯性

- 每个 BW → `*-fio.txt` 的 `Run status` / `read:`/`write:` 行。
- 每个后端放大 → `*-osd{0-5}-{before,after}.json` 的 `op_r_out_bytes`（randrw 另有 `op_w_in_bytes`）before/after 相减求和 ÷ fio io。
- NIC → `*-nic.txt`。多客户端 → `stepB-multiclient/pN-{client}.txt`。
- drop/mount 证据 → `test-script.log`、`mount-*.log`。
- opus 独立重算脚本（与 GLM analyze.py 结果一致）：
```python
import re
def get(fn,f):
    m=re.search(r'"%s":\s*([0-9]+)'%f, open(fn).read()); return int(m.group(1))
def io(fn):
    m=re.search(r'io=([0-9.]+)MiB', open(fn).read()); return float(m.group(1))
for ra in ['ra0','ra4','radefault']:
    for r in [1,2,3]:
        pre=f"{ra}-randread-r{r}"
        tot=sum(get(f"{pre}-osd{i}-after.json","op_r_out_bytes")-get(f"{pre}-osd{i}-before.json","op_r_out_bytes") for i in range(6))
        print(ra,r, round(tot/1048576/io(f"{pre}-fio.txt"),2),"x")
# ra0 -> 2.17x, ra4 -> 3.30x, radefault -> 3.29x
```
