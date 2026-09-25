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
| BlockSize读 | fresh B256/B4 ABBA | B4相对B256`-34.13%/-33.47%`；GET/GiB降16倍但在途量约`11.5→2.3` | 当时仅能签`B4+RA8`较慢；04-tmp3c已证明主要是RA并发混杂 |
| BlockSize写 | B256首格 | fio/close-complete=`3163.45/3150.57 MiB/s`；重挂后精确路径不可见、UsedSpace仍约10 GiB | `EVIDENCE_INVALID_PERSISTENCE_GATE`；停止其余写格，数值不签收 |

| 项 | 结果 |
|---|---|
| 竞品目标 | 20 MiB读未达到`5149.84 MiB/s`；写侧无可接受目标值 |
| 生产决策 | 本RUN不修改RA、async或format BlockSize；后续04-tmp3c已将B4/RA32登记为L2候选，仍不覆盖七项基线 |
| 环境闭环 | 两临时卷按精确UUID销毁；pool回到创建前1 object/64 KiB范围；当前卷UUID、挂载和32 GiB资产指纹不变；Ceph `HEALTH_OK` |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3b/20260904-132417/`；Step2 manifest 403/403通过，SHA256=`a92c04732375bec588a751d480c91a9b6ae094bcd065456b330fa3b80a37ec2f` |

## 二十三、04-tmp3c BlockSize×readahead 对象并发解耦（2026-09-04）

> 正式报告：`doc/perf-report/04-tmp3c-blocksize-readahead-concurrency-decoupling-20260904.md`；
> 正式 RUN_ID `20260904-165911`。本项为 L1 因果筛查，不替换七项 256 KiB 交付基线。

| 对照 | 结果 | 机制 | 裁决 |
|---|---:|---|---|
| B4/RA32 对相邻 B4/RA8（C03/C02） | `+73.60%` | 在途 GET `2.34→4.54` | 超过预注册 10% 门 |
| B4/RA32 对相邻 B4/RA8（C04/C05） | `+77.55%` | 在途 GET `2.33→4.59` | 超过预注册 10% 门 |
| B256/RA8 双锚（C06/C01） | `-1.56%` | GET 时延、在途量基本一致 | 环境漂移不足以解释效应 |
| B4/RA32 对 B256/RA8 平均 | `+12.50%` | 大对象+匹配窗口恢复对象并发 | 登记 L2 候选 |

| 项 | 结果 |
|---|---|
| VERDICT | `READAHEAD_OBJECT_CONCURRENCY_CAUSAL_SIGNAL` |
| 归因订正 | 04-tmp3b 的 B4/RA8 下降主要来自 RA8 只容纳约 2 个 4 MiB GET，不能归因于大 BlockSize 本身 |
| 竞品目标 | 最佳 `2921.87 MiB/s`，为 `5149.84 MiB/s` 的 `56.74%`，仍未达标 |
| 生产决策 | B4/RA32 仅为 L2 候选；完成对象层屋顶、随机/写和七项回归前，不修改 256 KiB 交付配置 |
| 有效性 | 6/6 fio、秒级采样、12 个健康门、EROFS 与当前卷指纹均通过；GPT/Luna 独立复算一致 |
| 环境闭环 | 两临时卷按 META+UUID 精确销毁；无挂载/进程残留；当前卷正常，Ceph `HEALTH_OK` |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3c/20260904-165911/`；322 项 manifest 全通过，SHA256=`01f4bc30c6ce7d56cead77ff8d97dabede4f49d471687a52fce071ed06ddc93e` |

## 二十四、04-tmp3d Ceph对象大小×并发服务曲线（2026-09-04）

> 正式报告：`doc/perf-report/04-tmp3d-ceph-object-size-concurrency-service-curve-20260904.md`；
> RUN_ID `20260904-173955`。本项绕过JuiceFS/TiKV/FUSE，只回答Ceph对象层余量，不替换七项基线。

| 对象大小 | QD1 | QD2 | QD4 | QD8 | QD16 | QD32 | QD1回环 | 单位 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| 256 KiB | 307.70 | 647.93 | 1327.10 | 2484.85 | 3834.28 | 4623.60 | 384.58 | MiB/s，末15秒均值 |
| 4 MiB | 828.53 | 1787.73 | 3373.60 | **5403.20** | **6659.20** | 6434.40 | 973.60 | MiB/s，末15秒均值 |

| 项 | 结果 |
|---|---|
| VERDICT | `OBJECT_BACKEND_HEADROOM_CONFIRMED` |
| 目标 | 4 MiB/QD8越过竞品`5149.84 MiB/s`；QD16越过项目`6250 MiB/s` |
| 与JuiceFS差额 | 4 MiB QD8/QD16比04-tmp3c最佳`2921.87 MiB/s`高`84.92%/127.91%` |
| 机制 | 对象后端可达目标；当前大块顺序读剩余约束在JuiceFS Reader/FUSE/请求生成与并发维持路径，触发04-tmp3e |
| 边界 | QD1回环上升`24.99%/17.51%`，低QD曲线含固定对象集热化；不影响对象层越线的可达性结论 |
| 环境闭环 | 唯一namespace精确删除`131072+8192`个数据对象及两run marker并归零；Ceph `HEALTH_OK`、97 PG active+clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3d/20260904-173955/`；最终manifest 460项全通过，SHA256=`fa81207dfc3648a6aa071e3bb27c96c48ab05d353218c80f0cf5a330b2cd7b45` |

## 二十五、04-tmp3e JuiceFS Reader/FUSE请求生成边界（2026-09-04）

> 正式报告：`doc/perf-report/04-tmp3e-juicefs-reader-fuse-request-generation-boundary-20260904.md`；
> RUN_ID `20260904-184259`。本项为B4/20 MiB读路径L1诊断，不替换七项256 KiB交付基线。

| Cell | 入口/参数 | mean MiB/s | CV | GET在途量 | 裁决 |
|---|---|---:|---:|---:|---|
| A02 | libaio QD1 / B4 RA32 | 1975.30 | 4.01% | 4.32 | 异步曲线起点 |
| A03 | libaio QD2 / B4 RA32 | 3021.45 | 3.24% | 8.50 | 同向扩展 |
| A04 | libaio QD4 / B4 RA32 | 4432.65 | 2.87% | 14.53 | 同向扩展 |
| A05 | libaio QD8 / B4 RA32 | **5277.79** | 1.63% | 15.07 | 越过竞品5149.84 MiB/s |
| B01/B04 | psync QD1 / RA32 | 2872.37 / 2743.41 | 3.59% / 3.69% | 4.44 / 3.98 | 生产语义锚 |
| B02/B03 | psync QD1 / RA64 | 2865.85 / 2953.02 | 6.39% / 6.37% | 4.36 / 4.66 | 相邻效应0%/+8.82%，未过门 |

| 项 | 结果 |
|---|---|
| Phase A | `APPLICATION_QD_SCALABLE`；libaio QD1→8带宽`+167.19%`，GET在途`4.32→15.07`；首尾psync锚漂移`-1.02%` |
| Phase B | `RESOLUTION_INSUFFICIENT`；RA64双配对未达到10%且不一致，不登记为生产旋钮 |
| 架构归因 | 对象余量能被应用异步并发利用；20 MiB同步单流的主要限制在应用/FUSE/Reader请求生成并发，不在Ceph对象服务能力 |
| 下一候选 | QD4/8时FUSE waiting中位`44.5/51`、最大均约51，接近`max_background=50`；属于代码/应用级方向，不在本RUN扩测 |
| 环境闭环 | 临时B4卷按META+UUID精确销毁；业务卷四项指纹不变；Ceph `HEALTH_OK`、6/6 OSD、97 PG active+clean；全程无sudo |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3e/20260904-184259/final-raw/`；376项manifest全通过，SHA256=`bca1d68d86f1b4115768a20efea90f310cd9fbaf871954436aa30ccad11cadca` |

## 二十六、04-tmp2f writeback排空根因与容量曲线（2026-09-04）

> 正式报告：`doc/perf-report/04-tmp2f-writeback-drain-attribution-and-capacity-curve-20260904.md`；
> RUN_ID `20260904-195053`。本项形成单次工程容量曲线，不替换无缓存七项基线。

| 档位 | 实际可用GiB | 正式窗前台MiB/s | 严格排空 | 含排空有效MiB/s | 错误 | 裁决 |
|---|---:|---:|---:|---:|---|---|
| W20 | 19.502 | 2921.63 | 82s | 2001.50 | ENOSPC/hardlink/其他上传错误均0 | `OBSERVED_SAFE_POINT` |
| W32 | 31.185 | 2494.01 | 100s | 1566.01 | 同上 | `OBSERVED_SAFE_POINT` |
| W64 | 62.429 | 2405.62 | 355s | 828.21 | 同上 | `OBSERVED_SAFE_POINT` |
| W128 | 124.917 | 2373.28 | 900s仍有约40.5GB | NA | 同上 | `LIFECYCLE_FAIL` |

| 项 | 结果 |
|---|---|
| 文件级根因 | W16两条hardlink ENOSPC与两个rawstaging残留逐文件匹配；失败分支直传但未登记残留，原daemon不做周期性全目录重扫，恢复挂载才重新发现 |
| 容量含义 | cache增大减少直接回退，却把前段吸收转为更长排空尾部；容量不是越大越安全 |
| 生产边界 | writeback保留为独占文件、低占空比、空间受监控场景的条件增强；建议从32GiB做业务canary，128GiB不满足本负载900秒门 |
| 数据完整性 | W128 timeout后同cache恢复，文件0/63/127抽读通过；四档每档对象均回到seed±8192 |
| 环境闭环 | scrub flags精确恢复；无任务mount/process/loop/backing；业务卷指纹不变；Ceph `HEALTH_OK`、6/6 OSD、97 PG active+clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2f/20260904-195053/final/`；970项manifest通过，SHA256=`5654f4306a76f855ae5be42c02abe6ec16665044ba8f7ef0d3305c657345d80b` |

## 二十七、04-6b端到端容量账与残余调优收口（2026-09-05）

> 正式报告：`doc/perf-report/04-6b-end-to-end-capacity-and-residual-tuning-closure-20260905.md`；
> RUN_ID `20260905-070441`。本项为L1筛选，首次发现候选后按合同停止，不直接修改生产配置。

| 参数/工作负载 | 配对1 | 配对2 | 几何配对效应 | 裁决 |
|---|---:|---:|---:|---|
| R8 / seqread | `+2.53%` | `+5.25%` | `+3.88%` | 无一致5%信号，停止 |
| R8 / mseqread | `+4.48%` | `+4.08%` | `+4.28%` | 无一致5%信号，停止 |
| F1（max-fuse-io 1M）/ seqwrite | `+7.13%` | `+14.81%` | `+10.90%` | 写机制门PASS，`SCREEN_CONTINUE_OPEN_05` |
| F1（max-fuse-io 1M）/ mseqwrite | `+6.28%` | `−1.41%` | `+2.36%` | 方向不一致，停止 |

| 项 | 结果 |
|---|---|
| seqwrite机制 | FUSE平均写请求`256KiB→1MiB`；两配对PUT/OSD op_w完成率提高`7.18%/14.25%`，OSD平均写延迟仅`1.012×/1.020×` |
| 阶段裁决 | `STAGE04_CLOSE_OPEN_STAGE05`；取消04-6b的U300与randrw状态回环，05补F1正式效应及mseqwrite/randwrite/randrw非劣门 |
| 有效性与恢复 | Phase A/B各8/8 cell通过；累计每OSD compact恰好4次；17个任务文件精确清理，对象锚回归；scrub、业务卷及Ceph状态恢复 |
| 持久证据 | `/mnt/c/SunRise/test/04-6b/20260905-070441/`；Phase B索引1032项，SHA见`remote-phase-b/sha256sum.txt`；机制补算见`derived/phase-b-mechanism-repair/` |

## 二十八、04-tmp3f竞品大块同步单流读最终收口（2026-09-05）

> 正式报告：`doc/perf-report/04-tmp3f-competitor-large-block-final-closure-20260905.md`；
> RUN_ID `20260905-125702`。本项复用B256卷既有只读资产，不替换七项256 KiB交付基线。

| 配置/效应 | 配对1 | 配对2 | 平均或裁决 |
|---|---:|---:|---|
| fio bs `256K→20M`（A臂） | `+52.26%` | `+52.08%` | 一致L1信号 |
| RA `8M→32M` | `+14.63%` | `+12.38%` | 一致L1信号 |
| `max-fuse-io 256K→1M` | `+14.22%` | `+11.17%` | 一致L1信号 |
| A/B/C 20M平均 | — | — | `2264.58 / 2570.39 / 2897.12 MiB/s` |
| 最佳C02 | — | — | `2963.95 MiB/s`，为竞品线`57.55%` |

| 项 | 结果 |
|---|---|
| 机制 | GET平均大小仍约256KiB；三个参数依次提高应用/FUSE效率与在途GET，组合约`5.74→13.72`，但未利用对象层全部余量 |
| 对标 | 直接RADOS 4MiB/QD8=`5403.20 MiB/s`、JuiceFS libaio QD8=`5277.79 MiB/s`均可越竞品线；同步单流剩余限制在请求生成/在途并发 |
| 决策 | RA32与FUSE1M登记为20MiB顺序读L1候选，统一转05做七项非劣回归；不再扩测RA/bs相邻值，当前生产基线不变 |
| 有效性与恢复 | 10/10 fio与机制门通过；最大锚漂移`4.51%`；无写入、format、layout或sudo；业务卷、资产与Ceph最终指纹一致 |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3f/20260905-125702/`；归档SHA256=`64632678262adf0f86fc13056a7d11bcef9e68d47fbdf950153ed9e15e68d5be`；manifest `339/339 PASS` |

## 二十九、04-tmp2g writeback固定写量前台容量订正（2026-09-05）

> 正式报告：`doc/perf-report/04-tmp2g-writeback-foreground-bandwidth-capacity-curve-20260905.md`；
> RUN_ID `20260905-160001`。每格固定写128 GiB，不替换无缓存七项基线。

| Cell | fio active-I/O MiB/s | 相对W20双锚 | 启动—返回MiB/s | 非active-I/O开销 | 严格排空 |
|---|---:|---:|---:|---:|---:|
| W20A | 2733.94 | 锚A | 2656.79 | 0.92s | 33s |
| W32 | 3311.08 | +25.33% | 2742.65 | 7.47s | 75s |
| W64 | 3849.15 | +45.69% | 2169.85 | 25.65s | 264s |
| W128 | 3881.53 | +46.92% | 3698.21 | 1.19s | 239s |
| W20B | 2550.03 | 锚B | 2486.33 | 0.93s | 89s |

| 项 | 结果 |
|---|---|
| 容量信号 | 标准fio active-I/O带宽单调提升，64→128GiB仅`+0.84%`，约64GiB后趋于平台 |
| 墙钟边界 | W64出现真实25.65s命令内非active-I/O开销，故预注册启动—返回曲线为`RESOLUTION_INSUFFICIENT` |
| 与04-tmp2f关系 | 固定128GiB突发下五档均排空；不撤销持续180秒大脏写量下W128 900秒超时结论 |
| 生产意义 | writeback继续作为独占文件、低占空比且有持久本地空间时的条件增强；容量按突发净积压和排空窗规划 |
| 环境/证据 | 无任务mount/loop/process/backing；scrub恢复；Ceph `HEALTH_OK`；1202项manifest全通过 |

## 三十、04-tmp2h randrw共享缓存预算筛选（2026-09-06）

> 正式报告：`doc/perf-report/04-tmp2h-randrw-shared-cache-budget-allocation-20260906.md`；
> RUN_ID `20260906-090701`。本项最终证据状态为INVALID，以下带宽只作工程描述，不替换交付基线。

| 总空间档 | R mean / 相对A0 | W mean / 相对A0 | P25 / P50 / P75 mean相对A0 | 生命周期 |
|---|---:|---:|---:|---|
| 32 GiB | `1622.72 / +1.30%` | `1656.11 / +3.38%` | `-41.61% / -43.48% / -43.35%` | 全部PASS |
| 64 GiB | `1686.50 / +5.95%` | `1645.37 / +3.37%` | `-35.01% / -39.51% / -49.10%` | 全部PASS |
| 96 GiB | `1717.68 / +9.03%` | `1655.91 / +5.11%` | `-32.73% / -52.69% / -68.85%` | 全部PASS |
| 128 GiB | `1738.72 / +8.88%` | `1660.37 / +3.98%` | `-7.68% / -22.45% / -41.64%` | 全部PASS |
| 256 GiB | `1719.05 / +8.73%` | `1654.08 / +4.62%` | `-18.18% / -33.55% / -33.13%` | 全部PASS |

| 项 | 结果 |
|---|---|
| 矩阵与锚 | 28/28 cell完成；A0 mean_direction=`1607.01/1586.70/1569.70 MiB/s`，首尾漂移约`2.38%` |
| 证据失败 | runtime sampler同步递归扫描rawstaging，R/P cell最低仅24样本/180秒、最大间隔约31.4秒，违反预注册每秒覆盖门 |
| 严格裁决 | `RUN_VALIDITY_STATE=EVIDENCE_INVALID`，`CACHE_VERDICT=NO_DECISION`；不得登记正式共享配额 |
| 工程信号 | 全部P25/P50/P75均明显低于同RUN A0；W端点计入排空后无耐久写收益，没有值得立即重跑的生产候选 |
| 环境收口 | 无RUN fio/mount/loop/backing；scrub flags恢复；Ceph `HEALTH_OK` |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2h/20260906-090701/`；gzip包可读性通过，SHA256=`01f28290b56578e24a5848a4ef30235f8f715ef3e564cc33a078256e9423946c` |

## 三十一、04-tmp3g竞品16MiB异步写QD曲线（2026-09-06）

> 正式报告：`doc/perf-report/04-tmp3g-competitor-large-block-async-write-closure-20260906.md`；
> RUN_ID `20260906-165126`。本项为无缓存写路径L1能力收口，不替换七项基线。

| Cell | 引擎/QD | 正式窗MiB/s | fio summary MiB/s | CV |
|---|---|---:|---:|---:|
| S01 | psync/QD1 | 2679.26 | 2672.38 | 5.26% |
| C08A | libaio/QD8 | 957.90 | 986.99 | 17.70% |
| C01 | libaio/QD1 | 1349.73 | 1439.15 | 15.96% |
| C02 | libaio/QD2 | 1154.20 | 1243.83 | 14.25% |
| C04 | libaio/QD4 | 1100.98 | 1167.93 | 17.75% |
| C08B | libaio/QD8 | 997.27 | 1025.07 | 17.18% |
| S02 | psync/QD1 | 2478.13 | 2482.89 | 4.10% |

| 项 | 结果 |
|---|---|
| 裁决 | `WRITE_ASYNC_TARGET_NOT_MET`；QD8两次仅为竞品`3051.76 MiB/s`线的`31.39%/32.68%` |
| 稳定性 | 同步锚漂移`7.51%`、QD8重复漂移`4.11%`，均通过8%门；七格环境、排空和重挂门通过 |
| 机制 | async_dio/libaio在QD1即比同步平均低`47.66%`，QD升高只增加排队和完成延迟；异步读收益不能外推到写 |
| 环境闭环 | 七个RUN资产精确删除、一次授权GC、对象锚回归；scrub恢复，Ceph `HEALTH_OK`、6/6 OSD、97 PG clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3g/20260906-165126/`；最终归档SHA256=`874fb99a83580a311cd88d60984e8b58dc621eac3d289a9e7ebe4a040c8233fd` |

## 三十二、04-tmp3h竞品四命令客户端缓存容量（2026-09-06）

> 正式报告：`doc/perf-report/04-tmp3h-competitor-four-command-client-cache-capacity-20260906.md`；
> RUN_ID `20260906-172359`。本项为有客户端NVMe缓存时的条件性能力筛选，不替换无缓存七项基线。

| 档位 | fio读正式MiB/s | 读命中率 | fio写正式MiB/s | fio写含排空MiB/s | 裁决 |
|---|---:|---:|---:|---:|---|
| T32 | 2802.85 | 100% | 2711.32 | 2479.34 | 容量不足 |
| T64 | 2768.85 | 100% | **2866.38** | 2624.75 | 容量不足 |
| T96 | 2743.77 | 100% | 2675.33 | 2442.57 | 容量不足 |
| T128 | 2776.71 | 100% | 2863.04 | **2626.78** | 容量不足 |

| 项 | 结果 |
|---|---|
| 裁决 | `NO_VERIFIED_CACHE_BUDGET_LE_128G`；各档fio读均未过`5149.84 MiB/s`，故不执行REV、不扩256GiB |
| 读侧边界 | 最佳`2802.85 MiB/s`，仅为竞品线`54.43%`；100%命中后扩容无趋势收益，容量不是限制 |
| 写侧边界 | 最佳`2866.38 MiB/s`，为竞品线`93.93%`；各档10秒严格排空，约64GiB后无容量收益 |
| cp口径 | 本地端点与cache backing同属`/dev/nvme1n1`，数值只作工程观察，不参与竞品裁决 |
| 环境闭环 | 最终GC后对象回到O0=`1978609`；scrub恢复，无RUN mount/process/loop/backing；Ceph `HEALTH_OK`、6/6 OSD、97 PG clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3h/20260906-172359/`；最终归档SHA256=`6aaa4b6f8373e6a61c2e4cc66e9b839e317127b9cb58fbb060b4dfd74cf80b10`；manifest `450/450 PASS` |

## 三十三、04-tmp2i randrw缓存采样干扰消除与共享策略收尾（2026-09-06）

> 正式报告：`doc/perf-report/04-tmp2i-randrw-cache-sampler-interference-closure-20260906.md`；
> 正式RUN_ID `20260906-201646`。本项只裁决randrw读缓存与writeback共享空间策略，不替换七项无缓存基线。

| Cell | READ MiB/s | WRITE MiB/s | mean MiB/s | 相对插值A0 | 生命周期 |
|---|---:|---:|---:|---:|---|
| A0-pre | 1706.07 | 1706.64 | 1706.35 | 锚 | PASS |
| T128-P25 | 1394.26 | 1393.71 | 1393.98 | `-16.88%` | 57s排空，PASS |
| T128-R | 1850.50 | 1851.14 | 1850.82 | `+12.32%` | PASS |
| T128-W | 1706.38 | 1707.12 | 1706.75 | `+5.45%` | 10s排空，PASS |
| A0-post | 1589.27 | 1589.27 | 1589.27 | 锚 | PASS |

| 项 | 结果 |
|---|---|
| 有效性 | `RUN_VALIDITY_STATE=VALID`；A0最大漂移`6.88%`，低于8%拒绝线；5/5 cell通过 |
| 采样修复 | 五格各181--182个原始样本，正式窗160个，最大间隔`1.027s`；旧RUN最长约31.4s的递归扫描干扰已消除 |
| 旧/新归因 | 新P25比04-tmp2h旧描述值低`5.44%`，`POST_REPAIR_DIFFERENCE_NOT_MATERIAL`；采样器缺陷不解释混合点负收益 |
| 裁决 | `NO_MATERIAL_MIXED_CACHE_CANDIDATE`；P25初筛失败后按合同取消P50/P75并关闭共享配额线 |
| 生产边界 | 不配置通用读写共享比例；纯读缓存沿用04-tmp2d，条件writeback沿用04-tmp2f/2g |
| 环境/证据 | 无RUN fio/mount/loop/backing；scrub恢复；Ceph `HEALTH_OK`、97 PG clean；持久证据见`/mnt/c/SunRise/test/04-tmp2i/20260906-201646/` |

## 三十四、04-tmp3i热缓存RA32同步单流读最终收口（2026-09-06）

> 正式报告：`doc/perf-report/04-tmp3i-cached-sync-read-ra32-final-closure-20260906.md`；
> RUN_ID `20260906-222839`。本项只关闭热缓存20MiB同步单流读的RA/容量方向，不替换七项无缓存基线。

| Cell | 路径/RA | fio summary MiB/s | 正式窗MiB/s | CV | 命中率 | Ceph RX/fio |
|---|---|---:|---:|---:|---:|---:|
| LOCAL1 | 同loop/ext4 | 6664.56 | **6846.36** | 2.17% | — | — |
| A1 | JuiceFS RA8 | 3577.55 | 3568.03 | 4.69% | 100% | 0.003507% |
| B1 | JuiceFS RA32 | 3579.04 | 3556.86 | 5.07% | 100% | 0.003571% |
| B2 | JuiceFS RA32 | 3654.61 | 3670.35 | 7.04% | 100% | 0.002999% |
| A2 | JuiceFS RA8 | 3345.67 | 3322.42 | 4.38% | 100% | 0.003746% |

| 项 | 结果 |
|---|---|
| 有效性 | `VALID`；A/B漂移`7.13%/3.14%`，均通过8%门；正式窗全部40/40秒覆盖 |
| 效应 | RA32正式均值`3613.61 MiB/s`，相对RA8 `+4.89%`，仍比竞品`5149.84 MiB/s`低`29.83%` |
| 机制 | 100% cache hit且Ceph RX约0.003%，排除容量不足和后端回源；同loop本地`6846.36 MiB/s`，剩余屋顶在JuiceFS缓存/FUSE/同步请求组合路径 |
| 裁决 | `BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET`；关闭继续扩大缓存或RA的同步单流收尾线 |
| 环境闭环 | 本RUN JuiceFS mount、cache mount、loop20、64GiB backing均精确清理；Ceph最终`HEALTH_OK`、6/6 OSD、97 PG clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3i/20260906-222839/`；最终归档SHA256=`b6d8dcc079e6f8d07a972fe1f9c474822161d8dd090fc91ae5683e4ec84b2769` |

## 三十五、04-tmp3j直接RADOS写服务曲线补证（2026-09-07）

> 正式报告：`doc/perf-report/04-tmp3j-direct-rados-write-service-curve-20260907.md`；
> RUN_ID `20260907-093208`。本项绕过JuiceFS/FUSE/TiKV，只证明Ceph对象后端写余量，不替换竞品
> 同命令结果或七项基线。

| Cell | QD | 256 KiB对象末40秒MiB/s | CV | 相对竞品写线`3051.76 MiB/s` |
|---|---:|---:|---:|---:|
| W01 | 32 | `3270.74` | `2.48%` | `+7.18%` |
| W02 | 64 | `3659.83` | `1.84%` | `+19.93%` |
| W03 | 128 | **`3948.86`** | `4.24%` | **`+29.40%`** |
| W04 | 32回环 | `3344.05` | `2.34%` | `+9.58%` |

| 项 | 结果 |
|---|---|
| 裁决 | `DIRECT_RADOS_WRITE_HEADROOM_CONFIRMED`；Ceph对象层并发聚合写能力越过竞品披露线 |
| 曲线边界 | QD32→64 `+11.90%`、QD64→128 `+7.90%`，尚未闭合最终平台；QD128仅达项目6250线`63.18%` |
| 稳定性 | QD32回环漂移`+2.24%`；4/4 cell rc=0、stderr为空，14个健康快照全部`HEALTH_OK` |
| 归因 | RADOS多对象并发与竞品单文件同步语义不同；只排除“Ceph总写带宽不足”，不代表JuiceFS已越线 |
| 环境闭环 | 逐cell按唯一run-name清理；settled对象数均回到`1978611`，最终namespace为空、6/6 OSD、97/97 PG clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp3j/20260907-093208/`；远端白名单149/149通过；含Gate和清理审计的本地最终manifest 156项，SHA256=`51c0df06ec1090916ec92c8711a77f88b3d0c9ce35b584bdf7b8f56c0085c196` |

## 三十六、04-tmp2j randrw纯读缓存容量曲线有效重测（2026-09-07）

> 正式报告：`doc/perf-report/04-tmp2j-randrw-read-cache-capacity-curve-retest-20260907.md`；
> RUN_ID `20260907-155057`。本项只闭合纯读缓存容量曲线，不替换七项无缓存基线，也不重开共享
> 读写缓存配额线。

| Cache | 热集占比 | READ MiB/s | WRITE MiB/s | mean MiB/s | 相对插值A0 | 命中率 |
|---|---:|---:|---:|---:|---:|---:|
| C32 | 25% | 1737.33 | 1737.25 | 1737.29 | `+5.62%` | 11.08% |
| C64 | 50% | 1678.96 | 1678.14 | 1678.55 | `+3.95%` | 22.63% |
| C96 | 75% | 1743.09 | 1742.83 | 1742.96 | `+9.82%` | 31.55% |
| C128 | 100% | 1810.10 | 1810.12 | 1810.11 | `+11.07%` | 38.16% |
| C256 | 200% | 1830.40 | 1829.45 | 1829.92 | `+14.84%` | 47.41% |

| 项 | 结果 |
|---|---|
| 有效性 | `VALID/CURVE_COMPLETE`；8/8 cell通过，A0最大漂移`5.03%`，每格正式窗160/160样本、最大间隔`1.031s` |
| 平台裁决 | 96GiB相对最佳256GiB只低约`4.37%`，更大容量无超过`M=5.03%`的新增收益；登记96GiB最小平台L1 canary |
| 时间形态 | C64/C96/C128/C256的READ W4/W1为`-16.16%/-22.51%/-29.06%/-29.40%`；收益是完整窗口均值，不能外推预热纯缓存峰值 |
| 机制 | 命中率`11.08%→47.41%`时157数据网RX约`1842→1150 MiB/s`，同时客户端NVMe缓存写约`389→865 MiB/s` |
| 环境闭环 | 无本RUN fio/process/mount/cache目录；scrub恢复；Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean |
| 持久证据 | `/mnt/c/SunRise/test/04-tmp2j/20260907-155057/final/`；raw gzip SHA256=`3e94336c98e57783a328e7ecc9cb35252446d264d6070befbe3ce5c1a9c80f8f`；本地独立复算通过 |

## 三十七、04-7 randrw缓存同步停顿与`async_dio`筛选（2026-09-08）

> 正式报告：`doc/perf-report/04-7-randrw-cache-stall-attribution-and-async-dio-screen-20260908.md`；
> RUN_ID `20260908-095000`。本项只筛选P25下的`async_dio`，不重开共享缓存容量线。

| Cell | `async_dio` | READ MiB/s | WRITE MiB/s | mean MiB/s | R/W同步无记录秒 | 排空s |
|---|---:|---:|---:|---:|---:|---:|
| A1 | 0 | 1481.48 | 1481.61 | 1481.54 | 47/47 | 102 |
| B1 | 1 | 1311.74 | 1311.93 | 1311.84 | 11/12 | 10 |
| B2 | 1 | 1269.35 | 1269.71 | 1269.53 | 0/0 | 10 |
| A2 | 0 | 1459.80 | 1459.64 | 1459.72 | 39/39 | 84 |

| 项 | 结果 |
|---|---|
| 有效性 | `VALID`；A/B重复最大漂移`epsilon=3.23%`，材料线`M=10%`；四格及生命周期全部PASS |
| 效应 | B1/A1与B2/A2方向均值分别`-11.45%/-13.03%`，mean total latency分别`+12.83%/+14.85%` |
| 停顿归因 | 同步无记录负担下降`75.53%/100%`且排空缩至10s，支持同步DIO提交/缓存协调参与长停顿，但改善未转化为吞吐收益 |
| 裁决 | `STOP_NEGATIVE`；不启用`async_dio`，不追加L2、容量或QD矩阵；纯读缓存与条件writeback既有结论不变 |
| 环境/证据 | RUN资产精确销毁，scrub恢复；Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean；持久归档SHA256=`bd3a01fd075823b4417b75e27a16eb5b5654e0dfbc24ff2477f03ff08ad3fc87` |

## 三十八、04-8 `max-fuse-io=1M`正式效应与兼容性回归（2026-09-09）

> 正式报告：`doc/perf-report/04-8-max-fuse-io-1m-formal-validation-20260909.md`；
> RUN_ID `20260909-115749`。本项决定FUSE1M能否替换通用256K基线。

| 阶段/项目 | 配对效应 | 裁决 |
|---|---:|---|
| Phase A seqwrite | `+14.32%/+14.42%/+13.24%/+15.26%`；几何`+14.31%` | `SEQWRITE_GAIN_CONFIRMED` |
| Phase B seqread | `-0.50%/-0.52%` | `NON_INFERIOR` |
| Phase B mseqread | `-6.35%/-2.15%` | `INCONCLUSIVE` |
| Phase B randread | `-1.71%/-1.05%` | `NON_INFERIOR` |
| Phase B mseqwrite | `+1.07%/+0.44%` | `NON_INFERIOR` |
| Phase B randwrite | `-21.82%/-2.36%` | `REGRESSION` |
| Phase B randrw read/write | `-0.11%/+5.19%`；`-0.15%/+5.16%` | `NON_INFERIOR` |

| 项 | 结果 |
|---|---|
| 机制 | FUSE平均写请求约`256KiB→1MiB`，PUT/OSD完成率约`+14.5%`；汇总OSD平均写延迟约`+8.0%` |
| 总裁决 | `VALID / STOP_REGRESSION`；通用生产挂载继续256K，1M只保留4MiB单流seqwrite专用挂载灰度候选 |
| 环境闭环 | 精确清理96GiB私有资产；对象`1978609→1978610`，TiKV pending=0；scrub恢复，Ceph `HEALTH_OK`、97 PG clean |
| 持久证据 | `/mnt/c/SunRise/test/04-8/20260909-115749/`；Phase B raw包SHA256=`f43db3855fd70173dfe6cc8daba3a39235fc87e1fd8aaff4d80bd3b6abc23624` |

## 三十九、05-1 randrw不同BS曲线与FUSE适配（2026-09-14）

> 正式报告：`doc/perf-report/05-1-randrw-block-size-sweep-and-adaptive-tuning-20260914.md`；
> Phase A RUN `20260914-124132`，Phase B RUN `20260914-141125`。本项形成按应用BS选择挂载参数的L1结论，不替换256 KiB通用基线。

| 项 | 结果 |
|---|---|
| 标准BS曲线 | 单方向READ/WRITE约为：4K `21`、16K `88`、64K `405`、256K `1731`、1M `1545--1742`、4M `2152--2160 MiB/s`；1M位置漂移超过10%只报范围 |
| 1M FUSE适配 | `--max-fuse-io 256K→1M`两组配对READ/WRITE均提升，效应为`+16.40%--+24.11%`，通过5% L1门 |
| 4M FUSE适配 | 第一对约`+13%`、第二对仅约`+3%`，最小效应`+2.92%`，按合同停止 |
| 配置边界 | FUSE1M只登记为1M randrw专用挂载canary；04-8已证明不能替换256K通用挂载 |
| Phase C | 经复核跳过fresh B1M/B256卷BlockSize筛选；未来仅在明确需要1M专用配置最后增量时重开 |
| 环境闭环 | 最终GC第二轮确认pending delete=0；对象数回到`1994996`，stored相对任务前仅`+655360 B`，三节点TiKV pending=0；Ceph `HEALTH_OK`、97 PG clean，无任务挂载/进程 |
| 持久证据 | Phase A包SHA256=`df81e21b...755b2`；含最终恢复的Phase B final包SHA256=`07eb203b...54bc`；路径均在`/mnt/c/SunRise/test/05-1/` |

## 四十、05-1b randrw卷BlockSize联动收尾（2026-09-14—15）

> 正式报告：`doc/perf-report/05-1b-randrw-blocksize-and-bs-coupled-parameter-closure-20260914.md`；
> 首轮RUN `20260914-172354`，诊断RUN `20260914-221613`，正式补测RUN `20260914-225012`。
> 任务已完成；B256通用生产基线不变。

| 项 | 结果 |
|---|---|
| FUSE64筛选 | 首轮受约15.6%同臂漂移影响，未形成正收益；结合后续B64结果，保持FUSE256K |
| B1M工程信号 | 1 MiB fio下相对fresh B256两位置READ/WRITE提升`+28.34%～+40.70%`，对象请求粒度约`256KiB→1MiB`；因对照漂移约8%，不签精确生产效应 |
| B4M停顿归因 | buffer300时FUSE平均操作时间`26.98→2136.21 ms`且完成集中在正式窗后；buffer1024解除客户端部分块缓冲/周期排空，恢复约`1996/2006 MiB/s` |
| B4M正式效应 | 两臂共同FUSE1M、buffer1024时，B4M相对B256两组READ/WRITE提升`+17.94%～+18.80%`，同臂漂移≤0.69%；登记4 MiB randrw专用卷L1候选，不替换通用卷 |
| B64 16/64 KiB | 16 KiB仅`+1.15%～+1.68%`；64 KiB为`-4.49%～-0.28%`，均无材料性正收益 |
| B64 4 KiB收尾 | 独立`C1→T1→T2→C2`的两组READ为`-6.28%/-2.27%`、WRITE为`-6.29%/-2.25%`，同臂漂移≤2.7%，均值约`-4.3%`；保持B256 |
| scrub与环境闭环 | 两次精确lease均恢复原flag；L/S临时卷按UUID销毁，无任务挂载/进程；Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean |
| 权威证据 | `/mnt/c/SunRise/test/05-1b/20260914-225012/final/opencode-05-1b-20260914-225012-final.tar.gz`；SHA256=`8ef69d78f6464abb02dc91ca32c1e0c8f75286c8d8ca9b2dab86ce3df84132c4` |

## 四十一、05-1/05-1b BS数据可用性与对外可比性独立复算审计（2026-09-15）

> 审计报告：`doc/perf-report/audit-05-1-05-1b-bs-data-usability-and-comparison-20260915.md`（不占任务编号）。
> 纯离线复算：不导入任务方分析器，从四个既有权威归档的fio原始日志与逐秒指标重算54个性能格；
> 无SSH/mount/fio/环境变更。**数值层面无订正**，订正的是可比性等级与两条读法。

| 项 | 结果 |
|---|---|
| 数值复现 | 54/54性能格正式窗均值与05-1/05-1b报告逐格一致（例：256K `1749.7652/1712.9957`、L组`1873.85→2226.125`、M组`2020.47/2592.97/2614.37/1860.41`）；非性能门（fio error=0、身份、97/97 PG active+clean、无foreign fio）全部通过 |
| 可比性分级 | ✅ 256K `1713.0--1749.8`（离散`2.1%`）、4M/FUSE1M `2216.1--2310.7`（`4.3%`）可做精确百分比；⚠️ 1M按口径分`1548--1742`（FUSE256K）/`1970--2058`（FUSE1M）/`2593--2614`（B1M）；❌ 4K `20.2--39.6`、16K `84.7--124.8`、64K `400.3--590.1`只能给区间（离散`5.5%--61.5%`） |
| 口径风险1 | 正式窗`[15,175)`相对fio summary在小BS低`4.18%--8.89%`、大BS低`0.17%--1.37%`；与有方（其数据为180s summary）比对必须同栏并列 |
| 口径风险2 | `W4/W1`：4K `0.44--0.61`、16K `0.41--0.61`、64K `0.43--0.60`、256K `0.79--0.80`、1M `0.92--1.26`、4M `0.91--1.08` ⇒ ≤64K在180s内未达稳态，均值是runtime的函数 |
| 口径风险3 | 同为B256：老生产卷4K `20.2--22.2`、16K `84.7--90.4`；同日新建卷4K `24.5--39.6`、16K `104.0--124.8`。卷状态必须逐点标注，⛔ 不得混入同一条"标准曲线" |
| 口径风险4 | S组12格内同配置4K由`39.6`（位置1）降到`24.5`（位置12），`-38.1%`；根因为元数据事务延迟`6.54→11.17 ms`（格内四分位`3.33→5.67→8.52→12.30 ms`），同期对象GET延迟反而`2.03→0.96 ms` |
| 口径风险5 | 4M用per-job bw log时逐秒积分比`io_bytes`少`8.19%--9.71%`；改用完成日志的正式补测RUN为`0.00%` |
| 订正1 | 05-1b「B4M `+17.94%~+18.80%`」⇒ `NET_GAIN_UNPROVEN` **且已从交付候选撤出**（⛔ 既不写"有收益"也不写"无收益"；跨RUN证据足以撤销候选、不足以重新主张任一方向，重新主张须同RUN三臂）：候选`B4M/b1024=2226.13/2227.25`与现成`B256/FUSE1M/b300=2201.56/2216.14/2310.66`同水平；`+18%`来自对照臂被buffer1024压低`2201.56→1873.85`（读放大`1.06→1.37`）。内部效度不变 |
| 订正2 | 05-1 Phase A的`metrics-pre/post.prom`为空（`METRICS_MISSING_ALLOWED_PHASE_A`）⇒ 标准曲线只有fio端点，⛔ 不得用于机制归因；挂载身份经核对确为交付配置`--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| 机制发现 | 12/12个B256大BS格PUT在途量`147.6--149.8`/上限`--max-uploads 150`，逐秒gauge mean=p95=max=`150.0`；写向天花板=`150×256KiB÷PUT延迟`（`15.03--19.95 ms`→`1880--2496 MiB/s`，与实测对象层`1849/2284`吻合）。B1M/B4M解闸后在途量`60.5/27.1`，对象层总流量`4.12--5.15`→`6.07--6.15 GiB/s`；`used_buffer`p95在所有大BS格均越配置值（`334--1234`）；客户端`7.75--10.20`核/64核。100GbE本批无可签收的NIC计数器证据；历史`3220 MiB/s`是fio randwrite观测，不是网卡能力上限 |
| 小BS机制 | 4K格uploading p95仅`42`、`used_buffer`p95 `10.8 MiB`、对象时延`1.44/1.81 ms`、读写放大约`8.2×`（正式窗应用`39.6/39.7`↔对象`327.2/325.3 MiB/s`）；元数据事务在途量全窗`74.3--91.9`、格内末窗`93.7--101.9`（≈128 inode串行上限）⇒ 属04-4/04-5元数据事务与TiKV方向，不是挂载参数问题 |
| 256K状态 | ⚠️ **推算非实测**：`1749.3 ÷ 0.25 = 6997 PUT/s × 15.03--19.95 ms ⇒ 在途量 105--140/150（70%--93%）`。256K格无机制数据，故只能判"接近闸门"，⛔ 不得写成"已证明饱和"；05-2 用宽松的`256K_UPLOAD_PROXIMITY_GATE`（`uploading` p95 >= 120）决定是否测该 BS |
| 口径归属 | 对外表"JuiceFS标准配置"列只能填通用交付口径（B256+FUSE256K+buffer300）；`FUSE1M/B1M/B4M`值只能填"该BS最优有效配置"列——04-8已证FUSE1M全局化会使256K randwrite回归 |
| 对比裁决规则 | 两侧均输出两栏（summary + 正式窗/W1--W4/W4-W1/CV）；`允许写方向性结论 = 两栏同号 AND 效应 > ε_pair`，其中相对半幅`ε_side=abs(位置1−位置2)/(位置1+位置2)`、`ε_pair=ε_ours+ε_theirs`（均无量纲）。异号记`STATISTIC_SENSITIVE`、同号未超噪声记`INCONCLUSIVE`，均只报区间 |
| 后续 | 新立`doc/perf-tasks/05-2-randrw-upload-concurrency-and-buffer-gate.md`（`max-uploads 150→300`在03-19/04-6b Phase C/05-1b §2.6三次预注册但从未在写侧执行）；原05-2--05-5顺延为05-3--05-6 |
| 复核收敛 | Opus↔GPT两轮往返后一致：审计结论受纳；05-2精简为1M单变量主判+256K条件门+buffer条件分支，删Phase V，机制门改对象PUT字节吞吐，scrub二选一前置，compact降条件动作，⛔ 不预注册U450/U600；格数`15→5--13`、临时卷`2→0`。记录见`doc/deploy-log/review-05-1-05-1b-audit-and-05-2-20260915.md` |
| 证据 | `/mnt/c/SunRise/test/audit-05-1-05-1b/20260915-recompute/`；复算器SHA256=`24cc8e3f5ffff555...`，逐格结果`derived/cells-recompute.tsv`（54格×45列）SHA256=`4d73215072397d1e...`；T-D后顶层`SHA256SUMS` 递归覆盖205项、`205/205 OK`、SHA256=`db8ebac9...16c2`；`ENVIRONMENT_MUTATION=NONE` |
| T-D归档互证 | 七项randrw@256K读写聚合`4350--5328 MiB/s`与sweep正式窗`3535.31/3746.14 MiB/s`不重叠，反映跨RUN/资产状态漂移；七项主机名缺失不可追溯。≥1M仅保留观测并标`NOT_COMPARABLE`，不生成新效应量 |

## 四十二、05-2 randrw上传并发闸门验证（2026-09-15）

> 正式报告：`doc/perf-report/05-2-randrw-upload-concurrency-and-buffer-gate-20260915.md`；
> 有效 RUN `20260915-141750`。任务完成，无新配置候选。

| 项 | 结果 |
|---|---|
| 1 MiB U150→U300 | 两组READ效应`+4.32%/-4.64%`，WRITE效应`+4.41%/-4.66%`；同臂噪声`5.30%/5.36%`，材料门`10.60%/10.73%`，裁决`RESOLUTION_INSUFFICIENT / SCREEN_CONTINUE=FAIL` |
| 对象机制 | uploading mean由`149.81/149.94`升至`193.87/177.45`（`+29.41%/+18.34%`），p95为`300/286.45`；PUT延迟`+25.28%/+28.86%`，吞吐却仅`+1.62%/-5.88%`，四格put_ops/s极差`6.25%`。因此`150`是对照臂命中的并发上限，不是可通过加大并发解锁的吞吐上限；停止U450/U600 |
| 口径稳健性 | READ `ε` 用bwlog/fio summary分别为`5.30%/5.07%`，WRITE为`5.36%/5.05%`；两种口径的配对效应均异号且未过门。逐秒日志积分亏损按位置约`-3.04%→-2.45%`，不改变`NO_CANDIDATE` |
| 256 KiB筛选 | B1 READ/WRITE=`1635.00/1634.72 MiB/s`；uploading mean/p95/max=`69.83/98.15/115`，`98.15<120`，判`GATE_NOT_TRIGGERED`；B2取消 |
| buffer分支 | Phase A未通过四条材料信号，Phase C未触发并取消 |
| 配置结论 | 不登记`max-uploads=300`；通用基线保持B256、FUSE256K、buffer300、U150、cache=0；05-1b竞品对比快照不变 |
| 环境闭环 | scrub flags精确恢复；Ceph `HEALTH_OK`、6/6 OSD up/in、97/97 PG clean；无任务进程/挂载残留，128×1GiB资产完整，未执行主动OSD compact |
| 权威证据 | `/mnt/c/SunRise/test/05-2/20260915-141750/final/05-2-20260915-141750-final.tar.gz`；SHA256=`96be3a4704128cc9f666a3c78eb697675d0598a98d37f797118310439a2eaa4f` |

## 四十三、06-1 randrw缓存与writeback组合包筛选（2026-09-15）

> 正式报告：`doc/perf-report/06-1-randrw-cache-writeback-configuration-screen-20260915.md`；
> 有效 RUN `20260915-204941`。任务完成，未登记生产候选。

| 项 | 结果 |
|---|---|
| 正式均值 | C1=`1796.50/1799.87`、T1=`2090.92/2093.68`、T2=`1990.70/1993.22`、C2=`1664.99/1668.21 MiB/s`（READ/WRITE） |
| 配对均值 | T1/C1=`+16.39%/+16.32%`，T2/C2=`+19.56%/+19.48%`；审计后均改判为**窗长依赖瞬时量，不登记效应** |
| 稳定性裁决 | 同臂噪声`ε=7.32%≥5%`；T格CV=`38.0%～42.1%`、W4/W1=`0.387～0.414`，裁决`RESOLUTION_INSUFFICIENT / NO_DECISION / NO_CANDIDATE` |
| 缓存机制 | T1/T2命中率=`58.05%/60.78%`，命中字节约`1380/1400 MiB/s`，但设备读仅`9.07/0.60 MiB/s`；命中几乎全由宿主页缓存供给，NVMe读缓存名义臂未成立 |
| 上传与PUT补证 | C1/T1/T2/C2 uploading mean=`85.56/108.28/106.43/73.63`、P95=`124.05/150/150/124.10`、峰=`148/150/150/150`；PUT请求率=`8236/9214/9117/7752 ops/s`。T臂进入上传槽饱和区且PUT请求率上升，但不改变非稳态与分辨率失败裁决 |
| 衰减机制 | 应用写减设备写与Dirty增长在约11%内闭合，强支持“RAM吸收→脏页回压”；96GiB缓存约`41.3/43.0s`周转并有约`2078/1988 drops/s`。设备高util不能单独证明是衰减主因 |
| 持久化 | rawstaging峰值=`71.08/75.30 GiB`，Dirty峰值更高达`112.4/118.5 GiB`；两格最终47秒排空，stageFull/errors=0，无缓存验证挂载读回PASS |
| 环境闭环 | scrub精确恢复；Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean；无任务进程、挂载、缓存目录残留，128×1GiB资产完整 |
| 权威证据 | `/mnt/c/SunRise/test/06-1/20260915-204941/phase-a-raw/06-1-raw.tar.gz`；SHA256=`ce8ec6c203d4bae4d8bf39cea38d1af64d7e67fe2a9001d6fa8b2af47383357c`；分析SHA256=`bc81625b7bc114d1444b4750024ba4638bdc41125b3a55440229bd2876281f7b` |

## 四十四、06-2 randrw whole-inode flush调查（2026-09-16）

> 正式报告：`doc/perf-report/06-2-randrw-m1-flush-investigation-20260916.md`；
> RUN `20260916-091446`。调查完成，未登记生产候选。

| 项 | 结果 |
|---|---|
| 前置归因 | Gate2A出现材料阻塞信号；Gate2B经审计回溯`GATE_INVALID`：wall-union `F=0.999990/Gmax=100196`构造性退化，request-weighted `F=0.8964/Gmax=8.65`也不是串行关键路径；观测开销约23%>`M=14.64%` |
| 语义门 | 真实FUSE R1--R8、关键依赖用例、填充卷fsck通过；因上游单测基础设施限制登记`QUALIFIED_GATE3_PASS`，⛔ 不称R1--R10全通过 |
| 补丁机制 | 观测scope约`1.87→1.00`，但flush wait/read约`35/37 ms→52/51 ms`；依赖闭包计数全零且约100ms单桶聚集，不能确认依赖闭包正确，疑似定时轮询待代码确认 |
| Phase A | T1/T2/C2正式窗覆盖仅`158/153/77`秒且runtime超合同，裁决`EVIDENCE_INVALID / NO_DECISION`；fio汇总位置对照约`-30.7%`与`-7.8%~-8.0%`仅作描述 |
| 状态累计 | 四格Ceph objects `4,671,724→5,725,452`；无共享卷GC口径下状态显著变化，未经状态重置不原样重跑 |
| 最终裁决 | `GATE2B_INVALID / EVIDENCE_INVALID / NO_CANDIDATE / PHASE_B_NOT_TRIGGERED / NOT_FOR_PRODUCTION`；06阶段无新增交付配置，不重跑 |
| 环境闭环 | scrub恢复；Ceph `HEALTH_OK`、6/6 OSD up/in；无fio、私有挂载和RUN缓存目录残留；生产二进制未替换 |
| 权威证据 | `/mnt/c/SunRise/test/06-2/20260916-091446/`；Phase A raw包SHA256=`181b7be91b19de794661c8999aebe8f5df6f682e05bafee39bc44e556ded2fb9` |

## 四十五、05-3 randread/randwrite六档BS标准曲线（2026-09-18）

> **2026-09-20订正：`BASELINE_CONFIG_MISMATCH / RETEST_PLANNED`。** 实际遗漏私有msgr8、使用系统msgr3配置；下列历史值不能代表通用交付曲线。05-3b承接配置/日志修正与随机写状态受控重测。
>
> 报告：`doc/perf-report/05-3-random-read-write-block-size-curves-20260918.md`；RUN `20260918-163841`。以下均为同一实际B256/FUSE256K配置、同一既有卷的fio全程摘要，单位MiB/s；A/B为正反序列位置，非配置对照。`L1_PARTIAL_FORMAL_REVIEW`，不得当作生产配置效应。

| BS | randread A/B | randwrite A/B | 证据判读 |
|---|---:|---:|---|
| 4K | 241.4 / 237.8 | 17.7 / 7.8 | 读稳；写B较A低56.2% |
| 16K | 796.3 / 786.5 | 60.4 / 29.0 | 读稳；写B较A低52.1% |
| 64K | 2008.1 / 2010.1 | 159.6 / 128.7 | 读稳；写B较A低19.3% |
| 256K | 3197.2 / 3073.3 | 2667.2 / 486.3 | 读漂移−3.9%；写首尾漂移−81.8% |
| 1M | 1985.3 / 1941.1 | 2664.8 / 2809.9 | 读稳；写日志正式窗待复核 |
| 4M | 2814.2 / 2792.8 | 4049.8 / 4020.5 | fio摘要可报告；读写逐job日志积分缺口使正式窗`UNKNOWN/REVIEW` |

读侧4K—1M的两位置正式窗可测且位置漂移≤3.9%；4M只保留fio摘要。写侧随连续覆盖写明显失稳，三节点TiKV待压缩量合计约`0→100.6 GiB`、Ceph对象数约`5.65→18.50百万`，故**不能**把连续矩阵中的BS差异解释为单一BS因果效应；未启动FUSE1M可选筛选、未登记新配置。第二方独立从原始文件复核24格summary/漂移/降级名单与租约恢复，数值一致。24/24格fio正常、每格128份日志，读写阶段scrub租约均精确恢复；最终Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean、无任务fio/挂载。原始证据`/mnt/c/SunRise/test/05-3/20260918-163841/`，157源目录待审核后再处理。

## 四十六、05-4 单流顺序读写BS曲线与16M写适配（2026-09-19—20）

> **2026-09-20订正：`BASELINE_CONFIG_MISMATCH / RETEST_PLANNED`。** 下列曲线与候选来自系统msgr3背景，未满足私有msgr8基线；旧值保留，正确基线及完整四格适配由05-4b重测，原配置签收不再生效。
>
> 正式报告：`doc/perf-report/05-4-single-stream-sequential-block-size-curves-20260920.md`；标准RUN `20260919-220327`。标准21格完成；适配使用主RUN `20260919-234336`的C1/T1/T2和健康补格 `20260919-235824`的C2。

| 项 | 结果 |
|---|---|
| seqread正式窗 | 64K `980.51/976.72`、256K `1395.75/1392.64`、1M `1472.49/1468.74`、4M `1499.46/1499.42`、16M `1515.27/1516.88 MiB/s`；最大位置漂移0.39%，4M后基本平台 |
| seqwrite正式窗 | 64K `944.13/881.26`、256K `1032.61/1083.53`、1M `1332.82/1297.04`、4M `1516.02/1533.39/1573.54`、16M `1847.12/2001.98 MiB/s`；最大位置漂移8.05%，均未越10%停止线 |
| 16M FUSE适配 | `max-fuse-io 256K→1M`两组正式窗效应`+7.08%/+8.08%`；同臂最大漂移`epsilon=2.57%`，材料线`M=5.14%`，较小效应过门 |
| 配置裁决 | `16M_FUSE1M_L1_SCREEN_CONTINUE`；仅登记16 MiB单流顺序写专用候选，不替换FUSE256K通用基线；读侧不追加RA/FUSE扫描 |
| scrub边界 | 保持scrub开启；一次deep-scrub中止和一次C2 post-gate普通scrub均按无效事件保留并精确卸载，最终C2在scrub结束后单格补测；状态为`VALID_WITH_REPLACEMENT_CELL` |
| 环境闭环 | 无fio/私有挂载；Ceph `HEALTH_OK`、6/6 OSD、97/97 PG clean；三节点TiKV pending=0；固定32GiB写资产inode/大小不变 |
| 权威证据 | `/mnt/c/SunRise/test/05-4/20260919-220327/`；`ALL-SHA256SUMS`覆盖812项，SHA256=`9b6a8b720cfee63bc855085e9bd5471eba5659449d01eff988f5501e2dccdaca`；第二方独立复算一致 |

## 四十七、05-5 多流顺序读写BS曲线（2026-09-20）

> **2026-09-20订正：`BASELINE_CONFIG_MISMATCH / RETEST_PLANNED`。** 实际使用系统msgr3，不能把该读平台作为msgr8通用配置上限；05-5b将完整重测读写。写第9格 `256K-B=3913.19` 的post-health失败，只列污染观察，不参与健康配对均值/漂移。
>
> 正式报告：`doc/perf-report/05-5-multistream-sequential-block-size-curves-20260920.md`；原执行RUN `20260920-072228`。旧配置读矩阵完整，写曲线因Ceph BlueFS DB容量耗尽而部分阻断。

| 项 | 结果 |
|---|---|
| mseqread正式窗 | 64K `2824.60/2816.90`、256K `2891.27/2913.79`、1M `2889.13/2912.43`、4M `2843.59/2900.68`、16M `2827.69/2837.88 MiB/s`；位置漂移`0.27%--1.99%`，五档均值仅`2821--2903 MiB/s`，无大BS增益 |
| mseqwrite已有格 | 64K `4102.65`、256K健康格 `4117.23`（污染观察 `3913.19`）、1M `4060.19/4167.66`、4M `4149.07/3854.25`、16M `4125.77/4106.54 MiB/s`；仅健康边界通过的1M/4M/16M配对漂移`0.47%--7.37%` |
| 写探针 | fio摘要4M A/B漂移`6.68%`，通过10%门；但`4M-B`正式窗CV=`17.26%`、`W4/W1=1.379`，只按范围解释 |
| 阻断 | 第9个写格后`osd.4`的40GiB BlueFS DB用满，约70MiB metadata spillover至slow device；缺`64K-B/4M-C`，状态`WRITE_PARTIAL_INFRASTRUCTURE_BLOCKED`，不拼接补格、不放宽健康门 |
| 配置裁决 | `NO_NEW_CONFIG / RETEST_PLANNED`；旧配置下未见BS收益信号，不能由此闭合正确交付配置的平台或替代当前并发证据 |
| 环境闭环 | 无任务fio/私有挂载；两phase scrub lease均恢复原flags。OSD 6/6 up/in、97 PG clean，但Ceph仍为`HEALTH_WARN/BLUEFS_SPILLOVER`，后续正式矩阵须先修复DB容量 |
| 权威证据 | `/mnt/c/SunRise/test/05-5/20260920-072228/`；远端/本地1002个文件逐项SHA256一致，`ALL-SHA256SUMS` SHA256=`3a873c88cb918757fe6cd4959c1c639b1e1f0540c4f23248bc7bf69dd77b8929` |

## 四十八、05-3b 正确msgr8基线下randread六档BS曲线（2026-09-20）

> 报告：`doc/perf-report/05-3b-random-bs-baseline-repair-and-retest-20260920.md`；读RUN `20260920-092512`、写侧最终范围RUN `20260921-025300`。最终状态`READ_VALID_L1 / WRITE_RANGE_ONLY_STATE_DRIFTED / FINAL_CLEANUP_COMPLETE`；B256/FUSE256K、uploads150/downloads200/buffer300、cache-size0、writeback关、私有msgr8实际生效；128jobs/QD128/direct1，各格180秒，主值为`[15,175)`完成字节聚合。

| BS | randread正式窗A/B（MiB/s） | 两位置均值（MiB/s） | 位置差D |
|---|---:|---:|---:|
| 4K | 260.86 / 259.33 | 260.10 | 0.59% |
| 16K | 938.42 / 940.97 | 939.70 | 0.27% |
| 64K | 2465.03 / 2519.20 | 2492.11 | 2.17% |
| 256K | 4569.31 / 4574.25 | 4571.78 | 0.11% |
| 1M | 3043.87 / 3026.05 | 3034.96 | 0.59% |
| 4M | 4227.48 / 4203.13 | 4215.30 | 0.58% |

A/B为正反序列位置，非不同配置；D为绝对差/两位置均值。全部12格fio正常、逐格128份日志字节/IO次数与JSON精确一致；4M日志缺口已修复，但其秒级CV仍约34%，不能把位置均值接近称为轮内平稳。1M低于256K可复现，归因尚未闭合；不以旧msgr3与本次差值宣称严格线程收益。写侧因六OSD DB仅余约5 GiB、低于首批11.54 GiB经验预算，未启动，旧写值不拼接。最终Ceph HEALTH_OK、6/6 OSD、97 PG clean，scrub精确恢复，无任务fio/私有挂载；原始数据已持久化至`/mnt/c/SunRise/test/05-3b/20260920-092512/remote-read/`，3261个文件逐项SHA一致，GPT本地审核与Luna独立raw复算通过。

**容量进展补充（不替换上述读数据）：** 2026-09-20定向维护16个mseqwrite文件后，DB可用约17.99—18.10 GiB，已释放约4.76 TiB完整slice引用和1997万pool对象；维护观测暂态峰值3.5293 GiB后，按两倍预留重算，randwrite首批需18.594 GiB/OSD、最大批需32.862 GiB，仍未启动写。空间可以回收，但生产自动回收和完整写流程容量尚未解决；详见05-3b报告§十。

**写侧范围收口（2026-09-21）：** 在精确维护后的正确msgr8起点上，最终RUN `20260921-025300`得到4K重复值15.367/11.853 MiB/s，秒级CV 40.84%/44.21%，`D_X=25.82%`，超过预注册10%稳定性门；控制格256K为2532.548 MiB/s、CV39.03%、W4/W1 0.395。异步写日志尾差按绝对带宽误差复算后不改变结论。因批次缺`C_after`且X重复已足以判定`STATE_DRIFTED`，停止后续BS、不跨RUN补点；状态为`WRITE_RANGE_ONLY_STATE_DRIFTED / FINAL_CLEANUP_COMPLETE`，不能称正确基线下randwrite六档曲线完成。最终维护释放2,637,684个对象和约324.893 GiB stored，scrub恢复、HEALTH_OK；raw包SHA256 `0293aeb3...33cb60c`已在本地独立复算通过。

## 四十九、05-4b 正确msgr8基线下单流顺序读五档曲线（2026-09-20）

> 报告：`doc/perf-report/05-4b-single-stream-bs-baseline-retest-20260920.md`；读RUN `20260920-133000`、标准写RUN `20260920-185100`、候选写RUN `20260920-212500`；`READ_VALID_L1 / WRITE_VALID_L1_CONDITIONAL_MAINTENANCE_START / FUSE1M_L1_SCREEN_CONTINUE`。B256、cache0、私有msgr8实际生效，psync/QD1/1job/direct1/32GiB/180s，正式窗`[15,175)`。

| BS | 正式窗两个位置（MiB/s） | 两位置均值（MiB/s） | 位置差D |
|---|---:|---:|---:|
| 64K | 988.37 / 983.84 | 986.10 | 0.46% |
| 256K | 1431.34 / 1440.31 | 1435.83 | 0.62% |
| 1M | 1504.57 / 1559.97 | 1532.27 | 3.62% |
| 4M | 1574.03 / 1581.95 | 1577.99 | 0.50% |
| 16M | 1595.50 / 1601.30 | 1598.40 | 0.36% |

4M→16M仅约+1.29%；首个1M格CV7.11%、W4/W1=1.174完整保留，其余CV1.45%—3.41%。10格逐IO日志精确对账、独立raw复算通过。

| BS | seqwrite正式窗位置值（MiB/s） | 位置均值（MiB/s） | 最大位置差D |
|---|---:|---:|---:|
| 64K | 1003.30 / 1012.91 | 1008.10 | 0.95% |
| 256K | 1186.60 / 1209.88 | 1198.24 | 1.94% |
| 1M | 1456.71 / 1494.86 | 1475.78 | 2.58% |
| 4M | 1644.38 / 1679.45 / 1634.80 | 1652.88 | 2.69% |
| 16M | 1985.30 / 1929.60 | 1957.45 | 2.85% |

标准写11格只覆盖精确`seqwrite.0.0`。首次及每格后执行同一单文件compact/恢复合同，因此标记`CONDITIONAL_MAINTENANCE_START`，不等价于无人工维护的长时稳态。16M下FUSE256K→FUSE1M两组配对收益为`+12.95%/+9.21%`，均高于按位置噪声形成的`M=8.17%`；仅登记16M单流顺序写L1候选，不替换通用FUSE256K。读包SHA256=`e9b8722f...590597`，标准写包=`3e441cde...1deaa`，候选包=`759752cf...3d62`，均已独立raw复算通过。三个RUN均精确恢复scrub，末态HEALTH_OK、无fio/私有挂载。

## 五十、05-5b 正确msgr8基线下多流顺序读五档曲线（2026-09-20）

> 报告：`doc/perf-report/05-5b-multistream-bs-baseline-and-capacity-retest-20260920.md`；读RUN `20260920-145000`、写RUN `20260920-170000`；`READ_VALID_L1 / WRITE_VALID_L1_CONDITIONAL_MAINTENANCE_START`。B256/FUSE256K、cache0、私有msgr8实际生效，psync/QD1/16jobs/direct1/每job4GiB/180s，正式窗`[15,175)`。

| BS | 正式窗两个位置（MiB/s） | 两位置均值（MiB/s） | 位置差D |
|---|---:|---:|---:|
| 64K | 4606.46 / 4674.77 | 4640.61 | 1.47% |
| 256K | 4833.12 / 4801.39 | 4817.25 | 0.66% |
| 1M | 4647.94 / 4773.75 | 4710.85 | 2.67% |
| 4M | 4822.33 / 4827.68 | 4825.00 | 0.11% |
| 16M | 4826.50 / 4842.30 | 4834.40 | 0.33% |

D为绝对差/两位置均值。64K→16M约+4.18%，4M→16M仅+0.19%；64K-1/1M-1的CV为5.56%/5.43%，其余1.58%—4.17%，均完整保留。10格共160份逐IO日志的字节/次数与fio JSON精确一致，独立raw复核通过。

| BS | mseqwrite正式窗位置值（MiB/s） | 位置均值（MiB/s） | 位置差D |
|---|---:|---:|---:|
| 64K | 3680.66 / 3875.72 | 3778.19 | 5.16% |
| 256K | 3953.17 / 4159.79 | 4056.48 | 5.09% |
| 1M | 4184.87 / 4049.51 | 4117.19 | 3.29% |
| 4M | 4082.75 / 3966.70 / 4067.05 | 4038.83 | 2.88% |
| 16M | 4074.20 / 4245.80 | 4160.00 | 4.13% |

写11格也在首次及每格后对16个精确4 GiB文件执行同一compact/恢复合同，因此同样标记`CONDITIONAL_MAINTENANCE_START`。64K→16M约`+10.10%`，4M→16M仅约`+3.00%`，大BS增益趋于饱和。写RUN及11次写后维护全部PASS，末次恢复后对象数回到固定起点、最小DB空闲约18.071 GiB；这是统一人工维护起点下的曲线，不证明长时无维护覆盖写可持续。

读权威根`/mnt/c/SunRise/test/05-5b/20260920-145000/`，原始包SHA256=`666ddf3a...c9cdbd`；写权威根`/mnt/c/SunRise/test/05-5b/20260920-170000/`，原始包SHA256=`0590ce45...810848`。两侧均通过独立raw复算；写阶段末态HEALTH_OK、scrub精确恢复，无fio/compact/私有挂载残留。

## 五十一、05-6 不同BS阶段最终汇总（2026-09-21）

> 报告：`doc/perf-report/05-6-block-size-stage-final-synthesis-20260921.md`；纯离线汇总，未访问环境或运行新负载。状态：`STAGE05_CLOSED_WITH_LIMITS`。

| 项 | 结论 |
|---|---|
| 通用配置 | 保持B256、FUSE256K、U150、D200、buffer300、cache0、writeback关闭及私有msgr8；没有全局配置变更 |
| 按BS方向 | 1M randrw的B1M/FUSE1M有`+28.34%～+40.70%`强工程信号但尚非生产候选；16M单流写FUSE1M两组配对`+12.95%/+9.21%`，为L1专用挂载候选；两者都不能替换通用配置 |
| 不采用项 | B64对4K/16K/64K无材料正收益；U300效应异号；B4M净收益经审计为`NET_GAIN_UNPROVEN` |
| 曲线完整性 | randread、seqread/seqwrite、mseqread/mseqwrite已形成正确msgr8曲线；randwrite因4K重复差`25.82%`收为`WRITE_RANGE_ONLY_STATE_DRIFTED`，不跨RUN拼接 |
| 竞品边界 | 有方只保留已归档randrw范围；矩阵`MATRIX_DRIFTED`，≥1M为`NOT_COMPARABLE/VALID_RANGE_ONLY`，不得归因为软件单因素或写精确落后倍数 |
| 生命周期 | 写曲线依赖每格精确测试文件compact形成统一起点；它是测试维护合同，不是生产自动回收方案。最终现场HEALTH_OK，无任务负载残留 |

## 五十二、06-3 randrw 21.7%观察收益最小复现（2026-09-21）

> 正式报告：`doc/perf-report/06-3-randrw-cache-admission-and-burst-performance-screen-20260916.md` §九；
> RUN `20260921-111637`。状态：`BATCH_COMPLETE / SCREEN_STOP_NO_CLEAR_REPEATABLE_BENEFIT / PAUSED_INCONCLUSIVE`。

| 格 | 配置 | 读/写 MiB/s | 结果 |
|---|---|---:|---|
| A1 | 无缓存、WB/CLW关 | `629.13 / 630.68` | 对照首轮 |
| B1 | 96GiB普通缓存＋WB、CLW关 | `503.60 / 505.71` | B重复1 |
| B2 | 同B1 | `505.67 / 508.21` | B重复2 |
| A2 | 同A1 | `411.61 / 413.43` | 对照末轮 |

| 项 | 结论 |
|---|---|
| 配对效应 | B1/A1读写`-19.95%/-19.82%`，B2/A2`+22.85%/+22.92%`，方向相反 |
| 同臂漂移 | B1→B2仅`+0.41%/+0.49%`；A1→A2下降`34.57%/34.45%`，材料线约69% |
| 描述均值 | B/A两臂均值比读`-3.02%`、写`-2.89%`；历史约21.7%未形成可重复收益 |
| 机制边界 | B两轮命中率约44.7%/44.4%、blockcache峰约96GiB，配置确实生效；staging峰仅18.5/15.75MiB，未复现06-1高积压工作区 |
| 决策 | 不登记生产候选，不触发WB关/开第二批；保留为状态漂移下不可判，不等于缓存或WB已被普遍证伪 |
| 环境闭环 | 四格drain/回读/卸载/私有缓存清理PASS；scrub flags恢复，Ceph 97/97 PG clean，无任务挂载或缓存目录残留 |
| 权威证据 | `/mnt/c/SunRise/test/06-3/20260921-111637/formal/raw-20260921-111637.tar.gz`；SHA256=`fb8e11d3043c0825cf163ab8ac23bc967e089abca2b409a460ae00cbc710fcf8`；本地冻结分析器独立复算通过 |

## 五十三、06-2b randrw range-flush修复与性能验证（2026-09-21）

> 正式报告：`doc/perf-report/06-2b-randrw-range-flush-repair-and-burst-validation-20260921.md`；
> 有效RUN `20260921-140634`。状态：`CORRECTNESS_PASS / PERFORMANCE_SCREEN_STOP / NO_CANDIDATE / NOT_FOR_PRODUCTION`。

| 项 | 结论 |
|---|---|
| H/C/T定义 | H=历史交付件；C=同源无仪表重建基座；T=C+range-flush通知/范围修复 |
| 六格读/写 | H0=`501.92/503.21`、C1=`481.40/483.19`、T1=`483.85/485.48`、T2=`506.40/508.71`、C2=`454.53/456.05`、H1=`461.29/461.98 MiB/s` |
| 配对效应 | T1/C1=`+0.51%/+0.47%`；T2/C2=`+11.41%/+11.55%` |
| 稳定性门 | `ε=5.617%`、`M=11.235%`；只有第二组刚过门，四项未全部通过 |
| 正确性 | 固定覆盖提交通知和已提交依赖误扩范围已修复；定向/race回归及真实FUSE smoke通过 |
| 性能裁决 | 描述性T/C均值约`+5.80%/+5.85%`，低于本RUN可分辨范围且两组不一致；不登记生产候选，不追加参数扫描 |
| 环境闭环 | 六格排空、无缓存读回、优雅卸载和缓存清理PASS；scrub flags恢复；Ceph `HEALTH_OK`；业务挂载未改变 |
| 权威证据 | `/mnt/c/SunRise/test/06-2b/20260921-140634/environment/opencode-06-2b-20260921-140634-evidence.tar.gz`；SHA256=`994b3a53fcdae64ece035c35def4c455e223c7dba8e4c232f3cbdb0dd0782e9c` |

## 五十四、06-4 randrw缓冲I/O独立模型验证（2026-09-21）

> 正式报告：`doc/perf-report/06-4-randrw-buffered-io-model-validation-20260921.md`；
> RUN `20260921-152622`。状态：`VALID_SCREEN / SCREEN_STOP / NO_CANDIDATE`。

| 格 | I/O模型 | 读/写 MiB/s | 实际时长 |
|---|---|---:|---:|
| D1 | direct=1 | `532.41 / 534.03` | 190.994s |
| B1 | direct=0 | `404.53 / 406.00` | 184.403s |
| B2 | direct=0 | `464.04 / 465.82` | 182.525s |
| D2 | direct=1 | `472.08 / 474.26` | 192.040s |

| 项 | 结论 |
|---|---|
| 配对效应 | B1/D1读写`-24.02%/-23.97%`，B2/D2`-1.70%/-1.78%`；两组均无正向信号 |
| 漂移与描述均值 | D臂约`-11.3%`、B臂约`+14.7%`；两臂描述均值比约`-13.53%/-13.54%`，不冒充去漂移因果值 |
| 机制 | B臂进入FUSE的读字节仍约占fio读字节98%；FUSE平均读请求`256KiB→128KiB`，GET读放大`1.23～1.27×→2.25～2.28×` |
| 决策 | 当前256K/128job/QD128 randrw不采用`direct=0`；保留`direct=1`规格基线，不触发竞品同模型补测 |
| 生命周期 | 四格定向fsync、上传排空、无缓存读回和卸载PASS；scrub已恢复，Ceph HEALTH_OK，无fio/私有挂载残留 |
| 权威证据 | `/mnt/c/SunRise/test/06-4/20260921-152622/`；归档SHA256=`b0bc2181f460793efa6305228942e26cc5b7bc8d45c58bf8e0f6ddbae5fe2c65` |

## 五十五、06阶段可比起点恢复只读评估（2026-09-21）

> 分析：`doc/perf-analysis/06-CLOSEOUT-RECOVERY-FEASIBILITY-20260921.md`；未执行负载、GC、compact、
> drop_caches、挂载切换或服务停启。

| 项 | 结果 |
|---|---|
| 当前健康 | Ceph `HEALTH_OK`，6/6 OSD up/in，97/97 PG active+clean；未发现fio；三节点TiKV pending-compaction均为0 |
| 起点差异 | `juicefs-data=6,116,986`对象，约为06-1逐格归一起点`≈1,996,000`的`3.06×`；pending为0不足以证明对象/slice及历史状态等价 |
| 活动范围 | `juicefs-prod`有2个活动会话：157的`/mnt/juicefs`及ceph-node3的portal namespace挂载；全卷GC/compact不能按私有测试目录清理理解 |
| 裁决 | `READ_ONLY_ASSESSMENT_COMPLETE / NOT_READY_FOR_RETEST`；当前状态下禁止直接复验或拼接历史样本 |
| 继续条件 | 只有明确维护窗口、全部会话核对和共享卷操作单独授权后，才评审全卷GC/compact及同一新RUN的A/B/B/A最小复验；否则21.7%项以`PAUSED_INCONCLUSIVE`限范围结束 |

## 五十六、06-5 randrw缓存＋writeback历史收益来源确认（2026-09-21）

> 正式报告：`doc/perf-report/06-5-randrw-cache-writeback-benefit-source-attribution-20260921.md`；
> RUN `20260921-182559`。状态：`COMBINED_SIGNAL_REPRODUCED / RESOLUTION_INSUFFICIENT / PAUSED_INCONCLUSIVE / NO_PRODUCTION_CANDIDATE`。

| 格 | 配置 | 读/写 MiB/s |
|---|---|---:|
| C1 / C2 | 无缓存、WB关 | `1676.40/1680.53`；`1641.59/1645.68` |
| R1 / R2 | 96GiB普通缓存、WB关 | `1657.83/1661.30`；`1782.93/1786.66` |
| W1 / W2 | 96GiB普通缓存、WB开 | `2032.27/2035.62`；`1981.96/1986.01` |

| 项 | 结论 |
|---|---|
| 完整组合W/C | 两组读写均约`+20.7%～+21.2%`且高于`M≈15.09%`，历史约21.7%组合信号复现 |
| 普通缓存R/C | `-1.1%/+8.6%`，无重复材料收益，不能单独解释组合提升 |
| writeback增量W/R | `+22.5%/+11.2%`，同向但第二组低于M；R同臂漂移约`7.55%`，严格来源分辨率不足 |
| 机制与代价 | W格命中率约53%，staging峰约49～52GiB、Dirty峰约94～95GiB，排空37～39s；属于有限前台突发吸收，不是后端持续带宽提高 |
| 决策 | 来源收窄至WB启用后的缓存/staging/宿主脏页协同路径；不登记生产候选，不追加同模型样本，06阶段限范围闭环 |
| 环境与证据 | 7次恢复、六格、排空、读回及恢复PASS；Ceph HEALTH_OK、portal/scrub恢复；归档SHA256=`3fe6902978384d92ea6452cb6ac150e03dfd32acfae4054bab9ecb3916efc114` |

## 五十七、06-2c randrw eager-freeze源码候选筛选（2026-09-22）

> 正式报告：`doc/perf-report/06-2c-randrw-write-path-source-optimization-screen-20260922.md`；
> RUN `20260922-180504`。状态：`CORRECTNESS_PASS / SCREEN_STOP / RESOLUTION_INSUFFICIENT / NO_CANDIDATE / NOT_FOR_PRODUCTION`。

| 格 | 构建 | 读/写 MiB/s | 排空 |
|---|---|---:|---:|
| C1 | 官方1.4.1同源对照 | `2288.22 / 2292.30` | 40s |
| T1 | C＋eager-freeze | `2160.31 / 2163.89` | 51s |
| T2 | C＋eager-freeze | `1802.34 / 1806.31` | 19s |
| C2 | 官方1.4.1同源对照 | `1758.52 / 1762.07` | 2s |

| 项 | 结论 |
|---|---|
| 配对效应 | T1/C1读写`-5.59%/-5.60%`，T2/C2`+2.49%/+2.51%`，方向相反 |
| 漂移与分辨率 | C1→C2约`-23.15%`，T1→T2约`-16.5%`；`epsilon=23.149%`、材料线`M=46.298%` |
| 时间形态 | T两格均为首段较快、末段较慢；T相对配对C留下更多staging并需要更长排空 |
| 机制判断 | 四格上传并发P95均触及150，缓存NVMe长期高负载；候选改变接纳/积压时序，未提高下游服务率 |
| 决策 | 当前eager-freeze实现停止，不重跑挑样本，不升级为生产候选；不外推为所有源码方向均无空间 |
| 环境与证据 | 四格正确性、排空、无缓存读回及恢复均PASS；portal/scrub恢复、Ceph HEALTH_OK；本地与远端3420文件逐项SHA256一致 |
| 权威证据 | `/mnt/c/SunRise/test/06-2c/20260922-180504/`；派生清单SHA256=`2948a602f0ed4780af3efa59c32868b7f23b5c569751a8f5562e4b71086350b3` |
## 05-3c：randwrite 不同BS描述性补测（2026-09-25）

> 报告：`doc/perf-report/05-3c-randwrite-bs-trend-completion-20260925.md`；RUN `20260924-225547`。同一B256/FUSE256K、cache-size0、writeback关、私有msgr8配置，128 jobs/QD128/libaio/direct1，每格180秒，值为`[15,175)`逐IO完成日志均值。**仅描述实际顺序，不是稳态BS效应。**

| 顺序与BS | randwrite（MiB/s） | CV | 解释 |
|---|---:|---:|---|
| 256K前锚 | 3156.30 | 19.82% | 同配置起点 |
| 16K | 64.20 | 49.96% | 顺序观察 |
| 64K | 174.56 | 45.15% | 顺序观察 |
| 1M | 3392.26 | 24.94% | 顺序观察 |
| 4M | 3779.45 | 43.27% | 顺序观察 |
| 256K后锚 | 693.74 | 26.90% | 与前锚相差127.92% |

六格fio/健康门通过、每格128份日志覆盖180秒；三节点TiKV default/kv pending compaction从0增至约53.35 GiB，表明明显状态积累但不单独证明因果。结论`DESCRIPTIVE_ONLY / STATE_DRIFTED`，不覆盖05-3b的写侧范围裁决。权威归档：`/mnt/c/SunRise/test/05-3c/20260924-225547/05-3c-20260924-225547-evidence.tar.gz`，SHA256 `ed98d17b16415b9a0fe34ef0a2c70bbfd723a999ff6582810f502dfc2810d9ba`；远端本RUN暂存已精确清理。
