# T09 top 100展示合同与修正版预检签收

> 时间：2026-09-11  
> 裁决：`T09_TOP100_REPAIRED_PREFLIGHT_PASS`  
> RUN：`20260911-164826`

## 1. 冻结的产品合同

用户已接受以下展示范围：

- 授权根及已展示目录的递归容量、文件总数和目录总数覆盖全部后代；
- 根以下最多三级，每个目录只显示按递归容量排序的top 100直接子项，文件与目录共同排序；
- 未进入top 100的直接子项由JuiceFS `...`行汇总，Portal显示为`其余项（聚合）`；聚合容量和计数有效，但不提供各项名称；
- 这不是完整文件清单。完整明细、文件属性、内容预览和下载不属于T09；
- 单root快照及单次API响应另设10,000行资源保护上限；超过时保留上一份有效快照并标记采集失败。

上述边界已写入`docs/T09-DIRECTORY-SNAPSHOT-DESIGN.md`、`docs/T09-NAMESPACE-DEPLOYMENT-AND-SUDO-PLAN.md`、MVP范围、OpenAPI和页面提示。

## 2. 修正内容

1. collector固定执行`juicefs summary --depth 3 --entries 100 --csv`，不再使用无效的`10000`；
2. CSV、SQLite、API和页面完整支持`directory`、`file`、`aggregate`三类可见行；
3. SQLite树索引与查询不再只过滤目录，单元测试覆盖文件、聚合项、generation切换及只读查询；
4. `summary`必须以`O_RDWR`打开虚拟`.control`，因此152专用控制挂载改为内核rw，同时固定`noatime`、`cache-size=0`、无`allow_other/allow_root`；
5. 只有固定命令collector能访问控制挂载；Portal service新增`InaccessiblePaths=/var/lib/juicefs-portal/namespace-mount`，网页/API仍只能查询SQLite；
6. 安装、验证和精确回滚链路同步纳入Portal drop-in，失败时仍自动恢复T08状态。

该控制挂载在技术上可写，但本方案不提供任意命令、路径或文件操作入口。风险边界是固定二进制、固定配置、固定`summary`命令、独立账户、systemd沙箱、路径隔离和资源限制，而不是把业务卷暴露给Portal。

## 3. 离线与三端证据

- Go测试、Go vet、JavaScript语法检查及T09离线Gate均通过；
- staging：`/tmp/jfsportal-t09-20260911-164826`；
- 文件数：`29`；
- `SHA256SUMS` SHA256：`9c97a9858b9c99b623a0ad1af6695deaf2f166c1d3e84a41152744e4c3002daf`；
- staging压缩包大小：`50,835,604 bytes`；SHA256：`e2506183fa20e604105a8de46376eefb67201288e116da4c8640b571974a189c`；
- JuiceFS二进制MD5：`24fae0852051c80ca571cb2f20275d46`；
- 本地、157和152的29项清单及二进制指纹一致；首次WSL到157传输的中间态被精确大小/SHA门拦截，文件稳定后才重新转发，未执行不完整副本。

## 4. 152只读预检

已执行仅盘点现场、不改变状态的root预检：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-164826/scripts/t09-readonly-preflight.sh /tmp/jfsportal-t09-20260911-164826
```

结果：

```text
T09_READONLY_PREFLIGHT_PASS host=ceph-node3 mem_available_kib=857602680 disk_available_bytes=794154577920
```

当前尚未安装新资产、启动控制挂载或collector，也没有重启Portal。PD/TiKV、Ceph、业务挂载及现有监控服务均未改变。

## 5. 下一步审批边界

正式更新仅允许在152执行以下一条顶层sudo命令：

```bash
sudo /usr/bin/bash /tmp/jfsportal-t09-20260911-164826/scripts/t09-update-namespace.sh /tmp/jfsportal-t09-20260911-164826
```

命令内部只操作T09文档列明的精确Portal受管路径，启动三个static T09 unit并重启一次Portal；不enable服务，不修改PD/TiKV/Ceph配置，不重启业务组件，也不修改157业务挂载。任何硬门失败都会调用本RUN精确回滚。
