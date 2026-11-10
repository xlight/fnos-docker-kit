#!/usr/bin/env python3
"""evidence-test.py —— 发布证据的 schema / 脱敏 / 绑定校验（design D14）。

覆盖：
  A. 三类证据的合法样本通过校验
  B. 缺字段 / 版本不符 / sha 不符 → 校验失败
  C. 脱敏：宿主地址、容器标识、账号不残留在公开形态里
  D. 字节级证据：无基材时 status 必须是 unavailable
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("ev", os.path.join(TC, "evidence.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

PASS = 0
FAIL = 0
SHA = "a" * 64


def ok(msg):
    global PASS
    PASS += 1
    print("PASS: %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: %s" % msg)


VER = "1.2.1010"

intent = {"fnos_version": VER, "patchset_sha256": SHA, "kind": "correction",
          "reason": "liveupdate 兼容 OTA 新 build", "author": "xlight",
          "created_at": "2026-11-09T00:00:00Z"}

behavior = {"fnos_version": VER, "patchset_sha256": SHA,
            "probes": [{"name": "resmon.net", "ok": True, "detail": "succ eth0"},
                       {"name": "file.rm", "ok": None, "skipped": True, "detail": "破坏性，默认跳过"}],
            "patch_status": {"healthy": True, "issue_count": 0},
            "created_at": "2026-11-09T00:00:00Z"}

evidence_ok = {"fnos_version": VER, "patchset_sha256": SHA,
               "environment": {"source": "iso", "strength": "strong"},
               "sites": {"total": 37, "ready": 37, "failed": []},
               "status": "ready", "generated_at": "2026-11-09T00:00:00Z"}
evidence_none = dict(evidence_ok, environment={"source": "none", "strength": "none"},
                     status="unavailable")

# ---- A. 合法样本 ----
for kind, doc in (("intent", intent), ("behavior", behavior), ("evidence", evidence_ok)):
    errs = ev.validate(doc, kind, VER, SHA)
    if errs:
        bad("A: %s 合法样本被拒: %s" % (kind, errs))
    else:
        ok("A: %s 合法样本通过" % kind)

# ---- B. 非法样本 ----
cases = [
    ("intent 缺 reason", ev.validate({k: v for k, v in intent.items() if k != "reason"}, "intent", VER, SHA)),
    ("intent 版本不符", ev.validate(dict(intent, fnos_version="1.2.1000"), "intent", VER, SHA)),
    ("intent sha 不符", ev.validate(dict(intent, patchset_sha256="b" * 64), "intent", VER, SHA)),
    ("behavior probes 为空", ev.validate(dict(behavior, probes=[]), "behavior", VER, SHA)),
    ("behavior 探针缺 ok", ev.validate(dict(behavior, probes=[{"name": "x"}]), "behavior", VER, SHA)),
    ("evidence 缺 sites", ev.validate({k: v for k, v in evidence_ok.items() if k != "sites"}, "evidence", VER, SHA)),
]
for name, errs in cases:
    if errs:
        ok("B: %s 被拒" % name)
    else:
        bad("B: %s 未被拒" % name)

# ---- C. 脱敏 ----
doc = {"fnos_version": VER, "host": "192.168.199.199", "container": "CT201",
       "user": "xlight", "password": "s3cret",
       "probes": [{"name": "x", "ok": True, "detail": "on 192.168.199.199 (CT201)"}]}
scrubbed = ev.scrub(doc)
raw = json.dumps(scrubbed, ensure_ascii=False)
leaks = [s for s in ("192.168.199.199", "CT201", "xlight", "s3cret") if s in raw]
if leaks:
    bad("C: 脱敏后仍残留: %s" % leaks)
else:
    ok("C: 脱敏清掉宿主地址/容器标识/账号")

# ---- D. 无基材时 status 必须是 unavailable ----
if ev.validate(evidence_none, "evidence", VER, SHA):
    bad("D: 无基材但 status 不是 unavailable，未被拒")
else:
    ok("D: 无基材时 status 必须是 unavailable")

# ---- E. CLI：validate / scrub ----
tmp = tempfile.mkdtemp()
p = os.path.join(tmp, "fnos-%s.intent.json" % VER)
json.dump(intent, open(p, "w"), ensure_ascii=False)
rc = os.system("python3 '%s' validate '%s' intent %s %s >/dev/null" % (
    os.path.join(TC, "evidence.py"), p, VER, SHA))
if rc == 0:
    ok("E: CLI validate 通过")
else:
    bad("E: CLI validate 失败 rc=%s" % rc)

print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)
