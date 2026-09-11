# T06 离线准备签收

> 时间：2026-09-10  
> 裁决：`T06_OFFLINE_GATE_PASS`  
> 远端状态变更：无。

## 已完成

- 新增只读JuiceFS metrics转发器，限制为GET/HEAD、4 MiB响应上限和loopback上游；Go单测及vet通过。
- 固化Prometheus T06 scrape配置和指标白名单；Prometheus `3.13.2` promtool校验通过。
- 固化Node Exporter `1.12.1`，官方包SHA256复核通过，所用命令行参数与该版本help匹配。
- 新增NVMe SMART textfile collector：只读`/dev/nvme0`～`/dev/nvme3`，全部成功后才原子替换旧样本。
- 新增150～152节点安装、157转发器安装、152 Prometheus更新及全局只读验收脚本。
- 所有安装脚本只落盘并`daemon-reload`，不会启动或enable服务；启动命令留待逐阶段审批。
- Prometheus更新脚本在重启/ready失败时自动恢复T05配置与unit。
- 离线安全扫描确认没有重启/关机、设备写入、递归chown/chmod或systemctl enable。

## 构建物

- 本地staging：`/tmp/jfsportal-t06-20260910-181003`
- 文件数：18
- 总大小：约30.2 MB
- `SHA256SUMS`本身SHA256：`71fd15fba0757efa66de978a2093a3bbb3a65faf01ea2974a9da58eb2a026ef6`
- metrics forwarder SHA256：`8c4b2b1ee5717042f4b8bfda558a596971a3829eb3f959ad8a5d7c0f391c4003`

## 尚未执行

- 未上传T06 staging。
- 未创建用户、目录或systemd unit。
- 未启动Node Exporter、NVMe timer或157转发器。
- 未启用Ceph Prometheus模块。
- 未替换或重启152 Prometheus。
