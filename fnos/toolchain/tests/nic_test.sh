#!/usr/bin/env bash
# ============================================================================
# tests/nic_test.sh — 只读校验：网卡被 NetworkManager 管理 + resmon active + 存储挂载
# 用法: sudo bash tests/nic_test.sh [ctid]   (默认 201)
# 无目标容器/未运行时 SKIP（退出 0），便于在任意环境安全运行。
# ============================================================================
set -uo pipefail
CT="${1:-201}"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

if ! pct status "$CT" >/dev/null 2>&1; then echo "SKIP: CT$CT 不存在"; exit 0; fi
pct status "$CT" 2>/dev/null | grep -q running || { echo "SKIP: CT$CT 未运行"; exit 0; }

nm="$(pct exec "$CT" -- sh -c "nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -m1 '^eth0:' || true")"
echo "$nm" | grep -q connected && ok "eth0 被 NM 管理 ($nm)" || no "eth0 被 NM 管理 ($nm)"

pct exec "$CT" -- sh -c 'grep -qE "^auto eth0" /etc/network/interfaces 2>/dev/null' \
  && no "interfaces 仍含 eth0 stanza（netdetect 回退）" || ok "interfaces 无 eth0 stanza"

r="$(pct exec "$CT" -- systemctl is-active resmon_service 2>/dev/null || true)"
[ "$r" = active ] && ok "resmon_service active" || no "resmon_service active ($r)"

rp="$(pct exec "$CT" -- python3 -c 'd=open("/usr/trim/bin/resmon_service","rb").read();print(1 if d[0x11b6c8:0x11b6d1]==bytes.fromhex("31c0900f84a7070000") else 0)' 2>/dev/null || echo 0)"
[ "$rp" = 1 ] && ok "resmon 已打 veth-kind 补丁（resmon.net 流量可用）" || no "resmon veth-kind 补丁缺失"

v="$(pct exec "$CT" -- sh -c 'findmnt -rno TARGET,FSTYPE | grep -E "^/vol[0-9]+ " || true')"
[ -n "$v" ] && ok "存储已挂载 ($v)" || no "存储未挂载"

echo
echo "== nic_test: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
