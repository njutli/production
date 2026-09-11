# 数据模型与刷新 SLA v1

> 状态：`FROZEN`

## 1. 核心实体

| 实体 | 主键 | 必要字段 | 关系 |
|---|---|---|---|
| `Cluster` | `clusterId` | name、health、collectedAt、freshness | 包含节点、组件、卷、pool |
| `Node` | `nodeId` | hostname、mgmtIp、roles、cpu、memory、network、status | 承载组件和磁盘 |
| `Component` | `componentId` | kind、nodeId、role、version、endpoint、status、startedAt | kind 为 client/PD/TiKV/MON/MGR/OSD |
| `Disk` | `diskId` | nodeId、device、model、serial、size、numa、mounts、purpose、health、io | 可映射 TiKV 或 OSD |
| `Volume` | `volumeId` | name、logicalUsed、usedInodes、clients、status | 使用 metadata cluster 和 Ceph pool |
| `Pool` | `poolId` | name、profile、stored、rawUsed、maxAvailable、pgState、io | 包含 OSD/PG 状态摘要 |
| `Client` | `clientId` | nodeId、volumeId、mountpoint、version、uptime、io、cache、status | 对应 JuiceFS metrics endpoint |
| `Alert` | `alertId` | severity、objectRef、summary、activeSince、updatedAt、status | 关联任一实体 |
| `DirectoryUsageRoot` | `rootId` | displayName、logicalBytes、fileCount、dirCount、collectedAt、status | 绑定一个或多个本地账户 |
| `DirectoryUsageEntry` | `rootId + generation + path` | parentPath、name、kind、depth、recursiveBytes、fileCount、dirCount | 属于一个三级用量快照；kind为directory/file/aggregate，总量完整但每目录具名项限top 100 |
| `SampleMeta` | 内嵌 | source、collectedAt、ageSeconds、freshness、error | 附在所有动态对象上 |

T09只建立目录递归用量快照，不建立文件内容、下载或同步Namespace浏览实体。文件明细继续延期。

## 2. 动态拓扑关系

```text
Client --mounts--> Volume
Client --metadata--> PD cluster --stores--> TiKV
Volume --data--> Ceph Pool --places--> OSD --uses--> Disk
PD/TiKV/MON/MGR/OSD --runs_on--> Node
```

节点、设备用途和预期组件来自版本化静态清单；Leader、Active、Up/In、在线和吞吐来自实时数据。两者冲突时页面标黄并同时显示 expected/observed，不能用静态值覆盖实时异常。

## 3. 新鲜度状态

- `fresh`：年龄不超过该源的最大正常年龄；
- `stale`：已超过最大正常年龄但仍有旧值；
- `unavailable`：没有成功样本或连续三个采集周期失败；
- `unknown`：字段在当前版本的数据源中不存在。

任何数值都必须随 `SampleMeta` 返回。`stale/unavailable/unknown` 不得转换成 0。

## 4. 采集与页面刷新 SLA

| 数据源 | 后端采集 | 最大正常年龄 | 页面读取 |
|---|---:|---:|---:|
| JuiceFS metrics | 10 s | 25 s | 5 s |
| Node Exporter/网络/磁盘 I/O | 10 s | 25 s | 5 s |
| PD/TiKV metrics 与只读 API | 15 s | 35 s | 5 s |
| Ceph mgr metrics | 15 s | 35 s | 5 s |
| 动态拓扑聚合 | 30 s | 70 s | 10 s |
| 全局容量 | 30 s | 70 s | 10 s |
| SMART/NVMe | 300 s | 660 s | 30 s |
| 告警规则 | 15 s | 35 s | SSE 或 5 s |
| 三级目录用量快照 | 60 s | 180 s | 30 s |

页面只调用 Portal API。前端可每 5 秒轮询总览或使用 SSE；不要求 WebSocket。图表默认查询 1 分钟 rate，避免把 counter 瞬时差当带宽。

## 5. 降级约定

- 某个 exporter 失联只标记对应对象过期，不让整个 API 失败。
- Prometheus 失联时返回最后缓存和 `stale`，不改查集群 CLI。
- 静态清单仍可展示灰色拓扑，但必须注明实时状态不可用。
- 任何后端请求不得因页面刷新去 SSH、sudo、执行 `ceph`/`smartctl` 或扫描目录。
