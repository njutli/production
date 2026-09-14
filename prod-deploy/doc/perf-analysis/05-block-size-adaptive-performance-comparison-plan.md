# 05阶段计划：不同I/O Block Size下的JuiceFS性能与竞品对比

> 日期：2026-09-14
>
> 状态：`PLANNED`
>
> 前置结论：04阶段已锁定exact patched JuiceFS v1.4.1与256 KiB通用交付基线；05阶段不推翻原存储规格，而是补齐不同应用I/O尺寸下的性能曲线和配置选择。
>
> 首项任务：`doc/perf-tasks/05-1-randrw-block-size-sweep-and-adaptive-tuning.md`

## 一、为什么开展05阶段

既有七项基线中，`seqwrite/mseqwrite`使用4 MiB，其余测试使用256 KiB。现有结论因此只能回答两个离散负载点，不能回答：

1. 应用I/O从小块增长到大块时，JuiceFS与有方的带宽、IOPS和延迟如何变化；
2. 两套系统在相同fio命令下的相对关系是否随BS改变；
3. JuiceFS是否需要按BS调整FUSE请求上限、预读或卷BlockSize，调整后能获得多少增益；
4. 哪些配置可以作为通用基线，哪些只能用于特定负载或专用挂载。

05阶段以`randrw`为第一优先级，因为它是存储规格最关心、也最接近生产混合读写的I/O模型。

## 二、四个概念必须分开

| 变量 | 所在层 | 能否在线切换 | 作用 |
|---|---|---|---|
| fio `bs` | 应用负载 | 是 | 每个应用I/O的大小，是本阶段横轴 |
| JuiceFS `BlockSize` | 卷格式 | 否；需独立卷 | 对象切分粒度，影响对象数、放大和单对象时延 |
| `--max-fuse-io` | 挂载 | 需重挂 | 单次FUSE请求上限；当前通用值256 KiB，可选上限1 MiB |
| `--max-readahead` | 挂载 | 需重挂 | 调整读侧在途窗口；随机负载不得沿用顺序读RA32结论 |

因此每项测试固定分为两层：

- **标准曲线**：固定当前交付卷和挂载，只改变fio `bs`；该层可与有方同命令直接比较。
- **适配曲线**：固定fio负载后再调整JuiceFS参数；每次只改一个层次。若改变卷BlockSize，必须使用fresh匹配对照卷，不能和历史业务卷直接相减。

## 三、统一测试口径

### 3.1 当前JuiceFS对照基线

```text
binary=/tmp/juicefs-1.4.1-patched
expected_md5=24fae0852051c80ca571cb2f20275d46
Volume BlockSize=256 KiB
mount=--max-fuse-io 256K --max-uploads 150 --cache-size 0
Ceph client private config=ms_async_op_threads=8
writeback=off
```

主对比不启用本地读缓存或writeback，避免把本地介质能力计入分布式数据路径。缓存能力如需展示，单列为条件性附加曲线。

### 3.2 BS档位

| 负载类别 | 核心档位 | 说明 |
|---|---|---|
| `randread/randwrite/randrw` | `4K, 16K, 64K, 256K, 1M, 4M` | 覆盖小IO、规格点和大块随机IO |
| `seqread/seqwrite/mseqread/mseqwrite` | `64K, 256K, 1M, 4M, 16M` | 20 MiB只作为已披露竞品命令的附加读点 |

若L1曲线已经出现清晰平台，不自动增加相邻档。所有系统在同一BS点必须保持相同`rw/ioengine/iodepth/numjobs/direct/runtime/filesize`，不得用改变QD或job数后的值冒充BS效应。

### 3.3 对比输出

每个BS至少报告：

- READ、WRITE各自的MiB/s、IOPS、平均及P95/P99完成延迟；
- JuiceFS标准配置值、JuiceFS该BS最优有效配置值；
- 有方同命令三轮值及均值；
- `JuiceFS标准/有方`、`JuiceFS最优/有方`百分比；
- 实际二进制、卷BlockSize、挂载参数和fio完整命令。

`randrw`两向分别比较，禁止相加后判断领先；如需对配置排序，使用两方向相对对照增益的较小值，防止以牺牲一向换取另一向。

有方测试由用户在对应环境独立执行，不写入JuiceFS任务书。当前通用七项脚本已从
`/home/lilingfeng/fio-7item-test.sh`归档至
`scripts/benchmark/fio-7item-test.sh`，归档SHA256为
`8986bbfe981b28be3379c4496cdbb441e774a78cfbb5bcfc091e39b4fdbbc7c0`。归档版本默认仍是原七项BS口径，后续有方BS sweep须以参数化的受审版本执行并冻结实际脚本SHA256，且不得执行归档脚本的`clean`入口代替精确人工清理。有方结果还须附fio版本、内核、挂载类型/参数、文件系统容量、客户端CPU/内存/网络和测试时间；缺这些信息时只作观测值。

## 四、任务分解

```text
05-1  randrw：标准BS曲线 → 大BS挂载适配 → 单个卷BlockSize候选筛选
  ├─ 无材料信号：保留B256通用基线，进入05-2
  └─ 有材料信号：另经授权补L2正式确认，再进入05-2
05-2  randread/randwrite：补齐随机纯读、纯写BS曲线
05-3  seqread/seqwrite：单流顺序BS曲线与专用挂载参数
05-4  mseqread/mseqwrite：多流顺序BS曲线及并发平台
05-5  汇总JuiceFS标准/最优曲线并导入有方数据，给出配置建议和阶段结论
```

05-1优先复用现有B256卷及固定`rw_test`资产，不重新layout。后续任务优先复用各自现有固定资产。只有卷BlockSize候选验证必须新建临时卷和一次性layout；该动作不得与标准曲线混在一个效应量中。

## 五、JuiceFS适配原则

1. **小于或等于256 KiB的随机I/O**：先保持FUSE256K；若64K出现明显对象粒度问题，才比较fresh B64与fresh B256。JuiceFS卷BlockSize最小为64 KiB，小于64 KiB的fio BS不能机械一一对齐。
2. **1 MiB及以上I/O**：先在同一B256卷比较FUSE256K与FUSE1M；只有FUSE层有材料信号后，才考虑卷BlockSize匹配。
3. **随机混合读写**：不直接套用顺序读的B4/RA32。RA32提升的是顺序读对象在途量，对randrw可能制造无效预读；默认readahead与RA0只允许做一次材料性筛选。
4. **卷BlockSize**：只在临时fresh对照卷上验证，候选范围为64 KiB至16 MiB的2次幂；同一候选必须有fresh B256对照、相同数据合同和相同挂载参数。
5. **通用配置门**：某BS上的峰值不等于通用配置。若要改变通用基线，必须对原七项及256 KiB规格点完成非劣回归；否则只形成“特定BS专用配置”。

## 六、判定规则

- L1材料信号：READ和WRITE方向相对两侧对照均同向，较小方向增益至少5%，且超过同RUN锚点漂移；机制指标方向一致。
- 一向提升、一向下降：记为Pareto权衡，不签“randrw整体提升”。
- 标准曲线首尾256K锚点漂移超过10%，或任一BS正反向两点差异超过10%：只保留工程观察，先归因运行状态，禁止与有方做精确百分比结论。
- 只有存在可交付且材料性候选才升级L2；L1无信号即停止该参数，不扫更多档位。
- 有方与JuiceFS硬件、网络、缓存或保护策略不一致时，结论限定为“各自已部署环境、相同fio命令的端到端对比”，不得归因为文件系统软件单因素。

## 七、稳定性、安全与证据边界

- 157上的WekaIO、K8s、网络、内核、md0和非本任务路径是红线；禁止全局`drop_caches`。
- 标准曲线只复用固定测试资产，禁止轮间layout；采用正向+反向BS次序及首尾256K锚点量化状态漂移。
- L1保持scrub开启并记录正式窗重叠；只有升级为长时间L2时，才可在用户单独授权后用既有状态驱动脚本暂停并恢复`noscrub/nodeep-scrub`。
- 不改生产卷BlockSize，不新建或删除Ceph pool，不停止/重启OSD、TiKV或业务服务。
- 临时卷必须使用本RUN专属META、Name、UUID和挂载路径；format、layout、destroy分开计划，destroy前再次核对身份并单独授权。
- 原始证据唯一持久化根为`/mnt/c/SunRise/test/05-*/<RUN_ID>/`；遵循`TEST-DATA-LIFECYCLE-POLICY.md`，先持久化和校验，再清远端临时副本。

## 八、阶段交付物

1. 每项任务的正式报告及可复算raw；
2. 七项“BS—带宽/IOPS/延迟”曲线；
3. JuiceFS标准配置、有方、JuiceFS按BS最优配置三方对比表；
4. 面向生产的配置表：通用基线、特定BS专用候选、不得采用项；
5. `doc/deploy-log/results-table.md`更新及05阶段最终报告。

05阶段结束条件：完成同命令对比并回答“是否存在可复用的按BS调优”；有则给出适用边界和回归结果，无则保持现有256 KiB通用配置并关闭继续扫描。
