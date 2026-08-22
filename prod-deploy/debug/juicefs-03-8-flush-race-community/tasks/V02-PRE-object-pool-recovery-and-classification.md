# V02-PRE：V02 前置对象池恢复、分类与洁净交接

> 执行方：GLM　｜　计划/复核方：Codex　｜　编写日期：2026-08-18  
> 性质：V02 的独立环境前置任务；不运行补丁性能测试，不产生任何 S/A/B 性能结论  
> 执行位置：经本轮明确授权的 `ssh thailand`（客户端 157）和测试集群  
> 预计：自然观察 3～6 小时；条件性单次 compact/扫描可能额外数小时  
> 重要：本任务书本身不授权 SSH、mount/umount、`juicefs gc --compact` 或 OSD compact；必须先满足 §三

---

## 计划线

```text
V01/V02 首轮
  ├─ pool objects 18.34M → 7.46M，说明曾发生回收
  └─ 7.46M > 3.11M，V02 正确停止且未运行 fio
★ V02-PRE（你在这里）
  ├─ 核清遗留 drain mount 与后台清理是否真实工作
  ├─ 观察完整小时级周期；必要时只做一次 gc --compact
  ├─ 仍不达门则只扫描分类，绝不 --delete
  └─ 只有低对象数 + 资产完整 + 挂载全退才签 READY
V02
  ├─ 复核 PRE 凭证和实时 3.11M 门
  └─ 再执行 v1.3 S/A/B 性能与完整性矩阵
```

一句话：本任务只把 V02 所需的测试卷恢复到可鉴别、可安全起跑的低对象状态，并把
“可自然/compact 恢复”与“需要另行删除决策或新卷”机械分开。

---

## 〇、背景与已知事实

### 0.1 当前阻塞

权威输入：

```text
ROOT=/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community
V02_TASK=$ROOT/tasks/V02-v131-SAB-performance-validation.md
V02_REPORT=$ROOT/report/V02-execution-20260818-143450.md
POOL=juicefs-data
START_OBJECTS_MAX=3110000
HARD_OBJECTS_MAX=8000000
```

V02 首轮在 2026-08-18 13:36（157 本地时间）记录：

```text
health=HEALTH_OK
objects=7,461,762
stored=1.96 TiB
max_avail=25 TiB
```

历史低对象基线约为 2.36M / 576 GiB。`3.11M` 不是纯容量阈值，而是已有 randrw
有效性边界；当前对象数下不能通过放宽门槛取得健康态绝对性能结论。

### 0.2 不能混淆的三种 GC

1. JuiceFS 挂载客户端的后台清理：按带抖动的小时级周期执行，会呈“平台后突降”，
   不是连续线性下降。
2. `juicefs gc --compact`：合并有效碎片，并可清理由本次 compaction 淘汰的 slice；
   不是对所有 delayed/pending/leaked 对象的强制删除。
3. TiKV GC：回收元数据 MVCC 旧版本；它不会直接删除 Ceph `juicefs-data` 对象。

因此不得把 TiKV safe-point/compaction 与 Ceph pool objects 下降写成同一件事。

### 0.3 必须先解释的现场矛盾

V01-R1 报告写“`/mnt/juicefs-v01-drain` 已卸载”，但 V02 post-early 快照仍看到该挂载，
且进程身份含历史 PID `1859211`。本任务必须先核实：

- mount 是否仍真实存在，而不是快照/namespace 误读；
- PID/starttime/exe/argv hash 是否与该 mount 一一对应；
- 是否有 `--read-only`、`--no-bgjob` 或 `--max-deletes=0`；
- 它是可证明的旧任务挂载、未知挂载，还是已失去 FUSE 会话的残留。

未完成归属核验前禁止新建第二个 drain mount，也禁止卸载或终止它。

---

## 一、目标、非目标与允许终态

### 1.1 唯一主目标

只有下列条件同时成立，才可签发 `READY-V02-LOW-OBJECT`：

1. `juicefs-data` 连续三次有效采样均 `objects <= 3,110,000`；
2. 三次间隔各至少 120 秒，最后一次 health/PG/OSD 全绿；
3. pool_id、pg_num/pgp_num、CRUSH map hash、Ceph config hash未改变；
4. 既有 `storage_test`、`rw_test`、`mseqread` 文件数量和大小门通过；
5. `/mnt/juicefs` 身份与任务前一致，业务保护项无异常；
6. PRE 创建或明确接管的 drain mount 已优雅卸载并证明 mount/process gone；
7. 没有运行中的 task gc/compact，OSD 三指标全绿；
8. 无 `gc --delete`、destroy、format、pool/PG/CRUSH/config/restart 或数据删除。

### 1.2 次要问题

- 对象下降是否来自可观察的小时级后台清理；
- 单次 `gc --compact` 是否足以回到有效起点；
- 若仍高，对象主要属于 valid、pending/trash、leaked 还是 recent skipped；
- 下一步应继续等待、另发受控 delete 维护任务，还是改用独立卷/pool。

这些只用于分流，不得写成 B 补丁或 V02 性能结论。

### 1.3 本任务不做

- 不运行 fio、mseqread、ns/B、drop_caches 或任何 S/A/B 性能/正确性测试；
- 不构建或替换 JuiceFS 生产二进制；
- 不执行 `juicefs gc --delete`、destroy、format、pool delete/create；
- 不删除 `test_dir`、旧 layout、未知目录或任何业务数据；
- 不改 Ceph/TiKV/JuiceFS/网络/内核参数；
- 不重启 OSD、TiKV、客户端或任何主机；
- 不做社区写入。

### 1.4 允许终态

```text
READY-V02-LOW-OBJECT
BLOCKED-AUTH
BLOCKED-REMOTE-OR-IDENTITY
BLOCKED-UNKNOWN-OR-UNOWNED-DRAIN-MOUNT
BLOCKED-BACKGROUND-CLEANUP-STALLED
BLOCKED-COMPACT-NOT-AUTHORIZED
BLOCKED-COMPACT-OR-HEALTH
BLOCKED-ASSET-GATE
BLOCKED-PENDING-OR-LEAKED-REQUIRES-NEW-PLAN
INVALID-LIVE-FLOOR-ABOVE-GATE
INVALID-EXTERNAL-WRITE-OR-ENVIRONMENT-DRIFT
PARTIAL-V02-PRE
V02-PRE-NON-COMPLIANT
```

`READY-*` 只允许把凭证交给 V02；不自动启动 V02，也不继承本轮授权。

---

## 二、固定范围、工具与目录

### 2.1 固定环境身份

```text
EXPECTED_CLIENT=157
POOL=juicefs-data
OLD_DRAIN_MNT=/mnt/juicefs-v01-drain
PRE_DRAIN_MNT=/mnt/juicefs-v02-pre-drain
PROTECTED_MNT=/mnt/juicefs
```

META 必须从既有受保护来源读入内存，禁止写入任务书、环境快照、命令日志或 archive。
命令记录一律使用字面 `$META`，另存只含 scheme/endpoint count/volume-name hash 的脱敏
identity。禁止在命令行调试输出中回显完整 META。

### 2.2 唯一允许的 JuiceFS 工具

优先核验既有测试二进制：

```text
GC_BIN=/tmp/juicefs-03-8
```

它只有同时满足以下条件才可用于本任务：

- 是普通文件、非 symlink，`file`/`ldd`/version 正常；
- SHA256/MD5/size/ELF build-id 已冻结；
- 若存在旧 drain mount，其 exe hash 必须与该二进制一致；
- 可加载当前 Ceph runtime；
- 不覆盖、不 chmod、不移动该文件。

任一不满足则停止 `BLOCKED-REMOTE-OR-IDENTITY`；不得改用
`/usr/local/bin/juicefs`、临时下载或其它未知 binary。

### 2.3 任务目录

```text
RUN_ID=YYYYmmdd-HHMMSS
CTRL=/home/lilingfeng/tmp/juicefs-v02-pre-control-$RUN_ID
REMOTE_OUT=/tmp/juicefs-v02-pre-$RUN_ID
REMOTE_ARCHIVE=/tmp/juicefs-v02-pre-$RUN_ID.tar.gz
REMOTE_ARCHIVE_SHA=/tmp/juicefs-v02-pre-$RUN_ID.tar.gz.sha256
LOCAL_ARCHIVE=/home/lilingfeng/tmp/juicefs-v02-pre-$RUN_ID.tar.gz
LOCAL_ARCHIVE_SHA=/home/lilingfeng/tmp/juicefs-v02-pre-$RUN_ID.tar.gz.sha256
REPORT=$ROOT/report/V02-PRE-execution-$RUN_ID.md
REPORT_SHA=$ROOT/report/V02-PRE-execution-$RUN_ID.md.sha256
READY_RECEIPT=$REMOTE_OUT/handoff/V02-PRE-READY.tsv
READY_RECEIPT_SHA=$REMOTE_OUT/handoff/V02-PRE-READY.tsv.sha256
```

所有目录启动前必须不存在；冲突时换 RUN_ID，禁止删除旧目录。PRE 只可创建这些精确
路径和条件性 `PRE_DRAIN_MNT`。本轮不得清理历史 V01/V02 证据目录。

### 2.4 固定阈值

```text
READY_OBJECTS_MAX=3110000
OBSERVE_FIRST_SEC=10800       # 3h
OBSERVE_MAX_SEC=21600         # 最多 6h
OBJECT_POLL_SEC=120
HEALTH_POLL_SEC=600
MEANINGFUL_DROP=100000        # 仅用于判断是否继续观察，不是 READY 门
EXTERNAL_RISE_STOP=100000
MAX_AVAIL_MIN_TIB=10
```

不得临时提高 READY 门或用 UsedSpace/UsedInodes 替代 Ceph pool objects。

---

## 三、授权和分层执行门

### 3.1 未授权时

只允许读取本地任务书、旧报告和固定源码文档；禁止创建远端目录、SSH、mount、umount、
gc、compact 或 sudo。此前 V01/V02 的授权不自动继承。

### 3.2 建议的本轮授权原文

用户必须明确确认该 META/POOL 是允许维护的测试卷，而不是业务卷，并逐字保存授权：

> 我授权执行 V02-PRE 任务书：确认本轮指定的 META 对应允许维护的测试卷和
> `juicefs-data` pool；允许通过 `ssh thailand`/scp 访问客户端 157，只在
> `/tmp/juicefs-v02-pre-*`、`/mnt/juicefs-v02-pre-drain` 操作；允许只读核验
> `/mnt/juicefs-v01-drain`，并仅在其 mount/PID/starttime/exe hash 与 V01 记录完全匹配、
> 可证明为旧任务遗留时优雅卸载；允许使用已核验的 `/tmp/juicefs-03-8` 创建一个无 fio、
> `--backup-meta 0`、后台清理启用的 PRE drain mount；允许连续只读采集 health、PG/OSD、
> pool objects/stored/max_avail、挂载身份和允许字段；自然观察未就绪时，允许最多执行一次
> `juicefs gc --compact $META`，随后最多执行一轮 OSD compact 与只读 cooldown；若该次
> compact 未提供完整分类，允许最多执行一次不带 `--compact`、不带 `--delete` 的
> `juicefs gc $META` 扫描。禁止 `gc --delete`、destroy、format、pool/PG/CRUSH 增删改、
> 配置修改、drop_caches、fio、删除测试/业务数据、服务/节点重启、系统二进制替换和社区写入。

若授权未明确包含“该卷可维护”、单次 JuiceFS compact 和单轮 OSD compact，则只执行
自然观察；需要 compact 时终态 `BLOCKED-COMPACT-NOT-AUTHORIZED`。若未授权 scan-only，
compact 后无法分类时停止，不得自行扩大权限。

### 3.3 sudo 边界

- sudo 只允许任务书列出的 Ceph 只读查询、一次 `ceph tell osd.<id> compact` 和必要的
  精确 mountpoint 优雅 umount；
- 所有 sudo 必须 `sudo -n`，先在同一会话 `sudo -n true`；出现密码提示立即停止；
- OSD 动态枚举后逐个串行 compact，禁止并行；
- 禁止把密码写入 stdin、脚本、日志或环境变量。

### 3.4 可自主修复与禁止改变

可以修复：task-owned 路径、quoting、采样 parser、日志命名、SSH 两次有界重连；所有
修复写入 `adaptations.tsv`，脚本重新 `bash -n` 并冻结新 SHA。

不得改变：卷/pool、阈值、观察时长、GC pass 数、GC flags、mount 参数、授权范围、
READY 判据。必须改变时停止报告。

---

## 四、步骤 0：必读、静态预飞与脚本冻结

### 4.1 必读

在 `preflight-review.md` 逐项确认：

1. 本任务书和修订后的 V02；
2. `skills/SYSTEM-SAFETY-SKILL.md`：sudo 写操作确认、脚本预扫描、精确路径守卫；
3. `skills/LONG-RUNNING-TEST-SKILL.md`：PID/rc/DONE、断线恢复和 heartbeat；
4. `skills/TESTING-GUIDE.md`：§1 health/OSD 三指标、§3 cooldown；本任务明确禁用其中
   destroy/format/pool 重建示例；
5. `doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md`：§二.6 记录、§二.9 分层授权、§二.12
   清理白名单；
6. `V02_REPORT`、V01-R1 报告和本地 v1.3 源码的 `cmd/gc.go`、`pkg/meta/base.go`、
   `pkg/meta/tkv.go`，理解 compact/delete/小时级后台任务的差别。

### 4.2 runner 静态门

GLM 可写 PRE runner/controller，但远端执行前必须：

- `set -euo pipefail`、`bash -n`，有 shellcheck 则保存真实结果；
- 列出全部 ssh/scp/sudo/mount/umount/gc/compact/kill/rm 命令；
- 扫描 `gc --delete`、destroy、format、pool delete/create、config set、restart、reboot、
  shutdown、pkill、killall、`rm -rf`；除字面拒绝/扫描规则外任一命中都拒绝启动；
- object parser 用合成 Ceph JSON 自测：正常、无目标 pool、objects 空/字符串/零、重复
  pool；只有精确一个 `juicefs-data` 且 objects 为正整数才接受；
- mount identity parser 自测：PID/starttime/exe/mountpoint 任一不一致必须拒绝归属；
- GC summary parser 只能读官方 summary 字段，字段缺失标 `UNKNOWN`，不得猜零；
- 所有状态初始化为 `NOT_RUN`，不得默认 READY。

脚本和任务书复制到 `$CTRL/input/`，记录 path/size/mode/mtime_ns/SHA256。正式远端动作后
禁止原地修改 runner；纯 parser bug 可保留旧 attempt 后新建 attempt，不能覆盖证据。

### 4.3 敏感信息

任何可能回显 META 的 stdout/stderr 必须在写盘前流式替换为 `<META:redacted>`；同时只在
pipe 中计算 raw stream SHA，保存 `PIPESTATUS` 每段 rc。`/proc/*/cmdline` 只计算 raw
SHA，并输出 allowlist：binary path hash、mountpoint、read-only/no-bgjob/max-deletes/
backup-meta 等非敏感 flags。禁止先写 raw 再事后脱敏。

---

## 五、Phase A：只读现场核验与 drain mount 归属

### 5.1 环境快照

在任何 mount/gc/compact 前保存：

- hostname/IP/time/current user，确认客户端 157；
- `ceph health`、health detail、PG 状态、全部 OSD up/in；
- pool JSON 原文及 objects/stored/max_avail/pool_id/pg_num/pgp_num；
- CRUSH map hash、Ceph config dump hash、OSD up_from；
- OSD `compact_running`、`compact_queue_len`、`kv_sync_lat`；
- `/mnt/juicefs`、`OLD_DRAIN_MNT`、`PRE_DRAIN_MNT` mountinfo；
- 所有 JuiceFS 进程的脱敏 identity；
- GC_BIN stat/hash/version/file/ldd/build-id；
- safe volume fields：UUID hash、storage type、block size、compression、TrashDays；
- 未知 fio 和共享业务状态。

health 非 OK、PG 非 active+clean、OSD 非 up/in、MAX AVAIL `<10 TiB`、客户端身份错误或
业务异常，立即结束，不做恢复动作。

### 5.2 旧 drain mount 分类

只允许以下三种结果：

1. `ABSENT`：mountinfo 无旧 mount，继续 §5.3；
2. `OWNED-HEALTHY`：mountpoint、卷名、PID/starttime、exe hash 与 V01 记录一致，FUSE
   可读，且 allowlist 证明 read-write、无 `--no-bgjob`、`max-deletes>0`；可采用为本轮
   观察 mount，但必须记录 `ADOPTED`, 不得创建第二个；
3. `UNKNOWN-OR-MISMATCH`：任何证据不闭合，终态
   `BLOCKED-UNKNOWN-OR-UNOWNED-DRAIN-MOUNT`。禁止卸载、kill 或覆盖。

“报告说是我们的”不构成 ownership；必须从现场 identity 机械证明。

### 5.3 条件性创建 PRE drain mount

仅在旧 mount `ABSENT` 时创建：

```text
"$GC_BIN" mount --max-uploads 150 --cache-size 0 --max-fuse-io 256K \
  --max-deletes 10 --backup-meta 0 "$META" "$PRE_DRAIN_MNT"
```

不得带 `--read-only` 或 `--no-bgjob`；不得带 writeback、subdir、format/layout 参数。使用
前台 task runner/唯一进程组保存完整脱敏日志、PID/starttime/exe/argv SHA。挂载后只做
`.stats`/目录 `stat`，不创建或修改文件。

挂载失败最多一次纯 SSH/路径重试；需要换 binary/参数则停止。创建成功后冻结
`DRAIN_OWNER=PRE`；旧 mount 被采用则 `DRAIN_OWNER=V01-ADOPTED`。

### 5.4 资产只读基线

在 drain mount 中核对：

```text
test_dir/storage_test.0.0 ... storage_test.127.0    精确 128 个，大小一致
test_dir/rw_test.0.0      ... rw_test.127.0         精确 128 个，大小一致
test_dir/mseqread/mseqread.0.0 ... .15.0            精确 16 个，大小一致
```

保存 sorted path/size/inode；不得补文件、重铺 layout 或修改时间戳。缺失直接
`BLOCKED-ASSET-GATE`，不做 compact。只有 GC summary 证明 valid objects 本身高于门时，
才可使用 `INVALID-LIVE-FLOOR-ABOVE-GATE`。

---

## 六、Phase B：小时级自然后台排空观察

### 6.1 采样

drain mount PID/starttime/exe 全程固定。每 120 秒记录：

```text
epoch\tiso\tobjects\tstored\tmax_avail\tparse_rc\tmount_pid\tpid_stable
```

每 10 分钟另外记录 health/PG/OSD、主挂载 identity、drain `.stats` 和任务日志尾部的
allowlist 事件：

```text
Cleanup delayed slices
cleanup slices/files/trash
Delete data blocks
object remove/delete error
checking counter last/nextCleanup
```

日志没有某行只能写 `NOT_OBSERVED`，不能写“后台任务没运行”；多客户端用元数据锁竞争，
本 mount 未拿到本轮 owner 也是可能情况。

### 6.2 观察窗口与分支

先完整观察 3 小时，禁止因前 30 分钟平台提前判失败：

- 任意时点达到 READY 对象门：仍完成 §10 的三采样/资产/teardown 后签 READY；
- 3 小时总降幅 `>=100,000` 但未达门：继续观察，累计最长 6 小时；
- 3 小时总降幅 `<100,000`：记录 `NATURAL=STALLED`，进入 Phase C；
- 6 小时仍未达门：无论期间是否下降，进入 Phase C；
- objects 相对本轮起点上升 `>100,000`：视为外部写入/漂移，立即
  `INVALID-EXTERNAL-WRITE-OR-ENVIRONMENT-DRIFT`，不 compact；
- health/PG/OSD/主挂载异常或 PID 变化：立即停止，不等待恢复后续跑。

采样失败不得当 0；连续三次取数失败停止。READY 判断只用有效 Ceph JSON 原文。

---

## 七、Phase C：条件性单次 `juicefs gc --compact`

### 7.1 启动硬门

只有以下全部满足才执行：

- Phase B 完整结束且未 READY；
- 用户授权精确包含该测试卷的单次 `gc --compact`；
- health OK、PG active+clean、OSD up/in；
- 无未知 fio、无其它 gc/compact、共享业务无异常；
- drain mount 和主挂载 identity 稳定；
- GC_BIN provenance 通过；
- 任务前资产门通过；
- `compact-pass-count=0`。

否则停止。禁止为了执行 compact 临时卸载业务挂载、改 max-deletes、改 TrashDays 或改
TiKV gc-interval。

### 7.2 唯一允许的 JuiceFS 管理动作

使用 GC_BIN 执行且全程以唯一 PID/process group 监控：

```text
"$GC_BIN" gc --compact "$META"
```

不得同时或随后增加 `--delete`，不得第二 pass。命令日志必须脱敏并保存：start/end、rc、
完整进度/summary、PID/starttime/exe、每 120 秒 objects/stored 和每 10 分钟 health。

任务没有为“完成更快”预设强杀超时。若超过 4 小时仍运行：不启动其它阶段，继续保存
heartbeat 并报告 `LONG-RUNNING`；只有 health/业务安全事件时才向**该精确 task process
group** 发送一次 SIGINT，并保存证据，禁止 SIGKILL/pkill/killall。

任一 EIO、panic、metadata/object delete error、health 非 OK、PG 非 clean 或主挂载变化，
终态 `BLOCKED-COMPACT-OR-HEALTH`。

### 7.3 一次 OSD compact 与 cooldown

JuiceFS compact rc=0 后，按动态 OSD 列表逐个串行执行一次已授权的 OSD compact；随后
轮询至全部：

```text
compact_running=0
compact_queue_len=0
kv_sync_lat avg<2ms
health=HEALTH_OK
PG=active+clean
```

无法覆盖任一 OSD 或 cooldown 不闭合即停止。禁止 restart 替代 compact。

### 7.4 post-compact 观察

至少再观察 30 分钟，每 120 秒采 objects/stored。若达到 READY 门，进入 §十；否则解析
本次完整 GC summary：valid、pending-delete、compacted、leaked、delslices、delfiles、
skipped 和对应 bytes。任何缺字段写 `UNKNOWN`。

因为 `gc --compact` 本身已经完成全对象扫描且 summary 完整时，禁止再运行 Phase D，
直接按 §九分类，避免对约 750 万对象重复扫描。固定解析其最终官方行：

```text
scanned ... objects, ... valid, ... pending delete (... bytes),
... compacted (... bytes), ... leaked (... bytes),
... delslices (... bytes), ... delfiles (... bytes), ... skipped (... bytes)
```

字段名以本轮冻结的 v1.3 `cmd/gc.go` 为准；不得把 progress spinner 的瞬时值当 final。

---

## 八、Phase D：条件性一次 scan-only 分类

只有以下情形可执行：

- 用户授权 scan-only；且
- 未执行 Phase C，或 Phase C `rc=0` 但没有可解析的完整对象分类且无安全事件；且
- 当前没有运行中的 gc/compact；且
- health/PG/OSD/identity 仍全绿。

固定命令：

```text
JFS_GC_SKIPPEDTIME=7200 "$GC_BIN" gc "$META"
```

必须机械证明 argv 中没有 `--compact`、`--delete`。此命令会扫描整个对象空间，可能运行
数小时；监控/中断纪律同 §7.2。它只用于分类，不允许根据中途计数执行删除。

完成后保存官方 summary 和 rc；字段缺失不得从 `pool objects - valid` 猜 leaked。
Phase C 非零退出、被安全中断或出现 health/identity 异常时禁止用 Phase D“补救”。

---

## 九、分类与下一步映射

### 9.1 分类优先级

使用完整 GC summary；一个对象类别只有官方输出明确计数时才可声明：

| 观察 | 本轮裁定 | 下一步 |
|---|---|---|
| objects 已 `<=3.11M` | 候选 READY | 完成 §十全部交接门 |
| pending/trash/delfile/delslice 占主要超额，leaked=0 | 后台/待删积压 | `BLOCKED-BACKGROUND-CLEANUP-STALLED`；另行决定延长 drain 或专用 delete 维护任务 |
| leaked >0 且足以解释主要超额 | 疑似泄漏 | `BLOCKED-PENDING-OR-LEAKED-REQUIRES-NEW-PLAN`；必须先备份/回滚评估，再另发 `gc --delete` 任务 |
| valid objects 本身明显 >3.11M | 历史低对象 floor 已失效 | `INVALID-LIVE-FLOOR-ABOVE-GATE`；选择清理已确认测试资产或新建独立卷/pool |
| skipped/recent 很高或外部写持续 | 环境不静止 | `INVALID-EXTERNAL-WRITE-OR-ENVIRONMENT-DRIFT` |
| summary 不完整 | 不可分类 | `PARTIAL-V02-PRE` |

“占主要超额”必须同时报告 object count 和 bytes；不能只看百分比。多类并存时按更危险的
leaked/unknown 路径处理。

### 9.2 本任务绝不自动进入 delete

即使 scan 明确报告大量 leaked/pending，本任务也必须停止。后续若考虑 `gc --delete`，
新的任务书至少要包含：测试卷所有权重新确认、元数据和对象回滚/备份决策、最近写入
跳过窗、delete threads、健康 watchdog、精确可删除类别、dry-run/scan 对照和用户逐项授权。

---

## 十、READY 交接门与 teardown

### 10.1 三次实时低对象确认

以至少 120 秒间隔取得连续三次有效样本，全部：

```text
objects <= 3110000
health = HEALTH_OK
PG = active+clean
all OSD = up/in
max_avail >= 10 TiB
```

任一失败重新计三次；最多等待 30 分钟。仍不闭合则不 READY。

### 10.2 资产和环境复核

- 重做 §5.4 文件数量/大小清单，与 pre 逐行一致；
- pool_id/PG/PGP/CRUSH/config hash 与 pre 一致；
- `/mnt/juicefs` mount/PID/starttime/exe/raw argv hash 与 pre 一致；
- 无未知 fio/gc/compact；OSD 三指标全绿；
- GC_BIN hash 未变；
- 保存 safe volume config post，TrashDays 等允许字段未变。

### 10.3 优雅退出 drain mount

只可处理机械证明为 `DRAIN_OWNER=PRE` 或 `V01-ADOPTED` 的精确 mount：

1. 保存 mountinfo/PID/starttime/exe/argv hash；
2. 使用 GC_BIN 对精确 mountpoint 优雅 umount；
3. 等待并证明 mount gone、对应 PID/process group gone；
4. 再采一次 health/objects/主挂载 identity。

umount 失败禁止 lazy/force、kill 或删除 mountpoint；终态不能 READY。未知 mount 永不处理。

### 10.4 READY receipt

只有 §10.1～§10.3 全过才写 `$READY_RECEIPT`，固定 TSV 两列：

```text
field\tvalue
status\tREADY-V02-LOW-OBJECT
run_id\t...
taskbook_sha256\t...
meta_identity_sha256\t...
pool\tjuicefs-data
pool_id\t...
objects_sample_1\t...
objects_sample_2\t...
objects_sample_3\t...
stored_last\t...
max_avail_last\t...
health_last\tHEALTH_OK
pg_osd_gate\tYES
asset_gate\tYES
protected_mount_unchanged\tYES
drain_mounts_gone\tYES
gc_compact_passes\t0_or_1
gc_scan_passes\t0_or_1
osd_compact_rounds\t0_or_1
gc_delete_passes\t0
performance_data\tNONE
forbidden_actions\t0
pool_identity_unchanged\tYES
ready_epoch\t...
report_path\t...
evidence_root\t...
```

为 receipt、report、manifest 分别生成 SHA256 sidecar。V02 仍必须实时重查所有门，receipt
不是免检令，也不传递授权。

---

## 十一、控制器、attempt 与恢复

1. controller 每个 phase/每 10 分钟写 heartbeat：北京时间、157 时间、phase、PID、
   objects、health、mount identity、status、next。
2. 判断长进程完成必须同时有 PID gone、rc sidecar、DONE/STOP marker。
3. SSH 断线最多两次有界重连；先核对 PID/starttime/exe/argv hash，匹配则继续观察，
   绝不重复 launch。
4. 自然观察可在同一 RUN_ID 恢复；必须证明 drain PID和全部环境 hash 未变。
5. GC 一旦启动绝不重启/补跑；断线只重新接管监控。没有确证旧 PID gone 绝不 launch。
6. runner/parser 修复只能新 attempt 目录，旧证据保留；compact pass 计数跨 attempt 累计，
   不能靠换目录归零。
7. 任一安全 STOP 后只做脱敏 post snapshot 和能安全完成的 task-owned teardown；不等待
   环境变绿偷偷续跑。

---

## 十二、交付物与判据来源

### 12.1 远端目录

```text
$REMOTE_OUT/
  input/
  preflight/
  snapshots/{pre,post}/
  drain/{identity,logs}/
  objects/object-trace.tsv
  health/health-trace.tsv
  compact/                     # 条件性，含唯一 pass
  scan/                        # 条件性，最多一次
  assets/{pre,post}.tsv
  handoff/V02-PRE-READY.tsv    # 仅 READY 时存在
  handoff/V02-PRE-READY.tsv.sha256
  commands.sh
  adaptations.tsv
  controller-state.tsv
  final-status.txt
  SHA256SUMS
```

### 12.2 报告

`$REPORT` 至少包含：

1. 授权 SHA 和实际动作集合；
2. V01 drain 现场矛盾的最终解释及 raw evidence；
3. pre/post health、pool、mount、config identity；
4. 完整对象时间序列和每个小时的净变化；
5. 后台 cleanup 日志事件/错误；
6. compact/scan 是否运行、精确 flags/rc/summary；
7. valid/pending-delete/compacted/leaked/delslices/delfiles/skipped 分类；
8. 资产 pre/post 对比；
9. READY 或阻塞状态的逐条件证据；
10. 未执行 `gc --delete`/destroy/format/pool 操作/重启/fio 的声明。

### 12.3 判据到原始证据

| 判据 | 唯一来源 |
|---|---|
| objects/stored/max_avail | `objects/object-trace.tsv` 每行指向 Ceph JSON SHA |
| health/PG/OSD | `health/health-trace.tsv` 指向逐次原文 |
| drain ownership | `drain/identity/` 的 mountinfo、PID/starttime/exe/argv hash |
| 后台任务 | `drain/logs/cleanup-events.tsv` 指向脱敏日志行；未观察不得反推未运行 |
| compact 次数/结果 | `compact/pass-count.txt`、gc log/rc/summary |
| scan-only | `scan/argv-check.txt`、log/rc/summary |
| 资产不变 | `assets/pre.tsv` 与 `assets/post.tsv` 逐行 diff |
| pool/env 不变 | pre/post pool_id/PGP/CRUSH/config/up_from hash |
| READY | 三个原始低对象样本 + receipt + teardown gone 证据 |

### 12.4 manifest 与归档

- SHA manifest 覆盖全部普通证据文件且实际 `sha256sum -c`；manifest 不自包含；
- archive 排除 META/credential、raw argv、私钥、挂载数据和 GC_BIN；
- tar member 去 `./` 后无重复、无绝对路径、无 `..`；
- scp 回 WSL 后重算 archive SHA，保存固定 `$LOCAL_ARCHIVE_SHA`；报告及固定
  `$REPORT_SHA` 写到本地，receipt 及其 sidecar 必须包含在 archive；
- READY receipt 必须能从 archive 独立复核，不只存在远端活目录。

---

## 十三、通用注意事项与 skill 合规自查

### 13.1 环境和记录

- 本任务没有 fio，因此不适用 bw log、drop_caches 和稳态带宽统计；报告必须明确
  `PERFORMANCE_DATA=NONE`；
- health、对象数和身份每个结论都指向原始文件，不能只写汇总；
- OSD compact 会短时增加负载，只有授权、无共享竞争且健康时执行；
- JuiceFS gc 扫描全对象，长时间无输出不代表挂死；以 PID、进度和 health 联合判断；
- 不把 UsedSpace、UsedInodes、TiKV disk size 当 Ceph pool objects；
- 不把 `compact_running=0` 解释为对象回收完成。

### 13.2 最终自查

报告逐项回答：

1. 是否始终为预期客户端/卷/pool；
2. 是否零 fio、零 drop_caches、零 S/A/B 性能数据；
3. JuiceFS compact 是否最多一次，scan-only 是否最多一次；
4. 是否零 `gc --delete`、destroy、format、pool/PG/CRUSH/config/restart；
5. 是否只管理精确 task-owned/已证明 owned 的 mount/PID/path；
6. OSD compact 是否最多一轮且三指标闭合；
7. pre/post 资产、主挂载和 pool identity 是否一致；
8. 敏感信息扫描是否零命中；
9. READY 是否由三次实时低对象原文和 teardown 共同支持。

任一不符必须降级状态，不得默默修报告。

---

## 十四、红线汇总

- 禁止 fio、layout、create-on-open、drop_caches 和任何性能测试；
- 禁止 `juicefs gc --delete`，即使扫描明确发现泄漏也禁止；
- 禁止 destroy、format、pool delete/create、PG/CRUSH/config 修改；
- 禁止 OSD/TiKV/主机/服务 restart、reboot、shutdown；
- 禁止删除测试目录、业务数据、未知文件或历史证据；
- 禁止触碰 `/mnt/juicefs`、系统 JuiceFS binary、WekaIO/BeeGFS/K8s/NIC/RoCE/md0；
- 禁止未知 drain mount 的 umount/kill，禁止 pkill/killall/SIGKILL；
- 禁止第二次 JuiceFS compact、第二轮 OSD compact或第二次 scan；
- 禁止通过改 TrashDays/max-deletes/gc-interval/阈值把环境“修到能跑”；
- 禁止把 V02-PRE READY 写成 V02 性能 PASS 或自动启动 V02；
- 禁止社区写入或生产替换。

---

## 十五、GLM 最终回复模板

```text
V02-PRE 状态：<允许终态之一>
RUN_ID / CTRL / REMOTE_OUT / archive / report：
授权 SHA 与实际启用阶段：
客户端 / META identity hash / pool identity：
V01 drain mount 最终归属和证据：
GC_BIN provenance：
自然观察起止 / 最低 objects / 每小时净变化：
后台 cleanup 事件与错误：
gc --compact passes / rc / summary：
scan-only passes / rc / summary：
valid / pending / trash / leaked / skipped：
对象三次 READY 样本：
资产 pre/post：
主挂载与 pool identity pre/post：
drain teardown：
READY receipt / SHA（若有）：
所有偏差、STOP 和未执行项：
skill 合规自查：
声明：PERFORMANCE_DATA=NONE；未执行 gc --delete/destroy/format/fio/生产替换/社区写入。
```
