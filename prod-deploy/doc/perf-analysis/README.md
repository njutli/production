# 新集群性能分析（prod-deploy）

> 承接老集群 `demo/production/doc/perf-analysis/`（01~12 阶段，单千兆环境）。
> 新集群：150-152（各 2× NVMe SSD OSD，DB/WAL on tmpfs）+ 157 client（JuiceFS FUSE），
> 双 100GbE（public 10.3.1 / cluster 10.3.2）。目标：**不限速 100GbE 下有效带宽 ≥ 网卡 50%**。
>
> 与老集群的关键差异：新集群是真 NVMe SSD + 双 100GbE + EC 4+2 failure-domain=osd，
> 老集群是单千兆 + PERC RAID SSD。老集群的调优结论（尤其 `--max-readahead 0`）是本目录的起点，
> 但**必须在新集群不限速口径下重新验证**，不能直接照搬绝对值。

## 文档

> 约定：**一个阶段 = 一篇文档**（现状分析 + 对比 + 后续计划都写在同一篇里），编号递增，不拆子文档。

| 文件 | 内容 |
|------|------|
| `01-baseline-review-and-nolimit-plan.md` | 阶段 01：集群现状 + GLM 4 组冷态基线数据可信度复核（缓存/测量偏差订正）+ 新旧集群对比 + 放弃限速测试决策 + 不限速调优计划 |
| `02-backend-raw-cap-and-juicefs-tuning-plan.md` | 阶段 02：01 阶段总结（三层瓶颈分解）+ 后端裸能力提升（A 线：cluster_network 修复 + cephx 关闭 + BlueStore 调优）+ JuiceFS 层级调优（B 线：FUSE dispatch 延迟削减 + 内部参数 + 多实例复测 + kernel mount 评估）|
| `03-juicefs-parameter-tuning-execution-plan.md` | 阶段 03：参数调优执行计划（T1 OSD 在线旋钮 / T2 挂载参数 / T3 对象数预算 / T4 重铺类）+ 判据体系 + 发现 F1--F79。**阶段已收口**，最终结论见 `doc/perf-report/03-JUICEFS-PERFORMANCE-TUNING-FINAL-REPORT-20260828.md` |
| `04-metadata-architecture-and-layout-plan.md` | 阶段 04：元数据架构与集群布局。U 线（交付基座版本锁定）/ A 线（`+25%--30%` 归因闭合）/ R 线（读侧均衡 PG，**唯一达标型实验**）/ M 线（写侧事务架构，不承诺达标） |

## 决策速查

- **新集群不再做限速测试**：限速唯一目的（对比老集群千兆绝对值）已完成，后续 JuiceFS 调优 + BeeGFS 基线均转不限速 100GbE 口径。
- **数据判读红线**（继承老集群 + 本轮新增；⚑ 2026-08-28 按 03 阶段复盘订正）：
  - ⚑ **主口径已升级**：有 per-job bw log 时，一律用**实际 timed-I/O 起点 + 重叠加权重采样 + 正式窗 + W1--W4 + CV**（见 `skills/EVIDENCE-INTEGRITY-SKILL.md` §1）。~~达标值 = fio bw_log 稳态中位数（截开头 1/4）~~ 降级为**无 per-job log 时的退化口径**。⛔ 一律不认 fio 平均/summary 作主口径。
  - 限速读类聚合上限 = 3×118 = 354（TBF 只在 3 服务端，客户端不限速），单链 118 不是天花板。
  - ⚑ **randrw 必须 R/W 分向报告、分别对验收线**（读=入向、写=出向，全双工独立）。~~randrw 高 iodepth×numjobs 下 R/W 分列是 fio 队列测量偏差，仅看合计~~ —— 该说法已作废，03 阶段起禁止把两向相加后与单向目标比较。
- **老集群核心遗产**：`--max-readahead 0` 消除随机读 ~2× 预读放大，老集群 randread 55.7→112.2、randrw 48.6→76.1 双双达标（`doc/perf-analysis/12` §12.1）。
- **01 阶段三层瓶颈分解**（01-5 最终版）：① 磁盘非瓶颈（BeeGFS 9045 实测）；② Ceph OSD EC 软件栈是瓶颈（CephFS+EC 4608 < 6250），Rep 非瓶颈（CephFS+Rep 6718 ✅）；③ FUSE 是 JuiceFS 主瓶颈（ceph-fuse 单变量 -42%）。
- **02 阶段两条主线**：A 线 = 后端裸能力提升（cephx_sign_messages=false 是最大可消除项，40-100μs/op）；B 线 = JuiceFS 层级调优（FUSE dispatch 延迟 5+ms/op 是根因）。
