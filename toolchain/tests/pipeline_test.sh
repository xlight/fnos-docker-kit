#!/usr/bin/env bash
# ============================================================================
# tests/pipeline_test.sh — 编排器核心行为自测（无需完整流水线/root）
#   覆盖：阶段路由、未知阶段报错、前置缺失判定、失败即停、幂等跳过
# 用法: bash tests/pipeline_test.sh
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
PY="${PYTHON:-python3}"

"$PY" - "$TC" <<'PYEOF'
import sys, os, types, tempfile, json, glob as _glob
def newest_patchset():
    cands = sorted(_glob.glob(os.path.join(TC, "patches", "fnos-*.json")))
    assert cands, "toolchain 内无补丁集"
    return cands[-1]
TC = sys.argv[1]
sys.path.insert(0, TC)
import fnos_pipeline as P
import fnos_patch, fnos_image

pass_n = fail_n = 0
def ok(m):
    global pass_n; pass_n += 1; print("  PASS:", m)
def no(m):
    global fail_n; fail_n += 1; print("  FAIL:", m)

def ns(**kw):
    d = dict(rootfs="/nonexistent", out="/tmp/opencode/pipe-test", stages=None,
             from_=None, to=None, ctid=201, force=False, patchset="", shim="",
             no_version_check=True, fs="ext4", size=12, vztmpl=False, zfs=None,
             deploy_image=None, storage="TEST-POOL", hostname="fnos-lxc",
             version=None, base=None, ota_version=None, debs_dir=None,
             script_dir=os.path.join(TC, "..", "scripts"))
    d.update(kw); return types.SimpleNamespace(**d)

# 1) 阶段路由
try:
    assert P.select_stages(ns(stages="image,release")) == ["image", "release"]; ok("--stages 路由")
except AssertionError: no("--stages 路由")
try:
    assert P.select_stages(ns(from_="verify", to="deploy")) == ["verify", "release", "deploy"]; ok("--from/--to 路由")
except AssertionError: no("--from/--to 路由")
try:
    assert P.select_stages(ns()) == [s for s in P.STAGE_ORDER if s != "overlay"]; ok("默认全阶段（无 base 跳过 overlay）")
except AssertionError: no("默认全阶段（无 base 跳过 overlay）")
try:
    assert P.select_stages(ns(base="/b")) == P.STAGE_ORDER; ok("默认全阶段（有 base 含 overlay 且居首）")
except AssertionError: no("默认全阶段（有 base 含 overlay 且居首）")
try:
    assert P.select_stages(ns(stages="overlay", base="/b")) == ["overlay"]; ok("--stages 单独 overlay")
except AssertionError: no("--stages 单独 overlay")

# 2) 未知阶段 -> SystemExit
try:
    P.select_stages(ns(stages="bogus")); no("未知阶段应报错")
except SystemExit: ok("未知阶段报错")

# 3) 前置缺失判定
miss = P.missing_prereqs("release", ns(rootfs="/", out="/tmp/opencode/pipe-nope"))
(ok if any("image" in m for m in miss) else no)("release 缺 image 前置被识别")
(ok if P.missing_prereqs("patch", ns(rootfs="/")) == [] else no)("patch 前置(rootfs=/ )满足")
(ok if any("--ctid" in m for m in P.missing_prereqs("smoke", ns(ctid=None))) else no)("smoke 缺 --ctid 被识别")
(ok if P.missing_prereqs("storage", ns(ctid=201), ["deploy"]) == [] else no)("storage 前置由更早的 deploy 产出则不算缺失")
(ok if P.missing_prereqs("smoke", ns(ctid=201), ["deploy"]) == [] else no)("smoke 前置由更早的 deploy 产出则不算缺失")

# 4) 失败即停：第二个阶段失败后，第三个阶段不得执行
calls = []
orig = dict(P.STAGES)
P.STAGES.update({
    "patch":  lambda a: (calls.append("patch"), 0)[1],
    "image":  lambda a: (calls.append("image"), 3)[1],
    "verify": lambda a: (calls.append("verify"), 0)[1],
})
tmp = tempfile.mkdtemp(prefix="pipe-")
open(os.path.join(tmp, "image.raw"), "w").close()
a2 = ns(rootfs="/", out=tmp, stages="patch,image,verify", ctid=None, version="V9.9.9999")
rc2 = P.do_run(a2)
P.STAGES.update(orig)
(ok if (rc2 == 1 and calls == ["patch", "image"]) else no)("失败即停：image 失败后 verify 不执行 (calls=%s rc=%d)" % (calls, rc2))

# 5) 幂等跳过：patch 已就绪时不再 apply
orig_status, orig_apply = fnos_patch.status, fnos_patch.apply
fnos_patch.status = lambda r: {"x": True}
applied = []
fnos_patch.apply = lambda *a, **k: applied.append(1)
rc = P.stage_patch(ns(rootfs="/", force=False, patchset=newest_patchset()))
fnos_patch.status, fnos_patch.apply = orig_status, orig_apply
(ok if (rc == 0 and not applied) else no)("幂等：patch 已就绪则跳过 apply")

# 6) 幂等跳过：image.raw 已存在则不重建
orig_mk = fnos_image.mkraw
built = []
fnos_image.mkraw = lambda *a, **k: built.append(1)
tmp2 = tempfile.mkdtemp(prefix="pipe-img-")
open(os.path.join(tmp2, "image.raw"), "w").close()
rc = P.stage_image(ns(rootfs="/", out=tmp2, force=False, vztmpl=False, zfs=None))
fnos_image.mkraw = orig_mk
(ok if (rc == 0 and not built) else no)("幂等：image.raw 存在则跳过重建")

# 7) overlay 前置判定
(ok if any("--base" in m for m in P.missing_prereqs("overlay", ns())) else no)("overlay 缺 --base 被识别")
tmp3 = tempfile.mkdtemp(prefix="pipe-ov-")
os.makedirs(os.path.join(tmp3, "base")); open(os.path.join(tmp3, "base", "f"), "w").close()
os.makedirs(os.path.join(tmp3, "rootfs")); open(os.path.join(tmp3, "rootfs", "x"), "w").close()
(ok if any("为空目录" in m for m in P.missing_prereqs("overlay", ns(base=tmp3 + "/base", ota_version="1.2.0800", rootfs=tmp3 + "/rootfs"))) else no)("overlay 非空 rootfs 被拒绝")
(ok if P.missing_prereqs("overlay", ns(base=tmp3 + "/base", ota_version="1.2.0800", rootfs=tmp3 + "/rootfs", force=True)) == [] else no)("overlay --force 允许重做非空 rootfs")
(ok if P.missing_prereqs("patch", ns(rootfs="/nonexistent"), ["overlay"]) == [] else no)("patch 前置由更早的 overlay 产出则不算缺失")

# 8) 版本推导：无版本 + overlay/patch 入口必填报错；有版本戳自动选中
a_nv = ns(rootfs="/nonexistent", out=tmp3, stages="patch")
(ok if P.resolve_version(a_nv) is None else no)("无版本戳时 resolve_version 返回 None")
a_v = ns(rootfs="/", out=tmp3, stages="patch", version="V1.2.0800")
(ok if P.resolve_patchset(a_v) == os.path.join(TC, "patches", "fnos-1.2.0800.json") else no)("有版本时 patchset 自动推导")
a_bad = ns(rootfs="/", out=tmp3, stages="patch", version="V9.9.9999")
(ok if P.resolve_patchset(a_bad) is None else no)("无对应补丁集时推导返回 None（入口失败，不猜旧版）")

# 9) overlay 合成测试（合成底座 + 合成 .deb + stub fetch，无需网络）
import subprocess as _sp
tb = tempfile.mkdtemp(prefix="pipe-ovb-")
os.makedirs(os.path.join(tb, "etc"))
open(os.path.join(tb, "etc", "machine-id"), "w").write("junk")
open(os.path.join(tb, "etc", "hostname"), "w").write("junk")
os.makedirs(os.path.join(tb, "usr/trim/lib"))
open(os.path.join(tb, "usr/trim/lib", "keep.so"), "w").write("base")
pkg = tempfile.mkdtemp(prefix="pipe-pkg-")
os.makedirs(os.path.join(pkg, "DEBIAN")); os.makedirs(os.path.join(pkg, "usr/trim/lib"))
open(os.path.join(pkg, "DEBIAN", "control"), "w").write("Package: t\nVersion: 1\nArchitecture: all\nMaintainer: t\nDescription: t\n")
open(os.path.join(pkg, "usr/trim/lib", "new.so"), "w").write("overlayed")
deb = os.path.join(tb, "t.deb")
assert _sp.run(["dpkg-deb", "-b", pkg, deb], capture_output=True).returncode == 0, "dpkg-deb 缺失则本项跳过"
tr = tempfile.mkdtemp(prefix="pipe-ovr-")
orig_run = P.run
def fake_run(cmd, env_extra=None, check=False):
    if "fetch-ota-debs.py" in cmd[1]:
        import shutil as _sh
        out = cmd[cmd.index("--out") + 1]
        _sh.copy(deb, os.path.join(out, "t.deb"))
        return 0
    return orig_run(cmd, env_extra, check)
P.run = fake_run
try:
    rc = P.stage_overlay(ns(base=tb, rootfs=tr, ota_version="1.2.0800", out=tmp3, debs_dir=os.path.join(tmp3, "debs")))
    ok_overlay = (rc == 0
                  and open(os.path.join(tr, "usr/trim/lib", "new.so")).read() == "overlayed"
                  and open(os.path.join(tr, "usr/trim/lib", "keep.so")).read() == "base"
                  and open(os.path.join(tr, "usr/trim/etc/version")).read().strip() == "1.2.0800"
                  and not os.path.lexists(os.path.join(tr, "etc/machine-id"))
                  and json.load(open(os.path.join(tr, P.OVERLAY_MARKER)))["ota_version"] == "1.2.0800")
    (ok if ok_overlay else no)("overlay 合成：覆盖+清理+版本戳+marker")
    rc2 = P.stage_overlay(ns(base=tb, rootfs=tr, ota_version="1.2.0800", out=tmp3, debs_dir=os.path.join(tmp3, "debs")))
    (ok if rc2 == 0 else no)("overlay 幂等：marker 一致则跳过")
finally:
    P.run = orig_run

print()
print("== pipeline_test: PASS=%d FAIL=%d ==" % (pass_n, fail_n))
sys.exit(1 if fail_n else 0)
PYEOF
py_rc=$?

echo "== 10) 缺省回潮回归（任一缺省重新指向具体旧版本即失败） =="
rg_rc=0
# argparse 缺省禁止出现旧版本字面量（docstring 示例除外，只查 default= 行）
if grep -rn 'default=.*1\.2\.0701' "$TC"/*.py | grep -v tests/; then
  echo "  FAIL: 发现指向旧版本的 argparse 缺省"; rg_rc=1
else
  echo "  PASS: 无指向旧版本的 argparse 缺省"
fi
if grep -rn 'fnos-1\.2\.0701\.json' "$TC"/tests/*.sh; then
  echo "  FAIL: 测试脚本写死旧版本补丁集文件名"; rg_rc=1
else
  echo "  PASS: 测试脚本无写死旧版本文件名"
fi
if "$PY" -c "import sys; sys.path.insert(0, '$TC'); import fnos_patch, fnos_pipeline; assert hasattr(fnos_patch, 'resolve_patchset') and hasattr(fnos_pipeline, 'resolve_version')"; then
  echo "  PASS: 版本推导入口存在（fnos_patch.resolve_patchset / pipeline.resolve_version）"
else
  echo "  FAIL: 版本推导入口缺失"; rg_rc=1
fi

[ "$py_rc" = 0 ] && [ "$rg_rc" = 0 ]
