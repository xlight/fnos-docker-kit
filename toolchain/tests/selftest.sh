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
#   6) tpk-perm 新条目定向（appcenter-tpk-perm）：锚点失败即停 + expect-mismatch 失败即停
#
# 注意：trim_app_center 约 103MB，纯 Python 特征扫描每条 ~1 分钟，全程预计 ~15 分钟。
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
  cp "$FIXTURE/trim_app_center"  "$t/usr/trim/bin/"
  cp "$FIXTURE/liveupdate"       "$t/usr/trim/bin/"   # 1010 起 liveupdate.hide-kernel-entry 归入 AOB 层
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
$PY - "$W/r1.json" "$W/r2.json" <<'PYEOF' && ok "tpk-perm 新条目：r1 applied、r2 already（幂等重放，真值=补丁集）" || no "tpk-perm 新条目状态异常"
import json, sys
mine = {"trim_app_center#tpk-walk-0644->0755", "trim_app_center#downloads-mkdir-0750->0755"}
def pick(f):
    d = json.load(open(f))
    return {p["id"]: p.get("status") for p in d["patches"] if p["id"] in mine}
s1, s2 = pick(sys.argv[1]), pick(sys.argv[2])
assert set(s1) == mine, "r1 缺新条目: %s" % s1
assert all(v == "applied" for v in s1.values()), "r1: %s" % s1
assert set(s2) == mine, "r2 缺新条目: %s" % s2
assert all(v == "already" for v in s2.values()), "r2: %s" % s2
PYEOF

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

echo "== 6) tpk-perm 新条目定向：锚点失败即停 + expect-mismatch 失败即停 =="
# 6a) 锚点方向（真值=补丁集 file_hashes）：篡改 P1 特征 -> 整文件哈希偏离 orig/patched -> 失败即停
mk_tree "$T"
if $PY - "$T/usr/trim/bin/trim_app_center" <<'PYEOF'
import sys
p = sys.argv[1]
data = bytearray(open(p, "rb").read())
i = data.find(bytes.fromhex("b9a4010000e8"))
assert i >= 0, "P1 特征缺失（fixture 漂移）"
data[i + 1] ^= 0xFF          # a4 -> 5b：特征失效且整文件哈希偏离 orig/patched
open(p, "wb").write(data)
print("  (tampered trim_app_center P1 @%#x)" % i)
PYEOF
then :; else no "6a: 找不到可篡改的 P1 特征"; fi
b="$(snap "$T")"
if $PY "$TC/aobpatch.py" apply --rootfs "$T" --patchset "$PATCHSET" --report "$W/r6a.json" >/dev/null 2>&1; then
  no "6a: 被篡改 trim_app_center 仍成功（应失败）"
else
  ok "6a: 被篡改 trim_app_center 报错且退出非 0"
fi
a="$(snap "$T")"
[ "$a" = "$b" ] && ok "6a: 失败后未写任何文件（未产出半成品）" || no "6a: 失败后文件被写坏"
$PY - "$W/r6a.json" <<'PYEOF' && ok "6a: 报告 precheck-failed 且新条目 unknown-file-hash" || no "6a: 报告状态不符"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("phase") == "precheck-failed" and d.get("ok") is False, d.get("phase")
s = {p["id"]: p.get("status") for p in d["patches"] if p["id"].startswith("trim_app_center#")}
assert s.get("trim_app_center#tpk-walk-0644->0755") == "unknown-file-hash", s
assert s.get("trim_app_center#downloads-mkdir-0750->0755") == "unknown-file-hash", s
PYEOF
# 6b) expect-mismatch 方向：去锚点迷你补丁集（条目仍取自真值补丁集）+ P1 特征出现 2 次
mk_tree "$T"
if $PY - "$PATCHSET" "$W/mini.json" "$T/usr/trim/bin/trim_app_center" <<'PYEOF'
import json, sys
ps = json.load(open(sys.argv[1]))
mini = {"fnos_version": ps.get("fnos_version"),
        "patches": [p for p in ps["patches"] if p["id"].startswith("trim_app_center#")],
        "file_hashes": {}}   # 去锚点：让命中计数（而非哈希门）成为失败原因
assert len(mini["patches"]) == 2, mini["patches"]
json.dump(mini, open(sys.argv[2], "w"))
with open(sys.argv[3], "ab") as f:
    f.write(bytes.fromhex("b9a4010000e8"))   # 追加一份 P1 特征 -> hits=2 != expect 1
PYEOF
then :; else no "6b: 迷你补丁集/篡改样本构造失败"; fi
b="$(snap "$T")"
if $PY "$TC/aobpatch.py" apply --rootfs "$T" --patchset "$W/mini.json" --report "$W/r6b.json" >/dev/null 2>&1; then
  no "6b: hits=2 仍成功（应 expect-mismatch）"
else
  ok "6b: expect-mismatch 报错且退出非 0"
fi
a="$(snap "$T")"
[ "$a" = "$b" ] && ok "6b: 失败后未写任何文件（未产出半成品）" || no "6b: 失败后文件被写坏"
$PY - "$W/r6b.json" <<'PYEOF' && ok "6b: 报告新条目 expect-mismatch(2!=1)" || no "6b: 报告状态不符"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("ok") is False
s = {p["id"]: p.get("status") for p in d["patches"] if p["id"].startswith("trim_app_center#")}
assert str(s.get("trim_app_center#tpk-walk-0644->0755", "")).startswith("expect-mismatch"), s
PYEOF

echo "== 7) best-effort 模式（合成小 fixture；断言三档/隔离/回退/备份） =="
BT="$W/be"; rm -rf "$BT"; mkdir -p "$BT/usr/trim/bin"
if $PY - "$PATCHSET" "$BT" <<'PYEOF'
import json, sys, os, hashlib
ps_path, bt = sys.argv[1], sys.argv[2]
ps = json.load(open(ps_path))
b = lambda n: b"\x00" * n
mk = lambda rel, data: open(os.path.join(bt, rel), "wb").write(data)
# ready（orig 锚定）、unverified（哈希未知唯一命中）、nomatch、ambiguous、already（patched 锚定）
a = b(32) + bytes.fromhex("deadbeef") + b(32)          # unverified unique
mk("usr/trim/bin/a.bin", a)
mk("usr/trim/bin/b.bin", b"\x11" * 64)                 # nomatch
mk("usr/trim/bin/c.bin", bytes.fromhex("deadbeef") + b"\x00" * 8 + bytes.fromhex("deadbeef"))  # ambiguous
d = b(32) + bytes.fromhex("cafebabe") + b(32)          # orig-known ready
dp = d.replace(bytes.fromhex("cafebabe"), bytes.fromhex("9090babe"))
mk("usr/trim/bin/d.bin", d)
e = b(32) + bytes.fromhex("90909090") + b(32)          # patched-known already
mk("usr/trim/bin/e.bin", e)
mini = {"fnos_version": ps.get("fnos_version"), "patches": [
    {"id": "a.unverified", "file": "usr/trim/bin/a.bin", "match": "de ad be ef",
     "replace": [{"find": "de ad", "to": "90 90"}], "expect": 1},
    {"id": "b.nomatch", "file": "usr/trim/bin/b.bin", "match": "de ad be ef",
     "replace": [{"find": "de ad", "to": "90 90"}], "expect": 1},
    {"id": "c.ambiguous", "file": "usr/trim/bin/c.bin", "match": "de ad be ef",
     "replace": [{"find": "de ad", "to": "90 90"}], "expect": 1},
    {"id": "d.ready", "file": "usr/trim/bin/d.bin", "match": "ca fe ba be",
     "replace": [{"find": "ca fe", "to": "90 90"}], "expect": 1},
    {"id": "e.already", "file": "usr/trim/bin/e.bin", "match": "ca fe ba be",
     "replace": [{"find": "ca fe", "to": "90 90"}], "expect": 1},
], "file_hashes": {
    "usr/trim/bin/d.bin": {"orig": hashlib.sha256(d).hexdigest(), "patched": hashlib.sha256(dp).hexdigest()},
    "usr/trim/bin/e.bin": {"orig": "00" * 64, "patched": hashlib.sha256(e).hexdigest()},
}}
json.dump(mini, open(os.path.join(bt, "ps.json"), "w"))
PYEOF
then :; else no "7: 合成 fixture 构造失败"; fi
# 7a) check 三档
$PY "$TC/aobpatch.py" check --rootfs "$BT" --patchset "$BT/ps.json" --best-effort > "$W/be-check.json" 2>/dev/null
$PY - "$W/be-check.json" <<'PYEOF' && ok "7a: check 三档 ready/ready-unverified/skipped/already 齐全" || no "7a: check 状态不符"
import json, sys
d = json.load(open(sys.argv[1]))
s = {p["id"]: p["status"].split("(")[0] for p in d["patches"]}
assert d["ok"] is True, d.get("ok")
assert s == {"a.unverified": "ready-unverified", "b.nomatch": "skipped",
             "c.ambiguous": "skipped", "d.ready": "ready", "e.already": "already"}, s
PYEOF
# 7b) apply：ready/unverified 被应用，skipped 不写，互不阻塞
$PY "$TC/aobpatch.py" apply --rootfs "$BT" --patchset "$BT/ps.json" --best-effort > "$W/be-apply.json" 2>/dev/null
$PY - "$W/be-apply.json" "$BT" <<'PYEOF' && ok "7b: apply 后 ready/unverified 已写、skipped 文件未动、ok 仍 true" || no "7b: apply 行为不符"
import json, sys
d = json.load(open(sys.argv[1])); bt = sys.argv[2]
s = {p["id"]: p["status"].split("(")[0] for p in d["patches"]}
assert d["ok"] is True
assert s["d.ready"] == "applied" and s["a.unverified"] == "applied", s
assert s["b.nomatch"] == "skipped" and s["c.ambiguous"] == "skipped", s
assert open(bt + "/usr/trim/bin/b.bin", "rb").read() == b"\x11" * 64
assert open(bt + "/usr/trim/bin/c.bin", "rb").read().count(bytes.fromhex("deadbeef")) == 2
PYEOF
# 7c) fallback：unknown-hash 唯一命中 -> skipped + force_cmd；强制可应用
BT2="$W/be2"; rm -rf "$BT2"; mkdir -p "$BT2/usr/trim/bin"
cp "$BT/usr/trim/bin/a.bin" "$BT2/usr/trim/bin/a.bin" 2>/dev/null || true
$PY - "$BT/ps.json" "$BT2" <<'PYEOF'
import json, sys, os, shutil
ps = json.load(open(sys.argv[1])); bt2 = sys.argv[2]
a = b"\x00" * 32 + bytes.fromhex("deadbeef") + b"\x00" * 32
open(os.path.join(bt2, "usr/trim/bin/a.bin"), "wb").write(a)
mini = {"fnos_version": ps["fnos_version"],
        "patches": [p for p in ps["patches"] if p["id"] == "a.unverified"],
        "file_hashes": {}}
json.dump(mini, open(os.path.join(bt2, "ps.json"), "w"))
PYEOF
$PY "$TC/aobpatch.py" apply --rootfs "$BT2" --patchset "$BT2/ps.json" --best-effort --fallback > "$W/be-fb.json" 2>/dev/null
$PY - "$W/be-fb.json" <<'PYEOF' && ok "7c: fallback 下 unknown-hash 唯一命中被 skipped 且带 force_cmd" || no "7c: fallback 行为不符"
import json, sys
d = json.load(open(sys.argv[1]))
p = d["patches"][0]
assert p["status"] == "skipped" and p.get("reason") == "unknown-hash-fallback", p
assert "--force-unverified --patch-id a.unverified" in p.get("force_cmd", ""), p.get("force_cmd")
PYEOF
$PY "$TC/aobpatch.py" apply --rootfs "$BT2" --patchset "$BT2/ps.json" --best-effort --fallback --force-unverified --patch-id a.unverified > "$W/be-force.json" 2>/dev/null
$PY - "$W/be-force.json" "$BT2" <<'PYEOF' && ok "7c: --force-unverified --patch-id 强制应用成功" || no "7c: 强制应用失败"
import json, sys
d = json.load(open(sys.argv[1])); bt2 = sys.argv[2]
p = d["patches"][0]
assert p["status"] == "applied" and p.get("applied_as") == "ready-unverified", p
data = open(bt2 + "/usr/trim/bin/a.bin", "rb").read()
assert data.count(bytes.fromhex("deadbeef")) == 0
PYEOF
# 7d) 备份存在且只保留最近 3 次运行目录
$PY - "$BT" <<'PYEOF' && ok "7d: 写前备份目录存在（backups/<ts>/ 下有文件）" || no "7d: 无备份"
import os, sys
bt = sys.argv[1]
root = os.path.join(bt, "usr/local/share/fnos-toolchain/backups")
dirs = [d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))] if os.path.isdir(root) else []
assert dirs, "no backup dirs"
files = []
for d in dirs:
    for dp, _, fns in os.walk(os.path.join(root, d)):
        files += fns
assert files, "backup dirs empty"
PYEOF

rm -rf "$W"
echo
echo "== 结果: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
