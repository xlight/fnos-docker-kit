#!/usr/bin/env python3
# ============================================================================
# fnos_iso.py — 从 fnOS 安装 ISO 提取出厂 rootfs（不挂载 ISO）
#
# 原理：fnOS 安装 ISO 是 Debian netinst 变体，其载荷是根目录下的 /TRIMFS.TGZ
#       （gzip 的 rootfs 全量）。本工具读 ISO 目录项拿到该文件的 LBA 与大小，
#       用 dd 按偏移读取并解包 —— 不 mount、不 loop。
#
# 用法：
#   fnos_iso.py inspect <iso>              # 打印版本/大小/LBA（JSON）
#   fnos_iso.py extract <iso> <destdir>    # 解包出厂 rootfs 到 <destdir>
#   fnos_iso.py verify  <iso> <destdir>    # 校验已解包的 rootfs
#
# 依赖：isoinfo(genisoimage)、dd、tar、gzip（宿主通常已有）
# ============================================================================
import json
import os
import re
import subprocess
import sys

PAYLOAD = "TRIMFS.TGZ"
CONF_PATH = "/CONFIG/TRIMFS.CONF;1"


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def _isoinfo_bytes(iso, path):
    p = _run(["isoinfo", "-i", iso, "-x", path])
    return p.stdout


def _isoinfo_list(iso):
    p = _run(["isoinfo", "-l", "-i", iso])
    if p.returncode != 0:
        raise RuntimeError("isoinfo -l 失败: %s" % p.stderr.strip())
    return p.stdout


def inspect(iso):
    """返回 {version, tgz_size, lba, size, name}。"""
    conf = _isoinfo_bytes(iso, CONF_PATH)
    version = None
    conf_size = None
    for line in conf.splitlines():
        line = line.strip()
        if line.startswith("trimfs_version="):
            version = line.split("=", 1)[1].strip()
        elif line.startswith("trimfs_tgz_size="):
            conf_size = int(line.split("=", 1)[1].strip())

    lba = size = None
    for line in _isoinfo_list(iso).splitlines():
        if PAYLOAD in line:
            # 形如: ----------   0 0 0   3001808946 Sep 14 2026 [ 357285 00]  TRIMFS.TGZ;1
            m = re.search(r"\[\s*(\d+)\s+\d+\]\s+(\S+)", line)
            nums = re.findall(r"\d{6,}", line)
            if m and nums:
                lba = int(m.group(1))
                size = int(nums[0])
                break
    if lba is None or size is None:
        raise RuntimeError("在 ISO 中找不到载荷 %s" % PAYLOAD)
    if conf_size is not None and conf_size != size:
        raise RuntimeError("载荷大小与 %s 不符：iso=%d conf=%d" % (CONF_PATH, size, conf_size))
    return {"version": version, "tgz_size": conf_size, "lba": lba, "size": size, "name": PAYLOAD}


def extract(iso, dest):
    info = inspect(iso)
    os.makedirs(dest, exist_ok=True)
    bs = 2048
    count = (info["size"] + bs - 1) // bs  # 精确到块，避免读入 ISO 尾部填充
    dd = subprocess.Popen(["dd", "if=%s" % iso, "bs=%d" % bs, "skip=%d" % info["lba"],
                           "count=%d" % count, "status=none"],
                          stdout=subprocess.PIPE)
    tar = subprocess.Popen(["tar", "xzf", "-", "-C", dest], stdin=dd.stdout)
    dd.stdout.close()
    rc = tar.wait()
    dd.wait()
    if rc != 0:
        raise RuntimeError("tar 解包失败 rc=%d" % rc)
    return info


def verify(iso, dest):
    """校验解包完整性：条目数 == 载荷 tar 条目数；关键件存在。"""
    info = inspect(iso)
    bs = 2048
    count = (info["size"] + bs - 1) // bs
    # 载荷 tar 的条目数
    dd = subprocess.Popen(["dd", "if=%s" % iso, "bs=%d" % bs, "skip=%d" % info["lba"],
                           "count=%d" % count, "status=none"], stdout=subprocess.PIPE)
    tarl = subprocess.Popen(["tar", "tzf", "-"], stdin=dd.stdout, stdout=subprocess.PIPE, text=True)
    dd.stdout.close()
    n_payload = sum(1 for _ in tarl.stdout)
    tarl.wait()
    dd.wait()

    n_dest = int(_run(["sh", "-c", "find %s | wc -l" % json.dumps(dest)]).stdout.strip())
    keys = ["usr/trim/bin/trim", "usr/trim/lib/libtrimacl.so", "etc/os-release"]
    missing = [k for k in keys if not os.path.exists(os.path.join(dest, k))]
    boot = _run(["sh", "-c", "ls %s/boot/vmlinuz-* 2>/dev/null | head -1" % json.dumps(dest)]).stdout.strip()
    ok = (n_dest >= n_payload and not missing and boot)
    return {"payload_entries": n_payload, "dest_entries": n_dest,
            "missing_key_files": missing, "kernel": boot, "ok": bool(ok)}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    cmd, iso = sys.argv[1], sys.argv[2]
    if cmd in ("extract", "verify") and os.geteuid() != 0:
        print("错误：extract/verify 需要 root（rootfs 内多为 root 属主，且会写目标）。请用 sudo 运行。",
              file=sys.stderr)
        sys.exit(1)
    if cmd == "inspect":
        print(json.dumps(inspect(iso), ensure_ascii=False, indent=2))
    elif cmd == "extract":
        if len(sys.argv) < 4:
            print("用法: fnos_iso.py extract <iso> <destdir>"); sys.exit(2)
        info = extract(iso, sys.argv[3])
        print(json.dumps(info, ensure_ascii=False))
    elif cmd == "verify":
        if len(sys.argv) < 4:
            print("用法: fnos_iso.py verify <iso> <destdir>"); sys.exit(2)
        r = verify(iso, sys.argv[3])
        print(json.dumps(r, ensure_ascii=False, indent=2))
        sys.exit(0 if r["ok"] else 1)
    else:
        print(__doc__); sys.exit(2)


if __name__ == "__main__":
    main()
