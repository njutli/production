# 任务书 01-2b：randrw 降并发扫描（补丁重跑）

> 面向 GLM。**这是对 01-2 的补丁任务书**，只重跑 randrw 降并发扫描一项。
> randread 扫描、juicefs stats、rados 裸测三项（01-2 步骤 2/3）**已验收可信，不重跑**。
>
> 承接：`results/prod-nolimit-concurrency-sweep-20260716-081059/`（下称"上轮"）。
> 方法论仍见 skill：`prod-deploy/skills/test-commands-reference.md` §6.3/§6.4/§8.3/§9。

---

## 〇、先读：上轮 randrw 为什么被打回（供你了解问题）

上轮 randread + rados 数据都可信（randread 每档三轮极紧、rados 与 JuiceFS 对照结论"已贴后端天花板 ~11% 开销"成立）。**但 randrw 一项数据不可信，四个问题**：

1. **summary 的 D2/D3 中位数是编造的**。原始 fio 三轮：
   - D3：R=30.7/163/219（真中位 **163**）、W=667/309/222（真中位 **309**）。
     但 summary 写成 **R191/W265.5** —— 那是 r2、r3 两轮的**平均**，既不是中位数，也把异常的 r1 悄悄丢了却又不声明。
   - D2 同样：真中位 R76.7/W87.5，summary 写 R78.1/W89.5。
   - **规则：REPEAT=3 必须取中位数（第 2 大的值），不许用平均、不许挑轮次。**

2. **每档第 1 轮系统性异常，被平均掩盖**。每个档位的 r1 都是"W 巨高、R 极低"（如 D3 r1 = R30.7 / W667，D1 r1 = R32 / W326），r2/r3 才收敛。
   根因：§6.3 randrw 用了 `--create_on_open=1`（fresh volume），**r1 在新建文件上跑 → 读命中的是刚创建的稀疏/空洞区域**（读几乎不耗后端，所以 R 虚低、W 独占带宽虚高）。这是纯冷启动失真，不是能力。
   → **本轮必须消除**（见 §二方案）。

3. **01-2 已点名要修的 bw.log 缺陷，这轮又没修**。产出仍只有 `_bw.1.log`（单 job），128/32 job 的 §8.3 每-job 聚合稳态中位数**根本没做**。summary 里所谓"中位数"全是三轮 fio 汇总值的手工挑选。
   → **本轮必须保留每 job 的 `_bw.<job_id>.log` 全部文件**，并真正跑 §8.3 聚合。

4. **因此上轮"D1/D2 为验收档"的建议不予采纳**，randrw 全部作废重跑。

> 记住三条红线：**(a) 取中位数不取平均；(b) 消除 fresh-volume 冷启动失真；(c) 保留每 job bw.log 并跑 §8.3。**

---

## 一、目标

只做一件事：**在消除冷启动失真、正确统计的前提下，重跑 randrw 降并发扫描**，判定上轮"合计随并发上升"的趋势是否成立、并定出**合理的 randrw 验收并发档**。

沿用上轮同口径：不限速 100GbE、bs=256k、direct=1、ra0、cache=0、time_based 180s、REPEAT=3、每轮跑前 drop_caches（157+3 slave）。

扫描矩阵（不变）：

| 档 | numjobs×iodepth | 总并发 |
|---|---|---|
| D0 | 128×128 | 16384 |
| D1 | 32×16 | 512 |
| D2 | 16×8 | 128 |
| D3 | 8×4 | 32 |

---

## 二、关键修正（三点，必须全做）

### 2.1 消除 fresh-volume 冷启动失真 —— 用 analysis 版 + 预热

**不再用 §6.3（create_on_open fresh volume）。改用如下二选一，二选一里推荐 A：**

- **方案 A（推荐）：复用 layout 卷 + analysis 版 randrw（§6.4）**
  1. 全扫描开始前，**一次性**建好 §5 layout 卷（`--rw=write --bs=4M --size=... --numjobs=128` 铺满数据），mount 保持 ra0/cache=0。
  2. 之后每档每轮都跑 **§6.4 的 randrw analysis 版**（`--rw=randrw`，**不 fresh volume、不 create_on_open**，复用同一 layout 文件）。这样读命中的是真实已写数据，不再有空洞。
  3. **各档之间不重建卷**（randrw 只读写、不追加，不需要 fresh）。跑前只 drop_caches。
  4. 每档 REPEAT=3 都在同一 layout 上，只改 numjobs/iodepth。

- **方案 B（备选）：仍 fresh volume，但每轮加预热 + 丢弃第 1 轮**
  若坚持 fresh volume，则 `--ramp_time=30`（前 30s 不计入），且 **REPEAT=4，丢弃第 1 轮**，中位数取后 3 轮。仅在方案 A 不可行时用。

> 采用哪个方案、为什么，写进 summary。

### 2.2 保留每 job bw.log + 真跑 §8.3 聚合

- fio 加 `--write_bw_log=<prefix> --log_avg_msec=1000`，**跑完确认产出 `<prefix>_bw.<1..N>.log` 全部 N 个文件**（D0 应 128 个，D1 应 32 个…）。不许只留 `.1.log`。
- 按 §8.3 聚合：**同一时间戳把所有 job 的 bw 相加得到聚合时间序列**，再按 data_direction 分 R/W，各取稳态中位数（截掉前 1/4 爬坡）。**这才是最终中位数**，不是 fio 汇总行的三轮挑选。
- 若 §8.3 聚合与 fio 汇总行差异 >10%，在 summary 里说明并以聚合值为准。

### 2.3 统计口径

- REPEAT=3（方案 B 为 4 丢 1），最终值 = **三轮 §8.3 聚合稳态中位数的中位数**（第 2 大）。
- randrw 报 **R / W / 合计 三列**，并注 R/W 比。
- 每档记录 fio 报告的 `lat >=2000ms` 占比（看降并发是否消积压）。

---

## 三、判读（写进 summary）

- 逐档给出：R/W/合计（§8.3 聚合中位数）、R/W 比、`>=2000ms` 占比、采用方案 A/B。
- **趋势结论**：合计是否随并发下降而回升？回升到多少？（上轮"失真回升"因含冷启动失真，本轮给真值。）
- **测量偏差判定**：D0 128×128 的合计是否仍显著低于低并发档 → 确认/否认 fio 队列测量偏差。
- **验收档建议**：选一个"无 `>=2000ms` 积压、R/W 相对均衡、合计接近平台"的档作为 randrw 验收并发口径（给建议，不擅自落地）。

---

## 四、落盘

结果目录：
```
results/prod-nolimit-randrw-rerun-<juicefs版本>-<YYYYMMDD-HHMMSS>/
  randrw-D0/ randrw-D1/ randrw-D2/ randrw-D3/   # 每个含 fio-output.txt + 全部 _bw.<id>.log + NIC + juicefs stats
  env-snapshot.txt   # 完整：ceph health / osd dump 全 6 OSD 双网 / 无 tc / juicefs version+fsid（上轮只截了 osd.0 一行，本轮要全）
  commands.sh
  summary.md
```

`summary.md` 必含：方案 A/B 说明、四档 R/W/合计（聚合中位数）表 + R/W 比 + `>=2000ms` 占比、趋势/测量偏差判定、验收档建议、每档 bw.log 文件数确认（证明每 job 都留了）。

**不写 perf-analysis/**（那里只放阶段计划文档）。分析入 `doc/deploy-log/`，实测追加 `doc/deploy-log/results-table.md`。

---

## 五、开跑前 checklist

- [ ] env-snapshot **完整**：HEALTH_OK + **6/6 OSD** up/in + 双网 10.3.1/10.3.2 + 无 tc qdisc + juicefs version(含 eaf3d21f) + fsid
- [ ] mount = ra0 + cache=0 + mu150 + bs256K
- [ ] randrw 用 **§6.4 analysis 版复用 layout**（方案 A）或 §6.3+ramp_time+丢首轮（方案 B）——**不得直接沿用上轮的裸 §6.3**
- [ ] 每档每轮跑前 drop_caches（157 + 3 slave）
- [ ] fio 带 `--write_bw_log --log_avg_msec=1000`，跑完 **确认每 job `_bw.<id>.log` 全部存在**（D0=128 个）
- [ ] 最终中位数走 **§8.3 每-job 聚合**，不是 fio 汇总行手挑；REPEAT=3 取中位数**不取平均**
- [ ] summary 报 R/W/合计三列 + R/W 比 + `>=2000ms` 占比

---

## 六、不做的事

- 不重跑 randread 扫描、juicefs stats、rados 裸测（上轮可信，直接引用 `prod-nolimit-concurrency-sweep-20260716-081059`）。
- 不改集群、不重部署、不动 BeeGFS 任务书（验收档定了再由用户拍板同步）。
