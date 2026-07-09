# 任务（GLM）：node2 RAID 确诊修复（perccli/OMSA）+ 全 OSD 内存盘上限评估

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-09
> 来源：`results/node2-raid-forensics-20260709/` 已坐实 **node2 是全局 IOPS 短板、墙在其物理写路径**（osd.2 迁 tmpfs 后 aio_wait 55.8ms→0.10ms、w_await 73ms→0.06ms）。用户判断"node2 RAID 卡近期降级"成立。
> **但上轮遗留两点**：① 无 perccli/storcli，**未直查 RAID 控制器 CachePolicy/BBU，病因仍是推断**；② osd.2 单迁 tmpfs 稳态并未真过 59（osd.3 仍在慢 RAID 路径上，EC 木桶未解开——上轮报的 58.97 是缓冲暂态均值，稳态仍 ~51）。
> 本任务两件事：
> **① 想办法拿到 RAID 工具（perccli64 / Dell OMSA），三节点只读取证坐实病因 → 若可改则开 WriteBack + 同口径稳态复测（看能否真过 59）。**
> **② 全 6 OSD 迁内存盘，跑全量指标，测"node2 不拖后腿时的后端稳态上限"（上限评估，非交付基线）。**

---

## 0. 关键前提与红线（GLM 请先读）
- **上轮回滚翻过车**：`bluefs-bdev-new-db` 加 tmpfs DB 后，直接删 symlink + umount → BlueFS CURRENT 损坏 → osd 起不来 → 只能 purge 重建。**本任务全 6 OSD 迁内存盘，回滚风险 ×6，必须用正确回滚法（见 §3.4）；集群无业务数据，最坏 purge 重建可接受，但每台每步必须落盘、且做完确认 6 OSD up/in + HEALTH_OK。**
- **内存盘只作"上限评估/诊断"，不是交付基线**：tmpfs 远快于任何真盘/RAID，测出的数**不能当作方案交付能力**，只用于回答"若 node2 写路径不拖后腿，后端稳态上限是多少、能否过 59"。报告须显式标注此口径。
- **稳态口径铁律**：rados/fio 均值含前 ~13s 缓冲暂态（已反复踩坑，见 `TESTING-GUIDE §5.5`）。**一切结论用稳态段（截前 30s / sec≥15）中位数，不用含缓冲的 Bandwidth 均值。**
- 三节点内存充足（~220G），可复用 `doc/perf-analysis/06_1-ramdisk-wal-db-test.md` 的方法（每 OSD **4GB** 内存盘，2GB 会 BlueFS spillover；tmpfs 不支持 O_DIRECT → 用 loop device）。
- 密码 .11=`TurboAi@303`，.13/.14=`123456`；OSD 映射 node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5；盘 sdb。
- **一切结论对账原始数据；无数据标"未取证"；不取 MAX；不手填 summary；有创操作全程 ops.log + 回滚。**

---

## 1. 阶段 D（先做）：拿到 RAID 工具，三节点只读取证

### 1.1 想办法装工具（上轮 GitHub/Broadcom 下载 0 字节，很可能是无外网）
按可行性尝试，落盘用的是哪个、怎么拿到的：
1. **Dell OMSA（首选，Dell 原生）**：`omreport storage vdisk controller=0`、`omreport storage battery` 可读 VD 缓存策略(Read/Write Policy)和 BBU 状态。若装了 OpenManage 直接用。
2. **perccli64 / storcli64**：Dell 支持站或 Broadcom 下载 `.deb`/`.rpm`；**若目标机无外网，在有网机器下好再 scp 进去**（不要在无网机反复 curl 出 0 字节）。
3. **MegaCli**：老工具，能读 LSI 3108 的 `-LDInfo -Lall -aAll`（Current Cache Policy）、`-AdpBbuCmd -aAll`（BBU）。
4. 若三者都拿不到：如实记录"工具不可得"，**阶段 E（修复）跳过**，只做阶段 F（全内存盘上限评估）。

### 1.2 三节点各只读采集（全落盘）
```bash
# OMSA 示例
sudo omreport storage vdisk controller=0    > raid-<node>-vd.txt      # ★ Write Policy = WriteBack / WriteThrough
sudo omreport storage battery controller=0  > raid-<node>-bbu.txt     # ★ BBU/电容 状态
# 或 perccli/storcli
sudo perccli64 /c0/vall show all            > raid-<node>-vd.txt
sudo perccli64 /c0/bbu show all             > raid-<node>-bbu.txt
# 或 MegaCli
sudo MegaCli -LDInfo -Lall -a0              > raid-<node>-vd.txt
sudo MegaCli -AdpBbuCmd -a0                 > raid-<node>-bbu.txt
```

### 1.3 阶段 D 判据（核心对比 node2 vs node1/node3）
一张"三节点 RAID 对比表"，明确 **node2 与 node1/3 差在哪**：
- **VD 当前写策略（Current Write Policy）**：node1/3 是否 `WriteBack`、node2 是否 `WriteThrough`？（看 **Current** 不是 Default）
- **BBU/电容**：node2 是否 `Degraded/Failed/在 Learn Cycle`，触发控制器 `No Write Cache if Bad BBU` 自动回退 WT？
- **产出**：坐实/推翻"node2 RAID WriteBack 未生效"。若三节点策略/BBU 均相同且正常 → RAID 假设被削弱，node2 慢另有原因，如实记录。

---

## 2. 阶段 E（视 D 结果·有创·可选）：修 node2 WriteBack + 同口径稳态复测

**仅当阶段 D 确诊 node2 是 WriteThrough 且可安全恢复时执行。** 落盘 + 回滚预案。
- **BBU 正常、策略是 WT** → 记录原值 → `perccli64 /c0/v0 set wrcache=WB`（或 OMSA/MegaCli 对应命令）→ 落盘改后。
- **BBU degraded** → 换电池是硬件动作（不在本任务范围）；**可临时 `ForcedWB` 仅验证**（无电池保护、掉电丢数据，本集群无业务数据可接受），**验证完立即回滚**。落盘标注"仅验证"。
- **复测**（与 `iops-wall-locate` 完全同口径）：净态三确认 → `rados bench 300 write -b 256K -t 64` → 同步采 node2 perf delta（aio_wait/kv_queued/kv_sync）+ node2/3 iostat + 客户端网卡。
- **判据**：node2 写延迟是否 73ms→~0.06ms（对齐 node1/3）；全局 IOPS 是否从 ~230 大幅上升；**稳态段中位数写带宽是否真过 59**（不看含缓冲均值）。
- **回滚**：验证完把 node2 缓存策略改回原值，确认 HEALTH_OK。

---

## 3. 阶段 F：全 6 OSD 迁内存盘 —— 全量指标上限评估

**目的**：node2（及全体）写路径不受物理盘/RAID 限制时，后端稳态上限是多少、哪些指标能过 59。**这是上限天花板，非交付基线。**

### 3.1 迁移（6 OSD 全做，复用 06_1 方法，用正确回滚法）
逐台逐 OSD：停 OSD → 建 4GB tmpfs + loop device → `ceph-bluestore-tool bluefs-bdev-new-db`（podman 容器内，挂 /dev + OSD 数据目录 + tmpfs；`CEPH_ARGS='--bluestore-block-db-size 4294967296'`）→ 起 OSD → 确认 up/in。**每个 OSD 做完确认，再做下一个；全部 6 个 up/in + HEALTH_OK 再开测。**

### 3.2 全量指标（rados 直打 juicefs-data，SSD 参数，净态三确认，稳态口径）
| 项 | 命令 | 时长 |
|----|----|----|
| 顺序/并发写 256K | `rados bench 300 write -b 256K -t 64 --no-cleanup` | 300s ×3 轮 |
| 读（顺序 seq）256K | prefill 后 `rados bench 300 seq -t 64` | ≥120s ×3 |
| 读（随机 rand）256K | `rados bench 300 rand -t 64` | 300s ×3 |
| 块大小写矩阵 | 4K/64K/256K/1M/4M write | 各 120s ×3 |
| （对照）并发扫描 256K write | t16/t64/t128 | 各 300s（看内存盘下 IOPS 墙是否随并发上移）|
- **每项 3 轮、净态复位（cleanup + compact queue_len=0 + iostat idle）**；报告给**稳态段中位数**（截前 30s）+ 均值/min/max/stddev/趋势。
- 同步采：6 OSD perf delta（aio_wait/kv_queued/kv_sync/op_w_latency）+ 客户端网卡（关键刀：内存盘下写带宽升上去后，客户端 eno1 会不会成为新墙？）+ ceph 节点 iostat。

### 3.3 判据
- **内存盘下 256K 稳态写能到多少？**（对比真盘 ~51）过 59 否？IOPS 从 ~230 上到多少？
- **新墙在哪**：写带宽升上去后，是被**客户端 eno1（单千兆 118）**顶住，还是 OSD CPU / EC 协调？用客户端网卡 + perf 分段定位。
- **块大小/并发在内存盘下的曲线**：256K vs 4M 还差多少？加并发有用了吗（真盘下 IOPS 恒定，内存盘下是否松动）？

### 3.4 正确回滚（避免上轮 CURRENT 损坏翻车）
**不能直接删 block.db symlink + umount tmpfs。** 正确顺序（逐 OSD）：
```
停 OSD → ceph-bluestore-tool bluefs-bdev-migrate 把 DB 数据迁回 sdb → 移除 block.db → umount tmpfs + 释放 loop → 起 OSD → 确认 up/in
```
若 migrate 失败导致 OSD 起不来 → 该 OSD purge + 重建（`ceph osd purge X --force` + `ceph orch daemon add osd`），落盘。**全部回滚后确认：6 OSD up/in + HEALTH_OK + 无残留 tmpfs/loop + SSD 参数仍在。**

---

## 4. 回报 opencode（最终一条消息）
1. **阶段 D（核心）**：拿到什么工具、三节点 RAID 对比 → node2 的 Write Policy/BBU 到底与 node1/3 差在哪 → **坐实还是推翻"RAID WriteBack 未生效"**。
2. **阶段 E（若做）**：开 WriteBack 后 node2 写延迟、全局 IOPS、**稳态段**写带宽 → 是否解决墙、能否过 59、已回滚否。
3. **阶段 F（上限评估）**：全 OSD 内存盘下，各指标**稳态段中位数**（写/读/块大小/并发全量），256K 写能否过 59、IOPS 上到多少、**新墙在哪**（客户端网卡 / CPU / EC）。显式标注"内存盘=上限非交付基线"。
4. **总判决**：node2 病因确否、可修否、修后能否达标 59；以及"后端理论上限"（内存盘）与"当前真盘能力"的差距归因。
5. 异常（工具不可得、回滚翻车、退化态复测）如实列。

## 5. 明确不做
- ❌ 不把内存盘数据当交付基线（仅上限评估，显式标注）。
- ❌ 不用含缓冲暂态的均值下"过 59"结论（用稳态段中位数）。
- ❌ 不再调 throttle / 验 hdd 误判（已证无效）。
- ❌ 回滚不走 `bluefs-bdev-migrate` 正确流程（避免重蹈 CURRENT 损坏）。
- ❌ 无数据支撑写进结论；不手填 summary。

## 6. 产出目录
`results/node2-raid-fix-memdisk-ceiling-20260709/`：
```
├── ops.log                                # 全程 + 工具获取 + 每台迁移/回滚
├── raid-<node>-{vd,bbu}.txt               # 阶段D 三节点只读取证
├── raid-compare.md                        # 三节点 RAID 对比表 + 病因判定
├── [E] fix-writeback/                      # 若修：净态确认 + rados 逐秒 + node2 perf/iostat + 客户端网卡 + 稳态中位数
├── [F] memdisk-ceiling/
│    ├── migrate-log.txt                    # 6 OSD 迁移/回滚全记录
│    ├── write-256k-t64-r{1,2,3}.txt        # 逐秒
│    ├── {seq,rand}-read-256k-t64-r{1,2,3}.txt
│    ├── {4k,64k,256k,1m,4m}-write-r{1,2,3}.txt
│    ├── conc-256k-t{16,64,128}.txt
│    ├── osd{0..5}-perf-t0/tend.txt + client-nic.txt + ceph{11,13,14}-iostat.txt
│    └── ceiling-summary.md                 # 各指标稳态中位数 + 新墙定位
└── report.md                              # 三阶段结论 + 总判决
```
