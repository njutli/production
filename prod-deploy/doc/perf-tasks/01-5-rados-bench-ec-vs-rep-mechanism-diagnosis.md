# 任务书 01-5：rados bench EC4+2 vs Replica3 后端机制诊断

> 面向 GLM。**本任务书的定位是「后端 EC4+2 随机读为何慢于副本」的机制诊断**，不是"换池方案选型"。
> 01-2d 给出 rados bench EC4+2 后端裸能力：write ~3500、seqread ~4400、randread ~4400 MB/s，**全部 < 6250 验收线**。
> 01-4 CephFS EC vs Rep 同后端对照已显示 Rep randread 6718 > EC 4608（+46%），**Rep 可达标、EC 不达标**——但 CephFS
> 多一层 MDS/客户端栈，且**当时未抓任何后端机制数据**（无 per-OSD op 计数、无写放大测量、无 cluster 网络流量分拆、无 per-OSD
> 延迟直方图）。**单一"Rep 高于 EC"的数字无说服力**，必须证明**为何** EC 慢于 Rep。
>
> **本任务回答的问题**：
> - EC4+2 随机读 ~4400 < 验收线 6250，是**架构固有上限**还是**可消除的限制**？
> - EC vs Rep 的差距由**哪些机制**造成？（fan-in 尾延迟 / op 计数放大 / cluster 网络流量 / 写放大 / CPU 解码 / per-OSD 队列深度）
> - 如果改用 Rep3 后端能否达标？通过什么机制达标？
>
> 承接：`results/prod-01-2d-fullretest-20260717/`（01-2d EC rados bench 数据）+
> `results/prod-nolimit-rootcause-cephfs-20260716-220958/step3-cephfs/`（01-4 CephFS EC vs Rep）。
> 方法论见 skill：`TESTING-GUIDE.md`、`test-commands-reference.md` §3.3、`LONG-RUNNING-TEST-SKILL.md`。
> 上位规划：`doc/perf-analysis/01-baseline-review-and-nolimit-plan.md` §5.3.4a / §七 / §7.3 决策链
> （"后端 ~4300 < 6250 验收线、CephFS 相近则回头攻后端 EC→副本"——本任务执行该决策链）。

---

## 〇、背景：为什么不能只看一个数字

### 0.1 现有数据 vs 缺口

| 数据 | 来源 | EC | Rep | Rep/EC | 缺什么 |
|------|------|----|----|--------|--------|
| rados bench EC 裸能力 | 01-2d §3.3 | ~4400 randread | — | — | 无 Rep 对照；无机制数据 |
| CephFS EC vs Rep | 01-4 step3 | 4608 S0 | 6718 S0 | 1.46× | 多了 MDS 栈；无后端机制数据 |
| 老 exp3 EC vs Rep | 07-08 | ~112 randread | ~112 randread | 1.00× | **1Gbps 网卡天花板压平了所有差距**；不可搬到 100GbE |

**三个缺口统一指向同一事实**：我们在 EC vs Rep 上**没有抓任何后端机制数据**。所以即使 Rep > EC，也无法回答"为什么 Rep 更快"——也就无法判断 EC4+2 是否**架构性地**无法达标（vs 只是当前配置下的临时限制）。

### 0.2 用户原则（与 01-4 一致）

> "只有一个副本池高于 EC 的数据没有说服力，我要详细的原因。"

**判定 EC4+2 是否架构受限**，需要：
- 不只比 Rep vs EC 的最终带宽；
- 还要回答"差距由哪些机制贡献、每个机制贡献多少"；
- 才能下"EC 架构受限无法达标"或"EC 受某项可消除限制"的结论。

### 0.3 与 01-4 的关系（避免重复）

01-4 step3 用 CephFS 测过 EC vs Rep（写未崩、Rep 6718 > EC 4608），但：
- CephFS 多一层 MDS + 内核态客户端，引入了非后端的变量；
- 01-4 step3 **未抓任何后端机制数据**（per-OSD op / 写放大 / cluster 网络等）；
- 01-4 的结论是"根因 = FUSE 方案"，CephFS 对照只是佐证。

**本任务直接绕过 CephFS / FUSE / JuiceFS**，用 `rados bench` 直连 RADOS，**单变量**比较 EC4+2 vs Rep3：
- 相同 6 块 OSD NVMe、相同 100GbE 双网、相同 DB/WAL on tmpfs；
- 唯一变量 = pool type（EC k=4 m=2 vs Replicated size=3）；
- 全程抓 6 类机制数据（见 §二）。

---

## 一、目标

**主目标**：在 EC4+2 池和新建 Rep3 池（同一组 6 OSD、同网络、同硬件）上跑**完全相同的 rados bench 参数**（沿用 01-2d §3.3 全模式全档），全程抓 6 类机制数据，回答：

1. **EC4+2 vs Rep3 后端裸能力对比**：write / seqread / randread 三模式 × 4 档 × 3 轮中位数，Rep 比 EC 快多少？Rep 能否达标（≥ 6250）？EC 是否架构受限？
2. **机制归因**：EC vs Rep 的带宽差距由哪几条机制贡献？每条贡献多少？是否可消除？

**判读逻辑**：

| Rep 结果 | EC vs Rep 机制归因 | 判定 |
|----------|-------------------|------|
| Rep ≥ 6250 验收线，且 Rep/EC > 1.3 | fan-in / op 计数放大 / cluster 网络流量起决定作用 | **EC4+2 架构受限，达标需换 Rep3 后端**（由用户拍板） |
| Rep ≥ 6250 但 Rep/EC ≈ 1.0–1.2 | EC vs Rep 差距小，EC 本可接近 6250 但当前未榨满 | **EC 未达上限**，回头查 JuiceFS 客户端（与 01-4 C1 矛盾，需复审） |
| Rep < 6250 但 Rep > EC | 后端 EC/Rep 都不达标，瓶颈在 OSD 硬件/网络 | **后端硬件天花板**，EC vs Rep 均不达标，方案选型无意义 |
| Rep ≈ EC 或 Rep < EC | 推翻 01-4 CephFS "Rep +46%" 结论（CephFS 那次的差距在 MDS 层，非后端） | **后端无差距**，01-4 结论需复审 |

---

## 二、机制假设与数据捕获设计（核心：每个机制对应什么数据）

> **本任务的方法论核心**：不是只跑 rados bench 拿一个 EC vs Rep 数字，而是**每个 (pool, op, -t) 单元**都同时抓 6 类机制数据，让每个机制假设都能被证实 / 证伪 / 量化贡献。

### 2.1 EC4+2 vs Rep3 三条 I/O 路径（背景）

**EC4+2 read（k=4 m=2）**：
- 客户端 → primary OSD P → P 向其余 3 个数据 chunk 持有 OSD 发 subop（cluster 网络）→ 等待 4 片全部到齐 → 解码（仅当 chunk 缺失才需 RS 解码；全片齐备则无解码 CPU 开销）→ 返回客户端
- 1 次 logical read = **4 次 OSD op**（4 个 chunk 各 1 次），分布在 4 个不同 OSD 上
- cluster 网络流量 = 3 × chunk_size（P 自己读 1 个，跨网取 3 个）

**Rep3 read（size=3）**：
- 客户端 → primary OSD P → P 本地磁盘读 → 返回
- 1 次 logical read = **1 次 OSD op**（只 primary 服务，2 副本 idle）
- cluster 网络流量 = 0（读不走副本）

**EC4+2 write（full-stripe, k=4 m=2, 256K 对象）**：
- 客户端 → primary P → P 编码 4 data + 2 parity 共 6 片 → 6 片分发到 6 个 OSD（5 个跨 cluster 网络）→ 全部落盘
- 写放大 = 6/4 = **1.5×**（256K logical → 384K 实际写）
- CPU：primary 做 RS 编码

**EC4+2 write（partial-stripe / sub-stripe）**：
- 客户端 → primary P → P 读回整个 stripe（4 data + 2 parity = 6 片）→ 重算 parity → 写回 6 片
- 写放大 = (6 read + 6 write) / 4 logical = **3.0×**（含读+写）
- 这是 EC overwrite 的最坏路径；Ceph 的 `allow_ec_overwrites` 默认为 false 即为规避此路径

**Rep3 write**：
- 客户端 → primary P → P 写本地 + 跨 cluster 网发 2 副本 → 3 落盘
- 写放大 = 3/1 = **3.0×**（恒定，无 stripe 概念）

### 2.2 六类机制假设与对应数据

每条假设都列出：**机制 / 数据源 / 期望 EC 模式 / 期望 Rep 模式 / 如何量化贡献**。

#### 假设 H1：read fan-in 导致尾延迟主导（EC 独有）

| 项 | 内容 |
|----|------|
| 机制 | EC 一次 logical read 等待 4 个 OSD 响应，effective 延迟 = max(4)；Rep 仅 1 个，effective = 单 OSD 延迟 |
| 数据源 | **per-OSD `osd.op_r_lat` 直方图**（admin socket perf dump，取 `osd_op_latency` / `osd_op_r_process_latency`）<br>**per-OSD `osd.op_wip`**（in-flight ops）<br>**rados bench 输出 Min/Max/Avg IOPS + Stddev** |
| 期望 EC | per-OSD 单 op 延迟 P50/P99 接近 Rep；但 client 端观察的 Max IOPS 低 / Stddev 大（因 fan-in 放大尾延迟） |
| 期望 Rep | per-OSD op 延迟同上；client 端 Max IOPS 高 / Stddev 小 |
| 量化 | EC client-observed P99 ≈ max of 4 OSD P99s ≫ 任一单 OSD P99；Rep client-observed P99 ≈ 单 OSD P99。**贡献 = EC 客户端尾延迟 - 单 OSD 平均尾延迟** |

#### 假设 H2：op 计数放大（EC 4× / Rep 1×）

| 项 | 内容 |
|----|------|
| 机制 | EC 一次 logical read = 4 次 OSD op（k=4 个 chunk）；Rep = 1 次。同 logical IOPS 下 EC 在后端产生 4× ops |
| 数据源 | **per-OSD `osd.op_r` / `osd.op_w` 计数器**（perf dump pre/post delta）<br>**rados bench 报告的 Avg IOPS**（= logical ops） |
| 期望 EC | (sum of per-OSD op_r delta) / (rados bench Avg IOPS × runtime) ≈ **4.0**（k=4） |
| 期望 Rep | 同上 ≈ **1.0**（只 primary） |
| 量化 | op 放大本身不直接造带宽差距，但**意味着同 logical 并发下 EC per-OSD op 队列深度 2× 于 Rep**（4 ops 分布到 6 OSD = 0.67×/OSD；1 op 分布到 3 primary = 0.33×/OSD；EC/Rep per-OSD 队列比 = 2.0×）。若 per-OSD 队列已达饱和点，EC 在更低 logical IOPS 就饱和 → 带宽天花板更低 |

#### 假设 H3：per-OSD 队列深度与磁盘 util（H2 的物理后果）

| 项 | 内容 |
|----|------|
| 机制 | 同 logical IOPS 下 EC per-OSD 多 2× ops 排队 → 磁盘 %util 更早撞顶 / await 更高 |
| 数据源 | **`iostat -x 1`** 逐秒（per-OSD：r/s, rkB/s, await, %util, aqu-sz）<br>**per-OSD `osd.op_wip`**（in-flight） |
| 期望 EC | 各 OSD `%util` 跑满 → await 上升 → 单 op 延迟上升 → 带宽天花板撞墙 |
| 期望 Rep | 各 primary OSD `%util` 仅一半（3 个 primary 共享 load，3 个 replica 空闲）；await 低；有余量 → 可继续涨 IOPS |
| 量化 | 同 logical IOPS 下 EC per-OSD `%util` 应 ≈ 2× Rep per-OSD（仅 primary 比对）。**EC 撞墙的临界点 = per-OSD 磁盘饱和点** |

#### 假设 H4：cluster 网络流量（EC 独有，read 也走 cluster）

| 项 | 内容 |
|----|------|
| 机制 | EC read：primary 向其余 chunk OSD 取片走 cluster 网络（3 × chunk_size/req）。Rep read：cluster 网络 0 流量 |
| 数据源 | **`sar -n DEV 1` 或 `/proc/net/dev` 1Hz 采样**（cluster NIC = `enp139s0f1np1`，public NIC = `enp139s0f0np0`，3 个 slave 节点全采） |
| 期望 EC randread | cluster NIC 流量 ≈ client IOPS × 3 × 64K（k=4，chunk=256K/4=64K，跨网取 3 片）→ 1.875× logical MB/s |
| 期望 Rep randread | cluster NIC 流量 ≈ 0 |
| 量化 | EC cluster 网络 MB/s / logical MB/s 比值，与 1.875 理论值对照。**若 EC cluster 网卡接近线速（12.5 GB/s × 3 节点 = 37.5 GB/s）→ 网络饱和是天花板**；若远低于线速，cluster 网络不是瓶颈 |

#### 假设 H5：写放大差异（H2 在写路径上的具象）

| 项 | 内容 |
|----|------|
| 机制 | EC full-stripe write = 1.5× 放大；EC partial-stripe = 3.0×（含读+写）；Rep = 3.0×（恒定） |
| 数据源 | **per-OSD `osd.op_w_in_bytes` delta** / (rados bench 报告的 logical bytes written)<br>**`ceph osd pool get <pool> stripe_width`** + `ec_profile`（确认 stripe_width / chunk_size） |
| 期望 EC write | 若 256K 对象对齐 stripe → 放大 ≈ **1.5×**（EC 写应快于 Rep）；若不对齐 → 放大 ≈ **3.0×** 或更高（RMW，EC 写慢于或 ≈ Rep） |
| 期望 Rep write | 放大 ≈ **3.0×** 恒定 |
| 量化 | 写放大比值 EC vs Rep 直接对照。**理论：EC full-stripe 写应快于 Rep**（1.5× vs 3.0×）；若实测 EC 写慢于 Rep，则非写放大主导（看 H6 CPU / H1 fan-in）。07-08 老数据 EC 51 vs Rep 27 支持"EC 写更快"（EC +89%） |

#### 假设 H6：CPU 编码 / 解码开销（写路径为主）

| 项 | 内容 |
|----|------|
| 机制 | EC 写：primary 做 Reed-Solomon 编码（真 CPU 工作）；EC 读：**全片齐备无解码**，无需 RS；Rep：仅 memcpy |
| 数据源 | **`pidstat -p <osd_pids> -u -h 1` 或 `top -b -p <osd_pids>` 1Hz**（per-OSD CPU%）<br>各 slave 节点 `mpstat -P ALL 1`（看整机 + per-core） |
| 期望 EC write | OSD CPU 显著高于 Rep write（编码开销） |
| 期望 EC read | OSD CPU ≈ Rep read（无解码） |
| 期望 Rep | write/read CPU 都低（无编码） |
| 量化 | EC write CPU - Rep write CPU = RS 编码成本；EC read CPU - Rep read CPU ≈ 0（若 ≈ 0 则证伪"EC read 有解码开销"假设） |

### 2.3 数据采集矩阵总表

每个 (pool, op, -t, round) 单元，按"前 / 中 / 后"三段采集：

| 阶段 | 工具 / 命令 | 频率 | 范围 | 用途 |
|------|------------|------|------|------|
| **PRE** | `ceph osd pool stats <pool>` | 1 次 | 集群 | baseline op 计数（算 delta） |
| PRE | `ceph tell osd.<X> perf dump`（每 OSD 一次，6 个） | 1 次 | 3 节点 × 2 OSD | baseline op_r/op_w/lat/in-flight |
| PRE | `ip -s link show enp139s0f0np0` + `...f1np1` | 1 次 | 3 节点 | baseline NIC 字节计数（算 delta） |
| PRE | `ceph osd pool get <pool> stripe_width ec_profile` | 1 次（pool 建 + 测前各 1） | 集群 | 确认 stripe 配置（H5） |
| PRE | `ceph -s` | 1 次 | 集群 | 确认 HEALTH_OK + 无 recovery |
| **DURING** | `iostat -x 1` 后台采 | 1 Hz | 3 节点（每节点采 nvme2n1/nvme3n1） | H3 per-OSD 磁盘 util/await/队列 |
| DURING | `sar -n DEV 1` 或 `cat /proc/net/dev` 后台采 | 1 Hz | 3 节点（public + cluster NIC） | H4 cluster 网络流量 |
| DURING | `pidstat -p <osd_pids> -u -h 1` 或 `top -b -d 1 -p <osd_pids>` | 1 Hz | 3 节点（4 个 OSD PID/节点） | H6 per-OSD CPU |
| DURING | `ceph osd pool stats <pool>` | 5 Hz（每 5s） | 集群 | per-pool 实时 op rate |
| **POST** | `ceph tell osd.<X> perf dump`（同 PRE） | 1 次 | 3 节点 × 2 OSD | 终态 op_r/op_w/lat（与 PRE delta 算放大比 H2/H5） |
| POST | `ip -s link show ...`（同 PRE） | 1 次 | 3 节点 | 终态 NIC 字节（与 PRE delta 算 H4 流量） |
| POST | `ceph osd pool stats <pool>` | 1 次 | 集群 | 终态 op rate |
| POST | `ceph health detail` | 1 次 | 集群 | 确认全程无 alert |
| 全程 | rados bench 完整输出（含 cur MB/s 逐秒） | — | 157 client | 带宽 + IOPS + Stddev + Min/Max |

> **每档每轮一条逻辑**：跑 rados bench 60s 的同时，3 个 slave 节点后台并行跑 iostat + sar + pidstat 三路 1Hz 采样；rados bench 跑完立即 POST snapshot。**PRE/DURING/POST 必须用同一份脚本驱动**（见 §五 commands.sh 模板），保证每个 cell 的采集口径完全一致。

### 2.4 量化机制贡献的分析方法

测试完所有 cell 后，按下列方法**把每个机制的贡献量化**：

| 机制 | 量化公式 | 数据源 |
|------|---------|--------|
| H1 fan-in 尾延迟 | EC Max IOPS / Avg IOPS 比 vs Rep 同比；EC client-observed P99 - 单 OSD P99 = fan-in 放大量 | rados bench Min/Max/Avg + per-OSD lat 直方图 |
| H2 op 计数放大 | (Σ OSD op_r delta) / (logical op_r) → EC 应 ≈ 4.0 / Rep ≈ 1.0 | per-OSD perf dump pre/post |
| H3 per-OSD 队列饱和 | 同 logical IOPS 下 EC per-OSD %util / Rep per-OSD %util → 应 ≈ 2.0；找 %util=100% 的临界点 | iostat 1Hz |
| H4 cluster 网络流量 | EC cluster NIC MB/s / logical MB/s → 应 ≈ 1.875；若接近 100GbE 线速则饱和 | sar/net-dev 1Hz + rados bench BW |
| H5 写放大 | (Σ OSD op_w_in_bytes delta) / (logical bytes written) → EC full-stripe ≈ 1.5 / Rep ≈ 3.0 | per-OSD perf dump + rados bench |
| H6 CPU 编码 | EC write OSD CPU% - Rep write OSD CPU% = RS 编码成本；EC read - Rep read ≈ 0 | pidstat/top 1Hz |

**结论模板**（写进 §六 summary）：

> EC4+2 随机读 ~4400 MB/s vs Rep3 ~X MB/s，差距 Δ MB/s 由以下机制贡献：
> - H1 fan-in 尾延迟贡献 X1%（fan-in 放大系数 4 → Max IOPS / Avg IOPS = Y%）
> - H3 per-OSD 队列饱和贡献 X2%（EC per-OSD %util 在 -t Y 时撞 100%，Rep 仅 Z%）
> - H4 cluster 网络流量贡献 X3%（EC cluster NIC 占 W% 线速）
> - H2/H5/H6 在 read 路径上无主导贡献（量化值 <5%）
> → 结论：[EC 架构受限 / 受某机制限制可消除 / 后端硬件天花板]

---

## 三、测试矩阵

### 3.1 池配置

| 池 | type | size/k,m | failure_domain | pg_num | allow_ec_overwrites | 备注 |
|----|------|----------|----------------|--------|---------------------|------|
| `juicefs-data` | EC | k=4 m=2 | osd | 32 | true（01-2d 现状，rados bench write 不触发 RMW） | 现有池 |
| `juicefs-data-rep` | Replicated | size=3 | osd | 32 | n/a | **本任务新建**（见 §3.2） |

> **关键**：两池共用**同一组 6 块 OSD**（nvme2n1 × 3 + nvme3n1 × 3），failure_domain 都是 osd，pg_num 相同。**唯一变量 = pool type**。这是最干净的单变量对照。

### 3.2 新建 Rep3 池命令

```bash
# 1. 建 replicated pool（与 EC 池相同的 6 OSD、相同 crush rule osd-level）
ceph osd pool create juicefs-data-rep 32 32 replicated=3

# 2. 应用 crush rule（osd-level failure domain，与 EC 池一致）
#    若 default rule 不是 osd-level，需自建 rule
ceph osd crush rule ls                      # 查现有 rule
# 若需自建（与 EC 池同 rule）：
# ceph osd crush rule create-replicated rep-osd-rule default osd
# ceph osd pool set juicefs-data-rep crush_rule rep-osd-rule

# 3. 验证对象分布到全部 6 OSD（必须 6/6 都有 PG）
ceph pg dump | grep juicefs-data-rep | head
ceph osd pool stats juicefs-data-rep

# 4. 配 cephx 权限（与 EC 池相同 user，授权新 pool）
ceph auth caps client.juicefs mon 'allow r' osd 'allow rwx pool=juicefs-data, allow rwx pool=juicefs-data-rep'

# 5. 确认 stripe_width / crush_rule 等元信息（写入 env-snapshot）
ceph osd pool get juicefs-data all > pool-ec-profile.txt
ceph osd pool get juicefs-data-rep all > pool-rep-profile.txt
```

> **pre-test 必须验证**：Rep 池的对象确实分布到全部 6 个 OSD（pg_num=32 + size=3 + osd-level failure domain → 每个 OSD 应有 ~16 PG）；如果只分布到 3 个 OSD（failure_domain 错了），对照失效。

### 3.3 rados bench 矩阵（完全沿用 01-2d §3.3）

| Phase | 模式 | -t 档 | runtime | REPEAT | 池 | 每池 cell 数 |
|-------|------|------|---------|--------|----|------|
| 1 | write | 16, 128, 1024, 4096 | 60s | 3 | EC + Rep | 4 × 3 × 2 = 24 |
| 2 | prefill | 16 | 120s | 1 | EC + Rep | 2（为 read 准备对象） |
| 3 | seq | 16, 128, 1024, 4096 | 60s | 3 | EC + Rep | 24 |
| 4 | rand | 128, 1024, 4096, 16384 | 60s | 3 | EC + Rep | 24 |

**总单元数**：72 个 rados bench cell（不含 prefill）+ 2 个 prefill。
**预计耗时**：72 × 60s ≈ 72 min rados bench + 72 × (cleanup + compact cooldown ~ 60s + drop_caches ~ 10s) ≈ 84 min；总 ~3 小时含 PRE/DURING/POST snapshot 开销。

> 与 01-2d §3.3 一致：每档 REPEAT=3 取中位数，每轮间 compact cooldown + drop_caches。每档之间必须 compact cooldown（前轮 -t1024 → -t4096 连锁退化教训）。
>
> **关键约束**（沿用 01-2d §3.3 红线）：
> - `-b 262144` 只在 write 模式有效；seq/rand 模式对象大小由 prefill 决定（256K）
> - `--run-name` 标记对象，cleanup 只删该 run-name
> - 每档每轮间必须 compact cooldown + drop_caches（client + 3 slave）
> - compact 验证：`compact_running=0` + `compact_queue_len=0` + `get_latency avg < 10μs` 四绿
> - 方差判据：Min/Max IOPS < 0.7 或 Stddev/Avg > 15% → 该轮作废重采
> - `-t 16384`：157 有 1007 GB RAM，8MB 栈 × 16384 = 128 GB，在可用范围

### 3.4 执行顺序（按池串行 + 池内按 phase 串行）

```
A. EC 池（juicefs-data）
   A.0 PRE: 验证 HEALTH_OK + 池干净 + compact 三绿 + pool profile 快照
   A.1 write sweep (4 档 × 3 轮) — 每档每轮 PRE/DURING/POST 全采
   A.2 cleanup + compact cooldown + drop_caches
   A.3 prefill (120s, -t16)
   A.4 compact cooldown + drop_caches
   A.5 seq read sweep (4 档 × 3 轮)
   A.6 compact cooldown + drop_caches（每档间亦然）
   A.7 rand read sweep (4 档 × 3 轮)
   A.8 cleanup + compact cooldown

B. 切 Rep 池（juicefs-data-rep）
   B.0 PRE: 验证 HEALTH_OK + 池干净 + PG 分布到 6 OSD + pool profile 快照
   B.1–B.8 同 A

C.（可选）若 A/B 任一组数据异常，回 EC 池重测对比 cell 验证可复现
```

> **EC 先、Rep 后**：EC 池已存在、状态稳定；新建 Rep 池后先稳定 PG 分布再测。**严禁 EC/Rep 交错**：切换池会增加 state contamination 风险。

> **不混跑 BeeGFS**：150/151/152 的 NVMe 与 BeeGFS 抢盘，必须错峰（沿用 01-4 红线）。

---

## 四、固定配置

### 4.1 rados bench 命令模板（与 01-2d §3.3 一致）

```bash
POOL=jjuicefs-data            # EC 池；Rep 池换 juicefs-data-rep
RUNNAME=jjuicefs-rados        # 标记对象，cleanup 用

# Phase 1: Write sweep
for t in 16 128 1024 4096; do
  for r in 1 2 3; do
    # PRE snapshot (见 §2.3)
    capture_pre "${POOL}-write-t${t}-r${r}"
    # DURING start background sampling on 3 slaves
    start_bg_sampling "${POOL}-write-t${t}-r${r}"
    # compact cooldown + drop_caches
    sudo rados -p ${POOL} cleanup --run-name ${RUNNAME} 2>/dev/null
    compact_cooldown; drop_caches_all
    # rados bench
    sudo rados bench -p ${POOL} 60 write -b 262144 -t ${t} --no-cleanup --run-name ${RUNNAME} \
      | tee rados-${POOL}-write-t${t}-r${r}.txt
    # POST snapshot + stop bg sampling
    stop_bg_sampling "${POOL}-write-t${t}-r${r}"
    capture_post "${POOL}-write-t${t}-r${r}"
  done
done
sudo rados -p ${POOL} cleanup --run-name ${RUNNAME} 2>/dev/null
compact_cooldown

# Phase 2: Prefill
sudo rados bench -p ${POOL} 120 write -b 262144 -t 16 --no-cleanup --run-name ${RUNNAME} \
  | tee prefill-${POOL}.txt
compact_cooldown; drop_caches_all

# Phase 3: Seq read sweep
for t in 16 128 1024 4096; do
  for r in 1 2 3; do
    capture_pre "${POOL}-seqread-t${t}-r${r}"
    start_bg_sampling "${POOL}-seqread-t${t}-r${r}"
    compact_cooldown; drop_caches_all
    sudo rados bench -p ${POOL} 60 seq -t ${t} --run-name ${RUNNAME} \
      | tee rados-${POOL}-seqread-t${t}-r${r}.txt
    stop_bg_sampling "${POOL}-seqread-t${t}-r${r}"
    capture_post "${POOL}-seqread-t${t}-r${r}"
  done
done

# Phase 4: Rand read sweep
for t in 128 1024 4096 16384; do
  for r in 1 2 3; do
    capture_pre "${POOL}-randread-t${t}-r${r}"
    start_bg_sampling "${POOL}-randread-t${t}-r${r}"
    compact_cooldown; drop_caches_all
    sudo rados bench -p ${POOL} 60 rand -t ${t} --run-name ${RUNNAME} \
      | tee rados-${POOL}-randread-t${t}-r${r}.txt
    stop_bg_sampling "${POOL}-randread-t${t}-r${r}"
    capture_post "${POOL}-randread-t${t}-r${r}"
  done
done

# Phase 5: Cleanup
sudo rados -p ${POOL} cleanup --run-name ${RUNNAME} 2>/dev/null
compact_cooldown
```

### 4.2 PRE/DURING/POST snapshot 脚本骨架（见 §五 commands.sh 完整版）

```bash
# PRE: 3 slave 节点 + 集群层
capture_pre() {
  local tag=$1
  ssh_to_slave_all "echo '== ${tag} PRE ==' ; ceph osd pool stats ${POOL} ; ip -s link show enp139s0f0np0 ; ip -s link show enp139s0f1np1"
  ssh_to_slave_all "for osd in 0 1 2 3 4 5; do ASOK=/var/run/ceph/\$(sudo ceph fsid)/ceph-osd.\${osd}.asok; [ -S \$ASOK ] && sudo ceph --admin-daemon \$ASOK perf dump; done" > perf-pre-${tag}.json
  ceph -s > ceph-pre-${tag}.txt
}

# DURING: 后台启动 iostat + sar + pidstat on 3 slaves
start_bg_sampling() {
  local tag=$1
  for ip in "${SLAVE_SERVERS[@]}"; do
    ssh_to_slave "${ip}" "iostat -x 1 > /tmp/iostat-${tag}-${ip}.log 2>&1 &"
    ssh_to_slave "${ip}" "sar -n DEV 1 > /tmp/sar-${tag}-${ip}.log 2>&1 &" \
      || ssh_to_slave "${ip}" "while true; do cat /proc/net/dev; sleep 1; done > /tmp/netdev-${tag}-${ip}.log 2>&1 &"
    OSD_PIDS=$(ssh_to_slave "${ip}" "pgrep -f 'ceph-osd.*osdid'")  # 取本节点 2 个 OSD 的 PID
    ssh_to_slave "${ip}" "pidstat -p ${OSD_PIDS} -u -h 1 > /tmp/pidstat-${tag}-${ip}.log 2>&1 &" \
      || ssh_to_slave "${ip}" "top -b -n 999999 -d 1 -p ${OSD_PIDS} > /tmp/top-${tag}-${ip}.log 2>&1 &"
  done
}

# POST: 同 PRE + kill 后台采样
stop_bg_sampling() {
  local tag=$1
  ssh_to_slave_all "pkill -f 'iostat.*${tag}'; pkill -f 'sar.*${tag}'; pkill -f 'pidstat.*${tag}'; pkill -f 'top.*${tag}'"
  # 拷回采样日志（经 HK 跳板）
  for ip in "${SLAVE_SERVERS[@]}"; do
    scp_from_slave "${ip}" /tmp/iostat-${tag}-${ip}.log "${RESULTS_DIR}/"
    scp_from_slave "${ip}" /tmp/sar-${tag}-${ip}.log "${RESULTS_DIR}/"
    scp_from_slave "${ip}" /tmp/pidstat-${tag}-${ip}.log "${RESULTS_DIR}/"
  done
  capture_pre "${tag/_PRE/_POST}"   # 复用 PRE 脚本，tag 改 POST
}
```

### 4.3 EC 池清理（沿用 01-2d §3.3 + TESTING-GUIDE §3.5）

- `rados -p juicefs-data cleanup --run-name ${RUNNAME}` 删 rados bench 自己的对象
- 不用 `juicefs destroy`（rados bench 对象不属于 JuiceFS）
- 若 EC 池当前有 JuiceFS 卷的数据：测前先确认 `rados df -p juicefs-data` 干净（01-2d 测后已 cleanup）；如不干净，用 `juicefs destroy` 走标准清卷流程
- 测完再次 `rados df` 确认归零

---

## 五、交付物

```
results/prod-01-5-rados-ec-vs-rep-mechanism-<YYYYMMDD-HHMMSS>/
├── commands.sh                       # 完整可执行命令记录（含 capture_pre/during/post 模板）
├── env-snapshot.txt                  # HEALTH_OK + 6 OSD up + 双网 + 无 tc + 池 profile (EC+Rep)
├── pool-ec-profile.txt               # ceph osd pool get juicefs-data all（stripe_width / ec_profile / crush_rule）
├── pool-rep-profile.txt              # ceph osd pool get juicefs-data-rep all
├── ec/                               # EC 池所有 cell
│   ├── write-t16-r1.txt              # rados bench 输出（每档每轮 1 个）
│   ├── write-t16-r1-iostat-node1.log # 每档每轮 × 3 slave × 3 工具 = 9 个采样日志
│   ├── write-t16-r1-sar-node1.log
│   ├── write-t16-r1-pidstat-node1.log
│   ├── write-t16-r1-perf-pre.json   # PRE OSD perf dump
│   ├── write-t16-r1-perf-post.json  # POST OSD perf dump
│   ├── write-t16-r1-ceph-pre.txt    # PRE ceph -s
│   ├── write-t16-r1-ceph-post.txt   # POST ceph -s
│   ├── ... (4 档 × 3 轮 × 3 模式 = 36 cell × 12 文件 ≈ 432 文件)
│   └── prefill.txt
├── rep/                              # Rep 池所有 cell（同 ec/ 结构）
└── summary.md                        # 机制诊断报告（§六模板）
```

**输出分析报告（强制）**：完成后建 `doc/perf-report/01-5-ec-vs-rep-mechanism-report.md`，正文含：
- 目的（§〇）
- 池配置对照（§3.1）
- EC vs Rep 三模式带宽中位数表（§3.3）
- 6 类机制数据汇总 + 量化贡献（§2.4）
- 判定（§一判读逻辑）
- 后续动作（EC 架构受限 → 用户拍板是否换 Rep3；后端硬件天花板 → OSD/NVMe 扩容；EC 未榨满 → 回 JuiceFS 客户端复审）

不写 perf-analysis/（只放计划文档）；实测追加 `doc/deploy-log/results-table.md`。

---

## 六、通用注意事项（每份任务书必带，本任务特有红线加粗）

> 引用 `TASK-BOOK-AUTHORING-GUIDE.md` §二通用注意事项六条（数据统计口径 / 冷态净化 / fresh-volume / 后端干净态 / 环境前置 / 记录规范 / 卷清理）。本任务为 rados bench 直测后端，不涉及 fio bw_log / fresh-volume，但仍须遵守：

1. **REPEAT=3 取中位数**，禁止取平均、禁止挑轮次。3 轮全保留。
2. **每档每轮间 compact cooldown + drop_caches**（client + 3 slave 全做）。compact 三绿 + `get_latency avg < 10μs` 四绿才继续。
3. **数据异常必须当场排查**（沿用 01-2d-1 教训）：Min IOPS=0、Stddev/Avg > 15% 等异常逐秒分析，不得跳过。
4. **`rados bench` 值仅供后端量级参照，禁止与 fio 值跨工具相除算"FUSE 开销/倍率"**。
5. **157 红线**：禁动 157 内核 / 100GbE 网卡 / RoCE / md0 / WekaIO 路径；BeeGFS 与本测试错峰用盘。
6. **commands.sh 必须含完整 capture_pre/during/post 脚本**，让单 cell 采集口径完全一致、可复现。

### 6.1 本任务特有红线

- **R1（变量隔离）**：EC 池和 Rep 池必须共用同一组 6 OSD、同一 crush rule（osd-level failure domain）、同一 pg_num=32、同一硬件配置。**唯一变量 = pool type**。Rep 池建好后必须 `ceph pg dump` 验证对象分布到全部 6 OSD（不只 3 个）。
- **R2（采集口径一致）**：72 个 cell 必须用同一份 capture 脚本驱动 PRE/DURING/POST snapshot。任何 cell 的 PRE/DURING/POST 缺失 → 该 cell 作废重跑。后台采样起止时间必须严格包裹 rados bench 起止时间（pre → start_bg → rados bench → stop_bg → post）。
- **R3（机制归因必须量化）**：summary 必须给出 6 类机制的量化贡献（§2.4 表），禁止只报"Rep 比 EC 快 X%"一个数字。每类机制的数据源文件路径在 summary 中可追溯。
- **R4（pool 清理纪律）**：rados bench 用 `--run-name`，cleanup 只删本 run-name 对象。**测前 / 测后必须 `rados df -p <pool>`** 确认对象数符合预期（prefill 后 ~1M，cleanup 后归零）。EC 池若有 JuiceFS 卷残留数据，先 `juicefs destroy` 清卷再开测。
- **R5（不切网络环境）**：本任务全程在不限速 100GbE 双网下进行，**不切限速**（01-2d C/D 已测限速口径，本任务是后端机制诊断，与限速无关）。
- **R6（不与 01-4 step3 CephFS 数据混读）**：01-4 step3 的 EC vs Rep 是 CephFS 栈，本任务是 rados bench 直测后端。**两份独立**，CephFS 数据可作旁证但不替代本任务的机制数据。summary 必须显式列出两份的差异（rados bench 绕过 MDS/FUSE vs CephFS 不绕）。

---

## 七、总结

本任务书的核心目的是：**用单变量对照 + 全程机制数据采集，证明 EC4+2 vs Rep3 在后端裸能力上的差距由哪些机制贡献、各贡献多少**，而不是只拿到一个"Rep 高于 EC"的数字。

完成后产出：
- EC vs Rep 三模式 × 4 档 × 3 轮中位数带宽表（72 cell）
- 6 类机制量化贡献表（fan-in 尾延迟 / op 计数放大 / per-OSD 队列饱和 / cluster 网络流量 / 写放大 / CPU 编解码）
- 判定：EC4+2 是架构受限 / 受某机制限制可消除 / 后端硬件天花板

**用户的决策需要这份机制数据支撑**：
- 若 EC 架构受限 → 是否换 Rep3 后端（容量换性能的代价由用户拍板）
- 若后端硬件天花板 → OSD/NVMe 扩容方向
- 若 EC 未榨满 → 回 JuiceFS 客户端复审（与 01-4 C1 结论矛盾时需复审）
