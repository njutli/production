# 05-6：不同BS性能曲线与配置建议汇总

> 日期：2026-09-21
> 状态：`STAGE05_CLOSED_WITH_LIMITS / COMPLETED_OFFLINE`
> 性质：仅整理既有权威证据，不访问测试环境、不运行fio、不改变集群状态。

## 一、目标

用05-1至05-5b已经签收的数据回答三件事：

1. 当前通用配置下，不同应用BS对应的JuiceFS性能曲线是什么；
2. 哪些按BS调整有可复现收益，哪些没有形成候选；
3. 已归档有方数据能支持什么级别的端到端比较，05阶段还有哪些明确缺口。

## 二、输入与口径

- randrw：05-1、05-1b、05-2及独立审计；
- randread/randwrite：05-3b；
- seqread/seqwrite：05-4b；
- mseqread/mseqwrite：05-5b；
- 有方：既有12格randrw BS sweep归档，不补测；
- 主值沿用各报告的`[15,175)`正式窗，不把fio summary、正式窗或不同RUN混成一个效应量。

旧05-3/05-4/05-5因未满足当前私有msgr8基线，仅保留追溯。05-3b randwrite按
`WRITE_RANGE_ONLY_STATE_DRIFTED`收口，不跨RUN补点；有方矩阵按`MATRIX_DRIFTED / VALID_RANGE_ONLY`
呈现，缺少环境合同的行不得归因为软件单因素。

## 三、交付物与完成条件

1. 新建05阶段汇总报告，列出可签收曲线、按BS配置建议、竞品范围和证据限制；
2. 更新05阶段计划书状态与`results-table.md`；
3. 不为填满表格重跑已触发停止门的测试，不新增远端操作；
4. 文档内所有数字均能回指既有报告，旧结论冲突时以独立审计及b版复测为准。

## 四、最终裁决

`STAGE05_CLOSED_WITH_LIMITS / COMPLETED_OFFLINE`：05阶段已有证据已汇总；未完成项按证据等级如实保留，不再以重复测试延长阶段。
