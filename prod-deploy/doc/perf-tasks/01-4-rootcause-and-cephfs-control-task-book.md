# 任务书 01-4：FUSE 单进程 6 核封顶「根因定位」+ CephFS 对照实验

> 面向 GLM。**本任务书的定位是「瓶颈根因定位」，不是「换栈评估」。**
> 01-3 已证"单进程 CPU 封顶 ~6 核 / bw 封顶（真值 ra0 randread ~2404）"是**现象**，但**没定位到"这 6 核到底卡在哪个环节"**。
> 本篇的主线 = 用 pprof 把根因定位到具体调用栈；CephFS 对照只是**判定"根因是否 = FUSE 用户态方案"的辅助实验**，
> 且**门槛前置**：只有在步骤 1+2 确认"是 FUSE 方案固有开销、且无客户端调优空间"后才做步骤 3。
>
> **贯穿原则（用户强调）**：调优方向聚焦**瓶颈定位与根因分析**，参数调节与方案对比只是辅助。
> **只有在瓶颈定位清楚、确认是方案架构限制、且无调优可能时，才真正考虑转其他方案。**
> 本任务书任何一步都不得跳过定位直接下"换栈"结论。
>
> 承接：`results/prod-nolimit-scalability-20260716-162750/`（01-3，含未分析的 pprof binary，在 157 `/tmp/scalability-results/`）。
> 方法论见 skill：`test-commands-reference.md`（§6/§7/§8.3/§9）、`TESTING-GUIDE.md`、`LONG-RUNNING-TEST-SKILL.md`。
> 上位规划：`doc/perf-analysis/01-baseline-review-and-nolimit-plan.md` §5.3.4a / §七 / §7.3 决策链。

---

## 🚫 前置依赖（BLOCKER — 级联自 01-3，未满足前不得开跑）

**本任务书整篇建立在 01-3 的现象结论之上**（"单进程 6 核封顶 ~595% / bw 封顶 ~2876 / 贴 rados 裸测 3198 的 90% / 多实例 1.74×"）。
而 **01-3 已用 01-2d 全量重测真值重新确立前提**（见 `01-3-...md` 顶部），本任务受两点直接影响：

1. **数据已更新**：01-3 引用的 randread bw（2876/2891 等）来自旧统计错误，rados "3198 / 贴后端 90%" 是不可复现单点值。
   → **01-2d 真值**：JuiceFS randread ra0 §8.3 = **2404**（default 1480）；rados 后端随机读裸 = **~4300–4400 MB/s**（低方差稳态）。
   本篇 §〇 中 595%/2876/1.74× 等 CPU/多实例数字**仍待 01-3 用真值复跑后回填**（标 "⟨待 01-3 复跑回填⟩"），但 bw 与后端裸值已可锁定为上述真值。
2. **后端裸能力闸门（已判定，结论变了）**：01-3 前置闸门用 01-2d 真值判定 —— 后端随机读裸 ~4300 **< 验收线 6250（69%）、< BeeGFS 9045（48%）→ 后端不达标，是首要瓶颈**。这意味着：
   - "FUSE 单进程封顶"**不是全部** —— JuiceFS ra0=2404 仅为后端 4300 的 56%，客户端确有额外损耗（本篇 C1/C2/C3 命题仍有意义）；
   - 但**首要瓶颈已定性在后端 EC4+2 随机读**（非客户端）。因此本篇的 CephFS 对照，其判读表新增一条更可能的落点：**CephFS 与 JuiceFS 相近（都被后端 4300 卡住）→ 换栈无益，回头攻后端**（见 §3.2）。

**因此本任务开跑条件（全部满足）**：
- [ ] 01-3 已激活并完成，现象结论（CPU 饱和拐点、多实例是否倍增）用 01-2d 真值重新确立；
- [x] 01-3 的**后端裸能力闸门已判定**（2026-07-17）：后端 ~4300 **不达标**、波动主因=脏 pool RocksDB bloat（**可消除、非架构固有**）→ 尚未坐实"架构受限无法提高"，需 EC→副本对照进一步判；
- [ ] 本篇 §〇 所有 "⟨待 01-3 复跑回填⟩" CPU/多实例数字已替换为真值。

> **前提变化提醒**：旧版本任务设计假设"后端够强、瓶颈纯在客户端 FUSE"，故 CephFS 对照的默认预期是"CephFS 更高=FUSE 是元凶"。
> **新基线下后端本身不达标**，所以**在做客户端 pprof 根因/CephFS 对照之前，后端 EC4+2 随机读能否提高（EC→副本、OSD 扩容）应是更优先的一条线**。
> 若后端经诊断确认"架构受限无法提高" → JuiceFS 客户端封顶已非主瓶颈，本任务（FUSE 根因+CephFS 对照）失去前提，直接进决策链。

---

## 〇、先读：01-3 定位到哪一层、还差什么

**01-3 已证（现象层）**（⚠️ CPU/多实例数字待 01-3 用 01-2d 真值复跑后回填；bw 与后端裸值已锁定为 01-2d 真值）：
- 单进程 CPU 封顶 ~595%（6.0 核 / 64 逻辑核 = 9.3%），并发 32→16384（512×）CPU 仅 +5%，S1→S0 bw +4.7%/CPU +0.7% 双双饱和。（CPU 饱和**趋势**大概率仍成立，具体数值待复核）
- bw 封顶 = **01-2d ra0 randread §8.3 = 2404 MiB/s**（旧值 2876 作废）。~~rados 裸测 3198 的 90%~~ 作废 —— 后端裸真值 ~4300，**JuiceFS 2404 仅为后端的 56%，未贴后端**。sys CPU 占比高（usr~320 / sys~264，待复核）。
- 线程级：CPU 分散在大量匿名 Go 线程，命名线程里最集中的是 librados **msgr-worker**（稳态单线程 ~60-67%，**无单线程 100% 锁死**）。
- 多实例可倍增（N4 ra0=⟨待回填，旧值 5013⟩=单进程 ⟨旧值 1.74×⟩），但业务要求单挂载点，多实例不满足业务需求。

**尚未定位（根因层）——"为什么只能用 6 核"三个候选未区分**：
1. **(C1) FUSE `/dev/fuse` 单管道 dispatch 模型限流** —— 若成立=FUSE 用户态方案的架构限制，**无客户端调优空间**。
2. **(C2) librados / messenger 线程模型或连接数上限** —— 可能有配置/连接可调空间。
3. **(C3) Go runtime 调度 / 内部锁竞争（semaphore/futex）** —— 可能有 JuiceFS 内部并发参数可调。

**这三者的区分，直接决定"有无调优可能"**，也决定 CephFS 对照是否有意义。01-3 抓了 pprof 但没分析——**这正是定位根因的钥匙**。

---

## 〇.1 红线与环境约束（务必遵守，同 01-3）

- **157 上有 WekaIO 业务在跑（红线）**：**不得动 157 内核参数、100GbE 网卡/驱动/RoCE、md0、WekaIO 路径**。
- **只有 157 一个 client 节点**。CephFS 挂载（步骤 3）也在 157，须评估内核态 ceph 客户端对 157 的影响，**开跑前确认 WekaIO 不受影响**；如有任何冲突迹象立即停并记录。
- **BeeGFS 与本测试抢同一批盘（150/151/152 的 nvme），须错峰**，勿并跑。
- 口径沿用不限速：bs=256k、direct=1、cache=0、time_based 180s、REPEAT=3；每轮跑前 drop_caches（157 + 3 slave）。
- **验收口径对齐**：randrw 对照并发 = **128（D2 档 16×8）**（用户明确的最终验收口径）；randread 对照用 S0（128×128）与 D2 两点。
- 达标参考线：不限速 50% = 6250 MiB/s（趋势为主，不作硬判据）。

---

## 一、步骤 1：pprof 热点分析（根因定位，主线，零测试成本）

**这是本任务书的核心。先做，做完才决定后面怎么走。**

1. 把 157 `/tmp/scalability-results/` 里 01-3 抓的 CPU pprof binary 下载到本地（三层 SSH）。
   如原 pprof 采样太短/不足，在 157 重新对 randread S0（128×128，ra0，稳态期）采一次
   `go tool pprof -seconds 30 http://127.0.0.1:6060/debug/pprof/profile`（JuiceFS 默认开 pprof agent :6060，除非 mount 带 `--no-agent`；env 确认）。
2. 本地 `go tool pprof`：出 `top30`、`-cum top30`、`list` 热点函数、并生成火焰图（`-svg` 或 `-http`）。
3. **同时采一份 goroutine + mutex/block profile**（`/debug/pprof/goroutine?debug=2`、`/debug/pprof/mutex`、`/debug/pprof/block`），看是否有大量 goroutine 阻塞在同一处 / 锁。

### 1.1 判读（写进 summary，映射到 C1/C2/C3）

| pprof 热点主要落在 | 指向 | 含义 / 下一步 |
|----|----|----|
| `fuse.*` / `/dev/fuse` 读写 / `Server.readRequest` / 内核↔用户态收发 | **C1 FUSE 管道** | 疑架构限制，客户端几乎无调优空间 → 直接进步骤 3 CephFS 对照验证 |
| `librados` / `msgr` / `ms_dispatch` / rados IO 提交回收 | **C2 librados** | 有连接/线程配置可调空间 → 步骤 2 针对性验证 |
| `sync.*` / `semaphore.Acquire` / `runtime.futex` / chan 阻塞 | **C3 锁/调度** | 有 JuiceFS 内部并发参数可调空间 → 步骤 2 针对性验证 |
| sys CPU 高但 pprof（用户态）分不出大头 | C1 倾向 | sys 时间多在内核 FUSE/网络栈 → C1；可加 `perf top`/`strace -c` 佐证 |

> 若 pprof agent 被 `--no-agent` 关闭：重挂一个带 agent 的实例专门采样（不影响红线，仅新增挂载点）。

---

## 二、步骤 2：单进程"能否扩核"的针对性验证（根因佐证，仅按 pprof 指向做）

**不盲扫全部参数**（老集群已证 buffer-size/prefetch/max-readahead 对随机读全无效，见 `perf-analysis/09/11`；
新集群 ra0 读放大已 =1.0，非老集群 2.5× 局面）。**只针对步骤 1 pprof 指向的那一类，试 1-2 个直接相关旋钮**，
目的是回答一个问题：**6 核这堵墙，能不能被客户端手段松动？**

- **若 pprof 指向 C2 librados**：试 librados 相关（如客户端连接数 / `--get-timeout`；或多 pool/连接对照）。看 S0 CPU 能否 >6 核、bw 能否 >2404（进而逼近后端裸 ~4300）。
- **若 pprof 指向 C3 锁/调度**：试与该锁相关的 JuiceFS 并发参数（依 pprof 定位的具体结构决定，如 buffer-size 仅在 pprof 指向 buffer 竞争时才试）。
- **若 pprof 指向 C1 FUSE 管道**：客户端**无对应旋钮**，不试参数，直接记录"无调优空间"，进步骤 3。

判定（写进 summary）：
- **墙能松动**（CPU/bw 随该参数上升）→ **说明尚未到架构极限，有调优可能**，继续沿该方向调，**暂不换栈**。
- **墙纹丝不动** → 坐实"客户端无调优空间"，为步骤 3 提供前置。

> 每个参数点只跑 randread S0（128×128，ra0）REPEAT=3、§8.3 聚合即可，快速证伪。

---

## 三、步骤 3：CephFS 内核态同后端对照（辅助实验，门槛前置）

**触发门槛（缺一不可，写进 summary 说明是否满足）**：
- 步骤 1 pprof 指向 **C1（FUSE 管道）**，或步骤 2 证明"墙纹丝不动、客户端无调优空间"；且
- 业务要求单挂载点、多实例 workaround 不被接受（已确认）。

**若门槛不满足**（pprof 指向 C2/C3 且步骤 2 墙能松动）→ **不做步骤 3**，回步骤 2 方向继续调优，本任务书结束。

### 3.1 对照设计（勿重蹈老集群误判）

CephFS 在此是**"根因是否 = FUSE 用户态方案"的判定对照**，不是"换栈动作"：
- **必须 256K 对齐 + 不限速 100GbE + 同规格 fio + 冷态隔离**，与 JuiceFS 不限速真值同口径。
  （老集群 CephFS 数据是 4K 小块 + 限速小样本，趋势可信、绝对值不可搬，见 `perf-analysis/06_3` + `results-table §14`；勿重复该误判。）
- **同后端**：CephFS 用**同一 Ceph 集群**，建 CephFS 卷。**EC4+2 池 + 副本池两版都测**（隔离 EC overwrite RMW 影响——CephFS + EC 写会触发 RMW，老集群写崩 13.8）。
- 挂载：`mount -t ceph`（内核态，天然单挂载点、无 FUSE 用户态税、能吃多核）。
- fio 口径：randread（S0 128×128 + D2 128 两点）、randrw（**验收档 128 = D2**）、seqread/mseqread（对照 default 预读主场）。REPEAT=3、§8.3 聚合、每 job bw.log 全留。
- 全程采：客户端 CPU（内核态 ceph 无单一用户进程，采整机 CPU + `ceph` 内核线程）、NIC RX、后端 OSD iostat/sar。

### 3.2 判读（写进 summary，回到"定位"而非"换栈"）

| CephFS vs JuiceFS（同后端、同口径） | 判定 | 含义 |
|----|----|----|
| CephFS randread/randrw **显著 > 2404（JuiceFS ra0 单进程封顶）且逼近后端裸 ~4300**、写不崩 | **反证：根因确是 FUSE 用户态方案**（C1 坐实） | 此时才谈"JuiceFS 方案在单挂载点场景有架构上限"，换栈评估**才成立** |
| CephFS 与 JuiceFS **相近（都 ~2404 量级，或都被后端 ~4300 卡住）** | **证明：瓶颈在后端 EC4+2 / 网络，与 FUSE 无关** | 换栈无益，**回头攻后端**（EC→副本、OSD NVMe、TiKV 元数据）。**⚠️ 新基线下这是最可能落点**——后端裸 4300 本身 < 6250 验收线，CephFS 也顶不动后端上限 |
| CephFS + EC 写触发 RMW 崩 / 副本池才正常 | EC overwrite 是 CephFS 短板 | 记录，作为方案对比的一项事实 |

> **新基线提醒**：后端随机读裸能力 ~4300 已是 JuiceFS ra0（2404）的 1.79×，也就是说 CephFS 就算完全无 FUSE 税，
> 最多也只能追到后端的 ~4300，**仍达不到 6250 验收线**。所以 CephFS 对照的真正价值是**切分"客户端损耗 vs 后端上限"**，
> 而非指望它达标。达标的关键更可能在后端 EC4+2 优化。

> **给判定与建议，不擅自落地换栈。是否换栈由用户拍板。**

---

## 四、落盘

一次任务所有数据放**同一** results 目录，多项建**子目录**：
```
results/prod-nolimit-rootcause-cephfs-<YYYYMMDD-HHMMSS>/
├── env-snapshot.txt              # HEALTH_OK + 6/6 OSD 双网 + 无 tc + juicefs version + pprof agent 状态 + WekaIO 未受影响佐证
├── commands.sh
├── step1-pprof/                  # cpu.prof + top/list 输出 + 火焰图 svg + goroutine/mutex/block profile + C1/C2/C3 判读
├── step2-param-probe/            # （若做）针对性参数点 fio + jfs-stats + CPU，墙是否松动
├── step3-cephfs/                 # （若门槛满足才有）ec/ 与 replica/ 两版 × randread/randrw/seqread + bw.log + osd iostat
│   ├── ec-4-2/
│   └── replica/
└── summary.md                    # 根因判定(C1/C2/C3) + 步骤2墙是否松动 + (若做)CephFS 对照判定 + 决策建议
```

**输出分析报告（强制）**：完成后建 `doc/perf-report/01-4-rootcause-cephfs-report.md`（编号对应本任务书），
头部标明对应任务书 / 结果路径 / 执行审阅方 / 判定；正文含目的、pprof 根因定位、步骤2结论、（若做）CephFS 对照、可信度校验、后续动作。
**报告主结论必须是"根因定位到 C1/C2/C3 的哪一类 + 有无调优可能"，CephFS 结论作为对照佐证，不得写成"建议换栈"式动作结论**（换栈由用户拍板）。

不写 perf-analysis/（只放计划文档）；实测追加 `doc/deploy-log/results-table.md`。

---

## 五、开跑前 checklist

- [ ] env-snapshot **完整**：HEALTH_OK + 6/6 OSD up/in + 双网 + 无 tc + juicefs version + pprof agent(:6060) 是否开启
- [ ] **步骤 1 先做**：pprof 下载/重采 → top/list/火焰图 + goroutine/mutex/block → 判 C1/C2/C3
- [ ] 步骤 2 **只按 pprof 指向试 1-2 个旋钮**，不盲扫（老集群已证 buffer/prefetch/readahead 对随机读无效，勿重复）
- [ ] 步骤 3 **门槛满足才做**；CephFS 用 **256K 对齐 + 不限速 + EC 与副本池两版**，勿用 4K/限速（勿重蹈老集群误判）
- [ ] CephFS 挂载前确认 **157 WekaIO 不受影响**；BeeGFS 与本测试**错峰**用盘
- [ ] randrw 对照并发 = **128（D2，验收口径）**；每轮 drop_caches；每 job bw.log 全留 + §8.3 聚合
- [ ] 结论以**根因定位**为主，换栈**只给判定不落地**

---

## 六、完成后交接

- 分析报告 `doc/perf-report/01-4-rootcause-cephfs-report.md`（主结论=根因 C1/C2/C3 + 有无调优可能）。
- 回填 `perf-analysis/01` §5.3.4a/§5.3.5a 状态列 + §七决策链落点（把"封顶"细化为根因层结论）。
- 若根因=C2/C3 且步骤 2 墙能松动 → 新开客户端调优任务书继续攻，**不进 CephFS**。
- 若根因=C1 且 CephFS 对照完成 → 把"是否换栈"作为待用户拍板项，附 CephFS vs JuiceFS 同口径数据。
