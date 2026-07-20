# 任务书 01-2：randrw 降并发扫描 + 读放大分段诊断（不限速）

> 面向 GLM。当前"不限速调优"阶段第二份任务书。承接 **01-1** 的不限速 ra0 冷态基线
> （`results/prod-nolimit-cold-ra0-20260715-235631/`，已验收可信）。
>
> 上位规划：`prod-deploy/doc/perf-analysis/01-baseline-review-and-nolimit-plan.md` §5.3.1 ~ §5.3.3。
> 命令/方法论见 skill（不重复）：
> - `prod-deploy/skills/test-commands-reference.md`（§6 随机项 / §7 rados 裸测 / §8 稳态中位数 / §9 五类采集）
> - `prod-deploy/skills/TESTING-GUIDE.md`（health / compact cooldown / 可靠性判据）
> - `prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md`（长跑托管）

---

## 〇、前提

- 集群沿用 01-1 已部署环境（Ceph EC4+2 + TiKV + JuiceFS，fsid `7bb47ec2-8061-...`）。开跑前重新确认 §六 checklist。
- 口径：**不限速 100GbE，256K block，单客户端，冷态 cache=0，ra0（`--max-readahead 0`）**。
- 本任务书**不改集群/不重部署**，只改 fio 并发档 + 挂载参数 + 加诊断采集。
- 达标线：不限速 50% = 6250 MiB/s（趋势/放大倍数为主，不作硬判据，见 01-1 §3.2c）。

---

## 一、任务目标（三件事，按序）

01-1 定位到两个瓶颈：**① randrw 合计仅 72.7（头号）② randread ra0=2572 距 6250 仍远（第二）**。
本轮**先推翻 randrw 的队列测量偏差、定出合理并发验收口径，再对读路径做放大分段诊断**：

1. **randrw / randread 降并发扫描** —— 判定 72.7 是否纯 fio 队列测量偏差，找到"不积压"的合理并发档。
2. **juicefs stats 分段** —— 量化 randread/randrw 的 object GET/PUT 放大与 meta 往返，切分放大在 FUSE 读路径还是 EC/后端。
3. **rados bench 后端裸上限** —— 绕开 JuiceFS/FUSE 标 256K 随机读写的后端天花板，判断"客户端还有多少可调空间"。

> ⚠️ **先修 01-1 的采集缺陷**：01-1 的 `*_bw.log` 只保留了单 job 日志（128 job 只存了 job1），
> 导致 §8.3 的"128 job 聚合稳态中位数"未真正执行。本轮所有 128 job 项**必须保留每 job 的
> `<prefix>_bw.<job_id>.log` 全部文件**（§9.2），再按 §8.3 聚合脚本算真稳态中位数。

---

## 二、步骤 1：randrw / randread 降并发扫描

### 2.1 扫描矩阵（randrw 为主，randread 陪跑同档做对照）

固定 bs=256k、direct=1、time_based 180s、REPEAT=3、ra0、cache=0；**只变 numjobs × iodepth**：

| 档位 | numjobs | iodepth | 总并发 | 目的 |
|---|---|---|---|---|
| D0（基线复现）| 128 | 128 | 16384 | 复现 01-1 的 72.7，锚定 |
| D1 | 32 | 16 | 512 | 主检验档（老集群 76/76 量级并发） |
| D2 | 16 | 8 | 128 | 低并发,看是否消除队列积压 |
| D3 | 8 | 4 | 32 | 极低并发,读写延迟本征 |

- randrw：fresh volume + create_on_open（`test-commands-reference.md` §6.3），每档跑前 destroy→format→mount。
- randread：复用同一 layout 卷（§6.1），每档只改 numjobs/iodepth，做单变量。
- 每档 REPEAT=3，每轮跑前 `drop_caches`（157 + 3 slave，§3.1）。

### 2.2 每档每轮必采（§9 五类，全部保留）

- fio 全量输出（含 clat 分布 + `lat(msec) >=2000` 占比）。
- **每 job 的 `_bw.<job_id>.log`**（用于 §8.3 聚合，别再只留 job1）。
- NIC（enp139s0f0np0）+ juicefs stats（§9.4）+ pidstat（§9.5）。

### 2.3 判读（写进 summary）

对每档算：
- **§8.3 聚合稳态中位数**（randrw 按 data_direction 分 R/W，再算合计）。
- fio 报告的 `>=2000ms` 占比（D0 应 ~44%，降并发后应显著下降）。
- **R/W 比**（老集群 D1 量级并发下为 1.00 均衡；看新集群随并发下降是否回归均衡）。

**结论分叉**：
- 若合计随并发下降**显著回升** + R/W 回归均衡 → 确认 72.7 是 fio 队列测量偏差，**选无积压的最低失真档（预期 D1/D2）作为 randrw 验收口径**，记入 results-table 并标注"新验收并发档"。
- 若合计**不回升**（仍 ~70 量级） → 排除测量偏差,randrw 低是真实能力瓶颈,进入步骤 2/3 深挖读路径。

> ⚠️ **BeeGFS 同步**：一旦本步定出新 randrw 验收并发档,必须同步到
> `beegfs-production/doc/perf-tasks/stage3-aligned-retest-task-book.md`（否则 JuiceFS↔BeeGFS 横向不可比）。
> 本轮先**只记录建议档**,是否落地改 BeeGFS 任务书由用户拍板（§七开口 1）。

---

## 三、步骤 2：juicefs stats 分段（读放大定位）

对 **randread（D0 128×128 + 步骤1 选出的最优档）** 和 **randrw（同两档）** 各跑一次,
全程后台采 `juicefs stats`（§9.4，每秒一行）+ NIC RX/TX。

算三个放大比,写进 summary：

| 指标 | 算法 | 判读 |
|---|---|---|
| **读放大** | juicefs object GET 带宽 ÷ fio 有效读带宽 | ≈1.0 无放大；>1.5 有投机预取/EC 读放大（ra0 应已消预读放大,复核是否残留） |
| **网络放大** | NIC RX ÷ fio 有效读带宽 | 切 EC 4+2 取片开销（理论 1.5× 读） |
| **meta 往返** | juicefs meta ops/lat 占比 | randread 走 FUSE→TiKV(查位置)+FUSE→RADOS(取数据) 双往返,看 meta lat 是否吃掉时间 |

**结论分叉**：
- 放大 ≈1.0 且 meta lat 低 → 读瓶颈是**并发/连接上限**（进步骤 3 + 后续客户端调参）。
- object GET 放大明显 → 残留读放大（复查 ra0 是否真生效 / EC 读放大）。
- meta lat 高 → IOPS 受双往返限制（老集群 `iops-wall-locate-20260708` 同型,引用对照）。

---

## 四、步骤 3：rados bench 后端裸上限（256K）

从**干净客户端节点 157 发起**（非 OSD 主机,否则 NIC RX/TX 混算），按 `test-commands-reference.md` §7：

```
rados bench -p juicefs-data 120 write -b 262144 -t 16 --no-cleanup --run-name rados-l1   # prefill
rados bench -p juicefs-data 60  rand  -t 128 --run-name rados-l1                          # 256K 随机读（扫 -t 16 / 128）
rados bench -p juicefs-data 60  rand  -t 16  --run-name rados-l1
rados -p juicefs-data cleanup --run-name rados-l1
```

- 同时采 157 NIC RX,算后端放大 = NIC_RX ÷ rados 有效读带宽（L1≈1.0 → 放大在 JuiceFS 内部；L1≈2.5 → 在 librados/EC/网络层）。
- **prefill 用 256K 对象对齐 JuiceFS 卷**,-b 262144 不可改。

**结论分叉**：
- 后端裸上限 **远高于** JuiceFS randread 2572 → 差距在客户端/FUSE,**下一份任务书做客户端并发参数扫描**（max-uploads / buffer-size / max_background）。
- 后端裸上限 **≈** JuiceFS randread → 已到架构天花板（EC4+2 + 6 OSD + 256K 随机）,单客户端接受,考虑多客户端聚合验收。

---

## 五、结果落盘

结果根目录：
```
results/prod-nolimit-concurrency-sweep-<juicefs版本>-<YYYYMMDD-HHMMSS>/
```
子目录：`randrw-D0..D3/`、`randread-D0..D3/`、`jfs-stats-diag/`、`rados-l1/`,各含 §9.6 结构。
必含 `commands.sh`、`env-snapshot.txt`（同 01-1：ceph health/osd dump 双网/无 tc/juicefs version/fsid）、`summary.md`。

**summary.md 必含**：
- 降并发扫描表（每档 R/W/合计 **稳态中位数** + `>=2000ms` 占比 + R/W 比）+ 测量偏差判定结论 + 建议验收并发档。
- 三个放大比（读/网络/meta）表 + 读瓶颈定位结论。
- rados 裸上限（16/128 两档）+ 后端放大 + 客户端可调空间结论。

更新 `prod-deploy/doc/deploy-log/results-table.md`（新增降并发档行,标注新 randrw 验收口径）。
分析归档到 `prod-deploy/doc/perf-analysis/02-*.md`（一个阶段一篇,承接 01 的 §5.3）。

---

## 六、开跑前 checklist

- [ ] Ceph HEALTH_OK + 6 OSD up/in + juicefs-data(EC, ec_overwrites) + osd dump 双网 10.3.1.x/10.3.2.x
- [ ] **无 tc qdisc**（不限速）；Ceph 走 100GbE（osd dump 非 10.114.x）
- [ ] JuiceFS 含 eaf3d21f；mount 参数 = mu150 + cache=0 + **ra0**
- [ ] 所有 fio 带 `--write_bw_log --log_avg_msec=1000`
- [ ] **本轮修正采集缺陷：128 job 项保留全部 `_bw.<job_id>.log`（不再只留 job1）**
- [ ] 每档每轮跑前 drop_caches（157 + 3 slave）
- [ ] randrw 每档 fresh volume（destroy→format→mount）；randread 复用同一 layout 卷
- [ ] rados bench 从 157 发起（非 OSD 主机），-b 262144
- [ ] §8.3 聚合脚本按 data_direction 分 R/W 算稳态中位数（不是 128 文件各自中位再平均）

---

## 七、待用户/GLM 确认的开口

1. **randrw 验收并发档**：若步骤 1 证明测量偏差,选出的新验收档（预期 D1 32×16 或 D2 16×8）
   是否落地改 BeeGFS 任务书 + results-table 验收口径？（本轮先只出建议档,不擅自改 BeeGFS。）
2. 步骤 2/3 若指向"客户端可调空间大",下一份任务书（01-3）做客户端并发参数扫描
   （max-uploads / buffer-size / max_background）+ 必要时多客户端聚合,是否直接排期。
