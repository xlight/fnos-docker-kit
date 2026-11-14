#!/usr/bin/env bash
# ============================================================================
# stor-guard.sh —— 宿主侧"存活巡检"（分钟级）：挂载点有效 + 容器在跑
#
# 为什么与 stor-selfheal.sh 分开：
#   stor-selfheal 是**存储栈自愈**（2 小时一轮，重动作：改配置、重建掩码、重启容器）；
#   stor-guard 是**存活巡检**（5 分钟一轮，零动作起步）：只回答一个问题——
#   "这个 NAS 现在是不是可用？"
#   2026-11-12 事故里 NAS 实际停了 2 小时，而 2 小时一轮的自愈把它判成"全部检查通过"
#   （根因：巡检 fail-open，见 fnos/41-usb-reenum-mountpoint-selfheal-gap.md）。
#   停机这种故障必须分钟级发现。
#
# 职责边界（刻意收窄）：
#   · 健康态：只更新状态文件，**零动作**（不 mount、不 start、不写容器配置）；
#   · 不健康态：只做两件事 —— 修宿主挂载点、按期望状态拉起容器；
#     更重的修复（配置/掩码/栈）仍归 stor-selfheal，**不重复造轮子**；
#   · 拉起受**预算**约束（24h 内最多 3 次、最小间隔 5 分钟），避免"起不来→反复拉起"
#     把守护变成故障源。
#
# 用法:
#   sudo env CTID=201 bash stor-guard.sh check     # 只检查（0 健康 / 1 不健康 / 2 用法错）
#   sudo env CTID=201 bash stor-guard.sh repair    # 检查 + 轻量修复
#   sudo env CTID=201 bash stor-guard.sh status    # 机器可读状态（JSON）
#
# 环境变量:
#   CTID              目标容器（必填，防误伤别的容器）
#   GUARD_INTERVAL    拉起最小间隔秒（默认 300）
#   GUARD_START_BUDGET 24h 内最大拉起次数（默认 3）
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CTID_IN="${CTID:-}"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
[ -n "$_CTID_IN" ] || die "必须显式传入 CTID（防默认 200 误伤）：sudo env CTID=201 bash $0 …"

CMD="${1:-check}"
JSON_MODE=0
case "$CMD" in check|repair|status) ;; *) printf '用法: %s check|repair|status\n' "$0" >&2; exit 2;; esac
[ "$CMD" = "status" ] && JSON_MODE=1

STATE_DIR="${GUARD_STATE_DIR:-/var/lib/fnos-stor/selfheal}"
EXPECT_FILE="$STATE_DIR/ct${CTID}.expect"
STATUS_FILE="$STATE_DIR/guard-ct${CTID}.json"
START_LOG="$STATE_DIR/ct${CTID}.starts"
INTERVAL="${GUARD_INTERVAL:-300}"
BUDGET="${GUARD_START_BUDGET:-3}"

need_root
mkdir -p "$STATE_DIR"

ct_running() { pct status "$CTID" 2>/dev/null | grep -q running; }

# 期望运行状态：默认 running（NAS 常态是开的）；人为停机显式记 stopped
expect_state() {
  local v=""
  [ -f "$EXPECT_FILE" ] && v="$(tr -d '[:space:]' < "$EXPECT_FILE" 2>/dev/null)"
  case "$v" in running|stopped) printf '%s\n' "$v";; *) printf 'running\n';; esac
}

# 宿主挂载点结论（复用 stor-mountpoint.sh）
mp_state() { bash "$SCRIPT_DIR/stor-mountpoint.sh" status 2>/dev/null; }
mp_healthy() {
  local out; out="$(mp_state)"
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("1" if d.get("healthy") else "0")' 2>/dev/null || echo 0
}

# 容器内登记卷是否真的挂上（轻量版：查 mount 表 + /proc/mounts）
ct_volumes_mounted() {
  local ids mp
  ids="$(pct exec "$CTID" -- sh -c 'sudo -u postgres psql -d trim -t -A -c "select id from mount order by id"' 2>/dev/null | tr -d ' \r')"
  [ -n "$ids" ] || return 1
  for mp in $ids; do
    case "$mp" in [0-9]*) ;; *) continue;; esac
    pct exec "$CTID" -- sh -c "grep -q ' /vol${mp} ' /proc/mounts" 2>/dev/null || return 1
  done
  return 0
}

# 拉起预算：24h 内最多 BUDGET 次，且两次之间至少 INTERVAL 秒
start_budget_ok() {
  local now last cnt=0 t
  now="$(date +%s)"
  last="$(tail -1 "$START_LOG" 2>/dev/null || echo 0)"
  [ -n "$last" ] || last=0
  if [ $((now - last)) -lt "$INTERVAL" ]; then
    log "拉起被抑制：距上次拉起不足 ${INTERVAL}s"
    return 1
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ $((now - t)) -lt 86400 ] && cnt=$((cnt+1))
  done < <(cat "$START_LOG" 2>/dev/null)
  if [ "$cnt" -ge "$BUDGET" ]; then
    log "拉起被抑制：24h 内已拉起 ${cnt} 次（预算上限 ${BUDGET}），需人工介入"
    return 1
  fi
  return 0
}

emit_json() { # $1=healthy(0/1) $2=container_running(0/1) $3=mountpoints_healthy(0/1) $4=expect $5=summary
  python3 - "$STATUS_FILE" "$1" "$2" "$3" "$4" "$5" "$CTID" <<'PY'
import datetime, json, os, sys
path, healthy, running, mp_ok, expect, summary, ctid = sys.argv[1:8]
doc = {"ctid": int(ctid),
       "checked_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "healthy": healthy == "1",
       "container_running": running == "1",
       "mountpoints_healthy": mp_ok == "1",
       "expect": expect,
       "summary": summary}
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
except OSError:
    pass
print(json.dumps(doc, ensure_ascii=False, indent=2))
PY
}

ensure_unit() { # 宿主侧存活巡检单元（5 分钟一轮；健康态零动作）
  local U="/etc/systemd/system/fnos-stor-guard-ct${CTID}.service"
  local T="/etc/systemd/system/fnos-stor-guard-ct${CTID}.timer"
  cat > "$U" <<EOF
[Unit]
Description=fnOS LXC liveness guard (CT${CTID}: mountpoints + container up)
After=fnos-stor-selfheal-ct${CTID}.service
Wants=fnos-stor-selfheal-ct${CTID}.service

[Service]
Type=oneshot
Environment=CTID=${CTID}
ExecStart=${SCRIPT_DIR}/stor-guard.sh repair
EOF
  cat > "$T" <<EOF
[Unit]
Description=定时存活巡检 fnOS LXC（CT${CTID}）

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "fnos-stor-guard-ct${CTID}.timer" >/dev/null 2>&1 && log "已启用存活巡检 timer：$(basename "$T")"
}

main() {
  local running=0 mp_ok=0 expect summary healthy=1
  expect="$(expect_state)"

  [ "$CMD" = "repair" ] && ensure_unit

  ct_running && running=1
  [ "$(mp_healthy)" = "1" ] && mp_ok=1

  if [ "$running" = 1 ] && [ "$mp_ok" = 1 ]; then
    healthy=1; summary="存活正常"
  elif [ "$expect" = "stopped" ]; then
    healthy=1; summary="按期望保持停机"
  else
    healthy=0
    summary="不健康：容器未运行且期望为 running" 
    [ "$mp_ok" = 0 ] && summary="不健康：宿主挂载点失效、容器未运行"
  fi

  if [ "$CMD" = "status" ]; then
    emit_json "$healthy" "$running" "$mp_ok" "$expect" "$summary"
    [ "$healthy" = 1 ] && exit 0 || exit 1
  fi

  if [ "$CMD" = "check" ]; then
    printf '  %-14s 容器运行=%s 宿主挂载点=%s 期望=%s → %s\n' "存活巡检" \
      "$([ "$running" = 1 ] && echo yes || echo no)" \
      "$([ "$mp_ok" = 1 ] && echo ok || echo bad)" "$expect" "$summary"
    emit_json "$healthy" "$running" "$mp_ok" "$expect" "$summary" >/dev/null
    [ "$healthy" = 1 ] && exit 0 || exit 1
  fi

  # repair：健康态零动作
  if [ "$healthy" = 1 ]; then
    emit_json "$healthy" "$running" "$mp_ok" "$expect" "$summary" >/dev/null
    exit 0
  fi

  # ① 宿主挂载点先修（轻量，不打断正在运行的容器）
  if [ "$mp_ok" = 0 ]; then
    log "宿主挂载点失效 → 调用 stor-mountpoint.sh apply"
    bash "$SCRIPT_DIR/stor-mountpoint.sh" apply >/dev/null 2>&1
    [ "$(mp_healthy)" = "1" ] && { mp_ok=1; log "宿主挂载点已恢复"; }
  fi

  # ② 容器没跑且期望为 running → 拉起（受预算约束）
  if [ "$running" = 0 ] && [ "$expect" = "running" ]; then
    # 与自愈修复互斥：自愈正在停容器重装配时，不能把容器拉起来打断它
    if ! action_lock_acquire "$CTID" 0; then
      summary="另一破坏性动作在跑（自愈修复中），本轮不拉起"
      log "$summary"
    elif start_budget_ok; then
      log "拉起容器：pct start $CTID"
      pct start "$CTID" >/dev/null 2>&1
      echo "$(date +%s)" >> "$START_LOG"
      local waited=0 up=0
      while [ "$waited" -lt 240 ]; do
        sleep 15; waited=$((waited+15))
        if ct_running && ct_volumes_mounted; then up=1; break; fi
      done
      if [ "$up" = 1 ]; then
        running=1; healthy=1; summary="已拉起并完成卷挂载"
        log "容器已起来且卷挂好（${waited}s）"
        manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"guard-start","ctid":%s,"result":"ok","waited":%s}' "$(date -Is)" "$CTID" "$waited")"
      else
        summary="拉起后未恢复可用（容器未运行或卷未挂上）"
        log "拉起未成功：$summary"
        manifest_add "$(printf '{"ts":"%s","mech":"host-storage","action":"guard-start","ctid":%s,"result":"failed","waited":%s}' "$(date -Is)" "$CTID" "$waited")"
      fi
      action_lock_release
    else
      summary="容器未运行，拉起被预算/冷却抑制"
    fi
  fi

  emit_json "$healthy" "$running" "$mp_ok" "$expect" "$summary" >/dev/null
  printf '  %-14s 容器运行=%s 宿主挂载点=%s 期望=%s → %s\n' "存活巡检" \
    "$([ "$running" = 1 ] && echo yes || echo no)" \
    "$([ "$mp_ok" = 1 ] && echo ok || echo bad)" "$expect" "$summary"
  [ "$healthy" = 1 ] && exit 0 || exit 1
}

main "$@"
