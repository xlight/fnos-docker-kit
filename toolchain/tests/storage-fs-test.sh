#!/usr/bin/env bash
# ============================================================================
# tests/storage-fs-test.sh — 7.2：fnOS「存储空间」卷 fs = btrfs / zfs 验证
#   前提：CT<CTID> 已部署且运行（ext4 rootfs）。
#   对每个 fs：stor-manage destroy -> create VOLFS=<fs> -> reboot -> 断言 fnOS 挂载。
#   最后恢复为 ext4。
# 用法: sudo CTID=201 bash tests/storage-fs-test.sh
# ============================================================================
set -uo pipefail
CTID="${CTID:-201}"
VOLSTORE="${VOLSTORE:-wd500g}"
HERE_SM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="${SM:-$HERE_SM/../../scripts/stor-manage.sh}"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

[ "$(id -u)" = 0 ] || { echo "需 root"; exit 2; }

test_fs() {
  local fs="$1"
  echo "===== 存储卷 fs=$fs (CT$CTID) ====="
  CTID="$CTID" VOLFS="$fs" VOLSTORE="$VOLSTORE" bash "$SM" destroy >/dev/null 2>&1 || true
  # destroy 会停容器；create 需要容器 running
  pct start "$CTID" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do pct exec "$CTID" -- test -d /usr/trim >/dev/null 2>&1 && break; sleep 5; done
  CTID="$CTID" VOLFS="$fs" VOLSTORE="$VOLSTORE" bash "$SM" create 2>&1 | tail -5
  pct reboot "$CTID" >/dev/null 2>&1
  local v=""
  for i in $(seq 1 24); do
    v="$(pct exec "$CTID" -- sh -c 'findmnt -rno TARGET,FSTYPE | grep -E "^/vol[0-9]+ "' 2>/dev/null)"
    [ -n "$v" ] && break; sleep 10
  done
  echo "  容器内: ${v:-（无）}"
  if echo "$v" | grep -q " $fs"; then ok "fnOS 挂载 $fs 卷"; else no "fnOS 未挂载 $fs 卷"; fi
}

test_fs btrfs
test_fs zfs
echo "===== 恢复 ext4 ====="
CTID="$CTID" VOLFS=ext4 VOLSTORE="$VOLSTORE" bash "$SM" destroy >/dev/null 2>&1 || true
CTID="$CTID" VOLFS=ext4 VOLSTORE="$VOLSTORE" bash "$SM" create >/dev/null 2>&1 && \
  pct reboot "$CTID" >/dev/null 2>&1 || true

echo
echo "== storage-fs-test: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
