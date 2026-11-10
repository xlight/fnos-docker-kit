#!/usr/bin/env python3
"""watch-issue.py —— 观察单元的 Issue 生命周期维护（design D10）。

定时检测发现新版本后，**不自动构建**，而是把状态变成一条持续可见的 Issue：

    待 rebase: <ver> (<channel>)   公开仓里还没有该版本的补丁集
    可构建:   <ver> (<channel>)   补丁集已就绪，但镜像还没发出来

生命周期规则：
  * 查重键 =（版本, 通道）；同一件事只有一条 Issue，状态变化时**改**它，不新建。
  * 状态未变 → 不动（不做每日评论）。
  * Issue 被误关且状态未解决 → 自动重开。
  * 状态已解决（补丁集就绪 **且** Hub 上已有对应镜像 tag）→ 自动关闭并写明依据。
  * Docker Hub 查询失败 → **保守**：既不判"已发布"（免得误关），也不判"未发布"
    （免得误报可构建）；保持 Issue 原状并告警。

用法：
  python3 watch-issue.py --detect <detect.json> [--index <index.json>]
                         [--repo <owner/name>] [--hub-repo <owner/name>]
                         [--dry-run]
退出码：0 正常（含"Hub 不可达→保守跳过"）；1 参数/数据错误。
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# 通道 → (镜像 tag 后缀, 说明)
CHANNELS = {
    "ISO": "",       # 官方 ISO 分支：tag = 版本号
    "OTA": "-ota",  # OTA/deb 分支：tag = 版本号-ota
}

STATE_REBASE = "待 rebase"
STATE_READY = "可构建"
STATE_DONE = "已完成"


def log(msg):
    print("[watch-issue] %s" % msg, file=sys.stderr, flush=True)


def gh(args, dry_run=False):
    """跑 gh CLI；dry-run 时只打印不执行。返回 (rc, stdout)。"""
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


def hub_tags(hub_repo, timeout=30):
    """列 Docker Hub 的 tag 名。失败返回 None（= 不可知，调用方必须保守处理）。

    测试钩子：FNOS_HUB_TAGS_FILE 指向一个 JSON 文件（["tag", ...] 或
    {"results":[{"name":...}]}）；文件不存在 = 模拟 Hub 不可达。
    """
    mock = os.environ.get("FNOS_HUB_TAGS_FILE")
    if mock:
        try:
            with open(mock, encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, list):
                return list(d)
            return [t.get("name") for t in d.get("results", [])]
        except Exception as e:
            log("Docker Hub 查询失败（mock %s）：%s" % (mock, e))
            return None
    url = "https://hub.docker.com/v2/repositories/%s/tags?page_size=100" % hub_repo
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "fnos-watch/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8"))
        return [t.get("name") for t in data.get("results", [])]
    except Exception as e:
        log("Docker Hub 查询失败（%s）：%s" % (hub_repo, e))
        return None


def vkey(v):
    import re
    try:
        return tuple(int(x) for x in re.findall(r"\d+", str(v)))
    except Exception:
        return (0,)


def pick_base_tag(tags, target):
    """底座 = 数字版本严格低于目标的最高 tag（数字相同优先无 -ota）。"""
    best, bestk = None, None
    tk = vkey(target)
    for n in tags or []:
        v = vkey(n)
        if not v or not (v < tk):
            continue
        k = (v, 0 if not n.endswith("-ota") else 1)
        if bestk is None or k > bestk:
            best, bestk = n, k
    return best


def classify(ver, channel, index_versions, tags):
    """算出该（版本, 通道）的目标状态。

    返回 (state, detail_dict)；tags=None 表示 Hub 不可知 → state=None（保守跳过）。
    """
    detail = {"version": ver, "channel": channel}
    entry = (index_versions or {}).get(ver)
    ready = bool(entry) and entry.get("status") == "ready"
    detail["patchset"] = entry.get("patchset") if entry else None
    detail["patchset_ready"] = ready
    detail["patchset_ready_counts"] = ("%s/%s" % (entry.get("ready"), entry.get("total"))) if entry else None
    if tags is None:
        detail["hub"] = "unknown"
        return None, detail
    tag = "%s%s" % (ver, CHANNELS[channel])
    detail["tag"] = tag
    detail["image_exists"] = tag in tags
    base = pick_base_tag(tags, ver)
    detail["base_tag"] = base
    if detail["image_exists"]:
        detail["hub"] = "ok"
        return STATE_DONE, detail
    detail["hub"] = "ok"
    if ready:
        return STATE_READY, detail
    return STATE_REBASE, detail


def title_for(state, ver, channel):
    return "%s: %s (%s)" % (state, ver, channel)


def body_for(state, detail, detect):
    """Issue 正文：状态 + 证据 + 下一步（可判定，不含推导方法）。"""
    ver = detail["version"]
    ch = detail["channel"]
    cur = (detect.get("current") or {})
    iso_url = cur.get("url") or ""
    iso_hash = cur.get("hash") or ""
    lines = []
    lines.append("## fnOS %s（%s 通道）状态：%s" % (ver, ch, state))
    lines.append("")
    lines.append("- 补丁集：%s" % (
        ("`%s`（ready %s）" % (detail["patchset"], detail["patchset_ready_counts"]))
        if detail.get("patchset") else "**缺**（需要人工 rebase 出 `toolchain/patches/fnos-%s.json`）" % ver))
    lines.append("- 镜像 tag：%s" % (
        "`%s`（已存在）" % detail["tag"] if detail.get("image_exists")
        else ("`%s`（**未发布**）" % detail["tag"] if detail.get("hub") == "ok" else "未知（Hub 查询失败）")))
    if ch == "OTA":
        lines.append("- deb 分支底座：%s" % (
            "`%s`" % detail["base_tag"] if detail.get("base_tag") else "**无**（Hub 上没有数字版本更低的镜像）"))
    if iso_url and ch == "ISO":
        lines.append("- 官方 ISO：`%s`" % iso_url)
        lines.append("- 官方 md5：`%s`" % iso_hash)
    lines.append("")
    if state == STATE_REBASE:
        lines.append("### 下一步")
        lines.append("")
        lines.append("1. 为 `%s` 重定基签名（人工流程；公开仓不暴露推导方法）" % ver)
        lines.append("2. 本地演练：`sudo bash toolchain/rehearse-build.sh --version %s`" % ver)
        lines.append("3. 发布补丁集并触发构建：`bash toolchain/publish.sh --patchset %s --image %s`" % (ver, ver))
    elif state == STATE_READY:
        lines.append("### 下一步")
        lines.append("")
        lines.append("补丁集已就绪，**构建需显式声明**（检测不会自动构建）：")
        lines.append("")
        lines.append("- 发布并构建：`bash toolchain/publish.sh --patchset %s --image %s`" % (ver, ver))
        lines.append("- 或手工触发：`gh workflow run public-ci.yml -f version=%s`" % ver)
    elif state == STATE_DONE:
        lines.append("### 已完成")
        lines.append("")
        lines.append("补丁集已发布，镜像 tag 已存在；本条自动关闭。")
    lines.append("")
    lines.append("<!-- managed-by: watch-issue.py（观察单元；状态未变时不会重复更新） -->")
    return "\n".join(lines)


def find_issue(repo, ver, channel):
    """按（版本, 通道）查已有 Issue（标题前缀匹配；类型变了也复用同一条）。"""
    prefix = "%s (%s)" % (ver, channel)
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
        t = it.get("title", "")
        # 只认观察单元自己管理的两类标题（构建失败类由 build-issue.py 管，互不干扰）
        if not (t.startswith(STATE_REBASE + ": ") or t.startswith(STATE_READY + ": ")):
            continue
        if prefix in t:
            return it
    return None


def parse_body_state(body):
    """从正文里解析上次记录的状态（用于"状态未变就不动"）。"""
    for line in (body or "").splitlines():
        if line.startswith("## fnOS "):
            if "状态：" in line:
                return line.split("状态：", 1)[1].strip()
    return None


def reconcile(ver, channel, state, detail, detect, repo, dry_run=False):
    """把一条 Issue 推到目标状态。返回动作描述。"""
    if state is None:
        return "skip-hub-unknown"
    existing = find_issue(repo, ver, channel)
    title = title_for(state, ver, channel)
    body = body_for(state, detail, detect)
    if existing is None:
        if state == STATE_DONE:
            return "none"  # 没有 issue 且已完成 → 无需建
        rc, _ = gh(["issue", "create", "--repo", repo, "--title", title, "--body", body], dry_run)
        return "created" if rc == 0 else "create-failed"
    num = existing.get("number")
    was_state = parse_body_state(existing.get("body"))
    if state == STATE_DONE:
        if existing.get("state") == "OPEN":
            gh(["issue", "close", str(num), "--repo", repo,
                "--comment", "自动关闭：补丁集已就绪且 Hub 上已有 `%s` 镜像 tag。" % detail.get("tag")], dry_run)
            return "closed"
        return "already-closed"
    # 状态未解决
    if existing.get("state") == "CLOSED":
        gh(["issue", "reopen", str(num), "--repo", repo,
            "--comment", "自动重开：状态仍未解决（%s）。" % state], dry_run)
        return "reopened"
    if was_state == state and existing.get("title") == title:
        return "unchanged"
    gh(["issue", "edit", str(num), "--repo", repo, "--title", title, "--body", body], dry_run)
    return "updated"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detect", required=True, help="check-iso-update.py 的 JSON 输出")
    ap.add_argument("--index", default="toolchain/patches/index.json")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "xlight/fnos-docker-kit"))
    ap.add_argument("--hub-repo", default=os.environ.get("DOCKERHUB_REPO", "xlight/fnos-dockermode"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    try:
        detect = json.load(open(a.detect, encoding="utf-8"))
    except Exception as e:
        log("读 detect JSON 失败: %s" % e)
        return 1
    try:
        index = json.load(open(a.index, encoding="utf-8"))
    except Exception:
        index = {}
    versions = index.get("versions") or {}

    tags = hub_tags(a.hub_repo)
    if tags is None:
        log("Docker Hub 不可达 → 保守处理：不关闭、不新建、不改状态，仅告警")
        print("::warning::Docker Hub 查询失败，观察单元未改变任何 Issue 状态")

    # 通道名统一大写（ISO / OTA）
    def _ch(c):
        return {"iso": "ISO", "deb": "OTA", "ota": "OTA"}.get(str(c).lower(), c)

    targets = []
    cur = (detect.get("current") or {}).get("version")
    if cur:
        targets.append((cur, "ISO"))
    ota = (detect.get("ota") or {}).get("version")
    if ota and ota != cur:
        targets.append((ota, "OTA"))

    for ver, ch in targets:
        state, detail = classify(ver, ch, versions, tags)
        try:
            action = reconcile(ver, ch, state, detail, detect, a.repo, a.dry_run)
        except Exception as e:
            log("处理 %s(%s) 失败: %s" % (ver, ch, e))
            continue
        log("%s(%s): state=%s action=%s" % (ver, ch, state, action))
    return 0


if __name__ == "__main__":
    sys.exit(main())
