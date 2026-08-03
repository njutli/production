# 系统安全红线 Skill

> 目的：杜绝因命令误操作导致生产节点不可达的事故。
> 创建：2026-07-27（node1/node2 chown -R / 事故后）
> 适用范围：**所有远程操作，无例外**

---

## 〇、最高原则

**任何改变文件所有权、删除文件、覆写设备的命令，执行前必须经过路径验证。没有例外。**

**所有操作不得影响已有业务的运行。** 157 上的 WekaIO、K8s 及其他生产服务属于红线保护区，任何操作（包括但不限于 chown/chmod/rm/dd/kill/重启服务/修改网络配置/修改内核参数）不得导致这些业务中断或性能劣化。执行前须评估影响范围，有疑问时停下报告。

---

## 一、禁止事项（红线，违反即事故）

### 1.1 禁止在嵌套 SSH 中用变量传路径

**禁止**：
```bash
ssh jump "ssh target 'chown -R 167:167 \$VAR/'"
# $VAR 在中间层可能被展开为空 → chown -R 167:167 /
```

**必须**：上传脚本到目标节点执行（见 §二）。

### 1.2 禁止 chown -R / rm -rf 的目标为变量或可能为空

以下场景必须先验证路径非空、非根：
- `chown -R`
- `chgrp -R`
- `rm -rf`
- `chmod -R`
- `dd if=/dev/zero of=...`
- `wipefs -a`
- `pvremove -ff`
- `vgremove --force`
- `dmsetup remove`

### 1.3 禁止未经确认执行 sudo 写操作

向脚本中添加 sudo 操作命令或手动执行 sudo 操作命令前，**必须经用户确认**（只读命令除外）。

- **需确认**：`sudo rm`、`sudo chown`、`sudo chmod`、`sudo systemctl stop`、`sudo umount`、`sudo wipefs`、`sudo dd`、`sudo podman rm` 等一切会改变系统状态的 sudo 命令
- **无需确认**：`sudo ls`、`sudo cat`、`sudo mount | grep`、`sudo podman ps` 等只读命令
- 确认时须列出完整命令和目标节点，用户明确回复"确认"后方可执行

### 1.4 禁止多节点并行执行破坏性命令

必须逐节点执行：改完 node1，确认无误，再改 node2。

### 1.5 禁止在未验证路径的情况下使用 -R 递归

能用精确文件列表就不用 -R：
```bash
# 禁止
chown -R 167:167 $DIR/
# 推荐
chown 167:167 "$DIR/file1" "$DIR/file2" "$DIR/file3"
```

### 1.6 禁止在未确认执行环境的情况下执行命令

执行任何命令前，必须确认当前所在的机器（WSL 本地 vs 157 远程 vs slave 节点）。混淆本地与远程环境会导致命令在错误机器上执行。远程操作必须通过显式 SSH 进行。

---

## 二、强制流程（破坏性命令执行前必须完成）

### 2.1 上传脚本，不在嵌套 SSH 中内联

```bash
# 1. 本地写脚本（用单引号 heredoc，阻止一切变量展开）
cat > /tmp/fix-perm.sh << 'EOF'
#!/bin/bash
set -euo pipefail

OSDDIR="/var/lib/ceph/020ed5ec-8703-11f1-a671-97520597268c/osd.1"

# 2. 路径守卫
[ -n "$OSDDIR" ] || { echo "REFUSE: empty path"; exit 1; }
[ "$OSDDIR" != "/" ] || { echo "REFUSE: root path"; exit 1; }
[ "$OSDDIR" != "" ] || { echo "REFUSE: empty path"; exit 1; }
[ -d "$OSDDIR" ] || { echo "REFUSE: not a directory: $OSDDIR"; exit 1; }

# 3. Dry-run（先打印，不执行）
echo "DRY-RUN: will chown -R 167:167 $OSDDIR/"
ls -la "$OSDDIR/"

# 4. 执行（路径已验证为非根、非空、是目录）
chown -R 167:167 "$OSDDIR/"
echo "DONE: $OSDDIR"
EOF

# 5. 上传到目标节点
scp /tmp/fix-perm.sh node1:/tmp/

# 6. 先 dry-run（注释掉实际 chown 行，跑一遍验证路径）
ssh node1 "bash /tmp/fix-perm.sh"

# 7. 确认输出无误后，取消注释 chown 行，重新上传执行
```

### 2.2 set -euo pipefail 置顶

脚本第一行必须是：
```bash
#!/bin/bash
set -euo pipefail
```

- `set -e`：命令失败立即退出
- `set -u`：引用未设置变量立即退出（**最关键**：$OSDDIR 为空时直接报错退出，不执行 chown）
- `set -o pipefail`：管道中任一环节失败即整体失败

### 2.3 路径守卫（所有破坏性命令前必须）

```bash
safety_check() {
    local target="$1"
    [ -n "$target" ] || { echo "REFUSE: empty path"; exit 1; }
    [ "$target" != "/" ] || { echo "REFUSE: root path"; exit 1; }
    [ "${target:0:1}" = "/" ] || { echo "REFUSE: relative path"; exit 1; }
    echo "SAFE: target=$target"
}

safety_check "$TARGET"
chown -R 167:167 "$TARGET/"
```

### 2.4 Dry-run 先行

破坏性命令执行前，先打印将要执行的命令和目标路径，人工确认：
```bash
echo "WILL EXECUTE: chown -R 167:167 $OSDDIR/"
echo "FILES AFFECTED:"
find "$OSDDIR" -maxdepth 1 -type f | head -10
# 确认输出无误后，取消注释执行
# chown -R 167:167 "$OSDDIR/"
```

---

## 三、SSH 嵌套操作规范

### 3.1 变量传递

在多层 SSH（WSL → 跳板 → 目标节点）中：

| 方式 | 安全性 | 说明 |
|------|--------|------|
| 上传脚本 + heredoc `<< 'EOF'` | ✅ 最安全 | 变量在脚本内硬编码，不经过 shell 展开 |
| `ssh -o SendEnv` 传环境变量 | ✅ 安全 | 变量在目标 shell 中展开 |
| 嵌套 SSH + `\$VAR` 转义 | ❌ 危险 | 变量可能在中间层被错误展开 |
| 嵌套 SSH + `$VAR` 不转义 | ❌ 危险 | 变量在中间层被展开，目标层收不到 |

### 3.2 推荐模式

```bash
# 1. 本地写脚本
cat > /tmp/op.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
# 硬编码所有路径，不依赖外部变量
TARGET="/var/lib/ceph/020ed5ec-8703-11f1-a671-97520597268c/osd.1"
[ -d "$TARGET" ] || exit 1
chown -R 167:167 "$TARGET/"
SCRIPT

# 2. 通过跳板上传到目标节点
ssh jump "scp -O -r /tmp/op.sh sunrise@target:/tmp/" 2>/dev/null

# 3. 执行
ssh jump "ssh target 'bash /tmp/op.sh'"
```

---

## 四、事故案例（2026-07-27）

### 事故经过

在嵌套 SSH（WSL → thailand → node1）中执行：
```bash
ssh thailand "
  FSID=020ed5ec-...
  ssh node1 \"
    OSDDIR=/var/lib/ceph/\$FSID/osd.1
    sudo chown -R 167:167 \$OSDDIR/
  \"
"
```

**根因**：`\$OSDDIR` 在 thailand shell 层被展开（thailand 上没有 `OSDDIR` 变量 → 展开为空），目标节点收到的命令变成 `chown -R 167:167 /`，递归修改了整个文件系统所有权。

**后果**：node1 和 node2 不可达（sshd 主机密钥文件所有权被改，拒绝连接），sudo 损坏。

**教训**：
1. 嵌套 SSH 中的变量展开层次极易出错
2. `chown -R` 目标为空时变成 `chown -R /`
3. 多节点并行执行放大了事故影响
4. `set -u` 能在此场景救命

---

## 五、检查清单（执行破坏性命令前逐条确认）

- [ ] 命令写在独立脚本中，用 `<< 'EOF'` heredoc
- [ ] 脚本首行 `set -euo pipefail`
- [ ] 目标路径硬编码在脚本内（不依赖外部变量）
- [ ] 路径守卫：非空、非根、是目录
- [ ] 先 dry-run（打印命令 + 列出目标文件）
- [ ] 确认 dry-run 输出无误
- [ ] 逐节点执行（不并行）
- [ ] 改完一个节点，验证可达 + 服务正常，再做下一个
