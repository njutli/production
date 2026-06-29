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

### 1.3 OSD Compaction 状态检查

高强度写后（如 128G layout），RocksDB LSM tree 可能膨胀。检查方法：

```bash
# 检查每个 OSD 的 RocksDB 状态
for osd in 0 1 2 3 4 5; do
  echo "--- osd. ---"
  sudo ceph daemon osd. perf dump 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
b=d.get('bluestore_rocksdb',{})
print('compact:', b.get('compact_sum','N/A'), 'compact_count:', b.get('compact_count','N/A'))
o=d.get('osd',{})
print('op_latency:', o.get('op_latency',{}).get('sum','N/A'))
"
done
```

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

layout 写完后，**不要立即开始随机测试**，等待 compaction 完成：

```bash
# layout 写完后
log "## Layout cooldown: 等待 compaction 完成"

# 方法 1：等 health 恢复 OK（最少 60s）
sleep 60
check_ceph_health "after layout cooldown"

# 方法 2（更精确）：轮询 RocksDB compact 指标
# 等到 compact_sum 不再增长（compaction 停止）
```

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

所有 6 个 OSD 的 `db=none wal=none`，即 WAL/DB 和 Data 共用同一块 SSD 的同一个 LV。长时间高强度写会导致：
- RocksDB compaction 和 Data IO 争抢磁盘带宽
- DB 读延迟飙升 → BlueFS DB 读停滞告警 → 写性能降 50%+

### 4.2 物理设备 vs 逻辑设备

| 方案 | 空间隔离 | I/O 隔离 | 效果 |
|------|---------|---------|------|
| 逻辑设备（同盘不同 LV） | 有 | 无 | DB 有独立空间，但 compaction IO 仍争抢 |
| 物理设备（NVMe + HDD） | 有 | 有 | 完全隔离，根本解决 |

### 4.3 测试环境规避

当前环境无法加独立物理设备，只能通过以下方式规避：
1. layout 后加 cooldown 等待 compaction 完成
2. 每项 fio 前检查 ceph health
3. 避免连续长时间高压力写（分段写、中间休息）
4. 如果再次出现 BlueFS stall，重启对应 OSD 后再继续

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
- layout 后加 cooldown（见第三节）
- 每项 fio 前检查 ceph health（见第二节）
- 生产环境必须用独立 NVMe 做 DB/WAL 设备

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
1. 每台 Ceph 节点配独立 NVMe SSD 做 DB/WAL
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
