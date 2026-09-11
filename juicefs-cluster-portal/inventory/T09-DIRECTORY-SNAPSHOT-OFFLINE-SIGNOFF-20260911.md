# T09三级目录用量快照本地实现签收

> 时间：2026-09-11 12:31～12:48 CST  
> 裁决：`T09_DIRECTORY_SNAPSHOT_OFFLINE_PASS`  
> 本地原始证据：`/mnt/c/SunRise/test/juicefs-cluster-portal/20260911/t09-directory-snapshot-offline/`

## 本轮完成内容

1. 新增`GET /api/v1/usage/roots`和`GET /api/v1/usage/tree`两个只读API；
2. USER只能读取账户`namespaceRoots`明确绑定的opaque root ID，ADMIN可读取全部root；
3. `rootId`不接受主机路径或`..`，`maxDepth`硬限制1～3，单次树硬限制10,000个目录；
4. 新增SQLite v1 schema、三级树索引及只读数据源；Portal以`mode=ro + query_only=1`打开数据库；
5. 新增普通用户三级目录用量页面，并在ADMIN菜单增加同一数据的管理视图；
6. 页面显示根目录总用量、三级目录递归用量、文件数、目录数和快照年龄，明确标注JuiceFS逻辑计费口径；
7. 更新OpenAPI、数据模型、环境配置示例和T09实现合同。

文件明细浏览、文件属性、内容预览和下载仍未恢复，不在本轮范围。

## SQLite与安全验证

- schema：`api/schema/namespace-v1.sql`，使用generation隔离未完成快照；
- 查询索引：`idx_namespace_entries_tree(root_id, generation, kind, relative_path)`；单元测试的`EXPLAIN QUERY PLAN`确认使用该索引；
- SQLite数据源拒绝写SQL；API层同样拒绝POST等非只读方法；
- USER读取授权root返回200，读取未授权root返回403，访问ADMIN API返回403；
- 自动化USER token不绑定目录；真实挂载路径、META和存储凭据不进入响应；
- live环境未配置`PORTAL_NAMESPACE_DB`时，目录API返回503而不是fixture或空数据。

## 离线验收

| 项目 | 结果 |
|---|---|
| Go test / vet | PASS |
| SQLite只读、schema版本和索引计划 | PASS |
| JavaScript语法、fixture JSON、OpenAPI只读方法门 | PASS |
| 本机USER登录及授权root | 200，只有`team-a` |
| USER访问未授权root / ADMIN API | 403 / 403 |
| POST目录API | 405 |
| USER三级树 | 6个fixture目录，最大深度3，fresh |
| Portal构建 | 11,116,706-byte静态ELF，无动态依赖 |

构建二进制SHA256为`ae01f8f9a12ba6734fef73a79e9a3e6b214cf5c427c23e678d833fe86b0059d1`。

## 状态和下一步

本轮完全在WSL本地完成；未上传152、未修改当前Portal、未建立业务卷只读挂载，也未改变157或集群状态。

下一步实现后台快照采集器，并先对本地目录和现有T09临时卷验证“新generation事务切换、失败保留旧快照、60秒刷新和资源上限”。验证通过后再冻结152专用只读挂载及collector timer的sudo计划，单独申请远端批准。
