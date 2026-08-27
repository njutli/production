# JuiceFS 源码检视计划

> 基座：main commit `53835e24`，共 ~86K 行 Go 代码（不含测试）
> 目标：系统性查找 bug 和可改进点，不局限于已上报的 flush 派发竞态

## 检视顺序与重点

按风险优先级排列：数据路径 > 元数据 > 存储后端 > FUSE 接口 > CLI > 工具

### 第一阶段：写路径（已完成部分）

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 1 | `pkg/vfs/writer.go` | 598 | 锁顺序、goroutine 时序、flush 派发、buffer 节流 | ✅ 已完成 |
| 2 | `pkg/chunk/cached_store.go` | 1252 | upload goroutine 引用计数、FlushTo/Finish/Abort 路径、writeback staging 超时、错误传播 | ✅ 已完成 |
| 3 | `pkg/vfs/compact.go` | 110 | compaction 读写逻辑、FlushTo panic 条件、错误处理 | ✅ 已完成 |
| 4 | `pkg/vfs/handle.go` | ~400 | Rlock/Wlock 死锁分析、handle 生命周期 | ✅ 已完成 |

**已发现问题**：flush 派发竞态、uploadError 数据竞争、stageFailed 数据竞争、Abort 孤儿对象

### 第二阶段：读路径

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 5 | `pkg/vfs/reader.go` | 935 | sliceReader 状态机（NEW/BUSY/READY/INVALID）、cache invalidation 时序、readahead 逻辑、并发读安全性 | 待检视 |
| 6 | `pkg/chunk/disk_cache.go` | 1059 | 磁盘缓存读写、stage/removeStage、缓存淘汰、并发安全 | 待检视 |
| 7 | `pkg/chunk/mem_cache.go` | ~300 | 内存缓存淘汰、Page 引用计数 | 待检视 |
| 8 | `pkg/chunk/prefetch.go` | ~200 | 预读逻辑、goroutine 泄漏 | 待检视 |
| 9 | `pkg/chunk/singleflight.go` | ~150 | 去重逻辑、重复请求处理 | 待检视 |

**重点**：reader 的 invalidate() 与 run() 的并发、disk cache 的 stage/removeStage 与 writeback 的交互

### 第三阶段：元数据引擎

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 10 | `pkg/meta/base.go` | 4094 | cleanupDeletedFiles、cleanupSlices、compactChunk、NewSlice、事务边界、锁使用 | 待检视 |
| 11 | `pkg/meta/tkv.go` | 5130 | doWrite、doCompactChunk、deleteChunk、txn 实现、key 编码 | 待检视 |
| 12 | `pkg/meta/tkv_tikv.go` | ~400 | TiKV 客户端、GC 机制、连接管理 | 待检视 |
| 13 | `pkg/meta/quota.go` | 1195 | 配额检查逻辑、并发安全、配额恢复 | 待检视 |
| 14 | `pkg/meta/dump.go` | 697 | 元数据 dump/load、大目录处理 | 待检视 |
| 15 | `pkg/meta/backup.go` | ~400 | 自动备份逻辑、并发安全 | 待检视 |

**重点**：compactChunk 的乐观锁（CAS）失败处理、cleanupSlices 的 refcount 竞态、txn 隔离级别

### 第四阶段：其他元数据引擎

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 16 | `pkg/meta/redis.go` | 6258 | Lua 脚本正确性、pipeline 错误处理、集群模式 | 待检视 |
| 17 | `pkg/meta/sql.go` | 6155 | SQL 注入风险、事务隔离、死锁、MySQL/PG/SQLite 差异 | 待检视 |

**重点**：三种引擎（Redis/SQL/TKV）的语义等价性，特别是 rename/unlink/compactChunk 路径

### 第五阶段：VFS 其他

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 18 | `pkg/vfs/vfs.go` | 1493 | Read/Write/Flush/Fsync 路径、锁顺序、特殊 inode 处理 | 待检视 |
| 19 | `pkg/vfs/internal.go` | 627 | 控制消息处理、accesslog | 待检视 |
| 20 | `pkg/fs/fs.go` | 1614 | 高层 FS 接口、直接调用路径 | 待检视 |

### 第六阶段：对象存储后端

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 21 | `pkg/object/object_storage.go` | ~800 | 对象存储抽象层、重试逻辑、错误分类 | 待检视 |
| 22 | `pkg/object/s3.go` | 645 | S3 协议实现、签名、分片上传 | 待检视 |
| 23 | `pkg/object/ceph.go` | ~300 | librados 绑定、内存管理 | 待检视 |
| 24 | 其他 object backends | ~3000 | 各后端的边界条件、错误处理 | 抽查 |

### 第七阶段：数据同步

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 25 | `pkg/sync/sync.go` | 2551 | 并发同步逻辑、断点续传、错误恢复 | 待检视 |
| 26 | `pkg/sync/checkpoint.go` | 837 | 检查点持久化、崩溃恢复 | 待检视 |

### 第八阶段：CLI 命令

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 27 | `cmd/mount_unix.go` | 1160 | 挂载参数解析、信号处理、graceful restart | 待检视 |
| 28 | `cmd/gc.go` | ~400 | GC 逻辑、--delete 路径、leaked 对象检测 | 待检视 |
| 29 | `cmd/format.go` | 623 | format 参数验证、卷创建 | 待检视 |
| 30 | `cmd/destroy.go` | ~200 | destroy 逻辑、对象清理 | 待检视 |

### 第九阶段：FUSE 与 Windows

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 31 | `pkg/fuse/fuse.go` | ~600 | FUSE 回调、参数传递、错误映射 | 待检视 |
| 32 | `pkg/winfsp/winfs.go` | 1486 | Windows FUSE 兼容性 | 抽查 |

### 第十阶段：工具与基础设施

| 序号 | 文件 | 行数 | 检视重点 | 状态 |
|------|------|------|---------|------|
| 33 | `pkg/utils/` | 2198 | buffer 管理、cond、timeout、logger | 抽查 |
| 34 | `pkg/acl/` | 404 | POSIX ACL 实现 | 抽查 |
| 35 | `pkg/gateway/` | 1668 | S3 gateway 兼容性 | 抽查 |

## 检视方法

对每个文件：
1. 通读全文，画出锁依赖图和 goroutine 时序图
2. 重点检查：数据竞争、死锁、资源泄漏、错误处理遗漏、边界条件
3. 检查跨文件交互：接口契约是否被遵守、锁顺序是否一致
4. 对照测试文件：测试是否覆盖了错误路径

## 优先级

- **P0**（数据安全）：写路径、元数据事务、对象删除
- **P1**（可靠性）：读路径缓存、GC、crash recovery
- **P2**（性能）：并发控制、内存管理、连接池
- **P3**（兼容性）：各后端差异、CLI 边界
