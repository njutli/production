# 03-17b GLM：读侧双稳态（阻塞 B8）定性，只读

## 计划线

```
03-16 已结案：读侧瓶颈在单挂载（per-mount），F50 单挂载 ≈16.9K GET/s
   └─ 03-17 两次中止：第 1 次脚本误停（B4-10 已修），第 2 次 A3 判档 FAIL dev=62.1%（正确停机）
        └─ 复算发现：好档/坏档是客户端双稳态，对象层 in-flight 97.4 ↔ 80.0，与 OSD/meta/缓冲区/CPU 全无关
             └─ ⚑ 该双稳态幅度（−17.7%）与 03-17 要测的效应同量级，且可能与自变量同源
                  └─ 【本任务 03-17b】先定性双稳态，判 H1/H2/H3
                       └─ 再重做 03-17 矩阵设计 → 修 B4-11/B4-12 → 重跑 03-17
```

- 上游报告：`doc/perf-report/03-17-interim-abort-20260820.md`（数据与推理全在里面，执行前请读 §三、§四）
- 本任务只做定性，不做调优，不追求任何带宽数字变好。

## 〇、要验的假设

现象（分析方已从原始数据复算，不需你重复验证）：同一脚本、同一形状、同一天，判档 fio 出现两个稳定态。

| | 判档 bw | ns/B | 对象层 in-flight | 每 GET 延迟 |
|---|---|---|---|---|
| 好档 | 4144–4166 MiB/s | 3.32–3.34 | **97.4** | 5.839 ms |
| 坏档 | 2666–3002 MiB/s | 4.73–5.36 | **80.0 / 80.3** | 7.0–7.5 ms |

已排除：OSD 侧（坏档时 OSD 每 op 反而更快）、meta、读放大（恒 1.000×）、GET 块大小（恒 256 KiB）、读缓冲区（峰值恒 ≈52 MiB）、客户端 CPU 饱和、本地缓存盘（`--cache-size 0`，本来就没开）。

三个候选机制：

| | 假设 | 判别信号 |
|---|---|---|
| **H1** | librados 建连时把连接轮转绑到 `msgr-worker`，3 个 worker 对 6 个 OSD 连接分配不均（如 3/2/1），单个 worker 成瓶颈 | 坏档轮次的 `msgr-worker-N` 逐线程 CPU 严重不均 |
| **H2** | 线程的 CPU / NUMA 落位不同（128 逻辑 CPU、2 socket、NUMA 按奇偶交错） | 坏档与线程所在 CPU / NUMA node 相关，而 worker 之间 CPU 是均衡的 |
| **H3** | 客户端对象层存在全局串行点（objecter 锁），in-flight 天然卡 80 | H1、H2 都不成立时的兜底 |
| **H4（新增）** | 会话继承的 CPU 亲和掩码不同：157 实为 **128 逻辑 CPU（0-127）**，但 SSH 会话被限制在 **96 个**（实测掩码 `0,17-64,81-127`，缺 1-16 与 65-80）。掩码随 session scope 走，**不同会话可能不同** | 坏档轮次线程只落在掩码的某个偏斜子集；亦可解释 F55 会话间慢漂移 |

**你不需要判断哪个成立。** 你只负责把 8 轮的原始证据取全，判读由分析方做。

## 一、目标

在**完全不改任何参数**的前提下，反复"新挂载 → 判档形状 fio → 卸载"8 次，取到每一轮的：档位（ns/B）、逐线程 CPU、线程 CPU 落位、对象层指标、OSD 侧指标。

## 二、⚑ 与 03-17 最不一样的一条：坏档不停机

03-17 的脚本在判档 FAIL 时会 `exit 1`。**本任务不会，也不允许。**

- 档位是本任务的**观测对象**，不是准入门槛。
- 你会在日志里看到 `GATE I1 ns/B=5.362 ref=3.287 verdict=FAIL(坏档,须重挂)` —— 这是**期望中的输出**，是本任务要抓的东西。
- 脚本会照常打 `DONE T48-iterN ...（tol 18% 仅供参考，本任务不据此停机）` 然后进入下一轮。
- **看到 FAIL 不要中断、不要重挂、不要重跑、不要问要不要停。** 8 轮必须跑完。
- 如果 8 轮**全是好档**或**全是坏档**，同样是有效结果，照常回传，不要为了"凑出两种档位"而加轮次。

## 三、固定环境

| 项 | 值 |
|---|---|
| 机器 | 157（`ssh thailand`），157 时间 = WSL − 1h |
| 二进制 | `/tmp/juicefs-03-8`，md5 **`de93563f11a5ff3bd94dd25a4e0283b1`** |
| 判别器 | `/tmp/t39-nsbgate.sh`（md5 `cd19b4691b2eb6566c12d280b4adfe2f`） |
| 环境快照 | `/tmp/env-snapshot.sh`（md5 `b6d1c556e43b183c43ea3fdc7de49cd7`） |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K`（与 03-16/03-17 逐字符相同） |
| 专用挂载点 | 只用 `/mnt/juicefs-p` |
| fio | 必须 3.28 |
| 期望线程数 | `msgr-worker=3`、`io_context_pool=2`（**系统默认**） |
| 输出目录 | `/tmp/production/opencode-t3.17b` |

### ⛔ 绝对不许做的事

1. ⛔ 不修改 `/etc/ceph/ceph.conf`（全机共用），不执行 `ceph config set`。脚本起止两次核 md5，应恒为 `5b6be34179a64e0a5f9c6d3a9690041f`。
2. ⛔ **不写任何私有 conf，不设 `CEPH_CONF`。** 本任务全程系统默认，这是与 03-17 的根本区别 —— 一旦注入参数，好坏档的对照就没了。
3. ⛔ 不改 `objecter_inflight_ops` / `objecter_inflight_op_bytes` / `--max-uploads` / `--max-fuse-io` / `--cache-size`。
4. ⛔ 不动业务挂载 `/mnt/juicefs`，不卸载它，不在它上面跑 fio。
5. ⛔ 不做 `juicefs gc`、`compact`、任何写操作、任何重启。fio 全程带 `--readonly`。
6. ⛔ 不为了"修好坏档"做任何干预（不 drop 别的缓存、不改 CPU 亲和、不 renice、不 taskset）。
7. ⛔ 不改脚本。需要改动一律回报，由分析方改。

## 四、迭代设计

8 轮，每轮：`健康检查 → 对象数 → 新挂载（系统默认）→ 数据集完整性 → drop_caches（client+3 节点）→ OSD 快照 → 逐线程快照 → fio 180s → 逐线程快照 → OSD 快照 → 健康检查 → 卸载 → 间隔 20s`。

| 轮次 | 特殊处理 | 用意 |
|---|---|---|
| 1 | 无 | 会话首个挂载（03-16 的首挂载都是好档） |
| 2、3、4 | 无 | 测"是否随挂载序号/累积读量退化" |
| **5** | **挂载前先空转 180s** | 测坏档能否靠"歇一会"自行脱离 |
| 6、7、8 | 无 | 补样本，看档位是否随机 |

判档 fio 形状与 t46/t47 的判档 fio **逐字符相同**（`mseqread` / `bs=256k` / `numjobs=16` / `direct=1` / `psync` / `iodepth=1` / `size=4G` / `runtime=180` / `--readonly`），因此 ns/B 与 `REF_NSB=3.287` 同口径、与 03-16/03-17 可直接并表。

预计时长：8 × (180s fio + ≈55s 前后置) + 180s 空转 ≈ **35~40 分钟**。属短测，白天可做。

## 五、执行步骤

### 步骤 0：只读安全扫描（先做，结果发我）

```bash
ssh thailand
date; cat /proc/loadavg; who | wc -l
mount | grep juicefs                      # 应只有业务挂载 /mnt/juicefs
pgrep -af 'fio|t4[0-9]-' | grep -v pgrep  # 应无残留
md5sum /etc/ceph/ceph.conf                # 应 5b6be34179a64e0a5f9c6d3a9690041f
md5sum /tmp/juicefs-03-8                  # 应 de93563f11a5ff3bd94dd25a4e0283b1
sudo ceph -s | head -8
df -h /tmp | tail -1
```

### 步骤 1：拷脚本，双端核 md5

脚本由分析方提供，md5 **`65aba1ba4fd3920f9b12eb890fc113b7`**，落到 157 的 `/tmp/t48-mount-state-worker-balance.sh`。
拷完自己核一遍；**不一致就停下来问，不要自己改**。

### 步骤 2：管路冒烟（1 轮 30s，约 2 分钟）

目的只有一个：确认管路通、产物齐，**不产出可用数据**。必须用独立 OUT，绝不能写进正式目录。

```bash
ACK_SUDO_WRITES=YES ITERS=1 RUNTIME=30 RECOVER_ITER=0 \
  OUT=/tmp/production/opencode-t3.17b-smoke \
  bash /tmp/t48-mount-state-worker-balance.sh full
```

自查（把这 6 项的实际值发我）：

1. `params.txt` 里应有 `SMOKE=YES`（证明脚本自己识别出这不是标定形状）。
2. `wrapper.log` 有 `MOUNT iter1 ... msgr-worker=3 io_context=2`。
3. `iter-1/threads-pre.tsv` 与 `threads-post.tsv` 都存在，且各含 3 行 `msgr-worker-*` + 2 行 `io_context_pool`。
4. `iter-1/threads-series.tsv` 行数 > 1，且第 6 列（processor）是 **0~127** 的整数，并且落在本会话亲和掩码内（实测 `0,17-64,81-127`）。⚑ 订正：~~0~95~~ —— 157 是 128 逻辑 CPU，`nproc` 报 96 是会话掩码所致，**看到 >95 的值属正常，不是异常**。
5. `iter-1/i1.tsv`、`iter-1/fio.txt`（含 `READ: bw=`）、`iter-1/conns-pre.txt`、`osd/` 下 12 个 json 都在。
6. 结尾有 `ALL DONE`。⚑ 订正验收口径：**`ALL DONE` 单独不足以证明跑完** —— 脚本第 538 行才打印 `ALL DONE`，而 `MANIFEST.md5`、`$OUT.tar.gz`、`$OUT.tar.gz.md5` 是 539-541 行生成的（缺陷 B4-13，暂不改，避免 md5 变动）。判"跑完" = **`ALL DONE` + `tar.gz` + `tar.gz.md5` 三者同时存在**。反之，缺 `ALL DONE` 也不等于数据不全（可能是 SIGHUP 打在 538-541 之间）。成功路径不打印 `exit rc=0`。
7. ⚑ 判档行会出现 `verdict=FAIL(坏档,须重挂)` 且**门槛看起来不是 18%** —— 这是共享判档器 `t39-nsbgate.sh` 的默认 `NSB_TOL=10` 在说话（缺陷 B4-14）。t48 用自己的 `TOL_NSB=18` 记进 `iters.tsv` 且**不据此停机**，两者不一致属已知、不影响本任务，**不要去改判档器**。

冒烟完成后：`rm -rf /tmp/production/opencode-t3.17b-smoke*`，避免与正式目录混淆。

### 步骤 3：无状态清点

```bash
bash /tmp/t48-mount-state-worker-balance.sh --preflight
```
把 `preflight-summary.txt` 全文发我（含对象数、fio 版本、落盘空间、背景监控数应为 0、期望线程数、预计时长）。

### 步骤 4：拿到用户对步骤 0/2/3 的明确确认后，跑正式轮

⚑ 必须用下面这条**完整命令**（先记录启动 shell 的亲和掩码，再启动）。掩码由挂载进程继承、全程不变，是 H4 的唯一证据，脚本里没抓：

```bash
{ echo "launcher_pid=$$"; taskset -cp $$; grep -E 'Cpus_allowed_list|Mems_allowed_list' /proc/self/status; \
  echo "nproc=$(nproc)"; echo "online=$(cat /sys/devices/system/cpu/online)"; } \
  > /tmp/production/opencode-t3.17b/cpus-allowed-launcher.txt 2>&1
ACK_SUDO_WRITES=YES nohup bash /tmp/t48-mount-state-worker-balance.sh full \
  > /tmp/t48-nohup.log 2>&1 &
```

⛔ 不要 `taskset` / `numactl` 改掩码，只记录现状。⛔ 不要在别的会话里再开一个 shell 跑（掩码会不同）。

执行中每完成 2 轮报一次进度，只报机械状态：`iters.tsv` 的行数与最后一行原文。**不要解读 ns/B，不要说"这轮好/这轮坏"以外的判断，不要算平均值。**

### 步骤 5：命中 STOP 时

保留现场（⛔ 不删 OUT、不卸载残留、不重跑），把 `wrapper.log` 最后 30 行 + STOP 那一行原文发我。

## 六、STOP 条件（脚本会自动停，你不要自己加判断）

1. `/etc/ceph/ceph.conf` md5 变化。
2. 业务挂载 `/mnt/juicefs` 身份（挂载行 / PID / starttime）变化。
3. Ceph 非 `HEALTH_OK`，且不是"唯一告警为 clock skew 且 ≤0.5s"。
4. 起点对象数 > 3,110,000。
5. 轮内对象数**上涨**（只读任务不该产生对象）。
6. 轮内对象数**下跌 > 1000**（疑似真删数据）；下跌 ≤1000 只记录到 `objects-shrink.tsv` 并继续。
7. 对象数不可解析。
8. `msgr-worker` ≠ 3 或 `io_context_pool` ≠ 2 —— 意味着共享配置被人改动，本任务对照失效。
9. 挂载失败，或 `max_read` ≠ 262144。
10. 实例漂移（轮内 PID/starttime 变化）。
11. 数据集不完整（`mseqread` 不足 16 个文件）—— ⛔ 绝不允许让 fio 补写布局。
12. fio 返回码非 0，或缺 `READ: bw=` 汇总行，或 bw log 不足 16 个。
13. ns/B 不可解析。
14. fio 版本非 3.28，或落盘空间 < 5120 MiB。
15. OSD `perf dump` 预探失败。
16. OUT 已含证据或归档已存在（防混批）。

**不在 STOP 条件里的**：ns/B 超出 ±18%（坏档）。这是观测对象，见 §二。

## 七、必须回传的原始证据

只回传，不解读：

```
/tmp/production/opencode-t3.17b.tar.gz
/tmp/production/opencode-t3.17b.tar.gz.md5
```

包内应含（脚本自动生成，你核对存在性即可）：

- `wrapper.log`、`params.txt`（应 `SMOKE=NO`）、`input-md5.txt`、`MANIFEST.md5`
- `iters.tsv`（8 行数据）、`instances.tsv`（8 行）、`probe-gate.log`
- `iter-1` … `iter-8/`，每个含 `threads-pre.tsv`、`threads-post.tsv`、`threads-series.tsv`、`i1.tsv`、`fio.txt`、`net.tsv`、`conns-pre.txt`、`conns-post.txt`、`objects-pre.txt`、`objects-post.txt`、`host-state-pre.txt`、`host-state-post.txt`
- `threads/iter*-comm.txt`（8 个）
- `osd/`：8 轮 × 前后 × 6 OSD = **96 个 json**
- `bwlog/`：8 轮 × 16 = **128 个 bw log**
- `cpu-topology.txt`（`lscpu` + NUMA cpulist + 每 CPU 的 package id）
- `objects-initial.txt`、`objects-final.txt`、`objects-shrink.tsv`、`objects-raw.jsonl`
- `health-*.txt`、`conf/ceph.conf.system-{before,after}`、`conf/sysconf-checks.tsv`

## 八、合规自查（回传前逐条打勾）

- [ ] 全程未写任何私有 conf，未设过 `CEPH_CONF`（`history` 里搜不到）。
- [ ] `/etc/ceph/ceph.conf` md5 起止一致，且从未执行 `ceph config set`。
- [ ] 8 轮的 `msgr-worker` 都是 3、`io_context_pool` 都是 2。
- [ ] 判档 FAIL 出现时**没有**中断或重挂，8 轮全部跑完。
- [ ] 所有 fio 都带 `--readonly`，未跑任何写负载，未执行 gc/compact/重启。
- [ ] 业务挂载 `/mnt/juicefs` 未被卸载、未被 fio 触及。
- [ ] 冒烟目录 `opencode-t3.17b-smoke*` 已删除，未与正式目录混淆。
- [ ] `params.txt` 显示 `SMOKE=NO`、`runtime=180`、`iters=8`。
- [ ] 未对任何数据做统计、平均、百分比或结论。

## 九、回复模板

```
T48 执行完毕 / 中止于 iterN。

步骤 0 安全扫描：157 时间 __ load __ 登录用户 __ 残留 fio/t4x __ ceph.conf md5 __ 二进制 md5 __
步骤 2 冒烟：SMOKE=__ msgr/ioctx=__/__ threads-*.tsv 行数 __ processor 取值范围 __ ALL DONE 有/无 tar.gz 有/无
步骤 3 preflight：对象数 __ fio 版本 __ 落盘 __ MiB 背景监控 __
正式轮：启动 shell 亲和掩码 __（cpus-allowed-launcher.txt 已生成 是/否）
       起点对象数 __ 收尾对象数 __ 对象下跌条目数 __ 最大跌幅 __
       iters.tsv 共 __ 行；逐行原文粘贴如下（不做任何加工）：
       <粘贴 iters.tsv 全文>
产物清点：osd json __/96  bwlog __/128  iter 目录 __/8  threads-series 最小行数 __
时钟漂移事件 __ 次，峰值 __ s
自查：§八 全部打勾 / 未通过项 __
包：/tmp/production/opencode-t3.17b.tar.gz  md5 __
```

⛔ 回复里不要出现平均值、百分比、"好档/坏档占比"、"说明什么"之类的判断。分析方会从原始数据重算（历史上执行方的统计出过错，这条是硬规矩）。

## 十、本任务不做的事

- 不测任何参数旋钮（msgr 线程数、ioctx 线程数都保持默认）—— 那是 03-17 重做后的事。
- 不试图修好坏档，不做 CPU 绑核 / NUMA 绑定实验 —— 那要等本任务判出 H1/H2/H3 再单独立项。
- 不跑双挂载、不跑 P128/C64/C128、不跑写负载。
- 不改 03-17 的脚本和任务书。
- 不碰 `/mnt/juicefs` 业务挂载，不碰 TiKV，不碰 OSD 侧任何旋钮。
