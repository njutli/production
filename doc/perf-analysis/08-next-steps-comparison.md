# 08 下一步调优工作规划：三个对比方向（2026-06-15）

> 前序结论（见 `01`~`07`）：
> - 顺序/rados bench 已触顶 ~106 MB/s，是 Ceph/EC 软件栈天花板，**非硬件**
>   （内存盘验证：换比 SSD 快数量级的介质，吞吐不变）。
> - 随机读 3.8 是主战场；瓶颈**不在网络**（RTT 0.2ms，只占总延迟 0.2%），
>   **不在介质**（内存盘验证无改善），**不在元数据**（TiKV 延迟仅 1ms，换 Redis 无效），
>   在 **JuiceFS FUSE 处理 + RGW 对象 GET 延迟（每请求 ~100ms）**。
> - 框架内调优已挖尽（block-size / Redis / 缓存 / 多客户端均验证，见 `07`）。
>
> 目标仍是：**随机读、写带宽各达千兆网卡 50% ≈ 59 MB/s**。
>
> 本文只做**分析与规划**，不含具体测试操作。下一阶段聚焦三个"换方案/换配置"的对比。

---

## 不再考虑：Ceph RBD

RBD 随机性能虽好，但**块设备单客户端独占，不满足多客户端共享 POSIX 的业务要求**，
直接排除，不再测试。

---

## 方向一：CephFS vs JuiceFS（含 JuiceFS 官方调优实践）

### 现状对照（256k randrw，已测）

| 方案 | 随机读 | 随机写 |
|------|-------|-------|
| JuiceFS | 3.8 | **38** |
| CephFS | **13.9** | 13.8 |

- **CephFS 读优**（无 FUSE 税，内核态直连 RADOS，读 3.6×）；
- **JuiceFS 写优**（整对象写新 chunk，绕过 EC overwrite 的 RMW；CephFS 就地改写触发 RMW）。

### 要回答的问题

JuiceFS 既然被广泛使用，必有其设计取舍（面向**大文件/顺序/缓存复用/海量小文件元数据**
等场景）。当前随机读差，可能是**没用对配置**，而非框架天生不行。需对照
**JuiceFS 官方性能调优实践**逐项核对，看是否有未启用的优化：

- **缓存相关**：`--cache-size`、`--cache-dir`（多盘）、`--buffer-size`（读写缓冲）、
   `--prefetch`（预读并发）、`--readahead`、`--open-cache`。
   注意：`07` 已测"去掉 --direct=1 无变化"，但那是**单项**；官方推荐的是**组合配置**
   （如大 buffer + prefetch），且要确认验收口径是否允许缓存生效。
   另外 juicefs stats 已证实 TiKV 元数据仅 1ms，`--attr-cache`/`--entry-cache` 等元数据缓存
   不会改善本 workload（瓶颈在数据路径，不在元数据路径）。
- **并发相关**：`--max-uploads`、`--max-downloads`（对象并发上传/下载数）——
  随机读的 RGW GET 延迟 100ms，**提高 download 并发**可能在单客户端内并行更多 GET，
  突破"单进程串行发起"的限制。这是 `07` 多客户端有效背后的同一原理，但在**单客户端内**实现。
- **挂载/FUSE 相关**：`--max-readahead`、FUSE `writeback_cache`、`max_read` 等。
- **格式化相关**：trash、压缩（关闭以省 CPU）。

### 该方向的判定标准

- 若 JuiceFS 按官方调优后随机读能逼近/超过 CephFS（13.9）甚至达 59 → JuiceFS 可留；
- 若调优后仍远低于 CephFS → 说明 FUSE+S3 路径是硬伤，应认真考虑 CephFS。

### 方向一 具体优化工作计划（结合四份官方文档分析 + 已有结论）

> **执行次序（2026-06-15 调整）**：本方向**降为优先级 2**，在**方向三（去 RGW）之后**执行。
> 原因见"五、下一步工作总结"：RGW 若是随机读根因，客户端调优只是绕过而非消除瓶颈。
> 因此本方向的参数（`--max-downloads` / `--buffer-size` / `--prefetch` 等）应在
> **方向三确定的后端路径上**验证：
> - 若去 RGW 后走 RADOS → 这些并发/缓冲参数针对 librados 后端复测；
> - 若去 RGW 收益有限、仍走 RGW/S3 → 这些参数针对 S3 后端复测（此时本方向才是主攻）。
> 下文计划本身（参数、纪律、判定）两种路径通用，仅后端不同。
>
> 来源：`doc/juicefs-doc/` 四份分析（DeepSeek / GLM / GPT / qwen）。
> 已实测无效、不再重复的项（block-size、元数据换 Redis、介质/RAID/OSD/调度器、
> EC→副本、单纯加客户端）见本文末"不再尝试"清单，下表不再列入。

#### 核心判断：单客户端随机读的根因是"串行发起 GET"

`07` 已定量：单次 RGW object GET ≈ 100ms，随机读 IOPS 被钉死
（`1/0.1s × 256k ≈ 2.5 MB/s`，对上实测 3.8）。多客户端线性扩展有效，
证明**后端带宽富余、瓶颈是单客户端并发发起的 GET 数不足**。
因此方向一的主线是：**在单客户端内提高对象 GET/PUT 的并发与预读**，
把"多客户端才能达到的聚合并发"在一个挂载点内实现。这与 `07` 多客户端有效
是同一原理。所有缓存类手段（warmup / tmpfs cache / cache-partial-only）
因验收口径是 **randrw（写持续使缓存失效，命中率极低，`07` 已验证去 `--direct=1`
无变化 3.7 vs 3.8）**，列为**低优先级旁路验证**，仅在拆出的纯 `randread` 支线下评估。

#### 测试纪律（贯穿所有步骤）

- **三条线分别记录**：每个改动都跑 `randwrite / randread / randrw` 三个用例
  （bench 脚本步骤 8/10/9），避免混合结果掩盖读路径改进。主判据是 **randrw 随机读**。
- **单变量**：一次只改一组相关参数，跑完记 `results-table.md` 再叠加下一组。
- **干净环境**：每个随机用例已由 `fresh_volume`（destroy→验 bucket 空→format→mount）隔离。
- **采诊断**：跑 randread 时并行 `juicefs stats <mount>`，看 `object` GET 并发数与 FUSE 延迟，
  确认改动是否真的提高了 in-flight GET 数（而非只看 fio 带宽）。

#### 分步计划（按优先级，全部用规格 fio 参数）

| 步骤 | 改动（mount/format 参数） | 假设 / 依据 | 预期信号 | 来源 |
|------|--------------------------|------------|---------|------|
| **1.1** | `--max-downloads=200`（默认 200，先确认当前值，再上调到 512 / 1024） | 单客户端 GET 并发上限可能限制了 in-flight 请求数；提高后单进程可并行更多 100ms GET | randread 带宽随并发上调而升，`juicefs stats` 的 object 列并发数增大 | GPT #1 |
| **1.2** | `--buffer-size=2048`（默认 300MB→2GB） | 读缓冲不足会限制预读 block 的并发驻留；2GB≈512 个 4MB block 可同时在途 | 与 1.1 叠加后 randread 进一步上升；顺序读也应受益（官方 674→1418） | DeepSeek 文章1 |
| **1.3** | `--prefetch` 两端各测：`--prefetch=0`（关）与 `--prefetch=8/16`（加大） | 随机读下默认 prefetch=1 会对每个 256k 读放大整 4MB block（2-3×，qwen 定量）。**先测关闭**看是否去掉放大收益；若 randread 是"块内多次命中"则**加大**反而好。两端都测 | 关闭：底层 object 带宽下降但有效 IOPS 升 → 读放大是部分主因；加大无改善则确认放大非主因（与 block-size 无效一致） | DeepSeek 文章1 / qwen |
| **1.4** | 写侧 `--max-uploads`（默认 20→上调）+ 关压缩（format `--compress none`，确认已是）+ `--writeback` 仅用于"验收前台值"场景 | 随机写已 38 接近 59，提 upload 并发或可补到 59；writeback 只提前台值不代表后端真值，验收/真值两套挂载分别记录 | randwrite/randrw 写带宽升向 59；writeback 下前台明显升（标注"前台值"） | DeepSeek 文章3 |
| **1.5** | FUSE 侧：`--max-readahead`、挂载 `-o max_read` 调大；`--open-cache` 留意（元数据缓存对本 workload 无效，`07` 已证 TiKV 仅 1ms） | 增大 FUSE 单次读窗口，减少 FUSE 层往返次数 | randread 小幅提升；若无效则确认 FUSE 单次往返不是主因 | DeepSeek 文章1 |
| **1.6（旁路，缓存/warmup，三条线全测）** | warmup 预热 + tmpfs/大盘 `--cache-dir` + `--cache-partial-only` | 既然要量化预热缓存的影响，就**对 randwrite / randread / randrw 三条线都测**，分别看缓存对写、读、混合的作用，而非只测纯读。`07` 定量：纯随机读命中后 IOPS 可达 12000+（qwen 8→12000）；randrw 历史上命中率极低（去 `--direct=1` 仍 3.7 vs 3.8），预热后是否仍成立要实测验证 | 纯 randread 预热后大幅跳升；randrw 验证是否仍基本无变化（若确无变化→佐证缓存对验收口径无效；若有提升→需重估）；randwrite 看 writeback/缓存对写的贡献 | GLM 文章2/3 / GPT #2 / qwen |

> 注：所有"组合"以 1.1+1.2 为基线优先验证（单客户端并发是最贴合根因的杠杆），
> 1.3 在其上做加/减两端探测，1.4 单独管写侧，1.5 为补充。
> 1.6 是缓存/warmup 旁路，**对 randwrite/randread/randrw 三条线全测**
> （warmup 需在跑 randread/randrw 前对测试目录预热）。

#### 执行方式（落到 bench 脚本）

每组参数作为 `EXTRA_MOUNT_OPTS` 透传给 bench 脚本一次跑全量：

```bash
# 基线
bash tests/bench-juicefs.sh baseline

# 1.1 + 1.2：单客户端并发 + 大读缓冲
bash tests/bench-juicefs.sh maxdl512-buf2g \
    --max-downloads 512 --buffer-size 2048

# 1.3：在上一组基础上关预读
bash tests/bench-juicefs.sh maxdl512-buf2g-noprefetch \
    --max-downloads 512 --buffer-size 2048 --prefetch 0

# 1.4：写侧并发（format 期参数走 EXTRA_FORMAT_OPTS）
EXTRA_FORMAT_OPTS="--max-uploads 40 --compress none" \
    bash tests/bench-juicefs.sh maxul-tune

# 1.6 旁路（缓存/warmup，三条线全测）：WARMUP=1 在 randread/randrw 前预热且不清缓存
WARMUP=1 bash tests/bench-juicefs.sh memcache \
    --cache-dir /dev/shm/jfsCache --cache-size 10240 --cache-partial-only
```

> `--max-uploads`/`--compress` 属 **format** 期参数（不是 mount 参数），
> bench 脚本已支持经 `EXTRA_FORMAT_OPTS` 透传给 `do_format`。
> 验证前先确认 JuiceFS 版本对应参数名（`juicefs format --help` / `juicefs mount --help`）。
> 缓存/warmup 用 `WARMUP=1`（脚本在 randread/randrw 前 `juicefs warmup` 且不清缓存）。

#### 方向一收尾判定

1. 跑完 1.1~1.5 后看 **randrw 随机读**最佳值：
   - 逼近/超过 CephFS 13.9 → JuiceFS 配置确有红利，继续逼近 59；
   - 仍 ~3.8 量级无明显改善 → 单客户端 FUSE+S3 路径是硬伤，**转方向三（去 RGW 直连 RADOS）**，
     并把 CephFS 作为正式备选上报。
2. 缓存/warmup 旁路（1.6，三条线全测）：
   - 若纯 randread 预热后达数千 IOPS，且 randrw 也随之提升 → 缓存对验收口径有效，向上层确认
     **验收是否允许预热/缓存**；若允许，warmup 是达标捷径；
   - 若 randrw 预热后仍基本无变化（佐证 `07` 结论）→ 缓存对验收口径（冷读 randrw）无效，
     回到并发/去 RGW 主线。

#### 待甄别样本：一条"测出过提升"的历史挂载命令（记不清冷热，需重跑）

实际操作中曾用如下命令挂载，**当时随机读写都测出提升**：

```bash
juicefs mount -d tikv://127.0.0.1:2379/juicefs-prod /mnt/juicefs \
    --cache-dir /var/jfsCache --cache-size 102400 \
    --prefetch 1 --max-uploads 20 --writeback \
    --open-cache 10 --attr-cache 10
```

> ⚠️ **当时未隔离冷/热态（记不清测试在新卷冷读还是复用缓存下跑），故此"提升"不可直接采信，
> 需用现 bench 脚本（`fresh_volume` + `drop_caches`）重跑甄别。** 这正是后来给脚本加冷态隔离的原因。

**逐参数判断（对照 `07` 已有结论）**：

| 参数 | 相对规格挂载 | 对随机性能的实际作用 | 判断 |
|------|------------|--------------------|------|
| `--writeback` | 新增 | 写本地缓存即返回（毫秒级），异步上传 | **随机写提升的最可能来源**，但是**前台值≠后端真值**（`07`/DeepSeek 文章3 已明确） |
| `--cache-size 102400`（100GB）+ `--cache-dir` | 新增/增大 | 测试集若被缓存覆盖且重复访问则命中 | **随机读提升的最可能来源**，但 `07` 已证冷态 randrw 命中率极低（去 `--direct=1` 仍 3.7 vs 3.8）→ 提升大概率来自**热态命中**而非框架变快 |
| `--open-cache 10` / `--attr-cache 10` | 新增 | 元数据/文件句柄缓存 | **基本无贡献**：`07` 证 TiKV 元数据仅 1ms，非瓶颈 |
| `--prefetch 1` | = 默认值 | 预读并发 | 非提升来源（与默认相同） |
| `--max-uploads 20` | = 默认值 | 上传并发 | 非提升来源（与默认相同） |

**结论**：这条命令的提升**高度可疑是缓存命中（读）+ writeback 前台加速（写）的幻觉**，
而非 JuiceFS 框架本身在冷态/真值口径下变快。它对后续调优的价值在于——它是
**步骤 1.4（writeback）+ 1.6（大缓存/warmup）的真实诱因样本**，正好用来回答那个关键判定：
**验收口径到底允不允许缓存/writeback**。

**甄别方法（用 bench 脚本两种口径各跑一遍对照）**：

```bash
# A. 冷态真值：全新空卷 + 清缓存，不加 writeback（fresh_volume + drop_caches 已内置）
bash tests/bench-juicefs.sh cold-baseline

# B. 热态上限：复现历史命令（大 cache + writeback），WARMUP=1 预热后重复读
WARMUP=1 bash tests/bench-juicefs.sh warm-cache-writeback \
    --cache-dir /var/jfsCache --cache-size 102400 --writeback \
    --open-cache 10 --attr-cache 10
```

- **B − A 的差距 = 缓存/writeback 的贡献**，由此把"提升来自哪"钉死。
- 若验收允许热态/缓存 → B 路线（大 cache + warmup + writeback）可能是达标捷径，值得正式量化上报；
- 若验收是冷态真值 → 此提升作废，回到去 RGW（方向三）/ 单客户端并发（1.1~1.2）主线。

---

## 方向二：EC vs 副本

### 规格与现实的权衡

- 规格要求 **EC 4+2**（空间利用率 ≥60%）；
- 但**若副本能把随机/顺序性能调到接近硬件天花板，性能价值可能压过空间**。
- 合理表述：**EC 是"用时间换空间"**（利用率高 67%，但编码/分发开销带来性能下降）；
  **副本是"用空间换时间"**（利用率 33%，但写放大虽大、IO 路径更简单）。

### 现状对照（已测，rados bench）

| 池类型 | 介质 | 写带宽 | 写放大 |
|--------|------|-------|-------|
| EC 4+2 | SSD | 102 | ×1.5 |
| 副本 size=3 | SSD | 86 | ×3 |
| EC 4+2 | 内存盘 | 106 | ×1.5 |
| 副本 size=3 | 内存盘 | 88.5 | ×3 |

- **顺序/rados bench 场景：副本反而比 EC 慢**（写放大 3×>1.5×，JuiceFS 无 RMW）。

### 但随机场景尚未对比 —— 这是本方向要补的

- CephFS 上 **EC 触发 overwrite RMW**（就地改写要读回旧条带），这是 CephFS 随机写差（13.8）的原因；
- **副本没有 RMW**（整块覆盖），CephFS + 副本池的**随机写**可能明显优于 EC。
- 因此要测：**CephFS + 副本池** 的随机读写，对比 CephFS + EC 池（13.9/13.8）。

### 该方向的判定标准

- 若副本在随机场景能逼近硬件天花板（且读写均衡）→ 可作为"放宽规格换性能"的备选方案上报；
- 若副本随机仍受 Ceph 软件栈限制、收益有限 → 坚持 EC（规格 + 顺序已证 EC 更优）。

### 测试落地

本方向测的是 **CephFS（内核态 `mount -t ceph`），不是 JuiceFS 挂载**，不在 bench-juicefs.sh 职责内。
需**另写 `tests/bench-cephfs.sh`**（待建）：复用同一套规格 fio 与冷态隔离逻辑，挂载改 CephFS，
并支持 **EC 池 / 副本池**两种数据池切换，分别跑 randwrite/randread/randrw 三条线对比。

---

## 方向三：是否使用 RGW

> **执行次序（2026-06-15 调整）：本方向升为优先级 1，最先执行。**
> 它直接验证 `07` 的根因假设（RGW object GET ~100ms 是随机读主因）。
> 这是判断"后续 JuiceFS 客户端调优（方向一）是否值得做"的前提——
> 若不先除掉/排除 RGW 这个嫌疑最大的瓶颈，其它客户端侧优化都只是绕过它、收益受其钉死。
> 衔接逻辑见"五、下一步工作总结"。

### 背景

- 当初用 RGW（S3 网关）是**有意为之**：为兼容其他终端（标准 S3 协议接入），
  且当时判断 RGW 不会成为瓶颈。
- 但 `07` 诊断显示：随机读的 100ms+ 延迟主要在 **RGW 对象 GET 处理**
  （HTTP 解析 → 定位 EC 对象 → 取分片重组）。RGW 这一层的嫌疑变大。

### 要回答的问题

去掉 RGW，让 **JuiceFS 直连 RADOS（librados 后端）**，少一层 HTTP/RGW 往返，
随机读延迟能降多少？对比：

| 路径 | 随机读 | 随机写 | 说明 |
|------|-------|-------|------|
| JuiceFS → RGW(S3) → RADOS（现状） | 3.8 | 38 | 多一层 HTTP/RGW |
| JuiceFS → RADOS（librados 直连） | 待测 | 待测 | 少一层，延迟应降 |

### 该方向的判定标准与权衡

- 若直连 RADOS 随机读明显提升 → 说明 RGW 是随机读延迟的主因之一；
- **但要权衡**：去掉 RGW 就**失去 S3 协议兼容**（其他终端无法标准 S3 接入）。
  需结合业务：是否真有"其他终端走 S3"的需求？若没有，去 RGW 是净收益；若有，
  则要么保留 RGW、要么用其他方式提供 S3（如另起 RGW 仅供外部，JuiceFS 走 RADOS）。

---

## 方向四（后端并行支线）：BlueStore 调参

> 来源：qwen 分析 + `results-table.md` 末两项未勾选待办
> （`RAID 改 JBOD/HBA 直通`、`BlueStore 调参后的带宽`）。
> 参考文章：**手把手教你搭建 Ceph 集群、对接 JuiceFS**
> （https://juicefs.com/zh-cn/blog/usage-tips/ceph-juicefs ，JuiceFS 官方唯一 Ceph 对接专文）。

### 定位：与方向一/二/三正交的后端支线

方向一/三调的是 **JuiceFS 客户端与访问链路**，方向二调的是**冗余方式**，
而 BlueStore 调参动的是 **Ceph OSD 数据落盘引擎本身**——属后端软件栈，
与上述三方向正交，可并行推进。它是 `results-table.md` 中**最后两项未实测**的待办之一。

### 依据与已排除项

`06` 结论：裸盘 SSD 顺序写 ~178 MB/s，经 Ceph EC 后只剩 ~102 MB/s（效率 57%），
43% 损耗在 **RAID 卡 + EC 编码 + Ceph/BlueStore 软件栈**。此前已排除介质/硬件假设：

| 已排除假设 | 验证手段 | 结论 |
|-----------|---------|------|
| WAL/DB 介质不够快 | WAL/DB 放内存盘 | +4.8%，无效 |
| 整块盘（RAID+SSD）不够快 | 全内存盘集群 | +0.2%，无效 |
| OSD 并发不够 | 6→12 OSD | 无变化 |
| PG 并行不够 | pg_num 32→128 | 无变化 |

> 即"介质快慢/并发数/PG 数"均非瓶颈。**唯一未动过的是 BlueStore 引擎参数本身**
> （分配粒度、blob 大小、延迟写阈值、op 分片线程）。这也是为何把它列为"值得最后一试"
> 而非高优先级——前述同类后端调整大多无效，预期收益存疑，但因是未勾选待办，需明确测一次以闭环。

### 候选参数与调优思路

| 参数 | 当前 | 调优思路 | 风险 |
|------|------|---------|------|
| `bluestore_min_alloc_size`（_ssd） | SSD 默认 4K/16K | 调大向 JuiceFS 4MB block 对齐，减少小 IO 碎片与元数据开销 | **需重建 OSD 才生效**（非热生效）；调过大浪费空间 |
| `bluestore_max_blob_size`（_ssd） | 默认 | 增大减少 IO 拆分 | 热生效，但过大增大单次读放大 |
| `bluestore_prefer_deferred_size`（_ssd） | 默认 | 控制小 IO 走延迟写（先 WAL 后落盘）的阈值，可能改善随机小写路径 | 调大增加 WAL 压力 |
| `osd_op_num_shards` / `osd_op_num_threads_per_shard` | Tier 3 调过 | 复测 op 分片/线程并发，结合上面参数 | 与 CPU 核数相关，过高反致竞争 |
| `bluestore_cache_size`（_ssd） | Tier 3 设 1GB | 可增大，但 `06_1` 已证介质非瓶颈，**效果存疑** | 占用内存 |

### 具体操作

```bash
# 1. 先查当前值（admin 节点 ceph-node1 192.168.11.11）
ssh turboai@192.168.11.11 "sudo cephadm shell -- ceph config dump" | grep -i blue
ssh turboai@192.168.11.11 "sudo cephadm shell -- ceph config show osd.0" | grep -i bluestore

# 2. 调参（集群级，对所有 OSD 生效）—— 单变量，一次一组
sudo cephadm shell -- ceph config set osd bluestore_max_blob_size_ssd 524288     # 512K，热生效，先测
# sudo cephadm shell -- ceph config set osd bluestore_min_alloc_size_ssd 65536   # 64K，需重建 OSD，最后测

# 3. 需重建才生效的参数：逐 OSD 重启（或重建），注意等 HEALTH_OK 再动下一个
for i in 0 1 2 3 4 5; do
    sudo cephadm shell -- ceph orch daemon restart osd.$i
    sleep 15
done

# 4. 先测后端裸能力（隔离 JuiceFS），再跑 bench 三条线
sudo cephadm shell -- rados bench -p default.rgw.buckets.data 60 write --no-cleanup
sudo cephadm shell -- rados bench -p default.rgw.buckets.data 60 rand
bash tests/bench-juicefs.sh bluestore-blob512k
```

### 测试纪律与判定

- **先 rados bench 再 bench 脚本**：BlueStore 改的是后端,先用 rados bench 看后端裸值是否动,
  再看是否传导到 JuiceFS 随机读写。后端没动则不必跑上层。
- **单变量**：`max_blob_size`（热生效）先测；`min_alloc_size`（需重建 OSD）最后测，且测前 `results-table.md` 记好基线。
- **判定**：
  - 若某参数使 rados bench 顺序/随机后端值明显上升 → 传导到 JuiceFS 看是否逼近 59,记入 results-table；
  - 若后端值不动（与 WAL/DB、内存盘、OSD 数同样无效）→ 确认 **EC 编码本身**是软件栈天花板,
    BlueStore 调参对本场景无解,勾掉待办、归入"不再尝试"。
- **RAID 改 JBOD/HBA 直通**（同为未勾选待办）：风险高（需重做阵列、重建全部 OSD、有丢数据风险），
  仅在 BlueStore 调参确认无效、且其他三方向均不达标时才作为最后手段评估，**不轻易动**。

---

## 五、下一步工作总结（优先级）

| 优先级 | 方向 | 核心问题 | 判定 |
|-------|------|---------|------|
| **1** | **去 RGW 直连 RADOS**（方向三） | RGW 是不是随机读 100ms 延迟的**根因** | 直连后随机读提升多少；权衡 S3 兼容 |
| 2 | **JuiceFS 客户端调优**（方向一） | 在确定的后端路径上，是否没用对配置？并发/缓冲/prefetch 组合 | 调优后随机读能否逼近 CephFS/59 |
| 3 | **CephFS + 副本池随机对比**（方向二） | 副本避开 RMW，随机能否接近天花板 | 性能 vs 规格（空间换时间）的取舍 |
| 并行支线 | **BlueStore 调参**（方向四） | EC 软件栈天花板里 BlueStore 引擎参数是否还有余地 | 后端 rados bench 是否动；是 results-table 末项待办闭环 |

> **顺序调整说明（2026-06-15）**：原计划先做 JuiceFS 客户端调优，现**改为先做去 RGW**。
> 理由：`07` 诊断把随机读 ~100ms 主要归到 **RGW object GET**。若 RGW 确是根因，
> 那么客户端侧的并发/缓冲/prefetch 调优只是在**绕过**瓶颈而非**消除**它，收益天花板被 RGW 钉死。
> 因此先用"去 RGW 直连 RADOS"一刀验证根因假设——这是**判断后续所有客户端调优是否值得做**的前提：
>
> - **若直连 RADOS 随机读明显提升** → 证实 RGW 是主因。后续的 JuiceFS 客户端调优（方向一）
>   就在**已去掉 RGW 的 RADOS 路径上**进行（并发/缓冲针对 librados 而非 S3），再逼近 59。
> - **若直连 RADOS 提升有限** → RGW 不是主因，瓶颈在 JuiceFS FUSE/单客户端串行本身，
>   此时再回头做方向一的客户端并发调优（此路径下它才是主攻），并把 CephFS 作正式备选上报。
>
> 方向二在"冗余方式对随机的影响"，涉及规格取舍，放最后。
> 方向四（BlueStore）是**后端并行支线**，与上述三方向正交、可穿插进行，
> 优先级低（前述同类后端调整多无效，但属未勾选待办，需测一次闭环）。

## 六、各方向如何用 bench-juicefs.sh 测（能力边界）

> bench 脚本已改造（2026-06-15），通过 **环境变量 + mount 透传参数** 覆盖 JuiceFS 一侧的全部用例。
> 非 JuiceFS 一侧（CephFS、Ceph 后端）不属本脚本职责，单列说明。

### 脚本新增能力

| 入口 | 作用 | 对应方向 |
|------|------|---------|
| `STORAGE=s3\|ceph`（默认 s3） | s3 走 RGW；**ceph=去 RGW 直连 RADOS**（`do_format` 自动切 `--storage ceph --bucket ceph://<pool>`，跳过 bucket/AK/SK/bucket 校验） | **方向三** |
| `CEPH_POOL=<pool>`（默认 `default.rgw.buckets.data`） | RADOS 数据池名；兼容旧名 `RADOS_POOL` | 方向三 |
| `EXTRA_FORMAT_OPTS="..."` | 透传给 `juicefs format` 的参数（如 `--max-uploads 40 --compress none`） | **1.4** |
| `[extra_mount_opts...]`（位置参数） | 透传给 `juicefs mount` 的参数（`--max-downloads/--buffer-size/--prefetch/--cache-*` 等） | **1.1/1.2/1.3/1.5/1.6** |
| `WARMUP=1` | randread/randrw 前 `juicefs warmup` 预热且**不清缓存**（热态/缓存口径）；默认 `WARMUP=0` 为冷态清缓存真值口径 | **1.6**、历史命令甄别 |

### 各方向/步骤的可测性对照

| 方向/步骤 | 能否用 bench 脚本 | 怎么跑 |
|----------|-----------------|--------|
| 1.1 max-downloads | ✅ 直测 | `bash tests/bench-juicefs.sh maxdl512 --max-downloads 512` |
| 1.2 buffer-size | ✅ 直测 | `... --buffer-size 2048` |
| 1.3 prefetch | ✅ 直测 | `... --prefetch 0` / `--prefetch 16` |
| 1.4 max-uploads / compress | ✅ 直测（已加 format 透传） | `EXTRA_FORMAT_OPTS="--max-uploads 40 --compress none" bash tests/bench-juicefs.sh ...` |
| 1.5 max-readahead 等 mount 参数 | ✅ 直测 | `... --max-readahead 16777216` |
| 1.6 缓存/warmup（三线全测） | ✅ 直测（已加 WARMUP） | 冷：`bash tests/bench-juicefs.sh cold ...`；热：`WARMUP=1 bash tests/bench-juicefs.sh warm --cache-size 102400` |
| 历史命令甄别（冷态A / 热态B） | ✅ 直测 | A：默认冷态；B：`WARMUP=1 ... --cache-size 102400 --writeback` |
| **方向三 去 RGW 直连 RADOS** | ✅ 直测（已加 STORAGE=ceph） | `STORAGE=ceph bash tests/bench-juicefs.sh norgw` |
| **方向二 CephFS EC vs 副本** | ❌ 不属本脚本 | 是 **CephFS**（内核态，非 JuiceFS 挂载）+ Ceph 池切换；**另写 `tests/bench-cephfs.sh`**（待建） |
| **方向四 BlueStore 调参** | ➖ 后端先调，再用本脚本看传导 | 在 Ceph 侧 `ceph config set` + `rados bench`（见方向四"具体操作"）；调完后照常 `bash tests/bench-juicefs.sh bluestore-xxx` 看是否传导到 JuiceFS |

> 结论：**JuiceFS 一侧（方向一全部 + 方向三）现在都能用 bench-juicefs.sh 一条命令跑全量三条线**；
> **方向二 CephFS** 需另起 `tests/bench-cephfs.sh`（同样的规格 fio + 冷态隔离，挂载换成 `mount -t ceph`，
> 并增加 EC/副本两种池的切换）；**方向四** 的调参动作在 Ceph 后端，本脚本只承担"看传导"的下游验证。

### 不再尝试（已排除）

- ❌ Ceph RBD（不满足多客户端共享）
- ❌ 硬件/介质/RAID/OSD 数/调度器（内存盘已证非瓶颈）
- ❌ 元数据换 Redis（TiKV 延迟仅 1ms，非瓶颈）
- ❌ JuiceFS block-size 调整（已测无效）
- ❌ 单纯加客户端（治标，读基数太低，线性外推需 ~22 客户端不现实）
