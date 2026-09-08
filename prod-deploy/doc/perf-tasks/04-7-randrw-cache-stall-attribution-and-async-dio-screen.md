# 04-7：randrw 缓存停顿归因与 `async_dio` 最小筛选

- 日期：2026-09-07
- 修订：r3（精简版，替代 r2）
- 状态：`COMPLETED / STOP_NEGATIVE / ENVIRONMENT_CLOSED`
- 历史审计：[04-7-L0-randrw-cache-stall-historical-audit-20260907.md](../perf-report/04-7-L0-randrw-cache-stall-historical-audit-20260907.md)
- 正式报告：[04-7-randrw-cache-stall-attribution-and-async-dio-screen-20260908.md](../perf-report/04-7-randrw-cache-stall-attribution-and-async-dio-screen-20260908.md)
- 持久证据：`/mnt/c/SunRise/test/04-7/20260907-l0-audit/`
- 在线证据：`/mnt/c/SunRise/test/04-7/20260908-095000/final/`

```text
TASKBOOK_REVISION=r3
EVIDENCE_LEVEL=L1_SCREEN
L0_AUDIT=PASS
ONLINE_ROUTE=CONDITIONAL_ABBA
MINIMUM_DECISION_SET=P25:A1-B1-B2-A2
STOP_AFTER_ANSWER=YES
MAX_PREP_BUDGET=60min
MAX_NEW_LOAD_BUDGET=3h
PRIMARY_ENDPOINT=fio_JSON_full_timed_run_directional_bandwidth
PRODUCTION_CHANGE=NONE
```

执行结果：RUN `20260908-095000` 的 `A1-B1-B2-A2` 四格及生命周期全部通过；`async_dio`
两次配对使方向均值带宽下降 `11.45%/13.03%`，判定 `STOP_NEGATIVE`，本方向关闭且不改生产配置。

## 一、只回答一个问题

在 04-tmp2i 的 P25 合同下，仅增加 JuiceFS 挂载参数 `-o async_dio`，能否：

1. 稳定提高 randrw 全程读、写带宽；
2. 减少所有 job 同时停止记录的停顿；
3. 不引入 writeback 排空、读回或恢复失败。

本任务是机制筛选，不是生产配置验收。P25 已被 04-tmp2i 判定为负向配置；只有本任务出现材料级、
可重复的正向信号，才另行决定是否进入更严格验证。不得在本任务中追加缓存容量、QD、全量基线或
生产变更矩阵。

## 二、L0 已完成，不再重做

冻结 raw：

```text
/mnt/c/SunRise/test/04-tmp2i/20260906-201646/final/raw/04-tmp2i-20260906-201646.tar
SHA256=162f3e661b64497de76acf9760549ef13bcb51883e04832e50def5db90276fcd
```

审计结论：

- P25 全程读、写带宽相对插值 A0 分别下降 `16.85%`、`16.91%`，这一总量结论有效；
- P25 独有 63 秒全 job 同步无记录区间，其中 52 秒位于正式 180 秒运行内部；
- 128 个 job 的最大 READ slat 均约 `19.05--19.41 s`，其他格仅约 `0.39--0.75 s`；
- 旧分析器跨空洞回填字节，使 P25 分段积分达到 fio JSON 总量的约 `121%`；因此旧 P25 的
  W1--W4、W4/W1、CV、P10/P90 无效，但 fio JSON 全程总量仍有效；
- 不同空洞期间的缓存计数器行为不同，证据支持“读提交路径发生同步停顿”，但尚不能归结为单一的
  “缓存已满”或整个 fio 进程停止。

因此在线阶段只需回答 `async_dio` 是否能改变这一现象，不再重复历史归档和统计口径探索。

## 三、冻结实验合同

### 3.1 固定项

| 项目 | 固定值 |
|---|---|
| 客户端 | `157` |
| JuiceFS | patched v1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46` |
| 文件集 | 既有 `test_dir/rw_test.$jobnum.0`，128 个 1 GiB 文件 |
| layout/卷 | 不 format、不 destroy、不重做 layout |
| 通用挂载 | `--max-uploads 150 --max-fuse-io 256K --free-space-ratio .20` |
| P25 缓存 | `--writeback --cache-size 31978` |
| fio | `libaio`、`iodepth=128`、`direct=1`、`bs=256K`、`randrw`、`rwmixread=50`、`size=1G`、`numjobs=128`、`runtime=180`、固定 seed |
| 每格预热 | 同文件集 `randread` 180 秒 |
| OS 页缓存 | 不执行 `drop_caches` |

缓存介质使用一个 RUN 专属的 128 GiB backing file、动态 loop 和 ext4，挂到
`/mnt/jfs-cache`。四格复用同一个 backing/loop；格间只对精确 RUN 资产重新创建空 ext4，避免引入
不同 loop 或物理位置变量。

### 3.2 唯一自变量

- A：不含 `-o async_dio`；
- B：只增加 `-o async_dio`。

顺序固定为：

```text
A1 -> B1 -> B2 -> A2
```

记录实际 argv、二进制哈希、worker PID/starttime、FUSE connection ID 和
`max_background`。能确认 B 挂载成功且实际 argv 含 `async_dio`，即可执行 L1；若不能直接从内核
接口证明能力生效，报告标记 `CAPABILITY_EVIDENCE=INFERRED`，不阻塞负向筛选。若结果为正，进入
更高等级验证前必须补强能力证明。

## 四、稳定性与生命周期

1. 整个 A-B-B-A 矩阵使用既有 scrub 控制租约暂停 scrub/deep-scrub，结束后精确恢复原值；
2. 开始前只检查一次 Ceph health、PG、OSD 状态、compact 状态和基线对象数 `O0`；
3. 每个正式 randrw 格结束后必须依次完成：
   - 最长 900 秒 writeback 严格排空；
   - graceful unmount；
   - cache=0 读回抽检；
   - 已授权的 JuiceFS GC、OSD compact 与固定冷却；
   - Ceph health 恢复且对象数回到 `O0 ± 8192`；
4. 上述四个正式写格对应四次恢复边界；不得加入每格 meta randwrite 探针、多挂载抽签或额外压力档；
5. 任一排空、读回、对象回收或健康门失败，立即停止新负载、保留现场并报告，不得跳过硬门续跑。

## 五、测量口径

### 5.1 主性能端点

以每格 fio JSON 的完整 180 秒 timed run 为唯一带宽主口径：

```text
READ_MiBps  = sum(read.io_bytes)  / max(read.runtime_ms)  / 1024^2 * 1000
WRITE_MiBps = sum(write.io_bytes) / max(write.runtime_ms) / 1024^2 * 1000
MEAN_MiBps  = (READ_MiBps + WRITE_MiBps) / 2
```

停顿属于真实结果，不能从主端点删除。job bw log 只用于识别同步无记录区间，不得跨空洞补值；同时
报告 READ/WRITE 的 slat、clat、total latency 加权均值和真实最大值。

### 5.2 低扰动归因

正式窗口以 1 Hz 采集轻量级缓存、FUSE、NIC 和客户端进程指标；禁止在正式窗口执行 `find`、`du`
或目录全量扫描。

若连续两个成功采样点均显示 fio 存活而所有 job 无完成，单格最多触发一次只读快照：相关进程的
`/proc/*/{wchan,status}`，以及仅在既有 endpoint 可用时采集一次有界 pprof。不得发送信号、使用
strace/eBPF 或修改内核。归因快照失败不使带宽结果失效。

## 六、判定规则

按方向和均值计算：

```text
P1 = B1 / A1 - 1
P2 = B2 / A2 - 1
epsilon = max(abs(A2/A1-1), abs(B2/B1-1))
M = max(10%, 2*epsilon)
```

- `RESOLUTION_INSUFFICIENT`：`epsilon >= 10%`；
- `CONTINUE_CANDIDATE`：两次 `P_mean >= M`，READ/WRITE 均无任一配对 `< -M`，同步无记录负担或
  total latency 至少一项材料改善，且四格生命周期全通过；
- `STOP_NEGATIVE`：两次均材料退化，或 B 新增排空/读回/恢复失败；
- `STOP_NO_SIGNAL`：矩阵有效且稳定，但未达到材料收益门；
- `INCONCLUSIVE`：两个配对方向冲突且不满足以上条件。

本任务不设置 30% 压力折算、不做 CI、不直接改变生产配置。

## 七、最短执行流程

### Phase 0：已完成

采用现有 L0 报告和持久证据，不再重跑。

### Phase 1：薄脚本与离线 Gate 0

优先复用 04-tmp2i/04-tmp2j 的挂载、fio、排空、恢复和归档逻辑；只允许新增薄执行器、分析器和
Gate。准备时间上限 60 分钟。Gate 只验证：A/B 唯一变量、A-B-B-A 顺序、fio JSON 主端点、空洞不
回填、RUN 资产归属以及危险命令扫描。

### Phase 2：只读 inventory 与变更计划

生成实际命令、精确对象和 sudo 计划；到此暂停，等待用户一次性授权。任务书本身不授权任何命令。

### Phase 3：连续执行

获得授权后连续完成 A1-B1-B2-A2；除安全硬门失败外不逐格等待人工确认。正常预计 `1.5--2.5 h`，
新负载最长 `3 h`；安全恢复不受该上限约束。

### Phase 4：分析与收口

独立复算主端点和判定，持久化证据，恢复 scrub 原值，清除精确 RUN 资产并完成报告。

## 八、安全边界与 sudo 类别

禁止重启生产服务、修改 TiKV/OSD 参数、改网络/Kubernetes/Weka、操作 pool/volume 生命周期、改
生产挂载或全局 drop_caches。

待 Phase 2 审核的 sudo 仅允许包含：

- scrub 租约的精确设置与恢复；
- RUN 专属缓存目录、loop、mkfs、mount、umount 和空目录删除；
- 既有恢复合同中的 JuiceFS GC、指定 OSD compact 及只读 perf 查询。

严禁 `rm -rf`、`losetup -D`、`pkill`、`killall`、`fuser -k`、force/lazy unmount、reboot，以及
任何未经计划列出的扩大范围操作。

## 九、证据与结束状态

持久目录固定为：

```text
/mnt/c/SunRise/test/04-7/<RUN_ID>/
```

公共证据只复制一次；逐格保留 fio JSON、bw log、轻量指标、生命周期门和必要 incident；生成
manifest 并校验后才能清理远端副本。

最终只允许以下状态之一：

```text
CONTINUE_CANDIDATE
STOP_NEGATIVE
STOP_NO_SIGNAL
RESOLUTION_INSUFFICIENT
INCONCLUSIVE
SAFETY_ABORT
```

除 `CONTINUE_CANDIDATE` 外均关闭本方向；即使为正，也只进入另立的最小 L2/生产回归，不在本任务
追加测试。

## 十、执行纪律

遵循：

- `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`
- `doc/perf-tasks/TEST-DATA-LIFECYCLE-POLICY.md`
- `SYSTEM-SAFETY-SKILL.md`

任何脚本便利性不得扩大本任务的变量、矩阵和环境权限。
