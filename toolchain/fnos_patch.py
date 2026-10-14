#!/usr/bin/env python3
# ============================================================================
# fnos_patch.py — 把一个出厂 rootfs 打成"可运行的 fnOS LXC rootfs"
#
# 五件事（全部幂等）：
#   1) /etc/fstab 改写（去 install-UUID root、/boot/efi、trimafs /fs）
#   2) 镜像内 mount 垫片 /usr/local/sbin/mount（剥 trimacl）
#   3) AOB 特征补丁（usr/trim 下目标二进制）
#   4) 容器侧启动服务烘焙并 enable：
#        /usr/local/share/fnos-toolchain/{aobpatch.py,patches/*.json}
#        /usr/local/sbin/fnos-dirfd-shim.py   （开机幂等重放：aob 相 / text 相）
#        /etc/systemd/system/fnos-dirfd-shim.service   （二进制补丁，trim 前）
#        /etc/systemd/system/fnos-aob-www.service      （文本-www 补丁，www 就绪后）
#        /etc/systemd/system/fnos-mountdir.service
#        /etc/systemd/system/fnos-disk-io-monitor.service
#            （磁盘 I/O 刷新 opt-in：仅烘焙、**不 enable**；启用见 README）
#        /usr/local/lib/libfnos-trashshim.so + trim_main.service.d/trashshim.conf
#            （回收站用户态 wrapper：LD_PRELOAD 挂到 trim，其派生 filemanager 生效）
#   5) 屏蔽 nfs-server（见下方 MASK_UNITS 注释：宿主全局 nfsd 互踩防护）
#
# 用法（需 root）：
#   fnos_patch.py apply  --rootfs <dir> [--patches <json>] [--mount-shim <sh>]
#   fnos_patch.py status --rootfs <dir>
# ============================================================================
import argparse, glob, json, os, shutil, subprocess, sys

TOOLCHAIN_DIR = os.path.dirname(os.path.abspath(__file__))

FSTAB = "# /etc/fstab — fnos-lxc (managed by fnos_patch.py)\n# 去掉了 install-UUID root / /boot/efi / trimafs（容器里不需要也不支持）\n"

DIRFD_UNIT = """[Unit]
Description=fnOS magic-dirfd shim (native-kernel compatibility, baked)
DefaultDependencies=no
After=local-fs.target
Before=trim_init.service trim_main.service
ConditionPathExists=/usr/local/sbin/fnos-dirfd-shim.py

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fnos-dirfd-shim.py apply --only aob

[Install]
WantedBy=multi-user.target
"""

# 文本/www 补丁单独一相：/usr/trim/www 由 sysrestore 异步解压，须等它就绪再打，
# 否则文本补丁 missing-file 会让 aobpatch 预检"任一失败不写任何文件"短路整套自愈。
# Type=simple：后台轮询等待 www，不阻塞 multi-user.target（www 消费方不依赖此相——
# 构建期 mirror 已把补丁写进 .restore/www.zip，解压出的即为已补版）。
AOB_WWW_UNIT = """[Unit]
Description=fnOS AOB replay (text/www patches) after /usr/trim/www is ready
DefaultDependencies=no
After=local-fs.target sysrestore.service trim_main.service
Wants=sysrestore.service
ConditionPathExists=/usr/local/sbin/fnos-dirfd-shim.py

[Service]
Type=simple
ExecStart=/usr/local/sbin/fnos-dirfd-shim.py apply --only text

[Install]
WantedBy=multi-user.target
"""

# 磁盘 I/O 刷新补丁的 **opt-in 启动单元**：默认烘焙但**不 enable**（补丁默认不生效）。
# 在需要的容器里 `systemctl enable --now fnos-disk-io-monitor.service` 即可启用；
# 它直接调 aobpatch.py（不依赖 dirfd 垫片版本）以 `--include-disabled` 重放被标
# disabled 的 `resmon_service.disk-io-refresh#*`。排在 fnos-dirfd-shim.service 之后
# （避免与之并发写同一二进制），且仍在 trim 之前。{patchset} 由 apply() 填入。
DISKIO_UNIT = """[Unit]
Description=fnOS disk I/O monitor opt-in (applies disabled resmon disk-io patch)
DefaultDependencies=no
After=local-fs.target fnos-dirfd-shim.service
Before=trim_init.service trim_main.service
ConditionPathExists=/usr/local/share/fnos-toolchain/aobpatch.py

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/share/fnos-toolchain/aobpatch.py apply --rootfs / --patchset /usr/local/share/fnos-toolchain/patches/{patchset} --only aob --include-disabled

[Install]
WantedBy=multi-user.target
"""

MOUNTDIR_UNIT = """[Unit]
Description=fnOS mount-dir rebind (host dir -> volume subdir)
DefaultDependencies=no
After=local-fs.target
ConditionPathExists=/usr/local/sbin/fnos-mountdir-apply.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fnos-mountdir-apply.sh

[Install]
WantedBy=multi-user.target
"""

# ---- 回收站用户态 wrapper（LD_PRELOAD 到 trim_main；其 fork+execv 的 filemanager 继承）----
TRASH_SO = "usr/local/lib/libfnos-trashshim.so"
TRASH_ASSET = os.path.join(TOOLCHAIN_DIR, "assets", "libfnos-trashshim.so")
TRASH_DROPIN = "etc/systemd/system/trim_main.service.d/trashshim.conf"
TRASH_DROPIN_BODY = (
    "# 由 fnos_patch.py 烘焙：把回收站搬运 wrapper 挂到 trim（其派生 filemanager 继承 LD_PRELOAD）\n"
    "[Service]\n"
    "Environment=LD_PRELOAD=/usr/local/lib/libfnos-trashshim.so\n"
)

# ---- 需在镜像内屏蔽的 systemd 单元 ----
# 背景（2026-10-11 事故复盘）：nfsd 的 /proc/net/rpc/nfsd.* 是**宿主内核全局态**——
# 在容器里跑 fnOS 的 nfs-server，等于直接在宿主起 rpc.nfsd。多个 fnOS 实例
# （CT200 + 数个 docker 容器，其中一个已删但 rpc.nfsd 泄漏）并发起停会互踩：
#   rpc.nfsd 卡在 nfsd_svc → nfsd4_cld_grace_done（不可中断 D）
#     ↓ 持有 sunrpc cache 锁
#   exportfs -r 卡在 write_flush → expkey_flush（D）
#     ↓ 容器 shutdown 永远等不到它退出
#   PID1 死在 zap_pid_ns_processes → 容器"杀不掉/exec 不进"，只能重启宿主
# 容器场景不需要对外提供 NFS，故镜像内直接 mask。
# 代价：fnOS 的「NFS 共享」特性随之不可用。如需恢复：删 rootfs 内
#       /etc/systemd/system/<unit> 这个指向 /dev/null 的符号链接即可。
MASK_UNITS = ("nfs-server.service",)

DIRFD_SHIM = """#!/usr/bin/env python3
# 开机幂等重放 AOB 补丁（自愈网：应对 fnOS 自更新把二进制换回原版）。
# 两相调用：
#   apply --only aob   → 仅二进制补丁，由 fnos-dirfd-shim.service 在 trim 之前跑；
#   apply --only text  → 仅文本/www 补丁，由 fnos-aob-www.service 在 /usr/trim/www
#                        就绪后跑（sysrestore 异步解压，故这里轮询等待、有界）。
#   apply --only aob --include-disabled → 连 disabled:true 的 opt-in 补丁一起打，
#                        由 fnos-disk-io-monitor.service 跑（默认不 enable）。
# 参数原样透传给 aobpatch.py。不带 --only 时全量处理（手动排查用）。
import sys, glob, subprocess, time
D = "/usr/local/share/fnos-toolchain"
args = sys.argv[1:] or ["apply"]
only = args[args.index("--only") + 1] if "--only" in args else "all"
ps_list = sorted(glob.glob(D + "/patches/*.json"))

def once():
    rc = 0
    for ps in ps_list:
        r = subprocess.run([sys.executable, D + "/aobpatch.py", *args,
                            "--rootfs", "/", "--patchset", ps])
        rc = rc or r.returncode
    return rc

if only == "text":
    rc = 1
    for _ in range(30):          # www 最晚由 sysrestore 解压，等待至多 ~60s
        rc = once()
        if rc == 0:
            break
        time.sleep(2)
    sys.exit(rc)
sys.exit(once())
"""

# ---- 网卡 NM 管理（L2）：让 NetworkManager 拥有 eth0 ----
# 背景：NetworkManager.conf = plugins=ifupdown,keyfile + [ifupdown] managed=false。
# fnOS 的 netdetect 会在开机把 `auto eth0 / iface eth0 inet dhcp` 写进 /etc/network/interfaces，
# 使 NM 把 eth0 判为 unmanaged，fnOS 的 NM 中心网络层随即无从管理/显示。
# 本保险丝在 NM 启动前清掉该 stanza 并预置 keyfile，使 NM 接管 eth0（对齐 CT200 的 Wired connection 1）。
NIC_FUSE_SH = """#!/bin/bash
# fnOS NIC fuse (baked by fnos_patch.py)：在 NetworkManager 启动前让 eth0 可被 NM 管理。
# 幂等：可重复运行；回撤（删本脚本 + unit + /etc/network/interfaces 恢复）。
set -u
I=/etc/network/interfaces
printf 'auto lo\\niface lo inet loopback\\niface lo inet6 loopback\\n' > "$I"
K=/etc/NetworkManager/system-connections/eth0.nmconnection
if [ ! -f "$K" ]; then
  cat > "$K" <<KM
[connection]
id=eth0
uuid=$(cat /proc/sys/kernel/random/uuid)
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
KM
  chmod 600 "$K"
fi
"""

NIC_FUSE_UNIT = """[Unit]
Description=fnOS NIC NM fuse (clean ifupdown so NetworkManager owns eth0)
DefaultDependencies=no
After=local-fs.target
Before=NetworkManager.service
ConditionPathExists=/usr/local/sbin/fnos-nic-fuse.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fnos-nic-fuse.sh

[Install]
WantedBy=sysinit.target
"""


def write_file(path, content, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)


def enable_unit(rootfs, name, target="multi-user.target"):
    want = os.path.join(rootfs, "etc/systemd/system/%s.wants" % target)
    os.makedirs(want, exist_ok=True)
    link = os.path.join(want, name)
    if not os.path.lexists(link):
        os.symlink("/etc/systemd/system/%s" % name, link)


def _is_masked(rootfs, name):
    p = os.path.join(rootfs, "etc/systemd/system", name)
    return os.path.islink(p) and os.readlink(p) == "/dev/null"


def mask_unit(rootfs, name):
    """屏蔽 systemd 单元：/etc/systemd/system/<name> -> /dev/null（幂等）。

    原厂单元本体在 /lib/systemd/system/ 下，故 /etc/... 这个路径正常不存在；
    若已存在同名文件（旧构建残留）先移除再建链接。
    """
    link = os.path.join(rootfs, "etc/systemd/system", name)
    os.makedirs(os.path.dirname(link), exist_ok=True)
    if _is_masked(rootfs, name):
        return
    if os.path.lexists(link):
        os.unlink(link)
    os.symlink("/dev/null", link)


def read_rootfs_version(rootfs):
    """读取 rootfs 的 fnOS 版本（`usr/trim/etc/version`，形如 `1.2.0701`）。"""
    for rel in ("usr/trim/etc/version", "usr/trim/etc/VERSION"):
        p = os.path.join(rootfs, rel)
        if os.path.exists(p):
            return open(p).read().strip()
    return None


def apply(rootfs, patches, mount_shim, enforce_version=True):
    log = []
    ps = json.load(open(patches))
    want = (ps.get("fnos_version") or "").lstrip("Vv")
    got = read_rootfs_version(rootfs)
    if enforce_version and want:
        if not got:
            raise RuntimeError("无法读取 rootfs 版本（usr/trim/etc/version 缺失），拒绝打补丁")
        if got != want:
            raise RuntimeError("版本不符：patchset=%s rootfs=%s（拒绝构建，换版本需重定基）" % (want, got))
    log.append("version anchor: rootfs=%s patchset=%s" % (got, ps.get("fnos_version")))
    write_file(os.path.join(rootfs, "etc/fstab"), FSTAB)
    log.append("fstab rewritten")
    dst = os.path.join(rootfs, "usr/local/sbin/mount")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(mount_shim, dst); os.chmod(dst, 0o755)
    log.append("mount shim -> %s" % dst)
    tc = os.path.join(rootfs, "usr/local/share/fnos-toolchain")
    os.makedirs(os.path.join(tc, "patches"), exist_ok=True)
    r = subprocess.run([sys.executable, os.path.join(TOOLCHAIN_DIR, "aobpatch.py"),
                        "apply", "--rootfs", rootfs, "--patchset", patches,
                        "--report", os.path.join(tc, "patch-report.json")])
    if r.returncode != 0:
        raise RuntimeError("AOB 打补丁失败（见 patch-report.json）")
    log.append("AOB patches applied: %s" % os.path.basename(patches))
    engine_dst = os.path.join(tc, "aobpatch.py")
    shutil.copy2(os.path.join(TOOLCHAIN_DIR, "aobpatch.py"), engine_dst)
    os.chmod(engine_dst, 0o755)  # opt-in 单元直接执行它，需可执行位
    shutil.copy2(patches, os.path.join(tc, "patches", os.path.basename(patches)))
    write_file(os.path.join(rootfs, "usr/local/sbin/fnos-dirfd-shim.py"), DIRFD_SHIM, 0o755)
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-dirfd-shim.service"), DIRFD_UNIT)
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-aob-www.service"), AOB_WWW_UNIT)
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-mountdir.service"), MOUNTDIR_UNIT)
    # 磁盘 I/O 刷新：opt-in 单元只烘焙、**不 enable**（补丁默认不生效；需显式 systemctl enable）。
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-disk-io-monitor.service"),
               DISKIO_UNIT.format(patchset=os.path.basename(patches)))
    write_file(os.path.join(rootfs, "usr/local/sbin/fnos-nic-fuse.sh"), NIC_FUSE_SH, 0o755)
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-nic-fuse.service"), NIC_FUSE_UNIT)
    # 回收站 wrapper：资产 .so -> rootfs/usr/local/lib；drop-in 挂到 trim_main（LD_PRELOAD）
    if not os.path.exists(TRASH_ASSET):
        raise RuntimeError("缺少回收站 wrapper 资产：%s" % TRASH_ASSET)
    so_dst = os.path.join(rootfs, TRASH_SO)
    os.makedirs(os.path.dirname(so_dst), exist_ok=True)
    shutil.copy2(TRASH_ASSET, so_dst); os.chmod(so_dst, 0o755)
    write_file(os.path.join(rootfs, TRASH_DROPIN), TRASH_DROPIN_BODY)
    log.append("trash wrapper baked: %s + %s" % (TRASH_SO, TRASH_DROPIN))
    enable_unit(rootfs, "fnos-dirfd-shim.service")
    enable_unit(rootfs, "fnos-aob-www.service")
    enable_unit(rootfs, "fnos-mountdir.service")
    enable_unit(rootfs, "fnos-nic-fuse.service", "sysinit.target")
    # 注意：fnos-disk-io-monitor.service **刻意不 enable**（磁盘 I/O 补丁默认不生效）。
    # 屏蔽 nfs-server：nfsd 是宿主内核全局态，容器内多实例互踩会 wedge 宿主（见 MASK_UNITS 注释）。
    for u in MASK_UNITS:
        mask_unit(rootfs, u)
    log.append("masked units: %s（宿主全局 nfsd 防互踩；fnOS NFS 共享特性随之不可用，"
               "删 /etc/systemd/system/<unit> 符号链接可恢复）" % ", ".join(MASK_UNITS))
    log.append("container-side units baked + enabled（含 NIC NM fuse + AOB 文本相；"
               "disk-io opt-in 单元仅烘焙、未 enable）")
    return log


def _has(rootfs, rel, needle):
    try:
        return needle in open(os.path.join(rootfs, rel)).read()
    except OSError:
        return False


def _active_fstab_lines(rootfs):
    """返回 /etc/fstab 的有效（非注释）行。"""
    try:
        raw = open(os.path.join(rootfs, "etc/fstab")).read().splitlines()
    except OSError:
        return None
    active = []
    for line in raw:
        body = line.split("#", 1)[0].strip()
        if body:
            active.append(body)
    return active


def status(rootfs):
    active = _active_fstab_lines(rootfs)
    st = {
        "fstab(no active trimafs/efi/uuid-root)": active is not None and not any(
            ("trimafs" in l) or ("/boot/efi" in l) or l.split()[1:2] == ["/"] for l in active),
        "mount shim": os.path.exists(os.path.join(rootfs, "usr/local/sbin/mount")),
        "dirfd shim": os.path.exists(os.path.join(rootfs, "usr/local/sbin/fnos-dirfd-shim.py")),
        "patch set baked": bool(glob.glob(os.path.join(rootfs, "usr/local/share/fnos-toolchain/patches/*.json"))),
        "patch engine baked": os.path.exists(os.path.join(rootfs, "usr/local/share/fnos-toolchain/aobpatch.py")),
        "dirfd unit enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-dirfd-shim.service")),
        "aob-www unit enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-aob-www.service")),
        "mountdir unit enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-mountdir.service")),
        "nic fuse script": os.path.exists(os.path.join(rootfs, "usr/local/sbin/fnos-nic-fuse.sh")),
        "nic fuse unit enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/sysinit.target.wants/fnos-nic-fuse.service")),
        "trash wrapper so": os.path.exists(os.path.join(rootfs, TRASH_SO)),
        "trash wrapper dropin": os.path.exists(os.path.join(rootfs, TRASH_DROPIN)),
        "disk-io opt-in unit baked": os.path.exists(os.path.join(rootfs, "etc/systemd/system/fnos-disk-io-monitor.service")),
        # 注意：status 的契约是"全 true = 健康"（stage_patch 用 all(values()) 判幂等），
        # 故这里表达"默认未启用"这个**健康态**，而不是"是否启用"（后者健康时为 False 会误判失败）。
        "disk-io opt-in disabled by default": not os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-disk-io-monitor.service")),
    }
    # nfs-server 屏蔽（宿主全局 nfsd 防互踩）
    for u in MASK_UNITS:
        st["masked: %s" % u] = _is_masked(rootfs, u)
    return st


def resolve_patchset(rootfs, patches=None):
    """--patches 缺省：按 rootfs 版本自动选同版本补丁集；找不到则显式失败。

    原则：缺省永不指向任何具体旧版本（fnos-local-deb-head D2）。"""
    if patches:
        return patches
    got = read_rootfs_version(rootfs)
    if not got:
        raise RuntimeError("未指定 --patches 且无法读取 rootfs 版本"
                           "（usr/trim/etc/version 缺失），请显式 --patches 指定补丁集")
    cand = os.path.join(TOOLCHAIN_DIR, "patches", "fnos-%s.json" % got.lstrip("Vv"))
    if not os.path.isfile(cand):
        raise RuntimeError("未指定 --patches 且无该版本补丁集（rootfs=%s，需人工 rebase），"
                           "拒绝猜测旧版本" % got)
    return cand


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["apply", "status"])
    ap.add_argument("--rootfs", required=True)
    ap.add_argument("--patches", default=None,
                    help="补丁集路径；缺省按 rootfs 版本自动选择（找不到则失败，永不默认旧版本）")
    ap.add_argument("--mount-shim", default=os.path.normpath(os.path.join(TOOLCHAIN_DIR, "..", "scripts", "stor-mount-shim.sh")))
    ap.add_argument("--no-version-check", action="store_true")
    a = ap.parse_args()
    if os.geteuid() != 0:
        print("需要 root", file=sys.stderr); sys.exit(1)
    if a.cmd == "apply":
        for line in apply(a.rootfs, resolve_patchset(a.rootfs, a.patches), a.mount_shim,
                          enforce_version=not a.no_version_check):
            print("  " + line)
    print(json.dumps(status(a.rootfs), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
