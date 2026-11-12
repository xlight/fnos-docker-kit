#!/usr/bin/env bash
# ============================================================================
# stor-mountpoint.sh —— 宿主 PVE 存储挂载点自愈（按标签，不按盘符）
#
# 为什么要它（2026-11-12 事故，见 fnos/41-usb-reenum-mountpoint-selfheal-gap.md）：
#   承载 CT201 rootfs 与 PVE 存储目录的 USB 盘反复重枚举（sdd→sde→sdf），
#   **盘符变了但旧挂载还在** —— mountinfo 里 `/dev/sdX on <挂载点>` 依旧存在，
#   而 /dev/sde1 已经不存在了，读写全报 `Input/output error`。
#   这种"僵尸挂载"有两个害处：
#     ① PVE 激活存储时判定 "directory is expected to be a mount point but is not
#        mounted" → `pct start` 直接失败 → 容器连启动都做不到；
#     ② 光看 mountinfo 以为还挂着，实际数据不可达。
#
# 判定"挂载点健康"要同时满足三件事（缺一即不健康）：
#   ① 它确实是挂载点；
#   ② 挂载源与**按标签解析出的当前设备**是同一个（标签=身份，盘符=位置）；
#   ③ 挂载点**可实际读取**（列目录不报 EIO）—— 僵尸挂载只有这一步才暴露。
#
# 用法:
#   sudo bash stor-mountpoint.sh check        # 只检查（0=全健康 / 1=有不健康 / 2=用法错）
#   sudo bash stor-mountpoint.sh apply        # 检查 + 修复（摘僵尸挂载 + 按标签重挂）
#   sudo bash stor-mountpoint.sh status       # 机器可读状态（JSON）
#
# 环境变量:
#   MP_STATE_DIR   状态目录（默认 /var/lib/fnos-stor）
#   MP_LABELS      覆盖要管的 "标签:挂载点" 列表（默认从 /etc/fstab 的 LABEL= 行推导）
#   MP_JSON=1      stdout 输出 JSON
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CMD="${1:-check}"
JSON_MODE="${MP_JSON:-0}"
[ "$CMD" = "status" ] && JSON_MODE=1
STATE_DIR="${MP_STATE_DIR:-/var/lib/fnos-stor}"
STATUS_FILE="$STATE_DIR/mountpoint-status.json"

need_root

# ---------- 挂载点清单 ----------
# 默认从 /etc/fstab 推导：LABEL=<标签> <挂载点> ... —— 这正是 systemd 自己用的身份映射。
# 也允许 MP_LABELS="标签:挂载点,标签:挂载点" 覆盖。
mp_pairs() {
  if [ -n "${MP_LABELS:-}" ]; then
    printf '%s\n' "$MP_LABELS" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$'
    return
  fi
  awk '$1 ~ /^LABEL=/ {
      lab = substr($1, 6); mp = $2; sub(/\/+$/, "", mp)
      if (lab != "" && mp != "") print lab ":" mp
    }
    $1 ~ /^\/dev\/disk\/by-label\// {
      lab = $1; sub(/^.*by-label\//, "", lab); mp = $2; sub(/\/+$/, "", mp)
      if (lab != "" && mp != "") print lab ":" mp
    }' /etc/fstab 2>/dev/null
}

# by-label 当前解析出的设备（身份 → 当前位置）
mp_expect_dev() { readlink -f "/dev/disk/by-label/$1" 2>/dev/null; }

# 挂载点当前挂载源（**精确匹配挂载点**；--target 会返回"包含它的父挂载"，未挂载时会误报）
mp_actual_src() { findmnt -n -o SOURCE -M "$1" 2>/dev/null | head -1; }

# 挂载源是否已是"无背书的残留设备"（loop 已 detach / 盘已拔走）
# 判据：设备节点还在，但系统里已查不到它与任何文件的关联
#   · loop 设备：losetup -a 里查不到 → 已 detach（挂载还开着时 sysfs 的 backing_file 仍显示旧值，不能作准）
#   · 其它设备：设备节点已消失 → 盘被拔走/重枚举
mp_source_is_stale() { # $1=source
  local src="$1" base
  [ -e "$src" ] || return 0
  base="$(basename "$src" 2>/dev/null)"
  case "$base" in
    loop*)
      losetup -a 2>/dev/null | grep -q "/dev/${base}:" && return 1
      return 0;;
    *) return 1;;
  esac
}

# 同一设备判定：优先比 major:minor（设备名会变，号不会随重枚举保留 → 名字不同即判不同）
mp_same_dev() { # $1=devA $2=devB
  local a b
  a="$(readlink -f "$1" 2>/dev/null)"; b="$(readlink -f "$2" 2>/dev/null)"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  local am bm
  am="$(lsblk -ndo MAJ:MIN "$a" 2>/dev/null | head -1)"
  bm="$(lsblk -ndo MAJ:MIN "$b" 2>/dev/null | head -1)"
  [ -n "$am" ] && [ "$am" = "$bm" ] && return 0
  return 1
}

# 挂载点是否可读（僵尸挂载在这里报 EIO）
mp_readable() { ls "$1" >/dev/null 2>&1; }

# ---------- 逐点判定 ----------
# 输出：label<TAB>mountpoint<TAB>expected<TAB>actual<TAB>state<TAB>reason
#   state ∈ ok | missing | zombie | mismatched | unreadable
mp_probe_one() { # $1=label $2=mountpoint
  local label="$1" mp="$2" exp act state reason
  exp="$(mp_expect_dev "$label")"
  if [ -z "$exp" ] || [ ! -e "$exp" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mp" "${exp:-<未解析>}" "-" "missing" "按标签找不到设备（盘未接入或标签未读到）"
    return 1
  fi
  act="$(mp_actual_src "$mp")"
  if [ -z "$act" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mp" "$exp" "-" "missing" "挂载点未挂载"
    return 1
  fi
  if ! mp_same_dev "$act" "$exp"; then
    # 源指向已消失设备 = 僵尸挂载；源存在但不是按标签那块 = 挂错盘
    if [ ! -e "$act" ] || mp_source_is_stale "$act"; then
      state="zombie"; reason="僵尸挂载：源 $act 已失效（盘符漂移/设备重枚举），读不到数据"
    else
      state="mismatched"; reason="挂载源与按标签解析的设备不一致（挂错盘？）"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mp" "$exp" "$act" "$state" "$reason"
    return 1
  fi
  if ! mp_readable "$mp"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mp" "$exp" "$act" "unreadable" "挂载点不可读（I/O 错误）"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$mp" "$exp" "$act" "ok" "挂载健康"
  return 0
}

mp_probe_all() {
  local rc=0 pair label mp
  while IFS= read -r pair; do
    label="${pair%%:*}"; mp="${pair#*:}"
    [ -n "$label" ] && [ -n "$mp" ] || continue
    mp_probe_one "$label" "$mp" || rc=1
  done <<EOF
$(mp_pairs)
EOF
  return $rc
}

mp_status_json() { # stdin = mp_probe_all 的 TSV
  python3 - "$STATUS_FILE" <<'PY'
import datetime, json, os, sys
path = sys.argv[1]
items = []
for line in sys.stdin.read().splitlines():
    p = line.split("\t")
    if len(p) < 6:
        continue
    items.append({"label": p[0], "mountpoint": p[1], "expected_source": p[2],
                  "actual_source": p[3], "state": p[4], "reason": p[5],
                  "healthy": p[4] == "ok"})
doc = {"checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "healthy": all(i["healthy"] for i in items) if items else True,
       "mountpoints": items}
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
except OSError:
    pass
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
}

# ---------- 修复 ----------
# 摘掉僵尸挂载：设备已消失时普通 umount 必失败 → 用 lazy（唯一可行路径；设备已不在，无数据风险）
mp_unmount_stale() { # $1=mountpoint
  local mp="$1" n=0
  while [ -n "$(mp_actual_src "$mp")" ]; do
    umount -l "$mp" >/dev/null 2>&1 || break
    n=$((n+1))
    [ "$n" -ge 8 ] && break
  done
  return 0
}

# 按标签重挂：优先让 systemd 按 fstab 挂（它自己认 LABEL=），再退到直接按标签挂
mp_mount_by_label() { # $1=label $2=mountpoint
  local label="$1" mp="$2" i=0
  # 等设备出现（重枚举后 by-label 要等 udev 刷新）
  while [ "$i" -lt 15 ]; do
    [ -e "/dev/disk/by-label/$label" ] && break
    sleep 2; i=$((i+2))
  done
  [ -e "/dev/disk/by-label/$label" ] || return 1
  mount "$mp" >/dev/null 2>&1 && return 0
  mount -o nouuid "/dev/disk/by-label/$label" "$mp" >/dev/null 2>&1 && return 0
  mount "/dev/disk/by-label/$label" "$mp" >/dev/null 2>&1 && return 0
  return 1
}

mp_apply_one() { # $1=label $2=mountpoint
  local label="$1" mp="$2" before after
  before="$(mp_actual_src "$mp")"
  log "修复：摘除 $mp 上的失效挂载（当前源：${before:-<无>}）"
  mp_unmount_stale "$mp"
  if mp_mount_by_label "$label" "$mp"; then
    after="$(mp_actual_src "$mp")"
    if mp_readable "$mp"; then
      log "已恢复：$mp ← $after（标签 $label）"
      manifest_add "$(printf '{"ts":"%s","mech":"host-mountpoint","action":"remount","label":"%s","mountpoint":"%s","before":"%s","after":"%s","result":"ok"}' \
        "$(date -Is)" "$label" "$mp" "${before:-none}" "${after:-none}")"
      return 0
    fi
    log "修复失败：$mp 挂上了但仍不可读"
    manifest_add "$(printf '{"ts":"%s","mech":"host-mountpoint","action":"remount","label":"%s","mountpoint":"%s","result":"unreadable"}' \
      "$(date -Is)" "$label" "$mp")"
    return 1
  fi
  log "修复失败：$mp 无法按标签 $label 挂载"
  manifest_add "$(printf '{"ts":"%s","mech":"host-mountpoint","action":"remount","label":"%s","mountpoint":"%s","result":"failed"}' \
    "$(date -Is)" "$label" "$mp")"
  return 1
}

main() {
  case "$CMD" in
    check|apply|status|selftest) ;;
    *) printf '用法: %s check|apply|status|selftest\n' "$0" >&2; exit 2;;
  esac

  # selftest：内部判据的单元断言（不依赖真实存储状态）
  if [ "$CMD" = "selftest" ]; then
    local rc=0
    if mp_source_is_stale /dev/definitely-not-here-xyz; then echo "PASS: 不存在的设备判为失效"; else echo "FAIL: 不存在的设备未判失效"; rc=1; fi
    local realdev; realdev="$(findmnt -n -o SOURCE -M /mnt 2>/dev/null | head -1)"
    if [ -n "$realdev" ] && ! mp_source_is_stale "$realdev"; then echo "PASS: 真实在用设备判为有效"; else echo "FAIL: 真实在用设备被误判为失效"; rc=1; fi
    if mp_same_dev /dev/null /dev/null; then echo "FAIL: 同一性判定把不同设备判为相同"; rc=1; else echo "PASS: 同一性判定区分不同设备"; fi
    exit $rc
  fi

  local probe rc=0
  probe="$(mp_probe_all)" || rc=1

  if [ "$CMD" = "status" ]; then
    printf '%s\n' "$probe" | mp_status_json
    exit $rc
  fi

  if [ "$JSON_MODE" = 1 ]; then
    printf '%s\n' "$probe" | mp_status_json >/dev/null
  fi

  printf '%s\n' "$probe" | awk -F'\t' 'NF>=6 { if ($5=="ok") printf "  OK    %s (%s) ← %s\n", $2, $1, $4; else printf "  FAIL  %s (%s): %s\n", $2, $1, $6 }'

  if [ "$CMD" = "check" ]; then
    [ "$rc" = 0 ] && log "挂载点全部健康" || log "存在失效挂载点"
    exit $rc
  fi

  # apply：只修不健康的点；健康挂载绝不触碰
  local fixed=0 label mp state
  while IFS=$'\t' read -r label mp _ _ state _; do
    [ "$state" = "ok" ] && continue
    mp_apply_one "$label" "$mp" && fixed=$((fixed+1))
  done <<EOF
$probe
EOF

  # 复核
  local probe2 rc2=0
  probe2="$(mp_probe_all)" || rc2=1
  printf '%s\n' "$probe2" | awk -F'\t' 'NF>=6 { if ($5=="ok") printf "  OK    %s (%s) ← %s\n", $2, $1, $4; else printf "  FAIL  %s (%s): %s\n", $2, $1, $6 }'
  [ "$JSON_MODE" = 1 ] && printf '%s\n' "$probe2" | mp_status_json >/dev/null
  [ "$rc2" = 0 ] && { log "挂载点已全部恢复"; exit 0; }
  log "仍有失效挂载点，需人工介入"
  exit 1
}

main "$@"
