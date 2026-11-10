#!/usr/bin/env python3
"""validate_patchset.py —— 补丁集的字节级取证（design D15 三态）。

三态：
  强证据  官方 ISO 出厂件（真出厂件）
  中证据  底座镜像 + **全量** OTA 包 overlay（≈真容器；需交叉核对）
  无证据  两者都不可用 → 待基材（调用方记 state/pending/<ver>.json，每日重试）

产出：
  --out         字节级证据 JSON（校验环境来源 / 逐站命中数 / 指纹摘要 / 交叉核对结论）
  --fingerprints 出厂指纹 JSON（state=factory，供覆盖度矩阵；只作 Release 资产，**不进仓树**）

退出码：0 取证成功；3 无可用基材（待基材）；4 补丁集不存在；5 取证过程失败。
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def find_toolchain():
    """定位 toolchain 根目录（里面有 aobpatch.py / fnos_rootfs.py / fnos_iso.py）。

    脚本在私有仓是 toolchain/ci-public/validate_patchset.py，在公开仓被映射到
    .github/scripts/validate_patchset.py —— 两种布局都要能找到 toolchain。
    """
    d = HERE
    for _ in range(5):
        if os.path.isfile(os.path.join(d, "aobpatch.py")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    # 兜底：公开仓里 toolchain/ 与 .github/ 平级
    return os.path.join(os.path.dirname(HERE), "toolchain")


TOOLCHAIN = find_toolchain()


def log(msg):
    print("[validate] %s" % msg, file=sys.stderr, flush=True)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def sha256_file(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def pick_base_image(version, repo="xlight/fnos-dockermode"):
    """底座镜像 = Hub 上数字版本**严格低于**目标版本的最高 tag（数字相同优先无 -ota）。

    没有底座 → 返回 ""（deb-head 路径不可用 → 待基材）。
    """
    import re
    import urllib.request
    try:
        req = urllib.request.Request("https://hub.docker.com/v2/repositories/%s/tags?page_size=100"
                                     % repo, headers={"User-Agent": "fnos-validate/1.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception as e:
        log("Hub 查询失败（不判底座）: %s" % e)
        return ""
    tgt = tuple(int(x) for x in re.findall(r"\d+", version))
    best, bestk = "", None
    for t in data.get("results", []):
        name = t.get("name", "")
        v = tuple(int(x) for x in re.findall(r"\d+", name))
        if not v or v >= tgt:
            continue
        k = (v, 0 if not name.endswith("-ota") else 1)
        if bestk is None or k > bestk:
            best, bestk = name, k
    return best


def build_rootfs(version, base, debs, workdir):
    """按 iso → deb-head 的顺序构造 rootfs；返回 (rootfs, environment) 或 (None, env)。"""
    out = os.path.join(workdir, "factory")
    r = run([sys.executable, os.path.join(TOOLCHAIN, "fnos_rootfs.py"), "iso",
             "--version", version, "--out", out])
    if r.returncode == 0 and os.path.isdir(out):
        return out, {"source": "iso", "strength": "strong",
                     "details": {"version": version, "tool": "fnos_rootfs.py iso"}}
    log("ISO 路径不可用（rc=%d）→ 试 deb-head" % r.returncode)
    if not base:
        base = pick_base_image(version)
        log("自动选底座镜像: %s" % (base or "<无>"))
    r = run([sys.executable, os.path.join(TOOLCHAIN, "fnos_rootfs.py"), "deb-head",
             "--version", version, "--base", base or "", "--out", out]
            + (["--debs", debs] if debs else []))
    if r.returncode == 0 and os.path.isdir(out):
        return out, {"source": "deb-head", "strength": "medium",
                     "details": {"version": version, "base_image": base,
                                 "tool": "fnos_rootfs.py deb-head"}}
    return None, {"source": "none", "strength": "none",
                  "details": {"reason": (r.stderr or r.stdout or "")[-300:]}}


def check_patchset(rootfs, patchset_path, report_path):
    """aobpatch check（best-effort：单站失配如实记录，不让整轮取证崩掉）。"""
    r = run([sys.executable, os.path.join(TOOLCHAIN, "aobpatch.py"), "check",
             "--rootfs", rootfs, "--patchset", patchset_path,
             "--report", report_path, "--best-effort"])
    if not os.path.isfile(report_path):
        log("aobpatch check 没产出报告: %s" % ((r.stderr or r.stdout) or "")[:200])
        return None
    return json.load(open(report_path, encoding="utf-8"))


def sites_of(report):
    """报告里的逐站结果 → {total, ready, failed[]}（ready = applied/already/ready）。"""
    items = report.get("patches") or report.get("items") or []
    ok_states = ("applied", "already", "ready", "ready-unverified")
    failed = []
    for it in items:
        st = str(it.get("status", "")).split("(")[0]
        if st not in ok_states:
            failed.append({"id": it.get("id"), "status": it.get("status"),
                           "reason": (it.get("reason") or "")[:160]})
    return {"total": len(items), "ready": len(items) - len(failed), "failed": failed}


def cross_check(repo, version, fp_files, tierb_file=""):
    """与容器自报指纹（tier-B）交叉核对：校验环境像不像真容器。

    tier-B 不进公开索引、不参与 ready/partial 判定；这里只用来给**证据定强度**。
    来源优先用 --tierb 指定的本地文件（容器自报，宿主侧采集）；没有则看仓里的
    state/tierb/<ver>.json；都没有 → not-compared。
    """
    p = tierb_file or os.path.join(repo, "state", "tierb", "%s.json" % version)
    if not p or not os.path.isfile(p):
        return {"status": "not-compared", "matched": 0, "total": 0, "diff": []}
    try:
        tb = json.load(open(p, encoding="utf-8")).get("files") or {}
    except Exception:
        return {"status": "not-compared", "matched": 0, "total": 0, "diff": []}
    matched, diff = 0, []
    for rel, sha in sorted((fp_files or {}).items()):
        if tb.get(rel) == sha:
            matched += 1
        else:
            diff.append(rel)
    total = len(fp_files or {})
    return {"status": "equivalent" if total and not diff else "divergent",
            "matched": matched, "total": total, "diff": diff}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="公开仓检出目录")
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", required=True, help="字节级证据 JSON 输出路径")
    ap.add_argument("--fingerprints", default="", help="出厂指纹 JSON 输出路径")
    ap.add_argument("--base", default="", help="deb-head 底座镜像 tag")
    ap.add_argument("--debs", default="", help="已下载的 OTA 包目录")
    ap.add_argument("--workdir", default="", help="rootfs 工作目录（默认临时目录）")
    ap.add_argument("--tierb", default="", help="容器自报指纹文件（tier-B；本地采集，不进公开索引）")
    a = ap.parse_args()

    ps_path = os.path.join(a.repo, "toolchain", "patches", "fnos-%s.json" % a.version)
    if not os.path.isfile(ps_path):
        log("补丁集不存在: %s" % ps_path)
        return 4
    ps_sha = sha256_file(ps_path)

    tmp = a.workdir or tempfile.mkdtemp(prefix="fnos-validate-")
    os.makedirs(tmp, exist_ok=True)
    try:
        rootfs, env = build_rootfs(a.version, a.base, a.debs, tmp)
        if not rootfs:
            log("无可用基材（iso 与 deb-head 都不行）")
            ev = {"version": a.version, "patchset": "fnos-%s.json" % a.version,
                  "patchset_sha256": ps_sha, "environment": env,
                  "sites": {"total": 0, "ready": 0, "failed": []},
                  "status": "unavailable", "generated_at": now_iso()}
            os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
            with open(a.out, "w", encoding="utf-8") as f:
                json.dump(ev, f, ensure_ascii=False, indent=2)
            return 3

        report_path = os.path.join(tmp, "patch-report.json")
        report = check_patchset(rootfs, ps_path, report_path)
        if report is None:
            return 5
        sites = sites_of(report)

        fp_files = {}
        fp_path = a.fingerprints
        if fp_path:
            r = run([sys.executable, os.path.join(HERE, "fingerprints.py"), "extract",
                     "--report", report_path, "--version", a.version, "--out", fp_path,
                     "--state", "factory"])
            if r.returncode == 0 and os.path.isfile(fp_path):
                fp_files = json.load(open(fp_path, encoding="utf-8")).get("files") or {}

        cc = cross_check(a.repo, a.version, fp_files, a.tierb)
        if cc["status"] == "divergent" and env.get("strength") == "strong":
            # 强证据环境与真容器不同构 → 降级（以真容器为准）
            env["strength"] = "medium"
            env.setdefault("details", {})["downgraded_by"] = "cross-check divergent"

        ev = {"version": a.version, "patchset": "fnos-%s.json" % a.version,
              "patchset_sha256": ps_sha, "environment": env, "sites": sites,
              "fingerprints": {"file": os.path.basename(fp_path) if fp_path else "",
                               "count": len(fp_files), "state": "factory"},
              "cross_check": cc, "generated_at": now_iso(),
              "status": "ready" if sites["ready"] == sites["total"] and sites["total"] else "partial"}
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(ev, f, ensure_ascii=False, indent=2)
        log("取证完成: %s (%d/%d 站命中, 环境=%s/%s)" %
            (a.version, sites["ready"], sites["total"], env.get("source"), env.get("strength")))
        return 0
    finally:
        if not a.workdir:
            subprocess.run(["rm", "-rf", tmp])


if __name__ == "__main__":
    sys.exit(main())
