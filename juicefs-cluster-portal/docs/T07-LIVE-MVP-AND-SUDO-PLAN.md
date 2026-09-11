# T07 管理员实时页面与远端更新计划

## 1. 本步交付

- Portal由fixture切换为只读Prometheus live adapter。
- 侧栏八个页面均可点击：总览、拓扑、节点与磁盘、JuiceFS客户端、TiKV/PD、Ceph、容量、告警。
- 总览区分JuiceFS逻辑带宽、Ceph Pool物理带宽和节点网络带宽。
- 磁盘页显示150～152共12块NVMe的用途、OSD映射、型号、序列号、实时I/O、延迟、队列、利用率、温度和寿命。
- 拓扑关系来自版本化静态清单，健康、PD Leader、MGR Active、TiKV、OSD和磁盘状态来自实时指标。
- API只允许固定语义查询；页面无法提交PromQL，也没有集群写操作。

## 2. 低扰动设计

- Portal只访问152本机`127.0.0.1:9090`，页面刷新不执行SSH、sudo、Ceph CLI、PD API、smartctl或目录扫描。
- 页面每5秒读取Portal；后端按端点缓存8秒，减少重复PromQL查询。
- Prometheus不可用时返回最近一次成功缓存并标为`stale`；无缓存时返回不可用，不把缺失值改为0。
- Portal维持0.5核/1 GiB/IOWeight 10，Prometheus维持2核/6 GiB/IOWeight 10。
- 不修改或重启PD、TiKV、Ceph OSD、JuiceFS、Node Exporter、NVMe collector和Grafana。

## 3. 指标配置最小变化

在现有PD白名单中增加已经存在的：

- `etcd_server_is_leader`：动态识别PD Leader；
- `etcd_server_has_leader`：确认etcd quorum存在Leader；
- `pd_cluster_status`：保留Region/Leader汇总状态。

不新增exporter、不扩大抓取目标、不采集Region ID等高基数标签。

## 4. Staging

- 本地路径：`/tmp/jfsportal-t07-20260910-200500`
- 大小：6.7 MiB；SHA清单19项。
- `SHA256SUMS`：`f57e777562dbaf55e83db54fe8df5fcf2def2fe2b55e4f95e99f102362118201`
- Portal二进制：`252cceb69cd283024f83680a5de64698c64a425131a7056f16ac8c7da91b1883`
- Prometheus配置：`56c3019785651928e20444c70fc4fca24a43bf0849137630abffa59ced52d993`

上传只写157和152的同名`/tmp`目录，不需要sudo；远端先全量校验SHA并执行只读preflight。

## 5. 唯一sudo状态变更

远端校验通过并再次取得用户批准后，仅在152执行：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t07-20260910-200500/scripts/t07-update-live-portal.sh /tmp/jfsportal-t07-20260910-200500
```

脚本先核对当前已安装Prometheus配置必须仍为T06签收SHA，再备份Portal二进制、Web文件和Prometheus配置。随后只替换这些文件，并依次重启`juicefs-prometheus.service`和`juicefs-portal.service`。

## 6. 自动回滚与停止条件

以下任一失败会恢复T06配置和旧Portal并重启这两个管理服务：staging SHA、promtool、Prometheus ready、PD Leader指标、任一Portal API、live数据来源、服务disabled状态、PD/TiKV PID或业务挂载检查。

备份路径由RUN_ID唯一确定；不删除业务数据、不操作设备、不改变Ceph配置。T07成功后管理服务仍保持`disabled`，不会设置开机自启。
