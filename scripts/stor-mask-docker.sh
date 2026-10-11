#!/usr/bin/env bash
# stor-mask-docker.sh —— Docker 版 /sys/block 掩码，使"可见性 == 透传集合"
#
# 背景：Docker 不隔离 /sys，fnOS 读 /sys/block 会看到宿主全部设备，
# 而 /dev 节点隔离（--device + cgroup）挡不住拓扑可见。对照 LXC 的 stor-mask.sh。
#
# 做法：自造掩码目录，只放透传设备的符号链接（指向真实 /sys/devices/...），
# 部署时 `-v <mask>:/sys/block` 覆盖容器内视图。宿主不受影响。
#
# 用法: sudo bash stor-mask-docker.sh apply|rollback|status
#   DOCKER_NAME="fnos-dm-cap" DEVS="nvme3n1 md127 dm-7"
#   DEVS 可为空（空集=全隐藏）；分区路径（如 nvme3n1p1）自动归并为整盘入口
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
[ -f "$SCRIPT_DIR/lib.sh" ] && source "$SCRIPT_DIR/lib.sh"

NAME="${DOCKER_NAME:-fnos-dm-cap}"
DEVS="${DEVS:-}"
MASK_BASE="${MASK_BASE:-/var/lib/fnos-docker-mask}"
MASK="$MASK_BASE/$NAME/sysblock"

mask_path() { printf '%s\n' "$MASK"; }

build_mask() {
  mkdir -p "$MASK"
  find "$MASK" -mindepth 1 -maxdepth 1 ! -name '.README' -delete 2>/dev/null || rm -f "$MASK"/* 2>/dev/null || true
  local d disk tgt
  for d in $DEVS; do
    # 整盘归并：分区路径（不在 /sys/block）归并为其所属整盘入口
    if [ -e "/sys/block/$d" ]; then
      disk="$d"
    elif [ -e "/sys/class/block/$d" ]; then
      disk="$(basename "$(dirname "$(readlink -f "/sys/class/block/$d")")")"
      [ -e "/sys/block/$disk" ] || { warn "  $d 的父设备 $disk 不在 /sys/block，跳过"; continue; }
      log "  归并分区 $d -> 整盘 $disk"
    else
      warn "  $d 不存在（/sys/block 与 /sys/class/block 均无），跳过"; continue
    fi
    [ -e "$MASK/$disk" ] && continue   # 去重（如同时传入盘与其分区）
    tgt="$(readlink -f "/sys/block/$disk")"
    ln -sfn "$tgt" "$MASK/$disk"
    log "  暴露 $disk -> $tgt"
  done
  printf '# stor-mask-docker: 可见性==透传集合\n' > "$MASK/.README"
}

do_apply() {
  need_root
  log "== stor-mask-docker apply (name=$NAME) 暴露: ${DEVS:-（空集=全隐藏）} =="
  build_mask
  manifest_add "$(printf '{"ts":"%s","script":"stor-mask-docker","action":"apply","name":"%s","devs":"%s"}' "$(date -Is)" "$NAME" "$DEVS")"
  log "完成；容器重建时加 -v $MASK:/sys/block 生效"
}

do_rollback() {
  need_root
  log "== stor-mask-docker rollback (name=$NAME) =="
  rm -rf "$MASK_BASE/$NAME"
  manifest_add "$(printf '{"ts":"%s","script":"stor-mask-docker","action":"rollback","name":"%s"}' "$(date -Is)" "$NAME")"
  log "完成；重建容器（去掉 -v）生效"
}

do_status() {
  need_root
  log "== stor-mask-docker status (name=$NAME) =="
  printf '  掩码目录   : %s\n' "$([ -d "$MASK" ] && echo 存在 || echo 缺失)"
  printf '  暴露设备   : %s\n' "$(ls "$MASK" 2>/dev/null | grep -v '^\.README$' | tr '\n' ' ')"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
    printf '  容器内可见 : %s\n' "$(docker exec "$NAME" sh -c 'ls /sys/block' 2>/dev/null | tr '\n' ' ')"
  fi
}

case "${1:-status}" in
  apply)    do_apply ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  mask-path) mask_path ;;
  *) echo "用法: $0 apply|rollback|status  （可用 DOCKER_NAME/DEVS 指定）"; exit 2 ;;
esac
