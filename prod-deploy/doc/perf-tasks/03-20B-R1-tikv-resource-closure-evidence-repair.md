# 03-20B-R1 任务书：TiKV 资源闭环证据修复复跑

## 一、任务定位

```text
03-20B 原始数据
  ├─ 机制方向：共享 NVMe 上的 compaction 与同步 KV/WAL/Raft 竞争
  ├─ device 覆盖仅 45%--47.5%，host 仅 72.5%--75%
  ├─ TiKV metrics 三个窗口仅 7/8 scrape
  ├─ Raft role 的 mount source/leaf 为空
  └─ 缺 coverage、skill check 和实际执行脚本全文
                         ↓
03-20B-R1：只修证据链，完全相同 B256 复跑一次  ← 本任务
                         ↓
分析方按预注册组合证据作唯一分支判断
  ├─ 复现共享盘竞争 → SHARED_NVME_SYNC_IO_WALL，关闭参数盲调
  └─ 未复现          → 保持 MECHANISM_PARTIAL，补客户端分段插桩
```

本任务不是新的性能探索，也不是参数实验。它只用一次与 03-20B 完全相同的 B256 arm，修复采样覆盖、设备映射和可追溯性硬缺口。

GLM 负责机械执行、STOP、归档和报告原始事实；不得根据现场曲线选择参数，不得自动补跑。资源归因由 GPT 在报告回传后完成。

---

## 二、为什么必须先做 R1

03-20B 按 256 个 per-job BW log 重算：

| 窗口 | BW mean (MiB/s) |
|---|---:|
| W1 `[15,55)` | 4438.74 |
| W2 `[55,95)` | 3516.52 |
| W3 `[95,135)` | 1834.42 |
| W4 `[135,175)` | 1663.30 |

`W4/W1=0.375`，正式窗 2863.24 MiB/s，仅为 6250 MiB/s 目标的 45.81%。三 TiKV 节点同时出现：

- NVMe 写 await、`aqu-sz`、IO PSI 上升；
- compaction/pending 与物理盘写流量上升；
- storage write、Raft commit、apply wait 延迟上升约 3.6--5.5 倍；
- `rocksdb:low` 单线程平均 CPU 不超过约 10.4%；
- W3/W4 uploader 远低于 150。

这已足以否定“先加 compaction worker”与“先调 max-uploads”，但 03-20B 没达到任务书自己的覆盖率和逐 role 设备映射硬门。为了保证架构结论可复核，必须用一次无新变量复跑补证，不能把不合规证据直接升级为正式结论。

---

## 三、唯一问题与成功条件

### 3.1 唯一问题

在相同的 B256 衰减过程中，至少构成 Raft quorum 的两个 TiKV 节点是否同时满足：

1. KV、Raft、WAL 与 compaction 映射到同一真实 leaf device；
2. W3/W4 相对 W1 持续高 busy，写 await/queue 或 IO PSI 显著升高；
3. foreground storage write/WAL/Raft 与 compaction I/O 同期存在；
4. RocksDB worker CPU、TiKV/客户端 CPU 和客户端上传并发没有先到顶；
5. 上述证据的正式窗口覆盖率全部过门。

### 3.2 执行成功

“脚本执行成功”必须同时满足：

- 只运行一个 B256 arm，fio rc=0，恰有 256 个 BW log；
- 挂载 PID/starttime 全程一致；
- preflight 120 秒 coverage/labels PASS；
- 正式 W1--W4 coverage 全部 PASS；
- 三节点 KV/Raft/WAL 九个 role 均解析到 mount source、major:minor、logical 和 leaf device；
- 无 sampler structured error/launcher stderr；
- final reset 回基点；
- 只做优雅卸载且成功；
- 实际执行脚本、校验器、remote helper、任务书全文及完整 MD5 在归档中。

任何一项失败均需归档，但不得用于正式资源归因，也不得在同一 RUN_ID 或新 RUN_ID 自动补跑。

---

## 四、冻结变量

| 项 | 冻结值 |
|---|---|
| arm | 仅 `D-B256` 一个 arm |
| jobfile | B0，MD5 `3b43b01ed2c4033ed42ad52bddc77c2f` |
| 文件布局 | 384 个既有文件；三组各 128 个；禁止新增/删除/layout |
| 并发与 inode | 256 job / 256 inode |
| fio | randwrite、256 KiB、iodepth=64、runtime=180s、既定 seed |
| JuiceFS 二进制 | `/tmp/juicefs-03-8`，MD5 `de93563f11a5ff3bd94dd25a4e0283b1` |
| 挂载参数 | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K` |
| Ceph 客户端变量 | 进程私有 conf，`ms_async_op_threads=8` |
| reset | 沿用 03-19/03-20A/03-20B 冻结 reset |
| 正式窗 | `15..175s`；W1/W2/W3/W4 各 40 秒 |
| 目标 | 6250 MiB/s，必须同时报告正式窗值与稳定性 |

### 4.1 本任务禁止

- 禁止修改 JuiceFS、TiKV、PD、Ceph、OSD、内核、网卡、NVMe sysfs 配置；
- 禁止重启 TiKV/PD/OSD，禁止 remount 作为修复手段；
- 禁止新增 inode、文件、layout，禁止预写探针；
- 禁止第二 arm、自动补跑或失败后换 RUN_ID 重来；
- 禁止 `pkill -f`、`killall`、`fuser -k`、模式匹配 kill；
- 禁止 kill JuiceFS mount PID；
- 禁止 lazy/force unmount，包括 `umount -l/-f`；
- 禁止因 OSD parser、设备映射或指标缺失而退化成固定等待/猜测；
- 禁止用 fio summary 冒充正式窗口；
- 禁止 GLM 根据单个 `%util`、pending 或 latency 写根因结论。

若 `/mnt/juicefs` 在脚本启动时已经挂载，脚本必须在不触碰该挂载的情况下 STOP。由用户决定如何处理外部状态。

---

## 五、配套脚本

| 文件 | 作用 |
|---|---|
| `scripts/FULLBASELINE/debug/t60-tikv-resource-closure-r1.sh` | 唯一执行入口、门禁、单 arm、reset、归档 |
| `scripts/FULLBASELINE/debug/t60-validate-coverage.py` | preflight/正式窗覆盖率与必需 labels 校验 |
| `scripts/FULLBASELINE/debug/t60-remote-host-sampler.sh` | 在 TiKV 节点持久 SSH 内按绝对 1 秒节拍采 host/PSI/PID I/O |
| `scripts/FULLBASELINE/debug/t56-gen-jobfiles.sh` | 生成冻结 jobfile |
| `scripts/FULLBASELINE/debug/t56-validate-jobfiles.sh` | 校验冻结 jobfile |

T60 会在开始时把前三个文件、本任务书和完整 MD5 复制进 `provenance/`。归档中缺任一文件即视为证据链失败。

---

## 六、执行前人工步骤

### 6.1 阅读并确认 skill

执行者必须通读：

- `skills/baseline-reproduction-skill.md` §2.2/§2.4/§3.3/§3.4/§3.6；
- `skills/TESTING-GUIDE.md` §1.1/§1.3/§2.2/§3.2/§5.6；
- `skills/test-commands-reference.md` §8.2--§8.4、§9、§11；
- 本任务书全文。

确认理解“只有一个正式写 arm、禁止探针、禁止 kill mount、禁止自动补跑”后，才允许设置：

```bash
export T60_SKILL_ACK=read-and-accepted
```

该变量只是执行者声明，不代替实际阅读。

### 6.2 只读离线检查

在 157 上执行：

```bash
cd /home/lilingfeng/demo/production/prod-deploy

bash -n scripts/FULLBASELINE/debug/t60-tikv-resource-closure-r1.sh
bash -n scripts/FULLBASELINE/debug/t60-remote-host-sampler.sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/FULLBASELINE/debug/t60-validate-coverage.py --help >/dev/null

bash scripts/FULLBASELINE/debug/t60-tikv-resource-closure-r1.sh --dry-run 20260824-R1
```

`--self-test` 会读取本机依赖、TiKV SSH 和 metrics endpoint，不挂载、不写负载；允许在正式执行前运行一次：

```bash
bash scripts/FULLBASELINE/debug/t60-tikv-resource-closure-r1.sh --self-test
```

若 self-test 有任何 `MISSING/FAIL`，STOP 回传；禁止边跑正式 arm 边修。

---

## 七、脚本门禁和执行流程

### 7.1 Phase 0：环境与可追溯性

脚本必须：

1. 验证 JuiceFS 二进制、系统 Ceph conf 和 B0 jobfile 完整 MD5；
2. 验证 Ceph `HEALTH_OK`、至少 6 个 OSD up；
3. 验证 `/mnt/juicefs` 未挂载；已挂载则 S00 STOP，不自动卸载；
4. 新建唯一 OUT，OUT 已存在则 STOP；
5. 复制实际执行的 T60、validator、remote helper、任务书到 `provenance/` 并记录 MD5；
6. 创建进程私有 Ceph conf，不修改 `/etc/ceph/ceph.conf`；
7. 挂载后冻结 PID、starttime、exe MD5、mount 参数和私有 conf；
8. 全量 stat 384 个文件，验证三组各 128 个、每个恰为既定 1 GiB；禁止 spot check。

### 7.2 Phase 1：逐 role 设备映射

每个 TiKV 节点均需：

1. 从 `/config` 和 cmdline 解析 KV data dir、RaftDB path、RocksDB WAL dir；
2. 如果配置路径尚不存在，逐级向父目录寻找最近存在路径，但必须同时保存 configured path 与 resolved probe；
3. 用 `findmnt -T` 得到 mount target/source/major:minor；
4. 用 `lsblk -s` 从 logical source 展开到全部真实 leaf disk；
5. 输出 `device/device-map.tsv`，九个 role 行均不得为空；
6. 保存每个 leaf 的 scheduler、`nr_requests`、`read_ahead_kb`、rotational，只读不修改。

任一 role 无法映射，S04 STOP，禁止根据目录层级现场手填 `/dev/nvme1n1`。

### 7.3 Phase 2：指标 exposition 硬门

三个节点分别保存完整 exposition，并逐节点证明以下 CPU 与 I/O labels 均存在：

- `rocksdb:low`；
- `rocksdb:high`；
- raftstore；
- apply。

同时必须存在 pending、compaction flow、WAL sync、Raft commit、storage async write 和 process CPU 等资源主指标。缺一类即 STOP。

### 7.4 Phase 3：13 个 sampler 与 120 秒预检

应恰有 13 个登记 PID/PGID：

- client runtime、client host：2；
- 三节点独立 TiKV metrics：3；
- 三节点持久 iostat：3；
- 三节点持久 host/PSI/PID I/O：3；
- Ceph、pool：2。

关键修复：

- device 不再每个样本重建 SSH，而是在一个持久会话中持续运行 `iostat -y -x -d 1`；
- host 不再把多行 `/proc` 文本塞进一个字段，而是远端按绝对 1 秒 deadline 输出一行纯数值 TSV；
- TiKV metrics 三节点并行，各自按固定 5 秒 deadline，禁止顺序 curl 后再 sleep 5；
- heartbeat 只在成功写入可解析样本后更新；
- 任何 stream 退出或 scrape 失败写 `*.errors.tsv` 并让 sampler 退出，由主看门 STOP。

120 秒后必须调用 validator，不能只按文件行数判断：

| 类别 | 门槛 |
|---|---|
| device/leaf | coverage ≥95%，最大相邻 gap ≤2s |
| host | coverage ≥95%，最大相邻 gap ≤2s |
| TiKV metrics/thread | coverage ≥90%，最大 gap ≤6s，且每个有效 scrape 含全部核心指标/线程池 |
| client runtime/host | coverage ≥95%，最大 gap ≤2s |
| errors | structured errors 和 launcher stderr 均为 0 行 |

预检失败必须在 fio 前 STOP。

### 7.5 Phase 4：冻结 reset

沿用已验证 reset：

1. 只向 6 个登记 OSD 发 compact；
2. 使用实查 `compact_running`、`compact_queue_len`、`kv_sync_lat.avgtime` 轮询 cooldown；禁止 key 缺失时固定 sleep 降级；
3. 执行一次既定 `juicefs gc --compact`；
4. 三次对象数收敛且回到 soft gate；
5. TiKV 全 CF pending 总和归零；
6. 全量 stat 384 个文件；
7. 四节点 drop caches；
8. 60 秒 quiet 后通过 idle gate。

### 7.6 Phase 5：唯一正式 arm

```bash
RUN_ID=$(date +%Y%m%d-%H%M%S)
export T60_SKILL_ACK=read-and-accepted
bash scripts/FULLBASELINE/debug/t60-tikv-resource-closure-r1.sh "$RUN_ID"
```

禁止在 tmux 中另开第二份，禁止重复敲命令。执行期间只观察 wrapper log，不运行额外 fio、gc、compact、性能探针或采样命令。

fio 只能由登记 PGID 启动。STOP 时主脚本只向该 PGID 发 SIGINT；60 秒仍存活才发 SIGTERM；再等待 60 秒仍不退出时，为避免失控写负载继续破坏环境，才允许向**同一个已登记 fio PGID** 发 SIGKILL并将本轮判为 S10 无效。禁止模式匹配 kill。

### 7.7 Phase 6：正式覆盖率硬门

fio 结束后、sampler 停止前，validator 按 fio start epoch 固定计算：

- W1 `[15,55)`；
- W2 `[55,95)`；
- W3 `[95,135)`；
- W4 `[135,175)`。

每个 40 秒窗：

- 每 host/leaf 至少 38 个有效 1 秒 device 区间；
- 每 host 至少 38 个有效 host 样本；
- 每 host 必须达到 TiKV metrics/thread ≥90% 且最大 gap ≤6 秒；
- client runtime/host ≥95%；
- 任一 structured error/launcher stderr 使整个资源归因 FAIL。

失败写 S11，但仍继续 final reset、优雅 cleanup 和归档；不得补跑。

### 7.8 Phase 7：final reset、指纹与 cleanup

1. 执行相同 final reset；失败写 S12，测量可单独保存但任务不算完整成功；
2. 再读原 PID 的 starttime 和 exe，必须与 pre 一致；
3. 停止登记的 13 个 sampler 精确 PGID；
4. 只依次尝试 JuiceFS 自带 umount、`fusermount3 -u`、`fusermount -u`、普通 `umount`；
5. 全部失败则保留挂载、写 S12 并归档，禁止 kill/lazy/force；
6. 写 `skill-check-post.txt`，记录 single arm、配置/restart/layout、kill、coverage、reset、cleanup 状态。

脚本中途异常也必须由 EXIT trap 停止登记 sampler、只尝试优雅卸载本任务创建的挂载，并生成 `-ABORT.tar.gz`。外部既有挂载不在 trap 的处理范围。

---

## 八、STOP 条件

| 编号 | 条件 | 处理 |
|---|---|---|
| S00 | 启动时已有 `/mnt/juicefs` mount | 不触碰挂载，STOP/归档 |
| S01 | 二进制、Ceph conf、B0 MD5 不一致 | fio 前 STOP |
| S02 | Ceph 非 HEALTH_OK、OSD up 不足 | fio 前 STOP |
| S03 | 384 文件布局/指纹不一致 | fio 前 STOP |
| S04 | 任一 KV/Raft/WAL role 无法解析 leaf | fio 前 STOP |
| S05 | OSD cooldown key/值不可解析 | fio 前 STOP |
| S06 | 必需 TiKV/client 指标或线程 label 缺失 | fio 前 STOP |
| S07 | pool objects 超过 hard limit | 写 STOP，终止精确 fio PGID |
| S08 | 120 秒 coverage/labels/errors 未过门 | fio 前 STOP |
| S09 | mount PID/starttime 变化 | 终止精确 fio PGID；本轮无效 |
| S10 | fio rc 非 0、BW log 非 256、mount/sampler 异常 | 本轮无效，继续 final reset/归档 |
| S11 | 正式任一 coverage/gap/errors 未过门 | 资源归因无效；禁止补跑 |
| S12 | final reset 或优雅卸载失败 | cleanup FAIL；保留现场并归档 |
| S13 | 配置、restart、remount、layout、第二 arm、broad/mount kill | 全任务无效 |

任何 STOP 必须保存 epoch、编号、phase、触发值。禁止改变量后在同一 RUN_ID 继续。

---

## 九、回传产物

归档至少包含：

```text
wrapper.log
STOP.txt                         # 若触发
phase.tsv
skill-check-pre.txt
skill-check-post.txt
coverage.tsv
coverage.log
preflight/coverage.tsv
preflight/coverage.log
provenance/* + MD5SUMS
fingerprint/{pre,post}.txt
device/device-map.tsv
device/<ip>/{tikv-config.json,cmdline.txt,lsblk.txt,map-*.tsv,leaf-devices.txt,sysfs-*.txt}
samplers/*.pid
samplers/*.heartbeat
samplers/*.errors.tsv
samplers/*.launcher.stderr
samplers/tikv-device-*.tsv
samplers/tikv-host-*.tsv
samplers/tikv-metrics-*.tsv
samplers/client-runtime.tsv
samplers/client-host.tsv
samplers/ceph.tsv
samplers/pool.tsv
arm/B0.fio
arm/jobfile.md5
arm/fio.{stdout,stderr,rc,pid}
arm/bw/*.log                     # 恰 256 个
reset/{preload,final}/...
files/{pre,pre-arm,post}.tsv
metrics-full/*
MANIFEST.md5
```

归档命名：

```text
/tmp/production/opencode-t3.20b-r1-<RUN_ID>.tar.gz
/tmp/production/opencode-t3.20b-r1-<RUN_ID>.tar.gz.md5
```

中途 STOP 则文件名带 `-ABORT`。

GLM 回传：完整归档路径、完整 MD5、脚本退出码、是否存在 STOP、fio rc/BW log 数、preflight/formal coverage 失败行数、mount pre/post PID/starttime、final reset 和 graceful cleanup 状态。

---

## 十、报告要求与预注册判定

报告落点：

```text
doc/perf-report/03-20B-R1-tikv-resource-closure-evidence-repair-<YYYYMMDD>.md
```

GLM 报告只写环境、偏离、门禁、原始结果和产物位置，不得现场写“应该加 worker/调 max-uploads”。

分析方固定使用：

- 256 per-job BW log 按相对时间对齐求和；
- device 使用真实 leaf 的区间 iostat；
- IO PSI 用 total 差分/墙钟；
- thread CPU 用同 `name+tid` 的 `Δcpu_seconds/Δwall_seconds`，分节点、线程池报告；
- thread I/O 用同 `name+tid+io` 差分；
- TiKV/Raft latency 用同 labels 的 `Δsum/Δcount`；
- 先分 host/device/CF/thread pool，再给 cluster 聚合；
- “显著上升”必须给绝对值、W4/W1 倍数并至少两个连续区间，不以单点判断。

### 唯一分支规则

| 组合证据 | 正式结论 | 后续 |
|---|---|---|
| 至少两个 quorum 节点持续高 busy，W3/W4 await/queue 或 IO PSI 相对 W1 上升；foreground WAL/Raft 与 compaction I/O 同期；worker/CPU 未先到顶 | `SHARED_NVME_SYNC_IO_WALL` | 关闭 worker、uploader、inode 参数盲调；输出物理隔离 Raft/WAL 与 KV compaction、增加独立 NVMe TiKV 节点/分摊 region、低尾延迟设备等架构建议 |
| 资源组合未复现，且正式 coverage 全过门 | `MECHANISM_PARTIAL` | 补客户端 inode queue/lock/retry/transaction 分段插桩；不增加 inode |
| 任一覆盖率、映射、稳定性硬门失败 | `EVIDENCE_INVALID` | 只报告失败原因；是否重做必须由用户另行授权 |

即便 uploader 在 W1 触顶，只要 W3/W4 未持续触顶，就不得重开 `max-uploads` 分支。即便 pending 上升，只要 worker CPU 不满且设备队列/PSI 已升高，就不得直接增加 compaction worker。

---

## 十一、交付检查表

- [ ] 任务书全文已读，`T60_SKILL_ACK` 由执行者主动设置
- [ ] 三个配套脚本离线检查通过
- [ ] 启动时没有外部既有 mount
- [ ] 只有一个 B256 arm
- [ ] 九个 KV/Raft/WAL role 均有完整 leaf 映射
- [ ] 13 个 sampler PID/PGID 完整
- [ ] 120 秒 preflight coverage/labels PASS
- [ ] W1--W4 正式 coverage 全 PASS
- [ ] fio rc=0，BW logs=256
- [ ] pre/post mount PID/starttime 一致
- [ ] final reset 回基点
- [ ] 仅优雅卸载，无 mount/broad kill
- [ ] provenance 与完整 MD5 入包
- [ ] 失败未自动补跑
- [ ] 报告只写事实，等待分析方归因
