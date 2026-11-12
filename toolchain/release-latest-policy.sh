#!/usr/bin/env bash
# ============================================================================
# release-latest-policy.sh —— 决定本次发布是否应抢 GitHub Release 的 "Latest" 标记
#
# 为什么要它：GitHub 的 "Latest" 默认按**发布时间**选，于是"先发 1.2.1010、后补发 1.2.1000"
# 会让 Latest 指向**版本更旧**的那个补丁集（2026-11-12 实测：v1.2.1000 成了 Latest，
# 而内容更新的是 v1.2.1010-r3）。本脚本按 **fnOS 版本号**判定，与发布时间无关。
#
# 用法: release-latest-policy.sh <新版本> [当前 Latest 的 tag]
# 输出: latest | not-latest
#   · 新版本 > 当前 Latest 的版本  → latest
#   · 同一版本的更高修订号（-rN） → latest
#   · 更旧的版本 / 无法解析         → not-latest
# ============================================================================
set -uo pipefail
NEW_VER="${1:-}"
CUR_TAG="${2:-}"

python3 - "$NEW_VER" "$CUR_TAG" <<'PY'
import re
import sys


def key(tag):
    """'v1.2.1010-r3' → ([1,2,1010], 3)；'v1.2.1010' → ([1,2,1010], 1)。"""
    m = re.match(r"^v?(\d+(?:\.\d+)*)(?:-r(\d+))?$", (tag or "").strip())
    if not m:
        return None
    return ([int(x) for x in m.group(1).split(".")], int(m.group(2) or 1))


new = key(sys.argv[1] if len(sys.argv) > 1 else "")
cur = key(sys.argv[2] if len(sys.argv) > 2 else "")
if new is None:
    print("not-latest")
    sys.exit(0)
if cur is None:
    print("latest")          # 没有当前 Latest（或解析不了）→ 新的接管
    sys.exit(0)
a, b = new[0], cur[0]
n = max(len(a), len(b))
a = a + [0] * (n - len(a))
b = b + [0] * (n - len(b))
if a > b or (a == b and new[1] >= cur[1]):
    print("latest")
else:
    print("not-latest")
PY
