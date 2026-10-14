#!/usr/bin/env bash
# ============================================================================
# tests/selftest.sh — 补丁引擎：幂等 / 失败即停 / 版本锚点（真值取自补丁集）
#
# 真值（单一来源）：patches/fnos-<ver>.json 的 file_hashes 与补丁定义。
#   - 期望补丁计数由补丁集推导（active = 非 retired/disabled）
#   - 终态断言用 file_hashes[file].patched（列表=多个合法终态）
#   - 篡改样本由补丁 match 派生
# fixture（原版输入）：
#   FIXTURE     = <extract>/orig                  （二进制；按 file_hashes.orig 守卫）
#   WWW_FIXTURE = <extract>/usr/trim             （www 文本补丁输入；按 find 串守卫）
#   漂移时以明确的 "FIXTURE DRIFT" 中止，不误报为引擎缺陷。
#
# 覆盖：
#   1) apply 全部 applied；重复 apply 全部 already（幂等）
#   2) 换回原版 -> 重放恢复（比 file_hashes.patched，列表感知）
#   3) 人为改动（由 match 派生）-> 失败即停（退出非 0 且不写任何文件）
#   4) 版本不符 -> 构建拒绝
#   5) 报告含补丁集版本 + 每条输入哈希（text 用 files[].input_sha256）
#
# 用法: bash tests/selftest.sh
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
PY="${PYTHON:-python3}"
FIXTURE="${FIXTURE:-}"
WWW_FIXTURE="${WWW_FIXTURE:-}"
PATCHSET="${PATCHSET:-$(ls "$TC"/patches/fnos-*.json 2>/dev/null | grep -v '\.bak' | sort -V | tail -1)}"
# fixture 版本戳跟随 PATCHSET（fnos-local-deb-head D2：测试输入也不写死旧版本；
# 二进制/www fixture 与补丁集的一致性由 fixture 守卫强制，有漂移即明确中止）
PATCHSET_VER="$("$PY" -c "import json,sys; print(json.load(open('$PATCHSET')).get('fnos_version','').lstrip('Vv'))")"
W="$(mktemp -d /tmp/opencode/fnos-selftest.XXXXXX)"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

[ -f "$PATCHSET" ] || { echo "缺少补丁集 $PATCHSET"; exit 2; }
# fixture 指引（公开仓契约）：orig/ 不随仓发布，用自己的 ISO 生成
[ -d "$FIXTURE" ] || { echo "缺少二进制 fixture：在 toolchain 目录先 sudo python3 fnos_iso.py extract <官方ISO> <destdir>，再 FIXTURE=<destdir> 重跑"; exit 2; }
[ -d "$WWW_FIXTURE" ] || { echo "缺少 www fixture：在 toolchain 目录先 sudo python3 fnos_iso.py extract <官方ISO> <destdir>，再 WWW_FIXTURE=<destdir>/usr/trim 重跑"; exit 2; }

# ---- fixture 守卫：对每个有 file_hashes 的文件断言 == 声明的 orig ----
# + 对 usr/trim/bin/ 下的文件断言 owner 可执行位（.so 不断言：库文件 644 合法）。
# 事故教训：orig/filemanager 曾以 644 入库，hash 全对但 file.* 全部 hanging。
fixture_check() {
  $PY - "$PATCHSET" "$FIXTURE" <<'PYEOF'
import json, sys, hashlib, os, stat
ps = json.load(open(sys.argv[1])); fx = sys.argv[2]
fh = ps.get("file_hashes") or {}
bad = []
for f, h in fh.items():
    b = os.path.basename(f); p = os.path.join(fx, b)
    if not os.path.exists(p):
        bad.append((b, h["orig"], "<missing>")); continue
    got = hashlib.sha256(open(p, "rb").read()).hexdigest()
    if got != h["orig"]:
        bad.append((b, h["orig"], got))
    if f.startswith("usr/trim/bin/") and not (os.stat(p).st_mode & stat.S_IXUSR):
        bad.append((b, "mode=755(可执行)", "mode=%o(不可执行)" % (stat.S_IMODE(os.stat(p).st_mode))))
if bad:
    print("FIXTURE DRIFT (%s):" % fx, file=sys.stderr)
    for b, want, got in bad:
        print("  %-18s want(orig)=%s got=%s" % (b, want, got), file=sys.stderr)
    sys.exit(1)
print("fixture ok: %d 个二进制 == file_hashes.orig（含 bin 可执行位）" % len(fh))
PYEOF
}

# ---- 真值查询 ----
active_count() {
  $PY - "$PATCHSET" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
def retired(p):
    if p.get("disabled"): return True
    return str(p.get("status", "")).lower() in ("retired", "deprecated", "disabled")
print(sum(1 for p in d["patches"] if not retired(p)))
PYEOF
}
text_finds() { # 全部 text 条目：每行 "<file-glob>	<find>"
  $PY - "$PATCHSET" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d["patches"]:
    if p.get("kind") == "text":
        print("%s\t%s" % (p["file"], p["find"]))
PYEOF
}

mk_tree() {
  local t="$1"
  rm -rf "$t"; mkdir -p "$t/etc" "$t/usr/trim/"{lib,bin,etc,www/assets,share/.restore}
  cp "$FIXTURE/libnfile.so"      "$t/usr/trim/lib/"
  cp "$FIXTURE/libnperm.so"      "$t/usr/trim/lib/"
  cp "$FIXTURE/libtrimacl.so"    "$t/usr/trim/lib/"
  cp "$FIXTURE/filemanager"      "$t/usr/trim/bin/"
  cp "$FIXTURE/network_service"  "$t/usr/trim/bin/"
  cp "$FIXTURE/resmon_service"   "$t/usr/trim/bin/"
  cp "$WWW_FIXTURE"/www/assets/Setting-*.js "$t/usr/trim/www/assets/"
  cp "$WWW_FIXTURE"/www/assets/index-*.js "$t/usr/trim/www/assets/"
  cp "$WWW_FIXTURE/share/.restore/www.zip"  "$t/usr/trim/share/.restore/"
  printf 'UUID=aaaa / ext4 defaults 0 1\ntrimafs /fs trimafs defaults 0 0\n' > "$t/etc/fstab"
  echo "$PATCHSET_VER" > "$t/usr/trim/etc/version"
}

snap() { for f in "$1"/usr/trim/lib/*.so "$1"/usr/trim/bin/*; do sha256sum "$f"; done; }

echo "== 0) fixture 守卫（真值 = 补丁集 file_hashes.orig） =="
if fixture_check; then ok "fixture 与补丁集声明一致"; else no "FIXTURE DRIFT（非引擎缺陷；先修 fixture）"; exit 2; fi
tf_ok=1
while IFS=$'\t' read -r tglob tfind; do
  [ -n "$tglob" ] || continue
  rel="${tglob#usr/trim/www/}"   # 如 assets/Setting-*.js
  # 注意：文件名模式必须不加引号以允许 glob 展开
  reldir="$(dirname "$rel")"; pat="$(basename "$rel")"
  # shellcheck disable=SC2086
  if grep -qF "$tfind" "$WWW_FIXTURE"/www/"$reldir"/$pat 2>/dev/null; then
    echo "  fixture 原版含 '${tfind:0:60}…'"
  else
    echo "  fixture 漂移：$tglob 不含 '${tfind:0:60}…'"; tf_ok=0
  fi
done <<<"$(text_finds)"
if [ "$tf_ok" = 1 ]; then ok "www fixture 为原版（全部 text 条目 find 命中）"; else no "www fixture 漂移"; exit 2; fi

echo "== 1) apply -> applied; rerun -> already =="
T="$W/rootfs"; mk_tree "$T"
n_active="$(active_count)"
$PY "$TC/aobpatch.py" apply --rootfs "$T" --patchset "$PATCHSET" --report "$W/r1.json" >/dev/null 2>&1
if $PY - "$W/r1.json" "$n_active" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); want = int(sys.argv[2])
assert d["ok"] is True, "apply 非 ok"
assert len(d["patches"]) == want, "n=%d want=%d" % (len(d["patches"]), want)
bad = [p["id"] for p in d["patches"] if p["status"] != "applied"]
assert not bad, "非 applied: %s" % bad
PYEOF
then ok "首轮 apply：$n_active 条全部 applied（计数由补丁集推导）"; else no "首轮 apply 异常"; fi
$PY "$TC/aobpatch.py" apply --rootfs "$T" --patchset "$PATCHSET" > "$W/r2.json" 2>/dev/null
n_applied=$($PY -c "import json;print(sum(1 for p in json.load(open('$W/r2.json'))['patches'] if p['status']=='applied'))")
[ "$n_applied" = "0" ] && ok "重复 apply 全部 already（幂等）" || no "重复 apply 仍有 $n_applied 条 applied"

echo "== 2) 自愈网：换回原版 -> 重放恢复（比 file_hashes.patched） =="
cp "$FIXTURE/libnfile.so" "$T/usr/trim/lib/libnfile.so"
$PY "$TC/aobpatch.py" apply --rootfs "$T" --patchset "$PATCHSET" >/dev/null 2>&1
if $PY - "$PATCHSET" "$T/usr/trim/lib/libnfile.so" <<'PYEOF'
import json, sys, hashlib
ps = json.load(open(sys.argv[1])); p = sys.argv[2]
h = ps["file_hashes"]["usr/trim/lib/libnfile.so"]["patched"]
want = h if isinstance(h, list) else [h]
got = hashlib.sha256(open(p, "rb").read()).hexdigest()
assert got in want, "got=%s want=%s" % (got, want)
PYEOF
then ok "重放后 libnfile.so == file_hashes.patched（声明终态）"; else no "重放未恢复到声明终态"; fi

echo "== 3) 人为改动（由 match 派生）-> 失败即停 =="
mk_tree "$T"
if $PY - "$PATCHSET" "$T" <<'PYEOF'
import json, sys, os
ps = json.load(open(sys.argv[1])); root = sys.argv[2]
def retired(p):
    if p.get("disabled"): return True
    return str(p.get("status", "")).lower() in ("retired", "deprecated", "disabled")
def parse(s):
    s = s.strip()
    if " " not in s and len(s) > 2:
        s = " ".join(s[i:i+2] for i in range(0, len(s), 2))
    return [None if t in ("?", "??", "**") else int(t, 16) for t in s.split()]
for p in ps["patches"]:
    if retired(p) or p.get("kind", "aob") == "text":
        continue
    pat = parse(p["match"])
    if any(x is None for x in pat):
        continue
    path = os.path.join(root, p["file"])
    if not os.path.exists(path):
        continue
    data = bytearray(open(path, "rb").read())
    i = bytes(data).find(bytes(pat))
    if i < 0:
        continue
    data[i + len(pat) // 2] ^= 0xFF   # 命中区翻一个字节 -> 该站点特征失效
    open(path, "wb").write(data)
    print("  (tampered %s @%#x via %s)" % (p["file"], i, p["id"]))
    break
else:
    sys.exit(3)
PYEOF
then :; else no "找不到可派生的篡改样本"; fi
b="$(snap "$T")"
if $PY "$TC/aobpatch.py" apply --rootfs "$T" --patchset "$PATCHSET" >/dev/null 2>&1; then
  no "被改动输入仍成功（应失败）"
else
  ok "被改动输入报错且退出非 0"
fi
a="$(snap "$T")"
[ "$a" = "$b" ] && ok "失败后未写任何文件（未产出半成品）" || no "失败后文件被写坏"

echo "== 4) 版本不符 -> 拒绝 =="
mk_tree "$T"; echo "9.9.9999" > "$T/usr/trim/etc/version"
if sudo -n "$PY" "$TC/fnos_patch.py" apply --rootfs "$T" --patches "$PATCHSET" >/dev/null 2>&1; then
  no "版本不符仍成功（应失败）"
else
  ok "版本不符拒绝构建（退出非 0）"
fi

echo "== 5) 报告含版本锚点 + 输入哈希 =="
$PY - "$W/r1.json" "$PATCHSET" <<'PYEOF' && ok "报告含 fnos_version + patchset_sha256 + 每条 input_sha256" || no "报告缺版本锚点"
import json, sys
d = json.load(open(sys.argv[1])); ps = json.load(open(sys.argv[2]))
assert d.get("fnos_version") and d.get("patchset_sha256")
fh = ps.get("file_hashes") or {}
for p in d["patches"]:
    if p["file"] in fh:
        assert "input_sha256" in p, p["id"]
    else:  # text 补丁：无整文件哈希锚点，用 files[].input_sha256
        assert p.get("files") and all("input_sha256" in f for f in p["files"]), p["id"]
PYEOF

rm -rf "$W"
echo
echo "== 结果: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
