# Ceph+JuiceFS 性能测试指导 Skill

> 目的：保证测试数据可靠、可追溯、可复现。
> 创建：2026-06-25
> 背景：测试中因 BlueFS DB 读停滞导致写性能从 108MB/s 降到 38-54MB/s，产生不可靠数据。

---

## 一、测试前检查清单

### 1.1 集群健康检查（必须）

每次启动测试脚本前，手动确认：

```bash
sudo ceph health          # 必须 HEALTH_OK
sudo ceph osd tree        # 所有 OSD 必须 up
sudo ceph osd stat        # 确认 in 数量正确
```

如果非 HEALTH_OK，**不要开始测试**。先修复问题（重启 OSD、等恢复等）。

### 1.2 BlueFS DB Stall 检查

```bash
sudo ceph health detail | grep -i bluefs
# 如果有 stalled read in db device of BlueFS，需要重启对应 OSD
```

### 1.3 OSD Compaction 状态检查（admin socket 直采）

高强度写后（如 128G layout），RocksDB LSM tree 可能膨胀，compaction 积压会导致 BlueFS stall。
**restart OSD 不会清除积压**——LSM tree 状态在磁盘上，restart 只清内存缓存，compaction 在 restart 后继续但不加速。

使用 admin socket 直采（不用 cephadm shell，后者开销大且输出混入日志）：

```bash
FSID=$(sudo ceph fsid)
# OSD 映射：node1(.11)=osd0,1 / node2(.13)=osd2,3 / node3(.14)=osd4,5
# 在对应 OSD 节点上执行：
for osd_id in 0 1 2 3 4 5; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  echo "--- osd.${osd_id} ---"
  sudo ceph --admin-daemon "$ASOK" perf dump | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get(rocksdb,{})
bs=d.get(bluestore,{})
print( compact_queue_len:, r.get(compact_queue_len,N/A))
print( compact_running:, r.get(compact_running,N/A))
kv=bs.get(kv_sync_lat,{})
print( kv_sync_lat avg:, round(kv.get(avgtime,0)*1000,3), ms)
"
done
```

**干净态判据**：
- `compact_queue_len` = 0（无等待 compaction）
- `compact_running` = 0（无进行中 compaction）
- `kv_sync_lat avg` < 2ms（无 KV 压力）

**如果积压未消除，强制 compaction**：

```bash
# 对每个 OSD 执行强制 compaction（秒级完成）
for osd_id in 0 1 2 3 4 5; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  echo "compacting osd.${osd_id}..."
  sudo ceph --admin-daemon "$ASOK" compact
done
# 轮询直到全部 compact_running=0
```

> ⚠️ `compact` 命令会短暂增加 OSD 负载（WARNING: Compaction probably slows your requests），
> 但通常秒级完成。完成后 OSD 处于真正的干净态，比 restart OSD 可靠得多。

### 1.4 磁盘空间检查

```bash
sudo ceph df             # 确认可用空间充足
df -h /data              # 客户端缓存目录空间
```

### 1.5 网络检查

```bash
cat /sys/class/net/eno1/mtu   # 确认 MTU 设置
ip link show eno1             # 确认链路状态 up
```

---

## 二、测试中的健康检查（自动）

### 2.1 健康检查库

所有测试脚本 **必须** source 健康检查库：

```bash
source tests/lib/ceph-health-check.sh
```

### 2.2 检查点位置

在以下位置调用 `check_ceph_health`：

| 检查点 | 位置 | 说明 |
|--------|------|------|
| 测试开始前 | 环境快照之后 | 确认初始状态 OK |
| 每个 fio 命令前 | run_seq/run_rand 函数内 | 防止集群异常时继续跑 |
| layout 写完后 | layout 完成后 | 检查写后状态 |
| 测试结束后 | 收尾前 | 记录终态 |

### 2.3 检查行为

- `check_ceph_health`：非 OK 时等待最多 120s，超时则 **abort 整个测试**
- `check_ceph_health_quick`：只检查不等待，用于快速状态记录

### 2.4 自定义等待时间

```bash
export CEPH_HEALTH_WAIT_SEC=300  # 等 5 分钟
```

---

## 三、Layout 后的 Cooldown（重要）

### 3.1 问题

128G layout 写入会产生大量 RocksDB SST 文件，compaction 跟不上会导致 BlueFS DB 读停滞。

### 3.2 规避方法

layout 写完后，**不要立即开始随机测试**，确保 compaction 完成：

```bash
# layout 写完后
log "## Layout cooldown: 等待 compaction 完成"

# 方法 1（推荐）：强制 compact + 轮询确认
for osd_id in 0 1 2 3 4 5; do
  ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
  sudo ceph --admin-daemon "$ASOK" compact
done
# 轮询直到全部 compact_running=0 且 compact_queue_len=0
while true; do
  all_done=true
  for osd_id in 0 1 2 3 4 5; do
    ASOK="/var/run/ceph/${FSID}/ceph-osd.${osd_id}.asok"
    running=$(sudo ceph --admin-daemon "$ASOK" perf dump | python3 -c "import sys,json;print(json.load(sys.stdin).get(rocksdb,{}).get(compact_running,1))")
    [ "$running" != "0" ] && all_done=false
  done
  $all_done && break
  sleep 5
done

# 方法 2（简单）：等 health 恢复 OK + sleep
sleep 120
check_ceph_health "after layout cooldown"
```

> **重要**：restart OSD **不能**替代 compact。restart 不清除磁盘上的 LSM tree 积压，
> compaction 在 restart 后继续但不加速。必须用 `compact` 命令或等待自然 compaction 完成。

### 3.3 推荐等待时间

| 写入量 | 建议等待 |
|--------|---------|
| < 10G | 30s |
| 10-50G | 60s |
| 50-128G | 120-300s |
| > 128G | 300s+ |

---

## 四、WAL/DB 配置说明

### 4.1 当前环境问题

所有 6 个 OSD 的 `db=none wal=none`，即 WAL/DB 和 Data 共用同一块 SSD 的同一个 LV。长时间高强度单流写 + OSD 已有 compaction 积压时会导致：
- RocksDB compaction 和 Data IO 争抢磁盘带宽
- DB 读延迟飙升 → BlueFS DB 读停滞告警 → 写性能降 50%+

> **订正（2026-07-06）**：此 stall 是**可管理现象、非硬瓶颈**——干净态（`compact` 后积压清零）下 128G 多 job 写零 stall，触发需"单流持续写 + 已有积压"。用 §3.2 的 `compact` + cooldown 即可规避。独立 NVMe 为可选优化，非必须（见 `doc/perf-analysis/11_1-step2-stall-compaction-branch.md`）。
>
> **进一步坐实（2026-07-07，净态对照 `results/stall-repro-memdisk-20260706/`）**：stall 根因是**多轮实验累积的 BlueFS 残余状态**，不是当前测试负载本身。净态对照 G1/G2/G3（从干净态起跑，分别叠加"无 / rados / rados+seqwrite"前置负载，完整复刻此前触发 stall 的负载序列）**三组自身 fio 窗口内全部零 stall**；只有在多轮实验累积、未 `compact` 的残余态下才复现出 stall。**结论：`compact` 清除残余状态即可完全防护，独立 WAL/DB（内存盘/NVMe）在有 compact 纪律的前提下不需要（P5 维持"不需要"）。**

### 4.2 物理设备 vs 逻辑设备

| 方案 | 空间隔离 | I/O 隔离 | 效果 |
|------|---------|---------|------|
| 逻辑设备（同盘不同 LV） | 有 | 无 | DB 有独立空间，但 compaction IO 仍争抢 |
| 物理设备（NVMe + HDD） | 有 | 有 | 完全隔离，根本解决 |

### 4.3 测试环境规避

当前环境无法加独立物理设备，只能通过以下方式规避：
1. layout 后加 cooldown + `compact` 命令确保 compaction 完成（见 §3.2）
2. 每项 fio 前检查 `compact_queue_len=0` + `compact_running=0`（见 §1.3）
3. 避免连续长时间高压力单 job 写（分段写、中间 `compact`）
4. 如果再次出现 BlueFS stall，用 `compact` 命令清除积压（restart 不够）

---

## 五、测试口径规范

### 5.1 冷态基线

- `--cache-size 0`（无客户端缓存）
- 每项跑前 `echo 3 > /proc/sys/vm/drop_caches`
- 不 drop OSD cache（模拟生产 OSD 自然状态）
- 随机项 REPEAT=3 取均值
- destroy + reformat 确保干净环境

### 5.2 暖态基线

- `--cache-size 102400`（100G，JuiceFS 默认）
- `--max-readahead 0`（关闭预读，或按测试目的调整）
- 不 drop_caches（客户端 + OSD 都不 drop）
- 不 destroy/reformat（复用冷态基线的卷和 128G 布局）
- 顺序项各 1 次；随机项 7 轮看收敛趋势
- r1 从冷 cache 开始（清空 cache 目录）

### 5.3 数据记录要求

每项 fio 测试必须保存：
- fio 完整原始输出（不是只记带宽）
- 挂载参数
- 日期时间
- cache 大小（暖态）
- NIC RX 字节量（用于交叉验证带宽）

### 5.4 切换 OSD config 模式后必须等集群完全恢复再测（重要）

做 HDD/SSD 对比（改 `bluestore_prefer_deferred_size` / `throttle_cost_per_io` 等 OSD 全局参数）时，
改参数通常需 **重启相关 OSD** 生效。**OSD 重启后集群会进入退化态**（`HEALTH_WARN slow ops` + `Degraded data redundancy: N pgs degraded`），
此时后端带宽会被恢复 I/O 严重拖累，测出的数据不可用。

> **教训（2026-07-06/07）**：`write-jfs-path` 与 `stall-repro-memdisk` 两轮的 SSD 侧（A2/A4）都在
> 冷重启后 ~3min 的退化态就开测，A2 rados 仅测得 27.6 MB/s（干净态应 ~72），**SSD/deferred 数据全部作废**，
> 导致"deferred 端到端收益"至今拿不到可靠对比。

**切模式后开测前，必须（逐条落盘确认）**：
1. `ceph health detail` = **HEALTH_OK**（不是 WARN）；
2. **`degraded` pgs 清零**（`ceph -s` 无 `Degraded data redundancy`，无 `pgs degraded`）；
3. 所有 OSD `up`/`in`（`ceph osd tree`）；
4. `iostat -x 1` 观察各节点 sdb 几秒确认 `%util≈0`（无后台恢复/compaction I/O）；
5. 起跑前照例 `compact` 到 `compact_queue_len=0`（见 §1.3/§3.2）。

经验上冷重启后需等 **10+ min** 恢复才稳。**HDD/SSD 两组必须在同等干净态下测，否则对比无效。**

### 5.5 rados bench 短测均值含缓冲暂态，不可当"后端稳态写能力"（重要）

`rados bench 60 write -b 256K -t 16` 的逐秒曲线是**"缓冲加速→跌落到稳态"的两段式**，不是随机抖动：

```
sec  cur MB/s
 1-17   ~112      ← BlueStore write buffer / RocksDB memtable / deferred 队列未满，写进内存就返回，吞吐虚高（近网卡线速）
 18     64  ↓     ← 缓冲填满，断崖
 19-60  ~48-53    ← 被磁盘真实落盘 + compaction/flush 节流，这才是持续稳态真值
```

实例（`results/clean-deferred-retest-20260707/A1/rados-bench-r1.txt`）：Max 112.75 / Min 44.5 / **Stddev 27.9 / 均值 68.45**——巨大波动**全部来自这一次缓冲跌落**，前 17s 稳定期本身 stddev 极小。

**后果与纪律**：
- **60s 短测的 `Bandwidth (MB/sec)` 均值偏高且不稳**（缓冲暂态占了近 1/3 时长）；r1（冷缓冲）往往明显高于 r2/r3（缓冲已被 r1 占用、暂态更短）。
- **绝对值不可当"后端稳态写能力"**。要测稳态：**用长测（≥300s）让稳态段主导，或截尾只算跌落后的后段（如后 40s cur MB/s 均值）**。
- **60s 短测仅可做「同口径相对对比」**（如 HDD vs SSD 同样都有缓冲暂态、大致抵消，横向差值仍可用）。
- ⚠️ **历史踩坑**：`cold-baseline-recheck-20260706` 那个孤立单次 rados 72.3 MB/s（曾被当作"deferred +23% 后端收益"依据）很可能就是"60s 短测恰好缓冲暂态占比更大"的一次采样；干净态 3 轮均值重测（`clean-deferred-retest-20260707`）HDD 57.4 vs SSD 57.9 = +0.9%，**+23% 不可复现**（另一层原因是上轮改 OSD crush class 引入 PG 重映射假象，见 `doc/perf-analysis/11_1-step2-stall-compaction-branch.md`）。

### 5.6 JuiceFS 写类 fio 平均 BW 含客户端写缓冲虚高，达标值取 fio 瞬时带宽的稳态段中位数（重要）

§5.5 是**后端 OSD/BlueStore 层**的缓冲暂态；JuiceFS **客户端层**有同一类问题，且更严重——写类 fio 报的**平均**带宽会**远超网卡物理上限**，是假象：

```
JuiceFS randwrite（fio direct=1 iodepth=128 numjobs=128）：
  测试开头几秒：写进客户端内存写缓冲即返回（fio 以为写完），瞬时 bw 冲到 485 MiB/s（buf 从 8M 涨到 600M）
  缓冲填满后：跌落到真实稳态，受网卡/后端限
  → fio 平均 BW = 127 MB/s（121 MiB/s），比千兆网卡线速（~118-123）还高 = 物理不可能 = 缓冲暂态把均值拉高的假象
```

实例（`results/memdisk-fullretest-128g-20260710/A/fio-randwrite-r1.txt`）：`bw min=62.8 max=485 avg=117.7 MiB/s`——min/max 跨度 62→485 说明是"缓冲加速→跌落"两段式，`avg` 被开头的 485 拉高；`clat 平均 26 秒、>=2000ms 占 96.75%`——IO 全积压在写缓冲/上传队列，均值毫无参考价值。

**根因**：JuiceFS 是 FUSE 文件系统，`fio --direct=1` 只绕开**内核页缓存**，绕不开 **JuiceFS 自己的写缓冲（buffer / max-uploads 上传队列）**。写类平均 BW 都会被开头缓冲瞬时吸入拉高。

**纪律 —— 从"有效数据带宽"出发（验收口径就是应用有效读写字节速率）**：
1. **达标值 = fio 有效数据带宽的稳态段中位数**，不是 fio 全程平均、更不是 max。（fio 平均/最大被缓冲暂态污染）
2. **采法**：fio 加 `--write_bw_log=<name> --log_avg_msec=1000`（每秒一个瞬时带宽点），测完对逐秒序列**截掉开头缓冲暂态段**，取**中位数**。读类同理用 `--read_bw_log`。可配合**拉长 runtime** 让稳态主导。
3. **❌ 绝不能拿 object put/get 当达标值**：object put/get 是**落后端的物理带宽（含写/读放大 + EC 1.5×）**，不是有效数据带宽。若 object put=100 但有 2× 放大，有效数据只有 50，其实**没达标**——用 put 替代 fio 会把放大"洗白"，得出假达标。
4. **放大单独算并报告**：写放大 = object put稳态 / fio有效写稳态；读放大 = object get稳态 / fio有效读稳态。三者关系应满足 **fio有效 ≤ 客户端网卡 ≤ object（放大后）**，三个一起采才能同时看清"有效带宽达标没"与"放大多少"。
- ⚠️ **红线**：任何 fio 平均 BW > 124 MB/s（超千兆网卡）必是缓冲暂态假象，**不认**，改取 fio 瞬时带宽稳态中位数。汇报外部/领导前务必换成稳态真实值，否则"127 MB/s 超网卡"一眼假会拖累整批数据可信度。
- ⚠️ **本轮教训**：`memdisk-fullretest-128g-20260710` 未开 `--write_bw_log`，导致无法回溯截尾取稳态中位数，只能重测补采。**后续所有 fio 测试必须开 bw_log。**

---

## 六、测试中遇到的问题及处理方法

### 6.1 BlueFS DB 读停滞

**现象**：`ceph health` 显示 `DB_DEVICE_STALLED_READ_ALERT`

**原因**：WAL/DB 和 Data 共用物理盘，长时间高强度写导致 RocksDB LSM tree 膨胀，compaction 跟不上，DB 读延迟飙升。

**影响**：写性能从 108MB/s 降到 38-54MB/s（约 50%+），数据不可靠。

**处理**：
```bash
# 重启有告警的 OSD
sudo ceph orch daemon restart osd.X
# 等待 OSD 恢复 up 且 health OK
sleep 30
sudo ceph health
```

**规避**：
- layout 后加 cooldown + `compact` 命令确保 compaction 完成（见第三节）
- 每项 fio 前检查 ceph health + `compact_queue_len`（见 §1.3）
- **restart OSD 不能清除 compaction 积压/残余状态**——必须用 `compact` 命令或等待自然完成
- stall 的触发条件（2026-07-07 净态对照坐实）：**多轮实验累积的 BlueFS 残余状态 + 高并发写入**，不是当前负载本身；干净态（`compact` 后）即使复刻此前触发 stall 的完整负载序列也零 stall
- **每轮/每格测试前 `compact` 清残余状态是最有效的防护**（比控制负载模式更根本）
- 多 job 分散写给 OSD compaction 喘息空间，不易触发 stall
- 独立 NVMe 做 DB/WAL 为**可选优化**（非必须）：干净态（compact 后 `compact_queue_len=0`）下 128G 多 job 写零 stall，`compact` 命令即可管理积压；仅在无法控制写入模式且 compaction 长期跟不上时，独立 NVMe 才有必要（详见 `doc/perf-analysis/11_1-step2-stall-compaction-branch.md`）

### 6.2 OSD down

**现象**：`ceph osd tree` 显示某 OSD 为 down

**处理**：
```bash
sudo ceph orch daemon restart osd.X
# 等待 up + PG 恢复 active+clean
sleep 30
sudo ceph health
```

### 6.3 PG degraded/inactive

**现象**：重启 OSD 后 PG 处于 degraded/inactive/peering

**处理**：等待自动恢复。`ceph health` 恢复 OK 前不要继续测试。

### 6.4 JuiceFS mount 失败

**现象**：mount 返回错误或 mountpoint 检查失败

**处理**：
```bash
juicefs umount /mnt/juicefs 2>/dev/null || fusermount -uz /mnt/juicefs 2>/dev/null
sleep 5
# 检查是否有残留进程
ps aux | grep juicefs | grep -v grep
# 重新挂载
juicefs mount -d --cache-size 0 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs
```

### 6.5 juicefs destroy 超时

**现象**：`juicefs destroy` 长时间无响应（>10分钟）

**原因**：需要删除大量 Ceph 对象（128G layout = 数千个 4M 对象）

**处理**：耐心等待。如果超过 30 分钟仍未完成，检查 Ceph RGW 状态：
```bash
sudo ceph orch ps | grep rgw
```

### 6.6 fio 进程残留

**现象**：fio 进程未正常退出，占用文件句柄

**处理**：
```bash
sudo kill -9 $(pgrep -x fio)
sleep 2
```

---

## 七、测试结果可靠性判断标准

| 条件 | 判定 |
|------|------|
| ceph health 全程 OK | 数据可靠 |
| ceph health 中途非 OK 但自动恢复 | 该项数据标记为 "recovered"，仅供参考 |
| ceph health 中途非 OK 且超时 abort | 数据不可靠，需要重测 |
| fio 结果明显偏低（如写 <50MB/s） | 检查是否 BlueFS stall，重测 |
| 暖态 7 轮不收敛（变化 >10%） | 说明环境不稳定，需要排查 |
| NIC RX 与 fio 带宽严重不符 | 检查是否有异常网络流量或缓存命中 |

---

## 八、已修改的测试脚本

以下脚本已加入健康检查：

| 脚本 | 检查点 |
|------|--------|
| `tests/bench-baseline-rerun.sh` | seqread prep / 每个 run_seq / 每个 run_rand / layout 前 |
| `tests/bench-warm-baseline-noRA.sh` | seqread prep / 每个 run_seq / 每个 run_rand |
| `tests/bench-warm-baseline.sh` | 同上 |
| `tests/lib/ceph-health-check.sh` | 健康检查库（被上面三个脚本 source） |

---

## 九、生产环境部署建议

详见 `ceph-production-deployment-notes.md`

核心要点：
1. 每台 Ceph 节点配独立 NVMe SSD 做 DB/WAL（**可选优化**：可显著缓解高强度单流写下的 compaction 争抢；若能通过定期 `compact` + 控制写入模式管理，非硬性必须）
2. Public/Cluster 网络分离
3. MTU 9000
4. EC 4+2（3节点）或 8+4（6+节点）
5. 监控告警：BlueFS stall / OSD down / PG degraded / 容量

---

## 十、测试命令记录规范（必须遵守）

### 10.1 问题

summary.txt 中只记录了结果摘要（如 `seqread: READ=79.2`），但：
- 挂载命令参数不完整（如 warm-baseline 没记录 --cache-size）
- fio 命令没记录（只记了 name 和结果）
- juicefs format 命令没记录
- 无法从 summary.txt 复现测试

### 10.2 要求

每个测试结果目录 **必须** 包含一个 `commands.sh` 文件，记录：

1. **juicefs destroy** 的完整命令
2. **juicefs format** 的完整命令（含所有参数：--storage, --bucket, --access-key, --block-size 等）
3. **juicefs mount** 的完整命令（含所有参数：--cache-size, --max-readahead, --max-uploads, --cache-dir 等）
4. **每个 fio 测试** 的完整命令（含所有参数：--bs, --rw, --size, --numjobs, --ioengine, --iodepth, --direct 等）
5. **环境特殊操作**（如 drop_caches, bucket rm 等）

### 10.3 格式

```bash
#!/bin/bash
# 完整命令记录：<测试名称>
# 日期：<日期>

# ---- 格式化卷 ----
juicefs format ...

# ---- 挂载 ----
juicefs mount ...

# ---- 顺序测试 ----
fio --name=seqread ...

# ---- 随机测试 ----
fio --name=randread ...
```

### 10.4 生成时机

- 测试开始前或测试完成后立即生成
- 不依赖脚本自动记录（脚本可能漏参数），手写确保完整
- 后续测试脚本也应该在 summary.txt 中直接写入完整命令

---

## 十一、文件命名规范

### 11.1 summary 文件

测试结果摘要文件使用 **summary.md**（不是 summary.txt），因为内容是 Markdown 格式。

### 11.2 完整文件列表

每个测试结果目录应包含：

| 文件 | 说明 |
|------|------|
|  | 测试结果摘要（Markdown 格式） |
|  | 所有完整命令记录（format/mount/fio） |
|  或  | 环境快照 |
|  | 挂载日志 |
|  | 格式化日志 |
|  | 销毁日志（如有） |
|  | 各项 fio 原始输出 |
