# T07 staging分发与安装前检查签收

> 时间：2026-09-10  
> 裁决：`T07_STAGING_PREFLIGHT_PASS`  
> sudo操作：无。

## 分发与完整性

- 固定staging路径：`/tmp/jfsportal-t07-20260910-200500`。
- staging内容：Portal二进制、Web静态文件、Prometheus配置、只读验证/更新脚本及fixture，共19个清单文件，约6.7 MiB。
- 本地完整执行`sha256sum -c SHA256SUMS`通过。
- 157（`oneasia-c1-cpu-node10`）完整执行`sha256sum -c SHA256SUMS`通过。
- 152（`ceph-node3`）完整执行`sha256sum -c SHA256SUMS`通过。
- `SHA256SUMS`文件SHA256：`f57e777562dbaf55e83db54fe8df5fcf2def2fe2b55e4f95e99f102362118201`。
- 分发仅在157和152的`/tmp`新增暂存文件，未使用sudo、未覆盖既有路径、未安装文件或操作服务。

## 152只读preflight

- `bash -n`检查三个远端执行/验收脚本通过。
- Prometheus `promtool check config`检查staging配置通过。
- 既有T06只读验收通过：`TARGET_CONTRACT_PASS required=12 ceph_up=2`、`T06_GLOBAL_VERIFY_PASS enabled=false`。
- Portal、Prometheus、Grafana均为`active/disabled`，分别仅监听`127.0.0.1:8080/9090/3000`。
- Portal健康接口返回`{"mode":"live","status":"ok"}`。
- PD PID为`1589960`、TiKV PID为`2088516`；`/mnt/jfs-tikv`仍为`/dev/nvme1n1`上的ext4，`/mnt/dbwal`仍为tmpfs。
- 普通登录用户无权读取`/etc/juicefs-portal/prometheus/prometheus.yml`，因此未绕过权限获取其SHA；更新脚本会在root上下文严格核对已签收T06 SHA，异常即在任何替换前退出。

## 下一步及状态边界

等待用户单独批准以下唯一sudo命令：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t07-20260910-200500/scripts/t07-update-live-portal.sh /tmp/jfsportal-t07-20260910-200500
```

该脚本仅备份并替换Portal二进制、Web静态文件及Prometheus受管配置，重启`juicefs-prometheus.service`与`juicefs-portal.service`，随后执行实时API、采集目标、服务禁用状态及业务指纹验收；失败时恢复备份并重启这两个管理服务。它不会enable服务，不会操作Grafana、PD、TiKV、Ceph OSD、JuiceFS挂载或业务数据。
