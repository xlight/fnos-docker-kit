#!/usr/bin/env python3
# ============================================================================
# fnos_pipeline.py — fnOS 镜像流水线的单一编排入口
#
# 阶段（默认按序全跑）：
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
#   fnos_pipeline.py run --rootfs <dir> --out <dir> [--version V1.2.0701]
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

DEFAULT_PS = os.path.join(TC, "patches", "fnos-1.2.0701.json")
# 公开仓脱敏：相对路径（不含任何宿主专有默认）
DEFAULT_SHIM = os.path.normpath(os.path.join(TC, "..", "scripts", "stor-mount-shim.sh"))
DEFAULT_SCRIPT_DIR = os.path.normpath(os.path.join(TC, "..", "scripts"))
STAGE_ORDER = ["patch", "image", "verify", "release", "deploy", "storage", "smoke"]


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
    if stage == "patch":
        if not (a.rootfs and os.path.isdir(a.rootfs)):
            miss.append("rootfs")
    elif stage == "image":
        if not (a.rootfs and os.path.isdir(a.rootfs)):
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
def stage_patch(a):
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


STAGES = {"patch": stage_patch, "image": stage_image, "verify": stage_verify,
          "release": stage_release, "deploy": stage_deploy, "storage": stage_storage,
          "smoke": stage_smoke}


def select_stages(a):
    if a.stages:
        chosen = [s.strip() for s in a.stages.split(",") if s.strip()]
        bad = [s for s in chosen if s not in STAGE_ORDER]
        if bad:
            raise SystemExit("未知阶段: %s（可用: %s）" % (bad, ",".join(STAGE_ORDER)))
        return [s for s in STAGE_ORDER if s in chosen]
    if a.from_ or a.to:
        lo = STAGE_ORDER.index(a.from_) if a.from_ else 0
        hi = STAGE_ORDER.index(a.to) if a.to else len(STAGE_ORDER) - 1
        return STAGE_ORDER[lo:hi + 1]
    return list(STAGE_ORDER)


def do_run(a):
    stages = select_stages(a)
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
    run(["bash", sm, "destroy"], env_extra={"CTID": a.ctid, "VOLSTORE": a.volstore})
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
    ap.add_argument("--version", default="V1.2.0701")
    ap.add_argument("--fs", default="ext4", choices=["ext4", "btrfs"])
    ap.add_argument("--size", default=12)
    ap.add_argument("--vztmpl", action="store_true")
    ap.add_argument("--zfs")
    ap.add_argument("--patchset", default=DEFAULT_PS)
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
