# T10阶段C适配T09基线的执行前签收

> 时间：2026-09-11  
> RUN：`20260911-172534`  
> 裁决：`T10_PHASE_C_T09_BASELINE_PREFLIGHT_PASS`  
> 状态变更：无；仅更新本地脚本、分发staging并执行只读盘点。

## 1. 修订原因

旧RUN `20260911-091149`形成于T09上线前，未保护namespace mount、collector timer、SQLite快照及Portal路径隔离，禁止继续执行。新RUN只在原T10-C脚本上增加T09运行态硬门，不扩展故障注入范围。

## 2. 新RUN合同

- staging：本地、157和152均为`/tmp/jfsportal-t10-20260911-172534`；
- 只含执行脚本和SHA清单；`SHA256SUMS`摘要为`7da80d1ba1cc60c5adfd90e238acd9c1c67160215b7028a717c0764b432e69e0`；
- shell语法、危险命令扫描和三端SHA验证通过；
- 唯一状态变更仍是顺序停止/启动`juicefs-portal.service`和`juicefs-prometheus.service`；
- 不停止或重启namespace mount/timer、PD、TiKV、Ceph、Node Exporter、NVMe collector及157 forwarder；
- 任一步失败时EXIT trap分别恢复Portal和Prometheus。

## 3. 新增T09保护门

- 固定核对当前Portal二进制及四个T09 unit/drop-in SHA；
- 执行前后保持namespace mount PID及完整`findmnt`指纹不变；
- namespace mount和timer必须为`active/static`，collector为oneshot `inactive/static`；
- SQLite必须完整、root为ready且快照年龄不超过180秒；
- Portal每次恢复后，其mount namespace必须仍不可见专用控制挂载；
- Portal恢复后namespace API必须仍返回`juicefs-prod-root`。

## 4. 152只读预检结果

- Portal、Prometheus、Grafana、namespace mount和timer全部active；前三项disabled，T09三项static；
- 全部固定SHA与脚本合同一致；
- namespace控制挂载仍为`JuiceFS:juicefs-prod + fuse.juicefs + rw`；
- Prometheus ready且`sum(up)=14`；Ceph为`HEALTH_OK`；
- PD/TiKV PID仍为`1589960/2088516`。

当前未停止或启动任何服务。

## 5. 待审批命令

目标节点`10.20.1.152（ceph-node3）`：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t10-20260911-172534/scripts/t10-management-failure-isolation.sh /tmp/jfsportal-t10-20260911-172534
```

预计Portal中断数秒，Prometheus暂停约10～100秒；业务数据面不应受到影响。
