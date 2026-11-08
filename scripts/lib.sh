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

# ---------- 容器静态节点 unit（共享：stor-manage / stor-usb 链等调用） ----------
# 背景（见 fnos/07 §13.1）：文件 bind 会被容器内 fnOS 的 umount 摘掉（写入落 stub），
# 设备节点统一改由开机 unit 静态 mknod（Before=trim_init，fnOS 动手前节点就绪）。
ct_running() { pct status "${1:-$CTID}" 2>/dev/null | grep -q 'status: running'; }
ct_md5() { pct exec "$1" -- md5sum "$2" 2>/dev/null | awk '{print $1}'; }

ct_node_helper_render() { # $1=helper 路径（进 top 注释）；stdout=通用节点 helper 正文
  local hn; hn="$(basename "${1:-fnos-node-unit.sh}")"
  sed "s|__HN__|$hn|g" <<'HELPER'
#!/bin/sh
# __HN__ —— fnOS LXC 静态节点 helper（由 lib.sh:ct_node_unit_ensure 生成）
# 用法: __HN__ <canon> [node...]；canon=整盘名（自动补全其分区）
#   node：块设备名（默认形状）或 c:<name>（字符设备，经 /proc/misc 查次号）
# 号段每次从 sysfs/procfs 现取；缺项跳过；exit 0 从不挡开机
C="${1:?canon}"; shift; M=/sys/block/$C
mknode() { rm -f "$1"; /bin/mknod "$1" "$2" "$3" "$4"; /bin/chown root:disk "$1"; /bin/chmod 660 "$1"; }
resolve_blk() {
  local n=$1 mm p
  mm="$(cat /sys/block/$n/dev 2>/dev/null)" && { echo "$mm"; return 0; }
  for p in /sys/block/*/$n/dev; do
    [ -f "$p" ] || continue
    mm="$(cat $p 2>/dev/null)" && { echo "$mm"; return 0; }
  done
  return 1
}
resolve_char() { awk -v n="$1" '$2==n{print "c 10 "$1; exit}' /proc/misc; }
mm="$(cat $M/dev 2>/dev/null)" && mknode /dev/$C b ${mm%%:*} ${mm##*:}
for p in $M/${C}[0-9]* $M/${C}p[0-9]*; do
  [ -e "$p" ] || continue
  pm="$(cat $p/dev 2>/dev/null)" || continue
  mknode /dev/${p##*/} b ${pm%%:*} ${pm##*:}
done
for e in "$@"; do
  case "$e" in
    c:*) n="${e#c:}"; set -- $(resolve_char "$n"); [ -n "${1:-}" ] || continue; mknode /dev/$n "$1" "$2" "$3" ;;
    *)   n="${e#b:}"; mm="$(resolve_blk "$n")" || continue; mknode /dev/$n b ${mm%%:*} ${mm##*:} ;;
  esac
done
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
