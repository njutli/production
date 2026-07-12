# 任务（GLM）12.1-步骤1：改部署（WAL/DB 独立 tmpfs + DATA 独立 tmpfs）+ 探 128G layout 容量

> 出题：opencode（规划/校验）　执行：GLM　日期：2026-07-09
> **本任务只做两件事：① 把 6 OSD 从"WAL/DB/DATA 全在同一块 tmpfs"改成"WAL/DB 独立 tmpfs + DATA 独立 tmpfs"，DATA tmpfs 抽到每节点内存真实允许的上限（不再用人为的 38G）；② 探测这个新部署能否安全承载 128G layout。**
> **不跑任何性能测试、不下达标结论。** 正式全量重测（步骤2）+ seqread/multi-seqwrite 根因诊断（步骤3）待本步骤确认部署 OK + 128G 能撑后另出任务书。
> 背景与目的：用户后续调优全部基于全内存盘（排除介质干扰，专注 JuiceFS/Ceph 软件层）。本次改部署目标形态 = **WAL/DB 独立 + DATA 独立**，且 layout 要能到 **128G**（对齐上周真盘基准 `results/patched-v1.3.1-retest-20260702/full-bs256k-cold-mu150-full-20260703-145314/` 的 128 jobs×1G，控制变量，供领导汇报的介质对比数据）。
> FSID = `073f28e0-5fe0-11f1-8ce6-7369ee2be5a1`；OSD 映射：node1(.11)=osd.0/1，node2(.13)=osd.2/3，node3(.14)=osd.4/5。

---

## 0. 铁律（务必先读）
1. **集群无业务数据**，可有创（改部署/重建 OSD）。但**每步必须落盘 ops.log + 可回滚**；历史回滚翻过车（直接删 symlink 致 BlueFS CURRENT 损坏 → purge 重建），本任务改 6 OSD，务必用正确流程。
2. **单 master 串行**：一次只动一个 OSD，做完确认 up/in 再动下一个；全部完成确认 6 OSD up/in + HEALTH_OK + degraded=0。
3. tmpfs 不支持 O_DIRECT，DB/DATA 设备须经 **loop device** 中转（见 06_1）。
4. **改部署最干净的方式很可能是 purge 重建**（`ceph osd purge` + `ceph orch daemon add osd` 指定独立 data/db 设备），而非在线把"同一块"拆成两块（在线拆分 BlueFS 风险高）。**由你判断用哪种，落盘说明选择理由**；无论哪种，做完必须 6 OSD up/in + HEALTH_OK。
5. bash 默认超时 120s；长操作（重建/迁移/写 layout）用 `setsid ... </dev/null >run.log 2>&1 & disown` 后台跑，确认进程真在跑再放手，轮询等完成。
6. 一切判断对账原始命令输出，无数据不下结论。

## 1. 现状摸底（先采,不动配置）
落盘 `probe.log`：
1. **三节点内存**：node1/2/3 各 `free -g`（total/used/free/available），客户端 tikv-node(.12) 也记一下。
2. **当前 6 OSD 部署形态**：确认现在是否 `bluefs_single_shared_device=1`（WAL/DB/DATA 同一 tmpfs）。每 OSD 的 block 设备来源（loop/tmpfs 大小、挂载点）、`ceph osd metadata osd.X | grep -iE "bluefs|db|wal|rotational|devices"`。
3. **Ceph 现状**：`ceph -s`、`ceph df`、`ceph osd df`、`ceph osd dump | grep ratio`（full/nearfull 阈值）、`ceph health detail`（须 HEALTH_OK）。
4. **当前 tmpfs/loop 清单**：三节点 `df -h | grep tmpfs`、`losetup -a`、`lsblk`。

## 2. 容量测算（先算再动，账写进 probe.log）
- 目标 layout = 128G 有效数据（JuiceFS 256K block）→ EC 4+2 → **192G raw**，均摊 6 OSD → 每 OSD DATA 需 **≥32G 纯数据** + BlueStore 元数据/开销余量 → 每 OSD DATA tmpfs 建议 **≥40-45G**（给足余量，避免 OSD nearfull 拒写）。
- WAL/DB 独立 tmpfs：每 OSD **4G**（06_1 已证 2G 会 spillover，4G 够）。
- **每节点内存账**：每台 2 OSD × (DATA 45G + WAL/DB 4G) = 98G tmpfs。对照各节点 available（~200G+），**扣除后须留 ≥40-50G 给系统/Ceph 进程/页缓存**。把每台"available − 98G = 剩余"算清楚，判断是否安全。
- **DATA tmpfs 具体给多大：你先看实测 free，再定切值**，原则=能稳撑 128G layout（每 OSD DATA ≥45G）且每节点留 ≥40G 安全余量。**若内存不够撑 45G×2+4G×2，把你能安全给的最大值和对应 layout 上限报出来**（可能只能到 96G/64G，据实说）。

## 3. 改部署（逐 OSD，串行，可回滚）
对每个 OSD（osd.0→osd.5，跨节点逐个）：
1. **建两块独立 tmpfs + loop**：DATA tmpfs（步骤2定的大小，如 45G）+ WAL/DB tmpfs（4G），各 `truncate` 出 block 文件、`losetup` 绑 loop、`chown 64045:64045`。落盘每 OSD 的 loop 映射。
2. **停 OSD**（`ceph orch daemon stop osd.X` → 等 `ceph osd stat` 显示对应 down → `podman rm -f` 强杀残留容器）。
3. **重建（推荐路线）**：`ceph osd purge X --force` → `ceph orch daemon add osd <host>:data=<DATA loop>,db_devices=<WAL/DB loop>`（或 cephadm 等效方式，指定独立 data + db 设备，确保 `bluefs_single_shared_device=0`）。**由你按 cephadm 实际支持的方式实现"独立 DATA + 独立 WAL/DB"**，落盘命令。
4. **起 OSD → 确认该 OSD up/in、class=ssd**，再动下一个。
5. 每 OSD 做完采 `ceph osd metadata osd.X` 确认 **DATA 与 DB 是两个不同设备**（`bluefs_single_shared_device` 应为 0/false）。
- 6 个全做完：`ceph -s` HEALTH_OK + degraded=0 + 6 up/in；`ceph df` 池重建 OK（EC 4+2，crush-failure-domain=osd，32 PGs，与之前一致）。落盘 `deploy-after.txt`。

## 4. 探 128G 容量（渐进试写,随时可停）
部署 OK 后，挂 JuiceFS（`--cache-size 0 --max-uploads 150`，默认组，本步骤不测性能），渐进写 layout 探容量：
1. **分档写 32G→64G→96G→128G**（128j，每档递增 block 大小；可控方式你定）。
2. **每档写完立即采**（`cap-<档>.log`）：`ceph osd df`（最高 %USE 的 OSD）、三节点 `free -g`（最低 available）、`ceph health`、`dmesg | tail`（OOM/OSD down）。
3. **停止条件（任一触发即停，不硬闯）**：任一 OSD %USE ≥85%（nearfull）、任一节点 available <30G、OOM/OSD down/health WARN。
4. 记录"能安全到几档 / 什么指标先触发 / 128G 时最高 OSD %USE 和最低节点 available"。

## 5. 探测完清理（务必净态,为步骤2起跑）
- 删测试数据 + 清池对象 + `compact` 到 `compact_queue_len=0`（数字非空白）+ 等 iostat idle。
- 确认 `ceph df` 池 USED 回空、HEALTH_OK、degraded=0、6 OSD up/in。落盘 `ceph-df-after-clean.txt`。
- **保留新部署形态**（WAL/DB 独立 + DATA 独立不回滚，步骤2要用）；只清数据。

## 6. 判据（回报 opencode）
1. **部署改成功否**：6 OSD 是否都变成"WAL/DB 独立 + DATA 独立"（`bluefs_single_shared_device=0` 对账）？用了 purge 重建还是在线迁移？
2. **DATA tmpfs 每 OSD 给了多大**、每节点内存扣完剩多少余量？
3. **128G layout 能否安全承载**？（能/否；若否，最大安全到几 G + 什么指标先触发 + 建议 layout 用 128G 还是 96/64G）
4. 128G（或最大档）时最高 OSD %USE、最低节点 available（原始对账）。
5. 部署后集群 HEALTH_OK、6 up/in、池 EC 4+2 参数无误？清理后池回空？
6. 异常（重建失败、OOM、OSD down、回滚、清理不干净）如实列。

## 7. 产出目录
`results/memdisk-redeploy-128g-probe-20260709/`：
```
├── ops.log                  # 全程逐步操作 + loop 映射 + 命令
├── probe.log                # 现状摸底 + 内存/容量两笔账 + DATA tmpfs 定值理由
├── deploy-after.txt         # 改部署后 ceph -s/osd df/osd metadata(证明独立部署)
├── cap-32g.log ... cap-128g.log   # 每档安全指标
├── ceph-df-after-clean.txt  # 清理后池回空证明
└── report.md                # 6 个判据 + 建议 layout 大小
```

## 8. 明确不做
- ❌ 不跑 fio 性能测试、不测带宽、不下达标结论（这是改部署+探容,不是性能测试）。
- ❌ 不改验收口径、不改其他 config（除部署形态）。
- ❌ 不硬闯停止条件（宁可停在 96G 也不打挂 OSD/节点）。
- ❌ 回滚/重建不落盘、不确认 up/in 就往下（避免重蹈 CURRENT 损坏翻车）。
- ❌ 探测数据残留（步骤2要净态起跑）；但新部署形态保留。
