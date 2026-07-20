# Step 0: direct_io / FUSE 页缓存确认

## 结论

**direct_io 未启用，且无法通过 JuiceFS CLI 启用。FUSE 页缓存不会显著虚高 randread 读数。**

## 详细发现

### 1. 当前挂载选项（/proc/mounts）

```
JuiceFS:juicefs-prod /mnt/juicefs fuse.juicefs rw,nosuid,nodev,relatime,user_id=1002,group_id=1002,default_permissions,max_read=131072 0 0
```

- **无 `direct_io`**：FUSE 页缓存处于开启状态
- `--cache-size 0` 只禁用 JuiceFS 自身缓存，不等于关闭 FUSE 内核页缓存

### 2. 尝试挂载 `-o direct_io` 实例

```
juicefs mount -d --max-uploads 150 --cache-size 0 --max-readahead 0 -o direct_io <META> /mnt/juicefs-dio
```

**结果：fusermount3 3.10.5 拒绝 `direct_io` 选项**

```
/usr/bin/fusermount3: unknown option 'direct_io'
fuse: fusermount exited with code 256
```

**原因**：`direct_io` 是 FUSE2 时代的挂载选项，FUSE3 (fusermount3) 不再支持将其作为命令行挂载选项。在 FUSE3 中，`direct_io` 通过 `fuse_file_info->direct_io` 在打开文件时设置，不是全局挂载选项。

### 3. 影响评估：FUSE 页缓存是否虚高 randread 读数？

**结论：不会显著虚高。**

依据：
1. **fio 使用 `--direct=1`（O_DIRECT）**：在 VFS 层，O_DIRECT 绕过内核页缓存，直接发起 I/O 请求到 FUSE daemon
2. **01-2 数据验证**：randread 带宽 ~2572-2891 MiB/s，与 rados 后端裸测 ~3198 MiB/s 一致（客户端开销 11%）。如果 FUSE 页缓存在服务读请求，带宽会远超后端能力（受限于内存带宽，可达数十 GiB/s）
3. **juicefs stats 显示 object GET**：01-2 的 stats 数据显示 object GET 操作与 fio 读带宽匹配，证明读请求确实穿透到 Ceph RADOS 后端

### 4. 附带发现

- `--block-size`、`--storage`、`--bucket` 是 **format-time 选项**，不是 mount-time 选项。这些参数在 `juicefs format` 时写入 TiKV 元数据，mount 时从元数据读取。在 mount 命令中指定这些参数会导致 `reorderOptions` 报 "unknown option" 错误（JuiceFS 1.3.1+2025-12-02.e0032b2）
- 当前生产 mount 是通过 deploy-juicefs.sh 的早期版本创建的，当时可能使用了不同的参数解析路径

## 对后续测试的影响

- **无需额外对照测试**：direct_io 不可启用，且现有数据已证明读穿透到后端
- 所有后续测试继续使用现有 /mnt/juicefs 挂载（ra0 + cache0 + max-uploads 150）
