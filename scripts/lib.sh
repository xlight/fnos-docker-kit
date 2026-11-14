#!/usr/bin/env bash
# lib.sh —— fnos-container-net-enumeration 的公共库
# 用法: source "$(dirname "$0")/lib.sh"   或   bash lib.sh help
#
# 约定：
#   - 所有机制脚本统一提供 apply|rollback|status 三个子命令，幂等
#   - 每次变更必须 manifest_add 一条 JSON（审计 + 供 rollback.sh 逆序全撤）
#   - 备份落在宿主 $HOST_BACKUP_ROOT/<ts>/，容器侧文件同时 pct pull 一份到宿主
#   - 退出码家规（fnos-ops-tui D2）：0 成功 / 1 通用失败 / 2 用法错误或前置缺失
#     （含显式拒绝，如缺确认的 destroy）；130 按惯例保留给 Ctrl-C 中断。
#     调用者据此区分"展示用法"与"展示错误"，绝不把 2 当失败重试。
set -uo pipefail

# ---------- 可覆盖的环境默认值 ----------
CTID="${CTID:-200}"
CT_IP="${CT_IP:-192.168.199.148}"
VM_IP="${VM_IP:-192.168.199.158}"
VMID_CONTROL="${VMID_CONTROL:-104}"
VMID_OTHER="${VMID_OTHER:-101}"
FNOS_USER="${FNOS_USER:-}"
FNOS_PORT="${FNOS_PORT:-5666}"
# 凭据只从环境变量读取（公开仓脱敏：无默认账号/口令）。
# 本地使用前先 export 相应变量，缺失时 need_creds 会显式报错。
# 固定"登录设备号"：每次探测都用随机 did 会在 longtoken 表里不断累积设备会话
# （设备列表变脏，可能触发设备数上限）；复用同一个 did 可避免。
# 注意：user.login 返回 errno 131072 是**密码错误**（前端对应 shared.passwordError），
# 不是限流；CT201 与 CT200 的密码不同，见 README §9。
FNOS_DID="${FNOS_DID:-c0ffee00-0000-4000-8000-000000000001}"
# sudo 下 $HOME 会变成 /root；用 SUDO_USER 的家目录作为默认落点
_caller="${SUDO_USER:-${USER:-root}}"
_caller_home="$(getent passwd "$_caller" 2>/dev/null | cut -d: -f6)"; [ -n "$_caller_home" ] || _caller_home="$HOME"
HOST_BACKUP_ROOT="${HOST_BACKUP_ROOT:-$_caller_home/fnos/backups}"
# systemd 单元里跑时没有 SUDO_USER（USER=root）→ 审计会落进 /root/fnos/backups，
# 与人工操作的审计**分叉**（rollback 只读项目内那份 → 定时动作漏撤）。
# 单元化机制（自愈/存活巡检/USB timer）一律写项目内这份。
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
if [ -z "${SUDO_USER:-}" ] && [ "$(id -u)" = 0 ] && [ -d "$_repo_root/backups" ]; then
  HOST_BACKUP_ROOT="$_repo_root/backups"
fi
CT_BACKUP_ROOT="${CT_BACKUP_ROOT:-/root/fnos-net-backup}"
MANIFEST="${MANIFEST:-$HOST_BACKUP_ROOT/manifest.jsonl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC="$SCRIPT_DIR/fnos_rpc.py"

# 前端枚举 Gy: Normal=0, Bond=1（见 assets/Setting-*.js）
# 故任务里的 {type:Normal}/{type:Bond} 等价于 {type:0}/{type:1}；三种线上载荷即覆盖四种命名。
DEFAULT_PROBES='[{"req":"appcgi.network.net.list","params":{}},
                  {"req":"appcgi.network.net.list","params":{"type":0}},
                  {"req":"appcgi.network.net.list","params":{"type":1}}]'

# ---------- 日志 ----------
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] FATAL: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }
ts()   { date '+%Y%m%d-%H%M%S'; }

# ---------- 前置检查 ----------
need_root() { [ "$(id -u)" = 0 ] || die "需要 root（宿主上请 sudo 运行）"; }
need_py()   { command -v python3 >/dev/null || die "缺少 python3"; }
need_rpc()  { [ -f "$RPC" ] || die "缺少 RPC 探针客户端: $RPC"; }
need_ct() {
  pct status "$CTID" 2>/dev/null | grep -q 'status: running' \
    || die "CT $CTID 未运行（pct status $CTID）"
}
ct()  { pct exec "$CTID" -- "$@"; }

# ---------- 退出码家规（fnos-ops-tui D2：0 成功 / 1 通用失败 / 2 用法错误或前置缺失；
# 130 按惯例保留给 Ctrl-C 中断。调用者据此区分"展示用法"与"展示错误"，绝不把 2 当失败重试） ----------

# ---------- 机器输出信封（fnos-ops-tui D2：stdout 单个对象 + 诊断走 stderr） ----------
# 约定：--json 输出 = stdout 有且仅有一个 JSON 对象
#   {schemaVersion:1, ok, data?, error:{code,message}?}，人类 prose 与诊断一律走
#   stderr，无颜色码；退出码语义不变（0/1/2 见上）。schemaVersion 只在破坏性变更
#   时 bump；消费者先断言版本再解析。
json_ok() {  # $1 = data JSON（调用者拼好的对象/数组；缺省 null）
  printf '{"schemaVersion":1,"ok":true,"data":%s}\n' "${1:-null}"
}
json_err() {  # $1 = code（稳定机器码） $2 = message（人类可读）
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({"schemaVersion": 1, "ok": False,
                  "error": {"code": sys.argv[1], "message": sys.argv[2]}}))
PY
  else
    printf '{"schemaVersion":1,"ok":false,"error":{"code":"error","message":"%s"}}\n' \
      "$(printf '%s' "$2" | tr -d '\"\\')"
  fi
}

# ---------- 备份与 manifest ----------
host_backup_dir() { d="$HOST_BACKUP_ROOT/$(ts)"; mkdir -p "$d"; printf '%s\n' "$d"; }
ct_backup_dir()   { d="$CT_BACKUP_ROOT/$(ts)"; ct mkdir -p "$d" >/dev/null; printf '%s\n' "$d"; }
manifest_add() {  # $1 = JSON 对象字符串（必须合法 JSON，否则拒绝写入；flock 串行多写者）
  mkdir -p "$(dirname "$MANIFEST")"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
      || { printf 'manifest_add 拒绝：非合法 JSON（未写入）: %.160s\n' "$1" >&2; return 1; }
  fi
  (
    if command -v flock >/dev/null 2>&1; then
      exec 9>"$MANIFEST.lock"; flock -x 9
    fi
    printf '%s\n' "$1" >> "$MANIFEST"
  )
}

# ---------- 破坏性动作互斥锁 ----------
# 为什么需要：存活巡检（stor-guard）与自愈修复（stor-selfheal）都可能动容器 ——
# 自愈正在"停容器 → 重装配 md → 起容器"时，存活巡检若同时把容器拉起来，
# 会打断修复（卷仍被占用 → 重装配失败），甚至把半装配状态暴露给 fnOS。
# 约定：任何会停/起容器的动作都必须持锁；拿不到锁就**跳过**（不排队、不硬闯）。
ACTION_LOCK_FD=""
action_lock_acquire() { # $1=ctid  $2=等待秒（0=不等）
  local ctid="$1" wait="${2:-0}" dir="/var/lib/fnos-stor/selfheal"
  mkdir -p "$dir" 2>/dev/null || return 1
  command -v flock >/dev/null 2>&1 || { ACTION_LOCK_FD=""; return 0; }   # 无 flock 则不拦
  exec 8>"$dir/ct${ctid}.lock" 2>/dev/null || return 1
  if flock -w "$wait" 8; then ACTION_LOCK_FD=8; return 0; fi
  exec 8>&- 2>/dev/null
  return 1
}
action_lock_release() {
  [ -n "$ACTION_LOCK_FD" ] || return 0
  flock -u 8 2>/dev/null
  exec 8>&- 2>/dev/null
  ACTION_LOCK_FD=""
}

# ---------- 容器静态节点 unit（共享：stor-manage / stor-usb 链等调用） ----------
# 背景（见 fnos/07 §13.1）：文件 bind 会被容器内 fnOS 的 umount 摘掉（写入落 stub），
# 设备节点统一改由开机 unit 静态 mknod（Before=trim_init，fnOS 动手前节点就绪）。
ct_running() { pct status "${1:-$CTID}" 2>/dev/null | grep -q 'status: running'; }
ct_md5() { pct exec "$1" -- md5sum "$2" 2>/dev/null | awk '{print $1}'; }

ct_node_helper_render() { # $1=helper 路径（进 top 注释）；stdout=通用节点 helper 正文
  local hn; hn="$(basename "${1:-fnos-node-unit.sh}")"
  sed "s|__HN__|$hn|g" <<'HELPER'
#!/bin/sh
# __HN__ —— fnOS LXC 节点 helper（运行时按**当前**设备身份建节点）
#
# 为什么不再用"把 md/dm 号写死"的旧做法：
#   宿主每次重启都会重建 md/LV/nvme 链路，**设备号会漂移**（md126→md127、
#   dm-3→dm-4 …）。旧 helper 把 10 月那次的号写进 unit，宿主一重启就过期，
#   容器里缺 /dev/dm-N → fnOS 挂 /volN 失败（CT201 2026-11-10 就是这么坏的：
#   /vol2 每 6 秒重试一次挂不上，宿主侧 md/LV 全都好好的）。
#
# 现在：每次容器开机都按 **/sys/block 的当前视图**重建节点。
#   * 容器里的 /sys/block 是宿主 /sys/block 的**掩码视图**（stor-mask.sh 决定
#     哪些设备对本 CT 可见）→ 视图里有什么就建什么节点，天然只暴露本栈设备。
#   * 号段每次现取（/sys/block/<dev>/dev）→ 号漂移免疫。
#   * 分区节点也从视图里现取。
#
# 用法: __HN__ [--usb-serial <SERIAL> --usb-canon <NAME>] [--wait <SEC>]
#   --usb-serial/--usb-canon：把某块 USB 盘在容器内**固定**成 /dev/<canon>
#     （宿主盘符会漂移，容器内名字按设计 pin 死）；找不到就跳过。
#   --wait：设备还没出现时轮询等待（默认 30s，每 2s 一轮）。
#
# 号段从 sysfs/procfs 现取；缺项跳过；**exit 0 从不挡开机**。
WAIT=30
USB_SERIAL=""
USB_CANON=""
CHAR_DEV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --usb-serial) USB_SERIAL="${2:-}"; shift 2;;
    --usb-canon)  USB_CANON="${2:-}"; shift 2;;
    --wait)       WAIT="${2:-30}"; shift 2;;
    c:*)          CHAR_DEV="${CHAR_DEV} ${1#c:}"; shift;;   # 字符设备（zfs 等）
    *)            shift;;                                   # 纯设备名：由扫描覆盖，忽略
  esac
done

mknode() { # <path> <maj> <min>
  [ -e "$1" ] && return 0
  rm -f "$1" 2>/dev/null
  /bin/mknod "$1" b "$2" "$3" 2>/dev/null || return 1
  /bin/chown root:disk "$1" 2>/dev/null
  /bin/chmod 660 "$1" 2>/dev/null
  return 0
}

# 把视图里的每个块设备（含分区）按当前号段建节点
scan_nodes() {
  local d p name mm pm
  for d in /sys/block/*; do
    [ -d "$d" ] || continue
    name="${d##*/}"
    mm="$(cat "$d/dev" 2>/dev/null)" || continue
    [ -n "$mm" ] || continue
    mknode "/dev/$name" "${mm%%:*}" "${mm##*:}"
    # 分区（/sys/block/<disk>/<disk><part>）
    for p in "$d"/*; do
      [ -e "$p" ] || continue
      pm="$(cat "$p/dev" 2>/dev/null)" || continue
      [ -n "$pm" ] || continue
      mknode "/dev/${p##*/}" "${pm%%:*}" "${pm##*:}"
    done
  done
}

# USB 规范名：按 serial 找整盘 → 建 /dev/<canon>（容器内名字 pin 死）
usb_canon_node() {
  [ -n "$USB_SERIAL" ] && [ -n "$USB_CANON" ] || return 0
  local d name mm ser
  for d in /sys/block/*; do
    [ -d "$d" ] || continue
    ser="$(cat "$d/device/serial" 2>/dev/null)" || continue
    [ "$ser" = "$USB_SERIAL" ] || continue
    name="${d##*/}"
    mm="$(cat "$d/dev" 2>/dev/null)" || continue
    rm -f "/dev/$USB_CANON" 2>/dev/null
    mknode "/dev/$USB_CANON" "${mm%%:*}" "${mm##*:}"
    echo "[node] USB canonical: /dev/$USB_CANON <- $name ($mm)"
    return 0
  done
  return 0
}

# 等设备出现：视图里至少有一个 dm-* 且 /dev 下有对应节点
wait_ready() {
  local i=0 d
  while [ "$i" -lt "$WAIT" ]; do
    for d in /sys/block/dm-*; do
      [ -d "$d" ] || continue
      mm="$(cat "$d/dev" 2>/dev/null)" || continue
      if [ -e "/dev/${d##*/}" ]; then return 0; fi
    done
    sleep 2; i=$((i+2))
  done
  return 0
}

# 字符设备（c:<name>，号段从 /proc/misc 现取）
char_nodes() {
  local n set major minor
  for n in $CHAR_DEV; do
    set=$(awk -v n="$n" '$2==n{print $1" "$3; exit}' /proc/misc 2>/dev/null)
    [ -n "$set" ] || continue
    major="$(echo "$set" | awk '{print $1}')"; minor="$(echo "$set" | awk '{print $2}')"
    [ -e "/dev/$n" ] && continue
    /bin/mknod "/dev/$n" c "$major" "$minor" 2>/dev/null && /bin/chmod 666 "/dev/$n" 2>/dev/null
  done
}

scan_nodes
char_nodes
usb_canon_node
wait_ready
scan_nodes
char_nodes
usb_canon_node
exit 0
HELPER
}

ct_node_unit_render() { # <unit-name> <helper-path> <description> <exec-args...>；stdout=unit 正文
  local desc=$3 hp=$2; shift 3
  printf '[Unit]\nDescription=%s\nAfter=local-fs.target\nBefore=trim_init.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=%s' "$desc" "$hp"
  local a; for a in "$@"; do [ -n "$a" ] && printf ' %s' "$a"; done
  printf '\n\n[Install]\nWantedBy=multi-user.target\n'
}

ct_node_unit_ensure() { # <ctid> <unit-name> <helper-path> <description> <exec-args...>
  local ctid=$1 un=$2 hp=$3 desc=$4; shift 4
  local td; td="$(mktemp -d)"
  local hf="$td/helper" uf="$td/unit"
  ct_node_helper_render "$hp" > "$hf"
  ct_node_unit_render "$un" "$hp" "$desc" "$@" > "$uf"
  if ! ct_running "$ctid"; then
    rm -rf "$td"
    log "  = 容器未运行：节点 unit 落装跳过（容器运行时重放落装）"
    return 0
  fi
  if [ "$(ct_md5 "$ctid" "/etc/systemd/system/$un")" = "$(md5sum < "$uf" | awk '{print $1}')" ] \
     && [ "$(ct_md5 "$ctid" "$hp")" = "$(md5sum < "$hf" | awk '{print $1}')" ]; then
    rm -rf "$td"; log "  = node unit 已是最新: $un"; return 0
  fi
  pct push "$ctid" "$uf" "/etc/systemd/system/$un" || { rm -rf "$td"; die "push unit 失败: $un"; }
  pct push "$ctid" "$hf" "$hp" || { rm -rf "$td"; die "push helper 失败: $hp"; }
  rm -rf "$td"
  pct exec "$ctid" -- chmod +x "$hp" 2>/dev/null || warn "chmod 失败: $hp"
  pct exec "$ctid" -- systemctl daemon-reload 2>/dev/null || warn "daemon-reload 失败"
  pct exec "$ctid" -- systemctl enable "$un" >/dev/null 2>&1 || warn "enable 失败: $un"
  log "  + node unit $un + helper $(basename "$hp")"
}

ct_node_unit_remove() { # <ctid> <unit-name> <helper-path>
  local ctid=$1 un=$2 hp=$3
  if ct_running "$ctid"; then
    pct exec "$ctid" -- systemctl disable "$un" >/dev/null 2>&1 || true
    pct exec "$ctid" -- rm -f "/etc/systemd/system/$un" "$hp" && log "  - node unit $un + helper"
    pct exec "$ctid" -- systemctl daemon-reload 2>/dev/null || true
  else
    log "容器未运行：unit 留待手动删 /etc/systemd/system/$un"
  fi
}

# ---------- RPC 探针 ----------
need_creds() {  # RPC 调用前检查凭据（无默认口令；缺失即显式报错）
  local _u=FNOS_USER _p=FNOS_PASS
  [ -n "${!_u:-}" ] || die "缺少 FNOS_USER 环境变量"
  [ -n "${!_p:-}" ] || die "缺少 FNOS_PASS 环境变量"
}
# netlist_probe <host> [port]  -> 打印 RESULT 行
netlist_probe() {
  local host="$1" port="${2:-$FNOS_PORT}"
  need_creds
  export FNOS_HOST="$host" FNOS_PORT="$port" FNOS_USER FNOS_PASS FNOS_DID
  export FNOS_PROBES="$DEFAULT_PROBES"
  python3 "$RPC" 2>/dev/null | grep '^RESULT '
}
# netlist_ok <host> [port] -> 0 表示至少一个探针返回非空 data.net.ifs
netlist_ok() {
  netlist_probe "$1" "$2" | python3 -c '
import sys, json
ok = False
for line in sys.stdin:
    if not line.startswith("RESULT "): continue
    try: r = json.loads(line[7:])
    except Exception: continue
    ifs = (((r.get("resp") or {}).get("data") or {}).get("net") or {}).get("ifs") or []
    if ifs: ok = True
print("OK" if ok else "NODATA")
' | grep -q '^OK$'
}
# netlist_summary -> 人类可读的接口清单（含名称与 IPv4）
netlist_summary() {
  netlist_probe "$1" "$2" | python3 -c '
import sys, json
seen = {}
for line in sys.stdin:
    if not line.startswith("RESULT "): continue
    try: r = json.loads(line[7:])
    except Exception: continue
    ifs = (((r.get("resp") or {}).get("data") or {}).get("net") or {}).get("ifs") or []
    for i in ifs:
        seen[i.get("name")] = i.get("ipv4Addr") or (i.get("ipv4") or [""])[0] if isinstance(i.get("ipv4"), list) else i.get("ipv4Addr")
for n, a in sorted(seen.items()):
    print("  iface=%s ipv4=%s" % (n, a or "-"))
if not seen: print("  (no interface)")
'
}

# ---------- 机制映射（私有 net-* 专属；文件存在时载入，公开树无此文件）----------
# shellcheck source=mech-map.sh
[ -f "$SCRIPT_DIR/mech-map.sh" ] && source "$SCRIPT_DIR/mech-map.sh"

# ---------- 自检 ----------
lib_help() {
  cat <<'EOF'
lib.sh —— 供机制脚本 source 的公共库（不直接执行）：
  source lib.sh                       载入全部函数
  bash lib.sh help                    显示本帮助
  bash lib.sh selftest                前置检查（root / python3 / RPC / CT 运行）

可用函数：
  log/warn/die/ts                    日志、时间戳
  need_root/need_py/need_rpc/need_ct 前置检查
  ct <cmd...>                        在容器内执行
  host_backup_dir / ct_backup_dir    创建并回显备份目录
  manifest_add '<json>'              追加一条审计记录（供 rollback.sh 逆序全撤）
  ct_node_unit_ensure <ctid> <unit> <helper> <desc> [args…]   容器静态节点 unit（mknod；幂等）
  ct_node_unit_render <unit> <helper> <desc> [args…]          unit 正文渲染（cmp/测试用）
  ct_node_unit_remove <ctid> <unit> <helper>                  移除节点 unit + helper
  netlist_probe <host> [port]        打印 RESULT 行（三种载荷覆盖 {} / Normal / Bond）
  netlist_ok <host> [port]           0=有接口数据（PASS）
  netlist_summary <host> [port]      打印接口名与 IPv4
环境变量（可覆盖）：CTID CT_IP VM_IP VMID_CONTROL VMID_OTHER FNOS_USER FNOS_PASS
                    FNOS_PORT HOST_BACKUP_ROOT CT_BACKUP_ROOT MANIFEST
EOF
}

lib_selftest() {
  log "CTID=$CTID CT_IP=$CT_IP VM_IP=$VM_IP"
  need_root; log "root OK"
  need_py;   log "python3 OK"
  need_rpc;  log "RPC client OK ($RPC)"
  need_ct;   log "CT $CTID running OK"
  log "manifest: $MANIFEST"
  log "selftest passed"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-help}" in
    help|--help|-h) lib_help ;;
    selftest)       lib_selftest ;;
    *) lib_help; exit 2 ;;
  esac
fi
