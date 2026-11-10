#!/usr/bin/env python3
"""required-files-test.py — 构建依赖契约自检（design D11）。

三件事：
  1. `fnos_patch.py --required-files` 的输出稳定（排序、两次一致）；
  2. `fnos_patch.py --self-check` 通过（报告集合 == apply() 实际 copy2 的源集合）；
  3. 报告的每个文件在**公开树**里存在（--public-root 指定公开仓根时）。

用法:
  python3 toolchain/tests/required-files-test.py [--public-root <公开仓根>]
  python3 toolchain/tests/required-files-test.py --version 1.2.1000
退出码: 0 全部通过；1 任一不符。
"""
import argparse, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)
REPO = os.path.dirname(TC)
PATCH = os.path.join(TC, "fnos_patch.py")


def run(args):
    p = subprocess.run([sys.executable, PATCH] + args, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--public-root", default=None,
                    help="公开仓根目录（其下应有 toolchain/ 与 scripts/）")
    ap.add_argument("--version", default=None, help="附带版本，校验补丁集项")
    a = ap.parse_args()
    errs = []

    # 1) 输出稳定
    args = ["--required-files"] + (["--version", a.version] if a.version else [])
    rc1, out1, err1 = run(args)
    rc2, out2, _ = run(args)
    if rc1 != 0 or rc2 != 0:
        errs.append("--required-files 退出码异常: %s/%s (%s)" % (rc1, rc2, err1.strip()[:200]))
    files1 = [x for x in out1.splitlines() if x.strip()]
    files2 = [x for x in out2.splitlines() if x.strip()]
    if files1 != files2:
        errs.append("--required-files 输出不稳定")
    if files1 != sorted(files1):
        errs.append("--required-files 输出未排序")
    if not files1:
        errs.append("--required-files 输出为空")
    # 集合成员正确性（关键项逐个断言）
    need = {"toolchain/aobpatch.py",
            "toolchain/assets/libfnos-trashshim.so",
            "toolchain/fnos-lib-consumers",
            "toolchain/fnos-nginx-route.sh",
            "toolchain/fnos-patch-status",
            "toolchain/fnos-patchset-fetch",
            "scripts/stor-mount-shim.sh"}
    miss = need - set(files1)
    if miss:
        errs.append("报告缺少构建输入: %s" % sorted(miss))
    if a.version:
        want = "toolchain/patches/fnos-%s.json" % a.version.lstrip("Vv")
        if want not in files1:
            errs.append("报告缺少补丁集项: %s" % want)

    # 2) 自检（报告集合 == apply() 实际读取源）
    rc, out, err = run(["--self-check", "--required-files"])
    if rc != 0:
        errs.append("--self-check 失败: %s" % (err.strip()[:300] or out.strip()[:300]))

    # 3) 私有仓里每个文件都真实存在
    for f in files1:
        p = os.path.join(REPO, f)
        if not os.path.isfile(p):
            errs.append("私有仓缺少构建输入: %s" % f)

    # 4) 公开树里每个文件都存在（给了 --public-root 才查）
    if a.public_root:
        for f in files1:
            p = os.path.join(a.public_root, f)
            if not os.path.isfile(p):
                errs.append("公开仓缺少构建输入: %s" % f)
        # 公开仓里跑一次自检（公开树自身也必须自洽）
        p = subprocess.run([sys.executable, os.path.join(a.public_root, "toolchain", "fnos_patch.py"),
                            "--self-check", "--required-files"],
                           capture_output=True, text=True)
        if p.returncode != 0:
            errs.append("公开仓自检失败: %s" % (p.stderr.strip()[:300] or p.stdout.strip()[:300]))

    if errs:
        for e in errs:
            print("FAIL: %s" % e)
        print("== 结果: FAIL=%d ==" % len(errs))
        return 1
    print("== 结果: PASS（构建依赖集合 %d 项，公开树%s）==" %
          (len(files1), "已校验" if a.public_root else "未校验"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
