#!/usr/bin/env python3
"""fingerprints-test.py —— 指纹提取与覆盖度复算的回归（3.1）。

验证：
  1. 同一文件出现在多条补丁记录里时，取**第一条**的 input_sha256
     （后续记录读到的是中间态，直接遍历会得到"被打过一半"的哈希）；
  2. 二进制补丁（记录级 input_sha256）与文本补丁（files[] 内）都能提取；
  3. 覆盖度可由指纹 + 补丁集 file_hashes 复算（覆盖/缺口/未知）；
  4. 指纹资产落盘格式稳定（version/state/files）。
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TC, "ci-public"))
import importlib.util

spec = importlib.util.spec_from_file_location(
    "fp", os.path.join(TC, "ci-public", "fingerprints.py"))
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)

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


REPORT = {
    "fnos_version": "V1.2.1000",
    "patchset": "fnos-1.2.1000.json",
    "patchset_sha256": "pssha",
    "patches": [
        # 二进制补丁（记录级哈希）
        {"id": "resmon_service.veth-kind", "kind": "binary",
         "file": "usr/trim/bin/resmon_service",
         "input_sha256": "FACTORY_RESMON", "status": "ready"},
        # 同一文件的第二条补丁：input 已是中间态
        {"id": "resmon_service.disk-io-refresh#0", "kind": "binary",
         "file": "usr/trim/bin/resmon_service",
         "input_sha256": "INTERMEDIATE_RESMON", "status": "ready"},
        # 文本补丁（files[] 内）
        {"id": "www.setting", "kind": "text", "file": "usr/trim/www/assets/Setting-*.js",
         "files": [{"file": "usr/trim/www/assets/Setting-abc.js",
                    "input_sha256": "FACTORY_WWW", "status": "ready"}]},
    ],
}

PS = {"file_hashes": {
    "usr/trim/bin/resmon_service": {"orig": "FACTORY_RESMON", "patched": "PATCHED_RESMON"},
    "usr/trim/www/assets/Setting-abc.js": {"orig": "FACTORY_WWW", "patched": "PATCHED_WWW"},
    "usr/trim/bin/other": {"orig": "OTHER_ORIG", "patched": "OTHER_PATCHED"},
}}


def main():
    data = fp.extract(REPORT, "1.2.1000")
    files = data["files"]
    if files.get("usr/trim/bin/resmon_service") == "FACTORY_RESMON":
        ok("1. 同一文件取第一条记录的 input_sha256（不是中间态）")
    else:
        bad("1. 取到了中间态：%r" % files.get("usr/trim/bin/resmon_service"))
    if files.get("usr/trim/www/assets/Setting-abc.js") == "FACTORY_WWW":
        ok("2a. 文本补丁的 files[] 能提取")
    else:
        bad("2a. 文本补丁未提取")
    if data.get("state") == "factory" and data.get("version") == "1.2.1000":
        ok("2b. 资产字段正确（version/state）")
    else:
        bad("2b. 资产字段错：%r" % data)

    # 覆盖度复算
    tmp = tempfile.mkdtemp()
    ps_f = os.path.join(tmp, "ps.json")
    json.dump(PS, open(ps_f, "w"))
    v = fp.verify(data, ps_f)
    if v["covered"] == 2 and v["total"] == 2 and not v["missing"]:
        ok("3a. 覆盖度复算：2/2 覆盖")
    else:
        bad("3a. 覆盖度复算错：%r" % v)
    # 缺口场景：指纹哈希不在 orig/patched 集合内
    data2 = {"files": {"usr/trim/bin/resmon_service": "SOMETHING_ELSE"}}
    v2 = fp.verify(data2, ps_f)
    if v2["missing"] == ["usr/trim/bin/resmon_service"] and v2["covered"] == 0:
        ok("3b. 缺口被点名（未覆盖文件）")
    else:
        bad("3b. 缺口判定错：%r" % v2)

    print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
