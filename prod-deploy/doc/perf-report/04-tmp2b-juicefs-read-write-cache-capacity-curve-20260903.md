# 04-tmp2b JuiceFS 读写缓存共享容量曲线报告

> 后续订正：04-tmp2c确认本RUN的20/40/80 GiB ext4因`-T largefile` inode密度过低，
> 名义16/32/64 GiB缓存实际只能容纳约4/8/16 GiB。故本报告“读容量曲线无收益”的现象不能
> 外推为JuiceFS读缓存无效；writeback staging硬失败结论不受此订正影响。详见
> `04-tmp2c-randread-cache-residency-curve-20260903.md`。

## 一、结论

```text
RUN_ID=20260903-000000
EVIDENCE_LEVEL=L1_SCREEN
VERDICT=CACHE_CAPACITY_CURVE_INVALID
WRITE_VERDICT=WRITEBACK_STAGING_DRAIN_FAILURE
ENGINEERING_DECISION=NO_DELIVERABLE_COMBINED_CACHE_TIER
ENVIRONMENT_CLOSURE=PASS
```

本轮完成了 `mseqread/randread × C16/C32/C64` 六个有效读点。`mseqread`随容量从
`3103.56`增至`3437.02 MiB/s`，但 `randread`呈明显非单调结果
`3892.38 / 2645.14 / 3814.71 MiB/s`；每档仅一个挂载实例，且实际缓存占用未达到名义预算，
因此只能作为工程观察，不能签容量因果曲线。

首个写点 `randwrite-c16` 的 fio 成功，但写后 staging 长时间固定为`112`个文件、
`29,363,712 B`，同时日志持续出现 staging 路径 `ENOENT`。这不是正常排空较慢，而是观察到了
writeback 队列/文件生命周期不一致。按任务书硬门停止其余五个写点，无法计算有效持久化带宽，
也不能给出 writeback 生产候选档。

## 二、冻结条件与执行范围

- JuiceFS：exact patched `1.4.1`，MD5 `24fae0852051c80ca571cb2f20275d46`；
- 后端：现有 `juicefs-prod` TiKV/Ceph，不改卷、pool、PG、CRUSH或生产挂载；
- 缓存介质：157本地NVMe上的RUN专属 backing file + loop/ext4；
- C16/C32/C64：20/40/80 GiB文件系统，`--cache-size=16/32/64 GiB`，共同启用
  `--writeback --free-space-ratio 0.20 --max-uploads 150`；
- 读项预热180秒、正式180秒；写项正式180秒并要求 staging 15分钟内连续两次为0；
- 固定顺序：每项 `C16→C64→C32`。本轮完成六个读点和一个无效写点后按硬门终止。

## 三、读点结果

主窗为正式运行 `[15,175)`；六点的尾段带宽与缓存占用稳态门均通过。

| 测试项 | 档位 | mean MiB/s | median MiB/s | CV | W4/W1 | 缓存FS峰值占用 | 相对历史锚* |
|---|---:|---:|---:|---:|---:|---:|---:|
| mseqread | C16 | 3103.56 | 3095.25 | 6.52% | 1.0081 | 4.06 GiB | -42.2% |
| mseqread | C32 | 3293.15 | 3274.63 | 3.81% | 1.0020 | 8.13 GiB | -38.6% |
| mseqread | C64 | 3437.02 | 3404.38 | 4.65% | 1.0001 | 16.25 GiB | -35.9% |
| randread | C16 | 3892.38 | 3928.88 | 3.72% | 0.9984 | 4.06 GiB | -29.8% |
| randread | C32 | 2645.14 | 2610.12 | 6.14% | 0.9870 | 8.13 GiB | -52.3% |
| randread | C64 | 3814.71 | 3839.75 | 4.40% | 0.9953 | 16.25 GiB | -31.2% |

\* 历史锚为 mseqread `5366`、randread `5544 MiB/s`，与本RUN不同窗且本RUN使用nested-loop，
只作量级参考，不能签严格效应。

读侧可以确认三点：

1. 六点轮内均已稳定，结果差异不是简单的预热未完成；
2. `mseqread C64/C16=+10.74%`，但 `randread C32`比C16低`32.04%`，容量与性能没有一致的
   单调关系；单点设计不足以把差异归因于容量；
3. C16/C32/C64采集到的缓存文件系统物理峰值只约`4.06/8.13/16.25 GiB`；本轮没有保存
   logical cache-byte/hit计数，不能仅按名义`--cache-size`断言实际缓存了工作集的既定比例。

此外，采样器用 `ip route get 10.20.1.150`选择了TiKV网卡`eno12399`，而Ceph OSD前端地址为
`10.3.1.6--8`。本轮记录的RX/TX不是Ceph数据路径，不能用于证明后端卸载比例。这不否定fio点值，
但进一步禁止把读侧差异解释为NVMe缓存命中收益。

## 四、写点硬失败

`randwrite-c16` 的 fio原文满足`rc=0 / job error=0`：

| 指标 | 值 | 解释 |
|---|---:|---|
| fio聚合前台WRITE | 1,354,380,231 B/s（约1291.64 MiB/s） | 仅前台工程观察 |
| fio写入字节 | 266,361,896,960 B | 已由fio确认完成 |
| 排空尾值 | 112 blocks / 112 files / 29,363,712 B | 连续数分钟不下降 |
| JuiceFS日志 | 大量`uploadStagingFile ... no such file or directory` | staging队列/文件生命周期异常 |
| 有效持久化带宽 | 不计算 | 未通过原始连续两次为0的硬门 |

该点标记为：

```text
CACHE_CAPACITY_CURVE_INVALID
WRITEBACK_STAGING_DRAIN_FAILURE
FRONTEND_ONLY_OBSERVATION
```

优雅卸载后 rawstaging 仍存在；随后使用相同cache-dir做一次无fio的恢复挂载，
`scanStaging()`立即把`112 / 29,363,712 B`清到`0 / 0 B`。这证明本次数据可恢复并已安全回传，
但不能倒推原正式点通过持久化门，也不能证明具体源码根因。其余C32/C64 randwrite及三档randrw
均未启动，避免重复暴露同一风险和制造无效数据。

## 五、后处理修复与证据边界

原分析器误用fio `group_reporting`下按worker累计的`job_runtime`作为墙钟时间；修复后改用
`read.runtime/write.runtime`。该修复只影响离线解析，不改变任何已执行命令或原始证据，离线
self-test通过。执行时冻结的分析器SHA256为`70907309c489f9a85c4e11cf45f3aaedda7a6c5d1405f428bd3602971e2e68ea`，
修复版分析器SHA256为
`c80920249df3bfac212673dc8b947e03dcd83a2ea8096dc1bdca7ee155dab554`。

综合边界：

- 六个读点可引用为当前嵌套缓存形态的一次L1稳态观察；
- 不得把读点写成容量单调收益、Ceph卸载比例或生产NVMe收益；
- `randwrite-c16`只能引用前台观察值，不得与无缓存基线计算writeback持久化收益；
- 本RUN不能输出完整12点曲线，不能推荐16/32/64 GiB中的任何生产档位；
- 不建议修脚本后重跑：写侧已触发产品行为硬失败，读侧也没有形成稳定、可归因的容量收益。

## 六、环境与证据生命周期

- phase-a/phase-b scrub租约均恢复，最终Ceph为`HEALTH_OK`、6/6 OSD up/in、97 PG
  `active+clean`；
- `/mnt/juicefs`生产参考挂载保持正常；三个TiKV metrics端点可达；
- 测试JuiceFS挂载、cache ext4、`/dev/loop20`、backing file及RUN专属目录均已精确清除；
- 仅向排空等待runner发送TERM以触发停止合同；未kill JuiceFS/生产进程，无强制/lazy umount、
  无裸NVMe mkfs、无递归删除；
- 最终证据共1341个文件，manifest复核通过；
- 持久证据：`/mnt/c/SunRise/test/04-tmp2b/20260903-000000/`；
- 最终归档：`opencode-04tmp2b-20260903-000000-evidence-final.tar.gz`，SHA256
  `b39b2853acdb47a1847a3d12baaff69c562ac7183faf3704ce1d26421672baf6`。

04-tmp2b至此关闭，不修改无缓存交付配置。后续04-tmp2c已用inode充足的原生ext4和正确Ceph
数据网卡补做只读randread驻留曲线；writeback若未来重新评估，仍须先解决staging一致性。
