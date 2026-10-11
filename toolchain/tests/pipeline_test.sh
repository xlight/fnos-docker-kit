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
import sys, os, types, tempfile
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
             version="V1.2.0701", script_dir=os.path.join(TC, "..", "scripts"))
    d.update(kw); return types.SimpleNamespace(**d)

# 1) 阶段路由
try:
    assert P.select_stages(ns(stages="image,release")) == ["image", "release"]; ok("--stages 路由")
except AssertionError: no("--stages 路由")
try:
    assert P.select_stages(ns(from_="verify", to="deploy")) == ["verify", "release", "deploy"]; ok("--from/--to 路由")
except AssertionError: no("--from/--to 路由")
try:
    assert P.select_stages(ns()) == P.STAGE_ORDER; ok("默认全阶段")
except AssertionError: no("默认全阶段")

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
a2 = ns(rootfs="/", out=tmp, stages="patch,image,verify", ctid=None)
rc2 = P.do_run(a2)
P.STAGES.update(orig)
(ok if (rc2 == 1 and calls == ["patch", "image"]) else no)("失败即停：image 失败后 verify 不执行 (calls=%s rc=%d)" % (calls, rc2))

# 5) 幂等跳过：patch 已就绪时不再 apply
orig_status, orig_apply = fnos_patch.status, fnos_patch.apply
fnos_patch.status = lambda r: {"x": True}
applied = []
fnos_patch.apply = lambda *a, **k: applied.append(1)
rc = P.stage_patch(ns(rootfs="/", force=False))
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

print()
print("== pipeline_test: PASS=%d FAIL=%d ==" % (pass_n, fail_n))
sys.exit(1 if fail_n else 0)
PYEOF
