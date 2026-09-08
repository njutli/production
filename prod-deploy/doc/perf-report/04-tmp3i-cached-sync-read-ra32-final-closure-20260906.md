# 04-tmp3i缓存命中同步单流读RA32最终收口报告

> 日期：2026-09-06  
> RUN_ID：`20260906-222839`  
> VALIDITY_STATE：`VALID`  
> VERDICT：`BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET`  
> 环境：patched JuiceFS 1.4.1、B256 `juicefs-prod`、64 GiB NVMe loop/ext4、32 GiB读缓存。

## 一、结论

在正式读窗`100%` JuiceFS block-cache命中、Ceph数据网卡RX仅占fio读取量
`0.0030%--0.0037%`的条件下，RA32两次正式窗为`3556.86/3670.35 MiB/s`，平均
`3613.61 MiB/s`；仅达到竞品`5149.84 MiB/s`目标的`70.17%`。RUN有效，但两次均未越线，故签：

```text
BEST_KNOWN_CACHED_SYNC_READ_TARGET_NOT_MET
```

RA32相对RA8双锚平均只提升`4.89%`，没有在热缓存路径复现无缓存路径曾观察到的约12%--15%收益，
也不足以弥补约29.83%的目标差距。到此关闭“继续扩大缓存或调高同步单流readahead追平竞品”方向；
不再扩扫RA64、缓存容量、QD或相邻挂载参数。

同一loop/ext4的LOCAL1直读正式窗为`6846.36 MiB/s`，超过目标32.94%，说明本次本地介质具备目标
量级；JuiceFS热缓存同步读只有LOCAL1的约52.78%。剩余屋顶位于JuiceFS block-cache索引/拷贝、
FUSE/VFS及同步单请求处理路径的组合，不是缓存容量不足或Ceph后端回源。该RUN不再把组合差额强归因
到其中单一组件。

## 二、正式数据

共同fio：`read / bs=20M / size=10G / direct=1 / psync / QD1 / runtime=60s / time_based`；
A/B只改变`--max-readahead=8M/32M`，每格独立挂载并预热60秒。

| Cell | RA | fio summary MiB/s | 正式窗`[10,50)` MiB/s | CV | clat mean | clat p99 | cache hit | Ceph RX/fio |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| LOCAL1 | — | 6664.56 | **6846.36** | 2.17% | 3000.52 us | 5734.40 us | — | — |
| A1 | 8M | 3577.55 | 3568.03 | 4.69% | 5589.76 us | 9895.94 us | 100% | 0.003507% |
| B1 | 32M | 3579.04 | 3556.86 | 5.07% | 5587.41 us | 10158.08 us | 100% | 0.003571% |
| B2 | 32M | 3654.61 | 3670.35 | 7.04% | 5471.83 us | 9764.86 us | 100% | 0.002999% |
| A2 | 8M | 3345.67 | 3322.42 | 4.38% | 5977.19 us | 9895.94 us | 100% | 0.003746% |

| 汇总项 | 结果 |
|---|---:|
| RA8正式均值 | `3445.23 MiB/s` |
| RA32正式均值 | `3613.61 MiB/s` |
| RA32相对RA8 | `+4.89%` |
| RA32距竞品目标 | `-29.83%` |
| A1/A2漂移 | `7.13%`（通过8%门） |
| B1/B2漂移 | `3.14%`（通过8%门） |

fio实测带宽与`20 MiB / clat_mean`估算闭合：B1/B2的估算值分别为`3579.47/3655.08 MiB/s`，
与summary仅差约0.01%。这说明当前同步单流吞吐直接受单请求约`5.5 ms`完成延迟约束；增大fio块大小
并未让同步入口形成足够并行度。

## 三、有效性和结论边界

- A/B四格的fio error均为0，正式窗均40/40秒覆盖；命中率、Ceph RX旁证及资产指纹门全部通过。
- 每格前后及最终均为Ceph `HEALTH_OK`、6/6 OSD up/in、97 PG严格`active+clean`。
- 既有32 GiB只读资产的inode、size、blocks、mtime及首尾hash执行前后完全一致；本RUN没有写入或删除
  JuiceFS数据，也没有执行GC、compact或pool/PG/CRUSH变更。
- LOCAL1只用于证明同一loop/ext4介质具有目标量级，不等价于JuiceFS缓存文件的直接读取，不能将两者差额
  全部归为FUSE或某一函数开销。
- 该结论只关闭20 MiB `psync/QD1`同步单流在现有实现中的缓存容量/RA参数方向；04-tmp3e已经证明
  `libaio/QD8`读可越过竞品线，但那是改变应用I/O并发模型，不是当前同步单流命令的可交付替代参数。

## 四、执行与生命周期闭环

- 首个只读inventory RUN `20260906-222655`因Bash局部变量初始化顺序触发`set -u`，在任何sudo、mount、
  loop或fio之前终止；证据保存在对应持久目录，正式数据不复用该RUN。
- 修复后新RUN通过本地与157远端Gate 0；唯一sudo面为本RUN目录、动态loop、ext4挂卸载及精确销毁。
- LOCAL1临时文件已在缓存目录建立前完成写满、`end_fsync`、直读和删除；随后执行固定ABBA矩阵。
- `/tmp/jfs-04tmp3i-mnt-*`、cache mount、`/dev/loop20`及64 GiB backing均已精确卸载、detach和删除；
  `STORAGE_CLOSED`、`EXECUTE_PASS`、`POST_SAFETY_PASS`均存在。
- `/mnt/juicefs`保持挂载；WekaIO、K8s相关进程和Ceph业务状态未受影响。

最终证据：

```text
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp3i/20260906-222839
ARCHIVE=final/raw/04tmp3i-20260906-222839-evidence.tar
SHA256=b6d8dcc079e6f8d07a972fe1f9c474822161d8dd090fc91ae5683e4ec84b2769
REMOTE_STATUS=PURGED
LOCAL_STATUS=COMPACTED
ENVIRONMENT_ASSET_STATUS=CLOSED
```

## 五、生产意义

RA32在热缓存同步读中只有约5%的工程收益，不能把缓存单流读推到竞品线，因此不单独升级为新的生产
交付参数。读缓存本身仍保留04-tmp2d已经确认的多并发读收益；本结果只说明即使数据完全驻留本地缓存，
单应用线程的20 MiB同步读仍受约5.5 ms端到端请求周期限制。若必须追平竞品同步单流指标，需要代码层
增加单流内部流水化/并发预取或改变应用I/O模型，而不是继续扩大缓存容量。
