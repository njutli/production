# 04-1b randread 显式 Primary 均衡工程筛选正式报告

```text
VERDICT=R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET
ENGINEERING_DECISION=PRIMARY_BALANCE_PRODUCTION_CANDIDATE_NOT_DIRECT_DELIVERY
TARGET_6250=FAIL
R1B_LIFECYCLE=CLOSED
RUN_ID=20260901-194644
```

## 一、结论

在同一个64-PG EC4+2测试Pool、同一UUID和同一份128×1 GiB只读数据上，把primary分布从自然态
`{0:10,1:15,2:11,3:11,4:8,5:9}`（`I_primary=1.40625`）调整为
`{0:10,1:11,2:11,3:10,4:11,5:11}`（`I_primary=1.03125`）后，randread工程观察值为：

| 条件 | 轮次 | 带宽 MiB/s |
|---|---|---:|
| N：自然primary | W01 / W04 | `3467 / 3438` |
| S：均衡primary | W02 / W03 | `3920 / 3929` |
| N均值 | — | `3452.5` |
| S均值 | — | `3924.5` |
| 描述性S-N | — | **`+472 MiB/s / +13.67%`** |

N两点极差相对N均值为`0.84%`，S两点为`0.23%`；`+13.67%`明显超过预注册`5%`材料关注线。
这证明**primary选择/分布是值得继续生产化的读性能变量**，但均衡态仍只有6250目标的`62.79%`，
相差`2325.5 MiB/s`，没有达成R线目标。

本RUN不能直接签“可上线配置”：W01与W02--W04之间挂载实例发生过变化，四轮不是严格固定挂载的
正式矩阵；Attempt 4同一挂载内只有`S/S/N`，虽得到`3920/3929 → 3438 MiB/s`的同向强信号，仍缺
第二个同挂载N闭环与正式区间。另因OSD admin-socket采样器不可用，没有取得正式窗内实际`op_r`
分布，故只能把性能差归于受控的primary条件，不能签出“`I_op`下降多少”这一机制量。

## 二、实验对象与实际操纵

```text
JuiceFS=/tmp/juicefs-1.4.1-patched
MD5=24fae0852051c80ca571cb2f20275d46
fio=randread,bs=256KiB,numjobs=128,iodepth=128,direct=1,runtime=180s,readonly
pool=jfs-r1b-20260901-194644,pool_id=6,pg_num=64
volume_uuid=0c7584ea-9066-4bc6-845e-6c4bad13dfe0
files=128x1GiB
```

空Pool阶段对5个PG使用`ceph osd pg-upmap`，每条映射保持六个acting成员集合不变，只调整顺序，
然后才layout一次。性能阶段不再修改upmap；N通过5条`primary-temp`恢复冻结的自然primary，S清除
这些`primary-temp`回到upmap定义的均衡态。四轮采集的64个PG均为`active+clean`，逐轮直方图与
N/S合同一致；fio前health唯一WARN是任务主动设置`noscrub,nodeep-scrub`产生的`OSDMAP_FLAGS`。
持久证据不支持“正式窗存在PG_AVAILABILITY异常”这一猜测。

## 三、GPT独立复核

GPT从持久化`fio.txt`重新解析得到：

```text
W01 N 3467 MiB/s  rc=0
W02 S 3920 MiB/s  rc=0
W03 S 3929 MiB/s  rc=0
W04 N 3438 MiB/s  rc=0
N_mean=3452.5 MiB/s
S_mean=3924.5 MiB/s
S_minus_N=472.0 MiB/s (+13.6713%)
N_pair_spread=0.8400%
S_pair_spread=0.2293%
```

四轮各有128条原始bw log且`fio.rc=0`；最终证据目录共558个清单条目，GPT本地执行
`sha256sum -c`通过。driver未生成`l1-bandwidth-only.json`的原因是解析器只接受大写`BW=`，而
fio-3.28摘要实际为小写`bw=`；这是后处理缺陷，不影响fio原文和上述独立计算。

### 3.1 有效性边界

1. W01在Attempt 2完成，W02--W04在Attempt 4完成；报告记录的挂载PID发生变化，UUID、Pool、文件、
   objects/stored与配置保持一致，但不能声称四轮使用同一daemon热状态。
2. Attempt 4内部两轮S和一轮N使用同一挂载，S均值相对W04 N为`+14.15%`；W01 N又与W04 N只差
   `0.84%`，降低了“纯挂载实例差异”解释的可信度，但没有把三轮筛选升级为八轮正式效应量。
3. 只有2个N、2个S点，不计算95% CI，不把pair spread冒充置信区间。
4. 03阶段历史randread `5544 MiB/s`来自另一Pool/layout/窗口，不能与本RUN `3924.5 MiB/s`直接相减；
   因此本RUN只能签相对N/S方向，不能更新七项交付基线绝对值。
5. 实际`op_r`未采到，不能声称带宽提升已经由OSD计数器机制闭合。

## 四、是否可用于生产

### 4.1 可以交付的内容

可以交付为**生产候选策略**：创建新Ceph数据Pool时，在Pool为空且尚未layout之前，根据该Pool的实际
逐PG acting map计算pool-scoped `pg-upmap`，优先让primary计数和实测读负载更均衡；先做可逆canary，
确认无recovery/backfill与业务回退后再写入数据。本RUN表明该方向可能产生两位数相对收益。

### 4.2 不能直接交付的内容

- 本RUN的5条命令属于已删除的pool_id=6，**不能复制到任何其他Pool**；
- 当前Quincy没有`pg-upmap-primary`。本RUN的持久S态依赖`pg-upmap`调整acting顺序；对已有数据的
  EC Pool直接这样做可能改变shard位置并触发恢复流量，不能作为在线低风险参数修改；
- `primary-temp`只用于实验可逆切换，不作为持久生产方案；
- 自然态`I_primary=1.40625`比03历史实际OSD读负载不均衡`1.132--1.136`更严重，`+13.67%`不能按比例
  外推到生产；
- 没有八轮正式矩阵、同窗H锚点和实际`I_op`，不能承诺生产收益幅度或6250达标。

因此，现阶段准确表述是：**发现了明确且可工程化的优化方向，但尚未形成可直接上线的生产配置**。
新Pool可在写入数据前按上述策略做最小生产canary；已有Pool若要采用，需要另行评估迁移/恢复影响，
不在04-1b内继续测试。

## 五、环境与证据闭环

```text
R1B_FINAL_EVIDENCE_PASS
R1B_ENVIRONMENT_CLOSURE_PASS
R1B_TEST_COMPLETE
```

- W01--W04每轮128条bw log，持久化manifest `558/558 OK`；
- CephX key已从清理计划脱敏；
- B挂载、volume、pool_id=6、5条upmap、CephX和keyring均已精确清除；
- `mon_allow_pool_delete=false`、balancer恢复`active=true/mode=upmap`；
- 无scrub flag、无`primary_temp`，Ceph `HEALTH_OK`；
- A/reference Pool和157既有业务正常；
- 远端RUN根已清理，持久证据保留在
  `/mnt/c/SunRise/test/04-1b/20260901-194644/final-evidence/`。

生命周期有一项过程偏差：执行方删除已持久化后的精确远端RUN根时使用了`rm -rf`，而项目红线要求
使用受限的精确删除方式。目标路径经RUN_ID核验且未越界，性能与环境结论不受影响；后续任务仍禁止
沿用该命令形式。

## 六、最终处置

1. 04-1“仅增加PG数量自然均衡”结论保持`R1_FEASIBILITY_BLOCKED`；32→64→128没有改善比例。
2. 04-1b签`R1B_BANDWIDTH_SIGNAL_POSITIVE_TARGET_NOT_MET`并关闭，不补L2/H、不修OSD sampler。
3. 不修改03阶段七项交付基线，不把`3924.5`写成新的randread基线。
4. 若业务决定建设新Pool，把“按实际Pool map预计算primary均衡、空Pool canary后layout”另立生产变更单；
   已有Pool不直接套用。
