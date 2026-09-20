# 06-2 randrw whole-inode flush 调查报告

> 日期：2026-09-16  
> RUN：`20260916-091446`  
> 状态：`COMPLETED / GATE2B_INVALID / EVIDENCE_INVALID / NO_DECISION / PHASE_B_NOT_TRIGGERED`  
> 构建性质：`INVESTIGATION_BUILD / NOT_FOR_PRODUCTION`
> 审计订正：2026-09-16 根据 Gate 2B 权威产物与 Phase A 原始流独立复算；原始证据不改写，
> Gate 2B 由 `PASS` 回溯为 `GATE_INVALID`，range-scoped 实现的授权链失效。

## 一、结论

06-2 已完成源码溯源、动态归因、range-scoped flush 实现、语义回归和一次四格 ABBA 环境验证，
但**没有得到可登记或可交付的性能优化**：

1. patched 两格观测到每次 flush 的平均 chunk 数由 baseline 的约 `1.87` 降至 `1.00`；但依赖边、
   闭包深度、额外依赖 chunk 与依赖等待计数全部为零，只能确认 scope 被限制为当前 chunk，**不能确认
   跨 chunk 依赖闭包被正确遵守**。
2. 机制未同向改善：每次 read 的平均 flush wait 由 baseline 的约 `34.7/37.2 ms` 增至
   patched 的约 `52.0/50.9 ms`。范围变小没有转化成等待时间下降。
3. Phase A 未通过证据门：T1/T2/C2 的正式窗分别只有 `158/153/77` 秒满足 128 job
   全覆盖，fio runtime 分别达到 `183.304/182.346/196.165 s`，超出冻结合同；因此不能计算
   正式效应量、`ε` 与 `M`。
4. Gate 2B 的墙钟并集 `F=0.999990` 在高并发下构造性趋近1，并发请求等待和 `F=0.8964` 也不是
   Amdahl 所需的串行关键路径占比；该门事后判定无效。instrumentation 自身带宽开销约 `23%`，
   已超过沿用的材料阈值 `14.64%`。
5. fio 汇总仅作工程观察，两组位置配对 READ/WRITE 都为负（约 `-30.7%` 与 `-7.8%~-8.0%`），
   且机制证据未改善，故 **Phase B 不触发**，不继续 U150/U300，也不追加“漂亮样本”。
6. 四格期间 Ceph 对象数由 `4,671,724` 增至 `5,725,452`。本轮按批准后的安全口径不对共享卷
   执行 `juicefs gc --compact --delete`，状态累计与长尾同步出现；二者相关但本报告不把它写成
   已证因果。即使获得状态重置授权，在修正 Gate 2B、观测扰动与依赖闭包证据前重跑也没有价值。

因此，M1 仍是有源码依据的合理嫌疑，但本次结果只能写成：**scope 被限制为当前 chunk 已观测，
Gate 2B 无判定力、依赖闭包未获正面证据、性能效应未闭合；当前补丁不是生产候选。**

## 二、前置门结果

| 门 | 结果 | 关键证据 |
|---|---|---|
| Gate 1 源码与构建溯源 | PASS | 官方 v1.4.1 `0b90c7d` + B-catchup；冻结工具链；P0 NEW→OLD→NEW 通过 |
| Gate 2A 零行为粗筛 | PASS | 35/36 dump 出现 read→flush；runtime trace 有材料阻塞信号 |
| Gate 2B 对称 instrumentation | **GATE_INVALID（事后审计）** | 预注册 wall-union `F=0.999990`、产物 `Gmax=100196.02`；request-weighted附带值`F=0.8964/Gmax=8.65`；两种口径都不能换算串行关键路径收益 |
| Gate 3 语义回归 | `QUALIFIED_GATE3_PASS` | 真实 FUSE R1--R8、R5/R6 延时、填充卷只读 fsck、零残留均通过 |
| Phase A 四格执行 | raw lifecycle PASS | 四格 fio rc=0、排空/无缓存读回/私有挂载清理/健康门通过 |
| Phase A 正式效应 | **EVIDENCE_INVALID** | T1/T2/C2 带宽日志覆盖与 runtime 合同失败 |

Gate 3 不是原任务书意义上的“R1--R10 全通过”：冻结 Go 1.26 下 baseline/patched 的
`pkg/chunk` 均受既有 mockey/runtime 链接兼容问题阻断，`pkg/meta` 全量套件依赖当前 WSL
不存在的外部后端。两臂对称失败，且 157 隔离临时卷已补齐真实 FUSE 主语义，但最终口径必须保留
`QUALIFIED_GATE3_PASS`，不得改写为完整通过。

### 2.1 Gate 2B为何无效

权威 `amdahl.tsv` 与 `gate2b-analysis.json` 明确把 deduplicated wall-union `F` 声明为决策指标：

- `f_dedup=0.999990020`、`Gmax=100196.0199`。128 jobs×iodepth128下，任一时刻几乎总有请求处于
  flush，墙钟区间并集自然覆盖整个160秒正式窗；该量会构造性趋近1，与flush是否限制吞吐无关。
- 附带的 request-weighted `F=0.896414746` 是并发请求等待时间之和，不是墙钟串行关键路径占比；
  不能直接套 Amdahl 公式得到 `Gmax=8.65`。
- 无仪表 baseline 到 instrumentation 的 READ/WRITE 由`1007.66/1009.83`降到
  `775.87/777.76 MiB/s`，开销分别为`-23.00%/-22.98%`，大于沿用的`M=14.64%`。

因此，本次实现补丁的准入依据事后失效；这不证明 M1 不是瓶颈，只说明当前门不能回答它是否值得改。

### 2.2 跨RUN、跨构建基线损失与观测器开销分离

以下三级对照的主机、缓存盘、挂载参数和fio合同相同，但06-1与06-2 baseline**不是相同二进制**：
06-1使用历史交付件MD5 `24fae0852051c80ca571cb2f20275d46`；06-2 Gate 2B baseline是同源代码
重新构建的调查件MD5 `1eb79575f654c77c14aa212c2b6c478d`，身份文件明确记录
`same_as_historical_binary=NO`。因此第一段差异必须同时包含跨RUN和跨构建因素。

| 时点 | 构建身份 | READ MiB/s | 相对前项 | 归属 |
|---|---|---:|---:|---|
| 06-1 T1（09-15） | 历史交付v1.4.1+B-catchup，无仪表，MD5 `24fae085…` | 2090.92 | — | — |
| 06-2 Gate 2B baseline（09-16） | 同源代码重新构建、无仪表，MD5 `1eb79575…` | 1007.66 | `-51.8%` | **跨RUN、跨构建基线损失，成因未定** |
| 06-2 Gate 2B instrumented（09-16） | Gate2B观测构建，MD5 `be67049f…` | 775.87 | `-23.0%` | 同RUN观测器开销 |
| 06-2 Phase A C1（09-16） | 同观测源码的配对baseline，MD5 `25d85813…` | 786.86 | 与上一项数值一致 | 独立构建验证量级 |

存在两个可分离但性质不同的损失：`-51.8%` 是跨RUN、跨构建基线损失，可能混合二进制/工具链、
对象和元数据状态、缓存/页缓存状态及其它运行差异，⛔ 不得纯归因“环境”；`-23.0%` 才是同RUN
baseline→instrumented可归因的观测器开销。前者大于后者，因此06-2 Phase A绝对带宽既不能直接与
06-1比较，也不能只用仪表化解释。

## 三、Phase A 合同与有效性

| 项 | 冻结配置 |
|---|---|
| 顺序 | `C1(instrumentation baseline) → T1(range patched) → T2(range patched) → C2(baseline)` |
| 唯一变量 | JuiceFS 调查二进制；两臂 instrumentation 完全对称 |
| 公共配置 | FUSE256K、buffer300、max-uploads150、max-downloads200、96 GiB cache、writeback |
| fio | randrw 50/50、256 KiB、128 jobs×iodepth128、预热60秒、正式180秒 |
| 主窗口 | 实际 I/O 起点后的 `[15,175)`，128 job 重叠加权 |
| 状态控制 | scrub/deep-scrub 暂停后精确恢复；不执行共享卷 GC；逐格被动稳定等待 |

| Cell | 二进制 | fio rc | 全 job 完整秒 | runtime | 证据状态 |
|---|---|---:|---:|---:|---|
| C1 | baseline | 0 | 160/160 | 180.721 s | PASS |
| T1 | patched | 0 | 158/160 | 183.304 s | FAIL |
| T2 | patched | 0 | 153/160 | 182.346 s | FAIL |
| C2 | baseline | 0 | 77/160 | 196.165 s | FAIL |

采样器本身不是缺口来源：四格 metrics/df/meminfo/NIC 分别有 `223/227/225/242` 个样本，
最大间隔均约 `0.82 s`，四格 sampler rc=0。失效来自 fio per-job 带宽流不能覆盖冻结正式窗，
不能用应用汇总值或删秒代替。

本 RUN 的正式 `ε` 与 `M` 均因证据失效而不可计算。若只用无效样本作漂移诊断，C1↔C2 相差
约`21.95%`，对应描述性`M≈43.90%`；这说明同RUN基线明显漂移，但⛔ 不得登记为正式门。Gate 2B
从06-1跨任务导入的`ε=7.32%/M=14.64%`也不能替代本RUN的噪声评估。

## 四、描述性带宽（不进入正式效应量）

| Cell | READ MiB/s | WRITE MiB/s | READ 位置对照 | WRITE 位置对照 |
|---|---:|---:|---:|---:|
| C1 baseline | 786.86 | 788.85 | — | — |
| T1 patched | 545.11 | 546.89 | `-30.72%`（T1/C1） | `-30.67%` |
| T2 patched | 566.06 | 567.70 | `-7.83%`（T2/C2） | `-8.03%` |
| C2 baseline | 614.12 | 617.30 | — | — |

上述数据来自 fio summary，只说明本 RUN 没有出现正向工程信号；因正式窗合同失败，⛔ 不得将其写成
有效回归幅度或生产性能结论。

## 五、机制结果

| Cell | flush chunks/次 | flush slices/次 | 额外依赖 chunk/次 | flush wait/read | uploading mean/p95/max |
|---|---:|---:|---:|---:|---:|
| C1 baseline | 1.866 | 1.990 | 0 | 34.71 ms | 8.68 / 33 / 150 |
| T1 patched | 1.000 | 1.544 | 0 | 52.04 ms | 3.79 / 13 / 26 |
| T2 patched | 1.000 | 1.560 | 0 | 50.92 ms | 6.01 / 16 / 150 |
| C2 baseline | 1.871 | 1.995 | 0 | 37.20 ms | 4.64 / 18 / 37 |

补丁把观测 scope 缩小约 `46.4%`，但 baseline 在当前 B256+writeback 工作集下本来平均也只有约
`1.87` 个 chunk，而不是理论上的 16 个活跃 chunk；可消除的实际范围小于最初静态上界。更重要的是，
patched 的 flush wait/read 上升约 `37%~50%`，未满足“范围和等待同时材料下降”的机制门。

补丁两格的 flush duration 直方图在`2.56 ms～81.92 ms`连续五档严格为零，约`40.4%/42.1%`
事件集中到`(81.92,163.84] ms`单档；这是约100 ms定时轮询/固定等待的强指纹，但尚需代码级追踪才能
确认为根因。与此同时，四格依赖边、闭包深度、额外依赖chunk与依赖等待均为零；可能是闭包未实现，
也可能是计数器未接线。两种情况都意味着当前 Gate 3 没有正面证明跨chunk依赖闭包正确。

对象层也没有显示被释放的共享请求预算：patched 两格 GET/PUT 请求率和 uploading 均低于相邻
baseline，方向与应用带宽下降一致。由于前台 writeback、对象回收和轮内状态变化交织，本报告不把
该现象进一步归因于某个单一对象层瓶颈。

## 六、状态累计与不重跑理由

| 时点 | Ceph objects | data bytes |
|---|---:|---:|
| Phase A start | 4,671,724 | 1,224,698,493,371 |
| after C1 | 5,160,308 | 1,352,777,857,467 |
| after T1 | 5,333,203 | 1,398,101,244,347 |
| after T2 | 5,424,775 | 1,422,106,294,715 |
| after C2/final | 5,725,452 | 1,500,926,966,203 |

JuiceFS 覆盖写会产生新的不可变对象，旧对象回收并非原地覆盖；在不主动 GC 的口径下，四格间对象与
数据量显著累计。它与 fio 长尾恶化同时发生，破坏了 ABBA 的稳定起点，但本报告不把相关性写成因果。

不重跑的首要理由依次是：①Gate 2B 的两种 `F` 都不能表示串行关键路径，准入门无效；②观测器开销
约23%，已大于材料阈值；③补丁出现疑似定时轮询且依赖闭包没有正面证据。对象累计、基线漂移和 fio
覆盖失效是额外理由。仅更换私有卷或执行 GC，仍无法修复前三项。

如未来必须重新回答该源码优化的精确效应，须先重写关键路径判据、把观测开销降到材料阈值以下、
闭合依赖语义，再批准并冻结可重复状态重置方案（或使用可恢复私有卷），最后以全新RUN重跑完整ABBA；
不得复用本RUN性能样本。

## 七、安全与生命周期闭环

- 未 format/layout/destroy 共享卷，未修改 pool/PG/CRUSH/TiKV/OSD 配置，未执行 drop_caches。
- 未触碰既有 `/mnt/juicefs` 挂载；只使用 `/tmp/jfs-06-2-...` 私有挂载和精确 RUN 缓存目录。
- 四格均先严格排空再优雅卸载，排空用时 `2/1/1/1 s`，无 fio/私有挂载/缓存目录残留。
- scrub/deep-scrub 已按原状态恢复；Phase A 结束时 Ceph `HEALTH_OK`、6/6 OSD up/in。
- 调查二进制没有替换生产二进制；正式结论为 `NOT_FOR_PRODUCTION`。
- 持久证据复核后，157 上精确 RUN 根 `/tmp/production/opencode-06-2-20260916-091446` 已删除，
  baseline/patched 调查二进制和隔离语义卷随该根一并移除；不可从环境误用。
- 完整原始包已持久化，SHA256：
  `181b7be91b19de794661c8999aebe8f5df6f682e05bafee39bc44e556ded2fb9`。

## 八、裁决

| 项 | 裁决 |
|---|---|
| Gate 2B | `GATE_INVALID`（事后审计；不得据此授权行为补丁） |
| Phase A | `EVIDENCE_INVALID / NO_DECISION` |
| range-scoped flush 候选 | `NO_CANDIDATE` |
| Phase B U150/U300 | `NOT_TRIGGERED` |
| 生产交付 | `NOT_FOR_PRODUCTION` |
| 后续 | 当前停止 06-2；仅在有可重复状态重置/私有卷方案时考虑新 RUN |

本报告不主张 M1 已被证明为 randrw 主因，也不主张补丁语义已由全量上游测试证明；它只确认：
**whole-inode flush 是可测嫌疑，当前 chunk scope 已缩小，但依赖闭包正确性未闭合；当前准入门无效、
观测器扰动过大，也没有形成可用的等待或带宽收益。**

## 九、权威证据

- 持久根：`/mnt/c/SunRise/test/06-2/20260916-091446/`
- 原始包：`phase-a/06-2-phase-a-r2-raw.tar.zst`
- 聚合结果：`phase-a/phase-a-analysis.json`
- Gate 3：`build/gate3/`
- Gate 2B：`profile/gate2b/`
- Luna 独立复核：`phase-a/06-2-phase-a-luna-independent-result-review.md`
