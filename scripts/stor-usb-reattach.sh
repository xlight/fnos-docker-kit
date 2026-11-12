#!/usr/bin/env bash
# ============================================================================
# stor-usb-reattach.sh —— USB 直通盘"重枚举"的即时恢复与可见性
#
# 为什么要它（2026-11-12 事故，详见 fnos/42-usb-drop-rootcause-and-reattach.md）：
#   承载 CT201 rootfs 与 PVE 存储目录的 USB 盘在 **USB 2.0（480Mb/s）** 链路上静默掉线：
#     12:20:49 usb 4-1: USB disconnect, device number 3   ← 无任何前置报错
#     12:20:50 重新枚举（设备号 4）→ 盘从 sde 变成 sdf
#     12:20:55 EXT4-fs (loop0): Remounting filesystem read-only  ← CT201 根挂载 emergency_ro
#   宿主存储目录的挂载源还指着已不存在的旧设备名（僵尸挂载）→ PVE 激活不了存储
#   → 容器起不来 → NAS 停机。软件阻止不了硬件掉线，但可以让它**秒级恢复**且**看得见**。
#
# 身份与位置的分工（关键）：
#   · **序列号** = 身份（掉线重枚举后不变）→ 触发与识别都按序列号；
#   · **/dev/sdX** = 位置（每次都会变）→ 只用来判断"发生过重枚举"。
#
# 用法:
#   sudo env CTID=201 bash stor-usb-reattach.sh check   # 只检查 + 链路体检
#   sudo env CTID=201 bash stor-usb-reattach.sh apply   # 检查 + 事件记录 + 恢复（重挂→拉起）
#   sudo env CTID=201 bash stor-usb-reattach.sh status  # 机器可读状态（JSON）
#
# 环境变量:
#   CTID              目标容器（必填）
#   USB_SERIAL        目标盘序列号（默认本机承载 PVE 存储目录的那块盘）
#   USB_STATE_DIR     状态目录（默认 /var/lib/fnos-stor/selfheal）
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CTID_IN="${CTID:-}"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
[ -n "$_CTID_IN" ] || die "必须显式传入 CTID（防默认 200 误伤）：sudo env CTID=201 bash $0 …"

CMD="${1:-check}"
case "$CMD" in check|apply|status|ensure-unit) ;; *) printf '用法: %s check|apply|status|ensure-unit\n' "$0" >&2; exit 2;; esac

# ---------- 盘身份（宿主私有标识一律外置到 /etc/fnos-usb-reattach.conf）----------
# 公开集不能出现具体盘序列号/标签/挂载点（leak-scan 会拦），因此：
#   · 身份从配置读（配置由 ensure-unit 写在 /etc，宿主本地、不进公开仓）；
#   · 环境变量优先于配置，便于测试与临时覆盖；
#   · udev 规则也由 ensure-unit **现场生成**（规则必须含序列号，故只能是宿主本地件）。
CONFIG_FILE="${USB_CONFIG:-/etc/fnos-usb-reattach.conf}"
cfg_get() { sed -n "s/^$1=//p" "$CONFIG_FILE" 2>/dev/null | head -1; }
USB_SERIAL="${USB_SERIAL:-$(cfg_get USB_SERIAL)}"
USB_LABEL="${USB_LABEL:-$(cfg_get USB_LABEL)}"
USB_MOUNT="${USB_MOUNT:-$(cfg_get USB_MOUNT)}"
USB_ALIAS="${USB_ALIAS:-$(cfg_get USB_ALIAS)}"
[ -n "$USB_SERIAL" ] || die "缺少盘序列号：请设置 USB_SERIAL 或写 $CONFIG_FILE（USB_SERIAL=…）"

STATE_DIR="${USB_STATE_DIR:-/var/lib/fnos-stor/selfheal}"
STATE_FILE="$STATE_DIR/usb-reattach-${USB_SERIAL}.json"
EVENTS_FILE="${USB_EVENTS_FILE:-/var/lib/fnos-stor/usb-events.jsonl}"
EVENT_KEEP=200

need_root
mkdir -p "$STATE_DIR"

# ---------- 盘当前身份（按序列号找设备，与盘符无关）----------
usb_mountpoint() { # 该标签对应的宿主挂载点（从 /etc/fstab 解析）
  [ -n "$USB_MOUNT" ] && { printf '%s\n' "$USB_MOUNT"; return 0; }
  local mp
  mp="$(awk -v l="$USB_LABEL" '
        $1 ~ ("^LABEL=" l "$") { print $2; next }
        $1 ~ ("/by-label/" l "$") { print $2 }
      ' /etc/fstab 2>/dev/null | head -1)"
  mp="${mp%/}"
  [ -n "$mp" ] || return 1
  printf '%s\n' "$mp"
}

usb_current_dev() { # 输出 /dev/sdX 或空
  local d
  for d in /sys/block/sd*; do
    [ -d "$d" ] || continue
    if [ "$(cat "$d/device/serial" 2>/dev/null)" = "$USB_SERIAL" ]; then
      printf '/dev/%s\n' "$(basename "$d")"
      return 0
    fi
  done
  # 兜底：udev 的 ID_SERIAL_SHORT
  for d in /dev/sd?; do
    [ -b "$d" ] || continue
    if udevadm info -q property -n "$d" 2>/dev/null | grep -q "^ID_SERIAL_SHORT=${USB_SERIAL}$"; then
      printf '%s\n' "$d"; return 0
    fi
  done
  return 1
}

usb_last_dev() { # 上次记录的设备名（首次为空）
  python3 - "$STATE_FILE" <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(d.get("last_dev") or "")
except Exception:
    print("")
PY
}

usb_state_field() { # $1=reattach_count|last_event
  python3 - "$STATE_FILE" "$1" <<'PY2' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    v = d.get(sys.argv[2])
    print(v if v is not None else "")
except Exception:
    print("")
PY2
}

usb_save_state() { # $1=设备名 $2=事件计数 $3=最近事件
  python3 - "$STATE_FILE" "$USB_SERIAL" "$1" "$2" "$3" <<'PY'
import datetime, json, os, sys
path, serial, dev, count, last = sys.argv[1:6]
doc = {"serial": serial,
       "last_dev": dev,
       "reattach_count": int(count or 0),
       "last_event": last or None,
       "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
except OSError:
    pass
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
}

# ---------- 事件 ----------
usb_record_event() { # $1=old $2=new $3=mounts(ok/bad) $4=container(running/stopped) $5=recovered(0/1)
  local old="$1" new="$2" mounts="$3" ctr="$4" recovered="$5" line
  line="$(printf '{"ts":"%s","serial":"%s","old_dev":"%s","new_dev":"%s","mounts":"%s","container":"%s","recovered":%s,"cause":"usb-reattach"}' \
    "$(date -Is)" "$USB_SERIAL" "${old:-none}" "${new:-none}" "$mounts" "$ctr" "$recovered")"
  mkdir -p "$(dirname "$EVENTS_FILE")"
  printf '%s\n' "$line" >> "$EVENTS_FILE"
  # 滚动保留最近 N 条
  tail -n "$EVENT_KEEP" "$EVENTS_FILE" > "$EVENTS_FILE.tmp" 2>/dev/null && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
  manifest_add "$(printf '{"ts":"%s","mech":"host-usb","action":"reattach","serial":"%s","old_dev":"%s","new_dev":"%s","mounts":"%s","container":"%s","recovered":%s}' \
    "$(date -Is)" "$USB_SERIAL" "${old:-none}" "${new:-none}" "$mounts" "$ctr" "$recovered")"
  printf '%s\n' "$line"
}

usb_event_count() { wc -l < "$EVENTS_FILE" 2>/dev/null | tr -d ' ' || echo 0; }

# ---------- 链路体检（只读）----------
usb_link_health() { # 输出 TSV：key<TAB>value
  local dev link_speed bridge bridge_name model cache apm advice=""
  dev="$(usb_current_dev || true)"
  if [ -n "$dev" ]; then
    local sysd; sysd="$(readlink -f "/sys/block/$(basename "$dev")/device" 2>/dev/null)"
    # 往上找 USB 设备（scsi → usb）
    local usbdev=""
    local p="$sysd"
    for _ in 1 2 3 4 5 6; do
      [ -n "$p" ] || break
      if [ -f "$p/idVendor" ]; then usbdev="$p"; break; fi
      p="$(dirname "$p")"
    done
    if [ -n "$usbdev" ]; then
      link_speed="$(cat "$usbdev/speed" 2>/dev/null)"
      bridge="$(cat "$usbdev/idVendor" 2>/dev/null):$(cat "$usbdev/idProduct" 2>/dev/null)"
      bridge_name="$(cat "$usbdev/product" 2>/dev/null)"
    fi
    model="$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_MODEL=\(.*\)$/\1/p' | head -1)"
    [ -z "$model" ] && model="$(cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null)"
    cache="$(cat "/sys/block/$(basename "$dev")/queue/write_cache" 2>/dev/null)"
  fi
  apm="$(hdparm -B "$dev" 2>/dev/null | grep -o 'APM_level[[:space:]]*=[[:space:]]*[0-9]*' | grep -o '[0-9]*$' || echo '?')"
  # 结论：低速档 + 廉价桥 + 2.5 寸盘 = 掉线温床
  case "$link_speed" in 480) advice="链路只有 480Mb/s（USB 2.0）：供电与带宽都吃紧 —— 建议换 USB 3.0 数据线并插 USB 3 口，或 SATA 直连";; esac
  case "$bridge" in 2109:*) advice="${advice:+$advice；}桥接芯片为廉价 USB-SATA 桥（$bridge $bridge_name）：建议换 ASM/JMicron 桥接盒或改直连";; esac
  case "$model" in *"ST1000LM"*|*"SMR"*) advice="${advice:+$advice；}2.5 寸 SMR 盘启动电流大，转速/落盘冲击更易触发掉线";; esac
  [ -z "$advice" ] && advice="链路体检未见明显风险项（仍建议观察重枚举事件计数）"
  printf 'device\t%s\n' "${dev:-<未在>}"
  printf 'mountpoint\t%s\n' "$(usb_mountpoint 2>/dev/null || echo '<未解析>')"
  printf 'link_speed\t%s\n' "${link_speed:-?}"
  printf 'bridge\t%s\n' "${bridge:-?} ${bridge_name:-}"
  printf 'model\t%s\n' "${model:-?}"
  printf 'write_cache\t%s\n' "${cache:-?}"
  printf 'apm_level\t%s\n' "${apm:-?}"
  printf 'advice\t%s\n' "$advice"
}

usb_health_json() { # $1 = 体检 TSV 文本（走 argv，不依赖 stdin/临时文件）
  python3 - "$STATE_FILE" "$USB_SERIAL" "$EVENTS_FILE" "$1" <<'PY'
import datetime, json, os, sys
state_path, serial, events_path, health_text = sys.argv[1:5]
health = {}
for line in health_text.splitlines():
    if "\t" in line:
        k, v = line.split("\t", 1)
        health[k] = v
state = {}
try:
    state = json.load(open(state_path, encoding="utf-8"))
except Exception:
    pass
last_event = state.get("last_event")
if isinstance(last_event, str) and last_event.strip():
    try:
        last_event = json.loads(last_event)
    except Exception:
        last_event = {"raw": last_event}
else:
    last_event = last_event or None
events = []
try:
    for line in open(events_path, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except Exception:
                pass
except Exception:
    pass
doc = {"serial": serial,
       "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "health": health,
       "reattach_count": state.get("reattach_count", 0),
       "last_event": last_event,
       "recent_events": events[-5:]}
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
}

ensure_unit() { # 写配置 + 生成 udev 规则 + 安装 systemd 单元（udev 触发 → 秒级恢复）
  local U="/etc/systemd/system/fnos-stor-usb-reattach-ct${CTID}.service"
  local R="/etc/udev/rules.d/99-fnos-reattach.rules"
  # 配置（宿主私有标识只落在这里）
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
# fnOS USB 盘重枚举恢复 —— 宿主私有配置（不进公开仓）
# USB_SERIAL  盘序列号（掉线重枚举后不变，身份用它）
# USB_LABEL   该盘上宿主存储分区的标签（挂载点按标签解析）
# USB_MOUNT   宿主挂载点（留空则按标签从 /etc/fstab 解析）
USB_SERIAL=${USB_SERIAL}
USB_LABEL=${USB_LABEL}
USB_MOUNT=${USB_MOUNT}
CTID=${CTID}
EOF
    log "已写宿主配置：$CONFIG_FILE"
  fi
  # udev 规则：必须含序列号 → 现场生成，宿主本地件
  cat > "$R" <<EOF
# 由 stor-usb-reattach.sh ensure-unit 生成（按序列号匹配盘重新出现）
# 用 ENV{ID_SERIAL_SHORT}：USB-ATA 桥后面板盘没有 sysfs serial 属性（序列号来自 ata_id），
# ATTRS{serial} 匹配不到。
SUBSYSTEM=="block", KERNEL=="sd?", ENV{ID_SERIAL_SHORT}=="${USB_SERIAL}", ACTION=="add", ENV{SYSTEMD_WANTS}="fnos-stor-usb-reattach-ct${CTID}.service"
EOF
  udevadm control --reload-rules 2>/dev/null
  cat > "$U" <<EOF
[Unit]
Description=fnOS LXC USB disk re-attach recovery (CT${CTID})
After=network.target

[Service]
Type=oneshot
Environment=CTID=${CTID}
ExecStart=${SCRIPT_DIR}/stor-usb-reattach.sh apply
EOF
  systemctl daemon-reload
  log "已生成 udev 规则：$R（按序列号匹配）"
  log "已安装恢复单元：$U"
}

main() {
  if [ "$CMD" = "ensure-unit" ]; then
    need_root
    ensure_unit
    exit 0
  fi
  local dev last changed=0
  dev="$(usb_current_dev || true)"
  last="$(usb_last_dev)"

  if [ "$CMD" = "status" ]; then
    local out health
    health="$(usb_link_health 2>/dev/null)"
    out="$(usb_health_json "$health" 2>/dev/null)"
    # 兜底：消费方（TUI）按 JSON 解析，输出必须始终是合法 JSON
    case "$out" in
      '{'*) printf '%s\n' "$out";;
      *)   printf '{"serial":"%s","healthy":false,"summary":"体检输出异常","reattach_count":0,"last_event":null}\n' "$USB_SERIAL";;
    esac
    exit 0
  fi

  echo "== stor-usb-reattach $CMD（盘 $USB_SERIAL / $USB_LABEL）=="
  echo "  当前设备: ${dev:-<未在>}   上次记录: ${last:-<无>}"

  # 链路体检（只读）
  local health; health="$(usb_link_health)"
  printf '%s\n' "$health" | awk -F'\t' 'NF==2 && $1!="advice" { printf "  %-12s %s\n", $1, $2 }'
  local advice; advice="$(printf '%s\n' "$health" | awk -F'\t' '$1=="advice"{print $2}')"
  [ -n "$advice" ] && echo "  建议: $advice"

  # 重枚举判定：设备名变了（首次只建基线，不算事件）
  local up_s
  up_s="$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)"
  if [ -z "$last" ]; then
    [ -n "$dev" ] && usb_save_state "$dev" 0 "" >/dev/null
    echo "  首次记录基线设备名：${dev:-<无>}"
  elif [ "${up_s:-0}" -lt 300 ] && [ -n "$dev" ]; then
    # 宿主刚开机时的枚举不是掉线：只更新基线，不记事件、不做恢复
    usb_save_state "$dev" "$(usb_state_field reattach_count)" "$(usb_state_field last_event)" >/dev/null
    echo "  开机阶段枚举，按基线处理（设备 ${dev}）"
  elif [ -n "$dev" ] && [ "$dev" != "$last" ]; then
    changed=1
    echo "  检测到重枚举：$last → $dev"
  fi

  if [ "$CMD" = "check" ]; then
    [ "$changed" = 1 ] && exit 1
    exit 0
  fi

  # apply：恢复（先挂载，后拉起）
  local mounts_ok=0 ctr_state="stopped" recovered=0
  if [ "$changed" = 1 ]; then
    # ① 宿主挂载点：按标签重挂（不打断在跑的容器）
    bash "$SCRIPT_DIR/stor-mountpoint.sh" apply >/dev/null 2>&1
    if bash "$SCRIPT_DIR/stor-mountpoint.sh" check >/dev/null 2>&1; then mounts_ok=1; fi
    # ② 容器：按期望状态拉起（走既有动作通道：最小间隔 + 24h 预算）
    bash "$SCRIPT_DIR/stor-guard.sh" repair >/dev/null 2>&1
    pct status "$CTID" 2>/dev/null | grep -q running && ctr_state="running" || ctr_state="stopped"
    [ "$mounts_ok" = 1 ] && [ "$ctr_state" = "running" ] && recovered=1
    # ③ 事件
    local ev; ev="$(usb_record_event "$last" "$dev" "$([ "$mounts_ok" = 1 ] && echo ok || echo bad)" "$ctr_state" "$recovered")"
    local count; count="$(usb_event_count)"
    usb_save_state "$dev" "$count" "$ev" >/dev/null
    echo "  恢复结果: 挂载点=$([ "$mounts_ok" = 1 ] && echo ok || echo bad) 容器=$ctr_state"
    [ "$recovered" = 1 ] && echo "  已完全恢复" || echo "  未完全恢复，需人工介入"
  else
    if [ -n "$dev" ]; then
      usb_save_state "$dev" "$(usb_state_field reattach_count)" "$(usb_state_field last_event)" >/dev/null
    fi
    echo "  无重枚举事件，无需恢复"
  fi

  [ "$changed" = 1 ] && [ "$recovered" = 1 ] && exit 0
  [ "$changed" = 1 ] && exit 1
  exit 0
}

main "$@"
