#!/usr/bin/env python3
"""build-issue.py —— 构建失败 Issue：按**失败阶段**分类并如实报告（design D10）。

为什么要有它：旧逻辑是"补丁集门禁通过 + build 失败 ⇒ 一定是 patchset miss"，
于是 1.2.1000 那次 `fnos_patch.py apply` 里 `open(zpool_path).read()` 的
UnicodeDecodeError（补丁已 37/37 applied）被报成"补丁失配"，正文却写着
`37/37 ok`。本脚本按**失败实际发生的阶段**分类：

    补丁检查   → 补丁失配（需重锚）
    补丁施加   → 补丁施加失败（工具/布局问题，**不是**补丁失配）
    镜像生成   → 镜像生成失败
    镜像校验   → 镜像校验失败
    推送       → 推送失败
    依赖/环境/磁盘/下载/解包/deb → 基础设施受阻

查重键 =（版本, 类型）：同一版本同一类型复用同一条 Issue，不每次刷新。
正文只含结果型内容（per-site 报告 + 日志尾部 + run 链接），不含推导方法。

用法：
  python3 build-issue.py --version <ver> --channel <iso|ota> --tag <tag>
                         --stage <阶段> [--run-url <url>]
                         [--report <patch-report.json>] [--log-tail <file>]
                         [--repo <owner/name>]
退出码：0 成功；1 参数错误。
"""
import argparse
import json
import os
import subprocess
import sys

# 阶段 → (Issue 类型前缀, 说明, 下一步)
STAGE_TYPES = {
    "补丁检查": ("补丁失配",
                "补丁集在新版 rootfs 上未全命中：需按维护者的重定基流程重锚（**人工**，不自动猜；公开仓不暴露推导方法）。",
                ["为该版本重定基签名（人工流程；公开仓不暴露推导方法）", "本地演练后再触发构建"]),
    "补丁施加": ("补丁施加失败",
                "补丁检查**已全绿**，失败发生在施加阶段——**不是补丁失配**，通常是工具或 rootfs 布局问题。",
                ["看正文日志尾部定位抛异常的位置", "修工具后重跑；补丁集本身可能无需重锚"]),
    "镜像生成": ("镜像生成失败",
                "补丁已施加，失败发生在镜像生成（mkraw）阶段。",
                ["看日志尾部的 mkraw 报错", "确认磁盘空间与镜像大小参数"]),
    "镜像校验": ("镜像校验失败",
                "镜像已生成，但 fsck / 补丁在位自检未通过。",
                ["看日志尾部的自检报错", "重跑构建确认是否偶发"]),
    "推送": ("推送失败",
             "镜像已构建成功，失败发生在推送 Docker Hub。",
             ["确认 DOCKERHUB_TOKEN/USER 有效", "重跑推送（镜像构建可复用）"]),
    "构建依赖缺失": ("基础设施受阻", "公开树缺构建依赖文件（构建工具自报的依赖集合不完整）。",
                 ["同步公开仓（sync-public.sh）补齐依赖", "或修清单"]),
    "构建环境": ("基础设施受阻", "构建环境缺工具或装包失败。",
               ["检查 apt 安装日志", "修 toolchain/deps.sh"]),
    "磁盘不足": ("基础设施受阻", "runner 可用磁盘低于断言阈值（需 ≥25G）。",
               ["换大 runner 或清理缓存"]),
    "ISO 下载": ("基础设施受阻", "官方 ISO 下载失败（直链可能过期或被拦）。",
               ["重新取签名 URL（check-iso-update.py --signed）", "手工传 iso_url 重跑"]),
    "ISO 解包": ("基础设施受阻", "ISO 载荷解包失败。",
               ["校验 ISO md5", "换官方 ISO 重跑"]),
    "deb 物化": ("基础设施受阻", "deb 通道底座物化或 .deb 覆盖失败。",
               ["确认底座 tag 存在", "确认 .deb 签名与版本匹配"]),
}
# 基础设施类共用同一个 Issue 类型（避免同一版本因不同环境问题开多条）
INFRA_TYPES = {"构建依赖缺失", "构建环境", "磁盘不足", "ISO 下载", "ISO 解包", "deb 物化"}


def log(msg):
    print("[build-issue] %s" % msg, file=sys.stderr, flush=True)


def gh(args, dry_run=False):
    cmd = ["gh"] + args
    if dry_run:
        log("DRY-RUN: %s" % " ".join(cmd))
        return 0, ""
    env = dict(os.environ)
    env.setdefault("GH_TOKEN", env.get("GITHUB_TOKEN", ""))
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        log("gh %s 失败: %s" % (args[0] if args else "?", (p.stderr or "").strip()[:300]))
    return p.returncode, p.stdout


def report_summary(path):
    """从 patch-report.json 提取 per-site 摘要（通过数/总数 + 失败站点）。"""
    if not path or not os.path.isfile(path):
        return None
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception:
        return None
    items = d.get("items") or d.get("patches") or []
    ok = ("ready", "already", "applied", "ok")
    bad = [i for i in items if str(i.get("status", "")).split("(")[0] not in ok]
    return {"total": len(items), "ok": len(items) - len(bad),
            "bad": ["%s -> %s" % (i.get("id"), i.get("status")) for i in bad],
            "sha256": d.get("patchset_sha256")}


def find_issue(repo, ver, channel, type_prefix):
    """查同（版本, 类型）的既有 Issue（标题前缀匹配，避免与观察单元的 Issue 混淆）。"""
    prefix = "%s: %s (%s)" % (type_prefix, ver, channel)
    rc, out = gh(["issue", "list", "--repo", repo, "--state", "all",
                  "--search", '"%s" in:title' % prefix, "--json", "number,title,state,body",
                  "--limit", "50"])
    if rc != 0 or not out.strip():
        return None
    try:
        items = json.loads(out)
    except Exception:
        return None
    for it in items:
        if it.get("title", "").startswith(prefix):
            return it
    return None


def build_body(ver, channel, tag, stage, type_prefix, desc, next_steps, summary, tail, run_url):
    lines = ["## fnOS %s（%s 通道）构建失败：%s" % (ver, channel, type_prefix), ""]
    lines.append("- 失败阶段：**%s**" % stage)
    lines.append("- 镜像 tag：`%s`" % tag)
    lines.append("- 分类：`%s`" % type_prefix)
    lines.append("")
    lines.append(desc)
    lines.append("")
    if summary:
        lines.append("### 补丁检查报告")
        lines.append("")
        lines.append("- 通过 **%d/%d**" % (summary["ok"], summary["total"]))
        if summary["sha256"]:
            lines.append("- 补丁集 sha256：`%s`" % summary["sha256"])
        if summary["bad"]:
            lines.append("- 未命中站点：")
            for b in summary["bad"][:20]:
                lines.append("  - `%s`" % b)
            if len(summary["bad"]) > 20:
                lines.append("  - …等 %d 条" % (len(summary["bad"]) - 20))
        else:
            lines.append("- 无未命中站点（失败不在补丁检查阶段）")
        lines.append("")
    if tail:
        lines.append("### 日志尾部")
        lines.append("")
        lines.append("```")
        lines.append(tail.rstrip()[:6000])
        lines.append("```")
        lines.append("")
    if run_url:
        lines.append("完整运行：%s" % run_url)
        lines.append("")
    lines.append("### 下一步")
    lines.append("")
    for i, s in enumerate(next_steps, 1):
        lines.append("%d. %s" % (i, s))
    lines.append("")
    lines.append("<!-- managed-by: build-issue.py（同一版本同一类型复用同一条） -->")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--tag", default="")
    ap.add_argument("--stage", required=True)
    ap.add_argument("--run-url", default="")
    ap.add_argument("--report", default="")
    ap.add_argument("--log-tail", default="")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "xlight/fnos-docker-kit"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    # 通道名统一大写（ISO / OTA）：与观察单元的 Issue 标题同一词汇
    channel = {"iso": "ISO", "deb": "OTA", "ota": "OTA"}.get(a.channel.lower(), a.channel)
    stage = a.stage
    if stage in INFRA_TYPES:
        type_prefix, desc, steps = STAGE_TYPES[stage]
    elif stage in STAGE_TYPES:
        type_prefix, desc, steps = STAGE_TYPES[stage]
    else:
        type_prefix = "构建失败"
        desc = "失败阶段未分类（%s）。" % stage
        steps = ["看日志尾部定位问题", "必要时把该阶段补进 build-issue.py 的分类表"]
    if stage == "缺补丁集":
        # 缺补丁集由观察单元的「待 rebase」Issue 维护，这里不重复开一条
        log("缺补丁集：交由观察单元/watch-issue.py 维护「待 rebase」Issue，不在此重复开 Issue")
        return 0

    summary = report_summary(a.report)
    tail = ""
    if a.log_tail and os.path.isfile(a.log_tail):
        tail = open(a.log_tail, encoding="utf-8", errors="replace").read()
    title = "%s: %s (%s)" % (type_prefix, a.version, channel)
    body = build_body(a.version, channel, a.tag or a.version, stage, type_prefix,
                       desc, steps, summary, tail, a.run_url)

    existing = find_issue(a.repo, a.version, channel, type_prefix)
    if existing is None:
        rc, _ = gh(["issue", "create", "--repo", a.repo, "--title", title, "--body", body], a.dry_run)
        log("created: %s" % title)
    else:
        num = existing.get("number")
        gh(["issue", "edit", str(num), "--repo", a.repo, "--title", title, "--body", body], a.dry_run)
        log("updated: #%s %s" % (num, title))
    return 0


if __name__ == "__main__":
    sys.exit(main())
