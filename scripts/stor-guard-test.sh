#!/usr/bin/env bash
# ============================================================================
# stor-guard-test.sh —— 存活巡检机制的回归测试（不碰真实容器）
#
# 用法: sudo bash stor-guard-test.sh
# 退出: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/stor-guard.sh"
GUARD_STATE_DIR="${GUARD_STATE_DIR:-/tmp/opencode/stor-guard-test}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 2; }
rm -rf "$GUARD_STATE_DIR"; mkdir -p "$GUARD_STATE_DIR"

# ① 真实容器在跑 + expect=running → 健康
out="$(GUARD_STATE_DIR="$GUARD_STATE_DIR" CTID=201 bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "存活正常"; then ok "① 容器在跑 → 健康"; else bad "① 判错：$(printf '%s' "$out" | tr '\n' ' ')"; fi

# ② 人为停机（expect=stopped）→ 不报红、不拉起
printf 'stopped\n' > "$GUARD_STATE_DIR/ct99998.expect"
out="$(GUARD_STATE_DIR="$GUARD_STATE_DIR" CTID=99998 bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "按期望保持停机"; then ok "② expect=stopped → 不报红"; else bad "② 判错：$(printf '%s' "$out" | tr '\n' ' ')"; fi

# ③ 容器不在 + expect=running → 报红
out="$(GUARD_STATE_DIR="$GUARD_STATE_DIR" CTID=99997 bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "不健康"; then ok "③ 容器不在 + expect=running → 报红"; else bad "③ 判错：$(printf '%s' "$out" | tr '\n' ' ')"; fi

# ④ 用法错误 → 退出码 2
GUARD_STATE_DIR="$GUARD_STATE_DIR" CTID=201 bash "$SCRIPT" frobnicate >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "④ 用法错 → 退出码 2"; else bad "④ 用法错退出码=$rc（期望 2）"; fi

# ⑤ 缺 CTID → 拒绝执行（防误伤默认容器）
GUARD_STATE_DIR="$GUARD_STATE_DIR" bash "$SCRIPT" check >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok "⑤ 缺 CTID → 拒绝执行（退出码 $rc）"; else bad "⑤ 缺 CTID 未被拒绝"; fi

# ⑥ 状态文件机器可读
if [ -f "$GUARD_STATE_DIR/guard-ct201.json" ] && python3 -c "
import json,sys; d=json.load(open('$GUARD_STATE_DIR/guard-ct201.json'))
assert d['ctid']==201 and 'container_running' in d and 'expect' in d" 2>/dev/null; then
  ok "⑥ 状态文件机器可读"
else
  bad "⑥ 状态文件缺失或不完整"
fi

rm -rf "$GUARD_STATE_DIR"
printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
