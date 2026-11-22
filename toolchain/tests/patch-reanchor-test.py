#!/usr/bin/env python3
# ============================================================================
# patch-reanchor-test.py —— fnos-patch-reanchor 的回归（**无破坏性**）
#
# 覆盖：exact / no-match / expect-mismatch / variant-mismatch / text glob /
#       副本校验（假 aobpatch）。
#
# 用法: python3 toolchain/tests/patch-reanchor-test.py
# 退出码: 0 全过 / 1 有失败
# ============================================================================
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REANCHOR = os.path.join(os.path.dirname(HERE), "fnos-patch-reanchor")
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


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(path, mode) as f:
        f.write(data)


def run(rootfs, out, prev, extra=None):
    cmd = [sys.executable, REANCHOR, "rootfs", "version", "out", "from"]
    cmd = [sys.executable, REANCHOR, "--rootfs", rootfs, "--version", "1.2.1102",
           "--out", out, "--from", prev, "--no-validate"]
    if extra:
        cmd += extra
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        doc = {"_raw": r.stdout, "_err": r.stderr}
    return r.returncode, doc


def main():
    tmp = tempfile.mkdtemp(prefix="fnos-reanchor-test.")
    root = os.path.join(tmp, "root")
    write(os.path.join(root, "usr/trim/lib/libnperm.so"), b"\x41\x42\x43")
    write(os.path.join(root, "usr/trim/www/assets/index.js"), "abc")

    a1 = {"id": "a1", "file": "usr/trim/lib/libnperm.so", "match": "41 42",
          "replace": [{"find": "41", "to": "43"}], "expect": 1}
    a2 = {"id": "a2", "file": "usr/trim/lib/libnperm.so", "match": "99 98",
          "replace": [{"find": "99", "to": "97"}], "expect": 1}
    t1 = {"id": "t1", "kind": "text", "file": "usr/trim/www/assets/*.js",
          "find": "abc", "to": "def", "expect": 1}

    def patchset(name, patches):
        p = os.path.join(tmp, name)
        write(p, json.dumps({"fnos_version": "1.2.1010",
                             "derived_from_table": "test", "file_hashes": {},
                             "patches": patches}))
        return p

    a3 = {"id": "a3", "file": "usr/trim/lib/libnperm.so", "match": "99 98",
          "replace": [], "expect": 1, "status": "retired", "retired_reason": "test"}
    prev_ok = patchset("prev_ok.json", [a1, t1, a3])
    prev_bad = patchset("prev_bad.json", [a1, a2, t1])
    prev_one = patchset("prev_one.json", [a1])

    # ① exact + text carried → ok
    rc, doc = run(root, os.path.join(tmp, "o1.json"), prev_ok)
    fh = {}
    try:
        fh = json.load(open(os.path.join(tmp, "o1.json"))).get("file_hashes") or {}
    except ValueError:
        pass
    fh_ok = (isinstance(fh.get("usr/trim/lib/libnperm.so"), dict)
             and fh["usr/trim/lib/libnperm.so"].get("orig"))
    kept_ids = [p["id"] for p in json.load(open(os.path.join(tmp, "o1.json")))["patches"]]
    retired_ok = ("a3" in kept_ids and doc.get("ready") == 2 and doc.get("total") == 2)
    if rc == 0 and doc.get("ready") == 2 and not doc.get("manual") and fh_ok and retired_ok:
        ok("① exact + text + retired → keep/carried，rc=0；file_hashes={orig} 结构正确")
    else:
        bad("① 结果不符: rc=%s %s" % (rc, doc))

    # ② no-match（a2 无命中）
    root2 = os.path.join(tmp, "root2")
    write(os.path.join(root2, "usr/trim/lib/libnperm.so"), b"\x41\x42\x99\x99")
    write(os.path.join(root2, "usr/trim/www/assets/index.js"), "abc")
    rc, doc = run(root2, os.path.join(tmp, "o2.json"), prev_bad)
    reasons = {m["id"]: m["reason"] for m in doc.get("manual", [])}
    if rc == 1 and reasons.get("a2") == "no-match" and "a1" not in reasons:
        ok("② no-match → rc=1 且点名 a2")
    else:
        bad("② no-match 不符: rc=%s %s" % (rc, doc))

    # ③ expect-mismatch（出现 2 次，expect=1）
    root3 = os.path.join(tmp, "root3")
    write(os.path.join(root3, "usr/trim/lib/libnperm.so"), b"\x41\x42\x41\x42")
    rc, doc = run(root3, os.path.join(tmp, "o3.json"), prev_one)
    reasons = {m["id"]: m["reason"] for m in doc.get("manual", [])}
    if rc == 1 and reasons.get("a1") == "expect-mismatch":
        ok("③ expect-mismatch → rc=1 且点名 a1")
    else:
        bad("③ expect-mismatch 不符: rc=%s %s" % (rc, doc))

    # ④ variant-mismatch（两个 rootfs，只有一个命中）
    root4 = os.path.join(tmp, "root4")
    write(os.path.join(root4, "usr/trim/lib/libnperm.so"), b"\x99\x99")
    write(os.path.join(root4, "usr/trim/www/assets/index.js"), "abc")
    cmd = [sys.executable, REANCHOR, "--rootfs", root, "--rootfs", root4,
           "--version", "1.2.1102", "--out", os.path.join(tmp, "o4.json"),
           "--from", prev_ok, "--no-validate"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    doc = json.loads(r.stdout)
    reasons = {m["id"]: m["reason"] for m in doc.get("manual", [])}
    if r.returncode == 1 and reasons.get("a1") == "variant-mismatch":
        ok("④ variant-mismatch → rc=1 且点名 a1")
    else:
        bad("④ variant-mismatch 不符: rc=%s %s" % (r.returncode, doc))

    # ⑤ 副本校验（假 aobpatch；通过）
    fake = os.path.join(tmp, "fake-aobpatch.py")
    write(fake, '''#!/usr/bin/env python3
import json, os, sys
cmd = sys.argv[1]
rootfs = sys.argv[sys.argv.index("--rootfs") + 1] if "--rootfs" in sys.argv else ""
if cmd == "apply":
    print(json.dumps({"ok": True, "patches": []})); sys.exit(0)
if os.path.exists(os.path.join(rootfs, ".fail")):
    print(json.dumps({"ok": False, "patches": [{"id": "a1", "status": "failed"}]}))
else:
    print(json.dumps({"ok": True, "patches": [{"id": "a1", "status": "applied"}]}))
''')
    os.chmod(fake, 0o755)
    out = os.path.join(tmp, "o5.json")
    r = subprocess.run([sys.executable, REANCHOR, "--rootfs", root,
                        "--version", "1.2.1102", "--out", out,
                        "--from", prev_ok, "--aobpatch", fake],
                       capture_output=True, text=True)
    doc = json.loads(r.stdout)
    out5 = json.load(open(out))
    fh5 = out5.get("file_hashes") or {}
    filled = all(isinstance(v, dict) and v.get("patched") for v in fh5.values()) if fh5 else False
    if r.returncode == 0 and doc.get("ok") and filled:
        ok("⑤ 副本校验通过 → ok；file_hashes 已回填 patched")
    else:
        bad("⑤ 校验通过用例不符: rc=%s %s filled=%s" % (r.returncode, doc, filled))

    # ⑥ 校验失败 → rc=1
    write(os.path.join(root, ".fail"), "")
    out6 = os.path.join(tmp, "o6.json")
    r = subprocess.run([sys.executable, REANCHOR, "--rootfs", root,
                        "--version", "1.2.1102", "--out", out6,
                        "--from", prev_ok, "--aobpatch", fake],
                       capture_output=True, text=True)
    doc = json.loads(r.stdout)
    if r.returncode == 1 and doc.get("verify_failed"):
        ok("⑥ 副本校验失败 → rc=1 且列 patch")
    else:
        bad("⑥ 校验失败用例不符: rc=%s %s" % (r.returncode, doc))

    print("== patch-reanchor 测试: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())