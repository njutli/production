#!/usr/bin/env python3
"""fnorder_check.py — 静态检查 bash 脚本的「函数在定义前被使用」（含间接调用）

动因：2026-08-05 mount-gear-attrib-test.sh 顶层第 89 行调用 safety_check_boot()，
      而它体内调用的 safety_check() 定义在第 87 行之后 → 运行时 command not found，
      脚本在产生任何数据前退出。bash -n 只查语法，查不出这类问题。

原理：bash 顺序解释，函数只在"读到定义行"之后才存在。
      因此顶层第 L 行调用 F 时，**F 及 F 传递可达的所有函数**都必须定义在 L 行之前。

用法：python3 fnorder_check.py <script.sh> [...]
退出码：0 = 通过；1 = 发现问题
"""
import re
import sys

KEYWORDS = set("""
if then else elif fi for while until do done case esac function in select time
{ } [ ] [[ ]] ! local return exit break continue declare readonly export unset eval
""".split())


def parse(path):
    lines = open(path, errors="ignore").read().splitlines()
    defs = {}
    owner = [None] * (len(lines) + 2)   # 行号 → 所属函数名（None = 顶层）
    depth = 0
    cur = None
    for i, l in enumerate(lines, 1):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", l)
        if m:
            defs.setdefault(m.group(1), i)
            cur = m.group(1)
            depth = 1
            owner[i] = cur
            continue
        if cur is not None:
            owner[i] = cur
            depth += l.count("{") - l.count("}")
            if depth <= 0:
                cur = None
                depth = 0
        else:
            owner[i] = None
    return lines, defs, owner


def called_names(line, defs):
    """本行以命令位置出现的、且是脚本内函数名的 token"""
    out = set()
    s = line
    s = re.sub(r"#.*$", "", s)
    # 命令位置：行首、| && || ; ( $( 之后
    for m in re.finditer(r"(?:^|\||&&|;|\(|\{|\bthen\b|\bdo\b|\belse\b|&)\s*([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*=)", s):
        n = m.group(1)
        if n in defs and n not in KEYWORDS:
            out.add(n)
    # 也算 $( f ) 与 if f; 形式
    for m in re.finditer(r"\$\(\s*([A-Za-z_][A-Za-z0-9_]*)\b", s):
        if m.group(1) in defs:
            out.add(m.group(1))
    return out


def check(path):
    lines, defs, owner = parse(path)
    # 调用图
    graph = {f: set() for f in defs}
    toplevel = []          # (行号, 函数名)
    for i, l in enumerate(lines, 1):
        if re.match(r"^\s*#", l) or not l.strip():
            continue
        if re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", l):
            continue
        # case 分支模式 `word)` / `a|b)` 不是函数调用（2026-08-05 加：MODE 解析里的
        # `precheck)` `r3)` 曾被误判成调用同名函数）
        if re.match(r"^\s*\(?[A-Za-z0-9_.*?\[\]|/-]+\)\s", l) and not re.search(r"\(\)", l):
            continue
        names = called_names(l, defs)
        if not names:
            continue
        o = owner[i]
        if o is None:
            for n in names:
                toplevel.append((i, n))
        else:
            graph.setdefault(o, set()).update(names)

    problems = []
    for line_no, f in toplevel:
        # 传递闭包
        seen, stack = set(), [f]
        while stack:
            x = stack.pop()
            if x in seen:
                continue
            seen.add(x)
            stack.extend(graph.get(x, ()))
        for g in sorted(seen):
            if defs[g] > line_no:
                chain = "" if g == f else "（%s 间接调用）" % f
                problems.append("顶层第 %d 行调用 %s()，但 %s() 定义在第 %d 行%s ⇒ 运行时 command not found"
                                % (line_no, f, g, defs[g], chain))

    print("=== %s ===" % path)
    print("  函数 %d 个，顶层调用 %d 处" % (len(defs), len(toplevel)))
    if problems:
        for p in sorted(set(problems)):
            print("  🔴 " + p)
        return False
    print("  ✅ 所有顶层调用（含间接可达函数）都在定义之后")
    return True


if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)
ok = all(check(p) for p in sys.argv[1:])
sys.exit(0 if ok else 1)
