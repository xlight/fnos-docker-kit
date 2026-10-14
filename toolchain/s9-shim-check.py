#!/usr/bin/env python3
"""s9-shim-check.py — 容器内运行：验证上传文件夹/权限检查两处功能垫片在位。

版本无关：按容器内 /usr/trim/etc/version 选烘焙补丁集，跑烘焙 aobpatch check，
再按 (文件, find->to) 语义定位两个站点（不硬编码任何版本的文件偏移）：
  - libnfile.so 内 trim_access(mode=8->2)（上传文件夹模式位）
  - libnperm.so 内 lea->mov（传结构体改传真 path）
输出 PASS/FAIL 行 + 末行 ALL/SOME（供 fnos_deploy.sh smoke §9 解析）。
"""
import json
import subprocess
import sys

WANT = {
    ("usr/trim/lib/libnfile.so", "08", "02"),
    ("usr/trim/lib/libnperm.so", "8d", "8b"),
}


def main():
    ver = open("/usr/trim/etc/version").read().strip()
    ps_path = ("/usr/local/share/fnos-toolchain/patches/fnos-%s.json" % ver)
    rep_path = "/tmp/s9.json"
    r = subprocess.run(
        [sys.executable, "/usr/local/share/fnos-toolchain/aobpatch.py",
         "check", "--rootfs", "/", "--patchset", ps_path, "--report", rep_path],
        capture_output=True, text=True)
    if r.returncode != 0:
        print("FAIL check rc=%d %s" % (r.returncode, (r.stderr or "")[:160]))
        print("SOME")
        return 1
    rep = json.load(open(rep_path))
    ps = json.load(open(ps_path))
    info = {}
    for p in ps.get("patches", []):
        for x in p.get("replace", []):
            info[p["id"]] = (p.get("file"), x.get("find"), x.get("to"))
    stat = {p["id"]: p.get("status") for p in rep.get("patches", [])}
    got = {}
    for pid, k in info.items():
        if k in WANT:
            got[k] = stat.get(pid)
    ok = (len(got) == len(WANT)
          and all(got.get(k) in ("ready", "already") for k in WANT))
    for k in sorted(WANT):
        print(("PASS" if got.get(k) in ("ready", "already") else "FAIL"), k,
              got.get(k))
    print("ALL" if ok else "SOME")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
