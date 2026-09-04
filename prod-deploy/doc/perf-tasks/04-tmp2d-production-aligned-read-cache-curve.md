# 04-tmp2d：交付配置对齐的读缓存容量曲线

> 日期：2026-09-03  
> 级别：`L1_SCREEN`；执行方：Luna；审核方：GPT。  
> 承接：04-tmp2c 已确认热数据近全驻留时 randread 可达约 34.5 GiB/s，但其
> cache=0 锚点误用了 Ceph 默认 `ms_async_op_threads=3`，且显式关闭了 prefetch，
> 不能与当前交付基线严格比较。本任务只订正读侧口径，不开启 writeback。

```text
UNIQUE_QUESTION=交付配置下，缓存占原生读工作集25%/50%/75%/100%/200%时，mseqread与randread的收益曲线是什么
MINIMUM_DECISION_SET=每项A0-pre+C25+C50+C75+C100+C200+A0-post，共14个cell；异常时只定点确认
STOP_AFTER_ANSWER=两项曲线、命中率、后端卸载比例和同窗锚点漂移可解释后停止
MAX_PREP_BUDGET=60min
ESTIMATED_WALL_CLOCK=2--3h
```

## 一、冻结配置与数据集

- 二进制：`/tmp/juicefs-1.4.1-patched`，MD5
  `24fae0852051c80ca571cb2f20275d46`；
- Ceph：进程私有 `CEPH_CONF`，MD5 `86351c58848c7e4caaa1bbeccb211730`，
  唯一额外客户端项为 `[client] ms_async_op_threads = 8`；禁止使用系统默认配置替代；
- mount：`--max-fuse-io 256K --max-uploads 150`；保持默认 readahead/prefetch，禁止显式传
  `--max-readahead 0`或`--prefetch 0`；缓存臂另传
  `--cache-dir --cache-size --free-space-ratio 0.20`，锚点传`--cache-size 0`；
- 明确禁止`--writeback`、新pool、新卷、新layout、全局`drop_caches`及写入测试资产；
- 缓存介质：157现有原生ext4 `/mnt/jfs-cache`，每个cell使用独立空目录；
- mseqread：`mseqread/`下16×4 GiB，原生工作集64 GiB，16 job、256 KiB；
- randread：`read_test.*.0`共128×1 GiB，原生工作集128 GiB，128 job、256 KiB；
- fio的I/O参数必须与`FULLBASELINE_V4_U141D.sh`对应测试项一致；正式运行180秒。为保留每个job的
  独立逐秒日志，本任务不启用只影响输出聚合的`group_reporting`，不改变实际I/O模型。

## 二、最小矩阵

每项依次执行：`A0-pre → C25 → C50 → C75 → C100 → C200 → A0-post`。

| 项目 | C25 | C50 | C75 | C100 | C200 |
|---|---:|---:|---:|---:|---:|
| mseqread（64 GiB） | 16 GiB | 32 GiB | 48 GiB | 64 GiB | 128 GiB |
| randread（128 GiB） | 32 GiB | 64 GiB | 96 GiB | 128 GiB | 256 GiB |

- 缓存cell：空缓存挂载，同负载预热180秒，再正式180秒；
- A0：不预热，只正式180秒；A0-pre/post用于量化同窗漂移；
- 每档一次即可。只有C75/C100关系反常、运行未进入稳态或证据缺失时，允许对受影响点做一次
  定点确认；不得重跑整张矩阵。

## 三、证据与判读

每cell至少保存：实际mount/fio命令、私有CEPH_CONF文件MD5与实际8个`msgr-worker`线程（守护化后
`/proc/<pid>/environ`不保留该变量，故不把环境变量残留作为硬门）、挂载PID/启动时间、fio JSON、
逐job逐秒bw日志、预热前/后及正式后blockcache metrics、缓存文件数和字节、正确Ceph数据网卡
RX/TX、Ceph health/PG、fio前后资产名称/inode/size/mtime。

主输出：正式窗`[15,175)`的mean/median/CV/P10/P90/W1--W4，cache命中率、实际驻留字节、
evicts/drops、Ceph RX/逻辑读取量，以及相对同项A0双锚均值的收益。历史最优值
`mseqread=5366 MiB/s`、`randread=5544 MiB/s`只作外部一致性检查，正式收益以同窗A0为准。

硬门仅限非性能完整性和安全事实：fio/采样错误、实际配置不符、资产漂移、错误网卡、挂载身份
错误、Ceph非`HEALTH_OK/active+clean`、外来fio或目录越界。`drops/evicts`、命中率、带宽CV和
容量非单调均是产品表现，应进入结果解释，不能据此把已完整采集的cell判成证据无效。

判读边界：

- C75用于定位50%到100%之间的容量拐点，不预设严格单调；
- C200只用于确认全驻留平台，不宣称超额缓存必然更快；
- mseqread低并发可能不受`ms_async_op_threads=8`直接加速，但仍必须用同一交付配置；
- 本任务形成容量/收益曲线和生产canary候选，不直接修改交付配置。

## 四、安全、授权与生命周期

- 禁止触碰WekaIO、K8s、网卡、内核、Ceph/TiKV配置与服务、`/mnt/juicefs`参考挂载；
- 禁止重启、kill业务进程、强制/lazy umount、裸盘/loop/mkfs以及递归清理非RUN目录；
- 唯一预计sudo写操作是在固定RUN_ID后精确创建和最终删除
  `/mnt/jfs-cache/jfs-04tmp2d-<RUN_ID>`；执行前必须展开完整命令并由用户确认；
- cell缓存内容由属主在路径守卫后清空；RUN根仅在空目录、非挂载点且证据已持久化后`rmdir`；
- 任一现场事实与任务书不符，立即停在只读证据收集，不自行改变实验变量。

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2d/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2d-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=逐cell卸载测试挂载并清空其缓存目录；最终精确rmdir RUN缓存根
```

执行停点只有两个：离线Gate+只读inventory/plan后等待sudo授权；14个cell连续执行并持久化后，
GPT复算、写报告并决定是否进行最终sudo空目录删除。数据生命周期遵循
`TEST-DATA-LIFECYCLE-POLICY.md`，公共证据只复制一次，cell只增量回传。
