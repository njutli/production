# 11 随机读调优阶段总结与下一步指南（2026-06-24）

> 本文是 10 系列（含 10_A 子系列）随机读瓶颈定位工作的**阶段性总结**，
> 汇总全部已验证结论、已排除方向、关键数据，并给出下一阶段调优的优先级路线。
>
> 前置文档：
> - `10-random-read-bottleneck-localization-plan.md`（定位计划：L1/L2/L3 分层）
> - `10_1/10_2`（v1.3 vs v1.4 基线 + 多客户端聚合）
> - `10_3`（L1 裸 RADOS + Cache/Readahead 对比）
> - `10_A` 系列（8 项候选验证，5 项已结）
> - `tun/` 三份模型补充（GLM5.1/5.2/qwen）
> - `doc/tmp-data-path-bottleneck-analysis.md`（数据链路与源码分析，本文完成后删除）

---

## 一、环境与目标

| 项 | 值 |
|----|----|
| 集群 | 3 台 Ceph 节点（.11/.13/.14）+ 1 台 TiKV 节点（.12），全千兆 |
| Ceph | 17.2.8，EC 4+2，6 OSD，SSD（PERC H730 RAID） |
| JuiceFS | v1.3.1，`--storage ceph`（直连 RADOS），block-size 256K |
| 元数据 | TiKV 单节点（.12:2379） |
| 验收目标 | 有效数据带宽 ≥ 网卡带宽 50% = **59 MB/s**（单客户端千兆半速） |
| fio 口径 | bs=256k randread iodepth=128 numjobs=128 direct=1 runtime=60s |

---

## 二、核心成果

### 2.1 readahead 是主要放大来源，关停后冷态达标

`10_A_4` 第三版（128G 256K 冷态，NIC RX 采样）：

| 配置 | READ | NIC RX | 放大 | 达标？ |
|------|------|--------|------|--------|
| 默认（readahead on） | 45.3 MB/s | 118.2 | **2.61×** | ❌ |
| `--max-readahead 0` | **77.7 MB/s** | 116.9 | **1.51×** | **✅** |
| G4（cache + 关 readahead + 关 prefetch） | 75.9 MB/s | 117.2 | 1.55× | ✅（不优于单独关 readahead） |

- readahead 贡献 **1.73×** 放大（2.61÷1.51），是 JuiceFS 内部放大主要来源
- 关停后冷态 Run1 即达 73.2 MB/s > 59 目标
- 加 cache（10G）无额外收益（128G >> 10G，命中率低）
- 关 prefetch 略降（77.7→75.9，-2%）

> ⚠️ `10_A_4` 初版/二版曾因 `bench-juicefs.sh` 未传 `--block-size 256K`（实际用 4K block）
> 得出"证伪"结论，第三版已修正。**所有引用 readahead 结论须以第三版为准。**

### 2.2 放大分解

| 层 | 放大 | 来源 | 状态 |
|----|------|------|------|
| L1 裸 librados / EC / 网络 | **1.04×** | `10_3` L1 rados bench 256K rand | ✅ 已排除 |
| **JuiceFS readahead** | **1.73×** | `10_A_4` A→B（2.61÷1.51） | ✅ **主要来源，已确认** |
| Ceph messenger 协议帧 | ~0.45× | strace + 源码分析（残余 1.51÷1.04-1） | ✅ 已定位 |
| TCP/IP 头 | ~0.38× | NIC − strace 差值 | 已知 |
| JuiceFS 其他内部（调度/FUSE） | ? | 残余未定量 | 🔶 待 pprof 定位 |
| **总放大（默认配置）** | **2.61×** | | |
| **总放大（关 readahead）** | **1.51×** | | |

### 2.3 数据链路与源码分析

完整链路（fio → FUSE 内核 → JuiceFS daemon → TiKV 元数据 → 缓存 → librados → Ceph OSD）
详见 `doc/tmp-data-path-bottleneck-analysis.md`（本文完成后删除，关键内容已并入本节）。

源码层面关键发现（JuiceFS v1.3.1，`pkg/object/ceph.go` + `pkg/chunk/cached_store.go`）：

| 发现 | 源码位置 | 影响 |
|------|---------|------|
| **每次 Get 前多一次 Stat 往返** | `ceph.go:137` `c.Head(key)` | 每 read 多 1 次 OSD 往返 + ~8K 协议开销 |
| **逐 block 同步读取，无批量** | `cached_store.go:97-180` `rSlice.ReadAt` | 无法合并多个 block 的 GET 请求 |
| **readahead 自适应算法** | `reader.go:419-440` `checkReadahead` | 随机读下窗口会自适应缩小，但不会归零；残余预读是放大主因 |
| IOContext 池容量 50 | `ceph.go:368` | 不是瓶颈 |

strace 关键数据（`10_A_2_3` §4.4，readahead 开启时）：

| 指标 | 值 |
|------|-----|
| 每 fio read 的 Ceph socket read() 调用 | **139** ≈ 4 OSD × 35 |
| 平均每 read() 读量 | 4,788 bytes |
| syscall 层放大 | **2.60×** |
| **slice 碎片化** | **排除**（4 OSD 精确对齐 EC 4+2，无额外 GET） |

---

## 三、已排除方向（全部有实验证据）

| 方向 | 证据 | 来源 |
|------|------|------|
| EC 取片放大 | L1 rados bench 256K rand 放大仅 1.04× | `10_3` §一 |
| slice 碎片化 | strace 139 ≈ 4×35，精确对齐 EC 4+2 | `10_A_2_3` §4.4 |
| FUSE 内核节流 | waiting≈0 全程 50 采样点 | `10_A_1` |
| 元数据缓存 | attr/entry/open-cache=300 对纯 randread 无增益 | `10_A_2_3` §三 |
| FUSE splice/max_read/max_pages | fusermount3 3.10.5 + kernel 5.15 不支持 | `10_A_7` |
| RGW HTTP 层 | 去掉 RGW 直连 RADOS，读反而更差（3.8→2.2） | `08_1` |
| BlueStore/磁盘介质 | 纯内存盘 106.6 vs SSD 106.4 | `06_2` |
| Ceph 软件栈并发 | rados bench -t 128/256 无提升 | `09_1` |
| prefetch 单独关停 | 128G 冷态 --prefetch 0：34.0 MB/s（↓25%），无改善 | `10_A_4` 第三版 |
| v1.4 升级（单客户端） | v1.4 单客户端 randread -3.3%（44.2 vs 45.7） | `10_1` |
| buffer-size 调大 | --buffer-size 2048 反降（两后端一致） | `08_2` B |

---

## 四、关键数据汇总

### 4.1 单客户端 randread（128G 256K 冷态）

| 配置 | READ (MB/s) | 放大 | 达标 | 来源 |
|------|------------|------|------|------|
| 09 基线（默认） | 45.9 | ~2.5× | ❌ | 09 系列 |
| `10_A_4` Config A（默认） | 45.3 | 2.61× | ❌ | `10_A_4` 第三版 |
| **`10_A_4` Config B（`--max-readahead 0`）** | **77.7** | **1.51×** | **✅** | `10_A_4` 第三版 |
| `10_A_4` Config C（G4: cache+关 readahead+关 prefetch） | 75.9 | 1.55× | ✅ | `10_A_4` 第三版 |

### 4.2 多客户端聚合（v1.3.1）

| 客户端数 | randread 聚合 | 来源 |
|---------|-------------|------|
| 1 | 45.9 MB/s | 09 基线 |
| 2 | 55.3 MB/s | `10_2` |
| 3 | 57.1 MB/s | `10_2` |
| 4 | 66.9 MB/s | `10_2` |

### 4.3 后端裸能力

| 口径 | 带宽 | 说明 |
|------|------|------|
| rados bench 256K t=128（L1） | 112.7 MB/s | ⚠️ 工作集 6.4G < OSD 内存，偏乐观 |
| rados bench 4M（旧） | 118-145 MB/s | ❌ 口径错位，已弃用 |

### 4.4 其他场景（默认配置）

| 场景 | 带宽 | 达标？ |
|------|------|--------|
| 顺序写（4M bs） | ~117 MB/s | ✅ |
| 顺序读（4M bs） | ~107 MB/s | ✅ |
| 随机写（256K） | ~63 MB/s | ✅ |

---

## 五、三份模型补充的裁决

`tun/` 目录下三份独立模型调优文档的验证状态：

| 模型 | 核心主张 | 验证结果 |
|------|---------|---------|
| **GLM5.1** | 49.6 物理上限 + tcpdump 分解 + pprof + slice 碎片 | tcpdump/strace ✅ 完成；pprof 待测；slice 碎片 ❌ 排除；**49.6 上限被 readahead 关停打破**（77.7 > 49.6） |
| **GLM5.2** | EC 2+1 对照 + allow_ec_overwrites + OSD perf dump + MTU jumbo | L1=1.04× 已证 EC/网络非放大源，这些方向**全部降级** |
| **qwen** | 达标率=1/RAF + FUSE congestion_threshold + 元数据强缓存 | congestion ❌ 证伪；元数据缓存 ❌ 证伪；**达标率=1/RAF 公式成立**，但 readahead 关停使 RAF 从 2.61→1.51，达标率从 38%→66% |

**三份的核心价值**：把"2.5× 残余放大如何分解"从悬案细化为可执行实验，推动了 10_A 系列验证。
其中 qwen 的"降 RAF 是软件出路"被证实，GLM5.1 的"49.6 物理不可达"被 readahead 关停推翻。

---

## 六、当前推荐配置

### 6.1 随机读场景

```bash
juicefs mount -d tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs \
  --storage ceph --bucket juicefs-data \
  --max-readahead 0
```

- randread 冷态 = **77.7 MB/s**（目标 59 的 1.32×）
- 放大 = **1.51×**（基线的 58%）
- 零成本（仅 mount 参数）

### 6.2 副作用警告

`--max-readahead 0` 对顺序写有退化（4K block 下 -43~48%，256K block 下未测）。
若需混合负载，需根据场景切换 mount 参数，或验证 JuiceFS 自适应 IO 模式识别能力。

### 6.3 不需要的配置

| 配置 | 原因 |
|------|------|
| `--prefetch 0` | 略降（77.7→75.9），无收益 |
| `--cache-size 10240` | 128G >> 10G，命中率低，无额外收益 |
| `--buffer-size 2048` | 反降（08_2 B 已证） |
| `--attr-cache 300` 等 | 对纯 randread 无增益（10_A_2_3 已证） |

---

## 七、下一步工作

### 7.1 验收口径测试（热态/多轮）

`--max-readahead 0` 冷态已达 77.7，热态应更高。需完成：

| 优先级 | 任务 | 方法 | 说明 |
|--------|------|------|------|
| **P0** | **热态多轮带宽** | `--max-readahead 0` + `bench-hot-multiround.sh`，5 轮不 drop cache | 验收口径数据，验证 Run1→RunN 递增并稳定 |
| **P1** | **256K block 下顺序写退化精测** | `--max-readahead 0` 跑 seqwrite 4M bs | 此前退化数据是 4K block 的，256K 下幅度未知 |
| **P2** | **spec 全量口径（128×128）实测** | 干净状态下跑 spec 口径 randread | `10_issue-1` 已证 128×32 正常可跑，128×128 待确认 |

### 7.2 冷态残余 1.51× 放大定位

readahead 关停后残余 1.51× = EC/网络 1.04× + 协议帧 ~0.45× + JuiceFS 内部 ?

| 优先级 | 任务 | 方法 | 预期价值 |
|--------|------|------|---------|
| **P3** | **pprof CPU 热力图** | `--max-readahead 0` 下 fio randread 期间 curl pprof 6062 端口，`go tool pprof -top` | 定位残余中 JuiceFS 内部 CPU 热点（cgo 调用？FUSE dispatch？锁竞争？） |
| **P4** | **readahead 关停后补采 strace** | 同 10_A_2_3 方法，但用 `--max-readahead 0` | 对比 on/off 的 strace 放大，精确量化 readahead 贡献 |
| **P5** | **JuiceFS 线程模型调研** | 读 go-fuse dispatch 代码 | 确认 FUSE 请求分发是否单线程瓶颈（10_A 顺位8） |
| **P6** | **L1 冷态对等复测** | prefill ≥128G + 所有 OSD drop_caches + rados bench rand | 得到与 JuiceFS 对等的冷态后端裸上限 |

### 7.3 源码级优化（需评估可行性和风险）

| 方向 | 方法 | 预期收益 | 风险 |
|------|------|---------|------|
| 去掉 ceph.Get 中的 Head/Stat 调用 | 改 `pkg/object/ceph.go:137`，跳过存在性检查 | 每次读省 1 次 OSD 往返 + ~8K 协议开销 | 需确保 JuiceFS 元数据一致性 |
| 调整 block-size 到中间值（如 512K） | format 时 `--block-size 512K` | 协议放大从 2.6× 降到 ~1.8×，但块级放大从 1× 升到 2× | 需重新铺数据，验证实际净效果 |

### 7.4 降级/备选方向

| 方向 | 状态 | 说明 |
|------|------|------|
| L2 CephFS 对照 | 最低优先 | L1 已确认放大在 JuiceFS 内部，CephFS 只细分"FUSE 层 vs JuiceFS 逻辑"，不改优化方向 |
| 升万兆网络 | 架构动作 | 放大仍在（1.51×），但达标线同步抬到 590，有余量 |
| 多客户端聚合 | 旁证 | v1.4 4-cl 92.1 > 单客户端天花板，但验收线也抬，治标不治本 |
| EC 2+1 / MTU jumbo / overwrites | 已降级 | L1=1.04× 已证 EC/网络非放大源 |

---

## 八、关键教训

1. **block-size 必须在 format 时指定**：`bench-juicefs.sh` 不自动传 `--block-size`，导致 10_A_4 初版/二版在 4K block 下测试得出错误结论。所有测试脚本须显式传 `EXTRA_FORMAT_OPTS="--block-size 256K"`。

2. **OSD BlueStore cache 会预热**：多轮测试中 Run2/Run3 会因 OSD 内存命中而暴涨（42.9→114.0），**Run1 是最接近冷态的数据**，不能用 Run2/Run3 评价参数效果。

3. **不要 SIGKILL 高并发 fio 后立即重启**：会残留 libaio io_context / FUSE 在途请求，污染下一个 fio（`10_issue-1`）。杀完等几秒、确认 `pgrep -x fio` 为空再起下一个。

4. **readahead 自适应算法在随机读下不会完全归零**：源码 `reader.go:419-440` 显示算法会缩小窗口但保留 blockSize 起始值，残余预读持续产生放大。`--max-readahead 0` 是唯一彻底关停方式。

5. **randrw + create_on_open 口径病态**：领导原命令的 `create_on_open=1` 导致读被写阻塞，READ 仅 ~4 MB/s。纯 randread 才是真实读性能（45.9 vs 4.05），两者差 10×。

---

## 九、一句话总结

**readahead 是随机读 2.61× 放大的主要来源（贡献 1.73×），`--max-readahead 0` 将冷态 randread 从 45.3 提升到 77.7 MB/s，超过 59 目标。残余 1.51× 放大来自 Ceph messenger 协议帧（~0.45×）+ EC/网络基线（1.04×），属架构固有开销。下一步优先做热态多轮验收测试，同时用 pprof 定位残余 JuiceFS 内部开销。**

---

环境：tikv-node (192.168.11.12)，JuiceFS v1.3.1，Ceph 17.2.8 HEALTH_OK，pool juicefs-data EC 4+2，2026-06-24。
