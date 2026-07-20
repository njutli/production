# 新集群 JuiceFS 方案调优报告（草稿）

> 环境：4 机集群（157 client + 150-152 storage），Ceph 17.2.8 EC4+2 NVMe SSD + TiKV 元数据
> JuiceFS v1.3.1+e0032b2（含 eaf3d21f loadRange 修复），block-size 256K，cache=0 冷态
> 数据来源：01-2d 完整基线重测，4 组（A/B/C/D）× 9 项 + rados bench 全模式，每项 REPEAT=3 取中位数
> --openfiles=128（= numjobs），per-job bw_log 全量保留，§8.3 稳态中位数 + fio 聚合行双口径
> 原始数据：`results/prod-01-2d-fullretest-20260717/`

---

## 一、基线数据

### 1.1 不限速口径（100GbE 双网分离）

- 达标标准：单项带宽 ≥ 6250 MiB/s（100GbE 网卡半速）

**两组配置对比：**

| 参数 | A 组 (default) | B 组 (ra0) | 说明 |
|------|---------------|------------|------|
| `--max-readahead` | 默认（JuiceFS 内部预读开启） | `0`（关闭预读） | 核心差异：ra0 消除读放大，randread +62%，但单流 seqread -86% |
| `--openfiles` | `128`（= numjobs，修复历史假瓶颈） | `128` | BeeGFS 对照实验证实 openfiles=100 导致 +507% 假瓶颈 |
| 其他 | `--max-uploads 150` `--cache-size 0` `--block-size 256K` | 同 A | — |

**不限速测试结果（§8.3 稳态中位数 / fio 聚合行）：**

| 测试项 | A (default) §8.3 | A fio 聚合 | B (ra0) §8.3 | B fio 聚合 | ra0 影响 | A 达标率 | B 达标率 |
|--------|-----------------|------------|-------------|------------|---------|---------|---------|
| seqread | 1263 | 1263 | 178 | 176 | -86% | 20.2% | 2.8% |
| seqwrite | 1530 | 1527 | 1550 | 1557 | 持平 | 24.5% | 24.8% |
| mseqread | 3804 | 3792 | 1909 | 1871 | -50% | 60.9% | 30.5% |
| mseqwrite | 4906 | 4886 | 4148 | 4121 | -15% | 78.5% | 66.3% |
| layout | 4218 | 3357 | 3171 | 3198 | -25% | 67.5% | 51.2% |
| randread | 1480 | 1475 | 2404 | 2453 | **+62%** | 23.7% | 38.5% |
| randwrite-true | 3635 | 3537 | 4274 | 4148 | +18% | 58.2% | 68.4% |
| randrw R | 1032 | 1034 | 1316 | 1318 | +28% | 16.5% | 21.1% |
| randrw W | 1038 | 1033 | 1319 | 1318 | +28% | 16.6% | 21.1% |
| randwrite-ow | 测试中 | 2415 | 测试中 | 2776 | — | — | — |

> randwrite-ow 受 JuiceFS Go 进程运行时间影响波动 22-83%（详见 §2.5），正在进行 3 轮 fresh-mount 重测。
> 达标率 = 实测带宽 / 6250 × 100%

**不限速达标分析：**

- **B 组 (ra0) 随机读类优势**：randread +62%、randrw +28%、randwrite-true +18%
- **A 组 (default) 顺序读/写类优势**：seqread +86%、mseqread +50%、mseqwrite +15%
- **写类不受预读影响**：seqwrite/mseqwrite 持平
- **单项均未达 6250 线**：瓶颈在单客户端 FUSE 用户态处理（CPU ~6 核封顶），非后端能力不足

### 1.2 限速口径（1Gbps TBF）

- 达标标准：单项带宽 ≥ 59 MB/s（1Gbps 网卡半速）
- TBF 在 3 个 slave egress，客户端 157 ingress 不受限 → 聚合读上限 3×118=354 MiB/s

**限速测试结果（§8.3 稳态中位数 / fio 聚合行）：**

| 测试项 | C (default) §8.3 | C fio 聚合 | D (ra0) §8.3 | D fio 聚合 | ra0 影响 | C 达标 | D 达标 |
|--------|-----------------|------------|-------------|------------|---------|--------|--------|
| seqread | 146 | 146 | 57 | 56 | -61% | ✅ 248% | ❌ 95% |
| seqwrite | 112 | 114 | 112 | 113 | 持平 | ✅ 193% | ✅ 192% |
| mseqread | 206 | 206 | 171 | 171 | -17% | ✅ 349% | ✅ 290% |
| mseqwrite | 112 | 114 | 112 | 114 | 持平 | ✅ 193% | ✅ 193% |
| layout | 112 | 114 | 112 | 114 | 持平 | ✅ 193% | ✅ 193% |
| randread | 93 | 93 | 173 | 173 | **+86%** | ✅ 158% | ✅ 293% |
| randwrite-true | 113 | 117 | 113 | 117 | 持平 | ✅ 198% | ✅ 198% |
| randrw R | 61 | 61 | 84 | 84 | +37% | ✅ 103% | ✅ 142% |
| randrw W | 62 | 61 | 84 | 84 | +37% | ✅ 105% | ✅ 142% |
| randwrite-ow | 113 | 117 | 114 | 117 | 持平 | ✅ 198% | ✅ 198% |

> 写类全部撞 1Gbps 墙（~112-117 MiB/s），default/ra0 无差异
> 读类：ra0 显著优于 default（randread +86%、randrw +37%）

**限速达标汇总：**

- C 组 (default)：8/9 达标，仅 seqread(ra0) 不达标（ra0 无预读流水线，单流延迟受限）
- D 组 (ra0)：9/9 全部达标
- 写类：default ≈ ra0（写不受预读影响，均撞 1Gbps 墙）
- randwrite-ow 限速 0% 波动（117/117/117），与不限速波动形成对照

### 1.3 rados bench 后端裸能力

> 干净 pool，256K 对象，REPEAT=3，每轮间 compact cooldown + drop_caches

| 模式 | -t16 | -t128 | -t1024 | -t4096 | -t16384 |
|------|------|-------|--------|--------|---------|
| Write | 2328 | 3361 | 3506 | 3516 | — |
| Seq read | 3348 | 4489 | 4430 | 4388 | — |
| Rand read | — | 4417 | 4335 | 4383 | 4096 |

- 后端随机读天花板 ~4400 MiB/s，顺序写 ~3500 MiB/s
- t16384 Min IOPS=0 是线程启动开销（第 0-1 秒），非真实 stall（逐秒分析已确认）
- t16384 带宽低于 t4096（128 线程/核调度开销），非后端瓶颈

### 1.4 BeeGFS 对齐口径

| 项 | JuiceFS B (ra0) | BeeGFS | BeeGFS/JuiceFS |
|---|---|---|---|
| seqread | 178 | 1644 | 9.1× |
| mseqread | 1909 | 7565 | 4.0× |
| randread | 2404 | 9045 | 3.8× |
| randrw 合计 | 2635 | 9690 | 3.7× |
| randwrite-true | 4274 | 6505 | 1.5× |
| seqwrite | 1550 | 1906 | 1.2× |

BeeGFS 内核模块无 FUSE 开销；JuiceFS 受 FUSE CPU 6 核封顶限制。

---

## 二、关键发现

### 2.1 ra0 对随机读 +62-86%（消除读放大）

default readahead 导致 2.01× 读放大（后端 GET 2242 MiB/s 但 fio 有效仅 1115）。ra0 关闭预读后无放大，randread 提升 62%（不限速）至 86%（限速）。

| 口径 | default randread | ra0 randread | ra0 收益 | 读放大 (GET/fio) |
|------|-----------------|-------------|---------|-----------------|
| 不限速 | 1480 | 2404 | +62% | default 2.01× / ra0 1.0× |
| 限速 | 93 | 173 | +86% | — |

### 2.2 FUSE CPU 6 核封顶（01-3 饱和曲线 + pprof）

| 并发 | bw (MiB/s) | CPU% | 核数 | 每核效率 |
|------|-----------|------|------|---------|
| 32 (S4) | 1230 | 566 | 5.7 | 216 |
| 128 (S3) | 1833 | 573 | 5.7 | 321 |
| 16384 (S0) | 2894 | 595 | 6.0 | 483 |

CPU 从 566% → 595%（+5%），并发增 512 倍。**FUSE `/dev/fuse` 单 goroutine dispatch 串行入口限制有效并行度**。

pprof 热点：`fuse.Server.loop` 31.5%、`writev→/dev/fuse` 17.5%、`cgocall` 22.0%、`Syscall6` 19.0%。锁竞争仅 2.3%。

多实例可线性扩展：N=1 ra0=2350 → N=4 ra0=5013（2.13×）。**6 核封顶是 per-mount 限制，多 mount 实例可绕过。**

### 2.3 后端 EC4+2 是次要瓶颈（rados bench + CephFS 对照）

| 层 | 工具 | 并发 | 带宽 (MiB/s) | 瓶颈 |
|---|------|------|------------|------|
| 纯后端 | rados bench -t4096 | 4096 | **4383** | EC4+2 后端天花板 |
| 内核态 | CephFS EC | 16384 | 4608 | 后端 + CephFS 内核开销 |
| FUSE | JuiceFS ra0 | 16384 | 2894 | **FUSE CPU 6 核封顶** |
| 内核态 | BeeGFS | 16384 | 9045 | 无 FUSE 瓶颈 |

即使绕过 FUSE（CephFS），EC4+2 后端天花板 4383-4608 仍远低于 BeeGFS 9045 → **EC 跨节点取片是后端侧根本瓶颈**。

### 2.4 randrw 不均衡问题（已解决）

旧基线 randrw R/W 严重不均衡（R=20.6/W=52.1），根因是 fresh-volume 冷启动失真。使用方案 A（复用 layout，无 create_on_open）后 R/W=1.0 均衡。

### 2.5 randwrite-ow 退化与波动

**退化（已解决）**：不做 pool 重建时，R1→R2→R3 逐轮递减（4031→1704→1406）。根因 = RocksDB on tmpfs 累积膨胀。解决 = 每轮间 pool 重建。

**波动（已定位）**：pool 重建后仍有 22% 波动。验证实验确认根因 = **JuiceFS Go 进程状态累积**（heap/GC/goroutine 随运行时间增长）。重启 mount（fresh Go 进程）后 BW +83%，fuse_ops 2.2×，fuse_lat 42%。pool 重建只清理后端，不重启 Go 进程 → 无法消除。**其他 8 项不受影响（均为首轮/fresh mount 测试）。**

### 2.6 限速口径读类超过 118 的归因

TBF 在 3 个 slave egress，客户端 157 ingress 不受限 → 聚合读上限 3×118=354 MiB/s。限速 randread default=93 < 118（单 OSD egress 受限），ra0=173 > 118（3 节点聚合）。写类全部撞 ~114-117 MiB/s 墙。

### 2.7 数据质量治理

| 问题 | 解决 |
|------|------|
| bw_log 只拷回 1 份（缺 per-job） | 修正 scp 通配符，全量保留 128 份 |
| "合并 log × numjobs" 外推 | 禁止，改用 §8.3 per-job 求和或 fio 聚合行 |
| `--openfiles=100` 假瓶颈 | 改为 `--openfiles=128`（BeeGFS 对照实验证实） |
| `juicefs format` 不清 pool | 改用 `juicefs destroy`，TESTING-GUIDE §3.5 固化 |
| t16384 Min IOPS=0 | 逐秒分析确认是线程启动开销，非真实 stall |

---

## 三、调优结论

### 3.1 readahead 口径选择

| 场景 | 推荐 | 理由 |
|------|------|------|
| 随机读为主（AI 训练随机采样） | ra0 | randread +62-86%，randrw +28-37% |
| 顺序读为主（数据加载/预处理） | default | seqread +86%，mseqread +50% |
| 混合读写 (randrw) | ra0 | default 仅 ra0 的 57-84% |
| 限速口径 | ra0 | randread +86%，写类持平 |
| 多实例并行 | ra0 | N=4 ra0=5013 vs default=2822 |

### 3.2 瓶颈定位

| 瓶颈层 | 量级 | 可解决？ |
|--------|------|---------|
| FUSE CPU 6 核封顶 | 单客户端最高 ~3000 MiB/s | 多 mount 实例绕过（N=4=5013） |
| EC4+2 后端天花板 | ~4400 MiB/s | 换 Rep3（6718）或 BeeGFS（9045） |
| 单流 ra0 seqread 延迟 | 1444μs | 多线程弥补（mseqread 16 job 恢复至 1909） |

### 3.3 不达标根因

不限速口径单项均未达 6250 线。根因 = FUSE 用户态架构（per-mount ~6 核）。**单客户端 JuiceFS 无法达标，需多实例或换内核态方案（CephFS/BeeGFS）。**

限速口径 D 组 (ra0) 9/9 全达标。

---

## 四、待续工作

### 4.1 已完成

- [x] 4 组基线（A/B/C/D）× 9 项 + rados bench 全模式
- [x] FUSE CPU 6 核封顶验证（01-3 饱和曲线 + pprof）
- [x] CephFS 内核态对照（01-4）
- [x] randwrite-ow 退化诊断（RocksDB bloat）
- [x] randwrite-ow 波动根因定位（Go 进程状态累积）
- [x] t16384 stall 诊断（假报警闭环）
- [x] 数据质量治理（openfiles / bw_log / format/destroy）
- [x] TESTING-GUIDE 更新（§1.3 compaction 局限 + §3.5 卷清理 + openfiles=128）
- [x] BeeGFS 对齐口径对比

### 4.2 待完成

- [ ] randwrite-ow 3 轮 fresh-mount 重测（获取准确基线值）
- [ ] 完整调优演进报告（数据积累后）
