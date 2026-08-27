# 03-21 任务书：TiKV 存储隔离与扩展可行性只读盘点

## 日期：2026-08-24

> 状态：任务书与采集脚本已就绪，**尚未上环境执行**
>
> 执行脚本：`scripts/FULLBASELINE/debug/t63-tikv-storage-topology-inventory.sh`
>
> 离线复算脚本：`scripts/FULLBASELINE/debug/t62-r2-offline-attribution.py`

---

## 一、任务定位

03-20B-R2 的正式协议判定为 `EVIDENCE_INVALID`：执行方用了 5 个 RUN_ID，自动 cleanup 未完成，且 256 进程的实际 timed-I/O 比脚本登记的 `fio_start` 晚约 58 秒，校正后的实际 W4 `client-host` 覆盖出现 3 秒 gap。

但成功 arm 的工程事实足够明确：

- 正式 BW 窗口为 2880.44 MiB/s，仅为 6250 目标的 46.09%，CV 44.50%，`W4/W1=0.368`；
- 三节点 KV/Raft/WAL 都落在各自唯一的 `/dev/nvme1n1`；
- 校正时间轴后，三盘从真实 W1 起就保持 94.27%--99.47% util、`aqu-sz=25.31--36.91`、`w_await=6.60--9.19ms`；
- RocksDB `rocksdb:low` 后台 I/O 与前台同步提交从 W1 起就在同一介质并存；
- W1→W4，storage write / Raft commit / scheduler prewrite 延迟约升 49%，而 TiKV CPU、worker CPU、客户端 uploader/buffer/CPU 全部下降；
- 因而增加 inode、`max-uploads` 或 compaction worker 都不再是有效方向；重复同一 B256 也不会增加架构决策信息。

本任务**不是性能复测，也不是 R3**。它只读回答下一层问题：

> 三个 TiKV 主机当前是否存在能够与 `/dev/nvme1n1` 物理隔离的健康 spare NVMe；若没有，本地介质隔离是否必须升级为新增/替换硬件或扩展 TiKV 节点？

拿到事实后，由 GPT 离线形成架构选项、容量预算和后续授权边界。本任务不迁移数据，不修改 TiKV，不验证改造后的性能。

---

## 二、唯一允许的工作范围

| 项 | 冻结要求 |
|---|---|
| 节点 | TiKV：`10.20.1.150/151/152`；采集端：157 |
| 工作负载 | **0 个 fio arm；0 个性能探针** |
| 远端状态 | 只读；不得创建远端 helper、临时文件、挂载或后台进程 |
| 采集内容 | 全块设备、NVMe/PCIe/NUMA/SMART、挂载/占用、TiKV config/metrics、PD store/hotspot、TiKV PID/start/exe/config pre/post |
| 输出 | `/tmp/production/opencode-t3.21-<RUN_ID>/` 及同名 `.tar.gz/.sha256` |
| 执行次数 | 一次授权采集；失败只回传现有现场，不自动补跑 |
| 最终判断 | GPT 离线完成；GLM 只报告事实和文件，不擅自宣布设备可清空或可迁移 |

### 2.1 明确禁止

- 禁止运行 fio、rados bench、dd、磁盘性能探针或预热；
- 禁止 mount/umount/remount、mkfs、wipefs、分区、LVM、RAID、`nvme format/sanitize`；
- 禁止修改 sysfs queue、scheduler、read-ahead、IRQ、NUMA、CPU affinity；
- 禁止修改 TiKV/PD/JuiceFS/Ceph 配置，禁止 restart/reload/kill 任一服务或进程；
- 禁止 drop cache、compact、GC、region transfer、leader transfer、balance 调整；
- 禁止递归扫描 TiKV 数据目录，例如 `du`、`find /mnt/jfs-tikv/tikv`；
- 禁止因为某设备“未挂载”就把它写成“可用 spare”。未挂载可能仍属于其他业务或保留数据，只能标成**候选，待资产所有者确认**；
- 禁止执行失败后清理 lock/output、换 RUN_ID 自动重来；
- 禁止从本任务结果推断“隔离后一定达到 6250 MiB/s”。本任务只判断改造条件，不测改造效应。

---

## 三、为什么下一步先做盘点，而不是再压一次 B256

1. **目标缺口是 2.17 倍。** 当前正式窗 2880.44 MiB/s 到 6250 MiB/s 不是局部旋钮通常能覆盖的幅度。
2. **真实 W1 已在盘墙。** 旧时间轴把 58 秒进程启动期开成了 W1，曾造成“compaction 后段才爬升”的错觉；校正后是三块盘从负载起点就高 busy、深队列。
3. **compaction 限速不是稳定解。** 限速或暂停只把回收债推到后续时间，形成依赖历史的短时高值，无法证明稳定有效带宽；增加 worker 会扩大同盘竞争。
4. **当前缺的是落地条件。** R2 只保存了工作盘的 leaf mapping，没有全主机 NVMe 清单、PCIe/NUMA failure domain、SMART、设备占用和 PD store 分布。在不知道是否有独立介质前，直接写迁移方案属于猜测。
5. **只读盘点不会引入测试波动。** 脚本只执行系统/设备查询和 HTTP metrics/config GET，不启动负载、不写远端、不碰服务状态。

---

## 四、交付文件与 Gate 0

| 文件 | 用途 |
|---|---|
| `t63-tikv-storage-topology-inventory.sh` | 唯一线上入口；只读采集、pre/post 状态自证、归档；md5 `5f092126cbc78ffb57c4c5f0079285c0` |
| `t62-r2-offline-attribution.py` | GPT 离线重算 R2 的真实 I/O 时间轴；不要求 GLM 在线执行；md5 `8241cfb3983832fe81ea35fb4961ef91` |

在 157 上、未设置授权变量时先执行纯离线检查：

```bash
cd /tmp/production/prod-deploy
bash -n scripts/FULLBASELINE/debug/t63-tikv-storage-topology-inventory.sh
bash scripts/FULLBASELINE/debug/t63-tikv-storage-topology-inventory.sh --self-test
```

预期唯一结果：

```text
t63 read-only inventory self-test: PASS
```

Gate 0 不连接远端、不创建正式 OUT、不生成 RUN_ID。若失败，停止并回传 stderr；不得改脚本后自行上线。

---

## 五、授权与唯一执行命令

GLM 必须先向用户复述以下边界并等待明确授权：

> “03-21 只读盘点三个 TiKV 节点，不运行 fio、不挂载、不改配置、不重启、不迁移数据；只生成本地证据包。若发现 foreign fio、SSH/JSON/状态门失败，只回传，不自动补跑。”

获得授权后：

```bash
cd /tmp/production/prod-deploy
export T63_USER_AUTH=03-21-read-only-inventory
RUN_ID=$(date +%Y%m%d-%H%M%S)
bash scripts/FULLBASELINE/debug/t63-tikv-storage-topology-inventory.sh "$RUN_ID"
```

禁止预先手工创建/删除脚本的 OUT、archive 或 lock。禁止为了“让结果 PASS”跳过某节点、某命令或 pre/post 比较。

---

## 六、脚本执行顺序

脚本自动完成以下步骤，GLM 不需要拆开手工执行：

1. 验证显式授权、RUN_ID、输出目录和单实例 lock；
2. 检查采集端和三 TiKV 节点不存在 foreign fio；只检查，不终止；
3. 每节点保存 TiKV `PID/starttime/exe md5/cmdline` pre；
4. 每节点采集：
   - `lsblk -b -J -O` 全设备树；
   - `findmnt -J`、`df -B1 -T`、`blkid`；
   - `/mnt/jfs-tikv`、KV、Raft Engine、WAL 的 leaf/mount/fs/free；
   - 全 NVMe sysfs 型号、序列号、firmware、PCI 路径、NUMA、sector、queue；
   - `nvme list/smart-log/id-ctrl/id-ns`（若节点安装 nvme-cli）；
   - NVMe PCIe `lspci -vv`；
   - TiKV `/config` 和完整 `/metrics` gzip；
5. 从 PD HTTP API 保存 health、stores、config；hotspot 接口存在时一并保存；
6. 再次保存三节点 TiKV config 与 process fingerprint；
7. JSON/gzip schema 自检，并逐字节比较 PID/start/exe/cmdline 和 config pre/post；
8. 输出 `result.txt`；生成相对路径 `SHA256SUMS` 并自校验；打包和生成外层 SHA-256。

远端只执行查询命令，所有文件只写到 157 的 `/tmp/production/opencode-t3.21-<RUN_ID>/`。

---

## 七、硬门与处置

| 代码 | 条件 | 处置 |
|---|---|---|
| S00 | 未授权、已有同 RUN_ID 输出/lock、采集端或任一 TiKV 节点存在 fio | 原样 STOP；不得 kill fio，不得清理后继续 |
| S01 | 任一必需 SSH/curl/PD endpoint 失败 | 记 `INVENTORY_INCOMPLETE`；保留已采内容，不得据此宣布无 spare |
| S02 | 任一 TiKV PID/start/exe/cmdline 或 config pre/post 改变 | 采集期间状态漂移，整包只作现场；不自动补跑 |
| S03 | `lsblk/findmnt/config/PD` JSON 或 metrics gzip 失败，或文件缺失 | `INVENTORY_INCOMPLETE` |
| S04 | `SHA256SUMS` 自校验或 archive SHA-256 失败 | 归档无效；只回传路径和错误 |

脚本退出码 9 表示已经形成包但存在 `INVALID.txt`；退出码 42 表示在形成完整包前 STOP。两者都禁止 GLM 自动换 RUN_ID 重试。

---

## 八、必须回传的证据

成功时至少应有：

```text
opencode-t3.21-<RUN_ID>/
├── run.txt
├── result.txt
├── SHA256SUMS
├── nodes/
│   ├── 10.20.1.150/
│   ├── 10.20.1.151/
│   └── 10.20.1.152/
│       ├── process-pre.txt / process-post.txt
│       ├── system.txt
│       ├── lsblk.json / findmnt.json / df.txt / blkid.txt
│       ├── storage-paths.txt
│       ├── nvme-sysfs.txt / nvme-cli.txt / lspci-vv.txt
│       ├── tikv-config-pre.json / tikv-config-post.json
│       └── tikv-metrics.prom.gz
├── pd/
│   ├── health.json
│   ├── stores.json
│   ├── config.json
│   └── hotspot-*.json（接口可用时）
└── provenance/
```

回传：

1. 脚本退出码、RUN_ID、`result.txt`、有无 `INVALID.txt`；
2. archive 绝对路径、字节数、`.sha256` 全文；
3. `SHA256SUMS` 条目数和 `sha256sum -c` 结果；
4. 每节点 `lsblk` 中所有顶层 disk 的 name/model/serial/size/mountpoints；
5. 当前 `/dev/nvme1n1` 的 PCIe 路径/NUMA/SMART 与任何其他 NVMe 的对应值；
6. PD stores 的 store id/address/state/region_count/leader_count/capacity/available；
7. pre/post process/config 是否逐字节一致；
8. 不做最终“可迁移”结论，等待 GPT 对原始包分析。

---

## 九、GPT 离线判读口径

### 9.1 设备只能先分成“在用、候选、不可判”，不能直接叫 spare

一个本地候选至少同时满足：

1. 是独立顶层 block device，不是 `/dev/nvme1n1` 的 partition、LVM、dm、md 或同一 controller namespace；
2. serial、PCIe 路径和 sysfs leaf 能证明与工作盘物理独立；
3. 没有 mountpoint/holder/active filesystem consumer；即便满足，本任务仍要求资产所有者确认所有权和可清空性；
4. SMART `critical_warning=0`、`media_errors=0`、available spare 不低于阈值、`percentage_used<80`；缺 nvme-cli/SMART 时只能记“健康未知”；
5. 容量至少覆盖当前用途和 30% 余量。仅按当前 `tikv_store_size_bytes` 可判断 POC 容量，不能替代生产增长/保留期规划；若迁整个 KV store，还需按 active device 容量或单独容量规划签收。

### 9.2 生产隔离要求三节点对称

只在三个 TiKV 节点都存在物理独立、健康、所有权可确认的候选设备时，才进入 `LOCAL_SPARE_CANDIDATE_ON_ALL_3`。只有一到两个节点有候选不能作为生产隔离方案，否则故障恢复和 leader/region 重平衡后会重新落回非对称延迟。

### 9.3 预注册四分支

| 原始事实 | 分支 | 下一步 |
|---|---|---|
| 三节点各有合格候选，且容量/所有权可确认 | `LOCAL_SPARE_CANDIDATE_ON_ALL_3` | 只写 WAL/Raft/KV SST 隔离迁移、回滚、故障域和验证计划；另行授权后才实施 |
| 仅一到两节点有候选 | `PARTIAL_SPARE_NOT_DEPLOYABLE` | 不做非对称迁移；评估补齐硬件或新增 TiKV 节点 |
| 三节点无独立候选 | `NO_LOCAL_SPARE` | 形成设备替换/新增节点/region 分摊的架构需求；当前硬件拓扑下停止 randwrite 参数调优 |
| 证据缺失、健康未知或采集中漂移 | `INVENTORY_INCOMPLETE` | 只说明缺口；不得自动运行 B256，也不得猜测设备可用性 |

即使进入第一分支，也只证明“有实施条件”，不证明“隔离后达到 6250”。架构变更后的性能验证必须是独立任务：单变量、明确回滚、稳定 reset、正确记录 fio timed-I/O 起点，并重新做实际窗口 coverage。

---

## 十、GLM 报告模板

报告文件建议：

```text
doc/perf-report/03-21-tikv-storage-isolation-feasibility-inventory-20260824.md
```

报告只写：

- 执行命令、RUN_ID、退出码、授权值；
- S00--S04 逐项结果；
- 每节点全设备事实表和当前 TiKV 路径映射；
- SMART/PCIe/NUMA 原始字段是否齐全；
- PD store/region/leader 分布；
- pre/post 一致性、archive/SHA-256/MANIFEST；
- 任何缺失或 permission error 的原文。

不要写：

- “未挂载，所以可以清空”；
- “有第二块盘，所以隔离后一定达标”；
- “应该直接迁移/格式化”；
- “需要再跑一次 R2/R3”；
- 未经 GPT 复算的最终架构分支。

---

## 十一、执行前检查表

- [ ] 用户明确授权 03-21 只读盘点；
- [ ] `bash -n` 与 `--self-test` PASS；
- [ ] 未修改 t63 脚本；
- [ ] 采集端和三节点无 foreign fio；
- [ ] 0 个性能 arm、0 次 mount/restart/config write；
- [ ] 三节点 pre/post process/config 齐全且一致；
- [ ] 三份 `lsblk/findmnt/config/metrics` 齐全；
- [ ] PD health/stores/config 齐全；
- [ ] `SHA256SUMS` 与 archive `.sha256` 可复核；
- [ ] 回传原始包后等待 GPT 分析，不自动追加负载。
