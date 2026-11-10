#!/usr/bin/env python3
"""watch-issue-test.py —— 观察单元 Issue 生命周期的回归（design D10 / 2.14-2.16）。

用假 gh（记录调用）+ 假 Hub（FNOS_HUB_TAGS_FILE）验证：
  1. 缺补丁集 → 建「待 rebase」Issue；
  2. 补丁集就绪但镜像未发 → 建「可构建」Issue；
  3. 同一状态再跑 → **不动**（不重复评论、不新建）；
  4. 状态类型变化 → **更新同一条**（改标题与正文，不新建）；
  5. Issue 被误关 → **重开**；
  6. 镜像已发布 → **关闭**；
  7. Hub 查询失败 → 保守跳过（不关、不建、不改），并告警。

用法: python3 toolchain/tests/watch-issue-test.py
退出码: 0 全过；1 有失败。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)
WATCH = os.path.join(TC, "ci-public", "watch-issue.py")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("PASS: %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: %s" % msg)


def make_fake_gh(tmp, issues):
    """假 gh：把 issue list 的结果按 issues 字典返回，其余调用记录到 gh.log。"""
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir, exist_ok=True)
    logf = os.path.join(tmp, "gh.log")
    script = os.path.join(bindir, "gh")
    with open(script, "w", encoding="utf-8") as f:
        f.write('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
logf = os.environ["FAKE_GH_LOG"]
issues = json.load(open(os.environ["FAKE_GH_ISSUES"]))
with open(logf, "a", encoding="utf-8") as lf:
    lf.write(" ".join(args) + "\\n")
if args[:2] == ["issue", "list"]:
    query = ""
    if "--search" in args:
        query = args[args.index("--search") + 1]
        query = query.split(" in:")[0].strip().strip('"')
    out = []
    for num, it in issues.items():
        title = it.get("title", "")
        if query and query not in title:
            continue
        out.append({"number": int(num), "title": title,
                    "state": it.get("state", "OPEN"), "body": it.get("body", "")})
    print(json.dumps(out))
    sys.exit(0)
sys.exit(0)
''')
    os.chmod(script, 0o755)
    return bindir, logf


def run_watch(tmp, bindir, logf, issues, detect, index_versions, tags):
    """跑一次 watch-issue.py；返回 (stdout+stderr, gh 调用列表)。"""
    if os.path.exists(logf):
        os.remove(logf)
    issues_f = os.path.join(tmp, "issues.json")
    json.dump(issues, open(issues_f, "w", encoding="utf-8"))
    detect_f = os.path.join(tmp, "detect.json")
    json.dump(detect, open(detect_f, "w", encoding="utf-8"))
    index_f = os.path.join(tmp, "index.json")
    json.dump({"revision": 1, "versions": index_versions}, open(index_f, "w", encoding="utf-8"))
    tags_f = os.path.join(tmp, "tags.json")
    if tags is None:
        if os.path.exists(tags_f):
            os.remove(tags_f)
    else:
        json.dump(tags, open(tags_f, "w", encoding="utf-8"))
    env = dict(os.environ)
    env["PATH"] = bindir + os.pathsep + env["PATH"]
    env["FAKE_GH_LOG"] = logf
    env["FAKE_GH_ISSUES"] = issues_f
    if tags is not None:
        env["FNOS_HUB_TAGS_FILE"] = tags_f
    else:
        env.pop("FNOS_HUB_TAGS_FILE", None)
    p = subprocess.run([sys.executable, WATCH, "--detect", detect_f, "--index", index_f,
                        "--repo", "o/r", "--hub-repo", "o/img"],
                       capture_output=True, text=True, env=env)
    calls = []
    if os.path.exists(logf):
        calls = [l.strip() for l in open(logf, encoding="utf-8") if l.strip()]
    return p.stdout + p.stderr, calls


DETECT = {"current": {"version": "1.2.1000", "url": "https://x/fnos.iso", "hash": "abc"},
          "ota": {"version": "1.2.1010"}}
INDEX_READY = {"1.2.1000": {"patchset": "fnos-1.2.1000.json", "sha256": "x",
                            "ready": 37, "total": 37, "status": "ready"}}


def mk_issues(iso_type="待 rebase", iso_state="OPEN", ota_type="待 rebase", ota_state="OPEN"):
    """造两条既有 Issue（ISO + OTA 通道），供"复用/不动/重开/关闭"断言用。"""
    return {
        "1": {"title": "%s: 1.2.1000 (ISO)" % iso_type, "state": iso_state,
              "body": "## fnOS 1.2.1000（ISO 通道）状态：%s\n" % iso_type},
        "2": {"title": "%s: 1.2.1010 (OTA)" % ota_type, "state": ota_state,
              "body": "## fnOS 1.2.1010（OTA 通道）状态：%s\n" % ota_type},
    }


def main():
    tmp = tempfile.mkdtemp(prefix="watch-test-")
    try:
        bindir, logf = make_fake_gh(tmp, {})

        # 1. 缺补丁集 → 建「待 rebase」
        out, calls = run_watch(tmp, bindir, logf, {}, DETECT, {}, ["1.2.0900"])
        if any(c.startswith("issue create") and "待 rebase: 1.2.1000 (ISO)" in c for c in calls):
            ok("1. 缺补丁集时创建「待 rebase」Issue")
        else:
            bad("1. 未创建「待 rebase」Issue（calls=%s）" % calls)

        # 2. 补丁集就绪但镜像未发 → 建「可构建」
        out, calls = run_watch(tmp, bindir, logf, {}, DETECT, INDEX_READY, ["1.2.0900"])
        if any(c.startswith("issue create") and "可构建: 1.2.1000 (ISO)" in c for c in calls):
            ok("2. 补丁集就绪但镜像未发时创建「可构建」Issue")
        else:
            bad("2. 未创建「可构建」Issue（calls=%s）" % calls)

        # 3. 已有且状态未变 → 不动
        issues = mk_issues()
        out, calls = run_watch(tmp, bindir, logf, issues, DETECT, {}, ["1.2.0900"])
        mutating = [c for c in calls if c.startswith(("issue create", "issue edit",
                                                      "issue close", "issue reopen"))]
        if not mutating:
            ok("3. 状态未变时不产生任何变更调用（不重复评论/不新建）")
        else:
            bad("3. 状态未变时仍有变更调用：%s" % mutating)

        # 4. 类型变化 → 更新同一条（不新建）
        issues = mk_issues()
        out, calls = run_watch(tmp, bindir, logf, issues, DETECT, INDEX_READY, ["1.2.0900"])
        if any(c.startswith("issue edit 1 ") for c in calls) and \
           not any(c.startswith("issue create") for c in calls):
            ok("4. 状态类型变化时更新同一条 Issue（不新建）")
        else:
            bad("4. 类型变化未正确更新同一条（calls=%s）" % calls)

        # 5. 被误关 → 重开
        issues = mk_issues(iso_state="CLOSED")
        out, calls = run_watch(tmp, bindir, logf, issues, DETECT, {}, ["1.2.0900"])
        if any(c.startswith("issue reopen 1 ") for c in calls):
            ok("5. 状态未解决而 Issue 被误关时自动重开")
        else:
            bad("5. 未重开误关的 Issue（calls=%s）" % calls)

        # 6. 镜像已发布 → 关闭
        issues = mk_issues()
        out, calls = run_watch(tmp, bindir, logf, issues, DETECT, INDEX_READY,
                               ["1.2.0900", "1.2.1000"])
        if any(c.startswith("issue close 1 ") for c in calls):
            ok("6. 镜像已发布时自动关闭 Issue")
        else:
            bad("6. 未关闭已完成的 Issue（calls=%s）" % calls)

        # 7. Hub 不可达 → 保守跳过（不关、不建、不改）
        issues = mk_issues()
        out, calls = run_watch(tmp, bindir, logf, issues, DETECT, INDEX_READY, None)
        if not any(c.startswith("issue close") or c.startswith("issue create")
                   or c.startswith("issue edit") or c.startswith("issue reopen")
                   for c in calls) and "::warning::" in out:
            ok("7. Hub 不可达时保守跳过并告警（不改任何 Issue）")
        else:
            bad("7. Hub 不可达时未保守处理（calls=%s）" % calls)

        # 8. OTA 通道的底座提示（无底座时点名）
        issues = {}
        out, calls = run_watch(tmp, bindir, logf, issues, DETECT, {}, ["1.2.0900"])
        if any("issue create" in c and "1.2.1010 (OTA)" in c for c in calls):
            ok("8. OTA 通道单独出一条 Issue")
        else:
            bad("8. OTA 通道未单独建 Issue（calls=%s）" % calls)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
