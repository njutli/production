# 04-8 `--max-fuse-io=1M`正式验证报告

> 日期：2026-09-09
> RUN_ID：`20260909-115749`
> 唯一变量：`--max-fuse-io 256K → 1M`
> 持久证据：`/mnt/c/SunRise/test/04-8/20260909-115749/`

```text
RUN_VALIDITY_STATE=VALID
PHASE_A_VERDICT=SEQWRITE_GAIN_CONFIRMED
PHASE_B_VERDICT=STOP_REGRESSION
GLOBAL_PRODUCTION_BASELINE_CANDIDATE=NO
SEQWRITE_ONLY_CANARY_CANDIDATE=YES
PRODUCTION_CHANGE=NONE
ENVIRONMENT=CLOSED
```

## 一、结论

`1M`对4 MiB单流同步seqwrite的收益得到正式复现：四组预注册配对均为正，几何效应
`+14.31%`，配对log双侧95% CI为`[+13.00%, +15.63%]`。FUSE平均写请求由约
`256 KiB`扩大到`1 MiB`，PUT/OSD完成率约提高`14.5%`，与带宽同向，因此该收益有明确机制支撑。

但`1M`不能作为七项统一生产基线：Phase B中mseqread两配对为`-6.35%/-2.15%`，按合同为
`INCONCLUSIVE`；randwrite为`-21.82%/-2.36%`，触发“任一配对低于-10%”的
`REGRESSION`门。其余项目均非劣。故生产默认配置继续保持`256K`，不得用seqwrite正收益覆盖
随机写兼容性失败。

如果存在只运行4 MiB单流顺序写、且与随机写挂载隔离的专用客户端，可把`1M`作为**按挂载灰度**
候选；灰度必须监控OSD写延迟和randwrite类业务，不等于修改通用交付基线。本任务到答案即停，
不追加轮次美化结果。

## 二、Phase A：seqwrite正式收益

| Cell | 臂 | 有效带宽 MiB/s | 正式窗CV |
|---|---|---:|---:|
| S01 | 256K | 1896.26 | 4.27% |
| S02 | 1M | 2167.76 | 3.52% |
| S03 | 1M | 2167.10 | 4.07% |
| S04 | 256K | 1893.94 | 2.83% |
| S05 | 1M | 2177.67 | 3.94% |
| S06 | 256K | 1923.02 | 4.02% |
| S07 | 256K | 1898.52 | 3.61% |
| S08 | 1M | 2188.15 | 3.63% |

四组固定配对效应为`+14.32%/+14.42%/+13.24%/+15.26%`；同臂噪声上界
`epsilon=1.27%`，材料门`M=max(5%,2epsilon)=5%`。8/8 detector、8/8 seqwrite、
9/9恢复门均通过。

机制侧，1M臂的PUT/OSD完成率约提高`14.5%`，四组汇总OSD平均写延迟约增加`8.0%`，低于
合同的10%材料门。单个配对曾出现约`11.02%/13.49%`的延迟上升，报告保留为灰度观察项，
但不替代预注册的全臂汇总判据。

## 三、Phase B：六项兼容性

固定顺序为`C01=A → C02=B → C03=B → C04=A`；每个挂载依次执行
`mseqread、seqread、randread、mseqwrite、randwrite、randrw`，正式窗均为`[15,175)`。

| 项目/方向 | C01 A | C02 B | C03 B | C04 A | B/A固定配对 | 裁决 |
|---|---:|---:|---:|---:|---:|---|
| seqread | 1427.82 | 1420.61 | 1422.93 | 1430.36 | `-0.50%/-0.52%` | `NON_INFERIOR` |
| mseqread | 4635.46 | 4341.25 | 4540.46 | 4640.22 | `-6.35%/-2.15%` | `INCONCLUSIVE` |
| randread | 4493.18 | 4416.53 | 4473.75 | 4521.35 | `-1.71%/-1.05%` | `NON_INFERIOR` |
| mseqwrite | 3973.97 | 4016.31 | 4016.01 | 3998.45 | `+1.07%/+0.44%` | `NON_INFERIOR` |
| randwrite | 3251.14 | 2541.60 | 2466.64 | 2526.32 | `-21.82%/-2.36%` | **`REGRESSION`** |
| randrw-read | 1700.95 | 1699.03 | 1696.23 | 1612.48 | `-0.11%/+5.19%` | `NON_INFERIOR` |
| randrw-write | 1706.23 | 1703.67 | 1699.85 | 1616.52 | `-0.15%/+5.16%` | `NON_INFERIOR` |

单位均为MiB/s。randwrite正式窗CV为`16.71%/37.31%/38.85%/36.26%`，且首个A臂明显高于
其余三格，所以`-21.82%`不应被外推成稳定的精确因果幅度；但合同在取数前已规定任一配对低于
`-10%`即判回归，不能事后改配对或补样。即使忽略该点，mseqread仍未通过两组均`>=-5%`的
非劣门，因此全局候选结论不变。

## 四、证据与生命周期

- Phase A证据：`/mnt/c/SunRise/test/04-8/20260909-115749/phase-a/`；
- Phase B原始包：`phase-b/phase-b-evidence.tar.gz`，`16572285`字节，SHA256
  `f43db3855fd70173dfe6cc8daba3a39235fc87e1fd8aaff4d80bd3b6abc23624`；
- 清理闭包包：`phase-b/phase-b-closure.tar.gz`，`1044742`字节，SHA256
  `3c8aae907f2b588dcf1235792add89dd07bf2a860685f90b978f616a56bb4d5c`；
- GPT从持久化原始日志独立重跑分析器，输出与远端`phase-b.json`逐字一致；Luna独立复核配对及
  `-5%/-10%`机械判据一致；
- 24/24 Phase B端点和12/12写后恢复通过，scrub/deep-scrub恢复为原值；
- 本RUN精确删除1个32 GiB seqwrite文件和16个4 GiB mseqwrite文件；GC后对象数连续三次为
  `1978610`，相对起点`1978609`仅`+1`；TiKV pending为0；
- 最终Ceph `HEALTH_OK`、6/6 OSD up/in、97/97 PG active+clean，无任务挂载、进程或私有路径残留。

因此04-8已完整闭环：确认了seqwrite专用收益，同时否决`1M`作为通用七项生产基线。
