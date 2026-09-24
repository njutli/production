# 06-2b range-flush修复离线验证报告

> 日期：2026-09-21  
> VERDICT：`OFFLINE_REPAIR_AND_GATE_PASS / ENVIRONMENT_NOT_RUN / NOT_FOR_PRODUCTION`  
> 权威证据：`/mnt/c/SunRise/test/06-2b/20260921-124344/offline/`

## 一、结论

06-2旧range-flush实现中两项可确定复现的问题已完成修复：

1. 固定大小覆盖写的slice提交后也会广播`commitcond`，不再只能等待100ms轮询发现完成；
2. 依赖已提交且从队列移除时，不再扫描其chunk并误纳入后续无关slice；若发现不符合不变量的
   “未提交依赖不在live队列”，保守回退为全live slice，而不是冒险漏等。

修正版的确定性回归、相关VFS回归、race检查和C/T同工具链Ceph构建全部通过。当前只证明
**实现具备进入环境语义smoke及性能对照的离线条件**；没有运行fio、挂载或访问157，不能据此声明
randrw已有性能收益，更不能作为生产二进制交付。

## 二、源码与修复范围

| 项 | 内容 |
|---|---|
| 源码基座 | 06-2冻结的官方v1.4.1 commit `0b90c7d` + B-catchup |
| 源码包SHA256 | `a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451` |
| 修复补丁 | `prod-deploy/debug/06-2b-range-flush/range-flush-repair.patch` |
| 补丁SHA256 | `c1d6240e77f4e665a54d6ed19d5cd109f318ca72ddae4368034d215ad11722b3` |
| Gate脚本 | `scripts/FULLBASELINE/debug/t06-2b-gate0-offline.sh` |
| 分类 | 调查构建，`NOT_FOR_PRODUCTION` |

行为改动限定为：

- `VFS.Read`将整inode `Flush`改为请求范围对应chunk及其未提交依赖FIFO前缀的`FlushRange`；
- 所有slice完成元数据提交后广播条件变量，包括非growing覆盖写；
- 已提交依赖直接排除，未提交依赖只扩展到其live FIFO前缀。

`Flush/FlushAll/Close/fsync/Truncate/CopyFileRange`仍保持整inode flush。修复没有降低等待超时，
也没有删除read-your-own-writes保障：读仍须等待所选脏slice的数据上传、依赖和元数据提交完成。

## 三、确定性缺陷复现与修复验证

| 用例 | 旧逻辑 | 修正版 |
|---|---|---|
| 非growing覆盖写提交通知 | FAIL：已注册waiter 1秒内未被唤醒 | PASS：真实提交广播唤醒 |
| 已提交依赖出队后的范围 | FAIL：误触发全量回退并纳入无关后缀 | PASS：只保留主目标 |
| commit早于waiter | — | PASS |
| 四个并发waiter | — | PASS |
| 虚假唤醒 | — | PASS：重新检查`committed`谓词 |
| timeout不伪装成功 | — | PASS |
| error传播、cancel | — | PASS；cancel保留正常3秒条件等待，不靠缩短轮询伪修复 |
| 真实写路径跨chunk多级增长依赖 | — | PASS，读回内容正确 |
| 固定文件覆盖写无增长依赖 | — | PASS |
| 多handle、重叠、跨chunk、EOF | — | PASS |

旧逻辑负例通过两个fixture补丁重新引入对应缺陷后运行同一测试获得，不是静态grep推断。

## 四、回归与构建结果

| Gate | 结果 |
|---|---|
| 归档路径/类型安全 | PASS |
| 修复补丁从权威包重新应用 | PASS |
| Read范围化且Truncate/CopyFileRange保持全量语义 | PASS |
| `TestVFSBasic/TestVFSIO/TestFill` + 全部range定向用例 | PASS，4.903秒 |
| 全部range用例`-race` | PASS，4.136秒 |
| C/T同Go版本、依赖、tags、CGO/ldflags构建 | PASS |
| 环境访问 | `NOT_RUN` |

完整`pkg/vfs`测试另行尝试，运行到Redis后端用例时被本地沙箱禁止连接`127.0.0.1:6379`而失败。
因此本报告不把全包测试写成PASS；完整输出已归档。该限制不影响已完成的直接相关内存后端回归，
但环境语义smoke仍不能省略。

最终离线二进制身份：

| 构建 | SHA256 | MD5 | version |
|---|---|---|---|
| C同源基座 | `b713e595a0fd320217913617098e91107de065285860498079e1777a61b2bbbc` | `4ea96bfb923733555221279d0a71083e` | `1.4.1+2026-07-30.0b90c7d` |
| T修正版 | `4ffd69637d43a1c33725f540124e7569957cf1c6541cea7fc49b0fa3bf38a4b2` | `2f28b8a4fefa78dc95dfaa8b91f72844` | `1.4.1+2026-07-30.0b90c7d` |

C与T均为本轮同源调查构建，C不冒充历史交付H；后续环境计划仍须核实H的
MD5 `24fae0852051c80ca571cb2f20275d46`。

## 五、证据与下一步边界

持久化包包含修复/负例补丁、Gate脚本、负例输出、正向/race日志、全包测试尝试、C/T二进制及
两层SHA256清单，外层`SHA256SUMS`已全通过。旧的`20260921-124002`目录是补齐error/cancel用例前的
中间快照，不作为最终离线裁决；本报告只引用`20260921-124344`。

最终持久化校验通过后，本轮新建的`/tmp/opencode-06-2b-*`源码/构建目录、证据中转目录及Go构建
缓存已按精确路径删除，释放约4GiB；未清理`/tmp/opencode`冻结权威树，也未删除任何历史证据。

下一步只能进入任务书停点1：重新做只读inventory并输出H/C/T身份、语义smoke、六格性能矩阵、
缓存容量、业务保护、scrub恢复和全部写操作计划。获得明确环境授权前，不上传、不挂载、不运行fio。
