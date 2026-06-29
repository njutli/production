# 12 下一阶段调优方向分析（基于 fullmatrix 测试结果 + 11 系列文档整合）

> 日期：2026-06-25
> 基础：fullmatrix 测试结果（results-table §七）+ 6 份 11 系列文档 + 3 份 tun/ 文档
> 目的：整合各模型提出的调优方向，结合最新测试数据裁决优先级

---

## 一、fullmatrix 测试后的现状更新

### 1.1 最新数据矩阵（排除 writeback 虚高数据）

| 配置 | randread r1(冷) | randread r3(热) | randrw r1(R/W) | seqwrite-fsync | seqread(热) |
|------|:---:|:---:|:---:|:---:|:---:|
| c0-default | 31.2 | 31.6 | 15.1/14.7 | 51.8 | 75.7 |
| c0-noRA | 44.0 | 49.2 | 17.1/16.8 | 37.9 | 48.0 |
| cache-default | 27.9 | 96.2 | 16.4/16.0 | 43.3 | 36.7 |
| cache-noRA | **101** | **174** | 16.3/16.0 | 47.1 | 46.9 |

### 1.2 关键结论

1. **randread：cache-noRA 是唯一冷态达标配置**（101 > 59），热态更高（174）
2. **randrw：所有配置均不达标**（~16 MB/s 读），readahead/cache 均无效
3. **seqwrite：所有配置均不达标**（最高 51.8 < 59），但此前 09 基线 117 是可信的（同 OSD 预热条件下测得）
4. **writeback 数据全部不可信**：写只落本地缓存未刷后端，读缓存命中本地，带宽远超千兆上限

### 1.3 与 11 系列文档预期的差异

| 11 系列预期 | fullmatrix 实测 | 差异原因 |
|------------|----------------|---------|
| c0-default randread ~46 | 实测 31.2 | 11 系列引用的 45.9 有 100G 默认缓存加持；fullmatrix cache=0 真冷态 |
| cache-noRA randread ~78 | 实测 101(r1)/174(r3) | 11 系列 10_A_4 的 77.7 也有缓存贡献；fullmatrix 证明冷态就 >100 |
| randrw 未深入分析 | 实测 ~16，远低于预期 | 所有模型都低估了 randrw 瓶颈严重性 |

---

## 二、11 系列文档价值评估

### 2.1 有价值的方向（仍值得下一阶段执行）

| 方向 | 来源 | 价值 | 理由 |
|------|------|------|------|
| **源码级：去掉 ceph.go:137 的 Head/Stat 调用** | GLM5.1/11-summary | 高 | 每次读多一次 OSD 往返，cache-noRA 下残余放大仍 1.51×，省掉 Head 可降延迟和放大。**现在冷态已达标(101)，但 randrw 仍不达标，降每读往返次数可能帮助 randrw** |
| **pprof CPU profile（ra=0 下）** | GLM5.1/glm52/deepseek/minimax/qwen（5/6 票） | 高 | 所有模型一致推荐，成本低(30min)。可定位残余开销是 CPU 密集还是 IO wait，决定后续方向。**特别需要分析 randrw 时的 CPU 热点** |
| **ra=0 下 strace 补采** | glm52 P2 | 中 | 10_A_2_3 的 strace 2.60× 是 default readahead 下测的，ra=0 下的放大从未实测。但 fullmatrix 已证明 ra=0+cache 冷态达标，优先级降低。**对 randrw 做 strace 更有价值** |
| **JuiceFS 线程模型调研** | glm52 P3/qwen 方向四 | 中 | 解释为何 iodepth/numjobs 调参全无效。如果 FUSE dispatch 是单线程，可能是 randrw 瓶颈的根因（读写共享一个 dispatch 队列） |
| **双挂载点交付策略** | glm52 §五 | 高 | 随机读用 cache-noRA（达标），顺序读写用 default（达标）。**但不解决 randrw**，需向业务确认是否可分挂载点 |
| **多客户端 RAF 摊薄验证** | glm52 §七 | 中 | 10_2 的 92.1 超过单客户端天花板 58，需区分后端实际 RAF 摊薄。**fullmatrix 未测多客户端，仍是未解问题** |

### 2.2 已被 fullmatrix 证伪或降级的方向

| 方向 | 来源 | 判定 | 理由 |
|------|------|------|------|
| **readahead 中间档位甜点** | deepseek/minimax/qwen P0 预读分层 | ❌ 已证伪 | fullmatrix + sweep 已穷尽 0/1/4/8/default，0→1 断崖式下跌，无甜点 |
| **FUSE congestion_threshold 调优** | qwen/deepseek P0 | ❌ 已证伪 | 10_A_1 已证 waiting≈0，fullmatrix 未改变此结论 |
| **FUSE splice/max_read/no_readahead** | glm51/deepseek/minimax | ❌ 已证伪 | 10_A_7 已证系统不支持（fusermount3 3.10.5 + kernel 5.15） |
| **元数据强缓存** | qwen 方向二 | ❌ 已证伪 | 10_A_2_3 §三已证对纯 randread 无增益 |
| **EC 2+1 池对照** | glm52 §二 | ❌ 降级 | L1=1.04× 已证 EC/网络非放大源；fullmatrix 证明 cache-noRA 冷态已达 101，EC 分片数不是瓶颈 |
| **allow_ec_overwrites=false** | glm52 §三 | ❌ 降级 | 同上，L1=1.04× 已排除 EC 层 |
| **MTU 9000 jumbo frame** | glm52 §六 | ❌ 降级 | L1=1.04× 包含了 TCP/IP 头开销，占比极小（<0.1×），不值得全链路改 MTU |
| **OSD perf dump 分解后端延迟** | glm52 §四 | 🔶 降级 | 对 randread 意义不大（冷态已达标）。**但对 randrw 仍有诊断价值**——读写争用时 OSD 侧排队情况 |
| **PG primary 分布** | glm52 §五 | 🔶 降级 | 6 OSD 小集群影响有限。**但 randrw 时如某 OSD 成热点，仍有价值** |
| **256K 对象 rados bench** | glm51 §六/deepseek P1-3 | 🔶 降级 | 后端裸上限的精确值对 randread 不再关键（冷态已达标）。**但理解 randrw 时后端能力仍有用** |
| **slice 碎片化 fsck/gc** | glm51 §2.5/deepseek P2-2 | ❌ 已证伪 | 10_A_2_3 strace 139≈4×35，精确对齐 EC 4+2，无额外 GET |
| **v1.4 升级** | 多文档提及 | ❌ 已证伪 | 10_1 单客户端 -3.3% |
| **--buffer-size 调大** | 多文档提及 | ❌ 已证伪 | 08_2 B 已证反降 |
| **升万兆网卡** | glm51 P6 | ❌ 降级 | 达标率=1/RAF公式正确，但 fullmatrix 证明 ra=0+cache 冷态已达标(101)。**randrw 不达标不是因为放大，升网卡也不解决** |

### 2.3 新增方向（fullmatrix 暴露的新问题）

| 方向 | 价值 | 理由 |
|------|------|------|
| **randrw 瓶颈深度分析** | **最高** | 所有配置 ~16 MB/s，远低于 59。这是当前唯一不达标的指标，且所有 11 系列文档都没有深入分析 randrw。读写争用的根因完全未知 |
| **randrw 下 pprof + strace** | 高 | 需要理解 randrw 时 JuiceFS 在做什么——是写阻塞了读？还是 FUSE dispatch 串行化？还是 OSD 侧排队？ |
| **randrw 下 OSD perf dump** | 中 | 读写争用时 OSD 侧的 op_in_queue 和 op_latency 变化 |
| **cache-noRA 的 seqwrite 为什么只有 47.1** | 中 | 09 基线 117 vs fullmatrix 47.1，差异可能来自 OSD 预热状态不同。需要同条件 A/B 对比 |
| **cache 预热效应量化** | 中 | cache-default randread r1→r3 从 27.9 涨到 96.2（3.4×），cache-noRA 从 101 涨到 174（1.7×）。需理解预热曲线以确定交付口径 |

---

## 三、各模型文档质量评价

| 文档 | 核心贡献 | 主要局限 |
|------|---------|---------|
| **11-random-read-tuning-summary** | 阶段总结最全面，放大分解清晰，源码分析到位 | readahead 结论被 fullmatrix 修正（77.7 有缓存贡献，真冷态 49.6 不达标，但 cache-noRA 冷态 101 达标） |
| **11-deepseek-v4** | 决策树清晰，P0 两件事（FUSE waiting + tcpdump）方向正确 | P0-1 已被 10_A_1 证伪；tcpdump/tshark 价值被 10_A_2_3 strace 替代 |
| **11-glm52** | 最先发现 ra=0 真冷态不达标(49.6)，第三条路判断准确 | P0(NIC RX 精测)已被 fullmatrix 替代；未预见到 cache-noRA 冷态可达 101 |
| **11-minimax** | 预读分层思路正确，FUSE 参数调优步骤详细 | P0(预读分层)已被 sweep 证伪；FUSE 参数被 10_A_7 证伪 |
| **11-qwen** | 达标率=1/RAF公式最深刻，FUSE congestion 疑点有价值 | FUSE congestion 被 10_A_1 证伪；元数据缓存被 10_A_2_3 证伪 |
| **11-gpt-5.4** | 先分层再决定方法论正确，决策框架清晰 | 预读分层被证伪后，文档的 P0/P1 已无实际可执行内容 |
| **tun/glm51** | 最先给出49.6 物理上限硬约束，tcpdump 分解法 | 49.6 被 readahead 关停推翻（77.7），又被 fullmatrix 修正（cache-noRA 101）。tcpdump 价值被 strace 替代 |
| **tun/glm52** | EC 2+1 / overwrites=false / MTU 三个新角度有创意 | 全部被 L1=1.04× 降级——EC/网络层不是放大源 |
| **tun/qwen** | 达标率=1/RAF是最核心的理论洞察，FUSE waiting 采样步骤最规范 | FUSE waiting 和元数据缓存均被证伪 |

---

## 四、下一阶段优先级建议

### P0：randrw 深度分析（最高优先级）

randrw 是当前唯一不达标的指标（~16 MB/s vs 59 目标），且根因完全未知。

| 步骤 | 方法 | 预计耗时 | 期望产出 |
|------|------|---------|---------|
| 1. pprof CPU profile | cache-noRA 配置下跑 randrw 60s，curl pprof 6062 | 30min | CPU 热点归属（FUSE dispatch? librados? 锁竞争?） |
| 2. strace 采样 | randrw 期间 strace -c -p $(pgrep juicefs) 10s | 30min | syscall 层放大 + 读写 syscall 交错模式 |
| 3. FUSE waiting 采样 | randrw 期间采 /sys/fs/fuse/connections/*/waiting | 10min | 读写是否互相阻塞 |
| 4. OSD perf dump | randrw 期间逐 OSD 采集 op_in_queue/op_latency | 30min | 后端排队 vs 处理延迟 |

### P1：源码级优化评估

| 方向 | 来源 | 预期收益 | 风险 |
|------|------|---------|------|
| 去掉 ceph.go:137 Head/Stat | 11-summary §2.3 | 每读省 1 次 OSD 往返 | 需确保元数据一致性 |
| rSlice.ReadAt 批量读取 | 11-summary §2.3 | 合并相邻 block GET | 改动大 |
| 线程模型调研（go-fuse dispatch） | glm52 P3/qwen | 解释 randrw 串行化根因 | 只调研不改代码 |

### P2：交付策略确定

| 配置 | 适用场景 | 达标情况 |
|------|---------|---------|
| cache-noRA（--max-readahead 0 --cache-size 100G） | 纯随机读 | ✅ 冷态 101，热态 174 |
| default（不加参数） | 顺序读写 | ✅ seqread 107，seqwrite 117（09 基线） |
| 双挂载点 | 混合负载（读写分离） | 各自达标，但 randrw 场景仍无解 |

需向业务确认：
1. 实际负载是纯随机读、还是 randrw 混合读写？
2. 如果是 randrw，读写比例是多少？（fio 默认 50/50，实际可能不同）
3. 是否可接受双挂载点方案（读/写分到不同挂载点）？
4. 是否可接受多客户端聚合（4-cl randread 66.9 > 59）？

### P3：辅助诊断（按需执行）

| 方向 | 触发条件 |
|------|---------|
| 多客户端 randrw 聚合测试 | 如果 randrw 单客户端不达标，看多客户端是否可行 |
| OSD 侧 bluestore_cache_size_ssd 调大 | 如果 OSD perf dump 显示 op_process_latency 高 |
| randrw 下 NIC RX 采样 | 确认 randrw 的放大倍数（读+写各自贡献多少网络流量） |

---

## 五、一句话总结

**fullmatrix 测试将问题从randread 不达标收敛为randrw 不达标——cache-noRA 已让 randread 冷态达标(101)，但 randrw 在所有配置下仅 ~16 MB/s。11 系列文档提出的方向大多已被 10_A 系列证伪或降级，下一阶段应聚焦 randrw 根因分析（pprof + strace + OSD perf dump），同时评估双挂载点交付策略。**
