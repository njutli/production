# T09 DirStats阶段B2正确性签收

> 时间：2026-09-11 11:56 CST  
> 裁决：`T09_DIRSTATS_PHASE_B2_PASS`  
> 原始证据：`/mnt/c/SunRise/test/t09-dirstats/20260911/phase-b2-correctness/`

## 范围

- 复用阶段B的独立临时卷`jfsportal-dirstats-20260911`，UUID固定为`80a2a0da-d98a-4b47-a97a-2da488c4d1ba`；
- 只修改临时卷固定路径`/CORRECTNESS`，不触碰业务卷和原有`/DIRTEST` 1万文件树；
- 用独立的`os.walk + lstat + 4 KiB对齐`清单作为预期值，而不是让fast和strict相互证明；
- 覆盖稀疏文件边界大小、grow、shrink、跨目录rename、hardlink、unlink；不含并发竞争和异常客户端崩溃。

## 正确性结果

| 步骤 | 操作 | 根目录files/dirs | length/bytes | JuiceFS size/bytes | fast首次观测 |
|---|---|---:|---:|---:|---|
| S0 | 创建0、1、4095、4096、4097、1 MiB文件 | 6 / 3 | 1,060,865 | 1,085,440 | 与清单及strict一致 |
| S1 | 1-byte文件扩至16,385 bytes | 6 / 3 | 1,077,249 | 1,101,824 | 一致 |
| S2 | 1 MiB文件缩至8,193 bytes | 6 / 3 | 36,866 | 65,536 | 一致 |
| S3 | 4,097-byte文件跨目录rename | 6 / 3 | 36,866 | 65,536 | 一致 |
| S4 | 为4,096-byte文件创建hardlink | 7 / 3 | 40,962 | 69,632 | 一致 |
| S5 | 删除hardlink的原始目录项 | 6 / 3 | 36,866 | 65,536 | 一致 |
| S6 | 删除零字节文件 | 5 / 3 | 36,866 | 61,440 | 一致 |

- 每一步都先由独立清单计算根、left、right三个目录的预期，再校验`info -r --strict`，最后轮询`info -r` fast；共42次目录结果全部精确相等；
- 七步均在第一次fast观测即一致。操作、清单、三次strict和三次fast查询合计为407～432 ms，因此只能证明“首次观测已正确”，不能把该值解释为纯DirStats传播延迟；
- 最终`summary --strict`与fast CSV逐行集合完全一致；阶段B的`/DIRTEST`在B2前后输出逐字节一致；
- hardlink按目录项计入files、length和size，与JuiceFS当前统计口径一致。Portal必须展示JuiceFS逻辑/计费口径，不能把它描述为唯一物理占用。

## 业务与容量闭环

- 前后均为14 targets、Ceph健康值0，6/6 OSD且全部PG clean；
- `juicefs-data`保持`1,978,612` objects和`518,630,965,248` bytes不变；临时file后端仍只有36-byte `juicefs_uuid`，稀疏测试未写Ceph对象；
- TiKV pending compaction始终为0；1分钟CPU采样由0变为约0.022核；
- 157根分区可用空间仅变化12 KiB；受控临时本地证据从597,718增至616,865 bytes，远低于64 MiB门；
- 业务挂载和JuiceFS进程指纹前后相同；临时测试卷继续挂载，未卸载或destroy。
- 原始结果归档SHA256为`64c2e5b4804a034d5551aaae94965ad788e9baf581b9f56f4cfa9439732b3bc8`，执行脚本SHA256为`d4ae4b4c6db7f5b5ef5d87a9d1fc00c7b50a5e54ede7c56f0be01c7acb7b6d3c`。

## 结论

B2证明社区版DirStats在本次有序单客户端元数据变更中，不仅比`du`快，而且对文件大小边界、目录移动、硬链接和删除能在首次查询时给出与独立清单一致的结果。它仍不等于对并发写入或异常崩溃的一般性强一致保证；门户应使用异步SQLite快照、标注采集时间，并保留低频strict抽样审计。

下一步是在用户确认后执行阶段C，将同一临时树扩到10万零字节文件，验证fast、strict和`du`的规模增长及刷新周期；不得自动进入100万档或清理卷。
