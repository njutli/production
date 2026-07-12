# gc --delete 失效根因诊断结论

## 根因：gc skip 是"正常语义"——slices 仍被文件引用时 gc 正确跳过，不是 bug

### 证据

| 实验 | 场景 | gc --delete 结果 | 池变化 | 结论 |
|------|------|-----------------|--------|------|
| Exp1 | 写1G+randwrite60s,**不删文件** | 0 deleted, 33391 skipped | 8.1→8.1 (无变化) | gc 正确跳过有引用的 slice |
| Exp2 | 写1G+randwrite60s,**删文件+等5s** | 5555 pending slices deleted, 5554 skipped | 5.7→4.5→**0**(后台清理) | gc 删 pending slice，后台异步清对象 |
| Exp3 | compact(meta URL 语法错误) | error: path not found | - | compact 需用 mount point |
| Exp4 | 多次 gc --delete | 第2次: 0 scanned, 0 skipped | 池已空 | 后台清理已完成 |
| Exp5 | compact(mount point 语法) | **超时(>5min)** | - | compact 太慢不可用 |
| Exp6 | compact(文件存在) | **超时** | - | 同上 |

### 机制解释
1. **randwrite 覆盖写产生 orphan slice**：每次覆盖写，JuiceFS 创建新 slice，旧 slice 仍被文件的 slice list 引用
2. **gc 只回收"无引用的 orphan"**：文件还存在 → slice 仍被引用 → gc 正确 skip
3. **删文件后 slice 变成 pending delete**：文件删除 → slice 解引用 → gc 标记为 pending delete → 删除 metadata → 后台异步删 Ceph 对象
4. **"stop deleting slice"**：gc 批量删除时的速率限制，不阻止后续清理（后台继续）
5. **后台清理 ~1-2 min 完成**：mount daemon 异步删除 Ceph 对象

### v2 池满根因
v2 中 randwrite 180s × 3 轮在文件未删时 gc → 全 skip → orphan slice 累积 → 池满。
**正确做法**：每轮 randwrite+randrw 后删 test_dir → gc → 等 2 min → 重建 layout。

### Phase B 方案
**方案：每轮后删文件+gc+重建 layout**（方案①删文件+gc，非扩 tmpfs）
- 每轮 randwrite 180s + randrw 180s 产生 ~30G orphan slice
- 128G layout + 30G = 158G (OSD %USE 80.6% < 85% 安全)
- 每轮后：rm test_dir/* → gc --delete → 等 2 min → 池空 → layout 128G (20min)
- 代价：每轮额外 ~23 min（gc 3min + layout 20min），2 次中间清理 = ~46 min

### config 确认
- BlockSize=256 KiB ✅
- TrashDays=0 ✅（trash 不是问题）
