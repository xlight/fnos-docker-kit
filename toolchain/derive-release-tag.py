#!/usr/bin/env python3
"""derive-release-tag.py —— 推导本次发布该用的 tag（design D4/D13）。

规则：
  · 目标发布 tag `v<ver>` 不存在            → 用 `v<ver>`（首发）
  · `v<ver>` 已存在                          → 用 `v<ver>-r<N+1>`（修正，N = 既有最大修订号）
  · 查不到既有 tag（远端不可达/查询失败）   → 退出码 2（fail-closed：调用方不得发布）

既有用法（发布单元、人工旁路共用同一份实现，避免两套语义）：

  python3 derive-release-tag.py --repo <公开仓工作区> --version <fnOS 版本>
  # stdout: v1.2.1010 或 v1.2.1010-r2
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys


def list_tags(repo):
    """远端 tag 列表；查询失败抛异常（调用方按 fail-closed 处理）。"""
    p = subprocess.run(["git", "-C", repo, "ls-remote", "--tags", "origin"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("ls-remote 失败: %s" % (p.stderr or "").strip()[:120])
    names = []
    for line in p.stdout.splitlines():
        m = re.search(r"refs/tags/([^\^]+)", line)
        if m:
            names.append(m.group(1))
    return names


def sha256_of_tag(repo, tag, path):
    """tag 里那份文件的 sha256（取不到返回 None）。"""
    try:
        p = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (tag, path)],
                           capture_output=True)
        if p.returncode != 0:
            return None
        return hashlib.sha256(p.stdout).hexdigest()
    except Exception:
        return None


def derive(repo, version, patchset_file=""):
    tags = list_tags(repo)
    v = version.lstrip("Vv")
    base = "v%s" % v
    if base not in tags:
        return base
    revs = []
    rx = re.compile(r"^%s-r(\d+)$" % re.escape(base))
    for t in tags:
        m = rx.match(t)
        if m:
            revs.append((int(m.group(1)), t))
    # 续跑优先：已存在且**内容与本次补丁集一致**的修订号 → 直接用它。
    # （上次可能"建了 tag 但没发完 Release"——发布分两步（tag / 资产）不是原子的，
    #   若一律取 max+1，那个半成品 tag 会被永远跳过、每次重试都多一个修订号。）
    if patchset_file and os.path.isfile(patchset_file):
        want = hashlib.sha256(open(patchset_file, "rb").read()).hexdigest()
        rel = "toolchain/patches/" + os.path.basename(patchset_file)
        for _, t in sorted(revs, reverse=True):
            got = sha256_of_tag(repo, t, rel)
            if got and got == want:
                return t
    return "%s-r%d" % (base, (max(n for n, _ in revs) + 1) if revs else 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--patchset-file", default="",
                    help="本次补丁集路径（给了就优先续跑内容一致的既有修订号）")
    a = ap.parse_args()
    try:
        print(derive(a.repo, a.version, a.patchset_file))
    except Exception as e:
        print("[derive-tag] 查询失败（fail-closed，不发布）: %s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
