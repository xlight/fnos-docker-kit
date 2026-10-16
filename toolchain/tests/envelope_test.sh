#!/usr/bin/env bash
# ============================================================================
# tests/envelope_test.sh — 机器输出信封契约回归（fnos-ops-tui 1.4）
#
# 断言（fnos-host-operations "机器输出信封"）：
#   1. 三个 --json 输出 stdout 纯 JSON 可解析，含 schemaVersion==1 与 ok 字段
#   2. data 含要求的键（子集断言：加字段不炸，缺字段才炸——additive-only）
#   3. stderr 不影响解析（人类 prose 若有，必须走 stderr）
#   4. 版本漂移显式失败由消费者侧覆盖（见 pipeline resolve_patchset 测试）
#
# 用法: bash tests/envelope_test.sh
#   需要 root（stor-manage/deploy 走真实只读 status；CTID/VOLSTORE 可覆盖）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
PY="${PYTHON:-python3}"
CTID="${CTID:-201}"
VOLSTORE="${VOLSTORE:-wd500g}"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 2; }

check_envelope() { # $1=label $2=file $3=required-keys(csv)
  local label="$1" f="$2" keys="$3"
  $PY - "$f" "$keys" <<'PYEOF' || return 1
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
try:
    d = json.loads(raw)
except Exception as e:
    print("stdout 非纯 JSON: %s | head=%.120s" % (e, raw)); sys.exit(1)
assert isinstance(d, dict), "顶层非对象"
assert d.get("schemaVersion") == 1, "schemaVersion!=1: %r" % d.get("schemaVersion")
assert d.get("ok") is True, "ok 非 true"
data = d.get("data") or {}
missing = [k for k in sys.argv[2].split(",") if k and k not in data]
assert not missing, "data 缺键: %s (keys=%s)" % (missing, sorted(data))
PYEOF
}

echo "== 1) stor-manage status --json =="
if CTID="$CTID" VOLSTORE="$VOLSTORE" bash "$TC/../scripts/stor-manage.sh" status --json \
    >/tmp/opencode/env-sm.json 2>/tmp/opencode/env-sm.err; then
  if check_envelope "stor-manage" /tmp/opencode/env-sm.json \
      "ctid,devid,zvol,nvmet,nvme,vg,md,lv,passthrough,sysblock_mask,heal_unit,container_running,vol"; then
    ok "stor-manage 信封合法 + data 键齐"
  else no "stor-manage 信封非法"; fi
else no "stor-manage status --json 退出非零"; fi

echo "== 2) fnos_deploy.sh status --json =="
if bash "$TC/fnos_deploy.sh" status "$CTID" --json \
    >/tmp/opencode/env-dep.json 2>/tmp/opencode/env-dep.err; then
  if check_envelope "deploy" /tmp/opencode/env-dep.json \
      "ctid,running,fnos_version,patchsets,units,nfs_mask"; then
    ok "deploy 信封合法 + data 键齐"
  else no "deploy 信封非法"; fi
else no "deploy status --json 退出非零"; fi

echo "== 3) fnos_pipeline.py status（天然 JSON，对齐信封） =="
if $PY "$TC/fnos_pipeline.py" status --out /tmp/opencode/nope --ctid "$CTID" \
    >/tmp/opencode/env-pipe.json 2>/tmp/opencode/env-pipe.err; then
  if check_envelope "pipeline" /tmp/opencode/env-pipe.json \
      "release_dir,image.raw,verification.json,release,container_running"; then
    ok "pipeline 信封合法 + data 键齐"
  else no "pipeline 信封非法"; fi
else no "pipeline status 退出非零"; fi

echo "== 4) stderr 隔离（人类输出若有，不得污染 stdout JSON） =="
bad=0
for f in /tmp/opencode/env-sm.json /tmp/opencode/env-dep.json /tmp/opencode/env-pipe.json; do
  $PY - "$f" <<'PYEOF' || bad=1
import json, sys
json.load(open(sys.argv[1]))  # 整文件恰为一个 JSON 文档
PYEOF
done
[ "$bad" = 0 ] && ok "三个 stdout 均为单 JSON 文档" || no "stdout 有污染"

echo
echo "== envelope_test: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
