# 04-tmp3g竞品16MiB异步写QD曲线收口报告

> 日期：2026-09-06  
> RUN_ID：`20260906-165126`  
> VALIDITY_STATE：`VALID`  
> VERDICT：`WRITE_ASYNC_TARGET_NOT_MET`  
> 环境：patched JuiceFS 1.4.1、既有B256 `juicefs-prod`、cache=0、writeback关闭。

## 一、结论

同一卷、客户端和16MiB单job顺序写口径下，`async_dio + libaio`没有释放写吞吐，反而从QD1开始
显著低于同步`psync/QD1`，并随QD升高继续下降。同步双锚平均`2578.69 MiB/s`；异步QD1/2/4
分别为`1349.73/1154.20/1100.98 MiB/s`，两次QD8仅`957.90/997.27 MiB/s`。

两次QD8分别只达到竞品`3051.76 MiB/s`目标的`31.39%/32.68%`，因此签署
`WRITE_ASYNC_TARGET_NOT_MET`并停止。04-tmp3e的异步QD8大块读收益不能外推到写路径；当前版本的
异步直接写不是该模型的生产候选。

## 二、正式矩阵

共同条件：`bs=16M,size=10G,direct=1,numjobs=1,time_based`；同步锚和QD8运行120秒，QD1/2/4
运行60秒；`max-fuse-io=1M,max-uploads=150,buffer-size=300`，Ceph客户端
`ms_async_op_threads=8`。

| Cell | 引擎/QD | 正式窗MiB/s | fio summary MiB/s | CV | clat mean | clat p99 |
|---|---|---:|---:|---:|---:|---:|
| S01 | psync/QD1 | 2679.26 | 2672.38 | 5.26% | 5.41 ms | 8.16 ms |
| C08A | libaio/QD8 | 957.90 | 986.99 | 17.70% | 124.09 ms | 308.28 ms |
| C01 | libaio/QD1 | 1349.73 | 1439.15 | 15.96% | 10.15 ms | 46.92 ms |
| C02 | libaio/QD2 | 1154.20 | 1243.83 | 14.25% | 24.65 ms | 80.22 ms |
| C04 | libaio/QD4 | 1100.98 | 1167.93 | 17.75% | 53.28 ms | 156.24 ms |
| C08B | libaio/QD8 | 997.27 | 1025.07 | 17.18% | 119.56 ms | 291.50 ms |
| S02 | psync/QD1 | 2478.13 | 2482.89 | 4.10% | 5.62 ms | 8.72 ms |

同步锚漂移`7.51%`、QD8重复漂移`4.11%`，均低于预注册`8%`门；七格fio、上传排空、格后Ceph
健康、实际挂载模式、PID、文件身份及重挂读回均通过。

## 三、机制解释与边界

- `libaio/QD1`已比同步平均低`47.66%`，下降不是“QD8过高”单一因素，而是当前写侧
  `async_dio/libaio`路径存在额外成本。
- QD从1升至8时完成延迟约从`10.15 ms`增至`120 ms`，吞吐没有随在途数增加，反而下降；证据
  支持写请求进入同一文件协调、缓冲/上传和后端队列后发生排队与背压，但不能精确归因到某行源码。
- 本RUN确认“增加异步写QD不是有效调优手段”。不扩测QD16、buffer、writeback或临时参数。

## 四、分析修复说明

首次分析错误地要求同一文件在性能挂载和只读验证挂载下的绝对路径字符串相等。原始证据先以SHA
`ab42db2bffb0765c546357a9e6b55896cb3259372866ddc411c2efa5bd28bd84`归档；随后仅把规则改为校验
RUN相对路径、inode、大小和首尾hash，raw前后SHA一致，未重跑或改写性能数据。

## 五、环境与证据闭环

- 七个RUN专属10GiB文件按冻结清单精确删除，随后仅执行一次已授权共享卷GC；
- 对象锚由准备前`1978609`、准备后`2265329`回到约`1.98M`，满足`O0±8192`；
- scrub租约恢复，无RUN挂载、fio或资产；Ceph最终`HEALTH_OK`、6/6 OSD、97 PG全active+clean；
- 最终证据归档SHA256：`874fb99a83580a311cd88d60984e8b58dc621eac3d289a9e7ebe4a040c8233fd`。

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3g/20260906-165126
MANIFEST_PATH=final归档内 closure/manifest.sha256
PERSISTENCE_STATUS=PASS
REMOTE_STATUS=ARCHIVE_PRESENT_PENDING_REVIEW
LOCAL_STATUS=PRESERVED
INCIDENT_STATUS=RESOLVED_ANALYZER_ABSOLUTE_PATH_COMPARISON
ENVIRONMENT_ASSET_STATUS=CLOSED
```

## 六、后续

关闭“16MiB异步写QD扩展”方向。04-tmp3h只回答客户端热读缓存与writeback能否在容量受控时使竞品
四条原始命令全部越线；该结论属于有本地缓存条件下的专项能力，不改变本RUN无缓存写侧结论。
