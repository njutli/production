# 04-7 randrw缓存同步停顿归因与`async_dio`最小筛选报告

> 日期：2026-09-08  
> RUN_ID：`20260908-095000`  
> 合同：P25 `A1-B1-B2-A2`；A为默认同步DIO，B仅增加`-o async_dio`  
> 原始证据：`/mnt/c/SunRise/test/04-7/20260908-095000/final/`

```text
RUN_VALIDITY_STATE=VALID
VERDICT=STOP_NEGATIVE
ASYNC_DIO_PRODUCTION_CANDIDATE=NO
SYNCHRONIZED_NO_RECORD_INTERVALS=REDUCED_BUT_NOT_WITHOUT_PERFORMANCE_COST
PRODUCTION_CHANGE=NONE
ENVIRONMENT=CLOSED
```

## 一、结论

`async_dio`明显改变了停顿形态，但不是可交付的randrw优化：两个同RUN配对的读写方向均值分别
下降`11.45%`和`13.03%`，mean total latency反而增加`12.83%`和`14.85%`。A/B各自重复漂移
最大仅`3.23%`，低于10%的材料阈值，负向结论清楚。

与此同时，所有job同步无记录时间从A1/A2的`47/39s`降至B1/B2的`11.5/0s`，writeback严格
排空时间从`102/84s`降至`10/10s`。这说明默认同步DIO提交/缓存协调路径确实参与长停顿；但
`async_dio`只是把运行形态变得更连续，代价是更低的全程吞吐和更高的平均总延迟，不能据此启用。

本结果不改变既有生产边界：P25读写共享缓存比例继续关闭；纯读缓存和低占空比、独占文件场景的
条件writeback仍分别沿用04-tmp2d/2j与04-tmp2f/2g结论。

## 二、正式结果

主端点为fio JSON完整timed run的实际字节数除以实际runtime；bw log只统计同步无记录秒，不跨
空洞回填带宽。

| Cell | `async_dio` | READ MiB/s | WRITE MiB/s | 方向均值 MiB/s | R/W同步无记录秒 | mean total latency ms | 严格排空 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| A1 | 0 | 1481.48 | 1481.61 | 1481.54 | 47 / 47 | 1378.98 | 102 |
| B1 | 1 | 1311.74 | 1311.93 | 1311.84 | 11 / 12 | 1555.86 | 10 |
| B2 | 1 | 1269.35 | 1269.71 | 1269.53 | 0 / 0 | 1607.36 | 10 |
| A2 | 0 | 1459.80 | 1459.64 | 1459.72 | 39 / 39 | 1399.54 | 84 |

| 配对 | READ | WRITE | 方向均值 | 同步无记录负担 | mean total latency |
|---|---:|---:|---:|---:|---:|
| B1 / A1 | `-11.46%` | `-11.45%` | `-11.45%` | `-75.53%` | `+12.83%` |
| B2 / A2 | `-13.05%` | `-13.01%` | `-13.03%` | `-100.00%` | `+14.85%` |

重复漂移计算得到`epsilon=3.23%`，判定材料线`M=max(10%,2*epsilon)=10%`；两个B/A配对均超过
材料退化线，因此按预注册规则签`STOP_NEGATIVE`，无需追加L2或更多容量/QD轮次。

## 三、归因边界

本RUN把04-tmp2i的历史观察推进了一步：

- 开启`async_dio`后，同步无记录区间和最长记录间隔在两次配对中都显著缩短，排空也由约
  `1.5min`缩到`10s`，所以长停顿并非单纯的Ceph整体停服，也不能只解释为“缓存空间已满”；
- 但B臂平均总延迟升高、全程双向带宽下降，说明等待减少没有转化成更高服务量。当前证据只能确认
  同步DIO提交/缓存协调参与停顿，不能再收窄到某个JuiceFS锁、FUSE队列或单一后台线程；
- B臂能力证据来自实际挂载argv精确包含`async_dio`，等级为`INFERRED_FROM_EXACT_MOUNT_ARGV`。
  若结果为正本应补内核能力证明；本次是稳定的负向筛选，无需为关闭候选追加验证。

因此，04-7回答的是“`async_dio`能否把停顿改善转化为生产可用收益”：答案是否定的；它没有证明
P25全部停顿只有一个根因，也不推翻既有纯读缓存和条件writeback方案。

## 四、生命周期与证据

- 四格fio、严格排空、graceful unmount、cache=0读回、GC/OSD compact和对象回归全部PASS；
- RUN专属ext4/loop/backing已精确销毁；无本RUN挂载、loop、fio或JuiceFS进程残留；
- 参考挂载`/mnt/juicefs`前后身份一致；Ceph最终`HEALTH_OK`、6/6 OSD up/in、97/97 PG clean；
- scrub/deep-scrub原值为未设置，RUN结束后已精确恢复为未设置；全局对象数前后均为`1978612`；
- 权威归档`04-7-20260908-095000.tar`大小`64256000`字节，SHA256：
  `bd3a01fd075823b4417b75e27a16eb5b5654e0dfbc24ff2477f03ff08ad3fc87`；
- GPT在本地从持久化归档重新运行同一分析器，带宽、停顿、效应量和`STOP_NEGATIVE`裁决一致；差异仅
  为Python浮点末位表示和临时目录派生的run_id。

一个不影响裁决的记录缺陷是根目录`run-state.tsv`仍停留在`INVENTORY_PLAN_PASS`；根`PASS`、四格
`PASS`、`storage/DESTROYED`、最终健康证据和`verdict.txt`均完整，因此不重跑负载，只在此显式登记。
仓库执行器已补充成功路径的最终状态写入；冻结的本RUN原始证据不回写。

04-7到此关闭，不新增生产配置，也不继续搜索`async_dio`相邻参数。
