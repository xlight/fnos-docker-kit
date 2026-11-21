#!/usr/bin/env bash
# ============================================================================
# stor-webui-test.sh —— WebUI 存活判据的回归（**无破坏性**）
#
# 覆盖：
#   ① lib.sh 探针解析：worker 计数 / HTTP 状态码 / uptime（含失败态）
#   ② stor-guard 的判据与恢复分支在位（静态断言）
#   ③ stor-selfheal 只做 warn 呈现（不进 bad_count）
#   ④ 预热阈值统一为 FNOS_WARMUP_SECONDS（默认 300）
#
# 用法: bash scripts/stor-webui-test.sh [--live]
#   --live 额外对 CT201 跑一次只读的 `stor-guard.sh status`
# 退出: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib.sh"
GUARD="$HERE/stor-guard.sh"
SELFHEAL="$HERE/stor-selfheal.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# shellcheck source=lib.sh
source "$LIB"

# 假 pct（必须是可执行文件：探针用 `timeout ... pct`，shell 函数对 timeout 不可见）
FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$FAKEBIN"' EXIT
cat >"$FAKEBIN/pct" <<'EOF'
#!/bin/sh
case "$*" in
  *"cut -d"*) printf '%s\n' "${FAKE_UPTIME-100.5}" ;;
  *pgrep*)
    [ "${FAKE_WORKERS_FAIL-0}" = 1 ] && return 1
    printf '%s\n' "${FAKE_WORKERS-2}"
    ;;
  *curl*) printf '%s\n' "${FAKE_HTTP-200}" ;;
  *) return 1 ;;
esac
EOF
chmod +x "$FAKEBIN/pct"
PATH="$FAKEBIN:$PATH"; export PATH

# ---------- ① 探针解析 ----------
export FAKE_WORKERS=2; n="$(webui_workers)"; [ "$n" = 2 ] && ok "① worker=2" || bad "① worker=$n"
export FAKE_WORKERS=0; n="$(webui_workers)"; [ "$n" = 0 ] && ok "① worker=0" || bad "① worker=$n"
export FAKE_WORKERS=2 FAKE_WORKERS_FAIL=1; n="$(webui_workers)"; [ "$n" = -1 ] && ok "① 探针失败 → -1" || bad "① 探针失败 worker=$n"
export FAKE_HTTP=200; c="$(webui_http)"; [ "$c" = 200 ] && ok "① http=200" || bad "① http=$c"
export FAKE_HTTP=; c="$(webui_http)"; [ "$c" = 000 ] && ok "① 空响应 → 000" || bad "① 空响应 http=$c"
export FAKE_UPTIME=123.45; u="$(ct_uptime)"; [ "$u" = 123 ] && ok "① uptime 取整秒" || bad "① uptime=$u"

# ---------- ④ 预热阈值 ----------
grep -q 'FNOS_WARMUP_SECONDS:-300' "$LIB" && ok "④ 预热阈值默认 300s" || bad "④ lib.sh 缺 FNOS_WARMUP_SECONDS 默认值"
grep -q 'FNOS_WARMUP_SECONDS' "$SELFHEAL" && ok "④ selfheal 复用同一常量" || bad "④ selfheal 未复用 FNOS_WARMUP_SECONDS"

# ---------- ② guard 判据与恢复 ----------
for pat in 'webui_state()' 'webui_gate_ok()' 'webui_budget_ok()' 'ct${CTID}.webui-fixes' 'GUARD_WEBUI_BUDGET'; do
  grep -q "$pat" "$GUARD" && ok "② guard 含 $pat" || bad "② guard 缺 $pat"
done
grep -q 'TimeoutStartSec=120' "$GUARD" && ok "② unit 有 TimeoutStartSec=120" || bad "② unit 缺 TimeoutStartSec=120"
grep -q 'Environment=GUARD_WEBUI_BUDGET' "$GUARD" && ok "② unit 注入 GUARD_WEBUI_BUDGET" || bad "② unit 未注入预算常量"
# 双门禁必须先于重启：cert + nginx -t 出现在 restart 之前
gate_line=$(grep -n 'webui_gate_ok' "$GUARD" | head -1 | cut -d: -f1)
restart_line=$(grep -n 'systemctl restart trim_nginx.service' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$restart_line" ] && [ "$gate_line" -lt "$restart_line" ]; then
  ok "② 门禁在重启之前"
else
  bad "② 门禁/重启顺序不对（gate=$gate_line restart=$restart_line）"
fi
# 门禁同时校验 cert 与 nginx -t
grep -q 'test -s "\$cert"' "$GUARD" && grep -q '"\$nginx" -t' "$GUARD" \
  && ok "② 双门禁（cert 非空 + nginx -t）" || bad "② 门禁不全"
# 4 个 emit_json 调用点都带 webui
n=$(grep -c 'emit_json "\$healthy" "\$running" "\$mp_ok" "\$expect" "\$summary" "\$(webui_json)"' "$GUARD")
[ "$n" = 4 ] && ok "② emit_json 4 个调用点都带 webui" || bad "② emit_json 调用点=$n（期望 4）"

# ---------- ③ selfheal 只 warn ----------
grep -q 'chk_webui_warn()' "$SELFHEAL" && ok "③ selfheal 有 chk_webui_warn" || bad "③ selfheal 缺 chk_webui_warn"
grep -q 'CHECK_NAME=webui;      chk_webui_warn' "$SELFHEAL" && ok "③ selfheal 调用 webui 检查" || bad "③ selfheal 未调用"
if grep -q 'rc_webui' "$SELFHEAL"; then
  bad "③ webui 不应计入 bad_count（发现 rc_webui）"
else
  ok "③ webui 不计入 bad_count"
fi

# ---------- 可选：对真实容器跑一次只读 status ----------
if [ "${1:-}" = "--live" ]; then
  if sudo -n pct status 201 2>/dev/null | grep -q running; then
    out="$(sudo -n env CTID=201 bash "$GUARD" status 2>/dev/null)"
    if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "webui" in d else 1)' 2>/dev/null; then
      ok "live: CT201 status 含 webui 字段"
    else
      bad "live: CT201 status 缺 webui 字段"
    fi
  else
    printf 'SKIP: live CT201 未运行\n'
  fi
fi

printf '== stor-webui 测试: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]