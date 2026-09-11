# T09专用只读挂载网络根因签收

> 时间：2026-09-11  
> 裁决：`T09_MOUNT_NETWORK_BLOCKER_CONFIRMED`；网络白名单是首个确定阻断点，但不是修复后发现的唯一阻断点。

## 证据链

- 业务卷状态明确显示`Storage=ceph`、`Bucket=ceph://juicefs-data`、`BlockSize=256 KiB`。因此挂载不仅需要访问`10.20.1.150～152:2379`的TiKV元数据，还要直接访问Ceph RADOS。
- Ceph的`public_network`是`10.3.1.0/24`，MON public/client地址为`10.3.1.6～8`，OSD public/front地址也在这三个IP；`10.3.2.0/24`是OSD复制与恢复使用的cluster网络，不属于客户端所需范围。
- 152本机拥有`10.3.1.8`接口，且非sudo TCP探测三个MON的v2端口`10.3.1.6～8:3300`均成功，排除主机本身无Ceph路由或MON不可达。
- 首次部署的`juicefs-namespace-mount.service`设置`IPAddressDeny=any`，但只允许`10.20.1.150～152/32`。在该沙箱内，TiKV可达而所有Ceph MON/OSD public/client连接均被拒绝。
- journal观察到mount进程成功启动、但60秒内没有形成FUSE挂载；这与“元数据入口可达、RADOS初始化被阻断”的失败位置一致。
- 157现有业务挂载使用相同的UBIP `fusermount3`布局，真实helper与152均为`root:root 4755`且SHA一致；helper权限不能解释节点差异。

## 最小修复

mount unit只新增以下三个精确地址：

```ini
IPAddressAllow=10.3.1.6/32
IPAddressAllow=10.3.1.7/32
IPAddressAllow=10.3.1.8/32
```

不放行`10.3.2.0/24`，不修改防火墙、路由、Ceph配置或业务挂载。root只读preflight增加三个MON `3300`端口探测，以及`jfsportal`身份读取`/etc/ceph/ceph.conf`的检查。

## 执行边界

- RUN `20260911-134851`继续标记为无效，禁止执行；
- 先在本地通过完整离线Gate，再生成全新RUN并做三端SHA校验；
- 新RUN仍先执行root只读preflight，只有通过并再次获得用户授权后才允许执行更新；
- 不执行任何`chmod`，不操作PD、TiKV、Ceph服务、业务挂载或业务数据。

## 修复后验证结果

RUN `20260911-141910`补齐地址后，JuiceFS在约94毫秒内从TiKV阶段进入RADOS连接阶段，随后明确返回`rados: ret=-13, Permission denied`。这证明网络阻断已经解除，同时暴露出152缺少`client.juicefs` keyring的第二个独立阻断点；不能再把网络遗漏表述为全部根因。
