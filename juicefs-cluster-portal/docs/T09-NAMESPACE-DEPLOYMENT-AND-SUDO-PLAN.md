# T09业务卷目录快照部署与sudo计划

> 状态：`DEPLOYED`；RUN `20260911-165833`已按“全量汇总+每目录top 100大项”完成152业务卷接入和运行态签收。
> 目标节点：`10.20.1.152（ceph-node3）`。
> 目标：把已经签收的三级目录快照能力接入业务卷，不改变业务挂载、PD/TiKV、Ceph或开机启动状态。

## 1. 最小部署范围

只新增一条独立管理链路：

```text
业务卷META
  └─ jfsportal用户的专用控制挂载（不使用allow_other）
       └─ 每60秒执行一次summary fast（每目录top 100）
            └─ SQLite generation快照
                 └─ Portal只读API和USER/ADMIN页面
```

- 挂载点：`/var/lib/juicefs-portal/namespace-mount`；不复用157的业务挂载。
- 采集配置只定义opaque root ID `juicefs-prod-root`；API仅返回虚拟路径`/`。
- 采集器为oneshot，单次最长30秒、`CPUQuota=20%`、`MemoryMax=192M`、`IOWeight=10`。
- JuiceFS `summary`必须以`O_RDWR`打开虚拟`.control`发送统计请求，因此专用挂载的内核标志必须为rw；采集命令逻辑只读，不读取文件内容，也不创建、修改或删除业务文件。
- 挂载客户端固定JuiceFS参数`--atime-mode noatime`、`cache-size=0`、无后台meta备份且不使用`allow_other/allow_root`，`CPUQuota=20%`、`MemoryMax=256M`、`IOWeight=10`。该参数控制JuiceFS元数据atime策略，不要求内核`findmnt`选项显示为`noatime`。
- 只有挂载用户`jfsportal`和root能进入FUSE挂载；Portal service另以`InaccessiblePaths`明确屏蔽该路径，网页请求只能读取SQLite。
- timer每60秒触发一次，但mount/service/timer均无`[Install]`，只在本次会话中`start`，不设置开机自启。
- Portal只重启一次以加载SQLite路径和USER授权；Prometheus、Grafana及业务组件不重启。
- 业务卷固定引用Ceph身份`client.juicefs`；152本地只安装该池级keyring（`root:jfsportal 0640`），不向Portal提供`client.admin`。

挂载客户端必须同时访问同三台节点上的两组服务地址：

| 节点 | TiKV元数据（管理网） | Ceph public/client（100GbE） |
|---|---|---|
| ceph-node1 | `10.20.1.150/32` | `10.3.1.6/32` |
| ceph-node2 | `10.20.1.151/32` | `10.3.1.7/32` |
| ceph-node3 | `10.20.1.152/32` | `10.3.1.8/32` |

systemd网络沙箱采用`IPAddressDeny=any`后逐项放行以上六个地址。Ceph内部复制与恢复使用的`10.3.2.0/24`不向客户端放行。当前systemd 249中，`RestrictAddressFamilies`和`LockPersonality`均会隐式启用`NoNewPrivileges=1`，使setuid `fusermount3`无法获得挂载权限，因此mount unit不使用这两项；精确IP过滤和`DevicePolicy=closed + DeviceAllow=/dev/fuse rw`继续保留，且实测不会启用`NoNewPrivileges`。

该安全模型不是内核`ro`：可信collector进程在技术上拥有通过专用挂载写业务卷的权限。风险通过无`allow_other`、Portal路径屏蔽、固定二进制/SHA、固定单一`summary`命令、systemd沙箱和资源限制收敛。JuiceFS客户端建立会话、心跳和退出时仍会在元数据引擎留下正常的短生命周期客户端状态。

## 1.1 展示精度边界

- 每个父目录的递归容量、文件总数和目录总数覆盖全部后代；
- 每个目录的直接子项明细最多展示按容量排序的100项，文件与目录共同参与排序；
- 超出100项的部分由JuiceFS合并为`...`，Portal显示为`其余项（聚合）`；聚合容量和计数有效，但不含逐项名称；
- 全树不是“最多100项”：只要单个目录的直接子项不超过100，可在三级内展示多个目录各自的top 100；
- snapshot/API另有10,000行资源保护上限，达到时本轮失败并保留上一份有效快照。

## 2. 固定输入与部署前硬门

- JuiceFS二进制必须是已批准的patched v1.4.1，MD5固定为`24fae0852051c80ca571cb2f20275d46`。
- Ceph认证库中的`client.juicefs`必须保持`mon allow r`及仅对`juicefs-data`的既有OSD权限；目标keyring部署前必须不存在。
- 152现有Portal、三份Web资产和Portal unit必须与T08签收SHA完全一致；漂移即停止。
- Portal、Prometheus、Grafana必须为`active/disabled`，PD/TiKV及`/mnt/jfs-tikv`、`/mnt/dbwal`必须存在。
- `/dev/fuse`、真实fusermount helper、三节点TiKV `2379`、三个Ceph MON public地址`3300`、`jfsportal`读取`ceph.conf`、至少1 GiB可用内存和2 GiB系统盘余量必须通过。
- 所有T09目标二进制、配置、unit、数据库和挂载均必须不存在；不会覆盖未知现场。
- USER账户必须唯一、角色仍为`USER`且尚未绑定`juicefs-prod-root`；密码哈希、会话secret和bootstrap凭据原样保留。

## 3. 状态变更及自动回滚

更新脚本先把当前Portal二进制、三份Web资产、`users.json`、`portal.env`及业务PID/挂载指纹备份到：

```text
/var/lib/juicefs-portal/t09-backup-RUN_ID
```

随后仅执行：

1. 由152本机root只读导出既有`client.juicefs`，安装为`/etc/ceph/ceph.client.juicefs.keyring`，不创建或修改Ceph认证记录；
2. 安装新Portal、Web、collector和固定JuiceFS二进制；
3. 给现有`user`账户追加opaque root授权，不改密码哈希；
4. 安装namespace配置和三个static systemd unit；
5. 启动专用控制挂载，运行一次collector，启动非自启timer，重启Portal；
6. 验证挂载为`JuiceFS:juicefs-prod + fuse.juicefs + rw`且无`allow_other/allow_root`、Portal路径被屏蔽、SQLite完整且不超过180秒、ADMIN/USER可读、越权与写请求被拒绝；
7. 对比PD/TiKV PID及两个业务挂载的前后指纹。

任一步失败即停止timer和专用挂载，恢复Portal、Web、账户与环境文件，并仅在SHA仍匹配时删除本RUN创建的`client.juicefs` keyring。回滚不使用lazy/forced unmount；若普通卸载失败，立即保留现场并停止删除，避免把活跃挂载下的路径误当成本地目录。

## 4. 本阶段不做

- 不修改157业务挂载，也不读取文件内容；
- 不修改PD/TiKV/Ceph配置，不重启相关进程；
- 不执行`mkfs`、`losetup`、块设备、NVMe、pool或volume操作；
- 不启停Prometheus/Grafana，不修改防火墙；
- 不运行`du`、递归`find`或strict summary；
- 不enable任何新增或现有服务。

## 5. 下一阶段执行顺序与sudo审批边界

先从157读取已存在的approved JuiceFS二进制到本地，生成RUN私有staging并经157转发152；这些步骤不需要sudo。152上的只读root预检通过后，才允许更新。

需要审批的顶层sudo命令仅两条（`RUN_ID`在staging生成后替换为实际值）：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-RUN_ID/scripts/t09-readonly-preflight.sh /tmp/jfsportal-t09-RUN_ID
sudo /usr/bin/bash /tmp/jfsportal-t09-RUN_ID/scripts/t09-update-namespace.sh /tmp/jfsportal-t09-RUN_ID
```

若更新后需主动撤回，使用脚本成功输出中的精确备份目录：

```bash
sudo /usr/bin/bash /var/lib/juicefs-portal/t09-backup-RUN_ID/t09-rollback-namespace.sh /var/lib/juicefs-portal/t09-backup-RUN_ID
```

第二条更新命令内部会创建/替换上述明确的Portal受管文件并执行`systemctl daemon-reload/start/restart/stop`；不会调用`sudo`、不会扩展到其他路径。正式执行前仍需把实际RUN ID和staging SHA回传确认。
