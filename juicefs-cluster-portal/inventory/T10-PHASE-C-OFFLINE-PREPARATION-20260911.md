# T10阶段C最小故障隔离离线签收

> 后续更正：本报告的RUN形成于T09上线前，未保护namespace挂载、timer和SQLite合同，已由RUN `20260911-172534`取代，禁止执行；见`T10-PHASE-C-T09-BASELINE-PREFLIGHT-SIGNOFF-20260911.md`。

> 时间：2026-09-11 09:11 CST  
> 裁决：`T10_PHASE_C_OFFLINE_PASS`  
> 状态变更：无；仅准备本地staging，尚未上传或执行。

## 验收范围

- staging：`/tmp/jfsportal-t10-20260911-091149`；仅含1个127行的执行脚本和SHA清单；
- 脚本SHA256：`dab905bc93f8e35148ac517159dd8480a7b812229300b472556d4a4e4aa4d525`；
- `bash -n`和staging全量`sha256sum -c`通过；
- 执行前固定核对152主机名、staging范围、Portal/Prometheus unit SHA、三个管理服务`active/disabled`、管理员令牌格式、PD/TiKV PID和两处业务挂载；
- 令牌只在root进程内存中使用，不输出、不复制、不写入staging或证据。

## 唯一状态变更

获批后脚本仅在152顺序执行：

1. `systemctl stop juicefs-portal.service`，只读确认Prometheus、Ceph指标和业务指纹不变，再`systemctl start juicefs-portal.service`；
2. 预热Portal overview缓存后，`systemctl stop juicefs-prometheus.service`，等待10秒并确认Portal返回`freshness=stale`且带错误说明，再`systemctl start juicefs-prometheus.service`；
3. 等待Prometheus恢复14个targets，确认Portal恢复fresh、Ceph健康值为0、管理服务仍为`active/disabled`且无自动重启；
4. 任一步失败时EXIT trap分别尝试启动Prometheus和Portal，避免一个恢复失败阻断另一个。

## 安全边界

- 不停止、重启或修改PD/TiKV、Ceph、JuiceFS、Node Exporter、NVMe collector或157 forwarder；
- 不执行`rm`、`mount/umount`、磁盘操作、Ceph写命令、网络/防火墙修改、服务enable或业务I/O；
- 全程核对PD/TiKV PID以及`/mnt/jfs-tikv`、`/mnt/dbwal`完整挂载指纹；
- 预计Portal不可用不超过30秒，Prometheus暂停约10～100秒；暂停期间不影响业务数据面。

## 待审批

1. 上传该staging到152的`/tmp`；
2. 在152执行：
   `sudo /usr/bin/bash /tmp/jfsportal-t10-20260911-091149/scripts/t10-management-failure-isolation.sh /tmp/jfsportal-t10-20260911-091149`

未获批前不执行上述操作。
