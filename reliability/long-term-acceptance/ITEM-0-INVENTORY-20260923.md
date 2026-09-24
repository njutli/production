# 长稳验收项0：157/150～152 只读配置盘点

执行时间：2026-09-23 08:26～08:29 ICT。通过 `ssh thailand` 登入157，再从157只读连接150～152。没有运行 fio、创建数据、改变挂载或执行 sudo。

## 核对结果

| 项 | 实况 | 结论 |
|---|---|---|
| JuiceFS | `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`，进程 PID 977835/977874 | 与交付二进制一致 |
| 挂载 | `/mnt/juicefs`，`--max-uploads 150 --cache-size 0 --max-fuse-io 256K`；findmnt `max_read=262144` | 与通用基线一致；未启用条件性缓存/writeback |
| 卷 | `juicefs-prod`，UUID `e1b69ea9-0e3d-427d-bea9-8765928afa66`，BlockSize 256K，Ceph pool `juicefs-data` | 与当前 LT 默认契约一致 |
| Ceph 客户端异步线程 | 运行中的两个 JuiceFS 进程 `/proc/*/environ` 均无 `CEPH_CONF`；挂载命令也无指定私有配置；`/etc/ceph/ceph.conf` 未见 `ms_async_op_threads`；`ceph config get client ms_async_op_threads` 返回 **3**。父进程无 `msgr-worker-*`，worker PID 977874 实际有 **3** 个。旧私有文件 `/tmp/t51-conf/ceph-msgr8.conf` 虽存在并写 8，但未见本挂载使用它 | **MISMATCH**：运行时也是3个，交付基线要求8；不能仅以文件存在视为启用 |
| Ceph | v17.2.9，FSID `f8137e5a-8af2-11f1-aa1c-4df480fc234d`；6/6 OSD up/in、HEALTH_OK、97 PG active+clean；`juicefs-data` EC4+2、PG32、min_size5，pool 584GiB/2.39M objects，max available 26TiB | 当前健康；scrub 禁止标志未设置 |
| BlueStore DB/WAL | 6个OSD的 DB 空闲约37.9～38.11GiB，slow used 0；各节点 `/mnt/dbwal` 为200G tmpfs，loop backing 在其中，DB/WAL 每OSD分别40G/10G | 容量现有余量较前次已改善；tmpfs 仍不具备断电耐久性 |
| TiKV/PD | 三店 150/151/152 的 store 均 Up；TiKV v7.1.5；各节点 KV、Raft、WAL 路径均在 `/mnt/jfs-tikv` 同一块 NVMe ext4，盘剩余约800GiB | 符合当前共享NVMe形态 |
| 157资源和业务 | 100GbE链路 Up；内存可用约917GiB；`/mnt/jfs-cache` 830GiB可用；根分区仅20GiB可用、98%使用；Weka/K8s进程在运行；无 fio 进程 | 必须明确业务窗口和根盘日志预算；不得凭空闲内存直接启动压测 |
| LT运行依赖 | fio 3.28、Python3、iostat存在；`jq` **不存在**，而现有 LT preflight 硬要求 jq；测试结果/数据目录尚不存在 | **BLOCKED**：先做离线脚本适配或在获批情况下部署工具，不能跳过预检 |

## 对既有证据的界定

先前的 LT-002 两小时结果来自另一套 `.12` 客户端和 `.11/.13/.14` 集群：CRC通过、fio零错误，但只有一个可见回收周期，容量结论为 `INCONCLUSIVE_LONG_BOUND`。归档实际 fio 为128 jobs、iodepth128，不能误称QD1，也不能替代本集群长稳签收。该归档的 FUSE `max_read=131072`，也与当前157的256K不同。

## 项0结论与下一步

**配置门 BLOCKED，未授权项2及任何写入负载。** 最小后续动作：

1. 项1离线修补 LT 的严格配置门：验证实际 FUSE 256K、二进制MD5、卷UUID/BlockSize、Ceph客户端有效配置及来源；缺少 `jq` 时采用已有Python3解析或明确安装依赖，不可静默跳过。对错配置做拒绝测试。
2. 先确认157挂载为何没有 `CEPH_CONF`，以及是否有其他证据证明 librados 实际8线程；若确认为3，要在可控业务窗口内另行批准挂载调整，复核前不将长测称为交付配置验收。**本次不做重挂载。**
3. 冻结157的业务独占窗口、业务持续/峰值负载和停止线，再根据此集群实际对象/DB增长预算决定可否进行短时写入 canary；不凭现有26TiB pool余量忽略40G/OSD DB空间限制。

完整原始检查由命令行只读获取：`findmnt`/`df`/`free`/`pgrep`/`md5sum`/`juicefs status`、`ceph -s`/`ceph df detail`/`ceph osd dump`/`ceph tell osd.N perf dump`、PD stores API、各节点 `findmnt`/`df`/`losetup`/`tikv.toml`。未复制凭据或输出敏感环境变量。
