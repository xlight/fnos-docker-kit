#!/usr/bin/env python3
"""fnos_rootfs.py —— 目标版本根文件系统的**统一构造工具**（design D15）。

为什么要有这个工具：此前"造出厂 rootfs"有两套实现——CI 的 public-ci.yml 里
一段 shell（deb-head），人工 rebase 时又是另一套手工步骤。两条路各自演进 →
锚点不一致 → CI 判 ready 而真容器 no-match（2026-11-09 的 liveupdate 事故）。
本工具让人工与 CI **调用同一段代码、同一份包清单**。

两个来源：
  iso       官方 ISO（**强证据**：真出厂件）。需要 root 与 ~25G 磁盘。
  deb-head  底座镜像 + **全量** OTA 包 overlay（中证据：≈真容器，需交叉核对）。

用法：
  python3 fnos_rootfs.py iso --version 1.2.1000 --out /tmp/factory
  python3 fnos_rootfs.py deb-head --version 1.2.1010 --base 1.2.1000 --out /tmp/factory
  python3 fnos_rootfs.py report --rootfs /tmp/factory --version 1.2.1010
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DOCKERHUB_REPO = os.environ.get("DOCKERHUB_REPO", "xlight/fnos-dockermode")
ISO_MIN_FREE_GB = 25


def log(msg):
    print("[fnos-rootfs] %s" % msg, file=sys.stderr, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def need_root():
    if os.geteuid() != 0:
        log("需要 root（解包/写入 rootfs）")
        sys.exit(2)


def free_gb(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / (1 << 30)


# --------------------------------------------------------------------------
# ISO 路径（强证据）
# --------------------------------------------------------------------------
def build_iso(version, out, iso_path=None, keep_iso=False):
    need_root()
    iso = iso_path
    tmp_iso = None
    if not iso:
        # 官方签名 URL（裸 URL 403）——用公开的检测器取
        r = run([sys.executable, os.path.join(HERE, "check-iso-update.py"), "--signed"])
        if r.returncode != 0:
            log("取 ISO 签名 URL 失败: %s" % (r.stderr or r.stdout)[:200])
            return 3
        info = json.loads(r.stdout)
        cur = (info.get("current") or {})
        if cur.get("version") != version:
            log("官网当前 ISO 是 %s（要 %s）→ 本路径不可用" % (cur.get("version"), version))
            return 3
        url = info.get("signed_url")
        if not url:
            log("没有签名 URL（官网直链被拦）")
            return 3
        tmp_iso = tempfile.NamedTemporaryFile(prefix="fnos-%s-" % version, suffix=".iso", delete=False)
        tmp_iso.close()
        log("下载官方 ISO %s → %s" % (version, tmp_iso.name))
        c = run(["curl", "-fL", "--retry", "3", "-o", tmp_iso.name, url], timeout=3600)
        if c.returncode != 0:
            log("ISO 下载失败: %s" % (c.stderr or "")[:200])
            return 3
        iso = tmp_iso.name
        want = cur.get("hash") or ""
        if want:
            got = hashlib.md5(open(iso, "rb").read()).hexdigest()
            if len(want) == 32 and got != want:
                log("ISO md5 不符: want=%s got=%s" % (want, got))
                return 3
    need = free_gb("/")
    if need < ISO_MIN_FREE_GB:
        log("可用磁盘不足（%.1fG < %dG）" % (need, ISO_MIN_FREE_GB))
        return 3
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out, exist_ok=True)
    log("解包出厂 rootfs → %s" % out)
    r = run([sys.executable, os.path.join(HERE, "fnos_iso.py"), "extract", iso, out], timeout=7200)
    if r.returncode != 0:
        log("fnos_iso.py extract 失败: %s" % ((r.stderr or r.stdout) or "")[:300])
        return 3
    if tmp_iso and not keep_iso:
        try:
            os.unlink(tmp_iso.name)
        except OSError:
            pass
    return 0


# --------------------------------------------------------------------------
# deb-head 路径（中证据）
# --------------------------------------------------------------------------
def build_deb_head(version, base, out, debs_dir=None, pull=True):
    need_root()
    if not base:
        log("没有底座镜像（Hub 上无更低的版本 tag）→ 本路径不可用")
        return 3
    image = "%s:%s" % (DOCKERHUB_REPO, base)
    if pull:
        log("拉取底座镜像 %s" % image)
        p = run(["docker", "pull", image], timeout=3600)
        if p.returncode != 0:
            log("底座镜像拉取失败: %s" % (p.stderr or "")[:200])
            return 3
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out, exist_ok=True)
    cid = run(["docker", "create", image]).stdout.strip()
    if not cid:
        log("docker create 失败")
        return 3
    try:
        log("导出底座 rootfs → %s" % out)
        p = subprocess.run("docker export %s | tar -x -C %s" % (cid, out),
                           shell=True, capture_output=True, text=True)
        if p.returncode != 0:
            log("导出失败: %s" % (p.stderr or "")[:200])
            return 3
    finally:
        run(["docker", "rm", cid])
    # 运行时残留清干净（与 CI 的 deb 分支一致）
    for rel in ("etc/machine-id", "etc/hostname", ".dockerenv"):
        try:
            os.unlink(os.path.join(out, rel))
        except OSError:
            pass
    for rel in ("var/log", "tmp", "run"):
        d = os.path.join(out, rel)
        if os.path.isdir(d):
            for name in os.listdir(d):
                p2 = os.path.join(d, name)
                shutil.rmtree(p2, ignore_errors=True) if os.path.isdir(p2) else _unlink(p2)
    # 全量 OTA 包 overlay（**含顶层 liveupdate/kernel**——缺了就会造出不同构的环境）
    debs = debs_dir or os.path.join(out, ".ota-debs")
    if not os.path.isdir(debs) or not [f for f in os.listdir(debs) if f.endswith(".deb")]:
        # 没给包目录就现取（人工与 CI 走同一条路：同一份清单、同一套完整性门）
        log("现取 OTA 包组 → %s" % debs)
        d = run([sys.executable, os.path.join(HERE, "fetch-ota-debs.py"),
                 "--version", version, "--out", debs], timeout=3600)
        if d.returncode != 0:
            log("OTA 包组获取失败（rc=%d，可能缺基材或清单不完整）: %s"
                % (d.returncode, (d.stderr or d.stdout or "")[-200:]))
            return 3
    deb_files = sorted(f for f in os.listdir(debs) if f.endswith(".deb"))
    if not deb_files:
        log("OTA 包目录里没有 .deb")
        return 3
    for f in deb_files:
        src = os.path.join(debs, f)
        log("overlay: %s" % f)
        p = subprocess.run("dpkg-deb --fsys-tarfile '%s' | tar -x --keep-directory-symlink -C '%s'"
                           % (src, out), shell=True, capture_output=True, text=True)
        if p.returncode != 0:
            log("overlay 失败 %s: %s" % (f, (p.stderr or "")[:200]))
            return 3
    # 版本戳（.deb 不含；补丁集版本锚必需）
    vpath = os.path.join(out, "usr/trim/etc/version")
    os.makedirs(os.path.dirname(vpath), exist_ok=True)
    with open(vpath, "w") as f:
        f.write(version + "\n")
    return 0


def _unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


# --------------------------------------------------------------------------
def report(rootfs, version=None):
    """rootfs 关键文件哈希（证据里的 environment 段）。"""
    out = {}
    for rel in ("usr/trim/bin/liveupdate", "usr/trim/bin/resmon_service",
                "usr/trim/bin/trim_app_center", "usr/trim/bin/filemanager",
                "usr/trim/bin/network_service", "usr/trim/lib/libnfile.so",
                "usr/trim/lib/libnperm.so", "usr/trim/lib/libtrimacl.so"):
        p = os.path.join(rootfs, rel)
        if os.path.isfile(p):
            out[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    data = {"rootfs": rootfs, "version": version, "files": out}
    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("iso")
    i.add_argument("--version", required=True)
    i.add_argument("--out", required=True)
    i.add_argument("--iso", default="")
    b = sub.add_parser("deb-head")
    b.add_argument("--version", required=True)
    b.add_argument("--base", default="")
    b.add_argument("--out", required=True)
    b.add_argument("--debs", default="")
    r = sub.add_parser("report")
    r.add_argument("--rootfs", required=True)
    r.add_argument("--version", default="")
    a = ap.parse_args()
    if a.cmd == "iso":
        return build_iso(a.version, a.out, a.iso or None)
    if a.cmd == "deb-head":
        return build_deb_head(a.version, a.base, a.out, a.debs or None)
    return report(a.rootfs, a.version)


if __name__ == "__main__":
    sys.exit(main())
