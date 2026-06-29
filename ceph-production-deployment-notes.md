# Ceph 生产环境部署注意事项

> 日期：2026-06-25
> 背景：测试环境因 WAL/DB 与数据共用物理盘，长时间高强度写导致 BlueFS DB 读停滞（HEALTH_WARN），写性能从 108 MB/s 降到 38-54 MB/s。

---

## 一、WAL/DB 是什么

BlueStore 是 Ceph 的默认对象存储引擎。每个 OSD 内部有：

| 组件 | 作用 | 存储内容 |
|------|------|---------|
| **Data** | 主数据区 | 对象的实际数据（最大，占磁盘绝大部分空间） |
| **WAL** (Write-Ahead Log) | 写前日志 | 先写 WAL 再写 Data，保证断电一致性 |
| **DB** (RocksDB) | 元数据数据库 | 对象的元数据索引（key、size、属性、位置映射等） |

写流程：数据 → WAL（顺序写，快）→ 异步刷到 Data → 元数据写入 DB（RocksDB LSM tree）。

读流程：查 DB（定位对象在 Data 中的位置）→ 从 Data 读取。

**DB 读卡住 = 每次读写都要等 RocksDB 查询 = 全部 IO 变慢。**

---

## 二、当前测试环境的配置（有问题）



验证命令：

输出：所有 OSD ，表示 WAL/DB 与 Data 共用同一块盘。

### 问题

- WAL/DB 和 Data 共用盘时，RocksDB 的 compaction（LSM tree 合并）会和数据读写争抢磁盘 I/O
- 长时间高强度写（如 128G layout 写 66 分钟）导致 RocksDB LSM tree 膨胀，compaction 跟不上
- DB 读延迟飙升 → BlueFS DB 读停滞告警 → 写性能降 50%+

### 部署脚本中的问题

 Step 4 只创建了 2 个 LVM LV 给 OSD 用，没有指定独立的 WAL/DB 设备：


---

## 三、生产环境部署要求

### 方案 A：独立 DB/WAL 设备（推荐）

每台 Ceph 节点配置：
- 1 块 HDD/SSD：数据盘（Data）
- **1 块 NVMe SSD**：DB/WAL 盘（RocksDB + WAL）

cephadm 部署语法：


### 方案 B：DB/WAL 与数据同盘但限制 DB 大小（折中）

如果无法加独立 NVMe，可以限制 RocksDB DB 的最大空间，防止 compaction 膨胀：


但这**不解决根本问题**——DB 和数据仍然争抢磁盘 I/O，只是延缓 compaction 膨胀。

### DB/WAL 设备容量建议

| 组件 | 建议容量 | 理由 |
|------|---------|------|
| WAL | 5-10 GB | 只存短时间写日志，小即可 |
| DB | **数据盘的 4%** | 官方建议；RocksDB LSM tree 通常不超过数据量 4% |

例如：1TB 数据盘 → DB 设备 40GB，WAL 设备 10GB。一块 100GB NVMe 可以给多个 OSD 共用 DB/WAL。

---

## 四、其他生产部署注意事项

### 4.1 网络配置

| 项 | 要求 | 说明 |
|----|------|------|
| 双网 | Public Network + Cluster Network 分离 | 客户端流量和 OSD 间流量互不干扰 |
| MTU | 9000（jumbo frame） | 减少 EC 分片的 TCP 头开销 |
| 带宽 | 万兆起步 | 千兆下 EC 4+2 的 4 分片读已接近线速 |

### 4.2 EC 池配置

| 项 | 值 | 说明 |
|----|-----|------|
| EC k+m | 4+2（3 节点）或 8+4（6+ 节点） | 容错 2 个 OSD 故障 |
| allow_ec_overwrites | true | JuiceFS 整对象写不触发 RMW，可安全开启 |
| failure_domain | osd（小集群）或 host（大集群） | 3 节点用 osd，6+ 节点用 host |
| pg_num | 32（小集群）或 128+（大集群） | PG 数量影响并行度 |

### 4.3 OSD 配置

| 参数 | 建议值 | 说明 |
|------|--------|------|
| bluestore_cache_size | 1-4 GB | BlueStore 读缓存，大集群可调大 |
| osd_op_threads | 32-64 | OSD 操作线程数，影响并发处理能力 |
| osd_max_backfills | 1-2 | 同时恢复的 PG 数，太高影响正常 IO |

### 4.4 监控告警

| 告警项 | 触发条件 | 处理 |
|--------|---------|------|
| BlueFS DB stalled read | HEALTH_WARN | 检查 DB 设备空间、I/O 延迟；可能需要重启 OSD |
| OSD down | OSD 离线 | 检查物理盘、网络 |
| PG degraded | 数据降级 | 等待恢复或手动修复 |
| Near full | 磁盘使用 >85% | 扩容或清理数据 |

---

## 五、部署前检查清单

- [ ] 每台 Ceph 节点有独立的 DB/WAL 设备（NVMe SSD）
- [ ] Public Network 和 Cluster Network 分离
- [ ] MTU 9000（如全链路支持）
- [ ] cephadm OSD spec 中指定了 db_devices
- [ ]  为 HEALTH_OK
- [ ] EC 池 k+m 匹配节点数和容错需求
- [ ] pg_num 合理（不过大不过小）
- [ ] 监控告警已配置（BlueFS、OSD down、PG degraded、容量）

---

## 六、当前测试环境的修复建议

1. **短期**：重启有 BlueFS 告警的 OSD（osd.1, osd.3, osd.4），清除告警
2. **中期**：重新部署 OSD，用 cephadm spec 指定独立的 DB 设备（如果有可用的 NVMe）
3. **长期**：生产环境必须用独立 DB/WAL 设备，避免同类问题
