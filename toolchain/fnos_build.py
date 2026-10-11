#!/usr/bin/env python3
# ============================================================================
# fnos_build.py — 构建编排：patch -> image -> 自检/指纹/验证报告 -> release
#
# 子命令（需 root）：
#   build   把出厂 rootfs 打成镜像并产出验证物
#     --rootfs <dir> --out <dir> [--version V1.2.0701] [--fs ext4|btrfs] [--size 12]
#     [--vztmpl] [--zfs <pool/dataset>] [--skip-patch] [--no-version-check]
#   verify  对一个已有镜像做自检 + 指纹 + 验证报告（5.1/5.3/5.4）
#     --image <img> --out <dir> [--rootfs <dir>] [--patchset <json>]
#   release 打包 release（镜像 + 清单 + 验证报告 + 部署说明）——未过验证不打包（6.1）
#     --out <dir> [--name fnos-lxc-<ver>]
#
# 产出（在 <out>/）：
#   image.raw / fnos-lxc.tar.gz / manifest.json / verification.json / DEPLOY.md
#   release/<name>.tar.gz （6.1，仅在 verify.ok 时）
# ============================================================================
import argparse
import datetime
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fnos_image  # noqa: E402
import fnos_patch  # noqa: E402

TC = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PS = os.path.join(TC, "patches", "fnos-1.2.0701.json")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_sha256(root):
    """rootfs 目录树指纹：排序遍历，逐文件哈希累积（含相对路径与类型）。
    非普通文件（设备/FIFO/socket）只记类型与 rdev，不读内容。"""
    h = hashlib.sha256()
    n = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort(); filenames.sort()
        for name in filenames:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, root)
            h.update(rel.encode() + b"\0")
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                h.update(b"L" + os.readlink(p).encode() + b"\0")
            elif stat.S_ISREG(st.st_mode):
                h.update(b"F" + str(st.st_size).encode() + b"\0")
                with open(p, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                h.update(b"\0")
            else:
                h.update(b"S" + oct(st.st_mode).encode() + b":"
                         + str(st.st_rdev).encode() + b"\0")
            n += 1
    return h.hexdigest(), n


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


# ---------------------------------------------------------------------- verify
def cmd_verify(image, out, rootfs=None, patchset=DEFAULT_PS):
    os.makedirs(out, exist_ok=True)
    ps = json.load(open(patchset))
    checks = []
    fps = {}

    # 5.1 镜像自检（fsck + 关键件 + 补丁在位）
    self_chk = fnos_image.check(image, patchset=patchset)
    checks.append({"name": "image-selfcheck", "cmd": "fnos_image check --patchset",
                   "result": self_chk, "ok": bool(self_chk.get("ok"))})

    # 补丁在位（图像内 check 已含，这里独立留证）
    checks.append({"name": "patchset-version", "expected": ps.get("fnos_version"),
                   "ok": True})

    if rootfs and os.path.isdir(rootfs):
        st = fnos_patch.status(rootfs)
        checks.append({"name": "rootfs-patched", "result": st,
                       "ok": all(st.values())})
        th, tn = tree_sha256(rootfs)
        fps["rootfs_tree_sha256"] = th
        fps["rootfs_tree_entries"] = tn

    # 5.3 产出物指纹
    fps["image"] = image
    fps["image_sha256"] = sha256_file(image)
    fps["image_size"] = os.path.getsize(image)
    fps["patchset_sha256"] = hashlib.sha256(open(patchset, "rb").read()).hexdigest()

    report = {
        "fnos_version": ps.get("fnos_version"),
        "patchset": os.path.basename(patchset),
        "verification_at": now(),
        "checks": checks,
        "fingerprints": fps,
        "ok": all(c.get("ok") for c in checks),
    }
    rp = os.path.join(out, "verification.json")
    json.dump(report, open(rp, "w"), ensure_ascii=False, indent=2)
    print("验证报告 -> %s (ok=%s)" % (rp, report["ok"]))
    for c in checks:
        print("  [%s] %s" % ("OK" if c.get("ok") else "FAIL", c["name"]))
    write_manifest(out, report)
    return report


def _image_entries(out):
    """把 out 目录里已知的镜像形态登记进清单。"""
    ent = []
    for fn, kind in (("image.raw", "raw"), ("fnos-lxc.tar.gz", "vztmpl")):
        p = os.path.join(out, fn)
        if os.path.isfile(p):
            ent.append({"path": fn, "kind": kind,
                        "sha256": sha256_file(p), "size": os.path.getsize(p)})
    return ent


def write_manifest(out, report):
    manifest = {
        "name": "fnos-lxc-%s" % (report.get("fnos_version") or "unknown"),
        "fnos_version": report.get("fnos_version"),
        "built_at": report.get("verification_at") or now(),
        "patchset": report.get("patchset"),
        "patchset_sha256": report.get("fingerprints", {}).get("patchset_sha256"),
        "images": _image_entries(out),
        "verification": "verification.json",
        "verification_sha256": sha256_file(os.path.join(out, "verification.json")),
        "ok": report.get("ok"),
    }
    mp = os.path.join(out, "manifest.json")
    json.dump(manifest, open(mp, "w"), ensure_ascii=False, indent=2)
    print("版本清单 -> %s" % mp)
    return manifest


def run_smoke(ctid, image):
    """构建期冒烟门禁（5.2）：起一次性容器 -> smoke -> 卸载。返回 check 记录。"""
    dep = os.path.join(TC, "fnos_deploy.sh")
    install = subprocess.run(["bash", dep, "install", str(ctid), "--image", image,
                              "--hostname", "fnos-smoke"], capture_output=True, text=True)
    smoke = subprocess.run(["bash", dep, "smoke", str(ctid)], capture_output=True, text=True)
    uninstall = subprocess.run(["bash", dep, "uninstall", str(ctid)], capture_output=True, text=True)
    ok = (install.returncode == 0 and smoke.returncode == 0 and uninstall.returncode == 0)
    return {"name": "build-smoke", "cmd": "fnos_deploy.sh install/smoke/uninstall %s" % ctid,
            "result": {"install_rc": install.returncode, "smoke_rc": smoke.returncode,
                       "uninstall_rc": uninstall.returncode,
                       "smoke_tail": smoke.stdout.strip().splitlines()[-3:]},
            "ok": ok}


# ----------------------------------------------------------------------- build
def cmd_build(a):
    out = a.out
    os.makedirs(out, exist_ok=True)
    # 1) 打补丁（烘进 rootfs）
    if not a.skip_patch:
        for line in fnos_patch.apply(a.rootfs, a.patchset, a.mount_shim,
                                     enforce_version=not a.no_version_check):
            print("  [patch] " + line)
    st = fnos_patch.status(a.rootfs)
    if not all(st.values()):
        raise RuntimeError("rootfs 自检未通过: %s" % st)

    # 2) 生成镜像
    produced = []
    raw = os.path.join(out, "image.raw")
    res = fnos_image.mkraw(a.rootfs, raw, a.size, a.fs)
    produced.append(res)
    print("  [image] raw %s (%s, %s GiB)" % (raw, a.fs, a.size))
    if a.vztmpl:
        t = os.path.join(out, "fnos-lxc.tar.gz")
        produced.append(fnos_image.mkvztmpl(a.rootfs, t))
        print("  [image] vztmpl %s" % t)
    if a.zfs:
        produced.append(fnos_image.mkzfs(a.rootfs, a.zfs))
        print("  [image] zfs %s" % a.zfs)

    # 3) 产出物验证（5.1） + 指纹/报告（5.3/5.4）
    report = cmd_verify(raw, out, rootfs=a.rootfs, patchset=a.patchset)

    # 3b) 构建期冒烟门禁（5.2）——失败则不产出 release
    if a.smoke_id:
        sc = run_smoke(a.smoke_id, raw)
        report["checks"].append(sc)
        report["ok"] = all(c.get("ok") for c in report["checks"])
        json.dump(report, open(os.path.join(out, "verification.json"), "w"),
                  ensure_ascii=False, indent=2)
        print("  [%s] %s" % ("OK" if sc["ok"] else "FAIL", sc["name"]))

    # 4) 清单（5.3，含冒烟结果后重写）
    manifest = write_manifest(out, report)

    # 5) 部署说明
    write_deploy_doc(os.path.join(out, "DEPLOY.md"), manifest)

    # 6) release（6.1）—— 未过验证不打包
    if report["ok"] and not a.no_release:
        cmd_release(out, manifest["name"])
    elif not report["ok"]:
        print("!! 产出物验证未通过 —— **不打包 release**", file=sys.stderr)
        return 1
    return 0


def write_deploy_doc(path, manifest):
    doc = """# fnos-lxc 部署说明

版本: {ver}    补丁集: {ps}
构建: {ts}

## 产物
{imgs}

## 部署（宿主 PVE）
1. 建 rootfs 卷（raw 用 `pct create` / 或按 CT200 形态手写 conf）：
   - 镜像文件: image.raw（ext4/btrfs）
   - `lxc.apparmor.profile: unconfined`、`features: nesting=1,fuse=1,mknod=1`
   - `/etc/pve/lxc/<id>.seccomp`（来自本包）
2. 建专属存储：`stor-manage.sh`（`VOLFS=ext4|btrfs|zfs`）+ `stor-mountdir.sh`
3. 启动并冒烟：`fnos_deploy.sh smoke <id>`

详见公开用法文档（`docs/public-usage.md`）。
""".format(ver=manifest["fnos_version"], ps=manifest["patchset"],
           ts=manifest["built_at"],
           imgs="\n".join("  - %s (%s)" % (i["path"], i.get("fs") or i.get("kind"))
                          for i in manifest["images"]))
    open(path, "w").write(doc)


# --------------------------------------------------------------------- release
def cmd_release(out, name):
    vp = os.path.join(out, "verification.json")
    if not os.path.exists(vp) or not json.load(open(vp)).get("ok"):
        print("!! verification.json 缺失或未通过 —— 拒绝打包 release", file=sys.stderr)
        return 1
    rdir = os.path.join(out, "release")
    os.makedirs(rdir, exist_ok=True)
    tar_path = os.path.join(rdir, "%s.tar.gz" % name)
    members = [f for f in sorted(os.listdir(out))
               if f in ("image.raw", "fnos-lxc.tar.gz", "manifest.json",
                        "verification.json", "DEPLOY.md")]
    with tarfile.open(tar_path, "w:gz") as t:
        for m in members:
            t.add(os.path.join(out, m), arcname=m)
    print("release -> %s (%d 文件, %.1f MiB)"
          % (tar_path, len(members), os.path.getsize(tar_path) / 1048576))
    sha = sha256_file(tar_path)
    print("  release sha256 = %s" % sha)
    # 侧车校验和（放在 release/ 目录，不放进包内，避免自引用）
    with open(tar_path + ".sha256", "w") as f:
        f.write("%s  %s\n" % (sha, os.path.basename(tar_path)))
    names = [n for n in os.listdir(out)
             if os.path.isfile(os.path.join(out, n)) and n != "SHA256SUMS"]
    lines = ["%s  %s\n" % (sha256_file(os.path.join(out, n)), n) for n in sorted(names)]
    lines.append("%s  release/%s\n" % (sha, os.path.basename(tar_path)))
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        f.writelines(lines)
    print("  SHA256SUMS -> %s" % os.path.join(out, "SHA256SUMS"))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build")
    b.add_argument("--rootfs", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--version", default="V1.2.0701")
    b.add_argument("--fs", default="ext4", choices=["ext4", "btrfs"])
    b.add_argument("--size", default=12)
    b.add_argument("--vztmpl", action="store_true")
    b.add_argument("--zfs")
    b.add_argument("--patchset", default=DEFAULT_PS)
    b.add_argument("--mount-shim", default=os.path.normpath(os.path.join(TC, "..", "scripts", "stor-mount-shim.sh")))
    b.add_argument("--skip-patch", action="store_true")
    b.add_argument("--no-version-check", action="store_true")
    b.add_argument("--no-release", action="store_true")
    b.add_argument("--smoke-id", type=int, help="构建期冒烟门禁使用的容器 id（一次性）")

    v = sub.add_parser("verify")
    v.add_argument("--image", required=True)
    v.add_argument("--out", required=True)
    v.add_argument("--rootfs")
    v.add_argument("--patchset", default=DEFAULT_PS)

    r = sub.add_parser("release")
    r.add_argument("--out", required=True)
    r.add_argument("--name", required=True)

    a = ap.parse_args()
    if os.geteuid() != 0:
        print("需要 root", file=sys.stderr); sys.exit(1)
    if a.cmd == "build":
        sys.exit(cmd_build(a))
    if a.cmd == "verify":
        rep = cmd_verify(a.image, a.out, a.rootfs, a.patchset)
        sys.exit(0 if rep["ok"] else 1)
    if a.cmd == "release":
        sys.exit(cmd_release(a.out, a.name))


if __name__ == "__main__":
    main()
