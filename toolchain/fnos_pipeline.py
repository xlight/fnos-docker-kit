#!/usr/bin/env python3
# ============================================================================
# fnos_pipeline.py — fnOS 镜像流水线的单一编排入口
#
# 阶段（默认按序全跑）：
#   overlay-> 可选前置：底座 rootfs 目录 + OTA 版本 → .deb 覆盖 + 版本戳
#             （本地 deb-head；不给 --base 则跳过，ISO 路径出厂 rootfs 已就绪）
#   patch  -> 给出厂 rootfs 打兼容补丁（fnos_patch）
#   image  -> 生成镜像 raw ext4/btrfs（+ 可选 vztmpl / zfs）（fnos_image）
#   verify -> 产出物验证 + 指纹 + 验证报告（fnos_build.cmd_verify）
#   release-> 打包 release（未过验证不打包）（fnos_build.cmd_release）
#   deploy -> 装成 PVE 容器（fnos_deploy.sh install）
#   storage-> 建专属存储 +（可选）目录挂载（stor-manage.sh / stor-mountdir.sh）
#   smoke  -> 宿主侧装配冒烟（fnos_deploy.sh smoke）
#
# 特性：单入口；`--stages`/`--from`/`--to` 选择阶段；失败即停；按既有证据幂等跳过；
#       `rollback` 只删专属资源。需 root。
#
# 用法：
#   fnos_pipeline.py run --rootfs <dir> --out <dir> [--version V1.2.0800]
#       [--base <底座rootfs目录> --ota-version <1.2.0800>]   # deb-head：overlay 前置
#       [--fs ext4|btrfs] [--size 12] [--vztmpl] [--zfs pool/ds]
#       [--stages patch,image,...] [--from image] [--to deploy]
#       [--ctid 201] [--storage <pool>] [--volstore <pool>] [--volfs ext4]
#       [--mountdir] [--force] [--script-dir <dir>]
#   fnos_pipeline.py rollback --ctid 201 [--volstore <pool>] [--storage <pool>]
#   fnos_pipeline.py status [--out <dir>] [--ctid 201]
# ============================================================================
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import time

TC = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TC)
import fnos_build   # noqa: E402
import fnos_image   # noqa: E402
import fnos_patch   # noqa: E402

# 公开仓脱敏：相对路径（不含任何宿主专有默认）
DEFAULT_SHIM = os.path.normpath(os.path.join(TC, "..", "scripts", "stor-mount-shim.sh"))
DEFAULT_SCRIPT_DIR = os.path.normpath(os.path.join(TC, "..", "scripts"))
STAGE_ORDER = ["overlay", "patch", "image", "verify", "release", "deploy", "storage", "smoke"]


def log(msg):
    print("[pipeline] %s" % msg, flush=True)


def run(cmd, env_extra=None, check=False):
    env = dict(os.environ)
    if env_extra:
        env.update({k: str(v) for k, v in env_extra.items()})
    print("  $ %s" % " ".join(cmd), flush=True)
    p = subprocess.run(cmd, env=env)
    if check and p.returncode != 0:
        raise RuntimeError("命令失败(%d): %s" % (p.returncode, " ".join(cmd)))
    return p.returncode


def ct_running(ctid):
    if not shutil.which("pct"):
        return False
    p = subprocess.run(["pct", "status", str(ctid)], capture_output=True, text=True)
    return "running" in p.stdout


# ---- prerequisites ----------------------------------------------------------
# 前置产物若由**本次运行中更早的阶段**产出，则不算缺失（如 deploy 产出的运行中容器）。
def missing_prereqs(stage, a, before=None):
    before = before or []
    miss = []
    if stage == "overlay":
        if not (a.base and os.path.isdir(a.base)):
            miss.append("--base（已 extract 的底座 rootfs 目录）")
        if not getattr(a, "ota_version", None) and not a.version:
            miss.append("--ota-version（或 --version）目标 OTA 版本")
        if (a.rootfs and os.path.isdir(a.rootfs) and os.listdir(a.rootfs)
                and not a.force):
            miss.append("rootfs 必须不存在或为空目录（防半覆盖态重入；换空目录或 --force 重建）")
    if stage == "patch":
        if not (a.rootfs and os.path.isdir(a.rootfs)) and "overlay" not in before:
            miss.append("rootfs")
    elif stage == "image":
        if not (a.rootfs and os.path.isdir(a.rootfs)) and "overlay" not in before:
            miss.append("rootfs（patch 阶段）")
    elif stage in ("verify", "release", "deploy"):
        if not os.path.isfile(os.path.join(a.out, "image.raw")) and "image" not in before:
            miss.append("image（image 阶段）")
        if stage == "deploy" and not a.ctid:
            miss.append("--ctid")
    elif stage in ("storage", "smoke"):
        if not a.ctid:
            miss.append("--ctid")
        elif not ct_running(a.ctid) and "deploy" not in before:
            miss.append("运行中的容器（deploy 阶段）")
    return miss


# ---- stages -----------------------------------------------------------------
# 本地 deb-head（语义与 CI public-ci.yml 的 deb 头步骤一字对齐，注释互引防漂移）：
# B 文件覆盖法（dpkg-deb --fsys-tarfile 解 data 覆盖，不跑 dpkg 库与 pre/post）；
# 运行时清理清单：machine-id、hostname、logs、/.dockerenv；machine-id 缺失由后续
# patch/推送步重建；版本戳 usr/trim/etc/version 为 fnos_patch 版本锚点必需。
OVERLAY_MARKER = ".fnos-overlay.json"


def stage_overlay(a):
    import glob
    ota = (getattr(a, "ota_version", None) or a.version or "").lstrip("Vv")
    if not ota:
        print("overlay 需要 --ota-version（或 --version）", file=sys.stderr)
        return 2
    base = os.path.abspath(a.base)
    rootfs = os.path.abspath(a.rootfs)
    if base == rootfs:
        print("overlay 拒绝：--base 与 --rootfs 不能是同一目录", file=sys.stderr)
        return 2
    marker_p = os.path.join(rootfs, OVERLAY_MARKER)
    if os.path.isfile(marker_p) and not a.force:
        try:
            mk = json.load(open(marker_p))
            if mk.get("base") == base and mk.get("ota_version") == ota:
                log("overlay: 已覆盖（base=%s ota=%s），幂等跳过（--force 可重做）"
                    % (base, ota))
                return 0
        except Exception:
            pass
    # --force 或 marker 不符：清空重做（防半覆盖态）
    if os.path.isdir(rootfs):
        for e in os.listdir(rootfs):
            p = os.path.join(rootfs, e)
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            else:
                os.unlink(p)
    else:
        os.makedirs(rootfs, exist_ok=True)
    log("overlay: cp -a 底座 %s -> %s" % (base, rootfs))
    rc = run(["cp", "-a", base + "/.", rootfs + "/"])
    if rc != 0:
        return rc
    # 运行时清理（与 CI 一致；断言防漏项）
    for rel in ("etc/machine-id", "etc/hostname", ".dockerenv"):
        p = os.path.join(rootfs, rel)
        if os.path.lexists(p):
            os.unlink(p)
    for rel in ("var/log", "tmp", "run"):
        d = os.path.join(rootfs, rel)
        if os.path.isdir(d):
            for e in os.listdir(d):
                p = os.path.join(d, e)
                if os.path.isdir(p) and not os.path.islink(p):
                    shutil.rmtree(p)
                else:
                    os.unlink(p)
    if os.path.lexists(os.path.join(rootfs, "etc/machine-id")):
        print("overlay 清理漏项：machine-id 仍在", file=sys.stderr)
        return 1
    if os.path.lexists(os.path.join(rootfs, ".dockerenv")):
        print("overlay 清理漏项：/.dockerenv 仍在", file=sys.stderr)
        return 1
    # .deb 包组现签现下（fetch-ota-debs 自带幂等跳过 + sha256 校验，失败即停）
    debs_dir = a.debs_dir or os.path.join(a.out or ".", "ota-debs")
    os.makedirs(debs_dir, exist_ok=True)
    rc = run([sys.executable, os.path.join(TC, "fetch-ota-debs.py"),
              "--version", ota, "--out", debs_dir])
    if rc != 0:
        print("overlay: .deb 下载失败，不产出半覆盖 rootfs", file=sys.stderr)
        return rc
    debs = sorted(glob.glob(os.path.join(debs_dir, "*.deb")))
    if not debs:
        print("overlay: 未下到任何 .deb", file=sys.stderr)
        return 1
    if not shutil.which("dpkg-deb"):
        print("overlay 需要 dpkg-deb（见 deps.sh 最小集）", file=sys.stderr)
        return 2
    for d in debs:
        log("overlay: %s" % os.path.basename(d))
        p1 = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", d], stdout=subprocess.PIPE)
        p2 = subprocess.Popen(["tar", "-x", "-C", rootfs], stdin=p1.stdout)
        p1.stdout.close()
        if p2.wait() != 0 or p1.wait() != 0:
            print("overlay: 解包覆盖失败 %s" % d, file=sys.stderr)
            return 1
    # 版本戳（.deb 不含它；fnos_patch 版本锚点必需）
    vstamp = os.path.join(rootfs, "usr/trim/etc/version")
    os.makedirs(os.path.dirname(vstamp), exist_ok=True)
    open(vstamp, "w").write(ota + "\n")
    if open(vstamp).read().strip() != ota:
        print("overlay: 版本戳写入失败", file=sys.stderr)
        return 1
    json.dump({"base": base, "ota_version": ota}, open(marker_p, "w"))
    log("overlay: 就绪 ota=%s（底座 %s）" % (ota, base))
    return 0


def stage_patch(a):
    if not a.patchset or not os.path.isfile(a.patchset):
        print("ERROR: 无可用补丁集（version=%s；缺 %s，需人工 rebase），拒绝猜测旧版本"
              % (a.version, os.path.join(TC, "patches",
                                         "fnos-%s.json" % (a.version or "?").lstrip("Vv"))),
              file=sys.stderr)
        return 2
    st = fnos_patch.status(a.rootfs)
    if all(st.values()) and not a.force:
        log("patch: rootfs 已打补丁，幂等跳过")
        return 0
    for line in fnos_patch.apply(a.rootfs, a.patchset, a.shim,
                                 enforce_version=not a.no_version_check):
        print("    " + line)
    st = fnos_patch.status(a.rootfs)
    return 0 if all(st.values()) else 1


def stage_image(a):
    raw = os.path.join(a.out, "image.raw")
    os.makedirs(a.out, exist_ok=True)
    if os.path.isfile(raw) and not a.force:
        log("image: %s 已存在，幂等跳过（--force 可重建）" % raw)
    else:
        fnos_image.mkraw(a.rootfs, raw, a.size, a.fs)
        log("image: raw %s (%s, %s GiB)" % (raw, a.fs, a.size))
    if a.vztmpl:
        t = os.path.join(a.out, "fnos-lxc.tar.gz")
        if not os.path.isfile(t) or a.force:
            fnos_image.mkvztmpl(a.rootfs, t)
            log("image: vztmpl %s" % t)
    if a.zfs:
        fnos_image.mkzfs(a.rootfs, a.zfs)
        log("image: zfs %s" % a.zfs)
    return 0


def stage_verify(a):
    rep = fnos_build.cmd_verify(os.path.join(a.out, "image.raw"), a.out,
                                rootfs=a.rootfs, patchset=a.patchset)
    return 0 if rep.get("ok") else 1


def stage_release(a):
    name = "fnos-lxc-%s" % (a.version or "unknown")
    return fnos_build.cmd_release(a.out, name)


def stage_deploy(a):
    if not a.storage:
        print("deploy 需要 --storage（PVE 存储池名）", file=sys.stderr)
        return 2
    img = a.deploy_image or os.path.join(a.out, "image.raw")
    rc = run(["bash", os.path.join(TC, "fnos_deploy.sh"), "install", str(a.ctid),
              "--image", img, "--storage", a.storage, "--size", str(a.size),
              "--hostname", a.hostname])
    if rc != 0:
        return rc
    wait_ready(a.ctid)
    return 0


def stage_storage(a):
    if not a.volstore:
        print("storage 需要 --volstore（ZFS 池名）", file=sys.stderr)
        return 2
    sm = os.path.join(a.script_dir, "stor-manage.sh")
    rc = run(["bash", sm, "create"],
             env_extra={"CTID": a.ctid, "VOLFS": a.volfs, "VOLSTORE": a.volstore})
    if rc != 0:
        return rc
    if a.mountdir:
        if not a.hostdir:
            print("mountdir 需要 --hostdir（宿主目录）", file=sys.stderr)
            return 2
        md = os.path.join(a.script_dir, "stor-mountdir.sh")
        rc = run(["bash", md, "apply"],
                 env_extra={"CTID": a.ctid, "HOSTDIR": a.hostdir, "CTDIR": a.ctdir,
                            "VOL": a.vol, "SUBDIR": a.subdir, "MPIDX": "1"})
    return rc


def wait_ready(ctid, tries=60):
    """等容器起 + fnOS 服务链就绪（trim_main/trim_nginx active 且 Web 可达）。"""
    if not shutil.which("pct"):
        return False
    for _ in range(tries):
        if ct_running(ctid):
            r = subprocess.run(["pct", "exec", str(ctid), "--", "sh", "-c",
                                "systemctl is-active trim_main trim_nginx >/dev/null 2>&1 "
                                "&& curl -s -o /dev/null -m 5 http://127.0.0.1:5666/"],
                               capture_output=True, text=True)
            if r.returncode == 0:
                return True
        time.sleep(5)
    return False


def stage_smoke(a):
    # deploy/storage 阶段可能改动 conf（GPU devN / 存储 dev2），先重启应用配置再冒烟
    if ct_running(a.ctid):
        run(["pct", "reboot", str(a.ctid)])
    wait_ready(a.ctid)
    return run(["bash", os.path.join(TC, "fnos_deploy.sh"), "smoke", str(a.ctid)])


STAGES = {"overlay": stage_overlay, "patch": stage_patch, "image": stage_image,
          "verify": stage_verify, "release": stage_release, "deploy": stage_deploy,
          "storage": stage_storage, "smoke": stage_smoke}


def select_stages(a):
    if a.stages:
        chosen = [s.strip() for s in a.stages.split(",") if s.strip()]
        bad = [s for s in chosen if s not in STAGE_ORDER]
        if bad:
            raise SystemExit("未知阶段: %s（可用: %s）" % (bad, ",".join(STAGE_ORDER)))
        chosen = [s for s in STAGE_ORDER if s in chosen]
    elif a.from_ or a.to:
        lo = STAGE_ORDER.index(a.from_) if a.from_ else 0
        hi = STAGE_ORDER.index(a.to) if a.to else len(STAGE_ORDER) - 1
        chosen = STAGE_ORDER[lo:hi + 1]
    else:
        chosen = list(STAGE_ORDER)
        # 纯缺省全量：无 --base 则跳过 overlay（ISO 路径出厂 rootfs 已就绪）。
        # 显式点名（--stages/--from/--to 含 overlay）却没给 --base 时保留，
        # 由 missing_prereqs 报缺 --base。
        if "overlay" in chosen and not a.base:
            chosen = [s for s in chosen if s != "overlay"]
    return chosen


def resolve_version(a):
    """--version 缺省：读 rootfs 版本戳（V 前缀归一）；读不到返回 None（调用方必填报错）。"""
    if a.version:
        return a.version
    if a.rootfs and os.path.isdir(a.rootfs):
        got = fnos_patch.read_rootfs_version(a.rootfs)
        if got:
            return "V" + got.lstrip("Vv")
    return None


def resolve_patchset(a):
    """--patchset 缺省：随版本推导；无对应文件返回 None（patch 入口失败，不静默旧版）。"""
    if a.patchset:
        return a.patchset
    if a.version:
        cand = os.path.join(TC, "patches", "fnos-%s.json" % a.version.lstrip("Vv"))
        if os.path.isfile(cand):
            return cand
    return None


def do_run(a):
    stages = select_stages(a)
    a.version = resolve_version(a)
    if a.version is None and any(s in stages for s in ("overlay", "patch", "release")):
        print("ERROR: 读不到版本（--rootfs 无版本戳），请显式 --version", file=sys.stderr)
        return 2
    a.patchset = resolve_patchset(a)
    log("阶段: %s" % " -> ".join(stages))
    # 前置检查（失败即停，明确缺失）
    allmiss = {}
    for i, s in enumerate(stages):
        m = missing_prereqs(s, a, stages[:i])
        if m:
            allmiss[s] = m
    if allmiss:
        for s, m in allmiss.items():
            print("ERROR: 阶段 %s 缺前置：%s" % (s, "; ".join(m)), file=sys.stderr)
        return 2
    results = {}
    for s in stages:
        log("== 阶段 %s ==" % s)
        rc = STAGES[s](a)
        results[s] = rc
        if rc != 0:
            log("!! 阶段 %s 失败(rc=%d) —— 停止（失败即停）" % (s, rc))
            print(json.dumps({"stages": results, "ok": False}, ensure_ascii=False))
            return 1
        log("阶段 %s OK" % s)
    log("全部阶段完成")
    print(json.dumps({"stages": results, "ok": True}, ensure_ascii=False))
    return 0


def do_rollback(a):
    if not a.volstore or not a.storage:
        print("rollback 需要 --volstore 与 --storage", file=sys.stderr)
        return 2
    sm = os.path.join(a.script_dir, "stor-manage.sh")
    log("回退：专属存储")
    run(["bash", sm, "destroy"], env_extra={"CTID": a.ctid, "VOLSTORE": a.volstore,
                                           # rollback 本身就是显式的销毁意图，等价于确认
                                           "CONFIRM_DESTROY": "YES"})
    log("回退：容器与 rootfs 卷")
    rc = run(["bash", os.path.join(TC, "fnos_deploy.sh"), "uninstall", str(a.ctid),
              "--storage", a.storage])
    log("回退完成（只删专属资源）")
    return rc


def do_status(a):
    info = {}
    if a.out:
        info["release_dir"] = a.out
        info["image.raw"] = os.path.isfile(os.path.join(a.out, "image.raw"))
        info["verification.json"] = os.path.isfile(os.path.join(a.out, "verification.json"))
        rel = os.path.join(a.out, "release")
        info["release"] = os.listdir(rel) if os.path.isdir(rel) else []
    if a.ctid:
        info["container_running"] = ct_running(a.ctid)
    print(json.dumps(info, ensure_ascii=False, indent=2))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["run", "rollback", "status"])
    ap.add_argument("--rootfs", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--base", default=None,
                    help="deb-head 底座 rootfs 目录；给出则 run 自动先跑 overlay（ISO 路径不给）")
    ap.add_argument("--ota-version", default=None,
                    help="overlay 目标 OTA 版本（如 1.2.0800）；缺省回落到 --version")
    ap.add_argument("--debs-dir", default=None,
                    help="OTA .deb 包组缓存目录；缺省为 <out>/ota-debs（重跑跳过已下包）")
    ap.add_argument("--version", default=None,
                    help="fnOS 版本（如 V1.2.0800）；缺省读 --rootfs 版本戳，读不到则必填报错")
    ap.add_argument("--fs", default="ext4", choices=["ext4", "btrfs"])
    ap.add_argument("--size", default=12)
    ap.add_argument("--vztmpl", action="store_true")
    ap.add_argument("--zfs")
    ap.add_argument("--patchset", default=None)
    ap.add_argument("--shim", default=DEFAULT_SHIM)
    ap.add_argument("--no-version-check", action="store_true")
    ap.add_argument("--stages")
    ap.add_argument("--from", dest="from_", choices=STAGE_ORDER)
    ap.add_argument("--to", choices=STAGE_ORDER)
    ap.add_argument("--ctid", type=int)
    ap.add_argument("--storage", default=None)
    ap.add_argument("--volstore", default=None)
    ap.add_argument("--volfs", default="ext4", choices=["ext4", "btrfs", "zfs"])
    ap.add_argument("--mountdir", action="store_true")
    ap.add_argument("--hostdir", default=None)
    ap.add_argument("--ctdir", default="/mnt/hostdata")
    ap.add_argument("--vol", default="/vol2")
    ap.add_argument("--subdir", default="data")
    ap.add_argument("--deploy-image")
    ap.add_argument("--hostname", default="fnos-lxc")
    ap.add_argument("--script-dir", default=DEFAULT_SCRIPT_DIR)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    if a.out is None:
        a.out = "./release-%s" % (a.version or "unknown").lstrip("Vv")

    if a.cmd in ("run", "rollback") and os.geteuid() != 0:
        print("需要 root（用 sudo 运行）", file=sys.stderr)
        return 1
    if a.cmd == "run":
        return do_run(a)
    if a.cmd == "rollback":
        if not a.ctid:
            print("rollback 需要 --ctid", file=sys.stderr)
            return 2
        return do_rollback(a)
    return do_status(a)


if __name__ == "__main__":
    sys.exit(main())
