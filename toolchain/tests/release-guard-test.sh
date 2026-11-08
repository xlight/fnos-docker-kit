#!/usr/bin/env bash
# release-guard-test.sh — 模拟 public-ci release job 的“validation 计数必须与
# patch-report 一致”门禁：构造一份假补丁集 + 两份假报告（一致/不一致），
# 断言比较逻辑分别 exit 0 / exit 1。不依赖 GitHub Actions。
set -uo pipefail
W="$(mktemp -d /tmp/opencode/release-guard.XXXXXX)"
trap 'rm -rf "$W"' EXIT
python3 - "$W" <<'PY'
import json, sys, os
w = sys.argv[1]
ps = {"fnos_version": "V9.9.9999", "patches": [], "file_hashes": {},
      "validation": {"ready": 30, "total": 36, "validated_at": "2026-11-07T00:00:00Z"}}
json.dump(ps, open(os.path.join(w, "ps.json"), "w"))
json.dump({"patches": [{"status": "ready"}] * 30 + [{"status": "x"}] * 6, "patchset_sha256": "abc"},
          open(os.path.join(w, "report-ok.json"), "w"))
json.dump({"patches": [{"status": "ready"}] * 29, "patchset_sha256": "abc"},
          open(os.path.join(w, "report-bad.json"), "w"))
PY

check() { # <report> -> 与补丁集 validation 比较，一致 exit 0，不一致 exit 1
  local report="$1"
  python3 - "$W/ps.json" "$report" <<'PY'
import json, sys
ps = json.load(open(sys.argv[1]))
rep = json.load(open(sys.argv[2]))
val = ps.get("validation") or {}
ok = ("ready", "already")
ready = sum(1 for p in rep.get("patches", []) if str(p.get("status", "")).split("(")[0] in ok)
total = len(rep.get("patches", []))
sys.exit(0 if (ready, total) == (val.get("ready"), val.get("total")) else 1)
PY
}

pass=0; fail=0
if check "$W/report-ok.json"; then echo "  PASS: 一致时放行"; pass=$((pass+1)); else echo "  FAIL: 一致却被拒"; fail=$((fail+1)); fi
if check "$W/report-bad.json"; then echo "  FAIL: 不一致却放行"; fail=$((fail+1)); else echo "  PASS: 不一致时失败"; pass=$((pass+1)); fi
echo "release-guard: $pass pass, $fail fail"
[ "$fail" = 0 ]
