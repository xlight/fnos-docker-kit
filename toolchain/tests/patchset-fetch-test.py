#!/usr/bin/env python3
"""patchset-fetch-test.py —— 容器侧补丁集下载器的语义回归（3.4/3.6/3.9）。

验证：
  1. 精确版本优先；
  2. 没有精确命中时选**覆盖度最高**的严格更早候选，并可列出未覆盖文件；
  3. 拒绝更高版本与预发布后缀；
  4. 旧索引（无 coverage/source_commit）按"精确命中"语义，行为不变；
  5. source_commit 存在时按该提交固定下载（URL 含 commit）；
  6. 已安装且索引未变 → 不重下；条目 revoked 或索引 revision 前进 → 需要刷新；
  7. 旧文件隔离为 .revoked-<ts>（不删除）。

用法: python3 toolchain/tests/patchset-fetch-test.py
退出码: 0 全过；1 有失败。
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("PASS: %s" % m)


def bad(m):
    global FAIL
    FAIL += 1
    print("FAIL: %s" % m)


from importlib.machinery import SourceFileLoader
_loader = SourceFileLoader("fetchmod", os.path.join(TC, "fnos-patchset-fetch"))
_spec = importlib.util.spec_from_loader("fetchmod", _loader)
fm = importlib.util.module_from_spec(_spec)
_loader.exec_module(fm)


def main():
    tmp = tempfile.mkdtemp(prefix="fetch-test-")
    try:
        fm.PATCHES = tmp
        # 1. 精确优先
        idx = {"revision": 19,
               "versions": {"1.2.1010": {"patchset": "fnos-1.2.1010.json", "sha256": "x"},
                            "1.2.1000": {"patchset": "fnos-1.2.1000.json", "sha256": "y"}},
               "coverage": {"1.2.1000": {"1.2.1010": {"covered_files": 7, "total_files": 8}}}}
        ver, entry, cell = fm.select_candidate("1.2.1010", idx)
        if ver == "1.2.1010":
            ok("1. 精确版本优先")
        else:
            bad("1. 精确命中被忽略：%s" % ver)

        # 2. 无精确命中 → 覆盖度最高的严格更早候选
        idx2 = {"revision": 19,
                "versions": {"1.2.1000": {"patchset": "a.json", "sha256": "y"},
                             "1.2.0900": {"patchset": "b.json", "sha256": "z"}},
                "coverage": {"1.2.1000": {"1.2.1010": {"covered_files": 7, "total_files": 8,
                                                        "missing": ["usr/trim/bin/resmon_service"]}},
                             "1.2.0900": {"1.2.1010": {"covered_files": 3, "total_files": 8}}}}
        ver, entry, cell = fm.select_candidate("1.2.1010", idx2)
        if ver == "1.2.1000":
            ok("2a. 选覆盖度最高的更早候选")
        else:
            bad("2a. 候选选择错：%s" % ver)
        if cell and cell.get("missing"):
            ok("2b. 候选带未覆盖文件清单")
        else:
            bad("2b. 候选缺未覆盖清单")

        # 3. 拒绝更高版本 / 预发布后缀
        idx3 = {"revision": 19,
                "versions": {"1.2.1020": {"patchset": "c.json", "sha256": "w"},
                             "1.2.1010-rc1": {"patchset": "d.json", "sha256": "v"}},
                "coverage": {}}
        cand = fm.select_candidate("1.2.1010", idx3)
        if cand is None:
            ok("3. 更高版本与预发布后缀都不作候选")
        else:
            bad("3. 错误地选了候选：%s" % cand[0])

        # 4. 旧索引（无 coverage）→ 精确命中语义；无精确命中时退回最近的严格更早
        idx4 = {"revision": 15, "versions": {"1.2.1000": {"patchset": "a.json", "sha256": "y"}}}
        cand = fm.select_candidate("1.2.1010", idx4)
        if cand and cand[0] == "1.2.1000" and cand[2] is None:
            ok("4. 旧索引无矩阵：退回最近严格更早版本，覆盖度为 None")
        else:
            bad("4. 旧索引语义错：%r" % (cand,))

        # 5. source_commit → 按提交固定下载
        parts = fm.raw_parts("https://raw.githubusercontent.com/o/r/main/toolchain/patches/index.json")
        if parts and parts[2] == "main":
            ok("5a. 索引 URL 解析出 owner/repo/ref")
        else:
            bad("5a. URL 解析错：%r" % (parts,))
        entry = {"patchset": "fnos-1.2.1000.json", "sha256": "y", "source_commit": "abc123"}
        got = []
        orig_fetch = fm.fetch

        def fake_fetch(url, timeout=20):
            got.append(url)
            return b"{}"

        fm.fetch = fake_fetch
        try:
            fm.download(entry, "fnos-1.2.1000.json",
                        "https://raw.githubusercontent.com/o/r/main/toolchain/patches/index.json")
        finally:
            fm.fetch = orig_fetch
        if got and "/abc123/" in got[0]:
            ok("5b. 按 source_commit 固定下载")
        else:
            bad("5b. 下载 URL 未按 commit 固定：%r" % got)

        # 6. 刷新判定
        idx6 = {"revision": 19, "versions": {"1.2.1000": {"patchset": "a.json", "sha256": "y"}}}
        fm.write_installed_revision("1.2.1000", 19)
        if not fm.needs_refresh("1.2.1000", idx6["versions"]["1.2.1000"], idx6):
            ok("6a. 索引 revision 未前进 → 不需刷新")
        else:
            bad("6a. 误判需要刷新")
        idx6b = {"revision": 20, "versions": {"1.2.1000": {"patchset": "a.json", "sha256": "y"}}}
        if fm.needs_refresh("1.2.1000", idx6b["versions"]["1.2.1000"], idx6b):
            ok("6b. 索引 revision 前进 → 需要刷新")
        else:
            bad("6b. 未识别索引前进")
        idx6c = {"revision": 19, "versions": {"1.2.1000": {"patchset": "a.json", "sha256": "y",
                                                           "revoked": True}}}
        if fm.needs_refresh("1.2.1000", idx6c["versions"]["1.2.1000"], idx6c):
            ok("6c. 条目被撤销 → 需要刷新")
        else:
            bad("6c. 未识别撤销")

        # 7. 隔离旧文件（不删除）
        p = os.path.join(tmp, "fnos-1.2.1000.json")
        open(p, "w").write("old")
        q = fm.quarantine(p)
        if q and os.path.exists(q) and not os.path.exists(p):
            ok("7. 旧文件隔离为 .revoked-<ts>（原文件移走，未删除）")
        else:
            bad("7. 隔离失败：%r" % q)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
