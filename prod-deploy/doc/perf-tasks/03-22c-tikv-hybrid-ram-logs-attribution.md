# 03-22c 任务书：TiKV WAL/Raft RAM 隔离归因（D1）

## 日期与状态

- 日期：2026-08-27；2026-08-28 首次RUN审计后冻结重跑版并完成正式重跑
- 面向：GLM 按冻结状态机自主执行；GPT 在完成后集中审核
- 上游：`03-22b-tikv-nvme-backed-storage-attribution.md`及其最终报告
- 当前状态：**正式重跑RUN `20260828-083811`已由冻结入口完成8/8 arm、G01--G08、final destroy、生产恢复和持久归档；GPT独立审核判`EVIDENCE_VALID`。D1相对B1c带宽效应中位`+5.05%`，未过15%材料门；稳定性改善门与D1部署稳定门通过；D1中位`3756.51 MiB/s`，未达6250。**
- 当前允许动作：只读引用正式报告与归档；是否另立条件C由用户按归因价值和维护成本决定
- 当前禁止动作：不得resume、补跑或复用首次/正式RUN的已销毁seed与state；不得为改善结果重跑R01--R08
- 正式报告：`../perf-report/03-22c-tikv-hybrid-ram-logs-attribution-20260828.md`

> 本任务不是03-22b追加arm，也不得复用03-22b的RUN_ID。03-22b的B1数据只作跨RUN参考；03-22c必须在同一新RUN内重测B1c控制臂。

### 正式重跑结论（2026-08-28）

重跑归档`results/opencode-t3.22c-20260828-083811.tar.gz`，SHA256=`3b5559c0ed905ba110ace02b1286a477db5b143678bad99daffa80f0e5978ba7`。8/8正式arm及全部GC/closure证据通过：B1c四臂中位`3607.63 MiB/s`，D1四臂中位`3756.51 MiB/s`；四配对效应`+6.02%/+2.40%/+4.09%/+7.14%`，中位`+5.05%`。带宽材料门失败，CV与W4/W1稳定性改善门通过，D1四臂部署稳定门通过，6250目标门失败。

机制上，B1c的Raft sync由W1约0.22--0.23 ms升到W4约0.74--0.80 ms；D1四臂始终约0.074--0.083 ms。但D1仍出现11--16 GiB pending compaction和更高的KV侧物理NVMe await，因此RAM logs只消除了同步logs路径的尾部放大，未消除KV/compaction共享服务率瓶颈。条件C和真实第二NVMe仍是独立可选问题，不进入本RUN结论。

### 首次03-22c RUN审计改判（2026-08-28）

首次RUN归档`opencode-t3.22c-20260827-232428.tar.gz`的SHA256为`1764e1b99804966bafbbedbf415dca30c3f147331c6b725fe021554f0d8cafaf`。其8个正式arm性能文件可以作为工程观察，但整个RUN不得作为正式因果证据，原因不是性能结果，而是执行合同被破坏：

1. 执行中把D1父tmpfs从34 GiB改为36 GiB、把安全阈值从95%放宽到98%，未按容量/门限变更规则重新请求批准；
2. `control/incidents.tsv`只记录初始化和一个memory字段问题，未记录OSD采样、tmpfs几何/门限修改以及G08闭包多次失败；
3. 临时生成且未进入manifest/Gate 0的编排脚本使用了`rm -rf`、lazy/forced unmount、`losetup -D`和宽范围进程清理；
4. R08完成后G08出现多次create/start/stop闭包尝试。按本任务“R01后任一非性能失败即整RUN无效”的预注册规则，当时必须进入invalid closure，不能修复重试后签`normal`；
5. 因此首次RUN汇总中的`EVIDENCE_VALID`、`无补跑替换`和`skill合规`均撤回。4/4配对方向为D1较高、效应中位`+2.32%`只保留为非正式工程观察。

重跑必须使用新RUN_ID和新formal seed；首次RUN归档保持只读，不覆盖、不删除，也不得把其中任何arm替换进重跑矩阵。

```text
03-18~03-21  单inode同步事务下界与TiKV/NVMe争用归因
      ↓
03-22          RAM/RAM逻辑隔离：工程观察，正式矩阵失效
      ↓
03-22b         同一物理NVMe：A1/B1在R03 CV硬门失败，invalid闭包完成
      ↓
F77：轮内compaction + WAL/Raft共享NVMe软排队；跨轮残差未唯一归因
      ↓
03-22c 同窗B1c/D1八臂正式重跑（已完成）
      ├─ 带宽：4/4正向、中位+5.05% < 15%材料门
      ├─ 稳定性：CV与W4/W1均4/4改善
      └─ 结论：logs是尾部放大因素，不是剩余带宽主墙
```

一句话目标：在KV数据路径保持NVMe不变的前提下，仅把TiKV RocksDB WAL与Raft Engine的32 GiB backing从同一物理NVMe迁到RAM，判断移除logs物理设备延迟及共享NVMe争用是否能稳定提升256-inode randwrite。

---

## 〇、背景与为何必须同窗重测B1

03-22b的B1中，`b1-kv.img`与`b1-logs.img`虽然位于两个独立loop/ext4，但父文件系统都在每节点同一`/dev/nvme1n1`。两者可分离部分loop、ext4 journal和上层worker/queue资源，最终I/O仍汇聚到同一NVMe namespace、控制器、硬件队列池和介质；它不是物理分盘。

03-22b正式矩阵没有完成：R01/A1=`3709.03 MiB/s`、CV 6.83%；R02/B1=`3651.45 MiB/s`、CV 8.52%；R03/B1 median仍为`3651.23 MiB/s`，但CV升至`10.701303%`，因此R04--R08停止，整个RUN为`EVIDENCE_INVALID`。这组结果不能签收A1/B1效应，却提供了D1的直接动机：R03 W1→W4期间pending compaction由0.12升至11.29 GiB、底层NVMe `w_await`由2.60升至18.05 ms、Raft sync由0.168升至0.763 ms，带宽由3811.0降至3329.6 MiB/s；hard stall始终为0。直接触发层是轮内compaction与WAL/Raft共用物理NVMe形成的软排队。

把logs backing改到RAM可以构造有价值的混合介质探针，但同时移除了两项因素：

1. NVMe logs本身的设备服务延迟；
2. logs与KV对同一物理NVMe控制器、队列池、FTL和介质的争用。

因此D1只能判断这两项组合是否重要，不能证明真实第二块NVMe会获得同等收益。

即使复用03-22b的布局合同、二进制、配置和jobfile，跨RUN仍可能存在日期、Ceph/OSD状态、NVMe后台状态、内核调度、临时TiKV起点和维护窗口漂移。03-22b的B1不足以作为D1唯一因果分母。03-22c必须重测同窗B1c；A1改变了“共享/独立文件系统”变量，不是D1的最小差异对照，无需重测。

03-22b结束时formal seed已按`mode=abort-invalid-run`销毁，pool objects回到pre-format附近；归档中虽有metadata dump、layout manifest和content anchors，但对应的524288个Ceph数据对象已经删除。因此03-22c只能复用**布局、job和校验合同**，不能把旧dump当成仍可用的数据seed直接load。

---

## 一、目标、正式问题与推断边界

### 1.1 唯一正式因果问题

在相同主机、相同fresh临时TiKV、相同Ceph pool、相同immutable seed/clone、相同KV NVMe backing、相同TiKV/JuiceFS配置和相同256-inode randwrite下：

> D1（KV在NVMe、WAL+Raft在RAM）是否稳定、材料性优于B1c（KV与WAL+Raft分别位于两个loop/ext4，但底层共享同一NVMe）？

### 1.2 同时报告但不作为主因果门的问题

1. D1四臂中位带宽是否达到网卡半速`6250 MiB/s`；
2. B1c相对03-22b B1的跨RUN漂移方向和幅度；
3. D1对TiKV transaction、RocksDB WAL sync、Raft、KV engine、底层NVMe await/queue/util和CPU/memory的影响；
4. D1提升仍不足6250时，剩余差距能否由per-inode同步事务周期解释；
5. 03-22 RAM/RAM、03-22b A1/B1、历史H只作分层工程参照，不使用同窗因果措辞。

### 1.3 结论边界

| 观察 | 允许结论 | 不允许结论 |
|---|---|---|
| D1显著高于B1c | logs介质服务时间或与KV共享NVMe的争用是重要因素 | 第二块NVMe必然获得相同提升 |
| D1≈B1c | 在当前负载下移除logs NVMe路径没有可辨识材料收益 | 所有物理分盘方案都无效 |
| D1提高但仍低于6250 | 存储路径有贡献但同步架构下界仍存在 | 继续无界扫描局部参数即可达标 |
| D1 CV/W4/W1不稳定但证据完整、环境健康 | 保留为正式稳定性结果，与B1c按预注册端点比较 | 因结果不好删除arm或停止矩阵 |
| 容量/内存/身份/健康/采集门失败 | 本RUN无正式因果结论 | 挑选好轮次或用03-22b B1替换控制臂 |

真实双NVMe、03-22b条件C和D1是三个不同问题，必须分别报告，不能合并为一个“存储隔离效应”。

---

## 二、冻结变量与正式矩阵

### 2.1 两臂唯一差异

每节点均保持KV路径、logs容量、loop/ext4层和TiKV配置一致：

| 臂 | KV data | RocksDB WAL + Raft Engine | 上层文件系统 | 变量 |
|---|---|---|---|---|
| B1c | 96 GiB实际预分配NVMe backing file | 32 GiB实际预分配NVMe backing file | 两个独立loop/ext4 | 同一物理NVMe控制 |
| D1 | 同一96 GiB NVMe backing合同 | 32 GiB实际预分配tmpfs backing file | 两个独立loop/ext4 | 仅logs底层改为RAM |

B1c两个backing的父设备必须是当前节点`/dev/nvme1n1`。D1的KV backing仍在该设备；logs backing必须位于本实例精确命名、fresh挂载的tmpfs，不能放到系统`/tmp`、生产路径、Ceph OSD盘或裸块设备。

D1不得直接把TiKV logs目录放在tmpfs上；必须采用“**36 GiB父tmpfs**中的实际预分配32 GiB文件 → 动态loop → 与B1c相同参数的ext4”，尽量只改变底层介质。父tmpfs多出的4 GiB只作为配额/文件系统记账余量，不改变32 GiB backing和32 GiB logs ext4的因果变量。禁止sparse truncate。

### 2.2 不重测A1的理由

- B1c与D1都使用独立KV/logs loop/ext4，仅logs backing介质不同，构成最小差异。
- A1把KV/WAL/Raft放在同一文件系统，会额外改变文件系统、journal和worker共享关系；加入主比较会混杂变量。
- 03-22c报告可引用03-22b A1作为历史上下文，但不得把A1↔D1写成同RUN单因素效应。

### 2.3 seed与工作负载

- 从03-22b最终归档导入并冻结JuiceFS二进制、fio job、256行layout manifest和256行content anchors的合同及SHA；旧metadata dump仅用于结构审计，**不得作为有存活数据对象的seed加载**。
- 新RUN必须且只允许创建一次新的formal immutable seed：新format/mount后按冻结合同执行一次完整layout与prepare，生成新的metadata dump、`seed.tsv`、layout manifest和content anchors，并在157持久目录及本地archive staging中双份SHA核对。正式seed创建完成后禁止再次layout。
- 每臂向fresh metadata namespace load该新RUN的同一dump，再从immutable`/seed_layout` clone到`/test_dir`；正式写只允许修改clone。若新seed的文件数、文件大小、anchors、pool对象数或dump/load/clone合同与冻结值不符，必须在正式矩阵前停止。
- JuiceFS二进制、MD5、mount参数、私有Ceph参数、fio `B0.fio`及其SHA与03-22b完全一致；若必须变化，停在设计层重新批准。
- fio固定：randwrite、256 KiB、256 job/256 inode、iodepth 64、direct=1、runtime 180秒、allow_file_create=0、create_on_open=0。
- 正式统计窗固定为实际I/O起点后的`[15,175)`，保留256个per-job 1秒BW log并按时间戳重叠求和。

### 2.4 正式顺序与配对

正式矩阵固定8臂、4个相邻配对，采用平衡顺序：

```text
R01=B1c, R02=D1,
R03=D1,  R04=B1c,
R05=D1,  R06=B1c,
R07=B1c, R08=D1
```

配对固定为`(R01,R02)`、`(R03,R04)`、`(R05,R06)`、`(R07,R08)`；每对统一计算：

```text
effect_pct = 100 × (BW_D1 - BW_B1c) / BW_B1c
```

不得按结果改顺序、改配对、用03-22b B1替换失败的B1c或补跑替换坏臂。

### 2.5 预注册判据

#### 2.5.1 非性能证据有效门

正式因果比较要求8/8 arm全部通过以下证据门：

| 判据 | 阈值 |
|---|---:|
| 正式覆盖 | 256/256 BW logs；160秒正式窗内node/client采样≥152点且相邻间隔≤2.5秒，TiKV/PD/OSD 5秒采样每对象≥29点且相邻间隔≤10秒 |
| 身份与时间轴 | RUN/instance、PID/starttime、UUID/Name/session、loop/backing/mount和I/O起点全部唯一且一致 |
| TiKV本地容量 | 所有role `<70% used`且`avail ≥8 GiB` |
| D1内存门 | 无swap-in/out，tmpfs/backing身份不变，MemAvailable不低于冻结安全线 |
| 健康 | Ceph HEALTH_OK，OSD全up/in，TiKV stores/regions稳定，disk status为Normal |
| local reset | 每臂fresh FS几何回基线±256 MiB，无旧实例目录 |
| seed return | pending/leaked/skipped=0，pool objects回seed±8192 |
| 运行错误 | fio、sampler、TiKV、NVMe、loop和文件系统无EIO/OOM/证据缺失 |

CV与`W4/W1`不再属于证据有效门。只要arm完整、身份正确、环境健康，即使CV>10%或`W4/W1<0.90`，该arm仍保留在正式稳定性比较中；这是本任务要测的结果，不能因“不稳定”而删除控制臂。任一非性能证据门失败则整RUN无正式因果结论，禁止补跑替换。

#### 2.5.2 性能、稳定性与部署验收端点

所有8个arm均报告median、mean、CV、W1--W4、`W4/W1`、最低秒和bottom-decile。预注册判据为：

1. **带宽材料门**：四个配对至少3个`D1>B1c`，且四配对带宽效应中位数`≥15%`；
2. **稳定性改善门**：四个配对至少3个D1的CV低于B1c，且四配对`CV_B1c-CV_D1`中位数`≥2.0`个百分点；同时至少3个D1的`W4/W1`高于B1c，且四配对差值中位数`≥0.03`；
3. **D1部署稳定门**：D1四臂全部满足CV`≤10%`且`W4/W1≥0.90`；
4. **目标门**：D1四臂median的中位数`≥6250 MiB/s`。

四类结论分别报告，不相互替代。D1可出现“带宽无材料提升但稳定性改善”“带宽提升但未达部署稳定门”或“稳定且材料提升但仍未达到6250”等组合，不得压成单一PASS/FAIL。

03-22c B1c与03-22b B1的差异只报告为跨RUN复现性指标，不作为本RUN D1↔B1c因果结论的否决或替换条件。

---

## 三、容量、内存与稳定性合同

1. 新RUN只在每节点NVMe上实际预分配`96+32=128 GiB`的B1c文件；创建前后保留不低于03-22b的生产空间reserve。不得复用03-22b已销毁或旧RUN backing。
2. D1每节点使用36 GiB配额的父tmpfs承载实际分配32 GiB logs backing，另有8 GiB PD tmpfs。inventory重新计算三节点MemAvailable、swap和NUMA；门固定为创建前`MemAvailable≥128 GiB`、创建后及fio全程`≥64 GiB`，不得下调。
3. tmpfs backing必须实际预分配，逐文件核对logical size、`stat %b×512`和`du -B1`；不得依赖稀疏页或内存超售。
4. 采集`MemAvailable`、`SwapFree`、`pswpin/pswpout`、NUMA、major faults及tmpfs使用量；任一swap-in/out、OOM、memory pressure异常使该arm无效。
   - D1父tmpfs另设独立保护门：`used<95%`且`avail≥2 GiB`；它只保护32 GiB backing的承载配额。
   - loop内logs ext4仍执行§2.5.1的业务容量门：`used<70%`且`avail≥8 GiB`。两套门不得混用或临场放宽。
5. 每臂重新创建本实例PD tmpfs；B1c每臂对两个精确loop重新mkfs，D1每臂重新创建logs tmpfs/backing/loop/ext4并对KV loop重新mkfs。禁止目录清理冒充reset。
6. D1 logs fresh可用空间仍需满足03-22b容量canary冻结的两倍峰值裕量，并沿用`used<70%`和`avail≥8 GiB`主动停止门。
7. 正式矩阵前必须分别完成B1c和D1完整storage/cluster/restore/clone/capacity canary；canary不进入正式统计。
8. 为拆分03-22b遗留的跨轮残差，每arm必须采集：三节点底层NVMe的只读SMART/health/temperature/controller-busy/data-units-written前后快照与fio期间iostat；Ceph OSD至少5秒粒度的op延迟、commit/apply、设备await/util、BlueStore throttle/kv-sync时间序列。采集失败属于证据门失败，不得用事后单点替代。
9. 分析器预注册把fio逐秒带宽的bottom-decile及W1--W4与TiKV compaction/pending、WAL/Raft sync、NVMe queue/await和OSD指标按统一I/O起点对齐；报告相关性与时间顺序，但不得仅凭相关系数宣告单因素因果。

---

## 四、执行步骤（当前均未授权）

### 4.1 GLM自主执行、问题留痕与授权模型

本任务默认采用“维护窗口一次授权 + 已冻结状态机自主批量执行”，不再要求每个正常子命令、canary或正式arm都返回GPT等待。GLM负责从Gate 0、inventory/plans、canary、formal matrix、closure到归档的连续执行和现场问题处理，GPT在最终报告、原始证据和仓库修改齐备后集中审核。放权不改变安全边界，也不授权临场改变因果变量、判据、顺序、介质、容量或清理范围。

GLM开始时必须执行`t66-autonomy.sh init <RUN_ID>`，全程维护只增不改的`control/incidents.tsv`。所有问题（包括脚本bug、预期外输出、重试、等待超时、手工调查和无害告警）必须在采取修复动作前后分别记录，字段至少包括phase、instance、严重度、症状、原始证据路径、动作、继续/闭包决策和当时脚本SHA。正常阶段用`progress`记录证据SHA；不得覆盖、删除或改写既有问题行和进度marker。

GLM可以自主修复**不改变测试合同且不扩展mutation vocabulary**的脚本实现问题，但必须遵守：先保留现场并只读定位；若存在活跃挂载/loop/临时服务，则只使用已审查的精确closure脚本恢复到静止态；在本地离线修改；重新执行完整Gate 0、生成新manifest、记录前后SHA；确认远端无活跃t66状态后才允许`resync`。禁止热替换正在运行的脚本，禁止用临场shell命令绕过失败的身份门。

重跑版进一步收紧：`t66-formal-arm-lifecycle.sh`和`t66-formal-matrix.sh`已进入manifest与Gate 0。正式矩阵只能由这两个冻结入口按R01→R08执行；它们不含自动清场、强制/惰性卸载、批量loop detach或重试。正式步骤失败时只允许写`RUN_INVALID`并保留现场，GLM随后依据精确state选择已审查的invalid closure；不得自行创建第二个编排器或shell清理片段。

正式R01开始前发现并修复实现问题，可在闭合环境后继续同一RUN；R01开始后任一非性能证据失败或实现修复需求都必须写`RUN_INVALID.tsv`、终止后续arm、按预审invalid closure恢复生产并归档，不得在同一RUN补跑或替换。CV/W4/W1表现不好不是实现问题，也不触发停止。

交付GLM前由GPT签收第1项；GLM先自主完成第2项并向用户呈交一次维护窗口总计划，用户批准后第3--6项不再逐步等待GPT：

1. 25文件`t66-*`完整包、manifest和离线Gate 0首次通过；
2. 只读inventory、全部sudo plans、容量/内存公式和生产stop/start计划；
3. 首次单节点B1c/D1 backing/loop/ext4（含D1 tmpfs）完整生命周期；
4. 三节点B1c/D1完整cluster→restore/clone→B0→GC/pool/local reset canary；
5. 正式矩阵前的环境冻结与固定顺序八臂；
6. 最终destroy、生产恢复和证据归档。

维护窗口批准后，GLM可在无需逐臂等待的情况下连续执行canary和R01→R08，但只有前一阶段/arm同时具备全部closure marker时才可进入下一项：analyzer完成并报告全部性能端点、非性能证据门通过、graceful umount/stop完成、GC seed return通过、pool回基线、本地storage回fresh baseline、Ceph/OSD/TiKV/内存门全绿、原始证据已落盘且SHA manifest完成。CV>10%或`W4/W1<0.90`只写入性能结果，不阻断下一arm；每臂结束写独立只增不改的进度摘要，正常通过不要求人工回复。

R01--R02首个完整配对闭合后由GLM自动执行证据合同复核并写marker；通过即继续R03--R08，不需要人工响应。复核失败按`RUN_INVALID`路径闭包，不得根据带宽调整后六臂。

进入R01前还必须由`t66-autonomy.sh formal-ready`把维护窗口批准证据、最终manifest SHA及全部seed/preflight/canary marker固化为`control/FORMAL_MATRIX_AUTHORIZED.tsv`；缺该marker时正式编排器必须拒绝运行。

以下任一情况必须fail-closed并停止当前测试动作；GLM可自主只读调查并执行事先审查的精确closure，但不得补跑、跳过或带着活跃环境改脚本：

- manifest/SHA、RUN/instance/token、PID/starttime、UUID/Name/session、loop/backing/mount或生产指纹不一致；
- 出现任务书未列出的sudo命令、需要shell手工绕过、热同步脚本或改变变量；
- fio/sampler/analyzer证据不完整，或身份、容量、memory/swap、health/readiness/quiet任一**非性能证据门**失败；CV/W4/W1越过部署阈值本身不触发本条；
- GC、pool return、本地baseline return或上一arm closure缺失；
- 超时、进程异常、EIO/OOM、Ceph异常、生产服务意外变化；
- 正式arm中途被中断。中断arm直接判无效，不允许从中点resume或用补跑替换。

失败后GLM使用维护窗口总授权中已签收的token和精确脚本完成closure；若现状超出预审脚本可证明处理的范围，则保持现场并向用户求助，禁止扩大sudo或清理目标。正常8/8完成后自动进行最终销毁、优先恢复生产、离线分析和归档，不因等待GPT审核延长停机。

### 步骤0：测试前skill合规确认

通读并记录`skills/SYSTEM-SAFETY-SKILL.md`、`skills/TESTING-GUIDE.md`、`skills/test-commands-reference.md`、`skills/baseline-reproduction-skill.md`、`skills/LONG-RUNNING-TEST-SKILL.md`及03-22b任务覆盖规则。明确本任务禁止全局drop_caches、OSD restart和重复layout；冷态由`direct=1 + cache-size=0 + immutable seed`保证。

### 步骤1：导入03-22b最终结论与合同

核对03-22b archive外层SHA=`7cd9e57276a19b2ee17966b369bc3a0fac75da3869582ae226689b8e225ac137`及内部manifest，冻结JuiceFS/fio/layout/anchor合同、R01--R03统计、环境指纹和F77未决问题。必须显式记录旧formal seed已销毁、旧数据对象不存在；禁止把旧metadata dump列为可直接load的活seed。

### 步骤2：离线实现与Gate 0

新建独立`t66-*`脚本与新RUN作用域；实现B1c/D1 storage plan/create/activate/deactivate/destroy、tmpfs实际分配和swap/memory门、cluster/新seed/restore/runner/GC/finalize，以及NVMe SMART与Ceph OSD时间序列采集和统一时间轴分析。完成语法、负向测试、危险命令扫描、sudo命令全集和调用图。Gate 0后暂停签收。

### 步骤3：只读inventory与sudo plans

重新采集157/150/151/152生产指纹、NVMe父设备、内存/swap/NUMA、容量、端口、进程、Ceph/TiKV健康；输出生产stop/start、B1c/D1 storage、每arm lifecycle和最终destroy的逐节点plan。不得执行写操作。

### 步骤4：维护窗口与生命周期canary

单独授权停止生产TiKV，生产PD保持运行。先在单节点闭合B1c和D1 create→activate→deactivate→destroy，再做三节点B1c/D1临时集群smoke。任何失败先安全closure，不进入formal seed。

### 步骤5：创建一次新immutable seed并完成clone/GC canary

先以小规模canary验证format/layout/prepare/dump/load/clone/GC状态机，销毁canary数据；随后按§2.3在本RUN中执行且仅执行一次正式format、完整layout和prepare，生成新的immutable seed bundle并双份持久化。之后分别验证B1c/D1从该新dump执行load、mount、clone COW、source anchors、GC inspect/delete/seed return和本地baseline return；正式seed不得在arm间销毁或重写。

### 步骤6：容量与长跑canary

使用同一B0负载分别验证B1c与D1，重点冻结D1 RAM logs峰值、swap/memory压力和B1c NVMe logs峰值。canary数据不进入正式矩阵。

### 步骤7：八个正式arm

严格执行§2.4顺序和§4.1批量授权合同。每arm状态机沿用03-22b：fresh storage→fresh cluster→load seed→mount/clone→capacity/health/quiet→single fio+samplers→analyzer→graceful closure→fresh GC return→local baseline return。前一arm未完整闭环不得进入下一arm；非性能证据门通过后可自动推进，非性能门失败必须原地暂停；CV/W4/W1越过部署阈值只记录结果，不停矩阵。

### 步骤8：分析与结论

独立复算8臂正式窗、四配对带宽与稳定性效应、CV/W4/W1/bottom-decile、TiKV日志路径延迟、KV/NVMe指标、Ceph OSD时间序列和RAM内存指标；按统一I/O起点做W1--W4与低谷对齐，分别判定§2.5的带宽、稳定性、部署和6250目标端点。不得把D1写成真实第二NVMe等效结果。

### 步骤9：最终closure与生产恢复

完成所有临时volume/GC/storage清理、空间和内存回归，优先恢复三节点生产TiKV并全局验证，再做离线分析和归档。禁止因等待GPT分析延长生产停机。

### 步骤10：测试后skill合规复核

逐条确认无pool delete/create、OSD restart、全局drop_caches、重复layout、sparse backing、生产路径写入、隐式rollback和补跑替换；所有sudo phase、compact/cooldown、capacity/memory、seed/pool/local baseline return和正式统计证据完整。

---

## 五、交付物

- 任务脚本：`scripts/FULLBASELINE/debug/t66-*`
- 原始结果：`/tmp/production/opencode-t3.22c-<RUN_ID>/`
- 正式报告：`doc/perf-report/03-22c-tikv-hybrid-ram-logs-attribution-<YYYYMMDD>.md`
- 更新：`doc/perf-analysis/03-juicefs-parameter-tuning-execution-plan.md`与`doc/deploy-log/results-table.md`
- 原始包：`results/prod-stage03-raw-<YYYYMMDD>/opencode-t3.22c-<RUN_ID>.tar.gz`及SHA256

每个arm至少保留：完整命令、环境快照、fio stdout/stderr、256份BW logs、I/O起点、supervisor状态、客户端/三TiKV节点metrics、pidstat/iostat、NVMe/loop/df、RAM/swap/NUMA、PD store status、seed/clone manifests和GC/local reset证据。

---

## 六、通用注意事项与本任务覆盖

1. **统计**：只认实际I/O起点后`[15,175)`、256份per-job日志按时间戳重叠求和后的稳态中位；禁止单log乘jobs、fio全程平均或挑轮次。
2. **冷态**：本任务明确禁止全局drop_caches；使用`direct=1 + cache-size=0 + immutable seed/clone`，报告记为经任务覆盖的`N/A`。
3. **fresh-volume**：新RUN只允许一次正式format/layout/prepare以创建新immutable seed；seed冻结后禁止再次layout或`create_on_open`，每臂load同一新dump并clone，正式写只修改clone。
4. **后端净化**：每个写arm/GC后执行Ceph compact/cooldown，确认`compact_running=0`、`compact_queue_len=0`、`kv_sync_lat`全绿；禁止OSD restart代替。
5. **健康静置**：fio前必须Ceph HEALTH_OK、OSD全up/in、TiKV readiness连续稳定、NVMe bounded-idle、D1 memory/swap门和容量门全部通过。
6. **清理**：只使用UUID/Name/session守卫的JuiceFS destroy和fresh-seed GC return；禁止pool delete/create。loop和tmpfs只按精确state/token清理，禁止`rm -rf`、force umount和批量loop detach。
7. **记录**：每个职责目录保留commands、state、identity、SHA及原始输出；报告每个数字必须可追到文件和字段。
8. **自主修复边界**：脚本bug只可在静止态离线修复并重跑完整Gate 0/manifest；GLM可在既有mutation vocabulary内自行继续。变量、矩阵、路径、介质、容量、清理方式或sudo mutation变化必须停止并重新请求用户批准。
9. **挂载档位**：只记录active worker CV作协变量；没有预注册坏档判别器，禁止detect-and-replace、重挂剔除或按结果挑档。
10. **静置超时**：compaction/readiness/quiet/memory门在冻结上限内不收敛即停止，不得无限等待后混入不同起点。
11. **长跑监督**：监督器只告警，不自动做破坏性恢复；fio或sampler异常保留现场，当前RUN正式矩阵失效。
12. **生产安全**：生产TiKV与临时TiKV绝不并行；生产PD保持运行；生产config/systemd/data、Ceph OSD盘、157的WekaIO/网络/内核均不得修改。

---

## 七、红线汇总

1. 当前任务书只授权离线`t66-*`实现与Gate 0；任何远程mutation必须等待只读inventory/plans签收和独立新维护窗口。
2. 03-22c必须以新RUN重测同窗B1c；不得使用首次03-22c RUN或03-22b B1作D1因果分母。
3. 不重测A1；A1只作外部背景，不能与D1组成单因素比较。
4. D1只把logs backing改为RAM；KV、loop/ext4、TiKV、seed、fio及其他变量不得变化。
5. D1是“RAM移除logs设备延迟+共享争用”的组合探针，不是第二块NVMe等价测试。
6. 只允许本RUN创建formal seed时执行一次完整layout；禁止每arm重复layout、pool删除重建、OSD restart、drop_caches、sparse backing和任何生产路径写入。
7. 8/8正式arm任一非性能证据门失败即无正式因果结论；禁止补跑替换、跨RUN拼样或调整预注册判据。CV/W4/W1是必须保留的性能端点，不是删除完整arm的理由。
8. 最终先恢复生产，再离线分析与归档。
9. 正式执行只允许manifest内的两个冻结编排入口；禁止另建wrapper，禁止`rm -rf`、lazy/forced unmount、`losetup -D`、宽范围kill和任何失败后的同RUN重试。
10. 首次RUN归档中的旧helper含嵌入口令，禁止复制或执行；新包只允许从执行shell注入`T66_SSH_PASSWORD`。若旧归档访问面不受控，先轮换凭据再开维护窗口。
