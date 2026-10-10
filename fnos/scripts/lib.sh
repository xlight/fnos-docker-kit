#!/usr/bin/env bash
# lib.sh —— fnos-container-net-enumeration 的公共库
# 用法: source "$(dirname "$0")/lib.sh"   或   bash lib.sh help
#
# 约定：
#   - 所有机制脚本统一提供 apply|rollback|status 三个子命令，幂等
#   - 每次变更必须 manifest_add 一条 JSON（审计 + 供 rollback.sh 逆序全撤）
#   - 备份落在宿主 $HOST_BACKUP_ROOT/<ts>/，容器侧文件同时 pct pull 一份到宿主
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
# 固定"登录设备号"：fnOS 对每个用户的活跃登录会话有限额，若每次探测都用随机 did，
# 会话会不断累积并最终导致 user.login 返回 errno 131072（登录被拒）。复用同一个 did 可避免。
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

# ---------- 备份与 manifest ----------
host_backup_dir() { d="$HOST_BACKUP_ROOT/$(ts)"; mkdir -p "$d"; printf '%s\n' "$d"; }
ct_backup_dir()   { d="$CT_BACKUP_ROOT/$(ts)"; ct mkdir -p "$d" >/dev/null; printf '%s\n' "$d"; }
manifest_add() {  # $1 = JSON 对象字符串
  mkdir -p "$(dirname "$MANIFEST")"
  printf '%s\n' "$1" >> "$MANIFEST"
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
