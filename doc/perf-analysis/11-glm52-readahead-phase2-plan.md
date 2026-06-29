# 11-glm52 readahead 后阶段计划（2026-06-24）

> 本文接续 `10_A` 系列验证与 sweep 实测，精简记录已确认结论，重点承载下一阶段工作计划。
> 模型：GLM-5.2（sunrise-ai-private/GLM52）

---

## 一、已确认结论（精简）

| 结论 | 依据 | 状态 |
|------|------|------|
| readahead 是随机读放大的主要来源 | `10_A_4` A→B（2.61→1.51×） | ✅ 方向确认 |
| **但 ra=0 真冷态不达标**（49.6 < 59） | sweep cache=0 + OSD drop_caches | ⚠️ 10_A_4 的 77.7 是 OSD 缓存热态假象 |
| **无甜点档位**：ra 0→1 断崖（49.6→36.0），1/4/8/default 无差异（~36） | sweep 5 档 | ✅ 已扫尽 |
| EC/网络非放大源（L1=1.04×） | `10_3` | ✅ 已排除 |
| slice 碎片化非主因（strace 139≈4×35） | `10_A_2_3` | ✅ 已排除 |
| FUSE 内核节流非瓶颈（waiting≈0） | `10_A_1` | ✅ 已排除 |
| 元数据缓存无效 | `10_A_2_3` | ✅ 已排除 |
| FUSE splice/max_read 系统不支持 | `10_A_7` | ✅ 已排除 |
| BlueStore cache 无法用 drop_caches 清除 | OSD 用 O_DIRECT + 用户态缓存 | ✅ 已确认 |

### sweep 实测数据（cache=0，128G 256K，MiB/s）

| readahead | randread | seqread | seqwrite | 三线达标？ |
|:---------:|:--------:|:-------:|:--------:|:--------:|
| **0** | **49.6** | 49.5 | 56.8 | ❌ 均不足 |
| 1 | 36.0 | 86.1 | 63.2 | ❌ randread 崩 |
| 4 | 35.8 | 92.6 | 55.9 | ❌ randread 崩 |
| 8 | 35.7 | 92.6 | 59.2 | ❌ randread 崩 |
| default | 35.5 | 91.3 | 66.1 | ❌ randread 崩 |

> **10_A_4 的 77.7 为何虚高**：layout 刚写完 128G 数据，BlueStore cache 热（6 OSD × ~1GB ≈ 6GB），叠加 readahead off 后放大降低，双因素叠加产生 77.7。sweep 在多轮测试后跑，BlueStore cache 被 128G 工作集充分 churn（命中率 <5%），49.6 才接近真冷态。

---

## 二、策略判断：第三条路

用户提出两个选项：A）基于关预读，补回被拉低的 seqread/seqwrite；B）放弃预读调参，继续分析 randread 瓶颈。

**两者都不对。应走第三条路：以 ra=0 为 randread 最优基线，深挖残余瓶颈。**

理由：

1. **readahead 调参已穷尽**——sweep 5 档无甜点，ra=0 是 randread 唯一最优（49.6 vs 36），但不够。继续在 readahead 参数上花时间无意义。

2. **补 seqread/seqwrite 不是调优问题，是配置问题**——ra=0 下 seqread=49.5 是预期行为（顺序读天然依赖预读），不是"缺陷"。生产用双挂载点即可解决（随机读挂载 ra=0，顺序读写挂载 default），无需"修复"。

3. **真正的问题：ra=0 下 randread 仍只有 49.6，距 59 差 18%**——这个差距的成因才是下一阶段的核心。有两种可能，指向完全不同的优化路径：

### 关键未解问题：ra=0 下瓶颈是网络带宽还是 IOPS/延迟？

| 假设 | 含义 | 优化方向 | 依据 |
|------|------|---------|------|
| **A：NIC 仍饱和（~115 MB/s）** | 放大 2.32×，readahead off 只砍到 2.32×（不是 10_A_4 说的 1.51×） | 降残余放大（源码改造、messenger 调参） | 10_A_4 的 NIC RX=117，但 READ 被缓存抬高 |
| **B：NIC 未饱和（~75 MB/s）** | 放大仍 1.50×，但 IOPS/延迟卡住了有效读 | 降延迟（pprof 找热点、线程模型、OSD 调参） | 49.6×1.50=74.4，远低于线速 117 |

**sweep 脚本的 NIC RX 采集有 bug**（`drop_all` 的 echo 污染了返回值），导致无法区分 A/B。**这是下一阶段的第一件事。**

> 如果是 A（网络饱和）：说明 ra=0 下残余放大仍 2.3×，比 10_A_4 声称的 1.51× 高得多。strace 2.60× 是在 default readahead 下测的，ra=0 下的 strace 放大从未测过——`10_A` 顺位 4 的"已确认 1.51×"是基于虚高数据算出的，**不能采信**。
>
> 如果是 B（IOPS 限制）：说明放大不是问题，瓶颈在每秒能完成的 read 操作数。ra=0 下每读恰好 1 个 block、4 个 OSD 应答、139 次 socket read()——如果这 139 次调用的延迟是瓶颈，优化方向完全不同（减少 syscall 次数、连接复用、批量读取）。

---

## 三、10_A 未完成项评估

| 顺位 | 实验 | 原状态 | 评估 | 决定 |
|------|------|--------|------|------|
| 5 | **pprof CPU 热力图** | 待测 | **高价值**。无论瓶颈是 A 还是 B，pprof 都能定位：CPU 密集→A（放大占网络）；CPU 空闲/IO wait→B（延迟卡 IOPS）。且成本极低（curl 6062 端口） | ✅ **保留，P1** |
| 6 | slice 碎片化 fsck/gc | 待测 | strace 已精确排除（139≈4×35，4 OSD 对齐 EC 4+2，无额外 GET） | ❌ **删除** |
| 8 | JuiceFS 线程模型调研 | 待测 | **中价值**。如果 FUSE dispatch 是单线程，可解释为何并发参数全无效、IOPS 有天花板。但需读 go-fuse 源码，成本中等 | ✅ **保留，P3** |
| — | L1 冷态对等复测 | 待测 | **低价值**。L1 的核心结论（1.04× 放大）不受工作集大小影响（是比值非绝对值）。冷态绝对带宽只影响"后端裸上限"的表述，不影响优化方向 | 🔶 **降级，非主线** |

---

## 四、新方向

### P0：ra=0 + NIC RX 精测（补 sweep 的 bug）

**目的**：区分瓶颈 A（网络饱和）vs B（IOPS/延迟限制），决定后续全部方向。

**方法**：ra=0 挂载，跑一次 60s randread，手动在 fio 前后取 `/proc/net/dev` 差值。不依赖 sweep 脚本的自动采集（有 bug），手工算一次即可。

**判读**：
- NIC RX ≈ 115 MB/s → 假设 A，放大 2.3×，走"降残余放大"路线
- NIC RX < 90 MB/s → 假设 B，放大 ~1.5×，走"降延迟/提 IOPS"路线

### P1：pprof CPU 热力图（ra=0 下）

**目的**：定位残余开销的 CPU 归属。

**方法**：
```bash
# JuiceFS 暴露 pprof（需确认 mount 时是否启用）
juicefs mount ... --max-readahead 0
# fio randread 跑起来后
curl -s http://localhost:6062/debug/pprof/profile?seconds=30 > prof.pb.gz
go tool pprof -top prof.pb.gz
```

**判读**：
- CPU 高在 `ceph.Get`/`rados.read` → librados 数据读取占主，对应 A 或 B 的 syscall 开销
- CPU 高在 `fuse.*`/`dispatch` → FUSE 层开销，对应线程模型问题
- CPU 低、大量 goroutine 在 `syscall`/`futex` → IO wait 为主，对应 B（延迟瓶颈）

### P2：ra=0 下补采 strace（`10_A` 顺位 4 修正）

**目的**：10_A_2_3 的 strace 2.60× 是 default readahead 下测的。ra=0 下的 strace 放大**从未实测**，10_A_4 声称的 1.51× 基于虚高数据，不可信。

**方法**：同 10_A_2_3 §4.4，但 mount 加 `--max-readahead 0`，strace 抓 10s，算 syscall 层放大。

**判读**：
- strace 放大 ≈ 1.5× → 与 P0 的 NIC RX 交叉验证（NIC 应也 ≈ 1.5×），确认假设 B
- strace 放大 ≈ 2.3× → 确认假设 A，readahead off 并未把放大降到 1.5×，10_A_4 全错

### P3：JuiceFS 线程模型调研

**目的**：确认 FUSE 请求分发是否单线程瓶颈，解释为何 iodepth/numjobs 调参全无效。

**方法**：读 go-fuse `server.go` 的 dispatch loop + JuiceFS `fuse.go` 的挂载配置。关键问题：一个 FUSE connection 的请求是否由单个 goroutine 串行 dispatch？

### P4：源码级优化评估

`11`（旧版）已记录的源码发现：

| 发现 | 位置 | 预期收益 | 风险 |
|------|------|---------|------|
| 每次 Get 前多一次 Head/Stat 往返 | `ceph.go:137` | 每 read 省 1 次 OSD 往返 + ~8K 协议开销 | 需确保元数据一致性 |
| 逐 block 同步读取，无批量合并 | `cached_store.go:97-180` | 可合并相邻 block 的 GET | 改动大，需评估 |
| readahead 自适应算法不归零 | `reader.go:419-440` | `--max-readahead 0` 已绕过 | 无 |

**前提**：P0/P1 先确定瓶颈类型，再决定是否值得动源码。如果瓶颈是 OSD 延迟（B），改 ceph.go 去 Head() 可能直接见效；如果瓶颈是网络带宽（A），省 8K 杯水车薪。

---

## 五、生产交付策略（与调优并行）

无论调优结论如何，当前已有可用于生产的配置：

| 挂载点 | 参数 | 适用场景 | 预期带宽 |
|--------|------|---------|---------|
| `/mnt/jfs-random` | `--max-readahead 0 --cache-size 0` | 随机读为主（推理/采样） | randread ~50 MB/s |
| `/mnt/jfs-sequential` | 默认（readahead on） | 顺序读写（数据导入/checkpoint） | seqread ~91、seqwrite ~66 MB/s |

- 两个挂载点共享同一 TiKV 元数据 + 同一 Ceph 池，数据互通
- 业务按 IO 模式选择挂载点，不需要切换参数或重启
- 若 P0-P4 调优有突破，更新 `/mnt/jfs-random` 参数即可

---

## 六、执行计划

```
P0  ra=0 + NIC RX 精测（手工，10 分钟）
    → 区分瓶颈 A（网络饱和）vs B（IOPS/延迟）
    │
    ├─ 若 A（网络饱和，放大 2.3×）：
    │   P2  ra=0 strace 补采 → 确认 syscall 层放大
    │   P1  pprof → 定位 CPU 热点在 librados 还是 FUSE
    │   P4  源码改造（去 Head()、批量读取）→ 降每读 syscall 次数
    │
    └─ 若 B（IOPS/延迟，放大 1.5×）：
        P1  pprof → 确认 CPU 是否空闲（IO wait 为主）
        P3  线程模型 → 确认 FUSE dispatch 是否单线程
        P4  源码改造（去 Head()）→ 省 1 次 OSD 往返，直接降延迟
        → OSD 侧：bluestore_cache_size_ssd 调大？OSD op threads？
```

### 优先级汇总

| 优先级 | 任务 | 预计耗时 | 产出 |
|--------|------|---------|------|
| **P0** | ra=0 + 手工 NIC RX | 10 min | 瓶颈类型判定（A/B） |
| **P1** | pprof CPU profile | 30 min | CPU 热点归属 |
| **P2** | ra=0 strace 补采 | 30 min | syscall 层放大真值 |
| **P3** | go-fuse 线程模型调研 | 1-2h | dispatch 是否单线程 |
| **P4** | 源码改造评估 | 视 P0-P3 | 可行性与预期收益 |

### 不做的事

| 项 | 理由 |
|----|------|
| 继续 sweep readahead 中间档位 | 0→1 断崖已证无甜点 |
| 补 seqread/seqwrite（ra=0 下） | 配置问题（双挂载点），非调优问题 |
| L2 CephFS 对照 | L1=1.04× 已排除后端，CephFS 只细分 FUSE 层 vs JuiceFS 逻辑，不改优化方向 |
| EC 2+1 / MTU jumbo / overwrites | L1=1.04× 已证 EC/网络非放大源 |
| slice 碎片化 fsck/gc | strace 已精确排除 |
| L1 冷态对等复测 | 1.04× 是比值不受工作集影响，绝对带宽非主线 |

---

## 七、一句话总结

readahead 是放大主因但 **ra=0 真冷态仅 49.6 MB/s，不达标**，且无中间甜点。下一阶段不在 readahead 参数上继续——而是用 **NIC RX 精测 + pprof + strace** 三板斧确定残余瓶颈是网络放大（A）还是 IOPS/延迟（B），再据类型选择源码改造或线程模型优化。生产用双挂载点（ra=0 随机读 + default 顺序读写）并行交付。
