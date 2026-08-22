# 03-17 GLM：librados 客户端线程扫描（验证单挂载 op 速率上限，只读）

> 任务书类型：**P0 归因实验；GLM 只执行和交付原始证据，不做统计、不选下一分支**
> 日期：2026-08-20　｜　执行方：GLM　｜　分析方：opencode
> 母文档：`doc/perf-analysis/03-juicefs-parameter-tuning-execution-plan.md` §11.3
> 上游报告：`doc/perf-report/03-16-n1n2-read-boundary-20260820.md`
> 唯一执行脚本：`scripts/FULLBASELINE/debug/t47-librados-msgr-threads.sh`
> 全程只读，不写任何数据；无人值守纪律沿用 `03-16` §八，时钟漂移判据沿用 `03-16` §2.1c

---

## 计划线

```text
03-16：双挂载合计 6048.7 vs 单挂载 4021.3（+50.4%）⇒ 读侧约束在单挂载，不在整机/集群
       单挂载卡在约 16.9K 对象 GET/s；j64→j128 GET 速率零增长、延迟精确翻倍
       客户端 GET 延迟中 OSD 只占 19%~40% ⇒ 瓶颈在客户端对象层
★ 03-17（本任务）：单挂载 randread，扫 librados 两个候选旋钮
  ├─ A 组：ms_async_op_threads = 1 / 3 / 6 / 12   ← 收发线程（msgr-worker）
  └─ X8 ：ms_async_op_threads = 3 + librados_thread_count = 8  ← 完成线程（io_context_pool，默认 2）
  判读：
  ├─ 只有 A6/A12 涨 ⇒ 收发路径是限制，调 ms_async_op_threads
  ├─ 只有 X8 涨    ⇒ 完成路径是限制，调 librados_thread_count
  ├─ 都涨          ⇒ 两者都非唯一约束，转查 objecter 全局锁
  └─ 都不涨        ⇒ F50 否证，转查 JuiceFS 对象层自身并发结构
拿到原始包后立即停；写路径、TiKV、max-downloads、EC PG 数均不得顺手补跑。
```

---

## 〇、要验的假设（F50）

librados 客户端默认 `ms_async_op_threads = 3`（157 的 `/etc/ceph/ceph.conf` 是最小配置，未设该项）。03-16 观测折算出**每 messenger worker 约 5.6K op/s**：

| 观测 | GET/s | 折算 worker 数 | 每 worker |
|---|---:|---:|---:|
| 单挂载 j64 | 16866 | 3 | 5622 |
| 单挂载 j128 | 16888 | 3 | 5629 |
| 双挂载 j128 合计 | 25110 | 6（两个独立 librados 客户端） | 4185 |

**有两个嫌疑，数值上吻合得一样好。** 2026-08-20 实测一个挂载实例的 librados 线程结构后发现，除了 msgr-worker，完成回调只跑在 2 个 `io_context_pool` 线程上：

| 嫌疑 | 参数 | 默认值 | 折算每线程 op/s | 折算单次耗时 |
|---|---|---:|---:|---:|
| 收发线程 | `ms_async_op_threads` | 3 | 16866/3 = 5622 | 178 µs |
| 完成线程 | `librados_thread_count` | **2** | 16866/2 = **8433** | **119 µs** |

现有数据**无法区分这两个**（双挂载时两者都等比下降，都能用 OSD 延迟上升解释）。所以本轮同时扫两个，用 A3 与 X8 的对照一刀切开——两臂唯一差别就是 `librados_thread_count`（2 vs 8）。

**预期（用于事后判定，GLM 不做判定）**：

| 臂 | 旋钮 | 预期 GET/s | 预期带宽 MiB/s |
|---|---|---:|---:|
| A1 | msgr 1 | ≈5.6K | ≈1400 |
| A3 | msgr 3（基线） | ≈16.9K | ≈4021 |
| A6 | msgr 6 | 20K~25K | 5000~6100 |
| A12 | msgr 12 | 与 A6 相近（受 F51 封顶） | |
| X8 | msgr 3 + ioctx 8 | 若完成路径是限制则 >20K，否则仍 ≈16.9K | |

`A1` 是**否证臂**：把 worker 降到 1 而带宽仍在 4000 附近，则"msgr 线程决定 op 速率"当场死掉。因此它排最前。

**本轮只动这两个旋钮。** `objecter_inflight_ops`（默认 1024，实测在飞仅 129）和 `objecter_inflight_op_bytes`（默认 100 MiB，实测单挂载在飞约 33 MiB）都未触顶，本轮**不得改动**。

---

## 一、目标

- 在单挂载上取得 `ms_async_op_threads` = 1 / 3 / 6 / 12 四个臂，以及 `librados_thread_count = 8` 对照臂（X8）的 randread 原始数据。
- 每个臂**必须留下两个旋钮线程数都已生效的直接证据**（见 §2.3）。
- 另取一个双挂载对照臂（threads 为默认），复现 03-16 的 C64/C128。
- 交付足够证据使分析方能回答：单挂载 GET 速率是否随 worker 数变化、变化是否线性、在哪一档被 F51 机器级约束接住。

GLM 不回答以上任何问题，只报告"脚本是否完成、是否命中 STOP、结果路径与校验和"。

---

## 二、固定环境与方法

### 2.1 固定环境

- 客户端：157；元数据/OSD 节点 `10.20.1.150-152`。
- 二进制：`/tmp/juicefs-03-8`，**md5 必须为 `de93563f11a5ff3bd94dd25a4e0283b1`**（= 上游 e0032b2a + loadRange 修复 + 社区版 flush-race 补丁；与 03-16 同一构建）。md5 不符即 `exit 3`。
- 挂载参数：`--max-fuse-io 256K --max-uploads 150 --cache-size 0`（与 03-16 完全一致）。
- 单挂载点：`/mnt/juicefs-p`；双挂载对照另加 `/mnt/juicefs-q`。
- 业务挂载 `/mnt/juicefs`：**只读身份核对，禁止卸载、重挂、改参数或在其中起 fio**。起始若本来无挂载，记为 `NA` 并全程比对"仍为 NA"，不是 STOP，但须在报告写明。
- fio 版本必须是 **3.28**，否则 `exit 3`。
- P 数据集 `read_test.*.0` 128 文件；Q 数据集 `rw_test.*.0` 128 文件；判档数据集 `test_dir/mseqread/mseqread.*.0` **精确 16 个**。全部以 `--readonly` 访问。
- 起点对象数：Ceph pool `juicefs-data` 的 **objects ≤ 3,110,000**（2026-08-20 13:02 实测 2,434,620）。⛔ 该闸门不得用 `UsedSpace`、`UsedInodes`、TiKV disk size 或任何其他量替代；每次取值的 `ceph df` 原文追加落盘到 `objects-raw.jsonl`。
- **run 内对象数闸门是单向的**：只拦“上涨”（只读任务却生成对象 = 真吃窗口，STOP）；“下跌”是 JuiceFS trash / Ceph 后台回收上一轮 cleanup 的尾巴，与验收无关，记入 `objects-shrink.tsv` 后**继续**，跌幅超过 **1000** 才 STOP。2026-08-20 首次执行因严格相等判定被 −2 个对象误停一次（B4-10，已修）。
- 落盘：根分区约 20 GiB 可用。本任务预计产出 ≈250 MiB。脚本要求可用 ≥5 GiB，否则 `exit 3`。
- 背景监控基线**应为空**（11 个历史遗留监控已于 08-20 09:01 清理）。非空须清点回报，**不得自行 kill**。
  脚本清点时会剔除自身进程树（`t4[0-9]-` 模式会命中 `t47` 自己；03-16 记到的 `count=2` 就是这种自匹配，基线其实是干净的），排除的 PID 记在 `background-monitors-selfexcluded.txt`。2026-08-20 14:35 实测清点为 **0**。

### 2.2 ⛔ 绝对不许改共享配置

`/etc/ceph/ceph.conf` 由全机共用（157 上有百余登录用户与其他业务）。**禁止修改、禁止备份后覆盖、禁止 `ceph config set`。**

本任务用**进程私有配置**注入参数：

```bash
# A 组：只设 ms_async_op_threads（N = 1/3/6/12），librados_thread_count 保持库默认 2
#   -> conf/ceph-msgr${N}.conf
# X8 臂：ms_async_op_threads = 3 且 librados_thread_count = 8
#   -> conf/ceph-msgr3-ioctx8.conf
cp /etc/ceph/ceph.conf $D/conf/ceph-msgr3-ioctx8.conf
cat >> $D/conf/ceph-msgr3-ioctx8.conf <<EOF

[client]
	ms_async_op_threads = 3
	librados_thread_count = 8
EOF
# 只对该次 juicefs mount 进程生效
CEPH_CONF=$D/conf/ceph-msgr3-ioctx8.conf /tmp/juicefs-03-8 mount ...
```

私有 conf 全部落在结果目录里随原始包回传。任务结束后不残留任何对 `/etc/ceph/` 的改动。

### 2.3 生效验证（本任务的核心闸门）——注入路径已在 157 实测通过

librados 的 messenger worker 是命名线程。计数方式：

```bash
cat /proc/<juicefs_io_pid>/task/*/comm | grep -c '^msgr-worker'
```

**⚠ 取 PID 有坑，必须取对。** `juicefs mount -d` 会留下两个进程：

| 角色 | ppid | 线程数 | 有 msgr-worker 吗 |
|---|---|---:|---|
| 守护父进程 | 1 | 约 34 | **没有** |
| 子进程（真正服务 IO） | 父进程 PID | 46 ~ 56 | **有** |

取到父进程会永远数到 0。脚本的 `mount_pid()` 已改为「候选集中 ppid 也属于候选集的那个」，父进程 PID 另记在 `instances.tsv` 末列备查。

2026-08-20 opencode 在 157 上实测（每档独立挂载、挂完即卸）：

| 私有 conf 设定 | 观测 msgr-worker | 观测 io_context_pool | 进程总线程数 |
|---|---:|---:|---:|
| 不注入（系统默认） | **3** | **2** | 47 |
| `ms_async_op_threads = 1` | **1** | 2 | 46 |
| `ms_async_op_threads = 3` | **3** | 2 | 47 |
| `ms_async_op_threads = 6` | **6** | 2 | — |
| `ms_async_op_threads = 12` | **12** | 2 | 56 |
| `= 3` + `librados_thread_count = 8` | **3** | **8** | 53 |
| `= 6` + `librados_thread_count = 8` | **6** | **8** | — |

全部一致 ⇒ **`CEPH_CONF` 私有配置注入有效，两个旋钮都可控，不需要备选方案。** 注意 `= 3 + ioctx 8` 的总线程数 53 比默认 47 恰好多 6，正是多出来的 6 个完成线程。 另有独立佐证：在私有 conf 里加 `debug_ms = 1` + `log_to_stderr = true` 后，mount 日志出现 132 行 librados msgr2 建链输出（连 3 个 mon、`learned_addr`、`AUTH_CONNECTING`、`mon_map` 等），证明该 conf 确实被 librados 读取。

一个挂载实例的 librados 线程结构（`ms_async_op_threads = 6` 实测）：

```
msgr-worker-0 … msgr-worker-5   ← 旋钮一：ms_async_op_threads（收发）
io_context_pool ×2              ← 旋钮二：librados_thread_count（完成回调，默认 2）
ms_dispatch / ms_local / ceph_timer / safe_timer ×2 / service / log
```

两个计数命令：

```bash
cat /proc/<io_pid>/task/*/comm | grep -c '^msgr-worker'
cat /proc/<io_pid>/task/*/comm | grep -c '^io_context_pool'
```

落盘要求：每个臂把该进程全部线程的 `tid comm` 落到 `msgr-threads-<arm>.txt`，计数写入 `msgr-threads.tsv`（列：`label mount conf want_msgr got_msgr want_ioctx got_ioctx`）；每个 run 目录里再各存一份（`msgr-threads-P.txt` / `-Q.txt`），`run-meta.txt` 里也记一行两个计数。

**若 `got_msgr != want_msgr` 或 `got_ioctx != want_ioctx`：该臂 STOP，整轮 STOP，回报。** ⛔ 禁止自行改用第二种注入方式后继续跑数据。A 组各臂的 `want_ioctx` 一律为库默认 **2**——这同时充当一个对照：如果 A 组某臂数到的不是 2，说明库默认值和我们的认知不一致，也要停。

⚠ **步骤 2 的预验证仍必须做一遍**（用一次性挂载同时试 `ms_async_op_threads=6` + `librados_thread_count=8`，两者都要数对）：opencode 的验证是在 08-20 14:33 完成的，GLM 上机时须重新留一份自己的证据，且能顺带确认脚本、二进制、挂载点都还是同一状态。

### 2.4 判档门修订（沿用 ns/B 判别器，门槛改为 ±18%）

03-16 证据显示 ns/B 的实测分布是双峰的，而原 ±10% 门槛正好劈在正常总体中间：

| 状态 | 实测 ns/B | 偏离 3.287 |
|---|---|---|
| 好态（第一挂载位） | 3.330 / 3.336 | 1.3% / 1.5% |
| 好态（第二挂载位） | 3.595 / 3.603 / 3.610 / 3.624 / 3.636 / 3.648 | 9.4% ~ 11.0% |
| 坏态 | 4.149 / 4.166 / 4.744 / 4.919 / 4.925 | 26.2% ~ 49.8% |

好态上界 11.0%、坏态下界 26.2%，中间是空的。**本任务门槛取 ±18%**（两侧各留 7 个百分点余量），既收下第二挂载位的固定劣势，又仍然拒绝 26% 以上的坏态和已知的约 27× 坏档。

附加要求：**ns/B 一律作为协变量记录**，无论通过与否都写入 `gate-summary.tsv`，不再只留通过/失败。判档连续三次失败仍然 STOP。

⚠ 判档挂载的旋钮必须与该臂一致（判档和测量必须是同一个挂载实例，不得为了判档另起默认配置的挂载）。参考值 3.287 是在默认 3 线程下标定的，因此 **A1（msgr 1）与 A12（msgr 12）不参与判档**，改由锚点兜底；判档在 **A3 / A6 / X8 / CTL** 上执行（X8 的 msgr 仍是默认 3，参考值适用）。不参与判档的臂不跑判档 fio，节省约 24 分钟。

### 2.5 批次锚点（两级，提前止损）

`threads=3` 臂的 `P64` 与 03-16 是完全相同的配置，作为批次锚点。03-16 实测 `P64 = 4021.3 MiB/s`（3 轮均值）。

| 级别 | 时点 | 样本数 | 容差 | 窗口 MiB/s |
|---|---|---:|---:|---|
| 提前止损 | Pass 1 的 A3 臂结束时 | 2 | ±15% | 3418.1 ~ 4624.5 |
| 最终闸门 | CTL 臂结束后 | 4 | ±10% | 3619.2 ~ 4423.4 |

任一级超窗即 STOP 并回报：说明环境或基座相对 03-16 已经变了，本轮所有臂之间的比较都不可用。设提前止损级是为了在环境已变时不再白跑约 2 小时。

锚点样本逐条落盘到 `anchor-a3-p64.tsv`，判定结果落盘到 `anchor-check.tsv`。

### 2.6 退出码

| 码 | 含义 |
|---:|---|
| 0 | 正常完成（或预验证/preflight 通过） |
| 2 | 参数或授权拒绝（未知模式、缺 `ACK_SUDO_WRITES`、`OUT` 非法、缺输入文件、OUT 已含正式轮证据、归档已存在） |
| 3 | 硬前置失败（二进制 md5 不符、fio 非 3.28、落盘不足、OSD 预探失败） |
| 5 | 起点对象数超闸门（run 内对象数上涨、或跌幅 >1000，走 rc=1） |
| 6 | 专用挂载点已被占用或专用目录非空 |
| **7** | **msgr-worker 线程注入未生效（预验证阶段）** |
| 90 | 业务挂载身份在退出时校验失败 |
| 91 | `/etc/ceph/ceph.conf` 在退出时校验失败（被改动） |
| 其他 | 矩阵执行中命中 STOP，原因见 `wrapper.log` |

---

## 三、矩阵与顺序

单挂载臂（挂载点只有 `/mnt/juicefs-p`，Q 不挂）：

| 臂 | ms_async_op_threads | librados_thread_count | 配置 | 判档 |
|---|---:|---:|---|---|
| A1 | 1 | 默认 2 | `P64` | 否 |
| A3 | 3 | 默认 2 | `P64`、`P128` | 是 |
| **X8** | **3** | **8** | `P64`、`P128` | 是 |
| A6 | 6 | 默认 2 | `P64`、`P128` | 是 |
| A12 | 12 | 默认 2 | `P64`、`P128` | 否 |

**A3 与 X8 是本轮的关键对照**：唯一差别是完成线程 2 vs 8。因此两个 Pass 都把 X8 紧挨 A3 排布，尽量压掉时间漂移。

双挂载对照臂（两侧均为系统默认，即 msgr 3 + ioctx 2，复现 03-16）：

| 臂 | 配置 | 判档 |
|---|---|---|
| CTL | `C64`、`C128` | 是（P、Q 两侧） |

执行顺序（**臂内挂载实例冻结，臂间必须重挂**，因为改线程数只能靠重挂生效）：

```text
预验证（一次性挂载试 msgr=6 + ioctx=8，只数线程，不跑 fio）
Pass 1： A1 → A3 → X8 → A6 → A12   ← A3 结束时做锚点提前止损（§2.5）
Pass 2： A12 → A6 → X8 → A3 → A1   ← 臂顺序反向，对冲时间漂移
CTL：   C64、C128 各 2 次           ← 臂标签为 T47-CTL-pc
最后做锚点最终闸门（§2.5）
```

每个臂在其挂载生命周期内，对该臂的每个配置各跑 **2 次**（`P64,P128,P64,P128` 交替，A1 为 `P64,P64`）。两个 Pass 合计每个 (臂, 配置) 得 **4 次重复**。

- run 数：Pass1 = 2+4+4+4+4 = 18；Pass2 = 18；CTL = 4；合计 **40 个 fio run**。
- 判档轮次：A3 / X8 / A6 各 2 个 Pass × 2 次 = 12 次，CTL 两侧 × 2 次 = 4 次，合计 **16 次判档 fio**。
- 单 run 180 s、间隔 20 s；挂载 12 次；**预计 3.5~4 h，最坏 5 h**。
- 每个 run 前后各采一次 6 个 OSD 的 `perf dump`、`ceph health detail`、对象数、host-state、i1 指标、net 计数（口径与 t46 完全一致）。

---

## 四、执行步骤

### 步骤 0：必须先读和预扫描

1. 通读本任务书、`03-16` §2.1c（时钟漂移）与 §八（无人值守纪律）、`skills/SYSTEM-SAFETY-SKILL.md`。
2. 只读安全扫描，输出清单给用户确认：

```bash
sudo ceph health detail
sudo ceph pg stat
sudo ceph df --format=json
sudo ceph osd dump | head -40
sudo ceph time-sync-status
for i in 0 1 2 3 4 5; do sudo ceph tell osd.$i perf dump | wc -c; done
ss -tlnp | head -20
mount | grep -i juicefs
ps -ef | grep -E 'juicefs|fio|monitor|tracer' | grep -v grep
cat /etc/ceph/ceph.conf
df -h /tmp
fio --version
md5sum /tmp/juicefs-03-8
```

### 步骤 1：拷脚本并双端记 md5

```bash
# 本地仓库 → 157 /tmp
scripts/FULLBASELINE/debug/t47-librados-msgr-threads.sh
scripts/FULLBASELINE/debug/t39-nsbgate.sh
scripts/FULLBASELINE/probe/env-snapshot.sh          # md5 必须为 b6d1c556e43b183c43ea3fdc7de49cd7
```

三个文件在本地和 157 两端都记 md5 并写入报告。`/tmp/env-snapshot.sh` 若已存在旧版必须覆盖。

### 步骤 2：预验证线程注入（不跑 fio）

```bash
bash /tmp/t47-librados-msgr-threads.sh --preflight-msgr-only
```

- 生成 `ceph-msgr6.conf`，用 `CEPH_CONF` 起一个一次性挂载，数 `msgr-worker` 线程，落盘 `msgr-preverify.txt`，随即卸载。
- **数到 6 才继续**（`rc=0`）；数到其他值立即停（`rc=7`），把 `msgr-preverify.txt` 与挂载日志回报，不进入正式矩阵。
- 该模式不需要 `ACK_SUDO_WRITES`，只做一次挂载+卸载，不跑 fio、不动对象。

### 步骤 3：无状态 preflight

```bash
bash /tmp/t47-librados-msgr-threads.sh --preflight
```

输出 fio 版本、落盘可用、对象数、OSD 预探、背景监控清点、业务挂载身份、判档数据集计数。清单交用户确认。

### 步骤 4：得到用户对步骤 0/2/3 清单的明确确认后，一次执行

```bash
ACK_SUDO_WRITES=YES nohup bash /tmp/t47-librados-msgr-threads.sh > /tmp/t47-wrapper.out 2>&1 &
```

按 `03-16` §八 的节奏监控（30 min 一次，七项必查，"进程消失 ≠ DONE"）。

### 步骤 5：命中 STOP 时

保留现场原样（不重挂、不清理、不重试），打包已有证据回传，报告命中的 STOP 条件编号与原文。

---

## 五、STOP 条件

1. 二进制 md5 != `de93563f11a5ff3bd94dd25a4e0283b1`。
2. fio 版本非 `3.28`。
3. 落盘可用 < 5120 MiB。
4. OSD `perf dump` 预探任一 < 1000 字节。
5. 起点对象数 > 3,110,000；或任一 run 前后对象数**上涨**（本任务全只读，上涨即异常）；或**下跌超过 1000 个**。下跌 ≤1000 属后台回收，脚本记录后继续，不是 STOP 条件。
6. 判档数据集不是精确 16 个文件，或 P/Q 数据集不是 128 个文件。
7. **`msgr-worker` 观测线程数不等于期望值**，或 **`io_context_pool` 观测线程数不等于期望值**（A 组期望 2、X8 期望 8、CTL 期望 2；含步骤 2 预验证）。
8. `threads=3` 臂的 `P64` 四次均值超出 3619 ~ 4423 MiB/s。
9. 判档（仅 A3 / X8 / A6 / CTL 臂）连续三次超出 ±18%。
10. 挂载实例的 `PID + starttime_ticks` 在**同一臂内**发生变化。
11. 业务挂载 `/mnt/juicefs` 身份发生任何变化（含 `NA` → 非 `NA`）。
12. 集群健康出现除时钟漂移以外的任何 `[WRN]/[ERR]`；或漂移值 > 0.5 s；或漂移值解析失败。（漂移例外的完整判据见 `03-16` §2.1c）
13. 任一 fio `rc != 0`，或 bw log 数量与 `numjobs` 不符。
14. 需要修改 `/etc/ceph/ceph.conf`、需要 `ceph config set`、或需要改用第二种参数注入方式才能继续。
15. 背景监控基线非空（清点回报，等指示，**不得自行 kill**）。

---

## 六、必须回传的原始证据

打包 `/tmp/production/opencode-t3.17/` 全目录 + md5，内容至少包含：

- `msgr-preverify.txt`、`msgr-threads-<arm>.txt`、`msgr-threads.tsv`（**本任务最关键的三项**，含 msgr 与 io_context 两组计数）
- `conf/ceph-msgr{1,3,6,12}.conf` 与 `conf/ceph-msgr3-ioctx8.conf`（实际使用的私有配置原文）
- `conf/ceph.conf.system-{before,after}` 与 `conf/sysconf-checks.tsv`（证明共享配置未被改动）
- 每个 run：`fio-<side>.txt`、`command-<side>.txt`、`fio-<side>-start-ns.txt`、`i1-<side>.tsv`、`proc-<side>.tsv`、`net.tsv`、`host-state-{pre,post}.txt`、`objects-{pre,post}.txt`、`run-meta.txt`
- `bwlog/`（全部 per-job bw log）
- `osd/`（每 run 前后 6 个 OSD 的 `perf dump`）
- `gate-summary.tsv`（含未通过项的 ns/B 值）、`i1-*-gate-*.tsv`、`probe-gate.log`
- `instances.tsv`、`instance-checks.tsv`、`mount.log`、`progress.tsv`、`wrapper.log`
- `objects-raw.jsonl`、`objects-initial.txt`、`objects-final.txt`、`objects-shrink.tsv`、`dataset-check.tsv`
- `skew-events.tsv`、`time-sync-*.json`
- `fio-version.txt`、`input-md5.txt`、`disk-preflight.txt`、`osd-probe.txt`、`background-monitors-initial.txt`
- `env-snapshot-*.txt`、`main-mount-before.txt`、`main-mount-after-checks.txt`
- pprof goroutine dump（Pass 2 的 A3/A6 臂各一次，用于对比排队结构）

---

## 七、合规自查（最后一步）

- [ ] 未修改 `/etc/ceph/ceph.conf`，未执行任何 `ceph config set`；`cat /etc/ceph/ceph.conf` 前后一致（前后原文都已落盘）。
- [ ] 全部 fio 带 `--readonly`；对象数全程无上涨（下跌条目见 `objects-shrink.tsv`，属正常）。
- [ ] 每个臂都有 `msgr-worker` 与 `io_context_pool` 两组线程计数证据，且都等于期望值（A 组 ioctx 应为 2，仅 X8 为 8）。
- [ ] 每个臂内挂载实例 `PID + starttime_ticks` 未变；臂间重挂已记录在 `mount.log` 与 `instances.tsv`。
- [ ] 业务挂载 `/mnt/juicefs` 未被卸载、重挂或写入。
- [ ] 未 kill、未 pkill 任何进程；`background-monitors-initial.txt` 已留痕，非空情况已在报告列出。
- [ ] `skew-events.tsv` 每条都满足「仅一条告警且为时钟漂移、值 ≤0.5 s」。
- [ ] 未改 `objecter_inflight_ops` / `objecter_inflight_op_bytes` / `--max-uploads` / `--max-fuse-io` / `--cache-size`；`librados_thread_count` 只在 X8 臂出现过。
- [ ] 未顺手补跑写测试、TiKV、`max-downloads`、EC PG 调整。
- [ ] 报告中**没有**任何带宽、GET 速率、百分比的计算或判定结论。

## 八、回复模板

```text
03-17 执行结果
脚本 md5（本地/157）：...
预验证：msgr 请求 6 / 观测 N；io_context 请求 8 / 观测 M
完成臂：A1 / A3 / X8 / A6 / A12 / CTL，各 run 数与 rc
msgr-threads.tsv：<全部原文>
命中 STOP：无 / 第 N 条（原文）
时钟漂移事件数：N，峰值 X s
对象数：起 ... 终 ...（下跌条目数 ...，最大跌幅 ...）
结果包：/tmp/production/opencode-t3.17-20260820.tar.gz  md5 ...
```

---

## 九、本任务不做的事

- 不改 `/etc/ceph/ceph.conf`，不改任何集群侧配置（EC PG 数、OSD 旋钮一律不动，B6 未授权）。
- 不做写测试、不碰 TiKV、不测 `max-downloads`、不做 Phase X 读写分挂载。
- 不因某个臂的结果"看起来好"就扩大扫描范围（如加 24 / 48 线程，或再加 ioctx 16 / 32）；扫描范围由分析方在拿到本轮原始包后决定。
- 不把两个旋钮同时往上叠（本轮没有"msgr 12 + ioctx 8"这种臂）；要先分清哪一个起作用。
- 不做任何统计与判定。
