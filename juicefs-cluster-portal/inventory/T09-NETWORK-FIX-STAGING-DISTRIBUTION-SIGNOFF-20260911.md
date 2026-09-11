# T09网络修复版staging分发签收

> 时间：2026-09-11 14:19～14:23 CST  
> 裁决：`T09_NETWORK_FIX_STAGING_DISTRIBUTION_PASS`  
> 现场影响：仅在157和152的独立`/tmp`创建新RUN；无sudo、无服务或业务状态变更。

## 新RUN

- RUN ID：`20260911-141910`；
- 三端路径：`/tmp/jfsportal-t09-20260911-141910`；
- 清单：28项，目录总字节数`152939228`；
- `SHA256SUMS` SHA256：`3fad66f0db02ccc6e762bbfecaf1b5a98c9834130b2043757f551fbbe8384842`，本地、157和152一致；
- `juicefs-ro` MD5：`24fae0852051c80ca571cb2f20275d46`，三端一致；
- 157和152均通过28项完整`sha256sum -c`及staged shell语法检查。

## 相对首次RUN的变化

相对完整但网络白名单有误的RUN `20260911-133252`，只有以下三项不同：

1. `systemd/juicefs-namespace-mount.service`：新增Ceph public/client地址`10.3.1.6～8/32`；
2. `scripts/t09-readonly-preflight.sh`：新增三个MON `3300`端口以及`jfsportal`读取`ceph.conf`的门禁；
3. `SHA256SUMS`：反映以上两项变化。

其他25项内容不变；没有修改JuiceFS二进制、Portal代码、collector、RBAC配置或更新/回滚逻辑。旧RUN `20260911-134851`继续禁止执行。

## 下一步

只允许先执行新RUN的root只读preflight：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-141910/scripts/t09-readonly-preflight.sh /tmp/jfsportal-t09-20260911-141910
```

该命令不安装文件、不启动服务、不修改系统状态。只有它返回`T09_READONLY_PREFLIGHT_PASS`，并再次获得用户对更新命令的明确授权后，才允许重试T09更新。
