#!/usr/bin/env bash
# ============================================================================
# tests/deploy-test.sh — 7/8/9 端到端：release 镜像 -> 容器 -> 专属存储 -> 冒烟
#                       -> 幂等 -> 回撤
#
# 目标容器 CT201（复用为靶机；**会先销毁现有 CT201**）。
# 只新增专属资源；回撤只删专属。
#
# 用法: sudo bash tests/deploy-test.sh
#   CTID=201 VOLFS=ext4 STORAGE=<PVE存储池> VOLSTORE=<ZFS池> OUT=<release 目录>
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
CTID="${CTID:-201}"
STORAGE="${STORAGE:-}"
VOLFS="${VOLFS:-ext4}"
VOLSTORE="${VOLSTORE:-}"
SIZE="${SIZE:-12}"
OUT="${OUT:-}"
[ -n "$STORAGE" ] || { echo "需要 STORAGE（PVE 存储池名）"; exit 2; }
[ -n "$VOLSTORE" ] || { echo "需要 VOLSTORE（ZFS 池名）"; exit 2; }
[ -n "$OUT" ] || { echo "需要 OUT（release 输出目录）"; exit 2; }
IMAGE="$OUT/image.raw"
DEP="$TC/fnos_deploy.sh"
SM="$TC/../scripts/stor-manage.sh"

pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 2; }
[ -f "$IMAGE" ] || { echo "缺镜像 $IMAGE"; exit 2; }

echo "########## 0) 清理旧 CT$CTID ##########"
pct stop "$CTID" >/dev/null 2>&1 || true
pct destroy "$CTID" >/dev/null 2>&1 || true
CTID="$CTID" VOLSTORE="$VOLSTORE" CONFIRM_DESTROY=YES bash "$SM" destroy >/dev/null 2>&1 || true
pvesm free "${STORAGE}:${CTID}/vm-${CTID}-disk-0.raw" >/dev/null 2>&1 || true

echo "########## 7.1 安装镜像为容器 ##########"
bash "$DEP" install "$CTID" --image "$IMAGE" --hostname fnos-lxc --size "$SIZE" --storage "$STORAGE" \
  && ok "install 完成" || no "install 失败"

echo "== 等待启动 =="
for i in $(seq 1 40); do
  st="$(pct status "$CTID" 2>/dev/null | awk '{print $2}')"
  [ "$st" = running ] || { sleep 3; continue; }
  pct exec "$CTID" -- test -d /usr/trim >/dev/null 2>&1 && break
  sleep 3
done
bash "$DEP" smoke "$CTID" && ok "7.3/9.1 首轮冒烟（无存储）" || no "首轮冒烟"

echo "########## 7.2 专属存储（宿主侧） ##########"
CTID="$CTID" VOLFS="$VOLFS" VOLSTORE="$VOLSTORE" bash "$SM" create \
  && ok "stor-manage create（$VOLFS）" || no "stor-manage create"
pct reboot "$CTID" >/dev/null 2>&1 || true
sleep 25
bash "$DEP" smoke "$CTID" && ok "7.2/9.1 带存储冒烟" || no "带存储冒烟"

echo "########## 8.1 幂等 ##########"
bash "$DEP" install "$CTID" --image "$IMAGE" --storage "$STORAGE" >/dev/null 2>&1 \
  && ok "重复 install 无错" || no "重复 install"
CTID="$CTID" VOLFS="$VOLFS" VOLSTORE="$VOLSTORE" bash "$SM" create >/dev/null 2>&1 \
  && ok "重复 stor-manage create 无错" || no "重复 create"
bash "$DEP" smoke "$CTID" >/dev/null 2>&1 && ok "幂等后仍可用" || no "幂等后不可用"

echo "########## 8.2 回撤 ##########"
CTID="$CTID" VOLSTORE="$VOLSTORE" CONFIRM_DESTROY=YES bash "$SM" destroy >/dev/null 2>&1 || true
bash "$DEP" uninstall "$CTID" --storage "$STORAGE" >/dev/null 2>&1 \
  && ok "uninstall 完成" || no "uninstall"
pct status "$CTID" >/dev/null 2>&1 && no "容器未移除" || ok "容器已移除"
[ -e "/etc/pve/lxc/${CTID}.conf" ] && no "conf 残留" || ok "conf 已移除"
CTID=200 pct status 200 2>/dev/null | grep -q running && ok "CT200 未受影响" || echo "  NOTE: CT200 非 running（与回撤无关，请人工确认）"

echo
echo "== deploy-test: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
