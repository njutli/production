# 任务演进脉络

> 记录从 00 到 01-4 + 审计的完整任务演进链，说明每个任务的性质、目标、发现的问题、得到的结果，以及补测任务针对的不足。

---

## 一、演进总表

| 任务 | 性质 | 目标 | 发现的问题 | 得到的结果 |
|------|------|------|-----------|-----------|
| **00** | 原始基线（已归档） | 新集群全量冷态基线，default vs ra0 双组 × 不限速/千兆双口径 | ① bw_log 只拷回 1 份合并文件（缺 127 份 per-job）；② randrw fresh-volume 冷启动失真（R/W 严重不均衡）；③ 限速 randread 前 60s 零完成 | 4 组数据（不限速 default/ra0 + 限速 default/ra0），但多 job time_based 项统计口径不可信 |
| **01-1** | 重定基线 | 从零部署 Ceph+TiKV+JuiceFS + 不限速冷态基线；决策停做限速（§9.4） | 同 00 的 bw_log 问题（per-job 文件未拷回）；randrw 72.7 确认为冷启动失真 | 不限速 ra0 基线入报告，但 randrw 作废、多 job 项仍用"合并×numjobs"外推 |
| **01-2** | 诊断扫描（附带修缺陷） | randrw/randread 降并发扫描 + 读放大诊断 + rados 裸上限 | 任务书明确"先修 01-1 的采集缺陷"，要求保留 128 份 per-job 文件；但**实际执行仍只拷回 1 份**；randrw 第 1 轮系统性冷启动失真；summary 中位数编造（取平均冒充中位数、丢异常轮次） | randread 扫描可信（三轮极紧）；rados 裸上限可信；**randrw 全部作废**；per-job 文件在 157 上有但未拷回 |
| **01-2b** | 补丁重跑（针对 01-2 randrw） | 消除冷启动失真 + 正确采集 per-job + 正确统计，重跑 randrw 四档 | 针对修复：① 用方案 A（复用 layout 卷，无 create_on_open）消除冷启动；② 保留 128 份 per-job 文件；③ §8.3 正确执行 | ✅ randrw D0-D3 全部可信，§8.3 与 fio 聚合行偏差 ≤1%，R/W=1.0 均衡 |
| **01-2c** | 补测（default 侧缺失项） | 补 default 侧缺失的 randread 读放大 + randrw 四档；附带修数据源冲突 | default 侧全量基线 bw_log 声称"已有且可信"（§〇 line 23-27），实际仍是合并文件；per-job 文件在 157 上有但未拷回 | randread 读放大 2.01× 量化完成；randrw default 四档完成；**但 mseqread、randwrite 的 default 侧从未用正确方法采集** |
| **01-3** | 可扩展性验证 | CPU 饱和曲线 + 多实例倍增 + max-uploads 扫描 | per-job 文件在 157 上有但未拷回；§8.3 用"合并×128"外推（偏差 ≤0.6%，A 类但不严谨） | CPU 6 核封顶坐实；多实例 ra0 N4=5013 vs default N4=2822；结论可信 |
| **01-4** | 根因 + CephFS 对照 | pprof 热点分析 + CephFS 内核态对照 | 无 bw_log，直接用 fio 聚合行（方法正确） | C1（FUSE dispatch）坐实；CephFS EC 1.60× / Rep 2.34× JuiceFS |
| **AUDIT** | 统计口径审计 | 全量数据审计，修订"合并×numjobs"外推值 | 确认 01-1 五目录全部只有合并 bw_log；157 上 01-1 的 per-job 已被覆盖丢失；01-2b 是唯一正确执行 §8.3 的测试；发现 `--openfiles=100` 假瓶颈问题（BeeGFS 已证实 +507%） | 无 C 类（需重测）——所有项有 fio 聚合行可用；但 mseqread、randwrite 从未有准确 §8.3 值；openfiles=100 可能导致所有 128-job 项偏低 |
| **01-2d** | **全量基线重测（定基线）** | 用正确方法（128/16/1 份 per-job §8.3 + REPEAT=3 + `--openfiles=128`）**一次性重测 A=default/B=ra0 全量**，同时补 rados 后端 4 档裸能力 | 旧全部真值作废（randread bw_log×numjobs 失真 65×、rados 3198 单点不可复现）；layout §8.3 峰值虚高（应取含 fsync 的 fio 真值）；randwrite-ow 轮间波动 50-100% 根因定位中 | ✅ **全量准确基线就位**（见 §三重写）。后端随机读裸 ~4300–4400（4000+ 稳态），**首要瓶颈在后端 EC4+2 随机读**（<6250 验收线、<BeeGFS 9045）；JuiceFS randread ra0=2404 仅为后端 56% |
| **01-5** | **rados bench 后端机制诊断 + FUSE 瓶颈验证**（01-2d 后续） | rados bench EC4+2 vs Rep3 单变量对照（72 cells + 监控）+ 用户两次反驳后补做：(A) JuiceFS+Rep3 后端实测、(B) ceph-fuse vs kernel CephFS 单变量对照（直接隔离 FUSE 影响） | 初版结论两次错：①"磁盘硬件天花板"被 BeeGFS 9045 推翻；②"Ceph 软件栈 per-IO 是后端瓶颈"被用户反驳（CephFS 同栈远高于 rados bench）；③"FUSE 是 JuiceFS 瓶颈"被用户要求直接证据。修复后补做 ceph-fuse 对照实验 | ✅ **三层瓶颈分解**：磁盘非瓶颈（BeeGFS 9045）、Ceph OSD 在 EC 是瓶颈但 Rep 非瓶颈（CephFS+Rep 6718 ✅）、**FUSE 是 JuiceFS 主瓶颈（直接证据：ceph-fuse 单变量对照损失 42%）**；Go/TiKV 非瓶颈（ceph-fuse 一样慢）；rados bench 不能代表后端真实能力（librados 比 CephFS 内核客户端低效 63%；librados 用户态 messenger 每次网络收发需 user↔kernel context switch，kernel CephFS 内核态 socket 无此开销）|

> **⚑ 分水岭（2026-07-17）**：01-2d 之前所有"当前数据可信度"结论（§三旧版）建立在**错误/缺失基线**上，已被 01-2d 全量重测取代。下方 §三已按 01-2d 真值重写。

---

## 二、补测任务针对性说明

### 01-2 → 针对 01-1 的不足

| 01-1 的不足 | 01-2 如何处理 | 是否修复 |
|-------------|-------------|---------|
| bw_log 只拷回 1 份（缺 per-job） | 任务书明确要求"保留每 job 的 `_bw.<job_id>.log` 全部文件" | ❌ 实际执行仍只拷回 1 份 |
| randrw 72.7 冷启动失真 | 用降并发扫描判定是否为队列测量偏差 | ⚠️ 发现是冷启动失真，但 randrw 数据本身仍不可信 |
| 无 randread 降并发数据 | 新增 randread D0-D3 扫描 | ✅ randread 扫描可信 |

### 01-2b → 针对 01-2 的不足

| 01-2 的不足 | 01-2b 如何处理 | 是否修复 |
|-------------|---------------|---------|
| randrw summary 中位数编造（取平均冒充中位数、丢异常轮次） | 严格 REPEAT=3 取中位数 | ✅ |
| randrw 每档第 1 轮冷启动失真（create_on_open=1 + 空目录） | 改用方案 A（复用 layout 卷，无 create_on_open） | ✅ |
| bw.log 仍只有 1 份（01-2 已点名要修但没修） | 强制保留 128 份 per-job 文件，跑 §8.3 聚合 | ✅ |

### 01-2c → 针对 default 侧的缺失

| 缺失项 | 01-2c 如何处理 | 是否修复 |
|--------|---------------|---------|
| default randread 读放大诊断（无 juicefs stats） | 补跑 default D0 + juicefs stats | ✅ 读放大 2.01× 量化 |
| default randrw 四档（只有 fresh-volume 失真值） | 补跑 default randrw D0-D3 方案 A | ✅ 四档完成 |
| **mseqread default 无准确 §8.3** | 未涉及（声称"已有 bw_log 且可信"） | ❌ 仍是合并文件 |
| **randwrite default 无准确 §8.3** | 未涉及 | ❌ 仍是合并文件 |
| **限速口径全部多 job 项无准确数据** | 未涉及（01-1 决策停做限速） | ❌ 从未重测 |

---

## 三、当前数据可信度总结（⚑ 2026-07-17 按 01-2d 全量重测重写）

> **口径**：不限速 100GbE，A=default / B=ra0，§8.3 稳态中位数；写类定量项（seqwrite/mseqwrite/layout）用含 `--end_fsync=1` 的 **fio 真值**（size 固定，耗时=size÷带宽，已验证无缓存虚高）。
> **layout §8.3 峰值（A4217/B3171）不采**——那是 128 job 全并发那几秒的峰值、含爬坡失真；采含 fsync 的 fio 真值 A3357/B3198。
> 数据源：`results/prod-01-2d-fullretest-20260717/summary.md`。均为 `--openfiles=128` 正确口径。

### 不限速口径（01-2d，全部准确）

| 测试项 | default (A) | ra0 (B) | ra0 影响 | 口径 |
|--------|---------|-----|------|------|
| seqread (1job) | ✅ 1263 | ✅ 178 | -86% | §8.3 单流 |
| mseqread (16job) | ✅ 3804 | ✅ 1909 | -50% | §8.3（**首次有准确值**）|
| seqwrite (定量4G) | ✅ 1527 | ✅ 1557 | 持平 | fio真值含fsync |
| mseqwrite (定量64G) | ✅ 4886 | ✅ 4121 | -16% | fio真值含fsync |
| layout (定量128G) | ✅ 3357 | ✅ 3198 | -5% | fio真值含fsync（§8.3峰值虚高不采）|
| **randread (128job)** | ✅ 1480 | ✅ **2404** | **+62%** | §8.3 |
| randwrite-true (128job) | ✅ 3635 | ✅ 4274 | +18% | §8.3（**首次有准确值**）|
| randrw R (128job) | ✅ 1032 | ✅ 1316 | +28% | §8.3 |
| randrw W (128job) | ✅ 1038 | ✅ 1319 | +28% | §8.3 |
| randwrite-ow (128job) | ⏳ 2004~3015 波动 | ⏳ 1410~2847 波动 | — | 轮间波动 50-100%，根因诊断中 |

**后端裸能力（rados bench，01-2d §3.3，REPEAT=3 低方差稳态）**：顺序读 ~4400 / 随机读 **~4300–4400（4000+）MB/s**。
→ **首要瓶颈在后端 EC4+2 随机读**（4300 < 6250 验收线、< BeeGFS 9045）；JuiceFS randread ra0=2404 仅为后端 56%（客户端次级瓶颈）。

### 限速口径（01-2d C=default / D=ra0，1Gbps TBF，全部准确）

| 测试项 | default (C) | ra0 (D) | 说明 |
|--------|---------|-----|------|
| seqread (1job) | ✅ 145.8 | ✅ 56.8 | default 预读跨节点并行放大 |
| mseqread (16job) | ✅ 205.5 | ✅ 170.9 | — |
| seqwrite (定量) | ✅ 112 | ✅ 112 | 撞 1Gbps 墙 |
| mseqwrite (定量) | ✅ 112 | ✅ 112 | 撞墙 |
| layout (定量) | ✅ 112 | ✅ 112 | 撞墙 |
| randread (128job) | ✅ 93.2 | ✅ 173.0 | ra0 +86%（EC 跨 3 节点并行）|
| randwrite-true (128job) | ✅ 112.8 | ✅ 113.0 | 撞墙 |
| randrw R (128job) | ✅ 61.0 | ✅ 83.5 | ra0 +37% |
| randrw W (128job) | ✅ 61.5 | ✅ 84.0 | — |
| randwrite-ow (128job) | ⏳ 测试中 | ⏳ 测试中 | 限速口径 0% 波动（117/117）|

> 限速读聚合上限 ≈ 3×118=354 MiB/s（TBF 在 3 slave egress，客户端 157 ingress 不限）。写类全部撞 1Gbps 墙（~112-117）。

### 旧版可信度表（01-2d 前，全部作废，仅供追溯）

> 01-2d 之前不限速多 job 项大量 ❌无准确值/⚠️fio聚合行（randread 用 bw_log×numjobs 失真、mseqread/randwrite 从无 §8.3、randrw default 未拷回），限速口径全部不可信。**这些已被 01-2d 全量重测（正确 §8.3 + openfiles=128）一次性解决。**

---

## 四、从未解决的问题清单（⚑ 2026-07-17 更新：多数已由 01-2d 解决）

1. ~~**mseqread 从无准确 §8.3**~~ → ✅ **01-2d 解决**：default 3804 / ra0 1909（§8.3）。
2. ~~**randwrite 从无准确 §8.3**~~ → ✅ **01-2d 解决**：randwrite-true default 3635 / ra0 4274（§8.3）。（randwrite-ow 轮间波动根因仍诊断中）
3. ~~**限速口径全部 128-job 项不可信**~~ → ✅ **01-2d C/D 组解决**：randread/randrw/randwrite-true 全部有准确 §8.3（见上表）。
4. ~~**per-job 文件在 157 未拷回**~~ → ✅ **01-2d 解决**：A/B/C/D 各 17 目录 per-job bw_log 全部拷回、§8.3 复算一致。
5. ~~**`--openfiles=100` 假瓶颈**~~ → ✅ **01-2d 解决**：全部改用 `--openfiles=128`（=numjobs）。
6. ⏳ **randwrite-ow 不限速轮间波动 50-100%**（唯一未结项）：A=2004~3015、B=1410~2847，v2 诊断已采集数据（OSD delta/PG/iostat/jfs-stats）待分析。限速口径 0% 波动形成对照。
7. ✅ **后端 EC4+2 随机读裸能力 4300 < 6250 是否可提高**（原"首要瓶颈"待诊断线）→ **01-5 解决**：
   - EC vs Rep 在 RADOS 层基本相当，换 Rep 后端对 rados bench 无显著提升
   - **磁盘非瓶颈**（BeeGFS 同硬件 9045 实测，NVMe 单盘 1.5+ GB/s）
   - Ceph OSD 软件栈在 EC 是瓶颈（4 ops × 250μs = 1000μs/op），Rep 路径非瓶颈（CephFS+Rep 6718 ✅ 达标）
   - **FUSE 是 JuiceFS 主瓶颈**（直接证据：ceph-fuse 单变量对照损失 42%）
   - **rados bench 不能代表后端真实能力**（librados 用户态比 CephFS 内核客户端低效 63%）——librados 使用用户态 messenger，每次网络收发都需 user↔kernel context switch，而 kernel CephFS 内核模块使用内核态 socket 直连 OSD，无此开销
   - 详见 `doc/perf-report/01-5-rados-bench-ec-vs-rep-mechanism-report.md`
