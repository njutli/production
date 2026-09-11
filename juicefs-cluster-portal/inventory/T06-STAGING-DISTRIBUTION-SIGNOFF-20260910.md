# T06 staging上传与分发签收

> 时间：2026-09-10  
> 裁决：`T06_STAGING_DISTRIBUTION_PASS`  
> sudo操作：无。

## 结果

- 固定路径：`/tmp/jfsportal-t06-20260910-181003`。
- 本地、157、150、151、152均存在同一份staging；每份18个受清单管理的文件，约29 MiB。
- 四个远端副本均执行完整`sha256sum -c SHA256SUMS`；全部文件最终通过。
- `SHA256SUMS`的SHA256为`71fd15fba0757efa66de978a2093a3bbb3a65faf01ea2974a9da58eb2a026ef6`。
- 主机名复核：157为`oneasia-c1-cpu-node10`，150～152依次为`ceph-node1`～`ceph-node3`。
- node_exporter、metrics forwarder和远端安装脚本执行权限均正确。

## 传输观察

157首次全量校验曾单独报告`node_exporter`不一致；立即比较发现本地与远端文件大小均为`23900840`字节、实际SHA均为`1108f7453ecfe4a72f131c73b69537c171840ad4f1713a2402328ad56cf12e09`，与清单一致。随后在157连续执行两次完整清单校验均通过，才开始向150～152分发。没有把未签收副本下发。

## 状态边界

- 本步只在各节点`/tmp`新增staging文件。
- 未创建系统用户或目录，未安装unit，未执行`systemctl daemon-reload/start/restart/enable`。
- 未修改Prometheus、Ceph、PD、TiKV、JuiceFS和任何业务挂载。

