#!/usr/bin/env bash
# stor-mountdir.sh —— 方案(A)：把宿主大目录挂到 fnOS 卷的子目录下
#
# 用途：让"大数据"落在宿主大目录（灵活、可任意扩容），而 fnOS 的存储空间/应用仍在 zvol 上。
#   宿主目录 ──mpN──▶ 容器内 <CTDIR> ──(fnOS 挂载 <VOL> 之后)── bind ──▶ <VOL>/<SUBDIR>
#
# 用法: sudo bash stor-mountdir.sh apply|rollback|status
#   HOSTDIR=<宿主大目录>  （必填，无默认）
#   CTDIR=/mnt/hostdata          宿主目录在容器内的落点
#   VOL=/vol2  SUBDIR=data       fnOS 卷与子目录名
#   MPIDX=1                      mpN 序号
#
# 注意：数据不在 fnOS 那块带 prjquota 的 ext4 上 → **配额类功能（团队文件夹/回收站）失效**，
#       这是"目录挂载"路线的固有代价（见 ~/fnos/09-mountdir-options.md）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

HOSTDIR="${HOSTDIR:-}"
CTDIR="${CTDIR:-/mnt/hostdata}"
VOL="${VOL:-/vol2}"
SUBDIR="${SUBDIR:-data}"
MPIDX="${MPIDX:-1}"
NAME="${NAME:-fnos-data}"
UNIT="fnos-mountdir.service"
HELPER="/usr/local/sbin/fnos-mountdir.sh"
CONF="/etc/pve/lxc/${CTID}.conf"
MPLINE="mp${MPIDX}: ${HOSTDIR},mp=${CTDIR}"

conf_has() { grep -qF -- "$1" "$CONF" 2>/dev/null; }

helper_text() {
cat <<EOF
#!/bin/bash
# fnOS 目录挂载(A) helper —— 由 stor-mountdir.sh 生成
HOSTDIR="${CTDIR}"
TARGET="${VOL}/${SUBDIR}"
case "\$1" in
  up)
    # 等 fnOS 把存储卷挂上（最多 ~120s）
    for i in \$(seq 1 60); do mountpoint -q "${VOL}" && break; sleep 2; done
    mkdir -p "\$TARGET"
    if ! mountpoint -q "\$TARGET"; then mount --bind "\$HOSTDIR" "\$TARGET" && echo "bound \$HOSTDIR -> \$TARGET"; fi
    ;;
  down)
    mountpoint -q "\$TARGET" && umount "\$TARGET" 2>/dev/null || true
    ;;
  *) echo "用法: \$0 up|down"; exit 2 ;;
esac
EOF
}

do_apply() {
  need_root; need_ct
  [ -n "$HOSTDIR" ] || die "apply 需要 HOSTDIR（宿主大目录）"
  log "== stor-mountdir apply (CT$CTID) $HOSTDIR -> $VOL/$SUBDIR =="
  # 1) 宿主目录
  mkdir -p "$HOSTDIR"
  # 2) mpN 送进容器
  if ! conf_has "mp${MPIDX}: ${HOSTDIR}"; then
    printf '%s\n' "$MPLINE" >> "$CONF"
    log "写入 $MPLINE"
  fi
  # 3) 容器内 helper + unit
  local tmp; tmp="$(mktemp)"; helper_text > "$tmp"
  pct push "$CTID" "$tmp" "$HELPER" --perms 0755 >/dev/null; rm -f "$tmp"
  pct exec "$CTID" -- sh -c "cat > /etc/systemd/system/${UNIT}" <<EOF
[Unit]
Description=fnOS mountdir bind (${HOSTDIR} -> ${VOL}/${SUBDIR})
DefaultDependencies=no
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HELPER} up
ExecStop=${HELPER} down
[Install]
WantedBy=multi-user.target
EOF
  pct exec "$CTID" -- systemctl daemon-reload >/dev/null 2>&1 || true
  pct exec "$CTID" -- systemctl enable "$UNIT" >/dev/null 2>&1 || true
  # 4) 立即生效（若卷已挂）
  pct exec "$CTID" -- "$HELPER" up 2>/dev/null || true
  manifest_add "$(printf '{"ts":"%s","script":"stor-mountdir","action":"apply","ctid":%s,"hostdir":"%s","ctdir":"%s","target":"%s/%s"}' \
      "$(date -Is)" "$CTID" "$HOSTDIR" "$CTDIR" "$VOL" "$SUBDIR")"
  log "完成；宿主目录已挂到容器内 ${VOL}/${SUBDIR}（重启后由 ${UNIT} 自动重建）"
}

do_rollback() {
  need_root
  log "== stor-mountdir rollback (CT$CTID) =="
  pct exec "$CTID" -- "$HELPER" down >/dev/null 2>&1 || true
  pct exec "$CTID" -- systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  pct exec "$CTID" -- rm -f "/etc/systemd/system/${UNIT}" "$HELPER" >/dev/null 2>&1 || true
  pct exec "$CTID" -- systemctl daemon-reload >/dev/null 2>&1 || true
  conf_has "mp${MPIDX}: ${HOSTDIR}" && { local t; t="$(mktemp)"; grep -vF "mp${MPIDX}: ${HOSTDIR}" "$CONF" > "$t"; cat "$t" > "$CONF"; rm -f "$t"; log "移除 $MPLINE"; }
  manifest_add "$(printf '{"ts":"%s","script":"stor-mountdir","action":"rollback","ctid":%s,"hostdir":"%s"}' "$(date -Is)" "$CTID" "$HOSTDIR")"
  log "完成（宿主目录本身保留，未删除）"
}

do_status() {
  need_root
  log "== stor-mountdir status (CT$CTID) =="
  printf '  宿主目录 : %s (%s)\n' "$HOSTDIR" "$(du -sh "$HOSTDIR" 2>/dev/null | cut -f1 || echo '?')"
  printf '  conf mpN : %s\n' "$(conf_has "mp${MPIDX}: ${HOSTDIR}" && echo 有 || echo 无)"
  printf '  unit     : %s\n' "$(pct exec "$CTID" -- systemctl is-enabled "$UNIT" 2>/dev/null || echo 未启用)"
  if pct status "$CTID" 2>/dev/null | grep -q running; then
    printf '  容器内   : %s\n' "$(ct sh -c "findmnt -rno TARGET,SOURCE | grep '$CTDIR\|$VOL/$SUBDIR'" 2>/dev/null | tr '\n' ' ')"
    printf '  df       : %s\n' "$(ct sh -c "df -h '$VOL/$SUBDIR' 2>/dev/null | tail -1" 2>/dev/null)"
  fi
}

case "${1:-status}" in
  apply)    do_apply ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  *) echo "用法: $0 apply|rollback|status  (HOSTDIR/CTDIR/VOL/SUBDIR/MPIDX 可覆盖)"; exit 2 ;;
esac
