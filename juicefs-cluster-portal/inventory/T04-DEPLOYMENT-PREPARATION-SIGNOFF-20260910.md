# T04：152部署准备离线签收

> 执行日期：2026-09-10
> 裁决：`T04_PASS`
> 远端状态变更：无

## 1. 已就绪内容

- Portal、Prometheus和Grafana的systemd unit及cgroup/文件系统/网络限制；
- Prometheus自监控初始配置、Grafana本地配置及provisioning；
- Portal `live`安全模式：真实adapter未连接时返回503，不泄露fixture；
- 本地Portal静态构建、官方包SHA验证、安全解包和staging生成脚本；
- 152只读预检、安装不启动、分步激活、只读验收和保留数据停用脚本；
- 完整目录、服务、sudo动作和停止边界说明。

## 2. 离线检查

```text
bash -n（全部shell脚本）                         PASS
Go format/test/vet                               PASS
Portal linux/amd64静态构建                       PASS
Portal payload SHA256复验                        PASS
合成Prometheus/Grafana归档的完整staging canary   PASS（31个文件）
OpenAPI/Prometheus/Grafana provisioning YAML     PASS
Grafana INI                                      PASS
全部JSON fixture                                 PASS
JavaScript                                       PASS
systemd unit解析                                 PASS
T04_OFFLINE_GATE_PASS
```

`systemd-analyze verify`只报告目标二进制尚未安装，符合离线阶段预期；未发现unit语法错误。已移除当前systemd版本不再需要的`CPUAccounting=`声明，CPUQuota仍保留。

## 3. 部署裁决

- T05可以进入，但必须先取得用户对`docs/T04-DEPLOYMENT-DESIGN-AND-SUDO-PLAN.md`中sudo范围的批准。
- 第一次批准只执行安装脚本；它不会启动或enable服务。
- 安装证据检查通过后，第二次批准才执行激活脚本。
- T05仅loopback运行，不开放管理网入口，不启用Ceph模块和exporter。
- T05软件包必须按官方SHA核验；当前仓库不保存第三方二进制。
