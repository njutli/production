# T09 DirStats规模测试阶段B（1万文件）签收

> 时间：2026-09-11 10:34～10:35 CST  
> 裁决：`T09_DIRSTATS_PHASE_B_PASS`  
> 原始数据：`/mnt/c/SunRise/test/t09-dirstats/20260911/phase-b-10k/`

## 现场

- 临时卷：`jfsportal-dirstats-20260911`；UUID=`80a2a0da-d98a-4b47-a97a-2da488c4d1ba`；
- 临时META后缀：`jfsportal-dirstats-20260911`，与业务卷`juicefs-prod`隔离；
- 客户端：157；临时挂载和file对象后端均在`/dev/shm`，`cache-size=0`、`backup-meta=0`、`no-bgjob`；
- 目录：10×10×10三级树，共1111个目录（含DIRTEST根）；
- 文件：10000个零字节文件；生成器完成11111次mkdir/create操作，用时22.222秒，实际499.997 ops/s。

## 结果

| 方法 | 首次/s | 后3次中位数/s | 相对fast |
|---|---:|---:|---:|
| `info -r` fast | 0.05 | 0.05 | 1.0× |
| `info -r --strict` | 0.09 | 0.09 | 1.8× |
| `summary --depth 3` fast | 0.05 | 0.06 | 1.0× |
| `summary --depth 3 --strict` | 0.09 | 0.09 | 1.5× |
| `du -s` | 0.84 | 0.79 | 13～16× |
| `du --max-depth=3` | 0.80 | 0.80 | 13～16× |

- DirStats在首次30秒等待后的第一个收敛检查即通过；
- fast与strict四轮均为`files=10000`、`dirs=1111`、`size=45,510,656 bytes`；info输出SHA完全相同；
- summary fast/strict均输出1112行，按PATH排序后每轮完全相同；原始顺序差异来自并发遍历，不是统计差异；
- `du`总量为4,550,656 bytes，而JuiceFS统计为45,510,656 bytes：零字节文件在JuiceFS目录用量中按4 KiB最小粒度计入，`du`的块占用只体现目录块。因此T09应明确展示“JuiceFS逻辑计费占用”，不能把默认`du`值当成同一口径。

## 业务与容量闭环

- 前后均为14 targets、Ceph健康值0、6/6 OSD、64/64 PG clean；
- `juicefs-data`前后均为1,978,612 objects、518,631,030,784 bytes，证明零字节测试没有进入Ceph数据池；
- TiKV pending compaction前后均为0；近1分钟CPU由0.044核变为0.178核，绝对增量很小；
- 业务JuiceFS读写字节速率前后均为0，FUSE ops约6→5.88/s；三节点PD/TiKV PID和业务挂载逐字节一致；
- 157根分区没有净增长；`/dev/shm`总使用量约36 KiB→752 KiB，临时对象目录加日志仅4,763 bytes，远低于64 MiB异常门。

## 结论和下一步

1万文件已经证明fast比`du`快一个数量级且统计结果可复现，但fast相对strict只有1.5～1.8倍，规模仍不足以判断大目录扩展性。临时卷和挂载保持空闲，未执行删除、卸载或destroy。经用户确认后可在同一树追加到10万零字节文件；不得自动进入100万档。
