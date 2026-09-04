# 04-1b任务书：randread同池Primary负载均衡因果对照与工程锚点

## 日期与状态

> 日期：2026-09-01
>
> 状态：`TASK_REVISED / EMPTY_POOL_PRIMARY_TEMP_CANARY_PENDING / NO_DATA_LAYOUT_AUTHORITY`
>
> 执行方：GLM；GPT负责离线Gate、阶段审核和最终复算。

```text
04-1：32→64→128 PG均未过结构门；证明“只增加PG数”无效（已结束）
  → 04-1b：空64-PG池显式重排primary已过结构门（I_primary 1.125→1.03125）
       ├─ primary-temp不能在同池可逆切换：停止，不能宣称负载均衡因果效应
       ├─ 同池N/S实际OSD读负载未改善：停止，签机制负结论
       └─ 同池N/S实际OSD读负载改善：运行固定八轮N/S，判断因果效应及6250目标
```

本任务只补04-1遗漏的“显式primary控制”路径，不重复PG梯子，不重新开发整套测试框架。原版
“既有A vs 新建B”混入fresh Pool、PG数和对象布局差异，不能单独归因于primary均衡；本修订将
正式因果对照改为**同一B Pool、同一layout、仅切换实际primary**，A只保留为工程锚点。

```text
EVIDENCE_LEVEL=L0_STRUCTURE → L0.5_EMPTY_POOL_TOGGLE → L1_SCREEN → 条件升级L2_FORMAL
SCREEN_SOURCE=同一B Pool/同一layout下 W01=N,W02=S,W03=S,W04=N 的实际OSD op_r
SCREEN_CONTINUE=同池N/S实际I_op满足§三机制门
SCREEN_STOP=结构不可控或实际I_op未改善
FORMAL_MATRIX=N,S,S,N,S,N,N,S；另有H01/H02两个A工程锚点，不进入N/S因果效应量
ESTIMATED_WALL_CLOCK=空池toggle 15--30min；至L1约1.5--2.5h；升级L2后合计约3--5h

EVIDENCE_ROOT=/mnt/c/SunRise/test/04-1b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04-1b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN；升级L2后为FORMAL
REMOTE_CLEANUP=AFTER_PERSISTENCE_PASS
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=独立收口阶段、精确计划和单独授权
```

---

## 一、背景与唯一问题

04-1在同一空Pool上实测得到：

| PG数 | `I_primary` |
|---:|---:|
| 32 | 1.3125 |
| 64 | 1.21875 |
| 128 | 1.21875 |

64→128只是PG分裂，primary直方图同比翻倍，因此04-1的有效结论是：**单纯增加PG数不能自然均衡primary**。
原任务把整个Ceph集群误当作含生产Pool，禁止了显式映射手段；现场实际是纯测试环境。

Quincy现场能力清点还表明：

- 没有`pg-upmap-primary`命令，禁止按不存在的能力设计；
- 有`ceph osd pg-upmap`、`primary-temp`和`primary-affinity`；
- 本任务优先使用只作用于新空Pool的`osd pg-upmap`，不需要全局`primary-affinity`。

核心问题：

> 在同一个64-PG B Pool、同一次layout和同一批文件上，只把实际primary从自然分布切换为均衡分布，
> 能否使128-job/256KiB randread的实际OSD读负载`I_op`降到`≤1.05`，并稳定提高带宽、接近或达到
> `6250 MiB/s`？

`N/S`是本任务的因果对照；既有A与B-S之间只作工程锚点比较，不宣称为primary均衡的单因素效应。

---

## 二、实验对象与固定条件

| 条件 | 定义与用途 |
|---|---|
| H / CURRENT ANCHOR | 既有`juicefs-data`及既有128×1GiB只读文件；只读冻结，只提供同窗工程锚点 |
| N / NATURAL-PRIMARY | 同一个B Pool/同一数据集；保留B的`pg-upmap`与数据放置，用本RUN的`primary-temp`把4个受控PG的实际primary恢复到冻结自然映射 |
| S / STEERED-PRIMARY | 同一个B Pool/同一数据集；清除本RUN的`primary-temp`，由已冻结的4条`pg-upmap`提供均衡primary |

所有条件统一使用：

- `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`；
- `--max-fuse-io 256K --max-uploads 150 --cache-size 0`；
- fio `randread, bs=256k, numjobs=128, iodepth=128, direct=1, runtime=180, --readonly`；
- 同一客户端、同一Ceph集群、B固定挂载、相同drop-caches和固定等待；H锚点使用独立只读挂载；
- layout后不再改PG、upmap、文件、挂载或卷。

N/S切换只允许改变4个已预注册PG的`primary-temp`。不得删除/重加`pg-upmap`来切换条件，因为
EC acting顺序变化可能触发shard重映射和恢复流量；不得以新建第二个Pool替代同池对照。

### 2.1 B的结构合同（已通过）

1. 直接创建64 PG空Pool，不再执行32→64→128梯子；
2. EC profile、CRUSH语义、`fast_read=1`与A一致；
3. 只在`objects=0/stored=0`时应用`ceph osd pg-upmap`；
4. 每条映射保持原acting六个OSD成员完全不变，只调整顺序；
5. 目标primary计数预注册为：

```text
osd.0=10  osd.1=11  osd.2=11  osd.3=10  osd.4=11  osd.5=11
I_primary=11/(64/6)=1.03125
```

把10个primary固定给历史`op_r/s`最高的osd.0和osd.3；该选择在本任务书中预注册，不根据本RUN性能改动。

若现场OSD集合不是精确`0..5`、任一PG acting集合不是这六个OSD、或命令不能形成上述映射，
直接停止，不动态换目标、不删除重建Pool搜索pool_id。

`primary-affinity`在纯测试集群并非安全禁区，但会同时影响H和其他Pool，破坏本任务同池N/S，
因此不在本RUN中使用；若`pg-upmap`不可行，另行设计，不现场切换方案。`ceph config set`也不作
一刀切禁令，但本任务无使用需求；只有最终删除空测试Pool时，可按独立授权短时设置
`mon_allow_pool_delete=true`并立即恢复。

### 2.2 同池primary切换合同

1. 空池阶段先完成一次`S→N→S`可逆canary；N目标直方图必须精确回到冻结自然值
   `{0:11,1:9,2:12,3:12,4:10,5:10}`，S必须回到
   `{0:10,1:11,2:11,3:10,4:11,5:11}`；
2. N只对4个计划PG设置冻结自然映射中的primary；S只清除这4个本RUN `primary-temp`；
3. 每次切换后必须验证64/64 `active+clean`、无recovery/backfill、对象/PG/`pg-upmap`未变，且
   `primary_temp`精确等于目标状态；空池canary若出现数据迁移、acting成员变化或不能完全清除，任务停止；
4. layout只在canary已恢复S且无残留`primary_temp`时执行一次；layout后不再改变对象、PG、upmap或挂载；
5. N/S轮间只在条件变化时切换，随后执行固定的映射稳定等待，不根据带宽决定等待时长。

---

## 三、门限与矩阵

### 3.1 结构门（L0）

B必须同时满足：64/64 PG `active+clean`、对象数为0、acting成员不变、primary分布精确匹配§2.1、
`I_primary≤1.05`。不过门即`R1B_STRUCTURE_BLOCKED`，不layout、不fio。

### 3.2 实际负载门（L1，同池N/S）

layout一次并稳定后运行：

```text
W01=N  W02=S  W03=S  W04=N
```

只用与fio正式窗重叠的六OSD `op_r`差分计算：

```text
I_op = max(op_r/s) / mean(op_r/s)
mean(I_op_N) >= 1.10
mean(I_op_S) <= 1.05
mean(I_op_N) - mean(I_op_S) >= 0.05
```

三项全过才升级L2；否则签`R1B_MECHANISM_NOT_MANIPULATED`并停止。primary计数好看不能代替
实际`I_op`。W01--W04带宽只作筛选旁证，不形成正式效应量。

### 3.3 正式矩阵（条件L2）

```text
R01=N  R02=S  R03=S  R04=N  R05=S  R06=N  R07=N  R08=S
```

沿用04-1已冻结的有效带宽口径、实际timed-I/O起点、重叠加权自然秒、`[15,175)`正式窗、
四子窗和固定二次轮序模型。输出`S-N`效应量、95% CI、同条件噪声底、S调整均值及6250目标判定。
性能高低、CV和延迟是结果，不是删样门。

另在正式矩阵前后各运行一次`H01/H02`既有A锚点，使用相同fio和测量口径。H只报告当前绝对值、
与S的描述性差异及历史区间是否一致，不进入`S-N`因果模型，也不得用H异常否定已完整的N/S样本。

---

## 四、执行阶段与复用原则

### Phase 0：最小离线Gate

执行前通读`TASK-BOOK-AUTHORING-GUIDE.md`及其引用skill。不得重写框架：

- 复用`s04r1-inventory.sh`、`s04r1-map-analyze.py`、`s04r1-osd-sampler.sh`、`s04r1-analyze.py`；
- 复用`s04r1-driver.sh`的inventory、身份、pool计划/核验和数据面组件；
- 复用`u141d-scrub-control.sh`的独立phase lease；
- 复用`FULLBASELINE_V4.sh`中已验证的randread fio命令和挂载检查；
- 只补“64 PG建池、最小pg-upmap和primary-temp计划/应用/清除”分支及对应fixture；禁止复制出第二套框架。

Gate只需证明：空池限制、N/S命令从冻结映射唯一生成、精确目标直方图、只操作B的4个PG、失败清除、
S态无残留和未知命令拒绝。

### Phase I：只读inventory与精确计划

复核Ceph版本/命令能力、健康、OSD/CRUSH、H指纹、容量和无并行负载；生成B create、upmap、
preserve、destroy计划后暂停，一次审核。

### Phase II：空池结构执行（已完成）

经授权后连续完成：创建B 64 PG→等待clean→保存自然映射→生成并应用最少数量的upmap→保存最终映射→
判结构门。阶段内部不逐条请示；异常停止并保留空池现场。

### Phase III：空池primary-temp可逆canary

复用冻结的自然/steered映射生成4条N apply和4条S clear命令，在B仍为空时执行一次`S→N→S`。
逐态冻结实际primary、acting/up、OSDMap epoch、PG/health和recovery证据；任一合同不满足即清除本RUN
`primary-temp`、验证回到S并停止。canary通过后才允许准备数据面。

### Phase IV：一次layout与L1

结构过门后再启用已有数据面组件并补最小Gate；创建隔离身份/卷、layout一次、冻结128个文件并只读挂载B；
L1不运行H，因此不额外挂载H，
按独立scrub lease连续跑同池`W01=N,W02=S,W03=S,W04=N`，恢复lease并清除`primary-temp`回到S后
暂停审核。

### Phase V：条件L2、H锚点与收口

仅机制门通过后才创建H的独立只读挂载，使用新phase scrub lease运行`H01`、连续N/S `R01--R08`和`H02`；随后恢复flags、
清除本RUN `primary-temp`回到S、优雅卸载、持久化并由GPT复算。B Pool/卷默认保留到正式报告决定
处置；任何删除必须另有精确计划和授权。

---

## 五、交付物与安全红线

最低交付：RUN公共inventory/实际脚本/commands、自然与steered逐PG映射、upmap与primary-temp清单、
空池可逆canary、N/S/H各cell原始fio日志与OSD counters、incidents、manifest、persistence记录，以及：

```text
doc/perf-report/04-1b-randread-explicit-primary-steering-ab-<YYYYMMDD>.md
doc/deploy-log/results-table.md
```

公共证据每RUN只复制一次，逐cell只增量回传；按`TEST-DATA-LIFECYCLE-POLICY.md`执行，不制作递归
phase快照。GLM只交原始数据和门状态，不计算最终效应或宣告达标。

红线：

1. 禁止修改、删除A Pool/卷/文件/CephX及`/mnt/juicefs`；这里的A是测试参考资产，不称“生产Pool”；
2. `pg-upmap`只允许作用于本RUN精确B Pool且必须在对象数为0时应用；后续不得删除/重加；
3. 禁止`primary-affinity`、改系统`ceph.conf`、OSD重启或改OSD权重；`primary-temp`只允许按冻结计划
   操作4个本RUN PG，并在阶段结束/失败时精确清除；
4. 禁止删除重建Pool搜索有利映射，禁止重复layout；
5. 禁止模式kill、lazy/force unmount、宽路径递归删除和任何块设备写；
6. 全局scrub flags按独立lease控制，失败/阶段结束先恢复；
7. 任一非性能门失败即停止、记录incident、恢复scrub并清除本RUN `primary-temp`后保留现场，
   不热修后继续同RUN；
8. 测试后按方法论复核合规，完成持久化前不得清理远端唯一证据。
