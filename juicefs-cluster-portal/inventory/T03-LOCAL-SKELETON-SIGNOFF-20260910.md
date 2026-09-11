# T03：本地项目骨架与fixture测试签收

> 执行日期：2026-09-10
> 裁决：`T03_PASS`
> 集群状态变更：无

## 1. 交付

- Go标准库只读API，覆盖T02冻结的12个路径；
- 无构建依赖的管理员监控首屏；
- JuiceFS、PD/TiKV、Ceph、节点、磁盘、容量、拓扑和告警脱敏fixture；
- ADMIN/USER权限边界、指标白名单、只读HTTP方法和数据新鲜度响应；
- 可重复执行的本地离线Gate。

文件/目录、授权路径用量、Namespace API和专用JuiceFS只读挂载均未实现，保持T09延期状态。

## 2. 验证结果

```text
go test ./...                                      PASS
go vet ./...                                       PASS
全部JSON fixture语法与全部fixture API              PASS
JavaScript语法                                     PASS
OpenAPI无POST/PUT/PATCH/DELETE和Namespace路径       PASS
GET /api/v1/health                                 HTTP 200
GET /api/v1/admin/overview（ADMIN）                 HTTP 200
GET /                                               HTTP 200
T03_OFFLINE_GATE_PASS
T03_HTTP_SMOKE_PASS
```

自动化测试同时确认：

- 未认证请求访问管理员API返回`401`；
- USER访问管理员API返回`403`；
- 非白名单时序指标返回`400`；
- POST等写方法返回`405`；
- 未登记节点的磁盘查询返回`404`；
- 每个动态响应包含采集来源、时间、年龄和新鲜度。

## 3. 运行边界

- 本阶段只在WSL本机`127.0.0.1:8080`短暂运行fixture服务，冒烟后已停止。
- 未SSH、未访问150～157、未执行sudo、未创建远端文件或服务。
- 当前默认token只用于本地fixture；T04必须设计生产密钥注入，并禁止默认token用于非loopback地址。
- T04以前不在152部署任何组件。
