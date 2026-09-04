# U141d 最终报告：patched JuiceFS v1.4.1 能否替代 patched v1.3.1

日期：2026-08-31

```text
VERDICT=REPLACE_APPROVED
APPROVED_SCOPE=exact patched v1.4.1 + B-catchup binary under the tested cache=0 baseline
STOCK_V141=REJECTED
PERFORMANCE_CLAIM=NO_MATERIAL_REGRESSION_DETECTED; DO_NOT_CLAIM_V141_IS_FASTER
```

## 一、结论

在当前 JuiceFS/Ceph 测试基线、相同数据资产和相同测试条件下，**允许用带 B-catchup 补丁的
v1.4.1 替代带补丁的 v1.3.1**。最终批准对象不是社区原版 v1.4.1，而是精确二进制：

| 臂 | 二进制 | MD5 |
|---|---|---|
| V13（原基座） | `/tmp/juicefs-03-8` | `de93563f11a5ff3bd94dd25a4e0283b1` |
| V14（批准候选） | `/tmp/juicefs-1.4.1-patched` | `24fae0852051c80ca571cb2f20275d46` |

批准理由不是“v1.4.1 更快”，而是：生产最相关的 `randrw` 负向倾向在重新设计的同窗正式矩阵中
收敛到约 `−0.5%`；`randwrite` 为 `−2.08%`；`mseqwrite` 观察值为 `+2.96%`。四个新端点
均未检测到稳定版本方向，且单侧 95% 下界均高于 `−5%`，足以排除超过 5% 的材料性退化。

社区原版、未带 B-catchup 的 v1.4.1 仍维持排除：其 `randwrite=551/552/551 MiB/s`，约为
当前交付基座的五分之一，不能因本报告批准 patched v1.4.1 而重新纳入候选。

## 二、最终数据

### 2.1 U141d 新补证端点

主口径为取数前冻结的二阶轮序趋势模型；正式顺序均为
`V13,V14,V14,V13,V14,V13,V13,V14`，每臂四轮。

| 端点 | V13 均值 MiB/s | V14 均值 MiB/s | V14 效应 | 双侧 95% CI | 单侧 95% 下界 | 结论 |
|---|---:|---:|---:|---:|---:|---|
| randrw.read | 1758.47 | 1749.30 | `−0.52%` | `[−5.52%, +4.48%]` | `−4.36%` | 无可测方向；排除 >5% 退化 |
| randrw.write | 1758.18 | 1749.21 | `−0.51%` | `[−5.49%, +4.47%]` | `−4.33%` | 无可测方向；排除 >5% 退化 |
| randwrite.write | 2492.89 | 2441.08 | `−2.08%` | `[−5.10%, +0.94%]` | `−4.40%` | 无可测方向；排除 >5% 退化 |
| mseqwrite.write | 4791.30 | 4933.11 | `+2.96%` | `[−3.47%, +9.38%]` | `−1.97%` | 点估计偏正；排除 >5% 退化 |

`mseqwrite` 的双侧区间半宽为 `6.42 pp`，按 U141d 的精度标签仍记
`RESOLUTION_INSUFFICIENT`；这表示不能声称“v1.4.1 确认提升约 3%”，不表示发现退化。
其点估计为正，单侧下界又能排除 `−5%`，因此在本次替代决策中不是阻断项。

三种预注册模型对风险方向一致：四端点的主模型、线性敏感性与未去趋势敏感性全部排除
超过 `10%` 的退化；除 randrw 的未去趋势敏感性外，其余也均排除超过 `5%` 的退化。
randrw 的正式结论只按预注册主模型表述，不扩大为“所有统计模型都排除 5%”。

### 2.2 U141b 保留、不重测的端点

U141d 在取数前已明确继承 U141b 的四项证据：

| 端点 | U141b median / mean 版本效应 | 最终使用方式 |
|---|---:|---|
| seqread | `−0.05% / +0.16%` | 已闭合 `NON_INFERIOR` |
| mseqread | `+0.57% / +0.00%` | 两种估计量均接近 0，无材料性退化方向 |
| randread | `+0.58% / −0.10%` | 两种估计量均接近 0，无材料性退化方向 |
| seqwrite | `−0.28% / −0.55%` | 已闭合 `NON_INFERIOR` |

U141b 当时把 mseqread/randread 标成 `RESOLUTION_INSUFFICIENT`，原因是同臂相邻对把 R07/R08
共同约 11% 的主机侧下陷算成了噪声底，导致容忍线膨胀；不是两臂出现了相反性能。用户随后批准
U141d 只复测真正有负向倾向的 randrw/randwrite，并补齐 mseqwrite，因此这两项无需再次重跑。

## 三、为什么 randrw 可以批准

U141b 的 randrw median/mean 结果曾为 `−8.30% / −4.74%`，四对中三对为负，是整个替代判断
最大的风险。该结果同时受单轮 V14 起步异常与趋势/噪声混合判据影响，无法确定真实幅度。

U141d 用四个固定预热轮、八轮二阶平衡矩阵、固定实际 I/O 正式窗重新测量后：

- 读向效应 `−0.52%`；
- 写向效应 `−0.51%`；
- 两个方向的双侧 CI 都跨 0，单侧 95% 下界均高于 `−5%`；
- 读写两向没有再出现 U141b 的持续负向幅度。

因此准确结论是：**先前的明显负向倾向主要是运行起点/轮序波动，不是可复现的 v1.4.1
版本退化。**

## 四、兼容性、有效性与边界

### 4.1 兼容性

P0 的 `V14 → V13 → V14` 三次挂载/卸载均成功。V14 的 Setting 是 V13 的超集，只新增空默认值
`Tiers`；15 个共有字段无差异。可以回滚到 V13，但文档中不得写成“Setting 完全 identical”。

### 4.2 证据有效性

- Phase A RUN `20260830-122350`：4 个预热轮、8 个正式轮、24 个 item 全部有效；closure
  `3650/3650` SHA256 通过。
- Phase B RUN `20260831-233540-bonly`：2 个 canary、8 个正式轮全部有效；closure
  `563/563` SHA256 通过。
- 两个 RUN 使用相同冻结分析器 SHA256
  `45f954ceabae134e9daa48b0ffeb816e85a256da0eb4e6bab320bc9ca38150ee`；GPT 在隔离目录从
  per-job 原始日志重跑，效应量、区间和分类均复现，差异仅为浮点末位与本地路径字段。
- 两阶段的 `noscrub+nodeep-scrub` 独立 lease 均精确恢复；最终 Ceph `HEALTH_OK`、6/6 OSD
  up/in、33 PG active+clean，无 mount/worker/fio 残留。
- Phase B 每轮前回到相同 seed，对象起点均为 `1,978,586`；没有复用此前不完整 Phase B 样本。

### 4.3 批准边界

1. 本结论只批准**带 B-catchup 的精确 v1.4.1 候选**；stock v1.4.1 不得交付。
2. 测试基线为 `--max-fuse-io 256K --max-uploads 150 --cache-size 0` 和客户端私有
   `ms_async_op_threads=8`；不能外推为所有缓存、并发或硬件组合都相同。
3. scrub 暂停是两臂对称的受控 benchmark 条件，因此可用于版本因果判断；本报告不据此承诺
   scrub 开启时的长期绝对带宽或韧性。
4. 04-4 已记录 V14 原构建命令、Go version、binary SHA/BuildID 没有完整保留。部署现有同 MD5
   二进制不受影响；若重新构建，须先闭合 source/patch/toolchain/BuildID/SHA256 可重现性并做 P0
   兼容性 smoke。代码或关键配置变化时，本结论不能直接继承。

## 五、决策与后续

```text
BASELINE_VERSION_LOCK=PATCHED_V141_APPROVED
REQUIRED_PATCH=B-CATCHUP
ROLLBACK_TO_V13=VERIFIED_WITH_EMPTY_TIERS_FIELD_RETAINED
FULL_PERFORMANCE_RETEST=NOT_REQUIRED_FOR_THE_ARCHIVED_EXACT_BINARY
```

04 阶段后续任务应统一使用最终批准的 V14 精确二进制；如果尚未完成可重现构建闭环，则环境执行前
暂时继续使用 V13，不能让“性能批准”替代“制品可重现”。

## 六、持久化证据

证据目录：`results/prod-u141d-final-20260831/`

| 文件 | SHA256 |
|---|---|
| `u141d-run5-phase-a-evidence-20260830.tar.gz` | `150f988c70b61ef65fe5608b740e1370b8cbc86472c08b08db411a64acac1e2b` |
| `u141d-phase-b-only-evidence-20260831.tar.gz` | `b9a1e7e78b2ba8364bce8ef1cf9655927f5f268b5edaf3b7f4d0a380a76a4aa4` |

同目录保存 GPT 独立重算的 A/B JSON、TSV 与统一 `SHA256SUMS`。原始归档、闭包校验、冻结分析器
重放和独立决策四层证据均已闭合。
