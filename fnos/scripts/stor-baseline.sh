#!/usr/bin/env bash
# stor-baseline.sh —— 采集 fnOS 存储基线（CT200 与对照 VM104）
# 用法: sudo bash stor-baseline.sh [outdir]
# 只读：仅调用 stor.* 查询接口并留档，不做任何修改。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

STOR_PROBES='[{"req":"stor.general","params":{}},
              {"req":"stor.state2","params":{}},
              {"req":"stor.listStor","params":{}},
              {"req":"stor.listDisk","params":{}}]'

probe_stor() {  # <host> <label> <outfile>
  local host="$1" label="$2" out="$3"
  {
    echo "# fnOS 存储基线 · label=$label host=$host · $(date '+%F %T')"
    echo "## probes: $(printf '%s' "$STOR_PROBES" | tr -d '\n')"
    FNOS_HOST="$host" FNOS_PORT="$FNOS_PORT" FNOS_USER="$FNOS_USER" FNOS_PASS="$FNOS_PASS" \
      FNOS_DID="$FNOS_DID" \
      FNOS_PROBES="$STOR_PROBES" python3 "$RPC" 2>/dev/null | grep '^RESULT '
  } > "$out"
}

main() {
  need_root; need_py; need_rpc
  local outdir="${1:-$HOST_BACKUP_ROOT/$(ts)-stor-baseline}"
  mkdir -p "$outdir"
  log "输出目录: $outdir"

  probe_stor "$CT_IP"  "CT200" "$outdir/ct200-stor.jsonl"
  probe_stor "$VM_IP"  "VM104" "$outdir/vm104-stor.jsonl"

  if pct status "$CTID" 2>/dev/null | grep -q 'status: running'; then
    { echo "# CT200 /dev 与 /sys/block · $(date '+%F %T')"
      ct sh -c 'echo "## ls /dev/md* /dev/dm-* /dev/zd* /dev/loop*"; ls /dev/md* /dev/dm-* /dev/zd* /dev/loop* 2>&1; echo "## ls /sys/block"; ls /sys/block'
    } > "$outdir/ct200-devices.txt" 2>&1
  else
    echo "CT $CTID 未运行，跳过设备采集" > "$outdir/ct200-devices.txt"
  fi

  for f in ct200-stor.jsonl vm104-stor.jsonl; do
    n=$(grep -c '^RESULT ' "$outdir/$f" 2>/dev/null); n=${n:-0}
    printf '  %-20s results=%s\n' "$f" "$n"
  done
  log "完成: $outdir"
}

main "$@"
