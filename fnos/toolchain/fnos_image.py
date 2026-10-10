#!/usr/bin/env python3
# ============================================================================
# fnos_image.py — 由出厂 rootfs 生成 LXC 镜像（多后端）并自检
#
# 支持的 rootfs 后端（PVE 原生）：
#   ext4   :  raw 镜像（loop 可挂；dir 存储）
#   btrfs  :  raw 镜像（btrfs；btrfs 存储 / 子卷）
#   zfs    :  ZFS 数据集（zfspool 存储；快照/压缩/复制）
#   vztmpl :  tar.gz（PVE 模板）
#
# 用法（需 root）：
#   fnos_image.py mkraw   <rootfs> <out.raw> [size_GiB=12] [--fs ext4|btrfs]
#   fnos_image.py mkvztmpl <rootfs> <out.tar.gz>
#   fnos_image.py mkzfs   <rootfs> <pool>/<dataset>
#   fnos_image.py check   <image>            # 自检（raw ext4/btrfs 或 tar.gz）
# ============================================================================
import json
import os
import subprocess
import sys
import tarfile
import tempfile

KEY_FILES = ["usr/trim/bin/trim", "usr/trim/lib/libtrimacl.so", "etc/os-release"]


def _run(cmd, check=True):
    p = subprocess.run(cmd)
    if check and p.returncode != 0:
        raise RuntimeError("命令失败(%d): %s" % (p.returncode, " ".join(cmd)))
    return p.returncode


def _out(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def _is_tar(path):
    if not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return f.read(2) == b"\x1f\x8b"


def _populate(rootfs, mnt):
    _run(["rsync", "-aHAX", "--numeric-ids", rootfs.rstrip("/") + "/", mnt + "/"])


def mkraw(rootfs, out, size_gib=12, fs="ext4"):
    size = int(size_gib) * 1024 * 1024 * 1024
    with open(out, "wb") as f:
        f.truncate(size)
    if fs == "ext4":
        _run(["mkfs.ext4", "-F", "-L", "fnosvol", out])
    elif fs == "btrfs":
        _run(["mkfs.btrfs", "-f", "-L", "fnosvol", out])
    else:
        raise ValueError("mkraw 只支持 ext4|btrfs")
    mnt = tempfile.mkdtemp(prefix="fnos-img-")
    try:
        _run(["mount", "-o", "loop", out, mnt])
        _populate(rootfs, mnt)
    finally:
        _run(["umount", mnt], check=False)
        os.rmdir(mnt)
    return {"image": out, "size": size, "kind": "raw", "fs": fs}


def mkvztmpl(rootfs, out):
    _run(["tar", "--numeric-owner", "-czf", out, "-C", rootfs, "."])
    return {"image": out, "kind": "vztmpl"}


def mkzfs(rootfs, dataset):
    """在 zpool 上建数据集并把 rootfs 灌进去（PVE zfspool 可直接用）。"""
    _run(["zfs", "create", "-p", dataset], check=False)  # 已存在则忽略
    mp = _out(["zfs", "get", "-H", "-o", "value", "mountpoint", dataset])
    if not mp or mp == "none":
        _run(["zfs", "set", "mountpoint=/mnt/%s" % dataset.replace("/", "_"), dataset])
        mp = _out(["zfs", "get", "-H", "-o", "value", "mountpoint", dataset])
    _populate(rootfs, mp)
    return {"image": dataset, "kind": "zfs", "mountpoint": mp}


def _fsck(image, fstype):
    if fstype == "ext4":
        p = subprocess.run(["e2fsck", "-fn", image], capture_output=True, text=True)
    elif fstype == "btrfs":
        p = subprocess.run(["btrfs", "check", "--readonly", image], capture_output=True, text=True)
    else:
        return {"ok": None, "detail": "unsupported fs %s" % fstype}
    # e2fsck: 0=clean, 1=errors-fixed(non-fatal for -n it's 4), 4=errors-left
    clean = p.returncode in (0,)
    return {"ok": clean, "rc": p.returncode,
            "detail": (p.stdout + p.stderr).strip().splitlines()[-1:] and
                      (p.stdout + p.stderr).strip().splitlines()[-1] or ""}


def _patch_check(mnt, patchset):
    p = subprocess.run([sys.executable,
                        os.path.join(os.path.dirname(os.path.abspath(__file__)), "aobpatch.py"),
                        "check", "--rootfs", mnt, "--patchset", patchset],
                       capture_output=True, text=True)
    try:
        rp = json.loads(p.stdout)
        return {"ok": rp.get("ok"), "total": len(rp.get("patches", [])),
                "not_in_place": [q["id"] for q in rp.get("patches", [])
                                 if q.get("status") not in ("already", "ready")]}
    except Exception:
        return {"ok": False, "detail": p.stdout[-300:] + p.stderr[-300:]}


def check(image, patchset=None):
    if _is_tar(image):
        with tarfile.open(image, "r:*") as t:
            names = set(n.lstrip("./") for n in t.getnames())
        missing = [k for k in KEY_FILES if k not in names]
        boot = next((n for n in names if n.startswith("boot/vmlinuz-")), "")
        res = {"kind": "vztmpl", "entries": len(names), "missing_key_files": missing, "kernel": boot}
        res["ok"] = bool(not missing and boot)
        return res
    # ZFS 数据集？（PVE zfspool rootfs 形态）
    z = subprocess.run(["zfs", "list", "-H", "-o", "name", image],
                       capture_output=True, text=True)
    if z.returncode == 0 and z.stdout.strip() == image:
        mp = _out(["zfs", "get", "-H", "-o", "value", "mountpoint", image])
        missing = [k for k in KEY_FILES if not os.path.exists(os.path.join(mp, k))]
        boot = _out(["sh", "-c", "ls %s/boot/vmlinuz-* 2>/dev/null | head -1" % mp])
        patches = _patch_check(mp, patchset) if patchset else None
        res = {"kind": "zfs", "dataset": image, "mountpoint": mp,
               "missing_key_files": missing, "kernel": boot, "patches": patches}
        res["ok"] = bool(not missing and boot and (patches is None or patches.get("ok")))
        return res
    fstype = _out(["blkid", "-o", "value", "-s", "TYPE", image])
    fsck = _fsck(image, fstype)
    mnt = tempfile.mkdtemp(prefix="fnos-chk-")
    missing = []; boot = ""; patches = None
    try:
        _run(["mount", "-o", "loop,ro", image, mnt])
        missing = [k for k in KEY_FILES if not os.path.exists(os.path.join(mnt, k))]
        boot = _out(["sh", "-c", "ls %s/boot/vmlinuz-* 2>/dev/null | head -1" % mnt])
        if patchset:
            patches = _patch_check(mnt, patchset)
    finally:
        _run(["umount", mnt], check=False)
        os.rmdir(mnt)
    res = {"kind": "raw", "fs": fstype or "?", "missing_key_files": missing, "kernel": boot,
           "fsck": fsck, "patches": patches}
    res["ok"] = bool(not missing and boot and fsck.get("ok")
                     and (patches is None or patches.get("ok")))
    return res


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    if os.geteuid() != 0:
        print("错误：需要 root。请用 sudo 运行。", file=sys.stderr); sys.exit(1)
    args = [a for a in sys.argv[3:] if not a.startswith("--")]
    opts = dict(a.split("=", 1) if "=" in a else (a, True) for a in sys.argv[3:] if a.startswith("--"))
    if cmd == "mkraw":
        if len(sys.argv) < 4:
            print("用法: fnos_image.py mkraw <rootfs> <out.raw> [size_GiB] [--fs ext4|btrfs]"); sys.exit(2)
        size = args[1] if len(args) > 1 else 12
        print(mkraw(sys.argv[2], args[0], size, opts.get("--fs", "ext4") or "ext4"))
    elif cmd == "mkvztmpl":
        print(mkvztmpl(sys.argv[2], args[0]))
    elif cmd == "mkzfs":
        print(mkzfs(sys.argv[2], args[0]))
    elif cmd == "check":
        r = check(sys.argv[2], opts.get("--patchset"))
        print(json.dumps(r, ensure_ascii=False, indent=2))
        sys.exit(0 if r["ok"] else 1)
    else:
        print(__doc__); sys.exit(2)


if __name__ == "__main__":
    main()
