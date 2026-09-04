# 04-tmp 正式报告：randrw 当前栈 `max-readahead=0` 严格 A/B

日期：2026-09-01

```text
VERDICT=RW_RA_INCONCLUSIVE
ENGINEERING_DECISION=KEEP_DEFAULT_READAHEAD; MATERIAL_5PCT_BENEFIT_EXCLUDED
RUN_ID=20260831-231629
VALIDITY_STATE=VALID
LIFECYCLE_STATE=CLOSED
EVIDENCE_ROOT=/mnt/c/SunRise/test/04-tmp/20260831-231629-autonomous
MANIFEST_PATH=opencode-04-tmp-randrw-ra-20260831-231629.archive.tar.zst::manifest.sha256
PERSISTENCE_STATUS=PASS
REMOTE_STATUS=PURGED
LOCAL_STATUS=COMPACTED
INCIDENT_STATUS=NONE
ENVIRONMENT_ASSET_STATUS=CLOSED
BINARY_MD5=24fae0852051c80ca571cb2f20275d46
ARCHIVE_SHA256=5e5953e55b6c89570aea3e8e97c2b3558c251d29aaf3c3bc968537da9e115fc5
```

> 性能、环境、独立复算和证据生命周期均已闭合。本地等价副本已经压缩，157上的两个精确RUN源
> 结果树及valid远端重复归档已经按白名单删除；长期权威证据只保留在持久化目录。

## 一、结论

在exact patched JuiceFS v1.4.1、`--max-fuse-io 256K --max-uploads 150 --cache-size 0`、
私有`ms_async_op_threads=8`和同一既有128×1 GiB数据资产下，显式追加
`--max-readahead 0`使randrw读、写两向都获得约`+1.6%`的小幅正向变化，但达不到预注册的
`+5%`材料收益：

| 方向 | DEFAULT原始均值 MiB/s | RA0原始均值 MiB/s | 冻结模型效应 | 双侧95% CI | 单侧95%下界 | 工程判定 |
|---|---:|---:|---:|---:|---:|---|
| READ | 1657.53 | 1684.46 | `+1.6246%` | `[+0.0399%, +3.2094%]` | `+0.4078%` | 95% CI上界低于`+5%`，排除材料收益 |
| WRITE | 1658.09 | 1685.36 | `+1.6447%` | `[+0.0088%, +3.2806%]` | `+0.3886%` | 95% CI上界低于`+5%`，排除材料收益 |

因此：

1. **不把`--max-readahead 0`加入生产交付配置**，保持默认readahead；
2. **关闭当前最终栈上randrw的readahead参数方向，不补样、不重跑**；
3. 本结论只针对randrw，不能外推为当前栈的randread也没有收益；
4. 即使采用RA0，两向也只有约`1685 MiB/s`，各自只达到`6250 MiB/s`目标约`27%`，不改变
   randrw共享约`3.3 GiB/s`服务容量、距离双向目标很远的架构结论。

## 二、为什么正式标签仍是 `RW_RA_INCONCLUSIVE`

任务书在取数前冻结的状态机规定：

- 两向点估计均至少`+5%`且单侧下界大于0，才记确认收益；
- 两向未达材料收益且CI与0相容，才记`RW_RA0_NO_MATERIAL_BENEFIT`；
- 其余情况记`RW_RA_INCONCLUSIVE`。

本次两向CI都刚好位于0以上，但上界又都低于`+5%`，落入状态机没有单列的“统计显著但低于材料
阈值”区间，所以冻结analyzer正确输出`RW_RA_INCONCLUSIVE`。这不是证据不足：CI半宽只有
`1.58/1.64 pp`，远低于`5 pp`分辨率硬门，而且区间已经排除`+5%`材料收益。正式标签不得事后改写，
工程决策则明确为`KEEP_DEFAULT_READAHEAD`。

后续任务书应补齐这一状态机空档：当共同主端点CI上界均低于材料阈值时，可以直接签
`SUBTHRESHOLD_EFFECT / KEEP_DEFAULT`，无需再要求CI必须包含0。

## 三、正式八轮数据

正式顺序和randseed为冻结的`A,B,B,A,B,A,A,B`，四对相邻跨臂比较共享相同seed。

| 轮次 | 臂 | randseed | READ MiB/s | WRITE MiB/s | READ CV | WRITE CV | READ W4/W1 | WRITE W4/W1 |
|---|:---:|---:|---:|---:|---:|---:|---:|---:|
| R01 | A | 41001 | 1674.35 | 1671.38 | 7.73% | 7.94% | 0.958 | 0.951 |
| R02 | B | 41001 | 1687.11 | 1683.86 | 7.22% | 7.18% | 0.977 | 0.971 |
| R03 | B | 41002 | 1694.14 | 1694.65 | 8.75% | 8.69% | 0.894 | 0.894 |
| R04 | A | 41002 | 1674.14 | 1674.42 | 8.21% | 8.09% | 0.961 | 0.958 |
| R05 | B | 41003 | 1681.54 | 1683.55 | 9.64% | 9.68% | 0.934 | 0.939 |
| R06 | A | 41003 | 1655.28 | 1657.43 | 8.98% | 8.83% | 0.950 | 0.957 |
| R07 | A | 41004 | 1626.34 | 1629.14 | 7.26% | 7.13% | 0.964 | 0.964 |
| R08 | B | 41004 | 1675.04 | 1679.39 | 9.93% | 9.78% | 0.893 | 0.895 |

四对RA0相对DEFAULT效应均为正：

| 配对 | READ | WRITE |
|---|---:|---:|
| R01→R02 | `+0.762%` | `+0.746%` |
| R04←R03 | `+1.194%` | `+1.208%` |
| R06←R05 | `+1.586%` | `+1.576%` |
| R07→R08 | `+2.995%` | `+3.084%` |

方向一致说明ra0确有小幅残余作用，但最大配对仍只有约`3%`；逐轮CV和W4/W1也没有形成稳定、材料级
的波动改善，不能把它包装成稳定性配置。

## 四、与早期 ra0 现象为什么不同

早期01-2d在旧基座和128K FUSE口径下，randrw从约`1032/1038`提高到`1316/1319 MiB/s`，
约`+28%`；randread曾提高约`+62%`。当前同窗A/B不能直接继承这些幅度。

最有直接证据支持的变化是03-6已经把`max-fuse-io`从128K提高到256K：

- 256 KiB fio I/O不再拆为约两个128 KiB FUSE请求；
- randrw `GET/IO`从约`1.62`降到`1.15`；
- RX放大从约`2.30×`降到`1.22×`；
- 即使保持默认readahead，randrw两向当时已提高约`53.1%`。

`max-fuse-io=256K`已经消除了大量原先由拆包和默认预读共同放大的额外工作，因此关闭readahead只
剩下约`1.6%`增量。patched v1.4.1、`msgr=8`和当前数据/集群状态也与早期不同，可能存在交互，
但本任务没有做多因素拆分，不能把差异唯一归因于某一个版本或Messenger参数。生产决策只需要回答
当前最终栈是否应追加ra0，本次同窗证据已经足够。

## 五、证据有效性与独立复算

- W01--W04和R01--R08共`12/12 CELL_PASS`；正式八轮fio rc均为0；
- 每个正式轮均有128份逐job混合读写bw log、160秒正式窗和30个sampler heartbeat；
- 文件资产每轮均为128×1 GiB；每轮前后对象数回到动态seed附近，R01--R08闭包只比seed多
  `1/2/3/4/5/5/6/6`个对象，均远低于`±8192`门；
- A/B实际mount token的唯一差异是B追加`--max-readahead 0`；二进制MD5、CEPH_CONF SHA、
  metadata identity、数据资产和fio命令相同；
- scrub在单一lease内暂停，结束后`noscrub/nodeep-scrub`精确恢复；最终`HEALTH_OK`、6/6 OSD
  up/in，无本RUN挂载、worker或fio残留；`incidents.tsv`只有表头；
- 原始归档内层`manifest.sha256`由执行方核验`7839/7839 OK`；GPT用普通gzip转交包再次核验
  `7839/7839 OK`，并从原始per-job日志独立重跑冻结analyzer；
- GPT结果与执行方草稿在所有工程数值和verdict上一致，文件差异仅为不同Python环境造成的约
  `1e-13`浮点末位。

因此`VALIDITY_STATE=VALID`，不存在删样、补样或用性能低点冒充环境异常的问题。

## 六、持久化与生命周期处置

长期权威证据为：

| 项 | 路径/值 | 处置 |
|---|---|---|
| 原始不可变归档 | `/mnt/c/SunRise/test/04-tmp/20260831-231629-autonomous/opencode-04-tmp-randrw-ra-20260831-231629.archive.tar.zst` | 长期保留 |
| 原始归档SHA256 | `5e5953e55b6c89570aea3e8e97c2b3558c251d29aaf3c3bc968537da9e115fc5` | 长期保留侧车 |
| 冻结脚本/命令/manifest/raw | 包含于上述归档 | 长期保留，可独立复算 |
| 正式报告 | 本文；并复制到权威根 | 长期保留 |
| GPT复算摘要 | 权威根`gpt-independent-review-20260901.md` | 长期保留 |
| gzip审查转交包 | 与zstd归档内容等价 | 报告签收后删除 |
| executor草稿 | 可由raw和冻结analyzer再生 | 报告签收后删除 |
| GPT临时解压/复算目录 | `/tmp/s04tmp-gpt-review.*`、`/tmp/s04tmp-gpt-independent` | 复算签收后删除 |
| 157源结果树 | `/tmp/production/opencode-04-tmp-randrw-ra-20260831-231629/` | 持久化与审核后精确删除 |

本地去重已完成并写入权威根`purge-audit.tsv`：共删除`66,183,863`字节等价归档、展开副本和临时
复算目录；长期保留的正式zstd归档与旧失败RUN最小incident包随后重新核验，SHA256仍分别为
`5e5953e55b6c89570aea3e8e97c2b3558c251d29aaf3c3bc968537da9e115fc5`和
`81b0fbbd62caf6a12a79857197f6fdb4aeb5363e3fecd42b9e589a0858de265a`。

2026-09-01远端收口逐项核对真实路径、类型、owner、活动引用和valid归档SHA后，精确删除valid源目录、
valid重复归档及侧车、invalid源目录，共释放`122,529,655`字节。删除后四个白名单路径均不存在，
其他2099离线Gate目录未改变，无04-tmp进程或挂载引用；Ceph仍为`HEALTH_OK`、6/6 OSD up/in。
完整逐路径记录位于权威根`purge-audit.tsv`。

环境资产已经闭合，不需要也不允许借生命周期清理再次操作挂载、卷、Ceph对象、pool、scrub flag或服务。
至此`REMOTE_STATUS=PURGED`、`LOCAL_STATUS=COMPACTED`、`LIFECYCLE_STATE=CLOSED`。

## 七、后续

04-tmp结束后，下一主线任务是`04-1`的V2空pool可行性链：先做只读inventory和精确plan，再经
独立授权注册一个空B pool，在同一pool_id上实际执行`32→64→128`单调PG梯子。当前授权仅到
结构可行性；没有档位`SELECTED`就以负结论停止，不开发数据面、不layout、不跑fio。
