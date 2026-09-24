# 192.168.11～14 长稳项0：只读环境与容量盘点

时间：2026-09-23 15:09～15:13（北京）。目标为客户端 `192.168.11.12`（`tikv-node`），存储节点 `.11/.13/.14`（`ceph-node1/2/3`）。本项仅查询当前状态及本地历史归档；未执行 fio、重挂、清理、集群配置修改或 sudo 写操作。Ceph 采样通过现有白名单脚本执行只读 `sudo -n ceph` 查询。

## 当前配置与健康

| 维度 | 当前只读证据 |
|---|---|
| 客户端 | `/mnt/juicefs` 为 `JuiceFS:juicefs-prod`，FUSE `max_read=131072`；挂载命令为 `--max-uploads 150 --cache-size 0`。运行二进制 `/tmp/juicefs-1.4.1-patched`，MD5 `24fae0852051c80ca571cb2f20275d46`，工作进程观测到3个 `msgr-worker`。 |
| 卷 | `juicefs status`：UUID `3e54dcc4-991e-425a-8e76-16c9c1fb6836`，BlockSize 256 KiB，存储为Ceph池 `juicefs-data`；与192环境契约及既有归档一致。当前会话数1。 |
| 客户端资源 | 内存可用约248 GiB；`/data` 为 `/dev/sdb` XFS，空闲约946 GiB；`/data/reliability-lt-results` 为 `turboai` 独占可写目录。无 fio 进程；JuiceFS staging blocks/bytes、writing blocks和正在上传请求均为0。fio 3.28、Python3、iostat可用。 |
| Ceph | FSID `073f28e0-5fe0-11f1-8ce6-7369ee2be5a1`，`HEALTH_OK`；MON 3/3 quorum，OSD `0,2,3,4,5,6` 六个 up/in，`osd.1` out/down，161 PG active+clean。`juicefs-data` 为EC池，PG 32、size 6、min_size 4，scrub禁止标志未设置。 |
| TiKV/节点 | PD视图中 `.11/.13/.14` 三个store均Up；三节点TiKV进程运行中，内存可用约204～211 GiB，TiKV文件系统各空闲约308～310 GiB，采样时节点IO PSI的10/60/300秒平均值均0。节点时区不一致：`.14`显示UTC，其余显示北京时区；时间对应同一时点。 |
| OSD DB | 六个OSD的BlueFS DB空闲约296～297 GiB/盘，slow used均0，采样时RocksDB compact_running/queue均0。当前最先触及的容量约束是Ceph池可用量。 |
| 测试入口 | 192客户端到三个存储节点的非交互SSH均可用；现有只读Ceph白名单脚本可执行，SHA256 `c920f8eedc63a7416607268ca0a4a5e53e9ee0ca7f2c9baaffc7c36df9a1c3bf`，与本地同版。 |

## 容量准入：当前阻断写入长测

当前 `juicefs-data`：对象数 **2,593,039**，`stored=668,512,099,756 B`（约622.6 GiB），`max_avail=537,908,183,040 B`（约**501.0 GiB**）。192环境契约冻结的最低池余量为0.4 TiB，即409.6 GiB，因此只剩 **91.4 GiB** 的停止线余量。客户端的`/data`空闲946 GiB不能替代Ceph池余量。

既有192环境LT-002正式2小时RUN `20260921-175359`的原始 `samples/ceph.tsv` 显示：`max_avail` 从948,515,897,344 B降至833,554,219,008 B，下降 **107.1 GiB**；同轮pool stored增长107.1 GiB，对象增长435,386个。旧文字报告把这两个`max_avail`值写成约951/888 GiB，和原始字节数不符；原始值换算为883.4/776.3 GiB。不能假定下次增长斜率相同，但当前91.4 GiB余量**小于上次2小时实际下降量**，所以当前条件不足以放行同负载2小时复测，更不足以放行24/72小时长测。

卷内 `reliability-lt-data` 下还能看到五个旧RUN目录（`20260921-173701`、`174543`、`175201`、`175359`、`20260922-144100`）。本项只列清单，未判断可删性，未读取或清理文件内容。需先对这些资产及Ceph池容量做精确归属和回收计划，再重测容量门；不得直接删除或将阈值调低来放行。

## 旧RUN证据的适用范围与偏差

本地归档 `/mnt/c/SunRise/test/reliability/20260921-175359/LT-002/` 包含冻结配置、两小时窗fio、131次监控、最终CRC校验及metadata检查点。数据正确性PASS、fio错误0，但只观测到1个增长—回收周期，容量判定为`INCONCLUSIVE_LONG_BOUND`。报告声称性能FAIL可能由分析器隐藏判据造成；冻结配置实际写明`LT_MAX_P99_US=10,000,000`，因此FAIL有可追溯原因。**2026-09-24订正：**fio所报P99约17,112,760微秒已触及直方图上限，不能当作真实P99；两窗平均延迟远大于该值，仍可确认超过10秒门槛，见 `ITEM-2A-192-CONFIG-LATENCY-ATTRIBUTION-20260924.md`。是否构成产品问题，取决于192环境的业务SLO，不能从2小时结果自行推断。

本地最新版公共引擎SHA256 `2c59d0f548da855483b2f5914da34f96ba34ea92a06ca7b3103259a1f4ac6cac`，192客户端现有引擎SHA256 `69149b0980a53de61358aabfb33481945c1d503243cc598f4cbed1d1bbc303f2`，存在版本差异。现有 `collect-long-term.sh` 还硬编码157结果路径；正式新RUN前须修正192归档目标并复核脚本。旧RUN本身不受此差异影响。

## 本项结论和暂停点

**项0盘点完成；当前写入测试准入BLOCKED。** 集群配置身份及健康满足只读检查，但池余量无法覆盖历史同负载两小时的已观察下降量。下一项先完成旧RUN资产归属/容量回收方案、192脚本和归档路径适配、离线门以及重算容量预算；通过容量门之后再执行新写入负载。157/150～152不属于本轮目标环境。
