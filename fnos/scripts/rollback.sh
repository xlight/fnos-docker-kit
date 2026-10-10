#!/usr/bin/env bash
# rollback.sh —— 按 manifest 逆序全撤（net-all 组合的一键回退）
#
# 依据：$MANIFEST（默认 ~/fnos/backups/manifest.jsonl）里每个机制**最后一条动作**；
#       只回撤"最后动作是 apply"的机制，并按 ts 逆序执行。
# 无 manifest 时退化为按固定逆序 [n4 n3 n2 n1] 逐个看 status，已应用的才回撤。
#
# 用法: sudo bash rollback.sh [--dry-run]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

order_from_manifest() {
  [ -f "$MANIFEST" ] || return 1
  python3 - "$MANIFEST" <<'PY'
import json, sys
last = {}          # mech -> (ts, action)
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    m = r.get('mech')
    if not m or m == 'ovs-guard':      # 该机制由网络恢复脚本自己管回滚，这里跳过
        continue
    last[m] = (r.get('ts') or '', r.get('action'))
applied = [m for m, (ts, a) in last.items() if a == 'apply']
applied.sort(key=lambda m: last[m][0])
print(' '.join(reversed(applied)))
PY
}

mechs="$(order_from_manifest)" || true
if [ -z "${mechs// }" ]; then
  warn "manifest 中无可回撤记录，退化为固定逆序"
  mechs=""
fi
# 合并：manifest 顺序优先，补齐固定逆序里缺的机制（无映射表时仅用 manifest 顺序）
if command -v mech_order_rev >/dev/null 2>&1; then
for m in $(mech_order_rev); do
  case " $mechs " in *" $m "*) ;; *) mechs="$mechs $m" ;; esac
done
fi

log "候选顺序（manifest 优先 + 固定逆序补齐）: $mechs  (manifest: $MANIFEST)"
for m in $mechs; do
  s=""
  command -v mech_script >/dev/null 2>&1 && s="$(mech_script "$m")" || { warn "未知机制 $m，跳过"; continue; }
  [ -f "$s" ] || { warn "缺少脚本 $s，跳过"; continue; }
  # 以各机制的**真实状态**为准：已应用的才回撤（manifest 可能因历史失败而失真）
  if ! bash "$s" status >/dev/null 2>&1; then
    log "$m: 未应用，跳过"
    continue
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry-run] 将执行: bash $s rollback"
    continue
  fi
  log "== $m rollback =="
  bash "$s" rollback || warn "$m rollback 返回非 0（继续）"
done

if [ "$DRY" = 0 ]; then
  if [ -x "$SCRIPT_DIR/rollback-verify.sh" ]; then
    bash "$SCRIPT_DIR/rollback-verify.sh"
  else
    log "回撤完成（本树无验证脚本，跳过端到端验证）。"
  fi
fi
