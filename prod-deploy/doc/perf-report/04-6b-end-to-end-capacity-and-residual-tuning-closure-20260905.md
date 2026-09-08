# 04-6b端到端容量账与残余调优方向收口报告

> 日期：2026-09-05  
> RUN_ID：`20260905-070441`  
> 二进制：patched JuiceFS 1.4.1，MD5 `24fae0852051c80ca571cb2f20275d46`  
> 最终裁决：`STAGE04_CLOSE_OPEN_STAGE05`  
> 生产配置：本报告不直接修改；`--max-fuse-io 1M`仅进入正式验证候选。

## 一、结论

04-6b已得到一个有效的L1材料信号，因此按任务书的“首次发现候选即停止”合同结束，不再执行
U300和randrw状态回环：

- `--max-readahead 8M`对seqread/mseqread的配对效应分别为`+3.88%/+4.28%`，均未形成两组
  一致`>=5%`信号，关闭R8方向；
- `--max-fuse-io 256K→1M`对seqwrite两组配对分别提升`+7.13%/+14.81%`，几何配对效应
  `+10.90%`；FUSE平均写请求由`256 KiB`变为`1024 KiB`，两组PUT和OSD op_w完成率分别同步
  提高约`7.18%/14.25%`，OSD平均写延迟仅增加约`1.20%/2.05%`，机制门通过；
- 同一参数对mseqwrite的两组配对为`+6.28%/-1.41%`，方向不一致，配对效应仅`+2.36%`，不构成
  mseqwrite候选；
- 因seqwrite已经出现材料候选，04阶段不再签“无可用参数”。应新开05做正式非劣验证，至少覆盖
  seqwrite、mseqwrite、randwrite和randrw后再决定是否改交付配置。

## 二、Phase A：R8筛选

所有8个端点均`fio rc=0/error=0`，正式窗为实际I/O起点后的`[15,175)`，每格160个1秒点：

| 端点 | 有效带宽 MiB/s | CV |
|---|---:|---:|
| R01-SR | 1439.05 | 2.83% |
| R02-SR | 1475.49 | 3.13% |
| R03-SR | 1498.06 | 4.57% |
| R04-SR | 1423.29 | 2.33% |
| R01-MSR | 4723.41 | 1.86% |
| R02-MSR | 4935.18 | 4.46% |
| R03-MSR | 4889.61 | 3.88% |
| R04-MSR | 4698.01 | 2.31% |

| 工作负载 | 配对1 | 配对2 | 几何配对效应 | 裁决 |
|---|---:|---:|---:|---|
| seqread | +2.53% | +5.25% | +3.88% | `SCREEN_STOP_NO_CONSISTENT_UPGRADE_SIGNAL` |
| mseqread | +4.48% | +4.08% | +4.28% | `SCREEN_STOP_NO_CONSISTENT_UPGRADE_SIGNAL` |

这只说明显式R8没有达到本任务5%升级门，不外推为所有readahead取值均无效。

## 三、Phase B：F1筛选

Attempt-5的8个正式端点全部`fio rc=0/error=0`：

| 端点 | 参数臂 | 工作负载 | 有效带宽 MiB/s | CV |
|---|---|---|---:|---:|
| W01-SW | A / 256K | seqwrite | 1624.76 | 5.10% |
| W02-SW | F1 / 1M | seqwrite | 1740.58 | 2.40% |
| W03-SW | F1 / 1M | seqwrite | 1758.93 | 3.02% |
| W04-SW | A / 256K | seqwrite | 1532.04 | 4.25% |
| W01-MSW | A / 256K | mseqwrite | 3878.98 | 26.12% |
| W02-MSW | F1 / 1M | mseqwrite | 4122.72 | 3.63% |
| W03-MSW | F1 / 1M | mseqwrite | 4020.91 | 4.20% |
| W04-MSW | A / 256K | mseqwrite | 4078.57 | 3.29% |

### 3.1 seqwrite机制门

| 配对 | 带宽 | PUT完成率 | OSD op_w完成率 | FUSE平均写请求 | OSD平均写延迟 |
|---|---:|---:|---:|---:|---:|
| W02-SW / W01-SW | +7.13% | 1.0718× | 1.0718× | 4.00× | 1.0120× |
| W03-SW / W04-SW | +14.81% | 1.1425× | 1.1425× | 4.00× | 1.0205× |

两个配对同时满足预注册的方向性要求：带宽、PUT和OSD完成率均至少提高5%，FUSE请求合并达到4倍，
OSD平均延迟恶化低于10%。因此将执行期分析器的`CANDIDATE_PENDING_MECHANISM`离线闭合为
`SCREEN_CONTINUE_OPEN_05`。其含义是“候选值得正式验证”，不是已经确认生产收益。

### 3.2 mseqwrite

W02/W01为`+6.28%`，W03/W04为`-1.41%`；一正一负，不满足一致性门。W01-MSW的CV达26.12%，
该低点按冻结规则保留而未删样；即使不考虑该点，当前矩阵也不能签mseqwrite正收益。

## 四、执行事件与有效边界

- Attempt-1：OSD perf解析函数漏调用递归入口，未进入seed/fio/compact；
- Attempt-2：mseqwrite seed成功并完成每OSD一次SEED compact，但既有seqwrite文件实际不存在，
  在首个正式cell前终止；
- Attempt-3：恢复分支检查路径与挂载函数路径不一致，未新增seed/fio/compact；遗留任务挂载已优雅卸载；
- Attempt-4：被上述遗留挂载门拦截，未新增seed/fio/compact；
- Attempt-5：复用Attempt-2经manifest核验的mseqwrite seed，只补建任务专属seqwrite，完成有效矩阵。

前四次不得进入效应量。跨尝试累计compact仍为每OSD恰好4次：Attempt-2的SEED一次，加上
Attempt-5的W01/W02/W03各一次，没有突破授权上限。

## 五、环境与生命周期收口

- 8/8正式cell通过；Phase B、任务文件精确清理标记均存在；
- 1×32 GiB seqwrite和16×4 GiB mseqwrite共17个任务文件按manifest删除；对象状态由seed后的
  `2371825`回到前置`1978609`，`bytes_used`由`932951556096`回到`778332733440`（前置为
  `778390536192`，差约55 MiB）；
- 无RUN挂载、进程或挂载目录残留；
- scrub flags恢复；Ceph为`HEALTH_OK`、6/6 OSD up/in、97/97 PG `active+clean`；
- 业务挂载仍为`JuiceFS:juicefs-prod /mnt/juicefs`，volume UUID仍为
  `e1b69ea9-0e3d-427d-bea9-8765928afa66`；
- 既有只读资产抽样hash、业务进程及保护资产路径/inode/size前后一致。

## 六、证据索引

长期证据根：`/mnt/c/SunRise/test/04-6b/20260905-070441/`

- Phase A原始证据：`remote-final/`；独立复核：`prep/phase-a-independent-final-audit.md`；
- Phase B正式原始证据：`remote-phase-b/phase-b-attempt5/`；
- 全量文件及SHA：`remote-phase-b/file-index.txt`、`remote-phase-b/sha256sum.txt`；
- 写机制离线补算：`derived/phase-b-mechanism-repair/`；
- 失败尝试边界：`derived/phase-b-attempts-incident-summary.md`。

原始fio JSON、per-job带宽日志和环境快照未修改；机制闭合只读取冻结的pre/post累计量并生成独立派生件。

## 七、下一步

1. 04-6b到此停止，取消U300和randrw状态回环，避免在已经找到材料候选后继续消耗环境时间；
2. 新建05正式任务，验证`max-fuse-io=1M`在seqwrite上的可重复效应，并对mseqwrite、randwrite、
   randrw执行非劣门；
3. `04-tmp3f`若继续，只回答竞品16/20 MiB口径和大块路径问题，不得替代05的256 KiB/七项回归，
   也不得提前把F1写入生产基线。
