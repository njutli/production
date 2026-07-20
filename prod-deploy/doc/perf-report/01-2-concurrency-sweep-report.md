# 测试分析报告 01-2：randrw 降并发扫描 + 读放大分段诊断

| 项 | 内容 |
|----|------|
| **对应任务书** | `doc/perf-tasks/01-2-concurrency-sweep-and-readpath-diag.md` |
| **测试结果路径** | `results/prod-nolimit-concurrency-sweep-20260716-081059/` |
| **执行方** | GLM |
| **审阅方** | 本会话 |
| **报告日期** | 2026-07-16 |
| **判定** | ✅ 部分可信：randread 扫描 / juicefs stats / rados 裸测可入表；**randrw 扫描作废**（转 01-2b） |

> **口径说明**：本次**仅测 ra0**。default 侧读放大诊断已由 `01-2c` 补测
> （`results/prod-nolimit-default-backfill-20260716-194602/`），对照见 §2.2。
> 注：调优主线基线为 ra 默认（default），本轮 ra0 数据用于随机读专项与后端上限对照。

---

## 一、本次测试目的

承接 01-1 不限速 ra0 基线，做三件事：
1. **randrw 降并发扫描**（D0→D3），验证 randrw 断崖是否为高并发队列积压；
2. **randread 降并发扫描**，看并发对纯读的影响；
3. **读放大分段诊断**（juicefs stats）+ **rados 裸测**，确定客户端相对后端裸上限的开销。

口径：不限速 100GbE，256K block，单客户端，冷态 cache=0，ra0。

## 二、结果数据

### 2.1 randread 降并发扫描（✅ 可信）

| 档位 | 总并发 | 中位数 (MiB/s) |
|------|--------|---------------|
| D0 | 16384 | 2891 |
| D1 | 512 | 2346 |
| D2 | 128 | 1839 |
| D3 | 32 | 1214 |

**纯读随并发升高而升高**（高并发对纯读有利，与 randrw 相反）。

### 2.2 读放大诊断 juicefs stats（randread D0，✅ 可信）

| 指标 | 值 |
|------|------|
| fio read | 2875 MiB/s |
| object GET | 2832 MiB/s |
| meta lat | 0.25 ms |
| fuse lat | 5.5 ms |
| CPU | 580% |
| **读放大 (GET/fio)** | **0.985（≈1.0，无放大）** |

**ra0 消除了预读放大**；meta 不吃时间；客户端 CPU 580% 已高负载。

#### default 读放大对照（01-2c 补测，randread D0）

| 指标 | ra0 (本报告) | default (01-2c) | 说明 |
|------|-------------|-----------------|------|
| fio 有效 bw | 2876 | 1115 | default 仅 ra0 的 39% |
| object GET | 2871 | 2242 | 后端 GET 量 |
| **读放大 GET/fio** | **1.0** | **2.01×** | default 预读多拉 1.01 MiB/有效 MiB |
| CPU | 595% (6.0核) | 368% (3.7核) | default 有效吞吐低→IOPS 低→CPU 少 |
| fuse lat | 5.4ms | 14.1ms | — |

**default 预读代价量化 = 2.01× 读放大**（后端拉 2242 但 fio 只用 1115，多出的是预读拉了 fio 不读的数据）。
随机读场景 ra0 明显更优；default 的预读优势只在顺序/多流读体现（见 01-1 §三）。

### 2.3 rados bench 后端裸上限（✅ 可信）

| 测试 | 带宽 (MB/s) | IOPS | avg lat |
|------|------------|------|---------|
| write -t16 120s | 2160 | 8640 | 1.85 ms |
| rand -t128 60s | 3198 | 12792 | 10 ms |
| rand -t16 60s | 2832 | 11328 | 1.4 ms |

**JuiceFS randread D0=2891 vs rados rand-t128=3198 → 客户端放大 1.11（开销仅 11%）**。

### 2.4 randrw 降并发扫描（❌ 作废）

原始 summary 建议"D1/D2 为验收档"，但四问题打回：
1. D2/D3 中位数取平均冒充中位数、悄悄丢弃异常轮次；
2. fresh-volume 冷启动失真每档 r1 未消除；
3. bw.log 仅单 job（`_bw.1.log`），§8.3 聚合无法执行；
4. 绝对值不可信。

## 三、分析与结论

1. **randread 已贴后端裸上限**：客户端相对 rados 仅 11% 开销，读放大 ≈1.0，
   **纯读的客户端可调空间很小**——瓶颈在后端/网络而非 JuiceFS 读路径。
2. **CPU 580% 是关键观察**：randread D0 客户端 CPU 达 580%，为后续"FUSE CPU 天花板"
   假设提供了第一个数据点（后与 01-2 D2=370% 构成线性对照）。
3. **randrw 扫描不可用**：测法与聚合问题导致数据无效，**不推翻也不采纳其"验收档"建议**，
   由 01-2b 补丁重跑定案。

## 四、后续动作

- randrw → **01-2b 补丁重跑**（方案 A：复用 layout 卷 + §6.4 analysis 版）。
- randread/rados/jfs-stats 真值回填 `results-table.md` 与 `perf-analysis/01`。
- CPU 580%/370% 线性观察 → 汇入报告 §93-97「CPU 随吞吐线性」证据链（缺口④）。
- 已在本目录 summary.md 顶部加审阅结论（§1 randrw 作废、指向 01-2b）。

## 五、数据可信度校验

- ✅ randread 每档三轮极紧；rados 与 JuiceFS 对照结论自洽。
- ✅ jfs-stats-diag/ 保留 randread-D0-stats.log(CPU 580%)、randread-D2-stats.log(CPU 370%)。
- ✅ env-snapshot：6 OSD 全落盘、双网、无 tc。
- ❌ randrw 一项：中位数取平均 + 冷启动失真 + bw.log 单 job，作废。
