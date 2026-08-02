# 01 — H3C 对比基线测试任务书

> **面向对象**：GLM（执行者）
> **是否重跑**：否，首轮建立 H3C 对比口径基线
> **承接**：`doc/perf-analysis/01-h3c-tuning-plan.md`（配置由来）+ `README.md`（H3C 目标 + 历史经验）
> **产出报告**：`doc/perf-report/01-h3c-baseline-report.md`（同编号）
> **结果目录**：`results/h3c-baseline-<YYYYMMDD-HHMMSS>/`
>
> **⚠️ 测试过程必须严格遵守 `skills/` 下全部文档，尤其：**
> - `skills/TESTING-GUIDE.md`：health 检查 / compact cooldown / 可靠性判据 / OSD compaction 三指标（`compact_queue_len`/`compact_running` 全绿才继续）
> - `skills/test-commands-reference.md`：完整 4 项命令 / 卷生命周期 / 数据采集规范（§8）
> - `skills/baseline-reproduction-skill.md`：集群配置 / 轮间清理 / 复现验证流程
> - `pre-skills/cluster-rebuild-skill.md`：重建/恢复指针页（→ prod-deploy 的 stable-rebuild-skill 规范路线 + cluster-rebuild-skill 诊断）（**h3c 口径为一次性前置**，见步骤 0.5；非过程反复做）
> - `skills/LONG-RUNNING-TEST-SKILL.md`：长跑监控（sleep 唤醒 + 每次唤醒查 health）
>
> 以下要求**不可省略**：
> - 每个测试项前必须 `check_ceph_health`；非 HEALTH_OK 不开测。
> - 写项后必须 compact cooldown 并轮询至 `compact_running=0` 再进下一项。
> - 数据异常（BW 偏低 >50% 预期 / 轮间波动 >5%）必须排查并重测，不得跳过。

---

## 〇、背景

`prod-deploy` 的配置是为 **256K 随机高并发（128 jobs）** 调的；H3C 的 4 项测试是 **大块顺序单线程（16M/20M，1 job）**，优化方向几乎相反（见 `README.md` 差异表）。本任务基于历史经验，**暂定一组针对 H3C 口径的最优配置，测一组可靠基线**，作为后续赶超 H3C 的调优起点。

> 本任务不做参数 sweep（除 max-readahead 的必要验证），只锁定"暂定最优配置"下的收敛基线。参数寻优放到 02 起的后续任务。

### H3C 性能目标（对比标靶）

| # | 测试项 | H3C 性能 | 本次口径 |
|---|--------|---------|---------|
| 1 | cp 读 | 2.0 GB/s | `time cp /mnt/epc/20Gfile /mnt/jfs-cache/20Gfile.cpread` |
| 2 | cp 写 | 2.0 GB/s | `time cp /mnt/jfs-cache/20Gfile /mnt/epc/` |
| 3 | fio 顺序读 | 5.4 GB/s | `--bs=20M --rw=read --direct=1 --numjobs=1 --runtime=60` |
| 4 | fio 顺序写 | 3.2 GB/s | `--bs=16M --rw=write --direct=1 --numjobs=1 --runtime=120` |

---

## 一、目标

一句话：**在针对 H3C 大块顺序口径暂定的最优配置下，跑出 4 项测试的收敛基线（REPEAT≥3、轮间波动 <5%），量化当前与 H3C 4 个标靶的差距，为后续调优确定方向。**

---

## 二、口径与配置

### 2.1 暂定最优配置（H3C 大块顺序口径）

| 参数 | 值 | 理由 / 来源 |
|------|:-:|------|
| **--block-size** | **4M** | 顺序无半块放大；RADOS GET/PUT 数 16×↓。**format 时参数，须新建 `juicefs-h3c` 卷，不动 `juicefs-prod`** |
| **--max-fuse-io** | **1M** | kernel 5.15 FUSE 硬上限；大块顺序 dispatch 数↓（prod-deploy 02-1 §9.2：mseqwrite 2265→4279 = +89%） |
| **--buffer-size** | **1024** | 配合 max-fuse-io 1M，防 go-fuse readPool 涨内存触发 write sleep（prod-deploy 02-1b） |
| **--max-readahead** | **8M** ⚑ | 顺序读预取纯收益（prod-deploy 的 ra0 是随机口径，方向相反）。⚑ **8M 为经验外推、prod-deploy 只测过 0/default**，本任务须 sweep 验证（步骤 5） |
| **--max-uploads** | 150 | 顺序写 +23%（演进报告 §四） |
| **--cache-size** | 0 | 冷态基线；writeback/暖态后续再考虑 |

> 以上均已固化进 `config.sh`（`JUICEFS_BASE_MOUNT_OPTS` + `JUICEFS_FORMAT_BLOCK_SIZE=4M` + `JUICEFS_READAHEAD=8M`），一键脚本会自动带上。

### 2.2 测试口径（严格遵守 skill）

- 所有测试在 `${EPC_MOUNT_POINT}`（`/mnt/epc`）上执行。
- **cp 本地端一律用 `/mnt/jfs-cache`（nvme1n1），禁用 /tmp**：157 上有 WekaIO 业务，/tmp 若为 tmpfs 会撞内存红线并与 WekaIO 争内存/带宽。
- fio `--direct=1`（绕内核页缓存）；cp 走 page cache（文件级真实场景）。
- 每项每轮跑前 `sync && echo 3 > /proc/sys/vm/drop_caches`（skill §3.1）。
- **REPEAT≥3，取中位数（第 2 大值），禁止取平均、禁挑轮次、禁丢弃任何一轮**（skill 3.3 / baseline §3.3）。
- fio BW 口径：H3C 用 fio 平均值，**同口径对比可直接用 fio 报告 BW**；若需绝对真值，加 `--write_bw_log=<prefix> --log_avg_msec=1000` 取稳态段中位数（截前 1/4）。两种都记录。
- 指标计算：cp 带宽 = 20G / `time` 的 real 秒；fio 取 `READ:/WRITE: bw=`。

### 2.3 验收 / 收敛判据

| 判据 | 门槛 |
|------|------|
| **收敛性（硬门槛）** | 各项 REPEAT≥3 的**轮间波动 <5%**（skill 四·三）；不收敛须排查（SST 积压 / compact / max-fuse-io 是否生效）并重测，收敛后方可锁定为基线 |
| 集群健康 | 全程 `HEALTH_OK`（中途非 OK 且未自动恢复 → 数据不可靠，重测，skill 七） |
| NIC 一致性 | NIC RX/TX 与 fio/cp BW 大致吻合（严重不符 → 查异常流量或缓存命中） |
| H3C 差距 | 收敛基线 vs 4 个 H3C 标靶，记录达标/差距（**这是横向对比，不是本任务的收敛门槛**） |

> 注：H3C 差距只作参考记录，不作为基线是否"测准"的门槛。基线测准的唯一硬门槛是收敛性。

---

## 三、执行步骤

> 逐条勾选。每步遵守 skill 对应章节。

### 步骤 0：环境前置检查（skill TESTING-GUIDE §1）

- [ ] `sudo ceph health` = HEALTH_OK；`ceph osd tree` 全 up；`ceph osd stat` in 数正确。
- [ ] `ceph health detail | grep -i bluefs` 无 DB stall。
- [ ] OSD compaction 三指标全绿（`compact_queue_len=0` + `compact_running=0`，admin socket 直采）。
- [ ] 网络：两网卡 UP、100GbE MTU=4200；`cluster_network`=10.3.2.0/24 且 cluster NIC 有 RX/TX（baseline §1.3）。
- [ ] 磁盘空间：`df -h /mnt/jfs-cache` ≥ 40G（放 20G 源 + 20G 副本）；`ceph df` 充足。
- [ ] JuiceFS 版本 `1.3.1+`（含 loadRange 修复 commit eaf3d21f）。
- [ ] **157 红线确认**：不动内核/网卡/RoCE/md0/WekaIO 路径；确认 WekaIO 内存占用，cp 走 jfs-cache 不打爆内存。

### 步骤 0.5：一次性彻底清理集群（⚠️ h3c 首测必做，消除 prod 旧数据）

> **背景（2026-07-22 实测）**：当前 `juicefs-data` pool 里有 **~305 万对象 / 1.1 TiB** prod-deploy 256K 口径的历史残留。h3c 新卷 `juicefs-h3c` 与 `juicefs-prod` **共用同一个 `juicefs-data` pool**——不清掉旧对象，新 4M 卷的读写要在被小对象撑大的 RocksDB LSM / TiKV 元数据上进行，**非干净态，顺序读稳态会被拖累且轮间无法收敛（<5%）**。
>
> **因此 h3c 首测前必须一次性彻底清理。** 这是**前置一次性**动作（非过程中反复重建）；重建/恢复口径见指针页 `pre-skills/cluster-rebuild-skill.md`（→ prod-deploy 规范路线 stable-rebuild-skill / 诊断 cluster-rebuild-skill）。

- [ ] 确认无任何测试在跑、JuiceFS 已卸载（`mount | grep -iE 'juicefs|/mnt/epc|/mnt/juicefs'` 为空）。
- [ ] 选一种清理方式（二选一）：
  - **A. stable-ID 重建（推荐，最干净且保 pool_id）**：按指针页 `pre-skills/cluster-rebuild-skill.md` → prod-deploy `stable-rebuild-skill.md` §二执行（destroy + `ceph auth rm` + `ceph-volume lvm` 复用现有 LV，禁 zap，~15min）。**注意：h3c 是一次性前置，跨部署不比绝对值，pool_id 是否保留不影响 h3c 口径。**
  - **B. pool 级重建（次选，更快）**：
    ```bash
    # 先 destroy 掉 prod 卷元数据（若还在），再删 pool 重建
    sudo ceph osd pool delete juicefs-data juicefs-data --yes-i-really-really-mean-it
    sudo ceph osd pool create juicefs-data 32 32 erasure ec-prod
    sudo ceph osd pool set juicefs-data allow_ec_overwrites true
    sudo ceph osd pool application enable juicefs-data juicefs
    # 重启所有 OSD 清 BlueStore 内存/LSM（见 baseline §2.4 步骤 3）
    ```
- [ ] **归零确认（硬门槛）**：`sudo rados df | grep juicefs-data` 的 OBJECTS **必须 = 0**（或 pool 全新无对象）后方可进步骤 1。
- [ ] 等 `HEALTH_OK` + PG `active+clean` + compaction 三指标全绿 + cephadm 告警消除，再建 h3c 卷。

### 步骤 1：新建 `juicefs-h3c` 卷（block-size 4M）+ 挂载

- [ ] format（block-size 4M，卷名 juicefs-h3c）：
```bash
juicefs format --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs \
  --block-size 4M --trash-days 0 --force \
  "${META}" juicefs-h3c
```
- [ ] mount（暂定最优参数，全部带上）：
```bash
juicefs mount -d --storage ceph --bucket ceph://juicefs-data \
  --access-key ceph --secret-key client.juicefs \
  --block-size 4M --max-fuse-io 1M --buffer-size 1024 \
  --max-uploads 150 --cache-size 0 --max-readahead 8M \
  "${META}" /mnt/epc
```
- [ ] **验证 max-fuse-io 生效**（否则 1M 白设）：
```bash
# 找到本挂载的 fuse 连接，确认 max_read = 1048576（=1M）
for c in /sys/fs/fuse/connections/*/; do echo "$c: $(cat $c/max_read 2>/dev/null)"; done
```
  - max_read ≠ 1048576 → 排查（kernel 版本 / 参数拼写），修正后重挂，**不带病继续**。
- [ ] 记录 JuiceFS 进程 `VmRSS/VmSize`（`cat /proc/$(pgrep -f 'juicefs.*mount'|head -1)/status | grep -E 'VmRSS|VmSize'`）作内存基线。

### 步骤 2：前置查本地端瓶颈（cp 项上限）

- [ ] 测 `/mnt/jfs-cache` 裸速（dd direct，4M×5120=20G）：
```bash
dd if=/dev/zero of=/mnt/jfs-cache/ddtest bs=4M count=5120 oflag=direct  # 写
dd if=/mnt/jfs-cache/ddtest of=/dev/null bs=4M count=5120 iflag=direct   # 读
rm /mnt/jfs-cache/ddtest
```
- [ ] 记录本地端读/写裸速。**若 < 2 GB/s，cp 项无法超 H3C**，须在报告显式标注 cp 项受本地端瓶颈限制。

### 步骤 3：准备测试文件

- [ ] 存储端 20G（cp 读的源）：`dd if=/dev/zero of=/mnt/epc/20Gfile bs=4M count=5120`
- [ ] 本地端 20G（cp 写的源）：`dd if=/dev/zero of=/mnt/jfs-cache/20Gfile bs=4M count=5120`

### 步骤 4：跑 4 项 × REPEAT≥3（一键脚本）

- [ ] 执行：
```bash
bash scripts/tests/h3c-4item-test.sh --repeat 3 --label h3c-baseline
```
  脚本已内置：每项前 drop_caches + check_ceph_health、NIC + jfs-stats 采集、cp 读写独立文件名（不误删 cp 写源）、轮间清理、自动生成 `commands.sh` + `env-snapshot.txt`。
- [ ] 复现验证（baseline §四）：跑满 3 轮，轮间用**清卷**（`juicefs destroy` + compact cooldown，见通用注意事项 7）为主。**h3c 是大块顺序单线程、低 IOPS，对 RocksDB LSM 压力远小于 prod 的 256K 随机高并发，默认不做过程性重建**。仅当某轮某项 BW 比前轮低 >10% 且排查确认为 SST 积压（compact 三指标非全绿、compact 后仍不恢复）时，才触发一次兜底重建（指针页 `pre-skills/cluster-rebuild-skill.md` → stable-rebuild-skill）。
- [ ] 写项后确认 compact cooldown 完成（skill §3.2，轮询 `compact_running=0`）。
- [ ] 长跑期间按 `LONG-RUNNING-TEST-SKILL.md`：每次唤醒查 `ps` + 日志尾 + `ceph health`。

### 步骤 5：max-readahead 验证 sweep（⚑ 仅此一项 sweep）

> 8M 是经验外推，须实测确认不劣于/优于其它档。仅在基线收敛后做。

- [ ] 固定其余最优参数，只扫 `--max-readahead ∈ {default, 4M, 8M, 16M}`，各跑 fio seq_read REPEAT≥3。
- [ ] 判定：
  - 8M 为峰值或与峰值差 <3% → 保留 8M，记录。
  - 其它档明显更优（>5%）→ 更新 `config.sh` 的 `JUICEFS_READAHEAD` 为最优档，并在报告说明。
  - 各档无差异 → 记录"readahead 对本口径不敏感"，保留 8M。

---

## 四、交付物

```
results/h3c-baseline-<YYYYMMDD-HHMMSS>/
├── commands.sh                    # 完整可执行命令（脚本自动生成）
├── env-snapshot.txt               # health + OSD + NIC + JuiceFS 版本/参数 + jfs-cache 裸速 + VmRSS
├── cp-read-r{1..3}/               # cp-time.txt + nic-raw.txt + jfs-stats.txt
├── cp-write-r{1..3}/
├── fio-seq-read-r{1..3}/          # fio 全文 + (可选) _bw.log
├── fio-seq-write-r{1..3}/
├── readahead-sweep/               # 步骤 5：default/4M/8M/16M 各 fio seq_read
└── summary.md                     # 见下
```

`summary.md` 必含：

| 测试项 | r1 | r2 | r3 | 中位 | H3C 目标 | 达标? | 轮间波动 |
|--------|----|----|----|------|---------|-------|---------|
| cp 读 | | | | | 2.0 GB/s | | <5%? |
| cp 写 | | | | | 2.0 GB/s | | <5%? |
| fio seq_read | | | | | 5.4 GB/s | | <5%? |
| fio seq_write | | | | | 3.2 GB/s | | <5%? |

- [ ] 收敛性判定（每项轮间波动是否 <5%，未收敛的排查记录）。
- [ ] max-fuse-io 生效证据（max_read=1048576）。
- [ ] max-readahead sweep 结果 + 最终选定值。
- [ ] jfs-cache 裸速（cp 项上限说明）。
- [ ] 与 H3C 4 标靶差距 + 后续调优方向（承接 `01-h3c-tuning-plan.md` §三）。
- [ ] 产出 `doc/perf-report/01-h3c-baseline-report.md`（同编号分析报告）。
- [ ] 真值同步进 `doc/deploy-log/results-table.md`（如已建）。

---

## 五、通用注意事项（必带，逐条遵守）

> 引自 `prod-deploy` TASK-BOOK-AUTHORING-GUIDE §二，关键红线就地复述。

1. **数据统计口径**：REPEAT≥3 取中位数（第 2 大值），不取平均、不挑轮次。fio 写类平均 BW 受前期写缓冲污染偏高（~7-8%，曾超线速属失真）；需绝对真值时取 `--write_bw_log` 稳态段（截前 1/4）中位数。**超线速（100GbE≈12500 MiB/s）的平均值一律不认**。
2. **冷态净化**：每项每轮跑前 drop_caches（脚本已做）；direct=1 绕不开 JuiceFS 客户端缓冲，故 cache-size=0。
3. **后端干净态**：写项后必须 `compact` + 轮询至 `compact_running=0` 再进下一项；restart OSD 清不掉 compaction 积压。切换配置后等集群完全恢复（10+ min）再测。
4. **环境前置**：开测前 HEALTH_OK + OSD 全 up；JuiceFS `1.3.1+`。
5. **157 红线**：157 有 WekaIO 业务在跑，**禁动内核/网卡/RoCE/md0/WekaIO 路径**；cp 本地端走 jfs-cache 不用 /tmp，注意不打爆内存。
6. **记录规范**：每个结果目录必含 `commands.sh`；每项保存 fio 全文 / cp time / NIC / jfs-stats / env-snapshot。
7. **卷清理**：`juicefs format` 不删 pool 对象——多轮须用 `juicefs destroy`（传 UUID 非卷名）+ compact cooldown（skill §3.5 / baseline §2.4）。`rados df -p juicefs-data` 确认对象数。
8. **结论冲突显式标注**：若数据与既有论断冲突或被推翻，显式标注、提示人工复审，不默默改写。统一用"失真"（禁用"伪影"）。

---

## 六、红线汇总

- **本任务特有**：
  - block-size 4M 是 **format 时参数**，必须**新建 `juicefs-h3c` 卷**，绝不 format 已有 `juicefs-prod`（会毁 prod-deploy 数据）。
  - max-fuse-io 1M 挂载后**必须验证 max_read=1048576 生效**，否则参数白设、基线无意义。
  - cp 本地端**只用 `/mnt/jfs-cache`，禁用 /tmp**（内存红线 + WekaIO 竞争）。
  - cp 读的目标用独立名（`20Gfile.cpread`），**绝不删除 cp 写的源文件**。
- **复述通用红线**：157 WekaIO 不可动；HEALTH_OK 才开测;写后 compact cooldown;REPEAT≥3 取中位、轮间波动 <5% 才锁基线;超线速值不认。
