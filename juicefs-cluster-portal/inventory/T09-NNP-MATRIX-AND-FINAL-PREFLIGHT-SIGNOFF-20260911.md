# T09 NoNewPrivileges矩阵与修复版预检签收

> 时间：2026-09-11  
> RUN：`20260911-150908`  
> 裁决：`T09_NNP_ROOTCAUSE_AND_REPAIR_PREFLIGHT_PASS`；尚未执行新RUN状态变更。

## 根因矩阵

152上的五组瞬时systemd unit执行后自动回收，结果为：

| 配置 | NoNewPrivs | Seccomp |
|---|---:|---:|
| 仅`User/Group=jfsportal` | 0 | 0 |
| `RestrictAddressFamilies` | 1 | 2 |
| `LockPersonality=true` | 1 | 2 |
| 精确`IPAddressDeny/Allow` | 0 | 0 |
| `DevicePolicy/DeviceAllow=/dev/fuse` | 0 | 0 |

各组`CapBnd`均为`000001ffffffffff`。因此失败不是能力上限删除了`CAP_SYS_ADMIN`，而是前两项分别隐式启用`NoNewPrivileges=1`，阻止`4755 root`的`fusermount3`通过execve获得新权限。

## 最小修复与门禁

- mount unit仅移除`RestrictAddressFamilies`和`LockPersonality`；
- 保留六个精确目标IP、`IPAddressDeny=any`、`DevicePolicy=closed`、`DeviceAllow=/dev/fuse rw`及全部CPU/内存/IO限制；
- 相对RUN `20260911-144710`只有mount unit和`SHA256SUMS`变化；
- 新RUN 28项清单SHA为`b405038a31deb24924cedb7478660d0d9de6568ea22396949131164f9bde0d7c`，本地、157和152一致；
- `juicefs-ro` MD5仍为`24fae0852051c80ca571cb2f20275d46`；
- 152 root只读preflight返回`T09_READONLY_PREFLIGHT_PASS`，可用内存`857548672 KiB`、系统盘余量`794654367744 bytes`。

## 下一步

等待用户明确批准RUN `20260911-150908`的唯一update命令。成功后须独立验证只读挂载、SQLite、RBAC、两个采集周期、未enable及业务指纹。
