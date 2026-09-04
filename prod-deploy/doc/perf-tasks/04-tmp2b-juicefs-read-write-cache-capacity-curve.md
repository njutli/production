# 04-tmp2b 任务书：JuiceFS 读写缓存共享容量曲线

## 日期：2026-09-02

> 实验编号：`TMP-CACHE2`，不占正式 `04-N` 编号。
>
> 当前状态：`COMPLETED / CACHE_CAPACITY_CURVE_INVALID / ENVIRONMENT_CLOSED`。
>
> 执行结果：RUN `20260903-000000`完成6个有效读点；首个`randwrite-c16`在fio成功后触发
> `WRITEBACK_STAGING_DRAIN_FAILURE`，按硬门停止其余5个写点。恢复挂载已安全清空staging，
> 所有测试资产和scrub状态均恢复。详见
> `doc/perf-report/04-tmp2b-juicefs-read-write-cache-capacity-curve-20260903.md`；不重跑、不交付缓存配置。
>
> 承接：`04-tmp2-juicefs-local-read-cache-stability-canary.md` 及其 2026-09-02 报告。
> 04-tmp2 已证明缓存机制信号很强，但没有证明正式窗已进入缓存稳态；本任务不重跑原 ABBA，
> 改为回答不同本地容量占工作集比例时，读缓存与 writeback 同时开启的实际收益曲线。
>
> 执行前必须遵守 `skills/SYSTEM-SAFETY-SKILL.md`、
> `skills/EVIDENCE-INTEGRITY-SKILL.md`、`skills/TESTING-GUIDE.md`、
> `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md` 和
> `doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`。

```text
EVIDENCE_LEVEL=L1_SCREEN
UNIQUE_QUESTION=16/32/64GiB本地总预算下，同时开启读缓存和writeback，四项前台与持久化后性能如何随容量比例变化
MINIMUM_DECISION_SET=3个容量档×4个测试项×每点1次正式运行；仅不稳态点允许1次条件确认
STOP_AFTER_ANSWER=不追加cache=0臂、不跑七项全量基线、不自动升级正式生产canary
MAX_PREP_BUDGET=90min；超时删非决策功能，不扩建通用测试框架
ESTIMATED_WALL_CLOCK=通常5--7h；含条件确认、写回排空和对象回归的硬上限10h
CACHE_MEDIUM=157本地独立NVMe上的RUN专属loop/ext4；禁止tmpfs
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2b/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2b-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=按state精确卸载JuiceFS/ext4、detach RUN专属loop并删除唯一backing file
```

---

## 计划线

```text
Phase 0：最小脚本、合成fixture和离线Gate 0
  ↓
Phase I：只读inventory + 12点执行计划 + 全部精确sudo/恢复计划
  ↓（GPT审核；用户一次性授权计划内的精确sudo操作）
Phase II：先完成全部读点，再完成写点；每个测试项按C16→C64→C32
  ├─ 180s已稳态：直接签该点
  ├─ 180s未稳态且无安全异常：该点只追加一次300s确认
  └─ 排空超时/错误/环境门失败：保留现场并停止，不拼接数据
  ↓
Phase III：容量曲线、前台/有效写带宽、环境和证据生命周期收口
```

一句话任务：复用现有数据资产，在读缓存与 `--writeback` 同时开启时，测出 16/32/64 GiB
本地共享缓存预算相对 64/128 GiB 工作集的收益曲线，并区分“客户端提前确认的写带宽”和
“包含后台写回排空的有效持久化带宽”。

---

## 一、问题边界与价值

### 1.1 为什么要同时打开读写缓存

生产若开启本地缓存，读缓存文件和 writeback 暂存通常会竞争同一块本地盘。只测读缓存无法回答
混合负载下缓存空间如何分配，也无法评估 writeback 的容量效应；只看 fio 写带宽又会把“先落本地、
稍后上传”误认为后端持久化能力。因此本任务把两者作为一个共享预算整体测试。

`--cache-size`只约束读缓存目标，并不是 writeback 字节上限。本任务不能仅把它设为
16/32/64 GiB 后宣称写缓存也受同样限制；必须用容量受控的独立文件系统约束二者共享的物理预算。

### 1.2 本任务不回答什么

- 不选择“最大档一定最快”；三档用于描述缓存/工作集比例与收益关系；
- 不把嵌套 loop 的绝对值直接签成生产裸 NVMe 性能；它只保证三档存储形态一致、容量可控；
- 不证明 writeback 具备断电、客户端崩溃或本地盘故障下的数据安全性；本任务不做故障注入；
- 不改变现有无缓存交付基线，不自动把 writeback 纳入生产配置；
- 不做 format、destroy、新 pool、新 layout 或数据集扩容。

---

## 二、冻结变量和最小矩阵

### 2.1 共享容量档

每个测试点使用一个全新的、RUN 和 cell 双重限定的 backing file、loop 和 ext4。名义文件系统容量
与 JuiceFS 参数如下，`df -B1`实测可用字节才是最终权威值：

| 档位 | loop/ext4名义容量 | `--cache-size` | `--free-space-ratio` | 目标可用总预算 |
|---|---:|---:|---:|---:|
| C16 | 20 GiB | 16384 MiB | 0.20 | 约16 GiB |
| C32 | 40 GiB | 32768 MiB | 0.20 | 约32 GiB |
| C64 | 80 GiB | 65536 MiB | 0.20 | 约64 GiB |

共同挂载参数：

```text
--max-uploads 150 --max-fuse-io 256K
--cache-dir <RUN_CELL_EXT4>/cache --cache-size <TIER_MIB>
--free-space-ratio 0.20 --writeback
```

- 不显式传 `--max-readahead`，保持当前交付默认语义；
- 不设置 `upload-delay`，避免人为扩大尚未持久化窗口；
- read cache 与 staging 的实际占用分配允许由 JuiceFS 动态决定，但必须逐秒采集；
- 每个 cell 重新创建文件系统不是重复挂载取样，而是容量与缓存状态隔离；同一 cell 只跑一次正式
  fio，不进行多挂载重复确认；
- 执行顺序固定为先完成 mseqread/randread 全部容量点，再完成 randwrite/randrw；每个测试项内按
  `C16 → C64 → C32`，用零额外样本降低容量大小与时间单调漂移完全重合的风险；报告按
  C16/C32/C64 排序展示。

### 2.2 测试项与工作集

全部复用当前 `/mnt/juicefs/test_dir` 既有文件；Phase I 只读核验 path、数量、inode、size、mtime。

| 项 | 既有数据集 | 工作集 | C16/C32/C64占比 | 预热和正式语义 |
|---|---|---:|---:|---|
| mseqread | `mseqread/`，16×4 GiB | 64 GiB | 25%/50%/100% | 同负载预热180s，正式180s |
| randread | `read_test.*.0`，128×1 GiB | 128 GiB | 12.5%/25%/50% | 同负载预热180s，正式180s |
| randwrite | `storage_test.*.0`，128×1 GiB | 128 GiB | 作为16/32/64 GiB突发暂存预算 | 空缓存直接正式180s，随后排空 |
| randrw | `rw_test.*.0`，128×1 GiB | 128 GiB | 12.5%/25%/50%共享预算 | 只读randread预热180s，再正式randrw 180s并排空 |

正式 fio 的 `bs/numjobs/iodepth/ioengine/direct/filesize/size` 必须与
`FULLBASELINE_V4_U141D.sh` 对应四项完全一致；mseqread 为 16 job、其余为 128 job，均为 256 KiB。
randrw 的 READ/WRITE 必须分开报告，禁止相加。

总计 `3 × 4 = 12` 个正式点。历史无缓存最优值只作描述性外部锚，不加入本 RUN：

| 项 | 历史锚点 |
|---|---:|
| mseqread | 5366 MiB/s |
| randread | 5544 MiB/s |
| randwrite | 2707 MiB/s |
| randrw | READ约1870 MiB/s；WRITE约1870 MiB/s |

历史锚不与本 RUN 同窗，故只能回答工程量级，不能据此签严格因果效应或非劣性。
此外每个容量点都需新挂载，而历史已知挂载档位可造成明显差异；本L1不以多挂载重复消除该变量，
所以容量档之间不足30%的差异只能写成描述性信号，不能直接归因于容量。材料差异若值得生产化，
再另立同窗生产canary，而不是在本任务内无限增样。

---

## 三、测试时间与缓存稳态

### 3.1 是否统一延长测试时间

**不统一延长。** 16/32/64 GiB 在当前数 GiB/s 负载下，容量本身通常在数秒到数十秒内被触达；
180 秒足以让 64 GiB mseqread 工作集循环多次、让 128 GiB 随机工作集发生多轮替换，也足以观察
writeback 从突发吸收到稳态回压的转换。统一拉长只会增加覆盖写、compaction/GC 历史和排空时间，
反而引入新的时间漂移。

默认口径：

- 读项：预热180s；正式180s，主性能窗为 `[15,175)`；
- randwrite：不做写预热；同时报告 `[0,30)`突发窗、`[60,175)`稳态尾窗和全180s；
- randrw：只读预热，不预先制造写历史；正式阶段同样报告突发、尾窗和全窗；
- 每秒采集总磁盘占用、可识别的cache/staging占用、
  `juicefs_staging_block_bytes`、`juicefs_staging_blocks`、
  `juicefs_staging_writing_blocks`、NIC和本地NVMe字节；实际字段须在Phase I实查，禁止猜名。

### 3.2 稳态门和唯一延长规则

180 秒正式点满足以下条件才可作为容量曲线有效点：

1. fio、mount、staging、NVMe、NIC、Ceph/TiKV和业务指纹无错误；
2. `[60,175)`最后30秒内，cache+staging总占用变化不超过该档预算的5%，或线性斜率绝对值
   不超过该档预算的2%/min；
3. `[60,175)`前后两个等长窗带宽比在`[0.90,1.10]`；读项另要求正式窗不再承担大规模首次填充；
4. 写项正式结束后 staging 能在15分钟内降到0，且连续两次（间隔10秒）为0。

若只有第2或第3项未满足，但其余安全门全部通过，则该**具体 cell**只允许追加一次300秒确认；
确认运行取代原180秒点进入容量曲线，但原始点仍保留。不得把全矩阵统一延长，也不得再次补跑。
300秒仍未稳态则标记 `NO_STEADY_STATE_WITHIN_BUDGET`，停止解释该点的容量收益。

### 3.3 writeback的两种带宽

每个含写点必须同时报告：

```text
foreground_bw = fio正式窗确认的WRITE带宽
effective_durable_bw = fio写入总字节 / (fio开始至staging连续两次为0的总时间)
drain_time = fio结束至staging连续两次为0的时间
```

这里的 `effective_durable_bw` 是本任务的保守工程口径，不等同于逐 I/O 线性化持久性证明，但能阻止
把 writeback 排队积压隐藏在高前台带宽后面。若只有前台带宽提升而有效带宽没有提升，结论必须写成
`WRITEBACK_FRONTEND_ONLY`，不得写成存储系统持久化性能提升。

---

## 四、容量曲线输出和决策

每个测试项生成一张 C16/C32/C64 表，至少包含：

- 正式窗 mean、median、CV、P10/P90、W1--W4、W4/W1；
- 相对历史无缓存锚的描述性变化；
- fio 读写字节、157 NIC RX/TX、本地NVMe读写、后端卸载比例；
- cache/staging峰值、尾值、斜率、staging delay/error增量；
- 含写点的前台带宽、排空时间和 `effective_durable_bw`；
- randrw READ与WRITE独立列。

本任务不要求容量越大性能必然单调上升。非单调可能来自读写争用、淘汰和后端服务率，必须按实际
占用解释。仅在相邻容量档差异小于10%、出现反常方向或写项相对历史锚回退超过10%时，才允许受影响
cell补一次；若它同时触发3.2的延长，只执行一次300秒确认，不叠加两类补测。

建议 verdict：

| 条件 | 结论 |
|---|---|
| 缺点、身份/安全门失败、writeback未排空 | `CACHE_CAPACITY_CURVE_INVALID` |
| 12点有效且容量状态可解释 | `CACHE_CAPACITY_CURVE_VALID` |
| 读有收益但写仅前台提升 | 追加 `WRITEBACK_FRONTEND_ONLY` |
| 至少一档读项有材料收益，且randwrite/randrw有效带宽不回退超过10%、15分钟内排空 | 追加 `PRODUCTION_CACHE_CANARY_WORTHWHILE` |
| 所有档均无材料收益或写侧有效吞吐/恢复代价不可接受 | 追加 `NO_DELIVERABLE_COMBINED_CACHE_TIER` |

即使出现候选档，也只能进入另立的生产 canary；本任务不会直接修改交付配置。

---

## 五、环境、安全与恢复合同

### 5.1 本地容量实现

- backing file 只能位于 Phase I 确认的 157 独立缓存 NVMe 上的 RUN 专属目录：
  `/mnt/jfs-cache/jfs-04tmp2b-<RUN_ID>/<CELL>.img`；该目录开始时精确创建为
  `1002:1002 0700`，全部 cell 收口后仅用精确 `rmdir` 删除；不得修改缓存盘根目录权限；
- 任一时刻只存在一个本任务 loop；禁止直接对 `/dev/nvme*` 执行 mkfs；
- `losetup`返回的设备必须反查 backing file 完全一致后，才允许对该 loop 执行 `mkfs.ext4`；
- mount 只能是 `/tmp/jfs-04tmp2b-cache-<RUN_ID>-<CELL>`，JuiceFS mount 只能是
  `/tmp/jfs-04tmp2b-mnt-<RUN_ID>-<CELL>`；
- 每个 cell 收口顺序固定为：停止 fio → staging 排空 → 优雅卸载 JuiceFS → 核对无相关 PID/FD →
  卸载 ext4 → 精确 detach loop → 删除唯一 backing file → 删除空目录；
- 任一步失败即保留现场，先 inspect/plan，禁止强制/lazy umount、禁止 `rm -rf`和glob清理。

loop/ext4会引入一致的嵌套存储开销，但可硬性限制共享容量，并能通过卸载文件系统清除本 cell 的
缓存状态而不执行全机 `drop_caches`。因此曲线内横向比较有效，绝对值必须标注存储形态边界。

### 5.2 不改变现有数据与业务

- mseqread、randread只读；randwrite和randrw仅覆盖各自既有测试文件，不新建、不扩容；
- 开跑前后核验文件集合、inode、size；写项允许mtime变化但所有文件仍须为固定大小；
- 不在正式 `/mnt/juicefs` 上直接跑 fio，使用 RUN 专属测试挂载；不改变卷格式、pool、PG、CRUSH、
  TiKV配置或集群进程；
- 157存在WekaIO/K8s等共置业务，**禁止执行全局 `drop_caches`**，也不得改内核、NUMA/IRQ、网络、
  RoCE、md0、WekaIO路径；
- `--writeback`存在客户端或本地缓存盘故障时丢失未上传对象的风险。测试中不得杀mount、断电或拔盘；
  staging未排空前严禁卸载本地ext4、detach loop或删除backing file。

### 5.3 scrub与写后状态

由于矩阵包含6个含写点且可能持续数小时，计划复用已签收的 `u141d-scrub-control.sh`，在独立授权后
暂停 `noscrub + nodeep-scrub`。开始前要求除预期 OSDMAP_FLAGS 外无健康异常、全部 PG
active+clean；任务结束或失败恢复原 flags。

写点之间不使用 pool delete/create、OSD restart或全局drop_caches。只复用现有安全的对象回归、
compact/cooldown合同；staging排空最长15分钟，对象回归/compact另按既有门等待，但整个任务不得超过
10小时。任一后端恢复门不通过就停止矩阵，不以无限等待换结果。

---

## 六、执行阶段和授权边界

### Phase 0：离线准备

优先复用 `t04tmp2-cache-run.sh`、`t04tmp2-cache-cleanup.sh`、
`t04tmp2-cache-analyze.py`、`u141d-scrub-control.sh`及既有state-driven loop守卫，仅增加一个精简
driver、容量/写回分析和Gate 0；禁止复制成新的通用框架。

Gate 0至少验证：

1. 12点矩阵、顺序、四项参数、唯一延长规则和硬时限；
2. mount同时包含cache-dir/cache-size/free-space-ratio/writeback，且无upload-delay；
3. 禁全局drop_caches、format/destroy/pool/PG/CRUSH/进程重启和直接NVMe mkfs；
4. loop设备必须由本cell backing反查，cleanup只接受state中登记的精确资产；
5. staging未清零时所有detach/delete路径必须fail closed；
6. 合成数据自证突发/尾窗、稳态斜率、foreground/effective durable计算；
7. 禁网络、sudo和真实环境变更；冻结全部脚本SHA256。

### Phase I：只读inventory和计划

只读确认二进制/META/卷/数据集、无foreign fio和测试mount、缓存NVMe身份/空间/空闲I/O、Ceph/TiKV
健康、现有scrub flags，并输出：

- 12个cell的完整命令和预计空间；
- 每种容量的精确loop create/verify/destroy命令；
- scrub pause/restore命令；
- 写后排空、对象回归和失败恢复计划。

到此暂停。所有 sudo 写操作必须由用户基于完整命令明确授权；任务书和Gate PASS不等于授权。

### Phase II：执行

授权后可按冻结矩阵批量执行，不要求每个正常cell停下来汇报。只有以下情况停：变量需改变、身份/业务
指纹异常、staging排空超时、非预期健康告警、脚本无法fail closed或计划外sudo操作。

脚本bug可自主修复，但必须重跑离线Gate、冻结新SHA并在报告列出修改；不得借修bug改变容量、矩阵、
时长、fio语义或安全边界。

### Phase III：签收与生命周期

先把原始证据、实际脚本、`commands.sh`、状态文件和manifest持久化到`EVIDENCE_ROOT`，核对源端/本地
SHA256和文件数后再清理远端临时结果。环境资产按state精确恢复；报告不得复制整棵证据树。

---

## 七、最小交付物

1. Phase I inventory、完整命令计划和用户授权记录；
2. 12点（及条件确认，如有）fio原文、per-job bw log和实际timed-I/O起点；
3. 每秒cache/staging、NVMe、NIC和必要后端指标；
4. 每个写点的staging排空证据和前台/有效持久化带宽；
5. 三档四项容量曲线、历史锚描述性比较和明确边界；
6. 环境恢复、scrub恢复、无mount/loop/backing残留及业务指纹；
7. 持久化manifest、SHA256、生命周期状态和skill合规自查。
