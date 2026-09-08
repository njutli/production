# 04-tmp2f writeback排空归因与容量曲线正式报告

## 一、结论

```text
ROOT_CAUSE=ENOSPC_HARDLINK_LIFECYCLE_CAUSE_CONFIRMED
CURVE=COMPLETE
CAPACITY=OBSERVED_MIN_SAFE_POINT:19.502_GiB
W20/W32/W64=OBSERVED_SAFE_POINT
W128=LIFECYCLE_FAIL_AT_900S
PRODUCTION_STATUS=CONDITIONAL_ENHANCEMENT; REQUIRE_DUTY_CYCLE_CANARY
```

04-tmp2e的16 GiB失败已经闭合到文件和源码：cache ext4接近满盘时，两个已经写入
`rawstaging`的文件在创建到`raw`的hardlink时收到`ENOSPC`；错误分支改走对象直传，却没有把这两个
文件登记到原daemon的后续扫描队列。原daemon因此900秒后仍有两个残留，恢复挂载初始化时全目录重扫
才将其发现并处理。普通`upload it directly`回退本身不是故障：历史20 GiB及本RUN四档均有大量回退，
但没有出现同类hardlink残留。

容量曲线显示：20、32和64 GiB均能严格排空，分别用时`82/100/355s`；128 GiB在900秒时仍约有
`40.5 GB` rawstaging数据，判`LIFECYCLE_FAIL`。这不是数据丢失：原daemon随后继续排空，同cache恢复
挂载后抽读文件0/63/127全部通过，最终对象数也回到seed容差内。

## 二、容量曲线

固定负载为128个既有1 GiB文件、256 KiB randwrite、libaio、iodepth=128、180秒；每档只测一次，
所以这是工程容量曲线和观测安全点，不是正式效应量。

| 档位 | 实际可用GiB | 正式窗前台MiB/s | 峰值staging/可用空间 | 最小空闲GiB | 95%/99%/严格排空 | 含排空有效MiB/s | direct fallback | 容量错误 | 裁决 |
|---|---:|---:|---:|---:|---|---:|---:|---|---|
| W20 | 19.502 | 2921.63 | 96.95% | 0.169 | 80.0/81.0/82s | 2001.50 | 1,606,298 | 0 | `OBSERVED_SAFE_POINT` |
| W32 | 31.185 | 2494.01 | 94.44% | 1.244 | 100.2/100.2/100s | 1566.01 | 1,315,976 | 0 | `OBSERVED_SAFE_POINT` |
| W64 | 62.429 | 2405.62 | 91.24% | 4.518 | 351.0/354.3/355s | 828.21 | 1,076,810 | 0 | `OBSERVED_SAFE_POINT` |
| W128 | 124.917 | 2373.28 | 89.43% | 11.436 | 900s仍未排空 | NA | 285,153 | 0 | `LIFECYCLE_FAIL` |

四档`real_enospc/hardlink_error/noncapacity_upload_error`均为0。W128最后一秒采样仍有154,563个文件、
40,522,709,088字节；紧接着的并发文件快照记录154,391个文件、40,477,614,816字节。数量差来自
daemon在递归扫描期间仍持续排空，不是丢证；正式卸载时已自然排空，所以稳定卸载后快照为空集。

容量越大没有让180秒持续写更快，反而显著延长任务结束后的持久化尾部：小cache较早触发直接上传
回退，限制了本地积压；大cache吸收更多前段突发，把压力转移为更长的后台排空。故不能用“cache越大
越好”选择生产容量，也不能只看fio前台返回带宽。

## 三、生产意义

- writeback仍可作为“客户端有空闲盘、文件由单客户端独占写”的条件性生产增强；它能吸收前段突发，
  但前台成功不等于后端已完成持久化。
- 本负载下首个新测观测安全点是19.502 GiB；考虑W20最小空闲仅约0.17 GiB，工程上更适合把32 GiB
  作为后续业务canary起点，而不是把20 GiB写成生产硬下限。
- 64 GiB虽通过，但355秒尾部已明显偏长；128 GiB不满足900秒生命周期门。生产最终容量必须结合
  实际写突发大小、空闲窗口和宕机持久性要求做占空比canary。
- 若再次出现`stage@disk_cache.go:804` hardlink ENOSPC，原daemon可能遗留孤立rawstaging；运维上应
  避免把cache打满，并监控staging数量/字节和空闲空间。源码层可考虑让失败分支显式登记或清理stage，
  或让周期扫描覆盖孤立rawstaging。

## 四、有效性、恢复与事故

- 四档fio均128 jobs、`error=0`；每档之后均完成同一GC、六OSD compact和TiKV cooldown，对象数最终
  分别为`1,978,906/1,979,229/1,979,529/1,979,629`，seed=`1,978,607`，均在`±8192`内。
- W20/W32/W64严格排空；W128 timeout后同cache恢复挂载并完成三个固定文件抽读；所有RUN专属挂载、
  loop和backing均已精确清除。
- `noscrub/nodeep-scrub`由本RUN state lease设置并恢复；终态为Ceph `HEALTH_OK`、6/6 OSD up/in、
  97 PG `active+clean`，业务卷UUID和挂载PID不变。
- 执行中修复三项确定性脚本问题：Gate摘要旧fixture RUN_ID、私有Ceph配置未显式绑定admin keyring、
  TIMEOUT时并发rawstaging扫描把文件消失误当命令失败。前两项发生在fio前；第三项从原W128现场续跑，
  未重跑、未替换性能样本。实际脚本版本和incident均保留。
- 修正版分析器在本地权威证据树复算返回`CURVE=COMPLETE`。TIMEOUT判据要求900秒初始快照非空且不
  超过最后聚合采样，并校验正式卸载后的稳定`(path,inode,size)`集合为初始快照子集；允许原daemon
  在故障修复等待期间自然排空到空集。

## 五、证据索引

- 权威证据：`/mnt/c/SunRise/test/04-tmp2f/20260904-195053/final/`
- 本地复算：`final/derived/analysis.json`
- 文件级根因：`/mnt/c/SunRise/test/04-tmp2f/20260904-195053/root-cause/`
- W16原始日志：`/mnt/c/SunRise/test/04-tmp2e/20260903-181523/w16-review/juicefs-formal.log.gz`
- W16残留清单：`/mnt/c/SunRise/test/04-tmp2e/20260903-181523/failure-closure/pre-rawstaging.tsv`
- 本RUN各档：`final/raw/opencode-04tmp2f-20260904-195053/cells/`
- 每档恢复：`final/raw/opencode-04tmp2f-20260904-195053/recovery/`

