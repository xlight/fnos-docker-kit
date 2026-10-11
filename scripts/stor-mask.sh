#!/usr/bin/env bash
# stor-mask.sh —— 方案2：动态屏蔽 /sys/block，使"可见性 == 直通集合"
#
# 背景：LXC 不隔离 /sys，fnOS 读 /sys/block 会看到宿主的全部设备（sda/sdb/sdc、
# md126=VM104 的盘、dm-0..3=宿主根/swap/VM104 的 LV 等），从而把外来阵列列为
# "存储空间"并判 broken（如 vol1）。
#
# 做法：把 /sys/block 换成我们自造的目录（bind mount），里面只放**本容器需要**的
# 设备符号链接（指向真实 /sys/devices/...）。其余设备对 fnOS 不可见。
#
# 用法: sudo bash stor-mask.sh apply|rollback|status
#   DEVS="nvme0n1 md0 dm-4"   # 要暴露的设备（默认值；由 stor-manage 生成更佳）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CONF="/etc/pve/lxc/${CTID}.conf"
MASK="/var/lib/lxc/${CTID}/sysblock"
DEVS="${DEVS:-nvme0n1 md0 dm-4}"
ENTRY="lxc.mount.entry: ${MASK} sys/block none bind,create=dir"

conf_has() { grep -qF -- "$1" "$CONF" 2>/dev/null; }
conf_rewrite() { local tmp; tmp="$(mktemp)"; sed "$1" "$CONF" > "$tmp" && cat "$tmp" > "$CONF"; rm -f "$tmp"; }

build_mask() {
  # 原地更新：**不要 rm/mkdir 目录**，否则会破坏正在运行容器的 bind（会变成 //deleted）
  mkdir -p "$MASK"
  find "$MASK" -mindepth 1 -maxdepth 1 ! -name '.README' -delete 2>/dev/null || rm -f "$MASK"/*
  local d tgt
  for d in $DEVS; do
    [ -e "/sys/block/$d" ] || { warn "  /sys/block/$d 不存在，跳过"; continue; }
    tgt="$(readlink -f "/sys/block/$d")"
    ln -sfn "$tgt" "$MASK/$d"
    log "  暴露 $d -> $tgt"
  done
  # 隐藏其它一切：目录里只有这些符号链接
  printf '# stor-mask: 可见性==直通集合\n' > "$MASK/.README"
}

do_apply() {
  need_root
  log "== stor-mask apply (CT$CTID) 暴露: $DEVS =="
  build_mask
  conf_has "$ENTRY" || { printf '%s\n' "$ENTRY" >> "$CONF"; log "写入 bind: $ENTRY"; }
  manifest_add "$(printf '{"ts":"%s","script":"stor-mask","action":"apply","ctid":%s,"devs":"%s"}' "$(date -Is)" "$CTID" "$DEVS")"
  log "完成；需重启容器生效：pct reboot $CTID"
}

do_rollback() {
  need_root
  log "== stor-mask rollback (CT$CTID) =="
  if conf_has "$ENTRY"; then
    local t; t="$(mktemp)"; grep -vF -- "$ENTRY" "$CONF" > "$t" && cat "$t" > "$CONF"; rm -f "$t"
    log "移除 bind"
  fi
  rm -rf "$MASK"; log "删除掩码目录"
  manifest_add "$(printf '{"ts":"%s","script":"stor-mask","action":"rollback","ctid":%s}' "$(date -Is)" "$CTID")"
  log "完成；需重启容器生效：pct reboot $CTID"
}

do_status() {
  need_root
  log "== stor-mask status (CT$CTID) =="
  printf '  掩码目录   : %s\n' "$([ -d "$MASK" ] && echo 存在 || echo 缺失)"
  printf '  conf bind  : %s\n' "$(conf_has "$ENTRY" && echo 有 || echo 无)"
  printf '  暴露设备   : %s\n' "$(ls "$MASK" 2>/dev/null | grep -v '^\.README$' | tr '\n' ' ')"
  if pct status "$CTID" 2>/dev/null | grep -q running; then
    printf '  容器内可见 : %s\n' "$(ct sh -c 'ls /sys/block' 2>/dev/null | tr '\n' ' ')"
  fi
}

case "${1:-status}" in
  apply)    do_apply ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  *) echo "用法: $0 apply|rollback|status  （可用 DEVS=\"...\" 指定暴露设备）"; exit 2 ;;
esac
