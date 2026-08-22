# ~~03-16N：GLM 12 小时夜间自主执行总任务书（2026-08-17 21:00—08-18 09:00）~~ ⚑ 已作废

> ⚑ **2026-08-19 作废，不得执行。** 作废理由（三条，任一独立成立）：
> 1. **窗口已过期**：原窗口 2026-08-17 21:00—08-18 09:00。Lane R 那晚从未启动（无 `doc/perf-report/03-16-*` 报告、157 上无 `/tmp/opencode-t3.16*`），该窗口实际被 V01-R1 夜间恢复占用。
> 2. **Lane V 指针失效**：§1.2 指向 `V01-v131-B-async-SAB-performance-integrity.md`，它已被 `V01-R1` → `V02-PRE` → `V02-PRE-R1` → `V02-v131-SAB-performance-validation.md`（2026-08-19）逐层取代。按原文执行会跑错 Lane V。
> 3. **排期不再可行**：§三 时刻表按 V01 的 4.5~6h 编排，而现行 V02 自估 8~12h（meta 退化重查最长约 14h），与 Lane R 的 3.5~4.5h 无法装进同一个 12h 窗口；且 V02 的写会把 `juicefs-data` objects 重新顶过 3.11M 闸门，直接摧毁 Lane R 赖以成立的低对象窗口。
>
> **替代安排**：Phase R 改为单轨执行，见 `03-16-glm-n1n2-read-boundary.md`；其中 §八 已并入本文 §5.1/5.2/5.3 的监控频率、必查项、SSH 断线与单实例纪律，以及 §6.1/6.2 的"可自主修实现 / 必须 STOP 的变量与安全门"分流规则。V02 另行单独排期，不与 Phase R 同窗口。
>
> 本文仅作历史留档：以下内容不再生效，读者不得据此启动任何在线步骤。

---

# ~~正文（历史留档）~~


> 执行方：GLM　｜　计划/复核方：Codex　｜　窗口：北京时间 2026-08-17 21:00 至 2026-08-18 09:00  
> 性质：只编排已经定义的只读 Phase R、V01 v1.3 S/A/B 与条件性完整性冒烟；不允许自行选择研究分支  
> 核心纪律：远端性能负载严格串行；读在写前；问题可自主修“实现”，不能自主改“变量、权限和安全门”  
> 本任务书与子任务书共同生效；冲突时采用更严格的 STOP/红线  
> 未见本任务书 §二的用户逐项授权原文时，GLM 只能做本地只读盘点和静态准备，不能设置任何 ACK 变量、创建容器或启动构建/测试

---

## 计划线

```text
03-15 Gate 0
  └─ 已冻结 03-16 Phase R；它必须先于所有新写实验
★ 21:00 夜间窗口（你在这里）
  ├─ Lane R：03-16 N1/N2 单/双挂载读边界，约 3.5~4.5h，只读
  ├─ Lane V：V01 v1.3 S/A/B，约 4.5~6h，R 封包后才可远端写
  ├─ Tail：若 V 全绿且时间足，做 16GiB B 完整性冒烟
  └─ Fallback：远端被安全门阻塞时，只做 V01 本地 port/build/unit
               和 C03-R4 runner 合成预飞，不碰生产
09:00
  └─ 只交原始包、机械状态和问题日志；统计/归因由 Codex 白天完成
```

一句话：先拿不容污染的 03-16 只读边界证据，再用剩余窗口完成 B-v1.3 的 S/A/B；不让任何 STOP 变成擅自清理、改参或错误分支。

---

## 〇、今晚应该做什么，不应该做什么

### 0.1 必做优先级

| 顺序 | 工作 | 预计时间 | 价值 | 是否使用 157/集群负载 |
|---:|---|---:|---|---|
| 1 | 03-16 Phase R | 3.5~4.5h | 划分单 mount 与整机共享读边界 | 是，只读 fio |
| 2 | V01 本地 port/build/unit | 0.8~1.5h | 冻结 v1.3 S/A/B 和 B 正确性 | 本地；禁止在 157 的 Phase R 期间编译 |
| 3 | V01 S/A/B 性能 | 4.5~6h | 回答 B 能否替代 A | 是，写 fio |
| 4 | V01 条件性完整性冒烟 | 0.8~1.2h | 初步数据完整性证据 | 是，16GiB 专用目录 |
| 5 | 归档、manifest、原始报告 | 0.5h | 让白天复核可重现 | 低负载 |

正常路径约 9.5~12 小时。完整性冒烟是唯一可按时间盒跳过的在线项。

### 0.2 今晚明确不做

- 03-17 Phase X、direct-rados 或最小复现分支；它们必须等 Codex 分析 03-16 raw data。
- 03-18 TiKV 服务端指标、任何 TiKV/PD/RocksDB 调参或 restart。
- librados T2、`--max-downloads`、OSD K3/K4/K5/K6、全七项 baseline。
- 正式 8 小时 soak；当前窗口不足以在 03-16+V01 后保持完整 8 小时。
- C03-R4 full run、社区 commit/push/issue/PR。
- pool/PG/CRUSH/layout/format/destroy/OSD 重启/主机重启。

---

## 一、权威子任务与固定顺序

### 1.1 Lane R

完整执行：

```text
/home/lilingfeng/demo/production/prod-deploy/doc/perf-tasks/03-16-glm-n1n2-read-boundary.md
```

必须使用仓库唯一脚本：

```text
prod-deploy/scripts/FULLBASELINE/debug/t46-n1n2-read-boundary.sh
```

03-16 的 STOP 原则不因本总任务书放宽。它要求 raw 包回传后由 Codex分析；GLM 不根据吞吐自行选择 Phase X/direct-rados。

### 1.2 Lane V

完整执行：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/V01-v131-B-async-SAB-performance-integrity.md
```

V01 的本地 port/build/unit 可在 Lane R 的等待间隙准备，但必须满足：

- 工作发生在控制机，不是客户端 157；
- 不抢占 157 CPU、内存、磁盘或网络；
- 每 30 分钟仍按 03-16 监控；
- 正式远端 fio 必须等 Lane R 结束、封包、卸载 P/Q 后。

如果无法证明构建机与 157 分离，所有 V01 构建延后到 Lane R 结束。

### 1.3 Tail

V01 自带条件性完整性冒烟。只有 V01 §8 五个启动条件全部满足才执行；不另加长稳。

---

## 二、一次性用户授权硬门

### 2.1 今晚请求授权的全部状态写入

用户需要明确批准以下封闭集合；除此之外都不授权：

| ID | 精确动作 | 精确范围 |
|---|---|---|
| A1 | 创建/chown、挂载/卸载测试专用目录 | 仅 `/mnt/juicefs-p`、`/mnt/juicefs-q`、`/mnt/juicefs-v01`；必要时只对这三个目录 `sudo umount` |
| A2 | drop Linux page cache | 仅 157、150、151、152 的 `sync; echo 3 > /proc/sys/vm/drop_caches`，只在任务书规定的 fio 前 |
| A3 | 复制/执行测试二进制和脚本 | 仅 157 `/tmp/juicefs-v01-<RUN_ID>-{S,A,B}`、`/tmp/t46-*` 和各自 OUT；禁止系统路径 |
| A4 | 只读 Phase R fio | 仅 P/Q 已有 read/rw 测试数据范围，遵守 03-16 |
| A5 | V01 写 fio | 仅专用挂载看到的既有 `test_dir/storage_test.*.0`、`test_dir/rw_test.*.0`；不得 create layout/format |
| A6 | 写后状态清理 | 每轮最多一遍 `juicefs gc --compact`；`ceph tell osd.* compact` 与只读轮询；禁止 `gc --delete`、destroy、restart、pool 操作 |
| A7 | 条件性完整性文件 | 仅创建/删除 `/mnt/juicefs-v01/test_dir/v01-integrity-<RUN_ID>`；删除前必须 realpath 双重校验 |
| A8 | 本地临时源码/构建与一次性 Redis | 仅 `/home/lilingfeng/tmp/juicefs-v01-<RUN_ID>-*`；Redis 仅用唯一命名、loopback 暴露、无宿主目录卷的一次性容器，任务结束必须 stop/remove 并证明不存在 |

### 2.2 不得从“自主执行”推导出的权限

自主执行不等于授权：

- kill 未知 fio/JuiceFS 进程；
- 修改业务 `/mnt/juicefs`；
- 删除别人的 `/tmp`、测试目录或数据；
- format/destroy、pool delete/create、PG/CRUSH/ceph config set；
- OSD/TiKV/PD/主机/网络服务 restart；
- 扩容磁盘、改内核、NIC/RoCE/MTU/RPS/IRQ/md0/WekaIO/K8s；
- 网络写入 GitHub 或修改社区状态。

### 2.3 授权证据

GLM 必须把用户包含 A1~A8 的批准原文逐字保存为：

```text
/home/lilingfeng/tmp/glm-overnight-20260817-authorization.txt
```

并记录 SHA256。缺文件、缺任一 ID 或用户明确排除某项时，对应在线步骤不执行；不得自行补写授权文本。

---

## 三、时间盒与调度表

时间是预算，不是改变门禁的理由。每个 phase 以实际完成为准。

| 北京时间 | phase | 行动 |
|---|---|---|
| 21:00–21:20 | O0 | 读任务书、保存授权、静态扫描、检查无未知 fio/health/objects |
| 21:20–02:00 | R | 执行并监控 03-16；正常 3.5~4.5h |
| R 等待间隙 | V-local-prep | 仅当构建机与 157 分离时，准备 V01 input/port/selftest；不跑远端负载 |
| R 完成后 0–90min | V0 | 完成 V01 本地 correctness/build、复制三二进制、远端 preflight |
| 最晚约 02:30–07:45 | V1 | 固定顺序 S1-A1-B1-B2-A2-S2；按完整 mount 单元推进 |
| 07:15 决策点 | V2 | 只有 V01 已全绿且剩余 >=75min 才启动 integrity |
| 08:15 | cutoff | 不再启动任何新 fio、build、gc 或 compact；只允许当前短步骤收尾 |
| 08:45 | hard stop | 完成专用挂载清理、health/post snapshot、archive/manifest |
| 09:00 | handoff | 原始执行报告和最终回复完成 |

若 03-16 因好档重试接近 02:00 才完成，V01 优先保证 block 1；不得用跳过 ns/B 门、缩短 randwrite 或删除 A/S 对照来赶时间。

---

## 四、启动前全局 preflight

### 4.1 必读

```text
prod-deploy/skills/SYSTEM-SAFETY-SKILL.md
prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md
prod-deploy/skills/TESTING-GUIDE.md
prod-deploy/skills/test-commands-reference.md
prod-deploy/skills/interleaved-ab-tuning-skill.md
prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md
03-16 子任务书
V01 子任务书
本总任务书
```

### 4.2 全局状态快照

在任何测试进程前保存：

- 本地与 157 的时间/时区/hostname；
- Ceph health/detail、PG、OSD、pool stats/object count/max_avail；
- 157 load/memory/disk、全部 fio/JuiceFS 进程、mountinfo；
- `/mnt/juicefs` 的 mount ID、PID、starttime、cmdline、exe hash；
- `/mnt/juicefs-{p,q,v01}` 是否已有挂载/文件；
- WekaIO/BeeGFS/K8s 外部负载摘要；
- t46、V01 taskbook、执行脚本的 hash 和静态扫描。

未知 fio、主挂载身份异常、health 非 OK、objects 不可解析或 `>3,110,000` 时，所有远端 lane 都 STOP；不得为了利用夜间时间继续制造负载。

### 4.3 预先创建夜间状态台账

本地只追加文件：

```text
/home/lilingfeng/tmp/glm-overnight-20260817-state.tsv
```

精确 schema：

```text
timestamp	phase	attempt	host	pid	status	health	objects	action	evidence
```

每次状态变化、修复、重试、STOP、DONE 和切 lane 必须追加；不得事后凭记忆补时间线。

---

## 五、无人值守监控

### 5.1 频率

- 默认每 30 分钟唤醒；
- 预计 10 分钟内完成的 gate/cooldown 可 2–10 分钟；
- 每次 sleep 前打印北京时间；任何单次 sleep 不超过 30 分钟；
- 每小时更新预计完成时间和是否还能完成下一个完整 mount 单元。

### 5.2 每次必查

1. 当前 wrapper 精确 PID、子 fio PID 与 phase marker；
2. 日志最后 50 行、最新 rc/DONE/STOP；
3. Ceph health、PG 和 objects；
4. 当前测试挂载 PID/starttime/exe hash；
5. 主挂载身份是否逐字不变；
6. 内存、磁盘、未知共享负载；
7. 当前结果目录是否继续增长、bw logs 数量是否符合预期。

只看到进程消失不能判 DONE；必须同时有 rc sidecar、DONE marker 和交付物计数。

### 5.3 SSH 断线

测试必须由可恢复的会话/后台 wrapper 管理，SSH 断线不重启任务。重连后先判断原 PID、日志和 marker，再决定；禁止因“不确定”启动第二份并发 fio。

---

## 六、自治修复与分流规则

### 6.1 可自主修复

- 本地 bash/解析器/路径/依赖/权限位等工程问题；
- 采集缺文件、manifest、归档和报告生成问题；
- V01 的 v1.3 测试接口适配；
- 短暂 SSH/下载失败的重试；
- 只读探测发现的命令兼容差异。

要求：先保存旧 attempt，再写 `adaptations.tsv`，记录旧/新 SHA、diff、原因和为何不改变量。正式数据出现后不允许原地续写旧表。

### 6.2 必须 STOP，不能“自主解决”

- health/PG/对象/空间/业务负载/主挂载/实例守卫失败；
- 需要改 fio 参数、矩阵、门槛、挂载选项、臂顺序或测试时长；
- 需要 gc 额外 pass、删除数据、format/destroy、改 Ceph/TiKV 配置或 restart；
- 未知进程/挂载冲突需要 kill/umount；
- 需要扩大 A1~A8；
- 发现疑似数据损坏或 EIO。

STOP 后保留现场和准确原因，不用“已记录”替代安全停机。

### 6.3 Lane R 的特殊规则

03-16 一旦命中自己的 STOP，停止 Lane R，不由 GLM 修脚本后原地继续：

- 若 STOP 原因是 cluster/objects/共享业务/主挂载：V01 远端也禁止；转 §七离线 fallback。
- 若 STOP 发生在任何远端负载前，且原因纯属本地脚本语法/路径：可以完成 V01 本地工作；是否启动 V01 远端仍须重新跑全局环境门。
- 若 STOP 发生在只读数据中途：先封存 partial、清理 P/Q 专用挂载并复核 health；不补 Phase R。只有全部环境门重新为绿，才可按既定 V01 继续。

### 6.4 Lane V attempt

服从 V01 的两次上限。一个完整 mount 单元已有有效数据后，不允许修改脚本并继续向旧 TSV 追加。

---

## 七、远端不能跑时的离线 fallback

远端安全门阻塞不等于结束 12 小时。按顺序做以下不触碰生产的工作：

### F1：完成 V01 本地闭环

- 冻结 S/A/B clone、patch、diff、测试文件、build provenance；
- 完成 S/A/B 正确性矩阵、B race/full-vfs/vet/build；
- 生成三个二进制及 hash，但不复制/执行到 157；
- 产出 `V01-LOCAL-READY` 或精确阻塞状态。

### F2：C03-R4 runner 合成预飞包

仅在 F1 完成且仍有 >=60 分钟时做。目标是早上交 Codex review，不执行 C03-R4 full Go/Redis/网络测试。

基于 C03-R3 runner 的已知缺陷，创建全新：

```text
/home/lilingfeng/tmp/juicefs-c03-r4-preflight-$RUN_ID
```

必须修复并用合成数据证明：

1. result TSV 精确 14 列，`bad`/`log`/`expectation_matched` 不错位；
2. 单项 rc=0 但 99/100 PASS 时 gate=NO；
3. Redis 数据逐行七列，不允许冒号打包；
4. expected/manifest/tar/extract 做真实集合与重复项检查；
5. expected 或 tar 有 duplicate pathname 时失败；
6. 三个 diff sidecar 总是生成；
7. static review 任一 NO 时正式 runner 拒绝启动；
8. VERIFY 启动前必须不存在，绝不 `rm -rf` 未验证路径；
9. untracked source artifact 进入 path guard；
10. payload freeze 后禁止生成 `final-compliance-review.md` 等新文件。

合成矩阵至少为：terminal 8 case、result parser 3 case、archive set 6 case（含 duplicate）、source guard 2 case。全部命令/stdout/rc 和脚本 SHA 落盘。禁止据此宣布 C03-R4 PASS 或启动正式测试。

### F3：机械打包检查

若剩余不足 60 分钟，只做现有 OUT 的成员去重检查、SHA manifest、秘密扫描和交付清单；不启动新测试。

---

## 八、阶段转换门

### 8.1 R → V

只有下列全部满足：

- 03-16 wrapper 已退出且有 DONE 或明确 STOP；
- R 的 archive/MD5 已生成，或 partial OUT 已冻结；
- `/mnt/juicefs-p`、`/mnt/juicefs-q` 无活动 mount/process；
- 没有 fio；
- health/PG/objects/主挂载身份重新检查为绿；
- V01 本地 correctness/build 已过门；
- 当前时间允许完成至少 V01 block 1 和安全收尾。

### 8.2 V → integrity

完全采用 V01 §8；GLM 不自行解释中间带宽或放宽时间条件。

### 8.3 任何阶段 → handoff

08:15 后不再启动新负载；完成当前可在 15 分钟内结束的步骤，然后进入清理/归档。若步骤预计超过，停止启动下一轮并标 `PARTIAL-TIMEBOX`。

---

## 九、必须交付的夜间总包

### 9.1 总控证据目录

```text
/home/lilingfeng/tmp/glm-overnight-20260817/
  authorization.txt
  commands.sh
  state.tsv
  preflight/
  phase-r.tsv
  phase-v.tsv
  attempts.tsv
  adaptations.tsv
  final-inventory.tsv
  final-status.txt
  SHA256SUMS
```

只保存指向大包的路径/hash，不复制巨大 bw logs 到总包。

### 9.2 子任务包

- 03-16：按其任务书交付 `/tmp/opencode-t3.16*`。
- V01：按其任务书交付本地/远端 archive 和 report。
- F2 若执行：交 C03-R4-preflight 目录/archive/hash。

### 9.3 夜间原始报告

写入：

```text
/home/lilingfeng/demo/production/prod-deploy/doc/perf-report/03-16N-glm-overnight-execution-$RUN_ID.md
```

报告只写机械事实：时间线、DONE/STOP、路径/hash、health/objects、attempt/adaptation、未执行原因。不得替 Codex写性能归因。

---

## 十、收尾合规检查

1. 所有本任务 fio 已退出；无孤儿 wrapper。
2. 三个专用 mount 均已清理；业务 `/mnt/juicefs` before/after 逐字一致。
3. health OK、PG 正常、objects 和空间落盘；异常则保留原文，不伪写 OK。
4. 未执行 destroy/format/pool/PG/CRUSH/config set/restart/广泛 kill。
5. 未修改 `/usr/local/bin/juicefs` 或 `/tmp/juicefs-03-8`。
6. 未运行 Phase X/direct-rados/03-18/T2/max-downloads/全 baseline/正式 soak。
7. 每个实际 fio 有完整 rc、全文和全部 bw logs。
8. 所有脚本修复有旧/新 hash、diff 和新 attempt。
9. archive 清单排序去重，manifest/tar/extract exact compare，禁止用 sha rc 冒充 member compare。
10. 秘密扫描通过；报告不含密码、token、key 或未脱敏认证 URL。

任一不满足，最终状态不能写全绿。

---

## 十一、GLM 最终回复模板

```text
夜间窗口：2026-08-17 21:00 ～ 2026-08-18 09:00
总状态：DONE / PARTIAL / BLOCKED
授权文件及 SHA256：

Lane R：DONE / STOP / NOT-RUN
03-16 OUT/archive/hash：
R 的 STOP、偏差、attempt：

Lane V-local：DONE / STOP / NOT-RUN
Lane V-remote：<V01 七状态之一或 NOT-RUN>
V01 本地/远端 OUT/archive/hash：
integrity：DONE / FAIL / TIMEBOX-SKIP / NOT-RUN

主挂载 before/after：
health 起止：
objects 起点/峰值/终点：
专用挂载是否全部清理：
所有自主修复及旧/新 SHA：
未执行任务及原因：

声明：没有执行未授权分支、生产替换或社区写入；等待 Codex 分析原始数据。
```
