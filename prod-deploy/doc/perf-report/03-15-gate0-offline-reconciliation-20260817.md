# 03-15 Gate 0：阶段 03 离线对账、证据收敛与上机入口冻结

> 日期：2026-08-17  
> 性质：零机器时间；未连接或改动 157/150-152，未运行性能测试  
> 输入：03-12/03-13/03-14 原始包、03-11 goroutine dump、Opus 对账、DeepSeek 复核、仓库脚本与报告  
> 下一任务：`doc/perf-tasks/03-16-glm-n1n2-read-boundary.md`

---

## 一、结论先行

1. **现阶段能签字的表述是“单挂载存在读写共享约束”，不能提前写死为固定 4.1 GiB/s 的 librados/objecter/整机硬顶。** 03-14 的分项反相关和多数稳态混比下合计守恒很强；但高写占比窗口可到 4573–4715 MiB/s，且历史 N4=5013 MiB/s 已越过 4.1 GiB/s。
2. **F46 仍不能证明 randrw 有可交付的双挂载解。** 业务目标是单测试项每个方向各 `>=6250 MiB/s`，且当前业务使用单挂载。把 P 读与 Q 写分到两个挂载后求和，只能当架构控制，不能当 randrw 验收值。
3. **下一次上机只做 Phase R：N1/N2 单/双挂载读边界。** 它先回答约束是 per-mount/per-process 还是 host/shared。任何写臂都会改变对象、meta、buffer 和 LSM 状态，应等本轮只读数据回传并分析后另发 Phase X。
4. **不再先补 T2、TiKV 或 max-downloads。** 这些都依赖边界归属，提前混跑只会增加实例档位和环境态混杂。
5. Gate 0 的已知脚本缺陷已在仓库修复并通过离线语法/静态校验；新 wrapper 尚未在 157 执行，线上行为必须由 03-16 的 preflight 和原始证据验证。

因此，不需要再与 Opus 做一轮文字讨论；剩余分歧已经变成可验证的实验问题。Opus 提议的 X64/X64-ref 保留为 **Phase X 候选**，不进入本轮 Phase R。

## 二、关键事实的统一口径

### 2.1 03-14：共享约束成立，但“固定字节硬顶”不成立

- 旧报告把 `juicefs_used_buffer_size_bytes` 峰值写成 8 MiB；原始 I1 证明真正峰值是 **590.4 MiB（t=2s）**，8 MiB 是 fio 结束后 `t>=190s` 的空载地板。旧表述撤回。
- 缓冲净变化对 180s 平均带宽的修正很小（Opus 重算上界约 0.4%），所以不能反向声称“4152 全是缓冲假象”。正确做法是同时保留 buffer 轨迹和稳态分窗。
- 缓冲平稳后、写占比 10%–50% 的分档合计约 **4038–4198 MiB/s**；读写配比大幅变化而合计较稳，支持同一挂载内存在共享约束。
- 写占比大于 50% 的 28 秒合计达到 **4573–4715 MiB/s**，说明共享成本不是固定的“每字节等价”硬顶；不能据此推导 write byte 比 read byte 更便宜，因为这段同时处于 buffer 超限/异步排空状态，缺少 durable PUT 完成量。
- 该实验对象数 **7.05M -> 7.66M**，远超有效性闸门 3.11M，写侧处在 F45 中间态。它能证明共享性，不能用来签健康态下的绝对写容量。

统一命名：**F46 = 单挂载内读写共享容量约束（层级和绝对容量待 N1/N2；健康态写配比待 Phase X）。**

### 2.2 历史 N4=5013 是强反证，但不是当前签收证据

01-3 在旧基座（128K、ra0、不同版本/环境）测得：N1=2350、N2=3865、N4=5013 MiB/s。N4 比 4.1 GiB/s 高约 19%，同为 128 有效并发时，多进程也高于当前单进程 j128。

这直接反对“整机在任何条件下固定封顶 4.1 GiB/s”，并把主嫌疑推向 per-process/per-mount；但它不能直接替代当前 256K+flushfix 基座的受控证据，因为版本、档位、数据布局和环境状态不同。03-16 用两对同会话好档挂载重新签这一刀。

### 2.3 03-11 goroutine 离线对比：排队随并发增大，仍未点名具体内部队列

分析命令：

```bash
python3 scripts/FULLBASELINE/analyze/goroutine-stack-count.py \
  pprof-goroutine-T41B-j64-p{1,2,3}.txt \
  pprof-goroutine-T41B-j128-p{1,2,3}.txt
```

按 goroutine block 计数（类别可重叠）：

| jobs | pass | total | fileReader.waitForIO | dataReader.Read | rados_read | rados_stat |
|---:|---:|---:|---:|---:|---:|---:|
| 64 | 1 | 491 | 61 | 152 | 47 | 28 |
| 64 | 2 | 450 | 61 | 126 | 29 | 34 |
| 64 | 3 | 472 | 62 | 138 | 51 | 17 |
| 128 | 1 | 706 | 127 | 254 | 83 | 44 |
| 128 | 2 | 731 | 127 | 268 | 94 | 40 |
| 128 | 3 | 718 | 127 | 262 | 72 | 59 |

中位数对比：

- 吞吐：j64 4001 -> j128 4073 MiB/s，仅 **+1.8%**。
- `fileReader.waitForIO`：61 -> 127，约 **2.08x**。
- `dataReader.Read`：138 -> 262，约 **1.90x**。
- `rados_read + rados_stat`：75 -> 127，约 **1.69x**。
- goroutine 总数：472 -> 718，约 **1.52x**。

这证明新增并发主要变成等待/在飞请求，而不是转成吞吐；也否定“固定 94 个 rados_read semaphore”这种过度点名，因为三个 j128 pass 的 read/stat 构成会变化。debug=2 dump 看不到 librados 内部 objecter/messenger 队列长度，故结论停在“请求在 file/data reader 到 rados 同步调用链上堆积”，不能再往下命名。

### 2.4 F48、F49 与对象数

- `--max-downloads` 200/512/1024 的 3867/4079/3833 来自单实例单轮且 ns/B 档位不同；三点非单调。结论降为：**200–1024 范围内无可信收益证据**，不是已正式否证。
- 03-12 的 TiKV 服务端逐 op 指标仍未取得，不能把 block cache、region 热点或客户端事务流水线任一项写成根因。
- 对象残留降级为：**强性能状态协变量 + 实验有效性闸门**。它与性能强相关，但现有数据不能切开时间窗、GC/删除、cache/LSM/MVCC 和 remount 等混杂，暂不写“对象数本身是主因”。

## 三、Gate 0 完成项

| 项 | 状态 | 结果 |
|---|---|---|
| 03-12/13/14 原始包本地归档 | 完成 | `results/prod-stage03-raw-20260815/`；三包均记录 bytes、MD5、SHA-256 |
| j64/j128 goroutine 对比 | 完成 | 新增可复现分析器 `goroutine-stack-count.py`；结论见 §2.3 |
| t43 stdout/字符串比较 | 完成 | BW 改走纯数字结果文件，正则校验后 `+0` 数值比较；补全 bw logs、I1、ceph.conf EXIT 恢复 |
| t42 TiKV 采集 | 完成（离线） | TiKV/PD 端点分离；精确 metric；完全去掉 `head`；全量 pre/post gzip；pair/label 校验和 manifest；取消写 preprobe |
| t39 判档实例漂移 | 完成 | 强制 `SKIP_REMOUNT=1`，冻结并逐轮核对 PID+starttime |
| t44 I1/快照/bw logs | 完成 | 统一 I1 键；快照移至候选挂载生效后；保存所有 bw logs |
| instrument I2b | 完成 | 以最后一个 `) ` 切分 `/proc/*/stat`，正确读取 field 14/15，并记录实际采样间隔 |
| latency analyzer | 完成 | write-only 项的 GET/IO 置 NA，消除假 40x 读放大 |
| env snapshot | 完成 | 不再 `head` 截断，记录全部 JuiceFS mount/process |
| N1/N2 专用 wrapper | 完成（离线） | 主挂载身份红线、两对好档 P/Q、不 remount、交错 3 轮、全套原始采集与校验包 |
| GLM 任务书 | 完成 | `03-16-glm-n1n2-read-boundary.md`；GLM 只跑/采/回传，不做统计和分支判断 |

“完成（离线）”只表示代码已实现并通过本机语法/静态测试，不表示在生产环境完成验证。

## 四、原始归档

本地从 `/tmp/opencode/` 复制，未访问远端：

| 文件 | bytes | MD5 |
|---|---:|---|
| `opencode-t3.12-20260815.tar.gz` | 285573 | `270dce2d07be8c8ba3ee90c8ed131f8e` |
| `opencode-t3.13-20260815.tar.gz` | 60747 | `0f7041060409ca093f0d9b5fefa4f687` |
| `opencode-t3.14-20260815.tar.gz` | 104446 | `e8b83b2de006e1b5ef40ab0317c9a54a` |

完整 SHA-256 见 `results/prod-stage03-raw-20260815/MANIFEST.md`。`results/` 受 gitignore 管理，需在工作区/交付介质中保留，不能把“未出现在 git diff”误认为未归档。

## 五、下一次上机：只执行 03-16 Phase R

### 5.1 为什么不把 X64/X64-ref 混进去

Opus 的 X64/X64-ref 能回答“跨挂载读写是否扩展”，信息价值高；但它不是本轮的正确第一步：

1. X64/X64-ref 含写，会立即改变对象数、TiKV/LSM、buffer 和后台 flush 状态，污染尚未取得的纯读边界。
2. “P 只读、Q 只写”不是现有 randrw 单挂载业务语义；即使合计变高，也只能证明架构分片可能性，不能证明 randrw 每向 6250 达标。
3. F44 写侧当前仍只有健康态约 3000 MiB/s，离写向 6250 约 2x；跨挂载不会自动消除 meta 提交率缺口。
4. Phase R 结果可能直接决定 Phase X 的最小矩阵：若双读不扩展，优先 direct-rados 划界；若双读扩展，再用健康池中的 Xref/Xsep 做架构控制才值得。

所以顺序冻结为：**R（只读）-> 回传 -> GPT 分析 -> 再签 X（若有必要）**。

### 5.2 03-16 的产出与分支

- 两个 pair，每个 pair 的 P/Q 都做 2 次 ns/B 判档，之后 PID/starttime 冻结且配置之间不 remount。
- 每 pair 六配置 x 3 交错轮：P64/Q64/C64/P128/Q128/C128。
- 两侧使用互斥的 128 文件数据集；并发 P/Q 各自保存全部 per-job bw logs 和 start-ns。
- 每轮采统一 I1、P/Q CPU/RSS、双 NIC、6 OSD perf、health、对象数、host load/memory；round 2 抓 goroutine。
- 起点/轮内对象数必须 `<=3.11M`；超过即 STOP，GLM 不自行 gc。

分析后分支：

```text
双挂载明显扩展
  -> 约束偏 per-mount/per-process
  -> 另发 Phase X（健康池 Xref/Xsep）；多挂载只作架构诊断

双挂载仍约等于单挂载平台
  -> 约束偏 host/shared path
  -> 另发 direct-rados 并发对照；再决定 T2 是否有机制依据

中间扩展或两 pair 不一致
  -> 不二元落锤；按 CPU/NIC/OSD/I1/pprof 拆解，并补最小复现
```

无论哪条分支，单测试项/单方向 `6250 MiB/s` 才是验收线；双挂载合计仅决定架构解释和后续路线。

## 六、离线验证记录

- 所有改动 shell：`bash -n` 通过。
- Python 分析器：`python3 -m py_compile` 通过。
- goroutine 六份原始 dump 均记录 MD5，重复运行计数一致。
- 新 03-16 wrapper 未执行任何 mount/fio/sudo；生产环境 preflight、权限、端口发现和 fio 产物完整性由任务书设为硬 STOP。

Gate 0 到此关闭。下一输入应是 GLM 回传的 03-16 原始目录/压缩包，或明确的 STOP 原文；不是人工汇总带宽。
