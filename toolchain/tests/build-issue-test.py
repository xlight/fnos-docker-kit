#!/usr/bin/env python3
"""build-issue-test.py —— 构建失败 Issue 的阶段分类回归（design D10 / 2.7）。

验证：
  1. 补丁检查失败 → 标题「补丁失配」，正文含 per-site 报告；
  2. **补丁检查全绿但施加阶段失败** → 标题「补丁施加失败」，正文**不含**"补丁失配"；
  3. 镜像生成 / 推送 / 基础设施类 → 各自措辞；
  4. 同一（版本, 类型）复用同一条 Issue（第二次是更新，不是新建）；
  5. 缺补丁集 → 不开 Issue（交由观察单元的「待 rebase」）。

用法: python3 toolchain/tests/build-issue-test.py
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
SCRIPT = os.path.join(TC, "ci-public", "build-issue.py")

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


def make_fake_gh(tmp):
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir, exist_ok=True)
    logf = os.path.join(tmp, "gh.log")
    script = os.path.join(bindir, "gh")
    with open(script, "w", encoding="utf-8") as f:
        f.write('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as lf:
    lf.write(json.dumps(args, ensure_ascii=False) + "\\n")
issues = json.load(open(os.environ["FAKE_GH_ISSUES"]))
if args[:2] == ["issue", "list"]:
    query = ""
    if "--search" in args:
        query = args[args.index("--search") + 1].split(" in:")[0].strip().strip('"')
    out = []
    for num, it in issues.items():
        title = it.get("title", "")
        if query and query not in title:
            continue
        out.append({"number": int(num), "title": title,
                    "state": it.get("state", "OPEN"), "body": it.get("body", "")})
    print(json.dumps(out))
sys.exit(0)
''')
    os.chmod(script, 0o755)
    return bindir, logf


def run(tmp, bindir, logf, issues, stage, report=None, tail=None):
    if os.path.exists(logf):
        os.remove(logf)
    issues_f = os.path.join(tmp, "issues.json")
    json.dump(issues, open(issues_f, "w", encoding="utf-8"))
    rep_f = os.path.join(tmp, "report.json")
    if report is None:
        rep_f = ""
    else:
        json.dump(report, open(rep_f, "w", encoding="utf-8"))
    tail_f = os.path.join(tmp, "tail.log")
    if tail is None:
        tail_f = ""
    else:
        open(tail_f, "w", encoding="utf-8").write(tail)
    env = dict(os.environ)
    env["PATH"] = bindir + os.pathsep + env["PATH"]
    env["FAKE_GH_LOG"] = logf
    env["FAKE_GH_ISSUES"] = issues_f
    p = subprocess.run([sys.executable, SCRIPT, "--repo", "o/r", "--version", "1.2.1000",
                        "--channel", "iso", "--tag", "1.2.1000", "--stage", stage,
                        "--run-url", "https://example.invalid/run/1",
                        "--report", rep_f, "--log-tail", tail_f],
                       capture_output=True, text=True, env=env)
    calls = []
    if os.path.exists(logf):
        for l in open(logf, encoding="utf-8"):
            l = l.strip()
            if not l:
                continue
            try:
                args = json.loads(l)
            except Exception:
                continue
            calls.append(args)
    return p.stdout + p.stderr, calls


def _arg(calls, flag):
    for c in calls:
        if c[:2] in (["issue", "create"], ["issue", "edit"]) and flag in c:
            i = c.index(flag)
            if i + 1 < len(c):
                return c[i + 1]
    return ""


def body_of(calls):
    return _arg(calls, "--body")


def title_of(calls):
    return _arg(calls, "--title")


def started(calls, kind):
    return any(c[:2] == ["issue", kind] for c in calls)


REPORT_BAD = {"items": [
    {"id": "resmon_service.veth-kind", "status": "no-match"},
    {"id": "liveupdate.hide-kernel-entry", "status": "ready"},
], "patchset_sha256": "deadbeef"}
REPORT_GOOD = {"items": [
    {"id": "resmon_service.veth-kind", "status": "ready"},
    {"id": "liveupdate.hide-kernel-entry", "status": "ready"},
], "patchset_sha256": "deadbeef"}


def main():
    tmp = tempfile.mkdtemp(prefix="build-issue-test-")
    try:
        bindir, logf = make_fake_gh(tmp)

        # 1. 补丁检查失败 → 补丁失配 + per-site 报告
        out, calls = run(tmp, bindir, logf, {}, "补丁检查", REPORT_BAD, "boom")
        t = title_of(calls)
        b = body_of(calls)
        if t.startswith("补丁失配: 1.2.1000 (ISO)"):
            ok("1a. 补丁检查失败 → 标题「补丁失配」")
        else:
            bad("1a. 标题错：%r" % t)
        if "resmon_service.veth-kind" in b and "no-match" in b:
            ok("1b. 正文含 per-site 报告")
        else:
            bad("1b. 正文缺 per-site 报告")

        # 2. 补丁检查全绿、施加阶段失败 → 不是补丁失配
        out, calls = run(tmp, bindir, logf, {}, "补丁施加", REPORT_GOOD, "UnicodeDecodeError: 0xad")
        t = title_of(calls)
        b = body_of(calls)
        if t.startswith("补丁施加失败:"):
            ok("2a. 施加阶段失败 → 标题「补丁施加失败」")
        else:
            bad("2a. 标题错：%r" % t)
        if "补丁失配" not in t and "不是补丁失配" in b:
            ok("2b. 正文明确说明「不是补丁失配」")
        else:
            bad("2b. 正文未正确区分：%r" % b[:120])
        if "UnicodeDecodeError" in b:
            ok("2c. 正文含日志尾部")
        else:
            bad("2c. 正文缺日志尾部")

        # 3. 其他阶段措辞
        for stage, prefix in (("镜像生成", "镜像生成失败"), ("推送", "推送失败"),
                              ("磁盘不足", "基础设施受阻"), ("构建依赖缺失", "基础设施受阻"),
                              ("ISO 下载", "基础设施受阻")):
            out, calls = run(tmp, bindir, logf, {}, stage, None, "x")
            t = title_of(calls)
            if t.startswith(prefix + ":"):
                ok("3. 阶段「%s」→ 标题「%s」" % (stage, prefix))
            else:
                bad("3. 阶段「%s」标题错：%r" % (stage, t))

        # 4. 同一（版本, 类型）复用同一条
        issues = {"7": {"title": "补丁失配: 1.2.1000 (ISO)", "state": "OPEN", "body": "旧"}}
        out, calls = run(tmp, bindir, logf, issues, "补丁检查", REPORT_BAD, "x")
        if any(c[:2] == ["issue", "edit"] and c[2] == "7" for c in calls) and \
           not started(calls, "create"):
            ok("4. 同版本同类型复用同一条 Issue")
        else:
            bad("4. 未复用同一条：%s" % calls)

        # 5. 缺补丁集 → 不开 Issue
        out, calls = run(tmp, bindir, logf, {}, "缺补丁集", None, "x")
        if not (started(calls, "create") or started(calls, "edit")):
            ok("5. 缺补丁集不开 Issue（交观察单元的「待 rebase」）")
        else:
            bad("5. 缺补丁集仍开了 Issue：%s" % calls)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
