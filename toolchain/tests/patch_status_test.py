#!/usr/bin/env python3
"""patch_status_test.py — fnos-patch-status 通知/版本选择逻辑的无依赖单测。

用假 psql 记录 SQL，验证：
  7.1 issues 通知 = advisory lock + 原地 UPDATE + NOT EXISTS 插入 + notify_user 补行，纯文本无换行
  7.2 健康+有更新目标 → ready 通知（ready/partial 文案）并清旧 issues；无目标 → 前缀清理
  7.3 索引未知时健康也不误清；pending_target 正确识别更新目标
  3.1 select_patchset：exact / fallback / no-compatible / 预发布后缀

用法: python3 fnos/toolchain/tests/patch_status_test.py
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)
FPS = os.path.join(TC, "fnos-patch-status")

PASS = FAIL = 0


def ok(m):
    global PASS; PASS += 1; print("  PASS:", m)


def no(m):
    global FAIL; FAIL += 1; print("  FAIL:", m)


def load_module():
    src = open(FPS).read().replace('if __name__ == "__main__":', 'if False:')
    m = {"__file__": FPS}
    exec(compile(src, FPS, "exec"), m)
    return m


def main():
    m = load_module()
    W = tempfile.mkdtemp()
    rec = os.path.join(W, "sql.log")
    orig_run_cmd = m["run_cmd"]

    def fake_run_cmd(cmd, timeout=30):
        if cmd[:3] == ["sudo", "-u", "postgres"]:
            with open(rec, "a") as f:
                f.write(cmd[-1] + "\n---\n")
            return 0, "", ""
        return orig_run_cmd(cmd, timeout)
    m["run_cmd"] = fake_run_cmd
    open(os.path.join(W, "version"), "w").write("1.2.1010\n")
    m["VERSION_PATH"] = os.path.join(W, "version")
    m["PROXY_INDEX_PATH"] = os.path.join(W, "index.json")

    # --- 3.1 select_patchset ---
    pdir = os.path.join(W, "patches"); os.makedirs(pdir)
    for v in ("1.2.0800", "1.2.1010"):
        json.dump({"fnos_version": "V" + v, "patches": [], "file_hashes": {}},
                  open(os.path.join(pdir, "fnos-%s.json" % v), "w"))
    m["PATCHES_DIR"] = pdir
    for rv, expect in [("1.2.1010", "exact"), ("1.2.1099", "fallback"),
                       ("1.2.0700", "no-compatible"), ("1.2.1010-rc1", "no-compatible")]:
        open(os.path.join(W, "version"), "w").write(rv + "\n")
        got = m["select_patchset"]()[0]
        (ok if got == expect else no)("select_patchset %s -> %s (want %s)" % (rv, got, expect))
    open(os.path.join(W, "version"), "w").write("1.2.1010\n")

    # --- 7.1 issues 通知 ---
    idx = {"revision": 1, "versions": {
        "1.2.1010": {"status": "ready", "ready": 37, "total": 37},
        "1.2.1099": {"patchset": "fnos-1.2.1099.json", "sha256": "x", "ready": 30,
                     "total": 36, "status": "partial", "validated_at": "t"}}}
    open(m["PROXY_INDEX_PATH"], "w").write(json.dumps(idx))
    open(rec, "w").write("")
    m["notify_postgres"](["AOB:x: ready"], ["AOB:y: skipped (no-match)"], False)
    sql = open(rec).read()
    if ("pg_advisory_xact_lock(hashtext('trim.fnos-patch-status.issues'))" in sql
            and "UPDATE notify SET content=" in sql and "WHERE NOT EXISTS" in sql
            and "INSERT INTO notify_user" in sql and "NOT EXISTS" in sql
            and "发现 1 个补丁问题；AOB:x: ready；警告：AOB:y: skipped (no-match)" in sql):
        ok("7.1 issues 通知: advisory lock + 原地更新 + 查重插入 + notify_user 补行 + 纯文本")
    else:
        no("7.1 issues 通知 SQL 不符: %s" % sql[:300])

    # --- 7.2 健康 + 有更新目标 partial ---
    open(rec, "w").write("")
    m["notify_postgres"]([], [], True)
    sql = open(rec).read()
    if ("补丁集 1.2.1099 部分就绪（30/36）" in sql
            and "DELETE FROM notify WHERE source='trim.fnos-patch-status.issues'" in sql):
        ok("7.2 健康+更新目标 → ready 通知(partial) 并清旧 issues")
    else:
        no("7.2 ready 通知不符: %s" % sql[:300])

    # --- 7.2 健康 + 无更新目标 → 前缀清理 ---
    open(rec, "w").write("")
    open(m["PROXY_INDEX_PATH"], "w").write(json.dumps(
        {"revision": 1, "versions": {"1.2.1010": {"status": "ready", "ready": 37, "total": 37}}}))
    m["notify_postgres"]([], [], True)
    sql = open(rec).read()
    if "source LIKE 'trim.fnos-patch-status%'" in sql and "DELETE FROM notify_user" in sql:
        ok("7.2 健康且无更新目标 → 前缀清理")
    else:
        no("7.2 清理不符: %s" % sql[:200])

    # --- 7.3 索引未知 → 健康也不清 ---
    open(rec, "w").write("")
    m["PROXY_INDEX_PATH"] = os.path.join(W, "missing.json")
    m["notify_postgres"]([], [], True)
    if open(rec).read() == "" and m["pending_target"]() == "unknown":
        ok("7.3 索引未知: 保留通知 + pending_target=unknown")
    else:
        no("7.3 索引未知行为不符")

    print()
    print("== patch_status_test: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
