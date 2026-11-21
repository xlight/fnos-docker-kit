#!/usr/bin/env python3
# ============================================================================
# lib-consumers-check-test.py —— 消费者清单运行期核对的回归（**无破坏性**）
#
# 覆盖：
#   ① cgroup v2 解析（`0::/system.slice/<unit>`，无结尾斜杠）
#   ② cgroup v1 解析（多行，取含 .service 的那段）
#   ③ 完整性：linked − 清单 → missing
#   ④ 生效性：inode 一致 → 不 stale；inode 变化 / `(deleted)` → stale
#   ⑤ 清单缺失 → list_missing
#   ⑥ 非映射进程不计数（maps 里没有库）
#
# 做法：FNOS_PROC_ROOT 指向临时假 proc 树，FNOS_PATCHES_DIR 指向临时补丁集。
# 用法: python3 toolchain/tests/lib-consumers-check-test.py
# 退出: 0 全过 / 1 有失败
# ============================================================================
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(os.path.dirname(HERE), "fnos-lib-consumers-check")
PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("PASS: %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: %s" % msg)


def run(proc_root, patches, list_path):
    env = dict(os.environ)
    env["FNOS_PROC_ROOT"] = proc_root
    env["FNOS_PATCHES_DIR"] = patches
    env["FNOS_CONSUMERS_LIST"] = list_path
    env["FNOS_VERSION_PATH"] = os.path.join(os.path.dirname(patches), "version")
    r = subprocess.run([sys.executable, CHECK, "--json", "--no-active"],
                       capture_output=True, text=True, env=env)
    try:
        return r.returncode, json.loads(r.stdout)
    except ValueError:
        return r.returncode, {"_raw": r.stdout, "_err": r.stderr}


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def main():
    if not os.path.exists(CHECK):
        print("缺少被测脚本: %s" % CHECK)
        return 2
    tmp = tempfile.mkdtemp(prefix="fnos-lcc-test.")
    proc = os.path.join(tmp, "proc")
    patches = os.path.join(tmp, "patches")
    os.makedirs(patches)
    write(os.path.join(tmp, "version"), "1.2.1011\n")
    write(os.path.join(patches, "fnos-1.2.1011.json"),
          json.dumps({"fnos_version": "1.2.1011", "patches": [
              {"id": "p1", "file": "usr/trim/lib/libnperm.so", "match": "a", "replace": "b"}]}))

    # 真实文件，拿它的 inode 写进假 maps
    lib = os.path.join(tmp, "libnperm.so")
    write(lib, "new-content")
    ino = os.stat(lib).st_ino

    def mkproc(pid, cgroup, maps_lines):
        d = os.path.join(proc, str(pid))
        os.makedirs(d, exist_ok=True)
        write(os.path.join(d, "cgroup"), cgroup)
        write(os.path.join(d, "maps"), maps_lines)

    # ① cgroup v2
    mkproc("100", "0::/system.slice/foo.service\n",
           "7f0000-7f0000 rw-p 00000000 08:01 %d %s\n" % (ino, lib))
    # ② cgroup v1（多行）
    mkproc("101", "12:devices:/system.slice/bar.service\n11:cpu:/user.slice\n",
           "7f0000-7f0000 rw-p 00000000 08:01 %d %s\n" % (ino, lib))
    # ⑥ 不映射库的进程
    mkproc("102", "0::/system.slice/baz.service\n",
           "7f0000-7f0000 rw-p 00000000 08:01 1 /etc/hostname\n")
    # ④ stale：`(deleted)`
    mkproc("103", "0::/system.slice/qux.service\n",
           "7f0000 7f0000 rw-p 00000000 08:01 %d %s (deleted)\n" % (ino, lib))
    # ④ stale：inode 不一致
    mkproc("104", "0::/system.slice/quux.service\n",
           "7f0000-7f0000 rw-p 00000000 08:01 999999 %s\n" % lib)

    lst = os.path.join(tmp, "consumers.txt")
    write(lst, "foo.service\nbar.service\nquux.service\nqux.service\n")

    rc, doc = run(proc, patches, lst)
    if doc.get("linked") == ["bar.service", "foo.service", "quux.service", "qux.service"]:
        ok("①② cgroup v1/v2 解析正确")
    else:
        bad("①② linked=%s" % doc.get("linked"))
    if doc.get("missing") == []:
        ok("③ 清单覆盖 linked → missing 为空")
    else:
        bad("③ missing=%s" % doc.get("missing"))
    stale_units = sorted({x["unit"] for x in doc.get("stale", [])})
    if stale_units == ["quux.service", "qux.service"]:
        ok("④ inode 变化 / (deleted) → stale")
    else:
        bad("④ stale units=%s" % stale_units)
    if doc.get("ok") is False and rc == 1:
        ok("④ 有 stale → ok=false / rc=1")
    else:
        bad("④ ok=%s rc=%s" % (doc.get("ok"), rc))
    if "baz.service" not in doc.get("linked", []):
        ok("⑥ 不映射库的进程不计数")
    else:
        bad("⑥ baz.service 被误计")

    # ⑤ 清单缺失
    rc, doc = run(proc, patches, os.path.join(tmp, "nope.txt"))
    if doc.get("list_missing") is True:
        ok("⑤ 清单缺失 → list_missing=true")
    else:
        bad("⑤ list_missing=%s" % doc.get("list_missing"))

    # ③ 差集非空
    write(lst, "foo.service\n")
    rc, doc = run(proc, patches, lst)
    if "bar.service" in doc.get("missing", []) and "qux.service" in doc.get("missing", []):
        ok("③b 清单漏项被点名")
    else:
        bad("③b missing=%s" % doc.get("missing"))

    print("== lib-consumers-check 测试: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())