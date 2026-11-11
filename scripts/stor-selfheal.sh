#!/usr/bin/env bash
# ============================================================================
# stor-selfheal.sh —— fnOS LXC 存储栈**自愈巡检**（宿主侧）
#
# 为什么要它：存储栈有太多"看起来正常、其实已经歪了"的状态，靠人发现太慢。
# 2026-11-11 一天内就撞了三种：
#   ① 宿主重启后 md/dm 号漂移 → 容器缺 /dev/dm-N → fnOS 每 6 秒重试挂载失败；
#   ② 宿主开机时 pmxcfs 还没重建 /etc/pve/lxc/<id>.conf → 透传写入全部落空；
#   ③ md 的**组件盘**没进容器的掩码视图 → fnOS 判 arrayState=broken（UI 显示已损坏），
#      而卷其实挂得好好的、数据完好。
#
# 本脚本把"健康"定义成**可机器判定**的几件事，逐项检查、按依赖顺序修复、修复后复核，
# 并做**防抖**（同一 CT 一小时内最多自动重启一次），避免修复动作自己变成故障源。
#
# 用法：
#   sudo env CTID=201 bash stor-selfheal.sh check     # 只检查，输出每项 OK/FAIL
#   sudo env CTID=201 bash stor-selfheal.sh repair    # 检查 + 修复 + 复核
#   sudo env CTID=201 bash stor-selfheal.sh repair --dry-run   # 只说要做什么，不做
#
# 环境变量：
#   CTID        目标容器（必填）
#   SELFHEAL_NO_RESTART=1   禁止自动重启容器（只修配置/掩码/节点）
#   SELFHEAL_COOLDOWN=3600  自动重启冷却秒（默认 3600）
#   SELFHEAL_STATE_DIR      状态目录（默认 /var/lib/fnos-stor/selfheal）
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CTID 必须在 source lib.sh **之前**取：lib.sh 会给 CTID 兜底 200，
# 那样"调用方忘了传 CTID"就会被悄悄指向别的容器。
CTID="${CTID:-}"
CMD="${1:-check}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
[ -n "$CTID" ] || { echo "用法: CTID=<id> bash $0 check|repair [--dry-run]" >&2; exit 2; }

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

STATE_DIR="${SELFHEAL_STATE_DIR:-/var/lib/fnos-stor/selfheal}"
RESTART_STATE="$STATE_DIR/ct${CTID}.restart"
COOLDOWN="${SELFHEAL_COOLDOWN:-3600}"
MASK="/var/lib/lxc/${CTID}/sysblock"
CONF="/etc/pve/lxc/${CTID}.conf"
STACK_STATE="/var/lib/fnos-stor/ct${CTID}.env"

log()  { printf '[selfheal] %s\n' "$*"; }
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }

ct_running() { pct status "$CTID" 2>/dev/null | grep -q running; }
ct_shm()     { pct exec "$CTID" -- sh -c "$1" 2>/dev/null; }

# ---------- 各项检查（返回 0=健康） ----------
chk_stack() { # 宿主侧存储栈完整（zvol/nvmet/md/VG/LV）
  [ -f "$STACK_STATE" ] || { bad "无栈状态文件 $STACK_STATE"; return 1; }
  local dm md
  dm="$(sed -n 's/^DM_DEV=//p' "$STACK_STATE")"
  md="$(sed -n 's/^MD_DEV=//p' "$STACK_STATE")"
  [ -n "$dm" ] && [ -e "$dm" ] || { bad "专属 LV 不存在: ${dm:-<空>}"; return 1; }
  [ -n "$md" ] && [ -e "$md" ] || { bad "md 阵列不存在: ${md:-<空>}"; return 1; }
  ok "宿主栈完整（$md → $dm）"
}

chk_conf() { # CT 配置：dev2 透传 + 组件/父盘 cgroup 放行
  [ -f "$CONF" ] || { bad "CT 配置不存在: $CONF"; return 1; }
  local need_ok=1 line
  # dev2 透传（LV 路径）
  grep -qE '^dev[0-9]+: /dev/trim_' "$CONF" || { bad "配置缺 LV 透传（devN: /dev/trim_…）"; need_ok=0; }
  # md / dm / nvme 分区 的放行（组件分区只被 fnOS 读 sysfs，不需要设备 I/O 放行）
  local want
  for want in md dm nvme-part; do
    local mm=""
    case "$want" in
      md)   mm="$(cat /sys/block/"$(sed -n 's/^MD_DEV=//p' "$STACK_STATE" | xargs -r -I{} basename {} 2>/dev/null)"/dev 2>/dev/null)" ;;
      dm)   mm="$(cat "$(readlink -f "$(sed -n 's/^DM_DEV=//p' "$STACK_STATE")")/dev" 2>/dev/null)" ;;
      nvme-part) mm="$(cat /sys/class/block/"$(sed -n 's/^NVME_DEV=//p' "$STACK_STATE")"p1/dev 2>/dev/null)" ;;
    esac
    [ -n "$mm" ] || continue
    grep -q "b ${mm%%:*}:${mm##*:} " "$CONF" || { bad "配置缺放行（$want）: $mm"; need_ok=0; }
  done
  [ "$need_ok" = 1 ] && ok "CT 配置（透传 + 放行）完整"
  return $((1-need_ok))
}

chk_mask() { # 掩码视图：条目在、软链不悬空、组件分区在
  [ -d "$MASK" ] || { bad "掩码目录不存在: $MASK"; return 1; }
  local rc=0 e t
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    t="$(readlink -f "$MASK/$e" 2>/dev/null)"
    if [ -z "$t" ] || [ ! -e "$t" ]; then bad "掩码条目悬空: $e"; rc=1; fi
  done < <(ls "$MASK" 2>/dev/null | grep -v '^\.README$')
  # md 的组件分区必须在视图里（fnOS 判 md 健康要找它）
  local comp cn
  comp="$(sed -n 's/^MD_DEV=//p' "$STACK_STATE" | xargs -r -I{} basename {} 2>/dev/null)"
  if [ -n "$comp" ]; then
    for c in /sys/block/"$comp"/slaves/*; do
      [ -e "$c" ] || continue
      cn="$(basename "$c")"
      [ -L "$MASK/$cn" ] || { bad "掩码缺组件盘: $cn（fnOS 会判 arrayState=broken）"; rc=1; }
    done
  fi
  [ "$rc" = 0 ] && ok "掩码视图完整（无悬空、组件在）"
  return $rc
}

chk_nodes() { # 容器 /dev 节点覆盖掩码视图
  ct_running || { warn "容器未运行，跳过节点检查"; return 0; }
  local missing=""
  for e in $(ls "$MASK" 2>/dev/null | grep -v '^\.README$'); do
    case "$e" in
      dm-*|md*|nvme*|sd*|vd*|zd*) ;;
      *) continue;;
    esac
    ct_shm "test -e /dev/$e" || missing="$missing $e"
  done
  if [ -n "$missing" ]; then bad "容器缺设备节点:$missing"; return 1; fi
  ok "容器设备节点齐全"
}

chk_mounts() { # 登记在册的卷都挂上了
  ct_running || { warn "容器未运行，跳过挂载检查"; return 0; }
  local miss=""
  local qout
  qout="$(ct_shm "sudo -u postgres psql -d trim -t -A -c \"select id from mount where uuid='$(sed -n 's/^VG=//p' "$STACK_STATE")'\"" 2>&1 | tr -d ' \r')"
  case "$qout" in
    *"could not connect"*|*"does not exist"*|*"ERROR"*)
      bad "容器内查询 fnOS 挂载登记失败（DB 不可达，判定不可信）: $qout"
      return 1;;
  esac
  local ids
  ids="$(ct_shm "sudo -u postgres psql -d trim -t -A -c \"select id from mount order by id\"" 2>/dev/null | tr -d ' \r')"
  [ -n "$ids" ] || { bad "拿不到 fnOS 的卷登记（mount 表为空）"; return 1; }
  local mp
  for mp in $ids; do
    case "$mp" in [0-9]*) ;; *) continue;; esac
    local vol="/vol$mp"
    ct_shm "grep -q ' $vol ' /proc/mounts" || miss="$miss $vol"
  done
  if [ -n "$miss" ]; then bad "卷未挂载:$miss"; return 1; fi
  ok "登记卷均已挂载"
}

# ---------- 修复动作 ----------
fix_stack() { log "修复：重建宿主存储栈（stor-manage up）"; CTID="$CTID" bash "$SCRIPT_DIR/stor-manage.sh" up; }
fix_conf()  { log "修复：重写透传与放行（stor-manage up）"; CTID="$CTID" bash "$SCRIPT_DIR/stor-manage.sh" up; }
fix_mask()  { log "修复：重建掩码视图"; CTID="$CTID" bash "$SCRIPT_DIR/stor-manage.sh" up; if [ -x "$SCRIPT_DIR/stor-usb.sh" ]; then CTID="$CTID" bash "$SCRIPT_DIR/stor-usb.sh" apply; fi; }
fix_nodes() { log "修复：容器内重建节点（重启节点 unit）"; ct_running && pct exec "$CTID" -- systemctl restart "fnos-stornode-${CTID}.service" 2>/dev/null; }

restart_guard() { # 防抖：冷却期 + 24h 预算（防抖是为了不反复重启同一台容器）
  [ "${SELFHEAL_NO_RESTART:-0}" = "1" ] && { warn "按 SELFHEAL_NO_RESTART=1 跳过自动重启"; return 1; }
  local last now
  last="$(cat "$RESTART_STATE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    warn "冷却期内（$((COOLDOWN/60)) 分钟内已重启过），本轮不自动重启"
    return 1
  fi
  # 24h 内最多 2 次自动重启：修不好就交给人，别自己变成故障源
  local budget=0 old
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    [ $((now - old)) -lt 86400 ] && budget=$((budget+1))
  done < <(cat "$STATE_DIR/ct${CTID}.restarts" 2>/dev/null)
  if [ "$budget" -ge 2 ]; then
    warn "24h 内已自动重启 ${budget} 次（预算上限），本轮不再重启——需要人工介入"
    return 1
  fi
  log "修复：重启容器让 cgroup/绑定/挂载重新生效（pct reboot $CTID）"
  pct reboot "$CTID"
  echo "$now" > "$RESTART_STATE"
  echo "$now" >> "$STATE_DIR/ct${CTID}.restarts"
  return 0
}

ensure_unit() { # 宿主侧开机 + 定时巡检单元
  local U="/etc/systemd/system/fnos-stor-selfheal-ct${CTID}.service"
  local T="/etc/systemd/system/fnos-stor-selfheal-ct${CTID}.timer"
  cat > "$U" <<EOF
[Unit]
Description=fnOS LXC storage self-heal check (CT${CTID})
After=fnos-stor-ct${CTID}.service
Wants=fnos-stor-ct${CTID}.service

[Service]
Type=oneshot
Environment=CTID=${CTID}
ExecStart=${SCRIPT_DIR}/stor-selfheal.sh repair
EOF
  cat > "$T" <<EOF
[Unit]
Description=定时巡检 fnOS LXC 存储栈（CT${CTID}）

[Timer]
OnBootSec=10min
OnUnitActiveSec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "fnos-stor-selfheal-ct${CTID}.timer" >/dev/null 2>&1 && log "已启用自愈巡检 timer：$(basename "$T")"
}

main() {
  [ "$CMD" = "check" ] || [ "$CMD" = "repair" ] || { echo "用法: $0 check|repair" >&2; exit 2; }
  need_root
  mkdir -p "$STATE_DIR"
  log "== stor-selfheal $CMD (CT$CTID) =="
  [ "$CMD" = "repair" ] && ensure_unit

  local rc_stack=0 rc_conf=0 rc_mask=0 rc_nodes=0 rc_mounts=0
  chk_stack   || rc_stack=1
  chk_conf    || rc_conf=1
  chk_mask    || rc_mask=1
  chk_nodes   || rc_nodes=1
  chk_mounts  || rc_mounts=1

  local bad_count=$((rc_stack+rc_conf+rc_mask+rc_nodes+rc_mounts))
  if [ "$bad_count" = 0 ]; then
    log "全部检查通过，无需修复"
    manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-check","ctid":%s,"result":"healthy"}' "$(date -Is)" "$CTID")"
    exit 0
  fi
  log "发现 $bad_count 项不健康"
  if [ "$CMD" = "check" ]; then
    manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-check","ctid":%s,"result":"unhealthy","items":%s}' "$(date -Is)" "$CTID" "$bad_count")"
    exit 1
  fi

  [ "$DRY" = 1 ] && { log "DRY-RUN：只诊断不修复"; exit 1; }

  # 修复顺序：栈 → 配置/放行 → 掩码 → 节点 →（必要时）重启容器
  [ "$rc_stack" = 1 ]  && fix_stack
  [ "$rc_conf" = 1 ]   && fix_conf
  [ "$rc_mask" = 1 ]   && fix_mask
  [ "$rc_nodes" = 1 ]  && fix_nodes
  # 挂载缺失 / 放行改动 → 必须重启容器才生效
  if [ "$rc_mounts" = 1 ] || [ "$rc_conf" = 1 ] || [ "$rc_mask" = 1 ]; then
    if restart_guard; then RESTARTED=1; fi
  fi

  if [ -n "${RESTARTED:-}" ]; then
    log "等待容器起来并让 fnOS 完成挂载（最多 240s）…"
    local waited=0 okv=0
    while [ "$waited" -lt 240 ]; do
      sleep 15; waited=$((waited+15))
      if ct_running && chk_mounts >/dev/null 2>&1; then okv=1; break; fi
    done
    [ "$okv" = 1 ] && log "卷已在 ${waited}s 内挂好" || warn "等待超时（${waited}s），卷可能仍未挂上"
  else
    sleep 20
  fi
  log "复核："
  local again=0
  chk_stack  || again=1
  chk_conf   || again=1
  chk_mask   || again=1
  chk_nodes  || again=1
  chk_mounts || again=1
  if [ "$again" = 0 ]; then
    log "自愈完成：全部检查通过"
    manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-repair","ctid":%s,"result":"repaired"}' "$(date -Is)" "$CTID")"
    exit 0
  fi
  log "自愈未完全成功（仍有不健康项），需人工介入"
  manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-repair","ctid":%s,"result":"failed"}' "$(date -Is)" "$CTID")"
  exit 1
}

main "$@"
