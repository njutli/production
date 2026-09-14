# T12 管理员带宽趋势曲线最终签收

> 日期：2026-09-14
>
> RUN：`20260914-094428`
>
> 裁决：`T12_PASS`

## 1. 交付内容

管理员总览新增四条带宽历史曲线：JuiceFS逻辑读/写和`juicefs-data` Pool物理读/写。页面支持15分钟、1小时、6小时和24小时窗口，默认1小时；查询步长分别为15、30、120和300秒，每30秒自动刷新，鼠标悬停可读取最近样本。

曲线复用既有`GET /api/v1/admin/timeseries`及Prometheus `query_range`，后端只接受固定语义指标白名单，前端不能传入任意PromQL。USER权限、采集拓扑和数据保留策略均未改变。

## 2. 离线验证

- `node --check web/app.js`通过；
- Go test、Go vet及`tests/offline-gate.sh`完整通过；
- 静态页面测试新增`bandwidth-range`、`bandwidth-svg`和曲线标签断言；
- 更新及只读验收脚本均通过`bash -n`。

## 3. 上线范围

152只备份并替换：

```text
/opt/juicefs-portal/web/index.html
/opt/juicefs-portal/web/app.js
/opt/juicefs-portal/web/styles.css
```

旧文件保存在：

```text
/var/lib/juicefs-portal/t12-backup-20260914-094428/
```

新文件SHA256：

```text
9d2d639ba8bda07ad4440e34f954c6cc2889190b424c3c17955fe29d0787353d  index.html
205e248c2a65f25888ab0597e010c9ef4c08a836104942ec4140940a0cdb9fed  app.js
d2dfefcdfb166bf86cbdc9afea3eea62a85c232fc70e2590675db24d9a58b706  styles.css
```

Go Portal通过`http.FileServer`逐请求读取静态资源，因此本次没有重启Portal、Prometheus、Grafana或任何业务服务。

## 4. 运行态验收

- HTTPS首页实际返回新`bandwidth-svg`，带版本参数的新`app.js`实际返回`refreshBandwidthChart`；
- 未认证访问时序API返回401；以内部只读ADMIN验证令牌查询四个白名单指标，均返回真实Prometheus点列：`T12_READONLY_VERIFY_PASS metrics=4 window=1h step=30`；
- Portal、Prometheus、Grafana持续active，三者`NRestarts=0`；
- T09目录快照generation为3814、年龄54.7秒并保持ready；Ceph、PD/TiKV和业务挂载由同轮T11只读样本确认正常；
- 本次没有新增采集器、端口、systemd unit、定时任务、凭据或挂载，也没有修改JuiceFS、TiKV或Ceph配置。

## 5. 使用方式

通过157建立SSH隧道后访问`https://localhost:8443/`，使用ADMIN登录。在“总览”的四个瞬时带宽卡片下方查看趋势图；首次打开或切换时间窗口会立即查询，随后每30秒更新。若浏览器已打开旧页面，刷新一次即可，静态资源URL已带`20260914-bandwidth`版本标识。
