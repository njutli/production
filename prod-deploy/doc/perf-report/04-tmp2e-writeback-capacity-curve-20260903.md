# 04-tmp2e writeback可用容量测试报告

## 一、结论

```text
RUN_ID=20260903-181523
EVIDENCE_LEVEL=L1_SCREEN
VERDICT=W16_WRITEBACK_DRAIN_FAILURE
CAPACITY_CURVE=STOPPED_AT_FIRST_CELL
PRODUCTION_DECISION=CONDITIONAL_ENABLE_WHEN_CLIENT_SPACE_IS_SUFFICIENT
DELIVERY_ROLE=BURST_WRITE_ENHANCEMENT
ENVIRONMENT_CLOSURE=CLOSED
```

修正容量口径后，首个16 GiB backing的`W16-randwrite`完成180秒fio，但writeback staging在
15分钟排空门结束时仍残留`2 blocks / 524288 B`，对应两个rawstaging文件。该点没有通过
writeback生命周期门，不能计算有效持久化带宽，也不能登记为容量曲线有效点。按任务书早停，
W32/W64/W96/W128和randrw均未启动。

这不是fio失败：128个job均正常运行，前台平均带宽约`2436.50 MiB/s`。失败发生在fio返回之后的
排空阶段，说明16 GiB不足以承接本次持续满压写入，但不否定writeback在生产短突发中的价值。

结合生产业务约束——每个客户端只写自己独占的文件、不依赖待上传期间的跨客户端可见性，且不会
长时间持续满压——本项目决定将writeback作为**有足够本地持久空间时的条件性生产增强配置**。
它用于提高业务活跃写入窗口的前台吞吐、把后端上传转移到空闲期；不宣称提高Ceph长期持久化服务率，
也不把本次W16登记为推荐容量。

## 二、测试口径

| 项 | 实际口径 |
|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46` |
| Ceph客户端 | RUN私有配置MD5 `86351c58848c7e4caaa1bbeccb211730`；8个`msgr-worker` |
| mount | `--writeback --cache-size 1 --free-space-ratio 0.20 --max-uploads 150 --max-fuse-io 256K` |
| workload | `storage_test.*.0`，128×1 GiB；randwrite、128 job、256 KiB、iodepth 128、180秒 |
| backing | 157本地NVMe上的RUN专属16 GiB文件，动态loop和普通ext4；不接触裸NVMe |
| 排空门 | fio结束后最长900秒；staging指标和rawstaging文件连续两次为零 |
| 后续矩阵 | W16通过后才允许W32/W64/W96/W128；本RUN未越过失败点 |

## 三、W16结果

| 指标 | 结果 |
|---|---:|
| backing名义容量 | 16 GiB |
| ext4 `df Available` | 16679096320 B，约15.53 GiB |
| staging峰值 | 16339697664 B，约15.22 GiB |
| 峰值/实际Available | 约97.96% |
| fio runtime / jobs / errors | 180067 ms / 128 / 0 |
| fio写入总量 | 464095805440 B，约432.22 GiB |
| 前台正式窗mean / median | 2436.50 / 2774.29 MiB/s |
| CV | 37.54% |
| W1 / W2 / W3 / W4 | 2623.44 / 2918.15 / 2580.05 / 1624.37 MiB/s |
| W4/W1 | 0.6192 |
| 900秒排空终值 | 2 blocks / 524288 B / 2 files |
| effective durable BW | 不计算；排空失败 |

两个残留文件均约262176 B，从staging降到2个文件后持续约14分钟没有变化。正式日志同时记录：

- rawstaging相关ENOSPC约4156条；
- `space not enough on device`直传回退约135.8万条；
- `Upload list is too full`约142条；
- 两次rawstaging到raw缓存的hardlink因ENOSPC失败；
- 4条cache文件创建ENOENT回退记录；
- 未发现`uploadStagingFile`或`<ERROR>`记录。

因此可以确认容量饱和后发生了直传回退，但不能用“最终数据大概率已直传”替代排空硬门。

## 四、与旧20 GiB生命周期canary的关系

RUN `20260903-171855`使用20 GiB backing，实际Available约19.50 GiB，staging峰值约19.10 GiB；
该次可在70秒排空，恢复抽读和环境收口均通过，但因容量口径错误只算生命周期canary，不算W16。

| RUN | 实际Available | foreground mean | W4 | drain | 判定 |
|---|---:|---:|---:|---:|---|
| 20260903-171855 | 19.50 GiB | 2491.63 MiB/s | 1623.21 MiB/s | 70 s | 生命周期canary有效；容量点无效 |
| 20260903-181523 | 15.53 GiB | 2436.50 MiB/s | 1624.37 MiB/s | >900 s且残留 | W16失败 |

两次前台mean只差约2.2%，W4几乎相同，说明有限writeback容量主要吸收前段突发，负载进入后端
回压后仍收敛到约1.62 GiB/s；增加几GiB staging没有改变稳态后端服务率。20 GiB与16 GiB的
生命周期结果不同，也说明临界容量附近存在明显安全边界，不能只看fio前台带宽选档。

### 4.1 对生产决定的量化支持

以当前exact v1.4.1无缓存代表值`2441.1 MiB/s`作为工程参照（不是同窗严格A/B），本轮四等分
窗口的前半段均值为`(2623.44+2918.15)/2 = 2770.80 MiB/s`，约高`13.5%`；其中W2达到
`2918.15 MiB/s`。但180秒全窗均值仅`2436.50 MiB/s`，W4降至`1624.37 MiB/s`。这组数据支持的
准确结论是：

- 在staging尚有余量的短突发阶段，writeback能够提高前台吞吐；
- staging耗尽后，前台重新受约`1.62 GiB/s`的后端排空平台约束；
- 因而收益取决于生产写入占空比和两次突发之间能否完成排空，而不是缓存可以提高后端长期带宽。

旧20 GiB canary在fio结束后70秒排空，也提供了“突发结束后可利用空闲期追平”的实测证据；它只
用于支持该运行机制，不作为正式容量点或固定容量建议。

## 五、实现机制归因与工程意义

下述机制来自与正式日志行为相符的参考源码核对：已知测试二进制对应官方v1.4.1语义并携带
B-catchup补丁，但原始构建命令、工具链与完整制品溯源尚未闭合，因此这里属于实现路径级归因，
不是对该exact binary的逐位源码证明。

1. 参考实现中，`free-space-ratio=0.20`下stage停止阈值使用`freeRatio/2`，即剩余空间低于约10%才标记
   `stageFull`；它不是“保留20%”或“提供固定writeback预算”。
2. 空间检查按秒更新，而128 job可在一个检查间隔内继续高速写入，因而仍可能越过阈值并打到
   ext4 ENOSPC。
3. staging文件写成后还会hardlink到普通cache路径；hardlink因ENOSPC失败时，上层回退为直接上传，
   但已写成的staging文件可能留在rawstaging，形成此次两个长期残留文件。

所以当前问题不是“16 GiB比20 GiB少一点带宽”，而是容量饱和时writeback生命周期不能稳定闭环。
本次W16不得作为生产容量档，但该结果不否定未进入容量临界区的writeback生产使用。

生产交付边界如下：

1. 仅在客户端具有独立、可靠、持久化本地盘且空间充足时启用；不得使用W16作为推荐值；
2. 适用于客户端独占文件和短时突发写；若文件之后要交给其他客户端读取，应先确认staging归零；
3. 独占文件消除了待上传期间的跨客户端可见性冲突，但没有消除本地盘或整机在上传完成前损坏所带来
   的数据风险。远端持久化完成应以staging归零为准，不能只以应用write/close返回为准；
4. 持续监控staging blocks/bytes/最老等待时间、本地剩余空间、ENOSPC和上传错误；rawstaging非空时
   禁止清理缓存目录；
5. 容量按`（突发前台速率－后端排空速率）×最长突发时间＋安全余量`估算。以本轮W2与W4之差
   约`1294 MiB/s`举例，60秒突发约产生`75.8 GiB`净积压，再加30%--50%余量约需
   `99--114 GiB`；这只是按本轮速率计算的示例，正式容量须代入实际业务突发时长。

最终工程决策：writeback作为条件性生产增强配置交付；无缓存配置继续保留为通用基线和空间不足
客户端的回退方案。

## 六、证据与收口状态

权威持久证据：

```text
/mnt/c/SunRise/test/04-tmp2e/20260903-171855/remote-result/
/mnt/c/SunRise/test/04-tmp2e/20260903-181523/w16-review/
```

W16失败证据、fio JSON、128个逐job带宽日志、runtime/drain采样及压缩后的formal daemon日志均已
持久化。执行中曾短暂失去157的SSH连接，因此在状态未知期间没有推进任何sudo；连接恢复后的
精确收口结果为：

- 原formal挂载已优雅卸载；恢复挂载使用同一cache-dir，staging指标和rawstaging文件连续多次为0；
- 恢复日志无`uploadStagingFile`、ENOENT或ERROR，`storage_test.0/63/127` direct抽读通过，128个
  文件仍各1 GiB；这些证据只证明可恢复，不追认原formal排空通过；
- 恢复挂载优雅卸载，cache ext4卸载，loop20经backing反查后精确detach，唯一backing及空RUN目录
  已删除；无本RUN挂载、进程、fio、loop或backing残留；
- `juicefs-data`对象数由`3553464`回到`1979160`，seed为`1979158`；OSD 0--5 compact归零，三
  TiKV endpoint连续三次pending compaction为0；
- `/mnt/juicefs`保持正常，Ceph `HEALTH_OK`、6/6 OSD up/in、97/97 PG `active+clean`；
- failure-closure目录共63项SHA256全量校验通过。

最终环境状态：`ENVIRONMENT_CLOSED`。本RUN未启动W32。
