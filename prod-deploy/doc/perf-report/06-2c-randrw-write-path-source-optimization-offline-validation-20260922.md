# 06-2c randrw写路径源码候选离线验证报告

> 日期：2026-09-22  
> VERDICT：`SOURCE_GATE_PASS / ENVIRONMENT_GATE_PASS / READONLY_INVENTORY_PASS / AWAITING_EXPLICIT_ENVIRONMENT_WRITE_AUTHORIZATION / NOT_FOR_PRODUCTION`  
> 权威证据：`/mnt/c/SunRise/test/06-2c/20260922-164957/offline/`

## 一、结论

06-2c只选择并实现了一个候选：对一次完整覆盖、文件全局偏移按卷`BlockSize`对齐且不增长文件的
对象块，在隐藏且默认关闭的实验开关下立即冻结slice，继续沿用既有
`flushData → Finish → FIFO commitThread → meta.Write`链路。目标是把可提前完成的写提交移出后续
读前flush等待；没有跳过上传、元数据提交或read-your-own-writes保障。

该候选的开关边界、跨chunk全局对齐、默认关闭、已知内容读回、读前完成既有提交链路、race、相关
VFS回归及同源Ceph C/T构建均通过。远端只读inventory和环境编排离线Gate也已完成；尚未上传候选、
暂停portal、修改Ceph flag、挂载或运行fio，不能宣称存在性能收益，也不能作为生产二进制。

## 二、候选与身份

| 项 | 内容 |
|---|---|
| 冻结源码 | 官方v1.4.1 commit `0b90c7d` + B-catchup |
| 源码包SHA256 | `a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451` |
| 候选补丁 | `debug/06-2c-eager-freeze/eager-freeze.patch` |
| 补丁SHA256 | `ad7a41a9ab68bc4dbb861d2a1f92c4c1c6f3f88fe45b2ab6ae960397a63ac753` |
| Gate脚本 | `scripts/FULLBASELINE/debug/t06-2c-gate0-offline.sh` |
| C SHA256 / MD5 | `a0c7d0fcabe5eacb2599cc299eaf51d9879611369bf7754b6e245884c78f8cea` / `9d8df3a58e63ba96aa55ccf167b6e245` |
| T SHA256 / MD5 | `5a502e83e5dd9fb7ac7062c09babb49bedfc5e770f99d967baf9fd688ae73304` / `0410a03810865d0994c53d568281687b` |
| version | C/T均为`1.4.1+2026-07-30.0b90c7d` |

补丁增加隐藏参数`--experimental-eager-freeze`，默认关闭。触发条件是：非增长覆盖写、slice相对偏移为0、
单次写入恰好一个`BlockSize`、slice长度恰好一个`BlockSize`，并以
`chunk_index × 64 MiB + slice_offset`检查文件全局对齐。部分、非对齐、增长写均保持原路径。

## 三、离线Gate结果

| 检查 | 结果 |
|---|---|
| 权威源码身份与补丁重新应用 | PASS |
| 默认关闭、完整/部分/非对齐/增长触发边界 | PASS |
| 非整除BlockSize下跨chunk全局对齐 | PASS |
| 提前冻结后在任何读或显式flush前完成既有commitThread/meta.Write | PASS |
| 真实内存VFS已知内容读回 | PASS |
| 候选定向`-race` | PASS |
| `TestVFSBasic/TestVFSIO/TestFill` | PASS |
| cmd编译、C/T同工具链Ceph构建、CLI开关探针 | PASS |
| 完整`pkg/vfs`套件 | `NOT_RUN_ENV_BLOCKED`：本机缺Redis/socket条件，不记PASS |
| 远端环境访问 | 只读inventory `PASS`；环境写与正式负载`NOT_RUN` |

Luna独立复核最初发现补丁以chunk内偏移代替文件全局偏移；修订后用3 MiB这一不能整除64 MiB chunk的
测试直接覆盖该边界，并重新从冻结源码构建和签收。有效RUN只认`20260922-164957`。

环境编排有效Gate为`20260922-173817`：`C1→T1→T2→C2`、最多5次恢复、C/T非增长覆盖语义smoke、
排空失败保留现场、严格SSH主机校验及portal恢复闭环均通过离线自测和独立复核。正式phase只能由wrapper
启动；只有152 portal/mount/collector/timer按原状态恢复且wrapper返回0，分析器才接受四轮证据。
环境Gate、只读inventory、缓存合同和精确授权计划已持久化至
`/mnt/c/SunRise/test/06-2c/20260922-173817/preflight/`，总清单复核PASS。

## 四、事故与证据边界

- `20260922-163500`因`/tmp`空间不足导致编译失败，属于无性能结果的工程事故；仅精确删除本任务可重建
  的临时源码/构建目录后重跑。
- `20260922-164858`和`20260922-164927`分别暴露手工补丁hunk计数错误，均在测试执行前失败；不进入有效证据。
- 旧有效但边界修复前的`20260922-163700`被本报告的最终RUN取代，不作为环境候选身份。
- 最终持久目录内`manifest.sha256`逐项校验通过；`/tmp`只作中转，不作为权威证据。

## 五、下一步

下一步是取得一次明确的环境写授权，然后由冻结wrapper完成真实FUSE语义smoke和
`C1 → T1 → T2 → C2`四轮筛选。主挂载保持挂载且必须空闲；只暂停152的namespace采集挂载，portal主体在线。

共享会话暂停、scrub flag、全卷GC/compact、上传二进制、私有挂载、fio和清理均属于后续环境写操作，
已在只读计划列明，仍须重新取得批量授权；两项离线PASS不构成这些操作的授权。
