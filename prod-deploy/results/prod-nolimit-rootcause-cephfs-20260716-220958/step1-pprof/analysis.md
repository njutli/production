# 01-4 步骤1：pprof 热点分析

## 分析对象
- cpu-01-3.prof: 20s 采样（01-3 捕获），87.35s total samples（avg 436.74%）
- cpu-60s.prof: 45s 采样（01-4 重采），206.96s total samples（avg 459.91%）
- goroutine.txt: 稳态期 goroutine 快照，10555 行

## pprof top（flat，45s profile）

| 函数 | flat% | 含义 |
|------|-------|------|
| runtime.cgocall | 20.87% | Go→C 转换开销（writev + rados_read） |
| Syscall6 | 18.98% | 内核系统调用（writev/read on /dev/fuse） |
| [libc.so.6] | 16.17% | C 库函数（memcpy/malloc） |
| [libceph-common.so.2] | 7.40% | Ceph messenger（网络 I/O） |
| runtime.memmove | 4.17% | 内存拷贝 |
| [librados.so.2.0.0] | 2.26% | librados API |
| runtime.futex | 1.56% | 锁竞争（低） |
| runtime.stealWork | 1.54% | goroutine 调度 |
| Mutex.Lock | 0.74% | 互斥锁（低） |

## pprof -cum（调用链，45s profile）

| 调用路径 | cum% | 分类 |
|----------|------|------|
| fuse.Server.loop | 31.51% | **C1 FUSE 主循环** |
| └─ fuse.Server.handleRequest | 28.51% | C1 FUSE 请求处理 |
| └─ fuse.Server.write → writev → sys_writev | 17.54% | **C1 写回 /dev/fuse** |
| └─ cephReader.Read → rados.IOContext.Read | 16.03% | **C2 从 RADOS 读数据** |
| runtime.cgocall | 21.98% | C1+C2 共享 cgo 开销 |
| Syscall6 | 18.98% | C1+C2 共享系统调用 |
| [libceph-common.so.2] | 7.40% | C2 Ceph messenger |
| [librados.so.2.0.0] | 2.26% | C2 librados |
| runtime.futex + Mutex.Lock | 2.30% | C3 锁（次要） |

## goroutine 分布

| goroutine 状态 | 数量 | 含义 |
|----------------|------|------|
| (*Server) loop | 131 | FUSE server dispatch 循环 |
| (*rSlice).ReadAt.func1 | 128 | chunk 读取（每 fio job 一个） |
| (*fileReader)/(*dataReader) | 128 | JuiceFS 内部读处理 |
| (*IOContext).Read.func2 | 70 | librados 读调用 |
| (*ceph).Head.func1/Stat.func2 | 57 | 元数据操作 |
| pollDesc.waitRead | 20 | 网络 I/O 等待 |

- 无大量 goroutine 阻塞在同一处/锁
- 分布均匀（128 = fio numjobs，一致）

## C1/C2/C3 判定

| 候选 | 占比 | 判定 |
|------|------|------|
| **C1 FUSE /dev/fuse dispatch** | ~31% cum（主循环）+ 17.5% writev = **主路径** | ✅ **主要根因** |
| C2 librados/messenger | ~16% cum（rados_read）+ 7.4% messenger | 次要（被 C1 cgo 开销放大） |
| C3 Go runtime/锁 | ~2.3% flat | 次要（无单点锁死） |

## 结论

**pprof → C1（FUSE /dev/fuse dispatch 模型）为主要根因。**

- FUSE server loop 是最大调用路径（31.51% cum），其中 writev 写回 /dev/fuse 占 17.54%
- cgo + syscall 开销（20.87% + 18.98% = 39.85%）是 Go→C→kernel 用户态方案的核心税
- librados 读（16.03%）是次要开销，但在 CephFS 内核态下不需要 cgo/syscall 过渡
- 锁竞争（C3）仅 2.3%，非瓶颈因素

**客户端无对应旋钮**（FUSE dispatch 是用户态方案架构限制）→ 跳过步骤2，进入步骤3 CephFS 对照。
