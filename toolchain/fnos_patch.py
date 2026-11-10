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
import argparse, glob, hashlib, json, os, re, shutil, subprocess, sys

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
After=local-fs.target sysrestore.service trim_main.service fnos-patchset-fetch.service
Wants=sysrestore.service fnos-patchset-fetch.service
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
ConditionPathExists=/usr/local/sbin/fnos-dirfd-shim.py

[Service]
Type=oneshot
RemainAfterExit=yes
# 运行时按版本选择补丁集（wrapper --profile disk-io 内部走精确→最近更早→no-compatible）
ExecStart=/usr/local/sbin/fnos-dirfd-shim.py apply --profile disk-io

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

# ---- 构建所需文件集合（design D11：公开清单与 CI 的机器契约）----
# apply()（= pipeline 的 stage_patch）会读取/拷贝的全部源文件。公开仓必须包含
# 这些文件，缺一个就要等到 CI 里才炸。路径一律是**公开树相对路径**
# （公开仓根 = 私有仓 fnos/ 根）。
REPO_ROOT = os.path.dirname(TOOLCHAIN_DIR)
BUILD_INPUTS = (
    ("toolchain/aobpatch.py", lambda: os.path.join(TOOLCHAIN_DIR, "aobpatch.py")),
    ("toolchain/assets/libfnos-trashshim.so", lambda: TRASH_ASSET),
    ("toolchain/fnos-lib-consumers", lambda: os.path.join(TOOLCHAIN_DIR, "fnos-lib-consumers")),
    ("toolchain/fnos-nginx-route.sh", lambda: os.path.join(TOOLCHAIN_DIR, "fnos-nginx-route.sh")),
    ("toolchain/fnos-patch-status", lambda: os.path.join(TOOLCHAIN_DIR, "fnos-patch-status")),
    ("toolchain/fnos-patchset-fetch", lambda: os.path.join(TOOLCHAIN_DIR, "fnos-patchset-fetch")),
    ("scripts/stor-mount-shim.sh", lambda: os.path.join(REPO_ROOT, "scripts", "stor-mount-shim.sh")),
)

# apply() 里每个 copy2 源表达式 -> 公开树相对路径（自检用）。
# 新增 copy2 源而不在此登记 → 自检失败（这是"契约不靠人记"的兜底）。
COPY_SOURCE_RESOLVERS = {
    "mount_shim": "scripts/stor-mount-shim.sh",
    "TRASH_ASSET": "toolchain/assets/libfnos-trashshim.so",
    "patch_status_src": "toolchain/fnos-patch-status",
    "patches": "@patchset",  # 动态：随 --patches/版本变化
    'os.path.join(TOOLCHAIN_DIR, "aobpatch.py")': "toolchain/aobpatch.py",
    'os.path.join(TOOLCHAIN_DIR, "fnos-patchset-fetch")': "toolchain/fnos-patchset-fetch",
    'os.path.join(TOOLCHAIN_DIR, "fnos-lib-consumers")': "toolchain/fnos-lib-consumers",
    'os.path.join(TOOLCHAIN_DIR, "fnos-nginx-route.sh")': "toolchain/fnos-nginx-route.sh",
}

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
MASK_UNITS = ("nfs-server.service", "notify_service.service", "trim_trashbind.service")

# ---- zpool shim + pg fix（容器环境适配：消除 syslog 噪音）----
# 背景（见 fnos/29-zpool-pg-syslog-noise-fix.md）：fnOS 在容器内调用 zpool status
# 检测 ZFS 池，但容器无 /dev/zfs → 每 ~5 秒报错。shim 拦截 zpool 调用返回空池 JSON。
# pg fix：PostgreSQL 15 WAL 归档服务需要 /var/backups/postgresql 目录 + pg_hba.conf replication 条目。
ZPOOL_SHIM = r"""#!/bin/sh
# zpool shim for fnOS in LXC container
for arg in "$@"; do
  case "$arg" in
    --version|version)
      echo "zfs-2.4.1-1"
      echo "zfs-kmod-2.4.4-pve1"
      exit 0
      ;;
  esac
done
subcmd=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    *) subcmd="$arg"; break ;;
  esac
done
case "$subcmd" in
  status|list)
    printf '{"output_version":{"command":"zpool %s","vers_major":0,"vers_minor":1},"pools":{},"error_count":0}\n' "$subcmd"
    exit 0
    ;;
esac
exit 0
"""

ZPOOL_SHIM_SCRIPT = r"""#!/bin/sh
# fnOS container zpool shim + pg fix (container-side, baked into rootfs)
# Called by fnos-zpool-shim.service on boot, and by fnos-syslog-fix.sh on host.
ZPOOL_SHIM_MARKER="zpool shim for fnOS in LXC container"
ZPOOL_REAL="/sbin/zpool.real"
ZPOOL_SHIM="/sbin/zpool"

apply_zpool_shim() {
    if grep -q "$ZPOOL_SHIM_MARKER" "$ZPOOL_SHIM" 2>/dev/null; then
        return 0
    fi
    if [ -f "$ZPOOL_SHIM" ]; then
        mv -f "$ZPOOL_SHIM" "$ZPOOL_REAL"
    fi
    cat > "$ZPOOL_SHIM" << 'SHIMEOF'
#!/bin/sh
# zpool shim for fnOS in LXC container
for arg in "$@"; do
  case "$arg" in
    --version|version)
      echo "zfs-2.4.1-1"
      echo "zfs-kmod-2.4.4-pve1"
      exit 0
      ;;
  esac
done
subcmd=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    *) subcmd="$arg"; break ;;
  esac
done
case "$subcmd" in
  status|list)
    printf '{"output_version":{"command":"zpool %s","vers_major":0,"vers_minor":1},"pools":{},"error_count":0}\n' "$subcmd"
    exit 0
    ;;
esac
exit 0
SHIMEOF
    chmod 755 "$ZPOOL_SHIM"
}

apply_pg_fix() {
    mkdir -p /var/backups/postgresql
    if id postgres >/dev/null 2>&1; then
        chown postgres:postgres /var/backups/postgresql
    fi
    chmod 750 /var/backups/postgresql
    PG_VER=$(ls /etc/postgresql/ 2>/dev/null | head -1)
    if [ -n "$PG_VER" ]; then
        PG_HBA="/etc/postgresql/$PG_VER/main/pg_hba.conf"
        if [ -f "$PG_HBA" ] && ! grep -qE '^local[[:space:]]+replication[[:space:]]+postgres' "$PG_HBA"; then
            sed -i '/^local[[:space:]]\+all[[:space:]]\+postgres/a local   replication     postgres                                    peer map=trim_root' "$PG_HBA"
        fi
    fi
    if [ -n "$PG_VER" ] && pgrep -x postgres >/dev/null 2>&1; then
        pg_ctlcluster "$PG_VER" main reload 2>/dev/null || true
    fi
}

rollback_zpool_shim() {
    if [ -f "$ZPOOL_REAL" ]; then
        rm -f "$ZPOOL_SHIM"
        mv "$ZPOOL_REAL" "$ZPOOL_SHIM"
    fi
}

rollback_pg_fix() {
    PG_VER=$(ls /etc/postgresql/ 2>/dev/null | head -1)
    if [ -n "$PG_VER" ]; then
        PG_HBA="/etc/postgresql/$PG_VER/main/pg_hba.conf"
        if [ -f "$PG_HBA" ]; then
            sed -i '/^local   replication     postgres/d' "$PG_HBA"
        fi
    fi
    rm -rf /var/backups/postgresql
}

status_zpool_shim() {
    if grep -q "$ZPOOL_SHIM_MARKER" "$ZPOOL_SHIM" 2>/dev/null; then
        printf '  zpool-shim          : GREEN (shim installed)\n'
        return 0
    else
        printf '  zpool-shim          : RED   (shim not installed)\n'
        return 1
    fi
}

status_pg_fix() {
    local fail=0
    if [ -d /var/backups/postgresql ]; then
        printf '  pg-fix:dir          : GREEN (/var/backups/postgresql)\n'
    else
        printf '  pg-fix:dir          : RED   (missing /var/backups/postgresql)\n'
        fail=1
    fi
    PG_VER=$(ls /etc/postgresql/ 2>/dev/null | head -1)
    if [ -n "$PG_VER" ] && [ -f "/etc/postgresql/$PG_VER/main/pg_hba.conf" ] && grep -qE '^local[[:space:]]+replication[[:space:]]+postgres' "/etc/postgresql/$PG_VER/main/pg_hba.conf" 2>/dev/null; then
        printf '  pg-fix:pg_hba       : GREEN (replication entry present)\n'
    else
        printf '  pg-fix:pg_hba       : RED   (replication entry missing)\n'
        fail=1
    fi
    return $fail
}

case "${1:-}" in
    apply)
        apply_zpool_shim
        apply_pg_fix
        ;;
    rollback)
        rollback_pg_fix
        rollback_zpool_shim
        ;;
    status)
        rc=0
        status_zpool_shim || rc=1
        status_pg_fix || rc=1
        exit $rc
        ;;
    *)
        echo "Usage: $0 {apply|rollback|status}"
        exit 2
        ;;
esac
"""

ZPOOL_SHIM_UNIT = """[Unit]
Description=fnOS zpool shim + pg fix (container environment)
DefaultDependencies=no
After=local-fs.target postgresql@*.service
Before=trim_main.service
ConditionPathExists=/usr/local/sbin/fnos-zpool-shim.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fnos-zpool-shim.sh apply

[Install]
WantedBy=sysinit.target
"""

DIRFD_SHIM = """#!/usr/bin/env python3
# 开机幂等重放 AOB 补丁（自愈网：应对 fnOS 自更新把二进制换回原版）。
# 按运行版本**只选一个补丁集**：精确匹配 → 数值最近的严格更早版本（fallback）→ no-compatible。
# 子命令：
#   apply [--only aob|text|all] [--include-disabled] [--best-effort ...]  透传 aobpatch
#   apply --profile disk-io        等价于 apply --only aob --include-disabled（磁盘 I/O opt-in）
#   status                         选择模式 + aobpatch check 摘要（--best-effort）
#   revert                         按文件从 backups/<最新 ts>/ 恢复
# 两相调用：
#   apply --only aob   → 仅二进制补丁，由 fnos-dirfd-shim.service 在 trim 之前跑；
#   apply --only text  → 仅文本/www 补丁，由 fnos-aob-www.service 在 /usr/trim/www
#                        就绪后跑（sysrestore 异步解压，故这里轮询等待、有界）。
import sys, os, glob, json, re, shutil, subprocess, time
D = "/usr/local/share/fnos-toolchain"
VER_PATH = "/usr/trim/etc/version"
PATCHES = D + "/patches"
BACKUPS = D + "/backups"


def vtuple(v):
    # 只取前导 dotted 数字部分；预发布后缀（如 -rc1）整体按 no-compatible 处理
    m = re.match(r"\\s*(\\d+(?:\\.\\d+)*)", str(v))
    return tuple(int(x) for x in m.group(1).split(".")) if m else ()


def running_version():
    try:
        return open(VER_PATH).read().strip().lstrip("Vv")
    except OSError:
        return ""


def select():
    # 返回 (mode, patchset_path, running_ver)：exact / fallback / no-compatible
    # 带后缀的预发布版本（如 1.2.1010-rc1）除精确字符串匹配外一律 no-compatible
    rv = running_version()
    clean = bool(re.match(r"\\s*\\d+(?:\\.\\d+)*\\s*$", rv))
    best = None
    for f in sorted(glob.glob(PATCHES + "/fnos-*.json")):
        try:
            v = str(json.load(open(f)).get("fnos_version", "")).lstrip("Vv")
        except Exception:
            continue
        if rv and v == rv:
            return "exact", f, rv
        if rv and clean and vtuple(v) < vtuple(rv):
            if best is None or vtuple(v) > vtuple(best[0]):
                best = (v, f)
    if best:
        return "fallback", best[1], rv
    return "no-compatible", None, rv


def mask_noisy_units():
    # 开机时补齐 LXC 里必然失败的服务的 mask（与 fnos_patch.py MASK_UNITS 一致）。
    # 背景：notify_service（二进制缺失）、trim_trashbind（依赖内核设备 /dev/trim-trashbin）
    # 在 LXC 里每 5s 崩一次，restart counter 能到 100+；老容器/被 fnOS 还原过的容器会
    # 丢掉镜像烘焙的 mask → 循环重启。开机重放时幂等补上，杜绝复发。
    for u in ("nfs-server.service", "notify_service.service", "trim_trashbind.service"):
        p = "/etc/systemd/system/" + u
        try:
            if os.path.islink(p) and os.readlink(p) == "/dev/null":
                continue
            subprocess.run(["systemctl", "stop", u], timeout=30,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["systemctl", "disable", u], timeout=30,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if os.path.lexists(p):
                os.unlink(p)
            os.symlink("/dev/null", p)
            print("masked %s (LXC 中不可用，避免重启循环)" % u)
        except Exception as e:
            print("mask %s failed: %s" % (u, e))
    subprocess.run(["systemctl", "daemon-reload"], timeout=60,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def aob(*args):
    mode, ps, rv = select()
    if ps is None:
        print("no-compatible-patchset (running=%s): 无可用补丁集，跳过本次重放" % rv)
        return 0
    restart = "--restart-consumers" in args
    args = [a for a in args if a != "--restart-consumers"]
    cmd = [sys.executable, D + "/aobpatch.py", *args, "--rootfs", "/", "--patchset", ps]
    if mode == "fallback":
        cmd += ["--fallback"]
    if "--best-effort" not in args:
        cmd += ["--best-effort"]
    print("replay mode=%s running=%s patchset=%s" % (mode, rv, os.path.basename(ps)))
    rc = subprocess.run(cmd).returncode
    if restart and rc == 0:
        restart_consumers()
    return rc


def restart_consumers():
    # live 替换 libnfile/libnperm/libtrimacl 后重启所有消费者（doc 35/36 的教训）
    lst = D + "/lib-consumers.txt"
    if not os.path.exists(lst):
        print("no consumer list (%s); skip restart" % lst)
        return
    for u in open(lst):
        u = u.strip()
        if not u or u.startswith("#"):
            continue
        try:
            r = subprocess.run(["systemctl", "restart", u], timeout=90)
            print("restart %s: rc=%d" % (u, r.returncode))
        except Exception as e:
            print("restart %s failed: %s" % (u, e))


def status():
    mode, ps, rv = select()
    print("running=%s mode=%s patchset=%s" % (rv, mode, os.path.basename(ps) if ps else "-"))
    if not ps:
        return 0
    r = subprocess.run([sys.executable, D + "/aobpatch.py", "check", "--rootfs", "/",
                        "--patchset", ps, "--best-effort"]
                       + (["--fallback"] if mode == "fallback" else []),
                       capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
        from collections import Counter
        c = Counter(str(p.get("status", "?")).split("(")[0] for p in d.get("patches", []))
        print("ok=%s patches=%s" % (d.get("ok"), dict(c)))
        for w in d.get("warnings", [])[:20]:
            print("  WARN", w)
    except Exception:
        print(r.stdout[-500:], r.stderr[-300:])
    return 0 if r.returncode == 0 else 1


def revert():
    if not os.path.isdir(BACKUPS):
        print("no backups dir"); return 1
    ts = sorted(os.listdir(BACKUPS))[-1]
    root = os.path.join(BACKUPS, ts)
    n = 0
    for dp, _, fns in os.walk(root):
        for fn in fns:
            src = os.path.join(dp, fn)
            dst = os.path.join("/", os.path.relpath(src, root))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            n += 1
    print("reverted %d file(s) from backups/%s" % (n, ts))
    return 0


args = sys.argv[1:]
if args and args[0] == "status":
    sys.exit(status())
if args and args[0] == "revert":
    sys.exit(revert())
# 每次 apply（含开机重放）先补齐冗余服务 mask —— fnOS 升级/还原可能把 mask 弄丢
mask_noisy_units()
if "--profile" in args:
    i = args.index("--profile")
    prof = args[i + 1] if i + 1 < len(args) else ""
    rest = args[:i] + args[i + 2:]
    if prof == "disk-io":
        args = ["apply", "--only", "aob", "--include-disabled"] + [a for a in rest if a != "apply"]
    else:
        args = rest or ["apply"]
if not args:
    args = ["apply"]
only = args[args.index("--only") + 1] if "--only" in args else "all"
if only == "text":
    # www 由 sysrestore 异步解压：先等 check 通过（文件就绪），再**只应用一次**
    # （反复 apply 会每次生成一个备份目录，把真正的备份冲掉）
    ready = False
    for _ in range(30):
        rc = aob("check", "--only", "text")
        if rc == 0:
            ready = True
            break
        time.sleep(2)
    if not ready:
        print("www not ready yet; skip text replay this round")
        sys.exit(0)
    sys.exit(aob("apply", "--only", "text"))
sys.exit(aob(*args))
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


PATCH_STATUS_UNIT = """[Unit]
Description=fnOS patch status detector (on-boot check + WebUI notification)
After=fnos-dirfd-shim.service fnos-aob-www.service fnos-patchset-fetch.service postgresql.service
Wants=fnos-patchset-fetch.service postgresql.service

[Service]
Type=oneshot
# 去掉 RemainAfterExit：让 fnos-patch-status.timer 能重复触发
ExecStart=/usr/local/sbin/fnos-patch-status --notify --log
StandardOutput=journal
StandardError=journal
TimeoutStartSec=300
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
"""

PATCH_STATUS_TIMER = """[Unit]
Description=Periodic fnOS patch status refresh

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
"""

# 目标版本补丁集下载器（网络就绪后；失败返回 0 不阻塞开机）
PATCHSET_FETCH_UNIT = """[Unit]
Description=fnOS patchset fetch (download missing target-version patchset)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=90
ExecStart=/usr/local/sbin/fnos-patchset-fetch
ExecStartPost=/bin/true

[Install]
WantedBy=multi-user.target
"""

# nginx 同源路由单元：在 trim_nginx 启动前创建 live conf 并同步 ng.conf.zip
NGINX_ROUTE_UNIT = """[Unit]
Description=fnOS nginx same-origin verlan route (before trim_nginx)
DefaultDependencies=no
After=local-fs.target trim_init.service
Before=trim_nginx.service
ConditionPathExists=/usr/local/sbin/fnos-nginx-route.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fnos-nginx-route.sh

[Install]
WantedBy=multi-user.target
"""


def write_file(path, content, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)


def upsert_kv(path, key, value, comment=None):
    """键值文件里改一个键、其余不动（shell source 风格，如 /etc/default/*）。

    有该键则替换行，无则追加 `KEY=value`（附 comment 行时一并追加）；
    文件不存在则新建。重跑幂等。返回是否发生改动。
    """
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        lines = None
    if lines is None:
        lines = []
        if comment:
            lines.append(comment)
        lines.append("%s=%s" % (key, value))
        changed = True
    else:
        changed = False
        pat = re.compile(r"^%s\s*=" % re.escape(key))
        for i, l in enumerate(lines):
            if pat.match(l):
                want = "%s=%s" % (key, value)
                if l != want:
                    lines[i] = want
                    changed = True
                break
        else:
            if comment:
                lines.append(comment)
            lines.append("%s=%s" % (key, value))
            changed = True
    if changed:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
    return changed


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
               DISKIO_UNIT)  # 运行时按版本选择补丁集，不再烘焙文件名
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
    # ---- zpool shim + pg fix（容器环境适配：消除 syslog 噪音）----
    # 背景（见 fnos/29-zpool-pg-syslog-noise-fix.md）：fnOS 在容器内调用 zpool status
    # 检测 ZFS 池，但容器无 /dev/zfs → 每 ~5 秒报错；pg_receivewal 因目录缺失 +
    # pg_hba.conf 无 replication 条目 → 每 ~2-3 分钟失败重启。
    zpool_path = os.path.join(rootfs, "sbin", "zpool")
    zpool_real = os.path.join(rootfs, "sbin", "zpool.real")
    if os.path.exists(zpool_path) and not os.path.exists(zpool_real):
        # 检查是否已经是 shim（避免重复重命名）。
        # 必须按**二进制**读：1.2.1000 的 ISO 里 /sbin/zpool 是真 ELF（zfs 用户态工具），
        # 按文本解码会 UnicodeDecodeError 直接把构建打挂。
        try:
            with open(zpool_path, "rb") as f:
                content = f.read()
            if b"zpool shim for fnOS in LXC container" not in content:
                os.rename(zpool_path, zpool_real)
                log.append("renamed /sbin/zpool -> /sbin/zpool.real")
        except (OSError, IOError):
            os.rename(zpool_path, zpool_real)
            log.append("renamed /sbin/zpool -> /sbin/zpool.real")
    write_file(zpool_path, ZPOOL_SHIM, 0o755)
    log.append("zpool shim -> %s" % zpool_path)
    # 容器侧自愈脚本
    shim_script_dst = os.path.join(rootfs, "usr/local/sbin/fnos-zpool-shim.sh")
    os.makedirs(os.path.dirname(shim_script_dst), exist_ok=True)
    write_file(shim_script_dst, ZPOOL_SHIM_SCRIPT, 0o755)
    log.append("zpool shim script -> %s" % shim_script_dst)
    # pg fix：创建 /var/backups/postgresql（构建期 root:root 750，运行期 chown）
    pg_backup_dir = os.path.join(rootfs, "var", "backups", "postgresql")
    os.makedirs(pg_backup_dir, exist_ok=True)
    os.chmod(pg_backup_dir, 0o750)
    log.append("pg backup dir created: %s (root:root 750, runtime chown)" % pg_backup_dir)
    # pg_hba.conf 幂等添加 replication 条目（版本动态检测）
    pg_dir = os.path.join(rootfs, "etc", "postgresql")
    pg_hba = None
    if os.path.isdir(pg_dir):
        for ver in sorted(os.listdir(pg_dir), reverse=True):
            cand = os.path.join(pg_dir, ver, "main", "pg_hba.conf")
            if os.path.exists(cand):
                pg_hba = cand
                break
    if pg_hba:
        try:
            content = open(pg_hba).read()
            if "local replication postgres" not in content:
                lines = content.splitlines()
                new_lines = []
                inserted = False
                for line in lines:
                    new_lines.append(line)
                    if not inserted and line.strip().startswith("local") and "postgres" in line and "peer" in line:
                        new_lines.append("local   replication     postgres                                    peer map=trim_root")
                        inserted = True
                if inserted:
                    with open(pg_hba, "w") as f:
                        f.write("\n".join(new_lines) + "\n")
                    log.append("pg_hba.conf replication entry added: %s" % pg_hba)
                else:
                    log.append("pg_hba.conf: no matching postgres local line, skipping")
            else:
                log.append("pg_hba.conf replication entry already present")
        except (OSError, IOError) as e:
            log.append("pg_hba.conf edit failed: %s" % e)
    else:
        log.append("pg_hba.conf not found (PostgreSQL not installed in rootfs?)")
    # 自愈 unit
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-zpool-shim.service"), ZPOOL_SHIM_UNIT)
    log.append("zpool shim unit baked: etc/systemd/system/fnos-zpool-shim.service")
    enable_unit(rootfs, "fnos-zpool-shim.service", "sysinit.target")
    log.append("zpool shim unit enabled (sysinit.target)")
    enable_unit(rootfs, "fnos-dirfd-shim.service")
    enable_unit(rootfs, "fnos-aob-www.service")
    enable_unit(rootfs, "fnos-mountdir.service")
    enable_unit(rootfs, "fnos-nic-fuse.service", "sysinit.target")
    # ---- fnos-patch-status: on-boot unified patch status detector + WebUI notify ----
    # Copies the container-side detector script and systemd oneshot service so every
    # built image reports patch health to the WebUI on boot (see fnos-patch-status change).
    patch_status_src = os.path.join(TOOLCHAIN_DIR, "fnos-patch-status")
    if os.path.exists(patch_status_src):
        ps_dst = os.path.join(rootfs, "usr/local/sbin/fnos-patch-status")
        os.makedirs(os.path.dirname(ps_dst), exist_ok=True)
        shutil.copy2(patch_status_src, ps_dst)
        os.chmod(ps_dst, 0o755)
        log.append("fnos-patch-status detector -> %s" % ps_dst)
    else:
        log.append("fnos-patch-status detector source not found in toolchain, skipping")
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-patch-status.service"),
               PATCH_STATUS_UNIT)
    enable_unit(rootfs, "fnos-patch-status.service")
    # 定时刷新 + 目标版本补丁集下载 + nginx 同源路由单元
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-patch-status.timer"),
               PATCH_STATUS_TIMER)
    enable_unit(rootfs, "fnos-patch-status.timer", "timers.target")
    shutil.copy2(os.path.join(TOOLCHAIN_DIR, "fnos-patchset-fetch"),
                 os.path.join(rootfs, "usr/local/sbin/fnos-patchset-fetch"))
    os.chmod(os.path.join(rootfs, "usr/local/sbin/fnos-patchset-fetch"), 0o755)
    # lib 消费者清单：live 替换 libnfile/libnperm/libtrimacl 后需重启这些服务（doc 35/36）
    shutil.copy2(os.path.join(TOOLCHAIN_DIR, "fnos-lib-consumers"),
                 os.path.join(rootfs, "usr/local/share/fnos-toolchain/lib-consumers.txt"))
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-patchset-fetch.service"),
               PATCHSET_FETCH_UNIT)
    enable_unit(rootfs, "fnos-patchset-fetch.service")
    shutil.copy2(os.path.join(TOOLCHAIN_DIR, "fnos-nginx-route.sh"),
                 os.path.join(rootfs, "usr/local/sbin/fnos-nginx-route.sh"))
    os.chmod(os.path.join(rootfs, "usr/local/sbin/fnos-nginx-route.sh"), 0o755)
    write_file(os.path.join(rootfs, "etc/systemd/system/fnos-nginx-route.service"),
               NGINX_ROUTE_UNIT)
    enable_unit(rootfs, "fnos-nginx-route.service")
    log.append("patch-status timer + patchset-fetch + nginx-route baked + enabled")
    log.append("fnos-patch-status.service baked + enabled")
    # 启动不等 ifupdown：容器内 interfaces 仅 lo（NIC fuse 每开机洗掉 eth0 stanza，
    # eth0 归 NM、IP 由宿主 veth 在 ifupdown 之外配好），ifup 等法永不成功，
    # 缺省 300 秒超时直接拖住 network-online -> trim_init 整条链。upsert 只动一键。
    upsert_kv(os.path.join(rootfs, "etc/default/networking"), "WAIT_ONLINE_METHOD", "none",
              "# LXC: ifupdown 只管 lo，不等它（fnos-lxc-boot-tune，否则罚站 300s）")
    log.append("wait-online none baked: etc/default/networking")
    # SSH 端口不得预占：清理 ssh.socket 启用软链（systemctl enable ssh.socket 的落盘点，
    # 未来 Debian 默认 socket 化的 ISO 也会落这里）。fnOS WebUI 开 SSH 前跑 IsPortInUse
    # 预检，socket activation 预占 22 会让开关"显示关却开不了"（fnos/23-ssh-webui-
    # toggle-socket-conflict.md）。仅清启用面，不动 /lib 单元本体（保留手动 enable 路径）。
    sock_wants = os.path.join(rootfs, "etc/systemd/system/sockets.target.wants/ssh.socket")
    if os.path.lexists(sock_wants):
        os.remove(sock_wants)
        log.append("ssh.socket enable symlink removed: etc/systemd/system/sockets.target.wants/ssh.socket")
    else:
        log.append("ssh.socket not enabled (absent)")
    # 注意：fnos-disk-io-monitor.service **刻意不 enable**（磁盘 I/O 补丁默认不生效）。
    # 屏蔽服务：nfs-server（宿主全局 nfsd 互踩）、notify_service（二进制缺失/fsck 孤儿）、
    # trim_trashbind（依赖内核设备 /dev/trim-trashbin，LXC 中不存在；回收站由 LD_PRELOAD wrapper 替代）。
    for u in MASK_UNITS:
        mask_unit(rootfs, u)
    log.append("masked units: %s（宿主全局 nfsd 防互踩 + LXC 冗余服务；"
               "删 /etc/systemd/system/<unit> 符号链接可恢复）" % ", ".join(MASK_UNITS))
    log.append("container-side units baked + enabled（含 NIC NM fuse + AOB 文本相；"
               "disk-io opt-in 单元仅烘焙、未 enable）")
    return log


def _has(rootfs, rel, needle):
    """二进制安全的内容包含判定（目标可能是 ELF 等二进制，不能按 UTF-8 解码）。"""
    try:
        with open(os.path.join(rootfs, rel), "rb") as f:
            return needle.encode() in f.read()
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


def _trim_app_center_patched(rootfs):
    """tpk 安装权限修复（appcenter-tpk-perm D5）：trim_app_center 是否处于 patched 态。

    以 rootfs 内烘焙补丁集的 file_hashes 为锚（整文件 sha256 ∈ patched 集为 True，
    orig/未知为 False）——版本绑定留在 JSON，本文件保持版本无关。
    旧镜像补丁集无该条目 → False（重跑 stage_patch 刷入新补丁集后即修复）。"""
    binp = os.path.join(rootfs, "usr/trim/bin/trim_app_center")
    if not os.path.exists(binp):
        return False
    try:
        sha = hashlib.sha256(open(binp, "rb").read()).hexdigest()
    except OSError:
        return False
    for j in sorted(glob.glob(os.path.join(rootfs, "usr/local/share/fnos-toolchain/patches/*.json"))):
        try:
            ps = json.load(open(j))
        except (OSError, ValueError):
            continue
        h = (ps.get("file_hashes") or {}).get("usr/trim/bin/trim_app_center")
        if not h:
            continue
        vals = h.get("patched")
        vals = [vals] if isinstance(vals, str) else list(vals or [])
        if sha in vals:
            return True
    return False


def status(rootfs):
    active = _active_fstab_lines(rootfs)
    st = {
        "fstab(no active trimafs/efi/uuid-root)": active is not None and not any(
            ("trimafs" in l) or ("/boot/efi" in l) or l.split()[1:2] == ["/"] for l in active),
        "mount shim": os.path.exists(os.path.join(rootfs, "usr/local/sbin/mount")),
        "AOB replay wrapper": os.path.exists(os.path.join(rootfs, "usr/local/sbin/fnos-dirfd-shim.py")),
        "patch set baked": bool(glob.glob(os.path.join(rootfs, "usr/local/share/fnos-toolchain/patches/*.json"))),
        "patch engine baked": os.path.exists(os.path.join(rootfs, "usr/local/share/fnos-toolchain/aobpatch.py")),
        # tpk 安装权限（appcenter-tpk-perm D5）：旧镜像/未打 → False，重跑 stage_patch 或热修后为 True。
        "trim_app_center patched": _trim_app_center_patched(rootfs),
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
        "wait-online none": _has(rootfs, "etc/default/networking", "WAIT_ONLINE_METHOD=none"),
        # 健康态表达"未启用"（同上 disk-io 注释）：软链存在=端口将被预占=WebUI SSH 开关失效。
        "ssh.socket not enabled": not os.path.lexists(os.path.join(rootfs, "etc/systemd/system/sockets.target.wants/ssh.socket")),
        "patch status service enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-patch-status.service")),
        "patch status timer enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/timers.target.wants/fnos-patch-status.timer")),
        "patchset fetch service enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-patchset-fetch.service")),
        "nginx route unit enabled": os.path.lexists(os.path.join(rootfs, "etc/systemd/system/multi-user.target.wants/fnos-nginx-route.service")),
    }
    # zpool shim + pg fix（容器环境适配，消除 syslog 噪音）
    # 注意：status 契约是"全 true = 健康"（stage_patch 用 all(values()) 判幂等），
    # 故对 rootfs 中**不存在**的组件（如测试 fixture、未装 PostgreSQL 的镜像）
    # 视为"不适用"（True），避免把"组件未安装"误判为"不健康"。
    zpool_path = os.path.join(rootfs, "sbin", "zpool")
    if os.path.exists(zpool_path):
        try:
            with open(zpool_path, "rb") as f:   # 二进制安全（可能是真 ELF）
                zpool_content = f.read()
            st["zpool shim"] = b"zpool shim for fnOS in LXC container" in zpool_content
        except (OSError, IOError):
            st["zpool shim"] = False
    else:
        st["zpool shim"] = True  # 组件不存在 → 不适用
    pg_dir = os.path.join(rootfs, "etc", "postgresql")
    if os.path.isdir(pg_dir):
        st["pg backup dir"] = os.path.exists(os.path.join(rootfs, "var", "backups", "postgresql"))
        pg_hba_found = False
        for v in os.listdir(pg_dir):
            cand = os.path.join(pg_dir, v, "main", "pg_hba.conf")
            if os.path.exists(cand):
                try:
                    for line in open(cand):
                        if "replication" in line and "postgres" in line and line.strip().startswith("local"):
                            pg_hba_found = True
                            break
                except (OSError, IOError):
                    pass
        st["pg hba replication entry"] = pg_hba_found
    else:
        st["pg backup dir"] = True  # PostgreSQL 未安装 → 不适用
        st["pg hba replication entry"] = True  # PostgreSQL 未安装 → 不适用
    zpool_unit = os.path.join(rootfs, "etc/systemd/system/fnos-zpool-shim.service")
    if os.path.exists(zpool_unit):
        st["zpool shim unit enabled"] = os.path.lexists(os.path.join(rootfs, "etc/systemd/system/sysinit.target.wants/fnos-zpool-shim.service"))
    else:
        st["zpool shim unit enabled"] = True  # unit 未烘焙 → 不适用
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


def _rel_to_repo(path):
    """绝对路径 -> 公开树相对路径（不在仓内则原样返回绝对路径）。"""
    ap = os.path.abspath(path)
    rp = os.path.abspath(REPO_ROOT)
    if ap == rp or ap.startswith(rp + os.sep):
        return os.path.relpath(ap, rp)
    return ap


def required_files(patches=None, mount_shim=None, version=None):
    """构建所需文件集合（公开树相对路径，稳定排序）。

    patches  : 具体补丁集路径（动态输入）；缺省时按 version 推导。
    mount_shim: mount shim 路径（动态输入）；缺省为 scripts/stor-mount-shim.sh。
    version  : fnOS 版本（用于在不给补丁集路径时推导补丁集相对路径）。
    """
    out = {rel for rel, _ in BUILD_INPUTS}
    out.add(_rel_to_repo(mount_shim) if mount_shim else "scripts/stor-mount-shim.sh")
    if patches:
        out.add(_rel_to_repo(patches))
    elif version:
        out.add("toolchain/patches/fnos-%s.json" % str(version).lstrip("Vv"))
    return sorted(out)


def _copy2_first_args(src):
    """扫出源码里所有 shutil.copy2(...) 的**第一个**参数（按括号配平切分）。

    不用正则：参数里本身带括号与逗号（os.path.join(a, b)），正则会切错。
    """
    out = []
    needle = "shutil.copy2("
    i = 0
    while True:
        j = src.find(needle, i)
        if j < 0:
            break
        k = j + len(needle)
        depth = 1
        buf = []
        while k < len(src):
            ch = src[k]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            elif ch == "," and depth == 1:
                break
            buf.append(ch)
            k += 1
        out.append(re.sub(r"\s+", " ", "".join(buf).strip()))
        i = k + 1
    return out


def self_check_required_files(patches=None, mount_shim=None, version=None):
    """自检：apply() 里实际 copy2 的源集合 == required_files() 报告的集合。

    做法：解析 apply() 源码里的 shutil.copy2(...) 源表达式，逐个用
    COPY_SOURCE_RESOLVERS 解析成公开树路径；解析不到即视为"新增了未登记的
    构建输入"→ 失败。补丁集是动态项，按需比对。
    """
    import inspect
    src = inspect.getsource(apply)
    exprs = _copy2_first_args(src)
    resolved = []
    unknown = []
    for e in exprs:
        if e not in COPY_SOURCE_RESOLVERS:
            unknown.append(e)
            continue
        resolved.append(COPY_SOURCE_RESOLVERS[e])
    if unknown:
        raise RuntimeError("apply() 出现未登记的 copy2 源（需登记进 COPY_SOURCE_RESOLVERS"
                           " 与 BUILD_INPUTS）：%s" % "; ".join(unknown))
    static = {r for r in resolved if r != "@patchset"}
    expect = set(required_files(patches=None, mount_shim=mount_shim, version=None))
    missing = expect - static
    extra = static - expect
    if missing or extra:
        raise RuntimeError("构建依赖集合与 apply() 实际读取源不一致：缺 %s / 多 %s"
                           % (sorted(missing) or "-", sorted(extra) or "-"))
    return sorted(expect)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="?", choices=["apply", "status", None])
    ap.add_argument("--rootfs", default=None)
    ap.add_argument("--patches", default=None,
                    help="补丁集路径；缺省按 rootfs 版本自动选择（找不到则失败，永不默认旧版本）")
    ap.add_argument("--mount-shim", default=os.path.normpath(os.path.join(TOOLCHAIN_DIR, "..", "scripts", "stor-mount-shim.sh")))
    ap.add_argument("--no-version-check", action="store_true")
    ap.add_argument("--required-files", action="store_true",
                    help="打印构建所需文件集合（公开树相对路径，每行一个）后退出")
    ap.add_argument("--version", default=None,
                    help="配合 --required-files：按 fnOS 版本推导补丁集相对路径")
    ap.add_argument("--self-check", action="store_true",
                    help="自检：required_files 与 apply() 实际读取源是否一致")
    a = ap.parse_args()
    if a.required_files or a.self_check:
        if a.self_check:
            files = self_check_required_files(patches=a.patches, mount_shim=a.mount_shim,
                                               version=a.version)
            print("SELF-CHECK OK: %d 个构建输入与 apply() 一致" % len(files))
        else:
            files = required_files(patches=a.patches, mount_shim=a.mount_shim, version=a.version)
        for f in files:
            print(f)
        return
    if not a.cmd:
        ap.error("需要子命令 apply/status（或用 --required-files）")
    if not a.rootfs:
        ap.error("apply/status 需要 --rootfs")
    if os.geteuid() != 0:
        print("需要 root", file=sys.stderr); sys.exit(1)
    if a.cmd == "apply":
        for line in apply(a.rootfs, resolve_patchset(a.rootfs, a.patches), a.mount_shim,
                          enforce_version=not a.no_version_check):
            print("  " + line)
    print(json.dumps(status(a.rootfs), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
