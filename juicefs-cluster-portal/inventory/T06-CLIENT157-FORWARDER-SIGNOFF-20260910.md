# T06 客户端157指标转发器签收

> 时间：2026-09-10  
> 裁决：`T06_CLIENT157_FORWARDER_PASS`  
> 范围：仅`10.20.1.157（oneasia-c1-cpu-node10）`。

## 执行结果

- staging完整SHA和危险命令扫描通过后，执行了用户批准的两条sudo命令。
- 新建`jfsmetrics`系统用户/组，安装只读metrics forwarder并在当前会话启动。
- 转发器主PID为`635070`，`NRestarts=0`，MemoryCurrent约3.7 MiB。
- cgroup限制为CPU 10%单核、内存64 MiB、IOWeight 10。
- 服务为active且disabled，没有设置开机自启。

## 网络与权限

- 监听`10.20.1.157:9633`，上游固定为`http://127.0.0.1:9567/metrics`。
- 从152抓取返回HTTP 200，约100 KiB，耗时约3.8 ms，并包含真实`juicefs_fuse_ops_total`指标。
- 从151发起同一请求超时并被拒绝，确认systemd来源IP白名单生效；只有152和localhost获准访问。
- 转发器只允许GET/HEAD，拒绝写方法，单次响应上限4 MiB。

## 业务保护检查

- JuiceFS挂载进程PID仍为`977835/977874`，未重启、重挂或修改配置。
- 157原有Node Exporter `127.0.0.1:9100`检查正常。
- 没有修改WekaIO、Kubernetes、网络配置、内核参数或任何业务目录。

