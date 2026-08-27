# 03-22 任务书：TiKV RAM block 存储隔离 A/B（冻结 seed 修订版）

## 日期与状态

- 日期：2026-08-26
- 面向：GLM 执行；GPT/用户分阶段签收
- 当前正式 RUN_ID：`20260825-163811`
- 当前进度：R01--R04 及 G01--G04 已闭环；R05 正式 fio 失败，R06--R08 未启动，当前 RUN_ID 按硬门判为 `EVIDENCE_INVALID`；G05 abort seed destroy、post-abort、临时集群停止以及六组 RAM storage 逐节点销毁均已闭环
- 当前动作：✅ `t64-finalize.sh <RUN_ID> invalid`、archive 持久化、GPT 独立复算和正式报告均已完成；03-22 环境工作关闭，禁止重跑 R05、启动 R06 或重建 RAM storage
- 已确认故障：B 的 32 GiB WAL/Raft 文件系统跨实例保留 R02/R03 目录，R05 启动前仅余约 6--9 GiB，正式写入后达到 94%--98%，触发 TiKV `AlmostFull`、事务延迟和 fio 超时
- 协议变化：废止“每个 arm 新 format + 新 layout + destroy”；改为“一个 immutable seed layout + 每轮 fresh TiKV restore + metadata clone + 轮后 fresh-seed GC 回归”
- 正式报告：`doc/perf-report/03-22-tikv-ram-block-storage-isolation-ab-20260826.md`
- 持久化归档：`results/prod-stage03-raw-20260826/opencode-t3.22-20260825-163811.tar.gz`，SHA-256 `1352878807325128fa3a07ac9325b74c89119ea24cbfab9f6e420fbc50096929`

> 承接 `03-18`--`03-21`：256 inode randwrite 已进入“客户端 inode 队列 + 同步 TiKV 事务延迟 + TiKV 前台提交/compaction 共用本地设备”的主因链。03-22 只回答块设备隔离是否能稳定改善该链路，不测试其他参数。

---

## 一、目标与推断边界

唯一因果问题：在相同主机、相同 JuiceFS/TiKV 配置、相同 Ceph 数据面、相同 256-inode randwrite 和相同起始文件布局下，B（KV 与 WAL+Raft 分盘）能否稳定优于 A（KV/WAL/Raft 共盘）。

同时报告：

1. B 四轮中位数是否达到 `6250 MiB/s`；
2. B/A 四个时间邻近配对的提升及方向一致性；
3. CV、`W4/W1`、TiKV 提交延迟、loop queue/util 的改善；
4. 若仍未达 6250，从单 inode/同步事务延迟、TiKV 本地状态和 Ceph 数据面量化剩余架构缺口。

RAM block 只证明 block queue/文件系统/worker 路径隔离的因果方向，不等于真实 NVMe 的介质延迟、持久性或生产验收。A/B 仍共享 CPU、NUMA、内存控制器和 6 OSD Ceph pool。

### 1.1 跨阶段基线与后续可选 C 臂

03-22 的最终分析不能只比较 A/B，还必须把原生产 TiKV 共享 NVMe 的同口径 B256 历史结果作为工程基线 H。历史正式窗约为 `2828--2959 MiB/s`，中心约 `2880 MiB/s`，且典型 `W4/W1` 约 `0.36--0.44`。比较分三层，禁止混写因果含义：

| 比较 | 可回答的问题 | 推断等级 |
|---|---|---|
| H→A | fresh TiKV、RAM 介质及临时集群起始状态这一组合是否改善原集群 | 跨阶段工程对照，不能拆分单因素 |
| A→B | RAM 条件下把 KV 与 WAL+Raft 分到独立 block/filesystem 是否有收益 | 当前任务唯一随机化因果效应 |
| H→B | 整体 RAM PoC 相对原集群改善多少、离 6250 还有多远 | 跨阶段工程对照 |

为拆分 H→A 的组合效应，后续可另立 C：**fresh TiKV + 原三节点共享 NVMe**。推荐在原 `/mnt/jfs-tikv` 上使用精确作用域、预分配的 NVMe-backed loop/ext4，使 C 与 A 都保持 `file→loop→ext4→KV/WAL/Raft 共盘`，主要只改变 backing medium。H→C 观察 fresh/历史 RocksDB 状态差异，C→A 观察 NVMe/RAM 介质差异。

C 不属于当前 RUN_ID，当前任务书只登记、不授权执行。它必须另立任务书和新 RUN_ID，并同时满足：用户批准的维护窗口；生产 TiKV 与 C 不并行；每节点有可预分配容量且预留生产安全余量；先完成只读 inventory 和逐条 sudo plan；禁止 sparse file 无上限侵占生产文件系统；失败后可精确卸载、detach 和删除唯一 backing file；生产数据目录、配置、systemd 和挂载全程不改。任一条件不满足，就保留“fresh 状态与介质贡献未拆分”的边界，不执行 C。

---

## 二、为什么改成冻结 seed

历史稳定性证据表明：fresh volume + layout 的跨轮 CV 约 `9.5%--13%`，已接近本任务预注册的 `15%` 隔离效应门；固定 layout 的读侧 CV 仅约 `0.6%--2.2%`。ABBA/BAAB 能抵消慢时间漂移，不能消除每轮独立 layout lottery。继续每轮 layout 会让“布局抽样差异”和“存储隔离效果”同量级，难以判断调优是否有效。

新协议只做一次正式数据 layout，并解决两个不能忽略的问题：

1. **不能把同一个 TiKV 元数据状态连续跑八轮。** 每轮仍新建 PD/TiKV data dir 和 cluster token，并把同一 seed dump 加载到空 metadata namespace；RocksDB/LSM 逻辑状态不跨 arm 复用。R05 证明“新目录”并不等于“本地存储起点相同”：旧实例目录若留在同一 ext4，会累积占用空间并触发 TiKV 容量门。任何后续新 RUN 必须在每个实例前后证明本地存储使用量回到冻结基线，或为每个实例重建等价的空本地文件系统；只检查 active TiKV pending compaction 不足以证明 fresh。
2. **不能让 randwrite 直接覆盖 seed 文件。** 覆盖会使旧 slice 失去引用并被删除，下一次仅恢复 metadata 会引用已丢失对象。因此 seed dump 里只保留 immutable `/seed_layout`；每轮通过 `juicefs clone -p` 元数据级克隆为 `/test_dir`。正式写只触碰 clone，seed source 始终持有原 slice 引用。

每轮结束后丢弃该轮已变异的 TiKV 状态，再启动一个独立 GC metadata 集群，重新加载原始 seed dump。此时 seed 对象是 valid，该轮新对象是 leaked；先 check-only，再经精确授权执行 `gc --delete`，并证明 valid/compacted 计数与 seed 基线一致、leaked/pending/skipped 为 0、pool 回到 seed 基线，才可启动下一 arm。

禁止用 `--max-deletes 0` 或 `--no-bgjob` 保护 seed；它们会改变 randwrite 的删除/后台工作路径，污染绝对带宽和 TiKV 负载。clone 的引用计数才是 seed 保护机制。

---

## 三、冻结变量

### 3.1 A/B 唯一变量

| 臂 | 每个 TiKV 节点 | TiKV 路径 |
|---|---|---|
| A | 1 × 128 GiB tmpfs-backed loop/ext4 | KV、RocksDB WAL、Raft Engine 共用一个 block device |
| B | 1 × 96 GiB KV loop/ext4 + 1 × 32 GiB log loop/ext4 | KV 与 WAL+Raft 位于两个独立 block device |

两臂都有相同 8 GiB PD tmpfs。每节点 `MemAvailable >= 384 GiB`。当前 RUN_ID 的六组 storage 已通过 create/verify/plan-destroy，修订协议不得重建或换 RUN_ID，除非 GPT/用户明确判定当前 RUN_ID 失效。

### 3.2 临时集群

- 节点：`10.20.1.150/151/152`；端口 PD `12379/12380`、TiKV `30160/30180`
- 一次只运行一个临时集群；旧实例 TiKV→PD 全部 TERM 停止后才启动下一个
- 每实例使用新的 data dir、cluster token 和 metadata URL
- 不注册 systemd，不写 `/opt`、`/etc`、生产 `/mnt/jfs-tikv`
- `SEED-*`、`RESTORE-*`、`GC-*`、`G01..G08` 和 `R01..R08` 都是独立实例

### 3.3 数据面与 workload

| 项 | 冻结值 |
|---|---|
| Ceph | 同一 `juicefs-data` pool、同一 6 OSD，不创建独立 Ceph 集群 |
| 正式 seed | 256 个文件，每文件 1 GiB；仅预写正式 B0 会访问的 256×512 MiB extent，共 128 GiB active data |
| 每 arm 工作集 | 从 `/seed_layout` metadata clone 到 `/test_dir`；禁止重新 layout、copy 数据或运行时建文件 |
| fio | randwrite、256 KiB、256 job/256 inode、iodepth 64、runtime 180s、slot+1 固定 seed |
| mount | `--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；Ceph client `ms_async_op_threads=8` |
| 正式窗 | 实际 I/O 起点后的 `[15,175)`；W1--W4 各 40 秒 |
| 统计 | fio BW 行按“从上一时间戳到本时间戳的区间平均速率”解释，依区间与自然秒的重叠时长做 1 秒加权重采样；256 job 逐秒求和后取正式窗中位数 |

正式顺序不变：

```text
R01=A, R02=B, R03=B, R04=A,
R05=B, R06=A, R07=A, R08=B
```

对应轮后 GC 实例固定为 `G01..G08`，全部放在 A storage 上；GC 是未计时的复位步骤，不是 A/B 测量臂。

---

## 四、保护对象与绝对红线

1. 生产 PD/TiKV PID/starttime/exe、systemd、配置 SHA、`/mnt/jfs-tikv` 必须全程不变。
2. 禁止任何 NVMe 写命令；禁止 `wipefs`、`blkdiscard`、`losetup -D`、`dd` 写设备、分区/LVM/RAID、递归 chown/chmod。
3. 禁止 pool delete/create、改 PG/CRUSH、OSD restart、systemctl stop/restart、reboot、全局 drop_caches。
4. 禁止 lazy/force umount、SIGKILL、`pkill/killall/fuser -k`、`rm -rf`、自动 trap cleanup。
5. `gc --delete` 和 `juicefs destroy` 是独立破坏性步骤：必须先有只读 plan/identity/UUID/session/prefix 证据，再使用本实例精确 token；不能合并授权。
6. 任何失败都保留现场，停止当前职责层；不得修完脚本后在同一正式矩阵静默继续。

本任务允许的 sudo 写操作仍只有：当前 RUN_ID storage 生命周期中的精确 tmpfs/loop/ext4 create/destroy，以及 `sudo ceph tell osd.1..6 compact`。seed/restore/clone/GC/volume destroy 本身不使用 sudo。当前六组 storage 已全部精确销毁，现阶段禁止再次 create。

---

## 五、脚本职责

| 脚本 | 单一职责 |
|---|---|
| `t64-gate0-offline.sh` | 离线语法、负向守卫、job/analyzer/GC parser self-test；不访问环境 |
| `t64-seed-interface-gate.sh` | 只读核对 pinned JuiceFS 的 dump/load/clone/gc CLI |
| `t64-cluster-orchestrator.sh` | 三节点临时集群串行 render/start/verify/TERM stop、生产指纹 |
| `t64-seed-volume.sh` | seed format/mount、一次 layout、graceful umount、metadata dump；不 restore/GC/delete |
| `t64-restore-volume.sh` | 向空 namespace load seed、mount、clone、verify、umount；支持经精确授权只读采纳“clone 已成功但旧合同后置校验失败”的现场，以及对证据失败 arm 做带独立 token 的 graceful `abort-umount`；不 format/layout/GC/destroy |
| `t64-gc-return.sh` | fresh-seed check-only GC、单独授权 delete、正常 G08 seed destroy；无效RUN只能使用独立 token 的 `abort-final-destroy`，并永久写入 `EVIDENCE_INVALID` 标记 |
| `t64-reset-gates.sh` | OSD compact/cooldown、TiKV pending gate、seed/pool return gate；正常完成与无效RUN提前销毁使用不同 action/token/marker |
| `t64-run-arm.sh` | 单个已准备 arm 的 fio 和 sampler；不做生命周期操作 |
| `t64-finalize.sh` | 最终只读复核、证据归档 |

旧 `t64-volume-layout.sh` 只保留历史 smoke/旧 canary 的精确收尾；它现在必须拒绝 `R01..R08` 的 format/layout/destroy。不得再用它创建正式卷。

---

## 六、恢复执行前：暂停、同步和 Gate

GLM 先回传旧 `ARM-CANARY-A2` 当前是否仍在运行、mount/cluster/volume state、是否已经自然结束。未得到用户指令前：

- 不启动 seed canary；
- 不启动 R01；
- 不 umount/destroy/stop 活现场；
- 不销毁 RUN_ID `20260825-163811` 的 A/B RAM storage。

GPT 发布新 SHA 后，GLM 把完整 t64 脚本同步到 157，逐个核对 SHA，然后执行：

```bash
cd /tmp/production/prod-deploy
bash scripts/FULLBASELINE/debug/t64-gate0-offline.sh
bash scripts/FULLBASELINE/debug/t64-seed-interface-gate.sh 20260825-163811
```

两门都 PASS 后仍暂停。interface gate 只运行 `version`/`--help`，不会连接 TiKV/Ceph、不会影响旧测试。

旧 A2 若已完整结束，应按它原 state 的标准 graceful umount/destroy/TERM 流程单独授权清理；若失败则先修旧职责层。只有确认无任何本 RUN_ID JuiceFS mount process、无临时端口占用，才进入下节。

---

## 七、小数据 seed/clone/GC canary（正式 seed 前必须完成）

canary 使用独立 volume name `jfs-t64-<RUN_ID>-seed-canary`，只写一个 16 MiB extent、逻辑文件 32 MiB，不进入正式结果。

### 7.1 SEED-CANARY：format、微型 layout、reset、dump

依次启动 A 侧 `SEED-CANARY` 三节点集群并 GLOBAL_VERIFY_PASS。然后分步：

```bash
export T64_SEED_FORMAT_AUTH="03-22-seed-format-${RUN_ID}-SEED-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-seed-volume.sh format-mount "$RUN_ID" A SEED-CANARY
unset T64_SEED_FORMAT_AUTH

bash scripts/FULLBASELINE/debug/t64-seed-volume.sh layout "$RUN_ID" A SEED-CANARY

export T64_RESET_AUTH="03-22-reset-${RUN_ID}-SEED-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-reset-gates.sh prepare "$RUN_ID" A SEED-CANARY
unset T64_RESET_AUTH

bash scripts/FULLBASELINE/debug/t64-seed-volume.sh umount "$RUN_ID" A SEED-CANARY
```

等待至少 65 秒，再单独授权 dump：

```bash
export T64_SEED_DUMP_AUTH="03-22-seed-dump-${RUN_ID}-SEED-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-seed-volume.sh dump "$RUN_ID" A SEED-CANARY
unset T64_SEED_DUMP_AUTH
```

必须看到 dump mode `600`、SHA、UUID/Name 固定、`Sessions=[]`、GC baseline 中 leaked/pending/skipped=0。随后 TiKV→PD 停止 `SEED-CANARY`。

### 7.2 RESTORE-CANARY：load、mount、clone、COW

启动 fresh A `RESTORE-CANARY`，验证后：

```bash
export T64_RESTORE_AUTH="03-22-restore-${RUN_ID}-RESTORE-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh load "$RUN_ID" A RESTORE-CANARY
unset T64_RESTORE_AUTH

export T64_RESTORE_MOUNT_AUTH="03-22-restore-mount-${RUN_ID}-RESTORE-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh mount "$RUN_ID" A RESTORE-CANARY
unset T64_RESTORE_MOUNT_AUTH

bash scripts/FULLBASELINE/debug/t64-restore-volume.sh clone "$RUN_ID" A RESTORE-CANARY
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh cow-canary "$RUN_ID" A RESTORE-CANARY
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh umount "$RUN_ID" A RESTORE-CANARY
```

COW gate 必须证明 source 首块 SHA 不变、target 首块 SHA 改变。等待 65 秒后 TiKV→PD 停止。

### 7.3 GC-CANARY：plan、delete、return、最终 destroy

启动 fresh A `GC-CANARY`，只执行 restore load，**禁止 mount**：

```bash
export T64_RESTORE_AUTH="03-22-restore-${RUN_ID}-GC-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh load "$RUN_ID" A GC-CANARY
unset T64_RESTORE_AUTH

bash scripts/FULLBASELINE/debug/t64-gc-return.sh inspect "$RUN_ID" A GC-CANARY
```

回传 `gc-inspect.tsv` 和 `gc-delete.plan`，暂停。只有 leaked>0、pending/delslices/delfiles/skipped=0，且 UUID/Name/session/mount 守卫全过，才单独授权：

```bash
export T64_GC_DELETE_AUTH="03-22-gc-delete-${RUN_ID}-GC-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-gc-return.sh delete "$RUN_ID" A GC-CANARY
unset T64_GC_DELETE_AUTH

export T64_RESET_AUTH="03-22-reset-${RUN_ID}-GC-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-reset-gates.sh seed-return "$RUN_ID" A GC-CANARY
unset T64_RESET_AUTH
```

必须证明 post-GC leaked/pending/skipped=0，valid/compacted 与 canary seed baseline 精确相同，pool objects 三次 spread≤4096 且回到 seed ±8192。

然后再次单独授权只销毁 canary seed：

```bash
export T64_SEED_DESTROY_AUTH="03-22-seed-destroy-${RUN_ID}-GC-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-gc-return.sh final-destroy "$RUN_ID" A GC-CANARY
unset T64_SEED_DESTROY_AUTH

export T64_RESET_AUTH="03-22-reset-${RUN_ID}-GC-CANARY-A"
bash scripts/FULLBASELINE/debug/t64-reset-gates.sh post-final-destroy "$RUN_ID" A GC-CANARY
unset T64_RESET_AUTH
```

最后停止 GC-CANARY。任一 canary gate 失败，不建正式 seed。

---

## 八、一次正式 layout 和 seed 冻结

### 8.1 建 SEED-FORMAL

启动 fresh A `SEED-FORMAL` 后，执行与 §7.1 相同的五个职责步骤，只把实例改为 `SEED-FORMAL`：format-mount → layout → reset prepare → graceful umount → 等待 65 秒 → dump。

这是本 RUN_ID **唯一一次正式 128 GiB layout**。`seed.tsv` 必须冻结：

- volume Name、UUID；
- dump 路径、mode 600、SHA-256；
- 256 个 source path/size/inode 及 manifest SHA；
- 每个文件正式 active extent 首个 256 KiB 的 content-anchor SHA；
- pinned JuiceFS MD5；
- seed GC 的 valid/compacted/leaked/pending/skipped；
- pool pre-format 和 pool-seed 三元组。

dump PASS 后停止 SEED-FORMAL。禁止 destroy，seed data objects 保留到 G08。

### 8.2 正式 seed restore/clone preflight（0 次正式写）

启动 A `RESTORE-PREFLIGHT`：load → mount → clone → verify → umount → 等待 65 秒 → stop。该步骤把 clone 后 256 个 target 的 path/size 和参考 inode 映射记录到 `formal-clone-contract.tsv`。跨 fresh namespace 时，`juicefs clone -p` 可因并行分配顺序不同而改变“路径→数字 inode”的对应关系，因此正式硬合同不是逐路径 inode 数值相等，而是：path/size 精确相同、256 个 target inode 全部唯一、与 256 个 source inode 零重叠、source/target content anchors 精确相同。数字 inode 只作为本轮身份快照，在同一 arm 的 fio 前后必须保持不变。

然后启动 A `GC-PREFLIGHT`：load seed → `gc-return inspect`。它没有执行数据写，预期 leaked=0；若非 0 则协议无效。无需、也禁止 `gc --delete`。运行 `reset-gates seed-return` 证明 pool 仍为 seed baseline，再停止。

只有正式 seed 和 preflight 都 PASS，才允许 R01。

---

## 九、8 个正式 arm

严格按 R01--R08 顺序逐轮完成“arm + 对应 Gxx”，前一 Gxx 未完成不得启动下一 R。

### 9.1 arm 集群和固定工作集

以 R01/A 为例：

```bash
# orchestrator: render -> start-pd -> start-tikv -> verify

export T64_RESTORE_AUTH="03-22-restore-${RUN_ID}-R01-A"
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh load "$RUN_ID" A R01
unset T64_RESTORE_AUTH

export T64_RESTORE_MOUNT_AUTH="03-22-restore-mount-${RUN_ID}-R01-A"
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh mount "$RUN_ID" A R01
unset T64_RESTORE_MOUNT_AUTH

bash scripts/FULLBASELINE/debug/t64-restore-volume.sh clone "$RUN_ID" A R01
```

clone 必须与 preflight 的 `formal-clone-contract.tsv` 在 path/size 上精确相同；target 必须是 256 个唯一 inode 且与 source inode 集合零重叠。source manifest 和 256 个 content anchors 必须仍等于 frozen seed，clone 初始 anchors 也必须相同。禁止把跨 namespace 的逐路径 inode 数字不同判为工作集漂移；也禁止 `format`、`layout`、数据 copy。

若 clone 命令已经 rc=0、stdout/stderr 为空、source/target path/size/anchor 全过，但旧版“逐路径 inode 数字相等”后置门失败，禁止删除 target 或重跑 clone。先保留现场并升级脚本，再使用精确 `T64_CLONE_ADOPT_AUTH=03-22-clone-adopt-<RUN_ID>-<INSTANCE>-<A|B>` 执行 `adopt-clone-state`。该动作只重读 source/target、核对 256 唯一且零重叠的 inode 集合并生成 jobfile/marker，不写 JuiceFS 数据；必须留下 `CLONE_ADOPT_PASS`、`clone-adopt.tsv` 和 `clone-inode-invariants.tsv`。

### 9.2 稳态门和唯一正式 fio

```bash
export T64_RESET_AUTH="03-22-reset-${RUN_ID}-R01-A"
bash scripts/FULLBASELINE/debug/t64-reset-gates.sh prepare "$RUN_ID" A R01
unset T64_RESET_AUTH

export T64_FIO_AUTH="03-22-fio-${RUN_ID}-R01-A"
bash scripts/FULLBASELINE/debug/t64-run-arm.sh "$RUN_ID" A R01
unset T64_FIO_AUTH
```

必须满足 OSD 三指标全绿、TiKV pending compaction 连续三次 0、quiet 60 秒、HEALTH_OK。run-arm 必须确认正式写前后 seed source path/size/inode 和 256 个 content anchors 不变、clone target path/size/inode 不变，并产出 256 logs、完整 sampler 和固定窗分析。

### 9.3 graceful 收尾和 fresh-seed GC

```bash
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh umount "$RUN_ID" A R01
# 等待 >=65s，orchestrator stop-tikv -> stop-pd

# 启动 fresh A G01，GLOBAL_VERIFY_PASS
export T64_RESTORE_AUTH="03-22-restore-${RUN_ID}-G01-A"
bash scripts/FULLBASELINE/debug/t64-restore-volume.sh load "$RUN_ID" A G01
unset T64_RESTORE_AUTH

bash scripts/FULLBASELINE/debug/t64-gc-return.sh inspect "$RUN_ID" A G01
```

检查 plan 后逐轮使用精确 `T64_GC_DELETE_AUTH` 执行 delete，再用本 Gxx 的 `T64_RESET_AUTH` 执行 `seed-return`。完成后 stop Gxx。R02 才能开始。

G08 的 delete + seed-return 完成后，不再保留 seed：使用独立 `T64_SEED_DESTROY_AUTH` 执行 `final-destroy`，再 `post-final-destroy` 证明 pool 回到正式 seed 的 pre-format 基线，最后停止 G08。

---

## 十、硬门和停止规则

| Gate | 条件 | 失败动作 |
|---|---|---|
| 生产保护 | 生产 PID/start/exe、systemd、mount、config SHA 不变 | 事故级停止 |
| Seed identity | dump SHA、UUID、Name、256 source manifest/content anchors 固定 | 禁止 restore/R01 |
| Clone identity | source 与 seed 相同；target 与 preflight path/size/inode 相同 | 当前 RUN_ID 正式矩阵无效 |
| Fresh metadata | load 前 namespace 为空；每实例新 PD/TiKV data dir/token | 停止，不复用旧 TiKV |
| 稳态 | OSD cooldown、TiKV pending 3×0、quiet、HEALTH_OK | 不跑 fio |
| fio/coverage | rc=0/err=0、256 logs、I/O 起点估计、coverage 达标 | EVIDENCE_INVALID |
| GC inspect | fresh seed、零 session/零 mount；pending/delslices/delfiles/skipped=0 | 禁止 delete |
| GC delete | inspect leaked>0 + 精确 token；post leaked/pending/skipped=0，valid/compacted=seed | 不启动下一 arm |
| Pool return | 三次 spread≤4096，回 seed ±8192 | 不启动下一 arm |
| 内存/资源 | 每节点 MemAvailable≥384GiB，无 foreign fio/OOM | 停止并保留现场 |
| 本地容量起点 | 不存在未核销的旧实例占用；KV/log/shared 各自 used/available 等于冻结基线且满足本轮写入与 reserve headroom | 不启动实例；当前 RUN_ID 失效 |

`JFS_GC_SKIPPEDTIME=0` 仅用于已证明“前一 mount 已 graceful 结束≥65秒、前一集群已停、当前 fresh seed 无 session/无 mount”的 GC 专用实例，使刚生成的 leaked objects 不受默认一小时 mtime 跳过。它不能在活跃卷、生产卷或 arm metadata 上使用。

---

## 十一、判定

固定时间配对：`R02/R01`、`R03/R04`、`R05/R06`、`R08/R07`。

| 条件 | 分类 |
|---|---|
| B/A 中位提升≥15%，至少 3/4 配对同向、两个 block 同向；B 至少 3/4 `CV≤10%` 且 `W4/W1≥0.90` | `ISOLATION_EFFECT_CONFIRMED` |
| 上述成立且 B 四点中位数≥6250 | `RAM_POC_TARGET_REACHED`，进入真实 NVMe 验证 |
| 隔离成立但 B<6250 | `PARTIAL_CAUSE_ONLY`，量化剩余架构缺口 |
| B/A<15% 或方向不足 3/4，证据有效 | `BLOCK_ISOLATION_NOT_SUFFICIENT` |
| 较快但稳定性不达标 | `UNSTABLE_DIRECTIONAL_ONLY` |
| 任一硬门或缺臂 | `EVIDENCE_INVALID`，不追加样本补结论 |

一次正式 seed 能最大化 A/B 因果识别，但 6250 的绝对结论条件于该 layout draw。若 B 中位数距 6250 小于 5%，或 B/A 中位数距 15% 小于 3 个百分点，03-22 只能写 borderline，需另开新 RUN_ID/第二 seed 做确认；若远离边界，不追加第二 seed。

---

## 十二、最终 teardown 与交付

G08 已 final-destroy、post-final-destroy，所有临时集群均 stop 后，重新 plan 当前 RUN_ID 的六组 RAM storage。按 `B152→B151→B150→A152→A151→A150` 每节点独立授权精确销毁；禁止批量授权。

若正式 arm 在 G01--G07 之间失败，禁止伪造后续 arm/Gxx 或调用正常 G08 路径。只能在对应 Gxx 已完成 inspect→独立授权 delete→postcheck→seed-return，且失败 arm、无分析结果、umount epoch、零 session/零 mount 和 frozen seed identity 均得到证明后，使用独立 `T64_ABORT_SEED_DESTROY_AUTH` 执行 `abort-final-destroy`。随后必须以独立 `T64_ABORT_RESET_AUTH` 执行 `post-abort-final-destroy`，在证据中永久保留 `RUN_INVALID.tsv`、`ABORT_SEED_DESTROY_PASS` 和 `POST_ABORT_FINAL_DESTROY_PASS`；这些 marker 不能满足正常完成判定。

最后运行 `t64-finalize.sh <RUN_ID> normal|invalid`。正常完成使用 `normal`；正式矩阵因硬门失败并按 abort 路径闭环时只能使用 `invalid`，禁止用正常归档掩盖无效 RUN。正常模式必须看到：

- R01--R08 全部分析和 graceful umount；
- G01--G08 全部 GC/pool-return；
- formal seed bundle、clone contract、G08 seed destroy/final pool return；
- 无 t64 process/mount/loop，六份 storage destroy audit；
- 生产指纹不变、Ceph HEALTH_OK；
- 完整 `SHA256SUMS`、archive 和外层 SHA。

`invalid` 模式必须交叉核对 `RUN_INVALID.tsv`、`seed.destroyed.tsv mode=abort-invalid-run`、失败 arm 与同编号 Gxx、`ABORT_SEED_DESTROY_PASS`、`POST_ABORT_FINAL_DESTROY_PASS`；失败前各 arm 必须有分析和卸载证据，失败 arm 必须保留 sampler failure 且不得有 `arm-analysis.json`，失败后不得启动任何正式 arm。它只收集截至失败点的实例证据，并同样要求六份 storage destroyed audit、生产指纹不变、Ceph `HEALTH_OK`、内外层 SHA；产出的 `FINALIZE_PASS mode=invalid` 只表示证据与清理归档完整，不改变 `EVIDENCE_INVALID` 分类。

报告写入：

```text
doc/perf-report/03-22-tikv-ram-block-storage-isolation-ab-202608xx.md
```

报告必须同时列出每 arm 原值、四个时间配对、两个 block、CV/W4/W1、TiKV/loop 时间线、seed/clone/GC 证据和所有协议偏离。GLM 不提前下架构结论；GPT 独立复算后再同步 03 计划书和 results-table。

### 最终红线一句话

**正式阶段只 layout 一次；每轮写 clone、不写 seed；每轮用 fresh seed metadata 先 inspect、后独立授权 GC，回到 seed 基线才继续。任何身份、session、source、GC 或 pool 门不满足，立即停止，不得用手工清理把失败改成 PASS。**
