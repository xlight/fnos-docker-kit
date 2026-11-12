#!/usr/bin/env bash
# ============================================================================
# stor-mountpoint-test.sh —— 宿主挂载点自愈机制的回归测试（不碰真实存储）
#
# 造的是事故同款状态：**同一块盘换了设备名**（loopA → loopB），
# 而旧挂载还挂在挂载点上 → 源指向已消失设备 = 僵尸挂载。
#
# 用法: sudo bash stor-mountpoint-test.sh
# 退出: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/stor-mountpoint.sh"
WORK="/tmp/opencode/stor-mp-test"
IMG="$WORK/disk.img"
MP="$WORK/mnt"
LABEL="STORMPTEST"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root"; exit 2; }; }
need_root
command -v losetup >/dev/null || { echo "缺 losetup"; exit 2; }
command -v mkfs.ext4 >/dev/null || { echo "缺 mkfs.ext4"; exit 2; }
command -v e2label >/dev/null || { echo "缺 e2label"; exit 2; }

cleanup() {
  mountpoint -q "$MP" && umount -l "$MP" 2>/dev/null
  for l in $(losetup -a 2>/dev/null | grep "$IMG" | cut -d: -f1); do losetup -d "$l" 2>/dev/null; done
  rm -f "/dev/disk/by-label/$LABEL" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
cleanup

mkdir -p "$MP"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
mkfs.ext4 -q -F "$IMG" >/dev/null 2>&1
LOOP_A="$(losetup --show -f "$IMG")"
e2label "$LOOP_A" "$LABEL" >/dev/null 2>&1
sleep 1
mount "$LOOP_A" "$MP" >/dev/null 2>&1 || { echo "挂载测试盘失败"; exit 2; }
echo "hello" > "$MP/probe.txt"

# --- ① 健康：标签解析与挂载源一致、且可读 ---
out="$(MP_LABELS="$LABEL:$MP" bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "OK"; then ok "① 健康挂载点判为 ok"; else bad "① 健康挂载点判错：$(printf '%s' "$out" | tr '\n' ' ')"; fi

# --- ② 缺盘：标签解析不到 ---
out="$(MP_LABELS="NO_SUCH_LABEL_XYZ:$MP" bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "FAIL"; then ok "② 标签解析不到 → 判红"; else bad "② 缺盘未判红：$(printf '%s' "$out" | tr '\n' ' ')"; fi

# --- ③ 盘符漂移：同一块盘换了设备名，旧挂载仍指向旧设备 ---
losetup -d "$LOOP_A" 2>/dev/null
LOOP_B="$(losetup --show -f "$IMG")"
e2label "$LOOP_B" "$LABEL" >/dev/null 2>&1
sleep 1
out="$(MP_LABELS="$LABEL:$MP" bash "$SCRIPT" check 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "FAIL"; then ok "③ 盘符漂移 → 判红（源与标签不一致/僵尸）"; else bad "③ 盘符漂移未判红：$(printf '%s' "$out" | tr '\n' ' ')"; fi

# --- ③b 判据单元断言：设备已消失 = 失效 ---
if bash "$SCRIPT" selftest 2>&1 | grep -q "^FAIL"; then bad "③b 失效判据单元断言失败"; else ok "③b 失效判据单元断言通过"; fi

# --- ④ apply 修复：摘僵尸挂载 + 按标签重挂 ---
out="$(MP_LABELS="$LABEL:$MP" bash "$SCRIPT" apply 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$MP/probe.txt" ] && [ "$(cat "$MP/probe.txt" 2>/dev/null)" = "hello" ]; then
  ok "④ apply 修复僵尸挂载并恢复数据可读"
else
  bad "④ apply 未修复：$(printf '%s' "$out" | tr '\n' ' ')"
fi

# --- ⑤ 幂等：再 apply 一次不改变挂载源、不报红 ---
src1="$(findmnt -n -o SOURCE --target "$MP" | head -1)"
out="$(MP_LABELS="$LABEL:$MP" bash "$SCRIPT" apply 2>&1)"; rc=$?
src2="$(findmnt -n -o SOURCE --target "$MP" | head -1)"
if [ "$rc" = 0 ] && [ "$src1" = "$src2" ]; then ok "⑤ 重复 apply 幂等"; else bad "⑤ 幂等失败：src1=$src1 src2=$src2"; fi

# --- ⑥ 审计：修复动作留了 manifest（manifest 路径由 lib.sh 决定，不写死宿主路径） ---
# shellcheck source=lib.sh
source "$HERE/lib.sh"
if tail -20 "$MANIFEST" 2>/dev/null | grep -q '"mech":"host-mountpoint"'; then
  ok "⑥ 修复动作已写审计"
else
  bad "⑥ 审计缺 host-mountpoint 记录"
fi

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
