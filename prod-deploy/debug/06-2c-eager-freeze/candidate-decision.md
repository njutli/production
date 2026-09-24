# 06-2c 候选决策：完整非增长对象块提前冻结

状态：`SELECTED_FOR_OFFLINE_VALIDATION / NOT_FOR_PRODUCTION / NO_ENVIRONMENT_RESULT`  
日期：2026-09-22

## 决策

06-2c只实现并筛选一个候选：当一次写操作完整覆盖一个与卷`BlockSize`对齐的对象块，且不增长文件时，
立即冻结该slice并沿用既有`flushData → Finish → FIFO commitThread → meta.Write`路径。

选择依据：冻结1.4.1中，达到对象块大小通常只调用`FlushTo`，slice仍可等待后台冻结或后续读触发flush；
提前冻结可能把`Finish`和元数据提交移出读前等待。该链路是可验证假设，不是已证实瓶颈。

本轮不选择：

- 继续缩小range-flush：06-2b没有重复材料收益，现有证据也未证明必要FIFO前缀之外仍有大量可排除等待；
- 放松inode/handle锁：会改变读写排序和read-your-own-writes边界，不属于最小局部修改。

## 最小行为差异

- 新增隐藏且默认关闭的`--experimental-eager-freeze`开关；
- 只有`!growing && relative_off=0 && write_len=BlockSize && slice_len=BlockSize && logical_off%BlockSize=0`
  才提前冻结；
- 部分块、非对齐写、增长/EOF写全部保留原逻辑；
- 不修改读路径、Flush/FlushRange、提交FIFO、元数据协议、缓存持久化或锁。

## 风险与进入环境前的缺口

提前冻结会减少后续合并机会，可能增加slice、元数据事务、对象请求和排空压力。环境筛选必须按每GiB
应用完成写量归一报告这些代价。当前定向测试覆盖开关、全局对齐触发边界、真实VFS已知内容读回，并
直接确认提前冻结的slice在任何读或显式flush之前已完成既有commitThread/meta.Write链路；真实FUSE下
WB排空后独立读回、错误/取消与更完整的重叠写语义仍须在环境性能矩阵前完成。

完整性能判据、安全合同和停止规则以
[06-2c任务书](../../doc/perf-tasks/06-2c-randrw-write-path-source-optimization-screen.md)为准。
