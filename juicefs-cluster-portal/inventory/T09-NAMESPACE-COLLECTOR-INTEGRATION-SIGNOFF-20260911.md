# T09三级目录快照采集器签收

> 2026-09-11合同更正：本报告记录的是早期隔离临时卷验证，其中`--entries 10000`超出JuiceFS 1.4.1上限，不能作为业务卷正式合同。正式实现已改为`--entries 100`：父目录总量覆盖全部后代，每个目录只保留top 100直接子项，遗漏项用`...`聚合；详见`docs/T09-DIRECTORY-SNAPSHOT-DESIGN.md`。

> 时间：2026-09-11 13:01～13:08 CST  
> 裁决：`T09_NAMESPACE_COLLECTOR_INTEGRATION_PASS`  
> 持久证据：`/mnt/c/SunRise/test/juicefs-cluster-portal/20260911/t09-namespace-collector/`

## 完成内容

1. 新增一次性`juicefs-namespace-collector`，供后续systemd timer每分钟调用；采集器自身不常驻；
2. 每个授权根只执行一次`juicefs summary --depth 3 --entries 10000 --csv`，禁止`du`和文件内容读取；
3. 成功采集在单个SQLite事务中写入新generation、切换当前指针并删除旧generation；
4. 采集失败保留最近成功generation、计数和时间，只将状态改为`failed`，API据此呈现stale；
5. 根ID、配置、路径、CSV层级、父子关系、行数、输出大小和执行时间均设硬门；
6. 默认拒绝可写挂载；`--allow-writable-roots`只用于本次隔离临时卷验证，生产配置禁止使用；
7. 构建流程已加入静态采集器，SQLite schema由Portal与采集器共同复用。

真实挂载路径只存在于采集器主机配置中；SQLite和API只保存opaque root ID、显示名和虚拟路径`/`。

## 本地合同验证

| 项目 | 结果 |
|---|---|
| 两次成功采集 | generation 1→2，旧generation在同一事务内删除 |
| 故障注入 | generation、计数和目录行不变，仅状态变为`failed` |
| 非法CSV | 路径穿越、缺父目录、重复路径和错误表头均拒绝 |
| 配置合同 | 未知字段、重复root、非绝对路径拒绝 |
| 只读挂载门 | 使用最长匹配mount验证`ro`，生产默认强制 |
| Go test / vet / 离线Gate | PASS |
| 静态构建 | PASS，无动态依赖 |

采集器静态二进制大小为6,459,554 bytes，SHA256为`ab50e3b27f05184d82e35ed286d8782b9ae6506c0b4545faf1a1728b01a2635a`。

## 157隔离临时卷验证

验证对象仍为T09独立临时卷`jfsportal-dirstats-20260911`的`DIRTEST`，不是业务卷。因为该测试挂载原本为rw，本轮仅对它显式使用测试例外开关；采集命令本身全程只读。

| 采样 | wall time | Max RSS | generation | 结果 |
|---|---:|---:|---:|---|
| run1 | 0.08 s | 103,432 KiB | 1 | ready，1111行 |
| run2（间隔超过60秒） | 0.08 s | 99,620 KiB | 2 | ready，仅保留generation 2 |
| 故障注入 | — | — | 2 | 非零退出；100000文件、1111目录及414150656 bytes全部保留 |
| recovery | 0.09 s | 103,688 KiB | 3 | ready，1111行 |

最终SQLite为458,752 bytes，`PRAGMA integrity_check=ok`。根据实测RSS，后续collector service的`MemoryMax`应设为192 MiB，比本轮峰值高约91 MiB；同时使用低CPU/IO权重和15秒单根超时。

## Portal真实SQLite联调

本地live Portal以只读方式打开157生成的SQLite：

- roots API返回`100000 files / 1111 dirs / 414150656 bytes`；
- tree API在`maxDepth=3`下返回1111个目录；
- 联调时快照年龄约199秒，超过180秒SLA，API正确返回`freshness=stale`；
- SQLite中的真实路径没有进入响应。

## 影响与现场

- 本轮没有sudo、没有挂载/卸载、没有修改业务卷或集群配置；
- 157业务挂载仍为`JuiceFS:juicefs-prod`，业务JuiceFS PID仍为`977835,977874`；
- T09临时卷和原10万文件树保持原样；验证文件持久化后，157新增的`collector-validation`目录已按精确文件清单删除，无残留；
- 未上传或重启152 Portal，当前线上页面仍是T08版本。

## 下一步

冻结152专用只读挂载、collector service/timer、USER root授权和Portal升级的最小部署方案。先形成完整命令及回滚计划并做离线Gate；涉及sudo的命令必须单独提交用户审批，未经批准不执行。
