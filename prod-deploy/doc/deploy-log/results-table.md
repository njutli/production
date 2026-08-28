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
