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

if grep -E '/home/[a-z0-9_-]+|/mnt/[A-Z0-9]' "$SCRIPT" | grep -v '^[[:space:]]*#' >/dev/null; then
  bad "脚本含宿主私有绝对路径（不能进公开集）"
else
  ok "无宿主私有绝对路径"
fi

for pat in "chk_stack" "chk_conf" "chk_mask" "chk_nodes" "chk_mounts" "restart_guard" "SELFHEAL_NO_RESTART" \
           "chk_ct" "chk_mountpoints" "start_guard" "fail-closed" "container_running"; do
  if grep -q "$pat" "$SCRIPT"; then ok "含判据/护栏：$pat"; else bad "缺判据/护栏：$pat"; fi
done

# ---- 2026-11-12 事故新增的断言（fail-closed 与动作验收）----
# ① 容器未运行时，节点/挂载两项必须判**不健康**（不是"跳过即通过"）
if grep -A2 'chk_nodes()' "$SCRIPT" | grep -q 'bad "容器未运行，无法核对容器内设备节点"'; then
  ok "fail-closed：节点检查在容器未运行时判红"
else
  bad "fail-closed 缺失：chk_nodes 在容器未运行时未判红"
fi
if grep -A2 'chk_mounts()' "$SCRIPT" | grep -q 'bad "容器未运行，无法核对 fnOS 卷登记与挂载"'; then
  ok "fail-closed：挂载检查在容器未运行时判红"
else
  bad "fail-closed 缺失：chk_mounts 在容器未运行时未判红"
fi
# ② 复核阶段不得把"跳过"当成通过：无法执行即计入不健康
if grep -q '无法执行' "$SCRIPT" && grep -q '复核' "$SCRIPT"; then
  ok "fail-closed 规则已写进巡检正文"
else
  bad "fail-closed 规则未写进巡检正文"
fi

# ---- 新脚本也要过公开侧的语法/路径门槛 ----
for extra in stor-mountpoint.sh stor-guard.sh stor-usb-reattach.sh; do
  escript="$TC/../scripts/$extra"
  if [ ! -f "$escript" ]; then bad "缺脚本：$extra"; continue; fi
  bash -n "$escript" && ok "语法正确：$extra" || bad "语法错误：$extra"
  if grep -E '/home/[a-z0-9_-]+|/mnt/[A-Z0-9]' "$escript" | grep -v '^[[:space:]]*#' >/dev/null; then
    bad "$extra 含宿主私有绝对路径（不能进公开集）"
  else
    ok "无宿主私有绝对路径：$extra"
  fi
done

# ---- 组件盘可见性相关机制必须在位（2026-11-12/14 实测缺陷的回归）----
MANAGE="$TC/../scripts/stor-manage.sh"
LIB="$TC/../scripts/lib.sh"
for pat in "chk_component" "fix_component" "component_parent" "action_lock_acquire" \
           "wait_container_settle" "component-fixes"; do
  if grep -q "$pat" "$SCRIPT"; then ok "自愈含组件盘机制：$pat"; else bad "自愈缺组件盘机制：$pat"; fi
done
for pat in "fix_md_member" "assemble_md" "ensure_md_autoassembly_guard" "FNO_MDADM"; do
  if grep -q "$pat" "$MANAGE"; then ok "栈脚本含成员纠正机制：$pat"; else bad "栈脚本缺成员纠正机制：$pat"; fi
done
for pat in "action_lock_acquire" "action_lock_release"; do
  if grep -q "$pat" "$LIB"; then ok "lib 含互斥锁：$pat"; else bad "lib 缺互斥锁：$pat"; fi
done
if [ -f "$TC/../scripts/stor-selfheal-component-test.sh" ]; then
  bash -n "$TC/../scripts/stor-selfheal-component-test.sh" \
    && ok "组件盘回归测试脚本语法正确" || bad "组件盘回归测试脚本语法错误"
else
  bad "缺组件盘回归测试脚本"
fi
for pat in "mp_source_is_stale" "mp_same_dev" "mountpoint-status.json" "期望运行状态\|expect" "start_budget_ok"; do
  if grep -Rq "$pat" "$TC/../scripts/stor-mountpoint.sh" "$TC/../scripts/stor-guard.sh"; then
    ok "新机制含判据：$pat"
  else
    bad "新机制缺判据：$pat"
  fi
done

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
