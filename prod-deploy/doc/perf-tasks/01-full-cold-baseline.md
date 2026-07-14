# 任务书：新集群全量冷态基线测试（default vs ra0 双组对照）

> 面向 GLM。前置：`/tmp/fix-cluster-network.md` 的 cluster_network 修复已完成并通过验收（`ceph osd dump` 每 OSD 第二组地址为 `10.3.2.x` + HEALTH_OK）。
>
> 方法论 + 完整命令见同仓库 skill，本任务书只补"本轮特有约定"，不重复命令：
> - `prod-deploy/skills/TESTING-GUIDE.md`（health 检查 / compact cooldown / 缓冲暂态 / 可靠性判据 / 记录规范）
> - `prod-deploy/skills/test-commands-reference.md`（每项 fio/juicefs/rados 完整命令 + 稳态中位数处理 §8 + 数据采集 §9）

---

## 一、任务目标

在**新集群**（修复后）用**之前调优过的最优配置**，做一次全量冷态基线测试，并**验证 ra0 在新集群上的收益**：

- **A 组：`--max-readahead default`**（保留默认预读）
- **B 组：`--max-readahead 0`**（关预读，历史最优）

两组唯一变量是 `--max-readahead`，其余配置完全相同，用于在新集群上复现 ra0 收益（历史：randread +103% / randrw +57%，代价单流顺序读 -33%）。

每组各跑一次**双口径**：
- **不限速**（100GbE TCP，双网已分离）
- **千兆限速**（eno12409 + TBF 1Gbps）

---

## 二、固定配置（两组共用，除 readahead 外）

format（`test-commands-reference.md` §2.1）：
```
--storage ceph --bucket ceph://juicefs-data
--access-key ceph --secret-key client.juicefs
--block-size 256K --trash-days 0
```

mount 公共部分（`test-commands-reference.md` §2.2）：
```
--storage ceph --bucket ceph://juicefs-data
--access-key ceph --secret-key client.juicefs
--block-size 256K --max-uploads 150 --cache-size 0
```
- **A 组**：以上公共部分，**不加** `--max-readahead`
- **B 组**：以上公共部分 **+ `--max-readahead 0`**

> JuiceFS 版本必须含 loadRange 修复（commit eaf3d21f），即 patched v1.3.1 或 v1.4.x。否则 2× 读放大 bug 会掩盖 ra0 效果（`test-commands-reference.md` §0）。

---

## 三、测试矩阵（每组每口径都跑全量）

按 `test-commands-reference.md` §一测试项总表 + §十典型序列执行：

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

每项**必做**：`test-commands-reference.md` §9 的 5 类采集（fio 原始输出 + bw_log + NIC + juicefs stats + pidstat）+ §3.1 drop_caches（每项跑前）。

---

## 四、本轮特有注意点（务必遵守）

### 4.1 双网已分离，不限速口径 NIC 采 enp139s0f0np0
- 修复后 public=10.3.1.0/24(enp139s0f0np0)、cluster=10.3.2.0/24(enp139s0f1np1)。
- §9.3 NIC 监控：**不限速口径采 `enp139s0f0np0`**（客户端只走 public，EC 取片走 cluster 不经客户端网卡）。
- 千兆口径采 `eno12409`。

### 4.2 千兆限速必须加在 eno12409（上轮教训）
- 上一轮 env-snapshot 记成了 `TBF on eno12399（管理网）` → 只限了 SSH 链路，Ceph 数据面仍跑 100GbE，**千兆数据全部作废**。
- 本轮**必须**用 `scripts/limit-bandwidth.sh apply` 正确切网（Ceph public+cluster 切到 10.114.1.0/24 + TBF 在 eno12409），跑前用 `limit-bandwidth.sh status` 确认 TBF 在 eno12409、`ceph osd dump` 地址已切到 10.114.1.x。测完 `limit-bandwidth.sh remove` 恢复 100GbE。

### 4.3 达标值只认稳态中位数，不看 fio 平均（上轮教训）
- 上一轮写类报 randwrite 2618 / randrw W 55.6，randrw R 只有 14.6，全是 fio 平均被客户端写缓冲拉高的假象（clat 平均 22 秒、>=2000ms 占 38%）。
- 本轮**所有项已在命令里嵌入 `--write_bw_log --log_avg_msec=1000`**（fio 3.28 无 `--read_bw_log`，`--write_bw_log` 对所有方向生效）。
- 达标值 = 按 §8.3 对 128 个 bw_log 按时间戳聚合、截开头 1/4 暂态后取**稳态中位数**，randrw 按 data_direction 分读写各取中位数。
- **红线**（§8.4）：任何 fio 平均 BW 超单客户端网卡线速（千兆≈124 / 100GbE TCP≈12500 MiB/s）一律不认。

### 4.4 ACCEPT 分口径，且不限速口径不当"达标线"
- 千兆口径 `ACCEPT=59`（可判达标）。
- 不限速口径 `ACCEPT=6250` 是"网卡半速分母"，**单客户端单 FUSE 挂载几乎到不了**——不限速口径**看趋势 + 放大倍数（fio ≤ NIC ≤ object）**，不要按 6250 判"全不达标"。

### 4.5 每项/每轮前 compact 清残余状态
- layout 后**必做** §3.2 compact cooldown（干净态判据 `compact_queue_len=0` + `compact_running=0` + `kv_sync_lat<2ms`）。
- 随机三项每轮之间也建议 compact，避免多轮累积 BlueFS 残余触发 stall（TESTING-GUIDE §6.1）。

### 4.6 A/B 两组切换 = 只改 mount，不重建集群
- A→B 只需 umount → 换 mount 参数重挂（randread 复用同一 layout 卷即可做单变量对比）。
- randwrite/randrw 是 fresh volume，两组各自 destroy→format→mount。

---

## 五、结果落盘

每组每口径一个结果目录，命名：
```
results/prod-{nolimit|1gbit}-cold-{default|ra0}-<juicefs版本>-<YYYYMMDD-HHMMSS>/
```
目录内结构按 `test-commands-reference.md` §9.6；必含 `commands.sh`（§十一）、`summary.md`、`env-snapshot.txt`（含 ceph health/osd tree/osd dump 网络地址/tc qdisc）。

**summary.md 除记录 fio 平均外，必须另起一栏记 §8.3 算出的稳态中位数**（这才是达标依据），并算出各随机项的放大倍数（object GET/PUT ÷ fio 有效带宽）。

汇总更新到 `prod-deploy/doc/deploy-log/results-table.md`（default / ra0 各一行 × 双口径），并在 A/B 对照处标注 ra0 相对 default 的 randread/randrw 增幅、seqread 降幅，用于验证 ra0 收益是否在新集群复现。

---

## 六、开跑前 checklist

- [ ] cluster_network 修复已验收（`ceph osd dump` 第二组地址 10.3.2.x + HEALTH_OK）
- [ ] **157 的 ceph.conf + keyring 已重新分发**（见下 §6.1，集群重新 bootstrap 过 fsid 会变，必须重分发）
- [ ] JuiceFS 版本含 eaf3d21f（`juicefs --version` 显示 1.3.1+ 或 1.4.x）
- [ ] fio 命令均带 `--write_bw_log --log_avg_msec=1000`
- [ ] 千兆口径用 `limit-bandwidth.sh apply` 且 `status` 确认 TBF 在 eno12409
- [ ] 每项跑前 drop_caches（客户端 157 + 3 storage 节点）
- [ ] layout 后 compact cooldown 到干净态

### 6.1 重新分发 157 的 ceph.conf + keyring（集群重新 bootstrap 后必做）

集群若被重新 bootstrap（`ceph fsid` 变化，如 2026-07-14 从 `87b65934…` 变成 `b3f3ba90…`），
则 157 上的旧 `/etc/ceph/ceph.conf` + `ceph.client.juicefs.keyring` 会失效/缺失，
JuiceFS 客户端连不上新集群（`ceph … osd pool ls` 报 `conf_read_file` / `ObjectNotFound`）。

**必须先把新集群的 conf + keyring 分发到 157，再 format/mount：**

```bash
# 方法一（推荐）：直接跑分发那步
bash scripts/deploy-juicefs.sh          # 内部 Step 会把新 ceph.conf + keyring 推到 157 /etc/ceph/

# 方法二（手动）：从 150 取新 conf + client.juicefs key，base64 传到 157
#   ceph.conf 需含新 fsid + mon_host（public 网 10.3.1.6/7/8）
#   keyring = [client.juicefs] key（集群侧 `ceph auth get client.juicefs`）
```

**验收（在 157 上）**：
```bash
sudo cat /etc/ceph/ceph.conf | grep -iE 'fsid|mon_host'     # fsid=新值, mon_host=10.3.1.6/7/8
ls -l /etc/ceph/ceph.client.juicefs.keyring                  # 存在
sudo ceph --name client.juicefs --keyring /etc/ceph/ceph.client.juicefs.keyring osd pool ls | grep juicefs-data
#   能列出 juicefs-data 才算通
```
