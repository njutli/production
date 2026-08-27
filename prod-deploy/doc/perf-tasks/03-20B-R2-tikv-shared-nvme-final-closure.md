# 03-20B-R2 任务书：TiKV 共享 NVMe 架构瓶颈最终证据闭环

## 日期：2026-08-23

---

## 一、任务定位

03-20B 与 03-20B-R1 已两次观察到相同方向：B256 randwrite 在运行中明显衰减，TiKV compaction 写入、物理 NVMe 写负载和 WAL/Raft/transaction 延迟同步上升，而 compaction worker、客户端 uploader 和 CPU 均未在最差窗口先到顶。

R1 的方向性数据有价值，但正式证据无效，具体缺口包括：

- 三节点 Raft role 的 leaf device 为空；
- iostat 固定列截断，未保存 `aqu-sz/%util`；
- host sampler 的 PSI 始终为 `-1`；
- validator 把一轮 exposition 的 metric 行数当成 scrape 数；
- W3 两节点实际只有 7/8 个唯一 scrape；
- sampler 未全部退出便生成 manifest，内部有 8 个 MD5 不一致；
- 缺 skill check 和任务书 provenance；
- 三次换 RUN_ID 执行以及脚本外 kill mount 触发 S13。

因此本任务只做一件事：在完全相同的 B256 arm 上，用已经通过离线 Gate 0 的采集与归档链，完成一次最终的正式资源归因。

这不是新参数实验，不寻找更高的单次 fio summary，也不允许 GLM 根据现场曲线改变方案。

```text
R1：强方向 + 硬门失败
             ↓
R2 Gate 0：离线修脚本、fixture、自测，不接触环境
             ↓
R2：用户授权后只执行一次冻结 B256
             ↓
  ├─ 全硬门通过且组合证据复现 → SHARED_NVME_SYNC_IO_WALL，关闭 03 参数调优
  ├─ 全硬门通过但组合不复现   → MECHANISM_PARTIAL，补客户端分段插桩
  └─ 任一硬门失败              → EVIDENCE_INVALID，STOP，不自动再跑
```

---

## 二、唯一问题

在相同的 256 inode randwrite 衰减过程中，至少构成 Raft quorum 的两个 TiKV 节点是否同时满足：

1. active Raft Engine、RocksDB WAL、KV SST/compaction 映射到同一真实 leaf NVMe；
2. W2--W4 的设备 busy 持续较高，且 `w_await/aqu-sz` 相对 W1 上升；
3. foreground storage/WAL/Raft 与 compaction I/O 同期存在；
4. storage write、Raft append/commit、apply wait、scheduler prewrite/commit 延迟同步上升；
5. `rocksdb:low` worker、TiKV 进程 CPU、客户端 uploader/CPU 没有先到顶。

若组合证据成立，则目标带宽无法稳定达到 6250 MiB/s 的主要原因是当前三 TiKV 节点把 latency-sensitive 同步日志/事务路径与吞吐型 KV compaction 放在同一物理 NVMe 上；这属于架构资源隔离问题，不是继续增加 inode 或客户端/worker 参数可以解决的问题。

---

## 三、冻结变量

| 项 | 冻结值 |
|---|---|
| 正式 arm | 仅 `D-B256` 一个 |
| jobfile | B0，MD5 `3b43b01ed2c4033ed42ad52bddc77c2f` |
| 文件布局 | 384 个既有 1 GiB 文件，三组各 128；禁止新增、删除或 layout |
| fio | randwrite、256 KiB、256 job/256 inode、iodepth=64、runtime=180s、固定 seed |
| JuiceFS | `/tmp/juicefs-03-8`，MD5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph client | 进程私有 conf，`ms_async_op_threads=8` |
| 集群配置 | JuiceFS/TiKV/PD/Ceph/OSD/内核/NVMe/网卡均不修改 |
| reset | 沿用 03-19/03-20A/03-20B 冻结 reset |
| 正式窗 | `[15,175)`；W1/W2/W3/W4 均为半开 40 秒窗 |
| 目标 | 稳定有效带宽 6250 MiB/s，同时报告均值、CV、W4/W1 |

### 3.1 明确禁止

- 禁止第二 arm、自动补跑、换 RUN_ID 重来；
- 禁止在正式执行前做 fio、预写、layout 或性能探针；
- 禁止修改或重启 JuiceFS、TiKV、PD、Ceph、OSD；
- 禁止 remount 作为修复手段；
- 禁止 `pkill -f`、`killall`、`fuser -k` 或任何模式匹配 kill；
- 禁止 kill JuiceFS mount PID；
- 禁止 lazy/force unmount，包括 `umount -l/-f`；
- 禁止手工删除 attempt marker、STOP 或失败归档以规避单次限制；
- 禁止因字段缺失而使用默认设备、固定 sleep 或猜测值继续；
- 禁止使用 fio summary 代替正式窗口；
- 禁止 GLM 在报告中写最终根因或选择下一参数。

发现 `/mnt/juicefs` 已挂载、存在其他 fio、已有 R2 attempt marker 或 lock 时，必须原样 STOP。不得清理环境后继续。

---

## 四、交付脚本

| 文件 | 作用 |
|---|---|
| `scripts/FULLBASELINE/debug/t61-tikv-resource-closure-r2.sh` | 唯一执行入口、单次锁、门禁、reset、唯一 fio arm、精确清理和归档 |
| `scripts/FULLBASELINE/debug/t61-remote-resource-sampler.sh` | 远端只读 device/host sampler；按 iostat header 解析并固定字段 |
| `scripts/FULLBASELINE/debug/t61-local-sampler.sh` | 13 路本地 sampler/SSH bridge 的固定入口，避免嵌套命令字符串 |
| `scripts/FULLBASELINE/debug/t61-validate-evidence.py` | 唯一 epoch、半开窗口、逐字段/逐 label 严格验证 |
| `scripts/FULLBASELINE/debug/t61-gate0-offline.sh` | 纯离线语法、fixture、安全规则与负向回归测试 |
| `scripts/FULLBASELINE/debug/t56-gen-jobfiles.sh` | 生成冻结 B0 jobfile |
| `scripts/FULLBASELINE/debug/t56-validate-jobfiles.sh` | 校验 job 数、inode、offset、size、seed 和禁止创建文件 |

---

## 五、Gate 0：由分析方离线完成

Gate 0 不执行 SSH、curl、mount、Ceph、fio，不读写测试文件：

```bash
cd /home/lilingfeng/demo/production/prod-deploy
bash scripts/FULLBASELINE/debug/t61-tikv-resource-closure-r2.sh --self-test
```

必须看到：

```text
t61 remote sampler self-test: PASS
t61 local sampler self-test: PASS
t61 validator self-test: PASS
03-20B-R2 Gate 0 offline tests: PASS
```

本任务书交付前，分析方已实际执行上述 Gate 0 并得到全 PASS；同时用新 validator 对 R1 原始包做负向回归，能够在 1 秒内明确拦截 W3 节点 151/152 的 `7/8` scrape、空 Raft leaf、旧 device/host schema 和非空 errors。GLM 可以在执行前再次运行纯离线 Gate 0，但不得据此生成 attempt marker，也不得用任何在线探针替代主脚本内的 120 秒预检。

Gate 0 覆盖以下 R1 回归点：

1. 用含 discard/flush 字段的 iostat fixture 验证按 header 取得 `rkB/s`、`wkB/s`、`r_await`、`w_await`、`aqu-sz`、`%util`；缺列必须失败。
2. host schema 中 IO some/full PSI、CPU some PSI、TiKV PID stat/io 均为非负 counter；`-1` fixture 必须失败。
3. metric 每 scrape 多行只能计为一个 epoch，相邻窗口使用半开边界。
4. 40 秒窗只有 7/8 个 metric epoch 必须失败，不能四舍五入为 90%。
5. fio 非零退出码不能被 `|| true` 覆盖。
6. 主脚本不得包含 broad/mount kill、lazy/force unmount 或自动 retry。
7. sampler 精确 PGID、停后 wait、文件静止检查和 `md5sum -c MANIFEST.md5` 必须存在。

任何一项失败，分析方修脚本后重新执行纯离线 Gate 0；Gate 0 未全 PASS 时，不得把脚本交给 GLM 上环境。

---

## 六、正式执行前人工确认

GLM 必须完整阅读：

- `skills/baseline-reproduction-skill.md` §2.2/§2.4/§3.3/§3.4/§3.6；
- `skills/TESTING-GUIDE.md` §1.1/§1.3/§2.2/§3.2/§5.6；
- `skills/test-commands-reference.md` §8.2--§8.4、§9、§11；
- 本任务书全文。

理解“唯一正式写 arm、已有 mount 原样 STOP、禁止 kill mount、禁止自动补跑”后，等待用户明确授权本次 R2。未获得授权不得设置 `T61_USER_AUTH`。

授权后只设置一次：

```bash
export T61_SKILL_ACK=read-and-accepted
export T61_USER_AUTH=03-20B-R2-single-run
RUN_ID=$(date +%Y%m%d-%H%M%S)
bash scripts/FULLBASELINE/debug/t61-tikv-resource-closure-r2.sh "$RUN_ID"
```

主脚本在 `/tmp/production/03-20B-R2-ATTEMPT-<RUN_ID>.started` 创建不可复用的 attempt 记录。只要任一 R2 attempt marker 已存在，脚本就拒绝新运行；失败后是否重新设计任务必须由用户另行决定，GLM 无权删除 marker 或修改脚本绕过。

执行期间只允许观察本进程 stdout 或该 RUN_ID 的 `wrapper.log`。不得另开 fio、gc、compact、curl/iostat 探针或第二份 T61。

---

## 七、脚本流程与硬门

### 7.1 S00--S03：环境、挂载与布局

1. 验证 binary、系统 Ceph conf、任务书和所有配套脚本存在；
2. 验证 `/mnt/juicefs` 未挂载、无 foreign fio、无旧 attempt、无并发 lock；
3. 验证 `HEALTH_OK`、恰为冻结的 6 个 OSD、`/tmp` 可用空间不少于 4 GiB；
4. 创建进程私有 Ceph conf，不修改系统 conf；
5. 只挂载一次，冻结 mount PID、starttime、exe MD5、mount options 和 private conf MD5；
6. 全量 stat 384 个文件，要求三组各 128、每个恰为 1 GiB；
7. 生成并校验 B0，禁止创建、截断和越界。

若主脚本启动时已有 mount，S00 必须在不触碰该 mount 的情况下 STOP。EXIT trap 只允许优雅卸载本任务已经创建的 mount。

### 7.2 S04：active role 到真实 leaf 的映射

每个 TiKV 节点从 `/config` 明确读取：

- KV：`storage.data-dir`；
- WAL：`rocksdb.wal-dir`，只有配置为空时才按 TiKV 语义回落到 KV data dir；
- Raft：若 `raft-engine.enable=true`，必须使用 `raft-engine.dir`；否则才使用 `raftstore.raftdb-path`。

对每个 role：

1. `findmnt -T` 若因末级目录不存在失败，逐级向父目录解析，保存实际解析到的 mount target；
2. 保存 source、fstype、major:minor；
3. `lsblk -s` 展开到真实 `TYPE=disk` leaf；
4. 保存 leaf scheduler、`nr_requests`、`read_ahead_kb`、rotational；
5. `device-map.tsv` 必须恰有 3 节点 × 3 role = 9 行，8 个字段均非空。

禁止使用固定 `/dev/nvme1n1` fallback。任一 role/leaf 为空，S04 在 fio 前 STOP。

### 7.3 S05--S08：reset key、13 sampler 与 120 秒严格预检

只读解析 6 个登记 OSD 的 `compact_running`、`compact_queue_len`、`kv_sync_lat.avgtime`；任一 key/值无法解析，不得退化为固定等待。

必须恰有 13 个独立 sampler PGID：

- client runtime、client host：2；
- TiKV metrics：3；
- TiKV device：3；
- TiKV host/PSI/PID：3；
- Ceph、pool：2。

关键采集要求：

- device：一个持久 SSH 流，按 iostat header 输出固定 8 列 `epoch/dev/rkB/s/wkB/s/r_await/w_await/aqu-sz/%util`；
- host：一个持久 SSH 流，固定 20 列，包含 CPU、IO some/full PSI、CPU some PSI、TiKV PID CPU/I/O/starttime；
- TiKV metrics：三节点并行，按绝对 5 秒 deadline，每个 epoch 必须含全部预注册 metric 和 `rocksdb:low/high`、raftstore、apply labels；
- heartbeat 只在完整样本成功写入后推进；SSH/curl/parser 失败必须让 sampler 退出；
- pool 超过 8,000,000 objects 只写 S07，由主脚本终止登记 fio PGID，禁止 sampler 自行模式匹配 kill。

120 秒 validator 硬门：

| 流 | 门槛 |
|---|---|
| device/host/client | 唯一有效 epoch ≥95%，max gap ≤2s |
| TiKV metrics | 唯一完整 scrape ≥90%，max gap ≤6s；120 秒至少 22/24 |
| pool/Ceph | 达到各自固定周期期望，且 objects/health/PG 有效 |
| fields/labels | 每个计入 coverage 的 epoch 必须 schema 和必需 labels 全部有效 |
| errors | 所有 `*.errors.tsv`、launcher stderr 为 0 字节 |

预检失败必须在 fio 前 S08 STOP。

### 7.4 冻结 reset

preload 与 final 使用完全相同流程：

1. 只向启动时登记的 6 个 OSD 发 compact；
2. 轮询实查 cooldown key，不能固定 sleep 代替；
3. 执行一次既定 `juicefs gc --compact`；
4. 三次对象数 spread ≤128，且每次处于 `2,434,672 ±128`；
5. post-GC compact/cooldown；
6. 三 TiKV 节点所有 CF pending 总和归零；
7. 全量 stat 384 个 1 GiB 文件；
8. 四节点 drop caches；
9. quiet 60 秒后，连续三次通过 mount identity、HEALTH、OSD cooldown、TiKV pending 和客户端 CPU idle ≥70%。

任何 reset 门失败必须 STOP；禁止减少等待、放宽对象门或跳过 final reset。

### 7.5 唯一正式 arm

正式 fio 使用 setsid 创建并登记唯一 PGID。主脚本每 2 秒检查：

- 原 mount PID/starttime/exe；
- 13 sampler 存活和 heartbeat；
- pool watchdog STOP；
- fio PID/PGID。

异常时只向登记 fio PGID 发 SIGINT，60 秒仍存活才发 SIGTERM，再等待 60 秒仍存活才允许对同一 PGID 发 SIGKILL，并将本轮判为 S10 无效。

fio 退出码必须直接保存；必须同时满足 rc=0、256 个 BW log、stdout `err=0`、未强杀。

### 7.6 正式 coverage

validator 以 fio start epoch 计算半开窗口：

- W1 `[15,55)`；
- W2 `[55,95)`；
- W3 `[95,135)`；
- W4 `[135,175)`。

每窗 device/host/client 至少 38/40 个有效 epoch；metrics 因 7/8=87.5%，所以每窗必须 8/8；device 每个 epoch 必须覆盖该节点 device-map 中所有唯一 leaf。

任一字段、label、coverage、gap、errors、health、objects 失败即 S11，资源归因无效；禁止补跑。

### 7.7 配置、重启、清理与归档

1. 比较三节点 `/config` pre/post 完整内容；
2. 比较三 TiKV PID/starttime/exe pre/post；
3. 比较系统 Ceph conf MD5、mount PID/starttime/exe；
4. 执行完整 final reset；
5. 对 13 个登记 sampler PGID 精确 TERM 并逐个 wait；超时只可强杀对应 sampler PGID，并写 S12；
6. 只尝试 JuiceFS umount、fusermount3、fusermount、普通 umount；全部失败则保留 mount 并写 S12；
7. sampler 停止后验证所有文件 size/mtime 静止；
8. 以相对路径生成 `MANIFEST.md5`，在打包前执行 `md5sum -c`；
9. 最后生成 tar.gz、外层 MD5 和独立 manifest verify 输出。

禁止在生成 manifest 后继续写 OUT。外层 tar.gz MD5 一致但内部 manifest 失败，仍为 S14/EVIDENCE_INVALID。

---

## 八、STOP 条件

| 编号 | 条件 | 处理 |
|---|---|---|
| S00 | 已有 mount/fio/attempt/lock | 不触碰外部状态，STOP |
| S01 | 文件/MD5/jobfile/空间失败 | fio 前 STOP |
| S02 | Ceph health 或冻结 OSD 集合失败 | fio 前 STOP |
| S03 | mount/layout/size/fingerprint 失败 | STOP |
| S04 | active role path、mount、leaf 或设备属性缺失 | fio 前 STOP |
| S05 | OSD cooldown key/value 缺失 | fio 前 STOP |
| S06 | preload reset 失败 | fio 前 STOP |
| S07 | objects 超 hard limit | 终止精确 fio PGID，本轮无效 |
| S08 | sampler/120 秒预检失败 | fio 前 STOP |
| S09 | mount/sampler/process 稳定性失败 | 终止精确 fio PGID，本轮无效 |
| S10 | fio rc/log/err/PGID 失败 | 本轮无效，继续 final reset/归档 |
| S11 | 正式 coverage/schema/labels/errors 失败 | 资源归因无效，不补跑 |
| S12 | final reset、sampler cleanup 或优雅卸载失败 | cleanup FAIL，保留证据/现场 |
| S13 | 配置/restart/remount/layout/第二 arm/broad 或 mount kill | 全任务无效 |
| S14 | 文件静止或内部 manifest 校验失败 | 归档无效 |

任一 STOP 都必须保存 epoch、编号和触发值。GLM 只回传，不修复后继续。

---

## 九、GLM 回传要求

GLM 不做根因判断，只报告原始事实：

1. 执行命令、唯一 RUN_ID、主脚本退出码；
2. attempt marker 路径；
3. archive、完整外层 MD5、manifest verify 是否全 PASS；
4. STOP 是否存在、全部 STOP 行；
5. fio rc、BW log 数、stdout `err=0`；
6. preflight/formal coverage 中所有 FAIL 行；
7. device-map 九行及每节点唯一 leaf；
8. mount/TiKV pre/post PID/starttime/exe 是否逐项一致；
9. preload/final reset 对象数、pending、idle gate；
10. sampler 13/13、是否使用 sampler PGID 强杀；
11. graceful unmount 是否成功，若失败确认 mount 被保留且没有 kill；
12. fio summary 只作为附录，不代替 256 BW log。

归档至少包含：

```text
attempt.started
wrapper.log
STOP.txt                         # 若触发
phase.tsv
skill-check-pre.txt
skill-check-post.txt
coverage.tsv
coverage.log
preflight/coverage.tsv
preflight/validator-output.txt
device/device-map.tsv
device/<ip>/*
samplers/*.pid
samplers/*.pgid
samplers/*.heartbeat
samplers/*.errors.tsv
samplers/*.tsv
arm/B0.fio
arm/fio.{pid,pgid,rc,stdout,stderr}
arm/bw/*.log                     # 成功时恰为 256
reset/{preload,final}/*
files/{pre,pre-arm,post}.tsv
metrics-full/*
fingerprint/*
provenance/*
MANIFEST.md5
```

---

## 十、分析方预注册判定

GLM 报告回传后，GPT 先复核全部硬门，再计算资源窗。不能跳过硬门直接看曲线。

### 10.1 组合证据计算

- fio：256 BW log 秒级聚合，报告 W1--W4 均值/CV、正式窗均值/CV、W4/W1；
- device：按 node/leaf 报告 `wkB/s`、`w_await`、`aqu-sz`、`%util` 的窗口均值和 W4/W1；
- host：IO some/full PSI delta、TiKV PID CPU/I/O；
- TiKV：compaction bytes、pending、`rocksdb:low/high` CPU/I/O、process CPU；
- foreground：storage write、Raft append/commit、apply wait、scheduler prewrite/commit 的 `Δsum/Δcount`；
- client：uploading、buffer、process CPU；
- 所有 counter 只在相邻有效 scrape 间求 delta，counter reset 的区间丢弃并报告。

### 10.2 唯一分支

| 组合证据 | 正式结论 | 后续 |
|---|---|---|
| 全硬门通过；至少两个 quorum 节点在连续两个后窗保持高 busy，且 `w_await/aqu-sz` 相对 W1 上升；foreground 与 compaction I/O 同期、同步延迟上升；worker/CPU 未先到顶 | `SHARED_NVME_SYNC_IO_WALL` | 关闭 inode、uploader、worker 参数调优；03 阶段输出架构结论 |
| 全硬门通过，但上述组合未复现 | `MECHANISM_PARTIAL` | 只补客户端 inode queue/lock/retry/transaction 分段插桩；不增加 inode |
| 任一硬门失败 | `EVIDENCE_INVALID` | 只报告失败原因；不自动 R3 |

“高 busy”不能只靠单个 `%util`：至少还要有 `w_await` 或 `aqu-sz` 上升、物理写流量与 compaction 同期、同步路径延迟上升。worker 未到顶要求 `rocksdb:low` 单线程平均 CPU 明显低于单核饱和，且 TiKV/host CPU 没有先达到 CPU 容量上限。

若正式得到 `SHARED_NVME_SYNC_IO_WALL`，03 阶段不再跑客户端参数。架构建议按优先级评估：

1. 将 RocksDB WAL/active Raft Engine 等 latency-sensitive 日志与 KV SST compaction 放到不同物理 NVMe；
2. 增加带独立 NVMe 的 TiKV 节点并重新分摊 region/leader，降低单盘 foreground+background 汇聚；
3. 使用更低 fsync/写尾延迟、持续写稳定性更好的设备；
4. 架构变更必须另立容量、故障域、迁移/回滚和 A-B-A 稳定性任务，未经授权不实施。

---

## 十一、完成标准

- [ ] 离线 Gate 0 全 PASS；
- [ ] 用户明确授权唯一一次 R2；
- [ ] 一个 RUN_ID、一个 attempt marker、一个正式 arm；
- [ ] 九个 role 全部解析到真实 leaf；
- [ ] 13 sampler 严格预检通过；
- [ ] preload reset 通过；
- [ ] fio rc=0、256 BW log、stdout err=0；
- [ ] W1--W4 唯一 epoch/schema/labels 全 PASS；
- [ ] mount/TiKV/config pre/post 一致；
- [ ] final reset 通过；
- [ ] 无 mount/broad kill，无 remount/配置/restart/layout；
- [ ] sampler 精确停止并 wait；
- [ ] 文件静止、内部 manifest 和外层 MD5 全 PASS；
- [ ] GPT 按唯一分支给出正式结论。
