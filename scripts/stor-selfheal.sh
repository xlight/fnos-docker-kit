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
# 2026-11-12 事故后的两条硬规矩（见 fnos/41-usb-reenum-mountpoint-selfheal-gap.md）：
#   ① **fail-closed**：某项检查因前提缺失（容器未运行）而无法执行时判为**不健康**，
#      不得以"跳过"当作通过 —— 事故里正是"容器没跑 → 跳过节点/挂载检查 → 结论'全部通过'"，
#      让 NAS 实际停机 2 小时无人察觉；
#   ② **动作要验收**：重启/拉起后必须复核"容器真的在跑**且**卷挂好"，
#      没有"超时但仍算通过"这条路径。
#
# 用法：
#   sudo env CTID=201 bash stor-selfheal.sh check     # 只检查，输出每项 OK/FAIL
#   sudo env CTID=201 bash stor-selfheal.sh repair    # 检查 + 修复 + 复核
#   sudo env CTID=201 bash stor-selfheal.sh repair --dry-run   # 只说要做什么，不做
#   sudo env CTID=201 bash stor-selfheal.sh check --json       # stdout 只有 JSON
#
# 环境变量：
#   CTID        目标容器（必填）
#   SELFHEAL_NO_RESTART=1   禁止自动重启/拉起容器（只修配置/掩码/节点）
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
JSON_MODE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    --json)    JSON_MODE=1;;
  esac
done
[ -n "$CTID" ] || { echo "用法: CTID=<id> bash $0 check|repair [--dry-run] [--json]" >&2; exit 2; }

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

STATE_DIR="${SELFHEAL_STATE_DIR:-/var/lib/fnos-stor/selfheal}"
RESTART_STATE="$STATE_DIR/ct${CTID}.restart"
COOLDOWN="${SELFHEAL_COOLDOWN:-3600}"
MASK="/var/lib/lxc/${CTID}/sysblock"
CONF="/etc/pve/lxc/${CTID}.conf"
STACK_STATE="/var/lib/fnos-stor/ct${CTID}.env"

log()  { if [ "$JSON_MODE" = 1 ]; then printf '[selfheal] %s\n' "$*" >&2; else printf '[selfheal] %s\n' "$*"; fi; }
# QUIET=1 时只打印不记账（轮询等待阶段的临时检查不进最终汇总）
QUIET=0
ok()   { if [ "$JSON_MODE" = 1 ]; then printf '  OK    %s\n' "$*" >&2; else printf '  OK    %s\n' "$*"; fi; [ "$QUIET" = 1 ] || RESULTS+=("$(printf '%s\tok\t%s' "$CHECK_NAME" "$*")"); }
bad()  { if [ "$JSON_MODE" = 1 ]; then printf '  FAIL  %s\n' "$*" >&2; else printf '  FAIL  %s\n' "$*"; fi; [ "$QUIET" = 1 ] || RESULTS+=("$(printf '%s\tbad\t%s' "$CHECK_NAME" "$*")"); }
warn() { if [ "$JSON_MODE" = 1 ]; then printf '  WARN  %s\n' "$*" >&2; else printf '  WARN  %s\n' "$*"; fi; [ "$QUIET" = 1 ] || RESULTS+=("$(printf '%s\twarn\t%s' "$CHECK_NAME" "$*")"); }

# 逐项检查结论的机器可读汇总（--json 时 stdout 只有 JSON，人读日志走 stderr）
CHECK_NAME="-"
RESULTS=()
STATUS_FILE="$STATE_DIR/status-ct${CTID}.json"
emit_status_json() { # <healthy:0|1> [container_running:0|1]
  python3 - "$CTID" "$1" "$STATUS_FILE" "${2:-0}" "${RESULTS[@]}" <<'PY'
import datetime, json, os, sys
ctid, healthy, path, running = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4] == "1"
checks = []
for line in sys.argv[5:]:
    parts = line.split("\t")
    if len(parts) == 3:
        checks.append({"name": parts[0], "level": parts[1], "detail": parts[2]})
bad_n = sum(1 for c in checks if c["level"] == "bad")
doc = {"ctid": int(ctid), "healthy": healthy,
       "container_running": running,
       "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "checks": checks,
       "summary": ("全部检查通过" if healthy else "存在 %d 项不健康" % bad_n)}
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
except OSError:
    pass
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
}

ct_running() { pct status "$CTID" 2>/dev/null | grep -q running; }
ct_shm()     { pct exec "$CTID" -- sh -c "$1" 2>/dev/null; }

# ---------- 各项检查（返回 0=健康） ----------
# 巡检 **fail-closed**：某项检查因前提缺失而无法执行时判为**不健康**，
# 不得以"跳过"当作通过（2026-11-12 事故根因，见 fnos/41-usb-reenum-mountpoint-selfheal-gap.md）。

chk_ct() { # 目标容器必须在运行（NAS 停机是最严重的故障，不能被"跳过"掩盖）
  if ct_running; then ok "容器在运行"; return 0; fi
  bad "容器未运行（stopped）——NAS 当前不可用"
  return 1
}

chk_mountpoints() { # 宿主 PVE 存储挂载点必须有效（源与标签一致且可读）
  local out healthy
  out="$(bash "$SCRIPT_DIR/stor-mountpoint.sh" status 2>/dev/null)"
  healthy="$(printf '%s' "$out" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("healthy") else "0")' 2>/dev/null || echo 0)"
  if [ "$healthy" = "1" ]; then ok "宿主存储挂载点有效"; return 0; fi
  local detail
  detail="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("挂载点状态不可读"); raise SystemExit
bad=[m for m in d.get("mountpoints",[]) if not m.get("healthy")]
if not bad: print("挂载点状态不可读")
else: print("; ".join("%s(%s): %s"%(m["mountpoint"],m["label"],m["reason"]) for m in bad))
' 2>/dev/null)"
  bad "宿主存储挂载点失效：${detail:-状态不可读}"
  return 1
}

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
  # md 的组件必须可见：独立条目，**或**经其父盘的 sysfs 子树可达（父盘暴露即可）
  local comp cn
  comp="$(sed -n 's/^MD_DEV=//p' "$STACK_STATE" | xargs -r -I{} basename {} 2>/dev/null)"
  if [ -n "$comp" ]; then
    for c in /sys/block/"$comp"/slaves/*; do
      [ -e "$c" ] || continue
      cn="$(basename "$c")"
      local cparent pname
      cparent="$(dirname "$(readlink -f "$c" 2>/dev/null)" 2>/dev/null)"
      pname="$(basename "$cparent" 2>/dev/null)"
      if [ ! -L "$MASK/$cn" ] && [ -z "$pname" -o ! -L "$MASK/$pname" ]; then
        bad "掩码缺组件盘: $cn（fnOS 会判 arrayState=broken）"; rc=1
      fi
    done
  fi
  # **分区不得单独暴露**：fnOS 的磁盘清单按"名字以 sd 开头"收集 /sys/block 条目，
  # 单独暴露的分区会被当成第二块盘 → 同一块物理盘在存储视图里出现两次（2026-11-12 实测）。
  # 判定不靠名字（dm-2/md126/nvme1n1 都带数字，但不是分区），而看 sysfs 形态：
  # 分区的路径形如 .../block/<整盘>/<分区>（比整盘多一层）。
  for e in $(ls "$MASK" 2>/dev/null | grep -v '^\.README$'); do
    local mtgt; mtgt="$(readlink -f "$MASK/$e" 2>/dev/null)"
    case "$mtgt" in
      */block/*/*) bad "掩码含分区独立条目: $e（会被 fnOS 当成第二块盘）"; rc=1;;
    esac
  done
  [ "$rc" = 0 ] && ok "掩码视图完整（无悬空、组件在、无分区独立条目）"
  return $rc
}

# 组件分区 → 父盘名（fnOS 按父盘解析组件）：
#   sdc1 → sdc（去掉尾号）｜nvme1n1p1 → nvme1n1（去掉 pN）｜zd0p1 → zd0｜本身是整盘则原样
component_parent() { # $1=组件设备名
  case "$1" in
    *p[0-9]) printf '%s\n' "${1%p[0-9]*}";;
    *[0-9])  printf '%s\n' "${1%%[0-9]*}";;
    *)       printf '%s\n' "$1";;
  esac
}

chk_component() { # (l) md 组件的父盘必须能被 fnOS 识别为"盘"
  # 后端存储（zvol）没有盘身份（无 ID_MODEL/ID_SERIAL）→ fnOS 的数组视图里没有组件盘
  # → 界面显示「缺失 disk 状态」（2026-11-12 实测）。
  local md comp parent
  md="$(sed -n 's/^MD_DEV=//p' "$STACK_STATE" 2>/dev/null)"
  [ -n "$md" ] || { bad "无 md 设备信息（$STACK_STATE）"; return 1; }
  local mdb; mdb="$(basename "$(readlink -f "$md" 2>/dev/null)" 2>/dev/null)"
  [ -n "$mdb" ] || { bad "md 设备不存在: $md"; return 1; }
  comp="$(ls /sys/block/"$mdb"/slaves/ 2>/dev/null | head -1)"
  [ -n "$comp" ] || { bad "md $mdb 没有组件（slaves 为空）"; return 1; }
  parent="$(component_parent "$comp")"
  if [ -e "/sys/block/$parent/device" ] \
     && { [ -s "/sys/block/$parent/device/model" ] || [ -s "/sys/block/$parent/device/serial" ]; }; then
    ok "md $mdb 组件 $comp 的父盘 $parent 有盘身份（fnOS 可识别）"
    return 0
  fi
  bad "md $mdb 组件 $comp 的父盘 $parent 无盘身份（fnOS 会显示「缺失 disk 状态」）"
  return 1
}

chk_nodes() { # 容器 /dev 节点覆盖掩码视图
  # fail-closed：容器没跑就核不了节点 → 不健康（不是"跳过即通过"）
  ct_running || { bad "容器未运行，无法核对容器内设备节点"; return 1; }
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
  # fail-closed：容器没跑就查不到 fnOS 的挂载登记 → 不健康（DB 不可达时同样判不健康）
  ct_running || { bad "容器未运行，无法核对 fnOS 卷登记与挂载"; return 1; }
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
fix_mountpoints() { # 宿主挂载点先修：轻量，不打断正在运行的容器
  log "修复：宿主存储挂载点（按标签重挂）"
  bash "$SCRIPT_DIR/stor-mountpoint.sh" apply
}

# 容器停机时的**拉起**（不是重启）：重启一个已停的容器没有意义，
# 且 PVE 启动容器前要先激活存储 —— 宿主挂载点坏着时启动必然失败。
start_guard() { # 与 restart_guard 同一套防抖（冷却期 + 24h 预算）
  [ "${SELFHEAL_NO_RESTART:-0}" = "1" ] && { warn "按 SELFHEAL_NO_RESTART=1 跳过自动拉起"; return 1; }
  local now last
  now="$(date +%s)"
  last="$(cat "$RESTART_STATE" 2>/dev/null || echo 0)"
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    warn "冷却期内（$((COOLDOWN/60)) 分钟内已动过容器），本轮不自动拉起"
    return 1
  fi
  local budget=0 old
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    [ $((now - old)) -lt 86400 ] && budget=$((budget+1))
  done < <(cat "$STATE_DIR/ct${CTID}.restarts" 2>/dev/null)
  if [ "$budget" -ge 2 ]; then
    warn "24h 内已自动动过容器 ${budget} 次（预算上限），本轮不再拉起——需要人工介入"
    return 1
  fi
  return 0
}

fix_start() { # 拉起并记账（与重启共用预算）
  # 与存活巡检互斥：巡检正在拉起时不要重复动作
  action_lock_acquire "$CTID" 0 || { warn "另一破坏性动作在跑（锁占用），跳过拉起"; return 1; }
  log "修复：拉起容器（pct start $CTID）"
  local now; now="$(date +%s)"
  pct start "$CTID" >/dev/null 2>&1
  echo "$now" > "$RESTART_STATE"
  echo "$now" >> "$STATE_DIR/ct${CTID}.restarts"
  manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-start","ctid":%s,"result":"attempted"}' "$(date -Is)" "$CTID")"
  action_lock_release
  return 0
}

budget_guard() { # 只做预算判定（冷却期 + 24h 次数），不动作
  local last now
  last="$(cat "$RESTART_STATE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    warn "冷却期内（$((COOLDOWN/60)) 分钟内已动过容器），本轮不动作"
    return 1
  fi
  # 24h 内最多 2 次自动动作：修不好就交给人，别自己变成故障源
  local budget=0 old
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    [ $((now - old)) -lt 86400 ] && budget=$((budget+1))
  done < <(cat "$STATE_DIR/ct${CTID}.restarts" 2>/dev/null)
  if [ "$budget" -ge 2 ]; then
    warn "24h 内已自动动过容器 ${budget} 次（预算上限），本轮不再动作——需要人工介入"
    return 1
  fi
  return 0
}

fix_component() { # md 成员被后端存储抢走 → 停容器 → 重放 stor-manage up（重装配）→ 起容器
  # 用**独立预算**（ct<N>.component-fixes）：本修复必须停容器，与普通重启同源但性质不同
  # （普通重启预算被别的事务占满时，若共用预算，本项就永远修不了 → 违背"能自动修复"）。
  [ "${SELFHEAL_NO_RESTART:-0}" = "1" ] && { warn "按 SELFHEAL_NO_RESTART=1 跳过自动纠正"; return 1; }
  # 与存活巡检互斥：修复期间不许有人把容器拉起来
  action_lock_acquire "$CTID" 0 || { warn "另一破坏性动作在跑（锁占用），本轮跳过组件纠正"; return 1; }
  local cf="$STATE_DIR/ct${CTID}.component-fixes" now last cnt=0 t
  now="$(date +%s)"
  mkdir -p "$STATE_DIR"
  last="$(tail -1 "$cf" 2>/dev/null || echo 0)"; [ -n "$last" ] || last=0
  if [ $((now - last)) -lt "${COMPONENT_COOLDOWN:-1800}" ]; then
    warn "组件纠正冷却期内（${COMPONENT_COOLDOWN:-1800}s 内已纠正过），本轮跳过"
    action_lock_release
    return 1
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ $((now - t)) -lt 86400 ] && cnt=$((cnt+1))
  done < <(cat "$cf" 2>/dev/null)
  if [ "$cnt" -ge "${COMPONENT_BUDGET:-2}" ]; then
    warn "24h 内已纠正组件 ${cnt} 次（预算上限 ${COMPONENT_BUDGET:-2}），需人工介入"
    action_lock_release
    return 1
  fi
  log "修复：纠正 md 成员（停容器 → 重放 stor-manage up 重装配 → 起容器）"
  if ct_running; then
    pct stop "$CTID" >/dev/null 2>&1
    log "已停容器（释放卷占用）"
  fi
  CTID="$CTID" bash "$SCRIPT_DIR/stor-manage.sh" up >/dev/null 2>&1
  pct start "$CTID" >/dev/null 2>&1
  echo "$now" >> "$cf"
  manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-fix-component","ctid":%s,"result":"attempted"}' "$(date -Is)" "$CTID")"
  action_lock_release
  return 0
}

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
  action_lock_acquire "$CTID" 0 || { warn "另一破坏性动作在跑（锁占用），跳过重启"; return 1; }
  pct reboot "$CTID"
  echo "$now" > "$RESTART_STATE"
  echo "$now" >> "$STATE_DIR/ct${CTID}.restarts"
  action_lock_release
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

# 容器刚启动时，节点/卷挂载必然查不到（还没就绪）→ **等它稳定**，
# 否则会把"启动中"当成故障去做重启（把正在启动的容器又重启一遍 = 自愈变故障源）。
wait_container_settle() { # 最多等 $1 秒（默认 300）
  local max="${1:-300}" waited=0 up
  while [ "$waited" -lt "$max" ]; do
    ct_running || return 0
    up="$(ct_shm "cut -d' ' -f1 /proc/uptime" 2>/dev/null | tr -d ' \r' | cut -d. -f1)"
    [ -n "${up:-}" ] || up=999
    # 容器已运行 ≥180s 且卷已挂载 → 认为已稳定
    if [ "$up" -ge 180 ] && chk_mounts_quiet; then return 0; fi
    sleep 15; waited=$((waited+15))
  done
  return 1
}
chk_mounts_quiet() { # 不记账的挂载检查（等待阶段用）
  local QUIET_SAVE="$QUIET"; QUIET=1
  chk_mounts >/dev/null 2>&1
  local rc=$?
  QUIET="$QUIET_SAVE"
  return $rc
}

main() {
  [ "$CMD" = "check" ] || [ "$CMD" = "repair" ] || { echo "用法: $0 check|repair" >&2; exit 2; }
  need_root
  mkdir -p "$STATE_DIR"
  log "== stor-selfheal $CMD (CT$CTID) =="
  [ "$CMD" = "repair" ] && ensure_unit
  # 容器刚启动就先等它稳定（否则会把"启动中"当成故障）
  if [ "$CMD" = "repair" ] && ct_running; then
    local up0
    up0="$(ct_shm "cut -d' ' -f1 /proc/uptime" 2>/dev/null | tr -d ' \r' | cut -d. -f1)"
    if [ -n "${up0:-}" ] && [ "$up0" -lt 180 ]; then
      log "容器刚启动（uptime ${up0}s），等待其完成挂载…"
      wait_container_settle 300 || warn "容器在 300s 内未稳定（继续检查）"
    fi
  fi

  local rc_ct=0 rc_mp=0 rc_stack=0 rc_conf=0 rc_mask=0 rc_nodes=0 rc_mounts=0 rc_comp=0
  CHECK_NAME=ct;         chk_ct         || rc_ct=1
  CHECK_NAME=mountpoints; chk_mountpoints || rc_mp=1
  CHECK_NAME=stack;      chk_stack      || rc_stack=1
  CHECK_NAME=conf;       chk_conf       || rc_conf=1
  CHECK_NAME=mask;       chk_mask       || rc_mask=1
  CHECK_NAME=component;  chk_component  || rc_comp=1
  CHECK_NAME=nodes;      chk_nodes      || rc_nodes=1
  CHECK_NAME=mounts;     chk_mounts     || rc_mounts=1

  local bad_count=$((rc_ct+rc_mp+rc_stack+rc_conf+rc_mask+rc_nodes+rc_mounts+rc_comp))
  if [ "$bad_count" = 0 ]; then
    log "全部检查通过，无需修复"
    manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-check","ctid":%s,"result":"healthy"}' "$(date -Is)" "$CTID")"
    [ "$JSON_MODE" = 1 ] && emit_status_json 1 "$(ct_running && echo 1 || echo 0)"
    exit 0
  fi
  log "发现 $bad_count 项不健康"
  if [ "$CMD" = "check" ]; then
    manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-check","ctid":%s,"result":"unhealthy","items":%s}' "$(date -Is)" "$CTID" "$bad_count")"
    [ "$JSON_MODE" = 1 ] && emit_status_json 0 "$(ct_running && echo 1 || echo 0)"
    exit 1
  fi

  [ "$DRY" = 1 ] && { log "DRY-RUN：只诊断不修复"; exit 1; }

  # 修复顺序：**宿主挂载点最前** → 栈 → 配置/放行 → 掩码 → 节点 →（必要时）重启容器
  # 挂载点坏着时重启容器没有意义：PVE 启动前要先激活存储，激活不了就起不来
  # （2026-11-12 事故：重启把"运行中但卷有问题"放大成"完全起不来"）。
  # 修复顺序：**组件成员纠正 → 掩码 → 其它**
  # 顺序有讲究：掩码会清掉"后端存储（无盘身份）"的条目，而组件纠正会把 md 成员
  # 换到物化设备分区 —— 先清掩码再纠正成员，中间会出现"组件不可见"的 broken 态。
  # （2026-11-12 实测踩过：掩码先重建 → /vol2 一度 arrayState=broken）
  if [ "$rc_comp" = 1 ]; then
    if fix_component; then COMP_FIXED=1; fi
  fi
  [ "$rc_mp" = 1 ]     && fix_mountpoints
  [ "$rc_stack" = 1 ]  && fix_stack
  [ "$rc_conf" = 1 ]   && fix_conf
  [ "$rc_mask" = 1 ]   && fix_mask
  [ "$rc_nodes" = 1 ]  && fix_nodes
  # 容器停机 → 拉起（不是重启）；挂载/放行/掩码问题 → 重启才生效
  if [ "$rc_ct" = 1 ]; then
    if start_guard; then fix_start; STARTED=1; fi
  fi
  if { [ "$rc_mounts" = 1 ] || [ "$rc_conf" = 1 ] || [ "$rc_mask" = 1 ]; } && ct_running \
     && [ -z "${COMP_FIXED:-}" ]; then
    if restart_guard; then RESTARTED=1; fi
  fi

  if [ -n "${RESTARTED:-}" ] || [ -n "${STARTED:-}" ]; then
    log "等待容器起来并让 fnOS 完成挂载（最多 240s）…"
    local waited=0 okv=0
    while [ "$waited" -lt 240 ]; do
      sleep 15; waited=$((waited+15))
      QUIET=1
      if ct_running && chk_mounts >/dev/null 2>&1; then okv=1; QUIET=0; break; fi
      QUIET=0
    done
    if [ "$okv" = 1 ]; then
      log "容器已运行且卷已在 ${waited}s 内挂好"
    else
      # 动作没有达成目标就是失败：没有"超时但仍算通过"这条路径
      if ct_running; then
        warn "等待超时（${waited}s），卷仍未挂上"
      else
        warn "等待超时（${waited}s），容器仍未进入运行态"
      fi
    fi
  else
    sleep 20
  fi
  log "复核："
  # 复核前同样要等容器稳定（刚起容器时卷还没挂完 → 否则必然误报）
  if ct_running; then
    wait_container_settle 300 || warn "容器在 300s 内未稳定（继续复核）"
  fi
  local again=0
  chk_ct         || again=1
  chk_mountpoints || again=1
  chk_stack      || again=1
  chk_conf       || again=1
  chk_mask       || again=1
  chk_component  || again=1
  chk_nodes      || again=1
  chk_mounts     || again=1
  if [ "$again" = 0 ]; then
    log "自愈完成：全部检查通过"
    manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-repair","ctid":%s,"result":"repaired"}' "$(date -Is)" "$CTID")"
    [ "$JSON_MODE" = 1 ] && emit_status_json 1 "$(ct_running && echo 1 || echo 0)"
    exit 0
  fi
  log "自愈未完全成功（仍有不健康项），需人工介入"
  manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"selfheal-repair","ctid":%s,"result":"failed"}' "$(date -Is)" "$CTID")"
  [ "$JSON_MODE" = 1 ] && emit_status_json 0 "$(ct_running && echo 1 || echo 0)"
  exit 1
}

main "$@"
