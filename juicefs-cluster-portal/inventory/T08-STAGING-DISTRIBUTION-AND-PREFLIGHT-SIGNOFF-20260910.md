# T08 staging分发与安装前检查签收

> 时间：2026-09-10 23:14 CST  
> 裁决：`T08_STAGING_PREFLIGHT_PASS`  
> 远端状态变更：仅在157和152的`/tmp`新增staging；无sudo、无服务重启。

## 分发与完整性

- staging：`/tmp/jfsportal-t08-20260910-230425`，约12 MiB，清单20项。
- 本地、157和152使用同一`SHA256SUMS`；157、152均完成`sha256sum -c SHA256SUMS`并通过。
- 152端`bash -n scripts/t08-update-auth.sh scripts/t08-readonly-verify.sh`通过。
- 本次先确认152不存在同名目标目录，随后才由157精确转发，未覆盖旧目录。

## 152安装前状态

T07受管对象与更新脚本冻结指纹完全一致：

| 对象 | SHA256 |
|---|---|
| `/opt/juicefs-portal/bin/juicefs-portal` | `252cceb69cd283024f83680a5de64698c64a425131a7056f16ac8c7da91b1883` |
| `/opt/juicefs-portal/web/index.html` | `68b7b0a0a7fdd77d3028b5e300ed2571a5e7c0f5bfb58c179afc7235217cf3d3` |
| `/opt/juicefs-portal/web/styles.css` | `c70f44f92855f7792cec14dc614946b90f5b5744c4ae47af52a6dbfd15c8aca6` |
| `/opt/juicefs-portal/web/app.js` | `fe5a62fc7b2e51fb05443af0376f684e5e54ff907b2ef159d34ffa0981dc9f1d` |
| `/etc/systemd/system/juicefs-portal.service` | `01fa8ecb8f1ff26cf5754a1ea92886bc0153011d93cef31c29e1c9543ecd63fe` |

- `juicefs-portal`、`juicefs-prometheus`、`juicefs-grafana`均为`active/disabled`。
- `10.20.1.152:8443`无监听。
- `portal-userctl`、users、session-secret、bootstrap credentials、TLS证书/私钥及本RUN备份路径均不存在。
- PD PID=`1589960`、TiKV PID=`2088516`。
- `/mnt/jfs-tikv`仍为`/dev/nvme1n1`上的ext4；`/mnt/dbwal`仍为tmpfs挂载。

## 首次变更门（已失效）

> 后续结果：该首次更新因Portal unit缺少152自身IP许可而触发自动回滚；本节命令已失效，禁止再次执行。详见`T08-UPDATE-ATTEMPT1-ROLLBACK-SIGNOFF-20260910.md`。

首次获批并已执行的命令：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t08-20260910-230425/scripts/t08-update-auth.sh /tmp/jfsportal-t08-20260910-230425
```

该脚本先复核上述SHA与目标路径，再备份T07、创建本地账户/TLS并替换Portal受管文件；只重启`juicefs-portal.service`，不重启Prometheus、Grafana、PD、TiKV、Ceph或JuiceFS。任一步失败会恢复T07备份并仅重启Portal。执行后仍需从152本机和157分别完成只读验收。
