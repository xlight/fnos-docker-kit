#!/usr/bin/env bash
# ============================================================================
# tests/disk-io-monitor.sh — 磁盘 I/O 监控补丁的「默认不生效 / opt-in」自测
#
# 覆盖（全部在临时 rootfs 上，无需容器）：
#   1) 默认 check/apply 不应用 disk-io：resmon 停在 veth-only（9a5af…），
#      8 条 disk-io 列在报告的 retired
#   2) --include-disabled 把 9a5af… 推进到 veth+disk-io（231f…，8 条 applied）
#   3) 工厂 orig（e5c7…）：默认 apply -> 9a5af…；--include-disabled -> 231f…
#   4) 幂等：对 231f… 再 check 全 already（默认 / include-disabled 均 ok）
#   5) status:retired（filemanager）即便 --include-disabled 也不被应用
#
# 真值（单一来源）：patches/fnos-<ver>.json 的 file_hashes（resmon_service.orig/patched）。
#
# 用法: bash tests/disk-io-monitor.sh
#   可选: CTID=201 bash tests/disk-io-monitor.sh   # 额外做容器只读字节校验
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
PY="${PYTHON:-python3}"
PATCHSET="${PATCHSET:-$(ls "$TC"/patches/fnos-*.json 2>/dev/null | grep -v '\.bak' | sort -V | tail -1)}"
# fixture 指引（公开仓契约）：用自己的 ISO 生成（extract），再传入对应目录；
# PATCHSET/FIXTURE 必须同版本，一致性由上面的守卫强制，有漂移即明确中止。
AP="$TC/aobpatch.py"
# 全量补丁态（resmon 应为默认终态）的构建 rootfs，以及工厂 orig（resmon=orig）
# fixture 指引（公开仓契约）：用自己的 ISO 生成（extract），再传入对应目录
PATCHED_ROOT="${PATCHED_ROOT:-}"
FACTORY_ROOT="${FACTORY_ROOT:-}"
W="$(mktemp -d /tmp/opencode/fnos-dio.XXXXXX)"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
sha(){ sha256sum "$1" | awk '{print $1}'; }

[ -f "$PATCHSET" ] || { echo "缺少补丁集 $PATCHSET"; exit 2; }
[ -n "$PATCHED_ROOT" ] && [ -f "$PATCHED_ROOT/usr/trim/bin/resmon_service" ] || { echo "缺少已打补丁的 rootfs：先对 ISO 跑 fnos_patch apply，再 PATCHED_ROOT=<rootfs> 重跑"; exit 2; }
[ -n "$FACTORY_ROOT" ] && [ -f "$FACTORY_ROOT/usr/trim/bin/resmon_service" ] || { echo "缺少工厂 rootfs：先 sudo python3 $TC/fnos_iso.py extract <官方ISO> <destdir>，再 FACTORY_ROOT=<destdir> 重跑"; exit 2; }

# ---- 真值 + fixture/state 守卫（真值 = file_hashes） ----
# H_ORIG=orig；H_VETH=默认终态（patched 首项）；H_DIO=opt-in 终态（patched 次项）
read -r H_ORIG H_VETH H_DIO <<<"$($PY - "$PATCHSET" <<'PYEOF'
import json, sys
h = json.load(open(sys.argv[1]))["file_hashes"]["usr/trim/bin/resmon_service"]
p = h["patched"]; p = p if isinstance(p, list) else [p]
print(h["orig"], p[0], p[1] if len(p) > 1 else p[0])
PYEOF
)"
if $PY - "$PATCHSET" "$PATCHED_ROOT/usr/trim/bin/resmon_service" "$FACTORY_ROOT/usr/trim/bin/resmon_service" <<'PYEOF'
import json, sys, hashlib
h = json.load(open(sys.argv[1]))["file_hashes"]["usr/trim/bin/resmon_service"]
p = h["patched"]; p = p if isinstance(p, list) else [p]
def s(x): return hashlib.sha256(open(x, "rb").read()).hexdigest()
pr, fr = s(sys.argv[2]), s(sys.argv[3])
bad = []
if pr not in p: bad.append(("PATCHED_ROOT resmon", p, pr))
if fr != h["orig"]: bad.append(("FACTORY_ROOT resmon", h["orig"], fr))
if bad:
    print("FIXTURE DRIFT:", file=sys.stderr)
    for name, want, got in bad:
        print("  %-20s want=%s got=%s" % (name, want, got), file=sys.stderr)
    sys.exit(1)
print("state ok: PATCHED_ROOT∈patched, FACTORY_ROOT==orig")
PYEOF
then :; else echo "  FAIL: FIXTURE DRIFT（见上；非引擎缺陷）"; exit 2; fi

mk_tree(){ # $1=目标 rootfs  $2=resmon 源
  local t="$1" resmon="$2"
  rm -rf "$t"; mkdir -p "$t/usr/trim/bin" "$t/usr/trim/lib"
  cp "$PATCHED_ROOT/usr/trim/lib/libnfile.so"    "$t/usr/trim/lib/"
  cp "$PATCHED_ROOT/usr/trim/lib/libnperm.so"    "$t/usr/trim/lib/"
  cp "$PATCHED_ROOT/usr/trim/lib/libtrimacl.so"  "$t/usr/trim/lib/"
  cp "$PATCHED_ROOT/usr/trim/bin/filemanager"    "$t/usr/trim/bin/"
  cp "$PATCHED_ROOT/usr/trim/bin/network_service" "$t/usr/trim/bin/"
  cp "$resmon" "$t/usr/trim/bin/resmon_service"
}
run(){ $PY "$AP" "$@" >"$W/out.json" 2>"$W/out.err"; echo $?; }
jq_id_status(){ $PY - "$1" "$2" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1])); ids=sys.argv[2].split(",")
print(" ".join("%s=%s"%(p["id"],p["status"]) for p in d["patches"] if p["id"] in ids))
EOF
}

echo "== 1) 默认 apply（resmon 工厂 orig）-> 9a5af…，disk-io 未应用 =="
T="$W/a"; mk_tree "$T" "$FACTORY_ROOT/usr/trim/bin/resmon_service"
[ "$(sha "$T/usr/trim/bin/resmon_service")" = "$H_ORIG" ] && ok "初始 resmon = 工厂 orig" || no "初始 resmon 非工厂 orig"
rc=$(run apply --rootfs "$T" --patchset "$PATCHSET" --only aob)
[ "$rc" = 0 ] && ok "默认 apply 退出 0" || no "默认 apply 退出 $rc"
[ "$(sha "$T/usr/trim/bin/resmon_service")" = "$H_VETH" ] && ok "默认 apply 后 resmon = 9a5af…（disk-io 未应用）" || no "默认 apply 后 resmon 非 9a5af"
$PY - "$W/out.json" <<'EOF' && ok "8 条 disk-io 列在 retired" || no "disk-io 未列 retired"
import json,sys;d=json.load(open(sys.argv[1]))
n=len([r for r in d["retired"] if "disk-io-refresh" in r["id"]]); assert n==8,n
EOF

echo "== 2) --include-disabled：9a5af… -> 231f…（8 条 applied） =="
rc=$(run apply --rootfs "$T" --patchset "$PATCHSET" --only aob --include-disabled)
[ "$rc" = 0 ] && ok "opt-in apply 退出 0" || no "opt-in apply 退出 $rc"
[ "$(sha "$T/usr/trim/bin/resmon_service")" = "$H_DIO" ] && ok "opt-in 后 resmon = 231f…" || no "opt-in 后 resmon 非 231f"
ids="$(jq_id_status "$W/out.json" "resmon_service.disk-io-refresh#0,resmon_service.disk-io-refresh#7")"
[ "$ids" = "resmon_service.disk-io-refresh#0=applied resmon_service.disk-io-refresh#7=applied" ] \
  && ok "disk-io#0/#7 = applied" || no "disk-io 状态异常: $ids"

echo "== 3) 幂等：对 231f… 再 check（默认 + include-disabled 均 ok，全 already） =="
for extra in "" "--include-disabled"; do
  rc=$(run check --rootfs "$T" --patchset "$PATCHSET" --only aob $extra)
  a=$($PY -c "import json;d=json.load(open('$W/out.json'));print(sum(1 for p in d['patches'] if p['status']!='already'))")
  [ "$rc" = 0 ] && [ "$a" = 0 ] && ok "check${extra:+ (include-disabled)} ok 且全 already" \
    || no "check${extra:+ (include-disabled)} rc=$rc non-already=$a"
done

echo "== 4) --include-disabled 不误启用 status:retired（filemanager） =="
$PY - "$W/out.json" <<'EOF' && ok "retired 仍含 filemanager（未被 opt-in 放行）" || no "filemanager retired 丢失"
import json,sys;d=json.load(open(sys.argv[1]))
assert any("filemanager" in r["id"] for r in d["retired"]), d["retired"]
EOF

echo "== 5) 工厂 orig + include-disabled -> 231f…（veth 与 disk-io 一起打） =="
T2="$W/b"; mk_tree "$T2" "$FACTORY_ROOT/usr/trim/bin/resmon_service"
rc=$(run apply --rootfs "$T2" --patchset "$PATCHSET" --only aob --include-disabled)
[ "$rc" = 0 ] && [ "$(sha "$T2/usr/trim/bin/resmon_service")" = "$H_DIO" ] \
  && ok "orig --include-disabled -> 231f…" || no "orig --include-disabled 未达 231f (rc=$rc)"

if [ -n "${CTID:-}" ]; then
  echo "== 6) 容器 CT$CTID 只读字节校验 =="
  hs="$(sudo -n pct exec "$CTID" -- sha256sum /usr/trim/bin/resmon_service 2>/dev/null | awk '{print $1}')"
  u="$(sudo -n pct exec "$CTID" -- systemctl is-enabled fnos-disk-io-monitor.service 2>/dev/null || echo '')"
  case "$hs" in
    "$H_DIO")  echo "  容器 resmon = 231f…（disk-io 已应用）; 单元 enabled=$u" ;;
    "$H_VETH") echo "  容器 resmon = 9a5af…（未 opt-in）; 单元 enabled=$u" ;;
    *)         echo "  容器 resmon = ${hs:0:12}…（未知态）; 单元 enabled=$u" ;;
  esac
fi

rm -rf "$W"
echo
echo "== 结果: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
