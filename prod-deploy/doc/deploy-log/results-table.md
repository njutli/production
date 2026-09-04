# JuiceFS 测试结果总表（持续更新）

> 口径：冷态基线（cache=0 / 无 writeback）+ 双口径测试，256K block，单客户端。
> 每完成一项测试追加一行；详细分析见同目录 `NN-*.md`。

## 双口径验收线

| 口径 | 分母（网卡线速） | 50% 线 | 数据面 |
|------|:---:|:---:|------|
| A 不限速（100GbE TCP） | 12500 MiB/s | 6250 | enp139s0f0np0 + enp139s0f1np1 |
| B 千兆限速（eno12409 TBF 1Gbps） | ~118 MiB/s | 59 | eno12409 + tc tbf |

## 一、不限速口径（100GbE TCP，冷态 cache=0）

| 日期 | 配置 | seqread | seqwrite | mseqread | mseqwrite | randread | randwrite | randrw R | randrw W | 备注 |
|------|------|---------|----------|----------|-----------|----------|-----------|----------|----------|------|
| 07-14 | 6 OSD EC 4+2 + cache=0 + default | 1272 | 1346 | 3330 | 3891 | 1474 | 3412 | 17.9† | 47.5† | layout=3841；50%线6250，读类未达 |
| 07-15 | 同上 + ra0 | 178 | 1350 | 1755 | 2799 | 2572 | 2652 | 20.6† | 52.1† | layout=2954；randread +74% |

> † randrw R/W 分列为 fio 队列测量偏差（iodepth128×128job 积压），仅看合计，见 STAGE-SUMMARY §9.3。
> ⚠️ 审计修订 2026-07-17：多 job 项取 fio `Run status` 聚合行（旧 ra0 行 173/1634/3630/2361/3274/3689 来自废弃目录 180604，已替换为 235631 fio 聚合行）。详见 `bw-statistics-audit.md`。

## 二、千兆限速口径（3 服务端 eno12409 TBF 1Gbps，客户端不限速；聚合上限≈354）

| 日期 | 配置 | seqread | seqwrite | mseqread | mseqwrite | randread | randwrite | randrw R | randrw W | 备注 |
|------|------|---------|----------|----------|-----------|----------|-----------|----------|----------|------|
| 07-15 | 同上 + TBF + default | 147⚠ | 114 | 182 | 114 | 90.9 | 117 | 18.8† | 50.4† | layout=114；写撞墙118 |
| 07-15 | 同上 + ra0 | 56.7 | 114 | 95.4 | 100 | 181 | 117 | 21.0† | 54.0† | layout=114；randread翻倍 |

> ⚠ default seqread 单流经预读跨节点并行预取放大（§9.2）。**新集群限速测试到此为止，后续转不限速（§9.4）。**

## 三、之前 1Gbps 环境对照（冷态，MiB/s）

> 来源：`doc/perf-analysis/results-table.md`。千兆单网环境，验收线 59。

| seqread | seqwrite | mseqread | mseqwrite | randread | randwrite | randrw R/W | 验收(59) |
|---------|----------|----------|-----------|----------|-----------|-----------|:---:|
| 77.7✅ | 50.8 | 110✅ | 41.5 | 33.6 | 29.0 | 15.1/14.7 | 2/7 达标 |

## 四、01-5 rados bench EC4+2 vs Rep3 后端裸能力对照（2026-07-18~19）

> 数据源：`results/prod-01-5-rados-ec-vs-rep-mechanism-20260718-233945/`
> 详见：`doc/perf-report/01-5-rados-bench-ec-vs-rep-mechanism-report.md`
> 单变量：pool type（同 6 OSD、同 100GbE 双网、同 DB/WAL tmpfs、同 crush rule osd-level）
> rados bench 256K 对象，runtime 60s，REPEAT=3 取中位数

### 4.1 三模式带宽中位数（MB/s）

| 模式 | -t | EC4+2 | Rep3 | Rep/EC | 备注 |
|------|----|-------|------|--------|------|
| write | 16 | 2929 | 2813 | 0.96× | EC 写略快（写放大 1.5× vs 3.0×）|
| write | 128 | 4574 | 4158 | 0.91× | |
| write | 1024 | 4584 | 4182 | 0.91× | |
| write | 4096 | 4622 | 4076 | 0.88× | |
| seqread | 16 | 3461 | 3724 | 1.08× | |
| seqread | 128 | 4883 | 3890 | 0.80× | |
| seqread | 1024 | 4544 | 4265 | 0.94× | |
| seqread | 4096 | 5552 | 3632 | 0.65× | EC 高并发反超（Rep primary 队列过深）|
| randread | 128 | 3446 | 4468 | 1.30× | |
| randread | 1024 | 4600 | 4242 | 0.92× | EC r1 cold=3191, r2/r3 warm=4600-4664 |
| randread | 4096 | 4580 | 3658 | 0.80× | EC r1 cold=3233, r2/r3 warm=4664 |
| randread | 16384 | 4221 | 4123 | 0.98× | |

> **EC vs Rep 在 RADOS 层基本相当**（0.80-1.30×，无 Rep 显著高于 EC 的稳定模式）。

### 4.2 iostat per-OSD 磁盘峰值（关键证据：磁盘非瓶颈）

| 测试 | EC per-OSD 峰值 | Rep per-OSD 峰值 | 同盘差距 | 含义 |
|------|-----------------|------------------|----------|------|
| rand-t4096 rkB/s | **290 MB/s**（4600 IOPS × 64K） | **1022 MB/s**（256K 块，%util 49.6%） | EC 是 Rep 的 28% | EC IOPS 瓶颈，Rep 磁盘远未饱和 |

### 4.3 cluster NIC 流量（重大发现）

| 测试 | EC cluster NIC RX avg | Rep cluster NIC RX avg |
|------|------------------------|------------------------|
| 全部 cell | **0** | 0 |

> **cluster_network 配置未生效**——EC subop 流量全走 public NIC。

## 五、01-5 FUSE 瓶颈验证（2026-07-19，用户两次反驳后补做）

> 数据源：`results/prod-01-5-.../fuse-verification/`
> 详见：`doc/perf-report/01-5-rados-bench-ec-vs-rep-mechanism-report.md` §五 + `fuse-bottleneck-verification.md`
> 实验 B 单变量对照设计：同后端（juicefs-data-rep pool）、同 MDS、同数据，唯一变量 = mount 方式

### 5.1 实验 A：JuiceFS on Rep3 后端（fio 256K 128j×128 ra0 REPEAT=3）

| 轮次 | BW (MiB/s) | IOPS | slat avg (μs) | clat avg (ms) |
|------|------------|------|---------------|---------------|
| r1 | 2969 | 11900 | 10774 | 1363 |
| r2 | 2965 | 11860 | 10787 | 1365 |
| r3 | 3019 | 12076 | — | — |
| **中位** | **2969** | 11876 | ~10800 | ~1365 |

> JuiceFS+Rep = 2969 MiB/s（vs JuiceFS+EC 2404，**+25%**），仍 ❌ 不达标。

### 5.2 实验 B：ceph-fuse vs kernel CephFS（决定性证据）

| 测试 | r1 | r2 | r3 | 中位 (MiB/s) | vs kernel |
|------|----|----|----|---------------|-----------|
| **kernel CephFS** | 4972 | 5001 | 4933 | **4972** | baseline |
| **ceph-fuse**（C++，无 Go/TiKV） | 2870 | 2884 | 2885 | **2884** | **0.58× = -42%** |
| JuiceFS+Rep（参考） | 2969 | 2965 | 3019 | 2969 | 0.60× = -40% |

### 5.3 Per-op 延迟对比（r2 代表性数据）

| 指标 | kernel CephFS | ceph-fuse | JuiceFS+Rep | ceph-fuse/kernel |
|------|---------------|-----------|-------------|------------------|
| BW (MiB/s) | 5001 | 2884 | 2965 | 0.58× |
| IOPS | 19888 | 11536 | 11876 | 0.58× |
| **slat avg (μs)** | **729** | **11092** | **10787** | **15.2×** |
| clat avg (ms) | 818 | 1403 | 1365 | 1.72× |
| lat avg (ms) | 819 | 1414 | 1376 | 1.73× |
| lat P99.4% | 散布 1-50ms | 99.44% @ 2000ms | 99.45% @ 2000ms | — |

### 5.4 四客户端栈同后端对照矩阵

| 客户端栈 | randread 中位 (MiB/s) | 是否 FUSE | 是否 Go | 是否 TiKV | 达标 6250 |
|----------|------------------------|-----------|---------|-----------|:---:|
| kernel CephFS（本集群）| 4972 | ❌ | ❌ | ❌ | ❌（接近）|
| kernel CephFS+Rep（01-4 集群）| 6718 | ❌ | ❌ | ❌ | **✅** |
| kernel CephFS+EC（01-4）| 4608 | ❌ | ❌ | ❌ | ❌ |
| **ceph-fuse**（C++，无 Go/TiKV）| **2884** | ✅ | ❌ | ❌ | ❌ |
| **JuiceFS+Rep** | **2969** | ✅ | ✅ | ✅ | ❌ |
| JuiceFS+EC（01-2d）| 2404 | ✅ | ✅ | ✅ | ❌ |
| rados bench+Rep（librados）| 4123 | ❌ | ❌ | ❌ | ❌ |
| rados bench+EC4+2（librados）| 4221 | ❌ | ❌ | ❌ | ❌ |
| BeeGFS（不同后端）| 9045 | ❌ | ❌ | n/a | **✅** |

### 5.5 01-5 结论（最终 v3，含直接证据）

1. **EC4+2 vs Rep3 在 RADOS 层基本相当**（0.80-1.30×）。01-4 CephFS 的"Rep +46% vs EC"是 CephFS 客户端层效应，非后端本质差异。
2. **磁盘非瓶颈**（BeeGFS 同硬件 9045，NVMe 单盘 1.5+ GB/s）。EC per-OSD 仅 290 MB/s = 磁盘能力的 19%。
3. **Ceph OSD 软件栈在 EC 是瓶颈**（4 ops × 250μs = 1000μs/op，CephFS+EC 也只 4608），**在 Rep 非瓶颈**（CephFS+Rep 6718 ✅ 达标）。
4. **FUSE 是 JuiceFS 主瓶颈**（直接证据：ceph-fuse 单变量对照 4972 → 2884，损失 42%；slat 暴涨 15×：729μs → 11092μs）。
5. **在 01-5 的 randread 口径中，Go runtime 和 TiKV 不是额外主损失**（ceph-fuse 无 Go/TiKV 但和 JuiceFS 一样慢，2884 vs 2969 差 3%）。该结论不得外推到 randwrite；03-18～03-22 已证明写侧受 per-inode 同步 TiKV 事务和 TiKV 本地写路径约束。
6. **01-4 C1（FUSE）结论正确**，01-5 实验 B 提供**直接证据**确认。
7. **rados bench 不能代表后端真实能力**——librados 用户态客户端比 CephFS 内核客户端低效 63%（rados bench Rep 4123 vs CephFS Rep 6718）。因为 librados 使用用户态 messenger，每次网络收发都需 user↔kernel context switch，而 kernel CephFS 内核模块使用内核态 socket 直连 OSD，无此开销。
8. **达标 6250 路径**：✅ kernel CephFS+Rep（6718）/ ✅ BeeGFS（9045），其余均不达标。

### 5.6 推翻的旧结论

| 旧结论 | 01-5 真相 |
|--------|-----------|
| "EC4+2 限制下后端不能达标，换 Rep3 后端可达标" | ❌ JuiceFS+Rep 2969 仍不达标（FUSE 主导）|
| "6 NVMe OSD 单盘 750 MB/s × 6 = 4500 = 磁盘硬件天花板" | ❌ 磁盘可跑 9+ GB/s（BeeGFS 9045 实测）|
| "Ceph 软件栈 per-IO 延迟是后端瓶颈" | ⚠️ 仅 EC 路径成立，Rep 路径非瓶颈（CephFS Rep 6718 ✅）|
| "01-4 CephFS Rep +46% 证明后端 Rep 强于 EC" | ❌ CephFS 客户端层效应，非后端本质差异 |
| "JuiceFS 瓶颈是 FUSE+Go+TiKV（01-4 间接推断）" | ⚠️ 对 01-5 randread，FUSE 是主瓶颈且 Go/TiKV 非额外主损失；该结论不适用于 randwrite，写侧见 03-18～03-22 |

## 六、03-22 TiKV RAM block 存储隔离 A/B（2026-08-25～26）

> 详细报告：`doc/perf-report/03-22-tikv-ram-block-storage-isolation-ab-20260826.md`。正式 RUN_ID `20260825-163811` 在 R05 触发本地容量硬门，整体分类为 **`EVIDENCE_INVALID`**；下列 R01--R04 数值是可复算的部分工程证据，不是完整 A/B 签收结果。

### 6.1 已完成 arm

| arm | TiKV 本地存储 | 正式窗 median MiB/s | CV | W4/W1 | 6250 达成率 | 证据状态 |
|---|---|---:|---:|---:|---:|---|
| R01/A | 128 GiB RAM loop，共享 KV/WAL/Raft | 3665.43 | 6.49% | 0.959 | 58.65% | arm/GC 完整 |
| R02/B | 96 GiB KV + 32 GiB WAL/Raft RAM loop | 3743.41 | 5.54% | 0.965 | 59.89% | arm/GC 完整 |
| R03/B | 同上 | 3689.86 | 6.12% | 0.926 | 59.04% | arm/GC 完整 |
| R04/A | 同 R01 | 3733.17 | 7.92% | 0.945 | 59.73% | arm/GC 完整 |
| R05/B | 同 R02 | — | — | — | — | logs 文件系统 94%--98%，TiKV `AlmostFull/AlreadyFull`；无 BW log/analysis |
| R06--R08 | 未启动 | — | — | — | — | 按硬门停止 |

### 6.2 部分比较与正式判定

| 比较 | 结果 | 判读 |
|---|---:|---|
| A 点中位数 | 3699.30 MiB/s | 只含 R01/R04 |
| B 点中位数 | 3716.64 MiB/s | 只含 R02/R03 |
| 部分 B/A | **+0.47%** | 配对 +2.13%/−1.16%，方向不一致；缺第二 block，不作正式因果结论 |
| 历史 H→A | +28.45%（相对中心 2880） | fresh TiKV + RAM + 临时集群起点的组合效应 |
| 历史 H→B | +29.05%（相对中心 2880） | 同上，不能拆 fresh 与介质贡献 |
| B 距目标 | 2533.36 MiB/s | 部分点值只达目标 59.47% |
| 正式分类 | **`EVIDENCE_INVALID`** | R05 storage 生命周期/容量合同失败，禁止补样修复同 RUN |

### 6.3 归档与下一步

| 项 | 值 |
|---|---|
| archive | `results/prod-stage03-raw-20260826/opencode-t3.22-20260825-163811.tar.gz` |
| bytes | `124546067` |
| SHA-256 | `1352878807325128fa3a07ac9325b74c89119ea24cbfab9f6e420fbc50096929` |
| teardown | 六组 RAM storage、临时集群、seed/GC 均清理；生产 PD/TiKV 与 JuiceFS 挂载正常，Ceph `HEALTH_OK` |
| 下一因果任务 | 03-22b已执行并按invalid合同收口，详见下一节；后续转03-22c同窗B1c/D1物理路径探针，条件C仍保持独立 |

## 七、03-22b TiKV NVMe-backed A1/B1（2026-08-26～27）

> 详细报告：`doc/perf-report/03-22b-tikv-nvme-backed-storage-attribution-20260827.md`。RUN_ID `20260826-164047`在R03触发预注册CV硬门，整体分类为 **`EVIDENCE_INVALID`**；R01--R03均有完整负载与采集证据，但只有R01/R02生成正式arm分析，不能用一个A1/B1配对签收逻辑隔离效应。

### 7.1 已完成arm

| arm | 臂 | 正式窗 median MiB/s | CV | W4/W1 | 6250达成率 | 判定 |
|---|:---:|---:|---:|---:|---:|---|
| R01 | A1：128 GiB共享loop/ext4 | 3709.03 | 6.83% | 0.971 | 59.34% | PASS |
| R02 | B1：96 GiB KV + 32 GiB logs两个loop/ext4，同一物理NVMe | 3651.45 | 8.52% | 0.947 | 58.42% | PASS |
| R03 | B1，同R02 | 3651.23 | **10.70%** | 0.917 | 58.42% | **FAIL：CV** |
| R04--R08 | — | — | — | — | — | 未运行 |

### 7.2 判定与机制

| 项 | 结果 | 判读 |
|---|---:|---|
| R02/B1相对R01/A1 | −1.55% | 只有一个相邻配对且全RUN无效，仅作描述 |
| R02→R03 median | 3651.45→3651.23 MiB/s | 中心几乎不变，问题不是平均服务率整体下移 |
| R01→R02→R03 CV | 6.83%→8.52%→10.70% | 尾段低谷逐渐加深；正式窗最低秒2986.6→2193.4→1508.6 MiB/s |
| R03 W1→W4 | BW 3811.0→3329.6 MiB/s；pending compaction 0.12→11.29 GiB；NVMe `w_await` 2.60→18.05 ms | 直接触发层为轮内compaction与WAL/Raft同步写共享同一NVMe造成的软排队 |
| RocksDB hard stall | stall及stall reason均为0 | 排除硬写停顿；跨轮残差仍不能唯一拆为compaction相位、NVMe FTL/GC/温度或Ceph/OSD扰动 |
| 目标 | 最好3709.03 MiB/s，距6250差2540.97 MiB/s | A1/B1点值都只达到目标约58%--59% |

### 7.3 闭包、归档与下一步

| 项 | 值 |
|---|---|
| 正式分类 | **`EVIDENCE_INVALID`**；`failed_instance=R03`，reason=`formal-stability-cv-gate-failed` |
| archive | `results/prod-stage03-raw-20260827/opencode-t3.22b-20260826-164047.tar.gz` |
| bytes / SHA-256 | `59001849` / `7cd9e57276a19b2ee17966b369bc3a0fac75da3869582ae226689b8e225ac137` |
| 环境闭包 | A1/B1 backing与临时资源精确销毁；生产PD/TiKV恢复，stores 3/3 Up，Ceph `HEALTH_OK` |
| seed边界 | metadata dump与layout/anchor合同已归档，但formal seed已销毁、Ceph数据对象已回收；后续只能复用合同，不能仅load旧dump |
| 下一任务 | 03-22c同RUN重测B1c，并以D1仅把32 GiB WAL/Raft backing移到RAM；稳定性作为正式端点，不再作为证据删除门。条件C另立 |

## 八、03-22c TiKV RAM logs首次RUN审计（2026-08-27～28）

> 独立审计：`doc/perf-report/03-22c-first-run-invalid-audit-20260828.md`。RUN_ID `20260827-232428`虽然完成8个arm并由执行方标为`EVIDENCE_VALID`，但GPT复核归档后改判 **`EVIDENCE_INVALID`**；不得把本节数值写成正式因果结论。

| 项 | 结果 |
|---|---|
| 工程观察 | 4/4配对D1高于B1c；效应`+2.76% / +0.99% / +6.86% / +1.88%`，中位`+2.32%` |
| 带宽水平 | B1c四臂中位约3652.47 MiB/s；D1四臂中位约3740.04 MiB/s，仍仅达6250目标约59.8% |
| 正式分类 | **`EVIDENCE_INVALID`**：未授权容量/门限变化、事件账本漏记、未入manifest的危险编排器、R01后G08闭包失败重试 |
| 归档 | `results/opencode-t3.22c-20260827-232428.tar.gz` |
| SHA-256 | `1764e1b99804966bafbbedbf415dca30c3f147331c6b725fe021554f0d8cafaf` |
| 环境结局 | 归档显示生产PD/TiKV恢复、stores 3/3 Up、Ceph `HEALTH_OK`、临时资源清除；无需重新操作旧环境 |
| 允许引用 | 仅可写“无效RUN工程观察提示RAM logs收益可能很小”；不得写“03-22c正式证明D1≈B1c” |
| 下一步 | 使用新RUN_ID、新formal seed和冻结的25文件`t66-*`包完整重做R01--R08；旧RUN不得resume、补跑或拼样 |

## 九、03-22c TiKV RAM logs正式重跑（2026-08-28）

> 正式报告：`doc/perf-report/03-22c-tikv-hybrid-ram-logs-attribution-20260828.md`。RUN_ID `20260828-083811`按冻结顺序完成8/8 arm与G01--G08闭环，GPT基于持久归档独立复核为 **`EVIDENCE_VALID`**。B1c/D1唯一差异是32 GiB WAL/Raft backing位于共享NVMe还是RAM；D1不是第二块真实NVMe等价物。

### 9.1 正式arm与配对

| arm | 臂 | median MiB/s | CV | W4/W1 | 6250达成率 | 部署稳定 |
|---|:---:|---:|---:|---:|---:|:---:|
| R01 | B1c | 3599.85 | 9.42% | 0.922 | 57.60% | ✅ |
| R02 | D1 | 3816.67 | 6.52% | 0.994 | 61.07% | ✅ |
| R03 | D1 | 3749.91 | 7.28% | 0.990 | 60.00% | ✅ |
| R04 | B1c | 3661.94 | 8.60% | 0.926 | 58.59% | ✅ |
| R05 | D1 | 3763.12 | 7.55% | 0.946 | 60.21% | ✅ |
| R06 | B1c | 3615.40 | 9.38% | 0.878 | 57.85% | ❌ |
| R07 | B1c | 3490.29 | 12.19% | 0.810 | 55.84% | ❌ |
| R08 | D1 | 3739.36 | 6.30% | 0.959 | 59.83% | ✅ |

| 正式端点 | 结果 | 判定 |
|---|---:|---|
| B1c四臂中位 | 3607.63 MiB/s | — |
| D1四臂中位 | 3756.51 MiB/s | 目标60.10%，差2493.49 MiB/s |
| 四配对D1/B1c | +6.02% / +2.40% / +4.09% / +7.14%；中位 **+5.05%** | 4/4正向但<15%，带宽材料门 **FAIL** |
| CV改善 | 4/4；中位+2.36 pp | 稳定性门 **PASS** |
| W4/W1改善 | 4/4；中位+0.0694 | 稳定性门 **PASS** |
| D1部署稳定 | 4/4 CV≤10%且W4/W1≥0.90 | **PASS** |

### 9.2 机制与闭环

| 项 | 正式结论 |
|---|---|
| B1c尾段 | pending约0.13--0.27→11.1--12.7 GiB，Raft sync约0.22--0.23→0.74--0.80 ms，NVMe `w_await`约1.7--2.0→16.4--17.7 ms；与带宽尾段下滑同向 |
| D1尾段 | Raft sync稳定在约0.074--0.083 ms，故CV/W4/W1改善；但KV pending仍升到11.3--15.7 GiB，物理NVMe await也未消失，说明logs是波动放大因素而非平均服务率主墙 |
| 内存/容量 | D1父tmpfs 89% used、4 GiB available；内层logs最大46% used、最少约17.3 GiB available；MemAvailable最低约741 GiB、无swap/OOM/abort |
| GC/seed | G01--G08均回到valid=524288、leaked=0；G08 UUID一致，post-final pool三点均精确回到pre-format 2434664 |
| 生产闭环 | 三节点生产PD/TiKV active，stores 3/3 Up，Ceph `HEALTH_OK`，无t66临时资源残留 |
| archive | `results/opencode-t3.22c-20260828-083811.tar.gz`，SHA-256=`3b5559c0ed905ba110ace02b1286a477db5b143678bad99daffa80f0e5978ba7` |
| 后续 | 不再扫inode/worker/`max-uploads`或重复A1/B1/D1；条件C仅作native ext4/fresh状态可选归因，真实第二NVMe仅在有硬件和部署决策时测试 |

## 十、04-4 同步元数据事务架构纸面审计（2026-08-30）

> 报告：`doc/perf-report/04-4-metadata-transaction-options-20260830.md`；证据包：
> `results/prod-stage04-analysis-20260830/m1-20260830-gpt-source-audit/`。本项为源码与历史证据分析，
> 未连接集群、未编译、未跑性能，模型数值不是实测。

| 项 | 结果 |
|---|---|
| VERDICT | **`M1_SINGLE_OPTION_ONLY`**；优先级仍为 `PRIORITY_PENDING_A2` |
| 源码真值 | V13 `e0032b2a + loadRange + B-catchup` 与交付 binary MD5/SHA/BuildID/Go version完整闭合；V14官方`0b90c7d + B-catchup`语义闭合，但原构建命令/Go version/binary SHA/BuildID未保留 |
| 当前路径 | 每个chunk可并发上传且各有commit thread，但每个completed slice仍单独进入`baseMeta.Write`，被同inode openFile lock、txBatchLock、共同inode attr key与同步TiKV Commit串行化 |
| 唯一候选 | 同 inode、跨 chunk 的 completed-slice metadata batch；首版仅TiKV、`ChangeLog=false`、non-growing overwrite；默认off、无新schema、不确定状态singleton fallback |
| 统一模型 | singleton参考ceiling约`3278.69 MiB/s`；假设`b/k=1.74/2.22/3.00`时未计数据面cap的模型约`5702/7286/9836 MiB/s`；评级`T2_CONDITIONAL`，必须实测ready-depth、transaction cost和1PC，⛔不得写成性能承诺 |
| 其余方向 | O2不删除slice mapping transaction；O3只拆本地锁会转成共同inode key冲突/retry；O4需metadata schema/mixed-client迁移，均不进入首原型 |
| 下一步 | 已写`04-5-metadata-transaction-batching-prototype.md`，当前无执行权限；先做被动shadow插桩，平均batch<2、`b/k<1.25`或base收益<25%即提前停止，过门后才做新volume正确性/故障注入/性能验证 |

## 十一、U141d patched v1.4.1替代最终判定（2026-08-31）

> 最终报告：`doc/perf-report/u141d-juicefs-v141-replace-v131-final-20260831.md`。候选只指
> exact patched v1.4.1 + B-catchup（MD5 `24fae0852051c80ca571cb2f20275d46`）；stock v1.4.1
> 因randwrite `551/552/551 MiB/s`继续排除。

| 正式端点 | V13 MiB/s | V14 MiB/s | V14效应 | 双侧95% CI | 单侧95%下界 | 结论 |
|---|---:|---:|---:|---:|---:|---|
| randrw.read | 1758.47 | 1749.30 | −0.52% | [−5.52%, +4.48%] | −4.36% | 排除>5%退化 |
| randrw.write | 1758.18 | 1749.21 | −0.51% | [−5.49%, +4.47%] | −4.33% | 排除>5%退化 |
| randwrite.write | 2492.89 | 2441.08 | −2.08% | [−5.10%, +0.94%] | −4.40% | 排除>5%退化 |
| mseqwrite.write | 4791.30 | 4933.11 | +2.96% | [−3.47%, +9.38%] | −1.97% | 排除>5%退化；不得宣称确认提升 |

| 项 | 最终结果 |
|---|---|
| VERDICT | **`REPLACE_APPROVED`**；04后续默认使用exact patched V14 |
| U141b保留项 | seqread/seqwrite已非劣；mseqread/randread两种估计量均接近0，无材料性退化方向 |
| P0兼容 | `V14→V13→V14`通过；V14 Setting仅多空默认`Tiers`，回滚可行但不是字节级identical |
| 有效性 | Phase A closure 3650/3650、Phase B closure 563/563 SHA通过；GPT从per-job原始日志独立重算复现 |
| 环境闭包 | 两个独立scrub lease均恢复；最终Ceph HEALTH_OK、6/6 OSD up/in、33 PG active+clean，无mount/worker/fio残留 |
| 持久证据 | `results/prod-u141d-final-20260831/`；A归档SHA `150f988c...`，B归档SHA `b9a1e7e7...` |
| 制品边界 | 现有同MD5二进制获批；重新构建须先闭合source/patch/toolchain/BuildID/SHA256与P0 smoke |

## 十二、04-tmp randrw `max-readahead=0` 严格A/B（2026-09-01）

> 正式报告：`doc/perf-report/04-tmp-randrw-readahead-residual-tuning-20260901.md`；
> RUN_ID `20260831-231629`，12/12 cell完成，GPT从128-job原始bw log独立复算。

| 方向 | DEFAULT均值 MiB/s | RA0均值 MiB/s | 冻结模型效应 | 双侧95% CI | 判定 |
|---|---:|---:|---:|---:|---|
| randrw.read | 1657.53 | 1684.46 | `+1.62%` | `[+0.04%, +3.21%]` | CI上界低于`+5%`材料收益 |
| randrw.write | 1658.09 | 1685.36 | `+1.64%` | `[+0.01%, +3.28%]` | CI上界低于`+5%`材料收益 |

| 项 | 结果 |
|---|---|
| 冻结VERDICT | `RW_RA_INCONCLUSIVE`；状态机未单列“统计正向但低于材料阈值” |
| 工程决策 | **保持默认readahead，不交付`--max-readahead 0`，关闭当前栈randrw该方向** |
| 历史差异 | 03-6的`max-fuse-io 128K→256K`已使GET/IO约`1.62→1.15`、RX放大约`2.30×→1.22×`，与ra0消冗余作用重叠 |
| 有效性 | 8/8正式轮、fio/sampler/资产/对象回归/mount身份/scrub恢复全部通过；manifest `7839/7839 OK` |
| 结论边界 | 只适用于当前exact patched V14、256K FUSE、msgr=8下的randrw；不得外推randread |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp/20260831-231629-autonomous/`；原始zstd SHA256=`5e5953e5...` |
| 生命周期 | `CLOSED`；本地/远端去重共释放`188,713,518`字节，157精确源证据已清除，Ceph保持`HEALTH_OK`、6/6 OSD up/in |

## 十三、04-1b randread同Pool显式Primary均衡工程筛选（2026-09-02）

> 正式报告：`doc/perf-report/04-1b-randread-explicit-primary-steering-ab-20260902.md`；
> RUN_ID `20260901-194644`。本节是隔离测试Pool的N/S工程筛选，不替换本表七项交付基线。

| 条件 | primary直方图 | I_primary | 轮次 MiB/s | 均值 MiB/s |
|---|---|---:|---:|---:|
| N：自然primary | `{0:10,1:15,2:11,3:11,4:8,5:9}` | `1.40625` | `3467 / 3438` | `3452.5` |
| S：均衡primary | `{0:10,1:11,2:11,3:10,4:11,5:11}` | `1.03125` | `3920 / 3929` | `3924.5` |

| 项 | 结果 |
|---|---|
| 描述性效应 | **S-N=`+472 MiB/s（+13.67%）`**；N/S pair spread=`0.84%/0.23%` |
| 6250目标 | **FAIL**；S仅达`62.79%`，仍差`2325.5 MiB/s` |
| VERDICT | `R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET` |
| 有效性边界 | 四轮各128条bw log且rc=0；但W01与W02--W04间mount实例变化，Attempt 4同mount仅`S/S/N`；无实际`op_r`采样，故不报95% CI、不签机制点估计 |
| 历史基线关系 | 03阶段`5544 MiB/s`来自不同Pool/layout/窗口，不直接相减，七项基线保持不变 |
| 生产意义 | **明确的候选策略，不是可直接上线配置**：新Pool可在空池阶段按实际map做primary均衡canary；测试pool_id=6的5条映射不可移植，已有EC Pool在线重排可能触发恢复 |
| 证据 | `/mnt/c/SunRise/test/04-1b/20260901-194644/final-evidence/`，manifest `558/558 OK` |
| 生命周期 | `CLOSED`；测试mount/volume/Pool/upmap/CephX/远端RUN根已清理，balancer与删除保护恢复，Ceph `HEALTH_OK`，参考Pool和157业务正常 |

## 十四、04-tmp2 本地读缓存最小 canary（2026-09-02）

> 正式报告：`doc/perf-report/04-tmp2-juicefs-local-read-cache-stability-canary-20260902.md`；
> RUN_ID `20260902-133433`。本节是热集机制筛选，不替换无缓存七项交付基线。

| 条件 | 轮次 MiB/s | 均值 MiB/s | 说明 |
|---|---:|---:|---|
| A：`cache-size=0` | `3849.58 / 3577.53` | `3713.56` | 后端RX约为fio读量的107% |
| B：64 GiB cache、32 GiB热窗口 | `35881.70 / 37098.34` | `36490.02` | 描述性`+882.62%`；B轮CV `2.13%/1.69%` |
| POST-A | `3841.24` | — | 相对A均值偏差`3.44%`，恢复门PASS |

| 项 | 结果 |
|---|---|
| 正式VERDICT | `CACHE_SCREEN_EVIDENCE_INVALID` |
| 归因边界 | R02正式窗仍新增`19.51 GiB`缓存；B物理NVMe读取接近零，热点主要由Linux页缓存承载，三源命中合同未闭合 |
| 工程观察 | 本地缓存可显著减少小热集的Ceph读取；该数值不是NVMe裸盘吞吐，也不是生产容量/稳定收益 |
| 决策 | 不修改无缓存交付配置；不补跑、不升级192 GiB L2；缓存保留为未来有额外盘且热点明确时的独立canary候选 |
| 证据 | `/mnt/c/SunRise/test/04-tmp2/20260902-133433/`；矩阵873文件远端/本地SHA256完全一致 |
| 生命周期 | `CLOSED`；缓存目录已精确删除，scrub恢复，POST-A通过，无fio/任务挂载残留，Ceph `HEALTH_OK` |

## 十五、04-2 fresh原生ext4与nested-loop归因（2026-09-02）

> 正式报告：`doc/perf-report/04-2-hcl-native-vs-nested-attribution-20260902.md`；
> RUN_ID `20260902-160000`。本项为归因专项，不替换七项交付基线。

| 端点 | 结果 | 判定 |
|---|---:|---|
| C调整均值 | 4121.22 MiB/s | fresh原生NVMe/ext4 |
| L调整均值 | 3933.97 MiB/s | 同盘backing + loop/ext4 |
| L相对C | `-4.54%`，95% CI `[-12.45%,+3.37%]` | CI跨0 |
| 同臂噪声 / 分辨阈值 | `epsilon=8.45%` / `M=16.90%` | `epsilon>=5%`且CI半宽`7.91pp>5pp` |
| 主VERDICT | `A1_CL_RESOLUTION_INSUFFICIENT` | 不证明nested-loop等价或有稳定损失 |
| H0 / H1 | 4072.58 / 1417.99 MiB/s；`D_H=96.70%` | `HISTORICAL_ANCHOR_RESOLUTION_INSUFFICIENT`；H↔C不可归因 |
| 环境闭环 | 生产TiKV三节点恢复，stores 3/3 Up，`/mnt/juicefs`重挂后31点/30分钟观察PASS；临时资源清零，四个scrub lease restored | `PRODUCTION_RESTORE=SIGNED` |
| 持久证据 | `/mnt/c/SunRise/test/04-2/20260902-160000/archive/opencode-04-2-20260902-160000.tar.gz`；SHA256=`24ee6606b0390fa1837109b18e3e10b452f52019d5fb7f60cb64b786443d6fd2` | archive校验PASS |

## 十六、04-tmp2b 读写缓存共享容量筛选（2026-09-03）

> 正式报告：`doc/perf-report/04-tmp2b-juicefs-read-write-cache-capacity-curve-20260903.md`；
> RUN_ID `20260903-000000`。本项是L1缓存专项，不替换无缓存七项交付基线。

| 测试项 | C16 MiB/s | C32 MiB/s | C64 MiB/s | 判读 |
|---|---:|---:|---:|---|
| mseqread | 3103.56 | 3293.15 | 3437.02 | 六点之一；轮内稳态，容量间仅描述 |
| randread | 3892.38 | 2645.14 | 3814.71 | 非单调，不能归因于容量 |
| randwrite | 1291.64* | 未运行 | 未运行 | *C16仅前台观察；staging排空硬失败 |
| randrw | 未运行 | 未运行 | 未运行 | 按硬门停止 |

| 项 | 结果 |
|---|---|
| 正式VERDICT | `CACHE_CAPACITY_CURVE_INVALID / WRITEBACK_STAGING_DRAIN_FAILURE` |
| 写侧证据 | fio rc/error为0，但写后固定残留112 blocks、112 files、29,363,712 B并持续出现staging `ENOENT`；不得计算有效持久化带宽 |
| 读侧边界 | 六点为有效L1稳态观察；实际缓存FS峰值仅约4.06/8.13/16.25 GiB，且采样器误选TiKV网卡而非Ceph数据网，不能签容量或后端卸载因果 |
| 工程决策 | `NO_DELIVERABLE_COMBINED_CACHE_TIER`；不补齐剩余写点、不修改无缓存交付配置、不进入生产canary |
| 安全恢复 | 同cache-dir恢复挂载通过`scanStaging()`把112/29,363,712 B清零；随后精确清除测试mount、ext4、loop、backing与RUN目录 |
| 环境闭环 | scrub flags恢复；Ceph `HEALTH_OK`、6/6 OSD up/in、97 PG active+clean；`/mnt/juicefs`正常 |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2b/20260903-000000/`；1341文件manifest通过；final archive SHA256=`b39b2853acdb47a1847a3d12baaff69c562ac7183faf3704ce1d26421672baf6` |

## 十七、04-tmp2c randread本地缓存驻留曲线订正（2026-09-03）

> 正式报告：`doc/perf-report/04-tmp2c-randread-cache-residency-curve-20260903.md`；
> RUN_ID `20260903-141500`。本项只订正读缓存机制，不替换无缓存七项交付基线，也不测试writeback。

| Cell | 缓存/16 GiB热集 | 带宽 MiB/s | 命中率 | Ceph RX/逻辑读 | 判读 |
|---|---:|---:|---:|---:|---|
| A0-pre / post | 0% | 3490.80 / 3817.51 | 0% | 101.8% | 前后漂移9.36% |
| C02 | 12.5% | 3659.58 | 5.60% | 96.1% | 相对A0均值+0.15%，在漂移内 |
| C04 | 25% | 4067.58 | 15.49% | 86.1% | 描述性+11.31% |
| C08 | 50% | 4900.65 | 40.98% | 60.1% | 描述性+34.11%，CV/W4门失败 |
| C16 | 100% | 35384.36 | 95.83% | 4.25% | 近全驻留平台；正式窗有drops |
| C32 | 200% | 35317.74 | ~100% | ~0% | 与C16同平台，无drops/evicts |

| 项 | 结果 |
|---|---|
| 订正原因 | 04-tmp2b使用`-T largefile`导致inode不足，名义16/32/64 GiB实际仅约4/8/16 GiB |
| 正式VERDICT | `CACHE_RESIDENCY_CURVE_INVALID_BY_PREREGISTERED_DROP_GATE` |
| 工程结论 | **热集近全驻留时读缓存收益确认**；约35.3k MiB/s（34.5 GiB/s）是本地RAM辅助热集上限，不是NVMe裸盘带宽 |
| 生产边界 | 只作为“有效容量覆盖热集并留余量”的独立canary方向；本项不交付固定容量，也不提供writeback证据；writeback生产判断见§十九 |
| 有效性 | phase-II manifest `1786/1786 OK`；GPT/Luna独立复算一致；小容量点受9.36%基线漂移和大量drops限制 |
| 生命周期 | `CLOSED`；RUN缓存目录精确删除，无测试挂载/进程；`/mnt/juicefs`正常，Ceph `HEALTH_OK`、97 PG |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2c/20260903-141500/` |

## 十八、04-tmp2d 交付配置读缓存容量曲线（2026-09-03）

> 正式报告：`doc/perf-report/04-tmp2d-production-aligned-read-cache-curve-20260903.md`；
> RUN_ID `20260903-131428`。本项使用patched v1.4.1、私有`ms_async_op_threads=8`和默认预读，
> 只评估读缓存，不替换无缓存七项交付基线。

| 项目 | A0均值 MiB/s | C25 | C50 | C75 | C100 | C200 |
|---|---:|---:|---:|---:|---:|---:|
| mseqread带宽 MiB/s | 4620.88 | 5357.61 | 7436.75 | 12633.37 | 29636.67 | 35664.08 |
| 相对A0 | — | +15.94% | +60.94% | +173.40% | +541.36% | +671.80% |
| 命中率 | 0% | 14.37% | 40.32% | 67.30% | 94.40% | 100.00% |
| randread带宽 MiB/s | 4434.60 | 5257.07 | 7712.65 | 14764.59 | 36220.89 | 37411.45 |
| 相对A0 | — | +18.55% | +73.92% | +232.94% | +716.78% | +743.63% |
| 命中率 | 0% | 16.27% | 41.72% | 69.76% | 95.35% | 100.00% |

| 项 | 结果 |
|---|---|
| VERDICT | `READ_CACHE_CURVE_COMPLETE`，14/14最终cell有效 |
| 稳定性 | mseqread/randread A0-pre→post漂移`+0.87%/+0.16%`；所有正式点W4/W1在`0.970--1.058` |
| 容量结论 | 75%档补出明显拐点；名义100%仍因块/条目开销只有94%--95%命中，200%档确认全驻留平台，但不代表生产必须配置2倍 |
| 生产意义 | 有独立本地NVMe且热集明确时，读缓存值得独立canary；容量按热集+缓存开销+20%文件系统空闲保护规划 |
| 边界 | 每档重新挂载，小于约30%的点值仍可能受挂载档位影响；35--37 GiB/s是本地页缓存/NVMe热集路径，不是Ceph裸盘带宽；不含writeback |
| 生命周期 | RUN缓存根已精确删除；无测试挂载/进程，`/mnt/juicefs`正常，Ceph `HEALTH_OK`且97/97 PG active+clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2d/20260903-131428/`；派生JSON SHA256=`0c562450e50fb2cff5236bf8678080ab8c2a39bcb9aebaa21aea628b80b3ecb8` |

## 十九、04-tmp2e writeback容量安全canary（2026-09-03）

> 正式报告：`doc/perf-report/04-tmp2e-writeback-capacity-curve-20260903.md`；
> RUN_ID `20260903-181523`。本项验证writeback前台带宽与持久化排空，不替换无缓存基线。

| 指标 | 16 GiB W16结果 | 判读 |
|---|---:|---|
| ext4实际Available | 15.53 GiB | 正确的修正容量点 |
| staging峰值 | 15.22 GiB（约97.96% Available） | 容量被打到临界区 |
| foreground mean / CV | 2436.50 MiB/s / 37.54% | 仅前台突发观察 |
| W1 / W4 | 2623.44 / 1624.37 MiB/s | 后段回落到后端服务平台 |
| fio写入 | 432.22 GiB；128 jobs均无错误 | fio本身通过 |
| 900秒排空终值 | 2 blocks / 524288 B / 2 files | 生命周期硬失败 |
| effective durable BW | 不计算 | staging未按合同排空 |

| 项 | 结果 |
|---|---|
| VERDICT | `W16_WRITEBACK_DRAIN_FAILURE / CAPACITY_CURVE_STOPPED_AT_FIRST_CELL` |
| 与旧20 GiB canary关系 | 旧RUN实际Available 19.50 GiB、前台2491.63 MiB/s、70秒排空；只算生命周期canary，不是W16容量点。两次W4均约1624 MiB/s，增加容量未改变后端平台 |
| 实现机制归因 | 与日志吻合的参考实现显示：`free-space-ratio=.20`的stageFull阈值使用一半（约10% free）；按秒检查可被高并发越过，hardlink在ENOSPC后直传回退，但已写staging文件可残留。原构建命令/工具链未闭合，故不是exact binary逐位源码证明 |
| 工程决策 | W16不得作为生产容量档，W32/W64/W96/W128及randrw按早停取消；但前段突发吸收信号和20 GiB canary排空支持在客户端空间充足、独占文件、低占空比且受监控时条件性启用writeback。恢复成功只证明本次可恢复，不追认W16排空通过 |
| 突发收益参照 | 前90秒约`2770.80 MiB/s`，相对当前无缓存代表值`2441.1 MiB/s`约`+13.5%`；该比较不是同窗严格A/B。全180秒均值仅`2436.50 MiB/s`，证明收益只属于缓存未饱和的业务活跃窗 |
| 安全恢复 | 同cache-dir恢复挂载后staging清零，三文件direct抽读和128×1 GiB资产检查通过；loop20/backing精确清理 |
| 环境闭环 | 对象`3553464→1979160`（seed `1979158`）；OSD/TiKV归零；`/mnt/juicefs`正常，Ceph `HEALTH_OK`、97/97 PG active+clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2e/20260903-181523/`；failure-closure 63项SHA256全量通过 |

## 二十、04-6 多流容量曲线与阶段收尾（2026-09-04）

> 正式报告：`doc/perf-report/04-6-stage04-final-capacity-and-tuning-exit-decision-20260903.md`；
> RUN_ID `20260903-214003`。本项只判断并发扩展形态和是否存在新可交付旋钮，不替换七项交付基线。

| 测试项 | 低并发① MiB/s | 高并发 MiB/s | 低并发② MiB/s | 扩展/漂移 | 严格判定 |
|---|---:|---:|---:|---:|---|
| mseqread `8→16→8` | 4384.27 | 4686.99 | 4392.77 | 高并发`+6.8%`；回环漂移`0.19%` | `PARTIAL_SCALING` |
| mseqwrite `8→16→8` | 4064.31 | 3853.67 | 4090.14 | 高并发约`-5.5%`；P50约`4.2×`；漂移`0.64%` | `SERVICE_PLATEAU_IDENTIFIED` |
| randrw.read `64→128→64` | 1554.71 | 1756.77 | 1426.69 | 回环漂移`8.23%` | `INCONCLUSIVE_DRIFT` |
| randrw.write `64→128→64` | 1556.35 | 1757.03 | 1428.34 | 回环漂移`8.22%` | `INCONCLUSIVE_DRIFT` |

| 项 | 结果 |
|---|---|
| 执行与恢复 | 9/9 cell、对象恢复、scrub恢复和最终环境门全部通过；Ceph `HEALTH_OK`、97/97 PG active+clean |
| mseqwrite机制闭环 | frozen raw离线复算：W02六块OSD数据盘正式窗P50均`100%`，OSD完成率相对两侧低档均值`0.94565×`；未重跑性能或改阈值 |
| randrw漂移归因 | M02后TiKV/RocksDB compaction debt及NVMe队列状态未随Ceph对象数回到O0；这是强相关证据，不是独立因果闭环 |
| 新生产旋钮 | `NONE_FOUND`；不追加盲目参数轮次 |
| 阶段裁决 | `STAGE04_CONTINUE_DIAGNOSIS`：mseqwrite平台已闭合，但mseqread仍`PARTIAL_SCALING`、randrw仍`INCONCLUSIVE_DRIFT`，不能扩大为全部项目数学架构上限 |
| 证据 | `/mnt/c/SunRise/test/04-6/20260903-214003/`；原始归档SHA256=`742ae150c6206345e48fc14a796de94b96f5fcfc148d8bbd0c14f60393e0e9be`；离线生成器/W02机制/R02机制/post分析SHA256分别为`dda73ee1.../562bca42.../20437034.../411f8705...` |

## 二十一、04-tmp3 竞品大块单流 L1 筛选（2026-09-04）

> 正式报告：`doc/perf-report/04-tmp3-competitor-large-block-sequential-benchmark-20260904.md`；
> RUN_ID `20260904-095827`。本项是16/20 MiB与cp的独立对标口径，不替换七项256 KiB交付基线。

| fio方向 | A均值 MiB/s | 候选均值 MiB/s | 相对A | 竞品目标达成率 | L1裁决 |
|---|---:|---:|---:|---:|---|
| 20 MiB读 | `1581.68` | R=`2614.08` | `+65.27%` | `50.76%` | `SCREEN_CONTINUE_R_ONLY`；强信号，但非正式效应 |
| 16 MiB写 | `2365.31` | F=`2616.09` | `+10.60%` | `85.72%` | `F_CONFIRMATION_ELIGIBLE_L1`；同位置配对增益`+10.29%/+10.89%` |

| 项 | 结果 |
|---|---|
| 参数拆分 | F（仅`max-fuse-io=1M`）读为`−7.35%`；W（F + `buffer-size=1024`）相对F为`−1.16%`且配对方向相反，故buffer增量`SCREEN_STOP` |
| cp辅助点 | 读A/R=`0.996/0.992 GB/s`，未观察到R收益；写A/W=`0.867/0.986 GB/s`，仅单点工程观察 |
| 对标结果 | 竞品披露的4/4目标均未达；其环境未披露，不作严格同条件产品优劣声明 |
| 生产决策 | 本L1不改生产配置；只在业务真实使用20 MiB direct读或16 MiB写时，另立最小A/R或A/F L2并补七项回归 |
| 有效性与恢复 | 12/12 cell、对象回环、两个scrub lease恢复、最终O0及`HEALTH_OK`/97 PG/6 OSD全部通过 |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3/20260904-095827/`；tar SHA256=`da7cce079b9fa83c66e1c517a33b9d7c5202a610db661aa0f638d75da5ce141c`；manifest `626/626 PASS`；GPT独立复算12/12通过 |

## 二十二、04-tmp3b 大块顺序 I/O 路径对齐（2026-09-04）

> 正式报告：`doc/perf-report/04-tmp3b-competitor-large-block-io-path-alignment-20260904.md`；
> RUN_ID `20260904-132417`。本项为L1路径筛选，不替换七项256 KiB交付基线。

| 分支 | 对照 | 有效结果 | 裁决 |
|---|---|---|---|
| readahead | RA8/16/32镜像 | RA32相对RA8两配对`+9.74%/+13.80%` | 第一对未达10%，保持RA8 |
| async读 | off/on ABBA | 两配对均约`0%`，且on增加RSS/线程与对象读放大 | 保持off |
| BlockSize读 | fresh B256/B4 ABBA | B4相对B256`-34.13%/-33.47%`；GET/GiB降16倍但单GET时延约升4.8倍 | `BLOCK4_READ_SCREEN_NO_SIGNAL`，保持256 KiB |
| BlockSize写 | B256首格 | fio/close-complete=`3163.45/3150.57 MiB/s`；重挂后精确路径不可见、UsedSpace仍约10 GiB | `EVIDENCE_INVALID_PERSISTENCE_GATE`；停止其余写格，数值不签收 |

| 项 | 结果 |
|---|---|
| 竞品目标 | 20 MiB读未达到`5149.84 MiB/s`；写侧无可接受目标值 |
| 生产决策 | 不修改RA、async或format BlockSize；不把本专项值覆盖七项基线 |
| 环境闭环 | 两临时卷按精确UUID销毁；pool回到创建前1 object/64 KiB范围；当前卷UUID、挂载和32 GiB资产指纹不变；Ceph `HEALTH_OK` |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3b/20260904-132417/`；Step2 manifest 403/403通过，SHA256=`a92c04732375bec588a751d480c91a9b6ae094bcd065456b330fa3b80a37ec2f` |
