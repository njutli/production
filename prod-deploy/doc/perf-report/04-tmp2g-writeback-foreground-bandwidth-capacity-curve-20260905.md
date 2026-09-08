# 04-tmp2g writeback前台带宽—容量订正报告

## 一、结论

```text
RUN_VALID=YES
FIO_ACTIVE_IO_CURVE=FOREGROUND_CAPACITY_SIGNAL
LAUNCH_TO_RETURN_CURVE=RESOLUTION_INSUFFICIENT
ENVIRONMENT=CLOSED
```

在每格固定覆盖写128 GiB、其他参数不变时，fio原始JSON报告的active-I/O聚合带宽随可用cache
从约20 GiB增加到32/64/128 GiB而由W20双锚均值`2641.98 MiB/s`提高到
`3311.08/3849.15/3881.53 MiB/s`，增幅`25.33%/45.69%/46.92%`。该工程曲线单调，且
64→128 GiB只再提高`0.84%`，说明本负载的active-I/O收益在约64 GiB后趋于平台。

预注册的“fio命令启动到返回”墙钟主口径为`2742.65/2169.85/3698.21 MiB/s`，其中W64在
active-I/O前出现`25.65s`额外前台开销，导致墙钟曲线不单调，故该口径必须签
`RESOLUTION_INSUFFICIENT`。两种结果不矛盾：writeback容量确实提高实际I/O阶段吞吐，但单次
128进程fio启动/打开文件开销会扰动“整条命令”均值；本RUN不能证明该开销由cache容量造成。

## 二、结果

| Cell | 实际可用GiB | fio active-I/O MiB/s | 相对W20锚 | 启动—返回MiB/s | 非active-I/O前台开销 | 严格排空 | 裁决 |
|---|---:|---:|---:|---:|---:|---:|---|
| W20A | 19.502 | 2733.94 | 锚A | 2656.79 | 0.92s | 33s | `OBSERVED_SAFE_POINT` |
| W32 | 31.185 | 3311.08 | +25.33% | 2742.65 | 7.47s | 75s | `OBSERVED_SAFE_POINT` |
| W64 | 62.429 | 3849.15 | +45.69% | 2169.85 | 25.65s | 264s | `OBSERVED_SAFE_POINT` |
| W128 | 124.917 | 3881.53 | +46.92% | 3698.21 | 1.19s | 239s | `OBSERVED_SAFE_POINT` |
| W20B | 19.502 | 2550.03 | 锚B | 2486.33 | 0.93s | 89s | `OBSERVED_SAFE_POINT` |

W20B相对W20A的active-I/O/墙钟漂移分别为`-6.73%/-6.42%`，均通过预注册8%门。五格均为
128 jobs、每job精确写1 GiB、总计128 GiB、`error=0`；没有ENOSPC、hardlink或非容量上传错误。

标准fio口径直接来自各job `write.bw_bytes`之和；启动—返回口径来自紧贴唯一一次fio调用的纳秒
sidecar。W64的fio JSON `elapsed=61s`与60.406s墙钟相符，而最大job runtime仅34.760s，证明
25.65s差额是真实命令内非active-I/O开销，不是重复fio或时间戳错误。该异常值完整保留。

## 三、为什么128 GiB写入没有全部驻留在128 GiB cache中

“逻辑写入量128 GiB、可用cache约128 GiB”不等于“128 GiB数据全部先留在本地，写完后才开始
上传”。本RUN使用`--writeback --max-uploads 150`，前台把脏块写入本地staging的同时，后台上传
线程持续向Ceph排空；cache需要容纳的是任一时刻的**净脏数据积压峰值**，而不是整轮逻辑写入量：

```text
净脏数据积压 ≈ 累计前台接收量 - 累计后台上传量
```

实测W64可用容量`62.429 GiB`、staging峰值`52.632 GiB`（84.31%）；W128可用容量
`124.917 GiB`、staging峰值也只有`53.202 GiB`（42.59%）。两个档位的脏数据峰值仅相差
`0.570 GiB`，说明128 GiB档从未把整轮128 GiB数据同时缓存下来，约64 GiB已经覆盖本负载约
53 GiB的最大净积压。运行期网卡发送计数在W64/W128采样窗口内分别增长约`82.07/76.18 GiB`，
也从侧面证明后台上传与前台写入并行发生；该计数包含主机其他流量，只作为并行上传佐证，不用于
精确核算Ceph有效数据量。

因此，20→64 GiB解除cache空间压力后，active-I/O带宽提高约46%；64→128 GiB只增加容量余量，
没有增加FUSE、JuiceFS切片与staging、本地NVMe/loop/ext4及后台上传流水线的处理能力，故只再提高
0.84%。本RUN只能确认“容量不再是主要约束”，尚不能在这些剩余环节之间精确归因约3.9 GiB/s的
平台上限。

这与读缓存的大幅收益并不矛盾：读缓存命中可以绕过Ceph/RADOS/网络，并可能进一步命中Linux页
缓存；writeback则仍要让每个字节经过FUSE和JuiceFS处理并持久暂存到本地盘，后台上传也同时读取
本地数据。因此writeback容量的作用是吸收前台生成速率与后台上传速率之间的短时差额，不是提供
“全部写入只走内存”的快速路径。若强行停止上传来让128 GiB全部驻留，只能测到本地暂存上限，
会改变生产语义并增加空间耗尽风险，不应作为本报告的生产代表结果。

## 四、对04-tmp2f的订正与生产意义

- 04-tmp2f固定180秒，实际每格写入约430--512 GiB，回答的是持续压力和排空能力；不能用
  “cache/128 GiB逻辑数据集比例”解释其前台均值。
- 本RUN固定脏写量为128 GiB，确认cache从约20 GiB增至64 GiB可把active-I/O带宽提高约46%，
  继续增至128 GiB的带宽增量很小。
- 128 GiB档在本次固定128 GiB突发下239秒严格排空；这不撤销04-tmp2f中“持续180秒写入后
  900秒仍未排空”的结论。容量必须按业务突发净积压与可用排空窗口规划，不能只看数据集比例。
- writeback仍可作为客户端有持久本地空间、文件由单客户端独占写、允许异步可见性的条件性生产
  增强。工程上可优先从约64 GiB容量做业务占空比canary；不能把128 GiB写成普适最优值。
- 不建议为本L1再重跑整套五格。若生产决策必须精确到容量百分比，只需在业务真实并发模型下复核
  32/64 GiB及排空窗口；fio进程初始化开销应与存储active-I/O带宽分开报告。

## 五、有效性、修复和环境收口

- 首次pause在任何状态写前遇到1个例行scrubbing PG并退出；PG恢复clean后同RUN重试成功。
- W20A完成后发现recovery只接受旧`W20`标签；仅扩展为冻结矩阵的`W20A/W20B/32/64/128`，
  新旧SHA和incident均保留，性能路径未修改。
- 初版分析器错误要求墙钟接近最大job runtime；raw显示墙钟与fio JSON `elapsed`一致，因此修为
  `elapsed`校验墙钟并单列非active-I/O开销。修复不修改fio、bw log或任何环境证据。
- 五格均完成严格排空、恢复抽读、精确unmount/detach/backing清理、GC、六OSD compact和TiKV
  cooldown；最终对象数回到seed容差内。
- 终态无本RUN mount、loop、fio、runner或backing；业务挂载正常，128文件inode/size清单SHA与
  inventory一致；Ceph `HEALTH_OK`、6/6 OSD、97 PG `active+clean`，scrub flags已恢复。

## 六、证据索引

- 权威证据：`/mnt/c/SunRise/test/04-tmp2g/20260905-160001/`
- 远端原始manifest：`manifest.sha256`，`1202/1202 PASS`
- GPT独立复算：`gpt-review/analysis-independent-v2.json`
- 执行侧复算：`derived/analysis.json`
- 原始fio：`cells/<CELL>/fio.json`；逐job日志：`cells/<CELL>/bw/`
- 两项脚本修复：`incidents/recovery-label-repair/`、`incidents/analyzer-timing-repair/`
- 本地原始归档：`raw-archive.tar.gz`，SHA256
  `2d954eec9f6378f30dac694e883596a1fdc01a2e24153ff6c87d94d018dd2e02`

远端最后一份raw暂保留至报告审核后清理；这不影响性能结论或环境终态。
