---
name: perf-review-planning
description: Use when reviewing/validating performance test results or planning next optimization steps for the JuiceFS+Ceph storage tuning project. Covers the mandatory "verify test method before reading data" discipline, control-variable checks, data traceability/credibility red lines, cold/warm cache 口径 rules, and how to maintain the next-stage plan. Trigger on: 校验测试结果, 检查数据, 测试方法, 控制变量, 下一阶段计划, baseline, fullmatrix, results 复核, 数据可信度, perf review, planning.
---

# 性能测试校验 & 工作规划 skill

负责"复核测试数据 + 规划下一步"的 agent 必读。本项目（JuiceFS+Ceph 单客户端调优）反复因
"只看数值不看方法"踩坑（口径串了、变量失控、结论数对不上原始日志），本 skill 固化教训。

---

## 第一条（最高优先）：先看测试方法，再看数据

**拿到任何一组测试结果，禁止先看带宽数字下结论。必须先逐项核对测试方法：**

1. **实际挂载参数**（最易被忽略，已多次出事）：
   - 不要信 summary 里人写的"口径"描述，**去看 `commands.sh` / mount.log 里真实的 `juicefs mount` 命令**。
   - 逐字确认：`--cache-size`、`--max-readahead`、`--max-uploads`、`--writeback`、`--prefetch`、`--block-size`。
   - 注意隐含联动：`--cache-size 0` 会**连带禁用 writeback 和 prefetch**（日志 `cache-size is 0, writeback and prefetch will be disabled`）。
2. **格式化参数 vs fio 参数是否匹配**：
   - JuiceFS `BlockSize`（format 时定，看 format.log 的 `"BlockSize"`）与 fio `bs` 是否对齐。
   - 不匹配会影响顺序写（如 256K block + bs=4M → 1 个 4M IO 切成 16 个对象 PUT）。
3. **冷/热态口径是否真冷**：cache=0？客户端 drop？**OSD 端 drop 了吗**（客户端清不掉 OSD BlueStore cache）？只认 r1。
4. **fio 是否正常跑完**：worker 是否起来、有无 err、io 量是否合理、是否被 SIGKILL 残留污染（见 10_issue-1）。
5. **集群状态**：`ceph -s` 有无 scrub/recovery/backfill 干扰。

只有方法核对通过，数值才有意义。

## 第二条：控制变量——对比组必须只差一个变量

- 任何"A vs B 对比"前，先列出 A、B 的**全部**挂载/测试参数，确认**只差目标变量**。
- 典型坑（真实发生过）：把 "cache=100G+RA开" 和 "cache=100G+RA关" 当成"暖态的两轮验证"——
  实际差了 readahead，不是同口径验证。
- 多变量同时变的组，**不能用于单因素结论**；要么作废，要么只在恰好单变量差异的子集间比。
- 制定测试计划时，明确写出 2×N 单变量矩阵，杜绝执行方随手改多个参数。

## 第三条：数据可信度红线

- **每个结论数必须能对上原始 fio 文件**（不是 summary 里转写的数）。本项目已 3 次出现"结论数查无实据"
  （85→77.7，真值 38-52）。对账原始 `READ: bw=` / `WRITE: bw=` 行。
- **物理合理性自检**：随机读/写 > 千兆线速（~124 MB/s）必是缓存命中，不能标为后端/冷态能力；
  纯随机写接近 124 要特别存疑（写须落后端）。
- **原始日志丢失 = 该结论不可作基准**（09 基线即因此废弃）。
- writeback 配置的写带宽可能虚高（只落本地未刷后端），须等上传完或写超本地容量再算。

## 第四条：冷/热态口径规则

- **真冷态唯一定义**：`--cache-size 0` + 客户端 drop + **3 台 OSD 都 drop** + 只认 r1。其余不准叫"冷态"。
- 暖态：显式标 `cache=<值>` + 轮次；r2/r3 含 OSD 预热，不是冷态。
- 验收/瓶颈定位用冷态下界；现实/重复访问场景用暖态，**结论必须标口径**。
- 当前验收口径（用户拍板）：**256K block、单客户端、目标 59 MB/s（千兆半速）**，维持不变。

## 第五条：规划纪律

- 不预设任何指标"已达标"——用干净、可追溯、单变量的数据确认。
- 排优先级考虑：真不达标 + 业务必需 + 已承诺 + **依赖关系**（如纯读纯写是 randrw 的地基；
  但 randrw ≠ 纯读+纯写，有读写干扰的额外损耗）。
- 正式计划写入 `doc/perf-analysis/11-next-stage-plan.md`；各模型分析是素材，不是计划。
- 自己负责规划，具体执行（跑测试）交 GLM；给 GLM 的任务要写明方法、控制变量、原始文件留存要求。

## 已知关键事实（避免重复踩坑）

- 放大主因 = EC 4+2 取片（每 256K 读从 4 OSD 取 4 分片）+ messenger 协议帧（strace 139≈4×35），
  **不是 readahead、不是 slice 碎片**。
- 已证伪：FUSE congestion_threshold、元数据强缓存、FUSE splice/max_read（系统不支持）、slice 碎片、
  v1.4、buffer-size 调大（对随机读）、max-uploads（对顺序写）。
- `--max-readahead 0` 救随机读但砸顺序写（−43~70%）；布局必须用默认参数建（防超时）。
- 高并发 fio 偶发起不来 = 前一个 fio 被 SIGKILL 的残留，非系统卡死（10_issue-1）。
- weka 生产真实负载：读 32K 为主、写 4K 为主、75:25 混合、多客户端聚合 ~1067 MB/s
  （与 256K 验收口径不同，作现实参照/plan B 弹药，不改口径）。
