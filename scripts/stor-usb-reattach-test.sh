#!/usr/bin/env bash
# ============================================================================
# stor-usb-reattach-test.sh —— USB 盘重枚举即时恢复机制的回归
#
# 用法: sudo bash stor-usb-reattach-test.sh
# 退出: 0 全过 / 1 有失败
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/stor-usb-reattach.sh"
RULES="/etc/udev/rules.d/99-fnos-reattach.rules"
CONFIG="${USB_CONFIG:-/etc/fnos-usb-reattach.conf}"
TEST_STATE="/tmp/opencode/usb-reattach-test"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 2; }

# 用独立状态目录，避免污染真实状态；事件文件也挪走
rm -rf "$TEST_STATE"; mkdir -p "$TEST_STATE"
export USB_STATE_DIR="$TEST_STATE"
export USB_EVENTS_FILE="$TEST_STATE/events.jsonl"   # 测试不污染真实事件流
# 盘身份从宿主配置读（公开集不写死序列号/标签）
[ -f "$CONFIG" ] || { echo "缺宿主配置 $CONFIG（先跑 stor-usb-reattach.sh ensure-unit）"; exit 2; }
. "$CONFIG"
export USB_SERIAL USB_LABEL

# ① 语法
bash -n "$SCRIPT" && ok "① 语法正确" || bad "① 语法错误"

# ② 序列号识别（按 ID_SERIAL_SHORT，与盘符无关）
out="$(sudo -n env CTID=201 USB_STATE_DIR="$TEST_STATE" USB_EVENTS_FILE="$TEST_STATE/events.jsonl" bash "$SCRIPT" check 2>&1)"
if printf '%s' "$out" | grep -qE "当前设备: /dev/sd[a-z]"; then ok "② 按序列号识别到当前设备"; else bad "② 未识别到设备：$(printf '%s' "$out"|head -3)"; fi

# ③ 链路体检给出可执行结论
if printf '%s' "$out" | grep -q "建议:"; then ok "③ 链路体检给出建议"; else bad "③ 链路体检无建议"; fi
if printf '%s' "$out" | grep -qE "link_speed|bridge"; then ok "③b 体检含链路速率与桥接芯片"; else bad "③b 体检缺链路信息"; fi

# ④ 首次只建基线，不记事件
if printf '%s' "$out" | grep -q "首次记录基线"; then ok "④ 首次只建基线"; else bad "④ 首次未建基线"; fi

# ⑤ 设备名变化 → check 报红（退出码 1）
state="$TEST_STATE/usb-reattach-${USB_SERIAL}.json"
cur="$(python3 -c "import json;print(json.load(open('$state'))['last_dev'])")"
python3 - "$state" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["last_dev"] = "/dev/sdZZ"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
sudo -n env CTID=201 USB_STATE_DIR="$TEST_STATE" USB_EVENTS_FILE="$TEST_STATE/events.jsonl" bash "$SCRIPT" check >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then ok "⑤ 设备名变化 → 判红（退出码 1）"; else bad "⑤ 设备名变化未判红（rc=$rc）"; fi

# ⑥ apply：记事件 + 恢复（健康态：挂载 ok、容器 running）
out="$(sudo -n env CTID=201 USB_STATE_DIR="$TEST_STATE" USB_EVENTS_FILE="$TEST_STATE/events.jsonl" bash "$SCRIPT" apply 2>&1)"
if printf '%s' "$out" | grep -q "检测到重枚举"; then ok "⑥ 识别到重枚举"; else bad "⑥ 未识别重枚举"; fi
if printf '%s' "$out" | grep -q "恢复结果:"; then ok "⑥b 给出恢复结果"; else bad "⑥b 无恢复结果"; fi
if grep -q '"cause":"usb-reattach"' "$TEST_STATE/events.jsonl" 2>/dev/null; then
  ok "⑥c 重枚举事件已记录"
else
  bad "⑥c 未见重枚举事件"
fi

# ⑦ udev 规则：必须用 ENV{ID_SERIAL_SHORT}（面板盘没有 sysfs serial 属性）
if [ -f "$RULES" ] && grep -q "ENV{ID_SERIAL_SHORT}==\"${USB_SERIAL}\"" "$RULES"; then ok "⑦ udev 规则按序列号（ENV）匹配"; else bad "⑦ udev 规则未按 ENV{ID_SERIAL_SHORT} 匹配（或规则未生成）"; fi
if grep -q 'SYSTEMD_WANTS' "$RULES"; then ok "⑦b 规则走 systemd 触发（非 udev RUN）"; else bad "⑦b 规则未用 SYSTEMD_WANTS"; fi

# ⑧ 开机阶段不记事件（逻辑存在）
if grep -q "开机阶段枚举" "$SCRIPT"; then ok "⑧ 开机枚举按基线处理"; else bad "⑧ 开机枚举未特殊处理"; fi

# ⑨ 恢复顺序：先挂载后拉起
order="$(grep -n 'stor-mountpoint.sh\|stor-guard.sh' "$SCRIPT" | head -4 | tr '\n' ' ')"
case "$order" in
  *stor-mountpoint.sh*stor-guard.sh*) ok "⑨ 恢复顺序：先重挂后拉起";;
  *) bad "⑨ 恢复顺序不对：$order";;
esac

rm -rf "$TEST_STATE"
printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
