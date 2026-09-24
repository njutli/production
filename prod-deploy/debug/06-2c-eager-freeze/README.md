# 06-2c eager-freeze 调查补丁

本目录保存06-2c的唯一源码候选，不是可交付JuiceFS源码树。

- `candidate-decision.md`：为什么选择该候选及行为边界；
- `eager-freeze.patch`：相对06-2冻结的官方1.4.1+B-catchup权威源码包；
- 权威源码包：`/mnt/c/SunRise/test/06-2/20260916-091446/build/juicefs-v1.4.1-b-catchup-source.tar.gz`；
- 源码包SHA256：`a3265ff95e68dc08d53afe3e755b063516e0403f53a5dd04248118b8b9c97451`。

只能通过06-2c离线Gate生成C/T调查二进制。补丁默认关闭，T臂必须显式传
`--experimental-eager-freeze`；二进制和开关均标记`NOT_FOR_PRODUCTION`。
