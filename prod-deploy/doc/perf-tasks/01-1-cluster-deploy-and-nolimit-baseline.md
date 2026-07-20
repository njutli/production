# 任务书 01-1：新集群从零部署（Ceph + TiKV + JuiceFS）+ 不限速冷态基线

> 面向 GLM。本任务书是**当前阶段（不限速调优）的第一份**任务书，覆盖 **集群尚未部署** 的起点：
> 从空集群开始，依次部署 Ceph、TiKV、JuiceFS，验收通过后立刻做一次不限速冷态基线。
>
> 命名约定（`prod-deploy/doc/perf-tasks/README` 精神）：
> - `00-*` = 上一阶段的全量冷态基线任务书（default vs ra0 双组双口径），已归档，本阶段不重跑限速。
> - `01-N-*` = 当前"不限速调优"阶段的系列任务书，本篇为 **01-1（部署 + 基线起点）**。
>
> 方法论 + 完整命令不在此重复，见同仓库 skill：
> - `prod-deploy/skills/TESTING-GUIDE.md`（health 检查 / compact cooldown / 缓冲暂态 / 可靠性判据 / 记录规范）
> - `prod-deploy/skills/test-commands-reference.md`（每项 fio/juicefs/rados 完整命令 + 稳态中位数 §8 + 数据采集 §9）
> - `prod-deploy/skills/LONG-RUNNING-TEST-SKILL.md`（长跑任务托管）
>
> 上位规划依据：`prod-deploy/doc/perf-analysis/01-baseline-review-and-nolimit-plan.md`
> （本阶段决策：**停做限速测试，全部转不限速口径**；ra0 作为随机读默认起点）。

---

## 〇、前提与红线

- 起点假设：**Ceph 与 TiKV 均未部署**（新机器 / 已 purge）。若集群已存在残留，先按 §1.0 清场。
- SSH 三层跳板：WSL → HK ECS → 157 → slaves，统一走 `config.sh` 的 `_run` / `ssh_to_client` / `ssh_to_slave`；
  输出含 `setlocale` 警告须 grep 过滤；多个连续 `cephadm shell` 合并为单条 `cephadm shell -- bash -c "..."`。
- 磁盘抢占红线：**BeeGFS 与 JuiceFS/Ceph 抢同一批盘（nvme2n1/nvme3n1），不能并存**。
  本任务书部署 Ceph 前，必须确认这些盘上**没有 BeeGFS 的 storage target**（若上一阶段跑过 BeeGFS，先 `clean-beegfs.sh --yes --purge`）。
- 网络红线：不动 100GbE 网卡/驱动参数；不动 157 内核（WekaIO 红线）。
- 本阶段**不做限速**：DB/WAL 已在 tmpfs、读瓶颈在网络/并发不在 DATA 盘，限速对比目的上一阶段已达成。

---

## 一、集群拓扑（部署目标）

| 节点 | 管理网(SSH) | 角色 | 盘 |
|---|---|---|---|
| 157 | 10.20.1.157 | JuiceFS FUSE 客户端 | nvme1n1 → /mnt/jfs-cache（本阶段 cache=0） |
| 150 | 10.20.1.150 | PD+TiKV / Ceph MON+MGR(bootstrap) / 2×OSD | nvme1n1→TiKV，nvme2n1/nvme3n1→OSD |
| 151 | 10.20.1.151 | PD+TiKV / Ceph MON / 2×OSD | 同上 |
| 152 | 10.20.1.152 | PD+TiKV / Ceph MON / 2×OSD | 同上 |

- 双 100GbE：public=10.3.1.0/24（enp139s0f0np0）、cluster=10.3.2.0/24（enp139s0f1np1）。
- Ceph：EC **4+2**、failure-domain=**osd**、`allow_ec_overwrites=true`，6 OSD（3 节点 × 2 NVMe）。
- DB/WAL on **tmpfs**（/mnt/dbwal，测试专用，断电丢、重建即可）；DATA=nvme2n1/nvme3n1（7.68TB SSD）。
- TiKV/PD：3 副本（3 PD + 3 TiKV），max-replicas=3，数据在 nvme1n1（/mnt/jfs-tikv）。
- JuiceFS：`--storage ceph` 直连 RADOS（无 RGW），元数据 TiKV，数据池 `juicefs-data`。

---

## 二、部署顺序（严格按序，每步验收通过再进下一步）

> 全部脚本在 `prod-deploy/scripts/`，均从 `config.sh` 取参数。跑前先核对 `config.sh`（§六 checklist）。

### 1.0 （条件）清场
若盘上有旧集群 / BeeGFS 残留：
- BeeGFS：`beegfs-production` 侧 `bash scripts/clean-beegfs.sh --yes --purge`。
- 旧 Ceph：`bash scripts/deploy-ceph.sh` 的清理路径或手动 `cephadm rm-cluster`，确认 nvme2n1/nvme3n1 无 LVM/信号。
- 旧 TiKV：停 systemd unit、清 /mnt/jfs-tikv。
- **验收**：`lsblk` 确认 nvme2n1/nvme3n1 无分区/无 ceph LVM；157 无残留 JuiceFS mount。

### 1.1 服务器准备
```
bash scripts/prepare-all-servers.sh        # 对 3 slave 跑 prepare-servers.sh slave，对 157 跑 client
```
装包 + 开防火墙端口 + nvme1n1 挂载（slave→/mnt/jfs-tikv，157→/mnt/jfs-cache）+ slave 上 tmpfs /mnt/dbwal（200G）。
- **验收**：每节点 `sudo -n true` 通过；slave `mountpoint /mnt/jfs-tikv` 与 `/mnt/dbwal` 均 OK；157 `mountpoint /mnt/jfs-cache` OK。

### 1.2 （可选）内核/网络调优
```
bash scripts/tune-servers.sh
```
- 红线：**不动 157 内核、不动 100GbE 网卡参数**。仅 slave 侧安全项。

### 1.3 部署 Ceph（先于 TiKV，因 JuiceFS 需要 juicefs-data pool + keyring）
```
bash scripts/deploy-ceph.sh --yes
```
内部：cephadm bootstrap（MON+MGR 在 150）→ 扩 MON 到 151/152 → 加 6 OSD（DB/WAL 走 tmpfs loop）
→ 建 EC 4+2 profile（failure-domain=osd）→ 建 `juicefs-data` EC 池 + `allow_ec_overwrites=true`
→ 建 `client.juicefs` cephx 用户。
- **验收**：
  - `ceph -s` → HEALTH_OK，3 mon quorum，6 osd up/in，pgs active+clean。
  - `ceph osd dump | grep -E 'juicefs-data'` → 池存在、EC、`allow_ec_overwrites` 为 true。
  - `ceph osd dump` 每 OSD 第二组地址为 **10.3.2.x**（cluster_network 生效），public 为 10.3.1.x。
  - 记录本次 **fsid**（重 bootstrap 会变，157 分发要用）。

### 1.4 部署 TiKV + PD
```
bash scripts/deploy-tikv.sh --yes
```
3 PD peer + 3 TiKV store，数据在 /mnt/jfs-tikv。
- **验收**：`bash scripts/test-tikv.sh` 全绿；`curl http://<slave>:2379/pd/api/v1/health` 每 PD `"health":true`；
  `pd-ctl store` 3 store 均 Up、max-replicas=3。

### 1.5 部署 JuiceFS 客户端（157）
```
bash scripts/deploy-juicefs.sh            # status 预检
bash scripts/deploy-juicefs.sh format     # 首次格式化文件系统
bash scripts/deploy-juicefs.sh mount
```
- **先决**：157 的 `/etc/ceph/ceph.conf`（新 fsid + mon_host=10.3.1.6/7/8）+ `ceph.client.juicefs.keyring` 已分发
  （`deploy-juicefs.sh` 内含分发步骤；若手动，见 §6.1）。
- format 参数（`test-commands-reference.md` §2.1，来自 config.sh）：
  ```
  --storage ceph --bucket ceph://juicefs-data
  --access-key ceph --secret-key client.juicefs
  --block-size 256K --trash-days 0
  ```
- mount 参数（本阶段冷态基线，`test-commands-reference.md` §2.2）：
  ```
  --storage ceph --bucket ceph://juicefs-data
  --access-key ceph --secret-key client.juicefs
  --block-size 256K --max-uploads 150 --cache-size 0
  ```
- **验收**：157 `juicefs --version` 含 **eaf3d21f**（1.3.1+2025-12-02.e0032b2 或更新）；
  挂载点可写读；`juicefs status <meta-url>` 正常；
  `ceph --name client.juicefs --keyring … osd pool ls | grep juicefs-data` 通。

---

## 三、不限速冷态基线（部署验收后立即跑）

> 本阶段**只跑不限速一组**（100GbE TCP，双网已分离）。**不做千兆限速**（上一阶段已完成对比，见 perf-analysis/01 §四）。
> readahead 口径：本阶段以 **ra0（`--max-readahead 0`）为随机读默认起点**（历史+上阶段已复现消 2× 放大）。
> 若需保留 default 对照，可在 randread 单项复用同 layout 卷各挂一次做单变量对比（不强制）。

### 3.1 测试矩阵（不限速全量，按 `test-commands-reference.md` §一 + §十）

| 顺序 | 项 | 命令 | 备注 |
|---|---|---|---|
| 1 | seqread | §4.1 | bs=256k, 1 job, 180s |
| 2 | seqwrite(fsync) | §4.2 | bs=4M, 1 job |
| 3 | mseqread | §4.4 | bs=256k, 16 job, 180s |
| 4 | mseqwrite | §4.5 | bs=4M, 16 job |
| 5 | layout | §5 | 128job×1G，写完必跑 §3.2 compact cooldown |
| 6 | randread ×3 | §6.1 | 复用 layout，180s，REPEAT=3 |
| 7 | randwrite ×3 | §6.2 | fresh volume + create_on_open |
| 8 | randrw ×3 | §6.3 | fresh volume + create_on_open |

每项**必做**：`test-commands-reference.md` §9 五类采集（fio 原始输出 + bw_log + NIC + juicefs stats + pidstat）
+ §3.1 drop_caches（**每项跑前**，客户端 157 + 3 storage 节点）。

### 3.2 本阶段特有口径（务必遵守，源自 perf-analysis/01 的三处订正）

**(a) 达标值只认 bw_log 稳态中位数，不看 fio 平均。**
所有 fio 命令已嵌 `--write_bw_log --log_avg_msec=1000`（fio 3.28 无 `--read_bw_log`，`--write_bw_log` 对所有方向生效）。
按 §8.3 对 128 个 bw_log 聚合、截开头 1/4 暂态取**稳态中位数**；randrw 按 data_direction 分读写各取中位数。
**红线**（§8.4）：任何 fio 平均 BW 超单客户端网卡 100GbE TCP 线速（≈12500 MiB/s）一律不认。

**(b) randrw 只看合计，R/W 分列是 fio 队列测量偏差。**
128 job × iodepth 128 = 16384 并发导致队列灾难性积压（上阶段实测 avg clat 达 2.6 万秒、`>=2000ms 占 44%`），
R/W 分列不反映真实读写能力，**汇总必须列 读/写/合计三列**并注明「以合计为准、R/W 分列为高并发队列失真」。
→ 若本轮 randrw 合计仍偏低，追加**降并发扫描**（128×128 → 32×16 → 16×8）看合计是否回升、R/W 是否回归均衡（老集群 76/76 为参照），作为下一份任务书的输入。

**(c) 不限速 ACCEPT=6250 是"网卡半速分母"，不当"全不达标"判据。**
单客户端单 FUSE 挂载几乎到不了 6250 MiB/s。不限速口径**看趋势 + 放大倍数（fio ≤ NIC ≤ object）**，
汇总须算各随机项放大倍数（object GET/PUT ÷ fio 有效带宽）。

**(d) NIC 采集口径。** 不限速客户端只走 public → 采 **enp139s0f0np0**（EC 取片走 cluster 不经客户端网卡）。

**(e) compact 清残余。** layout 后必做 §3.2 compact cooldown（干净态：`compact_queue_len=0` + `compact_running=0` + `kv_sync_lat<2ms`）；随机三项每轮之间也建议 compact（TESTING-GUIDE §6.1）。

---

## 四、结果落盘

结果目录命名：
```
results/prod-nolimit-cold-ra0-<juicefs版本>-<YYYYMMDD-HHMMSS>/
```
目录结构按 `test-commands-reference.md` §9.6；必含 `commands.sh`（§十一）、`summary.md`、
`env-snapshot.txt`（含 ceph health / osd tree / **osd dump 网络地址(确认 10.3.1.x/10.3.2.x)** / 无 tc qdisc 证明不限速 / juicefs version）。

**summary.md 除 fio 平均外，必须另栏记 §8.3 稳态中位数（达标依据）**，randrw 记读/写/合计三列，
并算各随机项放大倍数。

汇总更新到 `prod-deploy/doc/deploy-log/results-table.md`（新增不限速 ra0 稳态中位数行）。

---

## 五、部署过程落盘

部署过程按 `doc/deploy-log/README` 约定记到 `doc/deploy-log/`：
- 新建 `NN-deploy-<date>.md`：记录本次 bootstrap fsid、每步验收输出、遇到的坑与解法。
- 若集群重 bootstrap 过（fsid 变化），务必在文档记新 fsid 并确认 157 conf/keyring 已重分发。

---

## 六、开跑前 checklist

**部署前：**
- [ ] `config.sh` 核对：CEPH_SERVERS/TIKV_SERVERS/CEPH_PRIMARY、EC 4+2 + failure-domain=osd、
      public 10.3.1.0/24 + cluster 10.3.2.0/24、OSD 盘 nvme2n1/nvme3n1、tmpfs /mnt/dbwal 200G、
      block-size 256K、max-uploads 150、cache-size 0、readahead=0（ra0）
- [ ] nvme2n1/nvme3n1 **无 BeeGFS 残留**（如有先 clean-beegfs --purge）
- [ ] 各节点 NOPASSWD sudo；SSH 三跳可达
- [ ] 起点确认：Ceph/TiKV 未部署或已 purge（`lsblk` 盘干净）

**部署后 / 开测前：**
- [ ] Ceph HEALTH_OK + 6 OSD up/in + juicefs-data(EC, ec_overwrites) + osd dump 地址 10.3.1.x/10.3.2.x
- [ ] TiKV 3 PD health:true + 3 store Up
- [ ] 157 ceph.conf(新 fsid + mon_host 10.3.1.6/7/8) + keyring 已分发；`osd pool ls` 见 juicefs-data
- [ ] JuiceFS 版本含 eaf3d21f；挂载可读写
- [ ] 所有 fio 命令带 `--write_bw_log --log_avg_msec=1000`
- [ ] **本阶段不加限速**：无 tc qdisc、Ceph 走 100GbE（osd dump 地址为 10.3.x 非 10.114.x）
- [ ] 每项跑前 drop_caches（157 + 3 slave）
- [ ] layout 后 compact cooldown 到干净态

### 6.1 手动分发 157 的 ceph.conf + keyring（deploy-juicefs 未自动完成时）
集群重 bootstrap 后 fsid 变，157 旧 conf/keyring 失效 → JuiceFS 连不上（`conf_read_file`/`ObjectNotFound`）。
```bash
# 推荐：直接跑分发步骤
bash scripts/deploy-juicefs.sh          # 内部把新 ceph.conf + keyring 推到 157 /etc/ceph/
# 手动：从 150 取 ceph.conf(含新 fsid + mon_host=10.3.1.6/7/8) + `ceph auth get client.juicefs`，base64 传 157
```
验收（157 上）：
```bash
sudo grep -iE 'fsid|mon_host' /etc/ceph/ceph.conf         # fsid=新值, mon_host=10.3.1.6/7/8
ls -l /etc/ceph/ceph.client.juicefs.keyring                # 存在
sudo ceph --name client.juicefs --keyring /etc/ceph/ceph.client.juicefs.keyring osd pool ls | grep juicefs-data
```

---

## 七、完成后交接

本任务书产出（不限速 ra0 冷态基线稳态中位数）= 当前阶段后续任务书的输入基线：
- randrw 合计若仍偏低 → 触发 **01-2**（randrw 降并发扫描 + juicefs stats 分段，见 perf-analysis/01 §5.3）。
- randread ra0 距 6250 仍远 → 触发后续客户端并发扫描 + rados bench 标后端裸上限。
