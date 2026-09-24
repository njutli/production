# 06-2b range-flush调查制品

> `INVESTIGATION_BUILD / NOT_FOR_PRODUCTION`

本目录保存06-2b的调查补丁、两份确定性负例fixture和执行合同，供复核与上游代码讨论使用。
同源基座C的MD5为`4ea96bfb923733555221279d0a71083e`，修正版T的MD5为
`2f28b8a4fefa78dc95dfaa8b91f72844`。正确性修复通过，但性能筛选没有形成可重复材料收益；
不得引用本目录补丁宣称带宽提升，也不得将调查二进制用于生产。

结论和证据边界见：

- `doc/perf-report/06-2b-randrw-range-flush-repair-offline-validation-20260921.md`
- `doc/perf-report/06-2b-randrw-range-flush-repair-and-burst-validation-20260921.md`
