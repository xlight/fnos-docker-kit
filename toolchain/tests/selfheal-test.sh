#!/usr/bin/env bash
# selfheal-test.sh —— stor-selfheal.sh 的公开侧回归（不需要 PVE）
#
# 覆盖：
#   1. 语法正确（bash -n）
#   2. 缺 CTID → 明确用法错误（rc=2），不猜容器
#   3. 脚本不含宿主私有绝对路径（公开集可发布）
#   4. 关键判据都在（栈/配置/掩码/节点/挂载）+ 防抖与重启预算存在
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
SCRIPT="$TC/../scripts/stor-selfheal.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT"; exit 2; }

bash -n "$SCRIPT" && ok "语法正确" || bad "语法错误"

# 注意：脚本会 source lib.sh（默认 CTID=200），所以这里要显式清掉 CTID 才测得到"缺 CTID"
out="$(env -u CTID bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 2 ] && echo "$out" | grep -q "CTID"; then
  ok "缺 CTID → 明确用法错误（rc=2）"
else
  bad "缺 CTID 时行为不对（rc=$rc）: $out"
fi

if grep -nE '/home/[a-z0-9_-]+|/mnt/[A-Z0-9]' "$SCRIPT" | grep -v '^\s*#' >/dev/null; then
  bad "脚本含宿主私有绝对路径（不能进公开集）"
else
  ok "无宿主私有绝对路径"
fi

for pat in "chk_stack" "chk_conf" "chk_mask" "chk_nodes" "chk_mounts" "restart_guard" "SELFHEAL_NO_RESTART"; do
  if grep -q "$pat" "$SCRIPT"; then ok "含判据/护栏：$pat"; else bad "缺判据/护栏：$pat"; fi
done

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
