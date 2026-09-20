# randrw 与 randread 架构机制问答记录（06 阶段配套）

> 文档类型：架构机制问答 + 机制报告（内部存档）
> 日期：2026-09-18
> 会话性质：用户提问 / opencode 基于源码与归档证据作答；**含多处对本会话早期错误结论的撤销**
> 源码基线：`/tmp/opencode`，母本 `/mnt/c/SunRise/test/06-2/20260916-091446/build/juicefs-v1.4.1-b-catchup-source.tar.gz`
> 　　　　　SHA256 `a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451`（与 06-2 归档记录相符）
> 　　　　　**版本 1.4.1**（`pkg/version/version.go:30--32` = 1/4/1），对应测试二进制 `exe_md5 = 24fae0852051c80ca571cb2f20275d46`
> 归档证据：`/mnt/c/SunRise/test/06-3/20260916-161945/{analysis.json,raw.tar.gz}`
> 关联文档：
> - 权威现状：`doc/perf-analysis/06-STAGE-STATUS-20260917.md`（C-1～C-13、M-1～M-40、R-1～R-16）
> - ⚠️ 既有同主题文档：`doc/juicefs-slice-chunk-block-read-flow-analysis-20260918.md`
>   　该文基于 `/home/lilingfeng/project/juicefs` = **1.3.1**（`version.go` = 1/3/1），且其中 `block-size 默认 4M`
>   　与本卷实际 `BlockSize=256 KiB` 不同。**本文以 1.4.1 冻结源码为准；两文冲突处以本文为准。**
>   　建议后续为该文补版本批注（已登记为 R-17）。

---

## §0 本轮决策记录

### 0.1 关于去掉 `--direct=1`（用户定案）

**用户判断（采纳）**：去掉 `--direct=1` 测试没问题。理由是我们已经分析出 JuiceFS 的设计思路就是依赖 page cache 缓存小 IO、避免频繁 flush，因此：

- ⛔ **不与 06 阶段历史值做纵向对比**（历史十格全部 `direct=1`，不可比）；
- ✅ **只与竞品做横向对比**（竞品脚本同样不设 `direct=0`/`direct=1` 差异时按同口径重跑即可）。

这撤销了我上一轮"建议别去掉 `--direct=1`"的结论中**关于是否值得测**的部分。我上一轮的技术分析（数据集 128 GiB ≪ 宿主内存 ≥750 GiB ⇒ 会整集驻留 page cache）**仍然成立且必须写进任务书作为口径声明**，但它不构成"不要测"的理由 —— 它构成"**测出来的数不是介质性能，而是 page cache 命中下的端到端性能，且必须与竞品同口径对照才有意义**"这一口径限定。

**据此形成的口径要求（须写入未来任务书）：**

| 项 | 要求 |
|---|---|
| 对比方式 | **仅横向对竞品**；⛔ 不得与 06-1/06-3 任何格位比较，⛔ 不得计入 06 阶段 ABBA/漂移体系 |
| 口径标注 | 结果须标注「缓冲 I/O（`direct=0`），数据集 128 GiB < 宿主内存，含宿主 page cache 命中」 |
| 双方对等 | 竞品侧必须用**同一 fio 几何 + 同样 `direct=0`**，且**必须记录竞品客户端 MemTotal**（否则重犯 05-2 D4 的错误） |
| 编号 | 应作为独立任务（建议 06-4 或新阶段），⛔ 不改 06-1/06-2/06-2b/06-3 编号 |

### 0.2 本轮产生的撤销与新增（详见 §5）

- **撤销 5 项**（全部是我在本会话早期给出的错误论断）
- **新增 3 条结论 C-15/C-16/C-17 + 4 条机制 M-41～M-44**
- **更正既有 C-5 的一处证据口径**（`600--706 MiB/s` 是含空闲的整窗均值，活跃期中位为 `1607 MiB/s`）

---

## §1 报告：randrw 与 randread 的架构原理，及缓存扩容为何只对 randread 有效

### 1.1 摘要

randread 的缓存收益是**一阶**的：命中率每涨 1pp，带宽近似同比例涨。randrw 的缓存收益是**二阶**的：实测转化率仅 **0.317 %带宽/pp命中**（04-tmp2j：命中 `+15.86pp` → 带宽 `+5.02pp`）。而 06 阶段两轮筛选的噪声门分别是 `M=14.17%`（06-1）与 `M=47.16%`（06-3），**比缓存能兑现的效应量大 3.3 倍和 11 倍 ⇒ 测不出来是架构决定的必然，不是实验失败**。

根因是 randrw 有**四处结构性阻断**（原报告为三处，本轮新增第四处并修正第三处的证据）。

### 1.2 randread：一阶路径，无耦合

```
read(2) → FUSE READ → vfs.Read → fileReader.Read → sliceReader.run
        → meta.Read（取 slice 列表）→ dataReader.readSlice
        → rSlice.ReadAt → bcache.load(key)  ── 命中，结束
                        └ 未命中 → GET 对象存储 → 回填缓存
```

关键性质：

- **没有写，所以 `vfs.go:789 v.writer.Flush(ctx, ino)` 是空操作** —— `writer.go:558` 的 `w.find(inode)` 返回 nil 直接 `return 0`；
- slice 列表在 `openfiles` 里缓存后**不会因写而失效**（无写 ⇒ 无 `InvalidateChunk`），元数据往返趋近于零；
- **不产生任何新 block** ⇒ 缓存内容单调收敛到热集；
- 每个 read 的成本 = `bcache.load` 或一次 GET。

⇒ 传递函数近似恒等：命中率 ↑ ⇒ 平均延迟 ↓ ⇒ 固定 QD 下带宽 ↑。**加大 `--cache-size` 直接变成带宽。**

### 1.3 randrw：四处结构性阻断

#### 阻断一：`rwmixread=50` 把读带宽与写带宽锁成 1:1

十格实测 `read_bw` 与 `write_bw` 差异全部 `<0.3%` ⇒ 二者被硬锁定。后果：

- 缓存只能加速**读的那一半**；
- 更致命的是**读带宽不可能超过写带宽**，读侧因命中腾出的富余能力没有出口。

**这是一阶通道被封死的直接原因。** randread 无此约束。

#### 阻断二：M1 —— 每个读都被写的 flush 串行化

`pkg/vfs/vfs.go:789`，就在 `reader.Read` 前一行，无条件执行：

```go
_ = v.writer.Flush(ctx, ino)
n, err = h.reader.Read(ctx, off, buf)
```

`flush` 的粒度是**整个 inode 的全部 chunk 的全部 slice**（`writer.go:393--420`），不是被读的那个 range。本几何下单文件约 64 个未完成写。

⇒ randrw 中读的延迟 = **flush 等待 + 缓存读**（串行相加，见 §4 Q2 —— 我早前写成 `max` 是错的）。缓存把第二项压到近零，第一项完全不动 ⇒ 总延迟几乎不变。

这是 `range-flush.patch` / 06-2b 的全部动机。

#### 阻断三（★ 本轮修正证据）：缓存盘在活跃期已经饱和

**我原先引用的证据是错的**：`600--706 MiB/s` 与 `%util 峰 100.40%`。用户指出两点批评，**都成立**：

1. 600 MiB/s 远未达 NVMe 带宽上限；
2. `%util` 对多队列 NVMe 无意义（它只表示"至少有一个未完成 IO 的时间占比"，不表示压力）。

**但改用正确指标后，结论反而被更强地证实。** 从 `raw.tar.gz` 内 `cells/*/iostat-1hz.tsv` 重算，条件为「活跃样本 = `wkB/s > 100 MiB/s`」：

| 格 | 活跃样本 | 活跃写中位 | `w_await` 中位 | `w_await` p95 | `aqu-sz` 中位 | `%util` 中位 | `rkB/s` 最大 |
|---|---|---|---|---|---|---|---|
| S1 | 152/312 | **1608.3 MiB/s** | **49.04 ms** | 53.82 ms | **317.6** | 100.00 | **0.00** |
| W1 | 170/324 | **1606.8 MiB/s** | **50.06 ms** | 54.33 ms | **331.9** | 100.00 | **0.00** |
| C1 | — | ≈0（`wkB/s` 均值 3.27 kB/s） | 0.10 ms | 0.00 | 0.00 | 0.01 | 0.00 |

- **原先的 `600--624 MiB/s` 是含空闲期的整窗均值**（S1 整窗均值 622.5 MiB/s）；活跃期实际是 **1608 MiB/s，接近 2.6 倍**。
- **`w_await` 中位 49--50 ms、`aqu-sz` 中位 318--332** —— 这是一个**确凿饱和**的设备，不是轻载。
- 小李定律自校验：`6297 IO/s × 0.049 s = 308` ≈ `aqu-sz 318` ✓ 内部自洽。
- `rkB/s` 全程 `0.00` ⇒ **C-5「介质读为零、命中全部由宿主 page cache 供给」再次确证**。
- C1 对照 ≈0 ⇒ **臂身份由该盘自身计数证实**（符合指导书 §23 硬门①）。

⇒ **阻断三成立，但须换证据**：不是"带宽低"，而是"**活跃期 1.6 GiB/s + 50 ms 写延迟 + 队列深 330 = 缓存盘已饱和**"。

#### 阻断四（★ 本轮全新）：缓存准入被大量丢弃 + 缓存整体抖动 + 新块洪流超过缓存容量

这是本轮最重要的发现，三项互相咬合，**且证据早已在 `analysis.json` 里、06-3 报告从未使用**。

**(a) 准入丢弃**：`analysis.json` 的 `mechanism.counter_deltas` 已含正式窗 `cache_drops`：

| 格 | `cache_drops` | `cache_writes` | **丢弃率** | `cache_evicts` | `evicts/writes` | 命中率 | `put_count` | 新块量 |
|---|---|---|---|---|---|---|---|---|
| C1 | 0 | 0 | — | 0 | — | 0.00% | 602,038 | 147.0 GiB |
| **S1** | **302,759** | 541,667 | **35.85%** | 425,898 | **79%** | 45.25% | 544,032 | 132.8 GiB |
| **W1** | 50,788 | 691,859 | **6.84%** | 600,137 | **87%** | 44.71% | 476,903 | 116.4 GiB |
| **W2** | 51,116 | 673,455 | 7.05% | 580,773 | 86% | 44.69% | 465,021 | 113.5 GiB |
| **S2** | **239,562** | 528,632 | **31.19%** | 425,898 | **81%** | 42.38% | 485,932 | 118.6 GiB |
| C2 | 0 | 0 | — | 0 | — | 0.00% | 487,968 | 119.1 GiB |

命中率复算 `hits/(hits+miss)` 得 `45.25/44.71/44.69/42.38%`，与 06-3 报告记录的 `45.26/44.71/44.69/42.38%` 相符 ⇒ **公式与窗口口径确认无误**，因此同一份 `counter_deltas` 里的 drops/evicts 同样可信。

**丢弃的根因（源码注释直接写明）** —— `pkg/chunk/disk_cache.go:465--479`：

```go
select {
case cache.pending <- pendingFile{key, p, dropCache}:
default:
    if force { ... } else {
        // does not have enough bandwidth to write it into disk, discard it
        logger.Debugf("Caching queue is full (%s), drop %s (%d bytes)", cache.dir, key, len(p.Data))
        cache.m.cacheDrops.Add(1)     // :475
```

另一处 `cacheDrops` 增量在 `:450`，条件是 `cache.rawFull && cache.keys.name() == EvictionNone`；06-3 用 `--free-space-ratio 0.20` 且剩余 >88%、淘汰策略非 none ⇒ `:450` 不可能触发 ⇒ **S1 的 302,759 次丢弃全部来自 `:475`，即缓存盘带宽不足**。这与阻断三的 iostat 结论是同一笔账。

**队列有多小？** `pkg/chunk/cached_store.go:1172`：

```go
pendingPages := int(config.BufferSize) * 2 / 10 / config.BlockSize / len(dirs)
```

`--buffer-size 300`（`cmd/mount.go:391` 按 MiB 解析）、`BlockSize = 256 KiB`、`len(dirs) = 1`：

```
pendingPages = 314572800 * 2 / 10 / 262144 / 1 = 240 块 = 60 MiB
```

按活跃期 `w/s` 中位 6297 块/s 计算，**240 个槽位只够缓冲 38 ms**，而 `w_await` 中位就是 49 ms ⇒ **队列必然溢出，丢弃是结构性的**。

**(b) W 臂丢弃率只有 S 臂的 1/5 —— 因为 `--writeback` 绕过了可丢弃队列**

| 臂 | 准入通道 | 是否可丢弃 | 实测丢弃率 |
|---|---|---|---|
| S（CLW，无 WB） | `cached_store.go:368` → `bcache.cache()` → `pending` channel（`force=false`） | **可丢弃** | 31--36% |
| W（CLW + WB） | `disk_cache.go:801 os.Link(stagingPath, path)` 同步硬链接 | **不经队列，不丢弃** | 6.8--7.1% |

⇒ **这是 `--writeback` 优于 `--cache-large-write` 的一条全新机制**，此前未识别。它把 C-7 的「CLW 在 W 臂冗余」加强为：**CLW 的准入通道会丢掉三分之一，WB 的准入通道（硬链接）一个不丢。**

**(c) 新块洪流 > 缓存容量 ⇒ 缓存不可能收敛**

06-3 S/W 臂 `--cache-size 98304` MiB = **96 GiB**（已从归档 `commands.sh` 核对：`cache-size 98304` × 4 格、`cache-size 0` × C 臂）。而：

- S1 单格 180 s 内 `put_count = 544,032` 个**全新 block** = **132.8 GiB**；
- **单格产生的新块量（132.8 GiB）> 整个缓存容量（96 GiB）** ⇒ 缓存在一格之内就被整体翻转一遍以上；
- 实测 `evicts/writes = 79--87%` ⇒ 写进去的绝大部分在同一窗口内就被淘汰出去 —— **纯抖动**。

**这是 COW 的直接后果**：randrw 每次覆盖写都生成**新 slice、新 block、新对象名**，旧 block 虽然物理上还在缓存里，却因为在 `buildSlice` 里被新 slice 覆盖而**再也不会被读到**（逻辑死亡但仍占额度）。

⇒ **randread 的缓存会收敛到热集；randrw 的缓存被自己制造的新块洪流冲走。这是"加大 `--cache-size` 对 randrw 无效"最根本的架构原因。**

### 1.4 定量对照

| | randread | randrw（`rwmixread=50`） |
|---|---|---|
| 读是否等写 | 不等（Flush 空操作） | **每个读等整 inode flush**（`vfs.go:789`），串行相加 |
| slice 列表缓存 | 长期有效 | **每次 Write 失效**（`base.go:2168 InvalidateChunk`） |
| 读带宽上限 | 无内部耦合 | **≤ 写带宽**（比例锁定） |
| 缓存盘负载 | 仅读回填 | **活跃 1.6 GiB/s、`w_await` 50 ms、`aqu-sz` 330（饱和）** |
| 缓存准入 | 不丢弃（无写准入） | **S 臂丢弃 31--36%**；W 臂 7% |
| 新块生成 | **0** | **单格 113--133 GiB > 缓存 96 GiB** |
| 缓存稳定性 | 收敛到热集 | **抖动，`evicts/writes` 79--87%** |
| 命中→带宽传递 | 一阶，≈1 | **二阶，0.317 %/pp** |

**randrw 唯一的收益通道（二阶，已在 06-1 观测到）：**

```
读命中↑ → GET 流量↓（04-tmp2j RX 1975→1150 MiB/s）
        → 6 个 OSD 腾出能力给 PUT
        → PUT 时延↓（06-1 固定 150 槽：C1 7232 PUT/s = 20.7 ms → T1 8647 PUT/s = 17.3 ms，−16.4%）
        → 写带宽↑ → 读带宽被比例锁定跟着↑
```

自洽性检查：`1 / 0.836 = 1.196` vs 实测活跃写 `+19.56%` —— 吻合。

### 1.5 结论

1. **randread 加缓存有效**：一阶、无耦合、无额外成本、缓存收敛。
2. **randrw 加缓存难有效**：一阶通道被比例锁定封死；读被 M1 串行化；缓存盘活跃期已饱和；准入被丢弃 1/3；且**新块洪流单格就超过缓存容量导致纯抖动**。只剩一条二阶通道，传递率 0.317 %/pp。
3. ⇒ **06 阶段两轮筛选测不出缓存效应是架构决定的。**
4. ⇒ randrw 上值得做的**不是继续加 `--cache-size`**，而是：
   - **打掉阻断二**（M1 的 inode 级 flush 粒度）—— 即 06-2b range-flush，唯一不受比例锁定限制的方向；
   - **打掉阻断四(a)**（准入丢弃）—— **提高 `--buffer-size` 以放大 `pendingPages`**，单参数改动，见 §5 M-44。

---

## §2 前序问答（写序与耐久性、本地源码）

### 2.1 读写缓存只缓存数据，还是也缓存元数据？

**分开的两套机制**：读写缓存（`--cache-dir`/`--cache-size`）只缓存数据；元数据缓存是独立的、纯内存。

| 层 | 缓存什么 | 位置 | 源码 |
|---|---|---|---|
| 磁盘缓存 | 数据块 `raw/<key>` + WB 暂存 `rawstaging/<key>` | `--cache-dir` 磁盘 | `disk_cache.go:51--52` |
| 读缓冲 | 数据（预读/写缓冲） | 内存 `--buffer-size` | — |
| 内核元数据缓存 | attr / entry / dir-entry / negative-entry / readdir | 内核 | `cmd/mount_unix.go:1118--1122` |
| 客户端 openfiles | `attr` + `chunks map[uint32][]Slice`（slice 列表） | 客户端内存 | `pkg/meta/openfile.go:19--25` |

要点：`--cache-size` 一个字节都不用于元数据；写路径的 slice 提交必须同步等元数据引擎返回，不可缓存。

**对 06 阶段的含义**：C-12 的元数据通道利用率（T 臂 52--57%）**无法靠调 `--cache-size` 或 CLW/WB 缓解** —— 那三个开关只作用于数据面。

### 2.2 开 `--writeback` 后元数据先于数据落地，会不会数据/元数据不一致？

**用户的质疑成立。答案取决于是否开 `--writeback`，两种模式顺序正好相反。**

**默认模式：数据先落，元数据后提交**（与 ext4 ordered 一致）

- `writer.go:127--135 flushData()`：先 `s.writer.Finish(int(s.length))`，`defer s.markDone()`
- `writer.go:201 commitThread()`：`for !s.done { ... }` 必须等到 done
- `writer.go:215`：才 `m.Write(...)` 提交元数据
- `Finish()` 在非 WB 下等真正的 PUT：`cached_store.go:467 s.errors <- s.store.upload(...)`，`Finish` 在 `:507 <-s.errors` 阻塞

官方文档原话（`docs/en/guide/cache.md:185`）："the default **upload first, then commit** write process"。

**开 `--writeback`：变成「元数据先提交，数据后异步上传」**

`cached_store.go:424--443`：`stage()`（本地磁盘）成功后立即 `s.errors <- nil`，上传还没开始。文档 `:185` 承认："**commit first, then upload asynchronously**"，`:191` 列为风险："if write cache data suffers loss before upload is complete, file data is lost forever"，`:197` 说其他节点此时读会 timeout / I/O error。

**但危害形态与 ext4 不同：是失败停止，不是静默读到错数据**

| | ext4 元数据先落 | JuiceFS WB |
|---|---|---|
| 指针指向 | 块号会**复用** ⇒ 指向别的文件旧内容 | slice id 由 `base.go:2130 NewSlice` → `:2134 incrCounter("nextChunk")` **单调分配、永不复用** |
| 读到什么 | **静默的错误数据** | 对象不存在 ⇒ ENOENT/EIO |
| 可检测性 | 难 | `cmd/fsck.go:167` 扫全部 slice，`:222` 报 `N objects are lost, M broken files` |

**更难看的细节：staging 没有 fsync。** `pkg/chunk/disk_cache.go` 全文搜 `Sync()` / `Fsync` **零命中**；`stage()`（`:783--809`）走 `flushPage()` 普通 buffered write + rename。⇒ WB 的不一致窗口**连宿主掉电都挡不住**，只能挡 juicefs 进程崩溃。

**对 06 阶段的影响（待落 C-14）**：06-1 的 T1/T2 与 06-3 的 W 臂**全部开了 `--writeback`** ⇒ C-1 的活跃写 `+21.68%` **本质是拿耐久性换带宽**；C-1c 记账的 staging 峰 71.08 GiB 换成风险语言就是「任何时刻约 71 GiB 已被元数据承认、但只存在于单块未 fsync 的本地盘上」。C-7.4b 的「只需 `--writeback` 一个开关」技术上仍成立，但**必须加耐久性前置条件**。

### 2.3 WSL 本地的 JuiceFS 源码盘点

| 位置 | 版本 | 状态 | 能否作证据 |
|---|---|---|---|
| `/tmp/opencode/` | **1.4.1** | 从归档解包，SHA256 `a3265ff9…` 相符 | ✅ **唯一权威**，对应测试二进制 `24fae085…` |
| `/mnt/c/SunRise/github/juicefs/` | 1.4.0-dev-467-g44dd412a（2026-06-17） | git 仓库，工作树**脏**（`pkg/chunk/` 下 10 文件 M） | ⚠️ 仅可参考 / 可用于 `git log -L` 溯源 |
| `/home/lilingfeng/project/juicefs/` | **1.3.1** | 脏 | ❌ 版本不符（既有 `juicefs-slice-chunk-block…` 文档基于此） |
| `…/06-2/…/build/*.tar.gz` | 1.4.1 官方 + b-catchup | 归档，只读 | ✅ 冻结母本 |

**两份 1.4 的实际差距远小于表面**：`diff` 初看差 2499/1203/3076 行，全是 `/mnt/c` 上的 **CRLF 行尾**造成的假差异（`file` 确认 `with CRLF line terminators`）。`tr -d '\r'` 后：

| 文件 | 真实差异 | 差在哪 |
|---|---|---|
| `pkg/chunk/cached_store.go` | **7 行** | `:1063` staging 上传时 tier 解析（`ReadTierID()` vs `stageFooter.unmarshal`） |
| `pkg/vfs/writer.go` | **7 行** | `:97--103` `prepareID` 后补的 `FlushTo` —— 即 b-catchup 补丁 |
| `pkg/chunk/disk_cache.go` | 168 行 | 较多，未逐条核 |

**写序证据全部不受影响**，差异点都不在那些路径上，内容逐字节相同，仅行号偏移 7（clone 中 `m.Write` 在 `:208`、`for !s.done` 在 `:194`、`os.Link` 在 `:791`；两份 `disk_cache.go` 的 fsync 命中数**都是 0**）。

---

## §3 第一轮问答（读栈 / slice 概念 / Flush 语义 / 对象名 / 顺序）

### Q1 `base.go:Read()` 与 `vfs.go:Read()` 的关系 + 完整函数栈

**关系：不是同名重载，是分层的两件事。** `vfs.Read` 是 **VFS 层读入口**（句柄、权限、锁、flush、range 切分）；`baseMeta.Read` 是**元数据层的一个子步骤**，只负责「给我 (inode, chunk 序号) 的 slice 列表」。前者在一次读中调用后者 0 到 N 次（N = 跨越的 chunk 数）。

```
用户 read(2)
│  内核 VFS → FUSE 驱动 → /dev/fuse
│
├─ pkg/fuse/fuse.go:263        (fs *fileSystem) Read          ← FUSE READ 请求解包
│  └─ fs.v.Read(ctx, ino, buf, in.Offset, in.Fh)
│
├─ pkg/vfs/vfs.go:693          (v *VFS) Read                  ← VFS 层入口
│   ├─ :779  权限检查（EnableWriteback 时放宽）
│   ├─ :783  h.Rlock(ctx)                                     ← 句柄读锁
│   ├─ :789  v.writer.Flush(ctx, ino)   ★★ M1：等整个 inode 落地 + 提交
│   └─ :790  h.reader.Read(ctx, off, buf)
│
├─ pkg/vfs/reader.go:626       (f *fileReader) Read
│   ├─ :629  缓冲水位反压（readBufferUsed > bufferSize 则 sleep）
│   ├─ :659  f.splitRange(block)         ← 按 64 MiB chunk 边界切分
│   ├─ :660  f.prepareRequests(ranges)   ← 每段找/建一个 sliceReader
│   ├─ :670  f.checkReadahead(block)     ← 触发预读
│   └─ :671  f.waitForIO(ctx, reqs, buf) → :592
│
├─ pkg/vfs/reader.go:162       (s *sliceReader) run           ← 每 chunk 一个，异步
│   └─ :175  f.r.m.Read(ctx, inode, indx, &slices) ──────────┐
│                                                            │
│  ┌─────────────────────── 元数据层 ────────────────────────┘
│  ├─ pkg/meta/base.go:2081   (m *baseMeta) Read
│  │   ├─ :2093  m.of.ReadChunk(inode, indx)   ← 本地 slice 列表缓存，命中直接 return 0
│  │   ├─ :2100  m.en.doRead(ctx, inode, indx) ← 未命中走引擎
│  │   │    └─ pkg/meta/tkv.go:2624  doRead
│  │   │         └─ m.get(m.chunkKey(inode, indx))   ← 一次 TiKV 点查
│  │   │              └─ pkg/meta/slice.go:118 readSliceBuf   ← 按 24 字节切分
│  │   ├─ :2118  buildSlice(ss) → pkg/meta/slice.go:134
│  │   │          ★ 把重叠 slice 展平成不重叠列表，后来者覆盖先来者
│  │   └─ :2119  m.of.CacheChunk(inode, indx, *slices)  ← 回填本地缓存
│  └────────────────────────────────────────────────────────┐
│   └─ :209  f.r.Read(ctx, p, slices, off % ChunkSize) ←──────┘
│
├─ pkg/vfs/reader.go:840       (r *dataReader) Read
│   ├─ :850  遍历 slices，用累加 pos 定位覆盖目标偏移的片
│   └─ :853  每片起一个 goroutine → readSlice（>16 片走 :881 readManySlices）
│
├─ pkg/vfs/reader.go:813       (r *dataReader) readSlice
│   ├─ :816  s.Id == 0 → 填零（文件空洞 / 被截断区）
│   └─ :823  reader := r.store.NewReader(s.Id, int(s.Size))
│              → pkg/chunk/cached_store.go:1164 → :62 sliceForRead
│
└─ pkg/chunk/cached_store.go:97  (s *rSlice) ReadAt           ← 数据层
    ├─ :106  indx = index(off)          ← block 下标 = off / BlockSize
    ├─ :107  boff = off % BlockSize     ← block 内偏移
    ├─ :109  跨 block 则递归拆分
    ├─ :130  key = s.key(indx)          ← 生成对象名（见 Q5）
    ├─ :133  s.store.bcache.load(key)   ★ 本地盘缓存
    │         命中 → :135 r.ReadAt(p, boff) → :142 cacheHits++ → 返回
    ├─ :152  cacheMiss++
    ├─ :155  loadRange（部分读优化）
    └─ :162  group.Execute → :755 store.load → 对象存储 GET
              └─ :820 store.bcache.cache(key, page, …)   ← 回填读缓存
```

### Q2 slice 到底是数据还是元数据？

**slice 是元数据实体，它描述数据。** 官方文档把它放在数据章节讲，是因为它是**数据的逻辑划分单位**；但它在系统里的物理存在形式是一条元数据记录。两种说法不矛盾，只是视角不同。

```go
// pkg/meta/interface.go
type Slice struct {
    Id   uint64   // slice 全局唯一 id
    Size uint32   // slice 的总长度（cleng）
    Off  uint32   // 本次引用在 slice 内的起始偏移
    Len  uint32   // 本次引用的长度
}
// pkg/meta/slice.go:91
const sliceBytes = 24        // 一条 slice 记录 = 24 字节
```

- 存在元数据引擎里：TiKV key = `chunkKey(inode, indx)`，value = 24 字节记录的定长数组（`tkv.go:2624 doRead` → `readSliceBuf` 按 24 字节切分）；
- 提交它的动作是**元数据事务**：`tkv.go:2680` 的 `marshalSlice(...)` + `val = append(rs[1], val...)` + `tx.set(m.chunkKey(...), val)`；
- 真正的**数据**在对象存储的 **block** 里，block 名字由 slice 的 `Id` 派生（`cached_store.go:74--78`）。

| 概念 | 性质 | 存在哪 |
|---|---|---|
| chunk | 纯逻辑坐标（固定 64 MiB） | 无实体，只是元数据分片键 |
| **slice** | **元数据记录**（24 字节，指向数据） | 元数据引擎 `chunkKey(inode, indx)` |
| block | **数据对象** | 对象存储 / 本地缓存盘 `raw/chunks/…` |

准确说法：**slice 是「一次写入产生的逻辑区间」+「指向数据块的指针」，实现为一条元数据记录。**

### Q3 Flush 的完整实现，以及为什么值得

**用户判断完全正确：这个 Flush 不只提交元数据，数据也一起写了，而且数据在前。**

```
pkg/vfs/vfs.go:789        v.writer.Flush(ctx, ino)
 └─ pkg/vfs/writer.go:558 (w *dataWriter) Flush → w.find(inode)，nil 则 return 0
     └─ :443              (f *fileWriter) Flush → f.flush(ctx, false)
         └─ :393          (f *fileWriter) flush
              :405  for len(f.chunks) > 0 && err == 0 {
              :406      for _, c := range f.chunks {          ← 遍历该 inode 全部 chunk
              :407          for _, s := range c.slices {      ← 全部 slice
              :408              if !s.freezed {
              :409                  s.freezed = true
              :410                  go s.flushData()
              :414      f.flushcond.WaitWithTimeout(3s)
```

```
pkg/vfs/writer.go:117   (s *sliceWriter) flushData
     :117  defer s.markDone()
     :122  s.prepareID(...)
     :128  s.length = s.slen
     :129  s.writer.Finish(int(s.length))      ★★ 数据在这里上传
```

```
pkg/chunk/cached_store.go:497  (s *wSlice) Finish
     :503  s.FlushTo(n * BlockSize)
     :507  for i := 0; i < s.pendings; i++ { <-s.errors }
  非 --writeback：:467  s.errors <- s.store.upload(...)   ← 真 PUT 完成才发信号
  开 --writeback：:443  s.errors <- nil                   ← 只写完本地 rawstaging 就发信号
```

```
pkg/vfs/writer.go:193  (c *chunkWriter) commitThread
     :198  // the slices should be committed in the order that are created
     :201  for !s.done { ... }                       ← 等数据完成
     :207  for s.dep != nil && !s.dep.committed { }  ← 等依赖
     :215  f.w.m.Write(...)                          ★ 提交元数据
     :216  f.w.reader.Invalidate(...)
     :271  freeChunk → :274 f.flushcond.Broadcast()  ← len(f.chunks)==0 时唤醒 flush
```

**`vfs.go:789` 的完整语义：等这个 inode 的所有未完成写「数据上传完成（或 WB 下落本地盘）+ 元数据事务提交完成」。**

**为什么值得（三层，第 3 层才是真正答案）：**

1. **POSIX read-your-own-writes 是强制的。** 未提交的 slice 不在列表里 ⇒ `buildSlice` 展平时不存在 ⇒ 读返回**旧数据**。正确性问题，不能不做。
2. **替代方案（读路径 pending overlay）成本不低。** 见 Q7。
3. **★ 真实 buffered I/O 下这个 Flush 极少触发。** 应用读刚写过的偏移，内核 FUSE 页缓存**直接挡掉**，请求根本不下到 `/dev/fuse`。⇒ `vfs.go:789` 在真实负载下不是热路径。**是 `--direct=1` 把它变成了热路径**（M-39）。JuiceFS 的分工是「**正确性做在 VFS 层，性能靠内核页缓存挡量**」。我们的 benchmark 恰落在该设计的最坏情况上。

### Q4 从某个偏移读数据的完整实现

| | 大小 | 性质 |
|---|---|---|
| **chunk** | 固定 **64 MiB**（`interface.go:39 ChunkBits = 26`） | 纯逻辑坐标。**无实体**，只是元数据分片键 |
| **slice** | ≤ 64 MiB，不定长 | 一次连续写产生的逻辑区间，24 字节记录。**可重叠** |
| **block** | ≤ 格式化 `--block-size`（本卷 **256 KiB**，社区默认 4 MiB） | 真正的对象存储对象，**不可变** |

**走一遍：读 inode=X 的 `off = 100 MiB`，长度 256 KiB**

1. **文件偏移 → chunk 坐标**（`reader.go:659 splitRange`）：`indx = 100MiB >> 26 = 1`；chunk 内偏移 `= 100MiB − 64MiB = 36 MiB`。跨边界则拆多段。
2. **取 slice 列表**（`base.go:2081`）：先查 `m.of.ReadChunk(X,1)`；未命中 → `tkv.go:2624 doRead` 一次 TiKV 点查 → N × 24 字节 → `slice.go:134 buildSlice` 展平（后来者覆盖先来者，空洞用 `Id=0` 填充）。
3. **在展平列表里定位**（`reader.go:850--861`）：累加 `pos` 找到覆盖 36 MiB 的片；一个 256 KiB 读可能横跨多片 ⇒ 每片一个 goroutine。
4. **slice 内偏移 → block 坐标**（`cached_store.go:97`，入参 `off = 片内偏移 + s.Off`）：
   `blockIdx = off / 256KiB`；`blockOff = off % 256KiB`；`blockLen = min(s.Size − blockIdx×256KiB, 256KiB)`（`:66--72`）。
5. **生成对象名**（`:130 key(indx)` → `:74--78`）见 Q5。
6. **★ 命中读缓存的流程**（`:131--150`）：

```go
if s.store.conf.CacheEnabled() {
    r, err := s.store.bcache.load(key)         // 打开 <cache-dir>/<UUID>/raw/chunks/...
    if err == nil {
        n, err = r.ReadAt(p, int64(boff))      // ← 普通 buffered pread！
        if !s.store.conf.OSCache { dropOSCache(r) }   // posix_fadvise(DONTNEED)
        _ = r.Close()
        if err == nil {
            s.store.cacheHits.Add(1); s.store.cacheHitBytes.Add(float64(n))
            return n, nil                      // 结束，不碰网络
        }
        s.store.bcache.remove(key, false)      // 部分损坏 → 走 miss
    }
}
```

**第 4 行 `r.ReadAt` 是普通 buffered pread，不是 O_DIRECT** ⇒ 缓存命中的**真实供给方是宿主 page cache**。这正是 C-5 的代码根据（本轮 iostat 重算再次确证 `rkB/s` 全程 `0.00`）。

7. **未命中**（`:152--177`）：`cacheMiss++` → `loadRange` 或 `group.Execute` → `:755 store.load` → GET → `:820 store.bcache.cache(...)` 回填。回填是否发生由 `:844 shouldCache(size) = CacheFullBlock || size < BlockSize` 决定，默认 `CacheFullBlock=true` ⇒ 整块都缓存。

### Q5 对象名 `chunks/<id/1e6>/<id/1e3>/<id>_<indx>_<size>` 各级含义

```go
// cached_store.go:74--79
func (s *rSlice) key(indx int) string {
    if s.store.conf.HashPrefix {
        return fmt.Sprintf("chunks/%02X/%v/%v_%v_%v", s.id%256, s.id/1000/1000, s.id, indx, s.blockSize(indx))
    }
    return fmt.Sprintf("chunks/%v/%v/%v_%v_%v", s.id/1000/1000, s.id/1000, s.id, indx, s.blockSize(indx))
}
```

| 层级 | 表达式 | 含义 | 为什么 |
|---|---|---|---|
| `chunks/` | 字面量 | 数据对象顶层前缀 | 与 `meta/`、`juicefs_uuid` 区分 |
| 第 1 级 | `id / 1000000` | 每 **100 万** 个 slice id 一个目录 | 一级分桶 |
| 第 2 级 | `id / 1000` | 每 **1000** 个 slice id 一个目录 | 二级分桶。**限制单目录条目数** —— 对象存储 LIST 分页与本地目录项都受不了千万级 |
| 第 3 级 | `id` | **slice id**，全局单调唯一（`base.go:2130`，永不复用） | 内容寻址基础 |
| `_indx` | block 在该 slice 内的序号，从 0 起 | | |
| `_size` | `blockSize(indx) = min(slice.Size − indx×BS, BS)`（`:66--72`） | 该 block 的**实际字节数**，最后一块常小于 BS | |

两个设计细节：

1. **把 size 编进 key**：读端不需额外元数据就知道该 GET 多长；且 key 自校验 —— `cached_store.go:906 parseObjOrigSize` 从 key 反解长度，缓存文件名损坏能立即发现。
2. **`HashPrefix` 变体**把第 1 级换成 `id % 256`（两位大写十六进制），把单调 id 打散到 256 个前缀，避免按 key 前缀分区的对象存储（典型 S3）产生分区热点。本卷 Ceph RADOS 后端不需要。

举例（本卷 BlockSize=256 KiB，一次 256K 写 = 一个 slice = 一个 block），slice id = 5,257,621：`chunks/5/5257/5257621_0_262144`

### Q6 slice id 分配时机 —— 前提需更正

**更正 1：slice id 在第一个字节落下时就分配了，不等上传。** `writer.go:278--291`：

```go
s = &sliceWriter{ chunk: c, off: off, writer: f.w.store.NewWriter(0, f.tierID), ... }
go s.prepareID(meta.Background(), false)      // :290 ★ 立即异步申请
c.slices = append(c.slices, s)                // :291
```

且**基本不走网络** —— `base.go:2130 NewSlice` 从本地批量池取，池空才 `incrCounter("nextChunk", sliceIdBatch)`，`base.go:51 sliceIdBatch = 4<<10 = 4096` ⇒ **平均每 4096 个 slice 一次元数据往返**。

**更正 2：开 WB 时 block 在元数据提交之前就已在读缓存里。** `disk_cache.go:783--809`：`stage()` 写完 `rawstaging/` 后，`:801 os.Link(stagingPath, path)` 硬链接进 `raw/`，`:802 cache.add(key, -int32(len(data)), ...)` 登记索引 ⇒ **立即可被 `bcache.load(key)` 命中**，早于 `writer.go:215 m.Write`。

**更正 3：写缓存提交后不释放，只换账目。** `cached_store.go:445--452`：`bcache.uploaded(key, blen)`（→ `disk_cache.go:810 cache.add(key, +size, 0)`）+ `removeStage(key)` 只删 `rawstaging/` 这个名字；`raw/<key>`（**同一 inode、同一份数据**）保留继续当读缓存，仅容量记账从「暂存（负值，不占额度）」翻成「读缓存（正值，占额度）」。

⇒ **「读写缓存不会一致」在物理层面恰好相反：WB 下它们是同一 inode 的两个名字，物理上必然一致**（C-7.4b：源码 `:801/:802`；04-tmp2i `cache-inodes-formal-end.tsv` 里 122,486 个 rawstaging 文件 **100% 有硬链接**；06-1 T 臂无 CLW 仍达 41.82% 命中）。

**真正拦住读的是第三样东西：chunk 的 slice 列表里还没有那条 24 字节记录。** 读端拿不到 `{Id, Size, Off, Len}`，就不知道去 load 哪个 key、放到结果缓冲哪个位置。⇒ **缺的是索引项，不是数据也不是 id。**

### Q7 数据在缓存里，读路径为何不能去查？—— 我说错了

**撤销**：我说「命名空间里根本没有能指代它的名字」，**在本几何下是错的**。256 KiB 随机写、BlockSize 也 256 KiB ⇒ **一次写 = 一个 slice = 恰好一个完整 block**，key 三个分量在 slice 创建时全部确定（`id` 已分配、`indx=0`、`size=262144`），开 WB 时数据也已在 `raw/` 下。**名字有，数据有。** 该说法只在「slice 尾部未满的那个 block」上成立。

**"去查找"的成本不在查找本身。** 那张「inode → chunk → 按次序排列的 pending 区间表」**存在**，就是 `chunkWriter.slices`，在同一进程同一块内存里。技术上完全做得到。真实成本四项：

| | 成本 | 性质 |
|---|---|---|
| (a) | 读路径要拿 `fileWriter.Mutex`。当前读写两路**完全解耦**，只在 `writer.go:216 reader.Invalidate` 单向交互。randrw 下会成热锁 | **工程成本，高** |
| (b) | 要把 `slice.go:134 buildSlice` 改成对「已提交列表 + pending 列表」二路合并，pending 段次序依赖 `c.slices` FIFO 与 `s.dep` | 工程成本，中 |
| (c) | 未冻结 slice 的**尾部 block 还在 `s.pages` 内存里**，key 的 `size` 分量未定 ⇒ 读路径要实现**第二套数据源**（内存页 + 缓存文件 + 对象存储三条） | **工程成本，高** |
| (d) | 跨客户端时本地 overlay 让本地读与远端读看到不同内容，close-to-open 语义要重新定义 | **语义成本** |

**这个结论有直接价值**：(a)(c) 说明 overlay 是大改，(d) 还要动语义。而 **range-flush 只需把 `writer.go:405--412` 那个「遍历全部 chunk 全部 slice」的循环收窄到「与被读 range 相交的 slice」** —— 不碰读路径、不碰语义、不引入第二数据源。⇒ **收益大部分能拿到，复杂度低一个数量级。** 建议写进 06-2b 背景章节。

### Q8 并发覆盖写的顺序 —— 用户三个反问都成立，我表述过强

**提交时的顺序由元数据引擎的事务序决定，不是客户端。** `tkv.go doWrite` 是一个 TiKV 事务：

```go
val := marshalSlice(off, slice.Id, slice.Size, slice.Off, slice.Len)   // 24 字节
val = append(rs[1], val...)                    // ★ 追加到 chunk 值末尾
tx.set(m.chunkKey(inode, indx), val)
```

**顺序 = 追加顺序 = 事务提交顺序。** 读端 `slice.go:134 buildSlice` 按列表顺序逐个 `root.cut(...)`，后面的把前面重叠部分切掉并成为新 root ⇒ **列表越靠后越赢**。

**用户场景（原 aaa，进程1 写 bbb→slice1，进程2 写 ccc→slice2，同址并发）：**

- **同一客户端两个进程**：都进同一个 `fileWriter`（`writer.go:571 files map[Ino]*fileWriter`），`writeChunk` 全程持 `f.Lock()` ⇒ 串行化。`findWritableSlice`（`:169--190`）遇重叠返回 nil：

  ```go
  if pos < s.off+s.slen && s.off < pos+size {
      // overlaped
      // TODO: write into multiple slices
      return nil
  }
  ```

  ⇒ 强制新建 slice，按创建顺序 `append`（`:291`），`commitThread` 严格照 `c.slices[0]` FIFO 提交。**⇒ 顺序在本地写完那一刻就完全确定了。用户说对了。**
- **两个不同客户端**：各自本地 FIFO 有序，但两个 FIFO 如何交错完全由 TiKV 事务序决定，客户端无法预知。

**正确结论：同客户端内顺序本地可知且早已确定；跨客户端不可知。** 而 POSIX 对「无锁并发写同一区间」**本就不保证结果** ⇒ 跨客户端那部分不需要保证。

⇒ **撤销**：我把"顺序未定"当作读必须 flush 的主要理由**不成立**。真正成本是 Q7 的 (a)(c)(d)。本地读仍需"关心顺序"的唯一原因是要把本地那份**已知**顺序与已提交列表正确合并 —— 这是 Q7(b)，是实现工作量，不是不可知性。

### Q9 次序为何不能提前到写入本地缓存时确定？

**已经提前确定了。撤销上一轮说法。** `writer.go:291 c.slices = append(c.slices, s)` 执行完，该 chunk 内所有 pending slice 的相对次序即固定。`commitThread`（`:193--215`）不做任何重排：

```go
for len(c.slices) > 0 {
    s := c.slices[0]              // ← 严格取队首
    for !s.done { ... }
    for s.dep != nil && !s.dep.committed { ... }
    ... m.Write(...)
```

`s.dep` 处理的是**跨 chunk 的文件长度依赖**（`:296--313`），且只在 `if s.growing` 分支内设置 ⇒ 纯覆盖写下恒为 nil（即已登记的「假设① 范围收窄」）。⇒ **次序在本地写入时确定，`commitThread` 只是执行者。**

### Q10 物化动作为何不能提前？

**开 WB 时已经提前了**（`disk_cache.go:801` 的 `os.Link` 早于 `m.Write`）。真正没能提前的只有两样：

| | 没提前的东西 | 能否提前 | 为什么 |
|---|---|---|---|
| 1 | 未冻结 slice 的**尾部 block** | 可以但有代价 | 还在 `s.pages` 内存里，key 的 `size` 取决于 slice 最终长度；提前物化需每次写后重算 key 并落盘 ⇒ 写放大。**本几何不存在此问题**（一次写正好一整块） |
| 2 | slice 列表里那条 **24 字节索引记录** | **不能** | 它是**全局可见性的定义点**。一旦写入 TiKV，所有客户端都会去 GET 那个 key。非 WB 下这正是必须先等 PUT 完成的原因 |

⇒ **真正不能提前的只有第 2 项，理由是分布式可见性，不是本地实现困难。** 而这正是 `--writeback` 耐久性缺口所在（§2.2 / 待落 C-14）。

### Q11 `writeback_cache` 原理 + 能否去掉 `--direct=1`

**原理**：FUSE 内核侧特性（Linux ≥ 3.15）。默认 FUSE 写是 **writethrough**，每个 `write(2)` 同步下发一个 FUSE WRITE。开 `-o writeback_cache` 后内核把 FUSE 文件页缓存当普通 page cache 用：`write(2)` 只标脏就返回，由内核 writeback 线程自行合并、择机下发。

```
pkg/fuse/fuse.go:503--504   } else if n == "writeback_cache" { opt.EnableWriteback = true }
pkg/fuse/fuse.go:570--571   （另一处解析路径，同上）
pkg/vfs/vfs.go:779          if v.Conf.FuseOpts != nil && !v.Conf.FuseOpts.EnableWriteback && !hasReadPerm(h.flags) {
pkg/vfs/handle.go:246/:417  case syscall.O_WRONLY: // FUSE writeback_cache mode need reader even for WRONLY
```

`handle.go` 的注释点出关键副作用：**开了之后即使 `O_WRONLY` 打开也必须建 reader** —— 内核要先把页读进来才能改。

官方定位（`docs/zh_cn/guide/cache.md:141`）：对 **10--100 字节级**高频随机小写收益显著，**但会把顺序写也变成随机写**，只建议密集随机小写场景用。⚠️ 文档 `:143` 专门澄清 `-o writeback_cache`（内核页缓存策略）与 `--writeback`（客户端本地暂存）**是完全不同的两件事**。

**能否去掉 `--direct=1`** —— 本轮已由用户定案为「可以测，只对竞品横向比」，见 §0.1。我当时的三条技术分析仍作为**口径限定**保留：

1. 宿主 `Cached` 峰值达 **743 GiB** ⇒ 内存 ≥750 GiB；数据集仅 **128 × 1 GiB = 128 GiB** ⇒ 会整集驻留宿主 page cache；
2. `--direct=1` 从来没绕过真正的缓存层 —— juicefs 对 `<cache-dir>` 一直是 buffered I/O（`cached_store.go:135 r.ReadAt` 普通 pread），本轮 iostat 重算再次确证 `rkB/s` 全程 `0.00`；
3. 会摧毁 06 阶段十格纵向可比性（故 §0.1 明确只横向对竞品）。

⛔ **仍不建议的一项**：`--direct=1` 保持不变、只额外加 `-o writeback_cache` 单臂 —— `direct=1` 下内核页缓存被绕过，该选项基本不生效，预期无效应，不值得占格。

---

## §4 第二轮问答（脚本口径 / 延迟叠加 / 缓存盘压力 / Slice 字段 / 设计依据 / 缓存实现）

### Q1 `rwmixread` 为何只在竞品脚本里看到？我方读写是各占一半吗？

**是，各占一半，两侧同口径。** 但参数出现的位置与用户的印象相反 —— 全量清点如下：

| 脚本 | 是否显式写 `rwmixread` | 出处 |
|---|---|---|
| `scripts/FULLBASELINE/FULLBASELINE.sh` | ❌ 无 | `item_randrw()` `:191--201` |
| `scripts/FULLBASELINE/FULLBASELINE_V4.sh` | ❌ 无 | `item_randrw()` `:909--914` |
| `scripts/benchmark/fio-7item-test.sh`（竞品七项） | ❌ 无（全文 0 命中） | `item_randrw()` `:229--240` |
| `scripts/benchmark/fio-randrw-bs-sweep.sh` | ✅ **有** `--rwmixread=50` | `:477`、`:488` |
| `scripts/FULLBASELINE/debug/t06-1-randrw-cache-driver.sh` | ✅ **有** `rwmixread=50` | `:410` |
| 其余 04/05/06 阶段 debug driver | ✅ 多数有 | `grep -rln rwmixread scripts/` 共 21 个文件 |

**关键：fio 的默认值就是 50。** 本机 `fio-3.41` 实测：

```
$ fio --cmdhelp=rwmixread
   rwmixread: Percentage of mixed workload that is reads
        type: integer value (opt=100)
     default: 50
```

⇒ **没写 `rwmixread` 的脚本和写了 `rwmixread=50` 的脚本行为完全一致。** 所有 randrw 测试（我方 FULLBASELINE、我方 06 阶段、竞品七项）都是**读写各占一半**。

**用户"在竞品测试脚本里看到"的解释**：`fio-randrw-bs-sweep.sh` 是**双方共用**的脚本 —— 05-2 的 D4 已记载「竞品 `environment.tsv` 的源头就是 `scripts/benchmark/fio-randrw-bs-sweep.sh`，SHA256 `1120a83c…`」。所以那个显式带 `--rwmixread=50` 的脚本既跑我方也跑竞品，用户的观察是对的，只是它同时也是我方脚本。

⚠️ **`rwmixread` 不是可调项**：一旦改成非 50，`read_bw`/`write_bw` 的 1:1 锁定关系就变了，与 04/05/06 全部历史值不可比。若将来要探索比例锁定的影响，必须作为独立任务并明确声明不可比。

### Q2 为什么是 `max` 而不是"缓存命中延迟 + flush 延迟"？

**用户是对的，我写错了。是串行相加，不是取 max。** 代码是明确的顺序执行（`pkg/vfs/vfs.go:789--790`）：

```go
_ = v.writer.Flush(ctx, ino)      // 先等 flush 完
n, err = h.reader.Read(ctx, off, buf)   // 再读
```

正确写法：

```
读延迟 = flush 等待 + 缓存/网络读延迟          （串行相加）
```

我当时想表达的是"被 flush 项支配"，但写成 `max` 是错的。**撤销**（§5 撤销④）。

**不过用相加来算，结论反而更强 —— 因为两项差了两个数量级。** 从 06-3 `analysis.json` 的正式窗计数器可以直接算出缓存命中读的平均延迟（`cache_read_seconds_sum / cache_read_seconds_count`）：

| 格 | 缓存命中读平均延迟 |
|---|---|
| S1 | **0.1124 ms** |
| W1 | 0.1257 ms |
| W2 | 0.1188 ms |
| S2 | 0.1105 ms |

而 flush 侧的量级：06-1 实测 PUT 平均 **20.7 ms**（C1，7232 PUT/s × 150 槽）/ **17.3 ms**（T1）。

⇒ **比值约 150--185 倍。** 所以：

```
读延迟 ≈ flush 等待（~20 ms 量级）+ 缓存读（0.11 ms）
```

把 0.11 ms 这一项优化到 0，总延迟只降 0.5%。**这比我原来的 "max" 说法更有说服力地证明了阻断二。**

**一个必要的补充（并发共享）**：本几何 128 个 job 各用独立文件（`rw_test.N.0`），`iodepth=128` ⇒ 同一 inode 上有 128 个并发 IO。它们各自调 `Flush`，但通过 `fileWriter` 的 `f.Lock()` + `flushwaiting` / `flushcond`（`writer.go:397--420`）汇聚到**同一次排空波**。所以每个读等的是「当前 flush 波的剩余时间」，**不是 128 × flush**。这一点使 M1 的绝对代价比朴素估算低，但仍远高于缓存读。

### Q3 缓存盘额外写一份，NVMe 很快，600 MiB/s 远未到上限，`util 100.40%` 也不说明压力大

**用户的两条批评完全成立，我原来的证据是错的：**

1. `600--624 MiB/s` 确实低，不能证明压力；
2. `%util` 对多队列 NVMe **本质上无意义** —— 它只统计"至少有一个未完成 IO 的时间占比"，一个 NVMe 可以在 `%util = 100%` 时只用了 1% 的能力。

**但换用正确指标后，结论反而被更强地证实。** 从 `raw.tar.gz` 内 `cells/*/iostat-1hz.tsv` 重算（活跃样本定义 `wkB/s > 100 MiB/s`）：

| 格 | 活跃样本 | 活跃写中位 | `w_await` 中位 | `w_await` p95 | `aqu-sz` 中位 | `rkB/s` 最大 |
|---|---|---|---|---|---|---|
| S1 | 152/312 | **1608.3 MiB/s** | **49.04 ms** | 53.82 ms | **317.6** | 0.00 |
| W1 | 170/324 | **1606.8 MiB/s** | **50.06 ms** | 54.33 ms | **331.9** | 0.00 |
| C1（对照） | — | ≈0 | 0.10 ms | 0.00 | 0.00 | 0.00 |

- 原来的 `600--624 MiB/s` **是含空闲期的整窗均值**（S1 整窗均值 622.5 MiB/s）；活跃期实际 **1608 MiB/s**。
- **`w_await` 中位 49--50 ms、`aqu-sz` 中位 318--332** —— 这是**确凿排队**。小李定律自校验：`6297 IO/s × 0.049 s = 308 ≈ aqu-sz 318` ✓。
- 所以正确的表述**不是**"多写一份消耗带宽"，而是：**活跃突发期缓存盘队列深 330、写延迟 50 ms，已进入排队饱和区**。

**而且这个饱和有直接的功能后果**（Q4 与 §1.3 阻断四）：它导致 juicefs 的准入队列溢出，**31--36% 的缓存准入被静默丢弃**。所以阻断三不是一个"成本项"，而是通过丢弃**直接削掉了 CLW 三分之一的效果**。

⇒ 结论：**用户对我证据的批评成立；阻断三本身成立但须换证据；且它的危害比我原来说的更严重。** 已在 §1.3 与 §5 更正。

### Q4 600 MiB/s 这么低的带宽是什么限制导致的？

**答：600 MiB/s 不是任何"限制"，是被空闲期稀释的整窗均值。真正的限制是「突发 + 队列太浅」。** 三个层次：

**① 需求侧（juicefs 自己记账的准入写）** —— 由 `analysis.json` 正式窗计数器算出：

| 格 | `cache_write_bytes` | 正式窗时长 | 准入写需求 | `cache_writes/s` |
|---|---|---|---|---|
| S1 | 132.24 GiB | 189.939 s | **712.9 MiB/s** | 2851.8 块/s |
| W1 | 168.91 GiB | 200.017 s | **864.7 MiB/s** | 3459.0 块/s |
| W2 | 164.42 GiB | 195.778 s | 860.0 MiB/s | 3439.9 块/s |
| S2 | 129.06 GiB | 189.131 s | 698.8 MiB/s | 2795.1 块/s |

**② 设备侧（iostat 实测）**：活跃期 1608 MiB/s / 6297 块/s，但只有约一半时间活跃。

**③ 两者对得上 —— 这是关键的自校验：**

```
6297 块/s × (152 活跃样本 / 312 总样本) = 3068 块/s
对比 juicefs 记账 2851.8 块/s  →  误差 7.6%（iostat 覆盖了预热与排空，故略高）
```

⇒ **设备不是被"限制"在 600 MiB/s，而是以突发方式工作：约一半时间空闲、约一半时间 1.6 GiB/s。** 这是典型的内核 page cache writeback 行为（受 `dirty_expire_centisecs` / `dirty_background_ratio` 驱动），因为 `flushPage` 是普通 buffered write + rename、**全程无 fsync**（`disk_cache.go` 内 `Sync()`/`Fsync` 零命中）。

**真正的限制在 juicefs 自己的准入队列，不在设备**（`cached_store.go:1172`）：

```go
pendingPages := int(config.BufferSize) * 2 / 10 / config.BlockSize / len(dirs)
```

本配置 `--buffer-size 300`（`cmd/mount.go:391` 按 MiB 解析）、`BlockSize = 256 KiB`、`len(dirs) = 1`：

```
pendingPages = 314572800 × 2 / 10 / 262144 / 1 = 240 块 = 60 MiB
```

| 项 | 值 |
|---|---|
| 队列容量 | 240 块 |
| 活跃期消费速率 | 6297 块/s |
| ⇒ 队列可缓冲时长 | **38 ms** |
| 设备写服务时间（`w_await` 中位） | **49 ms** |

**38 ms < 49 ms ⇒ 每一次突发都必然溢出 ⇒ 丢弃是结构性的**，与 `disk_cache.go:474` 的源码注释完全一致：

```go
// does not have enough bandwidth to write it into disk, discard it
```

⇒ **结论：不是 NVMe 慢，不是带宽不够，而是 `pendingPages = 240` 这个队列相对于"突发式 writeback + 50 ms 排队"太浅了。** 这直接产生了一个可执行的调优候选（M-44）：`--buffer-size` 提到 2048 MiB 可把队列从 240 块（38 ms）放大到 1638 块（260 ms）。

### Q5 `type Slice struct` 中的 `Off` 和 `Len` 到底是什么意思？

**结论：`Off` 确实是「在 slice 自己的数据内的偏移」，不是文件偏移。文件/chunk 内的位置由另一个字段 `pos` 承载，而 `pos` 不在 `Slice` 结构体里。** 逐层说明：

**① 落盘的 24 字节记录有 5 个字段，比 `Slice` 多一个 `pos`**（`pkg/meta/slice.go:92--100`）：

```go
func marshalSlice(pos uint32, id uint64, size, off, len uint32) []byte {
    w := utils.NewBuffer(sliceBytes)   // 24 字节
    w.Put32(pos)     // 4  ← 在 chunk 内的起始位置
    w.Put64(id)      // 8  ← slice id
    w.Put32(size)    // 4  ← slice 的总长度（cleng）
    w.Put32(off)     // 4  ← 在 slice 内的起始偏移
    w.Put32(len)     // 4  ← 本次引用的长度
    return w.Bytes()
}
```

对应的内部结构体 `pkg/meta/slice.go:21--29` 也有 `pos`：

```go
type slice struct {
    id    uint64
    size  uint32
    off   uint32
    len   uint32
    pos   uint32       // ← 有 pos
    left  *slice
    right *slice
}
```

**② 而对外的 `meta.Slice` 没有 `pos`** —— 因为它出现在两个 `pos` 已隐含的场合：

- **写入时**（`writer.go:214--215`）：chunk 内位置作为**独立参数** `s.off` 传给 `m.Write`，不放在结构体里
  ```go
  var ss = meta.Slice{Id: s.id, Size: s.length, Off: s.soff, Len: s.slen}
  err = f.w.m.Write(meta.Background(), f.inode, c.indx, s.off, ss, s.lastMod)
  //                                              ↑ chunk 内偏移在这里
  ```
  然后 `tkv.go:2680` 把两者合成 24 字节：`marshalSlice(off, slice.Id, slice.Size, slice.Off, slice.Len)`
- **读出时**（`slice.go:151`）：`buildSlice` 输出的是**已展平、连续、有序**的列表，位置由遍历时累加得出，不需要显式 `pos`
  ```go
  chunk = append(chunk, Slice{Id: s.id, Size: s.size, Off: s.off, Len: s.len})
  ```
  读端 `reader.go:850--861` 就是靠累加 `pos += slices[i].Len` 定位的。

**③ `Off` 什么时候不为 0？** 写路径产生的记录 **`Off` 恒为 0** —— `sliceWriter.soff`（`writer.go:57`）在全文**只有声明和 `:214` 的读取，没有任何赋值点**，即永远是零值。`Off > 0` 只来自两处：

- **`buildSlice` 的 `cut()` 派生**（`slice.go:66`）：当后来的 slice 部分覆盖先前的 slice，先前那个的剩余部分在自己的数据内就不是从 0 开始了
  ```go
  right = newSlice(pos, s.id, s.size, s.off+l, s.len-l)
  //                                  ↑ 偏移前移 l 字节
  ```
- **`CopyFileRange` / clone 等引用既有 slice 的路径**（`tkv.go:2797/2802/2807`，可见 `s.Off` 与 `s.Off+skip`）

**④ 三个字段各自的用途**：

| 字段 | 用途 |
|---|---|
| `Size` | slice 的**总**长度。用来算 block key 的 `size` 分量（`cached_store.go:66--72 blockSize(indx) = min(Size − indx×BS, BS)`），以及决定该 slice 有几个 block |
| `Off` | 从这个 slice 的第几个字节开始取。`rSlice.ReadAt` 的入参就是 `off + int(s.Off)`（`reader.go:826`） |
| `Len` | 取多少字节。决定在结果缓冲里占多长，也是累加 `pos` 的步长 |

**一句话**：`{Id, Size}` 定位「哪一份不可变数据、总共多长」；`{Off, Len}` 在这份数据内切出「用哪一段」；`pos`（不在结构体里）说明「这一段贴到 chunk 的哪个位置」。用户的直觉「描述某段数据在文件中的偏移和长度」对应的是 **`pos` 和 `Len`**，而 `Off` 是另一个坐标系。

### Q6 randrw 下写让读缓存不断失效、读让 inode 立刻 flush 从而吃掉写缓存收益 —— 是这样吗？

**大方向成立，但三处机制需要修正，修正后结论更强。**

**修正 ①：磁盘读缓存不会因写而失效。** block 是**不可变**的，写只会产生**新** block，从不改旧 block。官方文档明说（`docs/zh_cn/guide/cache.md:22`）：

> 文件的任何修改操作都将生成新的数据块，原有块保持不变，**所以不用担心数据缓存的一致性问题**

写确实触发了两处失效，但都不是磁盘缓存：

| 被失效的东西 | 在哪 | 源码 |
|---|---|---|
| `openfiles` 的 slice 列表（**元数据**缓存） | 客户端内存 | `base.go:2168 defer m.of.InvalidateChunk(inode, indx)` |
| 内存预读缓冲 `sliceReader` | 客户端内存 | `writer.go:216 f.w.reader.Invalidate(...)` → `reader.go` 只调 `s.invalidate()` |

**真正让读缓存"变废"的是逻辑死亡 + 新块洪流**（§1.3 阻断四(c)）：旧 block 物理上还在缓存里，但在 `buildSlice` 里被新 slice 覆盖后**再也不会被读到**，却仍占 `--cache-size` 额度；同时新块以 113--133 GiB/格的速度涌入，**超过 96 GiB 的缓存总量** ⇒ 实测 `evicts/writes = 79--87%`，纯抖动。

⇒ 所以用户说的"读缓存不断失效"**现象成立，但不是显式失效，而是被自己制造的新块冲刷 + 逻辑死亡占额**。这个说法更准确，也更有解释力。

**修正 ②：读触发 flush 会吃掉写缓存收益 —— 方向要反过来看。**

开 `--writeback` 后，`Finish()` 只等本地 `stage()`（`cached_store.go:443 s.errors <- nil`），**不等 PUT**。所以：

| | 非 WB | 开 WB |
|---|---|---|
| 一次 flush 里每个 slice 要等 | **一次 PUT 往返（~20 ms）** | 一次本地 buffered write（sub-ms，无 fsync） |

⇒ **WB 不是"被 flush 吃掉收益"，而是 WB 把 flush 本身变便宜了。** 这意味着 C-1 的活跃写 `+19.56%` 里，**可能有相当大一块其实是读路径收益（M1 变短），而不是写路径收益**。

这是一个**新假设**，登记为 M-45。它与 C-2 已确证的「宿主脏页吸收 + 内核回压」不矛盾 —— 脏页吸收正是 `stage()` 能快速返回的原因；只是我们此前只从"写变快"的角度解读它，漏了"读等的 flush 变短"这一面。⚠️ 06-1 因比例锁定（read_bw ≡ write_bw）**无法从数据上分离这两条**，需要专门设计（例如 `rwmixread` 非 50 的单臂，或 range-flush 对照）才能判定。

**修正 ③：「这是 juicefs 机制决定的」成立，但要把"机制"具体化。** 不是一个笼统的机制，是四条可独立验证、可独立攻击的阻断（§1.3）：比例锁定、M1 inode 级 flush、缓存盘突发饱和、准入丢弃 + 新块洪流。其中只有第 2、4 条是可改的。

### Q7 「正确性做在 VFS 层，性能靠内核页缓存挡量」有官方依据吗？

**必须诚实区分：拆开的每一半都有官方依据，但"这两件事构成一个有意的分工"这句归纳是我的推断，官方没有原话。已按此降级标注。**

**有官方依据的部分：**

| 论断 | 官方出处 | 原文 |
|---|---|---|
| JuiceFS 明确承认在缓存与一致性之间取舍 | `docs/zh_cn/guide/cache.md:18` | 「分布式系统，往往需要在缓存和一致性之间进行取舍」 |
| **flush 的语义 = 数据同步到对象存储 + 对其他挂载点可见** | `docs/zh_cn/guide/cache.md:72`（一致性例外 第 3 条） | 「调用 `write` 成功后，挂载点自身立刻就能看到文件长度的变化……但这并不意味着修改已经成功提交，**在 `flush` 成功前，是不会将这些改动同步到对象存储的，其他挂载点也看不到文件的变动**。调用 `fsync, fdatasync, close` 都能触发 `flush`」 |
| COW / 不可变块 ⇒ 缓存无一致性问题 | `:22` | 「文件的任何修改操作都将生成新的数据块，原有块保持不变，所以不用担心数据缓存的一致性问题」 |
| 本地缓存以 block 为最小单元 | `:24` | 「本地数据缓存也是以对象存储的数据块做为最小单元」 |
| **重复读的高性能来自内核页缓存** | `:133` 与 `:137` | 「对于已经读过的文件，内核会为其建立页缓存……当重复读 JuiceFS 中的同一个文件时，速度会非常快，**延时可低至微秒，吞吐量可以到每秒几 GiB**」 |

`:70` 这一条尤其重要 —— **官方对 flush 语义的正式定义与我从代码得出的结论完全一致**（数据先落对象存储、然后元数据提交、之后才对其他挂载点可见）。这不是我的推断。

**没有官方依据的部分：为什么 `vfs.Read` 要无条件 `writer.Flush`。**

用 git 溯源（`/mnt/c/SunRise/github/juicefs`，1.4.0-dev 仓库）：

```
$ git log -L 789,789:pkg/vfs/vfs.go
  7a631f90  fix errcheck (#1247)       ← 只把 writer.Flush 改成 _ = writer.Flush
  b3f8f9d8  Refactor for VFS (#981)    ← 只把 writer 改成 v.writer
  d23762a7  first public release       ← 2021-01-08，首次公开发布即有此行
```

`git show d23762a7:pkg/vfs/vfs.go` 的上下文（`:613--620`）与今天结构完全相同：

```go
if !h.Rlock(ctx) { err = syscall.EINTR; return }
defer h.Runlock()

writer.Flush(ctx, ino)
n, err = h.reader.Read(ctx, off, buf)
```

⇒ **这行代码从 2021-01-08 首次公开发布起就存在，五年多从未有语义变更，也没有任何注释或 commit message 解释理由。** 用户"从第一次 release 就有了"的观察经 git 完全证实。

**结论分级：**

| 论断 | 级别 |
|---|---|
| flush 会同时落数据和提交元数据、并决定跨挂载点可见性 | ✅ **官方文档明证** |
| 重复读的性能由内核页缓存提供 | ✅ **官方文档明证** |
| COW 使缓存无需失效协议 | ✅ **官方文档明证** |
| 读前必须 flush 是为了 read-your-own-writes 正确性 | ⚠️ **代码可证**（`buildSlice` 不含未提交 slice ⇒ 会读到旧数据），但官方未解释 |
| **「正确性在 VFS 层、性能靠页缓存挡量」是一个有意的分工设计** | ⚠️ **我的归纳推断，无官方依据** |

写入 M-43 时已按此标注为**推断**。它作为解释框架有用（能同时解释为什么这行代码看着像灾难却五年没人动、以及为什么我们的 `direct=1` 数据低到反常），但**不得当作事实引用**。

### Q8 `openfiles` 的 slice 列表什么时候添加、什么时候释放？会一直加下去吗？

**先更正一处理解：`ReadChunk` 不创建列表。** `pkg/meta/openfile.go:206--219` 找不到就直接返回 `(nil, false)`：

```go
func (o *openfiles) ReadChunk(ino Ino, indx uint32) ([]Slice, bool) {
    of, ok := o.files[ino]
    if !ok { return nil, false }          // ← 不创建
    if indx == 0 { return of.first, of.first != nil }
    cs, ok := of.chunks[indx]
    return cs, ok
}
```

创建 map 的是 `CacheChunk`（`:221--234`，`of.chunks == nil` 时 `make`）。

**何时添加 —— 只有一个入口：**

`pkg/meta/base.go:2119 m.of.CacheChunk(inode, indx, *slices)`，即「刚从元数据引擎读到 slice 列表」之后回填。⇒ **只有读路径会往里加**，写路径从不添加。

**何时释放 —— 四条路径：**

| # | 触发 | 源码 | 粒度 |
|---|---|---|---|
| 1 | **写提交**（`Write` 内） | `base.go:2168 defer m.of.InvalidateChunk(inode, indx)` | 删该 chunk 一条 |
| 2 | truncate / fallocate 等 | `base.go:2194`、`:2229 InvalidateChunk(inode, invalidateAllChunks)` | 清空该 inode 全部 chunks |
| 3 | 重新 `open` 且 mtime 变了 | `openfile.go:143 of.invalidateChunk()`（`Open` 内） | 清空该 inode 全部 |
| 4 | **`openfiles` 层后台淘汰** | `openfile.go:68--115 cleanup()` 协程 | 整个 `openFile` 条目 |

第 4 条的两个条件（`cleanup()` 内）：

- `of.refs <= 0` 且 `now - of.lastCheck > 3600*12`（**12 小时**空闲）⇒ `of.release()` + `delete(o.files, ino)`
- 或 `len(o.files) > o.limit`（`--open-cache-limit`，默认 **10000**，`cmd/flags.go:407`）⇒ 按 `lastCheck` 最旧的挑一个淘汰

`release()`（`:35--42`）把 `chunks = nil`、`first = nil`，并把 `openFile` 放回 `ofPool` 复用。

**⇒ 不会一直加下去，有三重上界：**

1. 每次写就删掉对应 chunk 条目（路径 1）；
2. 缓存的**文件数**受 `--open-cache-limit = 10000` 硬约束；
3. 12 小时空闲自动回收。

**⚠️ 但对 randrw 而言，这个缓存几乎完全无用。** 路径 1 意味着：每次 `Write` 提交都删掉刚刚缓存的那条列表。读写交替打同一批 chunk 时，命中率趋近 0。这与 C-12 实测「每 256K 写 ≈1.04--1.07 次元数据事务」是自洽的 —— 如果 slice 列表缓存有效，事务数应该显著低于写次数。

⚠️ 另需注意：`ReadChunk` **不检查过期时间**，所以 slice 列表缓存跟 `--open-cache`（默认 `0s`）无关，一直生效；`--open-cache` 只影响 `Check()`（属性缓存，`:165--177`）。这与 §2.1 的结论一致。

### Q9 为什么一次点查得到的是 `N × 24` 字节？给 TiKV 的是什么，拿回来的是什么？

**核心：一个 chunk 的全部 slice 记录被打包成一个 value，不是 N 个 KV。** 所以一次点查拿回一个字节串，长度必然是 24 的整数倍。

**给数据库的 key**（`pkg/meta/tkv.go`）：

```go
func (m *kvMeta) chunkKey(inode Ino, indx uint32) []byte {
    return m.fmtKey("A", inode, "C", indx)
}
```

`fmtKey`（`:171--191`）按类型逐段拼二进制：

| 段 | 内容 | 字节数 |
|---|---|---|
| `"A"` | 字面前缀（inode 相关命名空间） | 1 |
| `inode` | `m.encodeInode(a, b.Get(8))` | 8 |
| `"C"` | 字面标记（chunk 命名空间） | 1 |
| `indx` | `b.Put32(a)` | 4 |
| | **合计** | **14 字节** |

**拿回来的 value**：`tkv.go:2624--2630`

```go
func (m *kvMeta) doRead(ctx Context, inode Ino, indx uint32) ([]*slice, syscall.Errno) {
    val, err := m.get(m.chunkKey(inode, indx))     // ← 一次点查，一个 value
    if err != nil { return nil, errno(err) }
    return readSliceBuf(val), 0                    // ← 客户端按 24 字节切分
}
```

`readSliceBuf`（`slice.go:118--131`）先校验 `len(buf) % sliceBytes != 0` 则报 `corrupt slices`，再每 24 字节切一条。

⚠️ TiKV 是**有序** KV（支持范围扫描，不只是哈希表）—— 这一点被用在别处（如 `doList` 用 `scanValues(m.fmtKey("A", inode, "C"), ...)` 扫一个 inode 的全部 chunk），但 `doRead` 只用点查。

**★ 这个"打包成一个 value"的设计有一个隐藏放大，值得记录：**

写入也是**整值改写**（`tkv.go doWrite`）：

```go
rs := tx.gets(m.inodeKey(inode), m.chunkKey(inode, indx))   // 读回整个 value
...
for i := 0; i < len(rs[1]); i += sliceBytes {               // ★ 线性去重扫描
    if bytes.Equal(rs[1][i:i+sliceBytes], val) { ...; return nil }
}
val = append(rs[1], val...)                                 // 追加
tx.set(m.chunkKey(inode, indx), val)                        // 写回整个 value
```

⇒ **chunk 内 slice 越多，每次写要读写的 value 越大，且去重扫描是 O(N)。** 06-1 实测单格产生约 50 万 slices（C-9.4/C-9.5：C1-post `507,597 slices`）。若某个 64 MiB chunk 堆积 1000 个 slice，value 就是 24 KB，每次写都要读回 24 KB + 线性扫 1000 条 + 写回 24 KB。

**这解释了三件事：**

1. 为什么 compaction 不可缺 —— 它就是把 N 条 slice 合并回少数几条；
2. 为什么 06-3 取消归一门后 pending-compaction 从 `0` 涨到 `45.64 GiB`（C-9.5）会带来性能后果，而不只是"空间没回收"；
3. 为什么 C-9 的四 RUN 对照里，**有归一门的 RUN 离散度低一个数量级**（04-tmp2j 2.2% / 06-1 0.13% vs 06-3 单调 +15%）。

### Q10 那条 24 字节记录什么时候生成？数据写来了不就该能确定了吗？

**用户的直觉在本几何下几乎成立，但有一个具体的、可指认的障碍：slice 在写完后仍保持 growable，所以 `Size`/`Len` 尚未定。** 逐步说明：

**① 物理生成时刻**：在元数据事务内 —— `tkv.go:2680 val := marshalSlice(off, slice.Id, slice.Size, slice.Off, slice.Len)`。

**② 逻辑内容确定时刻**：`writer.go:214`

```go
var ss = meta.Slice{Id: s.id, Size: s.length, Off: s.soff, Len: s.slen}
```

其中 `s.length` 直到 `flushData` 才赋值（`writer.go:128 s.length = s.slen`）⇒ **必须先冻结（freeze）。**

**③ 为什么写完一个 256 KiB 块还不冻结**（`writer.go:149--160`）：

```go
if s.slen == meta.ChunkSize {          // 只有写满整个 64 MiB chunk 才冻结
    s.freezed = true
    go s.flushData()
} else if int(s.slen) >= f.w.blockSize {   // 256 KiB：只上传 block，不冻结
    if s.id > 0 { err := s.writer.FlushTo(int(s.slen)) }
}
```

⇒ 本几何（一次写 256 KiB = 恰好一个 block）走的是 `else if` 分支：**block 上传了，slice 仍 growable**，`s.slen` 理论上还能长 ⇒ `Size`/`Len` 未定 ⇒ 记录未定。

**④ 谁会让它继续增长？几乎没人。** `findWritableSlice`（`writer.go:171--190`）：

```go
flushoff := s.slen / blockSize * blockSize
if pos >= s.off+flushoff && pos <= s.off+s.slen { return s }   // 只有严格紧邻追加才复用
```

随机写基本不可能命中这个条件 ⇒ 实际上不会增长。

**⑤ 那它什么时候才冻结？三个都是"迟到"的触发：**

| 触发 | 源码 | 延迟 |
|---|---|---|
| 被 4 个更新的 slice 挤到后面 | `writer.go:178 else if i > 3 { s.freezed = true; go s.flushData() }` | 取决于写速率 |
| 超过 `flushDuration` | `writer.go:506`，`flushDuration = 5s`（`:32`） | 最多 **5 秒** |
| 被 `Flush` 强制 | `writer.go:408--410` | 即 M1 |

**⑥ 所以正确结论**：记录之所以不能立刻确定，**唯一障碍是 slice 保持 growable 等待可能的紧邻追加**。而这个障碍在本几何下是**纯浪费** —— 追加永远不会来。

⇒ 这给出了 range-flush 之外的**第二个候选方向：提前冻结（eager freeze）**。改动极小 —— 只需在 `writer.go:149` 增加条件，对「本次写恰好填满一个 block 且 slice 起点对齐」的情形立即 `s.freezed = true`。这样记录即刻可定、slice 立即进入提交队列，M1 要等的队列大幅缩短。

⚠️ **但必须先算元数据账**：eager freeze 会让 slice 无法再合并紧邻写 ⇒ 其他负载（尤其顺序写）的 slice 数与元数据事务数会上升。而 C-12 已实测 06-1 T 臂元数据通道利用率已达 **52--57%**，余量不多。**对纯随机覆盖写本身几乎无副作用**（本来就不合并），但作为通用改动风险不明。登记为 M-46（候选，未评估，⛔ 不得在未算账前提交任务书）。

### Q11 本地缓存用什么方式保存数据？也是键值对吗？依赖那 24 字节记录吗？

**不是键值数据库，是「普通文件 + 内存索引」。而且完全不依赖那 24 字节记录。**

**① 磁盘上：一个 block = 一个文件，路径由对象名直接拼出**

```go
// disk_cache.go:51--52
stagingDir = "rawstaging"
cacheDir   = "raw"
// :729 / :733
func (cache *cacheStore) cachePath(key string) string { return filepath.Join(cache.dir, cacheDir, key) }
func (cache *cacheStore) stagePath(key string) string { return filepath.Join(cache.dir, stagingDir, key) }
```

`key` 就是对象名，于是实际路径形如：

```
<cache-dir>/<UUID>/raw/chunks/5/5257/5257621_0_262144           ← 读缓存
<cache-dir>/<UUID>/rawstaging/chunks/5/5257/5257621_0_262144     ← WB 暂存
```

对象名里那两级目录（`id/1e6`、`id/1e3`）在这里直接变成**文件系统目录**，正是为了不让单目录塞进千万个文件（§3 Q5）。

**② 写入方式：写临时文件 → 换名，全程无 fsync**（`disk_cache.go:444--529 flushPage`）

```
os.OpenFile(path + ".tmp", O_WRONLY|O_CREATE)
  → writeFile(f, data)
  → [可选] writeFile(f, checksum(data))        ← --verify-cache-checksum
  → [可选] writeFile(f, stageFooter)           ← tierID != 0，仅暂存文件有 footer
  → [可选] dropOSCache(f)                      ← posix_fadvise(DONTNEED)
  → closeFile(f)
  → renameFile(tmp, path)                      ← 原子换名
```

全文搜 `Sync()` / `Fsync` **零命中** ⇒ 这是 §2.2 耐久性缺口与 §4 Q4「突发式 writeback」的共同根源。

**③ 读取方式**：`bcache.load(key)` 打开该文件 → `r.ReadAt(p, boff)` **普通 buffered pread** ⇒ 真实供给方是宿主 page cache（C-5，本轮 iostat `rkB/s = 0.00` 再次确证）。

**④ 内存索引：有，但它的键不是字符串**

```go
// disk_cache.go:60--64
type cacheKey struct { id uint64; indx uint32; size uint32 }     // 16 字节
// cache_eviction.go:34--37
type cacheItem struct { size int32; atime uint32 }               // 8 字节
```

`cacheStore.keys KeyIndex`（接口在 `cache_eviction.go:39`）维护 `cacheKey → cacheItem`。`getCacheKey(key)`（`disk_cache.go:603--`）用**手写十进制解析**把对象名字符串拆成这个 16 字节结构 —— 纯内存优化，几十万个 block 的索引只占十几 MB。

两个细节：

- `cacheItem.size` **为负值表示「暂存中、不计入 `--cache-size` 额度」**（`:802 cache.add(key, -int32(len(data)), ...)`），上传成功后 `:810 uploaded()` 翻成正值。这正是 C-7.4b 里「负值不占 cache-size 但入 keys 索引 ⇒ 立即可命中」的实现。
- 索引不持久化：进程启动后 `scanCached`（`:949--1010`）遍历缓存目录重建，`:1009 cache.scanned = true`；之后按 `--cache-scan-interval` 周期性 `refreshCacheKeys`（`:418`）。

**⑤ 直接回答「所以依赖作为键的 24 字节记录吗」——不依赖。** 两者是完全不同的东西：

| | 元数据引擎里的 24 字节 slice 记录 | 本地缓存的键 |
|---|---|---|
| 是什么 | `{pos, id, size, off, len}` | 对象名字符串 / 解析后的 `cacheKey{id, indx, size}` |
| 存在哪 | TiKV，`chunkKey(inode, indx)` 的 value 内 | 缓存盘的文件路径 + 客户端内存索引 |
| 作用 | 告诉读端「该取哪个 id、取哪一段、贴到 chunk 哪里」 | 定位一个具体的不可变数据块 |

读端一旦从 24 字节记录里拿到 `{Id, Size, Off, Len}`，**它自己就能算出对象名**（`cached_store.go:74--79`），缓存查找完全不需要再碰元数据。

⇒ **这恰好是 §3 Q6/Q7 的结论：缺的是"知道该取哪个 key"这条索引项，不是缓存的寻址能力，也不是数据本身。**

---

## §4B 第三轮问答（读缓存内容 / 官方原文出处 / TiKV key 结构）

### Q1 读缓存中只保存数据吗，还是同时保存数据和元数据？

**只保存数据。缓存目录里没有任何 JuiceFS 文件系统元数据。** 但一个缓存文件里除了数据 payload，还可能有两段**缓存自身的**完整性/分层信息 —— 严格说这也算"元数据"，只是与文件系统元数据完全无关。

**① 一个缓存文件的确切内容**（`pkg/chunk/disk_cache.go:444--529 flushPage`，按写入顺序）：

```
[ block 数据 payload ]                     ← 唯一的"数据"
[ CRC32C 校验尾     ]   当 --verify-cache-checksum != none（默认 extend）
[ stageFooter       ]   仅当 tierID != 0（分层存储），且只有暂存文件有
```

对应代码：

```go
err = cache.writeFile(f, data)                                  // 数据
if cache.checksum != CsNone {
    err = cache.writeFile(f, checksum(data))                    // :545--547 校验尾
}
if tierID != 0 {
    // only staged file has a footer
    fData, err = (&footer).marshal(cache.checksum != CsNone)    // :551--560
    err = cache.writeFile(f, fData)
}
```

**校验尾有多大**（`disk_cache.go:1458--1471 checksum()`）：按 `csBlock = 32 KiB`（`:1353`）分段算 CRC32C，每段 4 字节。

```
256 KiB block → (262144-1)/32768 + 1 = 8 段 → 8 × 4 = 32 字节   （开销 0.012%）
```

⚠️ **06-3 归档的 `commands.sh` 里 `verify-cache-checksum` 命中数为 0** ⇒ 用的是默认值 `extend`（`cmd/flags.go:263--265`）⇒ **我们的缓存文件确实带这 32 字节尾**，磁盘上每个文件实际 262,176 字节。这一点此前未记录，对容量记账影响可忽略（0.012%），但对"缓存文件大小是否等于 BlockSize"的核对有意义。

**② 缓存目录里只有两棵树**（`disk_cache.go:51--52`、`:729`、`:733`）：

```
<cache-dir>/<UUID>/raw/chunks/...           ← 读缓存
<cache-dir>/<UUID>/rawstaging/chunks/...    ← --writeback 暂存
```

**没有** inode 属性、**没有** dentry、**没有** slice 列表、**没有** xattr。⇒ 官方文档也是这么定义的（`docs/zh_cn/guide/cache.md:24`）：「本地数据缓存缓存也是**以对象存储的数据块做为最小单元**」。

**③ 有一份"关于缓存的元数据"，但只在内存、不落盘**

```go
// disk_cache.go:60--64
type cacheKey  struct { id uint64; indx uint32; size uint32 }   // 16 字节
// cache_eviction.go:34--37
type cacheItem struct { size int32; atime uint32 }              // 8 字节
```

`cacheStore.keys KeyIndex` 维护 `cacheKey → cacheItem`，用于淘汰决策与容量记账（`size` 为负值 = 暂存中、不占 `--cache-size`）。**不持久化** —— 进程启动后由 `scanCached`（`:949--1010`）遍历目录重建，`:1009 cache.scanned = true`。

**④ 文件系统元数据的缓存在完全另外的地方，都不落盘、都不占 `--cache-size`**（§2.1 已列）：

| 缓存的元数据 | 位置 | 是否落盘 |
|---|---|---|
| attr / entry / dir-entry / negative-entry / readdir | 内核 | ❌ |
| `openFile.attr` + `openFile.chunks`（slice 列表） | 客户端进程内存 | ❌ |

**⇒ 一句话：`--cache-size` 管的每一个字节都是数据块；元数据一个字节都不进缓存盘。** 唯一的"额外内容"是每块 32 字节的 CRC 校验尾，属缓存自身完整性保护。

### Q2 Q7 所引官方原文的绝对路径

**两份副本行号完全一致**（已逐条核对），推荐引用持久副本：

| | 绝对路径 | 版本 | 持久性 |
|---|---|---|---|
| 权威 | `/tmp/opencode/docs/zh_cn/guide/cache.md` | **1.4.1**（冻结母本解包） | ⚠️ `/tmp`，重启即失 |
| **建议引用** | `/mnt/c/SunRise/github/juicefs/docs/zh_cn/guide/cache.md` | 1.4.0-dev-467-g44dd412a | ✅ 持久 |

英文版对应：`/tmp/opencode/docs/en/guide/cache.md` 与 `/mnt/c/SunRise/github/juicefs/docs/en/guide/cache.md`。

**五条引文的逐条出处（中文版）：**

| # | 路径:行 | 原文 |
|---|---|---|
| 1 | `…/docs/zh_cn/guide/cache.md:18` | 「分布式系统，往往需要在**缓存和一致性之间进行取舍**。JuiceFS 由于其元数据分离架构，需要从元数据、文件数据（对象存储）、文件数据本地缓存三方面来思考一致性问题：」 |
| 2 | `…/docs/zh_cn/guide/cache.md:22` | 「对于对象存储，JuiceFS 将文件分成一个个数据块（默认 4MiB），赋予唯一 ID 并上传至对象存储服务。**文件的任何修改操作都将生成新的数据块，原有块保持不变，所以不用担心数据缓存的一致性问题**，因为一旦文件被修改过了，JuiceFS 会从对象存储读取新的数据块。……」 |
| 3 | `…/docs/zh_cn/guide/cache.md:24` | 「[本地数据缓存](#client-read-cache)缓存也是**以对象存储的数据块做为最小单元**。一旦文件数据被下载到缓存盘，一致性就和缓存盘可靠性相关，如果磁盘数据发生了篡改，客户端也会读取到错误的数据。对于这种担忧，可以配置合适的 `--verify-cache-checksum` 策略，确保缓存盘数据完整性。」 |
| 4 ★ | `…/docs/zh_cn/guide/cache.md:72`（§一致性例外 第 3 条，节标题在 `:66`） | 「调用 `write` 成功后，挂载点自身立刻就能看到文件长度的变化（比如用 `ls -al` 查看文件大小，可能会注意到文件不断变大）——但这并不意味着修改已经成功提交，**在 `flush` 成功前，是不会将这些改动同步到对象存储的，其他挂载点也看不到文件的变动**。调用 `fsync, fdatasync, close` 都能触发 `flush`，让修改得以持久化、对其他客户端可见。」 |
| 5 | `…/docs/zh_cn/guide/cache.md:133` + `:137`（§内核页缓存，节标题在 `:131`） | `:133`「对于已经读过的文件，内核会为其建立页缓存（Page Cache），下次再打开的时候，如果文件没有被更新，就可以直接从内核页缓存读取，获得最好的性能。」<br>`:137`「当重复读 JuiceFS 中的同一个文件时，**速度会非常快，延时可低至微秒，吞吐量可以到每秒几 GiB**。」 |

⚠️ **我此前把第 4 条写成 `:70`、第 5 条写成 `:133--135`，都错了。** 正确是 `:72` 与 `:133`+`:137`（`:70` 是"内核元数据缓存主动失效"那条，`:135` 是"客户端跟踪最近打开的文件"那条）。已在本文档 §4 Q7 表、§5.4 M-43、附录 A.7 三处订正。

**§2.2 引用的英文版行号同步订正**（原写 `:190`、`:196--197`）：

| 路径:行 | 原文 |
|---|---|
| `…/docs/en/guide/cache.md:185` | "the default **upload first, then commit** write process … After the client write cache is enabled, the write process becomes **commit first, then upload asynchronously**" |
| `…/docs/en/guide/cache.md:191` | "Disk reliability is crucial to data integrity, **if write cache data suffers loss before upload is complete, file data is lost forever**." |
| `…/docs/en/guide/cache.md:197` | "If object storage upload speed is too slow …, **meanwhile reads from other nodes will result in timeout error (I/O error)**." |
| `…/docs/en/guide/cache.md:139` / `:143` | writeback-cache 节；`:143` 明确澄清它与 `--writeback` 是两回事（中文版对应 `:139` / `:141` / `:143`） |

**复算命令：**

```bash
D=/mnt/c/SunRise/github/juicefs/docs
grep -n '缓存和一致性之间进行取舍\|不用担心数据缓存的一致性\|以对象存储的数据块做为最小单元\|在 `flush` 成功前\|内核会为其建立页缓存\|延时可低至微秒' $D/zh_cn/guide/cache.md
grep -n 'upload first, then commit\|lost forever\|result in timeout error\|not the same as' $D/en/guide/cache.md
```

### Q3 给 TiKV 的那个 key 到底是什么含义？

**首先更正一处：实际发给 TiKV 的 key 不是 14 字节，是 27 字节。** 14 字节只是 `fmtKey()` 的输出，TiKV 客户端还会在前面加一段卷前缀。

**① 卷前缀（我上一轮漏了）** —— `pkg/meta/tkv_tikv.go:117--118`：

```go
prefix := strings.TrimLeft(tUrl.Path, "/")
return withPrefix(&tikvClient{...}, append([]byte(prefix), 0xFD)), nil
```

`prefixTxn.realKey()`（`pkg/meta/tkv_prefix.go:30--35`）在**每一次** get/set/scan 前都把它拼到最前面：

```go
func (tx *prefixTxn) realKey(key []byte) []byte {
    k := make([]byte, len(tx.prefix)+len(key))
    copy(k, tx.prefix)
    copy(k[len(tx.prefix):], key)
    return k
}
```

本卷元数据 URL 是 `tikv://…/juicefs-prod` ⇒ `tUrl.Path = "/juicefs-prod"` ⇒ 前缀 = `"juicefs-prod"`（12 字节）+ `0xFD`（1 字节分隔符，防止卷名互为前缀而冲突）= **13 字节**。

**② 完整 key 布局（27 字节）**

```
┌────────────────────────┬──────┬───┬──────────────────┬───┬──────────────┐
│ "juicefs-prod"  (12B)  │ 0xFD │'A'│ inode  (8B, LE)  │'C'│ indx (4B, BE)│
└────────────────────────┴──────┴───┴──────────────────┴───┴──────────────┘
  └──── 卷前缀 13 字节 ────┘ └────────── fmtKey 输出 14 字节 ──────────────┘
```

| 偏移 | 长度 | 内容 | 含义 | 来源 |
|---|---|---|---|---|
| 0--11 | 12 | `juicefs-prod` | 卷名，多卷共用一个 TiKV 集群时隔离 | `tkv_tikv.go:117` |
| 12 | 1 | `0xFD` | 卷前缀分隔符 | `tkv_tikv.go:118` |
| 13 | 1 | `'A'`（0x41） | **一级命名空间：inode 相关** | `chunkKey` → `fmtKey("A", …)` |
| 14--21 | 8 | inode 号，**小端** | 哪个文件 | `encodeInode`（显式 `binary.LittleEndian`） |
| 22 | 1 | `'C'`（0x43） | **二级命名空间：file chunks** | 同上 |
| 23--26 | 4 | chunk 序号 `indx`，**大端** | 文件内第几个 64 MiB | `Put32`，`utils.FromBuffer` 固定 `binary.BigEndian` |

**③ 完整键空间在源码里有正式文档** —— `pkg/meta/tkv.go:192--227`：

```
  Ino     iiiiiiii          ← 8 字节
  Length  llllllll
  Indx    nnnn              ← 4 字节
  name    ...
  sliceId cccccccc
  session ssssssss
  aclId   aaaa

All keys:
  setting            format
  C...               counter                 ← 如 nextInode / nextChunk
  AiiiiiiiiI         inode attribute
  AiiiiiiiiD...      dentry
  AiiiiiiiiPiiiiiiii parents // for hard links
  AiiiiiiiiCnnnn     file chunks             ← ★ 我们这个
  AiiiiiiiiS         symlink target
  AiiiiiiiiX...      extented attribute
  Diiiiiiiillllllll  delete inodes
  Kccccccccnnnn      slice refs
  Lttttttttcccccccc  delayed slices
  SEssssssss / SHssssssss / SIssssssss       ← session 过期/心跳/信息
  SSssssssssiiiiiiii sustained inode
  Uiiiiiiii          data length, space and inodes usage in directory
  QDiiiiiiii         directory quota
  ...
```

所以 `'A'` 和 `'C'` 不是随意取的字母，是这套两级命名空间的固定标签：**`A` 表示"挂在某个 inode 下的东西"，第二个字母区分是属性（`I`）、目录项（`D`）、chunk（`C`）、符号链接（`S`）还是扩展属性（`X`）。** 一个 inode 的所有相关数据共享 `A + inode8` 这 9 字节前缀。

**④ ★ 字节序的不对称是有意设计，值得单独记一条**

| 字段 | 字节序 | 代码 | 目的 |
|---|---|---|---|
| inode | **小端**（LittleEndian） | `tkv.go encodeInode` 显式指定 | 相邻 inode 号在**首字节**就不同 ⇒ key 散布到不同 TiKV region ⇒ **避免单调递增 inode 造成写热点**（标准 TiKV/HBase 反热点手法） |
| indx | **大端**（BigEndian） | `utils.FromBuffer` 固定 BigEndian | 同一 inode 的 chunk 按序号**字典序相邻且有序** |

大端 `indx` 的直接用途：`doList` 可以对 `fmtKey("A", inode, "C")` 做一次范围扫描，按 `indx` 升序拿到该文件全部 chunk：

```go
vals, err := m.scanValues(ctx, m.fmtKey("A", inode, "C"), -1, nil)
```

⇒ 两个选择合起来是「**跨文件打散、同文件聚集**」。

⚠️ 这可能也是 C-12 未观察到单 region 元数据热点的原因之一（**推断，未验证**）：128 个测试文件的 inode 由 `nextInode` 连续分配，若 inode 用大端编码，它们的 chunk key 会全挤在一小段 keyspace；小端编码把它们散开了。若将来要专门测元数据侧瓶颈，这一点需要单独设计观测（TiKV per-region 指标），已并入 §5.5 的 R-22。

**⑤ 与 §4 Q9 的衔接**：这个 27 字节 key 对应的 **value 是该 chunk 全部 slice 记录的拼接**（N × 24 字节），不是一条。所以一次点查拿回整个 slice 列表；而每次写也要**读回整个 value → O(N) 线性去重扫描 → 写回整个 value**（`tkv.go doWrite`）—— 这是 compaction 不可缺的根本原因。

---

## §4C 第四轮问答（缓存索引结构 / 失效与替换机制）

### Q1 读缓存是通过一级级本地目录来索引的吗？

**一半对。路径确实是由 key 直接拼出来的（目录寻址），但"在不在"是内存哈希表判断的，目录层级完全不参与索引。**

`bcache.load(key)`（`pkg/chunk/disk_cache.go:668--697`）是**三层**，磁盘是最后一层：

```go
func (cache *cacheStore) load(key string) (ReadCloser, error) {
    cache.Lock()
    defer cache.Unlock()
    if p, ok := cache.pages[key]; ok {              // ① 内存待落盘页
        return NewPageReader(p), nil
    }
    k := cache.getCacheKey(key)
    if cache.scanned && cache.keys.get(k) == nil {  // ② 内存索引：不在就直接返回
        return nil, errNotCached                    //    ⇒ 不产生任何 syscall
    }
    cache.Unlock()
    ...
    f, err = openCacheFile(cache.cachePath(key), parseObjOrigSize(key), cache.checksum)   // ③ 才开文件
```

| 层 | 是什么 | 作用 |
|---|---|---|
| ① `cache.pages[key]` | 已准入但**还没落盘**的内存页（就是准入队列里的内容） | **准入后立即可命中** —— 这是 CLW/WB 刚写入就能命中的原因 |
| ② `cache.keys KeyIndex` | 内存哈希表 `cacheKey{id,indx,size}` → `cacheItem{size,atime}` | **命中判定 + 容量记账 + 淘汰决策**。miss 时避免一次 `open()` syscall |
| ③ 磁盘文件 | 路径 = `cachePath(key)` = `filepath.Join(cache.dir, "raw", key)`（`:729`） | 实际数据 |

**寻址是纯计算，不是查找。** 读端拿到 `{Id, Size, Off, Len}` 后：

```
(id, indx, size) ──cached_store.go:74--79──> "chunks/5/5257/5257621_0_262144"
                 ──disk_cache.go:729───────> <cache-dir>/<UUID>/raw/chunks/5/5257/5257621_0_262144
```

**不需要遍历目录、不需要 LIST、不需要任何查找。** 那两级目录（`id/1e6`、`id/1e3`）**纯粹是为了限制单目录条目数** —— 06-3 实测缓存里同时有 **387,147** 个块（见下），若全塞进一个目录，ext4 的目录项查找与 `readdir` 都会退化。它不承担索引功能。

⚠️ 注意 ② 的 `cache.scanned` 守卫：进程刚启动、`scanCached`（`:949--1010`）还没扫完时，`scanned == false`，此时**跳过索引直接试开文件** —— 所以冷启动阶段每次 miss 都会付一次失败的 `open()`。

### Q2 缓存对应的文件范围被修改后，缓存怎么失效？新缓存怎么替代旧缓存？

**核心答案：缓存永远不会"失效"，因为它不可能变脏。也不存在"替代"——新旧共存，旧的变垃圾。**

**① 修改时实际发生什么**

```
应用写 256 KiB 到 off = 100 MiB
  │
  ├─ 新建 sliceWriter，立刻分配新 slice id（如 5,257,622）     writer.go:290
  ├─ 数据上传到新对象名  chunks/5/5257/5257622_0_262144        cached_store.go:74--79
  ├─ 准入到缓存 → 新文件 <cache-dir>/<UUID>/raw/chunks/5/5257/5257622_0_262144
  └─ 元数据 chunk 值尾部追加一条 24 字节记录                    tkv.go doWrite

旧的 chunks/5/5257/5257621_0_262144：
  ├─ 缓存文件还在，内容一个字节都没变
  ├─ 但 buildSlice 展平后新记录在后、覆盖旧记录 ⇒ 读端再也不会请求这个 key
  └─ ⇒ 变成垃圾，但仍然占着 --cache-size 额度
```

**⇒ 没有失效协议，因为不需要。** 官方文档就是这么定义的（`docs/zh_cn/guide/cache.md:22`）：

> 文件的任何修改操作都将生成新的数据块，原有块保持不变，**所以不用担心数据缓存的一致性问题**

**这是 content-addressed + 不可变 + slice id 永不复用三者的必然结果**：一个 key 的内容永远不变 ⇒ 缓存里的东西**不可能是脏的**，只可能是**死的**。死条目不会被误读，因为没有任何 slice 列表指向它。

**② 那旧文件怎么被清掉 —— 三条路径，只有一条精确**

| 路径 | 触发条件 | 精确性 | 代码链 |
|---|---|---|---|
| **A. 显式删除** | 元数据侧真正删除该 slice（**GC / compaction / 回收站到期**） | ✅ **精确删这一个** | `base.go:2985 deleteSlice_` → `newMsg(DeleteSlice)` → `cmd/mount.go:319--321 store.Remove(id,size)` → `cached_store.go:187 rSlice.Remove()` → 逐块 `bcache.remove(key, true)` + `store.delete(key)`（删对象存储） |
| **B. 容量淘汰** | `add()` 时 `full()`，即 `used > capacity` | ❌ 近似随机 | `disk_cache.go:777 add` → `:779 cleanupFull()` → `:830`，目标降到 `capacity × 95/100`，每淘汰一个 `cacheEvicts.Add(1)` |
| **C. 过期淘汰** | `--cache-expire` 到期 | ❌ 按 atime | `disk_cache.go:374 cleanupExpire` |
| （D. 完整性剔除） | 读到损坏块（CRC 校验失败或部分读） | ✅ 精确，但非常规 | `cached_store.go:147 bcache.remove(key, false)` |

**淘汰策略**（`cache_eviction.go:27--29`，可选 `none` / `2-random` / `lru`），默认 **`2-random`**（`cached_store.go:622`/`:625`）。`randomEviction.evictionIter()` 的实现是遍历 Go map（**遍历顺序随机**）比较 `atime` 取较旧者 ⇒ **近似 LRU，不是精确 LRU**。且有一句关键守卫：

```go
if value.size < 0 {
    continue // staging        ← 未上传的暂存块不参与淘汰
}
```

**③ ★ A 路径的一个重要性质：它只在执行删除的那个客户端上发生**

其他客户端缓存里的同一个块**永远收不到通知**。但这是**安全的** —— 因为 key 是内容寻址且不可变，一个死条目不可能被当成有效数据（没有 slice 列表指向它）。它只是垃圾，不是脏数据。

⇒ 这也是 JuiceFS 敢完全不做缓存失效协议的根本原因，代价就是**垃圾回收必须由元数据侧驱动**。

**④ ★ 与 06-3 的直接关联：缓存被填到了 99.995%**

用 `add()` 的容量记账公式（`disk_cache.go:775 cache.used += int64(size + 4096)`，每块额外记 4096 字节的 inode/目录开销）反推 06-3 S1：

```
387,147 块 × (262,144 + 4,096) = 103,074,017,280 字节
实测 juicefs_blockcache_bytes  = 103,074,017,280 字节     ← 逐字节相符 ✓

--cache-size 98304 MiB = 96 GiB = 103,079,215,104 字节
可容纳块数 = 103,079,215,104 / 266,240 = 387,166 块
实测峰值   = 387,147 块  ⇒  99.995%（差 19 块）
```

**⇒ 缓存被填到距绝对上限只差 19 个块。** 结合 `evicts/writes = 79--87%`，这是 **C-16 的定量铁证**：缓存在整个正式窗内持续处于「满 → 淘汰到 95% → 立刻被新块填满」的抖动循环。

**⑤ 一个新发现的叠加因素（建议记为 M-47）**

06-3 按任务书 §四 明令**禁止 GC/compact**（全归档零命中，C-9）。而路径 A 是**唯一精确**的垃圾回收通道，它由元数据侧的 slice 删除驱动。⇒ **06-3 期间 `DeleteSlice` 消息几乎不发，缓存里的死块完全没有精确回收，只能靠路径 B 的近似随机淘汰硬撑。**

这意味着取消归一门伤了**两处**，此前只记了一处：

| | 后果 | 记录状态 |
|---|---|---|
| 元数据侧 | pending-compaction `0 → 45.64 GiB`；chunk value 膨胀 + `doWrite` 的 O(N) 去重扫描变慢 | ✅ 已记（C-9.5、§4 Q9） |
| **缓存侧** | **死块无精确回收，只剩 2-random 随机淘汰** ⇒ 有效缓存容量进一步缩水，加剧 C-16 抖动 | ❌ **本轮新增** |

⚠️ **限定**：写入洪流（132.8 GiB/格 > 96 GiB）本身已足以造成抖动，所以这是**加剧因素而非主因**；且缺 GC 的情形下无法从 06-3 数据反推"若有 GC 会好多少"。⛔ 不得当作可量化收益。若要验证，需要一格「有归一门 + CLW」的对照 —— 这正好是 06-1 与 06-3 之间未被覆盖的组合。

---

## §5 撤销与新增清单（待并入 `06-STAGE-STATUS-20260917.md`）

### 5.1 撤销（全部是本会话早期我自己的错误论断，⛔ 禁止再作论据）

编号沿用 C-13 撤销清单，接在既有 ①--⑥ 之后：

| 编号 | 撤销内容 | 更正为 | 发现者 |
|---|---|---|---|
| ⑦ | 「读缓存命名空间里根本没有能指代 pending 数据的名字」 | **名字与数据（WB 下）都有**；缺的是 chunk slice 列表里那条 24 字节索引记录。该说法仅对「slice 尾部未满的 block」成立 | 用户（Q7） |
| ⑧ | 「pending slice 的次序直到提交那一刻才落定」 | 同客户端内次序在 `writer.go:291 append` 时即完全确定，`commitThread` 只是执行者；**仅跨客户端不可知**，而 POSIX 本就不保证无锁并发同址写 | 用户（Q8/Q9） |
| ⑨ | 「顺序未定是读必须 flush 的主要理由」 | 真实成本是：①读路径需拿 `fileWriter.Mutex`（randrw 下成热锁）②未冻结 slice 尾部 block 只在内存 ⇒ 需第二套数据源 ③跨客户端 overlay 破坏 close-to-open 语义 | 用户（Q8） |
| ⑩ | 「randrw 读延迟 = `max`(缓存命中延迟, flush 延迟)」 | **是串行相加**（`vfs.go:789` 然后 `:790`）。且两项差 150--185 倍（缓存命中读 0.11 ms vs PUT 20.7 ms）⇒ 相加的表述比 `max` 更强地支持阻断二 | 用户（Q2） |
| ⑪ | 阻断三的原证据「缓存盘写 600--624 MiB/s + `%util` 峰 100.40%」 | **证据错误**：`600--624` 是含空闲的整窗均值；`%util` 对多队列 NVMe 无意义。**换用 `w_await` 中位 49--50 ms、`aqu-sz` 中位 318--332、活跃写中位 1608 MiB/s 后，结论反而更强** | 用户（Q3） |

### 5.2 既有结论的证据口径更正

| 结论 | 原表述 | 更正 |
|---|---|---|
| **C-5** | 「06-3 S/W 臂 nvme1n1 ……写 `600–706 MiB/s`、util 峰 `100.40%`」 | 应分列两个口径：**整窗均值 622.5（S1）/ 691.1（W1）MiB/s**；**活跃期（`wkB/s>100MiB/s`）中位 1608.3 / 1606.8 MiB/s，`w_await` 中位 49.04 / 50.06 ms，`aqu-sz` 中位 317.6 / 331.9**。⛔ 不得再单独引用 `%util` 作为压力证据。C-5 的「介质读为零」部分**不变且再次确证**（活跃样本 `rkB/s` 最大值 `0.00`） |

### 5.3 新增结论（建议编号 C-15 / C-16 / C-17）

| 编号 | 结论 | 证据 |
|---|---|---|
| **C-15** | **缓存准入被大量静默丢弃。** 06-3 正式窗 `cache_drops`：S1 302,759（丢弃率 **35.85%**）、S2 239,562（**31.19%**）、W1 50,788（6.84%）、W2 51,116（7.05%）、C 臂 0。根因是 `pendingPages = BufferSize×2/10/BlockSize/len(dirs) = 240 块 = 60 MiB`（`cached_store.go:1172`），仅够缓冲 38 ms，而缓存盘 `w_await` 中位 49 ms ⇒ 结构性溢出。源码注释直接写明：`disk_cache.go:474 // does not have enough bandwidth to write it into disk, discard it`。另一处 drop 分支 `:450` 需 `rawFull && EvictionNone`，06-3 不满足 ⇒ **全部丢弃来自带宽不足** | `analysis.json` `mechanism.counter_deltas.cache_drops`（**06-3 报告从未使用**）；`iostat-1hz.tsv` 重算 |
| **C-16** | **新块洪流单格即超过缓存容量 ⇒ 缓存必然抖动。** S/W 臂 `--cache-size 98304` = **96 GiB**；单格 180 s 产生全新 block：S1 `put_count 544,032` = **132.8 GiB** > 96 GiB。实测 `evicts/writes = 79--87%`（S1 79%、W1 87%、W2 86%、S2 81%）⇒ 写进去的绝大部分同窗口内被淘汰。**这是 COW 的直接后果**：每次覆盖写生成新 slice/新 block/新对象名，旧 block 因在 `buildSlice` 被覆盖而逻辑死亡却仍占额度。⇒ **「加大 `--cache-size` 对 randrw 无效」的最根本架构原因** | `analysis.json` `counter_deltas`；归档 `commands.sh` 确认 `cache-size 98304` × 4 格 / `cache-size 0` × C 臂 |
| **C-17** | **`--writeback` 绕过可丢弃的准入队列。** S 臂（CLW 无 WB）准入走 `cached_store.go:368 → bcache.cache() → pending channel`（`force=false`，**可丢弃**）⇒ 丢弃 31--36%；W 臂（CLW+WB）走 `disk_cache.go:801 os.Link` **同步硬链接，不经队列** ⇒ 丢弃仅 6.8--7.1%。这是 WB 优于 CLW 的一条**此前未识别**的机制，把 C-7 的「CLW 在 W 臂冗余」加强为「**CLW 的准入通道会丢掉三分之一，WB 的准入通道一个不丢**」 | 同上 + 源码 |

### 5.4 新增机制（建议编号 M-41 ～ M-46）

| 编号 | 内容 | 级别 |
|---|---|---|
| **M-41** | 完整读栈 14 层（§3 Q1）；`vfs.go:789` Flush 的真实语义 = 数据在前、元数据在后、**粒度为整个 inode**；`baseMeta.Read` 只是其中一个子步骤 | ✅ 代码实证 |
| **M-42** | slice id **早分配**：`writer.go:290` 在新建 sliceWriter 时即 `go s.prepareID()`；且从本地批量池取，`base.go:51 sliceIdBatch = 4096` ⇒ 平均每 4096 个 slice 一次元数据往返 ⇒ **id 分配既不是瓶颈，也不是读可见性的障碍** | ✅ 代码实证 |
| **M-43** | 「正确性做在 VFS 层，性能靠内核页缓存挡量」—— ⚠️ **推断，非官方论断**。可证部分见 §4 Q7 表格（flush 语义 `cache.md:72`、页缓存性能 `:133`/`:137`、COW 免一致性 `:22` 均有官方原文）；`vfs.Read` 内无条件 flush 的**理由**无任何官方或注释依据，git 溯源确认该行自 `d23762a7 first public release`（**2021-01-08**）起五年未变、无解释 | ⚠️ **推断** |
| **M-44** | **候选：提高 `--buffer-size` 以放大准入队列。** `pendingPages` 与 `--buffer-size` 线性相关：300 MiB→240 块（38 ms）、1024→819（130 ms）、2048→1638（**260 ms**）、4096→3276（520 ms）。直接针对 C-15。⚠️ 副作用未评估：`--buffer-size` 同时是读写缓冲总量，且 `reader.go:629` 有基于它的反压逻辑 | 🔶 候选，未评估 |
| **M-45** | **假设：WB 在 randrw 的收益可能主要来自读路径而非写路径。** 开 WB 后 `Finish()` 只等本地 `stage()`（`cached_store.go:443`）不等 PUT ⇒ M1 每个 slice 的等待从 ~20 ms PUT 往返降到 sub-ms 本地写 ⇒ C-1 的 `+19.56%` 可能有相当大一块是"读等的 flush 变短"。与 C-2（脏页吸收）不矛盾 —— 脏页吸收正是 `stage()` 快速返回的原因，只是此前只从"写变快"解读。⚠️ 06-1 因比例锁定（`read_bw ≡ write_bw`）**无法从数据上分离**，需专门设计 | 🔶 假设，不可判 |
| **M-46** | **候选：提前冻结（eager freeze）。** 记录不能立即确定的唯一障碍是 slice 保持 growable 等待紧邻追加（`writer.go:149--152` 只在 `slen == ChunkSize`(64 MiB) 时冻结）；而 `findWritableSlice` 的复用条件要求严格紧邻，随机写永不命中 ⇒ 等待纯属浪费。改动仅为在 `:149` 增加「本次写恰好填满一个 block 且起点对齐 ⇒ 立即冻结」。⚠️ **必须先算元数据账**：C-12 实测 T 臂元数据通道利用率已 52--57%；对纯随机覆盖写几乎无副作用（本就不合并），但作为通用改动风险不明。⛔ 不得在未算账前提交任务书 | 🔶 候选，未评估 |
| **M-47** | **取消 GC 同时伤了缓存侧（新）。** 精确回收死缓存块的唯一通道是 `DeleteSlice` 消息（`base.go:2985` → `cmd/mount.go:319 store.Remove`），由元数据侧删除 slice 驱动。06-3 明令禁止 GC/compact ⇒ 该通道几乎不触发 ⇒ 死块只能靠默认 `2-random` 近似随机淘汰，有效缓存容量进一步缩水，**加剧 C-16 抖动**。⚠️ 写入洪流（132.8 GiB/格 > 96 GiB）已足以造成抖动 ⇒ 这是**加剧因素非主因**，⛔ 不可量化。验证需一格「有归一门 + CLW」对照（06-1 与 06-3 之间未覆盖的组合） | 🔶 机制，不可量化 |

### 5.5 新增待办（接在 R-1～R-16 之后）

| 编号 | 内容 | 优先级 |
|---|---|---|
| **R-17** | `doc/juicefs-slice-chunk-block-read-flow-analysis-20260918.md` 基于 **1.3.1**（`/home/lilingfeng/project/juicefs`）且写 `block-size 默认 4M`，与本卷 `BlockSize=256 KiB` 及测试基线 1.4.1 不符 ⇒ 须补版本批注并交叉引用本文 | 中 |
| **R-18** | **06-3 报告须补 `cache_drops` / `cache_evicts` 两项**。数据早已在 `analysis.json` 的 `counter_deltas` 里，报告未使用 ⇒ 遗漏了 C-15/C-16/C-17 三条结论。这是一个**报告完备性缺陷**，非数据缺陷 | **高** |
| **R-19** | 指导书 §23 硬门拟再补 2 条：⑥**缓存类任务须报告 `cache_drops` 与 `evicts/writes`**，否则准入是否真正生效不可判；⑦**`%util` 不得单独用作块设备压力证据**，须同时给 `w_await` 与 `aqu-sz` | **高** |
| **R-20** | 若采纳 §0.1 的 `direct=0` 竞品横向对比，任务书须含：①口径声明（数据集 < 宿主内存、含 page cache 命中）②竞品客户端 **MemTotal 必录**（否则重犯 05-2 D4）③明确 ⛔ 不与 06 阶段纵向比、不计入 ABBA/漂移体系 | 中 |
| **R-21** | 06-2b 背景章节应加入 §3 Q7 的四项成本分解，作为「range-flush 优于 read-overlay」的正式论证 | 中 |
| **R-22** | 元数据侧若要定位瓶颈，须加 **TiKV per-region 指标**观测。理由见 §4B Q3④：inode 用小端编码把连续 inode 散开，故 C-12 的 52--57% 通道利用率**不能**推断"无单 region 热点"（当前只是未观测） | 中 |
| **R-23** | 记录 `--verify-cache-checksum` 默认 `extend` ⇒ 每个 256 KiB 缓存文件带 **32 字节 CRC32C 尾**（实际 262,176 B）。06-3 未显式设置即用默认值。对容量记账影响 0.012% 可忽略，但「缓存文件大小 == BlockSize」的核对断言须据此修正 | 低 |
| **R-24** | 本文档订正了 5 处官方文档行号引用（`cache.md:70→:72`、`:133--135→:133+:137`、`en:190→:191`、`en:196--197→:197`）。若 `06-STAGE-STATUS` 或周报中存在同源引用，须同步订正 | 低 |

---

## §6 待办与下一步

**本文档只负责记录与论证，⛔ 未修改任何既有文档。** 需用户决定的落地动作，建议顺序：

1. **先补上一轮欠的 C-14**（`--writeback` 是耐久性换带宽，§2.2）—— 这是唯一涉及"候选是否可接受"的风险项。
2. **落本轮 §5.1 撤销 ⑦⑧⑨⑩⑪ + §5.2 的 C-5 口径更正** —— 纯文档编辑。
3. **落 §5.3 的 C-15/C-16/C-17 与 §5.4 的 M-41～M-46** —— 这批是本轮的主要产出，其中 C-15/C-16 直接给出了"缓存路线为何走不通"的机制级答案。
4. **R-18（高）**：修订 06-3 报告，补 `cache_drops`/`cache_evicts`。
5. **R-19（高）**：指导书补 2 条硬门。
6. 视用户意愿：R-17 / R-20 / R-21。

⚠️ **全部为本地文档工作，不涉及环境操作**（`FORMAL_LOAD = NOT_AUTHORIZED_YET` 不变）。

**方向性提示**：C-15 + M-44 给出了一个**成本极低的可执行候选** —— 单参数 `--buffer-size 300 → 2048`，直接针对已实测的 31--36% 准入丢弃。它比 range-flush 简单得多，且不需要改代码、不需要补丁构建基座。若要在 06 阶段再开一格，这是当前**性价比最高的选项**；但须先评估 `--buffer-size` 对读写缓冲总量与 `reader.go:629` 反压逻辑的副作用。

---

## 附录 A：本文档所用证据与复算命令

### A.1 源码基线

```bash
# /tmp/opencode 曾被清空过一次，如需重建：
sha256sum /mnt/c/SunRise/test/06-2/20260916-091446/build/juicefs-v1.4.1-b-catchup-source.tar.gz
#  → a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451
mkdir -p /tmp/opencode && tar xzf /mnt/c/SunRise/test/06-2/20260916-091446/build/juicefs-v1.4.1-b-catchup-source.tar.gz -C /tmp/opencode
grep -n 'major\|minor\|patch' /tmp/opencode/pkg/version/version.go | head -3   # → 1 / 4 / 1
```

### A.2 计数器复算（C-15 / C-16 / C-17 / Q2 的延迟）

```bash
cd /mnt/c/SunRise/test/06-3/20260916-161945
python3 -c "
import json
d=json.load(open('analysis.json'))
for c in d['cells']:
    n=c.get('cell'); m=c['mechanism']['counter_deltas']; rt=c['primary']['runtime_s']
    dr,w,ev,h,ms=m['cache_drops'],m['cache_writes'],m['cache_evicts'],m['cache_hits'],m['cache_miss']
    print(n, f'drops={dr:,} writes={w:,} 丢弃率={dr/(dr+w)*100:.2f}%' if dr+w else n+' 无缓存',
          f'ev/wr={ev/w*100:.0f}%' if w else '', f'命中率={h/(h+ms)*100:.2f}%' if h+ms else '',
          f'put={m[\"put_count\"]:,}块={m[\"put_bytes\"]/2**30:.1f}GiB',
          f'命中读={m[\"cache_read_seconds_sum\"]/m[\"cache_read_seconds_count\"]*1000:.4f}ms' if m['cache_read_seconds_count'] else '')
"
```

### A.3 iostat 重算（C-5 口径更正 / 阻断三）

```bash
mkdir -p /tmp/opencode/r63
tar xzf /mnt/c/SunRise/test/06-3/20260916-161945/raw.tar.gz -C /tmp/opencode/r63 \
    --wildcards '*/cells/S1/iostat-1hz.tsv' '*/cells/W1/iostat-1hz.tsv' '*/cells/C1/iostat-1hz.tsv'
# 然后对 nvme1n1 行、条件 wkB/s > 102400，统计 wkB/s / w_await / aqu-sz / %util / rkB/s 的
# mean / median / p95 / max（本文 §1.3 与 §4 Q3 表格即此结果）
```

### A.4 `pendingPages` 复算（C-15 / M-44）

```bash
python3 -c "
for bs in (300, 1024, 2048, 4096):
    pp = (bs << 20) * 2 // 10 // 262144 // 1        # cached_store.go:1172
    print(f'--buffer-size {bs:5d} MiB → pendingPages={pp:6d} 块 = {pp*256/1024:7.1f} MiB；按 6297 块/s 可缓冲 {pp/6297*1000:6.1f} ms')
"
```

### A.5 `vfs.Read` 内 flush 的 git 溯源（M-43 / Q7）

```bash
cd /mnt/c/SunRise/github/juicefs        # 1.4.0-dev 仓库，⚠️ 工作树脏，仅用于溯源
git log -L 789,789:pkg/vfs/vfs.go       # → 7a631f90 / b3f8f9d8 / d23762a7 first public release
git log -1 --format='%H %ad %s' d23762a7 --date=short   # → 2021-01-08 first public release
git show d23762a7:pkg/vfs/vfs.go | sed -n '610,625p'    # 上下文与今日结构一致，无注释
```

### A.6 脚本口径清点（Q1）

```bash
cd /home/lilingfeng/demo/production/prod-deploy
grep -rln 'rwmixread' scripts/                     # → 21 个文件，均为我方 debug driver + bs-sweep
grep -c 'rwmixread' scripts/benchmark/fio-7item-test.sh    # → 0
fio --cmdhelp=rwmixread | grep default             # → default: 50
```

### A.7 关键行号索引（1.4.1 冻结源码）

| 主题 | 位置 |
|---|---|
| 读入口（FUSE → VFS） | `pkg/fuse/fuse.go:263`；`pkg/vfs/vfs.go:693` |
| **读前无条件 flush（M1）** | **`pkg/vfs/vfs.go:789`** |
| 读 range 切分 / 预读 / 等待 | `pkg/vfs/reader.go:626` / `:670` / `:592` |
| 取 slice 列表 | `pkg/vfs/reader.go:175` → `pkg/meta/base.go:2081` |
| slice 列表本地缓存 命中/回填/失效 | `base.go:2093` / `:2119` / `:2168` |
| TiKV 点查 | `pkg/meta/tkv.go:2624 doRead`；key = `chunkKey()` = `fmtKey("A", inode, "C", indx)`（14 字节） |
| 重叠展平（后来者赢） | `pkg/meta/slice.go:134 buildSlice`，切割在 `:66` |
| 24 字节记录 序列化/常量 | `pkg/meta/slice.go:92 marshalSlice` / `:91 sliceBytes = 24` |
| 整值改写 + O(N) 去重扫描 | `pkg/meta/tkv.go doWrite`（`val = append(rs[1], val...)`） |
| 对象名生成 | `pkg/chunk/cached_store.go:74--79` |
| block 长度 | `pkg/chunk/cached_store.go:66--72` |
| 缓存命中读（buffered pread） | `pkg/chunk/cached_store.go:131--150` |
| 读路径回填缓存 | `pkg/chunk/cached_store.go:820`；准入判据 `:844 shouldCache` |
| **写路径准入（CLW）** | **`pkg/chunk/cached_store.go:368`** |
| **准入队列大小** | **`pkg/chunk/cached_store.go:1172 pendingPages`** |
| **准入丢弃** | **`pkg/chunk/disk_cache.go:474--476`**（注释 + `cacheDrops.Add(1)`）；另一分支 `:450` |
| 缓存文件路径 / 暂存路径 | `pkg/chunk/disk_cache.go:729` / `:733` |
| 写临时文件 + 换名（**无 fsync**） | `pkg/chunk/disk_cache.go:444` 起，`renameFile` 在 `:509` 附近 |
| WB 暂存 + 硬链接进读缓存 | `pkg/chunk/disk_cache.go:783 stage` / `:801 os.Link` / `:802 cache.add(负值)` |
| 上传成功后翻账 | `pkg/chunk/disk_cache.go:810 uploaded` |
| 内存索引结构 | `pkg/chunk/disk_cache.go:60 cacheKey`；`pkg/chunk/cache_eviction.go:34 cacheItem` / `:39 KeyIndex` |
| **缓存三层命中（内存页 / 内存索引 / 磁盘）** | **`pkg/chunk/disk_cache.go:668--697 load()`** |
| 容量记账（每块 +4096） | `pkg/chunk/disk_cache.go:775`；`full()` 判据 `:249--251` |
| 容量淘汰 | `pkg/chunk/disk_cache.go:777 add` → `:779` → `:830 cleanupFull`（目标 `capacity×95/100`） |
| 淘汰策略（默认 `2-random`） | `pkg/chunk/cache_eviction.go:27--29`、`:54 NewKeyIndex`；默认值 `cached_store.go:622`/`:625`；跳过暂存块 `randomEviction.evictionIter` 内 `if value.size < 0 { continue }` |
| **精确删除缓存（唯一通道）** | `pkg/meta/base.go:2985 deleteSlice_` → `cmd/mount.go:319--321 store.Remove` → `pkg/chunk/cached_store.go:187 rSlice.Remove` |
| 完整性剔除 | `pkg/chunk/cached_store.go:147 bcache.remove(key, false)` |
| 索引重建 / 周期刷新 | `pkg/chunk/disk_cache.go:949 scanCached` / `:1009` / `:418 refreshCacheKeys` |
| slice id 分配（早 + 批量 4096） | `pkg/vfs/writer.go:290`；`pkg/meta/base.go:2130` / `:51 sliceIdBatch` |
| 冻结条件 / slice 复用条件 | `pkg/vfs/writer.go:149--152` / `:171--190 findWritableSlice` |
| flush 遍历全部 chunk 全部 slice | `pkg/vfs/writer.go:393--420`（核心循环 `:405--412`） |
| 数据上传（WB 与非 WB 分岔） | `pkg/chunk/cached_store.go:497 Finish`；`:443`（WB）vs `:467`（非 WB） |
| 元数据提交 + FIFO 次序 | `pkg/vfs/writer.go:193 commitThread` / `:198` 注释 / `:215 m.Write` |
| `openfiles` 生命周期 | `pkg/meta/openfile.go:206 ReadChunk` / `:221 CacheChunk` / `:238 InvalidateChunk` / `:68 cleanup` / `:35 release` |
| FUSE `writeback_cache` | `pkg/fuse/fuse.go:503--504` / `:570--571`；`pkg/vfs/vfs.go:779`；`pkg/vfs/handle.go:246` / `:417` |
| 官方文档（flush 语义 / 页缓存 / COW / 本地缓存粒度 / 取舍声明） | `docs/zh_cn/guide/cache.md:72` / `:133`+`:137` / `:22` / `:24` / `:18`（1.4.1 与 1.4.0-dev 两份副本行号一致） |
| **TiKV 键空间正式文档** | **`pkg/meta/tkv.go:192--227`**（图例 + All keys 全表） |
| 卷前缀（卷名 + `0xFD`） | `pkg/meta/tkv_tikv.go:117--118`；每次操作拼接在 `pkg/meta/tkv_prefix.go:30--35 realKey` |
| inode 小端 / indx 大端 | `pkg/meta/tkv.go encodeInode`（显式 LittleEndian）；`pkg/utils/buffer.go:129 FromBuffer`（固定 BigEndian） |
| 缓存文件 CRC 校验尾 | `pkg/chunk/disk_cache.go:545--547`；`:1458 checksum()`；`:1353 csBlock = 32 KiB`；默认级别 `cmd/flags.go:263--265` = `extend` |
