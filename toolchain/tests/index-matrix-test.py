#!/usr/bin/env python3
"""index-matrix-test.py —— 覆盖度矩阵的回归（3.2/3.3）。

用本地 HTTP 服务冒充 Release 资产源，验证：
  1. 索引带 samples（tier-A / factory）与 coverage 两段；
  2. 覆盖度按纯哈希运算得出：1010 补丁集对 1.2.1000 出厂件 = 7/8，
     缺口 usr/trim/bin/resmon_service（与人工推导一致）；
  3. revision 以**公开仓当前索引**为基线只前进一格；
  4. samples/coverage 缺失（离线）时不编造矩阵；
  5. 生成的索引能通过 validate-index.py 的矩阵复算校验。

用法: python3 toolchain/tests/index-matrix-test.py
退出码: 0 全过；1 有失败。
"""
import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("PASS: %s" % m)


def bad(m):
    global FAIL
    FAIL += 1
    print("FAIL: %s" % m)


def load_ib():
    spec = importlib.util.spec_from_file_location(
        "ib", os.path.join(TC, "index_builder.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# 1.2.1000 出厂件指纹（与真实 ISO 提取结果一致的关键条目）
SAMPLE = {
    "version": "1.2.1000", "source": "tier-A", "state": "factory",
    "files": {
        "usr/trim/bin/filemanager": "9bddafa08199de6209b3bf0adc050f0a7ea1cf6e439e923453072274ee8d27a6",
        "usr/trim/bin/liveupdate": "6c04753fd3d98b78b6711c406a9d31fce9376d5eb6a1b5d61106e5ea9fa19bf7",
        "usr/trim/bin/network_service": "552e82e3103814e0b80923f6107c540b7265f58679b9da32cdc4a69e7f6bef05",
        "usr/trim/bin/resmon_service": "ad144cf4b9f4aa1f96f7ef80114132c1d01c44756e682d0b8fc9c609d80bad85",
        "usr/trim/lib/libnfile.so": "f48fa2059a94bb105a418cf519079e35c764546818c4b58050c9e1de582a5972",
        "usr/trim/lib/libnperm.so": "4b36c1e9e718428b338815f5bc8606ebad004e6dfc496162de1d206e423b29e8",
        "usr/trim/lib/libtrimacl.so": "e22e64442b32a9a3dd4e453897d516b9ac3b79c5e718b5b5aab4f2f2c23ee9d7",
        "usr/trim/bin/trim_app_center": "8c084c9b180b6078a941a8fcbeeea998b255ec7a36ab2a6905e6512035eeeb0e",
    },
    "generated_at": "2026-11-09T00:00:00Z",
}


def serve(root):
    handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=root, **kw)
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd, httpd.server_address[1]


def main():
    tmp = tempfile.mkdtemp(prefix="matrix-test-")
    try:
        # 假 Release 资产目录：<slug>/releases/download/<tag>/fingerprints-<ver>.json
        rel = os.path.join(tmp, "local", "repo", "releases", "download", "v1.2.1000")
        os.makedirs(rel)
        json.dump(SAMPLE, open(os.path.join(rel, "fingerprints-1.2.1000.json"), "w"))
        httpd, port = serve(tmp)
        base = "http://127.0.0.1:%d" % port

        ib = load_ib()
        ib.RELEASE_BASE = base
        ib.RELEASE_TMPL = base + "/%s/releases/download/%s/%s"

        stage = os.path.join(tmp, "stage")
        os.makedirs(os.path.join(stage, "toolchain", "patches"))
        for v in ("1.2.1000", "1.2.1010"):
            dst = os.path.join(stage, "toolchain", "patches", "fnos-%s.json" % v)
            shutil.copy(os.path.join(TC, "patches", "fnos-%s.json" % v), dst)
            # 公开仓里补丁集是**脱敏后**的形态（索引 sha256 对应脱敏后文件）
            d = json.load(open(dst))
            if isinstance(d.get("derived_from_table"), str):
                d["derived_from_table"] = "private-table:" + str(d.get("fnos_version", "unknown"))
            for x in d.get("patches", []):
                if isinstance(x, dict):
                    if "retired_reason" in x:
                        x["retired_reason"] = "retired"
                    if "disabled_reason" in x:
                        x["disabled_reason"] = "disabled (opt-in available)"
            json.dump(d, open(dst, "w"), ensure_ascii=False, indent=2)
        # 公开仓当前索引（基线 revision 18）
        baseidx = os.path.join(tmp, "base-index.json")
        json.dump({"revision": 18, "versions": {}}, open(baseidx, "w"))

        idx = ib.build(stage, slug="local/repo", source_commit="c" * 40,
                       base_file=baseidx)
        if idx["revision"] == 19:
            ok("1a. revision 以公开仓基线只前进一格（18 → 19）")
        else:
            bad("1a. revision=%s（应为 19）" % idx["revision"])
        if "1.2.1000" in (idx.get("samples") or {}):
            ok("1b. samples 收进了 tier-A/factory 样本")
        else:
            bad("1b. samples 缺失：%r" % list(idx.get("samples") or {}))
        cov = (idx.get("coverage") or {}).get("1.2.1010", {}).get("1.2.1000")
        if cov and cov.get("covered_files") == 7 and cov.get("total_files") == 8:
            ok("2a. 覆盖度 7/8（与人工推导一致）")
        else:
            bad("2a. 覆盖度错：%r" % cov)
        if cov and cov.get("missing") == ["usr/trim/bin/resmon_service"]:
            ok("2b. 缺口点名 resmon_service")
        else:
            bad("2b. 缺口错：%r" % (cov or {}).get("missing"))
        exact = (idx.get("coverage") or {}).get("1.2.1000", {}).get("1.2.1000")
        if exact and exact.get("covered_files") == 8:
            ok("2c. 同版本补丁集对同版本出厂件 8/8")
        else:
            bad("2c. 同版本覆盖度错：%r" % exact)

        # 生成的索引能过 validate-index.py（矩阵复算 + source_commit）
        p = subprocess.run([sys.executable, os.path.join(TC, "tests", "validate-index.py"),
                            "--index", os.path.join(stage, "toolchain", "patches", "index.json"),
                            "--patches-dir", os.path.join(stage, "toolchain", "patches")],
                           capture_output=True, text=True)
        if p.returncode == 0:
            ok("5. 生成的索引通过 validate-index.py（含矩阵复算）")
        else:
            bad("5. validate-index 失败：%s" % (p.stderr.strip()[:300] or p.stdout.strip()[:300]))

        # 离线（拉不到资产）→ 不编造矩阵
        idx2 = ib.build(stage, slug="local/repo", offline=True, base_file=baseidx)
        if not idx2.get("samples") and not idx2.get("coverage"):
            ok("4. 离线时不编造矩阵（无 samples/coverage）")
        else:
            bad("4. 离线仍产出矩阵")
        httpd.shutdown()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("== 结果: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
