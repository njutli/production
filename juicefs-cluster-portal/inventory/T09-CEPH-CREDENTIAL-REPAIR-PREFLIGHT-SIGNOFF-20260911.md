# T09 Ceph凭据修复版离线与只读预检签收

> 时间：2026-09-11  
> RUN：`20260911-144710`  
> 裁决：`T09_CEPH_CREDENTIAL_REPAIR_PREFLIGHT_PASS`；尚未执行状态变更。

## 修复边界

- 由152本机root从现有Ceph认证库只读导出`client.juicefs`；不执行`auth get-or-create`或`auth caps`，不修改集群认证记录；
- 只把该keyring安装到`/etc/ceph/ceph.client.juicefs.keyring`，权限固定为`root:jfsportal 0640`；
- 安装前验证既有caps为`mon allow r`和`juicefs-data`池级OSD权限；
- 回滚记录动态SHA，只有目标仍与本RUN安装内容一致时才删除，拒绝删除后来被替换的文件；
- 不复制、不安装、也不改变`client.admin` keyring。

## 门禁结果

- 本地完整离线Gate通过；
- 新RUN 28项清单SHA为`dd18fb5e35273a02956b6c51cc26b4d10e58721c440f71e565cc900f265a522a`，本地、157和152一致；
- `juicefs-ro` MD5仍为`24fae0852051c80ca571cb2f20275d46`；
- 157和152完整SHA及四个脚本语法通过；
- 152 root只读preflight返回`T09_READONLY_PREFLIGHT_PASS`，可用内存`857568228 KiB`、系统盘余量`794839453696 bytes`。

## 下一步

等待用户明确批准RUN `20260911-144710`的update命令；不继承前一RUN的写操作授权。
