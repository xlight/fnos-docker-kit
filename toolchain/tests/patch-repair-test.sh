#!/usr/bin/env bash
# ============================================================================
# patch-repair-test.sh —— 补丁重放修复轮的回归（**无破坏性**）
#
# 覆盖：
#   ① 健康态零动作（rc=0，state 不变）
#   ② 不健康 → 调 auto-fix → 转绿（rc=0）
#   ③ 只有 no-compatible-patchset → 先取补丁集，仍缺则 waiting（rc=1，预算不变）
#   ④ 文件健康但 stale → 重启清单内消费者（rc=0）
#   ⑤ 并发锁：第二个实例拿不到锁 → waiting（rc=1）
#   ⑥ flock 不可用 → waiting（fail-closed）
#   ⑦ 超时 → failed（rc=2，reason 写明超时）
#   ⑧ 活动闸门（pgrep 命中）→ waiting（rc=1，不动作）
#   ⑨ state.json 原子写：每轮结束都是合法 JSON
#
# 做法：用假的 fnos-patch-status / fnos-lib-consumers-check / systemctl / pgrep / fuser
# 覆盖 PATH 与环境变量，不碰真实容器。
# 用法: bash toolchain/tests/patch-repair-test.sh
# 退出: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$HERE/../fnos-patch-repair"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$WRAP" ] || { echo "缺少被测脚本: $WRAP"; exit 2; }
command -v python3 >/dev/null || { echo "缺少 python3"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
export PS_COUNT="$TMP/ps.count"
export DIRFD_LOG="$TMP/dirfd.log"
export FNOS_DIRFD_SHIM="$BIN/fnos-dirfd-shim.py"

# ---- 假工具 ----
cat >"$BIN/fnos-patch-status" <<'EOF'
#!/bin/sh
DEF_BEFORE='{"healthy": true, "issues": []}'
DEF_AFTER='{"healthy": true, "issues": [], "auto_fix": {"fixed": 0, "failed": 0}}'
[ -n "${FAKE_PS_SLEEP:-}" ] && sleep "$FAKE_PS_SLEEP"
if [ -n "${FAKE_PS_RAW:-}" ]; then printf '%s' "$FAKE_PS_RAW"; exit "${FAKE_PS_RC:-0}"; fi
case "$*" in
  *--auto-fix*) printf '%s' "${FAKE_PS_AFTER:-$DEF_AFTER}" ;;
  *)
    if [ -f "${PS_COUNT:-/dev/null}.done" ]; then
      echo "CALL $* (after)" >>"${PS_COUNT:-/dev/null}.log"
      printf '%s' "${FAKE_PS_AFTER:-$DEF_BEFORE}"
    else
      echo "CALL $* (before)" >>"${PS_COUNT:-/dev/null}.log"
      printf '%s' "${FAKE_PS_BEFORE:-$DEF_BEFORE}"
      : >"${PS_COUNT:-/dev/null}.done"
    fi
    ;;
esac
exit "${FAKE_PS_RC:-0}"
EOF
cat >"$BIN/fnos-dirfd-shim.py" <<'EOF'
#!/bin/sh
echo "$*" >>"${DIRFD_LOG:-/dev/null}"
exit "${FAKE_DIRFD_RC:-0}"
EOF
cat >"$BIN/fnos-lib-consumers-check" <<'EOF'
#!/bin/sh
DEF='{"ok": true, "list_missing": false, "missing": [], "stale": [], "linked": []}'
DEF_STALE='{"ok": false, "list_missing": false, "missing": [], "stale": [{"unit": "sysinfo_service.service"}], "linked": []}'
N=$(cat "${CC_COUNT:-/dev/null}" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" >"${CC_COUNT:-/dev/null}"
if [ "$N" -le "${FAKE_CC_STALE_TIMES:-0}" ]; then
    printf '%s' "${FAKE_CC_STALE:-$DEF_STALE}"
else
    printf '%s' "${FAKE_CC_JSON:-$DEF}"
fi
exit "${FAKE_CC_RC:-0}"
EOF
cat >"$BIN/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >>"${SYSTEMCTL_LOG:-/dev/null}"
exit "${FAKE_SYSTEMCTL_RC:-0}"
EOF
cat >"$BIN/pgrep" <<'EOF'
#!/bin/sh
echo "$*" >>"${PGREP_LOG:-/dev/null}"
[ "${FAKE_PGREP_HIT:-0}" = 1 ] && exit 0
exit 1
EOF
cat >"$BIN/fuser" <<'EOF'
#!/bin/sh
[ "${FAKE_FUSER_HIT:-0}" = 1 ] && exit 0
exit 1
EOF
chmod +x "$BIN"/*
ln -sf "$(command -v flock)" "$BIN/flock"
ln -sf "$(command -v python3)" "$BIN/python3"
ln -sf "$(command -v sleep)" "$BIN/sleep"
PYTHON="$(command -v python3)"

run_wrap() { # 用当前环境跑一轮；stdout=JSON
    rm -f "$TMP/ps.count" "$TMP/ps.count.log" "$TMP/ps.count.done"
    PATH="$BIN" "$PYTHON" "$WRAP" --json 2>"$TMP/stderr.log"
}
run_wrap_force() { # 跳过冷却/预算（测试 force 分支用）
    rm -f "$TMP/ps.count" "$TMP/ps.count.log" "$TMP/ps.count.done"
    PATH="$BIN" "$PYTHON" "$WRAP" --json --force 2>"$TMP/stderr.log"
}

new_state() { rm -rf "$TMP/state"; mkdir -p "$TMP/state"; }

# ---------- ① 健康态 ----------
new_state
export FNOS_PATCH_STATUS="$BIN/fnos-patch-status" FNOS_CONSUMERS_CHECK="$BIN/fnos-lib-consumers-check"
export FNOS_PATCH_REPAIR_STATE="$TMP/state" FNOS_PATCH_REPAIR_LOCK="$TMP/repair.lock"
unset FAKE_PS_BEFORE FAKE_PS_AFTER FAKE_CC_JSON FAKE_PS_RAW FAKE_PGREP_HIT FAKE_FUSER_HIT || true
out="$(run_wrap)"; rc=$?
[ "$rc" = 0 ] && ok "① 健康 → rc=0" || bad "① rc=$rc（期望 0）: $out"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["state"]=="healthy" else 1)' "$out" \
    && ok "① state=healthy" || bad "① state 非 healthy: $out"

# ---------- ② 不健康 → auto-fix ----------
new_state
export FAKE_PS_BEFORE='{"healthy": false, "issues": ["AOB:x: ready"]}'
export FAKE_PS_AFTER='{"healthy": true, "issues": [], "auto_fix": {"fixed": 2, "failed": 0}}'
export FAKE_CC_JSON='{"ok": true, "list_missing": false, "missing": [], "stale": [], "linked": []}'
out="$(run_wrap)"; rc=$?
[ "$rc" = 0 ] && ok "② auto-fix 后 → rc=0" || bad "② rc=$rc（期望 0）: $out"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("auto_fix",{}).get("fixed")==2 else 1)' "$out" \
    && ok "② 调用了 auto-fix" || bad "② 未调用 auto-fix: $out"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["repairs_24h"] else 1)' "$TMP/state/state.json" \
    && ok "② 预算已记账" || bad "② 预算未记账"
unset FAKE_PS_BEFORE FAKE_PS_AFTER

# ---------- ③ 只有 no-compatible-patchset → waiting ----------
new_state
export FAKE_PS_BEFORE='{"healthy": false, "issues": ["no-compatible-patchset"]}'
export FAKE_PS_AFTER='{"healthy": false, "issues": ["no-compatible-patchset"]}'
cat >"$BIN/fnos-patchset-fetch" <<'EOF'
#!/bin/sh
echo fetched >>"${FETCH_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/fnos-patchset-fetch"
export FNOS_PATCHSET_FETCH="$BIN/fnos-patchset-fetch" FETCH_LOG="$TMP/fetch.log"
out="$(run_wrap)"; rc=$?
[ "$rc" = 1 ] && ok "③ 不可修 → rc=1（waiting）" || bad "③ rc=$rc（期望 1）: $out"
grep -q fetched "$TMP/fetch.log" 2>/dev/null && ok "③ 调用了 fnos-patchset-fetch" || bad "③ 未取补丁集"
if [ -f "$TMP/state/state.json" ]; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not d["repairs_24h"] else 1)' "$TMP/state/state.json" \
    && ok "③ waiting 不烧预算" || bad "③ waiting 却记了预算"
else
  ok "③ waiting 不写预算文件（无动作）"
fi
unset FAKE_PS_BEFORE FAKE_PS_AFTER

# ---------- ④ 文件健康但 stale → 重启消费者 ----------
new_state
export FAKE_CC_STALE_TIMES=1 CC_COUNT="$TMP/cc.count"
printf 'sysinfo_service.service\n' >"$TMP/consumers.txt"
export FNOS_CONSUMERS_LIST="$TMP/consumers.txt"
export FAKE_PS_BEFORE='{"healthy": true, "issues": []}'
export SYSTEMCTL_LOG="$TMP/systemctl.log"
out="$(run_wrap)"; rc=$?
grep -q "restart sysinfo_service.service" "$SYSTEMCTL_LOG" 2>/dev/null && ok "④ 重启了 stale 消费者" || bad "④ 未重启 stale 消费者: $out"
unset FAKE_CC_STALE_TIMES CC_COUNT FAKE_PS_BEFORE

# ---------- ⑤ 并发锁 ----------
new_state
export FAKE_PS_BEFORE='{"healthy": false, "issues": ["AOB:x: ready"]}'
export FAKE_PS_AFTER='{"healthy": false, "issues": ["AOB:x: ready"]}'
export FAKE_PS_SLEEP=3
PATH="$BIN" "$PYTHON" "$WRAP" --json >"$TMP/first.out" 2>/dev/null &
p1=$!
sleep 0.5
out="$(run_wrap)"; rc=$?
wait $p1 || true
[ "$rc" = 1 ] && ok "⑤ 并发时第二个 → waiting（rc=1）" || bad "⑤ 第二个 rc=$rc（期望 1）: $out"
grep -q '正在运行' "$TMP/stderr.log" 2>/dev/null || grep -q '正在运行' <<<"$out" \
    && ok "⑤ 原因写明另一轮在跑" || bad "⑤ 原因未写明"
unset FAKE_PS_SLEEP FAKE_PS_BEFORE FAKE_PS_AFTER

# ---------- ⑥ flock 不可用 → waiting ----------
new_state
mv "$BIN/flock" "$TMP/flock.bak"
out="$(run_wrap)"; rc=$?
mv "$TMP/flock.bak" "$BIN/flock"
[ "$rc" = 1 ] && ok "⑥ 无 flock → waiting（fail-closed）" || bad "⑥ rc=$rc（期望 1）: $out"
grep -q 'flock 不可用' <<<"$out" && ok "⑥ 原因写明 flock 不可用" || bad "⑥ 原因未写明: $out"

# ---------- ⑦ 超时 ----------
new_state
export FAKE_PS_BEFORE='{"healthy": false, "issues": ["AOB:x: ready"]}'
export FAKE_PS_SLEEP=10
out="$(PATH="$BIN" "$PYTHON" "$WRAP" --json --max-seconds 1 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && ok "⑦ 超时 → failed（rc=2）" || bad "⑦ rc=$rc（期望 2）: $out"
grep -q '超时' <<<"$out" && ok "⑦ 原因写明超时" || bad "⑦ 原因未写明超时: $out"
unset FAKE_PS_SLEEP FAKE_PS_BEFORE

# ---------- ⑧ 活动闸门 ----------
new_state
export FAKE_PGREP_HIT=1
out="$(run_wrap)"; rc=$?
[ "$rc" = 1 ] && ok "⑧ 升级进行中 → waiting（rc=1）" || bad "⑧ rc=$rc（期望 1）: $out"
grep -q '进程在运行' <<<"$out" && ok "⑧ 原因写明升级/包管理进程" || bad "⑧ 原因未写明: $out"
unset FAKE_PGREP_HIT

# ---------- ⑨ state.json 合法 ----------
new_state
export FAKE_PS_BEFORE='{"healthy": false, "issues": ["AOB:x: ready"]}'
export FAKE_PS_AFTER='{"healthy": true, "issues": [], "auto_fix": {"fixed": 1, "failed": 0}}'
run_wrap >/dev/null 2>&1 || true
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/state/state.json" 2>/dev/null \
    && ok "⑨ state.json 是合法 JSON" || bad "⑨ state.json 解析失败"
unset FAKE_PS_BEFORE FAKE_PS_AFTER

# ---------- ⑩ force-apply 成功 ----------
export FAKE_PS_BEFORE='{"healthy": false, "issues": ["AOB:p1: ready-unverified"]}'
export FAKE_PS_AFTER='{"healthy": true, "issues": []}'
rm -f "$DIRFD_LOG"
out="$(run_wrap_force)"; rc=$?
grep -q -- "--force-unverified --patch-id p1" "$DIRFD_LOG" 2>/dev/null && ok "⑩ 用 --force-unverified --patch-id 调包装器" || bad "⑩ 未调用包装器: $(cat "$DIRFD_LOG" 2>/dev/null)"
grep -q -- "--restart-consumers" "$DIRFD_LOG" 2>/dev/null && ok "⑩ 带 --restart-consumers" || bad "⑩ 缺 --restart-consumers"
if [ "$rc" = 0 ]; then ok "⑩ force 后复核 healthy → rc=0"; else bad "⑩ rc=$rc（期望 0）: $out"; echo "--- stderr ---"; cat "$TMP/stderr.log"; echo "--- calls ---"; cat "${PS_COUNT}.log" 2>/dev/null; fi

# ---------- ⑪ force 失败 → failed ----------
export FAKE_DIRFD_RC=1
export FAKE_PS_AFTER='{"healthy": false, "issues": ["AOB:p1: ready-unverified"]}'
out="$(run_wrap_force)"; rc=$?
[ "$rc" = 2 ] && ok "⑪ force 失败 → rc=2（failed）" || bad "⑪ rc=$rc（期望 2）: $out"
grep -q '强制应用后仍有未验证补丁' <<<"$out" && ok "⑪ 原因点名未验证补丁" || bad "⑪ 原因不符: $out"
unset FAKE_DIRFD_RC FAKE_PS_BEFORE FAKE_PS_AFTER

printf '== patch-repair 测试: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]