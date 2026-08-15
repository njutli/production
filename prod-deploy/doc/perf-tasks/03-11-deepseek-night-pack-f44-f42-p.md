# 03-11-deepseek：夜间补充包（F44 敏感性 + F42 第二实例 + 坏档率 p 精确化）

> 任务书类型：**三个独立 P 段**（段A F44 需求侧证明；段B2 F42 跨实例稳健性；段C 档位模型参数估计）
> 作者：DeepSeek　｜　日期：2026-08-13　｜　执行方：GLM（夜间长块，03-10 之后接续）
> 母文档：03-8 §十三（F44 候选：meta 提交率 ~12K/s）、03-9 段B（F42 sweep 首实例）、AUTHORING-GUIDE §二.10（档位模型 p≈0.31，CI [0.11,0.59]）
> 🔴 **所有统计量由 DeepSeek 计算，GLM 只出原始数字与原文粘贴**
> 🔴 脚本：`t41-wrapper.sh`（段A/段C）＋ 复用 `t39-segB.sh`（段B2：`OUT=/tmp/opencode-t3.11 LP=T41B RUN_SEGC=0`）

---

## ⚑ 计划线

```
03-8 通过：补丁修复 randwrite（+445%）；F44 候选 = 写侧 meta 提交率 ~12K/s 墙（两臂共享，TiKV 侧未证）
03-9 傍晚：段A -o max_read 分离挂载｜段A2 读写共享性｜段B F42 sweep 首实例（含 pprof）｜段C 负控｜段D TiKV 侦察
03-10 夜间：补丁版 256K 全 7 项基线 × 2 挂载（固化证据集）
              │
★ 03-11（你在这里，03-10 之后）：
  段A（P1，~1.2h）：F44 敏感性——补丁版 randwrite numjobs {32,64,128}
        ⇒ H1 墙绑定：三点全 ~3000 且 meta 率钉 ~12K/s ⇒ meta 管线是制动
        ⇒ H2 并发绑定：随 numjobs 线性缩放 ⇒ 墙另有其因
  段B2（P1，~1.4h）：F42 第二实例 sweep（含 pprof）——跨实例稳健性
  段C（P2，~1.3h）：20 连挂 mseqread 探针 ⇒ p̂ 与 95% CI（现 0.31 [0.11,0.59] 太宽）
        │
  全部只出数据与候选；判定归 DeepSeek
一句话：给 F44 补需求侧敏感性、给 F42 补第二实例、把坏档率 p 的置信区间收窄。
```

---

## 〇、背景

- **F44**（03-8 §十三）：写侧 ~3000 MiB/s = meta 提交率 ~12K/s，已有 03-7L/03-8 两会话证据，但都是"单点 128 并发"的观测。R3/R5 要求灵敏度证明：**改 numjobs 看 meta 率跟不跟**——若 32/64 并发下 meta 率随写率下降（墙不绑定），则"~12K/s 是墙"不成立；若三档全钉在 ~12K/s 且吞吐不动，墙证据成立。此为 F44 从候选转点名的决定性实验。
- **F42**：03-9 段B 是单挂载 sweep。档位模型（p=0.31）要求跨实例稳健性；且 pprof（`net/http/pprof` 已随 metrics 端口起用，实测可访问）每点 goroutine dump + 30s CPU profile 能直接点名饱和 goroutine——比 I2b 线程级更强一层。
- **p 精确化**：全项目每个结论都依赖坏档模型（p=0.31，95%CI [0.11,0.59] 过宽 ⇒ 坏档压力测试与臂数选型都带着大不确定度）。20 连挂探针 ≈ 2.3h 把 p 的 CI 大致收窄一半，是全项目级的基础设施投资。

## 一、目标（全部只报数据与候选，⛔ GLM 不判）

- **段A**：F44 敏感性数据（三档吞吐 + meta 率 + jfsstats）。H1/H2 预登记对账由 DeepSeek 做。
- **段B2**：F42 第二实例的并发曲线 + pprof 证据。
- **段C**：20 个档位样本（ns/B + 探针 BW），DeepSeek 算 p̂ 与 CI。

## 二、口径与矩阵

- 段A：补丁版 `/tmp/juicefs-03-8`（md5 `1f60618c44fda1c19fecd75d52e053e9`，段首复核），`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；randwrite（storage_test 文件，directory 模式）numjobs **{32,64,128} × 1 轮**，`bs=256k iodepth=128 direct=1` 180s。判档 = I1 直连探针 ns/B（不经 V4 省 warmup，`direct_gate`）。⚑ **OBJ_MAX/objwatch HARD=15M（声明）**：池余量 26 TiB，容量无虞；3 点覆盖写净增 ~2.7M。
- 段B2：与 03-9 段B 完全同设计（jobfile 独占子集、锚点 4058±3% 描述、pass 升/降/升、I2b 10s、pprof 每点 + 锚点/j128-p2 CPU profile）；`RUN_SEGC=0`（段C 负控不重复）。
- 段C：stock 128K（`--max-uploads 150 --cache-size 0`，与参照群 n=15 同配置），20 连挂；每挂载 1 轮 mseqread 直连 fio（V4 逐字参数：`directory=mseqread/ bs=256k rw=read refill_buffers size=4G numjobs=16 group_reporting direct=1 ioengine=psync iodepth=1 time_based runtime=180`）＋ I1 采集。**不经 V4**（省 warmup ~8min/挂载）。

## 三、判据（每条指名数据来源）

| # | 判据 | 预登记/值域 | 数据来源 |
|---|---|---|---|
| A1 | F44 敏感性 | **H1 墙绑定**：32/64/128 三档吞吐全 ≈[2800,3400] 且各档 meta 率 ≈11~13K/s ⇒ 墙成立；**H2 并发绑定**：吞吐近似线性（32→~800~1500）且 meta 率随写率缩放 ⇒ 墙不成立 | `s1v3-bw.tsv` 行 T41A-*；meta 率 = 各档 `i1-jfsstats-T41A-*.tsv` Δ`meta_ops_durations_histogram_seconds_total`÷窗口（DeepSeek 算） |
| A2 | 判档门 | I1 ns/B ∈ [2.958, 3.616] | `probe-gate.log` |
| B1 | 段B2 全套 | 同 03-9 §三.2（B1-B5）+ pprof | `s1v3-bw.tsv` 行 T41B-*、`pprof-goroutine-*`、`pprof-cpu-*` |
| C1 | p 样本 | 20 个 ns/B（好档 ≈3.22~3.44，坏档 >3.62）；p̂ = 坏档数/20 | `p-probe.tsv` |
| E | 环境 | 全程 HEALTH_OK、无 SMOKE | `health.txt` |

## 四、执行步骤

**步骤 0**：通读 TESTING-GUIDE §1.3/§2.2/§3、AUTHORING-GUIDE §二.8/§二.10。无 layout/destroy/pool 操作。
1. `md5sum /tmp/juicefs-03-8` 复核；`bash -n` `t41-wrapper.sh`、`t39-segB.sh`。
2. `bash /tmp/t41-wrapper.sh`（段A → 段B2 → 段C 顺序内置；砍单用 `RUN_A=0`/`RUN_B2=0`/`RUN_C=0` 环境开关，改动须声明）。
3. 夜间每小时 `tail progress.txt` + `ceph health`；任何 STOP/OBJ_BREACH ⇒ 停并回报。
4. 收尾归档 `tar czf /tmp/opencode-t3.11-20260814.tar.gz /tmp/opencode-t3.11`。

**末步**：skill 合规自查（同 03-9/03-10 清单），任一不符显式标注。

## 五、交付物（157 `/tmp/opencode-t3.11/`）

1. `s1v3-bw.tsv` 全文（段A 3 行 + 段B2 锚点/15 sweep 行）
2. `p-probe.tsv` 全文（20 行：rc + nsB + verdict + probe_bw）
3. `probe-gate.log`、`remount-retry.log`、`instances.txt`、`arm-verify.txt` 全文
4. `pprof-goroutine-*.txt` 与 `pprof-cpu-*.pprof` 文件清单与大小（不粘全文）
5. 段A 各档 `i1-jfsstats-T41A-*.tsv` 行数；段B2 的 i2-threads 行数
6. `health.txt`、`wrapper.log`、`progress.txt` 全文；`objwatch-T41A*.tsv` 峰值
7. 异常与偏差逐条

## 六、风险与红线

1. 段A 对象上限 15M（声明）；BREACH ⇒ 停。⛔ 不得再上调。
2. 段C 的 ns/B 用 I1 直连窗（非 V4 pre/post）——口径差异在报告注明；参照 3.287 ±10% 阈值不变。
3. ⛔ 全程不碰 `/usr/local/bin/juicefs`、`/tmp/ray`；无 layout/destroy；157 业务路径禁动。
4. 段B2 若判档门三连败 ⇒ 跳过段B2 继续段C（wrapper 已内置），回报即可。
5. 时钟：157 时间 = WSL − 1h；归档 mtime 偏差照录。

## 七、时间预算

| 段 | 内容 | 预算 |
|---|---|---|
| A | 挂载+判档 + 3 点 randwrite | ~1.2h |
| B2 | 判档 + 锚点 + 15 sweep 点 | ~1.4h |
| C | 20 连挂探针 | ~1.3h |
| **合计** | | **~3.9h**（03-10 后接续，天亮前完成） |

砍单顺序：**段C 的 m11-m20 → 段B2 pass3 → 段A**。⛔ 段A 三点、段B2 锚点+pass1/2、段C 前 10 挂载不可砍。
