# 05-3 任务书：randread / randwrite 不同 BS 曲线

> **2026-09-20追溯更新：** 原执行另发现遗漏私有8线程配置；旧矩阵及证据封存保留，由[05-3b](05-3b-random-bs-baseline-repair-and-retest.md)承接配置/仪表修复与状态受控重测，不直接续跑本页旧脚本。

> 日期：2026-09-18  
> 面向：执行方采集原始证据；第二方独立复算、写报告  
> 状态：`STANDARD_MATRIX_EXECUTED / L1_PARTIAL_FORMAL_REVIEW`；RUN `20260918-163841` 的24格与环境收口已完成，见[报告](../perf-report/05-3-random-read-write-block-size-curves-20260918.md)；可选FUSE1M筛选未触发  
> 上位计划：[05阶段计划](../perf-analysis/05-block-size-adaptive-performance-comparison-plan.md)  
> 必读：`skills/SYSTEM-SAFETY-SKILL.md`、`skills/EVIDENCE-INTEGRITY-SKILL.md`、
> `skills/TESTING-GUIDE.md`、`skills/test-commands-reference.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` 和 `TEST-DATA-LIFECYCLE-POLICY.md`。

```text
05-1    randrw 六档 BS：标准曲线已取得；1M 的 FUSE1M 有专用 L1 信号
05-1b   卷 BlockSize 联动：B64 无材料收益；B4M 净收益未证
05-2    提高 max-uploads 至 300：1M 无可复现净收益；通用配置不变
  ↓
05-3    【本任务】同一通用配置测 randread / randwrite 六档 BS 曲线
        ├─ 标准曲线有足够证据 → 05-4；出现材料信号才筛选专用挂载
        └─ 证据缺口/状态漂移 → 标注受限档位，仅针对缺口决定是否补测
  ↓
05-4    单流顺序读写 BS 曲线
05-5    多流顺序读写 BS 曲线
05-6    汇总标准/专用曲线与已有有方证据，给出适用范围
```

一句话：测清当前通用配置下随机纯读、纯写的 BS—带宽/延迟曲线；只对明确有价值的大 BS 档筛选一项挂载适配。

## 〇、最小决策与证据合同

```text
EVIDENCE_LEVEL=L1_SCREEN
SCREEN_SOURCE=05-1/05-1b/05-2 的 randrw BS 结果仅作设计先验；本任务各档结果来自本 RUN
MINIMUM_DECISION_SET=两项 × 六档 BS × 正反各一位置 = 24 个正式格；不以旧七项结果代替
SCREEN_CONTINUE=1M 档出现 FUSE 请求拆分，且通用配置的有效曲线表明值得测试 FUSE1M 时，
                对该项只做一组 FUSE256K/FUSE1M 平衡配对；见 §三
SCREEN_STOP=标准曲线完成且无适配触发即收口；适配无重复正向材料信号即停止，不扫更多参数
FORMAL_MATRIX=若要交付专用挂载或宣称精确因果效应，另立 L2 验证并做 256K 七项非劣回归
ESTIMATED_WALL_CLOCK=准备约 1–2 h；标准曲线约 4–8 h（纯 fio 72 min）；可选适配另约 1–2 h
MAX_PREP_BUDGET=优先复用 05-1/05-2 生成 fio、身份/健康及复算组件；不新建通用编排框架
MAX_EXECUTION_BUDGET=标准曲线最长 9 h；到预算仍未恢复状态时停、保留证据并报告

EVIDENCE_ROOT=/mnt/c/SunRise/test/05-3/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-05-3-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_STAGE_CLOSE
ENVIRONMENT_ASSET_CLEANUP=既有卷与两套文件长期保留；仅精确收口本 RUN 私有挂载/进程，
                          若获授权暂停 scrub 则按状态文件恢复原 flags；证据清理不授权删除卷/文件
```

## 一、目标与边界

1. 在相同客户端、同一既有 B256 卷和同一套通用挂载参数下，回答 `4K/16K/64K/256K/1M/4M` 六档 `randread`、`randwrite` 各自的带宽、IOPS、完成延迟、轮内变化与位置漂移。**六档数值是必交付物**，平台或退化也是结果。
2. 对纯读和纯写分别判断：1M 时将 `--max-fuse-io 256K→1M` 是否值得进入后续正式验证。它是专用挂载筛选，不改变通用交付配置。
3. 本任务只测 JuiceFS；不在有方环境执行、不把不同环境的绝对带宽差归因于文件系统软件。05阶段跨系统汇总由05-6完成。

## 二、固定负载与数据资产

| 项 | 合同 |
|---|---|
| 客户端/二进制 | 157；`/tmp/juicefs-1.4.1-patched`，开跑时核对 MD5 `24fae0852051c80ca571cb2f20275d46` |
| 卷 | 既有 `juicefs-prod`，BlockSize=256 KiB；先冻结 META、卷 UUID、Ceph FSID 和客户端配置 SHA |
| 通用挂载 | `--max-fuse-io 256K --max-uploads 150 --max-downloads 200 --buffer-size 300 --cache-size 0`；readahead 保持默认、writeback 关闭；同一 `CEPH_CONF`，不改服务或系统设置 |
| `randread` | 既有 `/test_dir/read_test.{0..127}.0`，128个不同 inode、每个准确1 GiB；**全任务只读** |
| `randwrite` | 既有 `/test_dir/storage_test.{0..127}.0`，128个不同 inode、每个准确1 GiB；仅这些文件允许覆盖写，不新建/截短 |
| fio | `ioengine=libaio`、`numjobs=128`、`iodepth=128`、`direct=1`、`filesize=size=1G`、`time_based=1`、`runtime=180`、`group_reporting=1`、`allow_file_create=0`、`fallocate=none`、`openfiles=128`，固定随机种子；除 `rw`、文件名前缀与 `bs` 外保持一致 |
| 日志 | 每格 fio JSON/全文、128份 per-job `--write_bw_log`、`--log_avg_msec=1000`、实际命令及起止时间；按读/写方向分别分析 |

任务开始前通过只读 inventory 验证两套资产的文件名、inode、大小、非符号链接和挂载来源。
若缺文件或大小错误，**暂停本任务**：layout 会改变后端状态，须另列精确计划和恢复窗口；不得用 `fio` 自动建文件、稀疏文件或修改 `read_test` 来补齐。
不做全机 `drop_caches`、轮间 relayout、新卷/新 pool、主动 OSD compact 或 JuiceFS GC；若起点不能通过被动恢复门，记录并停下分析。

### 2.1 标准曲线：两项各12格，必做

先完成纯读，再开始纯写，保证写入不污染纯读资产和纯读阶段的后端起点。每项的 BS 顺序固定为：

```text
256K → 4K → 16K → 64K → 1M → 4M → 4M → 1M → 64K → 16K → 4K → 256K
```

每档恰有两个位置，首尾256K同时承担本项漂移锚。每个 `randread` 格均只访问 `read_test`；
每个 `randwrite` 格均只覆盖 `storage_test`。同一项原则上保持同一挂载进程及参数；
如必须重挂，记录原因和PID/starttime/exe，不能假定实例档位等价。

先按已有05-1/05-2合同生成并展示一格的完整 fio 命令，再冻结全部24格的命令清单。
`bs=4M` 的 `randwrite` 可能出现缓冲停顿：须设置有限墙钟上限；超时/错误则标记该格无效、停止后续写格，保存现场和已完成数据，**不得临时把 buffer 提至1024后把结果填回通用曲线**。

## 三、数据判读与可选适配

### 3.1 标准曲线判读

- 主值：以 fio 实际 timed-I/O 起点对齐每 job 日志，按区间与自然秒重叠加权汇总；取 `[15,175)` 正式窗的带宽均值，同时报告中位数、CV、P10/P90和四个40秒子窗的 `W4/W1`。fio 180秒 summary 另列，专供同口径外部对比。遇到长缺口或日志积分对不上JSON，窗口记 `UNKNOWN/REVIEW`，不得插值补零或拿 summary 冒充窗口值。
- 每档列两位置原始值与区间、IOPS、fio `clat` 平均/P95/P99；256K首尾变动及各档正反变动单独列出。`>10%` 位置漂移只降低该档解释等级为 `RANGE_ONLY`，不得挑好位置或删除有效低值。
- 纯读的低速不靠写后清理修正；纯写逐格记录 pool 对象数/stored、TiKV pending-compaction、OSD compact 状态与健康，恢复门不达标则停，不把不同起点拼成一条精确曲线。主动GC/compact如确有必要，退出本任务后另定方案。
- 已有有方 randrw 六档数据**不是**纯 `randread/randwrite` 对照。历史纯读/纯写七项值只能作已披露的单 BS 旁证，不能推算本轮其他档位。

### 3.2 可选1M适配筛选

标准曲线完整且实际 FUSE 请求粒度证明1M应用I/O仍受256K挂载上限拆分时，执行方在阶段边界提交原始证据；第二方据此决定是否启动该项的 FUSE1M 筛选。每项最多一组同卷同资产的 `C1→T1→T2→C2`（C=FUSE256K，T=FUSE1M；公共配置不变），每格180秒；纯读、纯写**各自独立判断**。不对4M、buffer、readahead或卷BlockSize自动开第二轮参数扫描。

只有两位置的有效带宽同向提升，且较小效应达到 `M=max(5%,2ε)`（`ε`来自本组同臂重复变化），同时所声称的 FUSE 请求拆分确有改善，才登记 `L1_SCREEN_CONTINUE`。噪声线高于效应、两对异号或机制证据不足，一律只保留点值及 `RESOLUTION_INSUFFICIENT/INCONCLUSIVE`，停止该方向。L1不能作为生产参数修改依据；若要交付，另立L2同窗验证及七项非劣回归。

## 四、执行阶段与停点

- [ ] **步骤0：** 执行方通读本页所列 skill/规范，确认157业务红线、两套文件资产、实际口径、scrub选项和失败恢复方式。
- [ ] **阶段0，离线 Gate 0：** 最小化复用已有生成器、挂载身份/健康检查和分析组件；若新增/修改脚本，只检验变更路径（两种 `rw`、文件名、BS顺序、双方向缺省值、超时、128日志、起点/窗口和非法路径），使用历史归档已知值及起点敏感性测试自证。核对实际脚本SHA、`commands.sh`、危险命令/明文口令扫描。Gate失败不得上环境。
- [ ] **阶段1，只读开跑门：** 核对机器/挂载/卷/二进制/资产、WekaIO与其他业务、无foreign fio、Ceph完整health/OSD/PG与空间、TiKV/OSD基线；客户端 `MemAvailable≥128 GiB`，不足即不开跑；形成所有sudo写命令与scrub plan。**本任务推荐按纯读和纯写两个phase分别临时暂停 `noscrub+nodeep-scrub`，但只有精确plan经授权后才可由状态驱动助手设置；未获授权则保持原flags，保存正式窗scrub重叠证据。不得运行中换口径。**
- [ ] **阶段2，纯读12格：** 通过开跑门后本phase批量完成，逐格保存fio/身份/health及必要sampler；不因带宽低中止。phase结束先精确恢复其拥有的scrub flags，保存恢复证据。仅在安全门失败或参数选择边界暂停回传。
- [ ] **阶段3，纯写12格：** 重核资产与后端起点后批量执行；每格前检查health及恢复门，记录写后债务；达到预注册墙钟、业务资源或容量停止条件立即停止本RUN，保留归因所需现场。phase结束按相同所有权规则恢复scrub flags。
- [ ] **阶段4，条件筛选：** 第二方检查24格原始证据；只对 §3.2 触发的项执行已冻结的FUSE1M配对，单独记录RUN/phase与挂载身份；未触发则明确取消。
- [ ] **步骤末：** 按skill复核全流程合规性、写出有效性状态和限制，第二方从raw独立复算；归档唯一持久副本、更新报告及 `results-table.md`，完成环境和证据的两类收口。

阶段内允许执行方自主修复不改变实验变量的脚本/采集缺陷，必须写入append-only `incidents.tsv`、重跑离线Gate并用新RUN或attempt隔离旧证据。改变BS矩阵、卷格式、挂载参数、文件集、健康/统计判据、scrub策略或清理方式，必须先停止并重新审定。不能边跑边修、挑格或跨RUN拼效应。

## 五、有效性门、报告与生命周期

| 非性能硬门：失败则相关phase `EVIDENCE_INVALID` | 性能端点：即使难看也必须保留 |
|---|---|
| 完整身份与资产、fio `rc=0/error=0`、128份方向日志、时间锚/必要采样覆盖、Ceph/OSD/PG安全状态、无foreign fio、业务资源未越界、scrub原flags精确恢复 | 带宽、IOPS、CV、`W4/W1`、完成延迟、首尾漂移、对象数变化和PUT/GET吞吐 |

四态记录：`VALID`可报告本RUN有效区间；`EVIDENCE_INVALID`只能作工程观察；
`RESOLUTION_INSUFFICIENT`说明当前噪声无法判断小效应；`INCONCLUSIVE`说明方向不一致。
性能差本身不能触发删样。跨系统仅允许描述各自部署环境下相同fio命令的端到端观测，且双方都报告正式窗与summary，不把不同窗口相减。

交付到 `doc/perf-report/05-3-random-read-write-block-size-curves-<YYYYMMDD>.md`：两条六档曲线的每位置读数、区间、延迟与漂移；可选配对的逐项裁决；文件/卷/挂载身份；每个异常的归因；实际命令与复算公式。原始证据按 `common/`、`cells/`、`incidents/`、`derived/` 分层，每RUN只复制一次公共文件。源端/本地 SHA256、文件数和归档可读性核对并形成 `PERSISTENCE_PASS` 后，才可按审核过的精确清单处理远端临时证据；本地只保留一份权威原始真值。环境资产（挂载/进程/scrub状态）独立核对，不得随证据目录清理。

## 六、红线

- 157上的WekaIO、K8s及其他业务、内核/网卡/RoCE/md0和非本任务路径不可触碰；开跑前确认共享资源的实际负载与可用余量，不能只看剩余容量。禁止全局drop_caches、服务重启、设备/文件系统格式化、pool删除、`rm -rf`及宽作用域kill/递归chown。
- fio写操作只准落入已核实的 `storage_test.{0..127}.0`；`read_test`只读。命令在157的明确主机身份下执行，不在多级SSH中传未解析的破坏性路径。
- 任何 `sudo` 写、全局 Ceph flag 改动和破坏性环境资产清理都必须列出精确命令/目标、完成plan及单独授权；失败先保留归因现场，并优先精确恢复**本任务拥有的**全局状态。禁止强制/懒卸载或模式匹配杀进程。
- 同一标准曲线内不得修改 cache、readahead、FUSE、buffer、uploads、卷BlockSize或测试文件集。受控暂停scrub不是生产可交付配置。
