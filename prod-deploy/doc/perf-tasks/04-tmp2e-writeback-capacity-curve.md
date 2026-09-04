# 04-tmp2e：writeback可用容量与前台/持久化收益曲线

> 日期：2026-09-03
> 级别：`L1_SCREEN`；状态：`COMPLETED_AT_W16_DRAIN_FAILURE / ENVIRONMENT_CLOSED`。
> 承接：04-tmp2b首个写点发生staging残留与ENOENT，证明旧实现不可直接签收；本任务用正常inode
> 密度的容量受控文件系统重新做最小canary，再决定是否展开容量曲线。

> 2026-09-03首次尝试（RUN `20260903-163526`）在W16前停止并判无效：运行时确认
> `cache-size=0`会连带关闭writeback；A0的180秒采样完成后又被240秒外层watchdog在退出排队阶段
> 终止。失败RUN已卸载且未创建loop，证据完整保留；修订为W cell使用`cache-size=1`、watchdog 300秒，
> 并按既有决定取消重复A0。该RUN不得纳入容量曲线。
>
> 第二次pre-fio尝试确认挂载本身已启用writeback，但进程会把`/proc/PID/cmdline`改写并截断，
> 旧门要求完整argv而误停。修订后的进程身份只用二进制、启动时刻和父子拓扑；参数契约由冻结
> runner/commands记录、RUN专属daemon日志、findmnt和metrics标签交叉证明。该次没有执行fio，
> 不构成性能cell，也不允许把截断cmdline继续作为硬门。
>
> 正式W16随后完成128-job fio（rc=0）并在约70秒排空，但在日志检查入口因Bash同行`local`
> 展开触发`set -u`而停止。允许一次`resume-postfio`证据修复：它必须先重新验证fio JSON/运行时、
> sampler、末两次staging=0、当前metrics=0、loop/backing、挂载和PID身份，且只完成原计划中的
> 日志检查、恢复挂载抽读及精确清理；明确禁止再次执行fio。修复失败则本cell失效。
>
> 2026-09-03修正容量RUN `20260903-181523`使用名义16 GiB backing（实际Available约15.53 GiB）。
> fio成功，但staging降到`2 blocks / 524288 B`后持续到900秒硬门仍不归零，判
> `W16_WRITEBACK_DRAIN_FAILURE`并按早停合同取消W32/W64/W96/W128及randrw。恢复挂载使残留归零，
> 三文件抽读和128×1 GiB资产检查通过；loop/backing、对象、OSD/TiKV/Ceph均已精确收口。恢复成功
> 只证明可恢复性，不追认原正式排空或性能点有效。正式报告：
> `doc/perf-report/04-tmp2e-writeback-capacity-curve-20260903.md`。
>
> 生产解释更新：W16硬失败只否决该容量档在持续满压下的排空合同，不否定writeback的短突发
> 吸收价值。项目决定在客户端有充足独立持久空间、文件由单客户端独占且接受异步持久化边界时，
> 将writeback作为条件性生产增强配置；容量和监控合同见正式报告。实验VERDICT和早停事实不变。

```text
UNIQUE_QUESTION=writeback可用本地容量占128GiB写地址集12.5%--100%时，randwrite/randrw的前台带宽、排空时间和有效持久化带宽如何变化
MINIMUM_DECISION_SET=先W16生命周期canary；通过后才展开W32/W64/W96/W128及另一写项
STOP_AFTER_ANSWER=容量曲线可解释，或任一安全/排空硬门明确否决writeback后停止
MAX_PREP_BUDGET=90min
ESTIMATED_WALL_CLOCK=通过canary后约8--12h；canary失败则约1--2h
```

## 一、为什么必须另立任务

JuiceFS `--cache-size`只限制读缓存目标，不是writeback暂存字节上限；在835 GiB公共缓存盘上只改
`cache-size`无法构成写容量实验。本任务为每个cell创建容量受控的RUN专属backing file、loop和
普通ext4，以backing/ext4本身的容量形成写回边界，并在挂载后记录`df`的实际可用字节作为容量
曲线横轴。`--free-space-ratio 0.20`仍保持在挂载参数中，但不得再把它推算成20%保留或写回
暂存上限；该nested-loop只用于容量归因，绝对值不能直接外推为生产裸NVMe性能。

## 二、冻结配置与矩阵

- 二进制、私有`ms_async_op_threads=8`配置、`--max-fuse-io 256K --max-uploads 150`以及默认
  readahead/prefetch与04-tmp2d一致；
- 每个正式/恢复挂载使用独立`--log <RUN专属文件>`采集daemon日志；本版本没有`juicefs log`
  子命令，不得用不存在的子命令补采日志；
- 缓存挂载传`--writeback --free-space-ratio 0.20`，不设置`upload-delay`；
- 所有writeback cell固定`--cache-size 1`（MiB）作为启用writeback所需的最小正值；纯写负载下
  该读缓存可忽略。本任务只改变写回暂存容量，容量由独立ext4的实际可用空间控制，不把
  `cache-size`误当成写回上限；`cache-size=0`会连带禁用writeback，明确禁止用于W cell；
- 正常ext4 inode密度，明确禁止`mkfs.ext4 -T largefile`；
- 每cell一个独立文件系统，任一时刻最多一个RUN专属loop；禁止对`/dev/nvme*`直接mkfs；
- randwrite使用`storage_test.*.0`128×1 GiB；randrw使用`rw_test.*.0`128×1 GiB；均为
  128 job、256 KiB，具体fio参数对齐`FULLBASELINE_V4_U141D.sh`；randrw读写分别报告。

容量定义（修订）：

每个cell使用下列名义backing容量；正式分析的`x`值必须取该cell挂载后`df -B1`记录的
`Available`，而不是名义容量或`free-space-ratio`推算值。ext4元数据会使实际可用值略低于名义值，
最终须同时报告GiB和相对于128 GiB地址集的实际比例。

| Cell | backing/ext4名义容量 | 曲线横轴（挂载后实际`df Available`） | 占128 GiB地址集 |
|---|---:|---:|---:|
| W16 | 16 GiB | 以挂载后`df Available`为准 | 名义12.5%，实际值按`df`计算 |
| W32 | 32 GiB | 以挂载后`df Available`为准 | 名义25%，实际值按`df`计算 |
| W64 | 64 GiB | 以挂载后`df Available`为准 | 名义50%，实际值按`df`计算 |
| W96 | 96 GiB | 以挂载后`df Available`为准 | 名义75%，实际值按`df`计算 |
| W128 | 128 GiB | 以挂载后`df Available`为准 | 名义100%，实际值按`df`计算 |

RUN `20260903-171855` 的旧W16使用20 GiB backing，挂载后`df Available=20,940,644,352 B`
（约19.5025 GiB），staging峰值为`20,507,787,264 B`（约19.0994 GiB，占实际Available的
97.93%）。因此该结果只能作为writeback生命周期canary，明确不得登记为W16容量曲线点；
`--free-space-ratio 0.20`在该实测中没有形成约16 GiB的暂存上限。

执行采用早停结构：

1. 新RUN先以16 GiB backing执行`W16-randwrite`生命周期canary；无缓存基线沿用已有正式结果作量级
   参照，不为本任务重复执行A0，也不把历史参照写成严格同窗因果A/B。旧20 GiB W16结果不复用
   为正式容量点；
2. 只有新的16 GiB W16通过后，才依次执行randwrite的W32/W64/W96/W128；下一阶段先只跑这五个
   randwrite点，每档记录实际`df Available`并执行完整恢复/收口；
3. 五个randwrite点完整通过后，再单独决定是否展开W16/W32/W64/W96/W128 randrw，不预先承诺
   randrw或其sudo操作；
4. 每档一次；只允许对单个证据缺失或容量拐点反常cell做一次定点确认，不重跑整矩阵。

当前脚本已实现五个randwrite容量点，执行顺序冻结为：对每个cell依次执行`run-cell`和同名
`recovery run after-<CELL>`，按`W16→W32→W64→W96→W128`推进，最后统一运行analyzer；任一步
失败即停止并保留该cell现场，不跨过失败点继续。

## 三、时间口径和判定

正式fio默认180秒，外层watchdog为300秒（与既有FULLBASELINE的`runtime+120s`一致）。写点不预热，以便观察缓存吸收突发到后端回压的完整过程；逐秒采集前台带宽、
staging/cache字节与块数、本地NVMe和Ceph数据网流量、upload错误。正式结束后最长等待15分钟，
staging连续两次（间隔10秒）为0才算排空完成。

每个cell结束后都以相同规则执行对象回收与OSD compaction冷却，要求`juicefs-data`对象数回到
RUN起点`+8192`以内、OSD compaction队列归零、TiKV/Ceph重新通过健康门后才进入下一cell。
这里不使用全局`drop_caches`，也不把恢复过程计入前台fio带宽。

每个点同时报告：

```text
foreground_bw = fio正式窗WRITE带宽
drain_time = fio结束到staging连续两次为0的时间
effective_durable_bw = fio写入总字节 / (fio开始到staging排空的总时间)
```

前台加速但`effective_durable_bw`不提高，只能签`WRITEBACK_FRONTEND_ONLY`；不得写成后端持久化
能力提升。容量越大也不要求严格单调，曲线应解释突发吸收时长、回压点和排空代价。

04-tmp2b出现过单次ENOENT。本轮为安全canary，任何`uploadStagingFile`/staging上传错误都立即
停止并保留现场；staging不再下降、15分钟不归零、graceful umount失败、恢复挂载后仍有残留，或
只读抽检发现数据错误，均立即停止并签`WRITEBACK_STAGING_DRAIN_FAILURE`或相应安全结论。

## 四、安全、sudo与收口

- 执行前必须输出每个cell完整的`install/mount/truncate/losetup/mkfs.ext4/mount/chown`及逆向
  `umount/losetup -d/rmdir`计划；用户确认前不得执行任何sudo写；
- loop设备必须由`losetup --find --show --nooverlap`动态获得，并反查backing路径完全一致后才
  mkfs或detach；所有目标必须含固定RUN_ID和CELL；
- 禁止裸盘mkfs、强制/lazy umount、bulk device detach、递归删除、重启以及修改WekaIO/K8s/
  网卡/内核/Ceph/TiKV全局状态；
- 每个写cell结束后必须完成JuiceFS writeback排空、必要的对象回收等待和资产抽检，再销毁该cell
  的loop文件系统；失败时保留精确现场，不跨cell拼接；
- 使用RUN私有Ceph配置执行`ceph tell`时，必须显式指定
  `/etc/ceph/ceph.client.admin.keyring`和`client.admin`；缺少keyring导致的空`perf dump`必须
  fail-closed，不能误判为compaction完成；
- 04-tmp2d完成并关闭环境之前不得启动本任务。

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp2e/<RUN_ID>
REMOTE_RESULT_ROOT=/tmp/production/opencode-04tmp2e-<RUN_ID>
EVIDENCE_RETENTION=SCREEN
REMOTE_CLEANUP=AFTER_REVIEW
LOCAL_COMPACTION=AFTER_REVIEW
ENVIRONMENT_ASSET_CLEANUP=逐cell卸载JuiceFS/ext4、精确detach RUN loop、删除唯一backing file与空RUN目录
```

最终结论只允许是：容量曲线有效、仅前台突发收益、无可交付writeback档，或writeback生命周期
失败。即使存在候选档，也必须另立生产canary验证故障语义，不能由本任务直接进入交付配置。
