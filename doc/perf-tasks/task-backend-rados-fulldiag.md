# 任务（GLM）：后端 rados 裸能力全量诊断 —— 确定真实上限 + 定位 50 MB/s 是谁的锅

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-07
> 来源：步骤 2 收尾。写侧软件优化已穷尽（mu/buffer/deferred/WAL 隔离均无效，见 `11_1`），
> 现象是"256K + EC 4+2 单客户端稳态写 ~50 MB/s"。**但 Ceph 广泛应用、不应这么慢，强烈怀疑是测量口径（并发不足/块太小/短测暂态）而非后端真实上限。**
> 本任务两件事：**① 严谨测准"当前池的真实后端裸能力"（长测 + 中位数 + 趋势，不只看均值）；② 定位 50 MB/s 到底是"EC 4+2 的锅""256K 小块的锅"还是"并发/口径的锅"——用块大小矩阵 + EC/副本对照池回答。**

---

## 0. 关键背景与假设（GLM 请先读）

### 已知事实（对账过原始数据）
- 集群：client=tikv-node(.12) **单千兆网卡 eno1**（sustained ~118 MB/s 上限）；3×ceph-node 各 2 OSD=6 OSD；**盘 sdb 是物理 SSD 但被 Ceph 误判 hdd**；`bluefs_single_shared_device=1`（WAL/DB/Data 同一块 sdb）。池 `juicefs-data` = **EC 4+2**（k=4 m=2，写放大 1.5）。
- **过去 rados bench 一直是 `-t 16`（16 并发），从未扫过并发**——这是最大嫌疑。
- **256K 写逐秒形态**（`clean-deferred-retest-20260707/A1/rados-bench-r1.txt`）：前 17s 缓冲加速 ~112 → 断崖 → 后段稳态 ~48-53。**均值 68.45 是暂态污染值，稳态才 ~50。**
- **4M 写逐秒形态**（`write-forensics-20260705/exp2-backend-raw/rados-bench-4M.txt`）：前 14s 峰值 100-116（近网卡线速）→ 退化到 40-64，均值 77.9；**avg latency 从 0.46 爬到 0.81s**（16 并发下延迟持续升高）。

### 待验证的假设（本任务要逐个证实/证伪，别预设结论）
- **H1（口径假象）**：50 MB/s 是"单客户端 16 并发喂不饱 6 OSD + 256K 小块 IOPS 受限 + 60s 短测暂态"的综合，**提高并发/延长时间后稳态会明显高于 50**。
- **H2（256K 小块的锅）**：换大块（1M/4M）稳态能过 59，说明瓶颈是小块 IOPS/元数据开销，非带宽。
- **H3（EC 4+2 的锅）**：同口径下副本池(size=3)或更宽 EC 明显快于 EC 4+2，说明 EC 读改写/分片分发是瓶颈 → 这是**存储规格(硬性 EC 4+2)与性能预期的矛盾**，可据此向领导汇报。
- **H4（后端确实到顶）**：任何块大小/EC/并发都过不了 59 → 必须解释为什么（此情形 opencode 认为可能性低，若出现要给出机理，如单 SSD 共享 WAL/DB 落盘 + fsync 放大）。

---

## 1. 铁律
1. **rados bench 直打池，不经 JuiceFS**（本任务测后端裸能力）。从 client(.12) 发起（与生产客户端同位置，含网络路径）。
2. **每个池/每种配置开测前净态**：池对象清零（`rados df` 落盘确认）+ `compact` 全 OSD 到 `compact_queue_len=0`（数字，非空白）+ `iostat` idle + HEALTH_OK。
3. **数据严谨性（本任务核心）**：
   - **长测**：write/randwrite/seqread/randread 每项 **≥300s**（让稳态段主导，压过缓冲暂态）。
   - **逐秒数据必须落盘**（rados bench 默认每秒一行 cur MB/s），报告要给：**均值、中位数、稳态段均值（截掉前 30s 暂态）、min/max、stddev、以及"暂态→稳态"趋势描述**。不允许只报 `Bandwidth (MB/sec)` 单一均值。
   - **每项跑 3 轮**，轮间净态复位；报告给三轮的稳态段中位数。
4. **单变量**：扫并发时固定块大小，扫块大小时固定并发，别混。
5. 有创操作（建/删对照池）**全程 ops.log 落盘 + 测完删除回滚**；集群无业务数据可有创。密码 .11=`TurboAi@303`，.13/.14=`123456`。
6. **一切结论对账逐秒原始数据**；无数据标"未取证"；不取多轮 MAX；不手填 summary。

---

## 2. 实验一：当前池(EC 4+2)真实裸能力 —— 长测 + 并发扫描

### 2A. 并发扫描（验 H1：是不是 16 并发喂不饱）
固定 **256K**，`juicefs-data` 池，rados bench write **300s**，扫并发 `-t`：**16 → 32 → 64 → 128**。
- 每档 3 轮，看稳态段中位数随并发的变化：若从 16→64 明显上升，则 50 是并发不足假象。
- 命令：`rados bench -p juicefs-data 300 write -b 256K -t <N> --no-cleanup`（逐秒输出重定向落盘；测完 `rados -p juicefs-data cleanup`）。

### 2B. 全量四项（用 2A 找到的最优并发，或至少 16 与 64 两档）
在 EC 4+2 池上跑全套，各 ≥300s、3 轮、净态复位：
| 项 | 命令要点 |
|----|----|
| 顺序写 | `rados bench 300 write -b 256K -t <opt> --no-cleanup` |
| 随机写 | rados bench 无原生 randwrite；用 `-b 256K` write 到已 prefill 的池即近似，或注明 rados bench write 本身是并发写不同对象（非严格顺序）|
| 顺序读 | 先 prefill：`rados bench <t> write --no-cleanup`；再 `rados bench 300 seq -t <opt>` |
| 随机读 | `rados bench 300 rand -t <opt>`（参考 `tests/bench-rados-256k-rand.sh`）|
> rados bench 的 write 实际是"16/N 线程并发写不同对象"，本身偏随机；严格"顺序 vs 随机"在 rados 层意义有限，**重点是读 vs 写、块大小、并发、EC vs 副本这几个变量**。四项都跑但报告时说清每项的真实语义。

---

## 3. 实验二：块大小矩阵（验 H2：是不是 256K 小块的锅）

`juicefs-data`（EC 4+2）池，固定最优并发，write + rand(read) 各 ≥120s（大块不必 300s，稳态来得快，但要覆盖退化段），扫块大小：
**4K → 64K → 256K → 1M → 4M**
- 关注：稳态段带宽随块大小的曲线；256K 稳态 vs 4M 稳态差多少（4M 已知峰值 116/稳态 ~77）。
- 若 **1M/4M 稳态过 59 而 256K 不过** → 瓶颈是小块（IOPS/每 op 固定开销），非带宽墙 → 对 JuiceFS 有意义（JuiceFS block-size 可调，但受验收 256K 口径约束，需另议）。

---

## 4. 实验三：EC vs 副本 对照池（验 H3：是不是 EC 4+2 的锅）

**建临时对照池，同口径测，测完删除回滚。** 集群无业务数据，可有创。

| 池 | 配置 | 目的 |
|----|----|----|
| P-rep3 | 副本池 `size=3` | 无 EC 读改写/分片分发；若明显快于 EC 4+2 → EC 是瓶颈 |
| P-ec42 | 复用 `juicefs-data`（EC 4+2）| 基线 |
| P-ec21（可选）| EC k=2 m=1（写放大 1.5 同，但分片少）| 看分片数影响 |
| P-ec82（可选，若空间够）| EC k=8 m=2（写放大 1.25，分片多）| 看更宽 EC |

- 建池示例（落盘每步）：
  - 副本：`ceph osd pool create rep3-test 128 128 replicated; ceph osd pool set rep3-test size 3`
  - EC：`ceph osd erasure-code-profile set ec21 k=2 m=1 crush-failure-domain=host; ceph osd pool create ec21-test 128 128 erasure ec21`
  - ⚠️ EC 4+2 需要 6 个 failure domain 但只有 3 host——现有 `juicefs-data` 能建说明用了 `crush-failure-domain=osd` 或特殊 profile，**建新 EC 池前先 `ceph osd erasure-code-profile get <现有profile>` 抄现有 profile 的 failure-domain 设置**，否则新池 PG 会 inactive。副本/EC2+1 在 3 host 下没问题。
- 每池：256K + 最优并发 + 4M 各一组，≥120s、3 轮、净态。
- **关键判据**：副本池 size=3 的 256K 稳态 vs EC 4+2。若副本明显更高（如 >59），则**结论是"硬性 EC 4+2 规格 与 59 预期矛盾"**——这是给领导的核心弹药。
- **测完务必删除对照池**：`ceph osd pool delete <pool> <pool> --yes-i-really-really-mean-it`（可能需临时 `mon_allow_pool_delete=true`，用完关掉），落盘回滚，确认 `ceph df` 空间释放、HEALTH_OK。

---

## 5. 回报 opencode（最终一条消息）

1. **当前池(EC 4+2)真实裸能力**：256K 各并发的稳态段中位数（16/32/64/128），四项（读/写）的稳态真值。**明确 50 MB/s 是否口径假象**（并发提上去后是多少）。
2. **块大小曲线**：4K→4M 稳态带宽，256K 与大块的差距，H2 成立否。
3. **EC vs 副本**：副本 size=3 是否明显快于 EC 4+2，H3 成立否 → 是否"EC 4+2 规格与 59 预期矛盾"。
4. **总判决**（四选一并给证据）：
   - 存在某配置（并发/块/EC）稳态过 59 → **当前 EC 4+2 + 256K 是规格/口径限制，非 Ceph 能力问题**。
   - 任何配置都过不了 59 → 给出机理（单 SSD 共享 WAL/DB fsync 放大？CPU？），**并说明这与 Ceph 广泛应用是否矛盾、为什么**。
5. 每项都要：均值 / 中位数 / 稳态段均值 / min-max / stddev / 趋势，逐秒数据落盘。
6. 异常（池 inactive、对照池未删、并发起不来）如实列。

## 6. 明确不做
- ❌ 不经 JuiceFS（本任务纯后端 rados）。
- ❌ 不只报单一均值（必须中位数 + 稳态段 + 趋势）。
- ❌ 不用 60s 短测下"稳态"结论（write/read 长测 ≥300s / 大块 ≥120s）。
- ❌ 对照池测完不删（务必删除 + 回滚 + 确认空间释放）。
- ❌ 改验收口径；无数据支撑标"未取证"。

## 7. 产出目录
`results/backend-rados-fulldiag-20260708/`：
```
├── ops.log                         # 全程 + 建/删对照池 + 净态确认
├── exp1-concurrency/  256k-t{16,32,64,128}-r{1,2,3}.txt（逐秒） + summary
├── exp1-fullset/      {write,seq,rand}-r{1,2,3}.txt + summary
├── exp2-blocksize/    {4k,64k,256k,1m,4m}-r{1,2,3}.txt + summary
├── exp3-ec-vs-rep/    rep3/ ec42/ [ec21/ ec82/] 各 256k+4m + summary
└── report.md          # 四问结论 + 每项 均值/中位数/稳态/趋势 表 + 总判决
```
