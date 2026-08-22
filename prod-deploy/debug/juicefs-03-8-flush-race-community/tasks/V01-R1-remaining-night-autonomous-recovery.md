# V01-R1：剩余夜间自主恢复——自然排空、v1.3 S/A/B 或 main 社区补丁全量复核

> 执行方：GLM　｜　计划/复核方：Codex　｜　日期：2026-08-18  
> 窗口：收到用户对 §二 B1～B9 的逐项授权后开始；北京时间 08:15 后不启动新 workload，08:45 前完成远端清理，09:00 前交付  
> 性质：修复 03-16N 的提前结束状态机；一个 lane STOP 只关闭该 lane，绝不自动结束总任务  
> 唯一在线优先项：对象池自然回落且构建门通过后，完成 v1.3.1 的 S/A/B 性能验证  
> 唯一离线保底项：无论在线条件如何，至少完成 C03-R4 全量审计重跑或给出其自身的精确阻塞证据  
> 本任务书不自行授予状态写入；没有 §二授权原文时仅允许只读盘点  
> 不得修改或覆盖 `/usr/local/bin/juicefs`、`/tmp/juicefs-03-8`、业务目录、pool、Ceph/TiKV 配置或社区远端状态

---

## 计划线

```text
03-16N 首轮
  ├─ 真实首个门：juicefs-data 18.4M > 3.11M，应 STOP
  ├─ 后续改成 UsedInodes 后重跑：门禁口径被改变，结果无效
  └─ V01：局部单测有数据，但 Ceph build/证据包未闭合
★ V01-R1（你在这里）
  ├─ Lane D：专用空闲 mount，最多 120min，自然排空 pending slices
  ├─ Lane L：全新 v1.3 S/A/B + 隔离 Redis + Ceph 三构建
  ├─ D+L 在 02:15 前全绿 → Lane P：完整 V01 S/A/B 性能
  └─ 任一不绿 → Lane C：C03-R4 full + v1.3 扩展语义
08:15
  └─ 不开新 workload；归档、清理、机械报告
```

一句话：让远端在无 fio 的情况下自然排空，让本地同时把补丁与构建证据做实；在线条件成熟就跑完整 S/A/B，否则把整晚转化成可提交社区的高质量本地证据，而不是提前结束。

---

## 〇、上一轮事实订正与本轮不可继承项

### 0.1 Codex 只读复核确认的事实

复核时间为北京时间 2026-08-17 23:53～23:55，连接方式为用户现有 SSH alias `thailand`，目标 hostname 为 `oneasia-c1-cpu-node10`（157）。执行时必须重新取数，不能把下表当当前值：

| 项 | 复核值 | 本轮含义 |
|---|---:|---|
| Ceph health / PG | `HEALTH_OK`；33 PG active+clean | 当时健康，不替代本轮 preflight |
| `juicefs-data` pool objects | `18,337,356` | 大于正式性能门 `3,110,000` |
| pool stored | `4,806,995,869,696` bytes | 明显高于卷的逻辑使用量 |
| JuiceFS `UsedSpace` | `621,696,548,864` bytes | 与 pool stored 的差额支持“有大量旧对象待回收”假设，但不是删除授权 |
| JuiceFS `UsedInodes` | `429` | 只作元数据背景；禁止替代 pool objects |
| `TrashDays` | `0` | 历史上空闲挂载曾使 17.03M 在 66min 自然回到 2.36M |
| 157 Go / rados headers | 无 Go；无 `librados.h` | 157 不是构建机 |
| 157 runtime | 有 `librados.so.2`；`/tmp/juicefs-03-8` 可加载 | 可做运行兼容检查 |
| WSL | Go 1.26、`librados2=20.2.0`，缺 header | 可用已下载 dev deb 无安装解包构建 |

### 0.2 上一轮 Phase R 只能如何使用

远端原始目录：

```text
/tmp/opencode-t3.16-20260817-215251
```

原始 gate 确实显示：

- `T46-A-t1`：P 3.379 ns/B PASS；Q 4.417 ns/B FAIL；
- `T46-A-t2`：P 4.938 ns/B FAIL；
- `T46-A-t3`：P 4.361 ns/B FAIL；
- 没有进入效应矩阵，`progress.tsv` 只有表头。

但该 wrapper 把对象门改为 `UsedInodes=429` 后才启动，违反权威任务书明确的 Ceph pool objects 门，因此只能标：

```text
INVALID-PHASE-R-GATE-BYPASS
```

本轮禁止继续该 OUT、补跑 pair B、重用其 PASS/FAIL 作为性能判据或再次修改 03-16 脚本。本轮不跑 Phase R。

### 0.3 上一轮 V01 本地目录只可作反例输入

```text
/home/lilingfeng/tmp/juicefs-v01-local-20260817-215747
```

它包含有价值的单测日志，但缺 `results-correctness.tsv`、`commands.sh`、`adaptations.tsv`、`SHA256SUMS`、隔离 Redis 生命周期和 Ceph 三二进制。不得增补旧目录后宣称 DONE；本轮必须使用全新 RUN_ID 和全新 clone。

---

## 一、目标、优先级与允许状态

### 1.1 P0：修复状态机与证据链

证明执行器不会因任一在线 lane STOP 而提前 FINAL：

- Lane D、L、P、C、T 各有独立状态；
- 一个 lane 的 `STOP/BLOCKED/FAIL` 必须转下一条允许路径；
- 北京时间 08:15 前，只要离线队列还有未尝试任务，就不能写总 FINAL；
- 每个修复、attempt、转移和跳过理由实时写状态表，不事后补记。

### 1.2 P0：v1.3 B 候选闭环

全新构造：

```text
S = e0032b2a + eaf3d21f
A = S + 已验证的同步 NewSlice patch
B = S + main 的异步 ID-ready catch-up 语义移植
```

完成正确性、隔离 Redis、扩展语义和三个带 Ceph tag 的可追溯构建。

### 1.3 P0：条件性在线性能

只有 pool objects、环境、构建和时间四门全绿，才执行既有 V01 的完整六位置 S/A/B：

```text
S1 → A1 → B1 → B2 → A2 → S2
```

不得只跑有利臂，不得以旧 A 数据替代当夜 A，不得把 block 1 partial 宣称正式 PASS。

### 1.4 P0：无条件离线保底

在线 lane 不可用时，执行 C03-R4 full clean rerun，纠正 C03-R3 的结果解析、Redis TSV、archive 集合与终态审计缺陷。它与 pool objects、157、Ceph build 相互独立。

### 1.5 P1：v1.3 扩展语义

把 C02 的十项 `writer_flush_c02_test.go` 只做接口适配移植到 v1.3 B，执行 single/count/race；不能借适配修改断言含义或 production writer。

### 1.6 总状态枚举

总状态只能取：

```text
DONE-PERF-AND-COMMUNITY
DONE-PERF-ONLY
DONE-COMMUNITY-ONLY
DONE-OFFLINE-EVIDENCE
PARTIAL-TIMEBOX
BLOCKED-GLOBAL-SAFETY
```

子 lane 必须保留自己的更具体状态；总状态不能掩盖 INVALID、FAIL 或未执行项。

---

## 二、一次性用户授权硬门

### 2.1 今晚续跑所需的封闭授权集合

| ID | 精确动作 | 精确范围 |
|---|---|---|
| B1 | 创建/chown、挂载/卸载专用目录 | 157 仅 `/mnt/juicefs-v01-drain`、`/mnt/juicefs-v01`；必要时只对这两个精确挂载点 `sudo umount` |
| B2 | 启动一个无 fio 的排空挂载 | 仅 `/mnt/juicefs-v01-drain`，使用固定 `/tmp/juicefs-03-8`；允许 `TrashDays=0` 客户端自然删除已无元数据引用的 pending slices；禁止 `gc --delete` |
| B3 | 本地临时 SDK、clone、测试和构建 | 仅 `/home/lilingfeng/tmp/juicefs-v01-r1-*` 与 `/home/lilingfeng/tmp/juicefs-c03-r4-*`；允许 `dpkg-deb -x` 和任务目录内 symlink；禁止 `apt install`、`dpkg -i`、修改系统路径 |
| B4 | 一次性 Redis 容器 | 仅名称和 label 都含本轮 RUN_ID 的容器；允许 task-owned `docker run/stop/rm`，若环境只允许 sudo，则只授权这些精确容器的 `sudo docker`；禁止管理未知容器或 Docker 服务 |
| B5 | 复制和执行任务二进制/脚本 | 157 仅 `/tmp/juicefs-v01-r1-$RUN_ID-{S,A,B}` 与 `/tmp/opencode-v01-r1-$RUN_ID*`；禁止覆盖已有 `/tmp/juicefs-03-8` |
| B6 | drop Linux page cache | 仅 157、150、151、152，在 V01 正式 fio 前执行任务书规定的 `sync; echo 3 > /proc/sys/vm/drop_caches` |
| B7 | V01 正式写 fio | 仅 `/mnt/juicefs-v01` 看到的既有 `test_dir/storage_test.*.0`、`test_dir/rw_test.*.0`；不 layout、不 format、不 create-on-open |
| B8 | 写后 compact | 每个正式写轮最多一次 `juicefs gc --compact`，以及 `ceph tell osd.* compact` 和只读 cooldown 轮询；禁止额外 pass、`gc --delete`、restart |
| B9 | 条件性完整性目录 | 仅创建/删除 `/mnt/juicefs-v01/test_dir/v01-integrity-$RUN_ID`；删除前执行 realpath 双重守卫 |

用户批准原文必须逐字保存为：

```text
/home/lilingfeng/tmp/juicefs-v01-r1-$RUN_ID/authorization.txt
```

并保存 SHA256。缺任一动作的授权，只关闭相应 lane；不能伪造 ACK，也不能因此提前结束其它离线 lane。

建议用户原文：

```text
我授权执行 V01-R1 任务书 §二 B1—B9，授权截止到北京时间 2026-08-18 09:00；除此之外不授权，禁止项保持不变。
```

### 2.2 明确未授权

- `juicefs gc --delete`、destroy、format、pool delete/create；
- 修改 PG/PGP/CRUSH、Ceph/TiKV/PD/RocksDB 参数；
- 重启 OSD、TiKV、PD、主机、网络或容器服务；
- 安装/卸载宿主系统包；
- kill 未知进程、卸载未知挂载；
- 修改 NIC/RoCE/MTU/RPS/IRQ/md0/WekaIO/BeeGFS/K8s；
- 覆盖业务 `/mnt/juicefs` 或系统二进制；
- GitHub commit/push/issue/PR 等社区写入。

---

## 三、固定输入、hash 与目录

### 3.1 固定输入

| 输入 | SHA256/固定值 |
|---|---|
| V01 权威子任务书 | `988f1ff52b5980194516e9463b31c40858dc83ebe120e45224be64058820cf17` |
| v1.3.1 base | `e0032b2ae5e9603403ca955eed7d05426f6f2f8c` |
| loadRange patch | `88bcd1afb708f363fe38a4d208976be7f409204674d7d7fc6e452ab01d4081ae` |
| A-sync patch | `e8dca1048a5f3765e97c7d57a2e7699c3c514f1ba155e519ace4369bfced5e92` |
| B main writer patch | `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| 三项社区测试 | `bce85ad4abf92a47074849a544aaa756963fb44a1839619bbc71c5d7ce1fe9bc` |
| C02 十项语义测试 | `03fa33d6da4829de4c1f6f3e539128f97c1f7273c29eb0b13579fd6ad08d120b` |
| C03-R3 权威任务书 | `5b1b2d2950d79bca6f733889f675d73092e84b9755fb6c3a56842161e6e352fb` |
| 本地 librados-dev deb | `6928beeb32f9c9375a764ed59c42a96f6f6944c8753112c146cfbfd002a842c1` |
| 157 已验证 A binary | `/tmp/juicefs-03-8`，远端 SHA256 `1f66cfae759335943f8c6e7910811cd24367a1f20dc85637af1f158cf2a5b3a3` |

路径：

```text
V01_TASK=prod-deploy/debug/juicefs-03-8-flush-race-community/tasks/V01-v131-B-async-SAB-performance-integrity.md
LOAD_PATCH=prod-deploy/debug/juicefs-03-8-flush-race-community/patch/eaf3d21f-partial-read.patch
A_PATCH=prod-deploy/debug/juicefs-03-8-flush-race-community/patch/juicefs-flush-race-fix-v131.patch
R3_INPUT=/home/lilingfeng/tmp/juicefs-c03-r3-20260817-200133/assets/input
DEV_DEB=/home/lilingfeng/librados-dev_20.2.0-0ubuntu2_amd64.deb
```

任一 hash 不匹配时仅关闭依赖它的 lane；保留实际值，继续独立任务。

### 3.2 新目录

```text
RUN_ID=YYYYmmdd-HHMMSS
CTRL=/home/lilingfeng/tmp/juicefs-v01-r1-$RUN_ID
SRC=$CTRL/src
SDK=$CTRL/librados-sdk
REMOTE=/tmp/opencode-v01-r1-$RUN_ID
REMOTE_DRAIN=/tmp/opencode-v01-r1-drain-$RUN_ID
C03R4=/home/lilingfeng/tmp/juicefs-c03-r4-$RUN_ID
```

所有路径启动前必须不存在。冲突时换 RUN_ID；禁止删除或复用未知目录。

### 3.3 SSH 规则

优先使用用户已经验证可用的 alias：

```text
ssh thailand
```

如果执行环境因系统 SSH config 权限报错，允许改用：

```text
ssh -F /home/lilingfeng/.ssh/config thailand
```

禁止把密码、token 或私钥复制进脚本、命令日志、报告和 archive。远端是 UTC+07，本任务所有 deadline 和状态时间统一用 `TZ=Asia/Shanghai` 生成，同时另存远端原始时间。

---

## 四、总状态机：任何单 lane 失败都不能提前 FINAL

### 4.1 启动顺序

```text
G0 全局只读 preflight
  ├─ health/路径/授权允许 → 启动 Lane D（远端空闲排空）
  └─ 同时开始 Lane L（本地全新 S/A/B）

02:15 北京时间决策门
  ├─ D=PASS + L=PASS + 环境全绿 + 剩余>=6h → Lane P full V01
  └─ 其它任何组合                         → Lane C full C03-R4

Lane P DONE/STOP 后若北京时间<07:15
  └─ 继续 Lane C 或 Tail，不提前 FINAL

08:15
  └─ 停止启动新 workload；清理、归档、报告
```

Lane D 的后台 idle mount 与 Lane L 的 WSL 本地工作允许并行；任何远端 fio 与其它远端 fio 严禁并行。Lane P 运行期间暂停新的本地重型 Go/race 测试，只做监控和轻量归档。

### 4.2 唯一允许写 FINAL 的条件

满足其一：

1. 北京时间已到 08:15，开始强制收尾；
2. P0/P1/尾任务全部到终态且没有剩余安全、独立、预登记工作；
3. 本地磁盘/主机或授权发生全局安全阻断，连离线任务也不能安全继续。

以下均不是总 FINAL 条件：对象数不达标、坏档、Ceph build 失败、157 SSH 暂断、某个 Go test 失败、Docker/Redis 失败、C03-R4 runner bug。它们只改变 lane 状态并触发下一个队列项。

### 4.3 状态台账

任务第一分钟创建：

```text
$CTRL/controller-state.tsv
```

精确 12 列：

```text
beijing_ts	remote_ts	lane	phase	attempt	host	pid	status	health	pool_objects	action	evidence
```

每个 START、DONE、STOP、修复、重试、lane transition、sleep、用户插话均实时追加。禁止把状态表放到 `$CTRL` 外，禁止最终凭记忆补写。

---

## 五、步骤 0：通读、静态扫描与全局只读 preflight

### 5.1 必读

完整阅读并在报告列出 hash：

```text
prod-deploy/skills/SYSTEM-SAFETY-SKILL.md
prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md
prod-deploy/skills/TESTING-GUIDE.md
prod-deploy/skills/test-commands-reference.md
prod-deploy/skills/interleaved-ab-tuning-skill.md
prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md
本任务书
V01 权威子任务书
C03-R3 权威任务书与 R3 报告
```

项目 skill 中若出现明文凭据，只能视为需要整改的历史问题；不得复制到新脚本或报告。所有 SSH 调用使用 alias/config。

### 5.2 生成 runner 前的强制扫描

扫描本任务新建的所有 shell 及其 source 子脚本：

- `sudo` 写操作；
- mount/umount、fio、gc、compact、docker；
- `rm`、chown/chmod、kill；
- reboot/shutdown/systemctl、destroy/format、pool/PG/CRUSH/config set；
- 明文 secret；
- `UsedInodes` 是否错误进入 pool object gate。

保存文件名、行号、完整匹配和结论。脚本里出现授权集合之外的状态写命令，runner 必须拒绝启动。

### 5.3 本地 preflight

保存：hostname、北京时间、磁盘、内存、Go/GCC、Git、Docker、当前进程、DEV_DEB hash、`dpkg-deb -f`、已安装 `librados2` 版本和库 hash。

必须证明：

- `/home/lilingfeng/project/juicefs` 只作只读 object seed；其 dirty worktree 不进入新 clone；
- DEV_DEB version 与 WSL 已安装 `librados2` 完全一致；
- 不执行 apt/dpkg install；
- CTRL/SRC/SDK/C03R4 均为全新路径；
- 剩余磁盘足以保存两套新包，不归档 Go cache 和 `.git`。

### 5.4 157 preflight

每项落盘：

1. hostname 必须 `oneasia-c1-cpu-node10`；
2. 北京时间与远端原始时间；
3. Ceph health/detail、PG、OSD tree/stat、pool df；
4. `pool_objects` 必须从 `ceph df --format=json` 的 `juicefs-data.stats.objects` 读取；
5. JuiceFS `UsedInodes/UsedSpace/TrashDays` 单独保存，绝不参与 pool gate；
6. mountinfo、全部 JuiceFS/fio 进程；
7. `/mnt/juicefs` 若 absent，则冻结 `ABSENT` 并要求全程仍 absent；若 present，则冻结 mount ID/PID/starttime/cmdline/exe hash；
8. 专用目录是否空闲；
9. `/tmp/juicefs-03-8` hash/version/ldd；
10. WekaIO/BeeGFS/K8s、load/memory、未知 fio。

health 非 OK、PG 非 active+clean、未知 fio、专用路径冲突或主挂载身份异常：不启动 Lane D/P，立即转 Lane L/C；禁止尝试“修集群”。

---

## 六、Lane D：专用空闲挂载促自然排空（无 fio）

### 6.1 目的与边界

本 lane 不是性能测试，也不是 `gc --delete`。只用已验证 `/tmp/juicefs-03-8` 挂载一个不访问数据的专用 mount，让 `TrashDays=0` 的正常客户端后台任务有机会回收已无元数据引用的 pending slices。

禁止：fio、find/遍历业务数据、读写测试文件、gc、compact、删除目录、多个排空 mount、修改 TrashDays。

### 6.2 启动

只有 B1/B2 授权、health/PG 全绿、无未知 fio 时：

1. 创建并 chown 精确 `/mnt/juicefs-v01-drain`；
2. 用 `/tmp/juicefs-03-8` 和固定参数 `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` 后台挂载；
3. 冻结 PID/starttime/cmdline/exe hash/mountinfo；
4. 不读取挂载内任何文件；
5. 启动 60s 一次的只读 trace。

`pool-drain.tsv` 精确列：

```text
beijing_ts	remote_ts	pool_objects	stored	bytes_used	max_avail	health	pg_state	mount_pid	mount_starttime
```

### 6.3 排空判据

正式性能可用门：

```text
pool_objects <= 3,110,000
```

目标门：`<=2,900,000`。达到正式门后继续观察 10 分钟，取三个相隔 5 分钟样本；三点均不超过 3.11M、health/PG 全绿、mount identity 不变才设置 `DRAIN_PASS=YES`。

`UsedInodes` 只能写 `meta-context.tsv`；任何脚本若用它填 `pool_objects`，立即 `DRAIN_INVALID-METRIC`，保存脚本并关闭 Lane D，不得现场改门后续跑。

### 6.4 有界等待与 STOP

- 30 分钟时，相比起点下降不足 1%：`NO-DRAIN-EFFECT`，优雅卸载，转离线；
- 仍明显下降：最多观察 120 分钟；
- 120 分钟仍高于 3.11M：`DRAIN-TIMEOUT`，优雅卸载，转离线；
- pool objects 比起点上升超过 1%、health 连续两次非 OK、PG 异常、mount identity 变化或业务负载异常：立即优雅卸载并 `DRAIN-SAFETY-STOP`；
- SSH 断线不重复挂载；恢复后先查精确 PID/mountinfo。

任何 STOP 后都禁止 `gc --delete`、额外 mount、重启或修改阈值。Lane L/C 继续。

---

## 七、Lane L：全新 v1.3 正确性、隔离 Redis 与 Ceph 构建

### 7.1 不复用旧 OUT

从 `/home/lilingfeng/project/juicefs` 的 Git objects 创建 S/A/B 三个全新 clone，checkout 完整 base SHA。禁止修改 seed worktree，禁止复制其 dirty 文件。

三臂严格按 V01 §2.4；保存 before/after status、HEAD、完整 binary diff、changed+untracked path 并集和 patch hash。B production writer 必须逐条满足 V01 的五条语义。

### 7.2 三项社区正确性矩阵

完全执行 V01 §4.3～4.4：

- S：U1/U3 各 10 个独立进程按 marker 失败，U2 通过；
- A：U1/U2 single 与 count20 通过，U3 只记录；
- B：U1/U2/U3 single、count100、race20 全通过；
- B：完整 `pkg/vfs`、gofmt、diffcheck、vet、build。

每个命令必须有真实 `.rc` sidecar。结果表固定为 V01 的 14 列；runner 自测必须证明 rc=0 但 99/100 PASS 会判 NO，`bad` 和 `log` 不错位。

### 7.3 一次性 Redis

完整 `pkg/vfs` 只使用本轮唯一容器：

- 冻结 Docker version/context、image ID/RepoDigest；
- loopback 临时端口，不借用 6379 已有服务；
- 每次 run/PONG/inspect/log/test/stop/gone 分别记录真实 rc；
- 生命周期 TSV 每数据行精确七列；
- trap 只 stop/remove 精确容器 ID，末尾查询为空。

Docker 不可用时把 full-vfs 标 `BLOCKED-REDIS`，继续 Ceph build 和 Lane C；不能复用未知 Redis 后写 PASS。

### 7.4 C02 十项扩展语义移植

把固定 `writer_flush_c02_test.go` 适配到 v1.3 B。允许改：接口签名、测试 harness 构造、测试文件名；禁止改测试名、断言、故障注入状态机和 production writer。

保存 main/v1.3 逐项映射和 `port-adaptations.tsv`。B 执行：

```text
10 tests × single
10 tests × count=100
10 tests × race count=20
```

逐测试解析，不以组合命令总 rc 替代。扩展语义失败不删除三项社区测试证据，但会阻止 `V131-B-LOCAL-READY`。

### 7.5 无安装 Ceph builder

固定 DEV_DEB：

```text
/home/lilingfeng/librados-dev_20.2.0-0ubuntu2_amd64.deb
SHA256=6928beeb32f9c9375a764ed59c42a96f6f6944c8753112c146cfbfd002a842c1
```

步骤：

1. `dpkg-deb -x` 到全新 `$SDK`；
2. 证明 deb version 与宿主已安装 `librados2` version 完全相等；
3. 仅在 `$SDK/usr/lib/x86_64-linux-gnu/` 创建指向宿主真实 `librados.so.2` 的 task-owned symlink，使 deb 内 `librados.so` 链闭合；
4. 设置任务级 `CGO_CFLAGS=-I$SDK/usr/include` 和 `CGO_LDFLAGS=-L$SDK/usr/lib/x86_64-linux-gnu`；
5. 分别在 S/A/B 执行 `make juicefs.ceph`；不得修改 Makefile/go.mod/go.sum；
6. 保存命令、env 白名单、真实 rc、version、SHA256/MD5/size/build-id、`ldd`、`go version -m`、source diff hash；
7. 从 ELF dynsym 提取所需 `rados_*` 未定义符号集合，供远端 ABI 比对。

本 lane 最多两个正式 build attempt。可修 include/lib 路径或 task-owned symlink；不可安装包、换依赖版本、删 build tag 或退回无 Ceph binary。

### 7.6 远端 ABI 与只读冒烟

只有三 build 成功且 B5 授权：

1. 复制到 157 的三个精确 `/tmp` 路径，重算 hash；
2. `ldd` 不得有 `not found`，`librados.so.2` 必须解析；
3. 比较每个 binary 需要的 `rados_*` dynsym 是否全部由 157 runtime 导出；
4. 只在 Lane D 已结束且 health 绿时，各 binary 用 `/mnt/juicefs-v01` 做一次新挂载并读取一个已知测试文件的固定小范围到 `/dev/null`；不得写入；
5. 每臂优雅卸载，保存 mount identity、read rc、JuiceFS log 和 dmesg 新增错误。

任一 ABI/read smoke 失败，Lane P 关闭并转 Lane C。禁止在远端安装开发包或 Go。

---

## 八、02:15 在线决策门与 Lane P

### 8.1 启动 Lane P 的全部条件

北京时间不晚于 02:15，并且：

```text
DRAIN_PASS=YES
pool_objects <= 3,110,000（三个稳定样本）
health=HEALTH_OK，PG=active+clean
V131-B-LOCAL-READY=YES
S/A/B_CEPH_BUILD=YES
S/A/B_REMOTE_ABI_SMOKE=YES
无未知 fio，主挂载身份与 preflight 一致
预计剩余时间 >= 6h
```

少一项都不启动 partial matrix，立即 Lane C。不得把 deadline、对象门或 Ceph build 改成 warning。

### 8.2 权威性能流程

完整执行 V01 任务书 §§5～8，输入替换为本轮全新三二进制；其它参数、顺序、ns/B 门、fio 时长、轮数、对象 watchdog、统计和判据一律不变。

特别复述：

- 固定顺序 `S1-A1-B1-B2-A2-S2`；
- 每位置新挂载，两次 ns/B，偏离 3.287 不超过 10%；
- 每个 mount 两轮 randwrite + 两轮 randrw，均 180s/128 jobs/256K；
- 每个 fio 前四节点 drop_caches；
- 保存全部 128 个 per-job bw logs，从 start-ns 对齐重算；
- randrw R/W 分开；
- 每写轮后最多一次 gc compact + OSD compact cooldown；
- 对象数来源永远是 Ceph pool，运行 watchdog `>8,000,000` 立即停止本 lane；
- S 必须重现塌态、A 必须是阳性对照，B 才能做修复与非劣判断。

任何坏档三次、对象越界、health/identity/证据门失败只关闭 Lane P；清理专用 mount 后转 Lane C/T，不能结束 controller。

### 8.3 完整性

完全采用 V01 §8。只有完整六位置机械暂定 `PASS-B-V131-PERF-NONINFERIOR`、北京时间不晚于 07:15 且剩余 >=75min 才执行；否则 `TIMEBOX-SKIP`。

---

## 九、Lane C：C03-R4 full 与离线队列（不依赖远端）

### 9.1 强制进入条件

满足任一就进入：

- 02:15 时 Lane D/L 任一未 PASS；
- Lane P 任何 STOP/INVALID/BLOCKED；
- Lane P 提前完成且北京时间早于 07:15；
- 远端 SSH/health/对象/挂载安全门关闭。

Lane C 不得被 Ceph build、157 或 pool objects 阻塞。

### 9.2 C03-R4 合成预飞必须修复的十项

从 R3 input 只读复制到全新 R4 input；禁止原地改 R3。先修 runner，再运行合成预飞：

1. result TSV 精确 14 列，`bad/log/expectation_matched` 不错位；
2. rc=0 但 99/100 PASS 时 gate=NO；
3. Redis 数据逐行七列，不允许冒号打包；
4. expected/manifest/tar/extract 做真实集合比较；
5. expected 或 tar 出现 duplicate pathname 时失败；
6. archive-vs-expected、extract-vs-expected、manifest-vs-expected 三个 diff sidecar 无条件生成；
7. static review 任一 NO，formal runner 拒绝启动；
8. VERIFY 启动前必须不存在；绝不删除或覆盖旧 VERIFY；
9. untracked source artifact 进入 changed-path/source guard；
10. payload freeze 后禁止生成或修改 `final-compliance-review.md` 等 payload 文件。

合成矩阵至少：terminal 8、result parser 3、archive set 6（含 duplicate）、source guard 2。每 case 保存输入、输出、真实 rc 和期望。

### 9.3 C03-R4 full clean run

预飞全 PASS 后执行全新 formal attempt，不复用 R3 PASS：

- 只读 fetch 官方 main，冻结执行时 commit/time/title；
- 若 writer base blob 未变，标准 apply B；若变更，仅允许上下文适配且必须证明五条语义未改，否则 `UPSTREAM-DRIFT-BLOCKED`；
- stock oracle、B 三项 community、C02 十项语义、count/race；
- 双工具链（按 R3 已验证获取方式）、各自一次性 Redis、完整 `pkg/vfs`；
- gofmt/tidy/vet、官方 lint、Linux/lite build、patch replay；
- source/protected paths、secret、community duplicate-search 只读证据；
- 14 列结果表与十项 archive integrity；
- archive payload 冻结后，全部 terminal 校验只写外置 TERMINAL；
- 不 commit/push/issue/PR。

正式 attempt 最多两个；只有 attempt 1 在任何 Go test 前因纯 runner bug 退出才允许 attempt 2。任何失败保留完整现场，然后继续 §9.4/§9.5，不能提前 FINAL。

### 9.4 V01 本地证据审计/补包

无论 Lane L PASS/FAIL，都检查新 CTRL 是否包含：input、三 clone 身份、patch、diff、完整 rc/log、14 列结果、Redis lifecycle、Ceph build provenance、commands、adaptations、SHA 和 exact archive set。

只修采集/manifest/打包，不修改冻结测试结果。缺测试不能用补文档冒充 PASS。

### 9.5 仍有时间时的预登记尾任务

按顺序，前一项完成或精确 BLOCKED 后继续：

1. B-v1.3 三项 community `count=1000` 和 `-race -count=100`；
2. B-v1.3 C02 十项 `count=500` 和 `-race -count=50`；
3. 在第二个干净 B clone 标准 replay port patch，比较 production diff 逐字节相等；
4. 生成本地 issue draft、PR draft、测试矩阵和风险说明，明确未提交；
5. 对 R3、R4、V01-R1 三包做成员去重、secret scan、SHA manifest 和可复现命令审计。

每项最多一个 stress attempt；失败如实记录并进入下一项。07:45 后不再启动 stress，只做轻量审计。

---

## 十、自治修复、监控与 attempt 纪律

### 10.1 可自主修复

- SSH config 选择、短暂断线、scp 重试；
- 本地路径、bash 语法、权限位、parser、manifest；
- v1.3 测试 harness 接口适配；
- task-owned SDK include/lib/symlink；
- C03-R4 runner/launcher/finalizer 工程 bug；
- 证据采集遗漏，只要尚未冻结 payload 或使用新 attempt。

每次必须先保存旧 attempt，记录症状、旧/新 SHA、diff、原因、为何未改实验变量。禁止修完后续写旧 formal TSV。

### 10.2 不能自主修复

- 把 pool objects 改成 UsedInodes；
- 改 3.11M/8M 对象门、ns/B 参照/阈值、S/A/B 顺序、fio 参数/时长/轮数；
- 改 A/B production 语义、测试断言或非劣界；
- 额外 gc/compact、gc delete、destroy/format/pool/PG/CRUSH/config/restart；
- 安装系统包、启停 Docker 服务；
- kill/umount 未知进程或挂载；
- 触碰业务挂载、系统 binary 或社区远端。

### 10.3 监控

- 排空/cooldown：每 5～10 分钟唤醒；pool trace 自身 60s 采样；
- 正式 fio：按预计完成时间 2～10 分钟；
- 本地长 Go/race：5～15 分钟；
- 默认无人值守不得单次 sleep 超过 30 分钟；sleep 前打印北京时间；
- 每小时更新 ETA 与 02:15/07:15/08:15 deadline 风险。

每次唤醒必查精确 PID、日志尾、DONE/STOP/rc、health/PG/pool objects、mount identity、未知 fio、结果目录增长。进程消失不等于 DONE。

### 10.4 用户插话与 SSH 断线

用户消息优先响应，但后台任务不得重复启动。SSH 恢复后先查原 wrapper PID、mount PID、starttime、日志和 rc；无法确认时关闭远端 lane并转离线，不启动第二份。

---

## 十一、交付物与机械判定

### 11.1 CTRL 必须目录

```text
$CTRL/
  authorization.txt
  input/
  preflight/{local,remote}/
  controller-state.tsv
  lane-status.tsv
  attempts.tsv
  adaptations.tsv
  commands.sh
  src/{S,A,B}/
  patches/
  tests/
  results-correctness.tsv
  semantic-results.tsv
  redis-lifecycle.tsv
  librados-sdk-meta/
  binaries/
  build-provenance.tsv
  remote-abi.tsv
  drain/
  performance/                 # 条件性，保存远端包路径/hash
  c03-r4/                      # 条件性，保存 R4 包路径/hash
  final-inventory.tsv
  final-status.txt
  SHA256SUMS
```

### 11.2 报告

写入：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/V01-R1-execution-$RUN_ID.md
```

报告按事实分开：

1. 上一轮订正；
2. Lane D 对象曲线与正式门；
3. Lane L 每一硬门和实际行数；
4. Ceph build/ABI；
5. Lane P 完成度和 raw 路径，不替 Codex 做最终归因；
6. C03-R4 14 列/Redis/archive/terminal 状态；
7. 所有 attempts/adaptations/STOP；
8. 未执行项与准确原因；
9. 授权与红线合规。

### 11.3 archive

- 生成 C-locale 排序且唯一的 expected regular-file set；
- expected 中重复路径直接失败；
- SHA manifest 覆盖 expected 除自身外的全部普通文件；
- tar regular-file set、extract set 与 expected 精确相等；
- 三个集合 diff sidecar 始终生成；
- 禁止归档 `.git`、Go/module/build cache、未脱敏 credential、巨大重复文件；
- 不删除失败 OUT/VERIFY。

### 11.4 机械最低交付

即使所有测试失败，也必须交：授权、controller state、所有 STOP 原文、对象 trace、构建日志、attempt/adaptation、commands、inventory、SHA、报告。缺这些时不能写 `DONE-*`。

---

## 十二、通用注意事项与红线复核

1. 每个正式 fio 前 health、PG、四节点 drop_caches、pool objects、mount identity；只读/写都保留全文和 per-job logs。
2. fio 统计从全部 job 按 start-ns 对齐逐秒求和；截缓冲暂态后取稳态中位，randrw R/W 分开；禁止单 log × jobs。
3. 复用既有 layout，禁止 fresh volume、create-on-open、format、destroy。
4. 每个新挂载重新判 ns/B；重试换 label；坏档最多三次，不放宽门。
5. 写后最多一遍 gc compact，再做 OSD compact cooldown；`compact_running=0`、`compact_queue_len=0`、KV latency 全部落盘。
6. 配置、pool_id、PG/PGP、CRUSH、OSD up_from、主挂载身份前后必须一致。
7. Lane D 的自然删除是本轮唯一高对象态允许的远端状态变化；它不能产出性能结论。
8. 157 上 WekaIO/BeeGFS/K8s/NIC/RoCE/MTU/md0 是红线。
9. 禁止任何重启、pool 操作、系统安装、业务替换和社区写入。
10. 最后按 SYSTEM-SAFETY、LONG-RUNNING、TESTING-GUIDE、test-commands-reference 和 authoring guide 逐条自查；任一不符明确降级。

---

## 十三、GLM 最终回复模板

```text
窗口：<北京时间 start> ～ 2026-08-18 09:00
总状态：<六个允许状态之一>
授权文件/SHA：
CTRL/archive/SHA：

Lane D：PASS / TIMEOUT / NO-EFFECT / SAFETY-STOP / NOT-AUTHORIZED
pool objects 起点/最低/终点，trace：
专用 drain mount 是否清理：

Lane L：PASS / PARTIAL / BLOCKED
S/A/B correctness 行数和异常：
C02 v1.3 扩展语义：
Redis lifecycle：
S/A/B Ceph build 与远端 ABI：

Lane P：<V01 状态或 NOT-RUN>
六位置完成度、raw OUT/archive/hash：
integrity：

Lane C：C03-R4 状态 / NOT-RUN
R4 OUT/archive/terminal/verify/hash：
14 列、Redis 七列、四集合和 duplicate gates：

所有 attempt、修复、STOP、偏差：
主挂载 before/after：
health/PG 起止：
未执行项及原因：

声明：未把 UsedInodes 当 pool objects；未执行 gc --delete/destroy/format/pool/restart/系统安装/生产替换/社区写入；等待 Codex 复算和审阅。
```
