# 任务书 02-1：零号检查 — 基础设施诊断 + 隐藏瓶颈排查

> 面向 GLM。**本任务书的定位是「A1/B1 调优的前置门槛」**——在投入大量测试时间做后端/客户端调优之前，先确认测试环境的基础设施没有隐藏问题。
>
> 01-5 已暴露 cluster_network 零流量是重大隐患；4 份外部调优建议均指出"不先修底层问题就做 A/B 线调优，所有后续数据都可能受干扰"。
> 其中 Z4（FUSE 内核 `max_read`）和 Z5（objecter 限流）如果命中，**可能根本改变 02 计划 B 线方向**——从"攻 FUSE 架构固有延迟"转向"修正一个配置不匹配"。
>
> **本任务回答的问题**：
> - cluster_network 修复是否真的生效了？（Z1）
> - PG 在 6 OSD 上分布是否均衡？（Z2）
> - 本集群能否复现 01-4 的 CephFS+Rep 6718？（Z3）
> - FUSE 内核侧 `max_read` 是否为 128K 导致 256K I/O 被拆包？（Z4）
> - librados 客户端 `objecter_inflight_op_bytes` 是否在限流？（Z5）
> - EC pool `fast_read` 能否消除冷启动-暖缓存波动？（Z6）
>
> 承接：`results/prod-01-5-rados-ec-vs-rep-mechanism-20260718-233945/`（01-5 数据）+
> `results/prod-nolimit-rootcause-cephfs-20260716-220958/`（01-4 CephFS 数据）。
> 方法论见 skill：`TESTING-GUIDE.md`、`test-commands-reference.md` §6.1/§8。
> 上位规划：`doc/perf-analysis/02-backend-raw-cap-and-juicefs-tuning-plan.md` §零（零号检查）。
>
> 来源：`/tmp/02-stage-optimization-suggestions.md` §一/§二 +
> `/tmp/minimax-m3-02-stage-tuning-recommendations.md` §二/§四 +
> `/tmp/opencode-02-stage-tuning-suggestions.md` 方向1 +
> `/tmp/opencode-02阶段调优补充建议.md` N1/N3。

---

## 〇、背景：为什么需要零号检查

### 0.1 01 阶段遗留的隐患

01-5 §四.4 报告了一个**重大发现**：cluster NIC `enp139s0f1np1` 在全部 rados bench 测试中**全程零流量**——EC subop 全部走 public NIC。后续"修复 cluster_network=10.3.2.0/24"后性能**反降**（写 -19%、读 -6%），但**没有验证修复是否生效**就开始等预热。

这意味着：
- 02 计划 A1"等 OSD 预热 24h 后复测"的整个流程，可能在 cluster_network **依然零流量**的状态下采集无效对照数据。
- 01-4 §5.4 的"IOPS 被延迟反馈环封顶在 11.6K → CPU 封顶 6 核"推导，隐含前提是"128 goroutine 的请求都能畅通进入 librados 队列"——但从未检查 librados 客户端自身的限流阀（`objecter_inflight_op_bytes` 默认仅 100MB）。
- 01-4/01-5 推断"FUSE dispatch 5+ms/op 是架构固有"，但**从未检查内核侧 FUSE 的 `max_read` 参数**——若默认 128K，256K I/O 被拆成 2 次 `/dev/fuse` 往返，dispatch 延迟直接翻倍。

### 0.2 核心逻辑

**在投入大量测试时间前，先确认测试环境没有隐藏问题。** 6 项零号检查门槛极低（<1h 可完成 Z1/Z2/Z4/Z5 的诊断部分），但其中任何一项命中都可能**改变 02 阶段后续方向**：

| 检查项 | 如果命中 | 对 02 计划的影响 |
|--------|---------|-----------------|
| Z1 cluster_network 未生效 | A1 预热复测是无效对照 | 必须先修根因再预热 |
| Z2 PG 不均衡 | 某些 OSD 过载 | 调 pg_num 后可能直接提升 |
| Z3 复现 6718 | CephFS+Rep 达标路径确认 | 直接给用户拍板选项 |
| Z4 max_read=128K | slat 15× 的物理根因 | B 线从"攻架构"转向"改配置" |
| Z5 objecter 限流 | 01-4 §5.4 结论需修正 | B 线优先级根本改变 |
| Z6 fast_read 有效 | 消除冷启动波动 | A4 可降级 |

### 0.3 与 01 阶段的关系（避免重复）

Z3（kernel CephFS+Rep 复现）与 01-5 实验 B 的 ceph-fuse vs kernel CephFS 对照有重叠，但**关键区别**：
- 01-5 实验 B 的 kernel CephFS 用的是 `juicefs-data-rep` 池，测得 4972。
- Z3 的目标是复现 01-4 的 **6718**——01-4 测试时是不同的集群状态（FSID 不同）。
- 若 Z3 在当前集群复现 6718 → 说明 4972→6718 的差异可消除，直接给出达标路径。

---

## 一、目标

**主目标**：用最低成本（<2h）完成 6 项基础设施诊断/验证，在 02 阶段 A/B 线调优开始前排除隐藏干扰项。

**判读逻辑**：

| 检查结果 | 判定 | 后续动作 |
|----------|------|---------|
| Z1 cluster_network 已生效 | ✅ 修复有效 | 进 A1 预热复测 |
| Z1 cluster_network 仍零流量 | ❌ 修复未生效 | 先修根因（配置/CRUSH/bug），不盲目预热 |
| Z2 PG 均衡（±20%） | ✅ 无热点 | 继续 |
| Z2 PG 不均衡 | ❌ 有热点 OSD | 调 pg_num 或重 crush 后重测 |
| Z3 复现 ≥6000 | ✅ 达标路径确认 | 记录"CephFS+Rep 可达标"，供用户拍板 |
| Z3 仍 ≈4972 | ❌ 差距未消除 | 与 Z1 结果交叉分析（cluster_network?） |
| Z4 max_read=128K 且修正后 slat↓ | ✅ **物理根因找到** | B 线方向根本改变，优先修配置 |
| Z4 max_read=256K 或修正无变化 | ❌ 非 max_read 问题 | B 线按原计划执行 |
| Z5 限流命中且修正后 slat↓ | ✅ **隐藏限流找到** | 01-4 §5.4 结论需修正 |
| Z5 未限流 | ❌ objecter 非瓶颈 | 排除，继续 |
| Z6 fast_read 消除冷启动波动 | ✅ 尾延迟拖尾确认 | A4 降级，记录 fast_read 有效 |
| Z6 无变化 | ❌ fast_read 无效 | 回滚 |

---

## 二、检查矩阵与口径

### 2.1 6 项检查分类

| # | 检查项 | 类型 | 改动 | 预计耗时 | 风险 |
|---|--------|------|------|---------|------|
| Z1 | cluster_network 根因诊断 | 纯诊断 | 无改动 | ~15min | 0 |
| Z2 | PG 分布均衡性 | 纯诊断 | 无改动 | ~5min | 0 |
| Z3 | kernel CephFS+Rep 复现 | 复现测试 | 无改动（只 mount） | ~30min | 低 |
| Z4 | FUSE 内核 max_read | 诊断+修正+复测 | remount JuiceFS | ~20min | 低 |
| Z5 | objecter 限流 | 诊断+修正+复测 | 改 ceph config | ~15min | 低 |
| Z6 | EC pool fast_read | 诊断+开关+复测 | 改 pool 属性 | ~15min | 低 |

### 2.2 测试口径

- **Z3**：kernel CephFS+Rep randread，bs=256k，128job×iodepth128，ra0，REPEAT=3，runtime=180s。复用 01-5 实验 B 的 layout 数据。
- **Z4/Z5**：JuiceFS+EC randread，bs=256k，128job×iodepth128，ra0，REPEAT=3，runtime=180s。复用 01-2d layout 数据。
- **Z6**：rados bench EC randread，-t128/-t4096，256K object，REPEAT=3，runtime=60s。
- **统计口径**：fio 用 §8.3 稳态中位数（截开头 1/4）；rados bench 取 3 轮中位数。
- **冷态**：cache=0，每轮跑前 drop_caches（157 + 3 slave）。
- **验收线**：6250 MiB/s（不限速 100GbE 网卡 50%）。

---

## 三、执行步骤

### 步骤 0：环境前置检查

- [ ] `ceph health` = HEALTH_OK，6 OSD up/in
- [ ] JuiceFS 版本 `1.3.1+`（含 loadRange 修复）
- [ ] 157 红线确认：不动内核/100GbE NIC/RoCE/md0/WekaIO
- [ ] BeeGFS 错峰（与本测试抢同批 NVMe 盘）
- [ ] `ceph osd dump` 快照（所有 OSD 配置变更前留底，可回滚）

### 步骤 1：Z1 — cluster_network 零流量根因诊断

> 目标：确认 cluster_network=10.3.2.0/24 是否真的生效，还是 EC subop 仍走 public NIC。

**1.1 配置层确认**（<5min）：
```bash
ceph config show osd.0 | grep -E "cluster_network|public_network|cluster_addr"
ceph config get osd cluster_network
ceph config get osd public_network
```

**1.2 OSD 进程实际监听**（<5min）：
```bash
# 在任一 slave 节点执行
ss -tlnp | grep ceph
# 期望：6789(public/mon) + 6800-7300(cluster/osd) 两组端口
# 若只有 6789 → OSD 未绑定 cluster 端口
```

**1.3 CRUSH map 检查**（<5min）：
```bash
ceph osd metadata osd.0 | grep -E "addr|front_addr|back_addr"
# front_addr = public, back_addr = cluster
# 若 back_addr 为空或指向 public IP → CRUSH map 未绑定 cluster_addr
```

**1.4 抓包直接确认**（<5min，最直接）：
```bash
# 在跑 rados bench randread 时，在任一 slave 节点抓 cluster NIC
# 先启动一个后台 rados bench：
rados bench -p juicefs-data 30 rand --pool-ops &

# 抓包：
tcpdump -i enp139s0f1np1 'port 6800' -c 100 -nn 2>&1 | head -20
# 期望：有 EC subop 流量（6800+ 端口）
# 当前（01-5 报告）：0 packets → 修复未生效

# 抓 public NIC 对照：
tcpdump -i enp139s0f0np0 'port 6800' -c 100 -nn 2>&1 | head -20
# 若 public NIC 有 6800 流量 → EC subop 走错网卡
```

**1.5 判定**：
- 配置层正确 + 进程监听 6800 + tcpdump 有流量 → ✅ cluster_network 已生效，进 A1 预热复测。
- 配置层正确但 tcpdump 0 流量 → ❌ 可能是 Quincy 17.2.x 在 `failure-domain=osd` 下的路由 bug。搜索 [tracker.ceph.com](https://tracker.ceph.com)，记录 bug ID。
- 配置层缺失（back_addr 空/指向 public）→ 修配置/CRUSH map 后重测。

**1.6 附带**：测 cluster NIC RTT：
```bash
ping -c 10 10.3.2.7    # cluster 网络
ping -c 10 10.3.1.7    # public 网络
# 对比延迟差异
```

### 步骤 2：Z2 — PG 分布与 CRUSH 均衡性检查

> 目标：确认 32 PG 在 6 OSD 上分布是否均匀。

**2.1 检查**（~5min）：
```bash
ceph osd df tree                              # 各 OSD 使用率
ceph pg dump_stuck                             # 是否有 stuck PG
ceph pg ls-by-pool juicefs-data | \
  awk '{print $NF}' | sort | uniq -c          # 每 OSD 承载 PG 数
ceph pg ls-by-pool juicefs-data-rep | \
  awk '{print $NF}' | sort | uniq -c          # Rep 池同样检查
```

**2.2 判定**：
- 每 OSD 承载 PG 数偏离均值 ±20% 以内 → ✅ 均衡，继续。
- 偏离 >20% → ❌ 不均衡，调 `pg_num` 或重 crush 后重测。记录不均衡程度。
- 有 stuck PG → 先修 stuck PG 再继续。

### 步骤 3：Z3 — kernel CephFS+Rep 同集群差距复现

> 目标：在本集群（01-5 FSID）复现 01-4 的 kernel CephFS+Rep = 6718，或确认 4972 是稳定上界。

**3.1 前置**：
- 确认 CephFS mount 仍在 157 上（`/mnt/cephfs-kernel`），若已卸载则重新 mount：
```bash
# kernel CephFS mount（同 01-5 实验 B）
mount -t ceph 10.3.1.150:6789:/ /mnt/cephfs-kernel \
  -o name=admin,secretfile=/etc/ceph/ceph.client.admin.keyring
```
- 确认 `juicefs-data-rep` 池存在且有 01-5 layout 数据可复用。若无，先 layout：
```bash
fio --directory=/mnt/cephfs-kernel/test_dir \
    --name=storage_test \
    --filesize=1G --size=1G --bs=4M \
    --rw=write --numjobs=128 --fallocate=none \
    --direct=1 --ioengine=libaio --iodepth=128 \
    --group_reporting --end_fsync=1
```
- compact cooldown（layout 后必须）。

**3.2 执行 randread**（REPEAT=3）：
```bash
# 每轮跑前 drop_caches（157 + 3 slave）
fio --directory=/mnt/cephfs-kernel/test_dir \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log=/tmp/z3-cephfs-randread --log_avg_msec=1000
# 跑 3 轮，取稳态中位数
```

**3.3 判定**：
- 中位 ≥ 6000 → ✅ 接近 01-4 的 6718，"CephFS+Rep 达标"路径确认。记录最优值，供用户拍板"是否换 CephFS+Rep"。
- 中位 4972±200 → ❌ 差距未消除。与 Z1 结果交叉分析：
  - 若 Z1 确认 cluster_network 未生效 → 修复后再跑一次 Z3。
  - 若 Z1 确认已生效 → 4972 是当前集群稳定上界，需查 01-4 集群差异（Ceph 版本/PG 分布/OSD 状态）。
- 中位 < 4500 → ❌ 异常低。检查 CephFS MDS 状态、PG 状态、是否有 scrub/degraded。

### 步骤 4：Z4 — FUSE 内核侧 max_read 检查

> 目标：确认 FUSE 内核 `max_read` 是否为 128K（默认），若是则 256K I/O 被拆成 2 次 `/dev/fuse` 往返，可能是 slat 15× 的物理根因。

**4.1 检查当前值**（<2min）：
```bash
# 确认 JuiceFS 已 mount（ra0 口径）
mount | grep juice

# 检查 FUSE 内核参数
for d in /sys/fs/fuse/connections/*/; do
  echo "=== $d ==="
  echo "max_background: $(cat $d/max_background)"
  echo "congestion_threshold: $(cat $d/congestion_threshold)"
  echo "max_read: $(cat $d/max_read)"
  echo "max_write: $(cat $d/max_write)"
done
```

**4.2 记录基线**（先跑一次未修正的 randread 作对照）：
```bash
# 复用 01-2d layout 数据
fio --directory=/mnt/juicefs/test_dir \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log=/tmp/z4-baseline-randread --log_avg_msec=1000
# 记录 slat avg / clat avg / BW
```

**4.3 修正并复测**（若 max_read=131072）：
```bash
# umount JuiceFS
juicefs umount /mnt/juicefs

# 调大内核 FUSE 参数（需在 mount 前设，mount 时协商）
# 方法 1：通过 sysfs 设全局默认
echo 512 > /sys/fs/fuse/max_background 2>/dev/null || true
# 方法 2：通过 JuiceFS mount 选项传 FUSE 参数
# go-fuse 在 mount 时会协商 max_read/max_write
# 检查 JuiceFS 是否支持 -o max_read=N 选项

# remount JuiceFS（ra0 口径）
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 256K \
  --max-uploads 150 --cache-size 0 --max-readahead 0 \
  "${META}" /mnt/juicefs

# mount 后重新检查协商后的值
for d in /sys/fs/fuse/connections/*/; do
  echo "max_read: $(cat $d/max_read)"
  echo "max_background: $(cat $d/max_background)"
done
```

**4.4 复测 randread**（REPEAT=3）：
```bash
fio --directory=/mnt/juicefs/test_dir \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log=/tmp/z4-fixed-randread --log_avg_msec=1000
# 对比 slat avg 变化
```

**4.5 判定**：
- `max_read` 修正前=128K、修正后=256K 且 slat 下降 ≥30% → ✅ **物理根因找到**。256K I/O 不再被拆包，dispatch 延迟减半。B 线方向根本改变。
- `max_read` 修正前已=256K → ❌ 非 max_read 问题，B 线按原计划执行。
- `max_read` 修正后 slat 无变化 → ❌ dispatch 延迟非由 max_read 导致。回滚 remount。

**4.6 附带检查**：go-fuse 版本和内核版本
```bash
grep go-fuse /home/lilingfeng/project/juicefs/go.mod
uname -r    # 157 内核版本，若 ≥6.1 则 io_uring FUSE 可行（B1b 调研用）
```

### 步骤 5：Z5 — librados 客户端限流参数核查

> 目标：确认 `objecter_inflight_op_bytes`（默认 100MB）是否在限流。当前 fio 128job×iodepth128=16384 并发，每 op 256K，理论峰值在途 4GB，远超 100MB 默认 40 倍。

**5.1 检查当前值**（<2min）：
```bash
ceph config get client objecter_inflight_ops
ceph config get client objecter_inflight_op_bytes

# 同时检查 157 ceph.conf
grep objecter /etc/ceph/ceph.conf 2>/dev/null || echo "未在 ceph.conf 中设置"

# 检查 JuiceFS 进程实际生效值（若 JuiceFS 有独立覆盖）
# JuiceFS 走 cgo 调 librados，可能用 rados_connect 时传参
grep -r "objecter_inflight" /home/lilingfeng/project/juicefs/pkg/object/ 2>/dev/null || echo "JuiceFS 源码未显式设置 objecter 参数"
```

**5.2 记录基线**（Z4 步骤 4.2 已有，可复用）：
- 若 Z4 已跑过 randread baseline，直接用其 slat/clat 作为对照。
- 若 Z4 未跑，则补跑一次（同 Z4 步骤 4.2）。

**5.3 修正并复测**（若确认是默认 100MB）：
```bash
# 临时调大限流阀
ceph config set client objecter_inflight_op_bytes 1073741824   # 1GB
ceph config set client objecter_inflight_ops 8192               # 8K ops

# 注意：client 侧配置需重启 JuiceFS 进程才生效
juicefs umount /mnt/juicefs
juicefs mount -d \
  --storage ceph --bucket "ceph://${POOL}" \
  --access-key ceph --secret-key "${CEPHX}" \
  --block-size 256K \
  --max-uploads 150 --cache-size 0 --max-readahead 0 \
  "${META}" /mnt/juicefs
```

**5.4 复测 randread**（REPEAT=3）：
```bash
fio --directory=/mnt/juicefs/test_dir \
    --name=storage_test \
    --filesize=1G --size=1G \
    --bs=256k --rw=randread \
    --ioengine=libaio --iodepth=128 --numjobs=128 \
    --direct=1 --fallocate=none --openfiles=128 \
    --group_reporting --time_based --runtime=180 \
    --write_bw_log=/tmp/z5-fixed-randread --log_avg_msec=1000
# 对比 slat 变化
```

**5.5 判定**：
- slat 下降 ≥30% → ✅ **隐藏限流找到**。01-4 §5.4 的"FUSE dispatch 5+ms 是架构固有"结论需修正——部分延迟来自 objecter 客户端排队，非 FUSE dispatch。B 线优先级改变。
- slat 无变化 → ❌ objecter 限流非瓶颈（可能 JuiceFS 已有独立覆盖或 100MB 足够）。明确记录排除。
- 无变化但有其他 slat 组成变化（如 clat 下降但 slat 不变）→ 记录并分析。

### 步骤 6：Z6 — EC pool fast_read 开关

> 目标：验证 EC pool `fast_read=true` 能否消除 01-5 §4.1 观察的"冷启动-暖缓存"波动模式（r1=3191 vs r2/r3=4600+，+44%）。

**6.1 记录基线**（01-5 已有，可复用）：
- 01-5 EC randread -t1024：r1=4600(cold=3191), r2=4664, r3=4600
- 01-5 EC randread -t4096：r1=4664(cold=3233), r2=4664, r3=4580

**6.2 开启 fast_read**：
```bash
# 在 EC 池上开启（若担心生产池，可先在诊断池试）
ceph osd pool get juicefs-data fast_read          # 确认当前值
ceph osd pool set juicefs-data fast_read true
ceph osd pool get juicefs-data fast_read          # 确认已生效
```

**6.3 复测 rados bench**（REPEAT=3，重点看 r1 是否不再冷）：
```bash
# -t1024
rados bench -p juicefs-data 60 rand --pool-ops -t 1024
# 跑 3 轮

# -t4096
rados bench -p juicefs-data 60 rand --pool-ops -t 4096
# 跑 3 轮
```

**6.4 判定**：
- r1 ≈ r2 ≈ r3（CV <5%）→ ✅ 冷启动-暖缓存波动被消除。尾延迟拖尾（某 shard 偶发慢）是冷启动根因。fast_read 有效。
- 中位数提升 ≥10% → fast_read 不仅消波动还提性能。纳入生产（需权衡多读 M=2 份冗余 shard 的 IOPS/网络代价）。
- 中位数反降 → ❌ IOPS-bound 场景下多读 2 份冗余 shard 反而加重 IOPS 压力。回滚 `fast_read false`。
- 无变化 → ❌ 冷启动波动非尾延迟导致。回滚。

**6.5 回滚**（若无效）：
```bash
ceph osd pool set juicefs-data fast_read false
```

---

## 四、交付物

```
results/prod-02-1-zero-check-<YYYYMMDD-HHMMSS>/
├── commands.sh                          # 完整可执行命令记录
├── env-snapshot.txt                     # HEALTH_OK + 6 OSD up + 双网 + 池配置
├── z1-cluster-network/
│   ├── config-show-osd0.txt              # ceph config show osd.0
│   ├── ss-tlnp-ceph.txt                  # ss -tlnp | grep ceph
│   ├── osd-metadata.txt                  # ceph osd metadata
│   ├── tcpdump-cluster-nic.txt           # tcpdump -i enp139s0f1np1
│   ├── tcpdump-public-nic.txt            # tcpdump -i enp139s0f0np0
│   └── ping-cluster-vs-public.txt        # ping RTT 对照
├── z2-pg-balance/
│   ├── osd-df-tree.txt                  # ceph osd df tree
│   ├── pg-dump-stuck.txt                # ceph pg dump_stuck
│   └── pg-per-osd-ec.txt                # EC 池 PG per OSD 统计
│   └── pg-per-osd-rep.txt               # Rep 池 PG per OSD 统计
├── z3-cephfs-rep-reproduce/
│   ├── randread-r1.txt                   # fio 全文输出
│   ├── randread-r2.txt
│   ├── randread-r3.txt
│   ├── randread-r1_bw.log ... r3_bw.log # per-job bw_log（128 份/轮）
│   └── summary.md                        # 3 轮中位数 + vs 01-4/01-5 对照
├── z4-fuse-max-read/
│   ├── fuse-kernel-params-baseline.txt   # 修正前 FUSE 内核参数
│   ├── fuse-kernel-params-fixed.txt      # 修正后 FUSE 内核参数
│   ├── randread-baseline-r{1,2,3}.txt     # 修正前 fio（3 轮）
│   ├── randread-baseline-r{1,2,3}_bw.log # per-job bw_log
│   ├── randread-fixed-r{1,2,3}.txt       # 修正后 fio（3 轮）
│   ├── randread-fixed-r{1,2,3}_bw.log
│   ├── go-fuse-version.txt              # go-fuse 版本
│   ├── kernel-version.txt               # uname -r
│   └── summary.md                        # slat 前后对比 + 判定
├── z5-objecter-throttle/
│   ├── objecter-config-baseline.txt      # 修正前 objecter 配置
│   ├── objecter-config-fixed.txt         # 修正后 objecter 配置
│   ├── randread-fixed-r{1,2,3}.txt       # 修正后 fio（3 轮）
│   ├── randread-fixed-r{1,2,3}_bw.log
│   └── summary.md                        # slat 前后对比 + 判定
├── z6-fast-read/
│   ├── fast-read-baseline.txt            # 01-5 基线（引用）
│   ├── ec-t1024-fast-r{1,2,3}.txt        # fast_read=true 3 轮
│   ├── ec-t4096-fast-r{1,2,3}.txt
│   └── summary.md                        # r1 vs r2/r3 波动对照 + 判定
└── summary.md                            # 6 项检查总判定 + 对 02 计划的影响
```

**输出分析报告（强制）**：完成后建 `doc/perf-report/02-1-zero-check-report.md`，正文含：
- 6 项检查的执行结果与判定
- Z4/Z5 如命中：对 01-4 §5.4 / 01-5 §十一 结论的影响评估
- Z3 如复现 6718：给用户的"CephFS+Rep 达标"路径建议
- 对 02 计划后续 A/B 线方向的修正建议
- summary.md 中 6 项检查的量化数据表

不写 perf-analysis/（只放计划文档）；实测追加 `doc/deploy-log/results-table.md`。

---

## 五、通用注意事项

> 引用 `TASK-BOOK-AUTHORING-GUIDE.md` §二通用注意事项六条。本任务以诊断为主，但仍须遵守：

1. **数据统计口径**：Z3/Z4/Z5 的 fio 测试必须用 §8.3 稳态中位数（截开头 1/4），加 `--write_bw_log --log_avg_msec=1000`，保留 per-job bw_log 全部 128 份。**禁止**用 bw_log×numjobs 外推。
2. **冷态净化**：Z3/Z4/Z5 每轮跑前必须 drop_caches（157 + 3 slave）。
3. **后端干净态**：Z3 layout 后必须 compact cooldown 至 `compact_running=0`。Z6 rados bench 前确认 EC 池干净（`rados df -p juicefs-data`）。
4. **环境前置**：每项检查前 `ceph health` = HEALTH_OK。
5. **记录规范**：`commands.sh` 必须含完整命令；每项检查的输出文件按目录结构保存。
6. **REPEAT=3 取中位数**：Z3/Z4/Z5 的 fio 和 Z6 的 rados bench 均 3 轮，取中位数（第 2 大值），不取平均、不挑轮次。

---

## 六、红线汇总

### 6.1 本任务特有红线

- **R1（配置变更可回滚）**：Z4/Z5/Z6 的所有配置变更（FUSE remount、ceph config set、pool set）必须在变更前做 `ceph osd dump` 快照。若修正无效，必须回滚到变更前状态再进行下一项检查。
- **R2（变量隔离）**：Z4 和 Z5 不能同时修正（否则无法区分哪项生效）。**必须串行**：Z4 修正+复测 → 回滚 → Z5 修正+复测 → 回滚。若两者都有效，再叠加测试。
- **R3（Z6 不改 EC 池生产属性）**：`fast_read` 测试完必须回滚为 `false`（若无效）或记录供用户拍板（若有效），**不擅自保持 `true`**。
- **R4（Z3 不破坏 JuiceFS 挂载）**：kernel CephFS mount 在 `/mnt/cephfs-kernel`，与 JuiceFS `/mnt/juicefs` 独立。测试前确认两者不冲突（不同挂载点、不同池）。Z3 测试期间 JuiceFS 可保持 mount 但不跑负载。
- **R5（157 红线）**：禁动 157 内核 / 100GbE 网卡 / RoCE / md0 / WekaIO 路径。Z4 的 FUSE remount 和 Z5 的 JuiceFS remount 不触碰内核/网卡，但须确认 WekaIO 不受影响。

### 6.2 通用红线（复述）

- 不重启节点。
- 不破坏生产 EC4+2 池（Z6 `fast_read` 测试后回滚）。
- 所有 OSD 配置变更前做 `ceph osd dump` 快照。
- cephx 等安全相关配置不在本任务范围（A2.1 才做）。
- BeeGFS 与本测试错峰用盘。

---

## 七、执行顺序与依赖关系

```
步骤 0：环境前置检查 ──── 必须先做
     │
     ├── Z1 cluster_network 根因诊断（纯诊断，无依赖）
     ├── Z2 PG 分布均衡性（纯诊断，无依赖）
     │   ↑ Z1/Z2 可并行
     │
     ▼
Z3 kernel CephFS+Rep 复现 ──── 依赖 Z1 结果（若 Z1 发现 cluster_network 未生效，先修再跑 Z3）
     │
     ▼
Z4 FUSE max_read 检查 ──── 依赖 JuiceFS mount（确保 Z3 的 CephFS 测试已完成，避免 mount 冲突）
     │   │
     │   └─ 修正 → 复测 → 回滚（R2 要求）
     │
     ▼
Z5 objecter 限流检查 ──── 必须在 Z4 回滚后执行（R2 变量隔离）
     │   │
     │   └─ 修正 → 复测 → 回滚（R2 要求）
     │
     ▼
Z6 EC pool fast_read ──── 与 Z3-Z5 独立（rados bench 直测，不走 fio/JuiceFS）
     │
     ▼
汇总 → summary.md + 分析报告
     │
     ▼
据结果更新 02 计划决策树：
  - Z1 未生效 → A1 预热复测暂停，先修根因
  - Z4 命中 → B 线优先修 FUSE 配置，降低 B1a/B1b 优先级
  - Z5 命中 → 01-4 §5.4 结论修正，B 线优先级重排
  - Z3 复现 6718 → 给用户"CephFS+Rep 达标"拍板选项
  - Z6 有效 → A4 降级，fast_read 纳入生产候选
```

> **关键依赖**：Z4 和 Z5 **必须串行 + 各自回滚**（R2），不能叠加测试。若两者各自有效，可在后续任务书（02-2）中做叠加验证。Z6 与 Z3-Z5 独立，可穿插执行。

---

## 八、总结

本任务书的核心目的是：**用最低成本（<2h）排除 6 类基础设施隐藏问题**，确保 02 阶段后续 A/B 线调优不会建立在"cluster_network 零流量 / PG 不均衡 / FUSE max_read 不匹配 / objecter 限流 / 尾延迟拖尾"等干扰项上。

完成后产出：
- 6 项检查的判定表（✅/❌ + 量化数据）
- 若 Z4/Z5 命中：对 01-4 §5.4 / 01-5 §十一 结论的影响评估
- 若 Z3 复现 6718：给用户的"CephFS+Rep 达标"路径建议
- 对 02 计划后续 A/B 线方向的修正建议

**用户的决策需要这份诊断支撑**：
- Z4/Z5 命中 → B 线从"攻架构固有延迟"转向"改配置"，大幅降低调优成本
- Z3 复现 6718 → 用户可拍板"换 CephFS+Rep"（空间效率换达标）
- Z1 cluster_network 未生效 → A1 预热复测暂停，先修根因
- Z6 fast_read 有效 → 后端 EC 冷启动波动消除，A 线更干净
