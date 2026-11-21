#!/usr/bin/env bash
# ============================================================================
# publish-image-dispatch-test.sh —— publish.sh --image 的 dispatch 行为回归
#
# 从 publish.sh 抽出 --image 派发块（不跑完整发布链），用假 gh 断言：
#   ① --image X → gh workflow run public-ci.yml -R <slug> -f version=X -f channel=iso
#   ② dispatch 失败 → 只 WARN，块本身退出 0（发布不回滚）
#   ③ 无 --image → 不 dispatch
#
# 用法: bash toolchain/tests/publish-image-dispatch-test.sh
# 退出码: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH="$HERE/../publish.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

log() { printf '[publish] %s\n' "$*"; }   # publish.sh 的 log()（抽取块依赖）

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/pub"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
echo "$@" >> "$GH_LOG"
exit "${GH_RC:-0}"
EOF
chmod +x "$tmp/bin/gh"
git init -q "$tmp/pub"
git -C "$tmp/pub" remote add origin https://github.com/xlight/fnos-docker-kit.git

# 抽出 --image 派发块（if [ -n "$IMAGE_VER" ] ... fi）
block="$(sed -n '/^if \[ -n "\$IMAGE_VER" \]; then$/,/^fi$/p' "$PUBLISH")"
if [ -z "$block" ]; then
  echo "FAIL: 无法从 publish.sh 抽取 --image 块"
  exit 1
fi

run_block() { # $1=IMAGE_VER $2=GH_RC
  : > "$tmp/gh.log"
  export GH_LOG="$tmp/gh.log" GH_RC="$2"
  PATH="$tmp/bin:$PATH" IMAGE_VER="$1" PUB_REPO="$tmp/pub"
  eval "$block"
}

# ① 正常 dispatch
run_block 1.2.1011 0
calls="$(cat "$tmp/gh.log")"
if [ "$calls" = "workflow run public-ci.yml -R xlight/fnos-docker-kit -f version=1.2.1011 -f channel=iso" ]; then
  ok "① dispatch 参数正确（version/channel=iso/-R slug）"
else
  bad "① dispatch 参数不符: $calls"
fi

# ② dispatch 失败 → 块退出 0（只 WARN）
out="$(run_block 1.2.1011 1 2>&1)"
rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q "WARN"; then
  ok "② dispatch 失败只 WARN、不回滚（rc=0）"
else
  bad "② 失败路径不符: rc=$rc out=$out"
fi

# ③ 无 --image → 不 dispatch
: > "$tmp/gh.log"
IMAGE_VER="" PUB_REPO="$tmp/pub" GH_LOG="$tmp/gh.log" GH_RC=0
eval "$block"
if [ ! -s "$tmp/gh.log" ]; then
  ok "③ 无 --image 不 dispatch"
else
  bad "③ 无 --image 却 dispatch: $(cat "$tmp/gh.log")"
fi

echo "== publish-image-dispatch 测试: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]