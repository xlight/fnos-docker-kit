#!/usr/bin/env bash
# ============================================================================
# fnos-ota-resilience.sh —— OTA 韧性机制的宿主侧安装器
#
# 背景（fnos/44、45 号文）：
#   已部署容器（CT201）没有"机制安装"路径（fnos_deploy.sh 只推网络配置），
#   而 OTA 韧性的四个机制（update-grub shim / 补丁重放修复 / 消费者核对 / 清单）
#   必须能重复收敛到目标状态。本脚本就是那条路径。
#
# 用法：
#   sudo env CTID=201 bash scripts/fnos-ota-resilience.sh status
#   sudo env CTID=201 bash scripts/fnos-ota-resilience.sh apply
#   sudo env CTID=201 bash scripts/fnos-ota-resilience.sh revert
#
# 约定：
#   · 幂等：apply 可反复执行；revert 可反复执行
#   · 容器停机时 apply 只落文件与 unit，不 enable/start；status 标"待启动后生效"
#   · 每个 mutation 都 manifest_add（AGENTS.md 约定；模板 fnos-dirfd-shim.sh 没做）
#   · `pct push` **不保留执行位**，推送后必须 `pct exec chmod +x`（模板第 56 行同样处理）
#   · unit 正文从 toolchain/fnos_patch.py 的常量渲染，避免两份定义漂移
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CTID="${CTID:-}"
[ -n "$CTID" ] || die "必须显式传入 CTID（防误伤别的容器）：sudo env CTID=201 bash $0 …"
CMD="${1:-status}"
case "$CMD" in apply|status|revert) ;; *) printf '用法: %s apply|status|revert\n' "$0" >&2; exit 2;; esac

TC="$REPO/toolchain"
SHIM_SRC="$TC/fnos-update-grub-shim"
REPAIR_SRC="$TC/fnos-patch-repair"
CHECK_SRC="$TC/fnos-lib-consumers-check"
PS_SRC="$TC/fnos-patch-status"
PS_DST="/usr/local/sbin/fnos-patch-status"
LIST_SRC="$TC/fnos-lib-consumers"
UNIT_DIR="/etc/systemd/system"
SHIM_DST="/usr/local/sbin/update-grub"
REPAIR_DST="/usr/local/sbin/fnos-patch-repair"
CHECK_DST="/usr/local/sbin/fnos-lib-consumers-check"
LIST_DST="/usr/local/share/fnos-toolchain/lib-consumers.txt"
UNITS=("fnos-patch-repair.service" "fnos-patch-repair.timer")

need_root

ct_is_running() { pct status "$CTID" 2>/dev/null | grep -q running; }

render_unit() { # $1=fnos_patch.py 里的常量名 → stdout
  python3 - "$TC/fnos_patch.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fnos_patch", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.stdout.write(getattr(mod, sys.argv[2]))
PY
}

push_file() { # $1=宿主源 $2=容器目标 $3=mode
  local src="$1" dst="$2" mode="$3"
  [ -f "$src" ] || die "缺少源文件: $src"
  pct push "$CTID" "$src" "$dst" >/dev/null 2>&1 || die "推送失败: $dst"
  if ct_is_running; then
    pct exec "$CTID" -- chmod "$mode" "$dst" >/dev/null 2>&1 || warn "chmod $mode 失败: $dst"
  else
    warn "容器未运行：$dst 已推送，执行位待启动后重跑 apply 修正"
  fi
}

push_unit() { # $1=常量名 $2=unit 文件名
  local tmp="$HOST_BACKUP_ROOT/.ota-resilience-$2.tmp"
  mkdir -p "$HOST_BACKUP_ROOT"
  render_unit "$1" >"$tmp" || die "渲染 unit 失败: $1"
  pct push "$CTID" "$tmp" "$UNIT_DIR/$2" >/dev/null 2>&1 || die "推送 unit 失败: $2"
}

do_apply() {
  local running=0
  ct_is_running && running=1
  log "apply：CT$CTID（容器$([ "$running" = 1 ] && echo 运行中 || echo 已停机)）"

  push_file "$SHIM_SRC"   "$SHIM_DST"   0755
  push_file "$REPAIR_SRC" "$REPAIR_DST" 0755
  push_file "$CHECK_SRC"  "$CHECK_DST"  0755
  push_file "$PS_SRC"     "$PS_DST"     0755
  push_file "$LIST_SRC"   "$LIST_DST"   0644
  push_unit PATCH_REPAIR_UNIT  "fnos-patch-repair.service"
  push_unit PATCH_REPAIR_TIMER "fnos-patch-repair.timer"

  if [ "$running" = 1 ]; then
    pct exec "$CTID" -- systemctl daemon-reload >/dev/null 2>&1 || warn "daemon-reload 失败"
    pct exec "$CTID" -- systemctl enable --now fnos-patch-repair.timer >/dev/null 2>&1 \
      || warn "enable --now fnos-patch-repair.timer 失败"
    log "已 enable --now fnos-patch-repair.timer"
  else
    warn "容器未运行：unit 已落盘，未 enable/start；启动后重跑 apply 即可生效"
  fi

  manifest_add "$(printf '{"ts":"%s","mech":"ota-resilience","action":"apply","ctid":%s,"container_running":%s,"files":["%s","%s","%s","%s"],"units":["%s","%s"]}' \
    "$(date -Is)" "$CTID" "$running" "$SHIM_DST" "$REPAIR_DST" "$CHECK_DST" "$LIST_DST" "${UNITS[0]}" "${UNITS[1]}")"
  log "apply 完成"
}

do_revert() {
  local running=0
  ct_is_running && running=1
  log "revert：CT$CTID"
  if [ "$running" = 1 ]; then
    pct exec "$CTID" -- systemctl disable --now fnos-patch-repair.timer >/dev/null 2>&1 || true
    for u in "${UNITS[@]}"; do
      pct exec "$CTID" -- rm -f "$UNIT_DIR/$u" >/dev/null 2>&1 || true
    done
    pct exec "$CTID" -- systemctl daemon-reload >/dev/null 2>&1 || true
    for f in "$SHIM_DST" "$REPAIR_DST" "$CHECK_DST" "$LIST_DST"; do
      pct exec "$CTID" -- rm -f "$f" >/dev/null 2>&1 || true
    done
  else
    warn "容器未运行：跳过容器内清理（文件仍在 rootfs 里，启动后重跑 revert 可清理）"
  fi
  manifest_add "$(printf '{"ts":"%s","mech":"ota-resilience","action":"revert","ctid":%s,"container_running":%s}' \
    "$(date -Is)" "$CTID" "$running")"
  log "revert 完成（容器未运行时文件未清理）"
}

do_status() {
  local running=0
  ct_is_running && running=1
  if [ "$running" != 1 ]; then
    printf '{"ok":true,"ctid":%s,"container":"stopped","note":"容器未运行，无法核对（n/a）；启动后重跑 apply 即可生效"}\n' "$CTID"
    return 0
  fi

  local items=() ok=1
  check_file() { # $1=路径 $2=need_exec
    if pct exec "$CTID" -- test -f "$1" >/dev/null 2>&1; then
      if [ "$2" = 1 ] && ! pct exec "$CTID" -- test -x "$1" >/dev/null 2>&1; then
        items+=("{\"path\":\"$1\",\"state\":\"not-executable\"}"); ok=0
      else
        items+=("{\"path\":\"$1\",\"state\":\"ok\"}")
      fi
    else
      items+=("{\"path\":\"$1\",\"state\":\"missing\"}"); ok=0
    fi
  }
  check_file "$SHIM_DST" 1
  check_file "$REPAIR_DST" 1
  check_file "$CHECK_DST" 1
  check_file "$PS_DST" 1
  check_file "$LIST_DST" 0
  for u in "${UNITS[@]}"; do check_file "$UNIT_DIR/$u" 0; done

  local timer_state
  timer_state="$(pct exec "$CTID" -- systemctl is-enabled fnos-patch-repair.timer 2>/dev/null | tr -d '\r' | head -1)"
  [ "$timer_state" = "enabled" ] || { items+=("{\"path\":\"fnos-patch-repair.timer\",\"state\":\"not-enabled\",\"detail\":\"$timer_state\"}"); ok=0; }

  # shim 被绕过判据：need-depmod 比 marker 新 → 收尾没走 shim
  local bypass="no-evidence"
  if pct exec "$CTID" -- sh -c '[ -f /boot/need-depmod ] && [ -f /run/fnos-update-grub-shim.last ]' >/dev/null 2>&1; then
    if pct exec "$CTID" -- sh -c '[ /boot/need-depmod -nt /run/fnos-update-grub-shim.last ]' >/dev/null 2>&1; then
      bypass="bypassed"; ok=0
    else
      bypass="ok"
    fi
  fi

  local joined; joined="$(printf '%s,' "${items[@]}")"; joined="[${joined%,}]"
  printf '{"ok":%s,"ctid":%s,"container":"running","shim_bypass":"%s","items":%s}\n' \
    "$([ "$ok" = 1 ] && echo true || echo false)" "$CTID" "$bypass" "$joined"
  [ "$ok" = 1 ] && return 0 || return 1
}

case "$CMD" in
  apply)  do_apply ;;
  revert) do_revert ;;
  status) do_status ;;
esac