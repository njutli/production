# JuiceFS VFS flush 派发竞态修复

当新 slice 的 ID 异步分配时，ID 就绪前写满的完整 block 永远不会被
派发——写路径检查 `s.id == 0` 跳过 `FlushTo`，ID 就绪路径只调 `SetID`
不补派发。

v1.3.x 上此 bug 导致 randwrite 吞吐崩塌约 5.5 倍（551 vs ~3000 MiB/s）。
main 上同一竞态存在但被更快的兜底排水掩盖。

## 文件

| 文件 | 说明 |
|------|------|
| `bug-report.md` | 问题现象、根因分析、v1.3 vs main 差异说明 |
| `patches/0001-vfs-dispatch-complete-blocks-after-preparing-slice-id.patch` | 修复补丁：`pkg/vfs/writer.go` 7 行 |
| `patches/0002-vfs-add-regression-tests-for-flush-dispatch.patch` | 回归测试：3 项确定性测试（243 行，新文件） |
| `test-report.md` | 测试步骤、结果、设计思路、原始数据路径 |
| `raw-test-data/U01/` | 全部原始日志、RC 文件、元数据、diff、结果表 |

## 补丁

两个补丁，按顺序在 `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a` 上应用：

```bash
git am patches/0001-vfs-dispatch-complete-blocks-after-preparing-slice-id.patch
git am patches/0002-vfs-add-regression-tests-for-flush-dispatch.patch
```

0001 是生产修复。0002 是回归测试，确定性验证 bug 和修复。

## 如何验证

```bash
git clone https://github.com/juicedata/juicefs
cd juicefs
git checkout 53835e2481f45cba159cdbcc1ce0f1fc576e3f1a
git am <path-to>/0001-*.patch
git am <path-to>/0002-*.patch

# 运行三项回归测试
go test -v -count=1 -run '^Test(FullBlock|PartialBlock|FlushError)' ./pkg/vfs/

# 运行完整 pkg/vfs（需要 Redis on 127.0.0.1:6379）
go test ./pkg/vfs -count=1
```

预期：全部测试通过。未打补丁的 stock 上，满 block 和错误路径测试
精确失败于目标 marker，半 block 负控通过。

## 作者

Li Lingfeng <a1151488180@gmail.com>
Assisted-by: DeepSeek <deepseek-v4-pro>
