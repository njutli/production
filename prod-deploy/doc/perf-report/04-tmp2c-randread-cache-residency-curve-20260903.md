# 04-tmp2c randread 本地读缓存驻留曲线报告

## 一、结论

```text
RUN_ID=20260903-141500
EVIDENCE_LEVEL=L1_SCREEN
FORMAL_VERDICT=CACHE_RESIDENCY_CURVE_INVALID_BY_PREREGISTERED_DROP_GATE
ENGINEERING_VERDICT=CACHE_BENEFIT_CONFIRMED_WHEN_HOTSET_NEAR_FULLY_RESIDENT
WRITEBACK_VERDICT=NOT_TESTED; 04-tmp2b SAFETY_BLOCK REMAINS
ENVIRONMENT_CLOSURE=PASS
```

04-tmp2b的“16/32/64 GiB”缓存实际受低inode密度限制，只容纳约`4/8/16 GiB`，并非
名义容量。04-tmp2c改用inode充足的现有ext4，把固定热集缩为`16 GiB`，完成
`cache=0/2/4/8/16/32 GiB`七个只读cell。

结果确认：当缓存只覆盖热集一小部分时，randread收益有限；当热集接近全部驻留时，命中率升至
`95.83%--100%`、Ceph数据网流量降至逻辑读取量的`4.25%--接近0`，带宽从无缓存同窗均值
`3654.16 MiB/s`升至约`35.3k MiB/s（34.5 GiB/s）`。这解释了04-tmp2曾观察到的约10倍热集信号，也证明
04-tmp2b的近零收益主要来自测试容量合同错误，而不是JuiceFS读缓存无效。

但本RUN不能签正式生产容量曲线：预注册合同把任何`blockcache_drops`列为硬失败，C02--C16均
出现drops，执行器却没有在C02后立即停止；A0前后还漂移`9.36%`，C08未过轮内稳定门。因此
小容量点只作工程观察，不交付具体生产档位。

## 二、测试条件

- JuiceFS：exact patched v1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46`；
- 后端：现有`juicefs-prod` TiKV/Ceph，只读访问，不新建pool、不做layout；
- 数据集：128个既有1 GiB文件，每个只访问前128 MiB，固定热集`16 GiB`；
- fio：128 job、randread、256 KiB、iodepth=128、direct=1、固定随机种子；
- mount：`--read-only --prefetch 0 --max-fuse-io 256K --max-uploads 150`；
- 缓存：157本地NVMe原生ext4 `/mnt/jfs-cache` 的RUN专属目录；每档空缓存预热180秒，再正式180秒；
- 明确未启用`--writeback`，未修改Ceph、TiKV、网卡、内核或参考挂载。

## 三、结果

主窗为正式运行`[15,175)`。效应以A0-pre/A0-post均值`3654.16 MiB/s`为描述性锚点。

| Cell | 容量/热集 | mean MiB/s | 相对A0均值 | CV | W4/W1 | 命中率 | cache gauge | drops / evicts | Ceph RX/逻辑读 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| A0-pre | 0% | 3490.80 | -4.47% | 3.37% | 0.990 | 0% | 0 | 0 / 0 | 101.8% |
| C02 | 12.5% | 3659.58 | +0.15% | 3.31% | 0.999 | 5.60% | 1.96 GiB | 1,991,791 / 669,832 | 96.1% |
| C04 | 25% | 4067.58 | +11.31% | 3.31% | 1.001 | 15.49% | 3.86 GiB | 1,976,447 / 660,933 | 86.1% |
| C08 | 50% | 4900.65 | +34.11% | 9.70% | 0.887 | 40.98% | 7.66 GiB | 1,561,506 / 661,740 | 60.1% |
| C16 | 100% | 35384.36 | +868.33% | 2.73% | 1.001 | 95.83% | 15.65 GiB | 849,131 / 238,798 | 4.25% |
| C32 | 200% | 35317.74 | +866.51% | 1.40% | 0.994 | ~100% | 16.50 GiB | 0 / 0 | ~0% |
| A0-post | 0% | 3817.51 | +4.47% | 3.06% | 1.016 | 0% | 0 | 0 / 0 | 101.8% |

A0-post相对A0-pre为`+9.36%`，所以C02与C04的精确小效应不应被放大。C08的CV和W4/W1均
未达预注册稳定门。C16和C32带宽几乎相同，且C32无drop/evict、命中率约100%，清楚显示容量
超过工作集后进入平台；C16仍有缓存写入drops，但正式窗已达到95.83%命中，因此带宽也进入平台。

## 四、机制解释与边界

1. **为什么04-tmp2b几乎没有提升**：`mkfs.ext4 -T largefile`分别只给20/40/80 GiB文件系统
   创建20,480/40,960/81,920个inode；JuiceFS再按20%空闲比例限制条目，256 KiB缓存块最终
   只能占约`4/8/16 GiB`。相对于当时128 GiB工作集，实际比例仅`3.125%/6.25%/12.5%`。
2. **为什么C02--C08低于名义比例**：高并发随机读产生大量缓存写入drops和evicts，实际命中率
   只有`5.6%/15.5%/41.0%`，因此多数读取仍走Ceph；容量比例不等于命中比例。
3. **为什么C16/C32可达约34.5 GiB/s**：数据近全命中客户端本地缓存，Ceph RX接近消失；此前
   04-tmp2的证据已表明热数据主要由Linux页缓存承载。因此该数字是客户端RAM辅助的热集上限，
   不是NVMe裸盘持续带宽，也不受100GbE后端网卡上限约束。
4. **drops不是原始数据损坏**：它反映缓存准入队列在当前并发下无法接收所有候选块，是重要的
   产品行为；把“任意drops”预注册为证据失效门过严。但该合同不能事后悄悄改写，所以本RUN仍按
   形式失效记录，同时保留明确的工程机制结论。

## 五、生产意义与下一步

- 可以确认的候选原则是：**读热点稳定、有效缓存容量至少覆盖热集并留有余量时，本地读缓存有
  材料收益**；本RUN中32 GiB预算覆盖16 GiB热集后，达到稳定平台。
- 不能把`32 GiB`直接写成生产推荐值。生产热集规模、内存压力、cache admission速度和多客户端
  并不等同于本RUN；若上线，应按“目标热集+余量”在单客户端做独立canary，并同时观察命中率、
  drops、Ceph RX和主机内存回收。
- 04-tmp2b暴露的writeback staging `ENOENT`和排空失败没有被本轮修复；**不得据此开启writeback**。
- 无缓存七项交付基线不变。本项只为存在额外客户端本地盘且热点明确的生产场景提供备选方向。

## 六、证据与环境闭环

- 持久证据：`/mnt/c/SunRise/test/04-tmp2c/20260903-141500/`；
- phase-II manifest：`1786/1786 OK`，覆盖除manifest自身外全部文件；
- 执行冻结runner SHA256：`cd7cf2fd41fe34227954664078a837fc1fd32ece9927b150115ab4419beecc8a`；
- 执行冻结analyzer SHA256：`20f4297ae0612eacca4b4d567db25039e3e0f4d040d5ed69ab69e5bac4f5f53d`；
- 审核analyzer SHA256：`f19edd0d7b015545e2f1b8f8cfdd9c57fd5484fa2f999b13cb0fe9a55a531e12`。

审核版分析器只修复A0无warmup文件的兼容性、按实际采样跨度验收以及离线fixture的纳秒时间戳，
未修改原始数据；其输出仍保留预注册drops硬门导致的`CACHE_RESIDENCY_CURVE_INVALID`。
GPT与Luna又分别从原始per-job日志、metrics和runtime sampler独立复算，带宽、CV、命中率、
缓存占用、drops/evicts、基线漂移及机制方向一致。

最终已确认RUN缓存根为空、无测试挂载或进程后，执行唯一授权的精确
`sudo rmdir /mnt/jfs-cache/jfs-04tmp2c-20260903-141500`。复核结果：目录不存在、
`/mnt/juicefs`参考挂载正常、Ceph `HEALTH_OK`、97 PG；未影响157业务。持久证据签收后，
157上的RUN结果和工具临时副本共约20 MiB也已按精确路径非sudo清除。
先前因mount PID识别门失败的废弃RUN `20260903-140900`已保留最小事故证据并分别通过
`22/22`、`167/167` manifest复核，其157临时副本也已精确清除，不参与任何效应计算。
