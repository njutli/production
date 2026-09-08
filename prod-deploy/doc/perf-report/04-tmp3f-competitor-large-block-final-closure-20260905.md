# 04-tmp3f竞品大块单流读最终收口报告

> 日期：2026-09-05
> RUN_ID：`20260905-125702`
> VALIDITY_STATE：`VALID`
> VERDICT：`READ_TARGET_NOT_MET_WITH_THREE_L1_SIGNALS`
> 环境：patched JuiceFS 1.4.1，B256，cache=0，单客户端同步QD1。

## 一、结论

同一B256卷、同一32GiB只读文件的10格镜像矩阵一次完成，确认三个现有参数方向都有一致收益：

- fio `bs=256K→20M`：A臂两组`+52.26%/+52.08%`；
- `max-readahead=8M→32M`：两组`+14.63%/+12.38%`；
- `max-fuse-io=256K→1M`：两组`+14.22%/+11.17%`。

三项叠加后，20MiB同步单流读由A臂平均`2264.58 MiB/s`提高到C臂平均`2897.12 MiB/s`，
合计约`+27.93%`。但最佳单格仅`2963.95 MiB/s`，为竞品公开目标`5149.84 MiB/s`
（5.4 GB/s）的`57.55%`，仍差`42.45%`；项目6250 MiB/s目标也未达到。

因此，RA32与`max-fuse-io=1M`可登记为**20MiB顺序读专项L1候选**，但不能直接覆盖256KiB七项
生产基线。结合04-tmp3d/e，现有挂载参数已能提高同步入口的在途请求，却仍不能利用对象层全部余量；
继续跨越竞品线需要应用异步/多请求，或修改JuiceFS Reader/FUSE请求流水线，而不是继续盲调现有参数。

## 二、针对性配置与矩阵结果

公共配置：

```text
BlockSize=256KiB
--max-downloads 200
--max-uploads 150
--buffer-size 300
--cache-size 0
Ceph client ms_async_op_threads=8
fio: read / psync / iodepth=1 / numjobs=1 / direct=1 / size=10G / runtime=60s
```

| Cell | bs | readahead | max-fuse-io | 正式窗 MiB/s | CV | GET在途量 |
|---|---:|---:|---:|---:|---:|---:|
| A01 | 256K | 8M | 256K | 1486.82 | 3.83% | 5.72 |
| A02 | 20M | 8M | 256K | 2263.78 | 2.50% | 9.48 |
| B01 | 20M | 32M | 256K | 2594.89 | 4.54% | 11.52 |
| C01 | 256K | 32M | 1M | 1628.41 | 3.84% | 6.20 |
| C02 | 20M | 32M | 1M | **2963.95** | 4.58% | **14.12** |
| C03 | 20M | 32M | 1M | 2830.29 | 5.36% | 13.32 |
| C04 | 256K | 32M | 1M | 1650.89 | 5.18% | 6.35 |
| B02 | 20M | 32M | 256K | 2545.89 | 5.46% | 11.32 |
| A03 | 20M | 8M | 256K | 2265.39 | 3.12% | 9.49 |
| A04 | 256K | 8M | 256K | 1489.60 | 3.69% | 5.75 |

五组同配置锚漂移的绝对值最大为`4.51%`，低于预注册8%门；10/10 fio rc/error、正式窗、
metrics、sidecar、对象错误和资产门均通过。

## 三、为什么bs增大有收益但仍未达标

所有cell的平均对象GET大小仍约`256 KiB`，说明把fio bs增到20MiB没有改变B256对象几何；它减少
应用同步调用边界，并让readahead/Reader在一个应用I/O内维持更多并发。证据是：

- A臂从256K fio bs切到20M后，GET在途量约`5.74→9.49`，带宽约提升52%；
- RA32进一步把GET在途量提高到约`11.42`，带宽再提高约13.5%；
- `max-fuse-io=1M`把FUSE read次数明显减少，同时GET在途量提高到约`13.72`，带宽再提高约12.7%；
- 最佳cell客户端NIC接收约`3024 MiB/s`、CPU约`4.78`核，均未达到100GbE或整机上限。

GET平均延迟从A20约`1.047 ms`升至C20约`1.18 ms`并不矛盾：更高并发提高了排队和单请求平均
响应时间，但在途请求数增幅更大，所以总带宽仍上升。该结果再次说明总吞吐由“单请求延迟×在途数”
共同决定，不能只看GET次数或平均延迟中的一个指标。

## 四、与竞品和既有证据的关系

| 口径 | 带宽 | 相对竞品5.4 GB/s |
|---|---:|---:|
| 竞品fio 20M同步单流读 | 5149.84 MiB/s | 100% |
| JuiceFS A：B256/RA8/FUSE256K | 2264.58 MiB/s（两点平均） | 43.97% |
| JuiceFS B：B256/RA32/FUSE256K | 2570.39 MiB/s | 49.91% |
| JuiceFS C：B256/RA32/FUSE1M | 2897.12 MiB/s | 56.26% |
| JuiceFS C最佳单格 | 2963.95 MiB/s | 57.55% |
| 04-tmp3d直接RADOS 4MiB/QD8 | 5403.20 MiB/s | 104.92% |
| 04-tmp3e应用libaio QD8 | 5277.79 MiB/s | 102.48% |

竞品未披露后端、缓存和一致性条件，因此这里只比较公开fio口径，不写成严格同条件产品结论。

## 五、环境和证据闭环

- 只复用业务卷的既有只读文件；没有format、layout、写fio、RADOS seed、GC、compact或sudo；
- 六个本RUN只读挂载均优雅卸载，worker退出，挂载目录删除；无RUN fio或挂载残留；
- 业务挂载、volume name/UUID/BlockSize、业务worker和资产size/inode/mtime/hash前后一致；
- Ceph最终`HEALTH_OK`、6/6 OSD、PG全active+clean，远端incident为空；
- 本地归档SHA256为
  `64632678262adf0f86fc13056a7d11bcef9e68d47fbdf950153ed9e15e68d5be`，内层manifest
  `339/339 PASS`；GPT独立重算与远端裁决结构一致，最大浮点差仅`4.44e-16`。

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3f/20260905-125702
MANIFEST_PATH=archive内 closure/manifest.sha256
PERSISTENCE_STATUS=PASS
REMOTE_STATUS=PURGED_AFTER_PERSISTENCE_VERIFICATION
LOCAL_STATUS=PRESERVED
INCIDENT_STATUS=RESOLVED_TRANSFER_RETRY
ENVIRONMENT_ASSET_STATUS=CLOSED_NO_DATA_ASSET
```

首次scp校验曾出现本地临时副本SHA不一致；远端源SHA始终稳定，当时未立即清理，改用checksum重核后
最终持久副本与远端SHA一致。该事件只影响证据传输，不影响测试环境或raw内容。GPT完成独立复核后，
已精确删除该RUN的远端raw、归档、校验文件和脚本目录；复查四个路径均不存在，业务挂载正常，Ceph
仍为`HEALTH_OK`、6/6 OSD、97/97 PG active+clean。

## 六、后续动作

1. 若20MiB同步单流读是生产必需模型，将RA32+`max-fuse-io=1M`带入05阶段七项回归，重点检查
   256KiB randread/randrw非劣；
2. 若应用允许异步或同文件多请求，优先做QD4--8业务canary；已有证据表明这条路径可以达到竞品线；
3. 不再继续搜索RA64、纯bs或其他相邻挂载参数，关闭04-tmp3系列。
