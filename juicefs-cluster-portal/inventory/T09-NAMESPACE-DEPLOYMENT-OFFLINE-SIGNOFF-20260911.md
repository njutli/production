# T09业务卷只读目录快照部署离线签收

> 时间：2026-09-11
> 裁决：`T09_NAMESPACE_DEPLOYMENT_OFFLINE_PASS`
> 现场影响：无远端连接、无上传、无sudo、无运行态变更。

## 完成内容

1. 冻结业务卷root ID、152专用只读挂载路径、60秒采集周期和SQLite路径；
2. 新增mount、collector、timer三个static unit，均未定义`[Install]`，不能被本轮脚本设置开机自启；
3. 新增staging、root只读preflight、更新、运行态验证和独立回滚脚本；
4. 更新只在当前USER账户增加`juicefs-prod-root`，保留密码哈希和其他认证材料；
5. 更新前固定核对T08安装SHA，更新后核对ro挂载、SQLite freshness、ADMIN/USER RBAC及业务PID/挂载指纹；
6. 回滚使用精确备份和普通卸载，卸载失败即停止删除，不使用lazy/forced unmount。

## 资源与安全边界

| 对象 | CPU | 内存 | I/O权重 | 启动方式 |
|---|---:|---:|---:|---|
| 专用只读挂载 | 20% | 256 MiB | 10 | 手工start、无重启、非自启 |
| snapshot collector | 20% | 192 MiB | 10 | timer触发的oneshot |
| collector timer | — | — | — | 60秒、手工start、非自启 |

挂载仅允许连接150～152，`cache-size=0`、`backup-meta=0`、日志进入有边界的journald；collector只能读配置/挂载并写Portal SQLite目录。timer在挂载停止后不会自动拉起挂载。

## 离线验证

- Go tests、Go vet、JavaScript、JSON与OpenAPI门禁：PASS；
- 5个T09脚本`bash -n`：PASS；
- unit关键资源、只读参数、无`[Install]`及危险命令扫描：PASS；
- systemd parser未报告未知directive；本机因目标二进制尚未安装及WSL凭据socket限制返回预期提示，已由固定白名单隔离，需在152 preflight再次核验；
- 当前尚未取得157上的approved JuiceFS二进制，因此未生成实际staging，也未触碰152。

## 下一步

1. 非sudo复制157上的`/tmp/juicefs-1.4.1-patched`并核对MD5；
2. 生成RUN私有staging、上传157并转发152，三端核对SHA；
3. 执行第一条root只读preflight并回传；
4. preflight通过后再单独确认更新命令，执行后完成低扰动运行态签收。

完整边界与命令见`docs/T09-NAMESPACE-DEPLOYMENT-AND-SUDO-PLAN.md`。
