# JuiceFS 官方材料中仍可尝试的方向（来自 GPT 分析）

> 仅保留与 `/home/lilingfeng/demo/production/doc/perf-analysis/` 现有实测结论一致、且**未被**以下文档重复展开的方向：
>
> - `/home/lilingfeng/doc/juicefs-article-reference-for-tuning.md`
> - `/home/lilingfeng/doc/juicefs-article-reference-for-tuning-deepseek.md`

## 1. `--max-downloads` 下载并发上限

- 原因：官方命令参考明确提供了 `--max-downloads=200`（v1.4+）这一下载并发上限参数；现有两份参考文档没有把它单独提炼出来。
- 目标：验证是否能在**单客户端内**提高对象 GET 并发，避免只靠多客户端线性扩展。
- 官方链接：
  - `https://juicefs.com/docs/zh/community/command_reference#config`
  - `https://juicefs.com/docs/zh/community/command_reference#mount-data-storage-options`
  - `https://juicefs.com/zh-cn/blog/engineering/juicefs-read-performance`

## 2. `--cache-partial-only`

- 原因：官方缓存文档明确说明该参数适合“对象存储吞吐高于缓存盘、本地更适合作低时延随机读缓存”的场景；现有两份参考文档未提到。
- 目标：若后续拆出纯 `randread` 测试，可验证它是否比“全量缓存”更适合当前这种随机读路径。
- 官方链接：
  - `https://juicefs.com/docs/zh/community/guide/cache`
  - `https://juicefs.com/docs/zh/community/command_reference#mount-data-cache-options`

## 3. `randread / randwrite / randrw` 分开评估

- 原因：现有两份参考文档分别提到了 `randread` 和 `randrw`，但没有把“后续所有变更都按三条线分别记录结果”单独收敛成一个持续执行原则。
- 目标：避免混合结果掩盖读路径改进，便于判断某个改动到底改善的是读、写，还是都无效。
- 官方链接：
  - `https://juicefs.com/zh-cn/blog/engineering/juicefs-read-performance`
  - `https://juicefs.com/zh-cn/blog/engineering/juicefs-ai-workload-performance-optimization`

## 优先级

1. `--max-downloads`
2. `--cache-partial-only`（仅在纯 `randread` 支线下考虑）
3. 后续所有实验按 `randread / randwrite / randrw` 三条线分别记录
