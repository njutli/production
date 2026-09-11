# T09三级目录用量快照设计

> 状态：`DEPLOYED`；已冻结为“汇总全量准确、每个目录展示top 100直接子项”，152业务卷接入于2026-09-11签收通过。

## 1. 本轮范围

T09只恢复“授权根目录三级以内的递归用量与大项”，不恢复文件内容预览、下载或完整文件系统浏览。页面显示：

- 授权根目录总逻辑用量、文件数、目录数；
- 根目录以下最多三级、每个目录按递归用量选出的top 100直接子项（文件和目录）；
- 超过top 100的其余直接子项合并为明确标注的`其余项（聚合）`，其容量、文件数和目录数仍计入父目录总量；
- 快照采集时间、年龄及fresh/stale状态。

所有值采用JuiceFS `DirStats`逻辑计费口径。页面请求只查询152系统盘上的SQLite，不执行`du`、JuiceFS CLI、SSH或现场目录扫描。

### 明确限制

- JuiceFS 1.4.1的`summary --entries`单层最大值为100；大于100会被CLI钳制为100；
- 父目录的总容量、文件总数和目录总数覆盖全部后代，但明细只展示每个目录最大的100个直接子项；
- `其余项（聚合）`不提供被合并项的名称，不能被解释为“全部文件清单”；
- `summary`不提供修改时间，当前快照不承诺文件或目录mtime；
- 单root快照与单次API响应仍设10,000行保护上限，超过时保留上一代快照并标记失败，防止管理查询挤占业务资源。

## 2. 数据流

```text
152专用JuiceFS控制挂载（内核rw、无allow_other、`--atime-mode noatime`）
        │ 后台采集，计划60秒一次
        ▼
JuiceFS summary fast / 逻辑只读统计请求
        │ 单事务写入新generation
        ▼
/var/lib/juicefs-portal/portal/namespace.db
        │ Portal以SQLite query_only方式读取
        ▼
GET /api/v1/usage/roots
GET /api/v1/usage/tree?rootId=...&maxDepth=3
        ▼
USER授权目录页 / ADMIN目录用量页
```

采集失败时不得清空当前generation；保留最后一次成功快照并标记stale。页面显示时间戳，不能把旧数据呈现成实时值。

## 3. SQLite合同

版本化schema位于`api/schema/namespace-v1.sql`：

- `snapshot_roots`：每个授权根一行，保存当前generation、汇总和采集状态；
- `namespace_entries`：按`root_id + generation + relative_path`唯一保存`directory/file/aggregate`三类明细；
- `idx_namespace_entries_tree`：服务`root_id + generation + path order`的三级树查询；
- Portal连接固定为`mode=ro + query_only=1 + busy_timeout=1000`，没有写数据库的能力；
- 单次树响应硬限制10,000行，`maxDepth`硬限制1～3。

真实主机挂载路径、META URL、TiKV地址和Ceph凭据都不得写入API响应。

## 4. 权限合同

- 本地账户可选字段`namespaceRoots`保存允许访问的opaque root ID；
- USER只能列出并查询自己绑定的root ID；越权root返回403；
- ADMIN可查看SQLite中的全部root，但仍只有GET权限；
- `rootId`只允许`[a-z0-9._-]`，API不接受主机路径，因此不存在通过`..`访问挂载点的入口；
- 自动化USER token不默认绑定任何目录。

## 5. 刷新合同

- 后台采集目标周期：60秒；
- 快照正常年龄：不超过180秒；超过后显示stale；
- USER页面：30秒读取一次SQLite，支持手工刷新；
- ADMIN页面继续沿用门户轮询，但请求同样只读SQLite；
- 低频strict抽样用于审计DirStats，不进入每个采集周期。

阶段B/B2/C已证明10万文件下fast约0.05秒且有序变更结果正确；同步`du`约22秒，禁止进入HTTP请求路径。

## 6. 签收状态

采集器本地及T09临时卷验证已完成：10万文件/1111目录单次采集0.08～0.09秒，失败保留旧generation，恢复后正常切换；152真实业务卷已验证top 100及聚合行、USER/ADMIN权限、Portal路径隔离、60秒刷新、资源上限和业务指纹，详见`inventory/T09-BUSINESS-NAMESPACE-DEPLOYMENT-FINAL-SIGNOFF-20260911.md`。
