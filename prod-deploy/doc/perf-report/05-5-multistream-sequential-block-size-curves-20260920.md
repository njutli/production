# 05-5 多流顺序读写BS曲线报告

> **2026-09-20复核订正：`BASELINE_CONFIG_MISMATCH / WRITE_PARTIAL_INFRASTRUCTURE_BLOCKED / RETEST_PLANNED`。** 本RUN实际使用系统 `ceph.conf`（归档SHA `8dd48e57…`，同哈希文件只读解析为3），遗漏私有8线程基线。撤回下文“读方向无需补测”及据此闭合当前最优配置平台的判断；9个写格中仅前8格前后健康边界通过，第9格 `256K-B` 的post-health出现spillover，其3913.19 MiB/s只能列为受污染观察，不能与4117.23计算健康配对均值/漂移。原数值与事件保留，后续由[05-5b](../perf-tasks/05-5b-multistream-bs-baseline-and-capacity-retest.md)完整重测。DB修复方式须另据现场诊断，历史compact失败不能证明本次只能扩容/重建。本订正优先于下文原状态及结论。

> 原签收状态（受上述订正约束）：`MSEQREAD_COMPLETE / MSEQWRITE_PARTIAL_INFRASTRUCTURE_BLOCKED / NO_NEW_CONFIG`  
> 固定资产创建RUN：`20260920-003242`；有效矩阵RUN：`20260920-072228`。  
> 权威证据：`/mnt/c/SunRise/test/05-5/20260920-072228/`。

## 一、结论

1. `mseqread`五档BS曲线完整：64 KiB--16 MiB正式窗均值仅在`2821--2903 MiB/s`间变化，同BS位置漂移为`0.27%--1.99%`。增大BS没有材料性收益，16个同步流已进入与BS基本无关的平台。
2. `mseqwrite`完成9/11格后被Ceph健康门停止。已完成数据在`3854--4168 MiB/s`量级；具备双位置的256 KiB/1 MiB/4 MiB/16 MiB漂移为`0.47%--7.37%`，同样未显示随BS增大的趋势。但缺少`64K-B`和`4M-C`，写曲线只能记为部分证据，不能冒充完整任务结果。
3. 停止原因不是JuiceFS参数：`osd.4`的40 GiB BlueFS DB设备已满，约70 MiB元数据溢出到slow device，触发`BLUEFS_SPILLOVER`。继续执行会把BS效应与溢出后的介质路径变化混在一起，因此不放宽健康门，也不补跑挑值。
4. 本任务没有产生新的交付配置。结合04-6的并发证据（mseqread 8→16流仅约`+6.8%`，mseqwrite 16流反降约`5.5%`且六块OSD盘P50 util均100%），现有证据支持“多流顺序负载不能靠继续增大BS或并发获得材料性提升”。写侧完整闭合仍依赖先修复Ceph BlueFS DB容量。

## 二、固定口径与有效性

- 节点157；JuiceFS `1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`；既有`juicefs-prod`、BlockSize=256 KiB。
- 挂载固定`max-fuse-io=256K,max-uploads=150,max-downloads=200,buffer-size=300,cache-size=0`。
- fio固定`numjobs=16,psync,QD1,direct=1,size=4G,runtime=180s`；读写均使用16个独立4 GiB固定文件，正式矩阵禁止自动创建。
- 正式窗为`[15,175)`，由16份per-job带宽日志聚合；fio启用`group_reporting=1`，JSON中的一个聚合job通过`job options.numjobs=16`和16份日志共同验证。
- 每个phase使用状态驱动lease暂停`noscrub/nodeep-scrub`，结束或失败均按原flags恢复。读阶段10/10格完整；写阶段9/11格完整、2格缺失，故写方向状态为`PARTIAL_FORMAL_REVIEW`。

## 三、BS曲线

### 3.1 mseqread：完整

单位MiB/s；A/B或1/2表示同配置在序列中的不同位置。

| BS | 正式窗位置值 | 位置均值 | 正式窗漂移 |
|---:|---:|---:|---:|
| 64K | 2824.60 / 2816.90 | 2820.75 | 0.27% |
| 256K | 2891.27 / 2913.79 | 2902.53 | 0.78% |
| 1M | 2889.13 / 2912.43 | 2900.78 | 0.80% |
| 4M | 2843.59 / 2900.68 | 2872.13 | 1.99% |
| 16M | 2827.69 / 2837.88 | 2832.78 | 0.36% |

五档最大均值差仅约`2.9%`，且最大BS不是最高点；因此本RUN没有“大BS提高多流顺序读”的信号。该RUN绝对值低于04-6历史锚，只用于同RUN BS横向关系，不生成跨RUN精确效应。

### 3.2 mseqwrite：部分完成

| BS | 正式窗位置值 | 已有位置均值 | 状态/漂移 |
|---:|---:|---:|---:|
| 64K | 4102.65 | 4102.65 | 缺`64K-B`，不可算位置漂移 |
| 256K | 4117.23 / 3913.19 | 4015.21 | 5.08% |
| 1M | 4060.19 / 4167.66 | 4113.93 | 2.61% |
| 4M | 4149.07 / 3854.25 | 4001.66 | 7.37%；缺额外锚`4M-C` |
| 16M | 4125.77 / 4106.54 | 4116.16 | 0.47% |

写探针`4M-A→64K-A→4M-B`按fio摘要计算的4M锚漂移为`6.68%`，通过10%停止线；正式窗漂移为`7.37%`。其中`4M-B`的CV为`17.26%`、`W4/W1=1.379`，明显高于其余多数格，故表格只支持“已完成格没有BS增益信号”，不支持精确档位排序。

## 四、阻断与安全收口

- 在第9个写格`256K-B`完成后的健康门出现：`HEALTH_WARN / BLUEFS_SPILLOVER`；`osd.4`显示40 GiB DB设备已用满并向slow device溢出约70 MiB。OSD仍为6/6 up/in、PG为97个，但介质路径已经改变。
- 既有历史报告已记录同类现象：长时间写入导致40 GiB DB耗尽，普通compact不能清除；此前通过pool重建和OSD重启恢复，但DB尺寸未被长期解决。因此本任务不把“等待、compact或忽略告警”当作可比性修复。
- 写阶段按硬门停止，未运行`64K-B/4M-C`；无fio和本RUN私有挂载残留，scrub lease执行`restore + verify-restored`成功，flags中无`noscrub/nodeep-scrub`。
- 但Ceph当前仍为`HEALTH_WARN/BLUEFS_SPILLOVER`。在扩容/重建BlueFS DB并恢复`HEALTH_OK`前，不应继续05-5写补格或其他正式性能矩阵。

## 五、执行事件与证据边界

- 初始RUN先精确创建空目录中缺失的16×4 GiB `mseqwrite`资产并校验，未触碰读资产或其他目录。
- 第一次读启动在任何Ceph写操作前被shell局部变量展开错误阻断；退出门确认无状态变化。
- 第二次读启动的首格fio成功，但脚本误把`group_reporting=1`的单个聚合JSON job当成缺少16 jobs；该RUN完整恢复scrub和挂载，首格不纳入正式矩阵。修复后用原始JSON和16份日志离线验证可得到可测正式窗，再以新RUN完整重跑。
- 有效RUN的读10格和写9格共19格均`fio rc=0/error=0`、16份日志齐全。远端与持久目录共1002个证据文件逐项SHA256一致；持久清单`ALL-SHA256SUMS`的SHA256为`3a873c88cb918757fe6cd4959c1c639b1e1f0540c4f23248bc7bf69dd77b8929`。

## 六、后续

05-5读方向已经回答，不再补测。写方向仅在Ceph BlueFS DB容量问题被独立修复、集群恢复`HEALTH_OK`后，使用新的RUN重新执行完整写矩阵；不得只补最后两格与溢出前数据拼接。若不计划改变当前Ceph集群，则以`WRITE_PARTIAL_INFRASTRUCTURE_BLOCKED`关闭05-5，并在05-6只展示已有范围和阻断原因。
