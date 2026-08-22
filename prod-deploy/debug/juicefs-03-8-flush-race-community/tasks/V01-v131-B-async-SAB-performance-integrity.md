# V01：JuiceFS v1.3.1 的 S/A/B 性能、正确性与条件性完整性验证

> 执行方：GLM　｜　分析方：Codex　｜　日期：2026-08-17/18  
> 性质：夜间时间盒任务；先做本地可移植性与正确性，再做生产测试卷上的 S/A/B 性能，最后按剩余时间做 B 完整性冒烟  
> 硬截止：北京时间 2026-08-18 08:15 后不启动新负载，08:45 前清理/归档，09:00 前完成原始执行报告  
> 本任务书不授权任何操作；只有用户对夜间总任务书中的“精确授权清单”明确同意后，才可设置授权变量并上机  
> 禁止：修改 `/usr/local/bin/juicefs`、触碰业务挂载、删除/重建 pool、重启服务/节点、修改 Ceph/TiKV 参数、提交或推送社区

---

## 计划线

```text
C01/C02
  └─ 已从原理层确定 main 的完整块漏派发行为
C03~R3
  ├─ raw technical evidence：main stock 失败、B/Q/replay 通过
  └─ PR-ready 审计仍不合规；不影响本任务回答 v1.3 性能问题
03-8 A-sync
  └─ v1.3.1 已有 randwrite 551 → 2970~3583 MiB/s 的性能实证
★ V01（你在这里）
  ├─ S：v1.3.1 stock + loadRange
  ├─ A：S + 已验证的同步分配补丁
  └─ B：S + main 候选的异步 catch-up 语义移植
      ├─ B 修复且不劣于 A → B 成为 v1.3 首选候选，进入长稳/社区双线
      ├─ B 修复但劣于 A   → 保留两候选，交 Codex 分析
      └─ B 不修复         → v1.3 内部继续 A，main 的 B correctness 结论独立保留
```

一句话：证明 B 不仅在 main 的定向单元测试中正确，也能在 v1.3.1 的真实 randwrite 塌态中恢复性能，并与 A-sync 做同夜、同基座、同口径的非劣对照。

---

## 〇、背景与当前可承接结论

### 0.1 已证

1. v1.3.1 stock 在 `--max-fuse-io 256K` 下的 randwrite 塌态长期稳定在约 535~551 MiB/s。
2. A-sync 在 v1.3.1 上已有 03-8 ABBA 性能证据：2970~3583 MiB/s，臂中位约 3003.5 MiB/s。
3. frozen main `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a` 上，B 的定向社区测试、C02 十项语义测试、race、完整 `pkg/vfs`、lint 和 build 的原始日志均支持 technical PASS。
4. B 与 A 的关键差别：A 把首次 `NewSlice` 放到写路径同步完成；B 保留 `go s.prepareID(...)`，在 ID 就绪后对已经形成的完整块补发 `FlushTo`。

### 0.2 未证，也是本任务唯一理由

- B 的 main 版本尚未在 v1.3.1 真实塌态上做过性能验证。
- B 移植到 v1.3.1 后是否能达到 A 的恢复幅度、是否引入 randrw 回退、是否保留数据完整性，尚无同场证据。
- C03-R3 的审计脚本缺陷不得被带入本轮：结果必须从原始 fio bw log 和真实 rc 重算，不能由一个总 gate 替代。

### 0.3 本轮不回答

- 不判断 main 上的整体 randwrite 塌态是否由这个竞态主导；已有资料说明 main 的深退化还有独立排水瓶颈。
- 不宣称 GitHub CI、维护者 review 或社区合入已经完成。
- 不做 8 小时正式 soak；若时间允许，只做有明确上限的完整性冒烟。正式长稳另开任务。
- 不跑 03-17、03-18、TiKV 参数、direct-rados、max-downloads 或任何 OSD 参数扫描。

---

## 一、目标、优先级与状态名

### 1.1 P0：v1.3.1 移植正确性

在固定基座上生成并冻结 S/A/B 三臂，证明：

- S 保留原始异步缺口；
- A 只包含已有同步补丁；
- B 只包含与 main B 等价的异步 catch-up writer 修改；
- B 的 full/partial/error 三项定向行为全部通过，且无 race；
- 三臂二进制均来自可追溯源码，支持 Ceph 后端。

### 1.2 P0：真实性能问题

唯一主问题：

> 在 v1.3.1 真实 256K randwrite 塌态中，B 是否相对 S 恢复至少 3 倍，并在预登记 5% 非劣界限内不劣于 A？

### 1.3 P1：randrw 安全性

B 相对 A 的 randrw 读、写两个方向分别记录；只做非劣性判断，不把读写相加冒充单方向性能。

### 1.4 P2：条件性完整性冒烟

仅当 P0 全部有效且 07:15 前仍有至少 75 分钟时执行。否则写 `TIMEBOX-SKIP`，不是失败。

### 1.5 最终状态只能取以下之一

```text
PASS-B-V131-PERF-NONINFERIOR
PASS-B-V131-FIXES-BUT-INFERIOR
FAIL-B-V131-NO-RECOVERY
INVALID-ENVIRONMENT-NONDISCRIMINATING
PARTIAL-TIMEBOX
BLOCKED-SAFETY-OR-AUTH
BLOCKED-BUILD-OR-PORT
```

GLM 只按机械门写状态，不做根因扩展；全部统计和最终工程取舍由 Codex复核。

---

## 二、固定输入、隔离目录与三臂定义

### 2.1 固定源码输入

| 资产 | 固定值/位置 | 规则 |
|---|---|---|
| v1.3.1 base | commit `e0032b2a` | 三臂同一 base |
| loadRange 修复 | commit/patch `eaf3d21f`；仓库备份 `patch/eaf3d21f-partial-read.patch` | 三臂都必须包含 |
| A-sync patch | `patch/juicefs-flush-race-fix-v131.patch` | 只进 A |
| B writer reference | `/home/lilingfeng/tmp/juicefs-c03-r3-20260817-200133/assets/input/async-catchup-main.patch` | 启动前 SHA256 必须为 `b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355` |
| B full main reference | `/home/lilingfeng/tmp/juicefs-c03-r3-20260817-200133/artifacts/community-candidate.patch` | 参考 SHA256 `1050e94f6f2f52091a99afd4ad2aaf3c6cde147590f9f28b48b377e72b5281f9` |
| main community tests | R3 input 的 `writer_flush_test.go` | 只能做 v1.3 接口适配，不改变断言语义 |

若上述 `/home/lilingfeng/tmp` 固定资产缺失或 hash 不符，停止使用该资产；不得从聊天记录手抄补丁。可从 R3 archive 按已记录 archive SHA 只读提取到全新 input，提取过程与 hash 必须落盘。

### 2.2 本地执行目录

```text
RUN_ID=YYYYmmdd-HHMMSS
INPUT=/home/lilingfeng/tmp/juicefs-v01-input-$RUN_ID
OUT_LOCAL=/home/lilingfeng/tmp/juicefs-v01-local-$RUN_ID
SRC_S=$OUT_LOCAL/src/S
SRC_A=$OUT_LOCAL/src/A
SRC_B=$OUT_LOCAL/src/B
```

全部必须启动前不存在；禁止复用 C03 clone、Go cache、旧二进制或旧 PASS。若路径冲突，换新的 RUN_ID，禁止删除未知目录。

### 2.3 157 上的精确范围

```text
REMOTE_OUT=/tmp/opencode-v01-$RUN_ID
REMOTE_ARCHIVE=/tmp/opencode-v01-$RUN_ID.tar.gz
MNT=/mnt/juicefs-v01
```

- `/mnt/juicefs` 只记录 before/after 身份，禁止在其下起 fio、卸载、重挂或改参数。
- V01 只创建、挂载和卸载 `/mnt/juicefs-v01`。
- 二进制只放 `/tmp/juicefs-v01-$RUN_ID-{S,A,B}`，不得覆盖 `/tmp/juicefs-03-8` 或系统二进制。
- 性能数据复用测试卷已有 `test_dir/storage_test.*.0` 与 `test_dir/rw_test.*.0`，不 layout、不 format、不 create-on-open。

### 2.4 三臂精确定义

| arm | 源码 | production writer 允许的差异 |
|---|---|---|
| S | `e0032b2a + eaf3d21f` | 无 FlushTo 修复 |
| A | S + A-sync patch | 仅 `pkg/vfs/writer.go` 的同步 NewSlice 修改 |
| B | S + B-v1.3 port | 仅 `pkg/vfs/writer.go` 的异步 ID-ready catch-up 修改 |

B port 的语义必须逐项满足：

1. 保留 `go s.prepareID(meta.Background(), false)`，不得改同步；
2. 仅在 `prepareID` 已把正 ID 写入真实 writer 后检查；
3. `s.id > 0 && !s.freezed && int(s.slen) >= f.w.blockSize` 时调用一次 `FlushTo(int(s.slen))`；
4. `FlushTo` 错误记录为 `s.err = syscall.EIO`；
5. 不改 blockSize、flush 定时、buffer 节流、NewSlice retry 或其他 production 文件。

v1.3 接口不同导致的测试适配只能进入新测试文件，不能借“兼容”修改 production 逻辑。

---

## 三、步骤 0：必读、授权与静态预飞

### 3.1 必读

完整阅读：

```text
prod-deploy/skills/SYSTEM-SAFETY-SKILL.md
prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md
prod-deploy/skills/TESTING-GUIDE.md
prod-deploy/skills/test-commands-reference.md
prod-deploy/doc/perf-tasks/TASK-BOOK-AUTHORING-GUIDE.md
prod-deploy/doc/perf-report/03-8-deepseek-randwrite-256k-flush-fix-20260813.md
prod-deploy/debug/juicefs-03-8-flush-race-community/report/C03-R3-execution-20260817-200133.md
本任务书
```

最新计划书取消了写前的 60 秒 mutating preprobe；本轮第一组正式 S-randwrite 同时承担环境状态测量。不得额外写探针。

### 3.2 用户授权硬门

必须在夜间总任务书的授权记录中找到用户对以下动作的明确同意：

- `/tmp` 构建/复制三个测试二进制；
- 创建/chown、挂载/卸载 `/mnt/juicefs-v01`；
- 在专用挂载看到的既有测试文件上执行 randwrite/randrw；
- 157、150、151、152 的 `drop_caches`；
- 写轮后的 `juicefs gc --compact` 与 `ceph tell osd.* compact`/状态轮询；
- 条件性完整性任务仅创建和删除 `test_dir/v01-integrity-$RUN_ID`。
- 本地仅在 `/home/lilingfeng/tmp/juicefs-v01-$RUN_ID-*` 生成源码/构建产物，并按 §4.4 创建和清理唯一命名的一次性 Redis 容器。

缺远端动作授权时，远端状态为 `BLOCKED-SAFETY-OR-AUTH`；缺本地临时目录/Redis 授权时，只能做只读盘点和静态准备，不能完成 port/build/unit。

### 3.3 runner 预飞

GLM 可以编写 V01 wrapper，但正式启动前必须：

1. `bash -n` 为 0；
2. 静态扫描并保存所有 `sudo`、mount/umount、`rm`、gc、compact、fio、kill、网络/配置命令；
3. 确认无 `rm -rf`、`pkill`、`killall`、destroy、format、pool delete/create、OSD/TiKV restart、config set、community write；
4. `rm` 只能针对通过 realpath 证明位于 `test_dir/v01-integrity-$RUN_ID` 的任务自建路径；
5. 结果 parser 用三份合成 bw log 自测：正常多 job、少一 job、空日志；少/空必须失败；
6. PID guard 用合成 before/after 自测：相同 PASS、PID 变 FAIL、starttime 变 FAIL、exe hash 变 FAIL；
7. 所有 gate 初始为 `NOT_RUN`，不能默认 PASS；
8. 将静态扫描、自测命令、stdout、rc 写进 input，冻结后才允许执行。

脚本缺陷可在正式 attempt 前修复；一旦正式 attempt 启动，任何修复必须使用新 attempt 目录并保留旧目录。

---

## 四、本地三臂生成、代码守卫与正确性

### 4.1 三个全新 clone

从只读本地 Git object seed 创建三个独立 clone；每臂 checkout `e0032b2a`，标准应用 `eaf3d21f`。禁止修改 `/home/lilingfeng/project/juicefs`。

每臂保存：

- HEAD、describe、remote、base writer blob；
- `git status --porcelain=v2 --untracked-files=all` before/after；
- `git diff --binary --full-index`；
- `git diff --check` 真实 rc；
- changed + untracked path 的并集，而不是只看 `git diff --name-only`。

SQLite、journal、测试数据库等任何未跟踪文件都必须进入 path guard；测试结束后出现即标记 `SOURCE-TREE-POLLUTED`，不能静默忽略。

### 4.2 应用 A 与生成 B port

- A 必须从固定 patch 标准 `git apply --check` + `git apply`，保存两个真实 rc。
- B 先根据 §2.4 生成单文件 port patch，再在全新 B clone 标准 apply；保存 patch、SHA256、apply-check/apply rc。
- B port 与 main B 做语句级映射表：每一条条件、FlushTo 参数、错误映射分别列出 v1.3/main 行，不允许只写“等价”。
- 若 v1.3 上标准 apply 需要 context 调整，允许改 patch 上下文和日志格式；禁止改变五条语义。所有调整写 `port-adaptations.tsv`。

### 4.3 v1.3 定向测试移植

把 main 的三项社区测试适配为 v1.3 测试文件，允许的适配仅包括：

- `chunk.ChunkStore`/`NewWriter` 的接口签名；
- v1.3 不存在字段的测试 harness 构造方式；
- 日志/测试文件名。

以下测试语义和断言不得改变：

```text
TestFullBlockDispatchedWhenSliceIDBecomesReady
TestPartialBlockNotDispatchedWhenSliceIDBecomesReady
TestFlushErrorRecordedWhenSliceIDBecomesReady
```

### 4.4 正确性矩阵

| arm | single | count | race | 预期 |
|---|---|---|---|---|
| S | U1/U2/U3 | U1/U3 各 10 个独立进程 | 不要求 | U1/U3 按固定 marker 失败；U2 通过 |
| A | U1/U2/U3 | U1/U2 count=20 | 不要求 | U1/U2 通过；U3 只记录，不作为 A 性能控制硬门 |
| B | U1/U2/U3 | 三项 count=100 | 三项 `-race -count=20` | 三项全部精确通过，无 race |

B 还必须完成：

- `go test ./pkg/vfs -count=1`；
- `go test ./pkg/vfs -run '^Test(FullBlock|PartialBlock|FlushError)' -race -count=20`；
- gofmt、`git diff --check`、`go vet ./pkg/vfs`；
- 用项目实际支持的 Go 工具链完成一次构建；如 v1.3 不支持最新 Go，记录并使用该分支可构建的工具链，不得改 go.mod 规避。

完整 `pkg/vfs` 必须使用任务自己创建的一次性 Redis，不能借用或停止既有 Redis：

- 容器名必须含 `V01` 的 `RUN_ID`，记录 engine version/context、image ID 与 RepoDigest；
- 仅绑定 loopback 的临时端口，不使用 host network、privileged 或宿主目录 volume；
- `redis-cli ping` 返回 PONG 后才启动测试，保存容器 inspect/log；
- 无论测试成败都 stop/remove，末尾以按精确容器名查询为空证明清理完成；
- 若本机无可用容器引擎且两次有界修复仍失败，完整 `pkg/vfs` 为硬门失败；不得安装系统 Redis、复用 6379 上未知服务或跳过该门后继续远端性能。

结果 TSV 必须 14 列并逐测试解析：

```text
arm	tool	mode	test	actual_rc	expected_pass	actual_pass	expected_fail	actual_fail	expected_marker	actual_marker	bad	log	expectation_matched
```

`bad` 只能为 YES/NO，`log` 必须存在且非空；禁止再次把日志路径写进 bad 列。所有组合测试都逐测试名锚定统计。

### 4.5 三个 Ceph 二进制

分别构建 S/A/B，构建方式必须与已验证 `/tmp/juicefs-03-8` 的 Ceph tag/链接口径一致。每个二进制保存：

- 完整构建命令和 rc；
- SHA256、MD5、size、ELF build-id；
- `version` 原文；
- `ldd`/Ceph 后端可用性证据；
- 对应 source diff SHA256。

在 157 复制后重算 SHA256，源端/目标端必须一致。任何一臂构建或 Ceph 后端冒烟失败，不得进入性能矩阵。

---

## 五、远端性能前置与安全门

### 5.1 必须在 03-16 之后

夜间总编排中，V01 的任何远端写负载必须等 03-16 Phase R 已 DONE/STOP、其 archive 已封存、P/Q 专用挂载已清理后才能开始。禁止并发 fio。

### 5.2 启动前保存并硬判

1. hostname 必须是客户端 157；
2. Ceph `HEALTH_OK`，PG 全 active+clean；
3. `juicefs-data` 对象数可解析且 `<=3,110,000`；
4. `/mnt/juicefs` 的 mountinfo、PID、starttime、cmdline、exe hash 冻结；
5. 没有未知 fio；WekaIO/BeeGFS/K8s 没有异常共享负载；
6. `storage_test.*.0` 和 `rw_test.*.0` 各精确 128 个，文件大小符合历史布局；
7. `/mnt/juicefs-v01` 未挂载且目录内无用户数据；
8. `/tmp` 和集群空间满足既有安全线；
9. pool_id、PG/PGP、CRUSH map hash 保存，任务全程不得变化。

任一环境门失败：不得通过 gc、重启、改参数或删数据“修到能跑”。记录并转 `BLOCKED-SAFETY-OR-AUTH` 或 `INVALID-ENVIRONMENT-NONDISCRIMINATING`。

### 5.3 挂载参数

三臂完全相同：

```text
--max-uploads 150 --cache-size 0 --max-fuse-io 256K
```

不额外增加 `--buffer-size`、`--max-readahead` 或其它参数。每次挂载后从 `/proc/<pid>/cmdline`、mountinfo 和 `/proc/<pid>/exe` 证明 arm、参数、PID、starttime 和二进制 hash。

### 5.4 档位门

- 每个新挂载先连续跑两次 mseqread ns/B 探针；
- 取两次 ns/B 中位数，相对 3.287 ns/B 偏差 `<=10%` 才是好档；
- 每个逻辑位置最多三次挂载尝试，每次必须新 label；
- 不能改用 raw mseqread 吞吐门；
- gate 后 PID/starttime/exe hash 任一变化，该 mount 的全部效应数据作废。

---

## 六、S/A/B 交错矩阵与原始口径

### 6.1 固定顺序

```text
block 1: S1 → A1 → B1
block 2: B2 → A2 → S2
```

每个逻辑位置必须是一个通过 ns/B 门的新挂载。不得为了凑结果调整顺序或复用实例。

### 6.2 每个 mount 的固定步骤

1. 保存 pre snapshot、health、objects、mount identity；
2. 两次 ns/B gate；
3. gate 后再次冻结 PID/starttime/exe hash；
4. `randwrite` 两轮，每轮 180s，128 jobs，bs=256K，复用 `storage_test.*.0`；
5. 每个 fio 前四节点 drop_caches、health、对象数和 mount identity；
6. 每轮保存全部 128 个 per-job bw log、fio 全文、start-ns、I1、进程 CPU/RSS、NIC、OSD/TiKV只读指标；
7. 每个高强度写轮后执行预授权的一遍 `juicefs gc --compact`，再做 compact cooldown，轮询 `compact_running=0`、`compact_queue_len=0`、KV 延迟安全门；
8. `randrw` 两轮，规则同上，读写方向分别保存；
9. 保存 post snapshot、身份和对象数，优雅卸载专用挂载。

若时间预算不足，必须完成当前 mount 的收尾后停止；不得砍 randwrite 轮次。砍单顺序：完整性冒烟 → block 2 的 randrw → 整个 block 2。只完成 block 1 时状态必须 `PARTIAL-TIMEBOX`。

### 6.3 轮内对象数看门狗

每个写 fio 启动后每 30 秒采一次 pool objects、stored、max_avail 与 health：

- 取数连续三次失败：停止当前 lane；
- objects `>8,000,000`：立即按 wrapper 的精确 PID 优雅终止本任务 fio，保留现场；
- 内存/used buffer `>4 GiB`、health 连续三次异常或共享业务异常：同样停止；
- 不允许等 objects 自然下降后继续，也不允许临时增加 GC pass。

### 6.4 带宽原始口径

每轮的验收值只能从全部 per-job bw log 重算：

1. 按该 fio 的 `start-ns` 对齐；
2. 同秒跨 128 job 求和；
3. 取 `15 <= sec-t0 <= 175`；
4. 记录逐秒均值、中位数、CV、stall，但主值沿用阶段计划的逐秒均值口径；
5. randrw 对 direction 0/1 分开计算；
6. 同一 mount 两轮取 mount-level 中位数；
7. 两个 mount 的 arm-level 值只供机械 gate，Codex会从 raw log 重算。

缺任一 job log、时间窗口不足、方向字段异常或 parser 自测未通过，该轮无效，不得用 fio 汇总行代替。

---

## 七、机械判据与分支

### 7.1 有效性门

以下全部满足才进入性能判据：

- 两个 block 的六个逻辑位置全部完成，且每个通过 ns/B 门；
- 每个 mount 的 PID/starttime/exe hash 不变；
- 所有 fio rc=0、128 job log 齐全；
- health、objects、主挂载身份和固定配置守卫无变化；
- S/A/B source、patch、binary hash 可追溯；
- A 与 B 都没有 JuiceFS EIO、panic、fatal、data corruption 或进程退出。

否则只能是 `PARTIAL`、`INVALID` 或 `BLOCKED`，不能计算正式 PASS。

### 7.2 S 环境鉴别门

S 的四个 randwrite 原始轮次应再次表现出塌态：

```text
arm-level randwrite < 1000 MiB/s
且四轮最大值 < 1200 MiB/s
```

若 S 不塌，环境没有形成可鉴别对照，状态为 `INVALID-ENVIRONMENT-NONDISCRIMINATING`；不得因为 B 数值高就宣称修复。

### 7.3 A 阳性对照门

A arm-level randwrite 必须 `>=1653 MiB/s`。低于该值说明已知有效的 A 在当前窗口都不能恢复，B/A 对比不具解释力；记录环境、停止扩展结论。

### 7.4 B 修复门

B 同时满足：

- arm-level randwrite `>=1653 MiB/s`；
- `B/S >=3.00`；
- B 两个 mount 都高于 S 两个 mount 的最大值；
- 没有 EIO、buffer >4 GiB 或对象看门狗事件。

满足才叫“B 在 v1.3 真实塌态中修复性能”。

### 7.5 B 相对 A 非劣门

预登记非劣界限为 5%：

```text
B_randwrite / A_randwrite >= 0.95
```

这是两挂载/臂的非劣判断，不得改写成“B 显著优于 A”。若比值在 `[0.90,0.95)`，状态仍为 fixes-but-inferior；不得临时放宽。

randrw 读、写方向分别要求 `B/A >=0.944`（沿用 03-8 的 ±5.56% 安全带），只作为 P1 安全门。randrw 不通过不推翻 randwrite 修复，但必须显式标红并阻止生产替换。

### 7.6 最终映射

| 条件 | 状态 |
|---|---|
| B 修复门 + B/A randwrite 非劣 + randrw 双方向非劣 | `PASS-B-V131-PERF-NONINFERIOR` |
| B 修复门通过，但任一非劣门失败 | `PASS-B-V131-FIXES-BUT-INFERIOR` |
| S/A 鉴别门有效，但 B 修复门失败 | `FAIL-B-V131-NO-RECOVERY` |
| S 不塌或 A 阳性门失败 | `INVALID-ENVIRONMENT-NONDISCRIMINATING` |
| 六位置未完整完成 | `PARTIAL-TIMEBOX` |

---

## 八、条件性 B 完整性冒烟

### 8.1 启动条件

只有同时满足才执行：

- 状态暂定为 `PASS-B-V131-PERF-NONINFERIOR`；
- 当前时间不晚于 07:15；
- health、objects、主挂载身份正常；
- 用户已授权创建/删除精确任务目录；
- 预计能在 08:30 前完成 write + verify + remount verify + 收尾。

### 8.2 精确范围

只使用：

```text
/mnt/juicefs-v01/test_dir/v01-integrity-$RUN_ID
```

realpath 必须位于该目录后才允许删除。禁止清空 `test_dir`，禁止 glob 命中父目录。

### 8.3 流程

1. 用 B 二进制挂载，冻结身份；
2. 16 job × 1 GiB，bs=256K，在各自文件写入 fio verify pattern；
3. `--verify=crc32c --verify_fatal=1 --do_verify=1`，保存完整输出和 rc；
4. sync/fsync，优雅卸载；
5. 仍用同一 B binary 新挂载；
6. `verify_only` 再读验，保存完整输出和 rc；
7. 只删除该精确自建目录；
8. 执行预授权的一遍 gc + compact cooldown；
9. 保存前后对象、health 和主挂载身份。

任一 verify 错误立即状态 `DATA-INTEGRITY-FAIL`，禁止重写文件后重试覆盖证据。

---

## 九、自治修复、重试与无人值守规则

### 9.1 GLM 可以自主解决

- bash 语法、变量引用、路径、工具发现、结果 parser 和采集脚本错误；
- v1.3 测试接口适配；
- 构建依赖/环境路径，但不能修改依赖版本或 go.mod；
- SSH 短暂断线后的只读重连与状态确认；
- 结果打包/manifest 错误，只要不修改已冻结原始日志。

每次修复必须记录：时间、症状、旧/新脚本 SHA、修改 diff、为何不改变实验变量、旧 attempt 路径和新 attempt 路径。

### 9.2 GLM 不能自主解决

- 改 B production 语义、A patch、测试矩阵、阈值、fio 参数、挂载参数或顺序；
- 放宽 ns/B 门、对象门、health 门或时间窗口；
- destroy/format、pool/PG/CRUSH 修改、配置 set、重启 OSD/TiKV/主机；
- 杀未知进程、触碰业务挂载或系统 JuiceFS binary；
- 因环境不健康而清理别人数据或继续跑；
- 创建/推送 commit、issue 或 PR。

### 9.3 attempt 上限

- 本地 port/build/unit：最多两个正式 attempt；
- 远端性能：最多两个正式 attempt，但只有首个在负载启动前因纯 runner bug 退出时才允许第二次；
- 一旦某个正式 attempt 已产生有效 fio 数据，不得原地修改脚本后接着补行；保留为 partial，后续使用新 OUT。

### 9.4 监控

21:00–09:00 每 30 分钟唤醒一次；预计 10 分钟内结束的步骤可缩短到 2–10 分钟。每次保存：

- 时间、当前 phase/arm/mount/round；
- 精确 PID、日志尾部、health、objects、主挂载身份；
- 预计剩余时间。

不得只依赖进程存在；必须同时看 DONE/STOP marker 和 rc sidecar。

---

## 十、交付物

### 10.1 本地包

```text
$OUT_LOCAL/
  input/
  src/{S,A,B}/
  patches/
  binaries/
  diffs/
  logs/
  rc/
  meta/
  results-correctness.tsv
  commands.sh
  adaptations.tsv
  SHA256SUMS
```

禁止归档 Go cache、完整 `.git`、构建 cache 或秘密。

### 10.2 远端包

```text
$REMOTE_OUT/
  preflight/
  binaries/
  mounts/
  gate/
  runs/<label>/<item>/<round>/
  metrics/
  health/
  objects/
  integrity/                 # 条件性
  results-raw.tsv
  results-mechanical.tsv
  commands.sh
  adaptations.tsv
  final-status.txt
  SHA256SUMS
```

每个 run 必须包含 fio 全文、128 个 bw logs、start-ns、rc、环境和实例证据。archive 用唯一成员清单生成，清单必须排序去重，并分别比较 expected、tar listing、extract、manifest；重复成员直接失败。

### 10.3 原始执行报告

写入：

```text
/home/lilingfeng/demo/production/prod-deploy/debug/juicefs-03-8-flush-race-community/report/V01-execution-$RUN_ID.md
```

报告必须分开写：

1. GLM 机械状态；
2. 技术原始结果；
3. 是否完整完成两个 block；
4. 每个 arm/mount 的 ns/B、重挂次数、PID/hash；
5. 每轮 raw 带宽来源路径；
6. 所有异常、修复和 partial attempt；
7. 明确“等待 Codex 复算，未授权生产替换或社区写入”。

---

## 十一、通用注意事项与红线汇总

1. 每个 fio 前必须 health、四节点 drop_caches、实例和对象数检查。
2. 所有写轮后必须一遍 gc、compact cooldown，并轮询三指标；禁止用 OSD restart 替代。
3. 复用已铺布局，禁止 fresh volume、create-on-open、format 或 destroy。
4. 全部 per-job bw log 必须保留；禁止单个 log × jobs，禁止只用 fio 汇总。
5. randrw 读写分报；两轮取 mount-level 中位，不挑轮。
6. 每个 remount 都是重新抽档；必须 ns/B 门和唯一 label。
7. `/mnt/juicefs`、`/usr/local/bin/juicefs`、WekaIO、BeeGFS、K8s、NIC/RoCE/MTU/md0 均为红线。
8. 不记录密码、token、完整带认证信息的 URL；报告和 archive 执行秘密扫描。
9. 不因“无人值守”扩大权限。安全/环境 STOP 后可以转做本地任务，但不能擅自修生产状态。
10. 最后对照所有 skill 做合规自查；任一不符必须标注对结论的影响。

---

## 十二、GLM 最终回复模板

```text
V01 状态：<七个允许状态之一>
本地 OUT / archive / SHA256：
远端 OUT / archive / SHA256：
base/eaf/A/B port/B binary SHA256：
正确性矩阵：S/A/B 各列实际行数和异常数
性能完成度：block1 / block2 / integrity
S/A/B randwrite 机械值及 raw 来源：
B/A randwrite 比值：
randrw R/W 比值：
主挂载 before/after：
health、objects 起止与峰值：
所有 attempt、修复和偏差：
未执行项及原因：
声明：未做生产替换、未做社区写入，等待 Codex 从 raw log 复算。
```
