#!/usr/bin/env bash
# ============================================================================
# update-grub-shim-test.sh —— update-grub 容器兼容 shim 的回归（**无破坏性**）
#
# 覆盖三条分支 + 一条兜底：
#   ① grub-probe 失败          → exit 0、branch=skip-probe、不调真身
#   ② 探测通过但真身缺失        → exit 0、branch=skip-no-real、不调真身
#   ③ 探测通过且真身存在        → 透传真身退出码、branch=real、real_rc 记录
#   ④ grub-probe 不存在(127)    → 透传真身、branch=passthrough-no-probe
#
# 做法：用假的 probe/real 覆盖 FNOS_UPDATE_GRUB_* 测试钩子，不碰真实系统。
# 用法: bash toolchain/tests/update-grub-shim-test.sh
# 退出: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/../fnos-update-grub-shim"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SHIM" ] || { echo "缺少被测脚本: $SHIM"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/probe" <<'EOF'
#!/bin/sh
echo "probe-stdout"
echo "probe-stderr: $*" >&2
exit "${FAKE_PROBE_RC:-1}"
EOF
cat >"$TMP/real" <<'EOF'
#!/bin/sh
echo "real $*" >>"$REAL_LOG"
exit "${FAKE_REAL_RC:-0}"
EOF
chmod +x "$TMP/probe" "$TMP/real"

run_shim() { # $1=marker $2=probe $3=real [shim args...]
    local m="$1" p="$2" r="$3"; shift 3
    FNOS_UPDATE_GRUB_MARKER="$m" \
    FNOS_UPDATE_GRUB_PROBE="$p" \
    FNOS_UPDATE_GRUB_REAL="$r" \
    REAL_LOG="$TMP/real.log" \
    "$SHIM" "$@" >/dev/null 2>&1
}

# ---------- ① grub-probe 失败 ----------
M="$TMP/m1"; rm -f "$TMP/real.log"
FAKE_PROBE_RC=1 run_shim "$M" "$TMP/probe" "$TMP/real"; rc=$?
[ "$rc" = 0 ] && ok "① grub-probe 失败 → exit 0" || bad "① grub-probe 失败 → rc=$rc（期望 0）"
grep -q '^branch=skip-probe$' "$M" 2>/dev/null && ok "① marker branch=skip-probe" || bad "① marker 未记 skip-probe"
grep -q '^reason=probe-stderr' "$M" 2>/dev/null && ok "① 原因已记录" || bad "① 原因缺失"
[ ! -s "$TMP/real.log" ] && ok "① 未调用真身" || bad "① 不该调用真身"

# ---------- ② 真身缺失 ----------
M="$TMP/m2"; rm -f "$TMP/real.log"
FAKE_PROBE_RC=0 run_shim "$M" "$TMP/probe" "$TMP/does-not-exist"; rc=$?
[ "$rc" = 0 ] && ok "② 真身缺失 → exit 0" || bad "② 真身缺失 → rc=$rc（期望 0）"
grep -q '^branch=skip-no-real$' "$M" 2>/dev/null && ok "② marker branch=skip-no-real" || bad "② marker 未记 skip-no-real"
[ ! -s "$TMP/real.log" ] && ok "② 未调用真身" || bad "② 不该调用真身"

# ---------- ③ 调真身并透传退出码 ----------
M="$TMP/m3"; rm -f "$TMP/real.log"
FAKE_PROBE_RC=0 FAKE_REAL_RC=7 run_shim "$M" "$TMP/probe" "$TMP/real" --update; rc=$?
[ "$rc" = 7 ] && ok "③ 透传真身退出码 7" || bad "③ rc=$rc（期望 7）"
grep -q '^branch=real$' "$M" 2>/dev/null && ok "③ marker branch=real" || bad "③ marker 未记 real"
grep -q '^real_rc=7$' "$M" 2>/dev/null && ok "③ real_rc=7 已记录" || bad "③ real_rc 缺失"
grep -q '^real --update$' "$TMP/real.log" 2>/dev/null && ok "③ 真身收到参数" || bad "③ 真身未收到参数"

# ---------- ④ grub-probe 不存在（127）----------
M="$TMP/m4"; rm -f "$TMP/real.log"
FAKE_PROBE_RC=0 run_shim "$M" "$TMP/no-such-probe" "$TMP/real"; rc=$?
grep -q '^branch=passthrough-no-probe$' "$M" 2>/dev/null && ok "④ marker branch=passthrough-no-probe" || bad "④ marker 未记 passthrough-no-probe"
[ -s "$TMP/real.log" ] && ok "④ 透传时调用真身" || bad "④ 未调用真身"

printf '== update-grub-shim 测试: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]